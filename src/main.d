import core.stdc.stdlib: EXIT_SUCCESS, EXIT_FAILURE;
import core.memory, core.time, core.thread;
import std.getopt, std.file, std.path, std.process, std.stdio, std.conv;
import config, itemdb, monitor, onedrive, selective, sync, util;
import std.net.curl: CurlException;
static import log;

int main(string[] args)
{
	// Determine the users configuration directory. 
	// Need to avoid using ~ here as expandTilde() below does not interpret correctly when running under init.d scripts
	string configPath = environment.get("XDG_CONFIG_HOME");
	if (configPath == ""){
		// XDG_CONFIG_HOME does not exist on systems where X11 is not present - ie - headless systems / servers
		// Get HOME environment variable
		configPath = environment.get("HOME") ~ "/.config";
	}
	
	// configuration directory
	string configDirName = configPath ~ "/onedrive";
	// only download remote changes
	bool downloadOnly;
	// override the sync directory
	string syncDirName;
	// enable monitor mode
	bool monitor;
	// force a full resync
	bool resync;
	// remove the current user and sync state
	bool logout;
	// enable verbose logging
	bool verbose;
	// print the access token
	bool printAccessToken;
	// print the version and exit
	bool printVersion;
	
	// Additional options added to support MyNAS Storage Appliance
	// Debug the HTTPS submit operations if required
	bool debugHttp;
	// Debug the HTTPS response operations if required
	bool debugHttpSubmit;
	// This allows for selective directory syncing instead of everything under ~/OneDrive/
	string singleDirectory;
	// Create a single root directory on OneDrive
	string createDirectory;
	// Remove a single directory on OneDrive
	string removeDirectory;
	// The source directory if we are using the OneDrive client to rename a directory
	string sourceDirectory;
	// The destination directory if we are using the OneDrive client to rename a directory
	string destinationDirectory;
	// Configure a flag to perform a sync
	// This is beneficial so that if just running the client itself - without any options, or sync check, the client does not perform a sync
	bool synchronize;
	// Local sync - Upload local changes first before downloading changes from OneDrive
	bool localFirst;
	// Upload Only
	bool uploadOnly;
	// Add a check mounts option to resolve https://github.com/abraunegg/onedrive/issues/8
	bool checkMount;
	// Add option to skip symlinks
	bool skipSymlinks;
	// Add option for no remote delete
	bool noRemoteDelete;
	// Are we able to reach the OneDrive Service
	bool online = false;
	
	try {
		auto opt = getopt(
			args,
			std.getopt.config.bundling,
			std.getopt.config.caseSensitive,
			"check-for-nomount", "Check for the presence of .nosync in the syncdir root. If found, do not perform sync.", &checkMount,
			"confdir", "Set the directory used to store the configuration files", &configDirName,
			"create-directory", "Create a directory on OneDrive - no sync will be performed.", &createDirectory,
			"destination-directory", "Destination directory for renamed or move on OneDrive - no sync will be performed.", &destinationDirectory,
			"debug-https", "Debug OneDrive HTTPS communication.", &debugHttp,
			"download|d", "Only download remote changes", &downloadOnly,
			"local-first", "Synchronize from the local directory source first, before downloading changes from OneDrive.", &localFirst,
			"logout", "Logout the current user", &logout,
			"monitor|m", "Keep monitoring for local and remote changes", &monitor,
			"no-remote-delete", "Do not delete local file 'deletes' from OneDrive when using --upload-only", &noRemoteDelete,
			"print-token", "Print the access token, useful for debugging", &printAccessToken,
			"resync", "Forget the last saved state, perform a full sync", &resync,
			"remove-directory", "Remove a directory on OneDrive - no sync will be performed.", &removeDirectory,
			"single-directory", "Specify a single local directory within the OneDrive root to sync.", &singleDirectory,
			"skip-symlinks", "Skip syncing of symlinks", &skipSymlinks,
			"source-directory", "Source directory to rename or move on OneDrive - no sync will be performed.", &sourceDirectory,
			"syncdir", "Set the directory used to sync the files that are synced", &syncDirName,
			"synchronize", "Perform a synchronization", &synchronize,
			"upload-only", "Only upload to OneDrive, do not sync changes from OneDrive locally", &uploadOnly,
			"verbose|v", "Print more details, useful for debugging", &log.verbose,
			"version", "Print the version and exit", &printVersion
		);
		if (opt.helpWanted) {
			defaultGetoptPrinter(
				"Usage: onedrive [OPTION]...\n\n" ~
				"no option        No sync and exit",
				opt.options
			);
			return EXIT_SUCCESS;
		}
	} catch (GetOptException e) {
		log.error(e.msg);
		log.error("Try 'onedrive -h' for more information");
		return EXIT_FAILURE;
	}
	
	// disable buffering on stdout
	stdout.setvbuf(0, _IONBF);

	if (printVersion) {
		std.stdio.write("onedrive ", import("version"));
		return EXIT_SUCCESS;
	}

	// Configure Logging
	log.init();

	// load configuration
	log.vlog("Loading config ...");
	configDirName = configDirName.expandTilde().absolutePath();
	log.vlog("Using Config Dir: ", configDirName);
	if (!exists(configDirName)) mkdirRecurse(configDirName);
	auto cfg = new config.Config(configDirName);
	cfg.init();
	
	// command line parameters override the config
	if (syncDirName) cfg.setValue("sync_dir", syncDirName.expandTilde().absolutePath());
	if (skipSymlinks) cfg.setValue("skip_symlinks", "true");
  
	// upgrades
	if (exists(configDirName ~ "/items.db")) {
		remove(configDirName ~ "/items.db");
		log.log("Database schema changed, resync needed");
		resync = true;
	}

	if (resync || logout) {
		log.vlog("Deleting the saved status ...");
		safeRemove(cfg.databaseFilePath);
		safeRemove(cfg.deltaLinkFilePath);
		safeRemove(cfg.uploadStateFilePath);
		if (logout) {
			safeRemove(cfg.refreshTokenFilePath);
		}
	}

	log.vlog("Initializing the OneDrive API ...");
	try {
		online = testNetwork();
	} catch (CurlException e) {
		// No network connection to OneDrive Service
		log.error("No network connection to Microsoft OneDrive Service");
		return EXIT_FAILURE;
	} 
	
	// Initialize OneDrive, check for authorization
	auto onedrive = new OneDriveApi(cfg, debugHttp);
	onedrive.printAccessToken = printAccessToken;
	if (!onedrive.init()) {
		log.error("Could not initialize the OneDrive API");
		// workaround for segfault in std.net.curl.Curl.shutdown() on exit
		onedrive.http.shutdown();
		return EXIT_FAILURE;
	}

	// if --synchronize or --monitor not passed in, exit & display help
	auto performSyncOK = false;
	
	if (synchronize || monitor) {
		performSyncOK = true;
	}
	
	// create-directory, remove-directory, source-directory, destination-directory 
	// are activities that dont perform a sync no error message for these items either
	if (((createDirectory != "") || (removeDirectory != "")) || ((sourceDirectory != "") && (destinationDirectory != "")) ) {
		performSyncOK = true;
	}
	
	if (!performSyncOK) {
		writeln("\n--synchronize or --monitor missing from your command options or use --help for further assistance\n");
		writeln("No OneDrive sync will be performed without either of these two arguments being present\n");
		onedrive.http.shutdown();
		return EXIT_FAILURE;
	}
	
	// initialize system
	log.vlog("Opening the item database ...");
	auto itemdb = new ItemDatabase(cfg.databaseFilePath);
	
	// Set the local path root
	string syncDir = expandTilde(cfg.getValue("sync_dir"));
	log.vlog("All operations will be performed in: ", syncDir);
	if (!exists(syncDir)) mkdirRecurse(syncDir);
	chdir(syncDir);
	
	// Configure selective sync by parsing and getting a regex for skip_file config component
	auto selectiveSync = new SelectiveSync();
	selectiveSync.load(cfg.syncListFilePath);
	selectiveSync.setMask(cfg.getValue("skip_file"));
	
	// Initialise the sync engine
	log.log("Initializing the Synchronization Engine ...");
	auto sync = new SyncEngine(cfg, onedrive, itemdb, selectiveSync);
	
	try {
		sync.init();
	} catch (OneDriveException e) {
		if (e.httpStatusCode == 400 || e.httpStatusCode == 401) {
			// Authorization is invalid
			log.log("\nAuthorization token invalid, use --logout to authorize the client again\n");
			onedrive.http.shutdown();
			return EXIT_FAILURE;
		}
	}
	
	// We should only set noRemoteDelete in an upload-only scenario
	if ((uploadOnly)&&(noRemoteDelete)) sync.setNoRemoteDelete();
	
	// Do we need to validate the syncDir to check for the presence of a '.nosync' file
	if (checkMount) {
		// we were asked to check the mounts
		if (exists(syncDir ~ "/.nosync")) {
			log.log("\nERROR: .nosync file found. Aborting synchronization process to safeguard data.");
			onedrive.http.shutdown();
			return EXIT_FAILURE;
		}
	}
	
	// Do we need to create or remove a directory?
	if ((createDirectory != "") || (removeDirectory != "")) {
	
		if (createDirectory != "") {
			// create a directory on OneDrive
			sync.createDirectoryNoSync(createDirectory);
		}
	
		if (removeDirectory != "") {
			// remove a directory on OneDrive
			sync.deleteDirectoryNoSync(removeDirectory);			
		}
	}
	
	// Are we renaming or moving a directory?
	if ((sourceDirectory != "") && (destinationDirectory != "")) {
		// We are renaming or moving a directory
		sync.renameDirectoryNoSync(sourceDirectory, destinationDirectory);
	}
	
	// Are we performing a sync, resync or monitor operation?
	if ((synchronize) || (resync) || (monitor)) {

		if ((synchronize) || (resync)) {
			if (online) {
				// Check user entry for local path - the above chdir means we are already in ~/OneDrive/ thus singleDirectory is local to this path
				if (singleDirectory != ""){
					// Does the directory we want to sync actually exist?
					if (!exists(singleDirectory)){
						// the requested directory does not exist .. 
						log.log("The requested local directory does not exist. Please check ~/OneDrive/ for requested path");
						onedrive.http.shutdown();
						return EXIT_FAILURE;
					}
				}
						
				// Perform the sync
				performSync(sync, singleDirectory, downloadOnly, localFirst, uploadOnly);
			}
		}
			
		if (monitor) {
			log.log("Initializing monitor ...");
			log.log("OneDrive monitor interval (seconds): ", to!long(cfg.getValue("monitor_interval")));
			Monitor m = new Monitor(selectiveSync);
			m.onDirCreated = delegate(string path) {
				log.vlog("[M] Directory created: ", path);
				try {
					sync.scanForDifferences(path);
				} catch(Exception e) {
					log.log(e.msg);
				}
			};
			m.onFileChanged = delegate(string path) {
				log.vlog("[M] File changed: ", path);
				try {
					sync.scanForDifferences(path);
				} catch(Exception e) {
					log.log(e.msg);
				}
			};
			m.onDelete = delegate(string path) {
				log.vlog("[M] Item deleted: ", path);
				try {
					sync.deleteByPath(path);
				} catch(Exception e) {
					log.log(e.msg);
				}
			};
			m.onMove = delegate(string from, string to) {
				log.vlog("[M] Item moved: ", from, " -> ", to);
				try {
					sync.uploadMoveItem(from, to);
				} catch(Exception e) {
					log.log(e.msg);
				}
			};
			// initialise the monitor class
			if (cfg.getValue("skip_symlinks") == "true") skipSymlinks = true;
			if (!downloadOnly) m.init(cfg, verbose, skipSymlinks);
			// monitor loop
			immutable auto checkInterval = dur!"seconds"(to!long(cfg.getValue("monitor_interval")));
			auto lastCheckTime = MonoTime.currTime();
			while (true) {
				if (!downloadOnly) m.update(online);
				auto currTime = MonoTime.currTime();
				if (currTime - lastCheckTime > checkInterval) {
					online = testNetwork();
					if (online) {
						performSync(sync, singleDirectory, downloadOnly, localFirst, uploadOnly);
						if (!downloadOnly) {
							// discard all events that may have been generated by the sync
							m.update(false);
						}
					}
					// performSync complete, set lastCheckTime to current time
					lastCheckTime = MonoTime.currTime();
					GC.collect();
				} else {
					Thread.sleep(dur!"msecs"(100));
				}
			}
		}
	}

	// workaround for segfault in std.net.curl.Curl.shutdown() on exit
	onedrive.http.shutdown();
	return EXIT_SUCCESS;
}

// try to synchronize the folder three times
void performSync(SyncEngine sync, string singleDirectory, bool downloadOnly, bool localFirst, bool uploadOnly)
{
	int count;
	string remotePath = "/";
    string localPath = ".";
	
	// Are we doing a single directory sync?
	if (singleDirectory != ""){
		// Need two different path strings here
		remotePath = singleDirectory;
		localPath = singleDirectory;
	}
	
	do {
		try {
			if (singleDirectory != ""){
				// we were requested to sync a single directory
				log.vlog("Syncing changes from this selected path: ", singleDirectory);
				if (uploadOnly){
					// Upload Only of selected single directory
					log.log("Syncing changes from selected local path only - NOT syncing data changes from OneDrive ...");
					sync.scanForDifferences(localPath);
				} else {
					// No upload only
					if (localFirst) {
						// Local First
						log.log("Syncing changes from selected local path first before downloading changes from OneDrive ...");
						sync.scanForDifferences(localPath);
						sync.applyDifferencesSingleDirectory(remotePath);
					} else {
						// OneDrive First
						log.log("Syncing changes from selected OneDrive path ...");
						sync.applyDifferencesSingleDirectory(remotePath);
						// is this a download only request?
						if (!downloadOnly) {
							// process local changes
							sync.scanForDifferences(localPath);
							// ensure that the current remote state is updated locally
							sync.applyDifferencesSingleDirectory(remotePath);
						}
					}
				}
			} else {
				// no single directory sync
				if (uploadOnly){
					// Upload Only of entire sync_dir
					log.log("Syncing changes from local path only - NOT syncing data changes from OneDrive ...");
					sync.scanForDifferences(localPath);
				} else {
					// No upload only
					if (localFirst) {
						// sync local files first before downloading from OneDrive
						log.log("Syncing changes from local path first before downloading changes from OneDrive ...");
						sync.scanForDifferences(localPath);
						sync.applyDifferences();
					} else {
						// sync from OneDrive first before uploading files to OneDrive
						log.log("Syncing changes from OneDrive ...");
						sync.applyDifferences();
						// is this a download only request?
						if (!downloadOnly) {
							// process local changes
							sync.scanForDifferences(localPath);
							// ensure that the current remote state is updated locally
							sync.applyDifferences();
						}
					}
				}
			}
			count = -1;
		} catch (Exception e) {
			if (++count == 3) throw e;
			else log.log(e.msg);
		}
	} while (count != -1);
}
