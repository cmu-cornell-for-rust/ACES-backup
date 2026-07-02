#!/usr/bin/env bash
# Login-node status check (no compute allocation).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

ok=0
fail() { log "FAIL: $*"; ok=1; }
pass() { log "OK:   $*"; }

log "BSAN status for ${ACES_USER}"

[[ -d "${BSAN_DIR}/.git" ]] && pass "repo ${BSAN_DIR}" || fail "missing repo ${BSAN_DIR}"
[[ -f "${BSAN_IMAGE}" ]] && pass "image ${BSAN_IMAGE}" || pass "image missing (will use rust.sif fallback)"

if bsan_artifacts_ready; then
  pass "bsan artifacts on disk (toolchain + cargo-bsan)"
else
  fail "bsan artifacts missing"
fi

if bsan_toolchain_ready; then
  pass "bsan registered with rustup"
elif bsan_toolchain_installed; then
  pass "bsan toolchain on disk (rustup link happens inside compute jobs)"
else
  fail "bsan not registered with rustup"
fi

if rustc_bsan_works; then
  pass "rustc +bsan runs in this environment"
elif bsan_toolchain_installed; then
  pass "rustc +bsan deferred to container (login node glibc)"
else
  fail "rustc +bsan unavailable"
fi

n="$(count_user_jobs bsan)"
if [[ "${n}" -gt 0 ]]; then
  log "WARN: ${n} bsan job(s) still active (squeue -u \$USER)"
else
  pass "no active bsan jobs"
fi

if [[ "${ok}" -eq 0 ]]; then
  log "BSAN is ready for benchmarks."
  exit 0
fi

log "Run setup once: ${ACES_ROOT}/scripts/setup_bsan_job.sh"
exit 1
