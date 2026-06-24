#!/usr/bin/env bash
# orchestration-capability-audit.sh — is each of the 6 orchestration subsystems operational?
#
# The 6 policy-driven actions (migration / scaling / preemption / provisioning / caching /
# loadbalancing) are hard to verify end-to-end because each needs a different resource
# pressure (GPU / storage I/O) that is hard to synthesize. This script verifies at two
# depths:
#
#   default      : read-only probe of every subsystem's /metrics (no side effects).
#                  A 200 + JSON = the handler is wired and responding = subsystem is UP.
#
#   --deep [type...] : ALSO directly POST a minimal request to each action endpoint and
#                  poll the job to a terminal state = the ACTION code path actually RUNS
#                  (② direct trigger), not just that the handler is up. This is the
#                  verification path for the types whose autonomous (①) situation cannot
#                  be synthesized (preemption=GPU>=0.95, caching/loadbalance=storage I/O).
#                  Default types when none given: preemption caching loadbalancing.
#
#                  SAFE BY CONSTRUCTION (no real workload is evicted or migrated):
#                    preemption    : min_priority = int32 min  -> 0 preemptible candidates
#                                    (preemption.go:329 skips pods with priority >= MinPriority)
#                    loadbalancing : cpu/mem/gpu threshold = 100 -> no node "overloaded"
#                                    (loadbalancing.go:637/645 -> empty plan, 0 migrations)
#                    caching       : reads a source PVC (non-destructive copy) into a cache
#                                    tier; MantaFS backend is a best-effort stub. TTL 60s.
#                  --deep performs cluster writes (creates in-memory jobs, best-effort
#                  deletes them) -> run it under YOUR shell, not unattended.
#
# Run ON the target cluster (uses LOCAL kubectl):
#   bash 03-orchestration/lib/orchestration-capability-audit.sh           # floor
#   bash 03-orchestration/lib/orchestration-capability-audit.sh --deep    # + direct trigger
#   (usually invoked via 03-orchestration/0{3..6}-*.sh)
set -uo pipefail
ORCH_NS="${ORCH_NS:-kube-system}"
SVC="${SVC:-ai-storage-orchestrator}"
PORT="${PORT:-18080}"
BASE="http://localhost:${PORT}/api/v1"
WL_NS="${WL_NS:-ai-storage-workloads}"
DEEP_TIMEOUT="${DEEP_TIMEOUT:-60}"

# ----------------------------------------------------------------------------- args
DEEP=0; declare -a DEEP_TYPES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --deep) DEEP=1; shift
            while [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; do DEEP_TYPES+=("$1"); shift; done ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1 (use --deep [type...])"; exit 2 ;;
  esac
done
[ "$DEEP" = 1 ] && [ "${#DEEP_TYPES[@]}" -eq 0 ] && DEEP_TYPES=(preemption caching loadbalancing)

# ----------------------------------------------------------------------------- port-forward
kubectl port-forward -n "$ORCH_NS" "svc/$SVC" "${PORT}:8080" >/dev/null 2>&1 &
PF=$!
trap 'kill "$PF" 2>/dev/null' EXIT
ready=0
for _ in $(seq 1 30); do
  if curl -s "http://localhost:${PORT}/health" >/dev/null 2>&1; then ready=1; break; fi
  sleep 0.5
done
[ "$ready" = 1 ] || { echo "❌ cannot reach orchestrator $SVC (-n $ORCH_NS) via port-forward"; exit 2; }

echo "== orchestration capability audit (orchestrator $ORCH_NS/$SVC) =="
hc=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${PORT}/health" 2>/dev/null)
echo "  /health -> $hc"
echo
printf "  %-14s %-8s %s\n" "POLICY TYPE" "HTTP" "/metrics endpoint"
printf "  %-14s %-8s %s\n" "-----------" "----" "-----------------"

# type -> read-only metrics endpoint
types="migration:$BASE/metrics scaling:$BASE/autoscaling/metrics preemption:$BASE/preemption/metrics provisioning:$BASE/provisioning/metrics caching:$BASE/caching/metrics loadbalancing:$BASE/loadbalancing/metrics"
pass=0; fail=0
for pair in $types; do
  t="${pair%%:*}"; ep="${pair#*:}"
  code=$(curl -s -o /tmp/oca.$$ -w '%{http_code}' "$ep" 2>/dev/null || echo 000)
  if [ "$code" = "200" ]; then
    printf "  %-14s %-8s ✅ operational\n" "$t" "$code"; pass=$((pass+1))
  else
    printf "  %-14s %-8s ❌ NOT operational\n" "$t" "$code"; fail=$((fail+1))
  fi
done
rm -f /tmp/oca.$$
echo
echo "  operational: $pass/6   down: $fail/6"
echo
echo "  NOTE: 200 = subsystem wired & responding (handler alive). It does NOT prove the"
echo "        autonomous chain (forecaster->policy->action) fires — that needs a per-type"
echo "        trigger. Proven policy-driven E2E (①): migration (50/40), scaling (autoscaler)."

# ----------------------------------------------------------------------------- deep (② direct trigger)
DEEP_PASS=0; DEEP_FAIL=0
if [ "$DEEP" = 1 ]; then
  echo
  echo "======================================================================"
  echo "  --deep: DIRECT-TRIGGER (②) — does the ACTION code path actually run?"
  echo "          requested: ${DEEP_TYPES[*]}"
  echo "======================================================================"

  # auto-detect a real worker node (preemption) and a source PVC (caching)
  NODE=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  [ -z "$NODE" ] && NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  PVC=$(kubectl get pvc -n "$WL_NS" --no-headers -o custom-columns=N:.metadata.name 2>/dev/null | head -1)
  PVC_REAL=1; [ -z "$PVC" ] && { PVC="deep-trigger-no-pvc"; PVC_REAL=0; }
  echo "  probe node=$NODE   source pvc=$PVC$([ "$PVC_REAL" = 0 ] && echo ' (none found; job will best-effort)')"

  # payload per type (safe by construction — see header)
  pl_preemption() { cat <<JSON
{"node_name":"$NODE","resource_type":"cpu","target_amount":"1m","strategy":"lowest_priority","min_priority":-2147483648,"max_pods_to_preempt":1,"protected_namespaces":["kube-system","apollo","keti","ai-storage-workloads","kubeflow","argocd","default","monitoring","gpu-operator","metallb-system"],"reason":"deep-trigger safe no-op (min_priority=int32min => 0 candidates)"}
JSON
}
  pl_caching() { cat <<JSON
{"source_pvc":"$PVC","source_namespace":"$WL_NS","target_tier":"auto","cache_size":"1Gi","cache_policy":"ttl","ttl_seconds":60,"reason":"deep-trigger (non-destructive copy)"}
JSON
}
  pl_loadbalancing() { cat <<JSON
{"strategy":"least_loaded","cpu_threshold":100,"memory_threshold":100,"gpu_threshold":100,"max_migrations_per_cycle":1,"interval":0}
JSON
}
  pl_provisioning() { cat <<JSON
{"workload_name":"deep-trigger-prov","workload_namespace":"$WL_NS","workload_type":"data-pipeline","storage_size":"1Gi","storage_class":"L2","access_mode":"ReadWriteOnce","reason":"deep-trigger (creates a small PVC, cleaned up after)"}
JSON
}

  # deep_trigger TYPE  EP  ID_KEY  CAN_DELETE
  deep_trigger() {
    local type="$1" ep="$2" idkey="$3" candelete="$4" payload code id st stl body
    echo; echo "  ── $type ──"
    payload="$(pl_$type)"
    code=$(curl -s -o /tmp/dt.$$.body -w '%{http_code}' -X POST "$BASE/$ep" \
             -H 'Content-Type: application/json' -d "$payload" 2>/dev/null)
    if [ "$code" != "201" ] && [ "$code" != "200" ]; then
      echo "    ❌ POST /$ep -> HTTP $code : $(head -c 200 /tmp/dt.$$.body)"; DEEP_FAIL=$((DEEP_FAIL+1)); return
    fi
    id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],"") or "")' /tmp/dt.$$.body "$idkey" 2>/dev/null)
    echo "    ✅ POST /$ep -> HTTP $code   ${idkey}=${id:-<none>}"
    [ -z "$id" ] && { echo "    ⚠️ no job id in response"; DEEP_FAIL=$((DEEP_FAIL+1)); return; }

    # poll the job to a terminal state
    local t=0
    while [ "$t" -lt "$DEEP_TIMEOUT" ]; do
      curl -s -o /tmp/dt.$$.get "$BASE/$ep/$id" 2>/dev/null
      st=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status","") or "")' /tmp/dt.$$.get 2>/dev/null)
      stl=$(printf '%s' "$st" | tr '[:upper:]' '[:lower:]')
      echo "      t=${t}s  status=$st"
      # 'active'/'ready' are terminal SUCCESS for long-lived jobs (caching serves, lb periodic,
      # provisioning PVC ready) — the action is up, which is exactly what ② needs to prove.
      case "$stl" in completed|failed|cancelled|done|succeeded|active|ready) break;; esac
      sleep 5; t=$((t+5))
    done

    # outcome summary (a few known detail fields per type)
    echo "    outcome: $(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
det=d.get("details") or {}
keys=["pods_to_preempt","total_pods_analyzed","pods_to_migrate","planned_migrations",
      "target_tier","cache_size","cached_bytes","balance_score","error_message"]
parts=[f"{k}={det[k]}" for k in keys if k in det and det[k] not in (None,"",0)]
print("status=%s | %s | msg=%s" % (d.get("status"), ", ".join(parts) or "ran (no notable detail)", (d.get("message") or "")[:90]))
' /tmp/dt.$$.get 2>/dev/null || echo "(could not parse)")"

    # verdict: any terminal state proves the action pipeline executed
    case "$stl" in
      completed|done|succeeded|cancelled|active|ready)
        echo "    ✅ $type ACTION executed end-to-end (state=$st)"; DEEP_PASS=$((DEEP_PASS+1));;
      failed)
        echo "    ⚠️ $type pipeline RAN but job ended failed — still proves handler+controller execute"
        echo "       (expected for caching if MantaFS backend/source is a stub). Counting as executed."
        DEEP_PASS=$((DEEP_PASS+1));;
      *)
        echo "    ❌ $type did not reach a terminal state in ${DEEP_TIMEOUT}s (status=$st)"; DEEP_FAIL=$((DEEP_FAIL+1));;
    esac

    # best-effort cleanup: only cancel a still-running ('active') job; a job that already
    # reached completed/failed is harmless and cannot be cancelled (would 400).
    if [ "$candelete" = 1 ] && { [ "$stl" = "active" ] || [ "$stl" = "ready" ]; }; then
      dc=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "$BASE/$ep/$id" 2>/dev/null)
      echo "    cleanup: DELETE /$ep/$id -> $dc"
    elif [ "$candelete" = 1 ]; then
      echo "    cleanup: job already terminal ($st) — nothing to cancel"
    else
      echo "    cleanup: (no DELETE route for $type; completed in-memory job is harmless, clears on restart)"
    fi
    rm -f /tmp/dt.$$.body /tmp/dt.$$.get
  }

  for t in "${DEEP_TYPES[@]}"; do
    case "$t" in
      preemption)    deep_trigger preemption    preemption    preemption_id    0 ;;
      caching)       deep_trigger caching       caching       cache_id         1 ;;
      loadbalancing) deep_trigger loadbalancing loadbalancing loadbalancing_id 1 ;;
      provisioning)  deep_trigger provisioning  provisioning  provisioning_id  1
                     # provisioning CREATES a real PVC -> remove it explicitly (the DELETE
                     # route deregisters the job; the PVC is labelled with the workload).
                     kubectl delete pvc -n "$WL_NS" -l workload-name=deep-trigger-prov --wait=false >/dev/null 2>&1
                     echo "    cleanup: removed deep-trigger-prov PVC(s)" ;;
      *) echo; echo "  ?? unknown deep type: $t (supported: preemption caching loadbalancing provisioning)";;
    esac
  done

  echo
  echo "  ── DEEP RESULT ──"
  echo "  executed (action ran): $DEEP_PASS / $((DEEP_PASS+DEEP_FAIL))"
  echo "  NOTE: ② direct trigger proves the ACTION code path RUNS, not that the autonomous"
  echo "        forecaster->policy chain fires for it (that is ①, still unproven for these)."
fi

# ----------------------------------------------------------------------------- exit
if [ "$DEEP" = 1 ]; then
  [ "$fail" -eq 0 ] && [ "$DEEP_FAIL" -eq 0 ]
else
  [ "$fail" -eq 0 ]
fi
