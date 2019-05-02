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
[alex@centos7full onedrive]$ cat business_shared_folders 
TestSharedFolder
ThisDoesNotExist
SomeRubbishFolder
AnotherSharedFolder
[alex@centos7full onedrive]$ 
```
3.  Validate your configuration with `onedrive --display-config`:
```text
onedrive version                    = v2.3.3-1-gc8e47a4
Config path                         = /home/alex/.config/onedrive
Config file found in config path    = true
Config option 'check_nosync'        = false
Config option 'sync_dir'            = /home/alex/OneDrive
Config option 'skip_dir'            = 
Config option 'skip_file'           = ~*|.~*|*.tmp
Config option 'skip_dotfiles'       = false
Config option 'skip_symlinks'       = false
Config option 'monitor_interval'    = 45
Config option 'min_notify_changes'  = 5
Config option 'log_dir'             = /var/log/onedrive/
Selective sync configured           = false
Selective Business Shared Folders configured = true
business_shared_folders contents:
TestSharedFolder
ThisDoesNotExist
SomeRubbishFolder
```

## Performing a sync of OneDrive Business Shared Folders
Perform a sync using the following command: `onedrive --synchronize --sync-shared-folders`:
```text
onedrive --confdir '~/.config/onedrive --synchronize --verbose --sync-shared-folders
Using Config Dir: /home/alex/.config/onedrive
Initializing the OneDrive API ...
Opening the item database ...
All operations will be performed in: /home/alex/OneDrive
Initializing the Synchronization Engine ...
Account Type: business
Default Drive ID: <redacted>
Default Root ID: 01WOGXO2N6Y2GOVW7725BZO354PWSELRRZ
Remaining Free Space: 1099329560663
Fetching details for OneDrive Root
OneDrive Root exists in the database
Syncing changes from OneDrive ...
Applying changes of Path ID: 01WOGXO2N6Y2GOVW7725BZO354PWSELRRZ
Syncing OneDrive Business Shared Folder: SomeRubbishFolder
Applying changes of Path ID: 01DBFNO5QIQCS5F3EUOVAKDH7TL7ROL6BM
Syncing OneDrive Business Shared Folder: TestSharedFolder
Applying changes of Path ID: 01DBFNO5VLLTCOGVRW6ZBYFBKAXHJI5IGF
Uploading differences of /home/alex/OneDrive
Processing root
The directory has not changed
Processing Cygwin.zip
The file has not changed
Processing local_dir
The directory has not changed
Processing asdf.txt
The file has not changed
Uploading new items of /home/alex/OneDrive
Applying changes of Path ID: 01WOGXO2N6Y2GOVW7725BZO354PWSELRRZ
Syncing OneDrive Business Shared Folder: SomeRubbishFolder
Applying changes of Path ID: 01DBFNO5QIQCS5F3EUOVAKDH7TL7ROL6BM
Syncing OneDrive Business Shared Folder: TestSharedFolder
Applying changes of Path ID: 01DBFNO5VLLTCOGVRW6ZBYFBKAXHJI5IGF
```

**Note:** Whenever you modify the `business_shared_folders` file you must perform a `--resync` of your database to clean up stale entries due to changes in your configuration.