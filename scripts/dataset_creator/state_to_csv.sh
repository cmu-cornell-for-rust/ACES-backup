#!/usr/bin/env bash
#
# state_to_csv.sh
#
#   Compiles the per-crate verdict files in a fetcher's _state/ dir into one
#   CSV. Works for every fetcher that writes them (fetch_c_ffi_crates.sh,
#   fetch_all_c_ffi_crates.sh, capslock/fetch_capslock_ffi_crates.sh), since
#   they share the format:
#       crate \t name \t version \t repository \t n_c \t n_c_unwind \t n_cpp \t n_files \t status
#
#   Unlike the fetchers' own CSV (C-FFI crates only), this keeps EVERY verdict,
#   failures included, with the raw status:
#       kept / no-c-ffi / download-failed / extract-failed / copy-failed / store-failed
#
# Usage:
#   ./state_to_csv.sh <STATE_DIR> [OUT_CSV] [STATUS_REGEX]
#
#   STATE_DIR     the _state dir, or the fetcher's OUTPUT_DIR containing it
#   OUT_CSV       default: <STATE_DIR>/../state.csv  ("-" = stdout)
#   STATUS_REGEX  only keep rows whose status matches (awk ERE), e.g.
#                   failed        -> every failure
#                   ^kept$        -> C-FFI crates only
#                 default: all rows
#
# Output columns:
#   crate,name,version,repository,host,extern_c,extern_c_unwind,extern_cpp,matched_files,status

set -uo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

[ "$#" -ge 1 ] || { sed -n '3,27p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

STATE_DIR="${1%/}"
[ -d "$STATE_DIR/_state" ] && STATE_DIR="$STATE_DIR/_state"
[ -d "$STATE_DIR" ] || die "$STATE_DIR is not a directory"
OUT_CSV="${2:-$(dirname "$STATE_DIR")/state.csv}"
STATUS_RE="${3:-}"

# Not `cat "$STATE_DIR"/*.tsv`: with this many files the glob overflows ARG_MAX.
rows() { find "$STATE_DIR" -maxdepth 1 -name '*.tsv' -exec cat {} + 2>/dev/null; }

compile() {
    echo "crate,name,version,repository,host,extern_c,extern_c_unwind,extern_cpp,matched_files,status"
    rows | awk -F'\t' -v re="$STATUS_RE" '
        function q(v) {   # RFC4180-quote only when needed
            if (v ~ /[,"\n]/) { gsub(/"/, "\"\"", v); return "\"" v "\"" }
            return v
        }
        function host(u) {
            if (u == "")                        return ""
            if (u ~ /github\.com/)              return "github"
            if (u ~ /gitlab\./)                 return "gitlab"
            if (u ~ /bitbucket\.org/)           return "bitbucket"
            if (u ~ /codeberg\.org/)            return "codeberg"
            if (u ~ /sr\.ht/)                   return "sourcehut"
            return "other"
        }
        $1 == "" { next }
        re != "" && $9 !~ re { next }
        { printf "%s,%s,%s,%s,%s,%d,%d,%d,%d,%s\n",
                 q($1), q($2), q($3), q($4), host($4), $5, $6, $7, $8, q($9) }
    ' | LC_ALL=C sort -t, -k1,1
}

if [ "$OUT_CSV" = "-" ]; then
    compile
else
    compile > "$OUT_CSV" || die "failed to write $OUT_CSV"
    echo "==> $(( $(wc -l < "$OUT_CSV") - 1 )) rows -> $OUT_CSV" >&2
    tail -n +2 "$OUT_CSV" | awk -F, '{ n[$NF]++ } END { for (s in n) printf "    %-16s %d\n", s, n[s] }' \
        | sort >&2
fi
