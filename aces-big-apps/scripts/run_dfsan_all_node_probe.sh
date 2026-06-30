#!/usr/bin/env bash
# Cheaply probe DFSan fixed-memory-map compatibility across ACES CPU nodes.
# Uses prebuilt tiny DFSan binaries; no compile, one short 1-core task per node.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_DIR="${OUTPUT_DIR}/dfsan"
LOG="${LOG_DIR}/dfsan-all-node-probe.${STAMP}.log"
CSV="${LOG_DIR}/dfsan-all-node-probe.${STAMP}.csv"
PIE_BIN="${DFSAN_PIE_BIN:-/scratch/user/u.ra353315/dfsan-module-smoke.20260630T144344Z/dfsan_smoke_pie}"
NOPIE_BIN="${DFSAN_NOPIE_BIN:-/scratch/user/u.ra353315/dfsan-module-smoke.20260630T144344Z/dfsan_smoke_nopie}"
CHECK_NOPIE="${CHECK_NOPIE:-0}"
IMMEDIATE_SECONDS="${IMMEDIATE_SECONDS:-5}"
RUN_TIMEOUT_SECONDS="${RUN_TIMEOUT_SECONDS:-8}"
MEM="${MEM:-256M}"
WALLTIME="${WALLTIME:-00:01:00}"
mkdir -p "${LOG_DIR}"

[[ -x "${PIE_BIN}" ]] || { echo "Missing PIE DFSan binary: ${PIE_BIN}" >&2; exit 1; }
if [[ "${CHECK_NOPIE}" == "1" ]]; then
  [[ -x "${NOPIE_BIN}" ]] || { echo "Missing non-PIE DFSan binary: ${NOPIE_BIN}" >&2; exit 1; }
fi

if [[ $# -gt 0 ]]; then
  NODES=("$@")
else
  mapfile -t NODES < <(sinfo -N -h -p cpu -o '%N %T' \
    | awk '$2 ~ /^(idle|mixed|mixed-)$/ {print $1}' \
    | sort -u)
fi

classify_output() {
  local rc="$1"
  local output="$2"
  if grep -q 'FATAL: Memory range 0x110000000000 - 0x1fffffffffff is not available' <<<"${output}"; then
    echo "origin2_unavailable"
  elif grep -q 'dfsan smoke argc=' <<<"${output}"; then
    echo "ok"
  elif [[ "${rc}" == "124" ]]; then
    echo "timeout"
  else
    echo "other_failure"
  fi
}

probe_one_binary() {
  local node="$1"
  local label="$2"
  local bin="$3"
  local output rc result
  set +e
  output=$(srun -A "${SLURM_ACCOUNT}" --partition=cpu --nodes=1 --ntasks=1 \
    --cpus-per-task=1 --mem="${MEM}" --time="${WALLTIME}" \
    --job-name="dfsan-${node}" --nodelist="${node}" \
    --immediate="${IMMEDIATE_SECONDS}" \
    bash -s -- "${node}" "${bin}" "${RUN_TIMEOUT_SECONDS}" <<'NODE' 2>&1
set -euo pipefail
node="$1"
bin="$2"
run_timeout="$3"
echo "allocated_node=$(hostname) requested_node=${node}"
timeout "${run_timeout}" env DFSAN_OPTIONS=verbosity=1 "${bin}" alpha beta
NODE
  )
  rc=$?
  set -e
  result=$(classify_output "${rc}" "${output}")
  echo "RESULT node=${node} binary=${label} rc=${rc} result=${result}"
  printf '%s\n' "${output}" | grep -E 'allocated_node=|dfsan_init|FATAL:|WARNING:|dfsan smoke argc=|Unable to allocate|Job allocation|timed out|Segmentation fault' || true
  echo "${node},${label},${rc},${result}" >> "${CSV}"
}

{
  echo "start=${STAMP}"
  echo "nodes=${NODES[*]:-}"
  echo "pie_binary=${PIE_BIN}"
  echo "nopie_binary=${NOPIE_BIN}"
  echo "check_nopie=${CHECK_NOPIE}"
  echo "immediate_seconds=${IMMEDIATE_SECONDS}"
  echo "run_timeout_seconds=${RUN_TIMEOUT_SECONDS}"
  echo "mem=${MEM}"
  echo "walltime=${WALLTIME}"
  echo "node,binary,rc,result" > "${CSV}"

  for node in "${NODES[@]}"; do
    echo "=== ${node} ==="
    probe_one_binary "${node}" pie "${PIE_BIN}"
    if [[ "${CHECK_NOPIE}" == "1" ]]; then
      probe_one_binary "${node}" nopie "${NOPIE_BIN}"
    fi
  done

  echo "csv=${CSV}"
  echo "status=ok"
} 2>&1 | tee "${LOG}"

echo "dfsan_all_node_probe_log=${LOG}"
echo "dfsan_all_node_probe_csv=${CSV}"
