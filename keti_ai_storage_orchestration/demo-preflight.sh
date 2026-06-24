#!/usr/bin/env bash
# demo-preflight.sh — gate BEFORE a demo: are all components green and the slate clean?
#
# Portable: uses the LOCAL kubectl (run it on / pointed at the target cluster). No ssh.
# Exits 0 only if every REQUIRED check passes. Optional checks (Kueue, ArgoCD) warn but
# do not fail. Prints a TARGET_NODE you can feed to the orchestration harnesses.
#
#   bash demo-preflight.sh
#   APOLLO_NS=apollo ORCH_NS=kube-system SCHED_NS=keti NS=ai-storage-workloads bash demo-preflight.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/load-env.sh"
NS="${NS:-ai-storage-workloads}"
APOLLO_NS="${APOLLO_NS:-apollo}"
ORCH_NS="${ORCH_NS:-kube-system}"
SCHED_NS="${SCHED_NS:-keti}"

PASS=0; FAIL=0; WARN=0
ok(){   PASS=$((PASS+1)); echo "  ✅ $1"; }
bad(){  FAIL=$((FAIL+1)); echo "  ❌ $1"; }
warn(){ WARN=$((WARN+1)); echo "  ⚠️  $1"; }

echo "== demo preflight =="
command -v kubectl >/dev/null 2>&1 || { echo "❌ kubectl not on PATH"; exit 2; }
kubectl version >/dev/null 2>&1 || { echo "❌ kubectl cannot reach a cluster"; exit 2; }
echo "  context: $(kubectl config current-context 2>/dev/null || echo '?')"

echo
echo "----- REQUIRED: components available -----"
for entry in "$ORCH_NS/ai-storage-orchestrator" "$APOLLO_NS/node-resource-forecaster" \
             "$APOLLO_NS/orchestration-policy-engine" "$SCHED_NS/ai-storage-scheduler"; do
  ns="${entry%%/*}"; dep="${entry##*/}"
  rep=$(kubectl get deploy "$dep" -n "$ns" -o jsonpath='{.status.availableReplicas}' 2>/dev/null)
  [ "${rep:-0}" -ge 1 ] 2>/dev/null && ok "up: $ns/$dep" || bad "DOWN: $ns/$dep (availableReplicas=${rep:-0})"
done
# mutating webhook gateway
kubectl get mutatingwebhookconfiguration 2>/dev/null | grep -qiE 'ai-storage|keti-ai-storage' \
  && ok "webhook gateway present (mutatingwebhookconfiguration)" || bad "ai-storage mutating webhook missing"
# A present webhook config + a Running pod is NOT proof it works: ai-storage-webhook is
# failurePolicy=Ignore, so if its serving cert and the config's caBundle drift (common after a
# redeploy when there is no cert-manager), pods are admitted UN-INJECTED with no error at all.
# Probe injection for real: submit a gated bare pod (its schedulingGate means it never schedules
# or pulls an image) and confirm the webhook injected the custom scheduler + sidecar.
PROBE=preflight-webhook-probe
kubectl delete pod "$PROBE" -n "$NS" --grace-period=0 --force --ignore-not-found >/dev/null 2>&1 || true
if kubectl apply -f - >/dev/null 2>&1 <<EOF
apiVersion: v1
kind: Pod
metadata: { name: $PROBE, namespace: $NS, labels: { demo: admission-trace } }
spec:
  schedulingGates: [{ name: preflight.hold }]
  containers: [{ name: c, image: busybox:1.36, command: ["sh","-c","sleep 30"] }]
EOF
then
  sleep 4
  PSCHED=$(kubectl get pod "$PROBE" -n "$NS" -o jsonpath='{.spec.schedulerName}' 2>/dev/null || true)
  PSIDE=$(kubectl get pod "$PROBE" -n "$NS" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null | tr ' ' '\n' | grep -c insight-trace || true)
  if [ "$PSCHED" = "ai-storage-scheduler" ] && [ "${PSIDE:-0}" -ge 1 ]; then
    ok "webhook ACTUALLY injects (schedulerName=ai-storage-scheduler + insight-trace sidecar)"
  else
    bad "webhook NOT injecting (schedulerName=$PSCHED, sidecar=$([ "${PSIDE:-0}" -ge 1 ] && echo yes || echo no)) — pods slip through un-injected (failurePolicy=Ignore is silent). Cause: caBundle↔serving-cert mismatch (re-sync caBundle to secret ai-storage-webhook-tls), or ns $NS missing label keti-ai-storage-injection=enabled."
  fi
  kubectl delete pod "$PROBE" -n "$NS" --grace-period=0 --force --ignore-not-found >/dev/null 2>&1 || true
else
  warn "could not create webhook injection probe in $NS (skipping real-injection check)"
fi
# workload namespace must exist (and be on the orchestration whitelist)
kubectl get ns "$NS" >/dev/null 2>&1 && ok "workload namespace $NS exists" || bad "workload namespace $NS missing"

echo
echo "----- OPTIONAL: queue + gitops -----"
kubectl get deploy -n kueue-system kueue-controller-manager >/dev/null 2>&1 \
  && ok "Kueue controller up (queue-based admission available)" \
  || warn "Kueue not found — pending/queue demo unavailable"
if kubectl get applications.argoproj.io -n argocd >/dev/null 2>&1; then
  syn=$(kubectl get applications.argoproj.io -n argocd --no-headers 2>/dev/null | grep -c Synced)
  tot=$(kubectl get applications.argoproj.io -n argocd --no-headers 2>/dev/null | wc -l)
  ok "ArgoCD up ($syn/$tot apps Synced) — GitOps demo available"
  kubectl get applications.argoproj.io -n argocd --no-headers 2>/dev/null \
    | awk '$0!~/Synced.*Healthy/{print "       blemish: "$1" "$2" "$3}'
else
  warn "ArgoCD not found — GitOps delivery demo unavailable"
fi

echo
echo "----- REQUIRED: clean slate (no leftovers that contaminate the demo) -----"
mig=$(kubectl get pods -n "$NS" --no-headers 2>/dev/null | grep -c -- '-migrated-')
[ "${mig:-0}" -eq 0 ] && ok "no orphan *-migrated-* pods in $NS" || bad "$mig orphan migrated pod(s) in $NS (run cleanup.sh)"
pol=$(kubectl get orchestrationpolicy -n "$APOLLO_NS" --no-headers 2>/dev/null | grep -c .)
[ "${pol:-0}" -eq 0 ] && ok "no leftover OrchestrationPolicies" || warn "$pol existing OrchestrationPolicy(ies) (cleanup.sh clears them)"
ppvc=$(kubectl get pvc -n "$NS" -l component=provisioning --no-headers 2>/dev/null | grep -cE 'oe2e|scale-cal')
[ "${ppvc:-0}" -eq 0 ] && ok "no leftover provisioning test PVCs" || bad "$ppvc leftover provisioning PVC(s) (run cleanup.sh)"
stray=$(kubectl get pods -n default --no-headers 2>/dev/null | grep -cE 'oe2e|pressure|scale-cal')
[ "${stray:-0}" -eq 0 ] && ok "no stray pressure/oe2e pods in default" || warn "$stray stray pod(s) in default (cleanup.sh clears them)"

echo
echo "----- TARGET_NODE suggestion (largest schedulable worker) -----"
# exclude control-plane (label AND taint), require Ready+schedulable, pick LARGEST allocatable
# CPU -> portable (no hardcoded node), avoids small master-ish nodes. Same logic as run-e2e.sh.
TN=$(kubectl get nodes -o json 2>/dev/null | python3 -c '
import json,sys
def cpum(c):
    c=str(c or "0"); return int(c[:-1]) if c.endswith("m") else int(float(c)*1000)
best="";bc=-1
for n in json.load(sys.stdin).get("items",[]):
    m=n.get("metadata",{});sp=n.get("spec",{});st=n.get("status",{})
    if sp.get("unschedulable"): continue
    lb=m.get("labels",{}) or {}
    if "node-role.kubernetes.io/control-plane" in lb or "node-role.kubernetes.io/master" in lb: continue
    if any(str(t.get("key","")).startswith(("node-role.kubernetes.io/control-plane","node-role.kubernetes.io/master")) for t in (sp.get("taints") or [])): continue
    if {c.get("type"):c.get("status") for c in (st.get("conditions") or [])}.get("Ready")!="True": continue
    cpu=cpum((st.get("allocatable",{}) or {}).get("cpu"))
    if cpu>bc: bc=cpu; best=m.get("name","")
print(best)' 2>/dev/null)
[ -z "$TN" ] && TN=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$TN" ]; then
   alloc=$(kubectl get node "$TN" -o jsonpath='{.status.allocatable.cpu}' 2>/dev/null)
  ok "suggested TARGET_NODE=$TN (allocatable cpu=$alloc)"
  echo "       export it for the harnesses:  export TARGET_NODE=$TN"
else
  bad "no schedulable node found"
fi

echo
echo "== preflight: PASS=$PASS  FAIL=$FAIL  WARN=$WARN =="
if [ "$FAIL" -eq 0 ]; then
  echo "✅ READY — required checks green ($WARN optional warning(s)). Proceed: bash run-e2e.sh"
  exit 0
else
  echo "❌ NOT READY — fix the $FAIL failing required check(s) (often: bash cleanup.sh, or (re)install)."
  exit 1
fi
