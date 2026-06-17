#!/bin/bash
# ============================================================================
# 04. Install Storage Components
# - NFS Server (if not external)
# - NFS Client Provisioner
# - Default StorageClass
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="04-storage"
source "$SCRIPT_DIR/common.sh"

# Configuration
NFS_SERVER="${NFS_SERVER:-}"
NFS_PATH="${NFS_PATH:-/data/nfs}"
STORAGE_CLASS_NAME="nfs-client"

print_header "Step 4: Install Storage Components"

check_root

# ============================================================================
# Verify Kubernetes is Ready
# ============================================================================
log_step "Verifying Kubernetes cluster..."

check_command kubectl || { log_error "kubectl not found"; exit 1; }

if ! kubectl get nodes &>/dev/null; then
    log_error "Cannot connect to Kubernetes cluster"
    exit 1
fi

# ============================================================================
# NFS Server Setup (Optional - if running on master)
# ============================================================================
log_step "Configuring NFS..."

if [ -z "$NFS_SERVER" ]; then
    echo ""
    echo -e "${YELLOW}NFS Server Configuration${NC}"
    echo "1) Install NFS server on this node"
    echo "2) Use existing external NFS server"
    echo ""
    read -p "Select option [1/2]: " nfs_option

    case "$nfs_option" in
        1)
            log_step "Installing NFS server on this node..."

            run_cmd "Install NFS server" "apt-get install -y nfs-kernel-server"

            # Create NFS directory
            mkdir -p "$NFS_PATH"
            chmod 777 "$NFS_PATH"

            # Configure exports
            echo "$NFS_PATH *(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports

            run_cmd "Export NFS shares" "exportfs -rav"
            run_cmd "Enable NFS server" "systemctl enable nfs-kernel-server"
            run_cmd "Start NFS server" "systemctl start nfs-kernel-server"

            NFS_SERVER=$(hostname -I | awk '{print $1}')
            log_success "NFS server configured: $NFS_SERVER:$NFS_PATH"
            ;;
        2)
            read -p "Enter NFS server IP: " NFS_SERVER
            read -p "Enter NFS path [$NFS_PATH]: " input_path
            NFS_PATH="${input_path:-$NFS_PATH}"
            ;;
        *)
            log_error "Invalid option"
            exit 1
            ;;
    esac
fi

# ============================================================================
# Install NFS Client on All Nodes
# ============================================================================
log_step "Installing NFS client..."

run_cmd "Install NFS client" "apt-get install -y nfs-common"

# Test NFS mount
log_step "Testing NFS connection..."
run_cmd_allow_fail "Test NFS mount" "showmount -e $NFS_SERVER"

# ============================================================================
# Install NFS Client Provisioner
# ============================================================================
log_step "Installing NFS Client Provisioner..."

# Add Helm repo
run_cmd_allow_fail "Add NFS provisioner Helm repo" \
    "helm repo add nfs-subdir-external-provisioner https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/"

run_cmd "Update Helm repos" "helm repo update"

# Install NFS provisioner
run_cmd "Install NFS Client Provisioner" \
    "helm upgrade --install nfs-subdir-external-provisioner nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
    --namespace kube-system \
    --set nfs.server=$NFS_SERVER \
    --set nfs.path=$NFS_PATH \
    --set storageClass.name=$STORAGE_CLASS_NAME \
    --set storageClass.defaultClass=true \
    --set storageClass.reclaimPolicy=Retain"

# Wait for provisioner to be ready
log_info "Waiting for NFS provisioner to be ready..."
sleep 10
run_cmd_allow_fail "Wait for NFS provisioner" \
    "kubectl wait --for=condition=Ready pods -l app=nfs-subdir-external-provisioner -n kube-system --timeout=120s"

# ============================================================================
# Verify StorageClass
# ============================================================================
log_step "Verifying StorageClass..."

kubectl get storageclass

# ============================================================================
# Test PVC Creation
# ============================================================================
log_step "Testing PVC creation..."

cat > /tmp/test-pvc.yaml << EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: $STORAGE_CLASS_NAME
  resources:
    requests:
      storage: 1Gi
EOF

run_cmd "Create test PVC" "kubectl apply -f /tmp/test-pvc.yaml"

log_info "Waiting for PVC to be bound..."
sleep 5

PVC_STATUS=$(kubectl get pvc test-pvc -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")

if [ "$PVC_STATUS" = "Bound" ]; then
    log_success "Test PVC bound successfully"
    run_cmd "Delete test PVC" "kubectl delete pvc test-pvc"
else
    log_warn "Test PVC status: $PVC_STATUS (may take longer to bind)"
fi

# ============================================================================
# Summary
# ============================================================================
SUMMARY_ITEMS=(
    "NFS Server: $NFS_SERVER"
    "NFS Path: $NFS_PATH"
    "StorageClass: $STORAGE_CLASS_NAME (default)"
)

print_summary "Storage Configuration" "${SUMMARY_ITEMS[@]}"

# Save configuration
cat > /root/nfs-config.env << EOF
NFS_SERVER=$NFS_SERVER
NFS_PATH=$NFS_PATH
STORAGE_CLASS_NAME=$STORAGE_CLASS_NAME
EOF

log_info "NFS configuration saved to /root/nfs-config.env"

print_footer "success" "Storage Installation"

log_info ""
log_info "Next step: Run 05.install-argocd.sh"
log_info ""
