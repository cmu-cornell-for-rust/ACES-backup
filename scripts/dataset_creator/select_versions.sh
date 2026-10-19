#!/usr/bin/env bash
#
# select_versions.sh
#
#   Prints the dataset dirs (<name>-<version>, one per line) a version
#   selection keeps, from a versions CSV as written by update_latest.py:
#   a column containing "name", one containing "version", and
#   latest_version / version_differs. Used by build_dataset.sh for its
#   version flags (only-first is here for completeness; build doesn't use it).
#
#   first        every crate at its listed (first) version
#   latest       every crate at latest_version (the first version where the
#                lookup failed, i.e. latest_version is empty)
#   only-latest  crates with version_differs=true, at latest_version
#   only-first   crates with version_differs=true, at the first version
#
#   `first` works on a CSV without the latest columns; the others exit 1
#   telling you to run update_latest.py. Fields may be double-quoted; a UTF-8
#   BOM is ignored.
#
# Usage:
#   ./select_versions.sh <first|latest|only-latest|only-first> <VERSIONS_CSV>

set -uo pipefail

[ "$#" -eq 2 ] || { echo "Usage: $0 <first|latest|only-latest|only-first> <VERSIONS_CSV>" >&2; exit 1; }
MODE="$1"; CSV="$2"
case "$MODE" in first|latest|only-latest|only-first) ;; *)
    echo "select_versions: unknown mode '$MODE'" >&2; exit 1 ;;
esac
[ -f "$CSV" ] || { echo "select_versions: versions CSV not found: $CSV" >&2; exit 1; }

LC_ALL=C awk -v mode="$MODE" -v csv="$CSV" '
    function splitcsv(line, f,    n, i, c, q, cur) {
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
    function trim(x) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", x); return x }
    BEGIN { bom = sprintf("%c%c%c", 239, 187, 191) }
    {
        line = $0
        sub(/\r$/, "", line)
        if (NR == 1 && index(line, bom) == 1) line = substr(line, 4)
        n = splitcsv(line, f)
        if (NR == 1) {
            for (i = 1; i <= n; i++) {
                h = tolower(trim(f[i]))
                if (h == "latest_version") li = i
                else if (h == "version_differs") di = i
                else if (!ni && index(h, "name")) ni = i
                else if (!vi && index(h, "version")) vi = i
            }
            if (!ni || !vi) { print "select_versions: no name/version column in " csv ": " line > "/dev/stderr"; bad = 1; exit 1 }
            if (mode != "first" && (!li || !di)) {
                print "select_versions: " csv " has no latest_version/version_differs columns;" > "/dev/stderr"
                print "  run dataset_creator/update_latest.py " csv " first." > "/dev/stderr"
                bad = 1; exit 1
            }
            next
        }
        name = trim(f[ni]); ver = trim(f[vi])
        if (name == "" || ver == "") next
        latest = li ? trim(f[li]) : ""; differs = di ? tolower(trim(f[di])) : ""
        if (mode == "first") out = name "-" ver
        else if (mode == "latest") {
            if (latest != "") out = name "-" latest
            else { out = name "-" ver; nolatest++ }
        }
        else if (differs != "true") next
        else out = name "-" (mode == "only-latest" ? latest : ver)
        if (!seen[out]++) { print out; count++ }
    }
    END {
        if (bad) exit 1
        if (!count) { print "select_versions: the " mode " selection from " csv " is empty" > "/dev/stderr"; exit 1 }
        if (nolatest) print "select_versions: " nolatest " crate(s) with no latest_version kept at their first version" > "/dev/stderr"
    }' "$CSV"
