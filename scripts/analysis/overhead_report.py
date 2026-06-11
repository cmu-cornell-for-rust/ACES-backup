#!/usr/bin/env python3
"""
Usage: overhead_report.py <dataset> [output.csv]

Combines the per-image result CSVs for one dataset
(<OUTPUTS_DIR>/<image>-<dataset>.csv) into a single overhead report.

Baselines (always required):
  rust-<dataset>.csv        plain `cargo test` runtimes
  base-miri-<dataset>.csv   stock Miri runtimes

Only crates whose status is `success` in BOTH baselines are kept.

Every other <image>-<dataset>.csv found in the outputs dir is treated as an
extra Miri edition and gets three columns (blank where that edition did not
succeed on the crate):
  <image>_seconds    its run_seconds
  <image>_speedup    base-miri seconds / <image> seconds   (>1 = faster than stock Miri)
  <image>_overhead   <image> seconds / rust seconds        (its slowdown vs native)

Output is written to <outputs dir>/analysis/overhead-<dataset>.csv unless an
explicit output path is given. The outputs dir defaults to <repo root>/outputs,
found relative to this script (so it works both locally and on the cluster);
override with $OUTPUTS_DIR.
"""

import csv
import os
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUTPUTS_DIR = os.environ.get("OUTPUTS_DIR", os.path.join(REPO_ROOT, "outputs"))


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

    # Keep only crates that succeeded under both rust and base-miri.
    crates = sorted(
        crate
        for crate, (status, _) in rust.items()
        if status == "success" and base.get(crate, ("", 0))[0] == "success"
    )

    header = ["crate", "rust_seconds", "base_miri_seconds", "base_miri_overhead"]
    for e in editions:
        header += [f"{e}_seconds", f"{e}_speedup", f"{e}_overhead"]

    if len(sys.argv) == 3:
        out_path = sys.argv[2]
    else:
        out_path = os.path.join(OUTPUTS_DIR, "analysis", f"overhead-{dataset}.csv")
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    out = open(out_path, "w", newline="")
    writer = csv.writer(out)
    writer.writerow(header)
    for crate in crates:
        rust_s = rust[crate][1]
        base_s = base[crate][1]
        row = [
            crate,
            f"{rust_s:.3f}",
            f"{base_s:.3f}",
            f"{base_s / rust_s:.3f}" if rust_s > 0 else "",
        ]
        for e in editions:
            status, secs = edition_results[e].get(crate, ("", 0.0))
            if status == "success":
                row += [
                    f"{secs:.3f}",
                    f"{base_s / secs:.3f}" if secs > 0 else "",
                    f"{secs / rust_s:.3f}" if rust_s > 0 else "",
                ]
            else:
                row += ["", "", ""]
        writer.writerow(row)
    out.close()
    print(f"Wrote {len(crates)} crates to {out_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
