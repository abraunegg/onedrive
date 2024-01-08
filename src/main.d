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
Monitor filesystemMonitor;


int main(string[] cliArgs) {
	// Application Start Time - used during monitor loop to detail how long it has been running for
	auto applicationStartTime = Clock.currTime();
	// Disable buffering on stdout - this is needed so that when we are using plain write() it will go to the terminal without flushing
	stdout.setvbuf(0, _IONBF);
	
	// Required main function variables
	string genericHelpMessage = "Please use 'onedrive --help' for further assistance in regards to running this application.";
	// If the user passes in --confdir we need to store this as a variable
	string confdirOption = "";
	// running as what user?
	string runtimeUserName = "";
	// Are we online?
	bool online = false;
	// Does the operating environment have shell environment variables set
	bool shellEnvSet = false;
	// What is the runtime syncronisation directory that will be used
	// Typically this will be '~/OneDrive' .. however tilde expansion is unreliable
	string runtimeSyncDirectory = "";
	// Configure the runtime database file path. Typically this will be the default, but in a --dry-run scenario, we use a separate database file
	string runtimeDatabaseFile = "";
	// Verbosity Logging Count - this defines if verbose or debug logging is being used
	long verbosityCount = 0;
	// Application Logging Level
	bool verboseLogging = false;
	bool debugLogging = false;
	
	// DEVELOPER OPTIONS OUTPUT VARIABLES
	bool displayMemoryUsage = false;
	bool displaySyncOptions = false;
	
	// JC #2519
	bool monitorFailures = false;
	
	// Define 'exit' and 'failure' scopes
	scope(exit) {
		// Detail what scope was called
		addLogEntry("Exit scope was called", ["debug"]);
		// Perform exit tasks
		performStandardExitProcess("exitScope");
	}
	
	scope(failure) {
		// Detail what scope was called
		addLogEntry("Failure scope was called", ["debug"]);
		// Perform exit tasks
		performStandardExitProcess("failureScope");
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
			"verbose|v+", "Print more details, useful for debugging (repeat for extra debugging)", &verbosityCount,
			"version", "Print the version and exit", &printVersion
		);
		
		// Print help and exit
		if (cliOptions.helpWanted) {
			cliArgs ~= "--help";
		}
		// Print the version and exit
		if (printVersion) {
			//writeln("onedrive ", strip(import("version")));
			string tempVersion = "v2.5.0-alpha-4" ~ " GitHub version: " ~ strip(import("version"));
			writeln(tempVersion);
			exit(EXIT_SUCCESS);
		}
	} catch (GetOptException e) {
		// Option errors
		writeln(e.msg);
		writeln(genericHelpMessage);
		return EXIT_FAILURE;
	} catch (Exception e) {
		// Generic error
		writeln(e.msg);
		writeln(genericHelpMessage);
		return EXIT_FAILURE;
	}
	
	// Determine the application logging verbosity
	if (verbosityCount == 1) { verboseLogging = true;}
	if (verbosityCount >= 2) { debugLogging = true;}
	
	// Initialize the application logging class, as we know the application verbosity level
	// If we need to enable logging to a file, we can only do this once we know the application configuration which is done slightly later on
    initialiseLogging(verboseLogging, debugLogging);
	
	/**
	// most used
	addLogEntry("Basic 'info' message", ["info"]); .... or just use addLogEntry("Basic 'info' message");
	addLogEntry("Basic 'verbose' message", ["verbose"]);
	addLogEntry("Basic 'debug' message", ["debug"]);
	// GUI notify only
	addLogEntry("Basic 'notify' ONLY message and displayed in GUI if notifications are enabled", ["notify"]);
	// info and notify
	addLogEntry("Basic 'info and notify' message and displayed in GUI if notifications are enabled", ["info", "notify"]);
	// log file only
	addLogEntry("Information sent to the log file only, and only if logging to a file is enabled", ["logFileOnly"]);
	// Console only (session based upload|download)
	addLogEntry("Basic 'Console only with new line' message", ["consoleOnly"]);
	// Console only with no new line
	addLogEntry("Basic 'Console only with no new line' message", ["consoleOnlyNoNewLine"]);
	**/
	
	// Log application start time
	addLogEntry("Application started", ["debug"]);
	
	// Who are we running as? This will print the ProcessID, UID, GID and username the application is running as
	runtimeUserName = getUserName();
	
	// Print in debug the application version as soon as possible
	// addLogEntry("Application Version: " ~ strip(import("version")), ["debug"]);
	string tempVersion = "v2.5.0-alpha-4" ~ " GitHub version: " ~ strip(import("version"));
	addLogEntry("Application Version: " ~ tempVersion, ["debug"]);
	
	// How was this application started - what options were passed in
	addLogEntry("Passed in 'cliArgs': " ~ to!string(cliArgs), ["debug"]);
	addLogEntry("Note: --confdir and --verbose are not listed in 'cliArgs' array", ["debug"]);
	addLogEntry("Passed in --confdir if present: " ~ confdirOption, ["debug"]);
	addLogEntry("Passed in --verbose count if present: " ~ to!string(verbosityCount), ["debug"]);
	
	// Create a new AppConfig object with default values, 
	appConfig = new ApplicationConfig();
	// Update the default application configuration with the logging level so these can be used as a config option throughout the application
	appConfig.setConfigLoggingLevels(verboseLogging, debugLogging, verbosityCount);
	
	// Initialise the application configuration, utilising --confdir if it was passed in
	// Otherwise application defaults will be used to configure the application
	if (!appConfig.initialise(confdirOption)) {
		// There was an error loading the user specified application configuration
		// Error message already printed
		return EXIT_FAILURE;
	}
	
	// Update the current runtime application configuration (default or 'config' fileread-in options) from any passed in command line arguments
	appConfig.updateFromArgs(cliArgs);
	
	// As early as possible, now re-configure the logging class, given that we have read in any applicable 'config' file and updated the application running config from CLI input:
	// - Enable logging to a file if this is required
	// - Disable GUI notifications if this has been configured
	
	// Configure application logging to a log file only if this has been enabled
	// This is the earliest point that this can be done, as the client configuration has been read in, and any CLI arguments have been processed.
	// Either of those ('confif' file, CPU arguments) could be enabling logging, thus this is the earliest point at which this can be validated and enabled.
	// The buffered logging also ensures that all 'output' to this point is also captured and written out to the log file
	if (appConfig.getValueBool("enable_logging")) {
		// Calculate the application logging directory
		string calculatedLogDirPath = appConfig.calculateLogDirectory();
		string calculatedLogFilePath;
		// Initialise using the configured logging directory
		addLogEntry("Using the following path to store the runtime application log: " ~ calculatedLogDirPath, ["verbose"]);
		// Calculate the logfile name
		if (calculatedLogDirPath != appConfig.defaultHomePath) {
			// Log file is not going to the home directory
			string logfileName = runtimeUserName ~ ".onedrive.log";
			calculatedLogFilePath = buildNormalizedPath(buildPath(calculatedLogDirPath, logfileName));
		} else {
			// Log file is going to the users home directory
			calculatedLogFilePath = buildNormalizedPath(buildPath(calculatedLogDirPath, "onedrive.log"));
		}
		// Update the logging class to use 'calculatedLogFilePath' for the application log file now that this has been determined
		enableLogFileOutput(calculatedLogFilePath);
	}
	
	// Disable GUI Notifications if configured to do so
	// - This option is reverse action. If 'disable_notifications' is 'true', we need to send 'false'
	if (appConfig.getValueBool("disable_notifications")) {
		// disable_notifications is true, ensure GUI notifications is initialised with false so that NO GUI notification is sent
		disableGUINotifications(false);
		addLogEntry("Disabling GUI notifications as per user configuration");
	}
	
	// Perform a depreciated options check now that the config file (if present) and CLI options have all been parsed to advise the user that their option usage might change
	appConfig.checkDepreciatedOptions(cliArgs);
	
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
		// Any error will have been printed by the function itself, but we need a small delay here to allow the buffered logging to output any error
		return EXIT_FAILURE;
	}
	
	// Check for --dry-run operation
	// If this has been requested, we need to ensure that all actions are performed against the dry-run database copy, and, 
	// no actual action takes place - such as deleting files if deleted online, moving files if moved online or local, downloading new & changed files, uploading new & changed files
	if (appConfig.getValueBool("dry_run")) {
		// this is a --dry-run operation
		addLogEntry("DRY-RUN Configured. Output below shows what 'would' have occurred.");
		
		// Cleanup any existing dry-run elements ... these should never be left hanging around
		cleanupDryRunDatabaseFiles(appConfig.databaseFilePathDryRun);
		
		// Make a copy of the original items.sqlite3 for use as the dry run copy if it exists
		if (exists(appConfig.databaseFilePath)) {
			// In a --dry-run --resync scenario, we should not copy the existing database file
			if (!appConfig.getValueBool("resync")) {
				// Copy the existing DB file to the dry-run copy
				addLogEntry("DRY-RUN: Copying items.sqlite3 to items-dryrun.sqlite3 to use for dry run operations");
				copy(appConfig.databaseFilePath,appConfig.databaseFilePathDryRun);
			} else {
				// No database copy due to --resync
				addLogEntry("DRY-RUN: No database copy created for --dry-run due to --resync also being used");
			}
		}
		// update runtimeDatabaseFile now that we are using the dry run path
		runtimeDatabaseFile = appConfig.databaseFilePathDryRun;
	}
	
	// Handle --logout as separate item, do not 'resync' on a --logout
	if (appConfig.getValueBool("logout")) {
		addLogEntry("--logout requested", ["debug"]);
		addLogEntry("Deleting the saved authentication status ...");
		if (!appConfig.getValueBool("dry_run")) {
			safeRemove(appConfig.refreshTokenFilePath);
		} else {
			// --dry-run scenario ... technically we should not be making any local file changes .......
			addLogEntry("DRY RUN: Not removing the saved authentication status");
		}
		// Exit
		return EXIT_SUCCESS;
	}
	
	// Handle --reauth to re-authenticate the client
	if (appConfig.getValueBool("reauth")) {
		addLogEntry("--reauth requested", ["debug"]);
		addLogEntry("Deleting the saved authentication status ... re-authentication requested");
		if (!appConfig.getValueBool("dry_run")) {
			safeRemove(appConfig.refreshTokenFilePath);
		} else {
			// --dry-run scenario ... technically we should not be making any local file changes .......
			addLogEntry("DRY RUN: Not removing the saved authentication status");
		}
	}
	
	// --resync should be considered a 'last resort item' or if the application configuration has changed, where a resync is needed .. the user needs to 'accept' this warning to proceed
	// If --resync has not been used (bool value is false), check the application configuration for 'changes' that require a --resync to ensure that the data locally reflects the users requested configuration
	if (appConfig.getValueBool("resync")) {
		// what is the risk acceptance for --resync?
		bool resyncRiskAcceptance = appConfig.displayResyncRiskForAcceptance();
		addLogEntry("Returned --resync risk acceptance: " ~ resyncRiskAcceptance, ["debug"]);
		
		// Action based on user response
		if (!resyncRiskAcceptance){
			// --resync risk not accepted
			return EXIT_FAILURE;
		} else {
			addLogEntry("--resync issued and risk accepted", ["debug"]);
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
			addLogEntry();
			addLogEntry("An application configuration change has been detected where a --resync is required");
			addLogEntry();
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
		addLogEntry();
		addLogEntry("WARNING: Overriding application configuration to use application defaults for skip_dir and skip_file due to --sync --single-directory --force-sync being used");
		addLogEntry();
		bool forceSyncRiskAcceptance = appConfig.displayForceSyncRiskForAcceptance();
		addLogEntry("Returned --force-sync risk acceptance: " ~ forceSyncRiskAcceptance, ["debug"]);
		
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
	addLogEntry("Testing network to ensure network connectivity to Microsoft OneDrive Service", ["debug"]);
	online = testInternetReachability(appConfig);
	
	// If we are not 'online' - how do we handle this situation?
	if (!online) {
		// We are unable to initialise the OneDrive API as we are not online
		if (!appConfig.getValueBool("monitor")) {
			// Running as --synchronize
			addLogEntry();
			addLogEntry("ERROR: Unable to reach Microsoft OneDrive API service, unable to initialise application");
			addLogEntry();
			return EXIT_FAILURE;
		} else {
			// Running as --monitor
			addLogEntry();
			addLogEntry("Unable to reach the Microsoft OneDrive API service at this point in time, re-trying network tests based on applicable intervals");
			addLogEntry();
			if (!retryInternetConnectivtyTest(appConfig)) {
				return EXIT_FAILURE;
			}
		}
	}
	
	// This needs to be a separate 'if' statement, as, if this was an 'if-else' from above, if we were originally offline and using --monitor, we would never get to this point
	if (online) {
		// Check Application Version
		addLogEntry("Checking Application Version ...", ["verbose"]);
		checkApplicationVersion();
		
		// Initialise the OneDrive API
		addLogEntry("Attempting to initialise the OneDrive API ...", ["verbose"]);
		oneDriveApiInstance = new OneDriveApi(appConfig);
		appConfig.apiWasInitialised = oneDriveApiInstance.initialise();
		if (appConfig.apiWasInitialised) {
			addLogEntry("The OneDrive API was initialised successfully", ["verbose"]);
			
			// Flag that we were able to initalise the API in the application config
			oneDriveApiInstance.debugOutputConfiguredAPIItems();
			
			// Need to configure the itemDB and syncEngineInstance for 'sync' and 'non-sync' operations
			addLogEntry("Opening the item database ...", ["verbose"]);
			
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
				// - Are we displaying the sync satus?
				// - Are we getting the URL for a file online
				// - Are we listing who modified a file last online
				// - Are we createing a shareable link for an existing file on OneDrive?
				// - Are we just creating a directory online, without any sync being performed?
				// - Are we just deleting a directory online, without any sync being performed?
				// - Are we renaming or moving a directory?
				// - Are we displaying the quota information?
				// - Did we just authorise the client?
								
				// --get-sharepoint-drive-id - Get the SharePoint Library drive_id
				if (appConfig.getValueString("sharepoint_library_name") != "") {
					// Get the SharePoint Library drive_id
					syncEngineInstance.querySiteCollectionForDriveID(appConfig.getValueString("sharepoint_library_name"));
					// Exit application
					// Use exit scopes to shutdown API and cleanup data
					return EXIT_SUCCESS;
				}
				
				// --display-sync-status - Query the sync status
				if (appConfig.getValueBool("display_sync_status")) {
					// path to query variable
					string pathToQueryStatusOn;
					// What path do we query?
					if (!appConfig.getValueString("single_directory").empty) {
						pathToQueryStatusOn = "/" ~ appConfig.getValueString("single_directory");
					} else {
						pathToQueryStatusOn = "/";
					}
					// Query the sync status
					syncEngineInstance.queryOneDriveForSyncStatus(pathToQueryStatusOn);
					// Exit application
					// Use exit scopes to shutdown API and cleanup data
					return EXIT_SUCCESS;
				}
				
				// --get-file-link - Get the URL path for a synced file?
				if (appConfig.getValueString("get_file_link") != "") {
					// Query the OneDrive API for the file link
					syncEngineInstance.queryOneDriveForFileDetails(appConfig.getValueString("get_file_link"), runtimeSyncDirectory, "URL");
					// Exit application
					// Use exit scopes to shutdown API and cleanup data
					return EXIT_SUCCESS;
				}
				
				// --modified-by - Are we listing the modified-by details of a provided path?
				if (appConfig.getValueString("modified_by") != "") {
					// Query the OneDrive API for the last modified by details
					syncEngineInstance.queryOneDriveForFileDetails(appConfig.getValueString("modified_by"), runtimeSyncDirectory, "ModifiedBy");
					// Exit application
					// Use exit scopes to shutdown API and cleanup data
					return EXIT_SUCCESS;
				}
				
				// --create-share-link - Are we createing a shareable link for an existing file on OneDrive?
				if (appConfig.getValueString("create_share_link") != "") {
					// Query OneDrive for the file, and if valid, create a shareable link for the file
					
					// By default, the shareable link will be read-only. 
					// If the user adds: 
					//		--with-editing-perms 
					// this will create a writeable link
					syncEngineInstance.queryOneDriveForFileDetails(appConfig.getValueString("create_share_link"), runtimeSyncDirectory, "ShareableLink");
					// Exit application
					// Use exit scopes to shutdown API
					return EXIT_SUCCESS;
				}
				
				// --create-directory - Are we just creating a directory online, without any sync being performed?
				if ((appConfig.getValueString("create_directory") != "")) {
					// Handle the remote path creation and updating of the local database without performing a sync
					syncEngineInstance.createDirectoryOnline(appConfig.getValueString("create_directory"));
					// Exit application
					// Use exit scopes to shutdown API
					return EXIT_SUCCESS;
				}
				
				// --remove-directory - Are we just deleting a directory online, without any sync being performed?
				if ((appConfig.getValueString("remove_directory") != "")) {
					// Handle the remote path deletion without performing a sync
					syncEngineInstance.deleteByPath(appConfig.getValueString("remove_directory"));
					// Exit application
					// Use exit scopes to shutdown API
					return EXIT_SUCCESS;
				}
				
				// Are we renaming or moving a directory?
				// 	onedrive --source-directory 'path/as/source/' --destination-directory 'path/as/destination'
				if ((appConfig.getValueString("source_directory") != "") && (appConfig.getValueString("destination_directory") != "")) {
					// We are renaming or moving a directory
					syncEngineInstance.uploadMoveItem(appConfig.getValueString("source_directory"), appConfig.getValueString("destination_directory"));
					// Exit application
					// Use exit scopes to shutdown API
					return EXIT_SUCCESS;
				}
				
				// Are we displaying the quota information?
				if (appConfig.getValueBool("display_quota")) {
					// Query and respond with the quota details
					syncEngineInstance.queryOneDriveForQuotaDetails();
					// Exit application
					// Use exit scopes to shutdown API
					return EXIT_SUCCESS;
				}
				
				// If we get to this point, we have not performed a 'no-sync' task ..
				// Did we just authorise the client?
				if (appConfig.applicationAuthorizeResponseUri) {
					// Authorisation activity
					if (exists(appConfig.refreshTokenFilePath)) {
						// OneDrive refresh token exists
						addLogEntry();
						addLogEntry("The application has been successfully authorised, but no extra command options have been specified.");
						addLogEntry();
						addLogEntry(genericHelpMessage);
						addLogEntry();
						// Use exit scopes to shutdown API
						return EXIT_SUCCESS;
					} else {
						// We just authorised, but refresh_token does not exist .. probably an auth error?
						addLogEntry();
						addLogEntry("Your application's authorisation was unsuccessful. Please review your URI response entry, then attempt authorisation again with a new URI response.");
						addLogEntry();
						// Use exit scopes to shutdown API
						return EXIT_FAILURE;
					}
				} else {
					// No authorisation activity
					addLogEntry();
					addLogEntry("Your command line input is missing either the '--sync' or '--monitor' switches. Please include one (but not both) of these switches in your command line, or refer to 'onedrive --help' for additional guidance.");
					addLogEntry();
					addLogEntry("It is important to note that you must include one of these two arguments in your command line for the application to perform a synchronisation with Microsoft OneDrive");
					addLogEntry();
					// Use exit scopes to shutdown API
					// invalidSyncExit = true;
					return EXIT_FAILURE;
				}
			}
		} else {
			// API could not be initialised
			addLogEntry("The OneDrive API could not be initialised");
			return EXIT_FAILURE;
		}
	}
	
	// Configure the sync direcory based on the runtimeSyncDirectory configured directory
	addLogEntry("All application operations will be performed in the configured local 'sync_dir' directory: " ~ runtimeSyncDirectory, ["verbose"]);
	
	try {
		if (!exists(runtimeSyncDirectory)) {
			addLogEntry("runtimeSyncDirectory: Configured 'sync_dir' is missing locally. Creating: " ~ runtimeSyncDirectory, ["debug"]);
			
			try {
				// Attempt to create the sync dir we have been configured with
				mkdirRecurse(runtimeSyncDirectory);
				// Configure the applicable permissions for the folder
				addLogEntry("Setting directory permissions for: " ~ runtimeSyncDirectory, ["debug"]);
				runtimeSyncDirectory.setAttributes(appConfig.returnRequiredDirectoryPermisions());
			} catch (std.file.FileException e) {
				// Creating the sync directory failed
				addLogEntry("ERROR: Unable to create the configured local 'sync_dir' directory: " ~ e.msg);
				// Use exit scopes to shutdown API
				return EXIT_FAILURE;
			}
		}
	} catch (std.file.FileException e) {
		// Creating the sync directory failed
		addLogEntry("ERROR: Unable to test for the existence of the configured local 'sync_dir' directory: " ~ e.msg);
		// Use exit scopes to shutdown API
		return EXIT_FAILURE;
	}
	
	// Change the working directory to the 'sync_dir' as configured
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
		
		// Check if there are interrupted upload session(s)
		if (syncEngineInstance.checkForInterruptedSessionUploads) {
			// Need to re-process the session upload files to resume the failed session uploads
			addLogEntry("There are interrupted session uploads that need to be resumed ...");
			// Process the session upload files
			syncEngineInstance.processForInterruptedSessionUploads();
		}
		
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
				addLogEntry("WARNING: The requested path for --single-directory does not exist locally. Creating requested path within " ~ runtimeSyncDirectory, ["info", "notify"]);
				// Make the required --single-directory path locally
				mkdirRecurse(singleDirectoryPath);
				// Configure the applicable permissions for the folder
				addLogEntry("Setting directory permissions for: " ~ singleDirectoryPath, ["debug"]);
				singleDirectoryPath.setAttributes(appConfig.returnRequiredDirectoryPermisions());
			}
			
			// Update the paths that we use to perform the sync actions
			localPath = singleDirectoryPath;
			remotePath = singleDirectoryPath;
			
			// Display that we are syncing from a specific path due to --single-directory
			addLogEntry("Syncing changes from this selected path: " ~ singleDirectoryPath, ["verbose"]);
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
			addLogEntry("OneDrive synchronisation interval (seconds): " ~ to!string(appConfig.getValueLong("monitor_interval")));
			
			// If we are in a --download-only method of operation, the output of these is not required
			if (!appConfig.getValueBool("download_only")) {
				addLogEntry("Maximum allowed open files:                  " ~ maxOpenFiles, ["verbose"]);
				addLogEntry("Maximum allowed inotify user watches:        " ~ maxInotifyWatches, ["verbose"]);
			}
			
			// Configure the monitor class
			Tid workerTid;
			filesystemMonitor = new Monitor(appConfig, selectiveSync);
			
			// Delegated function for when inotify detects a new local directory has been created
			filesystemMonitor.onDirCreated = delegate(string path) {
				// Handle .folder creation if skip_dotfiles is enabled
				if ((appConfig.getValueBool("skip_dotfiles")) && (isDotFile(path))) {
					addLogEntry("[M] Skipping watching local path - .folder found & --skip-dot-files enabled: " ~ path, ["verbose"]);
				} else {
					addLogEntry("[M] Local directory created: " ~ path, ["verbose"]);
					try {
						syncEngineInstance.scanLocalFilesystemPathForNewData(path);
					} catch (CurlException e) {
						addLogEntry("Offline, cannot create remote dir: " ~ path, ["verbose"]);
					} catch(Exception e) {
						addLogEntry("Cannot create remote directory: " ~ e.msg, ["info", "notify"]);
					}
				}
			};
			
			// Delegated function for when inotify detects a local file has been changed
			filesystemMonitor.onFileChanged = delegate(string path) {
				// Handle a changed file
				addLogEntry("[M] Local file changed: " ~ path, ["verbose"]);
				try {
					syncEngineInstance.handleLocalFileTrigger(path);
				} catch (CurlException e) {
					addLogEntry("Offline, cannot upload changed item: " ~ path, ["verbose"]);
				} catch(Exception e) {
					addLogEntry("Cannot upload file changes/creation: " ~ e.msg, ["info", "notify"]);
				}
			};
			
			// Delegated function for when inotify detects a delete event
			filesystemMonitor.onDelete = delegate(string path) {
				addLogEntry("[M] Local item deleted: " ~ path, ["verbose"]);
				try {
					addLogEntry("The operating system sent a deletion notification. Trying to delete the item as requested");
					syncEngineInstance.deleteByPath(path);
				} catch (CurlException e) {
					addLogEntry("Offline, cannot delete item: " ~ path, ["verbose"]);
				} catch(SyncException e) {
					if (e.msg == "The item to delete is not in the local database") {
						addLogEntry("Item cannot be deleted from Microsoft OneDrive because it was not found in the local database", ["verbose"]);
					} else {
						addLogEntry("Cannot delete remote item: " ~ e.msg, ["info", "notify"]);
					}
				} catch(Exception e) {
					addLogEntry("Cannot delete remote item: " ~ e.msg, ["info", "notify"]);
				}
			};
			
			// Delegated function for when inotify detects a move event
			filesystemMonitor.onMove = delegate(string from, string to) {
				addLogEntry("[M] Local item moved: " ~ from ~ " -> " ~ to, ["verbose"]);
				try {
					// Handle .folder -> folder if skip_dotfiles is enabled
					if ((appConfig.getValueBool("skip_dotfiles")) && (isDotFile(from))) {
						// .folder -> folder handling - has to be handled as a new folder
						syncEngineInstance.scanLocalFilesystemPathForNewData(to);
					} else {
						syncEngineInstance.uploadMoveItem(from, to);
					}
				} catch (CurlException e) {
					addLogEntry("Offline, cannot move item !", ["verbose"]);
				} catch(Exception e) {
					addLogEntry("Cannot move item: " ~ e.msg, ["info", "notify"]);
				}
			};
			
			// Handle SIGINT and SIGTERM
			signal(SIGINT, &exitHandler);
			signal(SIGTERM, &exitHandler);
			
			// Initialise the local filesystem monitor class using inotify to monitor for local filesystem changes
			// If we are in a --download-only method of operation, we do not enable local filesystem monitoring
			if (!appConfig.getValueBool("download_only")) {
				// Not using --download-only
				try {
					addLogEntry("Initialising filesystem inotify monitoring ...");
					filesystemMonitor.initialise();
					workerTid = filesystemMonitor.watch();
					addLogEntry("Performing initial syncronisation to ensure consistent local state ...");
				} catch (MonitorException e) {	
					// monitor class initialisation failed
					addLogEntry("ERROR: " ~ e.msg);
					return EXIT_FAILURE;
				}
			}
		
			// Filesystem monitor loop variables
			// Immutables
			immutable auto checkOnlineInterval = dur!"seconds"(appConfig.getValueLong("monitor_interval"));
			immutable auto githubCheckInterval = dur!"seconds"(86400);
			immutable ulong fullScanFrequency = appConfig.getValueLong("monitor_fullscan_frequency");
			immutable ulong logOutputSupressionInterval = appConfig.getValueLong("monitor_log_frequency");
			immutable bool webhookEnabled = appConfig.getValueBool("webhook_enabled");
			immutable string loopStartOutputMessage = "################################################## NEW LOOP ##################################################";
			immutable string loopStopOutputMessage = "################################################ LOOP COMPLETE ###############################################";
			
			// Changables
			bool performMonitor = true;
			ulong monitorLoopFullCount = 0;
			ulong fullScanFrequencyLoopCount = 0;
			ulong monitorLogOutputLoopCount = 0;
			MonoTime lastCheckTime = MonoTime.currTime();
			MonoTime lastGitHubCheckTime = MonoTime.currTime();
			
			// Webhook Notification Handling
			bool notificationReceived = false;
			
			while (performMonitor) {
				// Do we need to validate the runtimeSyncDirectory to check for the presence of a '.nosync' file - the disk may have been ejected ..
				checkForNoMountScenario();
			
				// If we are in a --download-only method of operation, there is no filesystem monitoring, so no inotify events to check
				if (!appConfig.getValueBool("download_only")) {
					try {
						// Process any inotify events
						filesystemMonitor.update(true);
					} catch (MonitorException e) {
						// Catch any exceptions thrown by inotify / monitor engine
						addLogEntry("ERROR: The following inotify error was generated: " ~ e.msg);
					}
				}
			
				// Webhook Notification reset to false for this loop
				notificationReceived = false;
				
				// Check for notifications pushed from Microsoft to the webhook
				if (webhookEnabled) {
					// Create a subscription on the first run, or renew the subscription
					// on subsequent runs when it is about to expire.
					oneDriveApiInstance.createOrRenewSubscription();
				}
				
				// Get the current time this loop is starting
				auto currentTime = MonoTime.currTime();
				
				// Do we perform a sync with OneDrive?
				if ((currentTime - lastCheckTime >= checkOnlineInterval) || (monitorLoopFullCount == 0)) {
					// Increment relevant counters
					monitorLoopFullCount++;
					fullScanFrequencyLoopCount++;
					monitorLogOutputLoopCount++;
					
					// If full scan at a specific frequency enabled?
					if (fullScanFrequency > 0) {
						// Full Scan set for some 'frequency' - do we flag to perform a full scan of the online data?
						if (fullScanFrequencyLoopCount > fullScanFrequency) {
							// set full scan trigger for true up
							addLogEntry("Enabling Full Scan True Up (fullScanFrequencyLoopCount > fullScanFrequency), resetting fullScanFrequencyLoopCount = 1", ["debug"]);
							fullScanFrequencyLoopCount = 1;
							appConfig.fullScanTrueUpRequired = true;
						} else {
							// unset full scan trigger for true up
							addLogEntry("Disabling Full Scan True Up", ["debug"]);
							appConfig.fullScanTrueUpRequired = false;
						}
					} else {
						// No it is disabled - ensure this is false
						appConfig.fullScanTrueUpRequired = false;
					}
					
					// Loop Start
					addLogEntry(loopStartOutputMessage, ["debug"]);
					addLogEntry("Total Run-Time Loop Number:     " ~ to!string(monitorLoopFullCount), ["debug"]);
					addLogEntry("Full Scan Freqency Loop Number: " ~ to!string(fullScanFrequencyLoopCount), ["debug"]);
					SysTime startFunctionProcessingTime = Clock.currTime();
					addLogEntry("Start Monitor Loop Time:        " ~ to!string(startFunctionProcessingTime), ["debug"]);
					
					// Do we perform any monitor console logging output surpression?
					// 'monitor_log_frequency' controls how often, in a non-verbose application output mode, how often 
					// the full output of what is occuring is done. This is done to lessen the 'verbosity' of non-verbose 
					// logging, but only when running in --monitor
					if (monitorLogOutputLoopCount > logOutputSupressionInterval) {
						// unsurpress the logging output
						monitorLogOutputLoopCount = 1;
						addLogEntry("Unsuppressing initial sync log output", ["debug"]);
						appConfig.surpressLoggingOutput = false;
					} else {
						// do we surpress the logging output to absolute minimal
						if (monitorLoopFullCount == 1) {
							// application startup with --monitor
							addLogEntry("Unsuppressing initial sync log output", ["debug"]);
							appConfig.surpressLoggingOutput = false;
						} else {
							// only surpress if we are not doing --verbose or higher
							if (appConfig.verbosityCount == 0) {
								addLogEntry("Suppressing --monitor log output", ["debug"]);
								appConfig.surpressLoggingOutput = true;
							} else {
								addLogEntry("Unsuppressing log output", ["debug"]);
								appConfig.surpressLoggingOutput = false;
							}
						}
					}
					
					// How long has the application been running for?
					auto elapsedTime = Clock.currTime() - applicationStartTime;
					addLogEntry("Application run-time thus far: " ~ to!string(elapsedTime), ["debug"]);
					
					// Need to re-validate that the client is still online for this loop
					if (testInternetReachability(appConfig)) {
						// Starting a sync 
						addLogEntry("Starting a sync with Microsoft OneDrive");
						
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
						
						// Handle any new inotify events
						filesystemMonitor.update(true);
						
						// Detail the outcome of the sync process
						displaySyncOutcome();
						
						if (appConfig.fullScanTrueUpRequired) {
							// Write WAL and SHM data to file for this loop
							addLogEntry("Merge contents of WAL and SHM files into main database file", ["debug"]);
							itemDB.performVacuum();
						}
					} else {
						// Not online
						addLogEntry("Microsoft OneDrive service is not reachable at this time. Will re-try on next sync attempt.");
					}
					
					// Output end of loop processing times
					SysTime endFunctionProcessingTime = Clock.currTime();
					addLogEntry("End Monitor Loop Time:                " ~ to!string(endFunctionProcessingTime), ["debug"]);
					addLogEntry("Elapsed Monitor Loop Processing Time: " ~ to!string((endFunctionProcessingTime - startFunctionProcessingTime)), ["debug"]);
					
					// Display memory details before cleanup
					if (displayMemoryUsage) displayMemoryUsagePreGC();
					// Perform Garbage Cleanup
					GC.collect();
					// Return free memory to the OS
					GC.minimize();
					// Display memory details after cleanup
					if (displayMemoryUsage) displayMemoryUsagePostGC();
					
					// Log that this loop is complete
					addLogEntry(loopStopOutputMessage, ["debug"]);
					
					// performSync complete, set lastCheckTime to current time
					lastCheckTime = MonoTime.currTime();
					
					// Developer break via config option
					if (appConfig.getValueLong("monitor_max_loop") > 0) {
						// developer set option to limit --monitor loops
						if (monitorLoopFullCount == (appConfig.getValueLong("monitor_max_loop"))) {
							performMonitor = false;
							addLogEntry("Exiting after " ~ to!string(monitorLoopFullCount) ~ " loops due to developer set option");
						}
					}
				}

				if (performMonitor) {
					auto nextCheckTime = lastCheckTime + checkOnlineInterval;
					currentTime = MonoTime.currTime();
					auto sleepTime = nextCheckTime - currentTime;
					addLogEntry("Sleep for " ~ to!string(sleepTime), ["debug"]);

					if(filesystemMonitor.initialised || webhookEnabled) {
						if(filesystemMonitor.initialised) {
							// If local monitor is on
							// start the worker and wait for event
							if(!filesystemMonitor.isWorking()) {
								workerTid.send(1);
							}
						}

						if(webhookEnabled) {
							// if onedrive webhook is enabled
							// update sleep time based on renew interval
							Duration nextWebhookCheckDuration = oneDriveApiInstance.getNextExpirationCheckDuration();
							if (nextWebhookCheckDuration < sleepTime) {
								sleepTime = nextWebhookCheckDuration;
								addLogEntry("Update sleeping time to " ~ to!string(sleepTime), ["debug"]);
							}
							notificationReceived = false;
						}

						int res = 1;
						// Process incoming notifications if any.
						auto signalExists = receiveTimeout(sleepTime, 
							(int msg) {
								res = msg;
							},
							(ulong _) {
								notificationReceived = true;
							}
						);
						
						// Debug values
						addLogEntry("signalExists = " ~ to!string(signalExists), ["debug"]);
						addLogEntry("worker status = " ~ to!string(res), ["debug"]);
						addLogEntry("notificationReceived = " ~ to!string(notificationReceived), ["debug"]);
						
						// Empirical evidence shows that Microsoft often sends multiple
						// notifications for one single change, so we need a loop to exhaust
						// all signals that were queued up by the webhook. The notifications
						// do not contain any actual changes, and we will always rely do the
						// delta endpoint to sync to latest. Therefore, only one sync run is
						// good enough to catch up for multiple notifications.
						int signalCount = notificationReceived ? 1 : 0;
						for (;; signalCount++) {
							signalExists = receiveTimeout(dur!"seconds"(-1), (ulong _) {});
							if (signalExists) {
								notificationReceived = true;
							} else {
								if (notificationReceived) {
									addLogEntry("Received " ~ to!string(signalCount) ~ " refresh signals from the webhook");
									oneDriveWebhookCallback();
								}
								break;
							}
						}

						if(res == -1) {
							addLogEntry("ERROR: Monitor worker failed.");
							monitorFailures = true;
							performMonitor = false;
						}
					} else {
						// no hooks available, nothing to check
						Thread.sleep(sleepTime);
					}
				}
			}
		}
	} else {
		// Exit application as the sync engine could not be initialised
		addLogEntry("Application Sync Engine could not be initialised correctly");
		// Use exit scope
		return EXIT_FAILURE;
	}
	
	// Exit application using exit scope
	if (!syncEngineInstance.syncFailures && !monitorFailures) {
		return EXIT_SUCCESS;
	} else {
		return EXIT_FAILURE;
	}
}

void performStandardExitProcess(string scopeCaller = null) {
	// Who called this function
	if (!scopeCaller.empty) {
		addLogEntry("Running performStandardExitProcess due to: " ~ scopeCaller, ["debug"]);
	}
		
	// Shutdown the OneDrive API instance
	if (oneDriveApiInstance !is null) {
		addLogEntry("Shutdown OneDrive API instance", ["debug"]);
		oneDriveApiInstance.shutdown();
		object.destroy(oneDriveApiInstance);
	}
	
	// Shutdown the sync engine
	if (syncEngineInstance !is null) {
		addLogEntry("Shutdown Sync Engine instance", ["debug"]);
		object.destroy(syncEngineInstance);
	}
	
	// Shutdown the client side filtering objects
	if (selectiveSync !is null) {
		addLogEntry("Shutdown Client Side Filtering instance", ["debug"]);
		selectiveSync.shutdown();
		object.destroy(selectiveSync);
	}
	
	// Shutdown the application configuration objects
	if (appConfig !is null) {
		addLogEntry("Shutdown Application Configuration instance", ["debug"]);
		// Cleanup any existing dry-run elements ... these should never be left hanging around
		cleanupDryRunDatabaseFiles(appConfig.databaseFilePathDryRun);
		object.destroy(appConfig);
	}
	
	// Shutdown any local filesystem monitoring
	if (filesystemMonitor !is null) {
		addLogEntry("Shutdown Filesystem Monitoring instance", ["debug"]);
		filesystemMonitor.shutdown();
		object.destroy(filesystemMonitor);
	}
	
	// Shutdown the database
	if (itemDB !is null) {
		addLogEntry("Shutdown Database instance", ["debug"]);
		// Make sure the .wal file is incorporated into the main db before we exit
		if (itemDB.isDatabaseInitialised()) {
			itemDB.performVacuum();
		}
		object.destroy(itemDB);
	}
	
	// Set all objects to null
	if (scopeCaller == "failureScope") {
		// Set these to be null due to failure scope - prevent 'ERROR: Unable to perform a database vacuum: out of memory' when the exit scope is then called
		addLogEntry("Setting ALL Class Objects to null due to failure scope", ["debug"]);
		itemDB = null;
		appConfig = null;
		oneDriveApiInstance = null;
		selectiveSync = null;
		syncEngineInstance = null;
	} else {
		addLogEntry("Application exit", ["debug"]);
		addLogEntry("#######################################################################################################################################", ["logFileOnly"]);
		// Sleep to allow any final logging output to be printed - this is needed as we are using buffered logging output
		Thread.sleep(dur!("msecs")(500));
		// Destroy the shared logging buffer
		object.destroy(logBuffer);
	}
}

void oneDriveWebhookCallback() {
	// If we are in a --download-only method of operation, there is no filesystem monitoring, so no inotify events to check
	if (!appConfig.getValueBool("download_only")) {
		try {
			// Process any inotify events
			filesystemMonitor.update(true);
		} catch (MonitorException e) {
			// Catch any exceptions thrown by inotify / monitor engine
			addLogEntry("ERROR: The following inotify error was generated: " ~ e.msg);
		}
	}

	// Download data from OneDrive last
	syncEngineInstance.syncOneDriveAccountToLocalDisk();
	if (appConfig.getValueBool("monitor")) {
	// Handle any new inotify events
		filesystemMonitor.update(true);
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
		addLogEntry("Syncing changes from Microsoft OneDrive ...");
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
			
		// Is --download-only NOT configured?
		if (!appConfig.getValueBool("download_only")) {
		
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
				addLogEntry("Performing a last examination of the most recent online data within Microsoft OneDrive to complete the reconciliation process");
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
}

void displaySyncOutcome() {

	// Detail any download or upload transfer failures
	syncEngineInstance.displaySyncFailures();
	
	// Sync is either complete or partially complete
	if (!syncEngineInstance.syncFailures) {
		// No download or upload issues
		if (!appConfig.getValueBool("monitor")) addLogEntry(); // Add an additional line break so that this is clear when using --sync
		addLogEntry("Sync with Microsoft OneDrive is complete");
	} else {
		addLogEntry();
		addLogEntry("Sync with Microsoft OneDrive has completed, however there are items that failed to sync.");
		// Due to how the OneDrive API works 'changes' such as add new files online, rename files online, delete files online are only sent once when using the /delta API call.
		// That we failed to download it, we need to track that, and then issue a --resync to download any of these failed files .. unfortunate, but there is no easy way here
		if (!syncEngineInstance.fileDownloadFailures.empty) {
			addLogEntry("To fix any download failures you may need to perform a --resync to ensure this system is correctly synced with your Microsoft OneDrive Account");
		}
		if (!syncEngineInstance.fileUploadFailures.empty) {
			addLogEntry("To fix any upload failures you may need to perform a --resync to ensure this system is correctly synced with your Microsoft OneDrive Account");
		}
		// So that from a logging perspective these messages are clear, add a line break in
		addLogEntry();
	}
}

void processResyncDatabaseRemoval(string databaseFilePathToRemove) {
	addLogEntry("Testing if we have exclusive access to local database file", ["debug"]);
	
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
	addLogEntry("Deleting the saved application sync status ...");
	if (!appConfig.getValueBool("dry_run")) {
		safeRemove(databaseFilePathToRemove);
	} else {
		// --dry-run scenario ... technically we should not be making any local file changes .......
		addLogEntry("DRY RUN: Not removing the saved application sync status");
	}
}

void cleanupDryRunDatabaseFiles(string dryRunDatabaseFile) {
	// Temp variables
	string dryRunShmFile = dryRunDatabaseFile ~ "-shm";
	string dryRunWalFile = dryRunDatabaseFile ~ "-wal";

	// If the dry run database exists, clean this up
	if (exists(dryRunDatabaseFile)) {
		// remove the existing file
		addLogEntry("DRY-RUN: Removing items-dryrun.sqlite3 as it still exists for some reason", ["debug"]);
		safeRemove(dryRunDatabaseFile);
	}
	
	// silent cleanup of shm files if it exists
	if (exists(dryRunShmFile)) {
		// remove items-dryrun.sqlite3-shm
		addLogEntry("DRY-RUN: Removing items-dryrun.sqlite3-shm as it still exists for some reason", ["debug"]);
		safeRemove(dryRunShmFile);
	}
	
	// silent cleanup of wal files if it exists
	if (exists(dryRunWalFile)) {
		// remove items-dryrun.sqlite3-wal
		addLogEntry("DRY-RUN: Removing items-dryrun.sqlite3-wal as it still exists for some reason", ["debug"]);
		safeRemove(dryRunWalFile);
	}
}

void checkForNoMountScenario() {
	// If this is a 'mounted' folder, the 'mount point' should have this file to help the application stop any action to preserve data because the drive to mount is not currently mounted
	if (appConfig.getValueBool("check_nomount")) {
		// we were asked to check the mount point for the presence of a '.nosync' file
		if (exists(".nosync")) {
			addLogEntry("ERROR: .nosync file found in directory mount point. Aborting application startup process to safeguard data.", ["info", "notify"]);
			Thread.sleep(dur!("msecs")(500));
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
			addLogEntry("Got termination signal, performing clean up");
			// Wait for all parallel jobs that depend on the database to complete
			addLogEntry("Waiting for any existing upload|download process to complete");
			taskPool.finish(true);
			// Was itemDb initialised?
			if (itemDB.isDatabaseInitialised()) {
				// Make sure the .wal file is incorporated into the main db before we exit
				addLogEntry("Shutting down DB connection and merging temporary data");
				itemDB.performVacuum();
				object.destroy(itemDB);
			}
			performStandardExitProcess();
		})();
	} catch(Exception e) {}
	exit(0);
}