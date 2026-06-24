# SDD Progress Ledger — Real-Stop Admission Pipeline Demo

Branch: cicd-automation. Package (untracked): /root/workspace/keti_ai_storage_orchestration/

- Task 1 (queue-hold lib + LocalQueue manifest): COMPLETE (review clean; spec ✅, quality approved; Important self-test-guard finding fixed → QH_SELFTEST env; live pend→release→admit verified). Files: 04-queue/lib/queue-hold.sh, 04-queue/demo-admission-queue-job.yaml. API: qh_ensure_no_localqueue / qh_wait_pending JOB [t]→echoes wl / qh_release / qh_wait_admitted JOB [t] / qh_cleanup / qh_workload_for JOB. Env QH_NS(=ai-storage-workloads)/QH_LQ/QH_CQ.
- Task 2 (admission-trace script + scheduling-hold probe): COMPLETE (DONE_WITH_CONCERNS; live E2E passed). Files: 02-scheduling/02-admission-trace.sh, 02-scheduling/demo-admission-trace-job.yaml. Probe A: webhook does NOT inject queue-name on bare Jobs (author-set) — webhook acts at POD creation. Probe B: ai-storage-scheduler IGNORES schedulingGates (binds gated pod→API rejects→no retry) → STOP 2 uses nodeSelector keti.io/demo-hold node-label hold + pod recreate on release. Worker is taint-degraded → tolerations + placement-only.
- Task 3 (run-demo.sh capstone + cleanup): COMPLETE (controller-authored, not gratuitously editing 01-gitops; run-demo owns the gitops→admission→orchestration boundary). Files: run-demo.sh (NEW), cleanup.sh (added demo=admission-trace block: job/pods/LocalQueue/demo-hold node label). syntax + refs verified.
- Task 4 (docs: RUN-ORDER.md + demo-runbook.md): COMPLETE. RUN-ORDER §3-A admission-trace + run-demo in "한 번에". demo-runbook 3.3b + quickstart + limitations (gates-not-honored, placement-only).

99 LIVE VALIDATION (2026-06-23): run-demo.sh --skip-gitops on KUBECONFIG=~/.kube/config-99 → exit 0. admission-trace PASS (demo-admission-queue Inadmissible→admit, webhook S3 tier+sidecar, csd-server-01 placed) + orchestration migration 21/21 (CPU49/Mem39). cleanup OK.
POST-REVIEW SAFETY FIX (critical, found by running on 99): queue-hold toggled the SHARED ai-storage-queue — fine on 80 (absent) but DESTRUCTIVE on 99 (real+in-use). Switched to DEMO-OWNED `demo-admission-queue` (QH_LQ default + manifest queue-name + cleanup + Task1 fixture). Never touches the shared queue. Also: run-demo now prints API SERVER URL (80/99 share context name 'kubernetes-admin@kubernetes'; only server URL distinguishes — this was the wrong-cluster trap).
NOTE: first run was accidentally against 80 (default ctx, degraded: worker-01 dead, orchestrator demo-paramsv3=404). Memory keti-ai-storage-test-env warned of exactly this. Corrected to 99.

FINAL REVIEW: done (integration). Integration sequence/honesty/cleanup = correct. 2 Important + 4 Minor, ALL FIXED: I-1 ORCH_SEL unquote comment; I-2 manifest toleration portability note (kept for this degraded cluster, documented to delete on healthy); M-1 --help awk range (no code leak); M-2 cleanup pod singular; M-4/5 --skip-gitops SKIP summary entry. Re-validated: syntax OK, --help clean, manifest valid.

Minor findings (for final review triage):
- T1: queue-hold.sh uses an embedded python3 snippet for ownerReference UID match (brief said jsonpath). Accepted — project style already uses python3 (common.sh). No fix.
- T2-M1: step-1 prints a hardcoded "webhook WILL inject S3 tier..." prediction; step-3 shows live truth. Could drift. Narrative-only, acceptable.
- T2-M2: comment near detect_target_node says it "picks ai-storage-master" — misleading (control-plane LABEL is excluded); logic correct (worker-label selector picks worker-01 first). Cosmetic.
- T2-M3: manifest tolerations are this-cluster-specific (unreachable/cilium-not-ready); harmless no-ops on healthy clusters. Documented.
