#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

kubectl apply -f "${ROOT_DIR}/year3-integration/4.integration_test/manifests/test-etri-workload.yaml"

