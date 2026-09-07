#!/usr/bin/env python3
"""Tests CSV of everything a hyperfine run did NOT get to.

Usage: missing_tests.py [-o OUT.csv] <tests.csv> <hyperfine.csv> [more-hyperfine.csv ...]

Diffs a tests CSV (crate,tests,contains_ffi -- as produced by list_tests.sh)
against one or more *-hyperfine.csv files and writes a tests CSV in the same
schema holding only the (crate, test) pairs the run never reported. Feed it
straight back to a rerun:

    missing_tests.py -o tests-rest.csv scripts/miri-tests.csv \\
        outputs/miri-top_500-hyperfine.csv
    run_bench_dataset.sh --tests tests-rest.csv miri miri top_500

Missing means no row with a "done" status -- by default success, test_failed
or no_match, i.e. the test got a real verdict. bench_failed rows are therefore
missing (hyperfine itself errored, worth retrying); pass --done-status to
change the set. Tests that simply never produced a row -- the usual case, a job
killed by walltime mid-crate -- are missing whatever the flag says, as are all
the tests of a crate absent from the output entirely.

contains_ffi is copied through from the input, NOT rescanned. Crate order and
the within-crate test order both follow the input, which matters: the slowlist
splitting in run_bench_dataset.sh strides the test list positionally.

A crate that failed to build or fetch has one test-less row in the output, so
every one of its tests looks missing; --skip-build-failed drops those crates
instead (a rerun would just fail again). Giving several hyperfine CSVs unions
their coverage: a test must be missing from all of them to be emitted.

The CSV goes to stdout (or -o FILE); a per-crate summary goes to stderr.
"""
import argparse
import csv
import sys

DONE_DEFAULT = "success,test_failed,no_match"
CRATE_FAILURES = {"build_failed", "fetch_failed"}

ap = argparse.ArgumentParser()
ap.add_argument("-o", "--output", help="write the tests CSV here (default: stdout)")
ap.add_argument("--done-status", default=DONE_DEFAULT,
                help=f"comma-separated statuses that count as done (default: {DONE_DEFAULT})")
ap.add_argument("--skip-build-failed", action="store_true",
                help="omit crates whose only rows are build_failed/fetch_failed")
ap.add_argument("-q", "--quiet", action="store_true", help="no stderr summary")
ap.add_argument("tests_csv", help="tests CSV from list_tests.sh (crate,tests,contains_ffi)")
ap.add_argument("hyperfine_csvs", nargs="+", help="one or more *-hyperfine.csv files")
args = ap.parse_args()

done_status = {s.strip() for s in args.done_status.split(",") if s.strip()}
if not done_status:
    ap.error("--done-status needs at least one status")

# ── Coverage: (crate, test) pairs that got a verdict, unioned over the inputs ─
done = set()            # (crate, test)
seen_status = set()     # every status seen, to flag a typo'd --done-status
broken = set()          # crates with a build_failed/fetch_failed row
ran_crates = set()      # crates with any row at all
for path in args.hyperfine_csvs:
    with open(path, newline="") as f:
        reader = csv.DictReader(f)
        for col in ("crate", "test", "status"):
            if col not in (reader.fieldnames or []):
                sys.exit(f"Error: {path} has no '{col}' column -- not a hyperfine CSV?")
        for r in reader:
            crate, test, status = r["crate"], r["test"], r["status"]
            if not crate:
                continue
            ran_crates.add(crate)
            seen_status.add(status)
            if status in CRATE_FAILURES:
                broken.add(crate)
            # Crate-level rows carry no test, and __calibration__ is not one.
            if test and test != "__calibration__" and status in done_status:
                done.add((crate, test))

unknown = done_status - seen_status
if unknown and not args.quiet:
    print(f"Warning: status(es) never seen in the input: {', '.join(sorted(unknown))}",
          file=sys.stderr)

# ── Diff against the tests list, preserving its order ────────────────────────
out_rows = []       # (crate, [missing tests], contains_ffi, crate's test count)
skipped_broken = []
total_tests = total_missing = 0
with open(args.tests_csv, newline="") as f:
    reader = csv.DictReader(f)
    if "crate" not in (reader.fieldnames or []) or "tests" not in (reader.fieldnames or []):
        sys.exit(f"Error: {args.tests_csv} needs crate,tests columns -- not a tests CSV?")
    for r in reader:
        crate = r["crate"]
        tests = [t for t in r["tests"].split(";") if t]
        if not tests:
            continue
        total_tests += len(tests)
        missing = [t for t in tests if (crate, t) not in done]
        if not missing:
            continue
        if args.skip_build_failed and crate in broken:
            skipped_broken.append((crate, len(missing)))
            continue
        total_missing += len(missing)
        out_rows.append((crate, missing, r.get("contains_ffi", ""), len(tests)))

out = open(args.output, "w", newline="") if args.output else sys.stdout
w = csv.writer(out)
w.writerow(["crate", "tests", "contains_ffi"])
for crate, tests, ffi, _ in out_rows:
    w.writerow([crate, ";".join(tests), ffi])
if args.output:
    out.close()

# ── Summary ──────────────────────────────────────────────────────────────────
if args.quiet:
    sys.exit(0)
e = sys.stderr
if out_rows:
    width = max(len(c) for c, _, _, _ in out_rows)
    print(f"{'crate':<{width}}  missing  of", file=e)
    for crate, missing, _, n in sorted(out_rows, key=lambda r: -len(r[1])):
        note = "" if crate in ran_crates else "  (never ran)"
        print(f"{crate:<{width}}  {len(missing):>7}  {n:>3}{note}", file=e)
print(f"\n{total_missing} missing test(s) across {len(out_rows)} crate(s) "
      f"(of {total_tests} tests in {args.tests_csv})", file=e)
if skipped_broken:
    n = sum(k for _, k in skipped_broken)
    print(f"skipped {len(skipped_broken)} build/fetch-failed crate(s), {n} test(s): "
          f"{', '.join(c for c, _ in skipped_broken)}", file=e)
elif broken:
    inc = [c for c, _, _, _ in out_rows if c in broken]
    if inc:
        print(f"note: {len(inc)} crate(s) failed to build/fetch and are included "
              f"in full ({', '.join(inc)}); --skip-build-failed drops them", file=e)
