#!/usr/bin/env python3
"""
Usage: plot_tree_size_dist.py [dist_dir] [output_dir]

Aggregate plots over EVERY crate's per-tree-size distribution
(output_tree_size_dist_<crate>.csv), summed across all crates and grouped by
tree size. Two figures are written:

  1. tree size  vs  percent pruned   -- 100 * sum(gc_pruned) / sum(size*count)
                                         i.e. what fraction of a tree's nodes
                                         the GC eventually reclaims as garbage.
  2. tree size  vs  average visits    -- sum(visited) / sum(count)
                                         i.e. node-visits per tree of that size.

Each point is one distinct tree size aggregated over all crates. The x axis is
log-scaled (sizes span 1 .. ~3e7); plot 2's y axis is log-scaled too. By default
(--style population) points are colored by how many trees (Σ count) share their
log-log neighborhood, so the plot reads as a heatmap of where the tree mass
actually lives and the lone giant trees on the right tail stay dim. Use
--style scatter to color each dot by its own tree count instead, or --style crate
to break the aggregate apart into one color-coded series per crate. --powerfit
overlays a sqrt(count)-weighted least-squares fit y = a*x^b on the log-y figures.

  dist_dir     dir holding the output_tree_size_dist_<crate>.csv files, in
               EITHER layout: one per-crate subdir each containing its CSV (how
               <OUTPUTS_DIR>/tracing is laid out), or all the CSVs sitting flat
               in the dir (how <OUTPUTS_DIR>/bsan_dists is). Both are globbed,
               so a mixed dir works too. Default: <OUTPUTS_DIR>/tracing.
  output_dir   where the PNGs are written. Default: <OUTPUTS_DIR>/analysis.

Because Miri and BSan dists produce the same four filenames, the PNGs are
suffixed with a tag defaulting to dist_dir's basename -- so bsan_dists yields
tree_size_vs_percent_pruned-bsan_dists.png and cannot clobber the Miri figures.
The historical "tracing" dir is the one exception and stays untagged; override
either way with --tag NAME / --tag "".

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


def _empty_size():
    return {"count": 0, "visited": 0, "gc_pruned": 0, "reads": 0, "writes": 0}


def _crate_name(path):
    """output_tree_size_dist_<crate>.csv -> <crate>."""
    base = os.path.basename(path)
    return base[len("output_tree_size_dist_"):-len(".csv")]


def aggregate(dist_dir):
    """Sum count/visited/gc_pruned per tree size, both overall and per crate.
    Returns (per_size dict, per_crate {crate: per_size dict}, crate_count)."""
    per_size = defaultdict(_empty_size)
    per_crate = {}
    # Per-crate subdirs (outputs/tracing) and flat CSVs (outputs/bsan_dists) are
    # both accepted; dedup in case a dir happens to hold both.
    files = sorted(set(
        glob.glob(os.path.join(dist_dir, "output_tree_size_dist_*.csv"))
        + glob.glob(os.path.join(dist_dir, "*", "output_tree_size_dist_*.csv"))))
    if not files:
        sys.exit(f"Error: no output_tree_size_dist_*.csv in {dist_dir} "
                 f"or its immediate subdirs")
    for path in files:
        crate = per_crate.setdefault(_crate_name(path), defaultdict(_empty_size))
        with open(path, newline="") as f:
            for row in csv.DictReader(f):
                s = int(row["tree_size"])
                for a in (per_size[s], crate[s]):
                    a["count"] += int(row["count"])
                    a["visited"] += int(row["visited"])
                    a["gc_pruned"] += int(row["gc_pruned"])
                    a["reads"] += int(row["reads"])
                    a["writes"] += int(row["writes"])
    return per_size, per_crate, len(files)


def main():
    parser = argparse.ArgumentParser(
        usage=argparse.SUPPRESS, description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("dist_dir", nargs="?",
                        default=os.path.join(OUTPUTS_DIR, "tracing"))
    parser.add_argument("output_dir", nargs="?",
                        default=os.path.join(OUTPUTS_DIR, "analysis"))
    parser.add_argument("--tag", default=None,
                        help="suffix for the PNG filenames and titles. Defaults to "
                             "dist_dir's basename (empty for the legacy 'tracing' "
                             "dir); pass --tag '' to force untagged names.")
    parser.add_argument("--style", choices=("scatter", "density", "population", "crate"),
                        default="population",
                        help="population = each dot colored by how many trees (Σ count) "
                             "share its neighborhood, so heavily populated sizes light up "
                             "the heatmap (default); density = same dots colored by how many "
                             "dots share their neighborhood; scatter = one dot per tree size "
                             "colored by its own tree count; crate = one dot per (crate, tree "
                             "size) colored by crate, so a single crate's curve is traceable "
                             "instead of being merged into the aggregate.")
    parser.add_argument("--top-crates", type=int, default=12, metavar="N",
                        help="--style crate only: how many crates (ranked by how many dots "
                             "they draw) get a distinct color and a legend entry. The rest "
                             "are drawn as light-gray context. Default 12; past 20 the "
                             "colors stop being easy to tell apart. 0 = no legend, color "
                             "every crate off a full-spectrum map instead.")
    parser.add_argument("--powerfit", action="store_true",
                        help="overlay a least-squares power-law fit y = a*x^b (fitted as a "
                             "line in log-log space, weighted by sqrt(tree count)) on the "
                             "log-y figures. Ignored by --style crate, which has no single "
                             "aggregate curve to fit.")
    args = parser.parse_args()

    if not os.path.isdir(args.dist_dir):
        sys.exit(f"Error: dist dir not found: {args.dist_dir}")

    # Tag the outputs by source dir so Miri and BSan figures coexist; "tracing"
    # keeps the original untagged filenames.
    tag = args.tag
    if tag is None:
        base = os.path.basename(os.path.normpath(args.dist_dir))
        tag = "" if base == "tracing" else base
    suffix = f"-{tag}" if tag else ""
    label = f", {tag}" if tag else ""

    # Headless-safe backend; import after so --help works without matplotlib.
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        from matplotlib.colors import LogNorm, to_hex
        import numpy as np
    except ImportError:
        sys.exit("Error: matplotlib is required (pip install matplotlib).")

    per_size, per_crate, n_crates = aggregate(args.dist_dir)

    # y-metrics, each computed from one size's aggregate dict `a` at tree size `s`,
    # so they apply identically to the overall aggregate and to a single crate.
    # Percent of node-mass reclaimed: total pruned / total nodes (= size * count).
    m_pct_pruned = lambda a, s: 100.0 * a["gc_pruned"] / (s * a["count"])
    # Average node-visits per tree of this size.
    m_avg_visits = lambda a, s: a["visited"] / a["count"]
    # Average non-pruned (kept/live) nodes per tree = size - avg pruned. This is
    # the live core that survives GC; the gap up to y=x is the garbage.
    m_avg_non_pruned = lambda a, s: s - a["gc_pruned"] / a["count"]
    # Memory accesses (reads + writes) per node = accesses-per-tree / tree size.
    m_accesses_per_node = lambda a, s: (a["reads"] + a["writes"]) / (a["count"] * s)

    sizes = sorted(per_size)
    counts = [per_size[s]["count"] for s in sizes]
    os.makedirs(args.output_dir, exist_ok=True)

    # Crates ranked by how many dots they draw (= distinct tree sizes), so the
    # legend names the crates you can actually see. The top N get well-separated
    # tab20 colors and legend entries; everything else is drawn as light-gray
    # context under them, since 100+ hues off one colormap are indistinguishable
    # by eye and a 100-entry legend is unreadable anyway.
    crate_names = sorted(per_crate)
    ranked = sorted(crate_names, key=lambda c: (-len(per_crate[c]), c))
    n_top = len(ranked) if args.top_crates == 0 else min(args.top_crates, len(ranked))
    top_crates = ranked[:n_top]
    OTHER = "0.82"
    if args.top_crates == 0:
        # Legend suppressed: colour every crate off a full-spectrum map (the
        # original look, kept for when you just want to see the spread).
        crate_color = {c: plt.cm.gist_ncar(i / max(1, len(crate_names) - 1))
                       for i, c in enumerate(crate_names)}
    else:
        # tab20 is qualitative but pairs each hue as dark/light neighbors, so take
        # all 10 saturated slots before any pale one -- otherwise ranks 1 and 2 come
        # out as near-twins. Past 20 crates fall back to sampling gist_ncar, which
        # gives unique but no longer easily separable colors.
        tab20_order = [i for i in range(0, 20, 2)] + [i for i in range(1, 20, 2)]
        pal = ([plt.cm.tab20(tab20_order[i] / 20) for i in range(n_top)] if n_top <= 20
               else [plt.cm.gist_ncar(i / max(1, n_top - 1)) for i in range(n_top)])
        crate_color = {c: pal[i] for i, c in enumerate(top_crates)}
        crate_color.update({c: OTHER for c in ranked[n_top:]})

    def _finish_scatter(fig, ax, xs, ylog, ylim, identity, ylabel, title):
        """Shared axis styling for every scatter style."""
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

    def _power_fit(xs, ys, ws):
        """Least-squares power-law fit y = a * x^b, done as a straight-line fit
        in log-log space (log10 y = b*log10 x + log10 a). Points are weighted by
        sqrt(count) so the dense, low-noise sizes anchor the line and the lone
        giant trees on the tail don't dominate. Returns (a, b)."""
        lx, ly = np.log10(xs), np.log10(ys)
        b, log_a = np.polyfit(lx, ly, 1, w=np.sqrt(ws))
        return 10.0 ** log_a, b

    def scatter(metric, ylabel, title, fname, ylog=False, ylim=None, identity=False):
        y = [metric(per_size[s], s) for s in sizes]
        if args.style == "crate":
            # One series per crate, so an individual crate's curve stays traceable.
            # Each crate is plotted from its own per-size aggregate, not the global one.
            # Wider figure when a legend goes outside the axes on the right.
            legend = args.top_crates != 0
            fig, ax = plt.subplots(figsize=(12, 5.5) if legend else (9, 5.5))
            # Gray context first, top crates last so they sit on top of it.
            others = [c for c in ranked[n_top:]] if legend else []
            for c in others + top_crates:
                pts = [(s, metric(per_crate[c][s], s)) for s in sorted(per_crate[c])]
                pts = [(s, yi) for s, yi in pts if not ylog or yi > 0]
                if not pts:
                    continue
                cx, cy = (np.asarray(v, float) for v in zip(*pts))
                is_top = legend and c in crate_color and c in top_crates
                ax.scatter(cx, cy, s=12 if is_top else 6,
                           alpha=0.55 if is_top else 0.35, edgecolors="none",
                           color=crate_color[c],
                           label=f"{c}  ({len(per_crate[c]):,})" if is_top else None,
                           zorder=3 if is_top else 2)
            xs = np.asarray(sizes, float)  # for the identity line's x-range
            _finish_scatter(fig, ax, xs, ylog, ylim, identity, ylabel, title)
            if legend:
                # Proxy entry for the gray mass, then legend outside the axes so it
                # never covers data. Supersedes any legend _finish_scatter made.
                if others:
                    ax.scatter([], [], s=12, color=OTHER,
                               label=f"other ({len(others)} crates)")
                ax.legend(loc="upper left", bbox_to_anchor=(1.01, 1.0), fontsize=7,
                          framealpha=0.9, markerscale=1.6, borderaxespad=0,
                          title=f"crate  (dots)", title_fontsize=8)
            fig.tight_layout()
            out = os.path.join(args.output_dir, fname)
            fig.savefig(out, dpi=150)
            plt.close(fig)
            return out
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
            # Reorder ws too, so it stays aligned with xs/ys for the power fit.
            xs, ys, ws, cvals = xs[order], ys[order], ws[order], cvals[order]
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
        # The fit is a straight line in log-log space, so it only means anything on
        # a log y axis (the percent-pruned figure is linear-y and skips it).
        if args.powerfit and ylog:
            a, b = _power_fit(xs, ys, ws)
            fx = np.array([xs.min(), xs.max()])
            ax.plot(fx, a * fx ** b, color="crimson", lw=1.6,
                    label=f"power fit  y = {a:.3g}·x^{b:.3g}")
            ax.legend(loc="upper left", framealpha=0.9)
        _finish_scatter(fig, ax, xs, ylog, ylim, identity, ylabel, title)
        fig.colorbar(sc, ax=ax).set_label(cbar_label)
        fig.tight_layout()
        out = os.path.join(args.output_dir, fname)
        fig.savefig(out, dpi=150)
        plt.close(fig)
        return out

    out1 = scatter(
        m_pct_pruned, "percent of node-mass pruned (%)",
        f"Tree size vs. percent pruned  (Miri, {n_crates} crate testbenches{label})",
        f"tree_size_vs_percent_pruned{suffix}.png", ylim=(-2, 102),
    )
    out2 = scatter(
        m_avg_visits, "average node-visits per tree",
        f"Tree size vs. average visits  (aggregate, {n_crates} crate testbenches{label})",
        f"tree_size_vs_avg_visits{suffix}.png", ylog=True,
    )
    out3 = scatter(
        m_avg_non_pruned, "average non-pruned (kept) nodes per tree",
        f"Tree size vs. average non-pruned nodes  (aggregate, {n_crates} crate testbenches{label})",
        f"tree_size_vs_avg_nonpruned{suffix}.png", ylog=True, identity=True,
    )
    out4 = scatter(
        m_accesses_per_node, "reads + writes per node  (accesses ÷ tree size)",
        f"Tree size vs. accesses per node  (aggregate, {n_crates} crate testbenches{label})",
        f"tree_size_vs_accesses_per_node{suffix}.png", ylog=True,
    )

    total_trees = sum(counts)
    print(f"Aggregated {n_crates} crates, {len(sizes)} distinct tree sizes, "
          f"{total_trees:,} trees (sizes 1..{sizes[-1]:,}).")
    print(f"Wrote {out1}")
    print(f"Wrote {out2}")
    print(f"Wrote {out3}")
    print(f"Wrote {out4}")

    # The figures legend only the top --top-crates series, so also emit the full
    # ranking as a CSV: dots = distinct tree sizes that crate contributes, i.e.
    # how many points it draws (log-y figures drop the few non-positive ones).
    # in_legend marks the crates that got their own color; the rest share gray.
    if args.style == "crate":
        keypath = os.path.join(args.output_dir, f"crate_colors{suffix}.csv")
        with open(keypath, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["rank", "crate", "dots", "trees", "max_tree_size",
                        "color", "in_legend"])
            for rank, c in enumerate(ranked, 1):
                cs = per_crate[c]
                w.writerow([rank, c, len(cs), sum(a["count"] for a in cs.values()),
                            max(cs), to_hex(crate_color[c]),
                            "true" if c in top_crates else "false"])
        print(f"Wrote {keypath}")
        shown = n_top if args.top_crates else 15
        print(f"\nCrate legend ({n_top} of {len(ranked)} crates colored"
              f"{', rest gray' if n_top < len(ranked) else ''}):")
        print(f"  {'#':>3}  {'crate':<34} {'dots':>7} {'trees':>14}  color")
        for rank, c in enumerate(ranked[:shown], 1):
            cs = per_crate[c]
            print(f"  {rank:>3}  {c:<34} {len(cs):>7,} "
                  f"{sum(a['count'] for a in cs.values()):>14,}  {to_hex(crate_color[c])}")


if __name__ == "__main__":
    main()
