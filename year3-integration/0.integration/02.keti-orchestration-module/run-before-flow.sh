#!/usr/bin/env bash
# run-before-flow.sh는 KETI 오케스트레이션 1차 운영 흐름을 실행한다.
#
# Author: 미정 <unknown@example.com>
# Created: 2026-05-28

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/log-utils.sh"
export RUN_ID LOG_DIR STATE_DIR STEP_LOG_DIR WORKLOAD_NAME TARGET_NAMESPACE
log_info "→ before flow start workload=${WORKLOAD_NAME} namespace=${TARGET_NAMESPACE}"
bash "${SCRIPT_DIR}/01-Argo-workflow-dispatch.sh" "${WORKLOAD_NAME}" "${TARGET_NAMESPACE}"
bash "${SCRIPT_DIR}/02-Kubeflow-pipeline-run.sh" "${WORKLOAD_NAME}" "${TARGET_NAMESPACE}"
bash "${SCRIPT_DIR}/03-Kueue-workload-enqueue.sh" "${WORKLOAD_NAME}" "${TARGET_NAMESPACE}"
bash "${SCRIPT_DIR}/04-Scheduler-schedule-trigger.sh" "${WORKLOAD_NAME}" "${TARGET_NAMESPACE}"
bash "${SCRIPT_DIR}/05-Algorithm-before-state.sh" "${WORKLOAD_NAME}" "${TARGET_NAMESPACE}"
bash "${SCRIPT_DIR}/06-Insight-Hub-connect.sh" "${WORKLOAD_NAME}" "${TARGET_NAMESPACE}"
bash "${SCRIPT_DIR}/07-Insight-Scope-collect.sh" "${WORKLOAD_NAME}" "${TARGET_NAMESPACE}"
bash "${SCRIPT_DIR}/08-Insight-Trace-record.sh" "${WORKLOAD_NAME}" "${TARGET_NAMESPACE}"
bash "${SCRIPT_DIR}/09-Preprocessing-Pipeline-Integration-run.sh" "${WORKLOAD_NAME}" "${TARGET_NAMESPACE}"
log_ok "✓ before flow complete"
