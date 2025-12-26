#!/usr/bin/env bash
# =============================================================================
# Phase 3 Tests: Prometheus (S3.1, S3.6)
# =============================================================================
# Validates that Prometheus is installed, pods are running, the API is healthy,
# Prometheus CRDs exist (prometheuses.monitoring.coreos.com, servicemonitors),
# and that the prometheus-operated service exists.
#
# Prerequisites:
#   - K3s cluster running (Phase 1 complete)
#   - Prometheus stack installed in the monitoring namespace
#   - KUBECONFIG set pointing to the cluster
#
# Usage:
#   export KUBECONFIG=~/.kube/config-homelab
#   bash observability/tests/test-prometheus.sh
# =============================================================================

set -euo pipefail

# Get the repo root
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/scripts"

# Source assertion helpers
source "$SCRIPTS_DIR/assert.sh"

echo "=========================================="
echo "  Phase 3 Tests: Prometheus (S3.1, S3.6)"
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
# S3.1: Prometheus pods are running
# =============================================================================
echo ""
echo "--- S3.1: Prometheus Running ---"

assert_pod_ready "monitoring" "app.kubernetes.io/name=prometheus" "Prometheus pods ready"
assert_pod_ready "monitoring" "app.kubernetes.io/name=grafana" "Grafana pods ready"
assert_pod_ready "monitoring" "app.kubernetes.io/name=alertmanager" "Alertmanager pods ready"

# =============================================================================
# S3.1: Prometheus API is healthy (via port-forward)
# =============================================================================
echo ""
echo "--- S3.1: Prometheus API Health Check ---"

# Use port-forward to test Prometheus health with cleanup in a trap
PORT_FORWARD_PID=""
cleanup() {
    if [[ -n "$PORT_FORWARD_PID" ]] && kill -0 "$PORT_FORWARD_PID" 2>/dev/null; then
        kill "$PORT_FORWARD_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Start port-forward to Prometheus service in background
kubectl port-forward -n monitoring svc/prometheus-operated 9090:9090 --address 127.0.0.1 &>/dev/null &
PORT_FORWARD_PID=$!

# Wait for port-forward to be ready
echo "  Waiting for port-forward to be ready..."
PORT_FORWARD_READY=""
for _ in $(seq 1 15); do
    if curl -sk -o /dev/null -w '%{http_code}' "http://127.0.0.1:9090/-/healthy" 2>/dev/null | grep -q "200"; then
        PORT_FORWARD_READY="yes"
        break
    fi
    sleep 1
done

if [[ -n "$PORT_FORWARD_READY" ]]; then
    assert_http_ok "http://127.0.0.1:9090/-/healthy" "Prometheus API healthy"
else
    ASSERTS_RUN=$((ASSERTS_RUN + 1))
    echo -e "\033[0;31m✗\033[0m Prometheus API healthy: port-forward did not become ready in time"
    ASSERTS_FAILED=$((ASSERTS_FAILED + 1))
fi

# Kill the port-forward before proceeding (trap handles it, but be explicit)
if [[ -n "$PORT_FORWARD_PID" ]] && kill -0 "$PORT_FORWARD_PID" 2>/dev/null; then
    kill "$PORT_FORWARD_PID" 2>/dev/null || true
    PORT_FORWARD_PID=""
fi

# =============================================================================
# S3.1: Prometheus-operated service exists
# =============================================================================
echo ""
echo "--- S3.1: Prometheus-operated Service ---"

assert_command_succeeds "kubectl get svc prometheus-operated -n monitoring" "prometheus-operated service exists"

# =============================================================================
# S3.6: Prometheus CRDs exist
# =============================================================================
echo ""
echo "--- S3.6: Prometheus CRDs ---"

assert_command_succeeds "kubectl get crd prometheuses.monitoring.coreos.com" "CRD prometheuses.monitoring.coreos.com exists"
assert_command_succeeds "kubectl get crd servicemonitors.monitoring.coreos.com" "CRD servicemonitors.monitoring.coreos.com exists"

# =============================================================================
# Summary
# =============================================================================
echo ""
assert_summary
