import core.stdc.stdlib: EXIT_SUCCESS, EXIT_FAILURE, exit;
import core.memory, core.time, core.thread;
import std.getopt, std.file, std.path, std.process, std.stdio, std.conv, std.algorithm.searching, std.string, std.regex;
import config, itemdb, monitor, onedrive, selective, sync, util;
import std.net.curl: CurlException;
import core.stdc.signal;
import std.traits;
static import log;

OneDriveApi oneDrive;
ItemDatabase itemDb;

const int EXIT_UNAUTHORIZED = 3;

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
	
	// load configuration file if available
	auto cfg = new config.Config(confdirOption);
	if (!cfg.initialize()) {
		// There was an error loading the configuration
		// Error message already printed
		return EXIT_FAILURE;
	}
	
	// update configuration from command line args
	cfg.update_from_args(args);
	
	// Has any of our configuration that would require a --resync been changed?
	// 1. sync_list file modification
	// 2. config file modification - but only if sync_dir, skip_dir, skip_file or drive_id was modified
	// 3. CLI input overriding configured config file option
	
	string currentConfigHash;
	string currentSyncListHash;
	string previousConfigHash;
	string previousSyncListHash;
	string configHashFile = cfg.configDirName ~ "/.config.hash";
	string syncListHashFile = cfg.configDirName ~ "/.sync_list.hash";
	string configBackupFile = cfg.configDirName ~ "/.config.backup";
	bool configOptionsDifferent = false;
	bool syncListDifferent = false;
	bool syncDirDifferent = false;
	bool skipFileDifferent = false;
	bool skipDirDifferent = false;
	
	if ((exists(cfg.configDirName ~ "/config")) && (!exists(configHashFile))) {
		// Hash of config file needs to be created
		std.file.write(configHashFile, computeQuickXorHash(cfg.configDirName ~ "/config"));
	}
	
	if ((exists(cfg.configDirName ~ "/sync_list")) && (!exists(syncListHashFile))) {
		// Hash of sync_list file needs to be created
		std.file.write(syncListHashFile, computeQuickXorHash(cfg.configDirName ~ "/sync_list"));
	}
	
	// If hash files exist, but config files do not ... remove the hash, but only if --resync was issued as now the application will use 'defaults' which 'may' be different
	if ((!exists(cfg.configDirName ~ "/config")) && (exists(configHashFile))) {
		// if --resync safe remove config.hash and config.backup
		if (cfg.getValueBool("resync")) {
			safeRemove(configHashFile);
			safeRemove(configBackupFile);
		}
	}
	
	if ((!exists(cfg.configDirName ~ "/sync_list")) && (exists(syncListHashFile))) {
		// if --resync safe remove sync_list.hash
		if (cfg.getValueBool("resync")) safeRemove(syncListHashFile);
	}
	
	// Read config hashes if they exist
	if (exists(cfg.configDirName ~ "/config")) currentConfigHash = computeQuickXorHash(cfg.configDirName ~ "/config");
	if (exists(cfg.configDirName ~ "/sync_list")) currentSyncListHash = computeQuickXorHash(cfg.configDirName ~ "/sync_list");
	if (exists(configHashFile)) previousConfigHash = readText(configHashFile);
	if (exists(syncListHashFile)) previousSyncListHash = readText(syncListHashFile);
	
	// Was sync_list updated?
	if (currentSyncListHash != previousSyncListHash) {
		// Debugging output to assist what changed
		log.vdebug("sync_list file has been updated, --resync needed");
		syncListDifferent = true;
	}
	
	// Was config updated?
	if (currentConfigHash != previousConfigHash) {
		// config file was updated, however we only want to trigger a --resync requirement if sync_dir, skip_dir, skip_file or drive_id was modified
		log.vdebug("config file has been updated, checking if --resync needed");
		if (exists(configBackupFile)) {
			// check backup config what has changed for these configuration options if anything
			// # sync_dir = "~/OneDrive"
			// # skip_file = "~*|.~*|*.tmp"
			// # skip_dir = ""
			// # drive_id = ""
			string[string] stringValues;
			stringValues["sync_dir"] = "";
			stringValues["skip_file"] = "";
			stringValues["skip_dir"] = "";
			stringValues["drive_id"] = "";
			
			auto file = File(configBackupFile, "r");
			auto r = regex(`^(\w+)\s*=\s*"(.*)"\s*$`);
			foreach (line; file.byLine()) {
				line = stripLeft(line);
				if (line.length == 0 || line[0] == ';' || line[0] == '#') continue;
				auto c = line.matchFirst(r);
				if (!c.empty) {
					c.popFront(); // skip the whole match
					string key = c.front.dup;
					auto p = key in stringValues;
					if (p) {
						c.popFront();
						// compare this key
						if ((key == "sync_dir") && (c.front.dup != cfg.getValueString("sync_dir"))) {
							log.vdebug(key, " was modified since the last time the application was successfully run, --resync needed");
							configOptionsDifferent = true;
						}
						
						if ((key == "skip_file") && (c.front.dup != cfg.getValueString("skip_file"))){
							log.vdebug(key, " was modified since the last time the application was successfully run, --resync needed");
							configOptionsDifferent = true;
						}
						if ((key == "skip_dir") && (c.front.dup != cfg.getValueString("skip_dir"))){
							log.vdebug(key, " was modified since the last time the application was successfully run, --resync needed");
							configOptionsDifferent = true;
						}
						if ((key == "drive_id") && (c.front.dup != cfg.getValueString("drive_id"))){
							log.vdebug(key, " was modified since the last time the application was successfully run, --resync needed");
							configOptionsDifferent = true;
						}
					}
				}
			}
		} else {
			// no backup to check
			log.vdebug("WARNING: no backup config file was found, unable to validate if any changes made");
		}
		
		// If there was a backup, any modified values we need to worry about would been detected
		if (!cfg.getValueBool("display_config")) {
			// we are not testing the configuration
			if (!configOptionsDifferent) {
				// no options are different
				if (!cfg.getValueBool("dry_run")) {
					// we are not in a dry-run scenario
					// update config hash
					log.vdebug("updating config hash as it is out of date");
					std.file.write(configHashFile, computeQuickXorHash(cfg.configDirName ~ "/config"));
					// create backup copy of current config file
					log.vdebug("making backup of config file as it is out of date");
					std.file.copy(cfg.configDirName ~ "/config", configBackupFile);
				}
			}
		}
	}
	
	// Is there a backup of the config file if the config file exists?
	if ((exists(cfg.configDirName ~ "/config")) && (!exists(configBackupFile))) {
		// create backup copy of current config file
		std.file.copy(cfg.configDirName ~ "/config", configBackupFile);
	}
	
	// config file set options can be changed via CLI input, specifically these will impact sync and --resync will be needed:
	//  --syncdir ARG
	//  --skip-file ARG
	//  --skip-dir ARG
	if (exists(cfg.configDirName ~ "/config")) {
		// config file exists
		// was the sync_dir updated by CLI?
		if (cfg.configFileSyncDir != "") {
			// sync_dir was set in config file
			if (cfg.configFileSyncDir != cfg.getValueString("sync_dir")) {
				// config file was set and CLI input changed this
				log.vdebug("sync_dir: CLI override of config file option, --resync needed");
				syncDirDifferent = true;
			}
		}
		
		// was the skip_file updated by CLI?
		if (cfg.configFileSkipFile != "") {
			// skip_file was set in config file
			if (cfg.configFileSkipFile != cfg.getValueString("skip_file")) {
				// config file was set and CLI input changed this
				log.vdebug("skip_file: CLI override of config file option, --resync needed");
				skipFileDifferent = true;
			}
		} 
		
		// was the skip_dir updated by CLI?
		if (cfg.configFileSkipDir != "") {
			// skip_dir was set in config file
			if (cfg.configFileSkipDir != cfg.getValueString("skip_dir")) {
				// config file was set and CLI input changed this
				log.vdebug("skip_dir: CLI override of config file option, --resync needed");
				skipDirDifferent = true;
			}
		}
	}
	
	// Has anything triggered a --resync requirement?
	if (configOptionsDifferent || syncListDifferent || syncDirDifferent || skipFileDifferent || skipDirDifferent) {
		// --resync needed, is the user just testing configuration changes?
		if (!cfg.getValueBool("display_config")){
			// not testing configuration changes
			if (!cfg.getValueBool("resync")) {
				// --resync not issued, fail fast
				log.error("An application configuration change has been detected where a --resync is required");
				return EXIT_FAILURE;
			} else {
				// --resync issued, update hashes of config files if they exist
				if (!cfg.getValueBool("dry_run")) {
					// not doing a dry run, update hash files if config & sync_list exist
					if (exists(cfg.configDirName ~ "/config")) {
						// update hash
						log.vdebug("updating config hash as --resync issued");
						std.file.write(configHashFile, computeQuickXorHash(cfg.configDirName ~ "/config"));
						// create backup copy of current config file
						log.vdebug("making backup of config file as --resync issued");
						std.file.copy(cfg.configDirName ~ "/config", configBackupFile);
					}
					if (exists(cfg.configDirName ~ "/sync_list")) {
						// update sync_list hash
						log.vdebug("updating sync_list hash as --resync issued");
						std.file.write(syncListHashFile, computeQuickXorHash(cfg.configDirName ~ "/sync_list"));
					}
				}
			}
		}
	}
	
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
		if (cfg.getValueBool("resync")) log.vdebug("--resync requested");
		log.vlog("Deleting the saved status ...");
		if (!cfg.getValueBool("dry_run")) {
			safeRemove(cfg.databaseFilePath);
			safeRemove(cfg.deltaLinkFilePath);
			safeRemove(cfg.uploadStateFilePath);
		}
		if (cfg.getValueBool("logout")) {
			log.vdebug("--logout requested");
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
		
		// exit
		return EXIT_SUCCESS;
	}
	
	if (cfg.getValueBool("force_http_11")) {
		log.log("NOTE: The use of --force-http-1.1 is depreciated");
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
		return EXIT_UNAUTHORIZED;
	}
	
	// if --synchronize or --monitor not passed in, exit & display help
	auto performSyncOK = false;
	
	if (cfg.getValueBool("synchronize") || cfg.getValueBool("monitor")) {
		performSyncOK = true;
	}
	
	// create-directory, remove-directory, source-directory, destination-directory 
	// are activities that dont perform a sync no error message for these items either
	if (((cfg.getValueString("create_directory") != "") || (cfg.getValueString("remove_directory") != "")) || ((cfg.getValueString("source_directory") != "") && (cfg.getValueString("destination_directory") != "")) || (cfg.getValueString("get_file_link") != "") || (cfg.getValueString("get_o365_drive_id") != "") || cfg.getValueBool("display_sync_status")) {
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
		log.vdebug("Using database file: ", asNormalizedPath(cfg.databaseFilePath));
		itemDb = new ItemDatabase(cfg.databaseFilePath);
	} else {
		// Load the items-dryrun.sqlite3 file as the database
		log.vdebug("Using database file: ", asNormalizedPath(cfg.databaseFilePathDryRun));
		itemDb = new ItemDatabase(cfg.databaseFilePathDryRun);
	}
	
	log.vlog("All operations will be performed in: ", syncDir);
	if (!exists(syncDir)) {
		log.vdebug("syncDir: Configured syncDir is missing. Creating: ", syncDir);
		try {
			// Attempt to create the sync dir we have been configured with
			mkdirRecurse(syncDir);
		} catch (std.file.FileException e) {
			// Creating the sync directory failed
			log.error("ERROR: Unable to create local OneDrive syncDir - ", e.msg);
			oneDrive.http.shutdown();
			return EXIT_FAILURE;
		}
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
	if (cfg.getValueString("get_file_link") == "") {
		// Print out that we are initializing the engine only if we are not grabbing the file link
		log.logAndNotify("Initializing the Synchronization Engine ...");
	}
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
	if (cfg.getValueString("get_o365_drive_id") != "") {
		sync.querySiteCollectionForDriveID(cfg.getValueString("get_o365_drive_id"));
	}
	
	// Are we obtaining the URL path for a synced file?
	if (cfg.getValueString("get_file_link") != "") {
		sync.queryOneDriveForFileURL(cfg.getValueString("get_file_link"), syncDir);
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

