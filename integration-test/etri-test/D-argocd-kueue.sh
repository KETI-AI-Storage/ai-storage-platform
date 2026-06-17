#!/bin/bash
# =============================================================================
# [조합 D] Argo CD + Kueue
#
# 구성요소: Argo CD (O) | Kubeflow (-) | Argo Workflow (-) | Kueue (O)
# 설명:     큐 관리 Job을 Argo CD로 GitOps 배포
#
# 검증 항목:
#   1. Job에 Kueue queue label 존재
#   2. Pod에 schedulerName 주입
#   3. Pod에 sidecar 주입
#   4. Pod에 shareProcessNamespace 주입
# =============================================================================
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

TEST_ID="D"
echo "=========================================="
echo " [${TEST_ID}] Argo CD + Kueue"
echo " Namespace: ${NS}"
echo "=========================================="
echo ""

# ----- Step 1: Kueue-managed Job 생성 -----
echo "--- Step 1: Kueue-managed Job 생성 ---"
cat <<'EOF' | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: combo-d-kueue-job
  namespace: kubeflow-user-example-com
  labels:
    combo-test: "true"
    combo-id: "D"
    kueue.x-k8s.io/queue-name: ai-storage-queue
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 300
  template:
    metadata:
      labels:
        combo-test: "true"
        combo-id: "D"
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
          print("[D] Kueue-managed Job")
          print("=" * 50)
          print("Kueue가 이 Job의 큐잉/스케줄링을 관리합니다")
          for i in range(3):
              print(f"  Processing {i+1}/3...")
              time.sleep(3)
          print("[D] Done!")
        resources:
          requests:
            cpu: "50m"
            memory: "64Mi"
      restartPolicy: Never
EOF

# ----- Step 2: Kueue label 검증 -----
echo ""
echo "--- Step 2: Kueue 연동 검증 ---"
check_kueue_label "${TEST_ID}-kueue" "job" "combo-d-kueue-job"

# ----- Step 3: Pod 대기 및 웹훅 검증 -----
echo ""
echo "--- Step 3: 웹훅 주입 검증 ---"
wait_for_pod "combo-id=D" 90
POD=$(kubectl get pods -n ${NS} -l "combo-id=D" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -n "${POD}" ]; then
    show_pod_status "${POD}"
    check_scheduler    "${TEST_ID}-scheduler"     "${POD}"
    check_sidecar      "${TEST_ID}-sidecar"        "${POD}"
    check_shareprocess "${TEST_ID}-shareprocess"   "${POD}"
fi

echo ""
echo -e "${CYAN}[INFO] Argo CD GitOps 배포 시:${NC}"
echo "  ArgoCD Application → Git repo (workloads/kueue-job.yaml) → 자동 Sync"
echo "  Kueue가 Job을 큐에 넣고, Pod 생성 시 웹훅 자동 주입"

print_summary "${TEST_ID}"
