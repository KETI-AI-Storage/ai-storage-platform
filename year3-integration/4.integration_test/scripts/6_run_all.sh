#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

echo "Deploying webhook..."
"${ROOT_DIR}/year3-integration/4.integration_test/scripts/0_deploy_webhook.sh"

echo "Starting Gluesys server..."
("${ROOT_DIR}/year3-integration/4.integration_test/scripts/5_run_gluesys_server.sh") &
GLUESYS_PID=$!

echo "Applying workload..."
"${ROOT_DIR}/year3-integration/4.integration_test/scripts/2_apply_workload.sh"

echo "Checking mutation..."
"${ROOT_DIR}/year3-integration/4.integration_test/scripts/3_check_mutation.sh" || true

echo "Checking ETRI status..."
"${ROOT_DIR}/year3-integration/4.integration_test/scripts/4_check_status.sh" || true

trap 'kill ${GLUESYS_PID} 2>/dev/null || true' EXIT

