# Homelab GitOps Infrastructure

A Kubernetes homelab running on an ARM64 SBC and an old PC, managed entirely through Git.
Built it to learn how real GitOps works: ArgoCD, Cilium eBPF networking, the whole observability stack.

Now with **3 environments** provisioned via OpenTofu on Proxmox, because testing changes directly on production is asking for trouble.

Two physical nodes + 3 Proxmox VMs on the home network:

- **server**: ARM64 SBC that runs the K3s control plane
- **agent**: x86_64 box that runs all the actual workloads
- **k8s-prod-agent**: x86_64 VM on Proxmox, extra worker for production
- **k8s-staging**: VM on VLAN 20, mirrors production for safe testing
- **k8s-testing**: VM on VLAN 30, throwaway environment for experiments

Everything is defined here as code. If the cluster burns down, I can rebuild it from this repo.

## What's running

| Thing | Why I picked it |
|-------|----------------|
| **K3s** | Kubernetes that actually runs on a Pi without eating all the RAM |
| **Cilium 1.18.9** | eBPF CNI with Hubble observability. Pinned to 1.18 because 1.19.x silently kills networking on ARM64. That was a fun week of debugging. |
| **ArgoCD** | GitOps so I never have to `kubectl apply` anything manually. App-of-apps bootstraps everything |
| **Traefik** | Handles ingress. Serves Grafana, ArgoCD UI, and Home Assistant on HTTPS |
| **MetalLB** | Gives services real IPs on my LAN instead of NodePorts |
| **cert-manager** | Auto-generates TLS certs so browsers don't complain |
| **Prometheus + Grafana** | Metrics and dashboards. Grafana at `grafana.homelab.local` |
| **Loki** | Log aggregation. Keeps 28 days of everything |
| **OpenTelemetry** | Forwards traces/metrics to Loki and Prometheus |
| **Home Assistant** | Home automation. StatefulSet with 10Gi PVC, accessible at `ha.homelab.local` |

## Infrastructure as Code

Before the VMs above, there's an IaC layer. All 3 environments are defined in OpenTofu and provisioned on Proxmox 9.x:

| Environment | VLAN | vCPU | RAM | Disk | Purpose |
|-------------|------|------|-----|------|---------|
| **testing** | 30 | 2 | 4GB | 30GB | Ephemeral experiments |
| **staging** | 20 | 4 | 8GB | 50GB | Production mirror (ArgoCD, monitoring) |
| **prod** | untagged | 4 | 8GB | 100GB | Additional K3s agent node |

```bash
cd proxmox/opentofu && tofu plan   # see what changes
make tofu-apply-testing             # provision testing VM
make tofu-apply-staging             # provision staging VM
make tofu-apply-prod                # provision production agent
```

See [proxmox/PLAN.md](proxmox/PLAN.md) for the full project plan with architecture decisions and phases.

## Getting it running

Prerequisites: two Linux machines on the same LAN, plus `kubectl`, `helm`, and `cilium` CLI on your laptop.

```bash
git clone https://github.com/<GITHUB_USER>/<REPO_NAME>.git
cd homelab-gitops-infra

# Install K3s on both nodes (disable kube-proxy, Cilium replaces it)
# server:  curl -sfL https://get.k3s.io | sh -s - --disable-kube-proxy --flannel-backend=none --disable-network-policy
# agent: curl -sfL https://get.k3s.io | K3S_URL=https://<CONTROL_PLANE_IP>:6443 K3S_TOKEN=<token> sh -

# Install Cilium (must be 1.18.9 on ARM64)
cilium install --version 1.18.9 -f infra/cilium/values.yaml

# Bootstrap GitOps. ArgoCD takes over from here.
kubectl apply -f platform/argocd/bootstrap/argocd-app.yaml
```

Add to `/etc/hosts` on your laptop:
```
<METALLB_IP>  argocd.homelab.local  grafana.homelab.local  ha.homelab.local
```

Then open `https://argocd.homelab.local` and watch the apps deploy themselves.

## Phases

### Platform (K3s + GitOps)

| # | What | Status |
|---|------|--------|
| 0 | Repo setup, pre-commit hooks, directory structure | ✅ |
| 1 | K3s cluster with Cilium CNI | ✅ |
| 2 | ArgoCD, MetalLB, Traefik, cert-manager | ✅ |
| 3 | Prometheus, Grafana, Loki, OpenTelemetry | ✅ |
| 4 | Home Assistant (StatefulSet, ingress, TLS) | ✅ |
| 5 | Network policies, RBAC, CIS scanning | ✅ |
| 6 | Documentation | ✅ |

### Proxmox IaC (OpenTofu + K3s environments)

| # | What | Status |
|---|------|--------|
| 0 | Repo setup, OpenTofu provider, directory structure | ✅ |
| 1 | Ubuntu cloud-init VM template on Proxmox | ✅ |
| 2 | Provision testing, staging, and production VMs | ✅ |
| 3 | Ansible post-provisioning (kubectl, helm, kernel tuning) | ✅ |
| 4 | K3s bootstrap on all 3 environments | ✅ |
| 5 | GitOps integration (ArgoCD on staging) | ⏳ |
| 6 | AIOps v1 (K8sGPT + Falco + anomaly detection) | ⏳ |

Full platform breakdown in [docs/plan/PLAN.md](docs/plan/PLAN.md).
Proxmox IaC breakdown in [proxmox/PLAN.md](proxmox/PLAN.md).

## Things I learned the hard way

- **Cilium 1.19.x is broken on ARM64.** Silent host network death: SSH daemon stays up, but all TCP connections timeout. No errors anywhere. Pinned to 1.18.9 until it's fixed upstream.
- **Don't run app pods on the control plane with Cilium.** The ClusterIP for the API server becomes unreachable from pods on the same node. Just keep the control plane tainted.
- **4GB RAM is tight.** With Prometheus, Loki, Grafana, ArgoCD, and Home Assistant all on the worker node, I had to reduce Loki's memcached caches from 10GB to 128MB and bump Traefik from 256MB to 384MB.
- **ArgoCD's Helm diff can't handle multi-line ConfigMap data.** Helm renders it as quoted strings, K8s stores it as block scalars. ArgoCD sees them as totally different. Fixed with `ignoreDifferences`.
- **kube-bench on K3s shows false positives.** The tool checks kubeadm paths; K3s puts things under `/var/lib/rancher/k3s/`. Wrote a filter script.

## Docs

- [docs/plan/PLAN.md](docs/plan/PLAN.md): platform plan with specs and tasks
- [docs/plan/HOW-TO-RUN.md](docs/plan/HOW-TO-RUN.md): step-by-step setup guide
- [docs/architecture.md](docs/architecture.md): why I chose each tool
- [docs/runbooks/](docs/runbooks/): recovery procedures for when things break
- [proxmox/PLAN.md](proxmox/PLAN.md): Proxmox IaC plan with ADRs and phases
- [proxmox/docs/runbooks/troubleshooting.md](proxmox/docs/runbooks/troubleshooting.md): every issue encountered and how to fix it
