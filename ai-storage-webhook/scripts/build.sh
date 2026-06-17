#!/bin/bash
# =============================================================================
# AI Storage Webhook - Build & Push Script
#
# 사용법:
#   ./scripts/build.sh              # latest 태그로 빌드
#   ./scripts/build.sh v1.0.0       # 특정 태그로 빌드
# =============================================================================
set -e

TAG=${1:-latest}
IMAGE="ketidevit2/ai-storage-webhook:${TAG}"

echo "=========================================="
echo " Building AI Storage Webhook"
echo " Image: ${IMAGE}"
echo "=========================================="

# 바이너리 빌드
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o bin/webhook ./cmd/

# Docker 이미지 빌드
docker build -t ${IMAGE} .

# Push
docker push ${IMAGE}

echo "=========================================="
echo " Build complete: ${IMAGE}"
echo "=========================================="
