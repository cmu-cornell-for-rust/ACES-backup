#!/usr/bin/env bash
# Usage: ./build-sif.sh rust        (builds rust.def -> ../rust.sif)
#        ./build-sif.sh rust.def    (same)
set -euo pipefail

# Accept "rust" or "rust.def"
name="${1%.def}"

# If not already inside an allocation, grab a compute node and re-exec there.
# exec replaces this process so the build runs on the compute node, not the
# login node.
if [[ -z "${SLURM_JOB_ID:-}" ]]; then
    script="$(readlink -f "$0")"
    exec srun --nodes=1 --ntasks-per-node=1 --mem=32G --time=02:00:00 \
        bash "$script" "$name"
fi

# --- below runs on the compute node ---

module load WebProxy

tmp_dir="/tmp/${USER}/sif-build.$$"
export SINGULARITY_TMPDIR="${tmp_dir}/tmp"
mkdir -p "$SINGULARITY_TMPDIR"
trap 'rm -rf "$tmp_dir"' EXIT

singularity build --fakeroot "${tmp_dir}/${name}.sif" "${name}.def"
cp -f "${tmp_dir}/${name}.sif" "../${name}.sif"
echo ">> Done: ../${name}.sif"
