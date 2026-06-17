#!/usr/bin/env bash
# package-setup-10-forecaster-version0.1.sh는 Forecaster(node-resource-forecaster) 설치/버전을 kubectl 결과로 출력한다.
#
# Author: 미정 <unknown@example.com>
# Created: 2026-05-28

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../02.keti-orchestration-module/lib/common-log.sh"
keti_component_status "Forecaster Status" "node-resource-forecaster" ""
