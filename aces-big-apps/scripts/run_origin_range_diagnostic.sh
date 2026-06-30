#!/usr/bin/env bash
# Diagnose what occupies DFSan/BSAN origin-2 range on one ACES node.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

NODE="${1:-ac001}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_DIR="${OUTPUT_DIR}/dfsan"
WORK_DIR="${USER_SCRATCH}/origin-range-diag.${STAMP}"
LOG="${LOG_DIR}/origin-range-diag.${NODE}.${STAMP}.log"
mkdir -p "${LOG_DIR}" "${WORK_DIR}"

SRUN_ARGS=(-A "${SLURM_ACCOUNT}" --partition=cpu --nodes=1 --ntasks=1 --cpus-per-task=1 --mem=512M --time=00:02:00 --job-name="origin-diag-${NODE}" --nodelist="${NODE}" --immediate=30)

echo "Submitting origin range diagnostic on ${NODE}: ${LOG}"
srun "${SRUN_ARGS[@]}" bash -s -- "${WORK_DIR}" "${LOG}" <<'NODE'
set -euo pipefail
WORK_DIR="$1"
LOG="$2"
SRC="${WORK_DIR}/origin_range_diag.c"
BIN="${WORK_DIR}/origin_range_diag"

cat > "${SRC}" <<'C'
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/personality.h>
#include <sys/utsname.h>
#include <unistd.h>

static const unsigned long long TARGET_START = 0x110000000000ULL;
static const unsigned long long TARGET_END   = 0x200000000000ULL;

static void print_file_one_line(const char *path) {
  FILE *f = fopen(path, "r");
  if (!f) {
    printf("%s=<unreadable errno=%d %s>\n", path, errno, strerror(errno));
    return;
  }
  char buf[256];
  if (fgets(buf, sizeof(buf), f)) {
    buf[strcspn(buf, "\n")] = 0;
    printf("%s=%s\n", path, buf);
  }
  fclose(f);
}

static int overlaps(unsigned long long start, unsigned long long end) {
  return start < TARGET_END && end > TARGET_START;
}

static void dump_overlaps(void) {
  FILE *f = fopen("/proc/self/maps", "r");
  if (!f) {
    printf("maps_error errno=%d %s\n", errno, strerror(errno));
    return;
  }
  char line[1024];
  int count = 0;
  printf("target_range=%#llx-%#llx\n", TARGET_START, TARGET_END);
  printf("--- overlaps with target range ---\n");
  while (fgets(line, sizeof(line), f)) {
    unsigned long long start = 0, end = 0;
    if (sscanf(line, "%llx-%llx", &start, &end) == 2 && overlaps(start, end)) {
      fputs(line, stdout);
      count++;
    }
  }
  printf("overlap_count=%d\n", count);
  fclose(f);
}

static void try_reserve_whole_range(void) {
#ifdef MAP_FIXED_NOREPLACE
  unsigned long long size = TARGET_END - TARGET_START;
  void *addr = (void *)(unsigned long)TARGET_START;
  errno = 0;
  void *p = mmap(addr, (size_t)size, PROT_NONE,
                 MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE | MAP_FIXED_NOREPLACE,
                 -1, 0);
  if (p == MAP_FAILED) {
    printf("mmap_fixed_noreplace_whole_range=failed errno=%d %s\n", errno, strerror(errno));
  } else {
    printf("mmap_fixed_noreplace_whole_range=success addr=%p size=%#llx\n", p, size);
    munmap(p, (size_t)size);
  }
#else
  printf("mmap_fixed_noreplace_whole_range=unsupported\n");
#endif
}

static void print_basic(void) {
  struct utsname uts;
  uname(&uts);
  printf("pid=%ld\n", (long)getpid());
  printf("hostname=%s\n", uts.nodename);
  printf("kernel=%s %s %s\n", uts.sysname, uts.release, uts.version);
  int pers = personality(0xffffffffUL);
  printf("personality=%#x ADDR_NO_RANDOMIZE=%s\n", pers,
         (pers >= 0 && (pers & ADDR_NO_RANDOMIZE)) ? "set" : "unset");
  print_file_one_line("/proc/sys/kernel/randomize_va_space");
  print_file_one_line("/proc/sys/vm/mmap_rnd_bits");
  print_file_one_line("/proc/sys/vm/mmap_rnd_compat_bits");
}

int main(int argc, char **argv, char **envp) {
  const char *stage = getenv("ORIGIN_DIAG_REEXEC") ? "after_ADDR_NO_RANDOMIZE_reexec" : "initial";
  printf("stage=%s\n", stage);
  print_basic();
  dump_overlaps();
  try_reserve_whole_range();

  if (!getenv("ORIGIN_DIAG_REEXEC")) {
    int oldp = personality(0xffffffffUL);
    if (oldp < 0) {
      printf("personality_read_failed errno=%d %s\n", errno, strerror(errno));
      return 0;
    }
    int newp = oldp | ADDR_NO_RANDOMIZE;
    errno = 0;
    int rc = personality((unsigned long)newp);
    printf("set_ADDR_NO_RANDOMIZE rc=%d errno=%d %s\n", rc, errno, strerror(errno));
    setenv("ORIGIN_DIAG_REEXEC", "1", 1);
    fflush(stdout);
    execv(argv[0], argv);
    printf("execv_failed errno=%d %s\n", errno, strerror(errno));
  }
  return 0;
}
C

{
  echo "start=$(date -u +%Y%m%dT%H%M%SZ)"
  echo "allocated_node=$(hostname)"
  echo "work_dir=${WORK_DIR}"
  command -v gcc
  gcc -O0 -g "${SRC}" -o "${BIN}"
  "${BIN}"
  echo "status=ok"
} 2>&1 | tee "${LOG}"

echo "origin_range_diag_log=${LOG}"
NODE
