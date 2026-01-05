# Velero: Kubernetes Backup and Restore

> **Velero:** [velero.io](https://velero.io/) · **GitHub:** [vmware-tanzu/velero](https://github.com/vmware-tanzu/velero) · **Helm Chart:** [vmware-tanzu/helm-charts](https://github.com/vmware-tanzu/helm-charts) · **CNCF Status:** Graduated

## Overview

Velero backs up and restores Kubernetes clusters. It captures both Kubernetes
objects (Deployments, Services, ConfigMaps, PersistentVolumeClaims) and
persistent volume data. For clusters without CSI snapshot support (like those
using local-path provisioner), Velero's **Kopia** integration provides
file-system backup (FSB) — walking the pod filesystem and uploading changed
blocks to object storage. Velero v1.12+ uses Kopia as the default uploader;
restic is deprecated and will be removed in v1.19+.

In this project, Velero stores backups in MinIO (S3-compatible object storage)
running on the same cluster. Two schedules provide different RPOs: a daily
cluster-wide backup (30-day TTL) and a 6-hour stateful workload backup (7-day
TTL). All PVC data is backed up via Kopia FSB since local-path has no CSI
driver.

## How It Works

```
 ┌──────────────────────────────────────────────────────────────────────────┐
 │                         Velero Architecture                                │
 │                                                                           │
 │  ┌────────────────────────────────────────────────────────────────────┐  │
 │  │                      velero namespace                                │  │
 │  │                                                                      │  │
 │  │  ┌─────────────────────────┐     ┌──────────────────────────────┐  │  │
 │  │  │     Velero Server       │     │     Node-Agent DaemonSet      │  │  │
 │  │  │      (Deployment)       │     │       (per node)              │  │  │
 │  │  │                         │     │                              │  │  │
 │  │  │  Schedule fires (cron)  │     │  ┌────────────────────────┐ │  │  │
 │  │  │         │               │     │  │      Kopia FSB         │ │  │  │
 │  │  │         ▼               │     │  │  ┌──────────────────┐  │ │  │  │
 │  │  │  ┌──────────────┐      │     │  │  │ Walk pod volume   │  │ │  │  │
 │  │  │  │  Backup CR    │      │     │  │  │ filesystem        │  │ │  │  │
 │  │  │  │  ┌──────────┐ │      │     │  │  ├──────────────────┤  │ │  │  │
 │  │  │  │  │ K8s obj  │ │      │     │  │  │ Deduplicate      │  │ │  │  │
 │  │  │  │  │ export   │─┼──────┼─────┼──┼──┤ blocks           │  │ │  │  │
 │  │  │  │  │ (JSON)   │ │      │     │  │  ├──────────────────┤  │ │  │  │
 │  │  │  │  ├──────────┤ │      │     │  │  │ Upload to MinIO  │  │ │  │  │
 │  │  │  │  │ Kopia    │─┼──────┼─────┼──┼──┤ S3               │  │ │  │  │
 │  │  │  │  │ metadata │ │      │     │  │  └──────────────────┘  │ │  │  │
 │  │  │  │  └──────────┘ │      │     │  └────────────────────────┘ │  │  │
 │  │  │  └───────┬───────┘      │     │                              │  │  │
 │  │  └──────────┼──────────────┘     └──────────────────────────────┘  │  │
 │  │             │ S3 API (internal)                                    │  │
 │  └─────────────┼──────────────────────────────────────────────────────┘  │
 │                │                                                          │
 │  ┌─────────────▼────────────────────────────────────────────────────────┐ │
 │  │                       MinIO (namespace: minio)                        │ │
 │  │  ┌──────────────────┐   ┌────────────────────────────────────────┐  │ │
 │  │  │  velero-backups/  │   │  PVC: minio-data (50Gi, local-path)   │  │ │
 │  │  │  ├── backups/     │   │  ┌──────────────────────────────────┐ │  │ │
 │  │  │  ├── restic/      │   │  │ /export/velero-backups/          │ │  │ │
 │  │  │  └── metadata/    │   │  │ ├── backups/  (K8s object JSON)  │ │  │ │
 │  │  └──────────────────┘   │  │ ├── restic/   (Kopia block data)  │ │  │ │
 │  │                         │  │ └── metadata/ (Velero state)      │ │  │ │
 │  │                         │  └──────────────────────────────────┘ │  │ │
 │  └─────────────────────────┴────────────────────────────────────────┘  │
 └──────────────────────────────────────────────────────────────────────────┘
```

### Backup Flow

1. **Schedule fires** — A `Schedule` CR (e.g., `daily-cluster` at 4 AM) triggers
   a new `Backup` CR
2. **Object export** — Velero server uses the Kubernetes API to export all
   matching K8s objects as JSON (Deployments, Services, PVCs, Secrets, etc.)
3. **FSB volume backup** — For pods annotated with
   `backup.velero.io/backup-volumes`, the node-agent runs Kopia to scan the
   volume's filesystem at `/var/lib/kubelet/pods/<pod-uid>/volumes/...`
4. **Kopia deduplication** — Kopia splits files into blocks, deduplicates by
   content hash, and compresses before upload
5. **Upload to MinIO** — Both the object JSON and Kopia block data are uploaded
   to the MinIO bucket via S3 API

### Restore Flow

1. **Restore CR created** — `velero restore create --from-backup <name>`
2. **Velero reads backup** — Fetches K8s object JSON and Kopia metadata from
   MinIO
3. **K8s objects created** — Velero re-creates Deployments, Services, PVCs
   in the target (or remapped) namespace
4. **Volume data restored** — node-agent runs Kopia to download blocks from
   MinIO and reconstruct files on the newly created PVC
5. **Deployment ready** — Once PVC data is restored, the pod starts with its
   original data

## Key Features

### 1. Backup Schedules — Cron-Driven with TTL

```yaml
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: daily-cluster
  namespace: velero
spec:
  schedule: "0 4 * * *"        # Daily at 4 AM
  template:
    ttl: 720h                  # 30 days retention
    defaultVolumesToFsBackup: true
    includedNamespaces: ["*"]
    excludedNamespaces:
      - velero
      - kube-system
```

### 2. Kopia File-System Backup (for Clusters Without CSI)

local-path provisioner has no CSI driver — Velero falls back to FSB via Kopia:

- **Before (CSI):** `VolumeSnapshot` CRD → CSI driver → cloud snapshot — seconds
- **After (FSB):** Node-agent reads `/var/lib/kubelet/pods` → Kopia walks
  filesystem → dedup → upload — minutes to hours for large volumes

Enable globally:
```yaml
defaultVolumesToFsBackup: true  # Velero helm value
```

Or per-pod via annotation:
```yaml
metadata:
  annotations:
    backup.velero.io/backup-volumes: data,config
```

### 3. Namespace Filtering

```bash
# Back up only specific namespaces
velero backup create app-backup --include-namespaces monitoring,home-assistant

# Exclude specific namespaces
velero backup create partial --exclude-namespaces kube-system,velero

# Back up specific resources
velero backup create pvc-only --include-resources persistentvolumeclaims
```

### 4. Pre/Post Backup Hooks

Run commands inside pods before/after backup for application-consistent snapshots:

```yaml
annotations:
  pre.hook.backup.velero.io/command: '["/bin/sh", "-c", "pg_dumpall > /tmp/dump.sql"]'
  pre.hook.backup.velero.io/container: postgres
  post.hook.backup.velero.io/command: '["/bin/sh", "-c", "rm /tmp/dump.sql"]'
  post.hook.backup.velero.io/container: postgres
```

### 5. Restore with Namespace Remapping

Restore into a different namespace for testing or migration:

```bash
velero restore create --from-backup daily-cluster-20250619-040000 \
  --namespace-mappings home-assistant:restore-test \
  --include-namespaces home-assistant
```

## Best Practices

### Kopia (Not Restic)

- **Use Kopia (default)** — restic is deprecated in v1.15+ and will be removed
  in v1.19+
- Kopia offers better performance, multi-repo support, and ongoing development
- Set `defaultVolumesToFsBackup: true` rather than per-pod annotations for
  cluster-wide coverage

### ARM64 Compatibility

- Pin the `kubectl` image to `bitnami/kubectl:≥1.25` — older versions have
  `exec format error` on ARM64 nodes
- The Velero server image (`velero/velero`) is multi-arch since v1.12
- Velero plugin images must also be multi-arch — `velero-plugin-for-aws` is

### Retention and Storage Growth

| Schedule | TTL | Scope | Storage Impact |
|----------|-----|-------|---------------|
| daily-cluster | 30 days | All namespaces | ~10-20 GiB/month |
| stateful-6h | 7 days | Stateful workloads | ~5-10 GiB/week |

Set TTL on schedules to prevent unbounded storage growth. Monitor MinIO PVC
usage via existing Prometheus PVC alerts.

### Test Restores

**Untested backup is NOT a backup.** After the first full backup completes:

```bash
kubectl create ns restore-test
velero restore create --from-backup daily-cluster-<ts> \
  --namespace-mappings <app>:restore-test \
  --include-namespaces <app>
kubectl get all -n restore-test
velero restore delete <restore-name>
kubectl delete ns restore-test
```

### What NOT to Back Up

| Data | Reason |
|------|--------|
| `kube-system` | K3s recreates these on install — waste of storage |
| `velero` namespace | Recursive backup of backup metadata |
| Media files >500GB (Immich, Nextcloud) | Too large for Velero FSB — use NAS snapshots |
| Transient scratch data | Not worth the storage cost |

## Security Considerations

| Concern | Mitigation |
|---------|-----------|
| **Broad RBAC** | Velero reads all resources and execs into pods — restrict who can create Backup CRs |
| **S3 credentials** | Stored as Kubernetes Secret in `velero` namespace — use SealedSecrets |
| **Privileged node-agent** | Access to `/var/lib/kubelet/pods` — restrict via PodSecurityAdmission |
| **Unencrypted backup data** | MinIO serves plain HTTP internally — enable MinIO TLS or encrypt at app level |
| **Secret exposure** | Secrets are backed up as K8s objects — ensure S3 bucket access is restricted |
| **RBAC escalation** | Restrict `velero.io` CRD create/update permissions to cluster-admins only |

## Configuration in This Project

```yaml
# platform/velero/values.yaml
image:
  repository: velero/velero
  tag: v1.18.1
  pullPolicy: IfNotPresent

resources:
  requests: { cpu: 100m, memory: 256Mi }
  limits:   { cpu: 1000m, memory: 512Mi }

nodeAgent:
  enabled: true
  podVolumePath: /var/lib/kubelet/pods
  podResources:
    requests: { cpu: 500m, memory: 512Mi }
    limits:   { cpu: 1000m, memory: 1Gi }

configuration:
  provider: aws                         # Works for ANY S3-compatible backend
  backupStorageLocation:
    - name: default
      provider: aws
      bucket: velero-backups
      prefix: velero
      config:
        region: minio
        s3ForcePathStyle: "true"
        s3Url: http://minio.minio.svc.cluster.local:9000
  volumeSnapshotLocation: []            # No CSI — no VolumeSnapshots

defaultVolumesToFsBackup: true          # Back up ALL PVC content via Kopia

kubectl:
  image:
    repository: docker.io/bitnami/kubectl
    tag: "1.31.1"                      # CRITICAL: ARM64 fix (≥ 1.25)

credentials:
  useSecret: true
  secretContents:
    cloud: |
      [default]
      aws_access_key_id=minioadmin
      aws_secret_access_key=minioadmin

initContainers:
  - name: velero-plugin-for-aws
    image: velero/velero-plugin-for-aws:v1.13.1
    volumeMounts:
      - name: plugins
        mountPath: /target
```

### Backup Schedules

```yaml
# platform/velero/schedules/daily-cluster.yaml
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: daily-cluster
  namespace: velero
spec:
  schedule: "0 4 * * *"                   # 4 AM daily
  template:
    includedNamespaces: ["*"]
    excludedNamespaces:
      - velero
      - kube-system
    ttl: 720h                             # 30 days retention
    defaultVolumesToFsBackup: true

---
# platform/velero/schedules/stateful-6h.yaml
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: stateful-6h
  namespace: velero
spec:
  schedule: "0 */6 * * *"                 # Every 6 hours
  template:
    includedNamespaces:
      - monitoring
      - home-assistant
    ttl: 168h                             # 7 days retention
    defaultVolumesToFsBackup: true
```

## Official References

- [Velero Documentation v1.18](https://velero.io/docs/v1.18/)
- [File System Backup (Kopia)](https://velero.io/docs/v1.18/file-system-backup/)
- [Backup Hooks](https://velero.io/docs/v1.18/backup-hooks/)
- [Restic Deprecation Notice](https://velero.io/docs/v1.18/file-system-backup/#restic-deprecation)
- [Velero Helm Chart](https://github.com/vmware-tanzu/helm-charts/tree/main/charts/velero)
- [ARM64 Multi-arch PR #6085](https://github.com/vmware-tanzu/velero/pull/6085)
- [Velero Plugin for AWS](https://github.com/vmware-tanzu/velero-plugin-for-aws)
