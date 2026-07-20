#!/usr/bin/env python3
"""
Usage: plot_by_crate.py <metric> <csv> [csv ...] [-o output_dir]

Plot a per-crate metric straight from the raw per-image result CSVs (the
<image>-<dataset>.csv files, each with a run_seconds column). One series per
plotted CSV, crates ordered along the x axis by the first plotted series
(ascending). Runtime always comes from run_seconds. Only crates that ran with
valid data under every input CSV are drawn, so all series cover the same crate
set.

  metric   what to plot:
             seconds   run_seconds of each CSV
             overhead  variant run_seconds / baseline run_seconds
             speedup   baseline run_seconds / variant run_seconds
                       (dashed line at 1)
  csv      raw result CSVs to use as the datapoints. For overhead and speedup
           the FIRST csv is the baseline (native rust for overhead, stock Miri
           for speedup); it sets the denominator/numerator and is not itself
           plotted, and the rest are the variants. For seconds every csv is
           plotted and the first only sets the x ordering. Each series is
           labelled by its filename (without the .csv extension).

  -o/--output-dir  where the PNG is written (default <OUTPUTS_DIR>/analysis).

The PNG is written to <output_dir>/<metric>_by_crate.png. The outputs dir
defaults to <repo root>/outputs, found relative to this script (so it works
both locally and on the cluster); override with $OUTPUTS_DIR.
"""

import argparse
import csv
import math
import os
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUTPUTS_DIR = os.environ.get("OUTPUTS_DIR", os.path.join(REPO_ROOT, "outputs"))

# Statuses where the test binary actually ran, so run_seconds is meaningful
# (a failing test still compiled and executed); build/fetch failures record
# 0.000s and are excluded.
RAN_STATUSES = ("success", "test_failed")

METRICS = {
    "seconds": {
        "has_baseline": False,
        "check_passed": True,
        "ylabel": "test-suite runtime, seconds  (log scale)",
        "title": "Per-crate runtime by variant",
    },
    "overhead": {
        "has_baseline": True,
        "check_passed": True,
        "ylabel": "overhead vs. {baseline}  (log scale)",
        "title": "Per-crate overhead by variant",
    },
    "speedup": {
        "has_baseline": True,
        "check_passed": False,
        "ylabel": "speedup vs. {baseline}  (log scale)",
        "title": "Per-crate speedup by variant",
    },
}


def load_csv(path):
    """Return (label, {crate: row}) for a raw result CSV. Result files are
    append-only, so the last row per crate wins. The series label is the
    filename without its .csv extension."""
    if not os.path.isfile(path):
        sys.exit(f"Error: file not found: {path}")
    data = {}
    with open(path, newline="") as f:
        reader = csv.DictReader(f)
        if reader.fieldnames is None or "run_seconds" not in reader.fieldnames:
            sys.exit(f"Error: {path} has no run_seconds column "
                     f"(is it a raw result CSV?)")
        for row in reader:
            crate = row.get("crate")
            if crate is not None:
                data[crate] = row
    base = os.path.basename(path)
    label = base[:-len(".csv")] if base.endswith(".csv") else base
    return label, data


def ran(row):
    status = row.get("status")
    return status is None or status in RAN_STATUSES


def run_seconds(row):
    """run_seconds if the binary ran and the value is a usable positive number,
    else None (log axes and ratios can't use 0 or a build failure's blank)."""
    if not ran(row):
        return None
    try:
        s = float(row["run_seconds"])
    except (KeyError, ValueError):
        return None
    return s if s > 0 else None


def passed_ok(row):
    try:
        return int(row["passed"]) > 0
    except (KeyError, ValueError):
        return False


def disambiguate(labels):
    """Append a 1-based counter to any label shared by more than one series,
    so duplicate `build` names stay distinct in the legend; unique labels are
    left untouched."""
    total = {}
    for label in labels:
        total[label] = total.get(label, 0) + 1
    seen = {}
    out = []
    for label in labels:
        if total[label] > 1:
            seen[label] = seen.get(label, 0) + 1
            out.append(f"{label} {seen[label]}")
        else:
            out.append(label)
    return out


def main():
    parser = argparse.ArgumentParser(
        usage=argparse.SUPPRESS, description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("metric", choices=sorted(METRICS))
    parser.add_argument("csvs", nargs="+")
    parser.add_argument("-o", "--output-dir",
                        default=os.path.join(OUTPUTS_DIR, "analysis"))
    args = parser.parse_args()
    metric = args.metric
    spec = METRICS[metric]

    if spec["has_baseline"] and len(args.csvs) < 2:
        sys.exit(f"Error: {metric} needs the baseline CSV first, then at least "
                 f"one variant CSV (got {len(args.csvs)}).")

    # Headless-safe backend; import after so --help works without matplotlib.
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        sys.exit("Error: matplotlib is required (pip install matplotlib).")

    loaded = [load_csv(p) for p in args.csvs]
    if spec["has_baseline"]:
        (baseline_label, baseline_data), series = loaded[0], loaded[1:]
    else:
        baseline_label, baseline_data, series = None, None, loaded

    # Number apart any variants sharing a `build` name so the legend (and the
    # averages below) can tell them apart.
    series = [(label, data) for label, (_, data)
              in zip(disambiguate([lbl for lbl, _ in series]), series)]

    check_passed = spec["check_passed"]

    def value(crate, row):
        """The plotted metric for one crate's row in one series, or None if the
        crate lacks usable data here (or in the baseline)."""
        v = run_seconds(row)
        if v is None:
            return None
        if baseline_data is not None:
            b = run_seconds(baseline_data.get(crate, {}))
            if b is None:
                return None
            return v / b if metric == "overhead" else b / v
        return v

    def keeps(crate):
        for _, data in series:
            row = data.get(crate)
            if row is None or value(crate, row) is None:
                return False
            if check_passed and not passed_ok(row):
                return False
        return True

    # Every crate seen in any input, and the subset with usable data across all
    # of them, ordered by the first plotted series ascending.
    all_crates = set(baseline_data or {})
    for _, data in series:
        all_crates |= set(data)
    first_data = series[0][1]
    crates = sorted((c for c in all_crates if keeps(c)),
                    key=lambda c: value(c, first_data[c]))
    skipped = len(all_crates) - len(crates)
    if not crates:
        sys.exit(f"Error: no crate has a usable {metric} value"
                 f"{' and a passing test' if check_passed else ''} "
                 f"across every input CSV.")

    fig, ax = plt.subplots(figsize=(max(12, 0.11 * len(crates)), 7))
    cmap = plt.get_cmap("tab10" if len(series) <= 10 else "tab20")
    xs_all = range(len(crates))
    for i, (label, data) in enumerate(series):
        pts = []
        for x, crate in zip(xs_all, crates):
            v = value(crate, data.get(crate, {}))
            if v is not None:
                pts.append((x, v))
        if not pts:
            continue
        xs, ys = zip(*pts)
        ax.plot(xs, ys, marker="o", ms=3, lw=0.8, alpha=0.8,
                color=cmap(i % cmap.N), label=label)

    if metric == "speedup":
        ax.axhline(1.0, ls="--", color="0.4", lw=1)
    # Values span orders of magnitude across crates (and ratios are
    # multiplicative); log y keeps the small ones readable next to the
    # extreme ones.
    ax.set_yscale("log")
    ax.set_xticks(list(xs_all))
    ax.set_xticklabels(crates, rotation=90, fontsize=5)
    ax.set_xlim(-1, len(crates))
    ax.set_xlabel(f"crate  (ordered by {series[0][0]} {metric}, ascending)")
    ax.set_ylabel(spec["ylabel"].format(baseline=baseline_label))
    ax.set_title(f"{spec['title']}  ({len(crates)} crates)")
    ax.grid(True, axis="y", ls=":", alpha=0.4)
    ax.legend(loc="upper left", fontsize=8, ncol=2, framealpha=0.9)
    fig.tight_layout()

    os.makedirs(args.output_dir, exist_ok=True)
    out = os.path.join(args.output_dir, f"{metric}_by_crate.png")
    fig.savefig(out, dpi=150)
    plt.close(fig)

    print(f"Plotted {len(series)} series over {len(crates)} crates "
          f"({skipped} crates lacked a usable {metric} value"
          f"{' or a passing test' if check_passed else ''} "
          f"under some input CSV and were skipped).")
    print(f"Wrote {out}")

    # Per-crate averages of each series over the shared crate set. Every kept
    # crate has a value in every series, so all averages cover the same crates.
    # Ratios (overhead/speedup) are multiplicative, so the geometric mean is
    # the meaningful average; seconds is additive, so read the plain mean.
    print(f"\nPer-crate {metric} averaged over {len(crates)} crates:")
    width = max(len(label) for label, _ in series)
    for label, data in series:
        ys = [value(crate, data[crate]) for crate in crates]
        mean = sum(ys) / len(ys)
        geomean = math.exp(sum(math.log(y) for y in ys) / len(ys))
        print(f"  {label:<{width}}  mean={mean:.3f}  geomean={geomean:.3f}")


if __name__ == "__main__":
    main()
