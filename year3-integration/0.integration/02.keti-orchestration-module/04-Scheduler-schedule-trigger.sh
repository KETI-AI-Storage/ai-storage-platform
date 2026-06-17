#!/usr/bin/env bash
# 04-Scheduler-schedule-trigger.sh는 KETI 오케스트레이션 단계 [04] Scheduler Schedule Trigger 상태를 Kubernetes 결과로 출력한다.
#
# Author: 미정 <unknown@example.com>
# Created: 2026-05-28

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/log-utils.sh"
init_step_context "04" "Scheduler Schedule Trigger" "${1:-}" "${2:-}"
print_step_intent \
  "AI Storage Scheduler 배치 결과 확인" \
  "Kueue admission 이후 Pod가 scheduler에 의해 node에 배치되는지 확인" \
  "pod/<pod-name>" \
  "kubectl get pod <pod> -n <namespace> -o wide" \
  "scheduled node/scheduler observed"
print_kv "workload" "${STEP_WORKLOAD:-UNKNOWN}"
print_kv "workload_source" "${STEP_WORKLOAD_SOURCE}"
print_kv "namespace" "${STEP_NAMESPACE:-UNKNOWN}"
print_kv "namespace_source" "${STEP_NAMESPACE_SOURCE}"
pod="$(find_workload_pod "${STEP_WORKLOAD}" "${STEP_NAMESPACE}")"
if [ -n "${pod}" ] && [ -n "${STEP_NAMESPACE}" ]; then
  scheduler="$(kubectl get pod "${pod}" -n "${STEP_NAMESPACE}" -o jsonpath='{.spec.schedulerName}' 2>/dev/null || true)"
  node="$(kubectl get pod "${pod}" -n "${STEP_NAMESPACE}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
fi
print_kv "pod" "${pod:-SKIP_NOT_FOUND}"
print_kv "scheduler" "${scheduler:-UNKNOWN}"
print_kv "selected_node" "${node:-UNKNOWN}"
if [ -n "${pod}" ] && [ -n "${STEP_NAMESPACE}" ]; then
  print_commands_block "command" \
    "kubectl get pod ${pod} -n ${STEP_NAMESPACE} -o wide" \
    "kubectl get events -n ${STEP_NAMESPACE} --sort-by=.metadata.creationTimestamp"
  print_raw_block "pod_wide" "$(capture_cmd "kubectl get pod ${pod} -n ${STEP_NAMESPACE} -o wide")"
  print_raw_block "events" "$(capture_cmd "kubectl get events -n ${STEP_NAMESPACE} --sort-by=.metadata.creationTimestamp | tail -20")"
else
  print_kv "status" "⚠ SKIP_NOT_FOUND"
fi
save_state scheduler "$([ -n "${node:-}" ] && echo "✓ scheduled / node=${node} / scheduler=${scheduler:-UNKNOWN}" || echo '⚠ pending')"
finish_step "04"
