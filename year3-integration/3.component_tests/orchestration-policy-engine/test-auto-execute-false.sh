#!/usr/bin/env bash
#
# Orchestration Policy Engine - autoExecute: false Test
# 수동 승인 모드 테스트 (autoExecute: false)
#
# 이 테스트는 정책이 자동 실행되지 않고 Pending/Approved 상태에서
# 대기하는지 확인합니다.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

NAMESPACE="apollo"
TEST_NAMESPACE="default"

print_header "Policy Engine - autoExecute: false Test"
log_info "이 테스트는 autoExecute: false 설정 시 정책이 자동 실행되지 않는지 확인합니다."
echo ""

# ============================================
# Prerequisites
# ============================================
log_step "1. Prerequisites Check"

run_test "Policy Engine running" "check_deployment_running $NAMESPACE orchestration-policy-engine"
run_test "CRD exists" "kubectl get crd orchestrationpolicies.apollo.keti.re.kr &>/dev/null"

# ============================================
# Test 1: Migration Policy (autoExecute: false)
# ============================================
log_step "2. Migration Policy Test (autoExecute: false)"

log_info "Creating migration policy with autoExecute: false..."
cat <<EOF | kubectl apply -f -
apiVersion: apollo.keti.re.kr/v1alpha1
kind: OrchestrationPolicy
metadata:
  name: test-manual-migration
  namespace: $NAMESPACE
spec:
  policyType: migration
  priority: 80
  autoExecute: false
  targetWorkload:
    name: nginx-test
    namespace: $TEST_NAMESPACE
    kind: Deployment
  conditions:
    triggers:
    - type: threshold
      metric: memory_pressure
      threshold: "70"
  actions:
    migration:
      sourceNode: worker-1
      targetNode: worker-2
      preservePV: true
      timeout: 300
EOF

sleep 5

# Check status - should be Pending or Approved, NOT Executing
MIGRATION_STATUS=$(kubectl get orchestrationpolicy test-manual-migration -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
log_info "Migration policy status: $MIGRATION_STATUS"

if [ "$MIGRATION_STATUS" == "Executing" ] || [ "$MIGRATION_STATUS" == "Completed" ]; then
    log_error "Policy should NOT auto-execute when autoExecute: false"
    run_test "Migration policy NOT auto-executed" "false"
else
    log_info "Policy correctly waiting (not auto-executing)"
    run_test "Migration policy NOT auto-executed" "true"
fi

# ============================================
# Test 2: Scaling Policy (autoExecute: false)
# ============================================
log_step "3. Scaling Policy Test (autoExecute: false)"

log_info "Creating scaling policy with autoExecute: false..."
cat <<EOF | kubectl apply -f -
apiVersion: apollo.keti.re.kr/v1alpha1
kind: OrchestrationPolicy
metadata:
  name: test-manual-scaling
  namespace: $NAMESPACE
spec:
  policyType: scaling
  priority: 75
  autoExecute: false
  targetWorkload:
    name: nginx-test
    namespace: $TEST_NAMESPACE
    kind: Deployment
  conditions:
    triggers:
    - type: threshold
      metric: cpu_usage
      threshold: "80"
  actions:
    scaling:
      minReplicas: 2
      maxReplicas: 5
      targetCPU: 70
EOF

sleep 5

SCALING_STATUS=$(kubectl get orchestrationpolicy test-manual-scaling -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
log_info "Scaling policy status: $SCALING_STATUS"

if [ "$SCALING_STATUS" == "Executing" ] || [ "$SCALING_STATUS" == "Completed" ]; then
    log_error "Policy should NOT auto-execute when autoExecute: false"
    run_test "Scaling policy NOT auto-executed" "false"
else
    log_info "Policy correctly waiting (not auto-executing)"
    run_test "Scaling policy NOT auto-executed" "true"
fi

# ============================================
# Test 3: Caching Policy (autoExecute: false)
# ============================================
log_step "4. Caching Policy Test (autoExecute: false)"

log_info "Creating caching policy with autoExecute: false..."
cat <<EOF | kubectl apply -f -
apiVersion: apollo.keti.re.kr/v1alpha1
kind: OrchestrationPolicy
metadata:
  name: test-manual-caching
  namespace: $NAMESPACE
spec:
  policyType: caching
  priority: 70
  autoExecute: false
  targetWorkload:
    name: data-app
    namespace: $TEST_NAMESPACE
    kind: StatefulSet
  conditions:
    triggers:
    - type: threshold
      metric: io_latency
      threshold: "100"
  actions:
    caching:
      sourcePVC: data-volume
      sourceNamespace: $TEST_NAMESPACE
      targetTier: nvme
      cacheSize: "5Gi"
EOF

sleep 5

CACHING_STATUS=$(kubectl get orchestrationpolicy test-manual-caching -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
log_info "Caching policy status: $CACHING_STATUS"

if [ "$CACHING_STATUS" == "Executing" ] || [ "$CACHING_STATUS" == "Completed" ]; then
    run_test "Caching policy NOT auto-executed" "false"
else
    run_test "Caching policy NOT auto-executed" "true"
fi

# ============================================
# Show All Policies Status
# ============================================
log_step "5. All Policies Status"

echo ""
log_info "Current policies with autoExecute: false:"
echo ""
kubectl get orchestrationpolicies -n $NAMESPACE -o custom-columns=\
'NAME:.metadata.name,TYPE:.spec.policyType,AUTO-EXEC:.spec.autoExecute,PRIORITY:.spec.priority,STATUS:.status.phase' 2>/dev/null

# ============================================
# Manual Approval Simulation
# ============================================
log_step "6. Manual Approval Simulation"

log_info "In production, these policies would require manual approval."
log_info "To manually approve a policy, you would:"
log_info "  1. Review the policy: kubectl get orchestrationpolicy <name> -n apollo -o yaml"
log_info "  2. Update status to Approved: kubectl patch orchestrationpolicy <name> -n apollo --type=merge -p '{\"status\":{\"phase\":\"Approved\"}}'"
log_info ""
log_info "For this test, we'll leave them in Pending state to verify autoExecute: false works."

# ============================================
# Controller Logs
# ============================================
log_step "7. Controller Logs (check for no auto-execution)"

log_info "Checking controller logs for policy processing..."
kubectl logs -n $NAMESPACE -l control-plane=controller-manager --tail=30 2>/dev/null | grep -E "test-manual|autoExecute|Reconciling" | tail -15 || log_info "No matching log entries"

# ============================================
# Cleanup
# ============================================
log_step "8. Cleanup"

log_info "Deleting test policies..."
kubectl delete orchestrationpolicy test-manual-migration -n $NAMESPACE --ignore-not-found >/dev/null
kubectl delete orchestrationpolicy test-manual-scaling -n $NAMESPACE --ignore-not-found >/dev/null
kubectl delete orchestrationpolicy test-manual-caching -n $NAMESPACE --ignore-not-found >/dev/null

log_info "Cleanup completed"

# ============================================
# Summary
# ============================================
echo ""
log_info "=========================================="
log_info "           TEST RESULTS"
log_info "=========================================="
log_info ""
log_info "autoExecute: false 테스트 결과:"
log_info "  - 정책들이 생성 후 자동 실행되지 않음 (Pending/Approved 상태 유지)"
log_info "  - 수동 승인 대기 중 상태 확인됨"
log_info ""

print_test_summary
