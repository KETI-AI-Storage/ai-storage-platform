#!/bin/bash
# =============================================================================
# AI Storage Webhook - TLS Certificate Generation
#
# K8s API Server → 웹훅 통신은 반드시 HTTPS.
# 이 스크립트가 자체 서명 인증서를 생성하고 K8s Secret으로 등록.
#
# 인증서 구조:
#   1. CA (Certificate Authority) 생성
#   2. CA로 서버 인증서 서명
#   3. CA 인증서를 MutatingWebhookConfiguration의 caBundle에 등록
#   4. 서버 인증서를 K8s Secret으로 저장
#
# SAN (Subject Alternative Name):
#   K8s API Server가 웹훅을 호출할 때 사용하는 DNS 이름과
#   인증서의 SAN이 일치해야 함.
#   형식: <service-name>.<namespace>.svc
#
# 사용법:
#   ./scripts/generate-certs.sh
# =============================================================================
set -e

# ─────────────────────────────────────────────────
# 설정값
# ─────────────────────────────────────────────────
SERVICE="ai-storage-webhook"
NAMESPACE="keti"
SECRET_NAME="ai-storage-webhook-tls"
CERT_DIR="/tmp/webhook-certs"

mkdir -p ${CERT_DIR}

# ─────────────────────────────────────────────────
# Step 1: CA (Certificate Authority) 키 + 인증서 생성
#
# CA는 "인증서를 발급하는 기관" 역할.
# 우리가 직접 만든 CA로 서버 인증서를 서명함.
# 이 CA의 공개키를 K8s에 등록하면, K8s가 우리 서버 인증서를 신뢰함.
# ─────────────────────────────────────────────────
echo "[1/5] Generating CA key and certificate..."
openssl genrsa -out ${CERT_DIR}/ca.key 2048
openssl req -new -x509 -days 3650 -key ${CERT_DIR}/ca.key \
    -subj "/CN=AI Storage Webhook CA" \
    -out ${CERT_DIR}/ca.crt

# ─────────────────────────────────────────────────
# Step 2: 서버 키 생성
# ─────────────────────────────────────────────────
echo "[2/5] Generating server key..."
openssl genrsa -out ${CERT_DIR}/tls.key 2048

# ─────────────────────────────────────────────────
# Step 3: CSR (Certificate Signing Request) 생성
#
# CSR = "이 서버에게 인증서를 발급해주세요" 라는 요청서.
# SAN에 K8s 내부 DNS 이름을 포함해야 함:
#   - ai-storage-webhook.keti.svc
#   - ai-storage-webhook.keti.svc.cluster.local
#
# K8s API Server는 이 DNS로 웹훅을 호출하므로
# 인증서에 이 이름이 없으면 TLS 검증 실패.
# ─────────────────────────────────────────────────
echo "[3/5] Generating CSR with SAN..."
cat > ${CERT_DIR}/csr.conf <<EOF
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
prompt = no

[req_distinguished_name]
CN = ${SERVICE}.${NAMESPACE}.svc

[v3_req]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${SERVICE}
DNS.2 = ${SERVICE}.${NAMESPACE}
DNS.3 = ${SERVICE}.${NAMESPACE}.svc
DNS.4 = ${SERVICE}.${NAMESPACE}.svc.cluster.local
EOF

openssl req -new -key ${CERT_DIR}/tls.key \
    -config ${CERT_DIR}/csr.conf \
    -out ${CERT_DIR}/server.csr

# ─────────────────────────────────────────────────
# Step 4: CA로 서버 인증서 서명
#
# Step 1의 CA가 Step 3의 CSR을 서명하여
# 최종 서버 인증서(tls.crt)를 생성.
# ─────────────────────────────────────────────────
echo "[4/5] Signing server certificate with CA..."
openssl x509 -req -days 3650 \
    -in ${CERT_DIR}/server.csr \
    -CA ${CERT_DIR}/ca.crt \
    -CAkey ${CERT_DIR}/ca.key \
    -CAcreateserial \
    -extensions v3_req \
    -extfile ${CERT_DIR}/csr.conf \
    -out ${CERT_DIR}/tls.crt

# ─────────────────────────────────────────────────
# Step 5: K8s Secret 생성
#
# tls.crt + tls.key를 K8s Secret으로 저장.
# 웹훅 Pod가 이 Secret을 볼륨으로 마운트하여 사용.
# ─────────────────────────────────────────────────
echo "[5/5] Creating Kubernetes TLS secret..."
kubectl delete secret ${SECRET_NAME} -n ${NAMESPACE} 2>/dev/null || true
kubectl create secret tls ${SECRET_NAME} \
    --cert=${CERT_DIR}/tls.crt \
    --key=${CERT_DIR}/tls.key \
    -n ${NAMESPACE}

# ─────────────────────────────────────────────────
# caBundle 출력
#
# MutatingWebhookConfiguration에 넣을 CA 인증서 (base64)
# K8s API Server가 이 CA로 웹훅 서버 인증서를 검증.
# ─────────────────────────────────────────────────
CA_BUNDLE=$(cat ${CERT_DIR}/ca.crt | base64 | tr -d '\n')
echo ""
echo "=========================================="
echo " TLS certificates generated successfully!"
echo "=========================================="
echo ""
echo "CA Bundle (for MutatingWebhookConfiguration):"
echo "${CA_BUNDLE}"
echo ""
echo "To apply, replace <CA_BUNDLE> in webhook-config.yaml with the value above."
echo "Or run:"
echo "  sed -i \"s|<CA_BUNDLE>|${CA_BUNDLE}|g\" deployments/webhook-config.yaml"
echo ""

# cleanup
rm -f ${CERT_DIR}/ca.key ${CERT_DIR}/ca.srl ${CERT_DIR}/server.csr ${CERT_DIR}/csr.conf
