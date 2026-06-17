#!/usr/bin/env bash
# 01.node-resource-forecaster.sh는 node-resource-forecaster Pod 상태와 LSTM/LightGBM 로그를
# 확인하고, port-forward를 직접 켜서 /api/v1/forecast/node/<workload_node> 응답에서 horizon별
# 통합 예측값을 파싱해 출력한다. 또한 scenario1.env의 워크로드 컨텍스트를 scenario2.env로
# 복사하여 scenario2의 후속 단계들이 일관된 컨텍스트로 진행되도록 한다.
# 예시 숫자를 박지 않으며, raw JSON은 노출하지 않는다.
#
# 사용법:
#   bash 01.node-resource-forecaster.sh [workload_name] [namespace]
#
# Author: 미정
# Created: 2026-05-22
# Related:
#   - apollo/node-resource-forecaster/server/http_server.py
#   - year3-integration/4.integration_test/scripts/demo/runtime.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"
# shellcheck source=../runtime.sh
source "${SCRIPT_DIR}/../runtime.sh"

SCENARIO="scenario2"
ARG_WORKLOAD="${1:-}"
ARG_NAMESPACE="${2:-}"

init_log "06.node-resource-forecaster"

# WHY: forecaster가 위치한 namespace를 라벨로 탐색한다(이름 박지 않음).
FORECASTER_NS="$(kubectl get deploy -A -l app=node-resource-forecaster \
  -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)"

require_cmd kubectl

echo
echo "================================"
echo "Node Resource Forecaster"
echo "================================"

# 1. 워크로드 컨텍스트 해결. SSoT = scenario1.env.
#    우선순위: 인자 > scenario1.env > (클러스터 보조 조회는 selector 누락 시에만)
load_workload_context "${ARG_WORKLOAD}" "${ARG_NAMESPACE}"
print_workload_context

NAMESPACE="${CTX_NAMESPACE}"
WORKLOAD_NAME="${CTX_WORKLOAD_NAME}"
WORKLOAD_KIND="${CTX_WORKLOAD_KIND}"
API_VERSION="${CTX_API_VERSION}"
RESOURCE_TYPE="${CTX_RESOURCE_TYPE}"
APP_LABEL_KEY="${CTX_APP_LABEL_KEY}"
APP_LABEL_VALUE="${CTX_APP_LABEL_VALUE}"
POD_SELECTOR="${CTX_POD_SELECTOR}"
WORKLOAD_NODE="${CTX_SELECTED_NODE}"

if [[ -z "${NAMESPACE}" || -z "${WORKLOAD_NAME}" || -z "${POD_SELECTOR}" ]]; then
  echo "안내=워크로드 컨텍스트가 불완전합니다. scenario1(01.preprocessing-workload.sh)을 먼저 실행하거나 인자를 명시하세요."
  exit 0
fi

# 2. scenario2.env 초기화. 워크로드 컨텍스트는 scenario1.env 복제가 아니라 참조만.
state_init "${SCENARIO}"
state_put "${SCENARIO}" "NAMESPACE" "${NAMESPACE}"
state_put "${SCENARIO}" "WORKLOAD_NAME" "${WORKLOAD_NAME}"
state_put "${SCENARIO}" "WORKLOAD_KIND" "${WORKLOAD_KIND}"
state_put "${SCENARIO}" "API_VERSION" "${API_VERSION}"
state_put "${SCENARIO}" "RESOURCE_TYPE" "${RESOURCE_TYPE}"
[[ -n "${RESOURCE_TYPE}" && -n "${WORKLOAD_NAME}" ]] && state_put "${SCENARIO}" "RESOURCE_REF" "${RESOURCE_TYPE}/${WORKLOAD_NAME}"
state_put "${SCENARIO}" "POD_SELECTOR" "${POD_SELECTOR}"
state_put "${SCENARIO}" "LABEL_SELECTOR" "${POD_SELECTOR}"

# 3. forecaster Pod 상태 + 로그.
[[ -n "${FORECASTER_NS}" ]] || die "node-resource-forecaster Deployment를 찾지 못했습니다(label app=node-resource-forecaster)."

fc_pod_name="$(jp get pods -n "${FORECASTER_NS}" -l app=node-resource-forecaster -o jsonpath='{.items[0].metadata.name}')"
fc_phase="$(jp get pods -n "${FORECASTER_NS}" -l app=node-resource-forecaster -o jsonpath='{.items[0].status.phase}')"
fc_ready="$(jp get pods -n "${FORECASTER_NS}" -l app=node-resource-forecaster -o jsonpath='{.items[0].status.containerStatuses[0].ready}')"
fc_node="$(jp get pods -n "${FORECASTER_NS}" -l app=node-resource-forecaster -o jsonpath='{.items[0].spec.nodeName}')"

echo "forecaster_pod=${fc_pod_name:-<none>}"
echo "phase=${fc_phase:-<none>}"
echo "ready=${fc_ready:-false}"
echo "node=${fc_node:-<none>}"

if [[ -z "${fc_pod_name}" || "${fc_phase}" != "Running" ]]; then
  echo "forecaster_running=false"
  echo "사유=forecaster Pod 미실행"
  exit 0
fi

fc_logs="$(kubectl logs -n "${FORECASTER_NS}" deploy/node-resource-forecaster --tail=500 2>/dev/null || true)"
lstm="미확인"; lightgbm="미확인"
grep -aEi 'LSTM' <<<"${fc_logs}" >/dev/null && lstm="확인됨"
grep -aEi 'LightGBM' <<<"${fc_logs}" >/dev/null && lightgbm="확인됨"
echo "LSTM=${lstm}"
echo "LightGBM=${lightgbm}"
echo "모델별 분리값=미제공"
echo "예측값 종류=통합 예측값"

# 4. workload node 확정. load_workload_context가 이미 채워주지만 비어 있으면 실시간 조회.
if [[ -z "${WORKLOAD_NODE}" ]]; then
  WORKLOAD_NODE="$(jp get pod -n "${NAMESPACE}" -l "${POD_SELECTOR}" -o jsonpath='{.items[0].spec.nodeName}')"
fi
echo "workload_node=${WORKLOAD_NODE:-<none>}"

if [[ -z "${WORKLOAD_NODE}" ]]; then
  echo "workload_node_found=false"
  echo "사유=workload Pod의 nodeName 미확인"
  exit 0
fi

# 5. port-forward + forecast API 호출.
command -v curl >/dev/null 2>&1 || die "curl이 설치되어 있지 않습니다."

PF_PID=""
cleanup_pf() {
  if [[ -n "${PF_PID}" ]]; then
    kill "${PF_PID}" 2>/dev/null || true
    wait "${PF_PID}" 2>/dev/null || true
    PF_PID=""
  fi
}
# WHY: init_log가 이미 EXIT trap을 잡고 있으므로 trap을 직접 설치하지 않고 runtime hook으로 등록한다.
runtime_add_exit_hook 'cleanup_pf'

# WHY: 18080부터 후보 포트를 차례로 시도(충돌 fallback).
PF_PORT=""
for port in 18080 18081 18082; do
  kubectl port-forward -n "${FORECASTER_NS}" svc/node-resource-forecaster "${port}":8080 >/dev/null 2>&1 &
  PF_PID=$!
  sleep 3
  if kill -0 "${PF_PID}" 2>/dev/null; then
    PF_PORT="${port}"
    break
  else
    PF_PID=""
  fi
done
[[ -n "${PF_PORT}" ]] || die "port-forward 시작 실패 (18080~18082 모두 실패)"
echo "port_forward_port=${PF_PORT}"

# API 응답 본문은 화면에 직접 노출하지 않고 임시 파일로 저장 후 python3로 파싱한다.
API_RESP_DIR="${RUNTIME_DIR}/api"
mkdir -p "${API_RESP_DIR}"
api_resp_file="${API_RESP_DIR}/forecast-${WORKLOAD_NODE}-$(date +%s).json"
http_code="$(curl -sS --max-time 10 -o "${api_resp_file}" \
  -w '%{http_code}' \
  "http://127.0.0.1:${PF_PORT}/api/v1/forecast/node/${WORKLOAD_NODE}?horizons=15,30,60,120" 2>/dev/null || echo "000")"
cleanup_pf

if [[ "${http_code}" != "200" || ! -s "${api_resp_file}" ]]; then
  echo "forecast_api_status=${http_code}"
  echo "forecast_api_response_present=false"
  exit 0
fi
echo "forecast_api_status=${http_code}"
echo "forecast_api_response_present=true"
echo "api_response_file=${api_resp_file}"

require_cmd_runtime python3
parsed="$(python3 - "${api_resp_file}" <<'PYEOF'
import json, sys
path = sys.argv[1]
try:
    with open(path, 'r', encoding='utf-8') as fh:
        d = json.load(fh)
    fs = d.get("forecasts") or []
    node_name = d.get("node_name") or d.get("node") or ""
    conf = d.get("confidence")
    req_id = d.get("request_id") or d.get("trace_id") or ""
    def pct(v):
        try: return "{:.1f}%".format(float(v) * 100)
        except Exception: return ""
    def fmt_conf(v):
        try: return "{:.4f}".format(float(v))
        except Exception: return ""
    print("FORECAST_NODE_NAME={}".format(node_name))
    print("FORECAST_CONFIDENCE={}".format(fmt_conf(conf)))
    print("REQUEST_ID={}".format(req_id))
    for h in (15, 30, 60, 120):
        rec = next((x for x in fs if x.get("horizon_minutes") == h), None)
        if not rec:
            for k in ("CPU","GPU","MEM","SIO"):
                print("H{}_{}=".format(h,k))
            continue
        print("H{}_CPU={}".format(h, pct(rec.get("predicted_cpu_utilization"))))
        print("H{}_GPU={}".format(h, pct(rec.get("predicted_gpu_utilization"))))
        print("H{}_MEM={}".format(h, pct(rec.get("predicted_memory_utilization"))))
        print("H{}_SIO={}".format(h, pct(rec.get("predicted_storage_io_utilization"))))
except Exception as e:
    sys.stderr.write("PARSE_ERR=" + str(e)[:200])
PYEOF
)"
parse_err="$(grep -aE '^PARSE_ERR=' <<<"${parsed}" | head -1 | sed 's/^PARSE_ERR=//' || true)"
[[ -z "${parse_err}" ]] || die "forecast 응답 파싱 실패: ${parse_err}"

while IFS='=' read -r k v; do
  case "${k}" in
    FORECAST_NODE_NAME|FORECAST_CONFIDENCE|REQUEST_ID|H15_*|H30_*|H60_*|H120_*) declare "${k}=${v}" ;;
  esac
done <<<"${parsed}"

forecast_node="${FORECAST_NODE_NAME:-${WORKLOAD_NODE}}"
echo "forecast_node=${forecast_node}"
if [[ -z "${FORECAST_NODE_NAME}" || "${FORECAST_NODE_NAME}" == "${WORKLOAD_NODE}" ]]; then
  echo "노드 일치 여부=일치"
else
  echo "노드 일치 여부=불일치"
fi
echo "confidence=${FORECAST_CONFIDENCE:-<n/a>}"
echo "confidence 설명=Forecaster API 예측 신뢰도"

echo
echo "통합 예측 결과"
echo "  출처=Forecaster API"
printf '  15분 후  CPU=%s GPU=%s Memory=%s Storage I/O=%s\n'   "${H15_CPU:-<n/a>}"  "${H15_GPU:-<n/a>}"  "${H15_MEM:-<n/a>}"  "${H15_SIO:-<n/a>}"
printf '  30분 후  CPU=%s GPU=%s Memory=%s Storage I/O=%s\n'   "${H30_CPU:-<n/a>}"  "${H30_GPU:-<n/a>}"  "${H30_MEM:-<n/a>}"  "${H30_SIO:-<n/a>}"
printf '  60분 후  CPU=%s GPU=%s Memory=%s Storage I/O=%s\n'   "${H60_CPU:-<n/a>}"  "${H60_GPU:-<n/a>}"  "${H60_MEM:-<n/a>}"  "${H60_SIO:-<n/a>}"
printf '  120분 후 CPU=%s GPU=%s Memory=%s Storage I/O=%s\n'   "${H120_CPU:-<n/a>}" "${H120_GPU:-<n/a>}" "${H120_MEM:-<n/a>}" "${H120_SIO:-<n/a>}"

# REQUEST_ID/TRACE_ID는 API 응답이 주는 값만 사용한다(없으면 비워둔다).
state_put "${SCENARIO}" "API_RESPONSE_FILE" "${api_resp_file}"
[[ -n "${REQUEST_ID:-}" ]] && state_put "${SCENARIO}" "REQUEST_ID" "${REQUEST_ID}"

echo "state_file=$(state_file_path "${SCENARIO}")"

# ===== 시연 화면 요약 =====
log_box_start "06/11" "Node Resource Forecaster"
log_kv "workload" "${WORKLOAD_NAME}"
log_kv "kind" "${WORKLOAD_KIND}"
log_kv "namespace" "${NAMESPACE}"
log_kv "node" "${WORKLOAD_NODE}"
log_kv_status "api_status" "${http_code}"
log_kv "confidence" "${FORECAST_CONFIDENCE:-<n/a>}"
log_evidence_title
log_cmd "kubectl get node ${WORKLOAD_NODE} -o wide"
kubectl get node "${WORKLOAD_NODE}" -o wide 2>/dev/null | head -5 | __demo_prefix_lines || log_evidence_line "WARN: node 조회 실패"
log_cmd_warn "kubectl top node ${WORKLOAD_NODE}"
kubectl top node "${WORKLOAD_NODE}" 2>/dev/null | head -5 | __demo_prefix_lines || log_evidence_line "WARN: metrics-server/top node 조회 실패"
printf 'horizon CPU GPU Memory StorageIO\n15m %s %s %s %s\n30m %s %s %s %s\n60m %s %s %s %s\n120m %s %s %s %s\n' \
  "${H15_CPU:-}" "${H15_GPU:-}" "${H15_MEM:-}" "${H15_SIO:-}" \
  "${H30_CPU:-}" "${H30_GPU:-}" "${H30_MEM:-}" "${H30_SIO:-}" \
  "${H60_CPU:-}" "${H60_GPU:-}" "${H60_MEM:-}" "${H60_SIO:-}" \
  "${H120_CPU:-}" "${H120_GPU:-}" "${H120_MEM:-}" "${H120_SIO:-}" | print_ascii_table
log_box_result "$([[ "${http_code}" == "200" ]] && echo PASS || echo WARN)" "forecaster_api=${http_code}"
