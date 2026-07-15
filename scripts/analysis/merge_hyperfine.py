#!/usr/bin/env python3
"""Merge two or more *-hyperfine.csv files on (crate, test).

Usage: merge_hyperfine.py [-o OUT.csv] <a-hyperfine.csv> <b-hyperfine.csv> [...]

Produces one wide CSV with a row per (crate, test) -- the union across all
inputs -- and, per input file, its status/mean_s/min_s/max_s for that test:

    crate,test,<label>_status,<label>_mean_s,<label>_min_s,<label>_max_s,...

<label> is the file's `build` column when unique across the inputs (e.g.
miri, bsan, rust), otherwise the file's basename. Cells are empty where a
file has no row for that test; timing cells are empty where status is not
success. Crate-level failure rows (empty test: fetch_failed/build_failed)
are not merged. If a file contains the same (crate, test) twice (a rerun
appended to the same CSV), the LAST row wins, since appends are newest-last.

The merged CSV goes to stdout (or -o FILE). A per-crate table of total
measured time -- the sum of mean_s over success rows, per input -- is
printed to stderr, sorted by the largest total, so
    merge_hyperfine.py a.csv b.csv > merged.csv
leaves the totals on the terminal.
"""
import argparse
import csv
import os
import sys
from collections import defaultdict

ap = argparse.ArgumentParser()
ap.add_argument("-o", "--output", help="write the merged CSV here (default: stdout)")
ap.add_argument("csvs", nargs="+", help="two or more *-hyperfine.csv files")
args = ap.parse_args()
if len(args.csvs) < 2:
    ap.error("need at least two CSVs to merge")

FIELDS = ("status", "mean_s", "min_s", "max_s")

tables = []   # one dict per input: (crate, test) -> row
builds = []
for path in args.csvs:
    rows = {}
    build = None
    with open(path, newline="") as f:
        for r in csv.DictReader(f):
            if not r["test"]:
                continue
            rows[(r["crate"], r["test"])] = r
            build = r["build"] or build
    if not rows:
        sys.exit(f"Error: no per-test rows in {path}")
    tables.append(rows)
    builds.append(build)

# Column labels: build names when they don't collide, else file basenames.
if len(set(builds)) == len(builds):
    labels = builds
else:
    labels = []
    for path in args.csvs:
        stem = os.path.basename(path).removesuffix(".csv").removesuffix("-hyperfine")
        while stem in labels:
            stem += "'"
        labels.append(stem)

# ── Merged CSV ────────────────────────────────────────────────────────────────
keys = sorted(set().union(*tables))
out = open(args.output, "w", newline="") if args.output else sys.stdout
w = csv.writer(out)
w.writerow(["crate", "test"] + [f"{lab}_{f}" for lab in labels for f in FIELDS])
for key in keys:
    row = list(key)
    for table in tables:
        r = table.get(key)
        row += [r[f] for f in FIELDS] if r else [""] * len(FIELDS)
    w.writerow(row)
if args.output:
    out.close()

# ── Per-crate total measured time, per input ─────────────────────────────────
totals = [defaultdict(float) for _ in tables]   # crate -> sum of success means
counts = [defaultdict(int) for _ in tables]
for table, tot, cnt in zip(tables, totals, counts):
    for (crate, _), r in table.items():
        if r["status"] == "success" and r["mean_s"]:
            tot[crate] += float(r["mean_s"])
            cnt[crate] += 1

err = sys.stderr
for path, lab, table, cnt in zip(args.csvs, labels, tables, counts):
    err.write(f"{lab}: {path} ({len(table)} test rows, "
              f"{sum(cnt.values())} success across {len(cnt)} crates)\n")
err.write(f"merged: {len(keys)} (crate, test) pairs\n\n")

crates = sorted(set().union(*totals), key=lambda c: -max(t[c] for t in totals))
cw = max((len(c) for c in crates), default=5) + 2
err.write("total measured seconds per crate (sum of success mean_s):\n")
err.write("crate".ljust(cw) + "".join(f"{lab:>14}" for lab in labels) + "\n")
for crate in crates:
    cells = "".join(f"{t[crate]:14.1f}" if crate in t else f"{'-':>14}" for t in totals)
    err.write(crate.ljust(cw) + cells + "\n")
err.write("TOTAL".ljust(cw)
          + "".join(f"{sum(t.values()):14.1f}" for t in totals) + "\n")
