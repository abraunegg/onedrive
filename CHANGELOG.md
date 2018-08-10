# Changelog

The format is based on [Keep a Changelog](http://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](http://semver.org/spec/v2.0.0.html).

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
