# Build stage
FROM golang:1.23-alpine AS builder

WORKDIR /app

# Install build dependencies
RUN apk add --no-cache git

# Copy go mod files
COPY go.mod go.sum* ./

# Download dependencies
RUN go mod download || true

# Copy source code
COPY . .

# Build binary
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o insight-scope ./cmd/main.go

# Runtime stage
FROM alpine:3.18

WORKDIR /app

# Install runtime dependencies
RUN apk add --no-cache ca-certificates tzdata

# Copy binary from builder
COPY --from=builder /app/insight-scope /app/insight-scope

# Default environment variables
ENV PORT=8081
ENV GRPC_PORT=9092

# Expose ports (HTTP REST + gRPC)
EXPOSE 8081 9092

# Run as non-root user
RUN adduser -D -u 1000 insight
USER insight

ENTRYPOINT ["/app/insight-scope"]
