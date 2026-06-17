#!/usr/bin/env bash
# install-scenario2.sh는 시나리오2(정책 생성·실행)용 node-resource-forecaster·ai-storage-orchestrator·orchestration-policy-engine·CRD를 적용한다.
#
# Author: 미정
# Created: 2026-04-17
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
APOLLO_DEP="${WORKSPACE_DIR}/apollo/deployments"
OPE_CRD="${WORKSPACE_DIR}/apollo/orchestration-policy-engine/config/crd/bases/apollo.keti.re.kr_orchestrationpolicies.yaml"

if ! command -v kubectl &>/dev/null; then
  echo "ERROR: kubectl not found" >&2
  exit 1
fi

if ! kubectl get storageclass nfs-client &>/dev/null; then
  echo "ERROR: StorageClass nfs-client not found. orchestration-policy-engine PVC가 apollo/deployments/orchestration-policy-engine.yaml L143에서 요구함." >&2
  exit 1
fi

echo "[scenario2] namespace apollo (apollo/deployments/namespace.yaml)"
kubectl apply -f "${APOLLO_DEP}/namespace.yaml"

echo "[scenario2] RBAC (apollo/deployments/rbac.yaml)"
kubectl apply -f "${APOLLO_DEP}/rbac.yaml"

echo "[scenario2] OrchestrationPolicy CRD (${OPE_CRD})"
kubectl apply -f "${OPE_CRD}"

echo "[scenario2] ai-storage-orchestrator (ai-storage-orchestrator/deployments/cluster-orchestrator.yaml)"
kubectl apply -f "${WORKSPACE_DIR}/ai-storage-orchestrator/deployments/cluster-orchestrator.yaml"

echo "[scenario2] orchestration-policy-engine + ConfigMap + PVC (apollo/deployments/orchestration-policy-engine.yaml — args에 --auto-execute=true L77-L78)"
kubectl apply -f "${APOLLO_DEP}/orchestration-policy-engine.yaml"

echo "[scenario2] node-resource-forecaster (apollo/deployments/node-resource-forecaster.yaml)"
kubectl apply -f "${APOLLO_DEP}/node-resource-forecaster.yaml"

kubectl rollout status deployment/node-resource-forecaster -n apollo --timeout=300s
kubectl rollout status deployment/ai-storage-orchestrator -n kube-system --timeout=300s
kubectl rollout status deployment/orchestration-policy-engine -n apollo --timeout=600s

echo "[scenario2] autoExecute=true: 컨트롤러 플래그는 apollo/deployments/orchestration-policy-engine.yaml L77-L78; 개별 OrchestrationPolicy spec.autoExecute 는 year3-integration/2.test_shell/07.test-policy-orchestration.sh 내 인라인 매니페스트(예 L247)에서 설정."

echo "[scenario2] 07.test-policy-orchestration.sh 는 Deployment 이름 orchestration-policy-engine 으로 수정됨(year3-integration/2.test_shell/07.test-policy-orchestration.sh L31-L35)."

echo "[scenario2] done."
echo "NOTE: apollo/deployments/orchestration-policy-engine.yaml spec.template.spec.nodeSelector.layer=orchestration (L106-L107). 해당 레이블이 없는 노드에는 스케줄되지 않음."
