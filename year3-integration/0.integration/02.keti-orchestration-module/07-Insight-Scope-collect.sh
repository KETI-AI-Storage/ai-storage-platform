#!/usr/bin/env bash
# 07-Insight-Scope-collect.sh는 KETI 오케스트레이션 단계 [07] Insight Scope Collect 상태를 Kubernetes 결과로 출력한다.
#
# Author: 미정 <unknown@example.com>
# Created: 2026-05-28

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/log-utils.sh"
init_step_context "07" "Insight Scope Collect" "${1:-}" "${2:-}"
print_step_intent "Insight Scope 수집 상태 확인" "service/pod/controller 계층에서 정책 판단용 관측 데이터가 보이는지 확인" "deploy/sts/ds/pod/svc/insight-scope" "kubectl get deploy,sts,ds,pod,svc -A | grep insight-scope" "scope runtime resource observed"
scope_inventory="$(kubectl get deploy,sts,ds,pod,svc -A 2>/dev/null | grep insight-scope || true)"
scope_deploy="$(printf '%s\n' "${scope_inventory}" | awk '$2 ~ /^deployment.apps\/insight-scope$/ {print $1; exit}')"
scope_service="$(printf '%s\n' "${scope_inventory}" | awk '$2 ~ /^service\/insight-scope$/ {print $1; exit}')"
comp_ns="$(find_resource_namespace insight-scope)"
[ -z "${comp_ns}" ] && comp_ns="${scope_service:-${scope_deploy:-}}"
print_kv "component" "insight-scope"
print_kv "namespace_source" "$([ -n "${comp_ns}" ] && echo 'runtime-discovery' || echo 'SKIP_NOT_FOUND')"
print_kv "namespace_detected" "${comp_ns:-SKIP_NOT_FOUND}"
print_commands_block "command" "kubectl get deploy,sts,ds,pod,svc -A | grep insight-scope"
print_raw_block "resources" "${scope_inventory}"
if [ -n "${comp_ns}" ] && kubectl get deploy insight-scope -n "${comp_ns}" >/dev/null 2>&1; then
  print_raw_block "logs" "$(capture_cmd "kubectl logs -n ${comp_ns} deploy/insight-scope --tail=80")"
  print_kv "status" "✓ observed-deploy"
  save_state insight_scope "✓ observed-deploy"
elif [ -n "${comp_ns}" ] && kubectl get svc insight-scope -n "${comp_ns}" >/dev/null 2>&1; then
  print_kv "status" "⚠ deploy not found / service observed"
  save_state insight_scope "⚠ deploy not found / service observed"
else
  print_kv "status" "⚠ SKIP_NOT_FOUND"
  save_state insight_scope "SKIP_NOT_FOUND"
fi
finish_step "07"
