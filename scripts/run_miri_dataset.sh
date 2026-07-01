#!/usr/bin/env bash
#
# Usage: run_dataset.sh <image> <walltime> <dataset> [miriflags]
#
#   <image>       image/SIF name under the group containers dir (e.g. base, rust).
#                 The `rust` image runs `cargo test`; anything else runs Miri.
#   <walltime>    per-job walltime, HH or HH:MM (passed straight to run_job.sh).
#   <dataset>     folder under the group datasets dir holding crate subdirectories.
#   [miriflags]   optional extra -Z Miri flags appended to the built-in set
#                 (e.g. "-Zmiri-strict-provenance -Zmiri-symbolic-alignment-check").
#                 Added to MIRIFLAGS on both the compile and run phase. Ignored
#                 for the `rust` image.
#
# Launches ONE SLURM job per crate via run_job.sh, keeping at most MAX_PARALLEL
# (default 40, override with the MAX_PARALLEL env var) running at once -- the
# `normal` QOS allows 40 concurrent jobs. Each job runs with 16G memory, is
# named "<crate>-<image>", writes its full stdout+stderr to "<crate>/<image>.log",
# and cleans up its per-job scratch on the way out. A row per crate
# (build,crate,status,compile_seconds,run_seconds,tests,timestamp,job_id) is
# appended to /scratch/group/p.cis260229.000/outputs/<image>-<dataset>.csv, with
# concurrent writes serialized by a lock. compile_seconds/run_seconds time the
# (--no-run) build and the execution separately. tests is the number of tests
# executed (summed across every "running N tests" line in the run output, i.e.
# unit + integration + doc tests); passed is how many of those passed (summed
# across the "test result:" lines). Both are 0 when nothing ran. status is one of: success,
# test_failed (compiled, tests/Miri failed), build_failed (compile error),
# fetch_failed (deps wouldn't download). The orchestrator waits for every job to
# finish, then exits, printing a count of each status.
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
MEM="16G"
MAX_PARALLEL="${MAX_PARALLEL:-40}"   # max jobs in flight at once (QOS MaxJobsPU=40)

# Miri flags used for every Miri image (Tree Borrows is the borrow model).
MIRI_COMMON="-Zmiri-disable-alignment-check -Zmiri-disable-data-race-detector -Zmiri-ignore-leaks -Zmiri-tree-borrows"

# ── Args ──────────────────────────────────────────────────────────────────--
if [[ $# -lt 3 || $# -gt 4 ]]; then
    echo "Usage: $0 <image> <walltime> <dataset> [miriflags]" >&2
    echo "  <image>     image/SIF name under $CONTAINERS_DIR (e.g. base, rust)" >&2
    echo "  <walltime>  per-job walltime, HH or HH:MM" >&2
    echo "  <dataset>   folder under $DATASETS_ROOT holding crate subdirectories" >&2
    echo "  [miriflags] optional extra -Z Miri flags appended to the built-in set" >&2
    exit 1
fi

IMAGE_ARG="$1"
WALLTIME="$2"
DATASET="$3"
EXTRA_MIRIFLAGS="${4:-}"   # extra -Z Miri flags, appended to MIRI_COMMON

# Full flag set for this run: the built-in common flags plus any extras.
MIRIFLAGS_ALL="$MIRI_COMMON${EXTRA_MIRIFLAGS:+ $EXTRA_MIRIFLAGS}"

# Normalized image name (strip any dir + .sif) for the job name and rust check.
IMAGE="$(basename "${IMAGE_ARG%.sif}")"
DATASET_DIR="$DATASETS_ROOT/$DATASET"
CSV="$OUTPUTS_DIR/${IMAGE}-${DATASET}.csv"

# ── Validate ──────────────────────────────────────────────────────────────--
[[ -x "$RUN_JOB" ]] \
    || { echo "Error: run_job.sh not executable at $RUN_JOB" >&2; exit 1; }
[[ -f "$CONTAINERS_DIR/$IMAGE.sif" ]] \
    || { echo "Error: image not found at $CONTAINERS_DIR/$IMAGE.sif" >&2; exit 1; }
[[ -d "$DATASET_DIR" ]] \
    || { echo "Error: dataset dir not found: $DATASET_DIR" >&2; exit 1; }

# ── Collect crate dirs ──────────────────────────────────────────────────────
CRATE_DIRS=()
for d in "$DATASET_DIR"/*/; do
    [[ -d "$d" ]] || continue
    CRATE_DIRS+=("${d%/}")
done
[[ ${#CRATE_DIRS[@]} -gt 0 ]] \
    || { echo "Error: no crate subdirectories in $DATASET_DIR" >&2; exit 1; }

# ── Per-image compile + run commands ─────────────────────────────────────────
# The `rust` image runs the normal suite; every other image runs under Miri with
# Tree Borrows. COMPILE_CMD (--no-run) does all the building; RUN_CMD then only
# executes, so the two phases can be timed separately and cleanly.
if [[ "$IMAGE" == "rust" ]]; then
    COMPILE_CMD='cargo test --no-run'
    RUN_CMD='cargo test'
elif [[ "$IMAGE" == *"tracing"* ]]; then
    COMPILE_CMD="MIRI_TRACING=1 RUSTC_LOG=miri=trace MIRIFLAGS=\"$MIRIFLAGS_ALL\" cargo miri test --no-run"
    RUN_CMD="MIRI_TRACING=1 RUSTC_LOG=miri=trace MIRIFLAGS=\"$MIRIFLAGS_ALL\" cargo miri test 2>/dev/null"
else
    COMPILE_CMD="MIRIFLAGS=\"$MIRIFLAGS_ALL\" cargo miri test --no-run"
    RUN_CMD="MIRIFLAGS=\"$MIRIFLAGS_ALL\" cargo miri test"
fi

echo "Image:    $IMAGE"
echo "Walltime: $WALLTIME   Mem: $MEM"
echo "Dataset:  $DATASET_DIR"
echo "Crates:   ${#CRATE_DIRS[@]}"
[[ "$IMAGE" != "rust" ]] && echo "MIRIFLAGS: $MIRIFLAGS_ALL"
echo "Results:  $CSV"
echo

# Results CSV (appended across runs; header written once). Lives on group
# scratch, but all writers are this script's launcher subshells on this login
# node, so we serialize appends with an flock on a node-local lock file.
mkdir -p "$OUTPUTS_DIR"
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
status=""
cms=0
rms=0
tests=0
passed=0
cargo clean || true
rm -f trace* events-* 2>/dev/null || true
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
    # (Only stdout is redirected, so any embedded "2>/dev/null" in RUN_CMD --
    # e.g. the tracing image -- keeps suppressing stderr as intended.)
    runlog="\$(mktemp)"
    ${RUN_CMD} > "\$runlog"; rc=\$?
    cat "\$runlog"
    if [ "\$rc" -eq 0 ]; then status=success; else status=test_failed; fi
    rms=\$(( \$(date +%s%3N) - rstart ))
    # Sum every "running N tests" line (unit + integration + doc test binaries).
    tests=\$(grep -oE '^running [0-9]+ test' "\$runlog" | grep -oE '[0-9]+' | awk '{s+=\$1} END{print s+0}')
    # Sum the "N passed" from each "test result:" summary line.
    passed=\$(grep -oE 'test result:.* [0-9]+ passed' "\$runlog" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+' | awk '{s+=\$1} END{print s+0}')
    rm -f "\$runlog"
fi
compile=\$(printf '%d.%03d' \$(( cms / 1000 )) \$(( cms % 1000 )))
run=\$(printf '%d.%03d' \$(( rms / 1000 )) \$(( rms % 1000 )))
ts=\$(date -u +'%Y-%m-%dT%H:%M:%SZ')
jobid="\$(basename "\${CARGO_HOME%/home}")"; jobid="\${jobid#cargo-}"
echo "result: ${CRATE} (${IMAGE}) -> \$status (compile \${cms}ms, run \${rms}ms)"
echo "CSVROW:${IMAGE},${CRATE},\$status,\$compile,\$run,\$tests,\$passed,\$ts,\$jobid"
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
        if [[ "$IMAGE" == *"tracing"* ]]; then
            TRACE_OUT="$OUTPUTS_DIR/tracing/$CRATE"
            mkdir -p "$TRACE_OUT"
            for f in trace* events-*; do
                [[ -e "$f" ]] && gzip "$f" && mv "${f}.gz" "$TRACE_OUT/"
            done
        fi
        row="$(grep -m1 '^CSVROW:' "$LOGFILE" 2>/dev/null | cut -d: -f2-)"
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
    st="$(grep -m1 '^CSVROW:' "$CRATE_PATH/${IMAGE}.log" 2>/dev/null | cut -d: -f2- | cut -d, -f3)"
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

