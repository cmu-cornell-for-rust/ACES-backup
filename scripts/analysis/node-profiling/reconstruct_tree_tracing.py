#!/usr/bin/env python3
"""
Usage: reconstruct_tree_tracing.py [tracing_dir] [output.csv]

Rebuilds the combined tree_tracing summary CSV from the per-crate tree-size
distribution files (output_tree_size_dist_<crate>.csv) that the analysis binary
wrote into each crate's tracing dir. Use this when the per-crate stdout logs --
the only place the binary emitted its CSVROW: summary line -- were lost, but the
durable dist CSVs survived.

  tracing_dir   directory whose subdirectories are per-crate tracing outputs,
                each containing an output_tree_size_dist_<crate>.csv.
                Default: <OUTPUTS_DIR>/tracing.
  output.csv    output name (basename, .csv forced) written into
                <OUTPUTS_DIR>/analysis/. Default: tree_tracing-reconstructed-
                <basename tracing_dir>.csv.

Tree size 1 (single-node trees) is EXCLUDED: every total and average is over
trees of size >= 2 only. So `trees` here is the count of multi-node trees and
the averages are per multi-node tree, NOT comparable to a full run's averages.

Recovered columns (summed across size buckets, then averaged over `trees`):
  crate, trees, nodes, avg_nodes,
  reads, avg_reads, writes, avg_writes,
  visited, avg_visited, skipped, avg_skipped,
  gc_pruned, avg_gc_pruned

NOT recoverable from the dist CSVs (absent here vs. a real run): the per-tree
max columns, gc_invoked, and memory_kinds -- the dist output never carried them.

The outputs dir defaults to <repo root>/outputs, found relative to this script
(so it works both locally and on the cluster); override with $OUTPUTS_DIR.
"""

import argparse
import csv
import glob
import os
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUTPUTS_DIR = os.environ.get("OUTPUTS_DIR", os.path.join(REPO_ROOT, "outputs"))

# Per-tree event columns to sum out of the dist CSV. `count` (trees of that
# size) and `tree_size` (nodes per tree) are handled separately below.
EVENTS = ("reads", "writes", "visited", "skipped", "gc_pruned")


def reconstruct_crate(dist_path):
    """Fold one crate's dist CSV into summary totals over trees of size >= 2.
    Returns None if the crate has no multi-node trees (nothing to report)."""
    trees = 0
    nodes = 0
    totals = {e: 0 for e in EVENTS}
    with open(dist_path, newline="") as f:
        for row in csv.DictReader(f):
            size = int(row["tree_size"])
            if size == 1:
                continue
            count = int(row["count"])
            trees += count
            nodes += size * count
            for e in EVENTS:
                totals[e] += int(row[e])
    if trees == 0:
        return None

    def avg(n):
        return n / trees

    out = {"crate": None, "trees": trees, "nodes": nodes, "avg_nodes": round(avg(nodes), 2)}
    for e in EVENTS:
        out[e] = totals[e]
        out[f"avg_{e}"] = round(avg(totals[e]), 2)
    return out


def main():
    parser = argparse.ArgumentParser(
        usage=argparse.SUPPRESS, description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("tracing_dir", nargs="?",
                        default=os.path.join(OUTPUTS_DIR, "tracing"))
    parser.add_argument("output", nargs="?")
    args = parser.parse_args()

    tracing_dir = args.tracing_dir
    if not os.path.isdir(tracing_dir):
        sys.exit(f"Error: tracing dir not found: {tracing_dir}")

    out_name = args.output or f"tree_tracing-reconstructed-{os.path.basename(os.path.normpath(tracing_dir))}.csv"
    out_name = os.path.splitext(os.path.basename(out_name))[0] + ".csv"
    out_dir = os.path.join(OUTPUTS_DIR, "analysis")
    os.makedirs(out_dir, exist_ok=True)
    out_path = os.path.join(out_dir, out_name)

    columns = ["crate", "trees", "nodes", "avg_nodes"]
    for e in EVENTS:
        columns += [e, f"avg_{e}"]

    rows = []
    no_dist = 0
    empty = 0
    for crate_dir in sorted(glob.glob(os.path.join(tracing_dir, "*"))):
        if not os.path.isdir(crate_dir):
            continue
        crate = os.path.basename(crate_dir)
        matches = glob.glob(os.path.join(crate_dir, "output_tree_size_dist_*.csv"))
        if not matches:
            no_dist += 1
            continue
        row = reconstruct_crate(matches[0])
        if row is None:
            empty += 1
            continue
        row["crate"] = crate
        rows.append(row)

    with open(out_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=columns)
        writer.writeheader()
        writer.writerows(rows)

    print(f"Reconstructed {len(rows)} crates -> {out_path}")
    if empty:
        print(f"  skipped {empty} crate(s) with no trees of size >= 2")
    if no_dist:
        print(f"  skipped {no_dist} dir(s) with no dist CSV")


if __name__ == "__main__":
    main()
