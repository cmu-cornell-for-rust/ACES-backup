#!/bin/bash
#SBATCH -A 158460239852
#SBATCH --job-name=bsan-investigate
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=24G
#SBATCH --time=01:30:00
#SBATCH --output=/scratch/group/p.cis260229.000/aces-big-apps/outputs/bsan-big-apps/sbatch/bsan-investigate.%j.log
export CPUS=1
exec /scratch/group/p.cis260229.000/aces-big-apps/scripts/bsan_singularity_run.sh /scratch/group/p.cis260229.000/containers/bsan.sif /scratch/group/p.cis260229.000/aces-big-apps bash -lc set\ -euo\ pipefail\;\ export\ ACES_ROOT=\'/scratch/group/p.cis260229.000/aces-big-apps\'\;\ source\ \'/scratch/group/p.cis260229.000/aces-big-apps/config.env\'\;\ source\ \'/scratch/group/p.cis260229.000/aces-big-apps/scripts/common.sh\'\;\ ensure_dirs\;\ \'/scratch/group/p.cis260229.000/aces-big-apps/scripts/investigate_corpus_debug_inner.sh\'
