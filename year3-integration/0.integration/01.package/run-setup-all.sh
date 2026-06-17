#!/usr/bin/env bash
# run-setup-all.sh는 KETI 지능형 오케스트레이션 패키지 설치 상태를 순서대로 점검한다.
#
# Author: 미정 <unknown@example.com>
# Created: 2026-05-28

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../02.keti-orchestration-module/lib/common-log.sh"
export RUN_ID LOG_DIR STATE_DIR STEP_LOG_DIR
log_info "→ package setup status check start"
bash "${SCRIPT_DIR}/package-setup-00-environment-version0.1.sh"
bash "${SCRIPT_DIR}/package-setup-01-kubernetes-version0.1.sh"
bash "${SCRIPT_DIR}/package-setup-02-argo-version0.1.sh"
bash "${SCRIPT_DIR}/package-setup-03-kubeflow-version0.1.sh"
bash "${SCRIPT_DIR}/package-setup-04-kueue-version0.1.sh"
bash "${SCRIPT_DIR}/package-setup-05-ai-storage-scheduler-version0.1.sh"
bash "${SCRIPT_DIR}/package-setup-06-scheduling-policy-engine-version0.1.sh"
bash "${SCRIPT_DIR}/package-setup-07-insight-hub-version0.1.sh"
bash "${SCRIPT_DIR}/package-setup-08-insight-scope-version0.1.sh"
bash "${SCRIPT_DIR}/package-setup-09-insight-trace-version0.1.sh"
bash "${SCRIPT_DIR}/package-setup-10-forecaster-version0.1.sh"
bash "${SCRIPT_DIR}/package-setup-11-orchestration-policy-engine-version0.1.sh"
bash "${SCRIPT_DIR}/package-setup-12-orchestrator-version0.1.sh"
bash "${SCRIPT_DIR}/package-setup-13-preprocessing-pipeline-integration-version0.1.sh"
log_ok "✓ package setup status check complete"
