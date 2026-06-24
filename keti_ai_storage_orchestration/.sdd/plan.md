# Plan — Real-Stop Admission Pipeline Demo

## Goal
A demo where the workload **physically halts at real Kubernetes control points**, mapping to
the presenter's narrative:

```
gitops (build + ArgoCD deploy)  → [REAL STOP]
webhook injects annotations + workload waits in queue  → [REAL STOP]
scheduling (custom scheduler places it)
orchestration (autonomous trigger — NO stop)
```

A "stop" is not a cosmetic Enter-pause: the workload is genuinely held at a Kubernetes
control point and `Enter` triggers the **real release action**.

## Verified cluster facts (2026-06-23, server v1.32.6)
- Demo namespace = `ai-storage-workloads` (label `keti-ai-storage-injection=enabled`; webhook = `ai-storage-webhook`, 2 webhooks).
- `ai-storage-workloads` has **NO LocalQueue** → any Kueue Workload there is
  `QuotaReserved=False :: Inadmissible :: LocalQueue ai-storage-queue doesn't exist`.
  This is a **reliable, real queue hold**. RELEASE = create LocalQueue `ai-storage-queue` → ClusterQueue `ai-storage-cluster-queue`.
- ClusterQueue `ai-storage-cluster-queue` exists (flavors default/csd/gpu).
- Custom scheduler = Deployment `keti/ai-storage-scheduler`. Plugins per ARCHITECTURE.md: **NodeResourcesFit (filter) only**;
  LeastAllocated score returns 0. It MAY NOT honor `schedulingGates` or nodeAffinity → **must probe live**.
- Schedulable worker = `ai-storage-worker-01` (32c). `ai-storage-master`=control-plane (excluded), `gpu-worker-server01`=cordoned.
- A pre-existing stranded `job-queue-verify-*` Workload sits pending in ai-storage-workloads (same root cause). Creating the LocalQueue will also admit it — acceptable; delete that stale demo job at setup for a clean stage.

## Global constraints (the reviewer's lens — copy verbatim into reviews)
- **Local kubectl only.** No hardcoded node/IP. Discover where possible; use `lib/common.sh:detect_target_node` for the worker.
- All demo objects named `demo-admission-*` and labeled `demo=admission-trace`. Setup idempotent; **full cleanup** of everything created.
- **HONESTY (non-negotiable):** state which mechanism actually holds each stage. If a pre-scheduling hold cannot be achieved against `ai-storage-scheduler`, **degrade the scheduling stop to a live observation and say so explicitly** — never imply a hold that isn't real. No greenwashing.
- `Enter` (via `pause_if` from `lib/common.sh`) triggers the REAL release action, not just a screen pause.
- **Do not disrupt non-demo workloads.** No cluster-wide cordon. No deleting other people's resources. Only touch `demo=admission-trace` objects + the `ai-storage-queue` LocalQueue.
- Webhook touches the workload at TWO points (faithful framing): (a) Job/route level BEFORE the queue (queue-name label + tier hints — this is what lets the queue route it), (b) Pod level at pod creation AFTER admit (schedulerName + insight-trace sidecar). The trace must show whatever the webhook ACTUALLY injects, at whichever object level, observed live.

## Tasks
1. **Queue-hold library + LocalQueue manifest** (`04-queue/`) — reliable pend→admit, live-verified.
2. **Admission-trace script + Job manifest** (`02-scheduling/`) — webhook-diff + queue-hold (from Task 1) + scheduling-hold (probe). Full live trace: real stop at queue (guaranteed) → real stop at scheduling (best-effort hold, else live+honest) → placed.
3. **Capstone `run-demo.sh`** (top level) gitops→trace→orchestration with the presenter's pause structure + `01-gitops` end banner + `cleanup.sh` updates for `demo=admission-trace`.
4. **Docs** — `RUN-ORDER.md` + `demo-runbook.md` updated for the new real-stop flow, with the honest mechanism notes.
