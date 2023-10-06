// What is this module called?
module main;

// What does this module require to function?
import core.stdc.stdlib: EXIT_SUCCESS, EXIT_FAILURE, exit;
import core.stdc.signal;
import core.memory;
import core.time;
import core.thread;
import std.stdio;
import std.getopt;
import std.string;
import std.file;
import std.process;
import std.algorithm;
import std.path;
import std.concurrency;
import std.parallelism;
import std.conv;
import std.traits;
import std.net.curl: CurlException;
import std.datetime;

// What other modules that we have created do we need to import?
import config;
import log;
import curlEngine;
import util;
import onedrive;
import syncEngine;
import itemdb;
import clientSideFiltering;
import monitor;

// What other constant variables do we require?
const int EXIT_RESYNC_REQUIRED = 126;

// Class objects
ApplicationConfig appConfig;
OneDriveApi oneDriveApiInstance;
SyncEngine syncEngineInstance;
ItemDatabase itemDB;
ClientSideFiltering selectiveSync;

int main(string[] cliArgs) {
	// Disable buffering on stdout - this is needed so that when we are using plain write() it will go to the terminal
	stdout.setvbuf(0, _IONBF);
	// Required main function variables
	string genericHelpMessage = "Try 'onedrive --help' for more information";
	// If the user passes in --confdir we need to store this as a variable
	string confdirOption = "";
	// Are we online?
	bool online = false;
	// Does the operating environment have shell environment variables set
	bool shellEnvSet = false;
	// What is the runtime syncronisation directory that will be used
	// Typically this will be '~/OneDrive' .. however tilde expansion is unreliable
	string runtimeSyncDirectory = "";
	// Configure the runtime database file path. Typically this will be the default, but in a --dry-run scenario, we use a separate database file
	string runtimeDatabaseFile = "";
	
	// Application Start Time - used during monitor loop to detail how long it has been running for
	auto applicationStartTime = Clock.currTime();
	
	// DEVELOPER OPTIONS OUTPUT VARIABLES
	bool displayMemoryUsage = false;
	bool displaySyncOptions = false;
	
	// Define 'exit' and 'failure' scopes
	scope(exit) {
		// detail what scope was called
		log.vdebug("Exit scope was called");
		
		// Was itemDB initialised?
		if (itemDB !is null) {
			// Make sure the .wal file is incorporated into the main db before we exit
			itemDB.performVacuum();
			object.destroy(itemDB);
		}
		
		// Free other objects and memory
		if (appConfig !is null) {
			// Cleanup any existing dry-run elements ... these should never be left hanging around
			cleanupDryRunDatabaseFiles(appConfig.databaseFilePathDryRun);
			object.destroy(appConfig);
		}
		if (oneDriveApiInstance !is null) object.destroy(oneDriveApiInstance);
		if (selectiveSync !is null) object.destroy(selectiveSync);
		if (syncEngineInstance !is null) object.destroy(syncEngineInstance);
	}
	
	scope(failure) {
		// detail what scope was called
		log.vdebug("Failure scope was called");
		
		// Was itemDB initialised?
		if (itemDB !is null) {
			// Make sure the .wal file is incorporated into the main db before we exit
			itemDB.performVacuum();
			object.destroy(itemDB);
		}
		
		// Free other objects and memory
		if (appConfig !is null) {
			// Cleanup any existing dry-run elements ... these should never be left hanging around
			cleanupDryRunDatabaseFiles(appConfig.databaseFilePathDryRun);
			object.destroy(appConfig);
		}
		if (oneDriveApiInstance !is null) object.destroy(oneDriveApiInstance);
		if (selectiveSync !is null) object.destroy(selectiveSync);
		if (syncEngineInstance !is null) object.destroy(syncEngineInstance);
		
		// Set these to be null due to failure scope - prevent 'ERROR: Unable to perform a database vacuum: out of memory' when the exit scope is then called
		log.vdebug("Setting Class Objects to null due to failure scope");
		itemDB = null;
		appConfig = null;
		oneDriveApiInstance = null;
		selectiveSync = null;
		syncEngineInstance = null;
	}
	
	// Read in application options as passed in
	try {
		bool printVersion = false;
		auto cliOptions = getopt(
			cliArgs,
			std.getopt.config.passThrough,
			std.getopt.config.bundling,
			std.getopt.config.caseSensitive,
			"confdir", "Set the directory used to store the configuration files", &confdirOption,
			"verbose|v+", "Print more details, useful for debugging (repeat for extra debugging)", &log.verbose,
			"version", "Print the version and exit", &printVersion
		);
		
		// Print help and exit
		if (cliOptions.helpWanted) {
			cliArgs ~= "--help";
		}
		// Print the version and exit
		if (printVersion) {
			//writeln("onedrive ", strip(import("version")));
			string tempVersion = "v2.5.0-alpha-2" ~ " GitHub version: " ~ strip(import("version"));
			writeln(tempVersion);
			return EXIT_SUCCESS;
		}
	} catch (GetOptException e) {
		// Option errors
		log.error(e.msg);
		log.error(genericHelpMessage);
		return EXIT_FAILURE;
	} catch (Exception e) {
		// Generic error
		log.error(e.msg);
		log.error(genericHelpMessage);
		return EXIT_FAILURE;
	}
	
	// How was this application started - what options were passed in
	log.vdebug("passed in options: ", cliArgs);
	log.vdebug("note --confdir and --verbose not listed in 'cliArgs'");

	// Create a new AppConfig object with default values, 
	appConfig = new ApplicationConfig();
	// Initialise the application configuration, utilising --confdir if it was passed in
	// Otherwise application defaults will be used to configure the application
	if (!appConfig.initialise(confdirOption)) {
		// There was an error loading the user specified application configuration
		// Error message already printed
		return EXIT_FAILURE;
	}
	
	// Update the existing application configuration (default or 'config' file) from any passed in command line arguments
	appConfig.updateFromArgs(cliArgs);
	
	// Depreciated options check now that the config file (if present) and CLI options have all been parsed
	appConfig.checkDepreciatedOptions(cliArgs);
	
	// Configure GUI Notifications
	// - This option is reverse action. If 'disable_notifications' is 'true', we need to send 'false'
	if (appConfig.getValueBool("disable_notifications")){
		// disable_notifications is true, initialise with false
		log.enableNotifications(false);
	} else {
		log.enableNotifications(true);
	}
	
	// Configure application logging to a log file only if enabled
	// This is the earliest point to do so as the client configuration has been read in, CLI arguments have been processed. 
	// Either of those could be enabling logging
	if (appConfig.getValueBool("enable_logging")){
		// configure the application logging directory
		string initialisedLogDirPath = appConfig.initialiseLogDirectory();
		// Initialise using the configured logging directory
		log.vlog("Using the following path to store the runtime application log: ", initialisedLogDirPath);
		log.initialise(initialisedLogDirPath);
	}
	
	// Configure Client Side Filtering (selective sync) by parsing and getting a usable regex for skip_file, skip_dir and sync_list config components
	selectiveSync = new ClientSideFiltering(appConfig);
	if (!selectiveSync.initialise()) {
		// exit here as something triggered a selective sync configuration failure
		return EXIT_FAILURE;
	}
	
	// Set runtimeDatabaseFile, this will get updated if we are using --dry-run
	runtimeDatabaseFile = appConfig.databaseFilePath;
	
	// Read in 'sync_dir' from appConfig with '~' if present expanded
	runtimeSyncDirectory = appConfig.initialiseRuntimeSyncDirectory();
	
	// DEVELOPER OPTIONS OUTPUT
	// Set to display memory details as early as possible
	displayMemoryUsage = appConfig.getValueBool("display_memory");
	// set to display sync options
	displaySyncOptions = appConfig.getValueBool("display_sync_options");
	
	// Display the current application configuration (based on all defaults, 'config' file parsing and/or options passed in via the CLI) and exit if --display-config has been used
	if ((appConfig.getValueBool("display_config")) || (appConfig.getValueBool("display_running_config"))) {
		// Display the application configuration
		appConfig.displayApplicationConfiguration();
		// Do we exit? We exit only if '--display-config' has been used
		if (appConfig.getValueBool("display_config")) {
			return EXIT_SUCCESS;
		}
	}
	
	// Check for basic application option conflicts - flags that should not be used together and/or flag combinations that conflict with each other, values that should be present and are not
	if (appConfig.checkForBasicOptionConflicts) {
		// Any error will have been printed by the function itself
		return EXIT_FAILURE;
	}
	
	// Check for --dry-run operation
	// If this has been requested, we need to ensure that all actions are performed against the dry-run database copy, and, 
	// no actual action takes place - such as deleting files if deleted online, moving files if moved online or local, downloading new & changed files, uploading new & changed files
	if (appConfig.getValueBool("dry_run")) {
		// this is a --dry-run operation
		log.log("DRY-RUN Configured. Output below shows what 'would' have occurred.");
		
		// Cleanup any existing dry-run elements ... these should never be left hanging around
		cleanupDryRunDatabaseFiles(appConfig.databaseFilePathDryRun);
		
		// Make a copy of the original items.sqlite3 for use as the dry run copy if it exists
		if (exists(appConfig.databaseFilePath)) {
			// In a --dry-run --resync scenario, we should not copy the existing database file
			if (!appConfig.getValueBool("resync")) {
				// Copy the existing DB file to the dry-run copy
				log.log("DRY-RUN: Copying items.sqlite3 to items-dryrun.sqlite3 to use for dry run operations");
				copy(appConfig.databaseFilePath,appConfig.databaseFilePathDryRun);
			} else {
				// No database copy due to --resync
				log.log("DRY-RUN: No database copy created for --dry-run due to --resync also being used");
			}
		}
		// update runtimeDatabaseFile now that we are using the dry run path
		runtimeDatabaseFile = appConfig.databaseFilePathDryRun;
	}
	
	// Handle --logout as separate item, do not 'resync' on a --logout
	if (appConfig.getValueBool("logout")) {
		log.vdebug("--logout requested");
		log.log("Deleting the saved authentication status ...");
		if (!appConfig.getValueBool("dry_run")) {
			safeRemove(appConfig.refreshTokenFilePath);
		} else {
			// --dry-run scenario ... technically we should not be making any local file changes .......
			log.log("DRY RUN: Not removing the saved authentication status");
		}
		// Exit
		return EXIT_SUCCESS;
	}
	
	// Handle --reauth to re-authenticate the client
	if (appConfig.getValueBool("reauth")) {
		log.vdebug("--reauth requested");
		log.log("Deleting the saved authentication status ... re-authentication requested");
		if (!appConfig.getValueBool("dry_run")) {
			safeRemove(appConfig.refreshTokenFilePath);
		} else {
			// --dry-run scenario ... technically we should not be making any local file changes .......
			log.log("DRY RUN: Not removing the saved authentication status");
		}
	}
	
	// --resync should be considered a 'last resort item' or if the application configuration has changed, where a resync is needed .. the user needs to 'accept' this warning to proceed
	// If --resync has not been used (bool value is false), check the application configuration for 'changes' that require a --resync to ensure that the data locally reflects the users requested configuration
	if (appConfig.getValueBool("resync")) {
		// what is the risk acceptance for --resync?
		bool resyncRiskAcceptance = appConfig.displayResyncRiskForAcceptance();
		log.vdebug("Returned --resync risk acceptance: ", resyncRiskAcceptance);
		// Action based on user response
		if (!resyncRiskAcceptance){
			// --resync risk not accepted
			return EXIT_FAILURE;
		} else {
			log.vdebug("--resync issued and risk accepted");
			// --resync risk accepted, perform a cleanup of items that require a cleanup
			appConfig.cleanupHashFilesDueToResync();
			// Make a backup of the applicable configuration file
			appConfig.createBackupConfigFile();
			// Update hash files and generate a new config backup
			appConfig.updateHashContentsForConfigFiles();
			// Remove the items database
			processResyncDatabaseRemoval(runtimeDatabaseFile);
		}
	} else {
		// Has any of our application configuration that would require a --resync been changed?
		if (appConfig.applicationChangeWhereResyncRequired()) {
			// Application configuration has changed however --resync not issued, fail fast
			log.error("\nAn application configuration change has been detected where a --resync is required\n");
			return EXIT_RESYNC_REQUIRED;
		} else {
			// No configuration change that requires a --resync to be issued
			// Make a backup of the applicable configuration file
			appConfig.createBackupConfigFile();
			// Update hash files and generate a new config backup
			appConfig.updateHashContentsForConfigFiles();
		}
	}
	
	// Implement https://github.com/abraunegg/onedrive/issues/1129
	// Force a synchronization of a specific folder, only when using --synchronize --single-directory and ignoring all non-default skip_dir and skip_file rules
	if (appConfig.getValueBool("force_sync")) {
		// appConfig.checkForBasicOptionConflicts() has already checked for the basic requirements for --force-sync
		log.log("\nWARNING: Overriding application configuration to use application defaults for skip_dir and skip_file due to --synch --single-directory --force-sync being used");
		bool forceSyncRiskAcceptance = appConfig.displayForceSyncRiskForAcceptance();
		log.vdebug("Returned --force-sync risk acceptance: ", forceSyncRiskAcceptance);
		// Action based on user response
		if (!forceSyncRiskAcceptance){
			// --force-sync risk not accepted
			return EXIT_FAILURE;
		} else {
			// --force-sync risk accepted
			// reset set config using function to use application defaults
			appConfig.resetSkipToDefaults();
			// update sync engine regex with reset defaults
			selectiveSync.setDirMask(appConfig.getValueString("skip_dir"));
			selectiveSync.setFileMask(appConfig.getValueString("skip_file"));	
		}
	}
	
	// Test if OneDrive service can be reached, exit if it cant be reached
	log.vdebug("Testing network to ensure network connectivity to Microsoft OneDrive Service");
	online = testInternetReachability(appConfig);
	
	// If we are not 'online' - how do we handle this situation?
	if (!online) {
		// We are unable to initialise the OneDrive API as we are not online
		if (!appConfig.getValueBool("monitor")) {
			// Running as --synchronize
			log.error("Unable to reach Microsoft OneDrive API service, unable to initialise application\n");
			return EXIT_FAILURE;
		} else {
			// Running as --monitor
			log.error("Unable to reach the Microsoft OneDrive API service at this point in time, re-trying network tests based on applicable intervals\n");
			if (!retryInternetConnectivtyTest(appConfig)) {
				return EXIT_FAILURE;
			}
		}
	}
	
	// This needs to be a separate 'if' statement, as, if this was an 'if-else' from above, if we were originally offline and using --monitor, we would never get to this point
	if (online) {
		// Check Application Version
		log.vlog("Checking Application Version ...");
		checkApplicationVersion();
		// Initialise the OneDrive API
		log.vlog("Attempting to initialise the OneDrive API ...");
		oneDriveApiInstance = new OneDriveApi(appConfig);
		appConfig.apiWasInitialised = oneDriveApiInstance.initialise();
		if (appConfig.apiWasInitialised) {
			log.vlog("The OneDrive API was initialised successfully");
			// Flag that we were able to initalise the API in the application config
			oneDriveApiInstance.debugOutputConfiguredAPIItems();
			
			// Need to configure the itemDB and syncEngineInstance for 'sync' and 'non-sync' operations
			log.vlog("Opening the item database ...");
			// Configure the Item Database
			itemDB = new ItemDatabase(runtimeDatabaseFile);
			// Was the database successfully initialised?
			if (!itemDB.isDatabaseInitialised()) {
				// no .. destroy class
				itemDB = null;
				// exit application
				return EXIT_FAILURE;
			}
			
			// Initialise the syncEngine
			syncEngineInstance = new SyncEngine(appConfig, itemDB, selectiveSync);
			appConfig.syncEngineWasInitialised = syncEngineInstance.initialise();
			
			// Are we not doing a --sync or a --monitor operation? Both of these will be false if they are not set
			if ((!appConfig.getValueBool("synchronize")) && (!appConfig.getValueBool("monitor"))) {
				
				// Are we performing some sort of 'no-sync' task?
				// - Are we obtaining the Office 365 Drive ID for a given Office 365 SharePoint Shared Library?
				// - Are we createing a shareable link for an existing file on OneDrive?
				// ... others ??
				
				if (appConfig.getValueString("sharepoint_library_name") != "") {
					syncEngineInstance.querySiteCollectionForDriveID(appConfig.getValueString("sharepoint_library_name"));
					// Exit application
					// Use exit scopes to shutdown API and cleanup data
					return EXIT_SUCCESS;
				}
				
			
				// If we get to this point, we have not performed a 'no-sync' task ..
				log.error("\n --sync or --monitor switches missing from your command line input. Please add one (not both) of these switches to your command line or use 'onedrive --help' for further assistance.\n");
				log.error("No OneDrive sync will be performed without one of these two arguments being present.\n");
				// Use exit scopes to shutdown API
				// invalidSyncExit = true;
				return EXIT_FAILURE;
			}
			// We do not need this instance, as the API was initialised, and individual instances are used during sync process
			oneDriveApiInstance.shutdown();
		} else {
			// API could not be initialised
			log.error("The OneDrive API could not be initialised");
			return EXIT_FAILURE;
		}
	}
	
	// Configure the sync direcory based on the runtimeSyncDirectory configured directory
	try {
		if (!exists(runtimeSyncDirectory)) {
			log.vdebug("runtimeSyncDirectory: Configured 'sync_dir' is missing locally. Creating: ", runtimeSyncDirectory);
			try {
				// Attempt to create the sync dir we have been configured with
				mkdirRecurse(runtimeSyncDirectory);
				// Configure the applicable permissions for the folder
				log.vdebug("Setting directory permissions for: ", runtimeSyncDirectory);
				runtimeSyncDirectory.setAttributes(appConfig.returnRequiredDirectoryPermisions());
			} catch (std.file.FileException e) {
				// Creating the sync directory failed
				log.error("ERROR: Unable to create local OneDrive 'sync_dir' - ", e.msg);
				// Use exit scopes to shutdown API
				return EXIT_FAILURE;
			}
		}
	} catch (std.file.FileException e) {
		// Creating the sync directory failed
		log.error("ERROR: Unable to test the existence of the configured OneDrive 'sync_dir' - ", e.msg);
		// Use exit scopes to shutdown API
		return EXIT_FAILURE;
	}
	
	// Change the working directory to the 'sync_dir' as configured
	log.log("All application operations will be performed in: ", runtimeSyncDirectory);
	chdir(runtimeSyncDirectory);
	
	// Do we need to validate the runtimeSyncDirectory to check for the presence of a '.nosync' file
	checkForNoMountScenario();
	
	// Set the default thread pool value - hard coded to 16
	defaultPoolThreads(to!int(appConfig.concurrentThreads));
	
	// Is the sync engine initiallised correctly?
	if (appConfig.syncEngineWasInitialised) {
		// Configure some initial variables
		string singleDirectoryPath;
		string localPath = ".";
		string remotePath = "/";
		
		// Are we doing a single directory operation (--single-directory) ?
		if (!appConfig.getValueString("single_directory").empty) {
			// Set singleDirectoryPath
			singleDirectoryPath = appConfig.getValueString("single_directory");
			
			// Ensure that this is a normalised relative path to runtimeSyncDirectory
			string normalisedRelativePath = replace(buildNormalizedPath(absolutePath(singleDirectoryPath)), buildNormalizedPath(absolutePath(runtimeSyncDirectory)), "." );
			
			// The user provided a directory to sync within the configured 'sync_dir' path
			// This also validates if the path being used exists online and/or does not have a 'case-insensitive match'
			syncEngineInstance.setSingleDirectoryScope(normalisedRelativePath);
			
			// Does the directory we want to sync actually exist locally?
			if (!exists(singleDirectoryPath)) {
				// The requested path to use with --single-directory does not exist locally within the configured 'sync_dir'
				log.logAndNotify("WARNING: The requested path for --single-directory does not exist locally. Creating requested path within ", runtimeSyncDirectory);
				// Make the required --single-directory path locally
				mkdirRecurse(singleDirectoryPath);
				// Configure the applicable permissions for the folder
				log.vdebug("Setting directory permissions for: ", singleDirectoryPath);
				singleDirectoryPath.setAttributes(appConfig.returnRequiredDirectoryPermisions());
			}
			
			// Update the paths that we use to perform the sync actions
			localPath = singleDirectoryPath;
			remotePath = singleDirectoryPath;
			
			// Display that we are syncing from a specific path due to --single-directory
			log.vlog("Syncing changes from this selected path: ", singleDirectoryPath);
		}

		// Are we doing a --sync operation? This includes doing any --single-directory operations
		if (appConfig.getValueBool("synchronize")) {
			// Did the user specify --upload-only?
			if (appConfig.getValueBool("upload_only")) {
				// Perform the --upload-only sync process
				performUploadOnlySyncProcess(localPath);
			}
			
			// Did the user specify --download-only?
			if (appConfig.getValueBool("download_only")) {
				// Only download data from OneDrive
				syncEngineInstance.syncOneDriveAccountToLocalDisk();
				// Perform the DB consistency check 
				// This will also delete any out-of-sync flagged items if configured to do so
				syncEngineInstance.performDatabaseConsistencyAndIntegrityCheck();
				// Do we cleanup local files?
				// - Deletes of data from online will already have been performed, but what we are now doing is searching the local filesystem
				//   for any new data locally, that usually would be uploaded to OneDrive, but instead, because of the options being
				//   used, will need to be deleted from the local filesystem
				if (appConfig.getValueBool("cleanup_local_files")) {
					// Perform the filesystem walk
					syncEngineInstance.scanLocalFilesystemPathForNewData(localPath);
				}
			}
			
			// If no use of --upload-only or --download-only
			if ((!appConfig.getValueBool("upload_only")) && (!appConfig.getValueBool("download_only"))) {
				// Perform the standard sync process
				performStandardSyncProcess(localPath);
			}
		
			// Detail the outcome of the sync process
			displaySyncOutcome();
		}
		
		// Are we doing a --monitor operation?
		if (appConfig.getValueBool("monitor")) {
			// What are the current values for the platform we are running on
			// Max number of open files /proc/sys/fs/file-max
			string maxOpenFiles = strip(readText("/proc/sys/fs/file-max"));
			// What is the currently configured maximum inotify watches that can be used
			// /proc/sys/fs/inotify/max_user_watches
			string maxInotifyWatches = strip(readText("/proc/sys/fs/inotify/max_user_watches"));
			
			// Start the monitor process
			log.log("OneDrive synchronisation interval (seconds): ", appConfig.getValueLong("monitor_interval"));
			log.vlog("Maximum allowed open files:                  ", maxOpenFiles);
			log.vlog("Maximum allowed inotify user watches:        ", maxInotifyWatches);
			
			// Configure the monitor class
			Monitor filesystemMonitor = new Monitor(appConfig, selectiveSync);
			
			// Delegated function for when inotify detects a new local directory has been created
			filesystemMonitor.onDirCreated = delegate(string path) {
				// Handle .folder creation if skip_dotfiles is enabled
				if ((appConfig.getValueBool("skip_dotfiles")) && (isDotFile(path))) {
					log.vlog("[M] Skipping watching local path - .folder found & --skip-dot-files enabled: ", path);
				} else {
					log.vlog("[M] Local directory created: ", path);
					try {
						syncEngineInstance.scanLocalFilesystemPathForNewData(path);
					} catch (CurlException e) {
						log.vlog("Offline, cannot create remote dir!");
					} catch(Exception e) {
						log.logAndNotify("Cannot create remote directory: ", e.msg);
					}
				}
			};
			
			// Delegated function for when inotify detects a local file has been changed
			filesystemMonitor.onFileChanged = delegate(string path) {
				log.vlog("[M] Local file changed: ", path);
				try {
					syncEngineInstance.scanLocalFilesystemPathForNewData(dirName(path));
				} catch (CurlException e) {
					log.vlog("Offline, cannot upload changed item!");
				} catch(Exception e) {
					log.logAndNotify("Cannot upload file changes/creation: ", e.msg);
				}
			};
			
			// Delegated function for when inotify detects a delete event
			filesystemMonitor.onDelete = delegate(string path) {
				log.log("Received inotify delete event from operating system .. attempting item deletion as requested");
				log.vlog("[M] Local item deleted: ", path);
				try {
					syncEngineInstance.deleteByPath(path);
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
			
			// Delegated function for when inotify detects a move event
			filesystemMonitor.onMove = delegate(string from, string to) {
				log.vlog("[M] Local item moved: ", from, " -> ", to);
				try {
					// Handle .folder -> folder if skip_dotfiles is enabled
					if ((appConfig.getValueBool("skip_dotfiles")) && (isDotFile(from))) {
						// .folder -> folder handling - has to be handled as a new folder
						syncEngineInstance.scanLocalFilesystemPathForNewData(to);
					} else {
						syncEngineInstance.uploadMoveItem(from, to);
					}
				} catch (CurlException e) {
					log.vlog("Offline, cannot move item!");
				} catch(Exception e) {
					log.logAndNotify("Cannot move item: ", e.msg);
				}
			};
			
			// Handle SIGINT and SIGTERM
			signal(SIGINT, &exitHandler);
			signal(SIGTERM, &exitHandler);
			
			// Initialise the filesystem monitor class
			try {
				log.log("Initialising filesystem inotify monitoring ...");
				filesystemMonitor.initialise();
				log.log("Performing initial syncronisation to ensure consistent local state ...");
			} catch (MonitorException e) {	
				// monitor class initialisation failed
				log.error("ERROR: ", e.msg);
				return EXIT_FAILURE;
			}
		
			// Filesystem monitor loop
			bool performMonitor = true;
			ulong monitorLoopFullCount = 0;
			ulong fullScanFrequencyLoopCount = 0;
			ulong monitorLogOutputLoopCount = 0;
			immutable auto checkOnlineInterval = dur!"seconds"(appConfig.getValueLong("monitor_interval"));
			immutable auto githubCheckInterval = dur!"seconds"(86400);
			immutable ulong fullScanFrequency = appConfig.getValueLong("monitor_fullscan_frequency");
			immutable ulong logOutputSupressionInterval = appConfig.getValueLong("monitor_log_frequency");
			MonoTime lastCheckTime = MonoTime.currTime();
			MonoTime lastGitHubCheckTime = MonoTime.currTime();
			string loopStartOutputMessage = "################################################## NEW LOOP ##################################################";
			string loopStopOutputMessage = "################################################ LOOP COMPLETE ###############################################";
			
			while (performMonitor) {
				
				// Do we need to validate the runtimeSyncDirectory to check for the presence of a '.nosync' file - the disk may have been ejected ..
				checkForNoMountScenario();
			
				try {
					// Process any inotify events
					filesystemMonitor.update(true);
				} catch (MonitorException e) {
					// Catch any exceptions thrown by inotify / monitor engine
					log.error("ERROR: The following inotify error was generated: ", e.msg);
				}
			
				// Check for notifications pushed from Microsoft to the webhook
				bool notificationReceived = false;
				
				// Check here for a webhook notification
				
				// Get the current time this loop is starting
				auto currentTime = MonoTime.currTime();
				
				// Do we perform a sync with OneDrive?
				if (notificationReceived || (currentTime - lastCheckTime > checkOnlineInterval) || (monitorLoopFullCount == 0)) {
					// Increment relevant counters
					monitorLoopFullCount++;
					fullScanFrequencyLoopCount++;
					monitorLogOutputLoopCount++;
					
					// Do we flag to perform a full scan of the online data?
					if (fullScanFrequencyLoopCount > fullScanFrequency) {
						// set full scan trigger for true up
						log.vdebug("Enabling Full Scan True Up (fullScanFrequencyLoopCount > fullScanFrequency), resetting fullScanFrequencyLoopCount = 1");
						fullScanFrequencyLoopCount = 1;
						appConfig.fullScanTrueUpRequired = true;
					} else {
						// unset full scan trigger for true up
						log.vdebug("Disabling Full Scan True Up");
						appConfig.fullScanTrueUpRequired = false;
					}
					
					log.vdebug(loopStartOutputMessage);
					log.vdebug("Total Run-Time Loop Number:     ", monitorLoopFullCount);
					log.vdebug("Full Scan Freqency Loop Number: ", fullScanFrequencyLoopCount);
					SysTime startFunctionProcessingTime = Clock.currTime();
					log.vdebug("Start Monitor Loop Time:              ", startFunctionProcessingTime);
					
					// Do we perform any monitor console logging output surpression?
					// 'monitor_log_frequency' controls how often, in a non-verbose application output mode, how often 
					// the full output of what is occuring is done. This is done to lessen the 'verbosity' of non-verbose 
					// logging, but only when running in --monitor
					if (monitorLogOutputLoopCount > logOutputSupressionInterval) {
						// unsurpress the logging output
						monitorLogOutputLoopCount = 1;
						log.vdebug("Unsuppressing log output");
						appConfig.surpressLoggingOutput = false;
					} else {
						// do we surpress the logging output to absolute minimal
						if (monitorLoopFullCount == 1) {
							// application startup with --monitor
							log.vdebug("Unsuppressing initial sync log output");
							appConfig.surpressLoggingOutput = false;
						} else {
							// only surpress if we are not doing --verbose or higher
							if (log.verbose == 0) {
								log.vdebug("Suppressing --monitor log output");
								appConfig.surpressLoggingOutput = true;
							} else {
								log.vdebug("Unsuppressing log output");
								appConfig.surpressLoggingOutput = false;
							}
						}
					}
					
					// How long has the application been running for?
					auto elapsedTime = Clock.currTime() - applicationStartTime;
					log.vdebug("Application run-time thus far: ", elapsedTime);
					
					// Need to re-validate that the client is still online for this loop
					if (testInternetReachability(appConfig)) {
						// Starting a sync 
						log.log("Starting a sync with Microsoft OneDrive");
						
						// Attempt to reset syncFailures
						syncEngineInstance.resetSyncFailures();
						
						// Did the user specify --upload-only?
						if (appConfig.getValueBool("upload_only")) {
							// Perform the --upload-only sync process
							performUploadOnlySyncProcess(localPath, filesystemMonitor);
						} else {
							// Perform the standard sync process
							performStandardSyncProcess(localPath, filesystemMonitor);
						}
						
						// Discard any inotify events generated as part of any sync operation
						filesystemMonitor.update(false);
						
						// Detail the outcome of the sync process
						displaySyncOutcome();
						
						if (appConfig.fullScanTrueUpRequired) {
							// Write WAL and SHM data to file for this loop
							log.vdebug("Merge contents of WAL and SHM files into main database file");
							itemDB.performVacuum();
						}
					} else {
						// Not online
						log.log("Microsoft OneDrive service is not reachable at this time. Will re-try on next loop attempt.");
					}
					
					// Output end of loop processing times
					SysTime endFunctionProcessingTime = Clock.currTime();
					log.vdebug("End Monitor Loop Time:                ", endFunctionProcessingTime);
					log.vdebug("Elapsed Monitor Loop Processing Time: ", (endFunctionProcessingTime - startFunctionProcessingTime));
					
					// Display memory details before cleanup
					if (displayMemoryUsage) log.displayMemoryUsagePreGC();
					// Perform Garbage Cleanup
					GC.collect();
					// Return free memory to the OS
					GC.minimize();
					// Display memory details after cleanup
					if (displayMemoryUsage) log.displayMemoryUsagePostGC();
					
					// Log that this loop is complete
					log.vdebug(loopStopOutputMessage);
					// performSync complete, set lastCheckTime to current time
					lastCheckTime = MonoTime.currTime();
					
					// Developer break via config option
					if (appConfig.getValueLong("monitor_max_loop") > 0) {
						// developer set option to limit --monitor loops
						if (monitorLoopFullCount == (appConfig.getValueLong("monitor_max_loop"))) {
							performMonitor = false;
							log.log("Exiting after ", monitorLoopFullCount, " loops due to developer set option");
						}
					}
				}
				// Sleep the monitor thread for 1 second, loop around and pick up any inotify changes
				Thread.sleep(dur!"seconds"(1));
			}
		}
	} else {
		// Exit application as the sync engine could not be initialised
		log.error("Application Sync Engine could not be initialised correctly");
		// Use exit scope
		return EXIT_FAILURE;
	}
	
	/**
	// Before we exit, if we are using --dry-run, clean up the local syste,
	if (appConfig.getValueBool("dry_run")) {
		// Cleanup any existing dry-run elements ... these should never be left hanging around
		cleanupDryRunDatabaseFiles(appConfig.databaseFilePathDryRun);
	}
	**/
		
	// Exit application using exit scope
	if (!syncEngineInstance.syncFailures) {
		return EXIT_SUCCESS;
	} else {
		return EXIT_FAILURE;
	}
}

void performUploadOnlySyncProcess(string localPath, Monitor filesystemMonitor = null) {
	// Perform the local database consistency check, picking up locally modified data and uploading this to OneDrive
	syncEngineInstance.performDatabaseConsistencyAndIntegrityCheck();
	if (appConfig.getValueBool("monitor")) {
		// Handle any inotify events whilst the DB was being scanned
		filesystemMonitor.update(true);
	}
	
	// Scan the configured 'sync_dir' for new data to upload
	syncEngineInstance.scanLocalFilesystemPathForNewData(localPath);
	if (appConfig.getValueBool("monitor")) {
		// Handle any new inotify events whilst the local filesystem was being scanned
		filesystemMonitor.update(true);
	}
}

void performStandardSyncProcess(string localPath, Monitor filesystemMonitor = null) {

	// If we are performing log supression, output this message so the user knows what is happening
	if (appConfig.surpressLoggingOutput) {
		log.log("Syncing changes from Microsoft OneDrive ...");
	}
	
	// Zero out these arrays
	syncEngineInstance.fileDownloadFailures = [];
	syncEngineInstance.fileUploadFailures = [];
	
	// Which way do we sync first?
	// OneDrive first then local changes (normal operational process that uses OneDrive as the source of truth)
	// Local First then OneDrive changes (alternate operation process to use local files as source of truth)
	if (appConfig.getValueBool("local_first")) {
		// Local data first 
		// Perform the local database consistency check, picking up locally modified data and uploading this to OneDrive
		syncEngineInstance.performDatabaseConsistencyAndIntegrityCheck();
		if (appConfig.getValueBool("monitor")) {
			// Handle any inotify events whilst the DB was being scanned
			filesystemMonitor.update(true);
		}
		
		// Scan the configured 'sync_dir' for new data to upload to OneDrive
		syncEngineInstance.scanLocalFilesystemPathForNewData(localPath);
		if (appConfig.getValueBool("monitor")) {
			// Handle any new inotify events whilst the local filesystem was being scanned
			filesystemMonitor.update(true);
		}
		
		// Download data from OneDrive last
		syncEngineInstance.syncOneDriveAccountToLocalDisk();
		if (appConfig.getValueBool("monitor")) {
		// Cancel out any inotify events from downloading data
			filesystemMonitor.update(false);
		}
	} else {
		// Normal sync
		// Download data from OneDrive first
		syncEngineInstance.syncOneDriveAccountToLocalDisk();
		if (appConfig.getValueBool("monitor")) {
			// Cancel out any inotify events from downloading data
			filesystemMonitor.update(false);
		}
		
		// Perform the local database consistency check, picking up locally modified data and uploading this to OneDrive
		syncEngineInstance.performDatabaseConsistencyAndIntegrityCheck();
		if (appConfig.getValueBool("monitor")) {
			// Handle any inotify events whilst the DB was being scanned
			filesystemMonitor.update(true);
		}
		
		// Scan the configured 'sync_dir' for new data to upload to OneDrive
		syncEngineInstance.scanLocalFilesystemPathForNewData(localPath);
		if (appConfig.getValueBool("monitor")) {
			// Handle any new inotify events whilst the local filesystem was being scanned
			filesystemMonitor.update(true);
		}
		
		// Make sure we sync any DB data to this point, but only if not in --monitor mode
		// In --monitor mode, this is handled within the 'loop', based on when the full scan true up is being performed
		if (!appConfig.getValueBool("monitor")) {
			itemDB.performVacuum();
		}
		
		// Perform the final true up scan to ensure we have correctly replicated the current online state locally
		if (!appConfig.surpressLoggingOutput) {
			log.log("Performing a final true-up scan of online data from Microsoft OneDrive");
		}
		// We pass in the 'appConfig.fullScanTrueUpRequired' value which then flags do we use the configured 'deltaLink'
		// If 'appConfig.fullScanTrueUpRequired' is true, we do not use the 'deltaLink' if we are in --monitor mode, thus forcing a full scan true up
		syncEngineInstance.syncOneDriveAccountToLocalDisk();
		if (appConfig.getValueBool("monitor")) {
			// Cancel out any inotify events from downloading data
			filesystemMonitor.update(false);
		}
	}
}

void displaySyncOutcome() {

	// Detail any download or upload transfer failures
	syncEngineInstance.displaySyncFailures();
	
	// Sync is either complete or partially complete
	if (!syncEngineInstance.syncFailures) {
		// No download or upload issues
		if (!appConfig.getValueBool("monitor")) writeln(); // Add an additional line break so that this is clear when using --sync
		log.log("Sync with Microsoft OneDrive is complete");
	} else {
		log.log("\nSync with Microsoft OneDrive has completed, however there are items that failed to sync.");
		// Due to how the OneDrive API works 'changes' such as add new files online, rename files online, delete files online are only sent once when using the /delta API call.
		// That we failed to download it, we need to track that, and then issue a --resync to download any of these failed files .. unfortunate, but there is no easy way here
		if (!syncEngineInstance.fileDownloadFailures.empty) {
			log.log("To fix any download failures you may need to perform a --resync to ensure this system is correctly synced with your Microsoft OneDrive Account");
		}
		if (!syncEngineInstance.fileUploadFailures.empty) {
			log.log("To fix any upload failures you may need to perform a --resync to ensure this system is correctly synced with your Microsoft OneDrive Account");
		}
		// So that from a logging perspective these messages are clear, add a line break in
		writeln();
	}
}

void processResyncDatabaseRemoval(string databaseFilePathToRemove) {
	log.vdebug("Testing if we have exclusive access to local database file");
	// Are we the only running instance? Test that we can open the database file path
	itemDB = new ItemDatabase(databaseFilePathToRemove);
	
	// did we successfully initialise the database class?
	if (!itemDB.isDatabaseInitialised()) {
		// no .. destroy class
		itemDB = null;
		// exit application - void function, force exit this way
		exit(-1);
	}
	
	// If we have exclusive access we will not have exited
	// destroy access test
	destroy(itemDB);
	// delete application sync state
	log.log("Deleting the saved application sync status ...");
	if (!appConfig.getValueBool("dry_run")) {
		safeRemove(databaseFilePathToRemove);
	} else {
		// --dry-run scenario ... technically we should not be making any local file changes .......
		log.log("DRY RUN: Not removing the saved application sync status");
	}
}

void cleanupDryRunDatabaseFiles(string dryRunDatabaseFile) {
	// Temp variables
	string dryRunShmFile = dryRunDatabaseFile ~ "-shm";
	string dryRunWalFile = dryRunDatabaseFile ~ "-wal";

	// If the dry run database exists, clean this up
	if (exists(dryRunDatabaseFile)) {
		// remove the existing file
		log.vdebug("DRY-RUN: Removing items-dryrun.sqlite3 as it still exists for some reason");
		safeRemove(dryRunDatabaseFile);
	}
	
	// silent cleanup of shm files if it exists
	if (exists(dryRunShmFile)) {
		// remove items-dryrun.sqlite3-shm
		log.vdebug("DRY-RUN: Removing items-dryrun.sqlite3-shm as it still exists for some reason");
		safeRemove(dryRunShmFile);
	}
	
	// silent cleanup of wal files if it exists
	if (exists(dryRunWalFile)) {
		// remove items-dryrun.sqlite3-wal
		log.vdebug("DRY-RUN: Removing items-dryrun.sqlite3-wal as it still exists for some reason");
		safeRemove(dryRunWalFile);
	}
}

void checkForNoMountScenario() {
	// If this is a 'mounted' folder, the 'mount point' should have this file to help the application stop any action to preserve data because the drive to mount is not currently mounted
	if (appConfig.getValueBool("check_nomount")) {
		// we were asked to check the mount point for the presence of a '.nosync' file
		if (exists(".nosync")) {
			log.logAndNotify("ERROR: .nosync file found in directory mount point. Aborting application startup process to safeguard data.");
			exit(EXIT_FAILURE);
		}
	}
}

// Getting around the @nogc problem
// https://p0nce.github.io/d-idioms/#Bypassing-@nogc
auto assumeNoGC(T) (T t) if (isFunctionPointer!T || isDelegate!T) {
	enum attrs = functionAttributes!T | FunctionAttribute.nogc;
	return cast(SetFunctionAttributes!(T, functionLinkage!T, attrs)) t;
}

// Catch CTRL-C
extern(C) nothrow @nogc @system void exitHandler(int value) {
	try {
		assumeNoGC ( () {
			log.log("Got termination signal, performing clean up");
			// was itemDb initialised?
			if (itemDB.isDatabaseInitialised()) {
				// Make sure the .wal file is incorporated into the main db before we exit
				log.log("Shutting down DB connection and merging temporary data");
				itemDB.performVacuum();
				destroy(itemDB);
			}
		})();
	} catch(Exception e) {}
	exit(0);
}