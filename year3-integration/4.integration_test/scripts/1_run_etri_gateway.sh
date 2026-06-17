#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "${ROOT_DIR}/ai-storage-orchestrator"

export KETI_API_ADDR="${KETI_API_ADDR:-http://127.0.0.1:8080}"

go run ./cmd/etri-mock

