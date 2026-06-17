#!/usr/bin/env bash
# 05-Algorithm-before-state.sh는 KETI 오케스트레이션 단계 [05] Algorithm Before State 상태를 Kubernetes 결과로 출력한다.
#
# Author: 미정 <unknown@example.com>
# Created: 2026-05-28

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/log-utils.sh"
init_step_context "05" "Algorithm Before State" "${1:-}" "${2:-}"
print_step_intent \
  "정책 적용 전 스케줄러 알고리즘 상태 캡처" \
  "filter/score/binding 로그와 node/storageclass/queue/resource-fit 기준 before 상태 저장" \
  "scheduler-before.log / before-algorithm-state.txt" \
  "kubectl logs deploy/ai-storage-scheduler; kubectl get pod,pvc,localqueue,events" \
  "before scheduler algorithm evidence captured"

pod="$(find_workload_pod "${STEP_WORKLOAD}" "${STEP_NAMESPACE}")"
node=""; scheduler=""; storageclass=""; pvc_status=""; queue=""; events=""
replicas=""; ready_replicas=""; pod_count=""; pvc_name=""
if [ -n "${pod}" ] && [ -n "${STEP_NAMESPACE}" ]; then
  node="$(kubectl get pod "${pod}" -n "${STEP_NAMESPACE}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
  scheduler="$(kubectl get pod "${pod}" -n "${STEP_NAMESPACE}" -o jsonpath='{.spec.schedulerName}' 2>/dev/null || true)"
  events="$(kubectl get events -n "${STEP_NAMESPACE}" --sort-by=.metadata.creationTimestamp 2>/dev/null | grep -iE "${pod}|Scheduled|affinity|toleration|image|volume|pvc|queue" | tail -5 || true)"
  storageclass="$(kubectl get pvc -n "${STEP_NAMESPACE}" --no-headers 2>/dev/null | awk 'NR==1 {print $6}')"
  pvc_status="$(kubectl get pvc -n "${STEP_NAMESPACE}" --no-headers 2>/dev/null | awk 'NR==1 {print $2}')"
  pvc_name="$(kubectl get pvc -n "${STEP_NAMESPACE}" --no-headers 2>/dev/null | awk 'NR==1 {print $1}')"
  replicas="$(kubectl get deploy "${STEP_WORKLOAD}" -n "${STEP_NAMESPACE}" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
  ready_replicas="$(kubectl get deploy "${STEP_WORKLOAD}" -n "${STEP_NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  pod_count="$(kubectl get pod -n "${STEP_NAMESPACE}" -l "app=${STEP_WORKLOAD}" --no-headers 2>/dev/null | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
fi
queue="$(kubectl get localqueue -A --no-headers 2>/dev/null | awk 'NR==1 {print $2 "/" $1}')"
scheduler_ns="$(find_resource_namespace ai-storage-scheduler)"
scheduler_log="${LOG_DIR}/scheduler-before.log"
if [ -n "${scheduler_ns}" ]; then
  kubectl logs -n "${scheduler_ns}" deploy/ai-storage-scheduler --tail=20000 > "${scheduler_log}" 2>&1 || true
else
  : > "${scheduler_log}"
fi
target_pattern="${pod:-${STEP_WORKLOAD}}"
if ! grep -F "${target_pattern}" "${scheduler_log}" >/dev/null 2>&1 && [ -n "${STEP_WORKLOAD}" ]; then
  target_pattern="${STEP_WORKLOAD}"
fi

print_kv "workload" "${STEP_WORKLOAD:-UNKNOWN}"
print_kv "namespace" "${STEP_NAMESPACE:-UNKNOWN}"
print_kv "pod" "${pod:-SKIP_NOT_FOUND}"
print_kv "scheduler" "${scheduler:-UNKNOWN}"
print_kv "selected_node" "${node:-UNKNOWN}"
print_kv "replicas" "${replicas:-UNKNOWN}"
print_kv "ready_replicas" "${ready_replicas:-0}"
print_kv "pod_count" "${pod_count:-0}"
print_kv "pvc" "${pvc_name:-UNKNOWN}"
print_kv "storageClass" "${storageclass:-UNKNOWN}"
print_kv "current_placement" "pod=${pod:-UNKNOWN} / node=${node:-UNKNOWN}"
print_existing_policy_history "${STEP_WORKLOAD}" "${STEP_NAMESPACE}"
print_kv "scheduler_log_file" "${scheduler_log#${MODULE_DIR}/}"
print_kv "scheduler_log_query" "pod_or_workload=${target_pattern:-UNKNOWN} / tail=20000"
print_separator
print_scheduler_algorithm_summary "${scheduler_log}" "${target_pattern}"
print_raw_block "events" "${events}"

{
  printf 'phase=before\n'
  printf 'workload=%s\n' "${STEP_WORKLOAD:-UNKNOWN}"
  printf 'namespace=%s\n' "${STEP_NAMESPACE:-UNKNOWN}"
  printf 'pod=%s\n' "${pod:-UNKNOWN}"
  printf 'storage_algorithm=%s/%s/%s\n' "${node:-UNKNOWN}" "${storageclass:-UNKNOWN}" "${pvc_status:-UNKNOWN}"
  printf 'preprocessing_algorithm=%s/%s\n' "${queue:-UNKNOWN}" "${node:-UNKNOWN}"
  printf 'training_inference_algorithm=%s/resource-fit-%s\n' "${node:-UNKNOWN}" "$([ -n "${node}" ] && echo ok || echo UNKNOWN)"
  printf 'scheduler=%s\n' "${scheduler:-UNKNOWN}"
  printf 'scheduler_log_file=%s\n' "${scheduler_log}"
} > "${LOG_DIR}/before-algorithm-state.txt"

save_state before_storage_algorithm "${node:-UNKNOWN}/${storageclass:-UNKNOWN}"
save_state before_preprocessing_algorithm "${queue:-UNKNOWN}/${node:-UNKNOWN}"
save_state before_training_infer_algorithm "${node:-UNKNOWN}/resource-fit-$([ -n "${node}" ] && echo ok || echo UNKNOWN)"
finish_step "05"
