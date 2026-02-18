#!/usr/bin/env bash
set -euo pipefail

# Required environment variables:
#   ONEDRIVE_BIN
#   E2E_TARGET
#   RUN_ID
#
# Optional (provided by GitHub Actions):
#   RUNNER_TEMP

OUT_DIR="ci/e2e/out"
SYNC_ROOT="${RUNNER_TEMP:-/tmp}/sync-${E2E_TARGET}"

mkdir -p "$OUT_DIR"
mkdir -p "$SYNC_ROOT"

RESULTS_FILE="${OUT_DIR}/results.json"
LOG_FILE="${OUT_DIR}/sync.log"

# We'll collect cases as JSON objects in a bash array, then assemble results.json.
declare -a CASES=()
pass_count=0
fail_count=0

# Helper: add a PASS case
add_pass() {
  local id="$1"
  local name="$2"
  CASES+=("$(jq -cn --arg id "$id" --arg name "$name" \
    '{id:$id,name:$name,status:"pass"}')")
  pass_count=$((pass_count + 1))
}

# Helper: add a FAIL case (with reason)
add_fail() {
  local id="$1"
  local name="$2"
  local reason="$3"
  CASES+=("$(jq -cn --arg id "$id" --arg name "$name" --arg reason "$reason" \
    '{id:$id,name:$name,status:"fail",reason:$reason}')")
  fail_count=$((fail_count + 1))
}

echo "E2E target: ${E2E_TARGET}"
echo "Sync root: ${SYNC_ROOT}"

###############################################
# Test Case 0001: basic resync
###############################################
TC_ID="0001"
TC_NAME="basic-resync (sync + verbose + resync + resync-auth)"

echo "Running test case ${TC_ID}: ${TC_NAME}"
echo "Running: onedrive --sync --verbose --resync --resync-auth"

# Stream output to console AND log file (Option A) while preserving exit code.
set +e
"$ONEDRIVE_BIN" \
  --sync \
  --verbose \
  --resync \
  --resync-auth \
  --syncdir "$SYNC_ROOT" \
  2>&1 | tee "$LOG_FILE"
rc=${PIPESTATUS[0]}
set -e

if [ "$rc" -eq 0 ]; then
  add_pass "$TC_ID" "$TC_NAME"
else
  add_fail "$TC_ID" "$TC_NAME" "onedrive exited with code ${rc}"
fi

###############################################
# Write results.json
###############################################
# Build JSON array from CASES[]
cases_json="$(printf '%s\n' "${CASES[@]}" | jq -cs '.')"

jq -n \
  --arg target "$E2E_TARGET" \
  --argjson run_id "$RUN_ID" \
  --argjson cases "$cases_json" \
  '{target:$target, run_id:$run_id, cases:$cases}' \
  > "$RESULTS_FILE"

echo "Results written to ${RESULTS_FILE}"
echo "Passed: ${pass_count}"
echo "Failed: ${fail_count}"

# Fail the job if any cases failed.
if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
