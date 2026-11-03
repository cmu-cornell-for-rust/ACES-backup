#!/usr/bin/env python3
"""How much of each program's borrow forest is single-node trees.

Usage: single_node_trees.py [-o OUT.csv] <dir of output_tree_size_dist_*.csv>

The directory is searched recursively, so both outputs/bsan-dists/bsan (flat)
and outputs/miri-tracing (one subdir per crate) work.

Each input CSV has one row per tree_size with a count of trees of that size.
Per program (one CSV) this computes:

    pct_trees  = 100 * count[size 1] / sum(count)
    pct_nodes  = 100 * count[size 1] / sum(tree_size * count)

and prints the mean, geometric mean, and (sample) std dev of each across
programs. Programs with no trees at all are skipped. Geomean ignores programs
whose value is 0 and says how many it dropped.

With -o, the per-program values are also written as a CSV.
"""
import argparse
import csv
import math
import statistics
import sys
from pathlib import Path

PREFIX = "output_tree_size_dist_"

ap = argparse.ArgumentParser()
ap.add_argument("-o", "--output", help="write per-program percentages here")
ap.add_argument("dir", help="e.g. outputs/bsan-dists/bsan")
args = ap.parse_args()

files = sorted(Path(args.dir).rglob(f"{PREFIX}*.csv"))   # flat or per-crate dirs
if not files:
    sys.exit(f"Error: no {PREFIX}*.csv files in {args.dir}")

rows = []   # (program, pct_trees, pct_nodes)
for path in files:
    trees = nodes = single = 0
    with open(path, newline="") as f:
        for r in csv.DictReader(f):
            size, count = int(r["tree_size"]), int(r["count"])
            trees += count
            nodes += size * count
            if size == 1:
                single += count
    if trees == 0:
        print(f"skipping {path.name}: no trees", file=sys.stderr)
        continue
    rows.append((path.stem.removeprefix(PREFIX),
                 100 * single / trees, 100 * single / nodes))


def summarize(name, vals):
    pos = [v for v in vals if v > 0]
    gm = statistics.geometric_mean(pos) if pos else math.nan
    sd = statistics.stdev(vals) if len(vals) > 1 else math.nan
    dropped = f"  ({len(vals) - len(pos)} zero(s) excluded from geomean)" \
        if len(pos) < len(vals) else ""
    print(f"{name:<10} mean {statistics.mean(vals):6.2f}%  "
          f"geomean {gm:6.2f}%  stddev {sd:6.2f}%{dropped}")


print(f"{len(rows)} programs")
summarize("% trees", [r[1] for r in rows])
summarize("% nodes", [r[2] for r in rows])

if args.output:
    with open(args.output, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["program", "pct_trees_single", "pct_nodes_single"])
        for p, t, n in rows:
            w.writerow([p, f"{t:.4f}", f"{n:.4f}"])
