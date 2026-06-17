#!/usr/bin/env bash
# package-setup-05-ai-storage-scheduler-version0.1.sh는 AI Storage Scheduler 설치/버전을 kubectl 결과로 출력한다.
#
# Author: 미정 <unknown@example.com>
# Created: 2026-05-28

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../02.keti-orchestration-module/lib/common-log.sh"
keti_component_status \
  "AI Storage Scheduler Status" \
  "ai-storage-scheduler" \
  "${REPO_DIR}/year3-integration/package/ai-storage-integration-package/manifests/03-scheduler/ai-storage-scheduler.yaml"
