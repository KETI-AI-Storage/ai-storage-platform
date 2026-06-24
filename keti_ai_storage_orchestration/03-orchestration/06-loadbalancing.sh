#!/usr/bin/env bash
# 06-loadbalancing.sh — LOADBALANCING (cluster rebalancing via pod migration).
# ② direct trigger: POST /loadbalancing with SAFE thresholds=100 -> cluster reads as "already
# balanced" -> completes, migrating NOTHING. Proves the loadbalancing ACTION runs without
# disrupting any workload.
# ① autonomous trigger needs STORAGE_IO forecast >= 0.28 (I/O imbalance) which is hard to
# synthesize here — so ② is the available proof.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib/load-env.sh"
exec bash "$HERE/lib/orchestration-capability-audit.sh" --deep loadbalancing
