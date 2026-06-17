#!/usr/bin/env bash
# image-list.txt 기준으로 컨테이너 이미지를 tar 로 저장한다.
#
# Author: 미정 <unknown@example.com>
# Created: 2026-05-28
#
# 설계 의도:
# - 인터넷 접근이 가능한 build 머신에서 docker pull → docker save 흐름을 자동화한다.
# - 폐쇄망 대상 서버에서는 본 스크립트 대신 import-images.sh 만 사용한다.

set -euo pipefail

IMAGES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIST_FILE="${IMAGES_DIR}/image-list.txt"
TAR_DIR="${TAR_DIR:-${IMAGES_DIR}/tar}"
PULL_FIRST="${PULL_FIRST:-true}"

log()  { printf '[save] %s\n' "$*"; }
fail() { printf '[save][FAIL] %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || fail "docker 명령이 필요합니다."
[[ -f "${LIST_FILE}" ]] || fail "이미지 목록 파일이 없습니다: ${LIST_FILE}"
mkdir -p "${TAR_DIR}"

while IFS=$' \t' read -r image tarname rest; do
  [[ -z "${image}" || "${image}" == \#* ]] && continue
  [[ -z "${tarname}" ]] && fail "image-list.txt 파싱 실패: '${image}' 줄에 tar 파일명이 없습니다."
  if [[ "${PULL_FIRST}" == "true" ]]; then
    log "pull ${image}"
    docker pull "${image}"
  fi
  out="${TAR_DIR}/${tarname}"
  log "save ${image} -> ${out}"
  docker save "${image}" -o "${out}"
done < "${LIST_FILE}"

log "완료. tar 파일 위치: ${TAR_DIR}"
ls -lh "${TAR_DIR}" || true
