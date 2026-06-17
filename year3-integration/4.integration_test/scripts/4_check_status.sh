#!/usr/bin/env bash
set -euo pipefail

WORKLOAD_NAME="${WORKLOAD_NAME:-etri-train}"
NAMESPACE="${NAMESPACE:-default}"
ETRI_ADDR="${ETRI_ADDR:-http://127.0.0.1:8080}"

curl -s "${ETRI_ADDR}/api/v1/etri/workloads/${NAMESPACE}/${WORKLOAD_NAME}/status" | jq .

