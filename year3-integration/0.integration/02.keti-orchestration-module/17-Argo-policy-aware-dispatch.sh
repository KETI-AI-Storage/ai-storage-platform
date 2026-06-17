#!/usr/bin/env bash
# 17-Argo-policy-aware-dispatch.sh는 KETI 오케스트레이션 단계 [17] Argo Policy Aware Dispatch 상태를 Kubernetes 결과로 출력한다.
#
# Author: 미정 <unknown@example.com>
# Created: 2026-05-28

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/log-utils.sh"
init_step_context "17" "Argo Policy Aware Dispatch" "${1:-}" "${2:-}"
print_step_intent "정책 적용 후 Argo 상태 재확인" "policy-aware dispatch 이후 GitOps Application 상태 확인" "ArgoCD Application" "kubectl get applications -A" "after argo state observed"
print_after_context
comp_ns="$(find_namespace "${ARGO_NS_CANDIDATES[@]}")"
print_kv "namespace_source" "$([ -n "${comp_ns}" ] && echo 'auto-detected' || echo 'SKIP_NOT_FOUND')"
print_kv "namespace_detected" "${comp_ns:-SKIP_NOT_FOUND}"
if [ -n "${comp_ns}" ]; then
  print_raw_block "applications" "$(capture_cmd 'kubectl get applications -A')"
  print_raw_block "argocd_pods" "$(capture_cmd "kubectl get pods -n ${comp_ns}")"
  save_state argo "✓ applications observed"
else
  print_kv "status" "⚠ SKIP_EXTERNAL_DEPENDENCY"
  save_state argo "SKIP_EXTERNAL_DEPENDENCY"
fi
finish_step "17"
