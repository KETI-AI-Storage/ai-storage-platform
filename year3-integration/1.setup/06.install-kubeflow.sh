#!/bin/bash
# ============================================================================
# 06. Install Kubeflow
# - Kubeflow Pipelines
# - Training Operator
# - Notebook Controller
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="06-kubeflow"
source "$SCRIPT_DIR/common.sh"

# Configuration
KUBEFLOW_VERSION="v1.8.0"
KUBEFLOW_NAMESPACE="kubeflow"

print_header "Step 6: Install Kubeflow"

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

# Check storage class
if ! kubectl get storageclass | grep -q "(default)"; then
    log_error "No default StorageClass found. Run 04.install-storage.sh first"
    exit 1
fi

# ============================================================================
# Install kustomize
# ============================================================================
log_step "Installing kustomize..."

if check_command kustomize; then
    log_info "kustomize already installed"
else
    KUSTOMIZE_VERSION="v5.3.0"
    run_cmd "Download kustomize" \
        "curl -s https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh | bash"
    run_cmd "Move kustomize" "mv kustomize /usr/local/bin/"
fi

run_cmd "Verify kustomize" "kustomize version"

# ============================================================================
# Clone Kubeflow Manifests
# ============================================================================
log_step "Cloning Kubeflow manifests..."

KUBEFLOW_DIR="/opt/kubeflow-manifests"

if [ -d "$KUBEFLOW_DIR" ]; then
    log_info "Kubeflow manifests directory exists, updating..."
    cd "$KUBEFLOW_DIR"
    run_cmd_allow_fail "Update manifests" "git pull"
else
    run_cmd "Clone Kubeflow manifests" \
        "git clone https://github.com/kubeflow/manifests.git $KUBEFLOW_DIR"
fi

cd "$KUBEFLOW_DIR"
run_cmd "Checkout version $KUBEFLOW_VERSION" "git checkout $KUBEFLOW_VERSION"

# ============================================================================
# Install Kubeflow Components
# ============================================================================
log_step "Installing Kubeflow components..."

echo ""
echo -e "${YELLOW}Kubeflow Installation Options${NC}"
echo "1) Full Kubeflow installation (all components)"
echo "2) Minimal installation (Pipelines + Training Operator only)"
echo ""
read -p "Select option [1/2]: " install_option

case "$install_option" in
    1)
        log_step "Installing full Kubeflow..."

        # This installs everything
        while ! kustomize build example | kubectl apply -f -; do
            log_warn "Retrying Kubeflow installation (some CRDs may need time)..."
            sleep 10
        done
        ;;
    2)
        log_step "Installing minimal Kubeflow (Pipelines + Training Operator)..."

        # Install cert-manager first
        log_info "Installing cert-manager..."
        run_cmd "Install cert-manager" \
            "kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml"

        sleep 30
        run_cmd_allow_fail "Wait for cert-manager" \
            "kubectl wait --for=condition=Available deployments --all -n cert-manager --timeout=300s"

        # Install Kubeflow Pipelines
        log_info "Installing Kubeflow Pipelines..."
        cd "$KUBEFLOW_DIR"

        run_cmd "Apply pipelines CRDs" \
            "kustomize build apps/pipeline/upstream/env/cert-manager/platform-agnostic-multi-user | kubectl apply -f -"

        # Install Training Operator
        log_info "Installing Training Operator..."
        run_cmd "Apply Training Operator" \
            "kustomize build apps/training-operator/upstream/overlays/kubeflow | kubectl apply -f -"
        ;;
    *)
        log_error "Invalid option"
        exit 1
        ;;
esac

# ============================================================================
# Wait for Kubeflow to be Ready
# ============================================================================
log_step "Waiting for Kubeflow components to be ready..."

log_info "This may take 5-10 minutes..."

# Create kubeflow namespace if not exists
run_cmd_allow_fail "Create kubeflow namespace" "kubectl create namespace $KUBEFLOW_NAMESPACE"

# Wait for key deployments
KEY_DEPLOYMENTS=(
    "ml-pipeline"
    "ml-pipeline-ui"
    "training-operator"
)

for deploy in "${KEY_DEPLOYMENTS[@]}"; do
    run_cmd_allow_fail "Wait for $deploy" \
        "kubectl rollout status deployment/$deploy -n $KUBEFLOW_NAMESPACE --timeout=300s"
done

# ============================================================================
# Configure Access
# ============================================================================
log_step "Configuring Kubeflow access..."

# Check for istio-ingressgateway
if kubectl get svc istio-ingressgateway -n istio-system &>/dev/null; then
    log_info "Istio ingress gateway found"

    # Patch to NodePort
    run_cmd_allow_fail "Patch istio-ingressgateway to NodePort" \
        "kubectl patch svc istio-ingressgateway -n istio-system -p '{\"spec\": {\"type\": \"NodePort\"}}'"

    INGRESS_PORT=$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}' 2>/dev/null)
    NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

    if [ -n "$INGRESS_PORT" ] && [ -n "$NODE_IP" ]; then
        KUBEFLOW_URL="http://${NODE_IP}:${INGRESS_PORT}"
    fi
else
    log_info "Istio not found, using port-forward for access"
    KUBEFLOW_URL="http://localhost:8080 (via port-forward)"
fi

# ============================================================================
# Save Access Information
# ============================================================================
KUBEFLOW_INFO="/root/kubeflow-info.txt"

cat > "$KUBEFLOW_INFO" << EOF
# Kubeflow Access Information
# Generated at: $(date)

Version: $KUBEFLOW_VERSION
Namespace: $KUBEFLOW_NAMESPACE
URL: ${KUBEFLOW_URL:-"Use port-forward"}

# Default credentials (if using Dex):
Email: user@example.com
Password: 12341234

# Port-forward commands:
# Kubeflow Dashboard:
kubectl port-forward svc/ml-pipeline-ui -n kubeflow 8080:80

# Kubeflow Pipelines API:
kubectl port-forward svc/ml-pipeline -n kubeflow 8888:8888
EOF

chmod 600 "$KUBEFLOW_INFO"

# ============================================================================
# Verify Installation
# ============================================================================
log_step "Verifying Kubeflow installation..."

echo ""
kubectl get pods -n $KUBEFLOW_NAMESPACE | head -20
echo ""
kubectl get svc -n $KUBEFLOW_NAMESPACE | head -10
echo ""

# ============================================================================
# Summary
# ============================================================================
SUMMARY_ITEMS=(
    "Version: $KUBEFLOW_VERSION"
    "Namespace: $KUBEFLOW_NAMESPACE"
    "URL: ${KUBEFLOW_URL:-Use port-forward}"
    "Manifests: $KUBEFLOW_DIR"
    "Info file: $KUBEFLOW_INFO"
)

print_summary "Kubeflow Installation" "${SUMMARY_ITEMS[@]}"

print_footer "success" "Kubeflow Installation"

log_info ""
log_info "Access Kubeflow:"
log_info "  URL: ${KUBEFLOW_URL:-Use port-forward}"
log_info "  See $KUBEFLOW_INFO for details"
log_info ""
log_info "Next step: Run 07.install-kueue.sh"
log_info ""
