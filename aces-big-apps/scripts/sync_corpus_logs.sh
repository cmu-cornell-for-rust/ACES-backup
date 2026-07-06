#!/usr/bin/env bash
# Sync BSAN corpus logs from ACES into aces/logs/bsan-corpus-investigation/.
# Usage:
#   ./sync_corpus_logs.sh                    # full mirror + latest curated batch
#   ./sync_corpus_logs.sh 20260706T120000Z  # curated dir for specific submit stamp
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACES_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SSH_CONFIG="${SSH_CONFIG:-${ACES_ROOT}/ssh/config}"
LOCAL_ROOT="${CORPUS_LOGS_LOCAL:-${ACES_ROOT}/logs/bsan-corpus-investigation}"
REMOTE_OUT="/scratch/group/p.cis260229.000/aces-big-apps/outputs/bsan-big-apps"
REMOTE_ACES="/scratch/group/p.cis260229.000/aces-big-apps"
STAMP="${1:-}"

if [[ -f "${SSH_CONFIG}" ]]; then
  RSYNC_SSH="ssh -F ${SSH_CONFIG}"
  SSH_CMD=(ssh -F "${SSH_CONFIG}" login.aces)
else
  KEY="$(cd "${ACES_ROOT}/.." && pwd)/id_aces_tamu"
  RSYNC_SSH="ssh -i ${KEY} -o ProxyJump=u.ra353315@aces-jump.hprc.tamu.edu:8822"
  SSH_CMD=(ssh -i "${KEY}" -o ProxyJump=u.ra353315@aces-jump.hprc.tamu.edu:8822 login.aces.hprc.tamu.edu)
fi

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

mkdir -p "${LOCAL_ROOT}"/{corpus,investigate,sbatch,meta}

log "Syncing corpus logs -> ${LOCAL_ROOT}/corpus/"
rsync -avz -e "${RSYNC_SSH}" \
  "login.aces:${REMOTE_OUT}/" "${LOCAL_ROOT}/corpus/" \
  --include='*.log' --exclude='investigate/***' --exclude='sbatch/***' --exclude='*'

log "Syncing investigate/ + sbatch/"
rsync -avz -e "${RSYNC_SSH}" "login.aces:${REMOTE_OUT}/investigate/" "${LOCAL_ROOT}/investigate/" 2>/dev/null || true
rsync -avz -e "${RSYNC_SSH}" "login.aces:${REMOTE_OUT}/sbatch/" "${LOCAL_ROOT}/sbatch/" 2>/dev/null || true

if [[ -z "${STAMP}" ]]; then
  STAMP="$("${SSH_CMD[@]}" "ls -t ${REMOTE_OUT}/corpus.submit.*.log 2>/dev/null | head -1 | xargs -I{} basename {} | sed 's/corpus.submit.//;s/.log//'" 2>/dev/null || true)"
fi

if [[ -n "${STAMP}" ]]; then
  BATCH_DIR="${LOCAL_ROOT}/main-batch-${STAMP}"
  mkdir -p "${BATCH_DIR}"/{corpus,sbatch,meta,investigate}
  log "Building curated batch ${BATCH_DIR}"
  submit="${LOCAL_ROOT}/corpus/corpus.submit.${STAMP}.log"
  [[ -f "${submit}" ]] && cp "${submit}" "${BATCH_DIR}/meta/"
  rsync -avz -e "${RSYNC_SSH}" \
    "login.aces:${REMOTE_OUT}/corpus.submit.${STAMP}.log" "${BATCH_DIR}/meta/" 2>/dev/null || true
  if [[ -f "${BATCH_DIR}/meta/corpus.submit.${STAMP}.log" ]]; then
  while IFS= read -r app; do
    [[ -z "${app}" ]] && continue
    latest="$(ls -t "${LOCAL_ROOT}/corpus/${app}."*.log 2>/dev/null | head -1 || true)"
    [[ -n "${latest}" ]] && cp "${latest}" "${BATCH_DIR}/corpus/"
  done < <(awk '/^apps=/{for(i=2;i<=NF;i++) print $i}' "${BATCH_DIR}/meta/corpus.submit.${STAMP}.log")
  fi
  cp "${LOCAL_ROOT}/investigate/"*.log "${BATCH_DIR}/investigate/" 2>/dev/null || true
  cp "${LOCAL_ROOT}/sbatch/"*.log "${BATCH_DIR}/sbatch/" 2>/dev/null || true
  log "Curated batch: ${BATCH_DIR} ($(ls "${BATCH_DIR}/corpus" 2>/dev/null | wc -l | tr -d ' ') app logs)"
fi

REMOTE_ACES="${REMOTE_ACES_ROOT:-/scratch/group/p.cis260229.000/aces-big-apps}"

# status snapshot for README
"${SSH_CMD[@]}" "export ACES_ROOT='${REMOTE_ACES}'; source \"\${ACES_ROOT}/config.env\"; bash \"\${ACES_ROOT}/scripts/corpus_status_snapshot.sh\"" \
  > "${LOCAL_ROOT}/meta/latest-snapshot.json" 2>/dev/null || true

log "Done. Local logs: ${LOCAL_ROOT}"
