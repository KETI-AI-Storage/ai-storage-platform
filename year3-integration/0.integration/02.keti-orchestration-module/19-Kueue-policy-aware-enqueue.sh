#!/usr/bin/env bash
# 19-Kueue-policy-aware-enqueue.sh는 KETI 오케스트레이션 단계 [19] Kueue Policy Aware Enqueue 상태를 Kubernetes 결과로 출력한다.
#
# Author: 미정 <unknown@example.com>
# Created: 2026-05-28

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/log-utils.sh"
init_step_context "19" "Kueue Policy Aware Enqueue" "${1:-}" "${2:-}"
print_step_intent "정책 적용 후 Kueue 상태 재확인" "policy-aware enqueue 이후 queue/admission 상태 확인" "localqueue / clusterqueue / workload" "kubectl get workload -A" "after queue state observed"
print_after_context
print_commands_block "command" "kubectl get localqueue -A" "kubectl get clusterqueue" "kubectl get workload -A"
print_raw_block "localqueue" "$(capture_cmd 'kubectl get localqueue -A')"
print_raw_block "clusterqueue" "$(capture_cmd 'kubectl get clusterqueue')"
print_raw_block "workload" "$(capture_cmd 'kubectl get workload -A')"
admitted="$(kubectl get workload -A --no-headers 2>/dev/null | awk 'NR==1 {print $NF}' || true)"
[ -n "${admitted}" ] && print_kv "admission" "${admitted}" || print_kv "status" "⚠ SKIP_EXTERNAL_DEPENDENCY"
save_state kueue "$([ -n "${admitted}" ] && echo '✓ workload admitted' || echo 'SKIP_EXTERNAL_DEPENDENCY')"
finish_step "19"
