#!/bin/bash
#
# Usage: ./run_job.sh [-J NAME] [-c N] <image.sif> <HH[:MM]> [MEM] -- <command> [args...]
#
#   -J, --name   optional SLURM job name
#   -c, --cpus   cores for the task (--cpus-per-task). Default: 4. cargo sizes
#                its own build parallelism from the affinity mask SLURM sets, so
#                this is also the effective `cargo build -j`. Raising it makes a
#                job build faster but request more of the node, so a sweep at
#                MAX_PARALLEL=40 asks for 40*N cores and may queue longer.
#   <image.sif>  path to the Rust SIF image (basename resolved under the shared
#                containers dir; `rust`, `rust.sif`, `/x/rust.sif` all work)
#   <HH[:MM]>    walltime as whole hours (4 -> 04:00:00) or HH:MM (4:30 -> 04:30:00)
#   [MEM]        memory, e.g. 32G, 64G, 512M. Bare number = GB. Default: 32G
#   --           separates script args from the command to run in the container
#   <command>    a shell command line to run INSIDE the container at /work
#
# Grabs a one-shot allocation, then -- ON THE COMPUTE NODE -- loads
# WebProxy + singularity, sets up writable scratch, and runs your command
# INSIDE the container with the directory you launched from bound at /work.
# The command's exit code is propagated as this script's exit code. The per-job
# scratch dir (cargo-<SLURM_JOB_ID>) is removed when the job finishes.
#
# Everything after `--` is joined into a single string and run via `bash -c`
# inside the container, so shell features (&&, ||, |, ;, cd, globs, env vars)
# all work -- BUT operators must be quoted so your login shell doesn't eat
# them before the script sees them. Quote the whole command line to be safe.
# Note: because the parts are space-joined, an argument that must contain
# literal spaces needs its own embedded quoting, e.g. '"a b.txt"'.
#
# The directory you run from is captured up front and bound by absolute path,
# so you can invoke this from anywhere in the group directory and /work will
# always be your current directory.
#
# Examples:
#   ./run_job.sh rust 4 -- cargo build --release
#   ./run_job.sh -J build rust 2:30 64G -- 'cd crates/foo && cargo test'
#   ./run_job.sh rust 4 -- 'cargo build --release && cargo test'
set -euo pipefail

JOBNAME=""
CPUS=4          # --cpus-per-task; also what cargo picks up as its -j

# Parse optional leading flags (-J/--name, -c/--cpus).
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
        -c|--cpus)
            if [[ $# -lt 2 ]]; then
                echo "Error: $1 requires a value." >&2
                exit 1
            fi
            CPUS="$2"
            shift 2
            ;;
        --cpus=*)
            CPUS="${1#*=}"
            shift
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

# Split remaining args at the first standalone `--`: everything before it is
# positional (SIF/TIME/MEM), everything after it is the command to run.
POSARGS=()
CMD=()
SEP_SEEN=0
while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--" ]]; then
        SEP_SEEN=1
        shift
        CMD=("$@")
        break
    fi
    POSARGS+=("$1")
    shift
done

if [[ "$SEP_SEEN" -eq 0 || ${#CMD[@]} -eq 0 ]]; then
    echo "Error: no command given. Put the command after '--'." >&2
    echo "Usage: $0 [-J NAME] [-c N] <image.sif> <HH[:MM]> [MEM] -- <command> [args...]" >&2
    exit 1
fi

set -- "${POSARGS[@]}"
if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "Usage: $0 [-J NAME] [-c N] <image.sif> <HH[:MM]> [MEM] -- <command> [args...]" >&2
    echo "  -J, --name: optional SLURM job name" >&2
    echo "  -c, --cpus: cores for the task (--cpus-per-task). Default: 4" >&2
    echo "  HH[:MM]: walltime as hours (4) or HH:MM (4:30)" >&2
    echo "  MEM: e.g. 32G, 64G, 512M (bare number = GB). Default: 32G" >&2
    exit 1
fi

SIF="$1"
TIME="$2"
MEM="${3:-32G}"

if ! [[ "$CPUS" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: --cpus must be a positive integer (got '$CPUS')." >&2
    exit 1
fi

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

# Capture the launch directory NOW, on the login node, as a canonical absolute
# path, and export it. The node script binds this exact path to /work instead
# of relying on $PWD being preserved across srun -- so the script works from
# anywhere in the group directory.
export WORKDIR_ABS="$(pwd -P)"

# Script that runs ON THE NODE: it loads modules, sets up scratch, and runs
# the command inside the container. Written under $HOME because /tmp is
# typically node-local and wouldn't be visible from the compute node. Quoted
# heredoc => literal, so $USER/$SLURM_JOB_ID/$http_proxy/$SIF_ABS/$WORKDIR_ABS
# all resolve on the node. The command line is passed as a single positional
# arg to this script (see srun line below) and captured into CMD_STR up front.
NODE_SCRIPT="$(mktemp "$HOME/.run_image_node.XXXXXX")"
trap 'rm -f "$NODE_SCRIPT"' EXIT

cat > "$NODE_SCRIPT" << 'NODE_EOF'
# Capture the command line to run before anything else can touch $@.
CMD_STR="$1"

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
    echo "Error: 'singularity' not found on this node." >&2
    echo "Try: module spider singularity" >&2
    exit 1
fi

# Writable per-job scratch under group space, bound at the SAME path in/out.
JOBSCRATCH="/scratch/group/p.cis260229.000/cargo-temp-$USER/cargo-$SLURM_JOB_ID"
mkdir -p "$JOBSCRATCH/home" "$JOBSCRATCH/target"

# Remove the per-job scratch when the node script exits, however it exits.
# (After singularity returns the bind mount is gone, so $JOBSCRATCH is a plain
# directory on the node and rm removes it and its contents entirely.)
trap 'rm -rf "$JOBSCRATCH" 2>/dev/null || true' EXIT

echo
echo "Running in container (/work -> $WORKDIR_ABS):"
echo "    $CMD_STR"
echo "(scratch: $JOBSCRATCH)"
echo

# Bound the stack before entering the container. BorrowSanitizer's shadow
# memory assumes Linux's modern top-down mmap layout, which the kernel only
# uses when RLIMIT_STACK is finite. SLURM propagates an unlimited stack, which
# forces the legacy bottom-up layout -- that loads shared libraries (libc) into
# bsan's shadow/origin regions, so every instrumented binary segfaults at
# startup. Singularity passes rlimits through, so lowering the soft limit here
# makes the container, and the binary it runs, inherit a compatible layout.
# Harmless for non-bsan images.
ulimit -S -s 8192

# Run the command INSIDE the container via `bash -c` so shell operators work.
# Non-login shell (-c, not -lc) so it inherits the toolchain PATH baked into
# the image rather than letting /etc/profile reset it. Only CARGO_HOME and
# CARGO_TARGET_DIR are redirected to writable scratch; RUSTUP_HOME and PATH
# stay pointed at the read-only toolchain. No exec, so the EXIT trap above can
# clean up the scratch; the container's exit code is captured and re-propagated.
singularity exec --cleanenv --pwd /work \
    --bind "$JOBSCRATCH" --bind "$WORKDIR_ABS:/work" \
    --env CARGO_HOME="$JOBSCRATCH/home" \
    --env CARGO_TARGET_DIR="$JOBSCRATCH/target" \
    --env http_proxy="$http_proxy"   --env https_proxy="$https_proxy" \
    --env HTTP_PROXY="$HTTP_PROXY"   --env HTTPS_PROXY="$HTTPS_PROXY" \
    "$SIF_ABS" bash -c "$CMD_STR"
status=$?

exit "$status"
NODE_EOF

# Assemble srun arguments, adding --job-name only if one was given.
# No --pty now: this is a one-shot batch-style command, not an interactive shell.
SRUN_ARGS=(--nodes=1 --ntasks-per-node=1 --cpus-per-task="${CPUS}"
           --mem="${MEM}" --time="${WALLTIME}")
if [[ -n "$JOBNAME" ]]; then
    SRUN_ARGS=(--job-name="$JOBNAME" "${SRUN_ARGS[@]}")
fi

echo "Requesting node: 1 task, ${CPUS} cpu(s), ${MEM}, ${WALLTIME}${JOBNAME:+, job=${JOBNAME}}, image=${SIF_ABS}"

# Land on the node and run the node script, passing the command as ONE arg.
# "${CMD[*]}" joins the post-`--` words with a single space into a command
# line that the node script hands to `bash -c`.
# Capture the exit status (don't let set -e abort before we can propagate it).
status=0
srun "${SRUN_ARGS[@]}" bash "$NODE_SCRIPT" "${CMD[*]}" || status=$?
exit "$status"
