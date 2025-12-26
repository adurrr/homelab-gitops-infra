# Phase 3 ArgoCD Sync Issues: Root Cause Analysis & Fixes

> Comprehensive documentation of all OutOfSync and Progressing issues found in
> Phase 3 observability apps, their root causes, and the fixes applied.

---

## Summary Table

| App | Status Issue | Root Cause | Fix Applied |
|-----|-------------|------------|-------------|
| **prometheus** | OutOfSync | CRD default values not considered in diff | `ignoreDifferences` for CRDs, ServiceMonitors, PodMonitors, PrometheusRules |
| **prometheus** | OutOfSync | Webhook caBundle populated by K8s after creation | `jqPathExpressions` for caBundle fields |
| **prometheus** | OutOfSync | ClusterRole rules conditionally added by Helm capabilities | `jqPathExpressions` for discovery.k8s.io rules |
| **prometheus** | OutOfSync | StatefulSet volumeClaimTemplates apiVersion/kind added by SSA | `jqPathExpressions` for volumeClaimTemplates |
| **prometheus** | OutOfSync | Deployment/DaemonSet resources drift on K8s 1.32+ | `jqPathExpressions` for container resources |
| **loki** | ComparisonError | `deploymentMode: Monolithic` requires object storage | Changed to `deploymentMode: SingleBinary` |
| **loki** | OutOfSync | StatefulSet volumeClaimTemplates apiVersion/kind added by SSA | `jqPathExpressions` for volumeClaimTemplates |
| **loki** | OutOfSync | ConfigMap/Secret runtime modifications | `jsonPointers` for /data |
| **homelab-apps** | OutOfSync/Progressing | Application spec normalization by ArgoCD controller | `jqPathExpressions` for helm, retry, syncPolicy blocks |
| **homelab-apps** | Progressing | Child apps OutOfSync → parent shows Progressing | `RespectIgnoreDifferences=true` + comprehensive ignores |
| **argocd** | OutOfSync | Mixing `helm.values` + `helm.parameters` causes drift | Consolidated all config into `helm.values` |
| **argocd** | OutOfSync | Deployment resources drift on K8s 1.32+ | `jqPathExpressions` for container resources |
| **argocd** | OutOfSync | Secrets/ConfigMaps modified at runtime | `jsonPointers` for /data |

---

## Issue 1: kube-prometheus-stack: CRD Default Values

### Symptom
Prometheus app shows `OutOfSync` immediately after a successful sync. The diff
shows fields present in the live CRD that are not in the Git manifest.

### Root Cause
ArgoCD has a **known limitation** where it cannot consider CRD default values
during diff calculation. When a CRD defines default values for fields, the
Kubernetes API server adds those defaults to the live object. ArgoCD's diff
engine sees these as "missing" from the desired state and reports OutOfSync.

This is tracked in:
- [argo-cd#11074](https://github.com/argoproj/argo-cd/issues/11074)
- [argo-cd#11139](https://github.com/argoproj/argo-cd/issues/11139)

### Affected Resources
- `ServiceMonitor`: `spec.endpoints[].relabelings[].action`
- `Prometheus`: `spec.remoteWrite[].writeRelabelConfigs[].action`
- `PodMonitor`: entire `/spec`
- `PrometheusRule`: entire `/spec`

### Fix
```yaml
ignoreDifferences:
  - group: monitoring.coreos.com
    kind: ServiceMonitor
    jqPathExpressions:
      - '.spec.endpoints[]?.relabelings[]?.action'
    jsonPointers:
      - /spec
  - group: monitoring.coreos.com
    kind: Prometheus
    jqPathExpressions:
      - '.spec.remoteWrite[]?.writeRelabelConfigs[]?.action'
  - group: monitoring.coreos.com
    kind: PodMonitor
    jsonPointers:
      - /spec
  - group: monitoring.coreos.com
    kind: PrometheusRule
    jsonPointers:
      - /spec
```

---

## Issue 2: Webhook caBundle Fields

### Symptom
ValidatingWebhookConfiguration and MutatingWebhookConfiguration show as
OutOfSync because the `caBundle` field differs between Git and live state.

### Root Cause
Kubernetes (or cert-manager) populates the `caBundle` field in webhook
configurations after they are created. This field is not present in the Helm
chart manifest but exists in the live object.

Tracked in:
- [helm-charts#4914](https://github.com/prometheus-community/helm-charts/issues/4914)

### Fix
```yaml
ignoreDifferences:
  - group: admissionregistration.k8s.io
    kind: ValidatingWebhookConfiguration
    jqPathExpressions:
      - '.webhooks[]?.clientConfig.caBundle'
  - group: admissionregistration.k8s.io
    kind: MutatingWebhookConfiguration
    jqPathExpressions:
      - '.webhooks[]?.clientConfig.caBundle'
```

---

## Issue 3: ClusterRole Conditional Rules

### Symptom
ClusterRole `prometheus-kube-prometheus-operator` shows OutOfSync due to
`discovery.k8s.io` API group rules.

### Root Cause
The kube-prometheus-stack chart conditionally adds `discovery.k8s.io` rules
based on `{{- if .Capabilities.APIVersions.Has "discovery.k8s.io/v1/EndpointSlice" }}`.
ArgoCD's Helm rendering may differ from what the cluster reports, causing
perpetual drift.

Tracked in:
- [argo-cd#20537](https://github.com/argoproj/argo-cd/issues/20537)

### Fix
```yaml
ignoreDifferences:
  - group: rbac.authorization.k8s.io
    kind: ClusterRole
    name: prometheus-kube-prometheus-operator
    jqPathExpressions:
      - '.rules[] | select (.apiGroups == ["discovery.k8s.io"])'
```

---

## Issue 4: StatefulSet volumeClaimTemplates (SSA)

### Symptom
StatefulSets (Alertmanager, Prometheus, Grafana, Loki) show OutOfSync because
`apiVersion` and `kind` fields appear in `volumeClaimTemplates` in the live
manifest but not in Git.

### Root Cause
When `ServerSideApply=true` is enabled, the API server performs internal
conversions on StatefulSet objects. During conversion, it adds `apiVersion: v1`
and `kind: PersistentVolumeClaim` to each volumeClaimTemplate entry. These
fields are not in the Helm manifest but appear in the live state.

This is a **known ArgoCD + SSA interaction issue**:
- [argo-cd#11143](https://github.com/argoproj/argo-cd/issues/11143)
- [argo-cd#11074](https://github.com/argoproj/argo-cd/issues/11074)

### Fix
```yaml
ignoreDifferences:
  - group: apps
    kind: StatefulSet
    name: alertmanager-prometheus-kube-prometheus-alertmanager
    jqPathExpressions:
      - '.spec.volumeClaimTemplates[0].apiVersion'
      - '.spec.volumeClaimTemplates[0].kind'
  - group: apps
    kind: StatefulSet
    name: prometheus-prometheus-kube-prometheus-prometheus
    jqPathExpressions:
      - '.spec.volumeClaimTemplates[0].apiVersion'
      - '.spec.volumeClaimTemplates[0].kind'
  - group: apps
    kind: StatefulSet
    name: loki
    jqPathExpressions:
      - '.spec.volumeClaimTemplates[0].apiVersion'
      - '.spec.volumeClaimTemplates[0].kind'
```

---

## Issue 5: Deployment/DaemonSet Resources Drift

### Symptom
Deployments (Grafana, kube-state-metrics, operator) and DaemonSets
(node-exporter) show OutOfSync because container `resources` fields differ.

### Root Cause
On Kubernetes 1.32+, the API server may inject default resource values into
container specs. This causes the live manifest to have `resources` fields that
don't exist in the Helm chart manifest.

Tracked in:
- [helm-charts#4914](https://github.com/prometheus-community/helm-charts/issues/4914)

### Fix
```yaml
ignoreDifferences:
  - group: apps
    kind: Deployment
    name: prometheus-grafana
    jqPathExpressions:
      - '.spec.template.spec.containers[]?.resources'
      - '.spec.template.spec.initContainers[]?.resources'
  - group: apps
    kind: Deployment
    name: prometheus-kube-state-metrics
    jqPathExpressions:
      - '.spec.template.spec.containers[]?.resources'
  - group: apps
    kind: DaemonSet
    name: prometheus-prometheus-node-exporter
    jqPathExpressions:
      - '.spec.template.spec.containers[]?.resources'
```

---

## Issue 6: App-of-Apps Normalization Drift

### Symptom
The `homelab-apps` root application shows `OutOfSync` even though all child
apps appear Synced in the list view. When you open the root app details, child
apps show as OutOfSync.

### Root Cause
The ArgoCD controller **normalizes** Application specs during reconciliation.
This normalization causes several fields to differ between the Git manifest and
the live Application resource:

1. **Helm block normalization**: `helm: {}` vs omitted: ArgoCD serializes
   empty blocks differently
2. **Retry block normalization**: Same issue with `retry: {}`
3. **Sync policy normalization**: `automated: {}` vs explicit fields
4. **Instance label**: ArgoCD adds `argocd.argoproj.io/instance` label
5. **Refresh annotation**: Added during manual refresh operations
6. **Status field**: ArgoCD adds operation state and sync status

Tracked in:
- [argo-cd#14668](https://github.com/argoproj/argo-cd/issues/14668)
- [argo-cd#6708](https://github.com/argoproj/argo-cd/issues/6708)

### Fix
```yaml
ignoreDifferences:
  - group: argoproj.io
    kind: Application
    jqPathExpressions:
      - '.spec.source.helm // empty'
      - '.spec.source.retry // empty'
      - '.spec.syncPolicy.automated // empty'
    jsonPointers:
      - /metadata/labels/argocd.argoproj.io~1instance
      - /metadata/annotations/argocd.argoproj.io~1refresh
      - /metadata/annotations/kubectl.kubernetes.io~1last-applied-configuration
      - /status
```

### Why Parent Shows Progressing
The parent app's health depends on child apps' health. When child apps are
OutOfSync, the parent flips between `Healthy` and `Progressing` as it detects
the drift. This is **expected behavior** for the App-of-Apps pattern: the
parent is "progressing" because it's waiting for children to converge.

By fixing the child apps' OutOfSync states with proper `ignoreDifferences`,
the parent will stabilize to `Healthy`.

---

## Issue 7: ArgoCD Self-Managed App Drift

### Symptom
The `argocd` self-managed application shows OutOfSync due to mixing
`helm.values` and `helm.parameters`.

### Root Cause
When both `helm.values` (inline YAML) and `helm.parameters` (key-value pairs)
are specified, Helm merges them in an unpredictable order. This can cause:
- Parameters overriding values unexpectedly
- Values overriding parameters unexpectedly
- Different rendering on each sync

### Fix
Consolidated all configuration into `helm.values` and removed `helm.parameters`
entirely. This ensures deterministic rendering.

---

## Issue 8: ArgoCD Secrets/ConfigMaps Runtime Modification

### Symptom
ArgoCD's own Secrets and ConfigMaps show OutOfSync because they are modified
at runtime by the ArgoCD controller.

### Root Cause
The ArgoCD controller manages its own configuration:
- `argocd-secret`: TLS certs, admin password, etc.
- `argocd-cm`: Main configuration
- `argocd-cmd-params-cm`: Command-line parameters
- `argocd-rbac-cm`: RBAC policy
- `argocd-ssh-known-hosts-cm`: SSH known hosts
- `argocd-tls-certs-cm`: TLS certificates

These are modified at runtime and will always differ from the Git manifest.

### Fix
```yaml
ignoreDifferences:
  - group: ""
    kind: Secret
    name: argocd-secret
    jsonPointers:
      - /data
  - group: ""
    kind: ConfigMap
    name: argocd-cm
    jsonPointers:
      - /data
  # ... (all other ConfigMaps)
```

---

## Issue 9: Loki deploymentMode Requires Object Storage

### Symptom
Loki app shows `ComparisonError`:
```
Cannot run scalable targets (backend, read, write) or distributed targets
without an object storage backend.
```

### Root Cause
In Loki chart 17.x, `deploymentMode` has four valid values:

| Mode | Replicas | Object Storage Required | Use Case |
|------|----------|------------------------|----------|
| `SingleBinary` | 1 | **No** (filesystem OK) | Dev/test, small homelabs |
| `Monolithic` | 1+ | **Yes** (for >1 replica) | Multi-replica simple setup |
| `SimpleScalable` | 2+ | **Yes** | Read/write separation |
| `Distributed` | 5+ | **Yes** | Production microservices |

Using `deploymentMode: Monolithic` with `minio.enabled: false` and no S3
backend triggers the validation error because the chart expects object storage
for any mode other than `SingleBinary`.

### Fix
Change `deploymentMode: Monolithic` to `deploymentMode: SingleBinary`:
```yaml
deploymentMode: SingleBinary

singleBinary:
  replicas: 1
  persistence:
    enabled: true
    size: 50Gi
    storageClassName: local-path

minio:
  enabled: false
```

---

## Required syncOptions

All apps now include these sync options:

| Option | Purpose |
|--------|---------|
| `ServerSideApply=true` | Required for large CRDs; avoids "object too large" errors |
| `RespectIgnoreDifferences=true` | **Critical**: without this, `ignoreDifferences` entries are ignored |
| `ApplyOutOfSyncOnly=true` | Reduces sync conflicts by only applying drifted resources |
| `CreateNamespace=true` | Auto-creates destination namespace if missing |

### Why `RespectIgnoreDifferences=true` is Critical
Without this option, ArgoCD **ignores** all `ignoreDifferences` entries during
the sync operation. The app may show as Synced after a manual sync, but will
immediately flip back to OutOfSync on the next comparison. This is a common
misconfiguration.

---

## Files Modified

| File | Changes |
|------|---------|
| `platform/argocd/apps/prometheus.yaml` | Added 15+ ignoreDifferences entries, syncOptions |
| `platform/argocd/apps/loki.yaml` | Fixed chart 17.x values, added StatefulSet ignores |
| `platform/argocd/apps/argocd.yaml` | Consolidated helm config, added comprehensive ignores |
| `platform/argocd/bootstrap/argocd-app.yaml` | Added Application normalization ignores |

---

## Verification Steps

After applying the fixes:

```bash
# 1. Apply the bootstrap root app (if not already applied)
kubectl apply -f platform/argocd/bootstrap/argocd-app.yaml

# 2. Force sync all apps
argocd app sync prometheus --force
argocd app sync loki --force
argocd app sync otel-collector --force
argocd app sync argocd --force

# 3. Wait for sync to complete
argocd app wait prometheus --sync --health --timeout 300
argocd app wait loki --sync --health --timeout 300
argocd app wait otel-collector --sync --health --timeout 300

# 4. Check all apps
argocd app list

# 5. Run Phase 3 tests
make test-phase3
```

### Expected Results
- `prometheus`: **Synced** + **Healthy**
- `loki`: **Synced** + **Healthy**
- `otel-collector`: **Synced** + **Healthy**
- `argocd`: **Synced** + **Healthy**
- `homelab-apps`: **Synced** + **Healthy** (may briefly show Progressing during child sync)

---

## References

- [ArgoCD Diff Customization](https://argo-cd.readthedocs.io/en/stable/user-guide/diffing/)
- [argo-cd#11074: kube-prometheus-stack OutOfSync](https://github.com/argoproj/argo-cd/issues/11074)
- [argo-cd#11143: StatefulSet SSA volumeClaimTemplates](https://github.com/argoproj/argo-cd/issues/11143)
- [argo-cd#20537: ClusterRole conditional rules](https://github.com/argoproj/argo-cd/issues/20537)
- [argo-cd#14668: App-of-Apps normalization](https://github.com/argoproj/argo-cd/issues/14668)
- [argo-cd#6708: App-of-Apps health status](https://github.com/argoproj/argo-cd/issues/6708)
- [helm-charts#4914: kube-prometheus-stack ArgoCD diffs](https://github.com/prometheus-community/helm-charts/issues/4914)
