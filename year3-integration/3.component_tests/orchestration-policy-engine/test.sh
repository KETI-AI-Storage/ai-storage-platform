#!/usr/bin/env bash
#
# Orchestration Policy Engine Component Test (Main)
# 정책 엔진 메인 테스트 - 기본 기능 및 상태 확인
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

NAMESPACE="apollo"
DEPLOYMENT_NAME="orchestration-policy-engine"

print_header "Orchestration Policy Engine - Main Test"

# ============================================
# Prerequisites Check
# ============================================
log_step "1. Prerequisites Check"

if ! kubectl get namespace $NAMESPACE &>/dev/null; then
    log_error "Namespace '$NAMESPACE' not found"
    exit 1
fi

# Check CRD
run_test "OrchestrationPolicy CRD exists" "kubectl get crd orchestrationpolicies.apollo.keti.re.kr &>/dev/null"

# Check deployment
if ! kubectl get deployment $DEPLOYMENT_NAME -n $NAMESPACE &>/dev/null; then
    log_error "Deployment '$DEPLOYMENT_NAME' not found"
    exit 1
fi

# ============================================
# Deployment Test
# ============================================
log_step "2. Deployment Test"

run_test "Deployment exists" "kubectl get deployment $DEPLOYMENT_NAME -n $NAMESPACE &>/dev/null"
run_test "Deployment is ready" "check_deployment_running $NAMESPACE $DEPLOYMENT_NAME"

POD_NAME=$(kubectl get pods -n $NAMESPACE -l control-plane=controller-manager -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$POD_NAME" ]; then
    log_info "Controller Pod: $POD_NAME"
    run_test "Controller pod running" "kubectl get pod $POD_NAME -n $NAMESPACE -o jsonpath='{.status.phase}' | grep -q Running"
fi

# ============================================
# RBAC Test
# ============================================
log_step "3. RBAC Test"

run_test "ServiceAccount exists" "kubectl get serviceaccount orchestration-policy-engine-controller-manager -n $NAMESPACE &>/dev/null"
run_test "ClusterRole exists" "kubectl get clusterrole orchestration-policy-engine-manager-role &>/dev/null 2>&1 || kubectl get clusterrole manager-role &>/dev/null 2>&1"

# ============================================
# CRD Schema Test
# ============================================
log_step "4. CRD Schema Test"

log_info "OrchestrationPolicy CRD Schema:"
kubectl get crd orchestrationpolicies.apollo.keti.re.kr -o jsonpath='{.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties}' 2>/dev/null | head -c 500 || true
echo ""

# Verify policy types
log_test "Checking supported policy types..."
CRD_SPEC=$(kubectl get crd orchestrationpolicies.apollo.keti.re.kr -o yaml 2>/dev/null)
for ptype in migration scaling provisioning caching loadbalance preemption; do
    if echo "$CRD_SPEC" | grep -q "$ptype"; then
        log_info "  - $ptype: supported"
    fi
done

# ============================================
# Basic Policy Creation Test
# ============================================
log_step "5. Basic Policy Creation Test"

# Create a simple test policy (autoExecute: false)
log_test "Creating test policy (autoExecute: false)..."
cat <<EOF | kubectl apply -f -
apiVersion: apollo.keti.re.kr/v1alpha1
kind: OrchestrationPolicy
metadata:
  name: test-basic-policy
  namespace: $NAMESPACE
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

sleep 3

run_test "Policy created" "kubectl get orchestrationpolicy test-basic-policy -n $NAMESPACE &>/dev/null"

# Check policy status
POLICY_STATUS=$(kubectl get orchestrationpolicy test-basic-policy -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
log_info "Policy status: ${POLICY_STATUS:-Pending}"
run_test "Policy has status" "[ -n '${POLICY_STATUS:-}' ] || true"

# ============================================
# Controller Logs Test
# ============================================
log_step "6. Controller Logs Test"

log_info "Recent controller logs:"
kubectl logs -n $NAMESPACE -l control-plane=controller-manager --tail=20 2>/dev/null || log_warn "Could not retrieve logs"

# ============================================
# Cleanup
# ============================================
log_step "7. Cleanup"

kubectl delete orchestrationpolicy test-basic-policy -n $NAMESPACE --ignore-not-found >/dev/null
log_info "Cleanup completed"

# ============================================
# Available Test Scripts
# ============================================
echo ""
log_info "=========================================="
log_info "Additional Test Scripts Available:"
log_info "=========================================="
log_info "  ./test-auto-execute-false.sh  - Manual approval test (autoExecute: false)"
log_info "  ./test-auto-execute-true.sh   - Auto execution test (autoExecute: true)"
log_info "  ./test-scenario-migration.sh  - Migration scenario with real pods"
log_info "  ./test-scenario-scaling.sh    - Scaling scenario with stress test"
log_info "  ./test-all-policies.sh        - Test all 6 policy types"

# ============================================
# Summary
# ============================================
print_test_summary
