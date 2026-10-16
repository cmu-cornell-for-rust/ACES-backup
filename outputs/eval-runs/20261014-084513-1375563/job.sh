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
            --env EV_TEST_THREADS="$TEST_THREADS" \
            --env EV_TEST_TIMEOUT="$TEST_TIMEOUT" \
            --env EV_MIRIFLAGS="$MIRIFLAGS_ALL" \
            --env EV_BSAN_OPTIONS="$BSAN_OPTIONS_ALL" \
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
