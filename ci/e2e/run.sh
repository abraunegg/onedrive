#!/usr/bin/env bash
set -euo pipefail

# Required environment variables:
#   ONEDRIVE_BIN
#   E2E_TARGET
#   RUN_ID

OUT_DIR="ci/e2e/out"
SYNC_ROOT="$RUNNER_TEMP/sync-${E2E_TARGET}"

mkdir -p "$OUT_DIR"
mkdir -p "$SYNC_ROOT"

RESULTS_FILE="${OUT_DIR}/results.json"
LOG_FILE="${OUT_DIR}/sync.log"

echo "E2E target: ${E2E_TARGET}"
echo "Sync root: ${SYNC_ROOT}"

CASE_NAME="basic-resync"

pass_count=0
fail_count=0

echo "Running: onedrive --sync --verbose --resync --resync-auth"

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
  pass_count=1
  status="pass"
else
  fail_count=1
  status="fail"
fi

# Write minimal results.json
cat > "$RESULTS_FILE" <<EOF
{
  "target": "${E2E_TARGET}",
  "run_id": ${RUN_ID},
  "cases": [
    {
      "name": "${CASE_NAME}",
      "status": "${status}"
    }
  ]
}
EOF

echo "Exit code: ${rc}"
echo "Results written to ${RESULTS_FILE}"
echo "Passed: ${pass_count}"
echo "Failed: ${fail_count}"

# Fail job if command failed
if [ "$rc" -ne 0 ]; then
  echo "E2E failed - see sync.log"
  exit 1
fi
