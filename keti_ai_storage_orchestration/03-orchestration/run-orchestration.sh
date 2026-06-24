#!/usr/bin/env bash
# run-orchestration.sh — run all 6 orchestration policy types, one per script, in order.
#   01 migration   ① autonomous (50/40 savings)
#   02 scaling     ① autonomous (autoscaler activated)  [provisioning ① co-fires here]
#   03 provisioning ② direct trigger (real PVC, cleaned up)
#   04 preemption  ② direct trigger (0 evictions)
#   05 caching     ② direct trigger (active/serving)
#   06 loadbalancing ② direct trigger (0 migrations)
#
#   bash run-orchestration.sh                 # all 6
#   bash run-orchestration.sh 01 02           # only these
#   ONLY="01 02" bash run-orchestration.sh    # same via env
# Env: TARGET_NODE (auto-detected for ① 01/02), KEEP=1.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib/load-env.sh"
source "$HERE/../lib/common.sh"

: "${TARGET_NODE:=$(detect_target_node)}"; export TARGET_NODE
SEL="${*:-${ONLY:-01 02 03 04 05 06}}"

command -v kubectl >/dev/null 2>&1 && kubectl version >/dev/null 2>&1 || { echo "❌ kubectl cannot reach a cluster"; exit 2; }
echo "== orchestration suite (TARGET_NODE=$TARGET_NODE) =="

declare -a RES; fails=0
for n in $SEL; do
  s=$(ls "$HERE/${n}-"*.sh 2>/dev/null | head -1)
  [ -z "$s" ] && { echo "  ?? no script for '$n'"; continue; }
  name="$(basename "$s" .sh)"
  echo; echo "######### $name #########"
  if bash "$s"; then RES+=("PASS  $name"); else RES+=("FAIL  $name"); fails=$((fails+1)); fi
  pause_if "$name complete"
done

echo; echo "== orchestration suite summary =="
printf '  %s\n' "${RES[@]}"
echo
[ "$fails" -eq 0 ] && { echo "✅ ORCHESTRATION: all selected types passed"; exit 0; } \
                   || { echo "❌ ORCHESTRATION: $fails type(s) failed"; exit 1; }
