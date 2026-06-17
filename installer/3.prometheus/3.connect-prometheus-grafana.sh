#!/usr/bin/env bash
set -e

NAMESPACE="monitoring"
RELEASE="grafana"
VALUES_FILE=$(mktemp ./tmp/grafana-values.yaml)

echo "[1/3] Make grafana-values.yaml for connect with prometheus"
cat > "${VALUES_FILE}" <<EOF
datasources:
  datasources.yaml: 
    apiVersion: 1
    datasources:
      - name: Prometheus
        type: prometheus
        access: proxy
        url: http://prometheus-server.${NAMESPACE}.svc.cluster.local:9090
        isDefault: true
        editable: true
EOF

echo "[2/3] Add Grafana repo & update"
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo update

echo "[3/3] Install or upgrade Grafana with Prometheus datasource"
helm upgrade --install "${RELEASE}" grafana/grafana \
  --namespace "${NAMESPACE}" \
  -f "${VALUES_FILE}"

echo "[INFO] Grafana is now deployed with Prometheus data source!"
echo "       > helm list -n ${NAMESPACE}"
echo "       > kubectl get all -n ${NAMESPACE}"

# 임시 파일 삭제
rm -f "${VALUES_FILE}"
