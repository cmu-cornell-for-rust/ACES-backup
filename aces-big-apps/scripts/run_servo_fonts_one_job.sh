#!/usr/bin/env bash
# One srun: bsan-servo image + BSAN setup (if needed) + servo-fonts BSAN test.
# Usage: run_servo_fonts_one_job.sh [walltime] [mem_GB]
#   Defaults: 2:00, 32G. Env: SERVO_FONTCONFIG_CLEAN=0 skips fontconfig cache clean.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

TIME="${1:-2:00}"
MEM="${2:-32}"

ensure_dirs
[[ -d "${APPS_DIR}/servo-xpath" ]] || die "Missing ${APPS_DIR}/servo-xpath — run: fetch_apps.sh servo-xpath"
[[ -f "${BSAN_SERVO_IMAGE}" ]] || die "Missing ${BSAN_SERVO_IMAGE} — run: rebuild_bsan_servo_image_job.sh"

INNER="set -euo pipefail; export ACES_ROOT='${ACES_ROOT}'; source '${ACES_ROOT}/config.env'; source '${ACES_ROOT}/scripts/common.sh'; ensure_dirs; '${ACES_ROOT}/scripts/servo_fonts_one_job_inner.sh'"

log "One-job servo-fonts: image=${BSAN_SERVO_IMAGE} time=${TIME} mem=${MEM}G"
"${SCRIPT_DIR}/run_bsan_job.sh" -J "bsan-servo-fonts" "${BSAN_SERVO_IMAGE}" "${TIME}" "${MEM}" -- bash -lc "${INNER}"
