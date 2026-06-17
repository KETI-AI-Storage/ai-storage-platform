#!/usr/bin/env bash
# 04.ai-storage-scheduler.sh는 ai-storage-scheduler가 대상 Pod를 배치한 결과만 확인한다.
# 워크로드는 인자 -> state -> 클러스터 라벨 순으로 해결한다.
#
# 사용법:
#   bash 04.ai-storage-scheduler.sh [workload_name] [namespace]
#
# Author: 미정
# Created: 2026-05-22
# Related:
#   - ai-storage-scheduler/internal/scheduler/scheduler.go
#   - year3-integration/4.integration_test/scripts/demo/runtime.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"
# shellcheck source=../runtime.sh
source "${SCRIPT_DIR}/../runtime.sh"

SCENARIO="scenario1"
ARG_WORKLOAD="${1:-}"
ARG_NAMESPACE="${2:-}"
SCHEDULER_NAME_EXPECTED="ai-storage-scheduler"
# WHY: ai-storage-scheduler가 배포되는 namespace를 라벨로 찾는다. 박지 않는다.
SCHED_DEPLOY_NS="$(kubectl get deploy -A -l app=ai-storage-scheduler \
  -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)"

init_log "04.ai-storage-scheduler"
require_cmd kubectl

echo
echo "================================"
echo "AI Storage Scheduler"
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

echo "namespace=${NAMESPACE}"
echo "workload=${WORKLOAD_NAME}"
echo "kind=${WORKLOAD_KIND:-<unknown>}"
echo "apiVersion=${API_VERSION:-<unknown>}"
echo "pod_selector=${POD_SELECTOR:-<none>}"

POD_NAME="$(get_first_pod_for_workload "${NAMESPACE}" "${WORKLOAD_KIND:-Deployment}" "${WORKLOAD_NAME}" "${API_VERSION:-apps/v1}" 2>/dev/null || true)"
echo "pod=${POD_NAME:-<none>}"
if [[ -z "${POD_NAME}" ]]; then
  echo "pod_found=false"
  echo "사유=${POD_SELECTOR} 라벨로 식별되는 Pod 없음"
  exit 0
fi

sched="$(jp get pod "${POD_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.schedulerName}')"
node_name="$(jp get pod "${POD_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.nodeName}')"
pod_scheduled_status="$(jp get pod "${POD_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="PodScheduled")].status}')"
pod_scheduled_lt="$(jp get pod "${POD_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="PodScheduled")].lastTransitionTime}')"
pod_creation_ts="$(jp get pod "${POD_NAME}" -n "${NAMESPACE}" -o jsonpath='{.metadata.creationTimestamp}')"

echo "schedulerName=${sched:-<empty>}"
echo "selected_node=${node_name:-<none>}"
echo "pod_scheduled=${pod_scheduled_status:-<empty>}"

# WHY: scenario2(06~11번) 측에서 scenario1.env를 SSoT로 읽는다.
#      Pod가 어느 노드에 떨어졌는지(=SELECTED_NODE)를 시나리오 1에서 확정해 저장한다.
if [[ -n "${node_name}" ]]; then
  state_put "scenario1" "SELECTED_NODE" "${node_name}"
fi

scheduling_elapsed="<n/a>"
if [[ -n "${pod_scheduled_lt}" && -n "${pod_creation_ts}" ]]; then
  t_sched="$(iso_to_epoch "${pod_scheduled_lt}")"
  t_create="$(iso_to_epoch "${pod_creation_ts}")"
  if [[ "${t_sched}" != "0" && "${t_create}" != "0" && "${t_sched}" -ge "${t_create}" ]]; then
    scheduling_elapsed="$((t_sched - t_create))s"
  fi
fi
echo "scheduling_time=${scheduling_elapsed}"

# scheduler 로그 요약: 점수표 원문은 노출하지 않고 핵심값만 추출.
sched_raw=""
if [[ -n "${SCHED_DEPLOY_NS}" ]]; then
  sched_raw="$(kubectl logs -n "${SCHED_DEPLOY_NS}" deploy/ai-storage-scheduler --since=10m --tail=500 2>/dev/null || true)"
fi
sched_for_pod="$(printf '%s\n' "${sched_raw}" | grep -aF "${POD_NAME}" 2>/dev/null || true)"
[[ -z "${sched_for_pod}" ]] && sched_for_pod="${sched_raw}"

score_map="$(printf '%s\n' "${sched_for_pod}" \
  | grep -aEo 'node=[A-Za-z0-9._-]+[[:space:]]+score=-?[0-9]+' \
  | awk -F'[ =]' '{print $2":"$NF}' \
  | awk '!seen[$0]++' \
  | paste -sd', ' - 2>/dev/null || true)"

cycle_s="$(printf '%s\n' "${sched_for_pod}" \
  | grep -aEo 'scheduling[_-]?cycle[^0-9-]*[0-9]+\.?[0-9]*' \
  | grep -aEo '[0-9]+\.?[0-9]*' | tail -1 2>/dev/null || true)"
bind_s="$(printf '%s\n' "${sched_for_pod}" \
  | grep -aEo 'bind[^0-9-]*[0-9]+\.?[0-9]*' \
  | grep -aEo '[0-9]+\.?[0-9]*' | tail -1 2>/dev/null || true)"

echo "score_map=${score_map:-<n/a>}"
echo "scheduling_cycle_s=${cycle_s:-<n/a>}"
echo "bind_phase_s=${bind_s:-<n/a>}"

echo "scheduler_match_true=$([[ "${sched}" == "${SCHEDULER_NAME_EXPECTED}" ]] && echo true || echo false)"
echo "node_assigned_true=$([[ -n "${node_name}" ]] && echo true || echo false)"
echo "pod_scheduled_true=$([[ "${pod_scheduled_status}" == "True" ]] && echo true || echo false)"

# ===== 시연 화면 요약 =====
SCHEDULED_LABEL="$([[ "${pod_scheduled_status}" == "True" ]] && echo true || echo false)"
log_box_start "04/11" "AI Storage Scheduler"
log_kv "namespace" "${NAMESPACE}"
log_kv "workload" "${WORKLOAD_NAME}"
log_kv "kind" "${WORKLOAD_KIND:-<unknown>}"
log_kv "pod" "${POD_NAME}"
log_kv "scheduler" "${sched}"
log_kv "selected_node" "${node_name}"
log_kv_status "scheduled" "${SCHEDULED_LABEL}"
log_kv "time" "${scheduling_elapsed}"
log_evidence_title
log_cmd "kubectl get pod ${POD_NAME} -n ${NAMESPACE} -o wide"
kubectl get pod "${POD_NAME}" -n "${NAMESPACE}" -o wide 2>/dev/null | head -5 | __demo_prefix_lines || log_evidence_line "WARN: pod 조회 실패"
log_cmd "kubectl get pod ${POD_NAME} -n ${NAMESPACE} -o jsonpath='{.spec.schedulerName}|{.spec.nodeName}'"
log_evidence_line "schedulerName : ${sched:-<empty>}"
log_evidence_line "nodeName      : ${node_name:-<none>}"
kubectl get events -n "${NAMESPACE}" --field-selector involvedObject.name="${POD_NAME}" --sort-by=.lastTimestamp 2>/dev/null \
  | grep -Ei 'Successfully assigned|failed|warning|error' | tail -5 | __demo_prefix_lines || true
log_box_result "$([[ "${SCHEDULED_LABEL}" == "true" ]] && echo PASS || echo WARN)" "scheduled=${SCHEDULED_LABEL}"
