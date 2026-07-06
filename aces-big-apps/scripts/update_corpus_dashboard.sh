#!/usr/bin/env bash
# Local-only dashboard poller: SSH read snapshot from ACES, render canvas here.
# Does NOT submit jobs or run loops on ACES.
#
# Usage:
#   ./scripts/update_corpus_dashboard.sh              # one-shot refresh
#   ./scripts/update_corpus_dashboard.sh --loop 2m    # poll locally every 2m
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../config.env"

LOOP_INTERVAL=""
POLL_LABEL="30s"
if [[ "${1:-}" == "--loop" ]]; then
  LOOP_INTERVAL="${2:-30s}"
  POLL_LABEL="${LOOP_INTERVAL}"
  shift 2
fi

SSH_CONFIG="${SSH_CONFIG:-${ACES_ROOT}/ssh/config}"
REMOTE="${ACES_DEPLOY_HOST:-login.aces.hprc.tamu.edu}"
REMOTE_ACES_ROOT="${ACES_DEPLOY_DIR:-${GROUP_ROOT}/aces-big-apps}"
CANVAS_DIR="${CANVAS_DIR:-${HOME}/.cursor/projects/Users-rafo-projects-big-programs/canvases}"
CANVAS_FILE="${CANVAS_DIR}/bsan-corpus-dashboard.canvas.tsx"
PID_FILE="${CANVAS_DIR}/.bsan-dashboard-poller.pid"
TMP_JSON="$(mktemp)"

if [[ -f "${SSH_CONFIG}" ]]; then
  SSH_CMD=(ssh -F "${SSH_CONFIG}" "${REMOTE}")
else
  KEY="$(cd "${ACES_ROOT}/.." && pwd)/id_aces_tamu"
  SSH_CMD=(ssh -i "${KEY}" -o "ProxyJump=u.ra353315@aces-jump.hprc.tamu.edu:8822" "${REMOTE}")
fi

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

interval_seconds() {
  local spec="$1"
  if [[ "${spec}" =~ ^([0-9]+)s$ ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ "${spec}" =~ ^([0-9]+)m$ ]]; then
    echo $((BASH_REMATCH[1] * 60))
  elif [[ "${spec}" =~ ^([0-9]+)h$ ]]; then
    echo $((BASH_REMATCH[1] * 3600))
  else
    echo 120
  fi
}

fetch_remote_snapshot() {
  # Single read-only SSH call; no sbatch/srun/loop on ACES.
  "${SSH_CMD[@]}" "export ACES_ROOT='${REMOTE_ACES_ROOT}'; bash -s" \
    <"${SCRIPT_DIR}/corpus_status_snapshot.sh"
}

refresh_once() {
  log "Fetching corpus status (local poll via SSH)..."
  if ! fetch_remote_snapshot >"${TMP_JSON}"; then
    log "ERROR: SSH fetch failed"
    return 1
  fi
  if ! python3 -c "import json; json.load(open('${TMP_JSON}'))" 2>/dev/null; then
    log "ERROR: invalid snapshot JSON"
    return 1
  fi
  python3 -c "
import json, sys
p = sys.argv[1]
poll = sys.argv[2]
with open(p) as f:
    d = json.load(f)
d['pollInterval'] = poll
with open(p, 'w') as f:
    json.dump(d, f)
" "${TMP_JSON}" "${POLL_LABEL}"
  mkdir -p "${CANVAS_DIR}"
  python3 "${SCRIPT_DIR}/render_corpus_dashboard.py" "${TMP_JSON}" >"${CANVAS_FILE}.tmp"
  mv "${CANVAS_FILE}.tmp" "${CANVAS_FILE}"
  log "Dashboard -> ${CANVAS_FILE}"
}

stop_other_pollers() {
  if [[ -f "${PID_FILE}" ]]; then
    local old_pid
    old_pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
    if [[ -n "${old_pid}" ]] && kill -0 "${old_pid}" 2>/dev/null; then
      log "Stopping previous local poller (pid ${old_pid})"
      kill "${old_pid}" 2>/dev/null || true
    fi
    rm -f "${PID_FILE}"
  fi
}

trap 'rm -f "${TMP_JSON}"' EXIT

if [[ -n "${LOOP_INTERVAL}" ]]; then
  stop_other_pollers
  echo $$ >"${PID_FILE}"
  secs="$(interval_seconds "${LOOP_INTERVAL}")"
  log "Local poll every ${LOOP_INTERVAL} (${secs}s). PID $$  Ctrl+C to stop."
  refresh_once || true
  while true; do
    sleep "${secs}"
    refresh_once || true
  done
else
  refresh_once
fi
