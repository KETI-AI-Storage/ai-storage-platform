#!/bin/bash
# =============================================================================
# [조합 B] Argo CD + Argo Workflow
#
# 구성요소: Argo CD (O) | Kubeflow (-) | Argo Workflow (O) | Kueue (-)
# 설명:     파이프라인 워크플로우를 Argo CD로 GitOps 배포
#
# 검증 항목:
#   1. Workflow 정상 생성
#   2. 각 Step Pod에 schedulerName 주입
#   3. 각 Step Pod에 sidecar 주입
#   4. 각 Step Pod에 shareProcessNamespace 주입
# =============================================================================
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

TEST_ID="B"
echo "=========================================="
echo " [${TEST_ID}] Argo CD + Argo Workflow"
echo " Namespace: ${NS}"
echo "=========================================="
echo ""

# ----- Step 1: Argo Workflow 생성 -----
echo "--- Step 1: Argo Workflow 생성 ---"
cat <<'EOF' | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  name: combo-b-pipeline
  namespace: kubeflow-user-example-com
  labels:
    combo-test: "true"
    combo-id: "B"
spec:
  entrypoint: pipeline
  serviceAccountName: default-editor
  templates:
  - name: pipeline
    dag:
      tasks:
      - name: preprocess
        template: preprocess-step
      - name: train
        template: train-step
        dependencies: [preprocess]

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
        print("[B] Argo Workflow - Preprocess")
        print("=" * 50)
        for i in range(2):
            print(f"  Preprocessing {i+1}/2...")
            time.sleep(3)
        print("[B-preprocess] Done!")
      resources:
        requests:
          cpu: "50m"
          memory: "64Mi"

  - name: train-step
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
        print("[B] Argo Workflow - Train")
        print("=" * 50)
        for i in range(2):
            print(f"  Training {i+1}/2...")
            time.sleep(3)
        print("[B-train] Done!")
      resources:
        requests:
          cpu: "50m"
          memory: "64Mi"
EOF

# ----- Step 2: Pod 대기 및 검증 -----
echo ""
echo "--- Step 2: 웹훅 주입 검증 (preprocess Pod) ---"
wait_for_pod "workflows.argoproj.io/workflow=combo-b-pipeline" 90
POD=$(kubectl get pods -n ${NS} -l "workflows.argoproj.io/workflow=combo-b-pipeline" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -n "${POD}" ]; then
    show_pod_status "${POD}"
    check_scheduler    "${TEST_ID}-scheduler"     "${POD}"
    check_sidecar      "${TEST_ID}-sidecar"        "${POD}"
    check_shareprocess "${TEST_ID}-shareprocess"   "${POD}"
fi

# ----- Step 3: Argo CD 참고 -----
echo ""
echo -e "${CYAN}[INFO] Argo CD GitOps 배포 시:${NC}"
echo "  ArgoCD Application → Git repo (pipelines/workflow.yaml) → 자동 Sync"
echo "  Workflow가 생성하는 각 Step Pod에 웹훅이 자동 주입"

print_summary "${TEST_ID}"
