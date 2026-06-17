#!/usr/bin/env bash
# package-setup-00-environment-version0.1.sh는 Environment Runtime 통합 상태를 kubectl 결과 기반으로 출력한다.
#
# 출력 블록은 common-log.sh의 env_runtime_status가 책임지며,
# namespace/노드/버전은 어떤 값도 하드코딩하지 않고 kubectl로 자동 탐색한다.
#
# Author: 미정 <unknown@example.com>
# Created: 2026-05-28

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../02.keti-orchestration-module/lib/common-log.sh"
env_runtime_status
