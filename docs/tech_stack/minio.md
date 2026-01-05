# MinIO: S3-Compatible Object Storage

> **MinIO:** [min.io](https://min.io/) · **GitHub:** [minio/minio](https://github.com/minio/minio) · **Docker Hub:** [minio/minio](https://hub.docker.com/r/minio/minio)

## Overview

MinIO is a high-performance, S3-compatible object storage server. It's a single
Go binary that speaks the S3 API — any tool that works with AWS S3 works with
MinIO. In this project, MinIO provides the object storage backend for Velero
backups. It runs as a single-node standalone instance with a local-path PVC.

For a homelab, MinIO is the natural choice: it is ARM64-native (single binary,
no JVM), needs minimal resources (256Mi RAM base), and provides the S3 API
that Velero expects. There is no need for a cloud S3 provider or an external
storage dependency when the backup target lives on the same cluster.

## How It Works

```
 ┌──────────────────────────────────────────────────────────────────────────┐
 │                       MinIO Architecture                                  │
 │                                                                           │
 │  ┌────────────────────────────────────────────────────────────────────┐  │
 │  │                       minio namespace                                │  │
 │  │                                                                      │  │
 │  │  ┌──────────────────────────┐                                       │  │
 │  │  │    MinIO Server Pod       │                                       │  │
 │  │  │                          │                                       │  │
 │  │  │  ┌────────────────────┐  │  TCP :9000 ──── Velero (S3 API)      │  │
 │  │  │  │   S3 API Engine     │◄─┼──────────────                        │  │
 │  │  │  │   (Go binary)       │  │              ┌─────────────────────┐ │  │
 │  │  │  ├────────────────────┤  │  TCP :9001 ────│ MinIO Console (UI)  │ │  │
 │  │  │  │   Web Console      │◄─┼──────────────  │ (Traefik ingress)   │ │  │
 │  │  │  │   (browser UI)     │  │                │ minio-console.      │ │  │
 │  │  │  └────────┬───────────┘  │                │ homelab.local       │ │  │
 │  │  │           │              │                └─────────────────────┘ │  │
 │  │  │           ▼              │                                       │  │
 │  │  │  ┌────────────────────┐  │                                       │  │
 │  │  │  │ /data (PVC mount)  │  │                                       │  │
 │  │  │  │                    │  │                                       │  │
 │  │  │  │ velero-backups/    │  │                                       │  │
 │  │  │  │ ├── backups/      │  │                                       │  │
 │  │  │  │ │   daily-.../    │  │   K8s object JSON (Velero exports)    │  │
 │  │  │  │ ├── restic/       │  │                                       │  │
 │  │  │  │ │   data/         │  │   Kopia block store (dedup chunks)    │  │
 │  │  │  │ │   index/        │  │                                       │  │
 │  │  │  │ └── metadata/     │  │   Velero internal state               │  │
 │  │  │  └────────────────────┘  │                                       │  │
 │  │  └──────────────────────────┘                                       │  │
 │  │                                                                      │  │
 │  │  ┌──────────────────────────────────────────────────────────────┐   │  │
 │  │  │  PVC: minio-data (50Gi, local-path)                           │   │  │
 │  │  │  storageClass: local-path, accessModes: [ReadWriteOnce]       │   │  │
 │  │  └──────────────────────────────────────────────────────────────┘   │  │
 │  └──────────────────────────────────────────────────────────────────────┘  │
 └──────────────────────────────────────────────────────────────────────────┘
```

### Bucket Layout

The Velero backup data is organized under a single bucket:

```
velero-backups/
├── backups/           # Completed backup metadata (JSON)
│   ├── daily-cluster-20250619-040000/
│   ├── stateful-6h-20250619-060000/
│   └── ...
├── restic/            # Kopia repository data (volume snapshots)
│   ├── config
│   ├── data/          # Deduplicated block storage
│   ├── index/         # Block index for lookups
│   └── ...
└── metadata/          # Velero internal state
```

## Key Features

### 1. S3-Compatible API

MinIO implements the Amazon S3 API — any S3 SDK or CLI tool works without
modification:

```bash
# Using AWS CLI
export AWS_ACCESS_KEY_ID=<key>
export AWS_SECRET_ACCESS_KEY=<secret>
aws --endpoint-url http://minio.minio.svc.cluster.local:9000 s3 ls s3://velero-backups/

# Using MinIO Client (mc) — installed in the MinIO pod
kubectl exec -n minio deploy/minio -- mc alias set local http://localhost:9000 <key> <secret>
kubectl exec -n minio deploy/minio -- mc ls local/velero-backups/
```

### 2. Standalone Mode

Single-node mode with local storage — no distributed consensus, no Erasure
Coding, no multi-drive striping:

- **Pros:** Simple, low resource usage (~200m CPU, 256Mi RAM), fast deployment
- **Cons:** No HA, no data redundancy at the storage layer (rely on PVC
  replication or Proxmox host disk)

For a homelab with <1TB backup data, standalone mode is the right choice.

### 3. Web Console (MinIO Console)

Browser-based UI for bucket management, file browsing, and access policy
configuration:

- URL: `https://minio-console.homelab.local`
- Authenticated with MinIO credentials (not cluster RBAC)
- Features: upload/download files, create/delete buckets, set bucket policies

### 4. Bucket Policies

Per-bucket access control with S3-style policy documents:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {"AWS": ["arn:aws:iam::velero:user/velero"]},
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": ["arn:aws:s3:::velero-backups/*"]
    }
  ]
}
```

### 5. Multi-Architecture

Official ARM64 images have been available since MinIO's earliest releases. No
special configuration needed — the `minio/minio` image manifest includes
`linux/amd64` and `linux/arm64` variants.

## Best Practices

### Standalone Is Enough for Homelab

Distributed MinIO (Erasure Coding, multi-drive) adds complexity without benefit
at this scale. With <1TB backup data and a single node, standalone mode works.
If the MinIO pod dies, Velero retries backup until MinIO returns.

### Pin the Release Tag

MinIO uses calendar versioning (`RELEASE.YYYY-MM-DDTHH-MM-SSZ`). Pin to a
specific release — avoid `:latest`:

```yaml
image:
  tag: "RELEASE.2025-09-07T16-13-09Z"
```

### TTL via Application, Not MinIO

Backup retention is controlled by Velero schedule TTL, not MinIO lifecycle
rules. MinIO does not manage object expiry — Velero deletes old backups after
TTL expires, and MinIO objects are removed as a side effect.

### Monitor PVC Usage

Backup data grows monotonically until TTL trims it. Track `kubelet_volume_stats_used_bytes`
for the MinIO PVC:

```promql
kubelet_volume_stats_used_bytes{persistentvolumeclaim="minio-data"}
```

Alert at 80% capacity — the PVC is 50Gi which fills faster than expected with
multiple daily backups.

### Manual Operations with `mc`

The MinIO Client (`mc`) is pre-installed in the Minio container image. Use it
for ad-hoc bucket management:

```bash
# List buckets
kubectl exec -n minio deploy/minio -- mc ls local/

# Create a bucket
kubectl exec -n minio deploy/minio -- mc mb local/velero-backups

# Check bucket size
kubectl exec -n minio deploy/minio -- mc du local/velero-backups

# Copy data (e.g., for off-site backup)
kubectl exec -n minio deploy/minio -- mc cp --recursive local/velero-backups/ /tmp/offsite/
```

## Security Considerations

| Concern | Mitigation |
|---------|-----------|
| **Access key exposure** | Store via SealedSecret (`minio-credentials`), never in plaintext Git |
| **HTTP only (no TLS)** | MinIO serves HTTP by default — expose externally only via Traefik with TLS termination |
| **Console UI auth** | Set strong password — separate from API credentials |
| **Network exposure** | NetworkPolicy: restrict port 9000 access to `velero` namespace only |
| **Data at rest** | MinIO data stored on local-path PVC — consider Proxmox host disk encryption (LUKS) |
| **Backup data access** | Anyone with MinIO credentials can read all backup data including Secrets |
| **No auth for internal calls** | Velero ↔ MinIO traffic uses HTTP with embedded credentials — ensure network isolation |

## Configuration in This Project

```yaml
# platform/minio/values.yaml
mode: standalone

image:
  repository: minio/minio
  tag: "RELEASE.2025-09-07T16-13-09Z"
  pullPolicy: IfNotPresent

resources:
  requests: { cpu: 200m, memory: 256Mi }
  limits:   { cpu: 1000m, memory: 512Mi }

persistence:
  enabled: true
  size: 50Gi
  storageClass: local-path
  accessMode: ReadWriteOnce

auth:
  existingSecret: minio-credentials      # SealedSecret — never plaintext

environment:
  MINIO_BROWSER: "on"                    # Enable web console
  MINIO_ROOT_USER: ""                    # Read from existingSecret
  MINIO_ROOT_PASSWORD: ""                # Read from existingSecret

ingress:
  enabled: true
  ingressClassName: traefik
  hosts:
    - minio-console.homelab.local
  tls:
    - hosts:
        - minio-console.homelab.local

# No bucket lifecycle rules — Velero manages object TTL
```

### Post-Install: Create the Velero Bucket

MinIO does not auto-create buckets. After the first deploy:

```bash
# Get credentials from the SealedSecret
kubectl get secret -n minio minio-credentials -o jsonpath='{.data.root-user}' | base64 -d
kubectl get secret -n minio minio-credentials -o jsonpath='{.data.root-password}' | base64 -d

# Set up mc alias and create bucket
kubectl exec -n minio deploy/minio -- mc alias set local http://localhost:9000 <key> <secret>
kubectl exec -n minio deploy/minio -- mc mb local/velero-backups
```

## Official References

- [MinIO Kubernetes Documentation](https://min.io/docs/minio/kubernetes/upstream/)
- [MinIO Linux Documentation](https://min.io/docs/minio/linux/)
- [MinIO Docker Hub Tags (multi-arch)](https://hub.docker.com/r/minio/minio/tags)
- [MinIO GitHub Repository](https://github.com/minio/minio)
- [MinIO Client (mc) Guide](https://min.io/docs/minio/linux/reference/minio-mc.html)
- [Single-Node Single-Drive Deployment](https://min.io/docs/minio/kubernetes/upstream/operations/install-deploy-manage/deploy-minio-single-node-multi-drive.html)
- [Bucket Policy Documentation](https://min.io/docs/minio/linux/administration/identity-access-management/policy-based-access-control.html)
