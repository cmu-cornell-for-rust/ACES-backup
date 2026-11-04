#!/usr/bin/env python3
"""How much of each program's borrow forest is single-node trees, and how big
its trees are.

Usage: single_node_trees.py [-o OUT.csv] <dir of output_tree_size_dist_*.csv>

The directory is searched recursively, so both outputs/bsan-dists/bsan (flat)
and outputs/miri-tracing (one subdir per crate) work.

Each input CSV has one row per tree_size with a count of trees of that size.
Per program (one CSV) this computes:

    pct_trees  = 100 * count[size 1] / sum(count)
    pct_nodes  = 100 * count[size 1] / sum(tree_size * count)
    avg_size   = sum(tree_size * count) / sum(count)
    singletons = count[size 1]

and prints the mean, geometric mean, (sample) std dev, median, and
interquartile range (25th-75th percentile) of each across programs. It also prints the mean and std dev of tree size pooled over every
tree in every program. Programs with no trees at all are skipped. Geomean ignores programs
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

rows = []   # (program, pct_trees, pct_nodes, avg_size, singletons)
all_trees = all_nodes = all_sq = 0   # pooled over every tree
for path in files:
    trees = nodes = single = 0
    with open(path, newline="") as f:
        for r in csv.DictReader(f):
            size, count = int(r["tree_size"]), int(r["count"])
            trees += count
            nodes += size * count
            all_sq += size * size * count
            if size == 1:
                single += count
    if trees == 0:
        print(f"skipping {path.name}: no trees", file=sys.stderr)
        continue
    all_trees += trees
    all_nodes += nodes
    rows.append((path.stem.removeprefix(PREFIX),
                 100 * single / trees, 100 * single / nodes, nodes / trees, single))


def summarize(name, vals, unit="%"):
    pos = [v for v in vals if v > 0]
    gm = statistics.geometric_mean(pos) if pos else math.nan
    sd = statistics.stdev(vals) if len(vals) > 1 else math.nan
    dropped = f"  ({len(vals) - len(pos)} zero(s) excluded from geomean)" \
        if len(pos) < len(vals) else ""
    q1, med, q3 = statistics.quantiles(vals, n=4) if len(vals) > 1 \
        else (math.nan,) * 3
    print(f"{name:<10} mean {statistics.mean(vals):6.2f}{unit}  "
          f"geomean {gm:6.2f}{unit}  stddev {sd:6.2f}{unit}  "
          f"median {med:6.2f}{unit}  IQR {q1:.2f}-{q3:.2f}{unit}{dropped}")


print(f"{len(rows)} programs")
summarize("% trees", [r[1] for r in rows])
summarize("% nodes", [r[2] for r in rows])
summarize("avg size", [r[3] for r in rows], unit="")
summarize("singletons", [r[4] for r in rows], unit="")

pooled_mean = all_nodes / all_trees
pooled_var = (all_sq - all_trees * pooled_mean ** 2) / (all_trees - 1) \
    if all_trees > 1 else math.nan
print(f"all trees  mean {pooled_mean:6.2f}   stddev {math.sqrt(pooled_var):6.2f}"
      f"   ({all_trees} trees)")

if args.output:
    with open(args.output, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["program", "pct_trees_single", "pct_nodes_single",
                    "avg_tree_size", "singletons"])
        for p, t, n, a, c in rows:
            w.writerow([p, f"{t:.4f}", f"{n:.4f}", f"{a:.4f}", c])
