#!/bin/bash
# Compile the crate, list its tests, then run and time each test once.
# Streams one row per test (or one test-less row for a crate that never got
# that far) straight into $EV_SHARD.
set -u

case "$EV_MODE" in
    rust) RUN="cargo test --tests" ;;
    miri) export MIRIFLAGS="$EV_MIRIFLAGS";   RUN="cargo miri test --tests" ;;
    bsan) export BSAN_OPTIONS="$EV_BSAN_OPTIONS"; RUN="cargo bsan test --tests"
          # Source locations in BSAN reports.
          export BSAN_SYMBOLIZER="$EV_BSAN_SYMBOLIZER"
          [ -x "$BSAN_SYMBOLIZER" ] \
              || echo "warning: BSAN_SYMBOLIZER $BSAN_SYMBOLIZER is not executable; reports will lack source locations" ;;
    *) echo "Error: bad EV_MODE '$EV_MODE'" >&2; exit 1 ;;
esac

# --cfg=miri so every mode selects the same code and test set, --cap-lints=warn
# so a crate's own deny lints don't fail it. In rust/bsan mode --cfg=miri goes
# on the crate under test only: under cfg(miri), dependencies like backtrace
# call Miri-only extern fns (miri_backtrace_size, ...) that fail to link
# natively. rustc-cfg-miri.sh adds it, standing in for rustc as RUSTC (plain
# cargo) and as BSAN_ORIG_RUSTC (cargo bsan, which overrides RUSTC and
# RUSTC_WRAPPER but runs that as its rustc). Miri sets cfg(miri) on every
# crate and provides those fns, so miri mode keeps the flag in RUSTFLAGS.
if [ "$EV_MODE" = miri ]; then
    export RUSTFLAGS="--cfg=miri --cap-lints=warn"
else
    export RUSTFLAGS="--cap-lints=warn"
    EV_REAL_RUSTC=$(command -v rustc) || { echo "Error: rustc not found" >&2; exit 1; }
    export EV_REAL_RUSTC
    export RUSTC="$(dirname "$0")/rustc-cfg-miri.sh"
    export BSAN_ORIG_RUSTC="$RUSTC"
fi
# rustdoc takes RUSTDOCFLAGS, not RUSTFLAGS, and only for the crate under
# test, so doc tests get --cfg=miri there in every mode.
export RUSTDOCFLAGS="--cfg=miri --cap-lints=warn"
echo "RUSTFLAGS=[$RUSTFLAGS]${RUSTC:+ RUSTC=[$RUSTC]}"

# Doc tests (only from a test list made with build_dataset.sh / list_tests.sh
# --doc) arrive as "doc:<name>#<filter>[#<skip>...]", every part with
# % , ; space ' " # percent-encoded. rustdoc splits test args on whitespace,
# so one can't be picked by its full name with --exact; `<filter> --skip
# <skip>...` (substring matches) selects exactly it instead. As in
# run_bench_dataset.sh.
DOC_RUN="${RUN% --tests} --doc"
pct_decode() {
    printf '%s' "$1" | sed -e 's/%2C/,/g' -e 's/%3B/;/g' -e 's/%20/ /g' \
        -e "s/%27/'/g" -e 's/%22/"/g' -e 's/%23/#/g' -e 's/%25/%/g'
}

HARNESS=()
[ -n "${EV_TEST_THREADS:-}" ] && HARNESS=(--test-threads="$EV_TEST_THREADS")

# --test-timeout: coreutils `timeout` signals the whole process group, so the
# test binaries cargo started die with it. Exits 124 (TERM) or 137 (-k KILL).
LIMIT=()
[ -n "${EV_TEST_TIMEOUT:-}" ] && LIMIT=(timeout -k 30 "$EV_TEST_TIMEOUT")

FAIL_LOG_LINES=200

ts() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }
now_ms() { date +%s%3N; }
secs() { printf '%d.%03d' $(( $1 / 1000 )) $(( $1 % 1000 )); }

# classify <output file>: sets ekind/emsg. Same patterns, same first-match
# order, as run_bench_dataset.sh and analysis/failure_logs.py -- keep in sync.
classify() {
    ekind=other; emsg=""
    local kp
    for kp in 'rustc|error\[E[0-9]+\]' 'linker|rust-lld' 'oom|SIGKILL' \
              'gc|ERROR: BorrowSanitizer: garbage collection' \
              'crash|BorrowSanitizer:DEADLYSIGNAL' \
              'bsan|error: Undefined Behavior:' 'panic|panicked at'; do
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

csvq() { [ -n "$1" ] && printf '"%s"' "${1//\"/\"\"}"; }

# row <test> <status> <compile_s> <run_s> [<error_type> <error>]
# Test names are Rust paths, so they never contain a comma.
row() {
    line="$EV_BUILD,$EV_CRATE,$1,$2,$3,$4,$(ts),$EV_JOBID,${5:-},$(csvq "${6:-}")"
    echo "$line" >> "$EV_SHARD"
    echo "CSVROW:$line"
}

# dump_output <label> <rc> <file>: the tail of a failing command's output into
# the crate log, where the panic / UB report / failures: summary lives.
dump_output() {
    local nlines
    nlines=$(wc -l < "$3")
    echo "--- output: $EV_CRATE :: $1 (exit $2) ---"
    if [ "$nlines" -gt "$FAIL_LOG_LINES" ]; then
        echo "[... $(( nlines - FAIL_LOG_LINES )) earlier line(s) omitted ...]"
    fi
    tail -n "$FAIL_LOG_LINES" "$3"
    echo "--- end output: $EV_CRATE :: $1 ---"
}

ntests_ran() {
    grep -aoE '^running [0-9]+ test' "$1" | grep -oE '[0-9]+' | awk '{s+=$1} END{print s+0}'
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# ── fetch ──
cargo fetch < /dev/null > "$tmp/out" 2>&1; rc=$?
cat "$tmp/out"
if [ "$rc" -ne 0 ]; then
    classify "$tmp/out"
    row "" fetch_failed "" "" "$ekind" "$emsg"
    exit 1
fi

# ── compile ──
cstart=$(now_ms)
$RUN --no-run < /dev/null > "$tmp/out" 2>&1; rc=$?
compile=$(secs $(( $(now_ms) - cstart )))
cat "$tmp/out"
if [ "$rc" -ne 0 ]; then
    classify "$tmp/out"
    row "" build_failed "$compile" "" "$ekind" "$emsg"
    exit 1
fi
echo "compiled: $EV_CRATE in ${compile}s"

# ── tests: from the tests CSV, in its order ──
cp "$EV_TESTS" "$tmp/tests"
echo "tests: $EV_CRATE -> $(wc -l < "$tmp/tests" | tr -d ' ') from the tests CSV"

# ── each test, once ──
while IFS= read -r t; do
    [ -n "$t" ] || continue
    if [ "${t#doc:}" != "$t" ]; then
        # The run includes rustdoc collecting the crate's doc tests and
        # compiling this one's snippet: neither is built by --no-run.
        IFS='#' read -ra dparts <<< "${t#doc:}"
        targs=( "$(pct_decode "${dparts[1]}")" )
        for sk in "${dparts[@]:2}"; do targs+=( --skip "$(pct_decode "$sk")" ); done
        trun=$DOC_RUN
    else
        targs=( --exact "$t" )
        trun=$RUN
    fi
    rstart=$(now_ms)
    ${LIMIT[@]+"${LIMIT[@]}"} $trun -- ${HARNESS[@]+"${HARNESS[@]}"} "${targs[@]}" \
        < /dev/null > "$tmp/out" 2>&1; rc=$?
    run=$(secs $(( $(now_ms) - rstart )))
    nrun=$(ntests_ran "$tmp/out")
    ekind=""; emsg=""
    if [ "${#LIMIT[@]}" -gt 0 ] && { [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; }; then
        status=timeout
    elif [ "$nrun" -eq 0 ]; then
        status=no_match
    elif [ "$rc" -ne 0 ]; then
        status=test_failed
    else
        status=success
    fi
    [ "$rc" -ne 0 ] && classify "$tmp/out"
    if [ "$status" = timeout ]; then
        # A fixed message, not whatever the killed run last printed (which
        # classify could mistake for e.g. a panic, or oom on the -k SIGKILL).
        ekind=timeout
        emsg="test timed out after $EV_TEST_TIMEOUT (--test-timeout; killed by $([ "$rc" -eq 137 ] && echo SIGKILL || echo SIGTERM))"
        echo "$emsg" >> "$tmp/out"
    fi
    [ "$status" != success ] && dump_output "$t" "$rc" "$tmp/out"
    echo "result: $EV_CRATE :: $t -> $status (${run}s)${ekind:+ [$ekind]}"
    row "$t" "$status" "$compile" "$run" "$ekind" "$emsg"
done < "$tmp/tests"
