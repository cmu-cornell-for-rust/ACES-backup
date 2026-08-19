#!/usr/bin/env python3
"""Compile per-crate BSAN node logs into one source-line profile.

Usage: node_profile.py [-o OUT.csv] [--by origin|test] <profile_dir_or_csv> [...]

Reads every <crate>.log / <crate>.log.gz written via BSAN_NODE_LOG (as laid
out by profile_bsan_dataset.sh, one file per crate) and aggregates, per
source line, how many distinct trees (alloc ids) minted a node there and how
many nodes (borrow tags) were made in total:

    crate,file,line,source,trees,nodes,rows

sorted by nodes descending. Input rows are run-length encoded by the runtime:

    [test,]num_alloc_ids,num_nodes,alloc_ids,origin_file,origin_line,
    origin_col,origin_source,test_file,test_line,test_col,test_source

where alloc_ids is a space-separated list of the run's distinct allocations.
The leading test column is added by profile_bsan_dataset.sh (older files
without it are also accepted). --by picks which of the row's two locations
to group on: origin (default; where the borrow was created) or test (the
test frame that led there).

Tree counting: alloc ids are only unique within one process, so ids are
namespaced by (crate, test) before counting. Two caveats inherit from the
runtime: within one test invocation several test binaries share (and, since
the log is opened with O_TRUNC, clobber) the log file, so only the last
binary's rows survive; and the same tree touching a line in several RLE runs
is correctly counted once, but the same id reused by different tests of one
binary counts once too. Counts are therefore best read as lower bounds.

Unresolved frames appear with the raw PC as the file and line 0; rows whose
grouping location is entirely empty are folded into a single "(unknown)" row
per crate. The summary on stderr lists the files read and total rows.
"""
import argparse
import csv
import glob
import gzip
import os
import sys
from collections import defaultdict

RUNTIME_HEADER = (
    "num_alloc_ids,num_nodes,alloc_ids,"
    "origin_file,origin_line,origin_col,origin_source,"
    "test_file,test_line,test_col,test_source"
).split(",")

ap = argparse.ArgumentParser()
ap.add_argument("-o", "--output", help="write the profile CSV here (default: stdout)")
ap.add_argument("--by", choices=("origin", "test"), default="origin",
                help="group by the node's origin (default) or test location")
ap.add_argument("inputs", nargs="+",
                help="profile dirs (of <crate>.log[.gz]) and/or individual logs")
args = ap.parse_args()

# ── Collect input files ───────────────────────────────────────────────────────
paths = []
for inp in args.inputs:
    if os.path.isdir(inp):
        # .csv[.gz] is the legacy spelling of these node logs; profile dirs
        # generated before the rename still work.
        paths += sorted(glob.glob(os.path.join(inp, "*.log"))
                        + glob.glob(os.path.join(inp, "*.log.gz"))
                        + glob.glob(os.path.join(inp, "*.csv"))
                        + glob.glob(os.path.join(inp, "*.csv.gz")))
    elif os.path.isfile(inp):
        paths.append(inp)
    else:
        sys.exit(f"Error: no such file or directory: {inp}")
if not paths:
    sys.exit("Error: no .log/.log.gz files found in the given inputs")

F, L, S = (("origin_file", "origin_line", "origin_source")
           if args.by == "origin" else
           ("test_file", "test_line", "test_source"))

# (crate, file, line) -> aggregates
trees = defaultdict(set)    # distinct (test, alloc_id)
nodes = defaultdict(int)    # sum of num_nodes
rows_ = defaultdict(int)    # RLE rows folded in
source = {}                 # first non-empty source text seen
total_rows = 0
skipped = 0

for path in paths:
    name = os.path.basename(path)
    crate = name.removesuffix(".gz").removesuffix(".log").removesuffix(".csv")
    opener = gzip.open if path.endswith(".gz") else open
    with opener(path, "rt", newline="") as f:
        reader = csv.reader(f)
        header = next(reader, None)
        if header is None:
            continue
        # With or without the leading test column added by the orchestrator.
        fields = ["test"] + RUNTIME_HEADER if header[:1] == ["test"] else RUNTIME_HEADER
        idx = {name: i for i, name in enumerate(fields)}
        for r in reader:
            # Stray runtime headers (concatenated logs) and short rows.
            if len(r) < len(fields) or r[idx["num_alloc_ids"]] == "num_alloc_ids":
                skipped += 1
                continue
            try:
                n_nodes = int(r[idx["num_nodes"]])
            except ValueError:
                skipped += 1
                continue
            total_rows += 1
            test = r[idx["test"]] if "test" in idx else ""
            file, line = r[idx[F]], r[idx[L]]
            if not file and (not line or line == "0"):
                file, line = "(unknown)", ""
            key = (crate, file, line)
            nodes[key] += n_nodes
            rows_[key] += 1
            for aid in r[idx["alloc_ids"]].split():
                trees[key].add((test, aid))
            if key not in source and r[idx[S]]:
                source[key] = r[idx[S]]

# ── Emit, hottest lines first ─────────────────────────────────────────────────
out = open(args.output, "w", newline="") if args.output else sys.stdout
w = csv.writer(out)
w.writerow(["crate", "file", "line", "source", "trees", "nodes", "rows"])
for key in sorted(nodes, key=lambda k: (-nodes[k], k)):
    crate, file, line = key
    w.writerow([crate, file, line, source.get(key, ""),
                len(trees[key]), nodes[key], rows_[key]])
if args.output:
    out.close()

crates = {k[0] for k in nodes}
sys.stderr.write(
    f"{len(paths)} file(s) read, {total_rows} node rows"
    f"{f' ({skipped} skipped)' if skipped else ''}; "
    f"{len(nodes)} {args.by} lines across {len(crates)} crates, "
    f"{sum(nodes.values())} nodes, "
    f"{sum(len(s) for s in trees.values())} line-tree pairs\n")
