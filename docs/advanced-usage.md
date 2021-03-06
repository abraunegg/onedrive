# Advanced Configuration of the OneDrive Free Client
This document covers the following scenarios:
*   Configuring the client to use mulitple OneDrive accounts / configurations
*   Configuring the client for use in dual-boot (Windows / Linux) situations

## Configuring the client to use mulitple OneDrive accounts / configurations
Essentially, each OneDrive account or SharePoint Shared Library which you require to be synced needs to have its own and unique configuration, local sync directory and service files. To do this, the following steps are needed:
1.  Create a unique configuration folder for each onedrive client configuration that you need
2.  Copy to this folder a copy of the default configuration file
3.  Update the default configuration file as required, changing the required minimum config options and any additional options as needed to support your multi-account configuration
4.  Authenticate the client using the new configuration directory
5.  Test the configuration using '--display-config' and '--dry-run'
6.  Sync the OneDrive account data as required using `--synchronize` or `--monitor`
7.  Configure a unique systemd service file for this account configuration

### 1. Create a unique configuration folder for each onedrive client configuration that you need
Make the configuration folder as required for this new configuration, for example:
```text
mkdir ~/.config/my-new-config
```

### 2. Copy to this folder a copy of the default configuration file
Copy to this folder a copy of the default configuration file by downloading this file from GitHub and saving this file in the directory created above:
```text
wget https://raw.githubusercontent.com/abraunegg/onedrive/master/config -O ~/.config/my-new-config/config
```

### 3. Update the default configuration file
The following config options *must* be updated to ensure that individual account data is not cross populated with other OneDrive accounts or other configurations:
* sync_dir

Other options that may require to be updated, depending on the OneDrive account that is being configured:
*   drive_id
*   application_id
*   sync_business_shared_folders
*   skip_dir
*   skip_file
*   Creation of a 'sync_list' file if required
*   Creation of a 'business_shared_folders' file if required

### 4. Authenticate the client
Authenticate the client using the specific configuration file:
```text
onedrive --confdir="~/.config/my-new-config"
```
You will be asked to open a specific URL by using your web browser where you will have to login into your Microsoft Account and give the application the permission to access your files. After giving permission to the application, you will be redirected to a blank page. Copy the URI of the blank page into the application.
```text
[user@hostname ~]$ onedrive --confdir="~/.config/my-new-config"
Configuration file successfully loaded
Configuring Global Azure AD Endpoints
Authorize this app visiting:

https://.....

Enter the response uri: 

```

### 5. Display and Test the configuration
Test the configuration using '--display-config' and '--dry-run'. By doing so, this allows you to test any configuration that you have currently made, enabling you to fix this configuration before using the configuration.

#### Display the configuration
```text
onedrive --confdir="~/.config/my-new-config" --display-config
```

#### Test the configuration by performing a dry-run
```text
onedrive --confdir="~/.config/my-new-config" --synchronize --verbose --dry-run
```

If both of these operate as per your expectation, the configuration of this client setup is complete and validated. If not, amend your configuration as required.

### 6. Sync the OneDrive account data as required
Sync the data for the new account configuration as required:
```text
onedrive --confdir="~/.config/my-new-config" --synchronize --verbose
```
or 
```text
onedrive --confdir="~/.config/my-new-config" --monitor --verbose
```

*   `--synchronize` does a one-time sync
*   `--monitor` keeps the application running and monitoring for changes both local and remote

### 7. Automatic syncing of new OneDrive configuration
In order to automatically start syncing your OneDrive accounts, you will need to create a service file for each account. From the applicable 'systemd folder' where the applicable systemd service file exists:
*   RHEL / CentOS: `/usr/lib/systemd/system`
*   Others: `/usr/lib/systemd/user` and `/lib/systemd/system`

**Note:** The `onedrive.service` runs the service as the 'root' user, whereas the `onedrive@.service` runs the service as your user account.

Copy the required service file to a new name:
```text
cp onedrive.service onedrive-my-new-config.service
```
or 
```text
cp onedrive@.service onedrive-my-new-config@.service
```

Edit the line beginning with `ExecStart` so that the confdir mirrors the one you used above:
```text
ExecStart=/usr/local/bin/onedrive --monitor --confdir="/full/path/to/config/dir"
```

Example:
```text
ExecStart=/usr/local/bin/onedrive --monitor --confdir="/home/myusername/.config/my-new-config"
```

Then you can safely run these commands:
```text
systemctl --user enable onedrive-my-new-config
systemctl --user start onedrive-my-new-config
```
or
```text
systemctl --user enable onedrive-my-new-config@myusername.service
systemctl --user start onedrive-my-new-config@myusername.service
```

Repeat these steps for each OneDrive new account that you wish to use.

## Configuring the client for use in dual-boot (Windows / Linux) situations
When dual booting Windows and Linux, depending on the Windows OneDrive account configuration, the 'Files On-Demand' option may be enabled when running OneDrive within your Windows environment.

When this option is enabled in Windows, if you are sharing this location between your Windows  and Linux systems, all files will be a 0 byte link, and cannot be used under Linux.

To fix the problem of windows turning all files (that should be kept offline) into links, you have to uncheck a specific option in the onedrive settings window. The option in question is `Save space and download files as you use them`.

To find this setting, open the onedrive pop-up window from the taskbar, click "Help & Settings" > "Settings". This opens a new window. Go to the tab "Settings" and look for the section "Files On-Demand".

After unchecking the option and clicking "OK", the Windows OneDrive client should restart itself and start actually downloading your files so they will truely be available on your disk when offline. These files will then be fully accessible under Linux and the Linux OneDrive client.

| OneDrive Personal | Onedrive Business<br>SharePoint |
|---|---|
| ![Uncheck-Personal](./images/personal-files-on-demand.png) | ![Uncheck-Business](./images/business-files-on-demand.png) |
