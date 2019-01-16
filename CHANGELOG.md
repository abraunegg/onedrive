# Changelog

The format is based on [Keep a Changelog](http://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](http://semver.org/spec/v2.0.0.html).

## [2.2.5] - 2019-01-16
### Fixed
- Update handling of HTTP 412 - Precondition Failed errors
- Update --display-config to display sync_list if configured
- Add a check for 'id' key on metadata update to prevent 'std.json.JSONException@std/json.d(494): Key not found: id'
- Update handling of 'remote' folder designation as 'root' items
- Ensure that remote deletes are handled correctly
- Handle 'Item not found' exception when unable to query OneDrive 'root' for changes
- Add handling for JSON response error when OneDrive API returns a 404 due to OneDrive API regression
- Fix items highlighted by codacy review

### Added
- Add --force-http-1.1 flag to downgrade any HTTP/2 curl operations to HTTP 1.1 protocol
- Support building with ldc2 and usage of pkg-config for lib finding

## [2.2.4] - 2018-12-28
### Fixed
- Resolve JSONException when supplying --get-O365-drive-id option with a string containing spaces
- Resolve 'sync_dir' not read from 'config' file when run in Docker container
- Resolve logic where potentially a 'default' ~/OneDrive sync_dir could be set despite 'config' file configured for an alternate
- Make sure sqlite checkpointing works by properly finalizing statements
- Update logic handling of --single-directory to prevent inadvertent local data loss
- Resolve signal handling and database shutdown on SIGINT and SIGTERM
- Update man page
- Implement better help output formatting

### Added
- Add debug handling for sync_dir operations
- Add debug handling for homePath calculation
- Add debug handling for configDirBase calculation
- Add debug handling if syncDir is created
- Implement Feature Request: Add status command or switch

## [2.2.3] - 2018-12-20
### Fixed
- Fix syncdir option is ignored

## [2.2.2] - 2018-12-20
### Fixed
- Handle short lived files in monitor mode
- Provide better log messages, less noise on temporary timeouts
- Deal with items that disappear during upload
- Deal with deleted move targets
- Reinitialize sync engine after three failed attempts
- Fix activation of dmd for docker builds
- Fix to check displayName rather than description for --get-O365-drive-id
- Fix checking of config file keys for validity
- Fix exception handling when missing parameter from usage option

### Added
- Notification support via libnotify
- Add very verbose (debug) mode by double -v -v
- Implement option --display-config

## [2.2.1] - 2018-12-04
### Fixed
- Gracefully handle connection errors in monitor mode 
- Fix renaming of files when syncing 
- Installation of doc files, addition of man page 
- Adjust timeout values for libcurl 
- Continue in monitor mode when sync timed out 
- Fix unreachable statements 
- Update Makefile to better support packaging 
- Allow starting offline in monitor mode 

### Added
- Implement --get-O365-drive-id to get correct SharePoint Shared Library (#248)
- Docker buildfiles for onedrive service (#262) 

## [2.2.0] - 2018-11-24
### Fixed
- Updated client to output additional logging when debugging
- Resolve database assertion failure due to authentication
- Resolve unable to create folders on shared OneDrive Personal accounts

### Added
- Implement feature request to Sync from Microsoft SharePoint
- Implement feature request to specify a logging directory if logging is enabled

### Changed
- Change '--download' to '--download-only' to align with '--upload-only'
- Change logging so that logging to a separate file is no longer the default

## [2.1.6] - 2018-11-15
### Fixed
- Updated HTTP/2 transport handling when using curl 7.62.0 for session uploads

### Added
- Added PKGBUILD for makepkg for building packages under Arch Linux

## [2.1.5] - 2018-11-11
### Fixed
- Resolve 'Key not found: path' when syncing from some shared folders due to OneDrive API change
- Resolve to only upload changes on remote folder if the item is in the database - dont assert if false
- Resolve files will not download or upload when using curl 7.62.0 due to HTTP/2 being set as default for all curl operations
- Resolve to handle HTTP request returned status code 412 (Precondition Failed) for session uploads to OneDrive Personal Accounts
- Resolve unable to remove '~/.config/onedrive/resume_upload: No such file or directory' if there is a session upload error and the resume file does not get created
- Resolve handling of response codes when using 2 different systems when using '--upload-only' but the same OneDrive account and uploading the same filename to the same location

### Updated
- Updated Travis CI building on LDC v1.11.0 for ARMHF builds
- Updated Makefile to use 'install -D -m 644' rather than 'cp -raf'
- Updated default config to be aligned to code defaults

## [2.1.4] - 2018-10-10
### Fixed
- Resolve syncing of OneDrive Personal Shared Folders due to OneDrive API change
- Resolve incorrect systemd installation location(s) in Makefile

## [2.1.3] - 2018-10-04
### Fixed
- Resolve File download fails if the file is marked as malware in OneDrive
- Resolve high CPU usage when running in monitor mode
- Resolve how default path is set when running under systemd on headless systems
- Resolve incorrectly nested configDir in X11 systems
- Resolve Key not found: driveType
- Resolve to validate filename length before download to conform with Linux FS limits
- Resolve file handling to look for HTML ASCII codes which will cause uploads to fail
- Resolve Key not found: expirationDateTime on session resume

### Added
- Update Travis CI building to test build on ARM64

## [2.1.2] - 2018-08-27
### Fixed
- Resolve skipping of symlinks in monitor mode
- Resolve Gateway Timeout - JSONValue is not an object
- Resolve systemd/user is not supported on CentOS / RHEL
- Resolve HTTP request returned status code 429 (Too Many Requests)
- Resolve handling of maximum path length calculation
- Resolve 'The parent item is not in the local database'
- Resolve Correctly handle file case sensitivity issues in same folder
- Update unit files documentation link

## [2.1.1] - 2018-08-14
### Fixed
- Fix handling no remote delete of remote directories when using --no-remote-delete
- Fix handling of no permission to access a local file / corrupt local file
- Fix application crash when unable to access login.microsoft.com upon application startup

### Added
- Build instructions for openSUSE Leap 15.0

## [2.1.0] - 2018-08-10

### Fixed
- Fix handling of database exit scenarios when there is zero disk space left on drive where the items database resides
- Fix handling of incorrect database permissions
- Fix handling of different database versions to automatically re-create tables if version mis-match
- Fix handling timeout when accessing the Microsoft OneDrive Service
- Fix localFileModifiedTime to not use fraction seconds

### Added
- Implement Feature: Add a progress bar for large uploads & downloads
- Implement Feature: Make checkinterval for monitor configurable
- Implement Feature: Upload Only Option that does not perform remote delete
- Implement Feature: Add ability to skip symlinks
- Add dependency, ebuild and build instructions for Gentoo distributions

### Changed
- Build instructions for x86, x86_64 and ARM32 platforms
- Travis CI files to automate building on x32, x64 and ARM32 architectures
- Travis CI files to test built application against valid, invalid and problem files from previous issues

## [2.0.2] - 2018-07-18
### Fixed
- Fix systemd service install for builds with DESTDIR defined
- Fix 'HTTP 412 - Precondition Failed' error handling
- Gracefully handle OneDrive account password change
- Update logic handling of --upload-only and --local-first

## [2.0.1] - 2018-07-11
### Fixed
- Resolve computeQuickXorHash generates a different hash when files are > 64Kb

## [2.0.0] - 2018-07-10
### Fixed
- Resolve conflict resolution issue during syncing - the client does not handle conflicts very well & keeps on adding the hostname to files
- Resolve Skilion #356 by adding additional check for 409 response from OneDrive
- Resolve multiple versions of file shown on website after single upload
- Resolve to gracefully fail when 'onedrive' process cannot get exclusive database lock
- Resolve 'Key not found: fileSystemInfo' when then item is a remote item (OneDrive Personal)
- Resolve skip_file config entry needs to be checked for any characters to escape
- Resolve Microsoft Naming Convention not being followed correctly
- Resolve Error when trying to upload a file with weird non printable characters present
- Resolve Crash if file is locked by online editing (status code 423)
- Resolve Resolve compilation issue with dmd-2.081.0
- Resolve skip_file configuration doesn't handle spaces or specified directory paths

### Added
- Implement Feature: Add a flag to detect when the sync-folder is missing
- Implement Travis CI for code testing

### Changed
- Update Makefile to use DESTDIR variables
- Update OneDrive Business maximum path length from 256 to 400
- Update OneDrive Business allowed characters for files and folders
- Update sync_dir handling to use the absolute path for setting parameter to something other than ~/OneDrive via config file or command line
- Update Fedora build instructions

## [1.1.2] - 2018-05-17
### Fixed
- Fix 4xx errors including (412 pre-condition, 409 conflict)
- Fix Key not found: lastModifiedDateTime (OneDrive API change)
- Fix configuration directory not found when run via init.d
- Fix Skillion Issues #73, #121, #132, #224, #257, #294, #295, #297, #298, #300, #306, #315, #320, #329, #334, #337, #341
### Added
- Add logging - log client activities to a file (/var/log/onedrive/%username%.onedrive.log or ~/onedrive.log)
- Add https debugging as a flag
- Add `--synchronize` to prevent from syncing when just blindly running the application
- Add individual folder sync
- Add sync from local directory first rather than download first then upload
- Add upload long path check
- Add upload only
- Add check for max upload file size before attempting upload
- Add systemd unit files for single & multi user configuration
- Add init.d file for older init.d based services
- Add Microsoft naming conventions and namespace validation for items that will be uploaded
- Add remaining free space counter at client initialisation to avoid out of space upload issue
- Add large file upload size check to align to OneDrive file size limitations
- Add upload file size validation & retry if does not match
- Add graceful handling of some fatal errors (OneDrive 5xx error handling)
### Changed

## [Unreleased] - 2018-02-19
### Fixed
- Crash when the delta link is expired
### Changed
- Disabled buffering on stdout

## [1.1.1] - 2018-01-20
### Fixed
- Wrong regex for parsing authentication uri

## [1.1.0] - 2018-01-19
### Added
- Support for shared folders (OneDrive Personal only)
- `--download` option to only download changes
- `DC` variable in Makefile to chose the compiler
### Changed
- Print logs on stdout instead of stderr
- Improve log messages

## [1.0.1] - 2017-08-01
### Added
- `--syncdir` option
### Changed
- `--version` output simplified
- Updated README
### Fixed
- Fix crash caused by remotely deleted and recreated directories

## [1.0.0] - 2017-07-14
### Added
- `--version` option
