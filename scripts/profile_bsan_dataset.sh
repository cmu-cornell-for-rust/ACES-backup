#!/usr/bin/env bash
#
# Usage: run_bsan_dataset.sh [--ignore FILE] <image> <walltime> <dataset> [bsan_options]
#
#   --ignore FILE  optional file of crate names to skip, one per line (blank
#                  lines and #-comments ignored). Names match the crate
#                  directory basenames under the dataset (e.g. bstr-1.12.1).
#   <image>     image/SIF name under the group containers dir (e.g. miri, rust,
#               bsan). The `rust` image runs `cargo test`; anything else runs
#               BorrowSanitizer via `cargo bsan test`.
#   <walltime>  per-job walltime, HH or HH:MM (passed straight to run_job.sh).
#   <dataset>   folder under the group datasets dir holding crate subdirectories.
#   [bsan_options] optional extra BSAN_OPTIONS appended (colon-separated, e.g.
#                  "opt1=val:opt2=val") to the built-in set on both the compile
#                  and run phase. Ignored for the `rust` image.
#
# Launches ONE SLURM job per crate via run_job.sh, keeping at most MAX_PARALLEL
# (default 40, override with the MAX_PARALLEL env var) running at once -- the
# `normal` QOS allows 40 concurrent jobs. Each job runs with 16G memory, is
# named "<crate>-<image>", writes its full stdout+stderr to "<crate>/<image>.log",
# and cleans up its per-job scratch on the way out. A row per crate
# (build,crate,status,compile_seconds,run_seconds,tests,passed,timestamp,job_id) is
# appended to /scratch/group/p.cis260229.000/outputs/<image>-<dataset>.csv, with
# concurrent writes serialized by a lock. compile_seconds/run_seconds time the
# (--no-run) build and the execution separately. tests is the number of tests
# executed (summed across every "running N tests" line in the run output, i.e.
# unit + integration + doc tests); passed is how many of those passed (summed
# across the "test result:" lines). Both are 0 when nothing ran. status is one of: success,
# test_failed (compiled, tests/bsan failed), build_failed (compile error),
# fetch_failed (deps wouldn't download). The orchestrator waits for every job to
# finish, then exits, printing a count of each status.
#
# For bsan images, each job also exports
# BSAN_NODE_LOG=<outputs>/bsan_profile/<crate>.csv so the runtime writes its
# per-node profile there; the job gzips it to <crate>.csv.gz on the way out
# (overwriting any .gz from a previous run).
#
# NOTE: the run_job.sh launchers are long-lived foreground processes, so run
# this under tmux/nohup if the sweep will outlast your SSH session.
set -euo pipefail

# The rolling concurrency limit below uses `wait -n`, which needs bash >= 4.3.
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
    echo "Error: this script needs bash >= 4.3 (have $BASH_VERSION)." >&2
    exit 1
fi

# ── Layout (all absolute, so this can be run from anywhere) ───────────────────
GROUP="/scratch/group/p.cis260229.000"
RUN_JOB="$GROUP/scripts/run_job.sh"
CONTAINERS_DIR="$GROUP/containers"
DATASETS_ROOT="$GROUP/datasets"
OUTPUTS_DIR="$GROUP/outputs"
PROFILE_DIR="$OUTPUTS_DIR/bsan_profile"   # per-crate BSAN_NODE_LOG csvs (gzipped)
MEM="16G"
MAX_PARALLEL="${MAX_PARALLEL:-40}"   # max jobs in flight at once (QOS MaxJobsPU=40)

# BSAN_OPTIONS used for every bsan image. stacktrace_max_len caps how many
# frames the runtime records per stack trace.
BSAN_COMMON="stacktrace_max_len=32"

# ── Args ──────────────────────────────────────────────────────────────────--
# Pull the optional --ignore/-i FILE flag out from anywhere in the arg list,
# leaving the positional args behind.
IGNORE_FILE=""
POS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i|--ignore)
            [[ $# -ge 2 ]] || { echo "Error: $1 requires a FILE argument." >&2; exit 1; }
            IGNORE_FILE="$2"; shift 2 ;;
        --ignore=*)
            IGNORE_FILE="${1#*=}"; shift ;;
        *)
            POS+=("$1"); shift ;;
    esac
done
set -- ${POS[@]+"${POS[@]}"}

if [[ $# -lt 3 || $# -gt 4 ]]; then
    echo "Usage: $0 [--ignore FILE] <image> <walltime> <dataset> [bsan_options]" >&2
    echo "  --ignore FILE  crate names to skip, one per line" >&2
    echo "  <image>     image/SIF name under $CONTAINERS_DIR (e.g. miri, rust, bsan)" >&2
    echo "  <walltime>  per-job walltime, HH or HH:MM" >&2
    echo "  <dataset>   folder under $DATASETS_ROOT holding crate subdirectories" >&2
    echo "  [bsan_options] optional extra BSAN_OPTIONS (colon-separated) appended to the built-in set" >&2
    exit 1
fi

IMAGE_ARG="$1"
WALLTIME="$2"
DATASET="$3"
EXTRA_BSAN_OPTIONS="${4:-}"   # extra BSAN_OPTIONS, appended to BSAN_COMMON

# Full option set for this run: the built-in common options plus any extras
# (colon-separated, sanitizer-style).
BSAN_OPTIONS_ALL="$BSAN_COMMON${EXTRA_BSAN_OPTIONS:+:$EXTRA_BSAN_OPTIONS}"

# Load the ignorelist (if any) into a set keyed by crate-dir basename.
declare -A IGNORE=()
if [[ -n "$IGNORE_FILE" ]]; then
    [[ -f "$IGNORE_FILE" ]] \
        || { echo "Error: ignorelist not found: $IGNORE_FILE" >&2; exit 1; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"              # strip trailing comments
        line="${line//[[:space:]]/}"    # strip whitespace (crate names have none)
        [[ -n "$line" ]] && IGNORE["$line"]=1
    done < "$IGNORE_FILE"
fi

# Normalized image name (strip any dir + .sif) for the job name and rust check.
IMAGE="$(basename "${IMAGE_ARG%.sif}")"
DATASET_DIR="$DATASETS_ROOT/$DATASET"

# When extra BSAN_OPTIONS are given, fold a filesystem-safe slug of them into
# the CSV name so runs with different option sets land in separate files
# instead of appending to the same one. Non-alphanumerics collapse to single
# dashes. The dataset name always comes LAST.
CSV="$OUTPUTS_DIR/${IMAGE}-${DATASET}.csv"
if [[ -n "$EXTRA_BSAN_OPTIONS" ]]; then
    OPT_SLUG="$(printf '%s' "$EXTRA_BSAN_OPTIONS" | tr -c '[:alnum:]' '-' | sed 's/-\{1,\}/-/g; s/^-//; s/-$//')"
    CSV="$OUTPUTS_DIR/${IMAGE}-${OPT_SLUG}-${DATASET}.csv"
fi

# ── Validate ──────────────────────────────────────────────────────────────--
[[ -x "$RUN_JOB" ]] \
    || { echo "Error: run_job.sh not executable at $RUN_JOB" >&2; exit 1; }
[[ -f "$CONTAINERS_DIR/$IMAGE.sif" ]] \
    || { echo "Error: image not found at $CONTAINERS_DIR/$IMAGE.sif" >&2; exit 1; }
[[ -d "$DATASET_DIR" ]] \
    || { echo "Error: dataset dir not found: $DATASET_DIR" >&2; exit 1; }

# ── Collect crate dirs (skipping any on the ignorelist) ──────────────────────
CRATE_DIRS=()
skipped=0
for d in "$DATASET_DIR"/*/; do
    [[ -d "$d" ]] || continue
    if [[ -n "${IGNORE[$(basename "${d%/}")]:-}" ]]; then
        skipped=$((skipped + 1))
        continue
    fi
    CRATE_DIRS+=("${d%/}")
done
[[ ${#CRATE_DIRS[@]} -gt 0 ]] \
    || { echo "Error: no crate subdirectories in $DATASET_DIR (after ignorelist)" >&2; exit 1; }

# ── Per-image compile + run commands ─────────────────────────────────────────
# The `rust` image runs the normal suite; every other image runs under
# BorrowSanitizer via `cargo bsan test`. COMPILE_CMD (--no-run) does all the
# building (including bsan's first-use instrumented-sysroot setup); RUN_CMD then
# only executes, so the two phases can be timed separately and cleanly.
if [[ "$IMAGE" == "rust" ]]; then
    COMPILE_CMD='cargo test --no-run'
    RUN_CMD='cargo test'
else
    COMPILE_CMD="BSAN_OPTIONS=\"$BSAN_OPTIONS_ALL\" cargo bsan test --no-run"
    RUN_CMD="BSAN_OPTIONS=\"$BSAN_OPTIONS_ALL\" cargo bsan test"
fi

echo "Image:    $IMAGE"
echo "Walltime: $WALLTIME   Mem: $MEM"
echo "Dataset:  $DATASET_DIR"
echo "Crates:   ${#CRATE_DIRS[@]}${IGNORE_FILE:+  (skipped $skipped via $IGNORE_FILE)}"
[[ "$IMAGE" != "rust" ]] && echo "BSAN_OPTIONS: $BSAN_OPTIONS_ALL"
[[ "$IMAGE" != "rust" ]] && echo "Node logs: $PROFILE_DIR/<crate>.csv.gz"
echo "Results:  $CSV"
echo

# Results CSV (appended across runs; header written once). Lives on group
# scratch, but all writers are this script's launcher subshells on this login
# node, so we serialize appends with an flock on a node-local lock file.
mkdir -p "$OUTPUTS_DIR"
[[ "$IMAGE" != "rust" ]] && mkdir -p "$PROFILE_DIR"
if [[ ! -f "$CSV" ]]; then
    echo "build,crate,status,compile_seconds,run_seconds,tests,passed,timestamp,job_id" > "$CSV"
fi
LOCKFILE="$(mktemp /tmp/run_dataset.lock.XXXXXX)"

# ── Launch jobs, at most MAX_PARALLEL in flight at once ──────────────────────
pids=()        # every launcher pid (for teardown on interrupt)
fail=0         # launchers that exited non-zero (build / run / infra errors)
inflight=0     # launched-but-not-yet-reaped count, drives the throttle
total=${#CRATE_DIRS[@]}
i=0

# On Ctrl-C / TERM, tear down whatever is still running (releasing the srun
# allocations) instead of leaving orphaned jobs behind.
cleanup() {
    trap - INT TERM
    [[ ${#pids[@]} -gt 0 ]] && kill "${pids[@]}" 2>/dev/null || true
    rm -f "$LOCKFILE"
}
trap cleanup INT TERM

# Block until one launcher finishes, then update the counters.
reap_one() {
    local rc=0
    wait -n || rc=$?
    inflight=$((inflight - 1))
    if (( rc != 0 )); then fail=$((fail + 1)); fi
}

for CRATE_PATH in "${CRATE_DIRS[@]}"; do
    CRATE="$(basename "$CRATE_PATH")"
    JOBNAME="${CRATE}-${IMAGE}"
    LOGFILE="$CRATE_PATH/${IMAGE}.log"
    i=$((i + 1))

    # Per-crate node log: the bsan runtime writes its profile csv here, and the
    # job gzips it on the way out (on the compute node, so compression runs in
    # parallel across jobs). Empty snippets for the plain rust image.
    NODE_LOG_EXPORT=""
    NODE_LOG_GZIP=""
    if [[ "$IMAGE" != "rust" ]]; then
        NODE_LOG="$PROFILE_DIR/$CRATE.csv"
        NODE_LOG_EXPORT="export BSAN_NODE_LOG=\"$NODE_LOG\""
        NODE_LOG_GZIP="{ [ -f \"$NODE_LOG\" ] && gzip -f \"$NODE_LOG\"; } || true"
    fi

    # Command that runs INSIDE the container, with /work == the crate dir.
    # CARGO_HOME / CARGO_TARGET_DIR are injected by run_job.sh and live under
    # the per-job scratch dir (named cargo-<SLURM_JOB_ID>), so deleting them on
    # exit reclaims that scratch, and the job id can be recovered from the path.
    # Phases are timed separately: COMPILE_CMD (--no-run) builds everything, then
    # RUN_CMD only executes -- so compile_seconds and run_seconds are clean. A row
    # is always emitted. status distinguishes fetch / build / test failures.
    # "\$" values expand inside the container; the rest expand here, now.
    read -r -d '' CMD <<EOF || true
trap 'rm -rf "\$CARGO_HOME" "\$CARGO_TARGET_DIR" 2>/dev/null || true' EXIT
$NODE_LOG_EXPORT
status=""
cms=0
rms=0
tests=0
passed=0
cargo clean || true
if ! cargo fetch; then
    status=fetch_failed
fi
if [ -z "\$status" ]; then
    cstart=\$(date +%s%3N)
    if ! ${COMPILE_CMD}; then status=build_failed; fi
    cms=\$(( \$(date +%s%3N) - cstart ))
fi
if [ -z "\$status" ]; then
    rstart=\$(date +%s%3N)
    # Capture run stdout so we can count tests; stderr still flows to the log.
    runlog="\$(mktemp)"
    ${RUN_CMD} > "\$runlog"; rc=\$?
    cat "\$runlog"
    if [ "\$rc" -eq 0 ]; then status=success; else status=test_failed; fi
    rms=\$(( \$(date +%s%3N) - rstart ))
    # Sum every "running N tests" line (unit + integration + doc test binaries).
    tests=\$(grep -aoE '^running [0-9]+ test' "\$runlog" | grep -oE '[0-9]+' | awk '{s+=\$1} END{print s+0}')
    # Sum the "N passed" from each "test result:" summary line.
    passed=\$(grep -aoE 'test result:.* [0-9]+ passed' "\$runlog" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+' | awk '{s+=\$1} END{print s+0}')
    rm -f "\$runlog"
fi
compile=\$(printf '%d.%03d' \$(( cms / 1000 )) \$(( cms % 1000 )))
run=\$(printf '%d.%03d' \$(( rms / 1000 )) \$(( rms % 1000 )))
ts=\$(date -u +'%Y-%m-%dT%H:%M:%SZ')
jobid="\$(basename "\${CARGO_HOME%/home}")"; jobid="\${jobid#cargo-}"
echo "result: ${CRATE} (${IMAGE}) -> \$status (compile \${cms}ms, run \${rms}ms)"
echo "CSVROW:${IMAGE},${CRATE},\$status,\$compile,\$run,\$tests,\$passed,\$ts,\$jobid"
$NODE_LOG_GZIP
EOF

    # Wait for a free slot before launching the next crate.
    if (( inflight >= MAX_PARALLEL )); then
        reap_one
    fi

    # Subshell cd's into the crate so run_job.sh binds it as /work. All output
    # (run_job.sh + srun + the in-container build/test) lands in the crate log;
    # afterward we pull the CSVROW line the container emitted and append it to
    # the shared CSV, serialized by an flock so concurrent jobs don't interleave.
    (
        cd "$CRATE_PATH" || exit 1
        "$RUN_JOB" -J "$JOBNAME" "$IMAGE" "$WALLTIME" "$MEM" -- "$CMD"
        rc=$?
        row="$(grep -am1 '^CSVROW:' "$LOGFILE" 2>/dev/null | cut -d: -f2-)"
        if [[ -n "$row" ]]; then
            { flock 9; printf '%s\n' "$row" >> "$CSV"; } 9>"$LOCKFILE"
        fi
        exit "$rc"
    ) > "$LOGFILE" 2>&1 &
    pids+=("$!")
    inflight=$((inflight + 1))
    echo "[$i/$total] launched $JOBNAME  ($inflight running)"
done

echo
echo "All $total launched; waiting for the final $inflight to finish..."

# Drain the remaining in-flight launchers.
while (( inflight > 0 )); do
    reap_one
done

trap - INT TERM
rm -f "$LOCKFILE"

# ── Per-run status breakdown (from each crate's emitted row) ─────────────────
declare -A counts=()
rows=0
for CRATE_PATH in "${CRATE_DIRS[@]}"; do
    CRATE="$(basename "$CRATE_PATH")"
    st="$(grep -am1 '^CSVROW:' "$CRATE_PATH/${IMAGE}.log" 2>/dev/null | cut -d: -f2- | cut -d, -f3)"
    if [[ -n "$st" ]]; then
        counts[$st]=$(( ${counts[$st]:-0} + 1 ))
        rows=$((rows + 1))
    fi
done
incomplete=$(( total - rows ))

echo
echo "Done ($total crates). Results CSV: $CSV"
for st in success test_failed build_failed fetch_failed; do
    echo "  $st: ${counts[$st]:-0}"
done
if (( incomplete > 0 )); then
    echo "  incomplete (killed / timeout / srun error, no row): $incomplete -- see those crates' .log"
fi

# Non-zero exit if any job failed to even complete (distinct from build/test
# failures, which are recorded in the CSV as a normal result).
if (( fail > 0 )); then
    exit 1
fi


