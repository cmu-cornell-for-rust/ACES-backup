#!/usr/bin/env bash
#
# fetch_all_c_ffi_crates.sh
#
#   Downloads EVERY crate on crates.io (~340k, one version each), greps each
#   one's Rust sources for C / C++ FFI declarations, and records the crates
#   that have them in all_c_ffi_crates.csv. No crate sources are kept: every
#   crate is extracted to a temp dir, scanned, and deleted.
#
#   Same scan and CSV as fetch_c_ffi_crates.sh; only the crate list differs.
#   Instead of paging the API (crates.io asks bulk users not to), the list
#   comes from the nightly database dump, https://static.crates.io/db-dump.tar.gz
#   (~2 GB). For each crate we take its *default version* (the
#   default_versions table: the version crates.io shows on the crate page,
#   normally the highest non-yanked stable release) and its repository URL.
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
#   Crates with C FFI are written to all_c_ffi_crates.csv, in the same shape
#   as c_ffi_bindings.csv, one row per crate name:
#       crate,name,version,repository,host,extern_c,extern_c_unwind,extern_cpp,matched_files,status
#
#   Incremental: the CSV is updated in place, never rebuilt from scratch.
#     - a crate whose current version is already in the CSV is not downloaded;
#     - a crate already in the CSV at an OLDER version is re-scanned at the new
#       one and its row replaced (or removed, if the new version has no C FFI;
#       a failed download/extract leaves the old row alone);
#     - rows for crates no longer in the list are left as they are.
#   Every scanned name-version also leaves a verdict in OUTPUT_DIR/_state/, so
#   crates WITHOUT C FFI aren't re-downloaded either. Delete a marker (or the
#   whole _state dir) to force a re-scan. Per-crate failures never abort the run.
#
#   The crate list is cached in OUTPUT_DIR/_crate_list.tsv and rebuilt from a
#   fresh dump once it is older than LIST_MAX_AGE_HOURS (the dump is nightly,
#   so re-fetching more often gains nothing), which is how new versions and
#   newly published crates get picked up.
#
# Usage:
#   ./fetch_all_c_ffi_crates.sh [OUTPUT_DIR] [CSV_PATH]
#   ./fetch_all_c_ffi_crates.sh --csv-only [OUTPUT_DIR] [CSV_PATH]
#
#   OUTPUT_DIR  state dir (verdicts + crate list), default: all_c_ffi_crates
#   CSV_PATH    default: all_c_ffi_crates.csv (next to this script)
#
#   --csv-only  skip fetching: just merge the verdicts in OUTPUT_DIR/_state/
#               into the CSV.
#
# Environment knobs:
#   JOBS=8              parallel download+scan workers
#   SLEEP_BETWEEN=1     per-worker politeness delay, seconds
#   LIST_MAX_AGE_HOURS=24  rebuild the cached crate list from a new dump once
#                       it is older than this (0 = every run, -1 = never)
#   SKIP_YANKED=0       1 = skip crates whose default version is yanked
#   LIMIT=0             process at most N not-yet-done crates this run (0 = all)
#   DUMP_URL=...        db dump location (a file:// URL works for a local copy)
#   USER_AGENT=...      sent to crates.io (keep a contact address in it)
#
# Disk: the dump needs ~2 GB + ~3.5 GB extracted while the list is built;
# both are deleted afterwards. Beyond that, only one extracted crate per
# worker is on disk at a time.
#
# Requirements: bash 4+, curl, tar, python3. Uses ripgrep if present, else grep.

set -uo pipefail   # no -e; per-crate failures are handled inline

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# ------------------------------ configuration ------------------------------ #
JOBS="${JOBS:-8}"
SLEEP_BETWEEN="${SLEEP_BETWEEN:-1}"
SKIP_YANKED="${SKIP_YANKED:-0}"
LIMIT="${LIMIT:-0}"
LIST_MAX_AGE_HOURS="${LIST_MAX_AGE_HOURS:-24}"
USER_AGENT="${USER_AGENT:-aces-c-ffi-dataset-builder (CMU systems research; mmaclare@andrew.cmu.edu)}"

API="https://crates.io/api/v1/crates"
CDN="https://static.crates.io/crates"
DUMP_URL="${DUMP_URL:-https://static.crates.io/db-dump.tar.gz}"

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

# Concatenate every per-crate verdict. Not `cat "$STATE_DIR"/*.tsv`: with this
# many files the expanded glob overflows ARG_MAX and cat silently reads nothing.
all_states() { find "$STATE_DIR" -maxdepth 1 -name '*.tsv' -exec cat {} + 2>/dev/null; }

# ------------------------------- worker mode ------------------------------- #
# Invoked by xargs, one crate per call: download, extract, scan, record the
# verdict, delete the sources.
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

    # Either way the extracted tree is dropped with the temp dir (EXIT trap).
    read -r n_c n_cu n_cpp n_files <<<"$(scan_crate "$src")"
    if [ $(( n_c + n_cu + n_cpp )) -gt 0 ]; then
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\tkept\n' \
            "$crate" "$name" "$version" "$repository" \
            "$n_c" "$n_cu" "$n_cpp" "$n_files" > "$state"
        echo "    c-ffi: $crate  (C=$n_c C-unwind=$n_cu C++=$n_cpp in $n_files files)"
    else
        printf '%s\t%s\t%s\t%s\t0\t0\t0\t0\tno-c-ffi\n' \
            "$crate" "$name" "$version" "$repository" > "$state"
    fi
    sleep "$SLEEP_BETWEEN"
    exit 0
fi

# --------------------------------- setup ----------------------------------- #
CSV_ONLY=0
if [ "${1:-}" = "--csv-only" ]; then CSV_ONLY=1; shift; fi

OUTPUT_DIR="${1:-all_c_ffi_crates}"
CSV_PATH="${2:-$(dirname "$SELF")/all_c_ffi_crates.csv}"

command -v curl >/dev/null || die "curl is required"
command -v tar  >/dev/null || die "tar is required"
[ "$CSV_ONLY" -eq 1 ] || command -v python3 >/dev/null || die "python3 is required"
RG="$(command -v rg || true)"

mkdir -p "$OUTPUT_DIR" || die "cannot create $OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
STATE_DIR="$OUTPUT_DIR/_state"
CRATE_LIST="$OUTPUT_DIR/_crate_list.tsv"
mkdir -p "$STATE_DIR"

export SELF SLEEP_BETWEEN USER_AGENT API CDN FFI_RE RG \
       OUTPUT_DIR STATE_DIR

if [ "$CSV_ONLY" -eq 0 ]; then
# --------------- phase 1: build the crate list from the db dump ------------- #
list_fresh=0
if [ -s "$CRATE_LIST" ]; then
    if [ "$LIST_MAX_AGE_HOURS" -lt 0 ]; then
        list_fresh=1
    elif [ "$LIST_MAX_AGE_HOURS" -gt 0 ] \
         && [ -n "$(find "$CRATE_LIST" -mmin -$(( LIST_MAX_AGE_HOURS * 60 )) 2>/dev/null)" ]; then
        list_fresh=1
    fi
fi
if [ "$list_fresh" -eq 1 ]; then
    echo "==> Reusing cached crate list ($(wc -l < "$CRATE_LIST" | tr -d ' ') crates): $CRATE_LIST"
    echo "    (younger than LIST_MAX_AGE_HOURS=$LIST_MAX_AGE_HOURS; LIST_MAX_AGE_HOURS=0 forces a new dump)"
else
    dump_dir="$OUTPUT_DIR/_dump"
    mkdir -p "$dump_dir"
    echo "==> Downloading the crates.io database dump (~2 GB) ..."
    curl -fL -A "$USER_AGENT" --retry 3 --retry-delay 5 -o "$dump_dir/db-dump.tar.gz" "$DUMP_URL" \
        || die "failed to download $DUMP_URL"
    echo "==> Extracting crates / versions / default_versions ..."
    # The archive's top-level dir is the dump's timestamp, e.g. 2026-10-01-020025/.
    tar -xzf "$dump_dir/db-dump.tar.gz" -C "$dump_dir" --strip-components=1 \
        --wildcards '*/data/crates.csv' '*/data/versions.csv' '*/data/default_versions.csv' 2>/dev/null \
      || tar -xzf "$dump_dir/db-dump.tar.gz" -C "$dump_dir" --strip-components=1 \
        '*/data/crates.csv' '*/data/versions.csv' '*/data/default_versions.csv' \
      || die "failed to extract the dump"     # GNU tar needs --wildcards, bsdtar rejects it
    rm -f "$dump_dir/db-dump.tar.gz"

    echo "==> Resolving each crate's default version ..."
    # Writes name \t version \t repository \t (yanked|"") per crate.
    python3 - "$dump_dir/data" "$CRATE_LIST.tmp" <<'PY' || die "failed to build the crate list"
import csv, sys
csv.field_size_limit(sys.maxsize)            # crates.csv carries whole READMEs
data, out = sys.argv[1], sys.argv[2]

want = {}                                    # version_id -> crate_id
with open(f"{data}/default_versions.csv", newline="") as f:
    for r in csv.DictReader(f):
        want[r["version_id"]] = r["crate_id"]

ver = {}                                     # crate_id -> (num, yanked, repository)
with open(f"{data}/versions.csv", newline="") as f:
    for r in csv.DictReader(f):
        if r["id"] in want:
            ver[r["crate_id"]] = (r["num"], r["yanked"] == "t", r["repository"])

def clean(s):
    return " ".join((s or "").split())       # no tabs/newlines in the TSV

with open(f"{data}/crates.csv", newline="") as f, open(out, "w") as o:
    for r in csv.DictReader(f):
        v = ver.get(r["id"])
        if not v or not v[0]:
            continue
        repo = clean(v[2]) or clean(r["repository"])
        o.write(f"{r['name']}\t{v[0]}\t{repo}\t{'yanked' if v[1] else ''}\n")
PY
    rm -rf "$dump_dir"
    LC_ALL=C sort -t$'\t' -k1,1 -u "$CRATE_LIST.tmp" > "$CRATE_LIST"
    rm -f "$CRATE_LIST.tmp"
    echo "==> $(wc -l < "$CRATE_LIST" | tr -d ' ') crates" \
         "($(awk -F'\t' '$4 == "yanked"' "$CRATE_LIST" | wc -l | tr -d ' ') with a yanked default version)."
fi

# ------------------------ phase 2: download + scan -------------------------- #
# Skip a crate if the CSV already lists this exact name-version, or if this
# name-version was already scanned (covers the crates WITHOUT C FFI, which
# aren't in the CSV). Anything else is new, or a newer version of a CSV row.
todo="$(mktemp)"
in_csv="$(mktemp)"
# name<TAB>version of every existing row (name/version never need quoting).
[ -f "$CSV_PATH" ] && awk -F, 'NR>1 && $2 != "" {print $2 "\t" $3}' "$CSV_PATH" > "$in_csv"
awk -F'\t' -v state_dir="$STATE_DIR" -v skip_yanked="$SKIP_YANKED" '
    FILENAME == ARGV[1] { listed[$1 "\t" $2] = 1; csv_ver[$1] = $2; next }
    $1 == "" { next }
    skip_yanked == "1" && $4 == "yanked" { next }
    ($1 "\t" $2) in listed { next }
    { f = state_dir "/" $1 "-" $2 ".tsv"
      if ((getline _ < f) >= 0) { close(f); next }   # already scanned
      if ($1 in csv_ver) upd++; else new++
      print $1 "\t" $2 "\t" $3 }
    END { printf "%d %d\n", new+0, upd+0 > "/dev/stderr" }
' "$in_csv" "$CRATE_LIST" > "$todo" 2> "$todo.counts"
rm -f "$in_csv"
read -r n_new n_upd < "$todo.counts"; rm -f "$todo.counts"

if [ "$LIMIT" -gt 0 ]; then
    head -n "$LIMIT" "$todo" > "$todo.lim" && mv "$todo.lim" "$todo"
fi
n_todo="$(wc -l < "$todo" | tr -d ' ')"
echo "==> Downloading + scanning $n_todo crates with $JOBS workers" \
     "($n_upd new versions of CSV rows, $n_new others before LIMIT) ..."
if [ "$n_todo" -gt 0 ]; then
    # macOS xargs -0 silently drops empty arguments, which would shift the
    # 3-arg groups; send "-" for a missing repository and unmap it in the worker.
    awk -F'\t' 'BEGIN{OFS="\t"} {r=($3==""?"-":$3); printf "%s%c%s%c%s%c", $1,0,$2,0,r,0}' "$todo" \
        | xargs -0 -n 3 -P "$JOBS" "$SELF" --worker
fi
rm -f "$todo"
fi

# ---------------------------- phase 3: merge CSV ---------------------------- #
# Start from the existing rows and, per crate name, apply the verdict for the
# version currently in the crate list:
#   kept (C FFI)      -> (re)write the row from the verdict
#   no-c-ffi          -> drop the row (the current version lost its FFI)
#   failure / none    -> keep the existing row untouched
# Names in the list but not yet in the CSV get a row if their verdict is kept.
# awk tags each output line: R = existing CSV line verbatim, S = verdict to format.
echo "==> Updating $CSV_PATH ..."
csv_tmp="$(mktemp)"
csv_old="$(mktemp)"
[ -f "$CSV_PATH" ] && tail -n +2 "$CSV_PATH" > "$csv_old"
states="$(mktemp)"
all_states > "$states"
{
    echo "crate,name,version,repository,host,extern_c,extern_c_unwind,extern_cpp,matched_files,status"
    awk -F'\t' -v list="$CRATE_LIST" -v states="$states" '
            BEGIN {
                while ((getline l < list) > 0)   { split(l, f, "\t"); if (f[1] != "") cur[f[1]] = f[2] }
                while ((getline l < states) > 0) { split(l, f, "\t"); k = f[2] "\t" f[3]; verdict[k] = f[9]; line[k] = l }
            }
            {   split($0, f, ","); name = f[2]
                if (name == "" || (name in seen)) next
                seen[name] = 1
                k = name "\t" cur[name]
                if ((name in cur) && verdict[k] == "kept")          print "S\t" line[k]
                else if ((name in cur) && verdict[k] == "no-c-ffi") dropped++
                else                                                print "R\t" $0
            }
            END {
                for (name in cur) {
                    k = name "\t" cur[name]
                    if (!(name in seen) && verdict[k] == "kept") print "S\t" line[k]
                }
                printf "%d\n", dropped+0 > "/dev/stderr"
            }
        ' "$csv_old" 2> "$csv_tmp.dropped" \
      | while IFS=$'\t' read -r tag rest; do
            if [ "$tag" = R ]; then printf '%s\n' "$rest"; continue; fi
            IFS=$'\t' read -r crate name version repository n_c n_cu n_cpp n_files _ <<<"$rest"
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
        done \
      | LC_ALL=C sort -t, -k1,1
} > "$csv_tmp"
n_dropped="$(cat "$csv_tmp.dropped" 2>/dev/null || echo 0)"
rm -f "$csv_tmp.dropped" "$csv_old" "$states"
mv "$csv_tmp" "$CSV_PATH"

# --------------------------------- summary ---------------------------------- #
counts="$(all_states | awk -F'\t' '{ n[$9]++ } END { for (s in n) print s, n[s] }')"
tally() { awk -v s="$1" '$1 == s { print $2; f=1 } END { if (!f) print 0 }' <<<"$counts"; }
ffi="$(tally kept)"; none="$(tally no-c-ffi)"
dl_fail="$(tally download-failed)"; ex_fail="$(tally extract-failed)"

# Counts are over every verdict in _state, i.e. all versions ever scanned.
echo
echo "==> Done."
echo "    scanned with C/C++ FFI:  $ffi"
echo "    scanned without FFI:     $none"
echo "    download failures:       $dl_fail"
echo "    extract failures:        $ex_fail"
echo "    rows dropped (new version has no FFI): $n_dropped"
echo "    csv:                     $CSV_PATH ($(( $(wc -l < "$CSV_PATH") - 1 )) rows)"
echo "    per-crate verdicts:      $STATE_DIR/"
exit 0
