#!/usr/bin/env bash
# 02-Kubeflow-pipeline-run.sh는 KETI 오케스트레이션 단계 [02] Kubeflow Pipeline Run 상태와
# Kubeflow 대시보드 접속용 포트포워딩(localhost:8084)을 함께 수행한다.
#
# 포트포워딩은 ensure_kubeflow_web_access에서 자동으로 처리되며,
# 후보 service(istio-ingressgateway > ml-pipeline-ui > centraldashboard) 중 가장 먼저
# 발견되는 항목을 사용한다. 기존 port-forward가 떠 있으면 재사용한다.
#
# Author: 미정 <unknown@example.com>
# Created: 2026-05-28

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/log-utils.sh"
ensure_kubeflow_web_access
init_step_context "02" "Kubeflow Pipeline Run" "${1:-}" "${2:-}"
print_step_intent \
  "Kubeflow Pipeline / Workflow 상태 확인" \
  "Data Preprocessing → Model Development → Training → Hyperparameter Tuning → Serving 파이프라인 경로 확인" \
  "workflow / pipeline / ml-pipeline-ui" \
  "kubectl get pods -n <kubeflow-ns>; kubectl get workflow -A" \
  "pipeline core components observed"
comp_ns="$(find_namespace "${KUBEFLOW_NS_CANDIDATES[@]}")"
print_kv "namespace_source" "$([ -n "${comp_ns}" ] && echo 'auto-detected' || echo 'SKIP_NOT_FOUND')"
print_kv "namespace_detected" "${comp_ns:-SKIP_NOT_FOUND}"
if [ -n "${comp_ns}" ]; then
  full_pods_file="${LOG_DIR}/kubeflow-pods-full-02.log"
  kubectl get pods -n "${comp_ns}" > "${full_pods_file}" 2>&1 || true
  core_pods="$(kubectl get pods -n "${comp_ns}" 2>/dev/null | awk 'NR==1 || /ml-pipeline|ml-pipeline-ui|workflow-controller|training-operator|kserve-controller-manager|centraldashboard/' | sed -n '1,9p')"
  print_commands_block "command" \
    "kubectl get pods -n ${comp_ns} | grep -E 'ml-pipeline|ml-pipeline-ui|workflow-controller|training-operator|kserve-controller-manager|centraldashboard'" \
    "kubectl get workflow -A"
  print_raw_block "kubeflow_core_pods" "${core_pods}"
  print_kv "full_log_file" "${full_pods_file#${MODULE_DIR}/}"
  print_raw_block "workflows" "$(capture_cmd 'kubectl get workflow -A')"
  print_kv "result" "✓ pipeline run observed"
  save_state kubeflow "✓ pipeline run observed"
else
  print_kv "status" "⚠ SKIP_EXTERNAL_DEPENDENCY"
  save_state kubeflow "SKIP_EXTERNAL_DEPENDENCY"
fi
finish_step "02"
