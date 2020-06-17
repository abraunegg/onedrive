# Known Issues
The below are known issues with this client:

## Moving files into different folders should not cause data to delete and be re-uploaded
**Issue Tracker:** [#876](https://github.com/abraunegg/onedrive/issues/876)

**Description:**

When running the client in standalone mode (`--synchronize`) moving folders that are sucessfully synced around between subseqant standalone syncs causes a deletion & re-upload of data to occur.

**Explanation:**

Technically, the client is 'working' correctly, as, when moving files, you are 'deleting' them from the current location, but copying them to the 'new location'. As the client is running in standalone sync mode, there is no way to track what OS operations have been done when the client is not running - thus, this is why the 'delete and upload' is occurring.

**Workaround:**

If the tracking of moving data to new local directories is requried, it is better to run the client in service mode (`--monitor`) rather than in standalone mode, as the 'move' of files can then be handled at the point when it occurs, so that the data is moved to the new location on OneDrive without the need to be deleted and re-uploaded.

## Application 'stops' running without any visible reason
**Issue Tracker:** [#494](https://github.com/abraunegg/onedrive/issues/494), [#753](https://github.com/abraunegg/onedrive/issues/753), [#792](https://github.com/abraunegg/onedrive/issues/792), [#884](https://github.com/abraunegg/onedrive/issues/884)

**Description:**

When running the client and performing an upload or download operation, the application just stops working without any reason or explanation.

**Explanation:**

The client is heavily dependant on Curl and OpenSSL to perform the activities with the Microsoft OneDrive service. Generally, when this issue occurs, the following is found in the HTTPS Debug Log:
```
OpenSSL SSL_read: SSL_ERROR_SYSCALL, errno 104
```
The only way to determine that this is the cause of the application ceasing to work is to generate a HTTPS debug log using the following additional flags:
```
--verbose --verbose --debug-https
```

This is indicative of the following:
* Some sort of flaky Internet connection somewhere between you and the OneDrive service
* Some sort of 'broken' HTTPS transparent inspection service inspecting your traffic somewhere between you and the OneDrive service

**How to resolve:**

The best avenue of action here are:
* Ensure your OS is as up-to-date as possible
* Get support from your OS vendor
* Speak to your ISP or Help Desk for assistance
* Open a ticket with OpenSSL and/or Curl teams to better handle this sort of connection failure
* Generate a HTTPS Debug Log for this application and open a new support request with Microsoft and provide the debug log file for their analysis.

If you wish to diagnose this issue further, refer to the following:

https://maulwuff.de/research/ssl-debugging.html
