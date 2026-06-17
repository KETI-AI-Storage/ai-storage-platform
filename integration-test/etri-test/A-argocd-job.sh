#!/bin/bash
# =============================================================================
# [조합 A] Argo CD + 단일 Job
#
# 구성요소: Argo CD (O) | Kubeflow (-) | Argo Workflow (-) | Kueue (-)
# 설명:     단일 Job/Deployment를 Argo CD로 GitOps 배포
#
# 검증 항목:
#   1. schedulerName = ai-storage-scheduler  (웹훅 자동 주입)
#   2. shareProcessNamespace = true          (웹훅 자동 주입)
#   3. insight-trace sidecar 존재            (웹훅 자동 주입)
# =============================================================================
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

TEST_ID="A"
echo "=========================================="
echo " [${TEST_ID}] Argo CD + 단일 Job"
echo " Namespace: ${NS}"
echo "=========================================="
echo ""

# ----- Step 1: Job 생성 -----
echo "--- Step 1: Job 생성 ---"
cat <<'EOF' | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: combo-a-training-job
  namespace: kubeflow-user-example-com
  labels:
    combo-test: "true"
    combo-id: "A"
    app: combo-a
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 300
  template:
    metadata:
      labels:
        combo-test: "true"
        combo-id: "A"
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
          print("[A] Single Job - AI Training")
          print("=" * 50)
          for i in range(3):
              print(f"  Training step {i+1}/3...")
              time.sleep(5)
          print("[A] Done!")
        resources:
          requests:
            cpu: "50m"
            memory: "64Mi"
      restartPolicy: Never
EOF

# ----- Step 2: Pod 대기 및 검증 -----
echo ""
echo "--- Step 2: 웹훅 주입 검증 ---"
wait_for_pod "combo-id=A" 60
POD=$(kubectl get pods -n ${NS} -l "combo-id=A" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -n "${POD}" ]; then
    show_pod_status "${POD}"
    check_scheduler  "${TEST_ID}-scheduler"     "${POD}"
    check_sidecar    "${TEST_ID}-sidecar"        "${POD}"
    check_shareprocess "${TEST_ID}-shareprocess" "${POD}"
fi

# ----- Step 3: Argo CD Application 참고 -----
echo ""
echo -e "${CYAN}[INFO] Argo CD GitOps 배포 시:${NC}"
echo "  ArgoCD Application → Git repo (workloads/job.yaml) → 자동 Sync"
echo "  웹훅이 Pod 생성 시 자동으로 scheduler/sidecar/shareProcess 주입"

print_summary "${TEST_ID}"
