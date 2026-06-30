#!/usr/bin/env bash
# Runs inside the BSAN container on a compute node.
set -euo pipefail
APP="${1:-servo-xpath}"
source "${ACES_ROOT}/config.env"
APP_DIR="${APPS_DIR}/${APP}"
LOG_DIR="${OUTPUT_DIR}/gdb"
mkdir -p "${LOG_DIR}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="${LOG_DIR}/${APP}.${STAMP}.ctor-order.log"

cd "${APP_DIR}"
BIN="$(find target/bsan/x86_64-unknown-linux-gnu/debug/deps -maxdepth 1 -type f -executable -name 'servo_xpath-*' -print | sort | tail -1)"
[[ -n "${BIN}" ]] || { echo "No servo_xpath test binary found" | tee "${LOG}"; exit 1; }

{
  echo "app=${APP}"
  echo "host=$(hostname)"
  echo "binary=${BIN}"
  echo "start=${STAMP}"
  gdb -batch \
    -ex 'set pagination off' \
    -ex 'set confirm off' \
    -ex 'set debuginfod enabled off' \
    -ex 'set breakpoint pending on' \
    -ex 'break __bsan_init' \
    -ex 'break std::sys::args::unix::imp::really_init' \
    -ex 'info breakpoints' \
    -ex 'run --nocapture --test-threads=1' \
    -ex 'printf "\n--- stop 1 ---\n"' \
    -ex 'frame' \
    -ex 'bt 5' \
    -ex 'continue' \
    -ex 'printf "\n--- stop 2 ---\n"' \
    -ex 'frame' \
    -ex 'bt 5' \
    -ex 'disable 1' \
    -ex 'continue' \
    -ex 'printf "\n--- stop after disabling bsan init breakpoint ---\n"' \
    -ex 'frame' \
    -ex 'bt 8' \
    -ex 'printf "\n--- mappings at std args init ---\n"' \
    -ex 'info proc mappings' \
    -ex 'continue' \
    -ex 'printf "\n--- final stop ---\n"' \
    -ex 'frame' \
    -ex 'p $_siginfo' \
    -ex 'bt 8' \
    --args "${BIN}" --nocapture --test-threads=1
  echo "status=ok"
} 2>&1 | tee "${LOG}"

echo "order_log=${LOG}"
