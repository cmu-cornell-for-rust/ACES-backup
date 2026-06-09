#!/usr/bin/env bash
#
# filter_unsafe_crates.sh
#
#   Runs `cargo geiger` over every crate already present in downloaded_crates
#   and removes the ones whose code contains NO `unsafe` usage — i.e. those
#   geiger marks ":)" or "?" — keeping only the ones marked "!".
#
#   Pairs with download_top_crates.sh, which populates the directory.
#
#   geiger legend (for reference):
#       :) = no `unsafe`, declares #![forbid(unsafe_code)]
#       ?  = no `unsafe`, missing #![forbid(unsafe_code)]
#       !  = `unsafe` usage found            <-- these are the ones we keep
#
#   Outputs (in $OUTPUT_DIR/_logs):
#       kept_unsafe_crates.csv   -> columns: crate, feature_args
#                                   (feature_args = extra flags needed to build it,
#                                    empty if it built with default features)
#       geiger_errors.csv        -> columns: crate, error  (the failing output)
#       removed_safe_crates.log  -> plain list of removed (no-unsafe) crates
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
INCLUDE_DEPS="${INCLUDE_DEPS:-0}"   # 0 = judge crate's OWN code only
                                    # 1 = keep if ANY crate in its dep tree uses unsafe

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
REMOVED_LOG="$LOG_DIR/removed_safe_crates.log"
KEPT_LOG="$LOG_DIR/kept_unsafe_crates.log"
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
: > "$KEPT_LOG"
printf 'crate,error\n' > "$ERROR_CSV"
: > "$REMOVED_LOG"

# ------------------- decide if geiger output shows unsafe ------------------- #
# Every table row looks like:
#     a/b  c/d  e/f  g/h  i/j   <symbol> <tree> name version
# where the second number of each "used/total" pair is the total unsafe items
# found.  total > 0  <=>  geiger prints "!".  This is symbol/emoji independent.
#
# returns 0 = unsafe found, 1 = no unsafe, 2 = could not determine
analyze_geiger_output() {
    local out="$1"
    [ -z "$out" ] && return 2
    out=$(printf '%s' "$out" | sed -E "s/${ESC}\[[0-9;]*[A-Za-z]//g")   # strip ANSI

    local metric_lines
    metric_lines=$(printf '%s\n' "$out" \
        | grep -E '^[[:space:]]*[0-9]+/[0-9]+([[:space:]]+[0-9]+/[0-9]+){4}')
    [ -z "$metric_lines" ] && return 2

    if [ "$INCLUDE_DEPS" != "1" ]; then
        # only the root crate matters -> the first metric line
        metric_lines=$(printf '%s\n' "$metric_lines" | head -n1)
    fi

    while IFS= read -r line; do
        for pair in $(printf '%s' "$line" | grep -oE '[0-9]+/[0-9]+' | head -n5); do
            [ "${pair#*/}" -gt 0 ] && return 0   # some total > 0  => "!"
        done
    done <<< "$metric_lines"
    return 1
}

# Runs geiger with escalating feature sets until it builds. On return:
#   exit code -> analyze_geiger_output (0 unsafe / 1 safe / 2 unanalyzable)
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

# --------------------------- run geiger and prune --------------------------- #
echo "==> Running cargo geiger and removing crates with no unsafe usage ..."
shopt -s nullglob
kept=0; removed=0; errored=0
for crate_dir in "$OUTPUT_DIR"/*/; do
    crate_dir="${crate_dir%/}"
    base=$(basename "$crate_dir")
    [ "$base" = "_logs" ] && continue
    [ -f "$crate_dir/Cargo.toml" ] || continue

    printf '    geiger: %-40s ' "$base"
    crate_has_unsafe "$crate_dir"
    case $? in
        0)  echo "unsafe -> keep"
            echo "$base" >> "$KEPT_LOG"
            kept=$((kept+1)) ;;
        1)  echo "safe   -> remove"
            echo "$base" >> "$REMOVED_LOG"
            rm -rf "$crate_dir"
            removed=$((removed+1)) ;;
        2)  echo "unanalyzable -> kept"
            # collapse newlines/tabs so each crate is one CSV row
            err_flat=$(printf '%s' "$LAST_ERR" | tr '\n\r\t' '   ' | tr -s ' ')
            printf '%s,%s\n' "$(csv_field "$base")" "$(csv_field "$err_flat")" >> "$ERROR_CSV"
            errored=$((errored+1)) ;;
    esac

    # reclaim disk after each crate, but only if it still exists
    if [ -d "$crate_dir" ]; then
        cargo clean --manifest-path "$crate_dir/Cargo.toml" >/dev/null 2>&1 || true
    fi
done

echo
echo "==> Done."
echo "    kept (unsafe found):   $kept    -> $KEPT_LOG"
echo "    removed (no unsafe):   $removed -> $REMOVED_LOG"
echo "    could not analyze:     $errored (left in place) -> $ERROR_CSV"
