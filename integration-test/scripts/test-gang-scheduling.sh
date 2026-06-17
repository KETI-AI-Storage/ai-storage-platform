#!/bin/bash
# ============================================
# KETI AI Storage - Gang Scheduling Test
# ============================================
# Kueue를 사용한 Gang Scheduling 테스트
# Master + Worker 3개가 동시에 스케줄되는지 확인
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
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${CYAN}[STEP]${NC} $1"; }

print_header() {
    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo " $1"
    echo "════════════════════════════════════════════════════════════"
}

# ============================================
# 1. Prerequisites Check
# ============================================
check_prerequisites() {
    print_header "1. Prerequisites Check"

    # kubectl
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found"
        exit 1
    fi
    log_success "kubectl: OK"

    # Cluster connection
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to cluster"
        exit 1
    fi
    log_success "Cluster connection: OK"

    # Kueue
    if kubectl get crd clusterqueues.kueue.x-k8s.io &> /dev/null; then
        log_success "Kueue CRDs: OK"
    else
        log_error "Kueue not installed"
        exit 1
    fi

    # AI Storage Scheduler
    if kubectl get pods -n keti -l app=ai-storage-scheduler --no-headers 2>/dev/null | grep -q "Running"; then
        log_success "AI Storage Scheduler: Running"
    else
        log_warning "AI Storage Scheduler: Not Running (will use default scheduler)"
    fi
}

# ============================================
# 2. Check Kueue Configuration
# ============================================
check_kueue_config() {
    print_header "2. Kueue Configuration"

    echo ""
    log_step "ClusterQueues:"
    kubectl get clusterqueue -o wide 2>/dev/null || log_warning "No ClusterQueues found"

    echo ""
    log_step "LocalQueues:"
    kubectl get localqueue -A -o wide 2>/dev/null || log_warning "No LocalQueues found"

    echo ""
    log_step "ResourceFlavors:"
    kubectl get resourceflavor -o wide 2>/dev/null || log_warning "No ResourceFlavors found"
}

# ============================================
# 3. Create Namespace
# ============================================
create_namespace() {
    print_header "3. Creating Test Namespace"

    kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
    log_success "Namespace '$NAMESPACE' ready"

    # Check if LocalQueue exists for this namespace
    if ! kubectl get localqueue -n $NAMESPACE ai-storage-queue &> /dev/null; then
        log_warning "LocalQueue 'ai-storage-queue' not found in namespace"
        log_info "Creating LocalQueue..."

        kubectl apply -f - <<EOF
apiVersion: kueue.x-k8s.io/v1beta1
kind: LocalQueue
metadata:
  name: ai-storage-queue
  namespace: $NAMESPACE
spec:
  clusterQueue: ai-storage-cluster-queue
EOF
        log_success "LocalQueue created"
    fi
}

# ============================================
# 4. Deploy Gang Scheduling Jobs
# ============================================
deploy_gang_jobs() {
    print_header "4. Deploying Gang Scheduling Jobs"

    log_info "Deploying 1 Master + 3 Workers..."
    kubectl apply -f "$TEST_DIR/workloads/gang-scheduling-test.yaml"

    echo ""
    log_success "Gang jobs deployed:"
    echo "  - gang-master   (coordinator)"
    echo "  - gang-worker-1 (training)"
    echo "  - gang-worker-2 (training)"
    echo "  - gang-worker-3 (training)"
}

# ============================================
# 5. Monitor Gang Scheduling
# ============================================
monitor_gang_scheduling() {
    print_header "5. Monitoring Gang Scheduling"

    local timeout=120
    local elapsed=0
    local all_running=false

    echo ""
    log_info "Waiting for all gang members to be scheduled (timeout: ${timeout}s)..."
    echo ""

    while [ $elapsed -lt $timeout ]; do
        # Get job status
        local master_status=$(kubectl get pods -n $NAMESPACE -l gang-group=distributed-training,role=master -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Pending")
        local worker_count=$(kubectl get pods -n $NAMESPACE -l gang-group=distributed-training,role=worker --no-headers 2>/dev/null | grep -c "Running" || echo "0")

        echo -ne "\r  Master: ${master_status} | Workers Running: ${worker_count}/3 | Elapsed: ${elapsed}s   "

        if [ "$master_status" = "Running" ] && [ "$worker_count" -eq 3 ]; then
            all_running=true
            break
        fi

        # Check if all completed
        local completed=$(kubectl get pods -n $NAMESPACE -l gang-group=distributed-training --no-headers 2>/dev/null | grep -c "Completed" || echo "0")
        if [ "$completed" -eq 4 ]; then
            echo ""
            log_success "All gang members completed!"
            return 0
        fi

        sleep 3
        elapsed=$((elapsed + 3))
    done

    echo ""
    if [ "$all_running" = true ]; then
        log_success "All gang members are running simultaneously!"
    else
        log_warning "Timeout reached. Checking current status..."
    fi
}

# ============================================
# 6. Show Results
# ============================================
show_results() {
    print_header "6. Gang Scheduling Results"

    echo ""
    log_step "Pod Status:"
    kubectl get pods -n $NAMESPACE -l gang-group=distributed-training -o wide

    echo ""
    log_step "Scheduling Timeline:"
    kubectl get pods -n $NAMESPACE -l gang-group=distributed-training \
        -o custom-columns='NAME:.metadata.name,NODE:.spec.nodeName,START:.status.startTime,STATUS:.status.phase' \
        --sort-by=.status.startTime

    echo ""
    log_step "Kueue Workload Status:"
    kubectl get workloads -n $NAMESPACE -o wide 2>/dev/null || log_info "No Kueue workloads (jobs may be using direct scheduling)"

    echo ""
    log_step "Node Distribution:"
    echo "  Checking if gang members are distributed across nodes..."
    kubectl get pods -n $NAMESPACE -l gang-group=distributed-training \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\n"}{end}'
}

# ============================================
# 7. Show Logs
# ============================================
show_logs() {
    print_header "7. Job Logs (Summary)"

    for job in gang-master gang-worker-1 gang-worker-2 gang-worker-3; do
        echo ""
        log_step "Logs from $job (last 5 lines):"
        kubectl logs -n $NAMESPACE -l job-name=$job --tail=5 2>/dev/null || echo "  (not available yet)"
    done
}

# ============================================
# 8. Cleanup
# ============================================
cleanup() {
    print_header "Cleanup"

    log_info "Deleting gang scheduling test jobs..."
    kubectl delete -f "$TEST_DIR/workloads/gang-scheduling-test.yaml" --ignore-not-found=true

    log_success "Cleanup complete"
}

# ============================================
# ArgoCD Registration
# ============================================
register_argocd() {
    print_header "ArgoCD Application Registration"

    log_info "Creating ArgoCD Application for integration tests..."

    kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: keti-gang-scheduling-test
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/keti-ai/keti-ai-storage.git
    targetRevision: main
    path: integration-test/workloads
  destination:
    server: https://kubernetes.default.svc
    namespace: ai-workload-test
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF

    log_success "ArgoCD Application 'keti-gang-scheduling-test' created"
    echo ""
    log_info "View in ArgoCD UI or run: kubectl get application -n argocd keti-gang-scheduling-test"
}

# ============================================
# Main
# ============================================
main() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║     KETI AI Storage - Gang Scheduling Test                   ║"
    echo "║     Kueue + AI Storage Scheduler Integration                 ║"
    echo "╚══════════════════════════════════════════════════════════════╝"

    case "${1:-}" in
        "argocd")
            register_argocd
            ;;
        "cleanup")
            cleanup
            ;;
        "status")
            show_results
            show_logs
            ;;
        "logs")
            show_logs
            ;;
        "monitor")
            monitor_gang_scheduling
            show_results
            ;;
        *)
            check_prerequisites
            check_kueue_config
            create_namespace
            deploy_gang_jobs
            monitor_gang_scheduling
            show_results
            show_logs

            echo ""
            print_header "Test Complete"
            echo ""
            log_info "Commands:"
            echo "  $0 status   - Show current status"
            echo "  $0 logs     - Show job logs"
            echo "  $0 monitor  - Monitor scheduling"
            echo "  $0 argocd   - Register with ArgoCD"
            echo "  $0 cleanup  - Remove test resources"
            ;;
    esac
}

main "$@"
