#!/usr/bin/env bash
# training-job-workload 예시 JSON 출력 (예시 이미지와 동일 키)
# 사용: ./insight-hub-datadb-json.sh [namespace] [job-name]
set -euo pipefail

NS="${1:-k8s-admission-webhook}"
JOB="${2:-training-job-workload}"

cpu_to_millicores() {
  local x="${1:-}"
  [[ -z "$x" ]] && echo 0 && return
  case "$x" in
    *m) echo "${x%m}" ;;
    *n) echo 0 ;;
    *) awk -v c="$x" 'BEGIN{printf "%d", c*1000}' ;;
  esac
}

# 날짜·시간 하드코딩
TS="2026-03-25T01:09:32Z"
NODE="ai-storage-worker-01"
CPU_PCT=2
MEM_STR="72Mi"
GPU_PCT=0
IO_R="4MB/s"
IO_W="1MB/s"
WT="train"

POD="$(kubectl get pod -n "$NS" -l "job-name=${JOB}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -n "$POD" ]]; then
  N="$(kubectl get pod -n "$NS" "$POD" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
  [[ -n "$N" ]] && NODE="$N"

  if kubectl get pod -n "$NS" "$POD" -o json 2>/dev/null | grep -q 'nvidia.com/gpu'; then
    GPU_PCT=1
  fi

  TOP_LINE="$(kubectl top pod -n "$NS" "$POD" --no-headers 2>/dev/null | head -1 || true)"
  if [[ -n "${TOP_LINE:-}" ]]; then
    CPU_RAW="$(echo "$TOP_LINE" | awk '{print $2}')"
    MEM_RAW="$(echo "$TOP_LINE" | awk '{print $3}')"
    [[ -n "$MEM_RAW" ]] && MEM_STR="$MEM_RAW"
    REQ_CPU="$(kubectl get pod -n "$NS" "$POD" -o jsonpath='{.spec.containers[0].resources.requests.cpu}' 2>/dev/null || true)"
    if [[ -n "$REQ_CPU" && -n "$CPU_RAW" ]]; then
      REQ_M="$(cpu_to_millicores "$REQ_CPU")"
      USE_M="$(cpu_to_millicores "$CPU_RAW")"
      if [[ "$REQ_M" =~ ^[0-9]+$ && "$USE_M" =~ ^[0-9]+$ && "$REQ_M" -gt 0 ]]; then
        CPU_PCT=$(( (USE_M * 100 + REQ_M / 2) / REQ_M ))
        [[ "$CPU_PCT" -gt 100 ]] && CPU_PCT=100
      fi
    fi
  fi
fi

emit_json() {
  if command -v jq >/dev/null 2>&1; then
    jq -n \
      --arg node "$NODE" \
      --arg timestamp "$TS" \
      --argjson cpu_usage "$CPU_PCT" \
      --arg memory_usage "$MEM_STR" \
      --argjson gpu_usage "$GPU_PCT" \
      --arg io_read "$IO_R" \
      --arg io_write "$IO_W" \
      --arg workload_type "$WT" \
      '{node:$node,timestamp:$timestamp,cpu_usage:$cpu_usage,memory_usage:$memory_usage,gpu_usage:$gpu_usage,io_read:$io_read,io_write:$io_write,workload_type:$workload_type}'
    return
  fi
  if command -v python3 >/dev/null 2>&1; then
    export E_NODE="$NODE" E_TS="$TS" E_CPU="$CPU_PCT" E_MEM="$MEM_STR" E_GPU="$GPU_PCT" E_IR="$IO_R" E_IW="$IO_W" E_WT="$WT"
    python3 <<'PY'
import json, os
print(json.dumps({
    "node": os.environ["E_NODE"],
    "timestamp": os.environ["E_TS"],
    "cpu_usage": int(os.environ["E_CPU"]),
    "memory_usage": os.environ["E_MEM"],
    "gpu_usage": int(os.environ["E_GPU"]),
    "io_read": os.environ["E_IR"],
    "io_write": os.environ["E_IW"],
    "workload_type": os.environ["E_WT"],
}, ensure_ascii=False))
PY
    return
  fi
  printf '{"node":"%s","timestamp":"%s","cpu_usage":%s,"memory_usage":"%s","gpu_usage":%s,"io_read":"%s","io_write":"%s","workload_type":"%s"}\n' \
    "$NODE" "$TS" "$CPU_PCT" "$MEM_STR" "$GPU_PCT" "$IO_R" "$IO_W" "$WT"
}

emit_json
