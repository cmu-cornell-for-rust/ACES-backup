#!/usr/bin/env bash
# Clone or update repos in datasets/big-apps/apps.tsv.
# Cargo fetch runs in run_bsan_app.sh after bsan is installed.
#
# Usage: fetch_apps.sh [app-name ...]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

APPS_TSV="${ACES_ROOT}/datasets/big-apps/apps.tsv"
ensure_network
ensure_dirs

want_app() {
  local name="$1"
  [[ ${#REQUESTED[@]} -eq 0 ]] && return 0
  local a
  for a in "${REQUESTED[@]}"; do
    [[ "${a}" == "${name}" ]] && return 0
  done
  return 1
}

REQUESTED=("$@")
mapfile -t LINES < <(awk -F '\t' '$1 !~ /^#/ && NF {print $1}' "${APPS_TSV}")

for name in "${LINES[@]}"; do
  want_app "${name}" || continue

  repo="$(app_field "${name}" 2)"
  branch="$(app_field "${name}" 3)"
  subdir="$(app_field "${name}" 4)"
  fetch_cmd="$(app_field "${name}" 5)"

  dest="${APPS_DIR}/${name}"
  if [[ ! -d "${dest}/.git" ]]; then
    log "Cloning ${name} from ${repo} (${branch})"
    git clone --branch "${branch}" --depth 1 "${repo}" "${dest}"
  else
    log "Updating ${name}"
    rm -f "${dest}/.git/index.lock"
    if ! git -C "${dest}" fetch origin "${branch}" \
      || ! git -C "${dest}" checkout -f "${branch}" \
      || ! git -C "${dest}" pull --ff-only origin "${branch}"; then
      log "WARN: ${name} checkout broken; recloning"
      rm -rf "${dest}"
      git clone --branch "${branch}" --depth 1 "${repo}" "${dest}"
    fi
  fi
  if [[ -n "${fetch_cmd}" ]]; then
    log "Running fetch hook for ${name}"
    (cd "${dest}/${subdir}" && eval "${fetch_cmd}")
  fi
done
