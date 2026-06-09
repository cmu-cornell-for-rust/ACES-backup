#!/usr/bin/env bash
#
# download_top_crates.sh
#
#   Downloads the top N most-downloaded crates from crates.io and extracts
#   each into the given output directory.
#
#   Pairs with filter_unsafe_crates.sh, which runs cargo geiger over the result
#   and removes the crates with no unsafe usage.
#
#   Usage: ./download_top_crates.sh <N> <downloaded_crates_dir>
#     e.g. ./download_top_crates.sh 500 /scratch/group/p.cis260229.000/downloaded_crates
#
# Requirements: bash, curl, jq, tar
set -uo pipefail   # no -e; per-crate failures are handled inline
# ------------------------------ configuration ------------------------------ #
if [ "$#" -lt 2 ] || [ -z "${1:-}" ] || [ -z "${2:-}" ]; then
    echo "Usage: $0 <N> <downloaded_crates_dir>" >&2
    echo "  e.g. $0 500 /scratch/group/p.cis260229.000/downloaded_crates" >&2
    exit 1
fi
MAX_CRATES="$1"                                      # how many top crates (positional, required)
OUTPUT_DIR="$2"                                      # where they land (positional, required)
USER_AGENT="${USER_AGENT:-top-crates-geiger-script (mmaclare@cs.cmu.edu)}"
SLEEP_BETWEEN="${SLEEP_BETWEEN:-1}"                  # politeness delay (seconds)
PER_PAGE=100                                         # crates.io API page size (max 100)
# --------------------------------------------------------------------------- #
API="https://crates.io/api/v1/crates"
CDN="https://static.crates.io/crates"
LOG_DIR="$OUTPUT_DIR/_logs"
DOWNLOAD_LOG="$LOG_DIR/download_errors.log"
die() { echo "ERROR: $*" >&2; exit 1; }
command -v curl >/dev/null || die "curl is required"
command -v jq   >/dev/null || die "jq is required"
command -v tar  >/dev/null || die "tar is required"
mkdir -p "$OUTPUT_DIR" "$LOG_DIR"
: > "$DOWNLOAD_LOG"
# Fetch a JSON URL to a file. Some servers/proxies return a gzipped body even
# when not requested, which corrupts shell command substitution; download to a
# file and gunzip it if it arrives gzip-compressed.
fetch_api_json() {   # $1 = url   $2 = output file
    curl -fsSL --compressed -A "$USER_AGENT" "$1" -o "$2" || return 1
    if [ "$(od -An -tx1 -N2 "$2" | tr -d ' ')" = "1f8b" ]; then
        mv "$2" "$2.gz" && gunzip -c "$2.gz" > "$2" && rm -f "$2.gz"
    fi
}
# ----------------------- phase 1: fetch the crate list ---------------------- #
echo "==> Fetching the top $MAX_CRATES crates by download count..."
crate_list="$(mktemp)"
page_json="$(mktemp)"
trap 'rm -f "$crate_list" "$crate_list".* "$page_json"' EXIT
pages=$(( (MAX_CRATES + PER_PAGE - 1) / PER_PAGE ))
for (( page=1; page<=pages; page++ )); do
    fetch_api_json "$API?page=$page&per_page=$PER_PAGE&sort=downloads" "$page_json" \
        || die "failed to query crates.io (page $page)"
    jq -r '
        .crates[]
        | [ .name, (.max_stable_version // .newest_version // .max_version) ]
        | @tsv' "$page_json" >> "$crate_list" \
        || die "failed to parse crates.io response (page $page)"
    echo "    page $page/$pages  (have $(wc -l < "$crate_list") crates)"
    sleep "$SLEEP_BETWEEN"
done
head -n "$MAX_CRATES" "$crate_list" > "$crate_list.trim" && mv "$crate_list.trim" "$crate_list"
echo "==> Got $(wc -l < "$crate_list") crates."
# ---------------------- phase 2: download and extract ----------------------- #
echo "==> Downloading + extracting into $OUTPUT_DIR ..."
ok=0; failed=0
while IFS=$'\t' read -r name version; do
    [ -z "$name" ] && continue
    dir="$OUTPUT_DIR/${name}-${version}"
    [ -d "$dir" ] && { echo "    skip (exists): ${name}-${version}"; continue; }
    tarball="$OUTPUT_DIR/${name}-${version}.crate"
    if curl -fsSL -A "$USER_AGENT" -o "$tarball" \
            "$CDN/${name}/${name}-${version}.crate"; then
        if tar -xzf "$tarball" -C "$OUTPUT_DIR" 2>/dev/null; then
            echo "    ok: ${name}-${version}"; ok=$((ok+1))
        else
            echo "    extract-failed: ${name}-${version}"; echo "$name-$version extract-failed" >> "$DOWNLOAD_LOG"; failed=$((failed+1))
        fi
        rm -f "$tarball"
    else
        echo "    download-failed: ${name}-${version}"; echo "$name-$version download-failed" >> "$DOWNLOAD_LOG"; failed=$((failed+1))
    fi
    sleep "$SLEEP_BETWEEN"
done < "$crate_list"
echo
echo "==> Download complete."
echo "    extracted: $ok"
echo "    failed:    $failed (see $DOWNLOAD_LOG)"
echo "    Next: run ./filter_unsafe_crates.sh $OUTPUT_DIR"
