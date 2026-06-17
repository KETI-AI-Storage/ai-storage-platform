#!/usr/bin/env bash
# AI Storage 통합 패키지 설치 스크립트.
#
# Author: 미정 <unknown@example.com>
# Created: 2026-05-28
#
# 설계 의도:
# - 다른 기관 서버에서 패키지 폴더만 가지고 설치 가능하도록 모든 경로는
#   PACKAGE_DIR 기준으로 해석한다.
# - kubectl 리소스 적용은 idempotent하게 동작한다 (apply, dry-run+apply 패턴).
# - 워크로드 예제는 APPLY_WORKLOAD_EXAMPLES=true 일 때만 적용한다.

set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARGET_NAMESPACE="${TARGET_NAMESPACE:-ai-storage-workloads}"
WEBHOOK_NAMESPACE="${WEBHOOK_NAMESPACE:-keti}"
APPLY_WORKLOAD_EXAMPLES="${APPLY_WORKLOAD_EXAMPLES:-false}"
IMPORT_IMAGES="${IMPORT_IMAGES:-false}"
IMAGE_DIR="${IMAGE_DIR:-${PACKAGE_DIR}/images/tar}"
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-auto}"

log()  { printf '[setup] %s\n' "$*"; }
warn() { printf '[setup][WARN] %s\n' "$*" >&2; }
fail() { printf '[setup][FAIL] %s\n' "$*" >&2; exit 1; }

require_cmd() {
  local name="$1"
  command -v "${name}" >/dev/null 2>&1 || fail "필수 명령이 없습니다: ${name}"
}

import_images() {
  if [[ "${IMPORT_IMAGES}" != "true" ]]; then
    log "이미지 import 건너뜀 (IMPORT_IMAGES=${IMPORT_IMAGES})."
    return
  fi
  if [[ ! -d "${IMAGE_DIR}" ]] || ! compgen -G "${IMAGE_DIR}/*.tar" >/dev/null; then
    warn "import 대상 tar 파일이 없음: ${IMAGE_DIR}/*.tar — 건너뜀."
    return
  fi
  CONTAINER_RUNTIME="${CONTAINER_RUNTIME}" \
    "${PACKAGE_DIR}/images/import-images.sh" "${IMAGE_DIR}"
}

apply_namespace() {
  log "Namespace 생성/라벨 적용: ${TARGET_NAMESPACE}"
  if [[ "${TARGET_NAMESPACE}" == "ai-storage-workloads" ]]; then
    kubectl apply -f "${PACKAGE_DIR}/manifests/00-namespace/ai-storage-workloads-namespace.yaml"
  else
    # WHY: env로 다른 namespace를 쓰는 경우 매니페스트 이름과 다를 수 있으므로
    #      kubectl create로 ad-hoc 생성 후 라벨을 강제 부착한다.
    kubectl create namespace "${TARGET_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
    kubectl label namespace "${TARGET_NAMESPACE}" keti-ai-storage-injection=enabled --overwrite
  fi
}

apply_storageclass() {
  log "StorageClass 적용: storage-l1/l2/l3/s3"
  kubectl apply -f "${PACKAGE_DIR}/manifests/01-storageclass/storageclass-l1-l2-l3-s3.yaml"
}

apply_webhook() {
  log "webhook namespace 보장: ${WEBHOOK_NAMESPACE}"
  kubectl create namespace "${WEBHOOK_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

  local cert_dir ca_bundle config_tmp
  cert_dir="$(mktemp -d)"
  config_tmp="$(mktemp)"
  trap 'rm -rf "${cert_dir}" "${config_tmp}"' RETURN

  log "[1/4] CA + server cert 생성"
  openssl genrsa -out "${cert_dir}/ca.key" 2048 >/dev/null 2>&1
  openssl req -new -x509 -days 3650 -key "${cert_dir}/ca.key" \
    -subj "/CN=AI Storage Webhook CA" \
    -out "${cert_dir}/ca.crt" >/dev/null 2>&1
  openssl genrsa -out "${cert_dir}/tls.key" 2048 >/dev/null 2>&1
  cat > "${cert_dir}/csr.conf" <<EOF
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
prompt = no

[req_distinguished_name]
CN = ai-storage-webhook.${WEBHOOK_NAMESPACE}.svc

[v3_req]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = ai-storage-webhook
DNS.2 = ai-storage-webhook.${WEBHOOK_NAMESPACE}
DNS.3 = ai-storage-webhook.${WEBHOOK_NAMESPACE}.svc
DNS.4 = ai-storage-webhook.${WEBHOOK_NAMESPACE}.svc.cluster.local
EOF
  openssl req -new -key "${cert_dir}/tls.key" \
    -config "${cert_dir}/csr.conf" \
    -out "${cert_dir}/server.csr" >/dev/null 2>&1
  openssl x509 -req -days 3650 \
    -in "${cert_dir}/server.csr" \
    -CA "${cert_dir}/ca.crt" \
    -CAkey "${cert_dir}/ca.key" \
    -CAcreateserial \
    -extensions v3_req \
    -extfile "${cert_dir}/csr.conf" \
    -out "${cert_dir}/tls.crt" >/dev/null 2>&1

  log "[2/4] TLS Secret apply: ai-storage-webhook-tls"
  kubectl create secret tls ai-storage-webhook-tls \
    --cert="${cert_dir}/tls.crt" \
    --key="${cert_dir}/tls.key" \
    -n "${WEBHOOK_NAMESPACE}" \
    --dry-run=client -o yaml | kubectl apply -f -

  log "[3/4] webhook Deployment / Service / RBAC apply"
  kubectl apply -f "${PACKAGE_DIR}/manifests/02-webhook/webhook-deployment.yaml"

  log "[4/4] MutatingWebhookConfiguration caBundle 치환 후 apply"
  ca_bundle="$(base64 < "${cert_dir}/ca.crt" | tr -d '\n')"
  sed "s|<CA_BUNDLE>|${ca_bundle}|g" \
    "${PACKAGE_DIR}/manifests/02-webhook/webhook-config.yaml" > "${config_tmp}"
  kubectl apply -f "${config_tmp}"
}

apply_scheduler() {
  log "Scheduler apply"
  kubectl apply -f "${PACKAGE_DIR}/manifests/03-scheduler/ai-storage-scheduler.yaml"
}

apply_orchestrator() {
  log "Orchestrator apply"
  kubectl apply -f "${PACKAGE_DIR}/manifests/04-orchestrator/cluster-orchestrator.yaml"
}

wait_rollout() {
  log "rollout 상태 확인"
  kubectl rollout status deployment/ai-storage-webhook    -n "${WEBHOOK_NAMESPACE}" --timeout=180s || warn "webhook rollout 실패 또는 지연"
  kubectl rollout status deployment/ai-storage-scheduler  -n "${WEBHOOK_NAMESPACE}" --timeout=180s || warn "scheduler rollout 실패 또는 지연"
  kubectl rollout status deployment/ai-storage-orchestrator -n kube-system          --timeout=180s || warn "orchestrator rollout 실패 또는 지연"
}

apply_workload_examples() {
  if [[ "${APPLY_WORKLOAD_EXAMPLES}" != "true" ]]; then
    log "워크로드 예제 적용 건너뜀 (APPLY_WORKLOAD_EXAMPLES=${APPLY_WORKLOAD_EXAMPLES})."
    return
  fi
  log "CIFAR-10 워크로드 예제 apply"
  kubectl apply -f "${PACKAGE_DIR}/manifests/05-workloads/cifar10/"
  log "추가 전처리 워크로드 예제 apply"
  kubectl apply -f "${PACKAGE_DIR}/manifests/05-workloads/preprocessing/"
}

print_followup() {
  cat <<EOF

설치 단계 완료. 다음 검증/확인 명령을 권장한다.

  ./verify.sh
  kubectl get namespace ${TARGET_NAMESPACE} --show-labels
  kubectl get storageclass storage-l1 storage-l2 storage-l3 storage-s3
  kubectl get deploy -n ${WEBHOOK_NAMESPACE} ai-storage-webhook ai-storage-scheduler
  kubectl get deploy -n kube-system ai-storage-orchestrator
  kubectl get mutatingwebhookconfiguration ai-storage-webhook

워크로드 예제까지 적용하려면 APPLY_WORKLOAD_EXAMPLES=true 를 설정한 뒤 다시 실행한다.
워크로드 PVC tier 결정은 다음 명령으로 확인:

  kubectl get pvc -n ${TARGET_NAMESPACE} -o custom-columns=NAME:.metadata.name,SC:.spec.storageClassName,TIER:.metadata.annotations.ai-storage/selected-tier

EOF
}

main() {
  require_cmd kubectl
  require_cmd sed
  require_cmd base64
  require_cmd openssl

  import_images
  apply_namespace
  apply_storageclass
  apply_webhook
  apply_scheduler
  apply_orchestrator
  wait_rollout
  apply_workload_examples
  print_followup
}

main "$@"
