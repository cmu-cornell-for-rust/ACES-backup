#!/usr/bin/env bash
# Run on ACES login node: update BSAN main, rebuild, submit full corpus.
set -euo pipefail
export ACES_ROOT="${ACES_ROOT:-/scratch/group/p.cis260229.000/aces-big-apps}"
source "${ACES_ROOT}/config.env"
source "${ACES_ROOT}/scripts/common.sh"
ensure_dirs

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="${OUTPUT_DIR}/corpus.rerun.${STAMP}.log"
exec > >(tee -a "${LOG}") 2>&1

echo "stamp=${STAMP}"
echo "host=$(hostname)"
bsan_revision_line || true

echo "=== Phase 1: BSAN setup (SETUP_FORCE=${SETUP_FORCE:-1}) ==="
SETUP_FORCE="${SETUP_FORCE:-1}" "${ACES_ROOT}/scripts/setup_bsan_job.sh"

echo "=== BSAN after setup ==="
git -C "${BSAN_DIR}" log -1 --oneline
export_rust_env
rustc +bsan -V 2>/dev/null | head -1 || echo "rustc=deferred_to_container"

echo "=== Phase 2: corpus prefetch + submit (BSAN_CLEAN=${BSAN_CLEAN:-1}) ==="
export BSAN_CLEAN="${BSAN_CLEAN:-1}"
export PREFLIGHT_FORCE=1
"${ACES_ROOT}/scripts/run_corpus_parallel.sh" "${CORPUS_TIME:-4:00}" "${CORPUS_MEM:-32}"

echo "rerun_log=${LOG}"
echo "status=ok"
