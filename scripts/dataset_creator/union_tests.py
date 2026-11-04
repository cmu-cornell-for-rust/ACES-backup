#!/usr/bin/env python3
"""Union of test CSVs: every (crate, test) in any of them.

Usage: union_tests.py -o OUT_CSV TESTS_CSV [TESTS_CSV ...]

    union_tests.py -o ../treeborrows-union-nodoc.csv \\
        ../treeborrows-list-nodoc.csv ../../outputs/treeborrows_list_no_docs.csv

Each input is a crate,tests CSV (';'-joined names) or a one-test-per-row
crate,test CSV, as run_eval_dataset.sh --tests takes. For crate,tests inputs
only a crate's first row counts, as in run_eval_dataset.sh. Writes crate,tests:
crates in order of first appearance (the first input's order, then crates new
in later inputs), each crate's tests likewise -- duplicates dropped. Crates
with no tests are left out.
"""
import argparse
import csv
import sys
from pathlib import Path

csv.field_size_limit(sys.maxsize)  # some crates list thousands of tests


def read_pairs(path):
    """(crate, test) pairs of one tests CSV, in file order."""
    with open(path, newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        cols = {h.strip().lower(): h for h in reader.fieldnames or []}
        if "crate" not in cols or not ({"test", "tests"} & cols.keys()):
            sys.exit(f"{path}: needs a crate column and a test or tests column")
        per_row = "test" in cols
        tcol = cols["test" if per_row else "tests"]
        seen_crates = set()
        for r in reader:
            crate = (r[cols["crate"]] or "").strip()
            if not crate:
                continue
            if not per_row:
                if crate in seen_crates:
                    continue  # first row per crate wins
                seen_crates.add(crate)
            for t in (r[tcol] or "").split(";") if not per_row else [r[tcol] or ""]:
                if t.strip():
                    yield crate, t.strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", "--out", type=Path, required=True)
    ap.add_argument("tests", type=Path, nargs="+")
    args = ap.parse_args()
    if any(args.out.resolve() == p.resolve() for p in args.tests):
        sys.exit("OUT_CSV must differ from the inputs")

    union = {}  # crate -> {test: None}, insertion-ordered
    for path in args.tests:
        before = sum(map(len, union.values()))
        n = 0
        for crate, test in read_pairs(path):
            union.setdefault(crate, {})[test] = None
            n += 1
        print(f"{path.name}: {n} tests, {sum(map(len, union.values())) - before} new")

    with open(args.out, "w", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["crate", "tests"])
        for crate, tests in union.items():
            w.writerow([crate, ";".join(tests)])
    print(f"{len(union)} crates / {sum(map(len, union.values()))} tests -> {args.out}")


if __name__ == "__main__":
    main()
