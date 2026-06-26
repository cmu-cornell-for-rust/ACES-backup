#!/usr/bin/env bash
# Usage: ./build-sif.sh rust              (builds rust.def -> ../rust.sif)
#        ./build-sif.sh rust.def          (same)
#        ./build-sif.sh bsan <ref>        (optional 2nd arg: git branch/commit
#                                          to build bsan from; defaults to main)
set -euo pipefail

# Accept "rust" or "rust.def"
name="${1%.def}"
# Optional git branch/commit to check out (consumed by defs that reference the
# BSAN_REF build arg, e.g. bsan.def). Empty => build from the default branch.
ref="${2:-}"

# Output image name. When a ref is given, tag the image as "<ref>-<image>" so
# branch/commit builds don't clobber the default one. Slashes in the ref (e.g.
# "feature/foo") are flattened to dashes so it's a valid filename.
if [[ -n "$ref" ]]; then
    outname="${ref//\//-}-${name}"
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

# BSAN_REF is forwarded to the def file as a build arg ({{ BSAN_REF }}). It is
# harmless for defs that don't reference it. Empty value => build from default.
singularity build --fakeroot --build-arg BSAN_REF="${ref}" \
    "${tmp_dir}/${outname}.sif" "${name}.def"
cp -f "${tmp_dir}/${outname}.sif" "../${outname}.sif"
echo ">> Done: ../${outname}.sif"
