#!/usr/bin/env bash
# Start an interactive Servo BSAN debug shell on a compute node.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

DEBUG_CPUS="${DEBUG_CPUS:-16}"
DEBUG_MEM="${DEBUG_MEM:-32G}"
DEBUG_TIME="${DEBUG_TIME:-01:00:00}"
APP="${1:-servo-xpath}"

ensure_dirs
IMAGE="$(resolve_image "${BSAN_IMAGE}")"
APP_DIR="${APPS_DIR}/${APP}"
[[ -d "${APP_DIR}" ]] || die "Missing app checkout: ${APP_DIR}"

RCFILE="${OUTPUT_DIR}/servo-debug-shell.rc"
cat > "${RCFILE}" <<RC
cd '${APP_DIR}'
echo
echo "Inside BSAN container on compute node: \$(hostname)"
echo "App dir: \$(pwd)"
echo
echo "Find latest test binary:"
echo "  find target/bsan/x86_64-unknown-linux-gnu/debug/deps -maxdepth 1 -type f -executable -name 'servo_xpath-*' -print | sort | tail -1"
echo
echo "Run gdb:"
echo "  BIN=\$(find target/bsan/x86_64-unknown-linux-gnu/debug/deps -maxdepth 1 -type f -executable -name 'servo_xpath-*' -print | sort | tail -1)"
echo "  gdb --args \"\$BIN\" --nocapture --test-threads=1"
echo
echo "Useful gdb commands: run ; bt full ; info registers ; thread apply all bt full"
echo
RC

cat <<MSG
Starting Servo BSAN debug allocation:
  app=${APP}
  cpus=${DEBUG_CPUS}
  mem=${DEBUG_MEM}
  time=${DEBUG_TIME}
  image=${IMAGE}

Detach tmux anytime with: Ctrl-b d
Cancel this allocation from another shell with: scancel -n bsan-gdb-servo
MSG

srun \
  -A "${SLURM_ACCOUNT}" \
  --job-name=bsan-gdb-servo \
  --nodes=1 \
  --ntasks=1 \
  --cpus-per-task="${DEBUG_CPUS}" \
  --mem="${DEBUG_MEM}" \
  --time="${DEBUG_TIME}" \
  --pty \
  bash -s -- "${IMAGE}" "${ACES_ROOT}" "${USER_SCRATCH}" "${GROUP_ROOT}" "${CARGO_HOME}" "${RUSTUP_HOME}" "${RCFILE}" <<'NODE'
set -euo pipefail
IMAGE="$1"
ACES_ROOT="$2"
USER_SCRATCH="$3"
GROUP_ROOT="$4"
CARGO_HOME="$5"
RUSTUP_HOME="$6"
RCFILE="$7"

module load WebProxy 2>/dev/null || true
command -v singularity &>/dev/null || module load Singularity 2>/dev/null || module load singularity 2>/dev/null || true
command -v singularity &>/dev/null || { echo 'singularity not found'; exit 1; }

singularity exec --cleanenv --pwd "${ACES_ROOT}" \
  --bind "${USER_SCRATCH}:${USER_SCRATCH}" \
  --bind "${GROUP_ROOT}:${GROUP_ROOT}" \
  --bind "${ACES_ROOT}:${ACES_ROOT}" \
  --env ACES_ROOT="${ACES_ROOT}" \
  --env CARGO_HOME="${CARGO_HOME}" \
  --env RUSTUP_HOME="${RUSTUP_HOME}" \
  --env RUSTUP_TOOLCHAIN=bsan \
  --env BSAN_RUST_ONLY=1 \
  --env PATH="${CARGO_HOME}/bin:/opt/cargo/bin:/opt/rust/cargo/bin:/usr/local/bin:/usr/bin:/bin" \
  "${IMAGE}" bash --rcfile "${RCFILE}" -i
NODE
