#!/usr/bin/env bash
# Usage: ./build-sif.sh rust              (builds rust.def -> ../rust.sif)
#        ./build-sif.sh rust.def          (same)
#        ./build-sif.sh bsan <ref>        (optional 2nd arg: git branch/commit
#                                          to build bsan from; defaults to main)
#        ./build-sif.sh miri <ref>        (git branch/commit of the Miri fork,
#                                          e.g. lazy+gc, tracing; defaults to
#                                          the default branch)
#        ./build-sif.sh miri_latest       (upstream Miri; takes no ref -- only
#                                          bsan.def and miri.def accept one)
set -euo pipefail

# Accept "rust" or "rust.def"
name="${1%.def}"
# Optional git branch/commit to check out (consumed by defs that declare a
# *_REF build arg, i.e. bsan.def / miri.def). Empty => default branch.
ref="${2:-}"

# Only bsan.def and miri.def are parameterized; every other def (rust,
# miri_latest) always builds from its default branch, so a ref there is a
# mistake rather than something to silently drop. Checked here, before the
# srun re-exec, so it fails on the login node instead of after an allocation.
if [[ -n "$ref" && "$name" != "bsan" && "$name" != "miri" ]]; then
    echo "Error: ${name}.def takes no ref (got '$ref'); it always builds from" >&2
    echo "       the default branch. Use 'miri <ref>' for fork builds." >&2
    exit 1
fi

# Output image name. When a ref is given, tag the image as "<ref>-<image>" so
# branch/commit builds don't clobber the default one. Slashes in the ref (e.g.
# "feature/foo") are flattened to dashes so it's a valid filename, and pluses
# (e.g. "lazy+gc") too, so the name stays inert in regex/URL contexts.
if [[ -n "$ref" ]]; then
    slug="${ref//\//-}"
    slug="${slug//+/-}"
    outname="${slug}-${name}"
else
    outname="$name"
fi

# If not already inside an allocation, grab a compute node and re-exec there.
# exec replaces this process so the build runs on the compute node, not the
# login node.
if [[ -z "${SLURM_JOB_ID:-}" ]]; then
    script="$(readlink -f "$0")"
    exec srun --nodes=1 --ntasks-per-node=1 --mem=32G --time=02:00:00 \
        bash "$script" "$name" "$ref"
fi

# --- below runs on the compute node ---

module load WebProxy

tmp_dir="/tmp/${USER}/sif-build.$$"
export SINGULARITY_TMPDIR="${tmp_dir}/tmp"
mkdir -p "$SINGULARITY_TMPDIR"
trap 'rm -rf "$tmp_dir"' EXIT

# When a ref is given, forward it to the def as a build arg -- {{ BSAN_REF }}
# for bsan.def, {{ MIRI_REF }} for miri.def (the names must match the def's
# %arguments section or singularity rejects the build). We only pass
# --build-arg for a non-empty ref: singularity rejects an empty value
# ("missing value portion"), and the def supplies its own default (build from
# the default branch) via its %arguments section when none is passed.
# Unparameterized defs were already rejected above, so this only ever sees
# bsan/miri with a non-empty ref.
build_args=()
if [[ -n "$ref" ]]; then
    case "$name" in
        bsan) build_args=(--build-arg "BSAN_REF=${ref}") ;;
        miri) build_args=(--build-arg "MIRI_REF=${ref}") ;;
    esac
fi
singularity build --fakeroot "${build_args[@]+"${build_args[@]}"}" \
    "${tmp_dir}/${outname}.sif" "${name}.def"
cp -f "${tmp_dir}/${outname}.sif" "../${outname}.sif"
echo ">> Done: ../${outname}.sif"
