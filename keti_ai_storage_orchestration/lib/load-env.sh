#!/usr/bin/env bash
# load-env.sh — auto-load <package-root>/.env if it exists.
#
# SOURCE this file (do NOT execute it). It is set -uo pipefail-safe.
# It must NOT call exit or set -e (it is sourced by the caller's shell).
#
# Usage (from any depth):
#   source "$HERE/lib/load-env.sh"          # from package root
#   source "$HERE/../lib/load-env.sh"       # from a first-level subdirectory
#   source "$HERE/../../lib/load-env.sh"    # etc.
#
# What it does:
#   1. Computes the package root from this file's own location (lib/..)
#      — correct regardless of which entrypoint sources it.
#   2. Sources <package-root>/.env with set -a / set +a so every var is
#      automatically exported to child processes.
#   3. If KUBECONFIG was set to a relative path, resolves it to an absolute
#      path under the package root (so a bundled kubeconfig is found regardless
#      of the caller's cwd). Empty or already-absolute KUBECONFIG is left alone.
#   4. Prints a one-line "(loaded .env)" note when it loads.
#   5. Is a silent no-op when .env is absent — existing behaviour is unchanged.

_lenv_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_lenv_file="$_lenv_root/.env"

if [ -f "$_lenv_file" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$_lenv_file"
  set +a

  # Resolve a relative KUBECONFIG to an absolute path under the package root.
  # Guard: KUBECONFIG may be unset in a set -u shell, so use the ${var:-} form.
  _lenv_kc="${KUBECONFIG:-}"
  if [ -n "$_lenv_kc" ] && [[ "$_lenv_kc" != /* ]]; then
    # Strip a leading ./ if present, then prepend the package root.
    _lenv_kc="${_lenv_kc#./}"
    KUBECONFIG="$_lenv_root/$_lenv_kc"
    export KUBECONFIG
  fi

  echo "(loaded .env from $_lenv_root)"
fi

# Default the monorepo to a package-internal, PERSISTENT path (NOT /tmp — that is ephemeral and lives
# outside the package). 01-gitops clones the ai-storage-platform monorepo here, so everything stays
# self-contained under the package. Override via MONOREPO env or .env. (Kept out of git via .gitignore.)
export MONOREPO="${MONOREPO:-$_lenv_root/.monorepo}"

unset _lenv_root _lenv_file _lenv_kc
