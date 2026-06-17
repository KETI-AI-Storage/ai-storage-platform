#!/bin/bash
# ============================================
# KETI AI Storage System - Integration Test Script
# ============================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(dirname "$SCRIPT_DIR")"
NAMESPACE="ai-workload-test"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

print_header() {
    echo ""
    echo "============================================"
    echo " $1"
    echo "============================================"
}

# Check prerequisites
check_prerequisites() {
    print_header "1. Checking Prerequisites"

    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found"
        exit 1
    fi
    log_success "kubectl found"

    # Check cluster connection
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        exit 1
    fi
    log_success "Connected to Kubernetes cluster"
}

# Check system components
check_system_components() {
    print_header "2. Checking System Components"

    local all_ready=true

    # Check ai-storage-scheduler
    if kubectl get pods -n keti -l app.kubernetes.io/name=ai-storage-scheduler --no-headers 2>/dev/null | grep -q "Running"; then
        log_success "ai-storage-scheduler: Running"
    else
        log_warning "ai-storage-scheduler: Not Running"
        all_ready=false
    fi

    # Check apollo-policy-server
    if kubectl get pods -n keti -l app.kubernetes.io/name=apollo-policy-server --no-headers 2>/dev/null | grep -q "Running"; then
        log_success "apollo-policy-server: Running"
    else
        log_warning "apollo-policy-server: Not Running"
        all_ready=false
    fi

    # Check insight-scope
    if kubectl get pods -n keti -l app=insight-scope --no-headers 2>/dev/null | grep -q "Running"; then
        log_success "insight-scope: Running"
    else
        log_warning "insight-scope: Not Running"
        all_ready=false
    fi

    # Check ai-storage-orchestrator
    if kubectl get pods -n kube-system -l app=ai-storage-orchestrator --no-headers 2>/dev/null | grep -q "Running"; then
        log_success "ai-storage-orchestrator: Running"
    else
        log_warning "ai-storage-orchestrator: Not Running"
        all_ready=false
    fi

    if [ "$all_ready" = false ]; then
        log_warning "Some components are not running. Continuing anyway..."
    fi
}

# Deploy test namespace
deploy_namespace() {
    print_header "3. Creating Test Namespace"

    kubectl apply -f "$TEST_DIR/00-namespace.yaml"
    log_success "Namespace '$NAMESPACE' created"
}

# Deploy test workloads
deploy_workloads() {
    print_header "4. Deploying Test Workloads"

    # Training job
    log_info "Deploying AI Training Pod..."
    kubectl apply -f "$TEST_DIR/workloads/01-ai-training-job.yaml"

    # Inference deployment
    log_info "Deploying AI Inference Deployment..."
    kubectl apply -f "$TEST_DIR/workloads/02-ai-inference-deployment.yaml"

    # Preprocessing job
    log_info "Deploying Data Preprocessing Job..."
    kubectl apply -f "$TEST_DIR/workloads/03-data-preprocessing-job.yaml"

    log_success "All workloads deployed"
}

# Wait for pods and show status
wait_for_pods() {
    print_header "5. Waiting for Pods to Schedule"

    log_info "Waiting for pods to be scheduled (timeout: 120s)..."

    local timeout=120
    local elapsed=0

    while [ $elapsed -lt $timeout ]; do
        local pending=$(kubectl get pods -n $NAMESPACE --no-headers 2>/dev/null | grep -c "Pending" || true)
        if [ "$pending" -eq 0 ]; then
            log_success "All pods scheduled!"
            break
        fi
        echo -n "."
        sleep 5
        elapsed=$((elapsed + 5))
    done
    echo ""

    if [ $elapsed -ge $timeout ]; then
        log_warning "Timeout waiting for pods. Some pods may still be pending."
    fi
}

# Show pod status
show_status() {
    print_header "6. Pod Status"

    echo ""
    echo "=== Test Namespace Pods ==="
    kubectl get pods -n $NAMESPACE -o wide

    echo ""
    echo "=== System Components ==="
    kubectl get pods -n keti -o wide

    echo ""
    echo "=== Scheduler Logs (last 10 lines) ==="
    kubectl logs -n keti -l app.kubernetes.io/name=ai-storage-scheduler --tail=10 2>/dev/null || echo "No logs available"

    echo ""
    echo "=== APOLLO Policy Server Logs (last 10 lines) ==="
    kubectl logs -n keti -l app.kubernetes.io/name=apollo-policy-server --tail=10 2>/dev/null || echo "No logs available"
}

# Verify scheduling
verify_scheduling() {
    print_header "7. Verifying Scheduling"

    echo ""
    echo "Checking if pods were scheduled by ai-storage-scheduler..."

    for pod in $(kubectl get pods -n $NAMESPACE -o jsonpath='{.items[*].metadata.name}'); do
        local scheduler=$(kubectl get pod -n $NAMESPACE $pod -o jsonpath='{.spec.schedulerName}')
        local node=$(kubectl get pod -n $NAMESPACE $pod -o jsonpath='{.spec.nodeName}')

        if [ "$scheduler" = "ai-storage-scheduler" ]; then
            if [ -n "$node" ]; then
                log_success "Pod $pod: Scheduled by $scheduler -> Node: $node"
            else
                log_warning "Pod $pod: Pending (scheduler: $scheduler)"
            fi
        else
            log_info "Pod $pod: Scheduler = $scheduler"
        fi
    done
}

# Cleanup function
cleanup() {
    print_header "Cleanup"

    log_info "Deleting test resources..."
    kubectl delete namespace $NAMESPACE --ignore-not-found=true
    log_success "Cleanup complete"
}

# Main
main() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║     KETI AI Storage System - Integration Test              ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""

    case "${1:-}" in
        "cleanup")
            cleanup
            ;;
        "status")
            show_status
            verify_scheduling
            ;;
        *)
            check_prerequisites
            check_system_components
            deploy_namespace
            deploy_workloads
            wait_for_pods
            show_status
            verify_scheduling

            echo ""
            print_header "Test Complete"
            log_info "Run '$0 status' to check current status"
            log_info "Run '$0 cleanup' to remove test resources"
            ;;
    esac
}

main "$@"
