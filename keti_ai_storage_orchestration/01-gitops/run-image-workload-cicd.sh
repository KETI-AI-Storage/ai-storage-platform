#!/usr/bin/env bash
# run-image-workload-cicd.sh — drive ONE image-built workload through the full
# code -> CI build -> Docker Hub -> ArgoCD -> deployed loop, with per-stage status.
#
# This is the IMAGE-workload lane (custom image built by your GitHub Actions CI on
# the build-80 runner), as opposed to the inline-manifest internal-git lane
# (auto-run-keti-orchestration.sh on the cluster, where code lives inline in the Workflow YAML).
#
#   <edit a component's source under the monorepo, then:>
#   bash 01-gitops/run-image-workload-cicd.sh                  # builds the component you changed
#   COMP=<component> bash 01-gitops/run-image-workload-cicd.sh   # force a specific one (env, not a flag)
#
# Flow:
#   [1] stage + commit + push the component's source/deploy to GitHub (cicd-automation)
#   [2] wait for the `image` CI run (build-80 -> Docker Hub) to succeed
#   [3] wait for CI's kustomization newTag bump to the new commit SHA
#   [4] hand off to gitops-e2e-verify.sh -> ArgoCD Synced/Healthy + deployed image tag
#
# Run where you have the monorepo working copy + a GitHub token in ~/.git-credentials,
# and LOCAL kubectl pointed at the target cluster. The git commit is made under YOUR
# git identity (run it yourself).
#
# Env: REPO, BRANCH, MONOREPO, TIMEOUT_CI, POLL.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib/load-env.sh"
source "$HERE/../lib/common.sh"
REPO="${REPO:-KETI-AI-Storage/ai-storage-platform}"
BRANCH="${BRANCH:-cicd-automation}"
MONOREPO="${MONOREPO:-/tmp/ai-storage-platform}"
# No flag/argument: build the component whose CODE YOU CHANGED (git). Honors a component passed by the
# internal chain (02-run-gitops --drive) or COMP env; otherwise auto-detects it from the git changes.
COMP="${1:-${COMP:-$(detect_changed_workload)}}"
MSG="${2:-${MSG:-deploy(${COMP:-?}): update workload code}}"
[ -n "$COMP" ] || { echo "❌ no changed buildable component in $MONOREPO — edit a component's source first, or set COMP=<dir>."; exit 1; }
TIMEOUT_CI="${TIMEOUT_CI:-1200}"   # CI build can take minutes (first base-image pull)
POLL="${POLL:-15}"

step(){ echo; echo "========== $* =========="; }
ok(){ echo "  ✅ $1"; }
die(){ echo "  ❌ $1"; exit 1; }
gh_token(){ if [ -n "${GITHUB_TOKEN:-}" ]; then printf '%s' "$GITHUB_TOKEN"; return; fi
  local c; c=$(grep -E 'github\.com' ~/.git-credentials 2>/dev/null | head -1); c=${c#*://}; c=${c%@github.com*}; printf '%s' "${c##*:}"; }
gh(){ curl -s -H "Authorization: token $(gh_token)" -H "Accept: application/vnd.github+json" "https://api.github.com$1"; }

cd "$MONOREPO" 2>/dev/null || die "monorepo not found at $MONOREPO"

step "[0] PREFLIGHT ($COMP)"
[ -n "$(gh_token)" ] || die "no GitHub token (\$GITHUB_TOKEN env or ~/.git-credentials)"
CFG="deploy/$COMP/appconfig.json"
[ -f "$CFG" ] || die "no $CFG (is the component name right?)"
read -r NAME SRC IMG BUILD < <(python3 -c '
import json,sys
c=json.load(open(sys.argv[1]))
src=c.get("sourceDir") or "-"
print(c.get("name",""), src, c.get("image","-"),
      "true" if (c.get("sourceDir") and c.get("build",True)) else "false")' "$CFG")
echo "  name=$NAME sourceDir=$SRC image=$IMG build=$BUILD branch=$BRANCH"
[ "$BUILD" = "true" ] && echo "  build:true → CI builds the image" \
                       || echo "  build:false → manifest-only workload; ArgoCD syncs (no CI image build)"
[ "$(git branch --show-current)" = "$BRANCH" ] || echo "  WARN: current branch != $BRANCH"

step "[1] COMMIT + PUSH code"
git add "deploy/$COMP" >/dev/null 2>&1 || true
[ "$SRC" != "-" ] && [ -d "$SRC" ] && git add "$SRC" >/dev/null 2>&1
PUSHED=0
if git diff --cached --quiet; then
  echo "  ⓘ no staged changes -> nothing new to build."
  echo "    To exercise the build, modify ${SRC}/ FIRST (e.g. edit ${SRC}/train.py), then re-run."
  echo "    Proceeding to VERIFY the current delivery of $COMP only (skipping build/bump)."
else
  git commit -q -m "$MSG" || die "git commit failed"
  git fetch -q origin "$BRANCH" 2>/dev/null || true
  git rebase -q "origin/$BRANCH" 2>/dev/null || die "rebase conflict vs origin/$BRANCH — resolve and retry"
  git push -q origin "$BRANCH" || die "git push failed"
  PUSHED=1
  SHA="$(git rev-parse HEAD)"; SHORT="${SHA:0:7}"
  ok "pushed $SHORT to $BRANCH"
  echo "    🔗 commit:  https://github.com/$REPO/commit/$SHORT"
fi

if [ "$PUSHED" = 1 ] && [ "$BUILD" = "true" ]; then
  step "[2] CI image build (GitHub Actions on build-80 -> Docker Hub)"
  echo "    🔗 Actions: https://github.com/$REPO/actions?query=branch%3A$BRANCH"
  t=0; ST=""; CC=""; RUNID=""; URL_SHOWN=0
  while [ "$t" -lt "$TIMEOUT_CI" ]; do
    read -r RUNID ST CC < <(gh "/repos/$REPO/actions/runs?head_sha=$SHA&per_page=10" | python3 -c '
import json,sys
rs=[r for r in json.load(sys.stdin).get("workflow_runs",[]) if r.get("name")=="image"]
print(rs[0]["id"], rs[0]["status"], rs[0].get("conclusion")) if rs else print("- pending -")')
    echo "  t=${t}s  image run=$RUNID  status=$ST  conclusion=$CC"
    if [ "$URL_SHOWN" = 0 ] && [[ "$RUNID" =~ ^[0-9]+$ ]]; then
      echo "    🔗 watch this run: https://github.com/$REPO/actions/runs/$RUNID"; URL_SHOWN=1
    fi
    [ "$ST" = "completed" ] && break
    sleep "$POLL"; t=$((t+POLL))
  done
  [ "$CC" = "success" ] || die "CI image build did not succeed (status=$ST conclusion=$CC). Check the run on GitHub."
  ok "CI image build succeeded (run $RUNID)"

  step "[3] CI kustomization newTag bump -> $SHORT"
  t=0; NT=""
  while [ "$t" -lt 300 ]; do
    git fetch -q origin "$BRANCH" 2>/dev/null || true
    NT="$(git show "origin/$BRANCH:deploy/$COMP/kustomization.yaml" 2>/dev/null \
          | sed -nE 's/.*newTag:[[:space:]]*"?([0-9a-f]{7,40})"?.*/\1/p' | head -1)"
    echo "  t=${t}s  kustomization newTag=$NT (want $SHORT)"
    [ "${NT:0:7}" = "$SHORT" ] && break
    sleep 10; t=$((t+10))
  done
  [ "${NT:0:7}" = "$SHORT" ] || die "CI did not bump $COMP tag to $SHORT (saw $NT). Did ${SRC}/ actually change?"
  git rebase -q "origin/$BRANCH" 2>/dev/null || true   # pull the [skip ci] bump locally
  ok "kustomization bumped to $SHORT"
elif [ "$PUSHED" = 1 ]; then
  echo; echo "========== [2-3] SKIPPED (build:false workload — manifest pushed; ArgoCD syncs, no CI image) =========="
else
  echo; echo "========== [2-3] SKIPPED (nothing new pushed) =========="
fi

step "[4] ArgoCD deploy + verification"
echo "  -> handing off to gitops-e2e-verify.sh $COMP"
bash "$HERE/gitops-e2e-verify.sh" "$COMP"
rc=$?

echo
if [ "$rc" -eq 0 ]; then
  if [ "$PUSHED" = 1 ] && [ "$BUILD" = "true" ]; then
    echo "✅ WORKLOAD CI/CD ($COMP): code -> CI -> Docker Hub -> ArgoCD -> deployed @ ${SHORT}"
  elif [ "$PUSHED" = 1 ]; then
    echo "✅ WORKLOAD DELIVERY ($COMP): manifest pushed @ ${SHORT} -> ArgoCD synced/healthy (build:false, no CI image)"
  else
    echo "✅ DELIVERY VERIFIED ($COMP): current deployment is healthy. (No new change pushed —"
    echo "   modify the workload's manifest/source and re-run to drive a new deploy.)"
  fi
else
  echo "⚠️  delivery verification reported issues for $COMP (see above)."
fi
exit "$rc"
