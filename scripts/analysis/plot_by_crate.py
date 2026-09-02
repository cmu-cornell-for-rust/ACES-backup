#!/usr/bin/env python3
"""
Usage: plot_by_crate.py <metric> <csv> [csv ...] [-o output_dir]

Plot a per-crate metric straight from the result CSVs the run_*_dataset scripts
produce, in either format:

  raw        <image>-<dataset>.csv -- one row per crate, runtime read from
             its run_seconds column (the whole test suite in one invocation)
  hyperfine  <image>-<dataset>-hyperfine.csv -- one row per TEST; a crate's
             runtime is the SUM of its tests' mean_s

The two can't be compared against each other: every hyperfine mean_s includes
cargo's freshness check and the startup of all the crate's test binaries, so
summing N tests counts that constant N times, well above the raw CSVs'
whole-suite run_seconds. Plot hyperfine against hyperfine (the constant is in
both) -- the script warns if the inputs mix formats.

One series per plotted CSV, crates ordered along the x axis by the first
plotted series (ascending). Only crates that ran with valid data under every
input CSV are drawn, so all series cover the same crate set.

A crate is also required to have EVERY test passing in every input (the
baseline included, since it sets the ratio): if a crate's suite failed partway
under one image, its runtime is the cost of the part that ran, not of the
workload the other images completed. Those crates are listed on stdout with
their per-input passed/tests counts rather than silently dropped. Pass
--allow-failures to plot them anyway.

Note that all-passing does NOT imply the inputs ran the same NUMBER of tests --
an input can compile out (#[cfg(not(miri))]) or ignore (#[cfg_attr(miri,
ignore)]) tests the others ran, and every one that did run then passed. Add
--require-equal-passed to demand matching counts as well.

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

  --no-ffi         plot only crates whose contains_ffi is false in the
                   list_tests.sh CSV (crate,tests,contains_ffi), i.e. crates
                   cargo-scan found no FFI call or declaration in. Crates with
                   FFI, and crates whose status is unknown -- scan_failed, or no
                   row in that CSV -- are excluded and listed on stdout. The CSV
                   is found by matching its tests-<dataset>.csv name against the
                   input filenames (<OUTPUTS_DIR> first, then <repo>/scripts);
                   --tests-csv FILE points at one directly. The output file
                   gains a _no_ffi suffix so it never overwrites the full plot.

  --min-seconds N  drop crates measuring under N seconds in ANY input, the
                   baseline included -- the crates whose totals are mostly the
                   per-invocation startup constant that survives the
                   calibration subtraction. Applying it to every input rather
                   than one keeps the selection symmetric: conditioning on a
                   single arm biases every ratio involving that arm upward, so
                   the result would otherwise depend on which csv was listed
                   first. Excluded crates are listed with their per-input
                   times, and the output file gains a _min<N>s suffix.

  --min-seconds-only-first
                   apply --min-seconds to the FIRST csv alone (the baseline, for
                   overhead/speedup) rather than to every input -- the old
                   behaviour, kept for reproducing older plots and for cutting on
                   a known-good baseline. It is asymmetric by construction: the
                   kept crates are the ones where that one arm was large, which
                   biases every ratio involving it upward and makes the selection
                   depend on argument order. The output gains a _first suffix.

The PNG is written to <output_dir>/<metric>_by_crate[_no_ffi][_min<N>s].png. The outputs dir
defaults to <repo root>/outputs, found relative to this script (so it works
both locally and on the cluster); override with $OUTPUTS_DIR.

    --cmap-indices N [N ...]
                                     explicit colormap index per plotted series, in plotting
                                     order. For seconds, provide one index per input CSV. For
                                     overhead/speedup, provide one per VARIANT (the baseline is
                                     first input CSV and is not plotted).

  --labels L [L ...]
                   legend label per input CSV, in the order given (baseline
                   included). Without it a series is named after its file, and a
                   real run name is long enough that the legend outgrows the
                   figure -- tight_layout then squeezes the axes to half width
                   making room for it. Quote labels containing spaces.
"""

import argparse
import csv
import glob
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
        "ylabel": "Testbench Runtime, Seconds  (Log Scale)",
        "title": "Unsafe Crate Testbench Runtimes",
    },
    "overhead": {
        "has_baseline": True,
        "check_passed": True,
        "ylabel": "overhead vs. {baseline}  (log scale)",
        "title": "Per-crate overhead by version",
    },
    "speedup": {
        "has_baseline": True,
        "check_passed": False,
        "ylabel": "speedup vs. {baseline}  (log scale)",
        "title": "Per-crate speedup by version",
    },
}


def aggregate_hyperfine(reader):
    """Collapse a per-test hyperfine CSV into the per-crate rows the rest of
    this script expects: a crate's runtime is the SUM of its tests' mean_s,
    each net of the crate's calibration row.

    mean_s is the statistic, matching merge_hyperfine.py and crate_totals.py so
    the plotted totals and those tools' per-crate tables are the same number.
    The tradeoff is deliberate: a hyperfine sample of a handful of runs is
    easily skewed upward by one scheduling hiccup on a shared node, and a sum
    of means inherits every such excursion, where min_s or median_s would shrug
    them off. On this dataset the choice is worth ~7% of a crate total, against
    the ~50% that subtracting calibration is worth -- so cross-tool agreement
    buys more than the noise resistance costs.

    Every measurement includes a constant: cargo's freshness check plus the
    startup of all the crate's test binaries (the --exact filter runs in each
    of them). run_bench_dataset.sh measures that constant per crate with a
    filter matching nothing and writes it as a test=__calibration__ row, which
    is subtracted here so what is summed is test-body time. The constant is
    ~1-3s per invocation under bsan/miri vs ~0.05s native, so leaving it in
    would turn a short-test crate's overhead into a startup-cost ratio.

    Subtraction is clamped at 0: a test whose body is faster than the noise on
    the calibration measurement contributes nothing rather than a negative.
    CSVs predating the calibration row are summed raw -- the caller reports
    which, since the two are not comparable.

    Only benchmarked tests carry a mean_s -- test_failed / no_match /
    bench_failed rows, and the single test-less row a build/fetch failure
    emits, all leave the timing columns empty and so contribute nothing. Like
    the raw result CSVs these files are append-only, so the same test can
    appear more than once; the last row for each (crate, test) wins, otherwise
    re-benchmarking a crate would inflate its sum.

    A crate with no benchmarked test at all gets no row, which `keeps()` then
    treats the same as a crate missing from the file.

    The synthetic row carries `passed` = the number of tests summed, so the
    check_passed metrics behave as they do for raw CSVs (where passed is the
    count of passing tests), and status=success so `ran()` accepts it.

    Returns (data, stats) where stats reports the calibration coverage.
    """
    def timing(row):
        try:
            v = float(row["mean_s"])
        except (KeyError, TypeError, ValueError):
            return None
        return v if v > 0 else None

    latest = {}
    calibration = {}
    for row in reader:
        crate = row.get("crate")
        if crate is None:
            continue
        if row.get("status") == "calibration":
            v = timing(row)
            if v is not None:
                calibration[crate] = v    # last calibration for the crate wins
            continue
        latest[(crate, row.get("test") or "")] = row

    data = {}
    zeroed = 0
    # Per-crate count of real test rows, so the caller can tell "every test
    # passed" from "every test that produced a timing passed". Rows with an
    # empty test name are the crate-level fetch/build failure markers, not
    # tests, and are excluded -- these CSVs are append-only, so a stale failure
    # row would otherwise mark a since-fixed crate as failing forever.
    test_rows = {}
    for (crate, test), row in latest.items():
        if test:
            test_rows[crate] = test_rows.get(crate, 0) + 1
        mean = timing(row)
        if mean is None:
            continue                      # not benchmarked -- no timing to add
        net = mean - calibration.get(crate, 0.0)
        if net <= 0:
            zeroed += 1
            net = 0.0
        agg = data.setdefault(crate, {"crate": crate, "status": "success",
                                      "run_seconds": 0.0, "passed": 0})
        agg["run_seconds"] += net
        agg["passed"] += 1

    # `tests` completes the synthetic row: `passed` counts the rows that
    # produced a timing, `tests` every row that was a test at all, so
    # passed == tests means the crate had no test_failed / no_match /
    # bench_failed row in this input.
    for crate, agg in data.items():
        agg["tests"] = test_rows.get(crate, agg["passed"])

    # A crate whose every test came out at or below its calibration has no
    # measurable body time left; run_seconds() rejects the 0 and the crate
    # drops out, so surface it rather than let it vanish.
    empty = [c for c, agg in data.items() if agg["run_seconds"] <= 0]
    for crate in empty:
        del data[crate]
    stats = {
        "calibrated": len(calibration),
        "zeroed_tests": zeroed,
        "dropped_crates": empty,
    }
    return data, stats


def load_csv(path):
    """Return (label, {crate: row}, kind, stats) for a result CSV, accepting
    either format produced by the run_*_dataset scripts:

      raw        one row per crate with a run_seconds column -- the last row
                 per crate wins, since result files are append-only
      hyperfine  one row per TEST with a mean_s column (the -hyperfine.csv
                 files) -- summed into one row per crate, see above

    The series label is the filename without its .csv extension.
    """
    if not os.path.isfile(path):
        sys.exit(f"Error: file not found: {path}")
    stats = None
    with open(path, newline="") as f:
        reader = csv.DictReader(f)
        fields = reader.fieldnames or []
        if "run_seconds" in fields:
            kind = "raw"
            data = {}
            for row in reader:
                crate = row.get("crate")
                if crate is not None:
                    data[crate] = row
        elif "mean_s" in fields and "test" in fields:
            kind = "hyperfine"
            data, stats = aggregate_hyperfine(reader)
        else:
            sys.exit(f"Error: {path} has neither a run_seconds column (raw "
                     f"result CSV) nor mean_s + test columns (hyperfine CSV).")
    base = os.path.basename(path)
    label = base[:-len(".csv")] if base.endswith(".csv") else base
    return label, data, kind, stats


def find_tests_csv(paths):
    """Locate the list_tests.sh CSV (crate,tests,contains_ffi) that goes with
    the result CSVs being plotted, for --no-ffi.

    list_tests.sh writes tests-<dataset>.csv, so any candidate whose <dataset>
    appears in an input filename (miri-top_500_fast-hyperfine.csv contains
    top_500_fast) is the right one. The outputs dir is searched first, then the
    repo's scripts dir, where a copy is sometimes kept; the longest matching
    dataset wins, so top_500_fast is not shadowed by a shorter name that is a
    substring of it. Returns None when nothing matches -- the caller reports it
    with the dirs searched, since --tests-csv is the way out.
    """
    bases = [os.path.basename(p) for p in paths]
    for d in (os.path.join(OUTPUTS_DIR), os.path.join(REPO_ROOT, "scripts")):
        matches = []
        for cand in sorted(glob.glob(os.path.join(d, "tests-*.csv"))):
            dataset = os.path.basename(cand)[len("tests-"):-len(".csv")]
            if dataset and any(dataset in b for b in bases):
                matches.append((len(dataset), cand))
        if matches:
            return max(matches)[1]
    return None


def load_ffi(path):
    """Return {crate: contains_ffi} from a list_tests.sh CSV, where the value is
    one of true/false/scan_failed (see list_tests.sh). The file is append-only
    and consumers keep the FIRST row per crate, so that is what is kept here."""
    if not os.path.isfile(path):
        sys.exit(f"Error: --no-ffi needs a list_tests.sh CSV; not found: {path}")
    ffi = {}
    with open(path, newline="") as f:
        reader = csv.DictReader(f)
        if "contains_ffi" not in (reader.fieldnames or []):
            sys.exit(f"Error: {path} has no contains_ffi column -- --no-ffi "
                     f"needs a list_tests.sh CSV (crate,tests,contains_ffi).")
        for row in reader:
            crate = row.get("crate")
            if crate and crate not in ffi:
                ffi[crate] = row.get("contains_ffi")
    if not ffi:
        sys.exit(f"Error: {path} has no crate rows, so --no-ffi would exclude "
                 f"every crate. Point --tests-csv at a populated list_tests.sh "
                 f"CSV (re-run list_tests.sh if this dataset was never listed).")
    return ffi


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


def all_passed(row):
    """True when every test of the crate passed in this input, False when any
    failed, None when the row cannot say.

    For a raw CSV `tests`/`passed` are libtest's own counts, summed over the
    crate's test binaries. For a hyperfine CSV they come from
    aggregate_hyperfine: `tests` is how many per-test rows the crate has and
    `passed` how many produced a timing, so passed < tests means the run
    recorded a test_failed / no_match / bench_failed row.

    A crate with zero tests is not "all passed" -- there is nothing to compare.
    """
    try:
        tests, passed = int(row["tests"]), int(row["passed"])
    except (KeyError, TypeError, ValueError):
        return None
    return passed == tests if tests > 0 else False


def passed_fraction(row):
    """`passed/tests` as a display string, or "?" when the row lacks them."""
    try:
        return f'{int(row["passed"])}/{int(row["tests"])}'
    except (KeyError, TypeError, ValueError):
        return "?"


def passed_count(row):
    """The row's passed test count, or None when it has no usable one. For a
    raw CSV that is the crate's passing-test count; for a hyperfine CSV it is
    the number of tests that carried a timing and were summed (see
    aggregate_hyperfine)."""
    try:
        return int(row["passed"])
    except (KeyError, TypeError, ValueError):
        return None


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
    parser.add_argument("--dpi", type=int, default=300, metavar="N",
                        help="output resolution (default 300, print quality). This figure's "
                             "width scales with the crate count, so a wide dataset at high "
                             "dpi makes a large PNG; matplotlib also caps any dimension at "
                             "65536 px. Use --format pdf for a resolution-independent file.")
    parser.add_argument("--format", default="png", metavar="EXT",
                        help="output file format: png (default), pdf or svg. The vector "
                             "formats ignore --dpi and stay sharp at any zoom.")
    parser.add_argument("--no-ffi", action="store_true",
                        help="plot only crates whose contains_ffi is false in the "
                             "list_tests.sh CSV (crate,tests,contains_ffi). Crates with "
                             "FFI, and crates whose FFI status is unknown (scan_failed, or "
                             "absent from that CSV), are excluded and listed. The output "
                             "file gains a _no_ffi suffix so it does not overwrite the "
                             "unfiltered plot.")
    parser.add_argument("--tests-csv", metavar="FILE",
                        help="the list_tests.sh CSV --no-ffi should read. Default: the "
                             "tests-<dataset>.csv whose dataset name appears in the input "
                             "filenames, looked up in <OUTPUTS_DIR> then <repo>/scripts.")
    parser.add_argument("--allow-failures", "--allow-passed-mismatch",
                        dest="allow_failures", action="store_true",
                        help="plot crates that had failing tests. By default only crates "
                             "where EVERY test passed in EVERY input are drawn, since a "
                             "run that bailed out partway is not the same workload as one "
                             "that completed. (--allow-passed-mismatch is the old name.)")
    parser.add_argument("--min-seconds", type=float, metavar="N",
                        help="drop crates measuring under N seconds in ANY input (the "
                             "baseline included). Aimed at the calibration noise floor: a "
                             "crate whose total is a fraction of a second is mostly the "
                             "per-invocation startup residue that survived the calibration "
                             "subtraction. The cut spans every input on purpose -- cutting "
                             "on one arm biases every ratio involving it upward, so the "
                             "answer would depend on which csv you listed first. Excluded "
                             "crates are listed with their per-input times. The output file "
                             "gains a _min<N>s suffix.")
    parser.add_argument("--min-seconds-only-first", action="store_true",
                        help="apply --min-seconds to the FIRST csv alone (the baseline for "
                             "overhead/speedup) instead of to every input. This is the old "
                             "behaviour and it is asymmetric on purpose only when you want "
                             "it: the kept crates are the ones where that one arm happened "
                             "to be large, which biases every ratio involving it upward and "
                             "makes the result depend on argument order. Use it to reproduce "
                             "an older plot or to cut on a known-good baseline. The output "
                             "file gains a _first suffix so it cannot overwrite the "
                             "symmetric plot.")
    parser.add_argument("--require-equal-passed", action="store_true",
                        help="additionally require the passed test COUNT to match across "
                             "inputs. All-passing does not imply equal counts: an input "
                             "can compile out or ignore tests the others ran.")
    parser.add_argument("--cmap-indices", type=int, nargs="+", metavar="N",
                        help="explicit colormap index per plotted series, in plotting "
                            "order. For seconds: one index per input CSV. For "
                            "overhead/speedup: one per variant (baseline is not "
                            "plotted).")
    parser.add_argument("--labels", nargs="+", metavar="LABEL",
                        help="legend label per input CSV, in the order the CSVs were "
                             "given (the baseline included, since overhead/speedup name "
                             "it in the y axis). Overrides the filename-derived labels, "
                             "which are long enough on a real run name that the legend "
                             "outgrows the figure and tight_layout squeezes the axes to "
                             "half width making room for it. Quote labels containing "
                             "spaces.")
    args = parser.parse_args()
    if args.min_seconds_only_first and args.min_seconds is None:
        parser.error("--min-seconds-only-first has no effect without --min-seconds.")
    metric = args.metric
    spec = METRICS[metric]

    if spec["has_baseline"] and len(args.csvs) < 2:
        sys.exit(f"Error: {metric} needs the baseline CSV first, then at least "
                 f"one variant CSV (got {len(args.csvs)}).")

    # Resolved before any plotting so a missing/unusable tests CSV fails fast.
    ffi = None
    if args.no_ffi:
        tests_csv = args.tests_csv or find_tests_csv(args.csvs)
        if tests_csv is None:
            sys.exit("Error: --no-ffi could not find a list_tests.sh CSV matching "
                     f"the inputs.\nLooked for tests-<dataset>.csv in {OUTPUTS_DIR} "
                     f"and {os.path.join(REPO_ROOT, 'scripts')}, where <dataset> "
                     "appears in an input\nfilename. Pass --tests-csv FILE.")
        ffi = load_ffi(tests_csv)
        print(f"FFI status from {tests_csv}: {len(ffi)} crates listed, "
              f"{sum(1 for v in ffi.values() if v == 'true')} with FFI.")
    elif args.tests_csv:
        print("Warning: --tests-csv is only used with --no-ffi; ignoring it.",
              file=sys.stderr)

    # Headless-safe backend; import after so --help works without matplotlib.
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        sys.exit("Error: matplotlib is required (pip install matplotlib).")

    loaded = [load_csv(p) for p in args.csvs]

    # Filename-derived labels are as long as the run name (~90 chars for a
    # -Zmiri-flag sweep); two of those in the legend are wider than the whole
    # canvas, and tight_layout shrinks the axes trying to fit them. Let the
    # caller name the series instead.
    if args.labels is not None:
        if len(args.labels) != len(loaded):
            sys.exit(f"Error: --labels expects {len(loaded)} value(s) (one per input "
                     f"CSV, baseline included), got {len(args.labels)}.")
        loaded = [(lab, data, kind, stats)
                  for lab, (_, data, kind, stats) in zip(args.labels, loaded)]

    # A hyperfine crate total is the sum of its per-test means, and each of
    # those includes cargo's freshness check plus the startup of every test
    # binary in the crate (see run_bench_dataset.sh) -- so it counts that
    # constant N times for N tests and is NOT comparable to a raw CSV's
    # whole-suite run_seconds. Comparing hyperfine against hyperfine is fine
    # (the constant is in both); mixing the two formats is not.
    kinds = {kind for _, _, kind, _ in loaded}
    if len(kinds) > 1:
        print("Warning: mixing raw and hyperfine CSVs. A hyperfine crate total "
              "sums per-test\n         means, each including per-invocation "
              "cargo + test-binary startup, so it\n         overstates the raw "
              "CSVs' whole-suite run_seconds. Ratios across the\n         two "
              "formats are not meaningful.", file=sys.stderr)
    uncalibrated = []
    for (_, data, kind, stats), path in zip(loaded, args.csvs):
        if kind != "hyperfine":
            continue
        n_tests = sum(row["passed"] for row in data.values())
        note = ""
        if stats["calibrated"]:
            note = (f", net of per-crate calibration "
                    f"({stats['calibrated']} crates calibrated")
            if stats["zeroed_tests"]:
                note += f", {stats['zeroed_tests']} at/below it"
            note += ")"
        else:
            uncalibrated.append(path)
        print(f"Aggregated {path}: {n_tests} benchmarked tests summed into "
              f"{len(data)} crates{note}.")
        if stats["dropped_crates"]:
            print(f"  {len(stats['dropped_crates'])} crate(s) had no test above "
                  f"their calibration and were dropped: "
                  f"{', '.join(sorted(stats['dropped_crates'])[:6])}"
                  f"{' ...' if len(stats['dropped_crates']) > 6 else ''}")
    if uncalibrated:
        print("Warning: no calibration rows in "
              f"{', '.join(os.path.basename(p) for p in uncalibrated)} -- summed "
              "raw, so\n         these totals still carry per-invocation cargo + "
              "test-binary startup\n         (re-run run_bench_dataset.sh to "
              "measure it). Do not compare them against\n         calibrated "
              "totals.", file=sys.stderr)

    if spec["has_baseline"]:
        (baseline_label, baseline_data, _, _), series = loaded[0], loaded[1:]
    else:
        baseline_label, baseline_data, series = None, None, loaded

    # Number apart any variants sharing a `build` name so the legend (and the
    # averages below) can tell them apart.
    series = [(label, data) for label, (_, data, _k, _s)
              in zip(disambiguate([lbl for lbl, _, _, _ in series]), series)]

    color_indices = None
    if args.cmap_indices is not None:
        color_indices = list(args.cmap_indices)
        if spec["has_baseline"] and len(color_indices) == len(args.csvs):
            # overhead/speedup baseline is not plotted, so ignore its color.
            color_indices = color_indices[1:]
        if len(color_indices) != len(series):
            if spec["has_baseline"]:
                expect = f"{len(series)} (variants) or {len(args.csvs)} (all CSVs incl. baseline)"
            else:
                expect = str(len(series))
            sys.exit(f"Error: --cmap-indices expects {expect} value(s), got "
                     f"{len(args.cmap_indices)}.")

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

    def has_data(crate):
        for _, data in series:
            row = data.get(crate)
            if row is None or value(crate, row) is None:
                return False
            if check_passed and not passed_ok(row):
                return False
        return True

    # Inputs the passed-count comparison spans: every plotted series plus the
    # baseline when there is one, since the baseline's runtime is half of every
    # ratio and a crate that ran a different number of tests there is just as
    # incomparable.
    counted = ([(baseline_label, baseline_data)] if baseline_data is not None
               else []) + series

    def passed_counts(crate):
        return [(label, passed_count(data.get(crate) or {}))
                for label, data in counted]

    def passed_fractions(crate):
        return [(label, passed_fraction(data.get(crate) or {}))
                for label, data in counted]

    def clean_everywhere(crate):
        """True when every input ran the crate with every test passing. An
        input that cannot report its counts (None) is treated as failing: it
        cannot be shown clean, and both CSV formats carry the columns."""
        return all(all_passed(data.get(crate) or {}) is True
                   for _, data in counted)

    def passed_agrees(crate):
        """True when every input reports the same passed test count. Only used
        under --require-equal-passed: all-passing does not imply equal counts,
        since an input can compile out or ignore tests the others ran."""
        counts = [n for _, n in passed_counts(crate)]
        return None not in counts and len(set(counts)) == 1

    # Every crate seen in any input, and the subset with usable data across all
    # of them, ordered by the first plotted series ascending. Crates that have
    # the data but disagree on the passed count are held back separately so they
    # can be reported with their counts.
    all_crates = set(baseline_data or {})
    for _, data in series:
        all_crates |= set(data)
    usable = [c for c in all_crates if has_data(c)]
    skipped = len(all_crates) - len(usable)

    # --no-ffi narrows the crate set before the passed-count check, so the
    # mismatch table below doesn't list crates that are out of scope anyway.
    # An unknown status (scan_failed, or no row at all in the tests CSV) is not
    # "no FFI" and is excluded too, but reported apart from the confirmed ones.
    if ffi is not None:
        with_ffi = sorted(c for c in usable if ffi.get(c) == "true")
        unknown = sorted(c for c in usable if ffi.get(c) not in ("true", "false"))
        usable = [c for c in usable if ffi.get(c) == "false"]
        for names, what in ((with_ffi, "contain FFI"),
                            (unknown, "have an unknown FFI status "
                                      "(scan_failed, or no row in the tests CSV)")):
            if names:
                print(f"\n--no-ffi excluded {len(names)} crate(s) that {what}:")
                print("  " + ", ".join(names))
        if with_ffi or unknown:
            print()

    # --min-seconds runs before the pass filter, so the exclusion table below
    # doesn't list crates that are out of scope anyway.
    #
    # The cut is applied to EVERY input (the baseline included), not just the
    # first, and deliberately so. Cutting on one input conditions the comparison
    # on that arm: the kept crates are the ones where it happened to be large,
    # which biases every ratio involving it upward (regression to the mean). On
    # this dataset that was worth a 3.5x swing in the geometric mean depending
    # only on which csv was listed first. Requiring all inputs above the cut is
    # symmetric, so no arm is privileged and reordering the arguments cannot
    # change the result. It is also the stricter rule -- for overhead/speedup,
    # where the baseline is the fastest arm by construction, the two coincide.
    if args.min_seconds is not None:
        # --min-seconds-only-first narrows the cut back to one arm; the table
        # below still shows every input, so the asymmetry stays visible.
        # Indices, not labels: the baseline shares disambiguate()'s namespace
        # with the variants but not its numbering, so labels can collide.
        cut_on = [0] if args.min_seconds_only_first else list(range(len(counted)))

        def input_secs(crate):
            return [(label, run_seconds(data.get(crate) or {}) or 0.0)
                    for label, data in counted]

        def worst_secs(crate):
            secs = input_secs(crate)
            return min(secs[i][1] for i in cut_on)

        too_small = sorted((c for c in usable if worst_secs(c) < args.min_seconds),
                           key=lambda c: -worst_secs(c))
        if too_small:
            small = set(too_small)
            usable = [c for c in usable if c not in small]
            labels = [label for label, _ in counted]
            cw = max(max(len(c) for c in too_small), len("crate")) + 2
            widths = [max(len(lab), 9) + 2 for lab in labels]
            if args.min_seconds_only_first:
                scope = (f"crate(s) measuring under that in {counted[0][0]}\n"
                         f"(--min-seconds-only-first: the cut is on that arm alone, "
                         f"so the selection depends on argument order and every "
                         f"ratio involving it is biased upward). Seconds per input, "
                         f"* marks the ones below the cut:")
            else:
                scope = ("crate(s) measuring under that in at least one input\n"
                         "(the cut applies to every input, so argument order cannot "
                         "change the selection). Seconds per input, * marks the ones "
                         "below the cut:")
            print(f"\n--min-seconds {args.min_seconds:g} excluded {len(too_small)} "
                  + scope)
            print("crate".ljust(cw)
                  + "".join(f"{lab:>{w}}" for lab, w in zip(labels, widths)))
            for crate in too_small:
                cells = "".join(
                    f"{f'{v:.3f}' + ('*' if v < args.min_seconds else ''):>{w}}"
                    for (_, v), w in zip(input_secs(crate), widths))
                print(crate.ljust(cw) + cells)
            print()

    def selected(crate):
        if not args.allow_failures and not clean_everywhere(crate):
            return False
        if args.require_equal_passed and not passed_agrees(crate):
            return False
        return True

    kept = [c for c in usable if selected(c)]
    excluded = sorted(c for c in usable if not selected(c))
    first_data = series[0][1]
    crates = sorted(kept, key=lambda c: value(c, first_data[c]))

    if excluded:
        labels = [label for label, _ in counted]
        cw = max(max(len(c) for c in excluded), len("crate")) + 2
        widths = [max(len(lab), 9) + 2 for lab in labels]
        why = "not every test passed in every input"
        if args.allow_failures:
            why = "the inputs disagree on how many tests passed"
        elif args.require_equal_passed:
            why += ", or the counts differ between inputs"
        print(f"\n{len(excluded)} crate(s) excluded: {why}, so their runtimes are "
              f"not\nthe same workload (plot them anyway with --allow-failures). "
              f"Columns are passed/tests:")
        print("crate".ljust(cw)
              + "".join(f"{lab:>{w}}" for lab, w in zip(labels, widths)))
        for crate in excluded:
            cells = "".join(f"{frac:>{w}}"
                            for (_, frac), w in zip(passed_fractions(crate), widths))
            print(crate.ljust(cw) + cells)
        print()

    if not crates:
        sys.exit(f"Error: no crate has a usable {metric} value"
                 f"{' and a passing test' if check_passed else ''}, with a "
                 f"matching passed test count, across every input CSV.")

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
        ci = color_indices[i] if color_indices is not None else i
        ax.plot(xs, ys, marker="o", ms=3, lw=0.8, alpha=0.8,
            color=cmap(ci % cmap.N), label=label)

    if metric == "speedup":
        ax.axhline(1.0, ls="--", color="0.4", lw=1)
    # Values span orders of magnitude across crates (and ratios are
    # multiplicative); log y keeps the small ones readable next to the
    # extreme ones.
    ax.set_yscale("log")
    ax.set_xticks(list(xs_all))
    ax.set_xticklabels(crates, rotation=90, fontsize=5)
    ax.set_xlim(-1, len(crates))
    ax.set_xlabel(f"Crate  (Ordered by {series[0][0]}, ascending)", fontsize=12)
    ax.set_ylabel(spec["ylabel"].format(baseline=baseline_label),fontsize=12)
    ax.set_title(f"{spec['title']}"
                 f"{', no FFI' if args.no_ffi else ''}"
                 #f"{f', >={args.min_seconds:g}s' if args.min_seconds is not None else ''})"
                , fontsize=14)
    ax.grid(True, axis="y", ls=":", alpha=0.4)
    ax.legend(loc="upper left", fontsize=12, ncol=2, framealpha=0.9)
    fig.tight_layout()

    os.makedirs(args.output_dir, exist_ok=True)
    # The _no_ffi / _min<N>s suffixes keep a filtered plot from overwriting the
    # full one. The float is rendered with 'p' for the point so the name stays
    # one extension-free token (0.5 -> _min0p5s).
    tag = "_no_ffi" if args.no_ffi else ""
    if args.min_seconds is not None:
        tag += "_min" + f"{args.min_seconds:g}".replace(".", "p") + "s"
        if args.min_seconds_only_first:
            tag += "_first"
    out = os.path.join(args.output_dir,
                       f"{metric}_by_crate{tag}.{args.format}")
    fig.savefig(out, dpi=args.dpi)
    plt.close(fig)

    print(f"Plotted {len(series)} series over {len(crates)} crates "
          f"({skipped} crates lacked a usable {metric} value"
          f"{' or a passing test' if check_passed else ''} "
          f"under some input CSV and were skipped"
          f"{f'; {len(excluded)} more had failing tests' if excluded else ''}).")
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
