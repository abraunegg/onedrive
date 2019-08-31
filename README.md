# OneDrive Free Client
[![Version](https://img.shields.io/github/v/release/abraunegg/onedrive)](https://github.com/abraunegg/onedrive/releases)
[![Release Date](https://img.shields.io/github/release-date/abraunegg/onedrive)](https://github.com/abraunegg/onedrive/releases)
[![Travis CI](https://img.shields.io/travis/com/abraunegg/onedrive)](https://travis-ci.com/abraunegg/onedrive/builds)
[![Docker Build](https://img.shields.io/docker/automated/driveone/onedrive)](https://hub.docker.com/r/driveone/onedrive)
[![Docker Pulls](https://img.shields.io/docker/pulls/driveone/onedrive)](https://hub.docker.com/r/driveone/onedrive)

A complete tool to interact with OneDrive on Linux. Built following the UNIX philosophy

## Features
*   State caching
*   Real-Time file monitoring with Inotify
*   File upload / download validation to ensure data integrity
*   Resumable uploads
*   Support OneDrive for Business (part of Office 365)
*   Shared folders (OneDrive Personal)
*   SharePoint / Office 365 Shared Libraries (refer to README.Office365.md to configure)
*   Desktop notifications via libnotify

## What's missing
*   While local changes are uploaded right away, remote changes are delayed
*   No GUI

## Building and Installation
See [docs/INSTALL.md](docs/INSTALL.md)

## Configuration and Usage
See [docs/USAGE.md](docs/USAGE.md)

## Docker support
See [docs/Docker.md](docs/Docker.md)

## Sharepoint group drive in Office 365 business or education
See [docs/Office365.md](docs/Office365.md)

## Reporting issues
If you encounter any bugs you can report them here on Github. Before filing an issue be sure to:

1.  Check the version of the application you are using `onedrive --version` and ensure that you are running either the latest [release](https://github.com/abraunegg/onedrive/releases) or built from master.
2.  Fill in a new bug report using the [issue template](https://github.com/abraunegg/onedrive/issues/new?template=bug_report.md)
3.  Generate a debug log for support using the following [process](https://github.com/abraunegg/onedrive/wiki/Generate-debug-log-for-support)
4.  Upload the debug log to [pastebin](https://pastebin.com/) or archive and email to support@mynas.com.au
