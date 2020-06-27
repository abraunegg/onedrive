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
	
	// main function variables
	string confdirOption;
	string configFilePath;
	string syncListFilePath;
	string databaseFilePath;
	string businessSharedFolderFilePath;
	string currentConfigHash;
	string currentSyncListHash;
	string previousConfigHash;
	string previousSyncListHash;
	string configHashFile;
	string syncListHashFile;
	string configBackupFile;
	string syncDir;
	string logOutputMessage;
	string currentBusinessSharedFoldersHash;
	string previousBusinessSharedFoldersHash;
	string businessSharedFoldersHashFile;
	bool configOptionsDifferent = false;
	bool businessSharedFoldersDifferent = false;
	bool syncListConfigured = false;
	bool syncListDifferent = false;
	bool syncDirDifferent = false;
	bool skipFileDifferent = false;
	bool skipDirDifferent = false;
	bool online = false;
	bool performSyncOK = false;
	bool onedriveInitialised = false;
	bool displayMemoryUsage = false;
	bool displaySyncOptions = false;
	
	// Define scopes
	scope(exit) {
		// Display memory details
		if (displayMemoryUsage) {
			log.displayMemoryUsagePreGC();
		}
		// if initialised, shut down the HTTP instance
		if (onedriveInitialised) {
			oneDrive.shutdown();
		}
		// Make sure the .wal file is incorporated into the main db before we exit
		destroy(itemDb);
		// free API instance
		oneDrive = null;
		// Perform Garbage Cleanup
		GC.collect();
		// Display memory details
		if (displayMemoryUsage) {
			log.displayMemoryUsagePostGC();
		}
	}
	
	scope(failure) {
		// Display memory details
		if (displayMemoryUsage) {
			log.displayMemoryUsagePreGC();
		}
		// if initialised, shut down the HTTP instance
		if (onedriveInitialised) {
			oneDrive.shutdown();
		}
		// Make sure the .wal file is incorporated into the main db before we exit
		destroy(itemDb);
		// free API instance
		oneDrive = null;
		// Perform Garbage Cleanup
		GC.collect();
		// Display memory details
		if (displayMemoryUsage) {
			log.displayMemoryUsagePostGC();
		}
	}

	// read in application options as passed in
	try {
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
		// print help and exit
		if (opt.helpWanted) {
			args ~= "--help";
		}
		// print the version and exit
		if (printVersion) {
			writeln("onedrive ", strip(import("version")));
			return EXIT_SUCCESS;
		}
	} catch (GetOptException e) {
		// option errors
		log.error(e.msg);
		log.error("Try 'onedrive -h' for more information");
		return EXIT_FAILURE;
	} catch (Exception e) {
		// generic error
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
	
	// set memory display
	displayMemoryUsage = cfg.getValueBool("display_memory");
	
	// set display sync options
	displaySyncOptions =  cfg.getValueBool("display_sync_options");
	 
	// update configuration from command line args
	cfg.update_from_args(args);
	
	// Initialise normalised file paths
	configFilePath = buildNormalizedPath(cfg.configDirName ~ "/config");
	syncListFilePath = buildNormalizedPath(cfg.configDirName ~ "/sync_list");
	databaseFilePath = buildNormalizedPath(cfg.configDirName ~ "/items.db");
	businessSharedFolderFilePath = buildNormalizedPath(cfg.configDirName ~ "/business_shared_folders");
	
	// Has any of our configuration that would require a --resync been changed?
	// 1. sync_list file modification
	// 2. config file modification - but only if sync_dir, skip_dir, skip_file or drive_id was modified
	// 3. CLI input overriding configured config file option
	configHashFile = buildNormalizedPath(cfg.configDirName ~ "/.config.hash");
	syncListHashFile = buildNormalizedPath(cfg.configDirName ~ "/.sync_list.hash");
	configBackupFile = buildNormalizedPath(cfg.configDirName ~ "/.config.backup");
	businessSharedFoldersHashFile = buildNormalizedPath(cfg.configDirName ~ "/.business_shared_folders.hash");
	
	// Does a config file exist with a valid hash file
	if ((exists(configFilePath)) && (!exists(configHashFile))) {
		// Hash of config file needs to be created
		std.file.write(configHashFile, computeQuickXorHash(configFilePath));
	}
	
	// Does a sync_list file exist with a valid hash file
	if ((exists(syncListFilePath)) && (!exists(syncListHashFile))) {
		// Hash of sync_list file needs to be created
		std.file.write(syncListHashFile, computeQuickXorHash(syncListFilePath));
	}
	
	// check if business_shared_folders & business_shared_folders hash exists
	if ((exists(businessSharedFolderFilePath)) && (!exists(businessSharedFoldersHashFile))) {
		// Hash of business_shared_folders file needs to be created
		std.file.write(businessSharedFoldersHashFile, computeQuickXorHash(businessSharedFolderFilePath));
	}
	
	// If hash files exist, but config files do not ... remove the hash, but only if --resync was issued as now the application will use 'defaults' which 'may' be different
	if ((!exists(configFilePath)) && (exists(configHashFile))) {
		// if --resync safe remove config.hash and config.backup
		if (cfg.getValueBool("resync")) {
			safeRemove(configHashFile);
			safeRemove(configBackupFile);
		}
	}
	
	// If sync_list hash file exists, but sync_list file does not ... remove the hash, but only if --resync was issued as now the application will use 'defaults' which 'may' be different
	if ((!exists(syncListFilePath)) && (exists(syncListHashFile))) {
		// if --resync safe remove sync_list.hash
		if (cfg.getValueBool("resync")) safeRemove(syncListHashFile);
	}
	
	if ((!exists(businessSharedFolderFilePath)) && (exists(businessSharedFoldersHashFile))) {
		// if --resync safe remove business_shared_folders.hash
		if (cfg.getValueBool("resync")) safeRemove(businessSharedFoldersHashFile);
	}
	
	// Read config hashes if they exist
	if (exists(configFilePath)) currentConfigHash = computeQuickXorHash(configFilePath);
	if (exists(syncListFilePath)) currentSyncListHash = computeQuickXorHash(syncListFilePath);
	if (exists(businessSharedFolderFilePath)) currentBusinessSharedFoldersHash = computeQuickXorHash(businessSharedFolderFilePath);
	if (exists(configHashFile)) previousConfigHash = readText(configHashFile);
	if (exists(syncListHashFile)) previousSyncListHash = readText(syncListHashFile);
	if (exists(businessSharedFoldersHashFile)) previousBusinessSharedFoldersHash = readText(businessSharedFoldersHashFile);
	
	// Was sync_list file updated?
	if (currentSyncListHash != previousSyncListHash) {
		// Debugging output to assist what changed
		log.vdebug("sync_list file has been updated, --resync needed");
		syncListDifferent = true;
	}
	
	// Was business_shared_folders updated?
	if (currentBusinessSharedFoldersHash != previousBusinessSharedFoldersHash) {
		// Debugging output to assist what changed
		log.vdebug("business_shared_folders file has been updated, --resync needed");
		businessSharedFoldersDifferent = true;
	}
	
	// Was config file updated between last execution ang this execution?
	if (currentConfigHash != previousConfigHash) {
		// config file was updated, however we only want to trigger a --resync requirement if sync_dir, skip_dir, skip_file or drive_id was modified
		log.log("config file has been updated, checking if --resync needed");
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
			auto configBackupFileHandle = File(configBackupFile, "r");
			string lineBuffer;
			auto range = configBackupFileHandle.byLine();
			// read configBackupFile line by line
			foreach (line; range) {
				lineBuffer = stripLeft(line).to!string;
				if (lineBuffer.length == 0 || lineBuffer[0] == ';' || lineBuffer[0] == '#') continue;
				auto c = lineBuffer.matchFirst(cfg.configRegex);
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
			// close file if open
			if (configBackupFileHandle.isOpen()){
				// close open file
				configBackupFileHandle.close();
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
					std.file.write(configHashFile, computeQuickXorHash(configFilePath));
					// create backup copy of current config file
					log.vdebug("making backup of config file as it is out of date");
					std.file.copy(configFilePath, configBackupFile);
				}
			}
		}
	}
	
	// Is there a backup of the config file if the config file exists?
	if ((exists(configFilePath)) && (!exists(configBackupFile))) {
		// create backup copy of current config file
		std.file.copy(configFilePath, configBackupFile);
	}
	
	// config file set options can be changed via CLI input, specifically these will impact sync and --resync will be needed:
	//  --syncdir ARG
	//  --skip-file ARG
	//  --skip-dir ARG
	if (exists(configFilePath)) {
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
	if (configOptionsDifferent || syncListDifferent || syncDirDifferent || skipFileDifferent || skipDirDifferent || businessSharedFoldersDifferent) {
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
					if (exists(configFilePath)) {
						// update hash
						log.vdebug("updating config hash as --resync issued");
						std.file.write(configHashFile, computeQuickXorHash(configFilePath));
						// create backup copy of current config file
						log.vdebug("making backup of config file as --resync issued");
						std.file.copy(configFilePath, configBackupFile);
					}
					if (exists(syncListFilePath)) {
						// update sync_list hash
						log.vdebug("updating sync_list hash as --resync issued");
						std.file.write(syncListHashFile, computeQuickXorHash(syncListFilePath));
					}
					if (exists(businessSharedFolderFilePath)) {
						// update business_shared_folders hash
						log.vdebug("updating business_shared_folders hash as --resync issued");
						std.file.write(businessSharedFoldersHashFile, computeQuickXorHash(businessSharedFolderFilePath));
					}
				}
			}
		}
	}
	
	// dry-run notification and database setup
	if (cfg.getValueBool("dry_run")) {
		log.log("DRY-RUN Configured. Output below shows what 'would' have occurred.");
		// If the dry run database exists, clean this up
		if (exists(cfg.databaseFilePathDryRun)) {
			// remove the existing file
			log.vdebug("Removing items-dryrun.sqlite3 as it still exists for some reason");
			safeRemove(cfg.databaseFilePathDryRun);	
		}
		
		// Make a copy of the original items.sqlite3 for use as the dry run copy if it exists
		if (exists(cfg.databaseFilePath)) {
			// in a --dry-run --resync scenario, we should not copy the existing database file
			if (!cfg.getValueBool("resync")) {
				// copy the existing DB file to the dry-run copy
				log.vdebug("Copying items.sqlite3 to items-dryrun.sqlite3 to use for dry run operations");
				copy(cfg.databaseFilePath,cfg.databaseFilePathDryRun);
			} else {
				// no database copy due to --resync
				log.vdebug("No database copy created for --dry-run due to --resync also being used");
			}
		}
	}
	
	// sync_dir environment handling to handle ~ expansion properly
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
	
	// Application upgrades - skilion version etc
	if (exists(databaseFilePath)) {
		if (!cfg.getValueBool("dry_run")) {
			safeRemove(databaseFilePath);
		}
		log.logAndNotify("Database schema changed, resync needed");
		cfg.setValueBool("resync", true);
	}
	
	// Handle --resync and --logout to remove local files
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
		// Display application version
		writeln("onedrive version                       = ", strip(import("version")));
		// Display all of the pertinent configuration options
		writeln("Config path                            = ", cfg.configDirName);
		// Does a config file exist or are we using application defaults
		writeln("Config file found in config path       = ", exists(configFilePath));
		
		// Config Options
		writeln("Config option 'check_nosync'           = ", cfg.getValueBool("check_nosync"));
		writeln("Config option 'sync_dir'               = ", syncDir);
		writeln("Config option 'skip_dir'               = ", cfg.getValueString("skip_dir"));
		writeln("Config option 'skip_file'              = ", cfg.getValueString("skip_file"));
		writeln("Config option 'skip_dotfiles'          = ", cfg.getValueBool("skip_dotfiles"));
		writeln("Config option 'skip_symlinks'          = ", cfg.getValueBool("skip_symlinks"));
		writeln("Config option 'monitor_interval'       = ", cfg.getValueLong("monitor_interval"));
		writeln("Config option 'min_notify_changes'     = ", cfg.getValueLong("min_notify_changes"));
		writeln("Config option 'log_dir'                = ", cfg.getValueString("log_dir"));
		writeln("Config option 'classify_as_big_delete' = ", cfg.getValueLong("classify_as_big_delete"));
		
		// Is config option drive_id configured?
		if (cfg.getValueString("drive_id") != ""){
			writeln("Config option 'drive_id'               = ", cfg.getValueString("drive_id"));
		}
		
		// Is sync_list configured?
		if (exists(syncListFilePath)){
			writeln("Config option 'sync_root_files'        = ", cfg.getValueBool("sync_root_files"));
			writeln("Selective sync 'sync_list' configured  = true");
			writeln("sync_list contents:");
			// Output the sync_list contents
			auto syncListFile = File(syncListFilePath);
			auto range = syncListFile.byLine();
			foreach (line; range)
			{
				writeln(line);
			}
		} else {
			writeln("Config option 'sync_root_files'        = ", cfg.getValueBool("sync_root_files"));
			writeln("Selective sync 'sync_list' configured  = false");
		}
		
		// Is business_shared_folders configured
		if (exists(businessSharedFolderFilePath)){
			writeln("Business Shared Folders configured     = true");
			writeln("business_shared_folders contents:");
			// Output the business_shared_folders contents
			auto businessSharedFolderFileList = File(businessSharedFolderFilePath);
			auto range = businessSharedFolderFileList.byLine();
			foreach (line; range)
			{
				writeln(line);
			}
		} else {
			writeln("Business Shared Folders configured     = false");
		}
		
		// Exit
		return EXIT_SUCCESS;
	}
	
	// If the user is still using --force-http-1.1 advise its no longer required
	if (cfg.getValueBool("force_http_11")) {
		log.log("NOTE: The use of --force-http-1.1 is depreciated");
	}
	
	// Test if OneDrive service can be reached
	log.vdebug("Testing network to ensure network connectivity to Microsoft OneDrive Service");
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
	log.vlog("Initializing the OneDrive API ...");
	oneDrive = new OneDriveApi(cfg);
	onedriveInitialised = oneDrive.init();
	oneDrive.printAccessToken = cfg.getValueBool("print_token");
	
	if (!onedriveInitialised) {
		log.error("Could not initialize the OneDrive API");
		// Use exit scopes to shutdown API
		return EXIT_UNAUTHORIZED;
	}
	
	// if --synchronize or --monitor not passed in, configure the flag to display help & exit
	if (cfg.getValueBool("synchronize") || cfg.getValueBool("monitor")) {
		performSyncOK = true;
	}
	
	// create-directory, remove-directory, source-directory, destination-directory
	// these are activities that dont perform a sync, so to not generate an error message for these items either
	if (((cfg.getValueString("create_directory") != "") || (cfg.getValueString("remove_directory") != "")) || ((cfg.getValueString("source_directory") != "") && (cfg.getValueString("destination_directory") != "")) || (cfg.getValueString("get_file_link") != "") || (cfg.getValueString("get_o365_drive_id") != "") || cfg.getValueBool("display_sync_status") || cfg.getValueBool("list_business_shared_folders")) {
		performSyncOK = true;
	}
	
	// Were acceptable sync operations provided? Was --synchronize or --monitor passed in
	if (!performSyncOK) {
		// was the application just authorised?
		if (cfg.applicationAuthorizeResponseUri) {
			// Application was just authorised
			log.log("\nApplication has been successfully authorised, however no additional command switches were provided.\n");
			log.log("Please use --help for further assistance in regards to running this application.\n");
			// Use exit scopes to shutdown API
			return EXIT_SUCCESS;
		} else {
			// Application was not just authorised
			log.log("\n--synchronize or --monitor switches missing from your command line input. Please add one (not both) of these switches to your command line or use --help for further assistance.\n");
			log.log("No OneDrive sync will be performed without one of these two arguments being present.\n");
			// Use exit scopes to shutdown API
			return EXIT_FAILURE;
		}
	}
	
	// if --synchronize && --monitor passed in, exit & display help as these conflict with each other
	if (cfg.getValueBool("synchronize") && cfg.getValueBool("monitor")) {
		writeln("\nERROR: --synchronize and --monitor cannot be used together\n");
		writeln("Refer to --help to determine which command option you should use.\n");
		// Use exit scopes to shutdown API
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
	
	// configure the sync direcory based on syncDir config option
	log.vlog("All operations will be performed in: ", syncDir);
	if (!exists(syncDir)) {
		log.vdebug("syncDir: Configured syncDir is missing. Creating: ", syncDir);
		try {
			// Attempt to create the sync dir we have been configured with
			mkdirRecurse(syncDir);
		} catch (std.file.FileException e) {
			// Creating the sync directory failed
			log.error("ERROR: Unable to create local OneDrive syncDir - ", e.msg);
			// Use exit scopes to shutdown API
			return EXIT_FAILURE;
		}
	}
	chdir(syncDir);
	
	// Configure selective sync by parsing and getting a regex for skip_file config component
	auto selectiveSync = new SelectiveSync();
	
	// load sync_list if it exists
	if (exists(syncListFilePath)){
		log.vdebug("Loading user configured sync_list file ...");
		syncListConfigured = true;
		// list what will be synced
		auto syncListFile = File(syncListFilePath);
		auto range = syncListFile.byLine();
		foreach (line; range)
		{
			log.vdebug("sync_list: ", line);
		}
		// close syncListFile if open
		if (syncListFile.isOpen()){
			// close open file
			syncListFile.close();
		}
	}
	selectiveSync.load(syncListFilePath);
	
	// load business_shared_folders if it exists
	if (exists(businessSharedFolderFilePath)){
		log.vdebug("Loading user configured business_shared_folders file ...");
		// list what will be synced
		auto businessSharedFolderFileList = File(businessSharedFolderFilePath);
		auto range = businessSharedFolderFileList.byLine();
		foreach (line; range)
		{
			log.vdebug("business_shared_folders: ", line);
		}
	}
	selectiveSync.loadSharedFolders(businessSharedFolderFilePath);
	
	// Configure skip_dir, skip_file, skip-dir-strict-match & skip_dotfiles from config entries
	// Handle skip_dir configuration in config file
	log.vdebug("Configuring skip_dir ...");
	log.vdebug("skip_dir: ", cfg.getValueString("skip_dir"));
	selectiveSync.setDirMask(cfg.getValueString("skip_dir"));
	
	// Was --skip-dir-strict-match configured?
	log.vdebug("Configuring skip_dir_strict_match ...");
	log.vdebug("skip_dir_strict_match: ", cfg.getValueBool("skip_dir_strict_match"));
	if (cfg.getValueBool("skip_dir_strict_match")) {
		selectiveSync.setSkipDirStrictMatch();
	}
	
	// Was --skip-dot-files configured?
	log.vdebug("Configuring skip_dotfiles ...");
	log.vdebug("skip_dotfiles: ", cfg.getValueBool("skip_dotfiles"));
	if (cfg.getValueBool("skip_dotfiles")) {
		selectiveSync.setSkipDotfiles();
	}
	
	// Handle skip_file configuration in config file
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
	// All skip_file entries are valid
	log.vdebug("skip_file: ", cfg.getValueString("skip_file"));
	selectiveSync.setFileMask(cfg.getValueString("skip_file"));
	
	// Initialize the sync engine
	auto sync = new SyncEngine(cfg, oneDrive, itemDb, selectiveSync);
	try {
		if (!initSyncEngine(sync)) {
			// Use exit scopes to shutdown API
			return EXIT_FAILURE;
		} else {
			if (cfg.getValueString("get_file_link") == "") {
				// Print out that we are initializing the engine only if we are not grabbing the file link
				log.logAndNotify("Initializing the Synchronization Engine ...");
			}
		}
	} catch (CurlException e) {
		if (!cfg.getValueBool("monitor")) {
			log.log("\nNo Internet connection.");
			// Use exit scopes to shutdown API
			return EXIT_FAILURE;
		}
	}

	// if sync list is configured, set to true now that the sync engine is initialised
	if (syncListConfigured) {
		sync.setSyncListConfigured();
	}
	
	// Do we need to configure specific --upload-only options?
	if (cfg.getValueBool("upload_only")) {
		// --upload-only was passed in or configured
		// was --no-remote-delete passed in or configured
		if (cfg.getValueBool("no_remote_delete")) {
			// Configure the noRemoteDelete flag
			sync.setNoRemoteDelete();
		}
		// was --remove-source-files passed in or configured
		if (cfg.getValueBool("remove_source_files")) {
			// Configure the localDeleteAfterUpload flag
			sync.setLocalDeleteAfterUpload();
		}
	}
			
	// Do we configure to disable the upload validation routine
	if (cfg.getValueBool("disable_upload_validation")) sync.setDisableUploadValidation();
	
	// Has the user enabled to bypass data preservation of renaming local files when there is a conflict?
	if (cfg.getValueBool("bypass_data_preservation")) {
		log.log("WARNING: Application has been configured to bypass local data preservation in the event of file conflict.");
		log.log("WARNING: Local data loss MAY occur in this scenario.");
		sync.setBypassDataPreservation();
	}
	
	// Are we configured to use a National Cloud Deployment
	if (cfg.getValueString("azure_ad_endpoint") != "") {
		// value is configured, is it a valid value?
		if ((cfg.getValueString("azure_ad_endpoint") == "USL4") || (cfg.getValueString("azure_ad_endpoint") == "USL5") || (cfg.getValueString("azure_ad_endpoint") == "DE") || (cfg.getValueString("azure_ad_endpoint") == "CN")) {
			// valid entries to flag we are using a National Cloud Deployment
			sync.setNationalCloudDeployment();
		}
	}
	
	// Do we need to validate the syncDir to check for the presence of a '.nosync' file
	if (cfg.getValueBool("check_nomount")) {
		// we were asked to check the mounts
		if (exists(syncDir ~ "/.nosync")) {
			log.logAndNotify("ERROR: .nosync file found. Aborting synchronization process to safeguard data.");
			// Use exit scopes to shutdown API
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
		// Exit application 
		// Use exit scopes to shutdown API
		return EXIT_SUCCESS;
	}
	
	// Are we obtaining the URL path for a synced file?
	if (cfg.getValueString("get_file_link") != "") {
		sync.queryOneDriveForFileURL(cfg.getValueString("get_file_link"), syncDir);
		// Exit application 
		// Use exit scopes to shutdown API
		return EXIT_SUCCESS;
	}
	
	// Are we listing OneDrive Business Shared Folders
	if (cfg.getValueBool("list_business_shared_folders")) {
		// Is this a business account type?
		if (sync.getAccountType() == "business"){
			// List OneDrive Business Shared Folders
			sync.listOneDriveBusinessSharedFolders();
		} else {
			log.error("ERROR: Unsupported account type for listing OneDrive Business Shared Folders");
		}
		// Exit application 
		// Use exit scopes to shutdown API
		return EXIT_SUCCESS;
	}
	
	// Are we going to sync OneDrive Business Shared Folders
	if (cfg.getValueBool("sync_business_shared_folders")) {
		// Is this a business account type?
		if (sync.getAccountType() == "business"){
			// Configure flag to sync business folders
			sync.setSyncBusinessFolders();
		} else {
			log.error("ERROR: Unsupported account type for syncing OneDrive Business Shared Folders");
		}
	}
	
	// Are we displaying the sync status of the client?
	if (cfg.getValueBool("display_sync_status")) {
		string remotePath = "/";
		// Are we doing a single directory check?
		if (cfg.getValueString("single_directory") != ""){
			// Need two different path strings here
			remotePath = cfg.getValueString("single_directory");
		}
		sync.queryDriveForChanges(remotePath);
	}
	
	// Are we performing a sync, or monitor operation?
	if ((cfg.getValueBool("synchronize")) || (cfg.getValueBool("monitor"))) {
		// Initialise the monitor class, so that we can do more granular inotify handling when performing the actual sync
		// needed for --synchronize and --monitor handling
		Monitor m = new Monitor(selectiveSync);

		if (cfg.getValueBool("synchronize")) {
			if (online) {
				// Check user entry for local path - the above chdir means we are already in ~/OneDrive/ thus singleDirectory is local to this path
				if (cfg.getValueString("single_directory") != "") {
					// Does the directory we want to sync actually exist?
					if (!exists(cfg.getValueString("single_directory"))) {
						// the requested directory does not exist .. 
						log.logAndNotify("ERROR: The requested local directory does not exist. Please check ~/OneDrive/ for requested path");
						// Use exit scopes to shutdown API
						return EXIT_FAILURE;
					}
				}
				// perform a --synchronize sync
				// fullScanRequired = false, for final true-up
				// but if we have sync_list configured, use syncListConfigured which = true
				performSync(sync, cfg.getValueString("single_directory"), cfg.getValueBool("download_only"), cfg.getValueBool("local_first"), cfg.getValueBool("upload_only"), LOG_NORMAL, false, syncListConfigured, displaySyncOptions, cfg.getValueBool("monitor"), m);
			}
		}
			
		if (cfg.getValueBool("monitor")) {
			log.logAndNotify("Initializing monitor ...");
			log.log("OneDrive monitor interval (seconds): ", cfg.getValueLong("monitor_interval"));
			
			m.onDirCreated = delegate(string path) {
				// Handle .folder creation if skip_dotfiles is enabled
				if ((cfg.getValueBool("skip_dotfiles")) && (selectiveSync.isDotFile(path))) {
					log.vlog("[M] Skipping watching path - .folder found & --skip-dot-files enabled: ", path);
				} else {
					log.vlog("[M] Directory created: ", path);
					try {
						sync.scanForDifferences(path);
					} catch (CurlException e) {
						log.vlog("Offline, cannot create remote dir!");
					} catch(Exception e) {
						log.logAndNotify("Cannot create remote directory: ", e.msg);
					}
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
						log.vlog("Item cannot be deleted from OneDrive because not found in the local database");
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
					// Handle .folder -> folder if skip_dotfiles is enabled
					if ((cfg.getValueBool("skip_dotfiles")) && (selectiveSync.isDotFile(from))) {
						// .folder -> folder handling - has to be handled as a new folder
						sync.scanForDifferences(to);
					} else {
						sync.uploadMoveItem(from, to);
					}
				} catch (CurlException e) {
					log.vlog("Offline, cannot move item!");
				} catch(Exception e) {
					log.logAndNotify("Cannot move item: ", e.msg);
				}
			};
			signal(SIGINT, &exitHandler);
			signal(SIGTERM, &exitHandler);

			// attempt to initialise monitor class
			if (!cfg.getValueBool("download_only")) {
				try {
					m.init(cfg, cfg.getValueLong("verbose") > 0, cfg.getValueBool("skip_symlinks"), cfg.getValueBool("check_nosync"));
				} catch (MonitorException e) {
					// monitor initialisation failed
					log.error("ERROR: ", e.msg);
					exit(-1);
				}
			}

			// monitor loop
			bool performMonitor = true;
			ulong monitorLoopFullCount = 0;
			immutable auto checkInterval = dur!"seconds"(cfg.getValueLong("monitor_interval"));
			immutable long logInterval = cfg.getValueLong("monitor_log_frequency");
			immutable long fullScanFrequency = cfg.getValueLong("monitor_fullscan_frequency");
			MonoTime lastCheckTime = MonoTime.currTime();
			long logMonitorCounter = 0;
			long fullScanCounter = 0;
			// set fullScanRequired to true so that at application startup we perform a full walk
			bool fullScanRequired = true;
			bool syncListConfiguredFullScanOverride = false;
			// if sync list is configured, set to true
			if (syncListConfigured) {
				// sync list is configured
				syncListConfiguredFullScanOverride = true;
			}
			
			while (performMonitor) {
				if (!cfg.getValueBool("download_only")) {
					try {
						m.update(online);
					} catch (MonitorException e) {
						// Catch any exceptions thrown by inotify / monitor engine
						log.error("ERROR: The following inotify error was generated: ", e.msg);
					}
				}
				
				auto currTime = MonoTime.currTime();
				// has monitor_interval elapsed or are we at application startup / monitor startup?
				// in a --resync scenario, if we have not 're-populated' the database, valid changes will get skipped:
				//   Monitor directory: ./target
				//   Monitor directory: target/2eVPInOMTFNXzRXeNMEoJch5OR9XpGby
				//   [M] Item moved: random_files/2eVPInOMTFNXzRXeNMEoJch5OR9XpGby -> target/2eVPInOMTFNXzRXeNMEoJch5OR9XpGby
				//   Moving random_files/2eVPInOMTFNXzRXeNMEoJch5OR9XpGby to target/2eVPInOMTFNXzRXeNMEoJch5OR9XpGby
				//   Skipping uploading this new file as parent path is not in the database: target/2eVPInOMTFNXzRXeNMEoJch5OR9XpGby
				// 'target' should be in the DB, it should also exist online, but because of --resync, it does not exist in the database thus parent check fails
				if ((currTime - lastCheckTime > checkInterval) || (monitorLoopFullCount == 0)) {
					// monitor sync loop
					logOutputMessage = "################################################## NEW LOOP ##################################################";
					if (displaySyncOptions) {
						log.log(logOutputMessage);
					} else {
						log.vdebug(logOutputMessage);
					}
					// Increment monitorLoopFullCount
					monitorLoopFullCount++;
					// Display memory details at start of loop
					if (displayMemoryUsage) {
						log.displayMemoryUsagePreGC();
					}
					
					// log monitor output suppression
					logMonitorCounter += 1;
					if (logMonitorCounter > logInterval) {
						logMonitorCounter = 1;
					}

					// do we perform a full scan of sync_dir?
					fullScanCounter += 1;
					if (fullScanCounter > fullScanFrequency){
						// loop counter has exceeded
						fullScanCounter = 1;
						if (syncListConfigured) {
							// set fullScanRequired = true due to sync_list being used
							fullScanRequired = true;
							// sync list is configured
							syncListConfiguredFullScanOverride = true;
						} else {
							// dont set fullScanRequired to true as this is excessive if sync_list is not being used
							fullScanRequired = false;
						}
					}
					
					if (displaySyncOptions) {
						// sync option handling per sync loop
						log.log("fullScanCounter =                    ", fullScanCounter);
						log.log("syncListConfigured =                 ", syncListConfigured);
						log.log("fullScanRequired =                   ", fullScanRequired);
						log.log("syncListConfiguredFullScanOverride = ", syncListConfiguredFullScanOverride);
					} else {
						// sync option handling per sync loop via debug
						log.vdebug("fullScanCounter =                    ", fullScanCounter);
						log.vdebug("syncListConfigured =                 ", syncListConfigured);
						log.vdebug("fullScanRequired =                   ", fullScanRequired);
						log.vdebug("syncListConfiguredFullScanOverride = ", syncListConfiguredFullScanOverride);
					}

					try {
						if (!initSyncEngine(sync)) {
							// Use exit scopes to shutdown API
							return EXIT_FAILURE;
						}
						try {
							// perform a --monitor sync
							if (logMonitorCounter == logInterval) log.log("Starting a sync with OneDrive");
							performSync(sync, cfg.getValueString("single_directory"), cfg.getValueBool("download_only"), cfg.getValueBool("local_first"), cfg.getValueBool("upload_only"), (logMonitorCounter == logInterval ? MONITOR_LOG_QUIET : MONITOR_LOG_SILENT), fullScanRequired, syncListConfiguredFullScanOverride, displaySyncOptions, cfg.getValueBool("monitor"), m);
							if (!cfg.getValueBool("download_only")) {
								// discard all events that may have been generated by the sync that have not already been handled
								try {
									m.update(false);
								} catch (MonitorException e) {
									// Catch any exceptions thrown by inotify / monitor engine
									log.error("ERROR: The following inotify error was generated: ", e.msg);
								}
							}
							if (logMonitorCounter == logInterval) log.log("Sync with OneDrive is complete");
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
					if (syncListConfigured) {
						syncListConfiguredFullScanOverride = false;
					}
					lastCheckTime = MonoTime.currTime();
					// Display memory details before cleanup
					if (displayMemoryUsage) {
						log.displayMemoryUsagePreGC();
					}
					// Perform Garbage Cleanup
					GC.collect();
					// Display memory details after cleanup
					if (displayMemoryUsage) {
						log.displayMemoryUsagePostGC();
					}
					// monitor loop complete
					logOutputMessage = "################################################ LOOP COMPLETE ###############################################";
					if (displaySyncOptions) {
						log.log(logOutputMessage);
					} else {
						log.vdebug(logOutputMessage);
					}
					// Developer break via config option
					if (cfg.getValueLong("monitor_max_loop") > 0) {
						// developer set option to limit --monitor loops
						if (monitorLoopFullCount == (cfg.getValueLong("monitor_max_loop"))) {
							performMonitor = false;
							log.log("Exiting after ", monitorLoopFullCount, " loops due to developer set option");
						}
					}
				}
				Thread.sleep(dur!"msecs"(500));
			}
		}
	}

	// --dry-run temp database cleanup
	if (cfg.getValueBool("dry_run")) {
		if (exists(cfg.databaseFilePathDryRun)) {
			// remove the file
			log.vdebug("Removing items-dryrun.sqlite3 as dry run operations complete");
			safeRemove(cfg.databaseFilePathDryRun);	
		}
	}
	
	// Exit application 
	// Use exit scopes to shutdown API
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
void performSync(SyncEngine sync, string singleDirectory, bool downloadOnly, bool localFirst, bool uploadOnly, long logLevel, bool fullScanRequired, bool syncListConfiguredFullScanOverride, bool displaySyncOptions, bool monitorEnabled, Monitor m)
{
	int count;
	string remotePath = "/";
    string localPath = ".";
	string logOutputMessage;
	
	// performSync API scan triggers
	log.vdebug("performSync API scan triggers");
	log.vdebug("-----------------------------");
	log.vdebug("fullScanRequired =                   ", fullScanRequired);
	log.vdebug("syncListConfiguredFullScanOverride = ", syncListConfiguredFullScanOverride);
	log.vdebug("-----------------------------");
	
	// Are we doing a single directory sync?
	if (singleDirectory != ""){
		// Need two different path strings here
		remotePath = singleDirectory;
		localPath = singleDirectory;
		// Set flag for singleDirectoryScope for change handling
		sync.setSingleDirectoryScope();
	}
	
	// Due to Microsoft Sharepoint 'enrichment' of files, we try to download the Microsoft modified file automatically
	// Set flag if we are in upload only state to handle this differently
	// See: https://github.com/OneDrive/onedrive-api-docs/issues/935 for further details   
	if (uploadOnly) sync.setUploadOnly();
	
	do {
		try {
			// starting a sync
			logOutputMessage = "################################################## NEW SYNC ##################################################";
			if (displaySyncOptions) {
				log.log(logOutputMessage);
			} else {
				log.vdebug(logOutputMessage);
			}
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
					string syncCallLogOutput;
					if (localFirst) {
						// sync local files first before downloading from OneDrive
						if (logLevel < MONITOR_LOG_QUIET) log.log("Syncing changes from local path first before downloading changes from OneDrive ...");
						sync.scanForDifferences(localPath);
						// if syncListConfiguredFullScanOverride = true
						if (syncListConfiguredFullScanOverride) {
							// perform a full walk of OneDrive objects
							sync.applyDifferences(syncListConfiguredFullScanOverride);
						} else {
							// perform a walk based on if a full scan is required
							sync.applyDifferences(fullScanRequired);
						}
					} else {
						// sync from OneDrive first before uploading files to OneDrive
						if (logLevel < MONITOR_LOG_SILENT) log.log("Syncing changes from OneDrive ...");
						
						// For the initial sync, always use the delta link so that we capture all the right delta changes including adds, moves & deletes
						logOutputMessage = "Initial Scan: Call OneDrive Delta API for delta changes as compared to last successful sync.";
						syncCallLogOutput = "Calling sync.applyDifferences(false);";
						if (displaySyncOptions) {
							log.log(logOutputMessage);
							log.log(syncCallLogOutput);
						} else {
							log.vdebug(logOutputMessage);
							log.vdebug(syncCallLogOutput);
						}
						sync.applyDifferences(false);
						
						// is this a download only request?						
						if (!downloadOnly) {
							// process local changes walking the entire path checking for changes
							// in monitor mode all local changes are captured via inotify
							// thus scanning every 'monitor_interval' (default 300 seconds) for local changes is excessive and not required
							logOutputMessage = "Process local filesystem (sync_dir) for file changes as compared to database entries";
							syncCallLogOutput = "Calling sync.scanForDifferences(localPath);";
							if (displaySyncOptions) {
								log.log(logOutputMessage);
								log.log(syncCallLogOutput);
							} else {
								log.vdebug(logOutputMessage);
								log.vdebug(syncCallLogOutput);
							}
							
							// What sort of local scan do we want to do?
							// In --monitor mode, when performing the DB scan, a race condition occurs where by if a file or folder is moved during this process
							// the inotify event is discarded once performSync() is finished (see m.update(false) above), so these events need to be handled
							// This can be remediated by breaking the DB and file system scan into separate processes, and handing any applicable inotify events in between
							if (!monitorEnabled) {
								// --synchronize in use
								// standard process flow
								sync.scanForDifferences(localPath);
							} else {
								// --monitor in use
								// Use individual calls with inotify checks between to avoid a race condition between these 2 functions
								// Database scan
								sync.scanForDifferencesDatabaseScan(localPath);
								// handle any inotify events that occured 'whilst' we were scanning the database
								m.update(true);
								// Filesystem walk to find new files not uploaded
								sync.scanForDifferencesFilesystemScan(localPath);
								// handle any inotify events that occured 'whilst' we were scanning the local filesystem
								m.update(true);
							}
							
							// At this point, all OneDrive changes / local changes should be uploaded and in sync
							// This MAY not be the case when using sync_list, thus a full walk of OneDrive ojects is required
							
							// --synchronize & no sync_list     : fullScanRequired = false, syncListConfiguredFullScanOverride = false
							// --synchronize & sync_list in use : fullScanRequired = false, syncListConfiguredFullScanOverride = true
							
							// --monitor loops around 10 iterations. On the 1st loop, sets fullScanRequired = false, syncListConfiguredFullScanOverride = true if requried
							
							// --monitor & no sync_list (loop #1)           : fullScanRequired = true, syncListConfiguredFullScanOverride = false
							// --monitor & no sync_list (loop #2 - #10)     : fullScanRequired = false, syncListConfiguredFullScanOverride = false
							// --monitor & sync_list in use (loop #1)       : fullScanRequired = true, syncListConfiguredFullScanOverride = true
							// --monitor & sync_list in use (loop #2 - #10) : fullScanRequired = false, syncListConfiguredFullScanOverride = false
							
							// Do not perform a full walk of the OneDrive objects
							if ((!fullScanRequired) && (!syncListConfiguredFullScanOverride)){
								logOutputMessage = "Final True-Up: Do not perform a full walk of the OneDrive objects - not required";
								syncCallLogOutput = "Calling sync.applyDifferences(false);";
								if (displaySyncOptions) {
									log.log(logOutputMessage);
									log.log(syncCallLogOutput);
								} else {
									log.vdebug(logOutputMessage);
									log.vdebug(syncCallLogOutput);
								}
								sync.applyDifferences(false);
							}
							
							// Perform a full walk of OneDrive objects because sync_list is in use / or trigger was set in --monitor loop
							if ((!fullScanRequired) && (syncListConfiguredFullScanOverride)){
								logOutputMessage = "Final True-Up: Perform a full walk of OneDrive objects because sync_list is in use / or trigger was set in --monitor loop";
								syncCallLogOutput = "Calling sync.applyDifferences(true);";
								if (displaySyncOptions) {
									log.log(logOutputMessage);
									log.log(syncCallLogOutput);
								} else {
									log.vdebug(logOutputMessage);
									log.vdebug(syncCallLogOutput);
								}
								sync.applyDifferences(true);
							}
							
							// Perform a full walk of OneDrive objects because a full scan was required
							if ((fullScanRequired) && (!syncListConfiguredFullScanOverride)){
								logOutputMessage = "Final True-Up: Perform a full walk of OneDrive objects because a full scan was required";
								syncCallLogOutput = "Calling sync.applyDifferences(true);";
								if (displaySyncOptions) {
									log.log(logOutputMessage);
									log.log(syncCallLogOutput);
								} else {
									log.vdebug(logOutputMessage);
									log.vdebug(syncCallLogOutput);
								}							
								sync.applyDifferences(true);
							}
							
							// Perform a full walk of OneDrive objects because a full scan was required and sync_list is in use and trigger was set in --monitor loop
							if ((fullScanRequired) && (syncListConfiguredFullScanOverride)){
								logOutputMessage = "Final True-Up: Perform a full walk of OneDrive objects because a full scan was required and sync_list is in use and trigger was set in --monitor loop";
								syncCallLogOutput = "Calling sync.applyDifferences(true);";
								if (displaySyncOptions) {
									log.log(logOutputMessage);
									log.log(syncCallLogOutput);
								} else {
									log.vdebug(logOutputMessage);
									log.vdebug(syncCallLogOutput);
								}
								sync.applyDifferences(true);
							}
						}
					}
				}
			}
			
			// sync is complete
			logOutputMessage = "################################################ SYNC COMPLETE ###############################################";
			if (displaySyncOptions) {
				log.log(logOutputMessage);
			} else {
				log.vdebug(logOutputMessage);
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
			// Use exit scopes to shutdown OneDrive API
		})();
	} catch(Exception e) {}
	exit(0);
}

