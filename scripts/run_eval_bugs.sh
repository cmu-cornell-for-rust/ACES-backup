#!/usr/bin/env bash
#
# Usage: run_eval_bugs.sh [options] [run_eval_dataset.sh options] [-- extra MIRIFLAGS]
#
# Re-run the tests of a bug dataset (e.g. outputs/dataset.csv: one row per
# bug-triggering test, with crate, version and test columns) under Miri, on the
# cluster, exactly as run_eval_dataset.sh runs any other dataset: same
# sbatch/worker layout, MIRIFLAGS (plus -Zmiri-disable-isolation, so tests
# can read files, the clock and env vars), per-test --test-timeout (default 30m),
# classification and master CSV. This only turns the bug CSV into the two files
# run_eval_dataset.sh takes, then hands off:
#
#   scripts/<name>-tests.csv    crate,test -- crate as <name>-<version>, one
#                               test per row (its --tests)
#   scripts/<name>-dataset.csv  crate_name,version -- with no
#                               <group>/datasets/<name> dir, this makes the
#                               workers download each crate from crates.io
#                               (run_eval_dataset.sh's "No dataset dir")
#
# and runs
#   run_eval_dataset.sh [opts] --no-slow-list --tests scripts/<name>-tests.csv -- miri <image> 6 <name> -Zmiri-disable-isolation [extra]
# whose results land in <group>/outputs/<image>[-<extra-slug>]-<name>-eval.csv.
#
# Only what that CSV doesn't have yet is run: tests with a row there (any
# status -- timeout and killed included) are left out, and so are whole crates
# with a test-less fetch_failed/build_failed row. run_eval_dataset.sh's merge
# appends the new rows to the same CSV, so re-running this after the bug
# dataset grows (or after an interrupted run) only does the difference.
#
# Options:
#   --dataset FILE  bug CSV (default <repo>/outputs/dataset.csv)
#   --name NAME     dataset name for the generated files and the master CSV
#                   (default bugs)
#   --image IMAGE   Miri image under <group>/containers (default master-miri:
#                   the cmu-cornell-for-rust/miri fork's master, built with
#                     containers/build_scripts/build.sh miri master
#                   -- rebuild it to pick up newer master commits)
#   --walltime T    per-job walltime, HH or HH:MM (run_eval_dataset.sh's
#                   positional [walltime]; default 6)
#   --all           run every test, even ones the CSV already has (their old
#                   rows stay; the CSV then holds both)
#   Any other option before `--` goes to run_eval_dataset.sh as is (e.g.
#   --test-timeout 10m, --jobs N); after `--`, extra MIRIFLAGS
#   (e.g. -Zmiri-backtrace=full), appended after -Zmiri-disable-isolation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GROUP="/scratch/group/p.cis260229.000"   # as in run_eval_dataset.sh

DATASET_CSV="$(dirname "$SCRIPT_DIR")/outputs/dataset.csv"
NAME="bugs"
IMAGE="master-miri"
WALLTIME="6"
PASS=()
EXTRA="-Zmiri-disable-isolation"
ALL=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dataset)   DATASET_CSV="$2"; shift 2 ;;
        --dataset=*) DATASET_CSV="${1#*=}"; shift ;;
        --name)      NAME="$2"; shift 2 ;;
        --name=*)    NAME="${1#*=}"; shift ;;
        --image)     IMAGE="$2"; shift 2 ;;
        --image=*)   IMAGE="${1#*=}"; shift ;;
        --walltime)  WALLTIME="$2"; shift 2 ;;
        --walltime=*) WALLTIME="${1#*=}"; shift ;;
        --all)       ALL=1; shift ;;
        -h|--help)   sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p;}' "$0"; exit 0 ;;
        --)          shift; EXTRA+="${*:+ $*}"; break ;;
        *)           PASS+=("$1"); shift ;;
    esac
done

[[ -f "$DATASET_CSV" ]] || { echo "Error: bug dataset not found: $DATASET_CSV" >&2; exit 1; }
[[ "$NAME" =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "Error: --name must be a plain file name (got '$NAME')." >&2; exit 1; }
# A dataset dir of that name would make run_eval_dataset.sh look for the
# crates there instead of downloading them.
[[ ! -d "$GROUP/datasets/$NAME" ]] \
    || { echo "Error: $GROUP/datasets/$NAME exists; pick another --name so the crates are downloaded." >&2; exit 1; }
[[ -f "$GROUP/containers/${IMAGE%.sif}.sif" ]] || {
    echo "Error: image $GROUP/containers/${IMAGE%.sif}.sif not found." >&2
    [[ "$IMAGE" == master-miri ]] && echo "  Build it from the fork's master: (cd $GROUP/containers/build_scripts && ./build.sh miri master)" >&2
    exit 1
}

TESTS_OUT="$SCRIPT_DIR/$NAME-tests.csv"
VERSIONS_OUT="$SCRIPT_DIR/$NAME-dataset.csv"

# The master CSV run_eval_dataset.sh will append to, named as it names it:
# <image>[-<slug>]-<name>-eval.csv, the slug from the extras plus tt<N> for
# --test-threads N.
SLUG="$(printf '%s' "$EXTRA" | tr -c '[:alnum:]' '-' | sed 's/-\{1,\}/-/g; s/^-//; s/-$//')"
for (( i = 0; i < ${#PASS[@]}; i++ )); do
    case "${PASS[i]}" in
        --test-threads)   SLUG="${SLUG:+$SLUG-}tt${PASS[i+1]:-}" ;;
        --test-threads=*) SLUG="${SLUG:+$SLUG-}tt${PASS[i]#*=}" ;;
    esac
done
MASTER_CSV="$GROUP/outputs/${IMAGE%.sif}${SLUG:+-$SLUG}-$NAME-eval.csv"
DONE_CSV="$MASTER_CSV"
[[ "$ALL" == 1 || ! -s "$MASTER_CSV" ]] && DONE_CSV=""

# The bug CSV's error cells are long and quoted, so it's read with Python's
# csv module rather than run_eval_dataset.sh's one-line awk parser.
python3 -I - "$DATASET_CSV" "$TESTS_OUT" "$VERSIONS_OUT" "$DONE_CSV" << 'PY_EOF'
import csv, sys
src, tests_out, versions_out, done_csv = sys.argv[1:]
# Already run: (crate, test) pairs in the master CSV, and crates with a
# test-less row (fetch_failed / build_failed).
done, done_crates = set(), set()
if done_csv:
    with open(done_csv, newline="", encoding="utf-8-sig") as f:
        for r in csv.DictReader(f):
            c, t = (r.get("crate") or "").strip(), (r.get("test") or "").strip()
            if t:
                done.add((c, t))
            elif c:
                done_crates.add(c)
tests, versions, seen = [], [], set()
total, skipped = set(), 0
with open(src, newline="", encoding="utf-8-sig") as f:
    for r in csv.DictReader(f):
        c, v, t = r["crate"].strip(), r["version"].strip(), r["test"].strip()
        if not (c and v and t):
            continue
        key = (f"{c}-{v}", t)
        if key in total:
            continue
        total.add(key)
        if key in done or key[0] in done_crates:
            skipped += 1
            continue
        tests.append(key)
        if (c, v) not in seen:
            seen.add((c, v)); versions.append((c, v))
with open(tests_out, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["crate", "test"])
    w.writerows(tests)
with open(versions_out, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["crate_name", "version"])
    w.writerows(versions)
print(f"{len(total)} test(s) in {src}" + (f"; {skipped} already in {done_csv}" if done_csv else ""))
print(f"{len(tests)} to run, in {len(versions)} crate version(s)")
print(f"  -> {tests_out}\n  -> {versions_out}")
PY_EOF

if [[ $(( $(wc -l < "$TESTS_OUT") - 1 )) -eq 0 ]]; then
    echo "Nothing to run: every test is already in $MASTER_CSV (--all to re-run them)."
    exit 0
fi
echo "Results append to $MASTER_CSV"

exec "$SCRIPT_DIR/run_eval_dataset.sh" ${PASS[@]+"${PASS[@]}"} --no-slow-list --tests "$TESTS_OUT" \
    -- miri "$IMAGE" "$WALLTIME" "$NAME" "$EXTRA"
