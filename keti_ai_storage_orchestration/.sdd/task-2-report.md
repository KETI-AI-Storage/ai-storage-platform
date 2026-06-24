# Task 2 Report — Admission-trace script + Job manifest

**Date**: 2026-06-23  
**Status**: DONE_WITH_CONCERNS  
**Concerns**: STOP 2 uses node-label hold (honest-degrade) rather than schedulingGates due to a confirmed scheduler limitation (see Probe B below).

---

## Probe A — Does the webhook gate a bare Job?

**Answer: NO. The webhook does NOT inject the queue-name label on Jobs.**

Submitted a minimal Job with `suspend: true`, NO `kueue.x-k8s.io/queue-name` label, into `ai-storage-workloads`. Result:
- No Kueue Workload was created (Kueue never picked up the Job)
- Job stayed suspended indefinitely (never ran)
- Webhook did NOT inject `kueue.x-k8s.io/queue-name` into the Job metadata

**Conclusion**: The routing label must be author/platform-set. A Job must include `kueue.x-k8s.io/queue-name: ai-storage-queue` and `suspend: true` explicitly for the queue hold to work. The webhook operates at **pod creation time** (post-admission), not at Job submit time.

Confirmed (by submitting a Job WITH the queue-name label): Kueue immediately created a Workload with `Inadmissible :: LocalQueue ai-storage-queue doesn't exist`.

### Webhook injection fields (pod level, observed live)

When a pod is created from the namespace, `ai-storage-webhook` injects:

| Field | Value |
|---|---|
| `spec.schedulerName` | `ai-storage-scheduler` |
| `spec.containers[+]` | `insight-trace` sidecar (`ketidevit2/insight-trace:job-exit-20260527`) |
| `spec.nodeSelector` (injected) | `node-role.kubernetes.io/worker: ''` |
| `metadata.annotations["ai-storage/selected-tier"]` | `S3` |
| `metadata.annotations["storage.keti.io/tier-hint"]` | `S3` |
| `metadata.annotations["storage.keti.io/archive-policy"]` | `default` |
| `metadata.annotations["storage.keti.io/checkpoint"]` | `false` |
| `metadata.annotations["storage.keti.io/latency"]` | `0ms` |
| `metadata.annotations["storage.keti.io/prefetch"]` | `false` |
| `metadata.annotations["storage.keti.io/dataset-size"]` | `0` |
| `metadata.labels["ai-storage-selected-tier"]` | `S3` |
| `metadata.labels["workload.keti.io/kind"]` | `job` |
| `metadata.labels["workload.keti.io/stage"]` | `default` |
| `metadata.labels["workload.keti.io/type"]` | `default` |

No tier annotations are injected at Job level. The `nodeSelector: node-role.kubernetes.io/worker: ''` is injected at pod level (not from the job template).

---

## Probe B — Does ai-storage-scheduler honor schedulingGates?

**Answer: PARTIALLY — the pod shows SchedulingGated, but the RELEASE mechanism does not work due to a scheduler bug.**

Submitted a Job with `schedulingGates: [{name: keti.io/demo-hold}]` plus tolerations for `node.kubernetes.io/unreachable:NoSchedule` and `node.cilium.io/agent-not-ready:NoSchedule`. After LocalQueue creation and admission:

1. Pod appeared with `PodScheduled=False, reason=SchedulingGated, no nodeName` ✓ (real hold visible)
2. **HOWEVER**: ai-storage-scheduler immediately attempted to bind the pod (~1.5s after pod creation)
3. API server rejected the binding: `"pod has non-empty .spec.schedulingGates"`
4. After this binding failure, the pod was left in an **assumed-but-unbound** state in the scheduler cache
5. The scheduler's `updatePodInSchedulingQueue` handler checked `IsAssumedPod() == true` and returned early
6. Gate removal (`kubectl patch pod ... --type=json -p '[{"op":"remove","path":"/spec/schedulingGates"}]'`) did NOT trigger re-scheduling

**Root cause** (confirmed via source code analysis):
- `schedule_one.go` bindingCycle: on failure, does NOT call `cache.ForgetPod()` (no such call exists)
- `eventhandler.go` `updatePodInSchedulingQueue()`: `if isAssumed { return }` — gate removal update is ignored
- `queue.go` `MoveAllToActiveOrBackoffQueue()`: empty stub, node label changes don't trigger re-queue
- `queue.go` backoff/unschedulable flush loops: entirely commented out

**Consequence**: SchedulingGates create a visually correct hold (SchedulingGated condition shown) but the release mechanism (`kubectl patch` to remove gates) does not work with this custom scheduler. The pod remains permanently stuck in the assumed-pod cache after binding failure.

**STOP 2 fallback mechanism used**: `nodeSelector: keti.io/demo-hold=true` on the job template. No node has this label initially → ai-storage-scheduler runs its filter cycle and finds 0 feasible nodes → pod is genuinely Pending/unschedulable. Release = `kubectl label node ai-storage-worker-01 keti.io/demo-hold=true` + delete stuck pod (Job controller re-creates it, scheduler places new pod immediately).

---

## STOP 1 evidence (live-verified)

- Job submitted with `suspend: true` and `kueue.x-k8s.io/queue-name: ai-storage-queue`
- No LocalQueue present → Kueue Workload appeared immediately with:
  `QuotaReserved=False, reason=Inadmissible, message="LocalQueue ai-storage-queue doesn't exist"`
- Pod count: **0** (confirmed by `qh_wait_pending`)
- Release: `qh_release` (creates LocalQueue) → Workload admitted → Job unsuspended

---

## STOP 2 evidence (live-verified, node-label hold mode)

- Pod created after admission, nodeSelector shows `{keti.io/demo-hold: true, node-role.kubernetes.io/worker: ''}`
- No node has `keti.io/demo-hold=true` → scheduler found 0 feasible nodes → pod Pending
- Release: `kubectl label node ai-storage-worker-01 keti.io/demo-hold=true` + `kubectl delete pod <stuck>`
- Job controller created new pod → scheduler placed it on `ai-storage-worker-01`
- Final pod: `schedulerName=ai-storage-scheduler`, `nodeName=ai-storage-worker-01`

---

## Scheduler hold behavior

- `ai-storage-scheduler` does NOT skip gated pods in its scheduling queue
- It attempts to bind gated pods immediately; API server rejects with `non-empty .spec.schedulingGates`
- Binding failure leaves pod in stuck assumed state — no retry mechanism active in this scheduler
- **Observable fact**: pod IS shown as SchedulingGated but cannot be released via gate removal
- **Mitigation used**: nodeSelector hold (see above)

---

## Cleanup confirmation

Exit trap verified post-run:
- `demo-admission-trace` Job: deleted (cascades to owned Workload via GC)
- Pods with `job-name=demo-admission-trace`: force-deleted (grace-period=0 to handle unreachable node)
- LocalQueue `ai-storage-queue`: deleted via `qh_cleanup`
- Node label `keti.io/demo-hold` on `ai-storage-worker-01`: removed
- No demo artifacts remain in `ai-storage-workloads` namespace

---

## Files created

- `/root/workspace/keti_ai_storage_orchestration/02-scheduling/demo-admission-trace-job.yaml`
- `/root/workspace/keti_ai_storage_orchestration/02-scheduling/02-admission-trace.sh`

---

## STOP 2 mode

**`honest-degrade` (node-label hold)** — SchedulingGates are technically visible on pods but the custom ai-storage-scheduler cannot be released via gate removal due to a confirmed assumed-pod cache bug. The script explains this honestly and uses a working nodeSelector-based hold instead.
