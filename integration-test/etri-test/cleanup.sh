#!/bin/bash
# =============================================================================
# 조합 A~H 테스트 리소스 전체 정리
#
# 사용법:
#   ./cleanup.sh          # 전체 정리
#   ./cleanup.sh A        # 특정 조합만 정리
#   ./cleanup.sh A B C    # 여러 조합 정리
# =============================================================================
set -e

NS="kubeflow-user-example-com"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo "=========================================="
echo " AI Storage 조합 테스트 - Cleanup"
echo " Namespace: ${NS}"
echo "=========================================="
echo ""

cleanup_a() {
    echo -e "${CYAN}[A]${NC} Job 정리..."
    kubectl delete job -n ${NS} combo-a-training-job --ignore-not-found
}

cleanup_b() {
    echo -e "${CYAN}[B]${NC} Argo Workflow 정리..."
    kubectl delete workflow -n ${NS} combo-b-pipeline --ignore-not-found
}

cleanup_c() {
    echo -e "${CYAN}[C]${NC} PyTorchJob 정리..."
    kubectl delete pytorchjob -n ${NS} combo-c-pytorchjob --ignore-not-found
}

cleanup_d() {
    echo -e "${CYAN}[D]${NC} Kueue Job 정리..."
    kubectl delete job -n ${NS} combo-d-kueue-job --ignore-not-found
}

cleanup_e() {
    echo -e "${CYAN}[E]${NC} PyTorchJob + Kueue 정리..."
    kubectl delete pytorchjob -n ${NS} combo-e-pytorchjob-kueue --ignore-not-found
}

cleanup_f() {
    echo -e "${CYAN}[F]${NC} Argo Workflow + Kueue 정리..."
    kubectl delete workflow -n ${NS} combo-f-workflow-kueue --ignore-not-found
    kubectl delete job -n ${NS} -l combo-id=F-kueue --ignore-not-found
}

cleanup_g() {
    echo -e "${CYAN}[G]${NC} 전체 통합 정리..."
    kubectl delete workflow -n ${NS} combo-g-full-integration --ignore-not-found
    kubectl delete pytorchjob -n ${NS} -l combo-id=G-train --ignore-not-found
}

cleanup_h() {
    echo -e "${CYAN}[H]${NC} Direct Pod 정리..."
    kubectl delete pod -n ${NS} combo-h-direct-pod --ignore-not-found
}

# 특정 조합만 정리 또는 전체 정리
if [ $# -gt 0 ]; then
    for COMBO in "$@"; do
        COMBO_UPPER=$(echo "${COMBO}" | tr '[:lower:]' '[:upper:]')
        case ${COMBO_UPPER} in
            A) cleanup_a ;;
            B) cleanup_b ;;
            C) cleanup_c ;;
            D) cleanup_d ;;
            E) cleanup_e ;;
            F) cleanup_f ;;
            G) cleanup_g ;;
            H) cleanup_h ;;
            *) echo -e "${RED}[ERROR]${NC} 알 수 없는 조합: ${COMBO}" ;;
        esac
    done
else
    echo "전체 조합 (A~H) 리소스 정리 중..."
    echo ""
    cleanup_a
    cleanup_b
    cleanup_c
    cleanup_d
    cleanup_e
    cleanup_f
    cleanup_g
    cleanup_h
fi

# 남은 Pod 정리 (label 기반)
echo ""
echo -e "${CYAN}[*]${NC} combo-test label Pod 일괄 정리..."
kubectl delete pods -n ${NS} -l combo-test=true --ignore-not-found

echo ""
echo -e "${GREEN}Cleanup 완료!${NC}"
echo ""
echo "확인: kubectl get pods -n ${NS} -l combo-test=true"
echo "확인: kubectl get jobs -n ${NS} -l combo-test=true"
echo "확인: kubectl get workflows -n ${NS} -l combo-test=true"
echo "확인: kubectl get pytorchjobs -n ${NS} -l combo-test=true"
