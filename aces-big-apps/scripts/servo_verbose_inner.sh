#!/usr/bin/env bash
# Runs inside the BSAN container on a compute node.
set -euo pipefail
APP="${1:-servo-xpath}"
source "${ACES_ROOT}/config.env"
APP_DIR="${APPS_DIR}/${APP}"
LOG_DIR="${OUTPUT_DIR}/gdb"
mkdir -p "${LOG_DIR}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="${LOG_DIR}/${APP}.${STAMP}.verbose-runtime.log"

cd "${APP_DIR}"
BIN="$(find target/bsan/x86_64-unknown-linux-gnu/debug/deps -maxdepth 1 -type f -executable -name 'servo_xpath-*' -print | sort | tail -1)"
[[ -n "${BIN}" ]] || { echo "No servo_xpath test binary found" | tee "${LOG}"; exit 1; }

{
  echo "app=${APP}"
  echo "host=$(hostname)"
  echo "binary=${BIN}"
  echo "start=${STAMP}"
  echo "--- runtime with verbosity ---"
  set +e
  BSAN_OPTIONS=verbosity=2 "${BIN}" --nocapture --test-threads=1
  rc=$?
  set -e
  echo "exit_code=${rc}"
} 2>&1 | tee "${LOG}"

echo "verbose_log=${LOG}"
