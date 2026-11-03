#!/usr/bin/env python3
"""List the tests in the bug dataset that hit a use-after-free or out-of-bounds access.

Usage: memory_bug_tests.py [DATASET_CSV] [OUT_CSV]

Writes one row per crate (<name>-<version>) to OUT_CSV in the shape of
mirilli-tests.csv (crate,tests), with the crate's failing tests joined by ';'.
A test is kept when its "error type" is Use-After-Free or Access Out-of-Bound.
Crates keep their first-seen order from DATASET_CSV; tests are sorted and deduplicated.

Defaults: ../../outputs/dataset.csv ../memory-bugs-tests.csv
"""
import argparse
import csv
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
csv.field_size_limit(sys.maxsize)  # error logs can be long

ERROR_TYPES = {"Use-After-Free", "Access Out-of-Bound"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dataset", nargs="?", default=HERE.parent.parent / "outputs" / "dataset.csv")
    ap.add_argument("out", nargs="?", default=HERE.parent / "memory-bugs-tests.csv")
    args = ap.parse_args()

    tests = {}
    with open(args.dataset, newline="", encoding="utf-8-sig") as f:
        for r in csv.DictReader(f):
            if r["error type"].strip() in ERROR_TYPES and r["test"].strip():
                crate = f"{r['crate'].strip()}-{r['version'].strip()}"
                tests.setdefault(crate, set()).add(r["test"].strip())

    with open(args.out, "w", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["crate", "tests"])
        for crate, ts in tests.items():
            w.writerow([crate, ";".join(sorted(ts))])

    print(f"{sum(map(len, tests.values()))} tests across {len(tests)} crates written to {args.out}")


if __name__ == "__main__":
    main()
