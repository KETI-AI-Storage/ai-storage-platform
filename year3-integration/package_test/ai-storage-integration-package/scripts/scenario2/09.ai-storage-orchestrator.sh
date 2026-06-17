#!/usr/bin/env bash
# 04.ai-storage-orchestrator.sh는 ai-storage-orchestrator Pod 상태와 /health 응답만 확인한다.
# /api/v1/autoscaling, /api/v1/migrations 등 전체 목록 엔드포인트는 절대 호출하지 않는다.
#
# 사용법:
#   bash 04.ai-storage-orchestrator.sh
#
# Author: 미정
# Created: 2026-05-22
# Related:
#   - ai-storage-orchestrator
#   - year3-integration/4.integration_test/scripts/demo/runtime.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"
# shellcheck source=../runtime.sh
source "${SCRIPT_DIR}/../runtime.sh"

init_log "09.ai-storage-orchestrator"

ORCH_NS="$(kubectl get deploy -A -l app=ai-storage-orchestrator \
  -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)"

require_cmd kubectl

echo
echo "================================"
echo "AI Storage Orchestrator"
echo "================================"

[[ -n "${ORCH_NS}" ]] || die "ai-storage-orchestrator Deployment를 찾지 못했습니다."

orch_pod_name="$(jp get pods -n "${ORCH_NS}" -l app=ai-storage-orchestrator -o jsonpath='{.items[0].metadata.name}')"
orch_phase="$(jp get pods -n "${ORCH_NS}" -l app=ai-storage-orchestrator -o jsonpath='{.items[0].status.phase}')"
orch_ready="$(jp get pods -n "${ORCH_NS}" -l app=ai-storage-orchestrator -o jsonpath='{.items[0].status.containerStatuses[0].ready}')"
orch_node="$(jp get pods -n "${ORCH_NS}" -l app=ai-storage-orchestrator -o jsonpath='{.items[0].spec.nodeName}')"

echo "orchestrator_pod=${orch_pod_name:-<none>}"
echo "phase=${orch_phase:-<none>}"
echo "ready=${orch_ready:-false}"
echo "node=${orch_node:-<none>}"

if [[ -z "${orch_pod_name}" || "${orch_phase}" != "Running" ]]; then
  echo "orchestrator_running=false"
  echo "health=미확인"
  echo "version=<n/a>"
  log_box_start "09/11" "AI Storage Orchestrator"
  log_kv "pod" "${orch_pod_name}"
  log_kv "namespace" "${ORCH_NS}"
  log_kv_status "phase" "${orch_phase}"
  log_kv_status "ready" "${orch_ready}"
  log_evidence_title
  log_cmd "kubectl get pod -n ${ORCH_NS} -l app=ai-storage-orchestrator -o wide"
  kubectl get pod -n "${ORCH_NS}" -l app=ai-storage-orchestrator -o wide 2>/dev/null | head -5 | __demo_prefix_lines || true
  log_box_result "WARN" "orchestrator Pod 미실행"
  exit 0
fi

# WHY: /health 응답이 hang하더라도 화면이 멈추지 않도록 timeout으로 강제 종료. 본문은 16KB로 제한.
HEALTH_RAW="$(timeout -k 2 3 kubectl exec -n "${ORCH_NS}" "${orch_pod_name}" -- \
  sh -c 'wget -qO- --tries=1 --timeout=2 http://127.0.0.1:8080/health 2>/dev/null | head -c 16384' 2>/dev/null || true)"

health_label="미확인"
grep -aEi '"status":"healthy"' <<<"${HEALTH_RAW}" >/dev/null && health_label="healthy"
# WHY: HEALTH_RAW가 비었거나 매칭 실패하면 grep이 exit 1 → pipefail로 command substitution이 죽지 않게 보호.
version="$(grep -aoE '"version":"[^"]+"' <<<"${HEALTH_RAW}" 2>/dev/null | head -1 | sed -E 's/.*:"([^"]+)".*/\1/' || true)"

echo "health=${health_label}"
echo "version=${version:-<n/a>}"
echo "health_healthy_true=$([[ "${health_label}" == "healthy" ]] && echo true || echo false)"

# ===== 시연 화면 요약 =====
orch_logs="$(kubectl logs -n "${ORCH_NS}" "${orch_pod_name}" --since=10m --tail=500 2>/dev/null || true)"
log_box_start "09/11" "AI Storage Orchestrator"
log_kv "pod" "${orch_pod_name}"
log_kv "namespace" "${ORCH_NS}"
log_kv_status "phase" "${orch_phase}"
log_kv_status "ready" "${orch_ready}"
log_kv_status "health" "${health_label}"
log_kv "version" "${version}"
log_evidence_title
log_cmd "kubectl get pod ${orch_pod_name} -n ${ORCH_NS} -o wide"
kubectl get pod "${orch_pod_name}" -n "${ORCH_NS}" -o wide 2>/dev/null | head -5 | __demo_prefix_lines || log_evidence_line "WARN: pod 조회 실패"
log_cmd "kubectl logs -n ${ORCH_NS} ${orch_pod_name} --since=10m | grep -Ei 'policy|orchestrator|autoscal|hpa|error|warn'"
printf '%s\n' "${orch_logs}" \
  | grep -Ei 'error|fail|failed|warn|warning|policy|orchestration|orchestrator|autoscal|hpa|scale|reconcile|created|updated|target|completed' \
  | head -30 | __demo_prefix_lines || log_evidence_line "WARN: 중요 로그 없음"
log_box_result "$([[ "${health_label}" == "healthy" ]] && echo PASS || echo WARN)" "health=${health_label}"
