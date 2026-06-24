#!/usr/bin/env bash
# 04-drive-demo.sh — drive a WORKLOAD through the GitOps pipeline (commit → CI → ArgoCD).
#   • If you changed a workload (git), it drives THAT workload.
#   • If you changed nothing, it AUTO-BUMPS a current-time stamp into a default workload (training-job)
#     so each run is a fresh commit that drives the pipeline — re-runnable, no manual edit needed.
#   build:true workloads (training-job): commit → CI image build → Docker Hub → newTag bump → ArgoCD.
#   build:false workloads (cpu-eval):    commit manifest → ArgoCD syncs (no CI image).
#
#   bash 01-gitops/04-drive-demo.sh        # no flag — drives your changed workload, else auto-bumps training-job
#
# For a read-only check of the CURRENT delivery (no commit), use:  02-run-gitops.sh <workload>
# Run where the monorepo + a GitHub PUSH token live, with KUBECONFIG at the cluster running ArgoCD.
# The commit/push is under YOUR git identity. Real outward action (GitHub + CI + Docker Hub).
#
# Env: MONOREPO, KUBECONFIG, SKIP_PREFLIGHT.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib/load-env.sh"
source "$HERE/../lib/common.sh"

MONOREPO="${MONOREPO:-/tmp/ai-storage-platform}"
# No flag: drive whichever WORKLOAD you changed (git). If you changed nothing, AUTO-BUMP a current-time
# stamp into the default workload (training-job) so each run is a fresh commit that drives the pipeline.
WL="$(detect_changed_workload)"
if [ -z "$WL" ]; then
  WL="training-job"
  CFG="$MONOREPO/deploy/$WL/appconfig.json"
  [ -f "$CFG" ] || { echo "❌ 기본 워크로드 deploy/$WL/appconfig.json 없음 ($MONOREPO)"; exit 1; }
  SRC=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("sourceDir") or "")' "$CFG" 2>/dev/null)
  STAMPDIR="$MONOREPO/deploy/$WL"; [ -n "$SRC" ] && [ -d "$MONOREPO/$SRC" ] && STAMPDIR="$MONOREPO/$SRC"
  printf 'cicd auto-update (drive-demo)\nupdated_utc: %s\n' "$(date -u +%FT%TZ)" > "$STAMPDIR/cicd-build-trigger"
  echo "== drive-demo: 수정한 워크로드 없음 → 워크로드 '$WL'에 현재시각 스탬프 자동 갱신 =="
  echo "   $STAMPDIR/cicd-build-trigger   (매 실행마다 새 commit → 파이프라인 반복 가능)"
else
  echo "== drive-demo: 내가 바꾼 워크로드 '$WL' 를 파이프라인에 태움 =="
fi
MSG="${MSG:-deploy($WL): drive workload change}"
[ -f "$MONOREPO/deploy/$WL/appconfig.json" ] || { echo "❌ deploy/$WL/appconfig.json 없음 ($MONOREPO)"; exit 1; }

# commit -> push -> (CI image build if build:true) -> ArgoCD deploy -> verify.
exec bash "$HERE/02-run-gitops.sh" --drive "$WL" "$MSG"
