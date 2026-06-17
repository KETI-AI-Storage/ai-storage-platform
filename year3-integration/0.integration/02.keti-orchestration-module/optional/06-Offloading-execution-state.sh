#!/usr/bin/env bash
# 06-Offloading-execution-state.sh는 offloading 관련 pod의 실제 가용성을 kubectl 결과로 출력한다.
#
# 컴포넌트 이름은 grep 패턴 용도로만 사용한다.
#
# Author: 미정 <unknown@example.com>
# Created: 2026-05-28

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/log-utils.sh"

start="$(date +%s)"
print_header "Offloading Execution State"

print_commands_block "command" "kubectl get pods -A | grep -i offload"
all_pods="$(capture_cmd 'kubectl get pods -A')"
filtered="$(printf '%s\n' "${all_pods}" | grep -iE 'NAMESPACE|offload' || true)"
print_raw_block "offloading_pods" "${filtered}"

if printf '%s' "${all_pods}" | grep -qi 'offload'; then
  print_kv "status"  "✓ observed"
  print_kv "source"  "kubectl-pods"
else
  print_kv "status"  "⚠ SKIP_NOT_FOUND"
  print_kv "source"  "kubectl-pods"
fi

print_kv "time" "$(measure_time "${start}")"
print_footer
