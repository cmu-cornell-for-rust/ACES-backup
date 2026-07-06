#!/usr/bin/env bash
# Corpus batch: serial prefetch, then parallel sbatch (one job per app).
# Usage: run_corpus_parallel.sh [walltime] [mem_GB] [app-name ...]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

TIME="${1:-4:00}"
MEM="${2:-32}"
shift 2 2>/dev/null || true

load_corpus_apps
if [[ $# -gt 0 ]]; then APPS=("$@"); else APPS=("${CORPUS_APPS[@]}"); fi

IMAGE="$(resolve_image "${BSAN_IMAGE}")"
ensure_dirs
export PREFLIGHT_FORCE=1
"${SCRIPT_DIR}/preflight.sh"
log "Cancelling stale corpus bsan-* jobs (keeping bsan-fonts-*)..."
while IFS= read -r jid; do
  [[ -n "${jid}" ]] && scancel "${jid}" 2>/dev/null || true
done < <(squeue -u "${ACES_USER}" -h -o "%i %j" 2>/dev/null \
  | awk '$2 ~ /^bsan-/ && $2 !~ /^bsan-fonts/ {print $1}')

log "Fetching ${#APPS[@]} corpus repo(s)..."
"${SCRIPT_DIR}/fetch_apps.sh" "${APPS[@]}"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
submit_log="${OUTPUT_DIR}/corpus.submit.${stamp}.log"
mkdir -p "${OUTPUT_DIR}"
{
  echo "stamp=${stamp}"
  echo "apps=${APPS[*]}"
  echo "time=${TIME} mem=${MEM}G cpus=${BSAN_CPUS} image=${IMAGE}"
  echo "mode=prefetch_then_sbatch"
  bsan_revision_line || true
  echo "BSAN_CLEAN=${BSAN_CLEAN:-0}"
} | tee "${submit_log}"

log "Phase 1: serial prefetch (shared CARGO_HOME, no lock fights later)"
"${SCRIPT_DIR}/run_corpus_prefetch.sh" "1:00" "16" "${APPS[@]}" 2>&1 | tee -a "${submit_log}"

log "Phase 2: sbatch ${#APPS[@]} corpus job(s) in parallel"
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

log "Corpus batch submitted (${#JOB_IDS[@]} jobs). submit_log=${submit_log}"
log "Job IDs: ${JOB_IDS[*]}"
log "Monitor: squeue -u ${ACES_USER}"
