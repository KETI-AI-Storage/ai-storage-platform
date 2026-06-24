# Task 1 Report — Queue-hold library + LocalQueue manifest

**Date:** 2026-06-23  
**Status:** DONE

---

## Files Created

1. `/root/workspace/keti_ai_storage_orchestration/04-queue/lib/queue-hold.sh` — sourceable bash library
2. `/root/workspace/keti_ai_storage_orchestration/04-queue/demo-admission-queue-job.yaml` — test fixture Job

---

## Live Verification

### Step 1: Source library + ensure no LocalQueue

```
source 04-queue/lib/queue-hold.sh
qh_ensure_no_localqueue
```

Result: LocalQueue `ai-storage-queue` was absent in `ai-storage-workloads` (no-op, idempotent). Confirmed:
```
No resources found in ai-storage-workloads namespace.
```

### Step 2: Apply test Job

```
kubectl apply -f 04-queue/demo-admission-queue-job.yaml
```

Result: `job.batch/demo-admission-queue-test created`

### Step 3: qh_wait_pending — Workload pending, 0 pods

```
WL_NAME=$(qh_wait_pending demo-admission-queue-test 60)
```

Result: `PASS — WL_NAME=job-demo-admission-queue-test-ce8c7`

**Workload conditions BEFORE release (evidence of real queue hold):**

```yaml
status:
  conditions:
  - lastTransitionTime: "2026-06-23T07:04:23Z"
    message: LocalQueue ai-storage-queue doesn't exist
    observedGeneration: 1
    reason: Inadmissible
    status: "False"
    type: QuotaReserved
```

No `Admitted` condition present; `.status.admission` is empty.

**Pod count for `demo-admission-queue-test`:** 0 — CONFIRMED.

### Step 4: qh_release — Create LocalQueue

```
qh_release   # kubectl apply localqueue yaml
```

Result: LocalQueue `ai-storage-queue` created in `ai-storage-workloads`, clusterQueue `ai-storage-cluster-queue`.

```
NAME               CLUSTERQUEUE               PENDING WORKLOADS   ADMITTED WORKLOADS
ai-storage-queue   ai-storage-cluster-queue
```

### Step 5: qh_wait_admitted — Workload admitted

```
qh_wait_admitted demo-admission-queue-test 120
```

Result: `PASS` — returned within ~3s of LocalQueue creation.

**Workload conditions AFTER release (evidence of real admission):**

```yaml
status:
  admission:
    clusterQueue: ai-storage-cluster-queue
    podSetAssignments:
    - count: 1
      flavors:
        cpu: default-flavor
        memory: default-flavor
      name: main
      resourceUsage:
        cpu: 100m
        memory: 64Mi
  conditions:
  - lastTransitionTime: "2026-06-23T07:05:22Z"
    message: Quota reserved in ClusterQueue ai-storage-cluster-queue
    observedGeneration: 1
    reason: QuotaReserved
    status: "True"
    type: QuotaReserved
  - lastTransitionTime: "2026-06-23T07:05:22Z"
    message: The workload is admitted
    observedGeneration: 1
    reason: Admitted
    status: "True"
    type: Admitted
```

**Job `.spec.suspend` after admission:** `false` — Kueue unsuspended the Job as expected.

### Step 6: Cleanup

```
kubectl delete -f 04-queue/demo-admission-queue-job.yaml --ignore-not-found
qh_cleanup
```

Result:
- `job.batch "demo-admission-queue-test" deleted`
- LocalQueue `ai-storage-queue` deleted.
- Workload `job-demo-admission-queue-test-ce8c7` cascade-deleted by K8s GC (owned by Job).

**Post-cleanup state:**
```
LocalQueues in ai-storage-workloads: No resources found
demo-admission-* objects:            No resources found
```

### Side effect: stale `job-queue-verify-csd-f4e96` workload

As predicted in the brief, creating the LocalQueue also admitted the pre-existing stale workload:

```json
[
  { "type": "QuotaReserved", "status": "True", "reason": "QuotaReserved",
    "message": "Quota reserved in ClusterQueue ai-storage-cluster-queue",
    "lastTransitionTime": "2026-06-23T07:05:22Z" },
  { "type": "Admitted", "status": "True", "reason": "Admitted",
    "message": "The workload is admitted",
    "lastTransitionTime": "2026-06-23T07:05:22Z" }
]
```

This is acceptable per the brief. That workload was NOT deleted.

---

## Cluster State After Cleanup

- `ai-storage-workloads` LocalQueue: **absent** (status quo restored)
- `demo-admission-*` objects: **none** in any namespace
- `job-queue-verify-csd-f4e96` workload: **Admitted=True** (side effect; not touched)
- All other cluster objects: **unmodified**

---

## Library Design Notes

- `queue-hold.sh` has zero side effects when sourced — all top-level code only sets env defaults and defines functions.
- `qh_workload_for` uses UID-based ownerReference matching first (exact), name-prefix match as fallback.
- `qh_wait_pending` asserts both the Workload condition state AND pod count=0 before returning success.
- Self-test guard: `if [ "${BASH_SOURCE[0]}" = "${0}" ] || [ "${1:-}" = "--selftest" ]` — runs only when executed directly or with `--selftest` flag.
- All functions tolerate `set -uo pipefail` (use `|| true` on kubectl calls that may return empty, avoid unbound variable errors).

---

## Code-Review Fix — 2026-06-23

### Finding 1 (Important) — Self-test guard reads `$1` from caller at source time

**Old guard:**
```bash
if [ "${BASH_SOURCE[0]}" = "${0}" ] || [ "${1:-}" = "--selftest" ]; then
```

**New guard (env-var based):**
```bash
if [ "${BASH_SOURCE[0]}" = "${0}" ] || [ "${QH_SELFTEST:-}" = "1" ]; then
```

Header comment updated to:
```
# Run the self-test with: QH_SELFTEST=1 bash 04-queue/lib/queue-hold.sh
```

### Finding 2 (Minor) — `qh_release` swallowed apply failures

**Old:**
```bash
qh_release() {
  qh_localqueue_yaml | kubectl apply -f - >/dev/null 2>&1
}
```

**New:**
```bash
qh_release() {
  local out
  if ! out=$(qh_localqueue_yaml | kubectl apply -f - 2>&1); then
    echo "qh_release: kubectl apply failed: ${out}" >&2
    return 1
  fi
}
```

On success: stdout/stderr suppressed (captured into `out`, discarded). On failure: error echoed to stderr, non-zero return. Idempotent re-apply still succeeds (kubectl apply is idempotent).

### Verification commands and output

```
$ bash -n 04-queue/lib/queue-hold.sh && echo "SYNTAX_OK"
SYNTAX_OK

$ bash -c 'set -uo pipefail; source /root/workspace/keti_ai_storage_orchestration/04-queue/lib/queue-hold.sh --selftest; echo SOURCED_OK'
SOURCED_OK

$ QH_SELFTEST=1 bash 04-queue/lib/queue-hold.sh 2>&1 | head -20; echo "EXIT:$?"
=== queue-hold.sh self-test ===
QH_NS=ai-storage-workloads  QH_LQ=ai-storage-queue  QH_CQ=ai-storage-cluster-queue
--- qh_localqueue_yaml ---
apiVersion: kueue.x-k8s.io/v1beta1
kind: LocalQueue
metadata:
  name: ai-storage-queue
  namespace: ai-storage-workloads
spec:
  clusterQueue: ai-storage-cluster-queue
--- functions defined: qh_ensure_no_localqueue qh_release qh_cleanup qh_workload_for qh_wait_pending qh_wait_admitted ---
PASS: library loaded, all functions present
EXIT:0
```
