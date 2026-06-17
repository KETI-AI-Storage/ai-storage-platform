#!/usr/bin/env bash
# runtime.sh는 시연 시나리오 스크립트(scenario1/01~05, scenario2/01~06, run-scenario1/2)가
# 공유하는 runtime state 파일 입출력과 워크로드/매니페스트/정책 자동 탐색 유틸을 제공한다.
# 본 파일은 source 전용이며 직접 실행하지 않는다.
#
# 본 라이브러리는 다음 원칙을 강제한다.
#   - 스크립트 내부에서 특정 워크로드/PVC/app label/namespace/정책 이름을 기본값으로 박지 않는다.
#   - 값은 다음 우선순위로만 결정한다.
#       (1) 사용자 positional argument
#       (2) runtime state 파일 (.runtime/<scenario>.env)
#       (3) manifest 파싱 결과
#       (4) kubectl로 라벨/필드 셀렉터 조회한 실제 클러스터 상태
#   - 위 어떤 경로로도 단일 값으로 특정되지 않으면 die()로 명확히 중단한다.
#
# Author: 미정
# Created: 2026-05-22
# Related:
#   - year3-integration/4.integration_test/scripts/demo/common.sh
#   - year3-integration/4.integration_test/manifests/*.yaml

# WHY: 호출 측 common.sh가 이미 set -euo pipefail을 켜둔다는 가정. 본 파일은 source 전용이라
#      set을 다시 잡지 않는다. 다만 변수 미설정 오류는 호출 측에서 잡히도록 unset 검사만 한다.

# 디렉터리 상수 (이 파일이 위치한 demo/ 디렉터리를 기준으로 결정).
DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="${DEMO_DIR}/.runtime"
INTEGRATION_DIR="$(cd "${DEMO_DIR}/../.." && pwd)"
MANIFESTS_DIR="${INTEGRATION_DIR}/manifests"

mkdir -p "${RUNTIME_DIR}" 2>/dev/null || true
mkdir -p "${RUNTIME_DIR}/logs" 2>/dev/null || true
mkdir -p "${RUNTIME_DIR}/api" 2>/dev/null || true
mkdir -p "${RUNTIME_DIR}/snapshots" 2>/dev/null || true

# ─────────────────────────────────────────────────────────────
# 로그 저장 (tee 기반).
# 각 시나리오 스크립트는 시작 시 init_log SCENARIO STEP_NAME 을 호출한다.
# stdout/stderr가 .runtime/logs/<scenario>-<step>-YYYYMMDD-HHMMSS.log 로 동시에 저장된다.
# 화면 출력은 그대로 유지된다. 실패한 스크립트도 trap을 통해 log_file 경로가 출력된다.
# ─────────────────────────────────────────────────────────────

__RUNTIME_EXIT_HOOKS=()
__RUNTIME_TRAP_INSTALLED=""

# runtime_add_exit_hook 'shell command'
# 각 시나리오 스크립트는 cleanup이 필요한 경우 init_log 이후 본 함수로 후크를 추가한다.
# 후크는 등록 순서대로 실행되고, 마지막에 log_file=... 한 줄이 출력된다.
runtime_add_exit_hook() {
  __RUNTIME_EXIT_HOOKS+=("$1")
}

__runtime_run_exit_hooks() {
  local rc=$?
  local h
  for h in "${__RUNTIME_EXIT_HOOKS[@]:-}"; do
    [[ -z "${h}" ]] && continue
    eval "${h}" || true
  done
  exit "${rc}"
}

# init_log STEP_NAME
#   화면에는 시연용 핵심 요약(screen() 호출)만 노출하고,
#   기존 echo는 모두 .runtime/logs/<step>-YYYYMMDD-HHMMSS.log 파일에만 기록한다.
#   stderr는 화면+로그 둘 다로 가서 die/에러는 눈에 띈다.
#   step name은 시나리오 prefix 없이 번호로 시작한다 (예: "01.preprocessing-workload").
init_log() {
  local step="${1:?init_log: step name required}"
  local ts logs_dir
  ts="$(date +%Y%m%d-%H%M%S)"
  logs_dir="${RUNTIME_DIR}/logs"
  mkdir -p "${logs_dir}"
  LOG_FILE="${logs_dir}/${step}-${ts}.log"
  # WHY: 시연 화면을 fd 3에 백업해 두고, 일반 stdout/stderr는 LOG_FILE에만 흘려보낸다.
  #      이렇게 하면 기존 echo는 화면에서 사라지고 LOG_FILE에 그대로 남는다.
  #      부모 어셈블러가 먼저 fd 3을 잡아두었으면 그대로 두어 부모 터미널에 출력한다.
  if ! { true >&3; } 2>/dev/null; then
    exec 3>&1
  fi
  if ! { true >&4; } 2>/dev/null; then
    exec 4>&2
  fi
  exec >>"${LOG_FILE}" 2>>"${LOG_FILE}"
  if [[ -z "${__RUNTIME_TRAP_INSTALLED}" ]]; then
    __RUNTIME_TRAP_INSTALLED=1
    trap __runtime_run_exit_hooks EXIT
  fi
}

# log_only "..."  — 화면에 노출하지 않고 LOG_FILE에만 상세 검증값을 기록한다.
# init_log 호출 후 stdout=LOG_FILE이므로 단순 echo와 동일하게 동작한다.
log_only() {
  printf '%s\n' "$*"
}

# screen "..."  — 시연 화면(fd 3)과 LOG_FILE 양쪽에 출력한다.
screen() {
  printf '%s\n' "$*"
  printf '%s\n' "$*" >&3
}

# screen_title은 시연 화면에 단계 제목 블록을 출력한다.
screen_title() {
  screen "================================"
  screen "$*"
  screen "================================"
}

# screen_err "..."  — die 등 에러 메시지를 화면(fd 4) + LOG_FILE에 함께 보낸다.
screen_err() {
  printf '%s\n' "$*" >&2
  printf '%s\n' "$*" >&4
}

# RUNTIME_LABEL_TYPE/STAGE는 manifest와 실 클러스터 양쪽에서 사용하는 공통 라벨이다.
# 워크로드 이름을 박지 않고도 "전처리 워크로드"를 단일 식별할 수 있는 유일한 키.
RUNTIME_LABEL_TYPE_KEY="workload.keti.io/type"
RUNTIME_LABEL_TYPE_VAL="preprocessing"
RUNTIME_LABEL_STAGE_KEY="workload.keti.io/stage"
RUNTIME_LABEL_STAGE_VAL="preprocess"
RUNTIME_LABEL_SELECTOR="${RUNTIME_LABEL_TYPE_KEY}=${RUNTIME_LABEL_TYPE_VAL},${RUNTIME_LABEL_STAGE_KEY}=${RUNTIME_LABEL_STAGE_VAL}"

# die는 호출 사유와 다음 단계 안내를 출력하고 종료한다.
die() {
  # WHY: die는 stderr(LOG_FILE)와 화면(fd 4) 양쪽에 노출해서 사용자가 즉시 인지하도록 한다.
  printf 'ERROR: %s\n' "$*" >&2
  if [[ "${RUNTIME_SUPPRESS_DIE_SCREEN:-}" != "1" ]] && { true >&4; } 2>/dev/null; then
    printf 'ERROR: %s\n' "$*" >&4
  fi
  exit 1
}

# die_missing는 누락된 값과 먼저 실행해야 할 단계를 함께 표기한다.
#   die_missing FIELD HINT
die_missing() {
  local field="${1:-<unknown>}" hint="${2:-앞 단계를 먼저 실행하거나 positional argument로 지정하세요.}"
  die "${field} 값을 단일 후보로 특정할 수 없습니다. ${hint}"
}

# require_cmd_runtime은 외부 커맨드 존재 여부를 확인한다.
# common.sh에 동명의 require_cmd가 있어 이름 충돌을 피한다.
require_cmd_runtime() {
  local missing=0 c
  for c in "$@"; do
    if ! command -v "${c}" >/dev/null 2>&1; then
      echo "ERROR: required command not found in PATH: ${c}" >&2
      missing=1
    fi
  done
  [[ "${missing}" -eq 0 ]] || exit 1
}

# state_file_path SCENARIO -> echoes .runtime/<scenario>.env path.
state_file_path() {
  local scenario="${1:-}"
  [[ -n "${scenario}" ]] || die "state_file_path: scenario name required"
  echo "${RUNTIME_DIR}/${scenario}.env"
}

# state_load SCENARIO -> existing 파일을 현재 셸로 source한다. 없으면 비-0 반환.
state_load() {
  local scenario="${1:-}" f
  [[ -n "${scenario}" ]] || die "state_load: scenario name required"
  f="$(state_file_path "${scenario}")"
  if [[ -f "${f}" ]]; then
    # shellcheck disable=SC1090
    source "${f}"
    return 0
  fi
  return 1
}

# state_put SCENARIO KEY VALUE
# WHY: source 호환을 위해 double-quote escape를 직접 처리한다. 같은 KEY가 있으면 교체한다.
#      LAST_UPDATED_AT은 다른 키가 갱신될 때마다 자동으로 함께 갱신된다(키 자체를 갱신할 땐 재귀 없이 그대로).
state_put() {
  local scenario="${1:-}" key="${2:-}" value="${3-}"
  [[ -n "${scenario}" && -n "${key}" ]] || die "state_put: scenario/key required"
  mkdir -p "${RUNTIME_DIR}"
  local f tmp esc
  f="$(state_file_path "${scenario}")"
  tmp="${f}.tmp"
  if [[ -f "${f}" ]]; then
    grep -vE "^${key}=" "${f}" > "${tmp}" 2>/dev/null || :
  else
    : > "${tmp}"
  fi
  esc="$(printf '%s' "${value}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
  printf '%s="%s"\n' "${key}" "${esc}" >> "${tmp}"
  mv "${tmp}" "${f}"
  if [[ "${key}" != "LAST_UPDATED_AT" ]]; then
    grep -vE '^LAST_UPDATED_AT=' "${f}" > "${tmp}" 2>/dev/null || :
    printf 'LAST_UPDATED_AT="%s"\n' "$(date -Iseconds)" >> "${tmp}"
    mv "${tmp}" "${f}"
  fi
}

# state_init SCENARIO 는 필수 키 스켈레톤을 만들고 SCENARIO_NAME만 채운다.
# 다른 키는 빈 문자열로 두어 후속 단계가 채우도록 한다.
state_init() {
  local scenario="${1:-}" k f
  [[ -n "${scenario}" ]] || die "state_init: scenario name required"
  state_put "${scenario}" "SCENARIO_NAME" "${scenario}"
  f="$(state_file_path "${scenario}")"
  for k in MANIFEST_PATH MANIFEST_SOURCE API_VERSION NAMESPACE WORKLOAD_KIND WORKLOAD_NAME RESOURCE_TYPE RESOURCE_REF APP_LABEL_KEY APP_LABEL_VALUE PVC_NAMES POD_SELECTOR LABEL_SELECTOR OWNER_KIND OWNER_NAME SELECTED_NODE POLICY_ID POLICY_NAME POLICY_TYPE POLICY_RESOURCE POLICY_HORIZON POLICY_REASON RECOMMENDATION_NODE RECOMMENDATION_COUNT RECOMMENDATION_FILE REQUEST_ID TRACE_ID API_RESPONSE_FILE; do
    if ! grep -qE "^${k}=" "${f}" 2>/dev/null; then
      printf '%s=""\n' "${k}" >> "${f}"
    fi
  done
}

# require_python3은 python3 + yaml 모듈 존재 여부를 검사한다.
require_python3() {
  command -v python3 >/dev/null 2>&1 || die "python3 not found in PATH (manifest 파싱에 필요)"
  python3 -c 'import yaml' >/dev/null 2>&1 || die "python3 yaml 모듈을 찾지 못함 (pip install pyyaml)"
}

# is_manifest_path ARG -> arg가 매니페스트 경로처럼 보이면 0, 아니면 1.
is_manifest_path() {
  local a="${1:-}"
  [[ -z "${a}" ]] && return 1
  case "${a}" in
    *.yaml|*.yml) return 0 ;;
    */*) [[ -f "${a}" ]] && return 0 ;;
  esac
  [[ -f "${a}" ]]
}

# kind_to_kubectl_resource KIND [API_VERSION]
#   workload kind/apiVersion을 kubectl resource type으로 변환한다.
kind_to_kubectl_resource() {
  local kind="${1:-}" api="${2:-}"
  case "${kind}" in
    Pod) echo "pod" ;;
    Deployment) echo "deployment" ;;
    StatefulSet) echo "statefulset" ;;
    DaemonSet) echo "daemonset" ;;
    Job) echo "job" ;;
    CronJob) echo "cronjob" ;;
    Workflow) echo "workflow.argoproj.io" ;;
    PyTorchJob) echo "pytorchjob.kubeflow.org" ;;
    TFJob) echo "tfjob.kubeflow.org" ;;
    MPIJob) echo "mpijob.kubeflow.org" ;;
    *)
      case "${api}/${kind}" in
        argoproj.io/*/Workflow) echo "workflow.argoproj.io" ;;
        kubeflow.org/*/PyTorchJob) echo "pytorchjob.kubeflow.org" ;;
        kubeflow.org/*/TFJob) echo "tfjob.kubeflow.org" ;;
        kubeflow.org/*/MPIJob) echo "mpijob.kubeflow.org" ;;
        *) return 1 ;;
      esac
      ;;
  esac
}

is_supported_workload_kind() {
  local kind="${1:-}" api="${2:-}"
  kind_to_kubectl_resource "${kind}" "${api}" >/dev/null 2>&1
}

# resource_type_to_kind RESOURCE_TYPE
#   kubectl resource type을 runtime kind 이름으로 되돌린다.
resource_type_to_kind() {
  local resource="${1:-}"
  case "${resource}" in
    pod|pods) echo "Pod" ;;
    deployment|deploy|deployments) echo "Deployment" ;;
    statefulset|statefulsets|sts) echo "StatefulSet" ;;
    daemonset|daemonsets|ds) echo "DaemonSet" ;;
    job|jobs) echo "Job" ;;
    cronjob|cronjobs) echo "CronJob" ;;
    workflow.argoproj.io|workflows.argoproj.io|workflow|workflows) echo "Workflow" ;;
    pytorchjob.kubeflow.org|pytorchjobs.kubeflow.org|pytorchjob|pytorchjobs) echo "PyTorchJob" ;;
    tfjob.kubeflow.org|tfjobs.kubeflow.org|tfjob|tfjobs) echo "TFJob" ;;
    mpijob.kubeflow.org|mpijobs.kubeflow.org|mpijob|mpijobs) echo "MPIJob" ;;
    *) return 1 ;;
  esac
}

# parse_manifest MANIFEST_PATH [RESOURCE_NAME]
#   매니페스트의 workload 후보와 동봉된 PVC들을 파싱해 key=value 줄을 표준출력으로 흘린다.
#   출력 키: API_VERSION, KIND, NAME, NAMESPACE, RESOURCE_TYPE, RESOURCE_REF, APP_KEY, APP_VALUE, POD_SELECTOR, PVCS
#   실패 시 'ERROR=...' 를 1줄 출력하고 비-0 반환.
parse_manifest() {
  local manifest="${1:-}" resource_name="${2:-}"
  [[ -f "${manifest}" ]] || { echo "ERROR=manifest not found: ${manifest}"; return 1; }
  require_python3
  python3 - "${manifest}" "${resource_name}" <<'PYEOF'
import sys, yaml
path = sys.argv[1]
wanted = sys.argv[2] if len(sys.argv) > 2 else ""
SUPPORTED = {
    ("apps/v1", "Deployment"): "deployment",
    ("apps/v1", "StatefulSet"): "statefulset",
    ("apps/v1", "DaemonSet"): "daemonset",
    ("batch/v1", "Job"): "job",
    ("batch/v1", "CronJob"): "cronjob",
    ("argoproj.io/v1alpha1", "Workflow"): "workflow.argoproj.io",
    ("kubeflow.org/v1", "PyTorchJob"): "pytorchjob.kubeflow.org",
    ("kubeflow.org/v1", "TFJob"): "tfjob.kubeflow.org",
    ("kubeflow.org/v1", "MPIJob"): "mpijob.kubeflow.org",
}
KIND_RESOURCE = {
    "Deployment": "deployment",
    "StatefulSet": "statefulset",
    "DaemonSet": "daemonset",
    "Job": "job",
    "CronJob": "cronjob",
    "Workflow": "workflow.argoproj.io",
    "PyTorchJob": "pytorchjob.kubeflow.org",
    "TFJob": "tfjob.kubeflow.org",
    "MPIJob": "mpijob.kubeflow.org",
}
try:
    with open(path, 'r', encoding='utf-8') as fh:
        docs = list(yaml.safe_load_all(fh))
except Exception as exc:
    print("ERROR=" + str(exc)[:200])
    sys.exit(1)
workload = None
pvcs = []
for d in docs:
    if not isinstance(d, dict):
        continue
    kind = d.get('kind', '')
    api = d.get('apiVersion', '')
    md = d.get('metadata') or {}
    name = md.get('name', '')
    if kind == 'PersistentVolumeClaim':
        pvcs.append(name)
        continue
    if kind not in KIND_RESOURCE:
        continue
    if wanted and name != wanted:
        continue
    if workload is None:
        workload = d
if not workload:
    print("ERROR=no supported workload in manifest")
    sys.exit(1)
api = workload.get('apiVersion', '')
kind = workload.get('kind', '')
resource_type = SUPPORTED.get((api, kind)) or KIND_RESOURCE.get(kind, "")
md = workload.get('metadata') or {}
name = md.get('name', '')
ns = md.get('namespace', '')
labels = md.get('labels') or {}
spec = workload.get('spec') or {}
app_key = ''
app_value = ''
selector_labels = (((spec.get('selector') or {}).get('matchLabels')) or {})
template_labels = ((((spec.get('template') or {}).get('metadata') or {}).get('labels')) or {})
for source in (selector_labels, template_labels, labels):
    for k in ('app', 'app.kubernetes.io/name'):
        if k in source:
            app_key, app_value = k, str(source[k])
            break
    if app_key:
        break
if not app_key:
    for source in (selector_labels, template_labels, labels):
        if source:
            k = next(iter(source))
            app_key, app_value = k, str(source[k])
            break
pod_selector = "{}={}".format(app_key, app_value) if app_key else ""
print("API_VERSION=" + api)
print("KIND=" + kind)
print("NAME=" + name)
print("NAMESPACE=" + ns)
print("RESOURCE_TYPE=" + resource_type)
print("RESOURCE_REF=" + (resource_type + "/" + name if resource_type and name else ""))
print("APP_KEY=" + app_key)
print("APP_VALUE=" + app_value)
print("POD_SELECTOR=" + pod_selector)
print("PVCS=" + ",".join(pvcs))
PYEOF
}

# list_manifest_workloads [RESOURCE_NAME]
#   MANIFESTS_DIR 안의 yaml/yml에서 지원 workload 후보를 path|apiVersion|kind|name|namespace 형태로 출력한다.
list_manifest_workloads() {
  local wanted="${1:-}"
  require_python3
  local f
  shopt -s nullglob
  for f in "${MANIFESTS_DIR}"/*.yaml "${MANIFESTS_DIR}"/*.yml; do
    [[ -f "${f}" ]] || continue
    python3 - "${f}" "${wanted}" <<'PYEOF' || true
import sys, yaml
path = sys.argv[1]
wanted = sys.argv[2] if len(sys.argv) > 2 else ""
supported = {"Deployment","StatefulSet","DaemonSet","Job","CronJob","Workflow","PyTorchJob","TFJob","MPIJob"}
try:
    with open(path, encoding="utf-8") as fh:
        docs = list(yaml.safe_load_all(fh))
except Exception:
    sys.exit(1)
for d in docs:
    if not isinstance(d, dict):
        continue
    kind = d.get("kind", "")
    if kind not in supported:
        continue
    md = d.get("metadata") or {}
    name = md.get("name", "")
    if wanted and name != wanted:
        continue
    print("|".join([path, d.get("apiVersion", ""), kind, name, md.get("namespace", "")]))
PYEOF
  done
  shopt -u nullglob
}

# find_preprocessing_manifests
#   MANIFESTS_DIR 안의 yaml 중 workload.keti.io/type=preprocessing 라벨을 가진 지원 workload 파일을 출력한다.
find_preprocessing_manifests() {
  local line
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    local f="${line%%|*}" name
    name="$(printf '%s\n' "${line}" | awk -F'|' '{print $4}')"
    python3 - "${f}" "${name}" "${RUNTIME_LABEL_TYPE_KEY}" "${RUNTIME_LABEL_TYPE_VAL}" \
      "${RUNTIME_LABEL_STAGE_KEY}" "${RUNTIME_LABEL_STAGE_VAL}" <<'PYEOF' >/dev/null 2>&1 && echo "${f}"
import sys, yaml
path, wanted, k1, v1, k2, v2 = sys.argv[1:7]
try:
    with open(path, encoding="utf-8") as fh:
        docs = list(yaml.safe_load_all(fh))
except Exception:
    sys.exit(1)
for d in docs:
    if not isinstance(d, dict):
        continue
    md = d.get("metadata") or {}
    if wanted and md.get("name", "") != wanted:
        continue
    labels = md.get("labels") or {}
    tmpl_labels = ((((d.get("spec") or {}).get("template") or {}).get("metadata") or {}).get("labels") or {})
    if (labels.get(k1) == v1 and labels.get(k2) == v2) or (tmpl_labels.get(k1) == v1 and tmpl_labels.get(k2) == v2):
        sys.exit(0)
sys.exit(1)
PYEOF
  done < <(list_manifest_workloads)
}

# resolve_manifest_path_or_resource_name INPUT [NAMESPACE]
#   매니페스트 경로를 1개로 결정한다.
#     1. 인자가 파일 경로면 그대로 사용
#     2. 인자가 파일명이면 manifests 디렉터리에서 파일명 검색
#     3. 인자가 워크로드 이름이면 manifests 디렉터리에서 같은 이름의 지원 workload 매니페스트 검색
#     4. 인자가 없으면 preprocessing 라벨 후보가 정확히 1개일 때만 채택
#   결정 실패 시 die_missing.
resolve_manifest_path_or_resource_name() {
  local arg="${1:-}" ns="${2:-}"
  if [[ -n "${arg}" && -f "${arg}" ]]; then
    echo "${arg}"
    return 0
  fi
  if [[ -n "${arg}" && "${arg}" == */* ]]; then
    die "manifest 파일이 존재하지 않습니다: ${arg}"
  fi
  if [[ -n "${arg}" && "${arg}" == *.y*ml ]]; then
    local by_file=""
    by_file="$(find "${MANIFESTS_DIR}" -maxdepth 1 -type f \( -name "${arg}" -o -name "$(basename "${arg}")" \) 2>/dev/null | sort || true)"
    local file_count
    file_count="$(printf '%s\n' "${by_file}" | sed '/^$/d' | wc -l | tr -d ' ')"
    case "${file_count}" in
      1) printf '%s\n' "${by_file}" ;;
      0) die_missing "MANIFEST_PATH" "파일명 '${arg}'와 일치하는 manifest가 ${MANIFESTS_DIR} 에 없습니다." ;;
      *) die "MANIFEST_PATH 후보가 ${file_count}개입니다. 파일 경로를 직접 지정하세요. 후보=
${by_file}" ;;
    esac
    return 0
  fi
  if [[ -n "${arg}" ]]; then
    local matches filtered count
    matches="$(list_manifest_workloads "${arg}" | sed '/^$/d')"
    if [[ -n "${ns}" ]]; then
      filtered="$(printf '%s\n' "${matches}" | awk -F'|' -v ns="${ns}" '($5=="" || $5==ns){print}')"
    else
      filtered="${matches}"
    fi
    count="$(printf '%s\n' "${filtered}" | sed '/^$/d' | wc -l | tr -d ' ')"
    case "${count}" in
      1) printf '%s\n' "${filtered}" | awk -F'|' '{print $1}' ;;
      0) die_missing "MANIFEST_PATH" "인자 '${arg}'와 일치하는 workload 리소스를 가진 매니페스트가 ${MANIFESTS_DIR} 에 없습니다." ;;
      *) die "MANIFEST_PATH 값을 단일 후보로 특정할 수 없습니다.
후보:
$(printf '%s\n' "${filtered}" | awk -F'|' '{printf "- path=%s apiVersion=%s kind=%s name=%s namespace=%s\n",$1,$2,$3,$4,($5?$5:"<none>")}')" ;;
    esac
    return 0
  fi
  local candidates count=0 first="" f
  while IFS= read -r f; do
    [[ -z "${f}" ]] && continue
    count=$((count + 1))
    [[ -z "${first}" ]] && first="${f}"
    candidates+="${f}"$'\n'
  done < <(find_preprocessing_manifests | awk '!seen[$0]++')
  case "${count}" in
    0) die_missing "MANIFEST_PATH" "인자를 주거나 ${MANIFESTS_DIR} 에 라벨이 일치하는 매니페스트를 두세요." ;;
    1) echo "${first}" ;;
    *) die "MANIFEST_PATH 후보가 ${count}개입니다. 인자로 매니페스트 경로 또는 워크로드 이름을 지정하세요. 후보=
${candidates%$'\n'}" ;;
  esac
}

# discover_manifest [POSITIONAL_ARG] [NAMESPACE]
#   resolve_manifest_path_or_resource_name 호환 래퍼.
discover_manifest() {
  resolve_manifest_path_or_resource_name "${1:-}" "${2:-}"
}

# detect_manifest_* helpers.
detect_manifest_api_version() { parse_manifest "${1:?manifest}" "${2:-}" | grep -aE '^API_VERSION=' | head -1 | sed 's/^API_VERSION=//'; }
detect_manifest_kind() { parse_manifest "${1:?manifest}" "${2:-}" | grep -aE '^KIND=' | head -1 | sed 's/^KIND=//'; }
detect_manifest_name() { parse_manifest "${1:?manifest}" "${2:-}" | grep -aE '^NAME=' | head -1 | sed 's/^NAME=//'; }
detect_manifest_namespace() { parse_manifest "${1:?manifest}" "${2:-}" | grep -aE '^NAMESPACE=' | head -1 | sed 's/^NAMESPACE=//'; }

# detect_workload_from_manifest MANIFEST_PATH [NAMESPACE_OVERRIDE] [RESOURCE_NAME]
#   namespace override를 반영한 workload 메타데이터를 출력한다.
detect_workload_from_manifest() {
  local manifest="${1:?manifest}" ns_override="${2:-}" resource_name="${3:-}" parsed ns
  parsed="$(parse_manifest "${manifest}" "${resource_name}")" || return 1
  ns="$(grep -aE '^NAMESPACE=' <<<"${parsed}" | head -1 | sed 's/^NAMESPACE=//')"
  if [[ -n "${ns_override}" ]]; then
    printf '%s\n' "${parsed}" | grep -avE '^NAMESPACE='
    printf 'NAMESPACE=%s\n' "${ns_override}"
  else
    printf '%s\n' "${parsed}"
  fi
}

# discover_namespace
#   webhook 통합 대상이 되는 namespace를 라벨로 결정한다(keti-ai-storage-injection=enabled).
#   0개 또는 2개 이상이면 die. 1개일 때만 단일 값으로 echo.
discover_namespace() {
  local out count
  out="$(kubectl get ns -l keti-ai-storage-injection=enabled \
          -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | sed '/^$/d' || true)"
  count="$(printf '%s\n' "${out}" | sed '/^$/d' | wc -l | tr -d ' ')"
  case "${count}" in
    0) die_missing "NAMESPACE" "라벨 keti-ai-storage-injection=enabled 인 namespace가 없습니다. namespace 인자를 지정하거나 클러스터 라벨을 먼저 설정하세요." ;;
    1) printf '%s' "${out}" ;;
    *) die "NAMESPACE 후보가 ${count}개입니다. 두 번째 인자로 namespace를 명시하세요. 후보=
${out}" ;;
  esac
}

# discover_workload_in_cluster [NAMESPACE]
#   클러스터에서 라벨이 일치하는 지원 workload를 1개로 결정한다.
#   출력 형식: "<namespace>|<name>|<kind>|<apiVersion>". 0개 or 2개+ 이면 die.
discover_workload_in_cluster() {
  local ns="${1:-}"
  local resources=(deployment statefulset daemonset job cronjob workflow.argoproj.io pytorchjob.kubeflow.org tfjob.kubeflow.org mpijob.kubeflow.org)
  local out="" resource chunk
  for resource in "${resources[@]}"; do
    if [[ -n "${ns}" ]]; then
      chunk="$(kubectl get "${resource}" -n "${ns}" -l "${RUNTIME_LABEL_SELECTOR}" -o json 2>/dev/null | python3 -c '
import json, sys
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
for it in d.get("items", []):
    print("{}|{}|{}|{}".format((it.get("metadata") or {}).get("namespace",""), (it.get("metadata") or {}).get("name",""), it.get("kind",""), it.get("apiVersion","")))
' || true)"
    else
      chunk="$(kubectl get "${resource}" -A -l "${RUNTIME_LABEL_SELECTOR}" -o json 2>/dev/null | python3 -c '
import json, sys
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
for it in d.get("items", []):
    print("{}|{}|{}|{}".format((it.get("metadata") or {}).get("namespace",""), (it.get("metadata") or {}).get("name",""), it.get("kind",""), it.get("apiVersion","")))
' || true)"
    fi
    [[ -n "${chunk}" ]] && out+="${chunk}"$'\n'
  done
  out="$(printf '%s\n' "${out}" | sed '/^$/d')"
  local count
  count="$(printf '%s\n' "${out}" | sed '/^$/d' | wc -l | tr -d ' ')"
  case "${count}" in
    0) die_missing "WORKLOAD_NAME" "클러스터에 라벨 ${RUNTIME_LABEL_SELECTOR} 인 지원 workload가 없습니다." ;;
    1) printf '%s\n' "${out}" ;;
    *) die "WORKLOAD 후보가 ${count}개입니다. 인자로 워크로드 이름을 지정하세요. 후보=
${out}" ;;
  esac
}

# resolve_workload_by_name NAME [NAMESPACE]
#   주어진 이름의 지원 workload를 1개 namespace로 한정한다. NAMESPACE가 비면 모든 ns 검색.
#   출력: "<namespace>|<name>|<kind>|<apiVersion>". 실패 시 die.
resolve_workload_by_name() {
  local name="${1:?workload name required}" ns="${2:-}"
  local resources=(deployment statefulset daemonset job cronjob workflow.argoproj.io pytorchjob.kubeflow.org tfjob.kubeflow.org mpijob.kubeflow.org)
  local out="" resource chunk
  for resource in "${resources[@]}"; do
    if [[ -n "${ns}" ]]; then
      chunk="$(kubectl get "${resource}" -n "${ns}" -o json 2>/dev/null | python3 -c '
import json, sys
name=sys.argv[1]
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
for it in d.get("items", []):
    md=it.get("metadata") or {}
    if md.get("name") == name:
        print("{}|{}|{}|{}".format(md.get("namespace",""), md.get("name",""), it.get("kind",""), it.get("apiVersion","")))
' "${name}" || true)"
    else
      chunk="$(kubectl get "${resource}" -A -o json 2>/dev/null | python3 -c '
import json, sys
name=sys.argv[1]
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
for it in d.get("items", []):
    md=it.get("metadata") or {}
    if md.get("name") == name:
        print("{}|{}|{}|{}".format(md.get("namespace",""), md.get("name",""), it.get("kind",""), it.get("apiVersion","")))
' "${name}" || true)"
    fi
    [[ -n "${chunk}" ]] && out+="${chunk}"$'\n'
  done
  out="$(printf '%s\n' "${out}" | sed '/^$/d')"
  local count
  count="$(printf '%s\n' "${out}" | sed '/^$/d' | wc -l | tr -d ' ')"
  case "${count}" in
    0) die_missing "WORKLOAD_NAME='${name}'" "해당 이름의 지원 workload가 클러스터에 없습니다." ;;
    1) printf '%s\n' "${out}" ;;
    *) die "이름 '${name}' 후보가 여러 namespace에 ${count}개입니다. namespace를 두 번째 인자로 지정하세요." ;;
  esac
}

# resolve_pod_by_name NAME [NAMESPACE]
#   Pod 이름을 namespace까지 단일 후보로 해석한다.
#   출력: "<namespace>|<podName>". 실패 시 빈 값.
resolve_pod_by_name() {
  local name="${1:?pod name required}" ns="${2:-}" out count
  if [[ -n "${ns}" ]]; then
    out="$(kubectl get pod "${name}" -n "${ns}" -o jsonpath='{.metadata.namespace}|{.metadata.name}' 2>/dev/null || true)"
  else
    out="$(kubectl get pod -A -o json 2>/dev/null | python3 -c '
import json, sys
name=sys.argv[1]
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
for it in d.get("items", []):
    md=it.get("metadata") or {}
    if md.get("name") == name:
        print("{}|{}".format(md.get("namespace",""), md.get("name","")))
' "${name}" || true)"
  fi
  out="$(printf '%s\n' "${out}" | sed '/^$/d')"
  count="$(printf '%s\n' "${out}" | sed '/^$/d' | wc -l | tr -d ' ')"
  [[ "${count}" -eq 1 ]] && printf '%s\n' "${out}"
}

# resolve_workload_from_pod POD_NAME [NAMESPACE]
#   Pod ownerReferences/labels를 사용해 상위 workload를 추론한다.
#   출력: "<namespace>|<name>|<kind>|<apiVersion>|<podName>|<selector>".
resolve_workload_from_pod() {
  local pod_name="${1:?pod name required}" ns="${2:-}" pod_ref pod_ns pod_json inferred
  pod_ref="$(resolve_pod_by_name "${pod_name}" "${ns}" 2>/dev/null || true)"
  [[ -n "${pod_ref}" ]] || return 1
  pod_ns="${pod_ref%%|*}"
  pod_name="${pod_ref#*|}"
  pod_json="$(kubectl get pod "${pod_name}" -n "${pod_ns}" -o json 2>/dev/null || true)"
  [[ -n "${pod_json}" ]] || return 1
  inferred="$(printf '%s' "${pod_json}" | python3 -c '
import json, sys
try:
    pod=json.load(sys.stdin)
except Exception:
    sys.exit(1)
md=pod.get("metadata") or {}
labels=md.get("labels") or {}
refs=md.get("ownerReferences") or []
ns=md.get("namespace","")
pod_name=md.get("name","")
for ref in refs:
    k=ref.get("kind","")
    n=ref.get("name","")
    api=ref.get("apiVersion","")
    if k in ("Deployment","StatefulSet","DaemonSet","Job","CronJob","Workflow","PyTorchJob","TFJob","MPIJob"):
        print("|".join([ns,n,k,api,pod_name,""]))
        sys.exit(0)
    if k == "ReplicaSet":
        print("|".join([ns,n,k,api,pod_name,""]))
        sys.exit(0)
for label_key, kind, api in (
    ("workflows.argoproj.io/workflow", "Workflow", "argoproj.io/v1alpha1"),
    ("training.kubeflow.org/job-name", "PyTorchJob", "kubeflow.org/v1"),
    ("kubeflow.org/job-name", "PyTorchJob", "kubeflow.org/v1"),
):
    if labels.get(label_key):
        print("|".join([ns,labels[label_key],kind,api,pod_name,f"{label_key}={labels[label_key]}"]))
        sys.exit(0)
print("|".join([ns,pod_name,"Pod","v1",pod_name,"metadata.name="+pod_name]))
')" || return 1
  local owner_ns owner_name owner_kind owner_api source_pod selector resource_type owner_json deployment_name cronjob_name actual
  IFS='|' read -r owner_ns owner_name owner_kind owner_api source_pod selector <<<"${inferred}"
  if [[ "${owner_kind}" == "ReplicaSet" ]]; then
    owner_json="$(kubectl get replicaset "${owner_name}" -n "${owner_ns}" -o json 2>/dev/null || true)"
    deployment_name="$(printf '%s' "${owner_json}" | python3 -c '
import json, sys
try:
    rs=json.load(sys.stdin)
except Exception:
    sys.exit(0)
for ref in (rs.get("metadata") or {}).get("ownerReferences") or []:
    if ref.get("kind") == "Deployment":
        print(ref.get("name",""))
        sys.exit(0)
' || true)"
    if [[ -n "${deployment_name}" ]]; then
      owner_name="${deployment_name}"; owner_kind="Deployment"; owner_api="apps/v1"
    fi
  elif [[ "${owner_kind}" == "Job" ]]; then
    job_owner="$(kubectl get job "${owner_name}" -n "${owner_ns}" -o json 2>/dev/null | python3 -c '
import json, sys
try:
    job=json.load(sys.stdin)
except Exception:
    sys.exit(0)
for ref in (job.get("metadata") or {}).get("ownerReferences") or []:
    if ref.get("kind") in ("CronJob","Workflow","PyTorchJob","TFJob","MPIJob"):
        print("|".join([ref.get("name",""), ref.get("kind",""), ref.get("apiVersion","")]))
        sys.exit(0)
' || true)"
    if [[ -n "${job_owner}" ]]; then
      IFS='|' read -r owner_name owner_kind owner_api <<<"${job_owner}"
    fi
  fi
  resource_type="$(kind_to_kubectl_resource "${owner_kind}" "${owner_api}" 2>/dev/null || true)"
  if [[ -n "${resource_type}" && "${owner_kind}" != "Pod" ]]; then
    actual="$(kubectl get "${resource_type}" "${owner_name}" -n "${owner_ns}" -o jsonpath='{.metadata.name}' 2>/dev/null || true)"
    if [[ -z "${actual}" && "${owner_kind}" =~ ^(PyTorchJob|TFJob|MPIJob)$ ]]; then
      # Kubeflow 계열 kind는 Pod label만 있고 CRD 조회가 안 될 수 있으므로 Pod 자체를 관측 대상으로 유지한다.
      owner_name="${source_pod}"; owner_kind="Pod"; owner_api="v1"; resource_type="pod"; selector="metadata.name=${source_pod}"
    fi
  fi
  printf '%s|%s|%s|%s|%s|%s\n' "${owner_ns}" "${owner_name}" "${owner_kind}" "${owner_api}" "${source_pod}" "${selector}"
}

# resolve_workload_or_pod_by_name NAME [NAMESPACE]
#   workload 이름을 먼저 찾고, 없으면 Pod 이름으로 찾아 owner workload 또는 Pod 자체를 반환한다.
#   출력: "<namespace>|<name>|<kind>|<apiVersion>|<podName>|<selector>".
resolve_workload_or_pod_by_name() {
  local name="${1:?name required}" ns="${2:-}" match pod_match
  set +e
  match="$(RUNTIME_SUPPRESS_DIE_SCREEN=1 resolve_workload_by_name "${name}" "${ns}" 2>/dev/null)"
  local match_rc=$?
  set -e
  if [[ -n "${match}" ]]; then
    printf '%s||\n' "${match}"
    return 0
  fi
  set +e
  pod_match="$(resolve_workload_from_pod "${name}" "${ns}" 2>/dev/null)"
  local pod_rc=$?
  set -e
  [[ -n "${pod_match}" ]] && { printf '%s\n' "${pod_match}"; return 0; }
  return 1
}

# get_selector_for_workload NAMESPACE NAME [KIND] [API_VERSION]
#   kind별 Pod selector 후보를 한 줄로 출력한다. 클러스터 조회 실패 시 빈 값을 반환한다.
get_selector_for_workload() {
  local ns="${1:?namespace required}" name="${2:?name required}" kind="${3:-Deployment}" api="${4:-apps/v1}"
  require_python3
  local resource_type
  resource_type="$(kind_to_kubectl_resource "${kind}" "${api}" 2>/dev/null || true)"
  [[ -n "${resource_type}" ]] || return 0
  case "${kind}" in
    Pod)
      echo "metadata.name=${name}"
      return 0
      ;;
    Job)
      if kubectl get pod -n "${ns}" -l "job-name=${name}" -o name >/dev/null 2>&1; then
        echo "job-name=${name}"
        return 0
      fi
      ;;
    CronJob)
      local job_name
      job_name="$(kubectl get job -n "${ns}" -o json 2>/dev/null | python3 -c '
import json, sys
name=sys.argv[1]
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
for it in d.get("items", []):
    for ref in (it.get("metadata") or {}).get("ownerReferences") or []:
        if ref.get("kind") == "CronJob" and ref.get("name") == name:
            print((it.get("metadata") or {}).get("name",""))
            sys.exit(0)
' "${name}" || true)"
      [[ -n "${job_name}" ]] && echo "job-name=${job_name}"
      return 0
      ;;
    Workflow)
      echo "workflows.argoproj.io/workflow=${name}"
      return 0
      ;;
    PyTorchJob|TFJob|MPIJob)
      local sel
      for sel in "training.kubeflow.org/job-name=${name}" "kubeflow.org/job-name=${name}" "job-name=${name}"; do
        if kubectl get pod -n "${ns}" -l "${sel}" -o name >/dev/null 2>&1; then
          echo "${sel}"
          return 0
        fi
      done
      echo "training.kubeflow.org/job-name=${name}"
      return 0
      ;;
  esac
  kubectl get "${resource_type}" -n "${ns}" "${name}" -o json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    ml = ((d.get("spec") or {}).get("selector") or {}).get("matchLabels") or {}
    if not ml:
        sys.exit(1)
    for k in ("app", "app.kubernetes.io/name"):
        if k in ml:
            print("{}={}".format(k, ml[k]))
            sys.exit(0)
    k = next(iter(ml))
    print("{}={}".format(k, ml[k]))
except Exception:
    sys.exit(1)
' 2>/dev/null || true
}

# get_pods_for_workload NAMESPACE KIND NAME [API_VERSION]
#   selector 우선, 실패 시 ownerReferences 기반으로 Pod 이름을 출력한다.
get_pods_for_workload() {
  local ns="${1:?namespace required}" kind="${2:?kind required}" name="${3:?name required}" api="${4:-}"
  local selector
  if [[ "${kind}" == "Pod" ]]; then
    kubectl get pod "${name}" -n "${ns}" -o jsonpath='{.metadata.name}{"\n"}' 2>/dev/null || true
    return 0
  fi
  selector="$(get_selector_for_workload "${ns}" "${name}" "${kind}" "${api}" 2>/dev/null || true)"
  if [[ -n "${selector}" ]]; then
    local pods
    pods="$(kubectl get pod -n "${ns}" -l "${selector}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | sed '/^$/d' || true)"
    if [[ -n "${pods}" ]]; then
      printf '%s\n' "${pods}"
      return 0
    fi
  fi
  kubectl get pod -n "${ns}" -o json 2>/dev/null | python3 -c '
import json, sys
kind, name = sys.argv[1:3]
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
for pod in d.get("items", []):
    md=pod.get("metadata") or {}
    refs=md.get("ownerReferences") or []
    labels=md.get("labels") or {}
    if any(r.get("kind")==kind and r.get("name")==name for r in refs):
        print(md.get("name",""))
    elif kind == "Workflow" and labels.get("workflows.argoproj.io/workflow") == name:
        print(md.get("name",""))
    elif kind in ("PyTorchJob","TFJob","MPIJob") and name in (labels.get("training.kubeflow.org/job-name"), labels.get("kubeflow.org/job-name")):
        print(md.get("name",""))
' "${kind}" "${name}" | sed '/^$/d' || true
}

get_first_pod_for_workload() {
  get_pods_for_workload "$@" | head -1
}

# get_pvc_names_for_workload NAMESPACE KIND NAME [API_VERSION]
#   workload template에서 참조하는 PVC 이름을 콤마 구분으로 출력한다.
get_pvc_names_for_workload() {
  local ns="${1:?namespace required}" kind="${2:?kind required}" name="${3:?name required}" api="${4:-}"
  local resource_type
  resource_type="$(kind_to_kubectl_resource "${kind}" "${api}" 2>/dev/null || true)"
  [[ -n "${resource_type}" ]] || return 0
  kubectl get "${resource_type}" -n "${ns}" "${name}" -o json 2>/dev/null | python3 -c '
import json, sys
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
def walk(x):
    if isinstance(x, dict):
        pvc=x.get("persistentVolumeClaim")
        if isinstance(pvc, dict) and pvc.get("claimName"):
            yield pvc.get("claimName")
        for v in x.values():
            yield from walk(v)
    elif isinstance(x, list):
        for v in x:
            yield from walk(v)
seen=[]
for c in walk(d.get("spec") or {}):
    if c not in seen:
        seen.append(c)
print(",".join(seen))
' || true
}

wait_for_workload_pods() {
  local ns="${1:?namespace required}" kind="${2:?kind required}" name="${3:?name required}" api="${4:-}" timeout="${5:-${DEMO_WAIT_TIMEOUT_SECONDS:-300}}"
  local elapsed=0 pods
  while (( elapsed < timeout )); do
    pods="$(get_pods_for_workload "${ns}" "${kind}" "${name}" "${api}" | paste -sd' ' -)"
    [[ -n "${pods}" ]] && { printf '%s\n' "${pods}"; return 0; }
    sleep 3
    elapsed=$((elapsed + 3))
  done
  return 1
}

# wait_for_workload_status NAMESPACE KIND NAME [API_VERSION] [TIMEOUT]
#   kind별 완료/준비 상태를 확인한다. 조회 불가 리소스는 WARN을 남기고 Pod 상태 관측으로 fallback한다.
wait_for_workload_status() {
  local ns="${1:?namespace required}" kind="${2:?kind required}" name="${3:?name required}" api="${4:-}" timeout="${5:-${DEMO_WAIT_TIMEOUT_SECONDS:-300}}"
  local resource_type phase
  resource_type="$(kind_to_kubectl_resource "${kind}" "${api}" 2>/dev/null || true)"
  [[ -n "${resource_type}" ]] || { echo "WARN workload_status unsupported kind=${kind} apiVersion=${api}"; return 0; }
  case "${kind}" in
    Deployment|StatefulSet|DaemonSet)
      kubectl rollout status "${resource_type}/${name}" -n "${ns}" --timeout="${timeout}s" 2>/dev/null || echo "WARN workload_rollout_status_failed resource=${resource_type}/${name} namespace=${ns}"
      ;;
    Job)
      if ! kubectl wait --for=condition=complete "job/${name}" -n "${ns}" --timeout="${timeout}s" 2>/dev/null; then
        phase="$(kubectl get job "${name}" -n "${ns}" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || true)"
        echo "WARN job_complete_wait_failed name=${name} failed_condition=${phase:-<none>}"
      fi
      ;;
    Workflow)
      phase="$(kubectl get "${resource_type}" "${name}" -n "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
      case "${phase}" in
        Succeeded|Failed|Error) echo "workflow_phase=${phase}" ;;
        "") echo "WARN workflow_status_unavailable name=${name} namespace=${ns}" ;;
        *) echo "workflow_phase=${phase}" ;;
      esac
      ;;
    PyTorchJob|TFJob|MPIJob)
      phase="$(kubectl get "${resource_type}" "${name}" -n "${ns}" -o jsonpath='{range .status.conditions[*]}{.type}={.status}{" "}{end}' 2>/dev/null || true)"
      [[ -n "${phase}" ]] && echo "training_job_conditions=${phase}" || echo "WARN training_job_status_unavailable kind=${kind} name=${name} namespace=${ns}"
      ;;
    CronJob)
      echo "cronjob_status=SKIP reason=CronJob creates Jobs on schedule"
      ;;
    *)
      echo "WARN workload_status_unknown kind=${kind}"
      ;;
  esac
  local pods
  pods="$(get_pods_for_workload "${ns}" "${kind}" "${name}" "${api}" | paste -sd' ' -)"
  echo "pod_names=${pods:-<none>}"
}

# state_require SCENARIO KEY -> state file에서 키 값을 echo. 없으면 die.
# WHY: bash 4+의 ${!var} 간접 참조를 사용해 eval 호출 없이 변수명으로 값을 얻는다.
state_require() {
  local scenario="${1:?scenario}" key="${2:?key}"
  state_load "${scenario}" || die_missing "${key}" "${scenario}의 runtime state 파일($(state_file_path "${scenario}"))이 없습니다. 먼저 01번 스크립트를 실행하세요."
  local val="${!key:-}"
  [[ -n "${val}" ]] || die_missing "${key}" "${scenario} state에 ${key} 값이 비어 있습니다. 앞 단계가 그 값을 채우도록 먼저 실행하세요."
  printf '%s' "${val}"
}

# state_get_or_empty SCENARIO KEY -> 키 없거나 빈 값이면 빈 문자열을 반환(에러 X).
state_get_or_empty() {
  local scenario="${1:?scenario}" key="${2:?key}"
  state_load "${scenario}" 2>/dev/null || return 0
  local val="${!key:-}"
  printf '%s' "${val}"
}

# parse_kv_str KEY KVSTRING
#   "k1=v1;k2=v2;..." 같은 문자열에서 특정 key의 value를 꺼낸다.
parse_kv_str() {
  local key="${1:?key}" str="${2:-}"
  # WHY: 매치가 없을 때 비-0 종료로 호출자의 set -e를 깨트리지 않도록 || true로 흡수한다.
  printf '%s\n' "${str}" | tr ';' '\n' | grep -aE "^${key}=" | head -1 | sed -E "s/^${key}=//" || true
}

# ─────────────────────────────────────────────────────────────
# Forecaster API 기반 정책 추천 직접 조회 (fallback 경로).
# orchestration-policy-engine은 내부적으로 forecaster의 /api/v1/policy/recommendations/<node>
# 를 호출하고, 그 결과를 자체 로그에 "recommendations dump ... json=..." 로 남긴다
# (apollo/orchestration-policy-engine/internal/forecaster/client.go logPolicyRecommendationsDump).
# 본 헬퍼는 같은 endpoint를 시연 스크립트에서 직접 호출해 추천을 fallback으로 얻는다.
# ─────────────────────────────────────────────────────────────

# port_forward_forecaster_open
#   forecaster Service에 port-forward를 백그라운드로 띄우고 PORT를 echo한다.
#   PF_PID는 호출자에서 받아 종료 시 kill해야 한다(runtime_add_exit_hook 권장).
#   실패하면 빈 문자열을 echo. 호출자가 처리한다.
port_forward_forecaster_open() {
  local ns="${1:?forecaster namespace required}"
  command -v kubectl >/dev/null 2>&1 || return 1
  local port
  for port in 18080 18081 18082 18180 18280; do
    kubectl port-forward -n "${ns}" svc/node-resource-forecaster "${port}":8080 >/dev/null 2>&1 &
    local pid=$!
    sleep 2
    if kill -0 "${pid}" 2>/dev/null; then
      printf 'PORT=%s\nPID=%s\n' "${port}" "${pid}"
      return 0
    fi
  done
  return 1
}

# fetch_recommendations_from_forecaster NAMESPACE NODE OUT_FILE
#   forecaster의 /api/v1/policy/recommendations/<node>를 호출해 OUT_FILE에 저장한다.
#   반환: 0=성공, 1=실패.
fetch_recommendations_from_forecaster() {
  local ns="${1:?ns}" node="${2:?node}" out_file="${3:?out_file}"
  command -v curl >/dev/null 2>&1 || return 1
  local pfinfo
  pfinfo="$(port_forward_forecaster_open "${ns}" 2>/dev/null || true)"
  local port pid
  port="$(grep -aE '^PORT=' <<<"${pfinfo}" | head -1 | sed 's/^PORT=//')"
  pid="$(grep -aE '^PID=' <<<"${pfinfo}" | head -1 | sed 's/^PID=//')"
  [[ -n "${port}" && -n "${pid}" ]] || return 1
  local http_code
  http_code="$(curl -sS --max-time 8 -o "${out_file}" \
    -w '%{http_code}' \
    "http://127.0.0.1:${port}/api/v1/policy/recommendations/${node}" 2>/dev/null || echo "000")"
  kill "${pid}" 2>/dev/null || true
  wait "${pid}" 2>/dev/null || true
  if [[ "${http_code}" == "200" && -s "${out_file}" ]]; then
    return 0
  fi
  return 1
}

# parse_recommendations_json IN_FILE
#   PolicyRecommendation 배열 JSON에서 핵심 요약값을 KEY=VAL 한 줄 단위로 출력한다.
#   매개변수의 JSON 형식은 forecaster types.go의 PolicyRecommendation 정의를 따른다.
#   출력 키:
#     REC_COUNT, REC_NODE, REC_PRIMARY_POLICY, REC_PRIMARY_RESOURCE,
#     REC_PRIMARY_HORIZON, REC_PRIMARY_REASON, REC_PRIMARY_PROB, REC_PRIMARY_URGENCY
#     REC_ROW|<horizon>|<resource>|<policy>|<prob>|<predicted>|<threshold>|<reason>
parse_recommendations_json() {
  local in_file="${1:?in_file}"
  require_python3
  python3 - "${in_file}" <<'PYEOF'
import json, sys
path = sys.argv[1]
try:
    with open(path, 'r', encoding='utf-8') as fh:
        data = json.load(fh)
except Exception as e:
    sys.stderr.write("PARSE_ERR=" + str(e)[:200])
    sys.exit(1)
if isinstance(data, dict):
    items = [data]
elif isinstance(data, list):
    items = data
else:
    items = []
def pct(v):
    try: return "{:.1f}%".format(float(v) * 100)
    except Exception: return ""
print("REC_COUNT={}".format(len(items)))
if not items:
    sys.exit(0)
node = items[0].get("node_name", "")
print("REC_NODE={}".format(node))
# Primary = highest probability(또는 urgency 기준)
def score(r):
    u = (r.get("urgency") or "").upper()
    rank = {"CRITICAL": 3, "HIGH": 2, "MEDIUM": 1, "LOW": 0}.get(u, 0)
    try: p = int(r.get("probability") or 0)
    except Exception: p = 0
    return (rank, p)
primary = sorted(items, key=score, reverse=True)[0]
print("REC_PRIMARY_POLICY={}".format(primary.get("policy_type", "")))
print("REC_PRIMARY_RESOURCE={}".format(primary.get("resource_type", "")))
print("REC_PRIMARY_HORIZON={}".format(primary.get("horizon_minutes", "")))
print("REC_PRIMARY_REASON={}".format(str(primary.get("reason", "")).replace('\n', ' ').strip()))
print("REC_PRIMARY_PROB={}".format(primary.get("probability", "")))
print("REC_PRIMARY_URGENCY={}".format(primary.get("urgency", "")))
for r in items:
    row = "REC_ROW|{}|{}|{}|{}|{}|{}|{}".format(
        r.get("horizon_minutes", ""),
        r.get("resource_type", ""),
        r.get("policy_type", ""),
        r.get("probability", ""),
        pct(r.get("predicted_utilization", "")),
        pct(r.get("threshold", "")),
        str(r.get("reason", "")).replace('|', '/').replace('\n', ' ').strip()
    )
    print(row)
PYEOF
}

# extract_recommendations_from_engine_log POLICY_ENGINE_NAMESPACE OUT_FILE
#   policy-engine 로그에서 "recommendations dump ... json=..." 라인의 JSON을 추출해 OUT_FILE에 저장.
#   여러 라인이 있으면 가장 최근(workload_node가 있다면 매칭) 한 줄을 선택.
#   매개변수:
#     ns: policy-engine deploy의 namespace
#     out_file: JSON 저장 경로
#     workload_node (optional): 지정 시 우선 매칭
#   반환: 0=성공, 1=실패.
extract_recommendations_from_engine_log() {
  local ns="${1:?ns}" out_file="${2:?out_file}" wl_node="${3:-}"
  command -v kubectl >/dev/null 2>&1 || return 1
  local logs lines pick
  logs="$(kubectl logs -n "${ns}" deploy/orchestration-policy-engine --tail=5000 2>/dev/null || true)"
  # WHY: forecaster client.go logPolicyRecommendationsDump이 남기는 키워드는 'recommendations dump' (복수형).
  lines="$(printf '%s\n' "${logs}" | grep -aE 'recommendations dump' || true)"
  [[ -n "${lines}" ]] || return 1
  local pick=""
  if [[ -n "${wl_node}" ]]; then
    pick="$(printf '%s\n' "${lines}" | grep -aE "node=${wl_node}( |\$)" | tail -1 || true)"
  fi
  [[ -z "${pick}" ]] && pick="$(printf '%s\n' "${lines}" | tail -1)"
  # json= 이후를 JSON으로 본다.
  local json
  json="$(printf '%s' "${pick}" | sed -E 's/.*json=//')"
  [[ -n "${json}" ]] || return 1
  printf '%s' "${json}" > "${out_file}"
  return 0
}

# load_workload_context [ARG_WORKLOAD] [ARG_NAMESPACE]
#   scenario2 측에서 사용하는 단일 컨텍스트 해결기.
#   우선순위:
#     (1) 인자(ARG_WORKLOAD/ARG_NAMESPACE)가 둘 다 비어있지 않으면 그것을 그대로 사용한다.
#         (단, ARG_WORKLOAD가 manifest 경로/단일 이름 어느 쪽이든 resolve_workload_by_name로 매핑한다)
#     (2) .runtime/scenario1.env 의 NAMESPACE / WORKLOAD_NAME / APP_LABEL_KEY / APP_LABEL_VALUE / POD_SELECTOR / SELECTED_NODE
#         이 단일 진실 원천(SSoT)이다.
#     (3) 어떤 값도 없으면 그대로 빈 채로 둔다. 절대로 임의 기본값(my-workload-x, default 등)을 만들지 않는다.
#
#   출력은 호출자 환경의 다음 변수에 채워 넣는다:
#     CTX_WORKLOAD_NAME, CTX_NAMESPACE, CTX_APP_LABEL_KEY, CTX_APP_LABEL_VALUE,
#     CTX_POD_SELECTOR, CTX_SELECTED_NODE, CTX_SOURCE (=argument|scenario1_env|unresolved),
#     CTX_MISSING (해결되지 않은 키 목록)
load_workload_context() {
  local arg_wl="${1:-}" arg_ns="${2:-}"
  CTX_WORKLOAD_NAME=""; CTX_NAMESPACE=""
  CTX_WORKLOAD_KIND=""; CTX_API_VERSION=""; CTX_RESOURCE_TYPE=""; CTX_RESOURCE_REF=""
  CTX_APP_LABEL_KEY=""; CTX_APP_LABEL_VALUE=""
  CTX_POD_SELECTOR=""; CTX_SELECTED_NODE=""
  CTX_SOURCE="unresolved"
  CTX_MISSING=""

  # (1) 인자 우선.
  if [[ -n "${arg_wl}" ]]; then
    local match=""
    match="$(resolve_workload_by_name "${arg_wl}" "${arg_ns}" 2>/dev/null)" || match=""
    if [[ -n "${match}" && "${match}" == *"|"* ]]; then
      IFS='|' read -r CTX_NAMESPACE CTX_WORKLOAD_NAME CTX_WORKLOAD_KIND CTX_API_VERSION <<<"${match}"
      CTX_RESOURCE_TYPE="$(kind_to_kubectl_resource "${CTX_WORKLOAD_KIND}" "${CTX_API_VERSION}" 2>/dev/null || true)"
      [[ -n "${CTX_RESOURCE_TYPE}" && -n "${CTX_WORKLOAD_NAME}" ]] && CTX_RESOURCE_REF="${CTX_RESOURCE_TYPE}/${CTX_WORKLOAD_NAME}"
      CTX_SOURCE="argument"
    fi
  fi

  # (2) scenario1.env SSoT.
  if [[ -z "${CTX_WORKLOAD_NAME}" || -z "${CTX_NAMESPACE}" ]]; then
    local f
    f="$(state_file_path scenario1)"
    if [[ -f "${f}" ]]; then
      # subshell에서 source해 호출자 변수 오염을 막고 필요한 키만 가져온다.
      local s1_wl s1_ns s1_kind s1_api s1_res_type s1_res_ref s1_key s1_val s1_sel s1_node
      s1_wl="$(   bash -c "set -a; source '${f}' 2>/dev/null; printf '%s' \"\${WORKLOAD_NAME:-}\"")"
      s1_ns="$(   bash -c "set -a; source '${f}' 2>/dev/null; printf '%s' \"\${NAMESPACE:-}\"")"
      s1_kind="$( bash -c "set -a; source '${f}' 2>/dev/null; printf '%s' \"\${WORKLOAD_KIND:-}\"")"
      s1_api="$(  bash -c "set -a; source '${f}' 2>/dev/null; printf '%s' \"\${API_VERSION:-}\"")"
      s1_res_type="$(bash -c "set -a; source '${f}' 2>/dev/null; printf '%s' \"\${RESOURCE_TYPE:-}\"")"
      s1_res_ref="$( bash -c "set -a; source '${f}' 2>/dev/null; printf '%s' \"\${RESOURCE_REF:-}\"")"
      s1_key="$(  bash -c "set -a; source '${f}' 2>/dev/null; printf '%s' \"\${APP_LABEL_KEY:-}\"")"
      s1_val="$(  bash -c "set -a; source '${f}' 2>/dev/null; printf '%s' \"\${APP_LABEL_VALUE:-}\"")"
      s1_sel="$(  bash -c "set -a; source '${f}' 2>/dev/null; printf '%s' \"\${POD_SELECTOR:-}\"")"
      s1_node="$( bash -c "set -a; source '${f}' 2>/dev/null; printf '%s' \"\${SELECTED_NODE:-}\"")"
      [[ -z "${CTX_WORKLOAD_NAME}" ]] && CTX_WORKLOAD_NAME="${s1_wl}"
      [[ -z "${CTX_NAMESPACE}" ]]     && CTX_NAMESPACE="${s1_ns}"
      [[ -z "${CTX_WORKLOAD_KIND}" ]] && CTX_WORKLOAD_KIND="${s1_kind}"
      [[ -z "${CTX_API_VERSION}" ]] && CTX_API_VERSION="${s1_api}"
      [[ -z "${CTX_RESOURCE_TYPE}" ]] && CTX_RESOURCE_TYPE="${s1_res_type}"
      [[ -z "${CTX_RESOURCE_REF}" ]] && CTX_RESOURCE_REF="${s1_res_ref}"
      CTX_APP_LABEL_KEY="${s1_key}"
      CTX_APP_LABEL_VALUE="${s1_val}"
      CTX_POD_SELECTOR="${s1_sel}"
      CTX_SELECTED_NODE="${s1_node}"
      [[ "${CTX_SOURCE}" == "unresolved" && -n "${s1_wl}" ]] && CTX_SOURCE="scenario1_env"
    fi
  fi

  # POD_SELECTOR/APP_LABEL이 비어있을 때만 클러스터에서 보조 조회.
  if [[ -z "${CTX_POD_SELECTOR}" && -n "${CTX_NAMESPACE}" && -n "${CTX_WORKLOAD_NAME}" ]]; then
    local pair=""
    pair="$(get_selector_for_workload "${CTX_NAMESPACE}" "${CTX_WORKLOAD_NAME}" "${CTX_WORKLOAD_KIND:-Deployment}" "${CTX_API_VERSION:-apps/v1}" 2>/dev/null)" || pair=""
    if [[ -n "${pair}" && "${pair}" == *"="* ]]; then
      CTX_APP_LABEL_KEY="${pair%%=*}"
      CTX_APP_LABEL_VALUE="${pair#*=}"
      CTX_POD_SELECTOR="${pair}"
    fi
  fi

  # SELECTED_NODE도 SSoT에 없으면 실시간 보조 조회.
  if [[ -z "${CTX_SELECTED_NODE}" && -n "${CTX_NAMESPACE}" && -n "${CTX_POD_SELECTOR}" ]]; then
    local node=""
    node="$(jp get pod -n "${CTX_NAMESPACE}" -l "${CTX_POD_SELECTOR}" -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null)" || node=""
    if [[ -z "${node}" && -n "${CTX_WORKLOAD_KIND}" && -n "${CTX_WORKLOAD_NAME}" ]]; then
      local first_pod
      first_pod="$(get_first_pod_for_workload "${CTX_NAMESPACE}" "${CTX_WORKLOAD_KIND}" "${CTX_WORKLOAD_NAME}" "${CTX_API_VERSION}" 2>/dev/null || true)"
      [[ -n "${first_pod}" ]] && node="$(jp get pod "${first_pod}" -n "${CTX_NAMESPACE}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
    fi
    CTX_SELECTED_NODE="${node}"
  fi

  # missing key 목록.
  local missing=""
  [[ -z "${CTX_WORKLOAD_NAME}"  ]] && missing+="WORKLOAD_NAME,"
  [[ -z "${CTX_NAMESPACE}"      ]] && missing+="NAMESPACE,"
  [[ -z "${CTX_POD_SELECTOR}"   ]] && missing+="POD_SELECTOR,"
  [[ -z "${CTX_SELECTED_NODE}"  ]] && missing+="SELECTED_NODE,"
  CTX_MISSING="${missing%,}"
}

# print_workload_context 은 load_workload_context 호출 후 결과를 표준 key=value로 출력한다.
print_workload_context() {
  echo "workload_name=${CTX_WORKLOAD_NAME:-<none>}"
  echo "workload_kind=${CTX_WORKLOAD_KIND:-<none>}"
  echo "workload_api_version=${CTX_API_VERSION:-<none>}"
  echo "workload_resource_type=${CTX_RESOURCE_TYPE:-<none>}"
  echo "workload_namespace=${CTX_NAMESPACE:-<none>}"
  echo "workload_pod_selector=${CTX_POD_SELECTOR:-<none>}"
  echo "workload_selected_node=${CTX_SELECTED_NODE:-<none>}"
  echo "workload_context_source=${CTX_SOURCE}"
  if [[ -n "${CTX_MISSING}" ]]; then
    echo "workload_context_missing_keys=${CTX_MISSING}"
    echo "workload_context_missing_source=$(state_file_path scenario1)"
  fi
}

# now_iso_runtime은 ISO8601 timestamp를 echo한다. common.sh의 now_iso와 동등.
now_iso_runtime() { date -Iseconds; }
