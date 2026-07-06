#!/usr/bin/env bash
# Build bsan-ext.sif (group bsan + libseccomp-dev) on a compute node for firecracker.
# Usage: rebuild_bsan_ext_image_job.sh [walltime] [mem_GB]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

TIME="${1:-1:00}"
MEM="${2:-16}"
OUT_DIR="${USER_SCRATCH}/containers"
OUT_SIF="${BSAN_EXT_IMAGE:-${OUT_DIR}/bsan-ext.sif}"
BASE_SIF="${OUT_DIR}/bsan-base.sif"
DEF_WORK="${OUT_DIR}/bsan-ext.def"

[[ -f "${BSAN_IMAGE}" ]] || die "Missing base image ${BSAN_IMAGE} (group bsan.sif)"

mkdir -p "${OUT_DIR}"
if [[ ! -f "${BASE_SIF}" ]]; then
  log "Copying base image to user scratch (compute nodes cannot read group containers/)"
  cp -f "${BSAN_IMAGE}" "${BASE_SIF}"
fi

cat > "${DEF_WORK}" <<DEF
Bootstrap: localimage
From: ${BASE_SIF}

%post
    set -eux
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends libseccomp-dev
    rm -rf /var/lib/apt/lists/*
    pkg-config --modversion libseccomp
    pkg-config --libs libseccomp

%runscript
    exec "\$@"
DEF

log "Building ${OUT_SIF} from ${DEF_WORK} (base ${BASE_SIF})"

if [[ -z "${SLURM_JOB_ID:-}" ]]; then
  case "${TIME}" in
    *:*:*) WALLTIME="${TIME}" ;;
    *:*) h="${TIME%%:*}"; m="${TIME##*:}"; WALLTIME="0${h}:$(printf '%02d' "${m}"):00" ;;
    *) WALLTIME="$(printf '%02d' "${TIME}"):00:00" ;;
  esac
  if [[ "${MEM}" != *G && "${MEM}" != *M ]]; then MEM="${MEM}G"; fi
  srun -A "${SLURM_ACCOUNT}" --nodes=1 --ntasks=1 --cpus-per-task=1 \
    --mem="${MEM}" --time="${WALLTIME}" --job-name=bsan-build-ext-sif \
    bash "${SCRIPT_DIR}/rebuild_bsan_ext_image_job.sh" "${TIME}" "${MEM}"
  exit $?
fi

module load WebProxy 2>/dev/null || true
command -v singularity &>/dev/null || module load Singularity 2>/dev/null || module load singularity 2>/dev/null || true
command -v singularity &>/dev/null || die "singularity not found on compute node"

tmp_dir="/tmp/${USER}/sif-build-ext.$$"
export SINGULARITY_TMPDIR="${tmp_dir}/tmp"
mkdir -p "${SINGULARITY_TMPDIR}"
trap 'rm -rf "${tmp_dir}"' EXIT

singularity build --fakeroot "${tmp_dir}/bsan-ext.sif" "${DEF_WORK}"
cp -f "${tmp_dir}/bsan-ext.sif" "${OUT_SIF}"
singularity exec "${OUT_SIF}" pkg-config --modversion libseccomp
log "Built ${OUT_SIF}"
