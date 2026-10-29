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
# Node-local $TMPDIR (/tmp/job.$SLURM_JOB_ID): much lower small-file latency
# than /scratch for cargo builds. Only this node ever touches these dirs.
SCRATCH_BASE="${TMPDIR:-/tmp}"
NODE_TMP="${TMPDIR:-/tmp}/eval-$SLURM_JOB_ID"
mkdir -p "$SCRATCH_BASE" "$NODE_TMP"
echo 0 > "$NODE_TMP/next"
trap 'rm -rf "$SCRATCH_BASE/ev-$SLURM_JOB_ID-"* "$NODE_TMP" 2>/dev/null || true' EXIT

# download_crate <name-version> <into dir>: fetch the crates.io tarball and
# extract it to <into dir>/<name-version>/, as download_dataset.sh does. The
# name is everything up to the last hyphen before a digit. curl from the node,
# else from the image (which has it).
download_crate() {
    local c="$1" name url tmp rc
    name="${c%-[0-9]*}"
    url="https://static.crates.io/crates/$name/$name-${c#"$name"-}.crate"
    tmp="$2/.$c.crate"
    if command -v curl >/dev/null; then
        curl -fsSL -A "crate-downloader (CMU systems research; via crates.io)" \
            --retry 3 --retry-delay 2 -o "$tmp" "$url"
    else
        singularity exec --cleanenv --bind "$2" \
            --env https_proxy="${https_proxy:-}" --env HTTPS_PROXY="${HTTPS_PROXY:-}" \
            "$SIF_ABS" curl -fsSL -A "crate-downloader (CMU systems research; via crates.io)" \
            --retry 3 --retry-delay 2 -o "$tmp" "$url"
    fi && tar -xzf "$tmp" -C "$2" && [ -f "$2/$c/Cargo.toml" ]
    rc=$?
    rm -f "$tmp"
    return "$rc"
}

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

# killed_rows <crate> <shard> <rc> <log> <job id>: a status=killed row for each
# of the crate's tests that has no row yet, once its srun step was killed
# outright (step OOM, signal) and took inner.sh down with it. When only the
# test process was OOM-killed, inner.sh recorded it and this adds nothing.
killed_rows() {
    local etype=other why="srun step exited $3" ts
    if grep -q 'oom[-_]kill' "$4"; then
        etype=oom
        why="srun step OOM-killed at --mem-per-task ${MEM_PER_TASK}G"
    fi
    echo "--- step killed: $1 ($why) ---" >> "$4"
    ts=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
    # FILENAME, not NR == FNR: the shard may be empty.
    awk -F, -v b="$IMAGE" -v c="$1" \
        -v tail=",killed,,,$ts,$5,$etype,\"$why before this test got a row\"" '
        FILENAME == ARGV[1] { if ($1 == b && $2 == c) have[$3] = 1; next }
        !($0 in have) { print b "," c "," $0 tail }' \
        "$2" "$RUNDIR/lists/$1.txt" >> "$2"
}

worker() {
    local tid="$1"
    local shard="$RUNDIR/shards/shard-${JOBIDX}-${tid}.csv"
    local scr="$SCRATCH_BASE/ev-${SLURM_JOB_ID}-${tid}"
    local crate cdir log e b rc
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
        rm -rf "$scr/work" "$scr/target" "$scr/$crate"
        mkdir -p "$scr/target"
        if [ "$DOWNLOAD" = 1 ]; then
            # No dataset dir: the crate comes straight from crates.io into
            # this worker's scratch, and is removed with it.
            log="$RUNDIR/crate-logs/$crate/eval-${IMAGE}.log"
            mkdir -p "${log%/*}"
            if ! download_crate "$crate" "$scr" > "$log" 2>&1; then
                echo "$IMAGE,$crate,,fetch_failed,,,$(date -u +'%Y-%m-%dT%H:%M:%SZ'),${SLURM_JOB_ID}.${tid},other,\"crates.io download failed (see $log)\"" >> "$shard"
                echo "$crate" >> "$RUNDIR/done/done-${JOBIDX}-${tid}.txt"
                continue
            fi
            mv "$scr/$crate" "$scr/work"
        else
            # Private copy of the crate as /work, minus any target/ and logs, so
            # cargo's Cargo.lock write never touches the shared dataset dir.
            mkdir -p "$scr/work"
            for e in "$cdir"/*; do
                b="${e##*/}"
                case "$b" in target|*.log) continue ;; esac
                cp -a "$e" "$scr/work/"
            done
        fi
        # Each crate is its own job step, so it gets its own cgroup capped at
        # --mem-per-task: an OOM kills this crate only, never its neighbours
        # (which a shared job-wide pool would let it starve or take down).
        srun --exact --nodes=1 --ntasks=1 \
            --cpus-per-task="$CPUS_PER_TASK" --mem="${MEM_PER_TASK}G" \
            --kill-on-bad-exit=0 --job-name="$crate" \
        singularity exec --cleanenv --pwd /work \
            --bind "$scr" --bind "$RUNDIR" --bind "$scr/work:/work" \
            --env CARGO_HOME="$scr/home" \
            --env CARGO_TARGET_DIR="$scr/target" \
            --env CARGO_BUILD_JOBS="$CPUS_PER_TASK" \
            --env CARGO_TERM_COLOR=never \
            --env EV_BUILD="$IMAGE" --env EV_MODE="$MODE" \
            --env EV_CRATE="$crate" \
            --env EV_SHARD="$shard" \
            --env EV_TESTS="$RUNDIR/lists/$crate.txt" \
            --env EV_TEST_THREADS="$TEST_THREADS" \
            --env EV_TEST_TIMEOUT="$TEST_TIMEOUT" \
            --env EV_MIRIFLAGS="$MIRIFLAGS_ALL" \
            --env EV_BSAN_OPTIONS="$BSAN_OPTIONS_ALL" \
            --env EV_BSAN_SYMBOLIZER="$BSAN_SYMBOLIZER" \
            --env EV_JOBID="${SLURM_JOB_ID}.${tid}" \
            --env http_proxy="${http_proxy:-}"   --env https_proxy="${https_proxy:-}" \
            --env HTTP_PROXY="${HTTP_PROXY:-}"   --env HTTPS_PROXY="${HTTPS_PROXY:-}" \
            "$SIF_ABS" bash "$RUNDIR/inner.sh" > "$log" 2>&1
        rc=$?
        # 143 (SIGTERM) without an OOM report is SLURM ending the job
        # (walltime, scancel): the crate was interrupted, not at fault, so it
        # gets no rows and stays out of done/ for the re-run list to pick up.
        if (( rc == 143 )) && ! grep -q 'oom[-_]kill' "$log"; then
            echo "--- step interrupted: $crate (srun step exited 143; not recorded) ---" >> "$log"
            break
        fi
        # inner.sh itself exits 0, or 1 after its fetch/build_failed row; past
        # 128, or with slurmstepd's oom_kill report, the step was killed.
        if (( rc > 128 )) || grep -q 'oom[-_]kill' "$log"; then
            killed_rows "$crate" "$shard" "$rc" "$log" "${SLURM_JOB_ID}.${tid}"
        fi
        rm -rf "$scr/work" "$scr/target"
        echo "$crate" >> "$RUNDIR/done/done-${JOBIDX}-${tid}.txt"
    done
    rm -rf "$scr"
}

for (( tid = 0; tid < NTASKS; tid++ )); do
    worker "$tid" &
done
wait
