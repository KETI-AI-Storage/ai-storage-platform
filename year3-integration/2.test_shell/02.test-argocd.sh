#!/usr/bin/env bash
#
# Test 02: ArgoCD Installation and Functionality
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "=========================================="
echo "  ArgoCD Installation Test"
echo "=========================================="
echo ""

# Check if ArgoCD is installed
if ! kubectl get namespace argocd &>/dev/null; then
    log_warn "ArgoCD namespace not found. Skipping ArgoCD tests."
    exit 0
fi

# Test 1: ArgoCD namespace exists
run_test "ArgoCD Namespace" "kubectl get namespace argocd &>/dev/null"

# Test 2: ArgoCD Server running
run_test "ArgoCD Server Running" "kubectl get deployment argocd-server -n argocd -o jsonpath='{.status.readyReplicas}' | grep -qE '^[1-9]'"

# Test 3: ArgoCD Repo Server running
run_test "ArgoCD Repo Server Running" "kubectl get deployment argocd-repo-server -n argocd -o jsonpath='{.status.readyReplicas}' | grep -qE '^[1-9]'"

# Test 4: ArgoCD Application Controller running
run_test "ArgoCD App Controller Running" "kubectl get deployment argocd-application-controller -n argocd -o jsonpath='{.status.readyReplicas}' | grep -qE '^[1-9]' 2>/dev/null || kubectl get statefulset argocd-application-controller -n argocd -o jsonpath='{.status.readyReplicas}' | grep -qE '^[1-9]'"

# Test 5: ArgoCD CRDs installed
run_test "Application CRD" "kubectl get crd applications.argoproj.io &>/dev/null"
run_test "AppProject CRD" "kubectl get crd appprojects.argoproj.io &>/dev/null"
run_test "ApplicationSet CRD" "kubectl get crd applicationsets.argoproj.io &>/dev/null"

# Test 6: ArgoCD Service accessible
run_test "ArgoCD Server Service" "kubectl get svc argocd-server -n argocd &>/dev/null"

# Test 7: Default AppProject exists
run_test "Default AppProject" "kubectl get appproject default -n argocd &>/dev/null"

# Test 8: Create test Application
log_test "Creating test ArgoCD Application..."
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: test-argocd-app
  namespace: argocd
  labels:
    test: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/argoproj/argocd-example-apps.git
    targetRevision: HEAD
    path: guestbook
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: false
      selfHeal: false
EOF

run_test "Application Creation" "kubectl get application test-argocd-app -n argocd &>/dev/null"

# Wait for application to sync
log_info "Waiting for application to sync (this may take a while)..."
sleep 30

# Test 9: Application status
APP_HEALTH=$(kubectl get application test-argocd-app -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
log_info "Application health status: $APP_HEALTH"
run_test "Application Processed" "[ '$APP_HEALTH' != '' ]"

# Cleanup
log_info "Cleaning up test application..."
kubectl delete application test-argocd-app -n argocd --ignore-not-found >/dev/null
kubectl delete all -l app=guestbook -n default --ignore-not-found >/dev/null 2>&1

# Test 10: ArgoCD CLI (if available)
if command_exists argocd; then
    run_test "ArgoCD CLI Available" "argocd version --client &>/dev/null"
else
    log_info "ArgoCD CLI not installed (optional)"
fi

# Print admin password location
log_info ""
log_info "ArgoCD Admin Password:"
log_info "  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"

# Print summary
print_test_summary
