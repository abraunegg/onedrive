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
* Compatible with OneDrive Personal and OneDrive for Business, including access to Microsoft SharePoint Libraries
* Supports seamless access to shared folders and files across both OneDrive Personal and OneDrive for Business accounts
* Supports near real-time processing of online changes via either WebSockets (native support) or webhooks (manual configuration required)
* Supports single-tenant and multi-tenant applications
* Supports Intune Single Sign-On (SSO) authentication via the Microsoft Identity Device Broker (D-Bus interface)
* Supports OAuth2 Device Authorisation Flow for Microsoft Entra ID accounts
* Supports the FreeDesktop.org Trash specification, allowing locally deleted files to be safely recoverable in case of accidental online deletion
* Supports national cloud deployments including Microsoft Cloud for US Government, Microsoft Cloud Germany, and Azure/Office 365 operated by VNET in China
* Provides rules for client-side filtering to select data for syncing with Microsoft OneDrive accounts
* Protects against significant data loss on OneDrive after configuration changes
* Supports a dry-run option for safe configuration testing
* Supports interruption-tolerant uploads and downloads by resuming file transfers from the point of failure, ensuring data integrity and efficiency
* Validates file transfers to ensure data integrity
* Caches sync state for efficiency
* Monitors local files in real-time using inotify
* Enhanced synchronisation speed with multi-threaded file transfers
* Manages traffic bandwidth use with rate limiting
* Supports sending desktop alerts using libnotify
* Provides desktop file-manager integration by registering the OneDrive folder as a sidebar location with a distinctive icon.


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

