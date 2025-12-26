# OpenTelemetry Collector: Unified Telemetry Pipeline

> **Official site:** [opentelemetry.io](https://opentelemetry.io/) · **Docs:** [opentelemetry.io/docs/collector](https://opentelemetry.io/docs/collector/)
> **GitHub:** [open-telemetry/opentelemetry-collector](https://github.com/open-telemetry/opentelemetry-collector) · **License:** Apache 2.0
> **CNCF Status:** Incubating

## Overview

The OpenTelemetry Collector is a **vendor-agnostic telemetry pipeline** that
receives, processes, and exports **traces, metrics, and logs**. It acts as a
universal intermediary between instrumentation sources and backend storage
systems: handling batching, retries, filtering, and enrichment in one place.

Instead of every application sending directly to Prometheus, Loki, and Jaeger
separately, applications send to the Collector, which fans out to all backends.

## How It Works

```
 ┌─────────────────────────────────────────────────────────────────┐
 │                 OpenTelemetry Collector                          │
 │                                                                  │
 │   Receivers               Processors              Exporters      │
 │  ┌──────────┐           ┌──────────┐           ┌─────────────┐  │
 │  │   OTLP   │           │  Memory  │           │ Prometheus  │  │
 │  │ (gRPC)   │─────┐     │  Limiter │     ┌────►│ RemoteWrite │  │
 │  └──────────┘     │     └──────────┘     │     └─────────────┘  │
 │                   │     ┌──────────┐     │     ┌─────────────┐  │
 │  ┌──────────┐     ├────►│  Batch   │─────┼────►│    Loki     │  │
 │  │Prometheus│─────┘     └──────────┘     │     │   (OTLP)    │  │
 │  │ (scrape) │           ┌──────────┐     │     └─────────────┘  │
 │  └──────────┘           │  K8s     │     │     ┌─────────────┐  │
 │                         │Attribute │─────┤     │   Jaeger    │  │
 │  ┌──────────┐           │ (enrich) │     │     │   (traces)  │  │
 │  │ Filelog  │─────┐     └──────────┘     └────►└─────────────┘  │
 │  │ (logs)   │     │     ┌──────────┐                             │
 │  └──────────┘     ├────►│  Filter  │  (processors are chained    │
 │                   │     │  (drop/  │   in order: memory_limiter  │
 │  ┌──────────┐     │     │   keep)  │   → filter → k8sattributes  │
 │  │Kubelet   │─────┘     └──────────┘   → batch)                  │
 │  │ stats    │                                                    │
 │  └──────────┘                                                    │
 └─────────────────────────────────────────────────────────────────┘
```

## Pipeline Components

### Receivers (data in)

| Receiver | Purpose |
|----------|---------|
| **otlp** | Standard OTLP protocol (gRPC :4317, HTTP :4318) |
| **prometheus** | Scrape Prometheus endpoints (like a mini-Prometheus) |
| **filelog** | Tail container log files (replaces Fluentd/Fluent Bit) |
| **kubeletstats** | Collect kubelet metrics from each node |
| **hostmetrics** | CPU, memory, disk, network from the node |
| **jaeger/zipkin** | Legacy trace protocols |

### Processors (transform)

| Processor | Purpose |
|-----------|---------|
| **memory_limiter** | **Must be first**: prevents OOM by shedding data |
| **batch** | Groups data for efficient export |
| **filter** | Drop or keep telemetry based on conditions |
| **k8sattributes** | Enrich with K8s metadata (pod name, namespace, node) |
| **resourcedetection** | Auto-detect cloud/provider metadata |
| **transform** | Modify telemetry using OTTL (OpenTelemetry Transformation Language) |

### Exporters (data out)

| Exporter | Purpose |
|----------|---------|
| **prometheusremotewrite** | Send metrics to Prometheus via remote_write |
| **otlphttp/loki** | Send logs to Loki via OTLP HTTP endpoint |
| **otlp/jaeger** | Send traces to Jaeger, Tempo, or any OTLP backend |
| **debug** | Print to stdout (development only) |

## Deployment Modes

```
 Agent Pattern (DaemonSet)           Gateway Pattern (Deployment)
 ─────────────────────────           ────────────────────────────

 ┌──────┐ ┌──────┐                   ┌──────┐ ┌──────┐
 │ Pod  │ │ Pod  │                   │ Pod  │ │ Pod  │
 │ OTel │ │ OTel │                   │      │ │      │
 │ side │ │ side │                   └──┬───┘ └──┬───┘
 └──┬───┘ └──┬───┘                      │        │
    │        │                          └───┬────┘
    ▼        ▼                              │
 ┌────────────────┐                 ┌───────▼───────┐
 │  OTel Gateway  │                 │  OTel Gateway │
 │  (Deployment)  │                 │  (Deployment) │
 └────────────────┘                 │  centralized  │
         │                          │  processing   │
         ▼                          └───────┬───────┘
    Backends                                │
                                      Backends
```

**This project:** Uses `mode: deployment`: a single centralized collector handling
all telemetry. For a 2-node cluster, this is simpler than the Agent+Gateway pattern.

## Best Practices

### Processor Order

```yaml
processors:
  memory_limiter:    # ALWAYS FIRST: prevents OOM
  filter:            # Drop unwanted data early
  k8sattributes:     # Enrich before batching
  batch:             # ALWAYS LAST: efficient exports
```

### Resource Sizing

| Mode | CPU | Memory |
|------|-----|--------|
| Agent (DaemonSet) | 200m | 256Mi |
| Gateway (Deployment) | 100m | 256Mi (homelab) |
| Gateway (Production) | 1-2 cores | 512Mi-1Gi |

### Batching

```yaml
processors:
  batch:
    timeout: 10s           # Send at least every 10s
    send_batch_size: 1024  # Up to 1024 items per batch
```

## Security Considerations

| Concern | Mitigation |
|---------|-----------|
| **Unauthenticated OTLP** | Place behind network policy; restrict to internal traffic |
| **Sensitive data leakage** | Use filter/transform processors to redact PII |
| **Memory exhaustion** | `memory_limiter` must be the first processor |
| **gRPC exposure** | Use mTLS between collectors in multi-tier setups |
| **Credential exposure** | Use K8s Secrets for exporter credentials |

## Configuration in This Project

```yaml
# observability/otel-collector/values.yaml
mode: deployment

config:
  receivers:
    otlp:
      protocols:
        grpc:  { endpoint: 0.0.0.0:4317 }
        http:  { endpoint: 0.0.0.0:4318 }

  processors:
    batch:
      timeout: 10s
      send_batch_size: 1024
    memory_limiter:
      check_interval: 5s
      limit_percentage: 80
      spike_limit_percentage: 25
    k8sattributes:
      auth_type: serviceAccount
      extract:
        metadata:
          - k8s.pod.name
          - k8s.namespace.name
          - k8s.node.name

  exporters:
    prometheusremotewrite:
      endpoint: http://prometheus-operated.monitoring:9090/api/v1/write
    otlphttp/loki:
      endpoint: http://loki.monitoring:3100/otlp

  service:
    pipelines:
      metrics:
        receivers: [otlp]
        processors: [memory_limiter, batch]
        exporters: [prometheusremotewrite]
      logs:
        receivers: [otlp]
        processors: [memory_limiter, batch]
        exporters: [otlphttp/loki]
```

**Deployment:** Single deployment in `monitoring` namespace. Receives OTLP data
from instrumented applications and forwards to Prometheus (metrics) and Loki (logs).

## Official References

- [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/)
- [Configuration](https://opentelemetry.io/docs/collector/configuration/)
- [Receivers](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/receiver)
- [Processors](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor)
- [Exporters](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/exporter)
- [Helm Chart](https://github.com/open-telemetry/opentelemetry-helm-charts)
- [Kubernetes Deployment](https://opentelemetry.io/docs/kubernetes/collector/)
- [OTTL Transform Language](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/pkg/ottl)
