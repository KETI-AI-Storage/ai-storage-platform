#!/bin/bash
# =============================================================================
# AI Storage Webhook - Integration Test
#
# 실제 K8s 클러스터에서 웹훅 동작을 검증하는 스크립트.
# 8가지 시나리오별 Pod를 생성하고, 웹훅이 올바르게 주입했는지 확인.
#
# 사전 조건:
#   1. 웹훅 배포 완료 (./scripts/deploy.sh)
#   2. 대상 네임스페이스에 injection label 설정됨
#
# 사용법:
#   ./scripts/integration-test.sh
#   ./scripts/integration-test.sh cleanup    # 테스트 Pod 정리
# =============================================================================
set -e

NS="kubeflow-user-example-com"
PASS=0
FAIL=0
TOTAL=0

# 색상
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ─────────────────────────────────────────────────
# Cleanup
# ─────────────────────────────────────────────────
if [ "$1" = "cleanup" ]; then
    echo "Cleaning up test pods..."
    kubectl delete pod -n ${NS} -l webhook-test=true --ignore-not-found
    echo "Done."
    exit 0
fi

echo "=========================================="
echo " AI Storage Webhook Integration Test"
echo " Namespace: ${NS}"
echo "=========================================="
echo ""

# ─────────────────────────────────────────────────
# 네임스페이스 injection label 확인
# ─────────────────────────────────────────────────
LABEL=$(kubectl get namespace ${NS} -o jsonpath='{.metadata.labels.keti-ai-storage-injection}' 2>/dev/null || echo "")
if [ "${LABEL}" != "enabled" ]; then
    echo -e "${RED}[ERROR] Namespace ${NS} missing label 'keti-ai-storage-injection=enabled'${NC}"
    echo "  Run: kubectl label namespace ${NS} keti-ai-storage-injection=enabled"
    exit 1
fi

# ─────────────────────────────────────────────────
# 헬퍼 함수: Pod 생성 후 확인
# ─────────────────────────────────────────────────
check_pod() {
    local TEST_NAME=$1
    local POD_NAME=$2
    local CHECK_TYPE=$3    # scheduler | sidecar | shareprocess | none
    local EXPECTED=$4      # true | false

    TOTAL=$((TOTAL + 1))

    # Pod가 생성될 때까지 대기
    sleep 2

    case ${CHECK_TYPE} in
        scheduler)
            ACTUAL=$(kubectl get pod -n ${NS} ${POD_NAME} -o jsonpath='{.spec.schedulerName}' 2>/dev/null || echo "ERROR")
            if [ "${EXPECTED}" = "true" ]; then
                if [ "${ACTUAL}" = "ai-storage-scheduler" ]; then
                    echo -e " ${GREEN}[PASS]${NC} ${TEST_NAME}: schedulerName=${ACTUAL}"
                    PASS=$((PASS + 1))
                else
                    echo -e " ${RED}[FAIL]${NC} ${TEST_NAME}: schedulerName=${ACTUAL} (expected: ai-storage-scheduler)"
                    FAIL=$((FAIL + 1))
                fi
            else
                if [ "${ACTUAL}" != "ai-storage-scheduler" ]; then
                    echo -e " ${GREEN}[PASS]${NC} ${TEST_NAME}: schedulerName=${ACTUAL} (not injected, as expected)"
                    PASS=$((PASS + 1))
                else
                    echo -e " ${RED}[FAIL]${NC} ${TEST_NAME}: schedulerName should NOT be ai-storage-scheduler"
                    FAIL=$((FAIL + 1))
                fi
            fi
            ;;
        sidecar)
            HAS_SIDECAR=$(kubectl get pod -n ${NS} ${POD_NAME} -o jsonpath='{.spec.containers[*].name}' 2>/dev/null | grep -c "insight-trace" || echo "0")
            if [ "${EXPECTED}" = "true" ]; then
                if [ "${HAS_SIDECAR}" -ge 1 ]; then
                    echo -e " ${GREEN}[PASS]${NC} ${TEST_NAME}: insight-trace sidecar 존재"
                    PASS=$((PASS + 1))
                else
                    echo -e " ${RED}[FAIL]${NC} ${TEST_NAME}: insight-trace sidecar 없음"
                    FAIL=$((FAIL + 1))
                fi
            else
                if [ "${HAS_SIDECAR}" -eq 0 ]; then
                    echo -e " ${GREEN}[PASS]${NC} ${TEST_NAME}: sidecar 미주입 (expected)"
                    PASS=$((PASS + 1))
                else
                    echo -e " ${RED}[FAIL]${NC} ${TEST_NAME}: sidecar가 주입되면 안됨"
                    FAIL=$((FAIL + 1))
                fi
            fi
            ;;
        sidecar-count)
            COUNT=$(kubectl get pod -n ${NS} ${POD_NAME} -o jsonpath='{.spec.containers[*].name}' 2>/dev/null | tr ' ' '\n' | grep -c "insight-trace" || echo "0")
            if [ "${COUNT}" = "${EXPECTED}" ]; then
                echo -e " ${GREEN}[PASS]${NC} ${TEST_NAME}: insight-trace 개수=${COUNT}"
                PASS=$((PASS + 1))
            else
                echo -e " ${RED}[FAIL]${NC} ${TEST_NAME}: insight-trace 개수=${COUNT} (expected: ${EXPECTED})"
                FAIL=$((FAIL + 1))
            fi
            ;;
        shareprocess)
            ACTUAL=$(kubectl get pod -n ${NS} ${POD_NAME} -o jsonpath='{.spec.shareProcessNamespace}' 2>/dev/null || echo "")
            if [ "${EXPECTED}" = "true" ]; then
                if [ "${ACTUAL}" = "true" ]; then
                    echo -e " ${GREEN}[PASS]${NC} ${TEST_NAME}: shareProcessNamespace=true"
                    PASS=$((PASS + 1))
                else
                    echo -e " ${RED}[FAIL]${NC} ${TEST_NAME}: shareProcessNamespace=${ACTUAL} (expected: true)"
                    FAIL=$((FAIL + 1))
                fi
            fi
            ;;
    esac
}

# =============================================================================
# [A] 순수 Pod — 아무것도 없음
# 기대: schedulerName + shareProcess + sidecar 전부 주입
# =============================================================================
echo "--- [A] 순수 Pod (빈 상태) ---"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: webhook-test-a
  namespace: ${NS}
  labels:
    webhook-test: "true"
spec:
  containers:
  - name: main
    image: busybox
    command: ["sleep", "30"]
  restartPolicy: Never
EOF
check_pod "A-scheduler" "webhook-test-a" "scheduler" "true"
check_pod "A-sidecar" "webhook-test-a" "sidecar" "true"
check_pod "A-shareprocess" "webhook-test-a" "shareprocess" "true"

# =============================================================================
# [B] default-scheduler 설정된 Pod
# 기대: ai-storage-scheduler로 교체됨
# =============================================================================
echo ""
echo "--- [B] default-scheduler 설정 ---"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: webhook-test-b
  namespace: ${NS}
  labels:
    webhook-test: "true"
spec:
  schedulerName: default-scheduler
  containers:
  - name: main
    image: busybox
    command: ["sleep", "30"]
  restartPolicy: Never
EOF
check_pod "B-scheduler" "webhook-test-b" "scheduler" "true"

# =============================================================================
# [C] ai-storage-scheduler 이미 설정
# 기대: 변경 없음 (여전히 ai-storage-scheduler)
# =============================================================================
echo ""
echo "--- [C] ai-storage-scheduler 이미 설정 ---"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: webhook-test-c
  namespace: ${NS}
  labels:
    webhook-test: "true"
spec:
  schedulerName: ai-storage-scheduler
  containers:
  - name: main
    image: busybox
    command: ["sleep", "30"]
  restartPolicy: Never
EOF
check_pod "C-scheduler" "webhook-test-c" "scheduler" "true"

# =============================================================================
# [D] insight-trace 사이드카 이미 존재
# 기대: 중복 주입 안됨 (insight-trace 1개만)
# =============================================================================
echo ""
echo "--- [D] 사이드카 이미 존재 ---"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: webhook-test-d
  namespace: ${NS}
  labels:
    webhook-test: "true"
spec:
  containers:
  - name: main
    image: busybox
    command: ["sleep", "30"]
  - name: insight-trace
    image: ketidevit2/insight-trace:latest
    command: ["sleep", "30"]
  restartPolicy: Never
EOF
check_pod "D-no-duplicate" "webhook-test-d" "sidecar-count" "1"
check_pod "D-scheduler" "webhook-test-d" "scheduler" "true"

# =============================================================================
# [E] injection disabled label
# 기대: 아무것도 주입 안됨
# =============================================================================
echo ""
echo "--- [E] injection disabled ---"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: webhook-test-e
  namespace: ${NS}
  labels:
    webhook-test: "true"
    keti-ai-storage-injection: disabled
spec:
  containers:
  - name: main
    image: busybox
    command: ["sleep", "30"]
  restartPolicy: Never
EOF
check_pod "E-no-scheduler" "webhook-test-e" "scheduler" "false"
check_pod "E-no-sidecar" "webhook-test-e" "sidecar" "false"

# =============================================================================
# [F] shareProcessNamespace: true 이미 설정
# 기대: shareProcess 그대로 유지
# =============================================================================
echo ""
echo "--- [F] shareProcessNamespace=true 이미 설정 ---"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: webhook-test-f
  namespace: ${NS}
  labels:
    webhook-test: "true"
spec:
  shareProcessNamespace: true
  containers:
  - name: main
    image: busybox
    command: ["sleep", "30"]
  restartPolicy: Never
EOF
check_pod "F-shareprocess" "webhook-test-f" "shareprocess" "true"
check_pod "F-sidecar" "webhook-test-f" "sidecar" "true"

# =============================================================================
# [G] shareProcessNamespace: false 설정
# 기대: true로 변경됨
# =============================================================================
echo ""
echo "--- [G] shareProcessNamespace=false ---"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: webhook-test-g
  namespace: ${NS}
  labels:
    webhook-test: "true"
spec:
  shareProcessNamespace: false
  containers:
  - name: main
    image: busybox
    command: ["sleep", "30"]
  restartPolicy: Never
EOF
check_pod "G-shareprocess" "webhook-test-g" "shareprocess" "true"

# =============================================================================
# [H] 전부 이미 올바르게 설정됨
# 기대: 변경 없음 (전부 유지)
# =============================================================================
echo ""
echo "--- [H] 전부 설정 완료 상태 ---"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: webhook-test-h
  namespace: ${NS}
  labels:
    webhook-test: "true"
spec:
  schedulerName: ai-storage-scheduler
  shareProcessNamespace: true
  containers:
  - name: main
    image: busybox
    command: ["sleep", "30"]
  - name: insight-trace
    image: ketidevit2/insight-trace:latest
    command: ["sleep", "30"]
  restartPolicy: Never
EOF
check_pod "H-scheduler" "webhook-test-h" "scheduler" "true"
check_pod "H-sidecar-count" "webhook-test-h" "sidecar-count" "1"
check_pod "H-shareprocess" "webhook-test-h" "shareprocess" "true"

# =============================================================================
# 결과 요약
# =============================================================================
echo ""
echo "=========================================="
echo " Integration Test Results"
echo "=========================================="
echo -e " Total: ${TOTAL}"
echo -e " ${GREEN}Pass:  ${PASS}${NC}"
echo -e " ${RED}Fail:  ${FAIL}${NC}"
echo "=========================================="

if [ ${FAIL} -gt 0 ]; then
    echo -e "${RED}SOME TESTS FAILED${NC}"
    exit 1
else
    echo -e "${GREEN}ALL TESTS PASSED${NC}"
fi

echo ""
echo "Cleanup: ./scripts/integration-test.sh cleanup"
