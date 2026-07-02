#!/bin/bash
#SBATCH -A 158460239852
#SBATCH --job-name=bsan-gdb
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=24G
#SBATCH --time=01:30:00
#SBATCH --output=/scratch/group/p.cis260229.000/aces-big-apps/outputs/bsan-big-apps/sbatch/bsan-gdb.%j.log
export CPUS=1
exec /scratch/group/p.cis260229.000/aces-big-apps/scripts/bsan_singularity_run.sh /scratch/group/p.cis260229.000/containers/bsan.sif /scratch/group/p.cis260229.000/aces-big-apps bash -lc export\ ACES_ROOT=/scratch/group/p.cis260229.000/aces-big-apps\;\ /scratch/user/u.ra353315/investigate_corpus_gdb_inner.sh
