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
#   run_eval_dataset.sh [opts] --tests scripts/<name>-tests.csv miri <image> <name> [extra]
# whose results land in <group>/outputs/<image>[-<extra-slug>]-<name>-eval.csv.
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

# The bug CSV's error cells are long and quoted, so it's read with Python's
# csv module rather than run_eval_dataset.sh's one-line awk parser.
python3 -I - "$DATASET_CSV" "$TESTS_OUT" "$VERSIONS_OUT" << 'PY_EOF'
import csv, sys
src, tests_out, versions_out = sys.argv[1:]
tests, versions = [], []
with open(src, newline="", encoding="utf-8-sig") as f:
    for r in csv.DictReader(f):
        c, v, t = r["crate"].strip(), r["version"].strip(), r["test"].strip()
        if not (c and v and t):
            continue
        if (c, v) not in versions:
            versions.append((c, v))
        if (f"{c}-{v}", t) not in tests:
            tests.append((f"{c}-{v}", t))
with open(tests_out, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["crate", "test"])
    w.writerows(tests)
with open(versions_out, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["crate_name", "version"])
    w.writerows(versions)
print(f"{len(tests)} test(s) in {len(versions)} crate version(s) from {src}")
print(f"  -> {tests_out}\n  -> {versions_out}")
PY_EOF

exec "$SCRIPT_DIR/run_eval_dataset.sh" ${PASS[@]+"${PASS[@]}"} --tests "$TESTS_OUT" \
    miri "$IMAGE" "$WALLTIME" "$NAME" "$EXTRA"
