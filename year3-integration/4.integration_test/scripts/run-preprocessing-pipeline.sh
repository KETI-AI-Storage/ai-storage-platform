#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORKFLOW_FILE="${WORKFLOW_FILE:-${ROOT_DIR}/year3-integration/4.integration_test/manifests/preprocessing-pipeline-workflow.yaml}"
NAMESPACE="${NAMESPACE:-default}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "ERROR: kubectl not found" >&2
  exit 1
fi

if [[ ! -f "${WORKFLOW_FILE}" ]]; then
  echo "ERROR: workflow file not found: ${WORKFLOW_FILE}" >&2
  exit 1
fi

if ! kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  echo "ERROR: namespace not found: ${NAMESPACE}" >&2
  exit 1
fi

if ! kubectl get crd workflows.argoproj.io >/dev/null 2>&1; then
  echo "ERROR: Argo Workflow CRD workflows.argoproj.io not found" >&2
  exit 1
fi

echo "[preprocessing-pipeline] namespace: ${NAMESPACE}"
echo "[preprocessing-pipeline] workflow file: ${WORKFLOW_FILE}"
echo "[preprocessing-pipeline] submit command:"
echo "kubectl create -n ${NAMESPACE} -f ${WORKFLOW_FILE} -o name"

kubectl create -n "${NAMESPACE}" -f "${WORKFLOW_FILE}" -o name
