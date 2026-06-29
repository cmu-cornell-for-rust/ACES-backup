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

export RUSTUP_HOME CARGO_HOME
export PATH="${CARGO_HOME}/bin:${PATH}"
rustup default bsan >/dev/null

cd "${app_dir}"
log "App=${APP} dir=${app_dir}"
log "Logs -> ${log_file}"

{
  echo "app=${APP}"
  echo "start=${stamp}"
  echo "test_cmd=${test_cmd} $*"

  echo "--- cargo clean ---"
  cargo clean

  echo "--- cargo fetch ---"
  if ! cargo fetch; then
    echo "status=fetch_error"
    exit 1
  fi

  echo "--- compile (cargo bsan test --no-run) ---"
  compile_start=$(date +%s)
  if ! eval "${test_cmd} --no-run $*"; then
    echo "status=build_error"
    exit 1
  fi
  compile_end=$(date +%s)
  echo "compile_seconds=$((compile_end - compile_start))"

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
