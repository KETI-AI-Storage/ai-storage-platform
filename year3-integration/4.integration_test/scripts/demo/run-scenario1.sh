#!/usr/bin/env bash
# run-scenario1.sh는 scenario1 디렉터리의 01~05번 스크립트를 순차로 호출하는 어셈블러다.
# 워크로드 이름/PVC/네임스페이스를 박지 않으며, 입력은 사용자 인자만 받는다.
# 전체 실행 로그를 .runtime/logs/scenario1-all-YYYYMMDD-HHMMSS.log 로 저장한다.
# 본 스크립트 자체는 정상/비정상 같은 단정 표현을 출력하지 않고 각 단계의 exit_code와
# log_file 경로만 모아서 보고한다.
#
# 사용법:
#   bash run-scenario1.sh [manifest_path_or_workload_name] [namespace]
#
# Author: 미정
# Created: 2026-05-22
# Related:
#   - year3-integration/4.integration_test/scripts/demo/scenario1/*.sh
#   - year3-integration/4.integration_test/scripts/demo/runtime.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=runtime.sh
source "${SCRIPT_DIR}/runtime.sh"

ARG_TARGET="${1:-}"
ARG_NAMESPACE="${2:-}"

init_log "scenario1-all"
require_cmd kubectl

banner "Scenario 1 — 전처리 워크로드 생성 및 검증"

STEP_LOG_FILES=()
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

run_step "${SCRIPT_DIR}/scenario1/01.preprocessing-workload.sh" "${ARG_TARGET}" "${ARG_NAMESPACE}"
run_step "${SCRIPT_DIR}/scenario1/02.ai-storage-webhook.sh"
run_step "${SCRIPT_DIR}/scenario1/03.storage-pvc-binding.sh"
run_step "${SCRIPT_DIR}/scenario1/04.ai-storage-scheduler.sh"
run_step "${SCRIPT_DIR}/scenario1/05.preprocessing-result.sh"

echo
echo "================================"
echo "Scenario 1 종합"
echo "================================"
echo "state_file=$(state_file_path scenario1)"
echo "logs_dir=${RUNTIME_DIR}/logs"
