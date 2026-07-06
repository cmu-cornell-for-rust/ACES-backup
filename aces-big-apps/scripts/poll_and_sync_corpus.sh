#!/usr/bin/env bash
# Poll ACES corpus until quiescent, then sync logs locally.
# Usage: ./poll_and_sync_corpus.sh [interval_minutes]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACES_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INTERVAL="${1:-5}"
SSH_CONFIG="${SSH_CONFIG:-${ACES_ROOT}/ssh/config}"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

while true; do
  n="$(ssh -F "${SSH_CONFIG}" login.aces 'squeue -u u.ra353315 -h -o %j 2>/dev/null | grep -c ^bsan- || true')"
  if [[ "${n}" -eq 0 ]]; then
    log "No bsan-* jobs running"
    break
  fi
  log "${n} bsan job(s) still active; sleeping ${INTERVAL}m"
  sleep "$((INTERVAL * 60))"
done

"${SCRIPT_DIR}/sync_corpus_logs.sh"
log "Sync complete"
