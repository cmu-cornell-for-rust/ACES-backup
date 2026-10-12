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
#   Where it runs: from the login node this submits ONE job via run_job.sh in
#   the `bsan` image (--image to change), with the dataset dir bound at /work;
#   the job runs this script again with --local, which does the builds. A copy
#   of the script is placed in <DATASET_DIR>/_logs/ for that, since only the
#   dataset dir is visible inside the container. The launcher waits for the
#   job, then copies the CSV to the outputs dir; run it under tmux/nohup for
#   big datasets.
#
# Usage:
#   ./build_dataset.sh [-c CPUS] [-t HH[:MM]] [-m MEM] [--image IMG] [--whole] <DATASET>
#   ./build_dataset.sh --local [--image IMG] [--whole] <DATASET_DIR>   # no job
#
#   DATASET       a dataset name under $GROUP/datasets/ (e.g. top_500), or a path
#
#   -c CPUS       cores for the job (default 16)
#   -t HH[:MM]    job walltime (default 8)
#   -m MEM        job memory (default 64G)
#   --image IMG   container image (default bsan); also the CSV's build column.
#                 Plain cargo either way -- no `cargo bsan`, so nothing is
#                 instrumented; in bsan, cargo is the image's default toolchain
#   --whole       compile with `cargo test --no-run` (all targets cargo test
#                 builds), not `cargo test --tests --no-run`
#   --local       skip the job: build on this machine / inside an image shell
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
LOCAL=0; CPUS=16; WALLTIME=8; MEM=64G; IMAGE=bsan; WHOLE=0; POS=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --local)    LOCAL=1; shift ;;
        --whole)    WHOLE=1; shift ;;
        -c|--cpus)  CPUS="$2"; shift 2 ;;
        -t|--time)  WALLTIME="$2"; shift 2 ;;
        -m|--mem)   MEM="$2"; shift 2 ;;
        --image)    IMAGE="$2"; shift 2 ;;
        -*)         die "unknown option $1" ;;
        *)          POS+=("$1"); shift ;;
    esac
done
[ "${#POS[@]}" -eq 1 ] && [ -n "${POS[0]}" ] \
    || { echo "Usage: $0 [-c CPUS] [-t HH[:MM]] [-m MEM] [--image IMG] [--whole] [--local] <DATASET>" >&2; exit 1; }
# A bare dataset name under the group datasets dir, or a path.
DATASET_DIR="$(cd "$GROUP/datasets/${POS[0]}" 2>/dev/null && pwd -P)" \
    || DATASET_DIR="$(cd "${POS[0]}" 2>/dev/null && pwd -P)" \
    || die "${POS[0]} is neither a dataset under $GROUP/datasets nor a directory"
BUILD_RUSTFLAGS="${BUILD_RUSTFLAGS:---cfg=miri --cap-lints=warn}"
RESULTS_CSV="$DATASET_DIR/_logs/build-$IMAGE.csv"

# ------------------------- launcher: submit the job ------------------------- #
if [ "$LOCAL" -eq 0 ]; then
    [ -x "$RUN_JOB" ] || die "run_job.sh not found at $RUN_JOB (or use --local)"
    [[ "$CPUS" =~ ^[1-9][0-9]*$ ]] || die "-c must be a positive integer"
    JOBS="${JOBS:-$(( CPUS >= 4 ? CPUS / 4 : 1 ))}"
    mkdir -p "$DATASET_DIR/_logs"
    cp "$SELF" "$DATASET_DIR/_logs/.build_dataset.sh"
    WHOLE_FLAG=""; [ "$WHOLE" -eq 1 ] && WHOLE_FLAG="--whole"
    echo "==> Submitting the build in the '$IMAGE' image" \
         "($CPUS cpus, $JOBS crates at a time, $MEM, ${WALLTIME}h) ..."
    cd "$DATASET_DIR" || exit 1
    # Single-quoted pieces survive run_job.sh's space-join + `bash -c`.
    "$RUN_JOB" -J build-dataset -c "$CPUS" "$IMAGE" "$WALLTIME" "$MEM" -- \
        "JOBS=$JOBS CARGO_BUILD_JOBS=$(( CPUS / JOBS > 0 ? CPUS / JOBS : 1 ))" \
        "BUILD_RUSTFLAGS='$BUILD_RUSTFLAGS'" \
        "bash _logs/.build_dataset.sh --local --image $IMAGE $WHOLE_FLAG /work"
    rc=$?
    rm -f "$DATASET_DIR/_logs/.build_dataset.sh"
    # Inside the job the dataset was /work, so the CSV landed at the same
    # _logs path; copy it next to the run CSVs.
    if [ -f "$RESULTS_CSV" ]; then
        out="$OUTPUTS_DIR/$IMAGE-$(basename "$DATASET_DIR")-build.csv"
        mkdir -p "$OUTPUTS_DIR" && cp "$RESULTS_CSV" "$out" && echo "    copied to:     $out"
    fi
    exit "$rc"
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
rm -rf "$STATE_DIR"                         # fresh check every run
mkdir -p "$STATE_DIR"

export SELF BUILD_RUSTFLAGS TARGET_BASE STATE_DIR IMAGE COMPILE

# ------------------------------ build each crate ---------------------------- #
crates="$(mktemp)"
for d in "$DATASET_DIR"/*/; do
    d="${d%/}"
    case "$(basename "$d")" in _*) continue ;; esac
    [ -f "$d/Cargo.toml" ] && printf '%s\0' "$d"
done > "$crates"
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
tail -n +2 "$RESULTS_CSV" | awk -F, '
    { c[$3]++; if ($5 != "") t[$5]++ }
    END {
        for (s in c) printf "    %-14s %d\n", s ":", c[s]
        for (k in t) printf "      error_type %s: %d\n", k, t[k]
    }'
echo "    results:       $RESULTS_CSV"
