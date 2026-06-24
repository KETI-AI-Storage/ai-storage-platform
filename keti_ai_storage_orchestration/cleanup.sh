#!/usr/bin/env bash
# cleanup.sh — remove demo/test artifacts from the CURRENT cluster (portable, local kubectl).
#
# Safe: only touches resources this demo creates (orphan migration products, the demo
# workloads, churned OrchestrationPolicies, checkpoint + provisioning PVCs it left behind).
# Run before/after a demo to guarantee a clean slate.
#
#   bash cleanup.sh
set -uo pipefail
NS="${NS:-ai-storage-workloads}"
APOLLO_NS="${APOLLO_NS:-apollo}"

echo "== cleanup (cluster: $(kubectl config current-context 2>/dev/null || echo '?')) =="

echo "-- orphan migration-product pods in $NS --"
kubectl get pods -n "$NS" --no-headers 2>/dev/null | awk '/-migrated-/{print $1}' \
  | tee /dev/stderr | xargs -r kubectl delete pod -n "$NS" --wait=false >/dev/null

echo "-- demo workloads (oe2e-*, scale-cal) --"
kubectl delete deploy -n "$NS" -l 'app in (oe2e-scale,scale-cal)' --ignore-not-found --wait=false >/dev/null 2>&1
kubectl delete pod   -n "$NS" oe2e-target --ignore-not-found --wait=false >/dev/null 2>&1
kubectl delete pod   -n default --ignore-not-found --wait=false \
  $(kubectl get pods -n default --no-headers 2>/dev/null | awk '/oe2e|pressure|scale-cal/{print $1}') >/dev/null 2>&1 || true

echo "-- demo OrchestrationPolicies in $APOLLO_NS (targetWorkload: oe2e-target, oe2e-scale, scale-cal) --"
# Scope to the demo's own policies only: the policy-engine continuously auto-generates
# policies from live forecasts, and deleting --all can remove a policy just created for a
# real node under genuine load. Filter by targetWorkload matching the demo workloads.
kubectl get orchestrationpolicy -n "$APOLLO_NS" -o json 2>/dev/null \
  | python3 -c '
import json,sys
items=json.load(sys.stdin).get("items",[])
demo={"oe2e-target","oe2e-scale","scale-cal"}
for p in items:
    tw=p.get("spec",{}).get("targetWorkload","")
    if tw in demo:
        print(p["metadata"]["name"])
' | xargs -r kubectl delete orchestrationpolicy -n "$APOLLO_NS" --wait=false >/dev/null 2>&1 || echo "   (none)"

echo "-- checkpoint PVCs (migration) in $NS --"
kubectl get pvc -n "$NS" --no-headers 2>/dev/null | awk '/checkpoint-/{print $1}' \
  | tee /dev/stderr | xargs -r kubectl delete pvc -n "$NS" --wait=false >/dev/null

echo "-- provisioning PVCs left by the demo workloads (component=provisioning) in $NS --"
kubectl get pvc -n "$NS" -l component=provisioning --no-headers 2>/dev/null | awk '{print $1}' \
  | grep -E 'oe2e|scale-cal' | tee /dev/stderr | xargs -r kubectl delete pvc -n "$NS" --wait=false >/dev/null

echo "-- gitops one-flow holds: demo-admission-queue LocalQueue + demo-hold node label --"
# The DEMO-OWNED LocalQueue demo-admission-queue is created by 05-queue-release (the queue RELEASE step).
# It is absent by default and never the cluster's shared ai-storage-queue, so removing it is always safe.
# Removing it also re-holds the gitops workload in the queue, so the one-flow can be replayed.
kubectl delete localqueue demo-admission-queue -n "$NS" --ignore-not-found >/dev/null 2>&1 || true
# Remove the demo scheduling-hold label (set by 02-scheduling/01-schedule-release) from any node.
for n in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  kubectl label node "$n" keti.io/demo-hold- 2>/dev/null || true
done

echo
echo "✅ cleanup done"
