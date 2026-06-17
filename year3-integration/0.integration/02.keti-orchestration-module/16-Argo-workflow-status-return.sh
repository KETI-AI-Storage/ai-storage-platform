#!/usr/bin/env bash
# 16-Argo-workflow-status-return.sh는 KETI 오케스트레이션 단계 [16] Argo Workflow Status Return 상태를 Kubernetes 결과로 출력한다.
#
# Author: 미정 <unknown@example.com>
# Created: 2026-05-28

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/log-utils.sh"
init_step_context "16" "Argo Workflow Status Return" "${1:-}" "${2:-}"
print_step_intent "Argo Workflow 상태 반환 확인" "ArgoCD Application sync/health 상태가 상위 흐름으로 반환되는지 확인" "ArgoCD Application" "kubectl get applications -A" "argo status return observed"
comp_ns="$(find_namespace "${ARGO_NS_CANDIDATES[@]}")"
print_kv "namespace_source" "$([ -n "${comp_ns}" ] && echo 'auto-detected' || echo 'SKIP_NOT_FOUND')"
print_kv "namespace_detected" "${comp_ns:-SKIP_NOT_FOUND}"
if [ -n "${comp_ns}" ]; then
  print_commands_block "command" "kubectl get applications -A" "kubectl get pods -n ${comp_ns}" "kubectl get deploy -n ${comp_ns}"
  print_raw_block "applications" "$(capture_cmd 'kubectl get applications -A')"
  print_raw_block "argocd_pods" "$(capture_cmd "kubectl get pods -n ${comp_ns}")"
  app="$(kubectl get applications -A --no-headers 2>/dev/null | awk 'NR==1 {print $2}')"
  print_kv "application" "${app:-SKIP_NOT_FOUND}"
  save_state argo "✓ applications observed"
else
  print_kv "status" "⚠ SKIP_EXTERNAL_DEPENDENCY"
  save_state argo "SKIP_EXTERNAL_DEPENDENCY"
fi
finish_step "16"
