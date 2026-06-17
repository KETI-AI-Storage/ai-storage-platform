#!/usr/bin/env bash
# images/tar/*.tar 를 컨테이너 런타임에 import 한다.
#
# Author: 미정 <unknown@example.com>
# Created: 2026-05-28
#
# 설계 의도:
# - 폐쇄망 대상 서버에서 ctr (containerd, k8s.io namespace) 우선, 없으면 docker load 로 동작한다.
# - CONTAINER_RUNTIME=auto|ctr|docker 로 강제 선택 가능.
# - 인자로 tar 디렉터리 경로를 받을 수 있으며, 기본값은 스크립트 위치의 tar/ 디렉터리이다.

set -euo pipefail

DEFAULT_TAR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tar"
TAR_DIR="${1:-${DEFAULT_TAR_DIR}}"
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-auto}"

log()  { printf '[import] %s\n' "$*"; }
fail() { printf '[import][FAIL] %s\n' "$*" >&2; exit 1; }

resolve_runtime() {
  case "${CONTAINER_RUNTIME}" in
    ctr)    command -v ctr    >/dev/null 2>&1 || fail "ctr 가 없습니다.";    echo "ctr";;
    docker) command -v docker >/dev/null 2>&1 || fail "docker 가 없습니다."; echo "docker";;
    auto)
      if command -v ctr >/dev/null 2>&1;    then echo "ctr"
      elif command -v docker >/dev/null 2>&1; then echo "docker"
      else fail "ctr 또는 docker 가 필요합니다."
      fi
      ;;
    *) fail "CONTAINER_RUNTIME 값이 잘못되었습니다: ${CONTAINER_RUNTIME}";;
  esac
}

main() {
  [[ -d "${TAR_DIR}" ]] || fail "tar 디렉터리가 없습니다: ${TAR_DIR}"
  if ! compgen -G "${TAR_DIR}/*.tar" >/dev/null; then
    log "import 대상 tar 파일이 없습니다: ${TAR_DIR}/*.tar"
    return 0
  fi

  local runtime
  runtime="$(resolve_runtime)"
  log "runtime=${runtime} target=${TAR_DIR}"

  for tar_path in "${TAR_DIR}"/*.tar; do
    log "import ${tar_path}"
    if [[ "${runtime}" == "ctr" ]]; then
      # WHY: kubelet 이 사용하는 namespace 는 k8s.io 이므로 다른 namespace 에 import 하면
      #      kubectl run/apply 시점에 ErrImageNeverPull 이 발생한다.
      ctr -n k8s.io images import "${tar_path}"
    else
      docker load -i "${tar_path}"
    fi
  done
  log "완료."
}

main "$@"
