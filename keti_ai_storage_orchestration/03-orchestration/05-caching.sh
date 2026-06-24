#!/usr/bin/env bash
# 05-caching.sh — CACHING (MantaFS storage-tier data caching).
# ② direct trigger: POST /caching reads a source PVC (non-destructive) into a cache tier ->
# reaches status=active ("serving"). Proves the caching ACTION runs end-to-end.
# ① autonomous trigger needs STORAGE_IO forecast >= 0.85 (heavy I/O) which is hard to
# synthesize here; the MantaFS data plane is a best-effort stub (control path proven, not
# real cross-tier data movement).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib/load-env.sh"
exec bash "$HERE/lib/orchestration-capability-audit.sh" --deep caching
