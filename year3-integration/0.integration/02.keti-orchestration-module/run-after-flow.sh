#!/usr/bin/env bash
# run-after-flow.sh는 KETI 오케스트레이션 2차 운영 흐름을 실행한다.
#
# Author: 미정 <unknown@example.com>
# Created: 2026-05-28

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/log-utils.sh"
export RUN_ID LOG_DIR STATE_DIR STEP_LOG_DIR WORKLOAD_NAME TARGET_NAMESPACE
log_info "→ after flow start workload=${WORKLOAD_NAME} namespace=${TARGET_NAMESPACE}"
bash "${SCRIPT_DIR}/17-Argo-policy-aware-dispatch.sh" "${WORKLOAD_NAME}" "${TARGET_NAMESPACE}"
bash "${SCRIPT_DIR}/18-Kubeflow-policy-aware-run.sh" "${WORKLOAD_NAME}" "${TARGET_NAMESPACE}"
bash "${SCRIPT_DIR}/19-Kueue-policy-aware-enqueue.sh" "${WORKLOAD_NAME}" "${TARGET_NAMESPACE}"
bash "${SCRIPT_DIR}/20-Scheduler-policy-aware-trigger.sh" "${WORKLOAD_NAME}" "${TARGET_NAMESPACE}"
bash "${SCRIPT_DIR}/21-Algorithm-after-state.sh" "${WORKLOAD_NAME}" "${TARGET_NAMESPACE}"
bash "${SCRIPT_DIR}/22-Selected-Orchestration-result.sh" "${WORKLOAD_NAME}" "${TARGET_NAMESPACE}"
bash "${SCRIPT_DIR}/23-Binding-resource-check.sh" "${WORKLOAD_NAME}" "${TARGET_NAMESPACE}"
bash "${SCRIPT_DIR}/24-Before-After-change-summary.sh" "${WORKLOAD_NAME}" "${TARGET_NAMESPACE}"
log_ok "✓ after flow complete"
