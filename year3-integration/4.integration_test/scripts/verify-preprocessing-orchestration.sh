#!/usr/bin/env bash
set -u

NAMESPACE="${NAMESPACE:-default}"
WORKFLOW_NAME="${WORKFLOW_NAME:-}"
WORKFLOW_LABEL="${WORKFLOW_LABEL:-integration.keti.io/component=preprocessing-pipeline}"
HUB_NAMESPACE="${HUB_NAMESPACE:-keti}"
APOLLO_NAMESPACE="${APOLLO_NAMESPACE:-apollo}"
ORCH_NAMESPACE="${ORCH_NAMESPACE:-kube-system}"
SINCE="${SINCE:-30m}"
BASELINE_FILE="${BASELINE_FILE:-/tmp/preprocessing-orchestration-baseline.env}"
STRICT_ORCHESTRATION="${STRICT_ORCHESTRATION:-1}"
PHASE="check"

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

usage() {
  cat <<USAGE
Usage:
  $0 --phase before|after|check

Environment:
  NAMESPACE              Workflow namespace. Default: default
  WORKFLOW_NAME          Workflow name. If empty, latest preprocessing workflow is used.
  HUB_NAMESPACE          Insight Hub namespace. Default: keti
  APOLLO_NAMESPACE       APOLLO namespace. Default: apollo
  ORCH_NAMESPACE         Orchestrator namespace. Default: kube-system
  SINCE                  Log window. Default: 30m
  BASELINE_FILE          Before/after DB count file. Default: /tmp/preprocessing-orchestration-baseline.env
  STRICT_ORCHESTRATION   If 1, orchestration_results count must increase in --phase after.

Phases:
  before  Capture Insight Hub DB counts before workflow execution.
  after   Compare Insight Hub DB counts after workflow execution and scan logs.
  check   Scan current component state and logs without DB before/after comparison.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase)
      PHASE="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

pass() {
  echo "PASS [$1] $2"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  echo "FAIL [$1] $2"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

warn() {
  echo "WARN [$1] $2"
  WARN_COUNT=$((WARN_COUNT + 1))
}

need_kubectl() {
  if ! command -v kubectl >/dev/null 2>&1; then
    echo "ERROR: kubectl not found" >&2
    exit 1
  fi
}

jsonpath() {
  kubectl "$@" 2>/dev/null || true
}

latest_workflow_name() {
  if [[ -n "${WORKFLOW_NAME}" ]]; then
    echo "${WORKFLOW_NAME}"
    return
  fi

  kubectl get workflows -n "${NAMESPACE}" -l "${WORKFLOW_LABEL}" \
    --sort-by=.metadata.creationTimestamp \
    -o name 2>/dev/null | tail -n 1 | sed 's|.*/||'
}

hub_sql() {
  local sql="$1"
  kubectl -n "${HUB_NAMESPACE}" exec deploy/insight-hub -- sqlite3 /data/insight-hub.db "${sql}" 2>/dev/null
}

hub_count() {
  local table="$1"
  hub_sql "select count(*) from ${table};" | tr -d '[:space:]'
}

check_deploy_available() {
  local ns="$1"
  local kind="$2"
  local name="$3"
  local stage="$4"
  local label="$5"

  if kubectl -n "${ns}" get "${kind}/${name}" >/dev/null 2>&1; then
    local ready
    ready="$(jsonpath -n "${ns}" get "${kind}/${name}" -o jsonpath='{.status.readyReplicas}')"
    if [[ -n "${ready}" && "${ready}" != "0" ]]; then
      pass "${stage}" "${label} is running (${kind}/${name}, readyReplicas=${ready})"
    else
      warn "${stage}" "${label} exists but readyReplicas=${ready:-0}"
    fi
  else
    fail "${stage}" "${label} missing (${kind}/${name} in namespace ${ns})"
  fi
}

check_daemonset_available() {
  local ns="$1"
  local name="$2"
  local stage="$3"
  local label="$4"

  if kubectl -n "${ns}" get "daemonset/${name}" >/dev/null 2>&1; then
    local desired ready
    desired="$(jsonpath -n "${ns}" get "daemonset/${name}" -o jsonpath='{.status.desiredNumberScheduled}')"
    ready="$(jsonpath -n "${ns}" get "daemonset/${name}" -o jsonpath='{.status.numberReady}')"
    if [[ -n "${ready}" && "${ready}" != "0" && "${ready}" == "${desired}" ]]; then
      pass "${stage}" "${label} is running (${ready}/${desired})"
    else
      warn "${stage}" "${label} readiness ${ready:-0}/${desired:-0}"
    fi
  else
    fail "${stage}" "${label} missing (daemonset/${name} in namespace ${ns})"
  fi
}

check_components() {
  echo "=== Component Precheck ==="
  check_deploy_available "${HUB_NAMESPACE}" deploy insight-hub "trace/scope/hub" "insight-hub"
  check_daemonset_available "${HUB_NAMESPACE}" insight-scope "trace/scope/hub" "insight-scope"
  check_deploy_available "${APOLLO_NAMESPACE}" deploy node-resource-forecaster "forecaster" "node-resource-forecaster"
  check_deploy_available "${APOLLO_NAMESPACE}" deploy orchestration-policy-engine "policy" "orchestration-policy-engine"
  check_deploy_available "${ORCH_NAMESPACE}" deploy ai-storage-orchestrator "orchestrator" "ai-storage-orchestrator"

  if kubectl -n "${HUB_NAMESPACE}" get deploy/apollo-policy-server >/dev/null 2>&1; then
    check_deploy_available "${HUB_NAMESPACE}" deploy apollo-policy-server "trace/scope/hub" "apollo-policy-server"
  elif kubectl -n "${APOLLO_NAMESPACE}" get deploy/apollo-policy-server >/dev/null 2>&1; then
    check_deploy_available "${APOLLO_NAMESPACE}" deploy apollo-policy-server "trace/scope/hub" "apollo-policy-server"
  else
    warn "trace/scope/hub" "apollo-policy-server deployment not found in ${HUB_NAMESPACE} or ${APOLLO_NAMESPACE}; WorkloadSignature receive path cannot be verified from deployment logs"
  fi
}

check_hub_tables() {
  echo
  echo "=== Insight Hub DB ==="
  local tables resource_count orch_count
  tables="$(hub_sql ".tables")"
  echo "${tables:-tables unavailable}"

  if grep -qw "resource_snapshots" <<<"${tables}"; then
    pass "trace/scope/hub" "hub table exists: resource_snapshots"
  else
    fail "trace/scope/hub" "hub table missing: resource_snapshots"
  fi

  if grep -qw "orchestration_results" <<<"${tables}"; then
    pass "hub result 저장" "hub table exists: orchestration_results"
  else
    fail "hub result 저장" "hub table missing: orchestration_results"
  fi

  if grep -E 'workload.*(trace|signature)|signature|trace' <<<"${tables}" >/dev/null; then
    pass "trace/scope/hub" "hub workload trace/signature table appears to exist"
  else
    warn "trace/scope/hub" "hub workload trace/signature table not found; current code stores resource snapshots and orchestration results only"
  fi

  resource_count="$(hub_count resource_snapshots)"
  orch_count="$(hub_count orchestration_results)"
  echo "resource_snapshots=${resource_count:-NA}"
  echo "orchestration_results=${orch_count:-NA}"
}

capture_before() {
  echo "=== Capture Baseline ==="
  check_components
  check_hub_tables

  local resource_count orch_count captured_at
  resource_count="$(hub_count resource_snapshots)"
  orch_count="$(hub_count orchestration_results)"
  captured_at="$(date -Iseconds)"

  if [[ -z "${resource_count}" || -z "${orch_count}" ]]; then
    fail "trace/scope/hub" "failed to capture hub DB baseline"
    summary
  fi

  {
    echo "CAPTURED_AT='${captured_at}'"
    echo "RESOURCE_SNAPSHOTS_BEFORE='${resource_count}'"
    echo "ORCHESTRATION_RESULTS_BEFORE='${orch_count}'"
  } > "${BASELINE_FILE}"

  pass "trace/scope/hub" "baseline captured at ${BASELINE_FILE}: resource_snapshots=${resource_count}, orchestration_results=${orch_count}"
}

logs_for_workflow_sidecars() {
  if [[ -z "${WORKFLOW_NAME}" ]]; then
    return
  fi

  kubectl logs -n "${NAMESPACE}" -l "workflows.argoproj.io/workflow=${WORKFLOW_NAME}" \
    -c insight-trace --prefix=true --since="${SINCE}" 2>/dev/null || true
}

check_workflow_trace_logs() {
  echo
  echo "=== Workflow insight-trace Logs ==="
  local logs
  logs="$(logs_for_workflow_sidecars)"
  echo "${logs:-workflow insight-trace logs unavailable}"

  if grep -E 'WorkloadSignature|signature|APOLLO|ReportWorkloadSignature|Final report' <<<"${logs}" >/dev/null; then
    pass "trace/scope/hub" "workflow sidecar produced signature/report related logs"
  else
    fail "trace/scope/hub" "workflow sidecar signature/report logs not found"
  fi

  if grep -E 'Failed|error|connection refused|deadline exceeded' <<<"${logs}" >/dev/null; then
    warn "trace/scope/hub" "workflow sidecar logs include failure/error markers; inspect output above"
  fi
}

component_logs() {
  local ns="$1"
  local target="$2"
  kubectl logs -n "${ns}" "${target}" --since="${SINCE}" --all-containers=true 2>/dev/null || true
}

check_component_logs() {
  echo
  echo "=== Component Logs (${SINCE}) ==="

  local hub_logs scope_logs forecaster_logs policy_logs orchestrator_logs apollo_logs
  hub_logs="$(component_logs "${HUB_NAMESPACE}" deploy/insight-hub)"
  scope_logs="$(component_logs "${HUB_NAMESPACE}" daemonset/insight-scope)"
  forecaster_logs="$(component_logs "${APOLLO_NAMESPACE}" deploy/node-resource-forecaster)"
  policy_logs="$(component_logs "${APOLLO_NAMESPACE}" deploy/orchestration-policy-engine)"
  orchestrator_logs="$(component_logs "${ORCH_NAMESPACE}" deploy/ai-storage-orchestrator)"

  echo "--- insight-hub ---"
  echo "${hub_logs:-no insight-hub logs}"
  echo "--- insight-scope ---"
  echo "${scope_logs:-no insight-scope logs}"
  echo "--- node-resource-forecaster ---"
  echo "${forecaster_logs:-no node-resource-forecaster logs}"
  echo "--- orchestration-policy-engine ---"
  echo "${policy_logs:-no orchestration-policy-engine logs}"
  echo "--- ai-storage-orchestrator ---"
  echo "${orchestrator_logs:-no ai-storage-orchestrator logs}"

  if kubectl -n "${HUB_NAMESPACE}" get deploy/apollo-policy-server >/dev/null 2>&1; then
    apollo_logs="$(component_logs "${HUB_NAMESPACE}" deploy/apollo-policy-server)"
  elif kubectl -n "${APOLLO_NAMESPACE}" get deploy/apollo-policy-server >/dev/null 2>&1; then
    apollo_logs="$(component_logs "${APOLLO_NAMESPACE}" deploy/apollo-policy-server)"
  else
    apollo_logs=""
  fi
  echo "--- apollo-policy-server ---"
  echo "${apollo_logs:-apollo-policy-server logs unavailable}"

  if grep -E 'Received workload signature|WorkloadSignature|ReportWorkloadSignature|workload signature' <<<"${apollo_logs}" >/dev/null; then
    pass "trace/scope/hub" "APOLLO policy-server received WorkloadSignature"
  else
    warn "trace/scope/hub" "APOLLO policy-server WorkloadSignature receive log not found"
  fi

  if grep -E 'SubmitHistoryData|STORED sqlite|resource_snapshots|hub.ingest|history data' <<<"${hub_logs}" >/dev/null ||
     grep -E 'SubmitHistoryData|Submitted history data|metrics.*sent|sampled' <<<"${scope_logs}" >/dev/null; then
    pass "trace/scope/hub" "insight-scope to insight-hub resource history path has activity"
  else
    fail "trace/scope/hub" "scope/hub resource history activity not found"
  fi

  if grep -Ei 'forecast|predict|recommendation|policy' <<<"${forecaster_logs}" >/dev/null; then
    pass "forecaster" "forecaster forecast/recommendation activity found"
  else
    fail "forecaster" "forecaster forecast/recommendation activity not found"
  fi

  if grep -E 'PolicyGenerator|recommendations|OrchestrationPolicy|Policy executed|auto.?execute|migration|provisioning' <<<"${policy_logs}" >/dev/null; then
    pass "policy" "policy engine recommendation/execution activity found"
  else
    fail "policy" "policy engine recommendation/execution activity not found"
  fi

  if grep -Ei 'migration|provisioning|stage|execute|success|failure|orchestration result|publish' <<<"${orchestrator_logs}" >/dev/null; then
    pass "orchestrator" "orchestrator execution/result activity found"
  else
    fail "orchestrator" "orchestrator execution/result activity not found"
  fi

  if grep -E 'hub.orch|orchestration_results|stored orchestration|orchestration result' <<<"${hub_logs}" >/dev/null; then
    pass "hub result 저장" "hub orchestration result log found"
  else
    warn "hub result 저장" "hub orchestration result log not found"
  fi
}

compare_after() {
  echo
  echo "=== Compare Hub DB Counts ==="
  if [[ ! -f "${BASELINE_FILE}" ]]; then
    fail "hub result 저장" "baseline file missing: ${BASELINE_FILE}; run --phase before first"
    return
  fi

  # shellcheck disable=SC1090
  . "${BASELINE_FILE}"

  local resource_after orch_after
  resource_after="$(hub_count resource_snapshots)"
  orch_after="$(hub_count orchestration_results)"

  echo "resource_snapshots_before=${RESOURCE_SNAPSHOTS_BEFORE:-NA} after=${resource_after:-NA}"
  echo "orchestration_results_before=${ORCHESTRATION_RESULTS_BEFORE:-NA} after=${orch_after:-NA}"

  if [[ -n "${resource_after}" && "${resource_after}" -gt "${RESOURCE_SNAPSHOTS_BEFORE:-0}" ]]; then
    pass "trace/scope/hub" "resource_snapshots increased"
  else
    fail "trace/scope/hub" "resource_snapshots did not increase"
  fi

  if [[ -n "${orch_after}" && "${orch_after}" -gt "${ORCHESTRATION_RESULTS_BEFORE:-0}" ]]; then
    pass "hub result 저장" "orchestration_results increased"
  else
    if [[ "${STRICT_ORCHESTRATION}" == "1" ]]; then
      fail "hub result 저장" "orchestration_results did not increase"
    else
      warn "hub result 저장" "orchestration_results did not increase"
    fi
  fi
}

summary() {
  echo
  echo "=== Orchestration Verification Summary ==="
  echo "PASS=${PASS_COUNT} WARN=${WARN_COUNT} FAIL=${FAIL_COUNT}"
  if [[ "${FAIL_COUNT}" -eq 0 ]]; then
    echo "RESULT=PASS"
    exit 0
  fi
  echo "RESULT=FAIL"
  exit 1
}

need_kubectl

case "${PHASE}" in
  before|after|check) ;;
  *)
    echo "ERROR: invalid --phase: ${PHASE}" >&2
    usage
    exit 1
    ;;
esac

WORKFLOW_NAME="$(latest_workflow_name)"

echo "[verify-orchestration] phase: ${PHASE}"
echo "[verify-orchestration] workflow namespace: ${NAMESPACE}"
echo "[verify-orchestration] workflow: ${WORKFLOW_NAME:-not selected}"
echo "[verify-orchestration] hub namespace: ${HUB_NAMESPACE}"
echo "[verify-orchestration] apollo namespace: ${APOLLO_NAMESPACE}"
echo "[verify-orchestration] orchestrator namespace: ${ORCH_NAMESPACE}"
echo "[verify-orchestration] since: ${SINCE}"

case "${PHASE}" in
  before)
    capture_before
    ;;
  after)
    check_components
    check_hub_tables
    check_workflow_trace_logs
    check_component_logs
    compare_after
    ;;
  check)
    check_components
    check_hub_tables
    check_workflow_trace_logs
    check_component_logs
    ;;
esac

summary
