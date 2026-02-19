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
# Uses separate --confdir profiles to avoid sync_dir change resync issues.
###############################################
TC_ID="0002"
TC_NAME="upload-only: uploads local changes, does not download remote-only changes"

REMOTE_PREFIX="ci_e2e/${RUN_ID}/${E2E_TARGET}/upload_only"

SEED_DIR="${RUNNER_TEMP:-/tmp}/seed-${E2E_TARGET}-${RUN_ID}"
UP_DIR="${RUNNER_TEMP:-/tmp}/uploadonly-${E2E_TARGET}-${RUN_ID}"
VER_DIR="${RUNNER_TEMP:-/tmp}/verify-${E2E_TARGET}-${RUN_ID}"

CONF_BASE="${RUNNER_TEMP:-/tmp}/conf-${E2E_TARGET}-${RUN_ID}"
CONF_SEED="${CONF_BASE}/seed"
CONF_UP="${CONF_BASE}/upload"
CONF_VER="${CONF_BASE}/verify"

SEED_LOG="${OUT_DIR}/tc0002-seed.log"
UP_LOG="${OUT_DIR}/tc0002-uploadonly.log"
VER_LOG="${OUT_DIR}/tc0002-verify.log"

REMOTE_ONLY_FILE="remote_only_${RUN_ID}.txt"
LOCAL_ONLY_FILE="local_only_${RUN_ID}.txt"

echo "Running test case ${TC_ID}: ${TC_NAME}"
echo "Remote prefix: ${REMOTE_PREFIX}"

# Helper: locate the already-injected refresh token (from workflow step)
TOKEN_SRC=""
if [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/onedrive/refresh_token" ]; then
  TOKEN_SRC="${XDG_CONFIG_HOME:-$HOME/.config}/onedrive/refresh_token"
elif [ -f "$HOME/.config/onedrive/refresh_token" ]; then
  TOKEN_SRC="$HOME/.config/onedrive/refresh_token"
fi

if [ -z "$TOKEN_SRC" ]; then
  add_fail "$TC_ID" "$TC_NAME" "Could not locate existing refresh_token to seed confdirs"
else
  # Clean state for this test
  rm -rf "$SEED_DIR" "$UP_DIR" "$VER_DIR" "$CONF_BASE"
  mkdir -p "$SEED_DIR" "$UP_DIR" "$VER_DIR"
  mkdir -p "$CONF_SEED" "$CONF_UP" "$CONF_VER"

  # Copy refresh_token into each confdir (confdir becomes the config root)
  umask 077
  cp -f "$TOKEN_SRC" "${CONF_SEED}/refresh_token"
  cp -f "$TOKEN_SRC" "${CONF_UP}/refresh_token"
  cp -f "$TOKEN_SRC" "${CONF_VER}/refresh_token"

  ########################################################
  # Step A: Seeder uploads a "remote-only" file
  ########################################################
  echo "Seeder creating remote-only file: ${REMOTE_ONLY_FILE}"
  printf "Created by seeder at run %s\n" "$RUN_ID" > "${SEED_DIR}/${REMOTE_ONLY_FILE}"

  set +e
  "$ONEDRIVE_BIN" \
    --confdir "$CONF_SEED" \
    --sync \
    --verbose \
    --resync \
    --resync-auth \
    --syncdir "$SEED_DIR" \
    --single-directory "$REMOTE_PREFIX" \
    2>&1 | tee "$SEED_LOG"
  rc_seed=${PIPESTATUS[0]}
  set -e

  if [ "$rc_seed" -ne 0 ]; then
    add_fail "$TC_ID" "$TC_NAME" "Seeder sync failed (exit code ${rc_seed})"
  else
    ########################################################
    # Step B: Uploader creates a local-only file
    ########################################################
    echo "Uploader creating local-only file: ${LOCAL_ONLY_FILE}"
    printf "Created by uploader at run %s\n" "$RUN_ID" > "${UP_DIR}/${LOCAL_ONLY_FILE}"

    ########################################################
    # Step C: Run upload-only from uploader profile
    # Must not download REMOTE_ONLY_FILE into UP_DIR.
    ########################################################
    set +e
    "$ONEDRIVE_BIN" \
      --confdir "$CONF_UP" \
      --sync \
      --verbose \
      --resync \
      --resync-auth \
      --upload-only \
      --syncdir "$UP_DIR" \
      --single-directory "$REMOTE_PREFIX" \
      2>&1 | tee "$UP_LOG"
    rc_up=${PIPESTATUS[0]}
    set -e

    if [ "$rc_up" -ne 0 ]; then
      add_fail "$TC_ID" "$TC_NAME" "Upload-only sync failed (exit code ${rc_up})"
    elif [ -f "${UP_DIR}/${REMOTE_ONLY_FILE}" ]; then
      add_fail "$TC_ID" "$TC_NAME" "Upload-only unexpectedly downloaded remote-only file: ${REMOTE_ONLY_FILE}"
    else
      ########################################################
      # Step D: Verify upload landed online using verifier
      ########################################################
      set +e
      "$ONEDRIVE_BIN" \
        --confdir "$CONF_VER" \
        --sync \
        --verbose \
        --resync \
        --resync-auth \
        --download-only \
        --syncdir "$VER_DIR" \
        --single-directory "$REMOTE_PREFIX" \
        2>&1 | tee "$VER_LOG"
      rc_ver=${PIPESTATUS[0]}
      set -e

      if [ "$rc_ver" -ne 0 ]; then
        add_fail "$TC_ID" "$TC_NAME" "Verifier download-only failed (exit code ${rc_ver})"
      elif [ ! -f "${VER_DIR}/${LOCAL_ONLY_FILE}" ]; then
        add_fail "$TC_ID" "$TC_NAME" "Uploaded file not found online (not downloaded by verifier): ${LOCAL_ONLY_FILE}"
      else
        # Optional log sanity checks (secondary):
        # - UP log should mention the uploaded filename
        # - UP log should not mention the remote-only filename
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
