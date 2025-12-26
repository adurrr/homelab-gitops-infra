#!/usr/bin/env bash
# =============================================================================
# Phase 2 Tests: ArgoCD & GitOps Bootstrap
# =============================================================================
# Validates that ArgoCD is installed, the UI is accessible, applications can
# sync from Git, projects exist, and the App-of-Apps pattern is configured.
#
# Prerequisites:
#   - K3s cluster running (Phase 1 complete)
#   - ArgoCD installed in the argocd namespace
#   - KUBECONFIG set pointing to the cluster
#
# Usage:
#   export KUBECONFIG=~/.kube/config-homelab
#   bash platform/tests/test-argocd.sh
# =============================================================================

set -euo pipefail

# Get the repo root
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/scripts"

# Source assertion helpers
source "$SCRIPTS_DIR/assert.sh"

echo "=========================================="
echo "  Phase 2 Tests: ArgoCD & GitOps Bootstrap"
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
# S2.1: ArgoCD pods are running
# =============================================================================
echo ""
echo "--- S2.1: ArgoCD Pods Running ---"

assert_pod_ready "argocd" "app.kubernetes.io/name=argocd-server" "ArgoCD server pod ready"
assert_pod_ready "argocd" "app.kubernetes.io/name=argocd-redis" "ArgoCD redis pod ready"
assert_pod_ready "argocd" "app.kubernetes.io/name=argocd-repo-server" "ArgoCD repo server pod ready"
assert_pod_ready "argocd" "app.kubernetes.io/name=argocd-dex-server" "ArgoCD dex server pod ready"
assert_pod_ready "argocd" "app.kubernetes.io/name=argocd-applicationset-controller" "ArgoCD ApplicationSet controller pod ready"

# =============================================================================
# S2.2: ArgoCD UI accessible via port-forward
# =============================================================================
echo ""
echo "--- S2.2: ArgoCD UI Accessible ---"

# Use port-forward to test local UI access with cleanup in a trap
PORT_FORWARD_PID=""
cleanup() {
    if [[ -n "$PORT_FORWARD_PID" ]] && kill -0 "$PORT_FORWARD_PID" 2>/dev/null; then
        kill "$PORT_FORWARD_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Start port-forward in background
kubectl port-forward -n argocd svc/argocd-server 8080:80 --address 127.0.0.1 &>/dev/null &
PORT_FORWARD_PID=$!

# Wait for port-forward to be ready
echo "  Waiting for port-forward to be ready..."
PORT_FORWARD_READY=""
for _ in $(seq 1 15); do
    if curl -sk -o /dev/null -w '%{http_code}' "http://127.0.0.1:8080" 2>/dev/null | grep -q "200\|302\|401"; then
        PORT_FORWARD_READY="yes"
        break
    fi
    sleep 1
done

if [[ -n "$PORT_FORWARD_READY" ]]; then
    assert_http_ok "http://127.0.0.1:8080" "ArgoCD UI accessible (status 200)"
else
    ASSERTS_RUN=$((ASSERTS_RUN + 1))
    echo -e "\033[0;31m✗\033[0m ArgoCD UI accessible: port-forward did not become ready in time"
    ASSERTS_FAILED=$((ASSERTS_FAILED + 1))
fi

# =============================================================================
# S2.3: ArgoCD can sync from Git (CRD exists)
# =============================================================================
echo ""
echo "--- S2.3: ArgoCD Application CRD ---"

assert_command_succeeds "kubectl get crd applications.argoproj.io" "ArgoCD Application CRD exists"
assert_command_succeeds "kubectl get applications.argoproj.io -n argocd" "ArgoCD Applications CRD exists"

# =============================================================================
# S2.4: App-of-Apps pattern configured
# =============================================================================
echo ""
echo "--- S2.4: App-of-Apps Pattern ---"

assert_resource_exists "argocd" "Application" "homelab-apps" "App-of-Apps root application exists"

# =============================================================================
# S2.5: ArgoCD Projects exist
# =============================================================================
echo ""
echo "--- S2.5: ArgoCD Projects ---"

assert_resource_exists "argocd" "AppProject" "observability" "Observability ArgoCD project exists"
assert_resource_exists "argocd" "AppProject" "applications" "Applications ArgoCD project exists"
assert_resource_exists "argocd" "AppProject" "platform" "Platform ArgoCD project exists"

# =============================================================================
# S2.8: All platform services Healthy/Synced
# =============================================================================
echo ""
echo "--- S2.8: Platform Services Health Status ---"

# Check health status of all ArgoCD applications
HEALTH_STATUSES=$(kubectl get applications.argoproj.io -n argocd -o jsonpath='{.items[*].status.health.status}' 2>/dev/null || echo "")
SYNC_STATUSES=$(kubectl get applications.argoproj.io -n argocd -o jsonpath='{.items[*].status.sync.status}' 2>/dev/null || echo "")

if [[ -n "$HEALTH_STATUSES" ]]; then
    # Count how many are Healthy
    HEALTHY_COUNT=0
    TOTAL_COUNT=0
    for status in $HEALTH_STATUSES; do
        TOTAL_COUNT=$((TOTAL_COUNT + 1))
        if [[ "$status" == "Healthy" ]]; then
            HEALTHY_COUNT=$((HEALTHY_COUNT + 1))
        fi
    done

    if [[ "$TOTAL_COUNT" -gt 0 ]] && [[ "$HEALTHY_COUNT" -eq "$TOTAL_COUNT" ]]; then
        ASSERTS_RUN=$((ASSERTS_RUN + 1))
        ASSERTS_PASSED=$((ASSERTS_PASSED + 1))
        echo -e "\033[0;32m✓\033[0m All $TOTAL_COUNT platform applications are Healthy"
    else
        ASSERTS_RUN=$((ASSERTS_RUN + 1))
        echo -e "\033[0;31m✗\033[0m Expected all applications Healthy, found $HEALTHY_COUNT/$TOTAL_COUNT"
        echo "  Health statuses: $HEALTH_STATUSES"
        echo "  Sync statuses: $SYNC_STATUSES"
        ASSERTS_FAILED=$((ASSERTS_FAILED + 1))
    fi
else
    ASSERTS_RUN=$((ASSERTS_RUN + 1))
    echo -e "\033[0;33m⊘\033[0m No ArgoCD applications found to check health status"
fi

# Also check sync status
if [[ -n "$SYNC_STATUSES" ]]; then
    SYNCED_COUNT=0
    TOTAL_SYNC=0
    for status in $SYNC_STATUSES; do
        TOTAL_SYNC=$((TOTAL_SYNC + 1))
        if [[ "$status" == "Synced" ]]; then
            SYNCED_COUNT=$((SYNCED_COUNT + 1))
        fi
    done

    if [[ "$TOTAL_SYNC" -gt 0 ]] && [[ "$SYNCED_COUNT" -eq "$TOTAL_SYNC" ]]; then
        ASSERTS_RUN=$((ASSERTS_RUN + 1))
        ASSERTS_PASSED=$((ASSERTS_PASSED + 1))
        echo -e "\033[0;32m✓\033[0m All $TOTAL_SYNC platform applications are Synced"
    else
        ASSERTS_RUN=$((ASSERTS_RUN + 1))
        echo -e "\033[0;31m✗\033[0m Expected all applications Synced, found $SYNCED_COUNT/$TOTAL_SYNC"
        echo "  Sync statuses: $SYNC_STATUSES"
        ASSERTS_FAILED=$((ASSERTS_FAILED + 1))
    fi
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
assert_summary
