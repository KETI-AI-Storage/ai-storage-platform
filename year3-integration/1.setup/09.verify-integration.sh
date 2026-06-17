#!/usr/bin/env bash
#
# 09. Verify Integration - Full System Verification
# Verifies all components are properly installed and running
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ============================================
# Configuration
# ============================================
TIMEOUT=${VERIFY_TIMEOUT:-300}  # 5 minutes default timeout

# ============================================
# Verification Functions
# ============================================

check_namespace() {
    local ns=$1
    if kubectl get namespace "$ns" &>/dev/null; then
        log_info "Namespace '$ns' exists"
        return 0
    else
        log_error "Namespace '$ns' not found"
        return 1
    fi
}

check_deployment() {
    local ns=$1
    local name=$2
    local replicas
    local ready

    if kubectl get deployment "$name" -n "$ns" &>/dev/null; then
        replicas=$(kubectl get deployment "$name" -n "$ns" -o jsonpath='{.spec.replicas}')
        ready=$(kubectl get deployment "$name" -n "$ns" -o jsonpath='{.status.readyReplicas}')
        ready=${ready:-0}

        if [ "$ready" -ge "$replicas" ]; then
            log_info "Deployment '$ns/$name' is ready ($ready/$replicas)"
            return 0
        else
            log_error "Deployment '$ns/$name' not ready ($ready/$replicas)"
            return 1
        fi
    else
        log_error "Deployment '$ns/$name' not found"
        return 1
    fi
}

check_pod_running() {
    local ns=$1
    local label=$2
    local count
    local running

    count=$(kubectl get pods -n "$ns" -l "$label" --no-headers 2>/dev/null | wc -l)
    running=$(kubectl get pods -n "$ns" -l "$label" --no-headers 2>/dev/null | grep -c "Running" || true)

    if [ "$count" -gt 0 ] && [ "$running" -eq "$count" ]; then
        log_info "Pods with label '$label' in '$ns' are running ($running/$count)"
        return 0
    else
        log_error "Pods with label '$label' in '$ns' not all running ($running/$count)"
        return 1
    fi
}

check_crd() {
    local crd=$1
    if kubectl get crd "$crd" &>/dev/null; then
        log_info "CRD '$crd' exists"
        return 0
    else
        log_error "CRD '$crd' not found"
        return 1
    fi
}

check_service() {
    local ns=$1
    local name=$2
    if kubectl get service "$name" -n "$ns" &>/dev/null; then
        log_info "Service '$ns/$name' exists"
        return 0
    else
        log_error "Service '$ns/$name' not found"
        return 1
    fi
}

# ============================================
# Main Verification
# ============================================

print_header "Year 3 Integration Verification"

TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0

run_check() {
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    if "$@"; then
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
    else
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
    fi
}

# ============================================
# 1. Kubernetes Core
# ============================================
log_info "========== Kubernetes Core =========="

run_check kubectl cluster-info &>/dev/null && log_info "Kubernetes cluster is accessible" || log_error "Cannot access Kubernetes cluster"

# Check core namespaces
run_check check_namespace "kube-system"
run_check check_namespace "default"

# Check core components
run_check check_deployment "kube-system" "coredns"
run_check check_pod_running "kube-system" "k8s-app=kube-proxy"

# Check metrics server
if kubectl get deployment metrics-server -n kube-system &>/dev/null; then
    run_check check_deployment "kube-system" "metrics-server"
else
    log_info "Metrics server not installed (optional)"
fi

# ============================================
# 2. CNI (Calico)
# ============================================
log_info "========== CNI (Calico) =========="

if kubectl get namespace calico-system &>/dev/null; then
    run_check check_namespace "calico-system"
    run_check check_deployment "calico-system" "calico-kube-controllers"
    run_check check_pod_running "calico-system" "k8s-app=calico-node"
elif kubectl get pods -n kube-system -l k8s-app=calico-node &>/dev/null; then
    run_check check_pod_running "kube-system" "k8s-app=calico-node"
else
    log_info "Calico CNI not detected, checking for other CNI..."
fi

# ============================================
# 3. Storage
# ============================================
log_info "========== Storage =========="

# Check for NFS provisioner
if kubectl get namespace nfs-provisioner &>/dev/null; then
    run_check check_namespace "nfs-provisioner"
    run_check check_deployment "nfs-provisioner" "nfs-client-provisioner"
fi

# Check StorageClasses
SC_COUNT=$(kubectl get storageclass --no-headers 2>/dev/null | wc -l)
if [ "$SC_COUNT" -gt 0 ]; then
    log_info "StorageClasses found: $SC_COUNT"
    kubectl get storageclass --no-headers 2>/dev/null | while read -r line; do
        log_info "  - $(echo "$line" | awk '{print $1}')"
    done
else
    log_info "No StorageClasses configured (may use local storage)"
fi

# ============================================
# 4. ArgoCD
# ============================================
log_info "========== ArgoCD =========="

if kubectl get namespace argocd &>/dev/null; then
    run_check check_namespace "argocd"
    run_check check_deployment "argocd" "argocd-server"
    run_check check_deployment "argocd" "argocd-repo-server"
    run_check check_deployment "argocd" "argocd-applicationset-controller"
    run_check check_service "argocd" "argocd-server"

    # Check ArgoCD CRDs
    run_check check_crd "applications.argoproj.io"
    run_check check_crd "applicationsets.argoproj.io"
else
    log_info "ArgoCD not installed"
fi

# ============================================
# 5. Kubeflow
# ============================================
log_info "========== Kubeflow =========="

if kubectl get namespace kubeflow &>/dev/null; then
    run_check check_namespace "kubeflow"

    # Training Operator
    if kubectl get deployment training-operator -n kubeflow &>/dev/null; then
        run_check check_deployment "kubeflow" "training-operator"
        run_check check_crd "pytorchjobs.kubeflow.org"
        run_check check_crd "tfjobs.kubeflow.org"
    fi

    # Pipelines
    if kubectl get deployment ml-pipeline -n kubeflow &>/dev/null; then
        run_check check_deployment "kubeflow" "ml-pipeline"
        run_check check_deployment "kubeflow" "ml-pipeline-ui"
    fi
else
    log_info "Kubeflow not installed"
fi

# ============================================
# 6. Kueue
# ============================================
log_info "========== Kueue =========="

if kubectl get namespace kueue-system &>/dev/null; then
    run_check check_namespace "kueue-system"
    run_check check_deployment "kueue-system" "kueue-controller-manager"

    # Check Kueue CRDs
    run_check check_crd "clusterqueues.kueue.x-k8s.io"
    run_check check_crd "localqueues.kueue.x-k8s.io"
    run_check check_crd "workloads.kueue.x-k8s.io"
    run_check check_crd "resourceflavors.kueue.x-k8s.io"

    # Check ClusterQueues
    CQ_COUNT=$(kubectl get clusterqueue --no-headers 2>/dev/null | wc -l)
    if [ "$CQ_COUNT" -gt 0 ]; then
        log_info "ClusterQueues found: $CQ_COUNT"
        kubectl get clusterqueue --no-headers 2>/dev/null | while read -r line; do
            log_info "  - $(echo "$line" | awk '{print $1}')"
        done
    fi

    # Check LocalQueues
    LQ_COUNT=$(kubectl get localqueue -A --no-headers 2>/dev/null | wc -l)
    if [ "$LQ_COUNT" -gt 0 ]; then
        log_info "LocalQueues found: $LQ_COUNT"
    fi
else
    log_info "Kueue not installed"
fi

# ============================================
# 7. Apollo Components
# ============================================
log_info "========== Apollo Components =========="

# Check Apollo namespace
if kubectl get namespace apollo &>/dev/null; then
    run_check check_namespace "apollo"

    # Insight Scope
    if kubectl get deployment insight-scope -n apollo &>/dev/null; then
        run_check check_deployment "apollo" "insight-scope"
        run_check check_service "apollo" "insight-scope"
    fi

    # Insight Trace
    if kubectl get deployment insight-trace -n apollo &>/dev/null; then
        run_check check_deployment "apollo" "insight-trace"
        run_check check_service "apollo" "insight-trace"
    fi

    # Node Resource Forecaster
    if kubectl get deployment node-resource-forecaster -n apollo &>/dev/null; then
        run_check check_deployment "apollo" "node-resource-forecaster"
        run_check check_service "apollo" "node-resource-forecaster"
    fi

    # Orchestration Policy Engine
    if kubectl get deployment orchestration-policy-engine -n apollo &>/dev/null; then
        run_check check_deployment "apollo" "orchestration-policy-engine"
    fi

    # Check Apollo CRDs
    run_check check_crd "orchestrationpolicies.apollo.keti.re.kr"
else
    log_info "Apollo namespace not found"
fi

# Check KETI namespace (ai-storage-scheduler)
if kubectl get namespace keti &>/dev/null; then
    run_check check_namespace "keti"

    if kubectl get deployment ai-storage-scheduler -n keti &>/dev/null; then
        run_check check_deployment "keti" "ai-storage-scheduler"
    fi
fi

# Check kube-system for orchestrator
if kubectl get deployment ai-storage-orchestrator -n kube-system &>/dev/null; then
    run_check check_deployment "kube-system" "ai-storage-orchestrator"
    run_check check_service "kube-system" "ai-storage-orchestrator"
fi

# ============================================
# 8. Integration Tests
# ============================================
log_info "========== Integration Tests =========="

# Test ArgoCD -> Kubeflow integration
if kubectl get namespace argocd &>/dev/null && kubectl get namespace kubeflow &>/dev/null; then
    log_info "ArgoCD + Kubeflow integration possible"
fi

# Test Kueue -> Kubeflow integration
if kubectl get namespace kueue-system &>/dev/null && kubectl get namespace kubeflow &>/dev/null; then
    # Check if Kueue is configured for Kubeflow workloads
    if kubectl get clusterqueue -o yaml 2>/dev/null | grep -q "pytorchjob\|tfjob"; then
        log_info "Kueue configured for Kubeflow workloads"
    else
        log_info "Kueue installed but may need Kubeflow workload configuration"
    fi
fi

# Test Apollo component connectivity
if kubectl get service insight-scope -n apollo &>/dev/null; then
    INSIGHT_SCOPE_IP=$(kubectl get service insight-scope -n apollo -o jsonpath='{.spec.clusterIP}')
    log_info "Insight Scope service available at: $INSIGHT_SCOPE_IP:8080"
fi

if kubectl get service ai-storage-orchestrator -n kube-system &>/dev/null; then
    ORCHESTRATOR_IP=$(kubectl get service ai-storage-orchestrator -n kube-system -o jsonpath='{.spec.clusterIP}')
    log_info "AI Storage Orchestrator service available at: $ORCHESTRATOR_IP:8080"
fi

# ============================================
# Summary
# ============================================
echo ""
log_info "=========================================="
log_info "           VERIFICATION SUMMARY          "
log_info "=========================================="
echo ""
log_info "Total Checks:  $TOTAL_CHECKS"
log_info "Passed:        $PASSED_CHECKS"
log_info "Failed:        $FAILED_CHECKS"
echo ""

if [ "$FAILED_CHECKS" -eq 0 ]; then
    log_info "All checks passed! System is ready."
    echo ""
    log_info "Quick Access URLs:"

    # ArgoCD URL
    if kubectl get service argocd-server -n argocd &>/dev/null; then
        ARGOCD_PORT=$(kubectl get service argocd-server -n argocd -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "")
        if [ -n "$ARGOCD_PORT" ]; then
            log_info "  ArgoCD: https://<node-ip>:$ARGOCD_PORT"
        fi
    fi

    # Kubeflow URL
    if kubectl get service istio-ingressgateway -n istio-system &>/dev/null; then
        KF_PORT=$(kubectl get service istio-ingressgateway -n istio-system -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}' 2>/dev/null || echo "")
        if [ -n "$KF_PORT" ]; then
            log_info "  Kubeflow: http://<node-ip>:$KF_PORT"
        fi
    fi

    exit 0
else
    log_error "Some checks failed. Please review the errors above."
    echo ""
    log_info "Troubleshooting commands:"
    log_info "  kubectl get pods -A | grep -v Running"
    log_info "  kubectl describe pod <pod-name> -n <namespace>"
    log_info "  kubectl logs <pod-name> -n <namespace>"
    exit 1
fi
