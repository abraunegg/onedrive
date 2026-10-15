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

unhealthy() {
	echo "unhealthy: $*"
	exit 1
}

# Extract the value of a "key": value pair from STATUS_LINES into FIELD_VALUE.
#
# The client writes the status file pretty-printed (one "key": value pair per
# line), so this matches whole lines rather than parsing JSON, which avoids a
# jq/python dependency that the shipped images do not install. Bash builtins
# are used instead of grep/sed so behaviour does not vary between the GNU
# (Debian/Fedora) and BusyBox (Alpine) tools.
#
# To fail safely if the file is truncated, malformed or formatted differently
# than expected, the key must appear on exactly one line and its value must
# match value_re, whose first capture group becomes FIELD_VALUE. Otherwise the
# check reports unhealthy with a diagnostic naming the offending field.
read_field() {
	local key="$1" value_re="$2" line_re line raw="" count=0
	line_re="^[[:space:]]*\"${key}\"[[:space:]]*:[[:space:]]*(.*[^,[:space:]])[[:space:]]*,?[[:space:]]*$"
	for line in "${STATUS_LINES[@]}"; do
		if [[ ${line} =~ ${line_re} ]]; then
			raw="${BASH_REMATCH[1]}"
			count=$((count + 1))
		fi
	done
	if [ "${count}" -eq 0 ]; then
		unhealthy "field '${key}' not found in ${STATUS_FILE}"
	fi
	if [ "${count}" -gt 1 ]; then
		unhealthy "field '${key}' found ${count} times in ${STATUS_FILE}, expected exactly once"
	fi
	if [[ ! ${raw} =~ ${value_re} ]]; then
		unhealthy "field '${key}' has unexpected value '${raw}' in ${STATUS_FILE}"
	fi
	FIELD_VALUE="${BASH_REMATCH[1]}"
}

# The expected path for the monitor file inside the container
STATUS_FILE="/onedrive/conf/monitor-status.json"

# The status file layout this script understands. A different
# schema_version may move or rename the fields checked below.
SUPPORTED_SCHEMA_VERSION=1

# How stale (in seconds) the status file is allowed to be before the
# container is considered unhealthy. Default is twice the client's default
# monitor_interval_seconds (300s), giving one missed cycle of slack.
# The default only applies when the variable is unset; an explicitly empty
# value is treated as a configuration error below.
MAX_AGE_SECONDS="${ONEDRIVE_HEALTHCHECK_MAX_AGE-600}"

# Validate before use in arithmetic, so a misconfiguration is reported
# clearly regardless of the status file contents. At most 10 digits keeps
# the value well within the range of shell arithmetic.
if [[ ! ${MAX_AGE_SECONDS} =~ ^[1-9][0-9]{0,9}$ ]]; then
	unhealthy "ONEDRIVE_HEALTHCHECK_MAX_AGE='${MAX_AGE_SECONDS}' is not a positive integer number of seconds"
fi

# monitor-status.json only exists while --monitor is running with
# monitor_status enabled (the default). If you wire this healthcheck up,
# your container is expected to be running in that mode; if it's running
# standalone (--sync / ONEDRIVE_SYNC_ONCE=1) or has monitor_status=false
# set, the file never appears and this reports unhealthy accordingly.
if [ ! -f "${STATUS_FILE}" ]; then
	echo "unhealthy: ${STATUS_FILE} not found (monitor not started yet, not running in --monitor mode, or monitor_status disabled)"
	exit 1
fi

# Read the file once so every field comes from the same snapshot, even if
# the monitor atomically replaces it while this check is running. The file
# can also disappear between the test above and this read during an orderly
# shutdown.
if ! { mapfile -t STATUS_LINES < "${STATUS_FILE}"; } 2>/dev/null; then
	unhealthy "${STATUS_FILE} could not be read"
fi
if [ "${#STATUS_LINES[@]}" -eq 0 ]; then
	unhealthy "${STATUS_FILE} is empty"
fi

read_field schema_version '^([0-9]+)$'
if [ "${FIELD_VALUE}" != "${SUPPORTED_SCHEMA_VERSION}" ]; then
	unhealthy "${STATUS_FILE} has schema_version ${FIELD_VALUE}, this healthcheck supports ${SUPPORTED_SCHEMA_VERSION}"
fi

read_field pid '^([1-9][0-9]*)$'
PID="${FIELD_VALUE}"
read_field state '^"([a-z_]+)"$'
STATE="${FIELD_VALUE}"
read_field initial_successful_sync_completed '^(true|false)$'
INITIAL_SYNC_DONE="${FIELD_VALUE}"

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
# Freshness cannot be determined if either timestamp is unavailable, so any
# failure here is reported as unhealthy.
if ! NOW="$(date +%s 2>/dev/null)" || [[ ! ${NOW} =~ ^[0-9]+$ ]]; then
	unhealthy "could not determine the current time (date +%s returned '${NOW}')"
fi
if ! MTIME="$(stat -c %Y "${STATUS_FILE}" 2>/dev/null)" || [[ ! ${MTIME} =~ ^[0-9]+$ ]]; then
	unhealthy "could not determine the modification time of ${STATUS_FILE}"
fi
AGE=$((NOW - MTIME))

if [ "${AGE}" -lt 0 ]; then
	unhealthy "${STATUS_FILE} modification time is $((-AGE))s in the future - check the system clock"
fi

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
