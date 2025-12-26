# How to Run: Phase 0

> Step-by-step instructions to set up your workstation and bootstrap the nodes.

---

## 1. Prerequisites: Workstation Tools

Install these on your admin machine (the laptop/desktop you manage the cluster from):

```bash
# === Required ===

# Git
sudo apt install git -y          # Debian/Ubuntu
# brew install git                # macOS

# kubectl (aarch64 or x86_64: the Ansible playbook will install this on nodes too)
# For your workstation:
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# Helm (for your workstation: nodes get it via Ansible)
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Ansible (for bootstrapping nodes)
pip install --break-system-packages ansible-core ansible-lint

# Pre-commit (for git hooks)
pip install --break-system-packages pre-commit

# === Optional but Recommended ===

# gitleaks (secret scanning)
# Download from: https://github.com/gitleaks/gitleaks/releases
# Or: brew install gitleaks

# trivy (vulnerability scanning)
# Download from: https://github.com/aquasecurity/trivy/releases
# Or: brew install trivy

# yamllint (already installed if you installed ansible-lint)
pip install --break-system-packages yamllint
```

---

## 2. Clone & Configure

```bash
# Clone the repo
git clone https://github.com/<YOUR_USER>/homelab-gitops-infra.git
cd homelab-gitops-infra

# Install pre-commit hooks (runs on every commit)
pre-commit install

# Create your environment file (NEVER commit this!)
cp infra/env.example infra/.env
vim infra/.env
```

Edit `infra/.env` with your real values:

```bash
# Your actual node IPs and hostnames
K3S_SERVER_HOST=server              # or whatever you call it
K3S_SERVER_IP=<CONTROL_PLANE_IP>
K3S_AGENT_HOST=agent              # or whatever you call it
K3S_AGENT_IP=<WORKER_IP>

# Generate a strong token:
K3S_TOKEN=$(openssl rand -hex 32)

# MetalLB IP pool (pick unused IPs on your LAN)
METALLB_IP_RANGE=<METALLB_IP_RANGE>

# Domains (use .local or .home for homelab)
DOMAIN_HOMEASSISTANT=ha.home.local
DOMAIN_GRAFANA=grafana.home.local
DOMAIN_ARGOCD=argocd.home.local
DOMAIN_HUBBLE=hubble.home.local

# Timezone
TIMEZONE=Europe/Madrid              # adjust to your timezone

# Home Assistant trusted proxies (K3s pod CIDR + your LAN)
HA_TRUSTED_PROXIES=10.42.0.0/16,<LAN_SUBNET>
```

---

## 3. Configure Ansible Inventory

```bash
# Copy the inventory template (NEVER commit this!)
cp ansible/inventory.example.yml ansible/inventory.yml
vim ansible/inventory.yml
```

Edit `ansible/inventory.yml` with your real node info:

```yaml
all:
  children:
    k3s:
      children:
        servers:
          hosts:
            node-server:
              ansible_host: <CONTROL_PLANE_IP>    # Your server IP
              ansible_user: root              # Or your SSH user
              ansible_ssh_private_key_file: ~/.ssh/id_ed25519  # Uncomment if using key auth
          vars:
            ansible_ssh_common_args: -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
        agents:
          hosts:
            node-worker:
              ansible_host: <WORKER_IP>    # Your agent IP
              ansible_user: root
              ansible_ssh_private_key_file: ~/.ssh/id_ed25519  # Uncomment if using key auth
          vars:
            ansible_ssh_common_args: -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
```

**SSH access options:**

| Method | How |
|--------|-----|
| **SSH key (recommended)** | `ssh-copy-id root@<IP>`, then uncomment `ansible_ssh_private_key_file` |
| **Password auth** | Install `sshpass` (`apt install sshpass`), then add `ansible_password` to each host |
| **sudo user** | Set `ansible_user: yourname`: Ansible will prompt for sudo password |

**Test connectivity first:**

```bash
# Quick ping test (prompts for sudo password)
make ansible-ping

# Or manually:
ansible all -m ping --ask-become-pass

# If using SSH password auth instead of keys:
ansible all -m ping --ask-pass --ask-become-pass
```

---

## 4. Verify Phase 0

Run all validations:

```bash
# Validate directory structure, env file, YAML, Helm charts, Ansible
make validate

# Run Phase 0 test suite (62 assertions)
make test-phase0

# Lint Ansible playbooks (production profile)
make ansible-lint

# Scan for secrets (requires gitleaks)
make scan-secrets

# Scan for vulnerabilities (requires trivy)
make scan-vulns

# See all available targets
make help
```

Expected output for `make test-phase0`:

```
==========================================
  Phase 0 Tests: Foundation & Repo Setup
==========================================

--- S0.1: Directory Structure ---
✓ infra/k3s exists
✓ infra/cilium exists
... (22 directory checks)

--- S0.2: YAML Linting ---
...

--- S0.9: Ansible Playbook ---
✓ ansible/playbook.yml exists
✓ ansible/inventory.example.yml exists
✓ bootstrap-node role exists
✓ install-kubectl role exists
✓ install-helm role exists
✓ install-helm role exists
✓ Vars include aarch64 architecture mapping
✓ Vars map aarch64 to arm64 (Go arch)
✓ Ansible playbook syntax is valid

==========================================
  Total:   65
  Passed:  65
  Failed:  0
ALL TESTS PASSED
```

---

## 5. Bootstrap Nodes with Ansible

This installs kubectl and helm on both nodes, and configures kernel parameters for K3s/Cilium.

```bash
# Step 1: Test SSH connectivity first
make ansible-ping

# Step 2: Dry run (no changes made: prompts for sudo password)
make ansible-check

# Step 3: Full run (prompts for sudo password)
make ansible-bootstrap
```

**What it does on each node:**
1. Updates package cache and installs prerequisites (curl, socat, conntrack, etc.)
2. Loads kernel modules: `overlay`, `br_netfilter`
3. Persists kernel modules across reboots
4. Sets sysctl params: IP forwarding, bridge netfilter
5. Disables swap (required by Kubernetes)
6. Installs `kubectl` v1.36.0 (arm64 binary on aarch64)
7. Installs `helm` v4.1.4 (via official get-helm-4 script)
8. Verifies all tools are installed and prints versions

**Idempotent:** Running it again skips already-installed versions.

**Sudo password:** Ansible will prompt for the sudo password (`BECOME password:`) because `ansible.cfg` has `become_ask_pass = True`. If your SSH user has passwordless sudo, set `become_ask_pass = False` in `ansible.cfg`.

---

## 6. Commit Phase 0

```bash
# Stage all files
git add .

# Verify no secrets are staged
git diff --cached -- '*.env' '*.key' '*.crt'  # should show nothing

# Commit
git commit -m "feat: Phase 0: repo setup, Ansible bootstrap, TDD framework

- Directory structure for all 6 phases
- .gitignore protecting .env, secrets, keys
- .env.example template with placeholder values
- Makefile with validate/lint/test/scan/ansible targets
- Pre-commit hooks (yamllint, gitleaks, shellcheck, helm-docs)
- TDD assertion library (scripts/assert.sh)
- Ansible playbook for node bootstrapping (aarch64-aware)
  - bootstrap-node: kernel modules, sysctl, swap off
- install-kubectl: version-pinned, idempotent
   - install-helm: version-pinned, idempotent
- Phase 0 test suite (62 assertions, all passing)
- ansible-lint production profile passing
- Architecture decisions documented (docs/architecture.md)
- Glossary (docs/glossary.md)"
```

---

## 7. What's Next

After Phase 0 is complete and committed, proceed to **Phase 1: K3s Cluster with Cilium**:

1. SSH into your server node (<CONTROL_PLANE_IP>) and install K3s
2. SSH into your agent node (<WORKER_IP>) and join it
3. Install Cilium CNI via `cilium install` CLI
4. Run `make test-phase1` to validate

See [PLAN.md](PLAN.md) §4 for Phase 1 details.

---

## 8. Phase 2: ArgoCD & GitOps Bootstrap

> **Prerequisite:** Phase 1 must be fully healthy.
> Verify: `cilium status` shows all OK, `kubectl get nodes` shows both Ready.

### Step 1: Install ArgoCD

```bash
# Add the Helm repo
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

# Install ArgoCD
kubectl create namespace argocd
helm install argocd argo/argo-cd \
  --namespace argocd \
  -f platform/argocd/values.yaml
```

### Step 2: Get Admin Password

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
echo  # newline after password
```

### Step 3: Access ArgoCD UI

```bash
# Port-forward for local access
kubectl port-forward -n argocd svc/argocd-server 8080:80 &
# Open http://localhost:8080
# Username: admin
# Password: (from step 2)
```

### Step 4: Bootstrap the GitOps Loop

```bash
# Apply the root Application (App-of-Apps pattern)
kubectl apply -f platform/argocd/bootstrap/argocd-app.yaml
```

This creates the `homelab-apps` root application, which points to
`platform/argocd/apps/`. ArgoCD will automatically sync everything in order:

| App | Purpose | Sync Wave |
|-----|---------|-----------|
| `platform-project` | Platform AppProject | -2 |
| `observability-project` | Observability AppProject | -2 |
| `applications-project` | Applications AppProject | -2 |
| `argocd` | ArgoCD self-managed | -1 |
| `metallb` | LoadBalancer controller | 0 |
| `metallb-config` | IP pool + L2 advertisement | 1 |
| `traefik` | Ingress controller | 1 |
| `cert-manager` | TLS certificate automation | 1 |

### Step 5: Validate

```bash
# Check all platform pods
kubectl get pods -n argocd
kubectl get pods -n metallb-system
kubectl get pods -n traefik
kubectl get pods -n cert-manager

# Check ArgoCD applications
kubectl get applications -n argocd

# Run Phase 2 test suite
make test-phase2
```

### Step 6: Commit Phase 2

```bash
git add .
git commit -m "feat: Phase 2: ArgoCD & GitOps bootstrap

- ArgoCD installed via Helm with production values
- App-of-Apps pattern: root app manages child apps
- ArgoCD self-managed (upgrades flow through Git)
- ArgoCD projects: platform, observability, applications
- MetalLB with IP pool and L2 advertisement
- Traefik ingress controller (replaces K3s built-in)
- cert-manager for TLS certificate automation
- Phase 2 test suite (ArgoCD, MetalLB, cert-manager)
- Phase 2 runbook with troubleshooting guide"
```

### Troubleshooting

See [docs/runbooks/phase2-argocd-gitops.md](docs/runbooks/phase2-argocd-gitops.md) for detailed troubleshooting.

Quick fixes:

```bash
# ArgoCD pods not ready
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server --tail=50

# MetalLB LoadBalancer stuck in Pending
kubectl get ipaddresspool -n metallb-system
kubectl logs -n metallb-system -l app.kubernetes.io/name=speaker --tail=50

# Traefik not routing
kubectl logs -n traefik -l app.kubernetes.io/name=traefik --tail=50

# cert-manager webhook issues (wait 60s for bootstrap)
kubectl get pods -n cert-manager
```

---

## 9. What's Next

After Phase 2 is complete, proceed to **Phase 3: Observability Stack**:

1. ArgoCD will auto-sync the observability project apps
2. Install kube-prometheus-stack (Prometheus + Grafana + Alertmanager)
3. Install Loki for log aggregation
4. Install OpenTelemetry Collector
5. Configure Grafana dashboards and datasources

See [PLAN.md](PLAN.md) §6 for Phase 3 details.

---

## Troubleshooting

### Ansible can't connect to nodes

```bash
# Test SSH connectivity manually
ssh root@<CONTROL_PLANE_IP> echo "OK"
ssh root@<WORKER_IP> echo "OK"

# If SSH key auth:
ssh-copy-id root@<CONTROL_PLANE_IP>
ssh-copy-id root@<WORKER_IP>

# Then test with Ansible
make ansible-ping
```

### "Host key verification failed" or "ssh_askpass" errors

This means SSH can't connect. Fix in order:

1. **Test SSH manually:** `ssh root@<CONTROL_PLANE_IP>`: does it work?
2. **Copy your SSH key:** `ssh-copy-id root@<CONTROL_PLANE_IP>`
3. **Or use password auth:** Install `sshpass` (`apt install sshpass`) and add `ansible_password` to each host in `ansible/inventory.yml`
4. **The inventory template already disables strict host checking** via `ansible_ssh_common_args`

### "BECOME password" prompt

This is expected: `ansible.cfg` has `become_ask_pass = True` so Ansible prompts for your sudo password. Enter the password for the `ansible_user` on the remote nodes.

If your SSH user has **passwordless sudo** (common for `root`), you can disable the prompt:
```ini
# In ansible.cfg, change:
become_ask_pass = False
```

### Locale warnings (LC_ALL)

The Makefile handles this automatically. If running Ansible directly:
```bash
export LC_ALL=C.UTF-8
ansible-playbook ansible/playbook.yml --ask-become-pass
```

### Pre-commit hooks not running

```bash
# Install hooks
pre-commit install

# Run manually on all files
pre-commit run --all-files
```

### "Host key verification failed" or "ssh_askpass" errors

This means SSH can't connect. Fix in order:

1. **Test SSH manually:** `ssh root@<CONTROL_PLANE_IP>`: does it work?
2. **Copy your SSH key:** `ssh-copy-id root@<CONTROL_PLANE_IP>`
3. **Or use password auth:** Install `sshpass` (`apt install sshpass`) and add `ansible_password` to inventory
4. **The inventory template already disables strict host checking** via `ansible_ssh_common_args`

### Locale warnings (LC_ALL)

If you see `warning: setlocale: LC_ALL: cannot change locale`, the Makefile handles this automatically. If running Ansible directly:

```bash
export LC_ALL=C.UTF-8
ansible-playbook ansible/playbook.yml --check
```
