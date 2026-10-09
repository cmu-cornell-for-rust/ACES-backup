#!/usr/bin/env python3
"""Find which crates in a dataset CSV also appear in crater_foreign_fn.csv.

Usage: match_crater.py <input.csv> [crater.csv]

The input CSV needs a crate-name column (`name` or `crate_name`) and a
`version` column. Writes <input_stem>_crater_match.csv next to the input,
with one row per input crate that appears in crater (versions need not match).
"""
import csv
import sys
from pathlib import Path

NAME_COLUMNS = ("name", "crate_name")
DEFAULT_CRATER = Path(__file__).resolve().parent / "crater_foreign_fn.csv"


def name_column(fieldnames, path):
    for col in NAME_COLUMNS:
        if col in fieldnames:
            return col
    sys.exit(f"error: {path} has no crate-name column (expected one of {NAME_COLUMNS})")


def main():
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    input_path = Path(sys.argv[1]).resolve()
    crater_path = Path(sys.argv[2]).resolve() if len(sys.argv) == 3 else DEFAULT_CRATER

    # crate name -> list of versions seen in crater
    crater_versions = {}
    with open(crater_path, newline="") as f:
        reader = csv.DictReader(f)
        col = name_column(reader.fieldnames, crater_path)
        for row in reader:
            versions = crater_versions.setdefault(row[col], [])
            if row["version"] not in versions:
                versions.append(row["version"])

    out_path = input_path.with_name(f"{input_path.stem}_crater_match.csv")
    total = matched = exact = 0
    with open(input_path, newline="") as fin, open(out_path, "w", newline="") as fout:
        reader = csv.DictReader(fin)
        col = name_column(reader.fieldnames, input_path)
        writer = csv.writer(fout)
        writer.writerow(["name", "version", "crater_versions", "version_match"])
        for row in reader:
            total += 1
            versions = crater_versions.get(row[col])
            if versions is None:
                continue
            matched += 1
            is_exact = row["version"] in versions
            exact += is_exact
            writer.writerow([row[col], row["version"], ";".join(versions), is_exact])

    print(f"{matched}/{total} crates found in crater ({exact} with matching version)")
    print(f"wrote {out_path}")


if __name__ == "__main__":
    main()
