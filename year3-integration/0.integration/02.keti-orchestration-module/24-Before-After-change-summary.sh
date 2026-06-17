#!/usr/bin/env bash
# 24-Before-After-change-summary.sh는 KETI 오케스트레이션 단계 [24] Before After Change Summary 상태를 Kubernetes 결과로 출력한다.
#
# Author: 미정 <unknown@example.com>
# Created: 2026-05-28

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/log-utils.sh"
init_step_context "24" "Before After Change Summary" "${1:-}" "${2:-}"
print_step_intent "Before/After Kubernetes 리소스 변화 요약" "Decision Pipeline/Apply Result와 분리해 before/after 동일 리소스 항목만 비교" "before-after-change-summary.txt" "before-orchestration-state.txt / after-orchestration-state.txt" "resource-change summary"
sp="$(read_state selected_policy none)"
tres="$(read_state target_resource UNKNOWN)"
csrc="$(read_state compare_source UNKNOWN)"
bs="$(read_state before_state UNKNOWN)"
as="$(read_state after_state UNKNOWN)"
ch="$(read_state changed false)"
cr="$(read_state change_reason 'target resource change not observed')"
pres="$(read_state policy_result '⚠ not-triggered')"
print_kv "selected_policy" "${sp}"
print_kv "target_resource" "${tres}"
print_kv "compare_source" "${csrc}"
print_kv "before_state" "${bs}"
print_kv "after_state" "${as}"
print_kv "changed" "${ch}"
print_kv "change_reason" "${cr}"
print_kv "resource_change_result" "$(read_state resource_change_result "${pres}")"
print_separator
print_kv "storage_algorithm" "before=$(read_state before_storage_algorithm UNKNOWN) → after=$(read_state after_storage_algorithm UNKNOWN)"
print_kv "preprocessing_algo" "before=$(read_state before_preprocessing_algorithm UNKNOWN) → after=$(read_state after_preprocessing_algorithm UNKNOWN)"
print_kv "training_infer_algo" "before=$(read_state before_training_infer_algorithm UNKNOWN) → after=$(read_state after_training_infer_algorithm UNKNOWN)"
print_separator
print_label_line "Decision Pipeline"
print_kv "existing_forecast" "$(read_state existing_forecast '⚠ not observed')"
print_kv "current_forecast" "$(read_state current_forecast '⚠ not evaluated')"
print_kv "forecaster_candidates" "$(read_state forecaster_candidates 'candidate scores unavailable in API response')"
print_kv "selected_policy" "${sp}"
print_kv "selected_confidence" "$(read_state selected_confidence '<n/a>')"
print_kv "scheduling_policy_status" "$(read_state scheduling_policy_status '⚠ not observed')"
print_kv "orchestration_policy_status" "$(read_state orchestration_policy_status '⚠ not observed')"
print_kv "orchestrator_apply_result" "$(read_state orchestrator_apply_result '⚠ not observed')"
print_kv "binding" "$(read_state binding '⚠ placement not checked')"
{
  printf 'selected_policy=%s\n' "${sp}"
  printf 'target_resource=%s\n' "${tres}"
  printf 'compare_source=%s\n' "${csrc}"
  printf 'before_state=%s\n' "${bs}"
  printf 'after_state=%s\n' "${as}"
  printf 'changed=%s\n' "${ch}"
  printf 'change_reason=%s\n' "${cr}"
  printf 'resource_change_result=%s\n' "$(read_state resource_change_result "${pres}")"
  printf 'current_forecast=%s\n' "$(read_state current_forecast '⚠ not evaluated')"
  printf 'selected_confidence=%s\n' "$(read_state selected_confidence '<n/a>')"
  printf 'scheduling_policy_status=%s\n' "$(read_state scheduling_policy_status '⚠ not observed')"
  printf 'orchestration_policy_status=%s\n' "$(read_state orchestration_policy_status '⚠ not observed')"
  printf 'orchestrator_apply_result=%s\n' "$(read_state orchestrator_apply_result '⚠ not observed')"
  printf 'binding=%s\n' "$(read_state binding '⚠ binding not checked')"
  printf 'total_time=%s\n' "$(read_state total_time '00:00:00')"
} > "${LOG_DIR}/before-after-change-summary.txt"
print_separator
print_orchestration_compare_box
finish_step "24"
