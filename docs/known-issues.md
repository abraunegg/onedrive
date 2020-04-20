# Known Issues
The below are known issues with this client:

## Unable to recursively delete directories in OneDrive Business when Retention Policy is enabled
**Issue Tracker:** https://github.com/abraunegg/onedrive/issues/338

**Description:**

Some organisations enable a retention policy on OneDrive Business that prevents the recursive deletion of data. The client is unable to delete directories as requested.

**Workaround:**

Client will print the following when this issue is encountered:
```
ERROR: Unable to delete the requested remote path from OneDrive: <dir>
ERROR: This error is due to OneDrive Business Retention Policy being applied
WORKAROUND: Manually delete all files and folders from the above path as per Business Retention Policy
```
A future version of onedrive will attempt to resolve this automatically negating the need for the above message.

## Moving files into different folders should not cause data to delete and be re-uploaded
**Issue Tracker:** https://github.com/abraunegg/onedrive/issues/876

**Description:**

When running the client in standalone mode (`--synchronize`) moving folders that are sucessfully synced around between subseqant standalone syncs causes a deletion & re-upload of data to occur.

**Explanation:**

Technically, the client is 'working' correctly, as, when moving files, you are 'deleting' them from the current location, but copying them to the 'new location'. As the client is running in standalone sync mode, there is no way to track what OS operations have been done when the client is not running - thus, this is why the 'delete and upload' is occurring.

**Workaround:**

If the tracking of moving data to new local directories is requried, it is better to run the client in service mode (`--monitor`) rather than in standalone mode, as the 'move' of files can then be handled at the point when it occurs, so that the data is moved to the new location on OneDrive without the need to be deleted and re-uploaded.
