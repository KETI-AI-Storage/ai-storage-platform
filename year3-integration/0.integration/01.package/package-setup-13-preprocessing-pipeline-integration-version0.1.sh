#!/usr/bin/env bash
# package-setup-13-preprocessing-pipeline-integration-version0.1.sh는 Preprocessing Pipeline Integration 워크로드의
# manifest 위치, 실제 deploy/pod 가용성, namespace 등을 kubectl 결과 기반으로 출력한다.
#
# workload 이름과 namespace는 어떤 값도 하드코딩하지 않으며,
# 사용자 인자 → manifest metadata → kubectl 검색 순으로 동적으로 결정한다.
#
# Author: 미정 <unknown@example.com>
# Created: 2026-05-28

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../02.keti-orchestration-module/lib/common-log.sh"

# 후보 manifest 경로 (workload 이름을 manifest에서도 가져올 수 있도록 검색).
MANIFEST_CANDIDATES=(
  "${REPO_DIR}/year3-integration/4.integration_test/manifests/preprocessing-pipeline-workflow.yaml"
  "${REPO_DIR}/year3-integration/4.integration_test/manifests/cpu-preprocessing-pipeline-workload.yaml"
)

start="$(date +%s)"
print_header "Preprocessing Pipeline Integration Status"

# 1순위: 사용자 인자, 2순위: manifest metadata.name, 3순위: kubectl 검색
workload_name=""
workload_source=""
if [ -n "${WORKLOAD_NAME:-}" ]; then
  workload_name="${WORKLOAD_NAME}"
  workload_source="user-arg"
fi

manifest_path=""
for cand in "${MANIFEST_CANDIDATES[@]}"; do
  if [ -f "${cand}" ]; then
    manifest_path="${cand}"
    if [ -z "${workload_name}" ]; then
      detected="$(grep -E '^[[:space:]]*name:' "${cand}" 2>/dev/null | head -1 | awk -F':' '{gsub(/[ \t]/,"",$2); print $2}')"
      if [ -n "${detected}" ]; then
        workload_name="${detected}"
        workload_source="manifest-metadata"
      fi
    fi
    break
  fi
done

if [ -z "${workload_name}" ]; then
  detected="$(kubectl get deploy -A --no-headers 2>/dev/null | awk '/preprocess|pipeline/ {print $2; exit}')"
  if [ -n "${detected}" ]; then
    workload_name="${detected}"
    workload_source="deploy-discovery"
  fi
fi

ns=""
ns_source=""
if [ -n "${TARGET_NAMESPACE:-}" ] && kubectl get ns "${TARGET_NAMESPACE}" >/dev/null 2>&1; then
  ns="${TARGET_NAMESPACE}"
  ns_source="user-arg"
elif [ -n "${workload_name}" ]; then
  ns="$(kubectl get deploy -A --no-headers 2>/dev/null | awk -v w="${workload_name}" '$2 == w || $2 ~ w {print $1; exit}')"
  if [ -z "${ns}" ]; then
    ns="$(kubectl get pods -A --no-headers 2>/dev/null | awk -v w="${workload_name}" '$2 ~ w {print $1; exit}')"
  fi
  [ -n "${ns}" ] && ns_source="workload-discovery"
fi

print_kv "workload"           "${workload_name:-UNKNOWN}"
print_kv "workload_source"    "${workload_source:-SKIP_NOT_FOUND}"
print_kv "namespace"          "${ns:-UNKNOWN}"
print_kv "namespace_source"   "${ns_source:-SKIP_NOT_FOUND}"
print_kv "manifest"           "${manifest_path:-SKIP_NOT_FOUND}"

if [ -n "${workload_name}" ] && [ -n "${ns}" ]; then
  print_separator
  print_commands_block "command" \
    "kubectl get deploy ${workload_name} -n ${ns}" \
    "kubectl get pods -n ${ns} -l app=${workload_name} -o wide" \
    "kubectl get pvc -n ${ns}"
  print_raw_block "deploy" "$(capture_cmd "kubectl get deploy ${workload_name} -n ${ns}")"
  print_raw_block "pods"   "$(capture_cmd "kubectl get pods -n ${ns} -l app=${workload_name} -o wide")"
  print_raw_block "pvc"    "$(capture_cmd "kubectl get pvc -n ${ns}")"
  if kubectl get deploy "${workload_name}" -n "${ns}" >/dev/null 2>&1; then
    print_kv "status" "✓ installed"
  else
    print_kv "status" "⚠ not installed / manifest may need apply"
  fi
elif [ -n "${manifest_path}" ]; then
  print_separator
  print_commands_block "command" "kubectl apply -f ${manifest_path}"
  print_kv "status" "⚠ not installed / manifest available"
else
  print_kv "status" "⚠ SKIP_NOT_FOUND"
fi

print_kv "time" "$(measure_time "${start}")"
print_footer
