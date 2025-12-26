# Technology Stack Reference

> Comprehensive documentation for each technology used in this project.
> Each file covers: overview, architecture, best practices, security concerns,
> configuration examples, and official references.

## Infrastructure & Orchestration

| Technology | File | Role in Project |
|-----------|------|-----------------|
| **K3s** | [k3s.md](k3s.md) | Lightweight Kubernetes distribution (2-node cluster) |
| **Cilium** | [cilium.md](cilium.md) | eBPF-based CNI, kube-proxy replacement, Hubble observability |

## Platform Services

| Technology | File | Role in Project |
|-----------|------|-----------------|
| **ArgoCD** | [argocd.md](argocd.md) | GitOps controller: syncs cluster state from Git |
| **MetalLB** | [metallb.md](metallb.md) | LoadBalancer for bare-metal (Layer 2 ARP) |
| **Traefik** | [traefik.md](traefik.md) | Ingress controller / reverse proxy (replaces K3s built-in) |
| **cert-manager** | [cert-manager.md](cert-manager.md) | TLS certificate lifecycle automation |

## Tooling & Automation

| Technology | File | Role in Project |
|-----------|------|-----------------|
| **Ansible** | [ansible.md](ansible.md) | Node bootstrapping (kubectl, helm, kernel config) |
| **Helm** | [helm.md](helm.md) | Kubernetes package manager (charts for all apps) |

## Observability Stack

| Technology | File | Role in Project |
|-----------|------|-----------------|
| **Prometheus + Grafana** | [prometheus-grafana.md](prometheus-grafana.md) | Metrics collection, alerting, visualization |
| **Loki** | [loki.md](loki.md) | Log aggregation (label-based, index-free) |
| **OpenTelemetry** | [opentelemetry.md](opentelemetry.md) | Unified telemetry pipeline (traces, metrics, logs) |

## Related Docs

- [Phases Overview](../phases-overview.md): End-to-end walkthrough with diagrams
- [Architecture Decisions](../architecture.md): AD-001 through AD-006
- [PLAN.md](../../docs/plan/PLAN.md): Master execution plan with all phases
- [HOW-TO-RUN.md](../../docs/plan/HOW-TO-RUN.md): Step-by-step setup guide
- [Glossary](../glossary.md): Key terms and acronyms
