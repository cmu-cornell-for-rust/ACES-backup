#!/usr/bin/env python3
"""Carry test lists over to the latest-version test CSV for unchanged crates.

Usage: merge_unchanged_tests.py [DATASET_CSV] [TESTS_CSV] [LATEST_TESTS_CSV] [--dry-run]

For every crate in DATASET_CSV (crate_name,version,latest_version,version_differs)
whose version_differs is "false", the row for <name>-<version> in TESTS_CSV
(crate,tests) also applies to the latest version, so it is added to
LATEST_TESTS_CSV unless a row for that crate is already there. Existing rows
are never changed; the output is sorted by crate, matching the input.

Defaults: ../mirilli-dataset.csv ../mirilli-tests.csv ../mirilli-tests-latest.csv
"""
import argparse
import csv
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
csv.field_size_limit(sys.maxsize)  # some crates list thousands of tests


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dataset", nargs="?", default=HERE.parent / "mirilli-dataset.csv")
    ap.add_argument("tests", nargs="?", default=HERE.parent / "mirilli-tests.csv")
    ap.add_argument("latest", nargs="?", default=HERE.parent / "mirilli-tests-latest.csv")
    ap.add_argument("--dry-run", action="store_true", help="only report what would be added")
    args = ap.parse_args()

    with open(args.dataset, newline="") as f:
        unchanged = {
            f"{r['crate_name']}-{r['version']}"
            for r in csv.DictReader(f)
            if r["version_differs"].strip().lower() == "false"
        }

    with open(args.tests, newline="") as f:
        tests = {r["crate"]: r["tests"] for r in csv.DictReader(f)}

    with open(args.latest, newline="") as f:
        reader = csv.DictReader(f)
        header = reader.fieldnames
        latest = {r["crate"]: r["tests"] for r in reader}

    added = sorted(c for c in unchanged if c in tests and c not in latest)
    missing = sorted(c for c in unchanged if c not in tests)
    print(f"{len(unchanged)} unchanged crates; {len(added)} added, "
          f"{len(unchanged & latest.keys())} already present, {len(missing)} not in {Path(args.tests).name}")
    for c in added:
        print(f"  + {c}")

    if args.dry_run or not added:
        return
    for c in added:
        latest[c] = tests[c]
    with open(args.latest, "w", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(header)
        for c in sorted(latest):
            w.writerow([c, latest[c]])


if __name__ == "__main__":
    main()
