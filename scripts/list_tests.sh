#!/usr/bin/env bash
#
# Usage: list_tests.sh [--ignore FILE] <walltime> <dataset>
#
#   --ignore FILE optional file of crate names to skip, one per line (blank
#                 lines and #-comments ignored). Names match the crate directory
#                 basenames under the dataset (e.g. bstr-1.12.1).
#   <walltime>    per-job walltime, HH or HH:MM (passed straight to run_job.sh).
#   <dataset>     folder under the group datasets dir holding crate subdirectories.
#
# For every crate, runs (in the stock `miri` image)
#     cargo miri test --tests -- --list --format=json -Zunstable-options
# which builds the test binaries and emits one JSON line per discovered test,
# then collects the names of tests marked "ignore": false, i.e. the tests that
# actually run. --tests covers unit + integration test binaries but NOT doc
# tests -- deliberately: doc-test names embed the item's generics (e.g.
# "arrayvec::ArrayVec<T,CAP> (line 748)"), whose commas would corrupt the CSV,
# while binary test names are Rust paths and can never contain a comma. Also runs `cargo scan` (cargo-scan, the PLSysSec crate auditor)
# on the crate and checks its effect list for FFI effects ("[FFI Call]" /
# "[FFI Declaration]" rows). Appends one row per crate
# (crate,tests,contains_ffi) to
# /scratch/group/p.cis260229.000/outputs/tests-<dataset>.csv, with the
# test names in the second column joined by ';' (empty when the crate has no
# runnable tests) and contains_ffi one of true/false/scan_failed.
# Crates whose listing fails (fetch/build error) get no row --
# check "<crate>/list-tests.log". Launches ONE SLURM job per crate via
# run_job.sh, keeping at most MAX_PARALLEL (default 40, override with the
# MAX_PARALLEL env var) running at once.
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
IMAGE="miri"                         # always the stock Miri image (miri.def, no ref)

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

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 [--ignore FILE] <walltime> <dataset>" >&2
    echo "  --ignore FILE  crate names to skip, one per line" >&2
    echo "  <walltime>  per-job walltime, HH or HH:MM" >&2
    echo "  <dataset>   folder under $DATASETS_ROOT holding crate subdirectories" >&2
    exit 1
fi

WALLTIME="$1"
DATASET="$2"

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

DATASET_DIR="$DATASETS_ROOT/$DATASET"
CSV="$OUTPUTS_DIR/tests-${DATASET}.csv"

# ── Validate ──────────────────────────────────────────────────────────────--
[[ -x "$RUN_JOB" ]] \
    || { echo "Error: run_job.sh not executable at $RUN_JOB" >&2; exit 1; }
[[ -f "$CONTAINERS_DIR/$IMAGE.sif" ]] \
    || { echo "Error: image not found at $CONTAINERS_DIR/$IMAGE.sif" >&2; exit 1; }
[[ -d "$DATASET_DIR" ]] \
    || { echo "Error: dataset dir not found: $DATASET_DIR" >&2; exit 1; }

# ── Collect crate dirs ──────────────────────────────────────────────────────
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

echo "Image:    $IMAGE"
echo "Walltime: $WALLTIME   Mem: $MEM"
echo "Dataset:  $DATASET_DIR"
echo "Crates:   ${#CRATE_DIRS[@]}${IGNORE_FILE:+  (skipped $skipped via $IGNORE_FILE)}"
echo "Results:  $CSV"
echo

# Results CSV (appended across runs; header written once). Lives on group
# scratch, but all writers are this script's launcher subshells on this login
# node, so we serialize appends with an flock on a node-local lock file.
mkdir -p "$OUTPUTS_DIR"
if [[ ! -f "$CSV" ]]; then
    echo "crate,tests,contains_ffi" > "$CSV"
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
    JOBNAME="${CRATE}-list-tests"
    LOGFILE="$CRATE_PATH/list-tests.log"
    i=$((i + 1))

    # Command that runs INSIDE the container, with /work == the crate dir.
    # CARGO_HOME / CARGO_TARGET_DIR are injected by run_job.sh and live under
    # the per-job scratch dir, so deleting them on exit reclaims that scratch.
    # --list emits one JSON line per discovered test on stdout (build noise goes
    # to stderr, i.e. the log); tests with "ignore": false are collected and
    # joined with ';'. cargo scan's CSV effect list is checked for "[FFI"
    # (matches both "[FFI Call]" and "[FFI Declaration]"); a scan failure is
    # recorded as scan_failed rather than dropping the row, since the test list
    # is still valid. A CSVROW line is only emitted when listing succeeds.
    # "\$" values expand inside the container; the rest expand here, now.
    read -r -d '' CMD <<EOF || true
trap 'rm -rf "\$CARGO_HOME" "\$CARGO_TARGET_DIR" 2>/dev/null || true' EXIT
cargo clean || true
if ! cargo fetch; then
    echo "result: ${CRATE} -> fetch_failed"
    exit 1
fi
listlog="\$(mktemp)"
if ! cargo miri test --tests -- --list --format=json -Zunstable-options > "\$listlog"; then
    echo "result: ${CRATE} -> list_failed"
    rm -f "\$listlog"
    exit 1
fi
tests="\$(grep -a '"ignore": false' "\$listlog" | sed -E 's/.*"name": *"([^"]*)".*/\1/' | paste -sd';' -)"
n="\$(grep -ac '"ignore": false' "\$listlog" || true)"
rm -f "\$listlog"
ffi=scan_failed
scanlog="\$(mktemp)"
if cargo scan . > "\$scanlog"; then
    if grep -aq '\[FFI' "\$scanlog"; then ffi=true; else ffi=false; fi
fi
rm -f "\$scanlog"
echo "result: ${CRATE} -> success (\$n tests, ffi=\$ffi)"
echo "CSVROW:${CRATE},\$tests,\$ffi"
EOF

    # Wait for a free slot before launching the next crate.
    if (( inflight >= MAX_PARALLEL )); then
        reap_one
    fi

    # Subshell cd's into the crate so run_job.sh binds it as /work. All output
    # (run_job.sh + srun + the in-container build/list) lands in the crate log;
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

# ── Summary (from each crate's emitted row) ──────────────────────────────────
# Row fields: crate,tests,contains_ffi -- the tests field is ';'-joined, so a
# plain comma cut is safe.
rows=0
with_tests=0
with_ffi=0
scan_failed=0
for CRATE_PATH in "${CRATE_DIRS[@]}"; do
    row="$(grep -am1 '^CSVROW:' "$CRATE_PATH/list-tests.log" 2>/dev/null | cut -d: -f2-)"
    if [[ -n "$row" ]]; then
        rows=$((rows + 1))
        [[ -n "$(cut -d, -f2 <<<"$row")" ]] && with_tests=$((with_tests + 1))
        case "$(cut -d, -f3 <<<"$row")" in
            true)        with_ffi=$((with_ffi + 1)) ;;
            scan_failed) scan_failed=$((scan_failed + 1)) ;;
        esac
    fi
done
incomplete=$(( total - rows ))

echo
echo "Done ($total crates). Results CSV: $CSV"
echo "  listed: $rows  (with >=1 runnable test: $with_tests, with FFI: $with_ffi, scan failed: $scan_failed)"
if (( incomplete > 0 )); then
    echo "  no row (fetch/build/list failure, killed, timeout): $incomplete -- see those crates' list-tests.log"
fi

if (( fail > 0 )); then
    exit 1
fi

