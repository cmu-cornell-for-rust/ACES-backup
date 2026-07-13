#!/usr/bin/env python3
"""List crates whose per-test rows are incomplete in a *-hyperfine.csv.

Usage: remaining_crates.py [--no-ffi] [--include-failed] <tests_csv> <hyperfine_csv>

Compares the tests CSV (crate,tests,contains_ffi from list_tests.sh; the tests
column deduped the way run_bench_dataset.sh does) against the rows of a merged
hyperfine results CSV, and prints -- one per line, in descending order of how
many test rows are missing -- the crates a rerun still needs. The output is
directly usable as run_bench_dataset.sh's --only (or --ignore) FILE.

A crate whose only row is fetch_failed/build_failed counts as attempted-and-
failed, not remaining (rerunning it would fail the same way); pass
--include-failed to list those too. Pass --no-ffi iff the original sweep used
it, so the expected universe matches.
"""
import argparse
import csv
import sys
from collections import defaultdict

parser = argparse.ArgumentParser()
parser.add_argument("--no-ffi", action="store_true",
                    help="expect only crates with contains_ffi == false")
parser.add_argument("--include-failed", action="store_true",
                    help="also list crates with a fetch_failed/build_failed row")
parser.add_argument("tests_csv")
parser.add_argument("hyperfine_csv")
args = parser.parse_args()

expected = {}  # crate -> ordered deduped test list
with open(args.tests_csv, newline="") as f:
    for row in csv.reader(f):
        if len(row) < 3 or row[0] == "crate":
            continue
        crate, tests, ffi = row[0].strip(), row[1], row[2].strip()
        if args.no_ffi and ffi != "false":
            continue
        seen, tl = set(), []
        for t in tests.split(";"):
            if t and t not in seen:
                seen.add(t)
                tl.append(t)
        if tl:
            expected[crate] = tl

have = defaultdict(set)  # crate -> set of tests with a row
failed = set()           # crates with a crate-level failure row
with open(args.hyperfine_csv, newline="") as f:
    for r in csv.DictReader(f):
        if r["status"] in ("fetch_failed", "build_failed"):
            failed.add(r["crate"])
        elif r["test"]:
            have[r["crate"]].add(r["test"])

remaining = []
for crate, tests in expected.items():
    missing = [t for t in tests if t not in have[crate]]
    if not missing:
        continue
    if crate in failed and not args.include_failed:
        continue
    remaining.append((len(missing), len(tests), crate))

for nmiss, ntests, crate in sorted(remaining, reverse=True):
    print(f"{crate}  # missing {nmiss}/{ntests} tests", file=sys.stderr)
    print(crate)

print(f"{len(remaining)} of {len(expected)} crates remaining"
      + (f" ({len(failed)} failed crates excluded)" if failed and not args.include_failed else ""),
      file=sys.stderr)
