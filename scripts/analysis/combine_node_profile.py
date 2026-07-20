#!/usr/bin/env python3
"""Combine BSAN per-crate node logs into one CSV keyed by source line location.

Usage: combine_node_profile.py [-o OUT.csv] <dir_or_csv> [<dir_or_csv> ...]

Reads every <crate>.csv / <crate>.csv.gz written via BSAN_NODE_LOG (one file
per crate, as laid out by profile_bsan_dataset.sh) and combines rows that share
an origin line location, summing the alloc ids (roots) and nodes:

    origin_file,origin_line,alloc_ids,nodes,rows,origin_source,tests

Rows are grouped by (origin_file, origin_line) -- columns are folded together,
so two runs at the same file:line combine regardless of column. `alloc_ids` and
`nodes` are the sums of the `num_alloc_ids` and `num_nodes` columns across every
matching run; `rows` counts how many input runs (RLE'd rows) were folded in.
`tests` is a space-separated list of the distinct `test_file:test_line` frames
seen at that origin (in first-seen order; empty test locations are dropped).
Output is sorted by nodes descending.

Input rows are run-length encoded by the runtime with header:

    [test,]num_alloc_ids,num_nodes,alloc_ids,origin_file,origin_line,
    origin_col,origin_source,test_file,test_line,test_col,test_source

The leading `test` column added by profile_bsan_dataset.sh is optional; files
with or without it are both accepted.
"""
import argparse
import csv
import glob
import gzip
import os
import sys
from collections import defaultdict

ap = argparse.ArgumentParser()
ap.add_argument("-o", "--output", help="write combined CSV here (default: stdout)")
ap.add_argument("inputs", nargs="+",
                help="profile dirs (of <crate>.csv[.gz]) and/or individual csvs")
args = ap.parse_args()

# ── Collect input files ───────────────────────────────────────────────────────
paths = []
for inp in args.inputs:
    if os.path.isdir(inp):
        paths += sorted(glob.glob(os.path.join(inp, "*.csv")))
        paths += sorted(glob.glob(os.path.join(inp, "*.csv.gz")))
    else:
        paths.append(inp)

if not paths:
    sys.exit("no input .csv/.csv.gz files found")


def opener(path):
    return gzip.open(path, "rt", newline="") if path.endswith(".gz") \
        else open(path, "rt", newline="")


# ── Aggregate by (origin_file, origin_line) ───────────────────────────────────
# value: [alloc_ids sum, nodes sum, row count, first-seen origin_source,
#         dict of test_file:test_line -> None (ordered set of test locations)]
agg = defaultdict(lambda: [0, 0, 0, "", {}])
files_read = 0
rows_read = 0

for path in paths:
    try:
        f = opener(path)
    except OSError as e:
        print(f"skip {path}: {e}", file=sys.stderr)
        continue
    with f:
        reader = csv.reader(f)
        try:
            header = next(reader)
        except StopIteration:
            continue
        files_read += 1
        # Locate columns by name so the optional leading `test` column is handled.
        idx = {name: i for i, name in enumerate(header)}
        try:
            i_na = idx["num_alloc_ids"]
            i_nn = idx["num_nodes"]
            i_of = idx["origin_file"]
            i_ol = idx["origin_line"]
            i_os = idx["origin_source"]
            i_tf = idx["test_file"]
            i_tl = idx["test_line"]
        except KeyError:
            print(f"skip {path}: unexpected header {header}", file=sys.stderr)
            files_read -= 1
            continue
        for row in reader:
            if len(row) <= i_os:
                continue
            rows_read += 1
            key = (row[i_of], row[i_ol])
            try:
                na = int(row[i_na]) if row[i_na] else 0
                nn = int(row[i_nn]) if row[i_nn] else 0
            except ValueError:
                na = nn = 0
            entry = agg[key]
            entry[0] += na
            entry[1] += nn
            entry[2] += 1
            if not entry[3]:
                entry[3] = row[i_os]
            tf = row[i_tf] if len(row) > i_tf else ""
            tl = row[i_tl] if len(row) > i_tl else ""
            if tf:
                entry[4][f"{tf}:{tl}"] = None

# ── Emit ──────────────────────────────────────────────────────────────────────
out = open(args.output, "w", newline="") if args.output else sys.stdout
with out:
    w = csv.writer(out)
    w.writerow(["origin_file", "origin_line", "alloc_ids", "nodes", "rows",
                "origin_source", "tests"])
    for (of, ol), (na, nn, rc, src, tests) in sorted(
            agg.items(), key=lambda kv: kv[1][1], reverse=True):
        w.writerow([of, ol, na, nn, rc, src, " ".join(tests)])

print(f"read {rows_read} rows from {files_read} files -> {len(agg)} line locations",
      file=sys.stderr)
