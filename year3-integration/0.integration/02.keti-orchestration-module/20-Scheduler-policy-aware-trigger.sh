#!/usr/bin/env bash
# 20-Scheduler-policy-aware-trigger.sh는 KETI 오케스트레이션 단계 [20] Scheduler Policy Aware Trigger 상태를 Kubernetes 결과로 출력한다.
#
# Author: 미정 <unknown@example.com>
# Created: 2026-05-28

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/log-utils.sh"
init_step_context "20" "Scheduler Policy Aware Trigger" "${1:-}" "${2:-}"
print_step_intent "정책 적용 후 Scheduler 배치 재확인" "policy-aware trigger 이후 Pod schedulerName/nodeName 확인" "pod/<pod-name>" "kubectl get pod <pod> -o wide" "after scheduler state observed"
print_after_context
pod="$(find_workload_pod "${STEP_WORKLOAD}" "${STEP_NAMESPACE}")"
if [ -n "${pod}" ] && [ -n "${STEP_NAMESPACE}" ]; then
  scheduler="$(kubectl get pod "${pod}" -n "${STEP_NAMESPACE}" -o jsonpath='{.spec.schedulerName}' 2>/dev/null || true)"
  node="$(kubectl get pod "${pod}" -n "${STEP_NAMESPACE}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
fi
print_kv "workload" "${STEP_WORKLOAD:-UNKNOWN}"
print_kv "namespace" "${STEP_NAMESPACE:-UNKNOWN}"
print_kv "pod" "${pod:-SKIP_NOT_FOUND}"
print_kv "scheduler" "${scheduler:-UNKNOWN}"
print_kv "selected_node" "${node:-UNKNOWN}"
[ -n "${pod}" ] && print_raw_block "pod_wide" "$(capture_cmd "kubectl get pod ${pod} -n ${STEP_NAMESPACE} -o wide")" || print_kv "status" "⚠ SKIP_NOT_FOUND"
save_state scheduler "$([ -n "${node:-}" ] && echo "✓ scheduled / node=${node} / scheduler=${scheduler:-UNKNOWN}" || echo '⚠ pending')"
finish_step "20"
