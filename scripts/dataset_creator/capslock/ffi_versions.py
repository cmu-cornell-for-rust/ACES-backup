#!/usr/bin/env python3
"""Write a crate_name,version CSV for the crates listed in ffi.json.

The version of each crate is the one capslock analysed, taken from db.json,
which maps name -> "data-extracted/<aa>/<bb>/<name>-<version>".
Crates missing from db.json are reported on stderr and skipped.

Usage:
    ./ffi_versions.py [--ffi ffi.json] [--db db.json] [-o ffi_versions.csv]
"""
import argparse
import csv
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def version_from_path(name, path):
    base = path.rstrip("/").rsplit("/", 1)[-1]
    prefix = name + "-"
    if not base.startswith(prefix):
        return None
    return base[len(prefix):]


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--ffi", type=Path, default=HERE / "ffi.json")
    ap.add_argument("--db", type=Path, default=HERE / "db.json")
    ap.add_argument("-o", "--output", type=Path, default=HERE / "ffi_versions.csv")
    args = ap.parse_args()

    names = json.loads(args.ffi.read_text())
    db = json.loads(args.db.read_text())

    rows, missing, bad = [], [], []
    for name in dict.fromkeys(names):  # dedupe, keep order
        path = db.get(name)
        if path is None:
            missing.append(name)
            continue
        version = version_from_path(name, path)
        if not version:
            bad.append((name, path))
            continue
        rows.append((name, version))

    with args.output.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["crate_name", "version"])
        w.writerows(rows)

    print(f"wrote {len(rows)} crates to {args.output}", file=sys.stderr)
    if missing:
        print(f"{len(missing)} not in db.json: {', '.join(missing)}", file=sys.stderr)
    for name, path in bad:
        print(f"could not parse version for {name}: {path}", file=sys.stderr)


if __name__ == "__main__":
    main()
