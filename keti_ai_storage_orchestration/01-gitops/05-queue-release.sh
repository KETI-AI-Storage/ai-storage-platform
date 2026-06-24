#!/usr/bin/env bash
# 05-queue-release.sh — the runtime tail of the gitops→queue→schedule flow.
#
# After 03-update-workload armed the queue hold (routed the workload to demo-admission-queue) and
# 04-drive-demo deployed it via GitOps, the workload's Job PENDS in the Kueue queue
# (demo-admission-queue is absent → Inadmissible). This script:
#   1. waits for that held Workload to appear in the queue,
#   2. shows it held + PAUSES (🛑 observe it sitting in the queue),
#   3. RELEASES it — creates the demo-admission-queue LocalQueue → Kueue admits → Job unsuspends,
#   4. shows the admitted Job proceeding to scheduling.
#
#   bash 01-gitops/05-queue-release.sh
# Env: QH_NS (default ai-storage-workloads), TIMEOUT (default 600s — GitOps/CI delivery can be slow).
#
# Repeatable: cleanup.sh deletes demo-admission-queue, so the next deploy pends again.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib/load-env.sh"
source "$HERE/../lib/common.sh"
export QH_NS=ai-storage-workloads          # QH_LQ defaults to demo-admission-queue (the hold queue)
source "$HERE/../lib/queue-hold.sh"
TIMEOUT="${TIMEOUT:-600}"

ok(){ echo "  ✅  $*"; }; bad(){ echo "  ❌  $*" >&2; }
hdr(){ echo; echo "══════════════════════════════════════════════"; echo "  $*"; echo "══════════════════════════════════════════════"; }
trace_pause(){ echo; if [ -t 0 ]; then printf '  ⏸  %s\n  → press Enter...' "$1"; read -r _ || true; echo;
               else echo "  (non-interactive: auto-continuing) $1"; sleep 3; fi; }

# echo a Workload routed to the hold queue ($QH_LQ) that is NOT yet admitted (held in the queue)
held_workload(){
  kubectl get workloads -n "$QH_NS" -o json 2>/dev/null | python3 -c '
import json, sys
q = sys.argv[1]
for w in json.load(sys.stdin).get("items", []):
    if w.get("spec", {}).get("queueName") != q:
        continue
    conds = {c.get("type"): c.get("status") for c in w.get("status", {}).get("conditions", [])}
    if conds.get("Admitted") != "True" and not w.get("status", {}).get("admission"):
        print(w["metadata"]["name"]); break' "$QH_LQ"
}

hdr "[05] gitops 배포 워크로드가 🛑 큐에서 대기 → release → admit (스케줄링은 06)"
kubectl cluster-info >/dev/null 2>&1 || { bad "kubectl unreachable"; exit 1; }
echo "  hold 큐: $QH_LQ  (ns=$QH_NS)"
kubectl get localqueue "$QH_LQ" -n "$QH_NS" >/dev/null 2>&1 \
  && echo "  ⓘ $QH_LQ LocalQueue가 이미 존재 — 이미 release됐거나 무장 안 됨. (반복하려면 cleanup.sh 후 03→04 다시)" \
  || ok "$QH_LQ 부재 확인 — 워크로드가 여기서 멈춥니다"

echo "  04가 배포한 워크로드가 큐에서 대기 상태가 되길 기다림 (최대 ${TIMEOUT}s; CI 빌드 포함이면 더 걸림)..."
WL=""; t=0
while [ "$t" -lt "$TIMEOUT" ]; do WL="$(held_workload)"; [ -n "$WL" ] && break; sleep 5; t=$((t+5)); done
[ -n "$WL" ] || { bad "큐에서 대기 중인 워크로드를 못 찾음 — 03(hold-arm)+04(배포)를 먼저 하셨나요?"; exit 1; }
ok "큐에서 대기 중: $WL"

echo
echo "  ── 🛑 STOP — gitops로 배포된 워크로드가 큐에서 실제 대기 중 (Inadmissible) ──"
kubectl get workload "$WL" -n "$QH_NS" \
  -o jsonpath='{range .status.conditions[*]}    {.type}={.status} ({.reason}) {.message}{"\n"}{end}' 2>/dev/null
echo "    파드: $(kubectl get pods -n "$QH_NS" -l "kueue.x-k8s.io/queue-name=$QH_LQ" --no-headers 2>/dev/null | wc -l | tr -d ' ')개 (대기 중엔 0)"
echo "  ──────────────────────────────────────────────────────────────────"
trace_pause "🛑 gitops 배포 워크로드가 큐에서 멈춰 있음. Enter → release(LocalQueue 생성) → admit"

echo "  releasing: creating LocalQueue $QH_LQ → $QH_CQ ..."
qh_release || { bad "qh_release 실패"; exit 1; }

echo "  waiting for $WL to be admitted (up to 120s)..."
t=0
while [ "$t" -lt 120 ]; do
  st="$(kubectl get workload "$WL" -n "$QH_NS" -o jsonpath='{.status.conditions[?(@.type=="Admitted")].status}' 2>/dev/null || true)"
  [ "$st" = "True" ] && break; sleep 5; t=$((t+5))
done
[ "$st" = "True" ] && ok "Workload $WL admitted by Kueue → Job unsuspend → 파드 생성" \
                   || echo "  ⚠ 120s 내 admit 안 됨 — 쿼터/상태 확인: kubectl get workload $WL -n $QH_NS -o yaml"

# Wait for the pod. With 03's SCHEDULING hold (nodeSelector keti.io/demo-hold), the pod is created but
# PENDS at scheduling — 05 STOPS here (does NOT schedule). 01-schedule-release reveals the webhook
# injection and releases scheduling. (If 03 didn't arm the scheduling hold, the pod just auto-schedules.)
echo "  waiting for the pod (up to 60s)..."
POD=""; t=0
while [ "$t" -lt 60 ]; do
  POD=$(kubectl get pods -n "$QH_NS" -l "kueue.x-k8s.io/queue-name=$QH_LQ" --no-headers 2>/dev/null | awk 'NR==1{print $1}')
  [ -n "$POD" ] && break; sleep 3; t=$((t+3))
done

hdr "✅ [큐 단계 완료] gitops 배포 → 🛑 큐 대기 → release → admit → 파드 생성"
if [ -n "$POD" ]; then
  NODE=$(kubectl get pod "$POD" -n "$QH_NS" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)
  if [ -z "$NODE" ]; then
    echo "  파드 $POD = 🛑 스케줄링 직전 대기 중 (nodeSelector keti.io/demo-hold 미충족, 노드 미배치)."
    echo "  ▶ 다음:  bash 02-scheduling/01-schedule-release.sh   # 🛑 스케줄링: 웹훅 주입 확인 → release → 배치"
  else
    echo "  ⓘ 파드가 이미 $NODE 에 배치됨 — 03의 스케줄링 hold가 무장 안 됐을 수 있음."
    echo "    (스케줄링까지 멈춰 보려면: cleanup → 03-update-workload → 04 → 05 → 06)"
  fi
else
  echo "  ⚠ 파드가 아직 안 보임 — 잠시 후:  bash 02-scheduling/01-schedule-release.sh"
fi
echo
echo "  반복하려면:  bash cleanup.sh"
