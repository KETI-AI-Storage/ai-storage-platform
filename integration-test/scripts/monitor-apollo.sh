#!/bin/bash
# ============================================
# APOLLO WorkloadSignature 모니터링 스크립트
# Summary 제외하고 상세 정보만 표시
# ============================================

MODE=${1:-"logs"}  # logs 또는 api

echo "╔════════════════════════════════════════════════════════════════════════════╗"
echo "║     APOLLO WorkloadSignature Monitor (Detailed View)                       ║"
echo "║     Usage: ./monitor-apollo.sh [logs|api]                                  ║"
echo "║     Ctrl+C to stop                                                         ║"
echo "╚════════════════════════════════════════════════════════════════════════════╝"
echo ""

if [ "$MODE" == "api" ]; then
    # API 모드: port-forward 후 HTTP API로 조회
    echo "Starting port-forward..."
    kubectl port-forward -n keti svc/apollo-policy-server 8080:8080 &
    PF_PID=$!
    sleep 3

    trap "kill $PF_PID 2>/dev/null; exit" INT TERM

    while true; do
        clear
        echo "=== $(date '+%Y-%m-%d %H:%M:%S') - APOLLO Workload Monitor (API) ==="
        echo ""
        echo "📊 현재 저장된 WorkloadSignature:"
        echo "────────────────────────────────────────────────────────────────────"
        curl -s http://localhost:8080/api/v1/data/workloads 2>/dev/null | \
            python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for key, sig in data.items():
        wt = {0:'UNKNOWN', 1:'IMAGE', 2:'TEXT', 3:'TABULAR', 4:'AUDIO', 6:'MULTIMODAL'}.get(sig.get('workload_type', 0), 'UNKNOWN')
        iop = {0:'UNKNOWN', 1:'READ_HEAVY', 2:'WRITE_HEAVY', 3:'BALANCED', 4:'SEQUENTIAL', 5:'RANDOM', 6:'BURSTY'}.get(sig.get('io_pattern', 0), 'UNKNOWN')
        metrics = sig.get('current_metrics', {})
        print(f\"Pod: {key}\")
        print(f\"  Type: {wt}, Framework: {sig.get('framework', 'N/A')}, Confidence: {sig.get('confidence', 0):.2f}\")
        print(f\"  I/O: {iop}, GPU: {sig.get('is_gpu_workload', False)}\")
        if metrics:
            print(f\"  CPU: {metrics.get('cpu_usage_percent', 0):.2f}%, Memory: {metrics.get('memory_usage_percent', 0):.2f}%\")
        print()
except:
    print('No data')
"
        echo ""
        echo "Next refresh in 10s... (Ctrl+C to stop)"
        sleep 10
    done
else
    # 로그 모드: kubectl logs 필터링
    echo "📺 실시간 WorkloadSignature 수신 로그 (Summary 제외):"
    echo "────────────────────────────────────────────────────────────────────"
    kubectl logs -n keti -l app.kubernetes.io/name=apollo-policy-server -f 2>/dev/null | \
        grep -v "Monitor Summary" | \
        grep -v "Uptime:" | \
        grep -v "received$" | \
        grep -v "═══════" | \
        grep -v "╔═════" | \
        grep -v "╠═════" | \
        grep -v "╚═════" | \
        grep -v "║.*received"
fi
