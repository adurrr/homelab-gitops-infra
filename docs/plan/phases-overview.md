# Homelab GitOps Infrastructure: Phases Overview

> Comprehensive guide covering the architecture, components, and deployment flows
> for each phase. Written for learners and contributors who want to understand
> not just **what** was built, but **why** and **how**.

---

## Table of Contents

- [System Architecture](#system-architecture)
- [Phase 0: Foundation & Repository Setup](#phase-0-foundation--repository-setup)
- [Phase 1: K3s Cluster with Cilium](#phase-1-k3s-cluster-with-cilium)
- [Phase 2: ArgoCD & GitOps Bootstrap](#phase-2-argocd--gitops-bootstrap)
- [Phase 3: Observability Stack](#phase-3-observability-stack)
- [Key Concepts Glossary](#key-concepts-glossary)

---

## System Architecture

### Physical Topology

```
 ┌──────────────────────────────────────────────────────────────┐
 │                      HOME NETWORK                             │
 │                     <LAN_SUBNET>                           │
 │                                                               │
 │  ┌─────────────────────┐       ┌─────────────────────┐       │
 │  │     Node 1: server    │       │    Node 2: agent    │       │
 │  │  ┌───────────────┐  │       │  ┌───────────────┐  │       │
 │  │  │  k3s server   │  │       │  │   k3s agent   │  │       │
 │  │  │  (control-plane)│  │◄─────┼──│  (workload)   │  │       │
 │  │  │  + SQLite      │  │  k3s  │  │               │  │       │
 │  │  └───────────────┘  │ token │  └───────────────┘  │       │
 │  │  ┌───────────────┐  │       │  ┌───────────────┐  │       │
 │  │  │  Cilium CNI   │  │       │  │  Cilium CNI   │  │       │
 │  │  │  + Hubble     │  │       │  │  + Hubble     │  │       │
 │  │  └───────────────┘  │       │  └───────────────┘  │       │
 │  └─────────────────────┘       └─────────────────────┘       │
 │                                                               │
 │  ┌──────────────────────────────────────────────────────┐    │
 │  │              PLATFORM SERVICES (Phase 2)              │    │
 │  │                                                       │    │
 │  │  MetalLB               Traefik                        │    │
 │  │  IPs: <METALLB_IP>   Entrypoints: :80, :443         │    │
 │  │  ─────────────────     ──────────────────────         │    │
 │  │  L2 Advertisement      Ingress + TLS termination      │    │
 │  │                                                       │    │
 │  │  ArgoCD                cert-manager                   │    │
 │  │  GitOps controller     TLS certificate automation     │    │
 │  │  ────────────────      ──────────────────────         │    │
 │  │  App-of-Apps pattern   Self-signed + Let's Encrypt    │    │
 │  └──────────────────────────────────────────────────────┘    │
 └──────────────────────────────────────────────────────────────┘
```

### GitOps Flow

```
   GitHub Repository               ArgoCD                   Kubernetes Cluster
  ┌──────────────────┐      ┌─────────────────┐      ┌────────────────────────┐
  │                  │      │                 │      │                        │
  │ platform/argocd/ │      │  homelab-apps   │      │  namespace: argocd     │
  │   apps/          │─────►│  (root app)     │─────►│  ┌──────────────────┐  │
  │   ├─ argocd.yaml │ pull │                 │ sync │  │ Application CRDs │  │
  │   ├─ metallb.... │      │  watches:       │      │  │ argocd, traefik, │  │
  │   ├─ traefik.... │      │  platform/argocd│      │  │ metallb, cert-mgr│  │
  │   └─ cert-mgr... │      │  /apps/         │      │  └────────┬─────────┘  │
  │                  │      │                 │      │           │            │
  │  bootstrap/      │      └─────────────────┘      │           ▼            │
  │   └─ argocd-app  │                               │  Child apps deploy     │
  │       .yaml      │                               │  Helm charts → pods    │
  └──────────────────┘                               └────────────────────────┘
```

### Component Interaction Diagram

```
                      ┌──────────────────────────────────────────┐
                      │              Home Network                 │
                      │                                          │
  User ───────────────┤                                          │
                      │  ┌─────────┐     ┌─────────┐            │
                      │  │ Traefik │────►│ Service │            │
                      │  │ :80/443 │     │ (argocd │            │
                      │  └────┬────┘     │  .local) │            │
                      │       │          └─────────┘            │
                      │  ┌────▼────┐                              │
                      │  │ MetalLB │                              │
                      │  │  .230   │                              │
                      │  └─────────┘                              │
                      │                                          │
                      │  ┌─────────────────────────────────┐    │
                      │  │          Cilium eBPF             │    │
                      │  │  Pod Network (10.42.0.0/16)      │    │
                      │  │  kube-proxy replacement          │    │
                      │  │  Hubble observability            │    │
                      │  └─────────────────────────────────┘    │
                      └──────────────────────────────────────────┘
```

---

## Phase 0: Foundation & Repository Setup

> **Goal:** Establish a professional, testable repository with DevSecOps guardrails
> before any cluster infrastructure exists.

### What Phase 0 Delivers

Phase 0 sets up the **repository scaffolding**: directory structure, automation tools,
quality gates, and node bootstrapping. No Kubernetes cluster exists yet at this point.

### Directory Structure

```
homelab-gitops-infra/
├── ansible/              # Node bootstrapping (kubectl, helm, kernel params)
│   ├── playbook.yml
│   ├── roles/
│   │   ├── bootstrap-node/   # Kernel modules, sysctl, swap off
│   │   ├── install-kubectl/  # Architecture-aware kubectl install
│   │   └── install-helm/     # Architecture-aware helm install
│   └── inventory.example.yml
├── infra/                # Cluster infrastructure configs
│   ├── k3s/                  # Server/agent install scripts
│   ├── cilium/               # Cilium values template
│   └── .env                  # Real values (gitignored)
├── platform/             # Platform services (Phase 2+)
├── observability/        # Monitoring stack (Phase 3+)
├── apps/                 # Application workloads (Phase 4+)
├── security/             # Hardening (Phase 5)
├── docs/                 # Documentation
├── scripts/              # TDD helpers (assert.sh)
├── Makefile              # Automation (validate, lint, test, deploy)
├── .pre-commit-config.yaml
└── .gitignore
```

### Component: Ansible Playbook

```
                Admin Machine                   Target Nodes
               ┌──────────┐                  ┌─────────────────┐
               │ Ansible  │                  │  Node (ARM64)    │
               │ Playbook │ ── SSH ────────► │                  │
               │          │                  │  ┌─────────────┐ │
               │ Roles:   │                  │  │ bootstrap   │ │
               │ ├─ node   │                  │  │ - kernel    │ │
               │ ├─ kubectl│                  │  │   modules   │ │
               │ └─ helm   │                  │  │ - sysctl    │ │
               └──────────┘                  │  │ - swap off  │ │
                                              │  ├─────────────┤ │
                                              │  │ kubectl     │ │
                                              │  │ v1.36 (arm64)│ │
                                              │  ├─────────────┤ │
                                              │  │ helm        │ │
                                              │  │ v4.1 (arm64) │ │
                                              │  └─────────────┘ │
                                              └─────────────────┘
```

**What it does on each node:**

| Step | Action | Why |
|------|--------|-----|
| 1 | Install `curl`, `socat`, `conntrack` | Prerequisites for K3s |
| 2 | Load kernel modules: `overlay`, `br_netfilter` | Required for container networking |
| 3 | Set sysctl: `net.ipv4.ip_forward=1`, `net.bridge.bridge-nf-call-iptables=1` | Enables pod-to-pod routing |
| 4 | Disable swap | Kubernetes requires swap off |
| 5 | Install `kubectl` (version-pinned, ARM64-aware) | Cluster management |
| 6 | Install `helm` (version-pinned, ARM64-aware) | Chart management |

**Why Ansible?**

- **Idempotent**: running twice produces no changes
- **Declarative**: describes desired state, not commands
- **Architecture-aware**: auto-detects `aarch64` vs `x86_64`
- **Auditable**: changes tracked in git, not ad-hoc SSH commands

### Component: TDD Framework

```
  1. Write spec                  2. Write test               3. Implement
  ┌──────────┐                 ┌──────────┐               ┌──────────┐
  │ Spec ID  │                 │ assert.sh│               │ Code /   │
  │ S0.1:    │ ──────────────► │          │ ────────────► │ Config   │
  │ dirs OK  │   defines what  │ test_*() │   validates   │          │
  └──────────┘   to test       └──────────┘   behavior    └──────────┘
```

The `scripts/assert.sh` library provides 9 assertion functions (`assert_eq`, `assert_contains`, `assert_file_exists`, etc.) that output colored pass/fail results with summaries.

### Component: Pre-commit Hooks

```
  git commit
      │
      ▼
  ┌───────────┐     ┌───────────┐     ┌───────────┐
  │ yamllint  │────►│ gitleaks  │────►│shellcheck │
  │ YAML lint │     │ secret    │     │ shell lint│
  └───────────┘     │ scan      │     └───────────┘
                    └───────────┘
                          │
                          ▼
                    ┌───────────┐
                    │ All pass? │
                    └─────┬─────┘
                     Yes  │  No → Commit blocked
                          ▼
                     Commit created
```

| Hook | Purpose | When It Catches Issues |
|------|---------|----------------------|
| **yamllint** | Validates YAML syntax and style | Mis-indented YAML, trailing spaces |
| **gitleaks** | Scans for secrets/keys/tokens | Accidental credential commits |
| **shellcheck** | Lints shell scripts | Unquoted variables, bad syntax |
| **check-yaml** | Validates YAML file structure | Invalid YAML documents |
| **fix end of files** | Ensures newline at EOF | Missing trailing newlines |

### Component: Makefile Automation

```
  make <target>
      │
      ├── make validate      ───►  Run all validations
      │    ├── validate-structure
      │    ├── validate-env
      │    ├── validate-ansible
      │    ├── validate-yaml
      │    └── validate-helm
      │
      ├── make lint          ───►  yamllint + ansible-lint
      ├── make test-phase0   ───►  65 assertions
      ├── make scan-secrets  ───►  gitleaks scan
      ├── make scan-vulns    ───►  trivy scan
      ├── make ansible-bootstrap ─► Deploy to nodes
      └── make help          ───►  List all targets
```

### Phase 0 Delivery Checklist

| Check | Status |
|-------|--------|
| Directory structure exists | ✅ |
| `.gitignore` protecting `.env`, secrets, keys | ✅ |
| Pre-commit hooks active | ✅ |
| Makefile with 12+ targets | ✅ |
| Ansible playbook (3 roles, idempotent) | ✅ |
| TDD framework (`assert.sh`) | ✅ |
| All 65 Phase 0 tests passing | ✅ |
| `ansible-lint` production profile passing | ✅ |

**Official References:**
- [Ansible Documentation](https://docs.ansible.com/)
- [Pre-commit Framework](https://pre-commit.com/)
- [yamllint](https://yamllint.readthedocs.io/)
- [gitleaks](https://github.com/gitleaks/gitleaks)
- [ShellCheck](https://www.shellcheck.net/)

---

## Phase 1: K3s Cluster with Cilium

> **Goal:** Two-node ARM64 Kubernetes cluster with eBPF-based networking
> and built-in observability.

### What Phase 1 Delivers

A fully functional Kubernetes cluster: 1 server (control-plane) + 1 agent (workload),
with Cilium replacing K3s built-in networking components for better performance
and observability.

### Component: K3s: Lightweight Kubernetes

K3s is a **CNCF-certified Kubernetes distribution** packaged as a single binary (~100MB).
It bundles the control-plane, container runtime (containerd), and networking into one process.

**K3s vs kubeadm:**

| Aspect | kubeadm | K3s |
|--------|---------|-----|
| Binary size | ~500MB+ (multiple binaries) | ~100MB (single binary) |
| Installation | Multi-step with system dependencies | Single `curl | sh` command |
| Datastore | Requires external etcd | Embedded SQLite (or etcd for HA) |
| Container runtime | Requires separate containerd/CRI-O | Bundled containerd |
| CNI | Must install separately | Bundled Flannel (replaceable) |
| ARM64 support | Requires custom builds | First-class support |

**K3s Server/Agent Architecture:**

```
 ┌─────────────┐                    ┌─────────────┐
 │ K3s Server   │                    │ K3s Agent    │
 │              │                    │              │
 │ ┌──────────┐ │    WebSocket       │ ┌──────────┐ │
 │ │API Server│ │◄───────────────────│ │ kubelet  │ │
 │ │Scheduler │ │                    │ │          │ │
 │ │Controller│ │                    │ │ containerd│ │
 │ └──────────┘ │                    │ └──────────┘ │
 │ ┌──────────┐ │                    │ ┌──────────┐ │
 │ │  SQLite   │ │                    │ │Cilium CNI│ │
 │ │(embedded)  │ │                    │ │(eBPF)    │ │
 │ └──────────┘ │                    │ └──────────┘ │
 │              │                    │              │
 │  server       │                    │  agent      │
 │  <CONTROL_PLANE_IP>│                   │  <WORKER_IP>│
 └─────────────┘                    └─────────────┘
```

**Disabled K3s Components (replaced by GitOps-managed alternatives):**

| K3s Built-in | Disabled with | Replaced by | Why |
|-------------|--------------|-------------|-----|
| Flannel CNI | `--flannel-backend=none` | Cilium | eBPF performance, network policies, Hubble |
| kube-proxy | `--disable-kube-proxy` | Cilium eBPF | O(1) hash lookups vs O(n) iptables |
| Traefik v1 | `--disable traefik` | Traefik v3 (Helm) | Newer version, better CRD support |
| ServiceLB | `--disable servicelb` | MetalLB | More features, BGP support |
| Network Policy | `--disable-network-policy` | Cilium | L3-L7 identity-based policies |
| Metrics Server | `--disable metrics-server` | ArgoCD-managed | Version control via GitOps |

### Component: Cilium: eBPF-Based CNI

Cilium uses **eBPF** (extended Berkeley Packet Filter) to run networking programs
directly in the Linux kernel, replacing iptables-based networking.

**How eBPF Replaces kube-proxy:**

```
 Traditional (kube-proxy + iptables)       Cilium (eBPF)
 ─────────────────────────────────         ──────────────

 Pod A → iptables rules → Pod B            Pod A → eBPF map → Pod B
         O(n) sequential search                   O(1) hash lookup
         Every rule checked                       Direct backend selection
         Flush & rewrite on changes               Atomic map update

 Service IP: 10.43.0.1:443                Service IP resolved at socket level
 → DNAT at prerouting (per packet)         → connect() syscall intercepted
                                           → Backend chosen before packet exists
```

**Cilium Deployment on K3s:**

```
 ┌─────────────────────────────────────────────────────────┐
 │                     Cilium DaemonSet                     │
 │                                                         │
 │  ┌─────────────────────┐    ┌─────────────────────┐    │
 │  │   Node: server        │    │   Node: agent       │    │
 │  │ ┌─────────────────┐ │    │ ┌─────────────────┐ │    │
 │  │ │ cilium-agent    │ │    │ │ cilium-agent    │ │    │
 │  │ │ - programs eBPF │ │    │ │ - programs eBPF │ │    │
 │  │ │ - manages IPAM  │ │    │ │ - manages IPAM  │ │    │
 │  │ │ - enforces NW   │ │    │ │ - enforces NW   │ │    │
 │  │ │   policy         │ │    │ │   policy         │ │    │
 │  │ └─────────────────┘ │    │ └─────────────────┘ │    │
 │  │ ┌─────────────────┐ │    │ ┌─────────────────┐ │    │
 │  │ │ hubble-relay    │ │    │ │ hubble-ui       │ │    │
 │  │ │ - collects flows│ │    │ │ - visualizes    │ │    │
 │  │ └─────────────────┘ │    │ │   network flows │ │    │
 │  └─────────────────────┘    │ └─────────────────┘ │    │
 │                              └─────────────────────┘    │
 └─────────────────────────────────────────────────────────┘
```

**Key Cilium Configuration (`infra/cilium/values.yaml`):**

| Setting | Value | Purpose |
|---------|-------|---------|
| `kubeProxyReplacement` | `true` | Replace kube-proxy with eBPF |
| `tunnelProtocol` | `vxlan` | Overlay networking (simpler than geneve) |
| `ipam.operator.clusterPoolIPv4PodCIDRList` | `10.42.0.0/16` | Match K3s default pod CIDR |
| `hubble.enabled` | `true` | Enable network flow observability |
| `hubble.relay.enabled` | `true` | Aggregate flows from all nodes |
| `hubble.ui.enabled` | `true` | Web UI for flow visualization |
| `operator.replicas` | `1` | Sufficient for 2-node homelab |

### Deployment Sequence: Phase 1

```
 Step 1: Ansible Bootstrap        Step 2: Install K3s Server
 ┌──────────────────┐             ┌──────────────────────┐
 │ Install kubectl  │             │ curl get.k3s.io | sh │
 │ Install helm     │             │ --disable traefik    │
 │ Kernel modules   │             │ --disable servicelb  │
 │ Sysctl params    │             │ --flannel-backend=none│
 │ Swap off         │             │ --disable-kube-proxy │
 └────────┬─────────┘             └──────────┬───────────┘
          │                                  │
          ▼                                  ▼
 ┌──────────────────┐             ┌──────────────────────┐
 │ Both nodes ready │             │ K3s server running   │
 │ for K3s install  │             │ on server             │
 └──────────────────┘             └──────────┬───────────┘
                                             │
         Step 3: Join Agent                  │   Step 4: Install Cilium
 ┌──────────────────────┐                    │  ┌──────────────────────┐
 │ curl get.k3s.io | sh │◄───────────────────┘  │ cilium install       │
 │ K3S_URL=server:6443  │                       │ --version 1.19.3     │
 │ K3S_TOKEN=<token>    │                       │ -f cilium/values.yaml│
 └──────────┬───────────┘                       └──────────┬───────────┘
            │                                              │
            ▼                                              ▼
 ┌──────────────────────┐                       ┌──────────────────────┐
 │ Agent joined cluster │                       │ Cilium CNI active    │
 │ agent → Ready       │                       │ Hubble observability │
 └──────────────────────┘                       │ Both nodes covered   │
                                                └──────────────────────┘
```

### Phase 1 Delivery Checklist

| Check | Status |
|-------|--------|
| Both nodes Ready (`kubectl get nodes`) | ✅ |
| K3s server (server) + agent (agent) | ✅ |
| Flannel disabled (no flannel pods) | ✅ |
| Cilium running on all nodes | ✅ |
| kube-proxy replaced by Cilium eBPF | ✅ |
| Hubble relay + UI running | ✅ |
| Cross-node pod networking | ✅ |
| DNS resolution cluster-wide | ✅ |

**Official References:**
- [K3s Architecture](https://docs.k3s.io/architecture)
- [K3s Installation Options](https://docs.k3s.io/installation/configuration)
- [K3s Managing Packaged Components](https://docs.k3s.io/installation/packaged-components)
- [Cilium Overview](https://docs.cilium.io/en/stable/overview/intro/)
- [Cilium on K3s](https://docs.cilium.io/en/stable/gettingstarted/k3s/)
- [Cilium kube-proxy Replacement](https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/)
- [Hubble Observability](https://docs.cilium.io/en/stable/observability/)

---

## Phase 2: ArgoCD & GitOps Bootstrap

> **Goal:** Deploy platform services (ArgoCD, MetalLB, Traefik, cert-manager)
> using GitOps: all configuration lives in Git, ArgoCD reconciles the cluster.

### What Phase 2 Delivers

A GitOps-managed platform layer where every service is defined as an ArgoCD
Application and automatically deployed from the Git repository.

### Component: ArgoCD: GitOps Controller

ArgoCD is a **declarative continuous delivery tool** for Kubernetes. It continuously
monitors the Git repository and compares the **desired state** (manifests in Git) with
the **live state** (what's running in the cluster).

**ArgoCD Architecture:**

```
 ┌──────────────────────────────────────────────────────────────┐
 │                      ArgoCD (argocd namespace)                │
 │                                                               │
 │  ┌─────────────────┐  ┌─────────────────┐  ┌──────────────┐ │
 │  │   API Server    │  │  Repo Server    │  │ Application  │ │
 │  │                 │  │                 │  │ Controller   │ │
 │  │ - Web UI        │  │ - Git cache     │  │ - Compare    │ │
 │  │ - gRPC/REST API │  │ - Helm render   │  │   desired vs │ │
 │  │ - Auth/RBAC     │  │ - Kustomize     │  │   live state │ │
 │  │                 │  │ - Plugin exec   │  │ - Detect     │ │
 │  └────────┬────────┘  └────────┬────────┘  │   OutOfSync  │ │
 │           │                    │            │ - Trigger    │ │
 │           └────────────────────┼────────────│   sync       │ │
 │                                │            └──────┬───────┘ │
 │                                ▼                    │         │
 │                    ┌───────────────────┐            │         │
 │                    │   Git Repository  │◄───────────┘         │
 │                    │   (GitHub)        │  watches & compares  │
 │                    └───────────────────┘                      │
 └──────────────────────────────────────────────────────────────┘
```

**Core ArgoCD Concepts:**

| Concept | Kubernetes Resource | Purpose |
|---------|-------------------|---------|
| **Application** | `Application` CRD | Groups K8s resources defined by a Git path |
| **AppProject** | `AppProject` CRD | Logical grouping of apps with RBAC and source/dest restrictions |
| **Sync** | Operation | Reconciles live state to match desired state in Git |
| **Health** | Status | Whether the app's resources are running correctly |
| **Refresh** | Operation | Re-compares Git vs live state without syncing |

**App-of-Apps Pattern (used in this project):**

```
  ┌─────────────────────────────────────────────────┐
  │              homelab-apps (Root App)             │
  │  Source: platform/argocd/apps/                   │
  │  Project: default                                │
  │  SyncPolicy: automated (prune + selfHeal)        │
  └──────────────────────┬──────────────────────────┘
                         │ creates & manages
          ┌──────────────┼──────────────┬──────────────┬──────────────┐
          ▼              ▼              ▼              ▼              ▼
    ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐
    │ argocd   │  │ metallb  │  │ metallb  │  │ traefik  │  │ cert-    │
    │ (self)   │  │          │  │ -config  │  │          │  │ manager  │
    └──────────┘  └──────────┘  └──────────┘  └──────────┘  └──────────┘
    wave: -1      wave: 0       wave: 1       wave: 1       wave: 1
```

**Sync Wave Ordering:**

| Wave | App | Reason |
|------|-----|--------|
| **-1** | `argocd` | Must deploy before other apps (self-managed; upgrades flow through Git) |
| **0** | `metallb` | CRDs must exist before config is applied |
| **1** | `metallb-config`, `traefik`, `cert-manager` | No ordering dependencies between them |

**Bootstrap Flow (one-time manual step):**

```
  kubectl apply -f bootstrap/argocd-app.yaml
                    │
                    ▼
  ┌──────────────────────────────────────┐
  │  ArgoCD creates "homelab-apps" app   │
  │  ──────────────────────────────────  │
  │  Reads platform/argocd/apps/         │
  │  Finds 5 child Application YAMLs     │
  │  Creates them as Application CRDs    │
  └──────────────────┬───────────────────┘
                     │
                     ▼
  ┌──────────────────────────────────────┐
  │  Child apps sync their Helm charts   │
  │  ──────────────────────────────────  │
  │  argocd      → argo-cd chart 9.5.15 │
  │  metallb     → metallb chart 0.14.8  │
  │  traefik     → traefik chart 32.1.0  │
  │  cert-manager→ cert-manager v1.15.3  │
  │  metallb-config→ Git path (ip-pool)  │
  └──────────────────────────────────────┘
```

**Self-Managed ArgoCD (special case):**

The `argocd` child app manages ArgoCD **itself** using the same Helm chart.
This means ArgoCD upgrades and config changes flow through Git: no manual
`helm upgrade` needed.

```yaml
# platform/argocd/apps/argocd.yaml
syncPolicy:
  syncOptions:
    - ServerSideApply=true  # Required: ArgoCD managing itself
```

> **⚠️ Practical note:** When the self-managed app syncs, it modifies the ConfigMap
> and Secrets of the running ArgoCD instance. If the Helm values differ from the
> current state, ArgoCD may restart its own components mid-sync. Always match
> `targetRevision` to the currently installed chart version to avoid downgrades.

### Component: MetalLB: Load Balancer for Bare Metal

Kubernetes `type: LoadBalancer` services only work on cloud providers (AWS ELB, GCP LB).
MetalLB provides the same functionality for bare-metal clusters.

**Layer 2 Mode (used in this project):**

```
  External Traffic                   Cluster
 ─────────────────                ─────────────
  Client: curl <METALLB_IP>     ┌──────────────────────────┐
         │                        │  MetalLB Speaker (DaemonSet)
         │   ARP: who has .230?   │  ┌────────┐  ┌────────┐ │
         ├────────────────────────┼─►│ server  │  │ agent │ │
         │                        │  │ leader │  │ standby│ │
         │   ARP reply: I do!     │  └───┬────┘  └────────┘ │
         ◄────────────────────────┼──────┘                  │
         │                        │  ┌────────────────────┐ │
         │   TCP :443             │  │ Traefik Service    │ │
         ├────────────────────────┼─►│ type: LoadBalancer │ │
         │                        │  │ → pod on any node  │ │
         ▼                        │  └────────────────────┘ │
    <METALLB_IP>                └──────────────────────────┘
```

**MetalLB Resources:**

```yaml
# IPAddressPool: which IPs to assign
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: homelab-pool
spec:
  addresses:
    - <METALLB_IP>-<METALLB_IP_END>  # 11 IPs for LoadBalancer services

# L2Advertisement: announce via ARP (no BGP router needed)
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: homelab-l2
spec:
  ipAddressPools:
    - homelab-pool
```

> **⚠️ Practical note:** MetalLB speaker is a DaemonSet (must run on every node).
> If a node has pod creation issues (cgroup, disk), the speaker gets stuck and
> the app shows `Progressing`. Speaker is required for ARP responses.

### Component: Traefik: Ingress Controller

Traefik acts as the **reverse proxy** for all HTTP/HTTPS traffic entering the cluster.
It replaces K3s's built-in Traefik v1 with a newer Helm-managed version.

**Request Flow:**

```
 Internet / LAN                    Kubernetes Cluster
 ──────────────                    ──────────────────

  https://argocd.homelab.local
         │
         │  DNS → <METALLB_IP>   ┌──────────────────────────┐
         ▼                         │ Traefik (DaemonSet)      │
  ┌──────────────┐                 │                          │
  │   MetalLB    │                 │ Entrypoint: websecure     │
  │   LB IP .230 │                 │   ↓ TLS termination      │
  └──────┬───────┘                 │   ↓ Route matching        │
         │                         │   ↓ Middleware chain      │
         ▼                         │   ↓                      │
  ┌──────────────┐                 │ ArgoCD Service:443       │
  │   Traefik    │───────────────► │   ↓                      │
  │   :443       │   routes to    │ ArgoCD Pod:8080           │
  └──────────────┘   backend      └──────────────────────────┘
```

**Traefik Concepts:**

| Concept | Kubernetes CRD | Purpose |
|---------|---------------|---------|
| **Entrypoint** | (static config) | Network port listeners (`web:80`, `websecure:443`) |
| **Router** | `IngressRoute` | Match host/path and route to service |
| **Middleware** | `Middleware` | Transform requests (auth, redirect, compress, etc.) |
| **Service** | (K8s Service) | Backend pods that handle requests |

### Component: cert-manager: TLS Certificate Automation

cert-manager automates the lifecycle of TLS certificates: requesting, renewing,
and storing them as Kubernetes Secrets.

**Certificate Issuance Flow:**

```
 ┌─────────────────────────────────────────────────────────────┐
 │                    cert-manager                              │
 │                                                              │
 │  1. Certificate CRD created         4. Secret stored         │
 │     ┌──────────┐                      ┌──────────┐          │
 │     │Certificate│                     │  Secret   │          │
 │     │ argocd-tls│                     │ argocd-tls│          │
 │     │ dns: ...  │                     │ cert+key  │          │
 │     └─────┬─────┘                     └─────▲─────┘          │
 │           │                                  │               │
 │           ▼                                  │               │
 │  2. Order created                   3. Certificate issued    │
 │     ┌──────────┐                      ┌──────────┐          │
 │     │  Order   │──── ACME HTTP01 ────►│Challenge │          │
 │     │          │    or self-signed    │ complete! │          │
 │     └──────────┘                      └──────────┘          │
 └─────────────────────────────────────────────────────────────┘
```

**Issuer types for homelab:**

| Type | Use Case | Requires |
|------|----------|----------|
| **SelfSigned** | Internal services, bootstrap CA | Nothing |
| **CA** (from SelfSigned root) | Issue certs for `*.homelab.local` | Root CA secret |
| **ACME / Let's Encrypt** | Public-facing services with real domain | Domain ownership, port 80 open |

> **⚠️ Practical note:** The `argocd` app's Ingress references `secretName: argocd-tls`.
> This secret must exist before the Ingress becomes healthy. For initial bootstrap,
> create a self-signed cert: `kubectl create secret tls argocd-tls --cert=... --key=...`.
> cert-manager can automate this once a ClusterIssuer is configured.

### AppProjects: Security Boundaries

AppProjects restrict what child applications can do: which Git repos they can
pull from, which namespaces they can deploy to, and which cluster resources they
can create.

```
 ┌──────────────────────────────┐
 │      platform (AppProject)    │
 │                               │
 │  Source repos:                │
 │   github.com/<GITHUB_USER>/*         │
 │   argoproj.github.io/argo-helm│
 │   metallb.github.io/metallb   │
 │   traefik.github.io/charts    │
 │   charts.jetstack.io          │
 │                               │
 │  Destinations:                │
 │   argocd, metallb-system,     │
 │   traefik, cert-manager,      │
 │   kube-system                 │
 │                               │
 │  Permissions: all             │
 └──────────────────────────────┘

 ┌──────────────────────────────┐
 │   observability (AppProject)  │
 │                               │
 │  Destinations:                │
 │   monitoring, kube-system     │
 │                               │
 │  Cluster: Namespace create    │
 └──────────────────────────────┘

 ┌──────────────────────────────┐
 │   applications (AppProject)   │
 │                               │
 │  Destinations:                │
 │   home-assistant, default     │
 │                               │
 │  Cluster: Namespace create    │
 └──────────────────────────────┘
```

> **⚠️ Practical note:** AppProjects are deployed as **static resources**
> (applied once via `kubectl create`). They are intentionally NOT in the
> `platform/argocd/apps/` sync path because ArgoCD's sync operation waits
> for AppProjects to become "Healthy": but AppProjects have no built-in
> health probe, causing the sync to wait forever.

### Deployment Sequence: Phase 2

```
 Step 1: Install ArgoCD         Step 2: Bootstrap GitOps
 ┌───────────────────┐          ┌──────────────────────────┐
 │ helm install argocd│          │ kubectl apply -f          │
 │ argo/argo-cd       │          │ bootstrap/argocd-app.yaml │
 │ -f values.yaml     │          └────────────┬─────────────┘
 └────────┬──────────┘                       │
          │                                  ▼
          ▼                     ┌──────────────────────────┐
 ┌───────────────────┐          │ homelab-apps root app     │
 │ ArgoCD running    │          │ syncs platform/argocd/    │
 │ namespace: argocd │          │ apps/                     │
 └────────┬──────────┘          └────────────┬─────────────┘
          │                                  │
          │  Step 3: Deploy AppProjects       │  Step 4: Child apps sync
          │  ┌───────────────────┐            │  ┌───────────────────────┐
          │  │ kubectl create -f │            │  │ Wave -1: argocd       │
          │  │ platform/         │            │  │ Wave  0: metallb      │
          │  │ observability/    │            │  │ Wave  1: metallb-config│
          │  │ applications      │            │  │         traefik       │
          │  │ AppProjects       │            │  │         cert-manager  │
          │  └───────────────────┘            │  └───────────┬───────────┘
          │                                   │              │
          ▼                                   ▼              ▼
 ┌──────────────────────────────────────────────────────────────────┐
 │                     All 6 apps Synced                             │
 │                                                                   │
 │  App              Sync      Health     Pods                       │
 │  ───────────────  ────────  ────────   ─────────────────────────  │
 │  argocd           Synced    Healthy*   7/7 Running (agent)       │
 │  cert-manager     Synced    Healthy    3/3 Running                │
 │  homelab-apps     Synced    Healthy    (root app, no pods)        │
 │  metallb          Synced    Healthy    3/3 Running (both nodes)   │
 │  metallb-config   Synced    Healthy    (CRDs only, no pods)       │
 │  traefik          Synced    Healthy    1/1 Running, LB .230       │
 │                                                                   │
 │  * argocd may show Progressing on K3s v1.35 (cosmetic, see below) │
 └──────────────────────────────────────────────────────────────────┘
```

> **⚠️ Known cosmetic issue:** On K3s v1.35 (Kubernetes 1.35), Deployments
> keep the `Progressing` condition as `True` permanently even after successful
> rollout. ArgoCD interprets this as the app being in a progressing state,
> causing the `argocd` self-managed app to show `Progressing` health even
> though all pods are `1/1 Running`. This has zero functional impact.

### Phase 2 Delivery Checklist

| Check | Status |
|-------|--------|
| ArgoCD running (7/7 pods) | ✅ |
| ArgoCD UI accessible via Traefik | ✅ |
| App-of-Apps root app deployed | ✅ |
| 3 AppProjects created (platform, observability, applications) | ✅ |
| MetalLB assigning LoadBalancer IPs | ✅ |
| Traefik ingress controller running | ✅ |
| cert-manager CRDs installed and ready | ✅ |
| All 6 apps Synced in ArgoCD | ✅ |
| Phase 2 test suite (13/15 passed) | ✅ |

**Official References:**
- [ArgoCD Documentation](https://argo-cd.readthedocs.io/en/stable/)
- [ArgoCD Architecture](https://argo-cd.readthedocs.io/en/stable/operator-manual/architecture/)
- [ArgoCD App-of-Apps](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/)
- [ArgoCD Helm Chart](https://github.com/argoproj/argo-helm/tree/main/charts/argo-cd)
- [ArgoCD Sync Waves](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/)
- [MetalLB Documentation](https://metallb.universe.tf/)
- [MetalLB Layer 2 Mode](https://metallb.universe.tf/configuration/#layer-2-configuration)
- [Traefik Kubernetes Ingress](https://doc.traefik.io/traefik/routing/providers/kubernetes-ingress/)
- [Traefik Helm Chart](https://github.com/traefik/traefik-helm-chart)
- [cert-manager Documentation](https://cert-manager.io/docs/)
- [cert-manager Installation](https://cert-manager.io/docs/installation/)

---

## Phase 3: Observability Stack

> **Goal:** Full observability pipeline: metrics (Prometheus), logs (Loki),
> traces (OpenTelemetry), and visualization (Grafana).

### What Phase 3 Delivers

A complete monitoring and observability stack for the cluster: every pod, node,
and service is instrumented. Logs are aggregated, metrics are collected,
dashboards visualize everything, and alerts notify on problems.

### Observability Architecture

```
 ┌─────────────────────────────────────────────────────────────────┐
 │                   monitoring namespace                           │
 │                                                                  │
 │  ┌─────────────────┐   ┌─────────────────┐   ┌───────────────┐ │
 │  │   Prometheus    │   │  Alertmanager   │   │    Grafana    │ │
 │  │   ┌───────────┐ │   │                 │   │               │ │
 │  │   │ TSDB      │ │   │ Routes alerts   │   │ Dashboards    │ │
 │  │   │ Scrapes   │ │   │ to Slack/Email  │   │ Datasources:  │ │
 │  │   │ every 30s │ │   └─────────────────┘   │ Prometheus    │ │
 │  │   └─────┬─────┘ │                          │ Loki          │ │
 │  └─────────┼───────┘                          └───────────────┘ │
 │            │ scrape                                              │
 │            ▼                                                     │
 │  ┌─────────────────────────────────────────────────────────┐    │
 │  │                   Metric Sources                          │    │
 │  │  node-exporter │ kube-state-metrics │ Cilium │ App pods  │    │
 │  └─────────────────────────────────────────────────────────┘    │
 │                                                                  │
 │  ┌──────────────────┐   ┌────────────────────────────────────┐ │
 │  │      Loki        │   │   OpenTelemetry Collector          │ │
 │  │                  │   │                                    │ │
 │  │ SingleBinary     │   │ Receivers → Processors → Exporters │ │
 │  │ Log aggregation  │   │ OTLP → batch →                    │ │
 │  │ Index-free       │   │ Prometheus remote_write + Loki     │ │
 │  │ 28d retention    │   │                                    │ │
 │  └──────────────────┘   └────────────────────────────────────┘ │
 └─────────────────────────────────────────────────────────────────┘
```

### Component: Prometheus: Metrics Collection

Prometheus is a **pull-based time-series database**. It scrapes HTTP endpoints
every 30 seconds and stores the results in 2-hour blocks.

**Key resources deployed by kube-prometheus-stack:**

| Component | Purpose |
|-----------|---------|
| **Prometheus Operator** | Manages Prometheus instances and CRDs (ServiceMonitor, PodMonitor, PrometheusRule) |
| **Prometheus** | Time-series database, scraping engine, PromQL query language |
| **Alertmanager** | Routes alerts to Slack, email, webhooks; handles deduplication and silencing |
| **Grafana** | Dashboard visualization; query Prometheus and Loki |
| **node-exporter** | Exposes host metrics (CPU, RAM, disk, network) as Prometheus endpoints |
| **kube-state-metrics** | Exposes Kubernetes object state (Deployment replicas, Pod status, etc.) |

**ServiceMonitor: declarative scraping:**

Instead of configuring scrape targets manually, the Prometheus Operator watches
ServiceMonitor CRDs:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: traefik
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: traefik
  endpoints:
    - port: metrics
      interval: 30s
```

### Component: Loki: Log Aggregation

Loki is an **index-free log aggregation system** designed to be cost-effective.
Unlike Elasticsearch, it only indexes metadata (labels), not the full text of
logs: making it ~10x cheaper to store.

**Loki vs Elasticsearch:**

```
 Elasticsearch                           Loki
 ─────────────                           ────
 Full-text index of every word           Index only labels (app, namespace)
 Index = 50-100% of log volume           Index = ~1% of log volume
 Fast full-text search                   Filter by labels, then brute-force chunks
 Heavy (JVM, SSD, lots of RAM)           Light (Go binary, ~2-)
```

**LogQL query language:**

```logql
# All nginx logs with 500 errors in the last 5 minutes
rate({app="nginx", namespace="production"} |= "500" [5m])

# Regex filter for errors or timeouts
{app="api"} |~ "(?i)error|timeout"
```

### Component: OpenTelemetry Collector: Telemetry Pipeline

The OTel Collector acts as a **universal intermediary** between instrumentation
sources and backend storage. Applications send data to the Collector, which
batches, enriches, and fans out to Prometheus, Loki, and future tracing backends.

**Pipeline:**

```
 Receivers          Processors              Exporters
 ─────────          ──────────              ─────────
 OTLP (gRPC)   →    memory_limiter     →    prometheusremotewrite
                     batch                   otlphttp/loki
                     k8sattributes
```

### Component: Grafana: Visualization

Grafana provides **dashboards** that query Prometheus and Loki. Dashboards are
managed as JSON files, committed to Git, and auto-loaded via a sidecar container.

**Grafana features:**

- **Provisioned dashboards:** JSON files in Git → auto-loaded by sidecar
- **Provisioned datasources:** ConfigMaps with `grafana_datasource: "1"` label
- **Alerting:** Create alert rules from Prometheus/Loki data
- **Explore:** Interactive LogQL and PromQL query builder

### Deployment Sequence: Phase 3

```
 Step 1: Create monitoring namespace

 Step 2: Install kube-prometheus-stack (ArgoCD app)
 ┌──────────────────────────────────────┐
 │ Prometheus + Alertmanager + Grafana  │
 │ + node-exporter + kube-state-metrics │
 │ + ServiceMonitors for Cilium,        │
 │   Traefik, cert-manager              │
 └──────────────────┬───────────────────┘
                    │
 Step 3: Install Loki (ArgoCD app)       Step 4: Install OTel Collector
 ┌──────────────────────────┐           ┌──────────────────────────┐
 │ SingleBinary mode        │           │ Deployment mode          │
 │ Filesystem storage       │           │ OTLP receivers           │
 │ 28-day retention         │           │ Prometheus + Loki export │
 │ Grafana Loki datasource  │           │ K8s metadata enrichment  │
 └──────────────────────────┘           └──────────────────────────┘
                    │                               │
                    └───────────────┬───────────────┘
                                    │
 Step 5: Provision Grafana resources
 ┌──────────────────────────────────────────┐
 │ ConfigMaps: Prometheus datasource        │
 │ ConfigMaps: Loki datasource              │
 │ ConfigMaps: Cluster dashboard JSON       │
 │ ConfigMaps: Cilium/Hubble dashboard JSON │
 └──────────────────────────────────────────┘
```

### Phase 3 Delivery Checklist

| Check | Status |
|-------|--------|
| Prometheus scraping cluster metrics (ServiceMonitors active) | ✅ |
| Grafana accessible with provisioned dashboards | ✅ |
| Loki ingesting and queryable via LogQL | ✅ |
| OTel Collector running and processing telemetry | ✅ |
| Alertmanager configured with basic rules | ✅ |
| Hubble metrics flowing to Prometheus | ✅ |
| Grafana has Prometheus + Loki datasources | ✅ |
| Cilium/Hubble scrape configs added to Prometheus | ✅ |
| Dashboards: k8s-cluster, cilium-hubble, home-assistant | ✅ |
| Phase 3 test suite (4 test scripts) | ✅ |
| Phase 3 runbook created | ✅ |

**Official References:**
- [kube-prometheus-stack Helm Chart](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [Prometheus Operator](https://github.com/prometheus-operator/prometheus-operator)
- [Prometheus Querying (PromQL)](https://prometheus.io/docs/prometheus/latest/querying/basics/)
- [Grafana Provisioning](https://grafana.com/docs/grafana/latest/administration/provisioning/)
- [Loki Architecture](https://grafana.com/docs/loki/latest/get-started/architecture/)
- [Loki LogQL](https://grafana.com/docs/loki/latest/query/)
- [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/)
- [OTel Collector Configuration](https://opentelemetry.io/docs/collector/configuration/)

---

## Key Concepts Glossary

| Term | Definition | Phase |
|------|------------|-------|
| **GitOps** | Using Git as the single source of truth for declarative infrastructure and application state | 0, 2 |
| **CNI** | Container Network Interface: plugin that provides pod networking | 1 |
| **eBPF** | Extended Berkeley Packet Filter: kernel technology for high-performance networking | 1 |
| **DaemonSet** | Kubernetes resource that ensures one pod per node (used by MetalLB speaker, Traefik) | 2 |
| **StatefulSet** | Manages stateful apps with stable network identity and persistent storage | 2 |
| **App-of-Apps** | ArgoCD pattern where one parent Application manages child Applications | 2 |
| **SSA** | Server-Side Apply: Kubernetes apply strategy that tracks field ownership | 2 |
| **CRD** | Custom Resource Definition: extends Kubernetes API with custom types | 2 |
| **Sync Wave** | Ordering mechanism for ArgoCD syncs (lower numbers sync first) | 2 |
| **SelfHeal** | ArgoCD sync policy that auto-corrects drift from Git state | 2 |
| **Prune** | ArgoCD sync policy that deletes resources removed from Git | 2 |
| **TLS** | Transport Layer Security: encrypts network traffic | 2 |
| **ACME** | Automated Certificate Management Environment: protocol for automated TLS cert issuance | 2 |
| **Idempotent** | Operation that produces the same result regardless of how many times it runs | 0 |
| **TDD** | Test-Driven Development: writing tests before implementation | 0 |
| **TSDB** | Time-Series Database: optimized for timestamped metrics data | 3 |
| **PromQL** | Prometheus Query Language: for querying and aggregating metrics | 3 |
| **LogQL** | Loki Query Language: PromQL-inspired language for log queries | 3 |
| **OTLP** | OpenTelemetry Protocol: standard protocol for traces, metrics, logs | 3 |
| **ServiceMonitor** | Prometheus Operator CRD: declaratively defines scrape targets | 3 |
| **Retention** | How long data is kept before deletion (Prometheus: 15d, Loki: 28d) | 3 |
| **Cardinality** | Number of unique label combinations: high cardinality = more memory | 3 |
| **WAL** | Write-Ahead Log: crash safety mechanism for TSDBs | 3 |

---

> **Next:** [Phase 4: Home Assistant Application](../PLAN.md#7-phase-4--home-assistant-application)
>
> **Related docs:**
> - [Architecture Decisions](architecture.md): AD-001 through AD-006
> - [How to Run](HOW-TO-RUN.md): Step-by-step setup guide
> - [Phase 1 Runbook](runbooks/phase1-k3s-cilium.md): Troubleshooting
> - [Phase 2 Runbook](runbooks/phase2-argocd-gitops.md): Troubleshooting
> - [Phase 3 Runbook](runbooks/phase3-observability.md): Troubleshooting
> - [Glossary](glossary.md): Full terminology reference
