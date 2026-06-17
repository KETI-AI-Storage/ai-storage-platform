#!/usr/bin/env bash
# 08-Insight-Trace-record.sh는 KETI 오케스트레이션 단계 [08] Insight Trace Record 상태를 Kubernetes 결과로 출력한다.
#
# Author: 미정 <unknown@example.com>
# Created: 2026-05-28

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/log-utils.sh"
init_step_context "08" "Insight Trace Record" "${1:-}" "${2:-}"
print_step_intent "Insight Trace 기록 상태 확인" "정책 판단 이벤트와 trace_id가 로그에 남는지 확인" "deploy/insight-trace" "kubectl logs -A --tail=200" "trace evidence observed"
comp_ns="$(find_resource_namespace insight-trace)"
print_kv "component" "insight-trace"
print_kv "namespace_source" "$([ -n "${comp_ns}" ] && echo 'runtime-discovery' || echo 'SKIP_NOT_FOUND')"
print_kv "namespace_detected" "${comp_ns:-SKIP_NOT_FOUND}"
if [ -n "${comp_ns}" ]; then
  print_commands_block "command" "kubectl get deploy insight-trace -n ${comp_ns}" "kubectl logs -n ${comp_ns} deploy/insight-trace --tail=5"
  print_raw_block "deploy" "$(capture_cmd "kubectl get deploy insight-trace -n ${comp_ns}")"
  print_tail_logs "logs" "${comp_ns}" "deploy/insight-trace" 5
fi
trace_id="$(kubectl logs -A --tail=200 2>/dev/null | grep -iE 'trace[-_ ]?id|trace_id' | tail -1 | awk '{print $NF}' || true)"
[ -n "${trace_id}" ] && print_kv "trace_id" "${trace_id}" || print_kv_warn "trace_id" "⚠ trace id not found in latest 200 log lines"
print_kv "status" "$([ -n "${comp_ns}" ] && echo '✓ recorded' || echo '⚠ SKIP_NOT_FOUND')"
save_state insight_trace "$([ -n "${comp_ns}" ] && echo '✓ recorded' || echo 'SKIP_NOT_FOUND')"
finish_step "08"
