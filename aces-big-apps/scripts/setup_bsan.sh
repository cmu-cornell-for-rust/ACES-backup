#!/usr/bin/env bash
# Install BorrowSanitizer (icmccorm/thread-docs). Run inside bsan.sif on a compute node.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

ensure_network
ensure_dirs

export RUSTUP_HOME CARGO_HOME
export PATH="${CARGO_HOME}/bin:/opt/cargo/bin:/opt/rust/cargo/bin:${PATH}"

bootstrap_rustup() {
  if rustup_healthy; then
    return 0
  fi

  log "Bootstrapping rustup into ${CARGO_HOME}"
  rm -rf "${RUSTUP_HOME}/toolchains"/* 2>/dev/null || true

  if [[ ! -x "${CARGO_HOME}/bin/rustup" ]]; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --no-modify-path --default-toolchain nightly
  fi

  export PATH="${CARGO_HOME}/bin:${PATH}"
  rustup toolchain install nightly --profile minimal
  rustup default nightly
  rustup component add rust-src rustfmt clippy

  rustup_healthy || die "rustup bootstrap failed"
}

if [[ ! -d "${BSAN_DIR}/.git" ]]; then
  log "Cloning ${BSAN_REPO} (${BSAN_BRANCH})"
  git clone --branch "${BSAN_BRANCH}" --depth 1 "${BSAN_REPO}" "${BSAN_DIR}"
else
  log "Updating ${BSAN_DIR}"
  git -C "${BSAN_DIR}" fetch origin "${BSAN_BRANCH}"
  git -C "${BSAN_DIR}" checkout "${BSAN_BRANCH}"
  git -C "${BSAN_DIR}" pull --ff-only origin "${BSAN_BRANCH}" || true
fi

bootstrap_rustup
cd "${BSAN_DIR}"

if ! bsan_toolchain_ready; then
  log "Running xb setup (downloads custom rustc; one-time, may take ~30-60 min)"
  unset RUSTUP_TOOLCHAIN
  rustup override unset 2>/dev/null || true
  RUSTUP_TOOLCHAIN=nightly ./xb setup
fi

log "Installing cargo-bsan"
unset RUSTUP_TOOLCHAIN
rustup override unset 2>/dev/null || true
RUSTUP_TOOLCHAIN=nightly ./xb install
rustup default bsan

cargo_bsan_ready || die "cargo-bsan missing after install"
log "BSAN ready: $(cargo bsan --version 2>/dev/null || cargo bsan -V)"
