#!/usr/bin/env bash
#
# download_crates.sh
#
#   Reads a list of `name-version` entries (one per line, default
#   kept_unsafe_crates.log) and downloads each crate's published crates.io
#   tarball, extracting it into OUTPUT_DIR/<name-version>/.
#
#   Each line looks like:  windows-core-0.62.2   /   zstd-sys-2.0.16+zstd.1.5.7
#   The crate name is everything up to the last hyphen that precedes a digit,
#   so multi-hyphen names (zerocopy-derive) and '+' build metadata in the
#   version are handled.
#
#   Idempotent: a crate whose folder already exists is skipped. Failures are
#   recorded and never abort the run.
#
# Usage:
#   ./download_crates.sh [LIST_FILE] [OUTPUT_DIR]
#   LIST_FILE   default: kept_unsafe_crates.log
#   OUTPUT_DIR  default: downloaded_crates
#
# Requirements: bash, curl, tar

set -uo pipefail

LIST_FILE="${1:-kept_unsafe_crates.log}"
OUTPUT_DIR="${2:-downloaded_crates}"
UA="crate-downloader (CMU systems research; via crates.io)"

die() { echo "ERROR: $*" >&2; exit 1; }
command -v curl >/dev/null || die "curl is required"
command -v tar  >/dev/null || die "tar is required"
[ -f "$LIST_FILE" ] || die "list file not found: $LIST_FILE"

mkdir -p "$OUTPUT_DIR"
FAIL_LOG="$OUTPUT_DIR/_download_failures.log"
: > "$FAIL_LOG"

echo "==> downloading crates listed in $LIST_FILE -> $OUTPUT_DIR/"
ok=0; skip=0; fail=0

while IFS= read -r raw || [ -n "$raw" ]; do
    line="${raw%$'\r'}"                      # strip trailing CR (CRLF files)
    line="${line#"${line%%[![:space:]]*}"}"  # trim leading whitespace
    line="${line%"${line##*[![:space:]]}"}"  # trim trailing whitespace
    [ -z "$line" ] && continue
    case "$line" in '#'*) continue ;; esac    # allow comment lines

    if [[ "$line" =~ ^(.*)-([0-9].*)$ ]]; then
        name="${BASH_REMATCH[1]}"
        version="${BASH_REMATCH[2]}"
    else
        printf '    %-42s -> SKIP (cannot parse name-version)\n' "$line"
        echo "$line unparseable" >> "$FAIL_LOG"; fail=$((fail+1)); continue
    fi

    dest="$OUTPUT_DIR/$line"
    if [ -d "$dest" ]; then
        printf '    %-42s -> skip (already present)\n' "$line"
        skip=$((skip+1)); continue
    fi

    url="https://crates.io/api/v1/crates/$name/$version/download"
    tmp="$(mktemp)"
    if curl -fsSL -A "$UA" --retry 3 --retry-delay 2 -o "$tmp" "$url"; then
        # a .crate file is a gzip tarball that unpacks to <name>-<version>/
        if tar -xzf "$tmp" -C "$OUTPUT_DIR"; then
            printf '    %-42s -> downloaded\n' "$line"
            ok=$((ok+1))
        else
            printf '    %-42s -> FAIL (extract)\n' "$line"
            echo "$line extract-failed" >> "$FAIL_LOG"; fail=$((fail+1))
        fi
    else
        printf '    %-42s -> FAIL (download)\n' "$line"
        echo "$line download-failed ($url)" >> "$FAIL_LOG"; fail=$((fail+1))
    fi
    rm -f "$tmp"
    sleep 0.2                                  # be polite to crates.io
done < "$LIST_FILE"

echo
echo "==> done: $ok downloaded, $skip already present, $fail failed"
[ "$fail" -gt 0 ] && echo "    failures -> $FAIL_LOG"
exit 0
