#!/usr/bin/env bash
# 09-Preprocessing-Pipeline-Integration-run.sh는 KETI 오케스트레이션 단계 [09] Preprocessing Pipeline Integration Run 상태를 Kubernetes 결과로 출력한다.
#
# Author: 미정 <unknown@example.com>
# Created: 2026-05-28

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/log-utils.sh"
init_step_context "09" "Preprocessing Pipeline Integration Run" "${1:-}" "${2:-}"
print_step_intent "Preprocessing Pipeline 통합 상태 확인" "워크로드 Pod와 전처리 파이프라인 실행 스크립트/manifest 연결 확인" "preprocessing workflow / workload pod" "kubectl get pods -l app=<workload> -o wide" "preprocessing workload evidence observed"
pp_manifest="${REPO_DIR}/year3-integration/4.integration_test/manifests/preprocessing-pipeline-workflow.yaml"
pp_script="${REPO_DIR}/year3-integration/4.integration_test/scripts/run-preprocessing-pipeline.sh"
print_kv "workload" "${STEP_WORKLOAD:-UNKNOWN}"
print_kv "workload_source" "${STEP_WORKLOAD_SOURCE}"
print_kv "namespace" "${STEP_NAMESPACE:-UNKNOWN}"
print_kv "namespace_source" "${STEP_NAMESPACE_SOURCE}"
print_kv "manifest" "${pp_manifest}"
print_kv "script" "${pp_script}"
[ -f "${pp_script}" ] && print_kv "status" "✓ script found" || print_kv "status" "⚠ SKIP_NOT_FOUND"
if [ -n "${STEP_WORKLOAD}" ] && [ -n "${STEP_NAMESPACE}" ]; then
  print_commands_block "command" "kubectl get pods -n ${STEP_NAMESPACE} -l app=${STEP_WORKLOAD} -o wide"
  print_raw_block "workload_pods" "$(capture_cmd "kubectl get pods -n ${STEP_NAMESPACE} -l app=${STEP_WORKLOAD} -o wide")"
fi
finish_step "09"
