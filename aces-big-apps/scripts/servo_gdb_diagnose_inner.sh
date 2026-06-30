#!/usr/bin/env bash
# Runs inside the BSAN container on a compute node.
set -euo pipefail
APP="${1:-servo-xpath}"
source "${ACES_ROOT}/config.env"
APP_DIR="${APPS_DIR}/${APP}"
LOG_DIR="${OUTPUT_DIR}/gdb"
mkdir -p "${LOG_DIR}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="${LOG_DIR}/${APP}.${STAMP}.diagnose.log"

cd "${APP_DIR}"
BIN="$(find target/bsan/x86_64-unknown-linux-gnu/debug/deps -maxdepth 1 -type f -executable -name 'servo_xpath-*' -print | sort | tail -1)"
[[ -n "${BIN}" ]] || { echo "No servo_xpath test binary found" | tee "${LOG}"; exit 1; }

{
  echo "app=${APP}"
  echo "host=$(hostname)"
  echo "pwd=$(pwd)"
  echo "binary=${BIN}"
  echo "start=${STAMP}"
  echo "--- toolchain ---"
  rustc +bsan -Vv
  cargo +bsan bsan -V || true
  "$(rustc +bsan --print sysroot)/bin/clang-22" --version | head -3
  echo "--- binary symbols ---"
  nm -an -C "${BIN}" | grep 'std::sys::args::unix::imp::ARGC' || true
  nm -an -C "${BIN}" | grep 'std::sys::args::unix::imp::ARGV' || true
  echo "--- program headers ---"
  readelf -lW "${BIN}" | sed -n '/LOAD/p;/GNU_RELRO/p'
  echo "--- gdb ---"
  gdb -batch \
    -ex 'set pagination off' \
    -ex 'set confirm off' \
    -ex 'set debuginfod enabled off' \
    -ex 'set print frame-arguments all' \
    -ex 'run --nocapture --test-threads=1' \
    -ex 'printf "\n--- signal info ---\n"' \
    -ex 'p $_siginfo' \
    -ex 'p/x $_siginfo._sifields._sigfault.si_addr' \
    -ex 'printf "\n--- disassembly around pc ---\n"' \
    -ex 'x/16i $pc-32' \
    -ex 'printf "\n--- key registers ---\n"' \
    -ex 'info registers rax rbx rcx rdx rsi rdi rbp rsp rip' \
    -ex 'printf "\n--- argument and fault memory ---\n"' \
    -ex 'info symbol $rdi' \
    -ex 'x/gx $rdi' \
    -ex 'info symbol $_siginfo._sifields._sigfault.si_addr' \
    -ex 'printf "\n--- mappings ---\n"' \
    -ex 'info proc mappings' \
    -ex 'printf "\n--- backtrace ---\n"' \
    -ex 'bt full' \
    --args "${BIN}" --nocapture --test-threads=1
  echo "status=ok"
} 2>&1 | tee "${LOG}"

echo "diagnose_log=${LOG}"
