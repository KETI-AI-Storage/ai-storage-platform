#!/usr/bin/env bash
# 06.orchestration-compare.sh는 정책 실행 전후 워크로드 상태 스냅샷을 캡처/비교한다.
# 실제 kubectl scale / kubectl apply / kubectl delete 는 호출하지 않으며 순수 관측 전용이다.
# 워크로드 컨텍스트는 .runtime/scenario2.env(없으면 scenario1.env)에서 읽고,
# 특정 워크로드 이름/PVC/정책 번호를 박지 않는다.
#
# 사용법(인자는 모두 선택):
#   bash 06.orchestration-compare.sh          # 인자 없음 → compare 기본 실행
#   bash 06.orchestration-compare.sh before   # 현재 상태를 before로 저장
#   bash 06.orchestration-compare.sh after    # 현재 상태를 after로 저장
#   bash 06.orchestration-compare.sh compare  # before/after 비교
#
# compare 모드에서 before/after 파일이 없으면 그 자리에서 현재 상태로 자동 보충한다.
#
# Author: 미정
# Created: 2026-05-22
# Related:
#   - year3-integration/4.integration_test/scripts/demo/scenario2/10.orchestration-policy.sh
#   - year3-integration/4.integration_test/scripts/demo/runtime.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"
# shellcheck source=../runtime.sh
source "${SCRIPT_DIR}/../runtime.sh"

# 인자 기본값: 없으면 compare.
MODE="${1:-compare}"
case "${MODE}" in
  before|after|compare) ;;
  *)
    echo "invalid_mode=${MODE}"
    echo "안내=mode는 before / after / compare 중 하나여야 합니다(인자 없으면 compare)."
    exit 0
    ;;
esac

init_log "11.orchestration-compare"
require_cmd kubectl

# 워크로드 컨텍스트 = scenario1.env SSoT (인자 없으면 scenario1.env에서 읽음).
load_workload_context "" ""
NAMESPACE="${CTX_NAMESPACE}"
WORKLOAD_NAME="${CTX_WORKLOAD_NAME}"
WORKLOAD_KIND="${CTX_WORKLOAD_KIND}"
API_VERSION="${CTX_API_VERSION}"
RESOURCE_TYPE="${CTX_RESOURCE_TYPE}"
APP_LABEL_KEY="${CTX_APP_LABEL_KEY}"
APP_LABEL_VALUE="${CTX_APP_LABEL_VALUE}"
POD_SELECTOR="${CTX_POD_SELECTOR}"
SOURCE_PVC_NAMES="$(STATE_FILE="$(state_file_path scenario1)" bash -c 'source "$STATE_FILE" 2>/dev/null; printf "%s" "${PVC_NAMES:-}"')"

read_scenario2_key() {
  local key="${1:?key}" f
  f="$(state_file_path scenario2)"
  [[ -f "${f}" ]] || return 0
  KEY_NAME="${key}" bash -c 'source "$1" 2>/dev/null; printf "%s" "${!KEY_NAME:-}"' _ "${f}"
}

POLICY_TYPE="$(read_scenario2_key POLICY_TYPE)"
POLICY_CR_NAME="$(read_scenario2_key POLICY_NAME)"
POLICY_ID="$(read_scenario2_key POLICY_ID)"
POLICY_OPERATOR_TYPE="$(read_scenario2_key POLICY_OPERATOR_TYPE)"
POLICY_OPERATOR_STATUS="$(read_scenario2_key POLICY_OPERATOR_STATUS)"
[[ -n "${POLICY_OPERATOR_TYPE}" ]] || POLICY_OPERATOR_TYPE="${POLICY_TYPE}"

SNAPSHOT_DIR="${RUNTIME_DIR}/snapshots"
mkdir -p "${SNAPSHOT_DIR}"
SNAPSHOT_BEFORE="${SNAPSHOT_DIR}/orchestration-before.env"
SNAPSHOT_AFTER="${SNAPSHOT_DIR}/orchestration-after.env"

echo
echo "================================"
echo "Orchestration Compare"
echo "================================"
echo "mode=${MODE}"
echo "namespace=${NAMESPACE:-<none>}"
echo "workload=${WORKLOAD_NAME:-<none>}"
echo "kind=${WORKLOAD_KIND:-<none>}"
echo "apiVersion=${API_VERSION:-<none>}"
echo "resource_type=${RESOURCE_TYPE:-<none>}"
echo "pod_selector=${POD_SELECTOR}"
echo "policy_type=${POLICY_TYPE:-<none>}"
echo "policy_id=${POLICY_ID:-<none>}"
echo "before_file=${SNAPSHOT_BEFORE}"
echo "after_file=${SNAPSHOT_AFTER}"
print_workload_context

if [[ -z "${WORKLOAD_NAME}" || -z "${NAMESPACE}" ]]; then
  echo "workload_resolved=false"
  echo "안내=워크로드 컨텍스트를 해결하지 못해 스냅샷을 생성하지 않습니다. scenario1(01.preprocessing-workload.sh)을 먼저 실행하세요."
  exit 0
fi

operator_endpoint_for_policy() {
  case "${1:-}" in
    scaling|autoscaling) echo "autoscaling" ;;
    migration) echo "migrations" ;;
    provisioning) echo "provisioning" ;;
    caching) echo "caching" ;;
    loadbalance|loadbalancing) echo "loadbalancing" ;;
    preemption) echo "preemption" ;;
    *) return 1 ;;
  esac
}

fetch_operator_resource() {
  local policy_type="${1:-}" resource_id="${2:-}" endpoint orch_ns orch_pod
  [[ -n "${policy_type}" && -n "${resource_id}" ]] || return 0
  endpoint="$(operator_endpoint_for_policy "${policy_type}" 2>/dev/null || true)"
  [[ -n "${endpoint}" ]] || return 0
  orch_ns="$(kubectl get deploy -A -l app=ai-storage-orchestrator -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)"
  [[ -n "${orch_ns}" ]] || return 0
  orch_pod="$(kubectl get pod -n "${orch_ns}" -l app=ai-storage-orchestrator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "${orch_pod}" ]] || return 0
  kubectl exec -n "${orch_ns}" "${orch_pod}" -- \
    sh -c "wget -qO- --tries=1 --timeout=2 http://127.0.0.1:8080/api/v1/${endpoint}/${resource_id} 2>/dev/null | head -c 8192" 2>/dev/null || true
}

summarize_operator_json() {
  python3 -c '
import json, sys
raw = sys.stdin.read().strip()
if not raw:
    print("OPERATOR_API_STATUS=")
    print("OPERATOR_API_DETAILS=")
    sys.exit(0)
try:
    data = json.loads(raw)
except Exception:
    print("OPERATOR_API_STATUS=parse_error")
    print("OPERATOR_API_DETAILS=" + raw[:200].replace("\n", " "))
    sys.exit(0)
status = data.get("status") or ""
details = data.get("details") or {}
parts = []
for key in ("hpa_name", "pvc_name", "current_replicas", "desired_replicas",
            "pods_to_migrate", "successful_migrations", "pods_to_preempt",
            "successful_preemptions", "target_achieved", "cache_size_bytes",
            "source_pvc", "target_tier"):
    if isinstance(details, dict) and key in details:
        parts.append(f"{key}:{details.get(key)}")
print("OPERATOR_API_STATUS=" + str(status))
print("OPERATOR_API_DETAILS=" + ",".join(parts))
'
}

# WHY: 현재 워크로드 상태를 KEY=VAL 한 줄 단위로 캡처해 source 가능한 env 파일로 저장한다.
capture_state() {
  local replicas ready cpu_req mem_req gpu_req pod_names pod_count node phase pod_csv uid_csv node_csv migrated_csv migrated_node_csv
  local pvc_csv pvc_phase_csv pvc_provisioning_csv source_pvc_exists node_counts event_count eviction_event_count prefetch_event_count
  local operator_raw operator_summary operator_status operator_details
  if [[ -n "${RESOURCE_TYPE}" ]]; then
    read -r replicas ready cpu_req mem_req gpu_req < <(kubectl get "${RESOURCE_TYPE}" -n "${NAMESPACE}" "${WORKLOAD_NAME}" -o json 2>/dev/null | python3 -c '
import json, sys
try:
    d=json.load(sys.stdin)
except Exception:
    print("0 0 <none> <none> <none>")
    sys.exit(0)
kind=d.get("kind","")
spec=d.get("spec") or {}
status=d.get("status") or {}
replicas = spec.get("replicas", "")
ready = status.get("readyReplicas", "")
if kind == "DaemonSet":
    replicas = status.get("desiredNumberScheduled", "")
    ready = status.get("numberReady", "")
elif kind == "Job":
    replicas = spec.get("completions", "")
    ready = status.get("succeeded", "")
elif kind == "CronJob":
    replicas = "<n/a>"
    ready = len(status.get("active") or [])
elif kind in ("Workflow","PyTorchJob","TFJob","MPIJob"):
    replicas = "<n/a>"
    ready = status.get("phase") or "<n/a>"
def find_containers(x):
    if isinstance(x, dict):
        if isinstance(x.get("containers"), list):
            return x.get("containers")
        for v in x.values():
            got=find_containers(v)
            if got:
                return got
    elif isinstance(x, list):
        for v in x:
            got=find_containers(v)
            if got:
                return got
    return []
containers=find_containers(spec)
req=((containers[0].get("resources") or {}).get("requests") or {}) if containers else {}
print("{} {} {} {} {}".format(replicas or "0", ready or "0", req.get("cpu","<none>"), req.get("memory","<none>"), req.get("nvidia.com/gpu","<none>")))
' || true)
  fi
  pod_names="$(get_pods_for_workload "${NAMESPACE}" "${WORKLOAD_KIND:-Deployment}" "${WORKLOAD_NAME}" "${API_VERSION:-apps/v1}" 2>/dev/null || true)"
  pod_count="$(printf '%s' "${pod_names}" | grep -c '^[^[:space:]]' || true)"
  pod_csv="$(printf '%s\n' "${pod_names}" | sed '/^$/d' | paste -sd',' -)"
  uid_csv=""
  node_csv=""
  while IFS= read -r p; do
    [[ -n "${p}" ]] || continue
    local uid n
    uid="$(jp get pod "${p}" -n "${NAMESPACE}" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
    n="$(jp get pod "${p}" -n "${NAMESPACE}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
    uid_csv+="${uid_csv:+,}${p}:${uid:-<none>}"
    node_csv+="${node_csv:+,}${p}:${n:-<none>}"
  done <<<"${pod_names}"
  local first_pod
  first_pod="$(printf '%s\n' "${pod_names}" | head -1)"
  if [[ -n "${first_pod}" ]]; then
    node="$(jp get pod "${first_pod}" -n "${NAMESPACE}" -o jsonpath='{.spec.nodeName}')"
    phase="$(jp get pod "${first_pod}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}')"
  fi
  migrated_csv="$(kubectl get pod -n "${NAMESPACE}" -l migration.ai-storage/job=true -o jsonpath='{range .items[*]}{.metadata.name}{","}{end}' 2>/dev/null | sed 's/,$//' || true)"
  migrated_node_csv="$(kubectl get pod -n "${NAMESPACE}" -l migration.ai-storage/job=true -o jsonpath='{range .items[*]}{.metadata.name}{":"}{.spec.nodeName}{","}{end}' 2>/dev/null | sed 's/,$//' || true)"
  pvc_csv="$(kubectl get pvc -n "${NAMESPACE}" -l "app=ai-storage-orchestrator,component=provisioning,workload-name=${WORKLOAD_NAME}" -o jsonpath='{range .items[*]}{.metadata.name}{","}{end}' 2>/dev/null | sed 's/,$//' || true)"
  pvc_phase_csv="$(kubectl get pvc -n "${NAMESPACE}" -l "app=ai-storage-orchestrator,component=provisioning,workload-name=${WORKLOAD_NAME}" -o jsonpath='{range .items[*]}{.metadata.name}{":"}{.status.phase}{","}{end}' 2>/dev/null | sed 's/,$//' || true)"
  pvc_provisioning_csv="$(kubectl get pvc -n "${NAMESPACE}" -l "app=ai-storage-orchestrator,component=provisioning,workload-name=${WORKLOAD_NAME}" -o jsonpath='{range .items[*]}{.metadata.name}{":"}{.metadata.labels.provisioning-id}{","}{end}' 2>/dev/null | sed 's/,$//' || true)"
  source_pvc_exists=false
  local pvc_candidate
  while IFS= read -r pvc_candidate; do
    [[ -n "${pvc_candidate}" ]] || continue
    if kubectl get pvc "${pvc_candidate}" -n "${NAMESPACE}" >/dev/null 2>&1; then
      source_pvc_exists=true
      break
    fi
  done < <(printf '%s\n' "${SOURCE_PVC_NAMES:-${WORKLOAD_NAME}-pvc}" | tr ',' '\n')
  node_counts="$(kubectl get pod -A -o json 2>/dev/null | python3 -c '
import json, sys
try:
    data=json.load(sys.stdin)
except Exception:
    print("")
    sys.exit(0)
counts={}
for item in data.get("items", []):
    node=(item.get("spec") or {}).get("nodeName") or "<none>"
    counts[node]=counts.get(node,0)+1
print(",".join(f"{k}:{counts[k]}" for k in sorted(counts)))
' || true)"
  event_count="$(kubectl get events -n "${NAMESPACE}" --sort-by=.lastTimestamp 2>/dev/null | grep -E "${WORKLOAD_NAME}|${POLICY_ID:-__none__}|cache-prefetch|Evict|Killing|Preempt" | wc -l | tr -d ' ' || true)"
  eviction_event_count="$(kubectl get events -n "${NAMESPACE}" --sort-by=.lastTimestamp 2>/dev/null | grep -Ei 'evict|preempt|killing' | wc -l | tr -d ' ' || true)"
  prefetch_event_count="$(kubectl get events -n "${NAMESPACE}" --sort-by=.lastTimestamp 2>/dev/null | grep -E 'cache-prefetch' | wc -l | tr -d ' ' || true)"
  operator_raw="$(fetch_operator_resource "${POLICY_OPERATOR_TYPE:-${POLICY_TYPE}}" "${POLICY_ID}")"
  operator_summary="$(printf '%s' "${operator_raw}" | summarize_operator_json)"
  operator_status="$(grep -aE '^OPERATOR_API_STATUS=' <<<"${operator_summary}" | sed 's/^OPERATOR_API_STATUS=//' || true)"
  operator_details="$(grep -aE '^OPERATOR_API_DETAILS=' <<<"${operator_summary}" | sed 's/^OPERATOR_API_DETAILS=//' || true)"
  printf 'REPLICAS=%s\n' "${replicas:-0}"
  printf 'READY=%s\n' "${ready:-0}"
  printf 'POD_COUNT=%s\n' "${pod_count:-0}"
  printf 'POD_NAMES=%s\n' "${pod_csv:-}"
  printf 'POD_UIDS=%s\n' "${uid_csv:-}"
  printf 'POD_NODES=%s\n' "${node_csv:-}"
  printf 'MIGRATED_PODS=%s\n' "${migrated_csv:-}"
  printf 'MIGRATED_NODES=%s\n' "${migrated_node_csv:-}"
  printf 'PVC_NAMES=%s\n' "${pvc_csv:-}"
  printf 'PVC_PHASES=%s\n' "${pvc_phase_csv:-}"
  printf 'PVC_PROVISIONING_IDS=%s\n' "${pvc_provisioning_csv:-}"
  printf 'SOURCE_PVC_EXISTS=%s\n' "${source_pvc_exists:-false}"
  printf 'NODE_POD_COUNTS=%s\n' "${node_counts:-}"
  printf 'EVENT_COUNT=%s\n' "${event_count:-0}"
  printf 'EVICTION_EVENT_COUNT=%s\n' "${eviction_event_count:-0}"
  printf 'PREFETCH_EVENT_COUNT=%s\n' "${prefetch_event_count:-0}"
  printf 'OPERATOR_API_STATUS=%s\n' "${operator_status:-}"
  printf 'OPERATOR_API_DETAILS=%s\n' "${operator_details:-}"
  printf 'NODE=%s\n' "${node:-<none>}"
  printf 'PHASE=%s\n' "${phase:-<none>}"
  printf 'CPU_REQ=%s\n' "${cpu_req:-<none>}"
  printf 'MEM_REQ=%s\n' "${mem_req:-<none>}"
  printf 'GPU_REQ=%s\n' "${gpu_req:-<none>}"
  printf 'CAPTURED_AT=%s\n' "$(date -Iseconds)"
}

load_snapshot() {
  local file="$1" prefix="$2" k v
  [[ -f "${file}" ]] || return 1
  while IFS='=' read -r k v; do
    [[ -z "${k}" ]] && continue
    case "${k}" in
      REPLICAS|READY|POD_COUNT|POD_NAMES|POD_UIDS|POD_NODES|MIGRATED_PODS|MIGRATED_NODES|PVC_NAMES|PVC_PHASES|PVC_PROVISIONING_IDS|SOURCE_PVC_EXISTS|NODE_POD_COUNTS|EVENT_COUNT|EVICTION_EVENT_COUNT|PREFETCH_EVENT_COUNT|OPERATOR_API_STATUS|OPERATOR_API_DETAILS|NODE|PHASE|CPU_REQ|MEM_REQ|GPU_REQ|CAPTURED_AT)
        declare -g "${prefix}${k}=${v}" ;;
    esac
  done < "${file}"
  return 0
}

print_snapshot_summary() {
  local label="$1"; shift
  local file="$1"
  echo
  echo "${label}_snapshot_file=${file}"
  [[ -f "${file}" ]] || { echo "${label}_present=false"; return; }
  echo "${label}_present=true"
  while IFS= read -r line; do
    echo "  ${label}.${line}"
  done < "${file}"
}

case "${MODE}" in
  before)
    capture_state > "${SNAPSHOT_BEFORE}"
    echo "snapshot_saved=true"
    echo "snapshot_path=${SNAPSHOT_BEFORE}"
    print_snapshot_summary "before" "${SNAPSHOT_BEFORE}"
    exit 0
    ;;
  after)
    capture_state > "${SNAPSHOT_AFTER}"
    echo "snapshot_saved=true"
    echo "snapshot_path=${SNAPSHOT_AFTER}"
    print_snapshot_summary "after" "${SNAPSHOT_AFTER}"
    exit 0
    ;;
esac

# compare 모드: before/after가 없으면 그 자리에서 자동 보충.
auto_filled_before=false
auto_filled_after=false
if [[ ! -s "${SNAPSHOT_BEFORE}" ]]; then
  echo "before_auto_capture=true"
  capture_state > "${SNAPSHOT_BEFORE}"
  auto_filled_before=true
fi
if [[ ! -s "${SNAPSHOT_AFTER}" ]]; then
  echo "after_auto_capture=true"
  capture_state > "${SNAPSHOT_AFTER}"
  auto_filled_after=true
fi
echo "before_auto_filled=${auto_filled_before}"
echo "after_auto_filled=${auto_filled_after}"

load_snapshot "${SNAPSHOT_BEFORE}" "B_" || true
load_snapshot "${SNAPSHOT_AFTER}"  "A_" || true

changed=0
notes=""
add_note() { changed=1; notes="${notes}${1}; "; }

value_in_csv() {
  local needle="${1:-}" csv="${2:-}"
  [[ -n "${needle}" ]] || return 1
  case ",${csv}," in
    *",${needle},"*) return 0 ;;
    *) return 1 ;;
  esac
}

int_gt() {
  local a="${1:-0}" b="${2:-0}"
  [[ "${a}" =~ ^[0-9]+$ ]] || a=0
  [[ "${b}" =~ ^[0-9]+$ ]] || b=0
  (( a > b ))
}

POLICY_RESULT_LABEL="WARN"
POLICY_REASON="정책별 실제 Kubernetes 리소스 변화가 확인되지 않았습니다."

case "${POLICY_TYPE}" in
  scaling|autoscaling)
    [[ "${B_REPLICAS:-}" != "${A_REPLICAS:-}" ]] && add_note "replicas ${B_REPLICAS:-0} -> ${A_REPLICAS:-0}"
    [[ "${B_READY:-}" != "${A_READY:-}" ]] && add_note "readyReplicas ${B_READY:-0} -> ${A_READY:-0}"
    [[ "${B_POD_COUNT:-}" != "${A_POD_COUNT:-}" ]] && add_note "pod_count ${B_POD_COUNT:-0} -> ${A_POD_COUNT:-0}"
    if [[ "${changed}" -eq 1 ]]; then
      POLICY_RESULT_LABEL="PASS"
      POLICY_REASON="autoscaling 실제 적용 확인: ${notes%; }"
    else
      POLICY_REASON="autoscaler는 생성됐을 수 있으나 replicas/ready/pod_count 변화가 없습니다."
    fi
    ;;
  migration)
    original_deleted=false
    while IFS= read -r p; do
      [[ -n "${p}" ]] || continue
      if ! value_in_csv "${p}" "${A_POD_NAMES:-}"; then
        original_deleted=true
        break
      fi
    done < <(printf '%s' "${B_POD_NAMES:-}" | tr ',' '\n')
    [[ "${B_MIGRATED_PODS:-}" != "${A_MIGRATED_PODS:-}" && -n "${A_MIGRATED_PODS:-}" ]] && add_note "migrated_pods ${B_MIGRATED_PODS:-<none>} -> ${A_MIGRATED_PODS}"
    [[ "${B_MIGRATED_NODES:-}" != "${A_MIGRATED_NODES:-}" && -n "${A_MIGRATED_NODES:-}" ]] && add_note "migrated_nodes ${B_MIGRATED_NODES:-<none>} -> ${A_MIGRATED_NODES}"
    [[ "${original_deleted}" == "true" ]] && add_note "original_pod_deleted=true"

    # WHY: 시연 워크로드의 PVC 는 RWO 라 다른 노드로 옮길 수 없으므로
    #      00.demo-prereqs-setup.sh 가 띄운 PVC-less migration 전용 워크로드를 보조 판정 대상으로 본다.
    #      별도 라벨(app=demo-migration-workload) Pod 의 현재 상태 + migrated-* Pod 신규 등장을 함께 인정한다.
    demo_mig_running="$(kubectl get pod -n "${NAMESPACE}" -l app=demo-migration-workload --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.metadata.name}{","}{end}' 2>/dev/null | sed 's/,$//' || true)"
    demo_mig_changed=false
    if [[ -n "${A_MIGRATED_PODS:-}" ]]; then
      while IFS= read -r mp; do
        [[ -n "${mp}" ]] || continue
        case "${mp}" in
          *-migrated-*)
            demo_mig_changed=true
            break ;;
        esac
      done < <(printf '%s' "${A_MIGRATED_PODS}" | tr ',' '\n')
    fi
    [[ "${demo_mig_changed}" == "true" ]] && add_note "migrated_label_pod_present=true; demo_migration_running=${demo_mig_running:-<none>}"

    if [[ "${original_deleted}" == "true" && -n "${A_MIGRATED_PODS:-}" ]]; then
      POLICY_RESULT_LABEL="PASS"
      POLICY_REASON="migration 실제 적용 확인: ${notes%; }"
    elif [[ "${demo_mig_changed}" == "true" ]]; then
      POLICY_RESULT_LABEL="PASS"
      POLICY_REASON="migration 실제 적용 확인(PVC-less demo workload 기준): ${notes%; }"
    else
      POLICY_REASON="migration 완료 증거가 부족합니다(original_deleted=${original_deleted}, migrated_pods=${A_MIGRATED_PODS:-<none>}, demo_workload_running=${demo_mig_running:-<none>})."
    fi
    ;;
  provisioning)
    [[ "${B_PVC_NAMES:-}" != "${A_PVC_NAMES:-}" && -n "${A_PVC_NAMES:-}" ]] && add_note "pvc ${B_PVC_NAMES:-<none>} -> ${A_PVC_NAMES}"
    [[ "${A_PVC_PHASES:-}" == *":Bound"* ]] && add_note "pvc_bound=${A_PVC_PHASES}"
    [[ "${A_PVC_PROVISIONING_IDS:-}" == *":provisioning-"* ]] && add_note "provisioning_id_label=${A_PVC_PROVISIONING_IDS}"
    if [[ -n "${A_PVC_NAMES:-}" && "${A_PVC_PHASES:-}" == *":Bound"* && "${A_PVC_PROVISIONING_IDS:-}" == *":provisioning-"* ]]; then
      POLICY_RESULT_LABEL="PASS"
      POLICY_REASON="provisioning 실제 적용 확인: ${notes%; }"
    else
      POLICY_REASON="PVC 생성/Bound/provisioning-id label 중 일부가 확인되지 않았습니다."
    fi
    ;;
  preemption)
    [[ "${B_POD_UIDS:-}" != "${A_POD_UIDS:-}" ]] && add_note "pod_uid_changed=true"
    int_gt "${A_EVICTION_EVENT_COUNT:-0}" "${B_EVICTION_EVENT_COUNT:-0}" && add_note "eviction_events ${B_EVICTION_EVENT_COUNT:-0} -> ${A_EVICTION_EVENT_COUNT:-0}"
    if [[ "${B_POD_UIDS:-}" != "${A_POD_UIDS:-}" && "${A_EVICTION_EVENT_COUNT:-0}" != "0" ]]; then
      POLICY_RESULT_LABEL="PASS"
      POLICY_REASON="preemption 실제 적용 확인: ${notes%; }"
    else
      POLICY_REASON="preempted Pod UID 변화 또는 eviction event가 확인되지 않았습니다. 후보가 없으면 WARN이 정상일 수 있습니다."
    fi
    ;;
  loadbalance|loadbalancing)
    [[ "${B_NODE_POD_COUNTS:-}" != "${A_NODE_POD_COUNTS:-}" ]] && add_note "node_pod_counts changed"
    [[ "${A_OPERATOR_API_DETAILS:-}" == *"pods_to_migrate"* || "${A_OPERATOR_API_DETAILS:-}" == *"successful_migrations"* ]] && add_note "operator_details=${A_OPERATOR_API_DETAILS}"
    if [[ "${B_NODE_POD_COUNTS:-}" != "${A_NODE_POD_COUNTS:-}" ]]; then
      POLICY_RESULT_LABEL="PASS"
      POLICY_REASON="load balancing 실제 적용 확인: ${notes%; }"
    else
      POLICY_REASON="node별 Pod 분포 변화가 없습니다. 클러스터가 이미 균형 상태이면 WARN이 정상일 수 있습니다."
    fi
    ;;
  caching)
    int_gt "${A_PREFETCH_EVENT_COUNT:-0}" "${B_PREFETCH_EVENT_COUNT:-0}" && add_note "cache_prefetch_events ${B_PREFETCH_EVENT_COUNT:-0} -> ${A_PREFETCH_EVENT_COUNT:-0}"
    [[ "${A_OPERATOR_API_STATUS:-}" =~ ^(active|loading|pending)$ ]] && add_note "cache_api_status=${A_OPERATOR_API_STATUS}"
    [[ "${A_SOURCE_PVC_EXISTS:-false}" == "true" ]] && add_note "source_pvc_exists=true"
    if int_gt "${A_PREFETCH_EVENT_COUNT:-0}" "${B_PREFETCH_EVENT_COUNT:-0}" && [[ "${A_SOURCE_PVC_EXISTS:-false}" == "true" ]]; then
      POLICY_RESULT_LABEL="PASS"
      POLICY_REASON="caching 실제 적용 확인: ${notes%; }"
    else
      POLICY_REASON="cache-prefetch Pod event 또는 source PVC가 확인되지 않았습니다."
    fi
    ;;
  *)
    [[ "${B_REPLICAS:-}" != "${A_REPLICAS:-}" ]] && add_note "replicas ${B_REPLICAS:-0} -> ${A_REPLICAS:-0}"
    [[ "${B_READY:-}" != "${A_READY:-}" ]] && add_note "readyReplicas ${B_READY:-0} -> ${A_READY:-0}"
    [[ "${B_POD_COUNT:-}" != "${A_POD_COUNT:-}" ]] && add_note "pod_count ${B_POD_COUNT:-0} -> ${A_POD_COUNT:-0}"
    if [[ "${changed}" -eq 1 ]]; then
      POLICY_RESULT_LABEL="PASS"
      POLICY_REASON="일반 리소스 변화 확인: ${notes%; }"
    fi
    ;;
esac

CHANGE_OBSERVED_LABEL="$([[ "${POLICY_RESULT_LABEL}" == "PASS" ]] && echo true || echo false)"
echo
echo "비교 결과 (before -> after)"
echo "policy_type=${POLICY_TYPE:-<none>}"
echo "policy_id=${POLICY_ID:-<none>}"
echo "replicas=${B_REPLICAS:-0} -> ${A_REPLICAS:-0}"
echo "readyReplicas=${B_READY:-0} -> ${A_READY:-0}"
echo "pod_count=${B_POD_COUNT:-0} -> ${A_POD_COUNT:-0}"
echo "pod_uids=${B_POD_UIDS:-<none>} -> ${A_POD_UIDS:-<none>}"
echo "migrated_pods=${B_MIGRATED_PODS:-<none>} -> ${A_MIGRATED_PODS:-<none>}"
echo "pvc_names=${B_PVC_NAMES:-<none>} -> ${A_PVC_NAMES:-<none>}"
echo "node_pod_counts=${B_NODE_POD_COUNTS:-<none>} -> ${A_NODE_POD_COUNTS:-<none>}"
echo "operator_api_status=${B_OPERATOR_API_STATUS:-<none>} -> ${A_OPERATOR_API_STATUS:-<none>}"
echo "change_observed=${CHANGE_OBSERVED_LABEL}"
echo "change_notes=${notes:-<none>}"
echo "policy_validation_result=${POLICY_RESULT_LABEL}"
echo "policy_validation_reason=${POLICY_REASON}"

log_box_start "11/11" "Orchestration Compare"
log_kv "target" "${WORKLOAD_NAME}"
log_kv "kind" "${WORKLOAD_KIND}"
log_kv "namespace" "${NAMESPACE}"
log_kv "mode" "${MODE}"
log_kv "policy" "${POLICY_TYPE:-<none>}"
log_kv "operator_id" "${POLICY_ID:-<none>}"
log_kv_status "changed" "${CHANGE_OBSERVED_LABEL}"
log_evidence_title
log_evidence_line "before"
printf 'metric value\nreplicas %s\nready %s\npod_count %s\npod_uids %s\nmigrated_pods %s\npvc %s\nnode_counts %s\noperator %s\n' \
  "${B_REPLICAS:-0}" "${B_READY:-0}" "${B_POD_COUNT:-0}" "${B_POD_UIDS:-<none>}" "${B_MIGRATED_PODS:-<none>}" "${B_PVC_NAMES:-<none>}" "${B_NODE_POD_COUNTS:-<none>}" "${B_OPERATOR_API_STATUS:-<none>}" | print_ascii_table
log_evidence_line "after"
printf 'metric value\nreplicas %s\nready %s\npod_count %s\npod_uids %s\nmigrated_pods %s\npvc %s\nnode_counts %s\noperator %s\n' \
  "${A_REPLICAS:-0}" "${A_READY:-0}" "${A_POD_COUNT:-0}" "${A_POD_UIDS:-<none>}" "${A_MIGRATED_PODS:-<none>}" "${A_PVC_NAMES:-<none>}" "${A_NODE_POD_COUNTS:-<none>}" "${A_OPERATOR_API_STATUS:-<none>}" | print_ascii_table
log_cmd "kubectl get pod -n ${NAMESPACE} -l ${POD_SELECTOR} -o wide"
if [[ -n "${POD_SELECTOR}" && "${POD_SELECTOR}" != metadata.name=* ]]; then
  kubectl get pod -n "${NAMESPACE}" -l "${POD_SELECTOR}" -o wide 2>/dev/null | sed -n '1,8p' | __demo_prefix_lines || log_evidence_line "WARN: pod 조회 실패"
else
  get_pods_for_workload "${NAMESPACE}" "${WORKLOAD_KIND:-Deployment}" "${WORKLOAD_NAME}" "${API_VERSION:-apps/v1}" 2>/dev/null \
    | sed -n '1,8p' | __demo_prefix_lines || log_evidence_line "WARN: pod 조회 실패"
fi
case "${POLICY_TYPE}" in
  provisioning)
    log_cmd "kubectl get pvc -n ${NAMESPACE} -l app=ai-storage-orchestrator,component=provisioning,workload-name=${WORKLOAD_NAME}"
    kubectl get pvc -n "${NAMESPACE}" -l "app=ai-storage-orchestrator,component=provisioning,workload-name=${WORKLOAD_NAME}" 2>/dev/null | sed -n '1,8p' | __demo_prefix_lines || log_evidence_line "WARN: pvc 조회 실패"
    ;;
  migration)
    log_cmd "kubectl get pod -n ${NAMESPACE} -l migration.ai-storage/job=true -o wide"
    kubectl get pod -n "${NAMESPACE}" -l migration.ai-storage/job=true -o wide 2>/dev/null | sed -n '1,8p' | __demo_prefix_lines || log_evidence_line "WARN: migrated pod 조회 실패"
    ;;
  preemption)
    log_cmd "kubectl get events -n ${NAMESPACE} | grep -Ei 'evict|preempt|killing'"
    kubectl get events -n "${NAMESPACE}" --sort-by=.lastTimestamp 2>/dev/null | grep -Ei 'evict|preempt|killing' | tail -8 | __demo_prefix_lines || log_evidence_line "WARN: eviction event 없음"
    ;;
  loadbalance|loadbalancing)
    log_cmd "kubectl get pod -A -o wide"
    kubectl get pod -A -o wide 2>/dev/null | sed -n '1,12p' | __demo_prefix_lines || log_evidence_line "WARN: cluster pod 조회 실패"
    log_evidence_line "operator_details: ${A_OPERATOR_API_DETAILS:-<none>}"
    ;;
  caching)
    log_cmd "kubectl get events -n ${NAMESPACE} | grep cache-prefetch"
    kubectl get events -n "${NAMESPACE}" --sort-by=.lastTimestamp 2>/dev/null | grep -E 'cache-prefetch' | tail -8 | __demo_prefix_lines || log_evidence_line "WARN: cache-prefetch event 없음"
    log_evidence_line "source_pvc_exists: ${A_SOURCE_PVC_EXISTS:-false}"
    log_evidence_line "operator_details  : ${A_OPERATOR_API_DETAILS:-<none>}"
    ;;
esac
log_evidence_line "validation : ${POLICY_REASON}"
log_box_result "${POLICY_RESULT_LABEL}" "${POLICY_REASON}"
