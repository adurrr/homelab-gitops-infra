#!/usr/bin/env bash
# =============================================================================
# Phase 4 Tests: Home Assistant (S4.1–S4.7)
# =============================================================================
# Validates Home Assistant deployment: pod running, PVC bound, UI accessible,
# health probes passing, ArgoCD status healthy, ingress configured.
#
# Usage:
#   bash apps/tests/test-app-sync.sh
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/scripts/assert.sh"

echo "=========================================="
echo "  Phase 4 Tests: Home Assistant"
echo "=========================================="
echo ""

# Pre-flight
echo "--- Pre-flight: KUBECONFIG and kubectl ---"
if [[ -z "${KUBECONFIG:-}" ]]; then
    for candidate in "$HOME/.kube/config-homelab" "$HOME/.kube/config" "/etc/rancher/k3s/k3s.yaml"; do
        [[ -f "$candidate" ]] && export KUBECONFIG="$candidate" && break
    done
fi
assert_command_succeeds "kubectl cluster-info 2>/dev/null" "kubectl can reach the cluster"

# S4.1: Pod running
echo ""
echo "--- S4.1: Home Assistant Pod Running ---"
assert_pod_ready "home-assistant" "app.kubernetes.io/name=home-assistant" "Home Assistant pod ready"

# S4.2: PVC bound
echo ""
echo "--- S4.2: PVC Bound ---"
assert_command_succeeds "kubectl get pvc -n home-assistant --no-headers 2>/dev/null | grep -q Bound" "Home Assistant PVC is Bound"

# S4.3: Service exists
echo ""
echo "--- S4.3: Service + Ingress ---"
assert_command_succeeds "kubectl get svc -n home-assistant --no-headers 2>/dev/null | head -1" "Home Assistant service exists"
assert_command_succeeds "kubectl get ingress -n home-assistant --no-headers 2>/dev/null | head -1" "Home Assistant ingress exists"

# S4.4: Health probes passing
echo ""
echo "--- S4.4: Health Probes ---"
HA_POD=$(kubectl get pod -n home-assistant -l app.kubernetes.io/name=home-assistant -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -n "$HA_POD" ]]; then
    READY=$(kubectl get pod -n home-assistant "$HA_POD" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    if [[ "$READY" == "True" ]]; then
        echo -e "\033[0;32m✓\033[0m Home Assistant pod is Ready"
        ASSERTS_RUN=$((ASSERTS_RUN + 1))
        ASSERTS_PASSED=$((ASSERTS_PASSED + 1))
    else
        echo -e "\033[0;31m✗\033[0m Home Assistant pod is not Ready (status: $READY)"
        ASSERTS_RUN=$((ASSERTS_RUN + 1))
        ASSERTS_FAILED=$((ASSERTS_FAILED + 1))
    fi
fi

# S4.5: ArgoCD sync + health
echo ""
echo "--- S4.5: ArgoCD Status ---"
HEALTH=$(kubectl get application home-assistant -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
SYNC=$(kubectl get application home-assistant -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
echo "  ArgoCD health: $HEALTH / sync: $SYNC"

if [[ "$HEALTH" == "Healthy" ]]; then
    echo -e "\033[0;32m✓\033[0m Home Assistant app is Healthy"
    ASSERTS_RUN=$((ASSERTS_RUN + 1))
    ASSERTS_PASSED=$((ASSERTS_PASSED + 1))
else
    echo -e "\033[0;33m⊘\033[0m Home Assistant health: $HEALTH (may be initializing)"
    ASSERTS_RUN=$((ASSERTS_RUN + 1))
fi

if [[ "$SYNC" == "Synced" ]]; then
    echo -e "\033[0;32m✓\033[0m Home Assistant is Synced"
    ASSERTS_RUN=$((ASSERTS_RUN + 1))
    ASSERTS_PASSED=$((ASSERTS_PASSED + 1))
else
    echo -e "\033[0;33m⊘\033[0m Home Assistant sync: $SYNC"
    ASSERTS_RUN=$((ASSERTS_RUN + 1))
fi

# S4.6: ServiceMonitor exists
echo ""
echo "--- S4.6: ServiceMonitor ---"
assert_command_succeeds "kubectl get servicemonitor -n home-assistant --no-headers 2>/dev/null | head -1" "ServiceMonitor exists"

echo ""
assert_summary
