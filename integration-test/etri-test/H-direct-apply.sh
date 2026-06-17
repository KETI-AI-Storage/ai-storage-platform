#!/bin/bash
# =============================================================================
# [조합 H] Argo CD 없이 직접 제출
#
# 구성요소: Argo CD (-) | Kubeflow (-) | Argo Workflow (-) | Kueue (-)
# 설명:     kubectl apply로 직접 Pod 제출 (GitOps 없음)
#           웹훅은 동일하게 동작함을 검증
#
# 검증 항목:
#   1. 직접 제출한 Pod에도 schedulerName 주입
#   2. 직접 제출한 Pod에도 sidecar 주입
#   3. 직접 제출한 Pod에도 shareProcessNamespace 주입
# =============================================================================
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

TEST_ID="H"
echo "=========================================="
echo " [${TEST_ID}] 직접 제출 (No Argo CD)"
echo " Namespace: ${NS}"
echo "=========================================="
echo ""

# ----- Step 1: 순수 Pod 직접 생성 -----
echo "--- Step 1: kubectl apply 직접 제출 ---"
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: combo-h-direct-pod
  namespace: kubeflow-user-example-com
  labels:
    combo-test: "true"
    combo-id: "H"
spec:
  tolerations:
  - operator: Exists
  containers:
  - name: training
    image: python:3.11-slim
    command: [python3, -c]
    args:
    - |
      import time
      print("=" * 50)
      print("[H] Direct Apply - No Argo CD")
      print("=" * 50)
      print("Argo CD 없이 직접 제출해도 웹훅이 동작합니다")
      for i in range(3):
          print(f"  Step {i+1}/3...")
          time.sleep(3)
      print("[H] Done!")
    resources:
      requests:
        cpu: "50m"
        memory: "64Mi"
  restartPolicy: Never
EOF

# ----- Step 2: Pod 대기 및 검증 -----
echo ""
echo "--- Step 2: 웹훅 주입 검증 ---"
wait_for_pod_name "combo-h-direct-pod" 60

show_pod_status "combo-h-direct-pod"
check_scheduler    "${TEST_ID}-scheduler"     "combo-h-direct-pod"
check_sidecar      "${TEST_ID}-sidecar"        "combo-h-direct-pod"
check_shareprocess "${TEST_ID}-shareprocess"   "combo-h-direct-pod"

echo ""
echo -e "${CYAN}[INFO] Argo CD 없이 직접 제출:${NC}"
echo "  kubectl apply -f pod.yaml → API Server → 웹훅 주입 → Pod 생성"
echo "  MutatingWebhook은 Argo CD 유무와 관계없이 모든 Pod CREATE에 동작"

print_summary "${TEST_ID}"
