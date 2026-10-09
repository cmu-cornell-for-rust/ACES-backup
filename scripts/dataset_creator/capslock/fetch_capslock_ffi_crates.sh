#!/usr/bin/env bash
#
# fetch_capslock_ffi_crates.sh
#
#   Walks the crate names in ffi.json, looks up the exact crate version that
#   capslock analysed in db.json (name -> "data-extracted/<aa>/<bb>/<name>-<version>"),
#   gets that exact version, greps its Rust sources for C / C++ FFI
#   declarations, and keeps only the crates that have them. Crates with no C
#   FFI are dropped immediately, so the output directory only ever holds
#   keepers.
#
#   Where the sources come from, per crate:
#       1. SRC_ROOT/<db.json path>, if SRC_ROOT is set and that dir exists
#          (a local copy of capslock's data-extracted/ tree) -> copied.
#       2. otherwise the exact <name>-<version>.crate from crates.io.
#
#   Matched patterns are the same as ../fetch_c_ffi_crates.sh (in *.rs files
#   only):
#       extern "C"           - the C ABI (bindings to C and callbacks to C).
#       extern "C-unwind"    - the unwinding variant of the C ABI.
#       extern "C++"         - cxx-style C++ bridges.
#   Not counted: `extern "C"` blocks marked #[wasm_bindgen] or
#   #[link(wasm_import_module = ..)] -- they import JavaScript / wasm host
#   functions, not C (see ffi_scan.pl).
#
#   The surviving crates are written to capslock_ffi.csv, in the same shape
#   as ../c_ffi_bindings.csv:
#       crate,name,version,repository,host,extern_c,extern_c_unwind,extern_cpp,matched_files,status
#   `repository` is read from the crate's own Cargo.toml.
#
#   Resumable: every crate that has been processed leaves a marker in
#   OUTPUT_DIR/_state/, and a re-run skips it. Delete the marker (or the whole
#   _state dir) to force a re-fetch. Per-crate failures never abort the run.
#
# Usage:
#   ./fetch_capslock_ffi_crates.sh [OUTPUT_DIR] [CSV_PATH]
#   ./fetch_capslock_ffi_crates.sh --csv-only [OUTPUT_DIR] [CSV_PATH]
#
#   OUTPUT_DIR  default: capslock_ffi_crates
#   CSV_PATH    default: capslock_ffi.csv (next to this script)
#
#   --csv-only  skip fetching: just rebuild the CSV from OUTPUT_DIR/_state/.
#
# Environment knobs:
#   FFI_JSON=ffi.json   list of crate names (next to this script)
#   DB_JSON=db.json     name -> data-extracted path map (next to this script)
#   SRC_ROOT=           dir containing capslock's data-extracted/ tree, if local
#   JOBS=8              parallel fetch+scan workers
#   SLEEP_BETWEEN=1     per-worker politeness delay after a download, seconds
#   USER_AGENT=...      sent to crates.io (keep a contact address in it)
#
# Requirements: bash 4+, curl, jq, tar, perl. Uses ripgrep if present, else grep.

set -uo pipefail   # no -e; per-crate failures are handled inline

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
HERE="$(dirname "$SELF")"

# ------------------------------ configuration ------------------------------ #
FFI_JSON="${FFI_JSON:-$HERE/ffi.json}"
DB_JSON="${DB_JSON:-$HERE/db.json}"
SRC_ROOT="${SRC_ROOT:-}"
JOBS="${JOBS:-8}"
SLEEP_BETWEEN="${SLEEP_BETWEEN:-1}"
USER_AGENT="${USER_AGENT:-aces-c-ffi-dataset-builder (CMU systems research; mmaclare@andrew.cmu.edu)}"

API="https://crates.io/api/v1/crates"
CDN="https://static.crates.io/crates"

# Any of the three FFI ABI strings. `extern"C"` (no space) is legal Rust, hence
# the optional whitespace.
FFI_RE='extern[[:space:]]*"(C|C-unwind|C\+\+)"'
# Drops wasm-bindgen / wasm import blocks, which share the "C" syntax.
FFI_SCAN="$(cd "$(dirname "$SELF")/.." && pwd)/ffi_scan.pl"

die() { echo "ERROR: $*" >&2; exit 1; }

# --------------------------------- scanning -------------------------------- #
# Emit "<file>\t<literal>" for every FFI ABI literal under $1. rg/grep find the
# candidate files; ffi_scan.pl drops the ones that aren't C (wasm-bindgen).
ffi_hits() {
    if [ -n "${RG:-}" ]; then
        "$RG" --no-config --no-messages -l -0 -g '*.rs' -e "$FFI_RE" -- "$1" 2>/dev/null
    else
        grep -rlE --null --include='*.rs' "$FFI_RE" "$1" 2>/dev/null
    fi | perl "$FFI_SCAN"
}

# Emit every FFI ABI literal found under $1, one per line.
ffi_matches() { ffi_hits "$1" | cut -f2; }

# Count the *.rs files under $1 containing at least one FFI ABI literal.
ffi_file_count() { ffi_hits "$1" | cut -f1 | sort -u | wc -l | tr -d ' '; }

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

# `repository = "..."` from the crate's Cargo.toml, or "".
repository_of() {   # $1 = crate dir
    [ -f "$1/Cargo.toml" ] || return 0
    awk '
        /^\[/ { in_pkg = ($0 ~ /^\[package\]/) }
        in_pkg && /^[[:space:]]*repository[[:space:]]*=/ {
            sub(/^[^=]*=[[:space:]]*/, ""); gsub(/^["\x27]|["\x27][[:space:]]*$/, "")
            print; exit
        }' "$1/Cargo.toml" | tr -d '\t\r\n'
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
# Invoked by xargs, one crate per call: copy/download, scan, keep or drop.
# argv: --worker <name> <version> <db path>
if [ "${1:-}" = "--worker" ]; then
    name="$2"; version="$3"; dbpath="$4"
    crate="${name}-${version}"
    state="$STATE_DIR/$crate.tsv"
    [ -f "$state" ] && exit 0                      # already processed

    fail() {   # $1 = status
        printf '%s\t%s\t%s\t\t0\t0\t0\t0\t%s\n' "$crate" "$name" "$version" "$1" > "$state"
        echo "    fail ($1): $crate" >&2
        exit 0
    }

    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/cffi.XXXXXX")" || exit 0
    trap 'rm -rf "$tmpdir"' EXIT

    downloaded=0
    if [ -n "$SRC_ROOT" ] && [ -d "$SRC_ROOT/$dbpath" ]; then
        cp -R "$SRC_ROOT/$dbpath" "$tmpdir/$crate" 2>/dev/null || fail copy-failed
        src="$tmpdir/$crate"
    else
        downloaded=1
        tarball="$tmpdir/$crate.crate"
        if ! curl -fsSL -A "$USER_AGENT" --retry 3 --retry-delay 2 --max-time 180 \
                  -o "$tarball" "$CDN/$name/$crate.crate" 2>/dev/null; then
            # CDN layout misses a few crates (odd names, build metadata in the
            # version); the API download endpoint redirects to the right object.
            curl -fsSL -A "$USER_AGENT" --retry 3 --retry-delay 2 --max-time 180 \
                 -o "$tarball" "$API/$name/$version/download" 2>/dev/null || fail download-failed
        fi
        tar -xzf "$tarball" -C "$tmpdir" 2>/dev/null || fail extract-failed
        rm -f "$tarball"

        # A .crate unpacks to a single top-level dir, normally <name>-<version>.
        src="$tmpdir/$crate"
        if [ ! -d "$src" ]; then
            src="$(find "$tmpdir" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
            [ -d "$src" ] || fail extract-failed
        fi
    fi

    repository="$(repository_of "$src")"
    read -r n_c n_cu n_cpp n_files <<<"$(scan_crate "$src")"
    if [ $(( n_c + n_cu + n_cpp )) -gt 0 ]; then
        rm -rf "${OUTPUT_DIR:?}/$crate"
        if mv "$src" "$OUTPUT_DIR/$crate" 2>/dev/null; then
            status=kept
            echo "    keep: $crate  (C=$n_c C-unwind=$n_cu C++=$n_cpp in $n_files files)"
        else
            status=store-failed
            echo "    fail (store): $crate" >&2
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$crate" "$name" "$version" "$repository" \
            "$n_c" "$n_cu" "$n_cpp" "$n_files" "$status" > "$state"
    else
        # No C FFI -> the tree is dropped with the temp dir.
        printf '%s\t%s\t%s\t%s\t0\t0\t0\t0\tno-c-ffi\n' \
            "$crate" "$name" "$version" "$repository" > "$state"
    fi
    [ "$downloaded" -eq 1 ] && sleep "$SLEEP_BETWEEN"
    exit 0
fi

# --------------------------------- setup ----------------------------------- #
CSV_ONLY=0
if [ "${1:-}" = "--csv-only" ]; then CSV_ONLY=1; shift; fi

OUTPUT_DIR="${1:-capslock_ffi_crates}"
CSV_PATH="${2:-$HERE/capslock_ffi.csv}"

command -v curl >/dev/null || die "curl is required"
command -v tar  >/dev/null || die "tar is required"
command -v jq   >/dev/null || die "jq is required"
RG="$(command -v rg || true)"
[ -f "$FFI_JSON" ] || die "missing $FFI_JSON"
[ -f "$DB_JSON" ]  || die "missing $DB_JSON"
[ -z "$SRC_ROOT" ] || [ -d "$SRC_ROOT" ] || die "SRC_ROOT=$SRC_ROOT is not a directory"

mkdir -p "$OUTPUT_DIR" || die "cannot create $OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
STATE_DIR="$OUTPUT_DIR/_state"
CRATE_LIST="$OUTPUT_DIR/_crate_list.tsv"
mkdir -p "$STATE_DIR"

export SELF FFI_SCAN SLEEP_BETWEEN USER_AGENT API CDN FFI_RE RG SRC_ROOT \
       OUTPUT_DIR STATE_DIR

if [ "$CSV_ONLY" -eq 0 ]; then
# ---------------- phase 1: resolve exact versions from db.json -------------- #
echo "==> Resolving versions for $(jq length "$FFI_JSON") crates from $(basename "$DB_JSON") ..."
missing="$OUTPUT_DIR/_missing_from_db.txt"
# db.json values look like data-extracted/fe/01/erdy-0.1.3; the version is the
# basename minus the "<name>-" prefix.
jq -r --slurpfile db "$DB_JSON" '
    .[] as $n
    | ($db[0][$n] // null) as $p
    | if $p == null then "MISSING\t\($n)"
      else ($p | split("/") | last) as $base
           | [$n, ($base | ltrimstr($n + "-")), $p] | @tsv
      end' "$FFI_JSON" > "$CRATE_LIST.tmp" || die "failed to parse $FFI_JSON / $DB_JSON"
awk -F'\t' '$1 == "MISSING" { print $2 }' "$CRATE_LIST.tmp" > "$missing"
awk -F'\t' '$1 != "MISSING" && $2 != "" && !seen[$1]++' "$CRATE_LIST.tmp" > "$CRATE_LIST"
rm -f "$CRATE_LIST.tmp"
n_missing="$(wc -l < "$missing" | tr -d ' ')"
echo "    $(wc -l < "$CRATE_LIST" | tr -d ' ') resolved, $n_missing not in db.json"
[ "$n_missing" -gt 0 ] && echo "    (listed in $missing)"

# ------------------ phase 2: copy/download + scan + keep/drop --------------- #
todo="$(mktemp)"
while IFS=$'\t' read -r name version dbpath; do
    [ -f "$STATE_DIR/${name}-${version}.tsv" ] && continue
    printf '%s\t%s\t%s\n' "$name" "$version" "$dbpath" >> "$todo"
done < "$CRATE_LIST"

n_todo="$(wc -l < "$todo" | tr -d ' ')"
n_done=$(( $(wc -l < "$CRATE_LIST") - n_todo ))
echo "==> Fetching + scanning $n_todo crates with $JOBS workers ($n_done already done) ..."
[ -n "$SRC_ROOT" ] && echo "    (copying from $SRC_ROOT where present, else crates.io)"
if [ "$n_todo" -gt 0 ]; then
    awk -F'\t' '{ printf "%s%c%s%c%s%c", $1,0,$2,0,$3,0 }' "$todo" \
        | xargs -0 -n 3 -P "$JOBS" "$SELF" --worker
fi
rm -f "$todo"
fi

# ---------------------------- phase 3: write CSV ---------------------------- #
# Concatenate every per-crate verdict. Not `cat "$STATE_DIR"/*.tsv`: with ~17k
# files the expanded glob overflows ARG_MAX and cat silently reads nothing.
all_states() { find "$STATE_DIR" -maxdepth 1 -name '*.tsv' -exec cat {} + 2>/dev/null; }

echo "==> Writing $CSV_PATH ..."
{
    echo "crate,name,version,repository,host,extern_c,extern_c_unwind,extern_cpp,matched_files,status"
    all_states \
      | awk -F'\t' '$9 == "kept"' \
      | LC_ALL=C sort -t$'\t' -k1,1 \
      | while IFS=$'\t' read -r crate name version repository n_c n_cu n_cpp n_files _; do
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
tally() { all_states | awk -F'\t' -v s="$1" '$9 == s' | wc -l | tr -d ' '; }
kept="$(tally kept)"; none="$(tally no-c-ffi)"
dl_fail="$(tally download-failed)"; ex_fail="$(tally extract-failed)"
cp_fail="$(tally copy-failed)"; st_fail="$(tally store-failed)"

echo
echo "==> Done."
echo "    kept (C/C++ FFI):  $kept   -> $OUTPUT_DIR/"
echo "    dropped (no FFI):  $none"
echo "    download failures: $dl_fail"
echo "    extract failures:  $ex_fail"
[ "$cp_fail" -gt 0 ] && echo "    copy failures:     $cp_fail"
[ "$st_fail" -gt 0 ] && echo "    store failures:    $st_fail"
echo "    csv:               $CSV_PATH ($kept rows)"
echo "    per-crate verdicts: $STATE_DIR/"
exit 0
