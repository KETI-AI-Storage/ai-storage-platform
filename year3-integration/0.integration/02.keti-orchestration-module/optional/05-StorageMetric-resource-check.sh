#!/usr/bin/env bash
# 05-StorageMetric-resource-check.sh는 storage metric 관련 컴포넌트의 실제 가용성을 kubectl 결과로 출력한다.
#
# 컴포넌트 이름은 grep 패턴 용도로만 사용한다.
#
# Author: 미정 <unknown@example.com>
# Created: 2026-05-28

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/log-utils.sh"

start="$(date +%s)"
print_header "StorageMetric Resource Check"

print_commands_block "command" \
  "kubectl get pods -A | grep -iE 'storage.*metric|metric.*storage'" \
  "kubectl get sc"
all_pods="$(capture_cmd 'kubectl get pods -A')"
filtered="$(printf '%s\n' "${all_pods}" | grep -iE 'NAMESPACE|storage.*metric|metric.*storage' || true)"
print_raw_block "storage_metric_pods" "${filtered}"
print_raw_block "storageclasses" "$(capture_cmd 'kubectl get sc')"

if printf '%s' "${all_pods}" | grep -qiE 'storage.*metric|metric.*storage'; then
  print_kv "status"  "✓ observed"
  print_kv "source"  "kubectl-pods"
else
  print_kv "status"  "⚠ SKIP_NOT_FOUND"
  print_kv "source"  "kubectl-pods"
fi

print_kv "time" "$(measure_time "${start}")"
print_footer
