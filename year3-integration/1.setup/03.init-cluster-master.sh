#!/bin/bash
# ============================================================================
# 03. Initialize Kubernetes Cluster (Master Node)
# - kubeadm init
# - CNI (Calico)
# - Metrics Server
# - NFS Provisioner
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="03-cluster-master"
source "$SCRIPT_DIR/common.sh"

# Configuration
POD_NETWORK_CIDR="10.244.0.0/16"
SERVICE_CIDR="10.96.0.0/12"
MASTER_IP="${MASTER_IP:-$(hostname -I | awk '{print $1}')}"
CLUSTER_NAME="keti-ai-storage"

print_header "Step 3: Initialize Kubernetes Cluster (Master)"

check_root

# ============================================================================
# Verify Prerequisites
# ============================================================================
log_step "Verifying prerequisites..."

check_command kubeadm || { log_error "kubeadm not found. Run 02.install-kubernetes.sh first"; exit 1; }
check_command kubelet || { log_error "kubelet not found"; exit 1; }
check_service containerd || { log_error "Containerd not running"; exit 1; }

# ============================================================================
# Initialize Cluster
# ============================================================================
log_step "Initializing Kubernetes cluster..."
log_info "Master IP: $MASTER_IP"
log_info "Pod Network CIDR: $POD_NETWORK_CIDR"
log_info "Service CIDR: $SERVICE_CIDR"

# Check if already initialized
if [ -f /etc/kubernetes/admin.conf ]; then
    log_warn "Cluster already initialized. Skipping kubeadm init..."
else
    run_cmd "Initialize cluster with kubeadm" \
        "kubeadm init --pod-network-cidr=$POD_NETWORK_CIDR --service-cidr=$SERVICE_CIDR --apiserver-advertise-address=$MASTER_IP"
fi

# ============================================================================
# Configure kubectl for root user
# ============================================================================
log_step "Configuring kubectl for root user..."

mkdir -p /root/.kube
cp -f /etc/kubernetes/admin.conf /root/.kube/config
chown root:root /root/.kube/config

export KUBECONFIG=/root/.kube/config

log_success "kubectl configured"

# ============================================================================
# Wait for API Server
# ============================================================================
log_step "Waiting for API server to be ready..."

for i in {1..30}; do
    if kubectl get nodes &>/dev/null; then
        log_success "API server is ready"
        break
    fi
    log_info "Waiting for API server... ($i/30)"
    sleep 5
done

# ============================================================================
# Install CNI (Calico)
# ============================================================================
log_step "Installing Calico CNI..."

CALICO_VERSION="v3.27.0"

run_cmd "Download Calico manifest" \
    "curl -fsSL https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml -o /tmp/calico.yaml"

# Modify CIDR if needed
sed -i "s|192.168.0.0/16|${POD_NETWORK_CIDR}|g" /tmp/calico.yaml

run_cmd "Apply Calico CNI" "kubectl apply -f /tmp/calico.yaml"

log_info "Waiting for Calico pods to be ready..."
sleep 30
run_cmd_allow_fail "Wait for Calico" \
    "kubectl wait --for=condition=Ready pods -l k8s-app=calico-node -n kube-system --timeout=300s"

# ============================================================================
# Remove Master Taint (Single Node Cluster Option)
# ============================================================================
log_step "Checking if this is a single-node cluster..."

read -p "Remove master taint to allow scheduling pods on master? [y/N]: " response
if [[ "$response" =~ ^[yY]$ ]]; then
    run_cmd_allow_fail "Remove master taint" \
        "kubectl taint nodes --all node-role.kubernetes.io/control-plane-"
    log_info "Master taint removed - pods can be scheduled on master node"
fi

# ============================================================================
# Install Metrics Server
# ============================================================================
log_step "Installing Metrics Server..."

run_cmd "Download Metrics Server manifest" \
    "curl -fsSL https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml -o /tmp/metrics-server.yaml"

# Add --kubelet-insecure-tls flag for self-signed certs
sed -i '/- --metric-resolution/a\        - --kubelet-insecure-tls' /tmp/metrics-server.yaml

run_cmd "Apply Metrics Server" "kubectl apply -f /tmp/metrics-server.yaml"

# ============================================================================
# Create Namespaces
# ============================================================================
log_step "Creating namespaces..."

NAMESPACES=(
    "apollo"
    "keti"
    "kubeflow"
    "argocd"
    "kueue-system"
)

for ns in "${NAMESPACES[@]}"; do
    run_cmd_allow_fail "Create namespace $ns" "kubectl create namespace $ns"
done

# ============================================================================
# Label Master Node
# ============================================================================
log_step "Labeling master node..."

MASTER_NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')

run_cmd_allow_fail "Label master as orchestration layer" \
    "kubectl label nodes $MASTER_NODE layer=orchestration --overwrite"

# ============================================================================
# Generate Join Command
# ============================================================================
log_step "Generating worker join command..."

JOIN_CMD=$(kubeadm token create --print-join-command 2>/dev/null)
JOIN_FILE="/root/worker-join-command.sh"

cat > "$JOIN_FILE" << EOF
#!/bin/bash
# Worker node join command
# Generated at: $(date)
# Valid for 24 hours

$JOIN_CMD
EOF

chmod +x "$JOIN_FILE"

log_success "Join command saved to: $JOIN_FILE"

# ============================================================================
# Verify Cluster
# ============================================================================
log_step "Verifying cluster status..."

echo ""
kubectl get nodes -o wide
echo ""
kubectl get pods -A
echo ""

# ============================================================================
# Summary
# ============================================================================
SUMMARY_ITEMS=(
    "Master IP: $MASTER_IP"
    "Pod Network: $POD_NETWORK_CIDR"
    "Service Network: $SERVICE_CIDR"
    "CNI: Calico $CALICO_VERSION"
    "Join command: $JOIN_FILE"
)

print_summary "Cluster Information" "${SUMMARY_ITEMS[@]}"

print_footer "success" "Kubernetes Cluster Initialization"

log_info ""
log_info "Next steps:"
log_info "  1. On WORKER nodes: Copy and run $JOIN_FILE"
log_info "  2. Run 04.install-storage.sh to set up NFS provisioner"
log_info "  3. Run 05.install-argocd.sh to install ArgoCD"
log_info ""
