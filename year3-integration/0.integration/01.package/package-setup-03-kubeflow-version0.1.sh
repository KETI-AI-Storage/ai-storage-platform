#!/usr/bin/env bash
# package-setup-03-kubeflow-version0.1.sh는 Kubeflow 설치 namespace/버전을 후보 검색 결과 기반으로 출력한다.
#
# Author: 미정 <unknown@example.com>
# Created: 2026-05-28

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../02.keti-orchestration-module/lib/common-log.sh"
component_status kubeflow "Kubeflow Status"
