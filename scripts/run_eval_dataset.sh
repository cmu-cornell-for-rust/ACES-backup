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
#   [walltime]  walltime per sbatch job, HH or HH:MM (default 48). (Recognized
#               positionally by shape, so a purely numeric dataset name would
#               need the walltime spelled out.)
#   <dataset>   folder under the group datasets dir holding crate subdirectories.
#   [extra]     mode-specific extras: -Z Miri flags (miri) or colon-separated
#               BSAN_OPTIONS (bsan), appended to the built-in set.
#
# Options:
#   --ignore FILE     crate names to skip, one per line (#-comments ok)
#   --only FILE       run ONLY the crates listed in FILE (same format;
#                     --ignore/--safety still apply on top)
#   --safety LIST     only run crates whose unsafe-scan status is in LIST, a
#                     comma-separated subset of safe, unsafe-deps, unsafe (or
#                     the symbols :) ? !). Crates "unknown" or never scanned
#                     are skipped. See --unsafe-scan
#   --unsafe-scan FILE  unsafe_scan.csv from dataset_creator/filter_unsafe.sh.
#                     Default: <dataset dir>/_logs/unsafe_scan.csv
#   --list FILE       per-crate test list (crate,tests with ';'-joined names, as
#                     build_dataset.sh / list_tests.sh write). Default:
#                     <outputs>/<dataset>_list.csv, else
#                     <dataset dir>/_logs/<dataset>_list.csv, if either exists
#   --jobs N          sbatch jobs to spread the crates over (default: one per
#                     crate, capped at 80)
#   --max-tasks N     ceiling on workers per job (default: as many as fit a
#                     24-core / 488G slice of a node at --cpus-per-task and
#                     --mem-per-task, i.e. 24 at the defaults)
#   --cpus-per-task N cores per worker (default 1; also caps CARGO_BUILD_JOBS)
#   --mem-per-task G  GB per worker (default 8, at most 16)
#   --test-threads N  pass `--test-threads=N` to the test harness on every run
# Environment:
#   BSAN_SYMBOLIZER   llvm-symbolizer path inside the image, so BSAN reports
#                     carry source locations (bsan mode). Default:
#                     /root/.rustup/toolchains/bsan/bin/llvm-symbolizer
#
#   --test-timeout T  time limit per test invocation, in any form coreutils
#                     `timeout` accepts (e.g. 300, 90s, 10m, 1.5h); a test that
#                     hits it is recorded as `timeout`. Unset by default. Worth
#                     setting: a test that hangs otherwise holds its worker --
#                     and every crate still queued behind it -- until walltime.
#
# How it differs from run_bench_dataset.sh
# ----------------------------------------
# * Tests come from <dataset>_list.csv (build_dataset.sh's listing; see
#   --list) when there is one: a crate with a row there runs exactly those
#   tests (none: no_tests). Any other crate -- or every crate, without a list
#   -- is listed by its worker after compiling, with
#   `cargo <tool> test --tests -- --list --format=json -Zunstable-options`
#   (the same listing as list_tests.sh, but under the run's own tool so it
#   reuses the build just made). Ignored tests -- including
#   #[cfg_attr(miri, ignore)] ones, since every mode builds with --cfg=miri --
#   are dropped, as list_tests.sh drops them. If the tool's listing fails
#   (e.g. Miri can't interpret a binary's startup), plain cargo lists instead.
# * No hyperfine: like run_bsan_dataset.sh, each phase is ONE invocation timed
#   with `date +%s%3N` around it. Each test is run exactly once -- no pre-run,
#   no warmup, no repeats -- and that run both classifies and times it.
# * No slowlist / test-level lists: the crates are dealt evenly over the jobs
#   (round-robin, so job sizes differ by at most one crate), and inside a job
#   the workers PULL crates from a shared queue as they free up, so one slow
#   crate never leaves the job's other workers idle behind a static deal.
# * A worker keeps its CARGO_HOME across the crates it handles, so registry
#   downloads are reused; the target dir is fresh per crate.
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
#   list          as above, unless the crate is in the list    (list_failed)
#   per test      cargo <tool> test --tests -- --exact <test>, timed once
#
# Rows are STREAMED into a per-worker shard CSV as each test finishes (single
# writer per shard; a walltime kill loses only the in-flight test):
#
#   build,crate,test,status,compile_seconds,run_seconds,timestamp,job_id,
#   error_type,error
#
# status: success, test_failed (exited non-zero), no_match (the filter ran 0
# tests), timeout (hit --test-timeout), and test-less crate rows:
# fetch_failed, build_failed, list_failed, no_tests (listing found no runnable
# tests). run_seconds is the wall time of the test's single invocation,
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
# error is the matching line (for panic, plus the message line after it; for
# other, the last error:/non-empty line), one line, at most 300 chars,
# double-quoted. The full output of every failing / no_match test (last 200
# lines) is written to <crate>/eval-<image>.log between
# "--- output: <crate> :: <test> ..." markers.
#
# The orchestrator submits the jobs, polls squeue with a progress line, then
# merges the shards into <outputs>/<image>[-<extra-slug>]-<dataset>-eval.csv
# and prints a status breakdown. Queues/shards/job logs live under
# <outputs>/eval-runs/<runid>/. If this script is killed the jobs keep running
# (Ctrl-C cancels them first); shards survive and can be merged by hand:
#   cat <rundir>/shards/*.csv >> <master csv>
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
# per-worker memory ceiling, and the most jobs submitted at once.
NODE_CPUS=24
NODE_MEM=488
MAX_MEM_PER_TASK=16
MAX_JOBS=80

# Built-in per-mode option sets (same as run_bench_dataset.sh).
MIRI_COMMON="-Zmiri-disable-alignment-check -Zmiri-disable-data-race-detector -Zmiri-ignore-leaks -Zmiri-tree-borrows"
BSAN_COMMON="stacktrace_max_len=32"
BSAN_SYMBOLIZER="${BSAN_SYMBOLIZER:-/root/.rustup/toolchains/bsan/bin/llvm-symbolizer}"

# ── Options ──────────────────────────────────────────────────────────────────
IGNORE_FILE=""
ONLY_FILE=""
SAFETY=""
UNSAFE_SCAN=""
LIST_CSV=""
JOBS=""              # empty = auto: one per crate, capped at MAX_JOBS
MAX_TASKS=""         # empty = auto: what fits NODE_CPUS / NODE_MEM
CPUS_PER_TASK=1
MEM_PER_TASK=8
TEST_THREADS=""
TEST_TIMEOUT=""
WALLTIME_ARG=48

POS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i|--ignore)     IGNORE_FILE="$2"; shift 2 ;;
        --ignore=*)      IGNORE_FILE="${1#*=}"; shift ;;
        --only)          ONLY_FILE="$2"; shift 2 ;;
        --only=*)        ONLY_FILE="${1#*=}"; shift ;;
        --safety)        SAFETY="$2"; shift 2 ;;
        --safety=*)      SAFETY="${1#*=}"; shift ;;
        --unsafe-scan)   UNSAFE_SCAN="$2"; shift 2 ;;
        --unsafe-scan=*) UNSAFE_SCAN="${1#*=}"; shift ;;
        --list)          LIST_CSV="$2"; shift 2 ;;
        --list=*)        LIST_CSV="${1#*=}"; shift ;;
        --jobs)          JOBS="$2"; shift 2 ;;
        --jobs=*)        JOBS="${1#*=}"; shift ;;
        --max-tasks)     MAX_TASKS="$2"; shift 2 ;;
        --max-tasks=*)   MAX_TASKS="${1#*=}"; shift ;;
        --cpus-per-task) CPUS_PER_TASK="$2"; shift 2 ;;
        --cpus-per-task=*) CPUS_PER_TASK="${1#*=}"; shift ;;
        --mem-per-task)  MEM_PER_TASK="$2"; shift 2 ;;
        --mem-per-task=*) MEM_PER_TASK="${1#*=}"; shift ;;
        --test-threads)  TEST_THREADS="$2"; shift 2 ;;
        --test-threads=*) TEST_THREADS="${1#*=}"; shift ;;
        --test-timeout)  TEST_TIMEOUT="$2"; shift 2 ;;
        --test-timeout=*) TEST_TIMEOUT="${1#*=}"; shift ;;
        -*)
            echo "Error: unknown option '$1'." >&2; exit 1 ;;
        *)
            POS+=("$1"); shift ;;
    esac
done
set -- ${POS[@]+"${POS[@]}"}

usage() {
    echo "Usage: $0 [options] <mode> <image> [walltime] <dataset> [extra]" >&2
    echo "  <mode>      miri | bsan | rust" >&2
    echo "  <image>     image/SIF name under $CONTAINERS_DIR" >&2
    echo "  [walltime]  per-job walltime, HH or HH:MM (default 48)" >&2
    echo "  <dataset>   folder under $DATASETS_ROOT" >&2
    echo "  [extra]     extra MIRIFLAGS (miri) or BSAN_OPTIONS (bsan)" >&2
    echo "  options: --ignore FILE --only FILE" >&2
    echo "           --safety safe,unsafe-deps,unsafe [--unsafe-scan FILE]" >&2
    echo "           --list FILE (default <dataset>_list.csv, if present)" >&2
    echo "           --jobs N (<= $MAX_JOBS) --max-tasks N --cpus-per-task N" >&2
    echo "           --mem-per-task G (<= $MAX_MEM_PER_TASK)" >&2
    echo "           --test-threads N --test-timeout T (per-test limit, e.g. 10m)" >&2
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

MEM_PER_TASK="${MEM_PER_TASK%G}"
for v in CPUS_PER_TASK MEM_PER_TASK; do
    [[ "${!v}" =~ ^[1-9][0-9]*$ ]] || { echo "Error: $v must be a positive integer." >&2; exit 1; }
done
(( MEM_PER_TASK <= MAX_MEM_PER_TASK )) \
    || { echo "Error: --mem-per-task is at most ${MAX_MEM_PER_TASK}G (got ${MEM_PER_TASK}G)." >&2; exit 1; }
(( CPUS_PER_TASK <= NODE_CPUS )) \
    || { echo "Error: --cpus-per-task is at most $NODE_CPUS." >&2; exit 1; }
if [[ -n "$JOBS" ]]; then
    [[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo "Error: --jobs must be a positive integer." >&2; exit 1; }
    (( JOBS <= MAX_JOBS )) || { echo "Error: --jobs is at most $MAX_JOBS." >&2; exit 1; }
fi
# The largest worker count a job may hold at this cpu/mem per worker.
FIT_TASKS=$(( NODE_CPUS / CPUS_PER_TASK ))
(( NODE_MEM / MEM_PER_TASK < FIT_TASKS )) && FIT_TASKS=$(( NODE_MEM / MEM_PER_TASK ))
if [[ -n "$MAX_TASKS" ]]; then
    [[ "$MAX_TASKS" =~ ^[1-9][0-9]*$ ]] || { echo "Error: --max-tasks must be a positive integer." >&2; exit 1; }
    (( MAX_TASKS <= FIT_TASKS )) || {
        echo "Error: --max-tasks $MAX_TASKS needs $(( MAX_TASKS * CPUS_PER_TASK )) cpus / $(( MAX_TASKS * MEM_PER_TASK ))G;" >&2
        echo "a job may use at most $NODE_CPUS cpus / ${NODE_MEM}G, i.e. $FIT_TASKS workers here." >&2
        exit 1
    }
else
    MAX_TASKS=$FIT_TASKS
fi
if [[ -n "$TEST_THREADS" ]]; then
    [[ "$TEST_THREADS" =~ ^[1-9][0-9]*$ ]] \
        || { echo "Error: --test-threads must be a positive integer (got '$TEST_THREADS')." >&2; exit 1; }
fi
if [[ -n "$TEST_TIMEOUT" ]]; then
    [[ "$TEST_TIMEOUT" =~ ^([0-9]+(\.[0-9]+)?|\.[0-9]+)[smhd]?$ && ! "$TEST_TIMEOUT" =~ ^[0.]+[smhd]?$ ]] \
        || { echo "Error: --test-timeout must be a positive duration like 300, 90s, 10m or 1.5h (got '$TEST_TIMEOUT')." >&2; exit 1; }
fi

IMAGE="$(basename "${IMAGE_ARG%.sif}")"
SIF_ABS="$CONTAINERS_DIR/$IMAGE.sif"
DATASET_DIR="$DATASETS_ROOT/$DATASET"

MIRIFLAGS_ALL=""
BSAN_OPTIONS_ALL=""
case "$MODE" in
    miri) MIRIFLAGS_ALL="$MIRI_COMMON${EXTRA:+ $EXTRA}" ;;
    bsan) BSAN_OPTIONS_ALL="$BSAN_COMMON${EXTRA:+:$EXTRA}" ;;
esac

# Master CSV: <image>[-<slug>]-<dataset>-eval.csv (slug as in the other run_*
# scripts, so different flag sets land in different files).
CSV="$OUTPUTS_DIR/${IMAGE}-${DATASET}-eval.csv"
SLUG=""
if [[ -n "$EXTRA" && "$MODE" != "rust" ]]; then
    SLUG="$(printf '%s' "$EXTRA" | tr -c '[:alnum:]' '-' | sed 's/-\{1,\}/-/g; s/^-//; s/-$//')"
fi
[[ -n "$TEST_THREADS" ]] && SLUG="${SLUG:+$SLUG-}tt${TEST_THREADS}"
[[ -n "$SLUG" ]] && CSV="$OUTPUTS_DIR/${IMAGE}-${SLUG}-${DATASET}-eval.csv"

# ── Validate ──────────────────────────────────────────────────────────────--
[[ -f "$SIF_ABS" ]]    || { echo "Error: image not found at $SIF_ABS" >&2; exit 1; }
[[ -d "$DATASET_DIR" ]] || { echo "Error: dataset dir not found: $DATASET_DIR" >&2; exit 1; }
command -v sbatch >/dev/null || { echo "Error: sbatch not found (run on a login node)." >&2; exit 1; }

if [[ -n "$LIST_CSV" ]]; then
    [[ -f "$LIST_CSV" ]] || { echo "Error: test list not found: $LIST_CSV" >&2; exit 1; }
else
    for f in "$OUTPUTS_DIR/${DATASET}_list.csv" "$DATASET_DIR/_logs/${DATASET}_list.csv"; do
        [[ -f "$f" ]] && { LIST_CSV="$f"; break; }
    done
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
declare -A ONLY=()
if [[ -n "$ONLY_FILE" ]]; then
    [[ -f "$ONLY_FILE" ]] || { echo "Error: --only list not found: $ONLY_FILE" >&2; exit 1; }
    read_name_list "$ONLY_FILE" ONLY
    (( ${#ONLY[@]} > 0 )) || { echo "Error: --only list $ONLY_FILE is empty." >&2; exit 1; }
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

# ── Select crates: every dataset dir holding a Cargo.toml ────────────────────
CRATES=()
skip_ignored=0; skip_only=0; skip_safety=0
for d in "$DATASET_DIR"/*/; do
    d="${d%/}"
    crate="$(basename "$d")"
    case "$crate" in _*) continue ;; esac
    [[ -f "$d/Cargo.toml" ]] || continue
    if [[ -n "${IGNORE[$crate]:-}" ]]; then skip_ignored=$((skip_ignored+1)); continue; fi
    if (( ${#ONLY[@]} > 0 )) && [[ -z "${ONLY[$crate]:-}" ]]; then skip_only=$((skip_only+1)); continue; fi
    if [[ -n "$SAFETY" && -z "${WANT_STATUS[${SAFETY_OF[$crate]:-unknown}]:-}" ]]; then skip_safety=$((skip_safety+1)); continue; fi
    CRATES+=("$crate")
done
NCRATES=${#CRATES[@]}
(( NCRATES > 0 )) || { echo "Error: no crates left to run in $DATASET_DIR after filtering." >&2; exit 1; }

# ── Shape: spread the crates evenly over as many jobs as allowed ─────────────
# Up to MAX_JOBS jobs (never more than one per crate), then each job is only
# as wide as its share of crates, capped at MAX_TASKS. Many narrow jobs
# backfill better than a few wide ones, and every crate starts at once until
# crates outnumber JOBS x MAX_TASKS; past that, workers pull from the job's
# queue as they free up.
if [[ -z "$JOBS" ]]; then
    JOBS=$NCRATES
    (( JOBS > MAX_JOBS )) && JOBS=$MAX_JOBS
fi
(( JOBS > NCRATES )) && JOBS=$NCRATES

RUNDIR="$OUTPUTS_DIR/eval-runs/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$RUNDIR/queues" "$RUNDIR/shards" "$RUNDIR/done" "$RUNDIR/lists"

# Per-crate test lists from LIST_CSV, one name per line, for the selected
# crates (first row per crate wins, as for every consumer of these CSVs).
nlisted=0
if [[ -n "$LIST_CSV" ]]; then
    declare -A SELECTED=()
    for crate in "${CRATES[@]}"; do SELECTED["$crate"]=1; done
    while IFS=, read -r crate tests || [[ -n "$crate" ]]; do
        tests="${tests//$'\r'/}"
        [[ -n "$crate" && "$crate" != "crate" && -n "${SELECTED[$crate]:-}" ]] || continue
        [[ -f "$RUNDIR/lists/$crate.txt" ]] && continue
        if [[ -n "$tests" ]]; then
            tr ';' '\n' <<<"$tests" > "$RUNDIR/lists/$crate.txt"
        else
            : > "$RUNDIR/lists/$crate.txt"
        fi
        nlisted=$((nlisted + 1))
    done < "$LIST_CSV"
fi

# Round-robin: job sizes differ by at most one crate.
i=0
for crate in "${CRATES[@]}"; do
    printf '%s\n' "$crate" >> "$RUNDIR/queues/job-$(( i % JOBS )).txt"
    i=$((i + 1))
done
PER_JOB_MAX=$(( (NCRATES + JOBS - 1) / JOBS ))
TASKS=$PER_JOB_MAX
(( TASKS > MAX_TASKS )) && TASKS=$MAX_TASKS

# ── Config shared with the node-side scripts ─────────────────────────────────
{
    printf 'GROUP=%q\n'            "$GROUP"
    printf 'MODE=%q\n'             "$MODE"
    printf 'IMAGE=%q\n'            "$IMAGE"
    printf 'SIF_ABS=%q\n'          "$SIF_ABS"
    printf 'DATASET_DIR=%q\n'      "$DATASET_DIR"
    printf 'CPUS_PER_TASK=%q\n'    "$CPUS_PER_TASK"
    printf 'TEST_THREADS=%q\n'     "$TEST_THREADS"
    printf 'TEST_TIMEOUT=%q\n'     "$TEST_TIMEOUT"
    printf 'MIRIFLAGS_ALL=%q\n'    "$MIRIFLAGS_ALL"
    printf 'BSAN_OPTIONS_ALL=%q\n' "$BSAN_OPTIONS_ALL"
    printf 'BSAN_SYMBOLIZER=%q\n'  "$BSAN_SYMBOLIZER"
} > "$RUNDIR/config.env"

# ── inner.sh: runs INSIDE the container, once per crate, cwd = /work ─────────
cat > "$RUNDIR/inner.sh" << 'INNER_EOF'
#!/bin/bash
# Compile the crate, list its tests, then run and time each test once.
# Streams one row per test (or one test-less row for a crate that never got
# that far) straight into $EV_SHARD.
set -u

case "$EV_MODE" in
    rust) RUN="cargo test --tests" ;;
    miri) export MIRIFLAGS="$EV_MIRIFLAGS";   RUN="cargo miri test --tests" ;;
    bsan) export BSAN_OPTIONS="$EV_BSAN_OPTIONS"; RUN="cargo bsan test --tests"
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
echo "RUSTFLAGS=[$RUSTFLAGS]${RUSTC:+ RUSTC=[$RUSTC]}"

HARNESS=()
[ -n "${EV_TEST_THREADS:-}" ] && HARNESS=(--test-threads="$EV_TEST_THREADS")

# --test-timeout: coreutils `timeout` signals the whole process group, so the
# test binaries cargo started die with it. Exits 124 (TERM) or 137 (-k KILL).
LIMIT=()
[ -n "${EV_TEST_TIMEOUT:-}" ] && LIMIT=(timeout -k 30 "$EV_TEST_TIMEOUT")

FAIL_LOG_LINES=200

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

# ── list ──
# From the dataset's test list when the crate has a row there; otherwise JSON
# lines on stdout, build noise on stderr. The tool's own listing reuses
# the build above; plain cargo is the fallback when it can't list (Miri
# failing a binary's startup), at the cost of a native build.
LIST_ARGS=(-- --list --format=json -Zunstable-options)
if [ -f "$EV_TESTS" ]; then
    sed '/^$/d' "$EV_TESTS" | LC_ALL=C sort -u > "$tmp/tests"
    echo "list: from the dataset's test list"
elif ! $RUN "${LIST_ARGS[@]}" < /dev/null > "$tmp/list" 2> "$tmp/listerr"; then
    cat "$tmp/listerr"
    if [ "$EV_MODE" != rust ]; then
        echo "list: $RUN failed to list; retrying with plain cargo"
        cargo test --tests "${LIST_ARGS[@]}" < /dev/null > "$tmp/list" 2> "$tmp/listerr"; rc=$?
    else
        rc=1
    fi
    if [ "$rc" -ne 0 ]; then
        cat "$tmp/listerr"
        cat "$tmp/list" "$tmp/listerr" > "$tmp/out"
        classify "$tmp/out"
        row "" list_failed "$compile" "" "$ekind" "$emsg"
        exit 1
    fi
fi
# Runnable = discovered and not #[ignore]d. A name in several binaries is
# listed once; --exact runs it in each of them.
if [ ! -f "$EV_TESTS" ]; then
    grep -a '"type": *"test"' "$tmp/list" | grep -a '"ignore": *false' \
        | sed -E 's/.*"name": *"([^"]*)".*/\1/' | sed '/^$/d' | LC_ALL=C sort -u > "$tmp/tests"
fi
ntests=$(wc -l < "$tmp/tests" | tr -d ' ')
echo "listed: $EV_CRATE -> $ntests runnable test(s)"
if [ "$ntests" -eq 0 ]; then
    row "" no_tests "$compile" ""
    exit 0
fi

# ── each test, once ──
while IFS= read -r t; do
    [ -n "$t" ] || continue
    rstart=$(now_ms)
    ${LIMIT[@]+"${LIMIT[@]}"} $RUN -- ${HARNESS[@]+"${HARNESS[@]}"} --exact "$t" \
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
    [ "$status" != success ] && dump_output "$t" "$rc" "$tmp/out"
    echo "result: $EV_CRATE :: $t -> $status (${run}s)${ekind:+ [$ekind]}"
    row "$t" "$status" "$compile" "$run" "$ekind" "$emsg"
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
SCRATCH_BASE="$GROUP/cargo-temp-$USER"
NODE_TMP="${TMPDIR:-/tmp}/eval-$SLURM_JOB_ID"
mkdir -p "$SCRATCH_BASE" "$NODE_TMP"
echo 0 > "$NODE_TMP/next"
trap 'rm -rf "$SCRATCH_BASE/ev-$SLURM_JOB_ID-"* "$NODE_TMP" 2>/dev/null || true' EXIT

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

worker() {
    local tid="$1"
    local shard="$RUNDIR/shards/shard-${JOBIDX}-${tid}.csv"
    local scr="$SCRATCH_BASE/ev-${SLURM_JOB_ID}-${tid}"
    local crate cdir log e b
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
        # Private copy of the crate as /work, minus any target/ and logs, so
        # cargo's Cargo.lock write never touches the shared dataset dir.
        rm -rf "$scr/work" "$scr/target"
        mkdir -p "$scr/work" "$scr/target"
        for e in "$cdir"/*; do
            b="${e##*/}"
            case "$b" in target|*.log) continue ;; esac
            cp -a "$e" "$scr/work/"
        done
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
echo "Dataset:  $DATASET_DIR"
if [[ -n "$LIST_CSV" ]]; then
    echo "Crates:   $NCRATES ($nlisted with tests from $LIST_CSV, the rest listed on the node)"
else
    echo "Crates:   $NCRATES (no test list; tests are listed per crate on the node)"
fi
echo "Skipped:  ignored=$skip_ignored not-in-only=$skip_only${SAFETY:+ not-$SAFETY=$skip_safety}"
echo "Shape:    $JOBS job(s), $(( NCRATES / JOBS ))-$PER_JOB_MAX crate(s) each, up to $TASKS worker(s)/job"
echo "          x ${CPUS_PER_TASK} cpu, ${MEM_PER_TASK}G/worker, $WALLTIME walltime"
echo "Timing:   one run per test${TEST_THREADS:+, --test-threads=$TEST_THREADS}${TEST_TIMEOUT:+, --test-timeout=$TEST_TIMEOUT}"
[[ "$MODE" == "miri" ]] && echo "MIRIFLAGS: $MIRIFLAGS_ALL"
[[ "$MODE" == "bsan" ]] && echo "BSAN_OPTIONS: $BSAN_OPTIONS_ALL"
[[ "$MODE" == "bsan" ]] && echo "BSAN_SYMBOLIZER: $BSAN_SYMBOLIZER"
echo "Results:  $CSV"
echo "Run dir:  $RUNDIR"
echo

# ── Submit one single-node sbatch job per queue ──────────────────────────────
JOBIDS=()
for (( j = 0; j < JOBS; j++ )); do
    q="$RUNDIR/queues/job-$j.txt"
    [[ -s "$q" ]] || continue
    nt=$(wc -l < "$q")
    (( nt > TASKS )) && nt=$TASKS
    if ! jid=$(sbatch --parsable \
        --job-name="ev-${IMAGE}-${DATASET}-$j" \
        --nodes=1 --ntasks-per-node="$nt" --cpus-per-task="$CPUS_PER_TASK" \
        --mem="$(( nt * MEM_PER_TASK ))G" --time="$WALLTIME" \
        --output="$RUNDIR/job-%j.out" \
        "$RUNDIR/job.sh" "$RUNDIR" "$j" "$nt"); then
        echo "Error: sbatch failed for job $j; cancelling ${JOBIDS[*]:-nothing}." >&2
        [[ ${#JOBIDS[@]} -gt 0 ]] && scancel "${JOBIDS[@]}" 2>/dev/null || true
        exit 1
    fi
    jid="${jid%%;*}"
    JOBIDS+=("$jid")
    echo "submitted job $j ($(wc -l < "$q") crates, $nt workers) -> SLURM job $jid"
done

cancel_jobs() {
    trap - INT TERM
    echo; echo "Cancelling jobs: ${JOBIDS[*]}"
    scancel "${JOBIDS[@]}" 2>/dev/null || true
    exit 130
}
trap cancel_jobs INT TERM

# ── Poll until every job leaves the queue ────────────────────────────────────
IDLIST=$(IFS=,; echo "${JOBIDS[*]}")
while :; do
    left=$(squeue -h -o '%T' -j "$IDLIST" 2>/dev/null | grep -c . || true)
    done_crates=$(cat "$RUNDIR"/done/*.txt 2>/dev/null | wc -l || true)
    rows=$(cat "$RUNDIR"/shards/*.csv 2>/dev/null | wc -l || true)
    echo "$(date +%H:%M:%S)  jobs in queue: $left   crates done: $done_crates/$NCRATES   result rows: $rows"
    (( left == 0 )) && break
    sleep 60
done
trap - INT TERM

# ── Merge shards into the master CSV and summarize ───────────────────────────
mkdir -p "$OUTPUTS_DIR"
HEADER="build,crate,test,status,compile_seconds,run_seconds,timestamp,job_id,error_type,error"
[[ -f "$CSV" ]] || echo "$HEADER" > "$CSV"
cat "$RUNDIR"/shards/*.csv >> "$CSV" 2>/dev/null || true

echo
echo "Done. Results CSV: $CSV"
# Status is field 4; test names never contain commas, and the only quoted
# field (error) comes after it.
cat "$RUNDIR"/shards/*.csv 2>/dev/null | awk -F, '
    { c[$4]++; total++ }
    END {
        for (s in c) printf "  %s: %d\n", s, c[s]
        printf "  total rows: %d\n", total + 0
    }' || true
done_crates=$(cat "$RUNDIR"/done/*.txt 2>/dev/null | wc -l || true)
if (( done_crates < NCRATES )); then
    echo "  NOTE: $(( NCRATES - done_crates )) crate(s) never finished (walltime / job failure)."
    echo "  Re-run them with --only: comm -23 <(sort $RUNDIR/queues/*.txt) <(sort $RUNDIR/done/*.txt)"
    echo "  See $RUNDIR/job-*.out and the crates' eval-${IMAGE}.log"
fi
