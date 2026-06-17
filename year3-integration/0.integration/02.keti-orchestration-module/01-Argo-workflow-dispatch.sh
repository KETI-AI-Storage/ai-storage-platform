#!/usr/bin/env bash
# 01-Argo-workflow-dispatch.sh는 KETI 오케스트레이션 단계 [01] Argo Workflow Dispatch 상태와
# Argo 대시보드 접속용 포트포워딩(localhost:8080)을 함께 수행한다.
#
# 포트포워딩은 ensure_argo_web_access에서 자동으로 처리되며,
# 기존 kubectl port-forward 프로세스가 이미 떠 있으면 재사용한다.
#
# Author: 미정 <unknown@example.com>
# Created: 2026-05-28

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/log-utils.sh"
ensure_argo_web_access
init_step_context "01" "Argo Workflow Dispatch" "${1:-}" "${2:-}"
print_step_intent \
  "GitOps Application 상태 확인" \
  "Git Repo → Application → ArgoCD Controller → Manifest Generation → Sync Apply 흐름 확인" \
  "ArgoCD Application" \
  "kubectl get applications -A" \
  "applications/sync/health observed"
comp_ns="$(find_namespace "${ARGO_NS_CANDIDATES[@]}")"
print_kv "namespace_source" "$([ -n "${comp_ns}" ] && echo 'auto-detected' || echo 'SKIP_NOT_FOUND')"
print_kv "namespace_detected" "${comp_ns:-SKIP_NOT_FOUND}"
if [ -n "${comp_ns}" ]; then
  print_commands_block "command" "kubectl get applications -A" "kubectl get pods -n ${comp_ns}" "kubectl get deploy -n ${comp_ns}"
  print_raw_block "applications" "$(capture_cmd 'kubectl get applications -A')"
  print_raw_block "argocd_pods" "$(capture_cmd "kubectl get pods -n ${comp_ns}")"
  print_raw_block "argocd_deploy" "$(capture_cmd "kubectl get deploy -n ${comp_ns}")"
  app="$(kubectl get applications -A --no-headers 2>/dev/null | awk 'NR==1 {print $2}')"
  sync="$(kubectl get applications -A --no-headers 2>/dev/null | awk 'NR==1 {print $(NF-2)}')"
  health="$(kubectl get applications -A --no-headers 2>/dev/null | awk 'NR==1 {print $(NF-1)}')"
  print_kv "application" "${app:-SKIP_NOT_FOUND}"
  print_kv "sync_state" "${sync:-SKIP_NOT_FOUND}"
  print_kv "health_state" "${health:-SKIP_NOT_FOUND}"
  if printf '%s %s' "${sync}" "${health}" | grep -qiE 'degrad|outofsync|missing|unknown'; then
    print_kv_warn "result" "⚠ sync degraded"
    save_state argo "⚠ sync degraded"
  else
    print_kv "result" "✓ applications observed"
    save_state argo "✓ applications observed"
  fi
else
  print_kv "status" "⚠ SKIP_EXTERNAL_DEPENDENCY"
  save_state argo "SKIP_EXTERNAL_DEPENDENCY"
fi
finish_step "01"
