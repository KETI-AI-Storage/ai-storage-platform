#!/bin/bash
# =============================================================================
# [조합 G] 전체 통합: Argo CD + Kubeflow + Argo Workflow + Kueue
#
# 구성요소: Argo CD (O) | Kubeflow (O) | Argo Workflow (O) | Kueue (O)
# 설명:     전체 통합 파이프라인
#           Argo Workflow DAG: preprocess → PyTorchJob(Kueue) → evaluate
#
# 검증 항목:
#   1. Workflow 정상 생성
#   2. Preprocess Pod 웹훅 주입
#   3. PyTorchJob에 Kueue label
#   4. PyTorchJob Master Pod 웹훅 주입
#   5. Evaluate Pod 웹훅 주입
# =============================================================================
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

TEST_ID="G"
echo "=========================================="
echo " [${TEST_ID}] 전체 통합 (Argo CD + Kubeflow + Workflow + Kueue)"
echo " Namespace: ${NS}"
echo "=========================================="
echo ""

# ----- Step 1: 전체 통합 Workflow 생성 -----
echo "--- Step 1: 통합 Workflow 생성 ---"
cat <<'EOF' | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  name: combo-g-full-integration
  namespace: kubeflow-user-example-com
  labels:
    combo-test: "true"
    combo-id: "G"
spec:
  entrypoint: full-pipeline
  serviceAccountName: default-editor
  templates:
  ###########################################################################
  # 메인 DAG: preprocess → train(PyTorchJob+Kueue) → evaluate
  ###########################################################################
  - name: full-pipeline
    dag:
      tasks:
      - name: preprocess
        template: preprocess-step
      - name: train
        template: create-pytorchjob
        dependencies: [preprocess]
      - name: evaluate
        template: evaluate-step
        dependencies: [train]

  ###########################################################################
  # Step 1: 전처리
  ###########################################################################
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
        print("[G] Full Integration - Preprocess")
        print("=" * 50)
        for s in ['tokenize', 'batch', 'save']:
            print(f"  {s}...")
            time.sleep(3)
        print("[G-preprocess] Done!")
      resources:
        requests:
          cpu: "50m"
          memory: "64Mi"

  ###########################################################################
  # Step 2: PyTorchJob (Kueue 관리)
  ###########################################################################
  - name: create-pytorchjob
    resource:
      action: create
      successCondition: status.replicaStatuses.Master.succeeded > 0
      failureCondition: status.replicaStatuses.Master.failed > 0
      manifest: |
        apiVersion: kubeflow.org/v1
        kind: PyTorchJob
        metadata:
          generateName: combo-g-train-
          namespace: kubeflow-user-example-com
          labels:
            combo-test: "true"
            combo-id: "G-train"
            kueue.x-k8s.io/queue-name: ai-storage-queue
            workflow-name: "combo-g-full-integration"
        spec:
          pytorchReplicaSpecs:
            Master:
              replicas: 1
              restartPolicy: OnFailure
              template:
                metadata:
                  labels:
                    combo-test: "true"
                    combo-id: "G-train"
                spec:
                  tolerations:
                  - operator: Exists
                  containers:
                  - name: pytorch
                    image: python:3.11-slim
                    command: [python3, -c]
                    args:
                    - |
                      import time, random
                      print("=" * 50)
                      print("[G] PyTorchJob + Kueue - Master")
                      print("=" * 50)
                      for epoch in range(2):
                          loss = 2.0 - epoch*0.3 + random.uniform(-0.05, 0.05)
                          print(f"  Epoch {epoch+1}/2: loss={loss:.4f}")
                          time.sleep(5)
                      print("[G-train] Done!")
                    resources:
                      requests:
                        cpu: "50m"
                        memory: "64Mi"

  ###########################################################################
  # Step 3: 평가
  ###########################################################################
  - name: evaluate-step
    tolerations:
    - operator: Exists
    container:
      image: python:3.11-slim
      name: main
      command: [python3, -c]
      args:
      - |
        import time, random
        print("=" * 50)
        print("[G] Full Integration - Evaluate")
        print("=" * 50)
        acc = random.uniform(0.90, 0.98)
        print(f"  Accuracy: {acc:.2%}")
        print("[G-evaluate] Done!")
      resources:
        requests:
          cpu: "50m"
          memory: "64Mi"
EOF

# ----- Step 2: Preprocess Pod 검증 -----
echo ""
echo "--- Step 2: Preprocess Pod 웹훅 검증 ---"
wait_for_pod "workflows.argoproj.io/workflow=combo-g-full-integration" 90
POD=$(kubectl get pods -n ${NS} -l "workflows.argoproj.io/workflow=combo-g-full-integration" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -n "${POD}" ]; then
    show_pod_status "${POD}"
    check_scheduler    "${TEST_ID}-preprocess-scheduler"     "${POD}"
    check_sidecar      "${TEST_ID}-preprocess-sidecar"        "${POD}"
    check_shareprocess "${TEST_ID}-preprocess-shareprocess"   "${POD}"
fi

# ----- Step 3: 후속 검증 안내 -----
echo ""
echo -e "${YELLOW}[NOTE]${NC} PyTorchJob Pod는 preprocess 완료 후 생성됩니다."
echo "  수동 확인:"
echo "    kubectl get pods -n ${NS} -l combo-id=G-train"
echo "    kubectl get pytorchjobs -n ${NS} -l combo-id=G-train"
echo ""
echo -e "${CYAN}[INFO] 전체 통합 흐름:${NC}"
echo "  Argo CD → Git Sync → Workflow 배포"
echo "  Workflow DAG: preprocess → PyTorchJob(Kueue) → evaluate"
echo "  모든 Pod에 웹훅이 자동으로 scheduler/sidecar/shareProcess 주입"

print_summary "${TEST_ID}"
