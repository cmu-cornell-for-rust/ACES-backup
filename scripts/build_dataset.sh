#!/usr/bin/env bash
#
# build_dataset.sh
#
#   Fetches and compiles every crate in a dataset ONCE -- no tests are run --
#   and records per crate whether it got through, how long the compile took,
#   how many runnable tests it has, and, for a failure, what the error was.
#   Use it to see which crates can be benchmarked at all before spending a
#   run_bench_dataset.sh sweep on them.
#
#   Per crate:  cargo fetch  &&  cargo test --tests --no-run
#               &&  cargo test --tests -- --list --format=json -Zunstable-options
#   with RUSTFLAGS="--cap-lints=warn" and --cfg=miri on the crate under test
#   only (see PRIMARY_RUSTFLAGS), as run_eval_dataset.sh compiles in rust/bsan
#   mode. --whole drops --tests from the compile (`cargo test --no-run`),
#   matching run_bench_dataset.sh's whole-crate mode; the listing is always
#   --tests. Each crate builds into its own target dir, deleted once it's
#   checked, and a Cargo.lock the build generated (the crate didn't ship one)
#   is removed.
#
#   --cfg=miri goes on the primary package only, through this script acting as
#   RUSTC_WRAPPER, because dependencies like backtrace link against Miri-only
#   symbols (miri_backtrace_size, ...) under cfg(miri).
#
#   The listing keeps "type": "test" entries with "ignore": false (the tests
#   that actually run, as list_tests.sh and run_eval_dataset.sh do), and writes
#   them to <dataset>_list.csv (see Output), which run_eval_dataset.sh uses in
#   place of listing on the node when it exists.
#
#   --doc also lists doc tests, with
#     cargo test --doc -- --list --format=json -Zunstable-options
#   (RUSTDOCFLAGS = BUILD_RUSTFLAGS + PRIMARY_RUSTFLAGS, as rustdoc ignores
#   RUSTFLAGS and only documents the crate under test), as list_tests.sh --doc
#   does and in its format: "doc:<name>#<filter>[#<skip>...]", percent-encoded
#   -- see "Doc tests" in list_tests.sh. They count towards `tests`. A crate
#   whose doc-test listing fails (most often: no lib target) keeps its binary
#   tests; the log says so. Doc tests aren't built by --no-run, so
#   compile_seconds doesn't include them.
#
#   Every crate whose plain compile succeeded (status ok or list_failed) is
#   then compiled a second time with
#     cargo bsan test --tests --no-run      (cargo bsan test --no-run with --whole)
#   in its own target dir, with the same RUSTFLAGS and --cfg=miri on the crate
#   under test (this script then stands in as BSAN_ORIG_RUSTC, as
#   rustc-cfg-miri.sh does for run_eval_dataset.sh). The crates that fail only
#   there go to a separate CSV (see Output); the main CSV doesn't depend on
#   it. Needs cargo-bsan, i.e. the experimental-bsan image (or one built from it).
#
#   The bsan compiles are a second pass, after every crate (of a job's part,
#   as a job) has had its plain build and listing, and the results CSV and
#   test list are written in between: cargo bsan's extra memory can then
#   neither OOM-kill a neighbouring crate's plain build or listing nor cost
#   the test list if it kills the job. If a job dies anyway, the launcher
#   rebuilds its rows from the per-crate files in its _build_parts/_state-K
#   dir, and lists the plain-compiled crates that never got their bsan
#   compile in _logs/build-<image>-bsan-unchecked.txt (they can't be counted
#   either way).
#
#   --rerun-bsan-only reruns just that cargo bsan compile, for just the crates
#   in the last bsan-only CSV and in bsan-unchecked.txt -- no fetch, plain build or listing, and the
#   main CSV and test list are left alone. The bsan-only CSV is rewritten with
#   the crates that still fail (the previous one is kept as .bak), each keeping
#   its compile_seconds from the previous one. Use it after a cargo-bsan / image
#   fix. Version flags don't apply: the crates are the CSV's.
#
#   --bsan-only runs just the cargo bsan compile, for every selected crate (the
#   version flags apply as usual) -- no plain build or listing, so no results
#   CSV or test list, and compile_seconds is empty. Every crate whose cargo
#   bsan compile fails gets a bsan-only row, including any that would fail a
#   plain build too.
#
#   --rerun-missing builds just the selected crates the last run left without
#   a row in the results CSV (a job killed or out of walltime before it got to
#   them), as jobs, and merges their rows into the existing results CSV, test
#   list and bsan-only CSV (the previous ones are kept as .bak); the other
#   crates' rows are kept as they are. Pass the same version flags, --whole
#   and --image as the run being finished, so it picks the same CSVs. Rerun
#   it until every crate has a row.
#
#   Each compile -- the plain one and cargo bsan's -- is stopped after
#   BUILD_TIMEOUT seconds (default 3600), and the crate gets a build_failed
#   (or bsan-only) row with error_type timeout.
#
#   Where it runs: from the login node the crates are dealt round-robin into
#   ceil(crates / -n) parts (so part sizes differ by at most one crate, and
#   none holds more than -n), and each part is built by its own sbatch job.
#   At most 40 jobs (the QOS limit) run at once; the rest start as earlier
#   ones finish. Each job runs this script again with --node --part K, on the
#   node outside the image, which builds that part's crates JOBS at a time:
#   each crate's worker is its own srun step in the `experimental-bsan` image
#   (--image to change), with an equal share of the job's cores and a hard cap
#   of (-m - 512M) / JOBS memory. A crate that runs out of memory is killed
#   alone -- it can't starve or take down the job's other crates -- and gets a
#   build_failed (or bsan-only) row with error_type oom if its worker didn't
#   get to write one. A copy of the script is placed in <DATASET_DIR>/_logs/
#   for the jobs, and the dataset dir is bound into every step at its own
#   path. The launcher waits for every job, merges the
#   parts' CSVs, copies the results to the outputs dir and merges the
#   bsan-only rows into <group>/scripts/bsan_build_fails.csv; run it under
#   tmux/nohup for big datasets (Ctrl-C cancels the jobs). Each job's output
#   goes to <DATASET_DIR>/_logs/_build_parts/job-K.log, its sbatch
#   submission's to submit-K.log.
#
#   No dataset dir: when DATASET is neither a dir under $GROUP/datasets/ nor a
#   path, its versions CSV <group>/scripts/<DATASET>-dataset.csv (else the one
#   next to this script, e.g. capslock-dataset.csv for capslock) stands in for
#   it: the version selection (--all default, --first, --latest, --only-latest,
#   --only-first) is made from the CSV, and each selected crate's crates.io tarball is
#   downloaded and extracted under $TMP (else $TMPDIR, else /tmp) just before
#   it builds (a download failure is a fetch_failed row). With --local, crates
#   and _logs go to $TMP/build_dataset-<DATASET>/ (kept, so a rerun reuses the
#   downloads and --rerun-bsan-only finds its CSV). As jobs, $TMP is node-local,
#   so each job downloads its own part's crates into its node's scratch, and
#   the shared dir that stands in for <DATASET_DIR> (_logs, part lists, CSVs)
#   is $GROUP/outputs/build-<DATASET>/; each crate's logs land in its
#   _logs/crate-logs/<crate>/, as the scratch is removed with the job.
#
# Usage:
#   ./build_dataset.sh [-n N] [-c CPUS] [-t HH[:MM]] [-m MEM] [--image IMG] [--whole] [--doc]
#                      [--latest | --only-latest | --only-first | --all] [--versions-csv FILE] <DATASET>
#   ./build_dataset.sh --local [--image IMG] [--whole] [--doc] [version flags] <DATASET_DIR>   # no job
#   ./build_dataset.sh --rerun-bsan-only [--local] [-n N ...] [--image IMG] [--whole] [--latest] <DATASET>
#   ./build_dataset.sh --bsan-only [--local] [-n N ...] [--image IMG] [--whole] [version flags] <DATASET>
#   ./build_dataset.sh --rerun-missing [-n N ...] [--image IMG] [--whole] [--doc] [version flags] <DATASET>
#
#   DATASET       a dataset name under $GROUP/datasets/ (e.g. top_500), or a path;
#                 else a name with a <name>-dataset.csv (see "No dataset dir")
#
#   -n N          at most N crates per job (default 100)
#   -c CPUS       cores per job (default 16)
#   -t HH[:MM]    walltime per job (default 8)
#   -m MEM        memory per job (default 64G; bare number = GB), split evenly
#                 into a hard per-crate cap over the JOBS crates it builds at
#                 once (16G less a little at the defaults); raise it if crates
#                 hit their cap (error_type oom)
#   --image IMG   container image (default experimental-bsan); also the CSV's
#                 build column. The main build is plain cargo (the image's default
#                 toolchain), so nothing is instrumented; the second compile
#                 is `cargo bsan`, so the image must have cargo-bsan
#   --whole       compile with `cargo test --no-run` (all targets cargo test
#                 builds), not `cargo test --tests --no-run`
#   --doc         also list doc tests (off by default; see above)
#   --rerun-bsan-only  only rerun cargo bsan on the last bsan-only CSV's
#                 crates (see above); --whole and --latest/--only-latest pick
#                 the same compile and CSV as the run being redone
#   --bsan-only   only the cargo bsan compile, no plain build or listing
#                 (see above)
#   --rerun-missing  only the crates with no row in the last results CSV,
#                 merged into the existing outputs (see above; not --local)
#   (versions)    which crate versions to build, from the versions CSV
#                 (dataset_creator/update_latest.py adds its latest_version /
#                 version_differs columns; dataset_creator/select_versions.sh
#                 does the selecting). Default: --all.
#   --first       every crate at its first (listed) version
#   --latest      every crate at its latest version (first where unchanged)
#   --only-latest only the crates whose latest version differs, at the latest
#                 --latest/--only-latest write *-latest outputs (see Output)
#                 and also <group>/scripts/<dataset>-tests-latest.csv, the
#                 list to pass to run_eval_dataset.sh --tests
#                 (an existing one is kept as .bak)
#   --only-first  only the crates whose latest version differs, at their
#                 first (listed) version; writes *-only-first outputs, so the
#                 full --first run's are kept
#   --all         (default) every dir in the dataset, whatever its version;
#                 with no dataset dir, every version the CSV lists (first and
#                 latest, as download_dataset.sh would fetch)
#   --versions-csv FILE  default <group>/scripts/<dataset>-dataset.csv
#   --local       skip the job: build on this machine / inside an image shell
#   --part K      with --local: build only the crates in part K's list
#                 (_logs/_build_parts/part-K.txt); set by the launcher
#
# Output (with --latest/--only-latest every name below gets a "-latest"
# suffix before .csv, and the parts dir is _build_parts-latest; with
# --only-first the suffix is "-only-first"):
#   <DATASET_DIR>/_logs/build-<image>.csv, and (when launched as a job) a copy
#   at $GROUP/outputs/<image>-<dataset>-build.csv, columns:
#     build,crate,status,compile_seconds,tests,error_type,error,timestamp
#   status           ok / fetch_failed / build_failed / list_failed
#   compile_seconds  wall time of the --no-run compile (empty on fetch_failed)
#   tests            number of runnable tests (empty unless status is ok)
#   error_type       for a failure, the first of these to match cargo's output
#                    (same patterns, same order, as run_bench_dataset.sh and
#                    analysis/failure_logs.py):
#                      rustc   error[E<code>]
#                      linker  rust-lld
#                      oom     SIGKILL
#                      gc      ERROR: BorrowSanitizer: garbage collection
#                      crash   BorrowSanitizer:DEADLYSIGNAL
#                      bsan    error: Undefined Behavior:
#                      panic   panicked at   (e.g. a build script panicking)
#                      other   none of the above
#                    or timeout: the compile ran past BUILD_TIMEOUT (set by
#                    this script, ahead of the patterns)
#   error            the matching line (else the last error:/non-empty line),
#                    one line, at most 300 chars
#   Each crate's full fetch+build output goes to <crate>/build-<image>.log.
#
#   <DATASET_DIR>/_logs/<dataset>_list.csv, and (when launched as a job) a copy
#   at $GROUP/outputs/<dataset>_list.csv, columns:
#     crate,tests
#   one row per crate with status ok, tests its runnable test names joined by
#   ';' (empty when it has none) -- the same format as list_tests.sh's CSV.
#
#   <DATASET_DIR>/_logs/build-<image>-bsan-only.csv, columns:
#     build,crate,compile_seconds,bsan_compile_seconds,error_type,error,timestamp
#   one row per crate whose plain compile succeeded but whose cargo bsan
#   compile failed; compile_seconds is the plain compile's, error_type/error
#   are classified from the bsan compile's output as above. Its full output
#   goes to <crate>/build-<image>-bsan.log.
#
#   $GROUP/scripts/bsan_build_fails.csv (when launched as a job; not in the
#   outputs dir): the running list of bsan-only build failures across
#   datasets and runs, same columns, which run_eval_dataset.sh skips in bsan
#   mode. Each run drops the rows of every crate it got through the cargo bsan
#   compile (a crate that now builds leaves the list) and appends its own
#   bsan-only rows; other crates' rows are kept as they are.
#
#   <DATASET_DIR>/_logs/build-<image>-bsan-unchecked.txt, only when a job died:
#   the plain-compiled crates whose cargo bsan compile never ran (see above),
#   one per line; --rerun-bsan-only picks them up.
#
# Environment knobs:
#   JOBS                crates built in parallel (default: CPUS/4 in a job,
#                       1 with --local); each cargo gets CPUS/JOBS cores and,
#                       in a job, (-m - 512M)/JOBS memory
#   BUILD_RUSTFLAGS="--cap-lints=warn"   RUSTFLAGS for the build (every crate)
#   PRIMARY_RUSTFLAGS="--cfg=miri"       extra rustc flags for the crate under
#                       test only; set it empty and BUILD_RUSTFLAGS to
#                       "--cfg=miri --cap-lints=warn" for the old behaviour
#   CARGO_TARGET_DIR    if set, per-crate target dirs go under it
#   BUILD_TIMEOUT=3600  seconds each compile (plain or cargo bsan) may take
#                       before it's killed (error_type timeout); 0: no limit
#
# Requirements: bash 4+; cargo (in the image, or here with --local).

set -uo pipefail   # no -e; per-crate failures are handled inline

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

die() { echo "ERROR: $*" >&2; exit 1; }

# As cargo's RUSTC_WRAPPER (set by the worker's build): argv is rustc and its
# args; the crate under test gets PRIMARY_RUSTFLAGS on top.
if [ -n "${BUILD_DATASET_RUSTC_WRAPPER:-}" ]; then
    # shellcheck disable=SC2086  # PRIMARY_RUSTFLAGS splits into flags
    [ "${CARGO_PRIMARY_PACKAGE:-}" = 1 ] && exec "$@" $PRIMARY_RUSTFLAGS
    exec "$@"
fi
# As cargo bsan's BSAN_ORIG_RUSTC (set by the worker's bsan build; cargo bsan
# overrides RUSTC and RUSTC_WRAPPER but runs this as its rustc): argv is
# rustc's args only. The manifest check keeps out a sysroot build, where std
# is the primary package.
if [ -n "${BUILD_DATASET_BSAN_RUSTC:-}" ]; then
    if [ "${CARGO_PRIMARY_PACKAGE:-}" = 1 ] \
            && [[ "${CARGO_MANIFEST_DIR:-}" == "$BUILD_DATASET_CRATE_DIR"* ]]; then
        # shellcheck disable=SC2086  # PRIMARY_RUSTFLAGS splits into flags
        exec "$BUILD_DATASET_REAL_RUSTC" "$@" $PRIMARY_RUSTFLAGS
    fi
    exec "$BUILD_DATASET_REAL_RUSTC" "$@"
fi

# classify <output file>: sets ekind/emsg from a failed command's output. Same
# patterns, same first-match order, as run_bench_dataset.sh's classify and
# analysis/failure_logs.py's error_type -- keep the three in sync.
classify() {
    ekind=other; emsg=""
    local kp
    for kp in 'rustc|error\[E[0-9]+\]' 'linker|rust-lld' 'oom|SIGKILL' \
              'gc|ERROR: BorrowSanitizer: garbage collection' \
              'crash|BorrowSanitizer:DEADLYSIGNAL' \
              'bsan|error: Undefined Behavior:' 'panic|panicked at'; do
        # panic takes the line after too: newer libtest prints the message there.
        if [ "${kp%%|*}" = panic ]; then
            emsg=$(grep -aE -m1 -A1 -- "${kp#*|}" "$1")
        else
            emsg=$(grep -aE -m1 -- "${kp#*|}" "$1")
        fi
        if [ -n "$emsg" ]; then ekind=${kp%%|*}; break; fi
    done
    [ -n "$emsg" ] || emsg=$(grep -aE '^error' "$1" | tail -n1)
    [ -n "$emsg" ] || emsg=$(grep -av '^[[:space:]]*$' "$1" | tail -n1)
    emsg=$(printf '%s' "$emsg" | sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' \
        | tr -d '\r' | tr '\n\t' '  ' | sed -e 's/^ *//' -e 's/  */ /g' | cut -c1-300)
}

# download_crate <name-version> <into dir>: fetch the crates.io tarball and
# extract it to <into dir>/<name-version>/, as download_dataset.sh does. The
# name is everything up to the last hyphen before a digit.
download_crate() {
    local c="$1" name tmp rc
    name="${c%-[0-9]*}"
    tmp="$(mktemp "$2/.$c.XXXXXX")" || return 1
    curl -fsSL -A "crate-downloader (CMU systems research; via crates.io)" \
            --retry 3 --retry-delay 2 -o "$tmp" \
            "https://static.crates.io/crates/$name/$name-${c#"$name"-}.crate" \
        && tar -xzf "$tmp" -C "$2" && [ -f "$2/$c/Cargo.toml" ]
    rc=$?
    rm -f "$tmp"
    return "$rc"
}

# timed_out <exit code> <elapsed ms>: whether a compile under
# `timeout $BUILD_TIMEOUT` failed because it ran out of time.
timed_out() { [ "$1" -ne 0 ] && [ "$BUILD_TIMEOUT" -gt 0 ] && [ "$2" -ge $(( BUILD_TIMEOUT * 1000 )) ]; }

# CSV-quote a field (empty stays empty).
csvq() { [ -n "$1" ] && printf '"%s"' "${1//\"/\"\"}"; }

# doc_names <all names> <runnable names>: each runnable doc test as
# doc:<name>#<filter>[#<skip>...] -- the same encoding and filter choice as
# list_tests.sh --doc (see "Doc tests" there); keep the two in sync. A doc
# test that can't be isolated is left out, with a warning on stderr.
doc_names() {
    awk '
        function enc(s) {
            gsub(/%/, "%25", s); gsub(/,/, "%2C", s); gsub(/;/, "%3B", s)
            gsub(/ /, "%20", s); gsub(/\047/, "%27", s); gsub(/"/, "%22", s)
            gsub(/#/, "%23", s); return s
        }
        NR == FNR { all[++n] = $0; next }
        {
            k = split($0, tok, " "); best = ""; bestn = -1
            for (j = 0; j <= k; j++) {
                i = (j == 0) ? 3 : j
                f = tok[i]
                if (f == "" || f == "-") continue
                skips = ""; cnt = 0; ok = 1
                for (m = 1; m <= n; m++) {
                    o = all[m]
                    if (o == $0 || !index(o, f)) continue
                    ko = split(o, otok, " "); sk = ""
                    for (q = 1; q <= ko; q++)
                        if (otok[q] != "-" && !index($0, otok[q])) { sk = otok[q]; break }
                    if (sk == "") { ok = 0; break }
                    skips = skips "#" enc(sk); cnt++
                }
                if (ok && (bestn < 0 || cnt < bestn)) { best = enc(f) skips; bestn = cnt }
                if (bestn == 0) break
            }
            if (bestn < 0) { print "warning: cannot isolate, skipped doc test: " $0 > "/dev/stderr"; next }
            print "doc:" enc($0) "#" best
        }
    ' "$1" "$2"
}

# ------------------------------- worker mode ------------------------------- #
# Invoked by xargs, one crate per call, in two passes over the crates (each
# pass over all of them before the next starts):
#   --worker <crate_dir>       plain fetch, compile and test listing: the
#                              crate's CSV row to $STATE_DIR/<crate>.csv and,
#                              when it built and listed, its <dataset>_list.csv
#                              row to $STATE_DIR/<crate>.list
#   --worker-bsan <crate_dir>  the cargo bsan compile, for a crate the first
#                              pass compiled (ok / list_failed): a failure's
#                              row to $STATE_DIR/<crate>.bsan, and, checked or
#                              not needed, $STATE_DIR/<crate>.bsandone
# The plain pass finishes for every crate first, so cargo bsan's extra memory
# can't OOM-kill a neighbouring crate's build or listing, and the test list is
# written before any bsan compile starts. --rerun-bsan-only runs only the
# second pass (which then downloads, when the crates are downloaded), as does
# --bsan-only, for every crate.
if [ "${1:-}" = "--worker" ] || [ "${1:-}" = "--worker-bsan" ]; then
    phase="$1"
    dir="$2"
    crate="$(basename "$dir")"
    logdir="$dir"
    [ -n "$CRATE_LOG_DIR" ] && logdir="$CRATE_LOG_DIR/$crate"
    log="$logdir/build-$IMAGE.log"
    if [ -n "$TARGET_BASE" ]; then
        export CARGO_TARGET_DIR="$TARGET_BASE/build-$crate"
    else
        export CARGO_TARGET_DIR="$dir/target"
    fi
    bsan_target="$CARGO_TARGET_DIR-bsan"

    # The pass that starts with the crate: download it if needed, and note
    # whether it shipped a Cargo.lock (one the build generates is removed at
    # the end of the bsan pass).
    if [ "$phase" = --worker ] || [ "$RERUN" -eq 1 ] || [ "$BSAN_ONLY" -eq 1 ]; then
        if [ "$DOWNLOAD" -eq 1 ] && [ ! -f "$dir/Cargo.toml" ]; then
            mkdir -p "$logdir"
            if ! download_crate "$crate" "$(dirname "$dir")" > "$log" 2>&1; then
                echo "    download_failed: $crate"
                if [ "$RERUN" -eq 1 ]; then
                    # Can't recheck it: keep its previous bsan-only row.
                    awk -F, -v c="$crate" '$2 == c' "$PREV_CSV" > "$STATE_DIR/$crate.bsan"
                    : > "$STATE_DIR/$crate.bsandone"
                elif [ "$BSAN_ONLY" -eq 1 ]; then
                    :   # no .bsandone: the launcher lists it as unchecked
                else
                    printf '%s,%s,fetch_failed,,,other,%s,%s\n' "$IMAGE" "$crate" \
                        "$(csvq "crates.io download failed (see $log)")" \
                        "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" > "$STATE_DIR/$crate.csv"
                fi
                exit 0
            fi
        fi
        [ -f "$dir/Cargo.lock" ] || : > "$STATE_DIR/$crate.nolock"
    fi

    if [ "$phase" = --worker ]; then
        rm -rf "${CARGO_TARGET_DIR:?}"
        status=ok; compile=""; ntests=""; ekind=""; emsg=""; tout=0
    wrap=()
    [ -n "$PRIMARY_RUSTFLAGS" ] \
        && wrap=(RUSTC_WRAPPER="$SELF" BUILD_DATASET_RUSTC_WRAPPER=1)
    if ! ( cd "$dir" && cargo fetch ) > "$log" 2>&1; then
        status=fetch_failed
    else
        cstart=$(date +%s%3N)
        ( cd "$dir" && timeout -k 60 "$BUILD_TIMEOUT" env ${wrap[@]+"${wrap[@]}"} \
                RUSTFLAGS="$BUILD_RUSTFLAGS" $COMPILE --no-run ) >> "$log" 2>&1
        brc=$?
        cms=$(( $(date +%s%3N) - cstart ))
        compile=$(printf '%d.%03d' $(( cms / 1000 )) $(( cms % 1000 )))
        [ "$brc" -eq 0 ] || status=build_failed
        if timed_out "$brc" "$cms"; then
            tout=1
            echo "--- build_dataset: compile timed out after ${BUILD_TIMEOUT}s ---" >> "$log"
        fi
    fi
    if [ "$status" = ok ]; then
        # JSON lines on stdout, build noise on stderr (into the log). Same
        # flags as the build, so the binaries it just made are reused.
        list="$STATE_DIR/$crate.json"
        if ( cd "$dir" && env ${wrap[@]+"${wrap[@]}"} RUSTFLAGS="$BUILD_RUSTFLAGS" \
                cargo test --tests -- --list --format=json -Zunstable-options ) \
                > "$list" 2>> "$log"; then
            names=$(grep -a '"type": *"test"' "$list" | grep -a '"ignore": *false' \
                | sed -E 's/.*"name": *"([^"]*)".*/\1/' | sed '/^$/d' | LC_ALL=C sort -u)
            if [ "$DOC" -eq 1 ]; then
                doclog="$STATE_DIR/$crate.doc.json"
                if ( cd "$dir" && env ${wrap[@]+"${wrap[@]}"} RUSTFLAGS="$BUILD_RUSTFLAGS" \
                        RUSTDOCFLAGS="$BUILD_RUSTFLAGS${PRIMARY_RUSTFLAGS:+ $PRIMARY_RUSTFLAGS}" \
                        cargo test --doc -- --list --format=json -Zunstable-options ) \
                        > "$doclog" 2>> "$log"; then
                    namesof() { sed -E 's/.*"name": *"([^"]*)".*/\1/' | sed '/^$/d' | LC_ALL=C sort -u; }
                    grep -a '"type": *"test"' "$doclog" | namesof > "$doclog.all"
                    grep -a '"type": *"test"' "$doclog" | grep -a '"ignore": *false' | namesof > "$doclog.run"
                    docs=$(doc_names "$doclog.all" "$doclog.run" 2>> "$log")
                    [ -n "$docs" ] && names="${names:+$names
}$docs"
                    rm -f "$doclog.all" "$doclog.run"
                else
                    echo "build_dataset: doc-test listing failed (no lib target?); binary tests only" >> "$log"
                fi
                rm -f "$doclog"
            fi
            ntests=$(printf '%s' "$names" | grep -c . || true)
            printf '%s,%s\n' "$crate" "$(printf '%s' "$names" | paste -sd';' -)" \
                > "$STATE_DIR/$crate.list"
        else
            status=list_failed
            cat "$list" >> "$log"
        fi
        rm -f "$list"
    fi
    if [ "$status" != ok ]; then
        classify "$log"
        [ "$tout" -eq 1 ] && { ekind=timeout; emsg="compile timed out after ${BUILD_TIMEOUT}s"; }
        echo "    $status: $crate [$ekind] $emsg"
    fi
    printf '%s,%s,%s,%s,%s,%s,%s,%s\n' "$IMAGE" "$crate" "$status" "$compile" \
        "$ntests" "$ekind" "$(csvq "$emsg")" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
        > "$STATE_DIR/$crate.csv"
        rm -rf "${CARGO_TARGET_DIR:?}"
        exit 0
    fi

    # --worker-bsan: the same compile under cargo bsan, for crates whose plain
    # compile succeeded; a failure here is one only bsan has.
    if [ "$RERUN" -eq 1 ]; then
        # --rerun-bsan-only: its plain compile passed last run; keep that time.
        status=ok
        compile=$(awk -F, -v c="$crate" '$2 == c { print $3; exit }' "$PREV_CSV")
        # An unchecked crate has no previous bsan-only row: the results' time.
        [ -n "$compile" ] \
            || compile=$(awk -F, -v c="$crate" '$2 == c { print $4; exit }' "$MAIN_RESULTS_CSV" 2>/dev/null)
    elif [ "$BSAN_ONLY" -eq 1 ]; then
        status=ok; compile=""   # no plain compile to go by
    else
        # build,crate,status,compile_seconds,...: none of these is quoted.
        status=$(cut -d, -f3 "$STATE_DIR/$crate.csv" 2>/dev/null)
        compile=$(cut -d, -f4 "$STATE_DIR/$crate.csv" 2>/dev/null)
    fi
    if [ "$status" = ok ] || [ "$status" = list_failed ]; then
        blog="$logdir/build-$IMAGE-bsan.log"
        bwrap=()
        [ -n "$PRIMARY_RUSTFLAGS" ] \
            && bwrap=(BSAN_ORIG_RUSTC="$SELF" BUILD_DATASET_BSAN_RUSTC=1
                      BUILD_DATASET_REAL_RUSTC="$(command -v rustc)" BUILD_DATASET_CRATE_DIR="$dir")
        rm -rf "$bsan_target"
        cstart=$(date +%s%3N)
        # RUSTUP_TOOLCHAIN beats a crate's rust-toolchain(.toml), which would
        # otherwise swap in stock stable/nightly (no bsan, no matching clang).
        ( cd "$dir" && timeout -k 60 "$BUILD_TIMEOUT" env ${bwrap[@]+"${bwrap[@]}"} \
                RUSTUP_TOOLCHAIN=bsan CARGO_TARGET_DIR="$bsan_target" RUSTFLAGS="$BUILD_RUSTFLAGS" \
                cargo bsan ${COMPILE#cargo } --no-run ) > "$blog" 2>&1
        brc=$?
        cms=$(( $(date +%s%3N) - cstart ))
        bcompile=$(printf '%d.%03d' $(( cms / 1000 )) $(( cms % 1000 )))
        if [ "$brc" -ne 0 ]; then
            classify "$blog"
            if timed_out "$brc" "$cms"; then
                ekind=timeout; emsg="cargo bsan compile timed out after ${BUILD_TIMEOUT}s"
                echo "--- build_dataset: $emsg ---" >> "$blog"
            fi
            echo "    bsan_build_failed: $crate [$ekind] $emsg"
            printf '%s,%s,%s,%s,%s,%s,%s\n' "$IMAGE" "$crate" "$compile" "$bcompile" \
                "$ekind" "$(csvq "$emsg")" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
                > "$STATE_DIR/$crate.bsan"
        fi
    fi
    : > "$STATE_DIR/$crate.bsandone"

    rm -rf "${CARGO_TARGET_DIR:?}" "${bsan_target:?}"
    # A job's downloaded crate goes too (its logs are in CRATE_LOG_DIR);
    # --local keeps its downloads for the next run.
    if [ -n "$CRATE_LOG_DIR" ]; then rm -rf "${dir:?}"; exit 0; fi
    if [ -f "$STATE_DIR/$crate.nolock" ]; then
        rm -f "${dir:?}/Cargo.lock" "${STATE_DIR:?}/${crate:?}.nolock"
    fi
    exit 0
fi

# -------------------------------- step mode -------------------------------- #
# Invoked by xargs on a part job (--node) in place of the worker:
#   --step <--worker|--worker-bsan> <crate_dir>
# runs that worker call in the image as its own srun step, with its own cgroup
# capped at the job's per-crate share of -m, so a crate that runs out of
# memory is killed alone -- it can neither starve nor take down the others.
# If the step dies before the worker wrote its row (OOM-killed as a whole,
# signal), the row is written here: a build_failed row in the first pass, a
# bsan-only row in the second. Always exits 0, so xargs keeps going.
if [ "${1:-}" = "--step" ]; then
    phase="$2"
    dir="$3"
    crate="$(basename "$dir")"
    errf="$BD_SCRATCH/step-$crate.err"
    srun --exact --nodes=1 --ntasks=1 \
        --cpus-per-task="$BD_STEP_CPUS" --mem="$BD_STEP_MEM" \
        --kill-on-bad-exit=0 --job-name="$crate" \
        singularity exec --cleanenv --pwd "$BD_DATASET_DIR" \
            --bind "$BD_DATASET_DIR" --bind "$BD_SCRATCH" --env-file "$BD_ENV" \
            "$BD_SIF" bash "$SELF" "$phase" "$dir" 2> "$errf"
    rc=$?
    cat "$errf" >&2
    # The worker exits 0 whenever it wrote what it had to; a missing row after
    # a failed step means the step was killed under it.
    missing=0
    if [ "$phase" = --worker ]; then
        [ -f "$STATE_DIR/$crate.csv" ] || missing=1
    else
        [ -f "$STATE_DIR/$crate.bsandone" ] || missing=1
    fi
    if [ "$rc" -ne 0 ] && [ "$missing" -eq 1 ]; then
        if grep -q 'oom[-_]kill' "$errf"; then
            ekind=oom; why="srun step OOM-killed at its $BD_STEP_MEM share of -m"
        else
            ekind=other; why="srun step exited $rc"
        fi
        logdir="$dir"
        [ -n "$CRATE_LOG_DIR" ] && logdir="$CRATE_LOG_DIR/$crate"
        mkdir -p "$logdir"
        ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
        if [ "$phase" = --worker ]; then
            echo "--- build_dataset: $why ---" >> "$logdir/build-$IMAGE.log"
            echo "    build_failed: $crate [$ekind] $why"
            printf '%s,%s,build_failed,,,%s,%s,%s\n' "$IMAGE" "$crate" "$ekind" \
                "$(csvq "$why")" "$ts" > "$STATE_DIR/$crate.csv"
        else
            echo "--- build_dataset: $why ---" >> "$logdir/build-$IMAGE-bsan.log"
            echo "    bsan_build_failed: $crate [$ekind] $why"
            if [ "$RERUN" -eq 1 ]; then
                compile=$(awk -F, -v c="$crate" '$2 == c { print $3; exit }' "$PREV_CSV")
            else
                compile=$(cut -d, -f4 "$STATE_DIR/$crate.csv" 2>/dev/null)
            fi
            printf '%s,%s,%s,,%s,%s,%s\n' "$IMAGE" "$crate" "$compile" "$ekind" \
                "$(csvq "$why")" "$ts" > "$STATE_DIR/$crate.bsan"
            : > "$STATE_DIR/$crate.bsandone"
        fi
    fi
    # What the killed worker left behind on the node.
    rm -rf "${TARGET_BASE:?}/build-$crate" "${TARGET_BASE:?}/build-$crate-bsan" "$errf"
    exit 0
fi

# ------------------------------- arguments --------------------------------- #
GROUP="/scratch/group/p.cis260229.000"
CONTAINERS_DIR="$GROUP/containers"
OUTPUTS_DIR="$GROUP/outputs"
# Bsan-only build failures of every run, for run_eval_dataset.sh (see Output).
BSAN_FAILS_CSV="$GROUP/scripts/bsan_build_fails.csv"
LOCAL=0; NODE=0; CPUS=16; WALLTIME=8; MEM=64G; IMAGE=experimental-bsan; WHOLE=0; DOC=0; RERUN=0; BSAN_ONLY=0; MISSING=0; DOWNLOAD=0; PER_JOB=100; PART=""; POS=()
VERSIONS=""; VERSIONS_CSV=""
MAX_PARALLEL=40   # jobs in flight at once (QOS limit)
while [ "$#" -gt 0 ]; do
    case "$1" in
        --local)    LOCAL=1; shift ;;
        --whole)    WHOLE=1; shift ;;
        --doc)      DOC=1; shift ;;
        --rerun-bsan-only) RERUN=1; shift ;;
        --bsan-only) BSAN_ONLY=1; shift ;;
        --rerun-missing) MISSING=1; shift ;;
        --download) DOWNLOAD=1; shift ;;   # internal: set by the launcher for part jobs
        --node)     NODE=1; LOCAL=1; shift ;;   # internal: a part job, on the node outside the image
        --first|--latest|--only-latest|--only-first|--all)
                    [ -z "$VERSIONS" ] || [ "$VERSIONS" = "${1#--}" ] \
                        || die "--$VERSIONS and $1 are mutually exclusive"
                    VERSIONS="${1#--}"; shift ;;
        --versions-csv) VERSIONS_CSV="$2"; shift 2 ;;
        --part)     PART="$2"; shift 2 ;;
        -n|--per-job) PER_JOB="$2"; shift 2 ;;
        -c|--cpus)  CPUS="$2"; shift 2 ;;
        -t|--time)  WALLTIME="$2"; shift 2 ;;
        -m|--mem)   MEM="$2"; shift 2 ;;
        --image)    IMAGE="$2"; shift 2 ;;
        -*)         die "unknown option $1" ;;
        *)          POS+=("$1"); shift ;;
    esac
done
VERSIONS="${VERSIONS:-all}"
[ "$RERUN" -eq 1 ] && [ "$BSAN_ONLY" -eq 1 ] && die "--rerun-bsan-only and --bsan-only are mutually exclusive"
[ "$MISSING" -eq 1 ] && { [ "$RERUN" -eq 1 ] || [ "$BSAN_ONLY" -eq 1 ]; } \
    && die "--rerun-missing doesn't go with --rerun-bsan-only or --bsan-only"
[ "$MISSING" -eq 1 ] && [ "$LOCAL" -eq 1 ] && die "--rerun-missing is for job runs, not --local"
[ "${#POS[@]}" -eq 1 ] && [ -n "${POS[0]}" ] \
    || { echo "Usage: $0 [-n N] [-c CPUS] [-t HH[:MM]] [-m MEM] [--image IMG] [--whole] [--doc] [--rerun-bsan-only | --bsan-only | --rerun-missing] [--local] [--latest | --only-latest | --only-first | --all] [--versions-csv FILE] <DATASET>" >&2; exit 1; }
# --node: a part job's batch script, on the compute node outside the image. It
# loads singularity and sets up node-local scratch (bound into every step at
# the same path): CARGO_HOME, the target dirs and, when downloading, the crates.
if [ "$NODE" -eq 1 ]; then
    [ -n "${SLURM_JOB_ID:-}" ] || die "--node is for part jobs (set by the launcher)"
    if ! command -v module &>/dev/null; then
        source /etc/profile.d/lmod.sh    2>/dev/null || \
        source /etc/profile.d/modules.sh 2>/dev/null || true
    fi
    module load WebProxy
    command -v singularity &>/dev/null || \
        module load Singularity 2>/dev/null || \
        module load singularity 2>/dev/null || true
    command -v singularity &>/dev/null || die "'singularity' not found on this node"
    BD_SIF="$CONTAINERS_DIR/$IMAGE.sif"
    [ -f "$BD_SIF" ] || die "image not found: $BD_SIF"
    BD_SCRATCH="${TMPDIR:-/tmp}/build-$SLURM_JOB_ID"
    mkdir -p "$BD_SCRATCH/home" "$BD_SCRATCH/target"
    trap 'rm -rf "$BD_SCRATCH" 2>/dev/null || true' EXIT
    export TMP="$BD_SCRATCH" CARGO_TARGET_DIR="$BD_SCRATCH/target"
    # Finite stack before srun propagates it into the steps (bsan shadow-memory
    # layout workaround -- see run_job.sh).
    ulimit -S -s 8192
fi
TMP_BASE="${TMP:-${TMPDIR:-/tmp}}"
# A bare dataset name under the group datasets dir, or a path; else a dataset
# name with a versions CSV, whose crates are downloaded (see "No dataset dir").
# CRATE_ROOT holds the crate dirs; CRATE_LOG_DIR, when set, their logs.
CRATE_LOG_DIR=""
if DATASET_DIR="$(cd "$GROUP/datasets/${POS[0]}" 2>/dev/null && pwd -P)" \
        || DATASET_DIR="$(cd "${POS[0]}" 2>/dev/null && pwd -P)"; then
    DS_NAME="$(basename "$DATASET_DIR")"
    CRATE_ROOT="$DATASET_DIR"
    if [ "$DOWNLOAD" -eq 1 ]; then
        # A part job of a CSV dataset: DATASET_DIR is the shared dir, the
        # crates go to this node's scratch (--node sets TMP to it; it's bound
        # into every step at the same path).
        if [ -n "${TMP:-}${TMPDIR:-}" ]; then
            CRATE_ROOT="$TMP_BASE/build_dataset-crates"
        else
            [ -n "${CARGO_TARGET_DIR:-}" ] || die "--download: no TMP, TMPDIR or CARGO_TARGET_DIR for the crates"
            CRATE_ROOT="$(dirname "$CARGO_TARGET_DIR")/build_dataset-crates"
        fi
        CRATE_LOG_DIR="$DATASET_DIR/_logs/crate-logs"
    fi
else
    DS_NAME="$(basename "${POS[0]%/}")"
    DS_CSV=""
    for f in "$GROUP/scripts/$DS_NAME-dataset.csv" "$(dirname "$SELF")/$DS_NAME-dataset.csv"; do
        [ -f "$f" ] && { DS_CSV="$f"; break; }
    done
    [ -n "$DS_CSV" ] || die "${POS[0]} is neither a dataset under $GROUP/datasets, a directory, nor a dataset with a $DS_NAME-dataset.csv"
    [ -n "$VERSIONS_CSV" ] || VERSIONS_CSV="$DS_CSV"
    DOWNLOAD=1
    if [ "$LOCAL" -eq 1 ]; then
        DATASET_DIR="$TMP_BASE/build_dataset-$DS_NAME"
    else
        DATASET_DIR="$OUTPUTS_DIR/build-$DS_NAME"
    fi
    CRATE_ROOT="$DATASET_DIR"
    mkdir -p "$DATASET_DIR/_logs" || die "can't create $DATASET_DIR/_logs"
    echo "==> No dataset dir for ${POS[0]}: building from $VERSIONS_CSV, crates downloaded to" \
         "$([ "$LOCAL" -eq 1 ] && echo "$CRATE_ROOT" || echo "each job's node-local scratch"); _logs in $DATASET_DIR/_logs"
fi
BUILD_RUSTFLAGS="${BUILD_RUSTFLAGS:---cap-lints=warn}"
PRIMARY_RUSTFLAGS="${PRIMARY_RUSTFLAGS---cfg=miri}"   # set but empty: off
BUILD_TIMEOUT="${BUILD_TIMEOUT:-3600}"
[[ "$BUILD_TIMEOUT" =~ ^[0-9]+$ ]] || die "BUILD_TIMEOUT must be a number of seconds (0: no limit)"
SUFFIX=""
case "$VERSIONS" in latest|only-latest) SUFFIX="-latest" ;; only-first) SUFFIX="-only-first" ;; esac
RESULTS_CSV="$DATASET_DIR/_logs/build-$IMAGE$SUFFIX.csv"
LIST_CSV="$DATASET_DIR/_logs/${DS_NAME}_list$SUFFIX.csv"
BSAN_CSV="$DATASET_DIR/_logs/build-$IMAGE-bsan-only$SUFFIX.csv"
BSAN_HEADER="build,crate,compile_seconds,bsan_compile_seconds,error_type,error,timestamp"
# --rerun-bsan-only: the bsan-only CSV being redone, copied aside (in _logs, so
# the part jobs see it) since the run overwrites BSAN_CSV.
PREV_CSV="$DATASET_DIR/_logs/.build-$IMAGE-bsan-only$SUFFIX.prev.csv"
# Plain-compiled crates a dead job never got through the bsan pass.
UNCHECKED_TXT="$DATASET_DIR/_logs/build-$IMAGE-bsan-unchecked$SUFFIX.txt"
# The whole run's results (a part job's RESULTS_CSV is its part's), for a
# rerun's compile_seconds of a crate that was unchecked rather than failing.
MAIN_RESULTS_CSV="$RESULTS_CSV"
PARTS_DIR="$DATASET_DIR/_logs/_build_parts$SUFFIX"

# Version selection: ALLOW holds the <name>-<version> dirs to build
# (VERSION_FILTER=0: every dir, i.e. --all with a dataset dir). A --part job
# builds its part list as given.
declare -A ALLOW=()
VERSION_FILTER=0
if [ -z "$PART" ] && { [ "$VERSIONS" != all ] || [ "$DOWNLOAD" -eq 1 ]; } && [ "$RERUN" -eq 0 ]; then
    if [ -n "$VERSIONS_CSV" ]; then
        [ -f "$VERSIONS_CSV" ] || die "versions CSV not found: $VERSIONS_CSV"
    else
        VERSIONS_CSV="$GROUP/scripts/$DS_NAME-dataset.csv"
        if [ ! -f "$VERSIONS_CSV" ]; then
            die "--$VERSIONS needs a versions CSV; $VERSIONS_CSV not found (pass --versions-csv FILE)"
        fi
    fi
    if [ -n "$VERSIONS_CSV" ]; then
        select_versions() { "$(dirname "$SELF")/dataset_creator/select_versions.sh" "$1" "$VERSIONS_CSV"; }
        if [ "$VERSIONS" = all ]; then
            # No dataset dir: every version the CSV lists. A CSV without the
            # latest columns has only its first versions.
            selected=$(select_versions first) || exit 1
            latest=$(select_versions latest 2>/dev/null) && selected="$selected"$'\n'"$latest"
        else
            selected=$(select_versions "$VERSIONS") || exit 1
        fi
        while IFS= read -r d; do [ -n "$d" ] && ALLOW["$d"]=1; done <<<"$selected"
        VERSION_FILTER=1
        missing=()
        [ "$DOWNLOAD" -eq 1 ] \
            || for d in "${!ALLOW[@]}"; do [ -f "$DATASET_DIR/$d/Cargo.toml" ] || missing+=("$d"); done
        echo "==> Versions: $VERSIONS -- ${#ALLOW[@]} crate dir(s) selected from $VERSIONS_CSV"
        if [ "${#missing[@]}" -gt 0 ]; then
            echo "    warning: ${#missing[@]} selected dir(s) not in $DATASET_DIR (skipped; download them with dataset_creator/update_latest.py):" >&2
            printf '      %s\n' "${missing[@]}" | LC_ALL=C sort >&2
        fi
    fi
fi
# want_crate <dir name>: whether the version selection keeps it.
want_crate() { [ "$VERSION_FILTER" -eq 0 ] || [ -n "${ALLOW[$1]:-}" ]; }

# --rerun-bsan-only, launcher or whole --local run: the crates come from the
# last bsan-only CSV, set aside as PREV_CSV.
if [ "$RERUN" -eq 1 ] && [ -z "$PART" ]; then
    [ -s "$BSAN_CSV" ] || die "--rerun-bsan-only: no bsan-only CSV at $BSAN_CSV"
    cp "$BSAN_CSV" "$PREV_CSV" || die "can't copy $BSAN_CSV to $PREV_CSV"
fi
# rerun_crates: the PREV_CSV and UNCHECKED_TXT crates that are still in the
# dataset dir (all of them, when they're downloaded).
rerun_crates() {
    { tail -n +2 "$PREV_CSV" | cut -d, -f2; cat "$UNCHECKED_TXT" 2>/dev/null; } \
            | LC_ALL=C sort -u | while IFS= read -r c; do
        [ -n "$c" ] && { [ "$DOWNLOAD" -eq 1 ] || [ -f "$DATASET_DIR/$c/Cargo.toml" ]; } && printf '%s\n' "$c"
    done
}

# summarize <csv>: status / error_type counts.
summarize() {
    tail -n +2 "$1" | awk -F, '
        { c[$3]++; if ($6 != "") t[$6]++; n += $5 }
        END {
            for (s in c) printf "    %-14s %d\n", s ":", c[s]
            for (k in t) printf "      error_type %s: %d\n", k, t[k]
            printf "    tests (ok crates): %d\n", n
        }'
}

# summarize_bsan <results csv> <bsan-only csv>: how many plain-compiled crates
# fail only under cargo bsan, by error_type.
summarize_bsan() {
    local built
    built=$(tail -n +2 "$1" | awk -F, '$3 == "ok" || $3 == "list_failed"' | wc -l | tr -d ' ')
    echo "    bsan-only build failures: $(( $(wc -l < "$2") - 1 )) of $built plain-compiled crate(s)"
    bsan_types "$2"
}
bsan_types() {
    tail -n +2 "$1" | awk -F, '{ t[$5]++ } END { for (k in t) printf "      error_type %s: %d\n", k, t[k] }'
}
# finish_rerun <crates rerun>: keep the previous bsan-only CSV as .bak, and
# summarize what the rerun fixed.
finish_rerun() {
    mv "$PREV_CSV" "$BSAN_CSV.bak"
    local still=$(( $(wc -l < "$BSAN_CSV") - 1 ))
    echo "    bsan-only build failures: $still of $1 rerun crate(s) still fail ($(( $1 - still )) now build)"
    bsan_types "$BSAN_CSV"
    echo "    bsan-only:     $BSAN_CSV  (previous: $BSAN_CSV.bak)"
}
# record_fails <checked crates file>: merge BSAN_CSV into BSAN_FAILS_CSV --
# drop the rows of the crates that got their cargo bsan compile this run (one
# per line in the file) or are in BSAN_CSV (--rerun-missing carries the last
# run's rows over), then append BSAN_CSV's rows.
record_fails() {
    local merged
    merged="$(mktemp)"
    {
        echo "$BSAN_HEADER"
        [ -f "$BSAN_FAILS_CSV" ] && tail -n +2 "$BSAN_FAILS_CSV" \
            | awk -F, 'FILENAME == ARGV[1] { c[$0] = 1; next }
                       FILENAME == ARGV[2] { c[$2] = 1; next } !($2 in c)' "$1" "$BSAN_CSV" -
        tail -n +2 "$BSAN_CSV"
    } > "$merged"
    mkdir -p "$(dirname "$BSAN_FAILS_CSV")" && cat "$merged" > "$BSAN_FAILS_CSV" \
        && echo "    appended to:   $BSAN_FAILS_CSV  ($(( $(wc -l < "$BSAN_CSV") - 1 )) row(s))"
    rm -f "${merged:?}"
}

# ------------------------ launcher: submit the jobs ------------------------ #
if [ "$LOCAL" -eq 0 ]; then
    (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3) )) \
        || die "the launcher needs bash >= 4.3 (wait -n)"
    command -v sbatch >/dev/null || die "sbatch not found (run on a login node, or use --local)"
    [ -f "$CONTAINERS_DIR/$IMAGE.sif" ] || die "image not found: $CONTAINERS_DIR/$IMAGE.sif"
    [[ "$CPUS" =~ ^[1-9][0-9]*$ ]] || die "-c must be a positive integer"
    [[ "$PER_JOB" =~ ^[1-9][0-9]*$ ]] || die "-n must be a positive integer"
    JOBS="${JOBS:-$(( CPUS >= 4 ? CPUS / 4 : 1 ))}"
    [[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "JOBS must be a positive integer"
    # -t / -m as run_job.sh takes them: HH or HH:MM; a bare number is GB.
    if [[ "$WALLTIME" =~ ^[0-9]{1,2}$ ]]; then
        SB_TIME="$(( 10#$WALLTIME )):00:00"
    elif [[ "$WALLTIME" =~ ^([0-9]{1,2}):([0-5][0-9])$ ]]; then
        SB_TIME="$(( 10#${BASH_REMATCH[1]} )):${BASH_REMATCH[2]}:00"
    else
        die "-t must be HH or HH:MM (e.g. 8 or 8:30)"
    fi
    [[ "$MEM" =~ ^([0-9]+)([KMGT]?)$ ]] || die "-m must be like 64G, 512M or a bare number (GB)"
    case "${BASH_REMATCH[2]}" in
        K) MEM_MB=$(( 10#${BASH_REMATCH[1]} / 1024 )) ;;
        M) MEM_MB=$(( 10#${BASH_REMATCH[1]} )) ;;
        T) MEM_MB=$(( 10#${BASH_REMATCH[1]} * 1024 * 1024 )) ;;
        *) MEM_MB=$(( 10#${BASH_REMATCH[1]} * 1024 )) ;;
    esac
    # Each of a job's JOBS crates at a time is an srun step with an equal share
    # of its cores and of -m (less 512M for the batch script itself).
    STEP_CPUS=$(( CPUS / JOBS > 0 ? CPUS / JOBS : 1 ))
    STEP_MEM=$(( (MEM_MB - 512) / JOBS ))
    (( STEP_MEM >= 512 )) || die "-m $MEM leaves under 512M per crate at $JOBS crates at a time"

    CRATES=()
    if [ "$RERUN" -eq 1 ]; then
        while IFS= read -r c; do CRATES+=("$c"); done < <(rerun_crates)
    elif [ "$DOWNLOAD" -eq 1 ]; then
        while IFS= read -r c; do CRATES+=("$c"); done < <(printf '%s\n' "${!ALLOW[@]}" | LC_ALL=C sort)
    else
        for d in "$DATASET_DIR"/*/; do
            d="${d%/}"
            case "$(basename "$d")" in _*) continue ;; esac
            [ -f "$d/Cargo.toml" ] && want_crate "$(basename "$d")" && CRATES+=("$(basename "$d")")
        done
    fi
    PREV_UNCHECKED=()
    if [ "$MISSING" -eq 1 ]; then
        # --rerun-missing: just the crates with no row yet. The previous
        # outputs are kept as .bak, and their rows merged back in below.
        [ -s "$RESULTS_CSV" ] || die "--rerun-missing: no results CSV at $RESULTS_CSV"
        mapfile -t CRATES < <(printf '%s\n' ${CRATES[@]+"${CRATES[@]}"} | sed '/^$/d' \
            | grep -vxF -f <(tail -n +2 "$RESULTS_CSV" | cut -d, -f2))
        if [ "${#CRATES[@]}" -eq 0 ]; then
            echo "==> Every selected crate already has a row in $RESULTS_CSV; nothing to do."
            exit 0
        fi
        for f in "$RESULTS_CSV" "$LIST_CSV" "$BSAN_CSV"; do
            if [ -f "$f" ]; then cp "$f" "$f.bak"; else rm -f "$f.bak"; fi
        done
        # The last run's unchecked crates aren't rebuilt, so they stay unchecked.
        [ -f "$UNCHECKED_TXT" ] && mapfile -t PREV_UNCHECKED < <(sed '/^$/d' "$UNCHECKED_TXT")
        echo "==> --rerun-missing: ${#CRATES[@]} crate(s) have no row in $RESULTS_CSV"
    fi
    n=${#CRATES[@]}
    [ "$n" -gt 0 ] || die "no crates (dirs with a Cargo.toml) in $DATASET_DIR"
    NPARTS=$(( (n + PER_JOB - 1) / PER_JOB ))

    # Deal round-robin, so part sizes differ by at most one crate.
    rm -rf "$PARTS_DIR"
    mkdir -p "$PARTS_DIR"
    i=0
    for c in "${CRATES[@]}"; do
        printf '%s\n' "$c" >> "$PARTS_DIR/part-$(( i % NPARTS )).txt"
        i=$((i + 1))
    done
    cp "$SELF" "$DATASET_DIR/_logs/.build_dataset.sh"
    WHOLE_FLAG=""; [ "$WHOLE" -eq 1 ] && WHOLE_FLAG="--whole"
    [ "$DOC" -eq 1 ] && WHOLE_FLAG="$WHOLE_FLAG --doc"
    # The part jobs only need it for the -latest output names.
    [ -n "$SUFFIX" ] && WHOLE_FLAG="$WHOLE_FLAG --$VERSIONS"
    [ "$RERUN" -eq 1 ] && WHOLE_FLAG="$WHOLE_FLAG --rerun-bsan-only"
    [ "$BSAN_ONLY" -eq 1 ] && WHOLE_FLAG="$WHOLE_FLAG --bsan-only"
    [ "$DOWNLOAD" -eq 1 ] && WHOLE_FLAG="$WHOLE_FLAG --download"
    echo "==> Building $n crates in the '$IMAGE' image as $NPARTS job(s) of" \
         "$(( n / NPARTS ))-$(( (n + NPARTS - 1) / NPARTS )) crates" \
         "($CPUS cpus, $JOBS crates at a time, $MEM, ${WALLTIME}h each; at most $MAX_PARALLEL at once)"
    echo "    each crate is its own srun step: $STEP_CPUS cpu(s), capped at ${STEP_MEM}M"

    pids=()
    cleanup() {
        trap - INT TERM
        # Killing sbatch --wait leaves its job running: cancel what was
        # submitted (each submit log starts with its job id), then the waiters.
        local ids
        ids=$(cat "$PARTS_DIR"/submit-*.log 2>/dev/null | grep -oE '^[0-9]+' || true)
        # shellcheck disable=SC2086  # one id per word
        [ -n "$ids" ] && scancel $ids 2>/dev/null
        for p in ${pids[@]+"${pids[@]}"}; do pkill -TERM -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
        exit 130
    }
    trap cleanup INT TERM
    # Job names unique to this launch, so a lost submission is found by name
    # (and an old run's job never is).
    RUN_TAG="$(date +%s)-$$"
    LAUNCH_START="$(date +%Y-%m-%dT%H:%M:%S)"
    # job_by_name <name>: the id of this launch's job of that name, if any.
    job_by_name() {
        sacct -n -X -P --name="$1" -S "$LAUNCH_START" -o JobID 2>/dev/null | grep -oE '^[0-9]+' | head -1
    }
    # wait_job <id>: until sacct says the job ended; 0 if it COMPLETED. sbatch
    # --wait alone isn't trusted: a slurmctld timeout can end it early.
    wait_job() {
        local st
        while :; do
            st=$(sacct -n -X -P -j "$1" -o State 2>/dev/null | head -1)
            case "$st" in
                ""|PENDING|RUNNING|REQUEUED|RESIZING|SUSPENDED|CONFIGURING|COMPLETING) sleep 60 ;;
                COMPLETED) return 0 ;;
                *) echo "job $1 ended $st"; return 1 ;;
            esac
        done
    }
    inflight=0; failed=0
    reap_one() {
        wait -n; [ $? -eq 0 ] || failed=$((failed + 1))
        inflight=$((inflight - 1))
    }
    for (( k = 0; k < NPARTS; k++ )); do
        [ "$inflight" -lt "$MAX_PARALLEL" ] || reap_one
        # The part job runs this script with --node, on the node outside the
        # image; sbatch --wait returns once the job ends, with its exit code.
        # The command goes in a batch script of its own, submitted without
        # arguments: the site's sbatch wrapper re-splits its arguments, which
        # breaks --wrap (and any script argument with a space in it).
        # shellcheck disable=SC2086  # WHOLE_FLAG splits into flags
        printf '#!/bin/bash\n%s\n' "$(printf '%q ' env JOBS="$JOBS" BD_STEP_CPUS="$STEP_CPUS" \
            BD_STEP_MEM="${STEP_MEM}M" BUILD_RUSTFLAGS="$BUILD_RUSTFLAGS" PRIMARY_RUSTFLAGS="$PRIMARY_RUSTFLAGS" \
            BUILD_TIMEOUT="$BUILD_TIMEOUT" \
            bash "$DATASET_DIR/_logs/.build_dataset.sh" --node --part "$k" --image "$IMAGE" \
            $WHOLE_FLAG "$DATASET_DIR")" > "$PARTS_DIR/job-$k.sh"
        # A submission refused for the per-user queue limit (your other jobs
        # count too) is retried every minute until there's room. Once there's
        # a job id, the job's own end state (from sacct) is the result. With
        # no id, sbatch may still have submitted it (a slurmctld timeout loses
        # the reply): it's looked up by name before submitting again.
        (
            log="$PARTS_DIR/submit-$k.log"
            name="build-dataset-$RUN_TAG-$k"
            tries=0
            while :; do
                from=$(( $(wc -l < "$log") + 1 ))   # this attempt's output
                sbatch --wait --parsable --job-name="$name" \
                    --nodes=1 --ntasks="$JOBS" --cpus-per-task="$STEP_CPUS" \
                    --mem="${MEM_MB}M" --time="$SB_TIME" --output="$PARTS_DIR/job-$k.log" \
                    "$PARTS_DIR/job-$k.sh"
                rc=$?
                out=$(tail -n +"$from" "$log")
                id=$(grep -oE '^[0-9]+' <<<"$out" | head -1)
                if [ -z "$id" ] && grep -qiE 'MaxSubmitJob|job submit limit' <<<"$out"; then
                    echo "queue full; retrying in 60s"
                    sleep 60
                    continue
                fi
                if [ -z "$id" ]; then
                    sleep 30   # let accounting catch up with a lost submission
                    id=$(job_by_name "$name")
                    [ -n "$id" ] && echo "$id" && echo "sbatch lost the reply (rc $rc), but job $id was submitted"
                fi
                if [ -n "$id" ]; then
                    wait_job "$id"
                    exit $?
                fi
                tries=$((tries + 1))
                [ "$tries" -lt 5 ] || { echo "no job after $tries submission attempts; giving up"; exit 1; }
                echo "submission failed (rc $rc), no job found; retrying in 60s"
                sleep 60
            done
        ) > "$PARTS_DIR/submit-$k.log" 2>&1 &
        pids+=("$!")
        inflight=$((inflight + 1))
        echo "    [$((k + 1))/$NPARTS] launched part $k ($(wc -l < "$PARTS_DIR/part-$k.txt") crates)"
    done
    while [ "$inflight" -gt 0 ]; do reap_one; done
    trap - INT TERM
    rm -f "$DATASET_DIR/_logs/.build_dataset.sh"

    # Merge the parts' CSVs (the jobs see the dataset dir at its own path, so
    # they landed at the same _logs paths). A part whose job died before writing
    # one is recovered from the per-crate rows in its _state-K dir instead.
    # part_rows <part CSV name> <state file ext>: every part's rows.
    part_rows() {
        local k
        for (( k = 0; k < NPARTS; k++ )); do
            if [ -f "$PARTS_DIR/$1.part-$k.csv" ]; then
                tail -n +2 "$PARTS_DIR/$1.part-$k.csv"
            elif [ -d "$PARTS_DIR/_state-$k" ]; then
                RECOVERED[$k]=1
                find "$PARTS_DIR/_state-$k" -maxdepth 1 -name "*.$2" -exec cat {} + 2>/dev/null
            fi
        done
    }
    # prev_rows <previous CSV> <crate column>: with --rerun-missing, the
    # previous run's rows but those of the crates this run built.
    prev_rows() {
        { [ "$MISSING" -eq 1 ] && [ -f "$1" ]; } || return 0
        tail -n +2 "$1" | awk -F, -v k="$2" 'FILENAME == ARGV[1] { c[$0] = 1; next } !($k in c)' \
            <(printf '%s\n' "${CRATES[@]}") -
    }
    # Crates a dead job never got through the bsan pass: in a part with no
    # bsan-only CSV, listed but without a .bsandone. For a full run only the
    # ones that compiled matter (with --bsan-only, all of them); a rerun keeps
    # their previous rows.
    declare -A RECOVERED=()
    UNCHECKED=()
    for (( k = 0; k < NPARTS; k++ )); do
        [ -f "$PARTS_DIR/bsan-only.part-$k.csv" ] && continue
        while IFS= read -r c; do
            [ -n "$c" ] && [ ! -f "$PARTS_DIR/_state-$k/$c.bsandone" ] || continue
            if [ "$RERUN" -eq 1 ] || [ "$BSAN_ONLY" -eq 1 ]; then
                UNCHECKED+=("$c")
            else
                st=$(cut -d, -f3 "$PARTS_DIR/_state-$k/$c.csv" 2>/dev/null)
                { [ "$st" = ok ] || [ "$st" = list_failed ]; } && UNCHECKED+=("$c")
            fi
        done < "$PARTS_DIR/part-$k.txt"
    done
    UNCHECKED+=(${PREV_UNCHECKED[@]+"${PREV_UNCHECKED[@]}"})
    # Not in a pipeline, so part_rows' RECOVERED entries stick.
    bsan_rows="$(mktemp)"
    part_rows bsan-only bsan > "$bsan_rows"
    prev_rows "$BSAN_CSV.bak" 2 >> "$bsan_rows"
    # A rerun's unchecked crates are still failing as far as anyone knows.
    if [ "$RERUN" -eq 1 ]; then
        for c in ${UNCHECKED[@]+"${UNCHECKED[@]}"}; do
            awk -F, -v c="$c" '$2 == c' "$PREV_CSV"
        done >> "$bsan_rows"
    fi
    {
        echo "$BSAN_HEADER"
        LC_ALL=C sort -t, -k2,2 "$bsan_rows"
    } > "$BSAN_CSV"
    rm -f "${bsan_rows:?}"
    rm -f "${UNCHECKED_TXT:?}"
    # checked_crates: the crates that got their cargo bsan compile -- every
    # part's crates but the unchecked ones, and (in a full run) only those
    # whose plain compile succeeded.
    checked_crates() {
        local k
        for (( k = 0; k < NPARTS; k++ )); do cat "$PARTS_DIR/part-$k.txt"; done \
            | grep -vxF -f <(printf '%s\n' ${UNCHECKED[@]+"${UNCHECKED[@]}"}) \
            | if [ "$RERUN" -eq 1 ] || [ "$BSAN_ONLY" -eq 1 ]; then cat; else
                awk -F, 'FILENAME == ARGV[1] { if ($3 == "ok" || $3 == "list_failed") ok[$2] = 1; next }
                         $0 in ok' "$RESULTS_CSV" -
              fi
    }
    # report_recovery: what came from dead jobs' state dirs, after the summary.
    report_recovery() {
        [ "${#RECOVERED[@]}" -gt 0 ] || [ "${#UNCHECKED[@]}" -gt 0 ] || return 0
        [ "${#RECOVERED[@]}" -gt 0 ] \
            && echo "    ${#RECOVERED[@]} part(s) recovered from their _state dirs (job died before" \
                    "writing all its CSVs): $(printf '%s\n' "${!RECOVERED[@]}" | sort -n | paste -sd' ' -)"
        if [ "${#UNCHECKED[@]}" -gt 0 ]; then
            printf '%s\n' "${UNCHECKED[@]}" | LC_ALL=C sort > "$UNCHECKED_TXT"
            if [ "$BSAN_ONLY" -eq 1 ]; then
                echo "    ${#UNCHECKED[@]} crate(s) never got their cargo bsan compile (job died or download"
                echo "    failed); listed in $UNCHECKED_TXT"
            elif [ "$RERUN" -eq 1 ]; then
                echo "    ${#UNCHECKED[@]} crate(s) never rechecked: kept their previous rows; listed in $UNCHECKED_TXT"
            else
                echo "    ${#UNCHECKED[@]} plain-compiled crate(s) never got their cargo bsan compile, so the"
                echo "    bsan-only CSV can't say whether they fail; listed in $UNCHECKED_TXT"
            fi
        fi
    }
    if [ "$RERUN" -eq 1 ]; then
        echo
        echo "==> Done (cargo bsan rerun of $n crates)."
        finish_rerun "$n"
        report_recovery
        [ "$failed" -eq 0 ] || echo "    $failed job(s) exited non-zero; see $PARTS_DIR/job-*.log"
        checked="$(mktemp)"; checked_crates > "$checked"; record_fails "$checked"; rm -f "${checked:?}"
        [ "$failed" -eq 0 ]
        exit $?
    fi
    if [ "$BSAN_ONLY" -eq 1 ]; then
        echo
        echo "==> Done (cargo bsan only, $n crates)."
        echo "    bsan build failures: $(( $(wc -l < "$BSAN_CSV") - 1 )) of $n crate(s)"
        bsan_types "$BSAN_CSV"
        echo "    bsan-only:     $BSAN_CSV"
        report_recovery
        [ "$failed" -eq 0 ] || echo "    $failed job(s) exited non-zero; see $PARTS_DIR/job-*.log"
        checked="$(mktemp)"; checked_crates > "$checked"; record_fails "$checked"; rm -f "${checked:?}"
        [ "$failed" -eq 0 ]
        exit $?
    fi
    for kind in "build-$IMAGE:csv:$RESULTS_CSV:2" "list:list:$LIST_CSV:1"; do
        IFS=: read -r pname ext out key <<<"$kind"
        rows_tmp="$(mktemp)"
        part_rows "$pname" "$ext" > "$rows_tmp"
        prev_rows "$out.bak" "$key" >> "$rows_tmp"
        {
            if [ "$pname" = list ]; then echo "crate,tests"
            else echo "build,crate,status,compile_seconds,tests,error_type,error,timestamp"; fi
            LC_ALL=C sort -t, -k"$key","$key" "$rows_tmp"
        } > "$out"
        rm -f "${rows_tmp:?}"
    done
    # This run's rows (with --rerun-missing the CSV has the last run's too).
    rows=$(( $(wc -l < "$RESULTS_CSV") - 1 - $(prev_rows "$RESULTS_CSV.bak" 2 | wc -l) ))

    echo
    if [ "$MISSING" -eq 1 ]; then
        echo "==> Done ($rows/$n missing crates now have a row; merged into the previous" \
             "results, kept as .bak: $(( $(wc -l < "$RESULTS_CSV") - 1 )) rows in all)."
    else
        echo "==> Done ($rows/$n crates have a row)."
    fi
    summarize "$RESULTS_CSV"
    summarize_bsan "$RESULTS_CSV" "$BSAN_CSV"
    echo "    results:       $RESULTS_CSV"
    echo "    test list:     $LIST_CSV"
    echo "    bsan-only:     $BSAN_CSV"
    report_recovery
    if [ "$rows" -lt "$n" ]; then
        echo "    $(( n - rows )) crate(s) have no row (job killed / walltime); see $PARTS_DIR/job-*.log"
    fi
    [ "$failed" -eq 0 ] || echo "    $failed job(s) exited non-zero; see $PARTS_DIR/job-*.log"
    out="$OUTPUTS_DIR/$IMAGE-$DS_NAME-build$SUFFIX.csv"
    mkdir -p "$OUTPUTS_DIR" && cp "$RESULTS_CSV" "$out" && echo "    copied to:     $out"
    out="$OUTPUTS_DIR/${DS_NAME}_list$SUFFIX.csv"
    cp "$LIST_CSV" "$out" && echo "    copied to:     $out"
    checked="$(mktemp)"; checked_crates > "$checked"; record_fails "$checked"; rm -f "${checked:?}"
    if [ "$SUFFIX" = -latest ]; then
        out="$GROUP/scripts/$DS_NAME-tests-latest.csv"
        [ -f "$out" ] && cp "$out" "$out.bak" && echo "    previous kept: $out.bak"
        cp "$LIST_CSV" "$out" && echo "    tests list:    $out  (run_eval_dataset.sh --tests $out ...)"
    fi
    [ "$failed" -eq 0 ]
    exit $?
fi

# ---------------------------- --local: do builds ---------------------------- #
# (On a part job these run in the image, where the workers will.)
in_image() {
    if [ "$NODE" -eq 1 ]; then singularity exec --cleanenv "$BD_SIF" sh -c "$1" >/dev/null 2>&1
    else sh -c "$1" >/dev/null 2>&1; fi
}
in_image 'command -v cargo' || die "cargo is required"
in_image 'command -v cargo-bsan' || die "cargo-bsan is required (run in the experimental-bsan image)"
in_image 'command -v timeout' || die "timeout (coreutils) is required, for BUILD_TIMEOUT"
if [ "$DOWNLOAD" -eq 1 ]; then
    in_image 'command -v curl && command -v tar' || die "downloading crates needs curl and tar"
    mkdir -p "$CRATE_ROOT" || die "can't create $CRATE_ROOT"
fi
JOBS="${JOBS:-1}"
TARGET_BASE="${CARGO_TARGET_DIR:-}"
COMPILE="cargo test --tests"
[ "$WHOLE" -eq 1 ] && COMPILE="cargo test"
export CARGO_TERM_COLOR=never

LOG_DIR="$DATASET_DIR/_logs"
STATE_DIR="$LOG_DIR/_build_dataset_state"   # per-crate rows, merged + removed below
if [ -n "$PART" ]; then
    # One job of several: its own crate list, state dir and CSV, so parts
    # running at once never touch each other's files.
    PART_LIST="$PARTS_DIR/part-$PART.txt"
    [ -f "$PART_LIST" ] || die "no crate list for part $PART at $PART_LIST"
    STATE_DIR="$PARTS_DIR/_state-$PART"
    RESULTS_CSV="$PARTS_DIR/build-$IMAGE.part-$PART.csv"
    LIST_CSV="$PARTS_DIR/list.part-$PART.csv"
    BSAN_CSV="$PARTS_DIR/bsan-only.part-$PART.csv"
fi
rm -rf "$STATE_DIR"                         # fresh check every run
mkdir -p "$STATE_DIR"

export SELF BUILD_RUSTFLAGS PRIMARY_RUSTFLAGS TARGET_BASE STATE_DIR IMAGE COMPILE DOC RERUN BSAN_ONLY PREV_CSV \
    DOWNLOAD CRATE_LOG_DIR MAIN_RESULTS_CSV BUILD_TIMEOUT

# Workers: here directly, or on a part job each as its own srun step (see
# step mode), which needs the worker environment written out for the image.
WORKER=("$SELF")
if [ "$NODE" -eq 1 ]; then
    WORKER+=(--step)
    BD_ENV="$BD_SCRATCH/worker.env"
    # Single-quoted: singularity's env-file parser keeps backslash escapes
    # (bash's %q) literally, so COMPILE would become `cargo\ test\ --tests`.
    for v in SELF BUILD_RUSTFLAGS PRIMARY_RUSTFLAGS TARGET_BASE STATE_DIR IMAGE COMPILE DOC RERUN \
            BSAN_ONLY PREV_CSV DOWNLOAD CRATE_LOG_DIR MAIN_RESULTS_CSV BUILD_TIMEOUT CARGO_TERM_COLOR \
            http_proxy https_proxy HTTP_PROXY HTTPS_PROXY; do
        [[ "${!v:-}" != *\'* ]] || die "$v contains a single quote: $v=${!v}"
        printf "%s='%s'\n" "$v" "${!v:-}"
    done > "$BD_ENV"
    printf "CARGO_HOME='%s'\nCARGO_BUILD_JOBS='%s'\n" "$BD_SCRATCH/home" "$BD_STEP_CPUS" >> "$BD_ENV"
    BD_DATASET_DIR="$DATASET_DIR"
    export BD_SIF BD_SCRATCH BD_ENV BD_STEP_CPUS BD_STEP_MEM BD_DATASET_DIR
fi

# ------------------------------ build each crate ---------------------------- #
crates="$(mktemp)"
if [ -n "$PART" ]; then
    while IFS= read -r c; do
        [ -n "$c" ] && { [ "$DOWNLOAD" -eq 1 ] || [ -f "$CRATE_ROOT/$c/Cargo.toml" ]; } \
            && printf '%s\0' "$CRATE_ROOT/$c"
    done < "$PART_LIST"
elif [ "$RERUN" -eq 1 ]; then
    rerun_crates | while IFS= read -r c; do printf '%s\0' "$CRATE_ROOT/$c"; done
elif [ "$DOWNLOAD" -eq 1 ]; then
    printf '%s\n' "${!ALLOW[@]}" | LC_ALL=C sort \
        | while IFS= read -r c; do printf '%s\0' "$CRATE_ROOT/$c"; done
else
    for d in "$DATASET_DIR"/*/; do
        d="${d%/}"
        case "$(basename "$d")" in _*) continue ;; esac
        [ -f "$d/Cargo.toml" ] && want_crate "$(basename "$d")" && printf '%s\0' "$d"
    done
fi > "$crates"
n="$(tr -cd '\0' < "$crates" | wc -c | tr -d ' ')"
if [ "$RERUN" -eq 1 ]; then
    echo "==> Rerunning cargo bsan ${COMPILE#cargo } --no-run on $n crates in $DATASET_DIR with $JOBS worker(s) ..."
elif [ "$BSAN_ONLY" -eq 1 ]; then
    echo "==> cargo bsan ${COMPILE#cargo } --no-run only, on $n crates in $DATASET_DIR with $JOBS worker(s) ..."
else
echo "==> Building $n crates in $DATASET_DIR with $JOBS worker(s):" \
     "$COMPILE --no-run (RUSTFLAGS=\"$BUILD_RUSTFLAGS\"," \
     "crate under test +\"$PRIMARY_RUSTFLAGS\"), then list tests$([ "$DOC" -eq 1 ] && echo ' (with doc tests)'), then cargo bsan ${COMPILE#cargo } --no-run ..."
fi
# Pass 1, plain (not with --rerun-bsan-only or --bsan-only), then its outputs, so the
# results and test list are written before any cargo bsan compile starts and
# survive a job killed during pass 2. (xargs runs the command once even on
# empty input.)
if [ "$RERUN" -eq 0 ] && [ "$BSAN_ONLY" -eq 0 ]; then
    [ "$n" -gt 0 ] && xargs -0 -n 1 -P "$JOBS" "${WORKER[@]}" --worker < "$crates"
    {
        echo "build,crate,status,compile_seconds,tests,error_type,error,timestamp"
        find "$STATE_DIR" -maxdepth 1 -name '*.csv' -exec cat {} + 2>/dev/null | LC_ALL=C sort -t, -k2,2
    } > "$RESULTS_CSV"
    {
        echo "crate,tests"
        find "$STATE_DIR" -maxdepth 1 -name '*.list' -exec cat {} + 2>/dev/null | LC_ALL=C sort -t, -k1,1
    } > "$LIST_CSV"
    echo "==> Plain pass done; results and test list written. Now cargo bsan ${COMPILE#cargo } --no-run ..."
fi
# Pass 2, cargo bsan.
[ "$n" -gt 0 ] && xargs -0 -n 1 -P "$JOBS" "${WORKER[@]}" --worker-bsan < "$crates"
rm -f "$crates"

# ---------------------------------- outputs --------------------------------- #
{
    echo "$BSAN_HEADER"
    find "$STATE_DIR" -maxdepth 1 -name '*.bsan' -exec cat {} + 2>/dev/null | LC_ALL=C sort -t, -k2,2
} > "$BSAN_CSV"
if [ "$RERUN" -eq 1 ]; then
    rm -rf "$STATE_DIR"
    # A part job leaves PREV_CSV and the summary to the launcher.
    [ -n "$PART" ] && exit 0
    echo
    echo "==> Done."
    finish_rerun "$n"
    rm -f "${UNCHECKED_TXT:?}"   # every one of them was just rechecked
    exit 0
fi
rm -rf "$STATE_DIR"
if [ "$BSAN_ONLY" -eq 1 ]; then
    [ -n "$PART" ] && exit 0
    echo
    echo "==> Done."
    echo "    bsan build failures: $(( $(wc -l < "$BSAN_CSV") - 1 )) of $n crate(s)"
    bsan_types "$BSAN_CSV"
    echo "    bsan-only:     $BSAN_CSV"
    exit 0
fi

echo
echo "==> Done."
summarize "$RESULTS_CSV"
summarize_bsan "$RESULTS_CSV" "$BSAN_CSV"
echo "    results:       $RESULTS_CSV"
echo "    test list:     $LIST_CSV"
echo "    bsan-only:     $BSAN_CSV"
