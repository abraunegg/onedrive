import core.stdc.stdlib: EXIT_SUCCESS, EXIT_FAILURE, exit;
import core.memory, core.time, core.thread;
import std.getopt, std.file, std.path, std.process, std.stdio, std.conv, std.algorithm.searching, std.string;
import config, itemdb, monitor, onedrive, selective, sync, util;
import std.net.curl: CurlException;
import core.stdc.signal;
import std.traits;
static import log;

OneDriveApi oneDrive;
ItemDatabase itemDb;

enum MONITOR_LOG_SILENT = 2;
enum MONITOR_LOG_QUIET  = 1;
enum LOG_NORMAL = 0;

int main(string[] args)
{
	// Disable buffering on stdout
	stdout.setvbuf(0, _IONBF);
	
	// Application Option Variables
	// Add a check mounts option to resolve https://github.com/abraunegg/onedrive/issues/8
	bool checkMount = false;
	// Check if we should ignore a directory if a special file (.nosync) is present - https://github.com/abraunegg/onedrive/issues/163
	bool checkNoSync = false;
	// configuration directory
	string configDirName;
	// Create a single root directory on OneDrive
	string createDirectory;
	// The destination directory if we are using the OneDrive client to rename a directory
	string destinationDirectory;
	// Debug the HTTPS submit operations if required
	bool debugHttp = false;
	// Do not use notifications in monitor mode
	bool disableNotifications = false;
	// Display application configuration but do not sync
	bool displayConfiguration = false;
	// Display sync status
	bool displaySyncStatus = false;
	// only download remote changes
	bool downloadOnly = false;
	// Does the user want to disable upload validation - https://github.com/abraunegg/onedrive/issues/205
	// SharePoint will associate some metadata from the library the file is uploaded to directly in the file - thus change file size & checksums
	bool disableUploadValidation = false;
	// Perform only a dry run - not applicable for --monitor mode
	bool dryRun = false;
	// Do we enable a log file
	bool enableLogFile = false;
	// Force the use of HTTP 1.1 to overcome curl => 7.62.0 where some operations are now sent via HTTP/2
	// Whilst HTTP/2 operations are handled, in some cases the handling of this outside of the client is not being done correctly (router, other) thus the client breaks
	// This flag then allows the user to downgrade all HTTP operations to HTTP 1.1 for maximum network path compatibility
	bool forceHTTP11 = false;
	// SharePoint / Office 365 Shared Library name to query
	string o365SharedLibraryName;
	// Local sync - Upload local changes first before downloading changes from OneDrive
	bool localFirst = false;
	// remove the current user and sync state
	bool logout = false;
	// enable monitor mode
	bool monitor = false;
	// Add option for no remote delete
	bool noRemoteDelete = false;
	// print the access token
	bool printAccessToken = false;
	// force a full resync
	bool resync = false;
	// Remove a single directory on OneDrive
	string removeDirectory;
	// This allows for selective directory syncing instead of everything under ~/OneDrive/
	string singleDirectory;
	// Skip dot files & folders - eg .file or /.folder/
	bool skipDotFiles = false;
	// Add option to skip symlinks
	bool skipSymlinks = false;
	// The source directory if we are using the OneDrive client to rename a directory
	string sourceDirectory;
	// override the sync directory
	string syncDirName;
	// Configure a flag to perform a sync
	// This is beneficial so that if just running the client itself - without any options, or sync check, the client does not perform a sync
	bool synchronize = false;
	// Upload Only
	bool uploadOnly = false;
	// enable verbose logging
	bool verbose = false;
	// print the version and exit
	bool printVersion = false;
	
	// Application Startup option validation
	try {
		auto opt = getopt(
			args,
			std.getopt.config.bundling,
			std.getopt.config.caseSensitive,
			"check-for-nomount", "Check for the presence of .nosync in the syncdir root. If found, do not perform sync.", &checkMount,
			"check-for-nosync", "Check for the presence of .nosync in each directory. If found, skip directory from sync.", &checkNoSync,
			"confdir", "Set the directory used to store the configuration files", &configDirName,
			"create-directory", "Create a directory on OneDrive - no sync will be performed.", &createDirectory,
			"destination-directory", "Destination directory for renamed or move on OneDrive - no sync will be performed.", &destinationDirectory,
			"debug-https", "Debug OneDrive HTTPS communication.", &debugHttp,
			"disable-notifications", "Do not use desktop notifications in monitor mode.", &disableNotifications,
			"display-config", "Display what options the client will use as currently configured - no sync will be performed.", &displayConfiguration,
			"display-sync-status", "Display the sync status of the client - no sync will be performed.", &displaySyncStatus,
			"download-only|d", "Only download remote changes", &downloadOnly,
			"disable-upload-validation", "Disable upload validation when uploading to OneDrive", &disableUploadValidation,
			"dry-run", "Perform a trial sync with no changes made", &dryRun,
			"enable-logging", "Enable client activity to a separate log file", &enableLogFile,
			"force-http-1.1", "Force the use of HTTP 1.1 for all operations", &forceHTTP11,
			"get-O365-drive-id", "Query and return the Office 365 Drive ID for a given Office 365 SharePoint Shared Library", &o365SharedLibraryName,
			"local-first", "Synchronize from the local directory source first, before downloading changes from OneDrive.", &localFirst,
			"logout", "Logout the current user", &logout,
			"monitor|m", "Keep monitoring for local and remote changes", &monitor,
			"no-remote-delete", "Do not delete local file 'deletes' from OneDrive when using --upload-only", &noRemoteDelete,
			"print-token", "Print the access token, useful for debugging", &printAccessToken,
			"resync", "Forget the last saved state, perform a full sync", &resync,
			"remove-directory", "Remove a directory on OneDrive - no sync will be performed.", &removeDirectory,
			"single-directory", "Specify a single local directory within the OneDrive root to sync.", &singleDirectory,
			"skip-dot-files", "Skip dot files and folders from syncing", &skipDotFiles,
			"skip-symlinks", "Skip syncing of symlinks", &skipSymlinks,
			"source-directory", "Source directory to rename or move on OneDrive - no sync will be performed.", &sourceDirectory,
			"syncdir", "Specify the local directory used for synchronization to OneDrive", &syncDirName,
			"synchronize", "Perform a synchronization", &synchronize,
			"upload-only", "Only upload to OneDrive, do not sync changes from OneDrive locally", &uploadOnly,
			"verbose|v+", "Print more details, useful for debugging (repeat for extra debugging)", &log.verbose,
			"version", "Print the version and exit", &printVersion
		);
		if (opt.helpWanted) {
			outputLongHelp(opt.options);
			return EXIT_SUCCESS;
		}
	} catch (GetOptException e) {
		log.error(e.msg);
		log.error("Try 'onedrive -h' for more information");
		return EXIT_FAILURE;
	} catch (Exception e) {
		// error
		log.error(e.msg);
		log.error("Try 'onedrive -h' for more information");
		return EXIT_FAILURE;
	}

	// Main function variables
	string homePath = "";
	string configDirBase = "";
	// Debug the HTTPS response operations if required
	bool debugHttpSubmit;
	// Are we able to reach the OneDrive Service
	bool online = false;
	// simulateNoRefreshTokenFile in case of --dry-run & --logout
	bool simulateNoRefreshTokenFile = false;
	
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
	
	if (printVersion) {
		std.stdio.write("onedrive ", import("version"));
		return EXIT_SUCCESS;
	}
	
	// dry-run notification
	if (dryRun) {
		log.log("DRY-RUN Configured. Output below shows what 'would' have occurred.");
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
	
	// dry-run database setup
	if (dryRun) {
		// Make a copy of the original items.sqlite3 for use as the dry run copy if it exists
		if (exists(cfg.databaseFilePath)) {
			// copy the file
			log.vdebug("Copying items.sqlite3 to items-dryrun.sqlite3 to use for dry run operations");
			copy(cfg.databaseFilePath,cfg.databaseFilePathDryRun);
		}
	}
	
	// command line parameters to override default 'config' & take precedence
	// Set the client to skip specific directories if .nosync is found AND ONLY if --check-for-nosync was passed in
	if (checkNoSync) {
		log.vdebug("CLI override to set check_nosync to: true");
		cfg.setValue("check_nosync", "true");
	}
	
	// Set the client to skip dot files & folders if --skip-dot-files was passed in
	if (skipDotFiles) {
		// The user passed in an alternate skip_dotfiles as to what was either in 'config' file or application default
		log.vdebug("CLI override to set skip_dotfiles to: true");
		cfg.setValue("skip_dotfiles", "true");
	}
	
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
		if (!dryRun) {
			safeRemove(configDirName ~ "/items.db");
		}
		log.logAndNotify("Database schema changed, resync needed");
		resync = true;
	}

	if (resync || logout) {
		log.vlog("Deleting the saved status ...");
		if (!dryRun) {
			safeRemove(cfg.databaseFilePath);
			safeRemove(cfg.deltaLinkFilePath);
			safeRemove(cfg.uploadStateFilePath);
		}
		if (logout) {
			if (!dryRun) {
				safeRemove(cfg.refreshTokenFilePath);
			} else {
				// simulate file being removed / unavailable
				simulateNoRefreshTokenFile = true;
			}
		}
	}

	// Display current application configuration, no application initialisation
	if (displayConfiguration){
		string userConfigFilePath = configDirName ~ "/config";
		string userSyncList = configDirName ~ "/sync_list";
		// Display application version
		std.stdio.write("onedrive version                    = ", import("version"));
		// Display all of the pertinent configuration options
		writeln("Config path                         = ", configDirName);
		
		// Does a config file exist or are we using application defaults
		if (exists(userConfigFilePath)){
			writeln("Config file found in config path    = true");
		} else {
			writeln("Config file found in config path    = false");
		}
		
		// Config Options
		writeln("Config option 'check_nosync'        = ", cfg.getValue("check_nosync"));
		writeln("Config option 'sync_dir'            = ", syncDir);
		writeln("Config option 'skip_file'           = ", cfg.getValue("skip_file"));
		writeln("Config option 'skip_dotfiles'       = ", cfg.getValue("skip_dotfiles"));
		writeln("Config option 'skip_symlinks'       = ", cfg.getValue("skip_symlinks"));
		writeln("Config option 'monitor_interval'    = ", cfg.getValue("monitor_interval"));
		writeln("Config option 'min_notif_changes'   = ", cfg.getValue("min_notif_changes"));
		writeln("Config option 'log_dir'             = ", cfg.getValue("log_dir"));
		
		// Is config option drive_id configured?
		if (cfg.getValue("drive_id", "") != ""){
			writeln("Config option 'drive_id'            = ", cfg.getValue("drive_id"));
		}
		
		// Is sync_list configured?
		if (exists(userSyncList)){
			writeln("Selective sync configured           = true");
			writeln("sync_list contents:");
			// Output the sync_list contents
			auto syncListFile = File(userSyncList);
			auto range = syncListFile.byLine();
			foreach (line; range)
			{
				writeln(line);
			}
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
	oneDrive = new OneDriveApi(cfg, debugHttp, forceHTTP11, dryRun, simulateNoRefreshTokenFile);
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
	
	// Initialize the item database
	log.vlog("Opening the item database ...");
	if (!dryRun) {
		// Load the items.sqlite3 file as the database
		log.vdebug("Using database file: ", cfg.databaseFilePath);
		itemDb = new ItemDatabase(cfg.databaseFilePath);
	} else {
		// Load the items-dryrun.sqlite3 file as the database
		log.vdebug("Using database file: ", cfg.databaseFilePathDryRun);
		itemDb = new ItemDatabase(cfg.databaseFilePathDryRun);
	}
	
	log.vlog("All operations will be performed in: ", syncDir);
	if (!exists(syncDir)) {
		log.vdebug("syncDir: Configured syncDir is missing. Creating: ", syncDir);
		mkdirRecurse(syncDir);
	}
	chdir(syncDir);
	
	// Configure selective sync by parsing and getting a regex for skip_file config component
	auto selectiveSync = new SelectiveSync();
	if (exists(cfg.syncListFilePath)){
		log.vdebug("Loading user configured sync_list file ...");
		// list what will be synced
		auto syncListFile = File(cfg.syncListFilePath);
		auto range = syncListFile.byLine();
		foreach (line; range)
		{
			log.vdebug("sync_list: ", line);
		}
	}
	selectiveSync.load(cfg.syncListFilePath);
	selectiveSync.setMask(cfg.getValue("skip_file"));
	
	// Initialize the sync engine
	log.logAndNotify("Initializing the Synchronization Engine ...");
	auto sync = new SyncEngine(cfg, oneDrive, itemDb, selectiveSync, dryRun);
	
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
				performSync(sync, singleDirectory, downloadOnly, localFirst, uploadOnly, LOG_NORMAL);
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
				} catch (CurlException e) {
					log.vlog("Offline, cannot create remote dir!");
				} catch(Exception e) {
					log.logAndNotify("Cannot create remote directory: ", e.msg);
				}
			};
			m.onFileChanged = delegate(string path) {
				log.vlog("[M] File changed: ", path);
				try {
					sync.scanForDifferences(path);
				} catch (CurlException e) {
					log.vlog("Offline, cannot upload changed item!");
				} catch(Exception e) {
					log.logAndNotify("Cannot upload file changes/creation: ", e.msg);
				}
			};
			m.onDelete = delegate(string path) {
				log.vlog("[M] Item deleted: ", path);
				try {
					sync.deleteByPath(path);
				} catch (CurlException e) {
					log.vlog("Offline, cannot delete item!");
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
				} catch (CurlException e) {
					log.vlog("Offline, cannot move item!");
				} catch(Exception e) {
					log.logAndNotify("Cannot move item:, ", e.msg);
				}
			};
			signal(SIGINT, &exitHandler);
			signal(SIGTERM, &exitHandler);

			// initialise the monitor class
			if (cfg.getValue("skip_symlinks") == "true") skipSymlinks = true;
			if (cfg.getValue("check_nosync") == "true") checkNoSync = true;
			if (!downloadOnly) m.init(cfg, verbose, skipSymlinks, checkNoSync);
			// monitor loop
			immutable auto checkInterval = dur!"seconds"(to!long(cfg.getValue("monitor_interval")));
			immutable auto logInterval = to!long(cfg.getValue("monitor_log_frequency"));
			auto lastCheckTime = MonoTime.currTime();
			auto logMonitorCounter = 0;
			while (true) {
				if (!downloadOnly) m.update(online);
				auto currTime = MonoTime.currTime();
				if (currTime - lastCheckTime > checkInterval) {
					logMonitorCounter += 1;
					if (logMonitorCounter > logInterval) 
						logMonitorCounter = 1;
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
							performSync(sync, singleDirectory, downloadOnly, localFirst, uploadOnly, (logMonitorCounter == logInterval ? MONITOR_LOG_QUIET : MONITOR_LOG_SILENT));
							if (!downloadOnly) {
								// discard all events that may have been generated by the sync
								m.update(false);
							}
						} catch (CurlException e) {
							// we already tried three times in the performSync routine
							// if we still have problems, then the sync handle might have
							// gone stale and we need to re-initialize the sync engine
							log.log("Persistent connection errors, reinitializing connection");
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

	// Workaround for segfault in std.net.curl.Curl.shutdown() on exit
	oneDrive.http.shutdown();
	
	// Make sure the .wal file is incorporated into the main db before we exit
	destroy(itemDb);
	
	// --dry-run temp database cleanup
	if (dryRun) {
		if (exists(cfg.databaseFilePathDryRun)) {
			// remove the file
			log.vdebug("Removing items-dryrun.sqlite3 as dry run operations complete");
			safeRemove(cfg.databaseFilePathDryRun);	
		}
	}
	
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
void performSync(SyncEngine sync, string singleDirectory, bool downloadOnly, bool localFirst, bool uploadOnly, long logLevel)
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
					if (logLevel < MONITOR_LOG_QUIET) log.log("Syncing changes from selected local path only - NOT syncing data changes from OneDrive ...");
					sync.scanForDifferences(localPath);
				} else {
					// No upload only
					if (localFirst) {
						// Local First
						if (logLevel < MONITOR_LOG_QUIET) log.log("Syncing changes from selected local path first before downloading changes from OneDrive ...");
						sync.scanForDifferences(localPath);
						sync.applyDifferencesSingleDirectory(remotePath);
					} else {
						// OneDrive First
						if (logLevel < MONITOR_LOG_QUIET) log.log("Syncing changes from selected OneDrive path ...");
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
					if (logLevel < MONITOR_LOG_QUIET) log.log("Syncing changes from local path only - NOT syncing data changes from OneDrive ...");
					sync.scanForDifferences(localPath);
				} else {
					// No upload only
					if (localFirst) {
						// sync local files first before downloading from OneDrive
						if (logLevel < MONITOR_LOG_QUIET) log.log("Syncing changes from local path first before downloading changes from OneDrive ...");
						sync.scanForDifferences(localPath);
						sync.applyDifferences();
					} else {
						// sync from OneDrive first before uploading files to OneDrive
						if (logLevel < MONITOR_LOG_SILENT) log.log("Syncing changes from OneDrive ...");
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
void outputLongHelp(Option[] opt)
{
	auto argsNeedingOptions = [
		"--confdir",
		"--create-directory",
		"--destination-directory",
		"--get-O365-drive-id",
		"--remove-directory",
		"--single-directory",
		"--source-directory",
		"--syncdir" ];
	writeln(`OneDrive - a client for OneDrive Cloud Services

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
`);
	foreach (it; opt) {
		writefln("  %s%s%s%s\n      %s",
				it.optShort == "" ? "" : it.optShort ~ " ",
				it.optLong,
				argsNeedingOptions.canFind(it.optLong) ? " ARG" : "",
				it.required ? " (required)" : "", it.help);
	}
}

