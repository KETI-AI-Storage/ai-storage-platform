#!/usr/bin/env bash
# 22-Selected-Orchestration-result.sh는 KETI 오케스트레이션 단계 [22] Selected Orchestration Result 상태를 Kubernetes 결과로 출력한다.
#
# Author: 미정 <unknown@example.com>
# Created: 2026-05-28

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/log-utils.sh"
init_step_context "22" "Selected Orchestration Result" "${1:-}" "${2:-}"
print_step_intent \
  "Apply Result 실제 리소스 변화 검증" \
  "선택 policy 적용 후 Kubernetes 리소스 값 변화 여부를 before/after 동일 항목으로 확인" \
  "orchestrationpolicy / target workload / affected resource" \
  "kubectl get orchestrationpolicy,target resource,hpa,pod,pvc,event" \
  "resource change based result"

before_file="${LOG_DIR}/before-orchestration-state.txt"
after_file="${LOG_DIR}/after-orchestration-state.txt"
policy_name="$(read_state selected_policy_name "$(read_state selected_policy none)")"
policy_ns="$(read_state selected_policy_ns '')"
policy_type="$(read_state selected_policy_type "$(selected_policy)")"
policy_failure_scope="$(read_state policy_failure_scope '')"
[ -f "${before_file}" ] || capture_orchestration_state before "${before_file}" "${policy_name}"

attempt=1
while [ "${attempt}" -le 6 ]; do
  capture_orchestration_state after "${after_file}" "${policy_name}"
  compute_orchestration_change "${policy_name}" "${policy_ns}" "${policy_type}" "${before_file}" "${after_file}"
  printf '%s' "${OC_CHANGED}" | grep -q 'true' && break
  [ "${policy_name}" = "none" ] && break
  sleep 5
  attempt=$((attempt + 1))
done

target_name="$(_state_kv "${after_file}" target_ref_name)"
[ -z "${target_name}" ] || [ "${target_name}" = "UNKNOWN" ] && target_name="$(_state_kv "${after_file}" workload)"
target_ns="$(_state_kv "${after_file}" target_ref_namespace)"
[ -z "${target_ns}" ] || [ "${target_ns}" = "UNKNOWN" ] && target_ns="$(_state_kv "${after_file}" workload_namespace)"
target_kind="$(_state_kv "${after_file}" target_ref_kind)"
[ -z "${target_kind}" ] || [ "${target_kind}" = "UNKNOWN" ] && target_kind="Deployment"
result_label="NO_CHANGE"
if printf '%s' "${OC_CHANGED}" | grep -q 'true'; then
  result_label="APPLIED"
elif [ "${policy_name}" = "none" ]; then
  result_label="${policy_failure_scope:-NO_POLICY}"
fi

print_kv "policy_name" "${policy_name}"
print_kv "orchestrator_apply_result" "$(read_state orchestrator_apply_result "$(read_state orchestrator '⚠ not observed')")"
print_kv "target_workload" "${target_name:-UNKNOWN}"
print_kv "target_namespace" "${target_ns:-UNKNOWN}"
print_kv "selected_action" "${policy_type:-none}"
print_kv "affected_resource" "${OC_TARGET_RESOURCE}"
print_kv "replicas_before" "$(_state_kv "${before_file}" deploy_replicas)"
print_kv "replicas_after" "$(_state_kv "${after_file}" deploy_replicas)"
print_kv "node_before" "$(_state_kv "${before_file}" pod_node)"
print_kv "node_after" "$(_state_kv "${after_file}" pod_node)"
print_kv "pvc_before" "$(_state_kv "${before_file}" pvc_name)/$(_state_kv "${before_file}" pvc_status)/$(_state_kv "${before_file}" pvc_capacity)"
print_kv "pvc_after" "$(_state_kv "${after_file}" pvc_name)/$(_state_kv "${after_file}" pvc_status)/$(_state_kv "${after_file}" pvc_capacity)"
print_kv "before_state" "${OC_BEFORE_STATE}"
print_kv "after_state" "${OC_AFTER_STATE}"
print_kv "resource_change_result" "${result_label}"
if [ -n "${policy_failure_scope}" ]; then
  print_kv "policy_failure_scope" "${policy_failure_scope}"
  print_kv "policy_failure_reason" "$(read_state policy_reason UNKNOWN)"
fi
print_kv "reason" "${OC_CHANGE_REASON}"
print_kv "wait_attempts" "${attempt}"

print_separator
case "${policy_type}" in
  autoscaling|scaling)
    print_kv "verify_policy" "autoscaling"
    print_raw_block "hpa_status" "$(capture_cmd "kubectl get hpa -A | grep -E '${target_name}|${policy_name}'")"
    print_raw_block "deployment" "$(capture_cmd "kubectl get deploy ${target_name} -n ${target_ns} -o wide")"
    print_raw_block "pods" "$(capture_cmd "kubectl get pod -n ${target_ns} -l app=${target_name} -o wide")"
    ;;
  migration)
    print_kv "verify_policy" "migration"
    print_kv "before_node" "$(_state_kv "${before_file}" pod_node)"
    print_kv "after_node" "$(_state_kv "${after_file}" pod_node)"
    print_raw_block "pods" "$(capture_cmd "kubectl get pod -n ${target_ns} -o wide | grep -E '${target_name}|migrat'")"
    ;;
  provisioning)
    print_kv "verify_policy" "provisioning"
    print_kv "before_pvc" "$(_state_kv "${before_file}" pvc_name)/$(_state_kv "${before_file}" pvc_status)/$(_state_kv "${before_file}" pvc_capacity)"
    print_kv "after_pvc" "$(_state_kv "${after_file}" pvc_name)/$(_state_kv "${after_file}" pvc_status)/$(_state_kv "${after_file}" pvc_capacity)"
    print_raw_block "pvc_pv_storageclass" "$(capture_cmd "kubectl get pvc,pv,storageclass -A | grep -E '${target_name}|${policy_name}|NAME'")"
    ;;
  caching)
    print_kv "verify_policy" "caching"
    print_raw_block "cache_pvc_pod" "$(capture_cmd "kubectl get pvc,pod -A | grep -Ei '${target_name}|${policy_name}|cache'")"
    print_raw_block "cache_events" "$(capture_cmd "kubectl get events -A --sort-by=.lastTimestamp | grep -Ei '${target_name}|${policy_name}|cache' | tail -10")"
    ;;
  preemption)
    print_kv "verify_policy" "preemption"
    print_raw_block "priority_pods" "$(capture_cmd "kubectl get pod -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,PRIORITY:.spec.priorityClassName,NODE:.spec.nodeName' | grep -E '${target_name}|${policy_name}|NAME'")"
    print_raw_block "eviction_events" "$(capture_cmd "kubectl get events -A --sort-by=.lastTimestamp | grep -Ei 'evict|preempt|victim|${target_name}|${policy_name}' | tail -10")"
    ;;
  loadbalance|loadbalancing)
    print_kv "verify_policy" "loadbalancing"
    print_kv "before_distribution" "$(_state_kv "${before_file}" node_counts)"
    print_kv "after_distribution" "$(_state_kv "${after_file}" node_counts)"
    print_raw_block "pod_distribution" "$(capture_cmd "kubectl get pod -A -o wide | grep -E '${target_name}|NAME'")"
    ;;
  *)
    print_kv "verify_policy" "${policy_type:-none}"
    print_raw_block "target_resource" "$(capture_cmd "kubectl get ${target_kind,,} ${target_name} -n ${target_ns} -o wide")"
    ;;
esac

{
  printf 'selected_policy=%s\n' "${policy_name}"
  printf 'policy_type=%s\n' "${policy_type}"
  printf 'target_workload=%s\n' "${target_name:-UNKNOWN}"
  printf 'target_namespace=%s\n' "${target_ns:-UNKNOWN}"
  printf 'affected_resource=%s\n' "${OC_TARGET_RESOURCE}"
  printf 'before_value=%s\n' "${OC_BEFORE_STATE}"
  printf 'after_value=%s\n' "${OC_AFTER_STATE}"
  printf 'result=%s\n' "${result_label}"
  printf 'orchestrator_apply_result=%s\n' "$(read_state orchestrator_apply_result "$(read_state orchestrator '⚠ not observed')")"
  printf 'resource_change_result=%s\n' "${result_label}"
  printf 'reason=%s\n' "${OC_CHANGE_REASON}"
} > "${LOG_DIR}/selected-orchestration-result.txt"

save_state target_resource "${OC_TARGET_RESOURCE}"
save_state compare_source "${OC_COMPARE_SOURCE}"
save_state before_state "${OC_BEFORE_STATE}"
save_state after_state "${OC_AFTER_STATE}"
save_state changed "${OC_CHANGED}"
save_state change_reason "${OC_CHANGE_REASON}"
save_state policy_result "$([ "${result_label}" = "APPLIED" ] && echo '✓ APPLIED' || echo "⚠ ${result_label} / ${OC_CHANGE_REASON}")"
save_state resource_change_result "$([ "${result_label}" = "APPLIED" ] && echo '✓ APPLIED' || echo "⚠ ${result_label} / ${OC_CHANGE_REASON}")"
finish_step "22"
