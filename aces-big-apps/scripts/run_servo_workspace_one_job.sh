#!/usr/bin/env bash
# One srun: BSAN setup (if needed) + broader Servo workspace test sweep.
# Usage: run_servo_workspace_one_job.sh [walltime] [mem_GB]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

TIME="${1:-4:00}"
MEM="${2:-32}"

ensure_dirs
[[ -d "${APPS_DIR}/servo-xpath" ]] || die "Missing ${APPS_DIR}/servo-xpath — run: fetch_apps.sh servo-xpath"
[[ -f "${BSAN_IMAGE}" || -f "${BSAN_SERVO_IMAGE}" ]] || die "Missing BSAN container image"

IMAGE="${BSAN_IMAGE}"
[[ -f "${IMAGE}" ]] || IMAGE="${BSAN_SERVO_IMAGE}"

INNER="set -euo pipefail; export ACES_ROOT='${ACES_ROOT}'; source '${ACES_ROOT}/config.env'; source '${ACES_ROOT}/scripts/common.sh'; ensure_dirs; '${ACES_ROOT}/scripts/servo_workspace_one_job_inner.sh'"

log "One-job servo workspace: image=${IMAGE} time=${TIME} mem=${MEM}G"
"${SCRIPT_DIR}/run_bsan_job.sh" -J "bsan-servo-ws" "${IMAGE}" "${TIME}" "${MEM}" -- bash -lc "${INNER}"
