#!/bin/bash
#
# Usage: ./run_image.sh [-J NAME] <image.sif> <HH[:MM]> [MEM]
#
#   -J, --name   optional SLURM job name
#   <image.sif>  path to the Rust SIF image
#   <HH[:MM]>    walltime as whole hours (4 -> 04:00:00) or HH:MM (4:30 -> 04:30:00)
#   [MEM]        memory, e.g. 32G, 64G, 512M. Bare number = GB. Default: 32G
#
# Grabs an interactive allocation, then -- ON THE COMPUTE NODE -- loads
# WebProxy + singularity, sets up writable scratch, and drops you straight
# into a shell INSIDE the container at /work. Just run `cargo build --release`.
# Exit the container shell to release the allocation.
set -euo pipefail

JOBNAME=""

# Parse optional leading flags (only -J/--name for now).
while [[ $# -gt 0 ]]; do
    case "$1" in
        -J|--name)
            if [[ $# -lt 2 ]]; then
                echo "Error: $1 requires a value." >&2
                exit 1
            fi
            JOBNAME="$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "Error: unknown option '$1'." >&2
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "Usage: $0 [-J NAME] <image.sif> <HH[:MM]> [MEM]" >&2
    echo "  -J, --name: optional SLURM job name" >&2
    echo "  HH[:MM]: walltime as hours (4) or HH:MM (4:30)" >&2
    echo "  MEM: e.g. 32G, 64G, 512M (bare number = GB). Default: 32G" >&2
    exit 1
fi

SIF="$1"
TIME="$2"
MEM="${3:-32G}"

# Walltime: accept HH (1-2 digits) or HH:MM.
if [[ "$TIME" =~ ^([0-9]{1,2})$ ]]; then
    WALLTIME=$(printf '%02d:00:00' "$((10#${BASH_REMATCH[1]}))")
elif [[ "$TIME" =~ ^([0-9]{1,2}):([0-9]{2})$ ]]; then
    H=$((10#${BASH_REMATCH[1]}))
    M=$((10#${BASH_REMATCH[2]}))
    if (( M > 59 )); then
        echo "Error: minutes must be 00-59 (got '${BASH_REMATCH[2]}')." >&2
        exit 1
    fi
    WALLTIME=$(printf '%02d:%02d:00' "$H" "$M")
else
    echo "Error: time must be HH or HH:MM (e.g. 4 or 4:30)." >&2
    exit 1
fi

if [[ "$MEM" =~ ^[0-9]+$ ]]; then
    MEM="${MEM}G"
elif ! [[ "$MEM" =~ ^[0-9]+[KMGT]$ ]]; then
    echo "Error: MEM must be like 32G, 512M, or a bare number (GB)." >&2
    exit 1
fi

# Absolute image path: always under the shared containers dir. Only the
# basename of the argument is used, and a ".sif" extension is added if absent,
# so `rust`, `rust.sif`, or `/some/path/rust.sif` all resolve to the same file.
# Exported so srun propagates it into the node script.
CONTAINERS_DIR="/scratch/group/p.cis260229.000/containers"
IMG="$(basename "$SIF")"
[[ "$IMG" == *.sif ]] || IMG="${IMG}.sif"
export SIF_ABS="$CONTAINERS_DIR/$IMG"
if [[ ! -f "$SIF_ABS" ]]; then
    echo "Error: image '$SIF_ABS' not found." >&2
    exit 1
fi

# Script that runs ON THE NODE: it loads modules, sets up scratch, and execs
# into the container. Written under $HOME because /tmp is typically node-local
# and wouldn't be visible from the compute node. Quoted heredoc => literal,
# so $USER/$SLURM_JOB_ID/$PWD/$http_proxy/$SIF_ABS all resolve on the node.
NODE_SCRIPT="$(mktemp "$HOME/.run_image_node.XXXXXX")"
trap 'rm -f "$NODE_SCRIPT"' EXIT

cat > "$NODE_SCRIPT" << 'NODE_EOF'
# Make 'module' available if the profile didn't already provide it.
if ! command -v module &>/dev/null; then
    source /etc/profile.d/lmod.sh    2>/dev/null || \
    source /etc/profile.d/modules.sh 2>/dev/null || true
fi

# Internet access on the compute node (sets http_proxy/https_proxy).
module load WebProxy

# Singularity only exists here on the node, not on the login node.
command -v singularity &>/dev/null || \
    module load Singularity 2>/dev/null || \
    module load singularity 2>/dev/null || true
if ! command -v singularity &>/dev/null; then
    echo "Error: 'singularity' not found on this node. Dropping to a node shell." >&2
    echo "Try: module spider singularity" >&2
    exec bash -i
fi

# Writable per-job scratch under group space, bound at the SAME path in/out.
JOBSCRATCH="/scratch/group/p.cis260229.000/$USER/cargo-$SLURM_JOB_ID"
mkdir -p "$JOBSCRATCH/home" "$JOBSCRATCH/target"

echo
echo "Entering container at /work. Inside, build with:"
echo "    cargo build --release"
echo "(scratch: $JOBSCRATCH ; type 'exit' to leave the container and release the node)"
echo

# Drop into an interactive shell INSIDE the container. Only
# CARGO_HOME/CARGO_TARGET_DIR are redirected to writable scratch; RUSTUP_HOME
# and PATH stay pointed at the read-only toolchain baked into the image.
exec singularity shell --cleanenv --pwd /work \
    --bind "$JOBSCRATCH" --bind "$PWD:/work" \
    --env CARGO_HOME="$JOBSCRATCH/home" \
    --env CARGO_TARGET_DIR="$JOBSCRATCH/target" \
    --env http_proxy="$http_proxy"   --env https_proxy="$https_proxy" \
    --env HTTP_PROXY="$HTTP_PROXY"   --env HTTPS_PROXY="$HTTPS_PROXY" \
    "$SIF_ABS"
NODE_EOF

# Assemble srun arguments, adding --job-name only if one was given.
SRUN_ARGS=(--nodes=1 --ntasks-per-node=1 --mem="${MEM}" --time="${WALLTIME}" --pty)
if [[ -n "$JOBNAME" ]]; then
    SRUN_ARGS=(--job-name="$JOBNAME" "${SRUN_ARGS[@]}")
fi

echo "Requesting interactive node: 1 task, ${MEM}, ${WALLTIME}${JOBNAME:+, job=${JOBNAME}}, image=${SIF_ABS}"

# Land on the node and run the node script, which execs into the container.
srun "${SRUN_ARGS[@]}" bash "$NODE_SCRIPT"
