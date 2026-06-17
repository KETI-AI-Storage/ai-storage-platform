#!/usr/bin/env bash
#
# Run All Component Tests
# 모든 컴포넌트 테스트 실행
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

print_header "KETI AI Storage Platform - All Component Tests"

# Track results
declare -A COMPONENT_RESULTS
TOTAL_COMPONENTS=0
PASSED_COMPONENTS=0
FAILED_COMPONENTS=0

run_component_test() {
    local component_name=$1
    local test_script=$2

    TOTAL_COMPONENTS=$((TOTAL_COMPONENTS + 1))

    echo ""
    echo "============================================================"
    echo "  Testing: $component_name"
    echo "============================================================"
    echo ""

    if [ -f "$test_script" ]; then
        if bash "$test_script"; then
            COMPONENT_RESULTS["$component_name"]="PASSED"
            PASSED_COMPONENTS=$((PASSED_COMPONENTS + 1))
        else
            COMPONENT_RESULTS["$component_name"]="FAILED"
            FAILED_COMPONENTS=$((FAILED_COMPONENTS + 1))
        fi
    else
        log_error "Test script not found: $test_script"
        COMPONENT_RESULTS["$component_name"]="NOT FOUND"
        FAILED_COMPONENTS=$((FAILED_COMPONENTS + 1))
    fi
}

# ============================================
# Run All Tests
# ============================================

echo ""
log_info "Starting all component tests..."
echo ""

# 1. Insight Scope
run_component_test "Insight Scope" "${SCRIPT_DIR}/insight-scope/test.sh"

# 2. Insight Trace
run_component_test "Insight Trace" "${SCRIPT_DIR}/insight-trace/test.sh"

# 3. Node Resource Forecaster
run_component_test "Node Resource Forecaster" "${SCRIPT_DIR}/node-resource-forecaster/test.sh"

# 4. Scheduling Policy Engine
run_component_test "Scheduling Policy Engine" "${SCRIPT_DIR}/scheduling-policy-engine/test.sh"

# 5. Orchestration Policy Engine
run_component_test "Orchestration Policy Engine" "${SCRIPT_DIR}/orchestration-policy-engine/test.sh"

# 6. AI Storage Scheduler
run_component_test "AI Storage Scheduler" "${SCRIPT_DIR}/ai-storage-scheduler/test.sh"

# 7. AI Storage Orchestrator
run_component_test "AI Storage Orchestrator" "${SCRIPT_DIR}/ai-storage-orchestrator/test.sh"

# ============================================
# Final Report
# ============================================

echo ""
echo "============================================================"
echo "           FINAL TEST REPORT"
echo "============================================================"
echo ""

printf "%-35s %s\n" "Component" "Status"
echo "------------------------------------------------------------"

for component in "Insight Scope" "Insight Trace" "Node Resource Forecaster" \
                 "Scheduling Policy Engine" "Orchestration Policy Engine" \
                 "AI Storage Scheduler" "AI Storage Orchestrator"; do
    result="${COMPONENT_RESULTS[$component]:-NOT RUN}"
    if [ "$result" == "PASSED" ]; then
        printf "%-35s ${GREEN}%s${NC}\n" "$component" "$result"
    elif [ "$result" == "FAILED" ]; then
        printf "%-35s ${RED}%s${NC}\n" "$component" "$result"
    else
        printf "%-35s ${YELLOW}%s${NC}\n" "$component" "$result"
    fi
done

echo "------------------------------------------------------------"
echo ""
echo "Total Components: $TOTAL_COMPONENTS"
echo -e "Passed:          ${GREEN}$PASSED_COMPONENTS${NC}"
echo -e "Failed:          ${RED}$FAILED_COMPONENTS${NC}"
echo ""

if [ "$FAILED_COMPONENTS" -eq 0 ]; then
    log_info "All component tests passed!"
    exit 0
else
    log_error "Some component tests failed"
    exit 1
fi
