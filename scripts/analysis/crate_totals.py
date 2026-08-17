#!/usr/bin/env python3
"""Per-crate total measured time from a merged-hyperfine CSV.

Usage: crate_totals.py [-o OUT.csv] <merged-hyperfine.csv>

Reads the wide CSV that merge_hyperfine.py writes -- one row per (crate, test)
with a <label>_status/<label>_mean_s/... group per input -- and collapses it to
one row per crate:

    crate,<label>_total_s,<label>_n,...

<label>_total_s is the sum of mean_s over that label's success rows (the same
number merge_hyperfine.py prints to stderr) and <label>_n is how many rows went
into it. total_s is empty where a label has no success rows for the crate.

Crates are sorted by their largest total across labels, descending. The CSV goes
to stdout (or -o FILE); grand totals go to stderr.
"""
import argparse
import csv
import sys
from collections import defaultdict

ap = argparse.ArgumentParser()
ap.add_argument("-o", "--output", help="write the totals CSV here (default: stdout)")
ap.add_argument("csv", help="a merged CSV from merge_hyperfine.py")
args = ap.parse_args()

totals = defaultdict(lambda: defaultdict(float))   # label -> crate -> seconds
counts = defaultdict(lambda: defaultdict(int))     # label -> crate -> rows

with open(args.csv, newline="") as f:
    reader = csv.DictReader(f)
    labels = [c.removesuffix("_mean_s") for c in (reader.fieldnames or [])
              if c.endswith("_mean_s")]
    if not labels:
        sys.exit(f"Error: no *_mean_s columns in {args.csv} -- not a merged CSV?")
    crates = []
    seen = set()
    for r in reader:
        crate = r["crate"]
        if crate not in seen:
            seen.add(crate)
            crates.append(crate)
        for lab in labels:
            mean = r.get(f"{lab}_mean_s")
            if r.get(f"{lab}_status") == "success" and mean:
                totals[lab][crate] += float(mean)
                counts[lab][crate] += 1

crates.sort(key=lambda c: -max(totals[lab][c] for lab in labels))

out = open(args.output, "w", newline="") if args.output else sys.stdout
w = csv.writer(out)
w.writerow(["crate"] + [f"{lab}_{f}" for lab in labels for f in ("total_s", "n")])
for crate in crates:
    row = [crate]
    for lab in labels:
        n = counts[lab][crate]
        row += [f"{totals[lab][crate]:.6f}" if n else "", n]
    w.writerow(row)
if args.output:
    out.close()

err = sys.stderr
err.write(f"{len(crates)} crates, labels: {', '.join(labels)}\n")
cw = max(len(lab) for lab in labels) + 2
for lab in labels:
    err.write(f"{lab.ljust(cw)}{sum(totals[lab].values()):12.1f}s total"
              f"  ({sum(counts[lab].values())} success rows"
              f" across {sum(1 for c in crates if counts[lab][c])} crates)\n")
