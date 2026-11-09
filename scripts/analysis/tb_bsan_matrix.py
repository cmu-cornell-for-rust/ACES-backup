#!/usr/bin/env python3
"""BorrowSanitizer vs. Miri Tree Borrows outcomes for every test where either
reports an aliasing violation, as a LaTeX table.

Usage: tb_bsan_matrix.py [--bsan CSV ...] [--build CSV] [--crates] [-j N] <log-output-dir>

    tb_bsan_matrix.py ../../log-output-tree-borrows-15416a0f...

Compares, test by test, at the crate version the Miri Tree Borrows run tested
(the <name>@<version>/ directories in <log-output-dir>; these are the versions
in treeborrows-dataset.csv, i.e. bug_report.py's "treeborrows", not
"treeborrows-updated"):

  Miri (columns)    from each crate's treeborrows/junit.xml
  BSan (rows)       from run_eval_dataset.sh eval CSVs (--bsan, default the
                    experimental-bsan-treeborrows-{eval-part1,2,3,missing-eval,
                    notfinal-eval}.csv in <repo>/outputs). A test in several
                    (reruns of timeouts and OOMs) takes its latest success or
                    test failure, else its latest row; a crate-level row (no
                    test, e.g. build_failed) counts for all its tests. A
                    crate with no eval rows that --build (default
                    outputs/experimental-bsan-treeborrows-build.csv) says
                    failed to fetch or build is Not built

and counts tests where at least one tool reports an aliasing violation, by:

  Pass              the test passed
  AV-Inv./Ins./P    the aliasing type, classified as in treeborrows_report.py
  Other UB          any other Undefined Behavior (UaF, OoB, ...)
  Unsup.-FFI        Miri only: unsupported operation: can't call foreign function
  Unsup.-other      Miri only: any other unsupported operation (int-to-ptr
                    casts under strict provenance, extern statics, ...)
  Fail              any other failure (panic, crash, ...)
  Timeout/OOM       timed out, or BSan was killed for running out of memory
  Not built         the crate didn't build (Miri: no junit.xml)
  Not run           the test isn't in the other tool's results: not
                    evaluated at this version, skipped, or a name mismatch

Cells where neither tool reports an aliasing violation aren't counted and are
written as --. --crates adds the number of distinct crates to each cell, as
"tests (crates)"; a crate can appear in several cells, so the totals aren't
the sum of their cells.

Requirements: python3 >= 3.6 (stdlib).
"""
import argparse
import collections
import csv
import os
import re
import sys
from multiprocessing import Pool

import treeborrows_report as tr

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BSAN_CSVS = [f"experimental-bsan-treeborrows-{s}.csv" for s in
             ("eval-part1", "eval-part2", "eval-part3", "missing-eval", "notfinal-eval")]
AV = {"Aliasing - Invalid": "AV-Inv.", "Aliasing - Insufficient": "AV-Ins.",
      "Aliasing - Protection": "AV-P"}
AVS = list(AV.values())
BSAN = ["Pass"] + AVS + ["Other UB", "Fail", "Timeout/OOM", "Not built", "Not run"]
MIRI = ["Pass"] + AVS + ["Other UB", "Unsup.-FFI", "Unsup.-other", "Fail", "Timeout/OOM",
                         "Not built", "Not run"]


def ub_type(lines):
    """AV-* or Other UB for the first "Undefined Behavior:" report in lines."""
    i = next(k for k, l in enumerate(lines) if "Undefined Behavior:" in l)
    return AV.get(tr.error_type(lines, i), "Other UB")


def miri_result(status, text):
    """Column for one treeborrows junit test case."""
    if status == "pass":
        return "Pass"
    if status == "UB":
        return ub_type(text.split("\n"))
    if status == "timeout":
        return "Timeout/OOM"
    if status == "fail":
        if "can't call foreign function" in text:
            return "Unsup.-FFI"
        return "Unsup.-other" if "unsupported operation:" in text else "Fail"
    return "Not run"


def miri_crate(args):
    """(crate, {test: column} or None if it has no junit.xml)."""
    logdir, entry = args
    name = entry.rpartition("@")[0]
    junit = tr.read_junit(os.path.join(logdir, entry, "treeborrows", "junit.xml"))
    if junit is None:
        return name, None
    out = collections.defaultdict(set)
    for _, test, status, _, text in junit:
        out[test].add(miri_result(status, text))
    # a test run under several binaries with differing results
    return name, {t: rs.pop() if len(rs) == 1 else "Not run" for t, rs in out.items()}


def bsan_result(row):
    """Row for one eval CSV row."""
    status, etype = row["status"], row["error_type"]
    if status == "success":
        return "Pass"
    if status == "test_failed":
        if etype == "bsan" and "Undefined Behavior:" in row["error"]:
            # run_eval writes line breaks as a literal \n (\\n when re-escaped)
            return ub_type(re.split(r"\\+n", row["error"]))
        return "Fail"
    if status in ("timeout", "killed"):
        return "Timeout/OOM"
    if status in ("build_failed", "fetch_failed"):
        return "Not built"
    return "Not run"


def read_bsan(paths, versions):
    """{(crate, test): row} at the given versions, test "" for crate rows."""
    best = {}
    for path in paths:
        with open(path, encoding="utf-8-sig", newline="") as f:
            for r in csv.DictReader(f):
                m = re.match(r"(.+)-(\d+\.\d+\.\d+.*)$", r["crate"])
                if not m or versions.get(m.group(1)) != m.group(2):
                    continue
                key = (m.group(1), r["test"])
                done = r["status"] in ("success", "test_failed")
                old = best.get(key)
                if old is None or (done, r["timestamp"]) >= (old[0], old[1]):
                    best[key] = (done, r["timestamp"], bsan_result(r))
    return {k: v[2] for k, v in best.items()}


def read_builds(path, versions, bsan):
    """Add a crate-level Not built to bsan for each crate the build CSV says
    failed to fetch or build and the evals have no rows for."""
    have = {c for c, _ in bsan}
    with open(path, encoding="utf-8-sig", newline="") as f:
        for r in csv.DictReader(f):
            m = re.match(r"(.+)-(\d+\.\d+\.\d+.*)$", r["crate"])
            if (m and versions.get(m.group(1)) == m.group(2) and m.group(1) not in have
                    and r["status"] in ("build_failed", "fetch_failed")):
                bsan[m.group(1), ""] = "Not built"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bsan", action="append", metavar="CSV",
                    help="BSan eval CSV (repeatable; default the five treeborrows evals)")
    ap.add_argument("--build", metavar="CSV", default=os.path.join(
                        ROOT, "outputs", "experimental-bsan-treeborrows-build.csv"),
                    help="BSan build CSV, for crates that never reached the evals")
    ap.add_argument("--crates", action="store_true",
                    help='write each cell as "tests (crates)"')
    ap.add_argument("-j", "--jobs", type=int, default=os.cpu_count())
    ap.add_argument("logdir", help="log-output-tree-borrows-* directory")
    args = ap.parse_args()
    paths = args.bsan or [os.path.join(ROOT, "outputs", f) for f in BSAN_CSVS]

    csv.field_size_limit(sys.maxsize)
    entries = sorted(n for n in os.listdir(args.logdir) if "@" in n)
    versions = dict(n.rsplit("@", 1) for n in entries)
    with Pool(args.jobs) as pool:
        miri = dict(pool.imap_unordered(miri_crate, [(args.logdir, e) for e in entries],
                                        chunksize=64))
    bsan = read_bsan(paths, versions)
    read_builds(args.build, versions, bsan)
    print(f"{len(miri)} Miri crates, {len(bsan)} BSan rows at those versions", file=sys.stderr)

    tests = {(c, t) for c, t in bsan if t}
    tests |= {(c, t) for c, ts in miri.items() if ts for t, m in ts.items() if m in AVS}
    counts, crates = collections.Counter(), collections.defaultdict(set)
    for c, t in tests:
        m = "Not built" if miri[c] is None else miri[c].get(t, "Not run")
        b = bsan.get((c, t)) or bsan.get((c, ""), "Not run")
        if m not in AVS and b not in AVS:
            continue
        for key in ((b, m), (b, None), (None, m), (None, None)):
            counts[key] += 1
            crates[key].add(c)

    def cell(b, m):
        if b is not None and m is not None and b not in AVS and m not in AVS:
            return "--"
        return f"{counts[b, m]} ({len(crates[b, m])})" if args.crates else str(counts[b, m])

    print(r"\begin{tabular}{@{}l " + "r" * len(MIRI) + r" @{\hspace{12pt}}r@{}}")
    print(r"    \toprule")
    print(r"    & \multicolumn{%d}{c}{Miri (TB)} & \\" % len(MIRI))
    print(r"    \cmidrule(lr){2-%d}" % (len(MIRI) + 1))
    print("    BSan & " + " & ".join(MIRI) + r" & $\Sigma$ \\")
    print(r"    \midrule")
    for b in BSAN:
        print(f"    {b:11} & " + " & ".join(cell(b, m) for m in MIRI)
              + f" & {cell(b, None)} \\\\")
    print(r"    \midrule")
    print("    " + r"$\Sigma$".ljust(11) + " & " + " & ".join(cell(None, m) for m in MIRI)
          + f" & {cell(None, None)} \\\\")
    print(r"    \bottomrule")
    print(r"  \end{tabular}")


if __name__ == "__main__":
    main()
