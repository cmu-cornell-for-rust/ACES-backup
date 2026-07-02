#!/usr/bin/env bash
# Run a command inside a Singularity image on a compute node.
# Usage: run_bsan_job.sh [-J NAME] [--batch] [--dry-run] [image.sif] <HH[:MM]> [MEM] -- <command>
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

JOBNAME=""
IMAGE=""
DRY_RUN=0
BATCH=0
POSARGS=()
CMD=()
SEP_SEEN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --) SEP_SEEN=1; shift; CMD=("$@"); break ;;
    -J|--name) JOBNAME="$2"; shift 2 ;;
    --batch) BATCH=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -*) die "Unknown option: $1" ;;
    *)
      if [[ -z "${IMAGE}" && "$1" == *.sif ]]; then
        IMAGE="$1"; shift
      else
        POSARGS+=("$1"); shift
      fi
      ;;
  esac
done

[[ "$SEP_SEEN" -eq 1 && ${#CMD[@]} -gt 0 ]] || die "Usage: run_bsan_job.sh [-J NAME] [--batch] [--dry-run] [image.sif] <HH[:MM]> [MEM] -- <command>"

TIME="${POSARGS[0]:?walltime required}"
MEM="${POSARGS[1]:-32}"
CPUS="${BSAN_CPUS:-${SMOKE_CPUS:-1}}"
if [[ "${MEM}" != *G && "${MEM}" != *M ]]; then MEM="${MEM}G"; fi
[[ -n "${IMAGE}" ]] || IMAGE="${BSAN_IMAGE}"
IMAGE="$(resolve_image "${IMAGE}")"

case "${TIME}" in
  *:*:*) WALLTIME="${TIME}" ;;
  *:*) h="${TIME%%:*}"; m="${TIME##*:}"; WALLTIME="0${h}:$(printf '%02d' "${m}"):00" ;;
  *) WALLTIME="$(printf '%02d' "${TIME}"):00:00" ;;
esac

WORKDIR_ABS="${ACES_ROOT}"
CMD_STR="${CMD[*]}"
SINGULARITY_RUN="${SCRIPT_DIR}/bsan_singularity_run.sh"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  log "DRY-RUN: would submit ${IMAGE} ${MEM} ${WALLTIME} ${JOBNAME:+-J ${JOBNAME}} batch=${BATCH}"
  log "DRY-RUN: ${CMD_STR}"
  exit 0
fi

if [[ "${BATCH}" -eq 1 ]]; then
  mkdir -p "${OUTPUT_DIR}/sbatch"
  job_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  job_label="${JOBNAME:-bsan-job}"
  wrapper="${OUTPUT_DIR}/sbatch/${job_label}.${job_stamp}.sh"
  {
    echo "#!/bin/bash"
    echo "#SBATCH -A ${SLURM_ACCOUNT}"
    echo "#SBATCH --job-name=${job_label}"
    echo "#SBATCH --nodes=1"
    echo "#SBATCH --ntasks-per-node=1"
    echo "#SBATCH --cpus-per-task=${CPUS}"
    echo "#SBATCH --mem=${MEM}"
    echo "#SBATCH --time=${WALLTIME}"
    echo "#SBATCH --output=${OUTPUT_DIR}/sbatch/${job_label}.%j.log"
    echo "export CPUS=${CPUS}"
    {
      printf 'exec %q' "${SINGULARITY_RUN}"
      printf ' %q' "${IMAGE}" "${WORKDIR_ABS}"
      printf ' %q' "${CMD[@]}"
      echo
    }
  } >"${wrapper}"
  chmod +x "${wrapper}"
  log "Submitting batch: ${IMAGE} ${MEM} ${WALLTIME} cpus=${CPUS} -J ${job_label}"
  job_id="$(sbatch --parsable "${wrapper}")"
  log "Submitted batch job ${job_id} (${job_label})"
  echo "${job_id}"
  exit 0
fi

SRUN_ARGS=(-A "${SLURM_ACCOUNT}" --nodes=1 --ntasks-per-node=1 --cpus-per-task="${CPUS}" --mem="${MEM}" --time="${WALLTIME}")
[[ -n "${BSAN_SRUN_IMMEDIATE:-}" ]] && SRUN_ARGS=(--immediate="${BSAN_SRUN_IMMEDIATE}" "${SRUN_ARGS[@]}")
[[ -n "${JOBNAME}" ]] && SRUN_ARGS=(--job-name="${JOBNAME}" "${SRUN_ARGS[@]}")

log "Submitting: ${IMAGE} ${MEM} ${WALLTIME} cpus=${CPUS} ${JOBNAME:+-J ${JOBNAME}}"
export CPUS

srun "${SRUN_ARGS[@]}" env CPUS="${CPUS}" "${SINGULARITY_RUN}" "${IMAGE}" "${WORKDIR_ABS}" "${CMD[@]}"
