#!/bin/bash
# ============================================================================
# 02. Install Kubernetes Components
# - kubeadm
# - kubelet
# - kubectl
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="02-kubernetes"
source "$SCRIPT_DIR/common.sh"

# Kubernetes version
K8S_VERSION="1.30"

print_header "Step 2: Install Kubernetes Components"

check_root

# ============================================================================
# Verify Prerequisites
# ============================================================================
log_step "Verifying prerequisites..."

check_command docker || { log_error "Docker not found. Run 01.install-prerequisites.sh first"; exit 1; }
check_service containerd || { log_error "Containerd not running"; exit 1; }

# Check swap is disabled
if [ "$(swapon --show | wc -l)" -gt 0 ]; then
    log_warn "Swap is still enabled, disabling..."
    run_cmd "Disable swap" "swapoff -a"
fi

# ============================================================================
# Add Kubernetes Repository
# ============================================================================
log_step "Adding Kubernetes repository..."

# Create keyrings directory
run_cmd "Create keyrings directory" "mkdir -p /etc/apt/keyrings"

# Download Kubernetes GPG key
run_cmd "Download Kubernetes GPG key" \
    "curl -fsSL https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg"

# Add Kubernetes repository
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list > /dev/null

log_success "Kubernetes repository added"

# ============================================================================
# Install Kubernetes Components
# ============================================================================
log_step "Installing Kubernetes components..."

run_cmd "Update apt cache" "apt-get update"

# Install kubeadm, kubelet, kubectl
run_cmd "Install kubeadm, kubelet, kubectl" \
    "apt-get install -y kubelet kubeadm kubectl"

# Hold packages to prevent automatic updates
run_cmd "Hold Kubernetes packages" \
    "apt-mark hold kubelet kubeadm kubectl"

# ============================================================================
# Enable kubelet
# ============================================================================
log_step "Enabling kubelet service..."

run_cmd "Enable kubelet" "systemctl enable kubelet"

# ============================================================================
# Configure crictl
# ============================================================================
log_step "Configuring crictl..."

cat > /etc/crictl.yaml << EOF
runtime-endpoint: unix:///var/run/containerd/containerd.sock
image-endpoint: unix:///var/run/containerd/containerd.sock
timeout: 10
debug: false
EOF

log_success "crictl configured"

# ============================================================================
# Verify Installation
# ============================================================================
log_step "Verifying installation..."

run_cmd "Verify kubeadm" "kubeadm version"
run_cmd "Verify kubelet" "kubelet --version"
run_cmd "Verify kubectl" "kubectl version --client"

# ============================================================================
# Summary
# ============================================================================
KUBEADM_VERSION=$(kubeadm version -o short 2>/dev/null)
KUBELET_VERSION=$(kubelet --version 2>/dev/null | awk '{print $2}')
KUBECTL_VERSION=$(kubectl version --client -o yaml 2>/dev/null | grep gitVersion | awk '{print $2}')

INSTALLED_ITEMS=(
    "kubeadm: $KUBEADM_VERSION"
    "kubelet: $KUBELET_VERSION"
    "kubectl: $KUBECTL_VERSION"
)

print_summary "Installed Kubernetes Components" "${INSTALLED_ITEMS[@]}"

print_footer "success" "Kubernetes Components Installation"

log_info ""
log_info "Next step:"
log_info "  - For MASTER node: Run 03.init-cluster-master.sh"
log_info "  - For WORKER node: Run 03.join-cluster-worker.sh (after master is ready)"
log_info ""
