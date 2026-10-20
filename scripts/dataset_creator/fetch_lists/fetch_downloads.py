#!/usr/bin/env python3
"""Cache crates.io download counts for every crate in the datasets.

Usage: fetch_downloads.py [--dataset NAME=CSV ...] [--dump DIR] [--keep-dump DIR] [-o CSV]

The datasets default to (paths relative to scripts/):

  mirilli      mirilli-dataset.csv
  capslock     capslock-dataset.csv
  treeborrows  treeborrows-dataset.csv
  extern-c     dataset_creator/fetch_lists/all_c_ffi_crates.csv

each a CSV with a *name* column (crate_name, name); versions are ignored.
Giving --dataset replaces the defaults.

No crates are downloaded. Download counts come from the crates.io nightly
database dump (crate_downloads table; total across all versions), streamed
the same way as fetch_deps.py -- one ~2 GB download instead of a rate-limited
API request per crate.

Output (default: scripts/crate-downloads.csv), one row per crate name in any
dataset, sorted by name:
    crate_name,downloads
downloads is rounded: exact below 1,000, then to the nearest thousand (12k,
132k), million (4M, 65M) or billion (9B). Crates not on crates.io (renamed,
deleted) get an empty downloads.

  --dump DIR       read an already-extracted dump (DIR/data/*.csv)
  --keep-dump DIR  extract the downloaded tables to DIR and keep them
"""
import argparse
import csv
import tempfile
from pathlib import Path

from fetch_deps import HERE, download_dump, rows

SCRIPTS = HERE.parent.parent
TABLES = ("crates", "crate_downloads")
DEFAULT_DATASETS = [
    ("mirilli", SCRIPTS / "mirilli-dataset.csv"),
    ("capslock", SCRIPTS / "capslock-dataset.csv"),
    ("treeborrows", SCRIPTS / "treeborrows-dataset.csv"),
    ("extern-c", HERE / "all_c_ffi_crates.csv"),
]


def rounded(n):
    """1234 -> 1k, 131_600 -> 132k, 999_700 -> 1M, 4_200_000 -> 4M."""
    if n < 1000:
        return str(n)
    for unit, suffix, nxt in ((10**3, "k", 10**6), (10**6, "M", 10**9), (10**9, "B", None)):
        r = (n + unit // 2) // unit
        if nxt is None or r * unit < nxt:
            return f"{r}{suffix}"


def dataset_names(path):
    # utf-8-sig: files saved from Excel start with a BOM.
    with open(path, newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        col = next((c for c in reader.fieldnames or [] if "name" in c), None)
        if not col:
            raise SystemExit(f"error: {path} has no *name* column")
        return {r[col] for r in reader if r[col]}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dataset", action="append", metavar="NAME=CSV",
                    help="a dataset to cover; repeatable, replaces the defaults")
    ap.add_argument("--dump", type=Path, help="already-extracted dump dir")
    ap.add_argument("--keep-dump", type=Path, help="extract the dump here and keep it")
    ap.add_argument("-o", "--output", type=Path, default=SCRIPTS / "crate-downloads.csv")
    args = ap.parse_args()

    if args.dataset:
        datasets = []
        for d in args.dataset:
            if "=" not in d:
                ap.error(f"--dataset {d}: expected NAME=CSV")
            name, path = d.split("=", 1)
            datasets.append((name, Path(path)))
    else:
        datasets = DEFAULT_DATASETS

    names = set()
    for ds, path in datasets:
        ds_names = dataset_names(path)
        print(f"==> {ds}: {len(ds_names)} crates ({path})", flush=True)
        names |= ds_names

    tmp = None
    if args.dump:
        dump = args.dump
    elif args.keep_dump:
        dump = args.keep_dump
        download_dump(dump, TABLES)
    else:
        tmp = tempfile.TemporaryDirectory(prefix="crates-dump-", dir=args.output.parent)
        dump = Path(tmp.name)
        download_dump(dump, TABLES)
    data = dump / "data"

    try:
        print("==> Reading download counts ...", flush=True)
        # crates.io names are unique up to case and -/_, so match on that too
        canon = lambda n: n.lower().replace("_", "-")
        wanted = {canon(n) for n in names}
        crate_id = {canon(r["name"]): r["id"] for r in rows(data, "crates")
                    if canon(r["name"]) in wanted}
        ids = set(crate_id.values())
        downloads = {r["crate_id"]: int(r["downloads"]) for r in rows(data, "crate_downloads")
                     if r["crate_id"] in ids}
    finally:
        if tmp:
            tmp.cleanup()

    missing = 0
    tmp_out = args.output.with_suffix(".csv.tmp")
    with open(tmp_out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["crate_name", "downloads"])
        for name in sorted(names):
            n = downloads.get(crate_id.get(canon(name)))
            missing += n is None
            w.writerow([name, "" if n is None else rounded(n)])
    tmp_out.replace(args.output)
    print(f"==> {len(names)} crates ({missing} not on crates.io) -> {args.output}")


if __name__ == "__main__":
    main()
