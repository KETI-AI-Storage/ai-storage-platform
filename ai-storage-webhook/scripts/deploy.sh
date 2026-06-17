#!/bin/bash
# =============================================================================
# AI Storage Webhook - Deploy Script
#
# 전체 배포 순서:
#   1. TLS 인증서 생성 → K8s Secret 등록
#   2. caBundle 값을 webhook-config.yaml에 삽입
#   3. Deployment + Service 배포
#   4. MutatingWebhookConfiguration 등록
#   5. 대상 네임스페이스에 injection label 추가
#
# 사용법:
#   ./scripts/deploy.sh                    # 기본 배포
#   ./scripts/deploy.sh delete             # 삭제
# =============================================================================
set -e

NAMESPACE="keti"
TARGET_NS="kubeflow-user-example-com"
DEPLOY_DIR="$(dirname "$0")/../deployments"

if [ "$1" = "delete" ] || [ "$1" = "d" ]; then
    echo "=========================================="
    echo " Deleting AI Storage Webhook"
    echo "=========================================="
    kubectl delete -f ${DEPLOY_DIR}/webhook-config.yaml 2>/dev/null || true
    kubectl delete -f ${DEPLOY_DIR}/webhook-deployment.yaml 2>/dev/null || true
    kubectl delete secret ai-storage-webhook-tls -n ${NAMESPACE} 2>/dev/null || true
    kubectl label namespace ${TARGET_NS} keti-ai-storage-injection- 2>/dev/null || true
    echo "Done."
    exit 0
fi

echo "=========================================="
echo " Deploying AI Storage Webhook"
echo "=========================================="

# Step 1: TLS 인증서 생성
echo "[1/4] Generating TLS certificates..."
bash "$(dirname "$0")/generate-certs.sh"

# Step 2: caBundle 삽입
# MutatingWebhookConfiguration.caBundle에는 **서명 CA 공개키(ca.crt)** 가 들어가야 함.
# (Secret의 tls.crt는 서버 인증서이므로 caBundle으로 쓰면 API 서버 TLS 검증 실패 가능)
echo "[2/4] Injecting caBundle..."
CA_BUNDLE=$(cat /tmp/webhook-certs/ca.crt | base64 | tr -d '\n')
sed "s|<CA_BUNDLE>|${CA_BUNDLE}|g" ${DEPLOY_DIR}/webhook-config.yaml > /tmp/webhook-config-rendered.yaml

# Step 3: Deployment + Service
echo "[3/4] Deploying webhook server..."
kubectl apply -f ${DEPLOY_DIR}/webhook-deployment.yaml

# Step 4: Webhook 등록
echo "[4/4] Registering MutatingWebhookConfiguration..."
kubectl apply -f /tmp/webhook-config-rendered.yaml

# 대상 네임스페이스에 injection label 추가
kubectl label namespace ${TARGET_NS} keti-ai-storage-injection=enabled --overwrite 2>/dev/null || true

echo ""
echo "=========================================="
echo " Deployment complete!"
echo ""
echo " Webhook server: ${NAMESPACE}/ai-storage-webhook"
echo " Target namespace: ${TARGET_NS} (injection enabled)"
echo ""
echo " 다른 네임스페이스에도 주입하려면:"
echo "   kubectl label namespace <ns> keti-ai-storage-injection=enabled"
echo "=========================================="
