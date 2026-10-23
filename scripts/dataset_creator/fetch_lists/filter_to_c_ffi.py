#!/usr/bin/env python3
"""Keep only the rows of a crate_name,version CSV whose crate is in the C FFI lists.

Usage: filter_to_c_ffi.py <input.csv> [-o CSV]

A crate is kept if its name appears in all_c_ffi_crates.csv,
all_c_ffi_crates_dependents.csv or all_c_ffi_crates_dependents_dependents.csv
(the `name` column; versions are ignored). Names are compared the way
crates.io does: case-insensitively, with `-` and `_` treated as the same.

Output (default: <input_stem>_c_ffi.csv next to input.csv) has the same
columns as the input.
"""
import argparse
import csv
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
LISTS = [
    HERE / "all_c_ffi_crates.csv",
    HERE / "all_c_ffi_crates_dependents.csv",
    HERE / "all_c_ffi_crates_dependents_dependents.csv"
]


def norm(name):
    return name.strip().lower().replace("_", "-")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("input", type=Path, help="CSV with a crate_name column")
    ap.add_argument("-o", "--output", type=Path)
    args = ap.parse_args()
    out = args.output or args.input.with_name(f"{args.input.stem}_c_ffi.csv")

    keep = set()
    for path in LISTS:
        with path.open(newline="") as f:
            keep.update(norm(row["name"]) for row in csv.DictReader(f))

    with args.input.open(newline="") as f:
        reader = csv.DictReader(f)
        rows = list(reader)
        fields = reader.fieldnames
    kept = [row for row in rows if norm(row["crate_name"]) in keep]

    with out.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        w.writerows(kept)

    print(f"kept {len(kept)} of {len(rows)} crates -> {out}", file=sys.stderr)


if __name__ == "__main__":
    main()
