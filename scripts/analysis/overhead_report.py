#!/usr/bin/env python3
"""
Usage: overhead_report.py <dataset> [output.csv]

Combines the per-image result CSVs for one dataset
(<OUTPUTS_DIR>/<image>-<dataset>.csv) into a single overhead report.

Baselines (always required):
  rust-<dataset>.csv        plain `cargo test` runtimes
  miri-<dataset>.csv        stock Miri runtimes (falls back to the older
                            base-miri-<dataset>.csv name if miri- is absent)

Every crate seen in ANY result file is included, regardless of outcome.
Each build contributes a <build>_status column (its recorded status, or
`absent` when the crate never appears in that build's CSV) so a failure is
always distinguishable from a missing run. <build>_seconds and the ratio
columns are filled wherever the test binary actually ran (status `success` or
`test_failed`, since a failing test still compiled and executed and its timing
is valid); they are blank only for build/fetch failures and absent runs.

The two baselines get:
  rust_status / rust_seconds
  base_miri_status / base_miri_seconds / base_miri_overhead

Every other <image>-<dataset>.csv found in the outputs dir is treated as an
extra Miri edition and gets:
  <image>_status    its recorded status (or `absent`)
  <image>_seconds   its run_seconds (success only)
  <image>_speedup   stock-Miri seconds / <image> seconds  (>1 = faster than stock Miri)
  <image>_overhead  <image> seconds / rust seconds        (its slowdown vs native)

Any build whose result CSV carries `tests`/`passed` columns also gets
<build>_tests and <build>_passed (the raw test counts from its last row);
builds without those columns omit them.

Output is always written to <outputs dir>/analysis/. By default the file is
overhead-<dataset>.csv; passing an explicit name uses that name (its basename,
with a .csv extension forced) within that same directory. The outputs dir
defaults to <repo root>/outputs, found relative to this script (so it works
both locally and on the cluster); override with $OUTPUTS_DIR.
"""

import csv
import os
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUTPUTS_DIR = os.environ.get("OUTPUTS_DIR", os.path.join(REPO_ROOT, "outputs"))


# Statuses where the test binary actually ran, so run_seconds is meaningful.
# A failing test still compiled and executed under the build, so its timing
# is valid for overhead; only build/fetch failures (0.000s) have no run.
RAN_STATUSES = ("success", "test_failed")


def ran(status):
    return status in RAN_STATUSES


def load_results(path):
    """Map crate -> (status, run_seconds, tests, passed), last row per crate
    winning (result files are append-only, so re-runs supersede earlier rows).
    `tests`/`passed` are the raw strings (or "" when the column is absent);
    the second return value flags whether this CSV carries those columns."""
    results = {}
    has_counts = False
    with open(path, newline="") as f:
        reader = csv.DictReader(f)
        has_counts = reader.fieldnames is not None and (
            "tests" in reader.fieldnames and "passed" in reader.fieldnames
        )
        for row in reader:
            results[row["crate"]] = (
                row["status"],
                float(row["run_seconds"]),
                row.get("tests", "") or "",
                row.get("passed", "") or "",
            )
    return results, has_counts


def main():
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__.strip())
    dataset = sys.argv[1]

    def csv_path(image):
        return os.path.join(OUTPUTS_DIR, f"{image}-{dataset}.csv")

    # Stock-Miri baseline: the unified miri.def builds the default branch as
    # plain `miri`; older sweeps recorded it as `base-miri`. Prefer the new
    # name, fall back to the old one. (Report columns stay base_miri_* either
    # way -- plot_speedup_by_crate.py depends on them.)
    STOCK_MIRI_NAMES = ("miri", "base-miri")
    stock_miri = next(
        (i for i in STOCK_MIRI_NAMES if os.path.isfile(csv_path(i))), None
    )
    if not os.path.isfile(csv_path("rust")):
        sys.exit(f"Error: missing baseline {csv_path('rust')}")
    if stock_miri is None:
        sys.exit(f"Error: missing baseline {csv_path('miri')} (or base-miri-)")

    rust, rust_counts = load_results(csv_path("rust"))
    base, base_counts = load_results(csv_path(stock_miri))

    # Any other <image>-<dataset>.csv in the outputs dir is an extra edition.
    baselines = ("rust",) + STOCK_MIRI_NAMES
    suffix = f"-{dataset}.csv"
    editions = sorted(
        name[: -len(suffix)]
        for name in os.listdir(OUTPUTS_DIR)
        if name.endswith(suffix) and name[: -len(suffix)] not in baselines
    )
    loaded = {e: load_results(csv_path(e)) for e in editions}
    edition_results = {e: res for e, (res, _) in loaded.items()}
    edition_counts = {e: counts for e, (_, counts) in loaded.items()}

    # All crates seen in any result file, regardless of outcome.
    all_crates = set(rust) | set(base)
    for e_results in edition_results.values():
        all_crates |= set(e_results)
    crates = sorted(all_crates)

    header = ["crate", "rust_status", "rust_seconds"]
    if rust_counts:
        header += ["rust_tests", "rust_passed"]
    header += ["base_miri_status", "base_miri_seconds", "base_miri_overhead"]
    if base_counts:
        header += ["base_miri_tests", "base_miri_passed"]
    for e in editions:
        header += [f"{e}_status", f"{e}_seconds", f"{e}_speedup", f"{e}_overhead"]
        if edition_counts[e]:
            header += [f"{e}_tests", f"{e}_passed"]

    analysis_dir = os.path.join(OUTPUTS_DIR, "analysis")
    if len(sys.argv) == 3:
        name = os.path.basename(sys.argv[2])
        if not name.endswith(".csv"):
            name += ".csv"
    else:
        name = f"overhead-{dataset}.csv"
    out_path = os.path.join(analysis_dir, name)
    os.makedirs(analysis_dir, exist_ok=True)
    out = open(out_path, "w", newline="")
    writer = csv.writer(out)
    writer.writerow(header)
    for crate in crates:
        rust_status, rust_s, rust_tests, rust_passed = rust.get(
            crate, ("absent", 0.0, "", "")
        )
        base_status, base_s, base_tests, base_passed = base.get(
            crate, ("absent", 0.0, "", "")
        )
        rust_ok = ran(rust_status)
        base_ok = ran(base_status)
        row = [
            crate,
            rust_status,
            f"{rust_s:.3f}" if rust_ok else "",
        ]
        if rust_counts:
            row += [rust_tests, rust_passed]
        row += [
            base_status,
            f"{base_s:.3f}" if base_ok else "",
            f"{base_s / rust_s:.3f}" if rust_ok and base_ok and rust_s > 0 else "",
        ]
        if base_counts:
            row += [base_tests, base_passed]
        for e in editions:
            status, secs, tests, passed = edition_results[e].get(
                crate, ("absent", 0.0, "", "")
            )
            ok = ran(status)
            row += [
                status,
                f"{secs:.3f}" if ok else "",
                f"{base_s / secs:.3f}" if ok and base_ok and secs > 0 else "",
                f"{secs / rust_s:.3f}" if ok and rust_ok and rust_s > 0 else "",
            ]
            if edition_counts[e]:
                row += [tests, passed]
        writer.writerow(row)
    out.close()
    print(f"Wrote {len(crates)} crates to {out_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
