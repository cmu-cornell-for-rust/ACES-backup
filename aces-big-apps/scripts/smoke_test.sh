#!/usr/bin/env bash
# Quick smoke test: requires BSAN already installed (setup_bsan_job.sh first).
# Usage: ./scripts/smoke_test.sh [app-name]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

APP="${1:-react-compiler}"
TIME="${SMOKE_TIME:-1:30}"
MEM="${SMOKE_MEM:-16}"

ensure_dirs
"${SCRIPT_DIR}/fetch_apps.sh" "${APP}"
"${SCRIPT_DIR}/preflight.sh" "${APP}"

IMAGE="$(resolve_image "${BSAN_IMAGE}")"
log "Smoke test: app=${APP} image=${IMAGE} mem=${MEM}G time=${TIME}"

INNER="set -euo pipefail; export ACES_ROOT='${ACES_ROOT}'; source '${ACES_ROOT}/config.env'; source '${ACES_ROOT}/scripts/common.sh'; ensure_dirs; '${ACES_ROOT}/scripts/run_bsan_app.sh' '${APP}'"

"${SCRIPT_DIR}/run_bsan_job.sh" -J "bsan-smoke-${APP}" "${IMAGE}" "${TIME}" "${MEM}" -- "${INNER}"

log "Smoke test finished. Logs: ${OUTPUT_DIR}/"
