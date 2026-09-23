#!/usr/bin/env bash
#
# Usage: run_bench_concurrent.sh [options] <image> [walltime] <dataset> [extra]
#
#   <image>     image/SIF name under the group containers dir (e.g. bsan, or a
#               variant/patched bsan image). bsan mode only -- see "Why bsan
#               only" below.
#   [walltime]  walltime per sbatch job, HH or HH:MM (default 2). One crate's
#               whole regular suite is now ONE timed invocation, so this covers
#               far more than the same number in run_bench_dataset.sh does.
#               (Recognized positionally by shape, so a purely numeric dataset
#               name would need the walltime spelled out.)
#   <dataset>   folder under the group datasets dir holding crate subdirectories.
#   [extra]     colon-separated BSAN_OPTIONS, appended to the built-in set.
#
# What this measures, and how it differs from run_bench_dataset.sh
# ----------------------------------------------------------------
# run_bench_dataset.sh times ONE test per `cargo bsan test` invocation
# (`-- --exact <test>`), serially, so nothing in a crate ever runs concurrently
# and --cpus-per-task only ever bought a faster one-off compile. This script
# times the OTHER shape: a crate's whole regular test list in a SINGLE
# invocation,
#
#     cargo bsan test --tests -- --test-threads=N --exact <t1> <t2> ... <tN>
#
# with N (default: --cpus-per-task, i.e. 4) libtest threads, so the tests
# actually run concurrently the way a developer running `cargo test` sees them.
# The unit of measurement is therefore the CRATE, not the test: one timed row
# per crate instead of one per test.
#
# Two consequences worth keeping in mind when comparing against a per-test CSV:
#
#   * the per-invocation constant (cargo's freshness check plus every test
#     binary's startup) is paid ONCE here, not once per test. On the top_500
#     regular set that constant is most of the serial total -- ~6000 serial
#     invocations at ~1-3s each -- so a concurrent row is expected to be far
#     below the sum of its crate's per-test rows even before any parallelism.
#     The __calibration__ row is still written per crate so that constant can
#     be subtracted from both sides.
#   * tests share one process. A #[test] that is not thread-safe, or a BSAN
#     report that takes the whole process down, affects every test in flight --
#     unlike the serial script, where each test had a process to itself.
#
# Only the "regular" tests run (the point of the request this was written for):
# every test named in the test-level slow and medium lists is subtracted from
# its crate's list and then simply never run -- the same claim-but-do-not-run
# behaviour as run_bench_dataset.sh --no-test-lists. There is no slow job, no
# medium job, no --all-slow and no crate slowlist here. A crate whose every
# test is claimed drops out of the run.
#
# Why bsan only: the mode is fixed rather than a positional so the defaults
# (BSAN_OPTIONS, bsan-slow.csv / bsan-medium.csv, the CSV name) need no
# per-mode branching. MODE below is still a variable, so adding miri/rust back
# is a one-line case statement plus a usage line.
#
# Options:
#   --tests FILE      tests CSV (crate,tests,contains_ffi -- as produced by
#                     list_tests.sh). Default: <outputs>/tests-<dataset>.csv
#   --no-ffi          only run crates whose contains_ffi column is exactly
#                     "false" (both "true" and "scan_failed" are skipped)
#   --ignore FILE     crate names to skip, one per line (#-comments ok)
#   --only FILE       run ONLY the crates listed in FILE (one per line,
#                     #-comments ok; --ignore/--no-ffi still apply on top)
#   --jobs N          number of single-node sbatch jobs. Default: as many as
#                     needed for full parallelism, ceil(crates / tasks),
#                     capped at 40 (the QOS job limit)
#   --tasks N         worker tasks per job. Default: auto -- one worker per
#                     crate left after filtering and claiming, capped at
#                     --max-tasks. Each job is submitted with only the workers
#                     it actually holds
#   --max-tasks N     ceiling for the auto-sized worker count (default 12 --
#                     at 4 cpus each that is half a node's 96 cores and 192G,
#                     the same node footprint the per-test script's 24x1
#                     default asks for. tasks*cpus may not exceed 96)
#   --cpus-per-task N cores per worker (default 4). Unlike in the per-test
#                     script this is the knob that matters: it caps cargo's
#                     build jobs AND, via --test-threads, how many tests run
#                     at once inside the timed invocation
#   --test-threads N  libtest threads for the timed invocation. Default:
#                     --cpus-per-task. Set it below the core count to measure
#                     contention separately from core count; the pair lands in
#                     the CSV name (-c<cpus>tt<threads>) so runs of different
#                     shapes can never append into one file
#   --mem-per-task G  GB per worker (default 16 -- four concurrent bsan tests
#                     hold rather more shadow memory than one; 12 x 16 = 192G,
#                     inside the 488G node cap)
#   --runs N          hyperfine timing runs per crate (default 3)
#   --warmup N        hyperfine warmup runs per crate (default 0; the untimed
#                     status pre-run already warms caches, so each crate's
#                     suite runs 1 + warmup + runs times in total)
#   --slow-tests FILE test-level slow list to EXCLUDE, "crate,test" rows.
#                     Default: <scripts>/bsan-slow.csv if it exists
#   --medium-tests FILE  test-level medium list to exclude, same format.
#                     Default: <scripts>/bsan-medium.csv if it exists
#
# Every crate compiles with RUSTFLAGS="--cfg=miri --cap-lints=warn", exactly as
# in run_bench_dataset.sh: --cfg=miri selects the same cfg(miri) code and the
# same TEST SET as Miri (#[cfg(not(miri))] compiled out, #[cfg_attr(miri,
# ignore)] ignored), and --cap-lints=warn keeps a crate's own deny/forbid lints
# from failing the build. Timings are only comparable across scripts because
# both use these.
#
# Failing tests
# -------------
# hyperfine gives up on a command that exits non-zero, and under bsan a
# non-trivial minority of crates have at least one failing test -- so one
# failure would otherwise cost the whole crate its row. The pre-run therefore
# loops: run the list untimed, and if it exits non-zero, take the test names
# out of libtest's `failures:` block (intersected with the requested list, so
# stray output cannot invent a name), drop them, and try again -- up to
# --max-preruns (3) passes. What is finally timed is the passing subset, which
# is also the only subset the per-test script ever timed, so the two remain
# comparable. The CSV records tests_requested, tests_run and excluded_failed
# per crate, and the dropped tests' output (panic / BSAN report) is in the
# crate log as usual.
#
# A non-zero exit with NO attributable failure -- a process abort, a harness
# error, a crate whose build went stale -- is not something dropping tests can
# fix, so the crate gets a prerun_failed row and no timing.
#
# Output
# ------
# Per-worker shards stream into <outputs>/<image>[-<slug>]-<dataset>-c<cpus>
# tt<threads>-concurrent.csv. The first 13 columns are exactly the per-test
# format's, so the analysis scripts read it unchanged; four more carry what is
# specific to a whole-suite row:
#
#   build,crate,test,status,compile_seconds,mean_s,stddev_s,median_s,min_s,
#   max_s,runs,timestamp,job_id,tests_requested,tests_run,test_threads,
#   excluded_failed
#
# test is __concurrent__ for the timed suite row and __calibration__ for the
# crate's zero-test invocation. status:
#
#   success        the whole surviving list ran and was timed
#   partial_match  timed, but libtest ran FEWER tests than were asked for --
#                  a stale test list, or (loudly) a libtest too old to accept
#                  more than one --exact filter. Check tests_run vs
#                  tests_requested before trusting such a row
#   all_failed     every test in the crate failed; nothing left to time
#   prerun_failed  non-zero exit with no attributable failing test
#   bench_failed   hyperfine itself errored
#   build_failed / fetch_failed   as in run_bench_dataset.sh
#   calibration    the per-crate constant row
#
# Per-crate logs land in <crate>/hyperfine-<image>-concurrent.log (the
# -concurrent suffix keeps them clear of the per-test script's logs).
# Chunks/shards/job scripts live under <outputs>/concurrent-runs/<runid>/.
#
# If this script is killed the sbatch jobs keep running (Ctrl-C cancels them
# first); shards survive, so results can be merged by hand:
#   cat <rundir>/shards/*.csv >> <master csv>
#
# NOTE: the image must contain `hyperfine` -- each job checks and aborts with
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

MODE="bsan"
BSAN_COMMON="stacktrace_max_len=32"

# ── Options ──────────────────────────────────────────────────────────────────
TESTS_CSV=""
NO_FFI=0
IGNORE_FILE=""
ONLY_FILE=""
JOBS=""              # empty = auto: ceil(crates / tasks), capped at 40
TASKS=""             # empty = auto: min(crates, MAX_TASKS)
MAX_TASKS=12         # ceiling on auto-sized workers per job (half a node at 4 cpus)
CPUS_PER_TASK=4
TEST_THREADS=""      # empty = follow CPUS_PER_TASK
MEM_PER_TASK=16      # GB per worker (12*16=192G, well inside the 488G node cap)
RUNS=3
WARMUP=0
MAX_PRERUNS=3        # pre-run passes allowed while dropping failing tests
SLOW_TESTS_FILE=""   # empty = <scripts>/bsan-slow.csv if present
MEDIUM_TESTS_FILE="" # empty = <scripts>/bsan-medium.csv if present
WALLTIME_ARG=2

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
        --test-threads)  TEST_THREADS="$2"; shift 2 ;;
        --test-threads=*) TEST_THREADS="${1#*=}"; shift ;;
        --mem-per-task)  MEM_PER_TASK="$2"; shift 2 ;;
        --mem-per-task=*) MEM_PER_TASK="${1#*=}"; shift ;;
        --runs)          RUNS="$2"; shift 2 ;;
        --runs=*)        RUNS="${1#*=}"; shift ;;
        --warmup)        WARMUP="$2"; shift 2 ;;
        --warmup=*)      WARMUP="${1#*=}"; shift ;;
        --max-preruns)   MAX_PRERUNS="$2"; shift 2 ;;
        --max-preruns=*) MAX_PRERUNS="${1#*=}"; shift ;;
        --slow-tests)    SLOW_TESTS_FILE="$2"; shift 2 ;;
        --slow-tests=*)  SLOW_TESTS_FILE="${1#*=}"; shift ;;
        --medium-tests)  MEDIUM_TESTS_FILE="$2"; shift 2 ;;
        --medium-tests=*) MEDIUM_TESTS_FILE="${1#*=}"; shift ;;
        -*)
            echo "Error: unknown option '$1'." >&2; exit 1 ;;
        *)
            POS+=("$1"); shift ;;
    esac
done
set -- ${POS[@]+"${POS[@]}"}

usage() {
    echo "Usage: $0 [options] <image> [walltime] <dataset> [extra]" >&2
    echo "  <image>     bsan image/SIF name under $CONTAINERS_DIR" >&2
    echo "  [walltime]  job walltime, HH or HH:MM (default 2)" >&2
    echo "  <dataset>   folder under $DATASETS_ROOT" >&2
    echo "  [extra]     extra BSAN_OPTIONS (colon-separated)" >&2
    echo "  options: --tests FILE --no-ffi --ignore FILE --only FILE --jobs N" >&2
    echo "           --tasks N --max-tasks N --cpus-per-task N (default 4)" >&2
    echo "           --test-threads N (default: --cpus-per-task) --mem-per-task G" >&2
    echo "           --runs N --warmup N --max-preruns N" >&2
    echo "           --slow-tests FILE --medium-tests FILE (excluded, not run;" >&2
    echo "             default <scripts>/bsan-slow.csv and bsan-medium.csv)" >&2
    exit 1
}
[[ $# -ge 2 && $# -le 4 ]] || usage

IMAGE_ARG="$1"
shift
# The walltime positional is optional: take the next arg as walltime only if it
# is shaped like one (HH or HH:MM); otherwise it is the dataset.
if [[ $# -ge 2 && "$1" =~ ^[0-9]{1,3}(:[0-9]{2})?$ ]]; then
    WALLTIME_ARG="$1"
    shift
fi
[[ $# -ge 1 && $# -le 2 ]] || usage
DATASET="$1"
EXTRA="${2:-}"

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

MEM_PER_TASK="${MEM_PER_TASK%G}"
for v in CPUS_PER_TASK MEM_PER_TASK RUNS WARMUP MAX_TASKS MAX_PRERUNS; do
    [[ "${!v}" =~ ^[0-9]+$ ]] || { echo "Error: $v must be a number." >&2; exit 1; }
done
(( RUNS          >= 1 )) || { echo "Error: --runs must be >= 1." >&2; exit 1; }
(( MAX_TASKS     >= 1 )) || { echo "Error: --max-tasks must be >= 1." >&2; exit 1; }
(( CPUS_PER_TASK >= 1 )) || { echo "Error: --cpus-per-task must be >= 1." >&2; exit 1; }
(( MAX_PRERUNS   >= 1 )) || { echo "Error: --max-preruns must be >= 1." >&2; exit 1; }
for v in JOBS TASKS; do
    if [[ -n "${!v}" ]]; then
        [[ "${!v}" =~ ^[0-9]+$ && "${!v}" -ge 1 ]] \
            || { echo "Error: --${v,,} must be a number >= 1." >&2; exit 1; }
    fi
done
# The whole point of this script is a concurrent invocation, so --test-threads
# defaults to the cores the worker was actually given rather than to libtest's
# own "one thread per core" (which, inside a cpuset-bound SLURM task, is the
# same number -- but only implicitly, and only if available_parallelism sees
# the binding).
if [[ -n "$TEST_THREADS" ]]; then
    [[ "$TEST_THREADS" =~ ^[1-9][0-9]*$ ]] \
        || { echo "Error: --test-threads must be a positive integer (got '$TEST_THREADS')." >&2; exit 1; }
else
    TEST_THREADS=$CPUS_PER_TASK
fi
if (( TEST_THREADS > CPUS_PER_TASK )); then
    echo "Warning: --test-threads=$TEST_THREADS exceeds --cpus-per-task=$CPUS_PER_TASK;" >&2
    echo "the threads will timeshare $CPUS_PER_TASK cores." >&2
fi

IMAGE="$(basename "${IMAGE_ARG%.sif}")"
SIF_ABS="$CONTAINERS_DIR/$IMAGE.sif"
DATASET_DIR="$DATASETS_ROOT/$DATASET"
[[ -n "$TESTS_CSV" ]] || TESTS_CSV="$OUTPUTS_DIR/tests-${DATASET}.csv"

BSAN_OPTIONS_ALL="$BSAN_COMMON${EXTRA:+:$EXTRA}"

# Master CSV. The concurrency shape is part of the measurement -- a 4-thread
# row and an 8-thread row are different experiments -- so it joins the extras
# slug in the filename and rows from different shapes can never be appended
# into one file.
SLUG=""
if [[ -n "$EXTRA" ]]; then
    SLUG="$(printf '%s' "$EXTRA" | tr -c '[:alnum:]' '-' | sed 's/-\{1,\}/-/g; s/^-//; s/-$//')"
fi
SHAPE="c${CPUS_PER_TASK}tt${TEST_THREADS}"
CSV="$OUTPUTS_DIR/${IMAGE}${SLUG:+-$SLUG}-${DATASET}-${SHAPE}-concurrent.csv"

# ── Validate ──────────────────────────────────────────────────────────────--
[[ -f "$SIF_ABS" ]]     || { echo "Error: image not found at $SIF_ABS" >&2; exit 1; }
[[ -d "$DATASET_DIR" ]] || { echo "Error: dataset dir not found: $DATASET_DIR" >&2; exit 1; }
[[ -f "$TESTS_CSV" ]]   || { echo "Error: tests CSV not found: $TESTS_CSV (--tests FILE?)" >&2; exit 1; }
command -v sbatch >/dev/null || { echo "Error: sbatch not found (run on a login node)." >&2; exit 1; }

# ── Test-level slow/medium lists (excluded, never run) ───────────────────────
# A file named explicitly must exist (a typo should not silently widen the run
# to include the slow tail); a defaulted one is optional.
for v in SLOW_TESTS_FILE MEDIUM_TESTS_FILE; do
    if [[ -n "${!v}" ]]; then
        [[ -f "${!v}" ]] || { echo "Error: test list not found: ${!v}" >&2; exit 1; }
    fi
done
[[ -n "$SLOW_TESTS_FILE"   ]] || SLOW_TESTS_FILE="$GROUP/scripts/${MODE}-slow.csv"
[[ -n "$MEDIUM_TESTS_FILE" ]] || MEDIUM_TESTS_FILE="$GROUP/scripts/${MODE}-medium.csv"
[[ -f "$SLOW_TESTS_FILE"   ]] || SLOW_TESTS_FILE=""
[[ -f "$MEDIUM_TESTS_FILE" ]] || MEDIUM_TESTS_FILE=""
if [[ -z "$SLOW_TESTS_FILE" && -z "$MEDIUM_TESTS_FILE" ]]; then
    echo "Warning: no slow/medium list found -- every test in $TESTS_CSV will be" >&2
    echo "run, including the slow tail. Pass --slow-tests/--medium-tests to exclude." >&2
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
RUNDIR="$OUTPUTS_DIR/concurrent-runs/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$RUNDIR/chunks" "$RUNDIR/tests" "$RUNDIR/shards"

# ── Parse the tests CSV ───────────────────────────────────────────────────---
# Rows are crate,tests,contains_ffi where tests is ';'-joined and guaranteed
# comma-free (see list_tests.sh). Duplicate names within a crate are collapsed;
# --exact runs such a name in every binary that has it anyway.
SELECTED=()          # "count<TAB>crate" lines, for size-descending dealing
declare -A SEEN_CRATE=()
declare -A ELIGIBLE=()
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

# ── Claim (and drop) the tests named by the slow/medium lists ────────────────
# The parser is deliberately forgiving: these files are assembled by hand and by
# several analysis scripts, so rows arrive with CRLF endings, a quoted crate
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

declare -A CLAIMED=()
n_slow=0; n_medium=0; slow_skipped=0; medium_skipped=0; tl_dups=0; skip_claimed=0
TL_KEPT=0; TL_SKIPPED=0; TL_DUP=0
load_test_list() {
    local crate test key
    TL_KEPT=0; TL_SKIPPED=0; TL_DUP=0
    while IFS=$'\t' read -r crate test; do
        key="$crate"$'\t'"$test"
        if [[ -n "${CLAIMED[$key]:-}" ]]; then TL_DUP=$((TL_DUP+1)); continue; fi
        # Crates this run's own filters dropped -- or that the dataset does not
        # have -- stay dropped, so the lists work across datasets.
        if [[ -z "${ELIGIBLE[$crate]:-}" ]]; then TL_SKIPPED=$((TL_SKIPPED+1)); continue; fi
        CLAIMED["$key"]=1
        TL_KEPT=$((TL_KEPT+1))
    done < <(parse_test_list "$1")
}
if [[ -n "$SLOW_TESTS_FILE" ]]; then
    load_test_list "$SLOW_TESTS_FILE"
    n_slow=$TL_KEPT; slow_skipped=$TL_SKIPPED; tl_dups=$(( tl_dups + TL_DUP ))
fi
if [[ -n "$MEDIUM_TESTS_FILE" ]]; then
    load_test_list "$MEDIUM_TESTS_FILE"
    n_medium=$TL_KEPT; medium_skipped=$TL_SKIPPED; tl_dups=$(( tl_dups + TL_DUP ))
fi

# Subtract them from the per-crate lists. A crate left with nothing drops out
# of the run (and out of the worker and job sizing below) entirely.
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
fi

if (( ${#SELECTED[@]} == 0 )); then
    echo "Error: every test in $TESTS_CSV is claimed by the slow/medium lists;" >&2
    echo "nothing left to run." >&2
    exit 1
fi

# ── Worker count per job: auto-size unless --tasks was given ─────────────────
# One worker per crate, capped at MAX_TASKS. Narrow jobs backfill into
# scheduling gaps that whole-node jobs never fit, and each job is later
# submitted with its OWN worker count (see job_worker_count).
if [[ -z "$TASKS" ]]; then
    TASKS=${#SELECTED[@]}
    (( TASKS > MAX_TASKS )) && TASKS=$MAX_TASKS
    (( TASKS < 1 )) && TASKS=1
fi

TOTAL_MEM=$(( TASKS * MEM_PER_TASK ))
if (( TOTAL_MEM > 488 )); then
    echo "Error: tasks*mem = ${TOTAL_MEM}G exceeds the 488G usable on an ACES node." >&2
    echo "Lower --tasks/--max-tasks or --mem-per-task." >&2
    exit 1
fi
TOTAL_CPUS=$(( TASKS * CPUS_PER_TASK ))
if (( TOTAL_CPUS > 96 )); then
    echo "Error: tasks*cpus = ${TOTAL_CPUS} exceeds the 96 cores on an ACES node." >&2
    echo "Lower --tasks/--max-tasks or --cpus-per-task." >&2
    exit 1
fi

# ── Job count: auto-size unless --jobs was given ─────────────────────────────
if [[ -z "$JOBS" ]]; then
    JOBS=$(( (${#SELECTED[@]} + TASKS - 1) / TASKS ))
    (( JOBS > 40 )) && JOBS=40
fi

# ── Deal crates round-robin across jobs*tasks workers, biggest first ─────────
# Sorting by test count descending before dealing gives a rough longest-
# processing-time-first balance. Note the unit dealt is a CRATE, as in the
# per-test script -- a crate's suite is one invocation and cannot be split.
mapfile -t SORTED < <(printf '%s\n' "${SELECTED[@]}" | sort -t$'\t' -k1,1nr -k2,2)
WORKERS=$(( JOBS * TASKS ))
i=0
for line in "${SORTED[@]}"; do
    crate="${line#*$'\t'}"
    w=$(( i % WORKERS ))
    printf '%s\n' "$crate" >> "$RUNDIR/chunks/chunk-$(( w % JOBS ))-$(( w / JOBS )).txt"
    i=$((i + 1))
done

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
    printf 'WARMUP=%q\n'           "$WARMUP"
    printf 'TEST_THREADS=%q\n'     "$TEST_THREADS"
    printf 'MAX_PRERUNS=%q\n'      "$MAX_PRERUNS"
    printf 'BSAN_OPTIONS_ALL=%q\n' "$BSAN_OPTIONS_ALL"
} > "$RUNDIR/config.env"

# ── inner.sh: runs INSIDE the container, once per crate, cwd = /work ─────────
# Fully quoted heredoc: everything resolves at run time from the HF_* env vars
# injected by the worker, so there is no nested-escaping to fight.
cat > "$RUNDIR/inner.sh" << 'INNER_EOF'
#!/bin/bash
# Compile the crate once, then time its WHOLE test list in a single concurrent
# `cargo bsan test` invocation. Streams one CSV row per crate (plus the
# calibration row) into this worker's shard.
#
# -f (noglob): test names are interpolated UNQUOTED into the pre-run command so
# the shell splits them into separate arguments, and a name containing a glob
# metacharacter must not then be matched against the crate directory.
set -uf

export BSAN_OPTIONS="$HF_BSAN_OPTIONS"
RUN="cargo bsan test --tests"

# --cfg=miri so this run selects the same cfg(miri) code and the same test set
# as the miri/per-test runs (#[cfg(not(miri))] compiled out, #[cfg_attr(miri,
# ignore)] ignored). --cap-lints=warn demotes the crate's own deny/forbid lints
# so a crate that would otherwise fail to build still compiles and gets timed.
# EXPORTED rather than prefixed onto $RUN because $RUN is handed to hyperfine,
# which runs with -N (no shell) -- a "VAR=value cmd" prefix would be taken as
# the program name there, not as an assignment.
export RUSTFLAGS="--cfg=miri --cap-lints=warn"
echo "RUSTFLAGS=[$RUSTFLAGS]"

# libtest's --test-threads is a HARNESS flag, so it goes after the `--`, before
# --exact. Unlike the per-test script this is never empty: running the tests
# concurrently is the whole measurement.
HARNESS="--test-threads=$HF_TEST_THREADS"
echo "HARNESS=[$HARNESS]"

FAIL_LOG_LINES=200

ts() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }
# `wc -l < f` pads its count on some platforms and these counts go into the
# CSV, so strip whitespace rather than ship " 5" as a field.
count_lines() { wc -l < "$1" | tr -d '[:space:]'; }
# row <test> <status> <compile> <mean> <stddev> <median> <min> <max>
#     <tests_requested> <tests_run> <excluded_failed>
row() {
    line="$HF_BUILD,$HF_CRATE,$1,$2,$3,$4,$5,$6,$7,$8,$HF_RUNS,$(ts),$HF_JOBID,$9,${10},$HF_TEST_THREADS,${11}"
    echo "$line" >> "$HF_SHARD"
    echo "CSVROW:$line"
}

LIST=$(mktemp)                      # the surviving (passing) test list
cp "$HF_TESTFILE" "$LIST"
NREQ=$(count_lines "$LIST")
EXCLUDED=0
NRUN=0

cargo clean >/dev/null 2>&1 || true
if ! cargo fetch; then
    row "__concurrent__" fetch_failed "" "" "" "" "" "" "$NREQ" 0 0
    exit 1
fi

cstart=$(date +%s%3N)
if ! $RUN --no-run; then
    row "__concurrent__" build_failed "" "" "" "" "" "" "$NREQ" 0 0
    exit 1
fi
cms=$(( $(date +%s%3N) - cstart ))
compile=$(printf '%d.%03d' $(( cms / 1000 )) $(( cms % 1000 )))

# --- Calibration: what an invocation costs before any test body runs --------
# The same command with a filter matching nothing still pays cargo's freshness
# check and starts every test binary in the crate, running zero tests -- i.e.
# exactly the constant the suite timing below also carries, but here paid ONCE
# for the crate rather than once per test. Written as its own row rather than
# subtracted, so the CSV keeps raw measurements.
CALIB_FILTER=__hyperfine_calibration_no_such_test__
hfcsv=$(mktemp)
if hyperfine --style basic -N --warmup "$HF_WARMUP" --runs "$HF_RUNS" \
        --export-csv "$hfcsv" "$RUN -- $HARNESS --exact $CALIB_FILTER"; then
    read -r cmean cstddev cmedian cmin cmax <<EOV
$(tail -n1 "$hfcsv" | awk -F, '{print $(NF-6), $(NF-5), $(NF-4), $(NF-1), $NF}')
EOV
    echo "calibration: $HF_CRATE -> ${cmedian}s per invocation (0 tests)"
    row "__calibration__" calibration "$compile" \
        "$cmean" "$cstddev" "$cmedian" "$cmin" "$cmax" 0 0 0
fi
rm -f "$hfcsv"

# --- Pre-run: warm caches, and drop whatever fails --------------------------
# hyperfine abandons a command that exits non-zero, so a single failing test
# would otherwise cost the crate its whole row. Each pass runs the current list
# untimed; on failure the names in libtest's `failures:` block are taken out
# and the pass repeats. Intersecting those names with the requested list means
# captured test output can never invent one.
#
# libtest prints two `failures:` blocks per binary: the first introduces the
# "---- <name> stdout ----" dumps (which do not match the indented-bare-name
# pattern, so the collector switches off again immediately), the second is the
# name list proper.
parse_failures() {
    awk '
        /^failures:[[:space:]]*$/ { inlist = 1; next }
        inlist && /^[[:space:]]+[^[:space:]]+[[:space:]]*$/ {
            gsub(/[[:space:]]/, "", $0); print; next
        }
        { inlist = 0 }
    ' "$1" | sort -u
}

prerun_ok=0
pass=0
while (( pass < HF_MAX_PRERUNS )); do
    pass=$(( pass + 1 ))
    nleft=$(count_lines "$LIST")
    (( nleft > 0 )) || break
    FILTERS=$(tr '\n' ' ' < "$LIST")
    runlog=$(mktemp)
    echo "pre-run pass $pass: $HF_CRATE, $nleft test(s), $HARNESS"
    $RUN -- $HARNESS --exact $FILTERS > "$runlog" 2>&1; rc=$?
    NRUN=$(grep -aoE '^running [0-9]+ test' "$runlog" | grep -oE '[0-9]+' \
           | awk '{s+=$1} END{print s+0}')
    if (( rc == 0 )); then
        prerun_ok=1
        rm -f "$runlog"
        break
    fi
    # The dropped tests' output -- the panic message, the BSAN report,
    # libtest's `failures:` summary -- exists nowhere else, so it goes in the
    # crate log. Tail, not head: the diagnosis is at the end, the head is
    # per-binary "running N tests" noise.
    nlines=$(count_lines "$runlog")
    echo "--- output: $HF_CRATE pass $pass (exit $rc, $NRUN test(s) ran) ---"
    if (( nlines > FAIL_LOG_LINES )); then
        echo "[... $(( nlines - FAIL_LOG_LINES )) earlier line(s) omitted ...]"
    fi
    tail -n "$FAIL_LOG_LINES" "$runlog"
    echo "--- end output: $HF_CRATE pass $pass ---"

    names=$(mktemp); confirmed=$(mktemp)
    parse_failures "$runlog" > "$names"
    grep -Fxf "$names" "$LIST" > "$confirmed" || true
    nfail=$(count_lines "$confirmed")
    rm -f "$runlog" "$names"
    if (( nfail == 0 )); then
        # Nothing attributable: a process abort (a BSAN report can take the
        # whole binary down, and with it every test in flight), a harness
        # error, a stale build. Dropping tests cannot fix that.
        echo "pre-run failed with no attributable test: $HF_CRATE"
        rm -f "$confirmed"
        row "__concurrent__" prerun_failed "$compile" "" "" "" "" "" \
            "$NREQ" "$NRUN" "$EXCLUDED"
        exit 1
    fi
    echo "dropping $nfail failing test(s) from $HF_CRATE:"
    sed 's/^/  /' "$confirmed"
    grep -Fxv -f "$confirmed" "$LIST" > "$LIST.next" || true
    mv "$LIST.next" "$LIST"
    EXCLUDED=$(( EXCLUDED + nfail ))
    rm -f "$confirmed"
done

nleft=$(count_lines "$LIST")
if (( nleft == 0 )); then
    row "__concurrent__" all_failed "$compile" "" "" "" "" "" "$NREQ" 0 "$EXCLUDED"
    exit 1
fi
if (( prerun_ok == 0 )); then
    echo "still failing after $HF_MAX_PRERUNS pre-run pass(es): $HF_CRATE"
    row "__concurrent__" prerun_failed "$compile" "" "" "" "" "" \
        "$NREQ" "$NRUN" "$EXCLUDED"
    exit 1
fi

# NRUN counts every "running N tests" line, so a name present in several
# binaries inflates it -- fewer tests run than asked for is the signal that
# matters: a stale test list, or a libtest too old to take more than one
# --exact filter (in which case NRUN collapses to ~1 and the row must not be
# read as a suite timing).
status=success
if (( NRUN < nleft )); then
    status=partial_match
    echo "WARNING: $HF_CRATE asked for $nleft test(s) but libtest ran $NRUN"
fi

# --- The measurement --------------------------------------------------------
FILTERS=$(tr '\n' ' ' < "$LIST")
hfcsv=$(mktemp)
if hyperfine --style basic -N --warmup "$HF_WARMUP" --runs "$HF_RUNS" \
        --export-csv "$hfcsv" "$RUN -- $HARNESS --exact $FILTERS"; then
    # Export columns are command,mean,stddev,median,user,system,min,max --
    # counted from the end so a comma in the command column cannot shift them.
    read -r mean stddev median minv maxv <<EOV
$(tail -n1 "$hfcsv" | awk -F, '{print $(NF-6), $(NF-5), $(NF-4), $(NF-1), $NF}')
EOV
    echo "result: $HF_CRATE -> $status (mean ${mean}s for $nleft test(s) on $HF_TEST_THREADS thread(s))"
    row "__concurrent__" "$status" "$compile" \
        "$mean" "$stddev" "$median" "$minv" "$maxv" "$NREQ" "$NRUN" "$EXCLUDED"
else
    echo "result: $HF_CRATE -> bench_failed"
    row "__concurrent__" bench_failed "$compile" "" "" "" "" "" \
        "$NREQ" "$NRUN" "$EXCLUDED"
fi
rm -f "$hfcsv" "$LIST"
INNER_EOF

# ── job.sh: the sbatch payload, one per node ─────────────────────────────────
# Also fully quoted: all configuration comes from config.env + its arguments
# (<rundir> <job index> [ntasks]). Launches the job's workers, each draining
# its own chunk file of crates and appending rows to its own shard (single
# writer per shard, so no locking anywhere).
cat > "$RUNDIR/job.sh" << 'JOB_EOF'
#!/bin/bash
set -u
RUNDIR="$1"
JOBIDX="$2"
source "$RUNDIR/config.env"
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
trap 'rm -rf "$SCRATCH_BASE/hfc-$SLURM_JOB_ID-"* 2>/dev/null || true' EXIT

worker() {
    local tid="$1"
    local chunk="$RUNDIR/chunks/chunk-${JOBIDX}-${tid}.txt"
    local shard="$RUNDIR/shards/shard-${JOBIDX}-${tid}.csv"
    [ -s "$chunk" ] || return 0
    local n k=0 crate log
    n=$(wc -l < "$chunk")
    while IFS= read -r crate; do
        [ -n "$crate" ] || continue
        k=$((k + 1))
        local cdir="$DATASET_DIR/$crate"
        local scr="$SCRATCH_BASE/hfc-${SLURM_JOB_ID}-${tid}"
        # -concurrent, so this never overwrites the per-test script's log.
        log="$cdir/hyperfine-${IMAGE}-concurrent.log"
        rm -rf "$scr"
        mkdir -p "$scr/home" "$scr/target"
        echo "[job $JOBIDX task $tid] ($k/$n) $crate"
        singularity exec --cleanenv --pwd /work \
            --bind "$scr" --bind "$RUNDIR" --bind "$cdir:/work" \
            --env CARGO_HOME="$scr/home" \
            --env CARGO_TARGET_DIR="$scr/target" \
            --env CARGO_BUILD_JOBS="$CPUS_PER_TASK" \
            --env HF_BUILD="$IMAGE" \
            --env HF_CRATE="$crate" \
            --env HF_TESTFILE="$RUNDIR/tests/$crate.txt" \
            --env HF_SHARD="$shard" \
            --env HF_RUNS="$RUNS" --env HF_WARMUP="$WARMUP" \
            --env HF_TEST_THREADS="$TEST_THREADS" \
            --env HF_MAX_PRERUNS="$MAX_PRERUNS" \
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
echo "Mode:     $MODE (concurrent suite per crate)   Image: $IMAGE"
echo "Dataset:  $DATASET_DIR"
echo "Tests:    $TOTAL_TESTS across ${#SELECTED[@]} crate(s) (from $TESTS_CSV)"
echo "Skipped:  ignored=$skip_ignored not-in-only=$skip_only ffi=$skip_ffi no-tests=$skip_empty missing-dir=${#MISSING[@]}"
(( skip_claimed > 0 )) && echo "          ($skip_claimed crate(s) had every test claimed by a slow/medium list)"
if (( ${#MISSING[@]} > 0 )); then
    printf '  missing from dataset: %s\n' "${MISSING[@]}" | head -20
fi
echo "Excluded: $(( n_slow + n_medium )) test(s) not run -- $n_slow slow, $n_medium medium"
if [[ -n "$SLOW_TESTS_FILE" ]]; then
    echo "          slow list:   $SLOW_TESTS_FILE"
    (( slow_skipped > 0 )) && echo "            ($slow_skipped entr(y/ies) skipped: crate not selected for this run)"
fi
if [[ -n "$MEDIUM_TESTS_FILE" ]]; then
    echo "          medium list: $MEDIUM_TESTS_FILE"
    (( medium_skipped > 0 )) && echo "            ($medium_skipped entr(y/ies) skipped: crate not selected for this run)"
fi
(( tl_dups > 0 )) && echo "          ($tl_dups duplicate list entr(y/ies) collapsed)"
echo "Shape:    $JOBS job(s) x up to $TASKS tasks x ${CPUS_PER_TASK} cpus, ${MEM_PER_TASK}G/task (<=${TOTAL_MEM}G/job), $WALLTIME each"
echo "          (one crate = one timed invocation; each job requests only the workers it holds)"
if (( JOBS > 40 )); then
    echo "WARNING:  $JOBS jobs exceeds the 40-job QOS limit; the extras will queue"
    echo "          until earlier ones finish (lower --jobs, or raise --max-tasks)."
fi
echo "Sampling: $RUNS runs, $WARMUP warmup per crate, --test-threads=$TEST_THREADS"
echo "          (plus up to $MAX_PRERUNS untimed pre-run pass(es) per crate)"
echo "BSAN_OPTIONS: $BSAN_OPTIONS_ALL"
echo "Results:  $CSV"
echo "Run dir:  $RUNDIR"
echo

# ── Submit one single-node sbatch job per chunked job index ──────────────────
JOBIDS=()
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
        --job-name="hfc-${IMAGE}-${DATASET}-${label}" \
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

cancel_jobs() {
    trap - INT TERM
    echo; echo "Cancelling jobs: ${JOBIDS[*]}"
    scancel "${JOBIDS[@]}" 2>/dev/null || true
    exit 130
}
trap cancel_jobs INT TERM

# ── Poll until every job leaves the queue, with a progress line ──────────────
# A crate contributes at most two rows (calibration + suite), so progress is
# counted in crates finished, not rows.
NCRATES=${#SELECTED[@]}
IDLIST=$(IFS=,; echo "${JOBIDS[*]}")
while :; do
    left=$(squeue -h -o '%T' -j "$IDLIST" 2>/dev/null | grep -c . || true)
    # The glob matches nothing until the first shard row lands, so the cat
    # (and the whole pipeline, under pipefail) must be allowed to fail.
    done_crates=$(cat "$RUNDIR"/shards/*.csv 2>/dev/null \
        | awk -F, '$3 != "__calibration__"' | wc -l || true)
    echo "$(date +%H:%M:%S)  jobs in queue: $left   crates finished: $done_crates/$NCRATES"
    (( left == 0 )) && break
    sleep 60
done
trap - INT TERM

# ── Merge shards into the master CSV and summarize ───────────────────────────
mkdir -p "$OUTPUTS_DIR"
if [[ ! -f "$CSV" ]]; then
    echo "build,crate,test,status,compile_seconds,mean_s,stddev_s,median_s,min_s,max_s,runs,timestamp,job_id,tests_requested,tests_run,test_threads,excluded_failed" > "$CSV"
fi
cat "$RUNDIR"/shards/*.csv >> "$CSV" 2>/dev/null || true

echo
echo "Done. Results CSV: $CSV"
# Status is field 4; test names contain '::' but never commas, so this is safe.
cat "$RUNDIR"/shards/*.csv 2>/dev/null | awk -F, '
    { c[$4]++; total++ }
    $3 == "__concurrent__" && $4 == "success" { ok++; secs += $6; ntests += $15 }
    $17 > 0 { dropped += $17 }
    END {
        for (s in c) printf "  %s: %d\n", s, c[s]
        printf "  total rows: %d\n", total + 0
        if (ok) printf "  timed suites: %d, %.0f tests, %.1fs of measured wall time\n", ok, ntests, secs
        if (dropped) printf "  tests dropped as failing: %d\n", dropped
    }' || true
done_crates=$(cat "$RUNDIR"/shards/*.csv 2>/dev/null \
    | awk -F, '$3 != "__calibration__"' | wc -l || true)
if (( done_crates < NCRATES )); then
    echo "  NOTE: fewer crate rows than crates -- workers killed by walltime. See the"
    echo "  crates' hyperfine-${IMAGE}-concurrent.log and $RUNDIR/job-*.out"
fi
