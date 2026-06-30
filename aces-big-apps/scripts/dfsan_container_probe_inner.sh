#!/usr/bin/env bash
# Runs inside the BSAN container on a compute node; uses module-built DFSan binaries.
set -euo pipefail
source "${ACES_ROOT}/config.env"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_DIR="${OUTPUT_DIR}/dfsan"
LOG="${LOG_DIR}/dfsan-container-probe.${STAMP}.log"
PIE_BIN="${DFSAN_PIE_BIN:-/scratch/user/u.ra353315/dfsan-module-smoke.20260630T144344Z/dfsan_smoke_pie}"
NOPIE_BIN="${DFSAN_NOPIE_BIN:-/scratch/user/u.ra353315/dfsan-module-smoke.20260630T144344Z/dfsan_smoke_nopie}"
mkdir -p "${LOG_DIR}"

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

{
  echo "start=${STAMP}"
  echo "host=$(hostname)"
  echo "container=bsan.sif"
  echo "pie_binary=${PIE_BIN}"
  echo "nopie_binary=${NOPIE_BIN}"
  run_case pie "${PIE_BIN}"
  run_case nopie "${NOPIE_BIN}"
  echo "status=ok"
} 2>&1 | tee "${LOG}"

echo "dfsan_container_probe_log=${LOG}"
