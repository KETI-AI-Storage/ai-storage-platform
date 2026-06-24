#!/usr/bin/env bash
# 02-setup-credentials.sh — create persistent cluster Secrets for GitOps/imagePull.
#
# Tokens are read from ENV ONLY and NEVER written to disk or echoed in full.
# Re-running this script is safe (idempotent via dry-run|apply).
# This script is OPT-IN — the installer does not call it automatically.
#
# Env vars consumed:
#
#   Docker Hub imagePullSecret (workload namespace):
#     DOCKERHUB_USER   — Docker Hub username
#     DOCKERHUB_TOKEN  — Docker Hub access token / password
#     DOCKERHUB_SECRET — secret name   (default: dockerhub-pull-secret)
#     WORKLOAD_NS      — target namespace(s), space-separated (default: ai-storage-workloads)
#
#   ArgoCD Git-repo credential (argocd namespace):
#     GIT_REPO_URL     — repository URL  (e.g. https://github.com/org/repo)
#     GIT_USERNAME     — git username
#     GIT_TOKEN        — personal access token / password
#     ARGOCD_REPO_SECRET — secret name (default: keti-ai-storage-repo-cred)
#
# Usage:
#   DOCKERHUB_USER=myuser DOCKERHUB_TOKEN=mytoken bash 00-install/02-setup-credentials.sh
#   GIT_REPO_URL=https://github.com/org/repo GIT_USERNAME=user GIT_TOKEN=ghp_... \
#     bash 00-install/02-setup-credentials.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib/load-env.sh"

ok(){  echo "  ✅ $1"; }
bad(){ echo "  ❌ $1"; }
say(){ echo "[credentials] $*"; }

# defaults
DOCKERHUB_SECRET="${DOCKERHUB_SECRET:-dockerhub-pull-secret}"
WORKLOAD_NS="${WORKLOAD_NS:-ai-storage-workloads}"
ARGOCD_REPO_SECRET="${ARGOCD_REPO_SECRET:-keti-ai-storage-repo-cred}"

have_dockerhub=0
have_git=0

[[ -n "${DOCKERHUB_USER:-}" && -n "${DOCKERHUB_TOKEN:-}" ]] && have_dockerhub=1
[[ -n "${GIT_REPO_URL:-}" && -n "${GIT_USERNAME:-}" && -n "${GIT_TOKEN:-}" ]] && have_git=1

if [[ "$have_dockerhub" -eq 0 && "$have_git" -eq 0 ]]; then
  say "No credentials env vars set — nothing to do."
  echo
  echo "  Set one or both of the following groups, then re-run:"
  echo
  echo "  Docker Hub imagePullSecret:"
  echo "    DOCKERHUB_USER=<user> DOCKERHUB_TOKEN=<token> \\"
  echo "      [DOCKERHUB_SECRET=<name>] [WORKLOAD_NS=<ns>] \\"
  echo "      bash $0"
  echo
  echo "  ArgoCD Git-repo credential:"
  echo "    GIT_REPO_URL=<url> GIT_USERNAME=<user> GIT_TOKEN=<token> \\"
  echo "      [ARGOCD_REPO_SECRET=<name>] \\"
  echo "      bash $0"
  exit 0
fi

command -v kubectl >/dev/null 2>&1 || { bad "kubectl not on PATH"; exit 1; }
kubectl version >/dev/null 2>&1   || { bad "kubectl cannot reach a cluster"; exit 1; }
say "target cluster: $(kubectl config current-context 2>/dev/null || echo '?')"
echo

# ── Docker Hub imagePullSecret ─────────────────────────────────────────────
if [[ "$have_dockerhub" -eq 1 ]]; then
  say "── Docker Hub imagePullSecret ──"
  for ns in $WORKLOAD_NS; do
    if ! kubectl get ns "$ns" >/dev/null 2>&1; then
      bad "namespace '$ns' not found — skipping imagePullSecret for $ns"
      continue
    fi
    if kubectl create secret docker-registry "$DOCKERHUB_SECRET" \
      --namespace="$ns" \
      --docker-server="https://index.docker.io/v1/" \
      --docker-username="$DOCKERHUB_USER" \
      --docker-password="$DOCKERHUB_TOKEN" \
      --dry-run=client -o yaml \
    | kubectl apply -f - >/dev/null; then
      ok "imagePullSecret '$DOCKERHUB_SECRET' applied in namespace '$ns'"
    else
      bad "failed to apply imagePullSecret '$DOCKERHUB_SECRET' in '$ns'"; exit 1
    fi
  done
  echo
  echo "  NOTE: Deployments or ServiceAccounts that pull from Docker Hub must reference"
  echo "  this secret. Either add it to the ServiceAccount's imagePullSecrets:"
  echo "    kubectl patch serviceaccount default -n <ns> \\"
  echo "      -p '{\"imagePullSecrets\":[{\"name\":\"$DOCKERHUB_SECRET\"}]}'"
  echo "  or reference it directly in the Pod spec (imagePullSecrets field)."
  echo
fi

# ── ArgoCD Git-repo credential ─────────────────────────────────────────────
if [[ "$have_git" -eq 1 ]]; then
  say "── ArgoCD Git-repo credential ──"
  if ! kubectl get ns argocd >/dev/null 2>&1; then
    say "  ⚠️  namespace 'argocd' not found — skipping ArgoCD repo credential."
    say "  Install ArgoCD first, then re-run this script."
  else
    if kubectl create secret generic "$ARGOCD_REPO_SECRET" \
      --namespace=argocd \
      --from-literal=type=git \
      --from-literal=url="$GIT_REPO_URL" \
      --from-literal=username="$GIT_USERNAME" \
      --from-literal=password="$GIT_TOKEN" \
      --dry-run=client -o yaml \
    | kubectl label --local -f - \
        "argocd.argoproj.io/secret-type=repository" -o yaml \
    | kubectl apply -f - >/dev/null; then
      # belt-and-suspenders: ensure label is present on pre-existing secrets too
      kubectl label secret "$ARGOCD_REPO_SECRET" -n argocd \
        "argocd.argoproj.io/secret-type=repository" \
        --overwrite >/dev/null
      ok "ArgoCD repo credential '$ARGOCD_REPO_SECRET' applied in namespace 'argocd'"
    else
      bad "failed to apply ArgoCD repo credential '$ARGOCD_REPO_SECRET' in 'argocd'"; exit 1
    fi
    echo "  Repository URL: $GIT_REPO_URL"
    echo "  ArgoCD will pick this up automatically (no restart required)."
    echo
  fi
fi

say "Done. Secrets persist in the cluster — no deletion required for continuous GitOps."
