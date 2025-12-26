# Helm: The Kubernetes Package Manager

> **Official site:** [helm.sh](https://helm.sh/) · **Docs:** [helm.sh/docs](https://helm.sh/docs/)
> **GitHub:** [helm/helm](https://github.com/helm/helm) · **License:** Apache 2.0
> **CNCF Status:** Graduated

## Overview

Helm is the **package manager for Kubernetes**. It packages Kubernetes manifests
into reusable **charts**: versioned, shareable bundles of pre-configured K8s
resources. Think `apt`/`yum`/`brew` but for Kubernetes.

## How It Works

```
 ┌────────────────────────────────────────────────────────────┐
 │                    Helm Workflow                            │
 │                                                             │
 │  ┌──────────┐     ┌──────────┐     ┌──────────────────┐   │
 │  │  Chart   │     │  Helm    │     │   Kubernetes      │   │
 │  │          │     │          │     │   Cluster         │   │
 │  │ values   │────►│ template │────►│  ┌─────────────┐ │   │
 │  │ .yaml    │     │ engine   │     │  │ Deployment  │ │   │
 │  │          │     │          │     │  │ Service     │ │   │
 │  │ templates│     │ Go       │     │  │ ConfigMap   │ │   │
 │  │ /        │     │ templates│     │  │ Ingress     │ │   │
 │  │          │     │          │     │  └─────────────┘ │   │
 │  │ Chart    │     │ render + │     └──────────────────┘   │
 │  │ .yaml    │     │ values = │                              │
 │  └──────────┘     │ manifests│     ┌──────────────────┐   │
 │                   └──────────┘     │  Release (state) │   │
 │                                    │  stored as Secret │   │
 │                                    └──────────────────┘   │
 └────────────────────────────────────────────────────────────┘
```

## Core Concepts

| Concept | Description |
|---------|-------------|
| **Chart** | Package of pre-configured K8s resources (`Chart.yaml` + templates + values) |
| **Release** | Instance of a chart running in a cluster (named, versioned) |
| **Repository** | Collection of charts (e.g., `https://charts.bitnami.com/bitnami`) |
| **Values** | Configuration overrides (`values.yaml` or `--set`) |
| **Template** | Go template files in `templates/` directory |
| **Hook** | Special resources that run at specific lifecycle points |
| **Dependency** | Chart that another chart depends on (`Chart.yaml` dependencies) |

## Chart Structure

```
mychart/
├── Chart.yaml          # Chart metadata (name, version, description)
├── values.yaml         # Default configuration values
├── charts/             # Sub-charts (dependencies)
├── templates/          # Kubernetes manifest templates
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── _helpers.tpl    # Reusable template functions
│   └── NOTES.txt       # Post-install message
├── .helmignore         # Files to exclude from chart package
└── README.md           # Chart documentation
```

### Chart.yaml

```yaml
apiVersion: v2
name: my-app
description: My application Helm chart
type: application          # or 'library' for helper charts
version: 0.1.0             # Chart version (SemVer)
appVersion: "1.16.0"       # Application version
dependencies:
  - name: redis
    version: 17.x.x
    repository: https://charts.bitnami.com/bitnami
```

### Values with Templates

**values.yaml:**
```yaml
replicaCount: 1
image:
  repository: nginx
  tag: "1.25"
  pullPolicy: IfNotPresent
service:
  type: ClusterIP
  port: 80
```

**templates/deployment.yaml:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}
spec:
  replicas: {{ .Values.replicaCount }}
  template:
    spec:
      containers:
        - name: {{ .Chart.Name }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          ports:
            - containerPort: {{ .Values.service.port }}
```

## Best Practices

### Versioning

- **Use SemVer** for chart versions (`version: 0.1.0`)
- **Separate appVersion** from chart version (`appVersion: "1.16.0"`)
- **Pin chart versions** in ArgoCD applications (`targetRevision: 9.5.15`)
- **Never use `latest`**: it breaks reproducibility

### Values Management

```bash
# Order of precedence (highest wins):
# 1. --set key=value (CLI)
# 2. -f custom-values.yaml (file)
# 3. Parent chart values (if subchart)
# 4. values.yaml (chart defaults)
```

```yaml
# In ArgoCD Application:
source:
  helm:
    values: |
      # Inline YAML (same as -f file)
      replicaCount: 2
    parameters:
      # Individual overrides (like --set)
      - name: "image.tag"
        value: "1.25"
```

### Chart Design

- **One concern per chart:** Don't bundle unrelated resources
- **Use `_helpers.tpl`:** Reusable template functions (name, labels, selectors)
- **Document values:** Comment every value in `values.yaml`
- **Use `NOTES.txt`:** Show useful post-install info
- **Test with `helm lint`:** Validates chart structure and templates
- **Test with `helm template`:** Renders templates without installing

### Resource Management

```yaml
# Always set resource requests/limits
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi
```

### Hooks

```yaml
metadata:
  annotations:
    "helm.sh/hook": pre-install,post-upgrade  # When to run
    "helm.sh/hook-weight": "-5"               # Order (lower first)
    "helm.sh/hook-delete-policy": hook-succeeded  # Clean up after
```

## Security Considerations

| Concern | Mitigation |
|---------|-----------|
| **Chart provenance** | Use signed charts (`helm verify`); verify `--prov` files |
| **Untrusted repos** | Only add known repos; pin versions |
| **Secrets in values** | Never commit secrets in `values.yaml`; use K8s Secrets + refs |
| **Helm release history** | Stored as Secrets; limit with `--history-max 10` |
| **Tiller (Helm v2)** | Deprecated; always use Helm v3+ (tillerless) |
| **RBAC escalation** | Helm uses the user's kubeconfig permissions; use least-privilege |
| **Template injection** | Values are injected as strings; use `tpl` function carefully |

## Helm with ArgoCD

ArgoCD can deploy Helm charts directly without `helm install`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
spec:
  source:
    chart: argo-cd
    repoURL: https://argoproj.github.io/argo-helm
    targetRevision: 9.5.15
    helm:
      values: |
        # Helm values (YAML)
      parameters:
        # Individual overrides
        - name: server.ingress.enabled
          value: "true"
```

**Key differences from `helm install`:**
- ArgoCD renders charts server-side (via repo-server), not via local Helm CLI
- No Helm release stored: ArgoCD manages resources directly
- Upgrades/downgrades happen when `targetRevision` changes in Git

## Configuration in This Project

### Manual install (bootstrap only)

```bash
# ArgoCD: installed once manually
helm install argocd argo/argo-cd \
  --namespace argocd \
  -f platform/argocd/values.yaml

# After bootstrap, ArgoCD manages itself via its own Helm chart
```

### GitOps-managed charts (all Phase 2 apps)

| App | Chart | Repo | Version |
|-----|-------|------|---------|
| argocd | argo-cd | argo-helm | 9.5.15 |
| metallb | metallb | metallb.io | 0.14.8 |
| traefik | traefik | traefik.io | 32.1.0 |
| cert-manager | cert-manager | jetstack.io | v1.15.3 |

All managed by ArgoCD: no manual `helm install/upgrade` after bootstrap.

## Common Commands

```bash
# Repository management
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm search repo argo-cd --versions

# Chart operations
helm install <release> <chart> -f values.yaml
helm upgrade <release> <chart> -f values.yaml
helm rollback <release> <revision>
helm uninstall <release>

# Development
helm lint <chart-dir>
helm template <release> <chart> -f values.yaml
helm dependency update <chart-dir>
helm package <chart-dir>

# Release management
helm list -n <namespace>
helm history <release> -n <namespace>
helm get values <release> -n <namespace>
helm get manifest <release> -n <namespace>
```

## Official References

- [Helm Documentation](https://helm.sh/docs/)
- [Chart Development Guide](https://helm.sh/docs/chart_template_guide/)
- [Chart Best Practices](https://helm.sh/docs/chart_best_practices/)
- [Values Files](https://helm.sh/docs/chart_template_guide/values_files/)
- [Built-in Objects](https://helm.sh/docs/chart_template_guide/builtin_objects/)
- [Helm Cheat Sheet](https://helm.sh/docs/intro/cheatsheet/)
- [Artifact Hub](https://artifacthub.io/): Chart repository
