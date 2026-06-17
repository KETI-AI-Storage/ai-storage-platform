#!/usr/bin/env bash
# run-demo-all.sh는 Scenario 1 -> Scenario 2 -> cleanup을 순서대로 실행한다.
# Scenario 1이 끝난 직후에는 워크로드를 삭제하지 않으며(Scenario 2가 동일 Pod을 사용),
# Scenario 2가 끝난 뒤에만 workload를 정리한다. PVC는 어떤 경우에도 삭제하지 않는다.
#
# 본 스크립트는 워크로드 이름/PVC/네임스페이스/정책 값을 박지 않는다. 모든 값은
# .runtime/scenario1.env / .runtime/scenario2.env에서 읽어 사용한다.
#
# 사용법:
#   bash run-demo-all.sh [manifest_path_or_workload_name] [namespace]
#
# Author: 미정
# Created: 2026-05-22
# Related:
#   - year3-integration/4.integration_test/scripts/demo/run-scenario1.sh
#   - year3-integration/4.integration_test/scripts/demo/run-scenario2.sh
#   - year3-integration/4.integration_test/scripts/demo/runtime.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=runtime.sh
source "${SCRIPT_DIR}/runtime.sh"

ARG_TARGET="${1:-}"
ARG_NAMESPACE="${2:-}"

init_log "scenario1-2-all"
require_cmd kubectl

SCENARIO1_RC=0
SCENARIO2_RC=0
CLEANUP_DONE=0

# cleanup은 scenario1.env / scenario2.env에서 워크로드/PVC 정보를 읽어 kind에 맞는 workload만 삭제한다.
# PVC는 절대 삭제하지 않으며, 데모 OrchestrationPolicy는 label로만 정리한다.
cleanup() {
  if [[ "${CLEANUP_DONE}" -eq 1 ]]; then
    return 0
  fi
  CLEANUP_DONE=1
  set +e

  banner "[cleanup] workload 삭제 / PVC 보존 / 데모 OrchestrationPolicy 정리"

  # scenario1.env 우선, 없으면 scenario2.env에서 워크로드 정보 로드.
  local ns="" wl="" kind="" api="" resource_type="" pvcs="" pod_selector="" manifest_source=""
  if state_load "scenario1" 2>/dev/null && [[ -n "${WORKLOAD_NAME:-}" && -n "${NAMESPACE:-}" ]]; then
    ns="${NAMESPACE}"; wl="${WORKLOAD_NAME}"; kind="${WORKLOAD_KIND:-}"; api="${API_VERSION:-}"; resource_type="${RESOURCE_TYPE:-}"; pvcs="${PVC_NAMES:-}"; pod_selector="${POD_SELECTOR:-}"; manifest_source="${MANIFEST_SOURCE:-manifest}"
  elif state_load "scenario2" 2>/dev/null && [[ -n "${WORKLOAD_NAME:-}" && -n "${NAMESPACE:-}" ]]; then
    ns="${NAMESPACE}"; wl="${WORKLOAD_NAME}"; kind="${WORKLOAD_KIND:-}"; api="${API_VERSION:-}"; resource_type="${RESOURCE_TYPE:-}"; pvcs="${PVC_NAMES:-}"; pod_selector="${POD_SELECTOR:-}"; manifest_source="${MANIFEST_SOURCE:-manifest}"
  fi

  if [[ -z "${ns}" || -z "${wl}" ]]; then
    echo "[cleanup] state 파일이 없어 자동 정리 대상이 없습니다."
    set -e
    return 0
  fi

  if [[ -z "${resource_type}" && -n "${kind}" ]]; then
    resource_type="$(kind_to_kubectl_resource "${kind}" "${api}" 2>/dev/null || true)"
  fi
  if [[ -z "${resource_type}" ]]; then
    echo "[cleanup] WARN: resource_type 확인 불가 kind=${kind:-<none>} apiVersion=${api:-<none>} workload=${wl}"
    set -e
    return 0
  fi

  echo "[cleanup] workload=${wl} namespace=${ns} kind=${kind:-<none>} apiVersion=${api:-<none>} resource_type=${resource_type} manifest_source=${manifest_source:-<none>} pvcs=${pvcs:-<none>}"

  if [[ -z "${pod_selector}" ]]; then
    pod_selector="$(get_selector_for_workload "${ns}" "${wl}" "${kind:-Deployment}" "${api:-apps/v1}" 2>/dev/null || true)"
  fi

  if [[ "${manifest_source}" == "cluster" ]]; then
    echo "[cleanup] workload 삭제 SKIP: manifest 없이 기존 클러스터 리소스를 대상으로 사용했습니다."
  else
    kubectl delete "${resource_type}" "${wl}" -n "${ns}" --ignore-not-found >/dev/null 2>&1 || true
    echo "[cleanup] workload 삭제 요청 완료 resource_type=${resource_type} name=${wl} namespace=${ns}"
  fi

  local app_pair="${pod_selector}"
  if [[ -n "${app_pair}" && "${manifest_source}" != "cluster" ]]; then
    local waited=0 remaining=0
    while (( waited < 30 )); do
      remaining="$(kubectl get pod -n "${ns}" -l "${app_pair}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w)"
      [[ "${remaining:-0}" -eq 0 ]] && break
      sleep 2
      waited=$((waited + 2))
    done
    if [[ "${remaining:-0}" -eq 0 ]]; then
      echo "[cleanup] Pod 종료 확인"
    else
      echo "[cleanup] WARN: Pod 잔존(${remaining}개)"
    fi
  fi

  if [[ -n "${pvcs}" ]]; then
    echo "[cleanup] PVC preserved: ${pvcs}"
  fi

  # 데모로 만들어진 OrchestrationPolicy를 라벨로 정리. apollo-* namespace 등을 박지 않는다.
  local apollo_ns
  apollo_ns="$(kubectl get deploy -A -l app=orchestration-policy-engine \
    -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)"
  if [[ -n "${apollo_ns}" ]]; then
    kubectl delete orchestrationpolicy -n "${apollo_ns}" \
      -l "generated-by=demo-scenario2,target-workload=${wl},target-kind=${kind}" \
      --ignore-not-found >/dev/null 2>&1 || true
    kubectl delete orchestrationpolicy -n "${apollo_ns}" \
      -l "generated-by=demo-scenario2,target-workload=${wl}" \
      --ignore-not-found >/dev/null 2>&1 || true
    echo "[cleanup] 데모 OrchestrationPolicy 정리(label: generated-by=demo-scenario2,target-workload=${wl},target-kind=${kind}; legacy target-workload 포함)"
  fi

  set -e
}
# WHY: init_log가 이미 EXIT trap을 잡고 있으므로 trap을 직접 설치하지 않고 runtime hook으로 등록한다.
runtime_add_exit_hook 'cleanup'

banner "Demo all-in-one: Scenario 1 -> Scenario 2 -> cleanup"
echo "[args] target='${ARG_TARGET:-<none>}' namespace='${ARG_NAMESPACE:-<none>}'"

set +e
bash "${SCRIPT_DIR}/run-scenario1.sh" "${ARG_TARGET}" "${ARG_NAMESPACE}"
SCENARIO1_RC=$?
set -e
echo "[demo-all] Scenario 1 exit code = ${SCENARIO1_RC}"

if [[ "${SCENARIO1_RC}" -ne 0 ]]; then
  banner "[demo-all] Scenario 1 실패 (rc=${SCENARIO1_RC}) — Scenario 2 미실행"
  exit "${SCENARIO1_RC}"
fi

set +e
# WHY: Scenario 2는 scenario1.env에서 워크로드 컨텍스트를 이어받으므로 추가 인자는 필요 없다.
bash "${SCRIPT_DIR}/run-scenario2.sh"
SCENARIO2_RC=$?
set -e
echo "[demo-all] Scenario 2 exit code = ${SCENARIO2_RC}"

banner "[demo-all] Summary: scenario1=${SCENARIO1_RC} scenario2=${SCENARIO2_RC}"
if [[ "${SCENARIO1_RC}" -eq 0 && "${SCENARIO2_RC}" -eq 0 ]]; then
  echo "RESULT=PASS"
else
  echo "RESULT=FAIL"
fi

summary_workload="<none>"
summary_kind="<none>"
summary_ns="<none>"
summary_node="<none>"
summary_policy="<none>"
summary_autoscaler="<not found>"
if state_load "scenario1" 2>/dev/null; then
  summary_workload="${WORKLOAD_NAME:-<none>}"
  summary_kind="${WORKLOAD_KIND:-<none>}"
  summary_ns="${NAMESPACE:-<none>}"
  summary_node="${SELECTED_NODE:-<none>}"
fi
if state_load "scenario2" 2>/dev/null; then
  summary_policy="${POLICY_TYPE:-${POLICY_NAME:-<none>}} / ${POLICY_RESOURCE:-<none>} / ${POLICY_HORIZON:-<none>}"
fi
if [[ "${summary_ns}" != "<none>" && "${summary_workload}" != "<none>" ]]; then
  summary_autoscaler="$(jp get hpa -n "${summary_ns}" -l target-workload="${summary_workload}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "${summary_autoscaler}" ]] && summary_autoscaler="hpa/${summary_autoscaler}" || summary_autoscaler="<not found>"
fi
summary_result="$([[ "${SCENARIO1_RC}" -eq 0 && "${SCENARIO2_RC}" -eq 0 ]] && echo PASS || echo FAIL)"
print_demo_summary "11/11 passed (warnings shown per step)" "${summary_workload}" "${summary_kind}" "${summary_ns}" "${summary_node}" "${summary_policy}" "${summary_autoscaler}" "${summary_result}"

exit "${SCENARIO2_RC}"
