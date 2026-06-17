#!/usr/bin/env bash
# AI Storage 통합 패키지 안전 모드 uninstall 스크립트.
#
# Author: 미정 <unknown@example.com>
# Created: 2026-05-28
#
# 설계 의도:
# - 기본 동작은 "아무것도 삭제하지 않음". 안내 메시지만 출력한다.
# - 각 삭제 단계는 명시적 환경 변수가 true 일 때만 실행된다.
#   DELETE_WORKLOADS=true     → workload 예제(Job/PVC/SA/Role/RoleBinding/ConfigMap) 삭제
#   DELETE_CORE=true          → webhook / scheduler / orchestrator core 컴포넌트 삭제
#   DELETE_STORAGECLASS=true  → storage-l1/l2/l3/s3 삭제 (다른 워크로드가 쓰면 위험)
#   DELETE_NAMESPACE=true     → TARGET_NAMESPACE 자체 삭제 (PVC가 남아 있으면 종속 리소스 함께 삭제됨)
# - PV는 reclaimPolicy=Retain 이므로 자동으로 삭제하지 않는다. 운영자가 수동으로 정리한다.

set -uo pipefail

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARGET_NAMESPACE="${TARGET_NAMESPACE:-ai-storage-workloads}"
WEBHOOK_NAMESPACE="${WEBHOOK_NAMESPACE:-keti}"
DELETE_WORKLOADS="${DELETE_WORKLOADS:-false}"
DELETE_CORE="${DELETE_CORE:-false}"
DELETE_STORAGECLASS="${DELETE_STORAGECLASS:-false}"
DELETE_NAMESPACE="${DELETE_NAMESPACE:-false}"

log()  { printf '[uninstall] %s\n' "$*"; }
warn() { printf '[uninstall][WARN] %s\n' "$*" >&2; }

print_intro() {
  cat <<EOF
[uninstall] AI Storage 통합 패키지 안전 모드.
  TARGET_NAMESPACE     = ${TARGET_NAMESPACE}
  WEBHOOK_NAMESPACE    = ${WEBHOOK_NAMESPACE}
  DELETE_WORKLOADS     = ${DELETE_WORKLOADS}
  DELETE_CORE          = ${DELETE_CORE}
  DELETE_STORAGECLASS  = ${DELETE_STORAGECLASS}
  DELETE_NAMESPACE     = ${DELETE_NAMESPACE}

WARNING: PV(reclaimPolicy=Retain)는 자동 삭제하지 않는다. 보존된 PV는 수동 정리가 필요하다.
WARNING: storage-l1/l2/l3/s3 StorageClass는 다른 워크로드가 사용 중일 수 있다. DELETE_STORAGECLASS=true 는 신중히 사용한다.
WARNING: 본 스크립트는 ai-storage-orchestrator(kube-system) 자체도 DELETE_CORE=true 일 때만 제거한다.
EOF
}

delete_workloads() {
  if [[ "${DELETE_WORKLOADS}" != "true" ]]; then
    log "워크로드 예제 삭제 건너뜀 (DELETE_WORKLOADS=${DELETE_WORKLOADS})."
    return
  fi
  warn "워크로드 예제 삭제 시작 (Job/SA/Role/RoleBinding/ConfigMap)."
  # WHY: PVC를 함께 지우면 PV 가 Retain 이라도 Bound 상태가 해제된다.
  #      Job 만 우선 정리해 사용자가 PVC 보존 여부를 결정할 시간을 준다.
  kubectl delete -f "${PACKAGE_DIR}/manifests/05-workloads/cifar10/"        --ignore-not-found=true --grace-period=30 || warn "cifar10 워크로드 삭제 실패/없음"
  kubectl delete -f "${PACKAGE_DIR}/manifests/05-workloads/preprocessing/"  --ignore-not-found=true --grace-period=30 || warn "preprocessing 워크로드 삭제 실패/없음"
  warn "PVC는 자동 삭제하지 않았다. 운영자가 수동으로 확인 후 삭제할 것을 권장한다:"
  warn "  kubectl get pvc -n ${TARGET_NAMESPACE}"
}

delete_core() {
  if [[ "${DELETE_CORE}" != "true" ]]; then
    log "core 컴포넌트 삭제 건너뜀 (DELETE_CORE=${DELETE_CORE})."
    return
  fi
  warn "core 컴포넌트 삭제 시작 (MutatingWebhookConfiguration → orchestrator → scheduler → webhook)."
  kubectl delete mutatingwebhookconfiguration ai-storage-webhook --ignore-not-found=true || true
  kubectl delete -f "${PACKAGE_DIR}/manifests/04-orchestrator/cluster-orchestrator.yaml" --ignore-not-found=true || true
  kubectl delete -f "${PACKAGE_DIR}/manifests/03-scheduler/ai-storage-scheduler.yaml"    --ignore-not-found=true || true
  kubectl delete -f "${PACKAGE_DIR}/manifests/02-webhook/webhook-deployment.yaml"        --ignore-not-found=true || true
  kubectl delete secret ai-storage-webhook-tls -n "${WEBHOOK_NAMESPACE}" --ignore-not-found=true || true
}

delete_storageclass() {
  if [[ "${DELETE_STORAGECLASS}" != "true" ]]; then
    log "StorageClass 삭제 건너뜀 (DELETE_STORAGECLASS=${DELETE_STORAGECLASS})."
    return
  fi
  warn "StorageClass storage-l1/l2/l3/s3 삭제 시작."
  kubectl delete -f "${PACKAGE_DIR}/manifests/01-storageclass/storageclass-l1-l2-l3-s3.yaml" --ignore-not-found=true || true
}

delete_namespace() {
  if [[ "${DELETE_NAMESPACE}" != "true" ]]; then
    log "Namespace 삭제 건너뜀 (DELETE_NAMESPACE=${DELETE_NAMESPACE})."
    return
  fi
  warn "Namespace ${TARGET_NAMESPACE} 삭제 시작 (남아있는 PVC/Pod 도 함께 종속 삭제됨)."
  kubectl delete namespace "${TARGET_NAMESPACE}" --ignore-not-found=true || true
}

main() {
  command -v kubectl >/dev/null 2>&1 || { echo "kubectl 이 필요합니다." >&2; exit 1; }
  print_intro
  delete_workloads
  delete_core
  delete_storageclass
  delete_namespace
  log "완료."
}

main "$@"
