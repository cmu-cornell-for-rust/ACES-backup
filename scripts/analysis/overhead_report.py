#!/usr/bin/env python3
"""
Usage: overhead_report.py <dataset> [output.csv]

Combines the per-image result CSVs for one dataset
(<OUTPUTS_DIR>/<image>-<dataset>.csv) into a single overhead report.

Baselines (always required):
  rust-<dataset>.csv        plain `cargo test` runtimes
  base-miri-<dataset>.csv   stock Miri runtimes

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
  <image>_speedup   base-miri seconds / <image> seconds   (>1 = faster than stock Miri)
  <image>_overhead  <image> seconds / rust seconds        (its slowdown vs native)

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
    """Map crate -> (status, run_seconds), last row per crate winning
    (result files are append-only, so re-runs supersede earlier rows)."""
    results = {}
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            results[row["crate"]] = (row["status"], float(row["run_seconds"]))
    return results


def main():
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__.strip())
    dataset = sys.argv[1]

    def csv_path(image):
        return os.path.join(OUTPUTS_DIR, f"{image}-{dataset}.csv")

    for image in ("rust", "base-miri"):
        if not os.path.isfile(csv_path(image)):
            sys.exit(f"Error: missing baseline {csv_path(image)}")

    rust = load_results(csv_path("rust"))
    base = load_results(csv_path("base-miri"))

    # Any other <image>-<dataset>.csv in the outputs dir is an extra edition.
    suffix = f"-{dataset}.csv"
    editions = sorted(
        name[: -len(suffix)]
        for name in os.listdir(OUTPUTS_DIR)
        if name.endswith(suffix) and name[: -len(suffix)] not in ("rust", "base-miri")
    )
    edition_results = {e: load_results(csv_path(e)) for e in editions}

    # All crates seen in any result file, regardless of outcome.
    all_crates = set(rust) | set(base)
    for e_results in edition_results.values():
        all_crates |= set(e_results)
    crates = sorted(all_crates)

    header = [
        "crate",
        "rust_status",
        "rust_seconds",
        "base_miri_status",
        "base_miri_seconds",
        "base_miri_overhead",
    ]
    for e in editions:
        header += [f"{e}_status", f"{e}_seconds", f"{e}_speedup", f"{e}_overhead"]

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
        rust_status, rust_s = rust.get(crate, ("absent", 0.0))
        base_status, base_s = base.get(crate, ("absent", 0.0))
        rust_ok = ran(rust_status)
        base_ok = ran(base_status)
        row = [
            crate,
            rust_status,
            f"{rust_s:.3f}" if rust_ok else "",
            base_status,
            f"{base_s:.3f}" if base_ok else "",
            f"{base_s / rust_s:.3f}" if rust_ok and base_ok and rust_s > 0 else "",
        ]
        for e in editions:
            status, secs = edition_results[e].get(crate, ("absent", 0.0))
            ok = ran(status)
            row += [
                status,
                f"{secs:.3f}" if ok else "",
                f"{base_s / secs:.3f}" if ok and base_ok and secs > 0 else "",
                f"{secs / rust_s:.3f}" if ok and rust_ok and rust_s > 0 else "",
            ]
        writer.writerow(row)
    out.close()
    print(f"Wrote {len(crates)} crates to {out_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
