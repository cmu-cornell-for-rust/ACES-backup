#!/usr/bin/env python3
"""Drop the crates with no tests from a test CSV.

Usage: drop_empty_tests.py [TESTS_CSV] [OUT_CSV]

Writes the rows of TESTS_CSV (crate,tests[,...]) whose tests column is not
empty (or only whitespace) to OUT_CSV, keeping every column and the row order.
Without OUT_CSV, TESTS_CSV is rewritten in place and the original is kept as
TESTS_CSV.bak.

Default: ../capslock-tests.csv, in place
"""
import argparse
import csv
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
csv.field_size_limit(sys.maxsize)  # some crates list thousands of tests


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("tests", nargs="?", type=Path, default=HERE.parent / "capslock-tests.csv")
    ap.add_argument("out", nargs="?", type=Path)
    args = ap.parse_args()

    with open(args.tests, newline="") as f:
        reader = csv.DictReader(f)
        header = reader.fieldnames
        rows = list(reader)
    if not header or "tests" not in header:
        sys.exit(f"{args.tests}: no tests column")

    kept = [r for r in rows if (r["tests"] or "").strip()]
    out = args.out or args.tests
    if args.out is None:
        shutil.copy2(args.tests, args.tests.with_name(args.tests.name + ".bak"))
    with open(out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=header, lineterminator="\n")
        w.writeheader()
        w.writerows(kept)

    print(f"{len(rows)} crates in {args.tests.name}; {len(rows) - len(kept)} with no tests "
          f"dropped; {len(kept)} written to {out}")


if __name__ == "__main__":
    main()
