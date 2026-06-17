#!/usr/bin/env bash
# 07.policy-recommendation.sh는 정책 추천 결과를 다단 fallback으로 수집한다.
#
# 워크로드 컨텍스트는 .runtime/scenario1.env를 SSoT로 사용한다(인자 우선).
# 인자 없이 실행해도 동작하며, scenario1.env에서 다음 키를 읽는다.
#   WORKLOAD_NAME, NAMESPACE, APP_LABEL_KEY/APP_LABEL_VALUE, POD_SELECTOR, SELECTED_NODE
# 값이 없으면 임의 기본값(my-workload-x, default 등)을 만들지 않고 <none>으로 출력한다.
#
# 추천 결과 다단 fallback 우선순위:
#   1) .runtime/scenario2.env 의 RECOMMENDATION_FILE 이 가리키는 최신 dump
#   2) policy-engine 로그의 "recommendations dump" 라인 추출
#      (apollo/orchestration-policy-engine/internal/forecaster/client.go:183 — 복수형 'recommendations dump')
#   3) forecaster API /api/v1/policy/recommendations/<workload_node> 직접 호출
#   4) 모두 실패하면 die 하지 않고 recommendation_count=0 등 값만 출력하고 종료
#
# 사용법:
#   bash 07.policy-recommendation.sh [workload_name] [namespace]
#
# Author: 미정
# Created: 2026-05-22
# Related:
#   - apollo/orchestration-policy-engine/internal/forecaster/client.go
#   - apollo/orchestration-policy-engine/internal/forecaster/types.go
#   - year3-integration/4.integration_test/scripts/demo/runtime.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"
# shellcheck source=../runtime.sh
source "${SCRIPT_DIR}/../runtime.sh"

SCENARIO="scenario2"
ARG_WORKLOAD="${1:-}"
ARG_NAMESPACE="${2:-}"

init_log "07.policy-recommendation"
require_cmd kubectl

echo
echo "================================"
echo "Policy Recommendation"
echo "================================"

# 0. 워크로드 컨텍스트 = scenario1.env 우선(SSoT). 인자가 있으면 인자가 최우선.
load_workload_context "${ARG_WORKLOAD}" "${ARG_NAMESPACE}"
print_workload_context

NAMESPACE="${CTX_NAMESPACE}"
WORKLOAD_NAME="${CTX_WORKLOAD_NAME}"
WORKLOAD_KIND="${CTX_WORKLOAD_KIND}"
API_VERSION="${CTX_API_VERSION}"
RESOURCE_TYPE="${CTX_RESOURCE_TYPE}"
POD_SELECTOR="${CTX_POD_SELECTOR}"
WORKLOAD_NODE="${CTX_SELECTED_NODE}"

POLICY_ENGINE_NS="$(kubectl get deploy -A -l app=orchestration-policy-engine \
  -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)"
FORECASTER_NS="$(kubectl get deploy -A -l app=node-resource-forecaster \
  -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)"
echo "policy_engine_namespace=${POLICY_ENGINE_NS:-<none>}"
echo "forecaster_namespace=${FORECASTER_NS:-<none>}"

state_init "${SCENARIO}"
state_put "${SCENARIO}" "NAMESPACE" "${NAMESPACE}"
state_put "${SCENARIO}" "WORKLOAD_NAME" "${WORKLOAD_NAME}"
state_put "${SCENARIO}" "WORKLOAD_KIND" "${WORKLOAD_KIND}"
state_put "${SCENARIO}" "API_VERSION" "${API_VERSION}"
state_put "${SCENARIO}" "RESOURCE_TYPE" "${RESOURCE_TYPE}"
[[ -n "${RESOURCE_TYPE}" && -n "${WORKLOAD_NAME}" ]] && state_put "${SCENARIO}" "RESOURCE_REF" "${RESOURCE_TYPE}/${WORKLOAD_NAME}"
state_put "${SCENARIO}" "POD_SELECTOR" "${POD_SELECTOR}"
state_put "${SCENARIO}" "LABEL_SELECTOR" "${POD_SELECTOR}"

# 다단 fallback.
RECOMMENDATION_FILE=""
RECOMMENDATION_SOURCE=""

# Path 1: scenario2.env가 가리키는 기존 dump 재사용.
state_load "${SCENARIO}" 2>/dev/null || true
if [[ -n "${RECOMMENDATION_FILE:-}" && -s "${RECOMMENDATION_FILE}" ]]; then
  echo "source_tried=runtime_state_file"
  RECOMMENDATION_SOURCE="runtime_state_file"
  echo "source_used=runtime_state_file"
  echo "recommendation_file=${RECOMMENDATION_FILE}"
fi

# Path 2: policy-engine 로그.
if [[ -z "${RECOMMENDATION_SOURCE}" && -n "${POLICY_ENGINE_NS}" ]]; then
  echo "source_tried=policy_engine_log"
  candidate="${RUNTIME_DIR}/api/recommendation-engine-log-$(date +%s).json"
  if extract_recommendations_from_engine_log "${POLICY_ENGINE_NS}" "${candidate}" "${WORKLOAD_NODE}"; then
    RECOMMENDATION_FILE="${candidate}"
    RECOMMENDATION_SOURCE="policy_engine_log"
    echo "source_used=policy_engine_log"
    echo "recommendation_file=${RECOMMENDATION_FILE}"
  else
    echo "policy_engine_log_match=false"
  fi
fi

# Path 3: forecaster API 직접 호출.
if [[ -z "${RECOMMENDATION_SOURCE}" && -n "${FORECASTER_NS}" && -n "${WORKLOAD_NODE}" ]]; then
  echo "source_tried=forecaster_api"
  candidate="${RUNTIME_DIR}/api/recommendation-forecaster-${WORKLOAD_NODE}-$(date +%s).json"
  if fetch_recommendations_from_forecaster "${FORECASTER_NS}" "${WORKLOAD_NODE}" "${candidate}"; then
    if [[ -s "${candidate}" ]]; then
      RECOMMENDATION_FILE="${candidate}"
      RECOMMENDATION_SOURCE="forecaster_api"
      echo "source_used=forecaster_api"
      echo "recommendation_file=${RECOMMENDATION_FILE}"
    else
      echo "forecaster_api_response_present=false"
    fi
  else
    echo "forecaster_api_response_present=false"
  fi
fi

# 결과가 없으면 명확히 값으로 표기하고 종료.
if [[ -z "${RECOMMENDATION_SOURCE}" || -z "${RECOMMENDATION_FILE}" || ! -s "${RECOMMENDATION_FILE}" ]]; then
  echo "recommendation_source=<none>"
  echo "recommendation_count=0"
  echo "recommendation_node=<none>"
  echo "policy_type=<none>"
  echo "policy_resource=<none>"
  echo "policy_horizon=<none>"
  echo "policy_reason=<none>"
  echo "안내=정책 추천 결과 없음. forecaster 모델/Policy Engine을 확인하세요."
  echo "state_file=$(state_file_path "${SCENARIO}")"
  log_box_start "07/11" "Policy Recommendation"
  log_kv "workload" "${WORKLOAD_NAME}"
  log_kv "kind" "${WORKLOAD_KIND}"
  log_kv "namespace" "${NAMESPACE}"
  log_kv "node" "${WORKLOAD_NODE:-<none>}"
  log_kv_status "recommend" "WARN"
  log_evidence_title
  printf 'policy resource horizon probability reason\n%s %s %s %s %s\n' "<none>" "<none>" "<none>" "<none>" "no-recommendation" | print_ascii_table
  log_box_result "WARN" "recommendation_count=0"
  exit 0
fi

echo "recommendation_source=${RECOMMENDATION_SOURCE}"

# JSON 파싱.
parsed=""
parsed="$(parse_recommendations_json "${RECOMMENDATION_FILE}" 2>&1)" || parsed=""
parse_err="$(grep -aE '^PARSE_ERR=' <<<"${parsed}" | head -1 | sed 's/^PARSE_ERR=//' || true)"
if [[ -n "${parse_err}" ]]; then
  echo "recommendation_parse_error=${parse_err}"
  echo "recommendation_count=0"
  echo "policy_type=<none>"
  echo "state_file=$(state_file_path "${SCENARIO}")"
  exit 0
fi

REC_COUNT="$(  grep -aE '^REC_COUNT='            <<<"${parsed}" | head -1 | sed 's/^REC_COUNT=//' || true)"
REC_NODE="$(   grep -aE '^REC_NODE='             <<<"${parsed}" | head -1 | sed 's/^REC_NODE=//' || true)"
REC_POLICY="$( grep -aE '^REC_PRIMARY_POLICY='   <<<"${parsed}" | head -1 | sed 's/^REC_PRIMARY_POLICY=//' || true)"
REC_RESOURCE="$(grep -aE '^REC_PRIMARY_RESOURCE='<<<"${parsed}" | head -1 | sed 's/^REC_PRIMARY_RESOURCE=//' || true)"
REC_HORIZON="$( grep -aE '^REC_PRIMARY_HORIZON=' <<<"${parsed}" | head -1 | sed 's/^REC_PRIMARY_HORIZON=//' || true)"
REC_REASON="$(  grep -aE '^REC_PRIMARY_REASON='  <<<"${parsed}" | head -1 | sed 's/^REC_PRIMARY_REASON=//' || true)"
REC_PROB="$(    grep -aE '^REC_PRIMARY_PROB='    <<<"${parsed}" | head -1 | sed 's/^REC_PRIMARY_PROB=//' || true)"
REC_URGENCY="$( grep -aE '^REC_PRIMARY_URGENCY=' <<<"${parsed}" | head -1 | sed 's/^REC_PRIMARY_URGENCY=//' || true)"

echo "recommendation_count=${REC_COUNT:-0}"
echo "recommendation_node=${REC_NODE:-<none>}"
if [[ -n "${REC_NODE}" && -n "${WORKLOAD_NODE}" ]]; then
  if [[ "${REC_NODE}" == "${WORKLOAD_NODE}" ]]; then echo "recommendation_node_matches_workload=true"
  else echo "recommendation_node_matches_workload=false"
  fi
fi
echo "policy_type=${REC_POLICY:-<none>}"
echo "policy_resource=${REC_RESOURCE:-<none>}"
echo "policy_horizon=${REC_HORIZON:-<none>}"
echo "policy_probability=${REC_PROB:-<none>}"
echo "policy_urgency=${REC_URGENCY:-<none>}"
echo "policy_reason=${REC_REASON:-<none>}"

echo
echo "rows"
while IFS= read -r line; do
  case "${line}" in
    REC_ROW\|*)
      IFS='|' read -r _ rh rres rpol rprob rpred rthr rreason <<<"${line}"
      printf '  horizon=%s resource=%s policy=%s probability=%s predicted=%s threshold=%s reason=%s\n' \
        "${rh:-<n/a>}" "${rres:-<n/a>}" "${rpol:-<n/a>}" "${rprob:-<n/a>}" "${rpred:-<n/a>}" "${rthr:-<n/a>}" "${rreason:-<n/a>}"
      ;;
  esac
done <<<"${parsed}"

# state 갱신: 10번이 그대로 사용한다(scenario1.env는 건드리지 않는다).
state_put "${SCENARIO}" "POLICY_TYPE" "${REC_POLICY}"
state_put "${SCENARIO}" "POLICY_NAME" "${REC_POLICY}"
state_put "${SCENARIO}" "POLICY_RESOURCE" "${REC_RESOURCE}"
state_put "${SCENARIO}" "POLICY_HORIZON" "${REC_HORIZON}"
state_put "${SCENARIO}" "POLICY_REASON" "${REC_REASON}"
state_put "${SCENARIO}" "RECOMMENDATION_NODE" "${REC_NODE}"
state_put "${SCENARIO}" "RECOMMENDATION_COUNT" "${REC_COUNT}"
state_put "${SCENARIO}" "RECOMMENDATION_FILE" "${RECOMMENDATION_FILE}"
state_put "${SCENARIO}" "API_RESPONSE_FILE" "${RECOMMENDATION_FILE}"

echo "state_file=$(state_file_path "${SCENARIO}")"

# ===== 시연 화면 요약 =====
log_box_start "07/11" "Policy Recommendation"
log_kv "workload" "${WORKLOAD_NAME}"
log_kv "kind" "${WORKLOAD_KIND}"
log_kv "namespace" "${NAMESPACE}"
log_kv "node" "${REC_NODE}"
log_kv "selected_policy" "${REC_POLICY}"
log_kv "resource" "${REC_RESOURCE}"
log_kv "horizon" "${REC_HORIZON}"
log_kv "probability" "${REC_PROB}"
log_evidence_title
printf 'policy resource horizon probability reason\n%s %s %s %s %s\n' "${REC_POLICY}" "${REC_RESOURCE}" "${REC_HORIZON}" "${REC_PROB}" "${REC_REASON}" | print_ascii_table
log_evidence_line "reason : ${REC_REASON}"
log_box_result "$([[ "${REC_COUNT:-0}" != "0" ]] && echo PASS || echo WARN)" "recommendation_count=${REC_COUNT:-0}"
