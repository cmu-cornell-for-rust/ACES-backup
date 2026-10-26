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

  bug id            1, 2, ...: rows with the same bug key share an id. The key
                    is the error type plus a location: "tag created at" for
                    aliasing violations that have one
                    outside <std>, else "bug location" (a std helper like
                    slice::as_mut_ptr creates tags for unrelated bugs), with
                    the crate version and line:col dropped, so the same file
                    in any version of a crate is one bug
                    (git2-0.20.4/src/call.rs:78:13 = git2-0.7.5/src/call.rs:72:39).
                    A report with no file in either (a bare address, or an
                    unsymbolized cargo.<hash>-cgu.08:0:0) is keyed on the
                    function in its first stack backtrace frame instead, or
                    if that's a bare address too (no symbolizer), on the
                    crate name alone
                    Numbered by first appearance, in input order, so appending
                    an eval CSV (earlier ones unchanged, same order) keeps the
                    old ids and numbers new bugs after them
  found by          the earlier bug lists that have this crate and test, e.g.
                    "mirilli, capslock": mirilli_bugs.csv (crate, version,
                    test; an empty test matches every test of the crate),
                    capslock_bugs.csv (crate as <name>-<version>, tests split
                    on ;) and treeborrows_bugs.csv (crate, version, test), in
                    scripts/
  diagnosis         C2 holds an ARRAYFORMULA that looks each bug id up on the
                    Bugs sheet (A -> C); the rest of the column is left
                    blank so it can spill
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
  # downloads       all-time crates.io downloads of the crate
  container         the eval build (the image the test ran in)
  test timestamp    when the test finished
  runtime (s)       the test's run_seconds
  test              as in the bugs CSV
  error type        from the first UB report line in the error and, for an
                    aliasing violation ("Undefined Behavior: {read access,
                    write access,reborrow,deallocation} through {tag} at
                    {alloc}[{offset}] is forbidden"), the Tree Borrows help
                    lines under it:
                      Aliasing - Protection    a protector was violated: "...
                                               the protected tag ... to become
                                               Disabled" or "the strongly
                                               protected tag ... disallows
                                               deallocations"
                      Aliasing - Invalid       the tag (accessed or conflicting)
                                               "has state Disabled which
                                               forbids ...": a foreign access
                                               revoked it; also a <wildcard>
                                               access with "no exposed tags
                                               which may perform this access"
                      Aliasing - Insufficient  the tag "has state {Frozen,
                                               Reserved (conflicted), ...}
                                               which forbids ...": still valid,
                                               but too weak for the access
                                               (e.g. a write through a Frozen
                                               shared reference)
                      Use-After-Free           "... trying to access an
                                               allocation that has been freed"
                      Access Out-of-Bound      "... an access of size ..."
                      Null Pointer Dereference "null pointer" (bsan has no such
                                               report yet; kept for when it does)
                      other                    none of the above
  wildcard          yes if the error mentions a <wildcard> tag (an access
                    through, or a tag built from, a pointer cast from an
                    integer), else no
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
HEADER = ["bug id", "found by", "diagnosis", "crate", "version", "last updated", "up to date?", "datasets",
          "# downloads", "container", "test timestamp", "runtime (s)", "test",
          "error type", "wildcard", "bug location", "tag created at", "error"]

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

# (<name>-<version>, test) -> the bug lists that have it; test "" is any test
found = {}
with open(os.path.join(SCRIPTS, "mirilli_bugs.csv"), newline="", encoding="utf-8-sig") as f:
    for r in csv.DictReader(f):
        found.setdefault((f"{r['crate']}-{r['version']}", r["test"]), set()).add("mirilli")
with open(os.path.join(SCRIPTS, "capslock_bugs.csv"), newline="", encoding="utf-8-sig") as f:
    for r in csv.DictReader(f):
        for t in r["tests"].split(";"):
            found.setdefault((r["crate"], t), set()).add("capslock")
with open(os.path.join(SCRIPTS, "treeborrows_bugs.csv"), newline="", encoding="utf-8-sig") as f:
    for r in csv.DictReader(f):
        found.setdefault((f"{r['crate']}-{r['version']}", r["test"]), set()).add("treeborrows")


def found_by(crate, test):
    hits = found.get((crate, test), set()) | found.get((crate, ""), set())
    return ", ".join(s for s in ("mirilli", "capslock", "treeborrows") if s in hits)


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
            "released": released[:10], "downloads": c["downloads"]}


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


def report_lines(error):
    """run_eval writes line breaks as a literal \\n, and a report quoted inside
    a panic message (e.g. a CLI test's captured stderr) is escaped again as
    \\\\n, so split on any run of backslashes before the n."""
    return re.split(r"\\+n", error)


def aliasing_type(lines):
    """Tree Borrows violation kind from the help lines after the UB line --
    bsan-rt's TransitionError: ProtectedDisabled / ProtectedDealloc,
    ChildAccessForbidden(perm), or a wildcard access no exposed tag may do."""
    for l in lines:
        if "Undefined Behavior:" in l:
            break  # the next report: these lines aren't about this one
        if (re.search(r"the protected tag \S+ \(currently .+\) to become Disabled", l)
                or "protected tags must never be Disabled" in l
                or re.search(r"the strongly protected tag \S+ disallows deallocations", l)):
            return "Aliasing - Protection"
        m = re.search(r"the (?:accessed|conflicting) tag .+? has state (.+?) which forbids", l)
        if m:
            return "Aliasing - Invalid" if m.group(1) == "Disabled" else "Aliasing - Insufficient"
        if "there are no exposed tags which may perform this access here" in l:
            return "Aliasing - Invalid"
    return "Aliasing - other"


def error_type(error):
    """Classify the first "Undefined Behavior:" report."""
    lines = report_lines(error)
    for i, l in enumerate(lines):
        if "Undefined Behavior:" not in l:
            continue
        l = l.rstrip()
        if " through " in l and l.endswith(" is forbidden"):
            return aliasing_type(lines[i + 1:])
        if "trying to access an allocation that has been freed" in l:
            return "Use-After-Free"
        if "an access of size" in l:
            return "Access Out-of-Bound"
        if "null pointer" in l.lower():
            return "Null Pointer Dereference"
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
    lines = report_lines(error)
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


def has_file(path):
    """Whether a location names a source file, not a bare address (0x5626...,
    different every run) or an unsymbolized codegen unit (cargo.<hash>-cgu.08:0:0)."""
    return bool(path) and "/" in path and not re.fullmatch(r"0x[0-9a-f]+", path)


def top_frame(error):
    """The function in the report's first stack backtrace frame, or ""."""
    lines = report_lines(error)
    for i, l in enumerate(lines):
        if l.strip() == "stack backtrace:":
            m = next((re.match(r"\s*0: (.+)", n) for n in lines[i + 1:i + 2]), None)
            return m.group(1).strip() if m else ""
    return ""


def bug_key(path):
    """<crate>-<version>/file:line:col -> <crate>/file"""
    path = re.sub(r":\d+:\d+$", "", path)
    top, _, rest = path.partition("/")
    return re.sub(r"-\d+\.\d+\.\d+\S*$", "", top) + "/" + rest


rows = []
for r in bugs:
    name, version = split_crate(r["crate"])
    ci = info.get(name)
    etype = error_type(r["error"])
    loc, created = locations(r["error"], r["crate"])
    if etype.startswith("Aliasing") and has_file(created) and not created.startswith("<std>/"):
        key = bug_key(created)
    elif has_file(loc):
        key = bug_key(loc)
    elif not re.fullmatch(r"0x[0-9a-f]+|", top_frame(r["error"])):
        # no file to go by: the function the report stopped in
        key = "fn " + top_frame(r["error"])
    else:
        # unsymbolized: the addresses are randomized every run, so all that's
        # left is the crate
        key = "crate " + name
    # two kinds of bug in one file (blst's pippenger.rs) are two bugs
    key = (etype, key) if key else ""
    rows.append((r, name, version, ci, bool(ci) and version == ci["newest"],
                 etype, key, loc, created))

# bug key -> id, by first appearance
bug_id = {}
for *_, key, _, _ in rows:
    if key and key not in bug_id:
        bug_id[key] = len(bug_id) + 1

# C2 looks up each row's bug id on the Bugs sheet and spills down the column,
# so every other diagnosis cell stays empty
DIAGNOSIS_FORMULA = '=ARRAYFORMULA(IF(A2:A="", , XLOOKUP(A2:A, Bugs!A2:A, Bugs!C2:C, "")))'

yn = lambda b: "yes" if b else "no"
with open(out_path, "w", newline="", encoding="utf-8-sig") as f:
    w = csv.writer(f)
    w.writerow(HEADER)
    for i, (r, name, version, ci, up_to_date, etype, key, loc, created) in enumerate(rows):
        w.writerow([
            bug_id.get(key, ""),
            found_by(r["crate"], r["test"]),
            DIAGNOSIS_FORMULA if i == 0 else "",
            name, version,
            ci["released"] if ci else "",
            yn(up_to_date) if ci else "",
            in_datasets(name, version, up_to_date),
            ci["downloads"] if ci else "",
            r["build"], r["timestamp"], r["run_seconds"], r["test"], etype,
            yn("<wildcard>" in r["error"]), loc, created, r["error"],
        ])

print(f"Wrote {len(bugs)} row(s) for {len(info)} crate(s) to {out_path}", file=sys.stderr)
