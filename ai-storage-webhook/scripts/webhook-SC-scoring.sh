#!/usr/bin/env bash
# Prints a human-readable "score log" matching ai-storage-webhook selectStorageClass() logic.
# Usage: ./webhook-SC-scoring.sh [-n NAMESPACE] WORKLOAD_OR_POD_NAME
# Example: ./webhook-SC-scoring.sh training-job-workload
# Example: ./webhook-SC-scoring.sh -n k8s-admission-webhook training-job-workload-jm75d

set -euo pipefail

NAMESPACE="${NAMESPACE:-k8s-admission-webhook}"

usage() {
  echo "Usage: $0 [-n NAMESPACE] <job-name | pod-name>" >&2
  echo "  Resolves the workload pod, finds its PVC, reads PVC labels/annotations (same as webhook)," >&2
  echo "  then prints workload hints and per-StorageClass scores." >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace)
      NAMESPACE="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      break
      ;;
  esac
done

[[ $# -eq 1 ]] || usage
ARG="$1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

resolve_pod() {
  local name="$1"
  # Exact pod
  if kubectl get pod "$name" -n "$NAMESPACE" &>/dev/null; then
    echo "$name"
    return 0
  fi
  # Job name -> pod (common labels)
  local p
  p="$(kubectl get pods -n "$NAMESPACE" -l "job-name=${name}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "$p" ]]; then echo "$p"; return 0; fi
  p="$(kubectl get pods -n "$NAMESPACE" -l "batch.kubernetes.io/job-name=${name}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "$p" ]]; then echo "$p"; return 0; fi
  p="$(kubectl get pods -n "$NAMESPACE" -l "app=${name}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "$p" ]]; then echo "$p"; return 0; fi
  echo "ERROR: could not find pod for '${name}' in namespace '${NAMESPACE}'" >&2
  exit 1
}

pvc_from_pod() {
  local pod="$1"
  kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{range .spec.volumes[*]}{.persistentVolumeClaim.claimName}{"\n"}{end}' 2>/dev/null | head -1
}

POD_NAME="$(resolve_pod "$ARG")"
PVC_NAME="$(pvc_from_pod "$POD_NAME")"
if [[ -z "${PVC_NAME}" ]]; then
  echo "ERROR: pod '${POD_NAME}' has no PersistentVolumeClaim volume" >&2
  exit 1
fi

PVC_JSON="$(kubectl get pvc "$PVC_NAME" -n "$NAMESPACE" -o json)"

JOB_NAME="$(kubectl get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.metadata.labels.job-name}' 2>/dev/null || true)"
APP_NAME="$(kubectl get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.metadata.labels.app}' 2>/dev/null || true)"
# Display title: prefer Job name (e.g. training-job-workload), else app label, else CLI arg
WORKLOAD_DISPLAY="${JOB_NAME:-${APP_NAME:-$ARG}}"

export POD_NAME PVC_NAME NAMESPACE WORKLOAD_DISPLAY
export PVC_JSON

python3 "${SCRIPT_DIR}/_storage_class_score.py" <<<"$PVC_JSON"
