# List of Identified Known Issues
The following points detail known issues associated with this client:

## Renaming or Moving Files in Standalone Mode causes online deletion and re-upload to occur
**Issue Tracker:** [#876](https://github.com/abraunegg/onedrive/issues/876), [#2579](https://github.com/abraunegg/onedrive/issues/2579)

**Summary:** 

Renaming or moving files and/or folders while using the standalone sync option `--sync` this results in unnecessary data deletion online and subsequent re-upload.

**Detailed Description:**

In standalone mode (`--sync`), the renaming or moving folders locally that have already been synchronized leads to the data being deleted online and then re-uploaded in the next synchronization process.

**Technical Explanation:**

This behavior is expected from the client under these specific conditions. Renaming or moving files is interpreted as deleting them from their original location and creating them in a new location. In standalone sync mode, the client lacks the capability to track file system changes (including renames and moves) that occur when it is not running. This limitation is the root cause of the observed 'deletion and re-upload' cycle.

**Recommended Workaround:**

For effective tracking of file and folder renames or moves to new local directories, it is recommended to run the client in service mode (`--monitor`) rather than in standalone mode. This approach allows the client to immediately process these changes, enabling the data to be updated (renamed or moved) in the new location on OneDrive without undergoing deletion and re-upload.

## Application 'stops' running without any visible reason
**Issue Tracker:** [#494](https://github.com/abraunegg/onedrive/issues/494), [#753](https://github.com/abraunegg/onedrive/issues/753), [#792](https://github.com/abraunegg/onedrive/issues/792), [#884](https://github.com/abraunegg/onedrive/issues/884), [#1162](https://github.com/abraunegg/onedrive/issues/1162), [#1408](https://github.com/abraunegg/onedrive/issues/1408), [#1520](https://github.com/abraunegg/onedrive/issues/1520), [#1526](https://github.com/abraunegg/onedrive/issues/1526)

**Summary:**

Users experience sudden shutdowns in a client application during file transfers with Microsoft's Europe Data Centers, likely due to unstable internet or HTTPS inspection issues. This problem, often signaled by an error code of 141, is related to the application's reliance on Curl and OpenSSL. Resolution steps include system updates, seeking support from OS vendors, ISPs, OpenSSL/Curl teams, and providing detailed debug logs to Microsoft for analysis.

**Detailed Description:**

The application unexpectedly stops functioning during upload or download operations when using the client. This issue occurs without any apparent reason. Running `echo $?` after the unexpected exit may return an error code of 141.

This problem predominantly arises when the client interacts with Microsoft's Europe Data Centers.

**Technical Explanation:**

The client heavily relies on Curl and OpenSSL for operations with the Microsoft OneDrive service. A common observation during this error is an entry in the HTTPS Debug Log stating:
```
OpenSSL SSL_read: SSL_ERROR_SYSCALL, errno 104
```
To confirm this as the root cause, a detailed HTTPS debug log can be generated with these commands:
```
--verbose --verbose --debug-https
```

This error typically suggests one of the following issues:
* An unstable internet connection between the user and the OneDrive service.
* An issue with HTTPS transparent inspection services that monitor the traffic en route to the OneDrive service.

**Recommended Resolution Steps:**

Recommended steps to address this issue include:
* Updating your operating system to the latest version.
* Configure the application to only use HTTP/1.1
* Configure the application to use IPv4 only.
* Upgrade your 'curl' application to the latest available from the curl developers.
* Seeking assistance from your OS vendor.
* Contacting your Internet Service Provider (ISP) or your IT Help Desk.
* Reporting the issue to the OpenSSL and/or Curl teams for improved handling of such connection failures.
* Creating a HTTPS Debug Log during the issue and submitting a support request to Microsoft with the log for their analysis.

For more in-depth SSL troubleshooting, please read: https://maulwuff.de/research/ssl-debugging.html