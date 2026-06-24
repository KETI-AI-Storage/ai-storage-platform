#!/usr/bin/env bash
# 03-update-workload.sh — make a real, repeatable change to a WORKLOAD so the GitOps pipeline has
# something to ship. It bumps a current-time marker into the workload:
#   • build:true workload (e.g. training-job) → writes the stamp into its SOURCE dir, so CI rebuilds
#     the image.
#   • build:false workload (e.g. cpu-eval)    → writes the stamp into its deploy/ dir, so ArgoCD
#     redeploys the manifest (no image build).
# Then run 04-drive-demo.sh to commit·push → (CI →) ArgoCD.
#
# This does the modify step ONLY (it does not commit/push). 04-drive-demo detects this change and
# drives it. (03 also auto-bumps training-job on its own if you skip this — this script is the
# explicit "modify a workload" step, and lets you target any workload.)
#
#   bash 01-gitops/03-update-workload.sh                # default workload: training-job
#   bash 01-gitops/03-update-workload.sh cpu-eval       # target a specific workload
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib/load-env.sh"     # sets MONOREPO (package-internal .monorepo by default)

WL="${1:-training-job}"
CFG="$MONOREPO/deploy/$WL/appconfig.json"
[ -d "$MONOREPO/deploy" ] || { echo "❌ 모노레포 없음: $MONOREPO  (먼저: bash 01-gitops/01-gitops-preflight.sh)"; exit 1; }
[ -f "$CFG" ] || { echo "❌ '$WL'는 deploy/ 워크로드가 아님 ($CFG 없음)"; echo "   가능한 워크로드:"; ls -1 "$MONOREPO"/deploy 2>/dev/null | sed 's/^/     /'; exit 1; }

SRC=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("sourceDir") or "")' "$CFG" 2>/dev/null)
# build:true → bump the SOURCE (CI rebuilds image);  build:false → bump the deploy manifest dir.
TARGET="$MONOREPO/deploy/$WL"; KIND="manifest (build:false → ArgoCD redeploy)"
if [ -n "$SRC" ] && [ -d "$MONOREPO/$SRC" ]; then TARGET="$MONOREPO/$SRC"; KIND="source (build:true → CI image rebuild)"; fi

TS="$(date -u +%FT%TZ)"
printf 'workload update (drive-demo)\nworkload: %s\nupdated_utc: %s\n' "$WL" "$TS" > "$TARGET/cicd-build-trigger"

echo "✅ 워크로드 '$WL' 수정됨 — 현재시각으로 갱신"
echo "   $TARGET/cicd-build-trigger   ($KIND)"
echo "   updated_utc: $TS"

# Arm the QUEUE HOLD: route the workload to the demo-owned hold queue (demo-admission-queue — absent by
# default), so AFTER 04 deploys it the Job PENDS in the Kueue queue (Inadmissible), ready to be paused +
# released by 05-queue-release.sh. Edits only THIS workload's manifest; never the shared ai-storage-queue.
HOLDQ=demo-admission-queue
if grep -rqE 'kueue\.x-k8s\.io/queue-name:' "$MONOREPO/deploy/$WL"/*.yaml 2>/dev/null; then
  sed -i -E "s|(kueue\.x-k8s\.io/queue-name:[[:space:]]*).*|\1${HOLDQ}|" "$MONOREPO/deploy/$WL"/*.yaml
  echo "✅ 큐 hold 무장 — '$WL' queue-name → ${HOLDQ}  (배포 후 큐에서 대기)"
else
  echo "ⓘ '$WL'에 kueue queue-name 라벨 없음 — 큐 hold 건너뜀 (배포만)"
fi

# Arm the SCHEDULING HOLD: add nodeSelector keti.io/demo-hold to the workload's pod template, so AFTER
# 05 admits it, the pod PENDS at scheduling (no node has that label). 01-schedule-release then reveals
# the webhook injection and releases it (labels a node). Idempotent. (cleanup.sh removes the label.)
HOLDLBL=keti.io/demo-hold
JOBF="$(grep -rl '^kind: Job' "$MONOREPO/deploy/$WL"/*.yaml 2>/dev/null | head -1)"
if [ -z "$JOBF" ]; then
  echo "ⓘ '$WL' Job 매니페스트 못 찾음 — 스케줄링 hold 건너뜀"
elif grep -q "$HOLDLBL" "$JOBF"; then
  echo "ⓘ 스케줄링 hold 이미 무장됨 ($WL)"
else
  # insert nodeSelector right after the pod-template spec line ("    spec:" at 4-space indent)
  sed -i '0,/^    spec:/s||    spec:\n      nodeSelector:\n        keti.io/demo-hold: "true"|' "$JOBF"
  grep -q "$HOLDLBL" "$JOBF" \
    && echo "✅ 스케줄링 hold 무장 — '$WL' pod에 nodeSelector ${HOLDLBL} (admit 후 스케줄링 직전 대기)" \
    || echo "⚠ 스케줄링 hold 주입 실패 (pod template spec 들여쓰기 확인) — 큐 hold만 적용됨"
fi
echo
echo "▶ 다음 (한 줄기: 큐 → 스케줄링, 같은 워크로드):"
echo "   1) bash 01-gitops/04-drive-demo.sh        # commit·push → CI/ArgoCD 배포 → 🛑 큐에서 대기"
echo "   2) bash 01-gitops/05-queue-release.sh      # 🛑 큐 → release → admit → 파드가 🛑 스케줄링 직전 대기"
echo "   3) bash 02-scheduling/01-schedule-release.sh   # 🛑 스케줄링: 웹훅 주입 확인 → release → 노드 배치 → 실행"
