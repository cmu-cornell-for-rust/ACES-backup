# Sourced by the job launchers (not run directly).
#
#   slurm_shape NTASKS CPUS_PER_TASK MEM_MB
#
# Sets the array SLURM_SHAPE to the partition/task/cpu/mem flags for a
# one-node sbatch or srun request.
#
# Bridges-2 (detected by its RM-shared partition): RM-shared bills per core,
# allows at most 2000M per core and 64 cores per job, so cores per task are
# raised until the memory fits. A job too big for that takes a whole RM node
# (256G), or an RM-512 node past 250G. Elsewhere (e.g. ACES) the request is
# passed through unchanged. PARTITION=<name> forces a partition.
#
# Raising --cpus-per-task only widens the allocation: srun steps that pass
# their own --cpus-per-task still get exactly that many cores.

SHARED_MB_PER_CORE=2000
SHARED_MAX_CORES=64

slurm_shape() {
    local nt=$1 cpt=$2 mem=$3 part="${PARTITION:-}" c
    SLURM_SHAPE=()
    # Inside an allocation srun makes a step, where a partition doesn't apply.
    if [[ -n "${SLURM_JOB_ID:-}" ]] || { [[ -z "$part" ]] && ! sinfo -h -p RM-shared -o %P 2>/dev/null | grep -q .; }; then
        SLURM_SHAPE=(--ntasks="$nt" --cpus-per-task="$cpt" --mem="${mem}M")
        return 0
    fi
    if [[ -z "$part" || "$part" == RM-shared ]]; then
        c=$cpt
        while (( nt * c * SHARED_MB_PER_CORE < mem )); do c=$(( c + 1 )); done
        if (( nt * c <= SHARED_MAX_CORES )) || [[ "$part" == RM-shared ]]; then
            SLURM_SHAPE=(--partition=RM-shared --ntasks="$nt" --cpus-per-task="$c" --mem="${mem}M")
            return 0
        fi
        part=RM
        (( mem > 250000 )) && part=RM-512
    fi
    SLURM_SHAPE=(--partition="$part" --ntasks="$nt" --cpus-per-task="$cpt" --mem="${mem}M")
}

# mem_mb 32G | 512M | 32: memory in MB, with G = 1000M (a bare number is GB),
# so whole-GB requests land on whole RM-shared cores.
mem_mb() {
    [[ "$1" =~ ^([0-9]+)([KMGTkmgt]?)$ ]] || { echo "mem_mb: bad memory '$1'" >&2; return 1; }
    local n=$(( 10#${BASH_REMATCH[1]} ))
    case "${BASH_REMATCH[2]}" in
        [Kk]) echo $(( n / 1000 )) ;;
        [Mm]) echo "$n" ;;
        [Tt]) echo $(( n * 1000000 )) ;;
        *)    echo $(( n * 1000 )) ;;
    esac
}
