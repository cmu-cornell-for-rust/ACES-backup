#!/usr/bin/env python3
"""Find which crates in a dataset CSV also appear in crater_foreign_fn.csv.

Usage: match_crater.py <input.csv> [crater.csv] [crater_all.csv]

The input CSV needs a crate-name column (`name` or `crate_name`) and a
`version` column. Writes <input_stem>_crater_match.csv next to the input,
with one row per input crate that appears in crater (versions need not match).

If crater_all.csv (the full crater index, from fetch_crater_index.sh) exists,
also writes <input_stem>_crater_nomatch.csv: input crates that crater ran but
that are not in crater.csv, i.e. Miri never hit a foreign-function call.
"""
import csv
import sys
from pathlib import Path

NAME_COLUMNS = ("name", "crate_name")
HERE = Path(__file__).resolve().parent
DEFAULT_CRATER = HERE / "crater_foreign_fn.csv"
DEFAULT_CRATER_ALL = HERE / "crater_all.csv"


def name_column(fieldnames, path):
    for col in NAME_COLUMNS:
        if col in fieldnames:
            return col
    sys.exit(f"error: {path} has no crate-name column (expected one of {NAME_COLUMNS})")


def load_versions(path):
    """crate name -> list of versions seen in the CSV at path"""
    versions = {}
    with open(path, newline="") as f:
        reader = csv.DictReader(f)
        col = name_column(reader.fieldnames, path)
        for row in reader:
            seen = versions.setdefault(row[col], [])
            if row["version"] not in seen:
                seen.append(row["version"])
    return versions


def main():
    if len(sys.argv) not in (2, 3, 4):
        sys.exit(__doc__)
    input_path = Path(sys.argv[1]).resolve()
    crater_path = Path(sys.argv[2]).resolve() if len(sys.argv) >= 3 else DEFAULT_CRATER
    all_path = Path(sys.argv[3]).resolve() if len(sys.argv) == 4 else DEFAULT_CRATER_ALL

    crater_versions = load_versions(crater_path)
    all_versions = None
    if all_path.exists():
        all_versions = load_versions(all_path)
    elif len(sys.argv) == 4:
        sys.exit(f"error: {all_path} not found")

    out_path = input_path.with_name(f"{input_path.stem}_crater_match.csv")
    nomatch_path = input_path.with_name(f"{input_path.stem}_crater_nomatch.csv")
    total = matched = exact = on_crater = 0
    nomatch_rows = []
    with open(input_path, newline="") as fin, open(out_path, "w", newline="") as fout:
        reader = csv.DictReader(fin)
        col = name_column(reader.fieldnames, input_path)
        writer = csv.writer(fout)
        writer.writerow(["name", "version", "crater_versions", "version_match"])
        for row in reader:
            total += 1
            if all_versions is not None and row[col] in all_versions:
                on_crater += 1
            versions = crater_versions.get(row[col])
            if versions is None:
                if all_versions is not None and row[col] in all_versions:
                    all_vs = all_versions[row[col]]
                    nomatch_rows.append([row[col], row["version"], ";".join(all_vs),
                                         row["version"] in all_vs])
                continue
            matched += 1
            is_exact = row["version"] in versions
            exact += is_exact
            writer.writerow([row[col], row["version"], ";".join(versions), is_exact])

    print(f"{matched}/{total} crates found in crater ({exact} with matching version)")
    print(f"wrote {out_path}")
    if all_versions is not None:
        with open(nomatch_path, "w", newline="") as f:
            writer = csv.writer(f)
            writer.writerow(["name", "version", "crater_versions", "version_match"])
            writer.writerows(nomatch_rows)
        print(f"{on_crater}/{total} crates on crater; {len(nomatch_rows)} of those "
              f"not in {crater_path.name}")
        print(f"wrote {nomatch_path}")
    else:
        print(f"note: {all_path} not found (run fetch_crater_index.sh); "
              f"skipping on-crater-but-unmatched report")


if __name__ == "__main__":
    main()
