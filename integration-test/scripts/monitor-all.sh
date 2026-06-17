#!/bin/bash
# ============================================
# 통합 모니터링 스크립트
# insight-scope (정적분석) + insight-trace (동적분석) + APOLLO (통합)
# ============================================

NAMESPACE=${1:-"ai-workload-test"}

echo "╔════════════════════════════════════════════════════════════════════════════╗"
echo "║     통합 분석 모니터링 (Static + Dynamic + APOLLO)                         ║"
echo "║     Namespace: $NAMESPACE                                                  ║"
echo "╚════════════════════════════════════════════════════════════════════════════╝"
echo ""

# Port forwards 설정
echo "🔧 Setting up port forwards..."
pkill -f "port-forward.*insight-scope" 2>/dev/null
pkill -f "port-forward.*apollo-policy-server.*8080" 2>/dev/null
sleep 1

kubectl port-forward -n keti svc/insight-scope 8081:8081 &>/dev/null &
PF_SCOPE=$!
kubectl port-forward -n keti svc/apollo-policy-server 8080:8080 &>/dev/null &
PF_APOLLO=$!
sleep 3

trap "kill $PF_SCOPE $PF_APOLLO 2>/dev/null; exit" INT TERM

# 실행 중인 Pod 목록
PODS=$(kubectl get pods -n $NAMESPACE --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

for POD in $PODS; do
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📦 POD: $POD"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # =====================
    # 1. INSIGHT-SCOPE (정적 분석)
    # =====================
    echo ""
    echo "┌─────────────────────────────────────────────────────────────────────────┐"
    echo "│ 📊 INSIGHT-SCOPE (정적 YAML 분석)                                       │"
    echo "└─────────────────────────────────────────────────────────────────────────┘"

    SCOPE_RESULT=$(curl -s "http://localhost:8081/api/v1/scope/pod/$NAMESPACE/$POD" 2>/dev/null)
    if [ -n "$SCOPE_RESULT" ] && [ "$SCOPE_RESULT" != "null" ]; then
        echo "$SCOPE_RESULT" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if 'error' in data:
        print(f'  ❌ Error: {data[\"error\"]}')
    else:
        # AI Model Detection
        model = data.get('detected_model', {})
        if model:
            print(f'  [AI Model Detection]')
            print(f'    Model Type: {model.get(\"model_type\", \"N/A\")}')
            print(f'    Category: {model.get(\"category\", \"N/A\")}')
            print(f'    Confidence: {model.get(\"confidence\", 0):.2f}')
            print(f'    Detection Source: {model.get(\"detection_source\", \"N/A\")}')

        # Workload Analysis
        workload = data.get('workload_analysis', {})
        if workload:
            print(f'  ')
            print(f'  [Workload Analysis]')
            print(f'    Workload Type: {workload.get(\"workload_type\", \"N/A\")}')
            print(f'    Framework: {workload.get(\"framework\", \"N/A\")}')
            print(f'    Pipeline Stage: {workload.get(\"pipeline_stage\", \"N/A\")}')

        # Storage Recommendation
        storage = data.get('storage_recommendation', {})
        if storage:
            print(f'  ')
            print(f'  [Storage Recommendation]')
            print(f'    Storage Class: {storage.get(\"storage_class\", \"N/A\")}')
            print(f'    Storage Size: {storage.get(\"storage_size\", \"N/A\")}')
            print(f'    IOPS: {storage.get(\"iops\", \"N/A\")}')
            print(f'    Throughput: {storage.get(\"throughput_mbps\", \"N/A\")} MB/s')
            print(f'    Cache Tier: {storage.get(\"cache_tier\", \"N/A\")}')

        # Image Analysis
        images = data.get('image_analysis', [])
        if images:
            print(f'  ')
            print(f'  [Image Analysis]')
            for img in images:
                print(f'    - Image: {img.get(\"image\", \"N/A\")}')
                if img.get('framework'):
                    print(f'      Framework: {img.get(\"framework\")}')
except Exception as e:
    print(f'  ⚠️  Parse error: {e}')
" 2>/dev/null || echo "  ⚠️  insight-scope 응답 없음"
    else
        echo "  ⚠️  insight-scope에서 데이터 없음"
    fi

    # =====================
    # 2. INSIGHT-TRACE (동적 분석) - HTTP API 사용
    # =====================
    echo ""
    echo "┌─────────────────────────────────────────────────────────────────────────┐"
    echo "│ 🔍 INSIGHT-TRACE (동적 런타임 분석)                                     │"
    echo "└─────────────────────────────────────────────────────────────────────────┘"

    # insight-trace 사이드카의 HTTP API 직접 조회 (9090 포트)
    TRACE_RESULT=$(kubectl exec -n $NAMESPACE $POD -c insight-trace -- wget -qO- http://localhost:9090/metrics 2>/dev/null)
    if [ -n "$TRACE_RESULT" ]; then
        echo "$TRACE_RESULT" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)

    print(f'  [Detection Results]')
    print(f'    Workload Type: {data.get(\"workload_type\", \"N/A\").upper()}')
    print(f'    Framework: {data.get(\"framework\", \"N/A\")}')
    print(f'    I/O Pattern: {data.get(\"io_pattern\", \"N/A\")}')
    print(f'    Pipeline Stage: {data.get(\"current_stage\", \"N/A\")}')
    print(f'    GPU Workload: {data.get(\"is_gpu_workload\", False)}')

    # Recommendations
    rec = data.get('recommendations', {})
    if rec:
        print(f'  ')
        print(f'  [Storage Recommendations]')
        print(f'    Storage Class: {rec.get(\"storage_class\", \"N/A\")}')
        print(f'    Storage Size: {rec.get(\"storage_size\", \"N/A\")}')
        print(f'    IOPS: {rec.get(\"iops\", \"N/A\")}')
        print(f'    Throughput: {rec.get(\"throughput\", \"N/A\")} MB/s')

    # Current Metrics
    metrics = data.get('current_metrics', {})
    if metrics:
        print(f'  ')
        print(f'  [Runtime Metrics]')
        print(f'    CPU Usage: {metrics.get(\"cpu_usage_percent\", 0):.2f}%')
        print(f'    Memory Usage: {metrics.get(\"memory_usage_percent\", 0):.2f}%')
        print(f'    Memory RSS: {metrics.get(\"memory_rss_bytes\", 0) / 1024 / 1024:.2f} MB')
        print(f'    Disk Read: {metrics.get(\"disk_read_bytes_per_sec\", 0) / 1024:.2f} KB/s')
        print(f'    Disk Write: {metrics.get(\"disk_write_bytes_per_sec\", 0) / 1024:.2f} KB/s')
        print(f'    Network RX: {metrics.get(\"network_rx_bytes_per_sec\", 0) / 1024:.2f} KB/s')
        print(f'    Network TX: {metrics.get(\"network_tx_bytes_per_sec\", 0) / 1024:.2f} KB/s')
except Exception as e:
    print(f'  ⚠️  Parse error: {e}')
" 2>/dev/null
    else
        echo "  ⚠️  insight-trace 사이드카 없거나 응답 없음"
    fi

    # =====================
    # 3. APOLLO (수신된 WorkloadSignature)
    # =====================
    echo ""
    echo "┌─────────────────────────────────────────────────────────────────────────┐"
    echo "│ 📡 APOLLO (수신된 WorkloadSignature)                                    │"
    echo "└─────────────────────────────────────────────────────────────────────────┘"

    APOLLO_KEY="$NAMESPACE/$POD"
    APOLLO_RESULT=$(curl -s "http://localhost:8080/api/v1/data/workloads" 2>/dev/null)
    if [ -n "$APOLLO_RESULT" ]; then
        echo "$APOLLO_RESULT" | python3 -c "
import sys, json
key = '$APOLLO_KEY'
try:
    data = json.load(sys.stdin)
    if key in data:
        sig = data[key]
        wt = {0:'UNKNOWN', 1:'IMAGE', 2:'TEXT', 3:'TABULAR', 4:'AUDIO', 5:'VIDEO', 6:'MULTIMODAL'}.get(sig.get('workload_type', 0), 'UNKNOWN')
        iop = {0:'UNKNOWN', 1:'READ_HEAVY', 2:'WRITE_HEAVY', 3:'BALANCED', 4:'SEQUENTIAL', 5:'RANDOM', 6:'BURSTY'}.get(sig.get('io_pattern', 0), 'UNKNOWN')

        print(f'  [WorkloadSignature]')
        print(f'    Workload Type: {wt}')
        print(f'    Framework: {sig.get(\"framework\", \"N/A\")}')
        print(f'    I/O Pattern: {iop}')
        print(f'    GPU Workload: {sig.get(\"is_gpu_workload\", False)}')
        print(f'    Confidence: {sig.get(\"confidence\", 0):.2f}')

        metrics = sig.get('current_metrics', {})
        if metrics:
            print(f'  ')
            print(f'  [Received Metrics]')
            print(f'    CPU Usage: {metrics.get(\"cpu_usage_percent\", 0):.2f}%')
            print(f'    Memory Usage: {metrics.get(\"memory_usage_percent\", 0):.2f}%')
            print(f'    Read IOPS: {metrics.get(\"read_iops\", 0)}')
            print(f'    Write IOPS: {metrics.get(\"write_iops\", 0)}')
            print(f'    Read Throughput: {metrics.get(\"read_throughput_mbps\", 0):.2f} MB/s')
            print(f'    Write Throughput: {metrics.get(\"write_throughput_mbps\", 0):.2f} MB/s')
    else:
        print(f'  ⚠️  APOLLO에 해당 Pod 데이터 없음')
except Exception as e:
    print(f'  ⚠️  APOLLO 데이터 파싱 오류: {e}')
" 2>/dev/null
    else
        echo "  ⚠️  APOLLO API 응답 없음"
    fi
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ 모니터링 완료: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# Cleanup
kill $PF_SCOPE $PF_APOLLO 2>/dev/null
