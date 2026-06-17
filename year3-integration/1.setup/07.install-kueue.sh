#!/bin/bash
# ============================================================================
# 07. Install Kueue
# - Kueue Controller
# - ClusterQueue Configuration
# - ResourceFlavor for GPU
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="07-kueue"
source "$SCRIPT_DIR/common.sh"

# Configuration
KUEUE_VERSION="v0.6.2"
KUEUE_NAMESPACE="kueue-system"

print_header "Step 7: Install Kueue"

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
# Install Kueue
# ============================================================================
log_step "Installing Kueue $KUEUE_VERSION..."

KUEUE_MANIFEST="https://github.com/kubernetes-sigs/kueue/releases/download/${KUEUE_VERSION}/manifests.yaml"

run_cmd "Download Kueue manifest" "curl -fsSL $KUEUE_MANIFEST -o /tmp/kueue-manifests.yaml"
run_cmd "Apply Kueue manifest" "kubectl apply --server-side -f /tmp/kueue-manifests.yaml"

# ============================================================================
# Wait for Kueue to be Ready
# ============================================================================
log_step "Waiting for Kueue controller to be ready..."

sleep 10

run_cmd_allow_fail "Wait for Kueue controller" \
    "kubectl rollout status deployment/kueue-controller-manager -n $KUEUE_NAMESPACE --timeout=300s"

# ============================================================================
# Create ResourceFlavors
# ============================================================================
log_step "Creating ResourceFlavors..."

cat > /tmp/kueue-resource-flavors.yaml << 'EOF'
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: ResourceFlavor
metadata:
  name: default-flavor
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: ResourceFlavor
metadata:
  name: gpu-flavor
spec:
  nodeLabels:
    nvidia.com/gpu: "present"
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: ResourceFlavor
metadata:
  name: csd-flavor
spec:
  nodeLabels:
    layer: storage
EOF

run_cmd "Apply ResourceFlavors" "kubectl apply -f /tmp/kueue-resource-flavors.yaml"

# ============================================================================
# Create ClusterQueue
# ============================================================================
log_step "Creating ClusterQueue..."

cat > /tmp/kueue-cluster-queue.yaml << 'EOF'
apiVersion: kueue.x-k8s.io/v1beta1
kind: ClusterQueue
metadata:
  name: keti-cluster-queue
spec:
  namespaceSelector: {}
  queueingStrategy: BestEffortFIFO
  resourceGroups:
  - coveredResources: ["cpu", "memory"]
    flavors:
    - name: default-flavor
      resources:
      - name: "cpu"
        nominalQuota: 100
      - name: "memory"
        nominalQuota: 256Gi
  - coveredResources: ["nvidia.com/gpu"]
    flavors:
    - name: gpu-flavor
      resources:
      - name: "nvidia.com/gpu"
        nominalQuota: 8
EOF

run_cmd "Apply ClusterQueue" "kubectl apply -f /tmp/kueue-cluster-queue.yaml"

# ============================================================================
# Create LocalQueue for AI Workloads
# ============================================================================
log_step "Creating LocalQueues..."

# Create LocalQueue in default namespace
cat > /tmp/kueue-local-queue-default.yaml << 'EOF'
apiVersion: kueue.x-k8s.io/v1beta1
kind: LocalQueue
metadata:
  namespace: default
  name: ai-workload-queue
spec:
  clusterQueue: keti-cluster-queue
EOF

# Create LocalQueue in kubeflow namespace
cat > /tmp/kueue-local-queue-kubeflow.yaml << 'EOF'
apiVersion: kueue.x-k8s.io/v1beta1
kind: LocalQueue
metadata:
  namespace: kubeflow
  name: ai-workload-queue
spec:
  clusterQueue: keti-cluster-queue
EOF

run_cmd "Apply LocalQueue (default)" "kubectl apply -f /tmp/kueue-local-queue-default.yaml"
run_cmd_allow_fail "Apply LocalQueue (kubeflow)" "kubectl apply -f /tmp/kueue-local-queue-kubeflow.yaml"

# ============================================================================
# Enable Kubeflow Integration
# ============================================================================
log_step "Configuring Kubeflow integration..."

# Patch Kueue config to enable integrations
cat > /tmp/kueue-config-patch.yaml << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: kueue-manager-config
  namespace: kueue-system
data:
  controller_manager_config.yaml: |
    apiVersion: config.kueue.x-k8s.io/v1beta1
    kind: Configuration
    health:
      healthProbeBindAddress: :8081
    metrics:
      bindAddress: :8080
    webhook:
      port: 9443
    leaderElection:
      leaderElect: true
      resourceName: c1f6bfd2.kueue.x-k8s.io
    controller:
      groupKindConcurrency:
        Job.batch: 5
        Pod: 5
        Workload.kueue.x-k8s.io: 5
        LocalQueue.kueue.x-k8s.io: 1
        ClusterQueue.kueue.x-k8s.io: 1
        ResourceFlavor.kueue.x-k8s.io: 1
    integrations:
      frameworks:
      - "batch/job"
      - "kubeflow.org/mpijob"
      - "kubeflow.org/mxjob"
      - "kubeflow.org/paddlejob"
      - "kubeflow.org/pytorchjob"
      - "kubeflow.org/tfjob"
      - "kubeflow.org/xgboostjob"
      - "ray.io/rayjob"
      - "ray.io/raycluster"
      - "jobset.x-k8s.io/jobset"
      podOptions:
        namespaceSelector:
          matchExpressions:
          - key: kubernetes.io/metadata.name
            operator: NotIn
            values: [ kube-system, kueue-system ]
EOF

run_cmd_allow_fail "Apply Kueue config" "kubectl apply -f /tmp/kueue-config-patch.yaml"

# Restart Kueue controller to pick up new config
run_cmd_allow_fail "Restart Kueue controller" \
    "kubectl rollout restart deployment/kueue-controller-manager -n $KUEUE_NAMESPACE"

# ============================================================================
# Verify Installation
# ============================================================================
log_step "Verifying Kueue installation..."

echo ""
echo "=== Kueue Pods ==="
kubectl get pods -n $KUEUE_NAMESPACE
echo ""
echo "=== ResourceFlavors ==="
kubectl get resourceflavors
echo ""
echo "=== ClusterQueues ==="
kubectl get clusterqueues
echo ""
echo "=== LocalQueues ==="
kubectl get localqueues -A
echo ""

# ============================================================================
# Summary
# ============================================================================
SUMMARY_ITEMS=(
    "Version: $KUEUE_VERSION"
    "Namespace: $KUEUE_NAMESPACE"
    "ClusterQueue: keti-cluster-queue"
    "ResourceFlavors: default-flavor, gpu-flavor, csd-flavor"
    "Kubeflow Integration: Enabled"
)

print_summary "Kueue Installation" "${SUMMARY_ITEMS[@]}"

print_footer "success" "Kueue Installation"

log_info ""
log_info "Kueue is now managing workload queues"
log_info "Submit jobs with: kueue.x-k8s.io/queue-name: ai-workload-queue annotation"
log_info ""
log_info "Next step: Run 08.install-apollo-components.sh"
log_info ""
