#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"
TIME="${1:-0:30}"
MEM="${2:-8}"
ensure_dirs
[[ -f "${BSAN_SERVO_IMAGE}" ]] || die "Missing ${BSAN_SERVO_IMAGE}"
INNER="set -euo pipefail; export ACES_ROOT='${ACES_ROOT}'; source '${ACES_ROOT}/config.env'; source '${ACES_ROOT}/scripts/common.sh'; ensure_dirs; '${ACES_ROOT}/scripts/servo_jemalloc_strace_probe.sh'"
log "Submitting jemalloc strace probe: time=${TIME} mem=${MEM}G"
"${SCRIPT_DIR}/run_bsan_job.sh" -J "bsan-jemalloc-strace" "${BSAN_SERVO_IMAGE}" "${TIME}" "${MEM}" -- bash -lc "${INNER}"
