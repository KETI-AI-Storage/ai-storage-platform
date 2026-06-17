#!/usr/bin/env bash

set -e

NAMESPACE="kcp-monitoring"

echo "[1/3] Add Helm repository for Grafana and update"
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo update

echo "[2/3] Create namespace (${NAMESPACE}) if it doesn't exist"
kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${NAMESPACE}"

echo "[3/3] Deploy Grafana"
helm install grafana grafana/grafana --namespace "${NAMESPACE}"

echo "[4/4] Patch Grafana Service to NodePort on 30030"
kubectl patch svc grafana -n "${NAMESPACE}" --type='json' \
  -p '[
    {"op": "replace", "path": "/spec/type", "value": "NodePort"},
    {"op": "replace", "path": "/spec/ports/0/nodePort", "value": 30030}
  ]'

echo "[INFO] Grafana installation done!"

HOST_IP=$(
  kubectl get nodes \
    -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}'
)

echo "[INFO] Access Grafana at http://${HOST_IP}:30030"

GRAFANA_ADMIN_PWD=$(
  kubectl get secret --namespace ${NAMESPACE} grafana \
    -o jsonpath="{.data.admin-password}" \
  | base64 --decode
)

echo "[INFO] Login with ID: admin and Password: ${GRAFANA_ADMIN_PWD}"
echo "[INFO] After logging in to Grafana, please change the default password immediately via the UI."

