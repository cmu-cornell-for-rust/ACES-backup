#!/usr/bin/env python3
"""
Usage: plot_wide_by_crate.py <csv> <column> [column ...] [-o output_dir]

The `seconds` plot of plot_by_crate.py, but reading one WIDE spreadsheet
instead of one result CSV per series.

plot_by_crate.py takes N files and reads run_seconds from each. The overhead
study sheet has already been joined the other way: one row per crate, and each
variant contributes a group of columns

    <variant>_status  <variant>_seconds  <variant>_speedup
    <variant>_overhead  <variant>_tests  <variant>_passed

so a series here is a COLUMN GROUP, named by the variant prefix. Name the
columns you want plotted, in the order you want them plotted; `_seconds` is
optional, so `lazy-alloc` and `lazy-alloc_seconds` select the same series.
Pass --list-columns to see what a sheet offers.

The sheet is a Google Sheets export, so it does not start with its header: a
banner row of merged group titles comes first, then a row of averages, and the
leading column is blank. The header is found by scanning for the row whose
first cells contain `crate`; everything above it is skipped and everything
below is data.

Selection matches plot_by_crate.py's seconds metric exactly, so the two plots
mean the same thing:

  * a crate is plotted only if EVERY named column ran it (status success or
    test_failed) with a usable positive time -- a variant that is `absent` or
    `build_failed` for a crate drops that crate from all series, keeping the
    series over one shared crate set
  * and only if every named column reports every test passing, since a suite
    that failed partway measures less work than one that completed. Excluded
    crates are listed with their passed/tests counts; --allow-failures plots
    them anyway, --require-equal-passed additionally demands the counts match
  * crates are ordered along the x axis by the FIRST named column, ascending

Options are the same as plot_by_crate.py's where they apply: --labels,
--cmap-indices, --min-seconds [--min-seconds-only-first], --allow-failures,
--require-equal-passed, --title, --dpi, --format.

The plot is written to <output_dir>/<name>[_min<N>s[_first]].<format>, where
<name> defaults to wide_seconds_by_crate (--out-name overrides it). The outputs
dir defaults to <repo root>/outputs/analysis; override with -o or $OUTPUTS_DIR.
"""

import argparse
import csv
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
# The row predicates, the label de-duplicator and the outputs-dir default are
# shared verbatim, so a crate kept here is a crate kept there.
from plot_by_crate import (OUTPUTS_DIR, all_passed, disambiguate, passed_count,
                           passed_fraction, run_seconds)

# The per-variant column group. `status` and `seconds` are what the plot needs;
# `tests`/`passed` gate the all-passing requirement. Missing ones are simply
# absent from the synthesized row, and the helpers already treat that as "this
# input cannot report", which fails the check rather than passing it silently.
SUFFIXES = {"status": "_status", "run_seconds": "_seconds",
            "tests": "_tests", "passed": "_passed"}


def load_wide(path, want):
    """Return [(label, {crate: row}), ...] for the named column groups, in the
    order named.

    Each synthesized row carries the keys plot_by_crate's helpers read
    (status/run_seconds/tests/passed), so run_seconds() and all_passed() apply
    unchanged.
    """
    if not os.path.isfile(path):
        sys.exit(f"Error: file not found: {path}")

    with open(path, newline="") as f:
        rows = list(csv.reader(f))

    # A sheet export leads with merged group banners and an averages row, so the
    # header is not row 0. It is the first row that names the crate column.
    header, start = None, None
    for i, row in enumerate(rows):
        cells = [c.strip() for c in row]
        if "crate" in cells:
            header, start = cells, i + 1
            break
    if header is None:
        sys.exit(f"Error: {path} has no header row containing a `crate` column.")

    crate_at = header.index("crate")
    index = {name: i for i, name in enumerate(header) if name}

    series = []
    for name in want:
        # `_seconds` is optional in what the caller types; the group is keyed by
        # the prefix either way.
        prefix = name[:-len("_seconds")] if name.endswith("_seconds") else name
        if prefix + "_seconds" not in index:
            sys.exit(f"Error: {path} has no `{prefix}_seconds` column. "
                     f"Run with --list-columns to see what it does have.")
        data = {}
        for row in rows[start:]:
            if crate_at >= len(row):
                continue
            crate = row[crate_at].strip()
            if not crate:
                continue
            data[crate] = {
                key: row[index[prefix + suffix]].strip()
                for key, suffix in SUFFIXES.items()
                if prefix + suffix in index and index[prefix + suffix] < len(row)
            }
        series.append((prefix, data))
    return series


def list_columns(path):
    """Print every plottable column group in the sheet, with its banner title
    when the merged row above the header supplies one."""
    with open(path, newline="") as f:
        rows = list(csv.reader(f))
    header_at = next((i for i, r in enumerate(rows)
                      if "crate" in [c.strip() for c in r]), None)
    if header_at is None:
        sys.exit(f"Error: {path} has no header row containing a `crate` column.")
    header = [c.strip() for c in rows[header_at]]
    # The banner row carries a group's title in the cell above its FIRST column
    # and blanks across the rest, so carry the last non-empty value forward.
    banner = [c.strip() for c in rows[0]] if header_at else []
    title, titles = "", []
    for i in range(len(header)):
        if i < len(banner) and banner[i]:
            title = banner[i]
        titles.append(title)

    print(f"Plottable columns in {os.path.basename(path)}:")
    for i, name in enumerate(header):
        if name.endswith("_seconds"):
            group = titles[i] if i < len(titles) else ""
            print(f"  {name[:-len('_seconds')]:<70}"
                  f"{'  -- ' + group if group else ''}")


def main():
    parser = argparse.ArgumentParser(
        description="Plot per-crate seconds from the wide overhead-study sheet.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__)
    parser.add_argument("csv", help="the wide sheet export")
    parser.add_argument("columns", nargs="*", metavar="COLUMN",
                        help="column groups to plot, in plotting order. Either "
                             "the bare variant prefix (lazy-alloc) or the full "
                             "column name (lazy-alloc_seconds). The first one "
                             "sets the x ordering.")
    parser.add_argument("--list-columns", action="store_true",
                        help="list the sheet's plottable column groups and exit.")
    parser.add_argument("-o", "--output-dir",
                        default=os.path.join(OUTPUTS_DIR, "analysis"),
                        help="where the plot is written "
                             "(default <OUTPUTS_DIR>/analysis).")
    parser.add_argument("--out-name", default="wide_seconds_by_crate",
                        help="output basename before the suffixes and extension "
                             "(default wide_seconds_by_crate, chosen so it cannot "
                             "overwrite plot_by_crate.py's seconds_by_crate).")
    parser.add_argument("--labels", nargs="+", metavar="LABEL",
                        help="legend label per plotted column, in order. Column "
                             "prefixes are long enough that the legend can "
                             "outgrow the figure and squeeze the axes.")
    parser.add_argument("--title", default="Unsafe Crate Testbench Runtimes in Miri",
                        help="plot title.")
    parser.add_argument("--cmap-indices", type=int, nargs="+", metavar="N",
                        help="explicit colormap index per plotted column, in "
                             "plotting order.")
    parser.add_argument("--allow-failures", action="store_true",
                        help="plot crates whose tests did not all pass. Their "
                             "runtime is the cost of the part that ran, not of "
                             "the workload the other columns completed.")
    parser.add_argument("--require-equal-passed", action="store_true",
                        help="additionally require the passed test COUNT to "
                             "match across columns. All-passing does not imply "
                             "equal counts.")
    parser.add_argument("--min-seconds", type=float, metavar="N",
                        help="drop crates measuring under N seconds in ANY "
                             "plotted column. Aimed at the noise floor, where a "
                             "total is mostly per-invocation startup. The cut "
                             "spans every column so column order cannot change "
                             "the selection.")
    parser.add_argument("--min-seconds-only-first", action="store_true",
                        help="apply --min-seconds to the FIRST column alone. "
                             "Asymmetric: the kept crates are the ones where "
                             "that one arm was large, so the selection depends "
                             "on column order.")
    parser.add_argument("--dpi", type=int, default=300, metavar="N",
                        help="raster resolution (default 300). Vector formats "
                             "ignore it.")
    parser.add_argument("--format", default="png",
                        help="output format: png, pdf, svg (default png).")
    args = parser.parse_args()

    if args.list_columns:
        list_columns(args.csv)
        return
    if not args.columns:
        parser.error("name at least one column to plot "
                     "(or pass --list-columns to see them).")
    if args.min_seconds_only_first and args.min_seconds is None:
        parser.error("--min-seconds-only-first has no effect without --min-seconds.")

    # Headless-safe backend; import after argument handling so --help and
    # --list-columns work without matplotlib.
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        sys.exit("Error: matplotlib is required (pip install matplotlib).")

    series = load_wide(args.csv, args.columns)
    if args.labels is not None:
        if len(args.labels) != len(series):
            sys.exit(f"Error: --labels expects {len(series)} value(s) (one per "
                     f"plotted column), got {len(args.labels)}.")
        series = [(lab, data) for lab, (_, data) in zip(args.labels, series)]
    else:
        series = list(zip(disambiguate([lab for lab, _ in series]),
                          [data for _, data in series]))

    color_indices = None
    if args.cmap_indices is not None:
        if len(args.cmap_indices) != len(series):
            sys.exit(f"Error: --cmap-indices expects {len(series)} value(s), "
                     f"got {len(args.cmap_indices)}.")
        color_indices = list(args.cmap_indices)

    def has_data(crate):
        for _, data in series:
            row = data.get(crate)
            if row is None or run_seconds(row) is None:
                return False
        return True

    all_crates = set()
    for _, data in series:
        all_crates |= set(data)
    usable = [c for c in all_crates if has_data(c)]
    skipped = len(all_crates) - len(usable)

    # --min-seconds runs before the pass filter so the exclusion table below
    # doesn't list crates that are out of scope anyway.
    if args.min_seconds is not None:
        cut_on = [0] if args.min_seconds_only_first else list(range(len(series)))

        def input_secs(crate):
            return [(label, run_seconds(data.get(crate) or {}) or 0.0)
                    for label, data in series]

        def worst_secs(crate):
            secs = input_secs(crate)
            return min(secs[i][1] for i in cut_on)

        too_small = sorted((c for c in usable if worst_secs(c) < args.min_seconds),
                           key=lambda c: -worst_secs(c))
        if too_small:
            small = set(too_small)
            usable = [c for c in usable if c not in small]
            labels = [label for label, _ in series]
            cw = max(max(len(c) for c in too_small), len("crate")) + 2
            widths = [max(len(lab), 9) + 2 for lab in labels]
            if args.min_seconds_only_first:
                scope = (f"crate(s) measuring under that in {labels[0]}\n"
                         f"(--min-seconds-only-first: the cut is on that column "
                         f"alone, so the selection depends on column order). "
                         f"Seconds per column, * marks the ones below the cut:")
            else:
                scope = ("crate(s) measuring under that in at least one column\n"
                         "(the cut applies to every column, so column order "
                         "cannot change the selection). Seconds per column, "
                         "* marks the ones below the cut:")
            print(f"\n--min-seconds {args.min_seconds:g} excluded "
                  f"{len(too_small)} " + scope)
            print("crate".ljust(cw)
                  + "".join(f"{lab:>{w}}" for lab, w in zip(labels, widths)))
            for crate in too_small:
                cells = "".join(
                    f"{f'{v:.3f}' + ('*' if v < args.min_seconds else ''):>{w}}"
                    for (_, v), w in zip(input_secs(crate), widths))
                print(crate.ljust(cw) + cells)
            print()

    def clean_everywhere(crate):
        """True when every plotted column ran the crate with every test passing.
        A column that cannot report its counts (None) is treated as failing: it
        cannot be shown clean."""
        return all(all_passed(data.get(crate) or {}) is True
                   for _, data in series)

    def passed_agrees(crate):
        counts = [passed_count(data.get(crate) or {}) for _, data in series]
        return None not in counts and len(set(counts)) == 1

    def selected(crate):
        if not args.allow_failures and not clean_everywhere(crate):
            return False
        if args.require_equal_passed and not passed_agrees(crate):
            return False
        return True

    kept = [c for c in usable if selected(c)]
    excluded = sorted(c for c in usable if not selected(c))
    first_data = series[0][1]
    crates = sorted(kept, key=lambda c: run_seconds(first_data[c]))

    if excluded:
        labels = [label for label, _ in series]
        cw = max(max(len(c) for c in excluded), len("crate")) + 2
        widths = [max(len(lab), 9) + 2 for lab in labels]
        why = "not every test passed in every column"
        if args.allow_failures:
            why = "the columns disagree on how many tests passed"
        elif args.require_equal_passed:
            why += ", or the counts differ between columns"
        print(f"\n{len(excluded)} crate(s) excluded: {why}, so their runtimes "
              f"are not\nthe same workload (plot them anyway with "
              f"--allow-failures). Columns are passed/tests:")
        print("crate".ljust(cw)
              + "".join(f"{lab:>{w}}" for lab, w in zip(labels, widths)))
        for crate in excluded:
            cells = "".join(
                f"{passed_fraction(data.get(crate) or {}):>{w}}"
                for (_, data), w in zip(series, widths))
            print(crate.ljust(cw) + cells)
        print()

    if not crates:
        sys.exit("Error: no crate has a usable seconds value and a passing test "
                 "across every named column.")

    fig, ax = plt.subplots(figsize=(max(12, 0.11 * len(crates)), 7))
    cmap = plt.get_cmap("tab10" if len(series) <= 10 else "tab20")
    for i, (label, data) in enumerate(series):
        ys = [run_seconds(data[crate]) for crate in crates]
        ci = color_indices[i] if color_indices is not None else i
        ax.plot(range(len(crates)), ys, marker="o", ms=3, lw=0.8, alpha=0.8,
                color=cmap(ci % cmap.N), label=label)

    # Values span orders of magnitude across crates, so log y keeps the small
    # ones readable next to the extreme ones.
    ax.set_yscale("log")
    ax.set_xticks(list(range(len(crates))))
    ax.set_xticklabels(crates, rotation=90, fontsize=5)
    ax.set_xlim(-1, len(crates))
    ax.set_xlabel(f"Crate  (Ordered by {series[0][0]}, ascending)", fontsize=12)
    ax.set_ylabel("Testbench Runtime, Seconds  (Log Scale)", fontsize=12)
    ax.set_title(args.title, fontsize=14)
    ax.grid(True, axis="y", ls=":", alpha=0.4)
    ax.legend(loc="upper left", fontsize=12, ncol=2, framealpha=0.9)
    fig.tight_layout()

    os.makedirs(args.output_dir, exist_ok=True)
    # The float is rendered with 'p' for the point so the name stays one
    # extension-free token (0.5 -> _min0p5s).
    tag = ""
    if args.min_seconds is not None:
        tag = "_min" + f"{args.min_seconds:g}".replace(".", "p") + "s"
        if args.min_seconds_only_first:
            tag += "_first"
    out = os.path.join(args.output_dir,
                       f"{args.out_name}{tag}.{args.format}")
    fig.savefig(out, dpi=args.dpi)
    plt.close(fig)

    print(f"Plotted {len(series)} column(s) over {len(crates)} crates "
          f"({skipped} crates lacked a usable seconds value under some column "
          f"and were skipped"
          f"{f'; {len(excluded)} more had failing tests' if excluded else ''}).")
    print(f"Wrote {out}")

    # Every kept crate has a value in every column, so all averages cover the
    # same crates. Seconds is additive, so read the plain mean; the geometric
    # mean is printed alongside because the spread is multiplicative.
    print(f"\nPer-crate seconds averaged over {len(crates)} crates:")
    width = max(len(label) for label, _ in series)
    for label, data in series:
        ys = [run_seconds(data[crate]) for crate in crates]
        mean = sum(ys) / len(ys)
        geomean = math.exp(sum(math.log(y) for y in ys) / len(ys))
        print(f"  {label:<{width}}  mean={mean:.3f}  geomean={geomean:.3f}")


if __name__ == "__main__":
    main()
