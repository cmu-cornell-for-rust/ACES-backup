#!/usr/bin/env bash
#
# Usage: run_eval_dataset.sh [options] <mode> <image> [walltime] <dataset> [extra]
#
#   <mode>      miri | bsan | rust -- which tool runs the tests:
#                 miri: MIRIFLAGS=<common+extra> cargo miri test
#                 bsan: BSAN_OPTIONS=<common+extra> cargo bsan test, with
#                       BSAN_SYMBOLIZER set (see below)
#                 rust: plain cargo test (extra ignored)
#   <image>     image/SIF name under the group containers dir (e.g. miri, bsan,
#               rust). Mode and image are separate so variant images can still
#               be driven in a given mode.
#   [walltime]  walltime per regular sbatch job, HH or HH:MM (default 4; the
#               slow-list jobs use --slow-walltime instead). (Recognized
#               positionally by shape, so a purely numeric dataset name would
#               need the walltime spelled out.)
#   <dataset>   folder under the group datasets dir holding crate subdirectories;
#               else a name with a <group>/scripts/<dataset>-dataset.csv (or
#               one next to this script), whose crates are downloaded instead
#               (see "No dataset dir" below).
#   [extra]     mode-specific extras: -Z Miri flags (miri) or colon-separated
#               BSAN_OPTIONS (bsan), appended to the built-in set.
#
# Options:
#   --ignore FILE     crate names to skip, one per line (#-comments ok)
#   --only FILE       run ONLY the crates listed in FILE (same format;
#                     --ignore/--safety still apply on top)
#   --first | --latest | --only-latest | --only-first
#                     only run the crate versions this selects from the
#                     versions CSV, as build_dataset.sh's flags do (via
#                     dataset_creator/select_versions.sh):
#                       --first        every crate at its first version
#                       --latest       every crate at its latest version
#                       --only-latest  crates whose latest version differs,
#                                      at the latest
#                       --only-first   crates whose latest version differs,
#                                      at the first (the --only-latest
#                                      crates' old versions)
#                     A filter on --tests, like --only: the tests CSV must
#                     name those versions (e.g. --only-latest with
#                     <dataset>-tests-latest.csv, --only-first with
#                     <dataset>-tests.csv). Default: no version filter
#   --versions-csv FILE  versions CSV for the flags above (update_latest.py's
#                     latest_version / version_differs columns). Default:
#                     <group>/scripts/<dataset>-dataset.csv
#   --safety LIST     only run crates whose unsafe-scan status is in LIST, a
#                     comma-separated subset of safe, unsafe-deps, unsafe (or
#                     the symbols :) ? !). Crates "unknown" or never scanned
#                     are skipped. See --unsafe-scan
#   --unsafe-scan FILE  unsafe_scan.csv from dataset_creator/filter_unsafe.sh.
#                     Default: <dataset dir>/_logs/unsafe_scan.csv
#   --tests FILE      REQUIRED. tests CSV: which crates to run, and which of
#                     their tests -- so it also picks the crate versions, e.g.
#                     <group>/scripts/<dataset>-tests.csv (first versions) or
#                     <dataset>-tests-latest.csv (build_dataset.sh --latest /
#                     --only-latest). Needs a crate column and a
#                     test or tests column, found by header name (else
#                     columns 1 and 2); either form works:
#                       crate,tests,...   ';'-joined names per crate, as
#                                         list_tests.sh / build_dataset.sh
#                                         write (first row per crate wins)
#                       ...,crate,test,...  one test per row, e.g. a previous
#                                         eval CSV filtered to the tests to
#                                         rerun (all rows count)
#                     Fields may be double-quoted; a UTF-8 BOM is ignored.
#   --skip-list FILE  (crate, test) pairs never to run, in any format --tests
#                     takes. Default: <group>/scripts/skip_list.csv, applied
#                     whenever it exists (tests known to hang or eat the
#                     walltime). A crate left with no tests is skipped
#   --no-skip-list    don't apply the default skip list
#   --bsan-build-fails FILE  skip the crates in FILE, a bsan-only CSV from
#                     build_dataset.sh (crates that build with plain cargo but
#                     not with cargo bsan; matched by crate column, version
#                     included). Repeatable; applies in any mode. Default, in
#                     bsan mode only: <group>/scripts/bsan_build_fails.csv, the
#                     list build_dataset.sh appends to, when it exists, so a
#                     bsan run doesn't spend a worker on a crate known not to
#                     build
#   --no-bsan-build-fails  don't apply the default bsan build-fail list
#   (slow list)       <group>/scripts/eval-slow-crates.csv, always applied when
#                     it exists: crate names, matched against any version
#                     (crate column, a version there is ignored; slowest
#                     first; any other columns are informational).
#                     Listed crates are pulled out of the test-count balancing
#                     and packed together into their own jobs, in list order,
#                     MAX_TASKS to a job -- so the long-running crates share a
#                     few nodes and the remaining jobs all finish early.
#   --slow-walltime T walltime for the slow-list jobs, HH or HH:MM (default 24)
#   --jobs N          sbatch jobs to spread the crates over, slow-list jobs
#                     included (default: one per crate, capped at --max-jobs;
#                     a run with more crates than --max-jobs x --max-tasks
#                     workers uses just enough full jobs instead, and the
#                     ones past --max-jobs are staged -- see below)
#   --max-jobs N      most of your jobs in SLURM at once, running + pending
#                     (default 90, the per-user submit limit); the rest are
#                     staged
#   --max-tasks N     ceiling on workers per job, at most 24 (default: 24, or
#                     fewer if 24 don't fit a 24-core / 488G slice of a node
#                     at --cpus-per-task and --mem-per-task)
#   --cpus-per-task N cores per worker (default 1; also caps CARGO_BUILD_JOBS)
#   --mem-per-task G  GB per worker (default 8, at most 16); a hard cap: each
#                     crate runs as its own srun step with --mem=G
#   --merge RUNDIR    don't run anything: merge RUNDIR's shards into its master
#                     CSV (see the end of this comment) and print the summary
#   --test-threads N  pass `--test-threads=N` to the test harness on every run
# Environment:
#   BSAN_SYMBOLIZER   llvm-symbolizer path inside the image, so BSAN reports
#                     carry source locations (bsan mode). Default:
#                     /root/.rustup/toolchains/bsan/bin/llvm-symbolizer
#
#   --test-timeout T  time limit per test invocation, in any form coreutils
#                     `timeout` accepts (e.g. 300, 90s, 10m, 1.5h); a test that
#                     hits it is recorded as `timeout`. Default 30m; 0 turns it
#                     off. Without one, a test that hangs holds its worker --
#                     and every crate still queued behind it -- until walltime.
#
# How it differs from run_bench_dataset.sh
# ----------------------------------------
# * Like run_bench_dataset.sh, the crates and tests come from the tests CSV
#   (--tests, see above), not from listing on the node: each crate runs
#   exactly the tests named there, in file order. Crates must also have a dir
#   in the dataset; ones with no tests named are skipped. --ignore/--only/
#   --safety filter the CSV's crates.
# * No hyperfine: like run_bsan_dataset.sh, each phase is ONE invocation timed
#   with `date +%s%3N` around it. Each test is run exactly once -- no pre-run,
#   no warmup, no repeats -- and that run both classifies and times it.
# * No slowlist / test-level lists: the crates are dealt over the jobs by test
#   count (biggest crate first, to the job with the fewest tests so far; a
#   crate is never split), and every crate gets a worker of its own -- a job
#   holds at most --max-tasks crates, and a run with more crates than an
#   explicit --jobs x workers is refused. The workers still pull from the
#   job's queue, but with one crate per worker each pulls exactly one.
# * At most --max-jobs (default 90) jobs per user sit in SLURM at once (running + pending, counting
#   the user's other jobs too). Jobs past that are staged by this script and
#   submitted as earlier ones leave the queue, so the script must keep running
#   (use tmux/screen) until every job has been submitted.
#
# No dataset dir
# --------------
# When <dataset> has no dir under the datasets dir but has a versions CSV
# (<group>/scripts/<dataset>-dataset.csv, else next to this script), each
# worker downloads its crate's crates.io tarball straight into its node-local
# scratch ($TMPDIR, next to the crate's CARGO_TARGET_DIR) in place of copying
# it from the dataset, and deletes it with the target dir once the crate is
# done -- one crate on disk per worker at a time. The crates (and versions)
# are still the --tests CSV's; the versions CSV only stands in for the dataset
# (and is the default --versions-csv). A failed download is a fetch_failed
# row. Each crate's eval-<image>.log, which would live in its dataset dir,
# goes to <rundir>/crate-logs/<crate>/ instead. --safety needs --unsafe-scan
# here, as there is no <dataset dir>/_logs/unsafe_scan.csv.
#
# Every mode compiles with --cfg=miri and RUSTFLAGS="--cap-lints=warn", so all
# three select the same cfg(miri) code and test set, and a crate's own
# deny/forbid lints don't fail the build. Unlike run_bench_dataset.sh, rust and
# bsan mode put --cfg=miri on the crate under test only (rustc-cfg-miri.sh), as
# build_dataset.sh does, so dependencies that call Miri-only fns under
# cfg(miri) still link.
#
# Per crate, inside the container:
#   fetch         cargo fetch                                  (fetch_failed)
#   compile       cargo <tool> test --tests --no-run, timed    (build_failed)
#   per test      cargo <tool> test --tests -- --exact <test>, timed once
#                 (a doc:<...> test, from a --doc listing: cargo <tool> test --doc
#                 -- <filter> --skip <skip>..., see inner.sh)
#
# Rows are STREAMED into a per-worker shard CSV as each test finishes (single
# writer per shard; a walltime kill loses only the in-flight test):
#
#   build,crate,test,status,compile_seconds,run_seconds,timestamp,job_id,
#   error_type,error
#
# status: success, test_failed (exited non-zero), no_match (the filter ran 0
# tests), timeout (hit --test-timeout), skipped (not run: an earlier 5 tests
# in a row in its module timed out; error_type timeout, run_seconds empty),
# killed (no row before the crate's srun step was killed -- usually OOM past
# --mem-per-task, error_type oom; compile/run_seconds empty), and test-less
# crate rows:
# fetch_failed, build_failed. run_seconds is the wall time of the test's single invocation,
# including cargo's freshness check and every test binary's startup.
#
# error_type/error are set on every row whose command exited non-zero, with
# the same patterns, in the same first-match order, as run_bench_dataset.sh
# and analysis/failure_logs.py:
#   rustc   error[E<code>]                    (compile error)
#   linker  rust-lld
#   oom     SIGKILL
#   gc      ERROR: BorrowSanitizer: garbage collection
#   crash   BorrowSanitizer:DEADLYSIGNAL
#   bsan    error: Undefined Behavior:        (BSAN/Miri UB report)
#   panic   panicked at                       (ordinary test failure)
#   other   none of the above
#   timeout set on every status=timeout row instead of the above, with error
#           "test timed out after <T> (--test-timeout; killed by SIGTERM|SIGKILL)"
# error is the matching line (for panic, plus the message line after it; for
# other, the last error:/non-empty line), one line, at most 300 chars,
# double-quoted. For bsan it is instead the whole UB report, from the
# "error: Undefined Behavior:" line through cargo's "error: test failed, ..."
# line (at most BSAN_REPORT_LINES lines of at most BSAN_LINE_CHARS chars,
# BSAN_REPORT_CHARS chars in all), with each line break written as a
# literal \n so the row stays on one line. The full output of every failing / no_match test (last 200
# lines) is written to <crate>/eval-<image>.log between
# "--- output: <crate> :: <test> ..." markers.
#
# The orchestrator submits the jobs, polls squeue with a progress line, then
# merges the shards into <outputs>/<image>[-<extra-slug>]-<tests>-eval.csv
# (<tests>: the --tests file's name, see "Master CSV" below)
# and prints a status breakdown. Queues/shards/job logs live under
# <outputs>/eval-runs/<runid>/. If this script is killed the jobs keep running
# (Ctrl-C cancels them first). The shards are merged whenever the
# orchestrator exits -- done, Ctrl-C, hangup, error -- and merging only adds
# rows the master CSV doesn't already have, so it's safe to repeat. If the
# orchestrator was killed outright (SIGKILL, node reboot), merge by hand:
#   run_eval_dataset.sh --merge <rundir>
# which appends the run's missing rows to the master CSV it was writing.
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
    echo "Error: this script needs bash >= 4 (have $BASH_VERSION)." >&2
    exit 1
fi

# ── Layout (all absolute, so this can be run from anywhere) ───────────────────
GROUP="/scratch/group/p.cis260229.000"
CONTAINERS_DIR="$GROUP/containers"
DATASETS_ROOT="$GROUP/datasets"
OUTPUTS_DIR="$GROUP/outputs"

# Node slice a job may ask for (a hard cap of 24 cpus per job), the
# per-worker memory ceiling, the most workers per job, and the most jobs the
# user may have in SLURM at once (the rest are staged; --max-jobs overrides).
NODE_CPUS=24
NODE_MEM=488
MAX_MEM_PER_TASK=16
MAX_TASKS_PER_JOB=24
MAX_JOBS=90

# Built-in per-mode option sets (Miri's same as run_bench_dataset.sh; BSAN's
# stack traces are shorter here, since the whole report goes in the CSV).
MIRI_COMMON="-Zmiri-disable-alignment-check -Zmiri-disable-data-race-detector -Zmiri-ignore-leaks -Zmiri-tree-borrows"
BSAN_COMMON="stacktrace_max_len=10"
BSAN_SYMBOLIZER="${BSAN_SYMBOLIZER:-/root/.rustup/toolchains/bsan/bin/llvm-symbolizer}"

# ── Options ──────────────────────────────────────────────────────────────────
IGNORE_FILE=""
ONLY_FILE=""
VERSIONS=""          # first | latest | only-latest | only-first; empty = no version filter
VERSIONS_CSV=""
SAFETY=""
UNSAFE_SCAN=""
TESTS_CSV=""
SKIP_CSV=""
NO_SKIP=0
BSAN_FAIL_CSVS=()
NO_BSAN_FAILS=0
JOBS=""              # empty = auto: one per crate, capped at MAX_JOBS unless more are needed
MAX_TASKS=""         # empty = auto: what fits NODE_CPUS / NODE_MEM
CPUS_PER_TASK=1
MEM_PER_TASK=8
TEST_THREADS=""
TEST_TIMEOUT="30m"    # 0 = no limit
WALLTIME_ARG=4
SLOW_WALLTIME_ARG=24

# ── Shard merging (end of a run, or --merge) ─────────────────────────────────
HEADER="build,crate,test,status,compile_seconds,run_seconds,timestamp,job_id,error_type,error"
# merge_shards <rundir> <csv>: append the shard rows <csv> doesn't have yet
# (whole-line match, so a repeat merge adds nothing), creating it with the
# header if needed. Prints how many rows it added.
merge_shards() {
    local rundir="$1" csv="$2" added
    mkdir -p "$(dirname "$csv")"
    [[ -s "$csv" ]] || echo "$HEADER" > "$csv"
    added=$({ cat "$rundir"/shards/*.csv 2>/dev/null || true; } \
        | awk 'NR == FNR { have[$0] = 1; next } !($0 in have) { have[$0] = 1; print }' "$csv" - \
        | tee -a "$csv" | wc -l | tr -d ' ')
    echo "Merged $added new row(s) from $rundir/shards into $csv"
}
# summarize_run <rundir> <ncrates>: status counts of the run's rows, and the
# crates it never finished.
summarize_run() {
    local rundir="$1" ncrates="$2" done_crates
    # Status is field 4; test names never contain commas, and the only quoted
    # field (error) comes after it.
    cat "$rundir"/shards/*.csv 2>/dev/null | awk -F, '
        { c[$4]++; total++ }
        END {
            for (s in c) printf "  %s: %d\n", s, c[s]
            printf "  total rows: %d\n", total + 0
        }' || true
    done_crates=$(cat "$rundir"/done/*.txt 2>/dev/null | wc -l || true)
    if (( done_crates < ncrates )); then
        echo "  NOTE: $(( ncrates - done_crates )) crate(s) never finished (walltime / job failure)."
        echo "  Re-run them with --only: comm -23 <(sort $rundir/queues/*.txt) <(sort $rundir/done/*.txt)"
        echo "  See $rundir/job-*.out and the crates' eval-<image>.log"
    fi
}

MERGE_DIR=""
POS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i|--ignore)     IGNORE_FILE="$2"; shift 2 ;;
        --ignore=*)      IGNORE_FILE="${1#*=}"; shift ;;
        --only)          ONLY_FILE="$2"; shift 2 ;;
        --only=*)        ONLY_FILE="${1#*=}"; shift ;;
        --first|--latest|--only-latest|--only-first)
                         [[ -z "$VERSIONS" || "$VERSIONS" == "${1#--}" ]] \
                             || { echo "Error: --$VERSIONS and $1 are mutually exclusive." >&2; exit 1; }
                         VERSIONS="${1#--}"; shift ;;
        --versions-csv)  VERSIONS_CSV="$2"; shift 2 ;;
        --versions-csv=*) VERSIONS_CSV="${1#*=}"; shift ;;
        --safety)        SAFETY="$2"; shift 2 ;;
        --safety=*)      SAFETY="${1#*=}"; shift ;;
        --unsafe-scan)   UNSAFE_SCAN="$2"; shift 2 ;;
        --unsafe-scan=*) UNSAFE_SCAN="${1#*=}"; shift ;;
        --skip-list)     SKIP_CSV="$2"; shift 2 ;;
        --skip-list=*)   SKIP_CSV="${1#*=}"; shift ;;
        --no-skip-list)  NO_SKIP=1; shift ;;
        --bsan-build-fails)   BSAN_FAIL_CSVS+=("$2"); shift 2 ;;
        --bsan-build-fails=*) BSAN_FAIL_CSVS+=("${1#*=}"); shift ;;
        --no-bsan-build-fails) NO_BSAN_FAILS=1; shift ;;
        --tests)         TESTS_CSV="$2"; shift 2 ;;
        --tests=*)       TESTS_CSV="${1#*=}"; shift ;;
        --jobs)          JOBS="$2"; shift 2 ;;
        --jobs=*)        JOBS="${1#*=}"; shift ;;
        --max-jobs)      MAX_JOBS="$2"; shift 2 ;;
        --max-jobs=*)    MAX_JOBS="${1#*=}"; shift ;;
        --max-tasks)     MAX_TASKS="$2"; shift 2 ;;
        --max-tasks=*)   MAX_TASKS="${1#*=}"; shift ;;
        --cpus-per-task) CPUS_PER_TASK="$2"; shift 2 ;;
        --cpus-per-task=*) CPUS_PER_TASK="${1#*=}"; shift ;;
        --mem-per-task)  MEM_PER_TASK="$2"; shift 2 ;;
        --mem-per-task=*) MEM_PER_TASK="${1#*=}"; shift ;;
        --merge)         MERGE_DIR="$2"; shift 2 ;;
        --merge=*)       MERGE_DIR="${1#*=}"; shift ;;
        --test-threads)  TEST_THREADS="$2"; shift 2 ;;
        --test-threads=*) TEST_THREADS="${1#*=}"; shift ;;
        --slow-walltime) SLOW_WALLTIME_ARG="$2"; shift 2 ;;
        --slow-walltime=*) SLOW_WALLTIME_ARG="${1#*=}"; shift ;;
        --test-timeout)  TEST_TIMEOUT="$2"; shift 2 ;;
        --test-timeout=*) TEST_TIMEOUT="${1#*=}"; shift ;;
        -*)
            echo "Error: unknown option '$1'." >&2; exit 1 ;;
        *)
            POS+=("$1"); shift ;;
    esac
done
set -- ${POS[@]+"${POS[@]}"}

# --merge RUNDIR: the master CSV comes from the run's config.env (MASTER_CSV;
# runs from before it was recorded: <outputs>/<image>-<dataset>-eval.csv).
if [[ -n "$MERGE_DIR" ]]; then
    MERGE_DIR="${MERGE_DIR%/}"
    [[ -f "$MERGE_DIR/config.env" ]] || { echo "Error: $MERGE_DIR/config.env not found -- not an eval run dir?" >&2; exit 1; }
    MASTER_CSV=""
    # shellcheck disable=SC1091
    source "$MERGE_DIR/config.env"
    [[ -n "$MASTER_CSV" ]] || MASTER_CSV="$OUTPUTS_DIR/${IMAGE}-$(basename "$DATASET_DIR")-eval.csv"
    merge_shards "$MERGE_DIR" "$MASTER_CSV"
    summarize_run "$MERGE_DIR" "$(cat "$MERGE_DIR"/queues/*.txt 2>/dev/null | wc -l)"
    exit 0
fi

usage() {
    echo "Usage: $0 [options] <mode> <image> [walltime] <dataset> [extra]" >&2
    echo "  <mode>      miri | bsan | rust" >&2
    echo "  <image>     image/SIF name under $CONTAINERS_DIR" >&2
    echo "  [walltime]  per-job walltime, HH or HH:MM (default 4; slow-list jobs: --slow-walltime)" >&2
    echo "  <dataset>   folder under $DATASETS_ROOT, or a name with a <dataset>-dataset.csv (downloaded)" >&2
    echo "  [extra]     extra MIRIFLAGS (miri) or BSAN_OPTIONS (bsan)" >&2
    echo "  options: --ignore FILE --only FILE" >&2
    echo "           --first | --latest | --only-latest | --only-first [--versions-csv FILE]" >&2
    echo "           --safety safe,unsafe-deps,unsafe [--unsafe-scan FILE]" >&2
    echo "           --tests FILE (required; e.g. $GROUP/scripts/<dataset>-tests.csv)" >&2
    echo "           --skip-list FILE (default $GROUP/scripts/skip_list.csv) | --no-skip-list" >&2
    echo "           --bsan-build-fails FILE (repeatable; default in bsan mode:" >&2
    echo "             $GROUP/scripts/bsan_build_fails.csv) | --no-bsan-build-fails" >&2
    echo "           --jobs N --max-jobs N (default 90) --max-tasks N (<= $MAX_TASKS_PER_JOB) --cpus-per-task N" >&2
    echo "           --mem-per-task G (<= $MAX_MEM_PER_TASK)" >&2
    echo "           --test-threads N --test-timeout T (per-test limit, e.g. 10m; default 30m, 0 = none)" >&2
    echo "           --slow-walltime T (slow-list jobs, HH or HH:MM; default 24)" >&2
    exit 1
}
[[ $# -ge 3 && $# -le 5 ]] || usage

MODE="$1"
IMAGE_ARG="$2"
shift 2
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

parse_walltime() {
    if [[ "$1" =~ ^([0-9]{1,3})$ ]]; then
        printf '%02d:00:00' "$((10#${BASH_REMATCH[1]}))"
    elif [[ "$1" =~ ^([0-9]{1,3}):([0-9]{2})$ ]]; then
        local h=$((10#${BASH_REMATCH[1]})) m=$((10#${BASH_REMATCH[2]}))
        (( m <= 59 )) || { echo "Error: minutes must be 00-59 (got '$1')." >&2; exit 1; }
        printf '%02d:%02d:00' "$h" "$m"
    else
        echo "Error: walltime must be HH or HH:MM (e.g. 48 or 8:30; got '$1')." >&2
        exit 1
    fi
}
WALLTIME=$(parse_walltime "$WALLTIME_ARG")
SLOW_WALLTIME=$(parse_walltime "$SLOW_WALLTIME_ARG")

MEM_PER_TASK="${MEM_PER_TASK%G}"
for v in CPUS_PER_TASK MEM_PER_TASK MAX_JOBS; do
    [[ "${!v}" =~ ^[1-9][0-9]*$ ]] || { echo "Error: $v must be a positive integer." >&2; exit 1; }
done
(( MEM_PER_TASK <= MAX_MEM_PER_TASK )) \
    || { echo "Error: --mem-per-task is at most ${MAX_MEM_PER_TASK}G (got ${MEM_PER_TASK}G)." >&2; exit 1; }
(( CPUS_PER_TASK <= NODE_CPUS )) \
    || { echo "Error: --cpus-per-task is at most $NODE_CPUS." >&2; exit 1; }
if [[ -n "$JOBS" ]]; then
    [[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo "Error: --jobs must be a positive integer." >&2; exit 1; }
fi
# The largest worker count a job may hold at this cpu/mem per worker.
FIT_TASKS=$(( NODE_CPUS / CPUS_PER_TASK ))
(( NODE_MEM / MEM_PER_TASK < FIT_TASKS )) && FIT_TASKS=$(( NODE_MEM / MEM_PER_TASK ))
(( FIT_TASKS > MAX_TASKS_PER_JOB )) && FIT_TASKS=$MAX_TASKS_PER_JOB
if [[ -n "$MAX_TASKS" ]]; then
    [[ "$MAX_TASKS" =~ ^[1-9][0-9]*$ ]] || { echo "Error: --max-tasks must be a positive integer." >&2; exit 1; }
    (( MAX_TASKS <= FIT_TASKS )) || {
        echo "Error: --max-tasks $MAX_TASKS needs $(( MAX_TASKS * CPUS_PER_TASK )) cpus / $(( MAX_TASKS * MEM_PER_TASK ))G;" >&2
        echo "a job may use at most $NODE_CPUS cpus / ${NODE_MEM}G and $MAX_TASKS_PER_JOB workers, i.e. $FIT_TASKS workers here." >&2
        exit 1
    }
else
    MAX_TASKS=$FIT_TASKS
fi
if [[ -n "$TEST_THREADS" ]]; then
    [[ "$TEST_THREADS" =~ ^[1-9][0-9]*$ ]] \
        || { echo "Error: --test-threads must be a positive integer (got '$TEST_THREADS')." >&2; exit 1; }
fi
# 0 (in any unit) turns the limit off.
[[ "$TEST_TIMEOUT" =~ ^[0.]+[smhd]?$ ]] && TEST_TIMEOUT=""
if [[ -n "$TEST_TIMEOUT" ]]; then
    [[ "$TEST_TIMEOUT" =~ ^([0-9]+(\.[0-9]+)?|\.[0-9]+)[smhd]?$ && ! "$TEST_TIMEOUT" =~ ^[0.]+[smhd]?$ ]] \
        || { echo "Error: --test-timeout must be a positive duration like 300, 90s, 10m or 1.5h (got '$TEST_TIMEOUT')." >&2; exit 1; }
fi

IMAGE="$(basename "${IMAGE_ARG%.sif}")"
SIF_ABS="$CONTAINERS_DIR/$IMAGE.sif"
DATASET_DIR="$DATASETS_ROOT/$DATASET"
# No dataset dir: download the crates on the nodes (see "No dataset dir").
DOWNLOAD=0
DS_CSV=""
if [[ ! -d "$DATASET_DIR" ]]; then
    for _f in "$GROUP/scripts/$DATASET-dataset.csv" \
              "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$DATASET-dataset.csv"; do
        [[ -f "$_f" ]] && { DS_CSV="$_f"; break; }
    done
    [[ -n "$DS_CSV" ]] && DOWNLOAD=1
fi

MIRIFLAGS_ALL=""
BSAN_OPTIONS_ALL=""
case "$MODE" in
    miri) MIRIFLAGS_ALL="$MIRI_COMMON${EXTRA:+ $EXTRA}" ;;
    bsan) BSAN_OPTIONS_ALL="$BSAN_COMMON${EXTRA:+:$EXTRA}" ;;
esac

# Master CSV: <image>[-<slug>]-<tests>-eval.csv -- <image> the container build
# (SIF name), <tests> the --tests file's name minus .csv and its "-tests" /
# "tests-" part (mirilli-tests.csv -> mirilli, mirilli-tests-latest.csv ->
# mirilli-latest), so each tests list gets its own file. Slug as in the other
# run_* scripts, so different flag sets land in different files.
TESTS_NAME="$(basename "${TESTS_CSV:-$DATASET}" .csv)"
TESTS_NAME="${TESTS_NAME/-tests/}"; TESTS_NAME="${TESTS_NAME#tests-}"
CSV="$OUTPUTS_DIR/${IMAGE}-${TESTS_NAME}-eval.csv"
SLUG=""
if [[ -n "$EXTRA" && "$MODE" != "rust" ]]; then
    SLUG="$(printf '%s' "$EXTRA" | tr -c '[:alnum:]' '-' | sed 's/-\{1,\}/-/g; s/^-//; s/-$//')"
fi
[[ -n "$TEST_THREADS" ]] && SLUG="${SLUG:+$SLUG-}tt${TEST_THREADS}"
[[ -n "$SLUG" ]] && CSV="$OUTPUTS_DIR/${IMAGE}-${SLUG}-${TESTS_NAME}-eval.csv"

# ── Validate ──────────────────────────────────────────────────────────────--
[[ -f "$SIF_ABS" ]]    || { echo "Error: image not found at $SIF_ABS" >&2; exit 1; }
[[ -d "$DATASET_DIR" || "$DOWNLOAD" == 1 ]] \
    || { echo "Error: dataset dir not found: $DATASET_DIR (and no $DATASET-dataset.csv to download it from)" >&2; exit 1; }
command -v sbatch >/dev/null || { echo "Error: sbatch not found (run on a login node)." >&2; exit 1; }

[[ -n "$TESTS_CSV" ]] || {
    echo "Error: --tests FILE is required: the tests CSV naming the crates (<name>-<version> dirs) and tests to run," >&2
    echo "  e.g. --tests $GROUP/scripts/${DATASET}-tests.csv (first versions) or" >&2
    echo "  $GROUP/scripts/${DATASET}-tests-latest.csv (build_dataset.sh --latest / --only-latest)." >&2
    exit 1
}
[[ -f "$TESTS_CSV" ]] || {
    echo "Error: tests CSV not found: $TESTS_CSV" >&2
    echo "  (pass --tests FILE; build_dataset.sh writes <dataset>_list.csv, list_tests.sh tests-<dataset>.csv)" >&2
    exit 1
}
# Skip list: an explicit one must exist; the default is used if it's there.
if (( NO_SKIP )); then
    SKIP_CSV=""
elif [[ -n "$SKIP_CSV" ]]; then
    [[ -f "$SKIP_CSV" ]] || { echo "Error: skip list not found: $SKIP_CSV" >&2; exit 1; }
else
    SKIP_CSV="$GROUP/scripts/skip_list.csv"
    [[ -f "$SKIP_CSV" ]] || SKIP_CSV=""
fi
SLOW_CSV="$GROUP/scripts/eval-slow-crates.csv"
if [[ ! -f "$SLOW_CSV" ]]; then
    echo "Warning: slow list $SLOW_CSV not found; slow crates will not be grouped." >&2
    SLOW_CSV=""
fi

# ── Crate filters ────────────────────────────────────────────────────────────
read_name_list() {   # <file> <assoc array name>
    local -n _set="$2"
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"; line="${line//[[:space:]]/}"
        [[ -n "$line" ]] && _set["$line"]=1
    done < "$1"
}
declare -A IGNORE=()
if [[ -n "$IGNORE_FILE" ]]; then
    [[ -f "$IGNORE_FILE" ]] || { echo "Error: ignorelist not found: $IGNORE_FILE" >&2; exit 1; }
    read_name_list "$IGNORE_FILE" IGNORE
fi
# Bsan build fails: crates build_dataset.sh found to build with plain cargo but
# not with cargo bsan. Explicit lists must exist; the default is used if found.
declare -A BSAN_FAIL=()
if (( NO_BSAN_FAILS )); then
    BSAN_FAIL_CSVS=()
elif (( ${#BSAN_FAIL_CSVS[@]} > 0 )); then
    for _f in "${BSAN_FAIL_CSVS[@]}"; do
        [[ -f "$_f" ]] || { echo "Error: bsan build-fail list not found: $_f" >&2; exit 1; }
    done
elif [[ "$MODE" == bsan && -f "$GROUP/scripts/bsan_build_fails.csv" ]]; then
    BSAN_FAIL_CSVS=("$GROUP/scripts/bsan_build_fails.csv")
fi
for _f in ${BSAN_FAIL_CSVS[@]+"${BSAN_FAIL_CSVS[@]}"}; do
    # build,crate,...: the crate is field 2 (a name-version, never quoted).
    while IFS=, read -r _ _crate _; do
        [[ -n "$_crate" && "$_crate" != crate ]] && BSAN_FAIL["$_crate"]=1
    done < "$_f"
done
declare -A ONLY=()
if [[ -n "$ONLY_FILE" ]]; then
    [[ -f "$ONLY_FILE" ]] || { echo "Error: --only list not found: $ONLY_FILE" >&2; exit 1; }
    read_name_list "$ONLY_FILE" ONLY
    (( ${#ONLY[@]} > 0 )) || { echo "Error: --only list $ONLY_FILE is empty." >&2; exit 1; }
fi

# Version flags: VERSION_OK holds the <name>-<version> dirs select_versions.sh
# keeps from the versions CSV.
declare -A VERSION_OK=()
if [[ -n "$VERSIONS" ]]; then
    [[ -n "$VERSIONS_CSV" ]] || VERSIONS_CSV="${DS_CSV:-$GROUP/scripts/$(basename "$DATASET_DIR")-dataset.csv}"
    [[ -f "$VERSIONS_CSV" ]] \
        || { echo "Error: --$VERSIONS needs a versions CSV; $VERSIONS_CSV not found (pass --versions-csv FILE)." >&2; exit 1; }
    _selected=$("$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dataset_creator/select_versions.sh" \
        "$VERSIONS" "$VERSIONS_CSV") || exit 1
    while IFS= read -r _dir; do [[ -n "$_dir" ]] && VERSION_OK["$_dir"]=1; done <<<"$_selected"
fi

# --safety: unsafe_scan.csv (from filter_unsafe.sh, fields double-quoted) maps
# crate -> !/?/:)/unknown; WANT_STATUS holds the statuses selected.
declare -A SAFETY_OF=()
declare -A WANT_STATUS=()
if [[ -n "$SAFETY" ]]; then
    IFS=, read -ra _classes <<<"$SAFETY"
    for c in "${_classes[@]}"; do
        case "$c" in
            unsafe|'!')       WANT_STATUS['!']=1 ;;
            unsafe-deps|'?')  WANT_STATUS['?']=1 ;;
            safe|':)')        WANT_STATUS[':)']=1 ;;
            *) echo "Error: --safety takes a comma-separated list of safe, unsafe-deps, unsafe (got '$c')." >&2; exit 1 ;;
        esac
    done
    [[ -n "$UNSAFE_SCAN" ]] || UNSAFE_SCAN="$DATASET_DIR/_logs/unsafe_scan.csv"
    [[ -f "$UNSAFE_SCAN" ]] \
        || { echo "Error: unsafe scan not found: $UNSAFE_SCAN (run dataset_creator/filter_unsafe.sh, or --unsafe-scan FILE)" >&2; exit 1; }
    while IFS=, read -r crate found _ || [[ -n "$crate" ]]; do
        crate="${crate//\"/}"; found="${found//\"/}"; found="${found//$'\r'/}"
        [[ -n "$crate" && "$crate" != "crate" ]] || continue
        SAFETY_OF["$crate"]="$found"
    done < "$UNSAFE_SCAN"
    (( ${#SAFETY_OF[@]} > 0 )) || { echo "Error: unsafe scan $UNSAFE_SCAN has no rows." >&2; exit 1; }
fi

# ── Select crates and tests from the tests CSV ───────────────────────────────
# parse_tests_csv <file>: one "crate<TAB>test" line per (crate, test), in file
# order, deduplicated. Columns by header name -- crate, and test (one per row,
# every row counts) or tests (';'-joined, first row per crate wins) -- else
# columns 1 and 2 as crate,tests. Fields may be double-quoted (with "" for a
# quote, but not spanning lines).
parse_tests_csv() {
    LC_ALL=C awk '
        function splitcsv(line, f,    n, i, c, q, cur) {
            n = 0; cur = ""; q = 0
            for (i = 1; i <= length(line); i++) {
                c = substr(line, i, 1)
                if (q) {
                    if (c == "\"") {
                        if (substr(line, i + 1, 1) == "\"") { cur = cur "\""; i++ } else q = 0
                    } else cur = cur c
                } else if (c == "\"") q = 1
                else if (c == ",") { f[++n] = cur; cur = "" }
                else cur = cur c
            }
            f[++n] = cur
            return n
        }
        function trim(x) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", x); return x }
        BEGIN { bom = sprintf("%c%c%c", 239, 187, 191); cc = 1; tc = 2; per_row = 0 }
        {
            line = $0
            sub(/\r$/, "", line)
            if (NR == 1 && index(line, bom) == 1) line = substr(line, 4)
            n = splitcsv(line, f)
            if (NR == 1) {
                hc = 0; ht = 0
                for (i = 1; i <= n; i++) {
                    h = tolower(trim(f[i]))
                    if (h == "crate" && !hc) hc = i
                    else if (h == "test" && !ht) { ht = i; per_row = 1 }
                    else if (h == "tests" && !ht) ht = i
                }
                if (hc) { cc = hc; if (ht) tc = ht; else tc = 0; next }
            }
            if (!tc) next
            crate = trim(f[cc]); tests = trim(f[tc])
            if (crate == "" || tests == "") next
            if (!per_row) { if (crate in done) next; done[crate] = 1 }
            k = split(tests, t, ";")
            for (j = 1; j <= k; j++) {
                t[j] = trim(t[j])
                if (t[j] != "" && !seen[crate SUBSEP t[j]]++) printf "%s\t%s\n", crate, t[j]
            }
        }' "$1"
}

RUNDIR="$OUTPUTS_DIR/eval-runs/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$RUNDIR/queues" "$RUNDIR/shards" "$RUNDIR/done" "$RUNDIR/lists"

# Each crate's tests go to $RUNDIR/lists/<crate>.txt, one per line, which the
# worker runs in that order. KEEP caches each crate's verdict (1 = run it).
CRATES=()
declare -A KEEP=()
declare -A NT=()          # tests per kept crate
declare -A SKIP=()        # "crate<TAB>test" pairs from the skip list
if [[ -n "$SKIP_CSV" ]]; then
    while IFS= read -r pair; do SKIP["$pair"]=1; done < <(parse_tests_csv "$SKIP_CSV")
fi
MISSING=()
skip_ignored=0; skip_bsanfail=0; skip_only=0; skip_version=0; skip_safety=0; skip_tests=0; NTESTS=0
while IFS=$'\t' read -r crate test; do
    if [[ -z "${KEEP[$crate]+x}" ]]; then
        KEEP[$crate]=0
        if [[ -n "${IGNORE[$crate]:-}" ]]; then skip_ignored=$((skip_ignored+1))
        elif [[ -n "${BSAN_FAIL[$crate]:-}" ]]; then skip_bsanfail=$((skip_bsanfail+1))
        elif (( ${#ONLY[@]} > 0 )) && [[ -z "${ONLY[$crate]:-}" ]]; then skip_only=$((skip_only+1))
        elif [[ -n "$VERSIONS" && -z "${VERSION_OK[$crate]:-}" ]]; then skip_version=$((skip_version+1))
        elif [[ -n "$SAFETY" && -z "${WANT_STATUS[${SAFETY_OF[$crate]:-unknown}]:-}" ]]; then skip_safety=$((skip_safety+1))
        elif [[ "$DOWNLOAD" == 0 && ! -f "$DATASET_DIR/$crate/Cargo.toml" ]]; then MISSING+=("$crate")
        else KEEP[$crate]=1
        fi
    fi
    [[ "${KEEP[$crate]}" == 1 ]] || continue
    if [[ -n "${SKIP[$crate$'\t'$test]:-}" ]]; then skip_tests=$((skip_tests+1)); continue; fi
    # Added on its first unskipped test, so a fully skipped crate drops out.
    if [[ -z "${NT[$crate]:-}" ]]; then CRATES+=("$crate"); : > "$RUNDIR/lists/$crate.txt"; fi
    printf '%s\n' "$test" >> "$RUNDIR/lists/$crate.txt"
    NT[$crate]=$(( ${NT[$crate]:-0} + 1 ))
    NTESTS=$((NTESTS + 1))
done < <(parse_tests_csv "$TESTS_CSV")
NCRATES=${#CRATES[@]}
if (( ${#MISSING[@]} > 0 )); then
    echo "Warning: ${#MISSING[@]} crate(s) in $TESTS_CSV have no dir under $DATASET_DIR (skipped):" >&2
    printf '  %s\n' "${MISSING[@]}" >&2
fi
(( NCRATES > 0 )) || {
    echo "Error: no crates with tests left to run from $TESTS_CSV after filtering." >&2
    if [[ -n "$VERSIONS" ]] && (( skip_version > 0 )); then
        echo "  --$VERSIONS dropped $skip_version crate(s): does $TESTS_CSV list the versions it selects?" >&2
        echo "  (--latest / --only-latest go with ${DATASET}-tests-latest.csv, --first / --only-first with ${DATASET}-tests.csv)" >&2
    fi
    rm -rf "$RUNDIR"
    exit 1
}

# ── Slow list: crates packed into their own jobs ────────────────────────────
# Matched on the dataset dir name minus its version (foo-1.2.3[-pre] -> foo).
# SLOW_CRATES keeps the slow list's order (slowest first); REG_CRATES the rest.
declare -A SLOW_RANK=()
if [[ -n "$SLOW_CSV" ]]; then
    n=0
    while IFS=, read -r name _ || [[ -n "$name" ]]; do
        name="${name//\"/}"; name="${name//$'\r'/}"; name="${name#$'\xef\xbb\xbf'}"
        name="${name//[[:space:]]/}"
        [[ -n "$name" && "$name" != crate && "$name" != \#* ]] || continue
        # A versioned entry (foo-1.2.3) still matches every version of foo.
        [[ "$name" =~ ^(.+)-[0-9]+\.[0-9]+\.[0-9]+([-+].*)?$ ]] && name="${BASH_REMATCH[1]}"
        [[ -n "${SLOW_RANK[$name]:-}" ]] || SLOW_RANK[$name]=$(( n++ ))
    done < "$SLOW_CSV"
fi
SLOW_CRATES=(); REG_CRATES=()
while IFS=$'\t' read -r _ crate; do
    SLOW_CRATES+=("$crate")
done < <(for crate in "${CRATES[@]}"; do
             base="$crate"
             [[ "$crate" =~ ^(.+)-[0-9]+\.[0-9]+\.[0-9]+([-+].*)?$ ]] && base="${BASH_REMATCH[1]}"
             [[ -n "${SLOW_RANK[$base]:-}" ]] && printf '%d\t%s\n' "${SLOW_RANK[$base]}" "$crate"
         done | sort -t$'\t' -k1,1n)
declare -A IS_SLOW=()
for crate in ${SLOW_CRATES[@]+"${SLOW_CRATES[@]}"}; do IS_SLOW[$crate]=1; done
for crate in "${CRATES[@]}"; do
    [[ -n "${IS_SLOW[$crate]:-}" ]] || REG_CRATES+=("$crate")
done
NSLOW=${#SLOW_CRATES[@]}
NREG=${#REG_CRATES[@]}

# ── Shape: spread the tests evenly over as many jobs as allowed ──────────────
# The slow crates fill the first SLOW_JOBS jobs, MAX_TASKS each in list order,
# so the slowest share a node. The rest go to the remaining jobs: up to
# MAX_JOBS in all (never more than one per crate), each only as wide as its
# number of crates, capped at MAX_TASKS. Many narrow jobs backfill better than
# a few wide ones. Every crate gets its own worker: if that takes more than
# MAX_JOBS jobs, the auto shape uses just enough full-width jobs and the ones
# past MAX_JOBS are staged (see the submit loop). With an explicit --jobs, a
# run that would need more than REG_JOBS x MAX_TASKS workers for the regular
# crates is refused rather than queueing crates behind one another.
SLOW_JOBS=$(( (NSLOW + MAX_TASKS - 1) / MAX_TASKS ))
if [[ -z "$JOBS" ]]; then
    REG_JOBS=$(( MAX_JOBS - SLOW_JOBS ))
    MIN_REG_JOBS=$(( (NREG + MAX_TASKS - 1) / MAX_TASKS ))
    (( REG_JOBS < MIN_REG_JOBS )) && REG_JOBS=$MIN_REG_JOBS
else
    REG_JOBS=$(( JOBS - SLOW_JOBS ))
fi
(( REG_JOBS > NREG )) && REG_JOBS=$NREG
(( REG_JOBS < 0 )) && REG_JOBS=0
(( NREG == 0 || REG_JOBS > 0 )) || {
    echo "Error: the $NSLOW slow-list crate(s) take $SLOW_JOBS job(s) at $MAX_TASKS worker(s) each," >&2
    echo "leaving none of --jobs $JOBS for the other $NREG crate(s). Raise --jobs." >&2
    rm -rf "$RUNDIR"
    exit 1
}
JOBS=$(( SLOW_JOBS + REG_JOBS ))
(( NREG <= REG_JOBS * MAX_TASKS )) || {
    echo "Error: $NREG crates need one worker each, but $REG_JOBS job(s) x $MAX_TASKS worker(s)" >&2
    echo "(after $SLOW_JOBS slow-list job(s)) is only $(( REG_JOBS * MAX_TASKS )). Raise --jobs" >&2
    echo "(or drop it to let the run stage extra jobs) / --max-tasks, or lower" >&2
    echo "--cpus-per-task / --mem-per-task." >&2
    rm -rf "$RUNDIR"
    exit 1
}

JOB_TESTS=(); JOB_CRATES=()
for (( j = 0; j < JOBS; j++ )); do JOB_TESTS[j]=0; JOB_CRATES[j]=0; done
# Slow crates: straight into jobs 0..SLOW_JOBS-1, slowest first.
for (( k = 0; k < NSLOW; k++ )); do
    crate="${SLOW_CRATES[k]}"
    j=$(( k / MAX_TASKS ))
    printf '%s\n' "$crate" >> "$RUNDIR/queues/job-$j.txt"
    JOB_TESTS[j]=$(( JOB_TESTS[j] + NT[$crate] ))
    JOB_CRATES[j]=$(( JOB_CRATES[j] + 1 ))
done
# Regular crates: balance by test count (greedy longest-first) over jobs
# SLOW_JOBS..JOBS-1: crates in decreasing order of tests, each to the job with
# the fewest tests so far (ties: fewest crates, then lowest index) among those
# not yet holding MAX_TASKS crates -- one crate per worker. Crates stay whole
# -- each is compiled once -- so one huge crate can still outweigh a job's
# share. The check above guarantees a free slot.
while IFS=$'\t' read -r cnt crate; do
    best=-1
    for (( j = SLOW_JOBS; j < JOBS; j++ )); do
        (( JOB_CRATES[j] < MAX_TASKS )) || continue
        (( best >= 0 )) || { best=$j; continue; }
        if (( JOB_TESTS[j] < JOB_TESTS[best] ||
              (JOB_TESTS[j] == JOB_TESTS[best] && JOB_CRATES[j] < JOB_CRATES[best]) )); then
            best=$j
        fi
    done
    printf '%s\n' "$crate" >> "$RUNDIR/queues/job-$best.txt"
    JOB_TESTS[best]=$(( JOB_TESTS[best] + cnt ))
    JOB_CRATES[best]=$(( JOB_CRATES[best] + 1 ))
done < <(for crate in ${REG_CRATES[@]+"${REG_CRATES[@]}"}; do printf '%d\t%s\n' "${NT[$crate]}" "$crate"; done \
         | sort -t$'\t' -k1,1nr -k2,2)
PER_JOB_MAX=0; PER_JOB_MIN=$NCRATES; TESTS_MAX=0; TESTS_MIN=$NTESTS
for (( j = 0; j < JOBS; j++ )); do
    (( JOB_CRATES[j] > PER_JOB_MAX )) && PER_JOB_MAX=${JOB_CRATES[j]}
    (( JOB_CRATES[j] < PER_JOB_MIN )) && PER_JOB_MIN=${JOB_CRATES[j]}
    (( JOB_TESTS[j] > TESTS_MAX )) && TESTS_MAX=${JOB_TESTS[j]}
    (( JOB_TESTS[j] < TESTS_MIN )) && TESTS_MIN=${JOB_TESTS[j]}
done
TASKS=$PER_JOB_MAX
(( TASKS > MAX_TASKS )) && TASKS=$MAX_TASKS

# ── Config shared with the node-side scripts ─────────────────────────────────
{
    printf 'GROUP=%q\n'            "$GROUP"
    printf 'MODE=%q\n'             "$MODE"
    printf 'IMAGE=%q\n'            "$IMAGE"
    printf 'SIF_ABS=%q\n'          "$SIF_ABS"
    printf 'DATASET_DIR=%q\n'      "$DATASET_DIR"
    printf 'DOWNLOAD=%q\n'         "$DOWNLOAD"
    printf 'CPUS_PER_TASK=%q\n'    "$CPUS_PER_TASK"
    printf 'MEM_PER_TASK=%q\n'     "$MEM_PER_TASK"
    printf 'TEST_THREADS=%q\n'     "$TEST_THREADS"
    printf 'TEST_TIMEOUT=%q\n'     "$TEST_TIMEOUT"
    printf 'MIRIFLAGS_ALL=%q\n'    "$MIRIFLAGS_ALL"
    printf 'BSAN_OPTIONS_ALL=%q\n' "$BSAN_OPTIONS_ALL"
    printf 'BSAN_SYMBOLIZER=%q\n'  "$BSAN_SYMBOLIZER"
    printf 'MASTER_CSV=%q\n'       "$CSV"
} > "$RUNDIR/config.env"

# ── inner.sh: runs INSIDE the container, once per crate, cwd = /work ─────────
cat > "$RUNDIR/inner.sh" << 'INNER_EOF'
#!/bin/bash
# Compile the crate, list its tests, then run and time each test once.
# Streams one row per test (or one test-less row for a crate that never got
# that far) straight into $EV_SHARD.
set -u

# Finite stack again: srun steps don't inherit the job script's ulimit, and a
# huge stack rlimit puts the mmap base inside bsan's shadow range (see
# run_job.sh). Every binary exec'd from here gets the compatible layout. The
# hard limit too, so nothing below (cargo bsan, its runner) can raise the soft
# one back up; thread stacks are mmapped, not bound by it.
echo "stack limit on entry: soft=$(ulimit -S -s) hard=$(ulimit -H -s)"
ulimit -S -s 8192
ulimit -H -s 8192 2>/dev/null || true
echo "stack limit now: soft=$(ulimit -S -s) hard=$(ulimit -H -s) (randomize_va_space=$(cat /proc/sys/kernel/randomize_va_space 2>/dev/null))"

case "$EV_MODE" in
    rust) RUN="cargo test --tests" ;;
    miri) export MIRIFLAGS="$EV_MIRIFLAGS";   RUN="cargo miri test --tests" ;;
    bsan) export BSAN_OPTIONS="$EV_BSAN_OPTIONS"; RUN="cargo bsan test --tests"
          # Beats a crate's rust-toolchain(.toml) pinning stock stable/nightly.
          export RUSTUP_TOOLCHAIN=bsan
          # Source locations in BSAN reports.
          export BSAN_SYMBOLIZER="$EV_BSAN_SYMBOLIZER"
          [ -x "$BSAN_SYMBOLIZER" ] \
              || echo "warning: BSAN_SYMBOLIZER $BSAN_SYMBOLIZER is not executable; reports will lack source locations" ;;
    *) echo "Error: bad EV_MODE '$EV_MODE'" >&2; exit 1 ;;
esac

# --cfg=miri so every mode selects the same code and test set, --cap-lints=warn
# so a crate's own deny lints don't fail it. In rust/bsan mode --cfg=miri goes
# on the crate under test only: under cfg(miri), dependencies like backtrace
# call Miri-only extern fns (miri_backtrace_size, ...) that fail to link
# natively. rustc-cfg-miri.sh adds it, standing in for rustc as RUSTC (plain
# cargo) and as BSAN_ORIG_RUSTC (cargo bsan, which overrides RUSTC and
# RUSTC_WRAPPER but runs that as its rustc). Miri sets cfg(miri) on every
# crate and provides those fns, so miri mode keeps the flag in RUSTFLAGS.
if [ "$EV_MODE" = miri ]; then
    export RUSTFLAGS="--cfg=miri --cap-lints=warn"
else
    export RUSTFLAGS="--cap-lints=warn"
    EV_REAL_RUSTC=$(command -v rustc) || { echo "Error: rustc not found" >&2; exit 1; }
    export EV_REAL_RUSTC
    export RUSTC="$(dirname "$0")/rustc-cfg-miri.sh"
    export BSAN_ORIG_RUSTC="$RUSTC"
fi
# rustdoc takes RUSTDOCFLAGS, not RUSTFLAGS, and only for the crate under
# test, so doc tests get --cfg=miri there in every mode.
export RUSTDOCFLAGS="--cfg=miri --cap-lints=warn"
echo "RUSTFLAGS=[$RUSTFLAGS]${RUSTC:+ RUSTC=[$RUSTC]}"

# Doc tests (only from a test list made with build_dataset.sh / list_tests.sh
# --doc) arrive as "doc:<name>#<filter>[#<skip>...]", every part with
# % , ; space ' " # percent-encoded. rustdoc splits test args on whitespace,
# so one can't be picked by its full name with --exact; `<filter> --skip
# <skip>...` (substring matches) selects exactly it instead. As in
# run_bench_dataset.sh.
DOC_RUN="${RUN% --tests} --doc"
pct_decode() {
    printf '%s' "$1" | sed -e 's/%2C/,/g' -e 's/%3B/;/g' -e 's/%20/ /g' \
        -e "s/%27/'/g" -e 's/%22/"/g' -e 's/%23/#/g' -e 's/%25/%/g'
}

HARNESS=()
[ -n "${EV_TEST_THREADS:-}" ] && HARNESS=(--test-threads="$EV_TEST_THREADS")

# --test-timeout: coreutils `timeout` signals the whole process group, so the
# test binaries cargo started die with it. Exits 124 (TERM) or 137 (-k KILL).
LIMIT=()
[ -n "${EV_TEST_TIMEOUT:-}" ] && LIMIT=(timeout -k 30 "$EV_TEST_TIMEOUT")

FAIL_LOG_LINES=200
BSAN_REPORT_LINES=200   # cap on a bsan error cell, in report lines
BSAN_LINE_CHARS=400     # ... on each report line (generic-heavy backtrace
                        # frames, e.g. chumsky's, run to tens of KB)
BSAN_REPORT_CHARS=16000 # ... and on the whole cell, so every row stays
                        # under editors' 20k-char line limit

ts() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }
now_ms() { date +%s%3N; }
secs() { printf '%d.%03d' $(( $1 / 1000 )) $(( $1 % 1000 )); }

# classify <output file>: sets ekind/emsg. Same patterns, same first-match
# order, as run_bench_dataset.sh and analysis/failure_logs.py -- keep in sync.
classify() {
    ekind=other; emsg=""
    local kp
    for kp in 'rustc|error\[E[0-9]+\]' 'linker|rust-lld' 'oom|SIGKILL' \
              'gc|ERROR: BorrowSanitizer: garbage collection' \
              'crash|BorrowSanitizer:DEADLYSIGNAL' \
              'bsan|error: Undefined Behavior:' 'panic|panicked at'; do
        if [ "${kp%%|*}" = panic ]; then
            emsg=$(grep -aE -m1 -A1 -- "${kp#*|}" "$1")
        else
            emsg=$(grep -aE -m1 -- "${kp#*|}" "$1")
        fi
        if [ -n "$emsg" ]; then ekind=${kp%%|*}; break; fi
    done
    if [ "$ekind" = bsan ]; then
        # The whole report: from the UB line through cargo's "error: test
        # failed" (or the first "error: N targets failed"), after the
        # stack trace and its "note: stack trace was truncated" line.
        emsg=$(awk -v max="$BSAN_REPORT_LINES" -v width="$BSAN_LINE_CHARS" '
            !on && /error: Undefined Behavior:/ { on = 1 }
            on {
                gsub(/\033\[[0-9;]*[A-Za-z]/, ""); sub(/\r$/, "")
                if (++n > max) { print "[... report truncated after " max " lines ...]"; exit }
                if (length($0) > width)
                    $0 = substr($0, 1, width) " [... " length($0) - width " more chars]"
                print
                if (/^error: (test failed|[0-9]+ targets? failed)/) exit
            }' "$1" | awk 'NF { for (; blank; blank--) print ""; print; next } { blank++ }' \
            | awk -v max="$BSAN_REPORT_CHARS" '
                { gsub(/\\/, "\\\\"); gsub(/\t/, "    ") }
                { sep = NR > 1 ? "\\n" : "" }
                total + length(sep $0) > max {
                    printf "\\n[... report truncated at %d chars ...]", max; exit
                }
                { printf "%s%s", sep, $0; total += length(sep $0) }')
        return
    fi
    [ -n "$emsg" ] || emsg=$(grep -aE '^error' "$1" | tail -n1)
    [ -n "$emsg" ] || emsg=$(grep -av '^[[:space:]]*$' "$1" | tail -n1)
    emsg=$(printf '%s' "$emsg" | sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' \
        | tr -d '\r' | tr '\n\t' '  ' | sed -e 's/^ *//' -e 's/  */ /g' | cut -c1-300)
}

csvq() { [ -n "$1" ] && printf '"%s"' "${1//\"/\"\"}"; }

# row <test> <status> <compile_s> <run_s> [<error_type> <error>]
# Test names are Rust paths, so they never contain a comma.
row() {
    line="$EV_BUILD,$EV_CRATE,$1,$2,$3,$4,$(ts),$EV_JOBID,${5:-},$(csvq "${6:-}")"
    echo "$line" >> "$EV_SHARD"
    echo "CSVROW:$line"
}

# dump_output <label> <rc> <file>: the tail of a failing command's output into
# the crate log, where the panic / UB report / failures: summary lives.
dump_output() {
    local nlines
    nlines=$(wc -l < "$3")
    echo "--- output: $EV_CRATE :: $1 (exit $2) ---"
    if [ "$nlines" -gt "$FAIL_LOG_LINES" ]; then
        echo "[... $(( nlines - FAIL_LOG_LINES )) earlier line(s) omitted ...]"
    fi
    tail -n "$FAIL_LOG_LINES" "$3"
    echo "--- end output: $EV_CRATE :: $1 ---"
}

ntests_ran() {
    grep -aoE '^running [0-9]+ test' "$1" | grep -oE '[0-9]+' | awk '{s+=$1} END{print s+0}'
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# ── fetch ──
cargo fetch < /dev/null > "$tmp/out" 2>&1; rc=$?
cat "$tmp/out"
if [ "$rc" -ne 0 ]; then
    classify "$tmp/out"
    row "" fetch_failed "" "" "$ekind" "$emsg"
    exit 1
fi

# ── compile ──
cstart=$(now_ms)
$RUN --no-run < /dev/null > "$tmp/out" 2>&1; rc=$?
compile=$(secs $(( $(now_ms) - cstart )))
cat "$tmp/out"
if [ "$rc" -ne 0 ]; then
    classify "$tmp/out"
    row "" build_failed "$compile" "" "$ekind" "$emsg"
    exit 1
fi
echo "compiled: $EV_CRATE in ${compile}s"

# ── tests: from the tests CSV, in its order ──
cp "$EV_TESTS" "$tmp/tests"
echo "tests: $EV_CRATE -> $(wc -l < "$tmp/tests" | tr -d ' ') from the tests CSV"

# ── each test, once ──
# After TIMEOUT_STREAK timeouts in a row within one top-level module (the
# test path's first segment, e.g. tests:: or lib::; for a doc test, its
# source file), that module's remaining tests are skipped: they get
# status=skipped rows, not runs, and the next module's tests still run.
TIMEOUT_STREAK=5
streak_mod=""; streak=0
skip_mods=$'\n'
while IFS= read -r t; do
    [ -n "$t" ] || continue
    if [ "${t#doc:}" != "$t" ]; then
        dname=$(pct_decode "${t#doc:}"); dname=${dname%%#*}
        mod="doc:${dname%% - *}"
    elif [ "${t%%::*}" != "$t" ]; then
        mod=${t%%::*}
    else
        mod=""
    fi
    if [[ "$skip_mods" == *$'\n'"$mod"$'\n'* ]]; then
        echo "result: $EV_CRATE :: $t -> skipped (${TIMEOUT_STREAK} timeouts in a row in ${mod:-<crate root>})"
        row "$t" skipped "$compile" "" timeout \
            "skipped: $TIMEOUT_STREAK consecutive timeouts in module ${mod:-<crate root>}"
        continue
    fi
    if [ "${t#doc:}" != "$t" ]; then
        # The run includes rustdoc collecting the crate's doc tests and
        # compiling this one's snippet: neither is built by --no-run.
        IFS='#' read -ra dparts <<< "${t#doc:}"
        targs=( "$(pct_decode "${dparts[1]}")" )
        for sk in "${dparts[@]:2}"; do targs+=( --skip "$(pct_decode "$sk")" ); done
        trun=$DOC_RUN
    else
        targs=( --exact "$t" )
        trun=$RUN
    fi
    rstart=$(now_ms)
    ${LIMIT[@]+"${LIMIT[@]}"} $trun -- ${HARNESS[@]+"${HARNESS[@]}"} "${targs[@]}" \
        < /dev/null > "$tmp/out" 2>&1; rc=$?
    run=$(secs $(( $(now_ms) - rstart )))
    nrun=$(ntests_ran "$tmp/out")
    ekind=""; emsg=""
    if [ "${#LIMIT[@]}" -gt 0 ] && { [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; }; then
        status=timeout
    elif [ "$nrun" -eq 0 ]; then
        status=no_match
    elif [ "$rc" -ne 0 ]; then
        status=test_failed
    else
        status=success
    fi
    [ "$rc" -ne 0 ] && classify "$tmp/out"
    if [ "$status" = timeout ]; then
        # A fixed message, not whatever the killed run last printed (which
        # classify could mistake for e.g. a panic, or oom on the -k SIGKILL).
        ekind=timeout
        emsg="test timed out after $EV_TEST_TIMEOUT (--test-timeout; killed by $([ "$rc" -eq 137 ] && echo SIGKILL || echo SIGTERM))"
        echo "$emsg" >> "$tmp/out"
    fi
    [ "$status" != success ] && dump_output "$t" "$rc" "$tmp/out"
    echo "result: $EV_CRATE :: $t -> $status (${run}s)${ekind:+ [$ekind]}"
    row "$t" "$status" "$compile" "$run" "$ekind" "$emsg"
    if [ "$status" = timeout ]; then
        [ "$mod" = "$streak_mod" ] || { streak_mod=$mod; streak=0; }
        streak=$(( streak + 1 ))
        if [ "$streak" -ge "$TIMEOUT_STREAK" ]; then
            echo "skipping: $EV_CRATE module ${mod:-<crate root>} after $streak timeouts in a row"
            skip_mods+="$mod"$'\n'
            streak=0
        fi
    else
        streak=0
    fi
done < "$tmp/tests"
INNER_EOF

# ── rustc-cfg-miri.sh: inner.sh's rustc in rust/bsan mode ────────────────────
# --cfg=miri for the crate under test (the primary package, in /work) only;
# the /work check keeps out cargo bsan's sysroot build, where std is primary.
cat > "$RUNDIR/rustc-cfg-miri.sh" << 'SHIM_EOF'
#!/bin/bash
if [ "${CARGO_PRIMARY_PACKAGE:-}" = 1 ] && [[ "${CARGO_MANIFEST_DIR:-}" == /work* ]]; then
    exec "$EV_REAL_RUSTC" "$@" --cfg=miri
fi
exec "$EV_REAL_RUSTC" "$@"
SHIM_EOF
chmod +x "$RUNDIR/rustc-cfg-miri.sh"

# ── job.sh: the sbatch payload, one per node ─────────────────────────────────
# Args: <rundir> <job index> <workers>. The workers share the job's crate
# queue: each pops the next crate under a node-local flock, so they stay busy
# until the queue is empty however uneven the crates turn out to be.
cat > "$RUNDIR/job.sh" << 'JOB_EOF'
#!/bin/bash
set -u
RUNDIR="$1"
JOBIDX="$2"
NTASKS="$3"
source "$RUNDIR/config.env"

if ! command -v module &>/dev/null; then
    source /etc/profile.d/lmod.sh    2>/dev/null || \
    source /etc/profile.d/modules.sh 2>/dev/null || true
fi
module load WebProxy
command -v singularity &>/dev/null || \
    module load Singularity 2>/dev/null || \
    module load singularity 2>/dev/null || true
if ! command -v singularity &>/dev/null; then
    echo "Error: 'singularity' not found on this node." >&2
    exit 1
fi
if [ -n "$TEST_TIMEOUT" ] && \
        ! singularity exec "$SIF_ABS" sh -c 'command -v timeout' >/dev/null 2>&1; then
    echo "Error: 'timeout' (coreutils) not found inside $SIF_ABS, needed by --test-timeout." >&2
    exit 1
fi

# Finite stack before entering the container (bsan shadow-memory layout
# workaround, harmless for other images -- see run_job.sh).
ulimit -S -s 8192

QUEUE="$RUNDIR/queues/job-$JOBIDX.txt"
# Node-local $TMPDIR (/tmp/job.$SLURM_JOB_ID): much lower small-file latency
# than /scratch for cargo builds. Only this node ever touches these dirs.
SCRATCH_BASE="${TMPDIR:-/tmp}"
NODE_TMP="${TMPDIR:-/tmp}/eval-$SLURM_JOB_ID"
mkdir -p "$SCRATCH_BASE" "$NODE_TMP"
echo 0 > "$NODE_TMP/next"
trap 'rm -rf "$SCRATCH_BASE/ev-$SLURM_JOB_ID-"* "$NODE_TMP" 2>/dev/null || true' EXIT

# download_crate <name-version> <into dir>: fetch the crates.io tarball and
# extract it to <into dir>/<name-version>/, as download_dataset.sh does. The
# name is everything up to the last hyphen before a digit. curl from the node,
# else from the image (which has it).
download_crate() {
    local c="$1" name url tmp rc
    name="${c%-[0-9]*}"
    url="https://static.crates.io/crates/$name/$name-${c#"$name"-}.crate"
    tmp="$2/.$c.crate"
    if command -v curl >/dev/null; then
        curl -fsSL -A "crate-downloader (CMU systems research; via crates.io)" \
            --retry 3 --retry-delay 2 -o "$tmp" "$url"
    else
        singularity exec --cleanenv --bind "$2" \
            --env https_proxy="${https_proxy:-}" --env HTTPS_PROXY="${HTTPS_PROXY:-}" \
            "$SIF_ABS" curl -fsSL -A "crate-downloader (CMU systems research; via crates.io)" \
            --retry 3 --retry-delay 2 -o "$tmp" "$url"
    fi && tar -xzf "$tmp" -C "$2" && [ -f "$2/$c/Cargo.toml" ]
    rc=$?
    rm -f "$tmp"
    return "$rc"
}

# Sets NEXT to the next crate in the queue, or "" once it is drained.
next_crate() {
    local n
    {
        flock 9
        n=$(< "$NODE_TMP/next")
        echo $(( n + 1 )) > "$NODE_TMP/next"
    } 9> "$NODE_TMP/lock"
    NEXT=$(sed -n "$(( n + 1 ))p" "$QUEUE")
}

# killed_rows <crate> <shard> <rc> <log> <job id>: a status=killed row for each
# of the crate's tests that has no row yet, once its srun step was killed
# outright (step OOM, signal) and took inner.sh down with it. When only the
# test process was OOM-killed, inner.sh recorded it and this adds nothing.
killed_rows() {
    local etype=other why="srun step exited $3" ts
    if grep -q 'oom[-_]kill' "$4"; then
        etype=oom
        why="srun step OOM-killed at --mem-per-task ${MEM_PER_TASK}G"
    fi
    echo "--- step killed: $1 ($why) ---" >> "$4"
    ts=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
    # FILENAME, not NR == FNR: the shard may be empty.
    awk -F, -v b="$IMAGE" -v c="$1" \
        -v tail=",killed,,,$ts,$5,$etype,\"$why before this test got a row\"" '
        FILENAME == ARGV[1] { if ($1 == b && $2 == c) have[$3] = 1; next }
        !($0 in have) { print b "," c "," $0 tail }' \
        "$2" "$RUNDIR/lists/$1.txt" >> "$2"
}

worker() {
    local tid="$1"
    local shard="$RUNDIR/shards/shard-${JOBIDX}-${tid}.csv"
    local scr="$SCRATCH_BASE/ev-${SLURM_JOB_ID}-${tid}"
    local crate cdir log e b rc
    # CARGO_HOME lives as long as the worker, so registry downloads carry over
    # from crate to crate; the source copy and target dir are per crate.
    rm -rf "$scr"
    mkdir -p "$scr/home"
    shopt -s dotglob nullglob
    while next_crate; [ -n "$NEXT" ]; do
        crate="$NEXT"
        cdir="$DATASET_DIR/$crate"
        log="$cdir/eval-${IMAGE}.log"
        echo "[job $JOBIDX task $tid] $crate"
        rm -rf "$scr/work" "$scr/target" "$scr/$crate"
        mkdir -p "$scr/target"
        if [ "$DOWNLOAD" = 1 ]; then
            # No dataset dir: the crate comes straight from crates.io into
            # this worker's scratch, and is removed with it.
            log="$RUNDIR/crate-logs/$crate/eval-${IMAGE}.log"
            mkdir -p "${log%/*}"
            if ! download_crate "$crate" "$scr" > "$log" 2>&1; then
                echo "$IMAGE,$crate,,fetch_failed,,,$(date -u +'%Y-%m-%dT%H:%M:%SZ'),${SLURM_JOB_ID}.${tid},other,\"crates.io download failed (see $log)\"" >> "$shard"
                echo "$crate" >> "$RUNDIR/done/done-${JOBIDX}-${tid}.txt"
                continue
            fi
            mv "$scr/$crate" "$scr/work"
        else
            # Private copy of the crate as /work, minus any target/ and logs, so
            # cargo's Cargo.lock write never touches the shared dataset dir.
            mkdir -p "$scr/work"
            for e in "$cdir"/*; do
                b="${e##*/}"
                case "$b" in target|*.log) continue ;; esac
                cp -a "$e" "$scr/work/"
            done
        fi
        # Each crate is its own job step, so it gets its own cgroup capped at
        # --mem-per-task: an OOM kills this crate only, never its neighbours
        # (which a shared job-wide pool would let it starve or take down).
        srun --exact --nodes=1 --ntasks=1 \
            --cpus-per-task="$CPUS_PER_TASK" --mem="${MEM_PER_TASK}G" \
            --kill-on-bad-exit=0 --job-name="$crate" \
        singularity exec --cleanenv --pwd /work \
            --bind "$scr" --bind "$RUNDIR" --bind "$scr/work:/work" \
            --env CARGO_HOME="$scr/home" \
            --env CARGO_TARGET_DIR="$scr/target" \
            --env CARGO_BUILD_JOBS="$CPUS_PER_TASK" \
            --env CARGO_TERM_COLOR=never \
            --env EV_BUILD="$IMAGE" --env EV_MODE="$MODE" \
            --env EV_CRATE="$crate" \
            --env EV_SHARD="$shard" \
            --env EV_TESTS="$RUNDIR/lists/$crate.txt" \
            --env EV_TEST_THREADS="$TEST_THREADS" \
            --env EV_TEST_TIMEOUT="$TEST_TIMEOUT" \
            --env EV_MIRIFLAGS="$MIRIFLAGS_ALL" \
            --env EV_BSAN_OPTIONS="$BSAN_OPTIONS_ALL" \
            --env EV_BSAN_SYMBOLIZER="$BSAN_SYMBOLIZER" \
            --env EV_JOBID="${SLURM_JOB_ID}.${tid}" \
            --env http_proxy="${http_proxy:-}"   --env https_proxy="${https_proxy:-}" \
            --env HTTP_PROXY="${HTTP_PROXY:-}"   --env HTTPS_PROXY="${HTTPS_PROXY:-}" \
            "$SIF_ABS" bash "$RUNDIR/inner.sh" > "$log" 2>&1
        rc=$?
        # 143 (SIGTERM) without an OOM report is SLURM ending the job
        # (walltime, scancel): the crate was interrupted, not at fault, so it
        # gets no rows and stays out of done/ for the re-run list to pick up.
        if (( rc == 143 )) && ! grep -q 'oom[-_]kill' "$log"; then
            echo "--- step interrupted: $crate (srun step exited 143; not recorded) ---" >> "$log"
            break
        fi
        # inner.sh itself exits 0, or 1 after its fetch/build_failed row; past
        # 128, or with slurmstepd's oom_kill report, the step was killed.
        if (( rc > 128 )) || grep -q 'oom[-_]kill' "$log"; then
            killed_rows "$crate" "$shard" "$rc" "$log" "${SLURM_JOB_ID}.${tid}"
        fi
        rm -rf "$scr/work" "$scr/target"
        echo "$crate" >> "$RUNDIR/done/done-${JOBIDX}-${tid}.txt"
    done
    rm -rf "$scr"
}

for (( tid = 0; tid < NTASKS; tid++ )); do
    worker "$tid" &
done
wait
JOB_EOF

# ── Plan summary ─────────────────────────────────────────────────────────────
echo "Mode:     $MODE   Image: $IMAGE"
if [[ "$DOWNLOAD" == 1 ]]; then
    echo "Dataset:  none at $DATASET_DIR -- crates downloaded from crates.io on the nodes ($DS_CSV)"
else
    echo "Dataset:  $DATASET_DIR"
fi
echo "Tests:    $NTESTS across $NCRATES crate(s) (from $TESTS_CSV)"
echo "Skipped:  ignored=$skip_ignored$( (( ${#BSAN_FAIL_CSVS[@]} > 0 )) && echo " bsan-build-fail=$skip_bsanfail") not-in-only=$skip_only${VERSIONS:+ not-$VERSIONS=$skip_version}${SAFETY:+ not-$SAFETY=$skip_safety} no-dir=${#MISSING[@]}"
for _f in ${BSAN_FAIL_CSVS[@]+"${BSAN_FAIL_CSVS[@]}"}; do
    echo "          bsan build-fail list: $_f"
done
if [[ -n "$SKIP_CSV" ]]; then
    echo "          $skip_tests test(s) from skip list $SKIP_CSV (${#SKIP[@]} listed)"
else
    echo "          no skip list"
fi
if [[ -n "$SLOW_CSV" ]]; then
    if (( NSLOW > 0 )); then
        echo "Slow:     $NSLOW crate(s) from $SLOW_CSV packed into job(s) 0-$(( SLOW_JOBS - 1 )), $SLOW_WALLTIME walltime"
    else
        echo "Slow:     none of the ${#SLOW_RANK[@]} crate(s) in $SLOW_CSV are in this run"
    fi
fi
echo "Shape:    $JOBS job(s), $TESTS_MIN-$TESTS_MAX test(s) / $PER_JOB_MIN-$PER_JOB_MAX crate(s) each, up to $TASKS worker(s)/job"
echo "          x ${CPUS_PER_TASK} cpu, ${MEM_PER_TASK}G/worker, $WALLTIME walltime$( (( SLOW_JOBS > 0 )) && echo " (regular jobs)")"
(( JOBS > MAX_JOBS )) && echo "Staging:  at most $MAX_JOBS of your jobs in SLURM at once; the rest are submitted
          as slots free up -- keep this script running (tmux/screen) until all are in"
echo "Timing:   one run per test${TEST_THREADS:+, --test-threads=$TEST_THREADS}${TEST_TIMEOUT:+, --test-timeout=$TEST_TIMEOUT}"
[[ "$MODE" == "miri" ]] && echo "MIRIFLAGS: $MIRIFLAGS_ALL"
[[ "$MODE" == "bsan" ]] && echo "BSAN_OPTIONS: $BSAN_OPTIONS_ALL"
[[ "$MODE" == "bsan" ]] && echo "BSAN_SYMBOLIZER: $BSAN_SYMBOLIZER"
echo "Results:  $CSV"
echo "Run dir:  $RUNDIR"
echo

# ── Submit one single-node sbatch job per queue, staging past MAX_JOBS ──────
# SLURM takes at most MAX_JOBS jobs per user at once (running + pending, the
# user's other jobs included). Every non-empty queue starts out staged; as
# many as fit go in now, the rest from the poll loop as slots free up.
# Staged fewest tests first (ties: lowest index), slow-list jobs included, so
# the small crates are submitted -- and so usually start -- ahead of the big.
STAGED=()
while IFS=$'\t' read -r _ j; do
    STAGED+=("$j")
done < <(for (( j = 0; j < JOBS; j++ )); do
             [[ -s "$RUNDIR/queues/job-$j.txt" ]] && printf '%d\t%d\n' "${JOB_TESTS[j]}" "$j"
         done | sort -t$'\t' -k1,1n -k2,2n)
JOBIDS=()
SQ_USER="${USER:-$(id -un)}"

# Sets NQUEUED to the user's job count in SLURM; fails if squeue does.
count_queued() {
    local out
    out=$(squeue -h -u "$SQ_USER" -o '%i' 2>/dev/null) || return 1
    NQUEUED=$(grep -c . <<< "$out" || true)
}

# Submits job $1, appending its SLURM id to JOBIDS; fails if sbatch does.
submit_job() {
    local j="$1" q="$RUNDIR/queues/job-$1.txt" nt wt jid
    nt=$(wc -l < "$q")
    (( nt > TASKS )) && nt=$TASKS
    wt=$WALLTIME
    (( j < SLOW_JOBS )) && wt=$SLOW_WALLTIME
    jid=$(sbatch --parsable \
        --job-name="ev-${IMAGE}-${DATASET}-$j" \
        --nodes=1 --ntasks-per-node="$nt" --cpus-per-task="$CPUS_PER_TASK" \
        --mem="$(( nt * MEM_PER_TASK ))G" --time="$wt" \
        --output="$RUNDIR/job-%j.out" \
        "$RUNDIR/job.sh" "$RUNDIR" "$j" "$nt") || return 1
    jid="${jid%%;*}"
    JOBIDS+=("$jid")
    echo "submitted job $j ($(wc -l < "$q") crates, ${JOB_TESTS[j]} tests, $nt workers, $wt) -> SLURM job $jid"
}

# Submits staged jobs, in order, while the user has fewer than MAX_JOBS in
# SLURM. Fails (leaving the job staged) if sbatch does; a failed squeue just
# skips this round.
submit_staged() {
    (( ${#STAGED[@]} )) || return 0
    count_queued || return 0
    while (( ${#STAGED[@]} && NQUEUED < MAX_JOBS )); do
        submit_job "${STAGED[0]}" || return 1
        STAGED=("${STAGED[@]:1}")
        NQUEUED=$(( NQUEUED + 1 ))
    done
}

if ! submit_staged; then
    echo "Error: sbatch failed for job ${STAGED[0]}; cancelling ${JOBIDS[*]:-nothing}." >&2
    (( ${#JOBIDS[@]} )) && scancel "${JOBIDS[@]}" 2>/dev/null || true
    exit 1
fi
(( ${#STAGED[@]} )) && echo "staged ${#STAGED[@]} job(s) until the queue has room (at most $MAX_JOBS of your jobs at once)"

# From here on, whatever ends the orchestrator merges the shards first:
# Ctrl-C / TERM cancel the jobs, then merge what they wrote; a hangup (SSH
# dropped) leaves them running and merges what's there so far -- rerun
# --merge once they finish. Normal completion merges below.
MERGED=0
merge_on_exit() {
    (( MERGED )) && return
    MERGED=1
    echo
    (( ${#STAGED[@]} )) && echo "warning: ${#STAGED[@]} staged job(s) were never submitted (jobs ${STAGED[*]}); their crates have no results." >&2
    merge_shards "$RUNDIR" "$CSV" || true
    echo "  (more rows later? run_eval_dataset.sh --merge $RUNDIR)"
}
cancel_jobs() {
    trap - INT TERM HUP
    echo; echo "Cancelling jobs: ${JOBIDS[*]:-none}"
    (( ${#JOBIDS[@]} )) && scancel "${JOBIDS[@]}" 2>/dev/null || true
    exit 130
}
trap merge_on_exit EXIT
trap cancel_jobs INT TERM
trap 'exit 129' HUP

# ── Poll until every job is submitted and has left the queue ───────────────
# Each round first submits whatever staged jobs now fit. A sbatch failure
# leaves the job staged for the next round; after SUBMIT_MAX_FAILS rounds in
# a row, the run gives up and cancels what it submitted.
SUBMIT_FAILS=0
SUBMIT_MAX_FAILS=5
while :; do
    if submit_staged; then
        SUBMIT_FAILS=0
    else
        SUBMIT_FAILS=$(( SUBMIT_FAILS + 1 ))
        echo "warning: sbatch failed for job ${STAGED[0]} ($SUBMIT_FAILS/$SUBMIT_MAX_FAILS); retrying next round." >&2
        if (( SUBMIT_FAILS >= SUBMIT_MAX_FAILS )); then
            trap - INT TERM HUP
            echo "Error: giving up on the ${#STAGED[@]} staged job(s); cancelling ${JOBIDS[*]:-nothing}." >&2
            (( ${#JOBIDS[@]} )) && scancel "${JOBIDS[@]}" 2>/dev/null || true
            exit 1
        fi
    fi
    left=0
    if (( ${#JOBIDS[@]} )); then
        IDLIST=$(IFS=,; echo "${JOBIDS[*]}")
        left=$(squeue -h -o '%T' -j "$IDLIST" 2>/dev/null | grep -c . || true)
    fi
    done_crates=$(cat "$RUNDIR"/done/*.txt 2>/dev/null | wc -l || true)
    rows=$(cat "$RUNDIR"/shards/*.csv 2>/dev/null | wc -l || true)
    echo "$(date +%H:%M:%S)  jobs in queue: $left   staged: ${#STAGED[@]}   crates done: $done_crates/$NCRATES   result rows: $rows"
    (( left == 0 && ${#STAGED[@]} == 0 )) && break
    sleep 60
done
trap - INT TERM HUP

# ── Merge shards into the master CSV and summarize ───────────────────────────
echo
MERGED=1
merge_shards "$RUNDIR" "$CSV"
echo "Done. Results CSV: $CSV"
summarize_run "$RUNDIR" "$NCRATES"
