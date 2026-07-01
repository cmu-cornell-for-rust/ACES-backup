#!/usr/bin/env bash
# Submit a short compute job that strace's the servo-fonts font integration test.
# Usage: run_servo_fonts_strace.sh [walltime] [mem_GB]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

TIME="${1:-0:45}"
MEM="${2:-32}"

ensure_dirs
[[ -d "${APPS_DIR}/servo-xpath" ]] || die "Missing Servo checkout — run: fetch_apps.sh servo-xpath"
[[ -f "${BSAN_SERVO_IMAGE}" ]] || die "Missing ${BSAN_SERVO_IMAGE}"

INNER="set -euo pipefail; export ACES_ROOT='${ACES_ROOT}'; source '${ACES_ROOT}/config.env'; source '${ACES_ROOT}/scripts/common.sh'; ensure_dirs; '${ACES_ROOT}/scripts/servo_fonts_strace_inner.sh'"

log "Submitting servo-fonts strace job: time=${TIME} mem=${MEM}G"
"${SCRIPT_DIR}/run_bsan_job.sh" -J "bsan-servo-strace" "${BSAN_SERVO_IMAGE}" "${TIME}" "${MEM}" -- bash -lc "${INNER}"
