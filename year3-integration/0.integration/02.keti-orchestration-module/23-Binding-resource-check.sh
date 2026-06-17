#!/usr/bin/env bash
# 23-Binding-resource-check.sh는 KETI 오케스트레이션 단계 [23] Placement Result Check 상태를 Kubernetes 결과로 출력한다.
#
# Author: 미정 <unknown@example.com>
# Created: 2026-05-28

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/log-utils.sh"
init_step_context "23" "Placement Result Check" "${1:-}" "${2:-}"
print_step_intent "배치 결과 읽기 전용 확인" "이미 스케줄된 Pod-Node, PVC-PV, Kueue admission 상태 확인" "pod/pvc/pv/workload" "kubectl get pod,pvc,pv,workload" "placement evidence checked"
pod="$(find_workload_pod "${STEP_WORKLOAD}" "${STEP_NAMESPACE}")"
print_kv "workload" "${STEP_WORKLOAD:-UNKNOWN}"
print_kv "namespace" "${STEP_NAMESPACE:-UNKNOWN}"
print_kv "pod" "${pod:-SKIP_NOT_FOUND}"
if [ -n "${pod}" ] && [ -n "${STEP_NAMESPACE}" ]; then
  node="$(kubectl get pod "${pod}" -n "${STEP_NAMESPACE}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
  pvc_bound="$(kubectl get pvc -n "${STEP_NAMESPACE}" --no-headers 2>/dev/null | awk '$2=="Bound"' | head -1)"
  kueue_line="$(kubectl get workload -n "${STEP_NAMESPACE}" --no-headers 2>/dev/null | grep -F "${STEP_WORKLOAD}" | head -1 || true)"
  if printf '%s\n' "${kueue_line}" | grep -qE 'True|Admitted|admitted'; then
    kueue_state="✓ True"
  elif [ -n "${kueue_line}" ]; then
    kueue_state="⚠ observed / admitted unknown"
  else
    kueue_state="⚠ workload not found"
  fi

  pod_node_out="$(capture_cmd "kubectl get pod ${pod} -n ${STEP_NAMESPACE} -o wide")"
  pvc_out="$(capture_cmd "kubectl get pvc -n ${STEP_NAMESPACE}")"
  pv_out="$(capture_cmd "kubectl get pv")"
  pvc_pv_out="$(printf '%s\n%s\n' "${pvc_out}" "${pv_out}")"
  kueue_out="$(capture_cmd "kubectl get workload -A")"

  print_kv "pod_node_assigned" "$([ -n "${node}" ] && echo "✓ ${node}" || echo "⚠ node not assigned")"
  print_kv "pvc_pv_bound" "$([ -n "${pvc_bound}" ] && echo "✓ Bound" || echo "⚠ bound pvc not found")"
  print_kv "kueue_admitted" "${kueue_state}"
  print_separator
  print_commands_block "command" \
    "kubectl get pod ${pod} -n ${STEP_NAMESPACE} -o wide" \
    "kubectl get pvc -n ${STEP_NAMESPACE}" \
    "kubectl get pv" \
    "kubectl get workload -A"
  print_separator
  print_limited_raw_block "pod_node_assignment" "${pod_node_out}" 5 "pod-node-assignment.txt"
  print_limited_raw_block "pvc_pv_status" "${pvc_pv_out}" 5 "pvc-pv-status.txt"
  print_limited_raw_block "kueue_admission" "${kueue_out}" 5 "kueue-admission.txt"
  if [ -n "${node}" ] && [ -n "${pvc_bound}" ] && printf '%s' "${kueue_state}" | grep -q '✓'; then
    placement_msg="✓ pod assigned / pvc bound / queue admitted"
  elif [ -n "${node}" ] && [ -n "${pvc_bound}" ]; then
    placement_msg="⚠ pod assigned / pvc bound / queue admission not confirmed"
  else
    placement_msg="⚠ placement evidence incomplete"
  fi
  print_kv "placement_check" "${placement_msg}"
  save_state binding "${placement_msg}"
else
  print_kv "status" "⚠ SKIP_NOT_FOUND"
  print_kv_warn "placement_check" "⚠ placement not checked"
  print_kv_warn "reason" "target pod not found"
  save_state binding "⚠ placement not checked / target pod not found"
fi
finish_step "23"
