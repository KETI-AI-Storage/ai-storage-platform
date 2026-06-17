#!/usr/bin/env bash
# 03.orchestration-policy-engine.sh는 orchestration-policy-engine Pod 상태와
# PolicyGenerator / Got recommendations / Found target workload / Reconciling 로그 4종의
# 존재 여부만 요약한다. 원문은 노출하지 않으며, grep -a로 바이너리 경고를 차단한다.
#
# 사용법:
#   bash 03.orchestration-policy-engine.sh
#
# Author: 미정
# Created: 2026-05-22
# Related:
#   - apollo/orchestration-policy-engine/cmd/main.go
#   - year3-integration/4.integration_test/scripts/demo/runtime.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"
# shellcheck source=../runtime.sh
source "${SCRIPT_DIR}/../runtime.sh"

init_log "08.orchestration-policy-engine"

POLICY_ENGINE_NS="$(kubectl get deploy -A -l app=orchestration-policy-engine \
  -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)"

require_cmd kubectl

echo
echo "================================"
echo "Orchestration Policy Engine"
echo "================================"

[[ -n "${POLICY_ENGINE_NS}" ]] || die "orchestration-policy-engine Deployment를 찾지 못했습니다."

pe_pod_name="$(jp get pods -n "${POLICY_ENGINE_NS}" -l app=orchestration-policy-engine -o jsonpath='{.items[0].metadata.name}')"
pe_phase="$(jp get pods -n "${POLICY_ENGINE_NS}" -l app=orchestration-policy-engine -o jsonpath='{.items[0].status.phase}')"
pe_ready="$(jp get pods -n "${POLICY_ENGINE_NS}" -l app=orchestration-policy-engine -o jsonpath='{.items[0].status.containerStatuses[0].ready}')"
pe_node="$(jp get pods -n "${POLICY_ENGINE_NS}" -l app=orchestration-policy-engine -o jsonpath='{.items[0].spec.nodeName}')"

echo "policy_engine_pod=${pe_pod_name:-<none>}"
echo "phase=${pe_phase:-<none>}"
echo "ready=${pe_ready:-false}"
echo "node=${pe_node:-<none>}"

if [[ -z "${pe_pod_name}" || "${pe_phase}" != "Running" ]]; then
  echo "policy_engine_running=false"
  echo "사유=policy-engine Pod 미실행"
  log_box_start "08/11" "Orchestration Policy Engine"
  log_kv "pod" "${pe_pod_name}"
  log_kv "namespace" "${POLICY_ENGINE_NS}"
  log_kv_status "phase" "${pe_phase}"
  log_kv_status "ready" "${pe_ready}"
  log_evidence_title
  log_cmd "kubectl get pod -n ${POLICY_ENGINE_NS} -l app=orchestration-policy-engine -o wide"
  kubectl get pod -n "${POLICY_ENGINE_NS}" -l app=orchestration-policy-engine -o wide 2>/dev/null | head -5 | __demo_prefix_lines || true
  log_box_result "WARN" "policy-engine Pod 미실행"
  exit 0
fi

pe_logs="$(kubectl logs -n "${POLICY_ENGINE_NS}" deploy/orchestration-policy-engine --since=10m --tail=1000 2>/dev/null || true)"

policy_generator="미확인"
recommendation_log="미확인"
target_workload_log="미확인"
reconcile_log="미확인"

grep -aE 'PolicyGenerator.*Running policy generation cycle' <<<"${pe_logs}" >/dev/null && policy_generator="동작 중"
if [[ "${policy_generator}" == "미확인" ]]; then
  grep -aE '\[PolicyGenerator\]' <<<"${pe_logs}" >/dev/null && policy_generator="동작 중"
fi
grep -aEi 'Got recommendations' <<<"${pe_logs}" >/dev/null && recommendation_log="확인됨"
grep -aEi 'Found target workload' <<<"${pe_logs}" >/dev/null && target_workload_log="확인됨"
grep -aEi 'Reconciling OrchestrationPolicy' <<<"${pe_logs}" >/dev/null && reconcile_log="확인됨"

echo "policy_generator=${policy_generator}"
echo "recommendation_log=${recommendation_log}"
echo "target_workload_log=${target_workload_log}"
echo "reconcile_log=${reconcile_log}"

echo "policy_generator_running_true=$([[ "${policy_generator}" == "동작 중" ]] && echo true || echo false)"
echo "reconcile_log_present_true=$([[ "${reconcile_log}" == "확인됨" ]] && echo true || echo false)"

# ===== 시연 화면 요약 =====
RECON_LABEL="$([[ "${reconcile_log}" == "확인됨" ]] && echo true || echo false)"
log_box_start "08/11" "Orchestration Policy Engine"
log_kv "pod" "${pe_pod_name}"
log_kv "namespace" "${POLICY_ENGINE_NS}"
log_kv_status "phase" "${pe_phase}"
log_kv_status "ready" "${pe_ready}"
log_kv_status "reconcile_log" "${RECON_LABEL}"
log_evidence_title
log_cmd "kubectl get pod ${pe_pod_name} -n ${POLICY_ENGINE_NS} -o wide"
kubectl get pod "${pe_pod_name}" -n "${POLICY_ENGINE_NS}" -o wide 2>/dev/null | head -5 | __demo_prefix_lines || log_evidence_line "WARN: pod 조회 실패"
log_cmd "kubectl logs -n ${POLICY_ENGINE_NS} ${pe_pod_name} --since=10m | grep -Ei 'policy|reconcile|error|warn|created|updated|target|completed'"
printf '%s\n' "${pe_logs}" \
  | grep -Ei 'error|fail|failed|warn|warning|policy|orchestration|reconcile|created|updated|target|completed' \
  | head -30 | __demo_prefix_lines || log_evidence_line "WARN: 중요 로그 없음"
log_box_result "$([[ "${RECON_LABEL}" == "true" ]] && echo PASS || echo WARN)" "reconcile_log=${RECON_LABEL}"
