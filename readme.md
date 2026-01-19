# OneDrive Client for Linux 
[![Version](https://img.shields.io/github/v/release/abraunegg/onedrive)](https://github.com/abraunegg/onedrive/releases)
[![Release Date](https://img.shields.io/github/release-date/abraunegg/onedrive)](https://github.com/abraunegg/onedrive/releases)
[![Test Build](https://github.com/abraunegg/onedrive/actions/workflows/testbuild.yaml/badge.svg)](https://github.com/abraunegg/onedrive/actions/workflows/testbuild.yaml)
[![Build Docker Images](https://github.com/abraunegg/onedrive/actions/workflows/docker.yaml/badge.svg)](https://github.com/abraunegg/onedrive/actions/workflows/docker.yaml)
[![Docker Pulls](https://img.shields.io/docker/pulls/driveone/onedrive)](https://hub.docker.com/r/driveone/onedrive)

A fully featured, free, and actively maintained Microsoft OneDrive client that seamlessly supports OneDrive Personal, OneDrive for Business, Microsoft 365 (formerly Office 365), and SharePoint document libraries.

Designed for maximum flexibility and reliability, this powerful and highly configurable client works across all major Linux distributions and FreeBSD. It can also be deployed in containerised environments using Docker or Podman. Supporting both one-way and two-way synchronisation modes, the client provides secure and efficient file syncing with Microsoft OneDrive services — tailored to suit both desktop and server environments.


## Project Background
This project originated as a fork of the skilion client in early 2018, after a number of proposed improvements and bug fixes — including [Pull Requests #82 and #314](https://github.com/skilion/onedrive/pulls?q=author%3Aabraunegg) — were not merged and development activity of the skilion client had largely stalled. While it’s unclear whether the original developer was unavailable or had stepped away from the project - bug reports and feature requests remained unanswered for extended periods. In 2020, the original developer (skilion) confirmed they had no intention of maintaining or supporting their work ([reference](https://github.com/skilion/onedrive/issues/518#issuecomment-717604726)).

The original [skilion repository](https://github.com/skilion/onedrive) was formally archived and made read-only on GitHub in December 2024. While still publicly accessible as a historical reference, an archived repository is no longer maintained, cannot accept contributions, and reflects a frozen snapshot of the codebase. The last code change to the skilion client was merged in November 2021; however, active development had slowed significantly well before then. As such, the skilion client should no longer be considered current or supported — particularly given the major API changes and evolving Microsoft OneDrive platform requirements since that time.

Under the terms of the GNU General Public License (GPL), forking and continuing development of open source software is fully permitted — provided that derivative works retain the same license. This client complies with the original GPLv3 licensing, ensuring the same freedoms granted by the original project remain intact.

Since forking in early 2018, this client has evolved into a clean re-imagining of the original codebase, resolving long-standing bugs and adding extensive new functionality to better support both personal and enterprise use cases to interact with Microsoft OneDrive from Linux and FreeBSD platforms.


## Features

### Broad Microsoft OneDrive Compatibility

* Works with OneDrive Personal, OneDrive for Business, and Microsoft SharePoint Libraries.
* Full support for shared folders and files across both Personal and Business accounts.
* Supports single-tenant and multi-tenant Microsoft Entra ID environments.
* Compatible with national cloud deployments:
  * Microsoft Cloud for US Government
  * Microsoft Cloud Germany
  * Azure/Office 365 operated by VNET in China

### Flexible Synchronisation Modes

* Bi-directional sync (default) - keeps local and remote data fully aligned.
* Upload-only mode - only uploads local changes; does not download remote changes.
* Download-only mode - only downloads remote changes; does not upload local changes.
* Dry-run mode - test configuration changes safely without modifying files.
* Safe conflict handling minimises data loss by creating local backups whenever this is determined to be the safest conflict-resolution strategy.

### Client-Side Filtering & Granular Sync Control

* Comprehensive rules-based client-side filtering (inclusions, exclusions, wildcard `*`, globbing `**`).
* Filter specific files, folders, or patterns to tailor precisely what is synced with Microsoft OneDrive.
* Efficient cached sync state for fast decision-making during large or complex sync sets.

### Real-Time Monitoring & Online Change Detection

* Near real-time processing of cloud-side changes using native WebSocket support.
* Webhook support for environments where WebSockets are unsuitable (manual setup).
* Real-time local change monitoring via inotify.

### Data Safety, Recovery & Integrity Protection

* Implements the FreeDesktop.org Trash specification, enabling recovery of items deleted locally due to online deletion.
* Strong safeguards to prevent accidental remote deletion or overwrite after configuration changes.
* Interruption-tolerant uploads and downloads, automatically resuming transfers.
* Integrity validation for every file transferred.

### Modern Authentication Support

* Standard OAuth2 Native Client Authorisation Flow (default), supporting browser-based login, multi-factor authentication (MFA), and modern Microsoft account security requirements.
* OAuth2 Device Authorisation Flow for Microsoft Entra ID accounts, ideal for headless systems, servers, and terminal-only environments.
* Intune Single Sign-On (SSO) using the Microsoft Identity Device Broker (IDB) via D-Bus, enabling seamless enterprise authentication without manual credential entry.

### Performance, Efficiency & Resource Management

* Multi-threaded file transfers for significantly improved sync speeds.
* Bandwidth rate limiting to control network consumption.
* Highly efficient processing with state caching, reducing API traffic and improving performance.

### Desktop Integration & User Experience

* libnotify desktop notifications for sync events, warnings, and errors.
* Registers the OneDrive folder as a sidebar location in supported file managers, complete with a distinctive icon.
* Works seamlessly in GUI and headless/server environments. A GUI is only required for Intune SSO, notifications, and sidebar integration; all other features function without graphical support.


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

## Documentation and Configuration Assistance
OneDrive Client for Linux includes a rich set of documentation covering installation, configuration options, advanced usage, and integrations. These resources are designed to help new users get started quickly and to give experienced users full control over advanced behaviour. If you are changing configuration, running in production, or using Business/SharePoint features, you should be reading these documents. All documentation is maintained in the [`docs/`](https://github.com/abraunegg/onedrive/tree/master/docs) directory of this repository.

### Getting Started

#### Installation
Learn how to install the client on various systems — from distribution packages to building from source. Please read the [Install Guide](https://github.com/abraunegg/onedrive/blob/master/docs/install.md)

#### Basic Usage & Configuration
Covers initial authentication, default settings, basic operational instructions, frequently asked 'how to' questions, and how to tailor the application configuration. Please read the [Usage Guide](https://github.com/abraunegg/onedrive/blob/master/docs/usage.md)

### Advanced Configuration

#### Application Configuration Options
Full reference for every config option (with descriptions, defaults, and examples) to customise sync behaviour precisely. Please read the [Application Configuration Options Guide](https://github.com/abraunegg/onedrive/blob/master/docs/application-config-options.md)

#### Advanced Usage
Tips for creating multiple config profiles, custom sync rules, daemon setups, selective sync, dual-booting with Microsoft Windows and more. Please read the [Advanced Usage Guide](https://github.com/abraunegg/onedrive/blob/master/docs/advanced-usage.md)

### Special Use Cases

#### Business Shared Items
Configuring sync for OneDrive Business shared items (files and folders). Please read the [Business Shared Items Guide](https://github.com/abraunegg/onedrive/blob/master/docs/business-shared-items.md)

#### SharePoint & Office 365 Libraries
Instructions for syncing SharePoint document libraries (Business or Education tenants). Please read the [SharePoint Library Guide](https://github.com/abraunegg/onedrive/blob/master/docs/sharepoint-libraries.md)

#### National Cloud support
Instructions for environments like Microsoft Cloud Germany or US Government cloud endpoints. Please read the [National Cloud Deployment Guide](https://github.com/abraunegg/onedrive/blob/master/docs/national-cloud-deployments.md)

### Container Support

#### Docker
How to run the OneDrive client in a Docker container. Please read the [Docker Guide](https://github.com/abraunegg/onedrive/blob/master/docs/docker.md)

#### Podman
How to run the OneDrive client with Podman. Please read the [Podman Guide](https://github.com/abraunegg/onedrive/blob/master/docs/podman.md)


## Basic Troubleshooting Steps

If you encounter any issues running the application, please follow these steps **before** raising a bug report:

1. **Check the application version**  
   Run `onedrive --version` to confirm which version you are using.  
   - Ensure you are running the latest [release](https://github.com/abraunegg/onedrive/releases).  
   - If you are already on the latest release but still experiencing issues, manually build the client from the `master` branch to test against the very latest code. This includes fixes for bugs discovered since the last tagged release.

2. **Run in verbose mode**  
   Use the `--verbose` option to provide greater clarity and detailed logging about the issue you are facing.

3. **Test with IPv4 only**  
   Configure the application to use **IPv4 network connectivity only**, then retest. See the `'ip_protocol_version'` option [documentation](https://github.com/abraunegg/onedrive/blob/master/docs/application-config-options.md#ip_protocol_version) for assistance.

4. **Test with HTTP/1.1 and IPv4**  
   Configure the application to use **HTTP/1.1 over IPv4 only**, then retest. See the `'force_http_11'` option [documentation](https://github.com/abraunegg/onedrive/blob/master/docs/application-config-options.md#force_http_11) for assistance.

5. **Verify cURL and libcurl versions**  
   If the above steps do not resolve your issue, upgrade both `curl` and `libcurl` to the latest versions provided by the curl developers.  
   - See [Compatibility with curl](https://github.com/abraunegg/onedrive/blob/master/docs/usage.md#compatibility-with-curl) for details on curl bugs that impact this client.  
   - Refer to the official [cURL Releases](https://curl.se/docs/releases.html) page for version information.

6. **Open a new issue**  
   If the problem persists after completing the steps above, proceed to **Reporting an Issue or Bug** below and open a new issue with the requested details and logs.



## Reporting an Issue or Bug

> [!IMPORTANT]
> Please ensure the problem is a software bug. For installation issues, distribution package/version questions, or dependency problems, start a [Discussion](https://github.com/abraunegg/onedrive/discussions) instead of filing a bug report.

If you encounter a bug, you can report it on GitHub. Before opening a new issue report:

1. **Complete the Basic Troubleshooting Steps**  
   Confirm you’ve run through all steps in the section above.

2. **Search existing issues**  
   Check both [Open](https://github.com/abraunegg/onedrive/issues) and [Closed](https://github.com/abraunegg/onedrive/issues?q=is%3Aissue%20state%3Aclosed) issues for a similar problem to avoid duplicates.

3. **Use the issue template**  
   Open a new bug report using the [issue template](https://github.com/abraunegg/onedrive/issues/new?template=bug_report.md) and fill in **all fields**. Complete detail helps us reproduce your environment and replicate the issue.

4. **Generate a debug log**  
   Follow this [process](https://github.com/abraunegg/onedrive/wiki/Generate-debug-log-for-support) to create a debug log.

   - If you are concerned about personal or business sensitive data in the debug log, you may:
     - Create a new OneDrive account, configure the client to use it, use **dummy** data to simulate your environment, and reproduce the issue; or
     - Provide an NDA or confidentiality agreement for signature prior to sharing sensitive logs.

5. **Share the debug log securely**
   - **Do not post debug logs publicly.** Debug logs can include sensitive details (file paths, filenames, API endpoints, environment info, etc.).
   - **Send the log via email** to **support@mynas.com.au** using a trusted email account.
   - **Archive and password-protect** the log before sending (e.g. `.zip` with AES or `.7z`):
     - Example (zip with password): `zip -e onedrive-debug.zip onedrive-debug.log`
     - Example (7z with password): `7z a -p onedrive-debug.7z onedrive-debug.log`
   - **Send the password out-of-band (OOB)** — not in the same email as the archive. Email **support@mynas.com.au** to arrange an OOB method (e.g. separate email thread, phone/SMS, or agreed channel).
   - **If you require an NDA**, attach your NDA or confidentiality agreement to your email. It will be reviewed and signed prior to exchanging sensitive data.


### What to include in your bug report
When raising a new bug report, please include **all details requested in the issue template**, such as:

- A clear description of the problem and how to reproduce it  
- Your operating system and installation method  
- OneDrive account type and client version  
- Application configuration and cURL version  
- Sync directory location, system mount points, and partition types  
- A full debug log, shared securely as described above  

Providing complete information makes it much easier to understand, reproduce, and resolve your issue quickly.  

> [!NOTE]  
> Submitting a bug report starts a collaboration. To help us help you, please:  
> - Stay available to answer questions or provide clarifications if needed  
> - Test and confirm fixes in your own environment when a pull request (PR) is created for your issue  

> [!TIP]  
> Reports with missing details are much harder to investigate. Sharing as much as you can up front gives the best chance of a fast and accurate fix.

## Known issues
Lists common limitations, known problems, diagnostics, and workarounds. Please read the [Known Issues Advice](https://github.com/abraunegg/onedrive/blob/master/docs/known-issues.md)

