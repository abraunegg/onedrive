# How to configure OneDrive Business Shared Folder Sync
## Application Version
Before reading this document, please ensure you are running application version [![Version](https://img.shields.io/github/v/release/abraunegg/onedrive)](https://github.com/abraunegg/onedrive/releases) or greater. Use `onedrive --version` to determine what application version you are using and upgrade your client if required.

## Important Note
This feature has been 100% re-written from v2.5.0 onwards. A pre-requesite before using this capability in v2.5.0 and above is for you to revert any Shared Business Folder configuration you may be currently using, including, but not limited to:
* Removing `sync_business_shared_folders = "true|false"` from your 'config' file
* Removing the 'business_shared_folders' file 
* Removing any local data | shared folder data from your configured 'sync_dir' to ensure that there are no conflicts or issues.

## Process Overview
Syncing OneDrive Business Shared Folders requires additional configuration for your 'onedrive' client:
1.  From the OneDrive web interface, review the 'Shared' objects that have been shared with you.
2.  Select the applicable folder, and click the 'Add shortcut to My files', which will then add this to your 'My files' folder
3.  Update your OneDrive Client for Linux 'config' file to enable the feature by adding `sync_business_shared_items = "true"`. Adding this option will trigger a `--resync` requirement.
4.  Test the configuration using '--dry-run'
5.  Remove the use of '--dry-run' and sync the OneDrive Business Shared folders as required


**NOTE:** This documentation will be updated as this feature progresses.


### Enable syncing of OneDrive Business Shared Folders via config file
```text
sync_business_shared_items = "true"
```

### Disable syncing of OneDrive Business Shared Folders via config file
```text
sync_business_shared_items = "false"
```

## Known Issues
Shared folders, shared with you from people outside of your 'organisation' are unable to be synced. This is due to the Microsoft Graph API not presenting these folders.

Shared folders that match this scenario, when you view 'Shared' via OneDrive online, will have a 'world' symbol as per below:

![shared_with_me](./images/shared_with_me.JPG)

This issue is being tracked by: [#966](https://github.com/abraunegg/onedrive/issues/966)
