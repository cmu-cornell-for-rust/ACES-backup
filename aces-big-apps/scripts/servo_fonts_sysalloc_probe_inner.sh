#!/usr/bin/env bash
# BSAN isolation: servo-fonts with libc system allocator (not jemalloc).
# Tests whether teardown UB is jemalloc+BSAN mixing vs FreeType hooks.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

APP="servo-xpath"
PACKAGE="servo-fonts"
SERVO_DIR="${APPS_DIR}/${APP}"
FEATURES="servo-allocator/use-system-allocator"
[[ -d "${SERVO_DIR}" ]] || die "Missing Servo checkout: ${SERVO_DIR}"

apply_bsan_stack_limit
ensure_dirs

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
log_file="${OUTPUT_DIR}/${APP}.${PACKAGE}.bsan-sysalloc.${stamp}.log"
mkdir -p "${OUTPUT_DIR}"
: >"${log_file}"
exec > >(tee -a "${log_file}") 2>&1

log "servo-fonts sysalloc probe log=${log_file}"

export_rust_env
ensure_bsan_toolchain_linked || true
bsan_runtime_ready || die "BSAN setup incomplete"
prepare_bsan_cargo_env

sysroot="$(rustc +bsan --print sysroot)"
export CC_x86_64_unknown_linux_gnu="${sysroot}/bin/clang-22"
export CXX_x86_64_unknown_linux_gnu="${sysroot}/bin/clang-22"
export CFLAGS_x86_64_unknown_linux_gnu="-O1 -ffunction-sections -fdata-sections -fPIC -g -gdwarf-4 -fno-omit-frame-pointer -m64 --target=x86_64-unknown-linux-gnu"
export CXXFLAGS_x86_64_unknown_linux_gnu="${CFLAGS_x86_64_unknown_linux_gnu}"

prepare_servo_fontconfig_build
"${SCRIPT_DIR}/apply_servo_bsan_patches.sh" "${SERVO_DIR}"

export CARGO_TARGET_DIR="${SERVO_DIR}/target/bsan-fonts-sysalloc"
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-1}"

cd "${SERVO_DIR}"
log "probe: features=${FEATURES} target=${CARGO_TARGET_DIR}"

echo "app=${APP}"
echo "package=${PACKAGE}"
echo "features=${FEATURES}"
echo "start=${stamp}"
echo "node=$(hostname)"

echo "--- compile font test only ---"
compile_start=$(date +%s)
cargo +bsan bsan test -p "${PACKAGE}" --features "${FEATURES}" --test font --no-run
compile_end=$(date +%s)
echo "compile_seconds=$((compile_end - compile_start))"

echo "--- run font test only ---"
run_start=$(date +%s)
cargo +bsan bsan test -p "${PACKAGE}" --features "${FEATURES}" --test font -- --nocapture --test-threads=1
run_end=$(date +%s)
echo "run_seconds=$((run_end - run_start))"
echo "status=ok"
echo "log_file=${log_file}"
