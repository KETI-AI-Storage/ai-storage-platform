#!/usr/bin/env bash
# 03-provisioning.sh — PROVISIONING (storage tiering).
# ② direct trigger: POST /provisioning -> orchestrator provisions a tier StorageClass PVC
# (+ binder pod for WaitForFirstConsumer), polls to terminal, then removes the PVC.
# Proves the provisioning ACTION runs end-to-end.
# NOTE: provisioning ALSO fires AUTONOMOUSLY (①) during 02-scaling (GPU-warning band) where it
# creates a real Bound PVC with no manual call — that is the stronger, policy-driven evidence.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib/load-env.sh"
exec bash "$HERE/lib/orchestration-capability-audit.sh" --deep provisioning
