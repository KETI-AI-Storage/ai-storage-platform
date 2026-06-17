#!/bin/bash
# ============================================================================
# 03. Join Kubernetes Cluster (Worker Node)
# - Join existing cluster
# - Label node
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="03-cluster-worker"
source "$SCRIPT_DIR/common.sh"

print_header "Step 3: Join Kubernetes Cluster (Worker)"

check_root

# ============================================================================
# Verify Prerequisites
# ============================================================================
log_step "Verifying prerequisites..."

check_command kubeadm || { log_error "kubeadm not found. Run 02.install-kubernetes.sh first"; exit 1; }
check_command kubelet || { log_error "kubelet not found"; exit 1; }
check_service containerd || { log_error "Containerd not running"; exit 1; }

# ============================================================================
# Get Join Command
# ============================================================================
log_step "Getting join command..."

echo ""
echo -e "${YELLOW}You need the join command from the master node.${NC}"
echo -e "On the master node, run: ${CYAN}cat /root/worker-join-command.sh${NC}"
echo ""

read -p "Enter the join command (kubeadm join ...): " JOIN_COMMAND

if [ -z "$JOIN_COMMAND" ]; then
    log_error "Join command is required"
    exit 1
fi

# ============================================================================
# Join Cluster
# ============================================================================
log_step "Joining cluster..."

if echo "$JOIN_COMMAND" | grep -q "kubeadm join"; then
    run_cmd "Join cluster" "$JOIN_COMMAND"
else
    log_error "Invalid join command. Must start with 'kubeadm join'"
    exit 1
fi

# ============================================================================
# Verify Join
# ============================================================================
log_step "Verifying node joined cluster..."

log_info "Waiting for node to be registered..."
sleep 10

# Try to get node status from kubelet
if systemctl is-active --quiet kubelet; then
    log_success "kubelet is running"
else
    log_error "kubelet is not running"
    run_cmd "Show kubelet status" "systemctl status kubelet"
    exit 1
fi

# ============================================================================
# Label Node (Optional)
# ============================================================================
echo ""
echo -e "${YELLOW}Node labeling should be done from the master node.${NC}"
echo ""
echo "To label this node as a worker, run on MASTER:"
echo -e "${CYAN}  kubectl label nodes $(hostname) layer=compute${NC}"
echo ""
echo "For storage nodes:"
echo -e "${CYAN}  kubectl label nodes $(hostname) layer=storage${NC}"
echo ""
echo "For GPU nodes:"
echo -e "${CYAN}  kubectl label nodes $(hostname) nvidia.com/gpu=present${NC}"
echo ""

# ============================================================================
# Summary
# ============================================================================
SUMMARY_ITEMS=(
    "Hostname: $(hostname)"
    "IP: $(hostname -I | awk '{print $1}')"
    "kubelet status: $(systemctl is-active kubelet)"
)

print_summary "Worker Node Information" "${SUMMARY_ITEMS[@]}"

print_footer "success" "Worker Node Join"

log_info ""
log_info "This node has joined the cluster."
log_info "Verify on master: kubectl get nodes"
log_info ""
