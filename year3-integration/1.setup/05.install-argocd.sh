#!/bin/bash
# ============================================================================
# 05. Install ArgoCD
# - ArgoCD Server
# - ArgoCD CLI
# - Initial Configuration
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="05-argocd"
source "$SCRIPT_DIR/common.sh"

# Configuration
ARGOCD_NAMESPACE="argocd"
ARGOCD_VERSION="stable"

print_header "Step 5: Install ArgoCD"

check_root

# ============================================================================
# Verify Prerequisites
# ============================================================================
log_step "Verifying prerequisites..."

check_command kubectl || { log_error "kubectl not found"; exit 1; }

if ! kubectl get nodes &>/dev/null; then
    log_error "Cannot connect to Kubernetes cluster"
    exit 1
fi

# ============================================================================
# Create Namespace
# ============================================================================
log_step "Creating ArgoCD namespace..."

run_cmd_allow_fail "Create namespace" "kubectl create namespace $ARGOCD_NAMESPACE"

# ============================================================================
# Install ArgoCD
# ============================================================================
log_step "Installing ArgoCD..."

ARGOCD_MANIFEST="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

run_cmd "Download ArgoCD manifest" "curl -fsSL $ARGOCD_MANIFEST -o /tmp/argocd-install.yaml"
run_cmd "Apply ArgoCD manifest" "kubectl apply -n $ARGOCD_NAMESPACE -f /tmp/argocd-install.yaml"

# ============================================================================
# Wait for ArgoCD to be Ready
# ============================================================================
log_step "Waiting for ArgoCD components to be ready..."

log_info "This may take a few minutes..."

# Wait for deployments
ARGOCD_DEPLOYMENTS=(
    "argocd-server"
    "argocd-repo-server"
    "argocd-redis"
    "argocd-dex-server"
    "argocd-applicationset-controller"
    "argocd-notifications-controller"
)

for deploy in "${ARGOCD_DEPLOYMENTS[@]}"; do
    run_cmd_allow_fail "Wait for $deploy" \
        "kubectl rollout status deployment/$deploy -n $ARGOCD_NAMESPACE --timeout=300s"
done

# ============================================================================
# Install ArgoCD CLI
# ============================================================================
log_step "Installing ArgoCD CLI..."

if check_command argocd; then
    log_info "ArgoCD CLI already installed"
else
    ARGOCD_CLI_VERSION=$(curl -s https://api.github.com/repos/argoproj/argo-cd/releases/latest | grep tag_name | cut -d '"' -f 4)

    run_cmd "Download ArgoCD CLI" \
        "curl -sSL -o /tmp/argocd-linux-amd64 https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_CLI_VERSION}/argocd-linux-amd64"

    run_cmd "Install ArgoCD CLI" \
        "install -m 555 /tmp/argocd-linux-amd64 /usr/local/bin/argocd"

    run_cmd "Cleanup" "rm /tmp/argocd-linux-amd64"
fi

run_cmd "Verify ArgoCD CLI" "argocd version --client"

# ============================================================================
# Expose ArgoCD Server
# ============================================================================
log_step "Configuring ArgoCD server access..."

# Patch to use LoadBalancer or NodePort
echo ""
echo -e "${YELLOW}ArgoCD Server Access Configuration${NC}"
echo "1) NodePort (accessible via node IP:port)"
echo "2) LoadBalancer (if cloud provider available)"
echo "3) Keep ClusterIP (use port-forward)"
echo ""
read -p "Select option [1/2/3]: " access_option

case "$access_option" in
    1)
        run_cmd "Patch ArgoCD server to NodePort" \
            "kubectl patch svc argocd-server -n $ARGOCD_NAMESPACE -p '{\"spec\": {\"type\": \"NodePort\"}}'"
        ;;
    2)
        run_cmd "Patch ArgoCD server to LoadBalancer" \
            "kubectl patch svc argocd-server -n $ARGOCD_NAMESPACE -p '{\"spec\": {\"type\": \"LoadBalancer\"}}'"
        ;;
    *)
        log_info "Keeping ClusterIP. Use: kubectl port-forward svc/argocd-server -n argocd 8080:443"
        ;;
esac

# ============================================================================
# Get Initial Admin Password
# ============================================================================
log_step "Getting initial admin password..."

# Wait for secret to be created
sleep 5

ARGOCD_PASSWORD=$(kubectl -n $ARGOCD_NAMESPACE get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d)

if [ -z "$ARGOCD_PASSWORD" ]; then
    log_warn "Could not retrieve initial password. Try manually:"
    log_info "kubectl -n $ARGOCD_NAMESPACE get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
else
    log_success "Initial admin password retrieved"
fi

# ============================================================================
# Get Access URL
# ============================================================================
log_step "Getting ArgoCD access URL..."

ARGOCD_SVC=$(kubectl get svc argocd-server -n $ARGOCD_NAMESPACE -o jsonpath='{.spec.type}')
ARGOCD_URL=""

case "$ARGOCD_SVC" in
    NodePort)
        NODE_PORT=$(kubectl get svc argocd-server -n $ARGOCD_NAMESPACE -o jsonpath='{.spec.ports[0].nodePort}')
        NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
        ARGOCD_URL="https://${NODE_IP}:${NODE_PORT}"
        ;;
    LoadBalancer)
        EXTERNAL_IP=$(kubectl get svc argocd-server -n $ARGOCD_NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
        if [ -n "$EXTERNAL_IP" ]; then
            ARGOCD_URL="https://${EXTERNAL_IP}"
        else
            log_info "LoadBalancer IP pending. Check: kubectl get svc argocd-server -n $ARGOCD_NAMESPACE"
        fi
        ;;
    *)
        ARGOCD_URL="https://localhost:8080 (via port-forward)"
        ;;
esac

# ============================================================================
# Save Credentials
# ============================================================================
CREDENTIALS_FILE="/root/argocd-credentials.txt"

cat > "$CREDENTIALS_FILE" << EOF
# ArgoCD Credentials
# Generated at: $(date)

URL: $ARGOCD_URL
Username: admin
Password: $ARGOCD_PASSWORD

# To login via CLI:
# argocd login <server> --username admin --password '$ARGOCD_PASSWORD' --insecure

# To change password:
# argocd account update-password
EOF

chmod 600 "$CREDENTIALS_FILE"

log_success "Credentials saved to $CREDENTIALS_FILE"

# ============================================================================
# Verify Installation
# ============================================================================
log_step "Verifying ArgoCD installation..."

echo ""
kubectl get pods -n $ARGOCD_NAMESPACE
echo ""
kubectl get svc -n $ARGOCD_NAMESPACE
echo ""

# ============================================================================
# Summary
# ============================================================================
SUMMARY_ITEMS=(
    "Namespace: $ARGOCD_NAMESPACE"
    "URL: $ARGOCD_URL"
    "Username: admin"
    "Password: (saved in $CREDENTIALS_FILE)"
    "CLI: $(argocd version --client --short 2>/dev/null || echo 'installed')"
)

print_summary "ArgoCD Installation" "${SUMMARY_ITEMS[@]}"

print_footer "success" "ArgoCD Installation"

log_info ""
log_info "Access ArgoCD:"
log_info "  URL: $ARGOCD_URL"
log_info "  Username: admin"
log_info "  Password: (see $CREDENTIALS_FILE)"
log_info ""
log_info "Next step: Run 06.install-kubeflow.sh"
log_info ""
