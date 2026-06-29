#!/usr/bin/env bash
# One-time BSAN install on a compute node. Refuses if already ready or job active.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

TIME="${SETUP_TIME:-2:00}"
MEM="${SETUP_MEM:-16}"
FORCE="${SETUP_FORCE:-0}"

if bsan_artifacts_ready && [[ "${FORCE}" -eq 0 ]]; then
  log "BSAN artifacts already present. Nothing to do."
  exit 0
fi

guard_no_duplicate_jobs "bsan" "${FORCE}"

IMAGE="$(resolve_image "${BSAN_IMAGE}")"
ensure_dirs

log "Submitting BSAN setup: ${IMAGE} mem=${MEM}G time=${TIME}"
INNER="set -euo pipefail; export ACES_ROOT='${ACES_ROOT}'; source '${ACES_ROOT}/config.env'; source '${ACES_ROOT}/scripts/common.sh'; ensure_dirs; '${ACES_ROOT}/scripts/setup_bsan.sh'"

"${SCRIPT_DIR}/run_bsan_job.sh" -J "bsan-setup" "${IMAGE}" "${TIME}" "${MEM}" -- "${INNER}"

"${SCRIPT_DIR}/check_bsan.sh"
