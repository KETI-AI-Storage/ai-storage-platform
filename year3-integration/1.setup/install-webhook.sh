#!/usr/bin/env bash
# install-webhook.sh는 ai-storage-webhook 네임스페이스·TLS·MutatingWebhookConfiguration 적용 및 Ready 검증을 수행한다.
#
# Author: 미정
# Created: 2026-04-17
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WEBHOOK_DIR="${WORKSPACE_DIR}/ai-storage-webhook"
CERT_DIR="/tmp/webhook-certs"
WEBHOOK_NS="keti"
WORKLOAD_NS="${WORKLOAD_NS:-k8s-admission-webhook}"

if [[ ! -d "${WEBHOOK_DIR}" ]]; then
  echo "ERROR: WEBHOOK_DIR not found: ${WEBHOOK_DIR}" >&2
  exit 1
fi

if ! command -v kubectl &>/dev/null; then
  echo "ERROR: kubectl not found" >&2
  exit 1
fi

echo "[install-webhook] namespaces ${WEBHOOK_NS}, ${WORKLOAD_NS}"
kubectl create namespace "${WEBHOOK_NS}" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "${WORKLOAD_NS}" --dry-run=client -o yaml | kubectl apply -f -

echo "[install-webhook] TLS (scripts/generate-certs.sh — NAMESPACE=keti 고정, ai-storage-webhook/scripts/generate-certs.sh L27-L29)"
pushd "${WEBHOOK_DIR}" >/dev/null
./scripts/generate-certs.sh
popd >/dev/null

if [[ ! -f "${CERT_DIR}/ca.crt" ]]; then
  echo "ERROR: ${CERT_DIR}/ca.crt missing after generate-certs.sh (generate-certs.sh는 ca.key 등만 삭제하고 ca.crt는 유지)" >&2
  exit 1
fi

CA_BUNDLE="$(base64 -w0 "${CERT_DIR}/ca.crt" 2>/dev/null || base64 "${CERT_DIR}/ca.crt" | tr -d '\n')"
if [[ -z "${CA_BUNDLE}" ]]; then
  echo "ERROR: empty caBundle" >&2
  exit 1
fi

TMP_CFG="$(mktemp)"
trap 'rm -f "${TMP_CFG}"' EXIT
# webhook-config.yaml의 플레이스홀더는 ai-storage-webhook/deployments/webhook-config.yaml L80.
sed "s|<CA_BUNDLE>|${CA_BUNDLE}|g" "${WEBHOOK_DIR}/deployments/webhook-config.yaml" >"${TMP_CFG}"

echo "[install-webhook] apply deployment (ai-storage-webhook/deployments/webhook-deployment.yaml)"
kubectl apply -f "${WEBHOOK_DIR}/deployments/webhook-deployment.yaml"

echo "[install-webhook] apply MutatingWebhookConfiguration (patched caBundle)"
kubectl apply -f "${TMP_CFG}"

echo "[install-webhook] caBundle in cluster (non-empty base64 required)"
BUNDLE="$(kubectl get mutatingwebhookconfiguration ai-storage-webhook -o jsonpath='{.webhooks[0].clientConfig.caBundle}' 2>/dev/null || true)"
if [[ -z "${BUNDLE}" ]]; then
  echo "ERROR: MutatingWebhookConfiguration ai-storage-webhook has empty webhooks[0].clientConfig.caBundle" >&2
  exit 1
fi
echo "[install-webhook] caBundle length: ${#BUNDLE}"

echo "[install-webhook] wait rollout (Deployment ai-storage-webhook, namespace ${WEBHOOK_NS})"
kubectl rollout status deployment/ai-storage-webhook -n "${WEBHOOK_NS}" --timeout=300s

echo "[install-webhook] namespace label (year3-integration/4.integration_test/scripts/0_deploy_webhook.sh L16-L18 패턴)"
kubectl label namespace "${WORKLOAD_NS}" keti-ai-storage-injection=enabled --overwrite

echo "[install-webhook] done."
