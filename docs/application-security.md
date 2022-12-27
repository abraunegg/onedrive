# OneDrive Client for Linux Application Security
This document details the application security used, and provides details for users on changing these security options.

There are 2 main components regarding security for this application:
* Azure Application Permissions
* User Authentication Permissions

## Default Application Security
Security options should follow the security principal of 'least privilege':
> The principle that a security architecture should be designed so that each entity 
> is granted the minimum system resources and authorizations that the entity needs 
> to perform its function.

Reference: [https://csrc.nist.gov/glossary/term/least_privilege](https://csrc.nist.gov/glossary/term/least_privilege)

As such, the following API permissions are used by default:

### Default Azure Application Permissions

| API / Permissions name | Type | Description | Admin consent required |
|---|---|---|---|
| Files.Read | Delegated | Have read-only access to user files | No |
| Files.Read.All  | Delegated | Have read-only access to all files user can access | No |
| Sites.Read.All   | Delegated | Have read-only access to all items in all site collections | No |
| offline_access   | Delegated | Maintain access to data you have given it access to | No |

![default_authentication_scopes](./images/default_authentication_scopes.jpg)

### Default User Authentication Permissions

| API / Permissions name | Type | Description | Admin consent required |
|---|---|---|---|
| Files.ReadWrite | Delegated | Have full access to user files | No |
| Files.ReadWrite.All  | Delegated | Have full access to all files user can access | No |
| Sites.ReadWrite.All   | Delegated | Have full access to all items in all site collections | No |
| offline_access   | Delegated | Maintain access to data you have given it access to | No |

When these delegated API permissions are combined, these provide the effective authentication scope for the OneDrive Client for Linux to access your data. The effective 'default' permissions will be:

| API / Permissions name | Type | Description | Admin consent required |
|---|---|---|---|
| Files.ReadWrite | Delegated | Have full access to user files | No |
| Files.ReadWrite.All  | Delegated | Have full access to all files user can access | No |
| Sites.ReadWrite.All   | Delegated | Have full access to all items in all site collections | No |
| offline_access   | Delegated | Maintain access to data you have given it access to | No |

These 'default' permissions will allow the OneDrive Client for Linux to read, write and delete data associated with your OneDrive Account.

## Configuring read-only access to your OneDrive data
In some situations, it may be desirable to configure the OneDrive Client for Linux totally in read-only operation.

To change the application to 'read-only' access, add the following to your configuration file:
```text
read_only_auth_scope = "true"
```
This will change the user authentication scope request to use read-only access.

**Note:** When changing this value, you *must* re-authenticate the client using the `--reauth` option to utilise the change in authentication scopes.

When using read-only authentication scopes, the uploading of any data or local change to OneDrive will fail with the following error:
```
2022-Aug-06 13:16:45.3349625    ERROR: Microsoft OneDrive API returned an error with the following message:
2022-Aug-06 13:16:45.3351661      Error Message:    HTTP request returned status code 403 (Forbidden)
2022-Aug-06 13:16:45.3352467      Error Reason:     Access denied
2022-Aug-06 13:16:45.3352838      Error Timestamp:  2022-06-12T13:16:45
2022-Aug-06 13:16:45.3353171      API Request ID:   <redacted>
```

As such, it is also advisable for you to add the following to your configuration file so that 'uploads' are prevented:
```text
download_only = "true"
```

**Important:** Additionally when using 'read_only_auth_scope' you also will need to remove your existing application access consent otherwise old authentication consent will be valid and will be used. This will mean the application will technically have the consent to upload data. See below on how to remove your prior application consent.
 
## Reviewing your existing application access consent

To review your existing application access consent, you need to access the following URL: https://account.live.com/consent/Manage

From here, you are able to review what applications have been given what access to your data, and remove application access as required.
