#!/usr/bin/env bash
# 03-Autoscaling-apply-result.sh는 Autoscaling scope 정책과 실제 HPA 리소스를 kubectl 결과로 출력한다.
#
# scope/policy 이름은 grep 패턴 용도로만 사용한다.
# HPA가 있어도 orchestrationpolicy가 없을 수 있고, 그 반대도 가능하므로 둘 다 별도로 검사한다.
#
# Author: 미정 <unknown@example.com>
# Created: 2026-05-28

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/log-utils.sh"

start="$(date +%s)"
print_header "Autoscaling Apply Result"

print_commands_block "command" "kubectl get hpa -A"
hpa_out="$(capture_cmd 'kubectl get hpa -A')"
print_raw_block "hpa" "${hpa_out}"

policy_observed=""
if kubectl api-resources --no-headers 2>/dev/null | awk '{print $1}' | grep -q '^orchestrationpolicies$'; then
  print_commands_block "command" "kubectl get orchestrationpolicy -A -o wide"
  raw="$(capture_cmd 'kubectl get orchestrationpolicy -A -o wide')"
  filtered="$(printf '%s\n' "${raw}" | grep -iE 'NAME|autoscaling|scaling' || true)"
  print_raw_block "orchestrationpolicy" "${filtered}"
  printf '%s' "${raw}" | grep -qiE 'autoscaling|scaling' && policy_observed=yes
else
  print_kv "policy_status" "⚠ SKIP_EXTERNAL_DEPENDENCY (no CRD)"
fi

if printf '%s\n' "${hpa_out}" | awk 'NR>1' | grep -q . ; then
  print_kv "hpa_status" "✓ observed"
elif [ -n "${policy_observed}" ]; then
  print_kv "hpa_status" "⚠ not-observed (policy only)"
else
  print_kv "hpa_status" "⚠ SKIP_NOT_FOUND"
fi

if [ -n "${policy_observed}" ]; then
  print_kv "policy_status" "✓ observed"
else
  printf '%s\n' "${hpa_out}" | awk 'NR>1' | grep -q . && print_kv "policy_status" "⚠ not-observed (hpa only)" || true
fi

print_kv "scope_source" "kubectl-cr+hpa"
print_kv "time" "$(measure_time "${start}")"
print_footer
