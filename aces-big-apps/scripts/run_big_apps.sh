#!/usr/bin/env bash
# Submit BSAN jobs for all apps (or a subset). Run inside tmux on a login node.
# Usage: run_big_apps.sh [app-name ...]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

APPS_TSV="${ACES_ROOT}/datasets/big-apps/apps.tsv"
IMAGE="$(resolve_image "${BSAN_IMAGE}")"
TIME="${JOB_TIME:-04:00}"
MEM="${JOB_MEM:-32}"

"${SCRIPT_DIR}/preflight.sh"

mapfile -t ALL_APPS < <(awk -F '\t' '$1 !~ /^#/ && NF {print $1}' "${APPS_TSV}")
APPS=("${@:-${ALL_APPS[@]}}")

log "Submitting ${#APPS[@]} job(s). Check: squeue -u \$USER"

for app in "${APPS[@]}"; do
  job_name="bsan-${app}"
  INNER="set -euo pipefail; export ACES_ROOT='${ACES_ROOT}'; source '${ACES_ROOT}/config.env'; source '${ACES_ROOT}/scripts/common.sh'; ensure_dirs; '${ACES_ROOT}/scripts/run_bsan_app.sh' '${app}'"
  "${SCRIPT_DIR}/run_bsan_job.sh" -J "${job_name}" "${IMAGE}" "${TIME}" "${MEM}" -- "${INNER}"
done

log "Submitted. Monitor: squeue -u ${ACES_USER}"
