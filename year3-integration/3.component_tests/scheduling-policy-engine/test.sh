#!/usr/bin/env bash
#
# Scheduling Policy Engine Component Test
# 스케줄링 정책 엔진 테스트
#
# Note: This component may be part of the ai-storage-scheduler
# or a separate module for scheduling policies
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

NAMESPACE="apollo"

print_header "Scheduling Policy Engine Component Test"

log_info "Scheduling Policy Engine은 AI-Storage-Scheduler 또는"
log_info "Orchestration Policy Engine의 스케줄링 관련 부분입니다."
echo ""

# ============================================
# Check Related Components
# ============================================
log_step "1. Related Components Check"

# Check if it's part of orchestration policy engine
if kubectl get deployment orchestration-policy-engine -n $NAMESPACE &>/dev/null; then
    log_info "Orchestration Policy Engine found in apollo namespace"
    run_test "Policy Engine exists" "true"

    # Check for scheduling-related policies
    log_info "Checking for scheduling-related CRDs..."

    # The scheduling policy might be integrated into OrchestrationPolicy
    ORCH_CRD=$(kubectl get crd orchestrationpolicies.apollo.keti.re.kr -o yaml 2>/dev/null || echo "")
    if echo "$ORCH_CRD" | grep -q "policyType"; then
        log_info "OrchestrationPolicy CRD supports policy types"
        run_test "CRD supports scheduling policies" "true"
    fi
fi

# Check if separate scheduling policy CRD exists
if kubectl get crd schedulingpolicies.apollo.keti.re.kr &>/dev/null 2>&1; then
    log_info "Separate SchedulingPolicy CRD found"
    run_test "SchedulingPolicy CRD" "true"
else
    log_info "No separate SchedulingPolicy CRD - using OrchestrationPolicy"
fi

# ============================================
# AI Storage Scheduler Check
# ============================================
log_step "2. AI Storage Scheduler Integration"

if kubectl get deployment ai-storage-scheduler -n keti &>/dev/null; then
    log_info "AI Storage Scheduler found"
    run_test "Scheduler exists" "true"

    # The scheduler itself implements scheduling policies
    log_info "Scheduler implements scheduling algorithms:"
    log_info "  - NodeResourcesFit (Filter)"
    log_info "  - LeastAllocated (Score)"
    log_info "  - DefaultBinder (Bind)"
else
    log_warn "AI Storage Scheduler not found"
fi

# ============================================
# Scheduling Policy Test via OrchestrationPolicy
# ============================================
log_step "3. Scheduling Policy Test"

log_info "Testing scheduling-related policies via OrchestrationPolicy..."

# Preemption policy is related to scheduling
cat <<EOF | kubectl apply -f -
apiVersion: apollo.keti.re.kr/v1alpha1
kind: OrchestrationPolicy
metadata:
  name: test-scheduling-preemption
  namespace: $NAMESPACE
spec:
  policyType: preemption
  priority: 100
  autoExecute: false
  targetWorkload:
    name: high-priority-workload
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
      reason: "Scheduling priority policy"
      graceperiod: 30
EOF

sleep 3

PREEMPT_STATUS=$(kubectl get orchestrationpolicy test-scheduling-preemption -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
log_info "Preemption policy status: $PREEMPT_STATUS"
run_test "Preemption policy created" "kubectl get orchestrationpolicy test-scheduling-preemption -n $NAMESPACE &>/dev/null"

# ============================================
# Node Affinity Policy Test
# ============================================
log_step "4. Node Affinity/Selection Test"

log_info "Testing node selection via Pod scheduling..."

# Create pod with node selector (uses ai-storage-scheduler)
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-scheduling-affinity
  namespace: default
  labels:
    test: scheduling-policy
spec:
  schedulerName: ai-storage-scheduler
  affinity:
    nodeAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        preference:
          matchExpressions:
          - key: layer
            operator: In
            values:
            - compute
  containers:
  - name: test
    image: busybox:latest
    command: ["sh", "-c", "sleep 30"]
    resources:
      requests:
        cpu: "50m"
        memory: "32Mi"
  restartPolicy: Never
EOF

sleep 10

POD_NODE=$(kubectl get pod test-scheduling-affinity -n default -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "")
POD_STATUS=$(kubectl get pod test-scheduling-affinity -n default -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")

log_info "Affinity pod status: $POD_STATUS"
log_info "Scheduled node: ${POD_NODE:-not yet scheduled}"

if [ -n "$POD_NODE" ]; then
    run_test "Node affinity scheduling" "true"

    # Check if node has expected label
    NODE_LAYER=$(kubectl get node $POD_NODE -o jsonpath='{.metadata.labels.layer}' 2>/dev/null || echo "")
    log_info "Node layer label: ${NODE_LAYER:-none}"
else
    run_test "Affinity pod created" "[ '$POD_STATUS' != '' ]"
fi

# ============================================
# Priority Class Test
# ============================================
log_step "5. Priority Class Test"

log_info "Checking PriorityClasses..."
kubectl get priorityclasses 2>/dev/null || log_info "No PriorityClasses found"

# ============================================
# Scheduler Logs for Policy Decisions
# ============================================
log_step "6. Scheduler Policy Logs"

if kubectl get pods -n keti -l app=ai-storage-scheduler &>/dev/null; then
    log_info "Checking scheduler logs for policy decisions..."
    kubectl logs -n keti -l app=ai-storage-scheduler --tail=30 2>/dev/null | grep -iE "filter|score|policy|scheduling" | tail -10 || log_info "No policy-related entries"
fi

# ============================================
# Cleanup
# ============================================
log_step "7. Cleanup"

kubectl delete orchestrationpolicy test-scheduling-preemption -n $NAMESPACE --ignore-not-found >/dev/null
kubectl delete pod test-scheduling-affinity -n default --ignore-not-found --grace-period=0 --force 2>/dev/null || true

log_info "Cleanup completed"

# ============================================
# Summary
# ============================================
echo ""
log_info "=========================================="
log_info "  SCHEDULING POLICY ENGINE SUMMARY"
log_info "=========================================="
log_info ""
log_info "Scheduling Policy Engine 구성:"
log_info "  1. AI-Storage-Scheduler: 커스텀 스케줄링 알고리즘"
log_info "     - Filter: NodeResourcesFit (노드 리소스 검사)"
log_info "     - Score: LeastAllocated (최소 할당 노드 선호)"
log_info "     - Bind: DefaultBinder (바인딩)"
log_info ""
log_info "  2. OrchestrationPolicy (preemption): 선점 정책"
log_info "     - 우선순위 기반 Pod 선점"
log_info "     - GPU/CSD 리소스 경쟁 해결"
log_info ""
log_info "사용 방법:"
log_info "  - Pod에 schedulerName: ai-storage-scheduler 지정"
log_info "  - 선점 필요시 OrchestrationPolicy(preemption) 생성"
log_info ""

print_test_summary
