OneDrive Free Client
====================

### Features:
* State caching
* Real-Time file monitoring with Inotify
* Resumable uploads

### What's missing:
* OneDrive for business is not supported
* While local changes are uploaded right away, remote changes are delayed.
* No GUI

### Dependencies
* [libcurl](http://curl.haxx.se/libcurl/)
* [SQLite 3](https://www.sqlite.org/)
* [Digital Mars D Compiler (DMD)](http://dlang.org/download.html)

### Dependencies: Ubuntu
```
sudo apt-get install libcurl-dev
sudo apt-get install libsqlite3-dev
sudo wget http://master.dl.sourceforge.net/project/d-apt/files/d-apt.list -O /etc/apt/sources.list.d/d-apt.list
wget -qO - http://dlang.org/d-keyring.gpg | sudo apt-key add -
sudo apt-get update && sudo apt-get install dmd-bin
```

### Installation
```
git clone git@github.com:skilion/onedrive.git
cd onedrive
make
sudo make install
```

### Configuration:
You should copy the default config file into your home directory before making changes:
```
mkdir -p ~/.config/onedrive
cp ./config ~/.config/onedrive/config
```

Available options:
* `sync_dir`: directory where the files will be synced
* `skip_file`: any files or directories that match this pattern will be skipped during sync

Pattern are case insensitive.
`*` and `?` [wildcards characters][1] are supported.
Use `|` to separate multiple patterns.

[1]: https://technet.microsoft.com/en-us/library/bb490639.aspx

### Selective sync
Selective sync allows you to sync only specific files and directories.
To enable selective sync create a file named `sync_list` in `~/.config/onedrive`.
Each line represents a path to a file or directory relative from your `sync_dir`.
```
$ cat ~/.config/onedrive/sync_list
Backup
Documents/report.odt
Work/ProjectX
notes.txt
```

### First run
The first time you run the program you will be asked to sign in. The procedure requires a web browser.

### Service
If you want to sync your files automatically, enable and start the systemd service:
```
systemctl --user enable onedrive
systemctl --user start onedrive
```

To see the logs run:
```
journalctl --user-unit onedrive -f
```

### Usage:
```
onedrive [OPTION]...

-m --monitor Keep monitoring for local and remote changes.
    --resync Forget the last saved state, perform a full sync.
    --logout Logout the current user.
   --confdir Set the directory to use to store the configuration files.
-v --verbose Print more details, useful for debugging.
-h    --help This help information.
```

### Notes:
* After changing `skip_file` in your configs or the sync list, you must execute `onedrive --resync`
* [Windows naming conventions][2] apply
* Use `make debug` to generate an executable for debugging

[2]: https://msdn.microsoft.com/en-us/library/aa365247
