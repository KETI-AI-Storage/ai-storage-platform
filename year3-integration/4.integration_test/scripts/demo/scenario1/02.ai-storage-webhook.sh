#!/usr/bin/env bash
# 02.ai-storage-webhook.sh는 webhook이 대상 Pod에 schedulerName / insight-trace sidecar /
# main-container annotation / selected-tier annotation/label / shareProcessNamespace 를 정상
# 주입했는지만 확인한다. 워크로드 이름은 인자, runtime state, 매니페스트, 클러스터 라벨 순으로 해결한다.
#
# 사용법:
#   bash 02.ai-storage-webhook.sh [workload_name] [namespace]
#
# Author: 미정
# Created: 2026-05-22
# Related:
#   - ai-storage-webhook/pkg/webhook/mutate.go
#   - year3-integration/4.integration_test/scripts/demo/runtime.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"
# shellcheck source=../runtime.sh
source "${SCRIPT_DIR}/../runtime.sh"

SCENARIO="scenario1"
ARG_WORKLOAD="${1:-}"
ARG_NAMESPACE="${2:-}"
SIDECAR_NAME_EXPECTED="insight-trace"
SCHEDULER_NAME_EXPECTED="ai-storage-scheduler"

init_log "02.ai-storage-webhook"
require_cmd kubectl

echo
echo "================================"
echo "AI Storage Webhook"
echo "================================"

# 1. 워크로드/네임스페이스 해결 우선순위: 인자 -> state -> 클러스터 라벨 -> 매니페스트.
NAMESPACE=""
WORKLOAD_NAME=""
WORKLOAD_KIND=""
API_VERSION=""
APP_LABEL_KEY=""
APP_LABEL_VALUE=""

if [[ -n "${ARG_WORKLOAD}" ]]; then
  match="$(resolve_workload_by_name "${ARG_WORKLOAD}" "${ARG_NAMESPACE}")"
  IFS='|' read -r NAMESPACE WORKLOAD_NAME WORKLOAD_KIND API_VERSION <<<"${match}"
elif state_load "${SCENARIO}" 2>/dev/null && [[ -n "${WORKLOAD_NAME:-}" && -n "${NAMESPACE:-}" ]]; then
  : # state file에서 채워짐
else
  match="$(discover_workload_in_cluster "${ARG_NAMESPACE}")"
  IFS='|' read -r NAMESPACE WORKLOAD_NAME WORKLOAD_KIND API_VERSION <<<"${match}"
fi

# app label은 state -> kind별 selector 조회 순으로 결정. 라벨 키 이름을 박지 않는다.
if [[ -z "${APP_LABEL_KEY:-}" || -z "${APP_LABEL_VALUE:-}" ]]; then
  pair="$(get_selector_for_workload "${NAMESPACE}" "${WORKLOAD_NAME}" "${WORKLOAD_KIND:-Deployment}" "${API_VERSION:-apps/v1}")"
  if [[ -n "${pair}" ]]; then
    APP_LABEL_KEY="${pair%%=*}"
    APP_LABEL_VALUE="${pair#*=}"
  fi
fi

POD_SELECTOR="${POD_SELECTOR:-}"
[[ -z "${POD_SELECTOR}" && -n "${APP_LABEL_KEY}" && -n "${APP_LABEL_VALUE}" ]] && POD_SELECTOR="${APP_LABEL_KEY}=${APP_LABEL_VALUE}"

[[ -n "${WORKLOAD_NAME}" && -n "${NAMESPACE}" ]] || die_missing "WORKLOAD_NAME/NAMESPACE" "01번 스크립트를 먼저 실행하거나 워크로드 이름을 인자로 지정하세요."
[[ -n "${POD_SELECTOR}" ]] || die_missing "POD_SELECTOR" "kind별 selector에서 Pod selector를 결정할 수 없습니다."

echo "namespace=${NAMESPACE}"
echo "workload=${WORKLOAD_NAME}"
echo "kind=${WORKLOAD_KIND:-<unknown>}"
echo "apiVersion=${API_VERSION:-<unknown>}"
echo "app_label=${POD_SELECTOR}"

# 2. 대상 Pod 식별.
POD_NAME="$(get_first_pod_for_workload "${NAMESPACE}" "${WORKLOAD_KIND:-Deployment}" "${WORKLOAD_NAME}" "${API_VERSION:-apps/v1}" 2>/dev/null || true)"
echo "pod=${POD_NAME:-<none>}"

if [[ -z "${POD_NAME}" ]]; then
  echo "pod_found=false"
  echo "사유=${POD_SELECTOR} 라벨로 식별되는 Pod 없음"
  exit 0
fi

# 3. webhook 주입 결과 검증값 수집.
sched="$(jp get pod "${POD_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.schedulerName}')"
share="$(jp get pod "${POD_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.shareProcessNamespace}')"
containers="$(jp get pod "${POD_NAME}" -n "${NAMESPACE}" -o jsonpath='{range .spec.containers[*]}{.name}{" "}{end}')"
sidecar_cn="$(jp get pod "${POD_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.containers[?(@.name=="'"${SIDECAR_NAME_EXPECTED}"'")].env[?(@.name=="CONTAINER_NAME")].value}')"
ann_mlops="$(jp get pod "${POD_NAME}" -n "${NAMESPACE}" -o jsonpath='{.metadata.annotations.mlops\.keti\.io/main-container}')"
ann_workload="$(jp get pod "${POD_NAME}" -n "${NAMESPACE}" -o jsonpath='{.metadata.annotations.workload\.keti\.io/main-container}')"
ann_aistorage="$(jp get pod "${POD_NAME}" -n "${NAMESPACE}" -o jsonpath='{.metadata.annotations.ai-storage/main-container}')"

# WHY: webhook의 resolveMainContainerName과 동일한 우선순위로 main container를 재계산해서 비교.
main_expected=""
if [[ -n "${ann_mlops}" ]]; then
  main_expected="${ann_mlops}"
elif [[ -n "${ann_workload}" ]]; then
  main_expected="${ann_workload}"
elif [[ -n "${ann_aistorage}" ]]; then
  main_expected="${ann_aistorage}"
else
  for c in ${containers}; do
    case "${c}" in
      "${SIDECAR_NAME_EXPECTED}"|istio-proxy) continue ;;
      *) main_expected="${c}"; break ;;
    esac
  done
fi
[[ -z "${main_expected}" ]] && main_expected="main"

pod_tier_ann="$(jp get pod "${POD_NAME}" -n "${NAMESPACE}" -o jsonpath='{.metadata.annotations.ai-storage/selected-tier}')"
pod_tier_lbl="$(jp get pod "${POD_NAME}" -n "${NAMESPACE}" -o jsonpath='{.metadata.labels.ai-storage-selected-tier}')"

echo "schedulerName=${sched:-<empty>}"
echo "shareProcessNamespace=${share:-<empty>}"
echo "main_container=${main_expected}"
sidecar_present="없음"
grep -qw "${SIDECAR_NAME_EXPECTED}" <<<"${containers}" && sidecar_present="존재"
echo "sidecar_container=${SIDECAR_NAME_EXPECTED}"
echo "sidecar_injected=${sidecar_present}"
echo "sidecar.CONTAINER_NAME=${sidecar_cn:-<empty>}"
main_match="불일치"
[[ -n "${sidecar_cn}" && "${sidecar_cn}" == "${main_expected}" ]] && main_match="일치"
echo "main_container_match=${main_match}"
echo "selected_tier_annotation=${pod_tier_ann:-<empty>}"
echo "selected_tier_label=${pod_tier_lbl:-<empty>}"

# WHY: 사용자 정책상 정상/비정상 같은 단정 라인은 출력하지 않는다. 위 key=value들이 그 자체로 판정 근거가 된다.
echo "scheduler_match=$([[ "${sched}" == "${SCHEDULER_NAME_EXPECTED}" ]] && echo true || echo false)"
echo "shareProcessNamespace_true=$([[ "${share}" == "true" ]] && echo true || echo false)"
echo "sidecar_injected=$([[ "${sidecar_present}" == "존재" ]] && echo true || echo false)"
echo "main_container_match_true=$([[ "${main_match}" == "일치" ]] && echo true || echo false)"

# state 갱신 (다른 단계가 이미 안다고 가정해도 일관성 유지).
state_put "${SCENARIO}" "NAMESPACE" "${NAMESPACE}"
state_put "${SCENARIO}" "API_VERSION" "${API_VERSION:-}"
state_put "${SCENARIO}" "WORKLOAD_KIND" "${WORKLOAD_KIND:-}"
state_put "${SCENARIO}" "WORKLOAD_NAME" "${WORKLOAD_NAME}"
state_put "${SCENARIO}" "APP_LABEL_KEY" "${APP_LABEL_KEY}"
state_put "${SCENARIO}" "APP_LABEL_VALUE" "${APP_LABEL_VALUE}"
state_put "${SCENARIO}" "POD_SELECTOR" "${POD_SELECTOR}"
state_put "${SCENARIO}" "LABEL_SELECTOR" "${POD_SELECTOR}"

# ===== 시연 화면 요약 =====
TIER_VAL="${pod_tier_lbl:-${pod_tier_ann:-}}"
if [[ -z "${TIER_VAL}" ]]; then
  TIER_VAL="$(jp get pod "${POD_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.nodeSelector.layer}' 2>/dev/null || true)"
fi
WEBHOOK_INJECTED="$([[ "${sidecar_present}" == "존재" ]] && echo true || echo false)"
SIDECAR_INJECTED_TRUE="$([[ "${sidecar_present}" == "존재" ]] && echo true || echo false)"
log_box_start "02/11" "AI Storage Webhook"
log_kv "namespace" "${NAMESPACE}"
log_kv "workload" "${WORKLOAD_NAME}"
log_kv "kind" "${WORKLOAD_KIND:-<unknown>}"
log_kv "pod" "${POD_NAME}"
log_kv "scheduler" "${sched}"
log_kv_status "sidecar" "${SIDECAR_INJECTED_TRUE}"
log_kv_status "share_ns" "${share}"
log_kv "tier" "${TIER_VAL}"
log_evidence_title
log_cmd "kubectl get pod ${POD_NAME} -n ${NAMESPACE} -o jsonpath='{.spec.schedulerName}'"
log_evidence_line "schedulerName : ${sched:-<empty>}"
log_cmd "kubectl get pod ${POD_NAME} -n ${NAMESPACE} -o jsonpath='{range .spec.containers[*]}{.name}{\" \"}{end}'"
log_evidence_line "containers    : ${containers:-<empty>}"
log_evidence_line "main_container: ${main_expected:-<empty>}"
log_evidence_line "annotations   : mlops=${ann_mlops:-<empty>} workload=${ann_workload:-<empty>} ai-storage=${ann_aistorage:-<empty>}"
kubectl get events -n "${NAMESPACE}" --field-selector involvedObject.name="${POD_NAME}" --sort-by=.lastTimestamp 2>/dev/null \
  | grep -Ei 'scheduled|created|started|warning|failed|error|sidecar|scheduler' | tail -5 | __demo_prefix_lines || true
log_box_result "$([[ "${WEBHOOK_INJECTED}" == "true" ]] && echo PASS || echo WARN)" "webhook_injected=${WEBHOOK_INJECTED}"
