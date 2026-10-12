#!/bin/bash
# Docker/Podman HEALTHCHECK for the onedrive container.
#
# Reads the machine-readable runtime status published by --monitor at
# /onedrive/conf/monitor-status.json (see
# docs/usage.md#machine-readable-monitor-runtime-status) and reports
# healthy only when:
#   - the monitor process recorded in the file is still running,
#   - the file was published recently enough to not be a stale leftover
#     from a crashed/killed process, and
#   - the first synchronisation cycle has completed successfully.
set -u

# Extract a top-level "key": value pair from the flat, pretty-printed JSON
# the client emits (one field per line). Avoids a jq/python dependency,
# neither of which the shipped images install.
json_field() {
	grep -o "\"${1}\":[^,}]*" "$2" \
		| head -n 1 \
		| sed -e 's/^"[^"]*":[[:space:]]*//' -e 's/^"//' -e 's/"[[:space:]]*$//'
}

# The expected path for the monitor file inside the container
STATUS_FILE="/onedrive/conf/monitor-status.json"

# How stale (in seconds) the status file is allowed to be before the
# container is considered unhealthy. Default is twice the client's default
# monitor_interval_seconds (300s), giving one missed cycle of slack.
MAX_AGE_SECONDS="${ONEDRIVE_HEALTHCHECK_MAX_AGE:=600}"

# monitor-status.json only exists while --monitor is running with
# monitor_status enabled (the default). If you wire this healthcheck up,
# your container is expected to be running in that mode; if it's running
# standalone (--sync / ONEDRIVE_SYNC_ONCE=1) or has monitor_status=false
# set, the file never appears and this reports unhealthy accordingly.
if [ ! -f "${STATUS_FILE}" ]; then
	echo "unhealthy: ${STATUS_FILE} not found (monitor not started yet, not running in --monitor mode, or monitor_status disabled)"
	exit 1
fi



PID="$(json_field pid "${STATUS_FILE}")"
STATE="$(json_field state "${STATUS_FILE}")"
INITIAL_SYNC_DONE="$(json_field initial_successful_sync_completed "${STATUS_FILE}")"

if [ -z "${PID}" ]; then
	echo "unhealthy: could not read 'pid' from ${STATUS_FILE}"
	exit 1
fi

# Liveness: the pid recorded in the status file must still be running. A
# crashed or SIGKILLed monitor leaves its last snapshot behind; this catches
# that case immediately rather than waiting for the staleness check below.
if ! kill -0 "${PID}" 2>/dev/null; then
	echo "unhealthy: monitor pid ${PID} from status file is not running"
	exit 1
fi

# Staleness: the file is replaced via temp-file + atomic rename on every
# monitor lifecycle event, so its mtime is a reliable, portable proxy for
# the JSON's own "updated_at" without needing to parse ISO-8601 timestamps
# across Fedora/Debian/Alpine's differing `date` implementations.
NOW="$(date +%s)"
MTIME="$(stat -c %Y "${STATUS_FILE}")"
AGE=$((NOW - MTIME))

if [ "${AGE}" -gt "${MAX_AGE_SECONDS}" ]; then
	echo "unhealthy: ${STATUS_FILE} is ${AGE}s old (max ${MAX_AGE_SECONDS}s) - monitor loop may be stuck"
	exit 1
fi

# Readiness: require the first successful sync cycle to have completed.
# This is the signal docs/docker.md recommends for gating dependent
# services; HEALTHCHECK's start-period gives a new container time to
# reach it before being marked unhealthy.
if [ "${INITIAL_SYNC_DONE}" != "true" ]; then
	echo "starting: initial sync not yet completed (state=${STATE})"
	exit 1
fi

echo "healthy: pid=${PID} state=${STATE} age=${AGE}s"
exit 0
