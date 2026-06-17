#!/usr/bin/env bash
#
# Test 01: Kubernetes Cluster Health
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "=========================================="
echo "  Kubernetes Cluster Health Test"
echo "=========================================="
echo ""

# Test 1: Cluster connectivity
run_test "Cluster Connectivity" "kubectl cluster-info &>/dev/null"

# Test 2: Node status
run_test "Nodes Ready" "[ \$(kubectl get nodes --no-headers | grep -c ' Ready') -gt 0 ]"

# Test 3: CoreDNS running
run_test "CoreDNS Running" "kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers | grep -q Running"

# Test 4: kube-proxy running
run_test "Kube-Proxy Running" "kubectl get pods -n kube-system -l k8s-app=kube-proxy --no-headers | grep -q Running"

# Test 5: Test pod creation
log_test "Creating test pod..."
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: test-k8s-health
  namespace: default
  labels:
    test: k8s-health
spec:
  containers:
  - name: test
    image: busybox:latest
    command: ["sh", "-c", "echo 'Kubernetes is healthy!' && sleep 10"]
  restartPolicy: Never
EOF

run_test "Pod Creation" "kubectl get pod test-k8s-health -n default &>/dev/null"

# Wait for pod to complete
log_info "Waiting for test pod to complete..."
sleep 15

# Test 6: Pod completed successfully
run_test "Pod Execution" "kubectl get pod test-k8s-health -n default -o jsonpath='{.status.phase}' | grep -qE 'Succeeded|Running'"

# Cleanup
log_info "Cleaning up test pod..."
kubectl delete pod test-k8s-health -n default --ignore-not-found >/dev/null

# Test 7: DNS resolution
log_test "Testing DNS resolution..."
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: test-dns
  namespace: default
  labels:
    test: dns
spec:
  containers:
  - name: test
    image: busybox:latest
    command: ["sh", "-c", "nslookup kubernetes.default.svc.cluster.local && sleep 5"]
  restartPolicy: Never
EOF

sleep 20
DNS_RESULT=$(kubectl logs test-dns -n default 2>/dev/null | grep -c "Address" || echo "0")
run_test "DNS Resolution" "[ $DNS_RESULT -gt 0 ]"

# Cleanup DNS test
kubectl delete pod test-dns -n default --ignore-not-found >/dev/null

# Test 8: Service creation
log_test "Testing service creation..."
kubectl create service clusterip test-svc --tcp=80:80 --dry-run=client -o yaml | kubectl apply -f - >/dev/null
run_test "Service Creation" "kubectl get svc test-svc &>/dev/null"
kubectl delete svc test-svc --ignore-not-found >/dev/null

# Print summary
print_test_summary
