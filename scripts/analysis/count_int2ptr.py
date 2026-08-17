#!/usr/bin/env python3
"""Count integer-to-pointer cast sites per crate from Miri run logs.

Usage: count_int2ptr.py [-o OUT.csv] [--log NAME] <dataset-dir | crate-dir | log> ...
       count_int2ptr.py [-o OUT.csv] --dataset top_500_fast

Miri warns on every int-to-ptr cast unless -Zmiri-permissive-provenance is set,
and run_miri_dataset.sh does not set it -- so the <crate>/<image>.log files a
Miri sweep leaves behind already record them. This script pulls the sites out.

Two diagnostic forms are recognised, so the same script works for a default run
and for a -Zmiri-strict-provenance one:

    warning: integer-to-pointer cast                       (default: a warning)
        --> src/lib.rs:42:13

    error: unsupported operation: integer-to-pointer casts and
    `ptr::with_exposed_provenance` are not supported with
    `-Zmiri-strict-provenance`                        (strict: halts execution)
        --> src/lib.rs:42:13

Both are rustc-style diagnostics whose first `-->` line is the span Miri
reported (Miri sets it from the innermost frame of the *pruned* backtrace, so it
is usually the crate's own source rather than a std internal). That file:line:col
is what gets collected.

Appends nothing and writes one row per crate whose log was found:

    crate,n_sites,n_local,n_warnings,n_strict,sites

  n_sites     distinct file:line:col spans seen in the log
  n_local     of those, the ones that look like the crate's own source -- a
              relative path, i.e. not under a registry/toolchain dir. A crate
              with n_sites > 0 and n_local == 0 does int-to-ptr only through a
              dependency or std.
  n_warnings  raw count of warning diagnostics, before deduplication
  n_strict    count of the strict-provenance hard error (0 for a default run)
  sites       the distinct spans, ';'-joined and sorted

Crates with no log, or a log with no diagnostic, are reported on stderr along
with a per-crate table sorted by n_sites. The CSV goes to stdout (or -o FILE).

Three caveats on reading the numbers:

  * Miri deduplicates the warning per source span within one process (a
    `SpanDedupDiagnostic` in ptr_from_addr_cast), so a span that warned in the
    first test does not warn again later in the same test binary. n_warnings can
    therefore exceed n_sites only because cargo runs each test binary as its own
    process. Per-TEST attribution is impossible from a whole-suite log; for that,
    parse the per-test logs from run_bench_dataset.sh, which invokes each test
    separately with --exact.

  * This counts only sites the tests actually EXECUTED. Unreached casts need a
    static check instead (rustc's implicit_provenance_casts lint, gated on
    #![feature(strict_provenance_lints)]).

  * Miri's tracing mode redirects the run phase's stderr to /dev/null
    (run_miri_dataset.sh), and these diagnostics go to stderr -- so logs from a
    MIRI_TRACING=1 sweep have none of them, and will read as 0 sites rather than
    "not measured".
"""
import argparse
import csv
import os
import re
import sys

GROUP = os.environ.get("GROUP", "/scratch/group/p.cis260229.000")
DATASETS_ROOT = os.environ.get("DATASETS_ROOT", os.path.join(GROUP, "datasets"))

WARN_RE = re.compile(r"^warning: integer-to-pointer cast\s*$")
STRICT_RE = re.compile(r"^error: unsupported operation: integer-to-pointer casts")
SPAN_RE = re.compile(r"^\s*-->\s+(\S+:\d+:\d+)\s*$")

# How far past a diagnostic's title line to look for its `-->` span. It is
# normally the very next line; a couple of lines of slack costs nothing and
# survives a stray line in between.
SPAN_LOOKAHEAD = 4

# A span whose path starts with one of these, or is absolute, is not the crate's
# own source: cargo unpacks dependencies under a registry dir, and std spans come
# out as /rustc/<hash>/library/... .
EXTERNAL_MARKERS = ("/", "~", "..")


def is_local(site):
    """True when a `file:line:col` span looks like the crate's own source. Miri
    prints crate-relative paths for the crate under test and absolute ones for
    registry/toolchain sources, so the leading character is enough. A span that
    could not be parsed ("?") is unknown, which is not local."""
    if site == "?":
        return False
    path = site.rsplit(":", 2)[0]
    return bool(path) and not path.startswith(EXTERNAL_MARKERS)


def scan_log(path):
    """Return (sites, n_warnings, n_strict) for one log file. `sites` is the set
    of distinct `file:line:col` spans; a diagnostic with no span line is recorded
    as "?" so it is still counted."""
    sites = set()
    n_warnings = n_strict = 0
    with open(path, errors="replace") as f:
        lines = f.readlines()
    for i, line in enumerate(lines):
        line = line.rstrip("\n")
        if WARN_RE.match(line):
            n_warnings += 1
        elif STRICT_RE.match(line):
            n_strict += 1
        else:
            continue
        site = "?"
        for follow in lines[i + 1:i + 1 + SPAN_LOOKAHEAD]:
            m = SPAN_RE.match(follow.rstrip("\n"))
            if m:
                site = m.group(1)
                break
        sites.add(site)
    return sites, n_warnings, n_strict


def collect(paths, logname):
    """Expand the command-line paths into [(crate, logfile_or_None)].

    A path is taken as a log file if it is a file, as a crate dir if it holds
    one named `logname`, and otherwise as a dataset dir whose subdirectories are
    crates. A crate dir with no log yields None so the caller can report it.

    The same log reached through two paths (a crate dir given alongside its
    dataset dir) is kept once: scanning it twice would double its warning count.
    """
    found = []
    seen = set()

    def add(crate, log):
        if log is not None:
            real = os.path.realpath(log)
            if real in seen:
                return
            seen.add(real)
        found.append((crate, log))

    for path in paths:
        path = path.rstrip("/")
        if os.path.isfile(path):
            # <dataset>/<crate>/miri.log -- the crate is the parent dir.
            add(os.path.basename(os.path.dirname(os.path.abspath(path))), path)
            continue
        if not os.path.isdir(path):
            sys.exit(f"Error: not a file or directory: {path}")
        own = os.path.join(path, logname)
        if os.path.isfile(own):
            add(os.path.basename(path), own)
            continue
        subs = sorted(d for d in os.listdir(path)
                      if os.path.isdir(os.path.join(path, d)))
        if not subs:
            sys.exit(f"Error: {path} holds no {logname} and has no "
                     f"subdirectories to treat as crates.")
        for crate in subs:
            log = os.path.join(path, crate, logname)
            add(crate, log if os.path.isfile(log) else None)
    return found


def main():
    ap = argparse.ArgumentParser(
        usage=argparse.SUPPRESS, description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("paths", nargs="*", metavar="PATH",
                    help="dataset dirs, crate dirs, or log files")
    ap.add_argument("-o", "--output",
                    help="write the CSV here (default: stdout)")
    ap.add_argument("--log", default="miri.log", metavar="NAME",
                    help="log filename inside each crate dir (default miri.log; "
                         "run_miri_dataset.sh names it <image>.log)")
    ap.add_argument("--dataset", metavar="NAME",
                    help=f"shorthand for the dataset dir {DATASETS_ROOT}/NAME "
                         f"(override the root with $DATASETS_ROOT)")
    args = ap.parse_args()

    paths = list(args.paths)
    if args.dataset:
        paths.append(os.path.join(DATASETS_ROOT, args.dataset))
    if not paths:
        ap.error("give at least one PATH, or --dataset NAME")

    entries = collect(paths, args.log)
    if not entries:
        sys.exit("Error: no crates found under the given paths.")

    rows = []
    missing = []
    for crate, log in entries:
        if log is None:
            missing.append(crate)
            continue
        sites, n_warnings, n_strict = scan_log(log)
        rows.append({
            "crate": crate,
            "sites": sorted(sites),
            "n_warnings": n_warnings,
            "n_strict": n_strict,
        })

    # Deduplicate crates seen more than once (the same crate reached through two
    # given paths), merging their sites rather than emitting two rows.
    merged = {}
    for row in rows:
        prev = merged.get(row["crate"])
        if prev is None:
            merged[row["crate"]] = row
            continue
        prev["sites"] = sorted(set(prev["sites"]) | set(row["sites"]))
        prev["n_warnings"] += row["n_warnings"]
        prev["n_strict"] += row["n_strict"]
    rows = sorted(merged.values(),
                  key=lambda r: (-len(r["sites"]), r["crate"]))

    out = open(args.output, "w", newline="") if args.output else sys.stdout
    w = csv.writer(out)
    w.writerow(["crate", "n_sites", "n_local", "n_warnings", "n_strict", "sites"])
    for r in rows:
        local = [s for s in r["sites"] if is_local(s)]
        w.writerow([r["crate"], len(r["sites"]), len(local),
                    r["n_warnings"], r["n_strict"], ";".join(r["sites"])])
    if args.output:
        out.close()

    # ── Summary ──────────────────────────────────────────────────────────────
    err = sys.stderr
    hits = [r for r in rows if r["sites"]]
    err.write(f"{len(rows)} crate log(s) scanned ({args.log}); "
              f"{len(hits)} with an int-to-ptr cast.\n")
    if missing:
        err.write(f"{len(missing)} crate dir(s) had no {args.log} "
                  f"(never run, or a different image): "
                  f"{', '.join(missing[:6])}"
                  f"{' ...' if len(missing) > 6 else ''}\n")
    if hits:
        cw = max(len(r["crate"]) for r in hits) + 2
        err.write("\nsites per crate (distinct spans, then the crate's own):\n")
        err.write("crate".ljust(cw) + f"{'sites':>7}{'local':>7}{'warns':>7}"
                  f"{'strict':>8}\n")
        for r in hits:
            local = sum(1 for s in r["sites"] if is_local(s))
            err.write(r["crate"].ljust(cw)
                      + f"{len(r['sites']):>7}{local:>7}"
                      + f"{r['n_warnings']:>7}{r['n_strict']:>8}\n")
        strict_logs = sum(1 for r in rows if r["n_strict"])
        if strict_logs:
            err.write(f"\n{strict_logs} log(s) hit the -Zmiri-strict-provenance "
                      f"hard error, which halts the run at the FIRST site -- "
                      f"their\nsite counts are lower bounds.\n")


if __name__ == "__main__":
    main()
