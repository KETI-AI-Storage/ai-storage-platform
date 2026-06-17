#!/usr/bin/env bash
# 03-Kueue-workload-enqueue.sh는 KETI 오케스트레이션 단계 [03] Kueue Workload Enqueue 상태를 Kubernetes 결과로 출력한다.
#
# Author: 미정 <unknown@example.com>
# Created: 2026-05-28

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/log-utils.sh"
init_step_context "03" "Kueue Workload Enqueue" "${1:-}" "${2:-}"
print_step_intent \
  "Workload Queue / Admission 상태 확인" \
  "Kubeflow workload가 Kueue queue에 들어가고 admission되는지 확인" \
  "localqueue / clusterqueue / workload" \
  "kubectl get localqueue -A; kubectl get clusterqueue; kubectl get workload -A" \
  "queue/admission observed"
comp_ns="$(find_namespace "${KUEUE_NS_CANDIDATES[@]}")"
print_kv "namespace_source" "$([ -n "${comp_ns}" ] && echo 'auto-detected' || echo 'SKIP_NOT_FOUND')"
print_kv "namespace_detected" "${comp_ns:-SKIP_NOT_FOUND}"
print_commands_block "command" "kubectl get localqueue -A" "kubectl get clusterqueue" "kubectl get workload -A"
print_raw_block "localqueue" "$(capture_cmd 'kubectl get localqueue -A')"
print_raw_block "clusterqueue" "$(capture_cmd 'kubectl get clusterqueue')"
print_raw_block "workload" "$(capture_cmd 'kubectl get workload -A')"
admitted="$(kubectl get workload -A --no-headers 2>/dev/null | awk 'NR==1 {print $NF}' || true)"
if [ -n "${admitted}" ]; then
  print_kv "admission" "${admitted}"
  print_kv "result" "✓ queue observed / admitted=${admitted}"
  save_state kueue "✓ workload admitted"
else
  print_kv "status" "⚠ SKIP_EXTERNAL_DEPENDENCY"
  save_state kueue "SKIP_EXTERNAL_DEPENDENCY"
fi
finish_step "03"
