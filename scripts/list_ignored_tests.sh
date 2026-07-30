#!/usr/bin/env bash
#
# Usage: list_ignored_tests.sh [--ignore FILE] <walltime> <dataset>
#
#   --ignore FILE optional file of crate names to skip, one per line (blank
#                 lines and #-comments ignored). Names match the crate directory
#                 basenames under the dataset (e.g. bstr-1.12.1).
#   <walltime>    per-job walltime, HH or HH:MM (passed straight to run_job.sh).
#   <dataset>     folder under the group datasets dir holding crate subdirectories.
#
# Companion to list_tests.sh: instead of the tests Miri *runs*, this collects the
# tests Miri does NOT run, which crates suppress two different ways:
#
#   #[cfg_attr(miri, ignore)]  the test still exists in the Miri build, it is
#                              just marked ignored -- it shows up in the Miri
#                              listing with "ignore": true.
#   #[cfg(not(miri))]          the test is compiled out entirely, so it never
#                              appears in the Miri listing at all. The only way
#                              to see it is to list the tests again *without*
#                              Miri and diff the two name sets.
#
# So for every crate we run (in the stock `miri` image) both
#     cargo test      --tests -- --list --format=json -Zunstable-options
#     cargo miri test --tests -- --list --format=json -Zunstable-options
# and take the union of
#     (a) Miri-listed tests with "ignore": true   -- cfg_attr(miri, ignore) and
#         plain #[ignore]; both are tests Miri skips.
#     (b) host-listed names absent from the Miri listing -- cfg(not(miri)).
# --tests covers unit + integration test binaries but NOT doc tests --
# deliberately: doc-test names embed the item's generics (e.g.
# "arrayvec::ArrayVec<T,CAP> (line 748)"), whose commas would corrupt the CSV,
# while binary test names are Rust paths and can never contain a comma.
#
# Appends one row per crate (crate,n_attr_ignored,n_cfg_out,ignored_tests) to
# /scratch/group/p.cis260229.000/outputs/ignore_list-<dataset>.csv, with the
# ignored test names in the last column joined by ';' (empty when Miri runs
# every test). Names are deduplicated, so a test name appearing in two test
# binaries counts once -- and if one copy is ignored under Miri while the other
# runs, the name still lands in the ignored column (listings carry no binary
# qualifier, so the two are indistinguishable here).
#
# Crates where either listing fails (fetch/build error) get no row -- check
# "<crate>/list-ignored.log". Note that bucket (b) is a set difference between
# two builds, so any *other* cfg difference between the host and Miri builds
# would also land there; in practice cfg(miri) is the only one that differs.
# Launches ONE SLURM job per crate via run_job.sh, keeping at most MAX_PARALLEL
# (default 40, override with the MAX_PARALLEL env var) running at once.
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
CSV="$OUTPUTS_DIR/ignore_list-${DATASET}.csv"

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
    echo "crate,n_attr_ignored,n_cfg_out,ignored_tests" > "$CSV"
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
    JOBNAME="${CRATE}-list-ignored"
    LOGFILE="$CRATE_PATH/list-ignored.log"
    i=$((i + 1))

    # Command that runs INSIDE the container, with /work == the crate dir.
    # CARGO_HOME / CARGO_TARGET_DIR are injected by run_job.sh and live under
    # the per-job scratch dir, so deleting them on exit reclaims that scratch.
    # --list emits one JSON line per discovered test on stdout (build noise goes
    # to stderr, i.e. the log). We list twice -- host first (cheaper, and it
    # writes to a different target subdir than cargo-miri, so the two builds do
    # not clobber each other) -- then union the "ignore": true names with the
    # host-minus-miri names and join with ';'. LC_ALL=C keeps the sorts and
    # `comm` on the same collation. A CSVROW line is only emitted when both
    # listings succeed. "\$" values expand inside the container; the rest expand
    # here, now.
    read -r -d '' CMD <<EOF || true
trap 'rm -rf "\$CARGO_HOME" "\$CARGO_TARGET_DIR" 2>/dev/null || true' EXIT
export LC_ALL=C
cargo clean || true
if ! cargo fetch; then
    echo "result: ${CRATE} -> fetch_failed"
    exit 1
fi
hostlog="\$(mktemp)"
if ! cargo test --tests -- --list --format=json -Zunstable-options > "\$hostlog"; then
    echo "result: ${CRATE} -> host_list_failed"
    rm -f "\$hostlog"
    exit 1
fi
mirilog="\$(mktemp)"
if ! cargo miri test --tests -- --list --format=json -Zunstable-options > "\$mirilog"; then
    echo "result: ${CRATE} -> miri_list_failed"
    rm -f "\$hostlog" "\$mirilog"
    exit 1
fi
host_all="\$(mktemp)"; miri_all="\$(mktemp)"; miri_ign="\$(mktemp)"; cfg_out="\$(mktemp)"
namesof() { sed -E 's/.*"name": *"([^"]*)".*/\1/' | sed '/^\$/d' | sort -u; }
grep -a '"type": *"test"' "\$hostlog" | namesof > "\$host_all"
grep -a '"type": *"test"' "\$mirilog" | namesof > "\$miri_all"
grep -a '"ignore": *true'  "\$mirilog" | namesof > "\$miri_ign"
# #[cfg(not(miri))] tests are compiled out of the Miri build, so they show up
# only as host names with no Miri counterpart.
comm -23 "\$host_all" "\$miri_all" > "\$cfg_out"
n_attr="\$(wc -l < "\$miri_ign" | tr -d ' ')"
n_cfg="\$(wc -l < "\$cfg_out" | tr -d ' ')"
ignored="\$(cat "\$miri_ign" "\$cfg_out" | sort -u | paste -sd';' -)"
n_host="\$(wc -l < "\$host_all" | tr -d ' ')"
rm -f "\$hostlog" "\$mirilog" "\$host_all" "\$miri_all" "\$miri_ign" "\$cfg_out"
echo "result: ${CRATE} -> success (\$n_host host tests, \$n_attr attr-ignored, \$n_cfg cfg'd out)"
echo "CSVROW:${CRATE},\$n_attr,\$n_cfg,\$ignored"
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
# Row fields: crate,n_attr_ignored,n_cfg_out,ignored_tests -- the test list is
# ';'-joined and last, so a plain comma cut is safe.
rows=0
with_ignored=0
attr_total=0
cfg_total=0
for CRATE_PATH in "${CRATE_DIRS[@]}"; do
    row="$(grep -am1 '^CSVROW:' "$CRATE_PATH/list-ignored.log" 2>/dev/null | cut -d: -f2-)"
    if [[ -n "$row" ]]; then
        rows=$((rows + 1))
        n_attr="$(cut -d, -f2 <<<"$row")"
        n_cfg="$(cut -d, -f3 <<<"$row")"
        attr_total=$((attr_total + n_attr))
        cfg_total=$((cfg_total + n_cfg))
        [[ -n "$(cut -d, -f4- <<<"$row")" ]] && with_ignored=$((with_ignored + 1))
    fi
done
incomplete=$(( total - rows ))

echo
echo "Done ($total crates). Results CSV: $CSV"
echo "  listed: $rows  (with >=1 ignored test: $with_ignored)"
echo "  ignored tests: $attr_total via #[ignore]/#[cfg_attr(miri, ignore)], $cfg_total via #[cfg(not(miri))]"
if (( incomplete > 0 )); then
    echo "  no row (fetch/build/list failure, killed, timeout): $incomplete -- see those crates' list-ignored.log"
fi

if (( fail > 0 )); then
    exit 1
fi
