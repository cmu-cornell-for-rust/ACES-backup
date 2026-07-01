#!/usr/bin/env bash
# Quick strace probe: Servo jemalloc malloc/realloc/usable_size (no full Servo build).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

SERVO_DIR="${APPS_DIR}/servo-xpath"
ALLOCATOR_RS="${SERVO_DIR}/components/allocator/lib.rs"
[[ -f "${ALLOCATOR_RS}" ]] || die "Missing ${ALLOCATOR_RS}"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
out="${OUTPUT_DIR}/servo-jemalloc.strace.${stamp}"
mkdir -p "${OUTPUT_DIR}"
log_file="${out}.log"
trace_file="${out}.trace"
summary_file="${out}.summary.txt"
probe_dir="${CARGO_TEMP}/jemalloc-strace-probe-${stamp}"
mkdir -p "${probe_dir}/src"

exec > >(tee -a "${log_file}") 2>&1
log "jemalloc strace probe log=${log_file}"

STRACE="$(resolve_strace)" || die "strace not found (stage ${USER_SCRATCH}/tools/strace-bundle/bin/strace)"
log "strace=${STRACE}"

cat >"${probe_dir}/src/main.rs" <<'RS'
fn main() {
    unsafe {
        let p = servo_allocator::libc_compat::malloc(4096);
        assert!(!p.is_null());
        let q = servo_allocator::libc_compat::realloc(p, 8192);
        assert!(!q.is_null());
        let _sz = servo_allocator::usable_size(q);
        servo_allocator::libc_compat::free(q);
    }
    println!("ok");
}
RS

cat >"${probe_dir}/Cargo.toml" <<EOF
[package]
name = "jemalloc-strace-probe"
version = "0.1.0"
edition = "2021"

[dependencies]
servo-allocator = { path = "${SERVO_DIR}/components/allocator" }
EOF

cd "${probe_dir}"
export CARGO_TARGET_DIR="${probe_dir}/target"
export RUSTUP_TOOLCHAIN="${RUSTUP_TOOLCHAIN:-stable}"
export PATH="${CARGO_HOME}/bin:${PATH}"

echo "--- cargo build probe ---"
cargo build -q

bin="${CARGO_TARGET_DIR}/debug/jemalloc-strace-probe"
[[ -x "${bin}" ]] || die "probe binary missing: ${bin}"
echo "binary=${bin}"

echo "--- strace probe ---"
set +e
"${STRACE}" -f -tt -o "${trace_file}" \
  -e trace=mmap,mmap2,munmap,mremap,brk,madvise,memfd_create \
  -- "${bin}"
rc=$?
set -e
echo "probe_exit=${rc}"

{
  echo "binary=${bin}"
  echo "probe_exit=${rc}"
  echo "=== syscall counts (filtered) ==="
  awk '{print $NF}' "${trace_file}" | sed 's/(.*//' | sort | uniq -c | sort -rn
  echo "=== mmap/munmap/mremap/brk lines ==="
  grep -E 'mmap|munmap|mremap|brk\(' "${trace_file}" || true
  echo "=== totals ==="
  echo -n "mmap: "; grep -c 'mmap' "${trace_file}" || true
  echo -n "munmap: "; grep -c 'munmap' "${trace_file}" || true
  echo -n "brk: "; grep -c 'brk(' "${trace_file}" || true
} | tee "${summary_file}"

echo "summary_file=${summary_file}"
