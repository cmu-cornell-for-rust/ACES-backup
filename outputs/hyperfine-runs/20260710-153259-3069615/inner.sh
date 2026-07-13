#!/bin/bash
# Compile the crate once, then classify + hyperfine each test in HF_TESTFILE.
# Emits one CSVROW: line per test (or a single test-less row on fetch/build
# failure) for the worker to harvest from the log.
set -u

case "$HF_MODE" in
    rust) RUN="cargo test --tests" ;;
    miri) export MIRIFLAGS="$HF_MIRIFLAGS";   RUN="cargo miri test --tests" ;;
    bsan) export BSAN_OPTIONS="$HF_BSAN_OPTIONS"; RUN="cargo bsan test --tests" ;;
    *) echo "Error: bad HF_MODE '$HF_MODE'" >&2; exit 1 ;;
esac

ts() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }
# row <test> <status> <compile> <mean> <stddev> <median> <min> <max>
row() {
    echo "CSVROW:$HF_BUILD,$HF_CRATE,$1,$2,$3,$4,$5,$6,$7,$8,$HF_RUNS,$(ts),$HF_JOBID"
}

cargo clean >/dev/null 2>&1 || true
if ! cargo fetch; then
    row "" fetch_failed "" "" "" "" "" ""
    exit 1
fi

cstart=$(date +%s%3N)
if ! $RUN --no-run; then
    row "" build_failed "" "" "" "" "" ""
    exit 1
fi
cms=$(( $(date +%s%3N) - cstart ))
compile=$(printf '%d.%03d' $(( cms / 1000 )) $(( cms % 1000 )))

while IFS= read -r t; do
    [ -n "$t" ] || continue
    # Untimed pre-run: classifies the test and warms caches. no_match means the
    # --exact filter ran 0 tests everywhere (stale test list).
    runlog=$(mktemp)
    $RUN -- --exact "$t" > "$runlog" 2>&1; rc=$?
    nrun=$(grep -aoE '^running [0-9]+ test' "$runlog" | grep -oE '[0-9]+' | awk '{s+=$1} END{print s+0}')
    rm -f "$runlog"
    status=""
    if [ "$nrun" -eq 0 ]; then status=no_match
    elif [ "$rc" -ne 0 ]; then status=test_failed
    fi
    mean=""; stddev=""; median=""; minv=""; maxv=""
    if [ -z "$status" ]; then
        hfcsv=$(mktemp)
        # -N: exec directly, no intermediate shell. Export columns are
        # command,mean,stddev,median,user,system,min,max -- counted from the
        # end so a comma in the command column can never shift them.
        if hyperfine --style basic -N --warmup "$HF_WARMUP" --runs "$HF_RUNS" \
                --export-csv "$hfcsv" "$RUN -- --exact $t"; then
            read -r mean stddev median minv maxv <<EOV
$(tail -n1 "$hfcsv" | awk -F, '{print $(NF-6), $(NF-5), $(NF-4), $(NF-1), $NF}')
EOV
            status=success
        else
            status=bench_failed
        fi
        rm -f "$hfcsv"
    fi
    echo "result: $HF_CRATE :: $t -> $status${mean:+ (mean ${mean}s)}"
    row "$t" "$status" "$compile" "$mean" "$stddev" "$median" "$minv" "$maxv"
done < "$HF_TESTFILE"
