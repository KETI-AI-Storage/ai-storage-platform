#!/usr/bin/env bash
# 18-Kubeflow-policy-aware-run.sh는 KETI 오케스트레이션 단계 [18] Kubeflow Policy Aware Run 상태를 Kubernetes 결과로 출력한다.
#
# Author: 미정 <unknown@example.com>
# Created: 2026-05-28

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/log-utils.sh"
init_step_context "18" "Kubeflow Policy Aware Run" "${1:-}" "${2:-}"
print_step_intent "정책 적용 후 Kubeflow 상태 재확인" "policy-aware run 이후 Pipeline/Workflow 상태 확인" "workflow / ml-pipeline-ui" "kubectl get workflow -A" "after kubeflow state observed"
print_after_context
comp_ns="$(find_namespace "${KUBEFLOW_NS_CANDIDATES[@]}")"
print_kv "namespace_source" "$([ -n "${comp_ns}" ] && echo 'auto-detected' || echo 'SKIP_NOT_FOUND')"
print_kv "namespace_detected" "${comp_ns:-SKIP_NOT_FOUND}"
if [ -n "${comp_ns}" ]; then
  full_pods_file="${LOG_DIR}/kubeflow-pods-full-18.log"
  kubectl get pods -n "${comp_ns}" > "${full_pods_file}" 2>&1 || true
  core_pods="$(kubectl get pods -n "${comp_ns}" 2>/dev/null | awk 'NR==1 || /ml-pipeline|ml-pipeline-ui|workflow-controller|training-operator|kserve-controller-manager|centraldashboard/' | sed -n '1,9p')"
  print_raw_block "kubeflow_core_pods" "${core_pods}"
  print_kv "full_log_file" "${full_pods_file#${MODULE_DIR}/}"
  print_raw_block "workflows" "$(capture_cmd 'kubectl get workflow -A')"
  save_state kubeflow "✓ pipeline run observed"
else
  print_kv "status" "⚠ SKIP_EXTERNAL_DEPENDENCY"
  save_state kubeflow "SKIP_EXTERNAL_DEPENDENCY"
fi
finish_step "18"
