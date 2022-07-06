# Configuration and Usage of the OneDrive Free Client
## Table of Contents
- [Using the client](#using-the-client)
  * [Upgrading from 'skilion' client](#upgrading-from-skilion-client)
  * [Local File and Folder Naming Conventions](#local-file-and-folder-naming-conventions)
  * [curl compatibility](#curl-compatibility)
  * [Authorize the application with your OneDrive Account](#authorize-the-application-with-your-onedrive-account)
  * [Show your configuration](#show-your-configuration)
  * [Testing your configuration](#testing-your-configuration)
  * [Performing a sync](#performing-a-sync)
  * [Performing a single directory sync](#performing-a-single-directory-sync)
  * [Performing a 'one-way' download sync](#performing-a-one-way-download-sync)
  * [Performing a 'one-way' upload sync](#performing-a-one-way-upload-sync)
  * [Performing a selective sync via 'sync_list' file](#performing-a-selective-sync-via-sync_list-file)
  * [Performing a --resync](#performing-a---resync)
  * [Performing a --force-sync without a --resync or changing your configuration](#performing-a---force-sync-without-a---resync-or-changing-your-configuration)
  * [Increasing logging level](#increasing-logging-level)
  * [Client Activity Log](#client-activity-log)
  * [Notifications](#notifications)
  * [Handling a OneDrive account password change](#handling-a-onedrive-account-password-change)
- [Configuration](#configuration)
  * [The default configuration](#the-default-configuration-file-is-listed-below)
  * ['config' file configuration examples](#config-file-configuration-examples)
    + [sync_dir](#sync_dir)
    + [sync_dir directory and file permissions](#sync_dir-directory-and-file-permissions)
    + [skip_dir](#skip_dir)
    + [skip_file](#skip_file)
    + [skip_dotfiles](#skip_dotfiles)
    + [monitor_interval](#monitor_interval)
    + [monitor_fullscan_frequency](#monitor_fullscan_frequency)
    + [min_notify_changes](#min_notify_changes)
    + [operation_timeout](#operation_timeout)
  * [Configuring the client for 'single tenant application' use](#configuring-the-client-for-single-tenant-application-use)
  * [Configuring the client to use older 'skilion' application identifier](#configuring-the-client-to-use-older-skilion-application-identifier)
- [Frequently Asked Configuration Questions](#frequently-asked-configuration-questions)
  * [How to sync only specific or single directory?](#how-to-sync-only-specific-or-single-directory)
  * [How to 'skip' directories from syncing?](#how-to-skip-directories-from-syncing)
  * [How to 'skip' files from syncing?](#how-to-skip-files-from-syncing)
  * [How to 'rate limit' the application to control bandwidth consumed for upload & download operations?](#how-to-rate-limit-the-application-to-control-bandwidth-consumed-for-upload--download-operations)
  * [How to prevent your local disk from filling up?](#how-to-prevent-your-local-disk-from-filling-up)
  * [How are symbolic links handled by the client?](#how-are-symbolic-links-handled-by-the-client)
  * [How to sync shared folders (OneDrive Personal)?](#how-to-sync-shared-folders-onedrive-personal)
  * [How to sync shared folders (OneDrive Business or Office 365)?](#how-to-sync-shared-folders-onedrive-business-or-office-365)
  * [How to sync sharePoint / Office 365 Shared Libraries?](#how-to-sync-sharepoint--office-365-shared-libraries)
- [Running 'onedrive' in 'monitor' mode](#running-onedrive-in-monitor-mode)
  * [Use webhook to subscribe to remote updates in 'monitor' mode](#use-webhook-to-subscribe-to-remote-updates-in-monitor-mode)
  * [More webhook configuration options](#more-webhook-configuration-options)
    + [webhook_listening_host and webhook_listening_port](#webhook_listening_host-and-webhook_listening_port)
    + [webhook_expiration_interval and webhook_renewal_interval](#webhook_expiration_interval-and-webhook_renewal_interval)
- [Running 'onedrive' as a system service](#running-onedrive-as-a-system-service)
  * [OneDrive service running as root user via init.d](#onedrive-service-running-as-root-user-via-initd)
  * [OneDrive service running as root user via systemd (Arch, Ubuntu, Debian, OpenSuSE, Fedora)](#onedrive-service-running-as-root-user-via-systemd-arch-ubuntu-debian-opensuse-fedora)
  * [OneDrive service running as root user via systemd (Red Hat Enterprise Linux, CentOS Linux)](#onedrive-service-running-as-root-user-via-systemd-red-hat-enterprise-linux-centos-linux)
  * [OneDrive service running as a non-root user via systemd (All Linux Distributions)](#onedrive-service-running-as-a-non-root-user-via-systemd-all-linux-distributions)
  * [OneDrive service running as a non-root user via systemd (with notifications enabled) (Arch, Ubuntu, Debian, OpenSuSE, Fedora)](#onedrive-service-running-as-a-non-root-user-via-systemd-with-notifications-enabled-arch-ubuntu-debian-opensuse-fedora)
  * [OneDrive service running as a non-root user via runit (antiX, Devuan, Artix, Void)](#onedrive-service-running-as-a-non-root-user-via-runit-antix-devuan-artix-void)
- [Additional Configuration](#additional-configuration)
  * [Advanced Configuration of the OneDrive Free Client](#advanced-configuration-of-the-onedrive-free-client)
  * [Access OneDrive service through a proxy](#access-onedrive-service-through-a-proxy)
  * [Setup selinux for a sync folder outside of the home folder](#setup-selinux-for-a-sync-folder-outside-of-the-home-folder)
- [All available commands](#all-available-commands)


## Using the client

### Upgrading from 'skilion' client
The 'skilion' version contains a significant number of defects in how the local sync state is managed. When upgrading from the 'skilion' version to this version, it is advisable to stop any service / onedrive process from running and then remove any `items.sqlite3` file from your configuration directory (`~/.config/onedrive/`) as this will force the creation of a new local cache file.

Additionally, if you are using a 'config' file within your configuration directory (`~/.config/onedrive/`), please ensure that you update the `skip_file = ` option as per below:

**Invalid configuration:**
```text
skip_file = ".*|~*"
```
**Minimum valid configuration:**
```text
skip_file = "~*"
```
**Default valid configuration:**
```text
skip_file = "~*|.~*|*.tmp"
```

Do not use a skip_file entry of `.*` as this will prevent correct searching of local changes to process.

### Local File and Folder Naming Conventions
The files and directories in the synchronization directory must follow the [Windows naming conventions](https://docs.microsoft.com/windows/win32/fileio/naming-a-file).
The application will attempt to handle instances where you have two files with the same names but with different capitalization. Where there is a namespace clash, the file name which clashes will not be synced. This is expected behavior and won't be fixed.

### curl compatibility
If your system utilises curl < 7.47.0, curl defaults to HTTP/1.1 for HTTPS operations. The client will use HTTP/1.1.

If your system utilises curl >= 7.47.0 and < 7.62.0, curl will prefer HTTP/2 for HTTPS but will stick to HTTP/1.1 by default. The client will use HTTP/1.1 for HTTPS operations.

If your system utilises curl >= 7.62.0, curl defaults to prefer HTTP/2 over HTTP/1.1 by default. The client will utilse HTTP/2 for most HTTPS operations and HTTP/1.1 for others. This difference is governed by the OneDrive platform and not this client.

If you wish to explicitly use HTTP/1.1 you will need to use the `--force-http-11` flag or set the config option `force_http_11 = "true"` to force the application to use HTTP/1.1 otherwise all client operations will use whatever is the curl default for your distribution.

### Authorize the application with your OneDrive Account
After installing the application you must authorize the application with your OneDrive Account. This is done by running the application without any additional command switches.

Note that some companies require to explicitly add this app in [Microsoft MyApps portal](https://myapps.microsoft.com/). To add an (approved) app to your apps, click on the ellipsis in the top-right corner and choose "Request new apps". On the next page you can add this app. If its not listed, you should request through your IT department.

You will be asked to open a specific URL by using your web browser where you will have to login into your Microsoft Account and give the application the permission to access your files. After giving permission to the application, you will be redirected to a blank page. Copy the URI of the blank page into the application.
```text
[user@hostname ~]$ onedrive

Authorize this app visiting:

https://.....

Enter the response uri:

```

**Example:**
```
[user@hostname ~]$ onedrive
Authorize this app visiting:

https://login.microsoftonline.com/common/oauth2/v2.0/authorize?client_id=22c49a0d-d21c-4792-aed1-8f163c982546&scope=Files.ReadWrite%20Files.ReadWrite.all%20Sites.ReadWrite.All%20offline_access&response_type=code&redirect_uri=https://login.microsoftonline.com/common/oauth2/nativeclient

Enter the response uri: https://login.microsoftonline.com/common/oauth2/nativeclient?code=<redacted>

Application has been successfully authorised, however no additional command switches were provided.

Please use 'onedrive --help' for further assistance in regards to running this application.
```

### Show your configuration
To validate your configuration the application will use, utilize the following:
```text
onedrive --display-config
```
This will display all the pertinent runtime interpretation of the options and configuration you are using. Example output is as follows:
```text
Configuration file successfully loaded
onedrive version                             = vX.Y.Z-A-bcdefghi
Config path                                  = /home/alex/.config/onedrive
Config file found in config path             = true
Config option 'sync_dir'                     = /home/alex/OneDrive
Config option 'enable_logging'               = false
...
Selective sync 'sync_list' configured        = false
Config option 'sync_business_shared_folders' = false
Business Shared Folders configured           = false
Config option 'webhook_enabled'              = false
```

### Testing your configuration
You are able to test your configuration by utilising the `--dry-run` CLI option. No files will be downloaded, uploaded or removed, however the application will display what 'would' have occurred. For example:
```text
onedrive --synchronize --verbose --dry-run
DRY-RUN Configured. Output below shows what 'would' have occurred.
Loading config ...
Using Config Dir: /home/user/.config/onedrive
Initializing the OneDrive API ...
Opening the item database ...
All operations will be performed in: /home/user/OneDrive
Initializing the Synchronization Engine ...
Account Type: personal
Default Drive ID: <redacted>
Default Root ID: <redacted>
Remaining Free Space: 5368709120
Fetching details for OneDrive Root
OneDrive Root exists in the database
Syncing changes from OneDrive ...
Applying changes of Path ID: <redacted>
Uploading differences of .
Processing root
The directory has not changed
Uploading new items of .
OneDrive Client requested to create remote path: ./newdir
The requested directory to create was not found on OneDrive - creating remote directory: ./newdir
Successfully created the remote directory ./newdir on OneDrive
Uploading new file ./newdir/newfile.txt ... done.
Remaining free space: 5368709076
Applying changes of Path ID: <redacted>
```

**Note:** `--dry-run` can only be used with `--synchronize`. It cannot be used with `--monitor` and will be ignored.

### Performing a sync
By default all files are downloaded in `~/OneDrive`. After authorizing the application, a sync of your data can be performed by running:
```text
onedrive --synchronize
```
This will synchronize files from your OneDrive account to your `~/OneDrive` local directory.

If you prefer to use your local files as stored in `~/OneDrive` as the 'source of truth' use the following sync command:
```text
onedrive --synchronize --local-first
```

### Performing a single directory sync
In some cases it may be desirable to sync a single directory under ~/OneDrive without having to change your client configuration. To do this use the following command:
```text
onedrive --synchronize --single-directory '<dir_name>'
```

Example: If the full path is `~/OneDrive/mydir`, the command would be `onedrive --synchronize --single-directory 'mydir'`

### Performing a 'one-way' download sync
In some cases it may be desirable to 'download only' from OneDrive. To do this use the following command:
```text
onedrive --synchronize --download-only
```

### Performing a 'one-way' upload sync
In some cases it may be desirable to 'upload only' to OneDrive. To do this use the following command:
```text
onedrive --synchronize --upload-only
```
**Note:** If a file or folder is present on OneDrive, that does not exist locally, it will be removed. If the data on OneDrive should be kept, the following should be used:
```text
onedrive --synchronize --upload-only --no-remote-delete
```

### Performing a selective sync via 'sync_list' file
Selective sync allows you to sync only specific files and directories.
To enable selective sync create a file named `sync_list` in your application configuration directory (default is `~/.config/onedrive`).
Each line of the file represents a relative path from your `sync_dir`. All files and directories not matching any line of the file will be skipped during all operations.
Here is an example of `sync_list`:
```text
# sync_list supports comments
#
# The ordering of entries is highly recommended - exclusions before inclusions
#
# Exclude temp folders under Documents
!Documents/temp*
# Exclude my secret data
!/Secret_data/*
#
# Include my Backup folder
Backup
# Include Documents folder
Documents/
# Include all PDF documents
Documents/*.pdf
# Include this single document
Documents/latest_report.docx
# Include all Work/Project directories
Work/Project*
notes.txt
# Include /Blender in the ~OneDrive root but not if elsewhere
/Blender
# Include these names if they match any file or folder
Cinema Soc
Codes
Textbooks
Year 2
```
The following are supported for pattern matching and exclusion rules:
*   Use the `*` to wildcard select any characters to match for the item to be included
*   Use either `!` or `-` characters at the start of the line to exclude an otherwise included item

To simplify 'exclusions' and 'inclusions', the following is also possible:
```text
# sync_list supports comments
#
# The ordering of entries is highly recommended - exclusions before inclusions
#
# Exclude temp folders under Documents
!Documents/temp*
# Exclude my secret data
!/Secret_data/*
#
# Include everything else
/*
```

**Note:** When enabling the use of 'sync_list' utilise the `--display-config` option to validate that your configuration will be used by the application, and test your configuration by adding `--dry-run` to ensure the client will operate as per your requirement.

**Note:** After changing the sync_list, you must perform a full re-synchronization by adding `--resync` to your existing command line - for example: `onedrive --synchronize --resync`

**Note:** In some circumstances, it may be required to sync all the individual files within the 'sync_dir', but due to frequent name change / addition / deletion of these files, it is not desirable to constantly change the 'sync_list' file to include / exclude these files and force a resync. To assist with this, enable the following in your configuration file:
```text
sync_root_files = "true"
```
This will tell the application to sync any file that it finds in your 'sync_dir' root by default.

### Performing a --resync
If you modify any of the following configuration items, you will be required to perform a `--resync` to ensure your client is syncing your data with the updated configuration:
*   sync_dir
*   skip_dir
*   skip_file
*   drive_id
*   Modifying sync_list
*   Modifying business_shared_folders

Additionally, you may choose to perform a `--resync` if you feel that this action needs to be taken to ensure your data is in sync. If you are using this switch simply because you dont know the sync status, you can query the actual sync status using `--display-sync-status`.

When using `--resync`, the following warning and advice will be presented:
```text
The use of --resync will remove your local 'onedrive' client state, thus no record will exist regarding your current 'sync status'
This has the potential to overwrite local versions of files with potentially older versions downloaded from OneDrive which can lead to data loss
If in-doubt, backup your local data first before proceeding with --resync

Are you sure you wish to proceed with --resync? [Y/N]
```

To proceed with using `--resync`, you must type 'y' or 'Y' to allow the application to continue.

**Note:** It is highly recommended to only use `--resync` if the application advises you to use it. Do not just blindly set the application to start with `--resync` as the default option.

**Note:** In some automated environments (and it is 100% assumed you *know* what you are doing because of automation), in order to avoid this 'proceed with acknowledgement' requirement, add `--resync-auth` to automatically acknowledge the prompt.

### Performing a --force-sync without a --resync or changing your configuration
In some cases and situations, you may have configured the application to skip certain files and folders using 'skip_file' and 'skip_dir' configuration. You then may have a requirement to actually sync one of these items, but do not wish to modify your configuration, nor perform an entire `--resync` twice.

The `--force-sync` option allows you to sync a specific directory, ignoring your 'skip_file' and 'skip_dir' configuration and negating the requirement to perform a `--resync`

In order to use this option, you must run the application manually in the following manner:
```text
onedrive --synchronize --single-directory '<directory_to_sync>' --force-sync <add any other options needed or required>
```

When using `--force-sync`, the following warning and advice will be presented:
```text
WARNING: Overriding application configuration to use application defaults for skip_dir and skip_file due to --synchronize --single-directory --force-sync being used

The use of --force-sync will reconfigure the application to use defaults. This may have untold and unknown future impacts.
By proceeding in using this option you accept any impacts including any data loss that may occur as a result of using --force-sync.

Are you sure you wish to proceed with --force-sync [Y/N] 
```

To proceed with using `--force-sync`, you must type 'y' or 'Y' to allow the application to continue.

### Increasing logging level
When running a sync it may be desirable to see additional information as to the progress and operation of the client. To do this, use the following command:
```text
onedrive --synchronize --verbose
```

### Client Activity Log
When running onedrive all actions can be logged to a separate log file. This can be enabled by using the `--enable-logging` flag. By default, log files will be written to `/var/log/onedrive/`

**Note:** You will need to ensure the existence of this directory, and that your user has the applicable permissions to write to this directory or the following warning will be printed:
```text
Unable to access /var/log/onedrive/
Please manually create '/var/log/onedrive/' and set appropriate permissions to allow write access
The requested client activity log will instead be located in the users home directory
```

On many systems this can be achieved by
```text
sudo mkdir /var/log/onedrive
sudo chown root.users /var/log/onedrive
sudo chmod 0775 /var/log/onedrive
```

All log files will be in the format of `%username%.onedrive.log`, where `%username%` represents the user who ran the client.

Additionally, you need to ensure that your user account is part of the 'users' group:
```
cat /etc/group | grep users
```

If your user is not part of this group, then you need to add your user to this group:
```
sudo usermod -a -G users <your-user-name>
```

You then need to 'logout' of all sessions / SSH sessions to login again to have the new group access applied.


**Note:**
To use a different log directory rather than the default above, add the following as a configuration option to `~/.config/onedrive/config`:
```text
log_dir = "/path/to/location/"
```
Trailing slash required

An example of the log file is below:
```text
2018-Apr-07 17:09:32.1162837 Loading config ...
2018-Apr-07 17:09:32.1167908 No config file found, using defaults
2018-Apr-07 17:09:32.1170626 Initializing the OneDrive API ...
2018-Apr-07 17:09:32.5359143 Opening the item database ...
2018-Apr-07 17:09:32.5515295 All operations will be performed in: /root/OneDrive
2018-Apr-07 17:09:32.5518387 Initializing the Synchronization Engine ...
2018-Apr-07 17:09:36.6701351 Applying changes of Path ID: <redacted>
2018-Apr-07 17:09:37.4434282 Adding OneDrive Root to the local database
2018-Apr-07 17:09:37.4478342 The item is already present
2018-Apr-07 17:09:37.4513752 The item is already present
2018-Apr-07 17:09:37.4550062 The item is already present
2018-Apr-07 17:09:37.4586444 The item is already present
2018-Apr-07 17:09:37.7663571 Adding OneDrive Root to the local database
2018-Apr-07 17:09:37.7739451 Fetching details for OneDrive Root
2018-Apr-07 17:09:38.0211861 OneDrive Root exists in the database
2018-Apr-07 17:09:38.0215375 Uploading differences of .
2018-Apr-07 17:09:38.0220464 Processing <redacted>
2018-Apr-07 17:09:38.0224884 The directory has not changed
2018-Apr-07 17:09:38.0229369 Processing <redacted>
2018-Apr-07 17:09:38.02338 The directory has not changed
2018-Apr-07 17:09:38.0237678 Processing <redacted>
2018-Apr-07 17:09:38.0242285 The directory has not changed
2018-Apr-07 17:09:38.0245977 Processing <redacted>
2018-Apr-07 17:09:38.0250788 The directory has not changed
2018-Apr-07 17:09:38.0254657 Processing <redacted>
2018-Apr-07 17:09:38.0259923 The directory has not changed
2018-Apr-07 17:09:38.0263547 Uploading new items of .
2018-Apr-07 17:09:38.5708652 Applying changes of Path ID: <redacted>
```

### Notifications
If notification support is compiled in, the following events will trigger a notification within the display manager session:
*   Aborting a sync if .nosync file is found
*   Cannot create remote directory
*   Cannot upload file changes
*   Cannot delete remote file / folder
*   Cannot move remote file / folder


### Handling a OneDrive account password change
If you change your OneDrive account password, the client will no longer be authorised to sync, and will generate the following error:
```text
ERROR: OneDrive returned a 'HTTP 401 Unauthorized' - Cannot Initialize Sync Engine
```
To re-authorise the client, follow the steps below:
1.   If running the client as a service (init.d or systemd), stop the service
2.   Run the command `onedrive --reauth`. This will clean up the previous authorisation, and will prompt you to re-authorise the client as per initial configuration.
3.   Restart the client if running as a service or perform a manual sync

The application will now sync with OneDrive with the new credentials.

## Configuration

Configuration is determined by three layers: the default values, values set in the configuration file, and values passed in via the command line. The default values provide a reasonable default, and configuration is optional.

Most command line options have a respective configuration file setting.

If you want to change the defaults, you can copy and edit the included config file into your configuration directory. Valid default directories for the config file are:
*   `~/.config/onedrive`
*   `/etc/onedrive`

**Example:**
```text
mkdir -p ~/.config/onedrive
wget https://raw.githubusercontent.com/abraunegg/onedrive/master/config -O ~/.config/onedrive/config
nano ~/.config/onedrive/config
```
This file does not get created by default, and should only be created if you want to change the 'default' operational parameters.

See the [config](https://raw.githubusercontent.com/abraunegg/onedrive/master/config) file for the full list of options, and [All available commands](https://github.com/abraunegg/onedrive/blob/master/docs/USAGE.md#all-available-commands) for all possible keys and their default values.

**Note:** The location of the application configuration information can also be specified by using the `--confdir` configuration option which can be passed in at client run-time.

### The default configuration file is listed below:
```text
# Configuration for OneDrive Linux Client
# This file contains the list of supported configuration fields
# with their default values.
# All values need to be enclosed in quotes
# When changing a config option below, remove the '#' from the start of the line
# For explanations of all config options below see docs/USAGE.md or the man page.
#
# sync_dir = "~/OneDrive"
# skip_file = "~*|.~*|*.tmp"
# monitor_interval = "300"
# skip_dir = ""
# log_dir = "/var/log/onedrive/"
# drive_id = ""
# upload_only = "false"
# check_nomount = "false"
# check_nosync = "false"
# download_only = "false"
# disable_notifications = "false"
# disable_upload_validation = "false"
# enable_logging = "false"
# force_http_11 = "false"
# local_first = "false"
# no_remote_delete = "false"
# skip_symlinks = "false"
# debug_https = "false"
# skip_dotfiles = "false"
# dry_run = "false"
# min_notify_changes = "5"
# monitor_log_frequency = "5"
# monitor_fullscan_frequency = "12"
# sync_root_files = "false"
# classify_as_big_delete = "1000"
# user_agent = ""
# remove_source_files = "false"
# skip_dir_strict_match = "false"
# application_id = ""
# resync = "false"
# resync_auth = "false"
# bypass_data_preservation = "false"
# azure_ad_endpoint = ""
# azure_tenant_id = "common"
# sync_business_shared_folders = "false"
# sync_dir_permissions = "700"
# sync_file_permissions = "600"
# rate_limit = "131072"
# operation_timeout = "3600"
# webhook_enabled = "false"
# webhook_public_url = ""
# webhook_listening_host = ""
# webhook_listening_port = "8888"
# webhook_expiration_interval = "86400"
# webhook_renewal_interval = "43200"
# space_reservation = "50"
```

### 'config' file configuration examples:
The below are 'config' file examples to assist with configuration of the 'config' file:

#### sync_dir
Configure your local sync directory location.

Example:
```text
# When changing a config option below, remove the '#' from the start of the line
# For explanations of all config options below see docs/USAGE.md or the man page.
#
sync_dir="~/MyDirToSync"
# skip_file = "~*|.~*|*.tmp"
# monitor_interval = "300"
# skip_dir = ""
# log_dir = "/var/log/onedrive/"
```
**Please Note:**
Proceed with caution here when changing the default sync dir from `~/OneDrive` to `~/MyDirToSync`

The issue here is around how the client stores the sync_dir path in the database. If the config file is missing, or you don't use the `--syncdir` parameter - what will happen is the client will default back to `~/OneDrive` and 'think' that either all your data has been deleted - thus delete the content on OneDrive, or will start downloading all data from OneDrive into the default location.

**Note:** After changing `sync_dir`, you must perform a full re-synchronization by adding `--resync` to your existing command line - for example: `onedrive --synchronize --resync`

**Important Note:** If your `sync_dir` is pointing to a network mount point (a network share via NFS, Windows Network Share, Samba Network Share) these types of network mount points do not support 'inotify', thus tracking real-time changes via inotify of local files is not possible. Local filesystem changes will be replicated between the local filesystem and OneDrive based on the `monitor_interval` value. This is not something (inotify support for NFS, Samba) that this client can fix.

#### sync_dir directory and file permissions
The following are directory and file default permissions for any new directory or file that is created:
*   Directories: 700 - This provides the following permissions: `drwx------`
*   Files: 600 - This provides the following permissions: `-rw-------`

To change the default permissions, update the following 2 configuration options with the required permissions. Utilise the [Unix Permissions Calculator](https://chmod-calculator.com/) to assist in determining the required permissions.

```text
# When changing a config option below, remove the '#' from the start of the line
# For explanations of all config options below see docs/USAGE.md or the man page.
#
...
# sync_business_shared_folders = "false"
sync_dir_permissions = "700"
sync_file_permissions = "600"

```

**Important:** Special permission bits (setuid, setgid, sticky bit) are not supported. Valid permission values are from `000` to `777` only.

#### skip_dir
This option is used to 'skip' certain directories and supports pattern matching.

Patterns are case insensitive. `*` and `?` [wildcards characters](https://technet.microsoft.com/en-us/library/bb490639.aspx) are supported. Use `|` to separate multiple patterns.

**Important:** Entries under `skip_dir` are relative to your `sync_dir` path.

Example:
```text
# When changing a config option below, remove the '#' from the start of the line
# For explanations of all config options below see docs/USAGE.md or the man page.
#
# sync_dir = "~/OneDrive"
# skip_file = "~*|.~*|*.tmp"
# monitor_interval = "300"
skip_dir = "Desktop|Documents/IISExpress|Documents/SQL Server Management Studio|Documents/Visual Studio*|Documents/WindowsPowerShell"
# log_dir = "/var/log/onedrive/"
```

**Note:** The `skip_dir` can be specified multiple times, for example:
```text
skip_dir = "SomeDir|OtherDir|ThisDir|ThatDir"
skip_dir = "/Path/To/A/Directory"
skip_dir = "/Another/Path/To/Different/Directory"
```
This will be interpreted the same as:
```text
skip_dir = "SomeDir|OtherDir|ThisDir|ThatDir|/Path/To/A/Directory|/Another/Path/To/Different/Directory"
```

**Note:** After changing `skip_dir`, you must perform a full re-synchronization by adding `--resync` to your existing command line - for example: `onedrive --synchronize --resync`

#### skip_file
This option is used to 'skip' certain files and supports pattern matching.

Patterns are case insensitive. `*` and `?` [wildcards characters](https://technet.microsoft.com/en-us/library/bb490639.aspx) are supported. Use `|` to separate multiple patterns.

Files can be skipped in the following fashion:
*   Specify a wildcard, eg: '*.txt' (skip all txt files)
*   Explicitly specify the filename and it's full path relative to your sync_dir, eg: 'path/to/file/filename.ext'
*   Explicitly specify the filename only and skip every instance of this filename, eg: 'filename.ext'

By default, the following files will be skipped:
*   Files that start with ~
*   Files that start with .~ (like .~lock.* files generated by LibreOffice)
*   Files that end in .tmp

**Important:** Do not use a skip_file entry of `.*` as this will prevent correct searching of local changes to process.

Example:
```text
# When changing a config option below, remove the '#' from the start of the line
# For explanations of all config options below see docs/USAGE.md or the man page.
#
# sync_dir = "~/OneDrive"
skip_file = "~*|Documents/OneNote*|Documents/config.xlaunch|myfile.ext"
# monitor_interval = "300"
# skip_dir = ""
# log_dir = "/var/log/onedrive/"
```

**Note:** The `skip_file` can be specified multiple times, for example:
```text
skip_file = "~*|.~*|*.tmp|*.swp"
skip_file = "*.blah"
skip_file = "never_sync.file"
```
This will be interpreted the same as:
```text
skip_file = "~*|.~*|*.tmp|*.swp|*.blah|never_sync.file"
```

**Note:** after changing `skip_file`, you must perform a full re-synchronization by adding `--resync` to your existing command line - for example: `onedrive --synchronize --resync`

#### skip_dotfiles
Setting this to `"true"` will skip all .files and .folders while syncing.

Example:
```text
# skip_symlinks = "false"
# debug_https = "false"
skip_dotfiles = "true"
# dry_run = "false"
# monitor_interval = "300"
```

#### monitor_interval
The monitor interval is defined as the wait time 'between' sync's when running in monitor mode. When this interval expires, the client will check OneDrive for changes online, performing data integrity checks and scanning the local 'sync_dir' for new content.

By default without configuration, 'monitor_interval' is set to 300 seconds. Setting this value to 600 will run the sync process every 10 minutes.

Example:
```text
# skip_dotfiles = "false"
# dry_run = "false"
monitor_interval = "600"
# min_notify_changes = "5"
# monitor_log_frequency = "5"
```

#### monitor_fullscan_frequency
This configuration option controls the number of 'monitor_interval' iterations between when a full scan of your data is performed to ensure data integrity and consistency.

By default without configuration, 'monitor_fullscan_frequency' is set to 12. In this default state, this means that a full scan is performed every 'monitor_interval' x 'monitor_fullscan_frequency' = 3600 seconds. This is only applicable when running in --monitor mode.

Setting this value to 24 means that the full scan of OneDrive and checking the integrity of the data stored locally will occur every 2 hours (assuming 'monitor_interval' is set to 300 seconds):

Example:
```text
# min_notify_changes = "5"
# monitor_log_frequency = "5"
monitor_fullscan_frequency = "24"
# sync_root_files = "false"
# classify_as_big_delete = "1000"
```

**Note:** When running in --monitor mode, at application start-up, a full scan will be performed to ensure data integrity. This option has zero effect when running the application in --synchronize mode and a full scan will always be performed.

#### min_notify_changes
This option defines the minimum number of pending incoming changes necessary to trigger a desktop notification. This allows controlling the frequency of notifications.

Example:
```text
# dry_run = "false"
# monitor_interval = "300"
min_notify_changes = "50"
# monitor_log_frequency = "5"
# monitor_fullscan_frequency = "12"
```

#### operation_timeout
Operation Timeout is the maximum amount of time (seconds) a file operation is allowed to take. This includes DNS resolution, connecting, data transfer, etc.

Example:
```text
# sync_file_permissions = "600"
# rate_limit = "131072"
operation_timeout = "3600"
```

#### Configuring the client for 'single tenant application' use
In some instances when using OneDrive Business Accounts, depending on the Azure organisational configuration, it will be necessary to configure the client as a 'single tenant application'.
To configure this, after creating the application on your Azure tenant, update the 'config' file with the tenant name (not the GUID) and the newly created Application ID, then this will be used for the authentication process.
```text
# skip_dir_strict_match = "false"
application_id = "your.application.id.guid"
# resync = "false"
# bypass_data_preservation = "false"
# azure_ad_endpoint = "xxxxxx"
azure_tenant_id = "your.azure.tenant.name"
# sync_business_shared_folders = "false"
```

#### Configuring the client to use older 'skilion' application identifier
In some instances it may be desirable to utilise the older 'skilion' application identifier to avoid authorising a new application ID within Microsoft Azure environments.
To configure this, update the 'config' file with the old Application ID, then this will be used for the authentication process.
```text
# skip_dir_strict_match = "false"
application_id = "22c49a0d-d21c-4792-aed1-8f163c982546"
# resync = "false"
# bypass_data_preservation = "false"
```
**Note:** The application will now use the older 'skilion' client identifier, however this may increase your chances of getting a OneDrive 429 error.

**Note:** After changing the 'application_id' you will need to restart any 'onedrive' process you have running, and potentially issue a `--reauth` to re-authenticate the client with this updated application ID.

## Frequently Asked Configuration Questions

### How to sync only specific or single directory?
There are two methods to achieve this:
*   Utilise '--single-directory' option to only sync this specific path
*   Utilise 'sync_list' to configure what files and directories to sync, and what should be exluded

### How to 'skip' directories from syncing?
There are several mechanisms available to 'skip' a directory from the sync process:
*   Utilise 'skip_dir' to configure what directories to skip. Refer to above for configuration advice.
*   Utilise 'sync_list' to configure what files and directories to sync, and what should be exluded

One further method is to add a '.nosync' empty file to any folder. When this file is present, adding `--check-for-nosync` to your command line will now make the sync process skip any folder where the '.nosync' file is present.

To make this a permanent change to always skip folders when a '.nosync' empty file is present, add the following to your config file:

Example:
```text
# upload_only = "false"
# check_nomount = "false"
check_nosync = "true"
# download_only = "false"
# disable_notifications = "false"
```

### How to 'skip' files from syncing?
There are two methods to achieve this:
*   Utilise 'skip_file' to configure what files to skip. Refer to above for configuration advice.
*   Utilise 'sync_list' to configure what files and directories to sync, and what should be exluded

### How to 'rate limit' the application to control bandwidth consumed for upload & download operations?
To minimise the Internet bandwidth for upload and download operations, you can configure the 'rate_limit' option within the config file.

Example valid values for this are as follows:
* 131072 	= 128 KB/s - minimum for basic application operations to prevent timeouts
* 262144 	= 256 KB/s
* 524288	= 512 KB/s
* 1048576 	= 1 MB/s
* 10485760 	= 10 MB/s
* 104857600 = 100 MB/s

Example:
```text
# sync_business_shared_folders = "false"
# sync_dir_permissions = "700"
# sync_file_permissions = "600"
rate_limit = "131072"
```

**Note:** A number greater than '131072' is a valid value, with '104857600' being tested as an upper limit.

### How to prevent your local disk from filling up?
By default, the application will reserve 50MB of disk space to prevent your filesystem to run out of disk space. This value can be modified by adding the following to your config file:

Example:
```text
...
# webhook_expiration_interval = "86400"
# webhook_renewal_interval = "43200"
space_reservation = "10"
```

The value entered is in MB (Mega Bytes). In this example, a value of 10MB is being used, and will be converted to bytes by the application. The value being used can be reviewed when using `--display-config`:
```
Config option 'sync_dir_permissions'         = 700
Config option 'sync_file_permissions'        = 600
Config option 'space_reservation'            = 10485760
Config option 'application_id'               = 
Config option 'azure_ad_endpoint'            = 
Config option 'azure_tenant_id'              = common
```

Any value is valid here, however, if you use a value of '0' a value of '1' will actually be used, so that you actually do not run out of disk space.

### How are symbolic links handled by the client?
Microsoft OneDrive has zero concept or understanding of symbolic links, and attempting to upload a symbolic link to Microsoft OneDrive generates a platform API error. All data (files and folders) that are uploaded to OneDrive must be whole files or actual directories.

As such, there are only two methods to support symbolic links with this client:
1. Follow the Linux symbolic link and upload what ever the link is pointing at to OneDrive. This is the default behaviour.
2. Skip symbolic links by configuring the application to do so. In skipping, no data, no link, no reference is uploaded to OneDrive.

To skip symbolic links, edit your configuration as per below:

```text
# local_first = "false"
# no_remote_delete = "false"
skip_symlinks = "true"
# debug_https = "false"
# skip_dotfiles = "false"
```
Setting this to `"true"` will configure the client to skip all symbolic links while syncing.

The default setting is `"false"` which will sync the whole folder structure referenced by the symbolic link, duplicating the contents on OneDrive in the place where the symbolic link is.

### How to sync shared folders (OneDrive Personal)?
Folders shared with you can be synced by adding them to your OneDrive. To do that open your Onedrive, go to the Shared files list, right click on the folder you want to sync and then click on "Add to my OneDrive".

### How to sync shared folders (OneDrive Business or Office 365)?
Refer to [./BusinessSharedFolders.md](BusinessSharedFolders.md) for configuration assistance.

Do not use the 'Add shortcut to My files' from the OneDrive web based interface to add a 'shortcut' to your shared folder. This shortcut is not supported by the OneDrive API, thus it cannot be used.

### How to sync sharePoint / Office 365 Shared Libraries?
Refer to [./SharePoint-Shared-Libraries.md](SharePoint-Shared-Libraries.md) for configuration assistance.

## Running 'onedrive' in 'monitor' mode
Monitor mode (`--monitor`) allows the onedrive process to continually monitor your local file system for changes to files.

Two common errors can occur when using monitor mode:
*   Intialisation failure
*   Unable to add a new inotify watch

Both of these errors are local environment issues, where the following system variables need to be increased as the current system values are potentially too low:
*   `fs.file-max`
*   `fs.inotify.max_user_watches`

To determine what these values are on your system use the following commands:
```
sysctl fs.file-max
sysctl fs.inotify.max_user_watches
```

To make a change to these variables:
```
sudo sysctl fs.file-max=<new_value>
sudo sysctl fs.inotify.max_user_watches=<new_value>
```

To make these changes permanent, refer to your OS reference documentation.

### Use webhook to subscribe to remote updates in 'monitor' mode

A webhook can be optionally enabled in the monitor mode to allow the onedrive process to subscribe to remote updates. Remote changes can be synced to your local file system as soon as possible, without waiting for the next sync cycle.

To enable this feature, you need to configure the following options in the config file:

```
webhook_enabled = "true"
webhook_public_url = "<public-facing url to reach your webhook>"
```

Setting `webhook_enabled` to `true` enables the webhook in 'monitor' mode. The onedrive process will listen for incoming updates at a configurable endpoint, which defaults to `0.0.0.0:8888`. The `webhook_public_url` must be set to an public-facing url for Microsoft to send updates to your webhook. If your host is directly exposed to the Internet, the `webhook_public_url` can be set to `http://<your_host_ip>:8888/` to match the default endpoint. However, the recommended approach is to configure a reverse proxy like nginx.

**Note:** A valid HTTPS certificate is required for your public-facing URL if using nginx.

For example, below is a nginx config snippet to proxy traffic into the webhook:

```
server {
	listen 80;
	location /webhooks/onedrive {
		proxy_pass http://127.0.0.1:8888;
	}
}
```

With nginx running, you can configure `webhook_public_url` to `https://<your_host>/webhooks/onedrive`.

### More webhook configuration options

Below options can be optionally configured. The default is usually good enough.

#### webhook_listening_host and webhook_listening_port

Set `webhook_listening_host` and `webhook_listening_port` to change the webhook listening endpoint. If `webhook_listening_host` is left empty, which is the default, the webhook will bind to `0.0.0.0`. The default `webhook_listening_port` is `8888`.

```
webhook_listening_host = ""
webhook_listening_port = "8888"
```

#### webhook_expiration_interval and webhook_renewal_interval

Set `webhook_expiration_interval` and `webhook_renewal_interval` to change the frequency of subscription renewal. By default, the webhook asks Microsoft to keep subscriptions alive for 24 hours, and it renews subscriptions when it is less than 12 hours before their expiration.

```
# Default expiration interval is 24 hours
webhook_expiration_interval = "86400"

# Default renewal interval is 12 hours
webhook_renewal_interval = "43200"
```

## Running 'onedrive' as a system service
There are a few ways to use onedrive as a service
*   via init.d
*   via systemd
*   via runit

**Note:** If using the service files, you may need to increase the `fs.inotify.max_user_watches` value on your system to handle the number of files in the directory you are monitoring as the initial value may be too low.

### OneDrive service running as root user via init.d
```text
chkconfig onedrive on
service onedrive start
```
To see the logs run:
```text
tail -f /var/log/onedrive/<username>.onedrive.log
```
To change what 'user' the client runs under (by default root), manually edit the init.d service file and modify `daemon --user root onedrive_service.sh` for the correct user.

### OneDrive service running as root user via systemd (Arch, Ubuntu, Debian, OpenSuSE, Fedora)
First, su to root using `su - root`, then enable the systemd service:
```text
systemctl --user enable onedrive
systemctl --user start onedrive
```
**Note:** `systemctl --user` directive is not applicable for Red Hat Enterprise Linux (RHEL) or CentOS Linux platforms - see below.

**Note:** This will run the 'onedrive' process with a UID/GID of '0', thus, any files or folders that are created will be owned by 'root'

To see the systemd application logs run:
```text
journalctl --user-unit=onedrive -f
```

**Note:** It is a 'systemd' requirement that the XDG environment variables exist for correct enablement and operation of systemd services. If you receive this error when enabling the systemd service:
```
Failed to connect to bus: No such file or directory
```
The most likely cause is that the XDG environment variables are missing. To fix this, you must add the following to `.bashrc` or any other file which is run on user login:
```
export XDG_RUNTIME_DIR="/run/user/$UID"
export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
```

To make this change effective, you must logout of all user accounts where this change has been made.

**Note:** On some systems (for example - Raspbian / Ubuntu / Debian on Raspberry Pi) the above XDG fix may not be reliable after system reboots. The potential alternative to start the client via systemd as root, is to perform the following:
1.  Create a symbolic link from `/home/root/.config/onedrive` pointing to `/root/.config/onedrive/`
2.  Create a systemd service using the '@' service file: `systemctl enable onedrive@root.service`
3.  Start the root@service: `systemctl start onedrive@root.service`

This will ensure that the service will correctly restart on system reboot.

To see the systemd application logs run:
```text
journalctl --unit=onedrive@<username> -f
```

### OneDrive service running as root user via systemd (Red Hat Enterprise Linux, CentOS Linux)
```text
systemctl enable onedrive
systemctl start onedrive
```
**Note:** This will run the 'onedrive' process with a UID/GID of '0', thus, any files or folders that are created will be owned by 'root'

To see the systemd application logs run:
```text
journalctl --unit=onedrive -f
```

### OneDrive service running as a non-root user via systemd (All Linux Distributions)
In some cases it is desirable to run the OneDrive client as a service, but not running as the 'root' user. In this case, follow the directions below to configure the service for your normal user login.

1.  As the user, who will be running the service, run the application in standalone mode, authorize the application for use & validate that the synchronization is working as expected:
```text
onedrive --synchronize --verbose
```
2.  Once the application is validated and working for your user, as the 'root' user, where <username> is your username from step 1 above.
```text
systemctl enable onedrive@<username>.service
systemctl start onedrive@<username>.service
```
3.  To view the status of the service running for the user, use the following:
```text
systemctl status onedrive@<username>.service
```

To see the systemd application logs run:
```text
journalctl --unit=onedrive@<username> -f
```

### OneDrive service running as a non-root user via systemd (with notifications enabled) (Arch, Ubuntu, Debian, OpenSuSE, Fedora)
In some cases you may wish to receive GUI notifications when using the client when logged in as a non-root user. In this case, follow the directions below:

1. Login via graphical UI as user you wish to enable the service for
2. Disable any `onedrive@` service files for your username - eg:
```text
sudo systemctl stop onedrive@alex.service
sudo systemctl disable onedrive@alex.service
```
3. Enable service as per the following:
```text
systemctl --user enable onedrive
systemctl --user start onedrive
```

To see the systemd application logs run:
```text
journalctl --user-unit=onedrive -f
```

**Note:** `systemctl --user` directive is not applicable for Red Hat Enterprise Linux (RHEL) or CentOS Linux platforms

### OneDrive service running as a non-root user via runit (antiX, Devuan, Artix, Void)

1. Create the following folder if not present already `/etc/sv/runsvdir-<username>`

  - where `<username>` is the `USER` targeted for the service
  - _e.g_ `# mkdir /etc/sv/runsvdir-nolan`

2. Create a file called `run` under the previously created folder with
   executable permissions

   - `# touch /etc/sv/runsvdir-<username>/run`
   - `# chmod 0755 /etc/sv/runsvdir-<username>/run`

3. Edit the `run` file with the following contents (priviledges needed)

  ```sh
  #!/bin/sh
  export USER="<username>"
  export HOME="/home/<username>"

  groups="$(id -Gn "${USER}" | tr ' ' ':')"
  svdir="${HOME}/service"

  exec chpst -u "${USER}:${groups}" runsvdir "${svdir}"
  ```

  - do not forget to correct the `<username>` according to the `USER` set on
    step #1

4. Enable the previously created folder as a service

  - `# ln -fs /etc/sv/runsvdir-<username> /var/service/`

5. Create a subfolder on the `USER`'s `HOME` directory to store the services
   (or symlinks)

   - `$ mkdir ~/service`

6. Create a subfolder for OneDrive specifically

  - `$ mkdir ~/service/onedrive/`

7. Create a file called `run` under the previously created folder with
   executable permissions

   - `$ touch ~/service/onedrive/run`
   - `$ chmod 0755 ~/service/onedrive/run`

8. Append the following contents to the `run` file

  ```sh
  #!/usr/bin/env sh
  exec /usr/bin/onedrive --monitor
  ```

  - in some scenario the path for the `onedrive` binary might differ, you can
    obtain it regardless by running `$ command -v onedrive`

9. Reboot to apply changes

10. Check status of user-defined services

  - `$ sv status ~/service/*`

You may refer to Void's documentation regarding
[Per-User Services](https://docs.voidlinux.org/config/services/user-services.html)
for extra details.

## Additional Configuration
### Advanced Configuration of the OneDrive Free Client
*   Configuring the client to use mulitple OneDrive accounts / configurations
*   Configuring the client for use in dual-boot (Windows / Linux) situations
*   Configuring the client for use when 'sync_dir' is a mounted directory
*   Upload data from the local ~/OneDrive folder to a specific location on OneDrive

Refer to [./advanced-usage.md](advanced-usage.md) for configuration assistance.

### Access OneDrive service through a proxy
If you have a requirement to run the client through a proxy, there are a couple of ways to achieve this:
1.  Set proxy configuration in `~/.bashrc` to allow the authorization process and when utilizing `--synchronize`
2.  If running as a systemd service, edit the applicable systemd service file to include the proxy configuration information:
```text
[Unit]
Description=OneDrive Free Client
Documentation=https://github.com/abraunegg/onedrive
After=network-online.target
Wants=network-online.target

[Service]
Environment="HTTP_PROXY=http://ip.address:port"
Environment="HTTPS_PROXY=http://ip.address:port"
ExecStart=/usr/local/bin/onedrive --monitor
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
```

**Note:** After modifying the service files, you will need to run `sudo systemctl daemon-reload` to ensure the service file changes are picked up. A restart of the OneDrive service will also be required to pick up the change to send the traffic via the proxy server

### Setup selinux for a sync folder outside of the home folder
If selinux is enforced and the sync folder is outside of the home folder, as long as there is no policy for cloud fileservice providers, label the file system folder to user_home_t.
```text
sudo semanage fcontext -a -t user_home_t /path/to/onedriveSyncFolder
sudo restorecon -R -v /path/to/onedriveSyncFolder
```
To remove this change from selinux and restore the default behaivor:
```text
sudo semanage fcontext -d /path/to/onedriveSyncFolder
sudo restorecon -R -v /path/to/onedriveSyncFolder
```

## All available commands
Output of `onedrive --help`
```text
OneDrive - a client for OneDrive Cloud Services

Usage:
  onedrive [options] --synchronize
      Do a one time synchronization
  onedrive [options] --monitor
      Monitor filesystem and sync regularly
  onedrive [options] --display-config
      Display the currently used configuration
  onedrive [options] --display-sync-status
      Query OneDrive service and report on pending changes
  onedrive -h | --help
      Show this help screen
  onedrive --version
      Show version

Options:

  --auth-files ARG
      Perform authorization via two files passed in as ARG in the format `authUrl:responseUrl`
      The authorization URL is written to the `authUrl`, then onedrive waits for the file `responseUrl`
      to be present, and reads the response from that file.
  --auth-response ARG
      Perform authentication not via interactive dialog but via providing the response url directly.
  --check-for-nomount
      Check for the presence of .nosync in the syncdir root. If found, do not perform sync.
  --check-for-nosync
      Check for the presence of .nosync in each directory. If found, skip directory from sync.
  --classify-as-big-delete
      Number of children in a path that is locally removed which will be classified as a 'big data delete'
  --confdir ARG
      Set the directory used to store the configuration files
  --create-directory ARG
      Create a directory on OneDrive - no sync will be performed.
  --create-share-link ARG
      Create a shareable link for an existing file on OneDrive
  --debug-https
      Debug OneDrive HTTPS communication.
  --destination-directory ARG
      Destination directory for renamed or move on OneDrive - no sync will be performed.
  --disable-download-validation
      Disable download validation when downloading from OneDrive
  --disable-notifications
      Do not use desktop notifications in monitor mode.
  --disable-upload-validation
      Disable upload validation when uploading to OneDrive
  --display-config
      Display what options the client will use as currently configured - no sync will be performed.
  --display-sync-status
      Display the sync status of the client - no sync will be performed.
  --download-only
      Replicate the OneDrive online state locally, by only downloading changes from OneDrive. Do not upload local changes to OneDrive.
  --dry-run
      Perform a trial sync with no changes made
  --enable-logging
      Enable client activity to a separate log file
  --force
      Force the deletion of data when a 'big delete' is detected
  --force-http-11
      Force the use of HTTP 1.1 for all operations
  --force-sync
      Force a synchronization of a specific folder, only when using --single-directory and ignoring all non-default skip_dir and skip_file rules
  --get-O365-drive-id ARG
      Query and return the Office 365 Drive ID for a given Office 365 SharePoint Shared Library
  --get-file-link ARG
      Display the file link of a synced file
  --help -h
      This help information.
  --list-shared-folders
      List OneDrive Business Shared Folders
  --local-first
      Synchronize from the local directory source first, before downloading changes from OneDrive.
  --log-dir ARG
      Directory where logging output is saved to, needs to end with a slash.
  --logout
      Logout the current user
  --min-notify-changes ARG
      Minimum number of pending incoming changes necessary to trigger a desktop notification
  --modified-by ARG
      Display the last modified by details of a given path
  --monitor -m
      Keep monitoring for local and remote changes
  --monitor-fullscan-frequency ARG
      Number of sync runs before performing a full local scan of the synced directory
  --monitor-interval ARG
      Number of seconds by which each sync operation is undertaken when idle under monitor mode.
  --monitor-log-frequency ARG
      Frequency of logging in monitor mode
  --no-remote-delete
      Do not delete local file 'deletes' from OneDrive when using --upload-only
  --operation-timeout
      Maximum amount of time (in seconds) an operation is allowed to take
  --print-token
      Print the access token, useful for debugging
  --reauth
      Reauthenticate the client with OneDrive
  --remove-directory ARG
      Remove a directory on OneDrive - no sync will be performed.
  --remove-source-files
      Remove source file after successful transfer to OneDrive when using --upload-only
  --resync
      Forget the last saved state, perform a full sync
  --resync-auth
      Approve the use of performing a --resync action
  --single-directory ARG
      Specify a single local directory within the OneDrive root to sync.
  --skip-dir ARG
      Skip any directories that match this pattern from syncing
  --skip-dir-strict-match
      When matching skip_dir directories, only match explicit matches
  --skip-dot-files
      Skip dot files and folders from syncing
  --skip-file ARG
      Skip any files that match this pattern from syncing
  --skip-size ARG
      Skip new files larger than this size (in MB)
  --skip-symlinks
      Skip syncing of symlinks
  --source-directory ARG
      Source directory to rename or move on OneDrive - no sync will be performed.
  --space-reservation ARG
      The amount of disk space to reserve (in MB) to avoid 100% disk space utilisation
  --sync-root-files
      Sync all files in sync_dir root when using sync_list.
  --sync-shared-folders
      Sync OneDrive Business Shared Folders
  --syncdir ARG
      Specify the local directory used for synchronization to OneDrive
  --synchronize
      Perform a synchronization
  --upload-only
      Replicate the locally configured sync_dir state to OneDrive, by only uploading local changes to OneDrive. Do not download changes from OneDrive.
  --user-agent ARG
      Specify a User Agent string to the http client
  --verbose -v+
      Print more details, useful for debugging (repeat for extra debugging)
  --version
      Print the version and exit
```
