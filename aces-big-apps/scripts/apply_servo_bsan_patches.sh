#!/usr/bin/env bash
# Apply Servo patches needed for BSAN (idempotent). Does not modify BSAN itself.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

SERVO_DIR="${1:-${APPS_DIR}/servo-xpath}"
SOURCE="${ACES_ROOT}/patches/servo_library_handle.bsan.rs"
TARGET="${SERVO_DIR}/components/fonts/platform/freetype/library_handle.rs"
STAMP="${SERVO_DIR}/.aces-bsan-patches.stamp"

[[ -d "${SERVO_DIR}" ]] || die "Missing Servo checkout: ${SERVO_DIR}"
[[ -f "${SOURCE}" ]] || die "Missing patch source: ${SOURCE}"
[[ -f "${TARGET}" ]] || die "Missing ${TARGET}"

patch_hash="$(sha256sum "${SOURCE}" | awk '{print $1}')"
if [[ -f "${STAMP}" ]] && grep -q "${patch_hash}" "${STAMP}"; then
  if ! grep -q 'usable_size' "${TARGET}" && grep -q 'FREETYPE_ALLOC_SIZES' "${TARGET}"; then
    log "Servo BSAN patches already applied (${patch_hash:0:12}…)"
    exit 0
  fi
  log "WARN: stamp present but ${TARGET} looks stale; re-applying"
fi

log "Installing BSAN-safe FreeType allocator hooks -> ${TARGET}"
cp "${SOURCE}" "${TARGET}"
if grep -q 'usable_size' "${TARGET}"; then
  die "Patch install failed: usable_size still present in ${TARGET}"
fi

echo "${patch_hash}" >"${STAMP}"
log "Servo BSAN patches applied"
