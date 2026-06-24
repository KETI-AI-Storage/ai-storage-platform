#!/usr/bin/env bash
# run-unit-tests.sh — fast, no-cluster unit tests for the core orchestration logic.
#
# DEV TOOL — REQUIRES SOURCE REPOS: this script reaches into the component source modules
# (ai-storage-orchestrator, apollo/orchestration-policy-engine) as siblings of this package
# directory. Those repos are NOT bundled inside this demo package. Run this only when both
# source repos are checked out alongside the package (i.e. ROOT/../ai-storage-orchestrator
# and ROOT/../apollo/orchestration-policy-engine exist).
#
# Verifies the DECISION logic behind the project's claims in milliseconds (no cluster,
# no load, no autonomous-chain waiting):
#
#   policy-engine generator (internal/generator):
#     - migration target SUITABILITY  (infra/controller/distroless excluded;
#                                       already-migrated product excluded = re-migration guard)
#     - #10 namespace whitelist
#     - target resolution             (migration -> pod name, others -> deployment name)
#     - findTargetWorkload            (picks the right pod among distractors; fake clientset)
#     - TestCalculateDesiredReplicas  (scaling replica arithmetic: util -> desired replicas)
#     - TestProvisioning*             (provisioning policy coverage)
#   orchestrator k8s (pkg/k8s):
#     - buildOptimizedPodSpec         (completed containers EXCLUDED = the 50/40 saving)
#     - checkpoint-volume dedup       (re-migration does not duplicate the volume)
#     - GetPodContainerStates         (waiting/completed -> drop, running/failed -> migrate)
#
# Use this on EVERY code change. Reserve the E2E harnesses (orchestration-e2e-verify.sh /
# gitops-e2e-verify.sh) for integration — they need a live cluster and take minutes.
#
#   bash tools/run-unit-tests.sh
#
# Toolchain handling: the policy-engine module requires go >= 1.24.6. Each module is run
# with the go it was already built with, so re-runs reuse the build cache instead of a
# fresh (memory-heavy) re-link:
#   - orchestrator (module go 1.21) -> the system `go`
#   - policy-engine (needs 1.24.6)  -> a cached go1.24.6 toolchain binary if present
# On a normal machine (no cached toolchain) it just uses `go`, letting it fetch 1.24.6.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORCH="$ROOT/ai-storage-orchestrator"
PENG="$ROOT/apollo/orchestration-policy-engine"

SYS_GO="$(command -v go)"
CACHED_1246="$(ls -d /root/go/pkg/mod/golang.org/toolchain@*go1.24.6*/bin/go 2>/dev/null | head -1)"
PENG_GO="${CACHED_1246:-$SYS_GO}"

# Offline pins only when we have a cached toolchain (this air-gapped env). On a normal
# machine these stay empty so `go` may fetch the toolchain / verify modules normally.
TC=""; OFF=""
if [ -n "$CACHED_1246" ]; then TC="GOTOOLCHAIN=local"; OFF="GOPROXY=off"; fi

gotest() { # GOBIN DIR PKG RUN-REGEX
  ( cd "$2" && env $TC GOFLAGS=-mod=mod $OFF "$1" test "$3" -run "$4" -count=1 )
}

echo "== KETI AI Storage core-logic unit tests =="
[ -n "$CACHED_1246" ] && echo "(offline: policy-engine via cached $PENG_GO)"
fail=0

echo; echo "----- orchestrator :: pkg/k8s -----"
gotest "$SYS_GO" "$ORCH" ./pkg/k8s/ \
  'TestBuildOptimizedPodSpec|TestGetPodContainerStates' || fail=1

echo; echo "----- policy-engine :: internal/generator -----"
gotest "$PENG_GO" "$PENG" ./internal/generator/ \
  'TestMigrationUnsuitableReason|TestIsWorkloadNamespace|TestResolveTargetWorkloadForRecommendation|TestFindTargetWorkload|TestCalculateDesiredReplicas|TestProvisioning' || fail=1

echo
if [ "$fail" = 0 ]; then echo "✅ UNIT TESTS PASSED"; else echo "❌ UNIT TESTS FAILED"; fi
exit "$fail"
