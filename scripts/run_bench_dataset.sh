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
#                     list_tests.sh). Default: <outputs>/tests-<dataset>.csv.
#                     analysis/missing_tests.py diffs such a CSV against a
#                     run's hyperfine CSV and writes the tests it never
#                     reported, to pick up a walltime-killed sweep
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
#   --all-slow        treat EVERY selected test as slow: skip the slowlist and
#                     the crate-level dealing entirely and split the tests
#                     evenly over --jobs jobs of --tasks workers (default
#                     16 x 24), at --slow-walltime and one run per test. Made
#                     for reruns where everything left is slow -- e.g. the
#                     leftovers missing_tests.py finds after a sweep is killed
#                     by walltime -- see the "Even test deal" note below
#   --slow-group N    slowlist crates per group (default 10). Groups are cut in
#                     slowlist FILE ORDER: first N entries, then the next N
#   --slow-splits N   how many jobs each group's tests are spread over
#                     (default 4). Each group becomes N jobs; every crate's
#                     test list is strided N ways, so a group of 10 crates
#                     runs as N jobs x 10 single-cpu workers
#                     (--slow-group/--slow-splits shape the CRATE slowlist
#                     only; they are unused when a test-level list is in play)
#   --slow-tests FILE test-level slow list, "crate,test" rows ordered SLOWEST
#                     FIRST. Replaces the crate slowlist entirely (see "Test-
#                     level slow/medium lists" below). Default: <scripts>/
#                     <mode>-slow.csv if it exists (so bsan picks up
#                     bsan-slow.csv on its own)
#   --medium-tests FILE  test-level medium list, same "crate,test" format.
#                     Its tests all run in ONE job of --max-tasks workers.
#                     Default: <scripts>/<mode>-medium.csv if it exists
#   --no-test-lists   still resolve and CLAIM the slow/medium lists (so their
#                     tests are still subtracted from the regular dealing) but
#                     never build the jobs that would run them -- i.e. run only
#                     the tests NOT named in either list. Use to skip a slow
#                     tail entirely rather than pay for it in its own jobs.
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
# Every mode compiles with RUSTFLAGS="--cfg=miri --cap-lints=warn" -- including
# rust and bsan. The --cfg=miri part makes all three select the same cfg(miri)
# code and, crucially, the same TEST SET as Miri: #[cfg(not(miri))] tests are
# compiled out and #[cfg_attr(miri, ignore)] tests are ignored everywhere, so
# the modes are comparable instead of each running whatever its own cfg
# selected. Rows written before this change came from differently-configured
# builds. --cap-lints=warn keeps a crate whose own deny/forbid lints fire from
# failing the build outright, so it still compiles and gets timed.
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
# Test-level slow/medium lists
# ----------------------------
# The crate slowlist above deals whole CRATES, so its jobs are only as wide as
# the group (10 workers by default) no matter how lopsided the crates are. When
# a run has already been profiled the unit that matters is the TEST, not the
# crate, and both lists below are read in place of scripts/slowlist:
#
#   <scripts>/<mode>-slow.csv    the slowest tests, ORDERED slowest first
#   <scripts>/<mode>-medium.csv  the middling ones, any order
#
# Both are "crate,test" rows (the test column may be ';'-joined, and rows may
# be CRLF/quoted/TAB-separated -- these files are assembled by hand and by
# several analysis scripts, so the parser tolerates all of that). They are
# picked up automatically when present, which for `bsan` means bsan-slow.csv
# and bsan-medium.csv; --slow-tests/--medium-tests point elsewhere.
#
# --no-test-lists does NOT bring back the crate slowlist. The lists are still
# resolved and their tests are still subtracted from the regular dealing --
# it just stops there, building no slow/medium jobs, so those tests are
# excluded from the run entirely rather than run somewhere else. Use it to
# skip a known-slow tail on a rerun instead of paying for it again.
#
#   slow    cut into jobs of --max-tasks (24) tests IN FILE ORDER, ONE TEST PER
#           WORKER -- so the first job holds the 24 slowest tests, the next the
#           24 after those. 96 slow tests is 4 jobs x 24 single-cpu workers,
#           each worker compiling its crate and timing its one test.
#   medium  ONE job of --max-tasks (24) workers, the list cut into 24 even
#           contiguous slices. Contiguous so a crate stays inside as few
#           slices as possible: every worker that touches a crate compiles it.
#   rest    everything left in the --tests CSV runs as REGULAR crate-per-worker
#           jobs, with the slow and medium tests SUBTRACTED from each crate's
#           test list so nothing is timed twice (a crate whose tests are all
#           claimed drops out of the regular dealing entirely).
#
# Slow and medium jobs both run at --slow-walltime and --slow-runs. Every
# worker gets a private CARGO_HOME and CARGO_TARGET_DIR, so the only thing the
# slices of one crate share is the crate DIRECTORY (and a Cargo.lock cargo may
# want to write). The crate slowlist already ran 4 workers per crate that way;
# a heavily-listed crate now reaches ~20, since its slow tests, its medium
# slice and its regular leftovers are all in flight at once.
#
# Typical use, with the tests CSV that the lists were derived from:
#
#   run_bench_dataset.sh --tests scripts/bsan-tests.csv bsan bsan top_500
#
# Even test deal (--all-slow)
# ---------------------------
# Both shapes above still deal whole CRATES to workers, so a rerun of 7 crates
# uses 7 workers however many tests they hold. --all-slow drops the fast/slow
# distinction and makes the TEST the unit: every selected crate's tests are
# laid end to end in the tests CSV's crate order and cut evenly TWICE -- first
# into --jobs shares, one per job, then each job's share into --tasks worker
# slices. Shares differ by at most one test at both levels, so a run is
# --jobs x --tasks workers wide (16 x 24 by default, i.e. 384 tests in flight)
# and every job holds the same amount of work. The slowlist file has no say --
# every test is treated as slow: --slow-walltime for every job and one run per
# test unless --runs says otherwise.
#
# Both cuts are CONTIGUOUS rather than round-robin, which is what keeps the
# compile bill near its floor: every worker that touches a crate compiles it
# privately, so a crate is split only where it straddles a slice boundary and
# costs one compile per worker it lands on. Round-robin at test granularity
# would instead compile every crate on every worker. Wider jobs trade core
# time for wall clock -- those extra compiles run concurrently, one per core,
# so 24 workers on 24 slow tests turn "24 x test" into "compile + test" -- and
# --tasks is the knob when that trade is not worth it. Typical use, after
# missing_tests.py built a rerun list:
#
#   run_bench_dataset.sh --tests tests-rest.csv --all-slow miri miri top_500
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
# A test_failed or no_match test never reaches hyperfine, so the CSV records
# only the verdict. Its output -- the panic message, the Miri/BSAN report,
# libtest's `failures:` summary -- is written to the crate log between
# "--- output: <crate> :: <test> ..." markers (last 200 lines), which is the
# only place it exists.
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
ALL_SLOW=0           # --all-slow: split every test evenly, no fast/slow split
ALL_SLOW_JOBS=16     # its default job count (overridden by --jobs)
ALL_SLOW_TASKS=24    # its default workers per job (overridden by --tasks)
RUNS_GIVEN=0         # was --runs passed? (--all-slow forces 1 otherwise)
WALLTIME_GIVEN=0     # was the walltime positional passed?
SLOW_GROUP=10        # slowlist crates per group
SLOW_SPLITS=4        # jobs each group's tests are split across
SLOW_TESTS_FILE=""   # test-level slow list; empty = <scripts>/<mode>-slow.csv
MEDIUM_TESTS_FILE="" # test-level medium list; empty = <mode>-medium.csv
NO_TEST_LISTS=0      # --no-test-lists: claim but don't run the listed tests
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
        --runs)          RUNS="$2"; RUNS_GIVEN=1; shift 2 ;;
        --runs=*)        RUNS="${1#*=}"; RUNS_GIVEN=1; shift ;;
        --slow-runs)     SLOW_RUNS="$2"; shift 2 ;;
        --slow-runs=*)   SLOW_RUNS="${1#*=}"; shift ;;
        --warmup)        WARMUP="$2"; shift 2 ;;
        --warmup=*)      WARMUP="${1#*=}"; shift ;;
        --test-threads)  TEST_THREADS="$2"; shift 2 ;;
        --test-threads=*) TEST_THREADS="${1#*=}"; shift ;;
        --all-slow)      ALL_SLOW=1; shift ;;
        --slow-walltime) SLOW_WALLTIME_ARG="$2"; shift 2 ;;
        --slow-walltime=*) SLOW_WALLTIME_ARG="${1#*=}"; shift ;;
        --slow-group)    SLOW_GROUP="$2"; shift 2 ;;
        --slow-group=*)  SLOW_GROUP="${1#*=}"; shift ;;
        --slow-splits)   SLOW_SPLITS="$2"; shift 2 ;;
        --slow-splits=*) SLOW_SPLITS="${1#*=}"; shift ;;
        --slow-tests)    SLOW_TESTS_FILE="$2"; shift 2 ;;
        --slow-tests=*)  SLOW_TESTS_FILE="${1#*=}"; shift ;;
        --medium-tests)  MEDIUM_TESTS_FILE="$2"; shift 2 ;;
        --medium-tests=*) MEDIUM_TESTS_FILE="${1#*=}"; shift ;;
        --no-test-lists) NO_TEST_LISTS=1; shift ;;
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
    echo "           --all-slow (split every test evenly over --jobs x --tasks)" >&2
    echo "           --slow-walltime T (for slowlist jobs, default 24)" >&2
    echo "           --slow-group N --slow-splits N (crate slowlist shape, 10 x 4)" >&2
    echo "           --slow-tests FILE --medium-tests FILE --no-test-lists" >&2
    echo "             (test-level lists; default <mode>-slow/-medium.csv)" >&2
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
    WALLTIME_GIVEN=1
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
if (( ALL_SLOW )); then
    # Every worker reads a part file, and the worker samples a part with
    # SLOW_RUNS -- so both counts must agree or the sampling would depend on a
    # flag the user never set. One run per test unless --runs says otherwise.
    (( RUNS_GIVEN )) || RUNS=1
    SLOW_RUNS=$RUNS
    # No share is "the fast one" any more, so the short regular walltime no
    # longer holds. (WALLTIME is parsed by here, so assign the parsed value.)
    (( WALLTIME_GIVEN )) || WALLTIME="$SLOW_WALLTIME"
    [[ -n "$JOBS"  ]] || JOBS=$ALL_SLOW_JOBS
    [[ -n "$TASKS" ]] || TASKS=$ALL_SLOW_TASKS
fi
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

# ── Test-level slow/medium lists ─────────────────────────────────────────────
# Named after the mode, so `bsan` finds bsan-slow.csv / bsan-medium.csv without
# being told. A file named explicitly must exist (a typo there should not
# silently fall back to whole-crate dealing); a defaulted one is optional.
# --all-slow deals every test itself, so the lists have nothing to say there.
for v in SLOW_TESTS_FILE MEDIUM_TESTS_FILE; do
    if [[ -n "${!v}" ]]; then
        [[ -f "${!v}" ]] || { echo "Error: test list not found: ${!v}" >&2; exit 1; }
    fi
done
if (( ALL_SLOW )); then
    SLOW_TESTS_FILE=""; MEDIUM_TESTS_FILE=""
else
    [[ -n "$SLOW_TESTS_FILE"   ]] || SLOW_TESTS_FILE="$GROUP/scripts/${MODE}-slow.csv"
    [[ -n "$MEDIUM_TESTS_FILE" ]] || MEDIUM_TESTS_FILE="$GROUP/scripts/${MODE}-medium.csv"
    [[ -f "$SLOW_TESTS_FILE"   ]] || SLOW_TESTS_FILE=""
    [[ -f "$MEDIUM_TESTS_FILE" ]] || MEDIUM_TESTS_FILE=""
fi
# When a test-level list is in play it replaces the crate slowlist outright:
# the lists already say which individual tests are slow, and leaving whole
# crates out of the regular dealing on top of that would strand the tests the
# lists did NOT claim in a 24h job of their own.
USE_TEST_LISTS=0
[[ -n "$SLOW_TESTS_FILE" || -n "$MEDIUM_TESTS_FILE" ]] && USE_TEST_LISTS=1

# --no-test-lists still resolves and claims the lists (below) -- so their tests
# are still pulled out of the regular dealing -- it just never builds the
# slow-test/medium jobs those tests would otherwise run in. The run therefore
# covers only what neither list claims.
if (( NO_TEST_LISTS )) && (( ! USE_TEST_LISTS )); then
    echo "Warning: --no-test-lists has nothing to exclude -- no slow/medium list" >&2
    echo "resolved (mode '$MODE' has no default, and neither --slow-tests nor" >&2
    echo "--medium-tests was given)." >&2
fi

# Slow and medium jobs are MAX_TASKS wide by construction (TASKS is auto-sized
# from the regular crates and says nothing about them), so the node-capacity
# check that guards TASKS has to cover MAX_TASKS too. Only relevant when those
# jobs will actually be submitted -- --no-test-lists claims the same tests but
# never builds them.
if (( USE_TEST_LISTS && ! NO_TEST_LISTS )); then
    if (( MAX_TASKS * MEM_PER_TASK > 488 )); then
        echo "Error: max-tasks*mem = $(( MAX_TASKS * MEM_PER_TASK ))G exceeds the 488G usable on an ACES node." >&2
        echo "Lower --max-tasks or --mem-per-task." >&2
        exit 1
    fi
    if (( MAX_TASKS * CPUS_PER_TASK > 96 )); then
        echo "Error: max-tasks*cpus = $(( MAX_TASKS * CPUS_PER_TASK )) exceeds the 96 cores on an ACES node." >&2
        exit 1
    fi
fi

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
declare -A ELIGIBLE=()   # crates that survived the filters AND have a dataset
                         # dir -- what a test-level list entry is checked against
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
    if [[ ! -d "$DATASET_DIR/$crate" ]]; then MISSING+=("$crate"); continue; fi
    ELIGIBLE["$crate"]=1
    if [[ -z "$tests" ]]; then skip_empty=$((skip_empty+1)); continue; fi
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

# ── Claim the tests named by the test-level lists ────────────────────────────
# Both lists are read IN FILE ORDER and kept that way -- the slow one is sorted
# slowest-first, and that order is what decides which tests share a job.
#
# The parser is deliberately forgiving: these files are assembled by hand and
# by several analysis scripts, so rows arrive with CRLF endings, a quoted crate
# field, a TAB where the comma should be, or several ';'-joined tests in the
# test column. Each is normalised to one "crate<TAB>test" line per test. A
# trailing contains_ffi column (should a full tests CSV be passed) is dropped.
parse_test_list() {
    awk '
        {
            line = $0
            sub(/\r$/, "", line)
            gsub(/"/, "", line)
            if (line ~ /^[[:space:]]*(#|$)/) next
            i = index(line, ",")
            if (i > 0) { crate = substr(line, 1, i - 1); tests = substr(line, i + 1) }
            else { if (split(line, f, /[ \t]+/) < 2) next; crate = f[1]; tests = f[2] }
            i = index(tests, ",")          # drop a contains_ffi column if present
            if (i > 0) tests = substr(tests, 1, i - 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", crate)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", tests)
            if (crate == "" || crate == "crate" || tests == "") next
            n = split(tests, t, ";")
            for (k = 1; k <= n; k++) {
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", t[k])
                if (t[k] != "") printf "%s\t%s\n", crate, t[k]
            }
        }' "$1"
}

SLOW_TESTS=()            # "crate<TAB>test", slowest first
MEDIUM_TESTS=()
declare -A CLAIMED=()    # every test either list took, to subtract below
TL_PAIRS=(); TL_SKIPPED=0; TL_DUP=0
# Fills TL_PAIRS with the eligible, not-yet-claimed tests of <file>.
load_test_list() {
    local crate test key
    TL_PAIRS=(); TL_SKIPPED=0; TL_DUP=0
    while IFS=$'\t' read -r crate test; do
        key="$crate"$'\t'"$test"
        # A test named twice (in one list or in both) is run once: the first
        # list to claim it owns it, so slow beats medium.
        if [[ -n "${CLAIMED[$key]:-}" ]]; then TL_DUP=$((TL_DUP+1)); continue; fi
        # Crates the run's own filters dropped -- or that the dataset does not
        # have -- stay dropped, so the lists work across datasets the way the
        # crate slowlist does.
        if [[ -z "${ELIGIBLE[$crate]:-}" ]]; then TL_SKIPPED=$((TL_SKIPPED+1)); continue; fi
        CLAIMED["$key"]=1
        TL_PAIRS+=("$key")
    done < <(parse_test_list "$1")
}

slow_skipped=0; medium_skipped=0; tl_dups=0; skip_claimed=0
if [[ -n "$SLOW_TESTS_FILE" ]]; then
    load_test_list "$SLOW_TESTS_FILE"
    SLOW_TESTS=(${TL_PAIRS[@]+"${TL_PAIRS[@]}"})
    slow_skipped=$TL_SKIPPED; tl_dups=$(( tl_dups + TL_DUP ))
fi
if [[ -n "$MEDIUM_TESTS_FILE" ]]; then
    load_test_list "$MEDIUM_TESTS_FILE"
    MEDIUM_TESTS=(${TL_PAIRS[@]+"${TL_PAIRS[@]}"})
    medium_skipped=$TL_SKIPPED; tl_dups=$(( tl_dups + TL_DUP ))
fi

# Subtract the claimed tests from the regular per-crate lists, so a test timed
# in a slow or medium job is not timed again by the crate that owns it. A crate
# left with nothing drops out of the regular dealing (and out of the worker and
# job sizing below) entirely.
if (( ${#CLAIMED[@]} > 0 )); then
    printf '%s\n' "${!CLAIMED[@]}" > "$RUNDIR/claimed.tsv"
    awk -F'\t' -v d="$RUNDIR/tests" '{ f = d "/" $1 ".claimed.txt"; print $2 >> f; close(f) }' \
        "$RUNDIR/claimed.tsv"
    KEPT=(); TOTAL_TESTS=0
    for line in "${SELECTED[@]}"; do
        crate="${line#*$'\t'}"
        claims="$RUNDIR/tests/$crate.claimed.txt"
        if [[ -f "$claims" ]]; then
            # grep exits 1 when every line was claimed -- an empty result, not
            # an error, so it must not take the script down under set -e.
            grep -Fxv -f "$claims" "$RUNDIR/tests/$crate.txt" \
                > "$RUNDIR/tests/$crate.rest.txt" || true
            mv "$RUNDIR/tests/$crate.rest.txt" "$RUNDIR/tests/$crate.txt"
        fi
        cnt=$(wc -l < "$RUNDIR/tests/$crate.txt")
        (( cnt > 0 )) || { skip_claimed=$((skip_claimed+1)); continue; }
        KEPT+=("$(printf '%d\t%s' "$cnt" "$crate")")
        TOTAL_TESTS=$(( TOTAL_TESTS + cnt ))
    done
    SELECTED=(${KEPT[@]+"${KEPT[@]}"})
    # Under --no-test-lists the claimed tests are excluded outright -- no job
    # will ever produce a row for them -- so they must not inflate the total
    # the progress line and the "fewer rows than tests" check are judged against.
    (( NO_TEST_LISTS )) || TOTAL_TESTS=$(( TOTAL_TESTS + ${#SLOW_TESTS[@]} + ${#MEDIUM_TESTS[@]} ))
fi

if (( NO_TEST_LISTS )); then
    if (( ${#SELECTED[@]} == 0 )); then
        echo "Error: --no-test-lists excludes every test claimed by the slow/medium" >&2
        echo "lists, and no regular tests are left after filtering $TESTS_CSV." >&2
        exit 1
    fi
elif (( ${#SELECTED[@]} + ${#SLOW_TESTS[@]} + ${#MEDIUM_TESTS[@]} == 0 )); then
    echo "Error: no tests left to run after filtering $TESTS_CSV." >&2
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
#
# A test-level list (above) takes this over completely: it already says which
# individual tests are slow, so the crates holding them keep their remaining
# tests in the regular dealing instead of being pulled out wholesale.
SLOWLIST_FILE="$GROUP/scripts/slowlist"
declare -A SLOWLIST=()
SLOW_ORDER=()
if (( ! USE_TEST_LISTS )) && [[ -f "$SLOWLIST_FILE" ]]; then
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
    (( ALL_SLOW )) && continue      # --all-slow deals tests, not crates
    # With a test-level list the SLOWLIST array is empty, so every crate that
    # still has tests is a regular one.
    [[ -z "${SLOWLIST[$crate]:-}" ]] && FAST_SEL+=("$line")
done

SLOW_CRATES=()
if (( ! ALL_SLOW )); then
    for crate in ${SLOW_ORDER[@]+"${SLOW_ORDER[@]}"}; do
        [[ -n "${SEL_COUNT[$crate]:-}" ]] && SLOW_CRATES+=("$crate")
    done
fi

# ── --all-slow: cut every test into JOBS x TASKS even slices ─────────────────
# Two contiguous cuts. First the whole test stream (all crates, in tests-CSV
# order) into JOBS shares, so every job holds the same amount of work; then
# each job's share into TASKS worker slices. Both differ by at most one test.
#
# Slices are filled in order and a crate's tests are adjacent, so a crate is
# split only where it straddles a slice boundary -- one compile per worker it
# lands on, no more -- and exactly one part file is open at a time, so awk's
# open-file limit never comes into play. Part files and chunk lines are the
# same ones the slowlist splitting writes, so the worker and inner.sh need no
# changes: a chunk line "<crate>\t<part>" points a worker at its slice.
if (( ALL_SLOW )); then
    for line in "${SELECTED[@]}"; do
        crate="${line#*$'\t'}"
        awk -v c="$crate" '{ print c "\t" $0 }' "$RUNDIR/tests/$crate.txt"
    done > "$RUNDIR/all-tests.tsv"

    mapfile -t ALL_SLOW_SHAPE < <(awk -F'\t' -v jobs="$JOBS" -v tasks="$TASKS" \
        -v total="$TOTAL_TESTS" -v rundir="$RUNDIR" '
        BEGIN {
            jbase = int(total / jobs); jrem = total % jobs
            j = -1; jfilled = 0; jcap = 0
            w = -1; wfilled = 0; wcap = 0
            cur = ""
        }
        {
            # Next job once this one has its share (a job can be capped at 0
            # when there are more jobs than tests; the guard just skips it).
            while (jfilled >= jcap && j < jobs - 1) {
                j++; jfilled = 0; jcap = jbase + (j < jrem ? 1 : 0)
                wbase = int(jcap / tasks); wrem = jcap % tasks
                w = -1; wfilled = 0; wcap = 0
            }
            while (wfilled >= wcap && w < tasks - 1) {
                w++; wfilled = 0; wcap = wbase + (w < wrem ? 1 : 0)
            }
            crate = $1; test = $2
            if (cur != j SUBSEP w SUBSEP crate) {
                if (cur != "") close(partfile)
                cur = j SUBSEP w SUBSEP crate
                part = nparts[crate]++      # per-crate part index (0,1,2..)
                partfile = rundir "/tests/" crate ".part" part ".txt"
                chunkfile = rundir "/chunks/chunk-" j "-" w ".txt"
                printf "%s\t%s\n", crate, part >> chunkfile
                close(chunkfile)
                if (w + 1 > ntasks[j]) ntasks[j] = w + 1
                nslices++                   # one slice == one compile
            }
            print test >> partfile
            jfilled++; wfilled++; jobtests[j]++
        }
        END {
            if (cur != "") close(partfile)
            for (k = 0; k < jobs; k++)
                if (ntasks[k] > 0) printf "%d %d %d %d\n", k, ntasks[k], jobtests[k], nslices
        }' "$RUNDIR/all-tests.tsv")

    (( ${#ALL_SLOW_SHAPE[@]} > 0 )) || { echo "Error: --all-slow produced no work." >&2; exit 1; }

    # More jobs (or workers) than tests leaves the tail empty. Shares are
    # filled in order, so the occupied jobs are exactly 0..count-1, and JOBS
    # and TASKS can shrink to what will actually be submitted rather than
    # asking for a quarter node to run three tests.
    JOBS=${#ALL_SLOW_SHAPE[@]}
    TASKS=1
    ALL_SLOW_MIN=0; ALL_SLOW_MAX=0; ALL_SLOW_SLICES=0
    for spec in "${ALL_SLOW_SHAPE[@]}"; do
        read -r _ nt ntests ALL_SLOW_SLICES <<<"$spec"
        (( nt > TASKS )) && TASKS=$nt
        (( ALL_SLOW_MIN == 0 || ntests < ALL_SLOW_MIN )) && ALL_SLOW_MIN=$ntests
        (( ntests > ALL_SLOW_MAX )) && ALL_SLOW_MAX=$ntests
    done
fi

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

# A slow job asks for one worker per crate in its group, so SLOW_GROUP -- not
# TASKS -- bounds those. Only worth checking when slow jobs will be submitted.
if (( ${#SLOW_CRATES[@]} > 0 )); then
    if (( SLOW_GROUP * MEM_PER_TASK > 488 )); then
        echo "Error: slow-group*mem = $(( SLOW_GROUP * MEM_PER_TASK ))G exceeds the 488G usable on an ACES node." >&2
        echo "Lower --slow-group or --mem-per-task." >&2
        exit 1
    fi
    if (( SLOW_GROUP * CPUS_PER_TASK > 96 )); then
        echo "Error: slow-group*cpus = $(( SLOW_GROUP * CPUS_PER_TASK )) exceeds the 96 cores on an ACES node." >&2
        exit 1
    fi
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

# ── Jobs for the test-level slow and medium lists ────────────────────────────
# They take the job indices after everything above. A worker is pointed at a
# slice with the same "<crate>\t<part>" chunk line the crate slowlist writes,
# so job.sh needs no changes -- and the part field is also what makes those
# workers sample SLOW_RUNS times instead of RUNS.
#
# Part numbers are handed out per crate across BOTH lists (a crate appears in
# each, and both write into $RUNDIR/tests), so no two slices of a crate can
# claim the same file or the same part log.
NEXT_JOB=$JOBS
for spec in ${SLOW_JOBS[@]+"${SLOW_JOBS[@]}"}; do
    read -r sj _ _ <<<"$spec"
    (( sj + 1 > NEXT_JOB )) && NEXT_JOB=$(( sj + 1 ))
done
declare -A PART_IDX=()
PART=""
next_part() {   # sets PART to the next free part index for crate $1
    PART="${PART_IDX[$1]:-0}"
    PART_IDX["$1"]=$(( PART + 1 ))
}

# Slow: MAX_TASKS tests per job, one test per worker, in list order -- so the
# first job holds the slowest MAX_TASKS tests, the next the MAX_TASKS after
# those. Nothing is shared inside a job, so a job ends when its slowest single
# test does, and grouping by rank keeps the fast ones from waiting on it.
#
# --no-test-lists skips this block entirely: SLOW_TESTS is still populated (it
# already did its job subtracting these tests from the regular dealing above),
# but no chunks are written for them, so they simply never run this pass.
SLOW_TEST_JOBS=()   # "<job idx> <ntasks> <label>"
if (( ${#SLOW_TESTS[@]} > 0 && ! NO_TEST_LISTS )); then
    nsjobs=$(( (${#SLOW_TESTS[@]} + MAX_TASKS - 1) / MAX_TASKS ))
    for (( g = 0; g < nsjobs; g++ )); do
        j=$NEXT_JOB; NEXT_JOB=$(( NEXT_JOB + 1 ))
        nt=0
        for (( t = 0; t < MAX_TASKS; t++ )); do
            idx=$(( g * MAX_TASKS + t ))
            (( idx < ${#SLOW_TESTS[@]} )) || break
            crate="${SLOW_TESTS[$idx]%%$'\t'*}"
            test="${SLOW_TESTS[$idx]#*$'\t'}"
            next_part "$crate"
            printf '%s\n' "$test" > "$RUNDIR/tests/$crate.part$PART.txt"
            printf '%s\t%s\n' "$crate" "$PART" > "$RUNDIR/chunks/chunk-$j-$t.txt"
            nt=$(( t + 1 ))
        done
        SLOW_TEST_JOBS+=("$j $nt slow$(( g + 1 ))")
    done
fi

# Medium: one job, MAX_TASKS workers, the list cut into that many even
# CONTIGUOUS slices. Contiguous because every worker that touches a crate
# compiles it privately: with the list grouped by crate, a crate is split only
# where it straddles a slice boundary, and consecutive tests of one crate
# inside a slice share a single part file (one compile, one calibration row).
#
# Also skipped under --no-test-lists, same reasoning as the slow block above.
MEDIUM_JOB=""
if (( ${#MEDIUM_TESTS[@]} > 0 && ! NO_TEST_LISTS )); then
    j=$NEXT_JOB; NEXT_JOB=$(( NEXT_JOB + 1 ))
    nmed=${#MEDIUM_TESTS[@]}
    nworkers=$MAX_TASKS
    (( nworkers > nmed )) && nworkers=$nmed
    mbase=$(( nmed / nworkers )); mrem=$(( nmed % nworkers ))
    idx=0
    for (( t = 0; t < nworkers; t++ )); do
        share=$(( mbase + (t < mrem ? 1 : 0) ))
        chunk="$RUNDIR/chunks/chunk-$j-$t.txt"
        : > "$chunk"
        cur=""; partfile=""
        for (( s = 0; s < share; s++ )); do
            crate="${MEDIUM_TESTS[$idx]%%$'\t'*}"
            test="${MEDIUM_TESTS[$idx]#*$'\t'}"
            if [[ "$crate" != "$cur" ]]; then
                cur="$crate"
                next_part "$crate"
                partfile="$RUNDIR/tests/$crate.part$PART.txt"
                : > "$partfile"
                printf '%s\t%s\n' "$crate" "$PART" >> "$chunk"
            fi
            printf '%s\n' "$test" >> "$partfile"
            idx=$(( idx + 1 ))
        done
    done
    MEDIUM_JOB="$j $nworkers medium"
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
# RUSTFLAGS. --cap-lints=warn demotes the crate's own deny/forbid lints to
# warnings, so a crate that would otherwise fail to build on a lint it never
# meant to gate the build on still compiles and gets timed. EXPORTED rather
# than prefixed onto $RUN because $RUN is handed to hyperfine, which runs with
# -N (no shell) -- a "VAR=value cmd" prefix would be taken as the program name
# there, not as an assignment.
export RUSTFLAGS="--cfg=miri --cap-lints=warn"
echo "RUSTFLAGS=[$RUSTFLAGS]"

# libtest's --test-threads is a HARNESS flag, so it goes after the `--`, before
# --exact. Empty unless --test-threads was passed; the leading space lives
# inside the expansion so the command string is byte-identical to before when
# the option is unset (hyperfine runs with -N and splits on whitespace).
HARNESS="${HF_TEST_THREADS:-}"
HARNESS="${HARNESS:+ --test-threads=$HARNESS}"
[ -n "$HARNESS" ] && echo "HARNESS=[$HARNESS]"

# How many lines of a failing test's output to keep in the crate log. Enough
# for a Miri/BSAN report plus libtest's failure summary, bounded so one test
# spewing to stdout cannot swamp the log for every other test in the crate.
FAIL_LOG_LINES=200

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
    # A test that fails (or matches nothing) never reaches hyperfine, so this
    # pre-run is the ONLY place its panic / UB report ever exists -- dump it
    # into the crate log before the temp file goes, or the CSV's test_failed
    # says nothing about WHY. Tail, not head: the diagnosis (the panic message,
    # Miri's or BSAN's report, libtest's `failures:` summary) is at the end,
    # while the head is per-binary "running N tests" noise. Passing tests are
    # untouched, so a clean crate's log reads exactly as it did before.
    if [ "$rc" -ne 0 ] || [ "$nrun" -eq 0 ]; then
        nlines=$(wc -l < "$runlog")
        echo "--- output: $HF_CRATE :: $t (exit $rc, $nrun test(s) matched) ---"
        if [ "$nlines" -gt "$FAIL_LOG_LINES" ]; then
            echo "[... $(( nlines - FAIL_LOG_LINES )) earlier line(s) omitted ...]"
        fi
        tail -n "$FAIL_LOG_LINES" "$runlog"
        echo "--- end output: $HF_CRATE :: $t ---"
    fi
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
TL_TOTAL=$(( ${#SLOW_TESTS[@]} + ${#MEDIUM_TESTS[@]} ))
if (( NO_TEST_LISTS && TL_TOTAL > 0 )); then
    echo "Tests:    $TOTAL_TESTS across ${#SELECTED[@]} crate(s) (from $TESTS_CSV)"
    echo "          --no-test-lists: $TL_TOTAL test(s) excluded, not run (see Slow/Medium below)"
elif (( TL_TOTAL > 0 )); then
    # TOTAL_TESTS counts the list tests too, and their crates need not be among
    # the regular ones -- a crate can have every test claimed by a list.
    echo "Tests:    $TOTAL_TESTS total: $(( TOTAL_TESTS - TL_TOTAL )) across ${#SELECTED[@]} regular crate(s),"
    echo "          plus the test-level lists below (from $TESTS_CSV)"
else
    echo "Tests:    $TOTAL_TESTS across ${#SELECTED[@]} crates (from $TESTS_CSV)"
fi
echo "Skipped:  ignored=$skip_ignored not-in-only=$skip_only ffi=$skip_ffi no-tests=$skip_empty missing-dir=${#MISSING[@]}"
(( skip_claimed > 0 )) && echo "          ($skip_claimed crate(s) had every test claimed by a test-level list)"
if (( ${#MISSING[@]} > 0 )); then
    printf '  missing from dataset: %s\n' "${MISSING[@]}" | head -20
fi
if (( ALL_SLOW )); then
    echo "Shape:    $JOBS job(s) x up to $TASKS tasks x ${CPUS_PER_TASK} cpus, ${MEM_PER_TASK}G/task (<=${TOTAL_MEM}G/job), $WALLTIME each"
    echo "          (--all-slow: $TOTAL_TESTS test(s) split evenly over $JOBS job(s), $ALL_SLOW_MIN-$ALL_SLOW_MAX each,"
    echo "           then over their workers: $ALL_SLOW_SLICES slice(s) = $ALL_SLOW_SLICES compile(s); slowlist ignored)"
elif (( ${#FAST_SEL[@]} > 0 )); then
    echo "Shape:    $JOBS job(s) x up to $TASKS tasks x ${CPUS_PER_TASK} cpus, ${MEM_PER_TASK}G/task (<=${TOTAL_MEM}G/job), $WALLTIME each"
    echo "          (${#FAST_SEL[@]} regular crate(s); each job requests only the workers it holds)"
fi
if (( ${#SLOW_CRATES[@]} > 0 )); then
    echo "Slow:     ${#SLOW_CRATES[@]} slowlist crate(s) -> ${#SLOW_JOBS[@]} job(s) x up to $SLOW_GROUP workers at $SLOW_WALLTIME"
    echo "          (groups of $SLOW_GROUP crates, each group's tests split $SLOW_SPLITS ways,"
    echo "           $SLOW_RUNS run(s) per test)"
fi
if (( ${#SLOW_TESTS[@]} > 0 )); then
    if (( NO_TEST_LISTS )); then
        echo "Slow:     ${#SLOW_TESTS[@]} test(s) from $(basename "$SLOW_TESTS_FILE") -- excluded by --no-test-lists, not run"
    else
        echo "Slow:     ${#SLOW_TESTS[@]} test(s) from $(basename "$SLOW_TESTS_FILE") -> ${#SLOW_TEST_JOBS[@]} job(s) x up to $MAX_TASKS workers"
        echo "          (one test per worker, list order -- slowest first; $SLOW_WALLTIME, $SLOW_RUNS run(s) per test)"
    fi
    (( slow_skipped > 0 )) && echo "          ($slow_skipped entr(y/ies) skipped: crate not selected for this run)"
fi
if (( ${#MEDIUM_TESTS[@]} > 0 )); then
    if (( NO_TEST_LISTS )); then
        echo "Medium:   ${#MEDIUM_TESTS[@]} test(s) from $(basename "$MEDIUM_TESTS_FILE") -- excluded by --no-test-lists, not run"
    else
        read -r _ mnt _ <<<"$MEDIUM_JOB"
        echo "Medium:   ${#MEDIUM_TESTS[@]} test(s) from $(basename "$MEDIUM_TESTS_FILE") -> 1 job x $mnt workers"
        echo "          (even contiguous slices; $SLOW_WALLTIME, $SLOW_RUNS run(s) per test)"
    fi
    (( medium_skipped > 0 )) && echo "          ($medium_skipped entr(y/ies) skipped: crate not selected for this run)"
fi
(( tl_dups > 0 )) && echo "          ($tl_dups duplicate test-list entr(y/ies) collapsed)"
TOTAL_JOBS=$(( JOBS + ${#SLOW_JOBS[@]} + ${#SLOW_TEST_JOBS[@]} ))
[[ -n "$MEDIUM_JOB" ]] && TOTAL_JOBS=$(( TOTAL_JOBS + 1 ))
if (( TOTAL_JOBS > 40 )); then
    echo "WARNING:  $TOTAL_JOBS jobs exceeds the 40-job QOS limit; the extras will"
    echo "          queue until earlier ones finish (lower --jobs/--slow-splits,"
    echo "          or raise --slow-group to pack more crates per job)."
fi
# With no regular crates, $RUNS applies to nothing -- report only what runs.
RUNS_NOTE="$RUNS runs"
if (( ${#FAST_SEL[@]} == 0 && ${#SLOW_CRATES[@]} > 0 )); then
    RUNS_NOTE="$SLOW_RUNS runs"
elif (( ${#SLOW_CRATES[@]} > 0 )); then
    RUNS_NOTE="$RUNS runs (slowlist: $SLOW_RUNS)"
fi
echo "Sampling: $RUNS_NOTE, $WARMUP warmup per test${TEST_THREADS:+, --test-threads=$TEST_THREADS}"
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
for spec in ${SLOW_TEST_JOBS[@]+"${SLOW_TEST_JOBS[@]}"}; do
    read -r sj snt slabel <<<"$spec"
    submit_one "$sj" "$snt" "$slabel" "$SLOW_WALLTIME"
done
if [[ -n "$MEDIUM_JOB" ]]; then
    read -r mj mnt mlabel <<<"$MEDIUM_JOB"
    submit_one "$mj" "$mnt" "$mlabel" "$SLOW_WALLTIME"
fi

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

