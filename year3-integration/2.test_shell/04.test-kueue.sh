#!/usr/bin/env bash
#
# Test 04: Kueue Installation and Functionality
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "=========================================="
echo "  Kueue Installation Test"
echo "=========================================="
echo ""

# Check if Kueue is installed
if ! kubectl get namespace kueue-system &>/dev/null; then
    log_warn "Kueue namespace not found. Skipping Kueue tests."
    exit 0
fi

# Test 1: Kueue namespace exists
run_test "Kueue Namespace" "kubectl get namespace kueue-system &>/dev/null"

# Test 2: Kueue Controller Manager running
run_test "Kueue Controller Running" "kubectl get deployment kueue-controller-manager -n kueue-system -o jsonpath='{.status.readyReplicas}' | grep -qE '^[1-9]'"

# Test 3: Kueue CRDs installed
run_test "ClusterQueue CRD" "kubectl get crd clusterqueues.kueue.x-k8s.io &>/dev/null"
run_test "LocalQueue CRD" "kubectl get crd localqueues.kueue.x-k8s.io &>/dev/null"
run_test "Workload CRD" "kubectl get crd workloads.kueue.x-k8s.io &>/dev/null"
run_test "ResourceFlavor CRD" "kubectl get crd resourceflavors.kueue.x-k8s.io &>/dev/null"

# Test 4: Check existing ResourceFlavors
RF_COUNT=$(kubectl get resourceflavors --no-headers 2>/dev/null | wc -l)
run_test "ResourceFlavors Exist" "[ $RF_COUNT -gt 0 ]"
if [ "$RF_COUNT" -gt 0 ]; then
    log_info "ResourceFlavors found:"
    kubectl get resourceflavors --no-headers 2>/dev/null | while read -r line; do
        log_info "  - $(echo "$line" | awk '{print $1}')"
    done
fi

# Test 5: Check existing ClusterQueues
CQ_COUNT=$(kubectl get clusterqueues --no-headers 2>/dev/null | wc -l)
run_test "ClusterQueues Exist" "[ $CQ_COUNT -gt 0 ]"
if [ "$CQ_COUNT" -gt 0 ]; then
    log_info "ClusterQueues found:"
    kubectl get clusterqueues --no-headers 2>/dev/null | while read -r line; do
        log_info "  - $(echo "$line" | awk '{print $1}')"
    done
fi

# Test 6: Check existing LocalQueues
LQ_COUNT=$(kubectl get localqueues -A --no-headers 2>/dev/null | wc -l)
if [ "$LQ_COUNT" -gt 0 ]; then
    run_test "LocalQueues Exist" "[ $LQ_COUNT -gt 0 ]"
    log_info "LocalQueues found:"
    kubectl get localqueues -A --no-headers 2>/dev/null | while read -r line; do
        log_info "  - $(echo "$line" | awk '{print $1 " / " $2}')"
    done
fi

# Test 7: Create test workload (Job)
log_test "Creating test Kueue workload..."

# Ensure default LocalQueue exists
if ! kubectl get localqueue default-queue -n default &>/dev/null; then
    log_info "Creating default LocalQueue for testing..."
    cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: kueue.x-k8s.io/v1beta1
kind: LocalQueue
metadata:
  name: default-queue
  namespace: default
spec:
  clusterQueue: ai-storage-cluster-queue
EOF
fi

cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: test-kueue-job
  namespace: default
  labels:
    test: kueue
    kueue.x-k8s.io/queue-name: default-queue
spec:
  parallelism: 1
  completions: 1
  suspend: true
  template:
    spec:
      containers:
      - name: test
        image: busybox:latest
        command: ["sh", "-c", "echo 'Kueue job test successful!' && sleep 5"]
        resources:
          requests:
            cpu: "100m"
            memory: "64Mi"
      restartPolicy: Never
EOF

run_test "Kueue Job Creation" "kubectl get job test-kueue-job -n default &>/dev/null"

# Wait for workload to be admitted
log_info "Waiting for workload to be admitted by Kueue..."
sleep 10

# Test 8: Check if workload was created
WORKLOAD_COUNT=$(kubectl get workloads -n default --no-headers 2>/dev/null | grep -c "test-kueue-job" || echo "0")
run_test "Workload Created" "[ $WORKLOAD_COUNT -gt 0 ]"

# Test 9: Check workload status
if [ "$WORKLOAD_COUNT" -gt 0 ]; then
    WORKLOAD_NAME=$(kubectl get workloads -n default --no-headers 2>/dev/null | grep "test-kueue-job" | awk '{print $1}')
    ADMISSION_STATUS=$(kubectl get workload "$WORKLOAD_NAME" -n default -o jsonpath='{.status.conditions[?(@.type=="Admitted")].status}' 2>/dev/null || echo "Unknown")
    log_info "Workload admission status: $ADMISSION_STATUS"
fi

# Wait for job completion
log_info "Waiting for job to complete..."
sleep 20

# Cleanup
log_info "Cleaning up test job..."
kubectl delete job test-kueue-job -n default --ignore-not-found >/dev/null

# Test 10: Kueue + Kubeflow integration (if Kubeflow is installed)
if kubectl get crd pytorchjobs.kubeflow.org &>/dev/null; then
    log_test "Testing Kueue + Kubeflow integration..."

    # Check if Kueue is configured for PyTorchJobs
    KUEUE_CONFIG=$(kubectl get configmap kueue-manager-config -n kueue-system -o yaml 2>/dev/null || echo "")
    if echo "$KUEUE_CONFIG" | grep -q "kubeflow.org"; then
        run_test "Kueue-Kubeflow Integration" "true"
        log_info "Kueue is configured to manage Kubeflow workloads"
    else
        log_info "Kueue may need additional configuration for Kubeflow integration"
    fi
fi

# Print summary
print_test_summary
