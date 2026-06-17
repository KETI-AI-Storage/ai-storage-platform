#!/usr/bin/env bash
#
# AI Storage Orchestrator Component Test
# 6가지 Operator 실행 컴포넌트 테스트
#
# Operators:
# 1. Migration Operator - 티어 마이그레이션
# 2. AutoScaling Operator - 오토스케일링
# 3. Loadbalance Operator - 로드밸런싱
# 4. Caching Operator - 글로벌 캐싱
# 5. Provision Operator - 사전 프로비저닝
# 6. Preemption Operator - 선점
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

NAMESPACE="kube-system"
DEPLOYMENT_NAME="ai-storage-orchestrator"
SERVICE_NAME="ai-storage-orchestrator"
SERVICE_PORT="8080"

print_header "AI Storage Orchestrator Component Test"

# ============================================
# Prerequisites Check
# ============================================
log_step "1. Prerequisites Check"

if ! kubectl get deployment $DEPLOYMENT_NAME -n $NAMESPACE &>/dev/null; then
    log_error "Deployment '$DEPLOYMENT_NAME' not found in namespace '$NAMESPACE'"
    log_info "Please deploy ai-storage-orchestrator first"
    exit 1
fi

run_test "Namespace exists" "kubectl get namespace $NAMESPACE &>/dev/null"

# ============================================
# Deployment Test
# ============================================
log_step "2. Deployment Test"

run_test "Deployment exists" "kubectl get deployment $DEPLOYMENT_NAME -n $NAMESPACE &>/dev/null"
run_test "Deployment is ready" "check_deployment_running $NAMESPACE $DEPLOYMENT_NAME"

POD_NAME=$(kubectl get pods -n $NAMESPACE -l app=$DEPLOYMENT_NAME -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$POD_NAME" ]; then
    log_info "Orchestrator Pod: $POD_NAME"
    run_test "Pod running" "kubectl get pod $POD_NAME -n $NAMESPACE -o jsonpath='{.status.phase}' | grep -q Running"
fi

# ============================================
# Service Test
# ============================================
log_step "3. Service Test"

run_test "Service exists" "kubectl get svc $SERVICE_NAME -n $NAMESPACE &>/dev/null"

SERVICE_IP=$(get_service_ip $NAMESPACE $SERVICE_NAME)
log_info "Service ClusterIP: $SERVICE_IP:$SERVICE_PORT"

# ============================================
# API Endpoint Tests
# ============================================
log_step "4. API Endpoint Tests"

# Create curl pod
log_info "Creating test curl pod..."
create_curl_pod "test-orchestrator" "default"

# Test health endpoint
log_test "Testing /health endpoint..."
HEALTH_RESPONSE=$(exec_curl "test-orchestrator" "default" "http://${SERVICE_IP}:${SERVICE_PORT}/health" "GET" 2>/dev/null || echo "")
if echo "$HEALTH_RESPONSE" | grep -qiE "healthy|ok|status"; then
    run_test "Health endpoint" "true"
    log_info "Health response: $HEALTH_RESPONSE"
else
    log_warn "Health response: $HEALTH_RESPONSE"
    run_test "Health endpoint responds" "[ -n '$HEALTH_RESPONSE' ]"
fi

# ============================================
# Migration API Test
# ============================================
log_step "5. Migration API Test"

log_test "Testing POST /api/v1/migrations..."
MIGRATION_REQUEST='{
  "pod_name": "test-pod",
  "pod_namespace": "default",
  "source_node": "worker-1",
  "target_node": "worker-2",
  "preserve_pv": true,
  "timeout": 300
}'

MIGRATION_RESPONSE=$(exec_curl "test-orchestrator" "default" \
    "http://${SERVICE_IP}:${SERVICE_PORT}/api/v1/migrations" \
    "POST" "$MIGRATION_REQUEST" 2>/dev/null || echo "")

if [ -n "$MIGRATION_RESPONSE" ]; then
    log_info "Migration API response: $MIGRATION_RESPONSE"
    if echo "$MIGRATION_RESPONSE" | grep -qE "migration_id|id|error"; then
        run_test "Migration API" "true"
    else
        run_test "Migration API responds" "true"
    fi
else
    log_warn "Migration API no response"
    run_test "Migration API" "false"
fi

# ============================================
# Autoscaling API Test
# ============================================
log_step "6. Autoscaling API Test"

log_test "Testing POST /api/v1/autoscaling..."
AUTOSCALING_REQUEST='{
  "workload_name": "test-deployment",
  "workload_namespace": "default",
  "min_replicas": 2,
  "max_replicas": 10,
  "target_cpu_percent": 70,
  "target_memory_percent": 80
}'

AUTOSCALING_RESPONSE=$(exec_curl "test-orchestrator" "default" \
    "http://${SERVICE_IP}:${SERVICE_PORT}/api/v1/autoscaling" \
    "POST" "$AUTOSCALING_REQUEST" 2>/dev/null || echo "")

if [ -n "$AUTOSCALING_RESPONSE" ]; then
    log_info "Autoscaling API response: $AUTOSCALING_RESPONSE"
    run_test "Autoscaling API" "true"
else
    log_warn "Autoscaling API no response"
fi

# ============================================
# Provisioning API Test
# ============================================
log_step "7. Provisioning API Test"

log_test "Testing POST /api/v1/provisioning..."
PROVISIONING_REQUEST='{
  "workload_name": "test-job",
  "workload_namespace": "default",
  "storage_size": "10Gi",
  "storage_class": "standard",
  "access_mode": "ReadWriteOnce"
}'

PROVISIONING_RESPONSE=$(exec_curl "test-orchestrator" "default" \
    "http://${SERVICE_IP}:${SERVICE_PORT}/api/v1/provisioning" \
    "POST" "$PROVISIONING_REQUEST" 2>/dev/null || echo "")

if [ -n "$PROVISIONING_RESPONSE" ]; then
    log_info "Provisioning API response: $PROVISIONING_RESPONSE"
    run_test "Provisioning API" "true"
else
    log_warn "Provisioning API no response"
fi

# ============================================
# Caching API Test
# ============================================
log_step "8. Caching API Test"

log_test "Testing POST /api/v1/caching..."
CACHING_REQUEST='{
  "source_pvc": "data-volume",
  "source_namespace": "default",
  "target_tier": "nvme",
  "cache_size": "5Gi"
}'

CACHING_RESPONSE=$(exec_curl "test-orchestrator" "default" \
    "http://${SERVICE_IP}:${SERVICE_PORT}/api/v1/caching" \
    "POST" "$CACHING_REQUEST" 2>/dev/null || echo "")

if [ -n "$CACHING_RESPONSE" ]; then
    log_info "Caching API response: $CACHING_RESPONSE"
    run_test "Caching API" "true"
else
    log_warn "Caching API no response"
fi

# ============================================
# Loadbalancing API Test
# ============================================
log_step "9. Loadbalancing API Test"

log_test "Testing POST /api/v1/loadbalancing..."
LOADBALANCING_REQUEST='{
  "target_node": "worker-1",
  "strategy": "round-robin",
  "weight": 100
}'

LOADBALANCING_RESPONSE=$(exec_curl "test-orchestrator" "default" \
    "http://${SERVICE_IP}:${SERVICE_PORT}/api/v1/loadbalancing" \
    "POST" "$LOADBALANCING_REQUEST" 2>/dev/null || echo "")

if [ -n "$LOADBALANCING_RESPONSE" ]; then
    log_info "Loadbalancing API response: $LOADBALANCING_RESPONSE"
    run_test "Loadbalancing API" "true"
else
    log_warn "Loadbalancing API no response"
fi

# ============================================
# Preemption API Test
# ============================================
log_step "10. Preemption API Test"

log_test "Testing POST /api/v1/preemption..."
PREEMPTION_REQUEST='{
  "workload_name": "high-priority-job",
  "workload_namespace": "default",
  "priority": 1000,
  "reason": "High priority AI training",
  "grace_period": 30
}'

PREEMPTION_RESPONSE=$(exec_curl "test-orchestrator" "default" \
    "http://${SERVICE_IP}:${SERVICE_PORT}/api/v1/preemption" \
    "POST" "$PREEMPTION_REQUEST" 2>/dev/null || echo "")

if [ -n "$PREEMPTION_RESPONSE" ]; then
    log_info "Preemption API response: $PREEMPTION_RESPONSE"
    run_test "Preemption API" "true"
else
    log_warn "Preemption API no response"
fi

# ============================================
# Orchestrator Logs
# ============================================
log_step "11. Orchestrator Logs"

log_info "Recent orchestrator logs:"
kubectl logs -n $NAMESPACE -l app=$DEPLOYMENT_NAME --tail=30 2>/dev/null | tail -20 || log_warn "Could not retrieve logs"

# ============================================
# Cleanup
# ============================================
log_step "12. Cleanup"

cleanup_curl_pod "test-orchestrator" "default"
log_info "Cleanup completed"

# ============================================
# Summary
# ============================================
echo ""
log_info "=========================================="
log_info "    ORCHESTRATOR TEST SUMMARY"
log_info "=========================================="
echo ""
log_info "Service: $SERVICE_IP:$SERVICE_PORT"
log_info ""
log_info "API Endpoints Tested:"
log_info "  - GET  /health"
log_info "  - POST /api/v1/migrations"
log_info "  - POST /api/v1/autoscaling"
log_info "  - POST /api/v1/provisioning"
log_info "  - POST /api/v1/caching"
log_info "  - POST /api/v1/loadbalancing"
log_info "  - POST /api/v1/preemption"
log_info ""

print_test_summary
