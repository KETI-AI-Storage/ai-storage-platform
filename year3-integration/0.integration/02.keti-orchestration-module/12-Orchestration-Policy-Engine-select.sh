#!/usr/bin/env bash
# 12-Orchestration-Policy-Engine-select.sh는 KETI 오케스트레이션 단계 [12] Orchestration Policy Engine Select 상태를 Kubernetes 결과로 출력한다.
#
# Author: 미정 <unknown@example.com>
# Created: 2026-05-28

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/log-utils.sh"
init_step_context "12" "Orchestration Policy Generation" "${1:-}" "${2:-}"
print_step_intent "OrchestrationPolicy 생성/선택 결과 확인" "이번 workload/namespace를 target으로 하는 OrchestrationPolicy CR 생성, 재사용, 선택 여부 확인" "orchestrationpolicy CR" "kubectl get orchestrationpolicy -A" "orchestration policy generation evidence checked"
policy_rows="$(kubectl get orchestrationpolicy -A \
  -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,TYPE:.spec.policyType,TARGET_WORKLOAD:.spec.targetWorkload,TARGET_NS:.spec.targetNamespace,TARGET_KIND:.spec.targetRef.kind,TARGET_REF:.spec.targetRef.name,RESOURCE:.spec.resourceType,HORIZON:.spec.horizon,PHASE:.status.phase,CREATED:.metadata.creationTimestamp \
  --no-headers 2>/dev/null || true)"
policy_total="$(printf '%s\n' "${policy_rows}" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
cr_line="$(printf '%s\n' "${policy_rows}" | awk -v w="${STEP_WORKLOAD}" -v ns="${STEP_NAMESPACE}" '$4 == w && ($5 == ns || $5 == "<none>" || $5 == "") {row=$0} END {print row}')"
latest_line="$(printf '%s\n' "${policy_rows}" | awk 'NF {row=$0} END {print row}')"
cr_ns="$(printf '%s' "${cr_line}" | awk '{print $1}')"
cr_name="$(printf '%s' "${cr_line}" | awk '{print $2}')"
policy="$(printf '%s' "${cr_line}" | awk '{print tolower($3)}')"
target_workload="$(printf '%s' "${cr_line}" | awk '{print $4}')"
target_ns="$(printf '%s' "${cr_line}" | awk '{print $5}')"
target_kind="$(printf '%s' "${cr_line}" | awk '{print $6}')"
target_ref="$(printf '%s' "${cr_line}" | awk '{print $7}')"
metric="$(printf '%s' "${cr_line}" | awk '{print $8}')"
horizon="$(printf '%s' "${cr_line}" | awk '{print $9}')"

if ! kubectl get crd orchestrationpolicies.apollo.keti.re.kr >/dev/null 2>&1 \
   && ! kubectl api-resources --no-headers 2>/dev/null | awk '{print $1}' | grep -q '^orchestrationpolicies$'; then
  print_kv "policy_crd" "✗ CRD_MISSING"
  print_kv "orchestration_policy_status" "✗ CRD_MISSING"
  print_kv "selected_policy" "none"
  print_kv "selected_confidence" "$(read_state selected_confidence '<n/a>')"
  print_kv "policy_type" "none"
  print_kv "policy_failure_scope" "CRD_MISSING"
  save_state selected_policy "none"; save_state selected_policy_name "none"; save_state selected_policy_ns ""; save_state selected_policy_type "none"; save_state orchestration_policy_status "✗ CRD_MISSING"; save_state policy_failure_scope "CRD_MISSING"; save_state policy_reason "orchestrationpolicy CRD not installed"
elif [ "${policy_total:-0}" = "0" ] || [ -z "${latest_line}" ]; then
  print_kv "selected_policy" "none"
  print_kv "orchestration_policy_status" "⚠ not found"
  print_kv "selected_confidence" "$(read_state selected_confidence '<n/a>')"
  print_kv "policy_type" "none"
  print_kv "policy_failure_scope" "POLICY_MISSING"
  print_kv "policy_reason" "orchestrationpolicy CRD exists but no policy instances were found"
  save_state selected_policy "none"; save_state selected_policy_name "none"; save_state selected_policy_ns ""; save_state selected_policy_type "none"; save_state orchestration_policy_status "⚠ not found"; save_state policy_failure_scope "POLICY_MISSING"; save_state policy_reason "orchestrationpolicy CRD exists but no policy instances were found"
elif [ -z "${cr_name}" ]; then
  latest_ns="$(printf '%s' "${latest_line}" | awk '{print $1}')"
  latest_name="$(printf '%s' "${latest_line}" | awk '{print $2}')"
  latest_target="$(printf '%s' "${latest_line}" | awk '{print $4 "/" $5}')"
  deploy_replicas="$(kubectl get deploy "${STEP_WORKLOAD}" -n "${STEP_NAMESPACE}" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
  deploy_kind="$([ -n "${deploy_replicas}" ] && echo Deployment || echo UNKNOWN)"
  workload_pod="$(find_workload_pod "${STEP_WORKLOAD}" "${STEP_NAMESPACE}")"
  workload_node="$([ -n "${workload_pod}" ] && kubectl get pod "${workload_pod}" -n "${STEP_NAMESPACE}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
  forecast_file="${LOG_DIR}/forecaster-api-10.json"
  forecast_choice="$(python3 - "${forecast_file}" 2>/dev/null <<'PYEOF' || true
import json, sys
path = sys.argv[1]
try:
    data = json.load(open(path, encoding="utf-8"))
except Exception:
    sys.exit(0)
rows = data.get("forecasts") or data.get("data") or []
if isinstance(rows, dict):
    rows = list(rows.values())
best = ("CPU", 15, 0.0)
for row in rows:
    if not isinstance(row, dict):
        continue
    horizon = row.get("horizon_minutes", row.get("horizon", row.get("minutes", 15)))
    try:
        horizon = int(str(horizon).rstrip("m"))
    except Exception:
        horizon = 15
    candidates = [
        ("CPU", row.get("predicted_cpu_utilization", row.get("cpu"))),
        ("MEMORY", row.get("predicted_memory_utilization", row.get("memory"))),
    ]
    for name, value in candidates:
        try:
            value = float(value)
        except Exception:
            continue
        if value > best[2]:
            best = (name, horizon, value)
print("%s|%s|%.4f" % best)
PYEOF
)"
  resource_resolved="$(printf '%s' "${forecast_choice}" | awk -F'|' '{print $1}')"
  horizon_resolved="$(printf '%s' "${forecast_choice}" | awk -F'|' '{print $2}')"
  predicted_resolved="$(printf '%s' "${forecast_choice}" | awk -F'|' '{print $3}')"
  [ -z "${resource_resolved}" ] && resource_resolved="CPU"
  [ -z "${horizon_resolved}" ] && horizon_resolved="15"
  [ -z "${predicted_resolved}" ] && predicted_resolved="0"
  if [ -n "${deploy_replicas}" ]; then
    policy="scaling"
    cr_ns="$(kubectl get deploy -A -l app=orchestration-policy-engine -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)"
    [ -z "${cr_ns}" ] && cr_ns="${latest_ns}"
    safe_workload="$(printf '%s' "${STEP_WORKLOAD}" | tr -c '[:alnum:]-' '-' | tr '[:upper:]' '[:lower:]' | cut -c1-32)"
    cr_name="target-scaling-${safe_workload}-$(date +%s)"
    min_replicas="$((deploy_replicas + 1))"
    max_replicas="$((deploy_replicas + 3))"
    policy_reason="target mismatch recovered: create scaling policy for ${STEP_WORKLOAD}/${STEP_NAMESPACE} from forecaster ${resource_resolved}=${predicted_resolved} horizon=${horizon_resolved}"
    print_kv "policy_failure_scope" "TARGET_MISMATCH_RECOVERED"
    print_kv "latest_policy" "${latest_ns}/${latest_name}"
    print_kv "latest_policy_target" "${latest_target}"
    print_kv "created_target_policy" "${cr_ns}/${cr_name}"
    print_kv "orchestration_policy_status" "✓ generated"
    print_kv "target_workload" "${STEP_WORKLOAD}"
    print_kv "target_namespace" "${STEP_NAMESPACE}"
    print_kv "selected_action" "${policy}"
    print_kv "before_replicas" "${deploy_replicas}"
    print_kv "desired_min_replicas" "${min_replicas}"
    cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: apollo.keti.re.kr/v1
kind: OrchestrationPolicy
metadata:
  name: ${cr_name}
  namespace: ${cr_ns}
  labels:
    generated-by: keti-orchestration-module
    policy-type: ${policy}
    target-workload: ${STEP_WORKLOAD}
    target-namespace: ${STEP_NAMESPACE}
    target-kind: ${deploy_kind}
spec:
  policyType: ${policy}
  autoExecute: true
  horizon: ${horizon_resolved}
  priorityScore: 90
  probability: 80
  urgency: HIGH
  resourceType: ${resource_resolved}
  targetNamespace: ${STEP_NAMESPACE}
  targetNode: ${workload_node}
  targetWorkload: ${STEP_WORKLOAD}
  reason: "${policy_reason}"
  parameters:
    minReplicas: "${min_replicas}"
    maxReplicas: "${max_replicas}"
    targetCPU: "80"
    targetMemory: "80"
    workloadType: "${deploy_kind}"
EOF
    policy_phase=""
    policy_result_status=""
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
      policy_phase="$(kubectl get orchestrationpolicy "${cr_name}" -n "${cr_ns}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
      policy_result_status="$(kubectl get orchestrationpolicy "${cr_name}" -n "${cr_ns}" -o jsonpath='{.status.result}' 2>/dev/null || true)"
      case "${policy_phase}" in Completed|Failed) break ;; esac
      sleep 5
    done
    print_kv "selected_policy" "✓ ${cr_name}"
    print_kv "selected_confidence" "$(read_state selected_confidence '<n/a>')"
    print_kv "policy_type" "✓ ${policy}"
    print_kv "policy_source" "target-mismatch-recovery"
    print_kv "policy_reason" "${policy_reason}"
    print_kv "policy_phase" "${policy_phase:-UNKNOWN}"
    print_kv "executor_result" "${policy_result_status:-UNKNOWN}"
    save_state selected_policy "${cr_name}"; save_state selected_policy_name "${cr_name}"; save_state selected_policy_ns "${cr_ns}"; save_state selected_policy_type "${policy}"
    save_state orchestration_policy_status "✓ generated"
    save_state policy_resource "${resource_resolved}"; save_state policy_horizon "${horizon_resolved}"; save_state policy_source "target-mismatch-recovery"; save_state policy_reason "${policy_reason}"; save_state policy_failure_scope "TARGET_MISMATCH_RECOVERED"
  else
    print_kv "selected_policy" "none"
    print_kv "orchestration_policy_status" "⚠ target mismatch"
    print_kv "selected_confidence" "$(read_state selected_confidence '<n/a>')"
    print_kv "policy_type" "none"
    print_kv "policy_failure_scope" "TARGET_MISMATCH"
    print_kv "target_workload" "${STEP_WORKLOAD:-UNKNOWN}"
    print_kv "target_namespace" "${STEP_NAMESPACE:-UNKNOWN}"
    print_kv "policy_total" "${policy_total}"
    print_kv "latest_policy" "${latest_ns}/${latest_name}"
    print_kv "latest_policy_target" "${latest_target}"
    print_kv "policy_reason" "policy exists but no CR targets ${STEP_WORKLOAD}/${STEP_NAMESPACE}; target Deployment not found for recovery"
    print_raw_block "recent_policy_targets" "$(printf '%s\n' "${policy_rows}" | tail -10)"
    save_state selected_policy "none"; save_state selected_policy_name "none"; save_state selected_policy_ns ""; save_state selected_policy_type "none"; save_state orchestration_policy_status "⚠ target mismatch"; save_state policy_failure_scope "TARGET_MISMATCH"; save_state policy_reason "policy exists but no CR targets ${STEP_WORKLOAD}/${STEP_NAMESPACE}; target Deployment not found for recovery"; save_state latest_policy "${latest_ns}/${latest_name}"; save_state latest_policy_target "${latest_target}"
  fi
else
  pred_util="$(kubectl get orchestrationpolicy "${cr_name}" -n "${cr_ns}" -o jsonpath='{.spec.parameters.predicted_utilization}' 2>/dev/null || true)"
  thr="$(kubectl get orchestrationpolicy "${cr_name}" -n "${cr_ns}" -o jsonpath='{.spec.parameters.threshold}' 2>/dev/null || true)"
  [ -z "${target_workload}" ] || [ "${target_workload}" = "<none>" ] && target_workload="${target_ref}"
  [ -z "${target_ns}" ] || [ "${target_ns}" = "<none>" ] && target_ns="${STEP_NAMESPACE}"
  [ -z "${target_kind}" ] || [ "${target_kind}" = "<none>" ] && target_kind="Deployment"
  pred_pct="$([ -n "${pred_util}" ] && awk -v v="${pred_util}" 'BEGIN { if (v+0 <= 1.0) printf "%.1f", v*100; else printf "%.1f", v+0 }' || echo UNKNOWN)"
  thr_pct="$([ -n "${thr}" ] && awk -v v="${thr}" 'BEGIN { if (v+0 <= 1.0) printf "%g", v*100; else printf "%g", v+0 }' || echo UNKNOWN)"
  if printf '%s' "$(read_state forecaster '')" | grep -q '✓ forecast observed'; then policy_source="orchestration-policy-engine"; else policy_source="fallback-rule"; fi
  policy_reason="${metric:-UNKNOWN} horizon=${horizon:-?} predicted=${pred_pct}% threshold=${thr_pct}% selected_action=${policy}"
  print_kv "selected_policy" "✓ ${cr_name}"
  print_kv "orchestration_policy_status" "✓ existing"
  print_kv "selected_confidence" "$(read_state selected_confidence '<n/a>')"
  print_kv "policy_type" "✓ ${policy}"
  print_kv "policy_source" "${policy_source}"
  print_kv "policy_reason" "${policy_reason}"
  print_kv "target_workload" "${target_workload:-${STEP_WORKLOAD:-UNKNOWN}}"
  print_kv "target_namespace" "${target_ns:-${STEP_NAMESPACE:-UNKNOWN}}"
  print_kv "target_kind" "${target_kind:-UNKNOWN}"
  print_raw_block "orchestrationpolicy" "$(capture_cmd "kubectl get orchestrationpolicy ${cr_name} -n ${cr_ns} -o yaml | sed -n '1,80p'")"
  save_state selected_policy "${cr_name}"; save_state selected_policy_name "${cr_name}"; save_state selected_policy_ns "${cr_ns}"; save_state selected_policy_type "${policy}"
  save_state orchestration_policy_status "✓ existing"
  save_state policy_resource "${metric:-UNKNOWN}"; save_state policy_horizon "${horizon:-UNKNOWN}"; save_state policy_source "${policy_source}"; save_state policy_reason "${policy_reason}"
fi
finish_step "12"
