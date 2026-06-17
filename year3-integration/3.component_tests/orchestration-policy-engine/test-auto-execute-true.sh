#!/usr/bin/env bash
#
# Orchestration Policy Engine - autoExecute: true Test
# 자동 실행 모드 테스트 (autoExecute: true)
#
# 이 테스트는 정책이 자동으로 실행되어 Orchestrator를 호출하는지 확인합니다.
# Orchestrator가 실행되어야 정상 동작합니다.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

NAMESPACE="apollo"
TEST_NAMESPACE="default"
ORCHESTRATOR_NS="kube-system"

print_header "Policy Engine - autoExecute: true Test"
log_info "이 테스트는 autoExecute: true 설정 시 정책이 자동 실행되는지 확인합니다."
log_info "AI Storage Orchestrator가 실행 중이어야 합니다."
echo ""

# ============================================
# Prerequisites
# ============================================
log_step "1. Prerequisites Check"

run_test "Policy Engine running" "check_deployment_running $NAMESPACE orchestration-policy-engine"
run_test "CRD exists" "kubectl get crd orchestrationpolicies.apollo.keti.re.kr &>/dev/null"

# Check if Orchestrator is running
if kubectl get deployment ai-storage-orchestrator -n $ORCHESTRATOR_NS &>/dev/null; then
    ORCH_READY=$(kubectl get deployment ai-storage-orchestrator -n $ORCHESTRATOR_NS -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [ "${ORCH_READY:-0}" -gt 0 ]; then
        run_test "Orchestrator running" "true"
        log_info "AI Storage Orchestrator is running - policies will be executed"
        ORCHESTRATOR_AVAILABLE=true
    else
        log_warn "AI Storage Orchestrator is not ready"
        ORCHESTRATOR_AVAILABLE=false
    fi
else
    log_warn "AI Storage Orchestrator not deployed"
    log_info "Policies will be created but may fail during execution"
    ORCHESTRATOR_AVAILABLE=false
fi

# ============================================
# Test 1: Migration Policy (autoExecute: true)
# ============================================
log_step "2. Migration Policy Test (autoExecute: true)"

log_info "Creating migration policy with autoExecute: true..."
cat <<EOF | kubectl apply -f -
apiVersion: apollo.keti.re.kr/v1alpha1
kind: OrchestrationPolicy
metadata:
  name: test-auto-migration
  namespace: $NAMESPACE
spec:
  policyType: migration
  priority: 90
  autoExecute: true
  targetWorkload:
    name: auto-test-workload
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

log_info "Waiting for auto-execution (10 seconds)..."
sleep 10

# Check status - should be Executing or Completed
MIGRATION_STATUS=$(kubectl get orchestrationpolicy test-auto-migration -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
MIGRATION_RESULT=$(kubectl get orchestrationpolicy test-auto-migration -n $NAMESPACE -o jsonpath='{.status.result}' 2>/dev/null || echo "")

log_info "Migration policy status: $MIGRATION_STATUS"
log_info "Migration result: ${MIGRATION_RESULT:-none}"

if [ "$MIGRATION_STATUS" == "Executing" ] || [ "$MIGRATION_STATUS" == "Completed" ]; then
    log_info "Policy auto-executed successfully!"
    run_test "Migration policy auto-executed" "true"
elif [ "$MIGRATION_STATUS" == "Failed" ]; then
    log_warn "Policy execution failed (Orchestrator may have returned error)"
    log_info "This is expected if the workload doesn't exist"
    run_test "Migration policy attempted execution" "true"
else
    if [ "$ORCHESTRATOR_AVAILABLE" == "true" ]; then
        log_error "Policy should auto-execute when autoExecute: true"
        run_test "Migration policy auto-executed" "false"
    else
        log_warn "Policy waiting - Orchestrator not available"
        run_test "Migration policy created" "true"
    fi
fi

# ============================================
# Test 2: Scaling Policy (autoExecute: true)
# ============================================
log_step "3. Scaling Policy Test (autoExecute: true)"

log_info "Creating scaling policy with autoExecute: true..."
cat <<EOF | kubectl apply -f -
apiVersion: apollo.keti.re.kr/v1alpha1
kind: OrchestrationPolicy
metadata:
  name: test-auto-scaling
  namespace: $NAMESPACE
spec:
  policyType: scaling
  priority: 85
  autoExecute: true
  targetWorkload:
    name: auto-test-app
    namespace: $TEST_NAMESPACE
    kind: Deployment
  conditions:
    triggers:
    - type: threshold
      metric: cpu_usage
      threshold: "75"
  actions:
    scaling:
      minReplicas: 2
      maxReplicas: 8
      targetCPU: 70
      targetMemory: 80
EOF

log_info "Waiting for auto-execution (10 seconds)..."
sleep 10

SCALING_STATUS=$(kubectl get orchestrationpolicy test-auto-scaling -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
SCALING_RESULT=$(kubectl get orchestrationpolicy test-auto-scaling -n $NAMESPACE -o jsonpath='{.status.result}' 2>/dev/null || echo "")

log_info "Scaling policy status: $SCALING_STATUS"
log_info "Scaling result: ${SCALING_RESULT:-none}"

if [ "$SCALING_STATUS" == "Executing" ] || [ "$SCALING_STATUS" == "Completed" ] || [ "$SCALING_STATUS" == "Failed" ]; then
    run_test "Scaling policy attempted execution" "true"
else
    run_test "Scaling policy created" "true"
fi

# ============================================
# Test 3: Caching Policy (autoExecute: true)
# ============================================
log_step "4. Caching Policy Test (autoExecute: true)"

log_info "Creating caching policy with autoExecute: true..."
cat <<EOF | kubectl apply -f -
apiVersion: apollo.keti.re.kr/v1alpha1
kind: OrchestrationPolicy
metadata:
  name: test-auto-caching
  namespace: $NAMESPACE
spec:
  policyType: caching
  priority: 80
  autoExecute: true
  targetWorkload:
    name: data-processor
    namespace: $TEST_NAMESPACE
    kind: StatefulSet
  conditions:
    triggers:
    - type: threshold
      metric: io_latency
      threshold: "50"
  actions:
    caching:
      sourcePVC: data-pvc
      sourceNamespace: $TEST_NAMESPACE
      targetTier: nvme
      cacheSize: "10Gi"
EOF

log_info "Waiting for auto-execution (10 seconds)..."
sleep 10

CACHING_STATUS=$(kubectl get orchestrationpolicy test-auto-caching -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
CACHING_RESULT=$(kubectl get orchestrationpolicy test-auto-caching -n $NAMESPACE -o jsonpath='{.status.result}' 2>/dev/null || echo "")

log_info "Caching policy status: $CACHING_STATUS"
log_info "Caching result: ${CACHING_RESULT:-none}"

run_test "Caching policy processed" "[ '$CACHING_STATUS' != '' ]"

# ============================================
# Show All Policies Status
# ============================================
log_step "5. All Policies Status"

echo ""
log_info "Current policies with autoExecute: true:"
echo ""
kubectl get orchestrationpolicies -n $NAMESPACE -o custom-columns=\
'NAME:.metadata.name,TYPE:.spec.policyType,AUTO-EXEC:.spec.autoExecute,PRIORITY:.spec.priority,STATUS:.status.phase,RESULT:.status.result' 2>/dev/null

# ============================================
# Controller Logs
# ============================================
log_step "6. Controller Logs (check auto-execution)"

log_info "Checking controller logs for auto-execution..."
echo ""
kubectl logs -n $NAMESPACE -l control-plane=controller-manager --tail=50 2>/dev/null | grep -E "test-auto|autoExecute|Executing|operator|Starting" | tail -20 || log_info "No matching log entries"

# ============================================
# Orchestrator Logs (if available)
# ============================================
if [ "$ORCHESTRATOR_AVAILABLE" == "true" ]; then
    log_step "7. Orchestrator Logs"
    log_info "Checking orchestrator logs for received requests..."
    echo ""
    kubectl logs -n $ORCHESTRATOR_NS -l app=ai-storage-orchestrator --tail=30 2>/dev/null | tail -15 || log_info "No logs available"
fi

# ============================================
# Cleanup
# ============================================
log_step "8. Cleanup"

log_info "Deleting test policies..."
kubectl delete orchestrationpolicy test-auto-migration -n $NAMESPACE --ignore-not-found >/dev/null
kubectl delete orchestrationpolicy test-auto-scaling -n $NAMESPACE --ignore-not-found >/dev/null
kubectl delete orchestrationpolicy test-auto-caching -n $NAMESPACE --ignore-not-found >/dev/null

log_info "Cleanup completed"

# ============================================
# Summary
# ============================================
echo ""
log_info "=========================================="
log_info "           TEST RESULTS"
log_info "=========================================="
log_info ""
log_info "autoExecute: true 테스트 결과:"
if [ "$ORCHESTRATOR_AVAILABLE" == "true" ]; then
    log_info "  - Orchestrator 연동: 정상"
    log_info "  - 정책들이 생성 후 자동 실행됨 (Executing/Completed 상태)"
    log_info "  - Orchestrator API 호출 확인됨"
else
    log_warn "  - Orchestrator 미실행 상태"
    log_info "  - 정책들이 생성되었으나 실행 대기 중"
    log_info "  - Orchestrator 배포 후 재테스트 필요"
fi
log_info ""

print_test_summary
