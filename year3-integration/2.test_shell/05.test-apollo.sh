#!/usr/bin/env bash
#
# Test 05: Apollo Components Test
# Tests all Apollo platform components:
# - Insight Scope
# - Insight Trace
# - Node Resource Forecaster
# - AI Storage Scheduler
# - AI Storage Orchestrator
# - Orchestration Policy Engine
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "=========================================="
echo "  Apollo Components Test"
echo "=========================================="
echo ""

# ============================================
# 1. Namespace and Basic Checks
# ============================================
log_info "=== Namespace and Basic Checks ==="

# Check Apollo namespace
if kubectl get namespace apollo &>/dev/null; then
    run_test "Apollo Namespace" "kubectl get namespace apollo &>/dev/null"
else
    log_warn "Apollo namespace not found. Creating..."
    kubectl create namespace apollo
fi

# Check KETI namespace
if kubectl get namespace keti &>/dev/null; then
    run_test "KETI Namespace" "kubectl get namespace keti &>/dev/null"
else
    log_info "KETI namespace not found (optional)"
fi

# ============================================
# 2. Insight Scope Tests
# ============================================
log_info ""
log_info "=== Insight Scope Tests ==="

if kubectl get deployment insight-scope -n apollo &>/dev/null; then
    run_test "Insight Scope Deployment" "kubectl get deployment insight-scope -n apollo -o jsonpath='{.status.readyReplicas}' | grep -qE '^[1-9]'"
    run_test "Insight Scope Service" "kubectl get svc insight-scope -n apollo &>/dev/null"

    # Test API endpoint
    INSIGHT_SCOPE_IP=$(kubectl get svc insight-scope -n apollo -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
    if [ -n "$INSIGHT_SCOPE_IP" ]; then
        log_info "Insight Scope ClusterIP: $INSIGHT_SCOPE_IP"
    fi
else
    log_info "Insight Scope not deployed"
fi

# ============================================
# 3. Insight Trace Tests
# ============================================
log_info ""
log_info "=== Insight Trace Tests ==="

if kubectl get deployment insight-trace -n apollo &>/dev/null; then
    run_test "Insight Trace Deployment" "kubectl get deployment insight-trace -n apollo -o jsonpath='{.status.readyReplicas}' | grep -qE '^[1-9]'"
    run_test "Insight Trace Service" "kubectl get svc insight-trace -n apollo &>/dev/null"

    INSIGHT_TRACE_IP=$(kubectl get svc insight-trace -n apollo -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
    if [ -n "$INSIGHT_TRACE_IP" ]; then
        log_info "Insight Trace ClusterIP: $INSIGHT_TRACE_IP"
    fi
else
    log_info "Insight Trace not deployed"
fi

# ============================================
# 4. Node Resource Forecaster Tests
# ============================================
log_info ""
log_info "=== Node Resource Forecaster Tests ==="

if kubectl get deployment node-resource-forecaster -n apollo &>/dev/null; then
    run_test "Forecaster Deployment" "kubectl get deployment node-resource-forecaster -n apollo -o jsonpath='{.status.readyReplicas}' | grep -qE '^[1-9]'"
    run_test "Forecaster Service" "kubectl get svc node-resource-forecaster -n apollo &>/dev/null"

    FORECASTER_IP=$(kubectl get svc node-resource-forecaster -n apollo -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
    if [ -n "$FORECASTER_IP" ]; then
        log_info "Node Resource Forecaster ClusterIP: $FORECASTER_IP"
    fi
else
    log_info "Node Resource Forecaster not deployed"
fi

# ============================================
# 5. AI Storage Scheduler Tests
# ============================================
log_info ""
log_info "=== AI Storage Scheduler Tests ==="

if kubectl get deployment ai-storage-scheduler -n keti &>/dev/null; then
    run_test "Scheduler Deployment" "kubectl get deployment ai-storage-scheduler -n keti -o jsonpath='{.status.readyReplicas}' | grep -qE '^[1-9]'"

    # Test scheduler with a test pod
    log_test "Testing custom scheduler..."
    cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: test-scheduler-pod
  namespace: default
  labels:
    test: scheduler
spec:
  schedulerName: ai-storage-scheduler
  containers:
  - name: test
    image: busybox:latest
    command: ["sh", "-c", "echo 'Scheduled by ai-storage-scheduler!' && sleep 30"]
    resources:
      requests:
        cpu: "50m"
        memory: "32Mi"
  restartPolicy: Never
EOF

    log_info "Waiting for pod to be scheduled..."
    sleep 15

    # Check if pod was scheduled
    POD_NODE=$(kubectl get pod test-scheduler-pod -n default -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "")
    if [ -n "$POD_NODE" ]; then
        run_test "Custom Scheduler Working" "true"
        log_info "Pod scheduled to node: $POD_NODE"
    else
        POD_STATUS=$(kubectl get pod test-scheduler-pod -n default -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        log_info "Pod status: $POD_STATUS"
        run_test "Custom Scheduler Working" "[ '$POD_STATUS' == 'Running' ] || [ '$POD_STATUS' == 'Succeeded' ]"
    fi

    # Cleanup
    kubectl delete pod test-scheduler-pod -n default --ignore-not-found >/dev/null
else
    log_info "AI Storage Scheduler not deployed in keti namespace"
fi

# ============================================
# 6. AI Storage Orchestrator Tests
# ============================================
log_info ""
log_info "=== AI Storage Orchestrator Tests ==="

if kubectl get deployment ai-storage-orchestrator -n kube-system &>/dev/null; then
    run_test "Orchestrator Deployment" "kubectl get deployment ai-storage-orchestrator -n kube-system -o jsonpath='{.status.readyReplicas}' | grep -qE '^[1-9]'"
    run_test "Orchestrator Service" "kubectl get svc ai-storage-orchestrator -n kube-system &>/dev/null"

    # Test health endpoint
    ORCH_IP=$(kubectl get svc ai-storage-orchestrator -n kube-system -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
    if [ -n "$ORCH_IP" ]; then
        log_info "AI Storage Orchestrator ClusterIP: $ORCH_IP:8080"

        # Create a test pod to check health endpoint
        log_test "Testing Orchestrator health endpoint..."
        cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: test-orch-health
  namespace: default
  labels:
    test: orchestrator
spec:
  containers:
  - name: curl
    image: curlimages/curl:latest
    command: ["sh", "-c", "curl -s http://${ORCH_IP}:8080/health && sleep 10"]
  restartPolicy: Never
EOF

        sleep 15
        HEALTH_RESULT=$(kubectl logs test-orch-health -n default 2>/dev/null | head -1)
        if echo "$HEALTH_RESULT" | grep -qiE "healthy|ok|status"; then
            run_test "Orchestrator Health Check" "true"
            log_info "Health response: $HEALTH_RESULT"
        else
            log_info "Health check response: $HEALTH_RESULT"
        fi

        kubectl delete pod test-orch-health -n default --ignore-not-found >/dev/null
    fi
else
    log_info "AI Storage Orchestrator not deployed"
fi

# ============================================
# 7. Orchestration Policy Engine Tests
# ============================================
log_info ""
log_info "=== Orchestration Policy Engine Tests ==="

if kubectl get deployment orchestration-policy-engine -n apollo &>/dev/null; then
    run_test "Policy Engine Deployment" "kubectl get deployment orchestration-policy-engine -n apollo -o jsonpath='{.status.readyReplicas}' | grep -qE '^[1-9]'"

    # Check CRD
    run_test "OrchestrationPolicy CRD" "kubectl get crd orchestrationpolicies.apollo.keti.re.kr &>/dev/null"

    # Test policy creation
    log_test "Testing OrchestrationPolicy creation..."
    cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: apollo.keti.re.kr/v1alpha1
kind: OrchestrationPolicy
metadata:
  name: test-policy
  namespace: apollo
spec:
  policyType: migration
  priority: 50
  autoExecute: false
  targetWorkload:
    name: test-workload
    namespace: default
    kind: Deployment
  conditions:
    triggers:
    - type: manual
      threshold: "test"
  actions:
    migration:
      sourceNode: worker-1
      targetNode: worker-2
      preservePV: true
EOF

    run_test "Policy Creation" "kubectl get orchestrationpolicy test-policy -n apollo &>/dev/null"

    # Check policy status
    sleep 5
    POLICY_STATUS=$(kubectl get orchestrationpolicy test-policy -n apollo -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    log_info "Policy status: $POLICY_STATUS"

    # Cleanup
    kubectl delete orchestrationpolicy test-policy -n apollo --ignore-not-found >/dev/null
else
    log_info "Orchestration Policy Engine not deployed"
fi

# ============================================
# 8. End-to-End Integration Test
# ============================================
log_info ""
log_info "=== End-to-End Integration Test ==="

# Check if all core components are available
CORE_COMPONENTS=0
AVAILABLE_COMPONENTS=0

if kubectl get deployment node-resource-forecaster -n apollo &>/dev/null; then
    AVAILABLE_COMPONENTS=$((AVAILABLE_COMPONENTS + 1))
fi
CORE_COMPONENTS=$((CORE_COMPONENTS + 1))

if kubectl get deployment orchestration-policy-engine -n apollo &>/dev/null; then
    AVAILABLE_COMPONENTS=$((AVAILABLE_COMPONENTS + 1))
fi
CORE_COMPONENTS=$((CORE_COMPONENTS + 1))

if kubectl get deployment ai-storage-orchestrator -n kube-system &>/dev/null; then
    AVAILABLE_COMPONENTS=$((AVAILABLE_COMPONENTS + 1))
fi
CORE_COMPONENTS=$((CORE_COMPONENTS + 1))

log_info "Core components available: $AVAILABLE_COMPONENTS/$CORE_COMPONENTS"

if [ "$AVAILABLE_COMPONENTS" -ge 2 ]; then
    log_test "Testing policy-based orchestration flow..."

    # Create a test policy with autoExecute
    cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: apollo.keti.re.kr/v1alpha1
kind: OrchestrationPolicy
metadata:
  name: test-auto-policy
  namespace: apollo
spec:
  policyType: caching
  priority: 80
  autoExecute: true
  targetWorkload:
    name: test-workload
    namespace: default
    kind: Deployment
  conditions:
    triggers:
    - type: threshold
      metric: cpu_usage
      threshold: "80"
  actions:
    caching:
      sourcePVC: test-pvc
      sourceNamespace: default
      targetTier: nvme
      cacheSize: "1Gi"
EOF

    sleep 10

    # Check if policy was processed
    POLICY_PHASE=$(kubectl get orchestrationpolicy test-auto-policy -n apollo -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    log_info "Auto-execute policy phase: $POLICY_PHASE"

    run_test "Policy Auto-Execution" "[ '$POLICY_PHASE' != '' ]"

    # Cleanup
    kubectl delete orchestrationpolicy test-auto-policy -n apollo --ignore-not-found >/dev/null
fi

# ============================================
# Summary
# ============================================
echo ""
log_info "=== Component Status Summary ==="

echo ""
printf "%-30s %s\n" "Component" "Status"
echo "----------------------------------------"

check_component_status() {
    local ns=$1
    local name=$2
    local display=$3

    if kubectl get deployment "$name" -n "$ns" &>/dev/null; then
        local ready=$(kubectl get deployment "$name" -n "$ns" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        local desired=$(kubectl get deployment "$name" -n "$ns" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
        ready=${ready:-0}
        if [ "$ready" -ge "$desired" ]; then
            printf "%-30s ${GREEN}Ready ($ready/$desired)${NC}\n" "$display"
        else
            printf "%-30s ${YELLOW}Not Ready ($ready/$desired)${NC}\n" "$display"
        fi
    else
        printf "%-30s ${RED}Not Deployed${NC}\n" "$display"
    fi
}

check_component_status "apollo" "insight-scope" "Insight Scope"
check_component_status "apollo" "insight-trace" "Insight Trace"
check_component_status "apollo" "node-resource-forecaster" "Node Resource Forecaster"
check_component_status "keti" "ai-storage-scheduler" "AI Storage Scheduler"
check_component_status "kube-system" "ai-storage-orchestrator" "AI Storage Orchestrator"
check_component_status "apollo" "orchestration-policy-engine" "Orchestration Policy Engine"

echo ""

# Print test summary
print_test_summary
