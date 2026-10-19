#!/usr/bin/env python3
"""Compare the crate sets of two CSVs.

Usage: compare_crates.py [--col NAME] [--col-a NAME] [--col-b NAME] [-V] [-q] <a.csv> <b.csv>

Reads the crate column of each CSV (by default the first column named
"crate", "crates" or "crate_name", case-insensitive -- so eval, build, tests,
hyperfine and dataset CSVs all work), takes the distinct values, and prints three sections:

    only in <a>     crates in a but not b
    only in <b>     crates in b but not a
    in both         the intersection

each sorted, one crate per line, with a count in the heading. -q prints the
counts only. --col sets the column name for both files; --col-a / --col-b set
it per file (e.g. --col-b Crate for mirilli-bugs.csv). -V/--ignore-version
strips a trailing "-<version>" (a2s-0.6.1 -> a2s) so crates match by name
alone, e.g. to compare a tests CSV against a dataset's bare crate_name column.
"""
import argparse
import csv
import re
import sys

csv.field_size_limit(sys.maxsize)  # tests CSVs can list thousands of tests

DEFAULT_COLS = ("crate", "crates", "crate_name")
# "-<major>.<minor>[.<patch>][-pre][+build]" at the end of name-version
VERSION_RE = re.compile(r"-\d+\.\d+(\.\d+)?(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$")


def read_crates(path, col, ignore_version=False):
    with open(path, newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        fields = reader.fieldnames or []
        if col is None:
            col = next((c for c in fields if c.strip().lower() in DEFAULT_COLS), None)
            if col is None:
                sys.exit(f"error: {path}: no crate/crates column (columns: {', '.join(fields)}); use --col")
        elif col not in fields:
            sys.exit(f"error: {path}: no column {col!r} (columns: {', '.join(fields)})")
        crates = {row[col].strip() for row in reader if (row.get(col) or "").strip()}
    if ignore_version:
        crates = {VERSION_RE.sub("", c) for c in crates}
    return crates


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
    ap.add_argument("-V", "--ignore-version", action="store_true",
                    help="match on crate name only, dropping a trailing -<version>")
    ap.add_argument("-q", "--quiet", action="store_true", help="print counts only")
    args = ap.parse_args()

    a = read_crates(args.a, args.col_a or args.col, args.ignore_version)
    b = read_crates(args.b, args.col_b or args.col, args.ignore_version)

    section(f"only in {args.a}", a - b, args.quiet)
    section(f"only in {args.b}", b - a, args.quiet)
    section("in both", a & b, args.quiet)


if __name__ == "__main__":
    main()
