#!/usr/bin/env bash
# Probe whether upstream DFSan can reserve its fixed shadow/origin layout on
# selected ACES nodes. Uses already-built tiny DFSan binaries; no compilation.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_DIR="${OUTPUT_DIR}/dfsan"
LOG="${LOG_DIR}/dfsan-node-probe.${STAMP}.log"
PIE_BIN="${DFSAN_PIE_BIN:-/scratch/user/u.ra353315/dfsan-module-smoke.20260630T144344Z/dfsan_smoke_pie}"
NOPIE_BIN="${DFSAN_NOPIE_BIN:-/scratch/user/u.ra353315/dfsan-module-smoke.20260630T144344Z/dfsan_smoke_nopie}"
mkdir -p "${LOG_DIR}"

if [[ $# -gt 0 ]]; then
  NODES=("$@")
else
  NODES=(ac001 ac005 ac014 ac020 ac035)
fi

[[ -x "${PIE_BIN}" ]] || { echo "Missing PIE DFSan binary: ${PIE_BIN}" >&2; exit 1; }
[[ -x "${NOPIE_BIN}" ]] || { echo "Missing non-PIE DFSan binary: ${NOPIE_BIN}" >&2; exit 1; }

{
  echo "start=${STAMP}"
  echo "pie_binary=${PIE_BIN}"
  echo "nopie_binary=${NOPIE_BIN}"
  echo "nodes=${NODES[*]}"

  for node in "${NODES[@]}"; do
    echo "=== node ${node} ==="
    set +e
    srun -A "${SLURM_ACCOUNT}" --partition=cpu --nodes=1 --ntasks-per-node=1 \
      --cpus-per-task=1 --mem=1G --time=00:02:00 --job-name="dfsan-${node}" \
      --nodelist="${node}" --immediate=30 \
      bash -s -- "${node}" "${PIE_BIN}" "${NOPIE_BIN}" <<'NODE'
set -euo pipefail
node="$1"
pie="$2"
nopie="$3"

echo "allocated_node=$(hostname) requested_node=${node}"
uname -a

run_case() {
  local label="$1"
  local bin="$2"
  echo "--- ${label} ---"
  set +e
  timeout 20 env DFSAN_OPTIONS=verbosity=1 "${bin}" alpha beta
  local rc=$?
  set -e
  echo "${label}_exit=${rc}"
}

run_case pie "${pie}"
run_case nopie "${nopie}"
NODE
    rc=$?
    set -e
    echo "node=${node} srun_exit=${rc}"
  done

  echo "status=ok"
} 2>&1 | tee "${LOG}"

echo "dfsan_node_probe_log=${LOG}"
