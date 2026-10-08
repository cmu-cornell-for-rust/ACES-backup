#!/usr/bin/env bash
#
# download_extern_c.sh
#
#   Reads a list of crates (same formats as download_dataset.sh), downloads
#   each one's crates.io tarball, and keeps it in OUTPUT_DIR/<name-version>/
#   ONLY if its Rust sources contain an `extern "C"` declaration. Crates
#   without one are deleted right after the scan.
#
#   Matched pattern (in *.rs files only, so vendored .c/.h sources don't
#   produce false positives):
#       extern[[:space:]]*"C"
#   The closing quote has to follow the C, so `extern "C-unwind"` and
#   `extern "C++"` do NOT count (unlike fetch_c_ffi_crates.sh, which keeps
#   all three).
#
#   The list can be:
#     - plain lines of `name-version` (e.g. zstd-sys-2.0.16+zstd.1.5.7), or
#     - a CSV (detected by a comma in its first line, which is the header):
#       the crate name comes from the FIRST column whose header contains
#       "name" and the version from the first containing "version"
#       (case-insensitive), e.g. tree_borrows/crates.csv (crate_name,version).
#
#   The kept crates are written to CSV_PATH:
#       crate,name,version,extern_c,matched_files
#
#   Resumable: every processed crate leaves a verdict in OUTPUT_DIR/_state/,
#   and a re-run skips it. Delete the marker (or the whole _state dir) to
#   force a re-scan. A crate folder that is already in OUTPUT_DIR but has no
#   verdict is scanned in place (and deleted if it has no extern "C") instead
#   of being downloaded again. Per-crate failures never abort the run.
#
# Usage:
#   ./download_extern_c.sh LIST_FILE [OUTPUT_DIR] [CSV_PATH]
#   OUTPUT_DIR  default: extern_c_crates
#   CSV_PATH    default: OUTPUT_DIR/_extern_c_crates.csv
#
# Environment knobs:
#   JOBS=8              parallel download+scan workers
#   SLEEP_BETWEEN=0.2   per-worker politeness delay, seconds
#   USER_AGENT=...      sent to crates.io (keep a contact address in it)
#
# Requirements: bash, curl, tar. Uses ripgrep if present, else grep.

set -uo pipefail   # no -e; per-crate failures are handled inline

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# ------------------------------ configuration ------------------------------ #
JOBS="${JOBS:-8}"
SLEEP_BETWEEN="${SLEEP_BETWEEN:-0.2}"
USER_AGENT="${USER_AGENT:-aces-c-ffi-dataset-builder (CMU systems research; mmaclare@andrew.cmu.edu)}"

API="https://crates.io/api/v1/crates"
CDN="https://static.crates.io/crates"

# `extern"C"` (no space) is legal Rust, hence the optional whitespace.
EXTERN_C_RE='extern[[:space:]]*"C"'

die() { echo "ERROR: $*" >&2; exit 1; }

# --------------------------------- scanning -------------------------------- #
# Print "<n_matches> <n_files>" for the crate tree at $1.
scan_crate() {
    local n_c n_files
    if [ -n "${RG:-}" ]; then
        n_c="$("$RG" --no-config --no-messages -o --no-filename --no-line-number \
                     -g '*.rs' -e "$EXTERN_C_RE" -- "$1" 2>/dev/null | wc -l | tr -d ' ')"
        n_files="$("$RG" --no-config --no-messages -l -g '*.rs' -e "$EXTERN_C_RE" -- "$1" 2>/dev/null | wc -l | tr -d ' ')"
    else
        n_c="$(grep -rhoE --include='*.rs' "$EXTERN_C_RE" "$1" 2>/dev/null | wc -l | tr -d ' ')"
        n_files="$(grep -rlE --include='*.rs' "$EXTERN_C_RE" "$1" 2>/dev/null | wc -l | tr -d ' ')"
    fi
    printf '%s %s' "${n_c:-0}" "${n_files:-0}"
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
# argv: --worker <name> <version>
if [ "${1:-}" = "--worker" ]; then
    name="$2"; version="$3"
    crate="${name}-${version}"
    state="$STATE_DIR/$crate.tsv"
    [ -f "$state" ] && exit 0                      # already processed

    # Already on disk (e.g. from download_dataset.sh): scan it in place.
    if [ -d "$OUTPUT_DIR/$crate" ]; then
        read -r n_c n_files <<<"$(scan_crate "$OUTPUT_DIR/$crate")"
        if [ "$n_c" -gt 0 ]; then
            printf '%s\t%s\t%s\t%s\t%s\tkept\n' "$crate" "$name" "$version" "$n_c" "$n_files" > "$state"
            echo "    keep:   $crate  (extern \"C\" x$n_c in $n_files files, already present)"
        else
            rm -rf "${OUTPUT_DIR:?}/$crate"
            printf '%s\t%s\t%s\t0\t0\tno-extern-c\n' "$crate" "$name" "$version" > "$state"
            echo "    delete: $crate  (no extern \"C\")"
        fi
        exit 0
    fi

    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/externc.XXXXXX")" || exit 0
    trap 'rm -rf "$tmpdir"' EXIT

    tarball="$tmpdir/$crate.crate"
    if ! curl -fsSL -A "$USER_AGENT" --retry 3 --retry-delay 2 --max-time 180 \
              -o "$tarball" "$CDN/$name/$crate.crate" 2>/dev/null; then
        # CDN layout misses a few crates (odd names, build metadata in the
        # version); the API download endpoint redirects to the right object.
        if ! curl -fsSL -A "$USER_AGENT" --retry 3 --retry-delay 2 --max-time 180 \
                  -o "$tarball" "$API/$name/$version/download" 2>/dev/null; then
            printf '%s\t%s\t%s\t0\t0\tdownload-failed\n' "$crate" "$name" "$version" > "$state"
            echo "    fail (download): $crate" >&2
            exit 0
        fi
    fi

    if ! tar -xzf "$tarball" -C "$tmpdir" 2>/dev/null; then
        printf '%s\t%s\t%s\t0\t0\textract-failed\n' "$crate" "$name" "$version" > "$state"
        echo "    fail (extract): $crate" >&2
        exit 0
    fi
    rm -f "$tarball"

    # A .crate unpacks to a single top-level dir, normally <name>-<version>.
    src="$tmpdir/$crate"
    if [ ! -d "$src" ]; then
        src="$(find "$tmpdir" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
        [ -d "$src" ] || { printf '%s\t%s\t%s\t0\t0\textract-failed\n' \
            "$crate" "$name" "$version" > "$state"; exit 0; }
    fi

    read -r n_c n_files <<<"$(scan_crate "$src")"
    if [ "$n_c" -gt 0 ]; then
        if mv "$src" "$OUTPUT_DIR/$crate" 2>/dev/null; then
            printf '%s\t%s\t%s\t%s\t%s\tkept\n' "$crate" "$name" "$version" "$n_c" "$n_files" > "$state"
            echo "    keep:   $crate  (extern \"C\" x$n_c in $n_files files)"
        else
            printf '%s\t%s\t%s\t%s\t%s\tstore-failed\n' "$crate" "$name" "$version" "$n_c" "$n_files" > "$state"
            echo "    fail (store): $crate" >&2
        fi
    else
        # No extern "C" -> the extracted tree is dropped with the temp dir.
        printf '%s\t%s\t%s\t0\t0\tno-extern-c\n' "$crate" "$name" "$version" > "$state"
    fi
    sleep "$SLEEP_BETWEEN"
    exit 0
fi

# --------------------------------- setup ----------------------------------- #
[ "$#" -ge 1 ] || die "usage: $0 LIST_FILE [OUTPUT_DIR] [CSV_PATH]"
LIST_FILE="$1"
OUTPUT_DIR="${2:-extern_c_crates}"
CSV_PATH="${3:-$OUTPUT_DIR/_extern_c_crates.csv}"

command -v curl >/dev/null || die "curl is required"
command -v tar  >/dev/null || die "tar is required"
[ -f "$LIST_FILE" ] || die "list file not found: $LIST_FILE"
RG="$(command -v rg || true)"

mkdir -p "$OUTPUT_DIR" || die "cannot create $OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
STATE_DIR="$OUTPUT_DIR/_state"
mkdir -p "$STATE_DIR"

export SELF SLEEP_BETWEEN USER_AGENT API CDN EXTERN_C_RE RG OUTPUT_DIR STATE_DIR

# ------------------ phase 1: list -> name<TAB>version lines ----------------- #
todo="$(mktemp)"
trap 'rm -f "$todo"' EXIT

if head -n1 "$LIST_FILE" | grep -q ','; then
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
            if (name != "" && ver != "") print name "\t" ver
        }
    ' "$LIST_FILE" > "$todo" || die "could not read $LIST_FILE as a CSV"
else
    # name-version lines: the name is everything up to the last hyphen that
    # precedes a digit.
    awk '
        { sub(/\r$/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, "") }
        $0 == "" || /^#/ { next }
        {
            # split at the LAST "-<digit>", same as the greedy regex in download_dataset.sh
            pos = 0
            while ((i = match(substr($0, pos + 1), /-[0-9]/)) > 0) pos += i
            if (pos) print substr($0, 1, pos - 1) "\t" substr($0, pos + 1)
            else     print "    skip (cannot parse name-version): " $0 > "/dev/stderr"
        }
    ' "$LIST_FILE" > "$todo"
fi

# Drop duplicates and anything that already has a verdict.
pending="$(mktemp)"
trap 'rm -f "$todo" "$pending"' EXIT
awk -F'\t' '!seen[$0]++' "$todo" | while IFS=$'\t' read -r name version; do
    [ -f "$STATE_DIR/${name}-${version}.tsv" ] || printf '%s\t%s\n' "$name" "$version"
done > "$pending"

n_total="$(awk -F'\t' '!seen[$0]++' "$todo" | wc -l | tr -d ' ')"
n_todo="$(wc -l < "$pending" | tr -d ' ')"

# -------------------- phase 2: download + scan + keep/drop ------------------ #
echo "==> $LIST_FILE: $n_total crates, $((n_total - n_todo)) already done, $n_todo to process with $JOBS workers -> $OUTPUT_DIR/"
if [ "$n_todo" -gt 0 ]; then
    awk -F'\t' '{ printf "%s%c%s%c", $1, 0, $2, 0 }' "$pending" \
        | xargs -0 -n 2 -P "$JOBS" "$SELF" --worker
fi

# ---------------------------- phase 3: write CSV ---------------------------- #
echo "==> Writing $CSV_PATH ..."
{
    echo "crate,name,version,extern_c,matched_files"
    cat "$STATE_DIR"/*.tsv 2>/dev/null \
      | awk -F'\t' '$6 == "kept"' \
      | LC_ALL=C sort -t$'\t' -k1,1 \
      | while IFS=$'\t' read -r crate name version n_c n_files _; do
            printf '%s,%s,%s,%s,%s\n' \
                "$(csv_field "$crate")" "$(csv_field "$name")" \
                "$(csv_field "$version")" "$n_c" "$n_files"
        done
} > "$CSV_PATH"

# --------------------------------- summary ---------------------------------- #
tally() { cat "$STATE_DIR"/*.tsv 2>/dev/null | awk -F'\t' -v s="$1" '$6 == s' | wc -l | tr -d ' '; }
kept="$(tally kept)"

echo
echo "==> Done."
echo "    kept (extern \"C\"):  $kept   -> $OUTPUT_DIR/"
echo "    deleted (none):     $(tally no-extern-c)"
echo "    download failures:  $(tally download-failed)"
echo "    extract failures:   $(tally extract-failed)"
st_fail="$(tally store-failed)"
[ "$st_fail" -gt 0 ] && echo "    store failures:     $st_fail"
echo "    csv:                $CSV_PATH ($kept rows)"
echo "    per-crate verdicts: $STATE_DIR/"
exit 0
