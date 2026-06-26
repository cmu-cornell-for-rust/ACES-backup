#!/usr/bin/env python3
"""
Usage: plot_tree_size_dist.py [tracing_dir] [output_dir]

Aggregate plots over EVERY crate's per-tree-size distribution
(output_tree_size_dist_<crate>.csv), summed across all crates and grouped by
tree size. Two figures are written:

  1. tree size  vs  percent pruned   -- 100 * sum(gc_pruned) / sum(size*count)
                                         i.e. what fraction of a tree's nodes
                                         the GC eventually reclaims as garbage.
  2. tree size  vs  average visits    -- sum(visited) / sum(count)
                                         i.e. node-visits per tree of that size.

Each point is one distinct tree size aggregated over all crates. The x axis is
log-scaled (sizes span 1 .. ~3e7); plot 2's y axis is log-scaled too. Points are
colored by how many trees that size aggregates (log10), so the dense, low-noise
sizes are visually separable from the lone giant trees out on the right tail.

  tracing_dir  dir whose subdirs are per-crate tracing outputs, each holding an
               output_tree_size_dist_<crate>.csv. Default: <OUTPUTS_DIR>/tracing.
  output_dir   where the PNGs are written. Default: <OUTPUTS_DIR>/analysis.

The outputs dir defaults to <repo root>/outputs, found relative to this script
(so it works both locally and on the cluster); override with $OUTPUTS_DIR.
"""

import argparse
import csv
import glob
import os
import sys
from collections import defaultdict

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUTPUTS_DIR = os.environ.get("OUTPUTS_DIR", os.path.join(REPO_ROOT, "outputs"))


def aggregate(tracing_dir):
    """Sum count/visited/gc_pruned per tree size across every crate's dist CSV.
    Returns (per_size dict, crate_count)."""
    per_size = defaultdict(
        lambda: {"count": 0, "visited": 0, "gc_pruned": 0, "reads": 0, "writes": 0})
    files = sorted(glob.glob(os.path.join(tracing_dir, "*", "output_tree_size_dist_*.csv")))
    if not files:
        sys.exit(f"Error: no output_tree_size_dist_*.csv under {tracing_dir}")
    for path in files:
        with open(path, newline="") as f:
            for row in csv.DictReader(f):
                s = int(row["tree_size"])
                a = per_size[s]
                a["count"] += int(row["count"])
                a["visited"] += int(row["visited"])
                a["gc_pruned"] += int(row["gc_pruned"])
                a["reads"] += int(row["reads"])
                a["writes"] += int(row["writes"])
    return per_size, len(files)


def main():
    parser = argparse.ArgumentParser(
        usage=argparse.SUPPRESS, description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("tracing_dir", nargs="?",
                        default=os.path.join(OUTPUTS_DIR, "tracing"))
    parser.add_argument("output_dir", nargs="?",
                        default=os.path.join(OUTPUTS_DIR, "analysis"))
    parser.add_argument("--style", choices=("scatter", "density", "population"),
                        default="scatter",
                        help="scatter = one dot per tree size colored by tree count "
                             "(default); density = same dots colored by how many dots "
                             "share their neighborhood; population = same dots colored by "
                             "how many trees (Σ count) share their neighborhood, so heavily "
                             "populated sizes light up the heatmap.")
    args = parser.parse_args()

    if not os.path.isdir(args.tracing_dir):
        sys.exit(f"Error: tracing dir not found: {args.tracing_dir}")

    # Headless-safe backend; import after so --help works without matplotlib.
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        from matplotlib.colors import LogNorm
        import numpy as np
    except ImportError:
        sys.exit("Error: matplotlib is required (pip install matplotlib).")

    per_size, n_crates = aggregate(args.tracing_dir)

    sizes = sorted(per_size)
    counts = [per_size[s]["count"] for s in sizes]
    # Percent of node-mass reclaimed: total pruned / total nodes (= size * count).
    pct_pruned = [100.0 * per_size[s]["gc_pruned"] / (s * per_size[s]["count"]) for s in sizes]
    # Average node-visits per tree of this size.
    avg_visits = [per_size[s]["visited"] / per_size[s]["count"] for s in sizes]
    # Average non-pruned (kept/live) nodes per tree = size - avg pruned. This is
    # the live core that survives GC; the gap up to y=x is the garbage.
    avg_non_pruned = [s - per_size[s]["gc_pruned"] / per_size[s]["count"] for s in sizes]
    # Memory accesses (reads + writes) per node = accesses-per-tree / tree size.
    accesses_per_node = [(per_size[s]["reads"] + per_size[s]["writes"]) / (per_size[s]["count"] * s)
                         for s in sizes]
    os.makedirs(args.output_dir, exist_ok=True)

    def scatter(y, ylabel, title, fname, ylog=False, ylim=None, identity=False):
        # On a log y axis drop non-positive points (e.g. trees pruned to 0 survivors).
        pts = [(s, yi, w) for s, yi, w in zip(sizes, y, counts) if not ylog or yi > 0]
        xs, ys, ws = (np.asarray(v, float) for v in zip(*pts))
        if args.style in ("density", "population"):
            # Color each dot by what falls in its 2D-histogram cell, so overlap reads
            # as a heatmap while every individual size stays a dot. "density" counts
            # dots (each size = 1); "population" sums tree counts (each size weighted
            # by how many trees share it), so crowded sizes dominate the heatmap.
            lx = np.log10(xs)
            ly = np.log10(ys) if ylog else ys
            nb = 80
            weights = ws if args.style == "population" else None
            hist, xe, ye = np.histogram2d(lx, ly, bins=nb, weights=weights)
            ix = np.clip(np.digitize(lx, xe) - 1, 0, nb - 1)
            iy = np.clip(np.digitize(ly, ye) - 1, 0, nb - 1)
            cvals = hist[ix, iy]
            order = np.argsort(cvals)  # draw densest dots last, on top
            xs, ys, cvals = xs[order], ys[order], cvals[order]
            norm = LogNorm(vmin=1)
            cbar_label = ("trees in neighborhood  (Σ count, log scale)"
                          if args.style == "population" else "dots in neighborhood  (log scale)")
            marker, alpha = 10, 0.85
        else:
            cvals = np.log10(ws)
            norm, cbar_label = None, "trees at this size  (log₁₀ count)"
            marker, alpha = 14, 0.7
        fig, ax = plt.subplots(figsize=(9, 5.5))
        sc = ax.scatter(xs, ys, c=cvals, cmap="viridis", s=marker, norm=norm,
                        alpha=alpha, edgecolors="none")
        ax.set_xscale("log")
        if ylog:
            ax.set_yscale("log")
        if identity:
            ax.plot([xs.min(), xs.max()], [xs.min(), xs.max()], ls="--", color="0.4",
                    lw=1, label="no pruning (kept = size)")
            ax.legend(loc="upper left", framealpha=0.9)
        if ylim:
            ax.set_ylim(*ylim)
        ax.set_xlabel("tree size (nodes, log scale)")
        ax.set_ylabel(ylabel)
        ax.set_title(title)
        ax.grid(True, which="both", ls=":", alpha=0.4)
        fig.colorbar(sc, ax=ax).set_label(cbar_label)
        fig.tight_layout()
        out = os.path.join(args.output_dir, fname)
        fig.savefig(out, dpi=150)
        plt.close(fig)
        return out

    out1 = scatter(
        pct_pruned, "percent of node-mass pruned (%)",
        f"Tree size vs. percent pruned  (aggregate, {n_crates} crates)",
        "tree_size_vs_percent_pruned.png", ylim=(-2, 102),
    )
    out2 = scatter(
        avg_visits, "average node-visits per tree",
        f"Tree size vs. average visits  (aggregate, {n_crates} crates)",
        "tree_size_vs_avg_visits.png", ylog=True,
    )
    out3 = scatter(
        avg_non_pruned, "average non-pruned (kept) nodes per tree",
        f"Tree size vs. average non-pruned nodes  (aggregate, {n_crates} crates)",
        "tree_size_vs_avg_nonpruned.png", ylog=True, identity=True,
    )
    out4 = scatter(
        accesses_per_node, "reads + writes per node  (accesses ÷ tree size)",
        f"Tree size vs. accesses per node  (aggregate, {n_crates} crates)",
        "tree_size_vs_accesses_per_node.png", ylog=True,
    )

    total_trees = sum(counts)
    print(f"Aggregated {n_crates} crates, {len(sizes)} distinct tree sizes, "
          f"{total_trees:,} trees (sizes 1..{sizes[-1]:,}).")
    print(f"Wrote {out1}")
    print(f"Wrote {out2}")
    print(f"Wrote {out3}")
    print(f"Wrote {out4}")


if __name__ == "__main__":
    main()
