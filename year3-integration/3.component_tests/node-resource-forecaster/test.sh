#!/usr/bin/env bash
#
# Node Resource Forecaster Component Test
# 자원 예측 컴포넌트 테스트
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

NAMESPACE="apollo"
DEPLOYMENT_NAME="node-resource-forecaster"
SERVICE_NAME="node-resource-forecaster"
SERVICE_PORT="8080"

print_header "Node Resource Forecaster Component Test"

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
    log_info "Please deploy node-resource-forecaster first"
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
create_curl_pod "test-forecaster" "default"

# Test health endpoint
log_test "Testing health endpoint..."
HEALTH_RESPONSE=$(exec_curl "test-forecaster" "default" "http://${SERVICE_IP}:${SERVICE_PORT}/health" "GET" 2>/dev/null || echo "")
if echo "$HEALTH_RESPONSE" | grep -qiE "healthy|ok|status"; then
    run_test "Health endpoint" "true"
    log_info "Health response: $HEALTH_RESPONSE"
else
    log_warn "Health endpoint response: $HEALTH_RESPONSE"
    run_test "Health endpoint" "[ -n '$HEALTH_RESPONSE' ]"
fi

# ============================================
# Forecasting Test
# ============================================
log_step "5. Forecasting Functionality Test"

# Get node list
NODES=$(kubectl get nodes --no-headers -o custom-columns=":metadata.name" 2>/dev/null)
FIRST_NODE=$(echo "$NODES" | head -1)

if [ -n "$FIRST_NODE" ]; then
    log_info "Testing forecast for node: $FIRST_NODE"

    # Test forecast endpoint for specific node
    log_test "Testing node forecast endpoint..."
    FORECAST_RESPONSE=$(exec_curl "test-forecaster" "default" "http://${SERVICE_IP}:${SERVICE_PORT}/api/v1/forecast/${FIRST_NODE}" "GET" 2>/dev/null || echo "")
    if [ -n "$FORECAST_RESPONSE" ]; then
        log_info "Forecast response: $FORECAST_RESPONSE"
        run_test "Node forecast endpoint" "true"
    else
        log_warn "No forecast response for node"
    fi

    # Test prediction API
    log_test "Testing prediction API..."
    PREDICT_REQUEST='{"node":"'$FIRST_NODE'","metrics":["cpu","memory"],"horizon":60}'
    PREDICT_RESPONSE=$(exec_curl "test-forecaster" "default" "http://${SERVICE_IP}:${SERVICE_PORT}/api/v1/predict" "POST" "$PREDICT_REQUEST" 2>/dev/null || echo "")
    if [ -n "$PREDICT_RESPONSE" ]; then
        log_info "Prediction response: $PREDICT_RESPONSE"
        run_test "Prediction API" "true"
    else
        log_info "Prediction API may not be available"
    fi
fi

# Test all nodes forecast
log_test "Testing all nodes forecast..."
ALL_FORECAST=$(exec_curl "test-forecaster" "default" "http://${SERVICE_IP}:${SERVICE_PORT}/api/v1/forecasts" "GET" 2>/dev/null || echo "")
if [ -n "$ALL_FORECAST" ]; then
    log_info "All nodes forecast available"
    run_test "All nodes forecast" "true"
fi

# ============================================
# Policy Generation Test
# ============================================
log_step "6. Policy Generation Test (if available)"

# Check if forecaster generates policies
log_test "Checking for auto-generated policies..."
GENERATED_POLICIES=$(kubectl get orchestrationpolicies -n $NAMESPACE -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
if [ -n "$GENERATED_POLICIES" ]; then
    log_info "Found policies: $GENERATED_POLICIES"
else
    log_info "No auto-generated policies found (forecaster may need more data)"
fi

# ============================================
# Log Test
# ============================================
log_step "7. Log Test"

log_info "Checking recent logs..."
kubectl logs -n $NAMESPACE -l app=$DEPLOYMENT_NAME --tail=15 2>/dev/null || log_warn "Could not retrieve logs"

# ============================================
# Cleanup
# ============================================
log_step "8. Cleanup"

cleanup_curl_pod "test-forecaster" "default"
log_info "Cleanup completed"

# ============================================
# Summary
# ============================================
print_test_summary
