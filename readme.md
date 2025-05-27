# OneDrive Client for Linux
[![Version](https://img.shields.io/github/v/release/abraunegg/onedrive)](https://github.com/abraunegg/onedrive/releases)
[![Release Date](https://img.shields.io/github/release-date/abraunegg/onedrive)](https://github.com/abraunegg/onedrive/releases)
[![Test Build](https://github.com/abraunegg/onedrive/actions/workflows/testbuild.yaml/badge.svg)](https://github.com/abraunegg/onedrive/actions/workflows/testbuild.yaml)
[![Build Docker Images](https://github.com/abraunegg/onedrive/actions/workflows/docker.yaml/badge.svg)](https://github.com/abraunegg/onedrive/actions/workflows/docker.yaml)
[![Docker Pulls](https://img.shields.io/docker/pulls/driveone/onedrive)](https://hub.docker.com/r/driveone/onedrive)

A fully featured, free, and actively maintained Microsoft OneDrive client that seamlessly supports OneDrive Personal, OneDrive for Business, Microsoft 365 (formerly Office 365), and SharePoint document libraries.

Designed for maximum flexibility and reliability, this powerful and highly configurable client works across all major Linux distributions and FreeBSD. It can also be deployed in containerised environments using Docker or Podman. Supporting both one-way and two-way synchronisation modes, the client provides secure and efficient file syncing with Microsoft OneDrive services — tailored to suit both desktop and server environments.


## Project Background
This project originated as a fork of the skilion client in early 2018, after a number of proposed improvements and bug fixes — including [Pull Requests #82 and #314](https://github.com/skilion/onedrive/pulls?q=author%3Aabraunegg) — were not merged and development activity had largely stalled. While it’s unclear whether the original developer was unavailable or had stepped away from the project, bug reports and feature requests remained unanswered for extended periods. In 2020, the developer confirmed they had no intention of maintaining or supporting their work ([reference](https://github.com/skilion/onedrive/issues/518#issuecomment-717604726)).

The original [skilion repository](https://github.com/skilion/onedrive) was formally archived and made read-only on GitHub in December 2024. While still publicly accessible as a historical reference, an archived repository is no longer maintained, cannot accept contributions, and reflects a frozen snapshot of the codebase. The last code change was merged in November 2021; however, active development had slowed significantly well before then. As such, the skilion client should no longer be considered current or supported — particularly given the major API changes and evolving platform requirements since that time.

Under the terms of the GNU General Public License (GPL), forking and continuing development of open source software is fully permitted — provided that derivative works retain the same license. This client complies with the original GPLv3 licensing, ensuring the same freedoms granted by the original project remain intact.

Since forking, the client has evolved into a clean re-imagining of the original codebase, resolving long-standing bugs and adding extensive new functionality to better support both personal and enterprise use cases.


## Features
* Compatible with OneDrive Personal and OneDrive for Business, including access to Microsoft SharePoint Libraries
* Supports seamless access to shared folders and files across both OneDrive Personal and OneDrive for Business accounts
* Supports single-tenant and multi-tenant applications
* Supports Intune Single Sign-On (SSO) authentication via the Microsoft Identity Device Broker (D-Bus interface)
* Supports national cloud deployments including Microsoft Cloud for US Government, Microsoft Cloud Germany, and Azure/Office 365 operated by VNET in China
* Provides rules for client-side filtering to select data for syncing with Microsoft OneDrive accounts
* Protects against significant data loss on OneDrive after configuration changes
* Supports a dry-run option for safe configuration testing
* Validates file transfers to ensure data integrity
* Caches sync state for efficiency
* Monitors local files in real-time using inotify
* Capability to sync remote updates immediately via webhooks
* Supports interrupted uploads for completion at a later time
* Enhanced synchronisation speed with multi-threaded file transfers
* Manages traffic bandwidth use with rate limiting
* Supports sending desktop alerts using libnotify


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
If you have a question or need something clarified, please raise a new discussion post [here](https://github.com/abraunegg/onedrive/discussions)

## Supported Application Version
Support is only provided for the current application release version or newer 'master' branch versions.

The current release version is: [![Version](https://img.shields.io/github/v/release/abraunegg/onedrive)](https://github.com/abraunegg/onedrive/releases)

To check your version, run: `onedrive --version`. Ensure you are using the current release or compile the latest version from the master branch if needed.

If you are using an older version, you must upgrade to the current release or newer to receive support.

## Basic Troubleshooting Steps
If you are encountering any issue running the application please follow these steps first:
1.  Check the version of the application using `onedrive --version` and ensure that you are running the latest [release](https://github.com/abraunegg/onedrive/releases). If you are already using the latest release and are still experiencing an issue, you must manually build the client from 'master' to ensure you are running the latest code, which will include fixes for bugs found since the last release that may be impacting you.
2.  Configure the application to only use IPv4 network connectivity, and then retest. 
3.  Configure the application to only use HTTP/1.1. operations with IPv4 network connectivity, and then retest.
4.  If the above points do not resolve your issue, upgrade your 'curl' version to the latest available by the curl developers. Refer to https://curl.se/docs/releases.html for details.

## Reporting an Issue or Bug
> [!IMPORTANT]
> Please ensure that issues reported as bugs are indeed software bugs. For installation problems, distribution package/version issues, or package dependency concerns, please start a [Discussion](https://github.com/abraunegg/onedrive/discussions) instead of filing a bug report.

If you encounter any bugs you can report them here on Github. Before filing an issue be sure to:

1. Follow the Basic Troubleshooting Steps
2.  Fill in a new bug report using the [issue template](https://github.com/abraunegg/onedrive/issues/new?template=bug_report.md) after following the Basic Troubleshooting Steps. Fill in *all* the details as this helps re-create your environment to replicate your issue.
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
Refer to [docs/install.md](https://github.com/abraunegg/onedrive/blob/master/docs/install.md)

### Configuration and Usage
Refer to [docs/usage.md](https://github.com/abraunegg/onedrive/blob/master/docs/usage.md)

### Configure OneDrive Business Shared Items
Refer to [docs/business-shared-items.md](https://github.com/abraunegg/onedrive/blob/master/docs/business-shared-items.md)

### Configure SharePoint / Office 365 Shared Libraries (Business or Education)
Refer to [docs/sharepoint-libraries.md](https://github.com/abraunegg/onedrive/blob/master/docs/sharepoint-libraries.md)

### Configure National Cloud support
Refer to [docs/national-cloud-deployments.md](https://github.com/abraunegg/onedrive/blob/master/docs/national-cloud-deployments.md)

### Docker support
Refer to [docs/docker.md](https://github.com/abraunegg/onedrive/blob/master/docs/docker.md)

### Podman support
Refer to [docs/podman.md](https://github.com/abraunegg/onedrive/blob/master/docs/podman.md)

