#!/usr/bin/env bash
# common.sh는 시연 래퍼 스크립트(run-scenario1.sh / run-scenario2.sh / run-demo-all.sh)가
# 공유하는 출력·검증·시간측정 유틸리티를 제공한다.
#
# Author: 미정
# Created: 2026-05-21
# Related: year3-integration/4.integration_test/scripts/demo/run-scenario1.sh
#
# 사용 규칙:
# - 본 파일은 source 전용. 직접 실행하지 않는다.
# - 호출 측에서 `set -euo pipefail`을 다시 선언하지 않도록 여기서 설정한다.
# - 성공/실패 판정은 PASS_COUNT/FAIL_COUNT로 누적 후 summary_and_exit가 결정한다.
#   echo만으로 성공처럼 보이게 하지 않는다.

set -euo pipefail

# banner는 단계 구분용 큰 제목을 출력한다.
banner() {
  local title="${1:-}"
  echo
  echo "============================================================"
  echo "  ${title}"
  echo "============================================================"
}

# step은 한 단계 시작을 알린다.
step() {
  echo
  echo "[STEP] $*"
}

# run은 실제 실행 명령을 한 줄 echo 후 그대로 실행한다.
# 시연자가 어떤 명령이 돌고 있는지 알 수 있도록 한다.
run() {
  echo "+ $*"
  "$@"
}

# 검증 카운터.
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

pass() {
  echo "PASS ${1} ${2}"
  PASS_COUNT=$((PASS_COUNT + 1))
}

warn() {
  echo "WARN ${1} ${2}"
  WARN_COUNT=$((WARN_COUNT + 1))
}

fail() {
  echo "FAIL ${1} ${2}" >&2
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

# 색상은 터미널 출력에서만 켠다. NO_COLOR=1이면 항상 비활성화한다.
__demo_color_enabled() {
  [[ "${NO_COLOR:-}" != "1" ]] || return 1
  { [[ -t 3 ]] || [[ -t 1 ]]; } 2>/dev/null
}

__demo_c() {
  local code="${1:-}" text="${2:-}"
  if __demo_color_enabled; then
    printf '\033[%sm%s\033[0m' "${code}" "${text}"
  else
    printf '%s' "${text}"
  fi
}

color_success() { __demo_c "1;32" "$*"; }
color_warn() { __demo_c "1;33" "$*"; }
color_error() { __demo_c "1;31" "$*"; }
color_header() { __demo_c "1;36" "$*"; }
color_key() { __demo_c "36" "$*"; }
color_value() { __demo_c "1;37" "$*"; }
color_muted() { __demo_c "90" "$*"; }

__demo_out() {
  if declare -F screen >/dev/null 2>&1; then
    screen "$*"
  else
    echo "$*"
  fi
}

__demo_prefix_lines() {
  while IFS= read -r line; do
    __demo_out "│  ${line}"
  done
}

log_box_start() {
  local step="${1:---}" title="${2:-Demo Step}"
  __demo_out ""
  __demo_out "$(color_header "┌─ [${step}] ${title} ─────────────────────────────────────────")"
}

log_kv() {
  local key="${1:-}" value="${2:-}"
  __demo_out "│  $(color_key "$(printf '%-15s' "${key}")") : $(color_value "${value:-<none>}")"
}

log_kv_status() {
  local key="${1:-}" status="${2:-}" label
  case "${status}" in
    true|True|PASS|pass|OK|ok|healthy|Running|Succeeded|완료|확인됨|동작\ 중)
      label="$(color_success "✓ ${status}")" ;;
    false|False|FAIL|fail|Failed|Error|error|미확인|불일치)
      label="$(color_error "✗ ${status}")" ;;
    SKIP|skip|WARN|warn|WARNING|warning|"<none>"|"")
      label="$(color_warn "⚠ ${status:-<none>}")" ;;
    *)
      label="$(color_value "${status}")" ;;
  esac
  __demo_out "│  $(color_key "$(printf '%-15s' "${key}")") : ${label}"
}

log_evidence_title() {
  __demo_out "$(color_header "├─ evidence ───────────────────────────────────────────────────")"
}

log_cmd() {
  __demo_out "│  $(color_muted "$ $*")"
}

log_cmd_warn() {
  __demo_out "│  $(color_warn "⚠ $ $*")"
}

log_evidence_line() {
  __demo_out "│  $*"
}

log_box_result() {
  local result="${1:-PASS}" reason="${2:-}"
  local label
  case "${result}" in
    PASS) label="$(color_success "✓ PASS")" ;;
    WARN) label="$(color_warn "⚠ WARN")" ;;
    FAIL) label="$(color_error "✗ FAIL")" ;;
    SKIP) label="$(color_warn "⚠ SKIP")" ;;
    *) label="${result}" ;;
  esac
  [[ -n "${reason}" ]] && label="${label} $(color_muted "${reason}")"
  __demo_out "$(color_header "└─ result: ${label} ─────────────────────────────────────────────")"
}

print_ascii_table() {
  local data
  data="$(cat)"
  if command -v column >/dev/null 2>&1; then
    printf '%s\n' "${data}" | column -t | __demo_prefix_lines
  else
    printf '%s\n' "${data}" | __demo_prefix_lines
  fi
}

print_demo_summary() {
  local steps="${1:-}" workload="${2:-<none>}" kind="${3:-<none>}" ns="${4:-<none>}" node="${5:-<none>}" policy="${6:-<none>}" autoscaler="${7:-<not found>}" result="${8:-PASS}"
  local result_label
  case "${result}" in
    PASS) result_label="$(color_success "✓ PASS")" ;;
    WARN) result_label="$(color_warn "⚠ WARN")" ;;
    FAIL) result_label="$(color_error "✗ FAIL")" ;;
    *) result_label="${result}" ;;
  esac
  __demo_out ""
  __demo_out "$(color_header "╔══════════════════════════════════════════════════════════════╗")"
  __demo_out "$(color_header "║  DEMO SUMMARY                                                ║")"
  __demo_out "$(color_header "╠══════════════════════════════════════════════════════════════╣")"
  __demo_out "║  $(printf '%-12s' "Steps") : ${steps}"
  __demo_out "║  $(printf '%-12s' "Workload") : ${workload}"
  __demo_out "║  $(printf '%-12s' "Kind") : ${kind}"
  __demo_out "║  $(printf '%-12s' "Namespace") : ${ns}"
  __demo_out "║  $(printf '%-12s' "Node") : ${node}"
  __demo_out "║  $(printf '%-12s' "Policy") : ${policy}"
  __demo_out "║  $(printf '%-12s' "Autoscaler") : ${autoscaler}"
  __demo_out "║  $(printf '%-12s' "Result") : ${result_label}"
  __demo_out "$(color_header "╚══════════════════════════════════════════════════════════════╝")"
}

# summary_and_exit는 누적된 PASS/WARN/FAIL 카운트로 종합 판정한다.
# FAIL이 1건이라도 있으면 RESULT=FAIL + return 1, 그렇지 않으면 RESULT=PASS + return 0.
# 호출 측은 반환값을 받아 exit 코드를 결정한다.
summary_and_exit() {
  local title="${1:-Summary}"
  echo
  echo "============================================================"
  echo "  ${title}  PASS=${PASS_COUNT} WARN=${WARN_COUNT} FAIL=${FAIL_COUNT}"
  echo "============================================================"
  if [[ "${FAIL_COUNT}" -eq 0 ]]; then
    echo "RESULT=PASS"
    return 0
  fi
  echo "RESULT=FAIL"
  return 1
}

# require_cmd는 필수 외부 커맨드가 PATH에 있는지 검사한다.
require_cmd() {
  local missing=0
  local cmd
  for cmd in "$@"; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      echo "ERROR: required command not found in PATH: ${cmd}" >&2
      missing=1
    fi
  done
  if [[ "${missing}" -ne 0 ]]; then
    exit 1
  fi
}

# jp는 kubectl 조회 결과를 안전하게 가져오는 read-only 래퍼다.
# 조회 실패해도 빈 문자열을 반환해 후속 비교가 정상 동작하게 한다.
jp() {
  kubectl "$@" 2>/dev/null || true
}

# now_epoch / now_iso는 시간 측정용 헬퍼.
now_epoch() {
  date +%s
}

now_iso() {
  date -Iseconds
}

# iso_to_epoch는 ISO 8601 시각 문자열을 epoch 초로 변환한다.
# 변환 실패 시 0을 반환한다(호출 측이 비교/뺄셈에서 사용 가능).
iso_to_epoch() {
  local iso="${1:-}"
  if [[ -z "${iso}" ]]; then
    echo 0
    return
  fi
  date -d "${iso}" +%s 2>/dev/null || echo 0
}
