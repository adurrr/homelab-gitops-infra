# External Secrets Operator: Kubernetes Secrets Abstraction

> **Name:** [external-secrets.io](https://external-secrets.io/latest/) · **GitHub:** [external-secrets/external-secrets](https://github.com/external-secrets/external-secrets) · **Helm chart:** [external-secrets/deploy/charts/external-secrets](https://github.com/external-secrets/external-secrets/tree/main/deploy/charts/external-secrets)
> **CNCF Status:** Incubating

## Overview

**External Secrets Operator (ESO)** synchronizes secrets from external APIs into Kubernetes. It reads secrets from providers such as SealedSecrets, HashiCorp Vault, AWS Secrets Manager, GCP Secret Manager, Azure Key Vault, and 1Password, then injects them as native `kind: Secret` resources. Applications read the K8s Secret — they never know about the backend.

In this project, ESO serves as an **abstraction layer** that decouples applications from the underlying secret provider. Today it reads from SealedSecrets; tomorrow it can switch to Vault without changing a single application manifest.

## How It Works

```
                        ┌──────────────────────────────────────┐
                        │            kube-apiserver             │
                        │                                      │
                        │  ┌────────────────────────────────┐  │
                        │  │        ExternalSecret CR       │  │
                        │  │                                │  │
                        │  │  name: db-credentials          │  │
                        │  │  spec:                         │  │
                        │  │    refreshInterval: 1h         │  │
                        │  │    secretStoreRef:              │  │
                        │  │      name: sealed-secrets-store│  │
                        │  │    target:                      │  │
                        │  │      name: db-credentials       │  │
                        │  │    data:                        │  │
                        │  │      - secretKey: password      │  │
                        │  │        remoteRef:               │  │
                        │  │          key: cluster/db/pass   │  │
                        │  └──────────┬─────────────────────┘  │
                        │             │                        │
                        └─────────────┼────────────────────────┘
                                      │
                                      ▼
                         ┌─────────────────────┐
                         │    ESO Controller    │
                         │  (external-secrets)  │
                         │                      │
                         │  Watches External-    │
                         │  Secret CRDs         │
                         └──────────┬──────────┘
                                    │
                                    ▼
                         ┌─────────────────────┐
                         │     SecretStore      │
                         │  (provider config)   │
                         │                      │
                         │  type: kubernetes    │
                         │  (wraps SealedSecrets)│
                         │                      │
                         │  Or type: vault      │
                         │  Or type: aws/secrets │
                         │  manager              │
                         └──────────┬──────────┘
                                    │
                      ┌─────────────┼─────────────┐
                      │             │              │
                      ▼             ▼              ▼
              ┌────────────┐ ┌────────────┐ ┌────────────┐
              │ Sealed-    │ │   Vault    │ │  AWS SM    │  ...
              │ Secrets    │ │            │ │            │
              │ (current)  │ │ (future)   │ │ (optional) │
              └────────────┘ └────────────┘ └────────────┘
                      │
                      ▼
              ┌─────────────────────┐
              │   K8s Secret        │
              │   (kind: Secret)    │
              │                     │
              │   created/updated   │
              │   by ESO            │
              └──────────┬──────────┘
                         │
                         ▼
              ┌─────────────────────┐
              │   Pod mounts        │
              │   Secret as env/    │
              │   volume            │
              └─────────────────────┘
```

### Migration Path

```
Before:  SealedSecret CR → sealed-secrets controller → K8s Secret → Pod
After:   ExternalSecret CR → ESO → SecretStore(SealedSecrets) → K8s Secret → Pod
Future:  ExternalSecret CR → ESO → SecretStore(Vault) → Vault → K8s Secret → Pod
```

The **SecretStore** is the only thing that changes. The `ExternalSecret` spec and the Pod spec stay identical.

## Key Features

### 1. Multi-Provider Backend

Supports 20+ providers including:

| Provider | SecretStore Type | Status |
|----------|-----------------|--------|
| SealedSecrets | `kubernetes` | Current |
| HashiCorp Vault | `vault` | Planned (future) |
| AWS Secrets Manager | `aws/secretsmanager` | Optional |
| GCP Secret Manager | `gcpsm` | Optional |
| Azure Key Vault | `azurekv` | Optional |
| 1Password | `onepassword` | Optional |

### 2. Refresh Interval

Secrets are automatically re-synced on a schedule defined by `refreshInterval`:

```yaml
spec:
  refreshInterval: 1h    # Re-check provider every hour
  # Set to 0 to disable refresh (static secret)
```

### 3. CreationPolicy

Controls how ESO manages the target K8s Secret:

| Policy | Behavior |
|--------|----------|
| `Owner` (default) | ESO creates the Secret and manages its lifecycle. If the ExternalSecret is deleted, the Secret is deleted. |
| `Merge` | ESO adds/updates keys on an existing Secret without taking ownership. |
| `Orphan` | ESO creates the Secret but does not delete it when the ExternalSecret is removed. |

### 4. PushSecret

Reverse sync — push K8s Secrets back to an external provider:

```yaml
apiVersion: external-secrets.io/v1alpha1
kind: PushSecret
metadata:
  name: push-my-secret
spec:
  secretStoreRefs:
    - name: vault-backend
  data:
    - match:
        secretKey: my-key
        remoteRef:
          remoteKey: /path/in/vault
```

Useful for bootstrapping external providers with existing secrets.

## Best Practices

- **Use `ClusterSecretStore` for shared backends**, `SecretStore` for namespace-scoped backends.
- **Set `refreshInterval` based on secret rotation cadence**: 1 hour for static secrets (API keys, certificates), 5 minutes for dynamic secrets (database credentials with TTLs).
- **Monitor `ExternalSecret` status conditions** for sync failures:
  ```bash
  kubectl get externalsecret -A -o json | \
    jq '.items[] | select(.status.conditions[].status != "True") | .metadata.name'
  ```
- **Keep SealedSecrets controller running during migration** — ESO wraps it, doesn't replace it.
- **ARM64 compatibility**: ESO provides multi-arch images with `linux/arm64` support.
- **Resource budget**: ~128MB RAM, ~50m CPU at idle. Brief spikes during large sync operations.
- **Pin the Helm chart version** to avoid unexpected CRD schema changes.

## Security Considerations

| Concern | Mitigation |
|---------|-----------|
| **SecretStore RBAC** | Restrict which ServiceAccounts can create SecretStore references; use `ClusterSecretStore` only for cluster-wide backends |
| **ESO ServiceAccount scope** | ESO's SA needs read access to external secrets — scope to minimum required paths |
| **Secrets in etcd** | K8s Secrets are stored in etcd (base64 encoded, not encrypted by default). Enable etcd encryption at rest if compliance requires it |
| **Credentials in Git** | Never commit SecretStore credentials in plaintext. Use SealedSecrets to encrypt the SecretStore's auth credentials |
| **RefreshInterval abuse** | Too-frequent refreshes can rate-limit the external provider. Minimum 1m recommended |
| **SecretStore namespace isolation** | A `SecretStore` in namespace A cannot be referenced by an `ExternalSecret` in namespace B. Use `ClusterSecretStore` for cross-namespace access |

## Configuration in This Project

```yaml
# platform/external-secrets/values.yaml (key settings)
installCRDs: true

resources:
  requests: { cpu: 50m, memory: 64Mi }
  limits:   { cpu: 200m, memory: 128Mi }

serviceMonitor:
  enabled: true                              # Scrape ESO metrics

webhook:
  port: 10250

certController:
  create: true                               # Auto-create webhook certs
```

### SecretStore Example (SealedSecrets provider)

```yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: sealed-secrets-store
  namespace: default
spec:
  provider:
    kubernetes:
      remoteNamespace: default
      server:
        caBundle: ""                          # Uses in-cluster CA
      auth:
        token:
          bearerToken:
            name: eso-token                   # SA token mounted as Secret
            key: token
```

### ExternalSecret Example

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: db-credentials
  namespace: default
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: sealed-secrets-store
    kind: SecretStore
  target:
    name: db-credentials                     # Target K8s Secret name
    creationPolicy: Owner
  data:
    - secretKey: password
      remoteRef:
        key: cluster/db/password              # Key in the external provider
```

## Official References

- [External Secrets Operator Documentation](https://external-secrets.io/latest/)
- [ESO Provider — Kubernetes (SealedSecrets)](https://external-secrets.io/latest/provider/kubernetes/)
- [ESO GitHub](https://github.com/external-secrets/external-secrets)
- [ESO Helm Chart](https://github.com/external-secrets/external-secrets/tree/main/deploy/charts/external-secrets)
- [ESO PushSecret](https://external-secrets.io/latest/api/pushsecret/)
- [ESO Best Practices](https://external-secrets.io/latest/introduction/best-practices/)
