#!/bin/sh
# migration-test workload entrypoint.
#
# One image, two roles selected by $MODE — this is what makes the pod a clean
# migration-savings demo:
#   preprocess : do bounded work, then exit 0  -> becomes a COMPLETED container.
#                The orchestrator EXCLUDES completed containers when it builds the
#                optimized pod, so this container's CPU/mem request is the saving.
#   serve      : run indefinitely               -> the RUNNING container that is
#                actually carried over to the target node.
set -eu

MODE="${MODE:-serve}"
echo "[migration-test] mode=${MODE} pod=${POD_NAME:-?} node=${NODE_NAME:-?}"

case "${MODE}" in
  preprocess)
    echo "[migration-test] preprocess: working ..."
    sleep 20
    echo "[migration-test] preprocess: done -> exit 0 (will show as Completed)"
    exit 0
    ;;
  serve)
    echo "[migration-test] serve: running indefinitely (migration target)"
    while true; do
      sleep 30
      echo "[migration-test] serve: heartbeat"
    done
    ;;
  *)
    echo "[migration-test] unknown MODE=${MODE}" >&2
    exit 1
    ;;
esac
