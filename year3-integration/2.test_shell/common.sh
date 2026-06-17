#!/usr/bin/env bash
#
# Common utilities for test scripts
#

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_test() {
    echo -e "${BLUE}[TEST]${NC} $1"
}

# Test functions
run_test() {
    local test_name="$1"
    local test_cmd="$2"

    TESTS_RUN=$((TESTS_RUN + 1))
    log_test "Running: $test_name"

    if eval "$test_cmd"; then
        log_info "PASSED: $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        log_error "FAILED: $test_name"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

print_test_summary() {
    echo ""
    echo "=========================================="
    echo "           TEST SUMMARY"
    echo "=========================================="
    echo "Tests Run:    $TESTS_RUN"
    echo -e "Passed:       ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Failed:       ${RED}$TESTS_FAILED${NC}"
    echo "=========================================="

    if [ "$TESTS_FAILED" -eq 0 ]; then
        log_info "All tests passed!"
        return 0
    else
        log_error "Some tests failed"
        return 1
    fi
}

# Wait for pod to be ready
wait_for_pod() {
    local namespace=$1
    local label=$2
    local timeout=${3:-120}

    log_info "Waiting for pod with label '$label' in namespace '$namespace'..."
    kubectl wait --for=condition=Ready pod -l "$label" -n "$namespace" --timeout="${timeout}s" 2>/dev/null
}

# Wait for deployment to be ready
wait_for_deployment() {
    local namespace=$1
    local name=$2
    local timeout=${3:-120}

    log_info "Waiting for deployment '$name' in namespace '$namespace'..."
    kubectl rollout status deployment/"$name" -n "$namespace" --timeout="${timeout}s" 2>/dev/null
}

# Cleanup function
cleanup_test_resources() {
    local namespace=$1
    local label=$2

    log_info "Cleaning up test resources with label '$label' in namespace '$namespace'..."
    kubectl delete all -l "$label" -n "$namespace" --ignore-not-found 2>/dev/null
}

# Check if command exists
command_exists() {
    command -v "$1" &>/dev/null
}
