#!/usr/bin/env python3
"""CSV of the log output behind every failing row of a hyperfine run.

Usage: failure_logs.py [-o OUT.csv] [--datasets-dir DIR] [--dataset NAME]
                       [--status S,...] [--max-lines N] <hyperfine.csv>

For each crate with a failing row in a *-hyperfine.csv (as written by
run_bench_dataset.sh), reads that crate's log(s) from the dataset dir --
<datasets>/<dataset>/<crate>/hyperfine-<build>.log, plus the
hyperfine-<build>-part<N>.log files of split slowlist crates -- and pulls out
the output for each failure:

  test_failed, no_match, timeout
      the block between "--- output: <crate> :: <test> ..." and
      "--- end output: <crate> :: <test> ---" (the pre-run's last 200 lines).
  bench_failed
      no output block is written for these, so the log lines between the
      previous "result:"/"calibration:" line and this test's
      "result: <crate> :: <test> -> bench_failed" line (hyperfine's error).
  build_failed, fetch_failed
      the last --max-lines lines of the log (cargo's error).

The dataset defaults to the part of the file name before "-hyperfine.csv"
after the last "-" (e.g. bsan-top_500-hyperfine.csv -> top_500), and <build>
is the CSV's build column (the image name). Crate logs are overwritten by each
run of the same image, so a log from a later run may not hold a given failure;
such rows get log_found=false / output_found=false instead of being dropped.

error_type classifies the extracted output, first match winning:
  rustc   error[E<code>]
  linker  rust-lld
  oom     SIGKILL
  gc      ERROR: BorrowSanitizer: garbage collection
  crash   BorrowSanitizer:DEADLYSIGNAL
  bsan    error: Undefined Behavior:
and "other" when none match ("" when no output was found).

Output columns: build,crate,test,status,error_type,log_file,log_found,
output_found,exit_code,output. The CSV goes to stdout (or -o FILE); a summary to stderr.
"""
import argparse
import csv
import glob
import os
import re
import sys

DEFAULT_DATASETS = "/scratch/group/p.cis260229.000/datasets"
DEFAULT_STATUS = "test_failed,no_match,timeout,bench_failed,build_failed,fetch_failed"
CRATE_FAILURES = {"build_failed", "fetch_failed"}

ap = argparse.ArgumentParser()
ap.add_argument("-o", "--output", help="write the CSV here (default: stdout)")
ap.add_argument("--datasets-dir", default=DEFAULT_DATASETS,
                help=f"root holding the dataset folders (default: {DEFAULT_DATASETS})")
ap.add_argument("--dataset", help="dataset folder name (default: inferred from the file name)")
ap.add_argument("--status", default=DEFAULT_STATUS,
                help=f"comma-separated statuses to pull logs for (default: {DEFAULT_STATUS})")
ap.add_argument("--max-lines", type=int, default=200,
                help="lines kept from the log tail for build/fetch failures (default: 200)")
ap.add_argument("-q", "--quiet", action="store_true", help="no stderr summary")
ap.add_argument("hyperfine_csv", help="a *-hyperfine.csv from run_bench_dataset.sh")
args = ap.parse_args()

statuses = {s.strip() for s in args.status.split(",") if s.strip()}

dataset = args.dataset
if not dataset:
    base = os.path.basename(args.hyperfine_csv)
    if not base.endswith("-hyperfine.csv"):
        sys.exit(f"Error: cannot infer the dataset from {base!r}; pass --dataset.")
    dataset = base[: -len("-hyperfine.csv")].rsplit("-", 1)[-1]
dataset_dir = os.path.join(args.datasets_dir, dataset)
if not os.path.isdir(dataset_dir):
    sys.exit(f"Error: dataset dir {dataset_dir} not found (see --datasets-dir/--dataset).")

with open(args.hyperfine_csv, newline="") as f:
    failures = [r for r in csv.DictReader(f) if r["status"] in statuses]


def crate_logs(crate, build):
    """The crate's log files for this build, the unsplit one first."""
    cdir = os.path.join(dataset_dir, crate)
    main = os.path.join(cdir, f"hyperfine-{build}.log")
    parts = sorted(glob.glob(os.path.join(cdir, f"hyperfine-{glob.escape(build)}-part*.log")))
    return [p for p in [main] + parts if os.path.isfile(p)]


_log_cache = {}

ERROR_TYPES = [
    ("rustc", re.compile(r"error\[E\d+\]")),
    ("linker", re.compile(re.escape("rust-lld"))),
    ("oom", re.compile(re.escape("SIGKILL"))),
    ("gc", re.compile(re.escape("ERROR: BorrowSanitizer: garbage collection"))),
    ("crash", re.compile(re.escape("BorrowSanitizer:DEADLYSIGNAL"))),
    ("bsan", re.compile(re.escape("error: Undefined Behavior:"))),
]


def error_type(text):
    for name, pat in ERROR_TYPES:
        if pat.search(text):
            return name
    return "other"


def read_lines(path):
    if path not in _log_cache:
        with open(path, errors="replace") as f:
            _log_cache[path] = f.read().splitlines()
    return _log_cache[path]


def output_block(lines, crate, test):
    """(exit code, text) of the test's "--- output:" block, or None."""
    start = f"--- output: {crate} :: {test} ("
    end = f"--- end output: {crate} :: {test} ---"
    for i, line in enumerate(lines):
        if line.startswith(start):
            m = re.search(r"\(exit (\d+),", line)
            body = []
            for line2 in lines[i + 1:]:
                if line2 == end:
                    break
                body.append(line2)
            return (m.group(1) if m else ""), "\n".join(body)
    return None


def bench_failed_block(lines, crate, test):
    """Lines leading up to the test's bench_failed result line, or None."""
    target = f"result: {crate} :: {test} -> bench_failed"
    for i, line in enumerate(lines):
        if line == target:
            j = i
            while j > 0 and not lines[j - 1].startswith(("result: ", "calibration: ")):
                j -= 1
            return "", "\n".join(lines[j:i])
    return None


out = open(args.output, "w", newline="") if args.output else sys.stdout
w = csv.writer(out)
w.writerow(["build", "crate", "test", "status", "error_type", "log_file", "log_found",
            "output_found", "exit_code", "output"])

n_found = 0
crates = set()
for r in failures:
    crate, test, status, build = r["crate"], r["test"], r["status"], r["build"]
    crates.add(crate)
    logs = crate_logs(crate, build)
    hit = None
    for path in logs:
        lines = read_lines(path)
        if status in CRATE_FAILURES:
            res = ("", "\n".join(lines[-args.max_lines:]))
        elif status == "bench_failed":
            res = bench_failed_block(lines, crate, test)
        else:
            res = output_block(lines, crate, test)
        if res is not None:
            hit = (path, *res)
            break
    if hit:
        n_found += 1
        path, code, text = hit
        w.writerow([build, crate, test, status, error_type(text), path,
                    "true", "true", code, text])
    else:
        w.writerow([build, crate, test, status, "", logs[0] if logs else "",
                    "true" if logs else "false", "false", "", ""])

if args.output:
    out.close()
if not args.quiet:
    print(f"{len(failures)} failing row(s) across {len(crates)} crate(s); "
          f"output found for {n_found}, missing for {len(failures) - n_found}.",
          file=sys.stderr)
