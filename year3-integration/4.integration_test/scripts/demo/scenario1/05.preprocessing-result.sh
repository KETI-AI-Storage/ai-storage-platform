#!/usr/bin/env bash
# 05.preprocessing-result.sh는 preprocess 컨테이너 로그에서 main complete / output_dir /
# chunk_path / manifest_path를 파싱하고, 컨테이너 내부에 결과 파일이 실제 존재하는지만 확인한다.
# manifest 전체 내용은 출력하지 않으며, chunk 파일 개수 등 summary만 노출한다.
# 컨테이너 이름은 매니페스트/Pod spec에서 동적으로 결정한다(특정 이름을 박지 않는다).
#
# 사용법:
#   bash 05.preprocessing-result.sh [workload_name] [namespace]
#
# Author: 미정
# Created: 2026-05-22
# Related:
#   - year3-integration/4.integration_test/scripts/demo/runtime.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"
# shellcheck source=../runtime.sh
source "${SCRIPT_DIR}/../runtime.sh"

SCENARIO="scenario1"
ARG_WORKLOAD="${1:-}"
ARG_NAMESPACE="${2:-}"
SIDECAR_NAME="insight-trace"

init_log "05.preprocessing-result"
require_cmd kubectl

echo
echo "================================"
echo "전처리 결과"
echo "================================"

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
  :
else
  match="$(discover_workload_in_cluster "${ARG_NAMESPACE}")"
  IFS='|' read -r NAMESPACE WORKLOAD_NAME WORKLOAD_KIND API_VERSION <<<"${match}"
fi
if [[ -z "${APP_LABEL_KEY:-}" || -z "${APP_LABEL_VALUE:-}" ]]; then
  pair="$(get_selector_for_workload "${NAMESPACE}" "${WORKLOAD_NAME}" "${WORKLOAD_KIND:-Deployment}" "${API_VERSION:-apps/v1}")"
  APP_LABEL_KEY="${pair%%=*}"
  APP_LABEL_VALUE="${pair#*=}"
fi
POD_SELECTOR="${POD_SELECTOR:-}"
[[ -z "${POD_SELECTOR}" && -n "${APP_LABEL_KEY}" && -n "${APP_LABEL_VALUE}" ]] && POD_SELECTOR="${APP_LABEL_KEY}=${APP_LABEL_VALUE}"

POD_NAME="$(get_first_pod_for_workload "${NAMESPACE}" "${WORKLOAD_KIND:-Deployment}" "${WORKLOAD_NAME}" "${API_VERSION:-apps/v1}" 2>/dev/null || true)"
echo "namespace=${NAMESPACE}"
echo "workload=${WORKLOAD_NAME}"
echo "kind=${WORKLOAD_KIND:-<unknown>}"
echo "apiVersion=${API_VERSION:-<unknown>}"
echo "pod_selector=${POD_SELECTOR:-<none>}"
echo "pod=${POD_NAME:-<none>}"

if [[ -z "${POD_NAME}" ]]; then
  echo "pod_found=false"
  echo "사유=${POD_SELECTOR} 라벨로 식별되는 Pod 없음"
  exit 0
fi

# 컨테이너 이름은 sidecar를 제외한 첫 비-sidecar 컨테이너로 동적으로 결정한다.
all_containers="$(jp get pod "${POD_NAME}" -n "${NAMESPACE}" -o jsonpath='{range .spec.containers[*]}{.name}{" "}{end}')"
CONTAINER_NAME=""
for c in ${all_containers}; do
  case "${c}" in
    "${SIDECAR_NAME}"|istio-proxy) continue ;;
    *) CONTAINER_NAME="${c}"; break ;;
  esac
done
[[ -n "${CONTAINER_NAME}" ]] || die "Pod ${POD_NAME}에서 main container 후보를 찾지 못함 (containers=${all_containers})"
echo "container=${CONTAINER_NAME}"

main_logs="$(kubectl logs -n "${NAMESPACE}" "${POD_NAME}" -c "${CONTAINER_NAME}" --tail=600 2>/dev/null || true)"
complete_log="미확인"
grep -aF -- "main complete" <<<"${main_logs}" >/dev/null && complete_log="확인됨"
echo "complete_log=${complete_log}"

output_dir="$(grep -aE '^main output_dir=' <<<"${main_logs}" | tail -1 | sed -E 's/^main output_dir=//' || true)"
chunk_path="$(grep -aE '^main chunk_path=' <<<"${main_logs}" | tail -1 | sed -E 's/^main chunk_path=//' || true)"
manifest_path="$(grep -aE '^main manifest_path=' <<<"${main_logs}" | tail -1 | sed -E 's/^main manifest_path=//' || true)"
echo "output_dir=${output_dir:-<unknown>}"
echo "chunk_path=${chunk_path:-<unknown>}"
echo "manifest_path=${manifest_path:-<unknown>}"

chunk_file_exists="<n/a>"
manifest_exists="<n/a>"
chunk_count="<n/a>"
if [[ -n "${chunk_path}" ]]; then
  if kubectl exec -n "${NAMESPACE}" "${POD_NAME}" -c "${CONTAINER_NAME}" -- test -f "${chunk_path}" >/dev/null 2>&1; then
    chunk_file_exists="true"
  else
    chunk_file_exists="false"
  fi
fi
if [[ -n "${manifest_path}" ]]; then
  if kubectl exec -n "${NAMESPACE}" "${POD_NAME}" -c "${CONTAINER_NAME}" -- test -f "${manifest_path}" >/dev/null 2>&1; then
    manifest_exists="true"
  else
    manifest_exists="false"
  fi
fi
echo "chunk_file=${chunk_path:-<unknown>}"
echo "chunk_file_exists=${chunk_file_exists}"
echo "manifest=${manifest_path:-<unknown>}"
echo "manifest_exists=${manifest_exists}"

if [[ -n "${output_dir}" ]]; then
  count_raw="$(kubectl exec -n "${NAMESPACE}" "${POD_NAME}" -c "${CONTAINER_NAME}" -- \
    sh -c "ls -1 ${output_dir}/chunks 2>/dev/null | grep -E '\\.pt$' | wc -l" 2>/dev/null || true)"
  count_raw="$(echo "${count_raw}" | tr -d '[:space:]')"
  [[ -n "${count_raw}" ]] && chunk_count="${count_raw}"
fi
echo "chunk_count=${chunk_count}"

pod_phase="$(jp get pod "${POD_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}')"
echo "pod_phase=${pod_phase:-<empty>}"
if [[ "${WORKLOAD_KIND:-}" =~ ^(Job|Workflow|PyTorchJob|TFJob|MPIJob)$ ]]; then
  echo "설명=${WORKLOAD_KIND} 워크로드는 완료형일 수 있어 Pod phase가 Succeeded/Failed로 전환될 수 있다"
else
  echo "설명=${WORKLOAD_KIND:-workload} 워크로드는 main complete 이후에도 Pod phase가 Running으로 유지될 수 있다"
fi

echo "complete_log_present_true=$([[ "${complete_log}" == "확인됨" ]] && echo true || echo false)"
echo "chunk_file_present_true=${chunk_file_exists}"
echo "manifest_file_present_true=${manifest_exists}"

# ===== 시연 화면 요약 =====
log_box_start "05/11" "Preprocessing Result"
log_kv "namespace" "${NAMESPACE}"
log_kv "workload" "${WORKLOAD_NAME}"
log_kv "kind" "${WORKLOAD_KIND:-<unknown>}"
log_kv "pod" "${POD_NAME}"
log_kv "output_dir" "${output_dir}"
log_kv_status "manifest" "${manifest_exists}"
log_kv "chunk_count" "${chunk_count}"
log_kv_status "pod_phase" "${pod_phase}"
log_evidence_title
log_cmd "kubectl get pod ${POD_NAME} -n ${NAMESPACE} -o wide"
kubectl get pod "${POD_NAME}" -n "${NAMESPACE}" -o wide 2>/dev/null | head -5 | __demo_prefix_lines || log_evidence_line "WARN: pod 조회 실패"
if [[ -n "${output_dir}" ]]; then
  log_cmd "kubectl exec ... -- ls -1 ${output_dir}/chunks | head -5"
  kubectl exec -n "${NAMESPACE}" "${POD_NAME}" -c "${CONTAINER_NAME}" -- \
    sh -c "ls -1 ${output_dir}/chunks 2>/dev/null | head -5" 2>/dev/null | __demo_prefix_lines || log_evidence_line "WARN: 파일 목록 조회 실패"
fi
log_evidence_line "chunk_file_exists : ${chunk_file_exists}"
log_evidence_line "manifest_exists   : ${manifest_exists}"
log_box_result "$([[ "${manifest_exists}" == "true" || "${complete_log}" == "확인됨" ]] && echo PASS || echo WARN)" "complete_log=${complete_log}"
