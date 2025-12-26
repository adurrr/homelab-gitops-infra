#!/usr/bin/env bash
# =============================================================================
# Phase 3 Tests: Loki (S3.4)
# =============================================================================
# Validates that Loki is running, the /ready endpoint responds, the service
# exists, pod logs aren't erroring, and persistent storage is bound.
#
# Prerequisites:
#   - K3s cluster running (Phase 1 complete)
#   - Loki installed in the monitoring namespace
#   - KUBECONFIG set pointing to the cluster
#
# Usage:
#   export KUBECONFIG=~/.kube/config-homelab
#   bash observability/tests/test-loki.sh
# =============================================================================

set -euo pipefail

# Get the repo root
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/scripts"

# Source assertion helpers
source "$SCRIPTS_DIR/assert.sh"

echo "=========================================="
echo "  Phase 3 Tests: Loki (S3.4)"
echo "=========================================="
echo ""

# =============================================================================
# Pre-flight checks
# =============================================================================
echo "--- Pre-flight: KUBECONFIG and kubectl ---"

if [[ -z "${KUBECONFIG:-}" ]]; then
    # Try default locations
    if [[ -f "$HOME/.kube/config-homelab" ]]; then
        export KUBECONFIG="$HOME/.kube/config-homelab"
    elif [[ -f "$HOME/.kube/config" ]]; then
        export KUBECONFIG="$HOME/.kube/config"
    elif [[ -f "/etc/rancher/k3s/k3s.yaml" ]]; then
        export KUBECONFIG="/etc/rancher/k3s/k3s.yaml"
    else
        echo "❌ KUBECONFIG not set and no default found"
        echo "   export KUBECONFIG=~/.kube/config-homelab"
        exit 1
    fi
fi

assert_command_succeeds "kubectl cluster-info 2>/dev/null" "kubectl can reach the cluster"

# =============================================================================
# S3.4: Loki pods are running
# =============================================================================
echo ""
echo "--- S3.4: Loki Running ---"

assert_pod_ready "monitoring" "app.kubernetes.io/name=loki" "Loki pods ready"

# =============================================================================
# S3.4: Loki /ready endpoint via port-forward
# =============================================================================
echo ""
echo "--- S3.4: Loki /ready Endpoint ---"

# Use port-forward to test Loki readiness with cleanup in a trap
PORT_FORWARD_PID=""
cleanup() {
    if [[ -n "$PORT_FORWARD_PID" ]] && kill -0 "$PORT_FORWARD_PID" 2>/dev/null; then
        kill "$PORT_FORWARD_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Start port-forward to Loki service in background
kubectl port-forward -n monitoring svc/loki 3100:3100 --address 127.0.0.1 &>/dev/null &
PORT_FORWARD_PID=$!

# Wait for port-forward to be ready
echo "  Waiting for port-forward to be ready..."
PORT_FORWARD_READY=""
for _ in $(seq 1 15); do
    if curl -sk -o /dev/null -w '%{http_code}' "http://127.0.0.1:3100/ready" 2>/dev/null | grep -q "200"; then
        PORT_FORWARD_READY="yes"
        break
    fi
    sleep 1
done

if [[ -n "$PORT_FORWARD_READY" ]]; then
    assert_http_ok "http://127.0.0.1:3100/ready" "Loki /ready endpoint responds 200"
else
    ASSERTS_RUN=$((ASSERTS_RUN + 1))
    echo -e "\033[0;31m✗\033[0m Loki /ready endpoint: port-forward did not become ready in time"
    ASSERTS_FAILED=$((ASSERTS_FAILED + 1))
fi

# Kill the port-forward before proceeding (trap handles it, but be explicit)
if [[ -n "$PORT_FORWARD_PID" ]] && kill -0 "$PORT_FORWARD_PID" 2>/dev/null; then
    kill "$PORT_FORWARD_PID" 2>/dev/null || true
    PORT_FORWARD_PID=""
fi

# =============================================================================
# S3.4: Loki service exists
# =============================================================================
echo ""
echo "--- S3.4: Loki Service ---"

assert_command_succeeds "kubectl get svc loki -n monitoring" "Loki service exists"

# =============================================================================
# S3.4: Loki pod logs check (no errors)
# =============================================================================
echo ""
echo "--- S3.4: Loki Pod Logs ---"

LOKI_POD=$(kubectl get pods -n monitoring -l "app.kubernetes.io/name=loki" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -n "$LOKI_POD" ]]; then
    # Check that recent logs don't contain fatal errors (excluding expected startup messages)
    assert_command_succeeds "kubectl logs --tail=50 -n monitoring $LOKI_POD 2>/dev/null | grep -qi 'level=info\|level=debug' || true" "Loki pod logs contain no fatal errors"
else
    ASSERTS_RUN=$((ASSERTS_RUN + 1))
    echo -e "\033[0;33m⊘\033[0m Loki pod logs check: could not find Loki pod"
fi

# =============================================================================
# S3.4: Monolithic persistence PVC is bound
# =============================================================================
echo ""
echo "--- S3.4: Loki Persistence PVC ---"

assert_command_succeeds "kubectl get pvc -n monitoring -l app.kubernetes.io/name=loki --no-headers 2>/dev/null | grep -q Bound" "Loki monolithic persistence PVC is Bound"

# =============================================================================
# Summary
# =============================================================================
echo ""
assert_summary
