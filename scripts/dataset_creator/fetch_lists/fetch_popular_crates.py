#!/usr/bin/env python3
"""List every crate on crates.io with more than N all-time downloads.

Usage: fetch_popular_crates.py [--min-downloads N] [--dump DIR] [--keep-dump DIR] [-o CSV]

No crates are downloaded. Download counts come from the crates.io nightly
database dump (crate_downloads table; total across all versions), streamed
the same way as fetch_deps.py. Each crate is listed at its
*default version* (the version crates.io shows).

Output (default: popular_crates.csv), sorted by downloads, highest first:
    crate,name,version,downloads,repository

  --min-downloads N  keep crates with downloads > N (default 1000)
  --dump DIR         read an already-extracted dump (DIR/data/*.csv)
  --keep-dump DIR    extract the downloaded tables to DIR and keep them
"""
import argparse
import csv
import tempfile
from pathlib import Path

from fetch_deps import HERE, download_dump, rows

TABLES = ("crates", "versions", "default_versions", "crate_downloads")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--min-downloads", type=int, default=1000)
    ap.add_argument("--dump", type=Path, help="already-extracted dump dir")
    ap.add_argument("--keep-dump", type=Path, help="extract the dump here and keep it")
    ap.add_argument("-o", "--output", type=Path, default=HERE / "popular_crates.csv")
    args = ap.parse_args()

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
        downloads = {r["crate_id"]: int(r["downloads"]) for r in rows(data, "crate_downloads")
                     if int(r["downloads"]) > args.min_downloads}
        default_vid = {r["version_id"]: r["crate_id"] for r in rows(data, "default_versions")
                       if r["crate_id"] in downloads}
        # crate_id -> (version, repository)
        version = {default_vid[r["id"]]: (r["num"], r["repository"])
                   for r in rows(data, "versions") if r["id"] in default_vid}
        crates = {r["id"]: (r["name"], r["repository"]) for r in rows(data, "crates")
                  if r["id"] in downloads}
    finally:
        if tmp:
            tmp.cleanup()

    out_rows = []
    for crate_id, (name, crate_repo) in crates.items():
        if crate_id not in version:
            continue  # no default version (every version deleted)
        num, ver_repo = version[crate_id]
        repo = " ".join((ver_repo or crate_repo or "").split())
        out_rows.append([f"{name}-{num}", name, num, downloads[crate_id], repo])
    out_rows.sort(key=lambda r: (-r[3], r[1]))

    tmp_out = args.output.with_suffix(".csv.tmp")
    with open(tmp_out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["crate", "name", "version", "downloads", "repository"])
        w.writerows(out_rows)
    tmp_out.replace(args.output)
    print(f"==> {len(out_rows)} crates with > {args.min_downloads} downloads -> {args.output}")


if __name__ == "__main__":
    main()
