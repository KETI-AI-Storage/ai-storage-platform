#!/usr/bin/env bash
# 03.storage-pvc-binding.sh는 워크로드 PVC 바인딩과 Pod의 /data 마운트 결과만 확인한다.
# 워크로드 이름/PVC 이름은 인자, state, 클러스터 라벨, kind별 selector 순으로 해결한다.
# PVC는 절대 삭제하지 않으며 jsonpath 조회만 수행한다.
#
# 사용법:
#   bash 03.storage-pvc-binding.sh [workload_name] [namespace]
#
# Author: 미정
# Created: 2026-05-22
# Related:
#   - ai-storage-webhook (storageClassName 주입)
#   - year3-integration/4.integration_test/scripts/demo/runtime.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"
# shellcheck source=../runtime.sh
source "${SCRIPT_DIR}/../runtime.sh"

SCENARIO="scenario1"
ARG_WORKLOAD="${1:-}"
ARG_NAMESPACE="${2:-}"

init_log "03.storage-pvc-binding"
require_cmd kubectl

echo
echo "================================"
echo "Storage PVC Binding"
echo "================================"

NAMESPACE=""
WORKLOAD_NAME=""
WORKLOAD_KIND=""
API_VERSION=""
PVC_NAMES=""
APP_LABEL_KEY=""
APP_LABEL_VALUE=""

if [[ -n "${ARG_WORKLOAD}" ]]; then
  match="$(resolve_workload_by_name "${ARG_WORKLOAD}" "${ARG_NAMESPACE}")"
  IFS='|' read -r NAMESPACE WORKLOAD_NAME WORKLOAD_KIND API_VERSION <<<"${match}"
elif state_load "${SCENARIO}" 2>/dev/null && [[ -n "${WORKLOAD_NAME:-}" && -n "${NAMESPACE:-}" ]]; then
  :
else
  match="$(discover_workload_in_cluster "${ARG_NAMESPACE}")"
  IFS='|' read -r NAMESPACE WORKLOAD_NAME WORKLOAD_KIND API_VERSION <<<"${match}"
fi

if [[ -z "${APP_LABEL_KEY:-}" || -z "${APP_LABEL_VALUE:-}" ]]; then
  pair="$(get_selector_for_workload "${NAMESPACE}" "${WORKLOAD_NAME}" "${WORKLOAD_KIND:-Deployment}" "${API_VERSION:-apps/v1}")"
  if [[ -n "${pair}" ]]; then
    APP_LABEL_KEY="${pair%%=*}"
    APP_LABEL_VALUE="${pair#*=}"
  fi
fi
POD_SELECTOR="${POD_SELECTOR:-}"
[[ -z "${POD_SELECTOR}" && -n "${APP_LABEL_KEY}" && -n "${APP_LABEL_VALUE}" ]] && POD_SELECTOR="${APP_LABEL_KEY}=${APP_LABEL_VALUE}"

# PVC 이름은 state에 있으면 그걸 쓰고, 없으면 workload template에서 referenced PVC 목록을 뽑는다.
if [[ -z "${PVC_NAMES}" ]]; then
  PVC_NAMES="$(get_pvc_names_for_workload "${NAMESPACE}" "${WORKLOAD_KIND:-Deployment}" "${WORKLOAD_NAME}" "${API_VERSION:-apps/v1}")"
fi

[[ -n "${WORKLOAD_NAME}" && -n "${NAMESPACE}" ]] || die_missing "WORKLOAD_NAME/NAMESPACE" "01번을 먼저 실행하거나 인자로 지정하세요."

echo "namespace=${NAMESPACE}"
echo "workload=${WORKLOAD_NAME}"
echo "kind=${WORKLOAD_KIND:-<unknown>}"
echo "apiVersion=${API_VERSION:-<unknown>}"
echo "app_label=${POD_SELECTOR}"
echo "pvc_names=${PVC_NAMES:-<none>}"

if [[ -z "${PVC_NAMES}" ]]; then
  echo "pvc_found=false"
  echo "사유=${WORKLOAD_KIND:-workload} ${WORKLOAD_NAME}에 PVC 참조가 없음"
  exit 0
fi

# 첫 PVC만 상세 검증한다(여러 개면 후속 호출에서 인자로 지정해 한 번 더 점검).
FIRST_PVC="${PVC_NAMES%%,*}"

pvc_phase="$(jp get pvc "${FIRST_PVC}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}')"
pvc_sc="$(jp get pvc "${FIRST_PVC}" -n "${NAMESPACE}" -o jsonpath='{.spec.storageClassName}')"
pvc_volume="$(jp get pvc "${FIRST_PVC}" -n "${NAMESPACE}" -o jsonpath='{.spec.volumeName}')"
echo "pvc=${FIRST_PVC}"
echo "pvc_phase=${pvc_phase:-<empty>}"
echo "storageClass=${pvc_sc:-<empty>}"
echo "pv=${pvc_volume:-<empty>}"

pv_phase=""
if [[ -n "${pvc_volume}" ]]; then
  pv_phase="$(jp get pv "${pvc_volume}" -o jsonpath='{.status.phase}')"
fi
echo "pv_phase=${pv_phase:-<empty>}"

POD_NAME="$(get_first_pod_for_workload "${NAMESPACE}" "${WORKLOAD_KIND:-Deployment}" "${WORKLOAD_NAME}" "${API_VERSION:-apps/v1}" 2>/dev/null || true)"
echo "pod=${POD_NAME:-<none>}"

claim_mounted="불일치"
mount_path=""
if [[ -n "${POD_NAME}" ]]; then
  vols="$(jp get pod "${POD_NAME}" -n "${NAMESPACE}" -o jsonpath='{range .spec.volumes[*]}{.persistentVolumeClaim.claimName}{"\n"}{end}')"
  grep -qE "^${FIRST_PVC}$" <<<"${vols}" && claim_mounted="일치"
  # Pod 컨테이너 중 PVC volume의 mountPath를 찾는다. 컨테이너 이름을 박지 않는다.
  vol_name_for_pvc="$(jp get pod "${POD_NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{range .spec.volumes[?(@.persistentVolumeClaim.claimName=="'"${FIRST_PVC}"'")]}{.name}{"\n"}{end}' | head -1)"
  if [[ -n "${vol_name_for_pvc}" ]]; then
    mount_path="$(jp get pod "${POD_NAME}" -n "${NAMESPACE}" \
      -o jsonpath='{range .spec.containers[*].volumeMounts[?(@.name=="'"${vol_name_for_pvc}"'")]}{.mountPath}{"\n"}{end}' | head -1)"
  fi
fi
echo "claim_mounted=${claim_mounted}"
echo "mountPath=${mount_path:-<empty>}"

echo "pvc_bound_true=$([[ "${pvc_phase}" == "Bound" ]] && echo true || echo false)"
echo "pv_bound_true=$([[ -n "${pvc_volume}" && "${pv_phase}" == "Bound" ]] && echo true || echo false)"
echo "claim_mounted_true=$([[ "${claim_mounted}" == "일치" ]] && echo true || echo false)"
echo "mountPath_present_true=$([[ -n "${mount_path}" ]] && echo true || echo false)"

# state 갱신.
state_put "${SCENARIO}" "PVC_NAMES" "${PVC_NAMES}"

# ===== 시연 화면 요약 =====
if [[ "${pvc_phase}" == "Bound" && "${pv_phase}" == "Bound" && "${claim_mounted}" == "일치" ]]; then
  BINDING_LABEL="true"
else
  BINDING_LABEL="false"
fi
log_box_start "03/11" "Storage PVC Binding"
log_kv "namespace" "${NAMESPACE}"
log_kv "workload" "${WORKLOAD_NAME}"
log_kv "kind" "${WORKLOAD_KIND:-<unknown>}"
log_kv "pvc" "${FIRST_PVC}"
log_kv_status "pvc_phase" "${pvc_phase}"
log_kv "storageClass" "${pvc_sc}"
log_kv_status "pv_phase" "${pv_phase}"
log_kv "mountPath" "${mount_path}"
log_evidence_title
log_cmd "kubectl get pvc ${FIRST_PVC} -n ${NAMESPACE}"
kubectl get pvc "${FIRST_PVC}" -n "${NAMESPACE}" 2>/dev/null | head -5 | __demo_prefix_lines || log_evidence_line "WARN: pvc 조회 실패"
if [[ -n "${pvc_volume}" ]]; then
  log_cmd "kubectl get pv ${pvc_volume}"
  kubectl get pv "${pvc_volume}" 2>/dev/null | head -5 | __demo_prefix_lines || log_evidence_line "WARN: pv 조회 실패"
fi
log_cmd "kubectl get pod ${POD_NAME} -n ${NAMESPACE} -o jsonpath='volumeMounts'"
log_evidence_line "claim_mounted : ${claim_mounted}"
log_evidence_line "mountPath     : ${mount_path:-<empty>}"
log_box_result "$([[ "${BINDING_LABEL}" == "true" ]] && echo PASS || echo WARN)" "binding=${BINDING_LABEL}"
