#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../config.env"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

ensure_network() {
  if command -v module >/dev/null 2>&1; then
    module load WebProxy 2>/dev/null || true
  fi
}

ensure_dirs() {
  mkdir -p "${CARGO_TEMP}" "${CARGO_HOME}" "${RUSTUP_HOME}" "${APPS_DIR}" "${OUTPUT_DIR}"
}

# Bash `read` collapses consecutive tabs; use awk for apps.tsv columns.
app_field() {
  local app="$1" col="$2"
  local tsv="${ACES_ROOT}/datasets/big-apps/apps.tsv"
  awk -F '\t' -v app="${app}" -v col="${col}" '$1 == app {print $col; exit}' "${tsv}"
}

resolve_image() {
  local image="${1:-${BSAN_IMAGE}}"
  if [[ ! -f "${image}" ]]; then
    image="${GROUP_CONTAINERS}/rust.sif"
    log "WARN: ${BSAN_IMAGE} missing; falling back to ${image}"
  fi
  if [[ "${image}" != /* ]]; then
    image="${GROUP_CONTAINERS}/${image##*/}"
  fi
  [[ -f "${image}" ]] || die "Missing container image ${image}"
  printf '%s\n' "${image}"
}

count_user_jobs() {
  local pattern="${1:-bsan}"
  squeue -h -u "${ACES_USER}" -o "%j" 2>/dev/null | grep -c "${pattern}" || true
}

guard_no_duplicate_jobs() {
  local pattern="${1:-bsan}"
  local force="${2:-0}"
  local n
  n="$(count_user_jobs "${pattern}")"
  if [[ "${n}" -gt 0 && "${force}" -eq 0 ]]; then
    die "Refusing to submit: ${n} job(s) matching '${pattern}' already queued/running. Check: squeue -u \$USER"
  fi
}

export_rust_env() {
  export RUSTUP_HOME CARGO_HOME
  export PATH="${CARGO_HOME}/bin:/opt/cargo/bin:/opt/rust/cargo/bin:${PATH}"
}

bsan_toolchain_installed() {
  [[ -x "${RUSTUP_HOME}/toolchains/bsan/bin/rustc" ]]
}

bsan_toolchain_ready() {
  export_rust_env
  command -v rustup >/dev/null 2>&1 \
    && rustup toolchain list 2>/dev/null | grep -qE '^bsan( |$)'
}

rustc_bsan_works() {
  export_rust_env
  rustc +bsan -vV >/dev/null 2>&1
}

rustup_healthy() {
  export_rust_env
  command -v rustup >/dev/null 2>&1 || return 1
  if bsan_toolchain_ready; then
    rustc_bsan_works
  else
    rustc +nightly -vV >/dev/null 2>&1 || rustc -vV >/dev/null 2>&1
  fi
}

cargo_bsan_ready() {
  [[ -x "${CARGO_HOME}/bin/cargo-bsan" ]] || command -v cargo-bsan >/dev/null 2>&1
}

# Login-node safe: artifacts exist; rustc may not run on host glibc.
bsan_artifacts_ready() {
  bsan_toolchain_installed && cargo_bsan_ready
}

# Inside container/compute node: toolchain actually executes.
bsan_runtime_ready() {
  bsan_artifacts_ready && rustc_bsan_works
}

bsan_ready() {
  bsan_artifacts_ready
}

require_bsan_ready() {
  if bsan_artifacts_ready; then
    return 0
  fi
  die "BSAN is not ready. Run once on a login node: ${ACES_ROOT}/scripts/setup_bsan_job.sh"
}

run_job() {
  local runner="${GROUP_SCRIPTS}/run_job.sh"
  if [[ -x "${runner}" ]]; then
    "${runner}" "$@"
  else
    die "Missing ${runner}. Deploy aces/ under ${GROUP_ROOT} and use the portal terminal."
  fi
}
