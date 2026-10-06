#!/usr/bin/env bash
#
# filter_unsafe_crates.sh
#
#   Runs `cargo geiger` over every crate already present in downloaded_crates
#   and records, for each one, where (if anywhere) `unsafe` shows up. No crates
#   are removed.
#
#   Pairs with download_top_crates.sh, which populates the directory.
#
#   Status written per crate (NOTE: this is our own classification, not
#   geiger's per-row symbol -- geiger uses "?" for "no forbid(unsafe_code)"):
#       !       = the crate's OWN code uses `unsafe`
#       ?       = own code is unsafe-free, but some dependency uses `unsafe`
#       :)      = no `unsafe` anywhere in the crate or its dependency tree
#       unknown = geiger could not build/analyze it (see geiger_errors.csv)
#
#   Outputs (in $OUTPUT_DIR/_logs):
#       unsafe_scan.csv          -> columns: crate, unsafe_status, feature_args
#                                   (unsafe_status = ! / ? / :) / unknown;
#                                    feature_args = extra flags needed to build it,
#                                    empty if it built with default features)
#       geiger_errors.csv        -> columns: crate, error  (the failing output
#                                   for crates marked "unknown")
#
# Requirements: bash, cargo, cargo-geiger, sed, grep
#       cargo install cargo-geiger

set -uo pipefail   # no -e; per-crate failures are handled inline

# ------------------------------ configuration ------------------------------ #
if [ "$#" -lt 1 ] || [ -z "${1:-}" ]; then
    echo "Usage: $0 <downloaded_crates_dir>" >&2
    echo "  e.g. $0 /scratch/group/p.cis260229.000/downloaded_crates" >&2
    exit 1
fi
OUTPUT_DIR="$1"   # directory to filter (positional arg, required)

# Extra geiger flags applied to EVERY crate. Leave EMPTY for default features.
# Do NOT put --all-features here: std-adjacent crates (addr2line, gimli,
# object, ...) enable `rustc-dep-of-std` under it and refuse to compile, and
# some even hard-error via compile_error!. Per-crate feature needs are handled
# automatically by the retry tiers in crate_has_unsafe().
GEIGER_ARGS="${GEIGER_ARGS:-}"

# Lints are irrelevant to detecting `unsafe`, so cap them. Cargo already caps
# lints for dependencies but NOT for the crate under test, so crates with
# #![deny(warnings)] (or hit by new deny-by-default nightly lints like
# dangerous_implicit_autorefs / mismatched_lifetime_syntaxes) otherwise fail
# the build over a lint. This recovers mime, try-lock, wait-timeout,
# serde_yaml, unsafe-libyaml, etc.
export RUSTFLAGS="${RUSTFLAGS:-} --cap-lints allow"

# Force one toolchain for the whole scan, ignoring any per-crate
# rust-toolchain(.toml) pins. Those pins make rustup try to download a
# different toolchain, which on this cluster fails with "Disk quota exceeded"
# (ff-0.14.0, sharded-slab) or leaves an unusable toolchain ("failed to run
# rustc", group-0.13.0). Defaults to the currently-active toolchain.
PIN_TOOLCHAIN="${PIN_TOOLCHAIN:-$(rustup show active-toolchain 2>/dev/null | awk '{print $1}')}"
[ -n "$PIN_TOOLCHAIN" ] && export RUSTUP_TOOLCHAIN="$PIN_TOOLCHAIN"
# --------------------------------------------------------------------------- #

LOG_DIR="$OUTPUT_DIR/_logs"
ERROR_CSV="$LOG_DIR/geiger_errors.csv"
RESULTS_CSV="$LOG_DIR/unsafe_scan.csv"
ESC=$(printf '\033')

# globals set by crate_has_unsafe() and read by the main loop
LAST_FEATS=""   # feature args that made the crate build ("" = default features)
LAST_ERR=""     # diagnostic / error text from the last (failing) attempt

die() { echo "ERROR: $*" >&2; exit 1; }

# RFC-4180 CSV field: wrap in double quotes, double any internal double quotes.
csv_field() {
    local s=${1//\"/\"\"}
    printf '"%s"' "$s"
}

command -v cargo >/dev/null || die "cargo is required"
cargo geiger --version >/dev/null 2>&1 \
    || die "cargo-geiger is required:  cargo install cargo-geiger"
[ -d "$OUTPUT_DIR" ] || die "$OUTPUT_DIR does not exist — run download_top_crates.sh first"

mkdir -p "$LOG_DIR"
printf 'crate,unsafe_status,feature_args\n' > "$RESULTS_CSV"
printf 'crate,error\n' > "$ERROR_CSV"

# ------------------- decide if geiger output shows unsafe ------------------- #
# Every table row looks like:
#     a/b  c/d  e/f  g/h  i/j   <symbol> <tree> name version
# where the second number of each "used/total" pair is the total unsafe items
# found.  total > 0  <=>  geiger prints "!".  This is symbol/emoji independent.
# The first row is the root crate; the rest are its dependencies (plus the
# trailing totals row, which can only be > 0 here if some dep is).
#
# returns 0 = root uses unsafe ("!"), 1 = no unsafe anywhere (":)"),
#         2 = could not determine,     3 = only deps use unsafe ("?")
row_has_unsafe() {
    local pair
    for pair in $(printf '%s' "$1" | grep -oE '[0-9]+/[0-9]+' | head -n5); do
        [ "${pair#*/}" -gt 0 ] && return 0
    done
    return 1
}

analyze_geiger_output() {
    local out="$1"
    [ -z "$out" ] && return 2
    out=$(printf '%s' "$out" | sed -E "s/${ESC}\[[0-9;]*[A-Za-z]//g")   # strip ANSI

    local metric_lines
    metric_lines=$(printf '%s\n' "$out" \
        | grep -E '^[[:space:]]*[0-9]+/[0-9]+([[:space:]]+[0-9]+/[0-9]+){4}')
    [ -z "$metric_lines" ] && return 2

    row_has_unsafe "$(printf '%s\n' "$metric_lines" | head -n1)" && return 0

    local line
    while IFS= read -r line; do
        row_has_unsafe "$line" && return 3
    done <<< "$(printf '%s\n' "$metric_lines" | tail -n +2)"
    return 1
}

# Runs geiger with escalating feature sets until it builds. On return:
#   exit code -> analyze_geiger_output (0 "!" / 1 ":)" / 2 unanalyzable / 3 "?")
#   LAST_FEATS -> the extra feature args that worked ("" if default features)
#   LAST_ERR   -> diagnostic text from the final failing attempt (for the error CSV)
crate_has_unsafe() {
    local dir="$1" out status errtxt feats=""
    local errfile; errfile=$(mktemp)
    LAST_FEATS=""
    LAST_ERR=""

    # --- pass 1: default features ---
    out=$( cd "$dir" && cargo geiger $GEIGER_ARGS 2>"$errfile" )
    status=$?
    errtxt=$(sed -E "s/${ESC}\[[0-9;]*[A-Za-z]//g" "$errfile")

    # --- pass 2: a target named the features it requires -> enable exactly those ---
    #     Catches cargo's own "requires the features: `bin`" (e.g. addr2line).
    if [ "$status" -ne 0 ] && printf '%s' "$errtxt" | grep -q 'requires the features:'; then
        feats=$(printf '%s' "$errtxt" \
                | grep -oE 'requires the features:[^\\]*' \
                | grep -oE '`[^`]+`' | tr -d '`' | sort -u | paste -sd, -)
        if [ -n "$feats" ]; then
            out=$( cd "$dir" && cargo geiger $GEIGER_ARGS --features "$feats" 2>"$errfile" )
            status=$?
            errtxt=$(sed -E "s/${ESC}\[[0-9;]*[A-Za-z]//g" "$errfile")
            [ "$status" -eq 0 ] && LAST_FEATS="--features $feats"
        fi
    fi

    # --- pass 3: still broken and the crate exposes a "full" feature ---
    #     derive/proc-macro crates (e.g. derive_more) compile_error! when no
    #     derive feature is enabled; "full" turns them all on.
    if [ "$status" -ne 0 ] && grep -qE '^[[:space:]]*full[[:space:]]*=' "$dir/Cargo.toml"; then
        out=$( cd "$dir" && cargo geiger $GEIGER_ARGS --features full 2>"$errfile" )
        status=$?
        errtxt=$(sed -E "s/${ESC}\[[0-9;]*[A-Za-z]//g" "$errfile")
        [ "$status" -eq 0 ] && LAST_FEATS="--features full"
    fi

    # --- pass 4: cargo panicked inside its own dependency-download path
    #     (e.g. the `pending_ids.insert` assertion on some dep graphs).
    #     Pre-fetch deps with plain cargo, then analyze --offline so geiger
    #     never re-enters the panicking download code. Reuses any feature(s)
    #     discovered in pass 2. Requires network for the fetch step. ---
    if [ "$status" -ne 0 ] \
       && printf '%s' "$errtxt" | grep -qE 'pending_ids\.insert|panicked at'; then
        ( cd "$dir" && cargo fetch ) >/dev/null 2>&1 || true
        out=$( cd "$dir" && cargo geiger $GEIGER_ARGS ${feats:+--features $feats} --offline 2>"$errfile" )
        status=$?
        errtxt=$(sed -E "s/${ESC}\[[0-9;]*[A-Za-z]//g" "$errfile")
        [ "$status" -eq 0 ] && LAST_FEATS="${feats:+--features $feats }--offline"
    fi

    # --- pass 5: an old proc-macro2 (and friends) fails on a newer nightly
    #     with `E0635: unknown feature proc_macro_span_shrink`. Bump just that
    #     dependency to a nightly-compatible version, then retry. Requires
    #     network + a Cargo.lock. Reuses any feature(s) from pass 2. ---
    if [ "$status" -ne 0 ] && printf '%s' "$errtxt" | grep -q 'proc_macro_span_shrink'; then
        ( cd "$dir" && cargo update -p proc-macro2 ) >/dev/null 2>&1 || true
        out=$( cd "$dir" && cargo geiger $GEIGER_ARGS ${feats:+--features $feats} 2>"$errfile" )
        status=$?
        errtxt=$(sed -E "s/${ESC}\[[0-9;]*[A-Za-z]//g" "$errfile")
        [ "$status" -eq 0 ] && LAST_FEATS="${feats:+--features $feats }(proc-macro2 bumped)"
    fi

    rm -f "$errfile"

    # diagnostic text for the error CSV: prefer stderr, fall back to stdout
    if [ -n "$errtxt" ]; then
        LAST_ERR="$errtxt"
    else
        LAST_ERR="$out"
    fi

    # record any always-on GEIGER_ARGS alongside the per-crate feature args
    if [ -n "${GEIGER_ARGS// }" ]; then
        LAST_FEATS="$GEIGER_ARGS${LAST_FEATS:+ }$LAST_FEATS"
    fi

    analyze_geiger_output "$out"
}

# Remove the build artifacts geiger left in a crate dir so a full scan doesn't
# fill the disk. rm -rf rather than `cargo clean`, because cargo clean has to
# resolve the manifest first and silently does nothing for exactly the crates
# that failed to build. A Cargo.lock geiger generated (the crate didn't ship
# one) is removed too; a shipped one is left as-is.
cleanup_crate() {
    local dir="$1" had_lock="$2"
    rm -rf "$dir/target"
    [ "$had_lock" = 0 ] && rm -f "$dir/Cargo.lock"
    return 0
}

# --------------------------- run geiger and record -------------------------- #
echo "==> Running cargo geiger and recording unsafe usage per crate ..."
shopt -s nullglob
n_unsafe=0; n_deps=0; n_safe=0; errored=0
for crate_dir in "$OUTPUT_DIR"/*/; do
    crate_dir="${crate_dir%/}"
    base=$(basename "$crate_dir")
    [ "$base" = "_logs" ] && continue
    [ -f "$crate_dir/Cargo.toml" ] || continue

    had_lock=0; [ -f "$crate_dir/Cargo.lock" ] && had_lock=1

    printf '    geiger: %-40s ' "$base"
    crate_has_unsafe "$crate_dir"
    case $? in
        0)  echo "!  unsafe"
            printf '%s,%s,%s\n' "$(csv_field "$base")" "$(csv_field '!')" "$(csv_field "$LAST_FEATS")" >> "$RESULTS_CSV"
            n_unsafe=$((n_unsafe+1)) ;;
        3)  echo "?  unsafe deps"
            printf '%s,%s,%s\n' "$(csv_field "$base")" "$(csv_field '?')" "$(csv_field "$LAST_FEATS")" >> "$RESULTS_CSV"
            n_deps=$((n_deps+1)) ;;
        1)  echo ":) safe"
            printf '%s,%s,%s\n' "$(csv_field "$base")" "$(csv_field ':)')" "$(csv_field "$LAST_FEATS")" >> "$RESULTS_CSV"
            n_safe=$((n_safe+1)) ;;
        2)  echo "unanalyzable"
            printf '%s,%s,\n' "$(csv_field "$base")" "$(csv_field unknown)" >> "$RESULTS_CSV"
            # collapse newlines/tabs so each crate is one CSV row
            err_flat=$(printf '%s' "$LAST_ERR" | tr '\n\r\t' '   ' | tr -s ' ')
            printf '%s,%s\n' "$(csv_field "$base")" "$(csv_field "$err_flat")" >> "$ERROR_CSV"
            errored=$((errored+1)) ;;
    esac

    # reclaim disk after each crate
    cleanup_crate "$crate_dir" "$had_lock"
done

echo
echo "==> Done."
echo "    ! unsafe (own code):   $n_unsafe"
echo "    ? unsafe deps only:    $n_deps"
echo "    :) no unsafe at all:   $n_safe"
echo "    could not analyze:     $errored -> $ERROR_CSV"
echo "    results:               $RESULTS_CSV"
