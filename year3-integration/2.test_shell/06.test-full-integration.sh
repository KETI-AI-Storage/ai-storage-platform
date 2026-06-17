#!/usr/bin/env bash
#
# Test 06: Full Integration Test
# Runs all tests in sequence and provides comprehensive report
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "=========================================="
echo "  Full Integration Test Suite"
echo "=========================================="
echo ""
echo "This script will run all component tests"
echo "and provide a comprehensive report."
echo ""

# Track overall results
declare -A TEST_RESULTS
TOTAL_SUITES=0
PASSED_SUITES=0
FAILED_SUITES=0

run_test_suite() {
    local suite_name=$1
    local suite_script=$2

    TOTAL_SUITES=$((TOTAL_SUITES + 1))

    echo ""
    echo "=========================================="
    echo "  Running: $suite_name"
    echo "=========================================="
    echo ""

    if [ -f "$suite_script" ]; then
        if bash "$suite_script"; then
            TEST_RESULTS["$suite_name"]="PASSED"
            PASSED_SUITES=$((PASSED_SUITES + 1))
        else
            TEST_RESULTS["$suite_name"]="FAILED"
            FAILED_SUITES=$((FAILED_SUITES + 1))
        fi
    else
        log_error "Test script not found: $suite_script"
        TEST_RESULTS["$suite_name"]="NOT FOUND"
        FAILED_SUITES=$((FAILED_SUITES + 1))
    fi

    echo ""
}

# Run all test suites
log_info "Starting full integration test suite..."
echo ""

# 1. Kubernetes tests
run_test_suite "Kubernetes Cluster" "${SCRIPT_DIR}/01.test-kubernetes.sh"

# 2. ArgoCD tests
run_test_suite "ArgoCD" "${SCRIPT_DIR}/02.test-argocd.sh"

# 3. Kubeflow tests
run_test_suite "Kubeflow" "${SCRIPT_DIR}/03.test-kubeflow.sh"

# 4. Kueue tests
run_test_suite "Kueue" "${SCRIPT_DIR}/04.test-kueue.sh"

# 5. Apollo tests
run_test_suite "Apollo Components" "${SCRIPT_DIR}/05.test-apollo.sh"

# ============================================
# Final Report
# ============================================
echo ""
echo "=========================================="
echo "       FULL INTEGRATION TEST REPORT"
echo "=========================================="
echo ""
echo "Test Suites Summary:"
echo "-------------------------------------------"

for suite in "Kubernetes Cluster" "ArgoCD" "Kubeflow" "Kueue" "Apollo Components"; do
    result="${TEST_RESULTS[$suite]:-NOT RUN}"
    if [ "$result" == "PASSED" ]; then
        printf "  %-25s ${GREEN}%s${NC}\n" "$suite" "$result"
    elif [ "$result" == "FAILED" ]; then
        printf "  %-25s ${RED}%s${NC}\n" "$suite" "$result"
    else
        printf "  %-25s ${YELLOW}%s${NC}\n" "$suite" "$result"
    fi
done

echo ""
echo "-------------------------------------------"
echo "Total Test Suites: $TOTAL_SUITES"
echo -e "Passed:           ${GREEN}$PASSED_SUITES${NC}"
echo -e "Failed:           ${RED}$FAILED_SUITES${NC}"
echo "-------------------------------------------"
echo ""

# System Overview
echo "System Component Overview:"
echo "-------------------------------------------"

# Kubernetes
if kubectl cluster-info &>/dev/null; then
    NODE_COUNT=$(kubectl get nodes --no-headers | wc -l)
    READY_NODES=$(kubectl get nodes --no-headers | grep -c " Ready" || echo "0")
    echo "  Kubernetes:     $READY_NODES/$NODE_COUNT nodes ready"
fi

# ArgoCD
if kubectl get namespace argocd &>/dev/null; then
    APP_COUNT=$(kubectl get applications -n argocd --no-headers 2>/dev/null | wc -l)
    echo "  ArgoCD:         Installed ($APP_COUNT applications)"
else
    echo "  ArgoCD:         Not installed"
fi

# Kubeflow
if kubectl get namespace kubeflow &>/dev/null; then
    echo "  Kubeflow:       Installed"
else
    echo "  Kubeflow:       Not installed"
fi

# Kueue
if kubectl get namespace kueue-system &>/dev/null; then
    CQ_COUNT=$(kubectl get clusterqueues --no-headers 2>/dev/null | wc -l)
    echo "  Kueue:          Installed ($CQ_COUNT cluster queues)"
else
    echo "  Kueue:          Not installed"
fi

# Apollo
APOLLO_COMPONENTS=0
if kubectl get deployment insight-scope -n apollo &>/dev/null; then APOLLO_COMPONENTS=$((APOLLO_COMPONENTS + 1)); fi
if kubectl get deployment insight-trace -n apollo &>/dev/null; then APOLLO_COMPONENTS=$((APOLLO_COMPONENTS + 1)); fi
if kubectl get deployment node-resource-forecaster -n apollo &>/dev/null; then APOLLO_COMPONENTS=$((APOLLO_COMPONENTS + 1)); fi
if kubectl get deployment ai-storage-scheduler -n keti &>/dev/null; then APOLLO_COMPONENTS=$((APOLLO_COMPONENTS + 1)); fi
if kubectl get deployment ai-storage-orchestrator -n kube-system &>/dev/null; then APOLLO_COMPONENTS=$((APOLLO_COMPONENTS + 1)); fi
if kubectl get deployment orchestration-policy-engine -n apollo &>/dev/null; then APOLLO_COMPONENTS=$((APOLLO_COMPONENTS + 1)); fi
echo "  Apollo:         $APOLLO_COMPONENTS/6 components deployed"

echo "-------------------------------------------"
echo ""

# Final status
if [ "$FAILED_SUITES" -eq 0 ]; then
    log_info "All test suites passed! System is fully operational."
    exit 0
else
    log_error "Some test suites failed. Please review the output above."
    echo ""
    echo "Troubleshooting tips:"
    echo "  1. Check pod status: kubectl get pods -A | grep -v Running"
    echo "  2. View pod logs: kubectl logs <pod-name> -n <namespace>"
    echo "  3. Describe failing resources: kubectl describe <resource> -n <namespace>"
    echo "  4. Re-run individual test: ${SCRIPT_DIR}/<test-script>.sh"
    exit 1
fi
