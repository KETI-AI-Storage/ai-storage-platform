#!/usr/bin/env bash
# AI Storage 통합 패키지 설치 검증 스크립트.
#
# Author: 미정 <unknown@example.com>
# Created: 2026-05-28
#
# 설계 의도:
# - 클러스터 상태를 변경하지 않고 검증만 수행한다 (kubectl get/describe만 사용).
# - 실패한 항목이 있어도 전체를 끝까지 돌려 사용자에게 한 번에 누락 항목을 보여준다.

set -uo pipefail

TARGET_NAMESPACE="${TARGET_NAMESPACE:-ai-storage-workloads}"
WEBHOOK_NAMESPACE="${WEBHOOK_NAMESPACE:-keti}"
APPLY_WORKLOAD_EXAMPLES="${APPLY_WORKLOAD_EXAMPLES:-false}"

PASS=0
FAIL=0

ok()   { printf '  [OK]   %s\n' "$*"; PASS=$((PASS+1)); }
ng()   { printf '  [FAIL] %s\n' "$*"; FAIL=$((FAIL+1)); }
info() { printf '  [INFO] %s\n' "$*"; }
section() { printf '\n=== %s ===\n' "$*"; }

check_namespace_label() {
  section "Namespace label"
  local got
  got="$(kubectl get namespace "${TARGET_NAMESPACE}" -o jsonpath='{.metadata.labels.keti-ai-storage-injection}' 2>/dev/null || true)"
  if [[ "${got}" == "enabled" ]]; then
    ok "${TARGET_NAMESPACE} 의 keti-ai-storage-injection=enabled"
  else
    ng "${TARGET_NAMESPACE} 의 keti-ai-storage-injection 라벨 누락 (got='${got}')"
  fi
}

check_storageclass() {
  section "StorageClass (storage-l1/l2/l3/s3)"
  for sc in storage-l1 storage-l2 storage-l3 storage-s3; do
    if kubectl get storageclass "${sc}" >/dev/null 2>&1; then
      ok "${sc} 존재"
    else
      ng "${sc} 없음"
    fi
  done
}

check_deployment() {
  local ns="$1" name="$2"
  local ready desired
  ready="$(kubectl get deploy "${name}" -n "${ns}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  desired="$(kubectl get deploy "${name}" -n "${ns}" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
  if [[ -z "${desired}" ]]; then
    ng "${ns}/${name} deployment 가 없음"
    return
  fi
  if [[ "${ready:-0}" == "${desired}" ]]; then
    ok "${ns}/${name} ready=${ready}/${desired}"
  else
    ng "${ns}/${name} ready=${ready:-0}/${desired}"
  fi
}

check_core_components() {
  section "Core deployments"
  check_deployment "${WEBHOOK_NAMESPACE}" ai-storage-webhook
  check_deployment "${WEBHOOK_NAMESPACE}" ai-storage-scheduler
  check_deployment "kube-system" ai-storage-orchestrator
}

check_mutating_webhook() {
  section "MutatingWebhookConfiguration"
  if kubectl get mutatingwebhookconfiguration ai-storage-webhook >/dev/null 2>&1; then
    ok "ai-storage-webhook MutatingWebhookConfiguration 존재"
    local count
    count="$(kubectl get mutatingwebhookconfiguration ai-storage-webhook -o jsonpath='{range .webhooks[*]}{.name}{"\n"}{end}' | wc -l)"
    info "등록된 webhook 수: ${count} (pod-injection + pvc-injection 으로 2 가 정상)"
  else
    ng "ai-storage-webhook MutatingWebhookConfiguration 없음"
  fi
}

check_gpu_nodes() {
  section "GPU node (nvidia.com/gpu)"
  local gpu_nodes
  gpu_nodes="$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' | awk -F'\t' '$2!="" && $2!="0"')"
  if [[ -z "${gpu_nodes}" ]]; then
    info "nvidia.com/gpu allocatable > 0 노드가 없음. GPU 워크로드는 건너뛸 것을 권장한다."
  else
    ok "GPU 노드 감지:"
    printf '%s\n' "${gpu_nodes}" | sed 's/^/      /'
    info "확인 명령:"
    info "  kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{\"\\t\"}{.status.allocatable.nvidia\\.com/gpu}{\"\\n\"}{end}'"
  fi
}

check_workload_examples() {
  section "Workload 예제 PVC tier (APPLY_WORKLOAD_EXAMPLES=${APPLY_WORKLOAD_EXAMPLES})"
  if [[ "${APPLY_WORKLOAD_EXAMPLES}" != "true" ]]; then
    info "워크로드 예제 미적용 모드 → PVC tier 확인 건너뜀."
    info "예제 적용 후 다음 명령으로 selected-tier 를 확인할 수 있다:"
    info "  kubectl get pvc -n ${TARGET_NAMESPACE} \\"
    info "    -o custom-columns=NAME:.metadata.name,SC:.spec.storageClassName,TIER:.metadata.annotations.ai-storage/selected-tier"
    return
  fi
  if kubectl get pvc -n "${TARGET_NAMESPACE}" >/dev/null 2>&1; then
    ok "${TARGET_NAMESPACE} 의 PVC 목록 (selected-tier):"
    kubectl get pvc -n "${TARGET_NAMESPACE}" \
      -o custom-columns=NAME:.metadata.name,SC:.spec.storageClassName,TIER:.metadata.annotations.ai-storage/selected-tier \
      | sed 's/^/      /'
  else
    ng "${TARGET_NAMESPACE} PVC 조회 실패"
  fi
}

main() {
  command -v kubectl >/dev/null 2>&1 || { echo "kubectl 이 필요합니다." >&2; exit 1; }
  check_namespace_label
  check_storageclass
  check_core_components
  check_mutating_webhook
  check_gpu_nodes
  check_workload_examples

  section "요약"
  printf '  PASS=%d FAIL=%d\n' "${PASS}" "${FAIL}"
  [[ "${FAIL}" -eq 0 ]] || exit 1
}

main "$@"
