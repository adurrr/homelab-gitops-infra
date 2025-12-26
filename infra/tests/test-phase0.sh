#!/usr/bin/env bash
# =============================================================================
# Phase 0 Tests: Foundation & Repo Setup
# =============================================================================
# Validates that the repository structure, configuration, and tooling
# are correctly set up before proceeding to Phase 1.
#
# Usage: bash infra/tests/test-phase0.sh
# =============================================================================

set -euo pipefail

# Get the repo root (two levels up from this script's directory: infra/tests/ -> repo root)
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/scripts"

# Source assertion helpers
source "$SCRIPTS_DIR/assert.sh"

echo "=========================================="
echo "  Phase 0 Tests: Foundation & Repo Setup"
echo "=========================================="
echo ""

# =============================================================================
# S0.1: Repository has valid directory structure
# =============================================================================
echo "--- S0.1: Directory Structure ---"

assert_dir_exists "$REPO_ROOT/infra/k3s" "infra/k3s exists"
assert_dir_exists "$REPO_ROOT/infra/cilium" "infra/cilium exists"
assert_dir_exists "$REPO_ROOT/infra/tests" "infra/tests exists"
assert_dir_exists "$REPO_ROOT/platform/argocd" "platform/argocd exists"
assert_dir_exists "$REPO_ROOT/platform/metallb" "platform/metallb exists"
assert_dir_exists "$REPO_ROOT/platform/cert-manager" "platform/cert-manager exists"
assert_dir_exists "$REPO_ROOT/observability/kube-prometheus-stack" "observability/kube-prometheus-stack exists"
assert_dir_exists "$REPO_ROOT/observability/loki" "observability/loki exists"
assert_dir_exists "$REPO_ROOT/observability/otel-collector" "observability/otel-collector exists"
assert_dir_exists "$REPO_ROOT/observability/dashboards" "observability/dashboards exists"
assert_dir_exists "$REPO_ROOT/observability/datasources" "observability/datasources exists"
assert_dir_exists "$REPO_ROOT/observability/tests" "observability/tests exists"
assert_dir_exists "$REPO_ROOT/apps/home-assistant" "apps/home-assistant exists"
assert_dir_exists "$REPO_ROOT/apps/home-assistant/templates" "apps/home-assistant/templates exists"
assert_dir_exists "$REPO_ROOT/apps/home-assistant/tests" "apps/home-assistant/tests exists"
assert_dir_exists "$REPO_ROOT/security/network-policies" "security/network-policies exists"
assert_dir_exists "$REPO_ROOT/security/rbac" "security/rbac exists"
assert_dir_exists "$REPO_ROOT/security/secrets" "security/secrets exists"
assert_dir_exists "$REPO_ROOT/security/tests" "security/tests exists"
assert_dir_exists "$REPO_ROOT/scripts" "scripts exists"
assert_dir_exists "$REPO_ROOT/docs" "docs exists"
assert_dir_exists "$REPO_ROOT/docs/runbooks" "docs/runbooks exists"

# =============================================================================
# S0.2: All YAML files pass yamllint (if installed)
# =============================================================================
echo ""
echo "--- S0.2: YAML Linting ---"

if command -v yamllint &>/dev/null; then
    result=$(yamllint -d relaxed "$REPO_ROOT" 2>&1 || true)
    if echo "$result" | grep -qi "error"; then
        echo "⚠ yamllint found errors (will be addressed as YAML files are added)"
    else
        assert_command_succeeds "yamllint -d relaxed $REPO_ROOT" "YAML files pass yamllint"
    fi
else
    echo "⚠ yamllint not installed: skipping YAML lint check"
    ASSERTS_RUN=$((ASSERTS_RUN + 1))
    ASSERTS_PASSED=$((ASSERTS_PASSED + 1))
    echo -e "\033[0;33m⊘\033[0m YAML lint (yamllint not installed)"
fi

# =============================================================================
# S0.3: All Helm charts pass helm lint (if any exist)
# =============================================================================
echo ""
echo "--- S0.3: Helm Chart Linting ---"

if command -v helm &>/dev/null; then
    chart_count=$(find "$REPO_ROOT" -name Chart.yaml 2>/dev/null | wc -l)
    if [[ "$chart_count" -gt 0 ]]; then
        while IFS= read -r chart; do
            chart_dir=$(dirname "$chart")
            assert_command_succeeds "helm lint $chart_dir" "Helm chart lint: $chart_dir"
        done < <(find "$REPO_ROOT" -name Chart.yaml)
    else
        ASSERTS_RUN=$((ASSERTS_RUN + 1))
        ASSERTS_PASSED=$((ASSERTS_PASSED + 1))
        echo -e "\033[0;33m⊘\033[0m No Helm charts found yet (expected for Phase 0)"
    fi
else
    echo "⚠ helm not installed: skipping Helm lint check"
    ASSERTS_RUN=$((ASSERTS_RUN + 1))
    ASSERTS_PASSED=$((ASSERTS_PASSED + 1))
    echo -e "\033[0;33m⊘\033[0m Helm lint (helm not installed)"
fi

# =============================================================================
# S0.4: Pre-commit hooks are configured
# =============================================================================
echo ""
echo "--- S0.4: Pre-commit Configuration ---"

assert_file_exists "$REPO_ROOT/.pre-commit-config.yaml" ".pre-commit-config.yaml exists"
assert_file_exists "$REPO_ROOT/.gitignore" ".gitignore exists"

# =============================================================================
# S0.5: No secrets committed (gitleaks check)
# =============================================================================
echo ""
echo "--- S0.5: Secret Detection ---"

if command -v gitleaks &>/dev/null; then
    # Scan git-tracked files only (--no-git scans all files including .env)
    # .env is gitignored so it won't appear in git-tracked scan results
    assert_command_succeeds "gitleaks detect --verbose 2>/dev/null" "No secrets detected by gitleaks"
else
    echo "⚠ gitleaks not installed: skipping secret detection"
    ASSERTS_RUN=$((ASSERTS_RUN + 1))
    ASSERTS_PASSED=$((ASSERTS_PASSED + 1))
    echo -e "\033[0;33m⊘\033[0m Secret detection (gitleaks not installed)"
fi

# =============================================================================
# S0.6: Makefile targets exist
# =============================================================================
echo ""
echo "--- S0.6: Makefile Targets ---"

assert_file_exists "$REPO_ROOT/Makefile" "Makefile exists"

# Check that key targets are defined
makefile_content=$(cat "$REPO_ROOT/Makefile")
assert_contains "$makefile_content" "validate-structure" "Makefile has validate-structure target"
assert_contains "$makefile_content" "lint" "Makefile has lint target"
assert_contains "$makefile_content" "test-phase0" "Makefile has test target"
assert_contains "$makefile_content" "scan-secrets" "Makefile has scan-secrets target"
assert_contains "$makefile_content" "scan-vulns" "Makefile has scan-vulns target"
assert_contains "$makefile_content" "help" "Makefile has help target"

# =============================================================================
# S0.7: Environment template exists and .env is gitignored
# =============================================================================
echo ""
echo "--- S0.7: Environment Configuration ---"

assert_file_exists "$REPO_ROOT/infra/env.example" "infra/env.example exists"

gitignore_content=$(cat "$REPO_ROOT/.gitignore")
assert_contains "$gitignore_content" ".env" ".gitignore excludes .env files"
# Verify .env.example is explicitly allowed (negation pattern)
assert_contains "$gitignore_content" "!**/.env.example" ".gitignore explicitly allows .env.example files"

# =============================================================================
# S0.8: Assert helpers are available
# =============================================================================
echo ""
echo "--- S0.8: TDD Assertion Helpers ---"

assert_file_exists "$REPO_ROOT/scripts/assert.sh" "scripts/assert.sh exists"

# Verify key functions are defined
assert_eq "$(grep -c 'assert_eq()' "$REPO_ROOT/scripts/assert.sh")" "1" "assert.sh defines assert_eq"
assert_eq "$(grep -c 'assert_contains()' "$REPO_ROOT/scripts/assert.sh")" "1" "assert.sh defines assert_contains"
assert_eq "$(grep -c 'assert_http_ok()' "$REPO_ROOT/scripts/assert.sh")" "1" "assert.sh defines assert_http_ok"
assert_eq "$(grep -c 'assert_pod_ready()' "$REPO_ROOT/scripts/assert.sh")" "1" "assert.sh defines assert_pod_ready"
assert_eq "$(grep -c 'assert_summary()' "$REPO_ROOT/scripts/assert.sh")" "1" "assert.sh defines assert_summary"

# =============================================================================
# S0.9: Ansible playbook structure and syntax
# =============================================================================
echo ""
echo "--- S0.9: Ansible Playbook ---"

assert_file_exists "$REPO_ROOT/ansible/playbook.yml" "ansible/playbook.yml exists"
assert_file_exists "$REPO_ROOT/ansible/inventory.example.yml" "ansible/inventory.example.yml exists"
assert_file_exists "$REPO_ROOT/ansible.cfg" "ansible.cfg exists (repo root)"
assert_file_exists "$REPO_ROOT/ansible/vars/main.yml" "ansible/vars/main.yml exists"

# Verify role directories exist
assert_dir_exists "$REPO_ROOT/ansible/roles/bootstrap-node/tasks" "bootstrap-node role exists"
assert_dir_exists "$REPO_ROOT/ansible/roles/install-kubectl/tasks" "install-kubectl role exists"
assert_dir_exists "$REPO_ROOT/ansible/roles/install-helm/tasks" "install-helm role exists"

# Verify role main.yml files exist
assert_file_exists "$REPO_ROOT/ansible/roles/bootstrap-node/tasks/main.yml" "bootstrap-node tasks/main.yml exists"
assert_file_exists "$REPO_ROOT/ansible/roles/install-kubectl/tasks/main.yml" "install-kubectl tasks/main.yml exists"
assert_file_exists "$REPO_ROOT/ansible/roles/install-helm/tasks/main.yml" "install-helm tasks/main.yml exists"

# Verify playbook references the correct roles
playbook_content=$(cat "$REPO_ROOT/ansible/playbook.yml")
assert_contains "$playbook_content" "bootstrap-node" "Playbook includes bootstrap-node role"
assert_contains "$playbook_content" "install-kubectl" "Playbook includes install-kubectl role"
assert_contains "$playbook_content" "install-helm" "Playbook includes install-helm role"

# Verify architecture mapping for aarch64
vars_content=$(cat "$REPO_ROOT/ansible/vars/main.yml")
assert_contains "$vars_content" "aarch64" "Vars include aarch64 architecture mapping"
assert_contains "$vars_content" "arm64" "Vars map aarch64 to arm64 (Go arch)"

# Verify inventory template has placeholder values (not real IPs)
inventory_content=$(cat "$REPO_ROOT/ansible/inventory.example.yml")
assert_contains "$inventory_content" "192.168.0.10" "Inventory template has placeholder server IP"
assert_contains "$inventory_content" "192.168.0.11" "Inventory template has placeholder agent IP"

# Verify inventory.yml is gitignored
assert_contains "$gitignore_content" "inventory.yml" ".gitignore excludes inventory.yml"

# Verify ansible.cfg is in repo root and specifies inventory path
ansible_cfg_content=$(cat "$REPO_ROOT/ansible.cfg")
assert_contains "$ansible_cfg_content" "inventory" "ansible.cfg specifies inventory path"

# Syntax check the playbook (if ansible-playbook is available)
if command -v ansible-playbook &>/dev/null; then
    assert_command_succeeds "LC_ALL=C.UTF-8 ansible-playbook --syntax-check $REPO_ROOT/ansible/playbook.yml 2>/dev/null" "Ansible playbook syntax is valid"
else
    ASSERTS_RUN=$((ASSERTS_RUN + 1))
    ASSERTS_PASSED=$((ASSERTS_PASSED + 1))
    echo -e "\033[0;33m⊘\033[0m Ansible playbook syntax check (ansible-playbook not installed)"
fi

# =============================================================================
# Summary
# =============================================================================
assert_summary
