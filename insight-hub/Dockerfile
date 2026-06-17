# Insight Hub — SQLite-backed ingest + query for node resource history
FROM golang:1.21-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /insight-hub ./cmd/main.go

FROM alpine:3.19
# sqlite: 운영/스크립트에서 kubectl exec 로 DB 확인 (check-hub-data.sh)
RUN apk add --no-cache ca-certificates sqlite
WORKDIR /app
COPY --from=build /insight-hub /app/insight-hub
ENV DATA_DIR=/data
ENV CHECKPOINT_DIR=/checkpoint
ENV CACHE_DIR=/cache
ENV OUTPUT_DIR=/output
ENV GRPC_PORT=50056
EXPOSE 50056
VOLUME ["/data", "/checkpoint", "/cache", "/output"]
ENTRYPOINT ["/app/insight-hub"]
