#!/usr/bin/env bash
#
# Usage: make_fast_dataset.sh <ignorefile> [src_dataset] [dest_dataset]
#
#   <ignorefile>    file of crate names to skip, one per line (blank lines and
#                   #-comments ignored). Names match the crate directory
#                   basenames under the dataset (e.g. bstr-1.12.1).
#   [src_dataset]   folder under the group datasets dir to copy from
#                   (default: top_500).
#   [dest_dataset]  folder under the group datasets dir to create
#                   (default: top_500_fast).
#
# Creates <dest_dataset> and copies into it every crate subdirectory of
# <src_dataset> whose basename is NOT on the ignorelist. Refuses to run if the
# destination already exists, so a stale copy is never silently mixed with a
# fresh one.
set -euo pipefail

# ── Layout (all absolute, so this can be run from anywhere) ───────────────────
GROUP="/scratch/group/p.cis260229.000"
DATASETS_ROOT="$GROUP/datasets"

# ── Args ──────────────────────────────────────────────────────────────────--
if [[ $# -lt 1 || $# -gt 3 ]]; then
    echo "Usage: $(basename "$0") <ignorefile> [src_dataset] [dest_dataset]" >&2
    exit 1
fi
IGNORE_FILE="$1"
SRC_DIR="$DATASETS_ROOT/${2:-top_500}"
DEST_DIR="$DATASETS_ROOT/${3:-top_500_fast}"

[[ -f "$IGNORE_FILE" ]] \
    || { echo "Error: ignorelist not found: $IGNORE_FILE" >&2; exit 1; }
[[ -d "$SRC_DIR" ]] \
    || { echo "Error: dataset dir not found: $SRC_DIR" >&2; exit 1; }
[[ ! -e "$DEST_DIR" ]] \
    || { echo "Error: destination already exists: $DEST_DIR" >&2; exit 1; }

# Load the ignorelist: one crate-dir basename per line, with #-comments and
# whitespace stripped. Kept as a newline-separated string (not an associative
# array) so the script also runs under macOS's bash 3.2.
IGNORE_NAMES="$(sed 's/#.*//; s/[[:space:]]//g' "$IGNORE_FILE" | grep -v '^$' || true)"

# ── Copy every crate dir not on the ignorelist ────────────────────────────────
mkdir -p "$DEST_DIR"
copied=0
skipped=0
for d in "$SRC_DIR"/*/; do
    [[ -d "$d" ]] || continue
    crate="$(basename "${d%/}")"
    if grep -qxF "$crate" <<< "$IGNORE_NAMES"; then
        skipped=$((skipped + 1))
        continue
    fi
    cp -R "${d%/}" "$DEST_DIR/"
    copied=$((copied + 1))
done

echo "Copied $copied crate(s) to $DEST_DIR ($skipped skipped via ignorelist)."

