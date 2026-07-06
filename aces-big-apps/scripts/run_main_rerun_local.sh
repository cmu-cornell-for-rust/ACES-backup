#!/usr/bin/env bash
# Update BSAN to latest main, rebuild toolchain, rerun full corpus with clean targets.
# Run from laptop (needs valid ACES SSH cert):
#   ./aces/scripts/run_main_rerun_local.sh
#
# Env overrides:
#   SETUP_FORCE=1        rebuild BSAN (default)
#   BSAN_CLEAN=1         cargo clean per app (default)
#   CORPUS_TIME=4:00     walltime per app
#   CORPUS_MEM=32        GB per app
#   SKIP_DEPLOY=1        skip rsync to ACES
#   SKIP_SETUP=1         skip BSAN setup job (toolchain already at HEAD)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACES_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=/dev/null
source "${ACES_ROOT}/config.env"

SSH_CONFIG="${SSH_CONFIG:-${ACES_ROOT}/ssh/config}"
SETUP_FORCE="${SETUP_FORCE:-1}"
BSAN_CLEAN="${BSAN_CLEAN:-1}"
CORPUS_TIME="${CORPUS_TIME:-4:00}"
CORPUS_MEM="${CORPUS_MEM:-32}"
SKIP_DEPLOY="${SKIP_DEPLOY:-0}"
SKIP_SETUP="${SKIP_SETUP:-0}"

SSH=(ssh -F "${SSH_CONFIG}" login.aces)
REMOTE="${ACES_DEPLOY_DIR:-${GROUP_ROOT}/aces-big-apps}"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

if [[ "${SKIP_DEPLOY}" != 1 ]]; then
  log "Deploy harness -> ACES"
  "${SCRIPT_DIR}/deploy.sh"
fi

log "Preflight SSH"
"${SSH[@]}" 'echo ok'

REMOTE_CMD=$(cat <<EOF
set -euo pipefail
export ACES_ROOT='${REMOTE}'
source "\${ACES_ROOT}/config.env"
source "\${ACES_ROOT}/scripts/common.sh"
ensure_dirs

echo "=== BSAN before ==="
git -C "\${BSAN_DIR}" fetch origin main
git -C "\${BSAN_DIR}" log -1 --oneline HEAD
git -C "\${BSAN_DIR}" log -1 --oneline origin/main

if [[ "${SKIP_SETUP}" != 1 ]]; then
  echo "=== BSAN setup (SETUP_FORCE=${SETUP_FORCE}) ==="
  SETUP_FORCE=${SETUP_FORCE} "\${ACES_ROOT}/scripts/setup_bsan_job.sh"
fi

echo "=== BSAN after setup ==="
git -C "\${BSAN_DIR}" log -1 --oneline HEAD
rustc +bsan -V | head -1

echo "=== Corpus rerun (BSAN_CLEAN=${BSAN_CLEAN}) ==="
export BSAN_CLEAN=${BSAN_CLEAN}
export PREFLIGHT_FORCE=1
"\${ACES_ROOT}/scripts/run_corpus_parallel.sh" "${CORPUS_TIME}" "${CORPUS_MEM}"

STAMP=\$(ls -t "\${OUTPUT_DIR}"/corpus.submit.*.log | head -1 | xargs basename | sed 's/corpus.submit.//;s/.log//')
echo "batch_stamp=\${STAMP}"
echo "submit_log=\${OUTPUT_DIR}/corpus.submit.\${STAMP}.log"
EOF
)

log "Running setup + corpus on ACES (may take hours for setup alone)"
"${SSH[@]}" bash -lc "${REMOTE_CMD}"

log "Syncing logs locally"
CORPUS_LOGS_LOCAL="${ACES_ROOT}/logs/bsan-corpus-investigation" \
  "${SCRIPT_DIR}/sync_corpus_logs.sh"

log "Rerun submitted. Monitor: ssh -F aces/ssh/config login.aces 'squeue -u \$USER'"
