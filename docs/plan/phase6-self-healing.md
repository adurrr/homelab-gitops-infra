# Phase 6: Self-Healing Alerts (Tier 1)

> **Goal:** Automate safe, idempotent remediation actions for the three most
> common failure modes: pod crash loops, OOMKills, and Cilium agent errors.
> Everything else stays manual or PR-gated.

**Depends on:** Phase 3 (Observability Stack; Prometheus, Alertmanager), Phase 4 (ntfy for notification on failures)
**Duration:** 1 week (build + dry-run), 2 weeks (monitor before enabling)
**New namespace:** `self-healing`
**Resource budget:** +114MB RAM, +100m CPU (webhook receiver + Argo Workflows baseline)
**Architecture decisions:** [AD-011](../architecture.md#ad-011-self-healing-tier-1-restart-only-with-safety-guards)

---

## What Phase 6 Delivers

A lightweight Go webhook receiver that maps Alertmanager alerts to Kubernetes remediation actions. Tier 1 only; safe, restart-based, bounded:

| Alert | Action | Safety Guard |
|-------|--------|-------------|
| `SelfHealPodCrashLoop` | `kubectl rollout restart` on owning Deployment/StatefulSet | RestartCount < 10, max 3/hour |
| `SelfHealFirstOOMKilled` | `kubectl rollout restart` + log the event | First occurrence only (not repeated OOMs) |
| `SelfHealCiliumAgentErrors` | `kubectl rollout restart` on cilium DaemonSet | Max 1 restart per 6 hours |

### Architecture Diagram

```
┌───────────────────────────────────────────────────────────────────────────┐
│                      Self-Healing Pipeline                                  │
│                                                                            │
│  Prometheus fires alert       Alertmanager routes       Webhook Receiver    │
│  ┌─────────────────┐         ┌──────────────────┐      ┌────────────────┐ │
│  │ PrometheusRule   │────────►│ route:            │─────►│ Go HTTP server │ │
│  │ SelfHealPodCrash │         │  match:            │      │ :8080/alert    │ │
│  │  for: 2m         │         │    self_heal:true  │      │                │ │
│  │  severity: info   │         │  receiver:          │      │ ┌────────────┐ │ │
│  └─────────────────┘         │    self-healing     │      │ │ Rate limit │ │ │
│                               │  continue: true     │      │ │ 3/hour/    │ │ │
│                               └──────────────────┘      │ │ alertname  │ │ │
│                                                         │ └─────┬──────┘ │ │
│  SelfHealFirstOOMKilled                                  │       │        │ │
│  ┌─────────────────┐                                    │       ▼        │ │
│  │ PrometheusRule   │───────────────────────────────────┤ ┌────────────┐ │ │
│  │ SelfHealOOM      │                                    │ │ Dedup by   │ │ │
│  │  increase(       │                                    │ │ alert      │ │ │
│  │   OOMKilled[5m]) │                                    │ │ fingerprint│ │ │
│  │  > 0             │                                    │ └─────┬──────┘ │ │
│  └─────────────────┘                                    │       │        │ │
│                                                         │       ▼        │ │
│  SelfHealCiliumErrors                                   │ ┌────────────┐ │ │
│  ┌─────────────────┐                                    │ │ Check      │ │ │
│  │ PrometheusRule   │───────────────────────────────────┤ │ guard:     │ │ │
│  │ rate(cilium_err  │                                    │ │ restart <  │ │ │
│  │  ors[5m]) > 0    │                                    │ │ 10? max/hr?│ │ │
│  └─────────────────┘                                    │ └─────┬──────┘ │ │
│                                                         │       │        │ │
│                                                         │       ▼        │ │
│                                                         │ ┌────────────┐ │ │
│                                                         │ │ kubectl    │ │ │
│                                                         │ │ rollout    │ │ │
│                                                         │ │ restart    │ │ │
│                                                         │ │ --dry-run  │ │ │
│                                                         │ │  → exec    │ │ │
│                                                         │ └─────┬──────┘ │ │
│                                                         └───────┼────────┘ │
│                                                                 │          │
│                                                         ┌───────▼────────┐ │
│                                                         │  Audit Log     │ │
│                                                         │  → Loki        │ │
│                                                         │  → ntfy        │ │
│                                                         │  (success AND  │ │
│                                                         │   failure)     │ │
│                                                         └────────────────┘ │
└───────────────────────────────────────────────────────────────────────────┘
```

---

## Component 1: PrometheusRules; Self-Healing Alerts

These rules are separate from the existing notification rules. They exist purely to trigger remediation. They fire at lower thresholds than notification rules (catch problems early, fix them before a human notices):

```yaml
# observability/rules/self-healing-rules.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: self-healing-rules
  namespace: monitoring
  labels:
    app: kube-prometheus-stack
    release: prometheus
spec:
  groups:
    - name: self-healing
      interval: 1m
      rules:
        # Pod crash loop; restart if it hasn't crashed too many times
        - alert: SelfHealPodCrashLoop
          expr: rate(kube_pod_container_status_restarts_total[15m]) > 0
          for: 2m
          labels:
            severity: info
            tier: "1"
            self_heal: "true"
          annotations:
            summary: "Self-healing: Pod crash loop detected"
            remediation_action: "rollout_restart"
            description: "Pod {{ $labels.namespace }}/{{ $labels.pod }} is crash looping. Will attempt rollout restart."

        # First OOMKill; restart to clear memory state
        - alert: SelfHealFirstOOMKilled
          expr: increase(kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}[5m]) > 0
          for: 0m
          labels:
            severity: info
            tier: "1"
            self_heal: "true"
          annotations:
            summary: "Self-healing: OOMKill detected"
            remediation_action: "rollout_restart"
            description: "Pod {{ $labels.namespace }}/{{ $labels.pod }} was OOMKilled. Restarting to clear memory. If this recurs, manual investigation needed."

        # Cilium agent errors; restart the daemonset
        - alert: SelfHealCiliumAgentErrors
          expr: rate(cilium_errors_warnings_total[5m]) > 0
          for: 3m
          labels:
            severity: info
            tier: "1"
            self_heal: "true"
          annotations:
            summary: "Self-healing: Cilium agent errors detected"
            remediation_action: "rollout_restart_daemonset"
            description: "Cilium agent on {{ $labels.node }} logging errors. Attempting DaemonSet restart."
```

---

## Component 2: Alertmanager Routing

```yaml
# observability/rules/alertmanager-config.yaml (additions)
receivers:
  # NEW: Self-healing webhook receiver
  - name: 'self-healing'
    webhook_configs:
      - url: "http://self-healing-receiver.self-healing.svc.cluster.local:8080/alert"
        send_resolved: false  # Don't send resolved; no action needed on resolution

route:
  # ADD to existing route tree:
  routes:
    # Self-healing alerts; route to remediation receiver
    - match:
        self_heal: "true"
      receiver: 'self-healing'
      continue: true       # ALSO notify via ntfy so I can see what it did
      group_wait: 30s      # Short wait; remediate quickly
      group_interval: 1m
      repeat_interval: 4h  # CRITICAL: prevents infinite remediation loops

    # Existing routes remain unchanged...
```

**⚠️ `repeat_interval: 4h` is non-negotiable.** Without this, Alertmanager re-fires alerts every `group_interval` (default 5m), which triggers a new remediation every 5 minutes. A pod that keeps crash looping would be restarted 12 times/hour indefinitely. At 4h, the receiver's own rate limiter (3/hour) catches it first, but the Alertmanager setting is the defense-in-depth.

---

## Component 3: Webhook Receiver (Go)

A single Go binary that receives Alertmanager webhooks and executes `kubectl` commands. This is custom code because the logic is specific to our cluster: which alerts map to which actions, which safety guards apply, which namespaces to exempt.

### Safety Guards (Implemented in Code)

| Guard | Mechanism | Why |
|-------|-----------|-----|
| **Rate limit** | In-memory counter per alert name, reset hourly | Max 3 remediations per alert type per hour |
| **Deduplication** | Alert fingerprint from Alertmanager payload | Same alert firing repeatedly = one remediation |
| **Restart count check** | `kubectl get pod -o jsonpath='{.status.containerStatuses[0].restartCount}'` | If > 10, something is fundamentally wrong; don't restart |
| **Max attempts per pod** | Pod annotation `remediated-at` with timestamp | If already restarted in last 30 minutes, skip |
| **Dry-run** | `kubectl rollout restart --dry-run=server` | Verify the API accepts the request before executing |
| **System namespace exemption** | Hard-coded skip for `kube-system`, `argocd`, `kyverno` | Never auto-restart infrastructure components |
| **Audit log** | Structured JSON log to stdout → Loki | Every action (success + failure) logged |

### Deployment

```yaml
# platform/self-healing/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: self-healing-receiver
  namespace: self-healing
spec:
  replicas: 1
  selector:
    matchLabels:
      app: self-healing-receiver
  template:
    spec:
      serviceAccountName: self-healing-sa  # RBAC for kubectl
      containers:
        - name: receiver
          image: ghcr.io/adurrr/self-healing-receiver:v0.1.0  # Built from platform/self-healing/
          ports:
            - containerPort: 8080
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits:   { cpu: 200m, memory: 128Mi }
          env:
            - name: LOG_LEVEL
              value: "info"
            - name: DRY_RUN
              value: "true"       # Start in dry-run mode!
            - name: MAX_RESTARTS_PER_HOUR
              value: "3"
            - name: EXEMPT_NAMESPACES
              value: "kube-system,argocd,kyverno,gatekeeper-system,metallb-system,cert-manager"
```

### RBAC (Least Privilege)

```yaml
# platform/self-healing/rbac.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: self-healing-sa
  namespace: self-healing
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: self-healing-role
rules:
  - apiGroups: ["apps"]
    resources: ["deployments", "statefulsets", "daemonsets"]
    verbs: ["get", "list", "patch"]         # patch for rollout restart
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list"]                   # read-only: check restart count
  - apiGroups: [""]
    resources: ["pods/exec"]
    verbs: ["create"]                        # Only if log-checking is needed
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: self-healing-binding
subjects:
  - kind: ServiceAccount
    name: self-healing-sa
    namespace: self-healing
roleRef:
  kind: ClusterRole
  name: self-healing-role
  apiGroup: rbac.authorization.k8s.io
```

---

## Alert → Action Mapping

The receiver uses a configurable mapping from alert name to remediation action:

```go
// This lives in a ConfigMap for easy adjustment without code changes
var actionMap = map[string]Action{
    "SelfHealPodCrashLoop": {
        Action:            "RolloutRestart",
        MaxRestartCount:   10,
        CooldownMinutes:   30,
        ExemptNamespaces:  []string{"kube-system", "argocd", "kyverno"},
    },
    "SelfHealFirstOOMKilled": {
        Action:            "RolloutRestart",
        MaxRestartCount:   10,
        CooldownMinutes:   30,
        ExemptNamespaces:  []string{"kube-system", "argocd", "kyverno"},
    },
    "SelfHealCiliumAgentErrors": {
        Action:            "RolloutRestartDaemonSet",
        MaxRestartCount:   999,         // DaemonSet restart is different
        CooldownMinutes:   360,         // 6 hours; very conservative
        ExemptNamespaces:  []string{},  // No exemptions; always applies to kube-system
    },
}
```

---

## Rollout Plan (Graduated, Never Big Bang)

### Phase 6a: Dry-Run Only (Week 1)

```yaml
# Deployment env
DRY_RUN: "true"
```

The receiver logs every action it WOULD take but executes nothing. All logs go to Loki. Review the audit log daily:

```
# Example dry-run log entry
{"level":"info","ts":"2025-07-01T04:02:00Z","msg":"DRY_RUN:
would restart deployment","alert":"SelfHealPodCrashLoop",
"namespace":"monitoring","pod":"loki-0","restart_count":3}
```

### Phase 6b: Enable with Monitoring (Week 2-3)

```yaml
DRY_RUN: "false"
```

1. Monitor ntfy for remediation notifications (sent alongside actions)
2. Grafana dashboard: track `remediation_actions_total` by result
3. If any action causes an outage → disable immediately (set `DRY_RUN: "true"` in ArgoCD)
4. If false positives > 10% → tune alert thresholds before proceeding

### Phase 6c: Production (Week 4+)

Self-healing runs continuously. Weekly review of audit logs for:
- Actions taken vs alerts fired (rate limiter effectiveness)
- False positives (actions that shouldn't have triggered)
- Missed alerts (actions that should have triggered but didn't)

---

## What Is NOT Automated (and Why)

| Potential Action | Tier | Why Not Automated |
|-----------------|------|-------------------|
| Memory limit increase after OOMKill | **Tier 2** | Changes `resources.limits` in Git. Needs human review + PR. heal8s pattern. |
| Image rollback after failed deployment | **Tier 2** | Image versions are in Git. Rollback = Git revert + PR. |
| Node cordon/drain on memory pressure | **Tier 3** | 2-node cluster. Losing one node kills HA. Human decision required. |
| PVC expansion | **Tier 3** | local-path doesn't support online expansion. |
| Certificate renewal | **N/A (cert-manager)** | cert-manager handles this natively. The only action is deleting failed challenges. |
| Cilium version upgrade | **Tier 3** | ARM64 Cilium is fragile (see AD-002). Never auto-upgrade networking. |

---

## Verification Checklist

| Check | How to Verify |
|-------|--------------|
| Self-healing rules loaded | `kubectl get prometheusrule -n monitoring self-healing-rules -o yaml` → rules present |
| Alertmanager routes self-heal alerts | Check Alertmanager UI → Status → shows `self-healing` receiver |
| Receiver receives webhooks | `kubectl logs -n self-healing -l app=self-healing-receiver` → shows incoming alerts |
| Dry-run logs correct action | Logs show "would restart" with correct pod/namespace |
| Rate limiter works | Fire same alert 5× in one minute → only 3 appear in logs |
| System namespace exemption works | Fire alert for `kube-system` pod → log shows "exempted: system namespace" |
| RBAC is correct | `kubectl auth can-i patch deployments --as=system:serviceaccount:self-healing:self-healing-sa` → yes |

---

## Risks and Rollback

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Infinite restart loop | Medium (without guards) | Medium | Rate limiter (3/hour), restart count ceiling (10), Alertmanager `repeat_interval: 4h` |
| Restarts destabilize production | Low | High | System namespace exemption. Start with dry-run. Monitor for 1 week before enabling. |
| Receiver crashes silently | Low | Medium | Dead man's switch (Watchdog alert). ntfy notifies on every action. |
| RBAC too broad | Low | Medium | Least-privilege: only `patch` on `deployments/statefulsets/daemonsets`. No `delete`, no `create`. |

**Rollback:** Set `replicas: 0` in the ArgoCD Application. Alertmanager stops receiving 200 responses, but that just means alerts don't get auto-remediated; they still go to ntfy and Telegram for human attention.

---

## Monitoring the Self-Healing Itself

```yaml
# Prometheus metrics from the receiver (if Prometheus endpoint added)
metrics:
  - name: self_healing_actions_total
    type: counter
    labels: [action, result, alertname]
  - name: self_healing_rate_limited_total
    type: counter
  - name: self_healing_dry_run_total
    type: counter
```

Grafana panel: "Self-Healing Actions" showing actions/hour, success/failure ratio, and rate-limit hits.

---

## Official References

- [Alertmanager Webhook Receiver](https://prometheus.io/docs/alerting/latest/configuration/#webhook_config)
- [Alertmanager repeat_interval](https://prometheus.io/docs/alerting/latest/configuration/#route)
- [Alertmanager Inhibition Rules](https://prometheus.io/docs/alerting/latest/configuration/#inhibit_rule)
- [Kubernetes RBAC](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)
- [Velero Backup Hooks (application-consistent)](https://velero.io/docs/v1.18/backup-hooks/)
