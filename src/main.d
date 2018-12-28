import core.stdc.stdlib: EXIT_SUCCESS, EXIT_FAILURE, exit;
import core.memory, core.time, core.thread;
import std.file, std.path, std.process, std.stdio, std.conv, std.algorithm.searching, std.string;
import config, itemdb, monitor, onedrive, selective, sync, util;
import docopt;
import std.net.curl: CurlException;
import core.stdc.signal;
import std.traits;
static import log;

OneDriveApi oneDrive;
ItemDatabase itemDb;

int main(string[] args)
{
	// Disable buffering on stdout
	stdout.setvbuf(0, _IONBF);
	
	auto doc = "OneDrive - a client for OneDrive Cloud Services

Usage:
  onedrive [options] [-v | -vv] (--synchronize | --monitor | --display-config | --display-sync-status )
  onedrive -h | --help
  onedrive --version

Options:
  -h --help     Show this screen.
  --version     Show version.
  --check-for-nomount
       Check for the presence of .nosync in the syncdir root. If found, do not perform sync.
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
  --disable-upload-validation
       Disable upload validation when uploading to OneDrive
  --display-config
       Display what options the client will use as currently configured - no sync will be performed.
  --display-sync-status
       Display the sync status of the client - no sync will be performed.
  --download-only -d
       Only download remote changes
  --enable-logging
       Enable client activity to a separate log file
  --get-O365-drive-id ARG
       Query and return the Office 365 Drive ID for a given Office 365 SharePoint Shared Library
  --local-first
       Synchronize from the local directory source first, before downloading changes from OneDrive.
  --logout
       Logout the current user
  --monitor -m
       Keep monitoring for local and remote changes
  --no-remote-delete
       Do not delete local file 'deletes' from OneDrive when using --upload-only
  --print-token
       Print the access token, useful for debugging
  --remove-directory ARG
       Remove a directory on OneDrive - no sync will be performed.
  --resync
       Forget the last saved state, perform a full sync
  --single-directory ARG
       Specify a single local directory within the OneDrive root to sync.
  --skip-symlinks
       Skip syncing of symlinks
  --source-directory ARG
       Source directory to rename or move on OneDrive - no sync will be performed.
  --syncdir ARG
       Set the directory used to sync the files that are synced
  --synchronize
       Perform a synchronization
  --upload-only
       Only upload to OneDrive, do not sync changes from OneDrive locally
  --verbose -v
       Print more details, useful for debugging (repeat for extra debugging)
";

	auto arguments = docopt.docopt(doc, args[1..$], true, import("version"));

	log.vdebug("parsed arguments = ", arguments);

	// Convert returned arguments to actually used settings

	// variables are ordered according to the help output, which is alphabetic
	// in the option names
	string ConvertToString(string arg) {
		return (arguments[arg].isNull ? null : arguments[arg].toString);
	}

	// Add a check mounts option to resolve https://github.com/abraunegg/onedrive/issues/8
	bool checkMount = arguments["--check-for-nomount"].isTrue;
	// configuration directory
	string configDirName = ConvertToString("--confdir");
	// Create a single root directory on OneDrive
	string createDirectory = ConvertToString("--create-directory");
	// The destination directory if we are using the OneDrive client to rename a directory
	string destinationDirectory = ConvertToString("--destination-directory");
	// Debug the HTTPS submit operations if required
	bool debugHttp = arguments["--debug-https"].isTrue;
	// Do not use notifications in monitor mode
	bool disableNotifications = arguments["--disable-notifications"].isTrue;
	// Does the user want to disable upload validation - https://github.com/abraunegg/onedrive/issues/205
	// SharePoint will associate some metadata from the library the file is uploaded to directly in the file - thus change file size & checksums
	bool disableUploadValidation = arguments["--disable-upload-validation"].isTrue;
	// Display application configuration but do not sync
	bool displayConfiguration = arguments["--display-config"].isTrue;
	// Display sync status
	bool displaySyncStatus = arguments["--display-sync-status"].isTrue;
	// only download remote changes
	bool downloadOnly = arguments["--download-only"].isTrue;
	// Do we enable a log file
	bool enableLogFile = arguments["--enable-logging"].isTrue;
	// SharePoint / Office 365 Shared Library name to query
	string o365SharedLibraryName = ConvertToString("--get-O365-drive-id");
	// Local sync - Upload local changes first before downloading changes from OneDrive
	bool localFirst = arguments["--local-first"].isTrue;
	// remove the current user and sync state
	bool logout = arguments["--logout"].isTrue;
	// enable monitor mode
	bool monitor = arguments["--monitor"].isTrue;
	// Add option for no remote delete
	bool noRemoteDelete = arguments["--no-remote-delete"].isTrue;
	// print the access token
	bool printAccessToken = arguments["--print-token"].isTrue;
	// Remove a single directory on OneDrive
	string removeDirectory = ConvertToString("--remove-directory");
	// force a full resync
	bool resync = arguments["--resync"].isTrue;
	// This allows for selective directory syncing instead of everything under ~/OneDrive/
	string singleDirectory = ConvertToString("--single-directory");
	// Add option to skip symlinks
	bool skipSymlinks = arguments["--skip-symlinks"].isTrue;
	// The source directory if we are using the OneDrive client to rename a directory
	string sourceDirectory = ConvertToString("--source-directory");
	// override the sync directory
	string syncDirName = ConvertToString("--syncdir");
	// Configure a flag to perform a sync
	// This is beneficial so that if just running the client itself - without any options, or sync check, the client does not perform a sync
	bool synchronize = arguments["--synchronize"].isTrue;
	// Upload Only
	bool uploadOnly = arguments["--upload-only"].isTrue;
	// enable verbose logging
	if (arguments["--verbose"].isInt) {
		log.verbose = arguments["--verbose"].asInt;
	} else {
		log.verbose = 0;
	}
	

	// Main function variables
	string homePath = "";
	string configDirBase = "";
	// Debug the HTTPS response operations if required
	bool debugHttpSubmit;
	// Are we able to reach the OneDrive Service
	bool online = false;
	
	// Determine the users home directory.
	// Need to avoid using ~ here as expandTilde() below does not interpret correctly when running under init.d or systemd scripts
	// Check for HOME environment variable
	if (environment.get("HOME") != ""){
		// Use HOME environment variable
		log.vdebug("homePath: HOME environment variable set");
		homePath = environment.get("HOME");
	} else {
		if ((environment.get("SHELL") == "") && (environment.get("USER") == "")){
			// No shell is set or username - observed case when running as systemd service under CentOS 7.x
			log.vdebug("homePath: WARNING - no HOME environment variable set");
			log.vdebug("homePath: WARNING - no SHELL environment variable set");
			log.vdebug("homePath: WARNING - no USER environment variable set");
			homePath = "/root";
		} else {
			// A shell & valid user is set, but no HOME is set, use ~ which can be expanded
			log.vdebug("homePath: WARNING - no HOME environment variable set");
			homePath = "~";
		}
	}
	
	// Output homePath calculation
	log.vdebug("homePath: ", homePath);

	// Determine the base directory relative to which user specific configuration files should be stored.
	if (environment.get("XDG_CONFIG_HOME") != ""){
		log.vdebug("configDirBase: XDG_CONFIG_HOME environment variable set");
		configDirBase = environment.get("XDG_CONFIG_HOME");
	} else {
		// XDG_CONFIG_HOME does not exist on systems where X11 is not present - ie - headless systems / servers
		log.vdebug("configDirBase: WARNING - no XDG_CONFIG_HOME environment variable set");
		configDirBase = homePath ~ "/.config";
	}
	
	// Output configDirBase calculation
	log.vdebug("configDirBase: ", configDirBase);
	
	// Determine the correct configuration directory to use
	if (configDirName != "") {
		// A CLI 'confdir' was passed in
		log.vdebug("configDirName: CLI override to set configDirName to: ", configDirName);
		if (canFind(configDirName,"~")) {
			// A ~ was found
			log.vdebug("configDirName: A '~' was found in configDirName, using the calculated 'homePath' to replace '~'");
			configDirName = homePath ~ strip(configDirName,"~","~");
		}
	} else {
		// Set the default application configuration directory
		log.vdebug("configDirName: Configuring application to use default config path");
		// configDirBase contains the correct path so we do not need to check for presence of '~'
		configDirName = configDirBase ~ "/onedrive";
	}
	
	// load application configuration
	log.vlog("Loading config ...");
	log.vlog("Using Config Dir: ", configDirName);
	if (!exists(configDirName)) mkdirRecurse(configDirName);
	auto cfg = new config.Config(configDirName);
	if(!cfg.init()){
		// There was an error loading the configuration
		// Error message already printed
		return EXIT_FAILURE;
	}
	
	// command line parameters to override default 'config' & take precedence
	// Set the client to skip symbolic links if --skip-symlinks was passed in
	if (skipSymlinks) {
		// The user passed in an alternate skip_symlinks as to what was either in 'config' file or application default
		log.vdebug("CLI override to set skip_symlinks to: true");
		cfg.setValue("skip_symlinks", "true");
	}
	
	// Set the OneDrive Local Sync Directory if was passed in via --syncdir
	if (syncDirName) {
		// The user passed in an alternate sync_dir as to what was either in 'config' file or application default
		// Do not expandTilde here as we do not know if we reliably can
		log.vdebug("CLI override to set sync_dir to: ", syncDirName);
		cfg.setValue("sync_dir", syncDirName);
	}
	
	// sync_dir environment handling to handle ~ expansion properly
	string syncDir;
	if ((environment.get("SHELL") == "") && (environment.get("USER") == "")){
		log.vdebug("sync_dir: No SHELL or USER environment variable configuration detected");
		// No shell or user set, so expandTilde() will fail - usually headless system running under init.d / systemd or potentially Docker
		// Does the 'currently configured' sync_dir include a ~
		if (canFind(cfg.getValue("sync_dir"),"~")) {
			// A ~ was found
			log.vdebug("sync_dir: A '~' was found in sync_dir, using the calculated 'homePath' to replace '~'");
			syncDir = homePath ~ strip(cfg.getValue("sync_dir"),"~","~");
		} else {
			// No ~ found in sync_dir, use as is
			log.vdebug("sync_dir: Getting syncDir from config value sync_dir");
			syncDir = cfg.getValue("sync_dir");
		}
	} else {
		// A shell and user is set, expand any ~ as this will be expanded correctly if present
		log.vdebug("sync_dir: Getting syncDir from config value sync_dir");
		if (canFind(cfg.getValue("sync_dir"),"~")) {
			log.vdebug("sync_dir: A '~' was found in configured sync_dir, automatically expanding as SHELL and USER environment variable is set");
			syncDir = expandTilde(cfg.getValue("sync_dir"));
		} else {
			syncDir = cfg.getValue("sync_dir");
		}
	}
	
	// vdebug syncDir as set and calculated
	log.vdebug("syncDir: ", syncDir);
	
	// Configure logging if enabled
	if (enableLogFile){
		// Read in a user defined log directory or use the default
		string logDir = cfg.getValue("log_dir");
		log.vlog("Using logfile dir: ", logDir);
		log.init(logDir);
	}

	// Configure whether notifications are used
	log.setNotifications(monitor && !disableNotifications);
	
	// upgrades
	if (exists(configDirName ~ "/items.db")) {
		remove(configDirName ~ "/items.db");
		log.logAndNotify("Database schema changed, resync needed");
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

	// Display current application configuration, no application initialisation
	if (displayConfiguration){
		string userConfigFilePath = configDirName ~ "/config";
		string userSyncList = configDirName ~ "/sync_list";
		// Display all of the pertinent configuration options
		writeln("Config path                         = ", configDirName);
		
		// Does a config file exist or are we using application defaults
		if (exists(userConfigFilePath)){
			writeln("Config file found in config path    = true");
		} else {
			writeln("Config file found in config path    = false");
		}
		
		// Config Options
		writeln("Config option 'sync_dir'            = ", syncDir);
		writeln("Config option 'skip_file'           = ", cfg.getValue("skip_file"));
		writeln("Config option 'skip_symlinks'       = ", cfg.getValue("skip_symlinks"));
		writeln("Config option 'monitor_interval'    = ", cfg.getValue("monitor_interval"));
		writeln("Config option 'log_dir'             = ", cfg.getValue("log_dir"));
		
		// Is config option drive_id configured?
		if (cfg.getValue("drive_id", "") != ""){
			writeln("Config option 'drive_id'            = ", cfg.getValue("drive_id"));
		}
		
		// Is sync_list configured?
		if (exists(userSyncList)){
			writeln("Selective sync configured           = true");
		} else {
			writeln("Selective sync configured           = false");
		}
		
		return EXIT_SUCCESS;
	}
	
	log.vlog("Initializing the OneDrive API ...");
	try {
		online = testNetwork();
	} catch (CurlException e) {
		// No network connection to OneDrive Service
		log.error("No network connection to Microsoft OneDrive Service");
		if (!monitor) {
			return EXIT_FAILURE;
		}
	}

	// Initialize OneDrive, check for authorization
	oneDrive = new OneDriveApi(cfg, debugHttp);
	oneDrive.printAccessToken = printAccessToken;
	if (!oneDrive.init()) {
		log.error("Could not initialize the OneDrive API");
		// workaround for segfault in std.net.curl.Curl.shutdown() on exit
		oneDrive.http.shutdown();
		return EXIT_FAILURE;
	}
	
	// if --synchronize or --monitor not passed in, exit & display help
	auto performSyncOK = false;
	
	if (synchronize || monitor) {
		performSyncOK = true;
	}
	
	// create-directory, remove-directory, source-directory, destination-directory 
	// are activities that dont perform a sync no error message for these items either
	if (((createDirectory != "") || (removeDirectory != "")) || ((sourceDirectory != "") && (destinationDirectory != "")) || (o365SharedLibraryName != "") || (displaySyncStatus == true)) {
		performSyncOK = true;
	}
	
	if (!performSyncOK) {
		writeln("\n--synchronize or --monitor missing from your command options or use --help for further assistance\n");
		writeln("No OneDrive sync will be performed without either of these two arguments being present\n");
		oneDrive.http.shutdown();
		return EXIT_FAILURE;
	}
	
	// initialize system
	log.vlog("Opening the item database ...");
	itemDb = new ItemDatabase(cfg.databaseFilePath);
	
	log.vlog("All operations will be performed in: ", syncDir);
	if (!exists(syncDir)) {
		log.vdebug("syncDir: Configured syncDir is missing. Creating: ", syncDir);
		mkdirRecurse(syncDir);
	}
	chdir(syncDir);
	
	// Configure selective sync by parsing and getting a regex for skip_file config component
	auto selectiveSync = new SelectiveSync();
	selectiveSync.load(cfg.syncListFilePath);
	selectiveSync.setMask(cfg.getValue("skip_file"));
	
	// Initialise the sync engine
	log.logAndNotify("Initializing the Synchronization Engine ...");
	auto sync = new SyncEngine(cfg, oneDrive, itemDb, selectiveSync);
	
	try {
		if (!initSyncEngine(sync)) {
			oneDrive.http.shutdown();
			return EXIT_FAILURE;
		}
	} catch (CurlException e) {
		if (!monitor) {
			log.log("\nNo internet connection.");
			oneDrive.http.shutdown();
			return EXIT_FAILURE;
		}
	}

	// We should only set noRemoteDelete in an upload-only scenario
	if ((uploadOnly)&&(noRemoteDelete)) sync.setNoRemoteDelete();
	
	// Do we configure to disable the upload validation routine
	if(disableUploadValidation) sync.setDisableUploadValidation();
	
	// Do we need to validate the syncDir to check for the presence of a '.nosync' file
	if (checkMount) {
		// we were asked to check the mounts
		if (exists(syncDir ~ "/.nosync")) {
			log.logAndNotify("ERROR: .nosync file found. Aborting synchronization process to safeguard data.");
			oneDrive.http.shutdown();
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
	
	// Are we obtaining the Office 365 Drive ID for a given Office 365 SharePoint Shared Library?
	if (o365SharedLibraryName != ""){
		sync.querySiteCollectionForDriveID(o365SharedLibraryName);
	}
	
	// Are we displaying the sync status of the client?
	if (displaySyncStatus) {
		string remotePath = "/";
		string localPath = ".";
		
		// Are we doing a single directory check?
		if (singleDirectory != ""){
			// Need two different path strings here
			remotePath = singleDirectory;
			localPath = singleDirectory;
		}
		sync.queryDriveForChanges(remotePath);
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
						log.logAndNotify("ERROR: The requested local directory does not exist. Please check ~/OneDrive/ for requested path");
						oneDrive.http.shutdown();
						return EXIT_FAILURE;
					}
				}
						
				// Perform the sync
				performSync(sync, singleDirectory, downloadOnly, localFirst, uploadOnly);
			}
		}
			
		if (monitor) {
			log.logAndNotify("Initializing monitor ...");
			log.log("OneDrive monitor interval (seconds): ", to!long(cfg.getValue("monitor_interval")));
			Monitor m = new Monitor(selectiveSync);
			m.onDirCreated = delegate(string path) {
				log.vlog("[M] Directory created: ", path);
				try {
					sync.scanForDifferences(path);
				} catch(Exception e) {
					log.logAndNotify("Cannot create remote directory: ", e.msg);
				}
			};
			m.onFileChanged = delegate(string path) {
				log.vlog("[M] File changed: ", path);
				try {
					sync.scanForDifferences(path);
				} catch(Exception e) {
					log.logAndNotify("Cannot upload file changes/creation: ", e.msg);
				}
			};
			m.onDelete = delegate(string path) {
				log.vlog("[M] Item deleted: ", path);
				try {
					sync.deleteByPath(path);
				} catch(SyncException e) {
					if (e.msg == "The item to delete is not in the local database") {
						log.vlog("Item cannot be deleted because not found in database");
					} else {
						log.logAndNotify("Cannot delete remote item: ", e.msg);
					}
				} catch(Exception e) {
					log.logAndNotify("Cannot delete remote item: ", e.msg);
				}
			};
			m.onMove = delegate(string from, string to) {
				log.vlog("[M] Item moved: ", from, " -> ", to);
				try {
					sync.uploadMoveItem(from, to);
				} catch(Exception e) {
					log.logAndNotify("Cannot move item:, ", e.msg);
				}
			};
			signal(SIGINT, &exitHandler);
			signal(SIGTERM, &exitHandler);

			// initialise the monitor class
			if (cfg.getValue("skip_symlinks") == "true") skipSymlinks = true;
			if (!downloadOnly) m.init(cfg, log.verbose >= 1, skipSymlinks);
			// monitor loop
			immutable auto checkInterval = dur!"seconds"(to!long(cfg.getValue("monitor_interval")));
			auto lastCheckTime = MonoTime.currTime();
			while (true) {
				if (!downloadOnly) m.update(online);
				auto currTime = MonoTime.currTime();
				if (currTime - lastCheckTime > checkInterval) {
					// log.logAndNotify("DEBUG trying to create checkpoint");
					// auto res = itemdb.db_checkpoint();
					// log.logAndNotify("Checkpoint return: ", res);
					// itemdb.dump_open_statements();
					try {
						if (!initSyncEngine(sync)) {
							oneDrive.http.shutdown();
							return EXIT_FAILURE;
						}
						try {
							performSync(sync, singleDirectory, downloadOnly, localFirst, uploadOnly);
							if (!downloadOnly) {
								// discard all events that may have been generated by the sync
								m.update(false);
							}
						} catch (CurlException e) {
							// we already tried three times in the performSync routine
							// if we still have problems, then the sync handle might have
							// gone stale and we need to re-initialize the sync engine
							log.log("Pesistent connection errors, reinitializing connection");
							sync.reset();
						}
					} catch (CurlException e) {
						log.log("Cannot initialize connection to OneDrive");
					}
					// performSync complete, set lastCheckTime to current time
					lastCheckTime = MonoTime.currTime();
					GC.collect();
				} 
				Thread.sleep(dur!"msecs"(500));
			}
		}
	}

	// workaround for segfault in std.net.curl.Curl.shutdown() on exit
	oneDrive.http.shutdown();
	return EXIT_SUCCESS;
}

bool initSyncEngine(SyncEngine sync)
{
	try {
		sync.init();
	} catch (OneDriveException e) {
		if (e.httpStatusCode == 400 || e.httpStatusCode == 401) {
			// Authorization is invalid
			log.log("\nAuthorization token invalid, use --logout to authorize the client again\n");
			return false;
		}
		if (e.httpStatusCode >= 500) {
			// There was a HTTP 5xx Server Side Error, message already printed
			return false;
		}
	}
	return true;
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
			if (++count == 3) {
				log.log("Giving up on sync after three attempts: ", e.msg);
				throw e;
			} else 
				log.log("Retry sync count: ", count, ": ", e.msg);
		}
	} while (count != -1);
}

// getting around the @nogc problem
// https://p0nce.github.io/d-idioms/#Bypassing-@nogc
auto assumeNoGC(T) (T t) if (isFunctionPointer!T || isDelegate!T)
{
	enum attrs = functionAttributes!T | FunctionAttribute.nogc;
	return cast(SetFunctionAttributes!(T, functionLinkage!T, attrs)) t;
}

extern(C) nothrow @nogc @system void exitHandler(int value) {
	try {
		assumeNoGC ( () {
			log.log("Got termination signal, shutting down db connection");
			// make sure the .wal file is incorporated into the main db
			destroy(itemDb);
			// workaround for segfault in std.net.curl.Curl.shutdown() on exit
			oneDrive.http.shutdown();
		})();
	} catch(Exception e) {}
	exit(0);
}
