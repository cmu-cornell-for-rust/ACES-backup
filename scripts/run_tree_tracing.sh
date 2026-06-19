#!/usr/bin/env bash
#
# Usage: run_tree_tracing.sh [image] [walltime] [tracing_dir]
#
#   [image]       image/SIF name under the group containers dir used to run the
#                 prebuilt analysis binary. Default: rust (the binary is built in,
#                 and runs in, this container).
#   [walltime]    per-job walltime, HH or HH:MM (passed to run_job.sh). Default: 60.
#   [tracing_dir] directory whose subdirectories are per-crate tracing outputs
#                 (events-*, gzipped). Default: $OUTPUTS/tracing.
#
# Parallel companion to run_miri_dataset.sh, but for the post-hoc tree_tracing
# analysis instead of the Miri sweep. It:
#   1. Builds the tree_tracing binary ONCE inside the container (unless a fresh
#      ./tree_tracing.bin already exists; force a rebuild with REBUILD=1).
#   2. Launches ONE SLURM job per crate via run_job.sh -- at most MAX_PARALLEL
#      (default 40) in flight -- each running `tree_tracing.bin <crate_dir>`, which
#      reduces that crate's tracing output to a single CSV row. The binary reads
#      the gzipped events-* files in place (it gunzips them in memory),
#      so nothing is unzipped to disk. Each job's stdout+stderr goes to
#      "<crate_dir>/tree_tracing.log".
#   3. After every job finishes, collects the CSVHEADER:/CSVROW: lines the binary
#      printed into each log and writes one combined CSV at
#      $OUTPUTS/tree_tracing-<basename tracing_dir>.csv.
#
# Each per-crate job ALSO writes that crate's tree-size distribution
# (output_tree_size_dist_<crate>.csv) into the crate's own tracing dir, next to
# its inputs. (Writing there relies on the same /scratch bind being read-write.)
#
# NOTE: the run_job.sh launchers are long-lived foreground processes, so run this
# under tmux/nohup if the sweep will outlast your SSH session.
#
# NOTE: per-crate jobs read <crate_dir> by absolute path from inside the container.
# This relies on the cluster's Singularity config auto-binding /scratch (true on
# this HPC, where everything already lives under /scratch/group). The binary
# itself is reached via /work (run_job binds the launch dir), so only the data
# read depends on the auto-bind.
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
OUTPUTS_DIR="$GROUP/outputs"
TREE_TRACING_SRC="$GROUP/scripts/analysis/tree_tracing"   # cargo project
BIN_NAME="tree_tracing.bin"                              # built artifact under SRC
MEM="${MEM:-64G}"            # per-crate analysis job memory
BUILD_MEM="${BUILD_MEM:-8G}" # the one-off build job needs far less
MAX_PARALLEL="${MAX_PARALLEL:-40}"   # max jobs in flight at once (QOS MaxJobsPU=40)

# ── Args ──────────────────────────────────────────────────────────────────--
IMAGE_ARG="${1:-rust}"
WALLTIME="${2:-60}"
TRACING_DIR="${3:-$OUTPUTS_DIR/tracing}"

IMAGE="$(basename "${IMAGE_ARG%.sif}")"
TRACING_NAME="$(basename "$TRACING_DIR")"
CSV="$OUTPUTS_DIR/tree_tracing-${TRACING_NAME}.csv"
BIN="$TREE_TRACING_SRC/$BIN_NAME"

# ── Validate ──────────────────────────────────────────────────────────────--
[[ -x "$RUN_JOB" ]] \
    || { echo "Error: run_job.sh not executable at $RUN_JOB" >&2; exit 1; }
[[ -f "$CONTAINERS_DIR/$IMAGE.sif" ]] \
    || { echo "Error: image not found at $CONTAINERS_DIR/$IMAGE.sif" >&2; exit 1; }
[[ -f "$TREE_TRACING_SRC/Cargo.toml" ]] \
    || { echo "Error: tree_tracing project not found at $TREE_TRACING_SRC" >&2; exit 1; }
[[ -d "$TRACING_DIR" ]] \
    || { echo "Error: tracing dir not found: $TRACING_DIR" >&2; exit 1; }

# ── Collect crate dirs ──────────────────────────────────────────────────────
CRATE_DIRS=()
for d in "$TRACING_DIR"/*/; do
    [[ -d "$d" ]] || continue
    CRATE_DIRS+=("${d%/}")
done
[[ ${#CRATE_DIRS[@]} -gt 0 ]] \
    || { echo "Error: no crate subdirectories in $TRACING_DIR" >&2; exit 1; }

echo "Image:    $IMAGE"
echo "Walltime: $WALLTIME   Mem: $MEM"
echo "Tracing:  $TRACING_DIR"
echo "Crates:   ${#CRATE_DIRS[@]}"
echo "Results:  $CSV"
echo

# ── Build the analysis binary once, inside the container ──────────────────────
# CARGO_TARGET_DIR is redirected by run_job.sh into per-job scratch (wiped on
# exit), so we copy the freshly built binary to a stable path under /work (==
# the tree_tracing project dir, bound by absolute path) before the job returns.
if [[ -f "$BIN" && -z "${REBUILD:-}" ]]; then
    echo "Using existing binary: $BIN  (set REBUILD=1 to rebuild)"
else
    echo "Building tree_tracing binary in container..."
    BUILD_CMD='cargo build --release && cp "$CARGO_TARGET_DIR/release/tree_tracing" "./'"$BIN_NAME"'"'
    (
        cd "$TREE_TRACING_SRC"
        "$RUN_JOB" -J tree_tracing-build "$IMAGE" "$WALLTIME" "$BUILD_MEM" -- "$BUILD_CMD"
    )
    [[ -f "$BIN" ]] || { echo "Error: build did not produce $BIN" >&2; exit 1; }
    echo "Built: $BIN"
fi
echo

# ── Launch jobs, at most MAX_PARALLEL in flight at once ──────────────────────
pids=()        # every launcher pid (for teardown on interrupt)
fail=0         # launchers that exited non-zero (infra / analysis errors)
inflight=0     # launched-but-not-yet-reaped count, drives the throttle
total=${#CRATE_DIRS[@]}
i=0

# On Ctrl-C / TERM, tear down whatever is still running (releasing the srun
# allocations) instead of leaving orphaned jobs behind.
cleanup() {
    trap - INT TERM
    [[ ${#pids[@]} -gt 0 ]] && kill "${pids[@]}" 2>/dev/null || true
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
    JOBNAME="tt-${CRATE}"
    LOGFILE="$CRATE_PATH/tree_tracing.log"
    i=$((i + 1))

    # The binary lives at /work/$BIN_NAME (we launch run_job from the project
    # dir), and reads the crate's tracing files from its absolute path. It prints
    # CSVHEADER:/CSVROW: to stdout, which run_job captures into $LOGFILE.
    CMD="./$BIN_NAME '$CRATE_PATH'"

    # Wait for a free slot before launching the next crate.
    if (( inflight >= MAX_PARALLEL )); then
        reap_one
    fi

    (
        cd "$TREE_TRACING_SRC" || exit 1
        "$RUN_JOB" -J "$JOBNAME" "$IMAGE" "$WALLTIME" "$MEM" -- "$CMD"
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

# ── Collect CSVHEADER:/CSVROW: lines from each job log into the combined CSV ──
mkdir -p "$OUTPUTS_DIR"
: > "$CSV"
header_written=0
rows=0
missing=0
for CRATE_PATH in "${CRATE_DIRS[@]}"; do
    LOGFILE="$CRATE_PATH/tree_tracing.log"
    if (( header_written == 0 )); then
        hdr="$(grep -m1 '^CSVHEADER:' "$LOGFILE" 2>/dev/null | sed 's/^CSVHEADER://')"
        if [[ -n "$hdr" ]]; then
            printf '%s\n' "$hdr" >> "$CSV"
            header_written=1
        fi
    fi
    row="$(grep -m1 '^CSVROW:' "$LOGFILE" 2>/dev/null | sed 's/^CSVROW://')"
    if [[ -n "$row" ]]; then
        printf '%s\n' "$row" >> "$CSV"
        rows=$((rows + 1))
    else
        missing=$((missing + 1))
    fi
done

echo
echo "Done ($total crates). Combined CSV: $CSV"
echo "  rows written: $rows"
if (( missing > 0 )); then
    echo "  no row (killed / timeout / error): $missing -- see those crates' tree_tracing.log"
fi

# Non-zero exit if any job failed to complete.
if (( fail > 0 )); then
    exit 1
fi

