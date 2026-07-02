#!/usr/bin/env bash
# One job: BSAN servo-fonts with system allocator (jemalloc bypass probe).
# Usage: run_servo_fonts_sysalloc_probe.sh [walltime] [mem_GB]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

TIME="${1:-1:00}"
MEM="${2:-32}"

ensure_dirs
[[ -d "${APPS_DIR}/servo-xpath" ]] || die "Missing ${APPS_DIR}/servo-xpath"
[[ -f "${BSAN_SERVO_IMAGE}" ]] || die "Missing ${BSAN_SERVO_IMAGE}"

INNER="set -euo pipefail; export ACES_ROOT='${ACES_ROOT}'; source '${ACES_ROOT}/config.env'; source '${ACES_ROOT}/scripts/common.sh'; ensure_dirs; '${ACES_ROOT}/scripts/servo_fonts_sysalloc_probe_inner.sh'"

log "Sysalloc probe: image=${BSAN_SERVO_IMAGE} time=${TIME} mem=${MEM}G"
"${SCRIPT_DIR}/run_bsan_job.sh" -J "bsan-fonts-sysalloc" "${BSAN_SERVO_IMAGE}" "${TIME}" "${MEM}" -- bash -lc "${INNER}"
