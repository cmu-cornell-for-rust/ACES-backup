#!/usr/bin/env python3
"""Tests CSV of the tests every hyperfine run measured -- their intersection.

Usage: common_tests.py [-o OUT.csv] <dir | hyperfine.csv> [more ...]

Takes a directory of *-hyperfine.csv files (or the files themselves) and writes
a tests CSV -- crate,tests,contains_ffi, the schema list_tests.sh produces and
run_bench_dataset.sh --tests consumes -- holding only the (crate, test) pairs
that EVERY input measured. Use it to put a set of configs on the same footing:

    common_tests.py -o tests-common.csv outputs/miri-v1
    plot_by_crate.py seconds outputs/miri-v1/*.csv     # now comparing like for like

"Measured" means a row whose status is in --status (default success), i.e. the
test produced a usable timing. A test that failed, went unmatched or was never
reached in even one input is left out, since it has no comparable number there.
Calibration rows and the test-less rows a build/fetch failure emits are never
tests and are ignored.

Crate and within-crate test order follow the FIRST input (or --order-by, or a
--ffi reference CSV when one is given), which keeps the output stable across
runs -- it matters because run_bench_dataset.sh's slowlist splitting strides
each crate's test list positionally.

contains_ffi is not rescanned: it is copied from --ffi FILE (a list_tests.sh
CSV) when given, and left empty otherwise. An empty column is fine for a normal
run but makes --no-ffi skip everything, since it keeps only the crates whose
column is exactly "false" -- pass --ffi if you plan to use it.

The CSV goes to stdout (or -o FILE); a per-input summary goes to stderr.
"""
import argparse
import csv
import glob
import os
import sys
from collections import OrderedDict

STATUS_DEFAULT = "success"
NOT_A_TEST = {"__calibration__", ""}

ap = argparse.ArgumentParser()
ap.add_argument("-o", "--output", help="write the tests CSV here (default: stdout)")
ap.add_argument("--status", default=STATUS_DEFAULT,
                help=f"comma-separated statuses that count as measured (default: {STATUS_DEFAULT})")
ap.add_argument("--ffi", metavar="FILE",
                help="a list_tests.sh CSV to copy contains_ffi from (and to take "
                     "crate/test ordering from)")
ap.add_argument("--order-by", metavar="FILE",
                help="take crate/test ordering from this input instead of the first")
ap.add_argument("--glob", default="*.csv", metavar="PAT",
                help="filename pattern to pick up inside a directory (default: *.csv)")
ap.add_argument("-q", "--quiet", action="store_true", help="no stderr summary")
ap.add_argument("inputs", nargs="+", help="directories and/or *-hyperfine.csv files")
args = ap.parse_args()

want_status = {s.strip() for s in args.status.split(",") if s.strip()}
if not want_status:
    ap.error("--status needs at least one status")

# ── Collect the input files ──────────────────────────────────────────────────
paths = []
for item in args.inputs:
    if os.path.isdir(item):
        found = sorted(glob.glob(os.path.join(item, args.glob)))
        if not found:
            sys.exit(f"Error: no files matching {args.glob} in {item}")
        paths.extend(found)
    elif os.path.isfile(item):
        paths.append(item)
    else:
        sys.exit(f"Error: not a file or directory: {item}")
# A file named twice would make the intersection a no-op against itself.
paths = list(OrderedDict.fromkeys(paths))
if len(paths) < 2 and not args.quiet:
    print(f"Warning: only {len(paths)} input -- the 'intersection' is just that file.",
          file=sys.stderr)


def measured(path):
    """The (crate, test) pairs in one hyperfine CSV with a wanted status."""
    seen = set()
    order = []
    with open(path, newline="") as f:
        reader = csv.DictReader(f)
        for col in ("crate", "test", "status"):
            if col not in (reader.fieldnames or []):
                sys.exit(f"Error: {path} has no '{col}' column -- not a hyperfine CSV?")
        for r in reader:
            crate, test = r["crate"], r["test"]
            if not crate or test in NOT_A_TEST:
                continue
            if r["status"] in want_status and (crate, test) not in seen:
                seen.add((crate, test))
                order.append((crate, test))
    return seen, order


per_file = [(p, *measured(p)) for p in paths]
common = set.intersection(*(s for _, s, _ in per_file))

# ── Ordering: --ffi, --order-by, else the first input ────────────────────────
order = []
if args.ffi or args.order_by:
    ref = args.ffi or args.order_by
    if args.ffi:
        with open(ref, newline="") as f:
            for r in csv.DictReader(f):
                for t in r["tests"].split(";"):
                    if t:
                        order.append((r["crate"], t))
    else:
        order = measured(ref)[1]
else:
    order = per_file[0][2]

ffi_of = {}
if args.ffi:
    with open(args.ffi, newline="") as f:
        for r in csv.DictReader(f):
            ffi_of[r["crate"]] = r.get("contains_ffi", "")

# ── Group the intersection into rows, in that order ─────────────────────────
rows = OrderedDict()          # crate -> [tests]
for crate, test in order:
    if (crate, test) in common:
        rows.setdefault(crate, []).append(test)
# Anything the ordering source never mentioned still belongs in the output.
missed = sorted(common - set(order))
for crate, test in missed:
    rows.setdefault(crate, []).append(test)

out = open(args.output, "w", newline="") if args.output else sys.stdout
w = csv.writer(out)
w.writerow(["crate", "tests", "contains_ffi"])
for crate, tests in rows.items():
    w.writerow([crate, ";".join(tests), ffi_of.get(crate, "")])
if args.output:
    out.close()

# ── Summary ─────────────────────────────────────────────────────────────────
if args.quiet:
    sys.exit(0)
e = sys.stderr
# These filenames share a long dataset suffix (and often a prefix); trimming
# what every input has in common keeps the table narrow enough to read.
names = [os.path.basename(p) for p, _, _ in per_file]
if len(names) > 1:
    pre = os.path.commonprefix(names)
    suf = os.path.commonprefix([n[::-1] for n in names])[::-1]
    trimmed = [n[len(pre):len(n) - len(suf)] or n for n in names]
    if all(trimmed):
        names = trimmed
width = max(len(n) for n in names)
print(f"{'input':<{width}}  measured  dropped", file=e)
for name, (_, seen, _) in zip(names, per_file):
    print(f"{name:<{width}}  {len(seen):>8}  {len(seen) - len(common):>7}", file=e)
n_tests = sum(len(t) for t in rows.values())
print(f"\nintersection: {n_tests} test(s) across {len(rows)} crate(s), "
      f"from {len(per_file)} input(s)", file=e)
if missed:
    print(f"note: {len(missed)} pair(s) were not in the ordering source and were "
          f"appended per crate", file=e)
if not args.ffi:
    print("note: contains_ffi left empty (no --ffi) -- a run using --no-ffi would "
          "skip every crate", file=e)
