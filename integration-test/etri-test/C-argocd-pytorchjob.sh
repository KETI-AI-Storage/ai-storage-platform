#!/bin/bash
# =============================================================================
# [조합 C] Argo CD + Kubeflow (PyTorchJob)
#
# 구성요소: Argo CD (O) | Kubeflow (O) | Argo Workflow (-) | Kueue (-)
# 설명:     분산 학습 Job을 Argo CD로 GitOps 배포
#
# 검증 항목:
#   1. PyTorchJob 정상 생성
#   2. Master Pod에 schedulerName 주입
#   3. Master Pod에 sidecar 주입
#   4. Master Pod에 shareProcessNamespace 주입
# =============================================================================
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

TEST_ID="C"
echo "=========================================="
echo " [${TEST_ID}] Argo CD + Kubeflow (PyTorchJob)"
echo " Namespace: ${NS}"
echo "=========================================="
echo ""

# ----- Step 1: PyTorchJob 생성 -----
echo "--- Step 1: PyTorchJob 생성 ---"
cat <<'EOF' | kubectl apply -f -
apiVersion: kubeflow.org/v1
kind: PyTorchJob
metadata:
  name: combo-c-pytorchjob
  namespace: kubeflow-user-example-com
  labels:
    combo-test: "true"
    combo-id: "C"
spec:
  pytorchReplicaSpecs:
    Master:
      replicas: 1
      restartPolicy: OnFailure
      template:
        metadata:
          labels:
            combo-test: "true"
            combo-id: "C"
        spec:
          tolerations:
          - operator: Exists
          containers:
          - name: pytorch
            image: python:3.11-slim
            command: [python3, -c]
            args:
            - |
              import time
              print("=" * 50)
              print("[C] PyTorchJob - Master")
              print("=" * 50)
              for epoch in range(2):
                  print(f"  Epoch {epoch+1}/2 training...")
                  time.sleep(5)
              print("[C] Training Done!")
            resources:
              requests:
                cpu: "50m"
                memory: "64Mi"
EOF

# ----- Step 2: Pod 대기 및 검증 -----
echo ""
echo "--- Step 2: 웹훅 주입 검증 (Master Pod) ---"
wait_for_pod "combo-id=C" 90
POD=$(kubectl get pods -n ${NS} -l "combo-id=C" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -n "${POD}" ]; then
    show_pod_status "${POD}"
    check_scheduler    "${TEST_ID}-scheduler"     "${POD}"
    check_sidecar      "${TEST_ID}-sidecar"        "${POD}"
    check_shareprocess "${TEST_ID}-shareprocess"   "${POD}"
fi

echo ""
echo -e "${CYAN}[INFO] Argo CD GitOps 배포 시:${NC}"
echo "  ArgoCD Application → Git repo (workloads/pytorchjob.yaml) → 자동 Sync"
echo "  Kubeflow Training Operator가 Master/Worker Pod 생성 → 웹훅 자동 주입"

print_summary "${TEST_ID}"
