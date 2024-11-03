# Application Configuration Options for the OneDrive Client for Linux
## Application Version
Before reading this document, please ensure you are running application version [![Version](https://img.shields.io/github/v/release/abraunegg/onedrive)](https://github.com/abraunegg/onedrive/releases) or greater. Use `onedrive --version` to determine what application version you are using and upgrade your client if required.

## Table of Contents

- [Configuration File Options](#configuration-file-options)
  - [application_id](#application_id)
  - [azure_ad_endpoint](#azure_ad_endpoint)
  - [azure_tenant_id](#azure_tenant_id)
  - [bypass_data_preservation](#bypass_data_preservation)
  - [check_nomount](#check_nomount)
  - [check_nosync](#check_nosync)
  - [classify_as_big_delete](#classify_as_big_delete)
  - [cleanup_local_files](#cleanup_local_files)
  - [connect_timeout](#connect_timeout)
  - [data_timeout](#data_timeout)
  - [debug_https](#debug_https)
  - [disable_download_validation](#disable_download_validation)
  - [disable_notifications](#disable_notifications)
  - [disable_upload_validation](#disable_upload_validation)
  - [display_running_config](#display_running_config)
  - [dns_timeout](#dns_timeout)
  - [download_only](#download_only)
  - [drive_id](#drive_id)
  - [dry_run](#dry_run)
  - [enable_logging](#enable_logging)
  - [force_http_11](#force_http_11)
  - [ip_protocol_version](#ip_protocol_version)
  - [local_first](#local_first)
  - [log_dir](#log_dir)
  - [max_curl_idle](#max_curl_idle)
  - [monitor_fullscan_frequency](#monitor_fullscan_frequency)
  - [monitor_interval](#monitor_interval)
  - [monitor_log_frequency](#monitor_log_frequency)
  - [no_remote_delete](#no_remote_delete)
  - [notify_file_actions](#notify_file_actions)
  - [operation_timeout](#operation_timeout)
  - [rate_limit](#rate_limit)
  - [read_only_auth_scope](#read_only_auth_scope)
  - [remove_source_files](#remove_source_files)
  - [resync](#resync)
  - [resync_auth](#resync_auth)
  - [skip_dir](#skip_dir)
  - [skip_dir_strict_match](#skip_dir_strict_match)
  - [skip_dotfiles](#skip_dotfiles)
  - [skip_file](#skip_file)
  - [skip_size](#skip_size)
  - [skip_symlinks](#skip_symlinks)
  - [space_reservation](#space_reservation)
  - [sync_business_shared_items](#sync_business_shared_items)
  - [sync_dir](#sync_dir)
  - [sync_dir_permissions](#sync_dir_permissions)
  - [sync_file_permissions](#sync_file_permissions)
  - [sync_root_files](#sync_root_files)
  - [threads](#threads)
  - [upload_only](#upload_only)
  - [user_agent](#user_agent)
  - [webhook_enabled](#webhook_enabled)
  - [webhook_expiration_interval](#webhook_expiration_interval)
  - [webhook_listening_host](#webhook_listening_host)
  - [webhook_listening_port](#webhook_listening_port)
  - [webhook_public_url](#webhook_public_url)
  - [webhook_renewal_interval](#webhook_renewal_interval)
- [Command Line Interface (CLI) Only Options](#command-line-interface-cli-only-options)
  - [CLI Option: --auth-files](#cli-option---auth-files)
  - [CLI Option: --auth-response](#cli-option---auth-response)
  - [CLI Option: --confdir](#cli-option---confdir)
  - [CLI Option: --create-directory](#cli-option---create-directory)
  - [CLI Option: --create-share-link](#cli-option---create-share-link)
  - [CLI Option: --destination-directory](#cli-option---destination-directory)
  - [CLI Option: --display-config](#cli-option---display-config)
  - [CLI Option: --display-sync-status](#cli-option---display-sync-status)
  - [CLI Option: --display-quota](#cli-option---display-quota)
  - [CLI Option: --force](#cli-option---force)
  - [CLI Option: --force-sync](#cli-option---force-sync)
  - [CLI Option: --get-file-link](#cli-option---get-file-link)
  - [CLI Option: --get-sharepoint-drive-id](#cli-option---get-sharepoint-drive-id)
  - [CLI Option: --list-shared-items](#cli-option---list-shared-items)
  - [CLI Option: --logout](#cli-option---logout)
  - [CLI Option: --modified-by](#cli-option---modified-by)
  - [CLI Option: --monitor | -m](#cli-option---monitor--m)
  - [CLI Option: --print-access-token](#cli-option---print-access-token)
  - [CLI Option: --reauth](#cli-option---reauth)
  - [CLI Option: --remove-directory](#cli-option---remove-directory)
  - [CLI Option: --single-directory](#cli-option---single-directory)
  - [CLI Option: --source-directory](#cli-option---source-directory)
  - [CLI Option: --sync | -s](#cli-option---sync--s)
  - [CLI Option: --sync-shared-files](#cli-option---sync-shared-files)
  - [CLI Option: --verbose | -v+](#cli-option---verbose--v)
  - [CLI Option: --with-editing-perms](#cli-option---with-editing-perms)
- [Deprecated Configuration File and CLI Options](#deprecated-configuration-file-and-cli-options)
  - [force_http_2](#force_http_2)
  - [min_notify_changes](#min_notify_changes)
  - [CLI Option: --synchronize](#cli-option---synchronize)


## Configuration File Options

### application_id
_**Description:**_ This is the config option for application id that used to identify itself to Microsoft OneDrive. In some circumstances, it may be desirable to use your own application id. To do this, you must register a new application with Microsoft Azure via	https://portal.azure.com/, then use your new application id with this config option.

_**Value Type:**_ String

_**Default Value:**_ d50ca740-c83f-4d1b-b616-12c519384f0c

_**Config Example:**_ `application_id = "d50ca740-c83f-4d1b-b616-12c519384f0c"`

### azure_ad_endpoint
_**Description:**_ This is the config option to change the Microsoft Azure Authentication Endpoint that the client uses to conform with data and security requirements that requires data to reside within the geographic borders of that country.

_**Value Type:**_ String

_**Default Value:**_ *Empty* - not required for normal operation

_**Valid Values:**_ USL4, USL5, DE, CN

_**Config Example:**_ `azure_ad_endpoint = "DE"`

### azure_tenant_id
_**Description:**_ This config option allows the locking of the client to a specific single tenant and will configure your client to use the specified tenant id in its Azure AD and Graph endpoint URIs, instead of "common". The tenant id may be the GUID Directory ID or the fully qualified tenant name.

_**Value Type:**_ String

_**Default Value:**_ *Empty* - not required for normal operation

_**Config Example:**_ `azure_tenant_id = "example.onmicrosoft.us"` or `azure_tenant_id = "0c4be462-a1ab-499b-99e0-da08ce52a2cc"`

> [!IMPORTANT]
> Must be configured if 'azure_ad_endpoint' is configured.

### bypass_data_preservation
_**Description:**_ This config option allows the disabling of preserving local data by renaming the local file in the event of data conflict. If this is enabled, you will experience data loss on your local data as the local file will be over-written with data from OneDrive online. Use with care and caution.

_**Value Type:**_ Boolean

_**Default Value:**_ False

_**Config Example:**_ `bypass_data_preservation = "false"` or `bypass_data_preservation = "true"`

### check_nomount
_**Description:**_ This config option is useful to prevent application startup & ongoing use in 'Monitor Mode' if the configured 'sync_dir' is a separate disk that is being mounted by your system. This option will check for the presence of a `.nosync` file in your mount point, and if present, abort any sync process to preserve data.

_**Value Type:**_ Boolean

_**Default Value:**_ False

_**Config Example:**_ `check_nomount = "false"` or `check_nomount = "true"`

_**CLI Option:**_ `--check-for-nomount`

> [!TIP]
> Create a `.nosync` file in your mount point *before* you mount your disk so that this `.nosync` file visible, in your mount point if your disk is unmounted at any point to preserve your data when you enable this option.

### check_nosync
_**Description:**_ This config option is useful to prevent the sync of a *local* directory to Microsoft OneDrive. It will *not* check for this file online to prevent the download of directories to your local system.

_**Value Type:**_ Boolean

_**Default Value:**_ False

_**Config Example:**_ `check_nosync = "false"` or `check_nosync = "true"`

_**CLI Option Use:**_ `--check-for-nosync`

> [!IMPORTANT]
> Create a `.nosync` file in any *local* directory that you wish to not sync to Microsoft OneDrive when you enable this option.

### classify_as_big_delete
_**Description:**_ This config option defines the number of children in a path that is locally removed which will be classified as a 'big data delete' to safeguard large data removals - which are typically accidental local delete events.

_**Value Type:**_ Integer

_**Default Value:**_ 1000

_**Config Example:**_ `classify_as_big_delete = "2000"`

_**CLI Option Use:**_ `--classify-as-big-delete 2000`

> [!NOTE]
> If this option is triggered, you will need to add `--force` to force a sync to occur.

### cleanup_local_files
_**Description:**_ This config option provides the capability to cleanup local files and folders if they are removed online.

_**Value Type:**_ Boolean

_**Default Value:**_ False

_**Config Example:**_ `cleanup_local_files = "false"` or `cleanup_local_files = "true"`

_**CLI Option Use:**_ `--cleanup-local-files`

> [!IMPORTANT]
> This configuration option can only be used with `--download-only`. It cannot be used with any other application option.

### connect_timeout
_**Description:**_ This configuration setting manages the TCP connection timeout duration in seconds for HTTPS connections to Microsoft OneDrive when using the curl library (CURLOPT_CONNECTTIMEOUT).

_**Value Type:**_ Integer

_**Default Value:**_ 10

_**Config Example:**_ `connect_timeout = "15"`

### data_timeout
_**Description:**_ This setting controls the timeout duration, in seconds, for when data is not received on an active connection to Microsoft OneDrive over HTTPS when using the curl library, before that connection is timeout out.

_**Value Type:**_ Integer

_**Default Value:**_ 60

_**Config Example:**_ `data_timeout = "300"`

### debug_https
_**Description:**_ This setting controls whether the curl library is configured to output additional data to assist with diagnosing HTTPS issues and problems.

_**Value Type:**_ Boolean

_**Default Value:**_ False

_**Config Example:**_ `debug_https = "false"` or `debug_https = "true"`

_**CLI Option Use:**_ `--debug-https`

> [!WARNING]
> Whilst this option can be used at any time, it is advisable that you only use this option when advised as this will output your `Authorization: bearer` - which is your authentication token to Microsoft OneDrive.

### disable_download_validation
_**Description:**_ This option determines whether the client will conduct integrity validation on files downloaded from Microsoft OneDrive. Sometimes, when downloading files, particularly from SharePoint, there is a discrepancy between the file size reported by the OneDrive API and the byte count received from the SharePoint HTTP Server for the same file. Enable this option to disable the integrity checks performed by this client.

_**Value Type:**_ Boolean

_**Default Value:**_ False

_**Config Example:**_ `disable_download_validation = "false"` or `disable_download_validation = "true"`

_**CLI Option Use:**_ `--disable-download-validation`

> [!CAUTION]
> If you're downloading data from SharePoint or OneDrive Business Shared Folders, you might find it necessary to activate this option. It's important to note that any issues encountered aren't due to a problem with this client; instead, they should be regarded as issues with the Microsoft OneDrive technology stack. Enabling this option disables all download integrity checks.

### disable_notifications
_**Description:**_ This setting controls whether GUI notifications are sent from the client to your display manager session. 

_**Value Type:**_ Boolean

_**Default Value:**_ False

_**Config Example:**_ `disable_notifications = "false"` or `disable_notifications = "true"`

_**CLI Option Use:**_ `--disable-notifications`

### disable_upload_validation
_**Description:**_ This option determines whether the client will conduct integrity validation on files uploaded to Microsoft OneDrive. Sometimes, when uploading files, particularly to SharePoint, SharePoint will modify your file post upload by adding new data to your file which breaks the integrity checking of the upload performed by this client. Enable this option to disable the integrity checks performed by this client.

_**Value Type:**_ Boolean

_**Default Value:**_ False

_**Config Example:**_ `disable_upload_validation = "false"` or `disable_upload_validation = "true"`

_**CLI Option Use:**_ `--disable-upload-validation`

> [!CAUTION]
> If you're uploading data to SharePoint or OneDrive Business Shared Folders, you might find it necessary to activate this option. It's important to note that any issues encountered aren't due to a problem with this client; instead, they should be regarded as issues with the Microsoft OneDrive technology stack. Enabling this option disables all upload integrity checks.

### display_running_config
_**Description:**_ This option will include the running config of the application at application startup. This may be desirable to enable when running in containerised environments so that any application logging that is occurring, will have the application configuration being consumed at startup, written out to any applicable log file.

_**Value Type:**_ Boolean

_**Default Value:**_ False

_**Config Example:**_ `display_running_config = "false"` or `display_running_config = "true"`

_**CLI Option Use:**_ `--display-running-config`

### dns_timeout
_**Description:**_ This setting controls the libcurl DNS cache value. By default, libcurl caches this info for 60 seconds. This libcurl DNS cache timeout is entirely speculative that a name resolves to the same address for a small amount of time into the future as libcurl does not use DNS TTL properties. We recommend users not to tamper with this option unless strictly necessary.

_**Value Type:**_ Integer

_**Default Value:**_ 60

_**Config Example:**_ `dns_timeout = "90"`

### download_only
_**Description:**_ This setting forces the client to only download data from Microsoft OneDrive and replicate that data locally. No changes made locally will be uploaded to Microsoft OneDrive when using this option.

_**Value Type:**_ Boolean

_**Default Value:**_ False

_**Config Example:**_ `download_only = "false"` or `download_only = "true"`

_**CLI Option Use:**_ `--download-only`

> [!IMPORTANT]
> When using this option, the default mode of operation is to not clean up local files that have been deleted online. This ensures that the local data is an *archive* of what was stored online. To cleanup local files use `--cleanup-local-files`.

### drive_id
_**Description:**_ This setting controls the specific drive identifier the client will use when syncing with Microsoft OneDrive.

_**Value Type:**_ String

_**Default Value:**_ *None*

_**Config Example:**_ `drive_id = "b!bO8V6s9SSk9R7mWhpIjUrotN73WlW3tEv3OxP_QfIdQimEdOHR-1So6CqeG1MfDB"`

> [!NOTE]
> This option is typically only used when configuring the client to sync a specific SharePoint Library. If this configuration option is specified in your config file, a value must be specified otherwise the application will exit citing a fatal error has occurred.

### dry_run
_**Description:**_ This setting controls the application capability to test your application configuration without actually performing any actual activity (download, upload, move, delete, folder creation).

_**Value Type:**_ Boolean

_**Default Value:**_ False

_**Config Example:**_ `dry_run = "false"` or `dry_run = "true"`

_**CLI Option Use:**_ `--dry-run`

### enable_logging
_**Description:**_ This setting controls the application logging all actions to a separate file. By default, all log files will be written to `/var/log/onedrive`, however this can changed by using the 'log_dir' config option

_**Value Type:**_ Boolean

_**Default Value:**_ False

_**Config Example:**_ `enable_logging = "false"` or `enable_logging = "true"`

_**CLI Option Use:**_ `--enable-logging`

> [!IMPORTANT]
> Additional configuration is potentially required to configure the default log directory. Refer to the [Enabling the Client Activity Log](./usage.md#enabling-the-client-activity-log) section in usage.md for details

### force_http_11
_**Description:**_ This setting controls the application HTTP protocol version. By default, the application will use libcurl defaults for which HTTP protocol version will be used to interact with Microsoft OneDrive. Use this setting to downgrade libcurl to only use HTTP/1.1.

_**Value Type:**_ Boolean

_**Default Value:**_ False

_**Config Example:**_ `force_http_11 = "false"` or `force_http_11 = "true"`

_**CLI Option Use:**_ `--force-http-11`

### ip_protocol_version
_**Description:**_ This setting controls the application IP protocol that should be used when communicating with Microsoft OneDrive. The default is to use IPv4 and IPv6 networks for communicating to Microsoft OneDrive.

_**Value Type:**_ Integer

_**Default Value:**_ 0

_**Valid Values:**_ 0 = IPv4 + IPv6, 1 = IPv4 Only, 2 = IPv6 Only

_**Config Example:**_ `ip_protocol_version = "0"` or `ip_protocol_version = "1"` or `ip_protocol_version = "2"`

> [!IMPORTANT]
> In some environments where IPv4 and IPv6 are configured at the same time, this causes resolution and routing issues to Microsoft OneDrive. If this is the case, it is advisable to change 'ip_protocol_version' to match your environment.

### local_first
_**Description:**_ This setting controls what the application considers the 'source of truth' for your data. By default, what is stored online will be considered as the 'source of truth' when syncing to your local machine. When using this option, your local data will be considered the 'source of truth'.

_**Value Type:**_ Boolean

_**Default Value:**_ False

_**Config Example:**_ `local_first = "false"` or `local_first = "true"`

_**CLI Option Use:**_ `--local-first`

### log_dir
_**Description:**_ This setting controls the custom application log path when 'enable_logging' has been enabled. By default, all log files will be written to `/var/log/onedrive`.

_**Value Type:**_ String

_**Default Value:**_ *None*

_**Config Example:**_ `log_dir = "~/logs/"`

_**CLI Option Use:**_ `--log-dir "~/logs/"`

### max_curl_idle
_**Description:**_ This configuration option controls the number of seconds that elapse after a cURL engine was last used before it is considered stale and destroyed. Evidence suggests that some upstream network devices ignore the cURL keep-alive setting and forcibly close the active TCP connection when idle.

_**Value Type:**_ Integer

_**Default Value:**_ 120

_**Config Example:**_ `monitor_fullscan_frequency = "120"`

_**CLI Option Use:**_ *None - this is a config file option only*

> [!IMPORTANT]
> It is strongly recommended not to modify this setting without conducting thorough network testing. Changing this option may lead to unexpected behaviour or connectivity issues, especially if upstream network devices handle idle connections in non-standard ways.

### monitor_fullscan_frequency
_**Description:**_ This configuration option controls the number of 'monitor_interval' iterations between when a full scan of your data is performed to ensure data integrity and consistency.

_**Value Type:**_ Integer

_**Default Value:**_ 12

_**Config Example:**_ `monitor_fullscan_frequency = "24"`

_**CLI Option Use:**_ `--monitor-fullscan-frequency '24'`

> [!NOTE]
> By default without configuration, 'monitor_fullscan_frequency' is set to 12. In this default state, this means that a full scan is performed every 'monitor_interval' x 'monitor_fullscan_frequency' = 3600 seconds. This setting is only applicable when running in `--monitor` mode. Setting this configuration option to '0' will *disable* the full scan of your data online.

### monitor_interval
_**Description:**_ This configuration setting determines how often the synchronisation loops run in --monitor mode, measured in seconds. When this time period elapses, the client will check for online changes in Microsoft OneDrive, conduct integrity checks on local data and scan the local 'sync_dir' to identify any new content that hasn't been uploaded yet.

_**Value Type:**_ Integer

_**Default Value:**_ 300

_**Config Example:**_ `monitor_interval = "600"`

_**CLI Option Use:**_ `--monitor-interval '600'`

> [!NOTE]
> A minimum value of 300 is enforced for this configuration setting.

### monitor_log_frequency
_**Description:**_ This configuration option controls the suppression of frequently printed log items to the system console when using `--monitor` mode. The aim of this configuration item is to reduce the log output when near zero sync activity is occurring.

_**Value Type:**_ Integer

_**Default Value:**_ 12

_**Config Example:**_ `monitor_log_frequency = "24"`

_**CLI Option Use:**_ `--monitor-log-frequency '24'`

_**Usage Example:**_ 

By default, at application start-up when using `--monitor` mode, the following will be logged to indicate that the application has correctly started and has performed all the initial processing steps:
```text
Reading configuration file: /home/user/.config/onedrive/config
Configuration file successfully loaded
Configuring Global Azure AD Endpoints
Sync Engine Initialised with new Onedrive API instance
All application operations will be performed in: /home/user/OneDrive
OneDrive synchronisation interval (seconds): 300
Initialising filesystem inotify monitoring ...
Performing initial synchronisation to ensure consistent local state ...
Starting a sync with Microsoft OneDrive
Fetching items from the OneDrive API for Drive ID: b!bO8V6s9SSk9R7mWhpIjUrotN73WlW3tEv3OxP_QfIdQimEdOHR-1So6CqeG1MfDB ..
Processing changes and items received from Microsoft OneDrive ...
Performing a database consistency and integrity check on locally stored data ... 
Scanning the local file system '~/OneDrive' for new data to upload ...
Performing a final true-up scan of online data from Microsoft OneDrive
Fetching items from the OneDrive API for Drive ID: b!bO8V6s9SSk9R7mWhpIjUrotN73WlW3tEv3OxP_QfIdQimEdOHR-1So6CqeG1MfDB ..
Processing changes and items received from Microsoft OneDrive ...
Sync with Microsoft OneDrive is complete
```
Then, based on 'monitor_log_frequency', the following output will be logged until the suppression loop value is reached:
```text
Starting a sync with Microsoft OneDrive
Syncing changes from Microsoft OneDrive ...
Sync with Microsoft OneDrive is complete
```
> [!NOTE]
> The additional log output `Performing a database consistency and integrity check on locally stored data ...` will only be displayed when this activity is occurring which is triggered by 'monitor_fullscan_frequency'.

> [!NOTE]
> If verbose application output is being used (`--verbose`), then this configuration setting has zero effect, as application verbose output takes priority over application output suppression.

### no_remote_delete
_**Description:**_ This configuration option controls whether local file and folder deletes are actioned on Microsoft OneDrive.

_**Value Type:**_ Boolean

_**Default Value:**_ False

_**Config Example:**_ `local_first = "false"` or `local_first = "true"`

_**CLI Option Use:**_ `--no-remote-delete`

> [!IMPORTANT]
> This configuration option can *only* be used in conjunction with `--upload-only`

### notify_file_actions
_**Description:**_ This configuration option controls whether the client will log via GUI notifications successful actions that the client performs.

_**Value Type:**_ Boolean

_**Default Value:**_ False

_**Config Example:**_ `notify_file_actions = "true"`

> [!NOTE]
> GUI Notification Support must be compiled in first, otherwise this option will have zero effect and will not be used.

### operation_timeout
_**Description:**_ This configuration option controls the maximum amount of time (seconds) a file operation is allowed to take. This includes DNS resolution, connecting, data transfer, etc. We recommend users not to tamper with this option unless strictly necessary. This option controls the CURLOPT_TIMEOUT setting of libcurl.

_**Value Type:**_ Integer

_**Default Value:**_ 3600

_**Config Example:**_ `operation_timeout = "3600"`

### rate_limit
_**Description:**_ This configuration option controls the bandwidth used by the application, per thread, when interacting with Microsoft OneDrive.

_**Value Type:**_ Integer

_**Default Value:**_ 0 (unlimited, use available bandwidth per thread)

_**Valid Values:**_ Valid tested values for this configuration option are as follows:

* 131072 	= 128 KB/s - absolute minimum for basic application operations to prevent timeouts
* 262144 	= 256 KB/s
* 524288	= 512 KB/s
* 1048576 	= 1 MB/s
* 10485760 	= 10 MB/s
* 104857600 = 100 MB/s

_**Config Example:**_ `rate_limit = "131072"`

### read_only_auth_scope
_**Description:**_ This configuration option controls whether the OneDrive Client for Linux operates in a totally in read-only operation.

_**Value Type:**_ Boolean

_**Default Value:**_ False

_**Config Example:**_ `read_only_auth_scope = "false"` or `read_only_auth_scope = "true"`

> [!IMPORTANT]
> When using 'read_only_auth_scope' you also will need to remove your existing application access consent otherwise old authentication consent will be valid and will be used. This will mean the application will technically have the consent to upload data until you revoke this consent.

### remove_source_files
_**Description:**_ This configuration option controls whether the OneDrive Client for Linux removes the local file post successful transfer to Microsoft OneDrive.

_**Value Type:**_ Boolean

_**Default Value:**_ False

_**Config Example:**_ `remove_source_files = "false"` or `remove_source_files = "true"`

_**CLI Option Use:**_ `--remove-source-files`

> [!IMPORTANT]
> This configuration option can *only* be used in conjunction with `--upload-only`

### resync
_**Description:**_ This configuration option controls whether the known local sync state with Microsoft OneDrive is removed at application startup. When this option is used, a full scan of your data online is performed to ensure that the local sync state is correctly built back up.

_**Value Type:**_ Boolean

_**Default Value:**_ False

_**Config Example:**_ `resync = "false"` or `resync = "true"`

_**CLI Option Use:**_ `--resync`

> [!CAUTION]
> It's highly recommended to use this option only if the application prompts you to do so. Don't blindly use this option as a default option. If you alter any of the subsequent configuration items, you will be required to execute a `--resync` to make sure your client is syncing your data with the updated configuration:
> *   drive_id
> *   sync_dir
> *   skip_file
> *   skip_dir
> *   skip_dotfiles
> *   skip_symlinks
> *   sync_business_shared_items
> *   Creating, Modifying or Deleting the 'sync_list' file

### resync_auth
_**Description:**_ This configuration option controls the approval of performing a 'resync' which can be beneficial in automated environments.

_**Value Type:**_ Boolean

_**Default Value:**_ False

_**Config Example:**_ `resync_auth = "false"` or `resync_auth = "true"`

_**CLI Option Use:**_ `--resync-auth`

> [!TIP]
> In certain automated environments (assuming you know what you're doing due to using automation), to avoid the 'proceed with acknowledgement' resync requirement, this option allows you to automatically acknowledge the resync prompt.

### skip_dir
_**Description:**_ This configuration option controls whether the application skips certain directories from being synced. Directories can be specified in 2 ways:

* As a single entry. This will search the respective path for this entry and skip all instances where this directory is present, where ever it may exist.
* As a full path entry. This will skip the explicit path as set.

> [!IMPORTANT]
> Entries for 'skip_dir' are *relative* to your 'sync_dir' path.

_**Value Type:**_ String

_**Default Value:**_ *Empty* - not required for normal operation

_**Config Example:**_ 

Patterns are case insensitive. `*` and `?` [wildcards characters](https://technet.microsoft.com/en-us/library/bb490639.aspx) are supported. Use `|` to separate multiple patterns. 

```text
skip_dir = "Desktop|Documents/IISExpress|Documents/SQL Server Management Studio|Documents/Visual Studio*|Documents/WindowsPowerShell|.Rproj-user"
```

The 'skip_dir' option can also be specified multiple times within your config file, for example:
```text
skip_dir = "SkipThisDirectoryAnywhere"
skip_dir = ".SkipThisOtherDirectoryAnywhere"
skip_dir = "/Explicit/Path/To/A/Directory"
skip_dir = "/Another/Explicit/Path/To/Different/Directory"
```

This will be interpreted the same as:
```text
skip_dir = "SkipThisDirectoryAnywhere|.SkipThisOtherDirectoryAnywhere|/Explicit/Path/To/A/Directory|/Another/Explicit/Path/To/Different/Directory"
```

_**CLI Option Use:**_ `--skip-dir 'SkipThisDirectoryAnywhere|.SkipThisOtherDirectoryAnywhere|/Explicit/Path/To/A/Directory|/Another/Explicit/Path/To/Different/Directory'`

> [!NOTE]
> This option is considered a 'Client Side Filtering Rule' and if configured, is utilised for all sync operations. If using the config file and CLI option is used, the CLI option will *replace* the config file entries. After changing or modifying this option, you will be required to perform a resync.

### skip_dir_strict_match
_**Description:**_ This configuration option controls whether the application performs strict directory matching when checking 'skip_dir' items. When enabled, the 'skip_dir' item must be a full path match to the path to be skipped.

_**Value Type:**_ Boolean

_**Default Value:**_ False

_**Config Example:**_ `skip_dir_strict_match = "false"` or `skip_dir_strict_match = "true"`

_**CLI Option Use:**_ `--skip-dir-strict-match`

### skip_dotfiles
_**Description:**_ This configuration option controls whether the application will skip all .files and .folders when performing sync operations.

_**Value Type:**_ Boolean

_**Default Value:**_ False

_**Config Example:**_ `skip_dotfiles = "false"` or `skip_dotfiles = "true"`

_**CLI Option Use:**_ `--skip-dot-files`

> [!NOTE]
> This option is considered a 'Client Side Filtering Rule' and if configured, is utilised for all sync operations. After changing this option, you will be required to perform a resync.

### skip_file
_**Description:**_ This configuration option controls whether the application skips certain files from being synced.

_**Value Type:**_ String

_**Default Value:**_ `~*|.~*|*.tmp|*.swp|*.partial`

_**Config Example:**_ 

Patterns are case insensitive. `*` and `?` [wildcards characters](https://technet.microsoft.com/en-us/library/bb490639.aspx) are supported. Use `|` to separate multiple patterns.

By default, the following files will be skipped:
*   Files that start with ~
*   Files that start with .~ (like .~lock.* files generated by LibreOffice)
*   Files that end in .tmp, .swp and .partial

Files can be skipped in the following fashion:
*   Specify a wildcard, eg: '*.txt' (skip all txt files)
*   Explicitly specify the filename and it's full path relative to your sync_dir, eg: '/path/to/file/filename.ext'
*   Explicitly specify the filename only and skip every instance of this filename, eg: 'filename.ext'

```text
skip_file = "~*|/Documents/OneNote*|/Documents/config.xlaunch|myfile.ext|/Documents/keepass.kdbx"
```

> [!IMPORTANT]
> Entries for 'skip_file' are *relative* to your 'sync_dir' path.

The 'skip_file' option can be specified multiple times within your config file, for example:
```text
skip_file = "~*|.~*|*.tmp|*.swp"
skip_file = "*.blah"
skip_file = "never_sync.file"
skip_file = "/Documents/keepass.kdbx"
```
This will be interpreted the same as:
```text
skip_file = "~*|.~*|*.tmp|*.swp|*.blah|never_sync.file|/Documents/keepass.kdbx"
```

_**CLI Option Use:**_ `--skip-file '~*|.~*|*.tmp|*.swp|*.blah|never_sync.file|/Documents/keepass.kdbx'`

> [!NOTE]
> This option is considered a 'Client Side Filtering Rule' and if configured, is utilised for all sync operations. If using the config file and CLI option is used, the CLI option will *replace* the config file entries. After changing or modifying this option, you will be required to perform a resync.

### skip_size
_**Description:**_ This configuration option controls whether the application skips syncing certain files larger than the specified size. The value specified is in MB.

_**Value Type:**_ Integer

_**Default Value:**_ 0 (all files, regardless of size, are synced)

_**Config Example:**_ `skip_size = "50"`

_**CLI Option Use:**_ `--skip-size '50'`

### skip_symlinks
_**Description:**_ This configuration option controls whether the application will skip all symbolic links when performing sync operations. Microsoft OneDrive has no concept or understanding of symbolic links, and attempting to upload a symbolic link to Microsoft OneDrive generates a platform API error. All data (files and folders) that are uploaded to OneDrive must be whole files or actual directories.

_**Value Type:**_ Boolean

_**Default Value:**_ False

_**Config Example:**_ `skip_symlinks = "false"` or `skip_symlinks = "true"`

_**CLI Option Use:**_ `--skip-symlinks`

> [!NOTE]
> This option is considered a 'Client Side Filtering Rule' and if configured, is utilised for all sync operations. After changing this option, you will be required to perform a resync.

### space_reservation
_**Description:**_ This configuration option controls how much local disk space should be reserved, to prevent the application from filling up your entire disk due to misconfiguration

_**Value Type:**_ Integer

_**Default Value:**_ 50 MB (expressed as Bytes when using `--display-config`)

_**Config Example:**_ `space_reservation = "100"`

_**CLI Option Use:**_ `--space-reservation '100'`

### sync_business_shared_items
_**Description:**_ This configuration option controls whether OneDrive Business | Office 365 Shared Folders, when added as a 'shortcut' to your 'My Files', will be synced to your local system.

_**Value Type:**_ Boolean

_**Default Value:**_ False

_**Config Example:**_ `sync_business_shared_items = "false"` or `sync_business_shared_items = "true"`

_**CLI Option Use:**_ *none* - this is a config file option only

> [!NOTE]
> This option is considered a 'Client Side Filtering Rule' and if configured, is utilised for all sync operations. After changing this option, you will be required to perform a resync.

> [!CAUTION]
> This option is *not* backwards compatible with any v2.4.x application version. If you are enabling this option on *any* system running v2.5.x application version, all your application versions being used *everywhere* must be v2.5.x codebase.

### sync_dir
_**Description:**_ This configuration option determines the location on your local filesystem where your data from Microsoft OneDrive will be saved.

_**Value Type:**_ String

_**Default Value:**_ `~/OneDrive`

_**Config Example:**_ `sync_dir = "~/MyDirToSync"`

_**CLI Option Use:**_ `--syncdir '~/MyDirToSync'`

> [!CAUTION]
> After changing this option, you will be required to perform a resync. Do not change or modify this option without fully understanding the implications of doing so.

### sync_dir_permissions
_**Description:**_ This configuration option defines the directory permissions applied when a new directory is created locally during the process of syncing your data from Microsoft OneDrive.

_**Value Type:**_ Integer

_**Default Value:**_ `700` - This provides the following permissions: `drwx------`

_**Config Example:**_ `sync_dir_permissions = "700"`

> [!IMPORTANT]
> Use the [Unix Permissions Calculator](https://chmod-calculator.com/) to help you determine the necessary new permissions. You will need to manually update all existing directory permissions if you modify this value.

### sync_file_permissions
_**Description:**_ This configuration option defines the file permissions applied when a new file is created locally during the process of syncing your data from Microsoft OneDrive.

_**Value Type:**_ Integer

_**Default Value:**_ `600` - This provides the following permissions: `-rw-------`

_**Config Example:**_ `sync_file_permissions = "600"`

> [!IMPORTANT]
> Use the [Unix Permissions Calculator](https://chmod-calculator.com/) to help you determine the necessary new permissions. You will need to manually update all existing directory permissions if you modify this value.

### sync_root_files
_**Description:**_ This configuration option manages the synchronisation of files located in the 'sync_dir' root when using a 'sync_list.' It enables you to sync all these files by default, eliminating the need to repeatedly modify your 'sync_list' and initiate resynchronisation.

_**Value Type:**_ Boolean

_**Default Value:**_ False

_**Config Example:**_ `sync_root_files = "false"` or `sync_root_files = "true"`

_**CLI Option Use:**_ `--sync-root-files`

> [!IMPORTANT]
> Although it's not mandatory, it's recommended that after enabling this option, you perform a `--resync`. This ensures that any previously excluded content is now included in your sync process.

### threads
_**Description:**_ This configuration option controls the number of 'threads' for upload and download operations when files need to be transferred between your local system and Microsoft OneDrive.

_**Value Type:**_ Integer

_**Default Value:**_ `8`

_**Maximum Value:**_ `16`

_**Config Example:**_ `threads = "16"`

> [!WARNING]
> Increasing the threads beyond the default will lead to increased system utilisation and local TCP port use, which may lead to unpredictable behaviour and/or may lead application stability issues.

### upload_only
_**Description:**_ This setting forces the client to only upload data to Microsoft OneDrive and replicate the locate state online. By default, this will also remove content online, that has been removed locally.

_**Value Type:**_ Boolean

_**Default Value:**_ False

_**Config Example:**_ `upload_only = "false"` or `upload_only = "true"`

_**CLI Option Use:**_ `--upload-only`

> [!IMPORTANT]
> To ensure that data deleted locally remains accessible online, you can use the 'no_remote_delete' option. If you want to delete the data from your local storage after a successful upload to Microsoft OneDrive, you can use the 'remove_source_files' option.

### user_agent
_**Description:**_ This configuration option controls the 'User-Agent' request header that is presented to Microsoft Graph API when accessing the Microsoft OneDrive service. This string lets servers and network peers identify the application, operating system, vendor, and/or version of the application making the request. We recommend users not to tamper with this option unless strictly necessary.

_**Value Type:**_ String

_**Default Value:**_ `ISV|abraunegg|OneDrive Client for Linux/vX.Y.Z-A-bcdefghi`

_**Config Example:**_ `user_agent = "ISV|CompanyName|AppName/Version"`

> [!IMPORTANT]
> The default 'user_agent' value conforms to specific Microsoft requirements to identify as an ISV that complies with OneDrive traffic decoration requirements. Changing this value potentially will impact how Microsoft see's your client, thus your traffic may get throttled. For further information please read: https://learn.microsoft.com/en-us/sharepoint/dev/general-development/how-to-avoid-getting-throttled-or-blocked-in-sharepoint-online

### webhook_enabled
_**Description:**_ This configuration option controls the application feature 'webhooks' to allow you to subscribe to remote updates as published by Microsoft OneDrive. This option only operates when the client is using 'Monitor Mode'.

_**Value Type:**_ Boolean

_**Default Value:**_ False

_**Config Example:**_ The following is the minimum working example that needs to be added to your 'config' file to enable 'webhooks' successfully:
```text
webhook_enabled = "true"
webhook_public_url = "https://<your.fully.qualified.domain.name>/webhooks/onedrive"
```

> [!NOTE]
> Setting `webhook_enabled = "true"` enables the webhook feature in 'monitor' mode. The onedrive process will listen for incoming updates at a configurable endpoint, which defaults to `0.0.0.0:8888`.

> [!IMPORTANT]
> A valid HTTPS certificate is required for your public-facing URL if using nginx. Self signed certificates will be rejected. Consider using https://letsencrypt.org/ to utilise free SSL certificates for your public-facing URL.

> [!TIP]
> If you receive this application error: `Subscription validation request failed. Response must exactly match validationToken query parameter.` the most likely cause for this error will be your nginx configuration.
> 
> To resolve this configuration issue, potentially investigate adding the following 'proxy' configuration options to your nginx configuration file:
> ```text
> server {
> 	listen 443;
>	server_name <your.fully.qualified.domain.name>;
> 	location /webhooks/onedrive {
> 		proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
> 		proxy_set_header X-Original-Request-URI $request_uri;
> 		proxy_read_timeout 300s;
> 		proxy_connect_timeout 75s;
> 		proxy_buffering off;
> 		proxy_http_version 1.1;
> 		proxy_pass http://127.0.0.1:8888;
> 	}
> }
> ```
> For any further nginx configuration assistance, please refer to: https://docs.nginx.com/

### webhook_expiration_interval
_**Description:**_ This configuration option controls the frequency at which an existing Microsoft OneDrive webhook subscription expires. The value is expressed in the number of seconds before expiry.

_**Value Type:**_ Integer

_**Default Value:**_ 600 

_**Config Example:**_ `webhook_expiration_interval = "1200"`

### webhook_listening_host
_**Description:**_ This configuration option controls the host address that this client binds to, when the webhook feature is enabled.

_**Value Type:**_ String

_**Default Value:**_ 0.0.0.0

_**Config Example:**_ `webhook_listening_host = ""` - this will use the default value. `webhook_listening_host = "192.168.3.4"` - this will bind the client to use the IP address 192.168.3.4.

> [!NOTE]
> Use in conjunction with 'webhook_listening_port' to change the webhook listening endpoint.

### webhook_listening_port
_**Description:**_ This configuration option controls the TCP port that this client listens on, when the webhook feature is enabled.

_**Value Type:**_ Integer

_**Default Value:**_ 8888

_**Config Example:**_ `webhook_listening_port = "9999"`

> [!NOTE]
> Use in conjunction with 'webhook_listening_host' to change the webhook listening endpoint.

### webhook_public_url
_**Description:**_ This configuration option controls the URL that Microsoft will send subscription notifications to. This must be a valid Internet accessible URL.

_**Value Type:**_ String

_**Default Value:**_ *empty*

_**Config Example:**_ 
```text
webhook_public_url = "https://<your.fully.qualified.domain.name>/webhooks/onedrive"
```

### webhook_renewal_interval
_**Description:**_ This configuration option controls the frequency at which an existing Microsoft OneDrive webhook subscription is renewed. The value is expressed in the number of seconds before renewal.

_**Value Type:**_ Integer

_**Default Value:**_ 300

_**Config Example:**_ `webhook_renewal_interval = "600"`

### webhook_retry_interval
_**Description:**_ This configuration option controls the frequency at which an existing Microsoft OneDrive webhook subscription is retried when creating or renewing a subscription failed. The value is expressed in the number of seconds before retry.

_**Value Type:**_ Integer

_**Default Value:**_ 60

_**Config Example:**_ `webhook_retry_interval = "120"`

## Command Line Interface (CLI) Only Options

### CLI Option: --auth-files
_**Description:**_ This CLI option allows the user to perform application authentication not via an interactive dialog but via specific files that the application uses to read the authentication data from.

_**Usage Example:**_ `onedrive --auth-files authUrl:responseUrl`

> [!IMPORTANT]
> The authorisation URL is written to the specified 'authUrl' file, then onedrive waits for the file 'responseUrl' to be present, and reads the authentication response from that file. Example:
> 
> ```text
> onedrive --auth-files '~/onedrive-auth-url:~/onedrive-response-url' 
> Reading configuration file: /home/alex/.config/onedrive/config
> Configuration file successfully loaded
> Configuring Global Azure AD Endpoints
> Client requires authentication before proceeding. Waiting for --auth-files elements to be available.
> ```
> At this point, the client has written the file `~/onedrive-auth-url` which contains the authentication URL that needs to be visited to perform the authentication process. The client will now wait and watch for the presence of the file `~/onedrive-response-url`.
> 
> Visit the authentication URL, and then create a new file called `~/onedrive-response-url` with the response URI. Once this has been done, the application will acknowledge the presence of this file, read the contents, and authenticate the application.
> ```text
> Sync Engine Initialised with new Onedrive API instance
> 
>  --sync or --monitor switches missing from your command line input. Please add one (not both) of these switches to your command line or use 'onedrive --help' for further assistance.
> 
> No OneDrive sync will be performed without one of these two arguments being present.
> ```

### CLI Option: --auth-response
_**Description:**_ This CLI option allows the user to perform application authentication not via an interactive dialog but via providing the authentication response URI directly.

_**Usage Example:**_ `onedrive --auth-response https://login.microsoftonline.com/common/oauth2/nativeclient?code=<redacted>`

> [!TIP]
> Typically, unless the application client identifier has been modified, authentication scopes are being modified or a specific Azure Tenant is being specified, the authentication URL will most likely be as follows:
> ```text
> https://login.microsoftonline.com/common/oauth2/v2.0/authorize?client_id=d50ca740-c83f-4d1b-b616-12c519384f0c&scope=Files.ReadWrite%20Files.ReadWrite.All%20Sites.ReadWrite.All%20offline_access&response_type=code&prompt=login&redirect_uri=https://login.microsoftonline.com/common/oauth2/nativeclient 
> ```
> With this URL being known, it is possible ahead of time to request an authentication token by visiting this URL, and performing the authentication access request.

### CLI Option: --confdir
_**Description:**_ This CLI option allows the user to specify where all the application configuration and relevant components are stored.

_**Usage Example:**_ `onedrive --confdir '~/.config/onedrive-business/'`

> [!IMPORTANT]
> If using this option, it must be specified each and every time the application is used. If this is omitted, the application default configuration directory will be used.

### CLI Option: --create-directory
_**Description:**_ This CLI option allows the user to create the specified directory path on Microsoft OneDrive without performing a sync.

_**Usage Example:**_ `onedrive --create-directory 'path/of/new/folder/structure/to/create/'`

> [!IMPORTANT]
> The specified path to create is relative to your configured 'sync_dir'.

### CLI Option: --create-share-link
_**Description:**_ This CLI option enables the creation of a shareable file link that can be provided to users to access the file that is stored on Microsoft OneDrive. By default, the permissions for the file will be 'read-only'.

_**Usage Example:**_ `onedrive --create-share-link 'relative/path/to/your/file.txt'`

> [!IMPORTANT]
> If writable access to the file is required, you must add `--with-editing-perms` to your command. See below for details.

### CLI Option: --destination-directory
_**Description:**_ This CLI option specifies the 'destination' portion of moving a file or folder online, without performing a sync operation.

_**Usage Example:**_ `onedrive --source-directory 'path/as/source/' --destination-directory 'path/as/destination'`

> [!IMPORTANT]
> All specified paths are relative to your configured 'sync_dir'.

### CLI Option: --display-config
_**Description:**_ This CLI option will display the effective application configuration

_**Usage Example:**_ `onedrive --display-config`

### CLI Option: --display-sync-status
_**Description:**_ This CLI option will display the sync status of the configured 'sync_dir'

_**Usage Example:**_ `onedrive --display-sync-status`

> [!TIP]
> This option can also use the `--single-directory` option to determine the sync status of a specific directory within the configured 'sync_dir'

### CLI Option: ---display-quota
_**Description:**_ This CLI option will display the quota status of the account drive id or the configured 'drive_id' value

_**Usage Example:**_ `onedrive --display-quota`

### CLI Option: --force
_**Description:**_ This CLI option enables the force the deletion of data when a 'big delete' is detected. 

_**Usage Example:**_ `onedrive --sync --verbose --force`

> [!IMPORTANT]
> This option should only be used exclusively in cases where you've initiated a 'big delete' and genuinely intend to remove all the data that is set to be deleted online.

### CLI Option: --force-sync
_**Description:**_ This CLI option enables the syncing of a specific directory, using the Client Side Filtering application defaults, overriding any user application configuration.

_**Usage Example:**_ `onedrive --sync --verbose --force-sync --single-directory 'Data'

> [!NOTE]
> When this option is used, you will be presented with the following warning and risk acceptance:
> ```text
> WARNING: Overriding application configuration to use application defaults for skip_dir and skip_file due to --synch --single-directory --force-sync being used
> 
> The use of --force-sync will reconfigure the application to use defaults. This may have untold and unknown future impacts.
> By proceeding in using this option you accept any impacts including any data loss that may occur as a result of using --force-sync.
> 
> Are you sure you wish to proceed with --force-sync [Y/N] 
> ```
> To proceed with this sync task, you must risk accept the actions you are taking. If you have any concerns, first use `--dry-run` and evaluate the outcome before proceeding with the actual action.

### CLI Option: --get-file-link
_**Description:**_ This CLI option queries the OneDrive API and return's the WebURL for the given local file.

_**Usage Example:**_ `onedrive --get-file-link 'relative/path/to/your/file.txt'`

> [!IMPORTANT]
> The path that you should use *must* be relative to your 'sync_dir'

### CLI Option: --get-sharepoint-drive-id
_**Description:**_ This CLI option queries the OneDrive API and return's the Office 365 Drive ID for a given Office 365 SharePoint Shared Library that can then be used with 'drive_id' to sync a specific SharePoint Library.

_**Usage Example:**_ `onedrive --get-sharepoint-drive-id '*'` or `onedrive --get-sharepoint-drive-id 'PointPublishing Hub Site'`

### CLI Option: --list-shared-items
_**Description:**_ This CLI option lists all OneDrive Business Shared items with your account. The resulting list shows shared files and folders that you can configure this client to sync.

_**Usage Example:**_ `onedrive --list-shared-items`

_**Example Output:**_
```
...
Listing available OneDrive Business Shared Items:

-----------------------------------------------------------------------------------
Shared File:     large_document_shared.docx
Shared By:       test user (testuser@domain.tld)
-----------------------------------------------------------------------------------
Shared File:     no_download_access.docx
Shared By:       test user (testuser@domain.tld)
-----------------------------------------------------------------------------------
Shared File:     online_access_only.txt
Shared By:       test user (testuser@domain.tld)
-----------------------------------------------------------------------------------
Shared File:     read_only.txt
Shared By:       test user (testuser@domain.tld)
-----------------------------------------------------------------------------------
Shared File:     qewrqwerwqer.txt
Shared By:       test user (testuser@domain.tld)
-----------------------------------------------------------------------------------
Shared File:     dummy_file_to_share.docx
Shared By:       testuser2 testuser2 (testuser2@domain.tld)
-----------------------------------------------------------------------------------
Shared Folder:   Sub Folder 2
Shared By:       test user (testuser@domain.tld)
-----------------------------------------------------------------------------------
Shared File:     file to share.docx
Shared By:       test user (testuser@domain.tld)
-----------------------------------------------------------------------------------
Shared Folder:   Top Folder
Shared By:       test user (testuser@domain.tld)
-----------------------------------------------------------------------------------
...
```

### CLI Option: --logout
_**Description:**_ This CLI option removes this clients authentication status with Microsoft OneDrive. Any further application use will require the application to be re-authenticated with Microsoft OneDrive.

_**Usage Example:**_ `onedrive --logout`

### CLI Option: --modified-by
_**Description:**_ This CLI option queries the OneDrive API and return's the last modified details for the given local file.

_**Usage Example:**_ `onedrive --modified-by 'relative/path/to/your/file.txt'`

> [!IMPORTANT]
> The path that you should use *must* be relative to your 'sync_dir'

### CLI Option: --monitor | -m
_**Description:**_ This CLI option controls the 'Monitor Mode' operational aspect of the client. When this option is used, the client will perform on-going syncs of data between Microsoft OneDrive and your local system. Local changes will be uploaded in near-realtime, whilst online changes will be downloaded on the next sync process. The frequency of these checks is governed by the 'monitor_interval' value.

_**Usage Example:**_ `onedrive --monitor` or `onedrive -m`

### CLI Option: --print-access-token
_**Description:**_ Print the current access token being used to access Microsoft OneDrive. 

_**Usage Example:**_ `onedrive --verbose --verbose --debug-https --print-access-token`

> [!CAUTION]
> Do not use this option if you do not know why you are wanting to use it. Be highly cautious of exposing this object. Change your password if you feel that you have inadvertently exposed this token.

### CLI Option: --reauth
_**Description:**_ This CLI option controls the ability to re-authenticate your client with Microsoft OneDrive.

_**Usage Example:**_ `onedrive --reauth`

### CLI Option: --remove-directory
_**Description:**_ This CLI option allows the user to remove the specified directory path on Microsoft OneDrive without performing a sync.

_**Usage Example:**_ `onedrive --remove-directory 'path/of/new/folder/structure/to/remove/'`

> [!IMPORTANT]
> The specified path to remove is relative to your configured 'sync_dir'.

### CLI Option: --single-directory
_**Description:**_ This CLI option controls the applications ability to sync a specific single directory.

_**Usage Example:**_ `onedrive --sync --single-directory 'Data'`

> [!IMPORTANT]
> The path specified is relative to your configured 'sync_dir' path. If the physical local path 'Folder' to sync is `~/OneDrive/Data/Folder` then the command would be `--single-directory 'Data/Folder'`.

### CLI Option: --source-directory
_**Description:**_ This CLI option specifies the 'source' portion of moving a file or folder online, without performing a sync operation.

_**Usage Example:**_ `onedrive --source-directory 'path/as/source/' --destination-directory 'path/as/destination'`

> [!IMPORTANT]
> All specified paths are relative to your configured 'sync_dir'.

### CLI Option: --sync | -s
_**Description:**_ This CLI option controls the 'Standalone Mode' operational aspect of the client. When this option is used, the client will perform a one-time sync of data between Microsoft OneDrive and your local system.

_**Usage Example:**_ `onedrive --sync` or `onedrive -s`

### CLI Option: --sync-shared-files
_**Description:**_ Sync OneDrive Business Shared Files to the local filesystem.

_**Usage Example:**_ `onedrive --sync --sync-shared-files`

> [!IMPORTANT]
> To use this option you must first enable 'sync_business_shared_items' within your application configuration. Please read 'business-shared-items.md' for more information regarding this option.

### CLI Option: --verbose | -v+
_**Description:**_ This CLI option controls the verbosity of the application output. Use the option once, to have normal verbose output, use twice to have debug level application output.

_**Usage Example:**_ `onedrive --sync --verbose` or `onedrive --monitor --verbose`

### CLI Option: --with-editing-perms
_**Description:**_ This CLI option enables the creation of a writable shareable file link that can be provided to users to access the file that is stored on Microsoft OneDrive. This option can only be used in conjunction with `--create-share-link`

_**Usage Example:**_ `onedrive --create-share-link 'relative/path/to/your/file.txt' --with-editing-perms`

> [!IMPORTANT]
> Placement of `--with-editing-perms` is critical. It *must* be placed after the file path as per the example above.

## Deprecated Configuration File and CLI Options
The following configuration options are no longer supported:

### force_http_2
_**Description:**_ Force the use of HTTP/2 for all operations where applicable

_**Deprecated Config Example:**_ `force_http_2 = "true"`

_**Deprecated CLI Option:**_ `--force-http-2`

_**Reason for depreciation:**_ HTTP/2 will be used by default where possible, when the OneDrive API platform does not downgrade the connection to HTTP/1.1, thus this configuration option is no longer required.

### min_notify_changes
_**Description:**_ Minimum number of pending incoming changes necessary to trigger a GUI desktop notification.

_**Deprecated Config Example:**_ `min_notify_changes = "50"`

_**Deprecated CLI Option:**_ `--min-notify-changes '50'`

_**Reason for depreciation:**_ Application has been totally re-written. When this item was introduced, it was done so to reduce spamming of all events to the GUI desktop.

### CLI Option: --synchronize
_**Description:**_ Perform a synchronisation with Microsoft OneDrive

_**Deprecated CLI Option:**_ `--synchronize`

_**Reason for depreciation:**_ `--synchronize` has been deprecated in favour of `--sync` or `-s`
