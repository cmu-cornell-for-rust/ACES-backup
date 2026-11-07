#!/usr/bin/env python3
"""Tests CSV of every test that one or more eval runs skipped.

Usage: skipped_tests.py [-o OUT.csv] [--tests TESTS.csv]... [--all] [--include-timeout] <eval.csv> [more-eval.csv ...]

Collects the (crate, test) pairs with status=skipped in the given *-eval.csv
files (run_eval_dataset.sh output: a module's remaining tests are skipped
after TIMEOUT_STREAK timeouts in a row) and writes them as a tests CSV
(crate,tests,contains_ffi -- the list_tests.sh schema), ready to feed back
to a rerun:

    skipped_tests.py -o tests-skipped.csv outputs/experimental-bsan-*-eval.csv
    run_eval_dataset.sh --tests tests-skipped.csv --no-timeout-skip ...

By default a skipped test is dropped if ANY of the given CSVs has a
non-skipped row for it (e.g. a later rerun got to it); --all keeps every
skipped test regardless. --include-timeout also collects status=timeout tests
(ones that actually hit --test-timeout), treated exactly like skipped ones.

Order: crates and tests in first-seen order across the inputs. With --tests
(repeatable; tests CSVs from list_tests.sh), the output instead follows the
order of those lists and copies contains_ffi from them; skipped tests not in
any --tests list are appended at the end of their crate (or crate list).
Without --tests, contains_ffi is left empty.

The CSV goes to stdout (or -o FILE); a per-crate summary goes to stderr.
"""
import argparse
import csv
import sys

csv.field_size_limit(sys.maxsize)

ap = argparse.ArgumentParser()
ap.add_argument("-o", "--output", help="write the tests CSV here (default: stdout)")
ap.add_argument("--tests", action="append", default=[], metavar="TESTS_CSV", dest="tests_csvs",
                help="tests CSV (crate,tests,contains_ffi) giving order and contains_ffi; repeatable")
ap.add_argument("--all", action="store_true",
                help="keep skipped tests even if another input has a non-skipped row for them")
ap.add_argument("--include-timeout", action="store_true",
                help="also collect status=timeout tests (they hit --test-timeout)")
ap.add_argument("-q", "--quiet", action="store_true", help="no stderr summary")
ap.add_argument("csvs", nargs="+", metavar="EVAL_CSV", help="*-eval.csv files")
args = ap.parse_args()
collect = {"skipped", "timeout"} if args.include_timeout else {"skipped"}

# ── Gather skipped and otherwise-run tests ───────────────────────────────────
skipped = {}            # crate -> {test: None}, first-seen order
ran = set()             # (crate, test) with some non-skipped row
per_file = []           # (path, skipped count)
for path in args.csvs:
    n = 0
    with open(path, newline="") as f:
        reader = csv.DictReader(f)
        for col in ("crate", "test", "status"):
            if col not in (reader.fieldnames or []):
                sys.exit(f"Error: {path} has no '{col}' column -- not an eval CSV?")
        for r in reader:
            crate, test, status = r["crate"], r["test"], r["status"]
            if not crate or not test or test == "__calibration__":
                continue
            if status in collect:
                skipped.setdefault(crate, {})[test] = None
                n += 1
            else:
                ran.add((crate, test))
    per_file.append((path, n))

recovered = 0
if not args.all:
    for crate in list(skipped):
        tests = skipped[crate]
        for t in [t for t in tests if (crate, t) in ran]:
            del tests[t]
            recovered += 1
        if not tests:
            del skipped[crate]

# ── Order (and contains_ffi) from --tests lists, if given ────────────────────
order = {}              # crate -> [{test: None}, contains_ffi]
for path in args.tests_csvs:
    with open(path, newline="") as f:
        reader = csv.DictReader(f)
        if not all(c in (reader.fieldnames or []) for c in ("crate", "tests")):
            sys.exit(f"Error: {path} has no crate,tests columns -- not a tests CSV?")
        for r in reader:
            entry = order.setdefault(r["crate"], [{}, ""])
            for t in r["tests"].split(";"):
                if t:
                    entry[0][t] = None
            if not entry[1] and r.get("contains_ffi"):
                entry[1] = r["contains_ffi"]

out_rows = []           # (crate, [tests], contains_ffi)
crates = [c for c in order if c in skipped] + [c for c in skipped if c not in order]
for crate in crates:
    tests = skipped[crate]
    listed, ffi = order.get(crate, [{}, ""])
    ordered = [t for t in listed if t in tests] + [t for t in tests if t not in listed]
    out_rows.append((crate, ordered, ffi))

out = open(args.output, "w", newline="") if args.output else sys.stdout
w = csv.writer(out)
w.writerow(["crate", "tests", "contains_ffi"])
for crate, tests, ffi in out_rows:
    w.writerow([crate, ";".join(tests), ffi])
if args.output:
    out.close()

# ── Summary ──────────────────────────────────────────────────────────────────
if args.quiet:
    sys.exit(0)
e = sys.stderr
if out_rows:
    width = max(len(c) for c, _, _ in out_rows)
    print(f"{'crate':<{width}}  skipped", file=e)
    for crate, tests, _ in sorted(out_rows, key=lambda r: -len(r[1])):
        print(f"{crate:<{width}}  {len(tests):>7}", file=e)
    print(file=e)
for path, n in per_file:
    print(f"{n:>7} skipped row(s) in {path}", file=e)
total = sum(len(t) for _, t, _ in out_rows)
print(f"{total} skipped test(s) across {len(out_rows)} crate(s)", file=e)
if recovered:
    print(f"dropped {recovered} skipped test(s) that another input ran (--all keeps them)", file=e)
if args.tests_csvs:
    unlisted = sum(1 for c, ts, _ in out_rows for t in ts if t not in order.get(c, [{}])[0])
    if unlisted:
        print(f"note: {unlisted} skipped test(s) are not in any --tests list", file=e)
