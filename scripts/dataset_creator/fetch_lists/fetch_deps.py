#!/usr/bin/env python3
"""For every crate on crates.io, list its direct dependencies that are in an input list.

Usage: fetch_deps.py <targets.csv> [--skip CSV ...] [--dump DIR] [--keep-dump DIR] [-o CSV]

targets.csv needs a `name` column (e.g. all_c_ffi_crates.csv); versions are
ignored. Crates in targets.csv, or in any --skip CSV, are left out of the
output. To go a level deeper, rerun on the output, skipping earlier levels:
    ./fetch_deps.py all_c_ffi_crates.csv                    # level 1
    ./fetch_deps.py all_c_ffi_crates_dependents.csv --skip all_c_ffi_crates.csv

No crates are downloaded. Dependencies come from the crates.io nightly
database dump, https://static.crates.io/db-dump.tar.gz (~2 GB), which is
streamed: only the tables we need are written to disk (~5 GB).
For each crate we take its *default version* (the version crates.io shows)
and check its declared dependencies (any version requirement, any target,
optional or not) against the names in targets.csv.

Output (default: <targets_stem>_dependents.csv next to targets.csv), one row
per crate with >= 1 target dependency:
    crate,name,version,normal_deps,build_deps,dev_deps
The *_deps columns are `;`-joined, by dependency kind.

  --skip CSV       also leave these crates out of the output (repeatable)
  --dump DIR       read an already-extracted dump (DIR/data/*.csv)
  --keep-dump DIR  extract the downloaded tables to DIR and keep them, so a
                   later run can pass --dump DIR
"""
import argparse
import csv
import shutil
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
DUMP_URL = "https://static.crates.io/db-dump.tar.gz"
USER_AGENT = "aces-c-ffi-dataset-builder (CMU systems research; mmaclare@andrew.cmu.edu)"
TABLES = ("crates", "versions", "default_versions", "dependencies")
KINDS = {"0": "normal", "1": "build", "2": "dev"}  # dependencies.kind

csv.field_size_limit(sys.maxsize)  # crates.csv carries whole READMEs


def download_dump(dest, tables=TABLES):
    """Stream the dump and extract just `tables` into dest/data/."""
    wanted = {f"data/{t}.csv" for t in tables}
    req = urllib.request.Request(DUMP_URL, headers={"User-Agent": USER_AGENT})
    print(f"==> Streaming {DUMP_URL} (~2 GB) ...", flush=True)
    (dest / "data").mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(req) as resp, tarfile.open(fileobj=resp, mode="r|gz") as tar:
        for member in tar:
            # Top-level dir is the dump's timestamp, e.g. 2026-10-01-020025/data/x.csv
            rel = member.name.split("/", 1)[-1]
            if rel in wanted and member.isfile():
                print(f"    {rel}", flush=True)
                with tar.extractfile(member) as src, open(dest / rel, "wb") as out:
                    shutil.copyfileobj(src, out, 1 << 20)
                wanted.discard(rel)
                if not wanted:
                    break
    if wanted:
        sys.exit(f"error: dump is missing {sorted(wanted)}")


def rows(data, table):
    with open(data / f"{table}.csv", newline="") as f:
        yield from csv.DictReader(f)


def names(path):
    with open(path, newline="") as f:
        return {r["name"] for r in csv.DictReader(f) if r["name"]}


def open_dump(args, tables=TABLES):
    """Return (data dir, TemporaryDirectory or None) per --dump / --keep-dump."""
    if args.dump:
        return args.dump / "data", None
    if args.keep_dump:
        download_dump(args.keep_dump, tables)
        return args.keep_dump / "data", None
    tmp = tempfile.TemporaryDirectory(prefix="crates-dump-", dir=args.output.parent)
    download_dump(Path(tmp.name), tables)
    return Path(tmp.name) / "data", tmp


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("targets", type=Path, help="CSV with a `name` column")
    ap.add_argument("--skip", type=Path, action="append", default=[],
                    help="CSV with a `name` column; leave these crates out of the output (repeatable)")
    ap.add_argument("--dump", type=Path, help="already-extracted dump dir")
    ap.add_argument("--keep-dump", type=Path, help="extract the dump here and keep it")
    ap.add_argument("-o", "--output", type=Path)
    args = ap.parse_args()
    args.targets = args.targets.resolve()
    args.output = (args.output or args.targets.with_name(f"{args.targets.stem}_dependents.csv")).resolve()

    targets = names(args.targets)
    skip = set(targets)
    for p in args.skip:
        skip |= names(p)
    print(f"==> {len(targets)} target crates in {args.targets.name}, skipping {len(skip)} crates")

    data, tmp = open_dump(args)
    try:
        print("==> Reading crates / default versions ...", flush=True)
        crate_name = {r["id"]: r["name"] for r in rows(data, "crates")}
        default_vid = {r["version_id"]: r["crate_id"] for r in rows(data, "default_versions")
                       if crate_name.get(r["crate_id"]) not in skip}
        version_num = {r["id"]: r["num"] for r in rows(data, "versions") if r["id"] in default_vid}

        print("==> Scanning dependencies ...", flush=True)
        # default version_id -> kind -> set of target dep names
        found = {}
        for r in rows(data, "dependencies"):
            if r["version_id"] not in default_vid:
                continue
            dep = crate_name.get(r["crate_id"])
            if dep in targets:
                kind = KINDS.get(r["kind"], "normal")
                found.setdefault(r["version_id"], {}).setdefault(kind, set()).add(dep)
    finally:
        if tmp:
            tmp.cleanup()

    out_rows = []
    for vid, by_kind in found.items():
        name, version = crate_name[default_vid[vid]], version_num[vid]
        out_rows.append([f"{name}-{version}", name, version,
                         *(";".join(sorted(by_kind.get(k, ()))) for k in KINDS.values())])
    out_rows.sort(key=lambda r: r[1])

    tmp_out = args.output.with_suffix(".csv.tmp")
    with open(tmp_out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["crate", "name", "version", *(f"{k}_deps" for k in KINDS.values())])
        w.writerows(out_rows)
    tmp_out.replace(args.output)
    print(f"==> {len(out_rows)}/{len(default_vid)} crates directly depend on a target -> {args.output}")


if __name__ == "__main__":
    main()
