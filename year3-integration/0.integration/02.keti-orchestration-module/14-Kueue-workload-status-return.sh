#!/usr/bin/env bash
# 14-Kueue-workload-status-return.sh는 KETI 오케스트레이션 단계 [14] Kueue Workload Status Return 상태를 Kubernetes 결과로 출력한다.
#
# Author: 미정 <unknown@example.com>
# Created: 2026-05-28

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/log-utils.sh"
init_step_context "14" "Kueue Workload Status Return" "${1:-}" "${2:-}"
print_step_intent "Kueue Workload 상태 반환 확인" "queue/admission 상태가 상위 흐름으로 반환되는지 확인" "workload/localqueue/clusterqueue" "kubectl get workload -A" "workload return observed"
print_commands_block "command" "kubectl get localqueue -A" "kubectl get clusterqueue" "kubectl get workload -A"
print_raw_block "localqueue" "$(capture_cmd 'kubectl get localqueue -A')"
print_raw_block "clusterqueue" "$(capture_cmd 'kubectl get clusterqueue')"
print_raw_block "workload" "$(capture_cmd 'kubectl get workload -A')"
admitted="$(kubectl get workload -A --no-headers 2>/dev/null | awk 'NR==1 {print $NF}' || true)"
[ -n "${admitted}" ] && print_kv "admission" "${admitted}" || print_kv "status" "⚠ SKIP_EXTERNAL_DEPENDENCY"
save_state kueue "$([ -n "${admitted}" ] && echo '✓ workload admitted' || echo 'SKIP_EXTERNAL_DEPENDENCY')"
finish_step "14"
