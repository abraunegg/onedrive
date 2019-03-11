# OneDrive Free Client
A complete tool to interact with OneDrive on Linux. Built following the UNIX philosophy

## Features
*   State caching
*   Real-Time file monitoring with Inotify
*   Resumable uploads
*   Support OneDrive for Business (part of Office 365)
*   Shared folders (OneDrive Personal)
*   SharePoint / Office 365 Shared Libraries (refer to README.Office365.md to configure)
*   Notifications

## What's missing
*   While local changes are uploaded right away, remote changes are delayed
*   No GUI

## Build Requirements
*   Build environment must have at least 1GB of memory & 1GB swap space
*   [libcurl](http://curl.haxx.se/libcurl/)
*   [SQLite 3](https://www.sqlite.org/) >= 3.7.15
*   [Digital Mars D Compiler (DMD)](http://dlang.org/download.html)

**Note:** DMD version >= 2.081.1 or LDC version >= 1.11.0 is required to compile this application

### Dependencies: Ubuntu/Debian - x86_64
```text
sudo apt install build-essential
sudo apt install libcurl4-openssl-dev
sudo apt install libsqlite3-dev
curl -fsS https://dlang.org/install.sh | bash -s dmd
```
For notifications the following is necessary:
```text
sudo apt install libnotify-dev
```

### Dependencies: Ubuntu - i386 / i686
**Note:** Validated with `Linux ubuntu-i386-vm 4.13.0-36-generic #40~16.04.1-Ubuntu SMP Fri Feb 16 23:26:51 UTC 2018 i686 i686 i686 GNU/Linux` and DMD 2.081.1
```text
sudo apt install build-essential
sudo apt install libcurl4-openssl-dev
sudo apt install libsqlite3-dev
curl -fsS https://dlang.org/install.sh | bash -s dmd
```
For notifications the following is necessary:
```text
sudo apt install libnotify-dev
```

### Dependencies: Debian - i386 / i686
**Note:** Validated with `Linux debian-i386 4.9.0-8-686-pae #1 SMP Debian 4.9.130-2 (2018-10-27) i686 GNU/Linux` and LDC - the LLVM D compiler (1.12.0).

First install development dependencies as per below:
```text
sudo apt install build-essential
sudo apt install libcurl4-openssl-dev
sudo apt install libsqlite3-dev
sudo apt install git
```
Second, install the LDC compiler as per below:
```text
mkdir ldc && cd ldc
wget http://httpredir.debian.org/debian/pool/main/g/gcc-8/gcc-8-base_8.2.0-19_i386.deb
wget http://httpredir.debian.org/debian/pool/main/g/gcc-8/libgcc1_8.2.0-19_i386.deb
wget http://httpredir.debian.org/debian/pool/main/l/ldc/libphobos2-ldc-shared82_1.12.0-1_i386.deb
wget http://httpredir.debian.org/debian/pool/main/l/ldc/libphobos2-ldc-shared-dev_1.12.0-1_i386.deb
wget http://httpredir.debian.org/debian/pool/main/l/ldc/ldc_1.12.0-1_i386.deb
wget http://httpredir.debian.org/debian/pool/main/l/llvm-toolchain-6.0/libllvm6.0_6.0.1-10_i386.deb
wget http://httpredir.debian.org/debian/pool/main/n/ncurses/libtinfo6_6.1+20181013-1_i386.deb
sudo dpkg -i ./*.deb
```
For notifications the following is necessary:
```text
sudo apt install libnotify-dev
```

### Dependencies: Fedora < Version 18 / CentOS / RHEL
```text
sudo yum groupinstall 'Development Tools'
sudo yum install libcurl-devel
sudo yum install sqlite-devel
curl -fsS https://dlang.org/install.sh | bash -s dmd
```
For notifications the following is necessary:
```text
sudo yum install libnotify-devel
```

### Dependencies: CentOS 6.x / RHEL 6.x
In addition to the above requirements, the `sqlite` version used on CentOS 6.x / RHEL 6.x needs to be upgraded. Use the following instructions to update your version of `sqlite` so that it can support the client:
```text
sudo yum -y update
sudo yum -y install epel-release, wget
sudo yum -y install mock
wget https://kojipkgs.fedoraproject.org//packages/sqlite/3.7.15.2/2.fc19/src/sqlite-3.7.15.2-2.fc19.src.rpm
sudo mock --rebuild sqlite-3.7.15.2-2.fc19.src.rpm
sudo yum -y upgrade /var/lib/mock/epel-6-{arch}/result/sqlite-*
```

### Dependencies: Fedora > Version 18
```text
sudo dnf groupinstall 'Development Tools'
sudo dnf install libcurl-devel
sudo dnf install sqlite-devel
curl -fsS https://dlang.org/install.sh | bash -s dmd
```
For notifications the following is necessary:
```text
sudo yum install libnotify-devel
```

### Dependencies: Arch Linux
```text
sudo pacman -S curl sqlite dmd
```
For notifications the following is necessary:
```text
sudo pacman -S libnotify
```

### Dependencies: Raspbian (ARMHF)
```text
sudo apt-get install libcurl4-openssl-dev
sudo apt-get install libsqlite3-dev
wget https://github.com/ldc-developers/ldc/releases/download/v1.11.0/ldc2-1.11.0-linux-armhf.tar.xz
tar -xvf ldc2-1.11.0-linux-armhf.tar.xz
```
For notifications the following is necessary:
```text
sudo apt install libnotify-dev
```

### Dependencies: Debian (ARM64)
```text
sudo apt-get install libcurl4-openssl-dev
sudo apt-get install libsqlite3-dev
wget https://github.com/ldc-developers/ldc/releases/download/v1.11.0/ldc2-1.11.0-linux-aarch64.tar.xz
tar -xvf ldc2-1.11.0-linux-aarch64.tar.xz
```
For notifications the following is necessary:
```text
sudo apt install libnotify-dev
```

### Dependencies: Gentoo
```text
sudo emerge app-portage/layman
sudo layman -a dlang
```
Add ebuild from contrib/gentoo to a local overlay to use.

For notifications the following is necessary:
```text
sudo emerge x11-libs/libnotify
```

### Dependencies: OpenSuSE Leap 15.0
```text
sudo zypper addrepo --check --refresh --name "D" http://download.opensuse.org/repositories/devel:/languages:/D/openSUSE_Leap_15.0/devel:languages:D.repo
sudo zypper install git libcurl-devel sqlite3-devel D:dmd D:libphobos2-0_81 D:phobos-devel D:phobos-devel-static
```
For notifications the following is necessary:
```text
sudo zypper install libnotify-devel
```

## Compilation & Installation
### Building using DMD Reference Compiler
Before cloning and compiling, if you have installed DMD via curl for your OS, you will need to activate DMD as per example below:
```text
Run `source ~/dlang/dmd-2.081.1/activate` in your shell to use dmd-2.081.1.
This will setup PATH, LIBRARY_PATH, LD_LIBRARY_PATH, DMD, DC, and PS1.
Run `deactivate` later on to restore your environment.
```
Without performing this step, the compilation process will fail.

**Note:** Depending on your DMD version, substitute `2.081.1` above with your DMD version that is installed.

```text
git clone https://github.com/abraunegg/onedrive.git
cd onedrive
make
sudo make install
```

### Build options

By passing `PKGCONFIG=1` to the `make` call, necessary libraries (`sqlite3`,
`curl`, and `libnotify` for notifications) are searched for using `pkg-config`
instead of using the hard-coded values.

By passing `NOTIFICATIONS=1` to the `make` call, notifications via
libnotify are enabled. If `pkg-config` is not used (see above), the necessary
libraries are `gmodule-2.0`, `glib-2.0`, and `notify`.

### Building using a different compiler (for example [LDC](https://wiki.dlang.org/LDC))
#### Debian - i386 / i686
```text
git clone https://github.com/abraunegg/onedrive.git
cd onedrive
make DC=/usr/bin/ldc2
sudo make install
```

#### ARMHF Architecture
```text
git clone https://github.com/abraunegg/onedrive.git
cd onedrive
make DC=~/ldc2-1.11.0-linux-armhf/bin/ldmd2
sudo make install
```

#### ARM64 Architecture
```text
git clone https://github.com/abraunegg/onedrive.git
cd onedrive
make DC=~/ldc2-1.11.0-linux-aarch64/bin/ldmd2
sudo make install
```

#### Docker onedrive monitor
```text
# Update onedriveDir with correct existing OneDrive directory path
onedriveDir="${HOME}/OneDrive"

firstRun='-d'
docker pull driveone/onedrive
docker inspect onedrive_conf > /dev/null || { docker volume create onedrive_conf; firstRun='-it'; }
docker inspect onedrive > /dev/null && docker rm -f onedrive
docker run $firstRun --restart unless-stopped --name onedrive -v onedrive_conf:/onedrive/conf -v "${onedriveDir}:/onedrive/data" driveone/onedrive
```

## Using the client
### Upgrading from 'skilion' client
The 'skilion' version contains a significant number of defect's in how the local sync state is managed. When upgrading from the 'skilion' version to this version, it is advisable to stop any service / onedrive process from running and then remove any `items.sqlite3` file from your configuration directory (`~/.config/onedrive/`) as this will force the creation of a new local cache file.

Additionally, if you are using a 'config' file within your configuration directory (`~/.config/onedrive/`), please ensure that you update the `skip_file = ` option as per below:

**Invalid configuration:**
```text
skip_file = "= .*|~*"
```
**Minimum valid configuration:**
```text
skip_file = "~*"
```
Do not use a skip_file entry of `.*` as this will prevent correct searching of local changes to process.

### Important - curl compatibility
If your system utilises curl >= 7.62.0 you may need to use `--force-http-1.1` in order for the client to work correctly due to changes in curl to prefer HTTP/2 over HTTP/1.1 by default.

### First run :zap:
After installing the application you must run it at least once from the terminal to authorize it.

You will be asked to open a specific link using your web browser where you will have to login into your Microsoft Account and give the application the permission to access your files. After giving the permission, you will be redirected to a blank page. Copy the URI of the blank page into the application.
```text
[user@hostname ~]$ onedrive 

Authorize this app visiting:

https://.....

Enter the response uri: 

```

### Testing your configuration
You are able to test your configuration by utilising the `--dry-run` CLI option. No files will be downloaded, uploaded or removed, however the application will display what 'would' have occurred. For example:
```text
onedrive --synchronize --verbose --dry-run
DRY-RUN Configured. Output below shows what 'would' have occurred.
Loading config ...
Using Config Dir: /home/user/.config/onedrive
Initializing the OneDrive API ...
Opening the item database ...
All operations will be performed in: /home/user/OneDrive
Initializing the Synchronization Engine ...
Account Type: personal
Default Drive ID: <redacted>
Default Root ID: <redacted>
Remaining Free Space: 5368709120
Fetching details for OneDrive Root
OneDrive Root exists in the database
Syncing changes from OneDrive ...
Applying changes of Path ID: <redacted>
Uploading differences of .
Processing root
The directory has not changed
Uploading new items of .
OneDrive Client requested to create remote path: ./newdir
The requested directory to create was not found on OneDrive - creating remote directory: ./newdir
Successfully created the remote directory ./newdir on OneDrive
Uploading new file ./newdir/newfile.txt ... done.
Remaining free space: 5368709076
Applying changes of Path ID: <redacted>
```

**Note:** `--dry-run` can only be used with `--synchronize`. It cannot be used with `--monitor` and will be ignored.

### Show your configuration
To validate your configuration the application will use, utilise the following:
```text
onedrive --display-config
```
This will display all the pertinent runtime interpretation of the options and configuration you are using. This is helpful to validate the client will perform the operations your asking without performing a sync. Example output is as follows:
```text
Config path                         = /home/alex/.config/onedrive
Config file found in config path    = false
Config option 'sync_dir'            = /home/alex/OneDrive
Config option 'skip_dir'            = 
Config option 'skip_file'           = ~*
Config option 'skip_dotfiles'       = false
Config option 'skip_symlinks'       = false
Config option 'monitor_interval'    = 45
Config option 'min_notif_changes'   = 5
Config option 'log_dir'             = /var/log/onedrive/
Selective sync configured           = false
```

### Performing a sync
By default all files are downloaded in `~/OneDrive`. After authorizing the application, a sync of your data can be performed by running:
```text
onedrive --synchronize
```
This will synchronize files from your OneDrive account to your `~/OneDrive` local directory.

If you prefer to use your local files as stored in `~/OneDrive` as the 'source of truth' use the following sync command:
```text
onedrive --synchronize --local-first
```

### Performing a selective directory sync
In some cases it may be desirable to sync a single directory under ~/OneDrive without having to change your client configuration. To do this use the following command:
```text
onedrive --synchronize --single-directory '<dir_name>'
```

Example: If the full path is `~/OneDrive/mydir`, the command would be `onedrive --synchronize --single-directory 'mydir'`

### Performing a 'one-way' download sync
In some cases it may be desirable to 'download only' from OneDrive. To do this use the following command:
```text
onedrive --synchronize --download-only 
```

### Performing a 'one-way' upload sync
In some cases it may be desirable to 'upload only' to OneDrive. To do this use the following command:
```text
onedrive --synchronize --upload-only
```

### Increasing logging level
When running a sync it may be desirable to see additional information as to the progress and operation of the client. To do this, use the following command:
```text
onedrive --synchronize --verbose
```

### Client Activity Log
When running onedrive all actions can be logged to a separate log file. This can be enabled by using the `--enable-logging` flag. By default, log files will be written to `/var/log/onedrive/`

**Note:** You will need to ensure your user has the applicable permissions to write to this directory or the following warning will be printed:
```text
Unable to access /var/log/onedrive/
Please manually create '/var/log/onedrive/' and set appropriate permissions to allow write access
The requested client activity log will instead be located in the users home directory
```

All logfiles will be in the format of `%username%.onedrive.log`, where `%username%` represents the user who ran the client.

**Note:**
To use a different log directory rather than the default above, add the following as a configuration option to `~/.config/onedrive/config`:
```text
log_dir = "/path/to/location/"
```
Trailing slash required

An example of the log file is below:
```text
2018-Apr-07 17:09:32.1162837 Loading config ...
2018-Apr-07 17:09:32.1167908 No config file found, using defaults
2018-Apr-07 17:09:32.1170626 Initializing the OneDrive API ...
2018-Apr-07 17:09:32.5359143 Opening the item database ...
2018-Apr-07 17:09:32.5515295 All operations will be performed in: /root/OneDrive
2018-Apr-07 17:09:32.5518387 Initializing the Synchronization Engine ...
2018-Apr-07 17:09:36.6701351 Applying changes of Path ID: <redacted>
2018-Apr-07 17:09:37.4434282 Adding OneDrive Root to the local database
2018-Apr-07 17:09:37.4478342 The item is already present
2018-Apr-07 17:09:37.4513752 The item is already present
2018-Apr-07 17:09:37.4550062 The item is already present
2018-Apr-07 17:09:37.4586444 The item is already present
2018-Apr-07 17:09:37.7663571 Adding OneDrive Root to the local database
2018-Apr-07 17:09:37.7739451 Fetching details for OneDrive Root
2018-Apr-07 17:09:38.0211861 OneDrive Root exists in the database
2018-Apr-07 17:09:38.0215375 Uploading differences of .
2018-Apr-07 17:09:38.0220464 Processing <redacted>
2018-Apr-07 17:09:38.0224884 The directory has not changed
2018-Apr-07 17:09:38.0229369 Processing <redacted>
2018-Apr-07 17:09:38.02338 The directory has not changed
2018-Apr-07 17:09:38.0237678 Processing <redacted>
2018-Apr-07 17:09:38.0242285 The directory has not changed
2018-Apr-07 17:09:38.0245977 Processing <redacted>
2018-Apr-07 17:09:38.0250788 The directory has not changed
2018-Apr-07 17:09:38.0254657 Processing <redacted>
2018-Apr-07 17:09:38.0259923 The directory has not changed
2018-Apr-07 17:09:38.0263547 Uploading new items of .
2018-Apr-07 17:09:38.5708652 Applying changes of Path ID: <redacted>
```

### Notifications
If notification support is compiled in, the following events will trigger a notification within the display manager session:
*   Aborting a sync if .nosync file is found
*   Cannot create remote directory
*   Cannot upload file changes
*   Cannot delete remote file / folder
*   Cannot move remote file / folder

### Uninstall
```text
sudo make uninstall
# delete the application state
rm -rf ~/.config/onedrive
```
If you are using the `--confdir option`, substitute `~/.config/onedrive` above for that directory.

If you want to just delete the application key, but keep the items database:
```text
rm -f ~/.config/onedrive/refresh_token
```

### Handling a OneDrive account password change
If you change your OneDrive account password, the client will no longer be authorised to sync, and will generate the following error:
```text
ERROR: OneDrive returned a 'HTTP 401 Unauthorized' - Cannot Initialize Sync Engine
```
To re-authorise the client, follow the steps below:
1.   If running the client as a service (init.d or systemd), stop the service
2.   Run the command `onedrive --logout`. This will clean up the previous authorisation, and will prompt you to re-authorise as per initial configuration.
3.   Restart the client if running as a service or perform a manual sync

The application will now sync with OneDrive with the new credentials.

## Additional Configuration
Additional configuration is optional.
If you want to change the defaults, you can copy and edit the included config file into your `~/.config/onedrive` directory:
```text
mkdir -p ~/.config/onedrive
cp ./config ~/.config/onedrive/config
nano ~/.config/onedrive/config
```
This file does not get created by default, and should only be created if you want to change the 'default' operational parameters.

Available options:
*   `sync_dir`: directory where the files will be synced
*   `skip_file`: any files or directories that match this pattern will be skipped during sync
*   `skip_dotfiles`: skip any .files or .folders during sync
*   `skip_symlinks`: any files or directories that are symlinked will be skipped during sync
*   `monitor_interval`: time interval in seconds by which the monitor process will process local and remote changes
*   `min_notif_changes`: minimum number of pending incoming changes to trigger a desktop notification

### sync_dir
Example: `sync_dir="~/MyDirToSync"`

**Please Note:**
Proceed with caution here when changing the default sync dir from ~/OneDrive to ~/MyDirToSync

The issue here is around how the client stores the sync_dir path in the database. If the config file is missing, or you don't use the `--syncdir` parameter - what will happen is the client will default back to `~/OneDrive` and 'think' that either all your data has been deleted - thus delete the content on OneDrive, or will start downloading all data from OneDrive into the default location.

### skip_dir
Example: `skip_dir = "Desktop|Documents/IISExpress|Documents/SQL Server Management Studio|Documents/Visual Studio*|Documents/WindowsPowerShell"`

Patterns are case insensitive. `*` and `?` [wildcards characters](https://technet.microsoft.com/en-us/library/bb490639.aspx) are supported. Use `|` to separate multiple patterns.

**Note:** after changing `skip_dir`, you must perform a full re-synchronization by adding `--resync` to your existing command line - for example: `onedrive --synchronize --resync`

### skip_file
Example: `skip_file = "~*|Documents/OneNote*|Documents/config.xlaunch|myfile.ext"`

Patterns are case insensitive. `*` and `?` [wildcards characters](https://technet.microsoft.com/en-us/library/bb490639.aspx) are supported. Use `|` to separate multiple patterns.

Files can be skipped in the following fashion:
*   Specify a wildcard, eg: '*.txt' (skip all txt files)
*   Explicitly specify the filename and it's full path relative to your sync_dir, eg: 'path/to/file/filename.ext'
*   Explicitly specify the filename only and skip every instance of this filename, eg: 'filename.ext'

**Note:** after changing `skip_file`, you must perform a full re-synchronization by adding `--resync` to your existing command line - for example: `onedrive --synchronize --resync`

**Note:** Do not use a skip_file entry of `.*` as this will prevent correct searching of local changes to process.

### skip_dotfiles
Example: `skip_dotfiles = "true"`

Setting this to `"true"` will skip all .files and .folders while syncing.

### skip_symlinks
Example: `skip_symlinks = "true"`

Setting this to `"true"` will skip all symlinks while syncing.

### monitor_interval
Example: `monitor_interval = "300"`

The monitor interval is defined as the wait time 'between' sync's when running in monitor mode. By default without configuration, the monitor_interval is set to 45 seconds. Setting this value to 300 will run the sync process every 5 minutes.

### min_notif_changes
Example: `min_notif_changes = "5"`

This option defines the minimum number of pending incoming changes necessary to trigger a desktop notification. This allows controlling the frequency of notifications.

### Selective sync
Selective sync allows you to sync only specific files and directories.
To enable selective sync create a file named `sync_list` in `~/.config/onedrive`.
Each line of the file represents a relative path from your `sync_dir`. All files and directories not matching any line of the file will be skipped during all operations.
Here is an example of `sync_list`:
```text
Backup
Documents/latest_report.docx
Work/ProjectX
notes.txt
Blender
Cinema Soc
Codes
Textbooks
Year 2
```
**Note:** after changing the sync_list, you must perform a full re-synchronization by adding `--resync` to your existing command line - for example: `onedrive --synchronize --resync`

### Skipping directories from syncing
There are several mechanisms available to 'skip' a directory from scanning:
*   Utilise 'skip_dir'
*   Utilise 'sync_list'

One further method is to add a '.nosync' empty file to any folder. When this file is present, adding `--check-for-nosync` to your command line will now make the sync process skip any folder where the '.nosync' file is present.

To make this a permanent change to always skip folders when a '.nosync' empty file is present, add the following to your config file:

Example: `check_nosync = "true"`

### Shared folders
Folders shared with you can be synced by adding them to your OneDrive. To do that open your Onedrive, go to the Shared files list, right click on the folder you want to sync and then click on "Add to my OneDrive".

### OneDrive service running as root user
There are two ways that onedrive can be used as a service
*   via init.d
*   via systemd

**Note:** If using the service files, you may need to increase the `fs.inotify.max_user_watches` value on your system to handle the number of files in the directory you are monitoring as the initial value may be too low.

**init.d**

```text
chkconfig onedrive on
service onedrive start
```
To see the logs run:
```text
tail -f /var/log/onedrive/<username>.onedrive.log
```
To change what 'user' the client runs under (by default root), manually edit the init.d service file and modify `daemon --user root onedrive_service.sh` for the correct user.

**systemd - Arch, Ubuntu, Debian, OpenSuSE, Fedora**
```text
systemctl --user enable onedrive
systemctl --user start onedrive
```

To see the logs run:
```text
journalctl --user-unit onedrive -f
```

**systemd - Red Hat Enterprise Linux, CentOS Linux**
```text
systemctl enable onedrive
systemctl start onedrive
```

To see the logs run:
```text
journalctl onedrive -f
```

### OneDrive service running as a non-root user via systemd

In some cases it is desirable to run the OneDrive client as a service, but not running as the 'root' user. In this case, follow the directions below to configure the service for a non-root user.

1.  As the user, who will be running the service, run the application in standalone mode, authorize the application for use & validate that the synchronization is working as expected:
```text
onedrive --synchronize --verbose
```
2.  Once the application is validated and working for your user, as the 'root' user, where <username> is your username from step 1 above.
```text
systemctl enable onedrive@<username>.service
systemctl start onedrive@<username>.service
```

3.  To view the status of the service running for the user, use the following:
```text
systemctl status onedrive@username.service
```

### Using multiple OneDrive accounts
You can run multiple instances of the application by specifying a different config directory in order to handle multiple OneDrive accounts. For example, if you have a work and a personal account, you can run the onedrive command using the --confdir parameter. Here is an example:

```text
onedrive --synchronize --verbose --confdir="~/.config/onedrivePersonal" &
onedrive --synchronize --verbose --confdir="~/.config/onedriveWork" &
```
or 
```text
onedrive --monitor --verbose --confdir="~/.config/onedrivePersonal" &
onedrive --monitor --verbose --confdir="~/.config/onedriveWork" &
```

*   `--synchronize` does a one-time sync
*   `--monitor` keeps the application running and monitoring for changes both local and remote
*   `&` puts the application in background and leaves the terminal interactive

### Automatic syncing of both OneDrive accounts

In order to automatically start syncing your OneDrive accounts, you will need to create a service file for each account. From the `~/onedrive` folder:
```text
cp onedrive.service onedrive-work.service
```
And edit the line beginning with `ExecStart` so that the command mirrors the one you used above:
```text
ExecStart=/usr/local/bin/onedrive --monitor --confdir="/path/to/config/dir"
```
Then you can safely run these commands:
```text
systemctl --user enable onedrive-work
systemctl --user start onedrive-work
```
Repeat these steps for each OneDrive account that you wish to use.

### Access OneDrive service through a proxy
If you have a requirement to run the client through a proxy, there are a couple of ways to achieve this:
1.  Set proxy configuration in `~/.bashrc` to allow the authorization process and when utilizing `--synchronize`
2.  If running as a systemd service, edit the applicable systemd service file to include the proxy configuration information:
```text
[Unit]
Description=OneDrive Free Client
Documentation=https://github.com/abraunegg/onedrive
After=network-online.target
Wants=network-online.target

[Service]
Environment="HTTP_PROXY=http://ip.address:port"
Environment="HTTPS_PROXY=http://ip.address:port"
ExecStart=/usr/local/bin/onedrive --monitor
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
```

**Note:** After modifying the service files, you will need to run `sudo systemctl daemon-reload` to ensure the service file changes are picked up. A restart of the OneDrive service will also be required to pick up the change to send the traffic via the proxy server

## Extra

### Reporting issues
If you encounter any bugs you can report them here on Github. Before filing an issue be sure to:

1.  Check the version of the application you are using `onedrive --version` and ensure that you are running either the latest [release](https://github.com/abraunegg/onedrive/releases) or built from master.
2.  Fill in a new bug report using the [issue template](https://github.com/abraunegg/onedrive/issues/new?template=bug_report.md)
3.  Generate a debug log for support using the following [process](https://github.com/abraunegg/onedrive/wiki/Generate-debug-log-for-support)
4.  Upload the debug log to [pastebin](https://pastebin.com/) or archive and email to support@mynas.com.au 

### All available commands
Output of `onedrive --help`
```text
OneDrive - a client for OneDrive Cloud Services

Usage:
  onedrive [options] --synchronize
      Do a one time synchronization
  onedrive [options] --monitor
      Monitor filesystem and sync regularly
  onedrive [options] --display-config
      Display the currently used configuration
  onedrive [options] --display-sync-status
      Query OneDrive service and report on pending changes
  onedrive -h | --help
      Show this help screen
  onedrive --version
      Show version

Options:

  --check-for-nomount
      Check for the presence of .nosync in the syncdir root. If found, do not perform sync.
  --check-for-nosync
      Check for the presence of .nosync in each directory. If found, skip directory from sync.
  --confdir ARG
      Set the directory used to store the configuration files
  --create-directory ARG
      Create a directory on OneDrive - no sync will be performed.
  --destination-directory ARG
      Destination directory for renamed or move on OneDrive - no sync will be performed.
  --debug-https
      Debug OneDrive HTTPS communication.
  --disable-notifications
      Do not use desktop notifications in monitor mode.
  --display-config
      Display what options the client will use as currently configured - no sync will be performed.
  --display-sync-status
      Display the sync status of the client - no sync will be performed.
  -d --download-only
      Only download remote changes
  --disable-upload-validation
      Disable upload validation when uploading to OneDrive
  --dry-run
      Perform a trial sync with no changes made	  
  --enable-logging
      Enable client activity to a separate log file
  --force-http-1.1
      Force the use of HTTP 1.1 for all operations
  --get-O365-drive-id ARG
      Query and return the Office 365 Drive ID for a given Office 365 SharePoint Shared Library
  --local-first
      Synchronize from the local directory source first, before downloading changes from OneDrive.
  --logout
      Logout the current user
  -m --monitor
      Keep monitoring for local and remote changes
  --no-remote-delete
      Do not delete local file 'deletes' from OneDrive when using --upload-only
  --print-token
      Print the access token, useful for debugging
  --resync
      Forget the last saved state, perform a full sync
  --remove-directory ARG
      Remove a directory on OneDrive - no sync will be performed.
  --single-directory ARG
      Specify a single local directory within the OneDrive root to sync.
  --skip-dot-files
      Skip dot files and folders from syncing
  --skip-symlinks
      Skip syncing of symlinks
  --source-directory ARG
      Source directory to rename or move on OneDrive - no sync will be performed.
  --syncdir ARG
      Specify the local directory used for synchronization to OneDrive
  --synchronize
      Perform a synchronization
  --upload-only
      Only upload to OneDrive, do not sync changes from OneDrive locally
  -v+ --verbose
      Print more details, useful for debugging (repeat for extra debugging)
  --version
      Print the version and exit
  -h --help
      This help information.
```

### File naming
The files and directories in the synchronization directory must follow the [Windows naming conventions](https://msdn.microsoft.com/en-us/library/aa365247).
The application will attempt to handle instances where you have two files with the same name but different case. Where there is a namespace clash, the file name which clashes will not be synced. This is expected behavior and won't be fixed.
