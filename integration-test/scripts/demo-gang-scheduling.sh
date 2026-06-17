#!/bin/bash
# ============================================
# Kueue Gang Scheduling Demo
# ============================================
# 자원 점유 → 해제 → Gang Scheduling 발동 데모
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(dirname "$SCRIPT_DIR")"
NAMESPACE="ai-workload-test"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

clear_line() { echo -ne "\033[2K\r"; }

print_box() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC} ${BOLD}$1${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
}

# ============================================
# Step 1: Setup
# ============================================
setup() {
    print_box "Step 1: Setup Namespace & LocalQueue"

    kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null
    echo -e "${GREEN}✓${NC} Namespace '$NAMESPACE' ready"

    # LocalQueue 확인/생성
    if ! kubectl get localqueue -n $NAMESPACE ai-storage-queue &> /dev/null; then
        echo -e "${YELLOW}!${NC} Creating LocalQueue..."
        kubectl apply -f - <<EOF
apiVersion: kueue.x-k8s.io/v1beta1
kind: LocalQueue
metadata:
  name: ai-storage-queue
  namespace: $NAMESPACE
spec:
  clusterQueue: ai-storage-cluster-queue
EOF
    fi
    echo -e "${GREEN}✓${NC} LocalQueue ready"

    # 기존 jobs 정리
    kubectl delete jobs -n $NAMESPACE --all --wait=false 2>/dev/null || true
    sleep 2
}

# ============================================
# Step 2: Deploy Blocker (큰 자원 요청)
# ============================================
deploy_blocker() {
    print_box "Step 2: Deploy Resource Blocker (CPU: 14, MEM: 28Gi)"

    echo -e "${YELLOW}!${NC} ClusterQueue 제한: CPU 16, Memory 32Gi"
    echo -e "${YELLOW}!${NC} Blocker 요청: CPU 14, Memory 28Gi"
    echo -e "${YELLOW}!${NC} 남는 자원: CPU 2, Memory 4Gi (Gang jobs 실행 불가)"
    echo ""

    kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: resource-blocker
  namespace: $NAMESPACE
  labels:
    kueue.x-k8s.io/queue-name: ai-storage-queue
    purpose: blocker
spec:
  parallelism: 1
  completions: 1
  template:
    metadata:
      labels:
        purpose: blocker
    spec:
      restartPolicy: Never
      containers:
      - name: blocker
        image: busybox:latest
        command: ["sh", "-c", "echo 'Blocking 14 CPU, 28Gi MEM...'; sleep 3600"]
        resources:
          requests:
            cpu: "14"
            memory: "28Gi"
          limits:
            cpu: "14"
            memory: "28Gi"
  backoffLimit: 0
EOF

    echo ""
    echo -e "${YELLOW}⏳${NC} Waiting for blocker to start..."

    local timeout=60
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        status=$(kubectl get pods -n $NAMESPACE -l purpose=blocker -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
        if [ "$status" = "Running" ]; then
            echo -e "${GREEN}✓${NC} Resource Blocker is RUNNING"
            break
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    echo ""
    kubectl get pods -n $NAMESPACE -l purpose=blocker -o wide
}

# ============================================
# Step 3: Deploy Gang Jobs (will be queued)
# ============================================
deploy_gang_jobs() {
    print_box "Step 3: Deploy Gang Jobs (총 CPU 6 요청 → 대기 예상)"

    echo -e "${YELLOW}!${NC} Gang Jobs 요청: Master(2 CPU) + Worker1(2 CPU) + Worker2(2 CPU) = 6 CPU"
    echo -e "${YELLOW}!${NC} 현재 남은 자원: 2 CPU (부족!)"
    echo ""

    kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: gang-demo-master
  namespace: $NAMESPACE
  labels:
    kueue.x-k8s.io/queue-name: ai-storage-queue
    gang-group: demo-training
    role: master
spec:
  parallelism: 1
  completions: 1
  template:
    metadata:
      labels:
        gang-group: demo-training
        role: master
    spec:
      restartPolicy: Never
      containers:
      - name: master
        image: busybox:latest
        command: ["sh", "-c", "echo '=== MASTER ===' && echo 'Started:' && date && sleep 10 && echo 'Done'"]
        resources:
          requests:
            cpu: "2"
            memory: "1Gi"
  backoffLimit: 2
---
apiVersion: batch/v1
kind: Job
metadata:
  name: gang-demo-worker-1
  namespace: $NAMESPACE
  labels:
    kueue.x-k8s.io/queue-name: ai-storage-queue
    gang-group: demo-training
    role: worker
spec:
  parallelism: 1
  completions: 1
  template:
    metadata:
      labels:
        gang-group: demo-training
        role: worker
    spec:
      restartPolicy: Never
      containers:
      - name: worker
        image: busybox:latest
        command: ["sh", "-c", "echo '=== WORKER-1 ===' && echo 'Started:' && date && sleep 10 && echo 'Done'"]
        resources:
          requests:
            cpu: "2"
            memory: "1Gi"
  backoffLimit: 2
---
apiVersion: batch/v1
kind: Job
metadata:
  name: gang-demo-worker-2
  namespace: $NAMESPACE
  labels:
    kueue.x-k8s.io/queue-name: ai-storage-queue
    gang-group: demo-training
    role: worker
spec:
  parallelism: 1
  completions: 1
  template:
    metadata:
      labels:
        gang-group: demo-training
        role: worker
    spec:
      restartPolicy: Never
      containers:
      - name: worker
        image: busybox:latest
        command: ["sh", "-c", "echo '=== WORKER-2 ===' && echo 'Started:' && date && sleep 10 && echo 'Done'"]
        resources:
          requests:
            cpu: "2"
            memory: "1Gi"
  backoffLimit: 2
EOF

    sleep 3
}

# ============================================
# Step 4: Show Queued State
# ============================================
show_queued_state() {
    print_box "Step 4: 현재 상태 확인"

    echo ""
    echo -e "${BOLD}Jobs:${NC}"
    kubectl get jobs -n $NAMESPACE

    echo ""
    echo -e "${BOLD}Pods:${NC}"
    kubectl get pods -n $NAMESPACE -o wide

    echo ""
    echo -e "${BOLD}Kueue Workloads:${NC}"
    kubectl get workloads -n $NAMESPACE 2>/dev/null || echo "(none)"

    echo ""
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}예상 상태:${NC}"
    echo -e "  ${GREEN}● resource-blocker${NC}   : Running (14 CPU 점유)"
    echo -e "  ${YELLOW}○ gang-demo-master${NC}   : Suspended/Pending (대기)"
    echo -e "  ${YELLOW}○ gang-demo-worker-1${NC} : Suspended/Pending (대기)"
    echo -e "  ${YELLOW}○ gang-demo-worker-2${NC} : Suspended/Pending (대기)"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ============================================
# Step 5: Delete Blocker & Watch
# ============================================
release_and_watch() {
    print_box "Step 5: Blocker 삭제 → Gang Scheduling 발동!"

    echo ""
    echo -e "${RED}${BOLD}>>> kubectl delete job resource-blocker${NC}"
    kubectl delete job resource-blocker -n $NAMESPACE --wait=false

    echo ""
    echo -e "${CYAN}${BOLD}>>> Watching...${NC}"
    echo ""

    local timeout=60
    local elapsed=0

    while [ $elapsed -lt $timeout ]; do
        running=$(kubectl get pods -n $NAMESPACE -l gang-group=demo-training --no-headers 2>/dev/null | grep -c "Running" || echo "0")
        completed=$(kubectl get pods -n $NAMESPACE -l gang-group=demo-training --no-headers 2>/dev/null | grep -c "Completed" || echo "0")

        echo -ne "\r  Gang Pods - Running: $running, Completed: $completed (${elapsed}s)   "

        if [ "$running" -ge 3 ] || [ "$completed" -ge 1 ]; then
            echo ""
            echo -e "${GREEN}${BOLD}✓ Gang Scheduling 발동!${NC}"
            break
        fi

        sleep 1
        elapsed=$((elapsed + 1))
    done

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    kubectl get pods -n $NAMESPACE -l gang-group=demo-training -o wide
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ============================================
# Cleanup
# ============================================
cleanup() {
    print_box "Cleanup"
    kubectl delete jobs -n $NAMESPACE --all --wait=false 2>/dev/null
    echo -e "${GREEN}✓${NC} Done"
}

# ============================================
# Main
# ============================================
main() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}     ${BOLD}KUEUE GANG SCHEDULING DEMO${NC}                               ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"

    case "${1:-}" in
        "cleanup")
            cleanup
            ;;
        "status")
            kubectl get pods -n $NAMESPACE -o wide
            kubectl get jobs -n $NAMESPACE
            ;;
        *)
            setup
            deploy_blocker
            sleep 2
            deploy_gang_jobs
            sleep 2
            show_queued_state

            echo ""
            echo -e "${YELLOW}${BOLD}Press ENTER to delete blocker...${NC}"
            read -r

            release_and_watch

            echo ""
            print_box "Demo Complete!"
            echo "  Run '$0 cleanup' to clean up"
            echo ""
            ;;
    esac
}

main "$@"
