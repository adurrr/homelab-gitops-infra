#!/usr/bin/env bash
# =============================================================================
# assert.sh: TDD Assertion Helpers for Bash Tests
# =============================================================================
# Usage:
#   source scripts/assert.sh
#   assert_eq "actual" "expected" "description"
#   assert_contains "haystack" "needle" "description"
#   assert_http_ok "http://example.com" "description"
#   assert_pod_ready "namespace" "label" "description"
#
# Exit codes:
#   0: all assertions passed
#   1: one or more assertions failed

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Counters
ASSERTS_RUN=0
ASSERTS_PASSED=0
ASSERTS_FAILED=0

# =============================================================================
# Core Assertions
# =============================================================================

# Assert two values are equal
# Usage: assert_eq "actual" "expected" "description"
assert_eq() {
    local actual="$1"
    local expected="$2"
    local description="${3:-assert_eq}"
    ASSERTS_RUN=$((ASSERTS_RUN + 1))

    if [[ "$actual" == "$expected" ]]; then
        echo -e "${GREEN}✓${NC} $description"
        ASSERTS_PASSED=$((ASSERTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $description"
        echo -e "  Expected: '$expected'"
        echo -e "  Actual:   '$actual'"
        ASSERTS_FAILED=$((ASSERTS_FAILED + 1))
    fi
}

# Assert haystack contains needle
# Usage: assert_contains "haystack" "needle" "description"
assert_contains() {
    local haystack="$1"
    local needle="$2"
    local description="${3:-assert_contains}"
    ASSERTS_RUN=$((ASSERTS_RUN + 1))

    if echo "$haystack" | grep -q "$needle"; then
        echo -e "${GREEN}✓${NC} $description"
        ASSERTS_PASSED=$((ASSERTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $description"
        echo -e "  Expected to contain: '$needle'"
        echo -e "  Actual: '$haystack'"
        ASSERTS_FAILED=$((ASSERTS_FAILED + 1))
    fi
}

# Assert haystack does NOT contain needle
# Usage: assert_not_contains "haystack" "needle" "description"
assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local description="${3:-assert_not_contains}"
    ASSERTS_RUN=$((ASSERTS_RUN + 1))

    if ! echo "$haystack" | grep -q "$needle"; then
        echo -e "${GREEN}✓${NC} $description"
        ASSERTS_PASSED=$((ASSERTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $description"
        echo -e "  Expected NOT to contain: '$needle'"
        echo -e "  Actual: '$haystack'"
        ASSERTS_FAILED=$((ASSERTS_FAILED + 1))
    fi
}

# Assert a URL returns HTTP 200
# Usage: assert_http_ok "http://example.com" "description"
assert_http_ok() {
    local url="$1"
    local description="${2:-assert_http_ok}"
    ASSERTS_RUN=$((ASSERTS_RUN + 1))

    local status
    status=$(curl -sk -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo "000")

    if [[ "$status" == "200" ]]; then
        echo -e "${GREEN}✓${NC} $description (HTTP $status)"
        ASSERTS_PASSED=$((ASSERTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $description (HTTP $status, expected 200)"
        ASSERTS_FAILED=$((ASSERTS_FAILED + 1))
    fi
}

# Assert a Kubernetes pod is ready by label selector
# Usage: assert_pod_ready "namespace" "app=myapp" "description"
assert_pod_ready() {
    local namespace="$1"
    local label="$2"
    local description="${3:-Pod ready}"
    ASSERTS_RUN=$((ASSERTS_RUN + 1))

    local ready_count total_count
    total_count=$(kubectl get pods -n "$namespace" -l "$label" --no-headers 2>/dev/null | wc -l || echo "0")
    ready_count=$(kubectl get pods -n "$namespace" -l "$label" --no-headers 2>/dev/null | grep -c "Running" || echo "0")

    if [[ "$total_count" -gt 0 ]] && [[ "$ready_count" -eq "$total_count" ]]; then
        echo -e "${GREEN}✓${NC} $description ($ready_count/$total_count pods ready)"
        ASSERTS_PASSED=$((ASSERTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $description ($ready_count/$total_count pods ready)"
        ASSERTS_FAILED=$((ASSERTS_FAILED + 1))
    fi
}

# Assert a Kubernetes resource exists
# Usage: assert_resource_exists "namespace" "kind" "name" "description"
assert_resource_exists() {
    local namespace="$1"
    local kind="$2"
    local name="$3"
    local description="${4:-Resource exists}"
    ASSERTS_RUN=$((ASSERTS_RUN + 1))

    if kubectl get "$kind" "$name" -n "$namespace" &>/dev/null; then
        echo -e "${GREEN}✓${NC} $description"
        ASSERTS_PASSED=$((ASSERTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $description ($kind/$name not found in $namespace)"
        ASSERTS_FAILED=$((ASSERTS_FAILED + 1))
    fi
}

# Assert a command exits with code 0
# Usage: assert_command_succeeds "command" "description"
assert_command_succeeds() {
    local cmd="$1"
    local description="${2:-Command succeeds}"
    ASSERTS_RUN=$((ASSERTS_RUN + 1))

    if eval "$cmd" &>/dev/null; then
        echo -e "${GREEN}✓${NC} $description"
        ASSERTS_PASSED=$((ASSERTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $description (command failed: $cmd)"
        ASSERTS_FAILED=$((ASSERTS_FAILED + 1))
    fi
}

# Assert a file exists
# Usage: assert_file_exists "path" "description"
assert_file_exists() {
    local path="$1"
    local description="${2:-File exists}"
    ASSERTS_RUN=$((ASSERTS_RUN + 1))

    if [[ -f "$path" ]]; then
        echo -e "${GREEN}✓${NC} $description"
        ASSERTS_PASSED=$((ASSERTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $description (file not found: $path)"
        ASSERTS_FAILED=$((ASSERTS_FAILED + 1))
    fi
}

# Assert a directory exists
# Usage: assert_dir_exists "path" "description"
assert_dir_exists() {
    local path="$1"
    local description="${2:-Directory exists}"
    ASSERTS_RUN=$((ASSERTS_RUN + 1))

    if [[ -d "$path" ]]; then
        echo -e "${GREEN}✓${NC} $description"
        ASSERTS_PASSED=$((ASSERTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $description (directory not found: $path)"
        ASSERTS_FAILED=$((ASSERTS_FAILED + 1))
    fi
}

# =============================================================================
# Summary & Exit
# =============================================================================

# Print test summary and exit with appropriate code
# Usage: assert_summary (call at end of test script)
assert_summary() {
    echo ""
    echo "=========================================="
    echo "  Test Summary"
    echo "=========================================="
    echo -e "  Total:   $ASSERTS_RUN"
    echo -e "  ${GREEN}Passed:  $ASSERTS_PASSED${NC}"
    echo -e "  ${RED}Failed:  $ASSERTS_FAILED${NC}"
    echo "=========================================="

    if [[ $ASSERTS_FAILED -gt 0 ]]; then
        echo -e "${RED}FAILURES DETECTED${NC}"
        return 1
    else
        echo -e "${GREEN}ALL TESTS PASSED${NC}"
        return 0
    fi
}

# Source environment file if it exists
# Usage: source_env (call at start of test scripts)
source_env() {
    local env_file="${1:-infra/.env}"
    if [[ -f "$env_file" ]]; then
        # shellcheck source=/dev/null
        source "$env_file"
        echo -e "${YELLOW}Loaded environment from $env_file${NC}"
    else
        echo -e "${RED}Environment file not found: $env_file${NC}"
        echo "Copy infra/env.example to infra/.env and fill in your values"
        exit 1
    fi
}
