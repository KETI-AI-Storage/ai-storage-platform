#!/usr/bin/env bash
# run-orchestration-cycle.sh는 KETI 지능형 오케스트레이션 전체 운영 사이클을 실행한다.
#
# Author: 미정 <unknown@example.com>
# Created: 2026-05-28

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/log-utils.sh"
export RUN_ID LOG_DIR STATE_DIR STEP_LOG_DIR WORKLOAD_NAME TARGET_NAMESPACE
cycle_start="$(date +%s)"
log_info "→ orchestration cycle start workload=${WORKLOAD_NAME} namespace=${TARGET_NAMESPACE}"
# 사이클이 본격적으로 시작되기 전에 before 상태를 한 번 캡처해 둔다.
# [22] 단계에서 after 상태를 새로 캡처해 이 파일과 비교한다.
capture_orchestration_state before "${LOG_DIR}/before-orchestration-state.txt"
log_info "→ captured before state file=${LOG_DIR}/before-orchestration-state.txt"
bash "${SCRIPT_DIR}/run-before-flow.sh" "${WORKLOAD_NAME}" "${TARGET_NAMESPACE}"
log_info "→ decision pipeline start workload=${WORKLOAD_NAME} namespace=${TARGET_NAMESPACE}"
bash "${SCRIPT_DIR}/10-Forecaster-decision-state.sh" "${WORKLOAD_NAME}" "${TARGET_NAMESPACE}"
bash "${SCRIPT_DIR}/11-Scheduling-Policy-Engine-generate.sh" "${WORKLOAD_NAME}" "${TARGET_NAMESPACE}"
bash "${SCRIPT_DIR}/12-Orchestration-Policy-Engine-select.sh" "${WORKLOAD_NAME}" "${TARGET_NAMESPACE}"
bash "${SCRIPT_DIR}/13-Orchestrator-policy-apply.sh" "${WORKLOAD_NAME}" "${TARGET_NAMESPACE}"
log_info "→ status return flow start workload=${WORKLOAD_NAME} namespace=${TARGET_NAMESPACE}"
bash "${SCRIPT_DIR}/14-Kueue-workload-status-return.sh" "${WORKLOAD_NAME}" "${TARGET_NAMESPACE}"
bash "${SCRIPT_DIR}/15-Kubeflow-pipeline-status-return.sh" "${WORKLOAD_NAME}" "${TARGET_NAMESPACE}"
bash "${SCRIPT_DIR}/16-Argo-workflow-status-return.sh" "${WORKLOAD_NAME}" "${TARGET_NAMESPACE}"
bash "${SCRIPT_DIR}/run-after-flow.sh" "${WORKLOAD_NAME}" "${TARGET_NAMESPACE}"
save_state total_time "$(format_duration "$(( $(date +%s) - cycle_start ))")"
print_cycle_summary
log_ok "✓ orchestration cycle complete log_dir=${LOG_DIR}"
