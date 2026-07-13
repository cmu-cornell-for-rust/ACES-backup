#!/bin/bash
set -u
RUNDIR="$1"
JOBIDX="$2"
source "$RUNDIR/config.env"

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
            --env HF_RUNS="$RUNS" --env HF_WARMUP="$WARMUP" \
            --env HF_MIRIFLAGS="$MIRIFLAGS_ALL" \
            --env HF_BSAN_OPTIONS="$BSAN_OPTIONS_ALL" \
            --env HF_JOBID="${SLURM_JOB_ID}.${tid}" \
            --env http_proxy="${http_proxy:-}"   --env https_proxy="${https_proxy:-}" \
            --env HTTP_PROXY="${HTTP_PROXY:-}"   --env HTTPS_PROXY="${HTTPS_PROXY:-}" \
            "$SIF_ABS" bash "$RUNDIR/inner.sh" > "$log" 2>&1
        grep -a '^CSVROW:' "$log" | cut -d: -f2- >> "$shard"
        rm -rf "$scr"
    done < "$chunk"
}

for (( tid = 0; tid < TASKS; tid++ )); do
    worker "$tid" &
done
wait
