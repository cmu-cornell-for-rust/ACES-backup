#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

TIME="${INVESTIGATE_TIME:-1:30}"
MEM="${INVESTIGATE_MEM:-24}"
IMAGE="$(resolve_image "${BSAN_IMAGE}")"
ensure_dirs

INNER="set -euo pipefail; export ACES_ROOT='${ACES_ROOT}'; source '${ACES_ROOT}/config.env'; source '${ACES_ROOT}/scripts/common.sh'; ensure_dirs; '${ACES_ROOT}/scripts/investigate_corpus_gdb_inner.sh'"

"${SCRIPT_DIR}/run_bsan_job.sh" --batch -J "bsan-gdb" "${IMAGE}" "${TIME}" "${MEM}" -- bash -lc "${INNER}"
