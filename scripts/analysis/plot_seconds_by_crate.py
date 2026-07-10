#!/usr/bin/env python3
"""
Usage: plot_seconds_by_crate.py [overhead_csv] [output_dir]

Plot every crate's runtime in seconds for each variant of the overhead
report, with crates ordered along the x axis by visits-per-gc-150000
seconds (ascending). One series per variant. Only plain better-bt-bsan and
visits-per-gc-150000 are plotted, and only crates with a runtime and at
least one passing test under every plotted variant, so all series cover
the same crate set.

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

    wanted = ["better-bt-bsan_seconds",
              "visit-gc-bsan-visits-per-gc-150000_seconds"]
    seconds_cols = [c for c in wanted if c in overhead[0]]
    if len(seconds_cols) < len(wanted):
        missing = sorted(set(wanted) - set(seconds_cols))
        sys.exit(f"Error: missing columns {missing} in {args.overhead_csv}")

    def has_all_seconds(row):
        try:
            for c in seconds_cols:
                float(row[c])
                passed = c[:-len("_seconds")] + "_passed"
                if int(row[passed]) == 0:
                    return False
            return True
        except (KeyError, ValueError):
            return False

    # Crates with a runtime and at least one passing test for every plotted
    # variant, ordered by visits-per-gc-150000 seconds ascending.
    kept = sorted((r for r in overhead if has_all_seconds(r)),
                  key=lambda r: float(r["visit-gc-bsan-visits-per-gc-150000_seconds"]))
    crates = [r["crate"] for r in kept]
    by_crate = {r["crate"]: r for r in kept}
    skipped = len(overhead) - len(crates)

    fig, ax = plt.subplots(figsize=(max(12, 0.11 * len(crates)), 7))
    cmap = plt.get_cmap("tab10" if len(seconds_cols) <= 10 else "tab20")
    xs_all = range(len(crates))
    for i, col in enumerate(seconds_cols):
        variant = col[:-len("seconds")].rstrip("_")
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

    # Runtimes span orders of magnitude across crates; log y keeps the fast
    # crates readable next to the slow ones.
    ax.set_yscale("log")
    ax.set_xticks(list(xs_all))
    ax.set_xticklabels(crates, rotation=90, fontsize=5)
    ax.set_xlim(-1, len(crates))
    ax.set_xlabel("crate  (ordered by visits-per-gc-150000 seconds, ascending)")
    ax.set_ylabel("test-suite runtime, seconds  (log scale)")
    ax.set_title(f"Per-crate runtime by variant  ({len(crates)} crates)")
    ax.grid(True, axis="y", ls=":", alpha=0.4)
    ax.legend(loc="upper left", fontsize=8, ncol=2, framealpha=0.9)
    fig.tight_layout()

    os.makedirs(args.output_dir, exist_ok=True)
    out = os.path.join(args.output_dir, "seconds_by_crate.png")
    fig.savefig(out, dpi=150)
    plt.close(fig)

    print(f"Plotted {len(seconds_cols)} series over {len(crates)} crates "
          f"({skipped} overhead rows lacked a runtime or a passing test "
          f"for some plotted variant and were skipped).")
    print(f"Wrote {out}")


if __name__ == "__main__":
    main()
