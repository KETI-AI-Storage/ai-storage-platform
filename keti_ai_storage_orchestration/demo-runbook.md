# KETI AI Storage — Orchestration Demo Runbook

A self-contained package to **install** the KETI AI Storage components on a cluster and
**demonstrate** the policy-driven autonomous orchestration (6 policy types), GitOps code
delivery, custom scheduling, and queue-based admission — with per-stage PASS/FAIL evidence.

> Honesty note: this runbook states exactly what is proven and at what depth. Capabilities
> are demonstrated at one of three levels — **① autonomous** (synthesize the situation, the
> system detects→decides→acts on its own), **② direct trigger** (call the action endpoint;
> proves the action code path runs but not that the autonomous chain fires it), **③ floor**
> (handler responds). Do not overstate. See the matrix at the end.

---

## 0. Layout (staged)

```
keti_ai_storage_orchestration/
  run-e2e.sh            # END-TO-END: runs the stages below in order
  demo-preflight.sh     # health + clean-slate gate (run before any demo)
  cleanup.sh            # remove demo artifacts (portable, local kubectl)
  demo-runbook.md       # this file
  lib/common.sh         # shared helpers (largest-worker auto-detect)
  00-install/
    01-install-components.sh   # wraps ai-storage-package installer (CRDs/stack/smoke)
  01-gitops/
    01-gitops-preflight.sh     # prereq gate; clones the monorepo to <pkg>/.monorepo if absent
    02-run-gitops.sh           # verify (read-only) the current GitOps delivery of a workload
    03-update-workload.sh      # modify a workload + arm queue/scheduling holds (default training-job)
    04-drive-demo.sh           # drive YOUR workload change: commit → CI (if build:true) → ArgoCD
    05-queue-release.sh        # 🛑 queue hold → release → admit → pod waits at scheduling
    gitops-e2e-verify.sh    run-image-workload-cicd.sh   # (helpers in the drive chain)
  02-scheduling/
    01-schedule-release.sh     # 🛑 scheduling → show webhook injection → release (label node) → placed → runs
                               #   (the same gitops workload continues here — the one-flow tail)
  03-orchestration/
    run-orchestration.sh    # runs all 6, one script each:
    01-migration.sh  02-scaling.sh  03-provisioning.sh
    04-preemption.sh 05-caching.sh  06-loadbalancing.sh
    lib/orchestration-e2e-verify.sh        # ① migration + scaling (POLICY_TYPE)
    lib/orchestration-capability-audit.sh  # ③ floor (6/6) + ② --deep (preempt/cache/lb/provision)
  tools/run-unit-tests.sh   # fast clusterless unit tier (~0.02s)
```

## 1. Prerequisites

- A Kubernetes cluster (1.25+) reachable via `kubectl` (this package uses the **local**
  kubectl — run it on the master or anywhere `KUBECONFIG` points at the target cluster).
- The installer package `ai-storage-package` available (sibling dir, `vendor/`, or
  `AI_STORAGE_PACKAGE_DIR`). It carries CRDs, Helm charts, RBAC, webhook cert, images.
- For the **GitOps** phase only: the GitHub monorepo + Docker Hub + ArgoCD must already be
  wired to this cluster (this is environment-specific and opt-in).

## 1b. Credentials

Tokens are **never committed** to this package (`.gitignore` excludes `*.env`, `.env`,
`secrets/`, `*-credentials*`, `*.token`, `*.key`, `kubeconfig*`).

### Two credential scopes

| Scope | Who needs it | Lifetime | How provided |
|---|---|---|---|
| **Cluster Secrets** (imagePull, ArgoCD repo) | Kubelet pulling images; ArgoCD syncing continuously | Persist in the cluster | `02-setup-credentials.sh` (run once at install time) |
| **Build-box / CI tokens** (GitHub push, Docker Hub push) | CI jobs building and pushing images | Runtime only | Env vars / `~/.git-credentials` / GitHub Actions repo secrets |

> "Set then delete" is wrong for continuous GitOps. Cluster Secrets must **persist** —
> ArgoCD needs the repo credential on every sync, and the kubelet needs the imagePullSecret
> on every pod start.

### Cluster Secrets — `00-install/02-setup-credentials.sh`

Run **once**, explicitly, after `01-install-components.sh`. It reads tokens from ENV and
creates Kubernetes Secrets via `dry-run=client|apply` (idempotent — safe to re-run).

Env vars it consumes:

```
# Docker Hub imagePullSecret (namespace: WORKLOAD_NS, default ai-storage-workloads)
DOCKERHUB_USER     Docker Hub username
DOCKERHUB_TOKEN    Docker Hub access token / password
DOCKERHUB_SECRET   secret name (default: dockerhub-pull-secret)
WORKLOAD_NS        space-separated namespace(s) (default: ai-storage-workloads)

# ArgoCD Git-repo credential (namespace: argocd — skipped if absent)
GIT_REPO_URL       repository URL  (e.g. https://github.com/org/repo)
GIT_USERNAME       git username
GIT_TOKEN          personal access token / password
ARGOCD_REPO_SECRET secret name (default: keti-ai-storage-repo-cred)
```

Example — set both in one call:

```bash
DOCKERHUB_USER=myuser DOCKERHUB_TOKEN=dckr_pat_xxx \
GIT_REPO_URL=https://github.com/KETI-AI-Storage/ai-storage-platform \
GIT_USERNAME=myuser GIT_TOKEN=ghp_yyy \
  bash 00-install/02-setup-credentials.sh
```

If **neither** group's vars are set, the script prints usage and exits 0 (no-op).

### Build-box / CI credentials

These are never stored in the package:
- **Local machine**: export `DOCKERHUB_USER` / `DOCKERHUB_TOKEN` in your shell, or use
  `docker login` and a `~/.docker/config.json`. For git push, use `~/.git-credentials`
  or an SSH key.
- **GitHub Actions**: store as repository **Secrets** (`DOCKERHUB_USER`, `DOCKERHUB_TOKEN`,
  `GIT_TOKEN`) and reference via `${{ secrets.NAME }}` in the workflow. The CI workflow in
  `.github/workflows/` already expects these names.

---

## 1c. Offline / USB bundle

This package can be carried on a USB drive to an air-gapped server. Drop a filled-in `.env`
into the bundle root and every entrypoint picks it up automatically — no script edits required.

### Steps

```bash
# 1. Copy the template and fill in real values (on the dev machine):
cp .env.example .env
$EDITOR .env

# 2. Optionally bundle the target cluster's kubeconfig alongside the package:
scp root@<master>:/etc/kubernetes/admin.conf ./kubeconfig
#    Then set in .env:  KUBECONFIG=./kubeconfig

# 3. Carry the USB to the air-gapped server. Run normally:
bash run-e2e.sh --install
```

Every entrypoint sources `lib/load-env.sh` early. When `.env` is present it prints:
```
(loaded .env from /path/to/keti_ai_storage_orchestration)
```
When `.env` is absent the loader is a silent no-op — existing behaviour is unchanged.

A relative `KUBECONFIG` (e.g. `./kubeconfig`) is automatically resolved to an absolute path
under the package root, so it is found regardless of your working directory.

### Security note

The bundle now carries credentials. Treat the USB as a secret:
- Store it physically securely (locked drawer / encrypted drive).
- Rotate all tokens (GitHub PAT, Docker Hub token) immediately after the demo.
- Delete `.env` and the bundled `kubeconfig` once the session is complete.

---

## 2. Quickstart

```bash
# fresh cluster, end to end:
bash run-e2e.sh --install

# already installed — just demonstrate:
bash run-e2e.sh

# one stage:
bash 03-orchestration/run-orchestration.sh    # all 6 policy types
bash 03-orchestration/01-migration.sh         # just one type
bash 01-gitops/02-run-gitops.sh cpu-eval         # GitOps delivery verify (needs the wiring above)
bash run-e2e.sh --only orchestration          # one stage via the e2e driver

# leave artifacts to inspect (skip auto-cleanup):
bash run-e2e.sh --keep

# PRESENTER real-stop ONE-FLOW — the SAME gitops workload physically stays held between scripts
# (🛑 queue, then 🛑 scheduling) until you run the next one. No flags.
bash 01-gitops/03-update-workload.sh cpu-eval      # modify workload + arm queue/scheduling holds
bash 01-gitops/04-drive-demo.sh                    # GitOps deploy → workload pends in the queue
bash 01-gitops/05-queue-release.sh                 # 🛑 queue → release → admit → 🛑 holds before scheduling
bash 02-scheduling/01-schedule-release.sh          # webhook shown → release (label node) → placed → runs
```

`run-e2e.sh` / `run-orchestration.sh` auto-detect the largest schedulable worker as
`TARGET_NODE`; override with `--target-node <name>` (e2e) or `TARGET_NODE=<name>` (env).

---

## 3. Phase-by-phase

### 3.0 Install (opt-in: `--install`)
`00-install/01-install-components.sh` → `ai-storage-package` (`install-crds.sh` → `install-stack.sh`
→ `run-install-smoke-test.sh`; `LOAD_IMAGES=1` to also load images on an air-gapped node).
**Proves:** components come up (forecaster, policy-engine, orchestrator, scheduler, webhook).

### 3.1 Preflight (`demo-preflight.sh`)
Gate: required components available + webhook present + workload namespace exists + clean
slate (no orphan migrated pods / provisioning PVCs). Optional: Kueue, ArgoCD (warn only).
Prints a suggested `TARGET_NODE`. **Exit 0 = ready.** If red → `bash cleanup.sh` or reinstall.

### 3.2 Orchestration — the 6 policy types

**① Autonomous — MIGRATION** (`orchestration-e2e-verify.sh`, `POLICY_TYPE=migration`)
Deploys a 2-container workload (one Completed + one Running) → applies CPU pressure >85% →
forecaster flags CRITICAL → policy-engine auto-generates a migration policy → orchestrator
migrates **only the running container** to another node (Completed excluded) → asserts
**CPU ~50% / Mem ~40% savings** + idempotency. Expected tail:
```
  ✅ PASS: CPU saving 49% ~= 50%
  ✅ PASS: Mem saving 39% ~= 40%
  ✅ ORCHESTRATION E2E (migration): ALL CHECKS PASSED
```

**① Autonomous — SCALING** (`orchestration-e2e-verify.sh`, `POLICY_TYPE=scaling`)
Deploys a Deployment sized into the STRESSED band (cpu_requests ~68%) → forecaster warning →
policy-engine auto-generates a scaling policy targeting the Deployment → orchestrator
**activates an autoscaler** (status=active) → asserts idempotency (N policies → 1 autoscaler).
```
  ✅ PASS: node cpu requests at 67% (STRESSED: 42-85%, NOT CRITICAL)
  ✅ PASS: autoscaler activated by autonomous chain: ...status=active...
  ✅ ORCHESTRATION E2E (scaling): ALL CHECKS PASSED
```
> Replica *count* only rises under real CPU **utilization** (idle workload stays at 1). That
> arithmetic is proven deterministically in `autoscaling_test.go::TestCalculateDesiredReplicas`,
> not by burning >node-capacity of CPU live. This phase proves the autonomous **wiring**.

**② Direct trigger — PREEMPTION + CACHING + LOADBALANCING** (`orchestration-capability-audit.sh --deep`)
First probes all 6 `/metrics` endpoints (③ floor, expect 6/6). Then directly POSTs a **safe**
request to each of the three and polls the job to a terminal state:
- preemption: `min_priority=int32min` → 0 candidates → `completed`, **0 evictions**
- loadbalancing: thresholds=100 → "already balanced" → `completed`, **0 migrations**
- caching: reads a source PVC (non-destructive) → `active` ("serving")
```
  operational: 6/6   down: 0/6
    ✅ preemption ACTION executed end-to-end (state=completed)
    ✅ caching ACTION executed end-to-end (state=active)
    ✅ loadbalancing ACTION executed end-to-end (state=completed)
  executed (action ran): 3 / 3
```
> ② proves the action code path RUNS — **not** that the forecaster→policy chain fires it.
> preemption needs GPU≥0.95 and caching/loadbalance need storage-I/O pressure, which cannot
> be synthesized here, so their **autonomous** trigger (①) is not demonstrated.

**PROVISIONING** co-fires during the SCALING phase: the GPU baseline sits in the warning band,
so the forecaster also emits a provisioning policy and the orchestrator **creates a real,
Bound PVC** for the workload (tier→StorageClass, WaitForFirstConsumer bound via a short binder
pod). So provisioning's autonomous action (①) is genuinely demonstrated — `cleanup.sh` removes
the PVC. Caveat: it is triggered by GPU-warning but its action is **storage** provisioning
(a trigger/action drift), and it always rides on the scaling load (never a real GPU situation).

### 3.3 GitOps one-flow — REAL stops at queue + scheduling (same workload, no flags)
The SAME gitops-deployed workload walks the whole admission path, **physically held at each control
point** so you can inspect the live state, then released by the NEXT script. Real Kubernetes holds,
not screen pauses. The flow spans `01-gitops/` (delivery + queue) → `02-scheduling/` (scheduling):
```
01-gitops/03-update-workload → 01-gitops/04-drive-demo → 01-gitops/05-queue-release → 02-scheduling/01-schedule-release
```

1. **03 + 04 arm + deploy:** `03` writes a current-time change AND arms both holds (queue-name →
   `demo-admission-queue`; pod `nodeSelector: keti.io/demo-hold`); `04` ships it via GitOps (CI → ArgoCD).
2. **🛑 STOP 1 — queue (real), `05-queue-release`:** the Kueue Workload is `Inadmissible` (no LocalQueue)
   → it genuinely waits with **0 pods**. Enter → `qh_release` creates the LocalQueue → Kueue admits →
   Job unsuspends → pod is created **but held at scheduling**.
3. **Webhook injection (pod level), shown by `01-schedule-release`:** the held pod shows
   `schedulerName=ai-storage-scheduler`, the injected `insight-trace` sidecar, and `storage.keti.io/*` annotations.
4. **🛑 STOP 2 — scheduling (real), `01-schedule-release`:** the pod has no feasible node
   (`nodeSelector: keti.io/demo-hold` absent) → it genuinely waits unscheduled. Enter → label a feasible
   node (the one matching the pod's other selectors, e.g. `nvidia.com/gpu`) → `ai-storage-scheduler`
   places a fresh pod → runs.

> **CAVEATS (state plainly):**
> - **Holds are demo-owned and safe:** the workload routes to `demo-admission-queue` (absent by default),
>   NOT the shared `ai-storage-queue`; the scheduling hold is a demo-only `keti.io/demo-hold` node label.
>   The flow only ever creates/deletes its OWN LocalQueue + node label — shared resources untouched.
> - The webhook acts at **pod-creation time** (at deploy the `kueue.x-k8s.io/queue-name` routing label is
>   author/platform-set). **`failurePolicy: Ignore`** — if the webhook server is unreachable, the pod is
>   **un-injected** (default-scheduler, no sidecar) with no error; `01-schedule-release` prints exactly
>   what was injected, so a missing sidecar/schedulerName is visible. Verify: `kubectl get pods -n keti -l app=ai-storage-webhook`.
> - `ai-storage-scheduler` **does not honor `schedulingGates`** (it tries to bind gated pods, the API
>   server rejects them) — so STOP 2 uses a **nodeSelector node-label hold**. Release just **labels the
>   node**; the scheduler re-queues the pending pod and binds it — **no pod deletion** (that would race the
>   in-flight bind AND count as a Job failure, fatal for a low `backoffLimit`). This is the honest mechanism.
> - GPU workloads (e.g. training-job) also need `nvidia.com/gpu=present` on the node (the installer
>   labels GPU nodes automatically); `01-schedule-release` picks a node satisfying the pod's selectors.
> - **Custom-scheduler scoring caveat:** basic placement works, but intelligent GPU/CSD-aware
>   *scoring* does NOT (LeastAllocated returns 0; real GPU pods stay Pending) — placement + admission,
>   not "smart scheduling".
> - STOP 1 demonstrates **Kueue Job admission** (Jobs only, not Deployments/Pods). The old standalone
>   `04-queue` queue demo is folded into this trace.

### 3.4 GitOps delivery (opt-in: `--gitops <component>`)
`gitops-e2e-verify.sh` verifies appconfig → CI image build → Docker Hub tag → ArgoCD
ApplicationSet app → Synced/Healthy → deployed image == built tag → webhook injection.
`run-image-workload-cicd.sh <comp>` drives the full code→CI→registry→redeploy loop.
> Needs the GitHub monorepo + Docker Hub + ArgoCD wired to this cluster. For a clean demo use
> a **Healthy** app (e.g. `cpu-eval`, `csd-preprocess`, `training-job`), not a blemished one.

#### Running from a different server (remote cluster targeting)

The GitOps scripts use **LOCAL kubectl** — no ssh. Copy the cluster's kubeconfig to the
machine that has the monorepo and GitHub token, then point `KUBECONFIG` at it:

```bash
# From any box with the monorepo at /tmp/ai-storage-platform and a token in ~/.git-credentials:
KUBECONFIG=/path/to/cluster.conf bash 01-gitops/02-run-gitops.sh cpu-eval
```

`02-run-gitops.sh` calls `01-gitops-preflight.sh` first; it checks the monorepo, token, kubectl
connectivity, and ArgoCD presence, and prints a concrete remediation line for each failure.
To bypass the gate (e.g. in CI where prereqs are guaranteed): `SKIP_PREFLIGHT=1`.

Env vars: `MONOREPO`, `REPO`, `BRANCH`, `REG`, `KUBECONFIG`, `SKIP_PREFLIGHT`, `GITHUB_TOKEN`.
Note: `kubeconfig*` is already in `.gitignore` — never commit cluster credentials.

---

## 4. Verification matrix (what is proven, at what depth)

| Policy | ① autonomous | ② direct | ③ floor | unit¹ | demonstrated as |
|---|:---:|:---:|:---:|:---:|---|
| migration     | ✅ | — | ✅ | ✅ | ① live: 50/40 savings, idempotent |
| scaling       | ✅ | — | ✅ | ✅ | ① live: autoscaler activated |
| provisioning  | ①* | — | ✅ | ✅ | ①* observed (co-fires on GPU-warn clusters; NOT harness-asserted) |
| preemption    | ✗  | ✅ | ✅ | ✗ | ② live: completed, 0 evictions |
| caching       | ✗  | ✅ | ✅ | ✗ | ② live: active / serving |
| loadbalancing | ✗  | ✅ | ✅ | ✗ | ② live: completed, 0 migrations |

¹ Unit tests live in the component source repos (`ai-storage-orchestrator`, `apollo/orchestration-policy-engine`)
  and run via `tools/run-unit-tests.sh` **only when those repos are checked out alongside this package** (not bundled).

**One-line truth:** all 6 respond (③) and have a real execution proof; **autonomy (①) is
*asserted* for migration and scaling (2/6)**; provisioning autonomy is *observed* but
cluster-dependent (only when the GPU forecast sits in the warning band) and **not
harness-asserted** — a silent provisioning regression would still print ALL-PASS;
preemption/caching/loadbalancing are proven at the **action level (②)** only — their
autonomous trigger needs GPU / storage-I/O pressure that cannot be synthesized on this hardware.

## 5. Known limitations (do not demo / state as caveats)
- **Real GPU workloads** stay Pending (GPU pod placement broken) — no live GPU scheduling.
- **Intelligent scheduler scoring** (LeastAllocated / GPU-CSD aware) returns 0 — not functional.
- **Kueue** gates Jobs only; not connected to continuous workloads.
- **`schedulingGates` are not honored** by `ai-storage-scheduler` (it binds gated pods, the API
  server rejects them, no retry). The admission trace's STOP 2 therefore uses a nodeSelector
  node-label hold, not a gate.
- **Admission-trace placement only:** on this cluster the lone worker is taint-degraded, so the
  trace proves scheduler *placement* (nodeName), not the pod reaching Running. Harmless tolerations
  carry it; a healthy cluster runs the pod.
- **MantaFS data plane** is a best-effort stub — caching/provisioning prove the K8s-native
  control path, not real cross-tier data movement.
- ArgoCD apps `cifar10-pipeline` / `ai-storage-pipeline` (OutOfSync) and `migration-test`
  (Degraded) are known-blemished — avoid them on stage.

## 6. Troubleshooting / evaluator Q&A
- **"Is it really autonomous?"** — Yes for migration/scaling/provisioning: the only input is
  load; the forecaster→policy-engine→orchestrator chain runs with no manual API call. The
  harness even forbids manual triggering. preemption/caching/lb are triggered directly (②).
- **"Why 0 evictions / 0 migrations in preemption/lb?"** — The ② payloads are safe-by-design
  (no real workload disrupted); they prove the action *runs*, observed reaching a terminal
  state. The decision arithmetic is unit-tested.
- **Pod stuck Pending** — `kubectl get pod <p> -o yaml | grep schedulerName` must be
  `ai-storage-scheduler`; check the four components with `demo-preflight.sh`.
- **Dirty results** — `bash cleanup.sh` then re-run; preflight must be green first.
