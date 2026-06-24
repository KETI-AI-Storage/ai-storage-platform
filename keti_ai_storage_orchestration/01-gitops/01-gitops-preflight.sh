#!/usr/bin/env bash
# 01-gitops-preflight.sh — standalone prereq gate for the GitOps delivery stage.
#
# Clones the monorepo to $MONOREPO if absent (needs a GitHub token). Otherwise read-only:
# no cluster writes, no git pushes.
# Exits 0 only when ALL required prereqs are met.
# Each check prints PASS or a ❌ + a concrete remediation line.
#
# Usage:
#   bash 01-gitops/01-gitops-preflight.sh
#   MONOREPO=/my/path KUBECONFIG=/path/to/cluster.conf bash 01-gitops/01-gitops-preflight.sh
#
# Env vars consumed (all optional with defaults):
#   MONOREPO        path to the ai-storage-platform monorepo checkout
#                   (default: /tmp/ai-storage-platform)
#   GITHUB_TOKEN    GitHub personal access token (alternative to ~/.git-credentials)
#   KUBECONFIG      kubeconfig pointing at the cluster that runs ArgoCD
#                   (default: whatever kubectl resolves — usually ~/.kube/config)
#
# To skip this gate when calling 02-run-gitops.sh: SKIP_PREFLIGHT=1
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib/load-env.sh"

MONOREPO="${MONOREPO:-/tmp/ai-storage-platform}"
REPO="${REPO:-KETI-AI-Storage/ai-storage-platform}"
BRANCH="${BRANCH:-cicd-automation}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✅ PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ❌ FAIL: $1"; echo "       → $2"; }

echo "== gitops preflight =="
echo "   MONOREPO : ${MONOREPO}"
echo "   KUBECONFIG: ${KUBECONFIG:-(default ~/.kube/config)}"
echo "   context  : $(kubectl config current-context 2>/dev/null || echo '(none)')"
echo

# ------------------------------------------------------------------ [1] monorepo
echo "----- [1] monorepo present (clone if absent) -----"
if [ -d "${MONOREPO}/deploy" ]; then
  ok "monorepo present at ${MONOREPO} (has deploy/)"
else
  echo "  ⓘ not found at ${MONOREPO} → cloning ${REPO} (branch ${BRANCH}) from GitHub..."
  _t="${GITHUB_TOKEN:-}"
  if [ -z "${_t}" ]; then _c=$(grep -E 'github\.com' ~/.git-credentials 2>/dev/null | head -1); _c=${_c#*://}; _c=${_c%@github.com*}; _t=${_c##*:}; fi
  if [ -z "${_t}" ]; then
    bad "monorepo absent and no GitHub token to clone it" \
        "export GITHUB_TOKEN=ghp_xxx (or set up ~/.git-credentials), then re-run — or clone manually to ${MONOREPO}"
  elif git clone -q --branch "${BRANCH}" "https://${_t}@github.com/${REPO}.git" "${MONOREPO}" 2>/dev/null \
       && git -C "${MONOREPO}" remote set-url origin "https://github.com/${REPO}.git"; then
    ok "monorepo cloned to ${MONOREPO} (branch ${BRANCH}; token NOT stored in remote URL)"
  else
    bad "monorepo clone failed" \
        "check token/repo/network — or clone manually:  git clone https://github.com/${REPO}.git ${MONOREPO}"
  fi
fi

# ------------------------------------------------------------------ [2] github token
echo
echo "----- [2] GitHub token -----"
_token_found=0
if [ -n "${GITHUB_TOKEN:-}" ]; then
  _token_found=1
else
  # look for https://...:TOKEN@github.com in ~/.git-credentials
  if grep -qsE 'github\.com' ~/.git-credentials 2>/dev/null; then
    _tok=$(grep -E 'github\.com' ~/.git-credentials 2>/dev/null | head -1)
    _tok=${_tok#https://}; _tok=${_tok%@github.com*}; _tok=${_tok##*:}
    [ -n "${_tok}" ] && _token_found=1
  fi
fi
if [ "${_token_found}" -eq 1 ]; then
  ok "GitHub token available (GITHUB_TOKEN env or ~/.git-credentials)"
else
  bad "no GitHub token found" \
      "either: export GITHUB_TOKEN=ghp_xxx  OR  add 'https://user:ghp_xxx@github.com' to ~/.git-credentials"
fi

# ------------------------------------------------------------------ [3] kubectl reaches cluster
echo
echo "----- [3] kubectl + cluster connectivity -----"
if ! command -v kubectl >/dev/null 2>&1; then
  bad "kubectl not found on PATH" \
      "install kubectl: https://kubernetes.io/docs/tasks/tools/"
  echo
  echo "== preflight: PASS=${PASS}  FAIL=${FAIL} =="
  echo "❌ NOT READY — fix the ${FAIL} failing prereq(s) above then re-run."
  exit 1
fi

_ctx="$(kubectl config current-context 2>/dev/null || echo '')"
_server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo '')"
echo "    context : ${_ctx:-(none)}"
echo "    server  : ${_server:-(none)}"

if kubectl version >/dev/null 2>&1; then
  ok "kubectl reaches the cluster (context=${_ctx:-?}, server=${_server:-?})"
else
  bad "kubectl cannot reach the cluster" \
      "set KUBECONFIG=/path/to/the/cluster/kubeconfig (the cluster that runs ArgoCD); for a remote cluster copy its kubeconfig and ensure its API server (e.g. ${_server:-...:6443}) is reachable from here"
fi

# ------------------------------------------------------------------ [4] argocd namespace + CRD
echo
echo "----- [4] ArgoCD installed on the cluster -----"
if kubectl get ns argocd >/dev/null 2>&1; then
  ok "namespace argocd exists"
else
  bad "namespace argocd not found" \
      "install ArgoCD: kubectl create namespace argocd && kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"
fi
if kubectl get crd applications.argoproj.io >/dev/null 2>&1; then
  ok "ArgoCD Application CRD present (applications.argoproj.io)"
else
  bad "ArgoCD Application CRD (applications.argoproj.io) not found" \
      "ArgoCD is not installed or CRDs are missing; install ArgoCD on the target cluster first"
fi

# ------------------------------------------------------------------ summary
echo
echo "== preflight: PASS=${PASS}  FAIL=${FAIL} =="
if [ "${FAIL}" -eq 0 ]; then
  echo "✅ READY — all prereqs met."
  echo "   Run: bash 01-gitops/02-run-gitops.sh <component>   (e.g. cpu-eval)"
  echo "   For a remote cluster: KUBECONFIG=/path/to/cluster.conf bash 01-gitops/02-run-gitops.sh cpu-eval"
  exit 0
else
  echo "❌ NOT READY — fix the ${FAIL} failing prereq(s) above then re-run."
  exit 1
fi
