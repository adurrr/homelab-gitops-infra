#!/usr/bin/env bash
# =============================================================================
# Phase 5 Tests: RBAC
# =============================================================================
# Validates ArgoCD RBAC configuration exists and is correctly applied.
# Usage: bash security/tests/test-rbac.sh
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/scripts/assert.sh"

echo "=========================================="
echo "  Phase 5 Tests: RBAC"
echo "=========================================="
echo ""

echo "--- Pre-flight ---"
if [[ -z "${KUBECONFIG:-}" ]]; then
    for candidate in "$HOME/.kube/config-homelab" "$HOME/.kube/config" "/etc/rancher/k3s/k3s.yaml"; do
        [[ -f "$candidate" ]] && export KUBECONFIG="$candidate" && break
    done
fi
assert_command_succeeds "kubectl cluster-info 2>/dev/null" "kubectl can reach the cluster"

# S5.3: ArgoCD RBAC configmap exists
echo ""
echo "--- S5.3: ArgoCD RBAC ---"
assert_resource_exists "argocd" "configmap" "argocd-rbac-cm" "ArgoCD RBAC ConfigMap exists"
assert_command_succeeds "kubectl get configmap argocd-rbac-cm -n argocd -o jsonpath='{.data.policy\.csv}' 2>/dev/null | grep -q admin" "RBAC policy defines admin role"
assert_command_succeeds "kubectl get configmap argocd-rbac-cm -n argocd -o jsonpath='{.data.policy\.default}' 2>/dev/null | grep -qi readonly" "RBAC default policy is read-only"

# S5.4: Secrets check
echo ""
echo "--- S5.4: No Plain-Text Secrets ---"
# Check repo doesn't contain raw Kubernetes secrets (gitleaks handles this in pre-commit)
assert_command_succeeds "! grep -r 'kind: Secret' $REPO_ROOT/security/ --include='*.yaml' --include='*.yml' 2>/dev/null | grep -v '#\|example\|README' | head -1" "No raw Secret manifests in security dir"

# S5.6: Pod security check
echo ""
echo "--- S5.6: Pod Security ---"
ROOT_PODS=$(kubectl get pods -A -o json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
root = []
for item in data.get('items', []):
    ns = item['metadata']['namespace']
    name = item['metadata']['name']
    if ns in ['kube-system', 'metallb-system']:
        continue  # system pods expected to run as root
    for c in item['spec'].get('containers', []):
        sec = c.get('securityContext', {})
        if sec.get('runAsUser') == 0 or sec.get('runAsNonRoot') == False:
            root.append(f'{ns}/{name}/{c.get(\"name\",\"?\")}')
if root:
    print(f'Pods running as root: {root[:5]}')
else:
    print('No non-system pods running as root')
" 2>/dev/null)
echo "  $ROOT_PODS"

if echo "$ROOT_PODS" | grep -q "No non-system"; then
    echo -e "\033[0;32m✓\033[0m No application pods running as root outside system namespaces"
    ASSERTS_RUN=$((ASSERTS_RUN + 1))
    ASSERTS_PASSED=$((ASSERTS_PASSED + 1))
else
    echo -e "\033[0;33m⊘\033[0m Some pods may run as root (check above)"
    ASSERTS_RUN=$((ASSERTS_RUN + 1))
fi

echo ""
assert_summary
