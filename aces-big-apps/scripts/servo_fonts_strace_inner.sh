#!/usr/bin/env bash
# Trace syscalls during servo-fonts integration test (compute node, inside bsan-servo.sif).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

APP="servo-xpath"
PACKAGE="servo-fonts"
SERVO_DIR="${APPS_DIR}/${APP}"
OUT="${OUTPUT_DIR}/strace"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "${OUT}"

apply_bsan_stack_limit
ensure_dirs
export_rust_env
prepare_bsan_cargo_env

sysroot="$(rustc +bsan --print sysroot)"
export CC_x86_64_unknown_linux_gnu="${sysroot}/bin/clang-22"
export CXX_x86_64_unknown_linux_gnu="${sysroot}/bin/clang-22"
export CFLAGS_x86_64_unknown_linux_gnu="-O1 -ffunction-sections -fdata-sections -fPIC -g -gdwarf-4 -fno-omit-frame-pointer -m64 --target=x86_64-unknown-linux-gnu"
export CXXFLAGS_x86_64_unknown_linux_gnu="${CFLAGS_x86_64_unknown_linux_gnu}"

prepare_servo_fontconfig_build
"${SCRIPT_DIR}/apply_servo_bsan_patches.sh" "${SERVO_DIR}"

export CARGO_TARGET_DIR="${SERVO_DIR}/target/bsan-fonts-strace"
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-1}"

cd "${SERVO_DIR}"
log "strace servo-fonts: target=${CARGO_TARGET_DIR}"

cargo +bsan fetch
cargo +bsan bsan build -p dlib --lib
cargo +bsan bsan test -p "${PACKAGE}" --test font --no-run

BIN="$(ls -t "${CARGO_TARGET_DIR}"/bsan/x86_64-unknown-linux-gnu/debug/deps/font-*.exe 2>/dev/null | head -1 || true)"
if [[ -z "${BIN}" ]]; then
  BIN="$(ls -t "${CARGO_TARGET_DIR}"/bsan/x86_64-unknown-linux-gnu/debug/deps/font-* 2>/dev/null | grep -v '\.d$' | head -1 || true)"
fi
[[ -n "${BIN}" && -x "${BIN}" ]] || die "font test binary missing under ${CARGO_TARGET_DIR}"

RAW="${OUT}/servo-fonts.font.${STAMP}.strace"
SUM="${OUT}/servo-fonts.font.${STAMP}.summary.txt"

log "binary=${BIN}"
log "raw=${RAW}"

STRACE="$(resolve_strace)" || die "strace not found"
log "strace=${STRACE}"

# -f follows threads; filter noisy fds/polls after the run.
STRACE=""
for candidate in strace /usr/bin/strace /bin/strace; do
  if command -v "${candidate}" &>/dev/null; then STRACE="$(command -v "${candidate}")"; break; fi
  if [[ -x "${candidate}" ]]; then STRACE="${candidate}"; break; fi
done
[[ -n "${STRACE}" ]] || die "strace not found"
log "strace=${STRACE}"

"${STRACE}" -f -o "${RAW}" -e trace=mmap,munmap,mprotect,brk,mremap,madvise,read,write,openat,close \
  "${BIN}" --nocapture --test-threads=1 || true

{
  echo "stamp=${STAMP}"
  echo "binary=${BIN}"
  echo "node=$(hostname)"
  echo "--- syscall counts (filtered trace set) ---"
  awk '{print $NF}' "${RAW}" | sed 's/[0-9]*$//' | sort | uniq -c | sort -rn
  echo "--- mmap/munmap/mprotect (first 80) ---"
  grep -E '^(mmap|munmap|mprotect|brk|mremap|madvise)\(' "${RAW}" | head -80
  echo "--- brk tail (last 20) ---"
  grep '^brk(' "${RAW}" | tail -20 || true
} >"${SUM}"

log "summary=${SUM}"
cat "${SUM}"
