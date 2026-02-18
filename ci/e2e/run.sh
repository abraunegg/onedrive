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
# Test Case 0002: upload-only does not download
###############################################
TC_ID="0002"
TC_NAME="upload-only: uploads local changes, does not download remote-only changes"

REMOTE_PREFIX="ci_e2e/${RUN_ID}/${E2E_TARGET}/upload_only"
SEED_DIR="${RUNNER_TEMP:-/tmp}/seed-${E2E_TARGET}-${RUN_ID}"
UP_DIR="${RUNNER_TEMP:-/tmp}/uploadonly-${E2E_TARGET}-${RUN_ID}"
VERIFY_DIR="${RUNNER_TEMP:-/tmp}/verify-${E2E_TARGET}-${RUN_ID}"

SEED_LOG="${OUT_DIR}/tc0002-seed.log"
UP_LOG="${OUT_DIR}/tc0002-uploadonly.log"
VERIFY_LOG="${OUT_DIR}/tc0002-verify.log"

REMOTE_ONLY_FILE="remote_only_${RUN_ID}.txt"
LOCAL_ONLY_FILE="local_only_${RUN_ID}.txt"

echo "Running test case ${TC_ID}: ${TC_NAME}"
echo "Remote prefix: ${REMOTE_PREFIX}"

rm -rf "$SEED_DIR" "$UP_DIR" "$VERIFY_DIR"
mkdir -p "$SEED_DIR" "$UP_DIR" "$VERIFY_DIR"

# Step A: Create a file and upload it via the seeder dir
# This makes it "remote-only" relative to UP_DIR (because UP_DIR has never synced yet)
echo "Created remotely by seeder at run ${RUN_ID}" > "${SEED_DIR}/${REMOTE_ONLY_FILE}"

set +e
"$ONEDRIVE_BIN" \
  --sync \
  --verbose \
  --syncdir "$SEED_DIR" \
  --single-directory "$REMOTE_PREFIX" \
  2>&1 | tee "$SEED_LOG"
rc_seed=${PIPESTATUS[0]}
set -e

if [ "$rc_seed" -ne 0 ]; then
  add_fail "$TC_ID" "$TC_NAME" "Seeder sync failed (exit code ${rc_seed})"
else
  # Step B: Create a local-only file in the upload-only dir
  echo "Created locally for upload-only at run ${RUN_ID}" > "${UP_DIR}/${LOCAL_ONLY_FILE}"

  # Step C: Run upload-only sync. It must NOT download REMOTE_ONLY_FILE.
  set +e
  "$ONEDRIVE_BIN" \
    --sync \
    --verbose \
    --upload-only \
    --syncdir "$UP_DIR" \
    --single-directory "$REMOTE_PREFIX" \
    2>&1 | tee "$UP_LOG"
  rc_up=${PIPESTATUS[0]}
  set -e

  if [ "$rc_up" -ne 0 ]; then
    add_fail "$TC_ID" "$TC_NAME" "Upload-only sync failed (exit code ${rc_up})"
  else
    # Assertion 1: upload-only must NOT download the remote-only file
    if [ -f "${UP_DIR}/${REMOTE_ONLY_FILE}" ]; then
      add_fail "$TC_ID" "$TC_NAME" "Upload-only unexpectedly downloaded remote-only file: ${REMOTE_ONLY_FILE}"
    else
      # Step D: Verify the local-only file exists online by doing a download-only into VERIFY_DIR
      set +e
      "$ONEDRIVE_BIN" \
        --sync \
        --verbose \
        --download-only \
        --syncdir "$VERIFY_DIR" \
        --single-directory "$REMOTE_PREFIX" \
        2>&1 | tee "$VERIFY_LOG"
      rc_ver=${PIPESTATUS[0]}
      set -e

      if [ "$rc_ver" -ne 0 ]; then
        add_fail "$TC_ID" "$TC_NAME" "Verifier download-only failed (exit code ${rc_ver})"
      elif [ ! -f "${VERIFY_DIR}/${LOCAL_ONLY_FILE}" ]; then
        add_fail "$TC_ID" "$TC_NAME" "Uploaded file not found online (not downloaded by verifier): ${LOCAL_ONLY_FILE}"
      else
        # Optional log validations (soft but useful):
        # - upload-only log should mention local file name
        # - upload-only log should NOT mention the remote-only file name
        if ! grep -Fq "$LOCAL_ONLY_FILE" "$UP_LOG"; then
          add_fail "$TC_ID" "$TC_NAME" "Upload-only log did not mention uploaded file: ${LOCAL_ONLY_FILE}"
        elif grep -Fq "$REMOTE_ONLY_FILE" "$UP_LOG"; then
          add_fail "$TC_ID" "$TC_NAME" "Upload-only log mentioned remote-only file (possible download): ${REMOTE_ONLY_FILE}"
        else
          add_pass "$TC_ID" "$TC_NAME"
        fi
      fi
    fi
  fi
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
