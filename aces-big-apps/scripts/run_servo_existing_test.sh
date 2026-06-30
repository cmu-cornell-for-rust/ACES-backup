#!/usr/bin/env bash
# Run the already-built servo-xpath BSAN test binary as a cheap runtime smoke.
# Usage: run_servo_existing_test.sh [test-harness args...]
# Stack is bounded by default (see config.env BSAN_STACK_KB); unlimited ACES default breaks BSAN layout.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

APP="servo-xpath"
TEST_DIR="${APPS_DIR}/${APP}/target/bsan/x86_64-unknown-linux-gnu/debug/deps"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
log_file="${OUTPUT_DIR}/${APP}.stack-smoke.${stamp}.log"
mkdir -p "${OUTPUT_DIR}"

BIN="${SERVO_XPATH_TEST_BIN:-}"
if [[ -z "${BIN}" ]]; then
  for candidate in "${TEST_DIR}"/servo_xpath-*; do
    if [[ -x "${candidate}" && "${candidate}" != *.d ]]; then
      BIN="${candidate}"
      break
    fi
  done
fi
[[ -n "${BIN}" && -x "${BIN}" ]] || die "Missing executable servo_xpath test binary under ${TEST_DIR}"

apply_bsan_stack_limit

{
  echo "app=${APP}"
  echo "start=${stamp}"
  echo "node=$(hostname)"
  echo "binary=${BIN}"
  echo "stack_soft_kb=$(ulimit -S -s)"
  echo "args=${*:-<none>}"
  echo "--- list tests ---"
  "${BIN}" --list
  echo "--- run tests ---"
  if "${BIN}" "$@"; then
    echo "status=ok"
  else
    rc="$?"
    echo "status=test_error"
    echo "exit_code=${rc}"
    exit "${rc}"
  fi
} 2>&1 | tee "${log_file}"

echo "log_file=${log_file}"
