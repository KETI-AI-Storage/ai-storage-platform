#!/usr/bin/env bash
# CIFAR-10 AI Storage 검증 패키지를 대상 클러스터에 설치한다.
#
# Author: 미정 <unknown@example.com>
# Created: 2026-05-28

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PACKAGE_DIR="${ROOT_DIR}/year3-integration/package/cifar10-ai-storage"
TARGET_NAMESPACE="${TARGET_NAMESPACE:-ai-storage-workloads}"
WEBHOOK_NAMESPACE="${WEBHOOK_NAMESPACE:-keti}"
IMAGE_DIR="${IMAGE_DIR:-${PACKAGE_DIR}/images}"
IMPORT_IMAGES="${IMPORT_IMAGES:-false}"
APPLY_CIFAR_EXAMPLES="${APPLY_CIFAR_EXAMPLES:-false}"

require_cmd() {
  local name="$1"
  if ! command -v "${name}" >/dev/null 2>&1; then
    echo "필수 명령이 없습니다: ${name}" >&2
    exit 1
  fi
}

apply_webhook_config() {
  local cert_dir ca_bundle config_tmp
  cert_dir="$(mktemp -d)"
  config_tmp="$(mktemp)"

  openssl genrsa -out "${cert_dir}/ca.key" 2048
  openssl req -new -x509 -days 3650 -key "${cert_dir}/ca.key" \
    -subj "/CN=AI Storage Webhook CA" \
    -out "${cert_dir}/ca.crt"
  openssl genrsa -out "${cert_dir}/tls.key" 2048
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
  openssl req -new -key "${cert_dir}/tls.key" -config "${cert_dir}/csr.conf" -out "${cert_dir}/server.csr"
  openssl x509 -req -days 3650 \
    -in "${cert_dir}/server.csr" \
    -CA "${cert_dir}/ca.crt" \
    -CAkey "${cert_dir}/ca.key" \
    -CAcreateserial \
    -extensions v3_req \
    -extfile "${cert_dir}/csr.conf" \
    -out "${cert_dir}/tls.crt"

  kubectl create namespace "${WEBHOOK_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret tls ai-storage-webhook-tls \
    --cert="${cert_dir}/tls.crt" \
    --key="${cert_dir}/tls.key" \
    -n "${WEBHOOK_NAMESPACE}" \
    --dry-run=client -o yaml | kubectl apply -f -

  ca_bundle="$(base64 < "${cert_dir}/ca.crt" | tr -d '\n')"
  sed "s|<CA_BUNDLE>|${ca_bundle}|g" \
    "${ROOT_DIR}/ai-storage-webhook/deployments/webhook-config.yaml" > "${config_tmp}"
  kubectl apply -f "${config_tmp}"
}

import_images() {
  if [[ "${IMPORT_IMAGES}" != "true" ]]; then
    echo "이미지 import 건너뜀: IMPORT_IMAGES=true 설정 시 ${IMAGE_DIR}/*.tar 를 import합니다."
    return
  fi
  if ! compgen -G "${IMAGE_DIR}/*.tar" >/dev/null; then
    echo "이미지 tar 파일이 없습니다: ${IMAGE_DIR}/*.tar" >&2
    exit 1
  fi
  for image_tar in "${IMAGE_DIR}"/*.tar; do
    echo "이미지 import: ${image_tar}"
    if command -v ctr >/dev/null 2>&1; then
      ctr -n k8s.io images import "${image_tar}"
    elif command -v docker >/dev/null 2>&1; then
      docker load -i "${image_tar}"
    else
      echo "ctr 또는 docker가 필요합니다." >&2
      exit 1
    fi
  done
}

main() {
  require_cmd kubectl
  require_cmd openssl
  require_cmd sed
  require_cmd base64

  import_images

  kubectl create namespace "${TARGET_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
  kubectl label namespace "${TARGET_NAMESPACE}" keti-ai-storage-injection=enabled --overwrite

  kubectl apply -f "${PACKAGE_DIR}/manifests/storageclass-l1-l2-l3-s3.yaml"
  kubectl apply -f "${ROOT_DIR}/ai-storage-scheduler/deployments/ai-storage-scheduler.yaml"
  kubectl apply -f "${ROOT_DIR}/ai-storage-orchestrator/deployments/cluster-orchestrator.yaml"
  kubectl apply -f "${ROOT_DIR}/ai-storage-webhook/deployments/webhook-deployment.yaml"
  apply_webhook_config

  kubectl rollout status deployment/ai-storage-webhook -n "${WEBHOOK_NAMESPACE}" --timeout=180s
  kubectl rollout status deployment/ai-storage-scheduler -n "${WEBHOOK_NAMESPACE}" --timeout=180s
  kubectl rollout status deployment/ai-storage-orchestrator -n kube-system --timeout=180s

  if [[ "${APPLY_CIFAR_EXAMPLES}" == "true" ]]; then
    kubectl apply -f "${ROOT_DIR}/year3-integration/4.integration_test/manifests/cifar10-preprocessing-workload.yaml"
    kubectl apply -f "${ROOT_DIR}/year3-integration/4.integration_test/manifests/cifar10-training-workload.yaml"
    kubectl apply -f "${ROOT_DIR}/year3-integration/4.integration_test/manifests/cifar10-inference-workload.yaml"
    kubectl apply -f "${ROOT_DIR}/year3-integration/4.integration_test/manifests/checkpoint-io-workload.yaml"
  fi

  echo "설치 초안 실행 완료. PVC tier와 Job 상태는 README-install.md의 검증 명령으로 확인하세요."
}

main "$@"
