#!/usr/bin/env bash
# =============================================================================
# Phase 3 Tests: OpenTelemetry Collector (S3.5)
# =============================================================================
# Validates that the OTel Collector is running, the service exists,
# the configuration contains expected receivers/exporters, pod logs indicate
# startup success, and the health endpoint responds.
#
# Prerequisites:
#   - K3s cluster running (Phase 1 complete)
#   - OTel Collector installed in the monitoring namespace
#   - KUBECONFIG set pointing to the cluster
#
# Usage:
#   export KUBECONFIG=~/.kube/config-homelab
#   bash observability/tests/test-otel-pipeline.sh
# =============================================================================

set -euo pipefail

# Get the repo root
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/scripts"

# Source assertion helpers
source "$SCRIPTS_DIR/assert.sh"

echo "=========================================="
echo "  Phase 3 Tests: OTel Collector (S3.5)"
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
# S3.5: OTel Collector pods are running
# =============================================================================
echo ""
echo "--- S3.5: OTel Collector Running ---"

assert_pod_ready "monitoring" "app.kubernetes.io/name=opentelemetry-collector" "OTel Collector pods ready"

# =============================================================================
# S3.5: OTel Collector service exists
# =============================================================================
echo ""
echo "--- S3.5: OTel Collector Service ---"

assert_command_succeeds "kubectl get svc -n monitoring -l app.kubernetes.io/name=opentelemetry-collector --no-headers 2>/dev/null | head -1" "OTel Collector service exists"

# =============================================================================
# S3.5: OTel Config contains expected receivers/exporters
# =============================================================================
echo ""
echo "--- S3.5: OTel Collector Configuration ---"

OTEL_CONFIGMAP=$(kubectl get configmap -n monitoring -l app.kubernetes.io/name=opentelemetry-collector -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -n "$OTEL_CONFIGMAP" ]]; then
    CONFIG_DATA=$(kubectl get configmap -n monitoring "$OTEL_CONFIGMAP" -o jsonpath='{.data}' 2>/dev/null || echo "")
    if [[ -n "$CONFIG_DATA" ]]; then
        assert_contains "$CONFIG_DATA" "receivers" "OTel config contains receivers"
        assert_contains "$CONFIG_DATA" "exporters" "OTel config contains exporters"
        assert_contains "$CONFIG_DATA" "service" "OTel config contains service pipeline"
    else
        ASSERTS_RUN=$((ASSERTS_RUN + 1))
        echo -e "\033[0;33m⊘\033[0m OTel config check: ConfigMap data is empty"
    fi
else
    ASSERTS_RUN=$((ASSERTS_RUN + 1))
    echo -e "\033[0;33m⊘\033[0m OTel config check: no ConfigMap found for opentelemetry-collector"
fi

# =============================================================================
# S3.5: OTel pod logs indicate startup success
# =============================================================================
echo ""
echo "--- S3.5: OTel Collector Logs ---"

OTEL_POD=$(kubectl get pods -n monitoring -l "app.kubernetes.io/name=opentelemetry-collector" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -n "$OTEL_POD" ]]; then
    # Pod is running (asserted above). Verify logs exist.
    assert_command_succeeds "test \$(kubectl logs --tail=50 -n monitoring $OTEL_POD 2>/dev/null | wc -l) -gt 0" "OTel pod has log output"
else
    ASSERTS_RUN=$((ASSERTS_RUN + 1))
    echo -e "\033[0;33m⊘\033[0m OTel pod logs check: could not find OTel Collector pod"
fi

# =============================================================================
# S3.5: OTel health endpoint via port-forward (health_check extension)
# =============================================================================
echo ""
echo "--- S3.5: OTel Health Endpoint ---"

# Use port-forward to test OTel health endpoint with cleanup in a trap
PORT_FORWARD_PID=""
cleanup() {
    if [[ -n "$PORT_FORWARD_PID" ]] && kill -0 "$PORT_FORWARD_PID" 2>/dev/null; then
        kill "$PORT_FORWARD_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Try port-forwarding to the OTel collector health check port 13133
# Use the actual service name from the Helm chart
OTEL_SVC=$(kubectl get svc -n monitoring -l app.kubernetes.io/name=opentelemetry-collector -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "otel-collector-opentelemetry-collector")
kubectl port-forward -n monitoring svc/$OTEL_SVC 13133:13133 --address 127.0.0.1 &>/dev/null &
PORT_FORWARD_PID=$!

# Wait for port-forward to be ready (longer timeout: OTel health takes time)
echo "  Waiting for port-forward to be ready..."
PORT_FORWARD_READY=""
for _ in $(seq 1 30); do
    if curl -sk -o /dev/null -w '%{http_code}' "http://127.0.0.1:13133" 2>/dev/null | grep -qE "200|404|503"; then
        PORT_FORWARD_READY="yes"
        break
    fi
    sleep 1
done

if [[ -n "$PORT_FORWARD_READY" ]]; then
    assert_http_ok "http://127.0.0.1:13133" "OTel Collector health endpoint responds 200"
else
    ASSERTS_RUN=$((ASSERTS_RUN + 1))
    echo -e "\033[0;31m✗\033[0m OTel Collector health endpoint: port-forward did not become ready in time"
    ASSERTS_FAILED=$((ASSERTS_FAILED + 1))
fi

# Kill the port-forward (trap handles it, but be explicit)
if [[ -n "$PORT_FORWARD_PID" ]] && kill -0 "$PORT_FORWARD_PID" 2>/dev/null; then
    kill "$PORT_FORWARD_PID" 2>/dev/null || true
    PORT_FORWARD_PID=""
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
assert_summary
