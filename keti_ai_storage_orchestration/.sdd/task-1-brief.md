# Task 1 — Queue-hold library + LocalQueue manifest (`04-queue/`)

You are implementing one task of the "real-stop admission pipeline demo" for the KETI AI Storage
package at `/root/workspace/keti_ai_storage_orchestration/`. You have a live cluster via `kubectl`.

## What this task delivers
The **QUEUE hold**: a reliable, reusable way to make a Kueue-gated Job genuinely WAIT in the
cluster queue (a real *pending* Workload, 0 pods), then RELEASE it so Kueue admits it.

**Mechanism (already verified on this cluster — do not re-derive, just use it):**
In namespace `ai-storage-workloads` there is **no LocalQueue**, so any Kueue Workload there reports
`QuotaReserved=False :: Inadmissible :: LocalQueue ai-storage-queue doesn't exist` → a real pend.
RELEASE = create LocalQueue `ai-storage-queue` (clusterQueue `ai-storage-cluster-queue`).
CLUSTER FACTS: ClusterQueue `ai-storage-cluster-queue` exists. Demo ns `ai-storage-workloads` is
injection-enabled. A stale `job-queue-verify-*` Workload is already pending there (same cause).

## Deliverables

### 1. `04-queue/lib/queue-hold.sh` — sourceable bash library
- **No side effects when sourced** (define functions only; guard any self-test behind
  `if [ "${BASH_SOURCE[0]}" = "${0}" ]` or a `--selftest` arg).
- Must tolerate being sourced under `set -uo pipefail`.
- Env with defaults: `QH_NS=${QH_NS:-ai-storage-workloads}`, `QH_LQ=${QH_LQ:-ai-storage-queue}`,
  `QH_CQ=${QH_CQ:-ai-storage-cluster-queue}`.
- Functions:
  - `qh_localqueue_yaml` — print the LocalQueue manifest (name `$QH_LQ`, ns `$QH_NS`,
    `spec.clusterQueue: $QH_CQ`) to stdout.
  - `qh_ensure_no_localqueue` — delete LocalQueue `$QH_LQ` in `$QH_NS` if it exists (so a fresh
    demo pends). Idempotent; `--ignore-not-found`.
  - `qh_release` — `kubectl apply` the LocalQueue (admits pending Workloads). Idempotent.
  - `qh_cleanup` — delete LocalQueue `$QH_LQ` in `$QH_NS` (reset to status quo). Idempotent.
  - `qh_workload_for JOB_NAME` — echo the Kueue Workload object name owned by that Job (Kueue names
    it `job-<name>-<hash>`; resolve by ownerReference UID match, fall back to name-prefix
    `job-<JOB_NAME>-`). Empty output if none yet.
  - `qh_wait_pending JOB_NAME [timeout=60]` — poll until the Job's Workload exists AND is NOT
    admitted (condition `Admitted`!=True and no `.status.admission`). On success echo the workload
    name to stdout and return 0; return 1 on timeout. Also assert 0 pods exist for the job.
  - `qh_wait_admitted JOB_NAME [timeout=120]` — poll until the Workload is `Admitted=True`
    (or the Job's `.spec.suspend` becomes false). return 0/1.
- Keep helpers small and quiet (callers print narration). Use `kubectl -o jsonpath`.

### 2. `04-queue/demo-admission-queue-job.yaml` — test fixture Job
- `batch/v1` Job, `metadata.name: demo-admission-queue-test`, `namespace: ai-storage-workloads`,
  labels `demo: admission-trace` (and `app: demo-admission-queue-test`).
- `spec.suspend: true`; pod-template + job labels include `kueue.x-k8s.io/queue-name: ai-storage-queue`.
- One `busybox:1.36` container, `command: ["sh","-c","echo admitted; sleep 10"]`,
  requests cpu `100m` / memory `64Mi`, limits cpu `200m` / memory `128Mi`, `restartPolicy: Never`.
- (This explicit-label fixture is for THIS task's self-test. Task 2 will instead submit a *bare*
  job and let the webhook inject the label — so keep this manifest self-contained and minimal.)

## Live verification (MUST run against the cluster; capture evidence)
1. `source 04-queue/lib/queue-hold.sh`.
2. `qh_ensure_no_localqueue`; `kubectl apply -f 04-queue/demo-admission-queue-job.yaml`.
3. `qh_wait_pending demo-admission-queue-test` → CONFIRM the Workload is really pending
   (capture `kubectl get workload <wl> -n ai-storage-workloads -o jsonpath` of its conditions,
   showing Inadmissible / not-admitted) and that there are **0 pods** for the job.
4. `qh_release`; `qh_wait_admitted demo-admission-queue-test` → CONFIRM the Workload becomes
   Admitted and the Job unsuspends (or a pod appears).
5. Tear down: delete the test Job (`kubectl delete -f ...`), `qh_cleanup`. Confirm the LocalQueue
   is gone and no `demo-admission-*` objects remain.
6. Note in the report: `qh_release` also admits the pre-existing stale `job-queue-verify-*` — that
   is acceptable (it was already meant to run); do NOT delete other people's workloads.

## Constraints
- Portable: local kubectl, no hardcoded node/IP. Idempotent. Only touch `demo=admission-trace`
  objects + the `ai-storage-queue` LocalQueue. Leave the cluster as you found it.

## Report
Write full details (commands run, observed Workload conditions before/after, pod counts) to
`/root/workspace/keti_ai_storage_orchestration/.sdd/task-1-report.md`.
Return only: STATUS (DONE / DONE_WITH_CONCERNS / BLOCKED), the files you created, and a one-line
verification result (e.g. "pend→release→admit confirmed live; cleaned up").
