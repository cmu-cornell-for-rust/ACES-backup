#!/usr/bin/env python3
"""Per-test CSV of a Miri Tree Borrows run (log-output-tree-borrows-*).

Usage: treeborrows_report.py [-o OUT.csv] [--ub-only] [-j N] <log-output-dir>

    treeborrows_report.py ../../log-output-tree-borrows-15416a0f...

The log directory holds one <name>@<version>/ per crate, each with a
global_log.txt and, if its tests built, {treeborrows,stackedborrows,
noborrows}/junit.xml from cargo-nextest under Miri. Writes one row per
treeborrows test case (or one row per crate, with an empty test, for a crate
with no treeborrows junit.xml, e.g. it didn't build), columns:

  bug id            rows with UB sharing a bug key share an id, as in
                    bug_report.py: error type plus "tag created at" (aliasing
                    violations, when outside <std>) else "bug location", minus
                    the crate version and line:col. Numbered by first
                    appearance, crates sorted by name
  crate, version    from the <name>@<version> directory
  binary            the nextest test binary (junit testsuite name)
  test              the test name
  tree borrows      pass, UB, fail (a non-UB failure: panic, ...), timeout,
                    skipped, or no junit (no treeborrows/junit.xml)
  runtime (s)       nextest's time for the test
  error type        for UB, from the first "Undefined Behavior:" line, using
                    bug_report.py's categories (Aliasing - Protection /
                    Invalid / Insufficient / other, Use-After-Free, Access
                    Out-of-Bound, Null Pointer Dereference) plus Miri-only ones:
                    Uninitialized Memory, Invalid Value, Misaligned Access,
                    Incorrect Dealloc Layout, Data Race, Unavailable Target
                    Feature, other

The bug location and "tag created at" are read from each UB report to group
bug ids, but aren't written out.

--ub-only keeps only rows whose tree borrows result is UB. Written with a UTF-8
BOM so Excel opens it cleanly. Requirements: python3 >= 3.6 (stdlib).
"""
import argparse
import csv
import os
import re
import sys
import xml.etree.ElementTree as ET
from multiprocessing import Pool

HEADER = ["bug id", "crate", "version", "binary", "test", "tree borrows", "runtime (s)",
          "error type"]
MSG_MAX = 500


def panic_message(text):
    """The message under "thread '...' panicked at file:line:col:", or ""."""
    lines = text.split("\n")
    for i, l in enumerate(lines):
        if " panicked at " in l:
            rest = l.split(" panicked at ", 1)[1]
            # older toolchains put the message on the same line: 'msg', file
            if not rest.rstrip().endswith(":") and "'" in rest:
                return rest.strip()
            return lines[i + 1].strip() if i + 1 < len(lines) else ""
    return ""


def norm_path(path, crate):
    """Cut Miri's absolute paths down to <crate>-<version>/... or <std>/..."""
    path = re.sub(r"^.*?/registry/src/[^/]+/", "", path)
    path = re.sub(r"^.*?/git/checkouts/", "", path)
    path = re.sub(r"^.*?/lib/rustlib/src/rust/library/", "<std>/", path)
    path = re.sub(r"^.*?/target/.*?/build/([^/]+)/[0-9a-f]+/out/", r"\1/out/", path)
    # the crate's own files: relative to its root, or under /build
    path = re.sub(r"^/build/", "", path)
    if not path.startswith("/") and not path.startswith("<std>/") \
            and not re.match(r"[^/]+-\d+\.\d+\.\d+[^/]*/", path):
        path = f"{crate}/{path}"
    return path


def aliasing_type(lines):
    """As in bug_report.py: the Tree Borrows help lines after the UB line."""
    for l in lines:
        if "Undefined Behavior:" in l:
            break
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


def error_type(lines, i):
    """Classify the UB report whose "Undefined Behavior:" line is lines[i]."""
    l = lines[i].rstrip()
    m = l.split("Undefined Behavior:", 1)[1].lower()
    if " through " in l and l.endswith(" is forbidden"):
        return aliasing_type(lines[i + 1:])
    if "data race" in m:
        return "Data Race"
    if "has been freed" in m or "use-after-free" in m:
        return "Use-After-Free"
    if "null pointer" in m:
        return "Null Pointer Dereference"
    if "incorrect layout on deallocation" in m:
        return "Incorrect Dealloc Layout"
    if "out-of-bounds" in m or re.search(r"expected a pointer to .* but got .* which is only", m):
        return "Access Out-of-Bound"
    if "uninitialized" in m:
        return "Uninitialized Memory"
    if "alignment" in m and "required" in m or "unaligned" in m:
        return "Misaligned Access"
    if "unavailable target features" in m:
        return "Unavailable Target Feature"
    if "constructing invalid value" in m:
        return "Invalid Value"
    return "other"


def arrow_after(lines, i):
    for n in lines[i + 1:i + 3]:
        m = re.search(r"-->\s*(\S+)", n)
        if m:
            return m.group(1)
    return ""


def analyze(text, crate):
    """(error type, wildcard, bug location, tag created at, UB message) for
    a failure's output, or None if it has no UB report."""
    lines = text.split("\n")
    ub = next((i for i, l in enumerate(lines) if "Undefined Behavior:" in l), None)
    if ub is None:
        return None
    etype = error_type(lines, ub)
    loc = arrow_after(lines, ub)
    created = ""
    for j in range(ub + 1, len(lines)):
        if "Undefined Behavior:" in lines[j]:
            break
        if re.search(r"help: the accessed tag \S+ was created here", lines[j]):
            created = arrow_after(lines, j)
            break
    end = next((j for j in range(ub, len(lines)) if lines[j].startswith("error: aborting")),
               len(lines) - 1)
    excerpt = "\n".join(lines[ub:end + 1])
    msg = lines[ub].split("Undefined Behavior:", 1)[1].strip()
    return (etype, "yes" if "<wildcard>" in excerpt else "no",
            norm_path(loc, crate) if loc else "",
            norm_path(created, crate) if created else "", msg)


def read_junit(path):
    """[(binary, test, status, time, output)] from a nextest junit.xml."""
    try:
        root = ET.parse(path).getroot()
    except (OSError, ET.ParseError) as e:
        return None if isinstance(e, OSError) else [("", "", "bad junit", "", str(e))]
    out = []
    for suite in root.iter("testsuite"):
        for tc in suite.iter("testcase"):
            status, text = "pass", ""
            fail = tc.find("failure")
            if fail is None:
                fail = tc.find("error")
            if fail is not None:
                status = "timeout" if "timeout" in (fail.get("type") or "") else "fail"
                parts = [fail.get("message") or "", fail.text or ""]
                for tag in ("system-err", "system-out"):
                    e = tc.find(tag)
                    if e is not None and e.text:
                        parts.append(e.text)
                text = "\n".join(p for p in parts if p.strip())
                if "Undefined Behavior:" in text:
                    status = "UB"
            elif tc.find("skipped") is not None:
                status = "skipped"
            out.append((suite.get("name") or "", tc.get("name") or "", status,
                        tc.get("time") or "", text))
    return out


def process(args):
    logdir, entry = args
    name, _, version = entry.rpartition("@")
    crate = f"{name}-{version}"
    d = os.path.join(logdir, entry)
    tb = read_junit(os.path.join(d, "treeborrows", "junit.xml"))
    others = {}
    for kind in ("stackedborrows", "noborrows"):
        r = read_junit(os.path.join(d, kind, "junit.xml"))
        others[kind] = {(b, t): s for b, t, s, _, _ in r} if r is not None else None
    if tb is None:
        return [[name, version, "", "", "no junit", "", "", "", "", "", "", "", ""]]
    rows = []
    for binary, test, status, time, text in tb:
        res = analyze(text, crate) if status == "UB" else None
        etype, wild, loc, created, err = res or ("", "", "", "", panic_message(text))
        sb, nb = ((o.get((binary, test), "") if o is not None else "")
                  for o in (others["stackedborrows"], others["noborrows"]))
        rows.append([name, version, binary, test, status, time, etype, wild, loc, created,
                     sb, nb, err[:MSG_MAX]])
    return rows


def bug_key(etype, loc, created, name):
    if not etype:
        return ""
    path = created if etype.startswith("Aliasing") and "/" in created \
        and not created.startswith("<std>/") else loc
    if "/" not in path:
        return (etype, "crate " + name)
    path = re.sub(r":\d+:\d+$", "", path)
    top, _, rest = path.partition("/")
    return (etype, re.sub(r"-\d+\.\d+\.\d+\S*$", "", top) + "/" + rest)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("logdir", help="log-output-tree-borrows-* directory")
    ap.add_argument("-o", "--output", help="output CSV (default: <logdir>-report.csv)")
    ap.add_argument("--ub-only", action="store_true", help="only tests with Tree Borrows UB")
    ap.add_argument("-j", "--jobs", type=int, default=os.cpu_count())
    args = ap.parse_args()
    logdir = args.logdir.rstrip("/")
    out_path = args.output or logdir + "-report.csv"

    entries = sorted(e for e in os.listdir(logdir)
                     if "@" in e and os.path.isdir(os.path.join(logdir, e)))
    print(f"{len(entries)} crate(s) in {logdir}", file=sys.stderr)

    bug_id = {}
    counts = {}
    nrows = 0
    with Pool(args.jobs) as pool, open(out_path, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.writer(f)
        w.writerow(HEADER)
        for i, rows in enumerate(pool.imap(process, ((logdir, e) for e in entries), chunksize=16), 1):
            for r in rows:
                status, etype = r[4], r[6]
                counts[status] = counts.get(status, 0) + 1
                if args.ub_only and status != "UB":
                    continue
                key = bug_key(etype, r[8], r[9], r[0])
                if key and key not in bug_id:
                    bug_id[key] = len(bug_id) + 1
                w.writerow([bug_id.get(key, "")] + r[:7])
                nrows += 1
            if i % 1000 == 0:
                print(f"  {i}/{len(entries)}", file=sys.stderr)

    print("tree borrows results: " + ", ".join(f"{k} {v}" for k, v in
                                                sorted(counts.items(), key=lambda kv: -kv[1])),
          file=sys.stderr)
    print(f"Wrote {nrows} row(s), {len(bug_id)} bug id(s) to {out_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
