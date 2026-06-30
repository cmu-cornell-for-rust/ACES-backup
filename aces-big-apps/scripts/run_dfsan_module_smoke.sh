#!/usr/bin/env bash
# Submit a tiny upstream DataFlowSanitizer smoke test using ACES' Clang module.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_DIR="${OUTPUT_DIR}/dfsan"
WORK_DIR="${USER_SCRATCH}/dfsan-module-smoke.${STAMP}"
LOG="${LOG_DIR}/dfsan-module-smoke.${STAMP}.log"
mkdir -p "${LOG_DIR}" "${WORK_DIR}"

SRUN_ARGS=(-A "${SLURM_ACCOUNT}" --nodes=1 --ntasks-per-node=1 --cpus-per-task=1 --mem=4G --time=00:05:00 --job-name=dfsan-map-module)

echo "Submitting DFSan module smoke: ${LOG}"
srun "${SRUN_ARGS[@]}" bash -s -- "${WORK_DIR}" "${LOG}" <<'NODE'
set -euo pipefail
WORK_DIR="$1"
LOG="$2"
SRC="${WORK_DIR}/dfsan_smoke.c"
PIE_BIN="${WORK_DIR}/dfsan_smoke_pie"
NOPIE_BIN="${WORK_DIR}/dfsan_smoke_nopie"

cat > "${SRC}" <<'C'
#include <stdio.h>
#include <stdlib.h>

static void dump_maps_prefix(void) {
  FILE *f = fopen("/proc/self/maps", "r");
  if (!f) return;
  char buf[256];
  puts("--- /proc/self/maps first 40 lines ---");
  for (int i = 0; i < 40 && fgets(buf, sizeof(buf), f); ++i) {
    fputs(buf, stdout);
  }
  fclose(f);
}

int main(int argc, char **argv) {
  printf("dfsan smoke argc=%d argv0=%s\n", argc, argv[0]);
  dump_maps_prefix();
  return 0;
}
C

run_case() {
  local label="$1"
  local bin="$2"
  echo "--- run ${label} ---"
  set +e
  DFSAN_OPTIONS=verbosity=2 "${bin}" alpha beta
  local rc=$?
  set -e
  echo "${label}_exit=${rc}"
}

{
  echo "start=$(date -u +%Y%m%dT%H%M%SZ)"
  echo "host=$(hostname)"
  echo "work_dir=${WORK_DIR}"
  module load GCCcore/13.3.0 Clang/18.1.8
  echo "clang=$(command -v clang)"
  clang --version | head -3

  echo "--- compile pie ---"
  clang -fsanitize=dataflow -g -O0 -fPIE -pie "${SRC}" -o "${PIE_BIN}"
  echo "pie_binary=${PIE_BIN}"

  echo "--- compile nopie ---"
  clang -fsanitize=dataflow -g -O0 -fno-pie -no-pie "${SRC}" -o "${NOPIE_BIN}"
  echo "nopie_binary=${NOPIE_BIN}"

  run_case pie "${PIE_BIN}"
  run_case nopie "${NOPIE_BIN}"
  echo "status=ok"
} 2>&1 | tee "${LOG}"

echo "dfsan_module_log=${LOG}"
NODE
