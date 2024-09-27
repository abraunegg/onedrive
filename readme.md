# OneDrive Client for Linux
[![Version](https://img.shields.io/github/v/release/abraunegg/onedrive)](https://github.com/abraunegg/onedrive/releases)
[![Release Date](https://img.shields.io/github/release-date/abraunegg/onedrive)](https://github.com/abraunegg/onedrive/releases)
[![Test Build](https://github.com/abraunegg/onedrive/actions/workflows/testbuild.yaml/badge.svg)](https://github.com/abraunegg/onedrive/actions/workflows/testbuild.yaml)
[![Build Docker Images](https://github.com/abraunegg/onedrive/actions/workflows/docker.yaml/badge.svg)](https://github.com/abraunegg/onedrive/actions/workflows/docker.yaml)
[![Docker Pulls](https://img.shields.io/docker/pulls/driveone/onedrive)](https://hub.docker.com/r/driveone/onedrive)

Introducing a free Microsoft OneDrive Client that seamlessly supports OneDrive Personal, OneDrive for Business, OneDrive for Office365, and SharePoint Libraries.

This robust and highly customisable client is compatible with all major Linux distributions and FreeBSD, and can also be deployed as a container using Docker or Podman. It offers both one-way and two-way synchronisation capabilities while ensuring a secure connection to Microsoft OneDrive services.

Originally derived as a 'fork' from the [skilion](https://github.com/skilion/onedrive) client, it's worth noting that the developer of the original client has explicitly stated they have no intention of maintaining or supporting their work ([reference](https://github.com/skilion/onedrive/issues/518#issuecomment-717604726)).

This client represents a 100% re-imagining of the original work, addressing numerous notable bugs and issues while incorporating a significant array of new features. This client has been under active development since mid-2018.

## Features
*   Compatible with OneDrive Personal, OneDrive for Business including accessing Microsoft SharePoint Libraries
*   Provides rules for client-side filtering to select data for syncing with Microsoft OneDrive accounts
*   Caches sync state for efficiency
*   Supports a dry-run option for safe configuration testing
*   Validates file transfers to ensure data integrity
*   Monitors local files in real-time using inotify
*   Supports interrupted uploads for completion at a later time
*   Capability to sync remote updates immediately via webhooks
*   Enhanced synchronisation speed with multi-threaded file transfers
*   Manages traffic bandwidth use with rate limiting
*   Supports seamless access to shared folders and files across both OneDrive Personal and OneDrive for Business accounts
*   Supports national cloud deployments including Microsoft Cloud for US Government, Microsoft Cloud Germany and Azure and Office 365 operated by VNET in China
*   Supports sending desktop alerts using libnotify
*   Protects against significant data loss on OneDrive after configuration changes
*   Works with both single and multi-tenant applications

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
1.  Check the version of the application you are using `onedrive --version` and ensure that you are running either the latest [release](https://github.com/abraunegg/onedrive/releases) or built from master.
2.  Configure the application to only use IPv4 network connectivity, and then retest. 
3.  Configure the application to only use HTTP/1.1. operations with IPv4 network connectivity, and then retest.
4.  If the above points do not resolve your issue, upgrade your 'curl' version to the latest available by the curl developers. Refer to https://curl.se/docs/releases.html for details.

## Reporting an Issue or Bug
> [!IMPORTANT]
> Please ensure that issues reported as bugs are indeed software bugs. For installation problems, distribution package/version issues, or package dependency concerns, please start a [Discussion](https://github.com/abraunegg/onedrive/discussions) instead of filing a bug report.

If you encounter any bugs you can report them here on Github. Before filing an issue be sure to:

1.  Fill in a new bug report using the [issue template](https://github.com/abraunegg/onedrive/issues/new?template=bug_report.md)
2.  Generate a debug log for support using the following [process](https://github.com/abraunegg/onedrive/wiki/Generate-debug-log-for-support)
    *   If you are in *any* way concerned regarding the sensitivity of the data contained with in the verbose debug log file, create a new OneDrive account, configure the client to use that, use *dummy* data to simulate your environment and then replicate your original issue
    *   If you are still concerned, provide an NDA or confidentiality document to sign
3.  Upload the debug log to [pastebin](https://pastebin.com/) or archive and email to support@mynas.com.au
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

