# keti_ai_storage_orchestration

Portable, **staged** install + demo package for the KETI AI Storage policy-driven orchestration.
Ship this directory to any Kubernetes cluster and demonstrate each capability stage by stage,
or end-to-end, with per-stage PASS/FAIL evidence. Runs against the **local** `kubectl` (no ssh).

## Stages

```
00-install/        01-install-components.sh        install the components (wraps ai-storage-package)
01-gitops/         03-update-workload.sh  04-drive-demo.sh  05-queue-release.sh
                     ONE-FLOW (same workload): deploy via GitOps -> 🛑 queue hold -> release -> admit
02-scheduling/     01-schedule-release.sh          ...the same workload continues here:
                     🛑 scheduling hold -> show webhook injection -> release (label node) -> placed -> runs
03-orchestration/  run-orchestration.sh         the 6 policy types, one script each:
                     01-migration.sh    ① autonomous  (50/40 savings)
                     02-scaling.sh      ① autonomous  (autoscaler) [provisioning ① co-fires]
                     03-provisioning.sh ② direct      (real PVC, cleaned up)
                     04-preemption.sh   ② direct      (0 evictions)
                     05-caching.sh      ② direct      (active/serving)
                     06-loadbalancing.sh ② direct     (0 migrations)
run-e2e.sh          end-to-end: runs the stages above in order
demo-preflight.sh   health + clean-slate gate (run before any demo)
cleanup.sh          remove demo artifacts
lib/common.sh       shared helpers (node auto-detect)
tools/              run-unit-tests.sh  (fast clusterless logic tests, ~0.02s)
demo-runbook.md     phase-by-phase commands, expected output, matrix, caveats, Q&A
```

## Quickstart

```bash
# whole thing on a fresh cluster (install -> demo -> clean):
bash run-e2e.sh --install

# already installed — demonstrate everything:
bash run-e2e.sh

# a single stage:
bash 03-orchestration/run-orchestration.sh        # all 6 policy types
bash 03-orchestration/01-migration.sh             # just one type
# the gitops ONE-FLOW (same workload: deploy -> 🛑queue -> 🛑scheduling -> placed):
bash 01-gitops/03-update-workload.sh cpu-eval && bash 01-gitops/04-drive-demo.sh \
  && bash 01-gitops/05-queue-release.sh && bash 02-scheduling/01-schedule-release.sh   # needs GitHub/Docker Hub/ArgoCD wired
bash run-e2e.sh --gitops cpu-eval                 # include gitops in the e2e

# gate / reset:
bash demo-preflight.sh
bash cleanup.sh
```

Runs against the **local** `kubectl` (point `KUBECONFIG` at the target cluster). The largest
schedulable worker is auto-detected as `TARGET_NODE` (override: `--target-node <name>`).

## Offline / USB bundle

Copy `.env.example` → `.env`, fill in credentials (and optionally drop the cluster's
`kubeconfig` into the bundle and set `KUBECONFIG=./kubeconfig`), then run normally on the
air-gapped server. See **[demo-runbook.md § 1c](demo-runbook.md#1c-offline--usb-bundle)** for
full steps and a security note. `.env` is gitignored and will never be committed.

## Requirements
- Kubernetes 1.25+ reachable via `kubectl`; `python3` on PATH
- `ai-storage-package` available for `--install` (sibling dir, `vendor/`, or `AI_STORAGE_PACKAGE_DIR`)
- GitOps stage only: GitHub monorepo + Docker Hub + ArgoCD wired to the cluster

## GitOps stage — remote cluster targeting

The GitOps stage uses **LOCAL kubectl** (no ssh). To target a cluster whose ArgoCD you want
to verify, point `KUBECONFIG` at that cluster's kubeconfig:

```bash
# Run from any machine that has the monorepo + a GitHub token
KUBECONFIG=/path/to/cluster.conf bash 01-gitops/02-run-gitops.sh cpu-eval
```

A standalone prereq gate (`01-gitops-preflight.sh`) runs first and prints PASS/FAIL with
remediation guidance. Set `SKIP_PREFLIGHT=1` to bypass it.

### GitOps env vars

| Var | Default | Purpose |
|---|---|---|
| `KUBECONFIG` | `~/.kube/config` | kubeconfig for the cluster running ArgoCD |
| `MONOREPO` | `/tmp/ai-storage-platform` | path to the ai-storage-platform monorepo checkout |
| `REPO` | `KETI-AI-Storage/ai-storage-platform` | GitHub repo slug |
| `BRANCH` | `cicd-automation` | branch to check CI runs against |
| `REG` | `ketidevit2` | Docker Hub organisation |
| `SKIP_PREFLIGHT` | `0` | set to `1` to skip the prereq gate |
| `GITHUB_TOKEN` | *(reads `~/.git-credentials`)* | GitHub PAT for API calls |

Note: `kubeconfig*` is in `.gitignore` — never commit cluster credentials.

See **[demo-runbook.md](demo-runbook.md)** for the full matrix (what is proven at what depth),
known limitations, and evaluator Q&A.
