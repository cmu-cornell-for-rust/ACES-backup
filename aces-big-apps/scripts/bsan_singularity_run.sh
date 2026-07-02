#!/usr/bin/env bash
# Run a command inside the BSAN Singularity image on a compute node.
# Usage: bsan_singularity_run.sh <image.sif> <workdir> <command>
set -euo pipefail

SIF_ABS="$1"
WORKDIR_ABS="$2"
shift 2
CMD=("$@")

module load WebProxy 2>/dev/null || true
command -v singularity &>/dev/null || module load Singularity 2>/dev/null || module load singularity 2>/dev/null || true
command -v singularity &>/dev/null || { echo "singularity not found"; exit 1; }

# shellcheck source=/dev/null
source "${WORKDIR_ABS}/config.env"

mkdir -p "${CARGO_HOME}" "${RUSTUP_HOME}" "${APPS_DIR}" "${OUTPUT_DIR}"
# shellcheck source=/dev/null
source "${WORKDIR_ABS}/scripts/common.sh"
apply_bsan_stack_limit
echo "Stack soft limit: $(ulimit -S -s) KB"

CMD_STR="${CMD[*]}"
SING_BIND_ARGS=()
if [[ "${BSAN_BIND_HOST_FFI:-0}" == 1 || "${CMD_STR}" == *run_servo* ]]; then
  local_spec=""
  while IFS= read -r local_spec; do
    [[ -n "${local_spec}" ]] || continue
    SING_BIND_ARGS+=(--bind "${local_spec}")
  done < <(bsan_singularity_host_ffi_binds)
  if [[ ${#SING_BIND_ARGS[@]} -gt 0 ]]; then
    echo "Host FFI binds: ${SING_BIND_ARGS[*]}"
  fi
fi

staged_strace="${USER_SCRATCH}/tools/strace-bundle/bin/strace"
if [[ -x "${staged_strace}" ]]; then
  SING_BIND_ARGS+=(--bind "${staged_strace}:/usr/bin/strace")
  echo "Staged strace bind: ${staged_strace} -> /usr/bin/strace"
elif host_strace="$(command -v strace 2>/dev/null)" && [[ -n "${host_strace}" && -x "${host_strace}" ]]; then
  SING_BIND_ARGS+=(--bind "${host_strace}:/usr/bin/strace")
  echo "Host strace bind: ${host_strace} -> /usr/bin/strace"
fi

if [[ "${CMD_STR}" == *strace* ]]; then
  for strace_bin in /usr/bin/strace /bin/strace; do
    if [[ -x "${strace_bin}" ]]; then
      SING_BIND_ARGS+=(--bind "${strace_bin}:${strace_bin}")
      echo "Host strace bind: ${strace_bin}"
      break
    fi
  done
fi

echo "Container: ${SIF_ABS}"
echo "Command:   ${CMD_STR}"

singularity exec --cleanenv --pwd "${WORKDIR_ABS}" \
  --bind "${USER_SCRATCH}:${USER_SCRATCH}" \
  --bind "${GROUP_ROOT}:${GROUP_ROOT}" \
  --bind "${WORKDIR_ABS}:${WORKDIR_ABS}" \
  "${SING_BIND_ARGS[@]}" \
  --env ACES_ROOT="${ACES_ROOT}" \
  --env CARGO_HOME="${CARGO_HOME}" \
  --env RUSTUP_HOME="${RUSTUP_HOME}" \
  --env CARGO_BUILD_JOBS="${CPUS:-1}" \
  --env PATH="${CARGO_HOME}/bin:/opt/cargo/bin:/opt/rust/cargo/bin:${PATH}" \
  --env http_proxy="${http_proxy:-}" --env https_proxy="${https_proxy:-}" \
  --env HTTP_PROXY="${HTTP_PROXY:-}" --env HTTPS_PROXY="${HTTPS_PROXY:-}" \
  "${SIF_ABS}" "${CMD[@]}"
