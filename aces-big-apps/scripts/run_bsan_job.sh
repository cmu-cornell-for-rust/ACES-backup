#!/usr/bin/env bash
# Run a command inside a Singularity image on a compute node.
# Usage: run_bsan_job.sh [-J NAME] [--dry-run] [image.sif] <HH[:MM]> [MEM] -- <command>
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

JOBNAME=""
IMAGE=""
DRY_RUN=0
POSARGS=()
CMD=()
SEP_SEEN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --) SEP_SEEN=1; shift; CMD=("$@"); break ;;
    -J|--name) JOBNAME="$2"; shift 2 ;;
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

[[ "$SEP_SEEN" -eq 1 && ${#CMD[@]} -gt 0 ]] || die "Usage: run_bsan_job.sh [-J NAME] [--dry-run] [image.sif] <HH[:MM]> [MEM] -- <command>"

TIME="${POSARGS[0]:?walltime required}"
MEM="${POSARGS[1]:-32}"
if [[ "${MEM}" != *G && "${MEM}" != *M ]]; then MEM="${MEM}G"; fi
[[ -n "${IMAGE}" ]] || IMAGE="${BSAN_IMAGE}"
IMAGE="$(resolve_image "${IMAGE}")"

case "${TIME}" in
  *:*:*) WALLTIME="${TIME}" ;;
  *:*) h="${TIME%%:*}"; m="${TIME##*:}"; WALLTIME="0${h}:$(printf '%02d' "${m}"):00" ;;
  *) WALLTIME="$(printf '%02d' "${TIME}"):00:00" ;;
esac

WORKDIR_ABS="$(pwd)"
CMD_STR="${CMD[*]}"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  log "DRY-RUN: would submit ${IMAGE} ${MEM} ${WALLTIME} ${JOBNAME:+-J ${JOBNAME}}"
  log "DRY-RUN: ${CMD_STR}"
  exit 0
fi

SRUN_ARGS=(-A "${SLURM_ACCOUNT}" --nodes=1 --ntasks-per-node=1 --mem="${MEM}" --time="${WALLTIME}")
[[ -n "${JOBNAME}" ]] && SRUN_ARGS=(--job-name="${JOBNAME}" "${SRUN_ARGS[@]}")

log "Submitting: ${IMAGE} ${MEM} ${WALLTIME} ${JOBNAME:+-J ${JOBNAME}}"

srun "${SRUN_ARGS[@]}" bash -s -- "${IMAGE}" "${WORKDIR_ABS}" "${CMD_STR}" <<'NODE'
set -euo pipefail
SIF_ABS="$1"
WORKDIR_ABS="$2"
CMD_STR="$3"

module load WebProxy 2>/dev/null || true
command -v singularity &>/dev/null || module load Singularity 2>/dev/null || module load singularity 2>/dev/null || true
command -v singularity &>/dev/null || { echo "singularity not found"; exit 1; }

# shellcheck source=/dev/null
source "${WORKDIR_ABS}/config.env"

mkdir -p "${CARGO_HOME}" "${RUSTUP_HOME}" "${APPS_DIR}" "${OUTPUT_DIR}"

echo "Container: ${SIF_ABS}"
echo "Command:   ${CMD_STR}"

singularity exec --cleanenv --pwd "${WORKDIR_ABS}" \
  --bind "${USER_SCRATCH}:${USER_SCRATCH}" \
  --bind "${GROUP_ROOT}:${GROUP_ROOT}" \
  --bind "${WORKDIR_ABS}:${WORKDIR_ABS}" \
  --env ACES_ROOT="${ACES_ROOT}" \
  --env CARGO_HOME="${CARGO_HOME}" \
  --env RUSTUP_HOME="${RUSTUP_HOME}" \
  --env PATH="${CARGO_HOME}/bin:/opt/cargo/bin:/opt/rust/cargo/bin:${PATH}" \
  --env http_proxy="${http_proxy:-}" --env https_proxy="${https_proxy:-}" \
  --env HTTP_PROXY="${HTTP_PROXY:-}" --env HTTPS_PROXY="${HTTPS_PROXY:-}" \
  "${SIF_ABS}" bash -lc "${CMD_STR}"
NODE
