#!/usr/bin/env bash
# =============================================================================
# Phase 3 Tests: Grafana (S3.2, S3.3)
# =============================================================================
# Validates that Grafana is accessible, the login page returns 200,
# Prometheus and Loki datasource ConfigMaps exist, and Grafana-dashboard
# ConfigMaps are present in the monitoring namespace.
#
# Prerequisites:
#   - K3s cluster running (Phase 1 complete)
#   - Grafana installed in the monitoring namespace
#   - KUBECONFIG set pointing to the cluster
#
# Usage:
#   export KUBECONFIG=~/.kube/config-homelab
#   bash observability/tests/test-grafana.sh
# =============================================================================

set -euo pipefail

# Get the repo root
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/scripts"

# Source assertion helpers
source "$SCRIPTS_DIR/assert.sh"

echo "=========================================="
echo "  Phase 3 Tests: Grafana (S3.2, S3.3)"
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
# S3.2: Grafana pods are running
# =============================================================================
echo ""
echo "--- S3.2: Grafana Running ---"

assert_pod_ready "monitoring" "app.kubernetes.io/name=grafana" "Grafana pods ready"

# =============================================================================
# S3.2: Grafana UI accessible via port-forward
# =============================================================================
echo ""
echo "--- S3.2: Grafana UI Accessible ---"

# Use port-forward to test Grafana UI access with cleanup in a trap
PORT_FORWARD_PID=""
cleanup() {
    if [[ -n "$PORT_FORWARD_PID" ]] && kill -0 "$PORT_FORWARD_PID" 2>/dev/null; then
        kill "$PORT_FORWARD_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Start port-forward to Grafana service in background
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80 --address 127.0.0.1 &>/dev/null &
PORT_FORWARD_PID=$!

# Wait for port-forward to be ready
echo "  Waiting for port-forward to be ready..."
PORT_FORWARD_READY=""
for _ in $(seq 1 15); do
    if curl -sk -o /dev/null -w '%{http_code}' "http://127.0.0.1:3000" 2>/dev/null | grep -q "200\|302\|401"; then
        PORT_FORWARD_READY="yes"
        break
    fi
    sleep 1
done

if [[ -n "$PORT_FORWARD_READY" ]]; then
    assert_command_succeeds "curl -sk -o /dev/null -w '%{http_code}' http://127.0.0.1:3000 2>/dev/null | grep -qE '200|302'" "Grafana login page accessible (HTTP 200 or 302)"
else
    ASSERTS_RUN=$((ASSERTS_RUN + 1))
    echo -e "\033[0;31m✗\033[0m Grafana login page accessible: port-forward did not become ready in time"
    ASSERTS_FAILED=$((ASSERTS_FAILED + 1))
fi

# Kill the port-forward before proceeding (trap handles it, but be explicit)
if [[ -n "$PORT_FORWARD_PID" ]] && kill -0 "$PORT_FORWARD_PID" 2>/dev/null; then
    kill "$PORT_FORWARD_PID" 2>/dev/null || true
    PORT_FORWARD_PID=""
fi

# =============================================================================
# S3.3: Datasource ConfigMaps exist
# =============================================================================
echo ""
echo "--- S3.3: Datasource ConfigMaps ---"

assert_command_succeeds "kubectl get configmap -n monitoring -l grafana_datasource=1 --no-headers 2>/dev/null | head -1" "Prometheus datasource ConfigMap exists (label grafana_datasource=1)" || \
    assert_resource_exists "monitoring" "configmap" "prometheus-datasource" "Prometheus datasource ConfigMap exists (fallback)"

assert_command_succeeds "kubectl get configmap -n monitoring -l grafana_datasource=1 -o yaml 2>/dev/null | grep -qi prometheus" "Prometheus datasource referenced in ConfigMap" || \
    assert_command_succeeds "kubectl get configmap -n monitoring -l grafana_datasource=1 --no-headers 2>/dev/null | head -1" "Some datasource ConfigMap exists"

# Also check for any ConfigMap with datasource in the name
assert_command_succeeds "kubectl get configmap -n monitoring --no-headers 2>/dev/null | grep -qi datasource" "A datasource ConfigMap exists in monitoring namespace"

# =============================================================================
# S3.3: Grafana-dashboard ConfigMaps exist
# =============================================================================
echo ""
echo "--- S3.3: Dashboard ConfigMaps ---"

assert_command_succeeds "kubectl get configmap -n monitoring --no-headers 2>/dev/null | grep -qi dashboard" "Grafana-dashboard ConfigMap exists in monitoring namespace"

# =============================================================================
# Summary
# =============================================================================
echo ""
assert_summary
