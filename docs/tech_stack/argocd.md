# ArgoCD: Declarative GitOps for Kubernetes

> **Official site:** [argo-cd.readthedocs.io](https://argo-cd.readthedocs.io/)
> **GitHub:** [argoproj/argo-cd](https://github.com/argoproj/argo-cd) · **License:** Apache 2.0
> **CNCF Status:** Graduated

## Overview

ArgoCD is a **declarative GitOps continuous delivery tool** for Kubernetes.
It continuously monitors Git repositories and reconciles the **desired state**
(manifests in Git) with the **live state** (what's running in the cluster).

## Core Concepts

### The GitOps Loop

```
 ┌──────────┐     ┌──────────┐     ┌──────────────┐
 │  Git Repo │────►│  ArgoCD  │────►│  Kubernetes   │
 │ (desired) │     │ compare  │     │  Cluster      │
 │          │     │   & sync │     │  (live)       │
 └──────────┘     └────┬─────┘     └───────┬───────┘
       ▲               │                   │
       └───────────────┴───────────────────┘
              feedback loop: status, health, diffs
```

### Resource Model

| Resource | Kind | Purpose |
|----------|------|---------|
| **Application** | `Application` CRD | Groups K8s resources defined by a Git source |
| **AppProject** | `AppProject` CRD | Logical grouping with RBAC, source/dest restrictions |
| **Repository** | Secret | Credentials for private Git repos and Helm registries |
| **Cluster** | Secret | Credentials for external K8s clusters |

### Application States

```
  Desired State (Git)              Live State (Cluster)
  ┌─────────────────┐              ┌─────────────────┐
  │ app: v2          │              │ app: v1          │
  │ replicas: 3      │   compare    │ replicas: 2      │
  │ image: nginx:1.25│ ◄──────────► │ image: nginx:1.24│
  └─────────────────┘              └─────────────────┘
                                          │
                               ┌──────────▼──────────┐
                               │  Sync Status         │
                               │  OutOfSync           │
                               │  Health: Progressing │
                               └─────────────────────┘
```

### Sync Status vs Health Status

| Status | Meaning | Example |
|--------|---------|---------|
| **Synced** | Live state matches desired state in Git | No diff detected |
| **OutOfSync** | Live state differs from Git | Someone ran `kubectl edit` |
| **Unknown** | Cannot determine state | Git repo unreachable |
| **Healthy** | All resources running correctly | Pods Ready, endpoints available |
| **Progressing** | Resources not yet healthy | Deployment rolling out |
| **Degraded** | Resources unhealthy | Pod CrashLoopBackOff |
| **Missing** | Resources not found | App was deleted |
| **Suspended** | App is paused | Manual or scheduled pause |

## Architecture

```
 ┌─────────────────────────────────────────────────────────────────┐
 │                    ArgoCD (argocd namespace)                     │
 │                                                                  │
 │  ┌──────────────────┐  ┌──────────────────┐  ┌───────────────┐ │
 │  │   API Server     │  │   Repo Server    │  │  Application  │ │
 │  │                  │  │                  │  │  Controller   │ │
 │  │ • Web UI         │  │ • Git cache      │  │               │ │
 │  │ • gRPC/REST API  │  │ • Helm render    │  │ • Compare     │ │
 │  │ • Auth (SSO/RBAC)│  │ • Kustomize build│  │   desired vs  │ │
 │  │ • Audit logging  │  │ • Config mgmt    │  │   live state  │ │
 │  │                  │  │   plugins        │  │ • Detect      │ │
 │  └────────┬─────────┘  └────────┬─────────┘  │   OutOfSync   │ │
 │           │                     │             │ • Invoke hooks│ │
 │           │                     │             │ • Trigger sync│ │
 │           └─────────────────────┼─────────────┤               │ │
 │                                 │             └───────┬───────┘ │
 │                                 ▼                     │         │
 │                      ┌──────────────────┐            │         │
 │                      │  Git Repository  │◄───────────┘         │
 │                      │  (GitHub)        │  watches & compares  │
 │                      └──────────────────┘                      │
 └─────────────────────────────────────────────────────────────────┘
```

**Component details:**

| Component | Role |
|-----------|------|
| **API Server** | Web UI, CLI, CI/CD integration; auth delegation; RBAC enforcement |
| **Repo Server** | Maintains local Git cache; renders manifests from Helm/Kustomize/plain YAML |
| **Application Controller** | Continuous reconciliation loop; compares states; triggers syncs |
| **Redis** | Cache for application state and repository metadata |
| **Dex** | Optional OIDC identity provider for SSO |

## Key Features

### 1. Sync Waves and Phases

Control the order of resource application:

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "-1"  # Lower numbers sync first
```

**Ordering precedence:**
1. Phase (PreSync → Sync → PostSync)
2. Wave number (negative → 0 → positive)
3. Kind (Namespaces first, then other resources)
4. Name (alphabetical)

### 2. Sync Policies

```yaml
syncPolicy:
  automated:
    prune: true        # Delete resources removed from Git
    selfHeal: true     # Auto-correct drift from Git state
    allowEmpty: true   # Allow apps with no resources
  syncOptions:
    - CreateNamespace=true         # Auto-create target namespace
    - ServerSideApply=true         # Use kubectl --server-side
    - PrunePropagationPolicy=foreground
    - ApplyOutOfSyncOnly=true      # Only sync changed resources
    - Validate=false               # Skip schema validation
```

### 3. Server-Side Apply (SSA)

For self-managed apps or resources with large annotations:

```yaml
syncPolicy:
  syncOptions:
    - ServerSideApply=true  # Required for ArgoCD managing itself
```

SSA tracks **field ownership** declaratively, preventing conflicts when multiple
managers modify the same resource. Essential for the App-of-Apps pattern where
the root app manages child Application CRDs.

### 4. Health Checks

ArgoCD has built-in health checks for standard K8s resources:

| Resource | Healthy when |
|----------|-------------|
| Deployment | `Available=True`, all replicas ready |
| StatefulSet | `currentReplicas == replicas` |
| DaemonSet | `numberReady == desiredNumberScheduled` |
| Service | Endpoints exist for all ports |
| Ingress | LoadBalancer hostname assigned |
| Pod | All containers Ready |

Custom health checks can be defined via Lua scripts in `argocd-cm` ConfigMap.

### 5. Ignore Differences

Skip specific fields during comparison:

```yaml
ignoreDifferences:
  - group: apps
    kind: Deployment
    jsonPointers:
      - /status/terminatingReplicas    # Ignore K8s 1.35 field
  - group: argoproj.io
    kind: Application
    jsonPointers:
      - /metadata/labels/argocd.argoproj.io~1instance  # Runtime label
```

## Best Practices

### App-of-Apps Pattern

```yaml
# Root Application: creates child apps from a directory
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: homelab-apps
  namespace: argocd
spec:
  project: default
  source:
    path: platform/argocd/apps
    repoURL: https://github.com/user/repo
    targetRevision: HEAD
  destination:
    namespace: argocd
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

**Child apps** are YAML files in the source directory. ArgoCD auto-discovers and manages them.

### Self-Managed ArgoCD

When ArgoCD manages its own installation:

```yaml
# platform/argocd/apps/argocd.yaml
spec:
  source:
    chart: argo-cd
    repoURL: https://argoproj.github.io/argo-helm
    targetRevision: 9.5.15   # Match installed version exactly
  syncPolicy:
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true  # Critical: prevents field ownership conflicts
```

> **⚠️ Important:** Always set `targetRevision` to match the **currently installed**
> chart version. A mismatch causes a downgrade or upgrade that can break ArgoCD
> itself mid-sync.

### AppProject Scope

Restrict what child apps can do:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: platform
  namespace: argocd
spec:
  sourceRepos:
    - 'https://github.com/user/repo'
    - 'https://charts.jetstack.io'
  destinations:
    - namespace: cert-manager
      server: https://kubernetes.default.svc
  clusterResourceWhitelist:
    - group: '*'
      kind: '*'
```

## Security Considerations

| Concern | Mitigation |
|---------|-----------|
| **Admin access** | Change default admin password; enable SSO/OIDC |
| **RBAC** | Use `policy.csv` with least-privilege roles |
| **Git credentials** | Store as K8s Secrets; never in plain config |
| **Self-managed app** | Can modify its own ConfigMap: risk of lockout |
| **Prune** | Can delete resources when files removed from Git |
| **Webhook exposure** | Use TLS; restrict to known Git providers |
| **Repository access** | Use deploy keys with read-only scope |

## Configuration in This Project

### Bootstrap (applied once)

```yaml
# platform/argocd/bootstrap/argocd-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: homelab-apps
  namespace: argocd
spec:
  source:
    path: platform/argocd/apps
    repoURL: https://github.com/<GITHUB_USER>/<REPO_NAME>
    targetRevision: HEAD
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
  ignoreDifferences:
    - group: argoproj.io
      kind: Application
      jsonPointers:
        - /metadata/labels/argocd.argoproj.io~1instance
```

### Sync Wave Ordering

| Wave | App | Reason |
|------|-----|--------|
| -2 | AppProjects (static) | Must exist before child apps |
| -1 | argocd | Self-managed; deploys first |
| 0 | metallb | CRDs needed before config |
| 1 | metallb-config, traefik, cert-manager | No ordering dependency |

## Official References

- [Documentation](https://argo-cd.readthedocs.io/en/stable/)
- [Architecture](https://argo-cd.readthedocs.io/en/stable/operator-manual/architecture/)
- [App-of-Apps](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/)
- [Sync Waves](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/)
- [Server-Side Apply](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/#server-side-apply)
- [Health Checks](https://argo-cd.readthedocs.io/en/stable/operator-manual/health/)
- [RBAC Configuration](https://argo-cd.readthedocs.io/en/stable/operator-manual/rbac/)
- [Helm Chart](https://github.com/argoproj/argo-helm/tree/main/charts/argo-cd)
