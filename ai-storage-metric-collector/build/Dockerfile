FROM golang:1.24.5 AS builder
WORKDIR /app
COPY . .
RUN go build -o metric-collector ./cmd/main.go

FROM gcr.io/distroless/base
COPY --from=builder /app/metric-collector /metric-collector
EXPOSE 2112
ENTRYPOINT ["/metric-collector"]
# FROM ubuntu:24.04

# ENV OPERATOR=/usr/local/bin/ai-storage-metric-collector \
#     USER_UID=root \
#     USER_NAME=discovery
# COPY _output/bin/ai-storage-metric-collector ${OPERATOR}

# ENTRYPOINT ["/usr/local/bin/ai-storage-metric-collector"]

# USER ${USER_UID}