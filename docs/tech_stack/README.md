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

## Security Foundation

| Technology | File | Role in Project |
|-----------|------|-----------------|
| **Kyverno** | [kyverno.md](kyverno.md) | Policy-as-code: validate, mutate, generate K8s resources |
| **External Secrets Operator** | [external-secrets-operator.md](external-secrets-operator.md) | Secrets abstraction: bridge SealedSecrets to future Vault |

## Notifications

| Technology | File | Role in Project |
|-----------|------|-----------------|
| **ntfy** | [ntfy.md](ntfy.md) | Self-hosted push notifications; replaces RocketChat placeholder |

## Backup Infrastructure

| Technology | File | Role in Project |
|-----------|------|-----------------|
| **Velero** | [velero.md](velero.md) | Kubernetes backup/restore with Kopia file-system backup |
| **MinIO** | [minio.md](minio.md) | S3-compatible object storage backend for Velero |

## Related Docs

- [Phases Overview](../plan/phases-overview.md): End-to-end walkthrough with diagrams
- [Architecture Decisions](../architecture.md): AD-001 through AD-014
- [PLAN.md](../plan/PLAN.md): Master execution plan with all phases
- [HOW-TO-RUN.md](../plan/HOW-TO-RUN.md): Step-by-step setup guide
- [Phase 4: Security Foundation](../plan/phase4-security-foundation.md)
- [Phase 5: Backup Infrastructure](../plan/phase5-backups.md)
- [Phase 6: Self-Healing Alerts](../plan/phase6-self-healing.md)
- [Phase 7: Application Workloads](../plan/phase7-applications.md)
- [Glossary](../glossary.md): Key terms and acronyms
