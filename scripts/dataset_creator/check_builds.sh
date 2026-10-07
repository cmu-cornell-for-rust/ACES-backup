#!/usr/bin/env bash
#
# check_builds.sh
#
#   Builds every crate's test binaries in a dataset dir and records which ones
#   fail and why. The main use: finding crates whose crates.io tarball ships
#   the test code but strips the test data it include_str!/include_bytes!s,
#   which fails the build with
#       error: couldn't read `tests/data/foo.json`: No such file or directory
#   Those are written to missing_test_data.log, the input test_repair.py reads
#   to restore the data from the crate's repository.
#
#   Per crate:  cargo fetch  &&  cargo build --tests
#   (plain cargo, NOT cargo bsan; --tests because the test targets are where
#   the fixtures are include_*!'d -- a bare `cargo build` never compiles them)
#   with RUSTFLAGS="--cfg=miri --cap-lints=warn", the same cfg the run scripts
#   (run_bench_dataset.sh) build with. Each crate builds into its own target
#   dir, deleted once it's checked, and a Cargo.lock the build generated (the
#   crate didn't ship one) is removed.
#
#   Where it runs: from the login node this submits ONE job via run_job.sh in
#   the `bsan` image (its toolchain, plain cargo), with the dataset dir bound
#   at /work; the job runs this script again with --local, which does the
#   builds. A copy of the script is placed in <DATASET_DIR>/_logs/ for that,
#   since only the dataset dir is visible inside the container. The launcher
#   waits for the job; run it under tmux/nohup for big datasets.
#
#   NOTE: only data a build needs is caught. Tests that open fixture files at
#   RUN time build fine here and still fail later -- those show up as
#   test_failed in the run CSVs instead.
#
# Usage:
#   ./check_builds.sh [-c CPUS] [-t HH[:MM]] [-m MEM] [--image IMG] <DATASET_DIR>
#   ./check_builds.sh --local <DATASET_DIR>     # build right here, no job
#
#   -c CPUS       cores for the job (default 16)
#   -t HH[:MM]    job walltime (default 8)
#   -m MEM        job memory (default 64G)
#   --image IMG   container image (default bsan)
#   --local       skip the job: build on this machine / inside an image shell
#
# Outputs (in <DATASET_DIR>/_logs/):
#   build_check.csv          crate,status,detail -- status is one of
#       ok                   built
#       missing_test_data    couldn't read a file under a fixture dir (tests/,
#                            testdata/, test/, src/tests/, src/unicode/data/
#                            -- test_repair.py's FIXTURE_DIRS); detail = path
#       missing_module       a module file (.rs) is missing; test_repair.py
#                            only restores non-.rs files, so not listed for it
#       fetch_failed         cargo fetch failed (deps not resolvable)
#       build_failed         anything else; detail = first error line
#   missing_test_data.log    the missing_test_data crates, one name-version
#                            per line -- test_repair.py's default input
#   build_logs/<crate>.log   full cargo output of every crate that failed
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

# ------------------------------- worker mode ------------------------------- #
# Invoked by xargs, one crate per call. argv: --worker <crate_dir>
# Writes "<crate>\t<status>\t<detail>" to $STATE_DIR/<crate>.tsv.
if [ "${1:-}" = "--worker" ]; then
    dir="$2"
    crate="$(basename "$dir")"
    out="$(mktemp)"
    had_lock=0; [ -f "$dir/Cargo.lock" ] && had_lock=1
    if [ -n "$TARGET_BASE" ]; then
        export CARGO_TARGET_DIR="$TARGET_BASE/check-$crate"
    else
        export CARGO_TARGET_DIR="$dir/target"
    fi
    rm -rf "$CARGO_TARGET_DIR"

    status=ok; detail=""
    if ! ( cd "$dir" && cargo fetch ) > "$out" 2>&1; then
        status=fetch_failed
    elif ! ( cd "$dir" && RUSTFLAGS="$BUILD_RUSTFLAGS" cargo build --tests ) >> "$out" 2>&1; then
        # Paths rustc couldn't read, made relative to the crate; a missing
        # fixture is one under a FIXTURE_DIRS dir (mirror of test_repair.py).
        missing="$(grep -oE "couldn't read \`[^\`]+\`" "$out" \
                   | sed -E "s/^couldn't read \`(.*)\`$/\1/; s#^$dir/##" | sort -u)"
        fixture="$(printf '%s\n' "$missing" \
                   | grep -E '^(tests|testdata|test|src/tests|src/unicode/data)/' | head -n1)"
        if [ -n "$fixture" ]; then
            status=missing_test_data; detail="$fixture"
        elif grep -q 'file not found for module' "$out"; then
            status=missing_module
            detail="$(grep -m1 'file not found for module' "$out")"
        else
            status=build_failed
        fi
    fi
    if [ "$status" = fetch_failed ] || [ "$status" = build_failed ]; then
        detail="$(grep -m1 -E '^error' "$out")"
    fi
    if [ "$status" != ok ]; then
        cp "$out" "$BUILD_LOGS/$crate.log"
        echo "    $status: $crate${detail:+  ($detail)}"
    fi
    detail="$(printf '%s' "$detail" | tr '\t\r\n' '   ')"
    printf '%s\t%s\t%s\n' "$crate" "$status" "$detail" > "$STATE_DIR/$crate.tsv"

    rm -f "$out"
    rm -rf "$CARGO_TARGET_DIR"
    [ "$had_lock" = 0 ] && rm -f "$dir/Cargo.lock"
    exit 0
fi

# ------------------------------- arguments --------------------------------- #
GROUP="/scratch/group/p.cis260229.000"
RUN_JOB="$GROUP/scripts/run_job.sh"
LOCAL=0; CPUS=16; WALLTIME=8; MEM=64G; IMAGE=bsan; POS=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --local)    LOCAL=1; shift ;;
        -c|--cpus)  CPUS="$2"; shift 2 ;;
        -t|--time)  WALLTIME="$2"; shift 2 ;;
        -m|--mem)   MEM="$2"; shift 2 ;;
        --image)    IMAGE="$2"; shift 2 ;;
        -*)         die "unknown option $1" ;;
        *)          POS+=("$1"); shift ;;
    esac
done
[ "${#POS[@]}" -eq 1 ] && [ -n "${POS[0]}" ] \
    || { echo "Usage: $0 [-c CPUS] [-t HH[:MM]] [-m MEM] [--image IMG] [--local] <DATASET_DIR>" >&2; exit 1; }
DATASET_DIR="$(cd "${POS[0]}" 2>/dev/null && pwd -P)" || die "${POS[0]} is not a directory"
BUILD_RUSTFLAGS="${BUILD_RUSTFLAGS:---cfg=miri --cap-lints=warn}"

# ------------------------- launcher: submit the job ------------------------- #
if [ "$LOCAL" -eq 0 ]; then
    [ -x "$RUN_JOB" ] || die "run_job.sh not found at $RUN_JOB (or use --local)"
    [[ "$CPUS" =~ ^[1-9][0-9]*$ ]] || die "-c must be a positive integer"
    JOBS="${JOBS:-$(( CPUS >= 4 ? CPUS / 4 : 1 ))}"
    mkdir -p "$DATASET_DIR/_logs"
    cp "$SELF" "$DATASET_DIR/_logs/.check_builds.sh"
    echo "==> Submitting the build check in the '$IMAGE' image" \
         "($CPUS cpus, $JOBS crates at a time, $MEM, ${WALLTIME}h) ..."
    cd "$DATASET_DIR" || exit 1
    # Single-quoted pieces survive run_job.sh's space-join + `bash -c`.
    "$RUN_JOB" -J check-builds -c "$CPUS" "$IMAGE" "$WALLTIME" "$MEM" -- \
        "JOBS=$JOBS CARGO_BUILD_JOBS=$(( CPUS / JOBS > 0 ? CPUS / JOBS : 1 ))" \
        "BUILD_RUSTFLAGS='$BUILD_RUSTFLAGS'" \
        "bash _logs/.check_builds.sh --local /work"
    rc=$?
    rm -f "$DATASET_DIR/_logs/.check_builds.sh"
    exit "$rc"
fi

# ---------------------------- --local: do builds ---------------------------- #
command -v cargo >/dev/null || die "cargo is required"
JOBS="${JOBS:-1}"
TARGET_BASE="${CARGO_TARGET_DIR:-}"
export CARGO_TERM_COLOR=never

LOG_DIR="$DATASET_DIR/_logs"
STATE_DIR="$LOG_DIR/_build_state"
BUILD_LOGS="$LOG_DIR/build_logs"
RESULTS_CSV="$LOG_DIR/build_check.csv"
MISSING_LOG="$LOG_DIR/missing_test_data.log"
rm -rf "$STATE_DIR" "$BUILD_LOGS"          # fresh check every run
mkdir -p "$STATE_DIR" "$BUILD_LOGS"

export SELF BUILD_RUSTFLAGS TARGET_BASE STATE_DIR BUILD_LOGS

# ------------------------------ build each crate ---------------------------- #
crates="$(mktemp)"
for d in "$DATASET_DIR"/*/; do
    d="${d%/}"
    case "$(basename "$d")" in _*) continue ;; esac
    [ -f "$d/Cargo.toml" ] && printf '%s\0' "$d"
done > "$crates"
n="$(tr -cd '\0' < "$crates" | wc -c | tr -d ' ')"
echo "==> Building tests of $n crates in $DATASET_DIR with $JOBS worker(s)" \
     "(RUSTFLAGS=\"$BUILD_RUSTFLAGS\") ..."
xargs -0 -n 1 -P "$JOBS" "$SELF" --worker < "$crates"
rm -f "$crates"

# ---------------------------------- outputs --------------------------------- #
csv_field() { local s=${1//\"/\"\"}; printf '"%s"' "$s"; }
states="$(mktemp)"
find "$STATE_DIR" -maxdepth 1 -name '*.tsv' -exec cat {} + 2>/dev/null | LC_ALL=C sort > "$states"
{
    echo "crate,status,detail"
    while IFS=$'\t' read -r crate status detail; do
        printf '%s,%s,%s\n' "$(csv_field "$crate")" "$status" "$(csv_field "$detail")"
    done < "$states"
} > "$RESULTS_CSV"
{
    echo "# crates whose test build couldn't read a fixture file -- input for"
    echo "# test_repair.py. Written by check_builds.sh on $(date -u +%Y-%m-%d)."
    awk -F'\t' '$2 == "missing_test_data" { print $1 }' "$states"
} > "$MISSING_LOG"
rm -rf "$STATE_DIR"

count() { awk -F'\t' -v s="$1" '$2 == s' "$states" | wc -l | tr -d ' '; }
echo
echo "==> Done."
echo "    ok:                 $(count ok)"
echo "    missing_test_data:  $(count missing_test_data) -> $MISSING_LOG"
echo "    missing_module:     $(count missing_module)"
echo "    fetch_failed:       $(count fetch_failed)"
echo "    build_failed:       $(count build_failed)"
echo "    results:            $RESULTS_CSV"
echo "    failure logs:       $BUILD_LOGS/"
rm -f "$states"
