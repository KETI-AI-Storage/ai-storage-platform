# Task 2 — Admission-trace script + Job manifest (`02-scheduling/`)

You are an implementer subagent on the "real-stop admission pipeline demo". You have a live
`kubectl` (shared operational cluster — stay within `demo=admission-trace` scope; CLEAN UP).

Read first: `/root/workspace/keti_ai_storage_orchestration/.sdd/plan.md` (cluster facts + global
constraints). Task 1 is DONE and you BUILD ON it.

## Goal
A single script that submits ONE workload and walks it through the admission pipeline, stopping it
**for real** at each control point so a presenter can inspect the live intermediate state, then
releasing it. The narrative:

```
Job submitted → [webhook injects annotations/labels]  → 🛑 STOP 1: workload really waiting in the QUEUE
   → release (create LocalQueue) → admitted → Pod created [webhook injects schedulerName + sidecar]
   → 🛑 STOP 2: Pod really held BEFORE scheduling
   → release (remove hold) → ai-storage-scheduler places it on a node → done
```

A "stop" = the workload is genuinely held at a Kubernetes control point; the presenter presses
Enter to trigger the REAL release. STOP 1 (queue) is guaranteed. STOP 2 (scheduling) is best-effort
(see PROBE below) and must DEGRADE HONESTLY if the custom scheduler can't be held.

## Reuse Task 1 (do not reimplement)
`source` the queue-hold library: `04-queue/lib/queue-hold.sh`. API:
`qh_ensure_no_localqueue` | `qh_wait_pending JOB [timeout]` (echoes workload name, rc0 if pending)
| `qh_release` | `qh_wait_admitted JOB [timeout]` | `qh_cleanup` | `qh_workload_for JOB`.
Env `QH_NS` default `ai-storage-workloads` (the injection ns), `QH_LQ=ai-storage-queue`,
`QH_CQ=ai-storage-cluster-queue`. Also `source ../lib/load-env.sh` and `../lib/common.sh`
(gives `pause_if`, `detect_target_node`).

## PROBES you MUST run live during development (these decide the script's exact behavior)
**Probe A — does the webhook gate a BARE Job?** Submit a minimal Job into ai-storage-workloads with
NO schedulerName, NO `kueue.x-k8s.io/queue-name` label, NO tier annotations, `suspend:true`, one
container. Inspect the live Job (`kubectl get job ... -o yaml`):
  - Did `ai-storage-webhook` inject the queue-name label and/or tier annotations onto the Job?
  - Is the Job actually gated by Kueue (a Workload appears, pending)?
  - If BARE works → the manifest stays bare and the script SHOWS the webhook injecting the queue
    label + tier (the "annotation update before the queue" reveal). 
  - If BARE is NOT gated (runs immediately / no Workload) → include `kueue.x-k8s.io/queue-name:
    ai-storage-queue` (and `suspend:true`) in the manifest so the queue stop is demonstrable, and
    narrate HONESTLY that the routing label is author/platform-set while the webhook augments it
    with tier decisions. Document which case held.

**Probe B — does ai-storage-scheduler honor `schedulingGates`?** Bake a scheduling gate into the
Job's pod template: `spec.template.spec.schedulingGates: [{name: keti.io/demo-hold}]`. After the
Job is admitted and a pod is created, check the pod for ~20–30s:
  - HELD case: pod stays `Pending` with `status.conditions[PodScheduled].reason=SchedulingGated`,
    no `spec.nodeName`. → schedulingGates WORKS; STOP 2 is a real held stop, release = remove the
    gate (`kubectl patch pod ... --type=json -p '[{"op":"remove","path":"/spec/schedulingGates"}]'`).
  - NOT-HELD case: ai-storage-scheduler assigned `spec.nodeName` despite the gate (it ignores
    gates). → STOP 2 cannot be a real hold; the script must DETECT this at runtime and degrade:
    show the pod's webhook injection + its (immediate) placement, print a clear honest note
    ("ai-storage-scheduler does not honor schedulingGates — placement shown live, not held"), then
    a normal pause so the presenter can talk.
  Record the observed behavior in your report.

## Deliverables

### 1. `02-scheduling/demo-admission-trace-job.yaml`
The FINAL working Job (per Probe A/B outcomes). `batch/v1` Job, name `demo-admission-trace`,
ns `ai-storage-workloads`, labels `demo: admission-trace`. Pod template carries the
`schedulingGates: [{name: keti.io/demo-hold}]` (our deliberate hold instrument). One light
container (busybox `sleep 60` is fine), modest requests (cpu 200m / mem 128Mi). `restartPolicy:
Never`. Include `suspend:true` and/or the queue-name label ONLY if Probe A showed the bare job
isn't gated otherwise — keep it as bare as the cluster allows so the webhook injection is visible.

### 2. `02-scheduling/02-admission-trace.sh`
Stepped trace. Structure:
- `set -uo pipefail`; resolve `HERE`; source load-env, common.sh, and the queue-hold lib.
  `export QH_NS=ai-storage-workloads`.
- A local `trace_pause "msg"` that, on a TTY, prints the message and waits for Enter (this script's
  PURPOSE is the stepped demo, so it stops by default on a TTY — do NOT gate it behind PAUSE=1);
  off-TTY (CI), print "(non-interactive: auto-continuing)" + `sleep 3` and proceed. The REAL
  release action runs AFTER `trace_pause` returns.
- `KEEP=${KEEP:-0}`. Trap EXIT → cleanup: delete the demo Job (`-l demo=admission-trace` in QH_NS),
  `qh_cleanup` (remove LocalQueue), remove any node label you added (Probe-B fallback), unless KEEP=1.
- **[setup]** preflight: kubectl reachable; ns ai-storage-workloads has injection label; ClusterQueue
  exists. `qh_ensure_no_localqueue`. Delete any leftover `demo-admission-trace` Job.
- **[step 1: submit + webhook]** `kubectl apply` the Job. Then SHOW the webhook's mutation: diff the
  applied manifest against the live Job object, or just print the injected fields — labels
  (`kueue.x-k8s.io/queue-name`, any `*selected-tier*`) and annotations (`storage.keti.io/*`,
  `ai-storage/selected-tier`). Label clearly: "웹훅이 큐 라우팅/스토리지-tier annotation을 주입".
- **[step 2: real queue stop]** `wl=$(qh_wait_pending demo-admission-trace 90)`. Print the live
  evidence: the Workload's conditions (Inadmissible / not admitted) and **0 pods**. Then
  `trace_pause "🛑 STOP 1 — 워크로드가 큐에서 실제 대기 중 (Workload pending, 파드 0개). Enter → LocalQueue 생성해 release"`.
  After Enter: `qh_release`; `qh_wait_admitted demo-admission-trace 120`; confirm the Job unsuspended.
- **[step 3: pod webhook + scheduling stop]** Wait for the pod to be created (`-l job-name=demo-admission-trace`).
  SHOW the pod-level webhook injection: `spec.schedulerName` (expect ai-storage-scheduler) and the
  injected `insight-trace` sidecar container. Then evaluate Probe-B at runtime:
    - If the pod is `SchedulingGated` (held): print the held evidence (PodScheduled=SchedulingGated,
      no nodeName), `trace_pause "🛑 STOP 2 — 파드가 스케줄링 직전 실제 대기 중 (SchedulingGated, 노드 미배치). Enter → gate 제거 → 스케줄러 배치"`,
      then remove the gate to release.
    - Else (placed despite the gate): print the HONEST degraded note and show the placement; then a
      normal `trace_pause` so the presenter can still narrate.
- **[step 4: placed]** Wait until the pod has `spec.nodeName` and PodScheduled=True. Print
  `nodeName` + that `ai-storage-scheduler` placed it. Final summary line.
- Exit 0 on success; non-zero with a clear message if a required step times out.

## Live verification (MUST, end to end)
Run the script non-interactively (off-TTY auto-continue, or feed Enter) once, all the way through:
confirm STOP 1 shows a real pending Workload with 0 pods; release admits it; the pod shows the
webhook-injected schedulerName + sidecar; STOP 2 behaves per Probe B (held-and-released, or
honest-degrade); the pod ends up scheduled on a node by ai-storage-scheduler; cleanup leaves no
`demo-admission-trace` objects and no leftover LocalQueue/node-label. Capture the key evidence.

## Constraints
Portable (local kubectl, no hardcoded node/IP — use detect_target_node only if you need a release
target node for a Probe-B fallback). Idempotent setup, full cleanup. HONESTY: the script's printed
claims must match what actually happens at runtime; STOP 2 must self-detect held-vs-placed and never
claim a hold that didn't occur. Match the package's existing script style (see
`02-scheduling/01-run-scheduling.sh`, `04-queue/01-run-queue.sh`, `lib/common.sh`).

## Report
Write full details (probe outcomes A & B, exact webhook-injected fields observed, STOP-1/STOP-2
evidence, scheduler hold behavior, cleanup confirmation) to
`/root/workspace/keti_ai_storage_orchestration/.sdd/task-2-report.md`.
Return only: STATUS, files created, one-line result + which mode STOP 2 used (held vs degraded).