#!/usr/bin/env python3
"""Add an `avg_size` column (nodes / alloc_ids) to combined.csv and sort descending.

avg_size is the mean tree size per root at that origin line location.
Rows with alloc_ids == 0 get avg_size = 0 (can't divide) and sort to the bottom.

Usage: add_avg_size.py [IN.csv] [-o OUT.csv]
       defaults: IN=combined.csv  OUT=combined_avg_size.csv
"""
import argparse
import csv
import sys

csv.field_size_limit(sys.maxsize)  # the `tests` column has huge fields


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("infile", nargs="?", default="combined.csv")
    ap.add_argument("-o", "--output", default="combined_avg_size.csv")
    args = ap.parse_args()

    with open(args.infile, newline="") as f:
        reader = csv.DictReader(f)
        fieldnames = reader.fieldnames
        if fieldnames is None:
            print("empty input", file=sys.stderr)
            return 1
        for col in ("nodes", "alloc_ids"):
            if col not in fieldnames:
                print(f"missing column {col!r}; have {fieldnames}", file=sys.stderr)
                return 1
        rows = list(reader)

    for r in rows:
        nodes = int(r["nodes"])
        alloc = int(r["alloc_ids"])
        r["avg_size"] = nodes / alloc if alloc else 0.0

    rows.sort(key=lambda r: r["avg_size"], reverse=True)

    out_fields = list(fieldnames) + ["avg_size"]
    with open(args.output, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=out_fields)
        writer.writeheader()
        writer.writerows(rows)

    print(f"wrote {len(rows)} rows -> {args.output}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
