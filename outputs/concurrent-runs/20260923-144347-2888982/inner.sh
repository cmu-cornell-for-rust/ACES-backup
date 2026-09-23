#!/bin/bash
# Compile the crate once, then time its WHOLE test list in a single concurrent
# `cargo bsan test` invocation. Streams one CSV row per crate (plus the
# calibration row) into this worker's shard.
#
# -f (noglob): test names are interpolated UNQUOTED into the pre-run command so
# the shell splits them into separate arguments, and a name containing a glob
# metacharacter must not then be matched against the crate directory.
set -uf

export BSAN_OPTIONS="$HF_BSAN_OPTIONS"
RUN="cargo bsan test --tests"

# --cfg=miri so this run selects the same cfg(miri) code and the same test set
# as the miri/per-test runs (#[cfg(not(miri))] compiled out, #[cfg_attr(miri,
# ignore)] ignored). --cap-lints=warn demotes the crate's own deny/forbid lints
# so a crate that would otherwise fail to build still compiles and gets timed.
# EXPORTED rather than prefixed onto $RUN because $RUN is handed to hyperfine,
# which runs with -N (no shell) -- a "VAR=value cmd" prefix would be taken as
# the program name there, not as an assignment.
export RUSTFLAGS="--cfg=miri --cap-lints=warn"
echo "RUSTFLAGS=[$RUSTFLAGS]"

# libtest's --test-threads is a HARNESS flag, so it goes after the `--`, before
# --exact. Unlike the per-test script this is never empty: running the tests
# concurrently is the whole measurement.
HARNESS="--test-threads=$HF_TEST_THREADS"
echo "HARNESS=[$HARNESS]"

FAIL_LOG_LINES=200

ts() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }
# `wc -l < f` pads its count on some platforms and these counts go into the
# CSV, so strip whitespace rather than ship " 5" as a field.
count_lines() { wc -l < "$1" | tr -d '[:space:]'; }
# row <test> <status> <compile> <mean> <stddev> <median> <min> <max>
#     <tests_requested> <tests_run> <excluded_failed>
row() {
    line="$HF_BUILD,$HF_CRATE,$1,$2,$3,$4,$5,$6,$7,$8,$HF_RUNS,$(ts),$HF_JOBID,$9,${10},$HF_TEST_THREADS,${11}"
    echo "$line" >> "$HF_SHARD"
    echo "CSVROW:$line"
}

LIST=$(mktemp)                      # the surviving (passing) test list
cp "$HF_TESTFILE" "$LIST"
NREQ=$(count_lines "$LIST")
EXCLUDED=0
NRUN=0

cargo clean >/dev/null 2>&1 || true
if ! cargo fetch; then
    row "__concurrent__" fetch_failed "" "" "" "" "" "" "$NREQ" 0 0
    exit 1
fi

cstart=$(date +%s%3N)
if ! $RUN --no-run; then
    row "__concurrent__" build_failed "" "" "" "" "" "" "$NREQ" 0 0
    exit 1
fi
cms=$(( $(date +%s%3N) - cstart ))
compile=$(printf '%d.%03d' $(( cms / 1000 )) $(( cms % 1000 )))

# --- Calibration: what an invocation costs before any test body runs --------
# The same command with a filter matching nothing still pays cargo's freshness
# check and starts every test binary in the crate, running zero tests -- i.e.
# exactly the constant the suite timing below also carries, but here paid ONCE
# for the crate rather than once per test. Written as its own row rather than
# subtracted, so the CSV keeps raw measurements.
CALIB_FILTER=__hyperfine_calibration_no_such_test__
hfcsv=$(mktemp)
if hyperfine --style basic -N --warmup "$HF_WARMUP" --runs "$HF_RUNS" \
        --export-csv "$hfcsv" "$RUN -- $HARNESS --exact $CALIB_FILTER"; then
    read -r cmean cstddev cmedian cmin cmax <<EOV
$(tail -n1 "$hfcsv" | awk -F, '{print $(NF-6), $(NF-5), $(NF-4), $(NF-1), $NF}')
EOV
    echo "calibration: $HF_CRATE -> ${cmedian}s per invocation (0 tests)"
    row "__calibration__" calibration "$compile" \
        "$cmean" "$cstddev" "$cmedian" "$cmin" "$cmax" 0 0 0
fi
rm -f "$hfcsv"

# --- Pre-run: warm caches, and drop whatever fails --------------------------
# hyperfine abandons a command that exits non-zero, so a single failing test
# would otherwise cost the crate its whole row. Each pass runs the current list
# untimed; on failure the names in libtest's `failures:` block are taken out
# and the pass repeats. Intersecting those names with the requested list means
# captured test output can never invent one.
#
# libtest prints two `failures:` blocks per binary: the first introduces the
# "---- <name> stdout ----" dumps (which do not match the indented-bare-name
# pattern, so the collector switches off again immediately), the second is the
# name list proper.
parse_failures() {
    awk '
        /^failures:[[:space:]]*$/ { inlist = 1; next }
        inlist && /^[[:space:]]+[^[:space:]]+[[:space:]]*$/ {
            gsub(/[[:space:]]/, "", $0); print; next
        }
        { inlist = 0 }
    ' "$1" | sort -u
}

prerun_ok=0
pass=0
while (( pass < HF_MAX_PRERUNS )); do
    pass=$(( pass + 1 ))
    nleft=$(count_lines "$LIST")
    (( nleft > 0 )) || break
    FILTERS=$(tr '\n' ' ' < "$LIST")
    runlog=$(mktemp)
    echo "pre-run pass $pass: $HF_CRATE, $nleft test(s), $HARNESS"
    $RUN -- $HARNESS --exact $FILTERS > "$runlog" 2>&1; rc=$?
    NRUN=$(grep -aoE '^running [0-9]+ test' "$runlog" | grep -oE '[0-9]+' \
           | awk '{s+=$1} END{print s+0}')
    if (( rc == 0 )); then
        prerun_ok=1
        rm -f "$runlog"
        break
    fi
    # The dropped tests' output -- the panic message, the BSAN report,
    # libtest's `failures:` summary -- exists nowhere else, so it goes in the
    # crate log. Tail, not head: the diagnosis is at the end, the head is
    # per-binary "running N tests" noise.
    nlines=$(count_lines "$runlog")
    echo "--- output: $HF_CRATE pass $pass (exit $rc, $NRUN test(s) ran) ---"
    if (( nlines > FAIL_LOG_LINES )); then
        echo "[... $(( nlines - FAIL_LOG_LINES )) earlier line(s) omitted ...]"
    fi
    tail -n "$FAIL_LOG_LINES" "$runlog"
    echo "--- end output: $HF_CRATE pass $pass ---"

    names=$(mktemp); confirmed=$(mktemp)
    parse_failures "$runlog" > "$names"
    grep -Fxf "$names" "$LIST" > "$confirmed" || true
    nfail=$(count_lines "$confirmed")
    rm -f "$runlog" "$names"
    if (( nfail == 0 )); then
        # Nothing attributable: a process abort (a BSAN report can take the
        # whole binary down, and with it every test in flight), a harness
        # error, a stale build. Dropping tests cannot fix that.
        echo "pre-run failed with no attributable test: $HF_CRATE"
        rm -f "$confirmed"
        row "__concurrent__" prerun_failed "$compile" "" "" "" "" "" \
            "$NREQ" "$NRUN" "$EXCLUDED"
        exit 1
    fi
    echo "dropping $nfail failing test(s) from $HF_CRATE:"
    sed 's/^/  /' "$confirmed"
    grep -Fxv -f "$confirmed" "$LIST" > "$LIST.next" || true
    mv "$LIST.next" "$LIST"
    EXCLUDED=$(( EXCLUDED + nfail ))
    rm -f "$confirmed"
done

nleft=$(count_lines "$LIST")
if (( nleft == 0 )); then
    row "__concurrent__" all_failed "$compile" "" "" "" "" "" "$NREQ" 0 "$EXCLUDED"
    exit 1
fi
if (( prerun_ok == 0 )); then
    echo "still failing after $HF_MAX_PRERUNS pre-run pass(es): $HF_CRATE"
    row "__concurrent__" prerun_failed "$compile" "" "" "" "" "" \
        "$NREQ" "$NRUN" "$EXCLUDED"
    exit 1
fi

# NRUN counts every "running N tests" line, so a name present in several
# binaries inflates it -- fewer tests run than asked for is the signal that
# matters: a stale test list, or a libtest too old to take more than one
# --exact filter (in which case NRUN collapses to ~1 and the row must not be
# read as a suite timing).
status=success
if (( NRUN < nleft )); then
    status=partial_match
    echo "WARNING: $HF_CRATE asked for $nleft test(s) but libtest ran $NRUN"
fi

# --- The measurement --------------------------------------------------------
FILTERS=$(tr '\n' ' ' < "$LIST")
hfcsv=$(mktemp)
if hyperfine --style basic -N --warmup "$HF_WARMUP" --runs "$HF_RUNS" \
        --export-csv "$hfcsv" "$RUN -- $HARNESS --exact $FILTERS"; then
    # Export columns are command,mean,stddev,median,user,system,min,max --
    # counted from the end so a comma in the command column cannot shift them.
    read -r mean stddev median minv maxv <<EOV
$(tail -n1 "$hfcsv" | awk -F, '{print $(NF-6), $(NF-5), $(NF-4), $(NF-1), $NF}')
EOV
    echo "result: $HF_CRATE -> $status (mean ${mean}s for $nleft test(s) on $HF_TEST_THREADS thread(s))"
    row "__concurrent__" "$status" "$compile" \
        "$mean" "$stddev" "$median" "$minv" "$maxv" "$NREQ" "$NRUN" "$EXCLUDED"
else
    echo "result: $HF_CRATE -> bench_failed"
    row "__concurrent__" bench_failed "$compile" "" "" "" "" "" \
        "$NREQ" "$NRUN" "$EXCLUDED"
fi
rm -f "$hfcsv" "$LIST"
