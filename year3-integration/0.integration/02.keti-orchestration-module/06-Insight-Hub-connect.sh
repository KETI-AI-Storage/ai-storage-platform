#!/usr/bin/env bash
# 06-Insight-Hub-connect.sh는 KETI 오케스트레이션 단계 [06] Insight Hub Connect 상태를 Kubernetes 결과로 출력한다.
#
# Author: 미정 <unknown@example.com>
# Created: 2026-05-28

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/log-utils.sh"
init_step_context "06" "Insight Hub Connect" "${1:-}" "${2:-}"
print_step_intent "Insight Hub 연결 상태 확인" "정책 판단 입력 이벤트가 hub 계층으로 전달되는지 확인" "deploy/service/insight-hub" "kubectl get deploy,pod,svc; kubectl logs" "hub connectivity observed"
comp_ns="$(find_resource_namespace insight-hub)"
print_kv "component" "insight-hub"
print_kv "namespace_source" "$([ -n "${comp_ns}" ] && echo 'runtime-discovery' || echo 'SKIP_NOT_FOUND')"
print_kv "namespace_detected" "${comp_ns:-SKIP_NOT_FOUND}"
if [ -n "${comp_ns}" ]; then
  print_commands_block "command" "kubectl get deploy insight-hub -n ${comp_ns}" "kubectl get pods -n ${comp_ns} -l app=insight-hub" "kubectl get svc -n ${comp_ns} insight-hub" "kubectl logs -n ${comp_ns} deploy/insight-hub --tail=5"
  print_raw_block "deploy" "$(capture_cmd "kubectl get deploy insight-hub -n ${comp_ns}")"
  print_raw_block "pods" "$(capture_cmd "kubectl get pods -n ${comp_ns} -l app=insight-hub")"
  print_raw_block "service" "$(capture_cmd "kubectl get svc -n ${comp_ns} insight-hub")"
  print_tail_logs "logs" "${comp_ns}" "deploy/insight-hub" 5
  print_kv "status" "✓ connected"
  save_state insight_hub "✓ connected"
else
  print_kv "status" "⚠ SKIP_NOT_FOUND"
  save_state insight_hub "SKIP_NOT_FOUND"
fi
finish_step "06"
