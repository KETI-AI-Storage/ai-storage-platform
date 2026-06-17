#!/bin/bash
# =============================================================================
# 조합 A~H 전체 테스트 순차 실행
#
# 사용법:
#   ./run-all.sh              # 전체 실행
#   ./run-all.sh A B C        # 특정 조합만 실행
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

TOTAL_PASS=0
TOTAL_FAIL=0

echo "################################################################"
echo "#  KETI AI Storage - 조합 A~H 통합 테스트"
echo "#  $(date '+%Y-%m-%d %H:%M:%S')"
echo "################################################################"
echo ""

run_test() {
    local ID=$1
    local SCRIPT="${SCRIPT_DIR}/${ID}"
    echo ""
    echo "================================================================"
    echo -e " ${CYAN}>>> 조합 ${ID} 실행${NC}"
    echo "================================================================"
    if bash "${SCRIPT}"; then
        TOTAL_PASS=$((TOTAL_PASS + 1))
    else
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
    fi
    echo ""
    sleep 3
}

COMBOS=("A-argocd-job.sh" "B-argocd-workflow.sh" "C-argocd-pytorchjob.sh" "D-argocd-kueue.sh" "E-argocd-pytorchjob-kueue.sh" "F-argocd-workflow-kueue.sh" "G-full-integration.sh" "H-direct-apply.sh")

if [ $# -gt 0 ]; then
    for ARG in "$@"; do
        ARG_UPPER=$(echo "${ARG}" | tr '[:lower:]' '[:upper:]')
        case ${ARG_UPPER} in
            A) run_test "A-argocd-job.sh" ;;
            B) run_test "B-argocd-workflow.sh" ;;
            C) run_test "C-argocd-pytorchjob.sh" ;;
            D) run_test "D-argocd-kueue.sh" ;;
            E) run_test "E-argocd-pytorchjob-kueue.sh" ;;
            F) run_test "F-argocd-workflow-kueue.sh" ;;
            G) run_test "G-full-integration.sh" ;;
            H) run_test "H-direct-apply.sh" ;;
            *) echo -e "${RED}[ERROR]${NC} 알 수 없는 조합: ${ARG}" ;;
        esac
    done
else
    for COMBO in "${COMBOS[@]}"; do
        run_test "${COMBO}"
    done
fi

echo ""
echo "################################################################"
echo "#  전체 테스트 결과"
echo "################################################################"
echo -e "  ${GREEN}성공: ${TOTAL_PASS}${NC}"
echo -e "  ${RED}실패: ${TOTAL_FAIL}${NC}"
echo "################################################################"
echo ""
echo "정리: ./cleanup.sh"
