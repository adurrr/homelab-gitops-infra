# Loki: Log Aggregation for Kubernetes

> **Official site:** [grafana.com/loki](https://grafana.com/loki/) · **Docs:** [grafana.com/docs/loki](https://grafana.com/docs/loki/latest/)
> **GitHub:** [grafana/loki](https://github.com/grafana/loki) · **License:** AGPL-3.0
> **CNCF Status:** Graduated (as part of Grafana ecosystem)

## Overview

Loki is a **horizontally-scalable, highly-available log aggregation system**
designed to be cost-effective and easy to operate. Unlike Elasticsearch, Loki
**does not index the full text of logs**: it only indexes metadata (labels),
making it significantly cheaper to run.

## How Loki Differs from Elasticsearch

```
 Elasticsearch Approach                    Loki Approach
 ─────────────────────                     ──────────────

 Log: "GET /api 200 15ms"                 Log: "GET /api 200 15ms"
         │                                        │
         ▼                                        ▼
 ┌─────────────────┐                      ┌─────────────────┐
 │ Full text index │                      │ Label index only│
 │ "GET","/api",   │                      │ {app="nginx"}   │
 │ "200","15ms"    │                      └────────┬────────┘
 │ ... big index   │                               │
 └────────┬────────┘                               ▼
          │                              ┌─────────────────┐
          ▼                              │ Compressed chunk │
 ┌─────────────────┐                      │ (raw log data)   │
 │ Raw log stored  │                      └─────────────────┘
 └─────────────────┘
                                          Index: ~1% of log volume
  Index: ~50-100% of log volume            Query: brute-force scan chunks
  Query: fast full-text                    Tradeoff: 10x cheaper storage
```

**Key insight:** Labels filter 99% of irrelevant logs; brute-force scanning
the remaining 1% is fast enough for most use cases.

## Architecture

```
 ┌─────────────────────────────────────────────────────────────────┐
 │                        Loki (monolithic)                         │
 │                                                                  │
 │  ┌──────────────┐   ┌──────────────┐   ┌──────────────────────┐ │
 │  │ Distributor   │   │   Ingester   │   │      Querier        │ │
 │  │               │   │              │   │                      │ │
 │  │ • Validates   │   │ • Appends to │   │ • Executes LogQL     │ │
 │  │   writes      │   │   chunks     │   │ • Merges results     │ │
 │  │ • Consistent  │──►│ • Flushes to │◄──│   from ingesters     │ │
 │  │   hashing     │   │   storage    │   │   + object storage   │ │
 │  │ • Fans out    │   │ • Memory +   │   │                      │ │
 │  │   to ingesters│   │   WAL safety │   │                      │ │
 │  └──────────────┘   └──────┬───────┘   └──────────────────────┘ │
 │                            │                                      │
 │                            │ flush (every 15m or when full)       │
 │                            ▼                                      │
 │                   ┌────────────────┐                             │
 │                   │ Object Store    │                             │
 │                   │ (filesystem or  │                             │
 │                   │  S3/MinIO)      │                             │
 │                   └────────────────┘                             │
 │                                                                  │
 │  ┌──────────────────────────────────────────────────────────────┐│
 │  │ Compactor (daily): merges index files into per-day files     ││
 │  └──────────────────────────────────────────────────────────────┘│
 └─────────────────────────────────────────────────────────────────┘
```

## LogQL: Query Language

Loki's query language is inspired by PromQL:

```logql
# Filter by labels (fast: indexed)
{app="nginx", namespace="production"}

# Filter by content (slower: brute-force)
{app="nginx"} |= "500"

# Regex filter
{app="nginx"} |~ "(?i)error|timeout"

# Create metrics from logs
rate({app="nginx"} |= "500" [5m])

# Aggregate
sum by (status) (count_over_time({app="nginx"}
    | json
    | status =~ "5.." [5m]))
```

## Deployment Modes

| Mode | Use Case | Resources |
|------|----------|-----------|
| **SingleBinary** | Homelab, small clusters | 2-4 GB RAM |
| **SimpleScalable** | Medium; separate read/write/backend | 4+ GB RAM per component |
| **Microservices** | Large; every component separate | 8+ GB RAM per component |

This project uses **SingleBinary** mode: all components in one pod.

## Best Practices

### Label Strategy

```
 Good labels (low cardinality):          Bad labels (high cardinality):
 ──────────────────────────────          ──────────────────────────────
 {app="nginx"}                           {pod="nginx-7d8b9bf866-hfgrz"}
 {namespace="production"}                {container_id="abc123..."}
 {env="prod"}                            {request_id="xyz..."}
 {component="api"}                       {user_id="42"}
```

**Rule of thumb:** Keep streams under ~100 per service. Each unique label
combination = a new stream = a new index entry = more memory.

### Retention

```yaml
loki:
  limits_config:
    retention_period: 672h       # 28 days (for homelab)
    max_entries_limit_per_query: 5000
```

### Resource Sizing (Homelab)

| Component | CPU | Memory | Storage |
|-----------|-----|--------|---------|
| SingleBinary | 500m | 2Gi | 50Gi (filesystem) |

## Security Considerations

| Concern | Mitigation |
|---------|-----------|
| **Log data exposure** | Use Grafana RBAC to control dashboard access |
| **Multi-tenancy** | Loki supports tenant isolation via `X-Scope-OrgID` header |
| **Unauthenticated API** | Place behind reverse proxy (Traefik) with auth |
| **Sensitive data in logs** | Use pipeline stages to redact (drop, replace, hash) |
| **Storage encryption** | Enable encryption at rest if using cloud object storage |

## Loki vs Alternatives

| Tool | Best For | Trade-off |
|------|----------|-----------|
| **Loki** | K8s logs, low cost, Grafana integration | No full-text index |
| **Elasticsearch** | Full-text search, complex queries | Expensive, heavy |
| **Splunk** | Enterprise, compliance | Very expensive |
| **Graylog** | Self-hosted, full-text | Java-heavy, complex |

## Configuration in This Project

```yaml
# observability/loki/values.yaml
deploymentMode: SingleBinary

loki:
  schemaConfig:
    configs:
      - from: "2024-01-01"
        store: tsdb
        object_store: filesystem
        schema: v13
        index:
          prefix: loki_index_
          period: 24h
  limits_config:
    allow_structured_metadata: true
    retention_period: 672h         # 28 days

singleBinary:
  replicas: 1
  persistence:
    enabled: true
    size: 50Gi

minio:
  enabled: false                   # Use filesystem, not MinIO
```

**Deployment:** SingleBinary with filesystem storage: simplest setup for homelab.
Grafana connects via Loki datasource (`http://loki.monitoring:3100`).

## Official References

- [Loki Documentation](https://grafana.com/docs/loki/latest/)
- [Architecture](https://grafana.com/docs/loki/latest/get-started/architecture/)
- [LogQL](https://grafana.com/docs/loki/latest/query/)
- [Best Practices](https://grafana.com/docs/loki/latest/best-practices/)
- [Helm Chart](https://github.com/grafana/helm-charts/tree/main/charts/loki)
- [Loki vs Elasticsearch](https://grafana.com/docs/loki/latest/get-started/comparisons/)
