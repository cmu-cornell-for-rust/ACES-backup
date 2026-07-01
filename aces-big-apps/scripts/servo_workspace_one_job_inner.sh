#!/usr/bin/env bash
# Run a broader Servo BSAN test sweep (unit workspace crates + servo-xpath).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

APP="servo-xpath"
SERVO_DIR="${APPS_DIR}/${APP}"
[[ -d "${SERVO_DIR}" ]] || die "Missing Servo checkout: ${SERVO_DIR}"

apply_bsan_stack_limit
ensure_dirs

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
log_file="${OUTPUT_DIR}/${APP}.workspace.bsan.${stamp}.log"
mkdir -p "${OUTPUT_DIR}"
: >"${log_file}"
exec > >(tee -a "${log_file}") 2>&1

log "servo workspace one-job log=${log_file}"

export_rust_env
if ! bsan_runtime_ready; then
  log "BSAN not ready; running setup_bsan.sh"
  unset RUSTUP_TOOLCHAIN BSAN_RUST_ONLY
  "${SCRIPT_DIR}/setup_bsan.sh"
fi
ensure_bsan_toolchain_linked || true
bsan_runtime_ready || die "BSAN setup incomplete"
prepare_bsan_cargo_env

export CARGO_TARGET_DIR="${SERVO_DIR}/target/bsan-workspace"
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-1}"

sysroot="$(rustc +bsan --print sysroot)"
export CC_x86_64_unknown_linux_gnu="${sysroot}/bin/clang-22"
export CXX_x86_64_unknown_linux_gnu="${sysroot}/bin/clang-22"
export CFLAGS_x86_64_unknown_linux_gnu="-O1 -ffunction-sections -fdata-sections -fPIC -g -gdwarf-4 -fno-omit-frame-pointer -m64 --target=x86_64-unknown-linux-gnu"
export CXXFLAGS_x86_64_unknown_linux_gnu="${CFLAGS_x86_64_unknown_linux_gnu}"

cd "${SERVO_DIR}"
log "dir=${SERVO_DIR} target=${CARGO_TARGET_DIR}"

echo "app=${APP}"
echo "job=workspace"
echo "start=${stamp}"
echo "node=$(hostname)"

mapfile -t PACKAGES < <(
  {
    echo "servo-xpath"
    for toml in tests/unit/*/Cargo.toml; do
      [[ -f "${toml}" ]] || continue
      awk -F'"' '/^name = / {print $2; exit}' "${toml}"
    done
  } | awk 'NF && !seen[$0]++'
)
echo "packages=${PACKAGES[*]}"

echo "--- cargo fetch ---"
cargo +bsan fetch

echo "--- compile workspace tests (BSAN --no-run) ---"
compile_start=$(date +%s)
pkg_args=()
for pkg in "${PACKAGES[@]}"; do
  pkg_args+=(-p "${pkg}")
done
cargo +bsan bsan test "${pkg_args[@]}" --lib --tests --no-run
compile_end=$(date +%s)
echo "compile_seconds=$((compile_end - compile_start))"

echo "--- run workspace tests ---"
run_start=$(date +%s)
cargo +bsan bsan test "${pkg_args[@]}" --lib --tests -- --nocapture --test-threads=1
run_end=$(date +%s)
echo "run_seconds=$((run_end - run_start))"
echo "status=ok"

csv="${OUTPUT_DIR}/results.csv"
if [[ ! -f "${csv}" ]]; then
  echo "timestamp,app,package,status,compile_seconds,run_seconds,log" >"${csv}"
fi
echo "${stamp},${APP},workspace,ok,$((compile_end - compile_start)),$((run_end - run_start)),${log_file}" >>"${csv}"
echo "log_file=${log_file}"
