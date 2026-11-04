#!/usr/bin/env python3
"""Drop the doc tests from a test CSV.

Usage: drop_doc_tests.py TESTS_CSV [OUT_CSV]

    drop_doc_tests.py ../treeborrows-list.csv   # -> ../treeborrows-list-nodoc.csv

Doc tests are the "doc:<name>#<filter>[#<skip>...]" entries that
build_dataset.sh / list_tests.sh --doc write. Handles both formats
run_eval_dataset.sh --tests takes:

  crate,tests,...   ';'-joined names per crate: doc tests are removed from the
                    list, and a crate left with none is dropped
  ...,test,...      one test per row: doc-test rows are dropped

Every other column and the row order are kept. Without OUT_CSV it writes
<TESTS_CSV stem>-nodoc.csv next to TESTS_CSV (never in place). Its own name
gives run_eval_dataset.sh a separate master CSV for the run.

Matches the Tree Borrows paper's pipeline (crater-at-home on
`cargo miri nextest run`), which can't run doc tests.
"""
import argparse
import csv
import sys
from pathlib import Path

csv.field_size_limit(sys.maxsize)  # some crates list thousands of tests


def is_doc(test):
    # "doc:<name>#...", not a unit test in a module named doc ("doc::foo").
    t = test.strip()
    return t.startswith("doc:") and not t.startswith("doc::")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("tests", type=Path)
    ap.add_argument("out", nargs="?", type=Path)
    args = ap.parse_args()

    out = args.out or args.tests.with_name(f"{args.tests.stem}-nodoc.csv")
    if out.resolve() == args.tests.resolve():
        sys.exit("OUT_CSV must differ from TESTS_CSV")

    with open(args.tests, newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        header = reader.fieldnames
        rows = list(reader)
    if not header:
        sys.exit(f"{args.tests}: empty")
    cols = {h.strip().lower(): h for h in header}

    kept = []
    doc_dropped = left = crates_dropped = 0
    if "test" in cols:  # one test per row
        col = cols["test"]
        for r in rows:
            if is_doc(r[col] or ""):
                doc_dropped += 1
            else:
                kept.append(r)
        left = len(kept)
        summary = f"{len(rows)} rows; {doc_dropped} doc-test rows dropped; {left} kept"
    elif "tests" in cols:  # crate,tests with ';'-joined names
        col = cols["tests"]
        for r in rows:
            tests = [t for t in (r[col] or "").split(";") if t.strip()]
            rest = [t for t in tests if not is_doc(t)]
            doc_dropped += len(tests) - len(rest)
            if not rest:
                crates_dropped += 1
                continue
            r[col] = ";".join(rest)
            left += len(rest)
            kept.append(r)
        summary = (f"{len(rows)} crates; {doc_dropped} doc tests removed; "
                   f"{crates_dropped} crates left with no tests dropped; "
                   f"{len(kept)} crates / {left} tests kept")
    else:
        sys.exit(f"{args.tests}: no test or tests column")

    with open(out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=header, lineterminator="\n")
        w.writeheader()
        w.writerows(kept)
    print(f"{args.tests.name}: {summary} -> {out}")


if __name__ == "__main__":
    main()
