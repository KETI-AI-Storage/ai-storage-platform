#!/usr/bin/env bash
#
# Common utilities for component tests
#

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_test() {
    echo -e "${BLUE}[TEST]${NC} $1"
}

log_step() {
    echo -e "${CYAN}[STEP]${NC} $1"
}

# Test functions
run_test() {
    local test_name="$1"
    local test_cmd="$2"

    TESTS_RUN=$((TESTS_RUN + 1))
    log_test "Running: $test_name"

    if eval "$test_cmd"; then
        log_info "PASSED: $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        log_error "FAILED: $test_name"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

print_test_summary() {
    echo ""
    echo "=========================================="
    echo "           TEST SUMMARY"
    echo "=========================================="
    echo "Tests Run:    $TESTS_RUN"
    echo -e "Passed:       ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Failed:       ${RED}$TESTS_FAILED${NC}"
    echo "=========================================="

    if [ "$TESTS_FAILED" -eq 0 ]; then
        log_info "All tests passed!"
        return 0
    else
        log_error "Some tests failed"
        return 1
    fi
}

# Wait for pod to be ready
wait_for_pod_ready() {
    local namespace=$1
    local label=$2
    local timeout=${3:-120}

    log_info "Waiting for pod with label '$label' in namespace '$namespace'..."
    kubectl wait --for=condition=Ready pod -l "$label" -n "$namespace" --timeout="${timeout}s" 2>/dev/null
}

# Wait for deployment to be ready
wait_for_deployment() {
    local namespace=$1
    local name=$2
    local timeout=${3:-120}

    log_info "Waiting for deployment '$name' in namespace '$namespace'..."
    kubectl rollout status deployment/"$name" -n "$namespace" --timeout="${timeout}s" 2>/dev/null
}

# Check if deployment is running
check_deployment_running() {
    local namespace=$1
    local name=$2

    local ready=$(kubectl get deployment "$name" -n "$namespace" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    local desired=$(kubectl get deployment "$name" -n "$namespace" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
    ready=${ready:-0}

    if [ "$ready" -ge "$desired" ] && [ "$desired" -gt 0 ]; then
        return 0
    else
        return 1
    fi
}

# Get service ClusterIP
get_service_ip() {
    local namespace=$1
    local name=$2

    kubectl get svc "$name" -n "$namespace" -o jsonpath='{.spec.clusterIP}' 2>/dev/null
}

# Create a test pod for curl requests
create_curl_pod() {
    local name=${1:-test-curl}
    local namespace=${2:-default}

    kubectl run "$name" --image=curlimages/curl:latest -n "$namespace" \
        --restart=Never --command -- sleep 3600 2>/dev/null || true

    # Wait for pod to be ready
    kubectl wait --for=condition=Ready pod/"$name" -n "$namespace" --timeout=60s 2>/dev/null
}

# Execute curl from test pod
exec_curl() {
    local pod_name=$1
    local namespace=$2
    local url=$3
    local method=${4:-GET}
    local data=${5:-}

    if [ -n "$data" ]; then
        kubectl exec "$pod_name" -n "$namespace" -- curl -s -X "$method" -H "Content-Type: application/json" -d "$data" "$url" 2>/dev/null
    else
        kubectl exec "$pod_name" -n "$namespace" -- curl -s -X "$method" "$url" 2>/dev/null
    fi
}

# Cleanup test pod
cleanup_curl_pod() {
    local name=${1:-test-curl}
    local namespace=${2:-default}

    kubectl delete pod "$name" -n "$namespace" --ignore-not-found --grace-period=0 --force 2>/dev/null
}

# Cleanup all test resources
cleanup_test_resources() {
    local namespace=$1
    local label=$2

    log_info "Cleaning up test resources with label '$label' in namespace '$namespace'..."
    kubectl delete all -l "$label" -n "$namespace" --ignore-not-found 2>/dev/null
}

# Create stress pod for resource testing
create_stress_pod() {
    local name=$1
    local namespace=$2
    local cpu_stress=${3:-1}
    local memory_stress=${4:-256}

    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: ${namespace}
  labels:
    test: stress
    app: stress-test
spec:
  containers:
  - name: stress
    image: polinux/stress
    command: ["stress"]
    args: ["--cpu", "${cpu_stress}", "--vm", "1", "--vm-bytes", "${memory_stress}M", "--timeout", "300s"]
    resources:
      requests:
        cpu: "100m"
        memory: "128Mi"
      limits:
        cpu: "500m"
        memory: "512Mi"
  restartPolicy: Never
EOF
}

# Check command exists
command_exists() {
    command -v "$1" &>/dev/null
}

# Print header
print_header() {
    local title=$1
    echo ""
    echo "=========================================="
    echo "  $title"
    echo "=========================================="
    echo ""
}
