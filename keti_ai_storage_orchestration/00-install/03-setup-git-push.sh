#!/usr/bin/env bash
# 03-setup-git-push.sh — make `git push` work on a FRESH environment for this project's monorepo.
#
# GitHub does NOT let a script mint a token from just a username (security). You create a Personal
# Access Token (PAT) ONCE at github.com → Settings → Developer settings → Personal access tokens
# (classic; scope: repo). This script then verifies it has push rights, stores it, and wires git to
# use it — so on any new box, one run = push-ready. If the `gh` CLI is installed and no token is
# given, it logs you in via GitHub's DEVICE FLOW (you enter a code in a browser) and gets a token
# for you — no manual PAT needed.
#
# Inputs (env / .env / interactive prompt):
#   GITHUB_USER   your GitHub username
#   GITHUB_TOKEN  PAT with `repo` scope (push access to REPO)
#   GIT_NAME / GIT_EMAIL   (optional) commit author identity
#   REPO          owner/repo to verify push on (default KETI-AI-Storage/ai-storage-platform)
#
#   bash 00-install/03-setup-git-push.sh                                    # interactive
#   GITHUB_USER=me GITHUB_TOKEN=ghp_xxx bash 00-install/03-setup-git-push.sh  # or via .env / env
#
# The token is read from env/prompt, stored ONLY in ~/.git-credentials (chmod 600), never echoed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib/load-env.sh"
REPO="${REPO:-KETI-AI-Storage/ai-storage-platform}"
ok(){ echo "  ✅ $1"; }; bad(){ echo "  ❌ $1"; }; say(){ echo "[setup-git-push] $*"; }

USER_IN="${GITHUB_USER:-}"
TOKEN_IN="${GITHUB_TOKEN:-}"

# no token + gh available -> device-flow login (no manual PAT)
if [ -z "$TOKEN_IN" ] && command -v gh >/dev/null 2>&1; then
  say "no GITHUB_TOKEN; 'gh' CLI found → device-flow login (enter the code in a browser)."
  if gh auth login --hostname github.com --git-protocol https; then
    gh auth setup-git 2>/dev/null || true
    TOKEN_IN="$(gh auth token 2>/dev/null || true)"
    USER_IN="${USER_IN:-$(gh api user -q .login 2>/dev/null || true)}"
  fi
fi

# else interactive prompt (token hidden)
[ -n "$USER_IN" ]  || read -rp  "GitHub username: " USER_IN
[ -n "$TOKEN_IN" ] || { read -rsp "GitHub PAT (repo scope, hidden): " TOKEN_IN; echo; }
[ -n "$USER_IN" ] && [ -n "$TOKEN_IN" ] || { bad "username and token are required"; exit 1; }

# verify token + push permission via API (NO push performed)
say "verifying token against github.com ..."
LOGIN=$(curl -s -H "Authorization: token $TOKEN_IN" https://api.github.com/user \
  | python3 -c 'import json,sys; print(json.load(sys.stdin).get("login",""))' 2>/dev/null)
[ -n "$LOGIN" ] || { bad "token invalid (GitHub /user returned no login)"; exit 1; }
ok "token authenticates as: $LOGIN"
PUSH=$(curl -s -H "Authorization: token $TOKEN_IN" "https://api.github.com/repos/$REPO" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin).get("permissions",{}).get("push"))' 2>/dev/null)
[ "$PUSH" = "True" ] && ok "push permission on $REPO = True" \
  || { bad "no push permission on $REPO (permissions.push=$PUSH) — use a token from an account with write access"; exit 1; }

# store credential + wire git to use it (this is what was missing → fixes the 'Username for ...' prompt)
printf 'https://%s:%s@github.com\n' "$USER_IN" "$TOKEN_IN" > ~/.git-credentials
chmod 600 ~/.git-credentials
git config --global credential.helper store
ok "wrote ~/.git-credentials (chmod 600) + git credential.helper=store"
[ -n "${GIT_NAME:-}" ]  && { git config --global user.name  "$GIT_NAME";  ok "git user.name=$GIT_NAME"; }
[ -n "${GIT_EMAIL:-}" ] && { git config --global user.email "$GIT_EMAIL"; ok "git user.email=$GIT_EMAIL"; }

echo
say "✅ git push is READY. Next: 01-gitops/01-gitops-preflight.sh → 03-update-workload.sh → 04-drive-demo.sh"
