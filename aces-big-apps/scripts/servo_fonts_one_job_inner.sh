#!/usr/bin/env bash
# Run inside bsan-servo.sif on a compute node (called by run_servo_fonts_one_job.sh).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

APP="servo-xpath"
PACKAGE="servo-fonts"
SERVO_DIR="${APPS_DIR}/${APP}"
[[ -d "${SERVO_DIR}" ]] || die "Missing Servo checkout: ${SERVO_DIR}"

apply_bsan_stack_limit
ensure_dirs

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
log_file="${OUTPUT_DIR}/${APP}.${PACKAGE}.bsan.${stamp}.log"
mkdir -p "${OUTPUT_DIR}"
: >"${log_file}"
exec > >(tee -a "${log_file}") 2>&1

log "servo-fonts one-job log=${log_file}"

export_rust_env
if ! bsan_runtime_ready; then
  log "BSAN not ready; running setup_bsan.sh (may take ~30-60 min)"
  unset RUSTUP_TOOLCHAIN BSAN_RUST_ONLY
  "${SCRIPT_DIR}/setup_bsan.sh"
fi
ensure_bsan_toolchain_linked || true
bsan_runtime_ready || die "BSAN setup incomplete"
prepare_bsan_cargo_env

sysroot="$(rustc +bsan --print sysroot)"
export CC_x86_64_unknown_linux_gnu="${sysroot}/bin/clang-22"
export CXX_x86_64_unknown_linux_gnu="${sysroot}/bin/clang-22"
export CFLAGS_x86_64_unknown_linux_gnu="-O1 -ffunction-sections -fdata-sections -fPIC -g -gdwarf-4 -fno-omit-frame-pointer -m64 --target=x86_64-unknown-linux-gnu"
export CXXFLAGS_x86_64_unknown_linux_gnu="${CFLAGS_x86_64_unknown_linux_gnu}"

prepare_servo_fontconfig_build
if [[ "${SERVO_FONTCONFIG_CLEAN:-1}" == 1 ]]; then
  clean_servo_fontconfig_cargo_cache "${SERVO_DIR}"
fi

cd "${SERVO_DIR}"
log "dir=${SERVO_DIR} stack_soft_kb=$(ulimit -S -s)"

echo "app=${APP}"
echo "package=${PACKAGE}"
echo "start=${stamp}"
echo "node=$(hostname)"

echo "--- cargo fetch ---"
cargo +bsan fetch

echo "--- prebuild dlib ---"
cargo +bsan bsan build -p dlib --lib

echo "--- compile integration tests (BSAN --no-run, no --lib) ---"
compile_start=$(date +%s)
cargo +bsan bsan test -p "${PACKAGE}" --tests --no-run
compile_end=$(date +%s)
echo "compile_seconds=$((compile_end - compile_start))"

echo "--- run integration tests ---"
run_start=$(date +%s)
cargo +bsan bsan test -p "${PACKAGE}" --tests -- --nocapture --test-threads=1
run_end=$(date +%s)
echo "run_seconds=$((run_end - run_start))"
echo "status=ok"

csv="${OUTPUT_DIR}/results.csv"
if [[ ! -f "${csv}" ]]; then
  echo "timestamp,app,package,status,compile_seconds,run_seconds,log" >"${csv}"
fi
echo "${stamp},${APP},${PACKAGE},ok,$((compile_end - compile_start)),$((run_end - run_start)),${log_file}" >>"${csv}"
echo "log_file=${log_file}"
