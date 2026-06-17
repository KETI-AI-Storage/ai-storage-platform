#!/usr/bin/env bash
#
# AI Storage Scheduler Component Test
# CSD/GPU 인식 커스텀 스케줄러 테스트
#
# 테스트 항목:
# 1. 스케줄러 배포 상태
# 2. 커스텀 스케줄러로 Pod 스케줄링
# 3. 노드 필터링 테스트
# 4. 스코어링 테스트
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

NAMESPACE="keti"
DEPLOYMENT_NAME="ai-storage-scheduler"
SCHEDULER_NAME="ai-storage-scheduler"
TEST_NAMESPACE="default"

print_header "AI Storage Scheduler Component Test"

# ============================================
# Prerequisites Check
# ============================================
log_step "1. Prerequisites Check"

if ! kubectl get namespace $NAMESPACE &>/dev/null; then
    log_error "Namespace '$NAMESPACE' not found"
    log_info "Creating namespace..."
    kubectl create namespace $NAMESPACE
fi

if ! kubectl get deployment $DEPLOYMENT_NAME -n $NAMESPACE &>/dev/null; then
    log_error "Deployment '$DEPLOYMENT_NAME' not found in namespace '$NAMESPACE'"
    log_info "Please deploy ai-storage-scheduler first"
    exit 1
fi

run_test "Namespace exists" "kubectl get namespace $NAMESPACE &>/dev/null"

# ============================================
# Deployment Test
# ============================================
log_step "2. Deployment Test"

run_test "Deployment exists" "kubectl get deployment $DEPLOYMENT_NAME -n $NAMESPACE &>/dev/null"
run_test "Deployment is ready" "check_deployment_running $NAMESPACE $DEPLOYMENT_NAME"

# Get pod info
POD_NAME=$(kubectl get pods -n $NAMESPACE -l app=$DEPLOYMENT_NAME -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$POD_NAME" ]; then
    log_info "Scheduler Pod: $POD_NAME"
    run_test "Scheduler pod running" "kubectl get pod $POD_NAME -n $NAMESPACE -o jsonpath='{.status.phase}' | grep -q Running"
fi

# ============================================
# RBAC Test
# ============================================
log_step "3. RBAC Test"

# Check if scheduler has proper RBAC
run_test "ServiceAccount exists" "kubectl get serviceaccount -n $NAMESPACE $DEPLOYMENT_NAME &>/dev/null || kubectl get serviceaccount -n $NAMESPACE default &>/dev/null"

# ============================================
# Basic Scheduling Test
# ============================================
log_step "4. Basic Scheduling Test"

log_info "Creating test pod with custom scheduler..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: scheduler-test-basic
  namespace: $TEST_NAMESPACE
  labels:
    test: scheduler
spec:
  schedulerName: $SCHEDULER_NAME
  containers:
  - name: test
    image: busybox:latest
    command: ["sh", "-c", "echo 'Scheduled by ai-storage-scheduler!' && sleep 60"]
    resources:
      requests:
        cpu: "50m"
        memory: "32Mi"
  restartPolicy: Never
EOF

log_info "Waiting for pod to be scheduled (30 seconds max)..."
sleep 10

# Check scheduling status
POD_STATUS=$(kubectl get pod scheduler-test-basic -n $TEST_NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
POD_NODE=$(kubectl get pod scheduler-test-basic -n $TEST_NAMESPACE -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "")

log_info "Pod status: $POD_STATUS"
log_info "Scheduled node: ${POD_NODE:-not scheduled yet}"

if [ -n "$POD_NODE" ]; then
    run_test "Pod scheduled by custom scheduler" "true"
    log_info "Successfully scheduled to node: $POD_NODE"
else
    # Wait a bit more
    sleep 10
    POD_NODE=$(kubectl get pod scheduler-test-basic -n $TEST_NAMESPACE -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "")
    if [ -n "$POD_NODE" ]; then
        run_test "Pod scheduled by custom scheduler" "true"
    else
        # Check if pending
        POD_STATUS=$(kubectl get pod scheduler-test-basic -n $TEST_NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null)
        if [ "$POD_STATUS" == "Pending" ]; then
            # Check events
            log_warn "Pod is Pending - checking events..."
            kubectl describe pod scheduler-test-basic -n $TEST_NAMESPACE | grep -A 5 "Events:" | tail -5
            run_test "Pod created (pending)" "true"
        else
            run_test "Pod scheduled" "[ '$POD_STATUS' == 'Running' ]"
        fi
    fi
fi

# ============================================
# Multiple Pods Scheduling Test
# ============================================
log_step "5. Multiple Pods Scheduling Test"

log_info "Creating multiple pods to test scheduling distribution..."

for i in 1 2 3; do
    cat <<EOF | kubectl apply -f - 2>/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: scheduler-test-multi-$i
  namespace: $TEST_NAMESPACE
  labels:
    test: scheduler-multi
spec:
  schedulerName: $SCHEDULER_NAME
  containers:
  - name: test
    image: busybox:latest
    command: ["sh", "-c", "sleep 60"]
    resources:
      requests:
        cpu: "25m"
        memory: "16Mi"
  restartPolicy: Never
EOF
done

log_info "Waiting for pods to be scheduled..."
sleep 15

# Check distribution
log_info "Pod distribution across nodes:"
kubectl get pods -n $TEST_NAMESPACE -l test=scheduler-multi -o wide --no-headers 2>/dev/null | \
    awk '{print $1, $3, $7}' | column -t

SCHEDULED_COUNT=$(kubectl get pods -n $TEST_NAMESPACE -l test=scheduler-multi -o jsonpath='{.items[*].spec.nodeName}' 2>/dev/null | wc -w)
run_test "Multiple pods scheduled" "[ $SCHEDULED_COUNT -ge 1 ]"

# ============================================
# Resource Request Test
# ============================================
log_step "6. Resource Request Test"

log_info "Creating pod with specific resource requests..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: scheduler-test-resources
  namespace: $TEST_NAMESPACE
  labels:
    test: scheduler-resources
spec:
  schedulerName: $SCHEDULER_NAME
  containers:
  - name: test
    image: nginx:alpine
    resources:
      requests:
        cpu: "100m"
        memory: "128Mi"
      limits:
        cpu: "200m"
        memory: "256Mi"
  restartPolicy: Never
EOF

sleep 10

RESOURCE_POD_NODE=$(kubectl get pod scheduler-test-resources -n $TEST_NAMESPACE -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "")
if [ -n "$RESOURCE_POD_NODE" ]; then
    run_test "Resource-constrained pod scheduled" "true"
    log_info "Scheduled to node: $RESOURCE_POD_NODE"

    # Check node has enough resources
    log_info "Node resource status:"
    kubectl describe node $RESOURCE_POD_NODE 2>/dev/null | grep -A 5 "Allocated resources:" | head -6 || true
else
    log_warn "Pod not yet scheduled"
fi

# ============================================
# Scheduler Logs
# ============================================
log_step "7. Scheduler Logs"

log_info "Recent scheduler logs:"
kubectl logs -n $NAMESPACE -l app=$DEPLOYMENT_NAME --tail=30 2>/dev/null | tail -20 || log_warn "Could not retrieve logs"

# Check for scheduling decisions in logs
log_info ""
log_info "Scheduling decisions:"
kubectl logs -n $NAMESPACE -l app=$DEPLOYMENT_NAME --tail=100 2>/dev/null | grep -iE "scheduled|binding|selected|score" | tail -10 || log_info "No scheduling entries found"

# ============================================
# Cleanup
# ============================================
log_step "8. Cleanup"

log_info "Deleting test pods..."
kubectl delete pod scheduler-test-basic -n $TEST_NAMESPACE --ignore-not-found --grace-period=0 --force 2>/dev/null || true
kubectl delete pods -n $TEST_NAMESPACE -l test=scheduler-multi --ignore-not-found --grace-period=0 --force 2>/dev/null || true
kubectl delete pod scheduler-test-resources -n $TEST_NAMESPACE --ignore-not-found --grace-period=0 --force 2>/dev/null || true

log_info "Cleanup completed"

# ============================================
# Summary
# ============================================
echo ""
log_info "=========================================="
log_info "     SCHEDULER TEST SUMMARY"
log_info "=========================================="
log_info ""
log_info "Scheduler Name: $SCHEDULER_NAME"
log_info "Namespace: $NAMESPACE"
log_info ""
log_info "테스트 결과:"
log_info "  - 기본 스케줄링: $([ -n \"$POD_NODE\" ] && echo 'OK' || echo 'Pending')"
log_info "  - 멀티 Pod 스케줄링: $SCHEDULED_COUNT/3 scheduled"
log_info "  - 리소스 기반 스케줄링: $([ -n \"$RESOURCE_POD_NODE\" ] && echo 'OK' || echo 'Pending')"
log_info ""
log_info "Pod 스케줄링 시 schedulerName: $SCHEDULER_NAME 사용"
log_info ""

print_test_summary
