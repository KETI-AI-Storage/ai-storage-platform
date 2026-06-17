#!/usr/bin/env bash
#
# Orchestration Policy Engine - All 6 Policy Types Test
# 6가지 정책 타입 모두 테스트
#
# Policy Types:
# 1. migration - 티어 마이그레이션
# 2. scaling - 오토스케일링
# 3. provisioning - 사전 프로비저닝
# 4. caching - 글로벌 캐싱
# 5. loadbalance - 로드밸런싱
# 6. preemption - 선점
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

NAMESPACE="apollo"
TEST_NAMESPACE="default"

print_header "All 6 Policy Types Test"
log_info "6가지 정책 타입을 모두 테스트합니다."
log_info "각 정책은 autoExecute: true로 생성되어 자동 실행됩니다."
echo ""

# ============================================
# Prerequisites
# ============================================
log_step "1. Prerequisites Check"

run_test "Policy Engine running" "check_deployment_running $NAMESPACE orchestration-policy-engine"
run_test "CRD exists" "kubectl get crd orchestrationpolicies.apollo.keti.re.kr &>/dev/null"

# Check orchestrator
ORCHESTRATOR_AVAILABLE=false
if kubectl get deployment ai-storage-orchestrator -n kube-system &>/dev/null; then
    ORCH_READY=$(kubectl get deployment ai-storage-orchestrator -n kube-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [ "${ORCH_READY:-0}" -gt 0 ]; then
        ORCHESTRATOR_AVAILABLE=true
        run_test "Orchestrator running" "true"
    fi
fi

if [ "$ORCHESTRATOR_AVAILABLE" != "true" ]; then
    log_warn "Orchestrator not available - policies will be created but execution may fail"
fi

# ============================================
# Policy 1: Migration
# ============================================
log_step "2. Policy Type: Migration (마이그레이션)"

log_info "Creating migration policy..."
cat <<EOF | kubectl apply -f -
apiVersion: apollo.keti.re.kr/v1alpha1
kind: OrchestrationPolicy
metadata:
  name: test-policy-migration
  namespace: $NAMESPACE
  labels:
    test: all-policies
spec:
  policyType: migration
  priority: 100
  autoExecute: true
  targetWorkload:
    name: test-workload
    namespace: $TEST_NAMESPACE
    kind: Deployment
  conditions:
    triggers:
    - type: threshold
      metric: node_memory_pressure
      threshold: "80"
  actions:
    migration:
      sourceNode: worker-1
      targetNode: worker-2
      preservePV: true
      timeout: 600
EOF

sleep 2
MIGRATION_STATUS=$(kubectl get orchestrationpolicy test-policy-migration -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
MIGRATION_RESULT=$(kubectl get orchestrationpolicy test-policy-migration -n $NAMESPACE -o jsonpath='{.status.result}' 2>/dev/null || echo "")
log_info "Migration: status=$MIGRATION_STATUS, result=${MIGRATION_RESULT:-none}"

# ============================================
# Policy 2: Scaling
# ============================================
log_step "3. Policy Type: Scaling (오토스케일링)"

log_info "Creating scaling policy..."
cat <<EOF | kubectl apply -f -
apiVersion: apollo.keti.re.kr/v1alpha1
kind: OrchestrationPolicy
metadata:
  name: test-policy-scaling
  namespace: $NAMESPACE
  labels:
    test: all-policies
spec:
  policyType: scaling
  priority: 95
  autoExecute: true
  targetWorkload:
    name: test-app
    namespace: $TEST_NAMESPACE
    kind: Deployment
  conditions:
    triggers:
    - type: threshold
      metric: cpu_usage
      threshold: "75"
    - type: threshold
      metric: memory_usage
      threshold: "80"
  actions:
    scaling:
      minReplicas: 2
      maxReplicas: 10
      targetCPU: 70
      targetMemory: 75
EOF

sleep 2
SCALING_STATUS=$(kubectl get orchestrationpolicy test-policy-scaling -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
SCALING_RESULT=$(kubectl get orchestrationpolicy test-policy-scaling -n $NAMESPACE -o jsonpath='{.status.result}' 2>/dev/null || echo "")
log_info "Scaling: status=$SCALING_STATUS, result=${SCALING_RESULT:-none}"

# ============================================
# Policy 3: Provisioning
# ============================================
log_step "4. Policy Type: Provisioning (사전 프로비저닝)"

log_info "Creating provisioning policy..."
cat <<EOF | kubectl apply -f -
apiVersion: apollo.keti.re.kr/v1alpha1
kind: OrchestrationPolicy
metadata:
  name: test-policy-provisioning
  namespace: $NAMESPACE
  labels:
    test: all-policies
spec:
  policyType: provisioning
  priority: 90
  autoExecute: true
  targetWorkload:
    name: ml-training-job
    namespace: $TEST_NAMESPACE
    kind: Job
  conditions:
    triggers:
    - type: prediction
      metric: storage_usage
      threshold: "85"
  actions:
    provisioning:
      storageSize: "100Gi"
      storageClass: "fast-nvme"
      accessMode: "ReadWriteOnce"
EOF

sleep 2
PROVISIONING_STATUS=$(kubectl get orchestrationpolicy test-policy-provisioning -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
PROVISIONING_RESULT=$(kubectl get orchestrationpolicy test-policy-provisioning -n $NAMESPACE -o jsonpath='{.status.result}' 2>/dev/null || echo "")
log_info "Provisioning: status=$PROVISIONING_STATUS, result=${PROVISIONING_RESULT:-none}"

# ============================================
# Policy 4: Caching
# ============================================
log_step "5. Policy Type: Caching (글로벌 캐싱)"

log_info "Creating caching policy..."
cat <<EOF | kubectl apply -f -
apiVersion: apollo.keti.re.kr/v1alpha1
kind: OrchestrationPolicy
metadata:
  name: test-policy-caching
  namespace: $NAMESPACE
  labels:
    test: all-policies
spec:
  policyType: caching
  priority: 85
  autoExecute: true
  targetWorkload:
    name: data-processor
    namespace: $TEST_NAMESPACE
    kind: StatefulSet
  conditions:
    triggers:
    - type: threshold
      metric: io_latency
      threshold: "100"
    - type: threshold
      metric: cache_miss_rate
      threshold: "30"
  actions:
    caching:
      sourcePVC: data-volume
      sourceNamespace: $TEST_NAMESPACE
      targetTier: nvme
      cacheSize: "50Gi"
EOF

sleep 2
CACHING_STATUS=$(kubectl get orchestrationpolicy test-policy-caching -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
CACHING_RESULT=$(kubectl get orchestrationpolicy test-policy-caching -n $NAMESPACE -o jsonpath='{.status.result}' 2>/dev/null || echo "")
log_info "Caching: status=$CACHING_STATUS, result=${CACHING_RESULT:-none}"

# ============================================
# Policy 5: Loadbalance
# ============================================
log_step "6. Policy Type: Loadbalance (로드밸런싱)"

log_info "Creating loadbalance policy..."
cat <<EOF | kubectl apply -f -
apiVersion: apollo.keti.re.kr/v1alpha1
kind: OrchestrationPolicy
metadata:
  name: test-policy-loadbalance
  namespace: $NAMESPACE
  labels:
    test: all-policies
spec:
  policyType: loadbalance
  priority: 80
  autoExecute: true
  targetWorkload:
    name: api-gateway
    namespace: $TEST_NAMESPACE
    kind: Deployment
  conditions:
    triggers:
    - type: threshold
      metric: request_imbalance
      threshold: "25"
    - type: threshold
      metric: node_cpu_variance
      threshold: "30"
  actions:
    loadbalance:
      targetNode: worker-1
      strategy: least-connections
      weight: 100
EOF

sleep 2
LOADBALANCE_STATUS=$(kubectl get orchestrationpolicy test-policy-loadbalance -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
LOADBALANCE_RESULT=$(kubectl get orchestrationpolicy test-policy-loadbalance -n $NAMESPACE -o jsonpath='{.status.result}' 2>/dev/null || echo "")
log_info "Loadbalance: status=$LOADBALANCE_STATUS, result=${LOADBALANCE_RESULT:-none}"

# ============================================
# Policy 6: Preemption
# ============================================
log_step "7. Policy Type: Preemption (선점)"

log_info "Creating preemption policy..."
cat <<EOF | kubectl apply -f -
apiVersion: apollo.keti.re.kr/v1alpha1
kind: OrchestrationPolicy
metadata:
  name: test-policy-preemption
  namespace: $NAMESPACE
  labels:
    test: all-policies
spec:
  policyType: preemption
  priority: 99
  autoExecute: true
  targetWorkload:
    name: high-priority-training
    namespace: $TEST_NAMESPACE
    kind: Job
  conditions:
    triggers:
    - type: resource_contention
      metric: gpu_availability
      threshold: "0"
    - type: priority
      metric: job_priority
      threshold: "1000"
  actions:
    preemption:
      priority: 1000
      reason: "High priority AI training job requires GPU resources"
      graceperiod: 30
EOF

sleep 2
PREEMPTION_STATUS=$(kubectl get orchestrationpolicy test-policy-preemption -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
PREEMPTION_RESULT=$(kubectl get orchestrationpolicy test-policy-preemption -n $NAMESPACE -o jsonpath='{.status.result}' 2>/dev/null || echo "")
log_info "Preemption: status=$PREEMPTION_STATUS, result=${PREEMPTION_RESULT:-none}"

# ============================================
# Wait for processing
# ============================================
log_step "8. Waiting for Policy Processing"

log_info "Waiting 15 seconds for all policies to be processed..."
sleep 15

# ============================================
# Results Summary
# ============================================
log_step "9. Results Summary"

echo ""
log_info "All Policies Status:"
echo ""
kubectl get orchestrationpolicies -n $NAMESPACE -l test=all-policies -o custom-columns=\
'NAME:.metadata.name,TYPE:.spec.policyType,PRIORITY:.spec.priority,AUTO:.spec.autoExecute,STATUS:.status.phase,RESULT:.status.result' 2>/dev/null

echo ""

# Count statuses
TOTAL=6
EXECUTED=0
FAILED=0
PENDING=0

for policy in migration scaling provisioning caching loadbalance preemption; do
    status=$(kubectl get orchestrationpolicy test-policy-$policy -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    case $status in
        Executing|Completed) EXECUTED=$((EXECUTED + 1)) ;;
        Failed) FAILED=$((FAILED + 1)) ;;
        *) PENDING=$((PENDING + 1)) ;;
    esac
done

log_info "Summary: Total=$TOTAL, Executed=$EXECUTED, Failed=$FAILED, Pending=$PENDING"

# Test results
run_test "All policies created" "[ $(kubectl get orchestrationpolicies -n $NAMESPACE -l test=all-policies --no-headers 2>/dev/null | wc -l) -eq 6 ]"

if [ "$ORCHESTRATOR_AVAILABLE" == "true" ]; then
    run_test "Policies attempted execution" "[ $EXECUTED -gt 0 ] || [ $FAILED -gt 0 ]"
fi

# ============================================
# Controller Logs
# ============================================
log_step "10. Controller Logs"

log_info "Recent controller activity:"
kubectl logs -n $NAMESPACE -l control-plane=controller-manager --tail=40 2>/dev/null | grep -E "test-policy|Reconciling|Executing|operator|Starting" | tail -20 || log_info "No matching entries"

# ============================================
# Cleanup
# ============================================
log_step "11. Cleanup"

log_info "Deleting all test policies..."
kubectl delete orchestrationpolicies -n $NAMESPACE -l test=all-policies --ignore-not-found >/dev/null

log_info "Cleanup completed"

# ============================================
# Final Summary
# ============================================
echo ""
log_info "=========================================="
log_info "      ALL POLICIES TEST SUMMARY"
log_info "=========================================="
echo ""
printf "%-15s %-12s %s\n" "Policy Type" "Status" "Result"
echo "-------------------------------------------"
printf "%-15s %-12s %s\n" "migration" "$MIGRATION_STATUS" "${MIGRATION_RESULT:-none}"
printf "%-15s %-12s %s\n" "scaling" "$SCALING_STATUS" "${SCALING_RESULT:-none}"
printf "%-15s %-12s %s\n" "provisioning" "$PROVISIONING_STATUS" "${PROVISIONING_RESULT:-none}"
printf "%-15s %-12s %s\n" "caching" "$CACHING_STATUS" "${CACHING_RESULT:-none}"
printf "%-15s %-12s %s\n" "loadbalance" "$LOADBALANCE_STATUS" "${LOADBALANCE_RESULT:-none}"
printf "%-15s %-12s %s\n" "preemption" "$PREEMPTION_STATUS" "${PREEMPTION_RESULT:-none}"
echo "-------------------------------------------"
echo ""

print_test_summary
