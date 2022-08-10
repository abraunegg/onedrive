# How to configure OneDrive SharePoint Shared Library sync
Syncing a OneDrive SharePoint library requires additional configuration for your 'onedrive' client:
1.  Login to OneDrive and under 'Shared Libraries' obtain the shared library name
2.  Query that shared library name using the client to obtain the required configuration details
3.  Create a unique local folder which will be the SharePoint Library 'root'
4.  Configure the client's config file with the required 'drive_id'
5.  Test the configuration using '--dry-run'
6.  Sync the SharePoint Library as required

**Note:** The `--get-O365-drive-id` process below requires a fully configured 'onedrive' configuration so that the applicable Drive ID for the given Office 365 SharePoint Shared Library can be determined. It is highly recommended that you do not use the application 'default' configuration directory for any SharePoint Site, and configure separate items for each site you wish to use.

## 1. Listing available OneDrive SharePoint Libraries
Login to the OneDrive web interface and determine which shared library you wish to configure the client for:
![shared_libraries](./images/SharedLibraries.jpg)

## 2. Query that shared library name using the client to obtain the required configuration details
Run the following command using the 'onedrive' client
```text
onedrive --get-O365-drive-id '<your site name to search>'
```
This will return something similar to the following:
```text
Configuration file successfully loaded
Configuring Global Azure AD Endpoints
Initializing the Synchronization Engine ...
Office 365 Library Name Query: <your site name to search>
-----------------------------------------------
Site Name:    <your site name>
Library Name: <your library name>
drive_id:     b!6H_y8B...xU5
Library URL:  <your library URL>
-----------------------------------------------
```
If there are no matches to the site you are attempting to search, the following will be displayed:
```text
Configuration file successfully loaded
Configuring Global Azure AD Endpoints
Initializing the Synchronization Engine ...
Office 365 Library Name Query: blah

ERROR: The requested SharePoint site could not be found. Please check it's name and your permissions to access the site.

The following SharePoint site names were returned:
 * <site name 1>
 * <site name 2>
 ...
 * <site name X>
```
This list of site names can be used as a basis to search for the correct site for which you are searching

## 3. Create a new configuration directory and sync location for this SharePoint Library
Create a new configuration directory for this SharePoint Library in the following manner:
```text
mkdir ~/.config/SharePoint_My_Library_Name
```

Create a new local folder to store the SharePoint Library data in
```text
mkdir ~/SharePoint_My_Library_Name
```

**Note:** Do not use spaces in the directory name, use '_' as a replacement

## 4. Configure SharePoint Library config file with the required 'drive_id' & 'sync_dir' options

Download a copy of the default configuration file by downloading this file from GitHub and saving this file in the directory created above:
```text
wget https://raw.githubusercontent.com/abraunegg/onedrive/master/config -O ~/.config/SharePoint_My_Library_Name/config
```

Update your 'onedrive' configuration file (`~/.config/SharePoint_My_Library_Name/config`) with the local folder where you will store your data:
```text
sync_dir = "~/SharePoint_My_Library_Name"
```

Update your 'onedrive' configuration file(`~/.config/SharePoint_My_Library_Name/config`) with the 'drive_id' value obtained in the steps above:
```text
drive_id = "insert the drive_id value from above here"
```
The OneDrive client will now be configured to sync this SharePoint shared library to your local system and the location you have configured.

**Note:** After changing `drive_id`, you must perform a full re-synchronization by adding `--resync` to your existing command line.

## 5. Validate and Test the configuration
Validate your new configuration using the `--display-config` option to validate you have configured the application correctly:
```text
onedrive --confdir="~/.config/SharePoint_My_Library_Name" --display-config
```

Test your new configuration using the `--dry-run` option to validate the application configuration:
```text
onedrive --confdir="~/.config/SharePoint_My_Library_Name" --synchronize --verbose --dry-run
```

## 6. Sync the SharePoint Library as required
Sync the SharePoint Library to your system with either `--synchronize` or `--monitor` operations:
```text
onedrive --confdir="~/.config/SharePoint_My_Library_Name" --synchronize --verbose
```

```text
onedrive --confdir="~/.config/SharePoint_My_Library_Name" --monitor --verbose
```

## 7. Enable systemd service 
Systemd can be used to automatically run this configuration in the background, however, a unique systemd service will need to be setup for this SharePoint Library instance

In order to automatically start syncing each SharePoint Library, you will need to create a service file for each SharePoint Library. From the applicable 'systemd folder' where the applicable systemd service file exists:
*   RHEL / CentOS: `/usr/lib/systemd/system`
*   Others: `/usr/lib/systemd/user` and `/lib/systemd/system`

**Note:** The `onedrive.service` runs the service as the 'root' user, whereas the `onedrive@.service` runs the service as your user account.

Copy the required service file to a new name:
```text
cp onedrive.service onedrive-SharePoint_My_Library_Name.service
```
or 
```text
cp onedrive@.service onedrive-SharePoint_My_Library_Name@.service
```

Edit the new file , updating the line beginning with `ExecStart` so that the confdir mirrors the one you used above:
```text
ExecStart=/usr/local/bin/onedrive --monitor --confdir="/full/path/to/config/dir"
```

Example:
```text
ExecStart=/usr/local/bin/onedrive --monitor --confdir="/home/myusername/.config/my-new-config"
```

Then you can safely run these commands:
### Custom systemd service on Red Hat Enterprise Linux, CentOS Linux
```text
systemctl enable onedrive-SharePoint_My_Library_Name
systemctl start onedrive-SharePoint_My_Library_Name
```

### Custom systemd service on Arch, Ubuntu, Debian, OpenSuSE, Fedora
```text
systemctl --user enable onedrive-SharePoint_My_Library_Name
systemctl --user start onedrive-SharePoint_My_Library_Name
```
or
```text
systemctl --user enable onedrive-SharePoint_My_Library_Name@myusername.service
systemctl --user start onedrive-SharePoint_My_Library_Name@myusername.service
```

### Viewing systemd logs for the custom service
```text
journalctl --unit=onedrive-my-new-config -f
```

Repeat these steps for each SharePoint Library that you wish to use.

# How to configure multiple OneDrive SharePoint Shared Library sync
Create a new configuration as per the process above.
