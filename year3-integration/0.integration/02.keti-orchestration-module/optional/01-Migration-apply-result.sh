#!/usr/bin/env bash
# 01-Migration-apply-result.sh는 Migration scope 정책의 실제 kubectl CR 결과를 출력한다.
#
# scope/policy 이름은 grep 패턴 용도로만 사용하며 실행값으로 박지 않는다.
# 실제 적용된 정책이 없으면 SKIP_NOT_FOUND로 표시한다.
#
# Author: 미정 <unknown@example.com>
# Created: 2026-05-28

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/log-utils.sh"

start="$(date +%s)"
print_header "Migration Apply Result"

# CR 자체가 클러스터에 등록되어 있는지 먼저 확인 (없으면 SKIP).
if kubectl api-resources --no-headers 2>/dev/null | awk '{print $1}' | grep -q '^orchestrationpolicies$'; then
  print_commands_block "command" \
    "kubectl get orchestrationpolicy -A" \
    "kubectl get orchestrationpolicy -A -o wide | grep -i migration"
  raw="$(capture_cmd 'kubectl get orchestrationpolicy -A -o wide')"
  filtered="$(printf '%s\n' "${raw}" | grep -iE 'NAME|migration' || true)"
  print_raw_block "orchestrationpolicy" "${filtered}"
  if printf '%s' "${raw}" | grep -qi 'migration'; then
    print_kv "status" "✓ observed"
    print_kv "scope_source" "kubectl-cr"
  else
    print_kv "status" "⚠ SKIP_NOT_FOUND"
    print_kv "scope_source" "kubectl-cr"
  fi
else
  print_kv "status"       "⚠ SKIP_EXTERNAL_DEPENDENCY"
  print_kv "reason"       "orchestrationpolicy CRD not installed"
  print_kv "scope_source" "crd-missing"
fi

print_kv "time" "$(measure_time "${start}")"
print_footer
