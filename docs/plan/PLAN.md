# Homelab GitOps Infrastructure: Master Plan

> **Status:** APPROVED: Phase 0 ✅, Phase 1 ✅, Phase 2 ✅, Executing Phase 3
> **Approach:** DevSecOps · TDD · Spec-Driven · Modular · Portfolio-Grade

### 🏗️ Architecture: ARM64 (aarch64)

**All components in this stack fully support ARM64/aarch64.** No compatibility issues.

| Component | ARM64 Support | Notes |
|-----------|:------------:|-------|
| K3s | ✅ | Official multi-arch images, install script auto-detects |
| Cilium | ✅ | Multi-arch container images, eBPF works on ARM64 |
| Hubble | ✅ | Runs as part of Cilium, same support |
| ArgoCD | ✅ | Official ARM64 images since v2.4 |
| Prometheus | ✅ | Multi-arch images via quay.io |
| Grafana | ✅ | Official ARM64 images |
| Loki | ✅ | Official ARM64 images |
| OpenTelemetry Collector | ✅ | Official ARM64 images |
| Home Assistant | ✅ | Primary platform (many users run on RPi) |
| MetalLB | ✅ | Multi-arch manifests |
| Traefik | ✅ | Official ARM64 images |
| cert-manager | ✅ | Official ARM64 images |
| kubectl | ✅ | Official ARM64 binary |
| helm | ✅ | Official ARM64 binary |
| cilium CLI | ✅ | Official ARM64 binary |

**Key consideration:** When downloading binaries or images, always use the `arm64` or `aarch64` variant. The Ansible playbook (Phase 0) handles architecture detection for kubectl and helm automatically.

### ⚠️ Sensitive Data Policy

**No real hostnames, IPs, tokens, or passwords are committed to this repo.**
All environment-specific values live in gitignored `.env` files. Committed templates (`.env.example`) contain only placeholder values. See [Environment Configuration](#environment-configuration) for details.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Repository Structure](#2-repository-structure)
3. [Phase 0: Foundation & Repo Setup](#3-phase-0--foundation--repo-setup)
4. [Phase 1: K3s Cluster with Cilium](#4-phase-1--k3s-cluster-with-cilium)
5. [Phase 2: ArgoCD & GitOps Bootstrap](#5-phase-2--argocd--gitops-bootstrap)
6. [Phase 3: Observability Stack](#6-phase-3--observability-stack)
7. [Phase 4: Home Assistant Application](#7-phase-4--home-assistant-application)
8. [Phase 5: Security Hardening](#8-phase-5--security-hardening)
9. [Phase 6: Documentation & Portfolio Polish](#9-phase-6--documentation--portfolio-polish)
10. [Testing Strategy](#10-testing-strategy)
11. [Risk Register](#11-risk-register)
12. [Glossary](#12-glossary)

---

## 1. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        HOMELAB CLUSTER                              │
│                                                                     │
│  ┌──────────────────────┐    ┌──────────────────────┐              │
│  │   Node 1 (Server)    │    │   Node 2 (Agent)     │              │
│  │   ┌────────────────┐ │    │   ┌────────────────┐ │              │
│  │   │  k3s server    │ │    │   │  k3s agent     │ │              │
│  │   │  + etcd/sqlite │ │    │   │  (workload)    │ │              │
│  │   └────────────────┘ │    │   └────────────────┘ │              │
│  │   ┌────────────────┐ │    │   ┌────────────────┐ │              │
│  │   │  Cilium CNI    │ │    │   │  Cilium CNI    │ │              │
│  │   │  + Hubble      │ │    │   │  + Hubble      │ │              │
│  │   └────────────────┘ │    │   └────────────────┘ │              │
│  └──────────────────────┘    └──────────────────────┘              │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │                    Platform Layer                            │    │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐   │    │
│  │  │ ArgoCD   │  │Traefik   │  │cert-mgr  │  │MetalLB   │   │    │
│  │  │ (GitOps) │  │(Ingress) │  │(TLS)     │  │(LB IP)   │   │    │
│  │  └──────────┘  └──────────┘  └──────────┘  └──────────┘   │    │
│  └─────────────────────────────────────────────────────────────┘    │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │                 Observability Layer                           │    │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐   │    │
│  │  │Prometheus│  │ Grafana  │  │  Loki    │  │  OTel    │   │    │
│  │  │(Metrics) │  │(Visual)  │  │ (Logs)   │  │(Collect) │   │    │
│  │  └─────┬────┘  └────▲─────┘  └────▲─────┘  └────┬─────┘   │    │
│  │        │            │             │              │          │    │
│  │        └────────────┴─────────────┴──────────────┘          │    │
│  └─────────────────────────────────────────────────────────────┘    │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │                 Application Layer                             │    │
│  │  ┌──────────────────────────────────────────────────────┐   │    │
│  │  │              Home Assistant                           │   │    │
│  │  │         (StatefulSet + PVC + Ingress)                │   │    │
│  │  └──────────────────────────────────────────────────────┘   │    │
│  └─────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────┘

         ┌─────────────────────┐
         │   Git Repository    │
         │  (this repo)       │──── ArgoCD watches & syncs ────►
         └─────────────────────┘
```

### Environment Configuration

Real hostnames, IPs, tokens, and passwords are **never committed** to this repository. Instead:

| File | Committed? | Purpose |
|------|-----------|---------|
| `infra/env.example` | ✅ Yes | Template with placeholder values |
| `infra/.env` | ❌ No (gitignored) | Real values: created by copying `env.example` |
| `**/secrets/*.yaml` | ❌ No (gitignored) | Raw K8s secrets (use SealedSecrets instead) |
| `**/*secret*` | ❌ No (gitignored) | Any file with "secret" in the name |

**Workflow:**
```bash
# 1. Copy the template
cp infra/env.example infra/.env

# 2. Fill in your real values
vim infra/.env

# 3. All scripts source this file automatically
source infra/.env
```

**Variables in `infra/.env`:**
```bash
# Node configuration (never commit real values!)
K3S_SERVER_HOST=node-server          # Real: your server hostname
K3S_SERVER_IP=192.168.0.10           # Real: your server IP
K3S_AGENT_HOST=node-worker           # Real: your agent hostname
K3S_AGENT_IP=192.168.0.11           # Real: your agent IP
K3S_TOKEN=                           # Real: your cluster token
KUBECONFIG_PATH=~/.kube/config-homelab

# MetalLB IP pool
METALLB_IP_RANGE=192.168.0.200-192.168.0.210

# Domain configuration
DOMAIN_HOMEASSISTANT=ha.example.com
DOMAIN_GRAFANA=grafana.example.com
DOMAIN_ARGOCD=argocd.example.com

# Timezone
TIMEZONE=America/New_York
```
```

### Data Flow: Observability

```
Applications ──► OTel Collector ──┬──► Prometheus (metrics)
                                  ├──► Loki (logs)
                                  └──► (traces via OTLP)

Prometheus ──► Grafana (datasource: Prometheus)
Loki ────────► Grafana (datasource: Loki)
```

---

## 2. Repository Structure

```
homelab-gitops-infra/
├── README.md                          # Portfolio overview & architecture
├── docs/                              # Documentation
│   ├── plan/                          # Planning docs
│   │   ├── PLAN.md                    # This file: phased execution plan
│   │   ├── HOW-TO-RUN.md              # Step-by-step setup guide
│   │   └── phases-overview.md
│   ├── architecture.md
│   ├── runbooks/
│   └── tech_stack/
├── Makefile                           # Automation: validate, test, deploy
├── .pre-commit-config.yaml            # Pre-commit hooks config
│
├── infra/                              # Phase 1: Cluster infrastructure
│   ├── env.example                     # Template: copy to .env and fill in
│   ├── .env                            # ❌ Gitignored: real IPs/tokens
│   ├── k3s/                            # K3s install scripts & config
│   │   ├── server-install.sh
│   │   ├── agent-install.sh
│   │   ├── config.yaml                 # K3s server config (uses env vars)
│   │   └── agent-config.yaml           # K3s agent config (uses env vars)
│   ├── cilium/                         # Cilium CNI values & manifests
│   │   ├── values.yaml
│   │   └── hubble-values.yaml
│   └── tests/                          # Cluster validation tests
│       ├── test-cluster.sh
│       ├── test-cilium.sh
│       └── test-network-policy.sh
│
├── platform/                           # Phase 2: Platform services
│   ├── argocd/                         # ArgoCD bootstrap
│   │   ├── Chart.yaml                  # App-of-Apps Helm chart
│   │   ├── values.yaml
│   │   └── templates/
│   │       ├── argocd-app.yaml
│   │       └── projects/
│   │           ├── observability.yaml
│   │           └── applications.yaml
│   ├── metallb/                        # LoadBalancer IP pool
│   │   ├── values.yaml
│   │   └── ip-pool.yaml
│   ├── cert-manager/                   # TLS certificate automation
│   │   └── values.yaml
│   └── tests/
│       ├── test-argocd.sh
│       ├── test-metallb.sh
│       └── test-cert-manager.sh
│
├── observability/                      # Phase 3: Monitoring stack
│   ├── kube-prometheus-stack/
│   │   └── values.yaml                 # Prometheus + Grafana + Alertmanager
│   ├── loki/
│   │   └── values.yaml                 # Loki (monolithic mode)
│   ├── otel-collector/
│   │   └── values.yaml                 # OpenTelemetry Collector
│   ├── dashboards/                     # Grafana dashboard ConfigMaps
│   │   ├── k8s-cluster.json
│   │   ├── home-assistant.json
│   │   └── cilium-hubble.json
│   ├── datasources/                    # Grafana datasource ConfigMaps
│   │   ├── prometheus.yaml
│   │   └── loki.yaml
│   └── tests/
│       ├── test-prometheus.sh
│       ├── test-loki.sh
│       ├── test-grafana.sh
│       └── test-otel-pipeline.sh
│
├── apps/                               # Phase 4: Applications
│   ├── home-assistant/
│   │   ├── Chart.yaml                  # Helm chart for HA
│   │   ├── values.yaml
│   │   ├── templates/
│   │   │   ├── statefulset.yaml
│   │   │   ├── service.yaml
│   │   │   ├── ingress.yaml
│   │   │   ├── pvc.yaml
│   │   │   ├── configmap.yaml
│   │   │   └── networkpolicy.yaml
│   │   └── tests/
│   │       ├── test-ha-deployment.yaml  # Spec-driven test
│   │       └── test-ha-connectivity.yaml
│   └── tests/
│       └── test-app-sync.sh
│
├── security/                           # Phase 5: Hardening
│   ├── network-policies/
│   │   ├── default-deny.yaml
│   │   ├── allow-argocd.yaml
│   │   ├── allow-observability.yaml
│   │   └── allow-home-assistant.yaml
│   ├── rbac/
│   │   └── argocd-rbac.yaml
│   ├── secrets/                        # SealedSecrets or External Secrets
│   │   └── README.md
│   └── tests/
│       ├── test-network-policies.sh
│       └── test-rbac.sh
│
├── docs/                               # Phase 6: Documentation
│   ├── architecture.md
│   ├── runbooks/
│   │   ├── cluster-restore.md
│   │   ├── argocd-recovery.md
│   │   └── observability-troubleshooting.md
│   └── glossary.md
│
├── scripts/                            # Shared utility scripts
│   ├── wait-for.sh
│   ├── assert.sh                       # TDD assertion helpers
│   └── kube-check.sh
│
└── .github/                            # CI/CD (future)
    └── workflows/
        └── validate.yaml                # Lint, validate, test pipeline
```

---

## 3. Phase 0: Foundation & Repo Setup

**Goal:** Establish a professional, testable repository with DevSecOps guardrails.

### Specs (Define Before Implementing)

| Spec ID | Description | Validation |
|---------|-------------|------------|
| S0.1 | Repository has valid directory structure | `make validate-structure` passes |
| S0.2 | All YAML files pass `yamllint` and `kubeval` | `make lint` passes |
| S0.3 | All Helm charts pass `helm lint` | `make lint` passes |
| S0.4 | Pre-commit hooks enforce linting and secrets scanning | `pre-commit run --all-files` passes |
| S0.5 | No secrets committed (detected by `gitleaks` or `trufflehog`) | `make scan-secrets` passes |
| S0.6 | Makefile provides `validate`, `lint`, `test`, `scan` targets | `make help` lists all targets |
| S0.7 | Ansible playbook installs kubectl and helm on all nodes | `make ansible-check` passes; `ansible-playbook --syntax-check` passes |
| S0.8 | Ansible playbook is idempotent | Running twice produces no changes on second run |

### Tasks

- [x] **T0.1** Initialize git repo with `.gitignore` (Kubernetes secrets, `.env`, `*.key`, `*.crt`)
- [x] **T0.2** Create directory structure (see §2)
- [ ] **T0.3** Install and configure pre-commit hooks:
  - `yamllint`: YAML linting ✅ configured
  - `helm-docs`: Helm chart doc generation ✅ configured
  - `gitleaks`: Secret detection ✅ configured (needs binary install)
  - `trivy`: Container/image vulnerability scanning ✅ configured (needs binary install)
  - `conftest`: Policy testing (OPA/Rego): future enhancement
  - **Action needed:** Run `pre-commit install` and install gitleaks/trivy binaries
- [x] **T0.4** Create `Makefile` with targets:
  - `validate-structure` ✅
  - `validate-env` ✅
  - `validate-ansible` ✅
  - `validate-yaml` ✅
  - `validate-helm` ✅
  - `lint` ✅
  - `test` / `test-phase0` ✅
  - `scan-secrets` ✅
  - `scan-vulns` ✅
  - `ansible-bootstrap` ✅
  - `ansible-check` ✅
  - `ansible-lint` ✅
  - `help` ✅
- [x] **T0.5** Create `scripts/assert.sh`: TDD assertion helpers (9 functions)
- [x] **T0.6** Create initial `README.md` with project overview, architecture diagram, and links
- [x] **T0.7** Create Ansible playbook for node bootstrapping:
  - Installs `kubectl`, `helm` on all nodes ✅
  - Auto-detects `aarch64`/`x86_64` architecture ✅
  - Configures kernel parameters required by K3s/Cilium ✅
  - Idempotent: safe to run multiple times ✅
  - ansible-lint production profile passes ✅
  - **Note:** Cilium CLI is installed separately in Phase 1 (on the admin machine), not via Ansible
- [x] **T0.8** Write and run tests for Phase 0 (62 assertions, all passing)

### Official References

- Pre-commit: https://pre-commit.com/
- yamllint: https://yamllint.readthedocs.io/
- kubeval: https://kubeval.instrumenta.com/
- gitleaks: https://github.com/gitleaks/gitleaks
- Trivy: https://aquasecurity.github.io/trivy/

---

## 4. Phase 1: K3s Cluster with Cilium

**Goal:** Two-node K3s cluster with Cilium CNI and Hubble observability.

### Specs

| Spec ID | Description | Validation |
|---------|-------------|------------|
| S1.1 | K3s server node is running and healthy | `kubectl get nodes` shows 2 nodes, both `Ready` |
| S1.2 | Flannel is disabled (no flannel pods) | `kubectl -n kube-system get pods -l app=flannel` returns nothing |
| S1.3 | Cilium pods are running on all nodes | `cilium status` reports OK, all nodes |
| S1.4 | Hubble is enabled and collecting flows | `cilium hubble status` shows connected |
| S1.5 | Pod-to-pod cross-node networking works | Test pod can reach pod on other node |
| S1.6 | DNS resolution works cluster-wide | `kubectl run test-dns --rm -it --restart=Never --image=busybox -- nslookup kubernetes.default` |
| S1.7 | Network policies can be enforced by Cilium | Apply test policy, verify enforcement |
| S1.8 | Kubeconfig is saved and works remotely | `kubectl get nodes` works from admin machine |

### Tasks

- [x] **T1.1** Prepare nodes (OS prerequisites):
  ```bash
  # On both nodes: ensure kernel modules
  sudo modprobe overlay && sudo modprobe br_netfilter
  sudo sysctl -w net.bridge.bridge-nf-call-iptables=1
  # Verify kernel >= 5.10 for eBPF/Cilium
  uname -r
  ```
- [x] **T1.2** Install K3s server node:
  ```bash
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='server \
    --flannel-backend=none \
    --disable-network-policy \
    --disable traefik \
    --disable-kube-proxy \
    --disable metrics-server \
    --token=${K3S_TOKEN} \
    --tls-san=${SERVER_IP} \
    --write-kubeconfig-mode=644' sh -
  ```
  - **Why `--disable traefik`?** We'll manage our own ingress via ArgoCD to control versions and config.
  - **Why `--flannel-backend=none`?** Cilium replaces flannel as CNI.
  - **Why `--disable-network-policy`?** Cilium provides its own network policy engine; K3s's default conflicts.
  - **Why `--disable-kube-proxy`?** Cilium replaces kube-proxy with eBPF (`kubeProxyReplacement: true` in values).
  - **Why `--disable metrics-server`?** We'll install it via ArgoCD in Phase 2 to avoid version conflicts.
  - **⚠️ Important:** Pass `INSTALL_K3S_EXEC` as a single line to systemd. Newlines break the unit file parser.
- [x] **T1.3** Copy kubeconfig to admin machine:
  ```bash
  scp server:/etc/rancher/k3s/k3s.yaml ~/.kube/config-homelab
  # Update server URL from 127.0.0.1 to actual IP
  ```
- [x] **T1.4** Install K3s agent node:
  ```bash
  curl -sfL https://get.k3s.io | K3S_URL=https://${SERVER_IP}:6443 \
    K3S_TOKEN=${K3S_TOKEN} sh -
  ```
- [x] **T1.5** Verify cluster:
  ```bash
  kubectl get nodes  # Both nodes Ready
  kubectl get pods -A  # Core pods running
  ```
- [x] **T1.6** Install Cilium via CLI (official method for K3s):
  > **Note:** The Cilium CLI needs to be installed on the admin machine before running `cilium install`.
  > Install it from: https://github.com/cilium/cilium-cli/releases
  > The `cilium install` command wraps Helm under the hood and auto-detects cluster configuration.

  ```bash
  # Set kubeconfig (required for cilium CLI to access the cluster)
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

  # Install Cilium: replaces flannel as CNI, enables Hubble
  cilium install --version 1.19.3 \
    -f infra/cilium/values.yaml
  ```
  **`infra/cilium/values.yaml`:**
  ```yaml
  # Cilium values for K3s homelab
  # Used by: cilium install --version 1.19.3 -f infra/cilium/values.yaml
  # Reference: https://docs.cilium.io/en/stable/installation/k3s
  kubeProxyReplacement: true          # Cilium replaces kube-proxy
  hubble:
    enabled: true
    relay:
      enabled: true
    ui:
      enabled: true
  ipam:
    operator:
      clusterPoolIPv4PodCIDRList: "10.42.0.0/16"  # K3s default
  operator:
    replicas: 1                        # Homelab: 1 is sufficient
  tunnelProtocol: vxlan               # Simpler than geneve for homelab
  ```
- [x] **T1.7** Verify Cilium installation:
  ```bash
  cilium status                          # Check Cilium daemonset status
  cilium connectivity test                # Full connectivity suite
  cilium hubble status                   # Verify Hubble is collecting flows
  ```
- [x] **T1.8** Write and run tests for Phase 1:
  ```bash
  # infra/tests/test-cluster.sh
  assert_eq "$(kubectl get nodes -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' | tr ' ' '\n' | sort | uniq)" "True" "All nodes Ready"
  assert_contains "$(kubectl get pods -n kube-system -l k8s-app=cilium --no-headers)" "Running" "Cilium pods running"
  assert_eq "$(kubectl -n kube-system get pods -l app=flannel 2>&1)" "No resources found" "Flannel disabled"
  # Cross-node connectivity test
  kubectl run test-node --image=busybox --command -- sleep 3600
  kubectl exec test-node -- ping -c 3 <OTHER_NODE_IP>
  ```

### Official References

- K3s Install: https://docs.k3s.io/quick-start
- K3s Custom CNI: https://docs.k3s.io/networking/basic-network-options
- Cilium K3s Guide: https://docs.cilium.io/en/stable/installation/k3s
- Cilium Helm Values: https://github.com/cilium/cilium/tree/main/install/kubernetes/cilium

### Troubleshooting Notes

> Full troubleshooting runbook: [`docs/runbooks/phase1-k3s-cilium.md`](docs/runbooks/phase1-k3s-cilium.md)

| Issue | Symptom | Fix |
|-------|---------|-----|
| Disk full on server | Pods CrashLoopBackOff, `no space left on device` | Clean disk, reinstall K3s |
| Missing `--disable-kube-proxy` | CoreDNS not ready, kube-proxy + Cilium conflict | Reinstall K3s with flag |
| CoreDNS not ready | `plugin/ready: kubernetes not ready`, DNS fails | Fix kube-proxy, restart CoreDNS |
| Hubble Relay crash | DNS lookup timeout for `hubble-peer` | Fix CoreDNS, restart Hubble Relay |
| BPF masquerade conflict | DNS queries timeout, connectivity fails | Remove `enableMasqueradeToRouteSource` and `bpf.masquerade` from values |
| systemd unit error | `bad unit file setting`, `Unbalanced quoting` | Pass `INSTALL_K3S_EXEC` as single line |

---

## 5. Phase 2: ArgoCD & GitOps Bootstrap

**Goal:** ArgoCD deployed and managing all cluster workloads via GitOps.

> **⚠️ Prerequisite:** Phase 1 must be fully healthy before starting Phase 2.
> Verify: `cilium status` shows all OK, `kubectl get pods -n kube-system` shows all Running,
> and DNS works: `kubectl run test --rm -it --image=busybox:1.28 --restart=Never -- nslookup kubernetes.default`

### Specs

| Spec ID | Description | Validation |
|---------|-------------|------------|
| S2.1 | ArgoCD is running in `argocd` namespace | All pods `Running` |
| S2.2 | ArgoCD UI is accessible | HTTP 200 on ArgoCD URL |
| S2.3 | ArgoCD can sync from this Git repo | `argocd app list` shows apps |
| S2.4 | App-of-Apps pattern is configured | Parent app creates child apps |
| S2.5 | ArgoCD project isolates observability and apps | Projects exist with correct source/dest restrictions |
| S2.6 | MetalLB has IP pool configured | `kubectl get ipaddresspool` shows pool |
| S2.7 | cert-manager is issuing certificates | `kubectl get clusterissuers` shows ready |
| S2.8 | All platform services are `Healthy` and `Synced` in ArgoCD | `argocd app get <app> --output json` shows healthy |

### Tasks

- [ ] **T2.1** Install ArgoCD via Helm (managed by itself after bootstrap):
  ```bash
  kubectl create namespace argocd
  helm repo add argo https://argoproj.github.io/argo-helm
  helm install argocd argo/argo-cd \
    --namespace argocd \
    -f platform/argocd/values.yaml
  ```
  **`platform/argocd/values.yaml`:**
  ```yaml
  # ArgoCD production values for homelab
  configs:
    params:
      server.insecure: true  # TLS terminated at Traefik
    rbac:
      policy.csv: |
        g, admin, role:admin
      policy.default: role:readonly
    repositories:
      homelab-gitops-infra:
        url: https://github.com/<YOUR_USER>/homelab-gitops-infra
        type: git

  server:
    ingress:
      enabled: true
      ingressClassName: traefik
      hosts:
        - argocd.homelab.local

  # Resource sizing for homelab
  controller:
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
  repoServer:
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
  server:
    resources:
      requests:
        cpu: 50m
        memory: 128Mi
  ```
- [ ] **T2.2** Get initial admin password and login:
  ```bash
  kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' | base64 -d
  argocd login <ARGOCD_URL> --username admin --password <PASSWORD>
  ```
- [ ] **T2.3** Create ArgoCD projects:
  - `observability`: restricts to observability namespace and repos
  - `applications`: restricts to app namespaces and repos
  - `platform`: for platform services
- [ ] **T2.4** Create App-of-Apps root application:
  ```yaml
  # platform/argocd/templates/argocd-app.yaml
  apiVersion: argoproj.io/v1alpha1
  kind: Application
  metadata:
    name: homelab-apps
    namespace: argocd
    finalizers:
      - resources-finalizer.argoproj.argoproj.io
  spec:
    destination:
      namespace: argocd
      server: https://kubernetes.default.svc
    project: default
    source:
      path: platform/argocd/apps
      repoURL: https://github.com/<YOUR_USER>/homelab-gitops-infra
      targetRevision: HEAD
    syncPolicy:
      automated:
        prune: true
        selfHeal: true
  ```
- [ ] **T2.5** Install MetalLB for LoadBalancer IPs:
  ```bash
  helm repo add metallb https://metallb.github.io/metallb
  helm install metallb metallb/metallb \
    --namespace metallb-system --create-namespace \
    -f platform/metallb/values.yaml
  ```
  **`platform/metallb/values.yaml`:**
  ```yaml
  # MetalLB values: assign IPs from your LAN range
  # Example: 192.168.1.200-192.168.1.210
  ```
  **`platform/metallb/ip-pool.yaml`:**
  ```yaml
  apiVersion: metallb.io/v1beta1
  kind: IPAddressPool
  metadata:
    name: homelab-pool
    namespace: metallb-system
  spec:
    addresses:
      - 192.168.1.200-192.168.1.210  # ADJUST to your LAN
  ---
  apiVersion: metallb.io/v1beta1
  kind: L2Advertisement
  metadata:
    name: homelab-l2
    namespace: metallb-system
  ```
- [ ] **T2.6** Install Traefik (disabled in K3s via `--disable traefik`; we manage it via Helm):
  ```bash
  helm repo add traefik https://traefik.github.io/charts/traefik/
  helm install traefik traefik/traefik \
    --namespace traefik --create-namespace \
    -f platform/traefik/values.yaml
  ```
- [ ] **T2.7** Install cert-manager for TLS:
  ```bash
  helm repo add jetstack https://charts.jetstack.io
  helm install cert-manager jetstack/cert-manager \
    --namespace cert-manager --create-namespace \
    --set installCRDs=true \
    -f platform/cert-manager/values.yaml
  ```
- [ ] **T2.8** Write and run tests for Phase 2:
  ```bash
  # platform/tests/test-argocd.sh
  assert_pod_ready "argocd" "app=argocd-server"
  assert_http_ok "https://argocd.homelab.local" "ArgoCD UI accessible"
  assert_eq "$(argocd app list -o json | jq length)" "0" "ArgoCD responding"
  # platform/tests/test-metallb.sh
  assert_eq "$(kubectl get ipaddresspool -n metallb-system -o jsonpath='{.items[0].spec.addresses[0]}')" "192.168.1.200-192.168.1.210" "MetalLB IP pool configured"
  # platform/tests/test-cert-manager.sh
  assert_eq "$(kubectl get clusterissuers -o jsonpath='{.items[0].status.conditions[0].status}')" "True" "cert-manager ready"
  ```

### Official References

- ArgoCD Install: https://argo-cd.readthedocs.io/en/stable/operator-manual/installation/
- ArgoCD Helm Chart: https://github.com/argoproj/argo-helm/tree/main/charts/argo-cd
- ArgoCD App-of-Apps: https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/
- MetalLB: https://metallb.universe.tf/installation/
- Traefik Helm: https://github.com/traefik/traefik-helm-chart
- cert-manager: https://cert-manager.io/docs/installation/helm/

---

## 6. Phase 3: Observability Stack

**Goal:** Full observability pipeline: metrics (Prometheus), logs (Loki), traces (OTel), visualization (Grafana).

### Specs

| Spec ID | Description | Validation |
|---------|-------------|------------|
| S3.1 | Prometheus is scraping cluster metrics | `kubectl get prometheus -n monitoring` shows active |
| S3.2 | Grafana is accessible and has dashboards | HTTP 200 on Grafana URL, dashboards loaded |
| S3.3 | Grafana has Prometheus and Loki datasources | Datasources listed and healthy in Grafana API |
| S3.4 | Loki is ingesting logs | `logcli query '{app="cilium"}' --limit=5` returns results |
| S3.5 | OTel Collector is running and processing telemetry | Collector metrics endpoint shows pipeline stats |
| S3.6 | Hubble metrics are flowing to Prometheus | Cilium/Hubble dashboard shows network flows |
| S3.7 | Alertmanager is configured with basic rules | `kubectl get alertmanager -n monitoring` shows active |

### Tasks

- [x] **T3.1** Create monitoring namespace:
  ```yaml
  # observability/namespace.yaml
  apiVersion: v1
  kind: Namespace
  metadata:
    name: monitoring
  ```
- [x] **T3.2** Install kube-prometheus-stack (Prometheus + Grafana + Alertmanager):
  ```bash
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
  helm install prometheus prometheus-community/kube-prometheus-stack \
    --namespace monitoring \
    -f observability/kube-prometheus-stack/values.yaml
  ```
  **`observability/kube-prometheus-stack/values.yaml`** (key sections):
  ```yaml
  # Homelab-optimized values
  prometheus:
    prometheusSpec:
      retention: 15d
      scrapeInterval: 30s
      resources:
        requests:
          cpu: 100m
          memory: 256Mi
        limits:
          cpu: 500m
          memory: 1Gi
      additionalScrapeConfigs:
        # Scrape Cilium/Hubble metrics
        - job_name: 'cilium'
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
    adminPassword: ""  # Will be set via sealed secret
    sidecar:
      dashboards:
        enabled: true
        searchNamespace: monitoring
      datasources:
        enabled: true
        searchNamespace: monitoring
    ingress:
      enabled: true
      ingressClassName: traefik
      hosts:
        - grafana.homelab.local
    resources:
      requests:
        cpu: 50m
        memory: 128Mi
      limits:
        cpu: 200m
        memory: 256Mi

  alertmanager:
    enabled: true
    alertmanagerSpec:
      resources:
        requests:
          cpu: 50m
          memory: 64Mi
  ```
- [x] **T3.3** Create Grafana datasource ConfigMaps:
  ```yaml
  # observability/datasources/prometheus.yaml
  apiVersion: v1
  kind: ConfigMap
  metadata:
    name: prometheus-datasource
    namespace: monitoring
    labels:
      grafana_datasource: "1"
  data:
    datasource.yaml: |
      apiVersion: 1
      datasources:
        - name: Prometheus
          type: prometheus
          access: proxy
          url: http://prometheus-operated.monitoring.svc.cluster.local:9090
          isDefault: true
  ---
  # observability/datasources/loki.yaml
  apiVersion: v1
  kind: ConfigMap
  metadata:
    name: loki-datasource
    namespace: monitoring
    labels:
      grafana_datasource: "1"
  data:
    datasource.yaml: |
      apiVersion: 1
      datasources:
        - name: Loki
          type: loki
          access: proxy
          url: http://loki.monitoring.svc.cluster.local:3100
  ```
- [x] **T3.4** Install Loki (monolithic mode for homelab):
  ```bash
  helm repo add grafana https://grafana.github.io/helm-charts
  helm install loki grafana/loki \
    --namespace monitoring \
    -f observability/loki/values.yaml
  ```
  **`observability/loki/values.yaml`:**
  ```yaml
  # Monolithic mode: appropriate for 2-node homelab
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
      retention_period: 672h  # 28 days

  singleBinary:
    replicas: 1
    persistence:
      enabled: true
      size: 50Gi
      storageClassName: local-path

  resources:
    requests:
      cpu: 500m
      memory: 2Gi
    limits:
      cpu: 2
      memory: 4Gi

  # Disable MinIO for homelab (use filesystem)
  minio:
    enabled: false
  ```
- [x] **T3.5** Install OpenTelemetry Collector:
  ```bash
  helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
  helm install otel-collector open-telemetry/opentelemetry-collector \
    --namespace monitoring \
    -f observability/otel-collector/values.yaml
  ```
  **`observability/otel-collector/values.yaml`:**
  ```yaml
  mode: deployment  # Single instance for homelab

  config:
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318

    processors:
      batch:
        timeout: 10s
        send_batch_size: 1024
      memory_limiter:
        check_interval: 5s
        limit_percentage: 80
        spike_limit_percentage: 25
      resourcedetection:
        detectors: [env, system]
      k8sattributes:
        auth_type: serviceAccount
        passthrough: false
        extract:
          metadata:
            - k8s.pod.name
            - k8s.namespace.name
            - k8s.node.name

    exporters:
      # Metrics → Prometheus remote write
      prometheusremotewrite:
        endpoint: http://prometheus-operated.monitoring.svc.cluster.local:9090/api/v1/write
      # Logs → Loki via OTLP
      otlphttp/loki:
        endpoint: http://loki.monitoring.svc.cluster.local:3100/otlp
        tls:
          insecure: true

    service:
      pipelines:
        metrics:
          receivers: [otlp]
          processors: [memory_limiter, k8sattributes, batch]
          exporters: [prometheusremotewrite]
        logs:
          receivers: [otlp]
          processors: [memory_limiter, k8sattributes, batch]
          exporters: [otphttp/loki]
        traces:
          receivers: [otlp]
          processors: [memory_limiter, k8sattributes, batch]
          exporters: [otlphttp/loki]

  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi

  serviceAccount:
    create: true

  clusterRole:
    create: true
    rules:
      - apiGroups: [""]
        resources: ["pods", "namespaces", "nodes"]
        verbs: ["get", "watch", "list"]
  ```
- [x] **T3.6** Add Cilium/Hubble scrape config to Prometheus (via values override).
- [x] **T3.7** Import dashboards:
  - Kubernetes cluster overview
  - Cilium/Hubble network
  - Home Assistant (once deployed)
- [x] **T3.8** Write and run tests for Phase 3:
  ```bash
  # observability/tests/test-prometheus.sh
  assert_pod_ready "monitoring" "app.kubernetes.io/name=prometheus"
  assert_http_ok "http://prometheus-operated.monitoring.svc:9090/-/healthy" "Prometheus healthy"
  # observability/tests/test-loki.sh
  assert_pod_ready "monitoring" "app.kubernetes.io/name=loki"
  assert_http_ok "http://loki.monitoring.svc:3100/ready" "Loki ready"
  # observability/tests/test-grafana.sh
  assert_pod_ready "monitoring" "app.kubernetes.io/name=grafana"
  # Check datasources via API
  curl -s http://grafana.monitoring.svc:3000/api/datasources | jq '.[].name' | grep -q "Prometheus"
  curl -s http://grafana.monitoring.svc:3000/api/datasources | jq '.[].name' | grep -q "Loki"
  # observability/tests/test-otel-pipeline.sh
  assert_pod_ready "monitoring" "app.kubernetes.io/name=otel-collector"
  # Send test telemetry and verify it arrives
  ```

### Official References

- kube-prometheus-stack: https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack
- Loki Helm: https://github.com/grafana/loki/tree/main/production/helm/loki
- OTel Collector Helm: https://github.com/open-telemetry/opentelemetry-helm-charts/tree/main/charts/opentelemetry-collector
- Grafana Provisioning: https://grafana.com/docs/grafana/latest/administration/provisioning/

---

## 7. Phase 4: Home Assistant Application

**Goal:** Home Assistant deployed via ArgoCD with proper persistence, networking, and observability integration.

### Specs

| Spec ID | Description | Validation |
|---------|-------------|------------|
| S4.1 | Home Assistant pod is `Running` | `kubectl get pods -n home-assistant` shows Running |
| S4.2 | PVC is bound and persistent | `kubectl get pvc -n home-assistant` shows Bound |
| S4.3 | Home Assistant UI is accessible via Ingress | HTTP 200 on `https://ha.homelab.local` |
| S4.4 | Health probes are passing | `kubectl describe pod` shows liveness/readiness OK |
| S4.5 | ArgoCD shows HA app as `Healthy` and `Synced` | `argocd app get home-assistant` shows healthy |
| S4.6 | Home Assistant metrics are in Prometheus | Query `homeassistant_*` metrics in Grafana |
| S4.7 | Home Assistant logs are in Loki | Query `{app="home-assistant"}` in Grafana Explore |

### Tasks

- [ ] **T4.1** Create Home Assistant Helm chart structure:
  ```
  apps/home-assistant/
  ├── Chart.yaml
  ├── values.yaml
  ├── templates/
  │   ├── statefulset.yaml
  │   ├── service.yaml
  │   ├── ingress.yaml
  │   ├── pvc.yaml
  │   ├── configmap.yaml
  │   ├── networkpolicy.yaml
  │   ├── servicemonitor.yaml
  │   └── _helpers.tpl
  └── tests/
      ├── test-ha-deployment.yaml
      └── test-ha-connectivity.yaml
  ```
- [ ] **T4.2** Define `values.yaml` with sensible defaults:
  ```yaml
  # apps/home-assistant/values.yaml
  image:
    repository: ghcr.io/home-assistant/home-assistant
    tag: stable
    pullPolicy: IfNotPresent

  replicaCount: 1

  strategy:
    type: Recreate  # Required for PVC + USB passthrough

  persistence:
    enabled: true
    storageClass: local-path
    size: 10Gi

  service:
    type: ClusterIP
    port: 8123

  ingress:
    enabled: true
    className: traefik
    hosts:
      - host: ha.homelab.local
        paths:
          - path: /

  config:
    timezone: "Europe/Madrid"  # ADJUST to your timezone
    trustedProxies:
      - 10.42.0.0/16    # K3s pod CIDR
      - 192.168.0.0/16   # Local network

  # USB device passthrough (uncomment if using Zigbee dongle)
  # usbDevices:
  #   - hostPath: /dev/serial/by-id/usb-Silicon_Labs_Sonoff_Zigbee_Dongle_Plus-if00
  #     containerPath: /dev/ttyACM0

  resources:
    requests:
      cpu: 500m
      memory: 512Mi
    limits:
      cpu: "1"
      memory: 1Gi

  serviceMonitor:
    enabled: true
    interval: 30s

  networkPolicy:
    enabled: true
    ingressFrom:
      - namespace: traefik
      - namespace: monitoring
  ```
- [ ] **T4.3** Create ArgoCD Application manifest for Home Assistant:
  ```yaml
  # apps/home-assistant/argocd-app.yaml
  apiVersion: argoproj.io/v1alpha1
  kind: Application
  metadata:
    name: home-assistant
    namespace: argocd
    finalizers:
      - resources-finalizer.argoproj.argoproj.io
  spec:
    destination:
      namespace: home-assistant
      server: https://kubernetes.default.svc
    project: applications
    source:
      path: apps/home-assistant
      repoURL: https://github.com/<YOUR_USER>/homelab-gitops-infra
      targetRevision: HEAD
      helm:
        valueFiles:
          - values.yaml
    syncPolicy:
      automated:
        prune: true
        selfHeal: true
      syncOptions:
        - CreateNamespace=true
  ```
- [ ] **T4.4** Write Helm chart tests (`apps/home-assistant/tests/`):
  ```yaml
  # test-ha-deployment.yaml: Spec-driven test
  # Tests that the StatefulSet template renders correctly
  ---
  apiVersion: v1
  kind: Pod
  metadata:
    name: test-ha-render
    namespace: home-assistant
  spec:
    containers:
      - name: test
        image: busybox
        command: ['sh', '-c', 'echo "Helm template renders OK"']
  ```
  ```bash
  # test-ha-connectivity.sh
  # Test: HA is reachable via service
  kubectl run test-ha --image=curlimages/curl --rm -it --restart=Never -- \
    curl -sf http://home-assistant.home-assistant.svc:8123/api/ || exit 1
  # Test: Ingress is configured
  curl -sf https://ha.homelab.local/api/ || exit 1
  # Test: PVC is bound
  kubectl get pvc ha-config -n home-assistant -o jsonpath='{.status.phase}' | grep -q Bound
  ```
- [ ] **T4.5** Add ServiceMonitor for Prometheus scraping:
  ```yaml
  # apps/home-assistant/templates/servicemonitor.yaml
  apiVersion: monitoring.coreos.com/v1
  kind: ServiceMonitor
  metadata:
    name: home-assistant
    namespace: home-assistant
    labels:
      release: prometheus
  spec:
    selector:
      matchLabels:
        app: home-assistant
    endpoints:
      - port: http
        interval: 30s
        path: /api/prometheus
  ```
  > **Note:** Home Assistant has a built-in Prometheus endpoint at `/api/prometheus` that must be enabled in HA configuration.
- [ ] **T4.6** Write and run tests for Phase 4:
  ```bash
  # apps/tests/test-app-sync.sh
  assert_eq "$(argocd app get home-assistant -o jsonpath='.status.health.status')" "Healthy" "HA app healthy"
  assert_eq "$(argocd app get home-assistant -o jsonpath='.status.sync.status')" "Synced" "HA app synced"
  assert_pod_ready "home-assistant" "app=home-assistant"
  assert_http_ok "https://ha.homelab.local/api/" "HA UI accessible"
  ```

### Official References

- Home Assistant Container: https://www.home-assistant.io/installation/container/
- Home Assistant Prometheus: https://www.home-assistant.io/integrations/prometheus/
- pajikos Helm Chart: https://github.com/pajikos/home-assistant-helm-chart
- ArgoCD Applications: https://argo-cd.readthedocs.io/en/stable/user-guide/application-specification/

---

## 8. Phase 5: Security Hardening

**Goal:** Apply DevSecOps principles: network policies, RBAC, secrets management, and security scanning.

### Specs

| Spec ID | Description | Validation |
|---------|-------------|------------|
| S5.1 | Default-deny network policy in all namespaces | Pod-to-pod traffic blocked by default |
| S5.2 | Explicit allow policies for each service | Only required traffic flows are permitted |
| S5.3 | ArgoCD RBAC restricts access by project | Non-admin users can only access their project |
| S5.4 | No secrets in plain text in the repo | `gitleaks detect` finds zero secrets |
| S5.5 | Container images scanned for CVEs | `trivy image` shows no critical/high CVEs |
| S5.6 | Pod security standards enforced | No pods running as root (except where required) |
| S5.7 | K3s is hardened per CIS benchmarks | `kube-bench` shows pass on relevant checks |

### Tasks

- [ ] **T5.1** Create default-deny network policies:
  ```yaml
  # security/network-policies/default-deny.yaml
  apiVersion: networking.k8s.io/v1
  kind: NetworkPolicy
  metadata:
    name: default-deny-ingress
  spec:
    podSelector: {}
    policyTypes:
      - Ingress
  ---
  apiVersion: networking.k8s.io/v1
  kind: NetworkPolicy
  metadata:
    name: default-deny-egress
  spec:
    podSelector: {}
    policyTypes:
      - Egress
  ```
  Apply to: `monitoring`, `home-assistant`, `argocd` namespaces.
- [ ] **T5.2** Create allow policies for each service:
  - `allow-argocd.yaml`: ArgoCD → cluster API, ArgoCD → Git
  - `allow-observability.yaml`: Prometheus scrapes, Loki ingests, Grafana serves UI
  - `allow-home-assistant.yaml`: HA → local network (for device discovery), Ingress → HA
- [ ] **T5.3** Configure ArgoCD RBAC:
  ```yaml
  # security/rbac/argocd-rbac.yaml
  # Policy: admin has full access, viewers are read-only
  # Projects restrict which repos/namespaces each team can deploy to
  ```
- [ ] **T5.4** Set up SealedSecrets or External Secrets Operator for secret management:
  ```bash
  helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets/
  helm install sealed-secrets sealed-secrets/sealed-secrets \
    --namespace sealed-secrets --create-namespace
  ```
- [ ] **T5.5** Run security scans:
  ```bash
  # Container image scanning
  trivy image ghcr.io/home-assistant/home-assistant:stable
  trivy image quay.io/cilium/cilium:v1.17.x
  trivy image quay.io/argoproj/argocd:v2.x.x
  # CIS benchmark
  kube-bench run --targets master,node
  ```
- [ ] **T5.6** Write and run tests for Phase 5:
  ```bash
  # security/tests/test-network-policies.sh
  # Test: default deny works
  kubectl run test-deny --image=busybox --rm -it --restart=Never -- \
    wget -q -O- http://home-assistant.home-assistant.svc:8123 && exit 1 || echo "PASS: Default deny works"
  # Test: explicit allow works
  kubectl run test-allow --image=busybox -n monitoring --rm -it --restart=Never -- \
    wget -q -O- http://prometheus-operated.monitoring.svc:9090/-/healthy && echo "PASS: Monitoring allow works"
  # security/tests/test-rbac.sh
  # Test: non-admin cannot modify other project's apps
  ```

### Official References

- K8s Network Policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Cilium Network Policies: https://docs.cilium.io/en/stable/policy/
- SealedSecrets: https://github.com/bitnami-labs/sealed-secrets
- kube-bench: https://github.com/aquasecurity/kube-bench
- Trivy: https://aquasecurity.github.io/trivy/

---

## 9. Phase 6: Documentation & Portfolio Polish

**Goal:** Professional-grade documentation suitable for a portfolio.

### Specs

| Spec ID | Description | Validation |
|---------|-------------|------------|
| S6.1 | README.md has architecture diagram, tech stack, and quickstart | Peer review |
| S6.2 | Each component has a doc explaining what, why, and how | All `docs/` files exist |
| S6.3 | Runbooks exist for common operations | All `docs/runbooks/` files exist |
| S6.4 | All tests pass in a single `make test` command | `make test` exits 0 |
| S6.5 | CI pipeline validates on every push | GitHub Actions workflow exists and passes |

### Tasks

- [ ] **T6.1** Write comprehensive `README.md`:
  - Architecture overview with ASCII diagram
  - Tech stack table with versions
  - Prerequisites (hardware, OS, network)
  - Quickstart guide (one-command bootstrap)
  - Links to each phase's documentation
- [ ] **T6.2** Write `docs/architecture.md`:
  - Detailed architecture decisions
  - Why K3s over kubeadm/kind/minikube
  - Why Cilium over Calico/Flannel
  - Why ArgoCD over Flux
  - Why this observability stack
- [ ] **T6.3** Write runbooks:
  - `cluster-restore.md`: How to recover from node failure
  - `argocd-recovery.md`: How to recover ArgoCD
  - `observability-troubleshooting.md`: Common monitoring issues
- [ ] **T6.4** Write `docs/glossary.md`: Terms and acronyms explained
- [ ] **T6.5** Create GitHub Actions workflow (`.github/workflows/validate.yaml`):
  ```yaml
  name: Validate
  on: [push, pull_request]
  jobs:
    lint:
      runs-on: ubuntu-latest
      steps:
        - uses: actions/checkout@v4
        - name: yamllint
          run: yamllint .
        - name: helm lint
          run: |
            find . -name Chart.yaml -execdir helm lint . \;
        - name: gitleaks
          uses: gitleaks/gitleaks-action@v2
  ```
- [ ] **T6.6** Final review: all tests pass:
  ```bash
  make lint && make test && make scan-secrets
  ```

---

## 10. Testing Strategy

### TDD / Spec-Driven Approach

Every phase follows this cycle:

```
1. WRITE SPEC → Define acceptance criteria (Spec IDs above)
2. WRITE TEST → Create test scripts that validate the spec
3. IMPLEMENT  → Write infrastructure code to make tests pass
4. VERIFY     → Run tests, confirm all specs pass
5. COMMIT     → Git commit with spec ID in message
```

### Test Categories

| Category | Tool | Purpose |
|----------|------|---------|
| **Structure** | `make validate-structure` | Directory layout, file existence |
| **Lint** | yamllint, helm lint, kubeval | Syntax and schema validation |
| **Security** | gitleaks, trivy, kube-bench | Secret detection, CVE scanning, CIS benchmarks |
| **Integration** | Bash scripts with `assert.sh` | Cluster state validation |
| **Policy** | conftest (OPA/Rego) | Policy-as-code for K8s manifests |
| **End-to-End** | `make test` | Full pipeline validation |

### Test Execution

```bash
# Run all tests
make test

# Run phase-specific tests
make test-phase1  # Cluster
make test-phase2  # ArgoCD
make test-phase3  # Observability
make test-phase4  # Home Assistant
make test-phase5  # Security

# Run security scans
make scan-secrets
make scan-vulns
```

---

## 11. Risk Register

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| K3s + Cilium compatibility issues | High | Medium | Pin versions, test in Phase 1 before proceeding |
| Node failure loses data | High | Low | Use local-path PVCs, document backup procedures |
| USB device passthrough issues | Medium | Medium | Use `/dev/serial/by-id/` paths, `strategy: Recreate` |
| Resource exhaustion on 2 nodes | Medium | Medium | Set resource requests/limits, monitor with Prometheus |
| ArgoCD loses sync with repo | Medium | Low | Self-heal enabled, manual sync documented in runbook |
| Loki storage fills up | Low | Medium | Set retention period (28d), monitor disk usage |
| Network policies break services | High | Medium | Test each policy incrementally, have rollback ready |
| **Disk full on server node** | High | Medium | Monitor with Prometheus, set log rotation, alert at 80% |
| **kube-proxy + Cilium conflict** | High | Low | Always use `--disable-kube-proxy` with `kubeProxyReplacement: true` |
| **CoreDNS not ready blocks everything** | High | Low | Verify CoreDNS first; restart after Cilium is healthy |
| **ARM64 Envoy crashes (tcmalloc)** | Medium | High | Use `envoy.enabled: false` (embedded mode works on ARM64) |

---

## 12. Glossary

| Term | Definition |
|------|-----------|
| **CNI** | Container Network Interface: plugin that provides networking to pods |
| **Cilium** | eBPF-based CNI with advanced networking, security, and observability |
| **Hubble** | Cilium's network observability platform |
| **GitOps** | Using Git as single source of truth for declarative infrastructure |
| **ArgoCD** | Kubernetes GitOps controller that syncs Git state to cluster |
| **App-of-Apps** | ArgoCD pattern where one parent Application manages child Applications |
| **OTel** | OpenTelemetry: vendor-neutral telemetry collection framework |
| **PVC** | PersistentVolumeClaim: request for persistent storage |
| **StatefulSet** | K8s workload for stateful applications (stable network ID, persistent storage) |
| **MetalLB** | Load balancer implementation for bare-metal Kubernetes |
| **SealedSecret** | Encrypted K8s Secret that can be stored in Git safely |
| **ServiceMonitor** | Prometheus Operator CRD that defines scrape targets |
| **NetworkPolicy** | K8s resource that controls traffic flow between pods |
| **k3s** | Lightweight Kubernetes distribution by Rancher/SUSE |
| **kube-prometheus-stack** | Helm chart bundling Prometheus Operator, Grafana, Alertmanager |

---

## Execution Checklist

Before starting execution, confirm:

- [ ] **Hardware ready:** 2 nodes (physical or VM) with Linux, kernel ≥ 5.10
- [ ] **Network ready:** Both nodes on same LAN, static IPs assigned
- [ ] **DNS/hosts:** `ha.homelab.local`, `grafana.homelab.local`, `argocd.homelab.local` resolve (or will use `/etc/hosts`)
- [ ] **Git account:** GitHub repository created for this project
- [ ] **Tools installed:** `kubectl`, `helm`, `cilium` CLI, `argocd` CLI on admin machine
- [ ] **Phase 0 complete** before starting Phase 1
- [ ] **Each phase's tests pass** before moving to next phase

---

*This plan is designed to be executed slowly, one phase at a time, with testing at each step. Do not proceed to the next phase until all specs for the current phase are validated.*
