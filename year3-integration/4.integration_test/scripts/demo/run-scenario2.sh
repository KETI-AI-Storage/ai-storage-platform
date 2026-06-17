#!/usr/bin/env bash
# run-scenario2.sh는 scenario2 디렉터리의 01~06번 스크립트를 순차로 호출하는 어셈블러다.
# 정책값은 02번 단계의 추천 결과(state)를 그대로 사용하며, 임의 기본 실행 플래그를 만들지 않는다.
# 전체 실행 로그를 .runtime/logs/scenario2-all-YYYYMMDD-HHMMSS.log 로 저장한다.
#
# 사용법:
#   bash run-scenario2.sh [workload_name] [namespace]
#
# 흐름:
#   1) 01.node-resource-forecaster.sh   - 컨텍스트 확정 + forecast 호출
#   2) 02.policy-recommendation.sh      - 추천 결과(state) 저장
#   3) 03.orchestration-policy-engine.sh- policy-engine 상태
#   4) 04.ai-storage-orchestrator.sh    - orchestrator /health
#   5) 06.orchestration-compare.sh before- 변경 전 스냅샷
#   6) 05.orchestration-policy.sh        - state의 추천값으로 CR 실행(없으면 안내만)
#   7) 06.orchestration-compare.sh after - 변경 후 스냅샷
#   8) 06.orchestration-compare.sh compare- before/after 비교
#
# Author: 미정
# Created: 2026-05-22
# Related:
#   - year3-integration/4.integration_test/scripts/demo/scenario2/*.sh
#   - year3-integration/4.integration_test/scripts/demo/runtime.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=runtime.sh
source "${SCRIPT_DIR}/runtime.sh"

ARG_WORKLOAD="${1:-}"
ARG_NAMESPACE="${2:-}"

init_log "scenario2-all"
require_cmd kubectl

banner "Scenario 2 — Forecaster / Policy / Orchestrator 검증 및 정책 실행"

run_step() {
  local script="$1"; shift
  local label="${script##*/}"
  echo
  echo ">> ${label} ${*}"
  local rc=0
  bash "${script}" "$@" || rc=$?
  echo "step=${label} exit_code=${rc}"
  return 0
}

run_step "${SCRIPT_DIR}/scenario2/06.node-resource-forecaster.sh"   "${ARG_WORKLOAD}" "${ARG_NAMESPACE}"
run_step "${SCRIPT_DIR}/scenario2/07.policy-recommendation.sh"      "${ARG_WORKLOAD}" "${ARG_NAMESPACE}"
run_step "${SCRIPT_DIR}/scenario2/08.orchestration-policy-engine.sh"
run_step "${SCRIPT_DIR}/scenario2/09.ai-storage-orchestrator.sh"
run_step "${SCRIPT_DIR}/scenario2/11.orchestration-compare.sh" before
run_step "${SCRIPT_DIR}/scenario2/10.orchestration-policy.sh"
# WHY: 정책 실행 후 변화가 반영될 시간을 짧게 둔다. autoscaler가 별도 리소스를 만드는 경우
#      replicas 자체는 변하지 않을 수 있으므로 20초 정도만 대기한다.
sleep 20
run_step "${SCRIPT_DIR}/scenario2/11.orchestration-compare.sh" after
run_step "${SCRIPT_DIR}/scenario2/11.orchestration-compare.sh" compare

echo
echo "================================"
echo "Scenario 2 종합"
echo "================================"
echo "state_file=$(state_file_path scenario2)"
echo "logs_dir=${RUNTIME_DIR}/logs"
