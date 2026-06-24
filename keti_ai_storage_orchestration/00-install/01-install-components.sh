#!/usr/bin/env bash
# 01-install-components.sh — install the KETI AI Storage components onto the CURRENT cluster.
#
# This wraps the canonical installer that ships in `ai-storage-package` (CRDs, namespaces,
# RBAC, webhook cert, Helm charts, images). It does NOT reinvent the install — it locates
# the package and runs its scripts in order, then a smoke test.
#
# The package is located via (first that exists):
#   1) $AI_STORAGE_PACKAGE_DIR
#   2) <this-package>/vendor/ai-storage-package   (bundle it here to ship fully self-contained)
#   3) <workspace>/ai-storage-package             (sibling checkout)
#   4) /root/workspace/ai-storage-package
#
# Usage (run where kubectl targets the TARGET cluster):
#   bash 00-install/01-install-components.sh              # crds -> stack -> smoke
#   LOAD_IMAGES=1 bash 00-install/01-install-components.sh # also load container images first
#   AI_STORAGE_PACKAGE_DIR=/path/to/pkg bash 00-install/01-install-components.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib/load-env.sh"
PKG_ROOT="$(cd "$HERE/.." && pwd)"
WS="$(cd "$PKG_ROOT/.." && pwd)"
LOAD_IMAGES="${LOAD_IMAGES:-0}"

say(){ echo "[install] $*"; }
die(){ echo "[install] ❌ $*" >&2; exit 1; }

# locate the installer package
APKG=""
for c in "${AI_STORAGE_PACKAGE_DIR:-}" "$PKG_ROOT/vendor/ai-storage-package" "$WS/ai-storage-package" "/root/workspace/ai-storage-package"; do
  [ -n "$c" ] && [ -d "$c/scripts" ] && { APKG="$c"; break; }
done
[ -n "$APKG" ] || die "ai-storage-package not found. Set AI_STORAGE_PACKAGE_DIR or bundle it at $PKG_ROOT/vendor/ai-storage-package"
S="$APKG/scripts"
say "using installer package: $APKG"

command -v kubectl >/dev/null 2>&1 || die "kubectl not on PATH"
kubectl version >/dev/null 2>&1 || die "kubectl cannot reach a cluster (configure KUBECONFIG)"
say "target cluster: $(kubectl config current-context 2>/dev/null || echo '?')"

run_step() {  # run_step "label" script.sh [args...]
  local label="$1" script="$2"; shift 2
  if [ ! -f "$S/$script" ]; then say "⚠️ skip $label — $script not in package"; return 0; fi
  say "── $label ($script) ──"
  if bash "$S/$script" "$@"; then say "✅ $label done"; else die "$label FAILED ($script) — see output above"; fi
}

# 1) container images (optional — only needed on an air-gapped/fresh node)
[ "$LOAD_IMAGES" = "1" ] && run_step "load images" load-images.sh

# 2) CRDs (OrchestrationPolicy etc.)
run_step "install CRDs" install-crds.sh

# 3) namespaces / RBAC / webhook cert / Helm charts (the components themselves)
run_step "install stack" install-stack.sh

# 4) smoke test (rollout health)
run_step "smoke test" run-install-smoke-test.sh

# 5) label GPU nodes so GPU workloads (nodeSelector nvidia.com/gpu=present) can schedule. Auto-detects
#    nodes that advertise nvidia.com/gpu capacity (the device plugin) — portable, no hardcoded names.
say "── label GPU nodes (nvidia.com/gpu=present) ──"
_gpunodes="$(kubectl get nodes -o json 2>/dev/null | python3 -c '
import json,sys
for n in json.load(sys.stdin).get("items",[]):
    cap=n.get("status",{}).get("capacity",{}).get("nvidia.com/gpu")
    try: c=int(cap)
    except (TypeError,ValueError): c=0
    if c>0: print(n["metadata"]["name"])')"
if [ -n "$_gpunodes" ]; then
  for n in $_gpunodes; do
    kubectl label node "$n" nvidia.com/gpu=present --overwrite >/dev/null 2>&1 && say "  labeled $n (nvidia.com/gpu=present)"
  done
else
  say "  (GPU 노드 없음 — nvidia.com/gpu capacity를 advertise하는 노드 없음; device plugin 설치 후 재실행하면 라벨됨)"
fi

say "✅ component installation complete. Next: bash ../demo-preflight.sh"
say "   For GitOps, provide credentials via 00-install/02-setup-credentials.sh (env-driven)."
