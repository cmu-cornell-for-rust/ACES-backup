#!/usr/bin/env bash
# Run BSAN tests for one app. Mirrors run_miri_dataset.sh per-crate flow.
# Usage: run_bsan_app.sh <app-name> [extra cargo args...]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

APP="${1:?app name required}"
shift || true
APPS_TSV="${ACES_ROOT}/datasets/big-apps/apps.tsv"

if [[ -z "$(awk -F '\t' -v app="${APP}" '$1 == app {print; exit}' "${APPS_TSV}")" ]]; then
  die "Unknown app '${APP}'. See ${APPS_TSV}"
fi

subdir="$(app_field "${APP}" 4)"
test_cmd="$(app_field "${APP}" 6)"
app_dir="${APPS_DIR}/${APP}/${subdir}"
[[ -d "${app_dir}" ]] || die "Missing checkout: ${app_dir} (run fetch_apps.sh first)"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
log_file="${OUTPUT_DIR}/${APP}.${stamp}.log"
csv="${OUTPUT_DIR}/results.csv"
mkdir -p "${OUTPUT_DIR}"

apply_bsan_stack_limit
export CARGO_TARGET_DIR="${app_dir}/target/bsan-${APP}"
export CARGO_BUILD_JOBS=1

export_rust_env
if ! bsan_runtime_ready; then
  log "BSAN not ready; running setup_bsan.sh (may take ~30-60 min)"
  unset RUSTUP_TOOLCHAIN BSAN_RUST_ONLY
  "${SCRIPT_DIR}/setup_bsan.sh"
fi
ensure_bsan_toolchain_linked || true
bsan_runtime_ready || die "BSAN setup incomplete"
prepare_bsan_cargo_env
prepare_bsan_native_cc_env
BSAN_CARGO=(cargo +bsan)

# See prepare_bsan_native_cc_env() in common.sh — host cc for C build scripts only.

log "App=${APP} dir=${app_dir}"
log "Logs -> ${log_file}"

{
  echo "app=${APP}"
  echo "start=${stamp}"
  echo "test_cmd=${test_cmd} $*"
  echo "app_dir=${app_dir}"
  echo "target_dir=${CARGO_TARGET_DIR}"
  bsan_revision_line || true
  echo "rustc=$(rustc +bsan -V 2>/dev/null | head -1 || echo unknown)"
  echo "stack_soft_kb=$(ulimit -S -s)"
  echo "BSAN_RUST_ONLY=${BSAN_RUST_ONLY:-}"
  echo "BSAN_OPTIONS=${BSAN_OPTIONS:-}"

  cd "${app_dir}"
  prepare_app_build_fixes "${APP}" "${app_dir}"

  if [[ "${BSAN_CLEAN:-0}" == 1 ]]; then
    echo "--- cargo clean ---"
    "${BSAN_CARGO[@]}" clean
  fi

  if [[ "${BSAN_SKIP_FETCH:-0}" != 1 ]]; then
    echo "--- cargo fetch ---"
    if ! "${BSAN_CARGO[@]}" fetch; then
      echo "status=fetch_error"
      exit 1
    fi
  else
    echo "fetch=skipped"
  fi

  if [[ "${BSAN_FETCH_ONLY:-0}" == 1 ]]; then
    echo "status=fetch_ok"
    exit 0
  fi

  echo "--- compile (BSAN test --no-run) ---"
  compile_start=$(date +%s)
  if ! eval "${test_cmd} --no-run $*"; then
    echo "status=build_error"
    exit 1
  fi
  compile_end=$(date +%s)

  echo "--- run tests ---"
  run_start=$(date +%s)
  if eval "${test_cmd} $*"; then
    run_end=$(date +%s)
    echo "run_seconds=$((run_end - run_start))"
    echo "status=ok"
  else
    run_end=$(date +%s)
    echo "run_seconds=$((run_end - run_start))"
    echo "status=test_error"
    exit 1
  fi
} 2>&1 | tee "${log_file}"

if [[ ! -f "${csv}" ]]; then
  echo "timestamp,app,status,compile_seconds,run_seconds,log" > "${csv}"
fi
status=$(grep '^status=' "${log_file}" | tail -1 | cut -d= -f2)
compile=$(grep '^compile_seconds=' "${log_file}" | tail -1 | cut -d= -f2 || echo "")
run=$(grep '^run_seconds=' "${log_file}" | tail -1 | cut -d= -f2 || echo "")
echo "${stamp},${APP},${status},${compile},${run},${log_file}" >> "${csv}"
