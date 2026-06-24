#!/usr/bin/env bash
# 02-scaling.sh — ① AUTONOMOUS scaling.
# Load into the STRESSED band -> forecaster warning -> policy-engine -> orchestrator activates
# an autoscaler for the Deployment (status=active) + idempotency (N policies -> 1 autoscaler).
# NOTE: provisioning (GPU-warn) co-fires here and creates a real Bound PVC = autonomous
# provisioning (①) is demonstrated as a side effect; 03-provisioning.sh also triggers it directly.
# Env: TARGET_NODE (auto), KEEP=1, TIMEOUT, SCALE_CPU.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib/load-env.sh"
source "$HERE/../lib/common.sh"
: "${TARGET_NODE:=$(detect_target_node)}"; export TARGET_NODE
exec env POLICY_TYPE=scaling bash "$HERE/lib/orchestration-e2e-verify.sh"
