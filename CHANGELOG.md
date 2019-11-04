# Changelog

The format is based on [Keep a Changelog](http://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](http://semver.org/spec/v2.0.0.html).

## 2.3.11 - 2019-11-05
### Fixed
*   Fix typo in the documentation regarding invalid config when upgrading from 'skilion' codebase
*   Fix handling of skip_dir, skip_file & sync_list config options
*   Fix typo in the documentation regarding sync_list
*   Fix log output to be consistent with sync_list exclusion
*   Fix 'Processing X changes' output to be more reflective of actual activity when using sync_list
*   Remove unused and unexported SED variable in Makefile.in 
*   Handle curl exceptions and timeouts better with backoff/retry logic
*   Update skip_dir pattern matching when using wildcards
*   Fix when a full rescan is performed when using sync_list
*   Fix 'Key not found: name' when computing skip_dir path
*   Fix call from --monitor to observe --no-remote-delete
*   Fix unhandled exception when monitor initialisation failure occurs due to too many open local files
*   Fix unhandled 412 error response from OneDrive API when moving files right after upload
*   Fix --monitor when used with --download-only. This fixes a regression introduced in 12947d1.
*   Fix if --single-directory is being used, and we are using --monitor, only set inotify watches on the single directory

### Changed
*   Move JSON logging output from error messages to debug output

## 2.3.10 - 2019-10-01
### Fixed
*   Fix searching for 'name' when deleting a synced item, if the OneDrive API does not return the expected details in the API call
*   Fix abnormal termination when no Internet connection
*   Fix downloading of files from OneDrive Personal Shared Folders when the OneDrive API responds with unexpected additional path data
*   Fix logging of 'initialisation' of client to actually when the attempt to initialise is performed
*   Fix when using a sync_list file, using deltaLink will actually 'miss' changes (moves & deletes) on OneDrive as using sync_list discards changes
*   Fix OneDrive API status code 500 handling when uploading files as error message is not correct
*   Fix crash when resume_upload file is not a valid JSON 
*   Fix crash when a file system exception is generated when attempting to update the file date & time and this fails

### Added
*   If there is a case-insensitive match error, also return the remote name from the response
*   Make user-agent string a configuration option & add to config file
*   Set default User-Agent to 'OneDrive Client for Linux v{version}'

### Changed
*   Make verbose logging output optional on Docker
*   Enable --resync & debug client output via environment variables on Docker

## 2.3.9 - 2019-09-01
### Fixed
*   Catch a 403 Forbidden exception when querying Sharepoint Library Names
*   Fix unhandled error exceptions that cause application to exit / crash when uploading files
*   Fix JSON object validation for queries made against OneDrive where a JSON response is expected and where that response is to be used and expected to be valid
*   Fix handling of 5xx responses from OneDrive when uploading via a session

### Added
*   Detect the need for --resync when config changes either via config file or cli override

### Changed
*   Change minimum required version of LDC to v1.12.0

### Removed
*   Remove redundant logging output due to change in how errors are reported from OneDrive

## 2.3.8 - 2019-08-04
### Fixed
*   Fix unable to download all files when OneDrive fails to return file level details used to validate file integrity
*   Included the flag "-m" to create the home directory when creating the user
*   Fix entrypoint.sh to work with "sudo docker run"
*   Fix docker build error on stretch
*   Fix hidden directories in 'root' from having prefix removed
*   Fix Sharepoint Document Library handling for .txt & .csv files
*   Fix logging for init.d service
*   Fix OneDrive response missing required 'id' element when uploading images
*   Fix 'Unexpected character '<'. (Line 1:1)' when OneDrive has an exception error
*   Fix error when creating the sync dir fails when there is no permission to create the sync dir

### Added
*   Add explicit check for hashes to be returned in cases where OneDrive API fails to provide them despite requested to do so
*   Add comparison with sha1 if OneDrive provides that rather than quickXor
*   Add selinux configuration details for a sync folder outside of the home folder
*   Add date tag on docker.hub
*   Add back CentOS 6 install & uninstall to Makefile
*   Add a check to handle moving items out of sync_list sync scope & delete locally if true
*   Implement --get-file-link which will return the weburl of a file which has been synced to OneDrive

### Changed
*   Change unauthorized-api exit code to 3
*   Update LDC to v1.16.0 for Travis CI testing
*   Use replace function for modified Sharepoint Document Library files rather than delete and upload as new file, preserving file history
*   Update Sharepoint modified file handling for files > 4Mb in size

### Removed
*   Remove -d shorthand for --download-only to avoid confusion with other GNU applications where -d stands for 'debug'

## 2.3.7 - 2019-07-03
### Fixed
*   Fix not all files being downloaded due to OneDrive query failure
*   False DB update which potentially could had lead to false data loss on OneDrive

## 2.3.6 - 2019-07-03 (DO NOT USE)
### Fixed
*   Fix JSONValue object validation
*   Fix building without git being available
*   Fix some spelling/grammatical errors
*   Fix OneDrive error response on creating upload session

### Added
*   Add download size & hash check to ensure downloaded files are valid and not corrupt
*   Added --force-http-2 to use HTTP/2 if desired

### Changed
*   Depreciated --force-http-1.1 (enabled by default) due to OneDrive inconsistent behavior with HTTP/2 protocol

## 2.3.5 - 2019-06-19
### Fixed
*   Handle a directory in the sync_dir when no permission to access
*   Get rid of forced root necessity during installation
*   Fix broken autoconf code for --enable-XXX options
*   Fix so that skip_size check should only be used if configured
*   Fix a OneDrive Internal Error exception occurring before attempting to download a file

### Added
*   Check for supported version of D compiler

## 2.3.4 - 2019-06-13
### Fixed
*   Fix 'Local files not deleted' when using bad 'skip_file' entry
*   Fix --dry-run logging output for faking downloading new files
*   Fix install unit files to correct location on RHEL/CentOS 7
*   Fix up unit file removal on all platforms
*   Fix setting times on a file by adding a check to see if the file was actually downloaded before attempting to set the times on the file
*   Fix an unhandled curl exception when OneDrive throws an internal timeout error
*   Check timestamp to ensure that latest timestamp is used when comparing OneDrive changes
*   Fix handling responses where cTag JSON elements are missing
*   Fix Docker entrypoint.sh failures when GID is defined but not UID

### Added
*   Add autoconf based build system
*   Add an encoding validation check before any path length checks are performed as if the path contains any invalid UTF-8 sequences
*   Implement --sync-root-files to sync all files in the OneDrive root when using a sync_list file that would normally exclude these files from being synced
*   Implement skip_size feature request
*   Implement feature request to support file based OneDrive authorization (request | response)

### Updated
*   Better handle initialisation issues when OneDrive / MS Graph is experiencing problems that generate 401 & 5xx error codes
*   Enhance error message when unable to connect to Microsoft OneDrive service when the local CA SSL certificate(s) have issues
*   Update Dockerfile to correctly build on Docker Hub
*   Rework directory layout and re-factor MD files for readability

## 2.3.3 - 2019-04-16
### Fixed
*   Fix --upload-only check for Sharepoint uploads
*   Fix check to ensure item root we flag as 'root' actually is OneDrive account 'root'
*   Handle object error response from OneDrive when uploading to OneDrive Business
*   Fix handling of some OneDrive accounts not providing 'quota' details
*   Fix 'resume_upload' handling in the event of bad OneDrive response

### Added
*   Add debugging for --get-O365-drive-id function
*   Add shell (bash,zsh) completion support
*   Add config options for command line switches to allow for better config handling in docker containers

### Updated
*   Implement more meaningful 5xx error responses
*   Update onedrive.logrotate indentations and comments
*   Update 'min_notif_changes' to 'min_notify_changes'

## 2.3.2 - 2019-04-02
### Fixed
*   Reduce scanning the entire local system in monitor mode for local changes
*   Resolve file creation loop when working directly in the synced folder and Microsoft Sharepoint

### Added
*   Add 'monitor_fullscan_frequency' config option to set the frequency of performing a full disk scan when in monitor mode

### Updated
*   Update default 'skip_file' to include tmp and lock files generated by LibreOffice
*   Update database version due to changing defaults of 'skip_file' which will force a rebuild and use of new skip_file default regex

## 2.3.1 - 2019-03-26
### Fixed
*   Resolve 'make install' issue where rebuild of application would occur due to 'version' being flagged as .PHONY
*   Update readme build instructions to include 'make clean;' before build to ensure that 'version' is cleanly removed and can be updated correctly
*   Update Debian Travis CI build URL's

## 2.3.0 - 2019-03-25
### Fixed
*   Resolve application crash if no 'size' value is returned when uploading a new file
*   Resolve application crash if a 5xx error is returned when uploading a new file
*   Resolve not 'refreshing' version file when rebuilding
*   Resolve unexpected application processing by preventing use of --synchronize & --monitor together
*   Resolve high CPU usage when performing DB reads
*   Update error logging around directory case-insensitive match
*   Update Travis CI and ARM dependencies for LDC 1.14.0
*   Update Makefile due to build failure if building from release archive file
*   Update logging as to why a OneDrive object was skipped

### Added
*   Implement config option 'skip_dir'

## 2.2.6 - 2019-03-12
### Fixed
*   Resolve application crash when unable to delete remote folders when business retention policies are enabled
*   Resolve deprecation warning: loop index implicitly converted from size_t to int
*   Resolve warnings regarding 'bashisms'
*   Resolve handling of notification failure is dbus server has not started or available
*   Resolve handling of response JSON to ensure that 'id' key element is always checked for
*   Resolve excessive & needless logging in monitor mode
*   Resolve compiling with LDC on Alpine as musl lacks some standard interfaces
*   Resolve notification issues when offline and cannot act on changes
*   Resolve Docker entrypoint.sh to accept command line arguments
*   Resolve to create a new upload session on reinit 
*   Resolve where on OneDrive query failure, default root and drive id is used if a response is not returned
*   Resolve Key not found: nextExpectedRanges when attempting session uploads and incorrect response is returned
*   Resolve application crash when re-using an authentication URI twice after previous --logout
*   Resolve creating a folder on a shared personal folder appears successful but returns a JSON error
*   Resolve to treat mv of new file as upload of mv target
*   Update Debian i386 build dependencies
*   Update handling of --get-O365-drive-id to print out all 'site names' that match the explicit search entry rather than just the last match
*   Update Docker readme & documentation
*   Update handling of validating local file permissions for new file uploads
### Added
*   Add support for install & uninstall on RHEL / CentOS 6.x
*   Add support for when notifications are enabled, display the number of OneDrive changes to process if any are found
*   Add 'config' option 'min_notif_changes' for minimum number of changes to notify on, default = 5
*   Add additional Docker container builds utilising a smaller OS footprint
*   Add configurable interval of logging in monitor mode
*   Implement new CLI option --skip-dot-files to skip .files and .folders if option is used
*   Implement new CLI option --check-for-nosync to ignore folder when special file (.nosync) present
*   Implement new CLI option --dry-run

## 2.2.5 - 2019-01-16
### Fixed
*   Update handling of HTTP 412 - Precondition Failed errors
*   Update --display-config to display sync_list if configured
*   Add a check for 'id' key on metadata update to prevent 'std.json.JSONException@std/json.d(494): Key not found: id'
*   Update handling of 'remote' folder designation as 'root' items
*   Ensure that remote deletes are handled correctly
*   Handle 'Item not found' exception when unable to query OneDrive 'root' for changes
*   Add handling for JSON response error when OneDrive API returns a 404 due to OneDrive API regression
*   Fix items highlighted by codacy review
### Added
*   Add --force-http-1.1 flag to downgrade any HTTP/2 curl operations to HTTP 1.1 protocol
*   Support building with ldc2 and usage of pkg-config for lib finding

## 2.2.4 - 2018-12-28
### Fixed
*   Resolve JSONException when supplying --get-O365-drive-id option with a string containing spaces
*   Resolve 'sync_dir' not read from 'config' file when run in Docker container
*   Resolve logic where potentially a 'default' ~/OneDrive sync_dir could be set despite 'config' file configured for an alternate
*   Make sure sqlite checkpointing works by properly finalizing statements
*   Update logic handling of --single-directory to prevent inadvertent local data loss
*   Resolve signal handling and database shutdown on SIGINT and SIGTERM
*   Update man page
*   Implement better help output formatting
### Added
*   Add debug handling for sync_dir operations
*   Add debug handling for homePath calculation
*   Add debug handling for configDirBase calculation
*   Add debug handling if syncDir is created
*   Implement Feature Request: Add status command or switch

## 2.2.3 - 2018-12-20
### Fixed
*   Fix syncdir option is ignored

## 2.2.2 - 2018-12-20
### Fixed
*   Handle short lived files in monitor mode
*   Provide better log messages, less noise on temporary timeouts
*   Deal with items that disappear during upload
*   Deal with deleted move targets
*   Reinitialize sync engine after three failed attempts
*   Fix activation of dmd for docker builds
*   Fix to check displayName rather than description for --get-O365-drive-id
*   Fix checking of config file keys for validity
*   Fix exception handling when missing parameter from usage option
### Added
*   Notification support via libnotify
*   Add very verbose (debug) mode by double -v -v
*   Implement option --display-config

## 2.2.1 - 2018-12-04
### Fixed
*   Gracefully handle connection errors in monitor mode 
*   Fix renaming of files when syncing 
*   Installation of doc files, addition of man page 
*   Adjust timeout values for libcurl 
*   Continue in monitor mode when sync timed out 
*   Fix unreachable statements 
*   Update Makefile to better support packaging 
*   Allow starting offline in monitor mode 
### Added
*   Implement --get-O365-drive-id to get correct SharePoint Shared Library (#248)
*   Docker buildfiles for onedrive service (#262) 

## 2.2.0 - 2018-11-24
### Fixed
*   Updated client to output additional logging when debugging
*   Resolve database assertion failure due to authentication
*   Resolve unable to create folders on shared OneDrive Personal accounts
### Added
*   Implement feature request to Sync from Microsoft SharePoint
*   Implement feature request to specify a logging directory if logging is enabled
### Changed
*   Change '--download' to '--download-only' to align with '--upload-only'
*   Change logging so that logging to a separate file is no longer the default

## 2.1.6 - 2018-11-15
### Fixed
*   Updated HTTP/2 transport handling when using curl 7.62.0 for session uploads
### Added
*   Added PKGBUILD for makepkg for building packages under Arch Linux

## 2.1.5 - 2018-11-11
### Fixed
*   Resolve 'Key not found: path' when syncing from some shared folders due to OneDrive API change
*   Resolve to only upload changes on remote folder if the item is in the database - dont assert if false
*   Resolve files will not download or upload when using curl 7.62.0 due to HTTP/2 being set as default for all curl operations
*   Resolve to handle HTTP request returned status code 412 (Precondition Failed) for session uploads to OneDrive Personal Accounts
*   Resolve unable to remove '~/.config/onedrive/resume_upload: No such file or directory' if there is a session upload error and the resume file does not get created
*   Resolve handling of response codes when using 2 different systems when using '--upload-only' but the same OneDrive account and uploading the same filename to the same location
### Updated
*   Updated Travis CI building on LDC v1.11.0 for ARMHF builds
*   Updated Makefile to use 'install -D -m 644' rather than 'cp -raf'
*   Updated default config to be aligned to code defaults

## 2.1.4 - 2018-10-10
### Fixed
*   Resolve syncing of OneDrive Personal Shared Folders due to OneDrive API change
*   Resolve incorrect systemd installation location(s) in Makefile

## 2.1.3 - 2018-10-04
### Fixed
*   Resolve File download fails if the file is marked as malware in OneDrive
*   Resolve high CPU usage when running in monitor mode
*   Resolve how default path is set when running under systemd on headless systems
*   Resolve incorrectly nested configDir in X11 systems
*   Resolve Key not found: driveType
*   Resolve to validate filename length before download to conform with Linux FS limits
*   Resolve file handling to look for HTML ASCII codes which will cause uploads to fail
*   Resolve Key not found: expirationDateTime on session resume
### Added
*   Update Travis CI building to test build on ARM64

## 2.1.2 - 2018-08-27
### Fixed
*   Resolve skipping of symlinks in monitor mode
*   Resolve Gateway Timeout - JSONValue is not an object
*   Resolve systemd/user is not supported on CentOS / RHEL
*   Resolve HTTP request returned status code 429 (Too Many Requests)
*   Resolve handling of maximum path length calculation
*   Resolve 'The parent item is not in the local database'
*   Resolve Correctly handle file case sensitivity issues in same folder
*   Update unit files documentation link

## 2.1.1 - 2018-08-14
### Fixed
*   Fix handling no remote delete of remote directories when using --no-remote-delete
*   Fix handling of no permission to access a local file / corrupt local file
*   Fix application crash when unable to access login.microsoft.com upon application startup
### Added
*   Build instructions for openSUSE Leap 15.0

## 2.1.0 - 2018-08-10
### Fixed
*   Fix handling of database exit scenarios when there is zero disk space left on drive where the items database resides
*   Fix handling of incorrect database permissions
*   Fix handling of different database versions to automatically re-create tables if version mis-match
*   Fix handling timeout when accessing the Microsoft OneDrive Service
*   Fix localFileModifiedTime to not use fraction seconds
### Added
*   Implement Feature: Add a progress bar for large uploads & downloads
*   Implement Feature: Make checkinterval for monitor configurable
*   Implement Feature: Upload Only Option that does not perform remote delete
*   Implement Feature: Add ability to skip symlinks
*   Add dependency, ebuild and build instructions for Gentoo distributions
### Changed
*   Build instructions for x86, x86_64 and ARM32 platforms
*   Travis CI files to automate building on x32, x64 and ARM32 architectures
*   Travis CI files to test built application against valid, invalid and problem files from previous issues

## 2.0.2 - 2018-07-18
### Fixed
*   Fix systemd service install for builds with DESTDIR defined
*   Fix 'HTTP 412 - Precondition Failed' error handling
*   Gracefully handle OneDrive account password change
*   Update logic handling of --upload-only and --local-first

## 2.0.1 - 2018-07-11
### Fixed
*   Resolve computeQuickXorHash generates a different hash when files are > 64Kb

## 2.0.0 - 2018-07-10
### Fixed
*   Resolve conflict resolution issue during syncing - the client does not handle conflicts very well & keeps on adding the hostname to files
*   Resolve skilion #356 by adding additional check for 409 response from OneDrive
*   Resolve multiple versions of file shown on website after single upload
*   Resolve to gracefully fail when 'onedrive' process cannot get exclusive database lock
*   Resolve 'Key not found: fileSystemInfo' when then item is a remote item (OneDrive Personal)
*   Resolve skip_file config entry needs to be checked for any characters to escape
*   Resolve Microsoft Naming Convention not being followed correctly
*   Resolve Error when trying to upload a file with weird non printable characters present
*   Resolve Crash if file is locked by online editing (status code 423)
*   Resolve Resolve compilation issue with dmd-2.081.0
*   Resolve skip_file configuration doesn't handle spaces or specified directory paths
### Added
*   Implement Feature: Add a flag to detect when the sync-folder is missing
*   Implement Travis CI for code testing
### Changed
*   Update Makefile to use DESTDIR variables
*   Update OneDrive Business maximum path length from 256 to 400
*   Update OneDrive Business allowed characters for files and folders
*   Update sync_dir handling to use the absolute path for setting parameter to something other than ~/OneDrive via config file or command line
*   Update Fedora build instructions

## 1.1.2 - 2018-05-17
### Fixed
*   Fix 4xx errors including (412 pre-condition, 409 conflict)
*   Fix Key not found: lastModifiedDateTime (OneDrive API change)
*   Fix configuration directory not found when run via init.d
*   Fix skilion Issues #73, #121, #132, #224, #257, #294, #295, #297, #298, #300, #306, #315, #320, #329, #334, #337, #341
### Added
*   Add logging - log client activities to a file (/var/log/onedrive/%username%.onedrive.log or ~/onedrive.log)
*   Add https debugging as a flag
*   Add `--synchronize` to prevent from syncing when just blindly running the application
*   Add individual folder sync
*   Add sync from local directory first rather than download first then upload
*   Add upload long path check
*   Add upload only
*   Add check for max upload file size before attempting upload
*   Add systemd unit files for single & multi user configuration
*   Add init.d file for older init.d based services
*   Add Microsoft naming conventions and namespace validation for items that will be uploaded
*   Add remaining free space counter at client initialisation to avoid out of space upload issue
*   Add large file upload size check to align to OneDrive file size limitations
*   Add upload file size validation & retry if does not match
*   Add graceful handling of some fatal errors (OneDrive 5xx error handling)

## Unreleased - 2018-02-19
### Fixed
*   Crash when the delta link is expired
### Changed
*   Disabled buffering on stdout

## 1.1.1 - 2018-01-20
### Fixed
*   Wrong regex for parsing authentication uri

## 1.1.0 - 2018-01-19
### Added
*   Support for shared folders (OneDrive Personal only)
*   `--download` option to only download changes
*   `DC` variable in Makefile to chose the compiler
### Changed
*   Print logs on stdout instead of stderr
*   Improve log messages

## 1.0.1 - 2017-08-01
### Added
*   `--syncdir` option
### Changed
*   `--version` output simplified
*   Updated README
### Fixed
*   Fix crash caused by remotely deleted and recreated directories

## 1.0.0 - 2017-07-14
### Added
*   `--version` option
