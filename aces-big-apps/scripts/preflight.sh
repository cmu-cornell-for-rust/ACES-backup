#!/usr/bin/env bash
# Login-node preflight before any srun (no tokens spent).
# Usage: preflight.sh [app-name]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

APP="${1:-}"
FORCE="${PREFLIGHT_FORCE:-0}"

guard_no_duplicate_jobs "bsan" "${FORCE}"

if [[ -n "${APP}" ]]; then
  subdir="$(app_field "${APP}" 4)"
  app_dir="${APPS_DIR}/${APP}/${subdir}"
  [[ -d "${app_dir}" ]] || die "Missing checkout ${app_dir}. Run: fetch_apps.sh ${APP}"
  log "OK:   app ${APP} checkout present"
fi

require_bsan_ready
resolve_image "${BSAN_IMAGE}" >/dev/null
log "OK:   preflight passed"
