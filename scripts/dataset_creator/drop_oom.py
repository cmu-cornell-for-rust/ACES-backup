#!/usr/bin/env python3
"""Drop the rows with error_type oom from an eval CSV.

Usage: drop_oom.py EVAL_CSV [OUT_CSV]

Writes the rows of EVAL_CSV (build,crate,test,status,...,error_type,error)
whose error_type is not "oom" to OUT_CSV, keeping every column and the row
order. Without OUT_CSV, EVAL_CSV is rewritten in place and the original is
kept as EVAL_CSV.bak.
"""
import argparse
import csv
import shutil
import sys
from pathlib import Path

csv.field_size_limit(sys.maxsize)  # error column holds long backtraces


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("eval", type=Path)
    ap.add_argument("out", nargs="?", type=Path)
    args = ap.parse_args()

    with open(args.eval, newline="") as f:
        reader = csv.DictReader(f)
        header = reader.fieldnames
        rows = list(reader)
    if not header or "error_type" not in header:
        sys.exit(f"{args.eval}: no error_type column")

    kept = [r for r in rows if (r["error_type"] or "").strip() != "oom"]
    out = args.out or args.eval
    if args.out is None:
        shutil.copy2(args.eval, args.eval.with_name(args.eval.name + ".bak"))
    with open(out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=header, lineterminator="\n")
        w.writeheader()
        w.writerows(kept)

    print(f"{len(rows)} rows in {args.eval.name}; {len(rows) - len(kept)} oom rows "
          f"dropped; {len(kept)} written to {out}")


if __name__ == "__main__":
    main()
