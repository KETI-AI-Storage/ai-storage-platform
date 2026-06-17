#!/usr/bin/env bash
# Insight Hub — scope → hub 적재 데이터 확인
#
# 아키텍처: insight-scope 가 gRPC(SubmitHistoryData)로 insight-hub 에 전송 → SQLite 저장
#
# 데이터 흐름:
#   insight-scope (DaemonSet, NODE_NAME=노드명) → MetricsCollector → ForecasterClient
#   → gRPC SubmitHistoryData → insight-hub → SQLite 테이블 resource_snapshots
#
# Hub에 들어가는 필드 (행 단위):
#   node_name, ts_unix_ms, cpu_util, mem_util, gpu_util, storage_io_util
#
# - 노드 집계: pod_namespace/pod_name 비어 있음 (전 노드 CPU·메모리 등)
# - Pod(워크로드) 구분: POD_METRICS_LABEL_SELECTOR 로 수집한 Pod는 Hub에 ns/name 키로 별도 저장
#
# 인자(노드 이름) 또는:
#   --job namespace/jobname   Job이 만든 Pod의 spec.nodeName 으로 조회 (training-job-workload 용)
#   --pod namespace/podname   해당 Pod가 떠 있는 노드로 조회
#
# 사용법:
#   ./check-hub-data.sh
#   ./check-hub-data.sh ai-storage-worker-01
#   ./check-hub-data.sh --job k8s-admission-webhook/training-job-workload
#   HUB_ADDR=127.0.0.1:50056 ./check-hub-data.sh
#
set -euo pipefail

HUB_NS="${HUB_NS:-keti}"
HUB_SVC="${HUB_SVC:-insight-hub}"
HUB_GRPC_PORT="${HUB_GRPC_PORT:-50056}"
HUB_ADDR="${HUB_ADDR:-${HUB_SVC}.${HUB_NS}.svc.cluster.local:${HUB_GRPC_PORT}}"
SQLITE_PATH="${SQLITE_PATH:-/data/insight-hub.db}"
GRPCURL_IMAGE="${GRPCURL_IMAGE:-fullstorydev/grpcurl:latest}"

NODE_FILTER=""
POD_REF=""
JOB_REF=""
JOB_POD_NS=""
JOB_POD_NAME=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pod)
      POD_REF="${2:-}"
      shift 2 || exit 1
      ;;
    --job)
      JOB_REF="${2:-}"
      shift 2 || exit 1
      ;;
    *)
      if [[ -n "${NODE_FILTER}" ]]; then
        echo "ERROR: 알 수 없는 인자: $1 (노드명은 하나만)" >&2
        exit 1
      fi
      NODE_FILTER="$1"
      shift
      ;;
  esac
done

resolve_pod_to_node() {
  kubectl get pod -n "$1" "$2" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true
}

resolve_job_to_node() {
  kubectl get pod -n "$1" -l "job-name=${2}" -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || true
}

if [[ -n "$POD_REF" ]]; then
  ns="${POD_REF%%/*}"
  name="${POD_REF#*/}"
  if [[ "$ns" == "$POD_REF" ]] || [[ -z "$name" ]]; then
    echo "ERROR: --pod 는 namespace/podname 형식이어야 합니다." >&2
    exit 1
  fi
  NODE_FILTER="$(resolve_pod_to_node "$ns" "$name")"
  if [[ -z "$NODE_FILTER" ]]; then
    echo "ERROR: Pod ${POD_REF} 을(를) 찾지 못했습니다." >&2
    exit 1
  fi
  JOB_POD_NS="$ns"
  JOB_POD_NAME="$name"
elif [[ -n "$JOB_REF" ]]; then
  ns="${JOB_REF%%/*}"
  jn="${JOB_REF#*/}"
  if [[ "$ns" == "$JOB_REF" ]] || [[ -z "$jn" ]]; then
    echo "ERROR: --job 은 namespace/jobname 형식이어야 합니다." >&2
    exit 1
  fi
  NODE_FILTER="$(resolve_job_to_node "$ns" "$jn")"
  if [[ -z "$NODE_FILTER" ]]; then
    echo "ERROR: Job ${JOB_REF} 의 실행 중인 Pod 가 없습니다 (완료/미생성 시 빈 값)." >&2
    exit 1
  fi
  JOB_POD_NS="$ns"
  JOB_POD_NAME="$(kubectl get pod -n "$ns" -l "job-name=${jn}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
fi

echo "== Insight Hub 데이터 확인 =="
echo "    gRPC 주소: ${HUB_ADDR}"
echo "    (scope→hub: gRPC SubmitHistoryData → SQLite resource_snapshots)"
echo ""
echo "    ※ 노드 집계 + (선택) Pod 단위 행 — insight-scope 에 POD_METRICS_LABEL_SELECTOR + INSIGHT_HUB_ENDPOINT 필요"
if [[ -n "${POD_REF:-}" ]]; then
  echo "    ※ 조회 노드: ${NODE_FILTER} (--pod ${POD_REF})  Pod: ${JOB_POD_NS}/${JOB_POD_NAME}"
elif [[ -n "${JOB_REF:-}" ]]; then
  echo "    ※ 조회 노드: ${NODE_FILTER} (--job ${JOB_REF})  Job Pod: ${JOB_POD_NS}/${JOB_POD_NAME:-?}"
elif [[ -n "${NODE_FILTER}" ]]; then
  echo "    ※ 조회 노드: ${NODE_FILTER}"
fi
echo ""

have_grpcurl() { command -v grpcurl >/dev/null 2>&1; }

grpc_health() {
  grpcurl -plaintext "${HUB_ADDR}" insight.hub.v1.InsightHubService/HealthCheck
}

grpc_list_nodes() {
  grpcurl -plaintext "${HUB_ADDR}" insight.hub.v1.InsightHubService/ListNodes
}

grpc_history_sample() {
  local node="$1"
  grpcurl -plaintext -d "{\"node_name\":\"${node}\",\"since_unix_ms\":0,\"max_snapshots\":8}" \
    "${HUB_ADDR}" insight.hub.v1.InsightHubService/GetNodeHistory
}

# 호스트에 grpcurl 없을 때: 같은 네임스페이스에서 임시 Pod로 gRPC 호출
# fullstorydev/grpcurl 이미지는 ENTRYPOINT 가 grpcurl 이므로 인자에 grpcurl 을 넣지 않음
grpcurl_via_kubectl() {
  local job="hub-grpcurl-$(date +%s)-$RANDOM"
  # -i/-t 없이 attach 만: CI/SSH 환경에서 TTY 오류 방지
  kubectl run "$job" -n "$HUB_NS" --rm --restart=Never --attach=true --image="$GRPCURL_IMAGE" \
    --image-pull-policy=IfNotPresent \
    -- "$@" 2>&1
}

# 클러스터 안에서 호출할 주소 (로컬 port-forward 가 아닐 때)
HUB_GRPC_TARGET="${HUB_GRPC_TARGET:-${HUB_SVC}.${HUB_NS}.svc.cluster.local:${HUB_GRPC_PORT}}"
if [[ "${HUB_ADDR}" == *"127.0.0.1"* ]] || [[ "${HUB_ADDR}" == *"localhost"* ]]; then
  GRPC_TARGET="${HUB_ADDR}"
else
  GRPC_TARGET="${HUB_GRPC_TARGET}"
fi

run_grpc_checks() {
  local mode="$1"
  echo "== 1) HealthCheck (total_snapshots = 저장된 행 수) =="
  if [[ "$mode" == "local" ]]; then
    grpc_health || true
  else
    grpcurl_via_kubectl -plaintext "${GRPC_TARGET}" insight.hub.v1.InsightHubService/HealthCheck || true
  fi
  echo ""
  echo "== 2) ListNodes (스냅샷이 있는 노드 이름) =="
  if [[ "$mode" == "local" ]]; then
    grpc_list_nodes || true
  else
    grpcurl_via_kubectl -plaintext "${GRPC_TARGET}" insight.hub.v1.InsightHubService/ListNodes || true
  fi
  echo ""
  if [[ -n "$NODE_FILTER" ]]; then
    echo "== 3) GetNodeHistory 샘플 (node=${NODE_FILTER}, 최대 8건) =="
    echo "    ※ Hub 키는 노드 이름입니다. 결과가 비면 Pod 이름이 아닌 노드명인지 확인하세요."
    if [[ "$mode" == "local" ]]; then
      grpc_history_sample "$NODE_FILTER" || true
    else
      grpcurl_via_kubectl -plaintext \
        -d "{\"node_name\":\"${NODE_FILTER}\",\"since_unix_ms\":0,\"max_snapshots\":8}" \
        "${GRPC_TARGET}" insight.hub.v1.InsightHubService/GetNodeHistory || true
    fi
  else
    echo "== 3) GetNodeHistory (건너뜀 — 노드명을 인자로 주면 샘플 조회)"
    echo "    예: $0 \$(kubectl get pod -n default mypod -o jsonpath='{.spec.nodeName}')"
  fi
}

if have_grpcurl; then
  run_grpc_checks local
else
  echo "   (호스트에 grpcurl 없음 → 클러스터에서 임시 Pod로 gRPC 호출: ${GRPCURL_IMAGE})"
  echo ""
  run_grpc_checks kubectl
  echo ""
  echo "   (실패 시: apt install grpcurl 또는 클러스터에서 위 이미지 pull 가능 여부 확인)"
fi

echo ""
HUB_HAS_POD_RPC=1
echo "== 4) ListPods (Pod 단위 스냅샷 키 — 노드 집계와 별도: node + namespace + pod_name) =="
if have_grpcurl; then
  LP_OUT=$(grpcurl -plaintext "${HUB_ADDR}" insight.hub.v1.InsightHubService/ListPods 2>&1) || true
else
  LP_OUT=$(grpcurl_via_kubectl -plaintext "${GRPC_TARGET}" insight.hub.v1.InsightHubService/ListPods 2>&1) || true
fi
echo "$LP_OUT"
if echo "$LP_OUT" | grep -q 'does not include a method named "ListPods"'; then
  HUB_HAS_POD_RPC=0
  echo ""
  echo "    → 배포 중인 insight-hub 이미지가 구버전입니다(ListPods/GetPodHistory 없음)."
  echo "      워크스페이스에서: cd insight-hub && docker build -t insight-hub:latest ."
  echo "      이미지를 클러스터 노드에 로드한 뒤: kubectl rollout restart deployment/insight-hub -n ${HUB_NS}"
fi

if [[ -n "$JOB_POD_NAME" && -n "$NODE_FILTER" && -n "$JOB_POD_NS" && "$HUB_HAS_POD_RPC" == 1 ]]; then
  echo ""
  echo "== 5) GetPodHistory (선택한 Pod만의 시계열 — 위 GetNodeHistory 노드 집계와 별도 키) =="
  body=$(printf '%s' "{\"node_name\":\"${NODE_FILTER}\",\"pod_namespace\":\"${JOB_POD_NS}\",\"pod_name\":\"${JOB_POD_NAME}\",\"since_unix_ms\":0,\"max_snapshots\":8}")
  if have_grpcurl; then
    grpcurl -plaintext -d "$body" "${HUB_ADDR}" insight.hub.v1.InsightHubService/GetPodHistory || true
  else
    grpcurl_via_kubectl -plaintext -d "$body" "${GRPC_TARGET}" insight.hub.v1.InsightHubService/GetPodHistory || true
  fi
elif [[ -n "$JOB_POD_NAME" && "$HUB_HAS_POD_RPC" == 0 ]]; then
  echo ""
  echo "== 5) GetPodHistory (건너뜀 — Hub 이미지 갱신 후 재실행)"
fi

echo ""
echo "== 6) SQLite 요약 (Pod 안 sqlite3 또는 kubectl cp → 호스트 sqlite3) =="
HUB_POD="$(kubectl get pods -n "$HUB_NS" -l app=insight-hub -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -z "$HUB_POD" ]]; then
  echo "    (Hub Pod 없음 — namespace=${HUB_NS}, label app=insight-hub 확인)"
else
  echo "    Pod: ${HUB_NS}/${HUB_POD}"
  SQL_SUM="SELECT node_name, COALESCE(NULLIF(pod_namespace,''),'(node)') AS scope, COALESCE(NULLIF(pod_name,''),'') AS pod, COUNT(*) AS rows, datetime(MIN(ts_unix_ms)/1000,'unixepoch') AS first_utc, datetime(MAX(ts_unix_ms)/1000,'unixepoch') AS last_utc FROM resource_snapshots GROUP BY node_name, pod_namespace, pod_name ORDER BY node_name, pod_namespace, pod_name;"
  SQL_RECENT="SELECT id, node_name, pod_namespace, pod_name, ts_unix_ms, printf('%.4f', cpu_util) AS cpu, printf('%.4f', mem_util) AS mem FROM resource_snapshots ORDER BY ts_unix_ms DESC LIMIT 8;"

  ran=0
  if kubectl exec -n "$HUB_NS" "$HUB_POD" -- sh -c 'command -v sqlite3 >/dev/null 2>&1'; then
    if kubectl exec -n "$HUB_NS" "$HUB_POD" -- sqlite3 "$SQLITE_PATH" "$SQL_SUM" 2>/dev/null; then
      echo ""
      echo "    최근 행:"
      kubectl exec -n "$HUB_NS" "$HUB_POD" -- sqlite3 -header -column "$SQLITE_PATH" "$SQL_RECENT" 2>/dev/null || true
      ran=1
    fi
  fi
  if [[ "$ran" != 1 ]] && command -v sqlite3 >/dev/null 2>&1; then
    TMPDB=$(mktemp /tmp/insight-hub-check-XXXXXX.db)
    if kubectl cp -n "$HUB_NS" "$HUB_POD:${SQLITE_PATH}" "$TMPDB" 2>/dev/null; then
      echo "    (kubectl cp → 호스트 sqlite3)"
      sqlite3 "$TMPDB" "$SQL_SUM" 2>/dev/null || true
      echo ""
      echo "    최근 행:"
      sqlite3 -header -column "$TMPDB" "$SQL_RECENT" 2>/dev/null || true
      rm -f "$TMPDB"
      ran=1
    else
      rm -f "$TMPDB"
    fi
  fi
  if [[ "$ran" != 1 ]]; then
    echo "    Pod에 sqlite3 없고 kubectl cp 실패 또는 호스트에 sqlite3 없음."
    echo "    apt install sqlite3 후 재실행하거나 Hub 이미지 재빌드(Dockerfile에 sqlite)."
  fi
fi

echo ""
echo "완료."
