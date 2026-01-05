# Phase 4: Security Foundation

> **Goal:** Add policy-as-code enforcement (Kyverno), secrets abstraction (ESO),
> and self-hosted alert notifications (ntfy). These are the guardrails every
> subsequent phase depends on.

**Depends on:** Phase 2 (ArgoCD GitOps), Phase 3 (Observability Stack)
**Duration:** 1 week (audit mode), 3-4 weeks (full rollout)
**New namespaces:** `kyverno`, `external-secrets`, `ntfy`
**Resource budget:** +220MB RAM, +190m CPU
**Architecture decisions:** [AD-007](../architecture.md#ad-007-kyverno-over-opa-gatekeeper-for-policy-as-code), [AD-008](../architecture.md#ad-008-sealedsecrets--eso-over-hashicorp-vault-for-secrets-management), [AD-009](../architecture.md#ad-009-ntfy-over-rocketchat-for-alert-notifications)

---

## What Phase 4 Delivers

Three new platform services, each fixing a specific security or operational gap:

| Component | Gap It Fixes | How |
|-----------|-------------|-----|
| **Kyverno** | No admission control; pods can run as root, mount hostPaths, skip resource limits | Validating + mutating admission webhook. Policies in Git. |
| **External Secrets Operator** | SealedSecrets works but no abstraction for switching backends later | `ExternalSecret` CRD → `SecretStore` → any backend |
| **ntfy** | Alertmanager has a RocketChat placeholder but no actual notification backend | Self-hosted HTTP pub/sub with native mobile apps. Replaces placeholder. |

### Architecture Diagram

```
┌──────────────────────────────────────────────────────────────────────┐
│                        Platform Services                              │
│                                                                       │
│  ┌─────────────────────────┐    ┌─────────────────────────────────┐  │
│  │        Kyverno           │    │     External Secrets Operator    │  │
│  │                           │    │                                  │  │
│  │  admission-controller     │    │  external-secrets-controller     │  │
│  │  ├─ Validating webhook    │    │  ├─ Watches ExternalSecret CRDs │  │
│  │  │   ● block privileged   │    │  ├─ Calls SecretStore provider  │  │
│  │  │   ● block hostPath     │    │  └─ Creates native K8s Secrets  │  │
│  │  │   ● require limits     │    │                                  │  │
│  │  │   ● block LB services  │    │  SecretStore:                    │  │
│  │  │   ● require HTTPS      │    │  ┌────────────────────────────┐ │  │
│  │  ├─ Mutating webhook      │    │  │ SealedSecrets              │ │  │
│  │  │   ● auto-node-affinity │    │  │  (current)                  │ │  │
│  │  │   ● default sec-ctx    │    │  │                             │ │  │
│  │  └─ Generating webhook    │    │  │ Vault                       │ │  │
│  │      ● default-deny NW    │    │  │  (future, via same API)     │ │  │
│  │                           │    │  └────────────────────────────┘ │  │
│  │  background-controller    │    └─────────────────────────────────┘  │
│  │  ● PolicyReports (audit)  │                                          │
│  └─────────────────────────┘                                          │
│                                                                       │
│  ┌─────────────────────────┐                                          │
│  │          ntfy            │                                          │
│  │                           │    Alertmanager                          │
│  │  HTTP pub/sub server      │◄─── webhook_configs                      │
│  │  ● topic: prom-alerts     │    sends JSON payload                    │
│  │  ● topic: node-alerts     │    to /prometheus-alerts                 │
│  │  ● iOS/Android clients    │                                          │
│  │     push notifications    │    Telegram bridge                        │
│  ▼                           │    (secondary, keep as fallback)          │
│  Human phones                │                                          │
└──────────────────────────────────────────────────────────────────────┘
```

---

## Component 1: Kyverno; Policy Enforcement

### Why Kyverno

Kyverno writes security rules in YAML. That's the entire reason. OPA Gatekeeper's Rego language is a full DSL with its own learning curve, debugging tools, and testing framework. For a single-operator homelab, "I can read every policy without looking up Rego syntax" matters more than theoretical expressiveness. See [AD-007](../architecture.md#ad-007-kyverno-over-opa-gatekeeper-for-policy-as-code) for the full comparison.

### Deployment

```yaml
# platform/kyverno/values.yaml
admissionController:
  replicas: 1
  resources:
    requests: { cpu: 100m, memory: 128Mi }
    limits:   { memory: 384Mi }  # No CPU limit (burst for policy eval)

backgroundController:
  replicas: 1
  resources:
    requests: { cpu: 10m, memory: 64Mi }

reportsController:
  replicas: 1
  resources:
    requests: { cpu: 10m, memory: 64Mi }

cleanupController:
  replicas: 1
  resources:
    requests: { cpu: 10m, memory: 64Mi }

# ===== CRITICAL: prevent K3s boot deadlock =====
webhooksRegistration:
  exemptNamespaces:
    - kube-system
    - gatekeeper-system
    - argocd
    - monitoring
    - traefik
    - metallb-system
```

**⚠️ Without the namespace exemptions**, Kyverno's validating webhook will block K3s ServiceLB from creating pods in `kube-system` during cluster startup. This is a circular deadlock: K3s needs pods to run, Kyverno blocks pods from starting, Kyverno can't run because K3s can't start. The exemptions are permanent; system namespaces run cluster-critical infrastructure that must never be gated by admission policies.

### Policies (Audit → Enforce Graduation)

All policies start in `validationFailureAction: Audit` for the first 1-2 weeks. PolicyReports surface violations without blocking. After validation, policies graduate to `Enforce` namespace-by-namespace.

| # | Policy | Type | Phase | What It Blocks |
|---|--------|------|-------|----------------|
| 1 | `block-privileged-containers` | Validate | Enforce immediately | `securityContext.privileged: true` |
| 2 | `block-hostpath-mounts` | Validate | Enforce immediately | `hostPath` volumes (except safe system paths) |
| 3 | `require-resource-limits` | Validate | Audit → Enforce | Pods without `resources.limits` |
| 4 | `block-loadbalancer-services` | Validate | Enforce immediately | `Service type: LoadBalancer` outside permitted namespaces |
| 5 | `require-https-ingress` | Validate | Audit → Enforce | Ingress without `tls` section |
| 6 | `block-latest-image-tag` | Validate | Audit → Enforce | Images tagged `:latest`, `:main`, `:master` |
| 7 | `require-labels` | Validate | Audit → Enforce | Deployments missing `team` and `cost-center` labels |
| 8 | `generate-default-deny-nwpolicy` | Generate | Enforce immediately | Auto-creates default-deny `NetworkPolicy` in each new namespace |

**Policy example** (the most critical one):

```yaml
# platform/kyverno/policies/block-privileged-containers.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: block-privileged-containers
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: privileged-containers
      match:
        any:
          - resources:
              kinds: [Pod]
      exclude:
        any:
          - resources:
              namespaces: [kube-system, gatekeeper-system, argocd, monitoring, traefik, metallb-system]
      validate:
        message: "Privileged containers are not allowed"
        pattern:
          spec:
            containers:
              - =(securityContext):
                  =(privileged): "false"
```

### Sync Wave

Kyverno deploys at sync wave `-1` (before application workloads) so policies exist before any pod tries to schedule:

```yaml
# platform/argocd/apps/kyverno.yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
```

---

## Component 2: External Secrets Operator; Secrets Abstraction

### Why ESO

The current setup works: SealedSecrets encrypts secrets, commits them to Git, decrypts in-cluster. The problem is coupling; every `SealedSecret` CR ties a workload permanently to the SealedSecrets controller. If I ever add Vault, every workload needs a new secret provisioning method.

ESO breaks this coupling. Workloads consume native K8s `Secret` resources; they always have, they always will. ESO creates those Secrets from whichever backend I configure. Today that's a SealedSecrets `SecretStore`. Tomorrow it could be a Vault `SecretStore`. The `ExternalSecret` CRD and the downstream `Secret` don't change. See [AD-008](../architecture.md#ad-008-sealedsecrets--eso-over-hashicorp-vault-for-secrets-management) for the full Vault comparison.

### Deployment

```yaml
# platform/secrets/external-secrets-operator/values.yaml
resources:
  requests: { cpu: 50m, memory: 64Mi }
  limits:   { cpu: 200m, memory: 128Mi }
```

### Migration Pattern (SealedSecrets → ESO)

**Before (SealedSecrets directly):**
```yaml
# This is the current pattern
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: home-assistant
  namespace: home-assistant
spec:
  encryptedData:
    password: AgA...encrypted...
```
→ SealedSecrets controller → `Secret/home-assistant` → Pod mounts `Secret`

**After (ESO wrapping SealedSecrets):**
```yaml
# Step 1: SecretStore (defines how to talk to the backend)
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: sealedsecrets-store
  namespace: home-assistant
spec:
  provider:
    kubernetes:
      remoteNamespace: home-assistant
      server:
        url: https://kubernetes.default.svc
      auth:
        serviceAccount:
          name: eso-reader

---
# Step 2: ExternalSecret (defines WHAT secrets to sync)
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: home-assistant
  namespace: home-assistant
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: sealedsecrets-store
    kind: SecretStore
  target:
    name: home-assistant
    creationPolicy: Owner
  data:
    - secretKey: password
      remoteRef:
        key: home-assistant
        property: password
```
→ ESO → reads `SecretStore` → calls provider → creates `Secret/home-assistant` → Pod mounts same `Secret`

**After (future, with Vault):**
Only the `SecretStore` changes:
```yaml
provider:
  vault:
    server: "http://vault.vault.svc.cluster.local:8200"
    path: "secret"
    version: "v2"
    auth:
      kubernetes:
        mountPath: "kubernetes"
        role: "home-assistant"
```
Everything else; the `ExternalSecret`, the downstream `Secret`, the Pod; stays identical.

### What ESO doesn't do

- **Doesn't encrypt secrets in Git.** SealedSecrets still does that. ESO is the abstraction layer between "where secrets live" and "what workloads consume."
- **Doesn't provide dynamic secrets.** Vault does that. ESO syncs static KV secrets.
- **Doesn't manage SealedSecrets keys.** The SealedSecrets controller handles its own key rotation.

---

## Component 3: ntfy; Self-Hosted Alert Notifications

### Why ntfy

Alertmanager's notification pipeline has a single output: a Telegram bridge. This means alert delivery depends on Telegram's API being reachable, the bridge deployment being healthy, and the bot token being valid. ntfy gives me a self-hosted notification channel that lives in the same cluster as Alertmanager; same failure domain, same network, zero external dependencies for the hot path. See [AD-009](../architecture.md#ad-009-ntfy-over-rocketchat-for-alert-notifications) for the Rocket.Chat comparison.

### Deployment

```yaml
# platform/ntfy/values.yaml
image:
  repository: binwiederhier/ntfy
  tag: "latest"
  pullPolicy: Always

resources:
  requests: { cpu: 10m, memory: 32Mi }
  limits:   { cpu: 100m, memory: 64Mi }

persistence:
  enabled: true
  size: 1Gi
  storageClass: local-path

ingress:
  enabled: true
  className: traefik
  hosts:
    - host: ntfy.homelab.local
      paths:
        - path: /
          pathType: Prefix

env:
  NTFY_BASE_URL: "https://ntfy.homelab.local"
  NTFY_BEHIND_PROXY: "true"
  NTFY_AUTH_DEFAULT_ACCESS: "deny-all"  # Private instance
```

### Alertmanager Integration

Replace the existing `rocketchat` placeholder receiver:

```yaml
# observability/rules/alertmanager-config.yaml
receivers:
  - name: 'ntfy'
    webhook_configs:
      - url: "http://ntfy.ntfy.svc.cluster.local/prometheus-alerts"
        send_resolved: true
        http_config:
          authorization:
            credentials: "tk_<ntfy-api-token>"

  - name: 'telegram'
    webhook_configs:
      - url: "http://alertmanager-telegram-bot.monitoring.svc.cluster.local:8080"
        send_resolved: true

route:
  routes:
    - match:
        severity: critical
      receiver: 'ntfy'
      continue: true           # ALSO notify Telegram as fallback
    - match:
        severity: warning
      receiver: 'ntfy'
    - match:
        severity: info
      receiver: 'null'
```

**Key design choice:** Critical alerts go to both ntfy AND Telegram (via `continue: true`). ntfy is the primary self-hosted channel. Telegram is the secondary channel; a fallback in case ntfy itself goes down. If both channels fail simultaneously, the Watchdog alert stops firing on both, which is itself a signal (dead man's switch).

### Phone Setup

1. Install ntfy app (iOS: App Store, Android: F-Droid or Play Store)
2. Add server: `https://ntfy.homelab.local`
3. Subscribe to `prometheus-alerts` topic
4. Enable "Instant delivery" (UnifiedPush)

Access is restricted to LAN/VPN only; the ntfy instance doesn't need public internet access. The phone connects when on the home network or via WireGuard.

---

## Deployment Sequence

```
  Step 1: Create namespaces               Step 2: Deploy Kyverno (wave -1)
  ┌─────────────────────────┐            ┌───────────────────────────────┐
  │ kubectl create ns:      │            │ ArgoCD syncs kyverno app:      │
  │  kyverno                │            │  helm install kyverno          │
  │  external-secrets       │            │  values: audit mode initially  │
  │  ntfy                   │            │  exempts system namespaces     │
  └───────────┬─────────────┘            └───────────────┬───────────────┘
              │                                          │
              ▼                                          ▼
  Step 3: Deploy ESO + ntfy (wave 0)    Step 4: Apply Kyverno policies
  ┌─────────────────────────┐            ┌───────────────────────────────┐
  │ ArgoCD syncs:            │            │ ArgoCD syncs kyverno-policies: │
  │  eso.yaml                │            │  8 ClusterPolicy CRDs         │
  │  ntfy.yaml               │            │  Mode: Audit (check reports) │
  └───────────┬─────────────┘            └───────────────┬───────────────┘
              │                                          │
              ▼                                          ▼
  Step 5: Update Alertmanager config      Step 6: Monitor PolicyReports
  ┌─────────────────────────┐            ┌───────────────────────────────┐
  │ Replace rocketchat recvr │            │ kubectl get policyreports -A   │
  │ Add ntfy receiver        │            │ Review violations daily       │
  │ Set continue:true for    │            │ Fix workloads or add           │
  │   critical alerts to     │            │   justified exemptions        │
  │   both channels          │            │                               │
  └─────────────────────────┘            └───────────────┬───────────────┘
                                                         │
                                                         ▼
                                          Step 7: Graduate policies (Week 3)
                                          ┌───────────────────────────────┐
                                          │ Switch Audit → Enforce         │
                                          │ Namespace-by-namespace:        │
                                          │  1. policy-test                │
                                          │  2. home-assistant             │
                                          │  3. monitoring                 │
                                          │  (system ns stay exempted)     │
                                          └───────────────────────────────┘
```

---

## Verification Checklist

| Check | How to Verify |
|-------|--------------|
| Kyverno pods running | `kubectl get pods -n kyverno` → 4/4 Running |
| Webhook registered | `kubectl get validatingwebhookconfigurations -o name \| grep kyverno` |
| Policies applied | `kubectl get clusterpolicies` → 8 policies, Status: Ready |
| PolicyReports generating | `kubectl get policyreports -A` → non-empty reports |
| **No K3s boot deadlock** | Reboot a node. Verify it comes back with `kubectl get nodes` within 2 minutes |
| ESO running | `kubectl get pods -n external-secrets` → 1/1 Running |
| SealedSecrets still works | Create a test `SealedSecret`, verify the controller decrypts it |
| ESO syncs a secret | Create a test `ExternalSecret`, verify `kubectl get secret` shows it |
| ntfy reachable | `curl http://ntfy.ntfy.svc.cluster.local` → 200 OK |
| Alertmanager sends to ntfy | Trigger a test alert, check ntfy web UI or app for message |

---

## Risks and Rollback

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Kyverno boot deadlock on K3s restart | Medium | Critical | Exempt `kube-system`, `metallb-system` permanently. Tested after initial deploy. |
| Policy blocks legitimate workload | High during audit | Low | Audit mode first. Fix workloads before enforcing. Keep exemptions minimal but documented. |
| ESO breaks existing SealedSecrets | Low | High | ESO creates NEW Secrets. Existing SealedSecrets are untouched. Don't delete SealedSecret CRs until ESO version is verified. |
| ntfy notification failures | Low | Medium | Telegram remains as secondary channel. Watchdog alert detects ntfy outage. |
| Webhook timeout on low-RAM node | Medium | Medium | Start with `failurePolicy: Ignore` (fail-open). Switch to `Fail` only after stable. |

**Rollback:** Each component is a separate ArgoCD Application. Deleting the App CR removes the component. Kyverno webhooks are removed with `helm uninstall`. Existing SealedSecrets are never touched by ESO; zero rollback risk. Alertmanager config is version-controlled; revert the commit to restore previous notification routing.

---

## Official References

- [Kyverno Documentation](https://kyverno.io/docs/)
- [Kyverno Policies Library](https://kyverno.io/policies/)
- [Kyverno Helm Chart](https://github.com/kyverno/kyverno/tree/main/charts/kyverno)
- [External Secrets Operator](https://external-secrets.io/latest/)
- [ESO Helm Chart](https://github.com/external-secrets/external-secrets/tree/main/deploy/charts/external-secrets)
- [ESO Kubernetes Provider](https://external-secrets.io/latest/provider/kubernetes/)
- [ntfy Documentation](https://docs.ntfy.sh/)
- [ntfy Alertmanager Integration](https://docs.ntfy.sh/integrations/#alertmanager)
