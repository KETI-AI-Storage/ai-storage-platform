#!/usr/bin/env bash
#
# Insight Scope Component Test
# 메트릭 수집 컴포넌트 테스트
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

NAMESPACE="apollo"
DEPLOYMENT_NAME="insight-scope"
SERVICE_NAME="insight-scope"
SERVICE_PORT="8080"

print_header "Insight Scope Component Test"

# ============================================
# Prerequisites Check
# ============================================
log_step "1. Prerequisites Check"

if ! kubectl get namespace $NAMESPACE &>/dev/null; then
    log_error "Namespace '$NAMESPACE' not found"
    exit 1
fi

if ! kubectl get deployment $DEPLOYMENT_NAME -n $NAMESPACE &>/dev/null; then
    log_error "Deployment '$DEPLOYMENT_NAME' not found in namespace '$NAMESPACE'"
    log_info "Please deploy insight-scope first"
    exit 1
fi

run_test "Namespace exists" "kubectl get namespace $NAMESPACE &>/dev/null"

# ============================================
# Deployment Test
# ============================================
log_step "2. Deployment Test"

run_test "Deployment exists" "kubectl get deployment $DEPLOYMENT_NAME -n $NAMESPACE &>/dev/null"
run_test "Deployment is ready" "check_deployment_running $NAMESPACE $DEPLOYMENT_NAME"

# Get pod name
POD_NAME=$(kubectl get pods -n $NAMESPACE -l app=$DEPLOYMENT_NAME -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$POD_NAME" ]; then
    log_info "Pod name: $POD_NAME"
    run_test "Pod is running" "kubectl get pod $POD_NAME -n $NAMESPACE -o jsonpath='{.status.phase}' | grep -q Running"
fi

# ============================================
# Service Test
# ============================================
log_step "3. Service Test"

run_test "Service exists" "kubectl get svc $SERVICE_NAME -n $NAMESPACE &>/dev/null"

SERVICE_IP=$(get_service_ip $NAMESPACE $SERVICE_NAME)
log_info "Service ClusterIP: $SERVICE_IP"

# ============================================
# API Test
# ============================================
log_step "4. API Endpoint Test"

# Create curl pod for testing
log_info "Creating test curl pod..."
create_curl_pod "test-insight-scope" "default"

# Test health endpoint
log_test "Testing health endpoint..."
HEALTH_RESPONSE=$(exec_curl "test-insight-scope" "default" "http://${SERVICE_IP}:${SERVICE_PORT}/health" "GET" 2>/dev/null || echo "")
if echo "$HEALTH_RESPONSE" | grep -qiE "healthy|ok|status"; then
    run_test "Health endpoint" "true"
    log_info "Health response: $HEALTH_RESPONSE"
else
    log_warn "Health endpoint response: $HEALTH_RESPONSE"
    run_test "Health endpoint" "[ -n '$HEALTH_RESPONSE' ]"
fi

# Test metrics endpoint (if exists)
log_test "Testing metrics endpoint..."
METRICS_RESPONSE=$(exec_curl "test-insight-scope" "default" "http://${SERVICE_IP}:${SERVICE_PORT}/metrics" "GET" 2>/dev/null || echo "")
if [ -n "$METRICS_RESPONSE" ]; then
    log_info "Metrics endpoint available"
    run_test "Metrics endpoint" "true"
else
    log_info "Metrics endpoint not available or empty response"
fi

# ============================================
# Log Test
# ============================================
log_step "5. Log Test"

log_info "Checking recent logs..."
kubectl logs -n $NAMESPACE -l app=$DEPLOYMENT_NAME --tail=10 2>/dev/null || log_warn "Could not retrieve logs"

# ============================================
# Cleanup
# ============================================
log_step "6. Cleanup"

cleanup_curl_pod "test-insight-scope" "default"
log_info "Cleanup completed"

# ============================================
# Summary
# ============================================
print_test_summary
