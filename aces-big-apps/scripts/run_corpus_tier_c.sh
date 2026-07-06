#!/usr/bin/env bash
# Prefetch + sbatch the three Tier-C FFI additions (rusty-v8, firecracker, wgpu-hal).
# Usage: run_corpus_tier_c.sh [walltime] [mem_GB]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

TIME="${1:-6:00}"
MEM="${2:-32}"
TIER_C=(rusty-v8 firecracker wgpu-hal)

ensure_dirs
export PREFLIGHT_FORCE=1
"${SCRIPT_DIR}/preflight.sh"

log "Fetching Tier-C apps: ${TIER_C[*]}"
"${SCRIPT_DIR}/fetch_apps.sh" "${TIER_C[@]}"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
submit_log="${OUTPUT_DIR}/corpus.tier_c.submit.${stamp}.log"
mkdir -p "${OUTPUT_DIR}"
{
  echo "stamp=${stamp}"
  echo "apps=${TIER_C[*]}"
  echo "time=${TIME} mem=${MEM}G cpus=${BSAN_CPUS}"
  echo "mode=tier_c_prefetch_sbatch"
  bsan_revision_line || true
} | tee "${submit_log}"

log "Prefetch Tier-C (serial)"
"${SCRIPT_DIR}/run_corpus_prefetch.sh" "2:00" "16" "${TIER_C[@]}" 2>&1 | tee -a "${submit_log}"

log "sbatch Tier-C (${#TIER_C[@]} jobs, cpus=${BSAN_CPUS})"
"${SCRIPT_DIR}/run_corpus_submit.sh" "${TIME}" "${MEM}" "${TIER_C[@]}" 2>&1 | tee -a "${submit_log}"

log "Tier-C batch submitted. submit_log=${submit_log}"
