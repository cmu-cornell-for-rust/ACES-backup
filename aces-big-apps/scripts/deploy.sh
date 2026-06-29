#!/usr/bin/env bash
# Sync aces/ to the group directory on ACES.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../config.env"

SSH_CONFIG="${SSH_CONFIG:-${ACES_ROOT}/ssh/config}"
REMOTE="${ACES_DEPLOY_HOST:-login.aces.hprc.tamu.edu}"
REMOTE_DIR="${ACES_DEPLOY_DIR:-${GROUP_ROOT}/aces-big-apps}"

if [[ -f "${SSH_CONFIG}" ]]; then
  RSYNC_SSH="ssh -F ${SSH_CONFIG}"
else
  KEY="$(cd "${ACES_ROOT}/.." && pwd)/id_aces_tamu"
  RSYNC_SSH="ssh -i ${KEY} -o ProxyJump=u.ra353315@aces-jump.hprc.tamu.edu:8822"
fi

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

log "Deploying ${ACES_ROOT}/ -> ${REMOTE}:${REMOTE_DIR}/"
rsync -avz --delete \
  --exclude '.git' \
  --exclude 'outputs/' \
  -e "${RSYNC_SSH}" \
  "${ACES_ROOT}/" "${REMOTE}:${REMOTE_DIR}/"

log "Done. On ACES: export ACES_ROOT=${REMOTE_DIR}"
