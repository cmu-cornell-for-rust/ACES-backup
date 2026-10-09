#!/usr/bin/env bash
#
# fetch_crater_foreign_fn.sh
#
#   Walks every crate in saethlin/crater-at-home's Miri run
#   (https://miri.saethlin.dev, one `cargo miri test` log per crate) and
#   records the crates whose log contains
#       error: unsupported operation: can't call foreign function
#   i.e. the equivalent of
#       grep -q "error: unsupported operation: can't call foreign function" ./err
#
#   The raw logs are pty output, so `error` is wrapped in ANSI color codes
#   (\e[1m\e[91merror\e[0m\e[1m: unsupported ...). A plain grep on the raw
#   bytes never matches; escape sequences are stripped first.
#
#   The crate list comes from the `const all = {...}` table on the landing
#   page (latest version of each crate). Logs are at /raw/<name>/<version>.
#   The full set is ~600 GB, so logs are streamed through the matcher and
#   never written to disk.
#
#   The only output is CSV_PATH:
#       crate,name,version,foreign_functions,log_url
#   foreign_functions is the `;`-joined set of functions Miri refused to call.
#
#   Resumable: while running, each processed crate appends
#   `name<TAB>version<TAB>status<TAB>functions` to CSV_PATH.state.tsv
#   (status: match | nomatch | nolog | fail; nolog = 404, the index lists
#   the crate but its log is gone). A re-run skips everything except
#   `fail`. When the run ends the CSV is written from it and the state file
#   is deleted, unless some fetches failed (re-run to retry those).
#
# Usage:
#   ./fetch_crater_foreign_fn.sh [CSV_PATH]      # directly
#   sbatch fetch_crater_foreign_fn.sh [CSV_PATH] # as a Slurm job (#SBATCH below)
#   CSV_PATH    default: crater_foreign_fn.csv
#   A job that hits its time limit can be resubmitted with the same CSV_PATH.
#
# Environment knobs:
#   JOBS=8      parallel download+scan workers. If the output fills with
#               `curl: (22) ... 503` or `(52) Empty reply from server` the
#               server is throttling: stop (progress is kept) and resubmit
#               with fewer. Workers already back off on their own (below).
#
# Requirements: bash, curl, perl, python3, tr, fold; flock (util-linux) if available.

# Ignored when run directly. One task: the work is network-bound and more
# tasks would just duplicate the crawl. Workers need only a few MB each.
#SBATCH --job-name=crater-foreign-fn
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=16G
#SBATCH --time=48:00:00
#SBATCH --output=crater_foreign_fn.%j.log
##SBATCH --account=<your-account>      # uncomment if your allocation needs it
##SBATCH --partition=cpu

set -uo pipefail   # no -e; per-crate failures are handled inline

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# ------------------------------ configuration ------------------------------ #
JOBS="${JOBS:-8}"
BASE="https://miri.saethlin.dev"
# Same string as the grep -q check, plus the backquoted function name.
NEEDLE_RE="error: unsupported operation: can't call foreign function \`[^\`]*\`"

# Logs are pty output: progress bars redraw with \r, so a whole log can be
# one multi-GB "line", and perl/grep hold a line in memory (OOM-killed on
# ACES). Split on \r and hard-wrap at 1 MB so memory stays bounded. The
# needle is ~60 bytes, so a wrap landing inside it is vanishingly rare.
strip_ansi() {
    tr '\r' '\n' | fold -b -w 1048576 \
        | perl -pe 's/\e\[[0-9;?]*[ -\/]*[@-~]//g; s/\e[()][0-9A-Za-z]//g'
}

# ------------------------------- worker mode ------------------------------- #
# Invoked by xargs as: SELF --one NAME VERSION   (STATE from the env)
if [[ "${1:-}" == "--one" ]]; then
    name="$2"; version="$3"
    url="$BASE/raw/$name/${version//+/%2B}"
    # Last line of the output is "curl strip grep" exit statuses (PIPESTATUS
    # doesn't survive the command substitution).
    # No --retry-delay: curl then backs off exponentially (1, 2, 4 .. 32 s),
    # which is what a 503 "slow down" wants.
    out="$(curl -sSf --retry 6 "$url" | strip_ansi \
           | grep -aoE "$NEEDLE_RE" | sed -E 's/.*`([^`]*)`$/\1/' | sort -u | paste -sd ';' -
           echo "${PIPESTATUS[0]} ${PIPESTATUS[1]} ${PIPESTATUS[2]}")"
    rcs="${out##*$'\n'}"; fns="${out%"$rcs"}"; fns="${fns%$'\n'}"
    read -r curl_rc strip_rc grep_rc <<< "$rcs"
    # curl/strip failing (or grep erroring, rc > 1) is a fetch failure;
    # grep finding nothing (rc 1) is not. A 404 won't fix itself on retry.
    # (curl's exit code for an HTTP error varies by version: 22, or 56 over
    # HTTP/2, so ask for the status explicitly.)
    if [[ "$curl_rc" != 0 ]] \
       && [[ "$(curl -sI -o /dev/null -w '%{http_code}' "$url")" == 404 ]]; then
        status=nolog; fns=""
    elif [[ "$curl_rc" != 0 || "$strip_rc" != 0 || "$grep_rc" -gt 1 ]]; then
        status=fail; fns=""
        # Still failing after curl's retries: hold this worker slot for a
        # while, so a throttled server sees the whole pool ease off.
        sleep 30
    elif [[ -n "$fns" ]]; then status=match
    else status=nomatch; fi
    line="$(printf '%s\t%s\t%s\t%s' "$name" "$version" "$status" "$fns")"
    # O_APPEND alone only keeps lines <= PIPE_BUF (4 KB) intact on a local
    # disk; a long function list or an NFS home can interleave workers.
    if command -v flock > /dev/null; then
        { flock 9; printf '%s\n' "$line" >&9; } 9>> "$STATE"
    else
        printf '%s\n' "$line" >> "$STATE"
    fi
    exit 0
fi

# -------------------------------- main mode -------------------------------- #
CSV_PATH="${1:-crater_foreign_fn.csv}"
STATE="$CSV_PATH.state.tsv"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
touch "$STATE"

echo "Fetching crate index from $BASE ..."
curl -sSf "$BASE/" | python3 -c '
import json, re, sys
d = json.loads(re.search(r"const all =\s*(\{.*?\});", sys.stdin.read(), re.S).group(1))
for k, v in d.items():
    print(f"{k}\t{v}")
' > "$TMP/index.tsv" || { echo "failed to fetch index" >&2; exit 1; }

# Drop stale `fail` lines; everything not settled (match/nomatch) is (re)done.
awk -F'\t' '$3 != "fail"' "$STATE" > "$TMP/state" && cat "$TMP/state" > "$STATE"
# FILENAME, not NR==FNR: the state file is empty on the first run.
awk -F'\t' 'FILENAME == ARGV[1] { done[$1 "\t" $2] = 1; next } !(($1 "\t" $2) in done)' \
    "$STATE" "$TMP/index.tsv" > "$TMP/todo.tsv"
echo "$(wc -l < "$TMP/index.tsv") crates in index, $(wc -l < "$TMP/todo.tsv") to process (JOBS=$JOBS)"

export STATE
tr '\t\n' '\0\0' < "$TMP/todo.tsv" | xargs -0 -r -n 2 -P "$JOBS" "$SELF" --one

# ------------------------------- CSV rebuild ------------------------------- #
python3 - "$STATE" "$CSV_PATH" "$BASE" <<'EOF'
import csv, os, sys, urllib.parse
state, out, base = sys.argv[1:]
csv.field_size_limit(sys.maxsize)  # default 128 KB would reject a huge function list
rows, counts = {}, {}
for line in open(state):
    name, version, status, fns = (line.rstrip("\n").split("\t") + [""])[:4]
    rows[(name, version)] = (status, fns)
for status, _ in rows.values():
    counts[status] = counts.get(status, 0) + 1
# Write to a temp file and rename, so a crash never leaves a truncated CSV.
written = 0
with open(out + ".tmp", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["crate", "name", "version", "foreign_functions", "log_url"])
    for (name, version), (status, fns) in sorted(rows.items()):
        if status == "match":
            w.writerow([f"{name}-{version}", name, version, fns,
                        f"{base}/logs/{name}/{urllib.parse.quote(version)}"])
            written += 1
# Read it back: the state file is only deleted if every match made it in.
with open(out + ".tmp", newline="") as f:
    assert sum(1 for _ in csv.reader(f)) - 1 == written == counts.get("match", 0)
os.replace(out + ".tmp", out)
print(f"{counts}  ->  {out} ({written} rows)")
sys.exit(3 if counts.get("fail") else 0)  # 1 = uncaught exception
EOF
case $? in
    0) rm -f "$STATE" ;;
    3) echo "some fetches failed; kept $STATE, re-run to retry them" >&2 ;;
    *) echo "CSV write failed; kept $STATE, re-run to rebuild" >&2; exit 1 ;;
esac
