# Prometheus + Grafana: Cluster Monitoring Stack

> **Prometheus:** [prometheus.io](https://prometheus.io/) · **GitHub:** [prometheus/prometheus](https://github.com/prometheus/prometheus)
> **Grafana:** [grafana.com](https://grafana.com/) · **GitHub:** [grafana/grafana](https://github.com/grafana/grafana)
> **kube-prometheus-stack:** [Helm chart](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
> **CNCF Status:** Both Graduated

## Overview

**Prometheus** is a time-series database and monitoring system that collects metrics
from instrumented targets via a **pull model** (scraping HTTP endpoints at intervals).

**Grafana** is a visualization platform that queries Prometheus (and other datasources)
to create dashboards and alerts.

In Kubernetes, they're deployed together via the **kube-prometheus-stack** Helm chart,
which bundles Prometheus, Alertmanager, Grafana, node-exporter, and kube-state-metrics.

## How It Works

```
 ┌──────────────────────────────────────────────────────────────────┐
 │                     monitoring namespace                          │
 │                                                                   │
 │  ┌───────────────┐    ┌───────────────┐    ┌───────────────────┐ │
 │  │   Prometheus  │    │  Alertmanager │    │     Grafana       │ │
 │  │               │    │               │    │                   │ │
 │  │ ┌───────────┐ │    │ • Routes      │    │ ┌───────────────┐ │ │
 │  │ │   TSDB    │ │    │   alerts      │    │ │ Dashboards    │ │ │
 │  │ │ (blocks)  │ │    │ • Deduplicates│    │ │ (JSON files)  │ │ │
 │  │ └───────────┘ │    │ • Groups      │    │ └───────────────┘ │ │
 │  │               │    │ • Silences    │    │ ┌───────────────┐ │ │
 │  │ Scrapes every │    │               │    │ │ Datasources   │ │ │
 │  │ 30s via HTTP  │    │ Slack/Email/  │    │ │ Prometheus    │ │ │
 │  └───────┬───────┘    │ Webhook       │    │ │ Loki          │ │ │
 │          │            └───────────────┘    │ └───────────────┘ │ │
 │          │ scrape                            └───────────────────┘ │
 │          ▼                                                        │
 │  ┌────────────────────────────────────────────────────────────┐   │
 │  │                     Metric Sources                          │   │
 │  │                                                             │   │
 │  │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌────────────┐ │   │
 │  │  │  node-    │  │  kube-   │  │  Cilium  │  │  App Pods  │ │   │
 │  │  │ exporter  │  │  state-  │  │  metrics │  │  (/metrics)│ │   │
 │  │  │ (host)    │  │  metrics │  │  (eBPF)  │  │            │ │   │
 │  │  │ CPU,RAM,  │  │  (K8s)   │  │  Hubble  │  │  custom    │ │   │
 │  │  │ disk,net  │  │  Deploy, │  │  flows   │  │  app stats │ │   │
 │  │  └──────────┘  │  Pod,Svc │  └──────────┘  └────────────┘ │   │
 │  │                └──────────┘                                 │   │
 │  └────────────────────────────────────────────────────────────┘   │
 └──────────────────────────────────────────────────────────────────┘
```

### ServiceMonitor: Declarative Scraping

Instead of configuring Prometheus scrape targets manually, the Prometheus Operator
uses **ServiceMonitor** CRDs to declaratively define what to scrape:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: traefik
  namespace: monitoring
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: traefik
  endpoints:
    - port: metrics
      interval: 30s
```

The Operator watches for ServiceMonitor resources and automatically configures
Prometheus to scrape matching services.

## Key Features

### 1. Prometheus TSDB

Prometheus stores metrics in a **time-series database** organized into 2-hour blocks:

```
/data/prometheus/
├── wal/                    # Write-Ahead Log (crash safety)
├── 01HABC.../              # 2-hour blocks
│   ├── chunks/             # Compressed sample data
│   ├── index               # Label index
│   ├── meta.json           # Block metadata
│   └── tombstones          # Deleted series markers
└── chunks_head/            # Current (uncompacted) block
```

Key settings:
- `--storage.tsdb.retention.time=15d`: How long to keep data
- `--storage.tsdb.retention.size=50GB`: Or size-based limit
- Blocks are compacted into larger blocks over time

### 2. PromQL: Query Language

```promql
# Rate of HTTP requests per second over 5 minutes
rate(http_requests_total{job="api"}[5m])

# 99th percentile latency
histogram_quantile(0.99, rate(http_request_duration_seconds_bucket[5m]))

# CPU usage % per namespace
sum by (namespace) (rate(container_cpu_usage_seconds_total[5m]))
```

### 3. Grafana Dashboard Provisioning

Dashboards are managed as JSON files: committed to Git and auto-loaded by
Grafana's sidecar container:

```yaml
# observability/dashboards/k8s-cluster.json (excerpt)
{
  "title": "Kubernetes Cluster Overview",
  "uid": "k8s-cluster",
  "panels": [
    {
      "title": "CPU Usage",
      "targets": [
        {
          "expr": "sum(rate(node_cpu_seconds_total{mode!='idle'}[5m]))
                   / sum(machine_cpu_cores) * 100"
        }
      ]
    }
  ]
}
```

### 4. Alertmanager

Routes alerts to notification channels:

```yaml
# PrometheusRule CRD: defines alerting rules
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: cluster-alerts
spec:
  groups:
    - name: node
      rules:
        - alert: HighCPUUsage
          expr: sum(rate(node_cpu_seconds_total{mode!="idle"}[5m]))
                / sum(machine_cpu_cores) > 0.9
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Node CPU usage above 90%"
```

## Best Practices

### Resource Sizing (Homelab)

| Component | CPU Request | Memory Request | Storage |
|-----------|------------|---------------|---------|
| Prometheus | 100m | 256Mi | 15d retention |
| Alertmanager | 50m | 64Mi |: |
| Grafana | 50m | 128Mi | 10Gi (dashboards + DB) |
| node-exporter | 10m | 32Mi |: |
| kube-state-metrics | 10m | 64Mi |: |

### Retention

- **15-30 days** is typical for homelab
- Formula: `samples_per_second × seconds × bytes_per_sample`
- Prometheus averages **1-2 bytes per sample** after compression
- For long-term (>30 days), use Thanos/Mimir remoteWrite

### HA Setup (optional)

```yaml
prometheus:
  prometheusSpec:
    replicas: 2               # Two replicas for HA
    podAntiAffinity: hard     # Spread across nodes
alertmanager:
  alertmanagerSpec:
    replicas: 3               # Odd number for quorum
```

### Metric Cardinality

- **Labels are your enemy**: each unique label combination = new time series
- Avoid labels with unbounded values (user IDs, request IDs, IPs)
- Use `writeRelabelConfigs` to drop high-cardinality labels
- Monitor with: `count({__name__=~".+"})` to check total series count

## Security Considerations

| Concern | Mitigation |
|---------|-----------|
| **Metric data exposure** | Encrypt at rest (filesystem encryption); TLS for endpoints |
| **Grafana admin access** | Set strong password; enable OAuth/OIDC |
| **Prometheus API** | No built-in auth: use reverse proxy (Traefik) with BasicAuth |
| **Node exporter** | Exposes host metrics; restrict with network policies |
| **Alertmanager webhooks** | Use HTTPS; validate webhook endpoints |
| **ServiceMonitor escalation** | Restrict ServiceMonitor creation via RBAC |

## Configuration in This Project

```yaml
# observability/kube-prometheus-stack/values.yaml (key settings)
prometheus:
  prometheusSpec:
    retention: 15d
    scrapeInterval: 30s
    resources:
      requests: { cpu: 100m, memory: 256Mi }
      limits:   { cpu: 500m, memory: 1Gi }
    additionalScrapeConfigs:
      - job_name: 'cilium'           # Scrape Cilium/Hubble metrics
        kubernetes_sd_configs:
          - role: pod
        relabel_configs:
          - source_labels: [__meta_kubernetes_pod_label_k8s_app]
            action: keep
            regex: cilium

grafana:
  persistence:
    enabled: true
    size: 10Gi
  ingress:
    enabled: true
    ingressClassName: traefik
    hosts: [grafana.homelab.local]
  sidecar:
    dashboards: { enabled: true }
    datasources: { enabled: true }

alertmanager:
  enabled: true
```

## Official References

- [Prometheus Overview](https://prometheus.io/docs/introduction/overview/)
- [Prometheus Storage](https://prometheus.io/docs/prometheus/latest/storage/)
- [PromQL Basics](https://prometheus.io/docs/prometheus/latest/querying/basics/)
- [Alerting Rules](https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/)
- [Grafana Documentation](https://grafana.com/docs/grafana/latest/)
- [Grafana Provisioning](https://grafana.com/docs/grafana/latest/administration/provisioning/)
- [kube-prometheus-stack Chart](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [Prometheus Operator](https://github.com/prometheus-operator/prometheus-operator)
