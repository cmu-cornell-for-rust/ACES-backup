#!/usr/bin/env bash
#
# shards_to_csv.sh
#
#   Merges a run dir's per-worker shard CSVs into one CSV with a header. Use it
#   when the orchestrator died before its own merge step. Works for the
#   streaming runners, which keep shards under <rundir>/shards/ with no header:
#       run_bench_dataset.sh     <outputs>/hyperfine-runs/<runid>/
#       run_bench_concurrent.sh  <outputs>/concurrent-runs/<runid>/
#       profile_bsan_dataset.sh  <outputs>/profile-runs/<runid>/
#       run_eval_dataset.sh      <outputs>/eval-runs/<runid>/
#   The header comes from the runner type, taken from the run dir's parent
#   (hyperfine-runs/...), or else from the first row's column count.
#
#   Exact duplicate rows are dropped; row order is otherwise kept.
#
# Usage:
#   ./shards_to_csv.sh <RUN_DIR> [OUT_CSV] [--append]
#
#   RUN_DIR   the run dir, or its shards/ dir
#   OUT_CSV   default: <RUN_DIR>/merged.csv  ("-" = stdout)
#   --append  append rows to an existing OUT_CSV (e.g. the master CSV) instead
#             of overwriting it; its header must match the runner's
#
# Output columns (by runner):
#   hyperfine   build,crate,test,status,compile_seconds,mean_s,stddev_s,median_s,min_s,max_s,runs,timestamp,job_id,error_type,error
#   concurrent  build,crate,test,status,compile_seconds,mean_s,stddev_s,median_s,min_s,max_s,runs,timestamp,job_id,tests_requested,tests_run,test_threads,excluded_failed
#   profile     build,crate,test,status,compile_seconds,run_seconds,timestamp,job_id
#   eval        build,crate,test,status,compile_seconds,run_seconds,timestamp,job_id,error_type,error

set -uo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

APPEND=0
ARGS=()
for a in "$@"; do
    case "$a" in
        --append) APPEND=1 ;;
        *)        ARGS+=("$a") ;;
    esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

[ "$#" -ge 1 ] || { sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

RUN_DIR="${1%/}"
[ "$(basename "$RUN_DIR")" = shards ] && RUN_DIR="$(dirname "$RUN_DIR")"
SHARD_DIR="$RUN_DIR/shards"
[ -d "$SHARD_DIR" ] || die "$SHARD_DIR is not a directory"
OUT_CSV="${2:-$RUN_DIR/merged.csv}"

BENCH_COLS="build,crate,test,status,compile_seconds,mean_s,stddev_s,median_s,min_s,max_s,runs,timestamp,job_id"
HYPERFINE_HEADER="$BENCH_COLS,error_type,error"
CONCURRENT_HEADER="$BENCH_COLS,tests_requested,tests_run,test_threads,excluded_failed"
PROFILE_HEADER="build,crate,test,status,compile_seconds,run_seconds,timestamp,job_id"
EVAL_HEADER="$PROFILE_HEADER,error_type,error"

rows() { find "$SHARD_DIR" -maxdepth 1 -name '*.csv' -exec cat {} + 2>/dev/null; }

# Field count of the first row, ignoring the quoted error field (always last,
# and the only field that can hold commas).
first_row_cols() {
    rows | head -n1 | sed -E 's/"([^"]|"")*"$/x/' | awk -F, '{ print NF }'
}

case "$(basename "$(dirname "$RUN_DIR")")" in
    hyperfine-runs)  HEADER="$HYPERFINE_HEADER" ;;
    concurrent-runs) HEADER="$CONCURRENT_HEADER" ;;
    profile-runs)    HEADER="$PROFILE_HEADER" ;;
    eval-runs)       HEADER="$EVAL_HEADER" ;;
    *)
        case "$(first_row_cols)" in
            15|13) HEADER="$HYPERFINE_HEADER" ;;  # 13 = before error_type/error
            17)    HEADER="$CONCURRENT_HEADER" ;;
            8)     HEADER="$PROFILE_HEADER" ;;
            10)    HEADER="$EVAL_HEADER" ;;
            "")    die "no shard rows in $SHARD_DIR" ;;
            *)     die "can't tell the runner type from $RUN_DIR (first row has $(first_row_cols) columns)" ;;
        esac ;;
esac

# With --append, rows already in OUT_CSV are skipped too, so re-merging a run
# into the master CSV is harmless.
merged_rows() {
    if [ "$APPEND" = 1 ] && [ -s "$OUT_CSV" ]; then
        rows | awk 'NR == FNR { seen[$0] = 1; next } NF && !seen[$0]++' "$OUT_CSV" -
    else
        rows | awk 'NF && !seen[$0]++'
    fi
}

if [ "$OUT_CSV" = "-" ]; then
    echo "$HEADER"
    merged_rows
else
    if [ "$APPEND" = 1 ] && [ -s "$OUT_CSV" ]; then
        have="$(head -n1 "$OUT_CSV")"
        if [ "$have" = "$BENCH_COLS" ] && [ "$HEADER" = "$HYPERFINE_HEADER" ]; then
            # Same in-place widening run_bench_dataset.sh does for old CSVs.
            sed -i.bak "1s/.*/$HEADER/" "$OUT_CSV" && rm -f "$OUT_CSV.bak"
        elif [ "$have" != "$HEADER" ]; then
            die "$OUT_CSV header doesn't match this run's:"$'\n'"  have: $have"$'\n'"  want: $HEADER"
        fi
    else
        echo "$HEADER" > "$OUT_CSV" || die "failed to write $OUT_CSV"
    fi
    before=$(wc -l < "$OUT_CSV")
    new="$(merged_rows)"
    [ -n "$new" ] && { printf "%s\n" "$new" >> "$OUT_CSV" || die "failed to write $OUT_CSV"; }
    echo "==> $(( $(wc -l < "$OUT_CSV") - before )) rows -> $OUT_CSV" >&2
    # Status is field 4; test names contain '::' but never commas, so this is safe.
    printf "%s\n" "$new" | awk -F, 'NF { n[$4]++ } END { for (s in n) printf "    %-16s %d\n", s, n[s] }' \
        | sort >&2
fi
