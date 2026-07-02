#!/usr/bin/env bash
# Serial cargo fetch for corpus apps (one srun, no compile/test).
# Usage: run_corpus_prefetch.sh <walltime> <mem_GB> <app> [app ...]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

TIME="${1:-1:00}"
MEM="${2:-16}"
shift 2 2>/dev/null || true

DEFAULT_CORPUS=(
  uutils-coreutils ripgrep ring rustls nix quiche git2-rs rusqlite bat fd
  tikv-codec polars-core vector-core react-compiler
)
if [[ $# -gt 0 ]]; then APPS=("$@"); else APPS=("${DEFAULT_CORPUS[@]}"); fi

IMAGE="$(resolve_image "${BSAN_IMAGE}")"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
prefetch_log="${OUTPUT_DIR}/corpus.prefetch.${stamp}.log"
mkdir -p "${OUTPUT_DIR}"

apps_shell=""
for app in "${APPS[@]}"; do
  apps_shell+=" $(printf '%q' "${app}")"
done

INNER="set -euo pipefail
export ACES_ROOT='${ACES_ROOT}'
source '${ACES_ROOT}/config.env'
source '${ACES_ROOT}/scripts/common.sh'
ensure_dirs
export_rust_env
if ! bsan_runtime_ready; then
  echo '=== setup_bsan (once) ==='
  '${ACES_ROOT}/scripts/setup_bsan.sh'
fi
prepare_bsan_cargo_env
for app in${apps_shell}; do
  echo '=== prefetch '\${app}' ==='
  BSAN_FETCH_ONLY=1 '${ACES_ROOT}/scripts/run_bsan_app.sh' \"\${app}\" || exit 1
done
echo 'status=prefetch_ok'
"

log "Prefetching deps for ${#APPS[@]} app(s) (serial, one job)"
log "Log -> ${prefetch_log}"

"${SCRIPT_DIR}/run_bsan_job.sh" -J "bsan-corpus-prefetch" "${IMAGE}" "${TIME}" "${MEM}" -- \
  bash -lc "${INNER}" 2>&1 | tee "${prefetch_log}"

if ! grep -q '^status=prefetch_ok' "${prefetch_log}"; then
  die "Prefetch failed; see ${prefetch_log}"
fi
log "Prefetch complete: ${prefetch_log}"
