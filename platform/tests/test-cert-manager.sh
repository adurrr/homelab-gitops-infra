#!/usr/bin/env bash
# =============================================================================
# Phase 2 Tests: cert-manager Readiness
# =============================================================================
# Validates that cert-manager is installed, pods are running, CRDs are
# available, and the webhook and cainjector components are healthy.
#
# Prerequisites:
#   - K3s cluster running (Phase 1 complete)
#   - cert-manager installed in the cert-manager namespace
#   - KUBECONFIG set pointing to the cluster
#
# Usage:
#   export KUBECONFIG=~/.kube/config-homelab
#   bash platform/tests/test-cert-manager.sh
# =============================================================================

set -euo pipefail

# Get the repo root
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/scripts"

# Source assertion helpers
source "$SCRIPTS_DIR/assert.sh"

echo "=========================================="
echo "  Phase 2 Tests: cert-manager Readiness"
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
# S2.7: cert-manager issuing certificates
# =============================================================================
echo ""
echo "--- S2.7: cert-manager Readiness ---"

# Check cert-manager pods running
assert_pod_ready "cert-manager" "app.kubernetes.io/name=cert-manager" "cert-manager pods ready"

# Check CRDs installed
assert_command_succeeds "kubectl get crd certificates.cert-manager.io" "cert-manager CRDs installed (certificates)"
assert_command_succeeds "kubectl get crd issuers.cert-manager.io" "cert-manager CRDs installed (issuers)"
assert_command_succeeds "kubectl get crd clusterissuers.cert-manager.io" "cert-manager CRDs installed (clusterissuers)"

# Check webhook is running
assert_pod_ready "cert-manager" "app.kubernetes.io/name=webhook" "cert-manager webhook ready"

# Check cainjector is running
assert_pod_ready "cert-manager" "app.kubernetes.io/name=cainjector" "cert-manager cainjector ready"

# =============================================================================
# Summary
# =============================================================================
echo ""
assert_summary
