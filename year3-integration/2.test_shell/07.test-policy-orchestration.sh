#!/usr/bin/env bash
#
# Test 07: Policy-Based Orchestration Test
# Tests the complete policy-based orchestration flow:
# Forecaster -> Policy Generator -> Policy Engine -> Operators
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "=========================================="
echo "  Policy-Based Orchestration Test"
echo "=========================================="
echo ""

# ============================================
# Prerequisites Check
# ============================================
log_info "=== Checking Prerequisites ==="

# Check OrchestrationPolicy CRD
if ! kubectl get crd orchestrationpolicies.apollo.keti.re.kr &>/dev/null; then
    log_error "OrchestrationPolicy CRD not found. Install the Orchestration Policy Engine first."
    exit 1
fi
run_test "OrchestrationPolicy CRD" "true"

# Check Policy Engine
if ! kubectl get deployment orchestration-policy-engine -n apollo &>/dev/null; then
    log_error "Orchestration Policy Engine not deployed."
    exit 1
fi
run_test "Policy Engine Running" "kubectl get deployment orchestration-policy-engine -n apollo -o jsonpath='{.status.readyReplicas}' | grep -qE '^[1-9]'"

# Check Orchestrator (optional but recommended)
if kubectl get deployment ai-storage-orchestrator -n kube-system &>/dev/null; then
    run_test "Orchestrator Running" "kubectl get deployment ai-storage-orchestrator -n kube-system -o jsonpath='{.status.readyReplicas}' | grep -qE '^[1-9]'"
    ORCHESTRATOR_AVAILABLE=true
else
    log_warn "AI Storage Orchestrator not deployed. Policy execution may be limited."
    ORCHESTRATOR_AVAILABLE=false
fi

# ============================================
# Test 1: Migration Policy
# ============================================
log_info ""
log_info "=== Test 1: Migration Policy ==="

cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: apollo.keti.re.kr/v1alpha1
kind: OrchestrationPolicy
metadata:
  name: test-migration-policy
  namespace: apollo
spec:
  policyType: migration
  priority: 100
  autoExecute: false
  targetWorkload:
    name: test-workload
    namespace: default
    kind: Deployment
  conditions:
    triggers:
    - type: threshold
      metric: memory_pressure
      threshold: "85"
  actions:
    migration:
      sourceNode: worker-1
      targetNode: worker-2
      preservePV: true
      timeout: 600
EOF

run_test "Migration Policy Created" "kubectl get orchestrationpolicy test-migration-policy -n apollo &>/dev/null"

sleep 3
MIGRATION_STATUS=$(kubectl get orchestrationpolicy test-migration-policy -n apollo -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
log_info "Migration policy status: ${MIGRATION_STATUS:-Pending}"

# ============================================
# Test 2: Scaling Policy
# ============================================
log_info ""
log_info "=== Test 2: Scaling Policy ==="

cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: apollo.keti.re.kr/v1alpha1
kind: OrchestrationPolicy
metadata:
  name: test-scaling-policy
  namespace: apollo
spec:
  policyType: scaling
  priority: 90
  autoExecute: false
  targetWorkload:
    name: test-deployment
    namespace: default
    kind: Deployment
  conditions:
    triggers:
    - type: threshold
      metric: cpu_usage
      threshold: "80"
    - type: threshold
      metric: request_rate
      threshold: "1000"
  actions:
    scaling:
      minReplicas: 2
      maxReplicas: 10
      targetCPU: 70
      targetMemory: 80
EOF

run_test "Scaling Policy Created" "kubectl get orchestrationpolicy test-scaling-policy -n apollo &>/dev/null"

sleep 3
SCALING_STATUS=$(kubectl get orchestrationpolicy test-scaling-policy -n apollo -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
log_info "Scaling policy status: ${SCALING_STATUS:-Pending}"

# ============================================
# Test 3: Caching Policy
# ============================================
log_info ""
log_info "=== Test 3: Caching Policy ==="

cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: apollo.keti.re.kr/v1alpha1
kind: OrchestrationPolicy
metadata:
  name: test-caching-policy
  namespace: apollo
spec:
  policyType: caching
  priority: 80
  autoExecute: false
  targetWorkload:
    name: data-processor
    namespace: default
    kind: StatefulSet
  conditions:
    triggers:
    - type: threshold
      metric: io_latency
      threshold: "100ms"
  actions:
    caching:
      sourcePVC: data-volume
      sourceNamespace: default
      targetTier: nvme
      cacheSize: "10Gi"
EOF

run_test "Caching Policy Created" "kubectl get orchestrationpolicy test-caching-policy -n apollo &>/dev/null"

sleep 3
CACHING_STATUS=$(kubectl get orchestrationpolicy test-caching-policy -n apollo -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
log_info "Caching policy status: ${CACHING_STATUS:-Pending}"

# ============================================
# Test 4: Loadbalance Policy
# ============================================
log_info ""
log_info "=== Test 4: Loadbalance Policy ==="

cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: apollo.keti.re.kr/v1alpha1
kind: OrchestrationPolicy
metadata:
  name: test-loadbalance-policy
  namespace: apollo
spec:
  policyType: loadbalance
  priority: 70
  autoExecute: false
  targetWorkload:
    name: api-service
    namespace: default
    kind: Deployment
  conditions:
    triggers:
    - type: threshold
      metric: request_imbalance
      threshold: "30"
  actions:
    loadbalance:
      targetNode: worker-1
      strategy: round-robin
      weight: 100
EOF

run_test "Loadbalance Policy Created" "kubectl get orchestrationpolicy test-loadbalance-policy -n apollo &>/dev/null"

sleep 3
LB_STATUS=$(kubectl get orchestrationpolicy test-loadbalance-policy -n apollo -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
log_info "Loadbalance policy status: ${LB_STATUS:-Pending}"

# ============================================
# Test 5: Provisioning Policy
# ============================================
log_info ""
log_info "=== Test 5: Provisioning Policy ==="

cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: apollo.keti.re.kr/v1alpha1
kind: OrchestrationPolicy
metadata:
  name: test-provisioning-policy
  namespace: apollo
spec:
  policyType: provisioning
  priority: 60
  autoExecute: false
  targetWorkload:
    name: ml-training-job
    namespace: default
    kind: Job
  conditions:
    triggers:
    - type: prediction
      metric: storage_usage
      threshold: "90"
  actions:
    provisioning:
      storageSize: "100Gi"
      storageClass: "fast-nvme"
      accessMode: "ReadWriteOnce"
EOF

run_test "Provisioning Policy Created" "kubectl get orchestrationpolicy test-provisioning-policy -n apollo &>/dev/null"

sleep 3
PROV_STATUS=$(kubectl get orchestrationpolicy test-provisioning-policy -n apollo -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
log_info "Provisioning policy status: ${PROV_STATUS:-Pending}"

# ============================================
# Test 6: Preemption Policy
# ============================================
log_info ""
log_info "=== Test 6: Preemption Policy ==="

cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: apollo.keti.re.kr/v1alpha1
kind: OrchestrationPolicy
metadata:
  name: test-preemption-policy
  namespace: apollo
spec:
  policyType: preemption
  priority: 95
  autoExecute: false
  targetWorkload:
    name: high-priority-job
    namespace: default
    kind: Job
  conditions:
    triggers:
    - type: resource_contention
      metric: gpu_availability
      threshold: "0"
  actions:
    preemption:
      priority: 1000
      reason: "High priority AI training job"
      graceperiod: 30
EOF

run_test "Preemption Policy Created" "kubectl get orchestrationpolicy test-preemption-policy -n apollo &>/dev/null"

sleep 3
PREEMPT_STATUS=$(kubectl get orchestrationpolicy test-preemption-policy -n apollo -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
log_info "Preemption policy status: ${PREEMPT_STATUS:-Pending}"

# ============================================
# Test 7: Auto-Execute Policy
# ============================================
log_info ""
log_info "=== Test 7: Auto-Execute Policy ==="

if [ "$ORCHESTRATOR_AVAILABLE" = true ]; then
    cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: apollo.keti.re.kr/v1alpha1
kind: OrchestrationPolicy
metadata:
  name: test-auto-execute-policy
  namespace: apollo
spec:
  policyType: caching
  priority: 85
  autoExecute: true
  targetWorkload:
    name: auto-test-workload
    namespace: default
    kind: Deployment
  conditions:
    triggers:
    - type: threshold
      metric: disk_io
      threshold: "1000"
  actions:
    caching:
      sourcePVC: auto-test-pvc
      sourceNamespace: default
      targetTier: ssd
      cacheSize: "5Gi"
EOF

    run_test "Auto-Execute Policy Created" "kubectl get orchestrationpolicy test-auto-execute-policy -n apollo &>/dev/null"

    log_info "Waiting for auto-execution..."
    sleep 10

    AUTO_STATUS=$(kubectl get orchestrationpolicy test-auto-execute-policy -n apollo -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    AUTO_RESULT=$(kubectl get orchestrationpolicy test-auto-execute-policy -n apollo -o jsonpath='{.status.result}' 2>/dev/null || echo "")
    log_info "Auto-execute policy status: ${AUTO_STATUS:-Unknown}"
    log_info "Auto-execute result: ${AUTO_RESULT:-None}"

    # Check if it was executed
    if [ "$AUTO_STATUS" == "Executing" ] || [ "$AUTO_STATUS" == "Completed" ]; then
        run_test "Auto-Execute Triggered" "true"
    else
        log_info "Policy may be waiting for conditions or orchestrator response"
    fi
else
    log_info "Skipping auto-execute test (Orchestrator not available)"
fi

# ============================================
# Policy List Summary
# ============================================
log_info ""
log_info "=== Policy Summary ==="
echo ""
kubectl get orchestrationpolicies -n apollo -o wide 2>/dev/null || echo "No policies found"

# ============================================
# Cleanup
# ============================================
log_info ""
log_info "=== Cleanup ==="

log_info "Deleting test policies..."
kubectl delete orchestrationpolicy test-migration-policy -n apollo --ignore-not-found >/dev/null
kubectl delete orchestrationpolicy test-scaling-policy -n apollo --ignore-not-found >/dev/null
kubectl delete orchestrationpolicy test-caching-policy -n apollo --ignore-not-found >/dev/null
kubectl delete orchestrationpolicy test-loadbalance-policy -n apollo --ignore-not-found >/dev/null
kubectl delete orchestrationpolicy test-provisioning-policy -n apollo --ignore-not-found >/dev/null
kubectl delete orchestrationpolicy test-preemption-policy -n apollo --ignore-not-found >/dev/null
kubectl delete orchestrationpolicy test-auto-execute-policy -n apollo --ignore-not-found >/dev/null

log_info "Cleanup complete."

# Print summary
echo ""
print_test_summary
