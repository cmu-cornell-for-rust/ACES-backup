#!/usr/bin/env bash
#
# fetch_c_ffi_crates.sh
#
#   Downloads every crate in the crates.io "api-bindings" category
#   (https://crates.io/categories/api-bindings, ~14.2k crates), greps each
#   one's Rust sources for C / C++ FFI declarations, and keeps only the crates
#   that have them. Crates with no C FFI are deleted immediately after the
#   scan, so the output directory only ever holds keepers.
#
#   Matched patterns (in *.rs files only, so vendored .c/.h sources don't
#   produce false positives):
#       extern "C"           - the C ABI: `extern "C" { .. }` blocks (bindings
#                              to C) and `extern "C" fn` (callbacks exported
#                              to C). Both are FFI.
#       extern "C-unwind"    - the unwinding variant of the C ABI.
#       extern "C++"         - cxx-style C++ bridges (`#[cxx::bridge]` modules
#                              contain `unsafe extern "C++" { .. }`).
#
#   The surviving crates are written to c_ffi_bindings.csv, in the same shape
#   as test_fixtures_fetched.csv:
#       crate,name,version,repository,host,extern_c,extern_c_unwind,extern_cpp,matched_files,status
#
#   Resumable: every crate that has been processed leaves a marker in
#   OUTPUT_DIR/_state/, and a re-run skips it. Delete the marker (or the whole
#   _state dir) to force a re-fetch. Per-crate failures never abort the run.
#
# Usage:
#   ./fetch_c_ffi_crates.sh [OUTPUT_DIR] [CSV_PATH]
#   ./fetch_c_ffi_crates.sh --prune [OUTPUT_DIR] [CSV_PATH]
#
#   OUTPUT_DIR  default: c_ffi_crates
#   CSV_PATH    default: c_ffi_bindings.csv (next to this script)
#
#   --prune     skip the download phase: re-scan the crates already sitting in
#               OUTPUT_DIR, delete the ones without C FFI, and rebuild the CSV.
#
# Environment knobs:
#   JOBS=8              parallel download+scan workers
#   SLEEP_BETWEEN=1     per-worker politeness delay, seconds
#   CATEGORY=api-bindings   crates.io category slug to harvest
#   USER_AGENT=...      sent to crates.io (keep a contact address in it)
#
# Requirements: bash 4+, curl, jq, tar. Uses ripgrep if present, else grep.

set -uo pipefail   # no -e; per-crate failures are handled inline

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# ------------------------------ configuration ------------------------------ #
CATEGORY="${CATEGORY:-api-bindings}"
JOBS="${JOBS:-8}"
SLEEP_BETWEEN="${SLEEP_BETWEEN:-1}"
USER_AGENT="${USER_AGENT:-aces-c-ffi-dataset-builder (CMU systems research; mmaclare@andrew.cmu.edu)}"
PER_PAGE=100                                   # crates.io API page size (max 100)

API="https://crates.io/api/v1/crates"
CDN="https://static.crates.io/crates"

# Any of the three FFI ABI strings. `extern"C"` (no space) is legal Rust, hence
# the optional whitespace.
FFI_RE='extern[[:space:]]*"(C|C-unwind|C\+\+)"'

die() { echo "ERROR: $*" >&2; exit 1; }

# --------------------------------- scanning -------------------------------- #
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

# --------------------------------- CSV bits -------------------------------- #
host_of() {   # $1 = repository url
    case "$1" in
        '')                     echo "" ;;
        *github.com*)           echo "github" ;;
        *gitlab.com*|*gitlab.*) echo "gitlab" ;;
        *bitbucket.org*)        echo "bitbucket" ;;
        *codeberg.org*)         echo "codeberg" ;;
        *sr.ht*)                echo "sourcehut" ;;
        *)                      echo "other" ;;
    esac
}

csv_field() {   # RFC4180-quote $1 only when it needs it
    local v="$1"
    case "$v" in
        *[,\"$'\n']*) printf '"%s"' "${v//\"/\"\"}" ;;
        *)            printf '%s'   "$v" ;;
    esac
}

# ------------------------------- worker mode ------------------------------- #
# Invoked by xargs, one crate per call: download, extract, scan, keep or drop.
# argv: --worker <name> <version> <repository>
if [ "${1:-}" = "--worker" ]; then
    name="$2"; version="$3"; repository="${4:-}"
    [ "$repository" = "-" ] && repository=""     # xargs drops empty args; see below
    crate="${name}-${version}"
    state="$STATE_DIR/$crate.tsv"
    [ -f "$state" ] && exit 0                      # already processed

    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/cffi.XXXXXX")" || exit 0
    trap 'rm -rf "$tmpdir"' EXIT

    tarball="$tmpdir/$crate.crate"
    if ! curl -fsSL -A "$USER_AGENT" --retry 3 --retry-delay 2 --max-time 180 \
              -o "$tarball" "$CDN/$name/$crate.crate" 2>/dev/null; then
        # CDN layout misses a few crates (odd names, build metadata in the
        # version); the API download endpoint redirects to the right object.
        if ! curl -fsSL -A "$USER_AGENT" --retry 3 --retry-delay 2 --max-time 180 \
                  -o "$tarball" "$API/$name/$version/download" 2>/dev/null; then
            printf '%s\t%s\t%s\t%s\t0\t0\t0\t0\tdownload-failed\n' \
                "$crate" "$name" "$version" "$repository" > "$state"
            echo "    fail (download): $crate" >&2
            exit 0
        fi
    fi

    if ! tar -xzf "$tarball" -C "$tmpdir" 2>/dev/null; then
        printf '%s\t%s\t%s\t%s\t0\t0\t0\t0\textract-failed\n' \
            "$crate" "$name" "$version" "$repository" > "$state"
        echo "    fail (extract): $crate" >&2
        exit 0
    fi
    rm -f "$tarball"

    # A .crate unpacks to a single top-level dir, normally <name>-<version>.
    src="$tmpdir/$crate"
    if [ ! -d "$src" ]; then
        src="$(find "$tmpdir" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
        [ -d "$src" ] || { printf '%s\t%s\t%s\t%s\t0\t0\t0\t0\textract-failed\n' \
            "$crate" "$name" "$version" "$repository" > "$state"; exit 0; }
    fi

    read -r n_c n_cu n_cpp n_files <<<"$(scan_crate "$src")"
    if [ $(( n_c + n_cu + n_cpp )) -gt 0 ]; then
        rm -rf "${OUTPUT_DIR:?}/$crate"
        if mv "$src" "$OUTPUT_DIR/$crate" 2>/dev/null; then
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\tkept\n' \
                "$crate" "$name" "$version" "$repository" \
                "$n_c" "$n_cu" "$n_cpp" "$n_files" > "$state"
            echo "    keep: $crate  (C=$n_c C-unwind=$n_cu C++=$n_cpp in $n_files files)"
        else
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\tstore-failed\n' \
                "$crate" "$name" "$version" "$repository" \
                "$n_c" "$n_cu" "$n_cpp" "$n_files" > "$state"
            echo "    fail (store): $crate" >&2
        fi
    else
        # No C FFI -> the extracted tree is dropped with the temp dir.
        printf '%s\t%s\t%s\t%s\t0\t0\t0\t0\tno-c-ffi\n' \
            "$crate" "$name" "$version" "$repository" > "$state"
    fi
    sleep "$SLEEP_BETWEEN"
    exit 0
fi

# --------------------------------- setup ----------------------------------- #
PRUNE=0
if [ "${1:-}" = "--prune" ]; then PRUNE=1; shift; fi

OUTPUT_DIR="${1:-c_ffi_crates}"
CSV_PATH="${2:-$(dirname "$SELF")/c_ffi_bindings.csv}"

command -v curl >/dev/null || die "curl is required"
command -v tar  >/dev/null || die "tar is required"
[ "$PRUNE" -eq 1 ] || command -v jq >/dev/null || die "jq is required"
RG="$(command -v rg || true)"

mkdir -p "$OUTPUT_DIR" || die "cannot create $OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
STATE_DIR="$OUTPUT_DIR/_state"
CRATE_LIST="$OUTPUT_DIR/_crate_list.tsv"
mkdir -p "$STATE_DIR"

export SELF CATEGORY SLEEP_BETWEEN USER_AGENT API CDN FFI_RE RG \
       OUTPUT_DIR STATE_DIR

# ------------------- phase 1: harvest the category listing ------------------ #
if [ "$PRUNE" -eq 0 ]; then
    if [ -s "$CRATE_LIST" ]; then
        echo "==> Reusing cached crate list ($(wc -l < "$CRATE_LIST" | tr -d ' ') crates): $CRATE_LIST"
        echo "    (delete it to re-harvest the category)"
    else
        echo "==> Harvesting the '$CATEGORY' category from crates.io ..."
        page_json="$(mktemp)"
        tmp_list="$(mktemp)"
        page=1; total=""
        while :; do
            if ! curl -fsSL --compressed -A "$USER_AGENT" --retry 3 --retry-delay 2 \
                     -o "$page_json" \
                     "$API?category=$CATEGORY&per_page=$PER_PAGE&page=$page&sort=alpha"; then
                rm -f "$page_json" "$tmp_list"
                die "failed to query crates.io (page $page)"
            fi
            [ -z "$total" ] && total="$(jq -r '.meta.total // "?"' "$page_json")"
            n="$(jq -r '.crates | length' "$page_json")"
            jq -r '
                .crates[]
                | [ .name,
                    (.max_stable_version // .newest_version // .max_version // ""),
                    (.repository // "") ]
                | @tsv' "$page_json" >> "$tmp_list" || { rm -f "$page_json" "$tmp_list"; die "bad response (page $page)"; }
            echo "    page $page  (have $(wc -l < "$tmp_list" | tr -d ' ')/$total)"
            [ "$(jq -r '.meta.next_page // "null"' "$page_json")" = "null" ] && break
            [ "$n" -eq 0 ] && break
            page=$((page+1))
            sleep 1                                # crates.io asks ~1 req/s on the API
        done
        rm -f "$page_json"
        # Drop crates with no publishable version, then de-duplicate.
        awk -F'\t' 'NF>=2 && $2 != "" && !seen[$1]++' "$tmp_list" > "$CRATE_LIST"
        rm -f "$tmp_list"
        echo "==> $(wc -l < "$CRATE_LIST" | tr -d ' ') crates to process."
    fi
fi

# -------------------- phase 2: download + scan + keep/drop ------------------ #
if [ "$PRUNE" -eq 0 ]; then
    todo="$(mktemp)"
    while IFS=$'\t' read -r name version repository; do
        [ -z "$name" ] && continue
        [ -f "$STATE_DIR/${name}-${version}.tsv" ] && continue
        printf '%s\t%s\t%s\n' "$name" "$version" "$repository" >> "$todo"
    done < "$CRATE_LIST"

    n_todo="$(wc -l < "$todo" | tr -d ' ')"
    n_done=$(( $(wc -l < "$CRATE_LIST") - n_todo ))
    echo "==> Downloading + scanning $n_todo crates with $JOBS workers ($n_done already done) ..."
    if [ "$n_todo" -gt 0 ]; then
        # macOS xargs -0 silently drops empty arguments, which would shift the
        # 3-arg groups; send "-" for a missing repository and unmap it in the worker.
        awk -F'\t' 'BEGIN{OFS="\t"} {r=($3==""?"-":$3); printf "%s%c%s%c%s%c", $1,0,$2,0,r,0}' "$todo" \
            | xargs -0 -n 3 -P "$JOBS" "$SELF" --worker
    fi
    rm -f "$todo"
else
    echo "==> Prune mode: re-scanning crates already in $OUTPUT_DIR ..."
    for dir in "$OUTPUT_DIR"/*/; do
        crate="$(basename "$dir")"
        case "$crate" in _*) continue ;; esac
        [ -d "$dir" ] || continue
        if [[ "$crate" =~ ^(.*)-([0-9].*)$ ]]; then
            name="${BASH_REMATCH[1]}"; version="${BASH_REMATCH[2]}"
        else
            name="$crate"; version=""
        fi
        repository="$(awk -F'\t' -v n="$name" '$1==n {print $3; exit}' "$CRATE_LIST" 2>/dev/null)"
        read -r n_c n_cu n_cpp n_files <<<"$(scan_crate "$dir")"
        if [ $(( n_c + n_cu + n_cpp )) -gt 0 ]; then
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\tkept\n' \
                "$crate" "$name" "$version" "$repository" \
                "$n_c" "$n_cu" "$n_cpp" "$n_files" > "$STATE_DIR/$crate.tsv"
            echo "    keep:   $crate"
        else
            rm -rf "${OUTPUT_DIR:?}/$crate"
            printf '%s\t%s\t%s\t%s\t0\t0\t0\t0\tno-c-ffi\n' \
                "$crate" "$name" "$version" "$repository" > "$STATE_DIR/$crate.tsv"
            echo "    delete: $crate  (no C FFI)"
        fi
    done
fi

# ---------------------------- phase 3: write CSV ---------------------------- #
echo "==> Writing $CSV_PATH ..."
{
    echo "crate,name,version,repository,host,extern_c,extern_c_unwind,extern_cpp,matched_files,status"
    cat "$STATE_DIR"/*.tsv 2>/dev/null \
      | awk -F'\t' '$9 == "kept"' \
      | LC_ALL=C sort -t$'\t' -k1,1 \
      | while IFS=$'\t' read -r crate name version repository n_c n_cu n_cpp n_files _; do
            # Mirror test_fixtures_fetched.csv's free-text status column.
            kinds=""
            [ "$n_c"   -gt 0 ] && kinds="extern \"C\""
            [ "$n_cu"  -gt 0 ] && kinds="${kinds:+$kinds + }extern \"C-unwind\""
            [ "$n_cpp" -gt 0 ] && kinds="${kinds:+$kinds + }extern \"C++\""
            printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
                "$(csv_field "$crate")" "$(csv_field "$name")" \
                "$(csv_field "$version")" "$(csv_field "$repository")" \
                "$(csv_field "$(host_of "$repository")")" \
                "$n_c" "$n_cu" "$n_cpp" "$n_files" \
                "$(csv_field "$kinds")"
        done
} > "$CSV_PATH"

# --------------------------------- summary ---------------------------------- #
tally() { cat "$STATE_DIR"/*.tsv 2>/dev/null | awk -F'\t' -v s="$1" '$9 == s' | wc -l | tr -d ' '; }
kept="$(tally kept)"; none="$(tally no-c-ffi)"
dl_fail="$(tally download-failed)"; ex_fail="$(tally extract-failed)"; st_fail="$(tally store-failed)"

echo
echo "==> Done."
echo "    kept (C/C++ FFI):  $kept   -> $OUTPUT_DIR/"
echo "    deleted (no FFI):  $none"
echo "    download failures: $dl_fail"
echo "    extract failures:  $ex_fail"
[ "$st_fail" -gt 0 ] && echo "    store failures:    $st_fail"
echo "    csv:               $CSV_PATH ($kept rows)"
echo "    per-crate verdicts: $STATE_DIR/"
exit 0
