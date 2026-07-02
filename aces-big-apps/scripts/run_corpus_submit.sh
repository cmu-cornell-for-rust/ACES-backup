#!/usr/bin/env bash
# Phase 2 only: parallel sbatch for corpus apps (after prefetch).
# Usage: run_corpus_submit.sh [walltime] [mem_GB] [app-name ...]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

TIME="${1:-4:00}"
MEM="${2:-32}"
shift 2 2>/dev/null || true

DEFAULT_CORPUS=(
  uutils-coreutils ripgrep ring rustls nix quiche git2-rs rusqlite bat fd
  tikv-codec polars-core vector-core react-compiler
)
if [[ $# -gt 0 ]]; then APPS=("$@"); else APPS=("${DEFAULT_CORPUS[@]}"); fi

IMAGE="$(resolve_image "${BSAN_IMAGE}")"
ensure_dirs
export PREFLIGHT_FORCE=1
"${SCRIPT_DIR}/preflight.sh"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
submit_log="${OUTPUT_DIR}/corpus.submit.${stamp}.log"
mkdir -p "${OUTPUT_DIR}"
{
  echo "stamp=${stamp}"
  echo "apps=${APPS[*]}"
  echo "time=${TIME} mem=${MEM}G image=${IMAGE}"
  echo "mode=sbatch_only"
} | tee "${submit_log}"

log "sbatch ${#APPS[@]} corpus job(s) in parallel"
cd "${ACES_ROOT}"
JOB_IDS=()
for app in "${APPS[@]}"; do
  job_name="bsan-${app}"
  INNER="set -euo pipefail; export ACES_ROOT='${ACES_ROOT}'; source '${ACES_ROOT}/config.env'; source '${ACES_ROOT}/scripts/common.sh'; ensure_dirs; export BSAN_CLEAN=${BSAN_CLEAN:-0}; export BSAN_SKIP_FETCH=1; '${ACES_ROOT}/scripts/run_bsan_app.sh' '${app}'"
  log "  -> ${job_name}"
  job_id="$("${SCRIPT_DIR}/run_bsan_job.sh" --batch -J "${job_name}" "${IMAGE}" "${TIME}" "${MEM}" -- bash -lc "${INNER}" \
    2>&1 | tee -a "${submit_log}" | tail -1)"
  JOB_IDS+=("${job_id}")
  echo "submitted job_id=${job_id} app=${app}" >>"${submit_log}"
done

log "Corpus submit done (${#JOB_IDS[@]} jobs). submit_log=${submit_log}"
log "Job IDs: ${JOB_IDS[*]}"
log "Monitor: squeue -u ${ACES_USER}"
