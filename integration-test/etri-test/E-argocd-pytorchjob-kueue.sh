#!/bin/bash
# =============================================================================
# [조합 E] Argo CD + Kubeflow + Kueue
#
# 구성요소: Argo CD (O) | Kubeflow (O) | Argo Workflow (-) | Kueue (O)
# 설명:     분산 학습 + 큐 관리 (PyTorchJob + Kueue)
#
# 검증 항목:
#   1. PyTorchJob에 Kueue queue label 존재
#   2. Master Pod에 schedulerName 주입
#   3. Master Pod에 sidecar 주입
#   4. Master Pod에 shareProcessNamespace 주입
# =============================================================================
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

TEST_ID="E"
echo "=========================================="
echo " [${TEST_ID}] Argo CD + Kubeflow + Kueue"
echo " Namespace: ${NS}"
echo "=========================================="
echo ""

# ----- Step 1: PyTorchJob + Kueue 생성 -----
echo "--- Step 1: PyTorchJob + Kueue 생성 ---"
cat <<'EOF' | kubectl apply -f -
apiVersion: kubeflow.org/v1
kind: PyTorchJob
metadata:
  name: combo-e-pytorchjob-kueue
  namespace: kubeflow-user-example-com
  labels:
    combo-test: "true"
    combo-id: "E"
    kueue.x-k8s.io/queue-name: ai-storage-queue
spec:
  pytorchReplicaSpecs:
    Master:
      replicas: 1
      restartPolicy: OnFailure
      template:
        metadata:
          labels:
            combo-test: "true"
            combo-id: "E"
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
              print("[E] PyTorchJob + Kueue - Master")
              print("=" * 50)
              print("Kueue가 PyTorchJob 큐잉 관리")
              for epoch in range(2):
                  print(f"  Epoch {epoch+1}/2 training...")
                  time.sleep(5)
              print("[E] Training Done!")
            resources:
              requests:
                cpu: "50m"
                memory: "64Mi"
EOF

# ----- Step 2: Kueue label 검증 -----
echo ""
echo "--- Step 2: Kueue 연동 검증 ---"
check_kueue_label "${TEST_ID}-kueue" "pytorchjob" "combo-e-pytorchjob-kueue"

# ----- Step 3: Pod 대기 및 웹훅 검증 -----
echo ""
echo "--- Step 3: 웹훅 주입 검증 (Master Pod) ---"
wait_for_pod "combo-id=E" 90
POD=$(kubectl get pods -n ${NS} -l "combo-id=E" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -n "${POD}" ]; then
    show_pod_status "${POD}"
    check_scheduler    "${TEST_ID}-scheduler"     "${POD}"
    check_sidecar      "${TEST_ID}-sidecar"        "${POD}"
    check_shareprocess "${TEST_ID}-shareprocess"   "${POD}"
fi

echo ""
echo -e "${CYAN}[INFO] Argo CD GitOps 배포 시:${NC}"
echo "  ArgoCD Application → Git repo → PyTorchJob YAML 배포"
echo "  Kueue가 PyTorchJob 큐잉 → Training Operator가 Pod 생성 → 웹훅 자동 주입"

print_summary "${TEST_ID}"
