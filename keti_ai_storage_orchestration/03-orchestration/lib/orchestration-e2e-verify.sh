#!/usr/bin/env bash
# orchestration-e2e-verify.sh
#
# Validates the KETI AI Storage *policy-driven autonomous orchestration* chain
# end-to-end, with per-stage PASS/FAIL and automatic cleanup.
#
# Parametrized by POLICY_TYPE (default: migration). Both modes prove the SAME
# autonomous chain -- load -> forecaster -> policy-engine -> orchestrator action --
# differing only in the situation synthesized and the action asserted:
#
#   POLICY_TYPE=migration  (node CPU CRITICAL > 85%)
#     [1] deploy a migratable workload (completed-step + running-step) + webhook
#     [2] CPU pressure -> node cpu_requests/capacity > 85%
#     [3] forecaster flags the node CRITICAL
#     [4] policy-engine auto-generates a migration policy
#     [5] orchestrator migrates: optimized pod on ANOTHER node, running-step only
#         (completed-step EXCLUDED = the saving), original deleted
#     [6] savings: CPU ~50% (45-55%), Mem ~40% (35-45%)
#     [7] idempotency: exactly ONE migration despite N policies
#
#   POLICY_TYPE=scaling    (node CPU STRESSED, warning band ~0.42 <= forecast < critical)
#     [1] deploy a scalable Deployment (request sized to the STRESSED band) + webhook
#     [2] node cpu_requests/capacity inside the STRESSED window [42%, 85%)
#     [3] forecaster flags the node in the warning/scaling band
#     [4] policy-engine auto-generates a scaling policy targeting the Deployment
#     [5] orchestrator activates an autoscaler for that workload (status=active)
#     [6] the active autoscaler is bound to OUR workload
#         NOTE: actual replica arithmetic (util -> desired replicas) is util-driven,
#         so an idle workload does NOT change replica count -- that math is proven
#         deterministically in autoscaling_test.go (TestCalculateDesiredReplicas),
#         not by burning >node-capacity of CPU live. This harness proves the
#         autonomous DETECT->DECIDE->ACTIVATE wiring; the unit test proves the action.
#     [7] idempotency: exactly ONE autoscaler despite N scaling policies (reuse)
#
# IMPORTANT (project rule): the action is triggered by LOAD -> the autonomous chain,
# never by a manual orchestrator API call. This harness honors that in both modes.
#
# Run ON the target cluster (uses LOCAL kubectl). Usually invoked via the wrappers
# 03-orchestration/01-migration.sh / 02-scaling.sh (which auto-detect TARGET_NODE):
#     POLICY_TYPE=migration bash 03-orchestration/lib/orchestration-e2e-verify.sh
#     POLICY_TYPE=scaling   bash 03-orchestration/lib/orchestration-e2e-verify.sh
#
# Override via env: POLICY_TYPE, TARGET_NODE, PRESSURE_CPU, SCALE_CPU, TIMEOUT, NS, KEEP=1.
set -uo pipefail

# ----------------------------------------------------------------------------- config
POLICY_TYPE="${POLICY_TYPE:-migration}"   # migration | scaling
NS="${NS:-ai-storage-workloads}"          # workload namespace (must be on the orchestration whitelist)
APOLLO_NS="${APOLLO_NS:-apollo}"          # forecaster + policy-engine
ORCH_NS="${ORCH_NS:-kube-system}"         # orchestrator
SCHED_NS="${SCHED_NS:-keti}"              # scheduler
TARGET_NODE="${TARGET_NODE:-}"                # worker node to load (auto-detected below if empty)
PRESSURE_CPU="${PRESSURE_CPU:-}"              # cpu cores to push the node >85% (migration); auto-sized to ~90% if empty
SCALE_CPU="${SCALE_CPU:-}"                     # cpu cores for the scalable Deployment (scaling); auto ~68% of node if empty
TIMEOUT="${TIMEOUT:-300}"                 # per-stage wait timeout (s)
POLL="${POLL:-10}"                        # poll interval (s)
KEEP="${KEEP:-0}"                         # KEEP=1 to leave artifacts for inspection

case "$POLICY_TYPE" in
  migration|scaling) ;;
  *) echo "unsupported POLICY_TYPE=$POLICY_TYPE (use: migration | scaling)"; exit 2 ;;
esac

# auto-detect the target node if not provided (portable: no hardcoded node name). The
# wrappers (01-migration.sh/02-scaling.sh) set TARGET_NODE; this covers standalone runs.
if [ -z "$TARGET_NODE" ]; then
  _cmn="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/../../lib/common.sh"
  [ -f "$_cmn" ] && . "$_cmn" && TARGET_NODE="$(detect_target_node)"
  [ -n "$TARGET_NODE" ] || { echo "TARGET_NODE not set and auto-detect failed — pass TARGET_NODE=<node>"; exit 2; }
fi

WL="oe2e-target"                          # migratable workload pod (migration)
LOAD="oe2e-pressure"                      # cpu pressure pod (migration; in 'default' = NOT whitelisted, never a target)
SWL="oe2e-scale"                          # scalable Deployment (scaling)

ORIG_CPU=0; ORIG_MEM=0                     # captured in migration stage 1
declare -a RESULTS; PASS=0; FAIL=0

# ----------------------------------------------------------------------------- helpers
ts()   { date +%H:%M:%S; }
log()  { echo "[$(ts)] $*"; }
step() { echo; echo "========== $* =========="; }
ok()   { PASS=$((PASS+1)); RESULTS+=("PASS  $1"); echo "  ✅ PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); RESULTS+=("FAIL  $1"); echo "  ❌ FAIL: $1${2:+ -- $2}"; }

# wait_until DESC TIMEOUT 'shell-expr-returning-0-when-ready'
wait_until() {
  local desc="$1" to="$2" expr="$3" t=0
  printf '  waiting: %s ' "$desc"
  while (( t < to )); do
    if eval "$expr" >/dev/null 2>&1; then echo " ok(${t}s)"; return 0; fi
    printf '.'; sleep "$POLL"; t=$((t+POLL))
  done
  echo " TIMEOUT(${to}s)"; return 1
}

# pod_req NS POD  ->  prints "millicpu mebimem" (sum of container requests)
pod_req() {
  kubectl get pod -n "$1" "$2" -o json 2>/dev/null | python3 -c '
import json,sys
def mc(c):
    if not c: return 0
    c=str(c).strip()
    return int(c[:-1]) if c.endswith("m") else int(float(c)*1000)
def mi(m):
    if not m: return 0
    m=str(m).strip()
    for k,v in {"Ki":1/1024,"Mi":1,"Gi":1024,"Ti":1048576}.items():
        if m.endswith(k): return int(float(m[:-2])*v)
    try: return int(int(m)/1048576)
    except: return 0
cpu=mem=0
try:
    for c in json.load(sys.stdin)["spec"]["containers"]:
        r=c.get("resources",{}).get("requests",{})
        cpu+=mc(r.get("cpu")); mem+=mi(r.get("memory"))
except Exception: pass
print(cpu,mem)'
}

# node_alloc_cpu NODE -> integer allocatable cpu cores
node_alloc_cpu() {
  local c; c=$(kubectl get node "$1" -o jsonpath='{.status.allocatable.cpu}' 2>/dev/null)
  case "$c" in
    *m) echo $(( ${c%m} / 1000 ));;
    "") echo 0;;
    *)  echo "$c";;
  esac
}

# node_cpu_req_pct NODE -> integer Requests% from the Allocated-resources table
node_cpu_req_pct() {
  kubectl describe node "$1" 2>/dev/null \
    | awk '/Allocated resources/{f=1} f&&/^[[:space:]]*cpu[[:space:]]/{print; exit}' \
    | grep -oE '\([0-9]+%\)' | head -1 | tr -dc '0-9'
}

# clear BOTH modes' load artifacts then wait for TARGET_NODE to drain below $1% (default 40,
# the STRESSED floor) so a chained run (run-demo: migration -> scaling) starts on a clean
# node. Async (--wait=false) deletes from a prior phase leave the pressure pod Terminating;
# without this the next phase sizes its load against a still-loaded node and mis-fires.
drain_node() {
  local thr="${1:-40}" t=0 p
  kubectl delete pod -n default oe2e-pressure --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl delete pod -n "$NS" oe2e-target --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl delete deploy -n "$NS" oe2e-scale --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl get pods -n "$NS" --no-headers 2>/dev/null | awk '/-migrated-/{print $1}' \
    | xargs -r kubectl delete pod -n "$NS" --wait=false >/dev/null 2>&1
  printf '  draining %s to <%s%% ' "$TARGET_NODE" "$thr"
  while [ "$t" -lt 120 ]; do
    p=$(node_cpu_req_pct "$TARGET_NODE")
    [ "${p:-100}" -lt "$thr" ] 2>/dev/null && { echo " ok(${p}%, ${t}s)"; return 0; }
    printf '.'; sleep 6; t=$((t+6))
  done
  echo " timeout(${p}%); proceeding"
}

migrated_pod() { kubectl get pods -n "$NS" --no-headers 2>/dev/null | awk -v p="$WL-migrated" 'index($1,p)==1{print $1; exit}'; }

# scaling policies for TARGET_NODE (one per line)
scaling_policies() {
  kubectl get orchestrationpolicy -n "$APOLLO_NS" --no-headers 2>/dev/null \
    | awk -v n="$TARGET_NODE" '$1 ~ ("scaling-" n){print $1}'
}

# active_autoscaler -> echoes "POLICY|result" of a scaling policy whose autoscaler
# is active; returns 0 if found, 1 otherwise. Safe under wait_until's eval (no `exit`
# that would kill the script -- it returns instead).
active_autoscaler() {
  local p r
  for p in $(scaling_policies); do
    r=$(kubectl get orchestrationpolicy -n "$APOLLO_NS" "$p" -o jsonpath='{.status.result}' 2>/dev/null)
    if echo "$r" | grep -q "type=autoscaling" && echo "$r" | grep -q "status=active"; then
      echo "$p|$r"; return 0
    fi
  done
  return 1
}

# ----------------------------------------------------------------------------- cleanup
cleanup_migration() {
  step "CLEANUP"
  kubectl delete pod -n "$NS" "$WL" --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl delete pod -n default "$LOAD" --ignore-not-found --wait=false >/dev/null 2>&1
  local mp; mp=$(migrated_pod); [ -n "$mp" ] && kubectl delete pod -n "$NS" "$mp" --wait=false >/dev/null 2>&1
  kubectl get orchestrationpolicy -n "$APOLLO_NS" --no-headers 2>/dev/null \
    | awk -v n="$TARGET_NODE" '$1 ~ ("migration-" n) {print $1}' \
    | xargs -r kubectl delete orchestrationpolicy -n "$APOLLO_NS" --wait=false >/dev/null 2>&1
  kubectl get pvc -n "$NS" --no-headers 2>/dev/null | awk '/checkpoint-/{print $1}' \
    | xargs -r kubectl delete pvc -n "$NS" --wait=false >/dev/null 2>&1
  log "cleaned: $WL, $LOAD, migrated pod, migration-$TARGET_NODE-* policies, checkpoint PVCs"
}

cleanup_scaling() {
  step "CLEANUP"
  kubectl delete deploy -n "$NS" "$SWL" --ignore-not-found --wait=false >/dev/null 2>&1
  # the STRESSED node also makes the forecaster emit provisioning(GPU warn) on GPU
  # nodes -> clear both scaling- and provisioning- policies for the node.
  kubectl get orchestrationpolicy -n "$APOLLO_NS" --no-headers 2>/dev/null \
    | awk -v n="$TARGET_NODE" '$1 ~ ("scaling-" n) || $1 ~ ("provisioning-" n){print $1}' \
    | xargs -r kubectl delete orchestrationpolicy -n "$APOLLO_NS" --wait=false >/dev/null 2>&1
  # provisioning(GPU-warn) co-fires on scaling load and ACTUALLY creates a real PVC for
  # the target workload (component=provisioning, workload-name=$SWL). Earlier this PVC was
  # leaked because cleanup only removed the Deployment+policies. Remove it explicitly.
  kubectl delete pvc -n "$NS" -l "component=provisioning,workload-name=$SWL" --wait=false >/dev/null 2>&1
  log "cleaned: deploy $SWL, scaling-/provisioning-$TARGET_NODE policies, provisioning PVC (workload-name=$SWL)"
  log "note: the orchestrator's in-memory autoscaler goes inert once $SWL is gone (cleared on restart)."
}

cleanup() {
  [ "$KEEP" = "1" ] && { echo; log "KEEP=1 -> leaving artifacts (manual cleanup needed)"; return; }
  case "$POLICY_TYPE" in
    scaling) cleanup_scaling ;;
    *)       cleanup_migration ;;
  esac
}
trap cleanup EXIT

# ----------------------------------------------------------------------------- [0] preflight (shared)
preflight() {
  step "[0] PREFLIGHT (POLICY_TYPE=$POLICY_TYPE)"
  kubectl version >/dev/null 2>&1 || { echo "kubectl not configured for the target cluster"; exit 2; }
  kubectl get node "$TARGET_NODE" >/dev/null 2>&1 \
    && ok "target node $TARGET_NODE exists" || { bad "target node $TARGET_NODE missing"; exit 2; }
  for entry in "$ORCH_NS/ai-storage-orchestrator" "$APOLLO_NS/node-resource-forecaster" \
               "$APOLLO_NS/orchestration-policy-engine" "$SCHED_NS/ai-storage-scheduler"; do
    ns="${entry%%/*}"; dep="${entry##*/}"
    rep=$(kubectl get deploy "$dep" -n "$ns" -o jsonpath='{.status.availableReplicas}' 2>/dev/null)
    [ "${rep:-0}" -ge 1 ] 2>/dev/null && ok "component up: $ns/$dep" || bad "component down: $ns/$dep"
  done
}

# ============================================================================= MIGRATION
run_migration() {
  # drain any prior-phase load (e.g. scaling's Deployment) so the node starts clean and the
  # generator does not pick a foreign workload as the migration victim.
  drain_node 40
  # Clean a dirty slate before starting. Leftover *-migrated-* pods in $NS are the
  # #1 contaminant: the generator picks an already-migrated leftover as the victim
  # instead of our workload, and re-migrating it fails on a duplicate
  # checkpoint-volume. Clear them + any stale migration-$TARGET_NODE policies.
  leftover=$(kubectl get pods -n "$NS" --no-headers 2>/dev/null | awk '/-migrated-/{print $1}')
  if [ -n "$leftover" ]; then
    log "WARN: clearing leftover migrated pods in $NS: $(echo "$leftover" | tr '\n' ' ')"
    echo "$leftover" | xargs -r kubectl delete pod -n "$NS" --wait=false >/dev/null 2>&1
  fi
  pre=$(kubectl get orchestrationpolicy -n "$APOLLO_NS" --no-headers 2>/dev/null | grep -c "migration-$TARGET_NODE")
  if [ "${pre:-0}" -gt 0 ]; then
    log "WARN: clearing $pre pre-existing migration-$TARGET_NODE policies (stale)"
    kubectl get orchestrationpolicy -n "$APOLLO_NS" --no-headers 2>/dev/null \
      | awk -v n="$TARGET_NODE" '$1 ~ ("migration-" n){print $1}' \
      | xargs -r kubectl delete orchestrationpolicy -n "$APOLLO_NS" --wait=false >/dev/null 2>&1
  fi

  # ------------------------------------------------------------------------- [1] workload
  step "[1] DEPLOY MIGRATABLE WORKLOAD ($WL on $TARGET_NODE)"
  # bare Pod (no controller -> no recreate) pinned via nodeName (no hostname nodeSelector:
  # the orchestrator copies nodeSelector onto the migrated pod and it would be rejected).
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $WL
  namespace: $NS
  labels: {app: $WL}
  annotations: {mlops.keti.io/main-container: running-step}
spec:
  nodeName: $TARGET_NODE
  restartPolicy: Never
  containers:
    - name: completed-step          # exits 0 -> Completed -> EXCLUDED on migration = the saving
      image: busybox:1.36
      command: ["sh","-c","echo preprocess; sleep 20; echo done; exit 0"]
      resources: {requests: {cpu: "1", memory: 2Gi}, limits: {cpu: "1", memory: 2Gi}}
    - name: running-step            # long-lived -> carried over to the target node
      image: busybox:1.36
      command: ["sh","-c","echo serving; while true; do sleep 30; done"]
      resources: {requests: {cpu: "1", memory: 3Gi}, limits: {cpu: "1", memory: 3Gi}}
EOF
  if wait_until "running-step Running" 120 \
     "[ \"\$(kubectl get pod -n $NS $WL -o jsonpath='{.status.containerStatuses[?(@.name==\"running-step\")].ready}' 2>/dev/null)\" = true ]"; then
    ok "workload running-step is Running"
  else bad "workload did not reach Running"; fi
  # completed-step must reach Completed for the saving to exist
  wait_until "completed-step Completed" 60 \
    "kubectl get pod -n $NS $WL -o jsonpath='{.status.containerStatuses[?(@.name==\"completed-step\")].state.terminated.reason}' 2>/dev/null | grep -q Completed" \
    && ok "completed-step reached Completed (exit 0)" || bad "completed-step not Completed"
  # webhook injection
  [ "$(kubectl get pod -n "$NS" "$WL" -o jsonpath='{.spec.schedulerName}' 2>/dev/null)" = "ai-storage-scheduler" ] \
    && ok "webhook injected schedulerName=ai-storage-scheduler" || bad "schedulerName not injected"
  kubectl get pod -n "$NS" "$WL" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null | grep -q insight-trace \
    && ok "webhook injected insight-trace sidecar" || bad "insight-trace sidecar not injected"
  read -r ORIG_CPU ORIG_MEM < <(pod_req "$NS" "$WL")
  log "original pod requests: cpu=${ORIG_CPU}m mem=${ORIG_MEM}Mi"

  # ------------------------------------------------------------------------- [2] pressure
  # size pressure to push the node to ~90% TOTAL cpu requests (>85% CRITICAL), accounting
  # for the workload + baseline already on the node -> portable across node sizes (a fixed
  # core count breaks on smaller nodes: 55 cores does not fit a 40-core node).
  if [ -z "$PRESSURE_CPU" ]; then
    palloc=$(node_alloc_cpu "$TARGET_NODE"); pcur=$(node_cpu_req_pct "$TARGET_NODE")
    PRESSURE_CPU=$(awk -v a="$palloc" -v c="${pcur:-0}" 'BEGIN{v=a*0.90-a*c/100; printf "%d", (v<1?1:v)}')
    log "auto-sized PRESSURE_CPU=$PRESSURE_CPU (node alloc=${palloc} cores, currently ${pcur}% -> target ~90%)"
  fi
  step "[2] APPLY CPU PRESSURE ($PRESSURE_CPU cores on $TARGET_NODE)"
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $LOAD
  namespace: default
  labels: {keti-ai-storage-injection: disabled}
spec:
  nodeName: $TARGET_NODE
  restartPolicy: Never
  containers:
    - name: pressure
      image: busybox:1.36
      command: ["sh","-c","sleep infinity"]
      resources: {requests: {cpu: "${PRESSURE_CPU}", memory: 256Mi}}
EOF
  wait_until "pressure pod Running" 120 \
    "[ \"\$(kubectl get pod -n default $LOAD -o jsonpath='{.status.phase}' 2>/dev/null)\" = Running ]" \
    && ok "pressure pod Running" || bad "pressure pod not Running"
  # Read the Requests percentage from the Allocated-resources table. The cpu row is
  # "cpu  57000m (89%)  2 (3%)" -> Requests%=first (NN%), Limits%=second.
  pct=$(node_cpu_req_pct "$TARGET_NODE")
  if [ "${pct:-0}" -ge 85 ] 2>/dev/null; then ok "node cpu requests at ${pct}% (>85%)"; else bad "node cpu only at ${pct:-?}% (<85%)"; fi

  # ------------------------------------------------------------------------- [3] forecaster
  step "[3] FORECASTER detects CRITICAL"
  if wait_until "forecaster CRITICAL for $TARGET_NODE" "$TIMEOUT" \
     "kubectl logs -n $APOLLO_NS deploy/node-resource-forecaster --tail=120 2>/dev/null | grep -i $TARGET_NODE | grep -qiE 'critical|recommendation'"; then
    ok "forecaster emitted recommendation/CRITICAL for $TARGET_NODE"
  else bad "forecaster never flagged $TARGET_NODE (soft)"; fi

  # ------------------------------------------------------------------------- [4] policy-engine
  step "[4] POLICY-ENGINE auto-generates migration policy"
  if wait_until "migration policy for $TARGET_NODE" "$TIMEOUT" \
     "kubectl get orchestrationpolicy -n $APOLLO_NS --no-headers 2>/dev/null | grep -q 'migration-$TARGET_NODE'"; then
    pol=$(kubectl get orchestrationpolicy -n "$APOLLO_NS" --no-headers 2>/dev/null | awk -v n="$TARGET_NODE" '$1 ~ ("migration-" n){print $1; exit}')
    ok "migration policy auto-generated: $pol"
  else bad "no migration policy generated"; fi

  # ------------------------------------------------------------------------- [5] orchestrator
  step "[5] ORCHESTRATOR executes migration"
  wait_until "optimized (migrated) pod appears" "$TIMEOUT" \
    "kubectl get pods -n $NS --no-headers 2>/dev/null | grep -q '$WL-migrated'"
  MP=$(migrated_pod)
  if [ -n "$MP" ]; then
    ok "optimized pod created: $MP"
    mnode=$(kubectl get pod -n "$NS" "$MP" -o jsonpath='{.spec.nodeName}' 2>/dev/null)
    [ -n "$mnode" ] && [ "$mnode" != "$TARGET_NODE" ] \
      && ok "migrated to a DIFFERENT node: $mnode" || bad "migrated pod not on a different node (node=$mnode)"
    cnames=$(kubectl get pod -n "$NS" "$MP" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null)
    echo "$cnames" | grep -q running-step && ok "migrated pod keeps running-step" || bad "migrated pod missing running-step"
    echo "$cnames" | grep -q completed-step && bad "completed-step was NOT excluded (still present)" || ok "completed-step EXCLUDED from migrated pod"
    wait_until "original $WL deleted" 90 "! kubectl get pod -n $NS $WL >/dev/null 2>&1" \
      && ok "original workload deleted" || bad "original workload still present"
  else
    bad "no optimized pod -> migration did not complete"
    log "orchestrator tail:"; kubectl logs -n "$ORCH_NS" deploy/ai-storage-orchestrator --tail=15 2>/dev/null | sed 's/^/    /'
  fi

  # ------------------------------------------------------------------------- [6] savings
  step "[6] SAVINGS (request-based, completed-step excluded)"
  # Re-resolve the migrated pod and retry the read until its requests are non-zero. A single
  # immediate read can return 0 -- right after migration the optimized pod is briefly not
  # retrievable by name (it appears in the LIST before `get <name>` resolves), and under node
  # pressure the API call can transiently fail -> 0. Retrying makes the saving measurement
  # robust (the migration itself is already verified above).
  MIG_CPU=0; MIG_MEM=0
  for _ in $(seq 1 20); do
    MP=$(migrated_pod)
    [ -n "$MP" ] && read -r MIG_CPU MIG_MEM < <(pod_req "$NS" "$MP")
    [ "${MIG_CPU:-0}" -gt 0 ] && break
    sleep 3
  done
  if [ -n "$MP" ] && [ "$ORIG_CPU" -gt 0 ] && [ "${MIG_CPU:-0}" -gt 0 ]; then
    scpu=$(( (ORIG_CPU - MIG_CPU) * 100 / ORIG_CPU ))
    smem=$(( (ORIG_MEM - MIG_MEM) * 100 / ORIG_MEM ))
    log "CPU ${ORIG_CPU}m -> ${MIG_CPU}m = ${scpu}%   |   Mem ${ORIG_MEM}Mi -> ${MIG_MEM}Mi = ${smem}%"
    { [ "$scpu" -ge 45 ] && [ "$scpu" -le 55 ]; } && ok "CPU saving ${scpu}% ~= 50%" || bad "CPU saving ${scpu}% outside 45-55%"
    { [ "$smem" -ge 35 ] && [ "$smem" -le 45 ]; } && ok "Mem saving ${smem}% ~= 40%" || bad "Mem saving ${smem}% outside 35-45%"
  else
    bad "cannot compute savings (migrated pod requests unreadable=${MIG_CPU:-?}, or missing baseline ORIG_CPU=${ORIG_CPU})"
  fi

  # ------------------------------------------------------------------------- [7] idempotency
  step "[7] IDEMPOTENCY (#14: one migration despite N policies)"
  npol=$(kubectl get orchestrationpolicy -n "$APOLLO_NS" --no-headers 2>/dev/null | grep -c "migration-$TARGET_NODE")
  nmig=$(kubectl get pods -n "$NS" --no-headers 2>/dev/null | grep -c "$WL-migrated")
  log "migration policies=${npol}  migrated pods=${nmig}"
  # Idempotency means EXACTLY ONE migration despite N policies. nmig==0 is not a
  # pass: it means the migration never happened (see stage [5]).
  if [ "${nmig:-0}" -eq 1 ]; then
    ok "exactly one migration (no churn) even with ${npol} policies"
  elif [ "${nmig:-0}" -eq 0 ]; then
    bad "idempotency not demonstrated: no migration occurred (${npol} policies, 0 migrated pods)"
  else
    bad "multiple migrated pods (${nmig}) -> idempotency broken"
  fi
}

# ============================================================================= SCALING
run_scaling() {
  # drain any prior-phase load (e.g. migration's 55-core pressure pod still Terminating) so
  # the STRESSED-band sizing below is computed against a clean node, not a contaminated one.
  drain_node 40
  # clear any prior run's Deployment + stale scaling policies for the node
  kubectl delete deploy -n "$NS" "$SWL" --ignore-not-found --wait=false >/dev/null 2>&1
  pre=$(scaling_policies | grep -c .)
  if [ "${pre:-0}" -gt 0 ]; then
    log "WARN: clearing $pre pre-existing scaling-$TARGET_NODE policies (stale)"
    scaling_policies | xargs -r kubectl delete orchestrationpolicy -n "$APOLLO_NS" --wait=false >/dev/null 2>&1
  fi

  # size the request to bring the node to ~68% TOTAL cpu requests (STRESSED band),
  # accounting for any existing baseline. The forecaster's LSTM smooths, so ~68%
  # requests forecasts ~0.44 -> warning/scaling (well below the ~0.85 CRITICAL that
  # would instead yield migration).
  local alloc curpct; alloc=$(node_alloc_cpu "$TARGET_NODE"); curpct=$(node_cpu_req_pct "$TARGET_NODE")
  if [ -z "$SCALE_CPU" ]; then
    SCALE_CPU=$(awk -v a="$alloc" -v c="${curpct:-0}" 'BEGIN{printf "%d", a*0.68 - a*c/100}')
  fi
  if [ "${SCALE_CPU:-0}" -lt 1 ] 2>/dev/null; then
    bad "node $TARGET_NODE already at ${curpct}% cpu requests (>= ~68% target) -- remove other load first (e.g. calibration 'scale-cal'), then re-run"
    return
  fi
  log "node $TARGET_NODE alloc=${alloc} cores, currently ${curpct}% -> Deployment requests SCALE_CPU=${SCALE_CPU} to reach ~68% (STRESSED band)"

  # ------------------------------------------------------------------------- [1] workload
  step "[1] DEPLOY SCALABLE WORKLOAD (Deployment $SWL on $TARGET_NODE)"
  # A Deployment (the scaling target: the autoscaler scales replicas of a Deployment).
  # Pinned via nodeName so the request lands on $TARGET_NODE deterministically.
  kubectl apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $SWL
  namespace: $NS
  labels: {app: $SWL}
spec:
  replicas: 1
  selector: {matchLabels: {app: $SWL}}
  template:
    metadata: {labels: {app: $SWL}}
    spec:
      nodeName: $TARGET_NODE
      containers:
        - name: load
          image: busybox:1.36
          command: ["sh","-c","sleep infinity"]
          resources: {requests: {cpu: "${SCALE_CPU}", memory: 256Mi}}
EOF
  if wait_until "$SWL pod Ready" 120 \
     "[ \"\$(kubectl get deploy -n $NS $SWL -o jsonpath='{.status.readyReplicas}' 2>/dev/null)\" = 1 ]"; then
    ok "scalable Deployment $SWL has a Ready replica"
  else bad "$SWL did not become Ready"; fi
  SPOD=$(kubectl get pods -n "$NS" -l app="$SWL" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  # webhook injection (proves the mutating webhook fires on Deployment-managed pods too)
  [ "$(kubectl get pod -n "$NS" "$SPOD" -o jsonpath='{.spec.schedulerName}' 2>/dev/null)" = "ai-storage-scheduler" ] \
    && ok "webhook injected schedulerName=ai-storage-scheduler" || bad "schedulerName not injected"
  kubectl get pod -n "$NS" "$SPOD" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null | grep -q insight-trace \
    && ok "webhook injected insight-trace sidecar" || bad "insight-trace sidecar not injected"

  # ------------------------------------------------------------------------- [2] STRESSED band
  step "[2] NODE IN STRESSED BAND (42% <= cpu_requests < 85%)"
  wait_until "$SWL pod scheduled on $TARGET_NODE" 60 \
    "[ \"\$(kubectl get pod -n $NS $SPOD -o jsonpath='{.spec.nodeName}' 2>/dev/null)\" = $TARGET_NODE ]" >/dev/null 2>&1
  pct=$(node_cpu_req_pct "$TARGET_NODE")
  if [ "${pct:-0}" -ge 42 ] 2>/dev/null && [ "${pct:-100}" -lt 85 ] 2>/dev/null; then
    ok "node cpu requests at ${pct}% (STRESSED: 42-85%, NOT CRITICAL)"
  elif [ "${pct:-0}" -ge 85 ] 2>/dev/null; then
    bad "node cpu at ${pct}% (>=85% = CRITICAL -> would trigger migration, not scaling; lower SCALE_CPU)"
  else
    bad "node cpu only at ${pct:-?}% (<42% = below warning; raise SCALE_CPU)"
  fi

  # ------------------------------------------------------------------------- [3] forecaster
  step "[3] FORECASTER detects warning/STRESSED"
  if wait_until "forecaster warning band for $TARGET_NODE" "$TIMEOUT" \
     "kubectl logs -n $APOLLO_NS deploy/node-resource-forecaster --tail=120 2>/dev/null | grep -i $TARGET_NODE | grep -qiE 'warning|stressed|scaling|recommendation'"; then
    ok "forecaster emitted warning/recommendation for $TARGET_NODE"
  else bad "forecaster never flagged $TARGET_NODE (soft)"; fi

  # ------------------------------------------------------------------------- [4] policy-engine
  step "[4] POLICY-ENGINE auto-generates scaling policy (targets the Deployment)"
  if wait_until "scaling policy for $TARGET_NODE" "$TIMEOUT" \
     "kubectl get orchestrationpolicy -n $APOLLO_NS --no-headers 2>/dev/null | grep -q 'scaling-$TARGET_NODE'"; then
    SPOL=$(scaling_policies | head -1)
    ok "scaling policy auto-generated: $SPOL"
    tw=$(kubectl get orchestrationpolicy -n "$APOLLO_NS" "$SPOL" -o jsonpath='{.spec.targetWorkload}' 2>/dev/null)
    [ "$tw" = "$SWL" ] && ok "policy targetWorkload=$tw (our Deployment)" \
      || bad "policy targetWorkload=$tw (expected $SWL)"
  else bad "no scaling policy generated"; SPOL=""; fi

  # ------------------------------------------------------------------------- [5] orchestrator
  step "[5] ORCHESTRATOR activates an autoscaler (status=active)"
  # Poll any scaling policy until one has executed and its result reports the autoscaler active.
  RES=""
  wait_until "a scaling policy executes (autoscaler active)" "$TIMEOUT" "active_autoscaler"
  hit=$(active_autoscaler) && { SPOL="${hit%%|*}"; RES="${hit#*|}"; }
  if [ -n "$RES" ]; then
    ok "autoscaler activated by autonomous chain: ${RES}"
    ph=$(kubectl get orchestrationpolicy -n "$APOLLO_NS" "$SPOL" -o jsonpath='{.status.phase}' 2>/dev/null)
    [ "$ph" = "Executing" ] && ok "policy phase=Executing (auto-approved + running)" || bad "policy phase=$ph (expected Executing)"
  else
    bad "no scaling policy reached an active autoscaler"
    log "orchestrator tail:"; kubectl logs -n "$ORCH_NS" deploy/ai-storage-orchestrator --tail=15 2>/dev/null | sed 's/^/    /'
  fi

  # ------------------------------------------------------------------------- [6] action binding
  step "[6] AUTOSCALER BOUND TO WORKLOAD ($SWL)"
  if [ -n "$RES" ]; then
    tw=$(kubectl get orchestrationpolicy -n "$APOLLO_NS" "$SPOL" -o jsonpath='{.spec.targetWorkload}' 2>/dev/null)
    [ "$tw" = "$SWL" ] && ok "active autoscaler is bound to our Deployment ($tw)" \
      || bad "active autoscaler bound to $tw (expected $SWL)"
    reps=$(kubectl get deploy -n "$NS" "$SWL" -o jsonpath='{.spec.replicas}' 2>/dev/null)
    log "replicas=${reps} (unchanged: workload is idle -> util ~0%; replica arithmetic is"
    log "  proven deterministically in autoscaling_test.go::TestCalculateDesiredReplicas,"
    log "  not by a live >node-capacity CPU burn. This stage proves the autonomous wiring.)"
  else
    bad "no active autoscaler to bind-check"
  fi

  # ------------------------------------------------------------------------- [7] idempotency
  step "[7] IDEMPOTENCY (one autoscaler despite N scaling policies)"
  # let the forecaster emit a second batch so N>=2 policies exist, then assert they
  # all reference ONE autoscaler id (the orchestrator reuses, does not duplicate).
  wait_until ">=2 scaling policies (second forecaster batch)" 120 \
    "[ \"\$(scaling_policies | grep -c .)\" -ge 2 ]" >/dev/null 2>&1
  npol=$(scaling_policies | grep -c .)
  ids=$(for p in $(scaling_policies); do
          kubectl get orchestrationpolicy -n "$APOLLO_NS" "$p" -o jsonpath='{.status.result}' 2>/dev/null \
            | grep -oE 'id=autoscaler-[a-z0-9]+'
        done | sort -u)
  nids=$(echo "$ids" | grep -c .)
  log "scaling policies=${npol}  distinct autoscaler ids=${nids}  [${ids//$'\n'/ }]"
  if [ "${nids:-0}" -eq 1 ]; then
    ok "exactly one autoscaler (reused) despite ${npol} scaling policies"
  elif [ "${nids:-0}" -eq 0 ]; then
    bad "idempotency not demonstrated: no autoscaler activated (${npol} policies)"
  else
    bad "multiple autoscalers (${nids}) -> idempotency broken"
  fi

  # [INFO] provisioning co-fire (informational only — does NOT affect PASS/FAIL)
  # The GPU-warn band can cause the forecaster to also emit a provisioning policy, which
  # the orchestrator acts on by creating a real Bound PVC. This is cluster-dependent
  # (only on GPU-warn nodes). Logged here as an observation; never calls bad().
  _prov_pvcs=$(kubectl get pvc -n "$NS" -l "component=provisioning,workload-name=$SWL" --no-headers 2>/dev/null | wc -l)
  log "provisioning co-fire: ${_prov_pvcs} PVC(s) with component=provisioning,workload-name=$SWL in $NS (informational; cluster-dependent; not asserted)"
}

# ----------------------------------------------------------------------------- main
preflight
case "$POLICY_TYPE" in
  scaling)   run_scaling ;;
  *)         run_migration ;;
esac

# ----------------------------------------------------------------------------- report
step "RESULT (POLICY_TYPE=$POLICY_TYPE)"
for r in "${RESULTS[@]}"; do echo "  $r"; done
echo; echo "  PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && { echo "  ✅ ORCHESTRATION E2E ($POLICY_TYPE): ALL CHECKS PASSED"; exit 0; } \
                  || { echo "  ❌ ORCHESTRATION E2E ($POLICY_TYPE): $FAIL CHECK(S) FAILED"; exit 1; }
