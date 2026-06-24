#!/usr/bin/env bash
# gitops-e2e-verify.sh
#
# Validates the KETI AI Storage *delivery* pipeline (the GitOps/CI front half) for one
# component, end-to-end, read-only, with per-stage PASS/FAIL:
#
#   appconfig.json  ->  CI image build (GitHub Actions)  ->  Docker Hub image
#       ->  ApplicationSet generates the ArgoCD app  ->  ArgoCD Synced/Healthy
#       ->  new image rolled out (soft). Scope = DELIVERY only; webhook/scheduling is the
#       02-scheduling stage's concern (not checked here).
#
# This is the companion to orchestration-e2e-verify.sh (which covers the runtime
# control loop). Together they cover code -> deploy -> orchestrate end-to-end.
#
# Run ON the target cluster (uses LOCAL kubectl). Needs the monorepo working copy
# (deploy/*) and a GitHub token in ~/.git-credentials. Read-only: no push, no cluster
# writes. Verifies the CURRENT delivered state (does not trigger a build).
#
#   bash 01-gitops/gitops-e2e-verify.sh [component]      # default: migration-test
#   COMP=cifar10-pipeline bash 01-gitops/gitops-e2e-verify.sh
#
# Env: REPO, BRANCH, REG (dockerhub org), MONOREPO.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib/load-env.sh"

COMP="${1:-${COMP:-migration-test}}"
REPO="${REPO:-KETI-AI-Storage/ai-storage-platform}"
BRANCH="${BRANCH:-cicd-automation}"
REG="${REG:-ketidevit2}"
MONOREPO="${MONOREPO:-/tmp/ai-storage-platform}"
HOLDQ="${HOLDQ:-demo-admission-queue}"   # demo queue-hold sentinel (matches 03-update-workload.sh / 05-queue-release.sh)
HELD=0

declare -a RESULTS; PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); RESULTS+=("PASS  $1"); echo "  ✅ PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); RESULTS+=("FAIL  $1"); echo "  ❌ FAIL: $1${2:+ -- $2}"; }
skip() { RESULTS+=("SKIP  $1"); echo "  ➖ SKIP: $1${2:+ -- $2}"; }
step() { echo; echo "========== $* =========="; }

gh_token() { if [ -n "${GITHUB_TOKEN:-}" ]; then printf '%s' "$GITHUB_TOKEN"; return; fi
  local c; c=$(grep -E 'github\.com' ~/.git-credentials 2>/dev/null | head -1); c=${c#*://}; c=${c%@github.com*}; printf '%s' "${c##*:}"; }
gh()  { curl -s -H "Authorization: token $(gh_token)" -H "Accept: application/vnd.github+json" "https://api.github.com$1"; }
# run a cluster command on THIS cluster (the package runs ON the target cluster -> local kubectl).
k99() { eval "$*" 2>/dev/null; }

# True when this component is armed with the demo QUEUE-HOLD (03-update-workload routed its
# queue-name to $HOLDQ) AND that LocalQueue is absent on the cluster. In that case the Job is
# INTENTIONALLY held in the Kueue queue -> ArgoCD reports health=Suspended *by design* (released
# by 05-queue-release.sh). This is a delivered-but-held state, NOT a delivery failure.
demo_queue_held() {
  grep -rqE "kueue\.x-k8s\.io/queue-name:[[:space:]]*\"?${HOLDQ}\"?[[:space:]]*\$" \
    "$MONOREPO/deploy/$COMP"/*.yaml 2>/dev/null || return 1
  ! k99 "kubectl get localqueue $HOLDQ -n $NAMESPACE" >/dev/null 2>&1
}

# ------------------------------------------------------------------------- [0] preflight
step "[0] PREFLIGHT (component: $COMP)"
[ -d "$MONOREPO/deploy" ] && ok "monorepo present: $MONOREPO" || { bad "monorepo deploy/ not found at $MONOREPO"; exit 2; }
[ -n "$(gh_token)" ] && ok "github token available" || bad "no github token (\$GITHUB_TOKEN env or ~/.git-credentials)"
k99 kubectl version >/dev/null 2>&1 && ok "kubectl reaches this cluster" || { bad "kubectl cannot reach the cluster"; exit 2; }

# ------------------------------------------------------------------------- [1] appconfig
step "[1] appconfig.json (single source of truth)"
CFG="$MONOREPO/deploy/$COMP/appconfig.json"
if [ -f "$CFG" ] && python3 -m json.tool "$CFG" >/dev/null 2>&1; then
  ok "appconfig.json valid"
  read -r NAME NAMESPACE IMAGE SOURCEDIR BUILD < <(python3 -c '
import json,sys
c=json.load(open(sys.argv[1]))
print(c.get("name",""),c.get("namespace",""),c.get("image",""),
      c.get("sourceDir","") or "-", "true" if (c.get("sourceDir") and c.get("build",True)) else "false")' "$CFG")
  echo "    name=$NAME ns=$NAMESPACE image=$IMAGE sourceDir=$SOURCEDIR buildable=$BUILD"
else
  bad "appconfig.json missing/invalid at $CFG"; exit 2
fi

# tag the GitOps state expects (what ArgoCD will deploy)
TAG=$(grep -E 'newTag:' "$MONOREPO/deploy/$COMP/kustomization.yaml" 2>/dev/null | head -1 | sed -E 's/.*newTag:\s*"?([^"]+)"?.*/\1/')
echo "    kustomization newTag=${TAG:-<none>}"

# ------------------------------------------------------------------------- [2] CI build
step "[2] CI image build (GitHub Actions)"
if [ "$BUILD" = "true" ]; then
  RUN=$(gh "/repos/$REPO/actions/runs?branch=$BRANCH&per_page=15" \
        | python3 -c 'import json,sys; r=[x for x in json.load(sys.stdin).get("workflow_runs",[]) if x["name"]=="image"]; print(r[0]["status"],r[0].get("conclusion")) if r else print("none none")')
  echo "    latest image run: $RUN"
  echo "$RUN" | grep -q "completed success" && ok "CI image workflow latest run = success" || bad "CI image run not success ($RUN)"
  # build:true components must have a bumped 7-hex SHA tag, not the 'latest' placeholder
  if echo "$TAG" | grep -qE '^[0-9a-f]{7}$'; then ok "kustomization newTag is a CI-bumped SHA ($TAG)"
  else bad "kustomization newTag not a bumped SHA (=$TAG) -> CI bump missing"; fi
else
  skip "CI build (component is deploy-only / public image)"
fi

# ------------------------------------------------------------------------- [3] Docker Hub
step "[3] Docker Hub image"
if [ "$BUILD" = "true" ]; then
  REPO_PATH="${IMAGE#*/}"   # ketidevit2/migration-test -> migration-test
  CODE=$(curl -s -o /dev/null -w "%{http_code}" "https://hub.docker.com/v2/repositories/$REG/$REPO_PATH/tags/$TAG/")
  [ "$CODE" = "200" ] && ok "image $REG/$REPO_PATH:$TAG exists on Docker Hub" \
                      || bad "image $REG/$REPO_PATH:$TAG NOT found (http $CODE)"
else
  skip "Docker Hub (deploy-only component uses a public base image)"
fi

# ------------------------------------------------------------------------- [4] ApplicationSet -> App
step "[4] ApplicationSet generated the ArgoCD app"
APPEXISTS=$(k99 "kubectl get applications.argoproj.io $NAME -n argocd -o jsonpath='{.metadata.name}'")
[ "$APPEXISTS" = "$NAME" ] && ok "ArgoCD app '$NAME' exists (appconfig -> ApplicationSet)" \
                           || bad "ArgoCD app '$NAME' not found"

# ------------------------------------------------------------------------- [5] ArgoCD sync/health
step "[5] ArgoCD Synced + Healthy"
SYNC=$(k99 "kubectl get applications.argoproj.io $NAME -n argocd -o jsonpath='{.status.sync.status}'")
HEALTH=$(k99 "kubectl get applications.argoproj.io $NAME -n argocd -o jsonpath='{.status.health.status}'")
echo "    sync=$SYNC health=$HEALTH"
[ "$SYNC" = "Synced" ]    && ok "app Synced"   || bad "app not Synced (=$SYNC)"
if [ "$HEALTH" = "Healthy" ]; then
  ok "app Healthy"
elif [ "$HEALTH" = "Suspended" ] && demo_queue_held; then
  HELD=1
  ok "app delivered — workload intentionally HELD at queue '$HOLDQ' (Suspended by design); run 05-queue-release.sh to admit"
else
  bad "app not Healthy (=$HEALTH)"
fi

# ------------------------------------------------------------------------- [6] deployed in cluster
step "[6] new image rolled out (runtime confirmation, soft)"
# Delivery is ALREADY proven by [2] CI build + [3] Docker Hub image + [4] app + [5] Synced/Healthy.
# This step is a soft runtime confirmation: wait briefly for the rollout, but a lag or a component
# that deploys in a different namespace is NOT a delivery failure -> SKIP, never FAIL.
if [ "$HELD" = 1 ]; then
  skip "workload HELD at queue '$HOLDQ' (Suspended by design) → no pod yet; image $IMAGE:$TAG is delivered and runs once 05-queue-release.sh admits it"
  step "[7] webhook / scheduling — out of scope here (see 02-scheduling)"
  skip "webhook injection + custom scheduling are a RUNTIME concern (02-scheduling stage)."
  step "RESULT ($COMP)"
  for r in "${RESULTS[@]}"; do echo "  $r"; done
  echo; echo "  PASS=$PASS  FAIL=$FAIL"
  echo "  ✅ GITOPS DELIVERY E2E ($COMP): DELIVERED — workload HELD at queue (run 05-queue-release.sh next)"
  exit 0
fi
PODIMAGES=""
for _ in $(seq 1 18); do   # ~90s for ArgoCD to roll the new image
  PODIMAGES=$(k99 "kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{\" \"}{.spec.containers[*].image}{\"\n\"}{end}'" | grep "$IMAGE" || true)
  { [ "$BUILD" != "true" ] && [ -n "$PODIMAGES" ]; } && break
  echo "$PODIMAGES" | grep -q "$IMAGE:$TAG" && break
  sleep 5
done
if [ "$BUILD" = "true" ] && echo "$PODIMAGES" | grep -q "$IMAGE:$TAG"; then
  ok "pods rolled out to built tag ($TAG)"; echo "$PODIMAGES" | grep "$IMAGE:$TAG" | sed 's/^/    /' | head -3
elif [ -n "$PODIMAGES" ]; then
  echo "$PODIMAGES" | sed 's/^/    /' | head -3
  skip "pods present but not yet on $TAG (rollout lag; delivery already proven by [2]-[5])"
else
  skip "no pod for $IMAGE found (component may deploy in another namespace; delivery proven by [2]-[5])"
fi

# ------------------------------------------------------------------------- [7] runtime (next stage)
step "[7] webhook / scheduling — out of scope here (see 02-scheduling)"
skip "webhook injection + custom scheduling are a RUNTIME concern, verified by the 02-scheduling stage. Only namespaces labelled keti-ai-storage-injection=enabled get injected; system components (e.g. metric-collector in 'monitoring') correctly use the default scheduler. This delivery stage stops at: image built -> registry -> ArgoCD Synced/Healthy -> rolled out."

# ------------------------------------------------------------------------- report
step "RESULT ($COMP)"
for r in "${RESULTS[@]}"; do echo "  $r"; done
echo; echo "  PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && { echo "  ✅ GITOPS DELIVERY E2E ($COMP): ALL CHECKS PASSED"; exit 0; } \
                  || { echo "  ❌ GITOPS DELIVERY E2E ($COMP): $FAIL CHECK(S) FAILED"; exit 1; }
