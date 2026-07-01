#!/usr/bin/env bash
# Forensics for servo-fonts BSAN runs (login node).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

echo "=== paths ==="
echo "ACES_ROOT=${ACES_ROOT}"
echo "OUTPUT_DIR=${OUTPUT_DIR}"
echo "RUSTUP_HOME=${RUSTUP_HOME}"
echo "CARGO_HOME=${CARGO_HOME}"
echo "BSAN_SERVO_IMAGE=${BSAN_SERVO_IMAGE}"

echo
echo "=== slurm (last 7 days, bsan-servo*) ==="
sacct -u "${ACES_USER}" -n -X --format=JobID,JobName%20,State,ExitCode,Elapsed,End \
  -S "$(date -d '7 days ago' +%Y-%m-%d)" 2>/dev/null | grep -E 'bsan-servo|bsan-setup' || echo "(no matching jobs)"

echo
echo "=== output dir listing (newest 25) ==="
if [[ -d "${OUTPUT_DIR}" ]]; then
  ls -lt "${OUTPUT_DIR}" 2>/dev/null | head -25
else
  echo "MISSING: ${OUTPUT_DIR}"
fi

echo
echo "=== package logs (servo-fonts) ==="
mapfile -t PKG_LOGS < <(find "${OUTPUT_DIR}" -maxdepth 1 -type f -name 'servo-xpath.servo-fonts.bsan.*.log' 2>/dev/null | sort -r)
if [[ ${#PKG_LOGS[@]} -eq 0 ]]; then
  echo "NONE"
else
  for f in "${PKG_LOGS[@]:0:5}"; do
    echo "--- ${f} ($(wc -c <"${f}") bytes) ---"
    grep -E '^(status=|package=|start=|error:|Error:|E0432)' "${f}" 2>/dev/null | tail -5 || true
  done
  L="${PKG_LOGS[0]}"
  echo
  echo "=== newest log tail: ${L} ==="
  tail -50 "${L}"
fi

echo
echo "=== submit log ==="
S="${OUTPUT_DIR}/servo-fonts.submit.log"
if [[ -f "${S}" ]]; then
  echo "file=${S} ($(wc -c <"${S}") bytes)"
  tail -60 "${S}"
else
  echo "MISSING: ${S}"
fi

echo
echo "=== results.csv ==="
if [[ -f "${OUTPUT_DIR}/results.csv" ]]; then
  grep -E 'servo-fonts|timestamp' "${OUTPUT_DIR}/results.csv" | tail -10
else
  echo "MISSING: ${OUTPUT_DIR}/results.csv"
fi

echo
echo "=== bsan toolchain ==="
if [[ -x "${RUSTUP_HOME}/toolchains/bsan/bin/rustc" ]]; then
  echo "bsan rustc: OK"
else
  echo "bsan rustc: MISSING"
fi
if [[ -x "${CARGO_HOME}/bin/cargo-bsan" ]]; then
  echo "cargo-bsan: OK"
else
  echo "cargo-bsan: MISSING"
fi
ls -1 "${RUSTUP_HOME}/toolchains" 2>/dev/null || echo "(no toolchains dir)"
