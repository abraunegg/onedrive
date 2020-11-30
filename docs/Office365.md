# How to configure OneDrive SharePoint Shared Library sync
Syncing a OneDrive SharePoint library requires additional configuration for your 'onedrive' client:
1.  Login to OneDrive and under 'Shared Libraries' obtain the shared library name
2.  Query that shared library name using the client to obtain the required configuration details
3.  Configure the client's config file with the required 'drive_id'
4.  Test the configuration using '--dry-run'
5.  Sync the SharePoint Library as required

## Listing available OneDrive SharePoint Libraries
1.  Login to the OneDrive web interface and determine which shared library you wish to configure the client for:
![shared_libraries](./images/SharedLibraries.jpg)

## Query that shared library name using the client to obtain the required configuration details
2.  Run the following command using the 'onedrive' client
```text
onedrive --get-O365-drive-id '<your library name>'
```
3.  This will return the following:
```text
Configuration file successfully loaded
Configuring Global Azure AD Endpoints
Initializing the Synchronization Engine ...
Office 365 Library Name Query: <your library name>
SiteName: <your library name>
drive_id: b!6H_y8B...xU5
URL:      <your site URL>
```

## Configure the client's config file with the required 'drive_id'
4.  Once you have obtained the 'drive_id' above, add to your 'onedrive' configuration file (`~/.config/onedrive/config`) the following:
```text
drive_id = "insert the drive_id value from above here"
```
The OneDrive client will now be configured to sync this SharePoint shared library to your local system.

**Note:** After changing `drive_id`, you must perform a full re-synchronization by adding `--resync` to your existing command line.

## Test the configuration using '--dry-run'
5.  Test your new configuration using the `--dry-run` option to validate the the new configuration

## Sync the SharePoint Library as required
6.  Sync the SharePoint Library to your system with either `--synchronize` or `--monitor` operations


# How to configure multiple OneDrive SharePoint Shared Library sync
Refer to [./advanced-usage.md](advanced-usage.md) for configuration assistance.
