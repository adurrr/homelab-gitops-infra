#!/usr/bin/env bash
# =============================================================================
# K3s Agent Installation Script
# =============================================================================
# Installs K3s agent on the worker node via SSH and joins it to the server cluster.
#
# Prerequisites:
#   - SSH access to the agent node (password or key)
#   - Passwordless sudo on the target node (see below)
#   - K3s server must already be running on the server node
#   - Run `make ansible-bootstrap` first (kernel modules, sysctl, swap off)
#   - Set K3S_SERVER_HOST, K3S_SERVER_IP, K3S_AGENT_HOST, K3S_TOKEN in infra/.env
#
# Passwordless sudo setup (run once on each node):
#   ssh agent 'echo "youruser ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/youruser'
#
# Usage:
#   source infra/.env && bash infra/k3s/agent-install.sh
#   source infra/.env && bash infra/k3s/agent-install.sh --force   # Uninstall first
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
if [[ -z "${K3S_SERVER_IP:-}" ]]; then
    echo "❌ K3S_SERVER_IP is not set in $ENV_FILE"
    exit 1
fi

if [[ -z "${K3S_AGENT_HOST:-}" ]]; then
    echo "❌ K3S_AGENT_HOST is not set in $ENV_FILE"
    exit 1
fi

if [[ -z "${K3S_TOKEN:-}" || "${K3S_TOKEN}" == CHANGE_ME* ]]; then
    echo "❌ K3S_TOKEN is not set in $ENV_FILE"
    echo ""
    echo "   Get the token from the SERVER node:"
    echo "   ssh ${K3S_SERVER_HOST:-$K3S_SERVER_IP} 'sudo cat /var/lib/rancher/k3s/server/node-token'"
    echo ""
    echo "   Then set it in infra/.env:"
    echo "   K3S_TOKEN=<token_from_server>"
    exit 1
fi

SSH_TARGET="${K3S_AGENT_HOST}"

echo "=========================================="
echo "  Installing K3s Agent on ${SSH_TARGET}"
echo "=========================================="
echo ""
echo "  Agent host:    ${K3S_AGENT_HOST}"
echo "  Server URL:    https://${K3S_SERVER_IP}:6443"
echo "  Token:         ******** (from K3S_TOKEN)"
echo ""

# ---------------------------------------------------------------------------
# Test SSH connectivity to agent
# ---------------------------------------------------------------------------
echo "  Testing SSH connectivity to ${SSH_TARGET}..."
if ! ssh -o ConnectTimeout=5 "${SSH_TARGET}" "echo 'SSH OK'" 2>/dev/null; then
    echo "❌ Cannot SSH into ${SSH_TARGET}"
    echo ""
    echo "  Troubleshooting:"
    echo "    1. Can you ping it?  ping -c 3 ${K3S_AGENT_IP:-${K3S_AGENT_HOST}}"
    echo "    2. SSH key set up?   ssh-copy-id ${SSH_TARGET}"
    echo "    3. Try with IP:      ssh ${K3S_AGENT_IP:-${K3S_AGENT_HOST}}"
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
    echo "  K3s install manually on the agent node:"
    echo ""
    echo "    ssh -t ${SSH_TARGET}"
    echo "    curl -sfL https://get.k3s.io | K3S_URL='https://${K3S_SERVER_IP}:6443' \\"
    echo "      K3S_TOKEN='${K3S_TOKEN}' sh -"
    echo ""
    exit 1
fi
echo "  ✅ Passwordless sudo OK"

# ---------------------------------------------------------------------------
# Verify server is reachable from agent
# ---------------------------------------------------------------------------
echo "  Checking server connectivity from agent..."
if ! ssh "${SSH_TARGET}" "curl -sk --max-time 5 https://${K3S_SERVER_IP}:6443" &>/dev/null; then
    echo "  ⚠️  Agent cannot reach K3s server at https://${K3S_SERVER_IP}:6443"
    echo "     Make sure the server node is running K3s before joining the agent."
    echo ""
    echo "  Troubleshooting:"
    echo "    1. Is the server running?  ssh ${K3S_SERVER_HOST:-$K3S_SERVER_IP} 'systemctl status k3s'"
    echo "    2. Is port 6443 open?        ssh ${K3S_SERVER_HOST:-$K3S_SERVER_IP} 'ss -tlnp | grep 6443'"
    echo "    3. Firewall blocking?        ssh ${K3S_SERVER_HOST:-$K3S_SERVER_IP} 'sudo ufw status'"
    echo ""
    read -rp "  Continue anyway? (y/N) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Handle existing installation on agent
# ---------------------------------------------------------------------------
if ssh "${SSH_TARGET}" "test -d /var/lib/rancher/k3s/agent" 2>/dev/null; then
    if [[ "$FORCE" == "true" ]]; then
        echo "  ⚠️  --force flag set: uninstalling existing K3s agent..."
        ssh "${SSH_TARGET}" "sudo /usr/local/bin/k3s-agent-uninstall.sh" 2>/dev/null || {
            echo "  ⚠️  Uninstall script not found, cleaning up manually..."
            ssh "${SSH_TARGET}" bash -s <<'REMOTE_CLEANUP'
                sudo systemctl stop k3s-agent 2>/dev/null || true
                sudo systemctl disable k3s-agent 2>/dev/null || true
                sudo rm -f /etc/systemd/system/k3s-agent.service
                sudo systemctl daemon-reload
                sudo rm -rf /var/lib/rancher/k3s/agent
                sudo rm -rf /etc/rancher/k3s
REMOTE_CLEANUP
            echo "  ✅ Manual cleanup done"
        }
        echo "  ✅ K3s agent uninstalled"
    else
        echo "ℹ️  K3s agent is already installed on ${SSH_TARGET}"
        echo ""
        echo "   To check status:"
        echo "     ssh ${SSH_TARGET} 'systemctl status k3s-agent'"
        echo "     ssh ${SSH_TARGET} 'journalctl -u k3s-agent -n 50 --no-pager'"
        echo ""
        echo "   To reinstall, run:"
        echo "     bash infra/k3s/agent-install.sh --force"
        echo ""
        echo "   Or uninstall manually:"
        echo "     ssh ${SSH_TARGET} 'sudo /usr/local/bin/k3s-agent-uninstall.sh'"
        exit 0
    fi
fi

# ---------------------------------------------------------------------------
# Install K3s agent via SSH
# ---------------------------------------------------------------------------
echo "  Installing K3s agent on ${SSH_TARGET}..."
echo "  (This may take a minute: downloading and installing K3s)"
echo ""

ssh "${SSH_TARGET}" "curl -sfL https://get.k3s.io | K3S_URL='https://${K3S_SERVER_IP}:6443' K3S_TOKEN='${K3S_TOKEN}' sh -"

# ---------------------------------------------------------------------------
# Verify installation
# ---------------------------------------------------------------------------
echo ""
echo "=========================================="
echo "  K3s Agent Installation Complete"
echo "=========================================="
echo ""

if ssh "${SSH_TARGET}" "test -d /var/lib/rancher/k3s/agent" 2>/dev/null; then
    echo "  ✅ K3s agent installed on ${SSH_TARGET}"
else
    echo "  ❌ K3s agent directory not found: installation may have failed"
    echo "     Check logs: ssh ${SSH_TARGET} 'journalctl -u k3s-agent -n 50 --no-pager'"
    exit 1
fi

# Wait for agent to register with server
echo ""
echo "  Waiting for agent to register with server..."
sleep 10

# Check service status on agent
if ssh "${SSH_TARGET}" "systemctl is-active --quiet k3s-agent" 2>/dev/null; then
    echo "  ✅ k3s-agent service is running on ${SSH_TARGET}"
else
    echo "  ⚠️  k3s-agent service is not running on ${SSH_TARGET}"
    echo "     Check logs: ssh ${SSH_TARGET} 'journalctl -u k3s-agent -n 50 --no-pager'"
    echo ""
    echo "  Common issues:"
    echo "    - Wrong K3S_TOKEN: get it from server:"
    echo "      ssh ${K3S_SERVER_HOST:-$K3S_SERVER_IP} 'sudo cat /var/lib/rancher/k3s/server/node-token'"
    echo "    - Server not reachable from agent"
    echo "    - Node name conflict: if server was reinstalled, token changed"
fi

echo ""
echo "  Verify from your admin machine:"
echo "    export KUBECONFIG=~/.kube/config-homelab"
echo "    kubectl get nodes"
echo ""
echo "  If the agent doesn't appear, check:"
echo "    1. On agent:  ssh ${SSH_TARGET} 'journalctl -u k3s-agent -n 100 --no-pager'"
echo "    2. On server:  ssh ${K3S_SERVER_HOST:-$K3S_SERVER_IP} 'journalctl -u k3s -n 100 --no-pager'"
echo "    3. Token mismatch? Get server token:"
echo "       ssh ${K3S_SERVER_HOST:-$K3S_SERVER_IP} 'sudo cat /var/lib/rancher/k3s/server/node-token'"
echo ""
echo "  Next step: Install Cilium CNI"
echo "    make cilium-install"
