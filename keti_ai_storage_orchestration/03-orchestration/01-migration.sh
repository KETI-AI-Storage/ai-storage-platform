#!/usr/bin/env bash
# 01-migration.sh — ① AUTONOMOUS migration.
# Load -> forecaster CRITICAL -> policy-engine -> orchestrator migrates ONLY the running
# container (completed excluded) to another node. Asserts ~50% CPU / ~40% Mem savings +
# idempotency. Pure policy-driven (no manual API). Env: TARGET_NODE (auto), KEEP=1, TIMEOUT.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib/load-env.sh"
source "$HERE/../lib/common.sh"
: "${TARGET_NODE:=$(detect_target_node)}"; export TARGET_NODE
exec env POLICY_TYPE=migration bash "$HERE/lib/orchestration-e2e-verify.sh"
