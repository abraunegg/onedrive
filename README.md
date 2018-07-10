# OneDrive Free Client
###### A complete tool to interact with OneDrive on Linux. Built following the UNIX philosophy.

### Features:
* State caching
* Real-Time file monitoring with Inotify
* Resumable uploads
* Support OneDrive for Business (part of Office 365)
* Shared folders (not Business)

### What's missing:
* While local changes are uploaded right away, remote changes are delayed
* No GUI

## Setup

### Build Requirements
* Build environment must have at least 1GB of memory
* [libcurl](http://curl.haxx.se/libcurl/)
* [SQLite 3](https://www.sqlite.org/)
* [Digital Mars D Compiler (DMD)](http://dlang.org/download.html)

### Dependencies: Ubuntu/Debian
```sh
sudo apt install libcurl4-openssl-dev
sudo apt install libsqlite3-dev
curl -fsS https://dlang.org/install.sh | bash -s dmd
```

### Dependencies: Fedora < Version 18 / CentOS / RHEL 
```sh
sudo yum install libcurl-devel
sudo yum install sqlite-devel
curl -fsS https://dlang.org/install.sh | bash -s dmd
```

### Dependencies: Fedora > Version 18 
```sh
sudo dnf install libcurl-devel
sudo dnf install sqlite-devel
curl -fsS https://dlang.org/install.sh | bash -s dmd
```

Alternatively, if you are on a 64 bit system, you may also use the LLVM D Compiler (LDC):
```
sudo dnf install ldc
```

### Dependencies: Arch Linux
```sh
sudo pacman -S curl sqlite dmd
```

### Installation
```sh
git clone https://github.com/abraunegg/onedrive.git
cd onedrive
make
sudo make install
```

Using a different compiler (for example [LDC](https://wiki.dlang.org/LDC)):
```sh
make DC=ldmd2
```

**Note:** 32Bit / i686 operating systems are not supported when using this client.

### First run :zap:
After installing the application you must run it at least once from the terminal to authorize it.

You will be asked to open a specific link using your web browser where you will have to login into your Microsoft Account and give the application the permission to access your files. After giving the permission, you will be redirected to a blank page. Copy the URI of the blank page into the application.

### Performing a sync
By default all files are downloaded in `~/OneDrive`. After authorizing the application, a sync of your data can be performed by running:
```
onedrive --synchronize
```
This will synchronize files from your OneDrive account to your `~/OneDrive` local directory.

If you prefer to use your local files as stored in `~/OneDrive` as the 'source of truth' use the following sync command:
```
onedrive --synchronize --local-first
```

### Performing a selective directory sync
In some cases it may be desirable to sync a single directory under ~/OneDrive without having to change your client configuration. To do this use the following command:
```
onedrive --synchronize --single-directory '<dir_name>'
```

Example: If the full path is `~/OneDrive/mydir`, the command would be `onedrive --synchronize --single-directory 'mydir'`

### Performing a 'one-way' sync
In some cases it may be desirable to 'upload only' to OneDrive. To do this use the following command:
```
onedrive --synchronize --upload-only 
```

### Increasing logging level
When running a sync it may be desirable to see additional information as to the progress and operation of the client. To do this, use the following command:
```
onedrive --synchronize --verbose
```

### Client Activity Log
When running onedrive all actions are logged to `/var/log/onedrive/`

All logfiles will be in the format of `%username%.onedrive.log`

An example of the log file is below:
```
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

### Uninstall
```sh
sudo make uninstall
# delete the application state
rm -rf ~/.config/onedrive
```
If you are using the `--confdir option`, substitute `~/.config/onedrive` above for that directory.

If you want to just delete the application key, but keep the items database:
```
rm -f ~/.config/onedrive/refresh_token
```

## Additional Configuration
Additional configuration is optional. 
If you want to change the defaults, you can copy and edit the included config file into your `~/.config/onedrive` directory:
```sh
mkdir -p ~/.config/onedrive
cp ./config ~/.config/onedrive/config
nano ~/.config/onedrive/config
```
This file does not get created by default, and should only be created if you want to change the 'default' operational parameters. 

Available options:
* `sync_dir`: directory where the files will be synced
* `skip_file`: any files or directories that match this pattern will be skipped during sync.

### sync_dir
Example: `sync_dir="~/MyDirToSync"`

**Please Note:**
Proceed with caution here by changing the default sync dir from ~/OneDrive to ~/MyDirToSync

The issue here is around how the client stores the sync_dir path in the database. If the config file is missing, or you don't use the `--syncdir` parameter - what will happen is the client will default back to `~/OneDrive` and 'think' that either all your data has been deleted - thus delete the content on OneDrive, or will start downloading all data from OneDrive into the default location.

### skip_file
Example: `skip_file = ".*|~*|Desktop|Documents/OneNote*|Documents/IISExpress|Documents/SQL Server Management Studio|Documents/Visual Studio*|Documents/config.xlaunch|Documents/WindowsPowerShell"`

Patterns are case insensitive. `*` and `?` [wildcards characters](https://technet.microsoft.com/en-us/library/bb490639.aspx) are supported. Use `|` to separate multiple patterns.

Note: after changing `skip_file`, you must perform a full synchronization by executing `onedrive --resync`

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
```
Note: after changing the sync list, you must perform a full synchronization by executing `onedrive --resync`

### Shared folders
Folders shared with you can be synced by adding them to your OneDrive. To do that open your Onedrive, go to the Shared files list, right click on the folder you want to sync and then click on "Add to my OneDrive".

### OneDrive service
There are two ways that onedrive can be used as a service
* via init.d
* via systemd

**Note:** If using the service files, you may need to increase the `fs.inotify.max_user_watches` value on your system to handle the number of files in the directory you are monitoring as the initial value may be too low.

**init.d**

```
chkconfig onedrive on
service onedrive start
```
To see the logs run:
```
tail -f /var/log/onedrive/<username>.onedrive.log
```
To change what 'user' the client runs under (by default root), manually edit the init.d service file and modify `daemon --user root onedrive_service.sh` for the correct user.

**systemd**
```sh
systemctl --user enable onedrive
systemctl --user start onedrive
```

To see the logs run:
```sh
journalctl --user-unit onedrive -f
```

**Note:** systemd is supported on Ubuntu only starting from version 15.04

### Using multiple accounts
You can run multiple instances of the application specifying a different config directory in order to handle multiple OneDrive accounts.
To do this you can use the `--confdir` parameter.
Here is an example:
```sh
onedrive --synchronize --monitor --confdir="~/.config/onedrivePersonal" &
onedrive --synchronize --monitor --confdir="~/.config/onedriveWork" &
```

`--monitor` keeps the application running and monitoring for changes

`&` puts the application in background and leaves the terminal interactive

## Extra

### Reporting issues
If you encounter any bugs you can report them here on Github. Before filing an issue be sure to:

1. Check the version of the application you are using `onedrive --version`
2. Run the application in verbose mode `onedrive --verbose`
3. Have the log of the error (preferably uploaded on an external website such as [pastebin](https://pastebin.com/))
4. Collect any information that you may think it is relevant to the error
	- The steps to trigger the error
	- What have you already done to try solve it
	- ...

### All available commands:
```text
Usage: onedrive [OPTION]...

no option        		   No Sync and exit
       --check-for-nomount Check for the presence of .nosync in the syncdir root. If found, do not perform sync.
                 --confdir Set the directory used to store the configuration files
        --create-directory Create a directory on OneDrive - no sync will be performed.
   --destination-directory Destination directory for renamed or move on OneDrive - no sync will be performed.
              --debug-http Debug OneDrive HTTP communication.
-d              --download Only download remote changes
             --local-first Synchronize from the local directory source first, before downloading changes from OneDrive.
                  --logout Logout the current user
-m               --monitor Keep monitoring for local and remote changes
             --print-token Print the access token, useful for debugging
                  --resync Forget the last saved state, perform a full sync
        --remove-directory Remove a directory on OneDrive - no sync will be performed.
        --single-directory Specify a single local directory within the OneDrive root to sync.
        --source-directory Source directory to rename or move on OneDrive - no sync will be performed.
                 --syncdir Set the directory used to sync the files that are synced
             --synchronize Perform a synchronization
             --upload-only Only upload to OneDrive, do not sync changes from OneDrive locally
-v               --verbose Print more details, useful for debugging
                 --version Print the version and exit
-h                  --help This help information.
```

### File naming
The files and directories in the synchronization directory must follow the [Windows naming conventions](https://msdn.microsoft.com/en-us/library/aa365247).
The application will crash for example if you have two files with the same name but different case. This is expected behavior and won't be fixed.
