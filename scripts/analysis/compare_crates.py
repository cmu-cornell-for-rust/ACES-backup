#!/usr/bin/env python3
"""Compare the crate sets of two CSVs.

Usage: compare_crates.py [--col NAME] [--col-a NAME] [--col-b NAME] [-q] <a.csv> <b.csv>

Reads the crate column of each CSV (by default the first column named
"crate" or "crates", case-insensitive -- so eval, build, tests and hyperfine
CSVs all work), takes the distinct values, and prints three sections:

    only in <a>     crates in a but not b
    only in <b>     crates in b but not a
    in both         the intersection

each sorted, one crate per line, with a count in the heading. -q prints the
counts only. --col sets the column name for both files; --col-a / --col-b set
it per file (e.g. --col-b Crate for mirilli-bugs.csv).
"""
import argparse
import csv
import sys

DEFAULT_COLS = ("crate", "crates")


def read_crates(path, col):
    with open(path, newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        fields = reader.fieldnames or []
        if col is None:
            col = next((c for c in fields if c.strip().lower() in DEFAULT_COLS), None)
            if col is None:
                sys.exit(f"error: {path}: no crate/crates column (columns: {', '.join(fields)}); use --col")
        elif col not in fields:
            sys.exit(f"error: {path}: no column {col!r} (columns: {', '.join(fields)})")
        return {row[col].strip() for row in reader if (row.get(col) or "").strip()}


def section(title, crates, quiet):
    print(f"{title}: {len(crates)}")
    if not quiet:
        for c in sorted(crates):
            print(f"  {c}")
        print()


def main():
    ap = argparse.ArgumentParser(description="Compare the crate sets of two CSVs.")
    ap.add_argument("a")
    ap.add_argument("b")
    ap.add_argument("--col", help="crate column name in both files")
    ap.add_argument("--col-a", help="crate column name in a")
    ap.add_argument("--col-b", help="crate column name in b")
    ap.add_argument("-q", "--quiet", action="store_true", help="print counts only")
    args = ap.parse_args()

    a = read_crates(args.a, args.col_a or args.col)
    b = read_crates(args.b, args.col_b or args.col)

    section(f"only in {args.a}", a - b, args.quiet)
    section(f"only in {args.b}", b - a, args.quiet)
    section("in both", a & b, args.quiet)


if __name__ == "__main__":
    main()
