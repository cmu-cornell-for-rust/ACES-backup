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
#   --tasks N         worker tasks per node (default 12 -- 24 cpus/96G per
#                     regular job, small enough to backfill readily)
#   --cpus-per-task N cores per worker (default 2; also caps cargo build jobs)
#   --mem-per-task G  GB per worker (default 8; tasks*mem must fit 488G/node)
#   --slow-walltime T walltime for the per-crate slowlist jobs, HH or HH:MM
#                     (default 12). SLURM bills elapsed time, not the request,
#                     and these jobs are tiny (2 cpus), so generous is cheap
#   --runs N          hyperfine timing runs per test (default 5)
#   --warmup N        hyperfine warmup runs per test (default 1; the untimed
#                     status pre-run also warms caches, so each test runs
#                     1 + warmup + runs times in total)
#
# Unlike run_miri_dataset.sh / run_bsan_dataset.sh (one srun job per crate,
# throttled to the 40-job QOS cap), this packs many single-core workers into a
# few whole-node sbatch jobs -- HPRC's preferred shape for many small tasks.
#
# Known-slow crates (scripts/slowlist, one name per line, #-comments ok) are
# automatically pulled out of the regular dealing and EACH submitted as its
# own single-worker job -- so a straggler that needs many hours never sits in
# (or times out of) the regular jobs, and since SLURM bills the full
# allocation until the job's last process exits, each slow crate stops
# costing anything the moment it finishes instead of idling until the
# slowest one drains. Slowlist entries not selected for the run are ignored,
# so the list is dataset-agnostic. Slow jobs request --slow-walltime (12h
# default) while the regular jobs keep the short <walltime>, so the wide
# fast jobs stay backfill-friendly.
#
# Crates from the tests CSV are dealt round-robin (largest test count first)
# across jobs*tasks workers; each worker processes its crates sequentially:
#
#   compile once  (cargo <tool> test --tests --no-run, timed)
#   per test      one untimed pre-run to classify (success / test_failed /
#                 no_match), then `hyperfine --runs N` on
#                 `cargo <tool> test --tests -- --exact <test>` for passing
#                 tests. Times include cargo's no-op freshness check and the
#                 startup of every test binary in the crate (the filter runs in
#                 all of them) -- constant per crate, so comparable across
#                 modes, but not a bare test-body time. A test name that occurs
#                 in several binaries is executed in each of them per run.
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
# build_failed, fetch_failed. Timing fields are empty unless status=success.
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
TASKS=12
CPUS_PER_TASK=2
MEM_PER_TASK=8       # GB per worker
RUNS=5
WARMUP=1
WALLTIME_ARG=2         # walltime for the regular jobs (positional overrides)
SLOW_WALLTIME_ARG=12   # walltime for the per-crate slowlist jobs

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
        --cpus-per-task) CPUS_PER_TASK="$2"; shift 2 ;;
        --cpus-per-task=*) CPUS_PER_TASK="${1#*=}"; shift ;;
        --mem-per-task)  MEM_PER_TASK="$2"; shift 2 ;;
        --mem-per-task=*) MEM_PER_TASK="${1#*=}"; shift ;;
        --runs)          RUNS="$2"; shift 2 ;;
        --runs=*)        RUNS="${1#*=}"; shift ;;
        --warmup)        WARMUP="$2"; shift 2 ;;
        --warmup=*)      WARMUP="${1#*=}"; shift ;;
        --slow-walltime) SLOW_WALLTIME_ARG="$2"; shift 2 ;;
        --slow-walltime=*) SLOW_WALLTIME_ARG="${1#*=}"; shift ;;
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
    echo "           --tasks N --cpus-per-task N --mem-per-task G --runs N --warmup N" >&2
    echo "           --slow-walltime T (for slowlist jobs, default 12)" >&2
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
for v in TASKS CPUS_PER_TASK MEM_PER_TASK RUNS WARMUP; do
    [[ "${!v}" =~ ^[0-9]+$ ]] || { echo "Error: $v must be a number." >&2; exit 1; }
done
if [[ -n "$JOBS" ]]; then
    [[ "$JOBS" =~ ^[0-9]+$ && "$JOBS" -ge 1 ]] || { echo "Error: --jobs must be a number >= 1." >&2; exit 1; }
fi
(( TASKS >= 1 )) || { echo "Error: --tasks must be >= 1." >&2; exit 1; }
TOTAL_MEM=$(( TASKS * MEM_PER_TASK ))
if (( TOTAL_MEM > 488 )); then
    echo "Error: tasks*mem = ${TOTAL_MEM}G exceeds the 488G usable on an ACES node." >&2
    echo "Lower --tasks or --mem-per-task." >&2
    exit 1
fi
TOTAL_CPUS=$(( TASKS * CPUS_PER_TASK ))
if (( TOTAL_CPUS > 96 )); then
    echo "Error: tasks*cpus = ${TOTAL_CPUS} exceeds the 96 cores on an ACES node." >&2
    exit 1
fi

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
if [[ -n "$EXTRA" && "$MODE" != "rust" ]]; then
    SLUG="$(printf '%s' "$EXTRA" | tr -c '[:alnum:]' '-' | sed 's/-\{1,\}/-/g; s/^-//; s/-$//')"
    CSV="$OUTPUTS_DIR/${IMAGE}-${SLUG}-${DATASET}-hyperfine.csv"
fi

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
# each isolated in its own single-worker job, so the regular jobs can run
# with a short walltime and no slow crate bills idle cores while waiting for
# a slower one to drain. Slowlist crates not selected for this run are
# simply ignored, so the list works across datasets.
SLOWLIST_FILE="$GROUP/scripts/slowlist"
declare -A SLOWLIST=()
if [[ -f "$SLOWLIST_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"; line="${line//[[:space:]]/}"
        [[ -n "$line" ]] && SLOWLIST["$line"]=1
    done < "$SLOWLIST_FILE"
fi

FAST_SEL=(); SLOW_SEL=()
for line in "${SELECTED[@]}"; do
    if [[ -n "${SLOWLIST[${line#*$'\t'}]:-}" ]]; then
        SLOW_SEL+=("$line")
    else
        FAST_SEL+=("$line")
    fi
done

# ── Job count: auto-size unless --jobs was given ─────────────────────────────
# Enough single-node jobs that every non-slow crate gets its own worker from
# the start (ceil(fast crates/tasks)), capped at the QOS's 40 concurrent jobs.
# More jobs than crates/tasks would just sit idle; more than 40 would sit in
# the queue anyway. The slow job (if any) is submitted on top of these.
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

# Slow crates take the job indices after the regular ones, one single-worker
# job each (chunk-<idx>-0.txt holds exactly that crate).
SLOW_CRATES=()
if (( ${#SLOW_SEL[@]} > 0 )); then
    mapfile -t SLOW_SORTED < <(printf '%s\n' "${SLOW_SEL[@]}" | sort -t$'\t' -k1,1nr -k2,2)
    for line in "${SLOW_SORTED[@]}"; do
        crate="${line#*$'\t'}"
        printf '%s\n' "$crate" > "$RUNDIR/chunks/chunk-$(( JOBS + ${#SLOW_CRATES[@]} ))-0.txt"
        SLOW_CRATES+=("$crate")
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
    printf 'WARMUP=%q\n'           "$WARMUP"
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

while IFS= read -r t; do
    [ -n "$t" ] || continue
    # Untimed pre-run: classifies the test and warms caches. no_match means the
    # --exact filter ran 0 tests everywhere (stale test list).
    runlog=$(mktemp)
    $RUN -- --exact "$t" > "$runlog" 2>&1; rc=$?
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
                --export-csv "$hfcsv" "$RUN -- --exact $t"; then
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
    local n k=0 crate
    n=$(wc -l < "$chunk")
    while IFS= read -r crate; do
        k=$((k + 1))
        local cdir="$DATASET_DIR/$crate"
        local scr="$SCRATCH_BASE/hf-${SLURM_JOB_ID}-${tid}"
        local log="$cdir/hyperfine-${IMAGE}.log"
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
            --env HF_TESTFILE="$RUNDIR/tests/$crate.txt" \
            --env HF_SHARD="$shard" \
            --env HF_RUNS="$RUNS" --env HF_WARMUP="$WARMUP" \
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
echo "Shape:    $JOBS job(s) x $TASKS tasks x ${CPUS_PER_TASK} cpus, ${MEM_PER_TASK}G/task (${TOTAL_MEM}G/node), $WALLTIME each"
if (( ${#SLOW_CRATES[@]} > 0 )); then
    echo "Slow:     ${#SLOW_CRATES[@]} slowlist crate(s), each in its own 1-worker job at $SLOW_WALLTIME"
fi
echo "Sampling: $RUNS runs, $WARMUP warmup per test"
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
    submit_one "$j" "$TASKS" "$j" "$WALLTIME"
done
for (( k = 0; k < ${#SLOW_CRATES[@]}; k++ )); do
    submit_one "$(( JOBS + k ))" 1 "slow-${SLOW_CRATES[$k]}" "$SLOW_WALLTIME"
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

