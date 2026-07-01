#!/usr/bin/env bash
# Submit servo-fonts (FFI) and workspace (broader) BSAN jobs concurrently.
# Usage: run_servo_parallel.sh [walltime] [mem_GB]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

TIME="${1:-4:00}"
MEM="${2:-32}"

ensure_dirs
"${SCRIPT_DIR}/fetch_apps.sh" servo-xpath

log "Submitting parallel Servo BSAN jobs (fonts + workspace), time=${TIME} mem=${MEM}G"
nohup "${SCRIPT_DIR}/run_servo_fonts_one_job.sh" "${TIME}" "${MEM}" \
  >"${OUTPUT_DIR}/servo-fonts.submit.$(date -u +%Y%m%dT%H%M%SZ).log" 2>&1 &
fonts_pid=$!
nohup "${SCRIPT_DIR}/run_servo_workspace_one_job.sh" "${TIME}" "${MEM}" \
  >"${OUTPUT_DIR}/servo-workspace.submit.$(date -u +%Y%m%dT%H%M%SZ).log" 2>&1 &
ws_pid=$!

log "Submitted fonts wrapper pid=${fonts_pid}, workspace wrapper pid=${ws_pid}"
log "Monitor: squeue -u \$USER"
sleep 2
squeue -u "${ACES_USER}"
