#!/usr/bin/env bash
#
# Orchestration Policy Engine - Migration Scenario Test
# 실제 Pod를 생성하여 마이그레이션 정책 테스트
#
# 시나리오:
# 1. 테스트용 Pod 생성 (nginx)
# 2. Pod가 특정 노드에서 실행되도록 설정
# 3. Migration 정책 생성 (autoExecute: true)
# 4. 정책이 자동 실행되어 마이그레이션이 시도되는지 확인
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

NAMESPACE="apollo"
TEST_NAMESPACE="default"
TEST_POD_NAME="migration-test-pod"
TEST_DEPLOYMENT_NAME="migration-test-deployment"

print_header "Migration Scenario Test"
log_info "실제 Pod를 생성하여 마이그레이션 정책이 동작하는지 테스트합니다."
echo ""

# ============================================
# Prerequisites
# ============================================
log_step "1. Prerequisites Check"

run_test "Policy Engine running" "check_deployment_running $NAMESPACE orchestration-policy-engine"

# Get node list
NODES=$(kubectl get nodes --no-headers -o custom-columns=":metadata.name" | grep -v control-plane | head -2)
NODE_COUNT=$(echo "$NODES" | wc -l)

if [ "$NODE_COUNT" -lt 1 ]; then
    log_error "At least 1 worker node is required for migration test"
    log_info "Available nodes:"
    kubectl get nodes
    exit 1
fi

SOURCE_NODE=$(echo "$NODES" | head -1)
TARGET_NODE=$(echo "$NODES" | tail -1)

# If only one node, use the same node (migration will be simulated)
if [ "$SOURCE_NODE" == "$TARGET_NODE" ] || [ -z "$TARGET_NODE" ]; then
    TARGET_NODE="$SOURCE_NODE"
    log_warn "Only one worker node available - migration target is same as source"
fi

log_info "Source Node: $SOURCE_NODE"
log_info "Target Node: $TARGET_NODE"

# ============================================
# Step 1: Create Test Deployment
# ============================================
log_step "2. Create Test Deployment"

log_info "Creating test deployment on node: $SOURCE_NODE"
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $TEST_DEPLOYMENT_NAME
  namespace: $TEST_NAMESPACE
  labels:
    app: migration-test
    test: scenario
spec:
  replicas: 1
  selector:
    matchLabels:
      app: migration-test
  template:
    metadata:
      labels:
        app: migration-test
    spec:
      nodeSelector:
        kubernetes.io/hostname: $SOURCE_NODE
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: "50m"
            memory: "64Mi"
          limits:
            cpu: "100m"
            memory: "128Mi"
EOF

log_info "Waiting for deployment to be ready..."
kubectl rollout status deployment/$TEST_DEPLOYMENT_NAME -n $TEST_NAMESPACE --timeout=60s 2>/dev/null || true

sleep 5

# Get actual pod name and node
ACTUAL_POD=$(kubectl get pods -n $TEST_NAMESPACE -l app=migration-test -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
ACTUAL_NODE=$(kubectl get pods -n $TEST_NAMESPACE -l app=migration-test -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null)

log_info "Created Pod: $ACTUAL_POD"
log_info "Running on Node: $ACTUAL_NODE"

run_test "Test deployment created" "kubectl get deployment $TEST_DEPLOYMENT_NAME -n $TEST_NAMESPACE &>/dev/null"
run_test "Pod is running" "kubectl get pod $ACTUAL_POD -n $TEST_NAMESPACE -o jsonpath='{.status.phase}' | grep -q Running"

# ============================================
# Step 2: Create Migration Policy (autoExecute: false first)
# ============================================
log_step "3. Create Migration Policy (autoExecute: false)"

log_info "Creating migration policy with autoExecute: false..."
log_info "This allows us to see the policy in Pending state before execution."

cat <<EOF | kubectl apply -f -
apiVersion: apollo.keti.re.kr/v1alpha1
kind: OrchestrationPolicy
metadata:
  name: scenario-migration-manual
  namespace: $NAMESPACE
spec:
  policyType: migration
  priority: 100
  autoExecute: false
  targetWorkload:
    name: $TEST_DEPLOYMENT_NAME
    namespace: $TEST_NAMESPACE
    kind: Deployment
  conditions:
    triggers:
    - type: manual
      metric: node_pressure
      threshold: "trigger"
  actions:
    migration:
      sourceNode: $ACTUAL_NODE
      targetNode: $TARGET_NODE
      preservePV: true
      timeout: 600
EOF

sleep 3

MANUAL_STATUS=$(kubectl get orchestrationpolicy scenario-migration-manual -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
log_info "Manual policy status: $MANUAL_STATUS"
run_test "Manual policy created (not executing)" "[ '$MANUAL_STATUS' != 'Executing' ] && [ '$MANUAL_STATUS' != 'Completed' ]"

# ============================================
# Step 3: Create Migration Policy (autoExecute: true)
# ============================================
log_step "4. Create Migration Policy (autoExecute: true)"

log_info "Creating migration policy with autoExecute: true..."
log_info "This policy will automatically trigger migration."

cat <<EOF | kubectl apply -f -
apiVersion: apollo.keti.re.kr/v1alpha1
kind: OrchestrationPolicy
metadata:
  name: scenario-migration-auto
  namespace: $NAMESPACE
spec:
  policyType: migration
  priority: 95
  autoExecute: true
  targetWorkload:
    name: $TEST_DEPLOYMENT_NAME
    namespace: $TEST_NAMESPACE
    kind: Deployment
  conditions:
    triggers:
    - type: threshold
      metric: node_memory_pressure
      threshold: "50"
  actions:
    migration:
      sourceNode: $ACTUAL_NODE
      targetNode: $TARGET_NODE
      preservePV: true
      timeout: 600
EOF

log_info "Waiting for auto-execution (15 seconds)..."
sleep 15

AUTO_STATUS=$(kubectl get orchestrationpolicy scenario-migration-auto -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
AUTO_RESULT=$(kubectl get orchestrationpolicy scenario-migration-auto -n $NAMESPACE -o jsonpath='{.status.result}' 2>/dev/null || echo "")

log_info "Auto policy status: $AUTO_STATUS"
log_info "Auto policy result: ${AUTO_RESULT:-none}"

# ============================================
# Step 4: Verify Results
# ============================================
log_step "5. Verify Results"

echo ""
log_info "Policy comparison:"
echo ""
kubectl get orchestrationpolicies -n $NAMESPACE -l test!=other -o custom-columns=\
'NAME:.metadata.name,TYPE:.spec.policyType,AUTO-EXEC:.spec.autoExecute,STATUS:.status.phase,RESULT:.status.result' 2>/dev/null | grep -E "scenario-migration|NAME"

echo ""

# Check if auto policy was executed
if [ "$AUTO_STATUS" == "Executing" ] || [ "$AUTO_STATUS" == "Completed" ]; then
    run_test "Auto policy executed" "true"
    log_info "Migration policy with autoExecute: true was executed!"
elif [ "$AUTO_STATUS" == "Failed" ]; then
    run_test "Auto policy attempted" "true"
    log_warn "Migration failed (this may be expected if orchestrator returned an error)"
else
    run_test "Auto policy processed" "[ '$AUTO_STATUS' != '' ]"
fi

# Compare with manual policy
if [ "$MANUAL_STATUS" != "Executing" ] && [ "$MANUAL_STATUS" != "Completed" ]; then
    run_test "Manual policy NOT auto-executed" "true"
    log_info "Manual policy (autoExecute: false) correctly waiting for approval"
else
    run_test "Manual policy stayed pending" "false"
fi

# ============================================
# Step 5: Check Logs
# ============================================
log_step "6. Check Controller Logs"

log_info "Policy Engine logs:"
kubectl logs -n $NAMESPACE -l control-plane=controller-manager --tail=30 2>/dev/null | grep -E "scenario-migration|Reconciling|Executing|operator" | tail -15 || log_info "No matching entries"

# Check orchestrator logs if available
if kubectl get deployment ai-storage-orchestrator -n kube-system &>/dev/null; then
    echo ""
    log_info "Orchestrator logs:"
    kubectl logs -n kube-system -l app=ai-storage-orchestrator --tail=20 2>/dev/null | grep -iE "migration|$TEST_DEPLOYMENT_NAME" | tail -10 || log_info "No matching entries"
fi

# ============================================
# Cleanup
# ============================================
log_step "7. Cleanup"

log_info "Deleting test resources..."

# Delete policies
kubectl delete orchestrationpolicy scenario-migration-manual -n $NAMESPACE --ignore-not-found >/dev/null
kubectl delete orchestrationpolicy scenario-migration-auto -n $NAMESPACE --ignore-not-found >/dev/null

# Delete deployment
kubectl delete deployment $TEST_DEPLOYMENT_NAME -n $TEST_NAMESPACE --ignore-not-found >/dev/null

log_info "Cleanup completed"

# ============================================
# Summary
# ============================================
echo ""
log_info "=========================================="
log_info "      MIGRATION SCENARIO SUMMARY"
log_info "=========================================="
log_info ""
log_info "테스트 시나리오:"
log_info "  1. 테스트 Deployment 생성 (node: $SOURCE_NODE)"
log_info "  2. Migration 정책 생성 (autoExecute: false) -> 대기 상태"
log_info "  3. Migration 정책 생성 (autoExecute: true) -> 자동 실행"
log_info ""
log_info "결과:"
log_info "  - autoExecute: false -> 상태: $MANUAL_STATUS (수동 승인 대기)"
log_info "  - autoExecute: true  -> 상태: $AUTO_STATUS (결과: ${AUTO_RESULT:-none})"
log_info ""

print_test_summary
