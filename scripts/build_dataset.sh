#!/usr/bin/env bash
#
# build_dataset.sh
#
#   Fetches and compiles every crate in a dataset ONCE -- no tests are run --
#   and records per crate whether it got through, how long the compile took,
#   and, for a failure, what the error was. Use it to see which crates can be
#   benchmarked at all before spending a run_bench_dataset.sh sweep on them.
#
#   Per crate:  cargo fetch  &&  cargo test --tests --no-run
#   with RUSTFLAGS="--cfg=miri --cap-lints=warn" -- byte-for-byte the compile
#   step run_bench_dataset.sh does in `rust` mode, so a crate that builds here
#   builds there. --whole drops --tests (`cargo test --no-run`), matching
#   run_bench_dataset.sh's whole-crate mode. Each crate builds into its own
#   target dir, deleted once it's checked, and a Cargo.lock the build generated
#   (the crate didn't ship one) is removed.
#
#   Where it runs: from the login node the crates are dealt round-robin into
#   ceil(crates / -n) parts (so part sizes differ by at most one crate, and
#   none holds more than -n), and each part is built by its own job via
#   run_job.sh in the `bsan` image (--image to change), with the dataset dir
#   bound at /work. At most 40 jobs (the QOS limit) run at once; the rest
#   start as earlier ones finish. Each job runs this script again with
#   --local --part K, which builds that part's crates. A copy of the script is
#   placed in <DATASET_DIR>/_logs/ for that, since only the dataset dir is
#   visible inside the container. The launcher waits for every job, merges the
#   parts' CSVs and copies the result to the outputs dir; run it under
#   tmux/nohup for big datasets. Each job's run_job.sh output goes to
#   <DATASET_DIR>/_logs/_build_parts/job-K.log.
#
# Usage:
#   ./build_dataset.sh [-n N] [-c CPUS] [-t HH[:MM]] [-m MEM] [--image IMG] [--whole] <DATASET>
#   ./build_dataset.sh --local [--image IMG] [--whole] <DATASET_DIR>   # no job
#
#   DATASET       a dataset name under $GROUP/datasets/ (e.g. top_500), or a path
#
#   -n N          at most N crates per job (default 100)
#   -c CPUS       cores per job (default 16)
#   -t HH[:MM]    walltime per job (default 8)
#   -m MEM        memory per job (default 64G)
#   --image IMG   container image (default bsan); also the CSV's build column.
#                 Plain cargo either way -- no `cargo bsan`, so nothing is
#                 instrumented; in bsan, cargo is the image's default toolchain
#   --whole       compile with `cargo test --no-run` (all targets cargo test
#                 builds), not `cargo test --tests --no-run`
#   --local       skip the job: build on this machine / inside an image shell
#   --part K      with --local: build only the crates in part K's list
#                 (_logs/_build_parts/part-K.txt); set by the launcher
#
# Output:
#   <DATASET_DIR>/_logs/build-<image>.csv, and (when launched as a job) a copy
#   at $GROUP/outputs/<image>-<dataset>-build.csv, columns:
#     build,crate,status,compile_seconds,error_type,error,timestamp
#   status           ok / fetch_failed / build_failed
#   compile_seconds  wall time of the --no-run compile (empty on fetch_failed)
#   error_type       for a failure, the first of these to match cargo's output
#                    (same patterns, same order, as run_bench_dataset.sh and
#                    analysis/failure_logs.py):
#                      rustc   error[E<code>]
#                      linker  rust-lld
#                      oom     SIGKILL
#                      gc      ERROR: BorrowSanitizer: garbage collection
#                      crash   BorrowSanitizer:DEADLYSIGNAL
#                      bsan    error: Undefined Behavior:
#                      panic   panicked at   (e.g. a build script panicking)
#                      other   none of the above
#   error            the matching line (else the last error:/non-empty line),
#                    one line, at most 300 chars
#   Each crate's full fetch+build output goes to <crate>/build-<image>.log.
#
# Environment knobs:
#   JOBS                crates built in parallel (default: CPUS/4 in a job,
#                       1 with --local); each cargo gets CPUS/JOBS cores
#   BUILD_RUSTFLAGS="--cfg=miri --cap-lints=warn"   RUSTFLAGS for the build
#   CARGO_TARGET_DIR    if set, per-crate target dirs go under it
#
# Requirements: bash 4+; cargo (in the image, or here with --local).

set -uo pipefail   # no -e; per-crate failures are handled inline

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

die() { echo "ERROR: $*" >&2; exit 1; }

# classify <output file>: sets ekind/emsg from a failed command's output. Same
# patterns, same first-match order, as run_bench_dataset.sh's classify and
# analysis/failure_logs.py's error_type -- keep the three in sync.
classify() {
    ekind=other; emsg=""
    local kp
    for kp in 'rustc|error\[E[0-9]+\]' 'linker|rust-lld' 'oom|SIGKILL' \
              'gc|ERROR: BorrowSanitizer: garbage collection' \
              'crash|BorrowSanitizer:DEADLYSIGNAL' \
              'bsan|error: Undefined Behavior:' 'panic|panicked at'; do
        # panic takes the line after too: newer libtest prints the message there.
        if [ "${kp%%|*}" = panic ]; then
            emsg=$(grep -aE -m1 -A1 -- "${kp#*|}" "$1")
        else
            emsg=$(grep -aE -m1 -- "${kp#*|}" "$1")
        fi
        if [ -n "$emsg" ]; then ekind=${kp%%|*}; break; fi
    done
    [ -n "$emsg" ] || emsg=$(grep -aE '^error' "$1" | tail -n1)
    [ -n "$emsg" ] || emsg=$(grep -av '^[[:space:]]*$' "$1" | tail -n1)
    emsg=$(printf '%s' "$emsg" | sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' \
        | tr -d '\r' | tr '\n\t' '  ' | sed -e 's/^ *//' -e 's/  */ /g' | cut -c1-300)
}

# CSV-quote a field (empty stays empty).
csvq() { [ -n "$1" ] && printf '"%s"' "${1//\"/\"\"}"; }

# ------------------------------- worker mode ------------------------------- #
# Invoked by xargs, one crate per call. argv: --worker <crate_dir>
# Writes the crate's CSV row to $STATE_DIR/<crate>.csv.
if [ "${1:-}" = "--worker" ]; then
    dir="$2"
    crate="$(basename "$dir")"
    log="$dir/build-$IMAGE.log"
    had_lock=0; [ -f "$dir/Cargo.lock" ] && had_lock=1
    if [ -n "$TARGET_BASE" ]; then
        export CARGO_TARGET_DIR="$TARGET_BASE/build-$crate"
    else
        export CARGO_TARGET_DIR="$dir/target"
    fi
    rm -rf "$CARGO_TARGET_DIR"

    status=ok; compile=""; ekind=""; emsg=""
    if ! ( cd "$dir" && cargo fetch ) > "$log" 2>&1; then
        status=fetch_failed
    else
        cstart=$(date +%s%3N)
        ( cd "$dir" && RUSTFLAGS="$BUILD_RUSTFLAGS" $COMPILE --no-run ) >> "$log" 2>&1
        brc=$?
        cms=$(( $(date +%s%3N) - cstart ))
        compile=$(printf '%d.%03d' $(( cms / 1000 )) $(( cms % 1000 )))
        [ "$brc" -eq 0 ] || status=build_failed
    fi
    if [ "$status" != ok ]; then
        classify "$log"
        echo "    $status: $crate [$ekind] $emsg"
    fi
    printf '%s,%s,%s,%s,%s,%s,%s\n' "$IMAGE" "$crate" "$status" "$compile" \
        "$ekind" "$(csvq "$emsg")" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
        > "$STATE_DIR/$crate.csv"

    rm -rf "$CARGO_TARGET_DIR"
    [ "$had_lock" = 0 ] && rm -f "$dir/Cargo.lock"
    exit 0
fi

# ------------------------------- arguments --------------------------------- #
GROUP="/scratch/group/p.cis260229.000"
RUN_JOB="$GROUP/scripts/run_job.sh"
OUTPUTS_DIR="$GROUP/outputs"
LOCAL=0; CPUS=16; WALLTIME=8; MEM=64G; IMAGE=bsan; WHOLE=0; PER_JOB=100; PART=""; POS=()
MAX_PARALLEL=40   # jobs in flight at once (QOS limit)
while [ "$#" -gt 0 ]; do
    case "$1" in
        --local)    LOCAL=1; shift ;;
        --whole)    WHOLE=1; shift ;;
        --part)     PART="$2"; shift 2 ;;
        -n|--per-job) PER_JOB="$2"; shift 2 ;;
        -c|--cpus)  CPUS="$2"; shift 2 ;;
        -t|--time)  WALLTIME="$2"; shift 2 ;;
        -m|--mem)   MEM="$2"; shift 2 ;;
        --image)    IMAGE="$2"; shift 2 ;;
        -*)         die "unknown option $1" ;;
        *)          POS+=("$1"); shift ;;
    esac
done
[ "${#POS[@]}" -eq 1 ] && [ -n "${POS[0]}" ] \
    || { echo "Usage: $0 [-n N] [-c CPUS] [-t HH[:MM]] [-m MEM] [--image IMG] [--whole] [--local] <DATASET>" >&2; exit 1; }
# A bare dataset name under the group datasets dir, or a path.
DATASET_DIR="$(cd "$GROUP/datasets/${POS[0]}" 2>/dev/null && pwd -P)" \
    || DATASET_DIR="$(cd "${POS[0]}" 2>/dev/null && pwd -P)" \
    || die "${POS[0]} is neither a dataset under $GROUP/datasets nor a directory"
BUILD_RUSTFLAGS="${BUILD_RUSTFLAGS:---cfg=miri --cap-lints=warn}"
RESULTS_CSV="$DATASET_DIR/_logs/build-$IMAGE.csv"
PARTS_DIR="$DATASET_DIR/_logs/_build_parts"

# summarize <csv>: status / error_type counts.
summarize() {
    tail -n +2 "$1" | awk -F, '
        { c[$3]++; if ($5 != "") t[$5]++ }
        END {
            for (s in c) printf "    %-14s %d\n", s ":", c[s]
            for (k in t) printf "      error_type %s: %d\n", k, t[k]
        }'
}

# ------------------------ launcher: submit the jobs ------------------------ #
if [ "$LOCAL" -eq 0 ]; then
    (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3) )) \
        || die "the launcher needs bash >= 4.3 (wait -n)"
    [ -x "$RUN_JOB" ] || die "run_job.sh not found at $RUN_JOB (or use --local)"
    [[ "$CPUS" =~ ^[1-9][0-9]*$ ]] || die "-c must be a positive integer"
    [[ "$PER_JOB" =~ ^[1-9][0-9]*$ ]] || die "-n must be a positive integer"
    JOBS="${JOBS:-$(( CPUS >= 4 ? CPUS / 4 : 1 ))}"

    CRATES=()
    for d in "$DATASET_DIR"/*/; do
        d="${d%/}"
        case "$(basename "$d")" in _*) continue ;; esac
        [ -f "$d/Cargo.toml" ] && CRATES+=("$(basename "$d")")
    done
    n=${#CRATES[@]}
    [ "$n" -gt 0 ] || die "no crates (dirs with a Cargo.toml) in $DATASET_DIR"
    NPARTS=$(( (n + PER_JOB - 1) / PER_JOB ))

    # Deal round-robin, so part sizes differ by at most one crate.
    rm -rf "$PARTS_DIR"
    mkdir -p "$PARTS_DIR"
    i=0
    for c in "${CRATES[@]}"; do
        printf '%s\n' "$c" >> "$PARTS_DIR/part-$(( i % NPARTS )).txt"
        i=$((i + 1))
    done
    cp "$SELF" "$DATASET_DIR/_logs/.build_dataset.sh"
    WHOLE_FLAG=""; [ "$WHOLE" -eq 1 ] && WHOLE_FLAG="--whole"
    echo "==> Building $n crates in the '$IMAGE' image as $NPARTS job(s) of" \
         "$(( n / NPARTS ))-$(( (n + NPARTS - 1) / NPARTS )) crates" \
         "($CPUS cpus, $JOBS crates at a time, $MEM, ${WALLTIME}h each; at most $MAX_PARALLEL at once)"

    pids=()
    cleanup() {
        trap - INT TERM
        # The run_job.sh launchers (and their srun) are the subshells' children.
        for p in ${pids[@]+"${pids[@]}"}; do pkill -TERM -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
        exit 130
    }
    trap cleanup INT TERM
    inflight=0; failed=0
    reap_one() {
        wait -n; [ $? -eq 0 ] || failed=$((failed + 1))
        inflight=$((inflight - 1))
    }
    for (( k = 0; k < NPARTS; k++ )); do
        [ "$inflight" -lt "$MAX_PARALLEL" ] || reap_one
        # Single-quoted pieces survive run_job.sh's space-join + `bash -c`.
        (
            cd "$DATASET_DIR" || exit 1
            "$RUN_JOB" -J "build-dataset-$k" -c "$CPUS" "$IMAGE" "$WALLTIME" "$MEM" -- \
                "JOBS=$JOBS CARGO_BUILD_JOBS=$(( CPUS / JOBS > 0 ? CPUS / JOBS : 1 ))" \
                "BUILD_RUSTFLAGS='$BUILD_RUSTFLAGS'" \
                "bash _logs/.build_dataset.sh --local --part $k --image $IMAGE $WHOLE_FLAG /work"
        ) > "$PARTS_DIR/job-$k.log" 2>&1 &
        pids+=("$!")
        inflight=$((inflight + 1))
        echo "    [$((k + 1))/$NPARTS] launched part $k ($(wc -l < "$PARTS_DIR/part-$k.txt") crates)"
    done
    while [ "$inflight" -gt 0 ]; do reap_one; done
    trap - INT TERM
    rm -f "$DATASET_DIR/_logs/.build_dataset.sh"

    # Merge the parts' CSVs (inside a job the dataset was /work, so they
    # landed at the same _logs paths).
    {
        echo "build,crate,status,compile_seconds,error_type,error,timestamp"
        for f in "$PARTS_DIR"/build-"$IMAGE".part-*.csv; do
            [ -f "$f" ] && tail -n +2 "$f"
        done | LC_ALL=C sort -t, -k2,2
    } > "$RESULTS_CSV"
    rows=$(( $(wc -l < "$RESULTS_CSV") - 1 ))

    echo
    echo "==> Done ($rows/$n crates have a row)."
    summarize "$RESULTS_CSV"
    echo "    results:       $RESULTS_CSV"
    if [ "$rows" -lt "$n" ]; then
        echo "    $(( n - rows )) crate(s) have no row (job killed / walltime); see $PARTS_DIR/job-*.log"
    fi
    [ "$failed" -eq 0 ] || echo "    $failed job(s) exited non-zero; see $PARTS_DIR/job-*.log"
    out="$OUTPUTS_DIR/$IMAGE-$(basename "$DATASET_DIR")-build.csv"
    mkdir -p "$OUTPUTS_DIR" && cp "$RESULTS_CSV" "$out" && echo "    copied to:     $out"
    [ "$failed" -eq 0 ]
    exit $?
fi

# ---------------------------- --local: do builds ---------------------------- #
command -v cargo >/dev/null || die "cargo is required"
JOBS="${JOBS:-1}"
TARGET_BASE="${CARGO_TARGET_DIR:-}"
COMPILE="cargo test --tests"
[ "$WHOLE" -eq 1 ] && COMPILE="cargo test"
export CARGO_TERM_COLOR=never

LOG_DIR="$DATASET_DIR/_logs"
STATE_DIR="$LOG_DIR/_build_dataset_state"   # per-crate rows, merged + removed below
if [ -n "$PART" ]; then
    # One job of several: its own crate list, state dir and CSV, so parts
    # running at once never touch each other's files.
    PART_LIST="$PARTS_DIR/part-$PART.txt"
    [ -f "$PART_LIST" ] || die "no crate list for part $PART at $PART_LIST"
    STATE_DIR="$PARTS_DIR/_state-$PART"
    RESULTS_CSV="$PARTS_DIR/build-$IMAGE.part-$PART.csv"
fi
rm -rf "$STATE_DIR"                         # fresh check every run
mkdir -p "$STATE_DIR"

export SELF BUILD_RUSTFLAGS TARGET_BASE STATE_DIR IMAGE COMPILE

# ------------------------------ build each crate ---------------------------- #
crates="$(mktemp)"
if [ -n "$PART" ]; then
    while IFS= read -r c; do
        [ -n "$c" ] && [ -f "$DATASET_DIR/$c/Cargo.toml" ] && printf '%s\0' "$DATASET_DIR/$c"
    done < "$PART_LIST"
else
    for d in "$DATASET_DIR"/*/; do
        d="${d%/}"
        case "$(basename "$d")" in _*) continue ;; esac
        [ -f "$d/Cargo.toml" ] && printf '%s\0' "$d"
    done
fi > "$crates"
n="$(tr -cd '\0' < "$crates" | wc -c | tr -d ' ')"
echo "==> Building $n crates in $DATASET_DIR with $JOBS worker(s):" \
     "$COMPILE --no-run (RUSTFLAGS=\"$BUILD_RUSTFLAGS\") ..."
xargs -0 -n 1 -P "$JOBS" "$SELF" --worker < "$crates"
rm -f "$crates"

# ---------------------------------- outputs --------------------------------- #
{
    echo "build,crate,status,compile_seconds,error_type,error,timestamp"
    find "$STATE_DIR" -maxdepth 1 -name '*.csv' -exec cat {} + 2>/dev/null | LC_ALL=C sort -t, -k2,2
} > "$RESULTS_CSV"
rm -rf "$STATE_DIR"

echo
echo "==> Done."
summarize "$RESULTS_CSV"
echo "    results:       $RESULTS_CSV"
