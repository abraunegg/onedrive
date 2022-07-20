import core.stdc.stdlib: EXIT_SUCCESS, EXIT_FAILURE, exit;
import core.memory, core.time, core.thread;
import std.getopt, std.file, std.path, std.process, std.stdio, std.conv, std.algorithm.searching, std.string, std.regex;
import config, itemdb, monitor, onedrive, selective, sync, util;
import std.net.curl: CurlException;
import core.stdc.signal;
import std.traits, std.format;
import std.concurrency: receiveTimeout;
static import log;

OneDriveApi oneDrive;
ItemDatabase itemDb;

bool onedriveInitialised = false;
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
	bool displayMemoryUsage = false;
	bool displaySyncOptions = false;
	
	// hash file permission values
	string hashPermissionValue = "600";
	auto convertedPermissionValue = parse!long(hashPermissionValue, 8);

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
		// was itemDb initialised?
		if (itemDb !is null) {
			// Make sure the .wal file is incorporated into the main db before we exit
			itemDb.performVacuum();
			destroy(itemDb);
		}
		// free API instance
		if (oneDrive !is null) {
			destroy(oneDrive);
		}
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
		// was itemDb initialised?
		if (itemDb !is null) {
			// Make sure the .wal file is incorporated into the main db before we exit
			itemDb.performVacuum();
			destroy(itemDb);
		}
		// free API instance
		if (oneDrive !is null) {
			destroy(oneDrive);
		}
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
		log.error("Try 'onedrive --help' for more information");
		return EXIT_FAILURE;
	} catch (Exception e) {
		// generic error
		log.error(e.msg);
		log.error("Try 'onedrive --help' for more information");
		return EXIT_FAILURE;
	}

	// confdirOption must be a directory, not a file
	// - By default ~/.config/onedrive will be used
	// - If the user is using --confdir , the confdirOption needs to be evaluated when trying to load any file
	// load configuration file if available
	auto cfg = new config.Config(confdirOption);
	if (!cfg.initialize()) {
		// There was an error loading the configuration
		// Error message already printed
		return EXIT_FAILURE;
	}
	
	// How was this application started - what options were passed in
	log.vdebug("passed in options: ", args);
	log.vdebug("note --confdir and --verbose not listed in args");

	// set memory display
	displayMemoryUsage = cfg.getValueBool("display_memory");

	// set display sync options
	displaySyncOptions =  cfg.getValueBool("display_sync_options");

	// update configuration from command line args
	cfg.update_from_args(args);
	
	// --resync should be a 'last resort item' .. the user needs to 'accept' to proceed 
	if ((cfg.getValueBool("resync")) && (!cfg.getValueBool("display_config"))) {
		// what is the risk acceptance?
		bool resyncRiskAcceptance = false;
	
		if (!cfg.getValueBool("resync_auth")) {
			// need to prompt user
			char response;
			// warning message
			writeln("\nThe use of --resync will remove your local 'onedrive' client state, thus no record will exist regarding your current 'sync status'");
			writeln("This has the potential to overwrite local versions of files with potentially older versions downloaded from OneDrive which can lead to data loss");
			writeln("If in-doubt, backup your local data first before proceeding with --resync");
			write("\nAre you sure you wish to proceed with --resync? [Y/N] ");
			
			try {
				// Attempt to read user response
				readf(" %c\n", &response);
			} catch (std.format.FormatException e) {
				// Caught an error
				return EXIT_FAILURE;
			}
			
			// Evaluate user repsonse
			if ((to!string(response) == "y") || (to!string(response) == "Y")) {
				// User has accepted --resync risk to proceed
				resyncRiskAcceptance = true;
				// Are you sure you wish .. does not use writeln();
				write("\n");
			}
		} else {
			// resync_auth is true
			resyncRiskAcceptance = true;
		}
		
		// Action based on response
		if (!resyncRiskAcceptance){
			// --resync risk not accepted
			return EXIT_FAILURE;
		}
	}

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
		// Hash file should only be readable by the user who created it - 0600 permissions needed
		configHashFile.setAttributes(to!int(convertedPermissionValue));
	}

	// Does a sync_list file exist with a valid hash file
	if ((exists(syncListFilePath)) && (!exists(syncListHashFile))) {
		// Hash of sync_list file needs to be created
		std.file.write(syncListHashFile, computeQuickXorHash(syncListFilePath));
		// Hash file should only be readable by the user who created it - 0600 permissions needed
		syncListHashFile.setAttributes(to!int(convertedPermissionValue));
	}

	// check if business_shared_folders & business_shared_folders hash exists
	if ((exists(businessSharedFolderFilePath)) && (!exists(businessSharedFoldersHashFile))) {
		// Hash of business_shared_folders file needs to be created
		std.file.write(businessSharedFoldersHashFile, computeQuickXorHash(businessSharedFolderFilePath));
		// Hash file should only be readable by the user who created it - 0600 permissions needed
		businessSharedFoldersHashFile.setAttributes(to!int(convertedPermissionValue));
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
	if (exists(configHashFile)) {
		try {
			previousConfigHash = readText(configHashFile);
		} catch (std.file.FileException e) {
			// Unable to access required file
			log.error("ERROR: Unable to access ", e.msg);
			// Use exit scopes to shutdown API
			return EXIT_FAILURE;
		}
	}
	if (exists(syncListHashFile)) {
		try {
			previousSyncListHash = readText(syncListHashFile);
		} catch (std.file.FileException e) {
			// Unable to access required file
			log.error("ERROR: Unable to access ", e.msg);
			// Use exit scopes to shutdown API
			return EXIT_FAILURE;
		}
	}
	if (exists(businessSharedFoldersHashFile)) {
		try {
			previousBusinessSharedFoldersHash = readText(businessSharedFoldersHashFile);
		} catch (std.file.FileException e) {
			// Unable to access required file
			log.error("ERROR: Unable to access ", e.msg);
			// Use exit scopes to shutdown API
			return EXIT_FAILURE;
		}
	}

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
		if (!cfg.getValueBool("display_config")){
			// only print this message if we are not using --display-config
			log.log("config file has been updated, checking if --resync needed");
		}
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
					// Hash file should only be readable by the user who created it - 0600 permissions needed
					configHashFile.setAttributes(to!int(convertedPermissionValue));
					// create backup copy of current config file
					log.vdebug("making backup of config file as it is out of date");
					std.file.copy(configFilePath, configBackupFile);
					// File Copy should only be readable by the user who created it - 0600 permissions needed
					configBackupFile.setAttributes(to!int(convertedPermissionValue));
				}
			}
		}
	}

	// Is there a backup of the config file if the config file exists?
	if ((exists(configFilePath)) && (!exists(configBackupFile))) {
		// create backup copy of current config file
		std.file.copy(configFilePath, configBackupFile);
		// File Copy should only be readable by the user who created it - 0600 permissions needed
		configBackupFile.setAttributes(to!int(convertedPermissionValue));
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
						// Hash file should only be readable by the user who created it - 0600 permissions needed
						configHashFile.setAttributes(to!int(convertedPermissionValue));
						// create backup copy of current config file
						log.vdebug("making backup of config file as --resync issued");
						std.file.copy(configFilePath, configBackupFile);
						// File copy should only be readable by the user who created it - 0600 permissions needed
						configBackupFile.setAttributes(to!int(convertedPermissionValue));
					}
					if (exists(syncListFilePath)) {
						// update sync_list hash
						log.vdebug("updating sync_list hash as --resync issued");
						std.file.write(syncListHashFile, computeQuickXorHash(syncListFilePath));
						// Hash file should only be readable by the user who created it - 0600 permissions needed
						syncListHashFile.setAttributes(to!int(convertedPermissionValue));
					}
					if (exists(businessSharedFolderFilePath)) {
						// update business_shared_folders hash
						log.vdebug("updating business_shared_folders hash as --resync issued");
						std.file.write(businessSharedFoldersHashFile, computeQuickXorHash(businessSharedFolderFilePath));
						// Hash file should only be readable by the user who created it - 0600 permissions needed
						businessSharedFoldersHashFile.setAttributes(to!int(convertedPermissionValue));
					}
				}
			}
		}
	}

	// dry-run notification and database setup
	if (cfg.getValueBool("dry_run")) {
		log.log("DRY-RUN Configured. Output below shows what 'would' have occurred.");
		string dryRunShmFile = cfg.databaseFilePathDryRun ~ "-shm";
		string dryRunWalFile = cfg.databaseFilePathDryRun ~ "-wal";
		// If the dry run database exists, clean this up
		if (exists(cfg.databaseFilePathDryRun)) {
			// remove the existing file
			log.vdebug("Removing items-dryrun.sqlite3 as it still exists for some reason");
			safeRemove(cfg.databaseFilePathDryRun);
		}
		// silent cleanup of shm and wal files if they exist
		if (exists(dryRunShmFile)) {
			// remove items-dryrun.sqlite3-shm
			safeRemove(dryRunShmFile);
		}
		if (exists(dryRunWalFile)) {
			// remove items-dryrun.sqlite3-wal
			safeRemove(dryRunWalFile);
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
	bool shellEnvSet = false;
	if ((environment.get("SHELL") == "") && (environment.get("USER") == "")){
		log.vdebug("sync_dir: No SHELL or USER environment variable configuration detected");
		// No shell or user set, so expandTilde() will fail - usually headless system running under init.d / systemd or potentially Docker
		// Does the 'currently configured' sync_dir include a ~
		if (canFind(cfg.getValueString("sync_dir"), "~")) {
			// A ~ was found in sync_dir
			log.vdebug("sync_dir: A '~' was found in sync_dir, using the calculated 'homePath' to replace '~' as no SHELL or USER environment variable set");
			syncDir = cfg.homePath ~ strip(cfg.getValueString("sync_dir"), "~");
		} else {
			// No ~ found in sync_dir, use as is
			log.vdebug("sync_dir: Getting syncDir from config value sync_dir");
			syncDir = cfg.getValueString("sync_dir");
		}
	} else {
		// A shell and user is set, expand any ~ as this will be expanded correctly if present
		shellEnvSet = true;
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

	// Configure the logging directory if different from application default
	// log_dir environment handling to handle ~ expansion properly
	string logDir = cfg.getValueString("log_dir");
	if (logDir != cfg.defaultLogFileDir) {
		// user modified log_dir entry
		// if 'log_dir' contains a '~' this needs to be expanded correctly
		if (canFind(cfg.getValueString("log_dir"), "~")) {
			// ~ needs to be expanded correctly
			if (!shellEnvSet) {
				// No shell or user set, so expandTilde() will fail - usually headless system running under init.d / systemd or potentially Docker
				log.vdebug("log_dir: A '~' was found in log_dir, using the calculated 'homePath' to replace '~' as no SHELL or USER environment variable set");
				logDir = cfg.homePath ~ strip(cfg.getValueString("log_dir"), "~");
			} else {
				// A shell and user is set, expand any ~ as this will be expanded correctly if present
				log.vdebug("log_dir: A '~' was found in log_dir, using SHELL or USER environment variable to expand '~'");
				logDir = expandTilde(cfg.getValueString("log_dir"));
			}
		} else {
			// '~' not found in log_dir entry, use as is
			logDir = cfg.getValueString("log_dir");
		}
		// update log_dir with normalised path, with '~' expanded correctly
		cfg.setValueString("log_dir", logDir);
	}

	// Configure logging only if enabled
	if (cfg.getValueBool("enable_logging")){
		// Initialise using the configured logging directory
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

	// Handle --logout as separate item, do not 'resync' on a --logout
	if (cfg.getValueBool("logout")) {
		log.vdebug("--logout requested");
		log.log("Deleting the saved authentication status ...");
		if (!cfg.getValueBool("dry_run")) {
			safeRemove(cfg.refreshTokenFilePath);
		}
		// Exit
		return EXIT_SUCCESS;
	}
	
	// Handle --reauth to re-authenticate the client
	if (cfg.getValueBool("reauth")) {
		log.vdebug("--reauth requested");
		log.log("Deleting the saved authentication status ... re-authentication requested");
		if (!cfg.getValueBool("dry_run")) {
			safeRemove(cfg.refreshTokenFilePath);
		}
	}
	
	// Display current application configuration, no application initialisation
	if (cfg.getValueBool("display_config")){
		// Display application version
		writeln("onedrive version                             = ", strip(import("version")));
		// Display all of the pertinent configuration options
		writeln("Config path                                  = ", cfg.configDirName);
		// Does a config file exist or are we using application defaults
		writeln("Config file found in config path             = ", exists(configFilePath));
		
		// Is config option drive_id configured?
		if (cfg.getValueString("drive_id") != ""){
			writeln("Config option 'drive_id'                     = ", cfg.getValueString("drive_id"));
		}

		// Config Options as per 'config' file
		writeln("Config option 'sync_dir'                     = ", syncDir);
		
		// logging and notifications
		writeln("Config option 'enable_logging'               = ", cfg.getValueBool("enable_logging"));
		writeln("Config option 'log_dir'                      = ", cfg.getValueString("log_dir"));
		writeln("Config option 'disable_notifications'        = ", cfg.getValueBool("disable_notifications"));
		writeln("Config option 'min_notify_changes'           = ", cfg.getValueLong("min_notify_changes"));
		
		// skip files and directory and 'matching' policy
		writeln("Config option 'skip_dir'                     = ", cfg.getValueString("skip_dir"));
		writeln("Config option 'skip_dir_strict_match'        = ", cfg.getValueBool("skip_dir_strict_match"));
		writeln("Config option 'skip_file'                    = ", cfg.getValueString("skip_file"));
		writeln("Config option 'skip_dotfiles'                = ", cfg.getValueBool("skip_dotfiles"));
		writeln("Config option 'skip_symlinks'                = ", cfg.getValueBool("skip_symlinks"));
		
		// --monitor sync process options
		writeln("Config option 'monitor_interval'             = ", cfg.getValueLong("monitor_interval"));
		writeln("Config option 'monitor_log_frequency'        = ", cfg.getValueLong("monitor_log_frequency"));
		writeln("Config option 'monitor_fullscan_frequency'   = ", cfg.getValueLong("monitor_fullscan_frequency"));
		
		// sync process and method
		writeln("Config option 'dry_run'                      = ", cfg.getValueBool("dry_run"));
		writeln("Config option 'upload_only'                  = ", cfg.getValueBool("upload_only"));
		writeln("Config option 'download_only'                = ", cfg.getValueBool("download_only"));
		writeln("Config option 'local_first'                  = ", cfg.getValueBool("local_first"));
		writeln("Config option 'check_nosync'                 = ", cfg.getValueBool("check_nosync"));
		writeln("Config option 'check_nomount'                = ", cfg.getValueBool("check_nomount"));
		writeln("Config option 'resync'                       = ", cfg.getValueBool("resync"));
		writeln("Config option 'resync_auth'                  = ", cfg.getValueBool("resync_auth"));

		// data integrity
		writeln("Config option 'classify_as_big_delete'       = ", cfg.getValueLong("classify_as_big_delete"));
		writeln("Config option 'disable_upload_validation'    = ", cfg.getValueBool("disable_upload_validation"));
		writeln("Config option 'bypass_data_preservation'     = ", cfg.getValueBool("bypass_data_preservation"));
		writeln("Config option 'no_remote_delete'             = ", cfg.getValueBool("no_remote_delete"));
		writeln("Config option 'remove_source_files'          = ", cfg.getValueBool("remove_source_files"));
		writeln("Config option 'sync_dir_permissions'         = ", cfg.getValueLong("sync_dir_permissions"));
		writeln("Config option 'sync_file_permissions'        = ", cfg.getValueLong("sync_file_permissions"));
		writeln("Config option 'space_reservation'            = ", cfg.getValueLong("space_reservation"));
		
		// curl operations
		writeln("Config option 'application_id'               = ", cfg.getValueString("application_id"));
		writeln("Config option 'azure_ad_endpoint'            = ", cfg.getValueString("azure_ad_endpoint"));
		writeln("Config option 'azure_tenant_id'              = ", cfg.getValueString("azure_tenant_id"));
		writeln("Config option 'user_agent'                   = ", cfg.getValueString("user_agent"));
		writeln("Config option 'force_http_11'                = ", cfg.getValueBool("force_http_11"));
		writeln("Config option 'debug_https'                  = ", cfg.getValueBool("debug_https"));
		writeln("Config option 'rate_limit'                   = ", cfg.getValueLong("rate_limit"));
		writeln("Config option 'operation_timeout'            = ", cfg.getValueLong("operation_timeout"));
		
		
		// Is sync_list configured ?
		writeln("Config option 'sync_root_files'              = ", cfg.getValueBool("sync_root_files"));
		if (exists(syncListFilePath)){
			
			writeln("Selective sync 'sync_list' configured        = true");
			writeln("sync_list contents:");
			// Output the sync_list contents
			auto syncListFile = File(syncListFilePath, "r");
			auto range = syncListFile.byLine();
			foreach (line; range)
			{
				writeln(line);
			}
		} else {
			writeln("Selective sync 'sync_list' configured        = false");
			
		}

		// Is business_shared_folders enabled and configured ?
		writeln("Config option 'sync_business_shared_folders' = ", cfg.getValueBool("sync_business_shared_folders"));
		if (exists(businessSharedFolderFilePath)){
			writeln("Business Shared Folders configured           = true");
			writeln("business_shared_folders contents:");
			// Output the business_shared_folders contents
			auto businessSharedFolderFileList = File(businessSharedFolderFilePath, "r");
			auto range = businessSharedFolderFileList.byLine();
			foreach (line; range)
			{
				writeln(line);
			}
		} else {
			writeln("Business Shared Folders configured           = false");
		}
		
		// Are webhooks enabled?
		writeln("Config option 'webhook_enabled'              = ", cfg.getValueBool("webhook_enabled"));
		if (cfg.getValueBool("webhook_enabled")) {
			writeln("Config option 'webhook_public_url'           = ", cfg.getValueString("webhook_public_url"));
			writeln("Config option 'webhook_listening_host'       = ", cfg.getValueString("webhook_listening_host"));
			writeln("Config option 'webhook_listening_port'       = ", cfg.getValueLong("webhook_listening_port"));
			writeln("Config option 'webhook_expiration_interval'  = ", cfg.getValueLong("webhook_expiration_interval"));
			writeln("Config option 'webhook_renewal_interval'     = ", cfg.getValueLong("webhook_renewal_interval"));
		}
		
		// Exit
		return EXIT_SUCCESS;
	}

	// --upload-only and --download-only are mutually exclusive and cannot be used together
	if ((cfg.getValueBool("upload_only")) && (cfg.getValueBool("download_only"))) {
		// both cannot be true at the same time
		writeln("ERROR: --upload-only and --download-only are mutually exclusive and cannot be used together.\n");
		return EXIT_FAILURE;
	}

	// Handle --resync to remove local files
	if (cfg.getValueBool("resync")) {
		log.vdebug("--resync requested");
		log.log("Deleting the saved application sync status ...");
		if (!cfg.getValueBool("dry_run")) {
			safeRemove(cfg.databaseFilePath);
			safeRemove(cfg.deltaLinkFilePath);
			safeRemove(cfg.uploadStateFilePath);
		}
	}
	
	// Test if OneDrive service can be reached, exit if it cant be reached
	log.vdebug("Testing network to ensure network connectivity to Microsoft OneDrive Service");
	online = testNetwork();
	if (!online) {
		// Cant initialise the API as we are not online
		if (!cfg.getValueBool("monitor")) {
			// Running as --synchronize
			log.error("Unable to reach Microsoft OneDrive API service, unable to initialize application\n");
			return EXIT_FAILURE;
		} else {
			// Running as --monitor
			log.error("Unable to reach Microsoft OneDrive API service at this point in time, re-trying network tests\n");

			// re-try network connection to OneDrive
			// https://github.com/abraunegg/onedrive/issues/1184
			// Back off & retry with incremental delay
			int retryCount = 10000;
			int retryAttempts = 1;
			int backoffInterval = 1;
			int maxBackoffInterval = 3600;

			bool retrySuccess = false;
			while (!retrySuccess){
				// retry to access OneDrive API
				backoffInterval++;
				int thisBackOffInterval = retryAttempts*backoffInterval;
				log.vdebug("  Retry Attempt:      ", retryAttempts);
				if (thisBackOffInterval <= maxBackoffInterval) {
					log.vdebug("  Retry In (seconds): ", thisBackOffInterval);
					Thread.sleep(dur!"seconds"(thisBackOffInterval));
				} else {
					log.vdebug("  Retry In (seconds): ", maxBackoffInterval);
					Thread.sleep(dur!"seconds"(maxBackoffInterval));
				}
				// perform the re-rty
				online = testNetwork();
				if (online) {
					// We are now online
					log.log("Internet connectivity to Microsoft OneDrive service has been restored");
					retrySuccess = true;
				} else {
					// We are still offline
					if (retryAttempts == retryCount) {
						// we have attempted to re-connect X number of times
						// false set this to true to break out of while loop
						retrySuccess = true;
					}
				}
				// Increment & loop around
				retryAttempts++;
			}
			if (!online) {
				// Not online after 1.2 years of trying
				log.error("ERROR: Was unable to reconnect to the Microsoft OneDrive service after 10000 attempts lasting over 1.2 years!");
				return EXIT_FAILURE;
			}
		}
	}
	
	// Check application version and Initialize OneDrive API, check for authorization
	if (online) {
		// Check Application Version
		log.vlog("Checking Application Version ...");
		checkApplicationVersion();
	
		// we can only initialise if we are online
		log.vlog("Initializing the OneDrive API ...");
		oneDrive = new OneDriveApi(cfg);
		onedriveInitialised = oneDrive.init();
		oneDrive.printAccessToken = cfg.getValueBool("print_token");
	}

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
	if (((cfg.getValueString("create_directory") != "") || (cfg.getValueString("remove_directory") != "")) || ((cfg.getValueString("source_directory") != "") && (cfg.getValueString("destination_directory") != "")) || (cfg.getValueString("get_file_link") != "") || (cfg.getValueString("modified_by") != "") || (cfg.getValueString("create_share_link") != "") || (cfg.getValueString("get_o365_drive_id") != "") || cfg.getValueBool("display_sync_status") || cfg.getValueBool("list_business_shared_folders")) {
		performSyncOK = true;
	}

	// Were acceptable sync operations provided? Was --synchronize or --monitor passed in
	if (!performSyncOK) {
		// was the application just authorised?
		if (cfg.applicationAuthorizeResponseUri) {
			// Application was just authorised
			if (exists(cfg.refreshTokenFilePath)) {
				// OneDrive refresh token exists
				log.log("\nApplication has been successfully authorised, however no additional command switches were provided.\n");
				log.log("Please use 'onedrive --help' for further assistance in regards to running this application.\n");
				// Use exit scopes to shutdown API
				return EXIT_SUCCESS;
			} else {
				// we just authorised, but refresh_token does not exist .. probably an auth error
				log.log("\nApplication has not been successfully authorised. Please check your URI response entry and try again.\n");
				return EXIT_FAILURE;
			}
		} else {
			// Application was not just authorised
			log.log("\n--synchronize or --monitor switches missing from your command line input. Please add one (not both) of these switches to your command line or use 'onedrive --help' for further assistance.\n");
			log.log("No OneDrive sync will be performed without one of these two arguments being present.\n");
			// Use exit scopes to shutdown API
			return EXIT_FAILURE;
		}
	}

	// if --synchronize && --monitor passed in, exit & display help as these conflict with each other
	if (cfg.getValueBool("synchronize") && cfg.getValueBool("monitor")) {
		writeln("\nERROR: --synchronize and --monitor cannot be used together\n");
		writeln("Please use 'onedrive --help' for further assistance in regards to running this application.\n");
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

	// What are the permission that have been set for the application?
	// These are relevant for:
	// - The ~/OneDrive parent folder or 'sync_dir' configured item
	// - Any new folder created under ~/OneDrive or 'sync_dir'
	// - Any new file created under ~/OneDrive or 'sync_dir'
	// valid permissions are 000 -> 777 - anything else is invalid
	if ((cfg.getValueLong("sync_dir_permissions") < 0) || (cfg.getValueLong("sync_file_permissions") < 0) || (cfg.getValueLong("sync_dir_permissions") > 777) || (cfg.getValueLong("sync_file_permissions") > 777)) {
		log.error("ERROR: Invalid 'User|Group|Other' permissions set within config file. Please check.");
		return EXIT_FAILURE;
	} else {
		// debug log output what permissions are being set to
		log.vdebug("Configuring default new folder permissions as: ", cfg.getValueLong("sync_dir_permissions"));
		cfg.configureRequiredDirectoryPermisions();
		log.vdebug("Configuring default new file permissions as: ", cfg.getValueLong("sync_file_permissions"));
		cfg.configureRequiredFilePermisions();
	}

	// configure the sync direcory based on syncDir config option
	log.vlog("All operations will be performed in: ", syncDir);
	if (!exists(syncDir)) {
		log.vdebug("syncDir: Configured syncDir is missing. Creating: ", syncDir);
		try {
			// Attempt to create the sync dir we have been configured with
			mkdirRecurse(syncDir);
			// Configure the applicable permissions for the folder
			log.vdebug("Setting directory permissions for: ", syncDir);
			syncDir.setAttributes(cfg.returnRequiredDirectoryPermisions());
		} catch (std.file.FileException e) {
			// Creating the sync directory failed
			log.error("ERROR: Unable to create local OneDrive syncDir - ", e.msg);
			// Use exit scopes to shutdown API
			return EXIT_FAILURE;
		}
	}

	// Change the working directory to the 'sync_dir' configured item
	chdir(syncDir);

	// Configure selective sync by parsing and getting a regex for skip_file config component
	auto selectiveSync = new SelectiveSync();

	// load sync_list if it exists
	if (exists(syncListFilePath)){
		log.vdebug("Loading user configured sync_list file ...");
		syncListConfigured = true;
		// list what will be synced
		auto syncListFile = File(syncListFilePath, "r");
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
		auto businessSharedFolderFileList = File(businessSharedFolderFilePath, "r");
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

	// Implement https://github.com/abraunegg/onedrive/issues/1129
	// Force a synchronization of a specific folder, only when using --synchronize --single-directory and ignoring all non-default skip_dir and skip_file rules
	if ((cfg.getValueBool("synchronize")) && (cfg.getValueString("single_directory") != "") && (cfg.getValueBool("force_sync"))) {
		log.log("\nWARNING: Overriding application configuration to use application defaults for skip_dir and skip_file due to --synchronize --single-directory --force-sync being used");
		// performing this action could have undesirable effects .. the user must accept this risk
		// what is the risk acceptance?
		bool resyncRiskAcceptance = false;
	
		// need to prompt user
		char response;
		// warning message
		writeln("\nThe use of --force-sync will reconfigure the application to use defaults. This may have untold and unknown future impacts.");
		writeln("By proceeding in using this option you accept any impacts including any data loss that may occur as a result of using --force-sync.");
		write("\nAre you sure you wish to proceed with --force-sync [Y/N] ");
		
		try {
			// Attempt to read user response
			readf(" %c\n", &response);
		} catch (std.format.FormatException e) {
			// Caught an error
			return EXIT_FAILURE;
		}
		
		// Evaluate user repsonse
		if ((to!string(response) == "y") || (to!string(response) == "Y")) {
			// User has accepted --force-sync risk to proceed
			resyncRiskAcceptance = true;
			// Are you sure you wish .. does not use writeln();
			write("\n");
		}
		
		// Action based on response
		if (!resyncRiskAcceptance){
			// --force-sync not accepted
			return EXIT_FAILURE;
		} else {
			// --force-sync risk accepted
			// reset set config using function to use application defaults
			cfg.resetSkipToDefaults();
			// update sync engine regex with reset defaults
			selectiveSync.setDirMask(cfg.getValueString("skip_dir"));
			selectiveSync.setFileMask(cfg.getValueString("skip_file"));		
		}
	}

	// Initialize the sync engine
	auto sync = new SyncEngine(cfg, oneDrive, itemDb, selectiveSync);
	try {
		if (!initSyncEngine(sync)) {
			// Use exit scopes to shutdown API
			return EXIT_FAILURE;
		} else {
			if ((cfg.getValueString("get_file_link") == "") && (cfg.getValueString("create_share_link") == "")) {
				// Print out that we are initializing the engine only if we are not grabbing the file link or creating a shareable link
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
		log.vdebug("Configuring uploadOnly flag to TRUE as --upload-only passed in or configured");
		sync.setUploadOnly();
		// was --no-remote-delete passed in or configured
		if (cfg.getValueBool("no_remote_delete")) {
			// Configure the noRemoteDelete flag
			log.vdebug("Configuring noRemoteDelete flag to TRUE as --no-remote-delete passed in or configured");
			sync.setNoRemoteDelete();
		}
		// was --remove-source-files passed in or configured
		if (cfg.getValueBool("remove_source_files")) {
			// Configure the localDeleteAfterUpload flag
			log.vdebug("Configuring localDeleteAfterUpload flag to TRUE as --remove-source-files passed in or configured");
			sync.setLocalDeleteAfterUpload();
		}
	}

	// Do we configure to disable the upload validation routine
	if (cfg.getValueBool("disable_upload_validation")) sync.setDisableUploadValidation();

	// Do we configure to disable the download validation routine
	if (cfg.getValueBool("disable_download_validation")) sync.setDisableDownloadValidation();

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
			// National Cloud Deployments do not support /delta as a query
			// https://docs.microsoft.com/en-us/graph/deployments#supported-features
			// Flag that we have a valid National Cloud Deployment that cannot use /delta queries
			sync.setNationalCloudDeployment();
		}
	}
	
	// Are we forcing to use /children scan instead of /delta to simulate National Cloud Deployment use of /children?
	if (cfg.getValueBool("force_children_scan")) {
		log.vdebug("Forcing client to use /children scan rather than /delta to simulate National Cloud Deployment use of /children");
		sync.setNationalCloudDeployment();
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

	// Are we createing an anonymous read-only shareable link for an existing file on OneDrive?
	if (cfg.getValueString("create_share_link") != "") {
		// Query OneDrive for the file, and if valid, create a shareable link for the file
		sync.createShareableLinkForFile(cfg.getValueString("create_share_link"));
		// Exit application
		// Use exit scopes to shutdown API
		return EXIT_SUCCESS;
	}

	// --get-file-link - Are we obtaining the URL path for a synced file?
	if (cfg.getValueString("get_file_link") != "") {
		// Query OneDrive for the file link
		sync.queryOneDriveForFileDetails(cfg.getValueString("get_file_link"), syncDir, "URL");
		// Exit application
		// Use exit scopes to shutdown API
		return EXIT_SUCCESS;
	}
	
	// --modified-by - Are we listing the modified-by details of a provided path?
	if (cfg.getValueString("modified_by") != "") {
		// Query OneDrive for the file link
		sync.queryOneDriveForFileDetails(cfg.getValueString("modified_by"), syncDir, "ModifiedBy");
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
						// The requested path to use with --single-directory does not exist locally within the configured 'sync_dir'
						log.logAndNotify("WARNING: The requested path for --single-directory does not exist locally. Creating requested path within ", syncDir);
						// Make the required --single-directory path locally
						string singleDirectoryPath = cfg.getValueString("single_directory");
						mkdirRecurse(singleDirectoryPath);
						// Configure the applicable permissions for the folder
						log.vdebug("Setting directory permissions for: ", singleDirectoryPath);
						singleDirectoryPath.setAttributes(cfg.returnRequiredDirectoryPermisions());
					}
				}
				// perform a --synchronize sync
				// fullScanRequired = false, for final true-up
				// but if we have sync_list configured, use syncListConfigured which = true
				performSync(sync, cfg.getValueString("single_directory"), cfg.getValueBool("download_only"), cfg.getValueBool("local_first"), cfg.getValueBool("upload_only"), LOG_NORMAL, false, syncListConfigured, displaySyncOptions, cfg.getValueBool("monitor"), m);

				// Write WAL and SHM data to file for this sync
				log.vdebug("Merge contents of WAL and SHM files into main database file");
				itemDb.performVacuum();
			}
		}

		if (cfg.getValueBool("monitor")) {
			log.logAndNotify("Initializing monitor ...");
			log.log("OneDrive monitor interval (seconds): ", cfg.getValueLong("monitor_interval"));

			m.onDirCreated = delegate(string path) {
				// Handle .folder creation if skip_dotfiles is enabled
				if ((cfg.getValueBool("skip_dotfiles")) && (selectiveSync.isDotFile(path))) {
					log.vlog("[M] Skipping watching local path - .folder found & --skip-dot-files enabled: ", path);
				} else {
					log.vlog("[M] Local directory created: ", path);
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
				log.vlog("[M] Local file changed: ", path);
				try {
					sync.scanForDifferences(path);
				} catch (CurlException e) {
					log.vlog("Offline, cannot upload changed item!");
				} catch(Exception e) {
					log.logAndNotify("Cannot upload file changes/creation: ", e.msg);
				}
			};
			m.onDelete = delegate(string path) {
				log.log("Received inotify delete event from operating system .. attempting item deletion as requested");
				log.vlog("[M] Local item deleted: ", path);
				try {
					sync.deleteByPath(path);
				} catch (CurlException e) {
					log.vlog("Offline, cannot delete item!");
				} catch(SyncException e) {
					if (e.msg == "The item to delete is not in the local database") {
						log.vlog("Item cannot be deleted from OneDrive because it was not found in the local database");
					} else {
						log.logAndNotify("Cannot delete remote item: ", e.msg);
					}
				} catch(Exception e) {
					log.logAndNotify("Cannot delete remote item: ", e.msg);
				}
			};
			m.onMove = delegate(string from, string to) {
				log.vlog("[M] Local item moved: ", from, " -> ", to);
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
					oneDrive.shutdown();
					exit(-1);
				}
			}

			// monitor loop
			bool performMonitor = true;
			ulong monitorLoopFullCount = 0;
			immutable auto checkInterval = dur!"seconds"(cfg.getValueLong("monitor_interval"));
			immutable auto githubCheckInterval = dur!"seconds"(86400);
			immutable long logInterval = cfg.getValueLong("monitor_log_frequency");
			immutable long fullScanFrequency = cfg.getValueLong("monitor_fullscan_frequency");
			MonoTime lastCheckTime = MonoTime.currTime();
			MonoTime lastGitHubCheckTime = MonoTime.currTime();
			
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
			immutable bool webhookEnabled = cfg.getValueBool("webhook_enabled");

			while (performMonitor) {
				if (!cfg.getValueBool("download_only")) {
					try {
						m.update(online);
					} catch (MonitorException e) {
						// Catch any exceptions thrown by inotify / monitor engine
						log.error("ERROR: The following inotify error was generated: ", e.msg);
					}
				}

				// Check for notifications pushed from Microsoft to the webhook
				bool notificationReceived = false;
				if (webhookEnabled) {
					// Create a subscription on the first run, or renew the subscription
					// on subsequent runs when it is about to expire.
					oneDrive.createOrRenewSubscription();

					// Process incoming notifications if any.

					// Empirical evidence shows that Microsoft often sends multiple
					// notifications for one single change, so we need a loop to exhaust
					// all signals that were queued up by the webhook. The notifications
					// do not contain any actual changes, and we will always rely do the
					// delta endpoint to sync to latest. Therefore, only one sync run is
					// good enough to catch up for multiple notifications.
					for (int signalCount = 0;; signalCount++) {
						const auto signalExists = receiveTimeout(dur!"seconds"(-1), (ulong _) {});
						if (signalExists) {
							notificationReceived = true;
						} else {
							if (notificationReceived) {
								log.log("Received ", signalCount," refresh signals from the webhook");
							}
							break;
						}
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
				if (notificationReceived || (currTime - lastCheckTime > checkInterval) || (monitorLoopFullCount == 0)) {
					// Check Application Version against GitHub once per day
					if (currTime - lastGitHubCheckTime > githubCheckInterval) {
						// --monitor GitHub Application Version Check time expired
						checkApplicationVersion();
						// update when we have performed this check
						lastGitHubCheckTime = MonoTime.currTime();
					}
					
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

					// do we perform a full scan of sync_dir and database integrity check?
					fullScanCounter += 1;
					// fullScanFrequency = 'monitor_fullscan_frequency' from config
					if (fullScanCounter > fullScanFrequency){
						// 'monitor_fullscan_frequency' counter has exceeded
						fullScanCounter = 1;
						// set fullScanRequired = true due to 'monitor_fullscan_frequency' counter has been exceeded
						fullScanRequired = true;
						// are we using sync_list?
						if (syncListConfigured) {
							// sync list is configured
							syncListConfiguredFullScanOverride = true;
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
							string startMessage = "Starting a sync with OneDrive";
							string finishMessage = "Sync with OneDrive is complete";
							// perform a --monitor sync
							if ((cfg.getValueLong("verbose") > 0) || (logMonitorCounter == logInterval)) {
								// log to console and log file if enabled
								log.log(startMessage);
							} else {
								// log file only if enabled so we know when a sync started when not using --verbose
								log.fileOnly(startMessage);
							}
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
							if ((cfg.getValueLong("verbose") > 0) || (logMonitorCounter == logInterval)) {
								// log to console and log file if enabled
								log.log(finishMessage);
							} else {
								// log file only if enabled so we know when a sync completed when not using --verbose
								log.fileOnly(finishMessage);
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
					
					// Display memory details before cleanup
					if (displayMemoryUsage) log.displayMemoryUsagePreGC();
					// Perform Garbage Cleanup
					GC.collect();
					// Display memory details after cleanup
					if (displayMemoryUsage) log.displayMemoryUsagePostGC();
					
					// If we did a full scan, make sure we merge the conents of the WAL and SHM to disk
					if (fullScanRequired) {
						// Write WAL and SHM data to file for this loop
						log.vdebug("Merge contents of WAL and SHM files into main database file");
						itemDb.performVacuum();
					}
					
					// reset fullScanRequired and syncListConfiguredFullScanOverride
					fullScanRequired = false;
					if (syncListConfigured) syncListConfiguredFullScanOverride = false;
					
					// monitor loop complete
					logOutputMessage = "################################################ LOOP COMPLETE ###############################################";

					// Handle display options
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
				// Sleep the monitor thread for 1 second, loop around and pick up any inotify changes
				Thread.sleep(dur!"seconds"(1));
			}
		}
	}

	// --dry-run temp database cleanup
	if (cfg.getValueBool("dry_run")) {
		string dryRunShmFile = cfg.databaseFilePathDryRun ~ "-shm";
		string dryRunWalFile = cfg.databaseFilePathDryRun ~ "-wal";
		if (exists(cfg.databaseFilePathDryRun)) {
			// remove the file
			log.vdebug("Removing items-dryrun.sqlite3 as dry run operations complete");
			// remove items-dryrun.sqlite3
			safeRemove(cfg.databaseFilePathDryRun);
		}
		// silent cleanup of shm and wal files if they exist
		if (exists(dryRunShmFile)) {
			// remove items-dryrun.sqlite3-shm
			safeRemove(dryRunShmFile);
		}
		if (exists(dryRunWalFile)) {
			// remove items-dryrun.sqlite3-wal
			safeRemove(dryRunWalFile);
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
			log.log("\nAuthorization token invalid, use --reauth to authorize the client again\n");
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
								// Database scan integrity check to compare DB data vs actual content on disk to ensure what we think is local, is local 
								// and that the data 'hash' as recorded in the DB equals the hash of the actual content
								// This process can be extremely expensive time and CPU processing wise
								//
								// fullScanRequired is set to TRUE when the application starts up, or the config option 'monitor_fullscan_frequency' count is reached
								// By default, 'monitor_fullscan_frequency' = 12, and 'monitor_interval' = 300, meaning that by default, a full database consistency check 
								// is done once an hour.
								//
								// To change this behaviour adjust 'monitor_interval' and 'monitor_fullscan_frequency' to desired values in the application config file
								if (fullScanRequired) {
									log.vlog("Performing Database Consistency Integrity Check .. ");
									sync.scanForDifferencesDatabaseScan(localPath);
									// handle any inotify events that occured 'whilst' we were scanning the database
									m.update(true);
								} else {
									log.vdebug("NOT performing Database Integrity Check .. fullScanRequired = FALSE");
									m.update(true);
								}
								
								// Filesystem walk to find new files not uploaded
								log.vdebug("Searching local filesystem for new data");
								sync.scanForDifferencesFilesystemScan(localPath);
								// handle any inotify events that occured 'whilst' we were scanning the local filesystem
								m.update(true);
							}

							// At this point, all OneDrive changes / local changes should be uploaded and in sync
							// This MAY not be the case when using sync_list, thus a full walk of OneDrive ojects is required

							// --synchronize & no sync_list     : fullScanRequired = false, syncListConfiguredFullScanOverride = false
							// --synchronize & sync_list in use : fullScanRequired = false, syncListConfiguredFullScanOverride = true

							// --monitor loops around 12 iterations. On the 1st loop, sets fullScanRequired = true, syncListConfiguredFullScanOverride = true if requried

							// --monitor & no sync_list (loop #1)           : fullScanRequired = true, syncListConfiguredFullScanOverride = false
							// --monitor & no sync_list (loop #2 - #12)     : fullScanRequired = false, syncListConfiguredFullScanOverride = false
							// --monitor & sync_list in use (loop #1)       : fullScanRequired = true, syncListConfiguredFullScanOverride = true
							// --monitor & sync_list in use (loop #2 - #12) : fullScanRequired = false, syncListConfiguredFullScanOverride = false

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
			log.log("Got termination signal, performing clean up");
			// if initialised, shut down the HTTP instance
			if (onedriveInitialised) {
				log.log("Shutting down the HTTP instance");
				oneDrive.shutdown();
			}
			// was itemDb initialised?
			if (itemDb !is null) {
				// Make sure the .wal file is incorporated into the main db before we exit
				log.log("Shutting down db connection and merging temporary data");
				itemDb.performVacuum();
				destroy(itemDb);
			}
		})();
	} catch(Exception e) {}
	exit(0);
}

