#!/usr/bin/env bash
# =============================================================================
# Phase 2 Tests: MetalLB IP Pool Configuration
# =============================================================================
# Validates that MetalLB is running, the IP pool is configured, L2
# advertisement exists, and the IP range is properly set.
#
# Prerequisites:
#   - K3s cluster running (Phase 1 complete)
#   - MetalLB installed in the metallb-system namespace
#   - KUBECONFIG set pointing to the cluster
#
# Usage:
#   export KUBECONFIG=~/.kube/config-homelab
#   bash platform/tests/test-metallb.sh
# =============================================================================

set -euo pipefail

# Get the repo root
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/scripts"

# Source assertion helpers
source "$SCRIPTS_DIR/assert.sh"

echo "=========================================="
echo "  Phase 2 Tests: MetalLB IP Pool"
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
# S2.6: MetalLB IP pool configured
# =============================================================================
echo ""
echo "--- S2.6: MetalLB IP Pool ---"

# Check MetalLB controller pods are running
assert_pod_ready "metallb-system" "app.kubernetes.io/name=metallb" "MetalLB controller ready"

# Check MetalLB speaker pods are running
assert_pod_ready "metallb-system" "app.kubernetes.io/name=speaker" "MetalLB speaker ready"

# Check IPAddressPool exists
assert_resource_exists "metallb-system" "IPAddressPool" "homelab-pool" "MetalLB IP pool exists"

# Check L2Advertisement exists
assert_resource_exists "metallb-system" "L2Advertisement" "homelab-l2" "MetalLB L2 advertisement exists"

# Check IP range is configured
echo ""
echo "--- S2.6: MetalLB IP Range ---"

IP_RANGE=$(kubectl get ipaddresspool homelab-pool -n metallb-system -o jsonpath='{.spec.addresses[0]}' 2>/dev/null || echo "")
if [[ -n "$IP_RANGE" ]]; then
    assert_contains "$IP_RANGE" "-" "MetalLB IP range uses dash-separated format (got: $IP_RANGE)"
    assert_contains "$IP_RANGE" "." "MetalLB IP range contains valid IP addresses (got: $IP_RANGE)"
else
    ASSERTS_RUN=$((ASSERTS_RUN + 1))
    echo -e "\033[0;31m✗\033[0m MetalLB IP range: could not retrieve IPAddressPool addresses"
    ASSERTS_FAILED=$((ASSERTS_FAILED + 1))
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
assert_summary
