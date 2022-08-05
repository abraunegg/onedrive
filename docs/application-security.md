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

As such, the folloiwng API permissions are used by default:

### Default Azure Application Permissions

| API / Permissions name | Type | Description | Admin consent required |
|---|---|---|---|
| Files.Read | Delegated | Have read-only access to user files | No |
| Files.Read.All  | Delegated | Have read-only access to all files user can access | No |
| Sites.Read.All   | Delegated | Have read-only access to all items in all site collections | No |
| offline_access   | Delegated | Maintain access to data you have given it access to | No |

### Default User Authentication Permissions

| API / Permissions name | Type | Description | Admin consent required |
|---|---|---|---|
| Files.ReadWrite | Delegated | Have full access to user files | No |
| Files.ReadWrite.All  | Delegated | Have full access to all files user can access | No |
| Sites.ReadWrite.All   | Delegated | Have full access to all items in all site collections | No |
| offline_access   | Delegated | Maintain access to data you have given it access to | No |

When these delegated API permissions are commbined, these provide the effective authentication scope for the OneDrive Client for Linux to access your data.