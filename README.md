# OneDrive Client for Linux
[![Version](https://img.shields.io/github/v/release/abraunegg/onedrive)](https://github.com/abraunegg/onedrive/releases)
[![Release Date](https://img.shields.io/github/release-date/abraunegg/onedrive)](https://github.com/abraunegg/onedrive/releases)
[![Travis CI](https://img.shields.io/travis/com/abraunegg/onedrive)](https://travis-ci.com/abraunegg/onedrive/builds)
[![Docker Build](https://img.shields.io/docker/cloud/automated/driveone/onedrive)](https://hub.docker.com/r/driveone/onedrive)
[![Docker Pulls](https://img.shields.io/docker/pulls/driveone/onedrive)](https://hub.docker.com/r/driveone/onedrive)

A free Microsoft OneDrive Client which supports OneDrive Personal, OneDrive for Business, OneDrive for Office365 and SharePoint.

This powerful and highly configurable client can run on all major Linux distributions, FreeBSD, or as a Docker container. It supports one-way and two-way sync capabilities and securely connects to Microsoft OneDrive services.

This client is a 'fork' of the [skilion](https://github.com/skilion/onedrive) client which was abandoned in 2018.

## Features
*   State caching
*   Real-Time local file monitoring with inotify
*   Real-Time syncing of remote updates via webhooks
*   File upload / download validation to ensure data integrity
*   Resumable uploads
*   Support OneDrive for Business (part of Office 365)
*   Shared Folder support for OneDrive Personal and OneDrive Business accounts
*   SharePoint / Office365 Shared Libraries
*   Desktop notifications via libnotify
*   Dry-run capability to test configuration changes
*   Prevent major OneDrive accidental data deletion after configuration change
*   Support for National cloud deployments (Microsoft Cloud for US Government, Microsoft Cloud Germany, Azure and Office 365 operated by 21Vianet in China)
*   Supports single & multi-tenanted applications
*   Supports rate limiting of traffic

## What's missing
*   Ability to encrypt/decrypt files on-the-fly when uploading/downloading files from OneDrive
*   Support for Windows 'On-Demand' functionality so file is only downloaded when accessed locally

## External Enhancements
*   A GUI for configuration management: [OneDrive Client for Linux GUI](https://github.com/bpozdena/OneDriveGUI)
*   Colorful log output terminal modification: [OneDrive Client for Linux Colorful log Output](https://github.com/zzzdeb/dotfiles/blob/master/scripts/tools/onedrive_log)
*   System Tray Icon: [OneDrive Client for Linux System Tray Icon](https://github.com/DanielBorgesOliveira/onedrive_tray)

## Frequently Asked Questions
Refer to [Frequently Asked Questions](https://github.com/abraunegg/onedrive/wiki/Frequently-Asked-Questions)

## Have a question
If you have a question or need something clarified, please raise a new disscussion post [here](https://github.com/abraunegg/onedrive/discussions)

## Reporting an Issue or Bug
If you encounter any bugs you can report them here on Github. Before filing an issue be sure to:

1.  Check the version of the application you are using `onedrive --version` and ensure that you are running either the latest [release](https://github.com/abraunegg/onedrive/releases) or built from master.
2.  Fill in a new bug report using the [issue template](https://github.com/abraunegg/onedrive/issues/new?template=bug_report.md)
3.  Generate a debug log for support using the following [process](https://github.com/abraunegg/onedrive/wiki/Generate-debug-log-for-support)
    *   If you are in *any* way concerned regarding the sensitivity of the data contained with in the verbose debug log file, create a new OneDrive account, configure the client to use that, use *dummy* data to simulate your environment and then replicate your original issue
    *   If you are still concerned, provide an NDA or confidentiality document to sign
4.  Upload the debug log to [pastebin](https://pastebin.com/) or archive and email to support@mynas.com.au
    *   If you are concerned regarding the sensitivity of your debug data, encrypt + password protect the archive file and provide the decryption password via an out-of-band (OOB) mechanism. Email support@mynas.com.au for an OOB method for the password to be sent.
    *   If you are still concerned, provide an NDA or confidentiality document to sign

## Known issues
Refer to [docs/known-issues.md](https://github.com/abraunegg/onedrive/blob/master/docs/known-issues.md)

## Documentation and Configuration Assistance
### Installing from Distribution Packages or Building the OneDrive Client for Linux from source
Refer to [docs/INSTALL.md](https://github.com/abraunegg/onedrive/blob/master/docs/INSTALL.md)

### Configuration and Usage
Refer to [docs/USAGE.md](https://github.com/abraunegg/onedrive/blob/master/docs/USAGE.md)

### Configure OneDrive Business Shared Folders
Refer to [docs/BusinessSharedFolders.md](https://github.com/abraunegg/onedrive/blob/master/docs/BusinessSharedFolders.md)

### Configure SharePoint / Office 365 Shared Libraries (Business or Education)
Refer to [docs/SharePoint-Shared-Libraries.md](https://github.com/abraunegg/onedrive/blob/master/docs/SharePoint-Shared-Libraries.md)

### Configure National Cloud support
Refer to [docs/national-cloud-deployments.md](https://github.com/abraunegg/onedrive/blob/master/docs/national-cloud-deployments.md)

### Docker support
Refer to [docs/Docker.md](https://github.com/abraunegg/onedrive/blob/master/docs/Docker.md)

### Podman support
Refer to [docs/Podman.md](https://github.com/abraunegg/onedrive/blob/master/docs/Podman.md)

