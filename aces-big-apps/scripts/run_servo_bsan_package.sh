#!/usr/bin/env bash
# BSAN-test one Servo workspace package (unsafe/FFI-heavy targets).
# Usage: run_servo_bsan_package.sh <cargo-package> [cargo test args...]
#   Harness args (--test-threads, --nocapture, ...) may be passed directly or after '--'.
# Env: SERVO_APP_DIR, BSAN_STACK_KB (default 8 MiB), BSAN_STACK_UNLIMITED=1, SERVO_GEIGER_WORKSPACE=1
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

PACKAGE="${1:?cargo package name required (e.g. servo-fonts, fonts)}"
shift || true

case "${PACKAGE}" in
  fonts) PACKAGE=servo-fonts ;;
  layout) PACKAGE=servo-layout ;;
  script) PACKAGE=servo-script ;;
  script_bindings) PACKAGE=servo-script-bindings ;;
  webgl) PACKAGE=servo-webgl ;;
  allocator) PACKAGE=servo-allocator ;;
esac

CARGO_TEST_ARGS=()
HARNESS_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --)
      shift
      HARNESS_ARGS+=("$@")
      break
      ;;
    --test-threads|--test-threads=*|--nocapture|--ignored|--exact|--show-output)
      HARNESS_ARGS+=("$1")
      shift
      ;;
    *)
      CARGO_TEST_ARGS+=("$1")
      shift
      ;;
  esac
done

APP="servo-xpath"
SERVO_DIR="${SERVO_APP_DIR:-${APPS_DIR}/${APP}}"
[[ -d "${SERVO_DIR}" ]] || die "Missing Servo checkout: ${SERVO_DIR}"

apply_bsan_stack_limit

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
log_file="${OUTPUT_DIR}/${APP}.${PACKAGE}.bsan.${stamp}.log"
geiger_file="${OUTPUT_DIR}/${APP}.geiger.${stamp}.txt"
mkdir -p "${OUTPUT_DIR}"
: >"${log_file}"
finalize_log() {
  local ec=$?
  if [[ ${ec} -ne 0 ]] && ! grep -q '^status=' "${log_file}" 2>/dev/null; then
    echo "status=aborted exit_code=${ec}" >>"${log_file}"
  fi
  return "${ec}"
}
trap finalize_log EXIT

log "package=${PACKAGE} log=${log_file}"
# Tee from the start so setup_bsan.sh (30-60 min) is visible before compile.
exec > >(tee -a "${log_file}") 2>&1

export RUSTUP_HOME CARGO_HOME
export PATH="${CARGO_HOME}/bin:${PATH}"

if ! bsan_runtime_ready; then
  log "BSAN not ready; running setup_bsan.sh (may take ~30-60 min)"
  unset RUSTUP_TOOLCHAIN BSAN_RUST_ONLY
  "${SCRIPT_DIR}/setup_bsan.sh"
fi
ensure_bsan_toolchain_linked || true
bsan_runtime_ready || die "BSAN setup incomplete (need bsan rustc + cargo-bsan in container)"

export RUSTUP_TOOLCHAIN=bsan
export BSAN_RUST_ONLY=1

BSAN_CARGO=(cargo +bsan bsan)

BSAN_SYSROOT="$(rustc +bsan --print sysroot)"
export CC_x86_64_unknown_linux_gnu="${BSAN_SYSROOT}/bin/clang-22"
export CXX_x86_64_unknown_linux_gnu="${BSAN_SYSROOT}/bin/clang-22"
export CFLAGS_x86_64_unknown_linux_gnu="-O1 -ffunction-sections -fdata-sections -fPIC -g -gdwarf-4 -fno-omit-frame-pointer -m64 --target=x86_64-unknown-linux-gnu"
export CXXFLAGS_x86_64_unknown_linux_gnu="${CFLAGS_x86_64_unknown_linux_gnu}"

if [[ "${PACKAGE}" == servo-fonts || "${PACKAGE}" == servo-layout ]]; then
  prepare_servo_fontconfig_build
  if [[ "${SERVO_FONTCONFIG_CLEAN:-1}" == 1 ]]; then
    clean_servo_fontconfig_cargo_cache "${SERVO_DIR}"
  fi
fi

package_source_dir() {
  local pkg="$1" root="$2"
  local path short="${pkg#servo-}"
  path="$(cargo +bsan metadata --format-version 1 --no-deps 2>/dev/null \
    | python3 -c "import json,sys; pkg=sys.argv[1]; data=json.load(sys.stdin); print(next((p['manifest_path'] for p in data['packages'] if p['name']==pkg), ''))" "${pkg}" 2>/dev/null || true)"
  if [[ -n "${path}" ]]; then
    dirname "${path}"
    return 0
  fi
  if [[ -d "${root}/components/${short}" ]]; then
    echo "${root}/components/${short}"
    return 0
  fi
  if [[ -d "${root}/ports/${short}" ]]; then
    echo "${root}/ports/${short}"
    return 0
  fi
  return 1
}

count_unsafe_in_dir() {
  local dir="$1"
  local u e n
  u="$(grep -Rho '\bunsafe\b' "${dir}" --include='*.rs' 2>/dev/null | wc -l | tr -d ' ' || true)"
  e="$(grep -Rho 'extern "C"' "${dir}" --include='*.rs' 2>/dev/null | wc -l | tr -d ' ' || true)"
  n="$(find "${dir}" -name '*.rs' 2>/dev/null | wc -l | tr -d ' ' || true)"
  printf 'package=%s\tdir=%s\tunsafe=%s\textern_C=%s\trs_files=%s\n' \
    "${PACKAGE}" "${dir}" "${u:-0}" "${e:-0}" "${n:-0}"
}

log_package_unsafe_stats() {
  local root="$1" out="$2"
  {
    echo "# target package unsafe/FFI stats (grep)"
    local src_dir
    if src_dir="$(package_source_dir "${PACKAGE}" "${root}")"; then
      count_unsafe_in_dir "${src_dir}"
    else
      echo "package=${PACKAGE}\twarn=no_source_dir"
    fi
    if [[ "${SERVO_GEIGER_WORKSPACE:-0}" == 1 ]]; then
      echo "# optional cargo-geiger for package (slow)"
      if command -v cargo-geiger >/dev/null 2>&1 || [[ -x "${CARGO_HOME}/bin/cargo-geiger" ]]; then
        export PATH="${CARGO_HOME}/bin:${PATH}"
        (cd "${root}" && cargo geiger -p "${PACKAGE}" 2>/dev/null | head -40) || echo "(cargo geiger failed)"
      else
        echo "(cargo-geiger not installed)"
      fi
    fi
  } >"${out}"
}

cd "${SERVO_DIR}"
log "Servo package=${PACKAGE} dir=${SERVO_DIR}"
log "stack_soft_kb=$(ulimit -S -s)"

{
  echo "app=${APP}"
  echo "package=${PACKAGE}"
  echo "start=${stamp}"
  echo "node=$(hostname)"
  echo "stack_soft_kb=$(ulimit -S -s)"
  if [[ ${#HARNESS_ARGS[@]} -gt 0 ]]; then
    echo "test_cmd=cargo +bsan bsan test -p ${PACKAGE} --lib --tests -- ${HARNESS_ARGS[*]}"
  else
    echo "test_cmd=cargo +bsan bsan test -p ${PACKAGE} --lib --tests ${CARGO_TEST_ARGS[*]:-<default>}"
  fi

  echo "--- package unsafe / FFI stats ---"
  log_package_unsafe_stats "${SERVO_DIR}" "${geiger_file}"
  echo "geiger_file=${geiger_file}"
  cat "${geiger_file}" || true

  echo "--- cargo fetch ---"
  if ! cargo +bsan fetch; then
    echo "status=fetch_error"
    exit 1
  fi

  if [[ "${PACKAGE}" == servo-fonts || "${PACKAGE}" == servo-layout ]]; then
    echo "--- prebuild fontconfig deps ---"
    if ! cargo +bsan bsan build -p dlib --lib; then
      echo "status=build_error"
      exit 1
    fi
  fi

  echo "--- compile (BSAN test --no-run) ---"
  compile_start=$(date +%s)
  if ! "${BSAN_CARGO[@]}" test -p "${PACKAGE}" --lib --tests --no-run "${CARGO_TEST_ARGS[@]}"; then
    echo "status=build_error"
    exit 1
  fi
  compile_end=$(date +%s)
  echo "compile_seconds=$((compile_end - compile_start))"

  echo "--- run tests ---"
  run_start=$(date +%s)
  run_cmd=("${BSAN_CARGO[@]}" test -p "${PACKAGE}" --lib --tests "${CARGO_TEST_ARGS[@]}")
  if [[ ${#HARNESS_ARGS[@]} -gt 0 ]]; then
    run_cmd+=(-- "${HARNESS_ARGS[@]}")
  fi
  if "${run_cmd[@]}"; then
    run_end=$(date +%s)
    echo "run_seconds=$((run_end - run_start))"
    echo "status=ok"
  else
    run_end=$(date +%s)
    echo "run_seconds=$((run_end - run_start))"
    echo "status=test_error"
    exit 1
  fi
}

csv="${OUTPUT_DIR}/results.csv"
if [[ ! -f "${csv}" ]]; then
  echo "timestamp,app,package,status,compile_seconds,run_seconds,log" > "${csv}"
fi
status=$(grep '^status=' "${log_file}" | tail -1 | cut -d= -f2)
compile=$(grep '^compile_seconds=' "${log_file}" | tail -1 | cut -d= -f2 || echo "")
run=$(grep '^run_seconds=' "${log_file}" | tail -1 | cut -d= -f2 || echo "")
echo "${stamp},${APP},${PACKAGE},${status},${compile},${run},${log_file}" >> "${csv}"

echo "log_file=${log_file}"
