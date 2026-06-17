# =============================================================================
# AI Storage Webhook - Multi-stage Docker Build
#
# Stage 1 (builder): Go 빌드 환경에서 바이너리 컴파일
# Stage 2 (runtime): 최소 이미지(distroless)에 바이너리만 복사
#
# distroless 사용 이유:
#   - shell 없음 → 공격 표면 최소화 (보안)
#   - 이미지 크기 ~20MB (alpine ~50MB, ubuntu ~200MB)
#   - 웹훅은 보안이 중요 (API Server와 직접 통신)
# =============================================================================

# Stage 1: 빌드
FROM golang:1.24-alpine AS builder

WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -ldflags="-s -w" -o webhook ./cmd/

# Stage 2: 런타임
FROM gcr.io/distroless/static:nonroot

COPY --from=builder /app/webhook /webhook

USER nonroot:nonroot
EXPOSE 8443

ENTRYPOINT ["/webhook"]
