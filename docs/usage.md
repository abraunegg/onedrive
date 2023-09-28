# Using the OneDrive Client for Linux
## Application Version
Before reading this document, please ensure you are running application version [![Version](https://img.shields.io/github/v/release/abraunegg/onedrive)](https://github.com/abraunegg/onedrive/releases) or greater. Use `onedrive --version` to determine what application version you are using and upgrade your client if required.

## Table of Contents
TABLE OF CONTENTS GOES HERE

## Important Notes
### Upgrading from the 'skilion' Client
The 'skilion' version has a significant number of issues in how it manages the local sync state. When upgrading from the 'skilion' client to this client, it's recommended to stop any service or OneDrive process that may be running. Once all OneDrive services are stopped, make sure to remove any old client binaries from your system.

Furthermore, if you're using a 'config' file within your configuration directory (`~/.config/onedrive/`), please ensure that you update the `skip_file = ` option as shown below:

**Invalid 'skilion' configuration:**
```text
skip_file = ".*|~*"
```
**Minimum valid configuration:**
```text
skip_file = "~*"
```
**Default valid configuration:**
```text
skip_file = "~*|.~*|*.tmp|*.swp|*.partial"
```

Avoid using a 'skip_file' entry of `.*` as it may prevent the correct detection of local changes to process. The configuration values for 'skip_file' will be checked for validity, and if there is an issue, the following error message will be displayed:
```text
ERROR: Invalid skip_file entry '.*' detected
```

### Naming Conventions for Local Files and Folders
In the synchronisation directory, it's crucial to adhere to the [Windows naming conventions](https://docs.microsoft.com/windows/win32/fileio/naming-a-file) for your files and folders. 

If you happen to have two files with the same names but different capitalisation, our application will make an effort to handle it. However, when there's a clash within the namespace, the file causing the conflict won't be synchronised. Please note that this behaviour is intentional and won't be addressed.

### Compatibility with curl
If your system uses curl < 7.47.0, curl will default to HTTP/1.1 for HTTPS operations, and the client will follow suit, using HTTP/1.1.

For systems running curl >= 7.47.0 and < 7.62.0, curl will prefer HTTP/2 for HTTPS, but it will still use HTTP/1.1 as the default for these operations. The client will employ HTTP/1.1 for HTTPS operations as well.

However, if your system employs curl >= 7.62.0, curl will, by default, prioritise HTTP/2 over HTTP/1.1. In this case, the client will utilise HTTP/2 for most HTTPS operations and stick with HTTP/1.1 for others. Please note that this distinction is governed by the OneDrive platform, not our client.

If you explicitly want to use HTTP/1.1, you can do so by using the `--force-http-11` flag or setting the configuration option `force_http_11 = "true"`. This will compel the application to exclusively use HTTP/1.1. Otherwise, all client operations will align with the curl default settings for your distribution.

## First Steps
### Authorise the Application with Your Microsoft OneDrive Account
Once you've installed the application, you'll need to authorise it using your Microsoft OneDrive Account. This can be done by simply running the application without any additional command switches.

Please be aware that some companies may require you to explicitly add this app to the [Microsoft MyApps portal](https://myapps.microsoft.com/). To add an approved app to your apps, click on the ellipsis in the top-right corner and select "Request new apps." On the next page, you can add this app. If it's not listed, you should make a request through your IT department.

When you run the application for the first time, you'll be prompted to open a specific URL using your web browser, where you'll need to log in to your Microsoft Account and grant the application permission to access your files. After granting permission to the application, you'll be redirected to a blank page. Simply copy the URI from the blank page and paste it into the application.

**Example:**
```text
[user@hostname ~]$ onedrive
Authorise this app by visiting:

https://login.microsoftonline.com/common/oauth2/v2.0/authorise?client_id=22c49a0d-d21c-4792-aed1-8f163c982546&scope=Files.ReadWrite%20Files.ReadWrite.all%20Sites.ReadWrite.All%20offline_access&response_type=code&redirect_uri=https://login.microsoftonline.com/common/oauth2/nativeclient

Enter the response URI from your browser:  https://login.microsoftonline.com/common/oauth2/nativeclient?code=<redacted>

The application has been successfully authorised, but no additional command switches were provided.

Please use 'onedrive --help' for further assistance on how to run this application.
```

### Display Your Applicable Runtime Configuration
To verify the configuration that the application will use, use the following command:
```text
onedrive --display-config
```
This command will display all the relevant runtime interpretations of the options and configurations you are using. An example output is as follows:
```text
Reading configuration file: /home/user/.config/onedrive/config
Configuration file successfully loaded
onedrive version                             = vX.Y.Z-A-bcdefghi
Config path                                  = /home/user/.config/onedrive
Config file found in config path             = true
Config option 'drive_id'                     = 
Config option 'sync_dir'                     = ~/OneDrive
...
Config option 'webhook_enabled'              = false
```

### Understanding OneDrive Client for Linux Operational Modes
There are two modes of operation when using the client:
1. Standalone sync mode that performs a single sync action against Microsoft OneDrive.
2. Ongoing sync mode that continuously syncs your data with Microsoft OneDrive.

#### Standalone Synchronisation Operational Mode (Standalone Mode)
This method of use can be employed by issuing the following option to the client:
```text
onedrive --sync
```
For simplicity, this can be reduced to the following:
```text
onedrive -s
```

#### Ongoing Synchronisation Operational Mode (Monitor Mode)
This method of use can be utilised by issuing the following option to the client:
```text
onedrive --monitor
```
For simplicity, this can be shortened to the following:
```text
onedrive -m
```
**Note:** This method of use is typically employed when enabling a systemd service to run the application in the background.

Two common errors can occur when using monitor mode:
*   Initialisation failure
*   Unable to add a new inotify watch

Both of these errors are local environment issues, where the following system variables need to be increased as the current system values are potentially too low:
*   `fs.file-max`
*   `fs.inotify.max_user_watches`

To determine what the existing values are on your system, use the following commands:
```text
sysctl fs.file-max
sysctl fs.inotify.max_user_watches
```
Alternatively, when running the client with increased verbosity (see below), the client will display what the current configured system maximum values are:
```text
...
All application operations will be performed in: /home/user/OneDrive
OneDrive synchronisation interval (seconds): 300
Maximum allowed open files:                 393370   <-- This is the fs.file-max value
Maximum allowed inotify watches:            29374    <-- This is the fs.inotify.max_user_watches value
Initialising filesystem inotify monitoring ...
...
```
To determine what value to change to, you need to count all the files and folders in your configured 'sync_dir':
```text
cd /path/to/your/sync/dir
ls -laR | wc -l
```

To make a change to these variables using your file and folder count, use the following process:
```text
sudo sysctl fs.file-max=<new_value>
sudo sysctl fs.inotify.max_user_watches=<new_value>
```
Once these values are changed, you will need to restart your client so that the new values are detected and used.

To make these changes permanent on your system, refer to your OS reference documentation.

### Increasing application logging level
When running a sync (`--sync`) or using monitor mode (`--monitor`), it may be desirable to see additional information regarding the progress and operation of the client. For example, for a `--sync` command, this would be:
```text
onedrive --sync --verbose
```
Furthermore, for simplicity, this can be simplified to the following:
```
onedrive -s -v
```
Adding `--verbose` twice will enable debug logging output. This is generally required when raising a bug report or needing to understand a problem.

### Testing your configuration
You can test your configuration by utilising the `--dry-run` CLI option. No files will be downloaded, uploaded, or removed; however, the application will display what 'would' have occurred. For example:
```text
onedrive --sync --verbose --dry-run
Reading configuration file: /home/user/.config/onedrive/config
Configuration file successfully loaded
Using 'user' Config Dir: /home/user/.config/onedrive
DRY-RUN Configured. Output below shows what 'would' have occurred.
DRY-RUN: Copying items.sqlite3 to items-dryrun.sqlite3 to use for dry run operations
DRY RUN: Not creating backup config file as --dry-run has been used
DRY RUN: Not updating hash files as --dry-run has been used
Checking Application Version ...
Attempting to initialise the OneDrive API ...
Configuring Global Azure AD Endpoints
The OneDrive API was initialised successfully
Opening the item database ...
Sync Engine Initialised with new Onedrive API instance
Application version:  vX.Y.Z-A-bcdefghi
Account Type:         <account-type>
Default Drive ID:     <drive-id>
Default Root ID:      <root-id>
Remaining Free Space: 1058488129 KB
All application operations will be performed in: /home/user/OneDrive
Fetching items from the OneDrive API for Drive ID: <drive-id> ..
...
Performing a database consistency and integrity check on locally stored data ... 
Processing DB entries for this Drive ID: <drive-id>
Processing ~/OneDrive
The directory has not changed
...
Scanning local filesystem '~/OneDrive' for new data to upload ...
...
Performing a final true-up scan of online data from OneDrive
Fetching items from the OneDrive API for Drive ID: <drive-id> ..

Sync with Microsoft OneDrive is complete
```

### Performing a sync with Microsoft OneDrive
By default, all files are downloaded in `~/OneDrive`. This download location is controlled by the 'sync_dir' config option.

After authorising the application, a sync of your data can be performed by running:
```text
onedrive --sync
```
This will synchronise files from your Microsoft OneDrive account to your `~/OneDrive` local directory or to your specified 'sync_dir' location.

If you prefer to use your local files as stored in `~/OneDrive` as your 'source of truth,' use the following sync command:
```text
onedrive --sync --local-first
```

### Performing a single directory synchronisation with Microsoft OneDrive
In some cases, it may be desirable to synchronise a single directory under ~/OneDrive without having to change your client configuration. To do this, use the following command:
```text
onedrive --sync --single-directory '<dir_name>'
```

**Example:** If the full path is `~/OneDrive/mydir`, the command would be `onedrive --sync --single-directory 'mydir'`

### Performing a 'one-way' download synchronisation with Microsoft OneDrive
In some cases, it may be desirable to 'download only' from Microsoft OneDrive. To do this, use the following command:
```text
onedrive --sync --download-only
```
This will download all the content from Microsoft OneDrive to your `~/OneDrive` location. Any files that are deleted online remain locally and will not be removed.

However, in some circumstances, it may be desirable to clean up local files that have been removed online. To do this, use the following command:

```text
onedrive --sync --download-only --cleanup-local-files
```

### Performing a 'one-way' upload synchronisation with Microsoft OneDrive
In some cases, it may be desirable to 'upload only' to Microsoft OneDrive. To do this, use the following command:
```text
onedrive --sync --upload-only
```
**Note:** If a file or folder is present on Microsoft OneDrive, which was previously synchronised and now does not exist locally, that item will be removed from Microsoft OneDrive online. If the data on Microsoft OneDrive should be kept, the following should be used:
```text
onedrive --sync --upload-only --no-remote-delete
```
**Note:** The operation of 'upload only' does not request data from Microsoft OneDrive about what 'other' data exists online. The client only knows about the data that 'this' client uploaded, thus any files or folders created or uploaded outside of this client will remain untouched online.

### Performing a selective synchronisation via 'sync_list' file
Selective synchronisation allows you to sync only specific files and directories.
To enable selective synchronisation, create a file named `sync_list` in your application configuration directory (default is `~/.config/onedrive`).

Important points to understand before using 'sync_list'.
*    'sync_list' excludes _everything_ by default on OneDrive.
*    'sync_list' follows an _"exclude overrides include"_ rule, and requires **explicit inclusion**.
*    Order exclusions before inclusions, so that anything _specifically included_ is included.
*    How and where you place your `/` matters for excludes and includes in subdirectories.

Each line of the file represents a relative path from your `sync_dir`. All files and directories not matching any line of the file will be skipped during all operations. 

Additionally, the use of `/` is critically important to determine how a rule is interpreted. It is very similar to `**` wildcards, for those that are familiar with globbing patterns.
Here is an example of `sync_list`:
```text
# sync_list supports comments
#
# The ordering of entries is highly recommended - exclusions before inclusions
#
# Exclude temp folder(s) or file(s) under Documents folder(s), anywhere in OneDrive
!Documents/temp*
#
# Exclude secret data folder in root directory only
!/Secret_data/*
#
# Include everything else in root directory
/*
#
# Include my Backup folder(s) or file(s) anywhere on OneDrive
Backup
#
# Include my Backup folder in root
/Backup/
#
# Include Documents folder(s) anywhere in OneDrive
Documents/
#
# Include all PDF files in Documents folder(s), anywhere in OneDrive
Documents/*.pdf
#
# Include this single document in Documents folder(s), anywhere in OneDrive
Documents/latest_report.docx
#
# Include all Work/Project directories or files, inside 'Work' folder(s), anywhere in OneDrive
Work/Project*
#
# Include all "notes.txt" files, anywhere in OneDrive
notes.txt
#
# Include /Blender in the ~OneDrive root but not if elsewhere in OneDrive
/Blender
#
# Include these directories(or files) in 'Pictures' folder(s), that have a space in their name
Pictures/Camera Roll
Pictures/Saved Pictures
#
# Include these names if they match any file or folder
Cinema Soc
Codes
Textbooks
Year 2
```
The following are supported for pattern matching and exclusion rules:
*   Use the `*` to wildcard select any characters to match for the item to be included
*   Use either `!` or `-` characters at the start of the line to exclude an otherwise included item

**Note:** When enabling the use of 'sync_list,' utilise the `--display-config` option to validate that your configuration will be used by the application, and test your configuration by adding `--dry-run` to ensure the client will operate as per your requirement.

**Note:** After changing the sync_list, you must perform a full re-synchronisation by adding `--resync` to your existing command line - for example: `onedrive --synchronise --resync`

**Note:** In some circumstances, it may be required to sync all the individual files within the 'sync_dir', but due to frequent name change / addition / deletion of these files, it is not desirable to constantly change the 'sync_list' file to include / exclude these files and force a resync. To assist with this, enable the following in your configuration file:
```text
sync_root_files = "true"
```
This will tell the application to sync any file that it finds in your 'sync_dir' root by default, negating the need to constantly update your 'sync_list' file.

### Performing a --resync
If you alter any of the subsequent configuration items, you'll need to execute a `--resync` to make sure your client is syncing your data with the updated configuration:
*   drive_id
*   sync_dir
*   skip_file
*   skip_dir
*   skip_dotfiles
*   skip_symlinks
*   sync_business_shared_items
*   Creating, Modifying or Deleting the 'sync_list' file

Additionally, you might opt for a `--resync` if you think it's necessary to ensure your data remains in sync. If you're using this switch simply because you're unsure of the sync status, you can check the actual sync status using `--display-sync-status`.

When you use `--resync`, you'll encounter the following warning and advice:
```text
Using --resync will delete your local 'onedrive' client state, so there won't be a record of your current 'sync status.'
This may potentially overwrite local versions of files with older versions downloaded from OneDrive, leading to local data loss.
If in doubt, back up your local data before using --resync.

Are you sure you want to proceed with --resync? [Y/N] 
```

To proceed with `--resync`, you must type 'y' or 'Y' to allow the application to continue.

**Note:** It's highly recommended to use `--resync` only if the application prompts you to do so. Don't blindly set the application to start with `--resync` as the default option.

**Note:** In certain automated environments (assuming you know what you're doing due to automation), to avoid the 'proceed with acknowledgement' requirement, add `--resync-auth` to automatically acknowledge the prompt.

### Performing a --force-sync without a --resync or changing your configuration
In some cases and situations, you may have configured the application to skip certain files and folders using 'skip_file' and 'skip_dir' configuration. You then may have a requirement to actually sync one of these items, but do not wish to modify your configuration, nor perform an entire `--resync` twice.

The `--force-sync` option allows you to sync a specific directory, ignoring your 'skip_file' and 'skip_dir' configuration and negating the requirement to perform a `--resync`.

To use this option, you must run the application manually in the following manner:
```text
onedrive --synchronise --single-directory '<directory_to_sync>' --force-sync <add any other options needed or required>
```

When using `--force-sync`, you'll encounter the following warning and advice:
```text
WARNING: Overriding application configuration to use application defaults for skip_dir and skip_file due to --sync --single-directory --force-sync being used

Using --force-sync will reconfigure the application to use defaults. This may have unknown future impacts.
By proceeding with this option, you accept any impacts, including potential data loss resulting from using --force-sync.

Are you sure you want to proceed with --force-sync [Y/N] 
```

To proceed with `--force-sync`, you must type 'y' or 'Y' to allow the application to continue.

### Client Activity Log
When running onedrive, all actions can be logged to a separate log file. This can be enabled by using the `--enable-logging` flag. By default, log files will be written to `/var/log/onedrive/` and will be in the format of `%username%.onedrive.log`, where `%username%` represents the user who ran the client to allow easy sorting of user to client activity log.

**Note:** You will need to ensure the existence of this directory and that your user has the applicable permissions to write to this directory; otherwise, the following error message will be printed:
```text
ERROR: Unable to access /var/log/onedrive
ERROR: Please manually create '/var/log/onedrive' and set appropriate permissions to allow write access
ERROR: The requested client activity log will instead be located in your user's home directory
```

On many systems, this can be achieved by performing the following:
```text
sudo mkdir /var/log/onedrive
sudo chown root:users /var/log/onedrive
sudo chmod 0775 /var/log/onedrive
```

Additionally, you need to ensure that your user account is part of the 'users' group:
```
cat /etc/group | grep users
```

If your user is not part of this group, then you need to add your user to this group:
```
sudo usermod -a -G users <your-user-name>
```

If you need to make a group modification, you will need to 'logout' of all sessions / SSH sessions to log in again to have the new group access applied.

If the client is unable to write the client activity log, the following error message will be printed:
```text
ERROR: Unable to write the activity log to /var/log/onedrive/%username%.onedrive.log
ERROR: Please set appropriate permissions to allow write access to the logging directory for your user account
ERROR: The requested client activity log will instead be located in your user's home directory
```

If you receive this error message, you will need to diagnose why your system cannot write to the specified file location.

#### Client Activity Log Example:
An example of a client activity log for the command `onedrive --sync --enable-logging` is below:
```text
2023-Sep-27 08:16:00.1128806    Configuring Global Azure AD Endpoints
2023-Sep-27 08:16:00.1160620    Sync Engine Initialised with new Onedrive API instance
2023-Sep-27 08:16:00.5227122    All application operations will be performed in: /home/user/OneDrive
2023-Sep-27 08:16:00.5227977    Fetching items from the OneDrive API for Drive ID: <redacted>
2023-Sep-27 08:16:00.7780979    Processing changes and items received from OneDrive ...
2023-Sep-27 08:16:00.7781548    Performing a database consistency and integrity check on locally stored data ... 
2023-Sep-27 08:16:00.7785889    Scanning the local file system '~/OneDrive' for new data to upload ...
2023-Sep-27 08:16:00.7813710    Performing a final true-up scan of online data from OneDrive
2023-Sep-27 08:16:00.7814668    Fetching items from the OneDrive API for Drive ID: <redacted>
2023-Sep-27 08:16:01.0141776    Processing changes and items received from OneDrive ...
2023-Sep-27 08:16:01.0142454    Sync with Microsoft OneDrive is complete
```
An example of a client activity log for the command `onedrive --sync --verbose --enable-logging` is below:
```text
2023-Sep-27 08:20:05.4600464    Checking Application Version ...
2023-Sep-27 08:20:05.5235017    Attempting to initialise the OneDrive API ...
2023-Sep-27 08:20:05.5237207    Configuring Global Azure AD Endpoints
2023-Sep-27 08:20:05.5238087    The OneDrive API was initialised successfully
2023-Sep-27 08:20:05.5238536    Opening the item database ...
2023-Sep-27 08:20:05.5270612    Sync Engine Initialised with new Onedrive API instance
2023-Sep-27 08:20:05.9226535    Application version:  vX.Y.Z-A-bcdefghi
2023-Sep-27 08:20:05.9227079    Account Type:         <account-type>
2023-Sep-27 08:20:05.9227360    Default Drive ID:     <redacted>
2023-Sep-27 08:20:05.9227550    Default Root ID:      <redacted>
2023-Sep-27 08:20:05.9227862    Remaining Free Space: <space-available>
2023-Sep-27 08:20:05.9228296    All application operations will be performed in: /home/user/OneDrive
2023-Sep-27 08:20:05.9228989    Fetching items from the OneDrive API for Drive ID: <redacted>
2023-Sep-27 08:20:06.2076569    Performing a database consistency and integrity check on locally stored data ... 
2023-Sep-27 08:20:06.2077121    Processing DB entries for this Drive ID: <redacted>
2023-Sep-27 08:20:06.2078408    Processing ~/OneDrive
2023-Sep-27 08:20:06.2078739    The directory has not changed
2023-Sep-27 08:20:06.2079783    Processing Attachments
2023-Sep-27 08:20:06.2080071    The directory has not changed
2023-Sep-27 08:20:06.2081585    Processing Attachments/file.docx
2023-Sep-27 08:20:06.2082079    The file has not changed
2023-Sep-27 08:20:06.2082760    Processing Documents
2023-Sep-27 08:20:06.2083225    The directory has not changed
2023-Sep-27 08:20:06.2084284    Processing Documents/file.log
2023-Sep-27 08:20:06.2084886    The file has not changed
2023-Sep-27 08:20:06.2085150    Scanning the local file system '~/OneDrive' for new data to upload ...
2023-Sep-27 08:20:06.2087133    Skipping item - excluded by sync_list config: ./random_25k_files
2023-Sep-27 08:20:06.2116235    Performing a final true-up scan of online data from OneDrive
2023-Sep-27 08:20:06.2117190    Fetching items from the OneDrive API for Drive ID: <redacted>
2023-Sep-27 08:20:06.5049743    Sync with Microsoft OneDrive is complete
```

#### Client Activity Log Differences
Despite application logging being enabled as early as possible, the following log entries will be missing from the client activity log when compared to console output:

**No user configuration file:**
```text
No user or system config file found, using application defaults
Using 'user' configuration path for application state data: /home/user/.config/onedrive
Using the following path to store the runtime application log: /var/log/onedrive
```
**User configuration file:**
```text
Reading configuration file: /home/user/.config/onedrive/config
Configuration file successfully loaded
Using 'user' configuration path for application state data: /home/user/.config/onedrive
Using the following path to store the runtime application log: /var/log/onedrive
```

### GUI Notifications
If notification support has been compiled in (refer to GUI Notification Support in install.md .. ADD LINK LATER), the following events will trigger a GUI notification within the display manager session:
*   Aborting a sync if .nosync file is found
*   Skipping a particular item due to an invalid name
*   Skipping a particular item due to an invalid symbolic link
*   Skipping a particular item due to an invalid UTF sequence
*   Skipping a particular item due to an invalid character encoding sequence
*   Cannot create remote directory
*   Cannot upload file changes (free space issue, breaches maximum allowed size, breaches maximum OneDrive Account path length)
*   Cannot delete remote file / folder
*   Cannot move remote file / folder
*   When a re-authentication is required
*   When a new client version is available
*   Files that fail to upload
*   Files that fail to download

### Handling a Microsoft OneDrive Account Password Change
If you change your Microsoft OneDrive Account Password, the client will no longer be authorised to sync, and will generate the following error upon next application run:
```text
AADSTS50173: The provided grant has expired due to it being revoked, a fresh auth token is needed. The user might have changed or reset their password. The grant was issued on '<date-and-timestamp>' and the TokensValidFrom date (before which tokens are not valid) for this user is '<date-and-timestamp>'.

ERROR: You will need to issue a --reauth and re-authorise this client to obtain a fresh auth token.
```

To re-authorise the client, follow the steps below:
1.   If running the client as a system service (init.d or systemd), stop the applicable system service
2.   Run the command `onedrive --reauth`. This will clean up the previous authorisation, and will prompt you to re-authorise the client as per initial configuration. Please note, if you are using `--confdir` as part of your application runtime configuration, you must include this when telling the client to re-authenticate.
3.   Restart the client if running as a system service or perform the standalone sync operation again

The application will now sync with OneDrive with the new credentials.

### Determining the synchronisation result
When the client has finished syncing without errors, the following will be displayed:
```
Sync with Microsoft OneDrive is complete
```

If any items failed to sync, the following will be displayed:
```
Sync with Microsoft OneDrive has completed, however there are items that failed to sync.
```
A file list of either upload or download items will be then listed to allow you to determine your next steps.

In order to fix the upload or download failures, you may need to re-try your command and perform a resync to ensure your system is correctly synced with your Microsoft OneDrive Account.

## Frequently Asked Configuration Questions

### How to configure the client?
Configuration is determined by three layers, and applied in the following order:
*   Application default values
*   Values that are set in the configuration file
*   Values that are passed in via the command line at application runtime. 

The default application values provide a reasonable default, and additional configuration is entirely optional.

If you want to change the application defaults, you can download a copy of the config file into your application configuration directory. Valid default directories for the config file are:
*   `~/.config/onedrive`
*   `/etc/onedrive`

**Example:** To download a copy of the config file, use the following:
```text
mkdir -p ~/.config/onedrive
wget https://raw.githubusercontent.com/abraunegg/onedrive/master/config -O ~/.config/onedrive/config
```

For full configuration options and CLI switches, please refer to application-config-options.md

### How to only sync a specific directory?
There are two methods to achieve this:
*   Employ the '--single-directory' option to only sync this specific path
*   Employ 'sync_list' as part of your 'config' file to configure what files and directories to sync, and what should be excluded

### How to 'skip' files from syncing?
There are two methods to achieve this:
*   Employ 'skip_file' as part of your 'config' file to configure what files to skip
*   Employ 'sync_list' to configure what files and directories to sync, and what should be excluded

### How to 'skip' directories from syncing?
There are three methods available to 'skip' a directory from the sync process:
*   Employ 'skip_dir' as part of your 'config' file to configure what directories to skip
*   Employ 'sync_list' to configure what files and directories to sync, and what should be excluded
*   Employ 'check_nosync' as part of your 'config' file and a '.nosync' empty file within the directory to exclude to skip that directory

### How to 'skip' dot files and folders from syncing?
There are three methods to achieve this:
*   Employ 'skip_file' or 'skip_dir' to configure what files or folders to skip
*   Employ 'sync_list' to configure what files and directories to sync, and what should be excluded
*   Employ 'skip_dotfiles' as part of your 'config' file to skip any dot file (for example: `.Trash-1000` or `.xdg-volume-info`) from syncing to OneDrive

### How to 'skip' files larger than a certain size from syncing?
There are two methods to achieve this:
*   Use `--skip-size ARG` option to skip new files larger than this size (in MB)
*   Use `skip_size = "value"` as part of your 'config' file where files larger than this size (in MB) will be skipped

### How to 'rate limit' the application to control bandwidth consumed for upload & download operations?
To minimise the Internet bandwidth for upload and download operations, you can add the 'rate_limit' configuration option as part of your 'config' file.

The default value is '0' which means use all available bandwidth for the application.

The value being used can be reviewed when using `--display-config`.

### How can I prevent my local disk from filling up?
By default, the application will reserve 50MB of disk space to prevent your filesystem from running out of disk space.

This default value can be modified by adding the 'space_reservation' configuration option and the applicable value as part of your 'config' file.

You can review the value being used when using `--display-config`.

### How does the client handle symbolic links?
Microsoft OneDrive has no concept or understanding of symbolic links, and attempting to upload a symbolic link to Microsoft OneDrive generates a platform API error. All data (files and folders) that are uploaded to OneDrive must be whole files or actual directories.

As such, there are only two methods to support symbolic links with this client:
1. Follow the Linux symbolic link and upload whatever the local symbolic link is pointing to to Microsoft OneDrive. This is the default behaviour.
2. Skip symbolic links by configuring the application to do so. When skipping, no data, no link, no reference is uploaded to OneDrive.

Use 'skip_symlinks' as part of your 'config' file to configure the skipping of all symbolic links while syncing.

### How to synchronise shared folders (OneDrive Personal)?
Folders shared with you can be synchronised by adding them to your OneDrive online. To do that, open your OneDrive account online, go to the Shared files list, right-click on the folder you want to synchronise, and then click on "Add to my OneDrive".

### How to synchronise shared folders (OneDrive Business or Office 365)?
Folders shared with you can be synchronised by adding them to your OneDrive online. To do that, open your OneDrive account online, go to the Shared files list, right-click on the folder you want to synchronise, and then click on "Add to my OneDrive".

Refer to [./business-shared-folders.md](business-shared-folders.md) for further details.

### How to synchronise SharePoint / Office 365 Shared Libraries?
There are two methods to achieve this:
* SharePoint library can be directly added to your OneDrive online. To do that, open your OneDrive account online, go to the Shared files list, right-click on the SharePoint Library you want to synchronise, and then click on "Add to my OneDrive".
* Configure a separate application instance to only synchronise that specific SharePoint Library. Refer to [./sharepoint-libraries.md](sharepoint-libraries.md) for configuration assistance.

### How to Create a Shareable Link?
In certain situations, you might want to generate a shareable file link and provide this link to other users for accessing a specific file.

To accomplish this, employ the following command:
```text
onedrive --create-share-link <path/to/file>
```
**Note:** By default, this access permissions for the file link will be read-only.

To make it a read-write link, execute the following command:
```text
onedrive --create-share-link <path/to/file> --with-editing-perms
```
**Note:** The order of the file path and option flag is crucial.

### How to Synchronise Both Personal and Business Accounts at Once?
You need to set up separate instances of the application configuration for each account.

Refer to [./advanced-usage.md](advanced-usage.md) for guidance on configuration.

### How to Synchronise Multiple SharePoint Libraries Simultaneously?
For each SharePoint Library, configure a separate instance of the application configuration.

Refer to [./advanced-usage.md](advanced-usage.md) for configuration instructions.

### How to Receive Real-time Changes from Microsoft OneDrive Service, Instead of Waiting for the Next Sync Period?
When operating in 'Monitor Mode,' it may be advantageous to receive real-time updates to online data. A 'webhook' is the method to achieve this, so that when in 'Monitor Mode,' the client subscribes to remote updates.

Remote changes can then be promptly synchronised to your local file system, without waiting for the next synchronisation cycle.

This is accomplished by:
*   Using 'webhook_enabled' as part of your 'config' file to enable this feature
*   Using 'webhook_public_url' as part of your 'config' file to configure the URL the webhook will use for subscription updates

### How to initiate the client as a background service?
There are a few ways to employ onedrive as a service:
* via init.d
* via systemd
* via runit

#### OneDrive service running as root user via init.d
```text
chkconfig onedrive on
service onedrive start
```
To view the logs, execute:
```text
tail -f /var/log/onedrive/<username>.onedrive.log
```
To alter the 'user' under which the client operates (typically root by default), manually modify the init.d service file and adjust `daemon --user root onedrive_service.sh` to match the correct user.

#### OneDrive service running as root user via systemd (Arch, Ubuntu, Debian, OpenSuSE, Fedora)
Initially, switch to the root user with `su - root`, then activate the systemd service:
```text
systemctl --user enable onedrive
systemctl --user start onedrive
```
**Note:** The `systemctl --user` command is not applicable to Red Hat Enterprise Linux (RHEL) or CentOS Linux platforms - see below.

**Note:** This will execute the 'onedrive' process with a UID/GID of '0', which means any files or folders created will be owned by 'root'.

To monitor the service's status, use the following:
```text
systemctl --user status onedrive.service
```

To observe the systemd application logs, use:
```text
journalctl --user-unit=onedrive -f
```

**Note:** For systemd to function correctly, it requires the presence of XDG environment variables. If you encounter the following error while enabling the systemd service:
```text
Failed to connect to bus: No such file or directory
```
The most likely cause is missing XDG environment variables. To resolve this, add the following lines to `.bashrc` or another file executed upon user login:
```text
export XDG_RUNTIME_DIR="/run/user/$UID"
export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
```

To apply this change, you must log out of all user accounts where it has been made.

**Note:** On certain systems (e.g., Raspbian / Ubuntu / Debian on Raspberry Pi), the XDG fix above may not persist after system reboots. An alternative to starting the client via systemd as root is as follows:
1. Create a symbolic link from `/home/root/.config/onedrive` to `/root/.config/onedrive/`.
2. Establish a systemd service using the '@' service file: `systemctl enable onedrive@root.service`.
3. Start the root@service: `systemctl start onedrive@root.service`.

This ensures that the service correctly restarts upon system reboot.

To examine the systemd application logs, run:
```text
journalctl --unit=onedrive@<username> -f
```

#### OneDrive service running as root user via systemd (Red Hat Enterprise Linux, CentOS Linux)
```text
systemctl enable onedrive
systemctl start onedrive
```
**Note:** This will execute the 'onedrive' process with a UID/GID of '0', meaning any files or folders created will be owned by 'root'.

To view the systemd application logs, execute:
```text
journalctl --unit=onedrive -f
```

#### OneDrive service running as a non-root user via systemd (All Linux Distributions)
In some instances, it is preferable to run the OneDrive client as a service without the 'root' user. Follow the instructions below to configure the service for your regular user login.

1. As the user who will run the service, launch the application in standalone mode, authorize it for use, and verify that synchronization is functioning as expected:
```text
onedrive --sync --verbose
```
2. After validating the application for your user, switch to the 'root' user, where <username> is your username from step 1 above.
```text
systemctl enable onedrive@<username>.service
systemctl start onedrive@<username>.service
```
3. To check the service's status for the user, use the following:
```text
systemctl status onedrive@<username>.service
```

To observe the systemd application logs, use:
```text
journalctl --unit=onedrive@<username> -f
```

#### OneDrive service running as a non-root user via systemd (with notifications enabled) (Arch, Ubuntu, Debian, OpenSuSE, Fedora)
In some scenarios, you may want to receive GUI notifications when using the client as a non-root user. In this case, follow these steps:

1. Log in via the graphical UI as the user you want to enable the service for.
2. Disable any `onedrive@` service files for your username, e.g.:
```text
sudo systemctl stop onedrive@alex.service
sudo systemctl disable onedrive@alex.service
```
3. Enable the service as follows:
```text
systemctl --user enable onedrive
systemctl --user start onedrive
```

To check the service's status for the user, use the following:
```text
systemctl --user status onedrive.service
```

To view the systemd application logs, execute:
```text
journalctl --user-unit=onedrive -f
```

**Note:** The `systemctl --user` command is not applicable to Red Hat Enterprise Linux (RHEL) or CentOS Linux platforms.

#### OneDrive service running as a non-root user via runit (antiX, Devuan, Artix, Void)

1. Create the following folder if it doesn't already exist: `/etc/sv/runsvdir-<username>`

  - where `<username>` is the `USER` targeted for the service
  - e.g., `# mkdir /etc/sv/runsvdir-nolan`

2. Create a file called `run` under the previously created folder with executable permissions

   - `# touch /etc/sv/runsvdir-<username>/run`
   - `# chmod 0755 /etc/sv/runsvdir-<username>/run`

3. Edit the `run` file with the following contents (permissions needed):

  ```sh
  #!/bin/sh
  export USER="<username>"
  export HOME="/home/<username>"

  groups="$(id -Gn "${USER}" | tr ' ' ':')"
  svdir="${HOME}/service"

  exec chpst -u "${USER}:${groups}" runsvdir "${svdir}"
  ```

  - Ensure you replace `<username>` with the `USER` set in step #1.

4. Enable the previously created folder as a service

  - `# ln -fs /etc/sv/runsvdir-<username> /var/service/`

5. Create a subfolder in the `USER`'s `HOME` directory to store the services (or symlinks)

   - `$ mkdir ~/service`

6. Create a subfolder specifically for OneDrive

  - `$ mkdir ~/service/onedrive/`

7. Create a file called `run` under the previously created folder with executable permissions

   - `$ touch ~/service/onedrive/run`
   - `$ chmod 0755 ~/service/onedrive/run`

8. Append the following contents to the `run` file

  ```sh
  #!/usr/bin/env sh
  exec /usr/bin/onedrive --monitor
  ```

  - In some scenarios, the path to the `onedrive` binary may vary. You can obtain it by running `$ command -v onedrive`.

9. Reboot to apply the changes

10. Check the status of user-defined services

  - `$ sv status ~/service/*`

For additional details, you can refer to Void's documentation on [Per-User Services](https://docs.voidlinux.org/config/services/user-services.html).

### How to start a user systemd service at boot without user login?
In some situations, it may be necessary for the systemd service to start without requiring your 'user' to log in.

To address this issue, you need to reconfigure your 'user' account so that the systemd services you've created launch without the need for you to log in to your system:
```text
loginctl enable-linger <your_user_name>
```