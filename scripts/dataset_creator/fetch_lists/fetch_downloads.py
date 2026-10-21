#!/usr/bin/env python3
"""Cache crates.io download counts and newest releases for every crate in the datasets.

Usage: fetch_downloads.py [--dataset NAME=CSV ...] [--dump DIR] [--keep-dump DIR] [-o CSV]

The datasets default to (paths relative to scripts/):

  mirilli      mirilli-dataset.csv
  capslock     capslock-dataset.csv
  treeborrows  treeborrows-dataset.csv
  extern-c     dataset_creator/fetch_lists/all_c_ffi_crates.csv

each a CSV with a *name* column (crate_name, name); versions are ignored.
Giving --dataset replaces the defaults.

No crates are downloaded. Everything comes from the crates.io nightly
database dump (crates, crate_downloads and versions tables), streamed the
same way as fetch_deps.py -- one ~2 GB download instead of a rate-limited
API request per crate.

Output (default: scripts/analysis/crate-downloads.csv), one row per crate name in any
dataset, sorted by name:
    crate_name,downloads,newest_version,last_released
  downloads        total across all versions, rounded: exact below 1,000,
                   then to the nearest thousand (12k, 132k), million (4M,
                   65M) or billion (9B)
  newest_version   newest unyanked stable release (newest unyanked release
                   if none is stable), as crates.io's max_stable_version
  last_released    date of the newest unyanked release, YYYY-MM-DD
Crates whose every version is yanked fall back to their yanked releases for
newest_version and last_released. Crates not on crates.io (renamed, deleted) get empty columns. bug_report.py
reads this file instead of querying crates.io.

  --dump DIR       read an already-extracted dump (DIR/data/*.csv)
  --keep-dump DIR  extract the downloaded tables to DIR and keep them
"""
import argparse
import csv
import tempfile
from pathlib import Path

from fetch_deps import HERE, download_dump, rows

SCRIPTS = HERE.parent.parent
TABLES = ("crates", "crate_downloads", "versions")
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


def semver_key(v):
    """Semver precedence: 1.10.0 > 1.9.0 > 1.9.0-rc.10 > 1.9.0-rc.2."""
    v = v.split("+", 1)[0]
    core, _, pre = v.partition("-")
    nums = tuple(int(x) if x.isdigit() else 0 for x in core.split("."))
    if not pre:
        return (nums, 1, ())
    # numeric identifiers sort before alphanumeric ones, and by value
    return (nums, 0, tuple((0, int(x), "") if x.isdigit() else (1, 0, x) for x in pre.split(".")))


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
    ap.add_argument("-o", "--output", type=Path, default=SCRIPTS / "analysis" / "crate-downloads.csv")
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
        print("==> Reading versions ...", flush=True)
        # crate id -> (newest stable, newest any, latest created_at), unyanked
        # in newest; yanked in newest_yanked, used only if a crate has no
        # unyanked release
        newest, newest_yanked = {}, {}
        for r in rows(data, "versions"):
            if r["crate_id"] not in ids:
                continue
            table = newest_yanked if r["yanked"] == "t" else newest
            stable, any_, released = table.get(r["crate_id"], ("", "", ""))
            num = r["num"]
            if "-" not in num.split("+", 1)[0] and (not stable or semver_key(num) > semver_key(stable)):
                stable = num
            if not any_ or semver_key(num) > semver_key(any_):
                any_ = num
            table[r["crate_id"]] = (stable, any_, max(released, r["created_at"]))
    finally:
        if tmp:
            tmp.cleanup()

    missing = 0
    tmp_out = args.output.with_suffix(".csv.tmp")
    with open(tmp_out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["crate_name", "downloads", "newest_version", "last_released"])
        for name in sorted(names):
            cid = crate_id.get(canon(name))
            n = downloads.get(cid)
            stable, any_, released = newest.get(cid) or newest_yanked.get(cid, ("", "", ""))
            missing += cid is None
            w.writerow([name, "" if n is None else rounded(n), stable or any_, released[:10]])
    tmp_out.replace(args.output)
    print(f"==> {len(names)} crates ({missing} not on crates.io) -> {args.output}")


if __name__ == "__main__":
    main()
