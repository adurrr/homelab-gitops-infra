# Phase 3 Runbook: Observability Stack

> Troubleshooting guide for Prometheus, Grafana, Loki, and OpenTelemetry Collector
> on the homelab cluster.

---

## Prerequisites Checklist

Before deploying Phase 3, verify Phase 2 is healthy:

```bash
# Cluster must be healthy
kubectl get nodes                    # Both nodes Ready
cilium status                        # All OK

# ArgoCD must be running and synced
argocd app list                      # All apps Synced + Healthy

# Platform services must be running
kubectl get pods -n argocd           # ArgoCD pods Running
kubectl get pods -n metallb-system   # MetalLB speakers Running
kubectl get pods -n traefik          # Traefik Running
```

---

## Deployment Steps

### 1. Apply the Observability AppProject

```bash
kubectl apply -f observability/appproject.yaml
```

> **Note:** AppProjects are applied as static resources, NOT through GitOps sync.
> ArgoCD waits for AppProjects to become "Healthy" but they have no health probe,
> causing the sync to hang forever.

### 2. Deploy via ArgoCD

Once the AppProject exists, ArgoCD will automatically sync the observability apps:

```bash
# Watch the sync progress
argocd app list | grep -E "prometheus|loki|otel"

# Or sync manually if needed
argocd app sync prometheus
argocd app sync loki
argocd app sync otel-collector
```

### 3. Verify Deployment

```bash
# All pods should be Running
kubectl get pods -n monitoring

# Services should exist
kubectl get svc -n monitoring

# Run Phase 3 tests
make test-phase3
```

---

## Prometheus Issues

### Prometheus pods stuck in Pending

**Symptom:** `kubectl get pods -n monitoring` shows Prometheus pods in `Pending`.

**Cause:** Insufficient memory. Prometheus requests 256Mi with 1Gi limit.

**Fix:**
```bash
# Check node resources
kubectl describe nodes | grep -A5 "Allocated resources"

# Check if PVC is pending
kubectl get pvc -n monitoring

# If storage is the issue, check local-path provisioner
kubectl get pods -n local-path-storage
```

### Prometheus OOMKilled

**Symptom:** Prometheus pod restarts with `OOMKilled` status.

**Cause:** Too many scrape targets or retention period too long for available memory.

**Fix:**
```bash
# Increase memory limit in values.yaml
# observability/kube-prometheus-stack/values.yaml:
#   prometheus.prometheusSpec.resources.limits.memory: 2Gi

# Or reduce retention
#   prometheus.prometheusSpec.retention: 7d

# Or reduce scrape interval
#   prometheus.prometheusSpec.scrapeInterval: 60s
```

### Prometheus can't scrape Cilium metrics

**Symptom:** Cilium targets show as DOWN in Prometheus UI.

**Cause:** Cilium metrics port not exposed or service monitor misconfigured.

**Fix:**
```bash
# Verify Cilium metrics are enabled
kubectl -n kube-system exec -it ds/cilium -- cilium status | grep -i metrics

# Check if metrics port is exposed
kubectl -n kube-system get pods -l k8s-app=cilium -o jsonpath='{.items[0].spec.containers[?(@.name=="cilium-agent")].ports}'

# Verify the additionalScrapeConfigs are applied
kubectl get secret -n monitoring prometheus-prometheus-kube-prometheus-additional-scrape-configs -o jsonpath='{.data}' | base64 -d | head -20
```

### Prometheus admission webhook failures

**Symptom:** `admission webhook "prometheusrulemutate.monitoring.coreos.com" denied the request`

**Cause:** The prometheus-operator admission webhooks are interfering.

**Fix:**
```bash
# This is already handled in values.yaml:
#   prometheusOperator.admissionWebhooks.enabled: false

# If still failing, delete the webhook configurations
kubectl delete mutatingwebhookconfiguration prometheus-kube-prometheus-admission
kubectl delete validatingwebhookconfiguration prometheus-kube-prometheus-admission
```

---

## Grafana Issues

### Grafana pods CrashLoopBackOff

**Symptom:** Grafana pod keeps restarting.

**Common causes:**

1. **PVC not bound:** Grafana persistence requires a bound PVC.
   ```bash
   kubectl get pvc -n monitoring | grep grafana
   kubectl describe pvc -n monitoring -l app.kubernetes.io/name=grafana
   ```

2. **Sidecar datasource/dashboard errors:** Check sidecar logs.
   ```bash
   kubectl logs -n monitoring -l app.kubernetes.io/name=grafana -c grafana-sc-datasources --tail=50
   kubectl logs -n monitoring -l app.kubernetes.io/name=grafana -c grafana-sc-dashboard --tail=50
   ```

3. **Admin password issue:** If `adminPassword` is set to an empty string, Grafana
   generates a random password stored in a secret.
   ```bash
   kubectl get secret -n monitoring prometheus-grafana -o jsonpath='{.data.admin-password}' | base64 -d
   ```

### Grafana dashboards not loading

**Symptom:** Dashboards don't appear in Grafana UI.

**Cause:** Sidecar not discovering ConfigMaps or label mismatch.

**Fix:**
```bash
# Verify ConfigMaps have the correct label
kubectl get configmap -n monitoring -l grafana_dashboard=1

# Check sidecar logs for discovery errors
kubectl logs -n monitoring -l app.kubernetes.io/name=grafana -c grafana-sc-dashboard --tail=100

# Verify sidecar is configured in values.yaml
#   grafana.sidecar.dashboards.enabled: true
#   grafana.sidecar.dashboards.searchNamespace: monitoring
```

### Grafana datasources not provisioning

**Symptom:** Prometheus or Loki not listed in Grafana datasources.

**Fix:**
```bash
# Verify datasource ConfigMaps exist
kubectl get configmap -n monitoring -l grafana_datasource=1

# Check datasource sidecar logs
kubectl logs -n monitoring -l app.kubernetes.io/name=grafana -c grafana-sc-datasources --tail=100

# Manually check the datasource config
kubectl get configmap prometheus-datasource -n monitoring -o jsonpath='{.data.datasource\.yaml}'
kubectl get configmap loki-datasource -n monitoring -o jsonpath='{.data.datasource\.yaml}'
```

---

## Loki Issues

### Loki pods stuck in Pending

**Symptom:** Loki pod in `Pending` state.

**Cause:** PVC not bound or insufficient resources (Loki requests 2Gi memory).

**Fix:**
```bash
# Check PVC status
kubectl get pvc -n monitoring -l app.kubernetes.io/name=loki

# Check if local-path provisioner is running
kubectl get pods -n kube-system | grep local-path

# If disk space is low
kubectl describe nodes | grep -A3 "Capacity:"
```

### Loki /ready endpoint returns 503

**Symptom:** `curl http://loki.monitoring.svc:3100/ready` returns 503.

**Cause:** Loki is still starting up or schema configuration is invalid.

**Fix:**
```bash
# Check Loki logs for startup errors
kubectl logs -n monitoring -l app.kubernetes.io/name=loki --tail=100

# Verify schema config matches chart version
# For chart 17.x, the schema should be:
#   loki.schemaConfig.configs[0].schema: v13
#   loki.schemaConfig.configs[0].store: tsdb
```

### Loki not receiving logs from OTel

**Symptom:** No logs appear in Loki when querying via Grafana.

**Fix:**
```bash
# Verify OTel Collector is running
kubectl get pods -n monitoring -l app.kubernetes.io/name=opentelemetry-collector

# Check OTel Collector logs for export errors
kubectl logs -n monitoring -l app.kubernetes.io/name=opentelemetry-collector --tail=100 | grep -i error

# Verify OTel Loki exporter config
kubectl get configmap -n monitoring -l app.kubernetes.io/name=opentelemetry-collector -o jsonpath='{.items[0].data}' | grep -A5 "otlphttp/loki"

# Test Loki directly
kubectl port-forward -n monitoring svc/loki 3100:3100 &
curl -X POST http://localhost:3100/loki/api/v1/push \
  -H "Content-Type: application/json" \
  -d '{"streams": [{"stream": {"test": "true"}, "values": [["'"$(date +%s%N)"'", "test log entry"]]}]}'
```

---

## OpenTelemetry Collector Issues

### OTel Collector pods CrashLoopBackOff

**Symptom:** OTel Collector pod keeps restarting.

**Common causes:**

1. **Invalid configuration:** Check the config for syntax errors.
   ```bash
   kubectl logs -n monitoring -l app.kubernetes.io/name=opentelemetry-collector --tail=50
   ```

2. **RBAC permissions missing:** OTel needs to read pod/node metadata.
   ```bash
   kubectl get clusterrole -l app.kubernetes.io/name=opentelemetry-collector
   kubectl get clusterrolebinding -l app.kubernetes.io/name=opentelemetry-collector
   ```

3. **Exporter endpoint unreachable:** Prometheus or Loki not running yet.
   ```bash
   # Verify endpoints are reachable
   kubectl run test-otel --rm -it --image=curlimages/curl --restart=Never -- \
     curl -sf http://prometheus-operated.monitoring.svc:9090/-/healthy
   kubectl run test-otel --rm -it --image=curlimages/curl --restart=Never -- \
     curl -sf http://loki.monitoring.svc:3100/ready
   ```

### OTel Collector health endpoint not responding

**Symptom:** Port-forward to port 13133 fails.

**Cause:** The `health_check` extension is not enabled in the OTel config.

**Fix:**
```bash
# Add health_check extension to the OTel values.yaml:
#   config:
#     extensions:
#       health_check:
#         endpoint: 0.0.0.0:13133
#     service:
#       extensions: [health_check]
#       pipelines: ...
```

### OTel metrics not reaching Prometheus

**Symptom:** Prometheus doesn't show OTel-exported metrics.

**Fix:**
```bash
# Verify Prometheus remote write endpoint is accessible
kubectl run test-otel --rm -it --image=curlimages/curl --restart=Never -- \
  curl -v http://prometheus-operated.monitoring.svc:9090/api/v1/write

# Check if Prometheus has remote write enabled
kubectl get prometheus -n monitoring -o jsonpath='{.items[0].spec}'

# Check OTel Collector logs for export errors
kubectl logs -n monitoring -l app.kubernetes.io/name=opentelemetry-collector --tail=200 | grep -i "prometheusremotewrite"
```

---

## Sync Wave Issues

### Loki or OTel fails because Prometheus isn't ready

**Symptom:** ArgoCD shows Loki or OTel as `Degraded` because exporters can't reach Prometheus.

**Cause:** Sync wave ordering: Loki and OTel (wave 1) may deploy before Prometheus (wave 0) is fully ready.

**Fix:**
```bash
# Wait for Prometheus to be fully ready
kubectl wait --for=condition=ready pod -n monitoring -l app.kubernetes.io/name=prometheus --timeout=300s

# Then sync the dependent apps
argocd app sync loki
argocd app sync otel-collector
```

---

## Resource Pressure

### Monitoring namespace consuming too much memory

**Symptom:** Nodes under memory pressure, pods getting evicted.

**Current resource requests:**

| Component | CPU Request | Memory Request | Memory Limit |
|-----------|-------------|----------------|--------------|
| Prometheus | 100m | 256Mi | 1Gi |
| Grafana | 50m | 128Mi | 256Mi |
| Alertmanager | 50m | 64Mi | - |
| Loki | 500m | 2Gi | 4Gi |
| OTel Collector | 100m | 256Mi | 512Mi |
| **Total** | **~800m** | **~2.7Gi** | **~6.3Gi** |

**Fix:** Reduce resource requests/limits in the respective values.yaml files.
Loki is the biggest consumer: consider reducing retention or memory limits.

```bash
# Check current resource usage
kubectl top pods -n monitoring

# Compare with requests
kubectl describe pods -n monitoring | grep -A2 "Requests:\|Limits:"
```

---

## Quick Reference

### Useful Commands

```bash
# Check all monitoring pods
kubectl get pods -n monitoring

# Check PVC status
kubectl get pvc -n monitoring

# Port-forward to services
kubectl port-forward -n monitoring svc/prometheus-operated 9090:9090 &
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80 &
kubectl port-forward -n monitoring svc/loki 3100:3100 &

# Run Phase 3 tests
make test-phase3

# Check ArgoCD sync status
argocd app list | grep -E "prometheus|loki|otel"
```

### Log Locations

```bash
# Prometheus logs
kubectl logs -n monitoring -l app.kubernetes.io/name=prometheus --tail=100

# Grafana logs
kubectl logs -n monitoring -l app.kubernetes.io/name=grafana --tail=100

# Loki logs
kubectl logs -n monitoring -l app.kubernetes.io/name=loki --tail=100

# OTel Collector logs
kubectl logs -n monitoring -l app.kubernetes.io/name=opentelemetry-collector --tail=100
```
