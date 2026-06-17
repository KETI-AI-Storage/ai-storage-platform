#!/usr/bin/env bash
set -euo pipefail

POD_NAME="${POD_NAME:-etri-train}"
NAMESPACE="${NAMESPACE:-default}"

echo "=== Pod volumes ==="
kubectl get pod "${POD_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.volumes}' | jq .
echo

echo "=== Pod volumeMounts ==="
kubectl get pod "${POD_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.containers[*].volumeMounts}' | jq .
echo

echo "=== Pod schedulerName / annotations ==="
kubectl get pod "${POD_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.schedulerName}{"\n"}'
kubectl get pod "${POD_NAME}" -n "${NAMESPACE}" -o jsonpath='{.metadata.annotations}{"\n"}' | jq .

