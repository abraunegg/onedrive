#!/bin/bash -eu

set +H -euo pipefail

# ----------------------------------------------------------------------
# Determine how the container is being started:
# - If started as non-root (e.g. --user 1000:1000), we must NOT attempt
#   user/group management or chown, as those require root.
# - If started as root, we can create/align the user and switch via gosu.
# ----------------------------------------------------------------------

CONTAINER_UID="$(id -u)"
CONTAINER_GID="$(id -g)"

# Default ONEDRIVE_UID/GID:
# - When running as non-root: default to the current UID/GID (the values Docker/Podman set)
# - When running as root: keep existing behaviour (infer from /onedrive/data unless explicitly provided)
if [ "${CONTAINER_UID}" -ne 0 ]; then
	: "${ONEDRIVE_UID:=${CONTAINER_UID}}"
	: "${ONEDRIVE_GID:=${CONTAINER_GID}}"
else
	: "${ONEDRIVE_UID:=$(stat /onedrive/data -c '%u')}"
	: "${ONEDRIVE_GID:=$(stat /onedrive/data -c '%g')}"
fi

# ----------------------------------------------------------------------
# Root privilege handling
# ----------------------------------------------------------------------
if [ "${CONTAINER_UID}" -eq 0 ]; then
	# Containers should not run the onedrive client as root by default.
	if [ "${ONEDRIVE_RUNAS_ROOT:=0}" == "1" ]; then
		echo "# Running container as root due to environment variable override"
		oduser='root'
		odgroup='root'
	else
		# Root container start is fine, but we will drop privileges to a non-root user.
		echo "# Container started as root; will drop privileges to UID:GID ${ONEDRIVE_UID}:${ONEDRIVE_GID}"
	fi

	# If we are not forcing root runtime, ensure a non-root user exists for ONEDRIVE_UID/GID
	if [ "${ONEDRIVE_RUNAS_ROOT:=0}" != "1" ]; then
		# Create / select group for target GID
		if ! odgroup="$(getent group "${ONEDRIVE_GID}")"; then
			odgroup='onedrive'
			groupadd "${odgroup}" -g "${ONEDRIVE_GID}"
		else
			odgroup="${odgroup%%:*}"
		fi

		# Create / select user for target UID
		if ! oduser="$(getent passwd "${ONEDRIVE_UID}")"; then
			oduser='onedrive'
			useradd -m "${oduser}" -u "${ONEDRIVE_UID}" -g "${ONEDRIVE_GID}"
		else
			oduser="${oduser%%:*}"
			usermod -g "${odgroup}" "${oduser}"
		fi

		echo "# Running container as user: ${oduser} (UID:GID ${ONEDRIVE_UID}:${ONEDRIVE_GID})"
	fi
else
	# Non-root start (e.g. --user). Do not attempt account management or chown.
	if [ "${ONEDRIVE_RUNAS_ROOT:=0}" == "1" ]; then
		echo "# NOTE: ONEDRIVE_RUNAS_ROOT=1 requested, but container is not running as root; ignoring."
	fi

	echo "# Container started as non-root UID:GID ${CONTAINER_UID}:${CONTAINER_GID}"
	echo "# Using ONEDRIVE_UID:GID ${ONEDRIVE_UID}:${ONEDRIVE_GID} (no user/group creation performed)"
fi

# ----------------------------------------------------------------------
# Default parameters
# ----------------------------------------------------------------------
ARGS=(--confdir /onedrive/conf --syncdir /onedrive/data)
echo "# Base Args: ${ARGS[@]}"

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

# Tell client to use a different value for file fragment size for large file uploads
if [ -n "${ONEDRIVE_FILE_FRAGMENT_SIZE:=""}" ]; then
	echo "# We are specifying the file fragment size for large file uploads (in MB)"
	echo "# Adding --file-fragment-size ARG"
	ARGS=(--file-fragment-size ${ONEDRIVE_FILE_FRAGMENT_SIZE} ${ARGS[@]})
fi

# Tell client to use a specific threads value for parallel operations
if [ -n "${ONEDRIVE_THREADS:=""}" ]; then
	echo "# We are specifying a thread value for the number of worker threads used for parallel upload and download operations"
	echo "# Adding --threads ARG"
	ARGS=(--threads ${ONEDRIVE_THREADS} ${ARGS[@]})
fi

# Allow override of args if command-line parameters are provided
if [ ${#} -gt 0 ]; then
	ARGS=("${@}")
fi

# ----------------------------------------------------------------------
# Launch
# ----------------------------------------------------------------------

# If started non-root, just run directly (no gosu, no chown).
if [ "${CONTAINER_UID}" -ne 0 ]; then
	echo "# Launching 'onedrive' as UID:GID ${CONTAINER_UID}:${CONTAINER_GID}"
	exec /usr/local/bin/onedrive "${ARGS[@]}"
fi

# Started as root:
# - If ONEDRIVE_RUNAS_ROOT=1: run directly as root.
# - Otherwise: chown writable dirs and drop to oduser via gosu.
if [ "${ONEDRIVE_RUNAS_ROOT:=0}" == "1" ]; then
	echo "# Launching 'onedrive' as root"
	exec /usr/local/bin/onedrive "${ARGS[@]}"
else
	echo "# Changing ownership permissions on /onedrive/data and /onedrive/conf to ${oduser}:${odgroup}"
	chown "${oduser}:${odgroup}" /onedrive/data /onedrive/conf
	echo "# Launching 'onedrive' as ${oduser} via gosu"
	exec gosu "${oduser}" /usr/local/bin/onedrive "${ARGS[@]}"
fi
