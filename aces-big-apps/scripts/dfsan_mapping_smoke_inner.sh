#!/usr/bin/env bash
# Runs inside the BSAN container on a compute node.
# Build and run tiny C programs with upstream DataFlowSanitizer to compare
# ACES/Singularity virtual-address behavior against BSAN.
set -euo pipefail
source "${ACES_ROOT}/config.env"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_DIR="${OUTPUT_DIR}/dfsan"
WORK_DIR="${USER_SCRATCH}/dfsan-smoke.${STAMP}"
LOG="${LOG_DIR}/dfsan-smoke.${STAMP}.log"
mkdir -p "${LOG_DIR}" "${WORK_DIR}"

CLANG="${RUSTUP_HOME}/toolchains/bsan/bin/clang-22"
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
  echo "start=${STAMP}"
  echo "host=$(hostname)"
  echo "work_dir=${WORK_DIR}"
  echo "clang=${CLANG}"
  "${CLANG}" --version | head -3

  echo "--- compile pie ---"
  "${CLANG}" -fsanitize=dataflow -g -O0 -fPIE -pie "${SRC}" -o "${PIE_BIN}"
  echo "pie_binary=${PIE_BIN}"

  echo "--- compile nopie ---"
  "${CLANG}" -fsanitize=dataflow -g -O0 -fno-pie -no-pie "${SRC}" -o "${NOPIE_BIN}"
  echo "nopie_binary=${NOPIE_BIN}"

  run_case pie "${PIE_BIN}"
  run_case nopie "${NOPIE_BIN}"
  echo "status=ok"
} 2>&1 | tee "${LOG}"

echo "dfsan_log=${LOG}"
