#!/bin/bash
# Docker/Podman HEALTHCHECK for the onedrive container.
#
# Reads the machine-readable runtime status published by --monitor at
# /onedrive/conf/monitor-status.json (see
# docs/usage.md#machine-readable-monitor-runtime-status) and reports
# healthy only when:
#   - the pid recorded in the file belongs to a running 'onedrive' process
#     that started before the file was last written,
#   - the file was published recently enough to not be a stale leftover
#     from a crashed/killed process, and
#   - the first synchronisation cycle has completed successfully.
#
# Requires jq, which is included in the container images.
set -u

unhealthy() {
	echo "unhealthy: $*"
	exit 1
}

# The expected path for the monitor file inside the container
STATUS_FILE="/onedrive/conf/monitor-status.json"

# The status file layout this script understands. A different
# schema_version may move or rename the fields checked below.
SUPPORTED_SCHEMA_VERSION=1

# Validate the status document and print "<pid> <state> <initial sync>".
# Every field is checked for type and value here, so a missing field,
# a null or a value of the wrong type is reported by its JSON path rather
# than passed on to the checks below. process.state must be one of the
# states the monitor publishes; a degraded state (the last cycle did not
# fully succeed) is accepted, as it does not mean the monitor has stopped
# working and is usually resolved by a later cycle.
    read -r -d '' STATUS_FILTER <<'EOF'
def field(path; expected):
	getpath(path) as $value
	| if ($value | type) == expected then $value
	  else error("field '\(path | join("."))' is \($value | type), expected \(expected)")
	  end;
def require(condition; message):
	if condition then . else error(message) end;

if length != 1 then error("expected one JSON document, found \(length)") else .[0] end
| if type != "object" then error("top-level value is \(type), expected object") else . end
| (field(["schema_version"]; "number")
	| require(. == $supported; "schema_version is \(.), this healthcheck supports \($supported)")) as $schema
| (field(["pid"]; "number")
	| require(. == floor and . > 0; "field 'pid' is \(.), expected a positive integer")) as $pid
| (field(["process", "state"]; "string")
	| require(IN("starting", "syncing", "idle", "degraded"); "field 'process.state' has unknown value \"\(.)\"")) as $state
| field(["sync", "initial_successful_sync_completed"]; "boolean") as $initial_sync
| "\($pid) \($state) \($initial_sync)"
EOF

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

if ! command -v jq >/dev/null 2>&1; then
	unhealthy "jq not found - this healthcheck requires a container image that includes jq"
fi

# A single jq invocation opens the file once, so all fields come from the
# same snapshot even if the monitor atomically replaces the file while this
# check is running. --slurp makes an empty file or one containing several
# JSON documents a reported error rather than an empty or partial result.
# On failure, the first line of jq's message (a parse error, or one raised
# by the filter above) is reported without its "jq: " prefix.
if ! STATUS_FIELDS="$(jq --slurp --raw-output --argjson supported "${SUPPORTED_SCHEMA_VERSION}" "${STATUS_FILTER}" "${STATUS_FILE}" 2>&1)"; then
	STATUS_FIELDS="${STATUS_FIELDS%%$'\n'*}"
	STATUS_FIELDS="${STATUS_FIELDS#jq: error (at *): }"
	unhealthy "invalid ${STATUS_FILE}: ${STATUS_FIELDS#jq: }"
fi
read -r PID STATE INITIAL_SYNC_DONE <<< "${STATUS_FIELDS}"

# Liveness: a crashed or SIGKILLed monitor leaves its last snapshot behind,
# so the pid recorded in the status file must belong to a running process
# named 'onedrive'. A process existing with that pid is not on its own proof
# that it is the same monitor that wrote the file: pids are reused, and the
# monitor is normally pid 1 in the container, so after a restart the new
# instance has the same pid as the one that left the file behind. The start
# time check further below covers that case.
if ! { read -r PROC_STAT < "/proc/${PID}/stat"; } 2>/dev/null \
	|| ! { read -r PROC_COMM < "/proc/${PID}/comm"; } 2>/dev/null; then
	unhealthy "monitor pid ${PID} from status file is not running"
fi
if [ "${PROC_COMM}" != "onedrive" ]; then
	unhealthy "pid ${PID} from status file is '${PROC_COMM}', not the onedrive monitor"
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

# Identity: a running monitor can only have written the file after it
# started, so a file last written before the recorded process started was
# left behind by a previous instance that happened to have the same pid. The process start
# time is boot time plus field 22 of /proc/<pid>/stat (in clock ticks). The
# fields are read after the last ')' because the process name preceding it
# may itself contain spaces or parentheses. This still cannot distinguish
# a different 'onedrive' process that reused the pid and started before
# the file was written, but the staleness check limits how long such a
# file is trusted.
read -r -a PROC_FIELDS <<< "${PROC_STAT##*) }"
PROC_START_TICKS="${PROC_FIELDS[19]-}"
BOOT_TIME=""
while read -r key value _; do
	if [ "${key}" = "btime" ]; then
		BOOT_TIME="${value}"
		break
	fi
done < /proc/stat
CLK_TCK="$(getconf CLK_TCK 2>/dev/null)"
if [[ ! ${CLK_TCK} =~ ^[1-9][0-9]*$ ]]; then
	CLK_TCK=100
fi
if [[ ! ${PROC_START_TICKS} =~ ^[0-9]+$ ]] || [[ ! ${BOOT_TIME} =~ ^[0-9]+$ ]]; then
	unhealthy "could not determine the start time of monitor pid ${PID}"
fi
PROC_START=$((BOOT_TIME + PROC_START_TICKS / CLK_TCK))

# Both timestamps are truncated to whole seconds, so allow 1s of slack.
if [ $((MTIME + 1)) -lt "${PROC_START}" ]; then
	unhealthy "${STATUS_FILE} was last written $((PROC_START - MTIME))s before monitor pid ${PID} started - left behind by a previous instance"
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
