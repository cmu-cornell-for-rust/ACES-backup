#!/usr/bin/env python3
"""
Usage: plot_speedup_by_crate.py [overhead_csv] [output_dir]

Plot every crate's value for each *speedup column of the overhead report,
with crates ordered along the x axis by base_miri_overhead (ascending).
One series per variant, a dashed line at speedup = 1. Crates with no
base-miri overhead or no passing lazy-alloc tests are skipped.

  overhead_csv  the overhead report. Default: <OUTPUTS_DIR>/analysis/overhead-top_500.csv.
  output_dir    where the PNG is written. Default: <OUTPUTS_DIR>/analysis.

The outputs dir defaults to <repo root>/outputs, found relative to this script
(so it works both locally and on the cluster); override with $OUTPUTS_DIR.
"""

import argparse
import csv
import os
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUTPUTS_DIR = os.environ.get("OUTPUTS_DIR", os.path.join(REPO_ROOT, "outputs"))


def read_csv(path):
    if not os.path.isfile(path):
        sys.exit(f"Error: file not found: {path}")
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def main():
    parser = argparse.ArgumentParser(
        usage=argparse.SUPPRESS, description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("overhead_csv", nargs="?",
                        default=os.path.join(OUTPUTS_DIR, "analysis", "overhead-top_500.csv"))
    parser.add_argument("output_dir", nargs="?",
                        default=os.path.join(OUTPUTS_DIR, "analysis"))
    args = parser.parse_args()

    # Headless-safe backend; import after so --help works without matplotlib.
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        sys.exit("Error: matplotlib is required (pip install matplotlib).")

    overhead = read_csv(args.overhead_csv)
    # A couple of columns are spelled ...bsanspeedup with no underscore, so
    # match the bare suffix and strip any trailing underscore off the variant.
    # bsan variants are excluded: their extreme outliers drown out the other series.
    speedup_cols = [c for c in overhead[0]
                    if c.endswith("speedup") and "bsan" not in c]
    if not speedup_cols:
        sys.exit(f"Error: no *speedup columns in {args.overhead_csv}")

    def base_overhead(row):
        try:
            return float(row["base_miri_overhead"])
        except (KeyError, ValueError):
            return None

    def passed(row):
        try:
            return int(row["lazy-alloc_passed"]) > 0
        except (KeyError, ValueError):
            return False

    # Crates with a base-miri overhead and at least one passing lazy-alloc
    # test, ordered by base_miri_overhead ascending.
    kept = sorted((r for r in overhead
                   if base_overhead(r) is not None and passed(r)),
                  key=base_overhead)
    crates = [r["crate"] for r in kept]
    by_crate = {r["crate"]: r for r in kept}
    skipped = len(overhead) - len(crates)

    fig, ax = plt.subplots(figsize=(max(12, 0.11 * len(crates)), 7))
    cmap = plt.get_cmap("tab10" if len(speedup_cols) <= 10 else "tab20")
    xs_all = range(len(crates))
    for i, col in enumerate(speedup_cols):
        variant = col[:-len("speedup")].rstrip("_")
        pts = []
        for x, crate in zip(xs_all, crates):
            try:
                pts.append((x, float(by_crate[crate][col])))
            except ValueError:
                pass  # crate absent / failed under this variant
        if not pts:
            continue
        xs, ys = zip(*pts)
        ax.plot(xs, ys, marker="o", ms=3, lw=0.8, alpha=0.8,
                color=cmap(i % cmap.N), label=variant)

    ax.axhline(1.0, ls="--", color="0.4", lw=1)
    # Ratios are multiplicative: log y keeps 2x and 0.5x equidistant from 1 and
    # stops the few enormous outliers from flattening everything else.
    ax.set_yscale("log")
    ax.set_xticks(list(xs_all))
    ax.set_xticklabels(crates, rotation=90, fontsize=5)
    ax.set_xlim(-1, len(crates))
    ax.set_xlabel("crate  (ordered by base_miri_overhead, ascending)")
    ax.set_ylabel("speedup vs. base miri  (log scale)")
    ax.set_title(f"Per-crate speedup by variant  ({len(crates)} crates)")
    ax.grid(True, axis="y", ls=":", alpha=0.4)
    ax.legend(loc="upper left", fontsize=8, ncol=2, framealpha=0.9)
    fig.tight_layout()

    os.makedirs(args.output_dir, exist_ok=True)
    out = os.path.join(args.output_dir, "speedup_by_crate.png")
    fig.savefig(out, dpi=150)
    plt.close(fig)

    print(f"Plotted {len(speedup_cols)} variants over {len(crates)} crates "
          f"({skipped} overhead rows had no base-miri overhead or no passing "
          f"lazy-alloc tests and were skipped).")
    print(f"Wrote {out}")


if __name__ == "__main__":
    main()
