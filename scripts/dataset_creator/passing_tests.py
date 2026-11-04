#!/usr/bin/env python3
"""Turn eval results into a test CSV of just the tests that passed.

Usage: passing_tests.py EVAL_CSV [EVAL_CSV ...] -o OUT_CSV

Reads one or more eval CSVs (build,crate,test,status,...; e.g.
outputs/experimental-bsan-*-eval.csv) and writes OUT_CSV in the crate,tests
shape of scripts/*-tests.csv, with tests joined by ';'. A test is kept if any
row for it, in any input, has status 'success'. Crates keep the order they
first appear in; each crate's tests are sorted and deduplicated.
"""
import argparse
import csv
import sys

csv.field_size_limit(sys.maxsize)  # some crates list thousands of tests


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("evals", nargs="+")
    ap.add_argument("-o", "--out", required=True)
    args = ap.parse_args()

    passed = {}  # crate -> set of tests; dict keeps first-seen crate order
    for path in args.evals:
        with open(path, newline="") as f:
            for r in csv.DictReader(f):
                if r["status"] == "success":
                    passed.setdefault(r["crate"], set()).add(r["test"])

    with open(args.out, "w", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["crate", "tests"])
        for crate, tests in passed.items():
            w.writerow([crate, ";".join(sorted(tests))])

    print(f"{sum(map(len, passed.values()))} passing tests across {len(passed)} crates "
          f"written to {args.out}")


if __name__ == "__main__":
    main()
