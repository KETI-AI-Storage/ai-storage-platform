#!/usr/bin/env bash
# 01.preprocessing-workload.sh는 매니페스트 또는 워크로드 이름을 인자로 받아 전처리 워크로드를
# 클러스터에 실제로 생성하고, 생성된 리소스 정보를 .runtime/scenario1.env에 저장한다.
# 매니페스트/네임스페이스는 인자 -> 라벨 -> 디렉터리 검색 순으로 단일 후보가 잡힐 때만 진행한다.
# 단일 후보가 잡히지 않으면 임의 기본값을 만들지 않고 명확한 에러로 중단한다.
#
# 사용법:
#   bash 01.preprocessing-workload.sh [manifest_path_or_workload_name] [namespace]
#
# Author: 미정
# Created: 2026-05-22
# Related:
#   - year3-integration/4.integration_test/scripts/demo/runtime.sh
#   - year3-integration/4.integration_test/scripts/demo/common.sh
#   - year3-integration/4.integration_test/manifests/*.yaml

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"
# shellcheck source=../runtime.sh
source "${SCRIPT_DIR}/../runtime.sh"

SCENARIO="scenario1"
ARG_TARGET="${1:-}"
ARG_NAMESPACE="${2:-}"

init_log "01.preprocessing-workload"
require_cmd kubectl
require_cmd_runtime python3

echo
echo "================================"
echo "전처리 워크로드 생성"
echo "================================"

# 1. manifest를 우선 찾고, 없으면 클러스터의 실제 workload/Pod 이름으로 해석한다.
MANIFEST_PATH=""
MANIFEST_SOURCE="manifest"
manifest_err=""
set +e
manifest_out="$(RUNTIME_SUPPRESS_DIE_SCREEN=1 discover_manifest "${ARG_TARGET}" "${ARG_NAMESPACE}" 2>&1)"
manifest_rc=$?
set -e
if [[ "${manifest_rc}" -eq 0 && -n "${manifest_out}" ]]; then
  MANIFEST_PATH="${manifest_out}"
fi

API_VERSION=""
WORKLOAD_KIND=""
WORKLOAD_NAME=""
MANIFEST_NS=""
RESOURCE_TYPE=""
RESOURCE_REF=""
APP_LABEL_KEY=""
APP_LABEL_VALUE=""
PVC_NAMES=""
POD_SELECTOR=""
SOURCE_POD_NAME=""

if [[ -n "${MANIFEST_PATH}" ]]; then
  echo "manifest=${MANIFEST_PATH}"

  # 2. 매니페스트 파싱 -> apiVersion/kind/name/app label/PVC 목록 추출.
  PARSE_RESOURCE_NAME=""
  if [[ -n "${ARG_TARGET}" && ! -f "${ARG_TARGET}" && "${ARG_TARGET}" != *.yaml && "${ARG_TARGET}" != *.yml ]]; then
    PARSE_RESOURCE_NAME="${ARG_TARGET}"
  fi
  parsed="$(detect_workload_from_manifest "${MANIFEST_PATH}" "${ARG_NAMESPACE}" "${PARSE_RESOURCE_NAME}")" || die "manifest 파싱 실패: ${MANIFEST_PATH}"
  API_VERSION="$(grep -aE '^API_VERSION=' <<<"${parsed}" | head -1 | sed 's/^API_VERSION=//')"
  WORKLOAD_KIND="$(grep -aE '^KIND=' <<<"${parsed}" | head -1 | sed 's/^KIND=//')"
  WORKLOAD_NAME="$(grep -aE '^NAME=' <<<"${parsed}" | head -1 | sed 's/^NAME=//')"
  MANIFEST_NS="$(grep -aE '^NAMESPACE=' <<<"${parsed}" | head -1 | sed 's/^NAMESPACE=//')"
  RESOURCE_TYPE="$(grep -aE '^RESOURCE_TYPE=' <<<"${parsed}" | head -1 | sed 's/^RESOURCE_TYPE=//')"
  RESOURCE_REF="$(grep -aE '^RESOURCE_REF=' <<<"${parsed}" | head -1 | sed 's/^RESOURCE_REF=//')"
  APP_LABEL_KEY="$(grep -aE '^APP_KEY=' <<<"${parsed}" | head -1 | sed 's/^APP_KEY=//')"
  APP_LABEL_VALUE="$(grep -aE '^APP_VALUE=' <<<"${parsed}" | head -1 | sed 's/^APP_VALUE=//')"
  PVC_NAMES="$(grep -aE '^PVCS=' <<<"${parsed}" | head -1 | sed 's/^PVCS=//')"
  POD_SELECTOR="$(grep -aE '^POD_SELECTOR=' <<<"${parsed}" | head -1 | sed 's/^POD_SELECTOR=//')"

  [[ -n "${WORKLOAD_NAME}" ]] || die "매니페스트에서 지원 workload 이름을 찾지 못함: ${MANIFEST_PATH}"
  [[ -n "${RESOURCE_TYPE}" ]] || die "지원하지 않는 workload kind입니다: kind=${WORKLOAD_KIND:-<none>} apiVersion=${API_VERSION:-<none>}"
else
  MANIFEST_SOURCE="cluster"
  manifest_err="${manifest_out}"
  echo "manifest=<none>"
  echo "manifest_lookup=SKIP reason=${manifest_err//$'\n'/ }"
  [[ -n "${ARG_TARGET}" ]] || die_missing "WORKLOAD_NAME" "manifest가 없을 때는 클러스터 workload 또는 Pod 이름을 첫 번째 인자로 지정하세요."
  cluster_match="$(resolve_workload_or_pod_by_name "${ARG_TARGET}" "${ARG_NAMESPACE}" 2>/dev/null || true)"
  [[ -n "${cluster_match}" ]] || die_missing "WORKLOAD_NAME='${ARG_TARGET}'" "manifest에도 없고 클러스터 workload/Pod에서도 단일 후보를 찾지 못했습니다."
  IFS='|' read -r NAMESPACE WORKLOAD_NAME WORKLOAD_KIND API_VERSION SOURCE_POD_NAME POD_SELECTOR <<<"${cluster_match}"
  RESOURCE_TYPE="$(kind_to_kubectl_resource "${WORKLOAD_KIND}" "${API_VERSION}" 2>/dev/null || true)"
  RESOURCE_REF="${RESOURCE_TYPE}/${WORKLOAD_NAME}"
  PVC_NAMES="$(get_pvc_names_for_workload "${NAMESPACE}" "${WORKLOAD_KIND}" "${WORKLOAD_NAME}" "${API_VERSION}" 2>/dev/null || true)"
  if [[ -z "${POD_SELECTOR}" ]]; then
    POD_SELECTOR="$(get_selector_for_workload "${NAMESPACE}" "${WORKLOAD_NAME}" "${WORKLOAD_KIND}" "${API_VERSION}" 2>/dev/null || true)"
  fi
  if [[ -n "${POD_SELECTOR}" && "${POD_SELECTOR}" == *"="* && "${POD_SELECTOR}" != metadata.name=* ]]; then
    APP_LABEL_KEY="${POD_SELECTOR%%=*}"
    APP_LABEL_VALUE="${POD_SELECTOR#*=}"
  fi
fi

# 3. namespace 결정. 우선순위: 인자 -> 매니페스트 metadata.namespace -> 기존 runtime state -> 클러스터 라벨 검색.
if [[ -n "${NAMESPACE:-}" ]]; then
  :
elif [[ -n "${ARG_NAMESPACE}" ]]; then
  NAMESPACE="${ARG_NAMESPACE}"
elif [[ -n "${MANIFEST_NS}" ]]; then
  NAMESPACE="${MANIFEST_NS}"
else
  STATE_NAMESPACE="$(state_get_or_empty "${SCENARIO}" "NAMESPACE" 2>/dev/null || true)"
  if [[ -n "${STATE_NAMESPACE}" ]]; then
    NAMESPACE="${STATE_NAMESPACE}"
  else
    NAMESPACE="$(discover_namespace)"
  fi
fi

[[ -z "${POD_SELECTOR}" && -n "${APP_LABEL_KEY}" && -n "${APP_LABEL_VALUE}" ]] && POD_SELECTOR="${APP_LABEL_KEY}=${APP_LABEL_VALUE}"
if [[ -z "${POD_SELECTOR}" ]]; then
  POD_SELECTOR="$(get_selector_for_workload "${NAMESPACE}" "${WORKLOAD_NAME}" "${WORKLOAD_KIND}" "${API_VERSION}" 2>/dev/null || true)"
fi

echo "apiVersion=${API_VERSION}"
echo "workload_kind=${WORKLOAD_KIND}"
echo "workload_name=${WORKLOAD_NAME}"
echo "namespace=${NAMESPACE}"
echo "resource_type=${RESOURCE_TYPE}"
echo "resource_ref=${RESOURCE_REF}"
echo "manifest_source=${MANIFEST_SOURCE}"
echo "source_pod=${SOURCE_POD_NAME:-<none>}"
echo "app_label=${POD_SELECTOR}"
echo "pvc_names=${PVC_NAMES:-<none>}"

# 4. manifest가 있을 때만 kubectl apply를 수행한다. cluster fallback은 기존 리소스를 관측 대상으로 연결한다.
echo
if [[ -n "${MANIFEST_PATH}" ]]; then
  echo "apply 명령=kubectl apply -f ${MANIFEST_PATH} -n ${NAMESPACE}"
  if ! kubectl apply -f "${MANIFEST_PATH}" -n "${NAMESPACE}" >/dev/null; then
    die "kubectl apply 실패: ${MANIFEST_PATH}"
  fi
  echo "apply_status=완료"
else
  echo "apply_status=SKIP reason=manifest 없이 클러스터 기존 리소스를 대상으로 사용"
fi
wait_for_workload_status "${NAMESPACE}" "${WORKLOAD_KIND}" "${WORKLOAD_NAME}" "${API_VERSION}" "${DEMO_WAIT_TIMEOUT_SECONDS:-300}" || true

# 5. 실제 클러스터의 적용 결과(uid, creationTimestamp 등)를 다시 읽어 state에 저장.
workload_uid="$(kubectl get "${RESOURCE_TYPE}" -n "${NAMESPACE}" "${WORKLOAD_NAME}" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
workload_created="$(kubectl get "${RESOURCE_TYPE}" -n "${NAMESPACE}" "${WORKLOAD_NAME}" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null || true)"
if [[ -z "${workload_uid}" ]]; then
  echo "WARN workload_get_failed resource_type=${RESOURCE_TYPE} name=${WORKLOAD_NAME} namespace=${NAMESPACE}"
fi
echo "workload_uid=${workload_uid:-<unknown>}"
echo "workload_created=${workload_created:-<unknown>}"

# 6. runtime state 파일 갱신. 정책 관련 필드는 비워두고 후속 단계가 채운다.
state_init "${SCENARIO}"
state_put "${SCENARIO}" "MANIFEST_PATH" "${MANIFEST_PATH}"
state_put "${SCENARIO}" "MANIFEST_SOURCE" "${MANIFEST_SOURCE}"
state_put "${SCENARIO}" "API_VERSION" "${API_VERSION}"
state_put "${SCENARIO}" "NAMESPACE" "${NAMESPACE}"
state_put "${SCENARIO}" "WORKLOAD_KIND" "${WORKLOAD_KIND}"
state_put "${SCENARIO}" "WORKLOAD_NAME" "${WORKLOAD_NAME}"
state_put "${SCENARIO}" "RESOURCE_TYPE" "${RESOURCE_TYPE}"
state_put "${SCENARIO}" "RESOURCE_REF" "${RESOURCE_REF}"
state_put "${SCENARIO}" "OWNER_KIND" "${WORKLOAD_KIND}"
state_put "${SCENARIO}" "OWNER_NAME" "${WORKLOAD_NAME}"
state_put "${SCENARIO}" "APP_LABEL_KEY" "${APP_LABEL_KEY}"
state_put "${SCENARIO}" "APP_LABEL_VALUE" "${APP_LABEL_VALUE}"
state_put "${SCENARIO}" "PVC_NAMES" "${PVC_NAMES}"
state_put "${SCENARIO}" "POD_SELECTOR" "${POD_SELECTOR}"
state_put "${SCENARIO}" "LABEL_SELECTOR" "${POD_SELECTOR}"
state_put "${SCENARIO}" "REQUEST_ID" "${workload_uid}"
state_put "${SCENARIO}" "TRACE_ID" "${workload_created}"

echo "state_file=$(state_file_path "${SCENARIO}")"

# ===== 시연 화면 요약 =====
log_box_start "01/11" "Preprocessing Workload"
log_kv "namespace" "${NAMESPACE}"
log_kv "workload" "${WORKLOAD_NAME}"
log_kv "kind" "${WORKLOAD_KIND}"
log_kv "resource_type" "${RESOURCE_TYPE}"
log_kv "manifest" "${MANIFEST_PATH##*/}"
log_kv "source" "${MANIFEST_SOURCE}"
log_evidence_title
log_cmd "kubectl get ${RESOURCE_TYPE} ${WORKLOAD_NAME} -n ${NAMESPACE}"
kubectl get "${RESOURCE_TYPE}" "${WORKLOAD_NAME}" -n "${NAMESPACE}" 2>/dev/null | head -5 | __demo_prefix_lines || log_evidence_line "WARN: workload 조회 실패"
if [[ -n "${POD_SELECTOR}" && "${POD_SELECTOR}" != metadata.name=* ]]; then
  log_cmd "kubectl get pod -n ${NAMESPACE} -l ${POD_SELECTOR} -o wide"
  kubectl get pod -n "${NAMESPACE}" -l "${POD_SELECTOR}" -o wide 2>/dev/null | head -6 | __demo_prefix_lines || log_evidence_line "WARN: pod 조회 실패"
elif [[ -n "${SOURCE_POD_NAME}" ]]; then
  log_cmd "kubectl get pod ${SOURCE_POD_NAME} -n ${NAMESPACE} -o wide"
  kubectl get pod "${SOURCE_POD_NAME}" -n "${NAMESPACE}" -o wide 2>/dev/null | head -5 | __demo_prefix_lines || log_evidence_line "WARN: pod 조회 실패"
fi
log_box_result "PASS" "apply_status=${MANIFEST_SOURCE}"
