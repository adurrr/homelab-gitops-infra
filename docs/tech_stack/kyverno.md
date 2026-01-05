# Kyverno: Kubernetes Policy Engine

> **Name:** [kyverno.io](https://kyverno.io/) · **GitHub:** [kyverno/kyverno](https://github.com/kyverno/kyverno) · **Helm chart:** [kyverno/charts/kyverno](https://github.com/kyverno/kyverno/tree/main/charts/kyverno)
> **CNCF Status:** Incubating

## Overview

**Kyverno** is a policy engine designed for Kubernetes. Policies are managed as Kubernetes resources — no new language to learn. Policies can **validate**, **mutate**, **generate**, and **cleanup** Kubernetes resources. It runs as a dynamic admission controller that intercepts resource creation and update requests, and a background controller that audits existing resources for policy violations.

In this project, Kyverno enforces cluster-wide security baselines: blocking privileged containers, requiring resource limits, auto-injecting node affinity, and generating default-deny NetworkPolicies for every namespace.

## How It Works

```
                        ┌───────────────────────────────────────┐
                        │         kube-apiserver                 │
                        │                                       │
                        │  ┌─────────┐  ┌─────────┐             │
                        │  │  Pod    │  │  Pod    │  ...         │
                        │  │ create  │  │ update  │              │
                        │  └────┬────┘  └────┬────┘             │
                        │       │            │                   │
                        │       ▼            ▼                   │
                        │  ┌──────────────────────────┐          │
                        │  │    Admission Webhooks     │          │
                        │  │  (validate + mutate)      │          │
                        │  └────────────┬─────────────┘          │
                        └───────────────┼───────────────────────┘
                                        │
                      ┌─────────────────┼──────────────────┐
                      │                 │                   │
                      ▼                 ▼                   ▼
              ┌────────────────┐ ┌────────────────┐ ┌──────────────────┐
              │  Validating    │ │   Mutating     │ │   Background     │
              │  Webhook       │ │   Webhook      │ │   Controller     │
              │                │ │                │ │                  │
              │ Checks policy  │ │ Injects:       │ │ Scans existing   │
              │ rules:         │ │ • node affin.  │ │ resources for    │
              │ • no privileged│ │ • sec context  │ │ violations       │
              │ • has limits   │ │ • labels       │ │ → PolicyReports  │
              │ • no hostPath  │ │ • annotations  │ │                  │
              │                │ │                │ │ Generate         │
              │ BLOCK / ALLOW  │ │ MODIFY REQ.    │ │ resources:       │
              └────────────────┘ └────────────────┘ │ netpols, etc.    │
                                                    └──────────────────┘
```

### Namespace Exemption (Critical for K3s)

K3s's **ServiceLB** (`svclb-*` pods) is created automatically for LoadBalancer-type services. If Kyverno blocks or mutates those pods before K3s can start them, the cluster enters a **boot deadlock**: Kyverno blocks ServiceLB pods → Traefik can't start → no ingress → can't manage Kyverno → stuck.

The following namespaces **must** be permanently exempted:

| Namespace | Reason |
|-----------|--------|
| `kube-system` | ServiceLB, CoreDNS, K3s system pods |
| `argocd` | ArgoCD application controller pods |
| `monitoring` | Prometheus operator, Grafana |
| `traefik` | Ingress controller |
| `metallb-system` | LoadBalancer controller |

## Key Features

### 1. Validate

Block non-compliant resources before they land in etcd:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-privileged-containers
spec:
  validationFailureAction: Enforce
  rules:
    - name: validate-privileged
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "Privileged containers are not allowed"
        pattern:
          spec:
            containers:
              - securityContext:
                  privileged: false
```

### 2. Mutate

Auto-inject node affinity, security contexts, resource limits, and labels:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-node-affinity
spec:
  rules:
    - name: inject-arm64-affinity
      match:
        any:
          - resources:
              kinds: ["Pod"]
      mutate:
        patchesJson6902: |
          - op: add
            path: /spec/affinity
            value:
              nodeAffinity:
                requiredDuringSchedulingIgnoredDuringExecution:
                  nodeSelectorTerms:
                    - matchExpressions:
                        - key: kubernetes.io/arch
                          operator: In
                          values: ["arm64"]
```

### 3. Generate

Auto-create resources when a namespace is created — for example, a default-deny NetworkPolicy for every new namespace:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: default-deny-netpol
spec:
  rules:
    - name: generate-netpol
      match:
        any:
          - resources:
              kinds: ["Namespace"]
      generate:
        apiVersion: networking.k8s.io/v1
        kind: NetworkPolicy
        name: default-deny
        synchronize: true
        namespace: "{{request.object.metadata.name}}"
        data:
          spec:
            podSelector: {}
            policyTypes:
              - Ingress
              - Egress
```

### 4. PolicyReports

When `validationFailureAction` is set to `Audit`, Kyverno generates **PolicyReport** resources that list violations without blocking. Reports can be queried with `kubectl`:

```bash
kubectl get policyreports -A
kubectl describe policyreport -n <namespace> <report-name>
```

### 5. PolicyException

Exempt specific resources from a policy without modifying the policy itself:

```yaml
apiVersion: kyverno.io/v2
kind: PolicyException
metadata:
  name: allow-fluentd-privileged
  namespace: logging
spec:
  exceptions:
    - policyName: disallow-privileged-containers
      ruleNames:
        - validate-privileged
  match:
    any:
      - resources:
          kinds: ["Pod"]
          names: ["fluentd-*"]
```

## Best Practices

- **Audit first**: Start with `validationFailureAction: Audit` for 1–2 weeks. Review PolicyReports before switching to `Enforce`.
- **Graduate per namespace**: Enforce on test → staging → production namespaces incrementally.
- **System namespaces stay exempted permanently**: kube-system, argocd, monitoring, traefik, metallb-system.
- **ARM64 compatibility**: Kyverno provides multi-arch images including `linux/arm64` — no special configuration needed.
- **Resource budget**: ~270MB RAM total across 4 controllers, ~130m CPU. See resource config below.
- **Start with `failurePolicy: Ignore`** on low-resource nodes to prevent webhook timeouts from blocking the cluster.
- **Pin the Helm chart version** — Kyverno CRDs evolve between releases.

## Security Considerations

| Concern | Mitigation |
|---------|-----------|
| **Webhook timeout on low-resource nodes** | Set `failurePolicy: Ignore` during initial rollout; tune later to `Fail` |
| **K3s boot deadlock** | Exempt system namespaces (kube-system, etc.) from all webhooks |
| **Mutating webhook breaks existing workloads** | Only match on specific namespaces; use `preconditions` to skip non-matching pods |
| **PolicyException sprawl** | Document each exception with a justification; review periodically |
| **Cluster-wide admission control** | Restrict `ClusterPolicy` creation to cluster admins via RBAC |
| **CRD version drift** | Match Helm chart and CRD versions; upgrade CRDs before the chart |

## Configuration in This Project

```yaml
# platform/kyverno/values.yaml (key settings)
admissionController:
  replicas: 1
  resources:
    requests: { cpu: 100m, memory: 128Mi }
    limits:   { memory: 384Mi }

backgroundController:
  replicas: 1
  resources:
    requests: { cpu: 10m, memory: 64Mi }
  serviceMonitor:
    enabled: true                              # Scrape background controller metrics

reportsController:
  replicas: 1

cleanupController:
  replicas: 1

webhooksRegistration:
  exemptNamespaces:
    - kube-system
    - argocd
    - monitoring
    - traefik
    - metallb-system
```

## Official References

- [Kyverno Documentation](https://kyverno.io/docs/)
- [Kyverno Policy Library](https://kyverno.io/policies/)
- [Kyverno GitHub](https://github.com/kyverno/kyverno)
- [Kyverno Helm Chart](https://github.com/kyverno/kyverno/tree/main/charts/kyverno)
- [Kyverno PolicyException](https://kyverno.io/docs/writing-policies/exceptions/)
- [PolicyReport CRD](https://kyverno.io/docs/policy-reports/)
