#!/usr/bin/env bash
# run-e2e.sh — END-TO-END: install -> (gitops) -> orchestration, in stage
# order, against the LOCAL kubectl (no ssh). Each stage has its own runner under NN-<stage>/;
# this capstone sequences them and prints a stage-level summary + an honest capability note.
#
# Stage order (matches the NN- directories):
#   00-install      install components            (opt-in: --install)        00-install/01-install-components.sh
#   (preflight)     health + clean-slate gate                                 demo-preflight.sh
#   01-gitops       code -> CI -> registry -> ArgoCD (opt-in: --gitops)       01-gitops/02-run-gitops.sh
#   02-scheduling   schedule-release: part of the gitops ONE-FLOW (queue->scheduling), run manually
#                   after 05-queue-release (needs a held pod) — NOT a standalone capstone stage.
#   03-orchestration 6 policy types (① autonomous + ② direct)                 03-orchestration/run-orchestration.sh
#   (cleanup)       remove demo artifacts        (unless --keep)              cleanup.sh
#
# Usage:
#   bash run-e2e.sh                          # preflight -> orchestration -> cleanup
#   bash run-e2e.sh --install                # also install components first
#   bash run-e2e.sh --gitops cpu-eval        # also run the GitOps delivery stage
#   bash run-e2e.sh --only orchestration     # one stage (orchestration|gitops)
#   bash run-e2e.sh --keep                   # leave artifacts for inspection
#   bash run-e2e.sh --target-node worker-2   # pin the node (else largest worker auto-detected)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/load-env.sh"
source "$HERE/lib/common.sh"

DO_INSTALL=0; DO_PREFLIGHT=1; KEEP=0; GITOPS=0; GITOPS_COMP="cpu-eval"; ONLY=""; PAUSE="${PAUSE:-0}"; TARGET_NODE="${TARGET_NODE:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --install) DO_INSTALL=1 ;;
    --pause) PAUSE=1 ;;   # demo mode: pause (Enter) between functional stages
    --skip-preflight) DO_PREFLIGHT=0 ;;
    --keep) KEEP=1 ;;
    --gitops) GITOPS=1; [ -n "${2:-}" ] && [ "${2#--}" = "$2" ] && { GITOPS_COMP="$2"; shift; } ;;
    --only) ONLY="${2:?--only needs a stage}"; shift ;;
    --target-node) TARGET_NODE="${2:?--target-node needs a node}"; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac
  shift
done
want(){ [ -z "$ONLY" ] || [[ ",$ONLY," == *",$1,"* ]]; }
declare -a SUMMARY; hdr(){ echo; echo "######################################################################"; echo "##  $*"; echo "######################################################################"; }

command -v kubectl >/dev/null 2>&1 && kubectl version >/dev/null 2>&1 || { echo "❌ kubectl cannot reach a cluster"; exit 2; }
[ -z "$TARGET_NODE" ] && TARGET_NODE=$(detect_target_node)
export TARGET_NODE PAUSE
echo "KETI AI Storage E2E — cluster=$(kubectl config current-context 2>/dev/null || echo '?')  TARGET_NODE=$TARGET_NODE$([ "$PAUSE" = 1 ] && echo '  [PAUSE mode]')"

run_stage(){ # run_stage label script [args...]
  local label="$1" script="$2"; shift 2
  hdr "STAGE: $label"
  local rc=0; bash "$script" "$@" || rc=$?
  [ "$rc" = 0 ] && SUMMARY+=("PASS  $label") || SUMMARY+=("FAIL  $label")
  pause_if "stage '$label' complete"
  return "$rc"
}

# 00 install (opt-in)
if [ "$DO_INSTALL" = 1 ]; then
  run_stage "00 install" "$HERE/00-install/01-install-components.sh" || { echo "❌ install failed — aborting"; printf '  %s\n' "${SUMMARY[@]}"; exit 1; }
fi

# preflight gate
if [ "$DO_PREFLIGHT" = 1 ]; then
  if ! run_stage "preflight" "$HERE/demo-preflight.sh"; then
    echo "❌ preflight not green — fix and retry (or --skip-preflight to force)."; printf '  %s\n' "${SUMMARY[@]}"; exit 1
  fi
fi

# 01 gitops (opt-in)
[ "$GITOPS" = 1 ] && want gitops && run_stage "01 gitops ($GITOPS_COMP)" "$HERE/01-gitops/02-run-gitops.sh" "$GITOPS_COMP" || true

# 02 scheduling is now the tail of the gitops ONE-FLOW (03->04->05->02-scheduling/01-schedule-release),
# which needs a GitOps-deployed + queue-held pod. It is NOT a standalone capstone stage — run it
# manually after 05-queue-release. (The old synthetic admission trace was removed.)

# 03 orchestration (6 policy types)
want orchestration && run_stage "03 orchestration" "$HERE/03-orchestration/run-orchestration.sh" || true

# cleanup
if [ "$KEEP" = 0 ]; then run_stage "cleanup" "$HERE/cleanup.sh" || true
else echo; echo "(--keep: leaving artifacts; run cleanup.sh when done)"; fi

hdr "E2E SUMMARY"
printf '  %s\n' "${SUMMARY[@]}"
fails=$(printf '%s\n' "${SUMMARY[@]}" | grep -c '^FAIL')
echo
[ "$fails" -eq 0 ] && { echo "✅ E2E COMPLETE — no stage failures"; exit 0; } || { echo "❌ E2E had $fails failing stage(s)"; exit 1; }
