#!/usr/bin/env python3
"""Check that every test in a tests CSV got the SAME result in every run.

Usage: check_consistency.py [-o REPORT.csv] <tests.csv> <dir | hyperfine.csv> [more ...]

Walks the tests listed in a tests CSV (crate,tests,contains_ffi -- what
list_tests.sh writes and common_tests.py reproduces) and compares each one's
`status` across a directory of *-hyperfine.csv files (or the files themselves).
A test is CONSISTENT when every input reports the same status for it.

This checks outcomes, not timings: run-to-run timings are expected to differ --
that is what the benchmark measures -- but a test that succeeds under one
configuration and fails under another is a real disagreement between them, e.g.
a GC setting that changes whether Miri reports UB. Missing rows are reported
separately from genuine disagreements, since they usually mean a run was cut
short rather than that the configurations disagree.

Statuses are abbreviated in the table: ok (success), FAIL (test_failed),
nomatch, bench (bench_failed), build (build_failed), fetch (fetch_failed) and
'-' for no row at all. The last row for a given (crate, test) wins, matching
the other tools, since these CSVs are append-only.

Exit status is 1 if any test disagreed, else 0 (missing rows alone do not fail
the check unless --strict is given), so this can gate a comparison.

  -o FILE        also write the full per-test report as CSV (crate,test plus a
                 column per input), not just the capped table on stdout
  --max-rows N   cap the printed table at N rows (default 40; -o gets them all)
  --strict       treat a missing row as a disagreement too
  --glob PAT     filename pattern to pick up inside a directory (default *.csv)
"""
import argparse
import csv
import glob
import os
import sys
from collections import Counter, OrderedDict

ABBREV = {
    "success": "ok",
    "test_failed": "FAIL",
    "no_match": "nomatch",
    "bench_failed": "bench",
    "build_failed": "build",
    "fetch_failed": "fetch",
}
MISSING = "-"

ap = argparse.ArgumentParser()
ap.add_argument("-o", "--output", help="write the full report CSV here")
ap.add_argument("--max-rows", type=int, default=40, metavar="N",
                help="cap the printed table at N rows (default 40)")
ap.add_argument("--strict", action="store_true",
                help="treat a missing row as a disagreement too")
ap.add_argument("--glob", default="*.csv", metavar="PAT",
                help="filename pattern to pick up inside a directory (default: *.csv)")
ap.add_argument("tests_csv", help="tests CSV listing the tests to check")
ap.add_argument("inputs", nargs="+", help="directories and/or *-hyperfine.csv files")
args = ap.parse_args()


def md_table(headers, rows):
    """headers + rows as a padded GitHub-flavoured markdown table."""
    cols = list(zip(headers, *rows)) if rows else [(h,) for h in headers]
    widths = [max(len(str(c)) for c in col) for col in cols]
    def line(cells):
        return "| " + " | ".join(str(c).ljust(w) for c, w in zip(cells, widths)) + " |"
    return "\n".join([line(headers),
                      "| " + " | ".join("-" * w for w in widths) + " |",
                      *(line(r) for r in rows)])


# ── The tests to check ───────────────────────────────────────────────────────
if not os.path.isfile(args.tests_csv):
    sys.exit(f"Error: tests CSV not found: {args.tests_csv}")
wanted = []                     # [(crate, test)] in file order
with open(args.tests_csv, newline="") as f:
    reader = csv.DictReader(f)
    for col in ("crate", "tests"):
        if col not in (reader.fieldnames or []):
            sys.exit(f"Error: {args.tests_csv} has no '{col}' column -- not a tests "
                     f"CSV (crate,tests,contains_ffi as list_tests.sh writes)?")
    for row in reader:
        crate = row["crate"]
        for t in (row["tests"] or "").split(";"):
            if crate and t:
                wanted.append((crate, t))
if not wanted:
    sys.exit(f"Error: {args.tests_csv} lists no tests.")

# ── The runs to compare ──────────────────────────────────────────────────────
HYPERFINE_COLS = ("crate", "test", "status")


def hyperfine_cols(path):
    """The hyperfine columns this CSV is missing (empty tuple if it has them)."""
    try:
        with open(path, newline="") as f:
            fields = csv.DictReader(f).fieldnames or []
    except OSError as exc:
        return (f"unreadable ({exc.strerror})",)
    return tuple(c for c in HYPERFINE_COLS if c not in fields)


paths, skipped = [], []
for item in args.inputs:
    if os.path.isdir(item):
        found = sorted(glob.glob(os.path.join(item, args.glob)))
        if not found:
            sys.exit(f"Error: no files matching {args.glob} in {item}")
        # A directory is a net, not a promise: the tests CSV, a report written
        # with -o, or any other CSV can share it. Skip what is not a run rather
        # than failing the whole comparison; an explicitly named file still errors.
        for f in found:
            (paths if not hyperfine_cols(f) else skipped).append(f)
    elif os.path.isfile(item):
        missing = hyperfine_cols(item)
        if missing:
            sys.exit(f"Error: {item} has no {', '.join(repr(c) for c in missing)} "
                     f"column -- not a hyperfine CSV?")
        paths.append(item)
    else:
        sys.exit(f"Error: not a file or directory: {item}")
paths = list(OrderedDict.fromkeys(paths))
if skipped:
    print(f"Skipped {len(skipped)} non-hyperfine CSV(s): "
          f"{', '.join(os.path.basename(p) for p in skipped)}", file=sys.stderr)
if len(paths) < 2:
    sys.exit("Error: need at least two runs to compare (got "
             f"{len(paths)}).")


def statuses(path):
    """{(crate, test): status} for one hyperfine CSV, last row winning."""
    out = {}
    with open(path, newline="") as f:
        reader = csv.DictReader(f)
        for r in reader:
            crate, test = r["crate"], r["test"]
            if crate and test and test != "__calibration__":
                out[(crate, test)] = r["status"]
    return out


per_run = [statuses(p) for p in paths]

# Trim the prefix/suffix every filename shares -- these are all
# <config>-<dataset>-hyperfine.csv, and the config is the only part that varies.
names = [os.path.basename(p) for p in paths]
pre = os.path.commonprefix(names)
suf = os.path.commonprefix([n[::-1] for n in names])[::-1]
trimmed = [n[len(pre):len(n) - len(suf)] or n for n in names]
if all(trimmed):
    names = trimmed

# ── Compare ─────────────────────────────────────────────────────────────────
agree, disagree, incomplete = 0, [], []
patterns = Counter()
for key in wanted:
    got = [run.get(key) for run in per_run]
    present = {s for s in got if s is not None}
    if None in got:
        # Absent somewhere: a disagreement only under --strict, otherwise its
        # own bucket -- a truncated run is a coverage problem, not a conflict.
        (disagree if args.strict else incomplete).append((key, got))
        if args.strict:
            patterns[tuple(ABBREV.get(s, s) if s else MISSING for s in got)] += 1
    elif len(present) > 1:
        disagree.append((key, got))
        patterns[tuple(ABBREV.get(s, s) for s in got)] += 1
    else:
        agree += 1

# ── Report ──────────────────────────────────────────────────────────────────
print(f"Checked {len(wanted)} test(s) from {args.tests_csv} across {len(paths)} run(s).")
print(f"  consistent:  {agree}")
print(f"  disagreeing: {len(disagree)}")
if not args.strict:
    print(f"  incomplete:  {len(incomplete)} (no row in at least one run)")

if patterns:
    print("\nDisagreement patterns (columns in input order):\n")
    print(md_table(("count", *names),
                   [(n, *pat) for pat, n in patterns.most_common()]))

shown = disagree[:args.max_rows]
if shown:
    print(f"\nDisagreeing tests{f' (first {len(shown)} of {len(disagree)})' if len(shown) < len(disagree) else ''}:\n")
    print(md_table(("crate", "test", *names),
                   [(c, t, *(ABBREV.get(s, s) if s else MISSING for s in got))
                    for (c, t), got in shown]))

if incomplete and not args.strict:
    per_run_missing = Counter()
    for _, got in incomplete:
        for name, s in zip(names, got):
            if s is None:
                per_run_missing[name] += 1
    print("\nRuns missing listed tests (rerun these to complete the comparison):\n")
    print(md_table(("run", "missing"),
                   [(n, c) for n, c in per_run_missing.most_common()]))

if args.output:
    with open(args.output, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["crate", "test", "verdict", *names])
        for key in wanted:
            got = [run.get(key) for run in per_run]
            present = {s for s in got if s is not None}
            verdict = ("incomplete" if None in got else
                       "disagree" if len(present) > 1 else "consistent")
            w.writerow([key[0], key[1], verdict, *(s or "" for s in got)])
    print(f"\nFull report: {args.output}")

sys.exit(1 if disagree else 0)
