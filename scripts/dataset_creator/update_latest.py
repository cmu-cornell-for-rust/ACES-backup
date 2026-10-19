#!/usr/bin/env python3
"""Add a `latest_version` column to a dataset CSV and download newer versions.

Usage: update_latest.py CSV [DATASET_DIR] [--no-download] [--prerelease] [-j N]

Reads CSV (a header with a column containing "name" and one containing
"version", e.g. mirilli-dataset.csv: crate_name,version), looks up each
crate's latest version on crates.io, and writes it back to CSV in a
`latest_version` column (added after the version column, or refreshed if it
already exists). Every other column is kept as-is.

For each crate whose latest version differs from the listed one, the
crates.io tarball of the latest version is extracted into
DATASET_DIR/<name>-<latest>/, the same layout download_dataset.sh produces.
A folder that already exists is skipped, so reruns are cheap.

  DATASET_DIR    default: ../../datasets/<csv name minus "-dataset">, i.e.
                 datasets/mirilli for mirilli-dataset.csv on ACES
  --no-download  only fill in the column
  --prerelease   allow pre-release versions (1.0.0-rc.1) as "latest";
                 by default the newest non-yanked stable version is used,
                 falling back to the newest pre-release if there is no stable
  -j N           parallel lookups/downloads (default 8)

Lookups use the crates.io sparse index (index.crates.io) and downloads use
static.crates.io; both are CDNs, so neither is subject to the crates.io API
rate limit. Crates that can't be found get an empty latest_version and are
listed in DATASET_DIR/_latest_failures.log. Requirements: python3 (stdlib).
"""
import argparse
import csv
import io
import json
import sys
import tarfile
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent
UA = "crate-downloader (CMU systems research; via crates.io)"
COLUMN = "latest_version"


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    last = None
    for _ in range(3):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            if e.code == 404:
                raise
            last = e
        except (urllib.error.URLError, TimeoutError) as e:
            last = e
    raise last


def index_path(name):
    n = name.lower()
    if len(n) <= 2:
        return f"{len(n)}/{n}"
    if len(n) == 3:
        return f"3/{n[0]}/{n}"
    return f"{n[:2]}/{n[2:4]}/{n}"


def semver_key(v):
    """Sort key for a semver string; a release sorts above its pre-releases."""
    v = v.split("+", 1)[0]
    core, _, pre = v.partition("-")
    nums = tuple(int(x) if x.isdigit() else 0 for x in core.split("."))
    if not pre:
        return (nums, 1, ())
    ids = tuple((0, int(p), "") if p.isdigit() else (1, 0, p) for p in pre.split("."))
    return (nums, 0, ids)


def latest_version(name, allow_pre):
    body = fetch(f"https://index.crates.io/{index_path(name)}").decode()
    vers = [e["vers"] for e in map(json.loads, body.splitlines()) if not e.get("yanked")]
    if not vers:
        return None
    stable = [v for v in vers if "-" not in v.split("+", 1)[0]]
    pool = vers if allow_pre or not stable else stable
    return max(pool, key=semver_key)


def download(name, version, out_dir):
    dest = out_dir / f"{name}-{version}"
    if dest.is_dir():
        return "already present"
    data = fetch(f"https://static.crates.io/crates/{name}/{name}-{version}.crate")
    # a .crate file is a gzip tarball that unpacks to <name>-<version>/
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tar:
        if hasattr(tarfile, "data_filter"):
            tar.extractall(out_dir, filter="data")
        else:  # python < 3.12 without the backport: refuse paths escaping out_dir
            root = out_dir.resolve()
            for m in tar.getmembers():
                if not (root / m.name).resolve().is_relative_to(root) or m.issym() or m.islnk():
                    raise ValueError(f"unsafe tar member {m.name}")
            tar.extractall(out_dir)
    return "downloaded"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("csv", type=Path)
    ap.add_argument("dataset_dir", type=Path, nargs="?")
    ap.add_argument("--no-download", action="store_true")
    ap.add_argument("--prerelease", action="store_true")
    ap.add_argument("-j", "--jobs", type=int, default=8)
    args = ap.parse_args()

    out_dir = args.dataset_dir
    if out_dir is None:
        out_dir = HERE.parent.parent / "datasets" / args.csv.stem.removesuffix("-dataset")

    with open(args.csv, newline="") as f:
        reader = csv.DictReader(f)
        fields = list(reader.fieldnames or [])
        rows = list(reader)

    lower = [h.lower() for h in fields]
    name_col = next((h for h, l in zip(fields, lower) if "name" in l), None)
    ver_col = next((h for h, l in zip(fields, lower) if "version" in l and h != COLUMN), None)
    if not name_col or not ver_col:
        sys.exit(f"ERROR: no \"name\" and/or \"version\" column in header: {fields}")
    if COLUMN not in fields:
        fields.insert(fields.index(ver_col) + 1, COLUMN)

    names = sorted({r[name_col].strip() for r in rows if r[name_col].strip()})
    print(f"==> looking up {len(names)} crates (name: {name_col}, version: {ver_col})")

    def lookup(name):
        try:
            return name, latest_version(name, args.prerelease), None
        except urllib.error.HTTPError as e:
            return name, None, "not in index" if e.code == 404 else f"lookup failed ({e})"
        except Exception as e:
            return name, None, f"lookup failed ({e})"

    latest, failures = {}, []
    with ThreadPoolExecutor(args.jobs) as pool:
        for name, ver, err in pool.map(lookup, names):
            latest[name] = ver or ""
            if err or not ver:
                failures.append(f"{name} {err or 'no non-yanked versions'}")

    changed = []
    for r in rows:
        name, cur = r[name_col].strip(), r[ver_col].strip()
        r[COLUMN] = latest.get(name, "")
        if r[COLUMN] and r[COLUMN] != cur:
            changed.append((name, cur, r[COLUMN]))

    with open(args.csv, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        w.writerows(rows)
    print(f"==> wrote {COLUMN} to {args.csv}: {len(changed)} of {len(rows)} rows have a newer version")

    ok = skip = 0
    if changed and not args.no_download:
        out_dir.mkdir(parents=True, exist_ok=True)
        print(f"==> downloading latest versions -> {out_dir}/")
        targets = sorted({(n, v) for n, _, v in changed})

        def get(t):
            try:
                return t, download(*t, out_dir), None
            except Exception as e:
                return t, None, str(e)

        with ThreadPoolExecutor(args.jobs) as pool:
            for (name, ver), status, err in pool.map(get, targets):
                label = f"{name}-{ver}"
                if err:
                    print(f"    {label:<42} -> FAIL ({err})")
                    failures.append(f"{label} download failed ({err})")
                else:
                    print(f"    {label:<42} -> {status}")
                    ok += status == "downloaded"
                    skip += status == "already present"

    if failures:
        out_dir.mkdir(parents=True, exist_ok=True)
        log = out_dir / "_latest_failures.log"
        log.write_text("\n".join(failures) + "\n")
        print(f"==> {len(failures)} failures -> {log}")
    if not args.no_download:
        print(f"==> done: {ok} downloaded, {skip} already present")


if __name__ == "__main__":
    main()
