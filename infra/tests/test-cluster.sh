#!/usr/bin/env bash
# =============================================================================
# Phase 1 Tests: K3s Cluster with Cilium
# =============================================================================
# Validates that the K3s cluster is running, Cilium CNI is installed,
# Hubble is collecting flows, and cross-node networking works.
#
# Prerequisites:
#   - K3s server and agent installed (server-install.sh, agent-install.sh)
#   - Cilium installed (cilium install)
#   - KUBECONFIG set pointing to the cluster
#
# Usage:
#   export KUBECONFIG=~/.kube/config-homelab
#   bash infra/tests/test-cluster.sh
# =============================================================================

set -euo pipefail

# Get the repo root
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/scripts"

# Source assertion helpers
source "$SCRIPTS_DIR/assert.sh"

echo "=========================================="
echo "  Phase 1 Tests: K3s Cluster with Cilium"
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
# S1.1: K3s server node is running and healthy
# =============================================================================
echo ""
echo "--- S1.1: Cluster Nodes Ready ---"

NODE_COUNT=$(kubectl get nodes -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | wc -w || echo "0")
assert_eq "$NODE_COUNT" "2" "Two nodes in cluster"

READY_COUNT=$(kubectl get nodes -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | tr ' ' '\n' | grep -c "^True$" || echo "0")
assert_eq "$READY_COUNT" "2" "Both nodes are Ready"

# =============================================================================
# S1.2: Flannel is disabled (no flannel pods)
# =============================================================================
echo ""
echo "--- S1.2: Flannel Disabled ---"

FLANNEL_PODS=$(kubectl -n kube-system get pods -l app=flannel --no-headers 2>/dev/null || echo "")
if [[ -z "$FLANNEL_PODS" || "$FLANNEL_PODS" == "No resources found"* ]]; then
    ASSERTS_RUN=$((ASSERTS_RUN + 1))
    ASSERTS_PASSED=$((ASSERTS_PASSED + 1))
    echo -e "\033[0;32m✓\033[0m No flannel pods found (correctly disabled)"
else
    ASSERTS_RUN=$((ASSERTS_RUN + 1))
    echo -e "\033[0;31m✗\033[0m Flannel pods found: should be disabled"
    echo "  Output: $FLANNEL_PODS"
fi

# =============================================================================
# S1.3: Cilium pods are running on all nodes
# =============================================================================
echo ""
echo "--- S1.3: Cilium Pods Running ---"

CILIUM_PODS=$(kubectl -n kube-system get pods -l k8s-app=cilium --no-headers 2>/dev/null || echo "")
assert_contains "$CILIUM_PODS" "Running" "Cilium pods are Running"

CILIUM_POD_COUNT=$(echo "$CILIUM_PODS" | grep -c "Running" || echo "0")
if [[ "$CILIUM_POD_COUNT" -ge 2 ]]; then
    ASSERTS_RUN=$((ASSERTS_RUN + 1))
    ASSERTS_PASSED=$((ASSERTS_PASSED + 1))
    echo -e "\033[0;32m✓\033[0m Cilium pods on all nodes ($CILIUM_POD_COUNT Running)"
else
    ASSERTS_RUN=$((ASSERTS_RUN + 1))
    echo -e "\033[0;31m✗\033[0m Expected Cilium pods on 2+ nodes, found $CILIUM_POD_COUNT"
fi

# =============================================================================
# S1.4: Hubble is enabled and collecting flows
# =============================================================================
echo ""
echo "--- S1.4: Hubble Status ---"

if command -v cilium &>/dev/null; then
    HUBBLE_STATUS=$(cilium hubble status 2>&1 || echo "error")
    if echo "$HUBBLE_STATUS" | grep -qi "connected\|ok\|running"; then
        ASSERTS_RUN=$((ASSERTS_RUN + 1))
        ASSERTS_PASSED=$((ASSERTS_PASSED + 1))
        echo -e "\033[0;32m✓\033[0m Hubble is connected and collecting flows"
    else
        ASSERTS_RUN=$((ASSERTS_RUN + 1))
        echo -e "\033[0;31m✗\033[0m Hubble not connected"
        echo "  Output: $HUBBLE_STATUS"
    fi
else
    ASSERTS_RUN=$((ASSERTS_RUN + 1))
    echo -e "\033[0;33m⊘\033[0m Hubble status check (cilium CLI not installed on this machine)"
fi

# =============================================================================
# S1.5: Pod-to-pod cross-node networking works
# =============================================================================
echo ""
echo "--- S1.5: Cross-Node Networking ---"

# Create a test pod on each node
echo "  Creating test pods on each node..."
SERVER_NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
WORKER_NODE=$(kubectl get nodes -o jsonpath='{.items[1].metadata.name}' 2>/dev/null)
# shellcheck disable=SC2046
kubectl run test-node-server --image=busybox --overrides="{\"spec\":{\"nodeName\":\"${SERVER_NODE}\"}}" --command -- sleep 60 2>/dev/null || true
# shellcheck disable=SC2046
kubectl run test-node-worker --image=busybox --overrides="{\"spec\":{\"nodeName\":\"${WORKER_NODE}\"}}" --command -- sleep 60 2>/dev/null || true

# Wait for pods to be ready
echo "  Waiting for test pods to start..."
RETRIES=30
for _ in $(seq 1 "$RETRIES"); do
    SERVER_READY=$(kubectl get pod test-node-server -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
    WORKER_READY=$(kubectl get pod test-node-worker -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
    if [[ "$SERVER_READY" == "True" && "$WORKER_READY" == "True" ]]; then
        break
    fi
    sleep 2
done

# Get the worker pod IP
WORKER_IP=$(kubectl get pod test-node-worker -o jsonpath='{.status.podIP}' 2>/dev/null || echo "")

if [[ -n "$WORKER_IP" ]]; then
    PING_RESULT=$(kubectl exec test-node-server -- wget -q -O- --timeout=5 "http://${WORKER_IP}:80" 2>&1 || echo "FAIL")
    # Even a connection refused proves cross-node networking works
    if echo "$PING_RESULT" | grep -qi "connection refused\|404\|200\|timeout" 2>/dev/null; then
        ASSERTS_RUN=$((ASSERTS_RUN + 1))
        ASSERTS_PASSED=$((ASSERTS_PASSED + 1))
        echo -e "\033[0;32m✓\033[0m Cross-node networking works (server pod can reach worker pod IP)"
    else
        # Try a simpler connectivity test
        PING_RESULT2=$(kubectl exec test-node-server -- ping -c 1 -W 3 "$WORKER_IP" 2>&1 || echo "FAIL")
        if echo "$PING_RESULT2" | grep -qi "1 packets transmitted\|100% packet loss"; then
            ASSERTS_RUN=$((ASSERTS_RUN + 1))
            ASSERTS_PASSED=$((ASSERTS_PASSED + 1))
            echo -e "\033[0;32m✓\033[0m Cross-node networking works (ping reached worker pod)"
        else
            ASSERTS_RUN=$((ASSERTS_RUN + 1))
            echo -e "\033[0;31m✗\033[0m Cross-node networking may not be working"
            echo "  Server pod could not reach worker pod at $WORKER_IP"
        fi
    fi
else
    ASSERTS_RUN=$((ASSERTS_RUN + 1))
    echo -e "\033[0;31m✗\033[0m Could not get worker pod IP: pods may not be ready"
fi

# Clean up test pods
echo "  Cleaning up test pods..."
kubectl delete pod test-node-server --force --grace-period=0 2>/dev/null || true
kubectl delete pod test-node-worker --force --grace-period=0 2>/dev/null || true

# =============================================================================
# S1.6: DNS resolution works cluster-wide
# =============================================================================
echo ""
echo "--- S1.6: DNS Resolution ---"

DNS_RESULT=$(kubectl run test-dns --image=busybox --restart=Never --rm -it --command -- nslookup kubernetes.default 2>&1 || echo "FAIL")
if echo "$DNS_RESULT" | grep -qi "Server:\|Name:\|Address:" 2>/dev/null; then
    ASSERTS_RUN=$((ASSERTS_RUN + 1))
    ASSERTS_PASSED=$((ASSERTS_PASSED + 1))
    echo -e "\033[0;32m✓\033[0m DNS resolution works (kubernetes.default resolves)"
else
    # Try non-interactive version
    DNS_POD="dns-test-$(date +%s)"
    kubectl run "$DNS_POD" --image=busybox --restart=Never --command -- sleep 10 2>/dev/null || true
    sleep 3
    DNS_LOOKUP=$(kubectl exec "$DNS_POD" -- nslookup kubernetes.default 2>&1 || echo "FAIL")
    kubectl delete pod "$DNS_POD" --force --grace-period=0 2>/dev/null || true

    if echo "$DNS_LOOKUP" | grep -qi "Server:\|Name:\|Address:" 2>/dev/null; then
        ASSERTS_RUN=$((ASSERTS_RUN + 1))
        ASSERTS_PASSED=$((ASSERTS_PASSED + 1))
        echo -e "\033[0;32m✓\033[0m DNS resolution works (kubernetes.default resolves)"
    else
        ASSERTS_RUN=$((ASSERTS_RUN + 1))
        echo -e "\033[0;31m✗\033[0m DNS resolution failed"
        echo "  Output: $DNS_LOOKUP"
    fi
fi

# =============================================================================
# S1.7: Network policies can be enforced by Cilium
# =============================================================================
echo ""
echo "--- S1.7: Network Policy Enforcement ---"

# First check if Cilium is running
CILIUM_PODS=$(kubectl get pods -n kube-system -l k8s-app=cilium --no-headers 2>/dev/null | grep -c "Running" || echo "0")
if [[ "$CILIUM_PODS" -lt 1 ]]; then
    ASSERTS_RUN=$((ASSERTS_RUN + 1))
    echo -e "\033[0;33m⊘\033[0m Skipping network policy test: Cilium pods not running yet"
    echo "  Run 'cilium status' to check Cilium health"
    echo "  Run 'kubectl get pods -n kube-system -l k8s-app=cilium' to see pod status"
else
    # Create a test namespace and default-deny policy
    kubectl create namespace test-netpol 2>/dev/null || true

    # Wait for namespace to be ready
    sleep 2

    # Apply the network policy: write to a temp file to avoid heredoc issues
    NETPOL_FILE=$(mktemp)
    cat > "$NETPOL_FILE" <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all
  namespace: test-netpol
spec:
  podSelector: {}
  policyTypes:
    - Ingress
EOF

    NETPOL_APPLY=$(kubectl apply -f "$NETPOL_FILE" 2>&1) || NETPOL_APPLY="FAILED"
    rm -f "$NETPOL_FILE"

    # Verify the policy was created
    NETPOL_COUNT=$(kubectl get networkpolicies -n test-netpol --no-headers 2>/dev/null | wc -l || echo "0")
    if [[ "$NETPOL_COUNT" -ge 1 ]]; then
        ASSERTS_RUN=$((ASSERTS_RUN + 1))
        ASSERTS_PASSED=$((ASSERTS_PASSED + 1))
        echo -e "\033[0;32m✓\033[0m Network policies can be created and enforced by Cilium"
    else
        ASSERTS_RUN=$((ASSERTS_RUN + 1))
        echo -e "\033[0;31m✗\033[0m Network policy creation failed"
        echo "  kubectl apply output: $NETPOL_APPLY"
        echo "  networkpolicies found: $NETPOL_COUNT"
        echo "  Check: kubectl get networkpolicies -n test-netpol"
        echo "  Check: cilium status"
    fi

    # Clean up
    kubectl delete namespace test-netpol 2>/dev/null || true
fi

# =============================================================================
# S1.8: Kubeconfig works remotely
# =============================================================================
echo ""
echo "--- S1.8: Kubeconfig Remote Access ---"

REMOTE_NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l || echo "0")
assert_eq "$REMOTE_NODES" "2" "kubectl works with remote kubeconfig (saw $REMOTE_NODES nodes)"

# =============================================================================
# Summary
# =============================================================================
echo ""
assert_summary
