#!/bin/bash -eu

set +H -euo pipefail

: ${ONEDRIVE_UID:=$(stat /onedrive/data -c '%u')}
: ${ONEDRIVE_GID:=$(stat /onedrive/data -c '%g')}

# Create new group using target GID
if ! odgroup="$(getent group "$ONEDRIVE_GID")"; then
	odgroup='onedrive'
	groupadd "${odgroup}" -g "$ONEDRIVE_GID"
else
	odgroup=${odgroup%%:*}
fi

# Create new user using target UID
if ! oduser="$(getent passwd "$ONEDRIVE_UID")"; then
	oduser='onedrive'
	useradd -m "${oduser}" -u "$ONEDRIVE_UID" -g "$ONEDRIVE_GID"
else
	oduser="${oduser%%:*}"
	usermod -g "${odgroup}" "${oduser}"
fi

# Root privilege check
# Containers should not be run as 'root', but allow via environment variable override
if [ "${ONEDRIVE_RUNAS_ROOT:=0}" == "1" ]; then
	echo "# Running container as root due to environment variable override"
	oduser='root'
	odgroup='root'
else 
	grep -qv root <( groups "${oduser}" ) || { echo 'ROOT level privileges prohibited!'; exit 1; }
	echo "# Running container as user: ${oduser}"
fi

# Default parameters
ARGS=(--confdir /onedrive/conf --syncdir /onedrive/data)
echo "# Base Args: ${ARGS}"

# Tell client to use Standalone Mode, based on an environment variable. Otherwise Monitor Mode is used.
if [ "${ONEDRIVE_SYNC_ONCE:=0}" == "1" ]; then
	echo "# We run in Standalone Mode"
	echo "# Adding --sync"
	ARGS=(--sync ${ARGS[@]})
else
	echo "# We run in Monitor Mode"
	echo "# Adding --monitor"
	ARGS=(--monitor ${ARGS[@]})
fi

# Make Verbose output optional, based on an environment variable
if [ "${ONEDRIVE_VERBOSE:=0}" == "1" ]; then
	echo "# We are being verbose"
	echo "# Adding --verbose"
	ARGS=(--verbose ${ARGS[@]})
fi

# Tell client to perform debug output, based on an environment variable
if [ "${ONEDRIVE_DEBUG:=0}" == "1" ]; then
	echo "# We are performing debug output"
	echo "# Adding --verbose --verbose"
	ARGS=(--verbose --verbose ${ARGS[@]})
fi

# Tell client to perform HTTPS debug output, based on an environment variable
if [ "${ONEDRIVE_DEBUG_HTTPS:=0}" == "1" ]; then
	echo "# We are performing HTTPS debug output"
	echo "# Adding --debug-https"
	ARGS=(--debug-https ${ARGS[@]})
fi

# Tell client to perform a resync based on environment variable
if [ "${ONEDRIVE_RESYNC:=0}" == "1" ]; then
	echo "# We are performing a --resync"
	echo "# Adding --resync --resync-auth"
	ARGS=(--resync --resync-auth ${ARGS[@]})
fi

# Tell client to sync in download-only mode based on environment variable
if [ "${ONEDRIVE_DOWNLOADONLY:=0}" == "1" ]; then
	echo "# We are synchronizing in download-only mode"
	echo "# Adding --download-only"
	ARGS=(--download-only ${ARGS[@]})
fi

# Tell client to clean up local files when in download-only mode based on environment variable
if [ "${ONEDRIVE_CLEANUPLOCAL:=0}" == "1" ]; then
	echo "# We are cleaning up local files that are not present online"
	echo "# Adding --cleanup-local-files"
	ARGS=(--cleanup-local-files ${ARGS[@]})
fi

# Tell client to sync in upload-only mode based on environment variable
if [ "${ONEDRIVE_UPLOADONLY:=0}" == "1" ]; then
	echo "# We are synchronizing in upload-only mode"
	echo "# Adding --upload-only"
	ARGS=(--upload-only ${ARGS[@]})
fi

# Tell client to sync in no-remote-delete mode based on environment variable
if [ "${ONEDRIVE_NOREMOTEDELETE:=0}" == "1" ]; then
	echo "# We are synchronizing in no-remote-delete mode"
	echo "# Adding --no-remote-delete"
	ARGS=(--no-remote-delete ${ARGS[@]})
fi

# Tell client to logout based on environment variable
if [ "${ONEDRIVE_LOGOUT:=0}" == "1" ]; then
	echo "# We are logging out"
	echo "# Adding --logout"
	ARGS=(--logout ${ARGS[@]})
fi

# Tell client to re-authenticate based on environment variable
if [ "${ONEDRIVE_REAUTH:=0}" == "1" ]; then
	echo "# We are logging out to perform a reauthentication"
	echo "# Adding --reauth"
	ARGS=(--reauth ${ARGS[@]})
fi

# Tell client to utilize auth files at the provided locations based on environment variable
if [ -n "${ONEDRIVE_AUTHFILES:=""}" ]; then
	echo "# We are using auth files to perform authentication"
	echo "# Adding --auth-files ARG"
	ARGS=(--auth-files ${ONEDRIVE_AUTHFILES} ${ARGS[@]})
fi

# Tell client to utilize provided auth response based on environment variable
if [ -n "${ONEDRIVE_AUTHRESPONSE:=""}" ]; then
	echo "# We are providing the auth response directly to perform authentication"
	echo "# Adding --auth-response ARG"
	ARGS=(--auth-response \"${ONEDRIVE_AUTHRESPONSE}\" ${ARGS[@]})
fi

# Tell client to print the running configuration at application startup
if [ "${ONEDRIVE_DISPLAY_CONFIG:=0}" == "1" ]; then
	echo "# We are printing the application running configuration at application startup"
	echo "# Adding --display-running-config"
	ARGS=(--display-running-config ${ARGS[@]})
fi

# Tell client to use sync single dir option
if [ -n "${ONEDRIVE_SINGLE_DIRECTORY:=""}" ]; then
	echo "# We are synchronizing in single-directory mode"
	echo "# Adding --single-directory ARG"
	ARGS=(--single-directory \"${ONEDRIVE_SINGLE_DIRECTORY}\" ${ARGS[@]})
fi

# Tell client run in dry-run mode
if [ "${ONEDRIVE_DRYRUN:=0}" == "1" ]; then
	echo "# We are running in dry-run mode"
	echo "# Adding --dry-run"
	ARGS=(--dry-run ${ARGS[@]})
fi

# Tell client to disable download validation
if [ "${ONEDRIVE_DISABLE_DOWNLOAD_VALIDATION:=0}" == "1" ]; then
	echo "# We are disabling the download integrity checks performed by this client"
	echo "# Adding --disable-download-validation"
	ARGS=(--disable-download-validation ${ARGS[@]})
fi

# Tell client to disable upload validation
if [ "${ONEDRIVE_DISABLE_UPLOAD_VALIDATION:=0}" == "1" ]; then
	echo "# We are disabling the upload integrity checks performed by this client"
	echo "# Adding --disable-upload-validation"
	ARGS=(--disable-upload-validation ${ARGS[@]})
fi

# Tell client to download OneDrive Business Shared Files if 'sync_business_shared_items' option has been enabled in the configuration files
if [ "${ONEDRIVE_SYNC_SHARED_FILES:=0}" == "1" ]; then
	echo "# We are attempting to sync OneDrive Business Shared Files if 'sync_business_shared_items' has been enabled in the config file"
	echo "# Adding --sync-shared-files"
	ARGS=(--sync-shared-files ${ARGS[@]})
fi

if [ ${#} -gt 0 ]; then
	ARGS=("${@}")
fi

# Only switch user if not running as target uid (ie. Docker)
if [ "$ONEDRIVE_UID" = "$(id -u)" ]; then
	echo "# Launching 'onedrive' as ${oduser}"
	/usr/local/bin/onedrive "${ARGS[@]}"
else
	echo "# Changing ownership permissions on /onedrive/data and /onedrive/conf to ${oduser}:${odgroup}"
	chown "${oduser}:${odgroup}" /onedrive/data /onedrive/conf
	echo "# Launching 'onedrive' as ${oduser} via gosu"
	exec gosu "${oduser}" /usr/local/bin/onedrive "${ARGS[@]}"
fi