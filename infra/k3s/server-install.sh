#!/usr/bin/env bash
# =============================================================================
# K3s Server Installation Script
# =============================================================================
# Installs K3s on the server (control plane) node via SSH.
#
# Prerequisites:
#   - SSH access to the server node (password or key)
#   - Passwordless sudo on the target node (see below)
#   - Run `make ansible-bootstrap` first (kernel modules, sysctl, swap off)
#   - Set K3S_SERVER_HOST, K3S_SERVER_IP, K3S_TOKEN in infra/.env
#
# Passwordless sudo setup (run once on each node):
#   ssh server 'echo "youruser ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/youruser'
#
# Usage:
#   source infra/.env && bash infra/k3s/server-install.sh
#   source infra/.env && bash infra/k3s/server-install.sh --force   # Uninstall first
#
# Idempotent: Skips if already installed (use --force to reinstall).
# =============================================================================

set -euo pipefail

FORCE=false
if [[ "${1:-}" == "--force" ]]; then
    FORCE=true
fi

# ---------------------------------------------------------------------------
# Load environment variables
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="$REPO_ROOT/infra/.env"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "❌ Missing $ENV_FILE"
    echo "   cp infra/env.example infra/.env"
    echo "   vim infra/.env  # Fill in your real values"
    exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

# ---------------------------------------------------------------------------
# Validate required variables
# ---------------------------------------------------------------------------
if [[ -z "${K3S_SERVER_HOST:-}" ]]; then
    echo "❌ K3S_SERVER_HOST is not set in $ENV_FILE"
    exit 1
fi

if [[ -z "${K3S_SERVER_IP:-}" ]]; then
    echo "❌ K3S_SERVER_IP is not set in $ENV_FILE"
    exit 1
fi

if [[ -z "${K3S_TOKEN:-}" || "${K3S_TOKEN}" == CHANGE_ME* ]]; then
    echo "❌ K3S_TOKEN is not set in $ENV_FILE"
    echo "   Generate one with: openssl rand -hex 32"
    exit 1
fi

SSH_TARGET="${K3S_SERVER_HOST}"

echo "=========================================="
echo "  Installing K3s Server on ${SSH_TARGET}"
echo "=========================================="
echo ""
echo "  Server host:  ${K3S_SERVER_HOST}"
echo "  Server IP:     ${K3S_SERVER_IP}"
echo "  Token:         ******** (from K3S_TOKEN)"
echo ""
echo "  Flags:"
echo "    --flannel-backend=none      (Cilium replaces flannel)"
echo "    --disable-network-policy    (Cilium provides network policy)"
echo "    --disable traefik           (ArgoCD will manage ingress)"
echo "    --disable-kube-proxy       (Cilium replaces kube-proxy)"
echo "    --disable metrics-server   (managed via ArgoCD in Phase 2)"
echo "    --write-kubeconfig-mode=644 (allows copying kubeconfig)"
echo ""

# ---------------------------------------------------------------------------
# Test SSH connectivity
# ---------------------------------------------------------------------------
echo "  Testing SSH connectivity to ${SSH_TARGET}..."
if ! ssh -o ConnectTimeout=5 "${SSH_TARGET}" "echo 'SSH OK'" 2>/dev/null; then
    echo "❌ Cannot SSH into ${SSH_TARGET}"
    echo ""
    echo "  Troubleshooting:"
    echo "    1. Can you ping it?  ping -c 3 ${K3S_SERVER_IP}"
    echo "    2. SSH key set up?   ssh-copy-id ${SSH_TARGET}"
    echo "    3. Try with IP:      ssh ${K3S_SERVER_IP}"
    echo ""
    echo "  If your SSH user differs from the hostname, set it in ~/.ssh/config"
    exit 1
fi
echo "  ✅ SSH connection OK"

# ---------------------------------------------------------------------------
# Check passwordless sudo
# ---------------------------------------------------------------------------
echo "  Checking passwordless sudo on ${SSH_TARGET}..."
if ! ssh "${SSH_TARGET}" "sudo -n true" 2>/dev/null; then
    echo ""
    echo "❌ Passwordless sudo is not configured on ${SSH_TARGET}"
    echo ""
    echo "  The K3s installer requires sudo without a password prompt."
    echo "  Set up passwordless sudo by running this command:"
    echo ""
    echo "    ssh ${SSH_TARGET} 'echo \"\$(whoami) ALL=(ALL) NOPASSWD:ALL\" | sudo tee /etc/sudoers.d/\$(whoami)'"
    echo ""
    echo "  Or if you prefer to enter your password each time, run the"
    echo "  K3s install manually on the server node:"
    echo ""
    echo "    ssh -t ${SSH_TARGET}"
    echo "    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='server \\"
    echo "      --flannel-backend=none --disable-network-policy --disable traefik \\"
    echo "      --disable-kube-proxy --disable metrics-server \\"
    echo "      --token=${K3S_TOKEN} --tls-san=${K3S_SERVER_IP} \\"
    echo "      --write-kubeconfig-mode=644' sh -"
    echo ""
    exit 1
fi
echo "  ✅ Passwordless sudo OK"

# ---------------------------------------------------------------------------
# Handle existing installation
# ---------------------------------------------------------------------------
if ssh "${SSH_TARGET}" "command -v k3s &>/dev/null && test -f /etc/rancher/k3s/k3s.yaml" 2>/dev/null; then
    if [[ "$FORCE" == "true" ]]; then
        echo "  ⚠️  --force flag set: uninstalling existing K3s server..."
        ssh "${SSH_TARGET}" "sudo /usr/local/bin/k3s-uninstall.sh" 2>/dev/null || true
        echo "  ✅ K3s server uninstalled"
    else
        echo "ℹ️  K3s is already installed on ${SSH_TARGET}"
        echo "   Current version: $(ssh "${SSH_TARGET}" "k3s --version" 2>/dev/null || echo 'unknown')"
        echo ""
        echo "   To check status:"
        echo "     ssh ${SSH_TARGET} 'systemctl status k3s'"
        echo ""
        echo "   To reinstall, run:"
        echo "     bash infra/k3s/server-install.sh --force"
        echo ""
        echo "   Or uninstall manually:"
        echo "     ssh ${SSH_TARGET} 'sudo /usr/local/bin/k3s-uninstall.sh'"
        exit 0
    fi
fi

# ---------------------------------------------------------------------------
# Install K3s server via SSH
# ---------------------------------------------------------------------------
echo "  Installing K3s server on ${SSH_TARGET}..."
echo "  (This may take a minute: downloading and installing K3s)"
echo ""

ssh "${SSH_TARGET}" "curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='server \
  --flannel-backend=none \
  --disable-network-policy \
  --disable traefik \
  --disable-kube-proxy \
  --disable metrics-server \
  --token=${K3S_TOKEN} \
  --tls-san=${K3S_SERVER_IP} \
  --write-kubeconfig-mode=644' sh -"

# ---------------------------------------------------------------------------
# Verify installation
# ---------------------------------------------------------------------------
echo ""
echo "=========================================="
echo "  K3s Server Installation Complete"
echo "=========================================="
echo ""

K3S_VERSION=$(ssh "${SSH_TARGET}" "k3s --version" 2>/dev/null || echo "unknown")
echo "  ✅ K3s version: ${K3S_VERSION}"

# Wait for node to be ready
echo ""
echo "  Waiting for node to be ready..."
RETRIES=30
READY=false
for _ in $(seq 1 "$RETRIES"); do
    if ssh "${SSH_TARGET}" "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl get nodes -o jsonpath='{.items[0].status.conditions[?(@.type==\"Ready\")].status}'" 2>/dev/null | grep -q "True"; then
        READY=true
        break
    fi
    echo "  ... waiting"
    sleep 5
done

if [[ "$READY" == "true" ]]; then
    echo "  ✅ Node is Ready"
else
    echo "  ⚠️  Node not ready after ${RETRIES} retries"
    echo "     Check: ssh ${SSH_TARGET} 'KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl get nodes'"
fi

echo ""
echo "  Next steps:"
echo "  1. Copy kubeconfig to your admin machine:"
echo "     scp ${SSH_TARGET}:/etc/rancher/k3s/k3s.yaml ~/.kube/config-homelab"
echo "     sed -i 's/127.0.0.1/${K3S_SERVER_IP}/g' ~/.kube/config-homelab"
echo ""
echo "  2. Install K3s agent on worker node:"
echo "     source infra/.env && bash infra/k3s/agent-install.sh"
echo ""
echo "  3. Install Cilium CNI:"
echo "     make cilium-install"
