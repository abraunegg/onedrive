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

### Installation

1. `make`
2. `sudo make install`

### Config:
Config files are loaded in the following order:

1. `/etc/onedrive.conf`
2. `/usr/local/etc/onedrive.conf`
3. `$XDG_CONFIG_HOME/onedrive/config`
4. `~/.config/onedrive/config`

Available options:

* `client_id` & `client_secret`: application identifiers necessary during the [authentication][2]
* `sync_dir`: directory where the files will be synced
* `skip_file`: any files that match this pattern will be skipped during sync
* `skip_dir`: any directories that match this pattern will be skipped during sync

Pattern are case insensitive.
`*` and `?` [wildcards characters][3] are supported.
Use `|` to separate multiple patterns.

[2]: https://dev.onedrive.com/auth/msa_oauth.htm
[3]: https://technet.microsoft.com/en-us/library/bb490639.aspx

### First run
The first time you run the program you will be asked to sign in. The procedure require a web browser.

### Usage:

	onedrive [OPTION]...

	no option    Sync and exit.
	-m --monitor Keep monitoring for local and remote changes.
		--resync Forget the last saved state, perform a full sync.
	-v --verbose Print more details, useful for debugging.
	-h    --help This help information.

### Notes:
* After changing the filters (`skip_file` or `skip_dir` in your configs) you must execute `onedrive --resync`
* [Windows naming conventions][4] apply
* Use `make debug` to generate an executable for debugging

[4]: https://msdn.microsoft.com/en-us/library/aa365247
