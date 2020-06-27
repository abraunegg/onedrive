# How to configure OneDrive Business Shared Folder Sync
Syncing OneDrive Business Shared Folders requires additional configuration for your 'onedrive' client:
1.  List available shared folders to determine which folder you wish to sync & to validate that you have access to that folder
2.  Create a new file called 'business_shared_folders' in your config directory which contains a list of the shared folders you wish to sync
3.  Perform a sync

## Listing available OneDrive Business Shared Folders
List the available OneDrive Business Shared folders with the following command:
```text
onedrive --list-shared-folders
```
   This will return a listing of all OneDrive Business Shared folders which have been shared with you and by whom. This is important for conflict resolution:
```text
Initializing the Synchronization Engine ...

Listing available OneDrive Business Shared Folders:
---------------------------------------
Shared Folder:   SharedFolder0
Shared By:       Firstname Lastname
---------------------------------------
Shared Folder:   SharedFolder1
Shared By:       Firstname Lastname
---------------------------------------
Shared Folder:   SharedFolder2
Shared By:       Firstname Lastname
---------------------------------------
Shared Folder:   SharedFolder0
Shared By:       Firstname Lastname (user@domain)
---------------------------------------
Shared Folder:   SharedFolder1
Shared By:       Firstname Lastname (user@domain)
---------------------------------------
Shared Folder:   SharedFolder2
Shared By:       Firstname Lastname (user@domain)
...
```

## Configuring OneDrive Business Shared Folders
1.  Create a new file called 'business_shared_folders' in your config directory
2.  On each new line, list the OneDrive Business Shared Folder you wish to sync
```text
[alex@centos7full onedrive]$ cat ~/.config/onedrive/business_shared_folders
# comment
Child Shared Folder
# Another comment
Top Level to Share
[alex@centos7full onedrive]$ 
```
3.  Validate your configuration with `onedrive --display-config`:
```text
Configuration file successfully loaded
onedrive version                       = v2.4.3
Config path                            = /home/alex/.config/onedrive-business/
Config file found in config path       = true
Config option 'check_nosync'           = false
Config option 'sync_dir'               = /home/alex/OneDriveBusiness
Config option 'skip_dir'               = 
Config option 'skip_file'              = ~*|.~*|*.tmp
Config option 'skip_dotfiles'          = false
Config option 'skip_symlinks'          = false
Config option 'monitor_interval'       = 300
Config option 'min_notify_changes'     = 5
Config option 'log_dir'                = /var/log/onedrive/
Config option 'classify_as_big_delete' = 1000
Config option 'sync_root_files'        = false
Selective sync 'sync_list' configured  = false
Business Shared Folders configured     = true
business_shared_folders contents:
# comment
Child Shared Folder
# Another comment
Top Level to Share
```

## Performing a sync of OneDrive Business Shared Folders
Perform a standalone sync using the following command: `onedrive --synchronize --sync-shared-folders --verbose`:
```text
onedrive --synchronize --sync-shared-folders --verbose
Using 'user' Config Dir: /home/alex/.config/onedrive-business/
Using 'system' Config Dir: 
Configuration file successfully loaded
Initializing the OneDrive API ...
Configuring Global Azure AD Endpoints
Opening the item database ...
All operations will be performed in: /home/alex/OneDriveBusiness
Application version: v2.4.3
Account Type: business
Default Drive ID: b!bO8V7s9SSk6r7mWHpIjURotN33W1W2tEv3OXV_oFIdQimEdOHR-1So7CqeT1MfHA
Default Root ID: 01WIXGO5V6Y2GOVW7725BZO354PWSELRRZ
Remaining Free Space: 1098316220277
Fetching details for OneDrive Root
OneDrive Root exists in the database
Initializing the Synchronization Engine ...
Syncing changes from OneDrive ...
Applying changes of Path ID: 01WIXGO5V6Y2GOVW7725BZO354PWSELRRZ
Number of items from OneDrive to process: 0
Attempting to sync OneDrive Business Shared Folders
Syncing this OneDrive Business Shared Folder: Child Shared Folder
OneDrive Business Shared Folder - Shared By:  test user
Applying changes of Path ID: 01JRXHEZMREEB3EJVHNVHKNN454Q7DFXPR
Adding OneDrive root details for processing
Adding OneDrive folder details for processing
Adding 4 OneDrive items for processing from OneDrive folder
Adding 2 OneDrive items for processing from /Child Shared Folder/Cisco VDI Whitepaper
Adding 2 OneDrive items for processing from /Child Shared Folder/SMPP_Shared
Processing 11 OneDrive items to ensure consistent local state
Syncing this OneDrive Business Shared Folder: Top Level to Share
OneDrive Business Shared Folder - Shared By:  test user (testuser@mynasau3.onmicrosoft.com)
Applying changes of Path ID: 01JRXHEZLRMXHKBYZNOBF3TQOPBXS3VZMA
Adding OneDrive root details for processing
Adding OneDrive folder details for processing
Adding 4 OneDrive items for processing from OneDrive folder
Adding 3 OneDrive items for processing from /Top Level to Share/10-Files
Adding 2 OneDrive items for processing from /Top Level to Share/10-Files/Cisco VDI Whitepaper
Adding 2 OneDrive items for processing from /Top Level to Share/10-Files/Images
Adding 8 OneDrive items for processing from /Top Level to Share/10-Files/Images/JPG
Adding 8 OneDrive items for processing from /Top Level to Share/10-Files/Images/PNG
Adding 2 OneDrive items for processing from /Top Level to Share/10-Files/SMPP
Processing 31 OneDrive items to ensure consistent local state
Uploading differences of ~/OneDriveBusiness
Processing root
The directory has not changed
Processing SMPP_Local
The directory has not changed
Processing SMPP-IF-SPEC_v3_3-24858.pdf
The file has not changed
Processing SMPP_v3_4_Issue1_2-24857.pdf
The file has not changed
Processing new_local_file.txt
The file has not changed
Processing root
The directory has not changed
...
The directory has not changed
Processing week02-03-Combinational_Logic-v1.pptx
The file has not changed
Uploading new items of ~/OneDriveBusiness
Applying changes of Path ID: 01WIXGO5V6Y2GOVW7725BZO354PWSELRRZ
Number of items from OneDrive to process: 0
Attempting to sync OneDrive Business Shared Folders
Syncing this OneDrive Business Shared Folder: Child Shared Folder
OneDrive Business Shared Folder - Shared By:  test user
Applying changes of Path ID: 01JRXHEZMREEB3EJVHNVHKNN454Q7DFXPR
Adding OneDrive root details for processing
Adding OneDrive folder details for processing
Adding 4 OneDrive items for processing from OneDrive folder
Adding 2 OneDrive items for processing from /Child Shared Folder/Cisco VDI Whitepaper
Adding 2 OneDrive items for processing from /Child Shared Folder/SMPP_Shared
Processing 11 OneDrive items to ensure consistent local state
Syncing this OneDrive Business Shared Folder: Top Level to Share
OneDrive Business Shared Folder - Shared By:  test user (testuser@mynasau3.onmicrosoft.com)
Applying changes of Path ID: 01JRXHEZLRMXHKBYZNOBF3TQOPBXS3VZMA
Adding OneDrive root details for processing
Adding OneDrive folder details for processing
Adding 4 OneDrive items for processing from OneDrive folder
Adding 3 OneDrive items for processing from /Top Level to Share/10-Files
Adding 2 OneDrive items for processing from /Top Level to Share/10-Files/Cisco VDI Whitepaper
Adding 2 OneDrive items for processing from /Top Level to Share/10-Files/Images
Adding 8 OneDrive items for processing from /Top Level to Share/10-Files/Images/JPG
Adding 8 OneDrive items for processing from /Top Level to Share/10-Files/Images/PNG
Adding 2 OneDrive items for processing from /Top Level to Share/10-Files/SMPP
Processing 31 OneDrive items to ensure consistent local state
```

**Note:** Whenever you modify the `business_shared_folders` file you must perform a `--resync` of your database to clean up stale entries due to changes in your configuration.

## Enable / Disable syncing of OneDrive Business Shared Folders
Performing a sync of the configured OneDrive Business Shared Folders can be enabled / disabled via adding the following to your configuration file.

### Enable syncing of OneDrive Business Shared Folders via config file
```text
sync_business_shared_folders = "true"
```

### Disable syncing of OneDrive Business Shared Folders via config file
```text
sync_business_shared_folders = "false"
```

## Known Issues
Shared folders, shared with you from people outside of your 'organisation' are unable to be synced. This is due to the Microsoft Graph API not presenting these folders.

Shared folders that match this scenario, when you view 'Shared' via OneDrive online, will have a 'world' symbol as per below:

![shared_with_me](./images/shared_with_me.JPG)

This issue is being tracked by: [#966](https://github.com/abraunegg/onedrive/issues/966)
