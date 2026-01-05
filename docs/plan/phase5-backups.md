# Phase 5: Backup Infrastructure

> **Goal:** Automated cluster backup with MinIO (S3-compatible storage) and
> Velero (Kubernetes-native backup/restore). PVCs, K8s objects, and
> application configs get point-in-time recovery capability.

**Depends on:** Phase 2 (ArgoCD GitOps), Phase 4 (Kyverno, SealedSecrets)
**Duration:** 1 week
**New namespaces:** `minio`, `velero`
**Resource budget:** +1.1GB RAM, +600m CPU, +50Gi storage (growing)
**Architecture decisions:** [AD-010](../architecture.md#ad-010-velero-118--minio-for-cluster-backups)

---

## What Phase 5 Delivers

Two tightly coupled components that together provide cluster backup and restore:

| Component | Gap It Fixes | How |
|-----------|-------------|-----|
| **MinIO** | No object storage for backup data | S3-compatible API on local-path PVC. Single-node, 50Gi initial. |
| **Velero** | Zero backup for PVCs, K8s objects, or cluster state | Kopia file-system backup for volumes, resource export for cluster state |

### Architecture Diagram

```
┌──────────────────────────────────────────────────────────────────────────┐
│                            Backup Architecture                             │
│                                                                           │
│  ┌─────────────────────────────────────────────────────────────────────┐ │
│  │                     Velero (namespace: velero)                       │ │
│  │                                                                      │ │
│  │  ┌──────────────────┐    ┌──────────────────────────────────────┐  │ │
│  │  │  Velero Server    │    │  Node-Agent DaemonSet (per node)      │  │ │
│  │  │  ┌─────────────┐ │    │  ┌──────────────────────────────────┐ │  │ │
│  │  │  │ Schedule    │ │    │  │  Kopia uploader                  │ │  │ │
│  │  │  │ Controller  │ │    │  │  ├─ Walks pod filesystem         │ │  │ │
│  │  │  │             │ │    │  │  ├─ Deduplicates blocks           │ │  │ │
│  │  │  │ Triggers    │ │    │  │  └─ Uploads to MinIO S3 API      │ │  │ │
│  │  │  │ backup on   │ │    │  │                                  │ │  │ │
│  │  │  │ cron sched  │ │    │  │  Access: /var/lib/kubelet/pods   │ │  │ │
│  │  │  └──────┬──────┘ │    │  └──────────────────────────────────┘ │  │ │
│  │  │         │        │    │                                        │  │ │
│  │  │         ▼        │    │  Pod annotations trigger backup:        │  │ │
│  │  │  ┌─────────────┐ │    │  backup.velero.io/backup-volumes: data  │  │ │
│  │  │  │ Backup CR   │ │    │  ┌──────────────────────────────────┐ │  │ │
│  │  │  │ ┌─────────┐ │ │    │  │ PVC: loki-storage (50Gi)         │ │  │ │
│  │  │  │ │ K8s obj │ │ │    │  │ PVC: home-assistant (10Gi)       │ │  │ │
│  │  │  │ │ export  │ │ │    │  │ PVC: grafana (10Gi)              │ │  │ │
│  │  │  │ ├─────────┤ │ │    │  └──────────────────────────────────┘ │  │ │
│  │  │  │ │ Kopia   │─┼─┼────┼──► FSB backup of volume data          │  │ │
│  │  │  │ │ volume  │ │ │    │                                        │  │ │
│  │  │  │ │ backup  │ │ │    └────────────────────────────────────────┘  │ │
│  │  │  │ └─────────┘ │ │                                                 │ │
│  │  │  └──────┬──────┘ │                                                 │ │
│  │  └─────────┼────────┘                                                 │ │
│  │            │ S3 API (internal)                                        │ │
│  └────────────┼──────────────────────────────────────────────────────────┘ │
│               │                                                             │
│  ┌────────────▼──────────────────────────────────────────────────────────┐ │
│  │                     MinIO (namespace: minio)                           │ │
│  │                                                                        │ │
│  │  ┌──────────────────┐     ┌──────────────────────────────────────┐   │ │
│  │  │  MinIO Server     │     │  PVC: minio-data (50Gi, local-path)   │   │ │
│  │  │  ┌─────────────┐ │     │  ┌──────────────────────────────────┐ │   │ │
│  │  │  │ Buckets:    │ │     │  │ /data/                           │ │   │ │
│  │  │  │ velero/     │ │     │  │ ├── velero/ (backup data)        │ │   │ │
│  │  │  │   backups/  │ │     │  │ │   ├── backups/                 │ │   │ │
│  │  │  │   restic/   │ │     │  │ │   └── restic/                  │ │   │ │
│  │  │  └─────────────┘ │     │  └──────────────────────────────────┘ │   │ │
│  │  └──────────────────┘     └──────────────────────────────────────┘   │ │
│  └──────────────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## Component 1: MinIO; S3-Compatible Object Storage

### Why MinIO

Velero needs object storage. The options for an on-prem homelab are: MinIO (self-hosted S3), NFS (network filesystem), or a cloud provider (AWS S3, Backblaze B2). Cloud providers cost money and add an external dependency. NFS works but ties backup storage to a filesystem path rather than an API. MinIO gives me S3-compatible API on local-path storage, ARM64-native, single binary. See [AD-010](../architecture.md#ad-010-velero-118--minio-for-cluster-backups) for full comparison.

### Deployment

```yaml
# platform/minio/values.yaml
mode: standalone  # Single node is sufficient for homelab backup volume
image:
  tag: "RELEASE.2025-09-07T16-13-09Z"  # Pin to specific release

resources:
  requests: { cpu: 200m, memory: 256Mi }
  limits:   { cpu: 1000m, memory: 512Mi }

persistence:
  enabled: true
  size: 50Gi  # Will grow as backup history accumulates
  storageClass: local-path

environment:
  MINIO_BROWSER: "on"  # Web console for manual bucket operations

ingress:
  enabled: true
  ingressClassName: traefik
  hosts:
    - minio-console.homelab.local

# Credentials via SealedSecret (NOT plaintext in Git)
auth:
  existingSecret: minio-credentials
```

**Post-install bucket creation:**
```bash
# Create the bucket Velero will use
kubectl exec -n minio deploy/minio -- mc alias set local http://localhost:9000 <access-key> <secret-key>
kubectl exec -n minio deploy/minio -- mc mb local/velero-backups
```

### Bucket Layout

```
velero-backups/
├── backups/           # Completed backup metadata (JSON)
│   ├── daily-cluster-20250619-040000/
│   ├── stateful-6h-20250619-060000/
│   └── ...
├── restic/            # Kopia/restic repository data (volume snapshots)
│   ├── config
│   ├── data/
│   ├── index/
│   └── ...
└── metadata/          # Velero internal state
```

---

## Component 2: Velero; Kubernetes Backup and Restore

### Why Velero

Velero is the CNCF-graduated standard for Kubernetes backup. It knows about K8s objects (Deployments, Services, ConfigMaps, PVCs) and can export them. The Kopia integration (default since v1.12) handles file-system backup of PVC data when CSI snapshots aren't available; which is my case, since local-path has no CSI driver. See [AD-010](../architecture.md#ad-010-velero-118--minio-for-cluster-backups) for full details.

### Critical ARM64 Configuration

The Velero Helm chart's CRD upgrade job runs a `kubectl` container. The default image from Bitnami had ARM64 issues in older versions. This is a hard blocker; without the fix, the install fails with `exec format error`.

```yaml
# platform/velero/values.yaml; CRITICAL ARM64 FIX
kubectl:
  image:
    repository: docker.io/bitnami/kubectl
    tag: "1.31.1"  # ≥ 1.25 required for ARM64
```

### Deployment

```yaml
# platform/velero/values.yaml
image:
  repository: velero/velero
  tag: v1.18.1
  pullPolicy: IfNotPresent

resources:
  requests: { cpu: 100m, memory: 256Mi }
  limits:   { cpu: 1000m, memory: 512Mi }

# Node-agent for file-system backup (replaces deprecated restic)
nodeAgent:
  enabled: true
  podVolumePath: /var/lib/kubelet/pods  # Path to pod volumes on K3s nodes
  podResources:
    requests: { cpu: 500m, memory: 512Mi }
    limits:   { cpu: 1000m, memory: 1Gi }

# MinIO S3 configuration
configuration:
  provider: aws  # Works for ANY S3-compatible backend
  backupStorageLocation:
    - name: default
      provider: aws
      bucket: velero-backups
      prefix: velero
      config:
        region: minio
        s3ForcePathStyle: "true"
        s3Url: http://minio.minio.svc.cluster.local:9000
  volumeSnapshotLocation: []  # No CSI; no VolumeSnapshots

# Kopia for file-system backup (default since v1.12)
defaultVolumesToFsBackup: true  # Back up ALL PVC content

# Credentials via SealedSecret
credentials:
  useSecret: true
  secretContents:
    cloud: |
      [default]
      aws_access_key_id=minioadmin
      aws_secret_access_key=minioadmin

# Plugin init container (required for S3 provider)
initContainers:
  - name: velero-plugin-for-aws
    image: velero/velero-plugin-for-aws:v1.13.1
    volumeMounts:
      - name: plugins
        mountPath: /target
```

### Backup Schedules

Two schedules target different data at different RPOs:

```yaml
# platform/velero/schedules/daily-cluster.yaml
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: daily-cluster
  namespace: velero
spec:
  schedule: "0 4 * * *"  # 4 AM daily
  template:
    includedNamespaces:
      - '*'  # All namespaces
    excludedNamespaces:
      - velero       # Don't back up backup data recursively
      - kube-system  # K3s system components; recreated by K3s, not worth backing up
    ttl: 720h        # 30 days retention
    defaultVolumesToFsBackup: true

---
# platform/velero/schedules/stateful-6h.yaml
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: stateful-6h
  namespace: velero
spec:
  schedule: "0 */6 * * *"  # Every 6 hours
  template:
    includedNamespaces:
      - monitoring       # Prometheus, Loki, Grafana PVCs
      - home-assistant   # HA SQLite database
    ttl: 168h            # 7 days retention
    defaultVolumesToFsBackup: true
```

### What Gets Backed Up (and What Doesn't)

| Workload | Backup Method | RPO | Why |
|----------|--------------|-----|-----|
| Prometheus TSDB (PVC) | Kopia FSB | 6h | Metrics are re-scrapable; older data less critical |
| Loki chunks (PVC) | Kopia FSB | 6h | Log loss acceptable at this RPO |
| Grafana config (PVC) | Kopia FSB | 24h | Dashboards in Git; PVC is dashboards + DB preferences |
| Home Assistant (PVC) | Kopia FSB | 6h | SQLite database; critical, tighter RPO |
| All K8s objects | Resource export | 24h | Deployments, ConfigMaps, Services, etc. |
| **NOT backed up**: | | | |
| Media files (Immich) | NAS snapshot | Daily | Too large for Velero (500GB+) |
| Download temp files | Not worth it | N/A | Transient data |
| kube-system pods | Not backed up | N/A | K3s recreates these on install |

### PVC Backup: How Kopia Works with local-path

local-path provisioner has no CSI driver; no `VolumeSnapshot` support. Velero falls back to file-system backup (FSB) via Kopia:

1. Velero node-agent DaemonSet runs on every node
2. It has access to `/var/lib/kubelet/pods` on the host (K3s stores pod volumes here)
3. During backup, Kopia walks the filesystem inside the pod's volume mount
4. It deduplicates blocks across all volumes and uploads to MinIO S3
5. During restore, Velero creates the PVC, then Kopia restores files into it

**Limitation:** FSB is slower than CSI snapshots (hours vs seconds for large volumes). The first backup of a 50Gi Loki PVC will take significant time. Subsequent backups are incremental (only changed blocks).

### Restore Verification

```bash
# Test restore; do this after first backup
# 1. Create a test namespace
kubectl create ns restore-test

# 2. Restore the latest daily backup into test namespace
velero restore create --from-backup daily-cluster-<timestamp> \
  --namespace-mappings home-assistant:restore-test \
  --include-namespaces home-assistant

# 3. Verify restored PVC data
kubectl exec -n restore-test deploy/home-assistant -- ls /config

# 4. Verify restored K8s objects
kubectl get all -n restore-test

# 5. Clean up
velero restore delete test-restore
kubectl delete ns restore-test
```

**⚠️ Critical:** An untested backup is NOT a backup; it's a hope. Run this restore test after the first full backup and after any major Velero version upgrade.

---

## Deployment Sequence

```
  Step 1: Deploy MinIO                        Step 2: Create bucket
  ┌─────────────────────────┐                ┌───────────────────────────────┐
  │ ArgoCD syncs minio app  │                │ kubectl exec -n minio deploy/ │
  │ helm install minio      │                │   minio -- mc mb local/       │
  │ namespace: minio         │                │   velero-backups              │
  │ PVC: 50Gi local-path     │                │                               │
  └───────────┬─────────────┘                └───────────────┬───────────────┘
              │                                              │
              ▼                                              ▼
  Step 3: Deploy Velero                       Step 4: Create backup schedules
  ┌─────────────────────────┐                ┌───────────────────────────────┐
  │ ArgoCD syncs velero app  │                │ kubectl apply -f:              │
  │ helm install velero      │                │  schedules/daily-cluster.yaml │
  │ namespace: velero        │                │  schedules/stateful-6h.yaml   │
  │ kubectl image: 1.31.1    │                │                               │
  │ provider: aws (MinIO)    │                │ Verify:                       │
  └───────────┬─────────────┘                │  velero schedule get           │
              │                              └───────────────┬───────────────┘
              ▼                                              │
  Step 5: Run first backup                                   │
  ┌─────────────────────────┐                               │
  │ velero backup create     │                               │
  │   initial --wait         │◄──────────────────────────────┘
  │                           │
  │ velero backup describe    │
  │   initial --details       │
  └───────────┬─────────────┘
              │
              ▼
  Step 6: Test restore
  ┌─────────────────────────┐
  │ Restore to test namespace │
  │ Verify PVC data restored  │
  │ Verify K8s objects exist  │
  │ Clean up test resources   │
  └─────────────────────────┘
```

---

## Verification Checklist

| Check | How to Verify |
|-------|--------------|
| MinIO running | `kubectl get pods -n minio` → 1/1 Running |
| MinIO bucket exists | `kubectl exec -n minio deploy/minio -- mc ls local/` → `velero-backups/` |
| Velero server running | `kubectl get pods -n velero -l deploy=velero` → 1/1 Running |
| Node-agent running on all nodes | `kubectl get pods -n velero -l name=node-agent` → 2/2 Running (one per node) |
| Backup location configured | `velero backup-location get` → Available |
| First backup completes | `velero backup create initial --wait` → Phase: Completed |
| Second backup is faster (incremental) | Compare `velero backup describe initial` duration with second backup |
| Restore works | Restore to test namespace, verify data integrity |
| Backup data in MinIO | `kubectl exec -n minio deploy/minio -- mc ls local/velero-backups/` → populated directories |

---

## Risks and Rollback

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| CRD install fails (ARM64 kubectl) | Medium | High | Pin `kubectl.image.tag` to `1.31.1` or later. Verified in values.yaml. |
| First backup OOMs (large PVC) | Medium on 4GB nodes | Medium | Set `nodeAgent.podResources.limits.memory: 1Gi`. First backup is always largest. |
| MinIO disk fills up | High over time | Low | TTL on backup schedules (30d cluster, 7d stateful). Monitor PVC usage via existing PVC alerts. |
| Restore doesn't work | Low (if tested) | Critical | Test restore immediately after first backup. Schedule quarterly restore tests. |
| Velero upgrade breaks ARM64 | Low | Medium | Pin image tags. Test on non-production namespace first. |

**Recovery scenario; complete cluster loss:**
1. Reinstall K3s on both nodes (Phase 1)
2. Reinstall ArgoCD (Phase 2 bootstrap)
3. Deploy MinIO with PVC (empty)
4. Deploy Velero pointing at empty MinIO
5. Use `mc` to copy backup data from external storage to MinIO bucket
6. Run `velero restore create --from-backup latest-daily-cluster`
7. All K8s objects and PVC data are restored

**⚠️ This recovery depends on having the MinIO `minio-credentials` SealedSecret in Git.** Without it, you can't authenticate to the restored MinIO instance. The SealedSecret controller key must also be backed up (it's in the K3s data directory, which survives node reboots but not complete disk failure). Document the key backup location in your off-site recovery instructions.

---

## Official References

- [Velero Documentation](https://velero.io/docs/v1.18/)
- [Velero File System Backup (Kopia)](https://velero.io/docs/v1.18/file-system-backup/)
- [Velero Helm Chart](https://github.com/vmware-tanzu/helm-charts/tree/main/charts/velero)
- [Velero Restic Deprecation Notice](https://velero.io/docs/v1.18/file-system-backup/#restic-deprecation)
- [Velero ARM64 Multi-arch PR](https://github.com/vmware-tanzu/velero/pull/6085)
- [MinIO Documentation](https://min.io/docs/minio/kubernetes/upstream/)
- [MinIO Docker Hub (multi-arch)](https://hub.docker.com/r/minio/minio/tags)
- [MinIO Kubernetes Deployment](https://min.io/docs/minio/kubernetes/upstream/operations/install-deploy-manage/deploy-minio-single-node-multi-drive.html)
