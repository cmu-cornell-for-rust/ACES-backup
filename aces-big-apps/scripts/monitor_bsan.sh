#!/usr/bin/env bash
# Watch BSAN setup/benchmark jobs from a login node (no compute tokens).
#
# Usage:
#   ./scripts/monitor_bsan.sh              # refresh every 30s
#   ./scripts/monitor_bsan.sh 15           # refresh every 15s
#   ./scripts/monitor_bsan.sh --once       # single snapshot
#
# In tmux:
#   tmux new -s bsan-monitor
#   export ACES_ROOT=/scratch/group/p.cis260229.000/aces-big-apps
#   cd "$ACES_ROOT" && ./scripts/monitor_bsan.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

INTERVAL="${MONITOR_INTERVAL:-30}"
ONCE=0

if [[ "${1:-}" == "--once" ]]; then
  ONCE=1
elif [[ -n "${1:-}" ]]; then
  INTERVAL="$1"
fi

status_line() {
  local label="$1" ok="$2"
  if [[ "${ok}" -eq 1 ]]; then
    printf '  OK   %s\n' "${label}"
  else
    printf '  FAIL %s\n' "${label}"
  fi
}

print_snapshot() {
  local now jobs setup_log latest_log
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  printf '\n========== BSAN monitor %s ==========\n' "${now}"

  jobs="$(squeue -h -u "${ACES_USER}" -o '%i %j %T %M %R' 2>/dev/null | grep -i bsan || true)"
  if [[ -n "${jobs}" ]]; then
    printf '\n-- squeue (bsan*) --\n%s\n' "${jobs}"
  else
    printf '\n-- squeue (bsan*) --\n(none)\n'
  fi

  printf '\n-- readiness (login node) --\n'
  [[ -d "${BSAN_DIR}/.git" ]] && status_line "repo ${BSAN_DIR}" 1 || status_line "repo ${BSAN_DIR}" 0
  bsan_artifacts_ready && status_line "bsan artifacts" 1 || status_line "bsan artifacts" 0
  bsan_toolchain_ready && status_line "bsan in rustup" 1 || status_line "bsan in rustup" 0
  cargo_bsan_ready && status_line "cargo-bsan" 1 || status_line "cargo-bsan" 0
  if rustc_bsan_works; then
    status_line "rustc +bsan on host" 1
  elif bsan_artifacts_ready; then
    printf '  WARN rustc +bsan not runnable on login node (use container)\n'
  else
    status_line "rustc +bsan on host" 0
  fi
  if bsan_artifacts_ready; then
    printf '  => ready to submit benchmarks (runs inside container)\n'
  else
    printf '  => not ready (run ./scripts/setup_bsan_job.sh if needed)\n'
  fi

  printf '\n-- recent jobs (sacct) --\n'
  sacct -u "${ACES_USER}" --starttime=today -n -P \
    --format=JobID,JobName%20,State,ExitCode,Elapsed \
    2>/dev/null | grep -i bsan | tail -8 || printf '(none today)\n'

  setup_log="${OUTPUT_DIR}/setup.log"
  if [[ -f "${setup_log}" ]]; then
    printf '\n-- tail setup.log --\n'
    tail -n 12 "${setup_log}"
  fi

  latest_log="$(ls -t "${OUTPUT_DIR}"/*.log 2>/dev/null | grep -v '/setup.log$' | head -1 || true)"
  if [[ -n "${latest_log}" ]]; then
    printf '\n-- tail %s --\n' "$(basename "${latest_log}")"
    tail -n 8 "${latest_log}"
  fi

  printf '\n-- hints --\n'
  printf '  cancel one job:  scancel <jobid>\n'
  printf '  cancel all:      scancel -u %s\n' "${ACES_USER}"
  printf '  full check:      ./scripts/check_bsan.sh\n'
}

while true; do
  print_snapshot
  [[ "${ONCE}" -eq 1 ]] && break
  sleep "${INTERVAL}"
done
