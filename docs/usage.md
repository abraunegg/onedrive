# Configuration and Usage of the OneDrive Free Client
## Application Version
Before reading this document, please ensure you are running application version [![Version](https://img.shields.io/github/v/release/abraunegg/onedrive)](https://github.com/abraunegg/onedrive/releases) or greater. Use `onedrive --version` to determine what application version you are using and upgrade your client if required.

## Table of Contents
MUST REDO

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
skip_file = "~*|.~*|*.tmp|*.swp|*.partial"
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

Enter the response uri from your browser:  https://login.microsoftonline.com/common/oauth2/nativeclient?code=<redacted>

Application has been successfully authorised, however no additional command switches were provided.

Please use 'onedrive --help' for further assistance in regards to running this application.
```

### Show your applicable runtime configuration
To validate the configuration that the application will use, utilise the following:
```text
onedrive --display-config
```
This will display all the pertinent runtime interpretation of the options and configuration you are using. Example output is as follows:
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

### Client operational modes
There are two modes of operation when using the client:
1. Standalone sync mode that performs a single sync action against Microsoft OneDrive.
2. Ongoing sync mode that continiously sync's your data with Microsoft OneDrive

#### Standalone synchronisation operational mode
This method of use can be used by issuing the following option to the client:
```
onedrive --sync
```
For simplicity, this can be simplified to the following:
```
onedrive -s
```

#### Ongoing synchronisation operational mode
This method of use can be used by issuing the following option to the client:
```
onedrive --monitor
```
For simplicity, this can be simplified to the following:
```
onedrive -m
```
**Note:** This method of use is typically used when enabling a systemd service to run the application in the background.

### Increasing application logging level
When running a sync or using monitor mode, it may be desirable to see additional information as to the progress and operation of the client. To do this, use the following command:
```text
onedrive --sync --verbose
```
For simplicity, this can be simplified to the following:
```
onedrive -s -v
```
Adding `--verbose` twice will enable debug logging output. This is generally required when raising a bug report or needing to understand a problem.

### Testing your configuration
You are able to test your configuration by utilising the `--dry-run` CLI option. No files will be downloaded, uploaded or removed, however the application will display what 'would' have occurred. For example:
```
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
Perfoming final true up scan of online data from OneDrive
Fetching items from the OneDrive API for Drive ID: <drive-id> ..

Sync with Microsoft OneDrive is complete
```

### Performing a sync with Microsoft OneDrive
By default all files are downloaded in `~/OneDrive`. This download location is controled by the 'sync_dir' config option.

After authorising the application, a sync of your data can be performed by running:
```text
onedrive --sync
```
This will synchronize files from your Microsoft OneDrive account to your `~/OneDrive` local directory, or to your specified 'sync_dir' location.

If you prefer to use your local files as stored in `~/OneDrive` as your 'source of truth' use the following sync command:
```text
onedrive --sync --local-first
```

### Performing a single directory sync with Microsoft OneDrive
In some cases it may be desirable to sync a single directory under ~/OneDrive without having to change your client configuration. To do this use the following command:
```text
onedrive --sync --single-directory '<dir_name>'
```

**Example:** If the full path is `~/OneDrive/mydir`, the command would be `onedrive --sync --single-directory 'mydir'`

### Performing a 'one-way' download sync with Microsoft OneDrive
In some cases it may be desirable to 'download only' from Microsoft OneDrive. To do this use the following command:
```text
onedrive --sync --download-only
```
This will download all the content from Microsoft OneDrive to your `~/OneDrive` location. Any files that are deleted online, remain locally and will not be removed.

However, in some circumstances, it may be desirable to cleanup local files that have been removed online. To do this, use the following command:

```text
onedrive --sync --download-only --cleanup-local-files
```

### Performing a 'one-way' upload sync with Microsoft OneDrive
In some cases it may be desirable to 'upload only' to Microsoft OneDrive. To do this use the following command:
```text
onedrive --sync --upload-only
```
**Note:** If a file or folder is present on Microsoft OneDrive, that was previously synced and now does not exist locally, that item it will be removed from Microsoft OneDrive online. If the data on Microsoft OneDrive should be kept, the following should be used:
```text
onedrive --sync --upload-only --no-remote-delete
```
**Note:** The operation of 'upload only' does not request data from Microsoft OneDrive about what 'other' data exists online. The client only knows about the data that 'this' client uploaded, thus any files or folders created or uploaded outside of this client will remain untouched online.

### Performing a selective sync via 'sync_list' file
Selective sync allows you to sync only specific files and directories.
To enable selective sync create a file named `sync_list` in your application configuration directory (default is `~/.config/onedrive`).

Important points to understand before using 'sync_list'.
*    'sync_list' excludes _everything_ by default on onedrive.
*    'sync_list' follows an _"exclude overrides include"_ rule, and requires **explicit inclusion**.
*    Order exclusions before inclusions, so that anything _specifically included_ is included.
*    How and where you place your `/` matters for excludes and includes in sub directories.

Each line of the file represents a relative path from your `sync_dir`. All files and directories not matching any line of the file will be skipped during all operations. 

Additionally, the use of `/` is critically important to determine how a rule is interpreted. It is very similar to `**` wildcards, for those that are familiar with globbing patterns.
Here is an example of `sync_list`:
```text
# sync_list supports comments
#
# The ordering of entries is highly recommended - exclusions before inclusions
#
# Exclude temp folder(s) or file(s) under Documents folder(s), anywhere in Onedrive
!Documents/temp*
#
# Exclude secret data folder in root directory only
!/Secret_data/*
#
# Include everything else in root directory
/*
#
# Include my Backup folder(s) or file(s) anywhere on Onedrive
Backup
#
# Include my Backup folder in root
/Backup/
#
# Include Documents folder(s) anywhere in Onedrive
Documents/
#
# Include all PDF files in Documents folder(s), anywhere in Onedrive
Documents/*.pdf
#
# Include this single document in Documents folder(s), anywhere in Onedrive
Documents/latest_report.docx
#
# Include all Work/Project directories or files, inside 'Work' folder(s), anywhere in Onedrive
Work/Project*
#
# Include all "notes.txt" files, anywhere in Onedrive
notes.txt
#
# Include /Blender in the ~Onedrive root but not if elsewhere in Onedrive
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

**Note:** When enabling the use of 'sync_list' utilise the `--display-config` option to validate that your configuration will be used by the application, and test your configuration by adding `--dry-run` to ensure the client will operate as per your requirement.

**Note:** After changing the sync_list, you must perform a full re-synchronization by adding `--resync` to your existing command line - for example: `onedrive --synchronize --resync`

**Note:** In some circumstances, it may be required to sync all the individual files within the 'sync_dir', but due to frequent name change / addition / deletion of these files, it is not desirable to constantly change the 'sync_list' file to include / exclude these files and force a resync. To assist with this, enable the following in your configuration file:
```text
sync_root_files = "true"
```
This will tell the application to sync any file that it finds in your 'sync_dir' root by default.

### Performing a --resync
If you modify any of the following configuration items, you will be required to perform a `--resync` to ensure your client is syncing your data with the updated configuration:
*   drive_id
*   sync_dir
*   skip_file
*   skip_dir
*   skip_dotfiles
*   skip_symlinks
*   sync_business_shared_items
*   Creating, Modifying or Deleting the 'sync_list' file

Additionally, you may choose to perform a `--resync` if you feel that this action needs to be taken to ensure your data is in sync. If you are using this switch simply because you dont know the sync status, you can query the actual sync status using `--display-sync-status`.

When using `--resync`, the following warning and advice will be presented:
```text
The usage of --resync will delete your local 'onedrive' client state, thus no record of your current 'sync status' will exist.
This has the potential to overwrite local versions of files with perhaps older versions of documents downloaded from OneDrive, resulting in local data loss.
If in doubt, backup your local data before using --resync

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
Reading configuration file: /home/user/.config/onedrive/config
Configuration file successfully loaded
Using 'user' Config Dir: /home/user/.config/onedrive

WARNING: Overriding application configuration to use application defaults for skip_dir and skip_file due to --sync --single-directory --force-sync being used

The use of --force-sync will reconfigure the application to use defaults. This may have untold and unknown future impacts.
By proceeding in using this option you accept any impacts including any data loss that may occur as a result of using --force-sync.

Are you sure you wish to proceed with --force-sync [Y/N] 
```

To proceed with using `--force-sync`, you must type 'y' or 'Y' to allow the application to continue.

### Client Activity Log
When running onedrive all actions can be logged to a separate log file. This can be enabled by using the `--enable-logging` flag. By default, log files will be written to `/var/log/onedrive/` and will be in the format of `%username%.onedrive.log`, where `%username%` represents the user who ran the client to allow easy sorting of user to client activity log.

**Note:** You will need to ensure the existence of this directory, and that your user has the applicable permissions to write to this directory or the following error message will be printed:
```text
ERROR: Unable to access /var/log/onedrive
ERROR: Please manually create '/var/log/onedrive' and set appropriate permissions to allow write access
ERROR: The requested client activity log will instead be located in your users home directory
```

On many systems this can be achieved by performing the following:
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

If you need to make a group modification, you will need to 'logout' of all sessions / SSH sessions to login again to have the new group access applied.

If the client is unable to write the client activity log, the following error message will be printed:
```text
ERROR: Unable to write activity log to /var/log/onedrive/%username%.onedrive.log
ERROR: Please set appropriate permissions to allow write access to the logging directory for your user account
ERROR: The requested client activity log will instead be located in your users home directory
```

#### Client Activity Log Example:
An example of a client activity log for the command `onedrive --sync --enable-logging` is below:
```text
2023-Sep-27 08:16:00.1128806    Configuring Global Azure AD Endpoints
2023-Sep-27 08:16:00.1160620    Sync Engine Initialised with new Onedrive API instance
2023-Sep-27 08:16:00.5227122    All application operations will be performed in: /home/user/OneDrive
2023-Sep-27 08:16:00.5227977    Fetching items from the OneDrive API for Drive ID: <redacted>
2023-Sep-27 08:16:00.7780979    Processing changes and items received from OneDrive ...
2023-Sep-27 08:16:00.7781548    Performing a database consistency and integrity check on locally stored data ... 
2023-Sep-27 08:16:00.7785889    Scanning local filesystem '~/OneDrive' for new data to upload ...
2023-Sep-27 08:16:00.7813710    Perfoming final true up scan of online data from OneDrive
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
2023-Sep-27 08:20:06.2085150    Scanning local filesystem '~/OneDrive' for new data to upload ...
2023-Sep-27 08:20:06.2087133    Skipping item - excluded by sync_list config: ./random_25k_files
2023-Sep-27 08:20:06.2116235    Perfoming final true up scan of online data from OneDrive
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
*   Skipping a particular item due to an invalid character enconding sequence
*   Cannot create remote directory
*   Cannot upload file changes (free space issue, breaches maximum allowed size, general failure, breaches maximum OneDrive Account path length)
*   Cannot delete remote file / folder
*   Cannot move remote file / folder
*   When a re-authentication is required
*   When a new client version is available
*   Files that fail to upload
*   Files that fail to download


### Handling a Microsoft OneDrive Account Password Change
If you change your OneDrive account password, the client will no longer be authorised to sync, and will generate the following error:
```text
ERROR: OneDrive returned a 'HTTP 401 Unauthorized' - Cannot Initialize Sync Engine
```
To re-authorise the client, follow the steps below:
1.   If running the client as a service (init.d or systemd), stop the service
2.   Run the command `onedrive --reauth`. This will clean up the previous authorisation, and will prompt you to re-authorise the client as per initial configuration.
3.   Restart the client if running as a service or perform a manual sync

The application will now sync with OneDrive with the new credentials.





### Determining the synchronisation result
When the client has finished syncing without errors, the following will be displayed:
```
Sync with Microsoft OneDrive is complete
```

However, if items failed to sync, the following will be displayed:
```
Sync with Microsoft OneDrive has completed, however there are items that failed to sync.
```
A file list of either upload or download items will be then listed to allow you to determine your next steps.

In order to fix the upload or download failures, you may need to re-try your command and perform a resync to ensure your system is correctly synced with your Microsoft OneDrive Account.




## How to configure the client
Configuration is determined by three layers: the default values, values that are set in the configuration file, and values that are passed in via the command line at application runtime. The default application values provide a reasonable default, and configuration is optional.

If you want to change the application defaults, you can download a copy of config file into your application configuration directory. Valid default directories for the config file are:
*   `~/.config/onedrive`
*   `/etc/onedrive`

**Example:** To download a copy of the config file, use the following:
```text
mkdir -p ~/.config/onedrive
wget https://raw.githubusercontent.com/abraunegg/onedrive/master/config -O ~/.config/onedrive/config
nano ~/.config/onedrive/config
```

