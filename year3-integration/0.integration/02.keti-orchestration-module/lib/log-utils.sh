#!/usr/bin/env bash
# log-utils.sh는 KETI 오케스트레이션 step 스크립트의 공통 출력과 Kubernetes 탐색 함수를 제공한다.
#
# 색상 규칙: 박스/key=하늘색, 명령어=흐린 회색, ✓=초록, ⚠=노랑, ✗=빨강
# NO_COLOR=1 환경변수가 설정되면 색상 출력이 비활성화된다.
# 각 step의 실제 실행 로직은 01~24 step 파일이 직접 가진다.
#
# Author: 미정 <unknown@example.com>
# Created: 2026-05-28

set -u

SCRIPT_PATH="${BASH_SOURCE[0]}"
COMMON_DIR="$(cd "$(dirname "${SCRIPT_PATH}")" && pwd)"
MODULE_DIR="$(cd "${COMMON_DIR}/.." && pwd)"
INTEGRATION_DIR="$(cd "${MODULE_DIR}/.." && pwd)"
REPO_DIR="$(cd "${INTEGRATION_DIR}/../.." && pwd)"
PACKAGE_DIR="${INTEGRATION_DIR}/01.package"

# Argo/Kubeflow/Kueue 등 외부 컴포넌트의 표준 설치 namespace 후보.
# 후보 배열은 검색 용도이지 실행값으로 박아넣는 용도가 아니다.
ARGO_NS_CANDIDATES=(${ARGO_NS_CANDIDATES:-argocd argo argo-system argo-events})
KUBEFLOW_NS_CANDIDATES=(${KUBEFLOW_NS_CANDIDATES:-kubeflow kubeflow-system kf})
KUEUE_NS_CANDIDATES=(${KUEUE_NS_CANDIDATES:-kueue-system kueue})
KETI_NS_CANDIDATES=(${KETI_NS_CANDIDATES:-keti apollo kube-system})

# 사용자 인자 우선, 없으면 비워두고 후속 탐색 로직이 채운다.
WORKLOAD_NAME="${1:-${WORKLOAD_NAME:-}}"
TARGET_NAMESPACE="${2:-${TARGET_NAMESPACE:-}}"

RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
LOG_DIR="${LOG_DIR:-${MODULE_DIR}/logs/run-${RUN_ID}}"
STATE_DIR="${STATE_DIR:-${LOG_DIR}/state}"
STEP_LOG_DIR="${STEP_LOG_DIR:-${LOG_DIR}/steps}"
mkdir -p "${LOG_DIR}" "${STATE_DIR}" "${STEP_LOG_DIR}"

# 색상 코드. NO_COLOR가 설정되면 무조건 비활성화하고,
# 그 외에는 stdout이 터미널이거나 FORCE_COLOR=1이면 색상을 적용한다.
if [ -n "${NO_COLOR:-}" ]; then
  SKY=""; DIM=""; GREEN=""; YELLOW=""; RED=""; RESET=""
elif [ -t 1 ] || [ -n "${FORCE_COLOR:-}" ]; then
  SKY=$'\033[36m'
  DIM=$'\033[2m'
  GREEN=$'\033[32m'
  YELLOW=$'\033[33m'
  RED=$'\033[31m'
  RESET=$'\033[0m'
else
  SKY=""; DIM=""; GREEN=""; YELLOW=""; RED=""; RESET=""
fi

# log 파일에 기록할 때는 ANSI 색상 코드를 제거하기 위한 sed 필터.
strip_ansi() {
  sed -E 's/\x1B\[[0-9;]*[mK]//g'
}

timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

# log_line은 색상이 적용된 한 줄을 stdout에 그대로 출력하고 색상 제거 사본을 run.log에 기록한다.
log_line() {
  local level="$1"
  local color="$2"
  shift 2
  local line
  line="[$(timestamp)] [${level}] $*"
  printf '%b%s%b\n' "${color}" "${line}" "${RESET}"
  printf '%s\n' "${line}" >> "${LOG_DIR}/run.log"
}

log_info()  { log_line "INFO " "${SKY}"    "$@"; }
log_ok()    { log_line "OK   " "${GREEN}"  "$@"; }
log_warn()  { log_line "WARN " "${YELLOW}" "$@"; }
log_error() { log_line "ERROR" "${RED}"    "$@"; }
log_skip()  { log_line "SKIP " "${DIM}"    "$@"; }

# tee_log는 색상 그대로 stdout에 표시하고, 색상 제거된 사본을 run.log에 누적한다.
tee_log() {
  local line="$1"
  printf '%b\n' "${line}"
  printf '%s\n' "${line}" | strip_ansi >> "${LOG_DIR}/run.log"
}

# 박스 테두리는 항상 하늘색.
print_header() {
  local title="$1"
  tee_log "${SKY}┌─ ${title} ────────────────────────────────${RESET}"
}

print_footer() {
  tee_log "${SKY}└──────────────────────────────────────────────────────────────${RESET}"
}

print_separator() {
  tee_log "${SKY}│${RESET}"
}

# status_color는 값 안에 ✓/⚠/✗이 있는지를 보고 적절한 색을 골라준다.
status_color() {
  local value="$1"
  case "${value}" in
    *✓*)        printf '%s' "${GREEN}"  ;;
    *⚠*|*SKIP*) printf '%s' "${YELLOW}" ;;
    *✗*)        printf '%s' "${RED}"    ;;
    *)          printf '%s' ""         ;;
  esac
}

# policy_highlight_color는 선택 정책명/정책 유형이 알려진 오케스트레이션 유형이면 초록색을 반환한다.
policy_highlight_color() {
  local key="$1"
  local value
  value="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"
  case "${key}:${value}" in
    selected_policy:*migration*|selected_policy:*provisioning*|selected_policy:*autoscaling*|selected_policy:*scaling*|selected_policy:*loadbalance*|selected_policy:*preemption*|selected_policy:*caching*|policy_type:*migration*|policy_type:*provisioning*|policy_type:*autoscaling*|policy_type:*scaling*|policy_type:*loadbalance*|policy_type:*preemption*|policy_type:*caching*)
      printf '%s' "${GREEN}" ;;
    *)
      printf '%s' "" ;;
  esac
}

# print_kv는 key는 하늘색, value는 상태(✓/⚠/✗)에 따라 색을 자동 적용한다.
print_kv() {
  local key="$1"
  local value="${2:-}"
  local color
  color="$(policy_highlight_color "${key}" "${value}")"
  [ -z "${color}" ] && color="$(status_color "${value}")"
  local line
  line="$(printf '%s│%s %s%-20s%s : %s%s%s' \
    "${SKY}" "${RESET}" \
    "${SKY}" "${key}" "${RESET}" \
    "${color}" "${value}" "${RESET}")"
  printf '%b\n' "${line}"
  printf '│ %-20s : %s\n' "${key}" "${value}" >> "${LOG_DIR}/run.log"
}

# print_kv_warn은 print_kv와 동일한 박스 포맷을 유지하되 value를 무조건 YELLOW(WARN)으로 강제한다.
# Forecast Pending Notice 박스처럼 전체 라인을 경고 색상으로 강조해야 할 때 사용한다.
# 일반 값(예: 'previous execution trace is not enough')도 ⚠ 키워드 없이 YELLOW로 표시되도록 한다.
print_kv_warn() {
  local key="$1"
  local value="${2:-}"
  printf '%b│%b %b%-20s%b : %b%s%b\n' \
    "${SKY}" "${RESET}" \
    "${SKY}" "${key}" "${RESET}" \
    "${YELLOW}" "${value}" "${RESET}"
  printf '│ %-20s : %s\n' "${key}" "${value}" >> "${LOG_DIR}/run.log"
}

# print_label_line은 키 라벨만 한 줄로 출력 (값이 없는 블록 헤더용).
print_label_line() {
  local key="$1"
  tee_log "${SKY}│${RESET} ${SKY}${key}${RESET}"
}

# print_dim_line은 흐린 회색으로 들여쓴 한 줄을 출력 (명령어 등).
print_dim_line() {
  local text="$1"
  printf '%b│%b   %b%s%b\n' "${SKY}" "${RESET}" "${DIM}" "${text}" "${RESET}"
  printf '│   %s\n' "${text}" >> "${LOG_DIR}/run.log"
}

# print_value_line은 일반 값을 들여쓰기로 출력 (kubectl 결과 표 등).
print_value_line() {
  local text="$1"
  printf '%b│%b   %s\n' "${SKY}" "${RESET}" "${text}"
  printf '│   %s\n' "${text}" >> "${LOG_DIR}/run.log"
}

# print_command_block은 "title" 라벨 + 명령어를 DIM으로 출력하고 그 실행 결과를 그대로 인쇄한다.
print_command_block() {
  local title="$1"
  local cmd="$2"
  local out
  out="$(bash -c "${cmd}" 2>/dev/null || true)"
  print_label_line "${title}"
  print_dim_line "${cmd}"
  if [ -n "${out}" ]; then
    while IFS= read -r line; do
      print_value_line "${line}"
    done <<< "${out}"
  else
    print_value_line "${YELLOW}⚠ not found${RESET}"
  fi
}

# print_commands_block은 라벨 1개 아래에 여러 명령어 라인을 DIM으로 출력한다 (실행 결과는 별도 블록으로).
print_commands_block() {
  local title="$1"
  shift
  print_label_line "${title}"
  local cmd
  for cmd in "$@"; do
    print_dim_line "${cmd}"
  done
}

# print_tail_logs는 deploy/pod 로그를 화면에는 마지막 N줄(latest_N 포맷)만 요약 표시하고
# 전체 로그는 LOG_DIR 하위 파일로 별도 저장한다.
# 인자: label, namespace, resource(예: deploy/insight-hub), n(=5), file_name(선택)
# 화면 출력 예:
#   logs
#     latest_1 : ...
#     latest_2 : ...
#     ...
#     full log file : logs/run-.../deploy-insight-hub.log
print_tail_logs() {
  local label="$1"
  local ns="$2"
  local resource="$3"
  local n="${4:-5}"
  local save_name="${5:-${resource//\//-}.log}"
  local save_path="${LOG_DIR}/${save_name}"
  mkdir -p "${LOG_DIR}"
  # 전체 로그는 별도 파일로 저장(--tail=2000 정도로 안전상 제한).
  kubectl logs -n "${ns}" "${resource}" --tail=2000 >"${save_path}" 2>&1 || true
  # 화면용 짧은 tail만 다시 가져온다.
  local short
  short="$(kubectl logs -n "${ns}" "${resource}" --tail="${n}" 2>/dev/null || true)"
  print_label_line "${label}"
  if [ -z "${short}" ]; then
    print_value_line "${YELLOW}⚠ not found${RESET}"
  else
    local i=1
    while IFS= read -r line; do
      print_value_line "  latest_${i} : ${line}"
      i=$((i+1))
    done <<< "${short}"
  fi
  local rel_save
  rel_save="${save_path#${MODULE_DIR}/}"
  print_value_line "${DIM}full log file : ${rel_save}${RESET}"
}

# print_scheduler_logs_block은 scheduler 로그를 화면에는 latest_N(최대 5줄)만 표시하고
# 전체 로그는 LOG_DIR 하위 파일로 저장한다. 세미콜론으로 한 줄에 뭉쳐 출력하지 않는다.
#
# Parameters:
# - label: 출력 라벨 (예: scheduler_logs)
# - ns: namespace
# - resource: deploy/pod 리소스 (예: deploy/ai-storage-scheduler)
# - n: 화면에 표시할 최대 줄 수 (기본 5)
# - save_name: 전체 로그 저장 파일명 (LOG_DIR 기준, 기본 scheduler.log)
# - filter: grep -iE 필터 (선택). 없으면 tail만 사용.
# - empty_reason: 로그가 없을 때 표시할 구체적 사유 (선택)
print_scheduler_logs_block() {
  local label="$1"
  local ns="$2"
  local resource="$3"
  local n="${4:-5}"
  local save_name="${5:-scheduler.log}"
  local filter="${6:-}"
  local empty_reason="${7:-scheduler decision log not found}"
  local save_path="${LOG_DIR}/${save_name}"
  mkdir -p "${LOG_DIR}"
  if [ -z "${ns}" ]; then
    print_label_line "${label}"
    print_value_line "  ${YELLOW}⚠ ${empty_reason}${RESET}"
    return
  fi
  kubectl logs -n "${ns}" "${resource}" --tail=2000 >"${save_path}" 2>&1 || true
  local lines
  if [ -n "${filter}" ]; then
    lines="$(grep -iE "${filter}" "${save_path}" 2>/dev/null | tail -n "${n}")"
  else
    lines="$(tail -n "${n}" "${save_path}" 2>/dev/null)"
  fi
  print_label_line "${label}"
  if [ -z "${lines}" ]; then
    print_value_line "  ${YELLOW}⚠ ${empty_reason}${RESET}"
  else
    local i=1
    while IFS= read -r line; do
      [ -z "${line}" ] && continue
      print_value_line "  latest_${i} : ${line}"
      i=$((i + 1))
    done <<< "${lines}"
  fi
  print_value_line "  full_log_file : ${save_path#${MODULE_DIR}/}"
}

# print_raw_block은 라벨 아래 임의 텍스트를 그대로 출력한다 (이미 캡처된 명령 결과 등).
print_raw_block() {
  local title="$1"
  local out="$2"
  print_label_line "${title}"
  if [ -z "${out}" ]; then
    print_value_line "${YELLOW}⚠ not found${RESET}"
    return
  fi
  while IFS= read -r line; do
    print_value_line "${line}"
  done <<< "${out}"
}

# print_limited_raw_block은 화면에는 최대 N줄만 출력하고 전체 원문은 LOG_DIR에 저장한다.
print_limited_raw_block() {
  local title="$1"
  local out="$2"
  local max_lines="${3:-5}"
  local save_name="${4:-${title}.txt}"
  local save_path="${LOG_DIR}/${save_name}"
  local total_lines truncated rel_save

  mkdir -p "${LOG_DIR}"
  printf '%s\n' "${out}" > "${save_path}"
  total_lines="$(printf '%s\n' "${out}" | sed '/^$/d' | wc -l | awk '{print $1}')"
  rel_save="${save_path#${MODULE_DIR}/}"

  print_label_line "${title}"
  if [ -z "${out}" ]; then
    print_value_line "${YELLOW}⚠ not found${RESET}"
    print_value_line "${DIM}full output: ${rel_save}${RESET}"
    return
  fi

  printf '%s\n' "${out}" | sed -n "1,${max_lines}p" | while IFS= read -r line; do
    print_value_line "${line}"
  done
  if [ "${total_lines}" -gt "${max_lines}" ]; then
    truncated=$((total_lines - max_lines))
    print_value_line "${DIM}... truncated ${truncated} lines, full output: ${rel_save}${RESET}"
  else
    print_value_line "${DIM}full output: ${rel_save}${RESET}"
  fi
}

print_scheduler_algorithm_summary() {
  local scheduler_log="$1"
  local target_pattern="${2:-}"
  python3 - "${scheduler_log}" "${target_pattern}" <<'PYEOF' | while IFS=$'\t' read -r kind text; do
import re
import sys
from collections import defaultdict

log_path = sys.argv[1]
target = sys.argv[2]


def emit(kind, text):
    print(f"{kind}\t{text}")


def fields(line):
    result = {}
    for key, value in re.findall(r'([A-Za-z_][A-Za-z0-9_]*)=("[^"]*"|\S+)', line):
        if value.startswith('"') and value.endswith('"'):
            value = value[1:-1]
        result[key] = value
    return result


def node_list(value):
    value = (value or "").strip().strip("[]")
    if not value:
        return []
    if "," in value:
        return [item.strip() for item in value.split(",") if item.strip()]
    return [item.strip() for item in value.split() if item.strip()]


def clean_score(value):
    return (value or "").strip().strip("[],")


try:
    with open(log_path, "r", encoding="utf-8", errors="replace") as fh:
        raw_lines = [line.rstrip("\n") for line in fh]
except OSError:
    raw_lines = []

lines = [line for line in raw_lines if not target or target in line]
if not lines and target:
    lines = raw_lines

passed = defaultdict(set)
filtered = defaultdict(set)
fallback_reopened = []
fallback_feasible = ""
total_nodes = 0
candidate_nodes = []
matrix = defaultdict(dict)
totals = {}
selected_node = ""
selected_score = ""
binder = ""
bind_result = ""

for line in lines:
    data = fields(line)
    node = data.get("node", "")
    plugin = data.get("plugin", "")

    if "[filter]" in line and "total_nodes=" in line:
        try:
            total_nodes = max(total_nodes, int(data.get("total_nodes", "0")))
        except ValueError:
            pass
    if "[filter-plugin]" in line and "Node passed filter" in line and plugin and node:
        passed[plugin].add(node)
    if "[filter-plugin]" in line and "Node filtered out" in line and plugin and node:
        filtered[plugin].add(node)
    if "[filter]" in line and "Node reopened" in line and node:
        fallback_reopened.append(node)
        fallback_feasible = data.get("feasible_nodes_after_fallback", fallback_feasible)
    if "[filter]" in line and "Node filtered out" in line and node:
        reason = data.get("reason", "")
        inferred = reason.split(":", 1)[0].strip() if ":" in reason else "filter"
        filtered[inferred].add(node)

    if "[score]" in line and "Scoring feasible nodes" in line:
        candidate_nodes = node_list(data.get("nodes", ""))
    if "[score-plugin]" in line and "Node scored" in line and plugin and node:
        score = clean_score(data.get("weighted_score", data.get("score", "")))
        matrix[node][plugin] = score
    if "[score]" in line and "Node scored" in line and node:
        totals[node] = clean_score(data.get("total_score", data.get("score", "")))
    if "[ScoreMap]" in line and "score_map=" in line:
        score_map = data.get("score_map", "")
        for item in score_map.split(","):
            if ":" not in item:
                continue
            map_node, map_score = item.strip().split(":", 1)
            if map_node.strip():
                totals[map_node.strip().strip("[]")] = clean_score(map_score)
    if "[score]" in line and "Best node selected" in line:
        selected_node = data.get("node", selected_node)
        selected_score = clean_score(data.get("score", data.get("total_score", selected_score)))
    if "[bind-plugin]" in line and "Starting bind" in line:
        binder = plugin or data.get("binder", binder)
    if "Successfully bound pod to node" in line or "Pod successfully bound" in line:
        bind_result = "confirmed"
        selected_node = data.get("node", selected_node)

if not selected_score and selected_node in totals:
    selected_score = totals[selected_node]
if not candidate_nodes:
    candidate_nodes = sorted(set(totals) | set(matrix))
if not totals:
    for node, scores in matrix.items():
        try:
            totals[node] = str(sum(int(value) for value in scores.values()))
        except ValueError:
            totals[node] = "UNKNOWN"

plugins = sorted({plugin for scores in matrix.values() for plugin in scores})
ranked = []
for node, score in totals.items():
    try:
        numeric = int(score)
    except (TypeError, ValueError):
        numeric = -10**18
    ranked.append((numeric, node, score))
ranked.sort(reverse=True)
if not selected_node and ranked:
    selected_node = ranked[0][1]
    selected_score = ranked[0][2]
runner_up = ""
runner_up_score = ""
for _, node, score in ranked:
    if node != selected_node:
        runner_up = node
        runner_up_score = score
        break

emit("SECTION", "Filter Phase")
filter_plugins = sorted(set(passed) | set(filtered))
if filter_plugins:
    for plugin in filter_plugins:
        nodes_seen = passed[plugin] | filtered[plugin]
        denominator = total_nodes or len(nodes_seen) or len(candidate_nodes) or len(passed[plugin])
        filtered_nodes = ", ".join(sorted(filtered[plugin])) if filtered[plugin] else "none"
        emit("LINE", f"{plugin:<18} : {len(passed[plugin])}/{denominator} nodes passed (filtered: {filtered_nodes})")
else:
    emit("LINE", "⚠ scheduler filter summary not found")
if fallback_reopened or fallback_feasible:
    reopened = ",".join(dict.fromkeys(fallback_reopened)) if fallback_reopened else "none"
    feasible = fallback_feasible or str(len(set(fallback_reopened)))
    emit("LINE", f"{'fallback':<18} : reopened={reopened} / feasible_nodes_after_fallback={feasible}")

emit("SECTION", "Score Phase")
emit("LINE", f"candidate_nodes   : {', '.join(candidate_nodes) if candidate_nodes else 'UNKNOWN'}")
emit("LINE", f"selected_node     : {selected_node or 'UNKNOWN'}")
emit("LINE", f"selected_score    : {selected_score or 'UNKNOWN'}")
emit("LINE", f"runner_up         : {runner_up or 'UNKNOWN'}")
emit("LINE", f"runner_up_score   : {runner_up_score or 'UNKNOWN'}")

emit("SECTION", "Score Matrix")
if matrix:
    node_width = max([len("node")] + [len(node) for node in matrix])
    plugin_widths = {plugin: max(len(plugin), 5) for plugin in plugins}
    total_width = max(len("TOTAL"), *(len(str(value)) + (2 if node == selected_node else 0) for node, value in totals.items()))
    header = f"{'node':<{node_width}} | " + " | ".join(
        f"{plugin:<{plugin_widths[plugin]}}" for plugin in plugins
    ) + f" | {'TOTAL':<{total_width}}"
    emit("LINE", header)
    for node in sorted(matrix):
        cells = [f"{node:<{node_width}}"]
        for plugin in plugins:
            cells.append(f"{matrix[node].get(plugin, '-'):<{plugin_widths[plugin]}}")
        total = totals.get(node, "UNKNOWN")
        if node == selected_node:
            total = f"{total} ★"
        cells.append(f"{total:<{total_width}}")
        emit("LINE", " | ".join(cells))
else:
    emit("LINE", "⚠ score-plugin weighted_score summary not found")

emit("SECTION", "Scheduling Decision")
emit("LINE", f"selected_node     : {selected_node or 'UNKNOWN'}")
emit("LINE", f"selected_score    : {selected_score or 'UNKNOWN'}")
emit("LINE", f"binder            : {binder or 'UNKNOWN'}")
emit("LINE", f"bind_result       : {bind_result or 'not observed'}")

emit("SECTION", "Decision Factor Analysis")
if selected_node and runner_up and selected_score and runner_up_score:
    try:
        total_delta = int(selected_score) - int(runner_up_score)
        emit("LINE", f"selected_vs_runner_up : {selected_node}({selected_score}) - {runner_up}({runner_up_score}) = {total_delta}")
    except ValueError:
        total_delta = None
        emit("LINE", f"selected_vs_runner_up : {selected_node}({selected_score}) vs {runner_up}({runner_up_score})")
    best_plugin = ""
    best_delta = 0
    for plugin in plugins:
        try:
            delta = int(matrix[selected_node].get(plugin, "0")) - int(matrix[runner_up].get(plugin, "0"))
        except ValueError:
            continue
        if abs(delta) > abs(best_delta):
            best_plugin = plugin
            best_delta = delta
    if best_plugin and best_delta != 0:
        emit("LINE", f"decisive_factor       : {best_plugin} delta={best_delta}")
    else:
        emit("LINE", "decisive_factor       : plugin tie")
else:
    emit("LINE", "⚠ runner-up comparison unavailable")
PYEOF
    case "${kind}" in
      SECTION) print_label_line "${text}" ;;
      LINE)    print_value_line "${text}" ;;
    esac
  done
}

print_ascii_table_block() {
  local title="$1"
  local out="$2"
  print_label_line "${title}"
  if [ -z "${out}" ]; then
    print_value_line "${YELLOW}⚠ not found${RESET}"
    return
  fi
  if command -v column >/dev/null 2>&1; then
    out="$(printf '%s\n' "${out}" | column -t 2>/dev/null || printf '%s\n' "${out}")"
  fi
  while IFS= read -r line; do
    print_value_line "${line}"
  done <<< "${out}"
}

capture_cmd() {
  local cmd="$1"
  bash -c "${cmd}" 2>/dev/null || true
}

measure_time() {
  local start="$1"
  local end
  end="$(date +%s)"
  printf '%ss' "$((end - start))"
}

format_duration() {
  local seconds="${1:-0}"
  printf '%02d:%02d:%02d' "$((seconds / 3600))" "$(((seconds % 3600) / 60))" "$((seconds % 60))"
}

save_state() {
  local key="$1"
  local value="${2:-}"
  printf '%s' "${value}" > "${STATE_DIR}/${key}"
}

read_state() {
  local key="$1"
  local default="${2:-unknown}"
  if [ -s "${STATE_DIR}/${key}" ]; then
    cat "${STATE_DIR}/${key}"
  else
    printf '%s' "${default}"
  fi
}

save_step_time() {
  local step="$1"
  local value="$2"
  printf '%s\n' "${value}" > "${STATE_DIR}/time-${step}"
}

init_step_context() {
  STEP_NO="$1"
  STEP_TITLE="$2"
  [ -n "${3:-}" ] && WORKLOAD_NAME="$3"
  [ -n "${4:-}" ] && TARGET_NAMESPACE="$4"
  STEP_START="$(date +%s)"
  print_header "[${STEP_NO}] ${STEP_TITLE}"
  local ws ns_resolved
  ws="$(resolve_workload)"
  STEP_WORKLOAD="${ws%%|*}"
  STEP_WORKLOAD_SOURCE="${ws##*|}"
  ns_resolved="$(resolve_target_namespace "${STEP_WORKLOAD}")"
  STEP_NAMESPACE="${ns_resolved%%|*}"
  STEP_NAMESPACE_SOURCE="${ns_resolved##*|}"
  save_state selected_workload "${STEP_WORKLOAD:-UNKNOWN}"
  save_state selected_namespace "${STEP_NAMESPACE:-UNKNOWN}"
}

finish_step() {
  local step_no="${1:-${STEP_NO:-00}}"
  local step_time
  step_time="$(measure_time "${STEP_START:-$(date +%s)}")"
  print_kv "time" "${step_time}"
  save_step_time "${step_no}" "${step_time}"
  print_footer
}

print_step_intent() {
  print_kv "action"   "$1"
  print_kv "purpose"  "$2"
  print_kv "artifact" "$3"
  print_kv "evidence" "$4"
  print_kv "result"   "$5"
  print_separator
}

print_after_context() {
  print_kv "state_scope" "After State / Kubernetes resource observation only"
  print_kv "compare_basis" "pod,node,replicas,pvc,storageClass,placement"
  print_separator
}

find_latest_previous_forecast_file() {
  local current_dir="${LOG_DIR}"
  find "${MODULE_DIR}/logs" -maxdepth 2 -type f -name 'forecaster-api-10.json' 2>/dev/null \
    | grep -v "^${current_dir}/" \
    | xargs -r ls -t 2>/dev/null \
    | head -1
}

print_existing_policy_history() {
  local workload="$1"
  local namespace="$2"
  local previous_forecast forecast_summary scheduling_resources scheduling_rows orchestration_rows apply_logs
  previous_forecast=""; forecast_summary=""; scheduling_resources=""; scheduling_rows=""; orchestration_rows=""; apply_logs=""

  print_separator
  print_label_line "Existing Policy History"

  previous_forecast="$(find_latest_previous_forecast_file)"
  if [ -n "${previous_forecast}" ] && command -v python3 >/dev/null 2>&1; then
    forecast_summary="$(python3 - "${previous_forecast}" <<'PYEOF' 2>/dev/null || true
import json, sys
path = sys.argv[1]
try:
    data = json.load(open(path, encoding="utf-8"))
except Exception:
    sys.exit(0)
confidence = data.get("confidence", data.get("selected_confidence", "UNKNOWN"))
node = data.get("node_name", data.get("node", "UNKNOWN"))
try:
    confidence = "%.4f" % float(confidence)
except Exception:
    pass
print("source=%s / node=%s / confidence=%s" % (path, node, confidence))
PYEOF
)"
  fi
  if [ -n "${forecast_summary}" ]; then
    print_kv "existing_forecast" "✓ observed / ${forecast_summary#${MODULE_DIR}/}"
  else
    print_kv "existing_forecast" "⚠ not observed"
  fi

  scheduling_resources="$(kubectl api-resources --no-headers 2>/dev/null | awk 'tolower($1) ~ /schedulingpolic/ {print $1; exit}')"
  if [ -n "${scheduling_resources}" ]; then
    scheduling_rows="$(kubectl get "${scheduling_resources}" -A --no-headers 2>/dev/null | grep -F "${workload}" | grep -F "${namespace}" | tail -5 || true)"
  fi
  if [ -n "${scheduling_rows}" ]; then
    print_kv "scheduling_policy_status" "✓ existing"
    print_raw_block "scheduling_policy_history" "${scheduling_rows}"
  elif [ -n "${scheduling_resources}" ]; then
    print_kv "scheduling_policy_status" "⚠ not found for target"
  else
    print_kv "scheduling_policy_status" "⚠ CRD not observed"
  fi

  orchestration_rows="$(kubectl get orchestrationpolicy -A \
    -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,TYPE:.spec.policyType,TARGET_WORKLOAD:.spec.targetWorkload,TARGET_NS:.spec.targetNamespace,PHASE:.status.phase,RESULT:.status.result,CREATED:.metadata.creationTimestamp \
    --no-headers 2>/dev/null | awk -v w="${workload}" -v ns="${namespace}" '$4 == w && ($5 == ns || $5 == "<none>" || $5 == "") {print}' | tail -5 || true)"
  if [ -n "${orchestration_rows}" ]; then
    print_kv "orchestration_policy_status" "✓ existing"
    print_raw_block "orchestration_policy_history" "${orchestration_rows}"
  elif kubectl get crd orchestrationpolicies.apollo.keti.re.kr >/dev/null 2>&1 \
       || kubectl api-resources --no-headers 2>/dev/null | awk '{print $1}' | grep -q '^orchestrationpolicies$'; then
    print_kv "orchestration_policy_status" "⚠ not found for target"
  else
    print_kv "orchestration_policy_status" "⚠ CRD not observed"
  fi

  apply_logs="$(timeout 8s kubectl logs -A --tail=500 2>/dev/null | grep -F "${workload}" | grep -iE 'orchestrator|executor|apply|autoscal|migration|provision|cache|preempt|loadbal' | tail -5 || true)"
  if [ -n "${apply_logs}" ]; then
    print_kv "orchestrator_apply_result" "✓ previous apply log observed"
    print_raw_block "apply_history" "${apply_logs}"
  else
    print_kv "orchestrator_apply_result" "⚠ not observed"
  fi
  save_state existing_forecast "$([ -n "${forecast_summary}" ] && echo "✓ observed" || echo "⚠ not observed")"
  print_separator
}

# detect_kubernetes_version은 kubectl version의 Server/Client gitVersion 중 가능한 것을 반환한다.
detect_kubernetes_version() {
  local version
  version="$(kubectl version -o json 2>/dev/null \
    | sed -n 's/.*"gitVersion": *"\([^"]*\)".*/\1/p' \
    | tail -1)"
  if [ -z "${version}" ]; then
    version="$(kubectl version --client 2>/dev/null \
      | awk '/Client Version/ {print $3; exit}')"
  fi
  printf '%s' "${version:-unknown}"
}

# find_namespace는 후보 namespace 배열 중 실제로 존재하는 첫 번째 namespace를 반환한다.
# 어떤 namespace도 존재하지 않으면 빈 문자열을 반환한다.
find_namespace() {
  local candidate
  for candidate in "$@"; do
    [ -z "${candidate}" ] && continue
    if kubectl get ns "${candidate}" >/dev/null 2>&1; then
      printf '%s' "${candidate}"
      return 0
    fi
  done
  return 0
}

# detect_argo_version은 argocd-server 이미지 태그 또는 argocd CLI에서 버전을 추출한다.
detect_argo_version() {
  local ns image cli
  ns="$(find_namespace "${ARGO_NS_CANDIDATES[@]}")"
  cli="$(argocd version --client --short 2>/dev/null | awk '{print $NF}' | head -1)"
  if [ -n "${ns}" ]; then
    image="$(kubectl get deploy -n "${ns}" -o jsonpath='{range .items[*]}{.spec.template.spec.containers[*].image}{"\n"}{end}' 2>/dev/null \
      | grep -iE 'argocd|argoproj|workflow-controller' \
      | sed -n 's/.*:\([^:@]*\)$/\1/p' \
      | head -1)"
  fi
  printf '%s' "${cli:-${image:-unknown}}"
}

# detect_kubeflow_version은 kubeflow 관련 deploy 이미지에서 버전 태그를 추출한다.
detect_kubeflow_version() {
  local ns image
  ns="$(find_namespace "${KUBEFLOW_NS_CANDIDATES[@]}")"
  if [ -n "${ns}" ]; then
    image="$(kubectl get deploy -n "${ns}" -o jsonpath='{range .items[*]}{.spec.template.spec.containers[*].image}{"\n"}{end}' 2>/dev/null \
      | sed -n 's/.*:\([^:@]*\)$/\1/p' \
      | head -1)"
  fi
  printf '%s' "${image:-unknown}"
}

# detect_kueue_version은 kueue 컨트롤러 deploy의 이미지 태그를 반환한다.
detect_kueue_version() {
  local ns image
  ns="$(find_namespace "${KUEUE_NS_CANDIDATES[@]}")"
  if [ -n "${ns}" ]; then
    image="$(kubectl get deploy -n "${ns}" -o jsonpath='{range .items[*]}{.spec.template.spec.containers[*].image}{"\n"}{end}' 2>/dev/null \
      | grep -iE 'kueue' \
      | sed -n 's/.*:\([^:@]*\)$/\1/p' \
      | head -1)"
    if [ -z "${image}" ]; then
      image="$(kubectl get deploy -n "${ns}" -o jsonpath='{range .items[*]}{.spec.template.spec.containers[*].image}{"\n"}{end}' 2>/dev/null \
        | sed -n 's/.*:\([^:@]*\)$/\1/p' \
        | head -1)"
    fi
  fi
  printf '%s' "${image:-unknown}"
}

# install_state는 namespace 존재 여부와 deploy 가용성을 보고 ✓ installed / ⚠ not found 등을 반환한다.
install_state() {
  local ns="$1"
  if [ -z "${ns}" ]; then
    printf '⚠ not found'
    return
  fi
  if ! kubectl get ns "${ns}" >/dev/null 2>&1; then
    printf '⚠ not found'
    return
  fi
  if ! kubectl get deploy -n "${ns}" >/dev/null 2>&1; then
    printf '⚠ unknown'
    return
  fi
  printf '✓ installed'
}

# install_state_for_keti는 KETI 자체 컴포넌트(deploy 이름 기반)에 대한 설치 상태를 판별한다.
install_state_for_keti() {
  local deploy="$1"
  local ns="$2"
  if [ -z "${ns}" ]; then
    printf '⚠ not found'
    return
  fi
  if ! kubectl get deploy "${deploy}" -n "${ns}" >/dev/null 2>&1; then
    printf '⚠ not found'
    return
  fi
  local desired ready
  desired="$(kubectl get deploy "${deploy}" -n "${ns}" -o jsonpath='{.status.replicas}' 2>/dev/null)"
  ready="$(kubectl get deploy "${deploy}" -n "${ns}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
  if [ -n "${ready}" ] && [ "${ready}" = "${desired:-0}" ]; then
    printf '✓ ready'
  else
    printf '⚠ installed'
  fi
}

# env_runtime_status는 Environment Runtime Status 통합 헤더를 출력한다 (00번 스크립트 전용).
env_runtime_status() {
  local start k8s_ver argo_ns kubeflow_ns kueue_ns
  start="$(date +%s)"
  k8s_ver="$(detect_kubernetes_version)"
  argo_ns="$(find_namespace "${ARGO_NS_CANDIDATES[@]}")"
  kubeflow_ns="$(find_namespace "${KUBEFLOW_NS_CANDIDATES[@]}")"
  kueue_ns="$(find_namespace "${KUEUE_NS_CANDIDATES[@]}")"

  local k8s_state argo_state kubeflow_state kueue_state
  if kubectl get nodes >/dev/null 2>&1; then
    k8s_state="✓ installed / version=${k8s_ver}"
  else
    k8s_state="✗ command failed / version=${k8s_ver}"
  fi
  argo_state="$(install_state "${argo_ns}") / version=$(detect_argo_version)"
  kubeflow_state="$(install_state "${kubeflow_ns}") / version=$(detect_kubeflow_version)"
  kueue_state="$(install_state "${kueue_ns}") / version=$(detect_kueue_version)"

  local k8s_version_out nodes_out
  k8s_version_out="$(kubectl version 2>/dev/null || true)"
  nodes_out="$(kubectl get nodes 2>/dev/null || true)"

  print_header "Environment Runtime Status"
  print_kv "kubernetes" "${k8s_state}"
  print_kv "argo"       "${argo_state}"
  print_kv "kubeflow"   "${kubeflow_state}"
  print_kv "kueue"      "${kueue_state}"
  print_separator
  print_commands_block "command" \
    "kubectl version" \
    "kubectl get nodes"
  print_separator
  print_raw_block "kubernetes_version" "${k8s_version_out}"
  print_separator
  print_raw_block "nodes" "${nodes_out}"
  print_kv "time" "$(measure_time "${start}")"
  print_footer
}

# component_status는 단일 외부 컴포넌트(kubernetes/argo/kubeflow/kueue)에 대한 상세 상태를 출력한다.
component_status() {
  local component="$1"
  local title="$2"
  local start ns ver
  start="$(date +%s)"
  print_header "${title}"
  case "${component}" in
    kubernetes)
      ver="$(detect_kubernetes_version)"
      if kubectl get nodes >/dev/null 2>&1; then
        print_kv "kubernetes" "✓ installed / version=${ver}"
      else
        print_kv "kubernetes" "✗ command failed / version=${ver}"
      fi
      print_separator
      print_commands_block "command" "kubectl version" "kubectl get nodes"
      print_separator
      print_raw_block "kubernetes_version" "$(capture_cmd 'kubectl version')"
      print_separator
      print_raw_block "nodes" "$(capture_cmd 'kubectl get nodes')"
      ;;
    argo)
      ns="$(find_namespace "${ARGO_NS_CANDIDATES[@]}")"
      ver="$(detect_argo_version)"
      print_kv "argo" "$(install_state "${ns}") / version=${ver}"
      print_kv "namespace_source" "$([ -n "${ns}" ] && echo 'auto-detected' || echo 'SKIP_NOT_FOUND')"
      print_kv "namespace_detected" "${ns:-SKIP_NOT_FOUND}"
      print_separator
      if [ -n "${ns}" ]; then
        print_commands_block "command" \
          "kubectl get ns ${ns}" \
          "kubectl get pods -n ${ns}" \
          "kubectl get deploy -n ${ns}" \
          "kubectl get applications -A"
        print_separator
        print_raw_block "pods"          "$(capture_cmd "kubectl get pods -n ${ns}")"
        print_raw_block "deploy"        "$(capture_cmd "kubectl get deploy -n ${ns}")"
        print_raw_block "applications"  "$(capture_cmd 'kubectl get applications -A')"
      else
        print_kv "status" "⚠ SKIP_EXTERNAL_DEPENDENCY"
        print_kv "reason" "argo namespace not found among candidates"
      fi
      ;;
    kubeflow)
      ns="$(find_namespace "${KUBEFLOW_NS_CANDIDATES[@]}")"
      ver="$(detect_kubeflow_version)"
      print_kv "kubeflow" "$(install_state "${ns}") / version=${ver}"
      print_kv "namespace_source" "$([ -n "${ns}" ] && echo 'auto-detected' || echo 'SKIP_NOT_FOUND')"
      print_kv "namespace_detected" "${ns:-SKIP_NOT_FOUND}"
      print_separator
      if [ -n "${ns}" ]; then
        print_commands_block "command" \
          "kubectl get ns ${ns}" \
          "kubectl get pods -n ${ns}" \
          "kubectl get workflow -A" \
          "kubectl get profiles -A"
        print_separator
        print_raw_block "pods"      "$(capture_cmd "kubectl get pods -n ${ns}")"
        print_raw_block "workflow"  "$(capture_cmd 'kubectl get workflow -A')"
        print_raw_block "profiles"  "$(capture_cmd 'kubectl get profiles -A')"
      else
        print_kv "status" "⚠ SKIP_EXTERNAL_DEPENDENCY"
        print_kv "reason" "kubeflow namespace not found among candidates"
      fi
      ;;
    kueue)
      ns="$(find_namespace "${KUEUE_NS_CANDIDATES[@]}")"
      ver="$(detect_kueue_version)"
      print_kv "kueue" "$(install_state "${ns}") / version=${ver}"
      print_kv "namespace_source" "$([ -n "${ns}" ] && echo 'auto-detected' || echo 'SKIP_NOT_FOUND')"
      print_kv "namespace_detected" "${ns:-SKIP_NOT_FOUND}"
      print_separator
      if [ -n "${ns}" ]; then
        print_commands_block "command" \
          "kubectl get ns ${ns}" \
          "kubectl get pods -n ${ns}" \
          "kubectl get deploy -n ${ns}" \
          "kubectl get workload -A" \
          "kubectl get localqueue -A" \
          "kubectl get clusterqueue"
        print_separator
        print_raw_block "pods"         "$(capture_cmd "kubectl get pods -n ${ns}")"
        print_raw_block "deploy"       "$(capture_cmd "kubectl get deploy -n ${ns}")"
        print_raw_block "workload"     "$(capture_cmd 'kubectl get workload -A')"
        print_raw_block "localqueue"   "$(capture_cmd 'kubectl get localqueue -A')"
        print_raw_block "clusterqueue" "$(capture_cmd 'kubectl get clusterqueue')"
      else
        print_kv "status" "⚠ SKIP_EXTERNAL_DEPENDENCY"
        print_kv "reason" "kueue namespace not found among candidates"
      fi
      ;;
  esac
  print_kv "time" "$(measure_time "${start}")"
  print_footer
}

# find_deploy_namespace는 클러스터 전체에서 특정 deploy 이름이 위치한 namespace를 찾는다.
find_deploy_namespace() {
  local deploy="$1"
  kubectl get deploy -A --no-headers 2>/dev/null \
    | awk -v n="${deploy}" '$2 == n {print $1; exit}'
}

# find_resource_namespace는 임의 리소스(deploy/sts/daemonset/job)에 해당 이름을 가진 namespace를 찾는다.
find_resource_namespace() {
  local name="$1"
  local ns
  ns="$(find_deploy_namespace "${name}")"
  if [ -n "${ns}" ]; then
    printf '%s' "${ns}"
    return
  fi
  ns="$(kubectl get sts -A --no-headers 2>/dev/null | awk -v n="${name}" '$2 == n {print $1; exit}')"
  if [ -n "${ns}" ]; then
    printf '%s' "${ns}"
    return
  fi
  ns="$(kubectl get daemonset -A --no-headers 2>/dev/null | awk -v n="${name}" '$2 == n {print $1; exit}')"
  if [ -n "${ns}" ]; then
    printf '%s' "${ns}"
    return
  fi
  ns="$(kubectl get pods -A --no-headers 2>/dev/null | awk -v n="${name}" '$2 ~ n {print $1; exit}')"
  printf '%s' "${ns}"
}

# keti_component_status는 KETI 자체 컴포넌트(scheduler, insight-hub 등)의 상태를 출력한다.
# 이름과 manifest 경로를 받아 동적으로 namespace를 탐색한다.
keti_component_status() {
  local title="$1"
  local deploy="$2"
  local manifest="${3:-}"
  local start ns ver
  start="$(date +%s)"
  print_header "${title}"

  ns="$(find_resource_namespace "${deploy}")"
  if [ -z "${ns}" ]; then
    local candidate
    for candidate in "${KETI_NS_CANDIDATES[@]}"; do
      if kubectl get deploy "${deploy}" -n "${candidate}" >/dev/null 2>&1; then
        ns="${candidate}"
        break
      fi
    done
  fi

  ver=""
  if [ -n "${ns}" ]; then
    ver="$(kubectl get deploy "${deploy}" -n "${ns}" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null \
      | sed -n 's/.*:\([^:@]*\)$/\1/p')"
  fi
  print_kv "component" "${deploy} : $(install_state_for_keti "${deploy}" "${ns}") / version=${ver:-unknown}"
  print_kv "namespace_source" "$([ -n "${ns}" ] && echo 'auto-detected' || echo 'SKIP_NOT_FOUND')"
  print_kv "namespace_detected" "${ns:-SKIP_NOT_FOUND}"
  print_separator

  if [ -n "${ns}" ] && kubectl get deploy "${deploy}" -n "${ns}" >/dev/null 2>&1; then
    print_commands_block "command" \
      "kubectl get deploy ${deploy} -n ${ns}" \
      "kubectl get pods -n ${ns} -l app=${deploy}" \
      "kubectl get svc -n ${ns}"
    print_separator
    print_raw_block "deploy" "$(capture_cmd "kubectl get deploy ${deploy} -n ${ns}")"
    print_raw_block "pods"   "$(capture_cmd "kubectl get pods -n ${ns} -l app=${deploy}")"
    print_raw_block "svc"    "$(capture_cmd "kubectl get svc -n ${ns}")"
  elif [ -n "${manifest}" ] && [ -f "${manifest}" ]; then
    print_kv "status" "⚠ not installed / manifest found"
    print_kv "manifest" "${manifest}"
    print_separator
    print_commands_block "command" "kubectl apply -f ${manifest}"
  else
    print_kv "status" "⚠ SKIP_EXTERNAL_DEPENDENCY"
    print_kv "reason" "deploy ${deploy} not found and no manifest provided"
  fi
  print_kv "time" "$(measure_time "${start}")"
  print_footer
}

# package_status는 기존 호환성을 위해 유지되는 진입점이다.
# title을 보고 어떤 컴포넌트인지 추론해 component_status 또는 keti_component_status로 위임한다.
# 인자: title, version(legacy, 무시됨), ns_hint, deploy, manifest
package_status() {
  local title="$1"
  local _legacy_version="${2:-}"
  local _legacy_ns="${3:-}"
  local deploy="${4:-}"
  local manifest="${5:-}"
  case "${title}" in
    "Environment Version"|"Environment Runtime Status")
      env_runtime_status
      ;;
    "Kubernetes Version"|"Kubernetes Status")
      component_status kubernetes "Kubernetes Status"
      ;;
    "Argo Version"|"Argo Status")
      component_status argo "Argo Status"
      ;;
    "Kubeflow Version"|"Kubeflow Status")
      component_status kubeflow "Kubeflow Status"
      ;;
    "Kueue Version"|"Kueue Status")
      component_status kueue "Kueue Status"
      ;;
    *)
      keti_component_status "${title}" "${deploy}" "${manifest}"
      ;;
  esac
}

# resolve_target_namespace는 사용자 인자 > current-context > workload 발견 위치 순으로 namespace를 결정한다.
# 반환 값은 "namespace|source" 형식. namespace를 못 찾으면 "|SKIP_NOT_FOUND".
resolve_target_namespace() {
  local workload="${1:-}"
  if [ -n "${TARGET_NAMESPACE:-}" ]; then
    if kubectl get ns "${TARGET_NAMESPACE}" >/dev/null 2>&1; then
      printf '%s|user-arg' "${TARGET_NAMESPACE}"
      return
    fi
  fi
  local ctx_ns
  ctx_ns="$(kubectl config view --minify -o jsonpath='{.contexts[0].context.namespace}' 2>/dev/null)"
  if [ -n "${ctx_ns}" ] && kubectl get ns "${ctx_ns}" >/dev/null 2>&1; then
    printf '%s|current-context' "${ctx_ns}"
    return
  fi
  if [ -n "${workload}" ]; then
    local ns
    ns="$(kubectl get deploy -A --no-headers 2>/dev/null | awk -v w="${workload}" '$2 == w || $2 ~ w {print $1; exit}')"
    if [ -z "${ns}" ]; then
      ns="$(kubectl get pods -A --no-headers 2>/dev/null | awk -v w="${workload}" '$2 ~ w {print $1; exit}')"
    fi
    if [ -n "${ns}" ]; then
      printf '%s|workload-discovery' "${ns}"
      return
    fi
  fi
  printf '|SKIP_NOT_FOUND'
}

# resolve_workload는 사용자 인자 > kubectl 검색 순으로 workload 이름을 결정한다.
# 반환 값은 "name|source". 못 찾으면 "|SKIP_NOT_FOUND".
resolve_workload() {
  if [ -n "${WORKLOAD_NAME:-}" ]; then
    printf '%s|user-arg' "${WORKLOAD_NAME}"
    return
  fi
  local name
  name="$(kubectl get workload -A --no-headers 2>/dev/null | awk 'NR==1 {print $2; exit}')"
  if [ -n "${name}" ]; then
    printf '%s|workload-cr' "${name}"
    return
  fi
  name="$(kubectl get deploy -A --no-headers 2>/dev/null | awk 'NR==1 {print $2; exit}')"
  if [ -n "${name}" ]; then
    printf '%s|deploy-fallback' "${name}"
    return
  fi
  printf '|SKIP_NOT_FOUND'
}

# find_workload_pod는 workload 이름과 namespace로 pod 이름을 찾는다 (full name 하드코딩 없음).
find_workload_pod() {
  local workload="$1"
  local ns="$2"
  [ -z "${workload}" ] && return 0
  [ -z "${ns}" ] && return 0
  local pod
  pod="$(kubectl get pod -n "${ns}" -l "app=${workload}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -z "${pod}" ]; then
    pod="$(kubectl get pod -n "${ns}" --no-headers 2>/dev/null | awk -v w="${workload}" '$1 ~ w {print $1; exit}')"
  fi
  printf '%s' "${pod}"
}

# selected_policy는 실제로 존재하는 orchestrationpolicy CR을 보고 migration/provisioning/autoscaling 중 하나를 반환한다.
# 어떤 CR도 없으면 none을 반환하며, 절대 임의의 정책 이름을 하드코딩으로 박지 않는다.
# 정책 유형은 (1) CR의 spec.policyType, (2) 출력 TYPE 컬럼, (3) NAME 컬럼 prefix 순으로 시도한다.
selected_policy() {
  if ! kubectl get crd orchestrationpolicies.apollo.keti.re.kr >/dev/null 2>&1 \
     && ! kubectl api-resources --no-headers 2>/dev/null | awk '{print $1}' | grep -q '^orchestrationpolicies$'; then
    printf 'none'
    return
  fi
  local line latest_ns latest_name policy
  line="$(kubectl get orchestrationpolicy -A --sort-by=.metadata.creationTimestamp 2>/dev/null | awk 'NR>1 {row=$0} END{print row}')"
  if [ -z "${line}" ]; then
    printf 'none'
    return
  fi
  latest_ns="$(printf '%s' "${line}" | awk '{print $1}')"
  latest_name="$(printf '%s' "${line}" | awk '{print $2}')"

  # 1순위: spec.policyType 직접 조회 (가장 정확).
  if [ -n "${latest_name}" ] && [ -n "${latest_ns}" ]; then
    policy="$(kubectl get orchestrationpolicy "${latest_name}" -n "${latest_ns}" \
      -o jsonpath='{.spec.policyType}' 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  fi

  # 2순위: 출력의 TYPE 컬럼(3번째)에서 유형 키워드 추출.
  if [ -z "${policy:-}" ]; then
    policy="$(printf '%s\n' "${line}" \
      | awk '{print tolower($3)}' \
      | grep -oE 'migration|provisioning|autoscaling|scaling|loadbalance|preemption|caching' \
      | head -1)"
  fi

  # 3순위: NAME 컬럼의 prefix(예: scaling-..., migration-...)에서 유형 키워드 추출.
  if [ -z "${policy:-}" ]; then
    policy="$(printf '%s\n' "${latest_name}" \
      | awk '{print tolower($0)}' \
      | grep -oE 'migration|provisioning|autoscaling|scaling|loadbalance|preemption|caching' \
      | head -1)"
  fi

  # scaling은 의미상 autoscaling으로 정규화한다.
  case "${policy:-}" in
    scaling) policy="autoscaling" ;;
  esac
  printf '%s' "${policy:-none}"
}

selected_policy_type_from_name() {
  local value
  value="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  printf '%s\n' "${value}" | grep -oE 'migration|provisioning|autoscaling|scaling|loadbalance|preemption|caching' | head -1
}

# policy_result는 selected policy CR의 status를 보고 ✓/⚠ 표시를 반환한다.
policy_result() {
  local policy="$1"
  if [ "${policy}" = "none" ]; then
    printf '⚠ not-triggered'
    return
  fi
  local result
  result="$(kubectl get orchestrationpolicy -A -o jsonpath='{range .items[*]}{.status.result}{" "}{.status.phase}{"\n"}{end}' 2>/dev/null | tail -1)"
  if printf '%s' "${result}" | grep -qiE 'success|applied|completed|running'; then
    printf '✓ applied'
  else
    printf '⚠ observed'
  fi
}

# _state_kv는 key=value 형식 상태 파일에서 특정 key의 값을 추출한다.
# 인자: <file> <key>. 값이 없거나 파일이 없으면 빈 문자열을 반환한다.
_state_kv() {
  local file="$1"
  local key="$2"
  [ -f "${file}" ] || { printf ''; return; }
  awk -F= -v k="${key}" '$1==k { sub(/^[^=]*=/, ""); print; exit }' "${file}" 2>/dev/null
}

# capture_orchestration_state는 현재 시점에서 정책 선택/적용에 영향 받는
# 리소스(orchestrationpolicy CR, HPA, Deployment, PVC, Pod)의 상태를 모두
# key=value 형식으로 단일 파일에 캡처한다. 해당 파일은 before/after 비교에 사용된다.
# 인자: <phase: before|after> <output_file_path> [override_policy_name].
# override_policy_name이 주어지면 가장 최근 CR이 아니라 해당 CR을 비교 기준으로 고정한다.
capture_orchestration_state() {
  local phase="$1"
  local out="$2"
  local override_name="${3:-}"
  mkdir -p "$(dirname "${out}")"

  local cr_line="" cr_ns="" cr_name="" cr_type="" cr_status="" cr_phase=""
  local target_ref_kind="" target_ref_name="" target_ref_ns=""
  if [ -n "${override_name}" ] && [ "${override_name}" != "none" ] && [ "${override_name}" != "UNKNOWN" ]; then
    cr_line="$(kubectl get orchestrationpolicy -A --no-headers 2>/dev/null | awk -v n="${override_name}" '$2==n {print; exit}')"
  else
    cr_line="$(kubectl get orchestrationpolicy -A --sort-by=.metadata.creationTimestamp --no-headers 2>/dev/null | tail -1)"
  fi
  cr_ns="$(printf '%s' "${cr_line}" | awk '{print $1}')"
  cr_name="$(printf '%s' "${cr_line}" | awk '{print $2}')"
  if [ -n "${cr_name}" ] && [ -n "${cr_ns}" ]; then
    cr_type="$(kubectl get orchestrationpolicy "${cr_name}" -n "${cr_ns}" -o jsonpath='{.spec.policyType}' 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
    case "${cr_type}" in scaling) cr_type="autoscaling" ;; esac
  fi
  [ -z "${cr_type}" ] && cr_type="$(selected_policy)"
  local cr_status_brief="" cr_status_msg=""
  if [ -n "${cr_name}" ] && [ -n "${cr_ns}" ]; then
    cr_status="$(kubectl get orchestrationpolicy "${cr_name}" -n "${cr_ns}" -o jsonpath='{.status.result}' 2>/dev/null || true)"
    cr_phase="$(kubectl get orchestrationpolicy "${cr_name}" -n "${cr_ns}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    target_ref_kind="$(kubectl get orchestrationpolicy "${cr_name}" -n "${cr_ns}" -o jsonpath='{.spec.targetRef.kind}' 2>/dev/null || true)"
    target_ref_name="$(kubectl get orchestrationpolicy "${cr_name}" -n "${cr_ns}" -o jsonpath='{.spec.targetRef.name}' 2>/dev/null || true)"
    target_ref_ns="$(kubectl get orchestrationpolicy "${cr_name}" -n "${cr_ns}" -o jsonpath='{.spec.targetRef.namespace}' 2>/dev/null || true)"
    if [ -z "${target_ref_name}" ]; then
      target_ref_name="$(kubectl get orchestrationpolicy "${cr_name}" -n "${cr_ns}" -o jsonpath='{.spec.targetWorkload}' 2>/dev/null || true)"
      target_ref_ns="$(kubectl get orchestrationpolicy "${cr_name}" -n "${cr_ns}" -o jsonpath='{.spec.targetNamespace}' 2>/dev/null || true)"
      [ -n "${target_ref_name}" ] && target_ref_kind="Deployment"
    fi
    # status.result가 "type=...;id=...;status=...;msg=..." 형태인 경우 status/phase/result 값만 뽑아 brief로 사용.
    if [ -n "${cr_status}" ]; then
      cr_status_brief="$(printf '%s' "${cr_status}" | tr ';' '\n' | awk -F= '/^(status|phase|result)=/ {sub(/^[^=]*=/,""); print; exit}')"
      cr_status_msg="$(printf '%s' "${cr_status}" | tr ';' '\n'   | awk -F= '/^(msg|message|reason)=/ {sub(/^[^=]*=/,""); print; exit}')"
    fi
    # brief가 비었으면 result 원본 그대로 사용한다(짧으면 그대로 보여줘도 무방).
    [ -z "${cr_status_brief}" ] && cr_status_brief="${cr_status}"
  fi

  local ws="" workload="" ns_resolved="" ns="" pod="" pod_phase="" node=""
  local pod_selector="" pod_count="" pod_uids="" pod_nodes="" node_counts=""
  ws="$(resolve_workload)"
  workload="${ws%%|*}"
  ns_resolved="$(resolve_target_namespace "${workload}")"
  ns="${ns_resolved%%|*}"
  pod="$(find_workload_pod "${workload}" "${ns}")"
  if [ -n "${workload}" ] && [ -n "${ns}" ]; then
    pod_selector="app=${workload}"
    pod_count="$(kubectl get pod -n "${ns}" -l "${pod_selector}" --no-headers 2>/dev/null | wc -l | tr -d ' ' || true)"
    if [ "${pod_count:-0}" = "0" ]; then
      local pod_list p uid pod_node
      pod_list="$(kubectl get pod -n "${ns}" --no-headers 2>/dev/null | awk -v w="${workload}" '$1 ~ w {print $1}')"
      pod_count="$(printf '%s\n' "${pod_list}" | sed '/^$/d' | wc -l | tr -d ' ')"
      while IFS= read -r p; do
        [ -z "${p}" ] && continue
        uid="$(kubectl get pod "${p}" -n "${ns}" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
        pod_node="$(kubectl get pod "${p}" -n "${ns}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
        pod_uids="${pod_uids:+${pod_uids},}${p}:${uid:-<none>}"
        pod_nodes="${pod_nodes:+${pod_nodes},}${p}:${pod_node:-<none>}"
      done <<< "${pod_list}"
    else
      pod_uids="$(kubectl get pod -n "${ns}" -l "${pod_selector}" -o jsonpath='{range .items[*]}{.metadata.name}{":"}{.metadata.uid}{","}{end}' 2>/dev/null | sed 's/,$//' || true)"
      pod_nodes="$(kubectl get pod -n "${ns}" -l "${pod_selector}" -o jsonpath='{range .items[*]}{.metadata.name}{":"}{.spec.nodeName}{","}{end}' 2>/dev/null | sed 's/,$//' || true)"
    fi
  fi
  if [ -n "${pod_nodes}" ]; then
    node_counts="$(printf '%s' "${pod_nodes}" \
      | tr ',' '\n' \
      | awk -F: '{node=$2; if (node=="") node="<none>"; counts[node]++} END{first=1; for (n in counts) {if (!first) printf ","; printf "%s:%s", n, counts[n]; first=0}}')"
  else
    node_counts="$(kubectl get pod -A -o wide --no-headers 2>/dev/null \
      | awk '{node=$8; if (node=="") node="<none>"; counts[node]++} END{first=1; for (n in counts) {if (!first) printf ","; printf "%s:%s", n, counts[n]; first=0}}' || true)"
  fi
  if [ -n "${pod}" ] && [ -n "${ns}" ]; then
    node="$(kubectl get pod "${pod}" -n "${ns}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
    pod_phase="$(kubectl get pod "${pod}" -n "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  fi

  # HPA는 정책 targetRef 또는 workload 이름과 매칭되는 첫 번째를 사용한다.
  local hpa_line="" hpa_ns="" hpa_name="" hpa_min="" hpa_max="" hpa_current="" hpa_desired=""
  hpa_line="$(kubectl get hpa -A --no-headers 2>/dev/null \
    | awk -v t1="${target_ref_name:-_none_}" -v t2="${workload:-_none_}" \
        '($2==t1 || $2==t2 || $3==t1 || $3==t2) {print; exit}')"
  hpa_ns="$(printf '%s' "${hpa_line}" | awk '{print $1}')"
  hpa_name="$(printf '%s' "${hpa_line}" | awk '{print $2}')"
  if [ -n "${hpa_name}" ] && [ -n "${hpa_ns}" ]; then
    hpa_min="$(kubectl get hpa "${hpa_name}" -n "${hpa_ns}" -o jsonpath='{.spec.minReplicas}' 2>/dev/null || true)"
    hpa_max="$(kubectl get hpa "${hpa_name}" -n "${hpa_ns}" -o jsonpath='{.spec.maxReplicas}' 2>/dev/null || true)"
    hpa_current="$(kubectl get hpa "${hpa_name}" -n "${hpa_ns}" -o jsonpath='{.status.currentReplicas}' 2>/dev/null || true)"
    hpa_desired="$(kubectl get hpa "${hpa_name}" -n "${hpa_ns}" -o jsonpath='{.status.desiredReplicas}' 2>/dev/null || true)"
  fi

  # Deployment는 정책 targetRef(kind=Deployment) 또는 workload 이름과 매칭되는 첫 번째를 사용한다.
  local deploy_name="" deploy_ns="" deploy_replicas="" deploy_ready="" deploy_available=""
  if [ -n "${target_ref_name}" ] && [ "${target_ref_kind:-}" = "Deployment" ]; then
    deploy_name="${target_ref_name}"
    deploy_ns="${target_ref_ns:-${ns}}"
  else
    local deploy_line=""
    deploy_line="$(kubectl get deploy -A --no-headers 2>/dev/null \
      | awk -v t1="${target_ref_name:-_none_}" -v t2="${workload:-_none_}" \
          '($2==t1 || $2==t2) {print; exit}')"
    deploy_ns="$(printf '%s' "${deploy_line}" | awk '{print $1}')"
    deploy_name="$(printf '%s' "${deploy_line}" | awk '{print $2}')"
  fi
  if [ -n "${deploy_name}" ] && [ -n "${deploy_ns}" ]; then
    deploy_replicas="$(kubectl get deploy "${deploy_name}" -n "${deploy_ns}" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
    deploy_ready="$(kubectl get deploy "${deploy_name}" -n "${deploy_ns}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
    deploy_available="$(kubectl get deploy "${deploy_name}" -n "${deploy_ns}" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)"
  fi

  # PVC는 workload namespace의 첫 번째 PVC를 사용한다 (없으면 UNKNOWN).
  local pvc_line="" pvc_name="" pvc_ns="" pvc_status="" pvc_capacity=""
  if [ -n "${ns}" ]; then
    pvc_line="$(kubectl get pvc -n "${ns}" --no-headers 2>/dev/null | head -1)"
    pvc_name="$(printf '%s' "${pvc_line}" | awk '{print $1}')"
    pvc_status="$(printf '%s' "${pvc_line}" | awk '{print $2}')"
    pvc_capacity="$(printf '%s' "${pvc_line}" | awk '{print $4}')"
    pvc_ns="${ns}"
  fi

  {
    printf 'phase=%s\n'                "${phase}"
    printf 'captured_at=%s\n'          "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'policy_name=%s\n'          "${cr_name:-UNKNOWN}"
    printf 'policy_namespace=%s\n'     "${cr_ns:-UNKNOWN}"
    printf 'policy_type=%s\n'          "${cr_type:-none}"
    printf 'policy_status_result=%s\n' "${cr_status:-UNKNOWN}"
    printf 'policy_status_phase=%s\n'  "${cr_phase:-UNKNOWN}"
    printf 'policy_status_brief=%s\n'  "${cr_status_brief:-UNKNOWN}"
    printf 'policy_status_msg=%s\n'    "${cr_status_msg:-UNKNOWN}"
    printf 'target_ref_kind=%s\n'      "${target_ref_kind:-UNKNOWN}"
    printf 'target_ref_name=%s\n'      "${target_ref_name:-UNKNOWN}"
    printf 'target_ref_namespace=%s\n' "${target_ref_ns:-UNKNOWN}"
    printf 'workload=%s\n'             "${workload:-UNKNOWN}"
    printf 'workload_namespace=%s\n'   "${ns:-UNKNOWN}"
    printf 'pod=%s\n'                  "${pod:-UNKNOWN}"
    printf 'pod_count=%s\n'            "${pod_count:-0}"
    printf 'pod_uids=%s\n'             "${pod_uids:-UNKNOWN}"
    printf 'pod_nodes=%s\n'            "${pod_nodes:-UNKNOWN}"
    printf 'node_counts=%s\n'          "${node_counts:-UNKNOWN}"
    printf 'pod_phase=%s\n'            "${pod_phase:-UNKNOWN}"
    printf 'pod_node=%s\n'             "${node:-UNKNOWN}"
    printf 'hpa_name=%s\n'             "${hpa_name:-UNKNOWN}"
    printf 'hpa_namespace=%s\n'        "${hpa_ns:-UNKNOWN}"
    printf 'hpa_min=%s\n'              "${hpa_min:-UNKNOWN}"
    printf 'hpa_max=%s\n'              "${hpa_max:-UNKNOWN}"
    printf 'hpa_current=%s\n'          "${hpa_current:-UNKNOWN}"
    printf 'hpa_desired=%s\n'          "${hpa_desired:-UNKNOWN}"
    printf 'deploy_name=%s\n'          "${deploy_name:-UNKNOWN}"
    printf 'deploy_namespace=%s\n'     "${deploy_ns:-UNKNOWN}"
    printf 'deploy_replicas=%s\n'      "${deploy_replicas:-UNKNOWN}"
    printf 'deploy_ready=%s\n'         "${deploy_ready:-UNKNOWN}"
    printf 'deploy_available=%s\n'     "${deploy_available:-UNKNOWN}"
    printf 'pvc_name=%s\n'             "${pvc_name:-UNKNOWN}"
    printf 'pvc_namespace=%s\n'        "${pvc_ns:-UNKNOWN}"
    printf 'pvc_status=%s\n'           "${pvc_status:-UNKNOWN}"
    printf 'pvc_capacity=%s\n'         "${pvc_capacity:-UNKNOWN}"
  } > "${out}"
}

# compute_orchestration_change는 before/after 상태 파일을 비교해 정책 type별로
# 가장 적절한 비교 source를 선택하고 결과를 전역 변수에 채운다.
# 채워지는 전역 변수:
#   OC_TARGET_RESOURCE OC_COMPARE_SOURCE OC_BEFORE_STATE OC_AFTER_STATE
#   OC_CHANGED OC_CHANGE_REASON OC_POLICY_RESULT
# 인자: <policy_name> <policy_ns> <policy_type> <before_file> <after_file>.
compute_orchestration_change() {
  local policy_name="$1"
  local policy_ns="$2"
  local policy_type="$3"
  local before_file="$4"
  local after_file="$5"

  OC_TARGET_RESOURCE=""; OC_COMPARE_SOURCE=""; OC_BEFORE_STATE=""; OC_AFTER_STATE=""
  OC_CHANGED="false"; OC_CHANGE_REASON=""; OC_POLICY_RESULT=""

  if [ -z "${policy_name}" ] || [ "${policy_name}" = "none" ] || [ "${policy_name}" = "UNKNOWN" ]; then
    OC_TARGET_RESOURCE="UNKNOWN"
    OC_COMPARE_SOURCE="UNKNOWN"
    OC_BEFORE_STATE="UNKNOWN"
    OC_AFTER_STATE="UNKNOWN"
    OC_CHANGED="false"
    OC_CHANGE_REASON="no orchestration policy selected"
    OC_POLICY_RESULT="⚠ not-triggered"
    return
  fi

  OC_TARGET_RESOURCE="orchestrationpolicy/${policy_name}"

  local b_pod_node a_pod_node
  local b_hpa_current a_hpa_current
  local b_deploy_replicas a_deploy_replicas
  local b_pvc_status a_pvc_status
  local b_pod_uids a_pod_uids b_node_counts a_node_counts
  local b_status a_status b_phase a_phase b_brief a_brief b_msg a_msg
  b_pod_node="$(_state_kv "${before_file}" pod_node)"
  a_pod_node="$(_state_kv "${after_file}"  pod_node)"
  b_hpa_current="$(_state_kv "${before_file}" hpa_current)"
  a_hpa_current="$(_state_kv "${after_file}"  hpa_current)"
  b_deploy_replicas="$(_state_kv "${before_file}" deploy_replicas)"
  a_deploy_replicas="$(_state_kv "${after_file}"  deploy_replicas)"
  b_pvc_status="$(_state_kv "${before_file}" pvc_status)"
  a_pvc_status="$(_state_kv "${after_file}"  pvc_status)"
  b_pod_uids="$(_state_kv "${before_file}" pod_uids)"
  a_pod_uids="$(_state_kv "${after_file}"  pod_uids)"
  b_node_counts="$(_state_kv "${before_file}" node_counts)"
  a_node_counts="$(_state_kv "${after_file}"  node_counts)"
  b_status="$(_state_kv "${before_file}" policy_status_result)"
  a_status="$(_state_kv "${after_file}"  policy_status_result)"
  b_phase="$(_state_kv "${before_file}"  policy_status_phase)"
  a_phase="$(_state_kv "${after_file}"   policy_status_phase)"
  b_brief="$(_state_kv "${before_file}"  policy_status_brief)"
  a_brief="$(_state_kv "${after_file}"   policy_status_brief)"
  b_msg="$(_state_kv "${before_file}"    policy_status_msg)"
  a_msg="$(_state_kv "${after_file}"     policy_status_msg)"

  # targetRef / pod_count도 함께 읽어 operator 결과 검증의 근거로 사용한다.
  local a_target_ref_name a_pod_count b_pod_count a_deploy_ready b_deploy_ready target_ref_empty
  a_target_ref_name="$(_state_kv "${after_file}"  target_ref_name)"
  a_pod_count="$(_state_kv "${after_file}"  pod_count)"
  b_pod_count="$(_state_kv "${before_file}" pod_count)"
  a_deploy_ready="$(_state_kv "${after_file}"  deploy_ready)"
  b_deploy_ready="$(_state_kv "${before_file}" deploy_ready)"
  target_ref_empty="false"
  case "${a_target_ref_name}" in ""|UNKNOWN) target_ref_empty="true" ;; esac

  # CR status에서 가장 간결한 표현을 고른다: brief > phase > raw result.
  _pick_state() {
    if _is_known "${1:-}"; then printf '%s' "$1"
    elif _is_known "${2:-}"; then printf '%s' "$2"
    elif _is_known "${3:-}"; then printf '%s' "$3"
    else printf 'unknown'
    fi
  }

  # _is_known은 값이 있는지(UNKNOWN/빈값이 아닌지) 판별한다.
  _is_known() { [ -n "${1:-}" ] && [ "${1}" != "UNKNOWN" ]; }

  # _target_missing_reason은 비교 대상 리소스를 못 찾았을 때 targetRef 비어있음 여부를
  # 우선 반영한 구체적 사유를 반환한다.
  _target_missing_reason() {
    if [ "${target_ref_empty}" = "true" ]; then
      printf 'orchestration policy targetRef is empty'
    else
      printf '%s' "$1"
    fi
  }

  case "${policy_type}" in
    autoscaling|scaling)
      # HPA → Deployment replicas → CR status 순으로 실제 변화를 검증한다.
      if _is_known "${a_hpa_current}"; then
        OC_COMPARE_SOURCE="hpa/status.currentReplicas"
        OC_BEFORE_STATE="replicas=${b_hpa_current:-UNKNOWN}"
        OC_AFTER_STATE="replicas=${a_hpa_current}"
        if [ "${b_hpa_current}" != "${a_hpa_current}" ]; then
          OC_CHANGED="true"
        else
          OC_CHANGE_REASON="autoscaler exists but replicas/ready/pod_count unchanged"
        fi
      elif _is_known "${a_deploy_replicas}"; then
        OC_COMPARE_SOURCE="deployment/spec.replicas"
        OC_BEFORE_STATE="replicas=${b_deploy_replicas:-UNKNOWN}"
        OC_AFTER_STATE="replicas=${a_deploy_replicas}"
        if [ "${b_deploy_replicas}" != "${a_deploy_replicas}" ] \
           || { _is_known "${a_deploy_ready}" && [ "${b_deploy_ready}" != "${a_deploy_ready}" ]; }; then
          OC_CHANGED="true"
        else
          OC_CHANGE_REASON="deployment replicas unchanged"
        fi
      elif _is_known "${a_brief}" || _is_known "${a_phase}" || _is_known "${a_status}"; then
        OC_COMPARE_SOURCE="orchestrationpolicy/status"
        OC_BEFORE_STATE="state=$(_pick_state "${b_brief}" "${b_phase}" "${b_status}")"
        OC_AFTER_STATE="state=$(_pick_state "${a_brief}" "${a_phase}" "${a_status}")"
        if [ "${OC_BEFORE_STATE}" != "${OC_AFTER_STATE}" ]; then
          OC_CHANGED="true"
        else
          OC_CHANGE_REASON="autoscaler observed but replicas unchanged"
        fi
      else
        OC_COMPARE_SOURCE="orchestrationpolicy/status"
        OC_BEFORE_STATE="state=unknown"
        OC_AFTER_STATE="state=selected"
        OC_CHANGED="false"
        OC_CHANGE_REASON="$(_target_missing_reason 'autoscaler / HPA / deployment target not found')"
      fi
      ;;
    provisioning)
      if _is_known "${a_pvc_status}"; then
        OC_COMPARE_SOURCE="pvc/status.phase"
        OC_BEFORE_STATE="pvc=${b_pvc_status:-UNKNOWN}"
        OC_AFTER_STATE="pvc=${a_pvc_status}"
        if [ "${b_pvc_status}" != "${a_pvc_status}" ]; then
          OC_CHANGED="true"
        else
          OC_CHANGE_REASON="pvc/pv/storageclass unchanged"
        fi
      elif _is_known "${a_brief}" || _is_known "${a_phase}" || _is_known "${a_status}"; then
        OC_COMPARE_SOURCE="orchestrationpolicy/status"
        OC_BEFORE_STATE="state=$(_pick_state "${b_brief}" "${b_phase}" "${b_status}")"
        OC_AFTER_STATE="state=$(_pick_state "${a_brief}" "${a_phase}" "${a_status}")"
        if [ "${OC_BEFORE_STATE}" != "${OC_AFTER_STATE}" ]; then
          OC_CHANGED="true"
        else
          OC_CHANGE_REASON="pvc/pv/storageclass unchanged"
        fi
      else
        OC_COMPARE_SOURCE="orchestrationpolicy/status"
        OC_BEFORE_STATE="state=unknown"
        OC_AFTER_STATE="state=selected"
        OC_CHANGED="false"
        OC_CHANGE_REASON="$(_target_missing_reason 'target PVC / PV / storageclass not observed')"
      fi
      ;;
    migration)
      if _is_known "${a_pod_node}"; then
        OC_COMPARE_SOURCE="pod/spec.nodeName"
        OC_BEFORE_STATE="node=${b_pod_node:-UNKNOWN}"
        OC_AFTER_STATE="node=${a_pod_node}"
        if [ "${b_pod_node}" != "${a_pod_node}" ] \
           || { _is_known "${a_pod_uids}" && [ "${b_pod_uids}" != "${a_pod_uids}" ]; }; then
          OC_CHANGED="true"
        else
          OC_CHANGE_REASON="pod node unchanged and migrated pod not found"
        fi
      elif _is_known "${a_brief}" || _is_known "${a_phase}" || _is_known "${a_status}"; then
        OC_COMPARE_SOURCE="orchestrationpolicy/status"
        OC_BEFORE_STATE="state=$(_pick_state "${b_brief}" "${b_phase}" "${b_status}")"
        OC_AFTER_STATE="state=$(_pick_state "${a_brief}" "${a_phase}" "${a_status}")"
        if [ "${OC_BEFORE_STATE}" != "${OC_AFTER_STATE}" ]; then
          OC_CHANGED="true"
        else
          OC_CHANGE_REASON="pod node unchanged and migrated pod not found"
        fi
      else
        OC_COMPARE_SOURCE="orchestrationpolicy/status"
        OC_BEFORE_STATE="state=unknown"
        OC_AFTER_STATE="state=selected"
        OC_CHANGED="false"
        OC_CHANGE_REASON="$(_target_missing_reason 'target workload pod or target deployment not found')"
      fi
      ;;
    preemption)
      OC_COMPARE_SOURCE="pod/metadata.uid"
      OC_BEFORE_STATE="pod_uids=${b_pod_uids:-UNKNOWN}"
      OC_AFTER_STATE="pod_uids=${a_pod_uids:-UNKNOWN}"
      if _is_known "${a_pod_uids}" && [ "${b_pod_uids}" != "${a_pod_uids}" ]; then
        OC_CHANGED="true"
      else
        OC_CHANGE_REASON="$(_target_missing_reason 'preemption event not found')"
      fi
      ;;
    loadbalance|loadbalancing)
      OC_COMPARE_SOURCE="cluster/node pod distribution"
      OC_BEFORE_STATE="node_counts=${b_node_counts:-UNKNOWN}"
      OC_AFTER_STATE="node_counts=${a_node_counts:-UNKNOWN}"
      if _is_known "${a_node_counts}" && [ "${b_node_counts}" != "${a_node_counts}" ]; then
        OC_CHANGED="true"
      else
        OC_CHANGE_REASON="$(_target_missing_reason 'node distribution unchanged')"
      fi
      ;;
    caching)
      OC_COMPARE_SOURCE="orchestrationpolicy/status + cache evidence"
      OC_BEFORE_STATE="state=$(_pick_state "${b_brief}" "${b_phase}" "${b_status}")"
      OC_AFTER_STATE="state=$(_pick_state "${a_brief}" "${a_phase}" "${a_status}")"
      if [ "${OC_BEFORE_STATE}" != "${OC_AFTER_STATE}" ]; then
        OC_CHANGED="true"
      else
        OC_CHANGE_REASON="$(_target_missing_reason 'cache evidence not found or unchanged')"
      fi
      ;;
    *)
      OC_COMPARE_SOURCE="orchestrationpolicy/status"
      OC_BEFORE_STATE="state=$(_pick_state "${b_brief}" "${b_phase}" "${b_status}")"
      OC_AFTER_STATE="state=$(_pick_state "${a_brief}" "${a_phase}" "${a_status}")"
      if [ "${OC_BEFORE_STATE}" != "${OC_AFTER_STATE}" ]; then
        OC_CHANGED="true"
      else
        OC_CHANGE_REASON="$(_target_missing_reason 'orchestrationpolicy status unchanged')"
      fi
      ;;
  esac

  if [ "${OC_CHANGED}" = "true" ]; then
    OC_POLICY_RESULT="✓ applied"
    if [ -z "${OC_CHANGE_REASON}" ]; then
      if _is_known "${a_msg}"; then
        OC_CHANGE_REASON="${a_msg}"
      elif _is_known "${a_brief}"; then
        OC_CHANGE_REASON="${a_brief}"
      else
        OC_CHANGE_REASON="${policy_type} policy applied"
      fi
    fi
    OC_CHANGED="✓ true"
  else
    OC_POLICY_RESULT="⚠ selected / change not observed"
    if [ -z "${OC_CHANGE_REASON}" ]; then
      if _is_known "${a_msg}"; then
        OC_CHANGE_REASON="observed=${a_msg} / no state transition"
      else
        OC_CHANGE_REASON="target resource change not observed"
      fi
    fi
    OC_CHANGED="false"
  fi
}

# =============================================================================
# 웹 접속용 포트포워딩 공통 함수 (Argo/Kubeflow Dashboard 등 외부 UI 접속용).
# =============================================================================

# is_port_in_use는 ss → lsof → fuser 순으로 사용 가능한 도구로 포트 LISTEN 여부를 검사한다.
# 도구가 하나도 없으면 false(미사용으로 간주)를 반환한다.
is_port_in_use() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk -v p=":${port}$" '$4 ~ p {found=1; exit} END {exit !found}'
    return $?
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"${port}" -sTCP:LISTEN -t 2>/dev/null | grep -q .
    return $?
  fi
  if command -v fuser >/dev/null 2>&1; then
    fuser "${port}/tcp" >/dev/null 2>&1
    return $?
  fi
  return 1
}

# detect_port_process는 해당 포트를 LISTEN하는 프로세스의 "pid|cmd" 문자열을 반환한다.
# ss → lsof → fuser → ps 순으로 시도하며, ps fallback은 sandbox/netns 격리 등으로 ss/lsof가
# PID를 보여주지 못하는 환경에서도 kubectl port-forward 프로세스를 식별할 수 있게 한다.
# 가용한 도구가 없거나 식별 실패 시 빈 문자열을 반환한다.
detect_port_process() {
  local port="$1"
  local pid="" cmd=""
  if command -v ss >/dev/null 2>&1; then
    pid="$(ss -ltnp 2>/dev/null \
      | awk -v p=":${port}$" '$4 ~ p {print $NF; exit}' \
      | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)"
  fi
  if [ -z "${pid}" ] && command -v lsof >/dev/null 2>&1; then
    pid="$(lsof -nP -iTCP:"${port}" -sTCP:LISTEN -t 2>/dev/null | head -1)"
  fi
  if [ -z "${pid}" ] && command -v fuser >/dev/null 2>&1; then
    pid="$(fuser "${port}/tcp" 2>/dev/null | tr -s ' ' | awk '{print $1}')"
  fi
  # ps fallback: kubectl port-forward ... <port>: 패턴을 가진 프로세스를 찾는다.
  # ss/lsof가 LISTEN PID를 가려도 ps는 일반적으로 보이므로 sandbox 환경에서도 동작한다.
  if [ -z "${pid}" ]; then
    local line
    line="$(ps -e -o pid=,args= 2>/dev/null \
      | awk -v port="${port}" '
          /kubectl[^ ]*[ ]+port-forward/ && index($0, " "port":") {print; exit}
          /kubectl[^ ]*[ ]+port-forward/ && index($0, ":"port" ") {print; exit}
        ')"
    if [ -n "${line}" ]; then
      pid="$(printf '%s' "${line}" | awk '{print $1}')"
      cmd="$(printf '%s' "${line}" | awk '{$1=""; sub(/^ +/, ""); print}')"
    fi
  fi
  if [ -n "${pid}" ]; then
    [ -z "${cmd}" ] && cmd="$(ps -o args= -p "${pid}" 2>/dev/null | head -1 || true)"
    printf '%s|%s' "${pid}" "${cmd}"
  fi
}

# find_service_from_candidates는 후보 service 이름을 순서대로 받아 kubectl get svc -A 결과에서
# 가장 먼저 매치되는 항목의 "namespace|service" 문자열을 반환한다.
# 매치가 없으면 빈 문자열을 반환한다 (namespace/service 이름을 실행값으로 하드코딩하지 않음).
find_service_from_candidates() {
  local cand all line
  all="$(kubectl get svc -A --no-headers 2>/dev/null)"
  for cand in "$@"; do
    [ -z "${cand}" ] && continue
    line="$(printf '%s\n' "${all}" | awk -v n="${cand}" '$2 == n {print $1 "|" $2; exit}')"
    if [ -n "${line}" ]; then
      printf '%s' "${line}"
      return
    fi
  done
}

# find_service_port는 service의 port 목록 중 우선순위에 따라 remote port 번호를 반환한다.
# 우선순위는 호출자에서 받은 순서 그대로(예: 443 → 80) 적용하고, 모두 없으면 첫 번째 port를 사용한다.
find_service_port() {
  local svc="$1"
  local ns="$2"
  shift 2
  local ports preferred p
  ports="$(kubectl get svc "${svc}" -n "${ns}" -o jsonpath='{range .spec.ports[*]}{.port}{"\n"}{end}' 2>/dev/null)"
  [ -z "${ports}" ] && return 0
  for preferred in "$@"; do
    if printf '%s\n' "${ports}" | grep -qx "${preferred}"; then
      printf '%s' "${preferred}"
      return
    fi
  done
  printf '%s\n' "${ports}" | head -1
}

# start_port_forward는 백그라운드로 kubectl port-forward를 시작하고 PID를 반환한다.
# setsid/nohup이 가능하면 세션을 분리해 부모가 종료되어도 살아남도록 한다.
# 1초 대기 후에도 프로세스가 살아있어야만 PID를 반환하고, 그 외에는 빈 문자열을 반환한다.
start_port_forward() {
  local svc="$1"
  local ns="$2"
  local local_port="$3"
  local remote_port="$4"
  local log_path="$5"
  mkdir -p "$(dirname "${log_path}")"
  local pid
  if command -v setsid >/dev/null 2>&1; then
    setsid nohup kubectl port-forward "svc/${svc}" -n "${ns}" "${local_port}:${remote_port}" \
      </dev/null >"${log_path}" 2>&1 &
  else
    nohup kubectl port-forward "svc/${svc}" -n "${ns}" "${local_port}:${remote_port}" \
      </dev/null >"${log_path}" 2>&1 &
  fi
  pid=$!
  # kubectl port-forward 초기 핸드셰이크가 완료될 시간 확보.
  sleep 1
  if kill -0 "${pid}" 2>/dev/null; then
    printf '%s' "${pid}"
  else
    printf ''
  fi
}

# write_web_access_state는 단일 key=value 라인을 web-access.env 파일에 추가/갱신한다.
# Argo와 Kubeflow가 동일 파일을 누적해서 쓰도록 sed로 in-place 치환한다.
write_web_access_state() {
  local key="$1"
  local value="${2:-}"
  local env_file="${LOG_DIR}/port-forward/web-access.env"
  mkdir -p "$(dirname "${env_file}")"
  touch "${env_file}"
  if grep -q "^${key}=" "${env_file}" 2>/dev/null; then
    # 구분자로 |를 사용해 value에 /가 들어가도 충돌 없게 한다.
    sed -i "s|^${key}=.*|${key}=${value}|" "${env_file}"
  else
    printf '%s=%s\n' "${key}" "${value}" >> "${env_file}"
  fi
}

# _classify_status는 사람용 status 문자열에서 env 파일에 저장할 단순 식별자를 뽑는다.
_classify_status() {
  case "$1" in
    *"port already in use"*) printf 'port-already-in-use' ;;
    *forwarding*)            printf 'forwarding' ;;
    *"not found"*)           printf 'not-found' ;;
    *failed*)                printf 'failed' ;;
    *)                       printf 'unknown' ;;
  esac
}

# _ensure_web_access는 Argo/Kubeflow 공통 진입 로직이다.
# 인자: title, component(ARGO|KUBEFLOW), scheme(http|https), local_port, port_pref_list(공백 구분), candidates...
# port_pref_list가 "443 80"이면 service 포트 중 443→80 순으로 선택한다.
_ensure_web_access() {
  local title="$1"
  local component="$2"
  local scheme="$3"
  local local_port="$4"
  local port_prefs_str="$5"
  shift 5
  local candidates=("$@")

  local start
  start="$(date +%s)"
  print_header "${title}"

  local svc_result ns="" svc=""
  svc_result="$(find_service_from_candidates "${candidates[@]}")"
  ns="${svc_result%%|*}"
  svc="${svc_result##*|}"
  # find_service_from_candidates가 빈 결과를 반환하면 분리 결과도 빈 문자열이 된다.
  [ -z "${svc_result}" ] && { ns=""; svc=""; }

  local web_url="${scheme}://localhost:${local_port}"
  local log_path="${LOG_DIR}/port-forward/${component,,}-${local_port}.log"
  local rel_log_path
  rel_log_path="${log_path#${MODULE_DIR}/}"

  # service를 찾지 못한 경우.
  if [ -z "${ns}" ] || [ -z "${svc}" ]; then
    print_kv "candidates"         "$(printf '%s ' "${candidates[@]}")"
    print_kv "service"            "⚠ not found"
    print_kv "web_url"            "${web_url}"
    print_kv "web_status"         "⚠ not found"
    print_kv "port_forward_pid"   "unknown"
    print_kv "port_forward_log"   "${rel_log_path}"
    write_web_access_state "${component}_URL"    "${web_url}"
    write_web_access_state "${component}_STATUS" "not-found"
    write_web_access_state "${component}_PID"    ""
    write_web_access_state "${component}_LOG"    "${log_path}"
    print_kv "time" "$(measure_time "${start}")"
    print_footer
    return
  fi

  # remote port 결정 (선호 포트 → 첫 포트).
  local remote_port
  # shellcheck disable=SC2086
  remote_port="$(find_service_port "${svc}" "${ns}" ${port_prefs_str})"
  if [ -z "${remote_port}" ]; then
    # 선호 포트 후보 중 첫 번째를 fallback으로.
    remote_port="${port_prefs_str%% *}"
  fi

  # 포트 사용 중인지 검사. 사용 중이면 kubectl port-forward인지 확인해 재사용 여부 결정.
  local pid="" status="" proc_info="" existing_pid="" existing_cmd=""
  if is_port_in_use "${local_port}"; then
    proc_info="$(detect_port_process "${local_port}")"
    existing_pid="${proc_info%%|*}"
    existing_cmd="${proc_info##*|}"
    [ -z "${proc_info}" ] && { existing_pid=""; existing_cmd=""; }
    # kubectl port-forward 프로세스이면서 같은 local port를 쓰는 경우만 재사용으로 판정한다.
    # service 이름이 후보 목록에 있는지도 함께 확인해 다른 서비스의 port-forward 재사용을 막는다.
    if printf '%s' "${existing_cmd}" | grep -q 'kubectl' \
       && printf '%s' "${existing_cmd}" | grep -q 'port-forward' \
       && ( printf '%s' "${existing_cmd}" | grep -q " ${local_port}:" \
            || printf '%s' "${existing_cmd}" | grep -q ":${local_port} " ); then
      local _is_target=0 _c
      for _c in "${candidates[@]}"; do
        if printf '%s' "${existing_cmd}" | grep -q "svc/${_c}\\b\\|/${_c} \\| ${_c} "; then
          _is_target=1
          break
        fi
      done
      if [ "${_is_target}" = "1" ]; then
        pid="${existing_pid}"
        status="✓ forwarding (reused existing pid=${pid})"
      else
        pid=""
        status="⚠ port already in use (pid=${existing_pid:-unknown}, cmd=${existing_cmd:-unknown})"
      fi
    else
      pid=""
      status="⚠ port already in use (pid=${existing_pid:-unknown}, cmd=${existing_cmd:-unknown})"
    fi
  else
    pid="$(start_port_forward "${svc}" "${ns}" "${local_port}" "${remote_port}" "${log_path}")"
    if [ -n "${pid}" ]; then
      status="✓ forwarding"
    else
      status="✗ failed to start (see ${rel_log_path})"
    fi
  fi

  print_kv "namespace_source"   "auto-detected"
  print_kv "namespace_detected" "${ns}"
  print_kv "service"            "${svc}"
  print_kv "remote_port"        "${remote_port}"
  print_kv "web_url"            "${web_url}"
  print_kv "web_status"         "${status}"
  print_kv "port_forward_pid"   "${pid:-unknown}"
  print_kv "port_forward_log"   "${rel_log_path}"
  print_separator
  print_commands_block "command" \
    "kubectl port-forward svc/${svc} -n ${ns} ${local_port}:${remote_port}"

  # state 파일 누적 갱신.
  write_web_access_state "${component}_URL"    "${web_url}"
  write_web_access_state "${component}_STATUS" "$(_classify_status "${status}")"
  write_web_access_state "${component}_PID"    "${pid:-}"
  write_web_access_state "${component}_LOG"    "${log_path}"

  print_kv "time" "$(measure_time "${start}")"
  print_footer
}

# ensure_argo_web_access는 Argo 웹 UI(local 8080)용 포트포워딩을 보장한다.
# 후보 service: argocd-server > argo-server. remote port 우선순위: 443 > 80.
ensure_argo_web_access() {
  _ensure_web_access "Argo Web Port-Forward" "ARGO" "https" "8080" "443 80" \
    argocd-server argo-server
}

# ensure_kubeflow_web_access는 Kubeflow 웹 UI(local 8084)용 포트포워딩을 보장한다.
# 후보 service: istio-ingressgateway > ml-pipeline-ui > centraldashboard. remote port 우선순위: 80 > 443.
ensure_kubeflow_web_access() {
  _ensure_web_access "Kubeflow Web Port-Forward" "KUBEFLOW" "http" "8084" "80 443" \
    istio-ingressgateway ml-pipeline-ui centraldashboard
}

# =============================================================================

print_orchestration_compare_box() {
  local before_file="${LOG_DIR}/before-orchestration-state.txt"
  local after_file="${LOG_DIR}/after-orchestration-state.txt"
  local policy_name policy_type target kind ns changed reason result target_resource operator_id
  policy_name="$(read_state selected_policy_name "$(read_state selected_policy none)")"
  policy_type="$(read_state selected_policy_type "$(selected_policy_type_from_name "${policy_name}")")"
  [ -z "${policy_type}" ] && policy_type="none"
  target="$(_state_kv "${after_file}" target_ref_name)"
  [ -z "${target}" ] || [ "${target}" = "UNKNOWN" ] && target="$(_state_kv "${after_file}" workload)"
  kind="$(_state_kv "${after_file}" target_ref_kind)"
  [ -z "${kind}" ] || [ "${kind}" = "UNKNOWN" ] && kind="Deployment"
  ns="$(_state_kv "${after_file}" target_ref_namespace)"
  [ -z "${ns}" ] || [ "${ns}" = "UNKNOWN" ] && ns="$(_state_kv "${after_file}" workload_namespace)"
  changed="$(read_state changed false)"
  reason="$(read_state change_reason 'target resource change not observed')"
  result="$(read_state policy_result '⚠ not-triggered')"
  operator_id="${policy_name:-UNKNOWN}"
  [ "${operator_id}" = "none" ] && operator_id="UNKNOWN"
  target_resource="$(read_state target_resource "${kind,,}/${target}")"

  print_header "[24] Orchestration Compare"
  print_kv "target"          "${target:-UNKNOWN}"
  print_kv "kind"            "${kind:-UNKNOWN}"
  print_kv "namespace"       "${ns:-UNKNOWN}"
  print_kv "mode"            "compare"
  print_kv "policy"          "${policy_type:-none}"
  print_kv "operator_id"     "${operator_id:-UNKNOWN}"
  print_kv "target_resource" "${target_resource:-UNKNOWN}"
  print_kv "changed"         "${changed}"
  tee_log "${SKY}├─ evidence ───────────────────────────────────────────────────${RESET}"
  print_label_line "before"
  print_ascii_table_block "metric value" "$(printf 'replicas %s\nready %s\npod_count %s\npod_uids %s\npvc %s\nnode_counts %s\noperator %s\n' \
    "$(_state_kv "${before_file}" deploy_replicas)" \
    "$(_state_kv "${before_file}" deploy_ready)" \
    "$(_state_kv "${before_file}" pod_count)" \
    "$(_state_kv "${before_file}" pod_uids)" \
    "$(_state_kv "${before_file}" pvc_name)" \
    "$(_state_kv "${before_file}" node_counts)" \
    "$(_state_kv "${before_file}" policy_status_brief)")"
  print_label_line "after"
  print_ascii_table_block "metric value" "$(printf 'replicas %s\nready %s\npod_count %s\npod_uids %s\npvc %s\nnode_counts %s\noperator %s\n' \
    "$(_state_kv "${after_file}" deploy_replicas)" \
    "$(_state_kv "${after_file}" deploy_ready)" \
    "$(_state_kv "${after_file}" pod_count)" \
    "$(_state_kv "${after_file}" pod_uids)" \
    "$(_state_kv "${after_file}" pvc_name)" \
    "$(_state_kv "${after_file}" node_counts)" \
    "$(_state_kv "${after_file}" policy_status_brief)")"
  print_label_line "command"
  if [ -n "${target}" ] && [ -n "${ns}" ]; then
    print_dim_line "kubectl get pod -n ${ns} -l app=${target} -o wide"
    print_raw_block "pod_wide" "$(capture_cmd "kubectl get pod -n ${ns} -l app=${target} -o wide | sed -n '1,8p'")"
  else
    print_dim_line "kubectl get pod -A -o wide"
  fi
  case "${policy_type}" in
    provisioning)
      print_dim_line "kubectl get pvc,pv -n ${ns}"
      print_raw_block "pvc_pv" "$(capture_cmd "kubectl get pvc,pv -n ${ns} | sed -n '1,8p'")" ;;
    migration)
      print_dim_line "kubectl get pod -n ${ns} -o wide"
      print_raw_block "migration_pods" "$(capture_cmd "kubectl get pod -n ${ns} -o wide | grep -E '${target}|migrat' | sed -n '1,8p'")" ;;
    preemption)
      print_dim_line "kubectl get events -n ${ns} --sort-by=.lastTimestamp | grep -Ei 'evict|preempt|killing'"
      print_raw_block "events" "$(capture_cmd "kubectl get events -n ${ns} --sort-by=.lastTimestamp | grep -Ei 'evict|preempt|killing' | tail -8")" ;;
    loadbalance|loadbalancing)
      print_dim_line "kubectl get pod -A -o wide"
      print_raw_block "node_distribution" "$(capture_cmd "kubectl get pod -A -o wide | sed -n '1,12p'")" ;;
    caching)
      print_dim_line "kubectl get events -n ${ns} --sort-by=.lastTimestamp | grep cache"
      print_raw_block "cache_events" "$(capture_cmd "kubectl get events -n ${ns} --sort-by=.lastTimestamp | grep -i cache | tail -8")" ;;
    autoscaling|scaling)
      print_dim_line "kubectl get hpa -A"
      print_raw_block "hpa" "$(capture_cmd "kubectl get hpa -A | sed -n '1,8p'")" ;;
  esac
  print_kv "validation" "${reason}"
  if printf '%s' "${result}" | grep -q '✓'; then
    tee_log "${SKY}└─ result: ${GREEN}✓ APPLIED ${reason}${RESET}${SKY} ─────────────────────────────${RESET}"
  elif printf '%s' "${result}" | grep -qi 'not-triggered'; then
    tee_log "${SKY}└─ result: ${YELLOW}⚠ WARN no policy selected${RESET}${SKY} ─────────────────────────────${RESET}"
  else
    tee_log "${SKY}└─ result: ${YELLOW}⚠ WARN ${reason}${RESET}${SKY} ─────────────────────────────${RESET}"
  fi
}

print_total_result_box() {
  local workload kind ns node policy_name policy_type policy_resource policy_horizon changed steps warnings fatal
  local change_reason policy_result result_label operator_result_label
  workload="$(read_state selected_workload "$(resolve_workload | awk -F'|' '{print $1}')")"
  ns="$(read_state selected_namespace "$(resolve_target_namespace "${workload}" | awk -F'|' '{print $1}')")"
  kind="$(_state_kv "${LOG_DIR}/after-orchestration-state.txt" target_ref_kind)"
  [ -z "${kind}" ] || [ "${kind}" = "UNKNOWN" ] && kind="Deployment"
  node="$(_state_kv "${LOG_DIR}/after-orchestration-state.txt" pod_node)"
  policy_name="$(read_state selected_policy_name "$(read_state selected_policy none)")"
  policy_type="$(read_state selected_policy_type "$(selected_policy_type_from_name "${policy_name}")")"
  [ -z "${policy_type}" ] && policy_type="none"
  policy_resource="$(read_state policy_resource "$(read_state target_resource UNKNOWN)")"
  policy_horizon="$(read_state policy_horizon UNKNOWN)"
  changed="$(read_state changed false)"
  change_reason="$(read_state change_reason 'target resource change not observed')"
  policy_result="$(read_state policy_result '⚠ not-triggered')"
  warnings="$(grep -R "⚠\\|WARN" "${STATE_DIR}" 2>/dev/null | wc -l | tr -d ' ' || true)"
  fatal="$(grep -R "✗\\|FAIL" "${STATE_DIR}" 2>/dev/null | wc -l | tr -d ' ' || true)"
  steps="24/24 completed"
  [ "${warnings:-0}" -gt 0 ] && steps="${steps} with warnings"
  # TOTAL RESULT는 실제 evidence(changed)와 정책 선택 여부로 판단한다.
  if [ "${fatal:-0}" -gt 0 ]; then
    result_label="${RED}✗ FAIL${RESET}"
  elif printf '%s' "${changed}" | grep -q 'true'; then
    result_label="${GREEN}✓ APPLIED${RESET}"
  elif [ -n "${policy_name}" ] && [ "${policy_name}" != "none" ]; then
    result_label="${YELLOW}⚠ WARN selected / ${change_reason}${RESET}"
  else
    result_label="${YELLOW}⚠ WARN no policy selected${RESET}"
  fi
  # 정책별 operator 결과 라인: changed=false면 PASS로 찍지 않고 구체 사유를 표시한다.
  if [ "${policy_name}" = "none" ] || [ -z "${policy_name}" ]; then
    operator_result_label="${YELLOW}⚠ WARN no policy selected${RESET}"
  elif printf '%s' "${changed}" | grep -q 'true'; then
    operator_result_label="${GREEN}✓ APPLIED ${change_reason}${RESET}"
  else
    operator_result_label="${YELLOW}⚠ WARN ${change_reason}${RESET}"
  fi
  tee_log "${SKY}╔══════════════════════════════════════════════════════════════╗${RESET}"
  tee_log "${SKY}║  TOTAL RESULT                                                ║${RESET}"
  tee_log "${SKY}╠══════════════════════════════════════════════════════════════╣${RESET}"
  tee_log "${SKY}║${RESET}  $(printf '%-12s' "Steps") : ${steps}"
  tee_log "${SKY}║${RESET}  $(printf '%-12s' "Workload") : ${workload:-UNKNOWN}"
  tee_log "${SKY}║${RESET}  $(printf '%-12s' "Kind") : ${kind:-UNKNOWN}"
  tee_log "${SKY}║${RESET}  $(printf '%-12s' "Namespace") : ${ns:-UNKNOWN}"
  tee_log "${SKY}║${RESET}  $(printf '%-12s' "Node") : ${node:-UNKNOWN}"
  tee_log "${SKY}║${RESET}  $(printf '%-12s' "Policy") : ${policy_type:-none} / ${policy_resource:-UNKNOWN} / ${policy_horizon:-UNKNOWN}"
  tee_log "${SKY}║${RESET}  $(printf '%-12s' "Operator") : ${policy_type:-none} / ${policy_name:-UNKNOWN}"
  tee_log "${SKY}║${RESET}  $(printf '%-12s' "Changed") : ${changed}"
  tee_log "${SKY}║${RESET}  $(printf '%-12s' "Op Result") : ${operator_result_label}"
  tee_log "${SKY}║${RESET}  $(printf '%-12s' "Result") : ${result_label}"
  tee_log "${SKY}╚══════════════════════════════════════════════════════════════╝${RESET}"
}

# print_cycle_summary는 전체 사이클의 요약을 실제 kubectl 결과와 state 파일로부터 출력한다.
print_cycle_summary() {
  local total_seconds=0 f value
  for f in "${STATE_DIR}"/time-*; do
    [ -f "${f}" ] || continue
    value="$(cat "${f}")"
    total_seconds=$((total_seconds + ${value%s}))
  done
  save_state total_time "$(format_duration "${total_seconds}")"

  print_header "KETI Intelligent Orchestration Cycle Summary"
  if kubectl get nodes >/dev/null 2>&1; then
    print_kv "kubernetes" "✓ ready / version=$(detect_kubernetes_version)"
  else
    print_kv "kubernetes" "⚠ unavailable / version=$(detect_kubernetes_version)"
  fi
  print_kv "argo"      "$(read_state argo 'SKIP_EXTERNAL_DEPENDENCY') / version=$(detect_argo_version)"
  print_kv "kubeflow"  "$(read_state kubeflow 'SKIP_EXTERNAL_DEPENDENCY') / version=$(detect_kubeflow_version)"
  print_kv "kueue"     "$(read_state kueue 'SKIP_EXTERNAL_DEPENDENCY') / version=$(detect_kueue_version)"
  print_kv "scheduler" "$(read_state scheduler '⚠ pending')"
  print_separator
  print_kv "storage_algorithm"   "before=$(read_state before_storage_algorithm UNKNOWN) → after=$(read_state after_storage_algorithm UNKNOWN)"
  print_kv "preprocessing_algo"  "before=$(read_state before_preprocessing_algorithm UNKNOWN) → after=$(read_state after_preprocessing_algorithm UNKNOWN)"
  print_kv "training_infer_algo" "before=$(read_state before_training_infer_algorithm UNKNOWN) → after=$(read_state after_training_infer_algorithm UNKNOWN)"
  print_separator
  print_kv "insight_hub"          "$(read_state insight_hub SKIP_NOT_FOUND)"
  print_kv "insight_scope"        "$(read_state insight_scope SKIP_NOT_FOUND)"
  print_kv "insight_trace"        "$(read_state insight_trace SKIP_NOT_FOUND)"
  print_separator
  print_label_line "Decision Pipeline"
  print_kv "existing_forecast"     "$(read_state existing_forecast '⚠ not observed')"
  print_kv "current_forecast"      "$(read_state current_forecast '⚠ not evaluated')"
  print_kv "forecaster_candidates" "$(read_state forecaster_candidates 'candidate scores unavailable in API response')"
  print_kv "selected_confidence"   "$(read_state selected_confidence '<n/a>')"
  print_kv "scheduling_policy_status" "$(read_state scheduling_policy_status '⚠ not observed')"
  local _sp _ps
  _sp="$(read_state selected_policy none)"
  _ps="$(read_state policy_source none)"
  if [ "${_sp}" = "none" ]; then
    print_kv "orchestration_policy_status" "⚠ no-policy-selected / source=${_ps}"
  else
    print_kv "orchestration_policy_status" "$(read_state orchestration_policy_status '✓ selected') / selected=${_sp} / source=${_ps}"
  fi
  print_kv "orchestrator_apply_result" "$(read_state orchestrator_apply_result '⚠ not observed')"
  print_separator
  print_kv "selected_policy" "$(read_state selected_policy none)"
  print_kv "policy_type"     "$(read_state selected_policy_type none)"
  print_kv "target_resource" "$(read_state target_resource UNKNOWN)"
  print_kv "compare_source"  "$(read_state compare_source UNKNOWN)"
  print_kv "before_state"    "$(read_state before_state UNKNOWN)"
  print_kv "after_state"     "$(read_state after_state UNKNOWN)"
  print_kv "changed"         "$(read_state changed false)"
  print_kv "change_reason"   "$(read_state change_reason 'target resource change not observed')"
  print_kv "resource_change_result" "$(read_state resource_change_result "$(read_state policy_result '⚠ not-triggered')")"
  print_kv "policy_source"   "$(read_state policy_source none)"
  print_kv "policy_reason"   "$(read_state policy_reason 'current workload condition does not require orchestration')"
  print_kv "binding"         "$(read_state binding '⚠ binding not checked')"
  print_kv "total_time"      "$(read_state total_time "$(format_duration "${total_seconds}")")"
  print_footer
  print_total_result_box
}
