# Proxmox + OpenTofu Infrastructure: Master Plan

> **Status:** DRAFT — Awaiting review and approval
> **Approach:** DevSecOps · TDD · Spec-Driven · Modular · Portfolio-Grade · AIOps-Integrated
> **Repo:** Monorepo under `homelab-gitops-infra/proxmox/` (same repo as existing K8s GitOps)

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Architecture Overview](#2-architecture-overview)
3. [Architecture Decision Records](#3-architecture-decision-records)
4. [Repository Structure](#4-repository-structure)
5. [Phase 0: Foundation & Repo Setup](#5-phase-0--foundation--repo-setup)
6. [Phase 1: Proxmox VM Templates & Cloud-Init](#6-phase-1--proxmox-vm-templates--cloud-init)
7. [Phase 2: OpenTofu IaC — VM Provisioning](#7-phase-2--opentofu-iac--vm-provisioning)
8. [Phase 3: Ansible Post-Provisioning](#8-phase-3--ansible-post-provisioning)
9. [Phase 4: K3s Cluster Bootstrap](#9-phase-4--k3s-cluster-bootstrap)
10. [Phase 5: GitOps Integration (ArgoCD Bootstrap)](#10-phase-5--gitops-integration-argocd-bootstrap)
11. [Phase 6: AIOps Integration](#11-phase-6--aiops-integration)
12. [Phase 7: Security Hardening & Validation](#12-phase-7--security-hardening--validation)
13. [Testing Strategy](#13-testing-strategy)
14. [Risk Register](#14-risk-register)
15. [Operational Runbooks (Pre-Spec)](#15-operational-runbooks-pre-spec)
16. [DevOps & AIOps Best Practices](#16-devops--aiops-best-practices)

---

## 1. Executive Summary

### Problem

The existing homelab cluster (2 nodes: ARM64 control plane + x86_64 worker) provides production services (Home Assistant, monitoring, etc.) but lacks pre-production environments for testing changes before they hit production. Currently, all changes are tested directly against the production cluster — any misconfiguration could take down Home Assistant or monitoring.

### Solution

Provision 3 additional VMs on Proxmox using Infrastructure as Code (OpenTofu) with **environment isolation** via separate VLANs:

| Environment | VMs | Role | K3s Role | VLAN |
|-------------|-----|------|----------|------|
| **Production** | 1 | New x86_64 worker | K3s agent (joins existing cluster) | untagged / vmbr0 (existing LAN) |
| **Staging** | 1 | Full staging environment | K3s server (standalone, mirrors prod) | VLAN 20 |
| **Testing** | 1 | Ephemeral test environment | K3s server (standalone) | VLAN 30 |

Staging runs a mirrored version of the production GitOps stack (same ArgoCD apps, same monitoring) so changes can be validated end-to-end before promotion. Testing is a throwaway environment for experimental changes.

### AIOps Integration (Phased Rollout)

AIOps tooling is deployed progressively, gated by available cluster capacity:

| Phase | Tool | Purpose | RAM Cost |
|-------|------|---------|----------|
| **v1 (Phase 6)** | K8sGPT + cloud LLM backend | Cluster diagnostics and root cause analysis | ~200MB |
| **v1 (Phase 6)** | Falco (eBPF) | Runtime threat detection | ~200MB |
| **v1 (Phase 6)** | Grafana ML anomaly detection | Metric-based anomaly detection via PromQL | negligible |
| **v2 (future)** | Ollama + K8sGPT local backend | On-prem LLM diagnostics (requires ≥8GB VM) | ~10GB |
| **v2 (future)** | Robusta Classic | Alert enrichment + log correlation | ~300MB |
| **v2 (future)** | Trivy Operator | Continuous CVE scanning | ~500MB |
| **Baseline** | Kube-bench (CronJob) | Automated CIS compliance checks | negligible |

**Rationale:** The staging VM has 8GB RAM (increased from 4GB to accommodate GitOps stack). A full AIOps suite would require ~14GB. v1 deploys the high-value, low-resource tools. Ollama, Robusta, and Trivy are deferred to a dedicated AIOps VM or larger production node.

### Key Principles

- **No manual VM creation** — everything is OpenTofu + cloud-init
- **GitOps all the way down** — ArgoCD manages cluster state after bootstrap
- **TDD for infrastructure** — tests written before implementation
- **Secrets never committed** — SealedSecrets, .env files gitignored
- **Environment isolation** — VLANs, separate K3s clusters, independent state
- **AIOps from day one** — diagnostics and anomaly detection built in, not bolted on

---

## 2. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         PROXMOX HOST (PVE 9.x)                               │
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │                        NETWORK LAYOUT                                 │  │
│  │                                                                       │  │
│  │   vmbr0 — untagged (existing LAN)                                     │  │
│  │   ┌─────────────────┐                                                 │  │
│  │   │ 192.168.1.0/24  │                                                 │  │
│  │   │ (prod + mgmt)  │                                                 │  │
│  │   └────────┬────────┘                                                 │  │
│  │            │                                                          │  │
│  │            ▼                                                          │  │
│  │   ┌──────────────────┐                                                │  │
│  │   │ k8s-prod-agent   │                                                │  │
│  │   │ VM ID: 301       │                                                │  │
│  │   │ 4 vCPU / 8GB RAM │                                                │  │
│  │   │ 100GB disk       │                                                │  │
│  │   └──────────────────┘                                                │  │
│  │                                                                       │  │
│  │   vmbr0.20 (staging VLAN)     vmbr0.30 (testing VLAN)                 │  │
│  │   ┌─────────────────┐           ┌─────────────────┐                   │  │
│  │   │ 10.0.20.0/24    │           │ 10.0.30.0/24    │                   │  │
│  │   │ (isolated)      │           │ (isolated)      │                   │  │
│  │   └────────┬────────┘           └────────┬────────┘                   │  │
│  │            │                              │                            │  │
│  │            ▼                              ▼                            │  │
│  │   ┌──────────────────┐        ┌──────────────────┐                    │  │
│  │   │ k8s-staging      │        │ k8s-testing      │                    │  │
│  │   │ VM ID: 201       │        │ VM ID: 101       │                    │  │
│  │   │ 4 vCPU / 8GB RAM │        │ 2 vCPU / 4GB RAM │                    │  │
│  │   │ 50GB disk        │        │ 30GB disk        │                    │  │
│  │   │ Standalone K3s   │        │ Standalone K3s   │                    │  │
│  │   └──────────────────┘        └──────────────────┘                    │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │                     STORAGE BACKENDS                                   │  │
│  │  local (ISO/templates)    local-lvm (VM disks)                        │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘

                              │
                              │ OpenTofu provisions VMs
                              │ Ansible bootstraps OS
                              │ Cloud-init auto-joins K3s
                              ▼

┌─────────────────────────────────────────────────────────────────────────────┐
│                      KUBERNETES CLUSTERS                                     │
│                                                                             │
│  ┌──────────────────────────────┐  ┌──────────────────────┐                │
│  │  Production (existing)       │  │  Production (new)     │                │
│  │  ┌──────────┐ ┌──────────┐  │  │  ┌──────────────────┐ │                │
│  │  │ server   │ │ agent    │  │  │  │ k8s-prod-agent   │ │                │
│  │  │ ARM64    │ │ x86_64   │  │  │  │ x86_64 (new VM)  │ │                │
│  │  └──────────┘ └──────────┘  │  │  └──────────────────┘ │                │
│  └──────────────────────────────┘  └──────────────────────┘                │
│                                                                             │
│  ┌──────────────────────────────┐  ┌──────────────────────┐                │
│  │  Staging (mirrors prod)      │  │  Testing (ephemeral)  │                │
│  │  ┌──────────────────────────┐│  │  ┌──────────────────┐ │                │
│  │  │ K3s server (all-in-one) ││  │  │ K3s server       │ │                │
│  │  │ ArgoCD + full stack     ││  │  │ Minimal bootstrap │ │                │
│  │  └──────────────────────────┘│  │  └──────────────────┘ │                │
│  └──────────────────────────────┘  └──────────────────────┘                │
└─────────────────────────────────────────────────────────────────────────────┘

                              │
                              │ GitOps via ArgoCD
                              │ Observability via kube-prometheus-stack
                              ▼

┌─────────────────────────────────────────────────────────────────────────────┐
│                      AIOps LAYER (on all clusters)                           │
│                                                                             │
│  ┌──────────────┐  ┌────────────────┐  ┌──────────────┐                    │
│  │ K8sGPT       │  │ Grafana ML     │  │ Robusta       │                    │
│  │ (diagnostics)│  │ (anomaly det.) │  │ (alerting)    │                    │
│  └──────┬───────┘  └───────┬────────┘  └──────┬───────┘                    │
│         │                  │                   │                             │
│         └──────────────────┼───────────────────┘                            │
│                            │                                                │
│                     ┌──────┴──────┐                                         │
│                     │ Ollama      │                                         │
│                     │ (llama3.1)  │                                         │
│                     └─────────────┘                                         │
│                                                                             │
│  ┌──────────────┐  ┌──────────────────────────────────┐                    │
│  │ Falco        │  │ Trivy Operator + Kube-bench      │                    │
│  │ (runtime)    │  │ (vulnerability + CIS scanning)    │                    │
│  └──────────────┘  └──────────────────────────────────┘                    │
└─────────────────────────────────────────────────────────────────────────────┘
```

### CI/CD Pipeline (GitHub Actions)

```
Git Push ──► GitHub Actions
                │
                ├──► tofu validate (all envs)
                ├──► tofu plan (diff against live state)
                ├──► yamllint + shellcheck
                ├──► ansible-lint
                ├──► gitleaks (secret detection)
                │
                └──► PR merged to main
                        │
                        ├──► tofu apply (auto-apply to testing)
                        ├──► tofu apply (manual approve for staging)
                        └──► tofu apply (manual approve for prod)
```

### Tooling Versions (Pinned)

| Tool | Version | Rationale |
|------|---------|-----------|
| Proxmox VE | 9.x | Latest stable, SDN support |
| OpenTofu | >= 1.10 | Drop-in Terraform replacement, open-source |
| bpg/proxmox provider | ~> 0.78 | Actively maintained, 40+ resources |
| K3s | v1.35.x | Matches existing cluster version |
| Ansible | >= 2.14 | Post-provisioning configuration |
| K8sGPT | 0.4.x | CNCF Sandbox, cloud or local LLM backend |
| Ollama | latest | Self-hosted LLM (deferred to v2, dedicated VM) |
| Falco | latest | eBPF runtime security (CNCF Graduated) |

---

## 3. Architecture Decision Records

### AD-001: bpg/proxmox over Telmate/proxmox

**Decision:** Use the `bpg/proxmox` (BPG Labs) Terraform provider.

**Rationale:**
- Telmate/proxmox is effectively unmaintained (last significant update 2023)
- BPG provider has 40+ resources/data sources vs Telmate's 2
- BPG supports Proxmox 9.x, SDN, CPU flags, NUMA, cloud-init natively
- Active GitHub community, responds to issues within days
- Telmate provider has known cloning bugs on Proxmox 8+

**Alternatives considered:** Telmate/proxmox — rejected due to abandonment.

### AD-002: OpenTofu over HashiCorp Terraform

**Decision:** Use OpenTofu 1.10+.

**Rationale:**
- Fully open-source (MPL 2.0) vs BSL-licensed Terraform
- Drop-in replacement — same HCL syntax, same provider ecosystem
- Active community fork with faster release cadence
- No risk of license changes affecting homelab usage
- S3 backend support is identical

**Alternatives considered:** Terraform — rejected due to BSL license uncertainty.

### AD-003: Monorepo over Multi-Repo

**Decision:** Keep Proxmox/Terraform code inside the existing `homelab-gitops-infra` repo under `proxmox/`.

**Rationale:**
- Tight coupling: Proxmox provisions the VMs that become K3s nodes used by the GitOps config
- Single source of truth for the entire homelab
- Shared secrets management (.env, SealedSecrets)
- Shared CI pipeline
- Single `git clone` to understand the whole system
- The empty `proxmox/` directory already exists for this purpose

**Alternatives considered:** Separate repo + Git submodule — rejected due to unnecessary complexity at homelab scale.

### AD-004: VLAN Isolation per Environment

**Decision:** Separate VLANs for production (10), staging (20), and testing (30).

**Rationale:**
- Prevents cross-environment traffic leakage
- Testing environment can't accidentally reach production services
- Enables network policy testing without affecting other environments
- Production agent node shares the existing LAN subnet (vmbr0) — it must reach the existing K3s server
- Staging/testing VLANs are fully isolated with their own subnet ranges

**Network design:**
| Environment | Bridge | VLAN | Subnet | Gateway |
|-------------|--------|------|--------|---------|
| Production (agent) | vmbr0 | untagged | 192.168.1.0/24 (existing LAN) | 192.168.1.1 |
| Staging | vmbr0 | 20 | 10.0.20.0/24 | 10.0.20.1 |
| Testing | vmbr0 | 30 | 10.0.30.0/24 | 10.0.30.1 |

**Why untagged for production:** The production VM must reach the existing K3s server at 192.168.1.10. Putting it on an isolated VLAN would require routing, NAT, or a dedicated bridge — complexity that adds no value for a single agent node. It lives on the same LAN as the existing cluster.

### AD-005: Full Clones over Linked Clones

**Decision:** Use `full = true` for all VM clones.

**Rationale:**
- Linked clones break when the template VM is regenerated (disk chain breaks)
- Full clones are independent and can be migrated between Proxmox nodes
- Disk space is not a constraint for 3 VMs
- Simplifies disaster recovery — no dependency chain to track

### AD-006: Cloud-Init over Manual Post-Install

**Decision:** Use Proxmox cloud-init for initial VM configuration (hostname, IP, SSH keys, packages).

**Rationale:**
- Fully automated — no manual SSH into fresh VMs
- IP addressing set at provision time, not via DHCP reservations
- SSH keys injected before first boot
- User data can run arbitrary commands (install qemu-guest-agent, configure kernel)
- Integrates with OpenTofu via `proxmox_virtual_environment_vm.initialization` block

### AD-007: Separate K3s Clusters for Staging/Testing

**Decision:** Staging and testing each run standalone single-node K3s clusters (server + agent on same VM).

**Rationale:**
- Staging mirrors production but doesn't need HA — it validates config changes, not cluster resilience
- Testing is ephemeral — single node reduces provisioning time and resource usage
- Production gets an additional agent node that joins the existing cluster — provides extra workload capacity
- Avoids the complexity of multi-node clusters in pre-production environments

### AD-008: K8sGPT + Ollama over Cloud LLM APIs

**Decision:** Use self-hosted Ollama (llama3.1:8b) as the LLM backend for K8sGPT diagnostics.

**Rationale:**
- No data leaves the cluster — all diagnostics stay on-premises
- No API costs or rate limits
- llama3.1:8b is sufficient for Kubernetes troubleshooting
- Works offline — cluster diagnostics available even during network issues
- CNCF Sandbox project with active development

### AD-009: Separate OpenTofu State per Environment

**Decision:** Each environment (prod/staging/testing) has its own OpenTofu state file in S3 backend.

**Rationale:**
- Prevents cross-environment state corruption
- `tofu destroy` in testing can't affect staging
- Different S3 keys: `proxmox-terraform/prod/terraform.tfstate`, etc.
- IAM/service account isolation possible in future

---

## 4. Repository Structure

```
homelab-gitops-infra/                    # Existing monorepo root
│
├── proxmox/                              # NEW: Proxmox IaC project
│   ├── PLAN.md                           # This file
│   ├── README.md                         # Portfolio overview & quickstart
│   │
│   ├── opentofu/                         # OpenTofu Infrastructure as Code
│   │   ├── main.tf                       # Root module: calls environments
│   │   ├── variables.tf                  # Shared input variables
│   │   ├── outputs.tf                    # Outputs: VM IPs, hostnames
│   │   ├── backend.tf                    # S3/MinIO backend config
│   │   ├── .terraform.lock.hcl           # Provider lock file (committed)
│   │   │
│   │   ├── environments/                 # Per-environment state & configs
│   │   │   ├── prod/                     # Production (agent node)
│   │   │   │   ├── main.tf
│   │   │   │   ├── terraform.tfvars
│   │   │   │   └── .terraform.lock.hcl
│   │   │   ├── staging/                 # Staging (mirrors prod)
│   │   │   │   ├── main.tf
│   │   │   │   ├── terraform.tfvars
│   │   │   │   └── .terraform.lock.hcl
│   │   │   └── testing/                 # Testing (ephemeral)
│   │   │       ├── main.tf
│   │   │       ├── terraform.tfvars
│   │   │       └── .terraform.lock.hcl
│   │   │
│   │   ├── modules/                      # Reusable OpenTofu modules
│   │   │   └── vm/                       # Generic Proxmox VM module
│   │   │       ├── main.tf
│   │   │       ├── variables.tf
│   │   │       ├── outputs.tf
│   │   │       └── README.md
│   │   │
│   │   └── templates/                    # Inventory templates for Ansible
│   │       └── inventory.tmpl
│   │
│   ├── ansible/                          # Post-provisioning configuration
│   │   ├── playbooks/
│   │   │   ├── post-provision.yml        # Base OS config (all VMs)
│   │   │   ├── install-k3s.yml           # K3s installation
│   │   │   └── join-cluster.yml          # Join agent to existing cluster
│   │   ├── roles/
│   │   │   ├── bootstrap-node/           # Kernel params, packages, qemu-agent
│   │   │   ├── install-kubectl/
│   │   │   ├── install-helm/
│   │   │   └── install-k3s/
│   │   ├── vars/
│   │   │   └── main.yml
│   │   └── inventory.example.yml         # Template (inventory.yml is gitignored)
│   │
│   ├── aiops/                            # AIOps configuration & manifests (v1)
│   │   ├── k8sgpt/
│   │   │   └── values.yaml               # K8sGPT Helm values (cloud backend)
│   │   ├── falco/
│   │   │   └── values.yaml               # Falco Helm values (eBPF)
│   │   └── anomaly/
│   │       └── recording-rules.yaml       # Prometheus ML anomaly rules
│   │
│   ├── cloud-init/                       # Cloud-init templates
│   │   ├── base.yaml                     # Common config (all VMs)
│   │   ├── k3s-server.yaml               # K3s server-specific config
│   │   └── k3s-agent.yaml                # K3s agent-specific config
│   │
│   ├── tests/                            # TDD test scripts
│   │   ├── test-tofu.sh                  # OpenTofu validate + plan
│   │   ├── test-proxmox.sh               # Proxmox API connectivity
│   │   ├── test-vm-provision.sh          # VM creation + SSH reachability
│   │   ├── test-k3s.sh                   # K3s cluster health
│   │   ├── test-network.sh               # VLAN isolation verification
│   │   └── test-aiops.sh                 # AIOps stack health
│   │
│   ├── docs/                             # Documentation
│   │   ├── architecture.md               # Proxmox-specific architecture decisions
│   │   ├── quickstart.md                 # One-command bootstrap guide
│   │   ├── runbooks/                     # Operational runbooks
│   │   │   ├── add-vm.md                 # How to add a new VM
│   │   │   ├── destroy-rebuild-env.md    # Tear down and rebuild an environment
│   │   │   ├── template-update.md        # Update VM template
│   │   │   └── aiops-troubleshooting.md  # K8sGPT/Ollama debug guide
│   │   └── tech_stack/
│   │       ├── opentofu.md               # OpenTofu deep dive
│   │       ├── proxmox-provider.md       # bpg/proxmox provider guide
│   │       └── aiops.md                  # AIOps tool selection rationale
│   │
│   └── .github/                          # CI/CD (or in repo root)
│       └── workflows/
│           └── proxmox-tofu.yaml         # OpenTofu validate/plan/apply
│
├── infra/                                # Existing: cluster infrastructure
├── platform/                             # Existing: ArgoCD & platform services
├── observability/                        # Existing: monitoring stack
├── apps/                                 # Existing: applications
├── security/                             # Existing: hardening
├── docs/                                 # Existing: documentation
└── scripts/                              # Existing: shared utilities
```

---

## 5. Phase 0: Foundation & Repo Setup

**Goal:** Establish project structure, tooling, pre-commit hooks, and Proxmox API access.

**Dependencies:** None.
**Duration:** ~2 hours.

### Specs

| Spec ID | Description | Validation |
|---------|-------------|------------|
| P0.1 | Directory structure matches plan | `make validate-structure-proxmox` passes |
| P0.2 | OpenTofu installed (>= 1.10) and provider initialized | `tofu version` && `tofu init` succeeds |
| P0.3 | Proxmox API token created with PVEVMAdmin role | `tofu plan` connects to Proxmox API without auth errors |
| P0.4 | Ansible installed (>= 2.14) and inventory template exists | `ansible --version` && `ansible-playbook --syntax-check` |
| P0.5 | Pre-commit hooks include tofu fmt validation | `pre-commit run --all-files` passes |
| P0.6 | S3 backend reachable (MinIO or compatible) | `tofu init -backend=true` succeeds |
| P0.7 | `.gitignore` covers `.env`, state backups, inventory.yml, secrets | `gitleaks detect` finds zero secrets |
| P0.8 | Makefile provides all phase targets | `make help` lists proxmox targets |

### Tasks

- [ ] **T0.1** Create directory structure under `proxmox/` (see §4)
- [ ] **T0.2** Install OpenTofu 1.10+ and verify:
  ```bash
  tofu version
  ```
- [ ] **T0.3** Create Proxmox API token (Proxmox 9.x compatible):
  ```bash
  # On Proxmox host via SSH:
  # 1. Create dedicated user (no shell login needed)
  pveum user add terraform@pve --comment "OpenTofu automation"

  # 2. Create custom role with ALL VM, storage, pool, and system privileges
  #    NOTE: VM.Monitor was REMOVED in PVE 9.x — replaced by VM.GuestAgent.* + Sys.Audit
  pveum role add TerraformRole -privs "\
  VM.Allocate,VM.Clone,VM.Config.CPU,VM.Config.Cloudinit,VM.Config.Disk,\
  VM.Config.HWType,VM.Config.Memory,VM.Config.Network,VM.Config.Options,\
  VM.Audit,VM.Backup,VM.Console,VM.PowerMgmt,VM.Migrate,VM.Snapshot,\
  VM.Snapshot.Rollback,VM.GuestAgent.Audit,VM.GuestAgent.FileRead,\
  VM.GuestAgent.FileWrite,VM.GuestAgent.FileSystemMgmt,VM.GuestAgent.Unrestricted,\
  Datastore.Allocate,Datastore.AllocateSpace,Datastore.AllocateTemplate,\
  Datastore.Audit,Pool.Allocate,Pool.Audit,Sys.Audit,Sys.Modify"

  # 3. Assign role to user on all relevant paths
  pveum acl modify /vms -user terraform@pve -role TerraformRole
  pveum acl modify /storage -user terraform@pve -role TerraformRole
  pveum acl modify /pool -user terraform@pve -role TerraformRole

  # 4. For SDN/VLAN support (Phase 2 VLAN creation):
  #    pveum acl modify /sdn -user terraform@pve -role PVESDNAdmin

  # 5. Create API token with privilege separation (default in PVE 9.x)
  pveum user token add terraform@pve terraform --privsep 1

  # 6. Grant token the same permissions (required when privsep=1)
  pveum acl modify /vms -token 'terraform@pve!terraform' -role TerraformRole
  pveum acl modify /storage -token 'terraform@pve!terraform' -role TerraformRole
  pveum acl modify /pool -token 'terraform@pve!terraform' -role TerraformRole

  # 7. Verify token works
  pveum user token permissions terraform@pve terraform

  # IMPORTANT: Cloud-init snippets require SSH/SFTP (PAM account).
  # The provider's `ssh {}` block in main.tf handles this.
  # Ensure the root user on Proxmox accepts SSH key auth for snippet uploads.
  ```
  Save the **token ID** (`terraform@pve!terraform`) and **token secret** for `.env`.
- [ ] **T0.4** Configure `proxmox/.env` from template:
  ```bash
  cp proxmox/.env.example proxmox/.env
  # Fill in: PROXMOX_ENDPOINT, PROXMOX_API_TOKEN_ID, PROXMOX_API_TOKEN_SECRET
  # Fill in: S3_ENDPOINT, S3_ACCESS_KEY, S3_SECRET_KEY, S3_BUCKET
  ```
- [ ] **T0.5** Create OpenTofu backend configuration (S3/MinIO):
  ```hcl
  # opentofu/backend.tf
  terraform {
    backend "s3" {
      endpoint                    = var.s3_endpoint
      bucket                      = var.s3_bucket
      key                         = "proxmox-terraform/${terraform.workspace}/terraform.tfstate"
      region                      = "us-east-1"
      encrypt                     = true
      skip_credentials_validation = true
      skip_metadata_api_check     = true
      skip_region_validation      = true
    }
  }
  ```
- [ ] **T0.6** Configure provider in `opentofu/main.tf`:
  ```hcl
  terraform {
    required_version = ">= 1.10"
    required_providers {
      proxmox = {
        source  = "bpg/proxmox"
        version = "~> 0.78.0"
      }
    }
  }

  provider "proxmox" {
    endpoint  = var.proxmox_endpoint
    api_token = "${var.proxmox_api_token_id}=${var.proxmox_api_token_secret}"
    insecure  = var.proxmox_tls_insecure  # true for self-signed certs

    ssh {
      agent    = true
      username = var.proxmox_ssh_user
    }
  }
  ```
- [ ] **T0.7** Extend `.pre-commit-config.yaml`:
  ```yaml
  # Add to existing pre-commit config:
  - repo: https://github.com/antonbabenko/pre-commit-terraform
    rev: v1.96.0
    hooks:
      - id: tofu_fmt
        files: ^proxmox/
      - id: tofu_validate
        files: ^proxmox/
      - id: tofu_tflint
        files: ^proxmox/
        args:
          - --args=--config=__GIT_WORKING_DIR__/proxmox/.tflint.hcl
  ```
- [ ] **T0.8** Extend `.gitignore`:
  ```gitignore
  # Proxmox additions
  proxmox/.env
  proxmox/opentofu/**/.terraform/
  proxmox/opentofu/**/terraform.tfstate*
  proxmox/opentofu/**/*.backup
  proxmox/ansible/inventory.yml
  proxmox/ansible/inventory.ini
  proxmox/ansible/**/*.retry
  ```
- [ ] **T0.9** Extend `Makefile` with proxmox targets:
  ```makefile
  # Proxmox targets
  .PHONY: tofu-init tofu-plan tofu-apply tofu-destroy tofu-fmt tofu-validate
  .PHONY: test-proxmox test-proxmox-phase0

  tofu-init: ## Initialize OpenTofu for all environments
    @for env in testing staging prod; do \
      echo "Initializing $$env..."; \
      cd proxmox/opentofu/environments/$$env && tofu init; \
    done

  tofu-validate: ## Validate OpenTofu configuration
    @for env in testing staging prod; do \
      echo "Validating $$env..."; \
      cd proxmox/opentofu/environments/$$env && tofu validate; \
    done

  test-proxmox-phase0: ## Run Phase 0 tests
    bash proxmox/tests/test-tofu.sh
  ```
- [ ] **T0.10** Write Phase 0 tests (`proxmox/tests/test-tofu.sh`)

---

## 6. Phase 1: Proxmox VM Templates & Cloud-Init

**Goal:** Create a base Ubuntu cloud image VM template on Proxmox with K3s prerequisites.

**Dependencies:** Phase 0 complete.
**Duration:** ~1 hour.

### Specs

| Spec ID | Description | Validation |
|---------|-------------|------------|
| P1.1 | Ubuntu cloud image downloaded to Proxmox local storage | Image visible in Proxmox UI under `local` |
| P1.2 | VM template (ID 9000) created with cloud-init support | Template exists: `qm status 9000` reports template |
| P1.3 | Template has qemu-guest-agent installed | Agent responds after clone and boot |
| P1.4 | Template has K3s kernel prerequisites | `/proc/sys/net/bridge/bridge-nf-call-iptables` = 1 |
| P1.5 | Cloud-init snippet datastore configured | Snippets visible under `local` storage |
| P1.6 | Template uses `virtio` for disk and network | Disk interface = `scsi0`, NIC model = `virtio` |

### Tasks

- [ ] **T1.1** Download Ubuntu 24.04 cloud image via OpenTofu:
  ```hcl
  # opentofu/modules/vm/main.tf
  resource "proxmox_virtual_environment_download_file" "ubuntu_cloud_image" {
    content_type = "import"
    datastore_id = "local"
    node_name    = var.proxmox_node
    url          = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
    file_name    = "noble-server-cloudimg-amd64.img"
  }
  ```

- [ ] **T1.2** Define base cloud-init config (`cloud-init/base.yaml`):
  ```yaml
  #cloud-config
  hostname: ${hostname}
  timezone: America/New_York
  package_update: true
  package_upgrade: true
  packages:
    - qemu-guest-agent
    - curl
    - wget
    - gnupg2
    - software-properties-common
    - apt-transport-https
    - ca-certificates
  write_files:
    - path: /etc/sysctl.d/99-k3s.conf
      content: |
        net.bridge.bridge-nf-call-iptables  = 1
        net.bridge.bridge-nf-call-ip6tables = 1
        net.ipv4.ip_forward                 = 1
    - path: /etc/ssh/sshd_config.d/99-hardening.conf
      content: |
        PasswordAuthentication no
        PermitRootLogin prohibit-password
  runcmd:
    - systemctl enable qemu-guest-agent
    - systemctl start qemu-guest-agent
    - sysctl --system
    - swapoff -a
    - sed -i '/swap/d' /etc/fstab
    - systemctl restart sshd
  ```

- [ ] **T1.3** Cloud-init is **minimal** — only hostname, networking, SSH keys, qemu-guest-agent, and kernel parameters. **K3s installation is NOT in cloud-init.** K3s is installed via Ansible in Phase 4 to keep cloud-init simple and avoid boot-time internet dependency.


- [ ] **T1.4** Create template VM via Proxmox UI or API (manual once, then managed via OpenTofu):
  1. Create VM: General → Name: `ubuntu-2404-cloud-template`, VM ID: 9000
  2. OS: Use the downloaded cloud image, enable QEMU Guest Agent
  3. System: BIOS OVMF (UEFI), SCSI controller VirtIO SCSI single, enable QEMU Agent
  4. Disks: `scsi0` on `local-lvm`, 8GB, Discard + SSD emulation
  5. CPU: 2 cores, type `host`
  6. Memory: 2048 MiB, ballooning disabled
  7. Network: `vmbr0`, model `virtio`
  8. Cloud-Init: Use `local` storage, configure default user + SSH key
  9. Start VM once to install qemu-guest-agent
  10. Convert to template: right-click → Convert to template

- [ ] **T1.5** Verify template:
  ```bash
  # Clone a test VM from template
  qm clone 9000 9999 --name test-clone --full
  qm start 9999
  # Verify SSH + qemu-guest-agent
  ssh ubuntu@<test-vm-ip> 'systemctl status qemu-guest-agent'
  qm stop 9999 && qm destroy 9999
  ```

---

## 7. Phase 2: OpenTofu IaC — VM Provisioning

**Goal:** Implement OpenTofu modules and environment configs to provision all 3 VMs.

**Dependencies:** Phase 1 complete.
**Duration:** ~3 hours.

### Specs

| Spec ID | Description | Validation |
|---------|-------------|------------|
| P2.1 | VM module is parameterized and reusable | `tofu validate` in all 3 environments passes |
| P2.2 | Production VM (k8s-prod-agent) on existing LAN | VM has IP on 192.168.1.0/24, untagged vmbr0 |
| P2.3 | Staging VM (k8s-staging) provisioned on VLAN 20 | VM has IP on 10.0.20.0/24, correct VLAN tag |
| P2.4 | Testing VM (k8s-testing) provisioned on VLAN 30 | VM has IP on 10.0.30.0/24, correct VLAN tag |
| P2.5 | VMs are tagged with environment metadata | Proxmox tags: `k8s`, `env:prod` (or `staging`/`testing`) |
| P2.6 | Cloud-init configures hostname, IP, SSH keys | SSH into VM without password prompt |
| P2.7 | Ansible inventory generated from OpenTofu outputs | `inventory.ini` contains all 3 VMs with correct groups |
| P2.8 | OpenTofu state stored in S3 backend (SSE encrypted) | State file exists in S3 bucket, not locally |
| P2.9 | SSH hardening: password auth disabled | `ssh -o PasswordAuthentication=yes` fails on all VMs |

### Tasks

- [ ] **T2.1** Implement generic VM module (`opentofu/modules/vm/main.tf`):
  ```hcl
  variable "vm_name" {
    type        = string
    description = "VM display name in Proxmox"
  }

  variable "vm_id" {
    type        = number
    description = "Unique VM ID (101, 201, 301 for testing/staging/prod)"
  }

  variable "node_name" {
    type        = string
    description = "Proxmox node name"
  }

  variable "template_id" {
    type        = number
    default     = 9000
    description = "Template VM ID to clone from"
  }

  variable "cpu_cores" {
    type        = number
    default     = 2
  }

  variable "memory_mb" {
    type        = number
    default     = 4096
  }

  variable "disk_size_gb" {
    type        = number
    default     = 30
  }

  variable "disk_datastore" {
    type        = string
    default     = "local-lvm"
  }

  variable "network_bridge" {
    type        = string
    default     = "vmbr0"
  }

  variable "network_vlan" {
    type        = number
    default     = null
    description = "VLAN tag (null = untagged/management VLAN)"
  }

  variable "network_model" {
    type        = string
    default     = "virtio"
  }

  variable "ip_address" {
    type        = string
    description = "Static IP in CIDR notation (e.g., 10.0.20.11/24)"
  }

  variable "gateway" {
    type        = string
  }

  variable "dns_servers" {
    type        = list(string)
    default     = ["1.1.1.1", "8.8.8.8"]
  }

  variable "ssh_user" {
    type        = string
    default     = "ubuntu"
  }

  variable "ssh_keys" {
    type        = list(string)
    description = "List of public SSH keys"
  }

  variable "cloud_init_user_data_file" {
    type        = string
    default     = null
    description = "Path to user-data cloud-init YAML"
  }

  variable "tags" {
    type        = list(string)
    default     = []
  }

  variable "on_boot" {
    type        = bool
    default     = true
  }

  variable "agent_enabled" {
    type        = bool
    default     = true
  }

  resource "proxmox_virtual_environment_vm" "vm" {
    name      = var.vm_name
    node_name = var.node_name
    vm_id     = var.vm_id
    tags      = var.tags
    on_boot   = var.on_boot

    agent {
      enabled = var.agent_enabled
    }

    clone {
      vm_id = var.template_id
      full  = true
    }

    cpu {
      cores   = var.cpu_cores
      sockets = 1
      type    = "x86-64-v2-AES"
      numa    = false
    }

    memory {
      dedicated = var.memory_mb
    }

    disk {
      datastore_id = var.disk_datastore
      interface    = "scsi0"
      size         = var.disk_size_gb
      discard      = "on"
      ssd          = true
      iothread     = true
    }

    network_device {
      bridge = var.network_bridge
      model  = var.network_model
      vlan_id = var.network_vlan
    }

    initialization {
      ip_config {
        ipv4 {
          address = var.ip_address
          gateway = var.gateway
        }
      }

      dns {
        servers = var.dns_servers
      }

      user_account {
        username = var.ssh_user
        keys     = var.ssh_keys
      }

      user_data_file_id = var.cloud_init_user_data_file != null ? proxmox_virtual_environment_file.user_data[0].id : null
    }

    stop_on_destroy     = true
    reboot_after_update = true

    lifecycle {
      ignore_changes = [
        network_device[0].mac_address,
      ]
    }
  }

  resource "proxmox_virtual_environment_file" "user_data" {
    count = var.cloud_init_user_data_file != null ? 1 : 0

    content_type = "snippets"
    datastore_id = "local"
    node_name    = var.node_name

    source_raw {
      data      = file(var.cloud_init_user_data_file)
      file_name = "cloud-init-${var.vm_name}.yaml"
    }
  }

  output "vm_id" {
    value = proxmox_virtual_environment_vm.vm.id
  }

  output "vm_name" {
    value = proxmox_virtual_environment_vm.vm.name
  }

  output "ipv4_address" {
    value = element(split("/", var.ip_address), 0)
  }

  output "ipv4_cidr" {
    value = var.ip_address
  }
  ```

- [ ] **T2.2** Create testing environment (`opentofu/environments/testing/main.tf`) — uses `modules/vm` directly:
  ```hcl
  module "k8s_testing" {
    source = "../../modules/vm"

    vm_name       = "k8s-testing"
    vm_id         = 101
    node_name     = "pve"  # Adjust to your Proxmox node name
    cpu_cores     = 2
    memory_mb     = 4096
    disk_size_gb  = 30
    network_bridge = "vmbr0"
    network_vlan  = 30
    ip_address    = "10.0.30.11/24"
    gateway       = "10.0.30.1"
    ssh_keys      = [file("~/.ssh/id_ed25519.pub")]
    tags          = ["k8s", "env:testing", "role:server"]

    k3s_role       = "server"
    k3s_token      = var.k3s_token
    environment     = "testing"
  }
  ```

- [ ] **T2.3** Create staging environment (`opentofu/environments/staging/main.tf`) — uses `modules/vm` directly:
  ```hcl
  module "k8s_staging" {
    source = "../../modules/vm"

    vm_name        = "k8s-staging"
    vm_id          = 201
    node_name      = "pve"
    cpu_cores      = 4
    memory_mb      = 8192
    disk_size_gb   = 50
    network_bridge = "vmbr0"
    network_vlan   = 20
    ip_address     = "10.0.20.11/24"
    gateway        = "10.0.20.1"
    ssh_keys       = [file("~/.ssh/id_ed25519.pub")]
    tags           = ["k8s", "env:staging", "role:server"]

    k3s_role       = "server"
    k3s_token      = var.k3s_token
    environment     = "staging"
  }
  ```

- [ ] **T2.4** Create production environment (`opentofu/environments/prod/main.tf`) — uses `modules/vm` directly:
  ```hcl
  module "k8s_prod_agent" {
    source = "../../modules/vm"

    vm_name        = "k8s-prod-agent"
    vm_id          = 301
    node_name      = "pve"
    cpu_cores      = 4
    memory_mb      = 8192
    disk_size_gb   = 100
    network_bridge = "vmbr0"
    network_vlan   = null  # Untagged — shares existing LAN
    ip_address     = "192.168.1.30/24"  # Static IP on existing LAN
    gateway        = "192.168.1.1"
    ssh_keys       = [file("~/.ssh/id_ed25519.pub")]
    tags           = ["k8s", "env:prod", "role:agent"]

    k3s_role        = "agent"
    k3s_token       = var.k3s_token
    k3s_server_url  = "https://${var.existing_k3s_server_ip}:6443"  # Existing cluster
    environment     = "prod"
  }
  ```

- [ ] **T2.5** Define `.tfvars` for each environment:
  ```hcl
  # environments/testing/terraform.tfvars
  proxmox_endpoint          = "https://192.168.1.2:8006/"
  proxmox_api_token_id      = "terraform@pve!provider"
  proxmox_api_token_secret  = "<from .env>"
  proxmox_tls_insecure      = true
  proxmox_ssh_user          = "root"
  k3s_token                 = "<testing-cluster-token>"
  ```

- [ ] **T2.6** Generate Ansible inventory from OpenTofu:
  ```hcl
  # opentofu/outputs.tf
  resource "local_file" "ansible_inventory" {
    content = templatefile("${path.module}/templates/inventory.tmpl", {
      testing_vm  = module.k8s_testing
      staging_vm  = module.k8s_staging
      prod_vm     = module.k8s_prod_agent
    })
    filename = "${path.module}/../ansible/inventory.ini"
  }
  ```

- [ ] **T2.7** Write Phase 2 tests (`proxmox/tests/test-vm-provision.sh`):
  ```bash
  #!/bin/bash
  source "$(dirname "$0")/../../scripts/assert.sh"

  # Test: VMs exist in Proxmox
  for vmid in 101 201 301; do
    assert_contains "$(curl -s -H "Authorization: PVEAPIToken=..." \
      https://pve:8006/api2/json/nodes/pve/qemu/$vmid/status/current)" \
      '"status":"running"' "VM $vmid is running"
  done

  # Test: VMs are reachable via SSH
  for ip in 10.0.30.11 10.0.20.11 192.168.1.30; do
    assert_ssh_ok "$ip" "VM at $ip accepts SSH"
  done

  # Test: VLAN isolation (staging can't reach testing)
  ssh 10.0.20.11 'ping -c 1 -W 2 10.0.30.11' && exit 1 || echo "PASS: VLAN isolation works"
  ```

---

## 8. Phase 3: Ansible Post-Provisioning

**Goal:** Configure OS-level settings (kernel modules, packages, security) on all provisioned VMs via Ansible.

**Dependencies:** Phase 2 complete (VMs are provisioned and reachable).
**Duration:** ~2 hours.

### Specs

| Spec ID | Description | Validation |
|---------|-------------|------------|
| P3.1 | Ansible connects to all 3 VMs via SSH | `ansible all -m ping` succeeds |
| P3.2 | Kernel modules loaded: overlay, br_netfilter | `lsmod | grep overlay` returns output |
| P3.3 | sysctl parameters set for K3s/Cilium | `sysctl net.bridge.bridge-nf-call-iptables` = 1 |
| P3.4 | kubectl and helm installed on all nodes | `kubectl version --client && helm version` |
| P3.5 | qemu-guest-agent running on all VMs | `systemctl is-active qemu-guest-agent` = active |
| P3.6 | UFW/firewall configured (if applicable) | Only required ports open |
| P3.7 | Ansible playbook is idempotent | Second run produces 0 changes |
| P3.8 | Inventory groups separate roles: servers, agents | `ansible-inventory --list` shows correct groups |

### Tasks

- [ ] **T3.1** Create Ansible inventory template (`ansible/inventory.example.yml`):
  ```yaml
  all:
    children:
      proxmox_vms:
        children:
          testing:
            hosts:
              k8s-testing:
                ansible_host: 10.0.30.11
                ansible_user: ubuntu
          staging:
            hosts:
              k8s-staging:
                ansible_host: 10.0.20.11
                ansible_user: ubuntu
          production:
            hosts:
              k8s-prod-agent:
                ansible_host: 192.168.1.30
                ansible_user: ubuntu
        vars:
          ansible_ssh_common_args: -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
  ```

- [ ] **T3.2** Create post-provisioning playbook (`ansible/playbooks/post-provision.yml`):
  ```yaml
  ---
  - name: Post-provision all Proxmox VMs
    hosts: proxmox_vms
    become: true
    gather_facts: true

    vars_files:
      - ../vars/main.yml

    pre_tasks:
      - name: Wait for SSH connection
        ansible.builtin.wait_for_connection:
          delay: 10
          timeout: 120

      - name: Display target info
        ansible.builtin.debug:
          msg: |
            Bootstrapping: {{ inventory_hostname }}
            IP: {{ ansible_host }}
            Arch: {{ ansible_architecture }}
            OS: {{ ansible_distribution }} {{ ansible_distribution_version }}

    roles:
      - role: ../roles/bootstrap-node
        tags: [bootstrap, kernel]
      - role: ../roles/install-kubectl
        tags: [kubectl]
      - role: ../roles/install-helm
        tags: [helm]

    post_tasks:
      - name: Verify kubectl
        ansible.builtin.command: kubectl version --client --output=json
        changed_when: false

      - name: Verify helm
        ansible.builtin.command: helm version --short
        changed_when: false

      - name: Bootstrap summary
        ansible.builtin.debug:
          msg: |
            ✅ {{ inventory_hostname }} bootstrapped
            kubectl: {{ kubectl_check.stdout }}
            helm: {{ helm_check.stdout }}
  ```

- [ ] **T3.3** Create K3s installation playbook (`ansible/playbooks/install-k3s.yml`):
  - Handles server install for staging/testing
  - Handles agent install for production (joins existing cluster)
  - Uses k3s_token from vars

- [ ] **T3.4** Extend `proxmox/.env.example` with Ansible variables:
  ```bash
  # Proxmox
  PROXMOX_ENDPOINT=https://192.168.1.2:8006/
  PROXMOX_API_TOKEN_ID=terraform@pve!provider
  PROXMOX_API_TOKEN_SECRET=xxxx
  PROXMOX_TLS_INSECURE=true
  PROXMOX_NODE_NAME=pve

  # OpenTofu backend (S3/MinIO)
  S3_ENDPOINT=https://minio.internal:9000
  S3_BUCKET=terraform-state
  S3_ACCESS_KEY=minioadmin
  S3_SECRET_KEY=minioadmin

  # K3s tokens (unique per environment)
  K3S_TOKEN_TESTING=testing-token-change-me
  K3S_TOKEN_STAGING=staging-token-change-me
  K3S_TOKEN_PROD=prod-token-change-me     # Must match existing cluster token

  # Existing production cluster
  EXISTING_K3S_SERVER_IP=192.168.1.10
  EXISTING_K3S_SERVER_PORT=6443

  # SSH
  SSH_PUBLIC_KEY_PATH=~/.ssh/id_ed25519.pub
  SSH_USER=ubuntu
  ```

- [ ] **T3.5** Reuse existing Ansible roles from `ansible/roles/` (bootstrap-node, install-kubectl, install-helm) — extend bootstrap-node role with qemu-guest-agent check

- [ ] **T3.6** Write Phase 3 tests (`proxmox/tests/test-ansible-post.sh`)

---

## 9. Phase 4: K3s Cluster Bootstrap

**Goal:** Install K3s on all VMs — servers on staging/testing, agent on production.

**Dependencies:** Phase 3 complete.
**Duration:** ~1.5 hours.

### Specs

| Spec ID | Description | Validation |
|---------|-------------|------------|
| P4.1 | Staging K3s server is Running | `kubectl get nodes` on staging shows Ready |
| P4.2 | Testing K3s server is Running | `kubectl get nodes` on testing shows Ready |
| P4.3 | Production agent joins existing cluster | `kubectl get nodes` on existing cluster shows new agent |
| P4.4 | K3s tokens match configuration | Nodes join without token errors |
| P4.5 | Cilium can be installed (kube-proxy disabled, flannel off) | `cilium install` works without conflicts |
| P4.6 | Kubeconfig retrievable from each cluster | `kubectl --kubeconfig=<path> get nodes` works |

### Tasks

- [ ] **T4.1** Install K3s on testing VM:
  ```bash
  ssh ubuntu@10.0.30.11
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='server \
    --flannel-backend=none \
    --disable-network-policy \
    --disable-kube-proxy \
    --disable traefik \
    --disable metrics-server \
    --token=${K3S_TOKEN_TESTING}' sh -
  ```

- [ ] **T4.2** Install K3s on staging VM:
  ```bash
  ssh ubuntu@10.0.20.11
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='server \
    --flannel-backend=none \
    --disable-network-policy \
    --disable-kube-proxy \
    --disable traefik \
    --disable metrics-server \
    --write-kubeconfig-mode=644 \
    --token=${K3S_TOKEN_STAGING}' sh -
  ```

- [ ] **T4.3** Install K3s agent on production VM (joins existing cluster):
  ```bash
  ssh ubuntu@192.168.1.30
  curl -sfL https://get.k3s.io | K3S_URL=https://${EXISTING_K3S_SERVER_IP}:6443 \
    K3S_TOKEN=${K3S_TOKEN_PROD} sh -
  ```

- [ ] **T4.4** Retrieve kubeconfigs:
  ```bash
  # Testing
  scp ubuntu@10.0.30.11:/etc/rancher/k3s/k3s.yaml ~/.kube/config-homelab-testing
  sed -i 's/127.0.0.1/10.0.30.11/' ~/.kube/config-homelab-testing

  # Staging
  scp ubuntu@10.0.20.11:/etc/rancher/k3s/k3s.yaml ~/.kube/config-homelab-staging
  sed -i 's/127.0.0.1/10.0.20.11/' ~/.kube/config-homelab-staging
  ```

- [ ] **T4.5** Verify all clusters:
  ```bash
  kubectl --kubeconfig ~/.kube/config-homelab-testing get nodes
  kubectl --kubeconfig ~/.kube/config-homelab-staging get nodes
  # Production: existing kubeconfig, verify new node appears
  kubectl get nodes -o wide
  ```

- [ ] **T4.6** Write Phase 4 tests (`proxmox/tests/test-k3s.sh`)

---

## 10. Phase 5: GitOps Integration (ArgoCD Bootstrap)

**Goal:** Deploy ArgoCD on staging and integrate with the existing GitOps repo. Production agent integrates automatically with existing ArgoCD.

**Dependencies:** Phase 4 complete.
**Duration:** ~2 hours.

### Specs

| Spec ID | Description | Validation |
|---------|-------------|------------|
| P5.1 | ArgoCD running on staging cluster | `argocd` namespace pods all Running |
| P5.2 | Staging points to staging branch/tag of GitOps repo | ArgoCD UI shows staging apps |
| P5.3 | Testing cluster has minimal bootstrap (optional) | Testing can be refreshed from scratch quickly |
| P5.4 | Production agent is visible in existing ArgoCD | New node shown in cluster info |
| P5.5 | Staging ArgoCD apps mirror production (different namespaces/endpoints) | Same app set, different ingress hosts |

### Tasks

- [ ] **T5.1** Install ArgoCD on staging:
  ```bash
  kubectl --kubeconfig ~/.kube/config-homelab-staging create namespace argocd
  helm repo add argo https://argoproj.github.io/argo-helm
  helm install argocd argo/argo-cd \
    --namespace argocd \
    --kubeconfig ~/.kube/config-homelab-staging \
    -f platform/argocd/values.yaml  # Reuse existing values, adjust domain
  ```

- [ ] **T5.2** Create staging-specific ArgoCD bootstrap:
  - Point to a staging branch or path in the same GitOps repo
  - Use staging-specific ingress domains (e.g., `grafana.staging.homelab.local`)
  - Adjust resource limits for single-node cluster

- [ ] **T5.3** Configure testing environment for quick teardown/rebuild:
  - Minimal ArgoCD bootstrap (or skip — use kubectl for testing)
  - Document rebuild procedure

- [ ] **T5.4** Verify production agent node health in existing ArgoCD UI

- [ ] **T5.5** Write Phase 5 tests

---

## 11. Phase 6: AIOps Integration (v1)

**Goal:** Deploy K8sGPT (cloud LLM backend), Falco (eBPF runtime security), and Grafana ML anomaly detection on staging cluster.

**Dependencies:** Phase 5 complete (ArgoCD available on staging, monitoring present).
**Duration:** ~2 hours.

**Resource constraint:** Staging VM has 8GB RAM. This phase deploys only lightweight AIOps components. Ollama, Robusta, and Trivy Operator are deferred to a future phase (v2) when either a dedicated AIOps VM or larger production node is available.

### Specs

| Spec ID | Description | Validation |
|---------|-------------|------------|
| P6.0 | Staging has >2GB free allocatable memory before AIOps deploy | `kubectl describe nodes` shows allocatable memory with headroom |
| P6.1 | K8sGPT operator running on staging (cloud LLM backend) | `k8sgpt analyze` returns results |
| P6.2 | Falco running on staging with eBPF probes | `kubectl get pods -n falco` shows Running |
| P6.3 | Grafana ML anomaly detection rules loaded | PrometheusRules CR created, rules visible in Prometheus UI |
| P6.4 | K8sGPT can explain cluster issues with LLM reasoning | `k8sgpt analyze --explain` produces meaningful output |
| P6.5 | Falco detects test events | Trigger a test rule violation, verify Falco logs it |

### AIOps Directory Structure (v1)

```
proxmox/aiops/
├── k8sgpt/
│   └── values.yaml               # K8sGPT Helm values (cloud backend)
├── falco/
│   └── values.yaml               # Falco Helm values
└── anomaly/
    └── recording-rules.yaml       # Prometheus ML anomaly rules
```

### Tasks

- [ ] **T6.1** Deploy K8sGPT operator (cloud LLM backend):
  ```bash
  helm repo add k8sgpt https://charts.k8sgpt.ai
  helm install k8sgpt-operator k8sgpt/k8sgpt-operator \
    --namespace aiops --create-namespace \
    --kubeconfig ~/.kube/config-homelab-staging \
    -f proxmox/aiops/k8sgpt/values.yaml
  ```

  ```yaml
  # aiops/k8sgpt/values.yaml
  k8sgpt:
    ai:
      enabled: true
      model: gpt-4o-mini              # Cloud backend (or any OpenAI-compatible)
      backend: openai
      baseUrl: https://api.openai.com/v1
      secretRef:
        name: k8sgpt-ai-secret        # Contains OPENAI_API_KEY via SealedSecret
    noCache: false
    filters:
      - Pod
      - Deployment
      - Service
      - Ingress
      - PvC
      - StatefulSet
      - CronJob
      - Node
      - HPA
  ```

- [ ] **T6.2** Deploy Falco:
  ```bash
  helm repo add falcosecurity https://falcosecurity.github.io/charts
  helm install falco falcosecurity/falco \
    --namespace falco --create-namespace \
    --kubeconfig ~/.kube/config-homelab-staging \
    -f proxmox/aiops/falco/values.yaml
  ```

  ```yaml
  # aiops/falco/values.yaml
  falco:
    json_output: true
    json_include_output_property: true
    file_output:
      enabled: false
    program_output:
      enabled: true
      keep_alive: false
    http_output:
      enabled: true
      url: "http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push"
    rules_file:
      - /etc/falco/falco_rules.yaml
      - /etc/falco/falco_rules.local.yaml
      - /etc/falco/k8s_audit_rules.yaml
      - /etc/falco/rules.d
    driver:
      kind: ebpf
  ```

- [ ] **T6.3** Deploy Grafana ML anomaly detection rules:
  ```yaml
  # aiops/anomaly/recording-rules.yaml
  apiVersion: monitoring.coreos.com/v1
  kind: PrometheusRule
  metadata:
    name: anomaly-detection
    namespace: monitoring
    labels:
      release: prometheus
  spec:
    groups:
      - name: homelab_anomalies
        rules:
          - record: pod_restarts:anomaly_band_upper
            expr: |
              avg_over_time(increase(kube_pod_container_status_restarts_total[1h])[12h:1h])
              + 3 * stddev_over_time(increase(kube_pod_container_status_restarts_total[1h])[12h:1h])
          - alert: HighPodRestarts
            expr: |
              increase(kube_pod_container_status_restarts_total[1h])
              > pod_restarts:anomaly_band_upper
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "Anomalous pod restart rate detected"
  ```

- [ ] **T6.4** Write Phase 6 tests (`proxmox/tests/test-aiops.sh`):
  ```bash
  # Test: K8sGPT responds (with timeout — cloud API may be slow)
  timeout 60 k8sgpt analyze --explain -n kube-system || echo "WARN: K8sGPT timed out"

  # Test: Falco pods running
  assert_contains "$(kubectl get pods -n falco --no-headers)" "Running" "Falco running"

  # Test: Anomaly rules exist
  assert_contains "$(kubectl get prometheusrule -n monitoring)" "anomaly-detection" "Anomaly rules exist"
  ```

### v2 Roadmap (Future)

| Component | When | Resource Needed |
|-----------|------|-----------------|
| Ollama + local K8sGPT | Dedicated VM with ≥10GB RAM | 8-12GB RAM |
| Robusta Classic | After Ollama is available | ~300MB |
| Trivy Operator | After v1 validated | ~500MB |
| AIOps dashboards in Grafana | After all tools running | negligible |

---

## 12. Phase 7: Security Hardening & Validation

**Goal:** Apply security best practices across all environments and validate end-to-end.

**Dependencies:** Phase 6 complete.
**Duration:** ~2 hours.

### Specs

| Spec ID | Description | Validation |
|---------|-------------|------------|
| P7.1 | No secrets in OpenTofu state or plan | `gitleaks detect` finds zero secrets |
| P7.2 | OpenTofu state encrypted at rest (S3 SSE) | State file server-side encrypted |
| P7.3 | Proxmox API token has least-privilege scope | Token can only manage VMs, not delete hosts |
| P7.4 | SSH key-only auth on all VMs | PasswordAuthentication = no |
| P7.5 | kube-bench passes on staging K3s (with K3s false-positive filter) | Filtered scan shows 0 FAIL |
| P7.6 | Trivy scans show no CRITICAL CVEs | `trivy config --severity CRITICAL` returns 0 |
| P7.7 | Network policies applied on staging | Default-deny with explicit allows |
| P7.8 | All phase tests pass end-to-end | `make test-proxmox` exits 0 |

### Tasks

- [ ] **T7.1** Review Proxmox API token permissions — ensure PVEVMAdmin role doesn't include Sys.Modify (if not needed)
- [ ] **T7.2** Enable S3 server-side encryption for OpenTofu state
- [ ] **T7.3** Harden SSH on all VMs via Ansible:
  ```yaml
  - name: Harden SSH
    ansible.builtin.lineinfile:
      path: /etc/ssh/sshd_config
      regexp: '^#?PasswordAuthentication'
      line: 'PasswordAuthentication no'
    notify: restart sshd
  ```
- [ ] **T7.4** Run kube-bench with K3s filter on staging
- [ ] **T7.5** Run full test suite and fix any failures
- [ ] **T7.6** Document security posture in `proxmox/docs/security.md`

---

## 13. Testing Strategy

### TDD Approach

```
1. WRITE SPEC → Define acceptance criteria (Spec IDs above)
2. WRITE TEST → Create test scripts that validate the spec
3. IMPLEMENT  → Write OpenTofu/Ansible code to make tests pass
4. VERIFY     → Run tests, confirm all specs pass
5. COMMIT     → Git commit with spec ID in message
```

### Test Categories

| Category | Tool | Purpose |
|----------|------|---------|
| **Structure** | `make validate-structure-proxmox` | Directory layout, file existence |
| **Lint** | `tofu fmt`, `tofu validate`, `ansible-lint`, `yamllint` | Syntax and schema validation |
| **Security** | gitleaks, trivy | Secret detection, CVE scanning |
| **Infrastructure** | Bash scripts with `assert.sh` | Proxmox API, VM state, SSH reachability |
| **Kubernetes** | kubectl, k8sgpt | Cluster health, node readiness |
| **Integration** | `make test-proxmox` | Full pipeline validation |
| **AIOps** | k8sgpt analyze, falco | AIOps stack health checks |

### Makefile Targets

```makefile
.PHONY: test-proxmox test-proxmox-phase0 test-proxmox-phase1 test-proxmox-phase2
.PHONY: test-proxmox-phase3 test-proxmox-phase4 test-proxmox-phase5
.PHONY: test-proxmox-phase6 test-proxmox-phase7

test-proxmox-phase0: ## Proxmox foundation tests
	bash proxmox/tests/test-tofu.sh

test-proxmox-phase2: ## VM provisioning tests
	bash proxmox/tests/test-vm-provision.sh

test-proxmox-phase3: ## Ansible post-provisioning tests
	bash proxmox/tests/test-ansible-post.sh

test-proxmox-phase4: ## K3s cluster tests
	bash proxmox/tests/test-k3s.sh

test-proxmox-phase6: ## AIOps stack tests
	bash proxmox/tests/test-aiops.sh

test-proxmox: test-proxmox-phase0 test-proxmox-phase2 test-proxmox-phase3 \
              test-proxmox-phase4 test-proxmox-phase6 ## Run all Proxmox tests
```

---

## 14. Risk Register

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| Proxmox API token scope too broad | High | Low | Audit with `pveum user permissions terraform@pve` |
| VLAN misconfiguration exposes staging to prod | High | Medium | Test network isolation in Phase 2 tests |
| K3s agent on prod joins with wrong token | High | Low | Use existing cluster token from `infra/.env` |
| Ollama 8GB RAM requirement exceeds staging VM | Low | Low | Deferred to v2; v1 uses cloud LLM backend for K8sGPT |
| K8sGPT cloud API costs or rate limits | Low | Medium | Monitor usage; switch to local Ollama when v2 VM available |
| OpenTofu state corruption with parallel applies | High | Low | Use `-parallelism=1` and S3 state locking |
| bpg/proxmox provider version incompatible with PVE 9.x | Medium | Medium | Pin provider to `~> 0.78`, test in dev first |
| Cloud-init user data exceeds Proxmox snippet limit | Low | Low | Split config between cloud-init and Ansible |
| Testing VM resources insufficient for AIOps stack | Medium | Medium | Run AIOps only on staging; keep testing minimal |
| Staging drift from production due to different scale | Medium | Medium | Document differences in `staging/README.md` |
| Existing cluster k3s version mismatch with new agent | High | Low | Verify K3s version before joining agent |

---

## 15. Operational Runbooks (Pre-Spec)

Runbooks to create in Phase 7 (documentation phase):

1. **`destroy-rebuild-env.md`** — How to `tofu destroy` and `tofu apply` an environment from scratch
2. **`add-vm.md`** — How to add a new VM to any environment using the VM module
3. **`template-update.md`** — Update the Ubuntu template VM and roll out to all clones
4. **`aiops-troubleshooting.md`** — Debug K8sGPT/Ollama/Robusta issues
5. **`production-join.md`** — Procedure to join new agent nodes to existing production cluster
6. **`vlan-setup.md`** — Configure VLANs on Proxmox networking

---

## 16. DevOps & AIOps Best Practices

### DevOps Principles Applied

| Principle | How it's applied |
|-----------|-----------------|
| **Infrastructure as Code** | 100% OpenTofu/Ansible — no manual VM creation |
| **GitOps** | ArgoCD controls all Kubernetes state from Git |
| **Immutable Infrastructure** | VMs are cloned from template, never manually configured |
| **TDD** | Tests written before implementation for each phase |
| **Least Privilege** | Proxmox API token scoped to VM operations only |
| **Environment Parity** | Staging mirrors production GitOps configuration |
| **Secrets Management** | `.env` gitignored, SealedSecrets for K8s secrets, Proxmox API tokens never committed |
| **CI/CD** | GitHub Actions validates and applies changes |
| **Idempotency** | OpenTofu and Ansible are idempotent by design |

### AIOps Principles Applied

| Principle | How it's applied |
|-----------|-----------------|
| **Observability-Driven** | AIOps tools integrate with existing Prometheus/Loki/Grafana |
| **Local-First** | Ollama runs on-prem — no data leaves the cluster |
| **Human-in-the-Loop** | K8sGPT suggests fixes, doesn't auto-apply; Robusta enriches alerts, doesn't auto-remediate |
| **Progressive Deployment** | AIOps runs on staging first to validate before production |
| **Lightweight** | Tools selected for homelab scale (not enterprise overkill) |
| **Security-Integrated** | Falco + Trivy provide continuous security monitoring without AI overhead |
| **Anomaly-Aware** | Grafana ML detection catches unusual patterns without manual threshold tuning |

### DevOps Maturity Model Target

| Capability | Target Level |
|------------|-------------|
| Version Control | Level 5: Everything in Git |
| CI/CD | Level 4: Automated deploy with manual approval for prod |
| Infrastructure as Code | Level 5: 100% IaC, no manual resources |
| Monitoring | Level 4: Proactive anomaly detection |
| Security | Level 4: Automated scanning + runtime detection |
| AIOps | Level 3: LLM-assisted diagnostics + anomaly detection |

---

## 17. Resource Budget

### VM Resource Allocation

| VM | vCPU | RAM | Disk | OS Overhead | Usable for K8s | Environment |
|----|------|-----|------|-------------|-----------------|-------------|
| k8s-testing | 2 | 4GB | 30GB | ~500MB | ~3.5GB | Testing |
| k8s-staging | 4 | 8GB | 50GB | ~500MB | ~7.5GB | Staging |
| k8s-prod-agent | 4 | 8GB | 100GB | ~500MB | ~7.5GB | Production (agent) |

### Staging VM Component Budget (8GB total)

This is the most constrained VM — it runs a full GitOps stack on a single node.

| Component | RAM (min) | RAM (typical) | Deployed in Phase |
|-----------|-----------|---------------|-------------------|
| K3s server + Cilium agent | 500MB | 700MB | 4 |
| CoreDNS + local-path-provisioner | 100MB | 150MB | 4 (built-in) |
| ArgoCD (server + repo-server + controller + redis) | 400MB | 600MB | 5 |
| MetalLB | 50MB | 80MB | 5 |
| Traefik | 200MB | 400MB | 5 |
| cert-manager | 100MB | 150MB | 5 |
| kube-prometheus-stack (Prometheus + Grafana + Alertmanager) | 800MB | 1500MB | 5 |
| Loki SingleBinary | 300MB | 600MB | 5 |
| OTel Collector | 150MB | 300MB | 5 |
| **Subtotal (platform + observability)** | **2600MB** | **4480MB** | 4-5 |
| K8sGPT operator (cloud backend) | 100MB | 200MB | 6 |
| Falco (eBPF) | 100MB | 200MB | 6 |
| **Total with AIOps v1** | **2800MB** | **4880MB** | 4-6 |
| **Available headroom** | — | **~2.6GB** | — |

**Conclusion:** The staging VM can fit the full GitOps stack + AIOps v1 with ~2.6GB headroom. The components that were **deferred to v2** would each consume:

| Deferred Component | RAM |
|--------------------|-----|
| Ollama (llama3.1:8b) | 8-12GB |
| Robusta Classic | ~300MB |
| Trivy Operator | ~500MB |

These would **not fit** on an 8GB VM alongside the platform stack. They require either a dedicated AIOps VM or a larger production node.

### Testing VM (4GB — Minimal)

Testing is intentionally lightweight — no ArgoCD, no observability stack. It runs only K3s + essential components for functional testing, leaving ~3GB for test workloads.

### Production Agent VM (8GB)

The production agent node adds workload capacity to the existing cluster. The existing cluster already runs the control plane and full stack, so the agent's 7.5GB usable RAM is fully available for application workloads.

---

## Execution Checklist

Before starting execution, confirm:

- [ ] **Proxmox ready:** PVE 9.x host with local and local-lvm storage
- [ ] **Network ready:** VLANs 20 and 30 configured on vmbr0 (or plan to create them)
- [ ] **S3/MinIO ready:** Backend for OpenTofu state storage
- [ ] **OpenTofu installed:** Version >= 1.10 on admin machine
- [ ] **Ansible installed:** Version >= 2.14 on admin machine
- [ ] **SSH keys generated:** `~/.ssh/id_ed25519` exists
- [ ] **Existing cluster accessible:** Can `kubectl get nodes` on production
- [ ] **DNS/hosts:** Resolve Proxmox host, MinIO, and planned VM hostnames
- [ ] **GitHub repo:** This project committed and pushed (same repo as homelab-gitops-infra)
- [ ] **Phase 0 complete** before starting Phase 1
- [ ] **Each phase's tests pass** before moving to the next

---

*This plan follows the same TDD, spec-driven, phased approach as the existing homelab-gitops-infra project. Do not proceed to the next phase until all specs for the current phase are validated.*
