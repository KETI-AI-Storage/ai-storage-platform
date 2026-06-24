#!/usr/bin/env bash
# 02-run-gitops.sh — demonstrate GitOps code delivery: CI build -> Docker Hub -> ArgoCD -> deployed.
#
#   bash 02-run-gitops.sh [component]                   # verify current delivery (read-only)
#   bash 02-run-gitops.sh --drive <component> ["msg"]   # drive the FULL code->CI->registry->redeploy loop
#
# Verify mode checks: appconfig -> CI image run success -> Docker Hub tag -> ArgoCD app
# Synced/Healthy -> deployed image == built tag -> webhook injection (gitops-e2e-verify.sh).
# Drive mode commits the component's source, waits for CI, the newTag bump, then verifies
# (run-image-workload-cicd.sh) — run on the build box with the monorepo + a GitHub token.
#
# PREREQ: the GitHub monorepo + Docker Hub + ArgoCD must be wired to THIS cluster.
# For a clean demo pick a Healthy app (e.g. cpu-eval, csd-preprocess, training-job).
#
# REMOTE CLUSTER TARGETING (KUBECONFIG):
#   This script uses LOCAL kubectl — no ssh. To target a remote cluster's ArgoCD, copy
#   its kubeconfig to this machine and point KUBECONFIG at it:
#     KUBECONFIG=/path/to/cluster.conf bash 01-gitops/02-run-gitops.sh cpu-eval
#   Note: kubeconfig* is in .gitignore — never commit cluster credentials.
#
# ENV VARS:
#   MONOREPO        path to the ai-storage-platform monorepo checkout
#                   (default: /tmp/ai-storage-platform)
#   REPO            GitHub repo  (default: KETI-AI-Storage/ai-storage-platform)
#   BRANCH          Git branch   (default: cicd-automation)
#   REG             Docker Hub org (default: ketidevit2)
#   KUBECONFIG      kubeconfig for the cluster running ArgoCD (standard kubectl env var)
#   SKIP_PREFLIGHT  set to 1 to skip the prereq gate (e.g. in CI where prereqs are guaranteed)
#   GITHUB_TOKEN    GitHub PAT (alternative to ~/.git-credentials)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib/load-env.sh"

DRIVE=0
if [ "${1:-}" = "--drive" ]; then DRIVE=1; shift; fi
COMP="${1:-cpu-eval}"

echo "== GitOps delivery demo: $COMP (mode=$([ "$DRIVE" = 1 ] && echo drive || echo verify)) =="

# ------------------------------------------------------------------ prereq gate
if [ "${SKIP_PREFLIGHT:-0}" != "1" ]; then
  if ! bash "$HERE/01-gitops-preflight.sh"; then
    echo
    echo "❌ Prereq gate failed — fix the issues above and re-run."
    echo "   To skip this gate: SKIP_PREFLIGHT=1 bash 01-gitops/02-run-gitops.sh $COMP"
    exit 1
  fi
  echo
fi

# ------------------------------------------------------------------ dispatch
if [ "$DRIVE" = 1 ]; then
  exec bash "$HERE/run-image-workload-cicd.sh" "$COMP" "${2:-}"
else
  exec bash "$HERE/gitops-e2e-verify.sh" "$COMP"
fi
