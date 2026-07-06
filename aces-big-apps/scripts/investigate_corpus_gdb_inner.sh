#!/usr/bin/env bash
# GDB-only follow-up for quiche SIGSEGV and nix failures (uses prebuilt corpus binaries).
set -euo pipefail

source "${ACES_ROOT}/config.env"
source "${ACES_ROOT}/scripts/common.sh"

LOG_DIR="${OUTPUT_DIR}/investigate"
mkdir -p "${LOG_DIR}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="${LOG_DIR}/corpus-gdb.${STAMP}.log"

export_rust_env
prepare_bsan_cargo_env
apply_bsan_stack_limit

QUICHE_DIR="${APPS_DIR}/quiche"
NIX_DIR="${APPS_DIR}/nix"

{
  echo "stamp=${STAMP}"
  echo "host=$(hostname)"
  echo "stack_soft_kb=$(ulimit -S -s)"

  echo ""
  echo "========== quiche: gdb SIGSEGV =========="
  cd "${QUICHE_DIR}"
  QUICHE_TEST='h3::tests::additional_headers_before_data_client'
  QUICHE_BIN="$(find target/bsan-quiche/bsan/x86_64-unknown-linux-gnu/debug/deps -maxdepth 1 -type f -executable -name 'quiche-*' ! -name '*.so' 2>/dev/null | sort | tail -1)"
  echo "quiche_bin=${QUICHE_BIN:-MISSING}"
  echo "quiche_test=${QUICHE_TEST}"
  if [[ -n "${QUICHE_BIN}" && -x "${QUICHE_BIN}" ]]; then
    echo "--- quiche direct ---"
    "${QUICHE_BIN}" --exact --nocapture --test-threads=1 "${QUICHE_TEST}" 2>&1 | tail -25 || echo "quiche_direct_exit=$?"
    echo "--- quiche gdb ---"
    gdb -batch \
      -ex 'set pagination off' \
      -ex 'set confirm off' \
      -ex 'set debuginfod enabled off' \
      -ex "run --exact --nocapture --test-threads=1 ${QUICHE_TEST}" \
      -ex 'printf "\n--- signal ---\n"' \
      -ex 'info program' \
      -ex 'p $_siginfo' \
      -ex 'p/x $_siginfo._sifields._sigfault.si_addr' \
      -ex 'bt full' \
      -ex 'thread apply all bt full' \
      -ex 'info proc mappings' \
      --args "${QUICHE_BIN}" --exact --nocapture --test-threads=1 "${QUICHE_TEST}" 2>&1 || true
  fi

  echo ""
  echo "========== nix: gdb mremap + self_cpu_time =========="
  cd "${NIX_DIR}"
  NIX_MREMAP_TEST='sys::test_mman::test_mremap_dontunmap'
  NIX_CPU_TEST='sys::test_resource::test_self_cpu_time'
  NIX_BIN="$(find target/bsan-nix/bsan/x86_64-unknown-linux-gnu/debug/deps -maxdepth 1 -type f -executable -name 'test-*' 2>/dev/null | sort | tail -1)"
  echo "nix_bin=${NIX_BIN:-MISSING}"
  if [[ -n "${NIX_BIN}" && -x "${NIX_BIN}" ]]; then
    echo "--- nix mremap direct ---"
    "${NIX_BIN}" --exact --nocapture --test-threads=1 "${NIX_MREMAP_TEST}" 2>&1 || echo "nix_mremap_exit=$?"
    echo "--- nix gdb mremap ---"
    gdb -batch \
      -ex 'set pagination off' \
      -ex 'set confirm off' \
      -ex 'set debuginfod enabled off' \
      -ex "run --exact --nocapture --test-threads=1 ${NIX_MREMAP_TEST}" \
      -ex 'printf "\n--- signal ---\n"' \
      -ex 'info program' \
      -ex 'p $_siginfo' \
      -ex 'bt full' \
      -ex 'thread apply all bt full' \
      --args "${NIX_BIN}" --exact --nocapture --test-threads=1 "${NIX_MREMAP_TEST}" 2>&1 || true
    echo "--- nix gdb self_cpu_time (10m cap) ---"
    timeout 600 gdb -batch \
      -ex 'set pagination off' \
      -ex 'set confirm off' \
      -ex 'set debuginfod enabled off' \
      -ex "run --exact --nocapture --test-threads=1 ${NIX_CPU_TEST}" \
      -ex 'printf "\n--- signal ---\n"' \
      -ex 'info program' \
      -ex 'p $_siginfo' \
      -ex 'bt full' \
      -ex 'thread apply all bt full' \
      --args "${NIX_BIN}" --exact --nocapture --test-threads=1 "${NIX_CPU_TEST}" 2>&1 || echo "nix_cpu_time: timeout or kill ($?)"
  fi

  echo ""
  echo "status=ok"
} 2>&1 | tee "${LOG}"

echo "investigate_gdb_log=${LOG}"
