#!/usr/bin/env bash
# 11-Scheduling-Policy-Engine-generate.sh는 KETI 오케스트레이션 단계 [11] Scheduling Policy Engine Generate 상태를 Kubernetes 결과로 출력한다.
#
# Author: 미정 <unknown@example.com>
# Created: 2026-05-28

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/log-utils.sh"
init_step_context "11" "Policy Generation" "${1:-}" "${2:-}"
print_step_intent "SchedulingPolicy 생성/기존 여부 확인" "같은 workload 기준 SchedulingPolicy CR 또는 policy engine 산출 기록 확인" "SchedulingPolicy CR / deploy/scheduling-policy-engine" "kubectl api-resources; kubectl get schedulingpolicy -A; kubectl logs ai-storage-scheduler" "scheduling policy generation evidence checked"
comp_ns="$(find_resource_namespace scheduling-policy-engine)"
sched_ns="$(find_resource_namespace ai-storage-scheduler)"
scheduling_resource="$(kubectl api-resources --no-headers 2>/dev/null | awk 'tolower($1) ~ /schedulingpolic/ {print $1; exit}')"
scheduling_rows=""
[ -n "${scheduling_resource}" ] && scheduling_rows="$(kubectl get "${scheduling_resource}" -A --no-headers 2>/dev/null | grep -F "${STEP_WORKLOAD}" | grep -F "${STEP_NAMESPACE}" | tail -5 || true)"
print_kv "component" "scheduling-policy-engine"
print_kv "namespace_source" "$([ -n "${comp_ns}" ] && echo 'runtime-discovery' || echo 'SKIP_NOT_FOUND')"
print_kv "namespace_detected" "${comp_ns:-SKIP_NOT_FOUND}"
print_kv "target_workload" "${STEP_WORKLOAD:-UNKNOWN}"
print_kv "target_namespace" "${STEP_NAMESPACE:-UNKNOWN}"
[ -n "${comp_ns}" ] && print_raw_block "deploy" "$(capture_cmd "kubectl get deploy scheduling-policy-engine -n ${comp_ns}")"
if [ -n "${scheduling_rows}" ]; then
  print_kv "scheduling_policy_status" "✓ existing"
  print_raw_block "scheduling_policy" "${scheduling_rows}"
elif [ -n "${scheduling_resource}" ]; then
  print_kv "scheduling_policy_status" "⚠ not found for target"
else
  print_kv "scheduling_policy_status" "⚠ CRD not observed"
fi
if [ -n "${sched_ns}" ]; then
  print_commands_block "command" "kubectl logs -n ${sched_ns} deploy/ai-storage-scheduler --tail=2000 | grep -iE 'policy|score|filter|queue'"
  print_scheduler_logs_block "scheduler_logs" "${sched_ns}" "deploy/ai-storage-scheduler" 5 "scheduler-11.log" 'policy|score|filter|queue'
else
  print_scheduler_logs_block "scheduler_logs" "" "deploy/ai-storage-scheduler" 5 "scheduler-11.log" 'policy|score|filter|queue' "ai-storage-scheduler deployment not found"
fi
print_kv "component_status" "$([ -n "${comp_ns}" ] && echo '✓ engine observed' || echo '⚠ SKIP_NOT_FOUND')"
save_state scheduling_policy "$([ -n "${scheduling_rows}" ] && echo '✓ existing' || echo '⚠ not observed')"
save_state scheduling_policy_status "$([ -n "${scheduling_rows}" ] && echo '✓ existing' || echo '⚠ not observed')"
finish_step "11"
