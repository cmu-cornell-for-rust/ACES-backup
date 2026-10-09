#!/usr/bin/env bash
#
# fetch_crater_index.sh
#
#   Writes the name and version of every crate in saethlin/crater-at-home's
#   Miri run (https://miri.saethlin.dev), taken from the `const all = {...}`
#   table on the landing page (latest version of each crate). This is the
#   same index fetch_crater_foreign_fn.sh walks, without fetching any logs.
#
# Usage:
#   ./fetch_crater_index.sh [CSV_PATH]    # default: crater_all.csv
#   Output columns: name,version

set -euo pipefail

CSV_PATH="${1:-crater_all.csv}"
BASE="https://miri.saethlin.dev"

curl -sSf "$BASE/" | python3 -c '
import csv, json, re, sys
d = json.loads(re.search(r"const all =\s*(\{.*?\});", sys.stdin.read(), re.S).group(1))
w = csv.writer(sys.stdout)
w.writerow(["name", "version"])
for name, version in sorted(d.items()):
    w.writerow([name, version])
' > "$CSV_PATH.tmp"
mv "$CSV_PATH.tmp" "$CSV_PATH"
echo "wrote $(($(wc -l < "$CSV_PATH") - 1)) crates to $CSV_PATH"
