#!/usr/bin/env python3
"""Drop from one test CSV the crates another test CSV already has.

Usage: subtract_tests.py [TESTS_CSV] [SUBTRACT_CSV] [OUT_CSV]

Writes the rows of TESTS_CSV (crate,tests) whose crate (<name>-<version>) is
not in SUBTRACT_CSV to OUT_CSV. A crate is dropped only on an exact
name-and-version match: another version of the same crate is kept.
The inputs are left alone; the output keeps TESTS_CSV's row order.

Defaults: ../capslock-tests.csv ../mirilli-tests.csv ../capslock-tests-minus-mirilli.csv
"""
import argparse
import csv
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
csv.field_size_limit(sys.maxsize)  # some crates list thousands of tests


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("tests", nargs="?", default=HERE.parent / "capslock-tests.csv")
    ap.add_argument("subtract", nargs="?", default=HERE.parent / "mirilli-tests.csv")
    ap.add_argument("out", nargs="?", default=HERE.parent / "capslock-tests-minus-mirilli.csv")
    args = ap.parse_args()

    with open(args.subtract, newline="") as f:
        drop = {r["crate"] for r in csv.DictReader(f)}

    with open(args.tests, newline="") as f:
        reader = csv.DictReader(f)
        header = reader.fieldnames
        rows = list(reader)

    kept = [r for r in rows if r["crate"] not in drop]
    with open(args.out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=header, lineterminator="\n")
        w.writeheader()
        w.writerows(kept)

    print(f"{len(rows)} crates in {Path(args.tests).name}; {len(rows) - len(kept)} also in "
          f"{Path(args.subtract).name} dropped; {len(kept)} written to {args.out}")


if __name__ == "__main__":
    main()
