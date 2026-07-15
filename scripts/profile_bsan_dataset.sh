#!/usr/bin/env bash
#
# Usage: profile_bsan_dataset.sh [options] <image> [walltime] <dataset> [bsan_options]
#
#   <image>     image/SIF name under the group containers dir (e.g. bsan,
#               visit-gc). Always runs BorrowSanitizer via `cargo bsan test`.
#   [walltime]  walltime per REGULAR sbatch job, HH or HH:MM (default 2).
#               Slowlist jobs use --slow-walltime instead. (Recognized
#               positionally by shape, so a purely numeric dataset name
#               would need the walltime spelled out.)
#   <dataset>   folder under the group datasets dir holding crate subdirectories.
#   [bsan_options] optional extra BSAN_OPTIONS appended (colon-separated) to
#                  the built-in set.
#
# Options:
#   --tests FILE      tests CSV (crate,tests,contains_ffi -- as produced by
#                     list_tests.sh). Default: <outputs>/tests-<dataset>.csv
#   --no-ffi          only run crates whose contains_ffi column is exactly
#                     "false" (both "true" and "scan_failed" are skipped)
#   --ignore FILE     crate names to skip, one per line (#-comments ok)
#   --only FILE       run ONLY the crates listed in FILE (one per line,
#                     #-comments ok; --ignore/--no-ffi still apply on top)
#   --jobs N          number of single-node sbatch jobs for the regular (non-
#                     slowlist) crates. Default: as many as needed for full
#                     parallelism, ceil(crates / tasks), capped at 40 (the
#                     QOS job limit)
#   --tasks N         worker tasks per node (default 12 -- so up to 12 crates
#                     run concurrently on one node)
#   --cpus-per-task N cores per worker (default 2; also caps cargo build jobs)
#   --mem-per-task G  GB per worker (default 8; tasks*mem must fit 488G/node)
#   --slow-walltime T walltime for the per-crate slowlist jobs, HH or HH:MM
#                     (default 12)
#
# Like run_bench_dataset.sh (and unlike run_bsan_dataset.sh), this packs many
# workers into a few whole-node sbatch jobs and runs ONLY the test cases
# listed in the --tests CSV. Known-slow crates (scripts/slowlist) are pulled
# out of the regular dealing and each submitted as its own single-worker job.
#
# Each worker processes its crates sequentially:
#
#   compile once  (cargo bsan test --tests --no-run, timed, WITHOUT the node
#                 log exported -- sysroot setup and build scripts would
#                 otherwise pollute the profile)
#   per test      one run of `cargo bsan test --tests -- --exact <test>` with
#                 BSAN_NODE_LOG pointed at a fresh temp file. The bsan runtime
#                 opens that file with O_TRUNC (every instrumented process
#                 rewrites it), so per-test temp files are the only way to
#                 keep more than the last run; note that WITHIN one run, if
#                 several test binaries execute instrumented code, only the
#                 last binary's log survives. After the run the temp log's
#                 rows are appended to the per-crate profile CSV under a
#                 leading `test` column.
#
# Per-crate profiles land in
#   <outputs>/bsan_profile/<image>[-<extra-slug>]-<dataset>/<crate>.csv.gz
# with columns
#   test,num_alloc_ids,num_nodes,alloc_ids,origin_file,origin_line,origin_col,
#   origin_source,test_file,test_line,test_col,test_source
# (one row per run of consecutive nodes sharing a location; alloc_ids is a
# space-separated list of the distinct allocations in the run). Aggregate them
# with analysis/node_profile.py. The profile dir is on group scratch, written
# from inside the container via the cluster's /scratch auto-bind.
#
# Result rows are STREAMED into per-worker shard CSVs (single writer per
# shard, no locking; a walltime kill loses only the in-flight test), one row
# per test plus a single test-less row for fetch_failed/build_failed crates:
#
#   build,crate,test,status,compile_seconds,run_seconds,timestamp,job_id
#
# status: success, test_failed, no_match (--exact filter ran 0 tests -- stale
# test list), build_failed, fetch_failed. run_seconds is empty for the
# crate-level failure rows.
#
# The orchestrator submits the jobs, polls squeue with a progress line, then
# merges all shards into <outputs>/<image>[-<extra-slug>]-<dataset>-profile.csv
# and prints a status breakdown. Per-crate logs land in
# <crate>/profile-<image>.log. Chunks/shards/logs for the run live under
# <outputs>/profile-runs/<runid>/ for debugging.
#
# If this script is killed the sbatch jobs keep running (Ctrl-C cancels them
# first); shards survive, so results can be merged by hand:
#   cat <rundir>/shards/*.csv >> <master csv>
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

# BSAN_OPTIONS used for every run. stacktrace_max_len caps how many frames the
# runtime records per stack trace.
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
    echo "Usage: $0 [options] <image> [walltime] <dataset> [bsan_options]" >&2
    echo "  <image>  image/SIF name under $CONTAINERS_DIR" >&2
    echo "  [walltime]  regular-job walltime, HH or HH:MM (default 2)" >&2
    echo "  <dataset>   folder under $DATASETS_ROOT" >&2
    echo "  [bsan_options] extra BSAN_OPTIONS (colon-separated)" >&2
    echo "  options: --tests FILE --no-ffi --ignore FILE --only FILE --jobs N" >&2
    echo "           --tasks N --cpus-per-task N --mem-per-task G" >&2
    echo "           --slow-walltime T (for slowlist jobs, default 12)" >&2
    exit 1
}
[[ $# -ge 2 && $# -le 4 ]] || usage

IMAGE_ARG="$1"
shift
# The walltime positional is optional: take the next arg as walltime only if
# it is shaped like one (HH or HH:MM); otherwise it is the dataset.
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
SLOW_WALLTIME=$(parse_walltime "$SLOW_WALLTIME_ARG")

MEM_PER_TASK="${MEM_PER_TASK%G}"
for v in TASKS CPUS_PER_TASK MEM_PER_TASK; do
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

# Full option set: built-in common options plus any extras (colon-separated).
BSAN_OPTIONS_ALL="$BSAN_COMMON${EXTRA:+:$EXTRA}"

# Fail fast on malformed options: the runtime tokenizes BSAN_OPTIONS on
# colons/spaces/commas and ABORTS EVERY instrumented process with
# "ERROR: expected '=' in BSAN_OPTIONS" if any token lacks a name=value
# shape -- catch that here instead of across a whole sweep. (A bare number
# also lands here when the walltime is put after the dataset: with
# `<image> <dataset> <walltime>` the walltime is taken as [bsan_options].)
IFS=$' :,\t' read -ra _opt_toks <<<"$BSAN_OPTIONS_ALL"
for tok in ${_opt_toks[@]+"${_opt_toks[@]}"}; do
    [[ -z "$tok" || "$tok" == ?*=* ]] || {
        echo "Error: BSAN_OPTIONS token '$tok' is not name=value." >&2
        echo "  full value: $BSAN_OPTIONS_ALL" >&2
        echo "  extras must be colon-separated name=value pairs," >&2
        echo "  e.g. bsan_visits_per_gc=40000 -- and the walltime goes BEFORE" >&2
        echo "  the dataset: $0 <image> [walltime] <dataset> [bsan_options]" >&2
        exit 1
    }
done

# Run stem: <image>[-<extra slug>]-<dataset> (slug logic as in the other
# run_*_dataset scripts, so different flag sets land in different files).
STEM="${IMAGE}-${DATASET}"
if [[ -n "$EXTRA" ]]; then
    SLUG="$(printf '%s' "$EXTRA" | tr -c '[:alnum:]' '-' | sed 's/-\{1,\}/-/g; s/^-//; s/-$//')"
    STEM="${IMAGE}-${SLUG}-${DATASET}"
fi
CSV="$OUTPUTS_DIR/${STEM}-profile.csv"
PROFILE_DIR="$OUTPUTS_DIR/bsan_profile/$STEM"   # per-crate node-log csvs (gzipped)

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
RUNDIR="$OUTPUTS_DIR/profile-runs/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$RUNDIR/chunks" "$RUNDIR/tests" "$RUNDIR/shards"
mkdir -p "$PROFILE_DIR"

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
# with a short walltime. Slowlist crates not selected for this run are simply
# ignored, so the list works across datasets.
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
    printf 'IMAGE=%q\n'            "$IMAGE"
    printf 'SIF_ABS=%q\n'          "$SIF_ABS"
    printf 'DATASET_DIR=%q\n'      "$DATASET_DIR"
    printf 'TASKS=%q\n'            "$TASKS"
    printf 'CPUS_PER_TASK=%q\n'    "$CPUS_PER_TASK"
    printf 'BSAN_OPTIONS_ALL=%q\n' "$BSAN_OPTIONS_ALL"
    printf 'PROFILE_DIR=%q\n'      "$PROFILE_DIR"
} > "$RUNDIR/config.env"

# ── inner.sh: runs INSIDE the container, once per crate, cwd = /work ─────────
# Fully quoted heredoc: everything resolves at run time from the PF_* env vars
# injected by the worker, so there is no nested-escaping to fight.
cat > "$RUNDIR/inner.sh" << 'INNER_EOF'
#!/bin/bash
# Compile the crate once, then run each test in PF_TESTFILE under a fresh
# BSAN_NODE_LOG and fold the node rows into the per-crate profile CSV.
# Emits one CSVROW: line per test (or a single test-less row on fetch/build
# failure) as a log-side copy; rows stream straight into the shard.
set -u

export BSAN_OPTIONS="$PF_BSAN_OPTIONS"
# Log the exact value the runtime will parse, so a bad option set is
# diagnosable from any crate's profile log.
echo "BSAN_OPTIONS=[$BSAN_OPTIONS]"
RUN="cargo bsan test --tests"
PROFILE_CSV="$PF_PROFILE_DIR/$PF_CRATE.csv"

ts() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }
# row <test> <status> <compile> <run>
# Streams the row STRAIGHT into this worker's shard (we are its only writer),
# so a walltime kill loses at most the in-flight test.
row() {
    line="$PF_BUILD,$PF_CRATE,$1,$2,$3,$4,$(ts),$PF_JOBID"
    echo "$line" >> "$PF_SHARD"
    echo "CSVROW:$line"
}

cargo clean >/dev/null 2>&1 || true
if ! cargo fetch; then
    row "" fetch_failed "" ""
    exit 1
fi

# Compile WITHOUT BSAN_NODE_LOG exported: the first-use instrumented-sysroot
# setup and build scripts would otherwise pollute the profile with nodes that
# have nothing to do with the tests.
cstart=$(date +%s%3N)
if ! $RUN --no-run; then
    row "" build_failed "" ""
    exit 1
fi
cms=$(( $(date +%s%3N) - cstart ))
compile=$(printf '%d.%03d' $(( cms / 1000 )) $(( cms % 1000 )))

# Fresh per-crate profile (one canonical header; the runtime's own header
# lines are stripped as rows are folded in). This lives on group scratch,
# reachable in-container via the cluster's /scratch auto-bind; this worker is
# the only writer for this crate, so no locking is needed.
echo "test,num_alloc_ids,num_nodes,alloc_ids,origin_file,origin_line,origin_col,origin_source,test_file,test_line,test_col,test_source" > "$PROFILE_CSV"

while IFS= read -r t; do
    [ -n "$t" ] || continue
    # Per-test temp node log: the runtime opens BSAN_NODE_LOG with O_TRUNC,
    # so sharing one file across runs would keep only the last test's rows.
    nodelog=$(mktemp)
    runlog=$(mktemp)
    rstart=$(date +%s%3N)
    BSAN_NODE_LOG="$nodelog" $RUN -- --exact "$t" > "$runlog" 2>&1; rc=$?
    rms=$(( $(date +%s%3N) - rstart ))
    # no_match means the --exact filter ran 0 tests everywhere (stale list).
    nrun=$(grep -aoE '^running [0-9]+ test' "$runlog" | grep -oE '[0-9]+' | awk '{s+=$1} END{print s+0}')
    cat "$runlog"; rm -f "$runlog"
    if [ "$nrun" -eq 0 ]; then status=no_match
    elif [ "$rc" -ne 0 ]; then status=test_failed
    else status=success
    fi
    # Fold this test's node rows into the crate profile under a leading test
    # column (test names are comma-free per list_tests.sh, so plain prefixing
    # keeps the CSV valid). The runtime header, when present, is line 1.
    awk -v t="$t" 'NR == 1 && /^num_alloc_ids,/ { next } { print t "," $0 }' \
        "$nodelog" >> "$PROFILE_CSV"
    rm -f "$nodelog"
    run=$(printf '%d.%03d' $(( rms / 1000 )) $(( rms % 1000 )))
    echo "result: $PF_CRATE :: $t -> $status (${run}s)"
    row "$t" "$status" "$compile" "$run"
done < "$PF_TESTFILE"

# Compress on the compute node, so compression runs in parallel across
# workers; -f overwrites any .gz from a previous run.
gzip -f "$PROFILE_CSV" || true
INNER_EOF

# ── job.sh: the sbatch payload, one per node ─────────────────────────────────
# Also fully quoted: all configuration comes from config.env + its args
# (<rundir> <job index> [ntasks]). Launches NTASKS background workers, each
# draining its own chunk file into its own shard.
cat > "$RUNDIR/job.sh" << 'JOB_EOF'
#!/bin/bash
set -u
RUNDIR="$1"
JOBIDX="$2"
source "$RUNDIR/config.env"
# Worker count for THIS job: the slow-crate jobs run a single worker; the
# orchestrator passes it explicitly.
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

# Finite stack before entering the container (bsan shadow-memory layout
# workaround -- see run_job.sh for the full story).
ulimit -S -s 8192

SCRATCH_BASE="$GROUP/cargo-temp-$USER"
mkdir -p "$SCRATCH_BASE"
trap 'rm -rf "$SCRATCH_BASE/pf-$SLURM_JOB_ID-"* 2>/dev/null || true' EXIT

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
        local scr="$SCRATCH_BASE/pf-${SLURM_JOB_ID}-${tid}"
        local log="$cdir/profile-${IMAGE}.log"
        rm -rf "$scr"
        mkdir -p "$scr/home" "$scr/target"
        echo "[job $JOBIDX task $tid] ($k/$n) $crate"
        singularity exec --cleanenv --pwd /work \
            --bind "$scr" --bind "$RUNDIR" --bind "$cdir:/work" \
            --env CARGO_HOME="$scr/home" \
            --env CARGO_TARGET_DIR="$scr/target" \
            --env CARGO_BUILD_JOBS="$CPUS_PER_TASK" \
            --env PF_BUILD="$IMAGE" \
            --env PF_CRATE="$crate" \
            --env PF_TESTFILE="$RUNDIR/tests/$crate.txt" \
            --env PF_SHARD="$shard" \
            --env PF_PROFILE_DIR="$PROFILE_DIR" \
            --env PF_BSAN_OPTIONS="$BSAN_OPTIONS_ALL" \
            --env PF_JOBID="${SLURM_JOB_ID}.${tid}" \
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
echo "Image:    $IMAGE"
echo "Dataset:  $DATASET_DIR"
echo "Tests:    $TOTAL_TESTS across ${#SELECTED[@]} crates (from $TESTS_CSV)"
echo "Skipped:  ignored=$skip_ignored not-in-only=$skip_only ffi=$skip_ffi no-tests=$skip_empty missing-dir=${#MISSING[@]}"
if (( ${#MISSING[@]} > 0 )); then
    printf '  missing from dataset: %s\n' "${MISSING[@]}" | head -20
fi
echo "Shape:    $JOBS job(s) x $TASKS tasks x ${CPUS_PER_TASK} cpus, ${MEM_PER_TASK}G/task (${TOTAL_MEM}G/node), $WALLTIME each"
if (( ${#SLOW_SEL[@]} > 0 )); then
    echo "Slow:     ${#SLOW_SEL[@]} slowlist crate(s), each in its own 1-worker job at $SLOW_WALLTIME"
fi
echo "BSAN_OPTIONS: $BSAN_OPTIONS_ALL"
echo "Profiles: $PROFILE_DIR/<crate>.csv.gz"
echo "Results:  $CSV"
echo "Run dir:  $RUNDIR"
echo

# ── Submit one single-node sbatch job per chunked job index ──────────────────
# Independent 1-node jobs backfill better than one multi-node job; a job index
# with no chunks (more workers than crates) is simply not submitted.
JOBIDS=()
submit_one() {
    local j="$1" ntasks="$2" label="$3" wall="$4" jid
    compgen -G "$RUNDIR/chunks/chunk-$j-*.txt" >/dev/null || return 0
    if ! jid=$(sbatch --parsable \
        --job-name="pf-${IMAGE}-${DATASET}-${label}" \
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
    echo "build,crate,test,status,compile_seconds,run_seconds,timestamp,job_id" > "$CSV"
fi
cat "$RUNDIR"/shards/*.csv >> "$CSV" 2>/dev/null || true

echo
echo "Done. Results CSV: $CSV"
echo "Per-crate profiles: $PROFILE_DIR/<crate>.csv.gz"
echo "Aggregate with: analysis/node_profile.py $PROFILE_DIR"
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
    echo "  profile-${IMAGE}.log and $RUNDIR/job-*.out"
fi