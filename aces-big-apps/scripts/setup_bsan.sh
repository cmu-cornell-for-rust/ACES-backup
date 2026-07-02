#!/usr/bin/env bash
# Install BorrowSanitizer (BSAN_BRANCH from config.env). Run inside bsan.sif on a compute node.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

ensure_network
ensure_dirs

export RUSTUP_HOME CARGO_HOME
export PATH="${CARGO_HOME}/bin:/opt/cargo/bin:/opt/rust/cargo/bin:${PATH}"

bootstrap_rustup() {
  export_rust_env
  if rustc +nightly -vV >/dev/null 2>&1 && bsan_toolchain_ready; then
    return 0
  fi

  log "Bootstrapping rustup into ${CARGO_HOME}"
  # Never wipe an existing bsan toolchain — only remove broken non-bsan toolchains.
  if bsan_toolchain_installed; then
    find "${RUSTUP_HOME}/toolchains" -mindepth 1 -maxdepth 1 ! -name 'bsan' -exec rm -rf {} + 2>/dev/null || true
  else
    rm -rf "${RUSTUP_HOME}/toolchains"/* 2>/dev/null || true
  fi

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
  log "Updating ${BSAN_DIR} -> origin/${BSAN_BRANCH}"
  git -C "${BSAN_DIR}" fetch --depth 1 origin "${BSAN_BRANCH}"
  git -C "${BSAN_DIR}" checkout "${BSAN_BRANCH}" 2>/dev/null \
    || git -C "${BSAN_DIR}" checkout -B "${BSAN_BRANCH}"
  if git -C "${BSAN_DIR}" rev-parse --verify "origin/${BSAN_BRANCH}" >/dev/null 2>&1; then
    git -C "${BSAN_DIR}" reset --hard "origin/${BSAN_BRANCH}"
  else
    git -C "${BSAN_DIR}" reset --hard FETCH_HEAD
  fi
fi

bootstrap_rustup
cd "${BSAN_DIR}"

if ! bsan_toolchain_ready; then
  log "Running xb setup (downloads custom rustc; one-time, may take ~30-60 min)"
  unset RUSTUP_TOOLCHAIN
  rustup override unset 2>/dev/null || true
  RUSTUP_TOOLCHAIN=nightly ./xb setup
fi

log "Installing cargo-bsan + BSAN pass/runtime"
unset RUSTUP_TOOLCHAIN
rustup override unset 2>/dev/null || true
need_install=0
cargo_bsan_ready || need_install=1
[[ -f "${BSAN_DIR}/target/release/bsan-pass/build/libbsan_plugin.so" ]] || need_install=1
if [[ "${SETUP_FORCE:-0}" == 1 ]]; then
  need_install=1
  log "SETUP_FORCE=1: rebuilding cargo-bsan + BSAN pass/runtime"
fi
if [[ "${need_install}" -eq 1 ]]; then
  # xb install must run against the bsan toolchain (llvm-objcopy lives there).
  RUSTUP_TOOLCHAIN=bsan ./xb install || {
    cargo_bsan_ready || die "xb install failed and cargo-bsan missing"
    log "WARN: xb install exited non-zero but cargo-bsan is present; continuing"
  }
fi
rustup default bsan 2>/dev/null || true
cargo_bsan_ready || die "cargo-bsan missing after install"
ensure_bsan_toolchain_linked || true
bsan_runtime_ready || die "BSAN runtime not ready after setup"
log "BSAN ready: $(RUSTUP_TOOLCHAIN=bsan cargo-bsan -V 2>/dev/null || echo cargo-bsan)"
