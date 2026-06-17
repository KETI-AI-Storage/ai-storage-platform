#!/usr/bin/env bash
# 05.orchestration-policy.sh는 02번이 결정한 정책 추천을 OrchestrationPolicy CR로 실제 생성·실행한다.
# 인자가 없어도 다음 우선순위로 정책 타입을 자동 탐색하며, 모두 실패하면 die하지 않고
# "정책 추천 결과 없음" 만 출력하고 정상 종료한다.
#
# POLICY_TYPE 자동 탐색 우선순위:
#   1) .runtime/scenario2.env 의 POLICY_TYPE / POLICY_RESOURCE / POLICY_HORIZON
#   2) .runtime/scenario2.env 의 RECOMMENDATION_FILE 파싱
#   3) policy-engine 로그의 "recommendations dump" 라인에서 즉시 추출
#   4) forecaster API /api/v1/policy/recommendations/<workload_node> 직접 호출
#
# 사용법:
#   bash 05.orchestration-policy.sh [policy_type] [resource_type] [horizon]
#
# Author: 미정
# Created: 2026-05-22
# Related:
#   - apollo.keti.re.kr/v1 OrchestrationPolicy CRD
#   - apollo/orchestration-policy-engine/internal/forecaster/client.go
#   - year3-integration/4.integration_test/scripts/demo/runtime.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"
# shellcheck source=../runtime.sh
source "${SCRIPT_DIR}/../runtime.sh"

SCENARIO="scenario2"
ARG_POLICY_TYPE="${1:-}"
ARG_RESOURCE="${2:-}"
ARG_HORIZON="${3:-}"
# WHY: 본 작업 정책상 env override는 사용하지 않는다. 폴링 상수는 운영 파라미터로 고정한다.
POLICY_TIMEOUT=180
POLICY_POLL_INTERVAL=5

init_log "10.orchestration-policy"
require_cmd kubectl

echo
echo "================================"
echo "Orchestration Policy"
echo "================================"

# 0. 워크로드 컨텍스트 = scenario1.env SSoT.
load_workload_context "" ""
print_workload_context
NS_WL="${CTX_NAMESPACE}"
WL_NAME="${CTX_WORKLOAD_NAME}"
WL_KIND="${CTX_WORKLOAD_KIND}"
WL_API_VERSION="${CTX_API_VERSION}"
WL_RESOURCE_TYPE="${CTX_RESOURCE_TYPE}"
POD_SEL="${CTX_POD_SELECTOR}"
WL_NODE="${CTX_SELECTED_NODE}"
echo "target_workload=${WL_NAME:-<none>}"
echo "target_kind=${WL_KIND:-<none>}"
echo "target_apiVersion=${WL_API_VERSION:-<none>}"
echo "target_resource_type=${WL_RESOURCE_TYPE:-<none>}"
echo "target_namespace=${NS_WL:-<none>}"
echo "target_node=${WL_NODE:-<none>}"

POLICY_ENGINE_NS="$(kubectl get deploy -A -l app=orchestration-policy-engine \
  -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)"
FORECASTER_NS="$(kubectl get deploy -A -l app=node-resource-forecaster \
  -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)"
echo "policy_engine_namespace=${POLICY_ENGINE_NS:-<none>}"

# 1. POLICY_TYPE / RESOURCE / HORIZON 자동 탐색.
state_load "scenario2" 2>/dev/null || true
POLICY_TYPE_RESOLVED="${ARG_POLICY_TYPE:-${POLICY_TYPE:-}}"
RESOURCE_RESOLVED="${ARG_RESOURCE:-${POLICY_RESOURCE:-}}"
HORIZON_RESOLVED="${ARG_HORIZON:-${POLICY_HORIZON:-}}"
REASON_RESOLVED="${POLICY_REASON:-}"
SOURCE_USED=""
[[ -n "${POLICY_TYPE_RESOLVED}" ]] && SOURCE_USED="argument_or_state"

# Path 2: state의 RECOMMENDATION_FILE 재파싱(state의 POLICY_TYPE가 비어있을 때).
if [[ -z "${POLICY_TYPE_RESOLVED}" && -n "${RECOMMENDATION_FILE:-}" && -s "${RECOMMENDATION_FILE}" ]]; then
  echo "source_tried=runtime_state_recommendation_file"
  parsed=""
  parsed="$(parse_recommendations_json "${RECOMMENDATION_FILE}" 2>&1)" || parsed=""
  POLICY_TYPE_RESOLVED="$(grep -aE '^REC_PRIMARY_POLICY=' <<<"${parsed}" | head -1 | sed 's/^REC_PRIMARY_POLICY=//')"
  RESOURCE_RESOLVED="$(grep -aE '^REC_PRIMARY_RESOURCE=' <<<"${parsed}" | head -1 | sed 's/^REC_PRIMARY_RESOURCE=//')"
  HORIZON_RESOLVED="$(grep -aE '^REC_PRIMARY_HORIZON=' <<<"${parsed}" | head -1 | sed 's/^REC_PRIMARY_HORIZON=//')"
  REASON_RESOLVED="$(grep -aE '^REC_PRIMARY_REASON=' <<<"${parsed}" | head -1 | sed 's/^REC_PRIMARY_REASON=//')"
  [[ -n "${POLICY_TYPE_RESOLVED}" ]] && SOURCE_USED="runtime_state_recommendation_file"
fi

# Path 3: policy-engine 로그 즉시 추출.
if [[ -z "${POLICY_TYPE_RESOLVED}" && -n "${POLICY_ENGINE_NS}" ]]; then
  echo "source_tried=policy_engine_log"
  candidate="${RUNTIME_DIR}/api/recommendation-engine-log-$(date +%s).json"
  if extract_recommendations_from_engine_log "${POLICY_ENGINE_NS}" "${candidate}" "${WL_NODE}"; then
    parsed=""
    parsed="$(parse_recommendations_json "${candidate}" 2>&1)" || parsed=""
    POLICY_TYPE_RESOLVED="$(grep -aE '^REC_PRIMARY_POLICY=' <<<"${parsed}" | head -1 | sed 's/^REC_PRIMARY_POLICY=//')"
    RESOURCE_RESOLVED="$(grep -aE '^REC_PRIMARY_RESOURCE=' <<<"${parsed}" | head -1 | sed 's/^REC_PRIMARY_RESOURCE=//')"
    HORIZON_RESOLVED="$(grep -aE '^REC_PRIMARY_HORIZON=' <<<"${parsed}" | head -1 | sed 's/^REC_PRIMARY_HORIZON=//')"
    REASON_RESOLVED="$(grep -aE '^REC_PRIMARY_REASON=' <<<"${parsed}" | head -1 | sed 's/^REC_PRIMARY_REASON=//')"
    [[ -n "${POLICY_TYPE_RESOLVED}" ]] && SOURCE_USED="policy_engine_log"
  fi
fi

# Path 4: forecaster API 직접.
if [[ -z "${POLICY_TYPE_RESOLVED}" && -n "${FORECASTER_NS}" && -n "${WL_NODE}" ]]; then
  echo "source_tried=forecaster_api"
  candidate="${RUNTIME_DIR}/api/recommendation-forecaster-${WL_NODE}-$(date +%s).json"
  if fetch_recommendations_from_forecaster "${FORECASTER_NS}" "${WL_NODE}" "${candidate}"; then
    parsed=""
    parsed="$(parse_recommendations_json "${candidate}" 2>&1)" || parsed=""
    POLICY_TYPE_RESOLVED="$(grep -aE '^REC_PRIMARY_POLICY=' <<<"${parsed}" | head -1 | sed 's/^REC_PRIMARY_POLICY=//')"
    RESOURCE_RESOLVED="$(grep -aE '^REC_PRIMARY_RESOURCE=' <<<"${parsed}" | head -1 | sed 's/^REC_PRIMARY_RESOURCE=//')"
    HORIZON_RESOLVED="$(grep -aE '^REC_PRIMARY_HORIZON=' <<<"${parsed}" | head -1 | sed 's/^REC_PRIMARY_HORIZON=//')"
    REASON_RESOLVED="$(grep -aE '^REC_PRIMARY_REASON=' <<<"${parsed}" | head -1 | sed 's/^REC_PRIMARY_REASON=//')"
    [[ -n "${POLICY_TYPE_RESOLVED}" ]] && SOURCE_USED="forecaster_api"
  fi
fi

echo "policy_type=${POLICY_TYPE_RESOLVED:-<none>}"
echo "policy_resource=${RESOURCE_RESOLVED:-<none>}"
echo "policy_horizon=${HORIZON_RESOLVED:-<none>}"
echo "policy_reason=${REASON_RESOLVED:-<none>}"
echo "source_used=${SOURCE_USED:-<none>}"

__emit_screen_summary_skip() {
  local note="$1"
  log_box_start "10/11" "Orchestration Policy"
  log_kv "target" "${WL_NAME}"
  log_kv "kind" "${WL_KIND:-<none>}"
  log_kv "namespace" "${NS_WL}"
  log_kv "policy" "${POLICY_TYPE_RESOLVED:-<none>}"
  log_kv "resource" "${RESOURCE_RESOLVED:-<none>}"
  log_kv "horizon" "${HORIZON_RESOLVED:-<none>}"
  log_evidence_title
  log_evidence_line "reason : ${note}"
  log_box_result "WARN" "${note}"
}

# 모든 fallback 실패 시 die 하지 않고 값만 출력하고 종료.
if [[ -z "${POLICY_TYPE_RESOLVED}" ]]; then
  echo "안내=정책 추천 결과 없음. forecaster 모델/Policy Engine을 확인하세요."
  echo "state_file=$(state_file_path "${SCENARIO}")"
  __emit_screen_summary_skip "no recommendation"
  exit 0
fi

if [[ -z "${RESOURCE_RESOLVED}" || -z "${HORIZON_RESOLVED}" ]]; then
  echo "안내=정책 추천 결과는 있으나 RESOURCE/HORIZON이 비어있어 CR를 생성하지 않습니다."
  echo "state_file=$(state_file_path "${SCENARIO}")"
  __emit_screen_summary_skip "missing resource/horizon"
  exit 0
fi
if [[ -z "${POLICY_ENGINE_NS}" ]]; then
  echo "안내=OrchestrationPolicy CR를 생성할 namespace(policy-engine deployment)가 없어 CR를 생성하지 않습니다."
  echo "state_file=$(state_file_path "${SCENARIO}")"
  __emit_screen_summary_skip "policy-engine namespace not found"
  exit 0
fi

# 2. CR 이름은 runtime에 생성(timestamp + 랜덤). 박은 이름이 아니다.
APOLLO_NS="${POLICY_ENGINE_NS}"
POLICY_CR_NAME="demo-$(date +%s)-$(printf '%04x' $((RANDOM)))"
echo "apollo_namespace=${APOLLO_NS}"
echo "policy_cr_name=${POLICY_CR_NAME}"

# WHY: 정책 타입별로 오케스트레이터 validateRequest 가 요구하는 필수 입력 + 데모에서
#      실제 K8s 변화(replicas/PVC Bound/migrated Pod/eviction event/노드 재분포)를 만드는
#      파라미터를 spec.parameters 에 미리 채워준다. 외부에서 환경변수로도 덮어쓸 수 있다.
# 참고: Apollo executor 가 사용하는 키 목록은
#       apollo/orchestration-policy-engine/internal/controller/orchestrationpolicy_controller.go 의
#       executeXxxPolicy 함수 내 paramStr/paramInt32/paramBool 호출부를 참고한다.
build_policy_parameters() {
  local pt="${1}"
  case "${pt}" in
    scaling|autoscaling)
      # WHY: 현재 replicas=1 일 때 minReplicas=2 만으로 즉시 1->2 스케일업이 발생한다.
      cat <<PARAMS
    minReplicas: "${DEMO_PARAM_MIN_REPLICAS:-2}"
    maxReplicas: "${DEMO_PARAM_MAX_REPLICAS:-5}"
    targetCPU: "${DEMO_PARAM_TARGET_CPU:-80}"
    targetMemory: "${DEMO_PARAM_TARGET_MEM:-80}"
    workloadType: "${WL_KIND:-Deployment}"
PARAMS
      ;;
    provisioning)
      # WHY: storageClass 파라미터는 정책 tier 이름(archive/burst/capacity/performance) 이며
      #      orchestrator 가 K8s StorageClass(storage-archive/burst/capacity/performance) 로
      #      변환한다. demo 기본값은 가장 보편적인 capacity tier.
      cat <<PARAMS
    storageClass: "${DEMO_PARAM_STORAGE_CLASS:-capacity}"
    storageSize: "${DEMO_PARAM_STORAGE_SIZE:-1Gi}"
    accessMode: "${DEMO_PARAM_ACCESS_MODE:-ReadWriteOnce}"
    workloadType: "${DEMO_PARAM_WORKLOAD_TYPE:-training}"
PARAMS
      ;;
    caching)
      cat <<PARAMS
    sourcePVC: "${DEMO_PARAM_SOURCE_PVC:-demo-cache-source}"
    targetTier: "${DEMO_PARAM_TARGET_TIER:-nvme}"
    cachePolicy: "${DEMO_PARAM_CACHE_POLICY:-lru}"
    prefetch: "${DEMO_PARAM_PREFETCH:-true}"
PARAMS
      ;;
    migration)
      # WHY: 시연 워크로드는 RWO PVC 때문에 다른 노드로 옮길 수 없으므로,
      #      00.demo-prereqs-setup.sh 가 띄워둔 PVC-less demo-migration-workload 의
      #      Running Pod 을 자동으로 골라 parameters.podName 으로 강제한다.
      #      사용자가 DEMO_PARAM_POD_NAME 으로 명시했으면 그 값을 우선한다.
      local mig_pod="${DEMO_PARAM_POD_NAME:-}"
      if [[ -z "${mig_pod}" ]]; then
        mig_pod="$(kubectl get pod -n "${NS_WL}" \
          -l app=demo-migration-workload \
          --field-selector=status.phase=Running \
          -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
      fi
      cat <<PARAMS
    preservePV: "${DEMO_PARAM_PRESERVE_PV:-false}"
PARAMS
      [[ -n "${mig_pod}" ]] && echo "    podName: \"${mig_pod}\""
      [[ -n "${DEMO_PARAM_TARGET_NODE:-}" ]] && echo "    targetNode: \"${DEMO_PARAM_TARGET_NODE}\""
      ;;
    loadbalance|loadbalancing)
      cat <<PARAMS
    scope: "${DEMO_PARAM_LB_SCOPE:-all}"
    strategy: "${DEMO_PARAM_LB_STRATEGY:-load_spreading}"
    cpuThreshold: "${DEMO_PARAM_LB_CPU_TH:-1}"
    memoryThreshold: "${DEMO_PARAM_LB_MEM_TH:-1}"
    maxMigrationsPerCycle: "${DEMO_PARAM_LB_MAX_MIG:-1}"
PARAMS
      ;;
    preemption)
      # WHY: target_amount 가 비면 오케스트레이터가 400 으로 즉시 차단한다.
      #      MinPriority 가 0 이면 일반 Pod(priority=0)을 후보 제외하므로 1 이상 필수.
      cat <<PARAMS
    targetAmount: "${DEMO_PARAM_PE_TARGET_AMOUNT:-100m}"
    minPriority: "${DEMO_PARAM_PE_MIN_PRIORITY:-1}"
    maxPodsToPreempt: "${DEMO_PARAM_PE_MAX_PODS:-1}"
    gracePeriodSeconds: "${DEMO_PARAM_PE_GRACE:-0}"
    strategy: "${DEMO_PARAM_PE_STRATEGY:-lowest_priority}"
PARAMS
      ;;
  esac
}

POLICY_PARAMETERS_BLOCK="$(build_policy_parameters "${POLICY_TYPE_RESOLVED}")"

policy_yaml="$(cat <<EOF
apiVersion: apollo.keti.re.kr/v1
kind: OrchestrationPolicy
metadata:
  name: ${POLICY_CR_NAME}
  namespace: ${APOLLO_NS}
  labels:
    generated-by: demo-scenario2
    policy-type: ${POLICY_TYPE_RESOLVED}
    target-workload: ${WL_NAME}
    target-kind: ${WL_KIND}
    target-resource-type: ${WL_RESOURCE_TYPE}
spec:
  policyType: ${POLICY_TYPE_RESOLVED}
  autoExecute: true
  horizon: ${HORIZON_RESOLVED}
  priorityScore: 80
  probability: 60
  urgency: HIGH
  resourceType: ${RESOURCE_RESOLVED}
  targetNamespace: ${NS_WL}
  targetNode: ${WL_NODE}
  targetWorkload: ${WL_NAME}
  reason: "scenario2 orchestration trigger (POLICY_TYPE=${POLICY_TYPE_RESOLVED}, RESOURCE=${RESOURCE_RESOLVED})"
$(if [[ -n "${POLICY_PARAMETERS_BLOCK}" ]]; then printf '  parameters:\n%s\n' "${POLICY_PARAMETERS_BLOCK}"; fi)
EOF
)"

echo "policy_parameters_inline=$(printf '%s' "${POLICY_PARAMETERS_BLOCK}" | tr '\n' ';' )"

echo "apply_command=kubectl apply -f - (CR=${POLICY_CR_NAME})"
if ! echo "${policy_yaml}" | kubectl apply -f - >/dev/null 2>&1; then
  echo "cr_apply_success=false"
  echo "state_file=$(state_file_path "${SCENARIO}")"
  __emit_screen_summary_skip "cr_apply_failed"
  exit 0
fi
echo "cr_apply_success=true"

# 3. status.phase polling.
echo "policy_reconcile_wait_timeout_s=${POLICY_TIMEOUT}"
poll_elapsed=0
last_phase=""
POLICY_PHASE=""
while (( poll_elapsed < POLICY_TIMEOUT )); do
  POLICY_PHASE="$(jp get orchestrationpolicy "${POLICY_CR_NAME}" -n "${APOLLO_NS}" -o jsonpath='{.status.phase}')"
  if [[ -n "${POLICY_PHASE}" && "${POLICY_PHASE}" != "${last_phase}" ]]; then
    echo "policy_phase=${POLICY_PHASE}"
    last_phase="${POLICY_PHASE}"
  fi
  case "${POLICY_PHASE}" in
    Completed|Failed) break ;;
  esac
  sleep "${POLICY_POLL_INTERVAL}"
  poll_elapsed=$((poll_elapsed + POLICY_POLL_INTERVAL))
done

POLICY_RESULT="$(jp get orchestrationpolicy "${POLICY_CR_NAME}" -n "${APOLLO_NS}" -o jsonpath='{.status.result}')"
POLICY_MESSAGE="$(jp get orchestrationpolicy "${POLICY_CR_NAME}" -n "${APOLLO_NS}" -o jsonpath='{.status.message}')"

RES_TYPE="$(parse_kv_str type "${POLICY_RESULT}")"
RES_ID="$(parse_kv_str id "${POLICY_RESULT}")"
RES_STATUS="$(parse_kv_str status "${POLICY_RESULT}")"
RES_MSG="$(parse_kv_str msg "${POLICY_RESULT}")"

echo "orchestration_type=${RES_TYPE:-<none>}"
echo "orchestration_id=${RES_ID:-<none>}"
echo "orchestration_status=${RES_STATUS:-<none>}"
echo "orchestration_message=${RES_MSG:-<none>}"
echo "policy_phase_final=${POLICY_PHASE:-<none>}"
echo "policy_status_message=${POLICY_MESSAGE:-<none>}"

state_put "${SCENARIO}" "POLICY_NAME" "${POLICY_CR_NAME}"
state_put "${SCENARIO}" "POLICY_TYPE" "${POLICY_TYPE_RESOLVED}"
state_put "${SCENARIO}" "POLICY_RESOURCE" "${RESOURCE_RESOLVED}"
state_put "${SCENARIO}" "POLICY_HORIZON" "${HORIZON_RESOLVED}"
state_put "${SCENARIO}" "POLICY_ID" "${RES_ID}"
state_put "${SCENARIO}" "POLICY_OPERATOR_TYPE" "${RES_TYPE:-${POLICY_TYPE_RESOLVED}}"
state_put "${SCENARIO}" "POLICY_OPERATOR_STATUS" "${RES_STATUS}"
state_put "${SCENARIO}" "POLICY_STATUS_RESULT" "${POLICY_RESULT}"
state_put "${SCENARIO}" "POLICY_STATUS_MESSAGE" "${POLICY_MESSAGE}"
state_put "${SCENARIO}" "TRACE_ID" "${POLICY_PHASE}"

echo "state_file=$(state_file_path "${SCENARIO}")"

# ===== 시연 화면 요약 =====
SUMMARY_RESULT="${RES_MSG:-${POLICY_MESSAGE:-}}"
EXECUTION_HINT="정책 실행 요청 완료. 실제 적용 여부는 11.orchestration-compare.sh의 정책별 before/after 검증 결과를 기준으로 판단하세요."

log_box_start "10/11" "Orchestration Policy"
log_kv "target" "${WL_NAME}"
log_kv "kind" "${WL_KIND}"
log_kv "namespace" "${NS_WL}"
log_kv "policy" "${POLICY_TYPE_RESOLVED}"
log_kv "resource" "${RESOURCE_RESOLVED}"
log_kv "horizon" "${HORIZON_RESOLVED}"
log_kv "policy_cr" "${POLICY_CR_NAME}"
log_kv_status "phase" "${POLICY_PHASE}"
log_kv "orchestration" "${RES_STATUS}"
log_kv "operator_id" "${RES_ID:-<none>}"
log_evidence_title
log_cmd "kubectl get orchestrationpolicy ${POLICY_CR_NAME} -n ${APOLLO_NS}"
kubectl get orchestrationpolicy "${POLICY_CR_NAME}" -n "${APOLLO_NS}" 2>/dev/null | head -5 | __demo_prefix_lines || log_evidence_line "WARN: orchestrationpolicy 조회 실패"
log_evidence_line "status.phase  : ${POLICY_PHASE:-<none>}"
log_evidence_line "status.result : ${POLICY_RESULT:-<none>}"
log_evidence_line "status.message: ${POLICY_MESSAGE:-<none>}"
kubectl get events -n "${APOLLO_NS}" --field-selector involvedObject.name="${POLICY_CR_NAME}" --sort-by=.lastTimestamp 2>/dev/null \
  | grep -Ei 'spec|status|policy|orchestration|autoscal|migration|provision|cache|loadbalanc|preempt|created|updated|failed|warning|error' \
  | tail -10 | __demo_prefix_lines || true
log_evidence_line "검증 기준    : ${EXECUTION_HINT}"
log_box_result "$([[ "${POLICY_PHASE}" == "Failed" ]] && echo WARN || echo SKIP)" "${SUMMARY_RESULT:-${EXECUTION_HINT}}"
