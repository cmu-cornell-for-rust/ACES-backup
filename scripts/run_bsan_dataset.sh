#!/usr/bin/env bash
#
# Usage: run_bsan_dataset.sh [--ignore FILE] [--tests FILE] [--no-ffi] <mode> <image> <walltime> <dataset> [extra]
#
#   --ignore FILE  optional file of crate names to skip, one per line (blank
#                  lines and #-comments ignored). Names match the crate
#                  directory basenames under the dataset (e.g. bstr-1.12.1).
#   --tests FILE      tests CSV (crate,tests,contains_ffi -- as produced by
#                     list_tests.sh). Default: <outputs>/tests-<dataset>.csv
#   --no-ffi          only run crates whose contains_ffi column is exactly
#                     "false" (both "true" and "scan_failed" are skipped)
#   <mode>      miri | bsan | rust -- which tool runs the tests:
#                 miri: MIRIFLAGS=<common+extra> cargo miri test
#                 bsan: BSAN_OPTIONS=<common+extra> cargo bsan test
#                 rust: plain cargo test (extra ignored)
#   <image>     image/SIF name under the group containers dir (e.g. miri, rust,
#               bsan). Mode and image are separate so variant images (e.g. a
#               patched miri) can still be driven in miri mode.
#   <walltime>  per-job walltime, HH or HH:MM (passed straight to run_job.sh).
#   <dataset>   folder under the group datasets dir holding crate subdirectories.
#   [extra]     mode-specific extras appended to the built-in set on both the
#               compile and run phase: -Z Miri flags (miri, space-separated,
#               e.g. "-Zmiri-strict-provenance") or BSAN_OPTIONS (bsan,
#               colon-separated, e.g. "opt1=val:opt2=val"). Ignored for rust.
#
# The tests CSV is the source of truth for what runs: a crate runs only if it is
# listed there with a non-empty tests column AND its dir exists under <dataset>.
# For each crate, ONLY the tests named in its row are run (passed as `--exact`
# filters), not the whole suite; doctests are excluded (--tests).
#
# Launches ONE SLURM job per selected crate via run_job.sh, keeping at most
# MAX_PARALLEL (default 40, override with the MAX_PARALLEL env var) running at
# once -- the `normal` QOS allows 40 concurrent jobs. Each job runs with 16G
# memory, is named "<crate>-<image>", writes its full stdout+stderr to
# "<crate>/<image>.log", and cleans up its per-job scratch on the way out. A row per crate
# (build,crate,status,compile_seconds,run_seconds,tests,passed,timestamp,job_id) is
# appended to /scratch/group/p.cis260229.000/outputs/<image>-<dataset>.csv, with
# concurrent writes serialized by a lock. compile_seconds/run_seconds time the
# (--no-run) build and the execution separately. tests is the number of tests
# executed (summed across every "running N tests" line in the run output, i.e.
# unit + integration + doc tests); passed is how many of those passed (summed
# across the "test result:" lines). Both are 0 when nothing ran. status is one of: success,
# test_failed (compiled, tests/tool failed), build_failed (compile error),
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

# Built-in per-mode option sets (same as run_miri_dataset / run_bench_dataset).
# stacktrace_max_len caps how many frames the bsan runtime records per stack
# trace; Tree Borrows is the borrow model on the Miri side.
MIRI_COMMON="-Zmiri-disable-alignment-check -Zmiri-disable-data-race-detector -Zmiri-ignore-leaks -Zmiri-tree-borrows"
BSAN_COMMON="stacktrace_max_len=32"

# ── Args ──────────────────────────────────────────────────────────────────--
# Pull the optional flags out from anywhere in the arg list, leaving the
# positional args behind.
IGNORE_FILE=""
TESTS_CSV=""
NO_FFI=0
POS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i|--ignore)
            [[ $# -ge 2 ]] || { echo "Error: $1 requires a FILE argument." >&2; exit 1; }
            IGNORE_FILE="$2"; shift 2 ;;
        --ignore=*)
            IGNORE_FILE="${1#*=}"; shift ;;
        --tests)
            [[ $# -ge 2 ]] || { echo "Error: $1 requires a FILE argument." >&2; exit 1; }
            TESTS_CSV="$2"; shift 2 ;;
        --tests=*)
            TESTS_CSV="${1#*=}"; shift ;;
        --no-ffi)
            NO_FFI=1; shift ;;
        *)
            POS+=("$1"); shift ;;
    esac
done
set -- ${POS[@]+"${POS[@]}"}

if [[ $# -lt 4 || $# -gt 5 ]]; then
    echo "Usage: $0 [--ignore FILE] [--tests FILE] [--no-ffi] <mode> <image> <walltime> <dataset> [extra]" >&2
    echo "  --ignore FILE  crate names to skip, one per line" >&2
    echo "  --tests FILE   tests CSV (crate,tests,contains_ffi -- as produced by" >&2
    echo "                 list_tests.sh). Default: $OUTPUTS_DIR/tests-<dataset>.csv" >&2
    echo "  --no-ffi       only run crates whose contains_ffi column is exactly" >&2
    echo "                 \"false\" (both \"true\" and \"scan_failed\" are skipped)" >&2
    echo "  <mode>      miri | bsan | rust -- which tool runs the tests" >&2
    echo "  <image>     image/SIF name under $CONTAINERS_DIR (e.g. miri, rust, bsan)" >&2
    echo "  <walltime>  per-job walltime, HH or HH:MM" >&2
    echo "  <dataset>   folder under $DATASETS_ROOT holding crate subdirectories" >&2
    echo "  [extra]     extra MIRIFLAGS (miri, space-separated) or BSAN_OPTIONS" >&2
    echo "              (bsan, colon-separated), appended to the built-in set" >&2
    exit 1
fi

MODE="$1"
IMAGE_ARG="$2"
WALLTIME="$3"
DATASET="$4"
EXTRA="${5:-}"   # mode-specific extras, appended to the built-in common set

case "$MODE" in miri|bsan|rust) ;; *)
    echo "Error: mode must be miri, bsan, or rust (got '$MODE')." >&2; exit 1 ;;
esac

# Default the tests CSV to the conventional per-dataset path when not given.
[[ -n "$TESTS_CSV" ]] || TESTS_CSV="$OUTPUTS_DIR/tests-${DATASET}.csv"

# Full per-mode option set for this run: the built-in common options plus any
# extras (space-separated -Z flags for Miri, colon-separated sanitizer-style
# options for bsan).
MIRIFLAGS_ALL=""
BSAN_OPTIONS_ALL=""
case "$MODE" in
    miri) MIRIFLAGS_ALL="$MIRI_COMMON${EXTRA:+ $EXTRA}" ;;
    bsan) BSAN_OPTIONS_ALL="$BSAN_COMMON${EXTRA:+:$EXTRA}" ;;
esac

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

# Normalized image name (strip any dir + .sif) for the job name and CSV/log names.
IMAGE="$(basename "${IMAGE_ARG%.sif}")"
DATASET_DIR="$DATASETS_ROOT/$DATASET"

# When extras are given, fold a filesystem-safe slug of them into the CSV name
# so runs with different flag/option sets land in separate files instead of
# appending to the same one. Non-alphanumerics collapse to single dashes. The
# dataset name always comes LAST.
CSV="$OUTPUTS_DIR/${IMAGE}-${DATASET}.csv"
if [[ -n "$EXTRA" && "$MODE" != "rust" ]]; then
    OPT_SLUG="$(printf '%s' "$EXTRA" | tr -c '[:alnum:]' '-' | sed 's/-\{1,\}/-/g; s/^-//; s/-$//')"
    CSV="$OUTPUTS_DIR/${IMAGE}-${OPT_SLUG}-${DATASET}.csv"
fi

# ── Validate ──────────────────────────────────────────────────────────────--
[[ -x "$RUN_JOB" ]] \
    || { echo "Error: run_job.sh not executable at $RUN_JOB" >&2; exit 1; }
[[ -f "$CONTAINERS_DIR/$IMAGE.sif" ]] \
    || { echo "Error: image not found at $CONTAINERS_DIR/$IMAGE.sif" >&2; exit 1; }
[[ -d "$DATASET_DIR" ]] \
    || { echo "Error: dataset dir not found: $DATASET_DIR" >&2; exit 1; }
[[ -f "$TESTS_CSV" ]] \
    || { echo "Error: tests CSV not found: $TESTS_CSV (--tests FILE?)" >&2; exit 1; }

# ── Select crates from the tests CSV ─────────────────────────────────────────
# The tests CSV is the source of truth for what runs: each row is
# crate,tests,contains_ffi (tests is ';'-joined and comma-free, per
# list_tests.sh). A crate runs only if it is listed here with a non-empty tests
# column and its dir exists under the dataset. CRATE_TESTS holds that crate's
# ';'-joined test names, which the per-crate command turns into `--exact`
# filters so ONLY the listed tests run (not the whole suite).
CRATE_DIRS=()
declare -A CRATE_TESTS=()
declare -A SEEN_CRATE=()
skipped=0; skip_ffi=0; skip_empty=0
MISSING=()
first=1
while IFS=, read -r crate tests ffi || [[ -n "$crate" ]]; do
    if (( first )); then first=0; [[ "$crate" == "crate" ]] && continue; fi
    crate="${crate//$'\r'/}"; ffi="${ffi//$'\r'/}"
    [[ -n "$crate" ]] || continue
    [[ -n "${SEEN_CRATE[$crate]:-}" ]] && continue
    SEEN_CRATE[$crate]=1
    if [[ -n "${IGNORE[$crate]:-}" ]]; then skipped=$((skipped + 1)); continue; fi
    if (( NO_FFI )) && [[ "$ffi" != "false" ]]; then skip_ffi=$((skip_ffi + 1)); continue; fi
    if [[ -z "$tests" ]]; then skip_empty=$((skip_empty + 1)); continue; fi
    if [[ ! -d "$DATASET_DIR/$crate" ]]; then MISSING+=("$crate"); continue; fi
    CRATE_DIRS+=("$DATASET_DIR/$crate")
    CRATE_TESTS[$crate]="$tests"
done < "$TESTS_CSV"

[[ ${#CRATE_DIRS[@]} -gt 0 ]] \
    || { echo "Error: no crates to run from $TESTS_CSV (after ignore/ffi/empty filters)" >&2; exit 1; }
if (( ${#MISSING[@]} > 0 )); then
    echo "Warning: ${#MISSING[@]} crate(s) in the tests CSV have no dir under $DATASET_DIR (skipped):" >&2
    printf '  %s\n' "${MISSING[@]}" >&2
fi

# ── Per-mode compile + run commands ──────────────────────────────────────────
# `rust` mode runs plain cargo; `miri` runs under Miri with Tree Borrows;
# `bsan` runs under BorrowSanitizer. COMPILE_CMD (--tests --no-run) does all
# the building (including bsan's first-use instrumented-sysroot setup and
# miri's sysroot build); RUN_PREFIX then only executes, and each crate's run
# appends `-- --exact <its listed tests>` so ONLY the tests named in the CSV
# run (see the loop). Using --tests limits building/running to unit +
# integration test binaries (doctests are excluded), matching how
# list_tests.sh enumerated them.
case "$MODE" in
    rust)
        COMPILE_CMD='cargo test --tests --no-run'
        RUN_PREFIX='cargo test --tests' ;;
    miri)
        COMPILE_CMD="MIRIFLAGS=\"$MIRIFLAGS_ALL\" cargo miri test --tests --no-run"
        RUN_PREFIX="MIRIFLAGS=\"$MIRIFLAGS_ALL\" cargo miri test --tests" ;;
    bsan)
        COMPILE_CMD="BSAN_OPTIONS=\"$BSAN_OPTIONS_ALL\" cargo bsan test --tests --no-run"
        RUN_PREFIX="BSAN_OPTIONS=\"$BSAN_OPTIONS_ALL\" cargo bsan test --tests" ;;
esac

echo "Mode:     $MODE   Image: $IMAGE"
echo "Walltime: $WALLTIME   Mem: $MEM"
echo "Dataset:  $DATASET_DIR"
echo "Tests:    $TESTS_CSV${NO_FFI:+  (--no-ffi)}"
echo "Crates:   ${#CRATE_DIRS[@]}${IGNORE_FILE:+  (skipped $skipped via $IGNORE_FILE)}"
[[ "$MODE" == "miri" ]] && echo "MIRIFLAGS: $MIRIFLAGS_ALL"
[[ "$MODE" == "bsan" ]] && echo "BSAN_OPTIONS: $BSAN_OPTIONS_ALL"
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

    # Build this crate's run command: only the tests listed for it in the CSV,
    # passed as exact filters (`-- --exact t1 t2 ...`). Test names from
    # list_tests.sh are Rust paths (no whitespace or single quotes), so
    # single-quoting each is safe against the container shell.
    TEST_FILTERS=""
    IFS=';' read -ra _tests <<< "${CRATE_TESTS[$CRATE]}"
    for t in ${_tests[@]+"${_tests[@]}"}; do
        [[ -n "$t" ]] && TEST_FILTERS+=" '$t'"
    done
    RUN_CMD="$RUN_PREFIX -- --exact$TEST_FILTERS"

    # Command that runs INSIDE the container, with /work == the crate dir.
    # CARGO_HOME / CARGO_TARGET_DIR are injected by run_job.sh and live under
    # the per-job scratch dir (named cargo-<SLURM_JOB_ID>), so deleting them on
    # exit reclaims that scratch, and the job id can be recovered from the path.
    # Phases are timed separately: COMPILE_CMD (--no-run) builds everything, then
    # RUN_CMD runs only this crate's listed tests -- so compile_seconds and
    # run_seconds are clean. A row is always emitted. status distinguishes
    # fetch / build / test failures.
    # "\$" values expand inside the container; the rest expand here, now.
    read -r -d '' CMD <<EOF || true
trap 'rm -rf "\$CARGO_HOME" "\$CARGO_TARGET_DIR" 2>/dev/null || true' EXIT
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


