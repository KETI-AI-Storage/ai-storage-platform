#!/usr/bin/env bash
# 01-schedule-release.sh — the SCHEDULING tail of the gitops one-flow (runs after 05).
#
# After 05 released the queue and the workload was admitted, 03's scheduling hold
# (nodeSelector keti.io/demo-hold) keeps the gitops workload's pod PENDING before scheduling. This:
#   1. finds that pod (held before scheduling),
#   2. shows what the webhook injected on it (schedulerName, insight-trace sidecar, storage-tier annots),
#   3. 🛑 PAUSES,
#   4. RELEASES scheduling — labels a feasible node keti.io/demo-hold=true, then makes the held pod
#      schedulable. This scheduler has NO automatic requeue (a freshly-labeled node does NOT rescue an
#      already-unschedulable pod: queue.MoveAllToActiveOrBackoffQueue is a no-op, the 30s
#      flushUnschedulablePodsLeftover is disabled, and a pod-update can't move it out of unschedulablePods),
#      so release = a NON-DESTRUCTIVE scheduler rollout restart, which re-lists pods and re-adds the
#      pending pod straight to the ACTIVE queue (rebuilding the node cache too) → it binds and runs.
#      NO pod deletion: deleting would count as a Job failure and is FATAL for low-backoffLimit Jobs
#      (training-job's is 1 → one delete = dead Job).
#
#   bash 02-scheduling/01-schedule-release.sh
# Env: QH_NS (default ai-storage-workloads). cleanup.sh removes the demo-hold node label.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib/load-env.sh"
source "$HERE/../lib/common.sh"
QH_NS="${QH_NS:-ai-storage-workloads}"
HOLDLBL=keti.io/demo-hold
SCHED_NS="${SCHED_NS:-keti}"                        # ai-storage-scheduler namespace
SCHED_DEPLOY="${SCHED_DEPLOY:-ai-storage-scheduler}"

ok(){ echo "  ✅  $*"; }; bad(){ echo "  ❌  $*" >&2; }
hdr(){ echo; echo "══════════════════════════════════════════════"; echo "  $*"; echo "══════════════════════════════════════════════"; }
trace_pause(){ echo; if [ -t 0 ]; then printf '  ⏸  %s\n  → press Enter...' "$1"; read -r _ || true; echo;
               else echo "  (non-interactive: auto-continuing) $1"; sleep 3; fi; }

# our gitops workload's pods = those carrying the demo-hold nodeSelector
held_pod(){   # Pending, no node assigned (held before scheduling)
  kubectl get pods -n "$QH_NS" -o json 2>/dev/null | python3 -c '
import json, sys
for p in json.load(sys.stdin).get("items", []):
    sp = p.get("spec", {})
    if "keti.io/demo-hold" not in (sp.get("nodeSelector") or {}): continue
    if sp.get("nodeName") or p.get("status", {}).get("phase") != "Pending": continue
    print(p["metadata"]["name"]); break'
}
placed_pod(){ # demo-hold pod that now HAS a node
  kubectl get pods -n "$QH_NS" -o json 2>/dev/null | python3 -c '
import json, sys
for p in json.load(sys.stdin).get("items", []):
    sp = p.get("spec", {})
    if "keti.io/demo-hold" not in (sp.get("nodeSelector") or {}): continue
    if sp.get("nodeName"): print(p["metadata"]["name"], sp["nodeName"]); break'
}
wait_placed(){ # $1=timeout s; echoes "<pod> <node>" once placed, empty on timeout
  local to="$1" t=0 fp nn
  while [ "$t" -lt "$to" ]; do
    read -r fp nn < <(placed_pod); [ -n "$nn" ] && { echo "$fp $nn"; return 0; }
    sleep 5; t=$((t+5))
  done
  return 1
}

hdr "[06] 🛑 스케줄링 직전 대기 → 웹훅 주입 확인 → release → 노드 배치"
kubectl cluster-info >/dev/null 2>&1 || { bad "kubectl unreachable"; exit 1; }

echo "  스케줄링 직전 대기 중인 파드를 찾는 중 (최대 90s; 05를 먼저 돌려야 함)..."
POD=""; t=0
while [ "$t" -lt 90 ]; do POD="$(held_pod)"; [ -n "$POD" ] && break; sleep 3; t=$((t+3)); done
[ -n "$POD" ] || { bad "스케줄링 직전 대기 파드를 못 찾음 — 03(스케줄링 hold)+04+05를 먼저 하셨나요?"; exit 1; }
ok "스케줄링 직전 대기: $POD"

echo
echo "  ── 웹훅이 파드에 주입한 것 (스케줄링 직전, live) ──────────────────"
kubectl get pod "$POD" -n "$QH_NS" -o json 2>/dev/null | python3 -c '
import json, sys
pod = json.load(sys.stdin); spec = pod.get("spec", {}); m = pod.get("metadata", {})
annots = {k: v for k, v in m.get("annotations", {}).items()
          if k.startswith("storage.keti.io/") or k.startswith("ai-storage/")}
print("    schedulerName:", spec.get("schedulerName"))
print("    injected annotations:")
for k, v in sorted(annots.items()): print(f"      {k}: {v}")
print("    containers:", [c.get("name") for c in spec.get("containers", [])])
print("    nodeSelector:", spec.get("nodeSelector"))
print("    phase:", pod.get("status", {}).get("phase"), " nodeName:", spec.get("nodeName") or "(none — 미배치)")
' 2>/dev/null || true
echo "  ──────────────────────────────────────────────────────────────────"

trace_pause "🛑 파드가 스케줄링 직전 대기 중 (nodeSelector ${HOLDLBL} 미충족, 노드 미배치). Enter → 노드 레이블 → ai-storage-scheduler 배치"

# pick a Ready node that satisfies the pod's OTHER nodeSelectors (e.g. nvidia.com/gpu, worker), label it
NEEDSEL="$(kubectl get pod "$POD" -n "$QH_NS" -o json 2>/dev/null | python3 -c '
import json, sys
sel = {k: v for k, v in (json.load(sys.stdin)["spec"].get("nodeSelector") or {}).items() if k != "keti.io/demo-hold"}
print(",".join(f"{k}={v}" for k, v in sel.items()))')"
TN="$(kubectl get nodes ${NEEDSEL:+-l "$NEEDSEL"} -o json 2>/dev/null | python3 -c '
import json, sys
for n in json.load(sys.stdin).get("items", []):
    if n.get("spec", {}).get("unschedulable"): continue
    if {c.get("type"): c.get("status") for c in n.get("status", {}).get("conditions", [])}.get("Ready") != "True": continue
    print(n["metadata"]["name"]); break')"
[ -n "$TN" ] || TN="$(detect_target_node)"
[ -n "$TN" ] || { bad "파드 nodeSelector(${NEEDSEL:-none})를 충족하는 Ready 노드가 없음"; exit 1; }
ok "배치 대상 노드: $TN  (selector: ${NEEDSEL:-none} + ${HOLDLBL})"

echo "  labeling node $TN with $HOLDLBL=true ..."
kubectl label node "$TN" "$HOLDLBL=true" --overwrite >/dev/null 2>&1 || { bad "노드 레이블 실패"; exit 1; }

# Release the held pod NON-DESTRUCTIVELY (never delete it — a delete counts as a Job failure and is
# FATAL for low-backoffLimit Jobs; training-job's backoffLimit is 1). First give the clean auto-path a
# brief chance (works if a scheduler WITH requeue is deployed). This scheduler currently has no auto
# requeue, so fall back to a scheduler rollout restart: on restart the informer re-lists pods and
# re-adds the pending pod straight to the ACTIVE queue (and rebuilds the node cache) → it binds to $TN.
FP=""; NN=""
echo "  노드 레이블 완료 → 자동 재평가를 잠시 대기 (최대 20s)..."
read -r FP NN <<<"$(wait_placed 20)"
if [ -z "$NN" ]; then
  echo "  ⓘ 자동 재큐 없음(이 스케줄러는 unschedulable→active 이동이 비활성) →"
  echo "    스케줄러 rollout restart로 비파괴 재평가 (파드 삭제 안 함): deployment/$SCHED_DEPLOY -n $SCHED_NS"
  kubectl rollout restart "deployment/$SCHED_DEPLOY" -n "$SCHED_NS" >/dev/null 2>&1 \
    || { bad "스케줄러 restart 실패 — 권한/이름 확인 (SCHED_NS=$SCHED_NS SCHED_DEPLOY=$SCHED_DEPLOY)"; exit 1; }
  kubectl rollout status "deployment/$SCHED_DEPLOY" -n "$SCHED_NS" --timeout=120s >/dev/null 2>&1 || true
  echo "    재기동 완료 → 배치 대기 (최대 120s)..."
  read -r FP NN <<<"$(wait_placed 120)"
fi
echo
if [ -n "$NN" ]; then
  echo "  ── 배치 완료 ───────────────────────────────────────────────────────"
  echo "    pod:       $FP"
  echo "    node:      $NN"
  echo "    scheduler: $(kubectl get pod "$FP" -n "$QH_NS" -o jsonpath='{.spec.schedulerName}' 2>/dev/null)"
  echo "    status:    $(kubectl get pod "$FP" -n "$QH_NS" -o jsonpath='{.status.phase}' 2>/dev/null)"
  echo "  ──────────────────────────────────────────────────────────────────"
  ok "ai-storage-scheduler가 $NN 에 배치 → 실행"
  echo "    로그:  kubectl logs -n $QH_NS $FP -f"
else
  bad "120s 내 배치 안 됨"; kubectl get pods -n "$QH_NS" -l "kueue.x-k8s.io/queue-name=demo-admission-queue" -o wide 2>/dev/null
fi

hdr "✅ 한 줄기 완성: gitops 배포 → 🛑큐(05) → release → admit → 🛑스케줄링(06) → 웹훅주입 → release → 배치 → 실행"
echo "  반복하려면:  bash cleanup.sh   (demo-admission-queue + demo-hold 노드 레이블 정리)"
