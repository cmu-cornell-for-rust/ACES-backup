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
#   The list can also be a CSV (detected by a comma in its first line, which
#   is then the header): the crate name comes from the FIRST column whose
#   header contains "name" and the version from the first containing
#   "version" (case-insensitive), e.g. mirilli/stage3.csv (crate_name,version)
#   or c_ffi_bindings.csv (crate,name,version,...). Quoted fields are handled.
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

# CSV list -> temp file of name-version lines, fed to the loop below.
if head -n1 "$LIST_FILE" | grep -q ','; then
    csv_entries="$(mktemp)"
    trap 'rm -f "$csv_entries"' EXIT
    awk '
        function parse(line, f,    n, i, c, q, cur) {   # RFC-4180 split into f[1..n]
            n = 0; cur = ""; q = 0
            for (i = 1; i <= length(line); i++) {
                c = substr(line, i, 1)
                if (q) {
                    if (c == "\"") {
                        if (substr(line, i + 1, 1) == "\"") { cur = cur "\""; i++ } else q = 0
                    } else cur = cur c
                } else if (c == "\"") q = 1
                else if (c == ",") { f[++n] = cur; cur = "" }
                else cur = cur c
            }
            f[++n] = cur
            return n
        }
        function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
        { sub(/\r$/, "") }
        NR == 1 {
            n = parse($0, h)
            for (i = 1; i <= n; i++) {
                col = tolower(h[i])
                if (!ni && index(col, "name"))    ni = i
                if (!vi && index(col, "version")) vi = i
            }
            if (!ni || !vi) { print "no \"name\" and/or \"version\" column in header: " $0 > "/dev/stderr"; exit 1 }
            printf "    (CSV: name from column \"%s\", version from \"%s\")\n", h[ni], h[vi] > "/dev/stderr"
            next
        }
        {
            parse($0, f)
            name = trim(f[ni]); ver = trim(f[vi])
            if (name != "" && ver != "") print name "-" ver
        }
    ' "$LIST_FILE" > "$csv_entries" || die "could not read $LIST_FILE as a CSV"
    LIST_FILE_ORIG="$LIST_FILE"
    LIST_FILE="$csv_entries"
fi

mkdir -p "$OUTPUT_DIR"
FAIL_LOG="$OUTPUT_DIR/_download_failures.log"
: > "$FAIL_LOG"

echo "==> downloading crates listed in ${LIST_FILE_ORIG:-$LIST_FILE} -> $OUTPUT_DIR/"
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
