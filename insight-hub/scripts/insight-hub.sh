#!/usr/bin/env bash
# Insight Hub verification: the insight-scope DaemonSet on the workload's node sends
# node-level metrics to Hub. SQLite keys are node names (node.metadata.name), not pod names.
#
# Usage:
#   ./insight-hub.sh [namespace] [deployment-name]
# Defaults: k8s-admission-webhook preprocessing-workload
#
set -euo pipefail
NS="${1:-k8s-admission-webhook}"
DEP="${2:-preprocessing-workload}"
SCOPE_NS="${INSIGHT_SCOPE_NS:-keti}"
SCOPE_LABEL="${INSIGHT_SCOPE_LABEL:-app=insight-scope}"

echo "== 1) Node where the workload pod is scheduled =="
NODE="$(kubectl get pods -n "$NS" -l "app=${DEP}" -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || true)"
if [[ -z "$NODE" ]]; then
  echo "ERROR: No pod found for ${NS}/app=${DEP}. Check Deployment/pod is Running."
  exit 1
fi
echo "   Node: $NODE"
echo "   (Hub keys must match this node name — not the pod name)"

echo ""
echo "== 2) insight-scope DaemonSet pod on that node =="
SCOPE_POD="$(kubectl get pods -n "$SCOPE_NS" -l "$SCOPE_LABEL" --field-selector "spec.nodeName=${NODE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -z "$SCOPE_POD" ]]; then
  echo "WARN: No insight-scope pod on node=${NODE} in namespace ${SCOPE_NS}."
  echo "      Set INSIGHT_SCOPE_NS / INSIGHT_SCOPE_LABEL if your DaemonSet uses different labels."
else
  echo "   insight-scope pod: $SCOPE_POD (node=$NODE, ns=$SCOPE_NS)"
fi

echo ""
echo "== 3) insight-scope env (Hub ingest) =="
if [[ -n "$SCOPE_POD" ]]; then
  kubectl get pod -n "$SCOPE_NS" "$SCOPE_POD" -o jsonpath='{range .spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' | grep -E 'INSIGHT_HUB_ENDPOINT|FORECASTER_ENDPOINT|ENABLE_FORECASTER' || true
else
  echo "   (skipped)"
fi

echo ""
echo "== 4) Expected logs (scope pod) — grep scope→hub / ForecasterClient =="
if [[ -n "$SCOPE_POD" ]]; then
  echo "   kubectl logs -n ${SCOPE_NS} \"$SCOPE_POD\" --tail=200 | grep -E 'scope→hub|scope-metrics|ForecasterClient|Insight Hub'"
  kubectl logs -n "$SCOPE_NS" "$SCOPE_POD" --tail=200 2>/dev/null | grep -E 'scope→hub|scope-metrics|ForecasterClient|Insight Hub|Connected to' || echo "   (none yet — Hub unreachable or before first flush (~5 min). Use HUB_TRACE_METRICS=1 for per-minute sample logs)"
fi

echo ""
echo "== 5) Hub pod logs — ingest proof [hub.ingest] STORED =="
HUB_K8S_NS="${INSIGHT_HUB_K8S_NS:-keti}"
kubectl get pods -n "$HUB_K8S_NS" -l app=insight-hub -o name 2>/dev/null | head -1 | xargs -r -I{} kubectl logs -n "$HUB_K8S_NS" {} --tail=100 2>/dev/null | grep -E '\[hub\.(startup|ingest)\]' || echo "   (no insight-hub logs — check insight-hub is deployed in namespace ${HUB_K8S_NS})"

echo ""
echo "== 6) Hub에 적재된 데이터 확인 (스크립트) =="
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -x "${SCRIPT_DIR}/check-hub-data.sh" ]]; then
  HUB_NS="${HUB_NS:-keti}" HUB_ADDR="${HUB_ADDR:-insight-hub.keti.svc.cluster.local:50056}" \
    "${SCRIPT_DIR}/check-hub-data.sh" "$NODE" || true
else
  echo "   ${SCRIPT_DIR}/check-hub-data.sh 가 없습니다."
  echo "   수동: grpcurl -plaintext insight-hub.keti.svc.cluster.local:50056 list"
  echo "   If node '$NODE' appears in ListNodes, snapshots for that node exist in the DB."
fi
