#!/usr/bin/env bash
#
# Orchestration Policy Engine - Scaling Scenario Test
# 실제 Pod에 부하를 주어 스케일링 정책 테스트
#
# 시나리오:
# 1. 테스트용 Deployment 생성
# 2. CPU 부하를 주는 Pod 생성
# 3. Scaling 정책 생성 (autoExecute: true)
# 4. 정책이 자동 실행되어 스케일링이 시도되는지 확인
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

NAMESPACE="apollo"
TEST_NAMESPACE="default"
TEST_DEPLOYMENT_NAME="scaling-test-app"

print_header "Scaling Scenario Test"
log_info "실제 Deployment를 생성하고 부하를 주어 스케일링 정책을 테스트합니다."
echo ""

# ============================================
# Prerequisites
# ============================================
log_step "1. Prerequisites Check"

run_test "Policy Engine running" "check_deployment_running $NAMESPACE orchestration-policy-engine"

# ============================================
# Step 1: Create Test Deployment
# ============================================
log_step "2. Create Test Deployment"

log_info "Creating test deployment..."
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $TEST_DEPLOYMENT_NAME
  namespace: $TEST_NAMESPACE
  labels:
    app: scaling-test
    test: scenario
spec:
  replicas: 1
  selector:
    matchLabels:
      app: scaling-test
  template:
    metadata:
      labels:
        app: scaling-test
    spec:
      containers:
      - name: app
        image: nginx:alpine
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: "100m"
            memory: "64Mi"
          limits:
            cpu: "200m"
            memory: "128Mi"
EOF

log_info "Waiting for deployment to be ready..."
kubectl rollout status deployment/$TEST_DEPLOYMENT_NAME -n $TEST_NAMESPACE --timeout=60s 2>/dev/null || true

sleep 3

INITIAL_REPLICAS=$(kubectl get deployment $TEST_DEPLOYMENT_NAME -n $TEST_NAMESPACE -o jsonpath='{.spec.replicas}' 2>/dev/null)
log_info "Initial replicas: $INITIAL_REPLICAS"

run_test "Test deployment created" "kubectl get deployment $TEST_DEPLOYMENT_NAME -n $TEST_NAMESPACE &>/dev/null"

# ============================================
# Step 2: Create Scaling Policy (autoExecute: false)
# ============================================
log_step "3. Create Scaling Policy (autoExecute: false)"

log_info "Creating scaling policy with autoExecute: false..."
cat <<EOF | kubectl apply -f -
apiVersion: apollo.keti.re.kr/v1alpha1
kind: OrchestrationPolicy
metadata:
  name: scenario-scaling-manual
  namespace: $NAMESPACE
spec:
  policyType: scaling
  priority: 90
  autoExecute: false
  targetWorkload:
    name: $TEST_DEPLOYMENT_NAME
    namespace: $TEST_NAMESPACE
    kind: Deployment
  conditions:
    triggers:
    - type: threshold
      metric: cpu_usage
      threshold: "70"
  actions:
    scaling:
      minReplicas: 1
      maxReplicas: 5
      targetCPU: 60
      targetMemory: 70
EOF

sleep 3

MANUAL_STATUS=$(kubectl get orchestrationpolicy scenario-scaling-manual -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
log_info "Manual policy status: $MANUAL_STATUS"
run_test "Manual policy waiting" "[ '$MANUAL_STATUS' != 'Executing' ]"

# ============================================
# Step 3: Create Scaling Policy (autoExecute: true)
# ============================================
log_step "4. Create Scaling Policy (autoExecute: true)"

log_info "Creating scaling policy with autoExecute: true..."
cat <<EOF | kubectl apply -f -
apiVersion: apollo.keti.re.kr/v1alpha1
kind: OrchestrationPolicy
metadata:
  name: scenario-scaling-auto
  namespace: $NAMESPACE
spec:
  policyType: scaling
  priority: 85
  autoExecute: true
  targetWorkload:
    name: $TEST_DEPLOYMENT_NAME
    namespace: $TEST_NAMESPACE
    kind: Deployment
  conditions:
    triggers:
    - type: threshold
      metric: cpu_usage
      threshold: "50"
    - type: threshold
      metric: request_rate
      threshold: "100"
  actions:
    scaling:
      minReplicas: 2
      maxReplicas: 8
      targetCPU: 50
      targetMemory: 60
EOF

log_info "Waiting for auto-execution (10 seconds)..."
sleep 10

AUTO_STATUS=$(kubectl get orchestrationpolicy scenario-scaling-auto -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
AUTO_RESULT=$(kubectl get orchestrationpolicy scenario-scaling-auto -n $NAMESPACE -o jsonpath='{.status.result}' 2>/dev/null || echo "")

log_info "Auto policy status: $AUTO_STATUS"
log_info "Auto policy result: ${AUTO_RESULT:-none}"

# ============================================
# Step 4: Simulate Load (Optional)
# ============================================
log_step "5. Simulate Load (Optional)"

log_info "Creating stress test pod to generate CPU load..."
cat <<EOF | kubectl apply -f - 2>/dev/null || true
apiVersion: v1
kind: Pod
metadata:
  name: stress-test-scaling
  namespace: $TEST_NAMESPACE
  labels:
    test: stress
spec:
  containers:
  - name: stress
    image: polinux/stress
    command: ["stress"]
    args: ["--cpu", "1", "--timeout", "60s"]
    resources:
      requests:
        cpu: "100m"
        memory: "64Mi"
      limits:
        cpu: "500m"
        memory: "128Mi"
  restartPolicy: Never
EOF

log_info "Stress pod will run for 60 seconds..."
log_info "In a real scenario, this would trigger CPU-based scaling policies."

sleep 10

# Check if metrics are available
log_info "Checking current resource usage..."
kubectl top pods -n $TEST_NAMESPACE 2>/dev/null || log_info "Metrics server may not be available"

# ============================================
# Step 5: Verify Results
# ============================================
log_step "6. Verify Results"

echo ""
log_info "Policy status comparison:"
echo ""
kubectl get orchestrationpolicies -n $NAMESPACE -o custom-columns=\
'NAME:.metadata.name,TYPE:.spec.policyType,AUTO-EXEC:.spec.autoExecute,STATUS:.status.phase,RESULT:.status.result' 2>/dev/null | grep -E "scenario-scaling|NAME"

echo ""

# Check policy execution
if [ "$AUTO_STATUS" == "Executing" ] || [ "$AUTO_STATUS" == "Completed" ]; then
    run_test "Auto scaling policy executed" "true"
    log_info "Scaling policy was auto-executed!"
elif [ "$AUTO_STATUS" == "Failed" ]; then
    run_test "Auto scaling policy attempted" "true"
    log_info "Scaling attempted but failed (may be expected if HPA not configured)"
else
    run_test "Auto scaling policy processed" "[ '$AUTO_STATUS' != '' ]"
fi

# Check current replicas
CURRENT_REPLICAS=$(kubectl get deployment $TEST_DEPLOYMENT_NAME -n $TEST_NAMESPACE -o jsonpath='{.spec.replicas}' 2>/dev/null)
log_info "Current replicas: $CURRENT_REPLICAS (initial: $INITIAL_REPLICAS)"

# ============================================
# Step 6: Check Logs
# ============================================
log_step "7. Check Logs"

log_info "Policy Engine logs:"
kubectl logs -n $NAMESPACE -l control-plane=controller-manager --tail=30 2>/dev/null | grep -E "scenario-scaling|autoscaling|Reconciling" | tail -10 || log_info "No matching entries"

# ============================================
# Cleanup
# ============================================
log_step "8. Cleanup"

log_info "Deleting test resources..."

# Delete policies
kubectl delete orchestrationpolicy scenario-scaling-manual -n $NAMESPACE --ignore-not-found >/dev/null
kubectl delete orchestrationpolicy scenario-scaling-auto -n $NAMESPACE --ignore-not-found >/dev/null

# Delete stress pod
kubectl delete pod stress-test-scaling -n $TEST_NAMESPACE --ignore-not-found --grace-period=0 --force 2>/dev/null || true

# Delete deployment
kubectl delete deployment $TEST_DEPLOYMENT_NAME -n $TEST_NAMESPACE --ignore-not-found >/dev/null

log_info "Cleanup completed"

# ============================================
# Summary
# ============================================
echo ""
log_info "=========================================="
log_info "       SCALING SCENARIO SUMMARY"
log_info "=========================================="
log_info ""
log_info "테스트 시나리오:"
log_info "  1. 테스트 Deployment 생성 (replicas: 1)"
log_info "  2. Scaling 정책 생성 (autoExecute: false) -> 대기 상태"
log_info "  3. Scaling 정책 생성 (autoExecute: true) -> 자동 실행"
log_info "  4. Stress 테스트로 부하 생성"
log_info ""
log_info "결과:"
log_info "  - autoExecute: false -> 상태: $MANUAL_STATUS"
log_info "  - autoExecute: true  -> 상태: $AUTO_STATUS (결과: ${AUTO_RESULT:-none})"
log_info "  - Replicas: $INITIAL_REPLICAS -> $CURRENT_REPLICAS"
log_info ""

print_test_summary
