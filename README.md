# OneDrive Free Client
###### A complete tool to interact with OneDrive on Linux. Built following the UNIX philosophy.

### Features:
* State caching
* Real-Time file monitoring with Inotify
* Resumable uploads
* Support OneDrive for Business (part of Office 365)
* Shared folders :scream:

### What's missing:
* While local changes are uploaded right away, remote changes are delayed
* No GUI

## Setup

### Dependencies
* [libcurl](http://curl.haxx.se/libcurl/)
* [SQLite 3](https://www.sqlite.org/)
* [Digital Mars D Compiler (DMD)](http://dlang.org/download.html)

### Dependencies: Ubuntu/Debian
```sh
sudo apt install libcurl4-openssl-dev
sudo apt install libsqlite3-dev
sudo wget http://master.dl.sourceforge.net/project/d-apt/files/d-apt.list -O /etc/apt/sources.list.d/d-apt.list
sudo apt-get update && sudo apt-get -y --allow-unauthenticated install --reinstall d-apt-keyring
sudo apt-get update && sudo apt-get install dmd-compiler dub
```

### Dependencies: Fedora/CentOS
```sh
sudo yum install libcurl-devel
sudo yum install sqlite-devel
curl -fsS https://dlang.org/install.sh | bash -s dmd
```

### Dependencies: Arch Linux
```sh
sudo pacman -S curl sqlite dmd
```

### Installation
```sh
git clone https://github.com/skilion/onedrive.git
cd onedrive
make
sudo make install
```

Using a different compiler (for example [LDC](https://wiki.dlang.org/LDC)):
```sh
make DC=ldmd2
```

### First run :zap:
After installing the application you must run it at least once from the terminal to authorize it.

You will be asked to open a specific link using your web browser where you will have to login into your Microsoft Account and give the application the permission to access your files. After giving the permission, you will be redirected to a blank page. Copy the URI of the blank page into the application.

### Uninstall
```sh
sudo make uninstall
# delete the application state
rm -rf .config/onedrive
```

## Configuration
Configuration is optional. By default all files are downloaded in `~/OneDrive` and only hidden files are skipped.
If you want to change the defaults, you can copy and edit the included config file into your `~/.config/onedrive` directory:
```sh
mkdir -p ~/.config/onedrive
cp ./config ~/.config/onedrive/config
nano ~/.config/onedrive/config
```

Available options:
* `sync_dir`: directory where the files will be synced
* `skip_file`: any files or directories that match this pattern will be skipped during sync.

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
If you want to sync your files automatically, enable and start the systemd service:
```sh
systemctl --user enable onedrive
systemctl --user start onedrive
```

To see the logs run:
```sh
journalctl --user-unit onedrive -f
```

Note: systemd is supported on Ubuntu only starting from version 15.04

### Using multiple accounts
You can run multiple instances of the application specifying a different config directory in order to handle multiple OneDrive accounts.
To do this you can use the `--confdir` parameter.
Here is an example:
```sh
onedrive --monitor --confdir="~/.config/onedrivePersonal" &
onedrive --monitor --confdir="~/.config/onedriveWork" &
```

`--monitor` keeps the application running and monitoring for changes

`&` puts the application in background and leaves the terminal interactive

## Extra

### Reporting issues
If you encounter any bugs you can report them here on Github. Before filing an issue be sure to:

1. Check the version of the application you are using `onedrive --version`
2. Run the application in verbose mode `onedrive --verbose`
3. Have the log of the error (preferably uploaded on an external website such as [pastebin](https://pastebin.com/))
4. Collect any information that you may think it is relevant to the error (such as the steps to trigger it)

### All available commands:
```text
Usage: onedrive [OPTION]...

no option        Sync and exit
       --confdir Set the directory used to store the configuration files
-d    --download Only download remote changes
        --logout Logout the current user
-m     --monitor Keep monitoring for local and remote changes
   --print-token Print the access token, useful for debugging
        --resync Forget the last saved state, perform a full sync
       --syncdir Set the directory used to sync the files are synced
-v     --verbose Print more details, useful for debugging
       --version Print the version and exit
-h        --help This help information.
```

### File naming
The files and directories in the synchronization directory must follow the [Windows naming conventions](https://msdn.microsoft.com/en-us/library/aa365247).
The application will crash for example if you have two files with the same name but different case. This is expected behavior and won't be fixed.
