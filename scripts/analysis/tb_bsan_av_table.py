#!/usr/bin/env python3
"""BorrowSanitizer aliasing violations that Miri Tree Borrows also reports, or
can't run for FFI, as a LaTeX table.

Usage: tb_bsan_av_table.py [--report CSV] <log-output-dir>

    tb_bsan_av_table.py ../../log-output-tree-borrows-15416a0f...

Takes the BSan rows of --report (default <repo>/outputs/tb-bsan-report.csv,
as written by bug_report.py) at the crate version the Miri Tree Borrows run
tested (the <name>@<version>/ directories in <log-output-dir>) and counts
tests by BSan's aliasing type (row) and Miri's result for the same test
(column), as in tb_bsan_matrix.py:

  Fail-FFI          Miri failed with "can't call foreign function"
  AV-Inv./Ins./P    Miri's aliasing type

Only those cells are counted: tests with any other Miri result (pass, other
UB or failures, timeout, not built or run) or a non-aliasing BSan error are
left out and tallied on stderr. tb_bsan_matrix.py has the full comparison.

Requirements: python3 >= 3.6 (stdlib).
"""
import argparse
import collections
import csv
import os
import sys

import tb_bsan_matrix as tm

MIRI = ["Unsup.-FFI"] + tm.AVS
HEADER = {"Unsup.-FFI": "Fail-FFI", "AV-Inv.": "Invalid", "AV-Ins.": "Insufficient",
          "AV-P": "Protected"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--report", default=os.path.join(tm.ROOT, "outputs", "tb-bsan-report.csv"))
    ap.add_argument("logdir", help="log-output-tree-borrows-* directory")
    args = ap.parse_args()

    csv.field_size_limit(sys.maxsize)
    version = dict(n.rsplit("@", 1) for n in os.listdir(args.logdir) if "@" in n)
    with open(args.report, encoding="utf-8-sig", newline="") as f:
        rows = [r for r in csv.DictReader(f) if version.get(r["crate"]) == r["version"]]
    miri = dict(tm.miri_crate((args.logdir, f"{c}@{version[c]}"))
                for c in {r["crate"] for r in rows})

    counts, skipped = collections.Counter(), collections.Counter()
    for r in rows:
        b = tm.AV.get(r["error type"])
        if b is None:
            skipped["BSan " + r["error type"]] += 1
            continue
        m = "Not built" if miri[r["crate"]] is None else miri[r["crate"]].get(r["test"], "Not run")
        if m in MIRI:
            counts[b, m] += 1
        else:
            skipped["Miri " + m] += 1

    # shade the Fail-FFI column (needs \usepackage[table]{xcolor})
    print(r"""\begin{tabular}{@{}l >{\columncolor{gray!15}}r rrr @{\hspace{12pt}}r@{}}
    \toprule
    & \multicolumn{4}{c}{Miri (TB)} & \\
    \cmidrule(lr){2-5}
    \toolshort{} & """ + " & ".join(HEADER[m] for m in MIRI) + r""" & $\Sigma$ \\
    \midrule""")
    for b in tm.AVS:
        v = [counts[b, m] for m in MIRI]
        print(f"    {b:8} & " + " & ".join(map(str, v)) + f" & {sum(v)} \\\\")
    v = [sum(counts[b, m] for b in tm.AVS) for m in MIRI]
    print(r"    \midrule")
    print("    " + r"$\Sigma$".ljust(8) + " & " + " & ".join(map(str, v)) + f" & {sum(v)} \\\\")
    print(r"""    \bottomrule
  \end{tabular}""")
    print("left out:", file=sys.stderr)
    for k, n in skipped.most_common():
        print(f"  {n:6}  {k}", file=sys.stderr)


if __name__ == "__main__":
    main()
