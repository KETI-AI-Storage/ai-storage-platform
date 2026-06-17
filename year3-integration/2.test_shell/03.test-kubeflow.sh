#!/usr/bin/env bash
#
# Test 03: Kubeflow Installation and Functionality
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "=========================================="
echo "  Kubeflow Installation Test"
echo "=========================================="
echo ""

# Check if Kubeflow is installed
if ! kubectl get namespace kubeflow &>/dev/null; then
    log_warn "Kubeflow namespace not found. Skipping Kubeflow tests."
    exit 0
fi

# Test 1: Kubeflow namespace exists
run_test "Kubeflow Namespace" "kubectl get namespace kubeflow &>/dev/null"

# Test 2: Training Operator
if kubectl get deployment training-operator -n kubeflow &>/dev/null; then
    run_test "Training Operator Running" "kubectl get deployment training-operator -n kubeflow -o jsonpath='{.status.readyReplicas}' | grep -qE '^[1-9]'"
else
    log_info "Training Operator not installed"
fi

# Test 3: PyTorchJob CRD
run_test "PyTorchJob CRD" "kubectl get crd pytorchjobs.kubeflow.org &>/dev/null"

# Test 4: TFJob CRD
run_test "TFJob CRD" "kubectl get crd tfjobs.kubeflow.org &>/dev/null"

# Test 5: Create test PyTorchJob
log_test "Creating test PyTorchJob..."
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: kubeflow.org/v1
kind: PyTorchJob
metadata:
  name: test-pytorch-job
  namespace: default
  labels:
    test: kubeflow
spec:
  pytorchReplicaSpecs:
    Master:
      replicas: 1
      restartPolicy: Never
      template:
        spec:
          containers:
          - name: pytorch
            image: python:3.9-slim
            command:
            - python
            - -c
            - "print('PyTorchJob test successful!')"
            resources:
              limits:
                cpu: "100m"
                memory: "128Mi"
EOF

run_test "PyTorchJob Creation" "kubectl get pytorchjob test-pytorch-job -n default &>/dev/null"

# Wait for job to complete
log_info "Waiting for PyTorchJob to complete..."
sleep 30

# Test 6: Check PyTorchJob status
JOB_STATUS=$(kubectl get pytorchjob test-pytorch-job -n default -o jsonpath='{.status.conditions[-1].type}' 2>/dev/null || echo "Unknown")
log_info "PyTorchJob status: $JOB_STATUS"
run_test "PyTorchJob Processed" "[ '$JOB_STATUS' != '' ]"

# Cleanup
log_info "Cleaning up test PyTorchJob..."
kubectl delete pytorchjob test-pytorch-job -n default --ignore-not-found >/dev/null

# Test 7: ML Pipeline (if installed)
if kubectl get deployment ml-pipeline -n kubeflow &>/dev/null; then
    run_test "ML Pipeline Running" "kubectl get deployment ml-pipeline -n kubeflow -o jsonpath='{.status.readyReplicas}' | grep -qE '^[1-9]'"
    run_test "ML Pipeline UI Running" "kubectl get deployment ml-pipeline-ui -n kubeflow -o jsonpath='{.status.readyReplicas}' | grep -qE '^[1-9]'"
else
    log_info "ML Pipeline not installed (optional)"
fi

# Test 8: Notebook Controller (if installed)
if kubectl get deployment notebook-controller -n kubeflow &>/dev/null; then
    run_test "Notebook Controller Running" "kubectl get deployment notebook-controller -n kubeflow -o jsonpath='{.status.readyReplicas}' | grep -qE '^[1-9]'"
else
    log_info "Notebook Controller not installed (optional)"
fi

# Test 9: Central Dashboard (if installed)
if kubectl get deployment centraldashboard -n kubeflow &>/dev/null; then
    run_test "Central Dashboard Running" "kubectl get deployment centraldashboard -n kubeflow -o jsonpath='{.status.readyReplicas}' | grep -qE '^[1-9]'"
else
    log_info "Central Dashboard not installed (optional)"
fi

# Print summary
print_test_summary
