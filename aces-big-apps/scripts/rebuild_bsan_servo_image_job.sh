#!/usr/bin/env bash
# Build bsan-servo.sif (group bsan + fontconfig/freetype dev headers) on a compute node.
# Usage: rebuild_bsan_servo_image_job.sh [walltime] [mem_GB]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

TIME="${1:-1:00}"
MEM="${2:-16}"
OUT_DIR="${USER_SCRATCH}/containers"
OUT_SIF="${BSAN_SERVO_IMAGE:-${OUT_DIR}/bsan-servo.sif}"
BASE_SIF="${OUT_DIR}/bsan-base.sif"
DEF_WORK="${OUT_DIR}/bsan-servo.def"

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
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \\
        libfontconfig-dev libfreetype-dev
    rm -rf /var/lib/apt/lists/*
    pkg-config --modversion fontconfig
    pkg-config --modversion freetype2

%environment
    export RUSTUP_HOME=/root/.rustup
    export CARGO_HOME=/root/.cargo
    export PATH=/root/.cargo/bin:\$PATH
    export USER="\${USER:-\$(id -un)}"
    export BSAN_SYSROOT=/opt/bsan-sysroot
    export BSAN_SYMBOLIZER=/root/.rustup/toolchains/bsan/bin/llvm-symbolizer

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
    --mem="${MEM}" --time="${WALLTIME}" --job-name=bsan-build-servo-sif \
    bash "${SCRIPT_DIR}/rebuild_bsan_servo_image_job.sh" "${TIME}" "${MEM}"
  exit $?
fi

module load WebProxy 2>/dev/null || true
command -v singularity &>/dev/null || module load Singularity 2>/dev/null || module load singularity 2>/dev/null || true
command -v singularity &>/dev/null || die "singularity not found on compute node"

tmp_dir="/tmp/${USER}/sif-build-servo.$$"
export SINGULARITY_TMPDIR="${tmp_dir}/tmp"
mkdir -p "${SINGULARITY_TMPDIR}"
trap 'rm -rf "${tmp_dir}"' EXIT

singularity build --fakeroot "${tmp_dir}/bsan-servo.sif" "${DEF_WORK}"
cp -f "${tmp_dir}/bsan-servo.sif" "${OUT_SIF}"
singularity exec "${OUT_SIF}" pkg-config --modversion fontconfig
singularity exec "${OUT_SIF}" pkg-config --modversion freetype2
log "Built ${OUT_SIF}"
