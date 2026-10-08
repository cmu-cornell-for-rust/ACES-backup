#!/usr/bin/env bash
#
# count_extern_c.sh
#
#   Read-only: scans a directory of already-extracted crates (one
#   <name-version>/ folder each, as written by download_dataset.sh) and
#   records how many C / C++ FFI declarations each one's Rust sources contain.
#   Nothing is downloaded or deleted.
#
#   Same scan as fetch_c_ffi_crates.sh / download_extern_c.sh (in *.rs files
#   only, so vendored .c/.h sources don't produce false positives):
#       extern_c         extern "C"
#       extern_c_unwind  extern "C-unwind"
#       extern_cpp       extern "C++"
#   matched_files is the number of .rs files with at least one of the three.
#
#   Every crate gets a row, including those with no matches:
#       crate,name,version,extern_c,extern_c_unwind,extern_cpp,matched_files
#   Filter with e.g.  awk -F, 'NR > 1 && $4 > 0' OUT_CSV
#
#   Top-level entries starting with "_" (e.g. _state) are skipped.
#
# Usage:
#   ./count_extern_c.sh CRATES_DIR [OUT_CSV]
#   OUT_CSV  default: CRATES_DIR/_extern_c_counts.csv  ("-" = stdout)
#
# Environment knobs:
#   JOBS=8   parallel scan workers
#
# Requirements: bash, find, xargs. Uses ripgrep if present, else grep.

set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
JOBS="${JOBS:-8}"

# Any of the three FFI ABI strings. `extern"C"` (no space) is legal Rust, hence
# the optional whitespace. Keep in sync with the fetchers.
FFI_RE='extern[[:space:]]*"(C|C-unwind|C\+\+)"'

die() { echo "ERROR: $*" >&2; exit 1; }

# Emit every FFI ABI literal found under $1, one per line.
ffi_matches() {
    if [ -n "${RG:-}" ]; then
        "$RG" --no-config --no-messages -o --no-filename --no-line-number \
              -g '*.rs' -e "$FFI_RE" -- "$1" 2>/dev/null
    else
        grep -rhoE --include='*.rs' "$FFI_RE" "$1" 2>/dev/null
    fi
}

# Count the *.rs files under $1 containing at least one FFI ABI literal.
ffi_file_count() {
    if [ -n "${RG:-}" ]; then
        "$RG" --no-config --no-messages -l -g '*.rs' -e "$FFI_RE" -- "$1" 2>/dev/null | wc -l | tr -d ' '
    else
        grep -rlE --include='*.rs' "$FFI_RE" "$1" 2>/dev/null | wc -l | tr -d ' '
    fi
}

# Print "<n_c> <n_c_unwind> <n_cpp> <n_files>" for the crate tree at $1.
scan_crate() {
    local dir="$1" counts
    # "C" cannot match "C-unwind" or "C++": the closing quote has to follow the C.
    counts="$(ffi_matches "$dir" | awk '
        /"C"/        { c++ }
        /"C-unwind"/ { u++ }
        /"C\+\+"/    { p++ }
        END { printf "%d %d %d", c+0, u+0, p+0 }')"
    [ -z "$counts" ] && counts="0 0 0"
    printf '%s %s' "$counts" "$(ffi_file_count "$dir")"
}

csv_field() {   # RFC4180-quote $1 only when it needs it
    local v="$1"
    case "$v" in
        *[,\"$'\n']*) printf '"%s"' "${v//\"/\"\"}" ;;
        *)            printf '%s'   "$v" ;;
    esac
}

# ------------------------------- worker mode ------------------------------- #
# Invoked by xargs, one crate dir per call; writes its row to ROWS_DIR.
if [ "${1:-}" = "--worker" ]; then
    dir="$2"
    crate="$(basename "$dir")"
    # name = everything up to the last "-<digit>", same as download_dataset.sh
    if [[ "$crate" =~ ^(.*)-([0-9].*)$ ]]; then
        name="${BASH_REMATCH[1]}"; version="${BASH_REMATCH[2]}"
    else
        name="$crate"; version=""
    fi
    read -r n_c n_cu n_cpp n_files <<<"$(scan_crate "$dir")"
    printf '%s,%s,%s,%s,%s,%s,%s\n' \
        "$(csv_field "$crate")" "$(csv_field "$name")" "$(csv_field "$version")" \
        "$n_c" "$n_cu" "$n_cpp" "$n_files" > "$ROWS_DIR/$crate.row"
    exit 0
fi

# --------------------------------- setup ----------------------------------- #
[ "$#" -ge 1 ] || die "usage: $0 CRATES_DIR [OUT_CSV]"
CRATES_DIR="${1%/}"
[ -d "$CRATES_DIR" ] || die "not a directory: $CRATES_DIR"
OUT_CSV="${2:-$CRATES_DIR/_extern_c_counts.csv}"
RG="$(command -v rg || true)"

ROWS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/count_extern_c.XXXXXX")" || die "mktemp failed"
trap 'rm -rf "$ROWS_DIR"' EXIT

export SELF RG ROWS_DIR FFI_RE

n_total="$(find "$CRATES_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '_*' | wc -l | tr -d ' ')"
echo "==> Scanning $n_total crates in $CRATES_DIR with $JOBS workers ..." >&2

find "$CRATES_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '_*' -print0 \
    | xargs -0 -n 1 -P "$JOBS" "$SELF" --worker

# Not `cat "$ROWS_DIR"/*.row`: with many crates the glob overflows ARG_MAX.
compile() {
    echo "crate,name,version,extern_c,extern_c_unwind,extern_cpp,matched_files"
    find "$ROWS_DIR" -name '*.row' -exec cat {} + | LC_ALL=C sort -t, -k1,1
}

if [ "$OUT_CSV" = "-" ]; then
    compile
else
    compile > "$OUT_CSV" || die "failed to write $OUT_CSV"
fi

# --------------------------------- summary ---------------------------------- #
find "$ROWS_DIR" -name '*.row' -exec cat {} + | awk -F, '
    { n++ }
    $(NF-3) > 0 { c++ }
    $(NF-2) > 0 { cu++ }
    $(NF-1) > 0 { cpp++ }
    $(NF-3) > 0 || $(NF-2) > 0 || $(NF-1) > 0 { any++ }
    END {
        printf "==> Done. %d crates scanned\n", n
        printf "    with extern \"C\":         %d\n", c
        printf "    with extern \"C-unwind\":  %d\n", cu
        printf "    with extern \"C++\":       %d\n", cpp
        printf "    with any of the above:   %d\n", any
    }' >&2
[ "$OUT_CSV" = "-" ] || echo "    csv: $OUT_CSV" >&2
exit 0
