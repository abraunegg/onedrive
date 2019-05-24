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
	
	// configuration directory
	string confdirOption;
	
	try {
		// print the version and exit
		bool printVersion = false;
		auto opt = getopt(
			args,
			std.getopt.config.passThrough,
			std.getopt.config.bundling,
			std.getopt.config.caseSensitive,
			"confdir", "Set the directory used to store the configuration files", &confdirOption,
			"verbose|v+", "Print more details, useful for debugging (repeat for extra debugging)", &log.verbose,
			"version", "Print the version and exit", &printVersion
		);
		if (opt.helpWanted) {
			args ~= "--help";
		}
		if (printVersion) {
			std.stdio.write("onedrive ", import("version"));
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
	
	// client version when running in debug mode
	log.vdebug("onedrive version = ", import("version"));

	// load configuration file if available
	auto cfg = new config.Config(confdirOption);
	if (!cfg.initialize()) {
		// There was an error loading the configuration
		// Error message already printed
		return EXIT_FAILURE;
	}
	// update configuration from command line args
	cfg.update_from_args(args);

	// dry-run notification
	if (cfg.getValueBool("dry_run")) {
		log.log("DRY-RUN Configured. Output below shows what 'would' have occurred.");
	}

	// Are we able to reach the OneDrive Service
	bool online = false;

	// dry-run database setup
	if (cfg.getValueBool("dry_run")) {
		// Make a copy of the original items.sqlite3 for use as the dry run copy if it exists
		if (exists(cfg.databaseFilePath)) {
			// copy the file
			log.vdebug("Copying items.sqlite3 to items-dryrun.sqlite3 to use for dry run operations");
			copy(cfg.databaseFilePath,cfg.databaseFilePathDryRun);
		}
	}
	
	// sync_dir environment handling to handle ~ expansion properly
	string syncDir;
	if ((environment.get("SHELL") == "") && (environment.get("USER") == "")){
		log.vdebug("sync_dir: No SHELL or USER environment variable configuration detected");
		// No shell or user set, so expandTilde() will fail - usually headless system running under init.d / systemd or potentially Docker
		// Does the 'currently configured' sync_dir include a ~
		if (canFind(cfg.getValueString("sync_dir"), "~")) {
			// A ~ was found
			log.vdebug("sync_dir: A '~' was found in sync_dir, using the calculated 'homePath' to replace '~'");
			syncDir = cfg.homePath ~ strip(cfg.getValueString("sync_dir"), "~");
		} else {
			// No ~ found in sync_dir, use as is
			log.vdebug("sync_dir: Getting syncDir from config value sync_dir");
			syncDir = cfg.getValueString("sync_dir");
		}
	} else {
		// A shell and user is set, expand any ~ as this will be expanded correctly if present
		log.vdebug("sync_dir: Getting syncDir from config value sync_dir");
		if (canFind(cfg.getValueString("sync_dir"), "~")) {
			log.vdebug("sync_dir: A '~' was found in configured sync_dir, automatically expanding as SHELL and USER environment variable is set");
			syncDir = expandTilde(cfg.getValueString("sync_dir"));
		} else {
			syncDir = cfg.getValueString("sync_dir");
		}
	}
	
	// vdebug syncDir as set and calculated
	log.vdebug("syncDir: ", syncDir);
	
	// Configure logging if enabled
	if (cfg.getValueBool("enable_logging")){
		// Read in a user defined log directory or use the default
		string logDir = cfg.getValueString("log_dir");
		log.vlog("Using logfile dir: ", logDir);
		log.init(logDir);
	}

	// Configure whether notifications are used
	log.setNotifications(cfg.getValueBool("monitor") && !cfg.getValueBool("disable_notifications"));
	
	// upgrades
	if (exists(cfg.configDirName ~ "/items.db")) {
		if (!cfg.getValueBool("dry_run")) {
			safeRemove(cfg.configDirName ~ "/items.db");
		}
		log.logAndNotify("Database schema changed, resync needed");
		cfg.setValueBool("resync", true);
	}

	if (cfg.getValueBool("resync") || cfg.getValueBool("logout")) {
		log.vlog("Deleting the saved status ...");
		if (!cfg.getValueBool("dry_run")) {
			safeRemove(cfg.databaseFilePath);
			safeRemove(cfg.deltaLinkFilePath);
			safeRemove(cfg.uploadStateFilePath);
		}
		if (cfg.getValueBool("logout")) {
			if (!cfg.getValueBool("dry_run")) {
				safeRemove(cfg.refreshTokenFilePath);
			}
		}
	}

	// Display current application configuration, no application initialisation
	if (cfg.getValueBool("display_config")){
		string userConfigFilePath = cfg.configDirName ~ "/config";
		string userSyncList = cfg.configDirName ~ "/sync_list";
		// Display application version
		std.stdio.write("onedrive version                    = ", import("version"));
		// Display all of the pertinent configuration options
		writeln("Config path                         = ", cfg.configDirName);
		
		// Does a config file exist or are we using application defaults
		if (exists(userConfigFilePath)){
			writeln("Config file found in config path    = true");
		} else {
			writeln("Config file found in config path    = false");
		}
		
		// Config Options
		writeln("Config option 'check_nosync'        = ", cfg.getValueBool("check_nosync"));
		writeln("Config option 'sync_dir'            = ", syncDir);
		writeln("Config option 'skip_dir'            = ", cfg.getValueString("skip_dir"));
		writeln("Config option 'skip_file'           = ", cfg.getValueString("skip_file"));
		writeln("Config option 'skip_dotfiles'       = ", cfg.getValueBool("skip_dotfiles"));
		writeln("Config option 'skip_symlinks'       = ", cfg.getValueBool("skip_symlinks"));
		writeln("Config option 'monitor_interval'    = ", cfg.getValueLong("monitor_interval"));
		writeln("Config option 'min_notify_changes'  = ", cfg.getValueLong("min_notify_changes"));
		writeln("Config option 'log_dir'             = ", cfg.getValueString("log_dir"));
		
		// Is config option drive_id configured?
		if (cfg.getValueString("drive_id") != ""){
			writeln("Config option 'drive_id'            = ", cfg.getValueString("drive_id"));
		}
		
		// Is sync_list configured?
		if (exists(userSyncList)){
			writeln("Config option 'sync_root_files'     = ", cfg.getValueBool("sync_root_files"));
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
			writeln("Config option 'sync_root_files'     = ", cfg.getValueBool("sync_root_files"));
			writeln("Selective sync configured           = false");
		}
		
		return EXIT_SUCCESS;
	}
	
	log.vlog("Initializing the OneDrive API ...");
	try {
		online = testNetwork();
	} catch (CurlException e) {
		// No network connection to OneDrive Service
		log.error("Cannot connect to Microsoft OneDrive Service");
		log.error("Reason: ", e.msg);
		if (!cfg.getValueBool("monitor")) {
			return EXIT_FAILURE;
		}
	}

	// Initialize OneDrive, check for authorization
	oneDrive = new OneDriveApi(cfg);
	oneDrive.printAccessToken = cfg.getValueBool("print_token");
	if (!oneDrive.init()) {
		log.error("Could not initialize the OneDrive API");
		// workaround for segfault in std.net.curl.Curl.shutdown() on exit
		oneDrive.http.shutdown();
		return EXIT_FAILURE;
	}
	
	// if --synchronize or --monitor not passed in, exit & display help
	auto performSyncOK = false;
	
	if (cfg.getValueBool("synchronize") || cfg.getValueBool("monitor")) {
		performSyncOK = true;
	}
	
	// create-directory, remove-directory, source-directory, destination-directory 
	// are activities that dont perform a sync no error message for these items either
	if (((cfg.getValueString("create_directory") != "") || (cfg.getValueString("remove_directory") != "")) || ((cfg.getValueString("source_directory") != "") && (cfg.getValueString("destination_directory") != "")) || (cfg.getValueString("get_o365_drive_id") != "") || cfg.getValueBool("display_sync_status")) {
		performSyncOK = true;
	}
	
	if (!performSyncOK) {
		writeln("\n--synchronize or --monitor missing from your command options or use --help for further assistance\n");
		writeln("No OneDrive sync will be performed without either of these two arguments being present\n");
		oneDrive.http.shutdown();
		return EXIT_FAILURE;
	}
	
	// if --synchronize && --monitor passed in, exit & display help as these conflict with each other
	if (cfg.getValueBool("synchronize") && cfg.getValueBool("monitor")) {
		writeln("\nERROR: --synchronize and --monitor cannot be used together\n");
		writeln("Refer to --help to determine which command option you should use.\n");
		oneDrive.http.shutdown();
		return EXIT_FAILURE;
	}
	
	// Initialize the item database
	log.vlog("Opening the item database ...");
	if (!cfg.getValueBool("dry_run")) {
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
	
	// Configure skip_dir & skip_file from config entries
	log.vdebug("Configuring skip_dir ...");
	log.vdebug("skip_dir: ", cfg.getValueString("skip_dir"));
	selectiveSync.setDirMask(cfg.getValueString("skip_dir"));
	log.vdebug("Configuring skip_file ...");
	// Validate skip_file to ensure that this does not contain an invalid configuration
	// Do not use a skip_file entry of .* as this will prevent correct searching of local changes to process.
	foreach(entry; cfg.getValueString("skip_file").split("|")){
		if (entry == ".*") {
			// invalid entry element detected
			log.logAndNotify("ERROR: Invalid skip_file entry '.*' detected");
			return EXIT_FAILURE;
		}
	}
	
	// valid entry
	log.vdebug("skip_file: ", cfg.getValueString("skip_file"));
	selectiveSync.setFileMask(cfg.getValueString("skip_file"));
		
	// Initialize the sync engine
	log.logAndNotify("Initializing the Synchronization Engine ...");
	auto sync = new SyncEngine(cfg, oneDrive, itemDb, selectiveSync);
	
	try {
		if (!initSyncEngine(sync)) {
			oneDrive.http.shutdown();
			return EXIT_FAILURE;
		}
	} catch (CurlException e) {
		if (!cfg.getValueBool("monitor")) {
			log.log("\nNo internet connection.");
			oneDrive.http.shutdown();
			return EXIT_FAILURE;
		}
	}

	// We should only set noRemoteDelete in an upload-only scenario
	if ((cfg.getValueBool("upload_only"))&&(cfg.getValueBool("no_remote_delete"))) sync.setNoRemoteDelete();
	
	// Do we configure to disable the upload validation routine
	if (cfg.getValueBool("disable_upload_validation")) sync.setDisableUploadValidation();
	
	// Do we need to validate the syncDir to check for the presence of a '.nosync' file
	if (cfg.getValueBool("check_nomount")) {
		// we were asked to check the mounts
		if (exists(syncDir ~ "/.nosync")) {
			log.logAndNotify("ERROR: .nosync file found. Aborting synchronization process to safeguard data.");
			oneDrive.http.shutdown();
			return EXIT_FAILURE;
		}
	}
	
	// Do we need to create or remove a directory?
	if ((cfg.getValueString("create_directory") != "") || (cfg.getValueString("remove_directory") != "")) {
	
		if (cfg.getValueString("create_directory") != "") {
			// create a directory on OneDrive
			sync.createDirectoryNoSync(cfg.getValueString("create_directory"));
		}
	
		if (cfg.getValueString("remove_directory") != "") {
			// remove a directory on OneDrive
			sync.deleteDirectoryNoSync(cfg.getValueString("remove_directory"));
		}
	}
	
	// Are we renaming or moving a directory?
	if ((cfg.getValueString("source_directory") != "") && (cfg.getValueString("destination_directory") != "")) {
		// We are renaming or moving a directory
		sync.renameDirectoryNoSync(cfg.getValueString("source_directory"), cfg.getValueString("destination_directory"));
	}
	
	// Are we obtaining the Office 365 Drive ID for a given Office 365 SharePoint Shared Library?
	if (cfg.getValueString("get_o365_drive_id") != ""){
		sync.querySiteCollectionForDriveID(cfg.getValueString("get_o365_drive_id"));
	}
	
	// Are we displaying the sync status of the client?
	if (cfg.getValueBool("display_sync_status")) {
		string remotePath = "/";
		string localPath = ".";
		
		// Are we doing a single directory check?
		if (cfg.getValueString("single_directory") != ""){
			// Need two different path strings here
			remotePath = cfg.getValueString("single_directory");
			localPath = cfg.getValueString("single_directory");
		}
		sync.queryDriveForChanges(remotePath);
	}
	
	// Are we performing a sync, resync or monitor operation?
	if ((cfg.getValueBool("synchronize")) || (cfg.getValueBool("resync")) || (cfg.getValueBool("monitor"))) {

		if ((cfg.getValueBool("synchronize")) || (cfg.getValueBool("resync"))) {
			if (online) {
				// Check user entry for local path - the above chdir means we are already in ~/OneDrive/ thus singleDirectory is local to this path
				if (cfg.getValueString("single_directory") != ""){
					// Does the directory we want to sync actually exist?
					if (!exists(cfg.getValueString("single_directory"))){
						// the requested directory does not exist .. 
						log.logAndNotify("ERROR: The requested local directory does not exist. Please check ~/OneDrive/ for requested path");
						oneDrive.http.shutdown();
						return EXIT_FAILURE;
					}
				}
						
				performSync(sync, cfg.getValueString("single_directory"), cfg.getValueBool("download_only"), cfg.getValueBool("local_first"), cfg.getValueBool("upload_only"), LOG_NORMAL, true);
			}
		}
			
		if (cfg.getValueBool("monitor")) {
			log.logAndNotify("Initializing monitor ...");
			log.log("OneDrive monitor interval (seconds): ", cfg.getValueLong("monitor_interval"));
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
			if (!cfg.getValueBool("download_only")) m.init(cfg, cfg.getValueLong("verbose") > 0, cfg.getValueBool("skip_symlinks"), cfg.getValueBool("check_nosync"));
			// monitor loop
			immutable auto checkInterval = dur!"seconds"(cfg.getValueLong("monitor_interval"));
			immutable auto logInterval = cfg.getValueLong("monitor_log_frequency");
			immutable auto fullScanFrequency = cfg.getValueLong("monitor_fullscan_frequency");
			auto lastCheckTime = MonoTime.currTime();
			auto logMonitorCounter = 0;
			auto fullScanCounter = 0;
			bool fullScanRequired = true;
			while (true) {
				if (!cfg.getValueBool("download_only")) m.update(online);
				auto currTime = MonoTime.currTime();
				if (currTime - lastCheckTime > checkInterval) {
					// log monitor output suppression
					logMonitorCounter += 1;
					if (logMonitorCounter > logInterval) 
						logMonitorCounter = 1;
					
					// full scan of sync_dir
					fullScanCounter += 1;
					if (fullScanCounter > fullScanFrequency){
						fullScanCounter = 1;
						fullScanRequired = true;
					}
					
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
							performSync(sync, cfg.getValueString("single_directory"), cfg.getValueBool("download_only"), cfg.getValueBool("local_first"), cfg.getValueBool("upload_only"), (logMonitorCounter == logInterval ? MONITOR_LOG_QUIET : MONITOR_LOG_SILENT), fullScanRequired);
							if (!cfg.getValueBool("download_only")) {
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
					fullScanRequired = false;
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
	if (cfg.getValueBool("dry_run")) {
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
void performSync(SyncEngine sync, string singleDirectory, bool downloadOnly, bool localFirst, bool uploadOnly, long logLevel, bool fullScanRequired)
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
	
	// Due to Microsoft Sharepoint 'enrichment' of files, we try to download the Microsoft modified file automatically
	// Set flag if we are in upload only state to handle this differently
	// See: https://github.com/OneDrive/onedrive-api-docs/issues/935 for further details   
	if (uploadOnly) sync.setUploadOnly();
	
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
						// Is a full scan of the entire sync_dir required?
						if (fullScanRequired) {
							// is this a download only request?						
							if (!downloadOnly) {
								// process local changes walking the entire path checking for changes
								// in monitor mode all local changes are captured via inotify
								// thus scanning every 'monitor_interval' (default 45 seconds) for local changes is excessive and not required
								sync.scanForDifferences(localPath);
								// ensure that the current remote state is updated locally
								sync.applyDifferences();
							}
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

