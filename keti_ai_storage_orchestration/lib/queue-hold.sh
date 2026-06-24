#!/usr/bin/env bash
# queue-hold.sh — Sourceable library for the KETI AI Storage queue-hold/release pattern.
#
# Mechanism (SAFE on shared/operational clusters — it NEVER touches the cluster's real
# ai-storage-queue): the demo Job is labelled kueue.x-k8s.io/queue-name=<QH_LQ>, where QH_LQ is a
# DEMO-OWNED LocalQueue name (default: demo-admission-queue) that does NOT exist by default. The
# Kueue Workload for it pends:
#   QuotaReserved=False :: Inadmissible :: LocalQueue demo-admission-queue doesn't exist
# HOLD    = ensure that demo LocalQueue is absent before submitting the Job.
# RELEASE = kubectl apply the demo LocalQueue (-> ClusterQueue QH_CQ) -> Kueue admits.
# CLEANUP = delete the demo LocalQueue (we created it; demo-owned, safe to remove).
# NOTE: earlier this toggled the shared ai-storage-queue — safe only because the BUILD box (80)
#       happened to lack that LocalQueue. On 99 that queue is real and in use, so we use a
#       demo-owned name instead. The Job's queue-name label MUST equal QH_LQ.
#
# No side effects when sourced. Guard any self-test behind:
#   if [ "${BASH_SOURCE[0]}" = "${0}" ] || [ "${QH_SELFTEST:-}" = "1" ]; then ...selftest... fi
# Run the self-test with: QH_SELFTEST=1 bash lib/queue-hold.sh
#
# Usage:
#   source /path/to/queue-hold.sh
#   qh_ensure_no_localqueue
#   kubectl apply -f my-job.yaml
#   qh_wait_pending my-job 60
#   qh_release
#   qh_wait_admitted my-job 120
#   qh_cleanup

# ── Env defaults (callers may override before sourcing or after) ──────────────
QH_NS="${QH_NS:-ai-storage-workloads}"
QH_LQ="${QH_LQ:-demo-admission-queue}"
QH_CQ="${QH_CQ:-ai-storage-cluster-queue}"

# ── qh_localqueue_yaml ────────────────────────────────────────────────────────
# Print the LocalQueue manifest to stdout. Suitable for kubectl apply -f -.
qh_localqueue_yaml() {
  cat <<EOF
apiVersion: kueue.x-k8s.io/v1beta1
kind: LocalQueue
metadata:
  name: ${QH_LQ}
  namespace: ${QH_NS}
spec:
  clusterQueue: ${QH_CQ}
EOF
}

# ── qh_ensure_no_localqueue ───────────────────────────────────────────────────
# Delete LocalQueue $QH_LQ in $QH_NS if it exists. Idempotent.
qh_ensure_no_localqueue() {
  kubectl delete localqueue "${QH_LQ}" -n "${QH_NS}" --ignore-not-found >/dev/null 2>&1 || true
}

# ── qh_release ────────────────────────────────────────────────────────────────
# Create (or update) the LocalQueue so Kueue admits pending Workloads. Idempotent.
qh_release() {
  local out
  if ! out=$(qh_localqueue_yaml | kubectl apply -f - 2>&1); then
    echo "qh_release: kubectl apply failed: ${out}" >&2
    return 1
  fi
}

# ── qh_cleanup ────────────────────────────────────────────────────────────────
# Delete the LocalQueue (reset to status quo). Idempotent.
qh_cleanup() {
  kubectl delete localqueue "${QH_LQ}" -n "${QH_NS}" --ignore-not-found >/dev/null 2>&1 || true
}

# ── qh_workload_for JOB_NAME ──────────────────────────────────────────────────
# Echo the Kueue Workload name owned by the given Job.
# Kueue names it job-<name>-<hash>. Strategy:
#   1. Match by ownerReference UID of the Job.
#   2. Fall back to name-prefix match "job-<JOB_NAME>-".
# Outputs empty string if not found yet.
qh_workload_for() {
  local job_name="${1:?qh_workload_for requires JOB_NAME}"

  # Get the Job's UID
  local job_uid
  job_uid=$(kubectl get job "${job_name}" -n "${QH_NS}" \
    -o jsonpath='{.metadata.uid}' 2>/dev/null || true)

  if [ -n "${job_uid}" ]; then
    # Find workload whose ownerReferences contains this UID
    local wl
    wl=$(kubectl get workload -n "${QH_NS}" -o json 2>/dev/null | \
      python3 -c "
import json, sys
data = json.load(sys.stdin)
uid = '${job_uid}'
for item in data.get('items', []):
    for ref in (item.get('metadata', {}).get('ownerReferences') or []):
        if ref.get('uid') == uid:
            print(item['metadata']['name'])
            break
" 2>/dev/null || true)
    if [ -n "${wl}" ]; then
      echo "${wl}"
      return 0
    fi
  fi

  # Fallback: name-prefix match
  local prefix="job-${job_name}-"
  kubectl get workload -n "${QH_NS}" --no-headers 2>/dev/null | \
    awk -v pfx="${prefix}" '$1 ~ "^" pfx {print $1; exit}'
}

# ── qh_wait_pending JOB_NAME [timeout=60] ────────────────────────────────────
# Poll until the Job's Workload exists AND is NOT admitted (Inadmissible pending).
# On success: echo workload name to stdout, return 0.
# On timeout: return 1.
# Also asserts 0 pods for the job.
qh_wait_pending() {
  local job_name="${1:?qh_wait_pending requires JOB_NAME}"
  local timeout="${2:-60}"
  local poll=3
  local elapsed=0
  local wl_name=""

  while [ "${elapsed}" -lt "${timeout}" ]; do
    wl_name=$(qh_workload_for "${job_name}")
    if [ -n "${wl_name}" ]; then
      # Check NOT admitted: Admitted condition must not be True,
      # and .status.admission must be absent/empty.
      local admitted_cond
      admitted_cond=$(kubectl get workload "${wl_name}" -n "${QH_NS}" \
        -o jsonpath='{.status.conditions[?(@.type=="Admitted")].status}' 2>/dev/null || true)
      local admission_field
      admission_field=$(kubectl get workload "${wl_name}" -n "${QH_NS}" \
        -o jsonpath='{.status.admission}' 2>/dev/null || true)

      if [ "${admitted_cond}" != "True" ] && [ -z "${admission_field}" ]; then
        # Confirm 0 pods
        local pod_count
        pod_count=$(kubectl get pods -n "${QH_NS}" \
          -l "job-name=${job_name}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
        if [ "${pod_count}" = "0" ]; then
          echo "${wl_name}"
          return 0
        fi
      fi
    fi
    sleep "${poll}"
    elapsed=$((elapsed + poll))
  done
  return 1
}

# ── qh_wait_admitted JOB_NAME [timeout=120] ──────────────────────────────────
# Poll until the Workload is Admitted=True OR the Job's .spec.suspend becomes false.
# return 0 on success, 1 on timeout.
qh_wait_admitted() {
  local job_name="${1:?qh_wait_admitted requires JOB_NAME}"
  local timeout="${2:-120}"
  local poll=3
  local elapsed=0

  while [ "${elapsed}" -lt "${timeout}" ]; do
    local wl_name
    wl_name=$(qh_workload_for "${job_name}")
    if [ -n "${wl_name}" ]; then
      local admitted_cond
      admitted_cond=$(kubectl get workload "${wl_name}" -n "${QH_NS}" \
        -o jsonpath='{.status.conditions[?(@.type=="Admitted")].status}' 2>/dev/null || true)
      if [ "${admitted_cond}" = "True" ]; then
        return 0
      fi
    fi

    # Also accept if Job is unsuspended
    local suspended
    suspended=$(kubectl get job "${job_name}" -n "${QH_NS}" \
      -o jsonpath='{.spec.suspend}' 2>/dev/null || true)
    if [ "${suspended}" = "false" ]; then
      return 0
    fi

    sleep "${poll}"
    elapsed=$((elapsed + poll))
  done
  return 1
}

# ── Self-test (only when run directly, or via QH_SELFTEST=1) ──────────────────
# Run the self-test with: QH_SELFTEST=1 bash lib/queue-hold.sh
if [ "${BASH_SOURCE[0]}" = "${0}" ] || [ "${QH_SELFTEST:-}" = "1" ]; then
  set -euo pipefail
  echo "=== queue-hold.sh self-test ==="
  echo "QH_NS=${QH_NS}  QH_LQ=${QH_LQ}  QH_CQ=${QH_CQ}"
  echo "--- qh_localqueue_yaml ---"
  qh_localqueue_yaml
  echo "--- functions defined: qh_ensure_no_localqueue qh_release qh_cleanup qh_workload_for qh_wait_pending qh_wait_admitted ---"
  echo "PASS: library loaded, all functions present"
fi
