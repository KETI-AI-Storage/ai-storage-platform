#!/bin/bash
# =============================================================================
# 공통 검증 함수 (A~H 테스트에서 source 하여 사용)
# =============================================================================
NS="kubeflow-user-example-com"
PASS=0
FAIL=0
TOTAL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Pod가 나타날 때까지 대기 (최대 60초)
wait_for_pod() {
    local LABEL=$1
    local TIMEOUT=${2:-60}
    local ELAPSED=0
    echo -e "${CYAN}[WAIT]${NC} Pod (${LABEL}) 생성 대기..."
    while [ $ELAPSED -lt $TIMEOUT ]; do
        POD=$(kubectl get pods -n ${NS} -l "${LABEL}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        if [ -n "${POD}" ] && [ "${POD}" != "" ]; then
            echo -e "${GREEN}[OK]${NC} Pod 발견: ${POD}"
            return 0
        fi
        sleep 3
        ELAPSED=$((ELAPSED + 3))
    done
    echo -e "${RED}[TIMEOUT]${NC} Pod가 ${TIMEOUT}초 내에 생성되지 않음"
    return 1
}

# Pod 이름으로 직접 대기
wait_for_pod_name() {
    local POD_NAME=$1
    local TIMEOUT=${2:-60}
    local ELAPSED=0
    echo -e "${CYAN}[WAIT]${NC} Pod (${POD_NAME}) 생성 대기..."
    while [ $ELAPSED -lt $TIMEOUT ]; do
        EXISTS=$(kubectl get pod -n ${NS} "${POD_NAME}" -o jsonpath='{.metadata.name}' 2>/dev/null)
        if [ -n "${EXISTS}" ]; then
            echo -e "${GREEN}[OK]${NC} Pod 발견: ${EXISTS}"
            return 0
        fi
        sleep 3
        ELAPSED=$((ELAPSED + 3))
    done
    echo -e "${RED}[TIMEOUT]${NC} Pod ${POD_NAME}가 ${TIMEOUT}초 내에 생성되지 않음"
    return 1
}

# schedulerName 검증
check_scheduler() {
    local TEST_NAME=$1
    local POD_NAME=$2
    TOTAL=$((TOTAL + 1))
    local ACTUAL
    ACTUAL=$(kubectl get pod -n ${NS} "${POD_NAME}" -o jsonpath='{.spec.schedulerName}' 2>/dev/null)
    if [ "${ACTUAL}" = "ai-storage-scheduler" ]; then
        echo -e "  ${GREEN}[PASS]${NC} ${TEST_NAME}: schedulerName=${ACTUAL}"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} ${TEST_NAME}: schedulerName=${ACTUAL} (expected: ai-storage-scheduler)"
        FAIL=$((FAIL + 1))
    fi
}

# sidecar(insight-trace) 존재 검증
check_sidecar() {
    local TEST_NAME=$1
    local POD_NAME=$2
    TOTAL=$((TOTAL + 1))
    local COUNT
    COUNT=$(kubectl get pod -n ${NS} "${POD_NAME}" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null | tr ' ' '\n' | grep -c "insight-trace" || echo "0")
    if [ "${COUNT}" -ge 1 ]; then
        echo -e "  ${GREEN}[PASS]${NC} ${TEST_NAME}: insight-trace sidecar 존재 (count=${COUNT})"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} ${TEST_NAME}: insight-trace sidecar 없음"
        FAIL=$((FAIL + 1))
    fi
}

# shareProcessNamespace 검증
check_shareprocess() {
    local TEST_NAME=$1
    local POD_NAME=$2
    TOTAL=$((TOTAL + 1))
    local ACTUAL
    ACTUAL=$(kubectl get pod -n ${NS} "${POD_NAME}" -o jsonpath='{.spec.shareProcessNamespace}' 2>/dev/null)
    if [ "${ACTUAL}" = "true" ]; then
        echo -e "  ${GREEN}[PASS]${NC} ${TEST_NAME}: shareProcessNamespace=true"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} ${TEST_NAME}: shareProcessNamespace=${ACTUAL} (expected: true)"
        FAIL=$((FAIL + 1))
    fi
}

# Kueue queue label 검증 (PyTorchJob / Job)
check_kueue_label() {
    local TEST_NAME=$1
    local RESOURCE_TYPE=$2  # pytorchjob | job
    local RESOURCE_NAME=$3
    TOTAL=$((TOTAL + 1))
    local QUEUE
    QUEUE=$(kubectl get "${RESOURCE_TYPE}" -n ${NS} "${RESOURCE_NAME}" -o jsonpath='{.metadata.labels.kueue\.x-k8s\.io/queue-name}' 2>/dev/null)
    if [ "${QUEUE}" = "ai-storage-queue" ]; then
        echo -e "  ${GREEN}[PASS]${NC} ${TEST_NAME}: kueue queue=${QUEUE}"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} ${TEST_NAME}: kueue queue=${QUEUE} (expected: ai-storage-queue)"
        FAIL=$((FAIL + 1))
    fi
}

# 전체 Pod 상태 출력
show_pod_status() {
    local POD_NAME=$1
    echo ""
    echo -e "${CYAN}--- Pod 상태 ---${NC}"
    kubectl get pod -n ${NS} "${POD_NAME}" -o wide 2>/dev/null
    echo ""
    echo -e "${CYAN}--- 컨테이너 목록 ---${NC}"
    kubectl get pod -n ${NS} "${POD_NAME}" -o jsonpath='{range .spec.containers[*]}{.name}{"\t"}{.image}{"\n"}{end}' 2>/dev/null
    echo ""
}

# 결과 요약
print_summary() {
    local TEST_ID=$1
    echo ""
    echo "=========================================="
    echo " [${TEST_ID}] Test Results"
    echo "=========================================="
    echo -e " Total: ${TOTAL}"
    echo -e " ${GREEN}Pass:  ${PASS}${NC}"
    echo -e " ${RED}Fail:  ${FAIL}${NC}"
    echo "=========================================="
    if [ ${FAIL} -gt 0 ]; then
        echo -e "${RED}SOME TESTS FAILED${NC}"
        return 1
    else
        echo -e "${GREEN}ALL TESTS PASSED${NC}"
        return 0
    fi
}
