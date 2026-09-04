#!/usr/bin/env bash
#
# Usage: run_bench_dataset.sh [options] <mode> <image> [walltime] <dataset> [extra]
#
#   <mode>      miri | bsan | rust -- which tool runs the tests:
#                 miri: MIRIFLAGS=<common+extra> cargo miri test
#                 bsan: BSAN_OPTIONS=<common+extra> cargo bsan test
#                 rust: plain cargo test (extra ignored)
#   <image>     image/SIF name under the group containers dir (e.g. miri, bsan,
#               rust, visit-gc). Mode and image are separate so variant images
#               (e.g. a patched miri) can still be driven in miri mode.
#   [walltime]  walltime per REGULAR sbatch job, HH or HH:MM (default 2).
#               Only needs to cover the non-slowlist crates on one worker --
#               short+narrow jobs backfill into scheduling gaps that long
#               ones never fit. Slowlist jobs use --slow-walltime instead.
#               (Recognized positionally by shape, so a purely numeric
#               dataset name would need the walltime spelled out.)
#   <dataset>   folder under the group datasets dir holding crate subdirectories.
#   [extra]     mode-specific extras: -Z Miri flags (miri) or colon-separated
#               BSAN_OPTIONS (bsan), appended to the built-in set.
#
# Options:
#   --tests FILE      tests CSV (crate,tests,contains_ffi -- as produced by
#                     list_tests.sh). Default: <outputs>/tests-<dataset>.csv
#   --no-ffi          only run crates whose contains_ffi column is exactly
#                     "false" (both "true" and "scan_failed" are skipped)
#   --ignore FILE     crate names to skip, one per line (#-comments ok)
#   --only FILE       run ONLY the crates listed in FILE (one per line,
#                     #-comments ok; --ignore/--no-ffi still apply on top).
#                     Made for isolating known-slow crates in their own
#                     long-walltime job, e.g. a list produced by
#                     analysis/remaining_crates.py after a timed-out sweep
#   --jobs N          number of single-node sbatch jobs for the regular (non-
#                     slowlist) crates. Default: as many as needed for full
#                     parallelism, ceil(crates / tasks), capped at 40 (the
#                     QOS job limit)
#   --tasks N         worker tasks per job. Default: auto -- one worker per
#                     REGULAR crate (the --tests CSV after --ignore/--only/
#                     --no-ffi filtering, minus the slowlist), capped at
#                     --max-tasks. Each job is then submitted with only the
#                     workers it actually holds, so the tail job asks for its
#                     9 crates rather than a full 24
#   --max-tasks N     ceiling for the auto-sized worker count (default 24 --
#                     a quarter node of cores, 192G). Narrow jobs backfill
#                     into scheduling gaps that wide ones never fit; raise it
#                     only if the queue is empty and you want fewer, wider jobs
#   --cpus-per-task N cores per worker (default 1; also caps cargo build jobs
#                     via CARGO_BUILD_JOBS). One is enough: the timed command
#                     is a single-threaded interpretation under miri/bsan, so
#                     extra cores only speed the one-off compile
#   --mem-per-task G  GB per worker (default 8; tasks*mem must fit 488G/node,
#                     so 24 workers x 8G = 192G leaves ample headroom)
#   --slow-walltime T walltime for the slowlist jobs, HH or HH:MM (default 24).
#                     SLURM bills elapsed time, not the request, and these jobs
#                     are small, so generous is cheap
#   --slow-group N    slowlist crates per group (default 10). Groups are cut in
#                     slowlist FILE ORDER: first N entries, then the next N
#   --slow-splits N   how many jobs each group's tests are spread over
#                     (default 4). Each group becomes N jobs; every crate's
#                     test list is strided N ways, so a group of 10 crates
#                     runs as N jobs x 10 single-cpu workers
#   --runs N          hyperfine timing runs per test (default 3)
#   --slow-runs N     hyperfine timing runs per test for SLOWLIST crates
#                     (default 1). These crates' tests are slow enough that
#                     repeating them costs hours for a variance estimate that
#                     matters least where the signal is largest
#   --warmup N        hyperfine warmup runs per test (default 0; the untimed
#                     status pre-run already warms caches, so each test runs
#                     1 + warmup + runs times in total)
#   --test-threads N  pass `--test-threads=N` to the test harness on every run
#                     (and on the calibration run), e.g. 1 to execute each
#                     test binary's tests serially. Off by default, which
#                     leaves libtest's own default (one thread per core). Since
#                     only the named test runs per invocation this rarely
#                     changes what executes -- but a name matching in several
#                     binaries, or a #[test] that itself spawns threads, is
#                     affected. It also changes every timing, so the run gets
#                     its own CSV (a -tt<N> slug) instead of appending to a
#                     parallel run's file.
#
# Every mode compiles with RUSTFLAGS="--cfg=miri" -- including rust and bsan. It
# makes all three select the same cfg(miri) code and, crucially, the same TEST
# SET as Miri: #[cfg(not(miri))] tests are compiled out and
# #[cfg_attr(miri, ignore)] tests are ignored everywhere, so the modes are
# comparable instead of each running whatever its own cfg selected. Rows written
# before this change came from differently-configured builds.
#
# Unlike run_miri_dataset.sh / run_bsan_dataset.sh (one srun job per crate,
# throttled to the 40-job QOS cap), this packs many single-core workers into a
# few whole-node sbatch jobs -- HPRC's preferred shape for many small tasks.
#
# Known-slow crates (scripts/slowlist, one name per line, #-comments ok) are
# automatically pulled out of the regular dealing -- so a straggler that needs
# many hours never sits in (or times out of) the regular jobs. They are cut
# into groups of --slow-group (10) crates in slowlist FILE ORDER, and each
# group is submitted as --slow-splits (4) jobs: one worker per crate, with
# every crate's test list strided across the 4 jobs. A 40-crate slowlist is
# therefore 4 groups x 4 = 16 jobs of 10 single-cpu workers, and each slow
# crate's tests are worked by 4 machines at once instead of one. Each split
# job recompiles the crate and writes its own __calibration__ row (private
# CARGO_TARGET_DIR per worker, so they cannot collide); part logs land in
# <crate>/hyperfine-<image>-part<N>.log. Slowlist entries not selected for the
# run are ignored, so the list is dataset-agnostic. Slow jobs request
# --slow-walltime (24h default) while the regular jobs keep the short
# <walltime>, so the wide fast jobs stay backfill-friendly.
#
# Crates from the tests CSV are dealt round-robin (largest test count first)
# across jobs*tasks workers; each worker processes its crates sequentially:
#
#   compile once  (cargo <tool> test --tests --no-run, timed)
#   calibrate     one `hyperfine` run of the same command with a filter that
#                 matches nothing, so it pays cargo's freshness check and every
#                 test binary's startup but runs zero tests
#   per test      one untimed pre-run to classify (success / test_failed /
#                 no_match), then `hyperfine --runs N` on
#                 `cargo <tool> test --tests -- --exact <test>` for passing
#                 tests. Times include cargo's no-op freshness check and the
#                 startup of every test binary in the crate (the filter runs in
#                 all of them) -- constant per crate, so comparable across
#                 modes, but not a bare test-body time. Subtract the crate's
#                 calibration row to recover the test body alone: that constant
#                 is ~1-3s per invocation under bsan/miri vs ~0.05s native, so
#                 for crates of short tests it otherwise dominates the timing
#                 (and inflates a bsan-vs-rust ratio into a startup ratio).
#                 A test name that occurs in several binaries is executed in
#                 each of them per run.
#
# Tests come from the CSV's ';'-joined tests column (crates with an empty list
# are skipped); the crate is matched to the dataset dir by basename. Rows are
# STREAMED into a per-worker shard CSV as each test finishes (single writer
# per shard, so no cross-node locking; a walltime kill loses only the
# in-flight test), a row per test plus a single test-less row for
# fetch_failed/build_failed crates:
#
#   build,crate,test,status,compile_seconds,mean_s,stddev_s,median_s,min_s,
#   max_s,runs,timestamp,job_id
#
# status: success, test_failed (pre-run exited non-zero), no_match (filter ran
# 0 tests -- stale test list), bench_failed (hyperfine itself errored),
# build_failed, fetch_failed, plus one calibration row per crate (see above;
# test=__calibration__). Timing fields are empty unless status is success or
# calibration -- so a crate contributes 1 + (its passing tests) rows, and the
# progress line's row count runs slightly ahead of the test count.
#
# The orchestrator submits the jobs, polls squeue with a progress line, then
# merges all shards into <outputs>/<image>[-<extra-slug>]-<dataset>-hyperfine.csv
# and prints a status breakdown. Per-crate logs land in
# <crate>/hyperfine-<image>.log. Chunks/shards/logs for the run live under
# <outputs>/hyperfine-runs/<runid>/ for debugging.
#
# If this script is killed the sbatch jobs keep running (Ctrl-C cancels them
# first); shards survive, so results can be merged by hand:
#   cat <rundir>/shards/*.csv >> <master csv>
#
# NOTE: the images must contain `hyperfine` -- each job checks and aborts with
# a clear error if it is missing.
set -euo pipefail

# mapfile / associative arrays need bash >= 4.
if (( BASH_VERSINFO[0] < 4 )); then
    echo "Error: this script needs bash >= 4 (have $BASH_VERSION)." >&2
    exit 1
fi

# ── Layout (all absolute, so this can be run from anywhere) ───────────────────
GROUP="/scratch/group/p.cis260229.000"
CONTAINERS_DIR="$GROUP/containers"
DATASETS_ROOT="$GROUP/datasets"
OUTPUTS_DIR="$GROUP/outputs"

# Built-in per-mode option sets (same as run_miri_dataset / run_bsan_dataset).
MIRI_COMMON="-Zmiri-disable-alignment-check -Zmiri-disable-data-race-detector -Zmiri-ignore-leaks -Zmiri-tree-borrows"
BSAN_COMMON="stacktrace_max_len=32"

# ── Options ──────────────────────────────────────────────────────────────────
TESTS_CSV=""
NO_FFI=0
IGNORE_FILE=""
ONLY_FILE=""
JOBS=""              # empty = auto: ceil(crates / tasks), capped at 40
TASKS=""            # empty = auto: min(fast crates, MAX_TASKS)
MAX_TASKS=24         # ceiling on auto-sized workers per job (a quarter node)
CPUS_PER_TASK=1
MEM_PER_TASK=8       # GB per worker (24*8=192G, well inside the 488G node cap)
SLOW_GROUP=10        # slowlist crates per group
SLOW_SPLITS=4        # jobs each group's tests are split across
RUNS=3
SLOW_RUNS=1          # hyperfine runs per test for slowlist crates
WARMUP=0
TEST_THREADS=""        # --test-threads N for the harness; empty = don't pass it
WALLTIME_ARG=2         # walltime for the regular jobs (positional overrides)
SLOW_WALLTIME_ARG=24   # walltime for the slowlist jobs

POS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --tests)         TESTS_CSV="$2"; shift 2 ;;
        --tests=*)       TESTS_CSV="${1#*=}"; shift ;;
        --no-ffi)        NO_FFI=1; shift ;;
        -i|--ignore)     IGNORE_FILE="$2"; shift 2 ;;
        --ignore=*)      IGNORE_FILE="${1#*=}"; shift ;;
        --only)          ONLY_FILE="$2"; shift 2 ;;
        --only=*)        ONLY_FILE="${1#*=}"; shift ;;
        --jobs)          JOBS="$2"; shift 2 ;;
        --jobs=*)        JOBS="${1#*=}"; shift ;;
        --tasks)         TASKS="$2"; shift 2 ;;
        --tasks=*)       TASKS="${1#*=}"; shift ;;
        --max-tasks)     MAX_TASKS="$2"; shift 2 ;;
        --max-tasks=*)   MAX_TASKS="${1#*=}"; shift ;;
        --cpus-per-task) CPUS_PER_TASK="$2"; shift 2 ;;
        --cpus-per-task=*) CPUS_PER_TASK="${1#*=}"; shift ;;
        --mem-per-task)  MEM_PER_TASK="$2"; shift 2 ;;
        --mem-per-task=*) MEM_PER_TASK="${1#*=}"; shift ;;
        --runs)          RUNS="$2"; shift 2 ;;
        --runs=*)        RUNS="${1#*=}"; shift ;;
        --slow-runs)     SLOW_RUNS="$2"; shift 2 ;;
        --slow-runs=*)   SLOW_RUNS="${1#*=}"; shift ;;
        --warmup)        WARMUP="$2"; shift 2 ;;
        --warmup=*)      WARMUP="${1#*=}"; shift ;;
        --test-threads)  TEST_THREADS="$2"; shift 2 ;;
        --test-threads=*) TEST_THREADS="${1#*=}"; shift ;;
        --slow-walltime) SLOW_WALLTIME_ARG="$2"; shift 2 ;;
        --slow-walltime=*) SLOW_WALLTIME_ARG="${1#*=}"; shift ;;
        --slow-group)    SLOW_GROUP="$2"; shift 2 ;;
        --slow-group=*)  SLOW_GROUP="${1#*=}"; shift ;;
        --slow-splits)   SLOW_SPLITS="$2"; shift 2 ;;
        --slow-splits=*) SLOW_SPLITS="${1#*=}"; shift ;;
        -*)
            echo "Error: unknown option '$1'." >&2; exit 1 ;;
        *)
            POS+=("$1"); shift ;;
    esac
done
set -- ${POS[@]+"${POS[@]}"}

usage() {
    echo "Usage: $0 [options] <mode> <image> [walltime] <dataset> [extra]" >&2
    echo "  <mode>   miri | bsan | rust" >&2
    echo "  <image>  image/SIF name under $CONTAINERS_DIR" >&2
    echo "  [walltime]  regular-job walltime, HH or HH:MM (default 2)" >&2
    echo "  <dataset>   folder under $DATASETS_ROOT" >&2
    echo "  [extra]     extra MIRIFLAGS (miri) or BSAN_OPTIONS (bsan)" >&2
    echo "  options: --tests FILE --no-ffi --ignore FILE --only FILE --jobs N" >&2
    echo "           --tasks N --max-tasks N --cpus-per-task N --mem-per-task G" >&2
    echo "           --runs N --warmup N --slow-runs N (slowlist runs, default 1)" >&2
    echo "           --slow-walltime T (for slowlist jobs, default 24)" >&2
    echo "           --slow-group N --slow-splits N (slowlist shape, 10 x 4)" >&2
    exit 1
}
[[ $# -ge 3 && $# -le 5 ]] || usage

MODE="$1"
IMAGE_ARG="$2"
shift 2
# The walltime positional is optional: take the next arg as walltime only if
# it is shaped like one (HH or HH:MM); otherwise it is the dataset.
if [[ $# -ge 2 && "$1" =~ ^[0-9]{1,3}(:[0-9]{2})?$ ]]; then
    WALLTIME_ARG="$1"
    shift
fi
[[ $# -ge 1 && $# -le 2 ]] || usage
DATASET="$1"
EXTRA="${2:-}"

case "$MODE" in miri|bsan|rust) ;; *)
    echo "Error: mode must be miri, bsan, or rust (got '$MODE')." >&2; exit 1 ;;
esac

# Walltime: accept HH (1-3 digits) or HH:MM (same as run_job.sh).
parse_walltime() {
    if [[ "$1" =~ ^([0-9]{1,3})$ ]]; then
        printf '%02d:00:00' "$((10#${BASH_REMATCH[1]}))"
    elif [[ "$1" =~ ^([0-9]{1,3}):([0-9]{2})$ ]]; then
        local h=$((10#${BASH_REMATCH[1]})) m=$((10#${BASH_REMATCH[2]}))
        (( m <= 59 )) || { echo "Error: minutes must be 00-59 (got '$1')." >&2; exit 1; }
        printf '%02d:%02d:00' "$h" "$m"
    else
        echo "Error: walltime must be HH or HH:MM (e.g. 8 or 8:30; got '$1')." >&2
        exit 1
    fi
}
WALLTIME=$(parse_walltime "$WALLTIME_ARG")
SLOW_WALLTIME=$(parse_walltime "$SLOW_WALLTIME_ARG")

MEM_PER_TASK="${MEM_PER_TASK%G}"
for v in CPUS_PER_TASK MEM_PER_TASK RUNS SLOW_RUNS WARMUP SLOW_GROUP SLOW_SPLITS MAX_TASKS; do
    [[ "${!v}" =~ ^[0-9]+$ ]] || { echo "Error: $v must be a number." >&2; exit 1; }
done
(( RUNS      >= 1 )) || { echo "Error: --runs must be >= 1." >&2; exit 1; }
(( SLOW_RUNS >= 1 )) || { echo "Error: --slow-runs must be >= 1." >&2; exit 1; }
(( SLOW_GROUP  >= 1 )) || { echo "Error: --slow-group must be >= 1." >&2; exit 1; }
(( SLOW_SPLITS >= 1 )) || { echo "Error: --slow-splits must be >= 1." >&2; exit 1; }
(( MAX_TASKS   >= 1 )) || { echo "Error: --max-tasks must be >= 1." >&2; exit 1; }
if [[ -n "$JOBS" ]]; then
    [[ "$JOBS" =~ ^[0-9]+$ && "$JOBS" -ge 1 ]] || { echo "Error: --jobs must be a number >= 1." >&2; exit 1; }
fi
if [[ -n "$TASKS" ]]; then
    [[ "$TASKS" =~ ^[0-9]+$ && "$TASKS" -ge 1 ]] || { echo "Error: --tasks must be a number >= 1." >&2; exit 1; }
fi
if [[ -n "$TEST_THREADS" ]]; then
    [[ "$TEST_THREADS" =~ ^[1-9][0-9]*$ ]] \
        || { echo "Error: --test-threads must be a positive integer (got '$TEST_THREADS')." >&2; exit 1; }
fi
# The tasks*mem / tasks*cpus node-capacity checks need the resolved TASKS, so
# they live just after auto-sizing (below the crate selection).

IMAGE="$(basename "${IMAGE_ARG%.sif}")"
SIF_ABS="$CONTAINERS_DIR/$IMAGE.sif"
DATASET_DIR="$DATASETS_ROOT/$DATASET"
[[ -n "$TESTS_CSV" ]] || TESTS_CSV="$OUTPUTS_DIR/tests-${DATASET}.csv"

# Full per-mode option set: built-in common options plus any extras.
MIRIFLAGS_ALL=""
BSAN_OPTIONS_ALL=""
case "$MODE" in
    miri) MIRIFLAGS_ALL="$MIRI_COMMON${EXTRA:+ $EXTRA}" ;;
    bsan) BSAN_OPTIONS_ALL="$BSAN_COMMON${EXTRA:+:$EXTRA}" ;;
esac

# Master CSV: <image>[-<extra slug>]-<dataset>-hyperfine.csv (slug logic as in
# the other run_*_dataset scripts, so different flag sets land in different
# files; the -hyperfine suffix marks the per-test benchmark format).
CSV="$OUTPUTS_DIR/${IMAGE}-${DATASET}-hyperfine.csv"
SLUG=""
if [[ -n "$EXTRA" && "$MODE" != "rust" ]]; then
    SLUG="$(printf '%s' "$EXTRA" | tr -c '[:alnum:]' '-' | sed 's/-\{1,\}/-/g; s/^-//; s/-$//')"
fi
# --test-threads changes every timing in the run (a serial suite pays no
# contention but loses all overlap), so it joins the slug: rows from a serial
# run must not append into a parallel run's CSV.
[[ -n "$TEST_THREADS" ]] && SLUG="${SLUG:+$SLUG-}tt${TEST_THREADS}"
[[ -n "$SLUG" ]] && CSV="$OUTPUTS_DIR/${IMAGE}-${SLUG}-${DATASET}-hyperfine.csv"

# ── Validate ──────────────────────────────────────────────────────────────--
[[ -f "$SIF_ABS" ]]    || { echo "Error: image not found at $SIF_ABS" >&2; exit 1; }
[[ -d "$DATASET_DIR" ]] || { echo "Error: dataset dir not found: $DATASET_DIR" >&2; exit 1; }
[[ -f "$TESTS_CSV" ]]  || { echo "Error: tests CSV not found: $TESTS_CSV (--tests FILE?)" >&2; exit 1; }
command -v sbatch >/dev/null || { echo "Error: sbatch not found (run on a login node)." >&2; exit 1; }

# Load the ignorelist (if any) into a set keyed by crate-dir basename.
declare -A IGNORE=()
if [[ -n "$IGNORE_FILE" ]]; then
    [[ -f "$IGNORE_FILE" ]] || { echo "Error: ignorelist not found: $IGNORE_FILE" >&2; exit 1; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"; line="${line//[[:space:]]/}"
        [[ -n "$line" ]] && IGNORE["$line"]=1
    done < "$IGNORE_FILE"
fi

# Load the --only list (if any) the same way; when non-empty, crates absent
# from it are skipped.
declare -A ONLY=()
if [[ -n "$ONLY_FILE" ]]; then
    [[ -f "$ONLY_FILE" ]] || { echo "Error: --only list not found: $ONLY_FILE" >&2; exit 1; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"; line="${line//[[:space:]]/}"
        [[ -n "$line" ]] && ONLY["$line"]=1
    done < "$ONLY_FILE"
    (( ${#ONLY[@]} > 0 )) || { echo "Error: --only list $ONLY_FILE is empty." >&2; exit 1; }
fi

# ── Run dir: chunks, per-crate test lists, shards, job scripts, logs ─────────
RUNDIR="$OUTPUTS_DIR/hyperfine-runs/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$RUNDIR/chunks" "$RUNDIR/tests" "$RUNDIR/shards"

# ── Parse the tests CSV ───────────────────────────────────────────────────---
# Rows are crate,tests,contains_ffi where tests is ';'-joined and guaranteed
# comma-free (see list_tests.sh). Duplicate names within a crate (same test in
# several binaries) are collapsed -- --exact runs it in every binary anyway.
SELECTED=()          # "count<TAB>crate" lines, for size-descending dealing
declare -A SEEN_CRATE=()
TOTAL_TESTS=0
skip_ignored=0; skip_only=0; skip_ffi=0; skip_empty=0
MISSING=()
first=1
while IFS=, read -r crate tests ffi || [[ -n "$crate" ]]; do
    if (( first )); then first=0; [[ "$crate" == "crate" ]] && continue; fi
    crate="${crate//$'\r'/}"; ffi="${ffi//$'\r'/}"
    [[ -n "$crate" ]] || continue
    [[ -n "${SEEN_CRATE[$crate]:-}" ]] && continue
    SEEN_CRATE[$crate]=1
    if [[ -n "${IGNORE[$crate]:-}" ]]; then skip_ignored=$((skip_ignored+1)); continue; fi
    if (( ${#ONLY[@]} > 0 )) && [[ -z "${ONLY[$crate]:-}" ]]; then skip_only=$((skip_only+1)); continue; fi
    if (( NO_FFI )) && [[ "$ffi" != "false" ]]; then skip_ffi=$((skip_ffi+1)); continue; fi
    if [[ -z "$tests" ]]; then skip_empty=$((skip_empty+1)); continue; fi
    if [[ ! -d "$DATASET_DIR/$crate" ]]; then MISSING+=("$crate"); continue; fi
    tr ';' '\n' <<<"$tests" | awk 'NF && !seen[$0]++' > "$RUNDIR/tests/$crate.txt"
    cnt=$(wc -l < "$RUNDIR/tests/$crate.txt")
    (( cnt > 0 )) || { skip_empty=$((skip_empty+1)); continue; }
    SELECTED+=("$(printf '%d\t%s' "$cnt" "$crate")")
    TOTAL_TESTS=$(( TOTAL_TESTS + cnt ))
done < "$TESTS_CSV"

if (( ${#SELECTED[@]} == 0 )); then
    echo "Error: no crates left to run after filtering $TESTS_CSV." >&2
    exit 1
fi

# ── Split off the known-slow crates (scripts/slowlist) ───────────────────────
# Crates listed in the slowlist file are pulled out of the normal dealing and
# run in their own long-walltime jobs, so the regular jobs can keep a short
# walltime and no slow crate bills idle cores while waiting for a slower one
# to drain. Slowlist crates not selected for this run are simply ignored, so
# the list works across datasets.
#
# The slowlist is read IN FILE ORDER and kept that way: grouping is positional
# (first --slow-group entries, then the next...), so the file itself is the
# knob for which crates share a job.
SLOWLIST_FILE="$GROUP/scripts/slowlist"
declare -A SLOWLIST=()
SLOW_ORDER=()
if [[ -f "$SLOWLIST_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"; line="${line//[[:space:]]/}"
        [[ -n "$line" ]] || continue
        [[ -n "${SLOWLIST[$line]:-}" ]] && continue
        SLOWLIST["$line"]=1
        SLOW_ORDER+=("$line")
    done < "$SLOWLIST_FILE"
fi

FAST_SEL=()
declare -A SEL_COUNT=()
for line in "${SELECTED[@]}"; do
    crate="${line#*$'\t'}"
    SEL_COUNT["$crate"]="${line%%$'\t'*}"
    [[ -z "${SLOWLIST[$crate]:-}" ]] && FAST_SEL+=("$line")
done

SLOW_CRATES=()
for crate in ${SLOW_ORDER[@]+"${SLOW_ORDER[@]}"}; do
    [[ -n "${SEL_COUNT[$crate]:-}" ]] && SLOW_CRATES+=("$crate")
done

# ── Worker count per job: auto-size unless --tasks was given ─────────────────
# Ask for what the run actually needs, not a whole node: one worker per fast
# (non-slowlist) crate, capped at MAX_TASKS. Narrow jobs backfill into
# scheduling gaps that whole-node jobs never fit, and a run of 12 crates
# should not sit in the queue waiting for 24 free cores. Each job is later
# submitted with its OWN worker count (see job_worker_count), so a final job
# holding 9 crates requests 9 tasks, not TASKS.
if [[ -z "$TASKS" ]]; then
    TASKS=${#FAST_SEL[@]}
    (( TASKS > MAX_TASKS )) && TASKS=$MAX_TASKS
    (( TASKS < 1 )) && TASKS=1
fi

# Node-capacity checks, now that TASKS is known. These bound the LARGEST job;
# per-job right-sizing only ever shrinks the request from here.
TOTAL_MEM=$(( TASKS * MEM_PER_TASK ))
if (( TOTAL_MEM > 488 )); then
    echo "Error: tasks*mem = ${TOTAL_MEM}G exceeds the 488G usable on an ACES node." >&2
    echo "Lower --tasks/--max-tasks or --mem-per-task." >&2
    exit 1
fi
TOTAL_CPUS=$(( TASKS * CPUS_PER_TASK ))
if (( TOTAL_CPUS > 96 )); then
    echo "Error: tasks*cpus = ${TOTAL_CPUS} exceeds the 96 cores on an ACES node." >&2
    exit 1
fi

# ── Job count: auto-size unless --jobs was given ─────────────────────────────
# Enough single-node jobs that every non-slow crate gets its own worker from
# the start (ceil(fast crates/tasks)), capped at the QOS's 40 concurrent jobs.
# More jobs than crates/tasks would just sit idle; more than 40 would sit in
# the queue anyway. The slow jobs are submitted on top of these.
if [[ -z "$JOBS" ]]; then
    JOBS=$(( (${#FAST_SEL[@]} + TASKS - 1) / TASKS ))
    (( JOBS > 40 )) && JOBS=40
fi

# ── Deal crates round-robin across jobs*tasks workers, biggest first ─────────
# Sorting by test count descending before dealing gives a rough longest-
# processing-time-first balance, so no worker gets all the monster crates.
if (( ${#FAST_SEL[@]} > 0 && JOBS > 0 )); then
    mapfile -t SORTED < <(printf '%s\n' "${FAST_SEL[@]}" | sort -t$'\t' -k1,1nr -k2,2)
    WORKERS=$(( JOBS * TASKS ))
    i=0
    for line in "${SORTED[@]}"; do
        crate="${line#*$'\t'}"
        w=$(( i % WORKERS ))
        printf '%s\n' "$crate" >> "$RUNDIR/chunks/chunk-$(( w % JOBS ))-$(( w / JOBS )).txt"
        i=$((i + 1))
    done
fi

# Slow crates take the job indices after the regular ones. They are cut into
# groups of SLOW_GROUP (in slowlist order), and each group is submitted as
# SLOW_SPLITS separate jobs: one worker per crate in the group, and every
# crate's TEST LIST split SLOW_SPLITS ways (strided, so the split is even even
# when the list is cost-ordered). So a 40-crate slowlist at 10 x 4 becomes 16
# jobs of 10 single-cpu workers, and the slowest crate's tests finish ~4x
# sooner than when one worker owned the whole crate.
#
# The cost of the split is that each of the SLOW_SPLITS jobs compiles the crate
# itself (they run on different nodes with private CARGO_TARGET_DIRs) and emits
# its own __calibration__ row -- build time is small next to these crates' test
# time, and per-job calibration rows are arguably the right ones to subtract
# since each job measures its own node.
SLOW_JOBS=()   # "<job idx> <ntasks> <label>" per submitted slow job
if (( ${#SLOW_CRATES[@]} > 0 )); then
    ngroups=$(( (${#SLOW_CRATES[@]} + SLOW_GROUP - 1) / SLOW_GROUP ))
    for (( g = 0; g < ngroups; g++ )); do
        gstart=$(( g * SLOW_GROUP ))
        gsize=$(( ${#SLOW_CRATES[@]} - gstart ))
        (( gsize > SLOW_GROUP )) && gsize=$SLOW_GROUP
        for (( f = 0; f < SLOW_SPLITS; f++ )); do
            j=$(( JOBS + g * SLOW_SPLITS + f ))
            maxtid=-1
            for (( t = 0; t < gsize; t++ )); do
                crate="${SLOW_CRATES[$(( gstart + t ))]}"
                part="$RUNDIR/tests/$crate.part$f.txt"
                awk -v f="$f" -v n="$SLOW_SPLITS" 'NR % n == f' \
                    "$RUNDIR/tests/$crate.txt" > "$part"
                # A crate with fewer tests than SLOW_SPLITS leaves some parts
                # empty; those get no chunk, so the worker never starts.
                [[ -s "$part" ]] || { rm -f "$part"; continue; }
                printf '%s\t%s\n' "$crate" "$f" > "$RUNDIR/chunks/chunk-$j-$t.txt"
                maxtid=$t
            done
            (( maxtid >= 0 )) && SLOW_JOBS+=("$j $(( maxtid + 1 )) g$(( g + 1 ))p$(( f + 1 ))")
        done
    done
fi

# ── Config shared with the node-side scripts ─────────────────────────────────
{
    printf 'GROUP=%q\n'            "$GROUP"
    printf 'MODE=%q\n'             "$MODE"
    printf 'IMAGE=%q\n'            "$IMAGE"
    printf 'SIF_ABS=%q\n'          "$SIF_ABS"
    printf 'DATASET_DIR=%q\n'      "$DATASET_DIR"
    printf 'TASKS=%q\n'            "$TASKS"
    printf 'CPUS_PER_TASK=%q\n'    "$CPUS_PER_TASK"
    printf 'RUNS=%q\n'             "$RUNS"
    printf 'SLOW_RUNS=%q\n'        "$SLOW_RUNS"
    printf 'WARMUP=%q\n'           "$WARMUP"
    printf 'TEST_THREADS=%q\n'     "$TEST_THREADS"
    printf 'MIRIFLAGS_ALL=%q\n'    "$MIRIFLAGS_ALL"
    printf 'BSAN_OPTIONS_ALL=%q\n' "$BSAN_OPTIONS_ALL"
} > "$RUNDIR/config.env"

# ── inner.sh: runs INSIDE the container, once per crate, cwd = /work ─────────
# Fully quoted heredoc: everything resolves at run time from the HF_* env vars
# injected by the worker, so there is no nested-escaping to fight.
cat > "$RUNDIR/inner.sh" << 'INNER_EOF'
#!/bin/bash
# Compile the crate once, then classify + hyperfine each test in HF_TESTFILE.
# Emits one CSVROW: line per test (or a single test-less row on fetch/build
# failure) for the worker to harvest from the log.
set -u

case "$HF_MODE" in
    rust) RUN="cargo test --tests" ;;
    miri) export MIRIFLAGS="$HF_MIRIFLAGS";   RUN="cargo miri test --tests" ;;
    bsan) export BSAN_OPTIONS="$HF_BSAN_OPTIONS"; RUN="cargo bsan test --tests" ;;
    *) echo "Error: bad HF_MODE '$HF_MODE'" >&2; exit 1 ;;
esac

# --cfg=miri for every mode, so all three select the same cfg(miri) code and the
# same test set (#[cfg(not(miri))] compiled out, #[cfg_attr(miri, ignore)]
# ignored) and time the same testbench. cargo has no --cfg flag, so it rides in
# RUSTFLAGS. EXPORTED rather than prefixed onto $RUN because $RUN is handed to
# hyperfine, which runs with -N (no shell) -- a "VAR=value cmd" prefix would be
# taken as the program name there, not as an assignment.
export RUSTFLAGS="--cfg=miri"
echo "RUSTFLAGS=[$RUSTFLAGS]"

# libtest's --test-threads is a HARNESS flag, so it goes after the `--`, before
# --exact. Empty unless --test-threads was passed; the leading space lives
# inside the expansion so the command string is byte-identical to before when
# the option is unset (hyperfine runs with -N and splits on whitespace).
HARNESS="${HF_TEST_THREADS:-}"
HARNESS="${HARNESS:+ --test-threads=$HARNESS}"
[ -n "$HARNESS" ] && echo "HARNESS=[$HARNESS]"

ts() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }
# row <test> <status> <compile> <mean> <stddev> <median> <min> <max>
# Streams the row STRAIGHT into this worker's shard (we are its only writer),
# so a walltime kill loses at most the in-flight test -- not, as when rows
# were harvested from the log after the container exited, the whole crate.
# The CSVROW echo is kept purely as a log-side copy for debugging.
row() {
    line="$HF_BUILD,$HF_CRATE,$1,$2,$3,$4,$5,$6,$7,$8,$HF_RUNS,$(ts),$HF_JOBID"
    echo "$line" >> "$HF_SHARD"
    echo "CSVROW:$line"
}

cargo clean >/dev/null 2>&1 || true
if ! cargo fetch; then
    row "" fetch_failed "" "" "" "" "" ""
    exit 1
fi

cstart=$(date +%s%3N)
if ! $RUN --no-run; then
    row "" build_failed "" "" "" "" "" ""
    exit 1
fi
cms=$(( $(date +%s%3N) - cstart ))
compile=$(printf '%d.%03d' $(( cms / 1000 )) $(( cms % 1000 )))

# --- Calibration: what an invocation costs before any test body runs --------
# The same command with a filter matching nothing still pays cargo's freshness
# check and starts every test binary in the crate, running zero tests -- i.e.
# exactly the constant that every per-test timing below also carries. Measured
# once per crate and written as its own row (test=__calibration__,
# status=calibration) rather than subtracted here, so the CSV keeps raw
# measurements and the analysis decides what to do with them. A crate gets no
# calibration row if this errors; consumers then fall back to raw sums.
CALIB_FILTER=__hyperfine_calibration_no_such_test__
hfcsv=$(mktemp)
if hyperfine --style basic -N --warmup "$HF_WARMUP" --runs "$HF_RUNS" \
        --export-csv "$hfcsv" "$RUN --$HARNESS --exact $CALIB_FILTER"; then
    read -r cmean cstddev cmedian cmin cmax <<EOV
$(tail -n1 "$hfcsv" | awk -F, '{print $(NF-6), $(NF-5), $(NF-4), $(NF-1), $NF}')
EOV
    echo "calibration: $HF_CRATE -> ${cmedian}s per invocation (0 tests)"
    row "__calibration__" calibration "$compile" \
        "$cmean" "$cstddev" "$cmedian" "$cmin" "$cmax"
fi
rm -f "$hfcsv"

while IFS= read -r t; do
    [ -n "$t" ] || continue
    # Untimed pre-run: classifies the test and warms caches. no_match means the
    # --exact filter ran 0 tests everywhere (stale test list).
    runlog=$(mktemp)
    $RUN --$HARNESS --exact "$t" > "$runlog" 2>&1; rc=$?
    nrun=$(grep -aoE '^running [0-9]+ test' "$runlog" | grep -oE '[0-9]+' | awk '{s+=$1} END{print s+0}')
    rm -f "$runlog"
    status=""
    if [ "$nrun" -eq 0 ]; then status=no_match
    elif [ "$rc" -ne 0 ]; then status=test_failed
    fi
    mean=""; stddev=""; median=""; minv=""; maxv=""
    if [ -z "$status" ]; then
        hfcsv=$(mktemp)
        # -N: exec directly, no intermediate shell. Export columns are
        # command,mean,stddev,median,user,system,min,max -- counted from the
        # end so a comma in the command column can never shift them.
        if hyperfine --style basic -N --warmup "$HF_WARMUP" --runs "$HF_RUNS" \
                --export-csv "$hfcsv" "$RUN --$HARNESS --exact $t"; then
            read -r mean stddev median minv maxv <<EOV
$(tail -n1 "$hfcsv" | awk -F, '{print $(NF-6), $(NF-5), $(NF-4), $(NF-1), $NF}')
EOV
            status=success
        else
            status=bench_failed
        fi
        rm -f "$hfcsv"
    fi
    echo "result: $HF_CRATE :: $t -> $status${mean:+ (mean ${mean}s)}"
    row "$t" "$status" "$compile" "$mean" "$stddev" "$median" "$minv" "$maxv"
done < "$HF_TESTFILE"
INNER_EOF

# ── job.sh: the sbatch payload, one per node ─────────────────────────────────
# Also fully quoted: all configuration comes from config.env + its two args
# (<rundir> <job index>). Launches TASKS background workers, each draining its
# own chunk file and appending harvested CSVROWs to its own shard (single
# writer per shard, so no locking anywhere).
cat > "$RUNDIR/job.sh" << 'JOB_EOF'
#!/bin/bash
set -u
RUNDIR="$1"
JOBIDX="$2"
source "$RUNDIR/config.env"
# Worker count for THIS job: the slow-crate job runs fewer workers than the
# regular TASKS (one per slow crate); the orchestrator passes it explicitly.
NTASKS="${3:-$TASKS}"

if ! command -v module &>/dev/null; then
    source /etc/profile.d/lmod.sh    2>/dev/null || \
    source /etc/profile.d/modules.sh 2>/dev/null || true
fi

# Internet access on the compute node (sets http_proxy/https_proxy).
module load WebProxy

command -v singularity &>/dev/null || \
    module load Singularity 2>/dev/null || \
    module load singularity 2>/dev/null || true
if ! command -v singularity &>/dev/null; then
    echo "Error: 'singularity' not found on this node." >&2
    exit 1
fi

if ! singularity exec "$SIF_ABS" sh -c 'command -v hyperfine' >/dev/null 2>&1; then
    echo "Error: 'hyperfine' not found inside $SIF_ABS -- add it to the image." >&2
    exit 1
fi

# Finite stack before entering the container (bsan shadow-memory layout
# workaround, harmless for other images -- see run_job.sh for the full story).
ulimit -S -s 8192

SCRATCH_BASE="$GROUP/cargo-temp-$USER"
mkdir -p "$SCRATCH_BASE"
trap 'rm -rf "$SCRATCH_BASE/hf-$SLURM_JOB_ID-"* 2>/dev/null || true' EXIT

worker() {
    local tid="$1"
    local chunk="$RUNDIR/chunks/chunk-${JOBIDX}-${tid}.txt"
    local shard="$RUNDIR/shards/shard-${JOBIDX}-${tid}.csv"
    [ -s "$chunk" ] || return 0
    local n k=0 line crate part testfile log runs
    n=$(wc -l < "$chunk")
    # Chunk lines are "<crate>" or, for a split slowlist crate, "<crate>\t<part>"
    # -- the part selects that job's slice of the test list (and its own log,
    # since the other parts run the same crate dir concurrently on other nodes).
    while IFS= read -r line; do
        k=$((k + 1))
        crate="${line%%$'\t'*}"
        part=""
        [ "$line" != "$crate" ] && part="${line#*$'\t'}"
        testfile="$RUNDIR/tests/$crate.txt"
        local cdir="$DATASET_DIR/$crate"
        local scr="$SCRATCH_BASE/hf-${SLURM_JOB_ID}-${tid}"
        log="$cdir/hyperfine-${IMAGE}.log"
        runs="$RUNS"
        # A part field is only ever set for slowlist crates, so it doubles as
        # the "this is a slow crate" flag: sample it SLOW_RUNS times, not RUNS.
        if [ -n "$part" ]; then
            testfile="$RUNDIR/tests/$crate.part$part.txt"
            log="$cdir/hyperfine-${IMAGE}-part$part.log"
            runs="$SLOW_RUNS"
        fi
        rm -rf "$scr"
        mkdir -p "$scr/home" "$scr/target"
        echo "[job $JOBIDX task $tid] ($k/$n) $crate"
        singularity exec --cleanenv --pwd /work \
            --bind "$scr" --bind "$RUNDIR" --bind "$cdir:/work" \
            --env CARGO_HOME="$scr/home" \
            --env CARGO_TARGET_DIR="$scr/target" \
            --env CARGO_BUILD_JOBS="$CPUS_PER_TASK" \
            --env HF_BUILD="$IMAGE" --env HF_MODE="$MODE" \
            --env HF_CRATE="$crate" \
            --env HF_TESTFILE="$testfile" \
            --env HF_SHARD="$shard" \
            --env HF_RUNS="$runs" --env HF_WARMUP="$WARMUP" \
            --env HF_TEST_THREADS="$TEST_THREADS" \
            --env HF_MIRIFLAGS="$MIRIFLAGS_ALL" \
            --env HF_BSAN_OPTIONS="$BSAN_OPTIONS_ALL" \
            --env HF_JOBID="${SLURM_JOB_ID}.${tid}" \
            --env http_proxy="${http_proxy:-}"   --env https_proxy="${https_proxy:-}" \
            --env HTTP_PROXY="${HTTP_PROXY:-}"   --env HTTPS_PROXY="${HTTPS_PROXY:-}" \
            "$SIF_ABS" bash "$RUNDIR/inner.sh" > "$log" 2>&1
        rm -rf "$scr"
    done < "$chunk"
}

for (( tid = 0; tid < NTASKS; tid++ )); do
    worker "$tid" &
done
wait
JOB_EOF

# ── Plan summary ─────────────────────────────────────────────────────────────
echo "Mode:     $MODE   Image: $IMAGE"
echo "Dataset:  $DATASET_DIR"
echo "Tests:    $TOTAL_TESTS across ${#SELECTED[@]} crates (from $TESTS_CSV)"
echo "Skipped:  ignored=$skip_ignored not-in-only=$skip_only ffi=$skip_ffi no-tests=$skip_empty missing-dir=${#MISSING[@]}"
if (( ${#MISSING[@]} > 0 )); then
    printf '  missing from dataset: %s\n' "${MISSING[@]}" | head -20
fi
echo "Shape:    $JOBS job(s) x up to $TASKS tasks x ${CPUS_PER_TASK} cpus, ${MEM_PER_TASK}G/task (<=${TOTAL_MEM}G/job), $WALLTIME each"
echo "          (${#FAST_SEL[@]} regular crate(s); each job requests only the workers it holds)"
if (( ${#SLOW_CRATES[@]} > 0 )); then
    echo "Slow:     ${#SLOW_CRATES[@]} slowlist crate(s) -> ${#SLOW_JOBS[@]} job(s) at $SLOW_WALLTIME"
    echo "          (groups of $SLOW_GROUP crates, each group's tests split $SLOW_SPLITS ways,"
    echo "           $SLOW_RUNS run(s) per test)"
fi
TOTAL_JOBS=$(( JOBS + ${#SLOW_JOBS[@]} ))
if (( TOTAL_JOBS > 40 )); then
    echo "WARNING:  $TOTAL_JOBS jobs exceeds the 40-job QOS limit; the extras will"
    echo "          queue until earlier ones finish (lower --jobs or --slow-splits)."
fi
SLOW_RUNS_NOTE=""
(( ${#SLOW_CRATES[@]} > 0 )) && SLOW_RUNS_NOTE=" (slowlist: $SLOW_RUNS)"
echo "Sampling: $RUNS runs$SLOW_RUNS_NOTE, $WARMUP warmup per test${TEST_THREADS:+, --test-threads=$TEST_THREADS}"
[[ "$MODE" == "miri" ]] && echo "MIRIFLAGS: $MIRIFLAGS_ALL"
[[ "$MODE" == "bsan" ]] && echo "BSAN_OPTIONS: $BSAN_OPTIONS_ALL"
echo "Results:  $CSV"
echo "Run dir:  $RUNDIR"
echo

# ── Submit one single-node sbatch job per chunked job index ──────────────────
# Independent 1-node jobs backfill better than one multi-node job; a job index
# with no chunks (more workers than crates) is simply not submitted. The slow
# job is sized to its own worker count so it doesn't hold idle cores while it
# runs the long tail.
JOBIDS=()
# Workers actually needed by job <j>: highest occupied task id + 1. Chunk task
# ids are contiguous from 0 for the regular dealing, so this is just the crate
# count; for a split slowlist group a crate with too few tests can leave a hole,
# and job.sh iterates 0..NTASKS-1 skipping empty chunks, so the max (not the
# count) is what must be requested.
job_worker_count() {
    local j="$1" f tid max=-1
    for f in "$RUNDIR"/chunks/chunk-"$j"-*.txt; do
        [[ -s "$f" ]] || continue
        tid="${f##*-}"; tid="${tid%.txt}"
        (( tid > max )) && max=$tid
    done
    echo $(( max + 1 ))
}
submit_one() {
    local j="$1" ntasks="$2" label="$3" wall="$4" jid
    compgen -G "$RUNDIR/chunks/chunk-$j-*.txt" >/dev/null || return 0
    if ! jid=$(sbatch --parsable \
        --job-name="hf-${IMAGE}-${DATASET}-${label}" \
        --nodes=1 --ntasks-per-node="$ntasks" --cpus-per-task="$CPUS_PER_TASK" \
        --mem="$(( ntasks * MEM_PER_TASK ))G" --time="$wall" \
        --output="$RUNDIR/job-%j.out" \
        "$RUNDIR/job.sh" "$RUNDIR" "$j" "$ntasks"); then
        echo "Error: sbatch failed for job $label; cancelling ${JOBIDS[*]:-nothing}." >&2
        [[ ${#JOBIDS[@]} -gt 0 ]] && scancel "${JOBIDS[@]}" 2>/dev/null || true
        exit 1
    fi
    jid="${jid%%;*}"
    JOBIDS+=("$jid")
    echo "submitted job $label ($ntasks workers) -> SLURM job $jid"
}
for (( j = 0; j < JOBS; j++ )); do
    nt=$(job_worker_count "$j")
    (( nt > 0 )) || continue
    submit_one "$j" "$nt" "$j" "$WALLTIME"
done
for spec in ${SLOW_JOBS[@]+"${SLOW_JOBS[@]}"}; do
    read -r sj snt slabel <<<"$spec"
    submit_one "$sj" "$snt" "slow-$slabel" "$SLOW_WALLTIME"
done

cancel_jobs() {
    trap - INT TERM
    echo; echo "Cancelling jobs: ${JOBIDS[*]}"
    scancel "${JOBIDS[@]}" 2>/dev/null || true
    exit 130
}
trap cancel_jobs INT TERM

# ── Poll until every job leaves the queue, with a progress line ──────────────
IDLIST=$(IFS=,; echo "${JOBIDS[*]}")
while :; do
    left=$(squeue -h -o '%T' -j "$IDLIST" 2>/dev/null | grep -c . || true)
    # The glob matches nothing until the first shard row lands, so the cat
    # (and the whole pipeline, under pipefail) must be allowed to fail.
    rows=$(cat "$RUNDIR"/shards/*.csv 2>/dev/null | wc -l || true)
    echo "$(date +%H:%M:%S)  jobs in queue: $left   result rows: $rows/$TOTAL_TESTS"
    (( left == 0 )) && break
    sleep 60
done
trap - INT TERM

# ── Merge shards into the master CSV and summarize ───────────────────────────
mkdir -p "$OUTPUTS_DIR"
if [[ ! -f "$CSV" ]]; then
    echo "build,crate,test,status,compile_seconds,mean_s,stddev_s,median_s,min_s,max_s,runs,timestamp,job_id" > "$CSV"
fi
cat "$RUNDIR"/shards/*.csv >> "$CSV" 2>/dev/null || true

echo
echo "Done. Results CSV: $CSV"
# Status is field 4; test names contain '::' but never commas, so this is safe.
cat "$RUNDIR"/shards/*.csv 2>/dev/null | awk -F, '
    { c[$4]++; total++ }
    END {
        for (s in c) printf "  %s: %d\n", s, c[s]
        printf "  total rows: %d\n", total + 0
    }' || true
rows=$(cat "$RUNDIR"/shards/*.csv 2>/dev/null | wc -l || true)
if (( rows < TOTAL_TESTS )); then
    echo "  NOTE: fewer rows than tests -- crates killed by walltime (or fetch/"
    echo "  build failures, which emit 1 row for a whole crate). See the crates'"
    echo "  hyperfine-${IMAGE}.log and $RUNDIR/job-*.out"
fi

