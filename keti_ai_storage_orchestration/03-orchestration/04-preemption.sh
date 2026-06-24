#!/usr/bin/env bash
# 04-preemption.sh — PREEMPTION (GPU contention eviction).
# ② direct trigger: POST /preemption with a SAFE payload (min_priority=int32min -> 0 eviction
# candidates) -> orchestrator runs analyze->find->select->complete, evicting NOTHING. Proves
# the preemption ACTION runs without disrupting any workload.
# ① autonomous trigger needs GPU forecast >= 0.95 (real GPU saturation) which cannot be
# synthesized on this hardware (GPU pod placement is broken) — so ② is the available proof.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib/load-env.sh"
exec bash "$HERE/lib/orchestration-capability-audit.sh" --deep preemption
