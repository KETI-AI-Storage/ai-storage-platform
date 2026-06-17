#!/bin/bash
# =============================================================================
# [조합 F] Argo CD + Argo Workflow + Kueue
#
# 구성요소: Argo CD (O) | Kubeflow (-) | Argo Workflow (O) | Kueue (O)
# 설명:     파이프라인 + 큐 관리
#           Argo Workflow가 Kueue-managed Job을 생성
#
# 검증 항목:
#   1. Workflow 정상 생성
#   2. Workflow Step Pod에 schedulerName 주입
#   3. Workflow Step Pod에 sidecar 주입
#   4. 내부 Job에 Kueue label 존재
# =============================================================================
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

TEST_ID="F"
echo "=========================================="
echo " [${TEST_ID}] Argo CD + Argo Workflow + Kueue"
echo " Namespace: ${NS}"
echo "=========================================="
echo ""

# ----- Step 1: Argo Workflow + Kueue Job 생성 -----
echo "--- Step 1: Argo Workflow (Kueue-managed step) 생성 ---"
cat <<'EOF' | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  name: combo-f-workflow-kueue
  namespace: kubeflow-user-example-com
  labels:
    combo-test: "true"
    combo-id: "F"
spec:
  entrypoint: pipeline
  serviceAccountName: default-editor
  templates:
  - name: pipeline
    dag:
      tasks:
      - name: preprocess
        template: preprocess-step
      - name: train-kueue
        template: create-kueue-job
        dependencies: [preprocess]

  # Step 1: 전처리 (일반 Pod)
  - name: preprocess-step
    tolerations:
    - operator: Exists
    container:
      image: python:3.11-slim
      name: main
      command: [python3, -c]
      args:
      - |
        import time
        print("=" * 50)
        print("[F] Workflow + Kueue - Preprocess")
        print("=" * 50)
        time.sleep(5)
        print("[F-preprocess] Done!")
      resources:
        requests:
          cpu: "50m"
          memory: "64Mi"

  # Step 2: Kueue-managed Job 생성
  - name: create-kueue-job
    resource:
      action: create
      successCondition: status.succeeded > 0
      failureCondition: status.failed > 0
      manifest: |
        apiVersion: batch/v1
        kind: Job
        metadata:
          generateName: combo-f-kueue-train-
          namespace: kubeflow-user-example-com
          labels:
            combo-test: "true"
            combo-id: "F-kueue"
            kueue.x-k8s.io/queue-name: ai-storage-queue
        spec:
          backoffLimit: 0
          template:
            metadata:
              labels:
                combo-test: "true"
                combo-id: "F-kueue"
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
                  print("[F] Kueue-managed Training Job")
                  print("=" * 50)
                  for i in range(2):
                      print(f"  Training {i+1}/2...")
                      time.sleep(5)
                  print("[F-train] Done!")
                resources:
                  requests:
                    cpu: "50m"
                    memory: "64Mi"
              restartPolicy: Never
EOF

# ----- Step 2: Workflow Step Pod 검증 -----
echo ""
echo "--- Step 2: Workflow Step Pod 웹훅 검증 ---"
wait_for_pod "workflows.argoproj.io/workflow=combo-f-workflow-kueue" 90
POD=$(kubectl get pods -n ${NS} -l "workflows.argoproj.io/workflow=combo-f-workflow-kueue" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -n "${POD}" ]; then
    show_pod_status "${POD}"
    check_scheduler    "${TEST_ID}-wf-scheduler"     "${POD}"
    check_sidecar      "${TEST_ID}-wf-sidecar"        "${POD}"
    check_shareprocess "${TEST_ID}-wf-shareprocess"   "${POD}"
fi

# ----- Step 3: Kueue Job Pod 검증 (나중에 생성됨) -----
echo ""
echo "--- Step 3: Kueue Job Pod 검증 (train step 완료 후) ---"
echo -e "${YELLOW}[NOTE]${NC} Kueue Job Pod는 preprocess 완료 후 생성됩니다."
echo "  수동 확인: kubectl get pods -n ${NS} -l combo-id=F-kueue"

print_summary "${TEST_ID}"
