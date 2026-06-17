#!/bin/bash
# ============================================================================
# 08. Install Apollo Components (KETI AI Storage Platform)
# - insight-scope (gRPC metrics collector)
# - insight-trace (distributed tracing)
# - node-resource-forecaster (LSTM-based prediction)
# - ai-storage-scheduler (custom K8s scheduler)
# - ai-storage-orchestrator (pod migration)
# - orchestration-policy-engine (policy-based automation)
#
# NOTE: All images are pulled from Docker Hub (ketidevit2/*)
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="08-apollo"
source "$SCRIPT_DIR/common.sh"

# Configuration
APOLLO_NAMESPACE="apollo"
KETI_NAMESPACE="keti"
DOCKER_REGISTRY="ketidevit2"
IMAGE_TAG="${IMAGE_TAG:-latest}"

print_header "Step 8: Install Apollo Components"

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
# Create Namespaces
# ============================================================================
log_step "Creating namespaces..."

run_cmd_allow_fail "Create apollo namespace" "kubectl create namespace $APOLLO_NAMESPACE"
run_cmd_allow_fail "Create keti namespace" "kubectl create namespace $KETI_NAMESPACE"

# ============================================================================
# Setup RBAC
# ============================================================================
log_step "Setting up RBAC..."

cat > /tmp/apollo-rbac.yaml << 'EOF'
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: apollo-service-account
  namespace: apollo
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: apollo-policy-engine
  namespace: apollo
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ai-storage-scheduler
  namespace: keti
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ai-storage-orchestrator
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: apollo-cluster-role
rules:
- apiGroups: [""]
  resources: ["pods", "nodes", "services", "endpoints", "persistentvolumeclaims", "events", "configmaps", "secrets", "namespaces"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: [""]
  resources: ["pods/log", "pods/status", "nodes/status", "pods/binding"]
  verbs: ["get", "list", "watch", "create", "update", "patch"]
- apiGroups: ["apps"]
  resources: ["deployments", "replicasets", "statefulsets", "daemonsets"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: ["batch"]
  resources: ["jobs", "cronjobs"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: ["metrics.k8s.io"]
  resources: ["pods", "nodes"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["apollo.keti.re.kr"]
  resources: ["*"]
  verbs: ["*"]
- apiGroups: ["coordination.k8s.io"]
  resources: ["leases"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: ["storage.k8s.io"]
  resources: ["storageclasses", "csinodes"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["autoscaling"]
  resources: ["horizontalpodautoscalers"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: apollo-cluster-role-binding
subjects:
- kind: ServiceAccount
  name: apollo-service-account
  namespace: apollo
- kind: ServiceAccount
  name: apollo-policy-engine
  namespace: apollo
- kind: ServiceAccount
  name: ai-storage-scheduler
  namespace: keti
- kind: ServiceAccount
  name: ai-storage-orchestrator
  namespace: kube-system
roleRef:
  kind: ClusterRole
  name: apollo-cluster-role
  apiGroup: rbac.authorization.k8s.io
EOF

run_cmd "Apply RBAC" "kubectl apply -f /tmp/apollo-rbac.yaml"

# ============================================================================
# Deploy insight-scope
# ============================================================================
log_step "Deploying insight-scope..."

cat > /tmp/insight-scope.yaml << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: insight-scope
  namespace: $APOLLO_NAMESPACE
  labels:
    app: insight-scope
spec:
  replicas: 1
  selector:
    matchLabels:
      app: insight-scope
  template:
    metadata:
      labels:
        app: insight-scope
    spec:
      serviceAccountName: apollo-service-account
      containers:
      - name: insight-scope
        image: ${DOCKER_REGISTRY}/insight-scope:${IMAGE_TAG}
        imagePullPolicy: Always
        ports:
        - containerPort: 50051
          name: grpc
        - containerPort: 9090
          name: metrics
        env:
        - name: GRPC_PORT
          value: "50051"
        - name: METRICS_PORT
          value: "9090"
        resources:
          requests:
            cpu: "100m"
            memory: "256Mi"
          limits:
            cpu: "500m"
            memory: "512Mi"
---
apiVersion: v1
kind: Service
metadata:
  name: insight-scope
  namespace: $APOLLO_NAMESPACE
spec:
  selector:
    app: insight-scope
  ports:
  - name: grpc
    port: 50051
    targetPort: 50051
  - name: metrics
    port: 9090
    targetPort: 9090
EOF

run_cmd "Deploy insight-scope" "kubectl apply -f /tmp/insight-scope.yaml"

# ============================================================================
# Deploy insight-trace
# ============================================================================
log_step "Deploying insight-trace..."

cat > /tmp/insight-trace.yaml << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: insight-trace
  namespace: $APOLLO_NAMESPACE
  labels:
    app: insight-trace
spec:
  replicas: 1
  selector:
    matchLabels:
      app: insight-trace
  template:
    metadata:
      labels:
        app: insight-trace
    spec:
      serviceAccountName: apollo-service-account
      containers:
      - name: insight-trace
        image: ${DOCKER_REGISTRY}/insight-trace:${IMAGE_TAG}
        imagePullPolicy: Always
        ports:
        - containerPort: 50052
          name: grpc
        - containerPort: 9091
          name: metrics
        env:
        - name: GRPC_PORT
          value: "50052"
        resources:
          requests:
            cpu: "100m"
            memory: "256Mi"
          limits:
            cpu: "500m"
            memory: "512Mi"
---
apiVersion: v1
kind: Service
metadata:
  name: insight-trace
  namespace: $APOLLO_NAMESPACE
spec:
  selector:
    app: insight-trace
  ports:
  - name: grpc
    port: 50052
    targetPort: 50052
  - name: metrics
    port: 9091
    targetPort: 9091
EOF

run_cmd "Deploy insight-trace" "kubectl apply -f /tmp/insight-trace.yaml"

# ============================================================================
# Deploy node-resource-forecaster
# ============================================================================
log_step "Deploying node-resource-forecaster..."

cat > /tmp/node-resource-forecaster.yaml << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: node-resource-forecaster
  namespace: $APOLLO_NAMESPACE
  labels:
    app: node-resource-forecaster
spec:
  replicas: 1
  selector:
    matchLabels:
      app: node-resource-forecaster
  template:
    metadata:
      labels:
        app: node-resource-forecaster
    spec:
      serviceAccountName: apollo-service-account
      containers:
      - name: node-resource-forecaster
        image: ${DOCKER_REGISTRY}/node-resource-forecaster:${IMAGE_TAG}
        imagePullPolicy: Always
        ports:
        - containerPort: 50055
          name: grpc
        - containerPort: 8080
          name: http
        env:
        - name: GRPC_PORT
          value: "50055"
        - name: HTTP_PORT
          value: "8080"
        - name: INSIGHT_SCOPE_ADDR
          value: "insight-scope.$APOLLO_NAMESPACE.svc.cluster.local:50051"
        resources:
          requests:
            cpu: "500m"
            memory: "1Gi"
          limits:
            cpu: "2000m"
            memory: "4Gi"
---
apiVersion: v1
kind: Service
metadata:
  name: node-resource-forecaster
  namespace: $APOLLO_NAMESPACE
spec:
  selector:
    app: node-resource-forecaster
  ports:
  - name: grpc
    port: 50055
    targetPort: 50055
  - name: http
    port: 8080
    targetPort: 8080
EOF

run_cmd "Deploy node-resource-forecaster" "kubectl apply -f /tmp/node-resource-forecaster.yaml"

# ============================================================================
# Deploy ai-storage-scheduler
# ============================================================================
log_step "Deploying ai-storage-scheduler..."

cat > /tmp/ai-storage-scheduler.yaml << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ai-storage-scheduler
  namespace: $KETI_NAMESPACE
  labels:
    app: ai-storage-scheduler
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ai-storage-scheduler
  template:
    metadata:
      labels:
        app: ai-storage-scheduler
    spec:
      serviceAccountName: ai-storage-scheduler
      containers:
      - name: ai-storage-scheduler
        image: ${DOCKER_REGISTRY}/keti-ai-storage-scheduler:${IMAGE_TAG}
        imagePullPolicy: Always
        ports:
        - containerPort: 10259
          name: https
        env:
        - name: SCHEDULER_NAME
          value: "ai-storage-scheduler"
        resources:
          requests:
            cpu: "100m"
            memory: "256Mi"
          limits:
            cpu: "500m"
            memory: "512Mi"
      nodeSelector:
        node-role.kubernetes.io/control-plane: ""
      tolerations:
      - key: "node-role.kubernetes.io/control-plane"
        operator: "Exists"
        effect: "NoSchedule"
EOF

run_cmd "Deploy ai-storage-scheduler" "kubectl apply -f /tmp/ai-storage-scheduler.yaml"

# ============================================================================
# Deploy ai-storage-orchestrator
# ============================================================================
log_step "Deploying ai-storage-orchestrator..."

cat > /tmp/ai-storage-orchestrator.yaml << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ai-storage-orchestrator
  namespace: kube-system
  labels:
    app: ai-storage-orchestrator
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ai-storage-orchestrator
  template:
    metadata:
      labels:
        app: ai-storage-orchestrator
    spec:
      serviceAccountName: ai-storage-orchestrator
      containers:
      - name: ai-storage-orchestrator
        image: ${DOCKER_REGISTRY}/ai-storage-orchestrator:${IMAGE_TAG}
        imagePullPolicy: Always
        ports:
        - containerPort: 8080
          name: http
        env:
        - name: PORT
          value: "8080"
        resources:
          requests:
            cpu: "100m"
            memory: "256Mi"
          limits:
            cpu: "500m"
            memory: "512Mi"
      nodeSelector:
        node-role.kubernetes.io/control-plane: ""
      tolerations:
      - key: "node-role.kubernetes.io/control-plane"
        operator: "Exists"
        effect: "NoSchedule"
---
apiVersion: v1
kind: Service
metadata:
  name: ai-storage-orchestrator
  namespace: kube-system
spec:
  selector:
    app: ai-storage-orchestrator
  ports:
  - name: http
    port: 8080
    targetPort: 8080
EOF

run_cmd "Deploy ai-storage-orchestrator" "kubectl apply -f /tmp/ai-storage-orchestrator.yaml"

# ============================================================================
# Deploy orchestration-policy-engine (CRD first)
# ============================================================================
log_step "Deploying orchestration-policy-engine..."

# Apply CRD
cat > /tmp/orchestration-policy-crd.yaml << 'EOF'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: orchestrationpolicies.apollo.keti.re.kr
spec:
  group: apollo.keti.re.kr
  names:
    kind: OrchestrationPolicy
    listKind: OrchestrationPolicyList
    plural: orchestrationpolicies
    singular: orchestrationpolicy
    shortNames:
    - op
    - ops
  scope: Namespaced
  versions:
  - name: v1
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
            properties:
              policyType:
                type: string
                enum: ["migration", "scaling", "provisioning", "caching", "loadbalance", "preemption"]
              probability:
                type: integer
                minimum: 0
                maximum: 100
              urgency:
                type: string
                enum: ["LOW", "MEDIUM", "HIGH", "CRITICAL"]
              resourceType:
                type: string
                enum: ["CPU", "MEMORY", "GPU", "STORAGE_IO"]
              targetNode:
                type: string
              sourceNode:
                type: string
              targetWorkload:
                type: string
              targetNamespace:
                type: string
              reason:
                type: string
              horizon:
                type: integer
              autoExecute:
                type: boolean
              priorityScore:
                type: integer
              parameters:
                type: object
                additionalProperties:
                  type: string
          status:
            type: object
            properties:
              phase:
                type: string
              message:
                type: string
              result:
                type: string
              executedAt:
                type: string
                format: date-time
              completedAt:
                type: string
                format: date-time
              executedBy:
                type: string
              conditions:
                type: array
                items:
                  type: object
                  properties:
                    type:
                      type: string
                    status:
                      type: string
                    reason:
                      type: string
                    message:
                      type: string
                    lastTransitionTime:
                      type: string
                      format: date-time
    additionalPrinterColumns:
    - name: Type
      type: string
      jsonPath: .spec.policyType
    - name: Urgency
      type: string
      jsonPath: .spec.urgency
    - name: Prob
      type: integer
      jsonPath: .spec.probability
    - name: Phase
      type: string
      jsonPath: .status.phase
    - name: Target
      type: string
      jsonPath: .spec.targetNode
    - name: Age
      type: date
      jsonPath: .metadata.creationTimestamp
    subresources:
      status: {}
EOF

run_cmd "Apply OrchestrationPolicy CRD" "kubectl apply -f /tmp/orchestration-policy-crd.yaml"

# Deploy controller
cat > /tmp/orchestration-policy-engine.yaml << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: orchestration-policy-engine
  namespace: $APOLLO_NAMESPACE
  labels:
    app: orchestration-policy-engine
    control-plane: controller-manager
spec:
  replicas: 1
  selector:
    matchLabels:
      app: orchestration-policy-engine
      control-plane: controller-manager
  template:
    metadata:
      labels:
        app: orchestration-policy-engine
        control-plane: controller-manager
    spec:
      serviceAccountName: apollo-policy-engine
      containers:
      - name: manager
        image: ${DOCKER_REGISTRY}/orchestration-policy-engine:${IMAGE_TAG}
        imagePullPolicy: Always
        args:
        - --leader-elect
        - --health-probe-bind-address=:8081
        - --metrics-bind-address=:8443
        - --forecaster-url=http://node-resource-forecaster.$APOLLO_NAMESPACE.svc.cluster.local:8080
        - --orchestrator-url=http://ai-storage-orchestrator.kube-system.svc.cluster.local:8080
        - --policy-namespace=$APOLLO_NAMESPACE
        - --enable-policy-generator=true
        - --auto-execute=false
        ports:
        - containerPort: 8443
          name: metrics
        - containerPort: 8081
          name: health
        livenessProbe:
          httpGet:
            path: /healthz
            port: 8081
          initialDelaySeconds: 15
          periodSeconds: 20
        readinessProbe:
          httpGet:
            path: /readyz
            port: 8081
          initialDelaySeconds: 5
          periodSeconds: 10
        resources:
          requests:
            cpu: "100m"
            memory: "256Mi"
          limits:
            cpu: "500m"
            memory: "512Mi"
      nodeSelector:
        node-role.kubernetes.io/control-plane: ""
      tolerations:
      - key: "node-role.kubernetes.io/control-plane"
        operator: "Exists"
        effect: "NoSchedule"
EOF

run_cmd "Deploy orchestration-policy-engine" "kubectl apply -f /tmp/orchestration-policy-engine.yaml"

# ============================================================================
# Wait for All Pods
# ============================================================================
log_step "Waiting for all pods to be ready..."

sleep 30

log_info "Checking pod status..."

echo ""
echo "=== Apollo Namespace ==="
kubectl get pods -n $APOLLO_NAMESPACE -o wide
echo ""
echo "=== Keti Namespace ==="
kubectl get pods -n $KETI_NAMESPACE -o wide
echo ""
echo "=== kube-system (ai-storage-orchestrator) ==="
kubectl get pods -n kube-system -l app=ai-storage-orchestrator -o wide
echo ""

# ============================================================================
# Verify Services
# ============================================================================
log_step "Verifying services..."

echo ""
echo "=== Services ==="
kubectl get svc -n $APOLLO_NAMESPACE
kubectl get svc -n kube-system -l app=ai-storage-orchestrator
echo ""

# ============================================================================
# Verify CRDs
# ============================================================================
log_step "Verifying CRDs..."

echo ""
kubectl get crd | grep -E "orchestrationpolicies" || echo "CRD not found"
echo ""

# ============================================================================
# Summary
# ============================================================================
APOLLO_RUNNING=$(kubectl get pods -n $APOLLO_NAMESPACE --no-headers 2>/dev/null | grep -c Running || echo 0)
APOLLO_TOTAL=$(kubectl get pods -n $APOLLO_NAMESPACE --no-headers 2>/dev/null | wc -l)
KETI_RUNNING=$(kubectl get pods -n $KETI_NAMESPACE --no-headers 2>/dev/null | grep -c Running || echo 0)
KETI_TOTAL=$(kubectl get pods -n $KETI_NAMESPACE --no-headers 2>/dev/null | wc -l)

SUMMARY_ITEMS=(
    "Docker Registry: $DOCKER_REGISTRY"
    "Image Tag: $IMAGE_TAG"
    ""
    "Apollo namespace: $APOLLO_RUNNING/$APOLLO_TOTAL running"
    "Keti namespace: $KETI_RUNNING/$KETI_TOTAL running"
    ""
    "Components:"
    "  - insight-scope (metrics collection)"
    "  - insight-trace (distributed tracing)"
    "  - node-resource-forecaster (LSTM prediction)"
    "  - ai-storage-scheduler (custom scheduler)"
    "  - ai-storage-orchestrator (pod migration)"
    "  - orchestration-policy-engine (policy automation)"
)

print_summary "Apollo Components" "${SUMMARY_ITEMS[@]}"

print_footer "success" "Apollo Components Installation"

log_info ""
log_info "All images pulled from Docker Hub: $DOCKER_REGISTRY/*"
log_info ""
log_info "Verify with:"
log_info "  kubectl get pods -n apollo"
log_info "  kubectl get pods -n keti"
log_info "  kubectl get orchestrationpolicies -A"
log_info ""
log_info "Next step: Run 09.verify-integration.sh"
log_info ""
