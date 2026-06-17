#!/usr/bin/env bash
# 13-Orchestrator-policy-apply.sh는 KETI 오케스트레이션 단계 [13] Orchestrator Policy Apply 상태를 Kubernetes 결과로 출력한다.
#
# Author: 미정 <unknown@example.com>
# Created: 2026-05-28

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/log-utils.sh"
init_step_context "13" "Apply Result" "${1:-}" "${2:-}"
print_step_intent "Orchestrator 적용 호출/관측 결과 확인" "선택된 policy를 처리할 API/service/log와 실제 executor 호출 여부 확인" "orchestration CRD / orchestrator service / orchestrator logs" "kubectl get crd,svc; kubectl logs -A" "orchestrator apply evidence checked"
print_commands_block "command" "kubectl get crd | grep -i policy" "kubectl get crd | grep -i orchestration" "kubectl get svc -A | grep -i orchestrator" "kubectl logs -A --tail=200 | grep -i orchestrator"
print_raw_block "policy_crd" "$(capture_cmd 'kubectl get crd | grep -i policy')"
print_raw_block "orchestration_crd" "$(capture_cmd 'kubectl get crd | grep -i orchestration')"
orchestrator_svc="$(kubectl get svc -A 2>/dev/null | grep -iE 'orchestrator|orchestration' | tail -5 || true)"
orch_logs="$(timeout 8s kubectl logs -A --tail=200 2>/dev/null | grep -iE 'orchestrator|executor|apply|autoscal|migration|provision|cache|preempt|loadbal' | tail -20 || true)"
print_raw_block "orchestrator_service" "${orchestrator_svc}"
print_raw_block "orchestrator_logs" "${orch_logs}"
policy_name="$(read_state selected_policy none)"
policy="$(read_state selected_policy_type none)"
[ "${policy_name}" = "none" ] && policy="none"
if [ "${policy_name}" = "none" ]; then
  apply_result="⚠ not invoked / no policy selected"
elif [ -n "${orch_logs}" ]; then
  apply_result="✓ executor observed / policy=${policy}"
else
  apply_result="⚠ policy selected but executor log not observed"
fi
print_kv "selected_policy" "${policy_name}"
print_kv "policy_type" "${policy:-none}"
print_kv "orchestrator_api_call" "$([ -n "${orchestrator_svc}" ] && echo 'service observed / direct API call not used by this step' || echo '⚠ service not found')"
print_kv "orchestrator_apply_result" "${apply_result}"
save_state orchestrator "${apply_result}"
save_state orchestrator_apply_result "${apply_result}"
finish_step "13"
