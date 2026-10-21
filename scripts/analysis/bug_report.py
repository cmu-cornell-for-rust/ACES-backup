#!/usr/bin/env python3
"""Per-bug report CSV: eval CSVs' bsan rows joined with the datasets and crates.io.

Usage: bug_report.py [-o OUT.csv] [--dataset NAME=CSV ...] [--downloads CSV]
                     <eval.csv> [more.csv ...]

    bug_report.py ../outputs/experimental-bsan-mirilli-latest-eval.csv

Each input is a *-eval.csv from run_eval_dataset.sh (build,crate,test,status,
...,timestamp,...,error_type,error), whole or already filtered down (e.g. in
Excel). Only rows with error_type bsan are kept. A (build, crate, test) seen
more than once -- in one file or across them -- is reported once, from its
most recent timestamp, at the position it was first seen. That's the key
rather than the whole row since Excel rewrites numbers (1.080 -> 1.08).
The datasets default to (paths relative to scripts/):

  mirilli      mirilli-dataset.csv
  capslock     capslock-dataset.csv
  treeborrows  treeborrows-dataset.csv
  extern-c     dataset_creator/fetch_lists/all_c_ffi_crates.csv

each a CSV with a *name* column (crate_name, name) and a version column, plus
optionally latest_version as written by update_latest.py. Giving --dataset
replaces the defaults. Writes one row per bug, in input order, with columns:

  bug id            B1, B2, ...: rows with the same bug key share an id. The key
                    is "tag created at" for aliasing violations that have one
                    outside <std>, else "bug location" (a std helper like
                    slice::as_mut_ptr creates tags for unrelated bugs).
                    Numbered by first appearance, in input order, so appending
                    an eval CSV (earlier ones unchanged, same order) keeps the
                    old ids and numbers new bugs after them
  diagnosis         auto-filled where it can be, else left blank for review
                    (the other options are "False Positive" and "Rerun!"):
                      True Positive           an aliasing violation
                      Duplicate TP (see new)  an aliasing violation on an
                                              out-of-date version, when the
                                              same test on a newer version of
                                              the crate (in bugs.csv) is one too
  crate             crate name (the bugs CSV's crate column is <name>-<version>)
  version           the version that was tested
  last updated      date of the crate's newest release on crates.io
  up to date?       yes if the tested version is the crate's current newest
                    stable release on crates.io (newest release if none is stable)
  datasets          the datasets the crate is in, e.g. "mirilli,
                    capslock-updated": <dataset> if the dataset's version
                    column lists the tested version, else <dataset>-updated
                    if the crate is in it at another version and the tested
                    version is up to date or is the dataset's latest_version
  # downloads       all-time crates.io downloads of the crate, rounded (12k, 4M)
  container         the eval build (the image the test ran in)
  test timestamp    when the test finished
  runtime (s)       the test's run_seconds
  test              as in the bugs CSV
  error type        from the first UB report line in the error:
                      aliasing violation     "Undefined Behavior: {read access,
                                             write access,reborrow,deallocation}
                                             through {tag} at {alloc}[{offset}]
                                             is forbidden"
                      use after free         "... trying to access an
                                             allocation that has been freed"
                      access out of bounds   "... an access of size ..."
                      other                  none of the above
  bug location      file:line:col of the bad access, the --> under the UB line
  tag created at    aliasing violations: where the accessed tag was created
                    (help: the accessed tag ... was created here) -- usually
                    the unsound code itself, where the access may be far off
                    (e.g. libgit2's C code for a git2 bug)
                    Locations are path:line:col with the eval job's paths cut
                    to <crate>-<version>/..., or <std>/... for the toolchain
  error             as in the bugs CSV

The crates.io columns (last updated, up to date?, # downloads) come from
--downloads (default analysis/crate-downloads.csv, as written by
fetch_downloads.py from the crates.io database dump), so they are as fresh
as its last run. Crates it doesn't list are looked up on crates.io instead,
at most one request a second (its crawler policy), and cached in
analysis/crates-io-cache.json for the day; --refresh looks them up again.
A crate that isn't on crates.io gets empty crates.io columns.
The output defaults to <first input minus .csv>-report.csv and is written with a
UTF-8 BOM so Excel opens it cleanly. Requirements: python3 >= 3.6 (stdlib).
"""
import argparse
import csv
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

USER_AGENT = "aces-bug-report (CMU systems research; via crates.io)"
API = "https://crates.io/api/v1/crates"
HEADER = ["bug id", "diagnosis", "crate", "version", "last updated", "up to date?", "datasets",
          "# downloads", "container", "test timestamp", "runtime (s)", "test",
          "error type", "bug location", "tag created at", "error"]

ap = argparse.ArgumentParser()
ap.add_argument("-o", "--output", help="output CSV (default: <bugs minus .csv>-report.csv)")
ap.add_argument("--dataset", action="append", metavar="NAME=CSV",
                help="a dataset to tag crates with; repeatable, replaces the defaults")
ap.add_argument("--downloads", metavar="CSV",
                help="fetch_downloads.py output (default: analysis/crate-downloads.csv)")
ap.add_argument("--refresh", action="store_true",
                help="look crates missing from --downloads up on crates.io again, ignoring the cache")
ap.add_argument("eval_csvs", nargs="+", help="run_eval_dataset.sh *-eval.csv files, whole or filtered")
args = ap.parse_args()
out_path = args.output or re.sub(r"\.csv$", "", args.eval_csvs[0]) + "-report.csv"

# bsan error cells can be large; lift the 128 KiB default field limit.
csv.field_size_limit(sys.maxsize)

# (build, crate, test) -> its most recent bsan row; dicts keep first-seen order
latest = {}
nread = 0
for path in args.eval_csvs:
    with open(path, newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        for col in ("build", "crate", "test", "timestamp", "run_seconds",
                    "error_type", "error"):
            if col not in (reader.fieldnames or []):
                sys.exit(f"Error: {path} has no '{col}' column -- not an eval CSV?")
        for r in reader:
            if r["error_type"] != "bsan":
                continue
            nread += 1
            key = (r["build"], r["crate"], r["test"])
            # ISO 8601 UTC timestamps compare correctly as strings
            if key not in latest or r["timestamp"] > latest[key]["timestamp"]:
                latest[key] = r
bugs = list(latest.values())
print(f"{nread} bsan row(s) in {len(args.eval_csvs)} file(s), "
      f"{nread - len(bugs)} duplicate(s) dropped", file=sys.stderr)

SCRIPTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_DATASETS = [
    ("mirilli", os.path.join(SCRIPTS, "mirilli-dataset.csv")),
    ("capslock", os.path.join(SCRIPTS, "capslock-dataset.csv")),
    ("treeborrows", os.path.join(SCRIPTS, "treeborrows-dataset.csv")),
    ("extern-c", os.path.join(SCRIPTS, "dataset_creator", "fetch_lists", "all_c_ffi_crates.csv")),
]
if args.dataset:
    datasets = []
    for d in args.dataset:
        if "=" not in d:
            ap.error(f"--dataset {d}: expected NAME=CSV")
        datasets.append(tuple(d.split("=", 1)))
else:
    datasets = DEFAULT_DATASETS

# dataset name -> {crate name -> (versions, latest_versions) listed for it}
members = {}
for ds, path in datasets:
    # utf-8-sig: files saved from Excel start with a BOM.
    with open(path, newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        name_col = next((c for c in reader.fieldnames or [] if "name" in c), None)
        if not name_col or "version" not in reader.fieldnames:
            sys.exit(f"Error: {path} needs a *name* and a version column")
        crates = members[ds] = {}
        for r in reader:
            vs, latest = crates.setdefault(r[name_col], (set(), set()))
            vs.add(r["version"])
            if r.get("latest_version"):
                latest.add(r["latest_version"])
known = set().union(*members.values())

# crates.io names are unique up to case and -/_, so match on that
canon = lambda n: n.lower().replace("_", "-")
# canonical crate name -> lookup()-style info (None: not on crates.io), from
# fetch_downloads.py
dumped = {}
downloads_path = args.downloads or os.path.join(SCRIPTS, "analysis", "crate-downloads.csv")
if os.path.exists(downloads_path):
    with open(downloads_path, newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        if "newest_version" not in (reader.fieldnames or []):
            print(f"{downloads_path} predates newest_version; rerun fetch_downloads.py. "
                  "Using crates.io instead", file=sys.stderr)
        else:
            for r in reader:
                dumped[canon(r["crate_name"])] = r["newest_version"] and {
                    "newest": r["newest_version"], "released": r["last_released"],
                    "downloads": r["downloads"]} or None
elif args.downloads:
    sys.exit(f"Error: {downloads_path} not found")
else:
    print(f"{downloads_path} not found; using crates.io instead", file=sys.stderr)


def split_crate(crate):
    """<name>-<version> -> (name, version), preferring a dataset name since
    crate names contain dashes too (aiken-lang-1.1.24). Longest name first,
    so libtz-sys-0.2.2 isn't read as libtz at version sys-0.2.2."""
    for i in reversed([m.start() for m in re.finditer(r"-(?=\d)", crate)]):
        if crate[:i] in known:
            return crate[:i], crate[i + 1:]
    m = re.match(r"^(.*?)-(\d+\.\d+\.\d+\S*)$", crate)
    return m.groups() if m else (crate, "")


def lookup(name):
    """{newest, released, downloads} from crates.io, or None if not found."""
    url = f"{API}/{urllib.parse.quote(name)}"
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT,
                                               "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            data = json.load(r)
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise
    c = data["crate"]
    versions = [v for v in data.get("versions", []) if not v.get("yanked")]
    released = max((v["created_at"] for v in versions), default="")
    return {"newest": c.get("max_stable_version") or c.get("max_version") or "",
            "released": released[:10], "downloads": rounded(c["downloads"])}


def rounded(n):
    """As fetch_downloads.py: 1234 -> 1k, 131_600 -> 132k, 999_700 -> 1M."""
    if n < 1000:
        return str(n)
    for unit, suffix, nxt in ((10**3, "k", 10**6), (10**6, "M", 10**9), (10**9, "B", None)):
        r = (n + unit // 2) // unit
        if nxt is None or r * unit < nxt:
            return f"{r}{suffix}"


names = []
for r in bugs:
    name = split_crate(r["crate"])[0]
    if name not in names:
        names.append(name)

# crates fetch_downloads.py didn't cover: crate name -> {fetched: date, info:
# lookup()}, reused for a day; saved after every lookup so an interrupted run
# keeps them
CACHE = os.path.join(SCRIPTS, "analysis", "crates-io-cache.json")
try:
    with open(CACHE) as f:
        cache = json.load(f)
except (OSError, ValueError):
    cache = {}
today = time.strftime("%Y-%m-%d")
undumped = [n for n in names if canon(n) not in dumped]
todo = [n for n in undumped if args.refresh or cache.get(n, {}).get("fetched") != today]
print(f"{len(names) - len(undumped)} crate(s) from {downloads_path}, "
      f"{len(undumped) - len(todo)} cached, {len(todo)} to look up on crates.io", file=sys.stderr)

for i, name in enumerate(todo, 1):
    print(f"[{i}/{len(todo)}] {name}", file=sys.stderr)
    try:
        ci = lookup(name)
    except Exception as e:
        print(f"  crates.io error: {e}", file=sys.stderr)
    else:
        if ci is None:
            print("  not found on crates.io", file=sys.stderr)
        cache[name] = {"fetched": today, "info": ci}
        with open(CACHE + ".tmp", "w") as f:
            json.dump(cache, f, indent=1, sort_keys=True)
        os.replace(CACHE + ".tmp", CACHE)
    if i < len(todo):
        time.sleep(1)
info = {n: dumped[canon(n)] if canon(n) in dumped else cache[n]["info"] if n in cache else None
        for n in names}


def error_type(error):
    """Classify the first "Undefined Behavior:" line of the report (run_eval
    writes line breaks as a literal \\n)."""
    for l in error.split("\\n"):
        if "Undefined Behavior:" not in l:
            continue
        l = l.rstrip()
        if " through " in l and l.endswith(" is forbidden"):
            return "aliasing violation"
        if "trying to access an allocation that has been freed" in l:
            return "use after free"
        if "an access of size" in l:
            return "access out of bounds"
        return "other"
    return "other"


def in_datasets(name, version, up_to_date):
    tags = []
    for ds, crates in members.items():
        vs, latest = crates.get(name, ((), ()))
        if version in vs:
            tags.append(ds)
        elif name in crates and (up_to_date or version in latest):
            tags.append(f"{ds}-updated")
    return ", ".join(tags)


def version_key(v):
    """Release order, roughly: 1.2.10 > 1.2.9 > 1.2.9-rc.1."""
    m = re.match(r"(\d+(?:\.\d+)*)(.*)", v)
    if not m:
        return ((), 0, v)
    return (tuple(int(x) for x in m.group(1).split(".")), not m.group(2), m.group(2))


def norm_path(path, crate):
    """Cut the eval job's absolute paths down to <crate>-<version>/..."""
    path = re.sub(r"^.*?/home/registry/src/[^/]+/", "", path)
    path = re.sub(r"^.*?/home/git/checkouts/", "", path)
    path = re.sub(r"^.*?/lib/rustlib/src/rust/library/", "<std>/", path)
    # build-script output: <pkg>/out/..., minus the per-build hash
    path = re.sub(r"^.*?/target/.*?/build/([^/]+)/[0-9a-f]+/out/", r"\1/out/", path)
    return re.sub(r"^/work/", crate + "/", path)


def locations(error, crate):
    """(bug location, tag created at) from the report; either may be ""."""
    lines = error.split("\\n")
    found, created = "", ""
    for i, l in enumerate(lines):
        if not found and "Undefined Behavior:" in l:
            found = next((m.group(1) for m in (re.search(r"-->\s*(\S+)", n)
                                               for n in lines[i + 1:i + 3]) if m), None) or ""
        elif re.search(r"help: the accessed tag \S+ was created here", l):
            created = next((m.group(1) for m in (re.search(r"-->\s*(\S+)", n)
                                                 for n in lines[i + 1:i + 3]) if m), None) or ""
            break
    return (norm_path(found, crate) if found else "",
            norm_path(created, crate) if created else "")


rows = []
for r in bugs:
    name, version = split_crate(r["crate"])
    ci = info.get(name)
    etype = error_type(r["error"])
    loc, created = locations(r["error"], r["crate"])
    key = (created if etype == "aliasing violation" and created
           and not created.startswith("<std>/") else loc)
    rows.append((r, name, version, ci, bool(ci) and version == ci["newest"],
                 etype, key, loc, created))

# bug key -> id, by first appearance
bug_id = {}
for *_, key, _, _ in rows:
    if key and key not in bug_id:
        bug_id[key] = f"B{len(bug_id) + 1}"

# (crate name, test) -> versions where that test is an aliasing violation
aliasing_at = {}
for r, name, version, _, _, etype, *_ in rows:
    if etype == "aliasing violation":
        aliasing_at.setdefault((name, r["test"]), []).append(version)


def diagnosis(r, name, version, up_to_date, etype):
    if etype != "aliasing violation":
        return ""
    if not up_to_date and any(version_key(v) > version_key(version)
                              for v in aliasing_at[(name, r["test"])]):
        return "Duplicate TP (see new)"
    return "True Positive"


yn = lambda b: "yes" if b else "no"
with open(out_path, "w", newline="", encoding="utf-8-sig") as f:
    w = csv.writer(f)
    w.writerow(HEADER)
    for r, name, version, ci, up_to_date, etype, key, loc, created in rows:
        w.writerow([
            bug_id.get(key, ""),
            diagnosis(r, name, version, up_to_date, etype),
            name, version,
            ci["released"] if ci else "",
            yn(up_to_date) if ci else "",
            in_datasets(name, version, up_to_date),
            ci["downloads"] if ci else "",
            r["build"], r["timestamp"], r["run_seconds"], r["test"], etype,
            loc, created, r["error"],
        ])

print(f"Wrote {len(bugs)} row(s) for {len(info)} crate(s) to {out_path}", file=sys.stderr)
