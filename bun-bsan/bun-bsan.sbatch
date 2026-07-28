#!/bin/bash
#SBATCH --job-name=bun-bsan
#SBATCH --partition=cpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=64
#SBATCH --mem=240G
#SBATCH --time=08:00:00
#SBATCH --output=/scratch/group/p.cis260229.000/bun-bsan/logs/slurm-%j.out

set -x
G=/scratch/group/p.cis260229.000/bun-bsan
mkdir -p "$G/logs"

module load charliecloud/0.33
# Outbound network for compute nodes (crates.io, npm, WebKit prebuilt).
module load WebProxy 2>/dev/null || true
curl -s -o /dev/null -w "outbound check: %{http_code}\n" --max-time 15 https://github.com

# Env (incl. proxy vars) passes through into the container by default.
export CH_IMAGE_STORAGE=$G/ch-storage
ch-run --no-passwd \
  -b /scratch:/scratch \
  bun-bsan -- bash "$G/job-inner.sh"
rc=$?
echo "JOB EXIT: $rc"
exit $rc
