#!/usr/bin/env bash
# install-scenario1.sh applies the minimum modules for scenario 1.
#
# Author: 미정
# Created: 2026-04-20
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WEBHOOK_SC_DIR="${WORKSPACE_DIR}/ai-storage-webhook"

INSIGHT_HUB_IMAGE="${INSIGHT_HUB_IMAGE:-}"
INSIGHT_HUB_PULL_POLICY="${INSIGHT_HUB_PULL_POLICY:-}"
INJECTION_NAMESPACE="${INJECTION_NAMESPACE:-kubeflow-user-example-com}"
SCOPE_POD_SELECTOR="${SCOPE_POD_SELECTOR:-}"

if ! command -v kubectl &>/dev/null; then
  echo "ERROR: kubectl not found" >&2
  exit 1
fi

if ! kubectl get namespace "${INJECTION_NAMESPACE}" &>/dev/null; then
  echo "ERROR: namespace ${INJECTION_NAMESPACE} not found. Prepare the injection target namespace first." >&2
  exit 1
fi

echo "StorageClass setup"
for f in storageclass-performance.yaml storageclass-capacity.yaml storageclass-burst.yaml storageclass-archive.yaml; do
  path="${WEBHOOK_SC_DIR}/${f}"
  name="$(awk '/^metadata:/{p=1} p&&/^  name:/{print $2; exit}' "${path}")"
  if kubectl get storageclass "${name}" &>/dev/null; then
    echo "StorageClass ${name} already exists - skip apply"
  else
    echo "Apply StorageClass ${name}"
    kubectl apply -f "${path}"
  fi
done

echo "Run webhook installer"
WORKLOAD_NS="${INJECTION_NAMESPACE}" bash "${SCRIPT_DIR}/install-webhook.sh"

echo "Ensure injection label on namespace"
kubectl label namespace "${INJECTION_NAMESPACE}" keti-ai-storage-injection=enabled --overwrite

echo "Deploy insight-trace"
kubectl apply -f "${WORKSPACE_DIR}/insight-trace/deployments/insight-trace.yaml"

echo "Deploy insight-scope"
kubectl apply -f "${WORKSPACE_DIR}/insight-scope/deployments/insight-scope.yaml"
if [[ -n "${SCOPE_POD_SELECTOR}" ]]; then
  # Override selector only when explicitly provided.
  kubectl -n keti set env daemonset/insight-scope POD_METRICS_LABEL_SELECTOR="${SCOPE_POD_SELECTOR}"
fi

echo "Deploy insight-hub"
kubectl apply -f "${WORKSPACE_DIR}/insight-hub/deployments/insight-hub.yaml"
if [[ -n "${INSIGHT_HUB_IMAGE}" ]]; then
  echo "Patch insight-hub image to ${INSIGHT_HUB_IMAGE}"
  kubectl -n keti set image deployment/insight-hub insight-hub="${INSIGHT_HUB_IMAGE}"
fi
if [[ -n "${INSIGHT_HUB_PULL_POLICY}" ]]; then
  kubectl patch deployment insight-hub -n keti --type=json \
    -p="[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/imagePullPolicy\",\"value\":\"${INSIGHT_HUB_PULL_POLICY}\"}]"
fi

echo "Deploy ai-storage-scheduler"
kubectl apply -f "${WORKSPACE_DIR}/ai-storage-scheduler/deployments/ai-storage-scheduler.yaml"

echo "Wait for rollout"
kubectl rollout status deployment/insight-hub -n keti --timeout=300s || true
kubectl rollout status daemonset/insight-scope -n keti --timeout=300s || true
kubectl rollout status deployment/insight-trace -n keti --timeout=300s || true
kubectl rollout status deployment/ai-storage-scheduler -n keti --timeout=300s || true
kubectl rollout status deployment/ai-storage-webhook -n keti --timeout=300s || true

echo "Done"
