#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

WEBHOOK_DIR="${ROOT_DIR}/ai-storage-webhook"

echo "[webhook] generating TLS certs and updating caBundle..."
cd "${WEBHOOK_DIR}"
./scripts/generate-certs.sh

echo "[webhook] applying deployment and config"
kubectl apply -f "${WEBHOOK_DIR}/deployments/webhook-deployment.yaml"
kubectl apply -f "${WEBHOOK_DIR}/deployments/webhook-config.yaml"

NAMESPACE="${NAMESPACE:-default}"
echo "[webhook] labeling namespace ${NAMESPACE} with keti-ai-storage-injection=enabled"
kubectl label namespace "${NAMESPACE}" keti-ai-storage-injection=enabled --overwrite

