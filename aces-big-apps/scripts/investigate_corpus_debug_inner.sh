#!/usr/bin/env bash
# Corpus debug investigation: uutils UB isolation + gdb on quiche SIGSEGV / nix failures.
# Runs inside bsan.sif on a compute node.
set -euo pipefail

source "${ACES_ROOT}/config.env"
source "${ACES_ROOT}/scripts/common.sh"

LOG_DIR="${OUTPUT_DIR}/investigate"
mkdir -p "${LOG_DIR}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="${LOG_DIR}/corpus-debug.${STAMP}.log"

export_rust_env
prepare_bsan_cargo_env
prepare_bsan_native_cc_env
apply_bsan_stack_limit

UUTILS_DIR="${APPS_DIR}/uutils-coreutils"
QUICHE_DIR="${APPS_DIR}/quiche"
NIX_DIR="${APPS_DIR}/nix"

export CARGO_TARGET_DIR="${UUTILS_DIR}/target/bsan-uutils-coreutils"
export RUSTUP_TOOLCHAIN=bsan

{
  echo "stamp=${STAMP}"
  echo "host=$(hostname)"
  echo "stack_soft_kb=$(ulimit -S -s)"
  echo "bsan=$(rustc +bsan -V 2>/dev/null | head -1)"

  echo ""
  echo "========== 1. uutils: nightly control (no BSAN) =========="
  cd "${UUTILS_DIR}"
  export RUSTUP_TOOLCHAIN=nightly
  unset BSAN_PLUGIN BSAN_RT_RUST BSAN_RT_LLVM BSAN_RUST_ONLY
  if cargo test -p uu_dd progress::tests::test_prog_update_write_io_lines -- --nocapture --test-threads=1 2>&1; then
    echo "uutils_nightly=PASS"
  else
    echo "uutils_nightly=FAIL"
  fi

  echo ""
  echo "========== 2. uutils: BSAN isolated single test =========="
  export RUSTUP_TOOLCHAIN=bsan
  prepare_bsan_cargo_env
  export CARGO_TARGET_DIR="${UUTILS_DIR}/target/bsan-uutils-coreutils"
  if cargo +bsan bsan test -p uu_dd progress::tests::test_prog_update_write_io_lines -- --nocapture --test-threads=1 2>&1; then
    echo "uutils_bsan_isolated=PASS"
  else
    echo "uutils_bsan_isolated=FAIL"
  fi

  echo ""
  echo "========== 3. uutils: BSAN only progress module tests =========="
  if cargo +bsan bsan test -p uu_dd progress::tests -- --nocapture --test-threads=1 2>&1; then
    echo "uutils_bsan_progress_mod=PASS"
  else
    echo "uutils_bsan_progress_mod=FAIL"
  fi

  echo ""
  echo "========== 4. uutils: BSAN full uu_dd lib (order matters?) =========="
  if cargo +bsan bsan test -p uu_dd --lib -- --nocapture --test-threads=1 2>&1 | tail -30; then
    echo "uutils_bsan_full_lib=PASS"
  else
    echo "uutils_bsan_full_lib=FAIL"
  fi

  echo ""
  echo "========== 5. quiche: locate binary + gdb SIGSEGV =========="
  cd "${QUICHE_DIR}"
  export CARGO_TARGET_DIR="${QUICHE_DIR}/target/bsan-quiche"
  QUICHE_BIN="$(find target/bsan-quiche/bsan/x86_64-unknown-linux-gnu/debug/deps -maxdepth 1 -type f -executable -name 'quiche-*' ! -name '*.so' 2>/dev/null | sort | tail -1)"
  echo "quiche_bin=${QUICHE_BIN:-MISSING}"
  if [[ -n "${QUICHE_BIN}" && -x "${QUICHE_BIN}" ]]; then
    echo "--- quiche cargo single test (no gdb) ---"
    cargo +bsan bsan test -p quiche additional_headers_before_data_client -- --exact --nocapture --test-threads=1 2>&1 | tail -40 || true
    echo "--- quiche gdb ---"
    gdb -batch \
      -ex 'set pagination off' \
      -ex 'set confirm off' \
      -ex 'set debuginfod enabled off' \
      -ex 'run --exact --nocapture --test-threads=1 additional_headers_before_data_client' \
      -ex 'printf "\n--- signal ---\n"' \
      -ex 'p $_siginfo' \
      -ex 'p/x $_siginfo._sifields._sigfault.si_addr' \
      -ex 'bt full' \
      -ex 'thread apply all bt full' \
      -ex 'info proc mappings' \
      --args "${QUICHE_BIN}" --exact --nocapture --test-threads=1 additional_headers_before_data_client 2>&1 || true
  fi

  echo ""
  echo "========== 6. nix: mremap test + gdb =========="
  cd "${NIX_DIR}"
  export CARGO_TARGET_DIR="${NIX_DIR}/target/bsan-nix"
  NIX_BIN="$(find target/bsan-nix/bsan/x86_64-unknown-linux-gnu/debug/deps -maxdepth 1 -type f -executable -name 'test-*' 2>/dev/null | sort | tail -1)"
  echo "nix_bin=${NIX_BIN:-MISSING}"
  if [[ -n "${NIX_BIN}" && -x "${NIX_BIN}" ]]; then
    echo "--- nix mremap single test ---"
    cargo +bsan bsan test -p nix --test test test_mremap_dontunmap -- --exact --nocapture --test-threads=1 2>&1 | tail -50 || true
    echo "--- nix gdb mremap ---"
    gdb -batch \
      -ex 'set pagination off' \
      -ex 'set confirm off' \
      -ex 'set debuginfod enabled off' \
      -ex 'run --exact --nocapture --test-threads=1 test_mremap_dontunmap' \
      -ex 'printf "\n--- signal ---\n"' \
      -ex 'p $_siginfo' \
      -ex 'bt full' \
      -ex 'info proc mappings' \
      --args "${NIX_BIN}" --exact --nocapture --test-threads=1 test_mremap_dontunmap 2>&1 || true
    echo "--- nix gdb self_cpu_time (SIGKILL repro attempt) ---"
    timeout 120 gdb -batch \
      -ex 'set pagination off' \
      -ex 'run --exact --nocapture --test-threads=1 test_self_cpu_time' \
      -ex 'bt full' \
      --args "${NIX_BIN}" --exact --nocapture --test-threads=1 test_self_cpu_time 2>&1 || echo "nix_cpu_time: timeout or kill ($?)"
  fi

  echo ""
  echo "status=ok"
} 2>&1 | tee "${LOG}"

echo "investigate_log=${LOG}"
