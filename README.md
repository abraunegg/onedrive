# OneDrive Client for Linux
[![Version](https://img.shields.io/github/v/release/abraunegg/onedrive)](https://github.com/abraunegg/onedrive/releases)
[![Release Date](https://img.shields.io/github/release-date/abraunegg/onedrive)](https://github.com/abraunegg/onedrive/releases)
[![Travis CI](https://img.shields.io/travis/com/abraunegg/onedrive)](https://travis-ci.com/abraunegg/onedrive/builds)
[![Docker Build](https://img.shields.io/docker/cloud/automated/driveone/onedrive)](https://hub.docker.com/r/driveone/onedrive)
[![Docker Pulls](https://img.shields.io/docker/pulls/driveone/onedrive)](https://hub.docker.com/r/driveone/onedrive)

A free Microsoft OneDrive Client which supports OneDrive Personal, OneDrive for Business, OneDrive for Office365 and Sharepoint.

This powerful and highly configurable client can run on all major Linux distributions, as a Docker container and on FreeBSD. It supports one-way and two-way sync capabilities and securely connects to Microsoft OneDrive services.

This client is a 'fork' of the [skilion](https://github.com/skilion/onedrive) client which was abandoned in 2018.

## Features
*   State caching
*   Real-Time file monitoring with Inotify
*   File upload / download validation to ensure data integrity
*   Resumable uploads
*   Support OneDrive for Business (part of Office 365)
*   Shared Folder support for OneDrive Personal and OneDrive Business accounts
*   SharePoint / Office365 Shared Libraries
*   Desktop notifications via libnotify
*   Dry-run capability to test configuration changes
*   Prevent major OneDrive accidental data deletion after configuration change
*   Support for National cloud deployments (Microsoft Cloud for US Government, Microsoft Cloud Germany, Azure and Office 365 operated by 21Vianet in China)

## What's missing
*   While local changes are uploaded right away, remote changes are delayed until next sync when using --monitor
*   No GUI

## Building and Installation
See [docs/INSTALL.md](https://github.com/abraunegg/onedrive/blob/master/docs/INSTALL.md)

## Configuration and Usage
See [docs/USAGE.md](https://github.com/abraunegg/onedrive/blob/master/docs/USAGE.md)

## Docker support
See [docs/Docker.md](https://github.com/abraunegg/onedrive/blob/master/docs/Docker.md)

## OneDrive Business Shared Folders
See [docs/BusinessSharedFolders.md](https://github.com/abraunegg/onedrive/blob/master/docs/BusinessSharedFolders.md)

## SharePoint / Office 365 Shared Libraries (Business or Education)
See [docs/Office365.md](https://github.com/abraunegg/onedrive/blob/master/docs/Office365.md)

## National Cloud support
See [docs/national-cloud-deployments.md](https://github.com/abraunegg/onedrive/blob/master/docs/national-cloud-deployments.md)

## Reporting issues
If you encounter any bugs you can report them here on Github. Before filing an issue be sure to:

1.  Check the version of the application you are using `onedrive --version` and ensure that you are running either the latest [release](https://github.com/abraunegg/onedrive/releases) or built from master.
2.  Fill in a new bug report using the [issue template](https://github.com/abraunegg/onedrive/issues/new?template=bug_report.md)
3.  Generate a debug log for support using the following [process](https://github.com/abraunegg/onedrive/wiki/Generate-debug-log-for-support)
4.  Upload the debug log to [pastebin](https://pastebin.com/) or archive and email to support@mynas.com.au

## Known issues
See [docs/known-issues.md](https://github.com/abraunegg/onedrive/blob/master/docs/known-issues.md)
