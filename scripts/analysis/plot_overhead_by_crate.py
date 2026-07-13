#!/usr/bin/env python3
"""
Usage: plot_overhead_by_crate.py [overhead_csv] [output_dir]

Plot every crate's overhead (runtime relative to native rust) for each
variant of the overhead report, with crates ordered along the x axis by
better-bt-bsan overhead (ascending). One series per variant. Only plain
better-bt-bsan and the visits-per-gc variants at or above 60000 are
plotted, and only crates with an overhead and at least one passing test
under every plotted variant, so all series cover the same crate set.

  overhead_csv  the overhead report. Default: <OUTPUTS_DIR>/analysis/overhead-top_500_fast.csv.
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
                        default=os.path.join(OUTPUTS_DIR, "analysis", "overhead-top_500_fast.csv"))
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

    def visits_per_gc(col):
        prefix = "visit-gc-bsan-visits-per-gc-"
        if not (col.startswith(prefix) and col.endswith("_overhead")):
            return None
        try:
            return int(col[len(prefix):-len("_overhead")])
        except ValueError:
            return None

    overhead_cols = [c for c in overhead[0]
                     if c == "better-bt-bsan_overhead"
                     or (visits_per_gc(c) or 0) == 60_000 or (visits_per_gc(c) or 0) == 150_000]
    if not overhead_cols:
        sys.exit(f"Error: no better-bt-bsan or visits-per-gc >= 60000 "
                 f"overhead columns in {args.overhead_csv}")

    def has_all_overheads(row):
        try:
            for c in overhead_cols:
                float(row[c])
                passed = c[:-len("_overhead")] + "_passed"
                if int(row[passed]) == 0:
                    return False
            return True
        except (KeyError, ValueError):
            return False

    # Crates with an overhead and at least one passing test for every plotted
    # variant, ordered by better-bt-bsan overhead ascending.
    kept = sorted((r for r in overhead if has_all_overheads(r)),
                  key=lambda r: float(r["better-bt-bsan_overhead"]))
    crates = [r["crate"] for r in kept]
    by_crate = {r["crate"]: r for r in kept}
    skipped = len(overhead) - len(crates)

    fig, ax = plt.subplots(figsize=(max(12, 0.11 * len(crates)), 7))
    cmap = plt.get_cmap("tab10" if len(overhead_cols) <= 10 else "tab20")
    xs_all = range(len(crates))
    for i, col in enumerate(overhead_cols):
        variant = col[:-len("overhead")].rstrip("_")
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

    # Overheads span orders of magnitude across crates; log y keeps the
    # low-overhead crates readable next to the extreme ones.
    ax.set_yscale("log")
    ax.set_xticks(list(xs_all))
    ax.set_xticklabels(crates, rotation=90, fontsize=5)
    ax.set_xlim(-1, len(crates))
    ax.set_xlabel("crate  (ordered by better-bt-bsan overhead, ascending)")
    ax.set_ylabel("overhead vs. native rust  (log scale)")
    ax.set_title(f"Per-crate overhead by variant  ({len(crates)} crates)")
    ax.grid(True, axis="y", ls=":", alpha=0.4)
    ax.legend(loc="upper left", fontsize=8, ncol=2, framealpha=0.9)
    fig.tight_layout()

    os.makedirs(args.output_dir, exist_ok=True)
    out = os.path.join(args.output_dir, "overhead_by_crate.png")
    fig.savefig(out, dpi=150)
    plt.close(fig)

    print(f"Plotted {len(overhead_cols)} series over {len(crates)} crates "
          f"({skipped} overhead rows lacked an overhead or a passing test "
          f"for some plotted variant and were skipped).")
    print(f"Wrote {out}")


if __name__ == "__main__":
    main()
