#!/usr/bin/env bash
# Mirrors the group's containers/build_scripts/build.sh pattern.
set -euo pipefail
DEF="${1:-bsan.def}"
NAME="${DEF%.def}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONTAINERS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=/dev/null
source "${CONTAINERS_DIR}/../config.env"

cd "${SCRIPT_DIR}"
echo "Building ${NAME}.sif (uses srun + singularity on ACES)..."
srun --nodes=1 --ntasks-per-node=1 --mem=16G --time=02:00:00 \
  singularity build --fakeroot "${CONTAINERS_DIR}/${NAME}.sif" "${DEF}"
echo "Wrote ${CONTAINERS_DIR}/${NAME}.sif"
