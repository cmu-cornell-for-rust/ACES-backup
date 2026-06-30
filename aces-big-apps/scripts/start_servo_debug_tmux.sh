#!/usr/bin/env bash
# Create a persistent tmux session for Servo BSAN debugging on ACES.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

SESSION="${1:-bsan-servo-debug}"
APP="${SERVO_DEBUG_APP:-servo-xpath}"
INTERVAL="${MONITOR_INTERVAL:-15}"

ensure_dirs

if ! command -v tmux >/dev/null 2>&1; then
  echo "tmux not found on PATH. Try: module load GCCcore/11.3.0 tmux/3.3a" >&2
  exit 1
fi

if tmux has-session -t "${SESSION}" 2>/dev/null; then
  echo "tmux session already exists: ${SESSION}"
  echo "Attach with: tmux attach -t ${SESSION}"
  exit 0
fi

tmux new-session -d -s "${SESSION}" -n monitor "cd '${ACES_ROOT}' && ./scripts/monitor_bsan.sh '${INTERVAL}'"
tmux new-window -t "${SESSION}" -n servo-gdb "cd '${ACES_ROOT}' && ./scripts/servo_debug_shell.sh '${APP}'"
tmux select-window -t "${SESSION}:servo-gdb"

echo "Created tmux session: ${SESSION}"
echo "Attach with: tmux attach -t ${SESSION}"
echo "Windows: monitor, servo-gdb"
