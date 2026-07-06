#!/usr/bin/env bash
# Submit a compute-node BSAN job for servo-fonts (Servo unsafe/FFI package).
# Usage: run_servo_fonts_job.sh [walltime] [mem_GB] [cargo test args...]
#   Defaults: 2:00 walltime, 32G RAM, package=servo-fonts.
# Env: SERVO_FONTCONFIG_CLEAN=0 to skip fontconfig-sys cache clean (default 1).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

TIME="${1:-2:00}"
shift || true
MEM="32"
if [[ $# -gt 0 && "$1" =~ ^[0-9]+$ ]]; then
  MEM="$1"
  shift || true
fi

ensure_dirs
# Login node may lack the bsan toolchain (host glibc); compute self-heals via setup_bsan.sh.
PREFLIGHT_FORCE=1 "${SCRIPT_DIR}/preflight.sh" servo-xpath

if [[ -f "${BSAN_SERVO_IMAGE}" ]]; then
  IMAGE="${BSAN_SERVO_IMAGE}"
  log "Using servo BSAN image: ${IMAGE}"
else
  die "Missing ${BSAN_SERVO_IMAGE}. Run: ./scripts/rebuild_bsan_servo_image_job.sh"
fi
EXTRA_Q=""
if [[ $# -gt 0 ]]; then
  EXTRA_Q="$(printf ' %q' "$@")"
fi

log "Submitting servo-fonts BSAN job: time=${TIME} mem=${MEM}G cpus=${BSAN_CPUS} image=${IMAGE}"
if [[ -n "${EXTRA_Q}" ]]; then
  log "Extra cargo args:${EXTRA_Q}"
fi

INNER="set -euo pipefail; export ACES_ROOT='${ACES_ROOT}'; source '${ACES_ROOT}/config.env'; source '${ACES_ROOT}/scripts/common.sh'; ensure_dirs; '${ACES_ROOT}/scripts/run_servo_bsan_package.sh' fonts${EXTRA_Q}"

submit_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
submit_log="${OUTPUT_DIR}/servo-fonts.submit.${submit_stamp}.log"
log "Batch output -> ${OUTPUT_DIR}/sbatch/bsan-servo-fonts.*.log  submit_log=${submit_log}"
{
  echo "stamp=${submit_stamp}"
  echo "time=${TIME} mem=${MEM}G cpus=${BSAN_CPUS} image=${IMAGE}"
} >"${submit_log}"
job_id="$("${SCRIPT_DIR}/run_bsan_job.sh" --batch -J "bsan-servo-fonts" "${IMAGE}" "${TIME}" "${MEM}" -- bash -lc "${INNER}" \
  2>&1 | tee -a "${submit_log}" | tail -1)"
echo "submitted job_id=${job_id}" >>"${submit_log}"

log "Submitted servo-fonts job ${job_id}. Package logs: ${OUTPUT_DIR}/servo-xpath.servo-fonts.bsan.*.log"
