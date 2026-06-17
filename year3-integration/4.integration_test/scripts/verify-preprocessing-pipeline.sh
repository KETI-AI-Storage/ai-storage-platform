#!/usr/bin/env bash
set -u

NAMESPACE="${NAMESPACE:-default}"
WORKFLOW_NAME="${WORKFLOW_NAME:-}"
WORKFLOW_LABEL="${WORKFLOW_LABEL:-integration.keti.io/component=preprocessing-pipeline}"
FORBIDDEN_LOG_PATTERN="${FORBIDDEN_LOG_PATTERN:-manifest not found|model artifact missing|fallback chunks|fallback model}"
MODE="all"

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

usage() {
  cat <<USAGE
Usage:
  NAMESPACE=default WORKFLOW_NAME=<workflow-name> $0 [--mode all|workflow|storage]

Modes:
  all       Check workflow, webhook/sidecar, artifacts, logs, PVC, StorageClass, PV, and mounts.
  workflow  Check workflow status, containers, artifact logs, fallback markers.
  storage   Check namespace injection, PVC tiering, StorageClass, PV, and Pod volume mounts.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="${2:-}"
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

workflow_name() {
  if [[ -n "${WORKFLOW_NAME}" ]]; then
    echo "${WORKFLOW_NAME}"
    return
  fi

  kubectl get workflows -n "${NAMESPACE}" -l "${WORKFLOW_LABEL}" \
    --sort-by=.metadata.creationTimestamp \
    -o name 2>/dev/null | tail -n 1 | sed 's|.*/||'
}

pods_for_workflow() {
  kubectl get pods -n "${NAMESPACE}" -l "workflows.argoproj.io/workflow=${WORKFLOW_NAME}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null
}

pvc_names_for_workflow() {
  kubectl get pvc -n "${NAMESPACE}" -l "workflows.argoproj.io/workflow=${WORKFLOW_NAME}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null
}

check_preconditions() {
  echo "=== Preconditions ==="
  if kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
    pass "precheck" "namespace exists: ${NAMESPACE}"
  else
    fail "precheck" "namespace missing: ${NAMESPACE}"
    return
  fi

  if kubectl get crd workflows.argoproj.io >/dev/null 2>&1; then
    pass "precheck" "Argo Workflow CRD exists"
  else
    fail "precheck" "Argo Workflow CRD workflows.argoproj.io missing"
  fi

  local ns_label
  ns_label="$(jsonpath get namespace "${NAMESPACE}" -o jsonpath='{.metadata.labels["keti-ai-storage-injection"]}')"
  if [[ "${ns_label}" == "enabled" ]]; then
    pass "webhook/sidecar" "namespace injection label keti-ai-storage-injection=enabled"
  else
    fail "webhook/sidecar" "namespace injection label missing or not enabled"
  fi

  if kubectl get mutatingwebhookconfiguration >/dev/null 2>&1 &&
     kubectl get mutatingwebhookconfiguration -o name | grep -E 'ai-storage|keti|webhook' >/dev/null 2>&1; then
    pass "webhook/sidecar" "mutating webhook configuration found"
  else
    fail "webhook/sidecar" "mutating webhook configuration not found"
  fi
}

check_workflow() {
  echo
  echo "=== Workflow ==="
  if kubectl get workflow "${WORKFLOW_NAME}" -n "${NAMESPACE}" -o wide; then
    pass "workflow" "workflow exists: ${WORKFLOW_NAME}"
  else
    fail "workflow" "workflow not found: ${WORKFLOW_NAME}"
    return
  fi

  local phase progress
  phase="$(jsonpath get workflow "${WORKFLOW_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}')"
  progress="$(jsonpath get workflow "${WORKFLOW_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.progress}')"
  echo "phase=${phase:-NA} progress=${progress:-NA}"
  if [[ "${phase}" == "Succeeded" ]]; then
    pass "workflow" "workflow phase is Succeeded"
  else
    fail "workflow" "workflow phase is ${phase:-unknown}; expected Succeeded"
  fi

  echo
  echo "=== Pods ==="
  kubectl get pods -n "${NAMESPACE}" -l "workflows.argoproj.io/workflow=${WORKFLOW_NAME}" -o wide
}

check_pod_containers() {
  echo
  echo "=== Pod Containers, Webhook Mutation, Sidecar ==="
  local pods pod container_names scheduler share main_exit sidecar_exit sidecar_reason sidecar_env oom
  pods="$(pods_for_workflow)"
  if [[ -z "${pods}" ]]; then
    fail "workflow" "no workflow pods found"
    return
  fi

  for pod in ${pods}; do
    echo "--- pod/${pod} ---"
    container_names="$(jsonpath get pod "${pod}" -n "${NAMESPACE}" -o jsonpath='{range .spec.containers[*]}{.name}{" "}{end}')"
    scheduler="$(jsonpath get pod "${pod}" -n "${NAMESPACE}" -o jsonpath='{.spec.schedulerName}')"
    share="$(jsonpath get pod "${pod}" -n "${NAMESPACE}" -o jsonpath='{.spec.shareProcessNamespace}')"
    main_exit="$(jsonpath get pod "${pod}" -n "${NAMESPACE}" -o jsonpath='{.status.containerStatuses[?(@.name=="main")].state.terminated.exitCode}')"
    sidecar_exit="$(jsonpath get pod "${pod}" -n "${NAMESPACE}" -o jsonpath='{.status.containerStatuses[?(@.name=="insight-trace")].state.terminated.exitCode}')"
    sidecar_reason="$(jsonpath get pod "${pod}" -n "${NAMESPACE}" -o jsonpath='{.status.containerStatuses[?(@.name=="insight-trace")].state.terminated.reason}')"
    sidecar_env="$(jsonpath get pod "${pod}" -n "${NAMESPACE}" -o jsonpath='{range .spec.containers[?(@.name=="insight-trace")].env[*]}{.name}={.value}{"\n"}{end}' | grep '^CONTAINER_NAME=' || true)"
    oom="$(jsonpath get pod "${pod}" -n "${NAMESPACE}" -o jsonpath='{range .status.containerStatuses[*]}{.name}:{.lastState.terminated.reason}:{.state.terminated.reason}{"\n"}{end}' | grep OOMKilled || true)"

    echo "containers=${container_names}"
    echo "schedulerName=${scheduler:-NA} shareProcessNamespace=${share:-NA}"
    echo "main exitCode=${main_exit:-NA}"
    echo "insight-trace exitCode=${sidecar_exit:-NA} reason=${sidecar_reason:-NA}"
    echo "insight-trace env ${sidecar_env:-CONTAINER_NAME missing}"

    if grep -qw "insight-trace" <<<"${container_names}"; then
      pass "webhook/sidecar" "${pod}: insight-trace container present"
    else
      fail "webhook/sidecar" "${pod}: insight-trace container missing"
    fi

    if [[ "${scheduler}" == "ai-storage-scheduler" ]]; then
      pass "webhook/sidecar" "${pod}: schedulerName mutated to ai-storage-scheduler"
    else
      fail "webhook/sidecar" "${pod}: schedulerName=${scheduler:-NA}; expected ai-storage-scheduler"
    fi

    if [[ "${share}" == "true" ]]; then
      pass "webhook/sidecar" "${pod}: shareProcessNamespace=true"
    else
      fail "webhook/sidecar" "${pod}: shareProcessNamespace=${share:-NA}; expected true"
    fi

    if [[ "${sidecar_env}" == "CONTAINER_NAME=main" ]]; then
      pass "webhook/sidecar" "${pod}: insight-trace CONTAINER_NAME=main"
    else
      fail "webhook/sidecar" "${pod}: insight-trace CONTAINER_NAME is not main"
    fi

    if [[ "${main_exit}" == "0" ]]; then
      pass "workflow" "${pod}: main container exited 0"
    else
      fail "workflow" "${pod}: main container exitCode=${main_exit:-NA}"
    fi

    if [[ "${sidecar_exit}" == "0" && "${sidecar_reason}" == "Completed" ]]; then
      pass "webhook/sidecar" "${pod}: insight-trace Completed without error"
    else
      fail "webhook/sidecar" "${pod}: insight-trace exitCode=${sidecar_exit:-NA} reason=${sidecar_reason:-NA}"
    fi

    if [[ -z "${oom}" ]]; then
      pass "webhook/sidecar" "${pod}: no OOMKilled container state"
    else
      fail "webhook/sidecar" "${pod}: OOMKilled found: ${oom}"
    fi
  done
}

check_logs_and_artifacts() {
  echo
  echo "=== Main Logs ==="
  kubectl logs -n "${NAMESPACE}" -l "workflows.argoproj.io/workflow=${WORKFLOW_NAME}" -c main --prefix=true || true

  echo
  echo "=== Fallback Log Scan ==="
  if kubectl logs -n "${NAMESPACE}" -l "workflows.argoproj.io/workflow=${WORKFLOW_NAME}" -c main --prefix=true 2>/dev/null | grep -E "${FORBIDDEN_LOG_PATTERN}"; then
    fail "artifact 연결" "forbidden fallback log pattern found"
  else
    pass "artifact 연결" "no forbidden fallback log pattern found"
  fi

  echo
  echo "=== Expected Log Markers ==="
  local marker logs
  logs="$(kubectl logs -n "${NAMESPACE}" -l "workflows.argoproj.io/workflow=${WORKFLOW_NAME}" -c main --prefix=true 2>/dev/null || true)"
  for marker in \
    "raw data written" \
    "chunks written" \
    "shards written" \
    "stage paths initialized" \
    "metadata-index written" \
    "manifest written" \
    "placement-plan written" \
    "cleanup-plan written" \
    "chunk_count=2 shard_count=2" \
    "shard files verified" \
    "complete: model artifact created" \
    "placement_mode=worker-local-prestage target_storage=MataFS" \
    "complete: report_path=/work/preprocess/reports/evaluation-report.json" \
    "storage tier marker files written"; do
    if grep -F "${marker}" <<<"${logs}" >/dev/null; then
      pass "artifact 연결" "${marker}"
    else
      fail "artifact 연결" "missing marker: ${marker}"
    fi
  done
}

check_storage_classes() {
  echo
  echo "=== StorageClasses ==="
  if kubectl get storageclass; then
    pass "PVC/storage" "storageclass list readable"
  else
    fail "PVC/storage" "cannot list storageclasses"
  fi

  for sc in storage-capacity storage-performance; do
    if kubectl get storageclass "${sc}" >/dev/null 2>&1; then
      pass "PVC/storage" "StorageClass exists: ${sc}"
    else
      fail "PVC/storage" "StorageClass missing: ${sc}"
    fi
  done
}

check_pvcs() {
  echo
  echo "=== PVCs ==="
  local pvcs pvc expected_role expected_sc actual_sc phase volume access_modes capacity selected dataset latency prefetch locality cache pv_phase
  pvcs="$(pvc_names_for_workflow)"
  if [[ -z "${pvcs}" ]]; then
    warn "PVC/storage" "no PVCs found by workflow label; falling back to name search"
    pvcs="$(kubectl get pvc -n "${NAMESPACE}" -o name 2>/dev/null | grep -E "${WORKFLOW_NAME}|preprocess-capacity-data|training-performance-data|metadata-randomio-data" | sed 's|.*/||' || true)"
  fi

  if [[ -z "${pvcs}" ]]; then
    fail "PVC/storage" "no preprocessing workflow PVCs found"
    return
  fi

  kubectl get pvc -n "${NAMESPACE}" ${pvcs}

  for pvc in ${pvcs}; do
    expected_role="$(jsonpath get pvc "${pvc}" -n "${NAMESPACE}" -o jsonpath='{.metadata.labels["integration.keti.io/storage-role"]}')"
    case "${expected_role}" in
      capacity) expected_sc="storage-capacity" ;;
      performance|metadata-randomio) expected_sc="storage-performance" ;;
      *) expected_sc="" ;;
    esac

    actual_sc="$(jsonpath get pvc "${pvc}" -n "${NAMESPACE}" -o jsonpath='{.spec.storageClassName}')"
    phase="$(jsonpath get pvc "${pvc}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}')"
    volume="$(jsonpath get pvc "${pvc}" -n "${NAMESPACE}" -o jsonpath='{.spec.volumeName}')"
    access_modes="$(jsonpath get pvc "${pvc}" -n "${NAMESPACE}" -o jsonpath='{.spec.accessModes[*]}')"
    capacity="$(jsonpath get pvc "${pvc}" -n "${NAMESPACE}" -o jsonpath='{.status.capacity.storage}')"
    selected="$(jsonpath get pvc "${pvc}" -n "${NAMESPACE}" -o jsonpath='{.metadata.annotations["ai-storage/selected-tier"]}')"
    dataset="$(jsonpath get pvc "${pvc}" -n "${NAMESPACE}" -o jsonpath='{.metadata.annotations["storage.keti.io/dataset-size"]}')"
    latency="$(jsonpath get pvc "${pvc}" -n "${NAMESPACE}" -o jsonpath='{.metadata.annotations["storage.keti.io/latency"]}')"
    prefetch="$(jsonpath get pvc "${pvc}" -n "${NAMESPACE}" -o jsonpath='{.metadata.annotations["storage.keti.io/prefetch"]}')"
    locality="$(jsonpath get pvc "${pvc}" -n "${NAMESPACE}" -o jsonpath='{.metadata.annotations["storage.keti.io/locality"]}')"
    cache="$(jsonpath get pvc "${pvc}" -n "${NAMESPACE}" -o jsonpath='{.metadata.annotations["storage.keti.io/cache-aware"]}')"

    echo "--- pvc/${pvc} ---"
    echo "role=${expected_role:-NA} storageClass=${actual_sc:-NA} expected=${expected_sc:-NA} phase=${phase:-NA} volume=${volume:-NA}"
    echo "accessModes=${access_modes:-NA} capacity=${capacity:-NA}"
    echo "selected-tier=${selected:-NA} dataset-size=${dataset:-NA} latency=${latency:-NA} prefetch=${prefetch:-NA} locality=${locality:-NA} cache-aware=${cache:-NA}"

    if [[ "${phase}" == "Bound" ]]; then
      pass "PVC/storage" "${pvc}: phase Bound"
    else
      fail "PVC/storage" "${pvc}: phase=${phase:-NA}; expected Bound"
    fi

    if [[ -n "${expected_sc}" && "${actual_sc}" == "${expected_sc}" ]]; then
      pass "PVC/storage" "${pvc}: ${expected_role} workload connected to ${actual_sc}"
    else
      fail "PVC/storage" "${pvc}: storageClass=${actual_sc:-NA}; expected ${expected_sc:-role metadata missing}"
    fi

    if [[ -n "${selected}" ]]; then
      pass "PVC/storage" "${pvc}: ai-storage/selected-tier=${selected}"
    else
      fail "PVC/storage" "${pvc}: ai-storage/selected-tier annotation missing"
    fi

    for field in dataset latency prefetch locality cache; do
      local value="${!field}"
      if [[ -n "${value}" ]]; then
        pass "PVC/storage" "${pvc}: ${field} hint present (${value})"
      else
        fail "PVC/storage" "${pvc}: ${field} hint missing"
      fi
    done

    if [[ -n "${volume}" ]]; then
      pv_phase="$(jsonpath get pv "${volume}" -o jsonpath='{.status.phase}')"
      echo "pv/${volume} phase=${pv_phase:-NA}"
      if [[ "${pv_phase}" == "Bound" ]]; then
        pass "PVC/storage" "${pvc}: bound PV ${volume}"
      else
        fail "PVC/storage" "${pvc}: PV ${volume} phase=${pv_phase:-NA}"
      fi
    else
      fail "PVC/storage" "${pvc}: bound PV name missing"
    fi
  done
}

check_volume_mounts() {
  echo
  echo "=== Pod Volume Mounts ==="
  local pods pod mounts volumes
  pods="$(pods_for_workflow)"
  for pod in ${pods}; do
    echo "--- pod/${pod} volume summary ---"
    volumes="$(jsonpath get pod "${pod}" -n "${NAMESPACE}" -o jsonpath='{range .spec.volumes[*]}{.name}:{.persistentVolumeClaim.claimName}{"\n"}{end}')"
    mounts="$(jsonpath get pod "${pod}" -n "${NAMESPACE}" -o jsonpath='{range .spec.containers[?(@.name=="main")].volumeMounts[*]}{.name}:{.mountPath}{"\n"}{end}')"
    echo "${volumes}"
    echo "${mounts}"

    if grep -E 'preprocess-capacity-data|training-performance-data|metadata-randomio-data' <<<"${volumes}" >/dev/null; then
      pass "PVC/storage" "${pod}: preprocessing PVC volume present"
    else
      fail "PVC/storage" "${pod}: preprocessing PVC volume missing"
    fi

    if grep -E '/mnt/capacity|/mnt/performance|/mnt/metadata' <<<"${mounts}" >/dev/null; then
      pass "PVC/storage" "${pod}: tier volumeMount present"
    else
      fail "PVC/storage" "${pod}: tier volumeMount missing"
    fi
  done
}

summary() {
  echo
  echo "=== Verification Summary ==="
  echo "PASS=${PASS_COUNT} WARN=${WARN_COUNT} FAIL=${FAIL_COUNT}"
  if [[ "${FAIL_COUNT}" -eq 0 ]]; then
    echo "RESULT=PASS"
    exit 0
  fi
  echo "RESULT=FAIL"
  exit 1
}

need_kubectl

case "${MODE}" in
  all|workflow|storage) ;;
  *)
    echo "ERROR: invalid --mode: ${MODE}" >&2
    usage
    exit 1
    ;;
esac

WORKFLOW_NAME="$(workflow_name)"
if [[ -z "${WORKFLOW_NAME}" ]]; then
  echo "ERROR: workflow not found. Set WORKFLOW_NAME or check label ${WORKFLOW_LABEL} in namespace ${NAMESPACE}." >&2
  exit 1
fi

echo "[verify] namespace: ${NAMESPACE}"
echo "[verify] workflow: ${WORKFLOW_NAME}"
echo "[verify] mode: ${MODE}"

check_preconditions

if [[ "${MODE}" == "all" || "${MODE}" == "workflow" ]]; then
  check_workflow
  check_pod_containers
  check_logs_and_artifacts
fi

if [[ "${MODE}" == "all" || "${MODE}" == "storage" ]]; then
  check_storage_classes
  check_pvcs
  check_volume_mounts
fi

summary
