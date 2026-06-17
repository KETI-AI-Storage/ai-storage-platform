#!/usr/bin/env bash

set -e

NAMESPACE="kcp-monitoring"

echo "[1/4] Add Helm repository and update"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo update

echo "[2/4] Create namespace (${NAMESPACE})"
kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${NAMESPACE}"

echo "[3/4] Deloy Prometheus"
helm install prometheus prometheus-community/prometheus --namespace ${NAMESPACE}

echo "[4/4] Patch Prometheus Service to NodePort on 30090"
kubectl patch svc prometheus-server -n "${NAMESPACE}" --type='json' \
  -p '[
    {"op": "replace", "path": "/spec/type", "value": "NodePort"},
    {"op": "replace", "path": "/spec/ports/0/port", "value": 9090},
    {"op": "replace", "path": "/spec/ports/0/nodePort", "value": 30090}
  ]'
  
echo "[INFO] Prometheus Installation done!"
echo "         > helm list -n ${NAMESPACE}"
echo "         > kubectl get all -n ${NAMESPACE}"
