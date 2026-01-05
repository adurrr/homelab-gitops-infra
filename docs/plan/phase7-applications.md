# Phase 7: Application Workloads

> **Goal:** Deploy photo management (Immich or PhotoPrism) with appropriate storage
> architecture, and document the ARR stack external deployment pattern.

**Depends on:** Phase 2 (ArgoCD, Traefik, cert-manager), Phase 4 (Kyverno, SealedSecrets), Phase 5 (Velero for backup)
**Duration:** 1 week (planning + storage setup), 2-3 days (deployment + import)
**New namespaces:** `immich` (or `photoprism`)
**Resource budget (Immich ML):** +4-8GB RAM, +1 core (indexing); ~1.5GB idle
**Resource budget (PhotoPrism):** +400MB-2GB, ~0.3 cores
**Architecture decisions:** [AD-012](../architecture.md#ad-012-immich-over-photoprism-for-photo-management), [AD-013](../architecture.md#ad-013-arr-stack-on-external-vm-not-in-k3s)

---

## What Phase 7 Delivers

Two independent workstreams that represent the "homelab applications" layer:

| Workstream | Decision | Rationale |
|-----------|----------|-----------|
| **Photo Management** | Immich (if RAM ≥ 8GB/node) or PhotoPrism (if RAM < 8GB) | See [AD-012](../architecture.md#ad-012-immich-over-photoprism-for-photo-management) |
| **ARR Stack (Media)** | External Docker VM, NOT in K3s | See [AD-013](../architecture.md#ad-013-arr-stack-on-external-vm-not-in-k3s) |

---

## Workstream 1: Photo Management

### Decision: Immich (conditional)

Immich is the clear choice IF each node has ≥ 8GB RAM. The mobile app (auto-backup from phone) is the killer feature. PhotoPrism is the fallback for lower-RAM nodes or read-only archive use cases.

### Architecture

```
┌────────────────────────────────────────────────────────────────────┐
│                       Immich in K3s                                 │
│                                                                     │
│  ┌────────────────┐    ┌────────────────┐    ┌──────────────────┐ │
│  │ Immich Server   │    │ Immich ML       │    │ PostgreSQL       │ │
│  │ :8080           │───►│ :3003           │    │ :5432            │ │
│  │                  │    │                  │    │ + VectorChord    │ │
│  │ API + uploads   │    │ Face detection   │    │ + pgvector       │ │
│  │                  │    │ CLIP search      │    │                  │ │
│  └────────┬─────────┘    └────────┬─────────┘    └────────┬─────────┘ │
│           │                       │                       │           │
│  ┌────────▼───────────────────────▼───────────────────────▼─────────┐ │
│  │                       Storage                                     │ │
│  │                                                                   │ │
│  │  local-path (fast SSD)          NFS (NAS share)                   │ │
│  │  ┌────────────────────┐        ┌────────────────────────────┐    │ │
│  │  │ PostgreSQL data    │        │ /photos/                    │    │ │
│  │  │ (50Gi PVC)         │        │ ├── library/   (read-only) │    │ │
│  │  │                    │        │ ├── upload/    (read-write)│    │ │
│  │  │ Redis data         │        │ └── thumbs/    (generated) │    │ │
│  │  │ (1Gi PVC)          │        └────────────────────────────┘    │ │
│  │  └────────────────────┘                                          │ │
│  └──────────────────────────────────────────────────────────────────┘ │
│                                                                       │
│  Backup:                                                              │
│  ├── PostgreSQL: Velero (Kopia FSB, daily)                            │
│  ├── Redis: not backed up (ephemeral job queue)                       │
│  └── Photos: NAS snapshot (NOT Velero; too large)                    │
└──────────────────────────────────────────────────────────────────────┘
```

### Deployment (Immich)

```yaml
# platform/immich/values.yaml
# Install via OCI Helm chart
# helm install immich oci://ghcr.io/immich-app/immich-charts/immich -f values.yaml

image:
  tag: "v1.133.0"  # Pin to specific version

immich:
  persistence:
    library:
      enabled: true
      existingClaim: immich-library-pvc  # NFS PVC; ReadWriteMany
    uploads:
      enabled: true
      existingClaim: immich-library-pvc  # Same NFS share

  metrics:
    enabled: true  # Prometheus scraping

  # ===== PostgreSQL + VectorChord =====
  postgresql:
    enabled: true
    image:
      repository: tensorchord/pgvecto-rs
      tag: "pg16-v0.3.0"  # ARM64 compatible
    persistence:
      enabled: true
      size: 50Gi
      storageClass: local-path  # Fast local SSD for DB performance
    resources:
      requests: { cpu: 200m, memory: 256Mi }
      limits:   { cpu: 1000m, memory: 1Gi }

  # ===== Redis =====
  redis:
    enabled: true
    architecture: standalone  # Single instance; no HA needed for homelab
    persistence:
      enabled: true
      size: 1Gi

  # ===== ML Service =====
  machineLearning:
    enabled: true  # Disable if RAM < 6GB
    resources:
      requests: { cpu: 100m, memory: 256Mi }
      limits:   { cpu: 1000m, memory: 2Gi }

  # ===== Resource Limits =====
  server:
    resources:
      requests: { cpu: 100m, memory: 256Mi }
      limits:   { cpu: 1000m, memory: 1Gi }

# ===== Ingress =====
ingress:
  main:
    enabled: true
    ingressClassName: traefik
    hosts:
      - host: photos.homelab.local
        paths:
          - path: /
            pathType: Prefix
    tls:
      - hosts:
          - photos.homelab.local
        secretName: immich-tls
```

### Storage Architecture (Critical Detail)

**PostgreSQL stays on local-path.** VectorChord needs fast random I/O for vector similarity searches. NFS adds network latency that degrades search performance. 50Gi is adequate for a personal photo library (< 100k photos).

**Photos go to NFS.** Reasons:
1. ReadWriteMany; if I ever want to run a second Immich pod or a sidecar photo tool
2. Too large for Velero; NAS handles its own snapshots
3. Survives cluster rebuild; photos exist independently of K3s

**`/dev/shm` requirement for PostgreSQL:**

```yaml
# In the Immich values or as a pod patch
volumes:
  postgresql:
    extraVolumes:
      - name: dshm
        emptyDir:
          medium: Memory
          sizeLimit: 1Gi
    extraVolumeMounts:
      - name: dshm
        mountPath: /dev/shm
```

Without this, PostgreSQL + VectorChord on ARM64 fails during large vector index builds because shared memory is insufficient.

### ARM64 PostgreSQL Image

The default PostgreSQL image in the Immich chart may not include the VectorChord extension on ARM64. Two options:

1. Use Immich's curated PostgreSQL image: `ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0`
2. Use `tensorchord/pgvecto-rs:pg16-v0.3.0` (ARM64 native)

Verify with: `SELECT * FROM pg_available_extensions WHERE name = 'vector';`

### Fallback: PhotoPrism (if RAM < 8GB/node)

```yaml
# platform/photoprism/values.yaml
image:
  repository: photoprism/photoprism
  tag: "latest"
  pullPolicy: Always

persistence:
  originals:
    enabled: true
    existingClaim: photoprism-photos-pvc  # NFS PVC

  storage:
    enabled: true
    size: 10Gi
    storageClass: local-path

mariadb:
  enabled: true
  persistence:
    enabled: true
    size: 10Gi

resources:
  requests: { cpu: 100m, memory: 256Mi }
  limits:   { cpu: 500m, memory: 2Gi }

ingress:
  enabled: true
  hosts:
    - host: photos.homelab.local
```

PhotoPrism needs ~4GB swap configured on the node to avoid OOM during TensorFlow indexing. That's a Proxmox host setting, not a K3s setting.

### Hybrid Option: Both

Both tools can point at the same photo directory. Immich handles mobile backup and browsing; PhotoPrism runs as a read-only archive for advanced search. They don't conflict because neither modifies files in the other's domain. This doubles the resource budget but gives the best of both worlds. Only viable on 8GB+ nodes.

---

## Workstream 2: ARR Stack (External Deployment)

### Decision: Docker Compose on Dedicated VM

The ARR stack (Sonarr, Radarr, Prowlarr, qBittorrent+VPN, Jellyseerr) is NOT deployed in K3s. It runs on a separate Proxmox VM managed by Docker Compose. See [AD-013](../architecture.md#ad-013-arr-stack-on-external-vm-not-in-k3s) for the full justification.

### Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                         Proxmox Hosts                                  │
│                                                                       │
│  ┌─────────────────────┐  ┌─────────────────────┐                    │
│  │  K3s Node 1          │  │  K3s Node 2          │                    │
│  │  (K8s workloads)     │  │  (K8s workloads)     │                    │
│  └─────────────────────┘  └─────────────────────┘                    │
│                                                                       │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │  Proxmox VM: arr-media (2 vCPU, 4GB RAM, 200GB disk)       │    │
│  │  ┌───────────────────────────────────────────────────────┐  │    │
│  │  │              Docker Compose Stack                       │  │    │
│  │  │                                                        │  │    │
│  │  │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ │  │    │
│  │  │  │  Gluetun │ │qBittorrent│ │  Sonarr   │ │  Radarr   │ │  │    │
│  │  │  │ (VPN)    │ │          │ │  :8989    │ │  :7878    │ │  │    │
│  │  │  │          │ │ seedbox  │ │           │ │           │ │  │    │
│  │  │  └────┬─────┘ └────┬─────┘ └─────┬─────┘ └─────┬─────┘ │  │    │
│  │  │       │            │             │             │       │  │    │
│  │  │       ▼            ▼             └──────┬──────┘       │  │    │
│  │  │  ┌────────────────────┐                 │              │  │    │
│  │  │  │  Traffic flow:     │                 ▼              │  │    │
│  │  │  │  Gluetun → qBittor │    ┌──────────────────────┐   │  │    │
│  │  │  │  (VPN kill-switch) │    │     Prowlarr         │   │  │    │
│  │  │  └────────────────────┘    │     :9696            │   │  │    │
│  │  │                            │  (indexer manager)    │   │  │    │
│  │  │                            └──────────┬───────────┘   │  │    │
│  │  │                                       │               │  │    │
│  │  │                                       ▼               │  │    │
│  │  │                          ┌──────────────────────┐     │  │    │
│  │  │                          │    Jellyseerr        │     │  │    │
│  │  │                          │    :5055             │     │  │    │
│  │  │                          │  (request UI)         │     │  │    │
│  │  │                          └──────────────────────┘     │  │    │
│  │  │                                                        │  │    │
│  │  │  Storage: bind mounts                                  │  │    │
│  │  │  /mnt/nas/media/movies      → /movies (Radarr)         │  │    │
│  │  │  /mnt/nas/media/tv          → /tv (Sonarr)              │  │    │
│  │  │  /mnt/nas/media/downloads   → /downloads (qBittorrent) │  │    │
│  │  │  /opt/arr-stack/config      → /config (persistent)     │  │    │
│  │  └───────────────────────────────────────────────────────┘  │    │
│  └─────────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────────┘
```

### Network Integration with K3s

The VM's services appear at `*.homelab.local` via Traefik in K3s:

```yaml
# platform/arr-proxy/services.yaml
# ExternalName Services bridge K3s networking to the external VM
---
apiVersion: v1
kind: Service
metadata:
  name: sonarr
  namespace: arr-proxy
spec:
  type: ExternalName
  externalName: arr-media-vm.lan  # VM hostname or IP
  ports:
    - port: 80
      targetPort: 8989
---
apiVersion: v1
kind: Service
metadata:
  name: radarr
  namespace: arr-proxy
spec:
  type: ExternalName
  externalName: arr-media-vm.lan
  ports:
    - port: 80
      targetPort: 7878
```

```yaml
# platform/arr-proxy/ingressroute.yaml
# Traefik IngressRoute for external VM service
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: sonarr
  namespace: arr-proxy
spec:
  entryPoints:
    - websecure
  routes:
    - kind: Rule
      match: Host(`sonarr.homelab.local`)
      services:
        - name: sonarr
          port: 80
  tls:
    secretName: sonarr-tls  # cert-manager manages this
```

**This gives me:** valid TLS certs (cert-manager), DNS (`*.homelab.local`), and Traefik middleware (auth headers, rate limiting) for services that don't live in K3s. The best of both worlds.

### ARM64 Image Compatibility

All ARR apps use `lscr.io/linuxserver/*` images; full multi-arch (linux/arm64). If I ever change my mind and deploy in K3s, the images are ready. But the architecture decision stands: separate VM.

| App | Image | ARM64 | RAM (idle) |
|-----|-------|-------|------------|
| Sonarr | `lscr.io/linuxserver/sonarr` | ✅ | ~150MB |
| Radarr | `lscr.io/linuxserver/radarr` | ✅ | ~150MB |
| Prowlarr | `lscr.io/linuxserver/prowlarr` | ✅ | ~80MB |
| Bazarr | `lscr.io/linuxserver/bazarr` | ✅ | ~100MB |
| qBittorrent | `lscr.io/linuxserver/qbittorrent` | ✅ | ~80MB idle |
| Jellyseerr | `lscr.io/linuxserver/jellyseerr` | ✅ | ~150MB |
| Gluetun | `qmcgaw/gluetun` | ✅ | ~50MB |
| **Total** | | | **~1GB** |

---

## Verification Checklist

### Immich (or PhotoPrism)

| Check | How to Verify |
|-------|--------------|
| PostgreSQL running | `kubectl get pods -n immich -l app.kubernetes.io/name=postgresql` → 1/1 Running |
| Redis running | `kubectl get pods -n immich -l app.kubernetes.io/name=redis` → 1/1 Running |
| Immich server running | `kubectl get pods -n immich -l app.kubernetes.io/name=immich-server` → 1/1 Running |
| ML service (if enabled) | `kubectl get pods -n immich -l app.kubernetes.io/name=immich-machine-learning` → 1/1 Running |
| Ingress accessible | `curl -k https://photos.homelab.local` → 200 or redirect |
| NFS mount working | `kubectl exec -n immich deploy/immich-server -- ls /photos/library` → files visible |
| `/dev/shm` configured | `kubectl exec -n immich postgresql-0 -- df -h /dev/shm` → ≥ 1Gi |

### ARR Stack (External VM)

| Check | How to Verify |
|-------|--------------|
| Docker running on VM | `ssh arr-media-vm 'docker ps'` → all containers healthy |
| Gluetun VPN connected | Check Gluetun logs for "connected" or check torrent IP |
| Services reachable from LAN | `curl http://arr-media-vm:8989` → Sonarr UI |
| Traefik routing works | `curl -k https://sonarr.homelab.local` → Sonarr UI via K3s ingress |
| cert-manager TLS valid | Browser shows valid cert (no warnings) |

---

## Official References

- [Immich Documentation](https://immich.app/docs/overview/introduction)
- [Immich Helm Chart (OCI)](https://github.com/immich-app/immich-charts)
- [Immich ARM64/Pi5 Setup](https://immich.app/docs/guides/raspberry-pi-5)
- [PhotoPrism Documentation](https://docs.photoprism.app/)
- [PhotoPrism Helm Chart](https://charts.photoprism.app)
- [LinuxServer.io Images (multi-arch)](https://docs.linuxserver.io/images/)
- [Gluetun VPN Client (ARM64)](https://github.com/qdm12/gluetun)
- [Traefik ExternalName Services](https://doc.traefik.io/traefik/routing/providers/kubernetes-crd/#kind-ingressroute)
