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
  grep -qv root <( groups "${oduser}" ) || { echo 'ROOT level privileges prohibited!'; exit 1; }
fi

# Default parameters
ARGS=(--monitor --confdir /onedrive/conf --syncdir /onedrive/data)
echo "Base Args: ${ARGS}"

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

# Tell client to sync in upload-only mode based on environment variable
if [ "${ONEDRIVE_UPLOADONLY:=0}" == "1" ]; then
   echo "# We are synchronizing in upload-only mode"
   echo "# Adding --upload-only"
   ARGS=(--upload-only ${ARGS[@]})
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

# Tell client to utilize provided auth reponse based on environment variable
if [ -n "${ONEDRIVE_AUTHRESPONSE:=""}" ]; then
   echo "# We are providing the auth response directly to perform authentication"
   echo "# Adding --auth-response ARG"
   ARGS=(--auth-response \"${ONEDRIVE_AUTHRESPONSE}\" ${ARGS[@]})
fi

if [ ${#} -gt 0 ]; then
  ARGS=("${@}")
fi

echo "# Launching onedrive"
# Only switch user if not running as target uid (ie. Docker)
if [ "$ONEDRIVE_UID" = "$(id -u)" ]; then
   /usr/local/bin/onedrive "${ARGS[@]}"
else
   chown "${oduser}:${odgroup}" /onedrive/data /onedrive/conf
   exec gosu "${oduser}" /usr/local/bin/onedrive "${ARGS[@]}"
fi
