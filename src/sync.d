// What is this module called?
module syncEngine;

// What does this module require to function?
import core.memory;
import core.stdc.stdlib: EXIT_SUCCESS, EXIT_FAILURE, exit;
import core.thread;
import core.time;
import std.algorithm;
import std.array;
import std.concurrency;
import std.container.rbtree;
import std.conv;
import std.datetime;
import std.encoding;
import std.exception;
import std.file;
import std.json;
import std.parallelism;
import std.path;
import std.range;
import std.regex;
import std.stdio;
import std.string;
import std.uni;
import std.uri;
import std.utf;
import std.math;

// What other modules that we have created do we need to import?
import config;
import log;
import util;
import onedrive;
import itemdb;
import clientSideFiltering;

class JsonResponseException: Exception {
	@safe pure this(string inputMessage) {
		string msg = format(inputMessage);
		super(msg);
	}	
}

class PosixException: Exception {
	@safe pure this(string localTargetName, string remoteTargetName) {
		string msg = format("POSIX 'case-insensitive match' between '%s' (local) and '%s' (online) which violates the Microsoft OneDrive API namespace convention", localTargetName, remoteTargetName);
		super(msg);
	}	
}

class AccountDetailsException: Exception {
	@safe pure this() {
		string msg = format("Unable to query OneDrive API to obtain required account details");
		super(msg);
	}	
}

class SyncException: Exception {
    @nogc @safe pure nothrow this(string msg, string file = __FILE__, size_t line = __LINE__) {
        super(msg, file, line);
    }
}

struct DriveDetailsCache {
	// - driveId is the drive for the operations were items need to be stored
	// - quotaRestricted details a bool value as to if that drive is restricting our ability to understand if there is space available. Some 'Business' and 'SharePoint' restrict, and most (if not all) shared folders it cant be determined if there is free space
	// - quotaAvailable is a ulong value that stores the value of what the current free space is available online
	string driveId;
	bool quotaRestricted;
	bool quotaAvailable;
	ulong quotaRemaining;
}

struct DeltaLinkDetails {
	string driveId;
	string itemId;
	string latestDeltaLink;
}

struct DatabaseItemsToDeleteOnline {
	Item dbItem;
	string localFilePath;
}

class SyncEngine {
	// Class Variables
	ApplicationConfig appConfig;
	ItemDatabase itemDB;
	ClientSideFiltering selectiveSync;
	
	// Array of directory databaseItem.id to skip while applying the changes.
	// These are the 'parent path' id's that are being excluded, so if the parent id is in here, the child needs to be skipped as well
	RedBlackTree!string skippedItems = redBlackTree!string();
	// Array of databaseItem.id to delete after the changes have been downloaded
	string[2][] idsToDelete;
	// Array of JSON items which are files or directories that are not 'root', skipped or to be deleted, that need to be processed
	JSONValue[] jsonItemsToProcess;
	// Array of JSON items which are files that are not 'root', skipped or to be deleted, that need to be downloaded
	JSONValue[] fileJSONItemsToDownload;
	// Array of paths that failed to download
	string[] fileDownloadFailures;
	// Associative array mapping of all OneDrive driveId's that have been seen, mapped with DriveDetailsCache data for reference
	DriveDetailsCache[string] onlineDriveDetails;
	// List of items we fake created when using --dry-run
	string[2][] idsFaked;
	// List of paths we fake deleted when using --dry-run
	string[] pathFakeDeletedArray;
	// Array of database Parent Item ID, Item ID & Local Path where the content has changed and needs to be uploaded
	string[3][] databaseItemsWhereContentHasChanged;
	// Array of local file paths that need to be uploaded as new itemts to OneDrive
	string[] newLocalFilesToUploadToOneDrive;
	// Array of local file paths that failed to be uploaded to OneDrive
	string[] fileUploadFailures;
	// List of path names changed online, but not changed locally when using --dry-run
	string[] pathsRenamed;
	// List of paths that were a POSIX case-insensitive match, thus could not be created online
	string[] posixViolationPaths;
	// List of local paths, that, when using the OneDrive Business Shared Folders feature, then disabling it, folder still exists locally and online
	// This list of local paths need to be skipped
	string[] businessSharedFoldersOnlineToSkip;
	// List of interrupted uploads session files that need to be resumed
	string[] interruptedUploadsSessionFiles;
	// List of validated interrupted uploads session JSON items to resume
	JSONValue[] jsonItemsToResumeUpload;
	// This list of local paths that need to be created online
	string[] pathsToCreateOnline;
	// Array of items from the database that have been deleted locally, that needs to be deleted online
	DatabaseItemsToDeleteOnline[] databaseItemsToDeleteOnline;
	// Array of parentId's that have been skipped via 'sync_list'
	string[] syncListSkippedParentIds;
		
	// Flag that there were upload or download failures listed
	bool syncFailures = false;
	// Is sync_list configured
	bool syncListConfigured = false;
	// Was --dry-run used?
	bool dryRun = false;
	// Was --upload-only used?
	bool uploadOnly = false;
	// Was --remove-source-files used?
	// Flag to set whether the local file should be deleted once it is successfully uploaded to OneDrive
	bool localDeleteAfterUpload = false;
	
	// Do we configure to disable the download validation routine due to --disable-download-validation
	// We will always validate our downloads
	// However, when downloading files from SharePoint, the OneDrive API will not advise the correct file size 
	// which means that the application thinks the file download has failed as the size is different / hash is different
	// See: https://github.com/abraunegg/onedrive/discussions/1667
    bool disableDownloadValidation = false;
	
	// Do we configure to disable the upload validation routine due to --disable-upload-validation
	// We will always validate our uploads
	// However, when uploading a file that can contain metadata SharePoint will associate some 
	// metadata from the library the file is uploaded to directly in the file which breaks this validation. 
	// See: https://github.com/abraunegg/onedrive/issues/205
	// See: https://github.com/OneDrive/onedrive-api-docs/issues/935
	bool disableUploadValidation = false;
	
	// Do we perform a local cleanup of files that are 'extra' on the local file system, when using --download-only
	bool cleanupLocalFiles = false;
	// Are we performing a --single-directory sync ?
	bool singleDirectoryScope = false;
	string singleDirectoryScopeDriveId;
	string singleDirectoryScopeItemId;
	// Is National Cloud Deployments configured ?
	bool nationalCloudDeployment = false;
	// Do we configure not to perform a remote file delete if --upload-only & --no-remote-delete configured
	bool noRemoteDelete = false;
	// Is bypass_data_preservation set via config file
	// Local data loss MAY occur in this scenario
	bool bypassDataPreservation = false;
	// Maximum file size upload
	//  https://support.microsoft.com/en-us/office/invalid-file-names-and-file-types-in-onedrive-and-sharepoint-64883a5d-228e-48f5-b3d2-eb39e07630fa?ui=en-us&rs=en-us&ad=us
	//	July 2020, maximum file size for all accounts is 100GB
	//  January 2021, maximum file size for all accounts is 250GB
	ulong maxUploadFileSize = 268435456000; // 250GB
	// Threshold after which files will be uploaded using an upload session
	ulong sessionThresholdFileSize = 4 * 2^^20; // 4 MiB
	// File size limit for file operations that the user has configured
	ulong fileSizeLimit;
	// Total data to upload
	ulong totalDataToUpload;
	// How many items have been processed for the active operation
	ulong processedCount;
	// Are we creating a simulated /delta response? This is critically important in terms of how we 'update' the database
	bool generateSimulatedDeltaResponse = false;
	// Store the latest DeltaLink
	string latestDeltaLink;
	// Struct of containing the deltaLink details
	DeltaLinkDetails deltaLinkCache;
	// Array of driveId and deltaLink for use when performing the last examination of the most recent online data
	alias DeltaLinkInfo = string[string];
	DeltaLinkInfo deltaLinkInfo;
	// Flag to denote data cleanup pass when using --download-only --cleanup-local-files
	bool cleanupDataPass = false;
	// Create the specific task pool to process items in parallel
	TaskPool processPool;
	
	// Shared Folder Flags for 'sync_list' processing
	bool sharedFolderDeltaGeneration = false;
	string currentSharedFolderName = "";
			
	// Configure this class instance
	this(ApplicationConfig appConfig, ItemDatabase itemDB, ClientSideFiltering selectiveSync) {
	
		// Create the specific task pool to process items in parallel
		processPool = new TaskPool(to!int(appConfig.getValueLong("threads")));
		addLogEntry("Initialised TaskPool worker with threads: " ~ to!string(processPool.size), ["debug"]);
		
		// Configure the class variable to consume the application configuration
		this.appConfig = appConfig;
		// Configure the class variable to consume the database configuration
		this.itemDB = itemDB;
		// Configure the class variable to consume the selective sync (skip_dir, skip_file and sync_list) configuration
		this.selectiveSync = selectiveSync;
		
		// Configure the dryRun flag to capture if --dry-run was used
		// Application startup already flagged we are also in a --dry-run state, so no need to output anything else here
		this.dryRun = appConfig.getValueBool("dry_run");
		
		// Configure file size limit
		if (appConfig.getValueLong("skip_size") != 0) {
			fileSizeLimit = appConfig.getValueLong("skip_size") * 2^^20;
			fileSizeLimit = (fileSizeLimit == 0) ? ulong.max : fileSizeLimit;
		}
		
		// Is there a sync_list file present?
		if (exists(appConfig.syncListFilePath)) this.syncListConfigured = true;
		
		// Configure the uploadOnly flag to capture if --upload-only was used
		if (appConfig.getValueBool("upload_only")) {
			addLogEntry("Configuring uploadOnly flag to TRUE as --upload-only passed in or configured", ["debug"]);
			this.uploadOnly = true;
		}
		
		// Configure the localDeleteAfterUpload flag
		if (appConfig.getValueBool("remove_source_files")) {
			addLogEntry("Configuring localDeleteAfterUpload flag to TRUE as --remove-source-files passed in or configured", ["debug"]);
			this.localDeleteAfterUpload = true;
		}
		
		// Configure the disableDownloadValidation flag
		if (appConfig.getValueBool("disable_download_validation")) {
			addLogEntry("Configuring disableDownloadValidation flag to TRUE as --disable-download-validation passed in or configured", ["debug"]);
			this.disableDownloadValidation = true;
		}
		
		// Configure the disableUploadValidation flag
		if (appConfig.getValueBool("disable_upload_validation")) {
			addLogEntry("Configuring disableUploadValidation flag to TRUE as --disable-upload-validation passed in or configured", ["debug"]);
			this.disableUploadValidation = true;
		}
		
		// Do we configure to clean up local files if using --download-only ?
		if ((appConfig.getValueBool("download_only")) && (appConfig.getValueBool("cleanup_local_files"))) {
			// --download-only and --cleanup-local-files were passed in
			addLogEntry();
			addLogEntry("WARNING: Application has been configured to cleanup local files that are not present online.");
			addLogEntry("WARNING: Local data loss MAY occur in this scenario if you are expecting data to remain archived locally.");
			addLogEntry();
			// Set the flag
			this.cleanupLocalFiles = true;
		}
		
		// Do we configure to NOT perform a remote delete if --upload-only & --no-remote-delete configured ?
		if ((appConfig.getValueBool("upload_only")) && (appConfig.getValueBool("no_remote_delete"))) {
			// --upload-only and --no-remote-delete were passed in
			addLogEntry("WARNING: Application has been configured NOT to cleanup remote files that are deleted locally.");
			// Set the flag
			this.noRemoteDelete = true;
		}
		
		// Are we configured to use a National Cloud Deployment?
		if (appConfig.getValueString("azure_ad_endpoint") != "") {
			// value is configured, is it a valid value?
			if ((appConfig.getValueString("azure_ad_endpoint") == "USL4") || (appConfig.getValueString("azure_ad_endpoint") == "USL5") || (appConfig.getValueString("azure_ad_endpoint") == "DE") || (appConfig.getValueString("azure_ad_endpoint") == "CN")) {
				// valid entries to flag we are using a National Cloud Deployment
				// National Cloud Deployments do not support /delta as a query
				// https://docs.microsoft.com/en-us/graph/deployments#supported-features
				// Flag that we have a valid National Cloud Deployment that cannot use /delta queries
				this.nationalCloudDeployment = true;
				// Reverse set 'force_children_scan' for completeness
				appConfig.setValueBool("force_children_scan", true);
			}
		}
		
		// Are we forcing to use /children scan instead of /delta to simulate National Cloud Deployment use of /children?
		if (appConfig.getValueBool("force_children_scan")) {
			addLogEntry("Forcing client to use /children API call rather than /delta API to retrieve objects from the OneDrive API");
			this.nationalCloudDeployment = true;
		}
		
		// Are we forcing the client to bypass any data preservation techniques to NOT rename any local files if there is a conflict?
		// The enabling of this function could lead to data loss
		if (appConfig.getValueBool("bypass_data_preservation")) {
			addLogEntry("WARNING: Application has been configured to bypass local data preservation in the event of file conflict.");
			addLogEntry("WARNING: Local data loss MAY occur in this scenario.");
			this.bypassDataPreservation = true;
		}
		
		// Did the user configure a specific rate limit for the application?
		if (appConfig.getValueLong("rate_limit") > 0) {
			// User configured rate limit
			addLogEntry("User Configured Rate Limit: " ~ to!string(appConfig.getValueLong("rate_limit")));
			
			// If user provided rate limit is < 131072, flag that this is too low, setting to the recommended minimum of 131072
			if (appConfig.getValueLong("rate_limit") < 131072) {
				// user provided limit too low
				addLogEntry("WARNING: User configured rate limit too low for normal application processing and preventing application timeouts. Overriding to recommended minimum of 131072 (128KB/s)");
				appConfig.setValueLong("rate_limit", 131072);
			}
		}
		
		// Did the user downgrade all HTTP operations to force HTTP 1.1
		if (appConfig.getValueBool("force_http_11")) {
			// User is forcing downgrade to curl to use HTTP 1.1 for all operations
			addLogEntry("Downgrading all HTTP operations to HTTP/1.1 due to user configuration", ["verbose"]);
		} else {
			// Use curl defaults
			addLogEntry("Using Curl defaults for HTTP operational protocol version (potentially HTTP/2)", ["debug"]);
		}
	}
	
	// Initialise the Sync Engine class
	bool initialise() {
		// Control whether the worker threads are daemon threads. A daemon thread is automatically terminated when all non-daemon threads have terminated.
		processPool.isDaemon(true); // daemon thread
		
		// Create a new instance of the OneDrive API
		OneDriveApi oneDriveApiInstance;
		oneDriveApiInstance = new OneDriveApi(appConfig);
		// Exit scope - release curl engine back to pool
		scope(exit) {
			oneDriveApiInstance.releaseCurlEngine();
			// Free object and memory
			oneDriveApiInstance = null;
		}
		
		// Can the API be initialised successfully?
		if (oneDriveApiInstance.initialise()) {
			// Get the relevant default drive details
			try {
				getDefaultDriveDetails();
			} catch (AccountDetailsException exception) {
				// details could not be queried
				addLogEntry(exception.msg);
				// Must force exit here, allow logging to be done
				forceExit();
			}
			
			// Get the relevant default root details
			try {
				getDefaultRootDetails();
			} catch (AccountDetailsException exception) {
				// details could not be queried
				addLogEntry(exception.msg);
				// Must force exit here, allow logging to be done
				forceExit();
			}
			
			// Display details
			try {
				displaySyncEngineDetails();
			} catch (AccountDetailsException exception) {
				// Details could not be queried
				addLogEntry(exception.msg);
				// Must force exit here, allow logging to be done
				forceExit();
			}
		} else {
			// API could not be initialised
			addLogEntry("OneDrive API could not be initialised with previously used details");
			// Must force exit here, allow logging to be done
			forceExit();
		}
		
		// API was initialised
		addLogEntry("Sync Engine Initialised with new Onedrive API instance", ["verbose"]);
		return true;
	}
	
	// Shutdown the sync engine, wait for anything in processPool to complete
	void shutdown() {
		addLogEntry("SyncEngine: Waiting for all internal threads to complete", ["debug"]);
		shutdownProcessPool();
	}
	
	// Shut down all running tasks that are potentially running in parallel
	void shutdownProcessPool() {
		// TaskPool needs specific shutdown based on compiler version otherwise this causes a segfault
		if (processPool.size > 0) {
			// TaskPool is still configured for 'thread' size
			// Normal TaskPool shutdown process
			addLogEntry("Shutting down processPool in a thread blocking manner", ["debug"]);
			// All worker threads are daemon threads which are automatically terminated when all non-daemon threads have terminated.
			processPool.finish(true); // If blocking argument is true, wait for all worker threads to terminate before returning.
		}
	}
		
	// Get Default Drive Details for this Account
	void getDefaultDriveDetails() {
		
		// Function variables
		JSONValue defaultOneDriveDriveDetails;
		
		// Create a new instance of the OneDrive API
		OneDriveApi getDefaultDriveApiInstance;
		getDefaultDriveApiInstance = new OneDriveApi(appConfig);
		getDefaultDriveApiInstance.initialise();
		
		// Get Default Drive Details for this Account
		try {
			addLogEntry("Getting Account Default Drive Details", ["debug"]);
			defaultOneDriveDriveDetails = getDefaultDriveApiInstance.getDefaultDriveDetails();
		} catch (OneDriveException exception) {
			addLogEntry("defaultOneDriveDriveDetails = getDefaultDriveApiInstance.getDefaultDriveDetails() generated a OneDriveException", ["debug"]);
			string thisFunctionName = getFunctionName!({});
			
			if ((exception.httpStatusCode == 400) || (exception.httpStatusCode == 401)) {
				// Handle the 400 | 401 error
				handleClientUnauthorised(exception.httpStatusCode, exception.error);
			} else {
				// Default operation if not 400,401 errors
				// - 408,429,503,504 errors are handled as a retry within getDefaultDriveApiInstance
				// Display what the error is
				displayOneDriveErrorMessage(exception.msg, getFunctionName!({}));
			}
		}
		
		// If the JSON response is a correct JSON object, and has an 'id' we can set these details
		if ((defaultOneDriveDriveDetails.type() == JSONType.object) && (hasId(defaultOneDriveDriveDetails))) {
			addLogEntry("OneDrive Account Default Drive Details:      " ~ to!string(defaultOneDriveDriveDetails), ["debug"]);
			appConfig.accountType = defaultOneDriveDriveDetails["driveType"].str;
			appConfig.defaultDriveId = defaultOneDriveDriveDetails["id"].str;
			
			// Make sure that appConfig.defaultDriveId is in our driveIDs array to use when checking if item is in database
			// Keep the DriveDetailsCache array with unique entries only
			DriveDetailsCache cachedOnlineDriveData;
			if (!canFindDriveId(appConfig.defaultDriveId, cachedOnlineDriveData)) {
				// Add this driveId to the drive cache, which then also sets for the defaultDriveId:
				// - quotaRestricted;
				// - quotaAvailable;
				// - quotaRemaining;
				addOrUpdateOneDriveOnlineDetails(appConfig.defaultDriveId);
			} 
			
			// Fetch the details from cachedOnlineDriveData
			cachedOnlineDriveData = getDriveDetails(appConfig.defaultDriveId);
			// - cachedOnlineDriveData.quotaRestricted;
			// - cachedOnlineDriveData.quotaAvailable;
			// - cachedOnlineDriveData.quotaRemaining;
			
			// In some cases OneDrive Business configurations 'restrict' quota details thus is empty / blank / negative value / zero
			if (cachedOnlineDriveData.quotaRemaining <= 0) {
				// free space is <= 0  .. why ?
				if ("remaining" in defaultOneDriveDriveDetails["quota"]) {
					if (appConfig.accountType == "personal") {
						// zero space available
						addLogEntry("ERROR: OneDrive account currently has zero space available. Please free up some space online.");
					} else {
						// zero space available is being reported, maybe being restricted?
						addLogEntry("WARNING: OneDrive quota information is being restricted or providing a zero value. Please fix by speaking to your OneDrive / Office 365 Administrator.");
					}
				} else {
					// json response was missing a 'remaining' value
					if (appConfig.accountType == "personal") {
						addLogEntry("ERROR: OneDrive quota information is missing. Potentially your OneDrive account currently has zero space available. Please free up some space online.");
					} else {
						// quota details not available
						addLogEntry("ERROR: OneDrive quota information is being restricted. Please fix by speaking to your OneDrive / Office 365 Administrator.");
					}
				}
			}
			
			// What did we set based on the data from the JSON
			addLogEntry("appConfig.accountType                 = " ~ appConfig.accountType, ["debug"]);
			addLogEntry("appConfig.defaultDriveId              = " ~ appConfig.defaultDriveId, ["debug"]);
			addLogEntry("cachedOnlineDriveData.quotaRemaining  = " ~ to!string(cachedOnlineDriveData.quotaRemaining), ["debug"]);
			addLogEntry("cachedOnlineDriveData.quotaAvailable  = " ~ to!string(cachedOnlineDriveData.quotaAvailable), ["debug"]);
			addLogEntry("cachedOnlineDriveData.quotaRestricted = " ~ to!string(cachedOnlineDriveData.quotaRestricted), ["debug"]);
			
		} else {
			// Handle the invalid JSON response
			throw new AccountDetailsException();
		}
		
		// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
		getDefaultDriveApiInstance.releaseCurlEngine();
		getDefaultDriveApiInstance = null;
		// Perform Garbage Collection
		GC.collect();
	}
	
	// Get Default Root Details for this Account
	void getDefaultRootDetails() {
		
		// Function variables
		JSONValue defaultOneDriveRootDetails;
		
		// Create a new instance of the OneDrive API
		OneDriveApi getDefaultRootApiInstance;
		getDefaultRootApiInstance = new OneDriveApi(appConfig);
		getDefaultRootApiInstance.initialise();
		
		// Get Default Root Details for this Account
		try {
			addLogEntry("Getting Account Default Root Details", ["debug"]);
			defaultOneDriveRootDetails = getDefaultRootApiInstance.getDefaultRootDetails();
		} catch (OneDriveException exception) {
			addLogEntry("defaultOneDriveRootDetails = getDefaultRootApiInstance.getDefaultRootDetails() generated a OneDriveException", ["debug"]);
			string thisFunctionName = getFunctionName!({});

			if ((exception.httpStatusCode == 400) || (exception.httpStatusCode == 401)) {
				// Handle the 400 | 401 error
				handleClientUnauthorised(exception.httpStatusCode, exception.error);
			} else {
				// Default operation if not 400,401 errors
				// - 408,429,503,504 errors are handled as a retry within getDefaultRootApiInstance
				// Display what the error is
				displayOneDriveErrorMessage(exception.msg, getFunctionName!({}));
			}
		}
		
		// If the JSON response is a correct JSON object, and has an 'id' we can set these details
		if ((defaultOneDriveRootDetails.type() == JSONType.object) && (hasId(defaultOneDriveRootDetails))) {
			addLogEntry("OneDrive Account Default Root Details:       " ~ to!string(defaultOneDriveRootDetails), ["debug"]);
			appConfig.defaultRootId = defaultOneDriveRootDetails["id"].str;
			addLogEntry("appConfig.defaultRootId      = " ~ appConfig.defaultRootId, ["debug"]);
			
			// Save the item to the database, so the account root drive is is always going to be present in the DB
			saveItem(defaultOneDriveRootDetails);
		} else {
			// Handle the invalid JSON response
			throw new AccountDetailsException();
		}
		
		// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
		getDefaultRootApiInstance.releaseCurlEngine();
		getDefaultRootApiInstance = null;
		// Perform Garbage Collection
		GC.collect();
	}
	
	// Reset syncFailures to false based on file activity
	void resetSyncFailures() {
		// Log initial status and any non-empty arrays
		string logMessage = "Evaluating reset of syncFailures: ";
		if (fileDownloadFailures.length > 0) {
			logMessage ~= "fileDownloadFailures is not empty; ";
		}
		if (fileUploadFailures.length > 0) {
			logMessage ~= "fileUploadFailures is not empty; ";
		}

		// Check if both arrays are empty to reset syncFailures
		if (fileDownloadFailures.length == 0 && fileUploadFailures.length == 0) {
			if (syncFailures) {
				syncFailures = false;
				logMessage ~= "Resetting syncFailures to false.";
			} else {
				logMessage ~= "syncFailures already false.";
			}
		} else {
			// Indicate no reset of syncFailures due to non-empty conditions
			logMessage ~= "Not resetting syncFailures due to non-empty arrays.";
		}

		// Log the final decision and conditions
		addLogEntry(logMessage, ["debug"]);
	}
	
	// Perform a sync of the OneDrive Account
	// - Query /delta
	//		- If singleDirectoryScope or nationalCloudDeployment is used we need to generate a /delta like response
	// - Process changes (add, changes, moves, deletes)
	// - Process any items to add (download data to local)
	// - Detail any files that we failed to download
	// - Process any deletes (remove local data)
	void syncOneDriveAccountToLocalDisk() {
	
		// performFullScanTrueUp value
		addLogEntry("Perform a Full Scan True-Up: " ~ to!string(appConfig.fullScanTrueUpRequired), ["debug"]);
		
		// Fetch the API response of /delta to track changes that were performed online
		fetchOneDriveDeltaAPIResponse();
		
		// Process any download activities or cleanup actions
		processDownloadActivities();
		
		// If singleDirectoryScope is false, we are not targeting a single directory
		// but if true, the target 'could' be a shared folder - so dont try and scan it again
		if (!singleDirectoryScope) {
			// OneDrive Shared Folder Handling
			if (appConfig.accountType == "personal") {
				// Personal Account Type
				// https://github.com/OneDrive/onedrive-api-docs/issues/764
				
				// Get the Remote Items from the Database
				Item[] remoteItems = itemDB.selectRemoteItems();
				foreach (remoteItem; remoteItems) {
					// Check if this path is specifically excluded by 'skip_dir', but only if 'skip_dir' is not empty
					if (appConfig.getValueString("skip_dir") != "") {
						// The path that needs to be checked needs to include the '/'
						// This due to if the user has specified in skip_dir an exclusive path: '/path' - that is what must be matched
						if (selectiveSync.isDirNameExcluded(remoteItem.name)) {
							// This directory name is excluded
							addLogEntry("Skipping path - excluded by skip_dir config: " ~ remoteItem.name, ["verbose"]);
							continue;
						}
					}
					
					// Directory name is not excluded or skip_dir is not populated
					if (!appConfig.suppressLoggingOutput) {
						addLogEntry("Syncing this OneDrive Personal Shared Folder: " ~ remoteItem.name);
					}
					// Check this OneDrive Personal Shared Folder for changes
					fetchOneDriveDeltaAPIResponse(remoteItem.remoteDriveId, remoteItem.remoteId, remoteItem.name);
					
					// Process any download activities or cleanup actions for this OneDrive Personal Shared Folder
					processDownloadActivities();
				}
				// Clear the array
				remoteItems = [];
			} else {
				// Is this a Business Account with Sync Business Shared Items enabled?
				if ((appConfig.accountType == "business") && (appConfig.getValueBool("sync_business_shared_items"))) {
				
					// Business Account Shared Items Handling
					// - OneDrive Business Shared Folder
					// - OneDrive Business Shared Files
					// - SharePoint Links
				
					// Get the Remote Items from the Database
					Item[] remoteItems = itemDB.selectRemoteItems();
					
					foreach (remoteItem; remoteItems) {
						// As all remote items are returned, including files, we only want to process directories here
						if (remoteItem.remoteType == ItemType.dir) {
							// Check if this path is specifically excluded by 'skip_dir', but only if 'skip_dir' is not empty
							if (appConfig.getValueString("skip_dir") != "") {
								// The path that needs to be checked needs to include the '/'
								// This due to if the user has specified in skip_dir an exclusive path: '/path' - that is what must be matched
								if (selectiveSync.isDirNameExcluded(remoteItem.name)) {
									// This directory name is excluded
									addLogEntry("Skipping path - excluded by skip_dir config: " ~ remoteItem.name, ["verbose"]);
									continue;
								}
							}
							
							// Directory name is not excluded or skip_dir is not populated
							if (!appConfig.suppressLoggingOutput) {
								addLogEntry("Syncing this OneDrive Business Shared Folder: " ~ remoteItem.name);
							}
							
							// Debug log output
							addLogEntry("Fetching /delta API response for:", ["debug"]);
							addLogEntry("    remoteItem.remoteDriveId: " ~ remoteItem.remoteDriveId, ["debug"]);
							addLogEntry("    remoteItem.remoteId:      " ~ remoteItem.remoteId, ["debug"]);
							
							// Check this OneDrive Business Shared Folder for changes
							fetchOneDriveDeltaAPIResponse(remoteItem.remoteDriveId, remoteItem.remoteId, remoteItem.name);
							
							// Process any download activities or cleanup actions for this OneDrive Business Shared Folder
							processDownloadActivities();
						}
					}
					// Clear the array
					remoteItems = [];
					
					// OneDrive Business Shared File Handling - but only if this option is enabled
					if (appConfig.getValueBool("sync_business_shared_files")) {
						// We need to create a 'new' local folder in the 'sync_dir' where these shared files & associated folder structure will reside
						// Whilst these files are synced locally, the entire folder structure will need to be excluded from syncing back to OneDrive
						// But file changes , *if any* , will need to be synced back to the original shared file location
						//  .
						//	├── Files Shared With Me													-> Directory should not be created online | Not Synced
						//	│          └── Display Name (email address) (of Account who shared file)	-> Directory should not be created online | Not Synced
						//	│          │   └── shared file.ext 											-> File synced with original shared file location on remote drive
						//	│          │   └── shared file.ext 											-> File synced with original shared file location on remote drive
						//	│          │   └── ......			 										-> File synced with original shared file location on remote drive
						//	│          └── Display Name (email address) ...
						//	│		└── shared file.ext ....											-> File synced with original shared file location on remote drive
						
						// Does the Local Folder to store the OneDrive Business Shared Files exist?
						if (!exists(appConfig.configuredBusinessSharedFilesDirectoryName)) {
							// Folder does not exist locally and needs to be created
							addLogEntry("Creating the OneDrive Business Shared Files Local Directory: " ~ appConfig.configuredBusinessSharedFilesDirectoryName);
						
							// Local folder does not exist, thus needs to be created
							mkdirRecurse(appConfig.configuredBusinessSharedFilesDirectoryName);
							// As this will not be created online, generate a response so it can be saved to the database
							Item sharedFilesPath = makeItem(createFakeResponse(baseName(appConfig.configuredBusinessSharedFilesDirectoryName)));
							
							// Add DB record to the local database
							addLogEntry("Creating|Updating into local database a DB record for storing OneDrive Business Shared Files: " ~ to!string(sharedFilesPath), ["debug"]);
							itemDB.upsert(sharedFilesPath);
						} else {
							// Folder exists locally, is the folder in the database? 
							// Query DB for this path
							Item dbRecord;
							if (!itemDB.selectByPath(baseName(appConfig.configuredBusinessSharedFilesDirectoryName), appConfig.defaultDriveId, dbRecord)) {
								// As this will not be created online, generate a response so it can be saved to the database
								Item sharedFilesPath = makeItem(createFakeResponse(baseName(appConfig.configuredBusinessSharedFilesDirectoryName)));
								
								// Add DB record to the local database
								addLogEntry("Creating|Updating into local database a DB record for storing OneDrive Business Shared Files: " ~ to!string(sharedFilesPath), ["debug"]);
								itemDB.upsert(sharedFilesPath);
							}
						}
						
						// Query for OneDrive Business Shared Files
						addLogEntry("Checking for any applicable OneDrive Business Shared Files which need to be synced locally", ["verbose"]);
						queryBusinessSharedObjects();
						
						// Download any OneDrive Business Shared Files
						processDownloadActivities();
					}
				}
			}
		}
	}
	
	// Cleanup arrays when used in --monitor loops
	void cleanupArrays() {
		addLogEntry("Cleaning up all internal arrays used when processing data", ["debug"]);
		
		// Multi Dimensional Arrays
		idsToDelete.length = 0;
		idsFaked.length = 0;
		databaseItemsWhereContentHasChanged.length = 0;
		
		// JSON Items Arrays
		jsonItemsToProcess = [];
		fileJSONItemsToDownload = [];
		jsonItemsToResumeUpload = [];
		
		// String Arrays
		fileDownloadFailures = [];
		pathFakeDeletedArray = [];
		pathsRenamed = [];
		newLocalFilesToUploadToOneDrive = [];
		fileUploadFailures = [];
		posixViolationPaths = [];
		businessSharedFoldersOnlineToSkip = [];
		interruptedUploadsSessionFiles = [];
		pathsToCreateOnline = [];
		databaseItemsToDeleteOnline = [];
		
		// Perform Garbage Collection on this destroyed curl engine
		GC.collect();
		addLogEntry("Cleaning of internal arrays complete", ["debug"]);
	}
	
	// Configure singleDirectoryScope = true if this function is called
	// By default, singleDirectoryScope = false
	void setSingleDirectoryScope(string normalisedSingleDirectoryPath) {
		
		// Function variables
		Item searchItem;
		JSONValue onlinePathData;
		
		// Set the main flag
		singleDirectoryScope = true;
		
		// What are we doing?
		addLogEntry("The OneDrive Client was asked to search for this directory online and create it if it's not located: " ~ normalisedSingleDirectoryPath);
		
		// Query the OneDrive API for the specified path online
		// In a --single-directory scenario, we need to travervse the entire path that we are wanting to sync
		// and then check the path element does it exist online, if it does, is it a POSIX match, or if it does not, create the path
		// Once we have searched online, we have the right drive id and item id so that we can downgrade the sync status, then build up 
		// any object items from that location
		// This is because, in a --single-directory scenario, any folder in the entire path tree could be a 'case-insensitive match'
		
		try {
			onlinePathData = queryOneDriveForSpecificPathAndCreateIfMissing(normalisedSingleDirectoryPath, true);
		} catch (PosixException e) {
			displayPosixErrorMessage(e.msg);
			addLogEntry("ERROR: Requested directory to search for and potentially create has a 'case-insensitive match' to an existing directory on OneDrive online.");
		}
		
		// Was a valid JSON response provided?
		if (onlinePathData.type() == JSONType.object) {
			// Valid JSON item was returned
			searchItem = makeItem(onlinePathData);
			addLogEntry("searchItem: " ~ to!string(searchItem), ["debug"]);
			
			// Is this item a potential Shared Folder?
			// Is this JSON a remote object
			if (isItemRemote(onlinePathData)) {
				// The path we are seeking is remote to our account drive id
				searchItem.driveId = onlinePathData["remoteItem"]["parentReference"]["driveId"].str;
				searchItem.id = onlinePathData["remoteItem"]["id"].str;
			} 
			
			// Set these items so that these can be used as required
			singleDirectoryScopeDriveId = searchItem.driveId;
			singleDirectoryScopeItemId = searchItem.id;
		} else {
			addLogEntry();
			addLogEntry("The requested --single-directory path to sync has generated an error. Please correct this error and try again.");
			addLogEntry();
			forceExit();
		}
	}
	
	// Query OneDrive API for /delta changes and iterate through items online
	void fetchOneDriveDeltaAPIResponse(string driveIdToQuery = null, string itemIdToQuery = null, string sharedFolderName = null) {
				
		string deltaLink = null;
		string currentDeltaLink = null;
		string databaseDeltaLink;
		JSONValue deltaChanges;
		ulong responseBundleCount;
		ulong jsonItemsReceived = 0;
		
		// Reset jsonItemsToProcess & processedCount
		jsonItemsToProcess = [];
		processedCount = 0;
		
		// Reset generateSimulatedDeltaResponse
		generateSimulatedDeltaResponse = false;
		
		// Reset Shared Folder Flags for 'sync_list' processing
		sharedFolderDeltaGeneration = false;
		currentSharedFolderName = "";
		
		// Was a driveId provided as an input
		if (strip(driveIdToQuery).empty) {
			// No provided driveId to query, use the account default
			addLogEntry("driveIdToQuery was empty, setting to appConfig.defaultDriveId", ["debug"]);
			driveIdToQuery = appConfig.defaultDriveId;
			addLogEntry("driveIdToQuery: " ~ driveIdToQuery, ["debug"]);
		}
		
		// Was an itemId provided as an input
		if (strip(itemIdToQuery).empty) {
			// No provided itemId to query, use the account default
			addLogEntry("itemIdToQuery was empty, setting to appConfig.defaultRootId", ["debug"]);
			itemIdToQuery = appConfig.defaultRootId;
			addLogEntry("itemIdToQuery: " ~ itemIdToQuery, ["debug"]);
		}
		
		// What OneDrive API query do we use?
		// - Are we running against a National Cloud Deployments that does not support /delta ?
		//   National Cloud Deployments do not support /delta as a query
		//   https://docs.microsoft.com/en-us/graph/deployments#supported-features
		//
		// - Are we performing a --single-directory sync, which will exclude many items online, focusing in on a specific online directory
		// 
		// - Are we performing a --download-only --cleanup-local-files action?
		//   - If we are, and we use a normal /delta query, we get all the local 'deleted' objects as well.
		//   - If the user deletes a folder online, then replaces it online, we download the deletion events and process the new 'upload' via the web interface .. 
		//     the net effect of this, is that the valid local files we want to keep, are actually deleted ...... not desirable
		if ((singleDirectoryScope) || (nationalCloudDeployment) || (cleanupLocalFiles)) {
			// Generate a simulated /delta response so that we correctly capture the current online state, less any 'online' delete and replace activity
			generateSimulatedDeltaResponse = true;
		}
		
		// Shared Folders, by nature of where that path has been shared with us, we cannot use /delta against that path, as this queries the entire 'other persons' drive:
		//    Syncing this OneDrive Business Shared Folder: Sub Folder 2
		//    Fetching /delta response from the OneDrive API for Drive ID: b!fZgJhK-pU0eTQpylvmoYCkE4YgH_KRNDlxjRx9OWNqmV9Q_E_uWdRJKIB5L_ruPN
		//    Processing API Response Bundle: 1 - Quantity of 'changes|items' in this bundle to process: 18
		//    Skipping path - excluded by sync_list config: Sub Folder Share/Sub Folder 1/Sub Folder 2
		//
		// When using 'sync_list' potentially nothing is going to match, as, we are getting the 'whole' path from their 'root' , not just the folder shared with us
		if (!sharedFolderName.empty) {
			// When using 'sync_list' we need to do this
			sharedFolderDeltaGeneration = true;
			currentSharedFolderName = sharedFolderName;
			
			generateSimulatedDeltaResponse = true;
			
		}
		
		// Reset latestDeltaLink & deltaLinkCache
		latestDeltaLink = null;
		deltaLinkCache.driveId = null;
		deltaLinkCache.itemId = null;
		deltaLinkCache.latestDeltaLink = null;
		// Perform Garbage Collection
		GC.collect();
				
		// What /delta query do we use?
		if (!generateSimulatedDeltaResponse) {
			// This should be the majority default pathway application use
			
			// Do we need to perform a Full Scan True Up? Is 'appConfig.fullScanTrueUpRequired' set to 'true'?
			if (appConfig.fullScanTrueUpRequired) {
				addLogEntry("Performing a full scan of online data to ensure consistent local state");
				addLogEntry("Setting currentDeltaLink = null", ["debug"]);
				currentDeltaLink = null;
			} else {
				// Try and get the current Delta Link from the internal cache, this saves a DB I/O call
				currentDeltaLink = getDeltaLinkFromCache(deltaLinkInfo, driveIdToQuery);
				
				// Is currentDeltaLink empty (no cached entry found) ?
				if (currentDeltaLink.empty) {
					// Try and get the current delta link from the database for this DriveID and RootID
					databaseDeltaLink = itemDB.getDeltaLink(driveIdToQuery, itemIdToQuery);
					if (!databaseDeltaLink.empty) {
						addLogEntry("Using database stored deltaLink", ["debug"]);
						currentDeltaLink = databaseDeltaLink;
					} else {
						addLogEntry("Zero deltaLink available for use, we will be performing a full online scan", ["debug"]);
						currentDeltaLink = null;
					}
				} else {
					// Log that we are using the deltaLink for cache
					addLogEntry("Using cached deltaLink", ["debug"]);
				}
			}
			
			// Dynamic output for non-verbose and verbose run so that the user knows something is being retrieved from the OneDrive API
			if (appConfig.verbosityCount == 0) {
				if (!appConfig.suppressLoggingOutput) {
					addProcessingLogHeaderEntry("Fetching items from the OneDrive API for Drive ID: " ~ driveIdToQuery, appConfig.verbosityCount);
				}
			} else {
				addLogEntry("Fetching /delta response from the OneDrive API for Drive ID: " ~  driveIdToQuery, ["verbose"]);
			}
			
			// Create a new API Instance for querying the actual /delta and initialise it
			OneDriveApi getDeltaDataOneDriveApiInstance;
			getDeltaDataOneDriveApiInstance = new OneDriveApi(appConfig);
			getDeltaDataOneDriveApiInstance.initialise();

			// Get the /delta changes via the OneDrive API
			while (true) {
				// Check if exitHandlerTriggered is true
				if (exitHandlerTriggered) {
					// break out of the 'while (true)' loop
					break;
				}
				
				// Increment responseBundleCount
				responseBundleCount++;
				
				// Ensure deltaChanges is empty before we query /delta
				deltaChanges = null;
				// Perform Garbage Collection
				GC.collect();
				
				// getDeltaChangesByItemId has the re-try logic for transient errors
				deltaChanges = getDeltaChangesByItemId(driveIdToQuery, itemIdToQuery, currentDeltaLink, getDeltaDataOneDriveApiInstance);
				
				// If the initial deltaChanges response is an invalid JSON object, keep trying until we get a valid response ..
				if (deltaChanges.type() != JSONType.object) {
					// While the response is not a JSON Object or the Exit Handler has not been triggered
					while (deltaChanges.type() != JSONType.object) {
						// Check if exitHandlerTriggered is true
						if (exitHandlerTriggered) {
							// break out of the 'while (true)' loop
							break;
						}
					
						// Handle the invalid JSON response and retry
						addLogEntry("ERROR: Query of the OneDrive API via deltaChanges = getDeltaChangesByItemId() returned an invalid JSON response", ["debug"]);
						deltaChanges = getDeltaChangesByItemId(driveIdToQuery, itemIdToQuery, currentDeltaLink, getDeltaDataOneDriveApiInstance);
					}
				}
				
				ulong nrChanges = count(deltaChanges["value"].array);
				int changeCount = 0;
				
				if (appConfig.verbosityCount == 0) {
					// Dynamic output for a non-verbose run so that the user knows something is happening
					if (!appConfig.suppressLoggingOutput) {
						addProcessingDotEntry();
					}
				} else {
					addLogEntry("Processing API Response Bundle: " ~ to!string(responseBundleCount) ~ " - Quantity of 'changes|items' in this bundle to process: " ~ to!string(nrChanges), ["verbose"]);
				}
				
				// Update the count of items received
				jsonItemsReceived = jsonItemsReceived + nrChanges;
				
				// The 'deltaChanges' response may contain either @odata.nextLink or @odata.deltaLink
				// Check for @odata.nextLink
				if ("@odata.nextLink" in deltaChanges) {
					// @odata.nextLink is the pointer within the API to the next '200+' JSON bundle - this is the checkpoint link for this bundle
					// This URL changes between JSON bundle sets
					// Log the action of setting currentDeltaLink to @odata.nextLink
					addLogEntry("Setting currentDeltaLink to @odata.nextLink: " ~ deltaChanges["@odata.nextLink"].str, ["debug"]);
					
					// Update currentDeltaLink to @odata.nextLink for the next '200+' JSON bundle - this is the checkpoint link for this bundle
					currentDeltaLink = deltaChanges["@odata.nextLink"].str;
				}
				
				// Check for @odata.deltaLink - usually only in the LAST JSON changeset bundle
				if ("@odata.deltaLink" in deltaChanges) {
					// @odata.deltaLink is the pointer that finalises all the online 'changes' for this particular checkpoint
					// When the API is queried again, this is fetched from the DB as this is the starting point
					// The API issue here is - the LAST JSON bundle will ONLY ever contain this item, meaning if this is then committed to the database
					// if there has been any file download failures from within this LAST JSON bundle, the only way to EVER re-try the failed items is for the user to perform a --resync
					// This is an API capability gap:
					//
					// ..
					// @odata.nextLink:  https://graph.microsoft.com/v1.0/drives/<redacted>/items/<redacted>/delta?token=<redacted>F9JRD0zODEyNzg7JTIzOyUyMzA7JTIz
					// Processing API Response Bundle: 115 - Quantity of 'changes|items' in this bundle to process: 204
					// ..
					// @odata.nextLink:  https://graph.microsoft.com/v1.0/drives/<redacted>/items/<redacted>/delta?token=<redacted>F9JRD0zODM2Nzg7JTIzOyUyMzA7JTIz
					// Processing API Response Bundle: 127 - Quantity of 'changes|items' in this bundle to process: 204
					// @odata.nextLink:  https://graph.microsoft.com/v1.0/drives/<redacted>/items/<redacted>/delta?token=<redacted>F9JRD0zODM4Nzg7JTIzOyUyMzA7JTIz
					// Processing API Response Bundle: 128 - Quantity of 'changes|items' in this bundle to process: 176
					// @odata.deltaLink: https://graph.microsoft.com/v1.0/drives/<redacted>/items/<redacted>/delta?token=<redacted>
					// Finished processing /delta JSON response from the OneDrive API
					
					// Log the action of setting currentDeltaLink to @odata.deltaLink
					addLogEntry("Setting currentDeltaLink to (@odata.deltaLink): " ~ deltaChanges["@odata.deltaLink"].str, ["debug"]);
					
					// Update currentDeltaLink to @odata.deltaLink as the final checkpoint URL for this entire JSON response set
					currentDeltaLink = deltaChanges["@odata.deltaLink"].str;
					
					// Store this currentDeltaLink as latestDeltaLink
					latestDeltaLink = deltaChanges["@odata.deltaLink"].str;
					
					// Update deltaLinkCache
					deltaLinkCache.driveId = driveIdToQuery;
					deltaLinkCache.itemId = itemIdToQuery;
					deltaLinkCache.latestDeltaLink = currentDeltaLink;
				}
				
				// We have a valid deltaChanges JSON array. This means we have at least 200+ JSON items to process.
				// The API response however cannot be run in parallel as the OneDrive API sends the JSON items in the order in which they must be processed
				auto jsonArrayToProcess = deltaChanges["value"].array;
				foreach (onedriveJSONItem; jsonArrayToProcess) {
					// increment change count for this item
					changeCount++;
					// Process the received OneDrive object item JSON for this JSON bundle
					// This will determine its initial applicability and perform some initial processing on the JSON if required
					processDeltaJSONItem(onedriveJSONItem, nrChanges, changeCount, responseBundleCount, singleDirectoryScope);
				}
				
				// Clear up this data
				jsonArrayToProcess = null;
				// Perform Garbage Collection
				GC.collect();
				
				// Is latestDeltaLink matching deltaChanges["@odata.deltaLink"].str ?
				if ("@odata.deltaLink" in deltaChanges) {
					if (latestDeltaLink == deltaChanges["@odata.deltaLink"].str) {
						// break out of the 'while (true)' loop
						break;
					}
				}
				
				// Cleanup deltaChanges as this is no longer needed
				deltaChanges = null;
				// Perform Garbage Collection
				GC.collect();
				
				// Sleep for a while to avoid busy-waiting
				Thread.sleep(dur!"msecs"(100)); // Adjust the sleep duration as needed
			}
			
			// Terminate getDeltaDataOneDriveApiInstance here
			getDeltaDataOneDriveApiInstance.releaseCurlEngine();
			getDeltaDataOneDriveApiInstance = null;
			// Perform Garbage Collection on this destroyed curl engine
			GC.collect();
			
			// To finish off the JSON processing items, this is needed to reflect this in the log
			addLogEntry("------------------------------------------------------------------", ["debug"]);
			
			// Log that we have finished querying the /delta API
			if (appConfig.verbosityCount == 0) {
				if (!appConfig.suppressLoggingOutput) {
					// Close out the '....' being printed to the console
					completeProcessingDots();
				}
			} else {
				addLogEntry("Finished processing /delta JSON response from the OneDrive API", ["verbose"]);
			}
			
			// If this was set, now unset it, as this will have been completed, so that for a true up, we dont do a double full scan
			if (appConfig.fullScanTrueUpRequired) {
				addLogEntry("Unsetting fullScanTrueUpRequired as this has been performed", ["debug"]);
				appConfig.fullScanTrueUpRequired = false;
			}
			
			// Cleanup deltaChanges as this is no longer needed
			deltaChanges = null;
			// Perform Garbage Collection
			GC.collect();
		} else {
			// Why are are generating a /delta response
			addLogEntry("Why are we generating a /delta response:", ["debug"]);
			addLogEntry(" singleDirectoryScope:    " ~ to!string(singleDirectoryScope), ["debug"]);
			addLogEntry(" nationalCloudDeployment: " ~ to!string(nationalCloudDeployment), ["debug"]);
			addLogEntry(" cleanupLocalFiles:       " ~ to!string(cleanupLocalFiles), ["debug"]);
			addLogEntry(" sharedFolderName:        " ~ sharedFolderName, ["debug"]);
			
			// What 'path' are we going to start generating the response for
			string pathToQuery;
			
			// If --single-directory has been called, use the value that has been set
			if (singleDirectoryScope) {
				pathToQuery = appConfig.getValueString("single_directory");
			}
			
			// We could also be syncing a Shared Folder of some description
			if (!sharedFolderName.empty) {
				pathToQuery = sharedFolderName;
			}
			
			// Generate the simulated /delta response
			//
			// The generated /delta response however contains zero deleted JSON items, so the only way that we can track this, is if the object was in sync
			// we have the object in the database, thus, what we need to do is for every DB object in the tree of items, flag 'syncStatus' as 'N', then when we process 
			// the returned JSON items from the API, we flag the item as back in sync, then we can cleanup any out-of-sync items
			//
			// The flagging of the local database items to 'N' is handled within the generateDeltaResponse() function
			//
			// When these JSON items are then processed, if the item exists online, and is in the DB, and that the values match, the DB item is flipped back to 'Y' 
			// This then allows the application to look for any remaining 'N' values, and delete these as no longer needed locally
			deltaChanges = generateDeltaResponse(pathToQuery);
			
			// How many changes were returned?
			ulong nrChanges = count(deltaChanges["value"].array);
			int changeCount = 0;
			addLogEntry("API Response Bundle: " ~ to!string(responseBundleCount) ~ " - Quantity of 'changes|items' in this bundle to process: " ~ to!string(nrChanges), ["debug"]);
			// Update the count of items received
			jsonItemsReceived = jsonItemsReceived + nrChanges;
			
			// The API response however cannot be run in parallel as the OneDrive API sends the JSON items in the order in which they must be processed
			auto jsonArrayToProcess = deltaChanges["value"].array;
			foreach (onedriveJSONItem; deltaChanges["value"].array) {
				// increment change count for this item
				changeCount++;
				// Process the received OneDrive object item JSON for this JSON bundle
				// When we generate a /delta response .. there is no currentDeltaLink value
				processDeltaJSONItem(onedriveJSONItem, nrChanges, changeCount, responseBundleCount, singleDirectoryScope);
			}
			
			// Clear up this data
			jsonArrayToProcess = null;
			// Perform Garbage Collection
			GC.collect();
			
			// To finish off the JSON processing items, this is needed to reflect this in the log
			addLogEntry("------------------------------------------------------------------", ["debug"]);
			
			// Log that we have finished generating our self generated /delta response
			if (!appConfig.suppressLoggingOutput) {
				addLogEntry("Finished processing self generated /delta JSON response from the OneDrive API");
			}
			
			// Cleanup deltaChanges as this is no longer needed
			deltaChanges = null;
		}
		
		// Cleanup deltaChanges as this is no longer needed
		deltaChanges = null;
		// Perform Garbage Collection
		GC.collect();
		
		// We have JSON items received from the OneDrive API
		addLogEntry("Number of JSON Objects received from OneDrive API:                 " ~ to!string(jsonItemsReceived), ["debug"]);
		addLogEntry("Number of JSON Objects already processed (root and deleted items): " ~ to!string((jsonItemsReceived - jsonItemsToProcess.length)), ["debug"]);
		
		// We should have now at least processed all the JSON items as returned by the /delta call
		// Additionally, we should have a new array, that now contains all the JSON items we need to process that are non 'root' or deleted items
		addLogEntry("Number of JSON items to process is: " ~ to!string(jsonItemsToProcess.length), ["debug"]);
		
		// Are there items to process?
		if (jsonItemsToProcess.length > 0) {
			// Lets deal with the JSON items in a batch process
			size_t batchSize = 500;
			ulong batchCount = (jsonItemsToProcess.length + batchSize - 1) / batchSize;
			ulong batchesProcessed = 0;
			
			// Dynamic output for a non-verbose run so that the user knows something is happening
			if (!appConfig.suppressLoggingOutput) {
				addProcessingLogHeaderEntry("Processing " ~ to!string(jsonItemsToProcess.length) ~ " applicable changes and items received from Microsoft OneDrive", appConfig.verbosityCount);
			}
			
			// For each batch, process the JSON items that need to be now processed.
			// 'root' and deleted objects have already been handled
			foreach (batchOfJSONItems; jsonItemsToProcess.chunks(batchSize)) {
				// Chunk the total items to process into 500 lot items
				batchesProcessed++;
				if (appConfig.verbosityCount == 0) {
					// Dynamic output for a non-verbose run so that the user knows something is happening
					if (!appConfig.suppressLoggingOutput) {
						addProcessingDotEntry();
					}
				} else {
					addLogEntry("Processing OneDrive JSON item batch [" ~ to!string(batchesProcessed) ~ "/" ~ to!string(batchCount) ~ "] to ensure consistent local state", ["verbose"]);
				}	
					
				// Process the batch
				processJSONItemsInBatch(batchOfJSONItems, batchesProcessed, batchCount);
				
				// To finish off the JSON processing items, this is needed to reflect this in the log
				addLogEntry("------------------------------------------------------------------", ["debug"]);
			}
			
			if (appConfig.verbosityCount == 0) {
				// close off '.' output
				if (!appConfig.suppressLoggingOutput) {
					// Close out the '....' being printed to the console
					completeProcessingDots();
				}
			}
			
			// Debug output - what was processed
			addLogEntry("Number of JSON items to process is: " ~ to!string(jsonItemsToProcess.length), ["debug"]);
			addLogEntry("Number of JSON items processed was: " ~ to!string(processedCount), ["debug"]);
			
			// Free up memory and items processed as it is pointless now having this data around
			jsonItemsToProcess = [];
			
			// Perform Garbage Collection on this destroyed curl engine
			GC.collect();
		} else {
			if (!appConfig.suppressLoggingOutput) {
				addLogEntry("No changes or items that can be applied were discovered while processing the data received from Microsoft OneDrive");
			}
		}
		
		// Keep the DriveDetailsCache array with unique entries only
		DriveDetailsCache cachedOnlineDriveData;
		if (!canFindDriveId(driveIdToQuery, cachedOnlineDriveData)) {
			// Add this driveId to the drive cache
			addOrUpdateOneDriveOnlineDetails(driveIdToQuery);
		}
	}
	
	// Process the /delta API JSON response items
	void processDeltaJSONItem(JSONValue onedriveJSONItem, ulong nrChanges, int changeCount, ulong responseBundleCount, bool singleDirectoryScope) {
		
		// Variables for this JSON item
		string thisItemId;
		bool itemIsRoot = false;
		bool handleItemAsRootObject = false;
		bool itemIsDeletedOnline = false;
		bool itemHasParentReferenceId = false;
		bool itemHasParentReferencePath = false;
		bool itemIdMatchesDefaultRootId = false;
		bool itemNameExplicitMatchRoot = false;
		string objectParentDriveId;
		auto jsonProcessingStartTime = Clock.currTime();
		
		addLogEntry("------------------------------------------------------------------", ["debug"]);
		addLogEntry("Processing OneDrive Item " ~ to!string(changeCount) ~ " of " ~ to!string(nrChanges) ~ " from API Response Bundle " ~ to!string(responseBundleCount), ["debug"]);
		addLogEntry("Raw JSON OneDrive Item: " ~ to!string(onedriveJSONItem), ["debug"]);
		
		// What is this item's id
		thisItemId = onedriveJSONItem["id"].str;
		
		// Is this a deleted item - only calculate this once
		itemIsDeletedOnline = isItemDeleted(onedriveJSONItem);
		if (!itemIsDeletedOnline) {
			// This is not a deleted item
			addLogEntry("This item is not a OneDrive deletion change", ["debug"]);
			
			// Only calculate this once
			itemIsRoot = isItemRoot(onedriveJSONItem);
			itemHasParentReferenceId = hasParentReferenceId(onedriveJSONItem);
			itemIdMatchesDefaultRootId = (thisItemId == appConfig.defaultRootId);
			itemNameExplicitMatchRoot = (onedriveJSONItem["name"].str == "root");
			objectParentDriveId = onedriveJSONItem["parentReference"]["driveId"].str;
			
			// Test is this is the OneDrive Users Root?
			// Debug output of change evaluation items
			addLogEntry("defaultRootId                                        = " ~ appConfig.defaultRootId, ["debug"]);
			addLogEntry("'search id'                                          = " ~ thisItemId, ["debug"]);
			addLogEntry("id == defaultRootId                                  = " ~ to!string(itemIdMatchesDefaultRootId), ["debug"]);
			addLogEntry("isItemRoot(onedriveJSONItem)                         = " ~ to!string(itemIsRoot), ["debug"]);
			addLogEntry("onedriveJSONItem['name'].str == 'root'               = " ~ to!string(itemNameExplicitMatchRoot), ["debug"]);
			addLogEntry("itemHasParentReferenceId                             = " ~ to!string(itemHasParentReferenceId), ["debug"]);
			
			if ( (itemIdMatchesDefaultRootId || singleDirectoryScope) && itemIsRoot && itemNameExplicitMatchRoot) {
				// This IS a OneDrive Root item or should be classified as such in the case of 'singleDirectoryScope'
				addLogEntry("JSON item will flagged as a 'root' item", ["debug"]);
				handleItemAsRootObject = true;
			}
		}
		
		// How do we handle this JSON item from the OneDrive API?
		// Is this a confirmed 'root' item, has no Parent ID, or is a Deleted Item
		if (handleItemAsRootObject || !itemHasParentReferenceId || itemIsDeletedOnline){
			// Is a root item, has no id in parentReference or is a OneDrive deleted item
			addLogEntry("objectParentDriveId                                  = " ~ objectParentDriveId, ["debug"]);
			addLogEntry("handleItemAsRootObject                               = " ~ to!string(handleItemAsRootObject), ["debug"]);
			addLogEntry("itemHasParentReferenceId                             = " ~ to!string(itemHasParentReferenceId), ["debug"]);
			addLogEntry("itemIsDeletedOnline                                  = " ~ to!string(itemIsDeletedOnline), ["debug"]);
			addLogEntry("Handling change immediately as 'root item', or has no parent reference id or is a deleted item", ["debug"]);
			
			// OK ... do something with this JSON post here ....
			processRootAndDeletedJSONItems(onedriveJSONItem, objectParentDriveId, handleItemAsRootObject, itemIsDeletedOnline, itemHasParentReferenceId);
		} else {
			// Do we need to update this RAW JSON from OneDrive?
			if ( (objectParentDriveId != appConfig.defaultDriveId) && (appConfig.accountType == "business") && (appConfig.getValueBool("sync_business_shared_items")) ) {
				// Potentially need to update this JSON data
				addLogEntry("Potentially need to update this source JSON .... need to check the database", ["debug"]);
				
				// Check the DB for 'remote' objects, searching 'remoteDriveId' and 'remoteId' items for this remoteItem.driveId and remoteItem.id
				Item remoteDBItem;
				itemDB.selectByRemoteId(objectParentDriveId, thisItemId, remoteDBItem);
				
				// Is the data that was returned from the database what we are looking for?
				if ((remoteDBItem.remoteDriveId == objectParentDriveId) && (remoteDBItem.remoteId == thisItemId)) {
					// Yes, this is the record we are looking for
					addLogEntry("DB Item response for remoteDBItem: " ~ to!string(remoteDBItem), ["debug"]);
				
					// Must compare remoteDBItem.name with remoteItem.name
					if (remoteDBItem.name != onedriveJSONItem["name"].str) {
						// Update JSON Item
						string actualOnlineName = onedriveJSONItem["name"].str;
						addLogEntry("Updating source JSON 'name' to that which is the actual local directory", ["debug"]);
						addLogEntry("onedriveJSONItem['name'] was:         " ~ onedriveJSONItem["name"].str, ["debug"]);
						addLogEntry("Updating onedriveJSONItem['name'] to: " ~ remoteDBItem.name, ["debug"]);
						onedriveJSONItem["name"] = remoteDBItem.name;
						addLogEntry("onedriveJSONItem['name'] now:         " ~ onedriveJSONItem["name"].str, ["debug"]);
						// Add the original name to the JSON
						onedriveJSONItem["actualOnlineName"] = actualOnlineName;
					}
				}
			}
		
			// If we are not self-generating a /delta response, check this initial /delta JSON bundle item against the basic checks 
			// of applicability against 'skip_file', 'skip_dir' and 'sync_list'
			// We only do this if we did not generate a /delta response, as generateDeltaResponse() performs the checkJSONAgainstClientSideFiltering()
			// against elements as it is building the /delta compatible response
			// If we blindly just 'check again' all JSON responses then there is potentially double JSON processing going on if we used generateDeltaResponse()
			bool discardDeltaJSONItem = false;
			if (!generateSimulatedDeltaResponse) {
				// Check applicability against 'skip_file', 'skip_dir' and 'sync_list'
				discardDeltaJSONItem = checkJSONAgainstClientSideFiltering(onedriveJSONItem);
			}
			
			// Add this JSON item for further processing if this is not being discarded
			if (!discardDeltaJSONItem) {
				// Add onedriveJSONItem to jsonItemsToProcess
				addLogEntry("Adding this Raw JSON OneDrive Item to jsonItemsToProcess array for further processing", ["debug"]);
				jsonItemsToProcess ~= onedriveJSONItem;
			}
		}
		
		// How long to initially process this JSON item
		auto jsonProcessingElapsedTime = Clock.currTime() - jsonProcessingStartTime;
		addLogEntry("Initial JSON item processing time: " ~ to!string(jsonProcessingElapsedTime), ["debug"]);
	}
	
	// Process 'root' and 'deleted' OneDrive JSON items
	void processRootAndDeletedJSONItems(JSONValue onedriveJSONItem, string driveId, bool handleItemAsRootObject, bool itemIsDeletedOnline, bool itemHasParentReferenceId) {
		
		// Use the JSON elements rather can computing a DB struct via makeItem()
		string thisItemId = onedriveJSONItem["id"].str;
		string thisItemDriveId = onedriveJSONItem["parentReference"]["driveId"].str;
			
		// Check if the item has been seen before
		Item existingDatabaseItem;
		bool existingDBEntry = itemDB.selectById(thisItemDriveId, thisItemId, existingDatabaseItem);
		
		// Is the item deleted online?
		if(!itemIsDeletedOnline) {
			
			// Is the item a confirmed root object?
			
			// The JSON item should be considered a 'root' item if:
			// 1. Contains a ["root"] element
			// 2. Has no ["parentReference"]["id"] ... #323 & #324 highlighted that this is false as some 'root' shared objects now can have an 'id' element .. OneDrive API change
			// 2. Has no ["parentReference"]["path"]
			// 3. Was detected by an input flag as to be handled as a root item regardless of actual status
			
			if ((handleItemAsRootObject) || (!itemHasParentReferenceId)) {
				addLogEntry("Handing JSON object as OneDrive 'root' object", ["debug"]);
				if (!existingDBEntry) {
					// we have not seen this item before
					saveItem(onedriveJSONItem);
				}
			}
		} else {
			// Change is to delete an item
			addLogEntry("Handing a OneDrive Deleted Item", ["debug"]);
			if (existingDBEntry) {
				// Is the item to delete locally actually in sync with OneDrive currently?
				// What is the source of this item data?
				string itemSource = "online";
				
				// Compute this deleted items path based on the database entries
				string localPathToDelete = computeItemPath(existingDatabaseItem.driveId, existingDatabaseItem.parentId) ~ "/" ~ existingDatabaseItem.name;
				if (isItemSynced(existingDatabaseItem, localPathToDelete, itemSource)) {
					// Flag to delete
					addLogEntry("Flagging to delete item locally: " ~ to!string(onedriveJSONItem), ["debug"]);
					idsToDelete ~= [thisItemDriveId, thisItemId];
				} else {
					// local data protection is configured, safeBackup the local file, passing in if we are performing a --dry-run or not
					// In case the renamed path is needed
					string renamedPath;
					safeBackup(localPathToDelete, dryRun, renamedPath);
				}
			} else {
				// Flag to ignore
				addLogEntry("Flagging item to skip: " ~ to!string(onedriveJSONItem), ["debug"]);
				skippedItems.insert(thisItemId);
			}
		}
	}
	
	// Process each of the elements contained in jsonItemsToProcess[]
	void processJSONItemsInBatch(JSONValue[] array, ulong batchGroup, ulong batchCount) {
	
		ulong batchElementCount = array.length;

		foreach (i, onedriveJSONItem; array.enumerate) {
			// Use the JSON elements rather can computing a DB struct via makeItem()
			ulong elementCount = i +1;
			auto jsonProcessingStartTime = Clock.currTime();
			
			// To show this is the processing for this particular item, start off with this breaker line
			addLogEntry("------------------------------------------------------------------", ["debug"]);
			addLogEntry("Processing OneDrive JSON item " ~ to!string(elementCount) ~ " of " ~ to!string(batchElementCount) ~ " as part of JSON Item Batch " ~ to!string(batchGroup) ~ " of " ~ to!string(batchCount), ["debug"]);
			addLogEntry("Raw JSON OneDrive Item (Batched Item): " ~ to!string(onedriveJSONItem), ["debug"]);
			
			// Configure required items from the JSON elements
			string thisItemId = onedriveJSONItem["id"].str;
			string thisItemDriveId = onedriveJSONItem["parentReference"]["driveId"].str;
			string thisItemParentId = onedriveJSONItem["parentReference"]["id"].str;
			string thisItemName = onedriveJSONItem["name"].str;
			
			// Create an empty item struct for an existing DB item
			Item existingDatabaseItem;
			
			// Do we NOT want this item?
			bool unwanted = false; // meaning by default we will WANT this item
			// Is this parent is in the database
			bool parentInDatabase = false;
			// What is the path of the new item
			string newItemPath;
			
			// Configure the remoteItem - so if it is used, it can be utilised later
			Item remoteItem;
			
			// Check the database for an existing entry for this JSON item
			bool existingDBEntry = itemDB.selectById(thisItemDriveId, thisItemId, existingDatabaseItem);
			
			// Calculate if the Parent Item is in the database so that it can be re-used
			parentInDatabase = itemDB.idInLocalDatabase(thisItemDriveId, thisItemParentId);
			
			// Calculate the path of this JSON item, but we can only do this if the parent is in the database
			if (parentInDatabase) {
				// Calculate this items path
				newItemPath = computeItemPath(thisItemDriveId, thisItemParentId) ~ "/" ~ thisItemName;
				addLogEntry("JSON Item calculated full path is: " ~ newItemPath, ["debug"]);
			} else {
				// Parent not in the database
				// Is the parent a 'folder' from another user? ie - is this a 'shared folder' that has been shared with us?
				
				// Lets determine why?
				if (thisItemDriveId == appConfig.defaultDriveId) {
					// Parent path does not exist - flagging as unwanted
					addLogEntry("Flagging as unwanted: thisItemDriveId (" ~ thisItemDriveId ~ "), thisItemParentId (" ~ thisItemParentId ~ ") not in local database", ["debug"]);
					// Was this a skipped item?
					if (thisItemParentId in skippedItems) {
						// Parent is a skipped item
						addLogEntry("Reason: thisItemParentId listed within skippedItems", ["debug"]);
					} else {
						// Parent is not in the database, as we are not creating it
						addLogEntry("Reason: Parent ID is not in the DB .. ", ["debug"]);
					}
					
					// Flag as unwanted
					unwanted = true;	
				} else {
					// Edge case as the parent (from another users OneDrive account) will never be in the database - potentially a shared object?
					addLogEntry("The reported parentId is not in the database. This potentially is a shared folder as 'remoteItem.driveId' != 'appConfig.defaultDriveId'. Relevant Details: remoteItem.driveId (" ~ remoteItem.driveId ~ "), remoteItem.parentId (" ~ remoteItem.parentId ~ ")", ["debug"]);
					addLogEntry("Potential Shared Object JSON: " ~ to!string(onedriveJSONItem), ["debug"]);

					// Format the OneDrive change into a consumable object for the database
					remoteItem = makeItem(onedriveJSONItem);
										
					if (appConfig.accountType == "personal") {
						// Personal Account Handling
						addLogEntry("Handling a Personal Shared Item JSON object", ["debug"]);
						
						if (hasSharedElement(onedriveJSONItem)) {
							// Has the Shared JSON structure
							addLogEntry("Personal Shared Item JSON object has the 'shared' JSON structure", ["debug"]);
							// Create a 'root' DB Tie Record for this JSON object
							createDatabaseRootTieRecordForOnlineSharedFolder(onedriveJSONItem);
						}
						
						// Ensure that this item has no parent
						addLogEntry("Setting remoteItem.parentId to be null", ["debug"]);
						remoteItem.parentId = null;
						// Add this record to the local database
						addLogEntry("Update/Insert local database with remoteItem details with remoteItem.parentId as null: " ~ to!string(remoteItem), ["debug"]);
						itemDB.upsert(remoteItem);
					} else {
						// Business or SharePoint Account Handling
						addLogEntry("Handling a Business or SharePoint Shared Item JSON object", ["debug"]);
						
						if (appConfig.accountType == "business") {
							// Create a 'root' DB Tie Record for this JSON object
							createDatabaseRootTieRecordForOnlineSharedFolder(onedriveJSONItem);
							
							// Ensure that this item has no parent
							addLogEntry("Setting remoteItem.parentId to be null", ["debug"]);
							remoteItem.parentId = null;
							
							// Check the DB for 'remote' objects, searching 'remoteDriveId' and 'remoteId' items for this remoteItem.driveId and remoteItem.id
							Item remoteDBItem;
							itemDB.selectByRemoteId(remoteItem.driveId, remoteItem.id, remoteDBItem);
							
							// Must compare remoteDBItem.name with remoteItem.name
							if ((!remoteDBItem.name.empty) && (remoteDBItem.name != remoteItem.name)) {
								// Update DB Item
								addLogEntry("The shared item stored in OneDrive, has a different name to the actual name on the remote drive", ["debug"]);
								addLogEntry("Updating remoteItem.name JSON data with the actual name being used on account drive and local folder", ["debug"]);
								addLogEntry("remoteItem.name was:              " ~ remoteItem.name, ["debug"]);
								addLogEntry("Updating remoteItem.name to:      " ~ remoteDBItem.name, ["debug"]);
								remoteItem.name = remoteDBItem.name;
								addLogEntry("Setting remoteItem.remoteName to: " ~ onedriveJSONItem["name"].str, ["debug"]);
								
								// Update JSON Item
								remoteItem.remoteName = onedriveJSONItem["name"].str;
								addLogEntry("Updating source JSON 'name' to that which is the actual local directory", ["debug"]);
								addLogEntry("onedriveJSONItem['name'] was:         " ~ onedriveJSONItem["name"].str, ["debug"]);
								addLogEntry("Updating onedriveJSONItem['name'] to: " ~ remoteDBItem.name, ["debug"]);
								onedriveJSONItem["name"] = remoteDBItem.name;
								addLogEntry("onedriveJSONItem['name'] now:         " ~ onedriveJSONItem["name"].str, ["debug"]);
								
								// Update newItemPath value
								newItemPath = computeItemPath(thisItemDriveId, thisItemParentId) ~ "/" ~ remoteDBItem.name;
								addLogEntry("New Item updated calculated full path is: " ~ newItemPath, ["debug"]);
							}
								
							// Add this record to the local database
							addLogEntry("Update/Insert local database with remoteItem details: " ~ to!string(remoteItem), ["debug"]);
							itemDB.upsert(remoteItem);
						} else {
							// Sharepoint account type
							addLogEntry("Handling a SharePoint Shared Item JSON object - NOT IMPLEMENTED YET ........ ", ["info"]);
						}
					}
				}
			}
			
			// Check the skippedItems array for the parent id of this JSONItem if this is something we need to skip
			if (!unwanted) {
				if (thisItemParentId in skippedItems) {
					// Flag this JSON item as unwanted
					addLogEntry("Flagging as unwanted: find(thisItemParentId).length != 0", ["debug"]);
					unwanted = true;
					
					// Is this item id in the database?
					if (existingDBEntry) {
						// item exists in database, most likely moved out of scope for current client configuration
						addLogEntry("This item was previously synced / seen by the client", ["debug"]);
						
						if (("name" in onedriveJSONItem["parentReference"]) != null) {
							
							// How is this out of scope?
							// is sync_list configured
							if (syncListConfigured) {
								// sync_list configured and in use
								if (selectiveSync.isPathExcludedViaSyncList(onedriveJSONItem["parentReference"]["name"].str)) {
									// Previously synced item is now out of scope as it has been moved out of what is included in sync_list
									addLogEntry("This previously synced item is now excluded from being synced due to sync_list exclusion", ["debug"]);
								}
							}
							// flag to delete local file as it now is no longer in sync with OneDrive
							addLogEntry("Flagging to delete item locally: ", ["debug"]);
							idsToDelete ~= [thisItemDriveId, thisItemId];
						}
					}	
				}
			}
			
			// Check the item type - if it not an item type that we support, we cant process the JSON item
			if (!unwanted) {
				if (isItemFile(onedriveJSONItem)) {
					addLogEntry("The item we are syncing is a file", ["debug"]);
				} else if (isItemFolder(onedriveJSONItem)) {
					addLogEntry("The item we are syncing is a folder", ["debug"]);
				} else if (isItemRemote(onedriveJSONItem)) {
					addLogEntry("The item we are syncing is a remote item", ["debug"]);
				} else {
					// Why was this unwanted?
					if (newItemPath.empty) {
						// Compute this item path & need the full path for this file
						newItemPath = computeItemPath(thisItemDriveId, thisItemParentId) ~ "/" ~ thisItemName;
						addLogEntry("New Item calculated full path is: " ~ newItemPath, ["debug"]);
					}
					// Microsoft OneNote container objects present as neither folder or file but has file size
					if ((!isItemFile(onedriveJSONItem)) && (!isItemFolder(onedriveJSONItem)) && (hasFileSize(onedriveJSONItem))) {
						// Log that this was skipped as this was a Microsoft OneNote item and unsupported
						addLogEntry("The Microsoft OneNote Notebook '" ~ newItemPath ~ "' is not supported by this client", ["verbose"]);
					} else {
						// Log that this item was skipped as unsupported 
						addLogEntry("The OneDrive item '" ~ newItemPath ~ "' is not supported by this client", ["verbose"]);
					}
					unwanted = true;
					addLogEntry("Flagging as unwanted: item type is not supported", ["debug"]);
				}
			}
			
			// Check if this is excluded by config option: skip_dir
			if (!unwanted) {
				// Only check path if config is != ""
				if (!appConfig.getValueString("skip_dir").empty) {
					// Is the item a folder?
					if (isItemFolder(onedriveJSONItem)) {
						// work out the 'snippet' path where this folder would be created
						string simplePathToCheck = "";
						string complexPathToCheck = "";
						string matchDisplay = "";
						
						if (hasParentReference(onedriveJSONItem)) {
							// we need to workout the FULL path for this item
							// simple path
							if (("name" in onedriveJSONItem["parentReference"]) != null) {
								simplePathToCheck = onedriveJSONItem["parentReference"]["name"].str ~ "/" ~ onedriveJSONItem["name"].str;
							} else {
								simplePathToCheck = onedriveJSONItem["name"].str;
							}
							addLogEntry("skip_dir path to check (simple):  " ~ simplePathToCheck, ["debug"]);
							
							// complex path
							if (parentInDatabase) {
								// build up complexPathToCheck
								complexPathToCheck = buildNormalizedPath(newItemPath);
							} else {
								addLogEntry("Parent details not in database - unable to compute complex path to check", ["debug"]);
							}
							if (!complexPathToCheck.empty) {
								addLogEntry("skip_dir path to check (complex): " ~ complexPathToCheck, ["debug"]);
							}
						} else {
							simplePathToCheck = onedriveJSONItem["name"].str;
						}
						
						// If 'simplePathToCheck' or 'complexPathToCheck' is of the following format:  root:/folder
						// then isDirNameExcluded matching will not work
						if (simplePathToCheck.canFind(":")) {
							addLogEntry("Updating simplePathToCheck to remove 'root:'", ["debug"]);
							simplePathToCheck = processPathToRemoveRootReference(simplePathToCheck);
						}
						if (complexPathToCheck.canFind(":")) {
							addLogEntry("Updating complexPathToCheck to remove 'root:'", ["debug"]);
							complexPathToCheck = processPathToRemoveRootReference(complexPathToCheck);
						}
						
						// OK .. what checks are we doing?
						if ((!simplePathToCheck.empty) && (complexPathToCheck.empty)) {
							// just a simple check
							addLogEntry("Performing a simple check only", ["debug"]);
							unwanted = selectiveSync.isDirNameExcluded(simplePathToCheck);
						} else {
							// simple and complex
							addLogEntry("Performing a simple then complex path match if required", ["debug"]);
							
							// simple first
							addLogEntry("Performing a simple check first", ["debug"]);
							unwanted = selectiveSync.isDirNameExcluded(simplePathToCheck);
							matchDisplay = simplePathToCheck;
							if (!unwanted) {
								// simple didnt match, perform a complex check
								addLogEntry("Simple match was false, attempting complex match", ["debug"]);
								unwanted = selectiveSync.isDirNameExcluded(complexPathToCheck);
								matchDisplay = complexPathToCheck;
							}
						}
						// result
						addLogEntry("skip_dir exclude result (directory based): " ~ to!string(unwanted), ["debug"]);
						if (unwanted) {
							// This path should be skipped
							addLogEntry("Skipping path - excluded by skip_dir config: " ~ matchDisplay, ["verbose"]);
						}
					}
					// Is the item a file?
					// We need to check to see if this files path is excluded as well
					if (isItemFile(onedriveJSONItem)) {
					
						string pathToCheck;
						// does the newItemPath start with '/'?
						if (!startsWith(newItemPath, "/")){
							// path does not start with '/', but we need to check skip_dir entries with and without '/'
							// so always make sure we are checking a path with '/'
							pathToCheck = '/' ~ dirName(newItemPath);
						} else {
							pathToCheck = dirName(newItemPath);
						}
						
						// perform the check
						unwanted = selectiveSync.isDirNameExcluded(pathToCheck);
						// result
						addLogEntry("skip_dir exclude result (file based): " ~ to!string(unwanted), ["debug"]);
						if (unwanted) {
							// this files path should be skipped
							addLogEntry("Skipping file - file path is excluded by skip_dir config: " ~ newItemPath, ["verbose"]);
						}
					}
				}
			}
			
			// Check if this is excluded by config option: skip_file
			if (!unwanted) {
				// Is the JSON item a file?
				if (isItemFile(onedriveJSONItem)) {
					// skip_file can contain 4 types of entries:
					// - wildcard - *.txt
					// - text + wildcard - name*.txt
					// - full path + combination of any above two - /path/name*.txt
					// - full path to file - /path/to/file.txt
					
					// is the parent id in the database?
					if (parentInDatabase) {
						// Compute this item path & need the full path for this file
						if (newItemPath.empty) {
							newItemPath = computeItemPath(thisItemDriveId, thisItemParentId) ~ "/" ~ thisItemName;
							addLogEntry("New Item calculated full path is: " ~ newItemPath, ["debug"]);
						}
						
						// The path that needs to be checked needs to include the '/'
						// This due to if the user has specified in skip_file an exclusive path: '/path/file' - that is what must be matched
						// However, as 'path' used throughout, use a temp variable with this modification so that we use the temp variable for exclusion checks
						string exclusionTestPath = "";
						if (!startsWith(newItemPath, "/")){
							// Add '/' to the path
							exclusionTestPath = '/' ~ newItemPath;
						}
						
						addLogEntry("skip_file item to check: " ~ exclusionTestPath, ["debug"]);
						unwanted = selectiveSync.isFileNameExcluded(exclusionTestPath);
						addLogEntry("Result: " ~ to!string(unwanted), ["debug"]);
						if (unwanted) addLogEntry("Skipping file - excluded by skip_dir config: " ~ thisItemName, ["verbose"]);
					} else {
						// parent id is not in the database
						unwanted = true;
						addLogEntry("Skipping file - parent path not present in local database", ["verbose"]);
					}
				}
			}
			
			// Check if this is included or excluded by use of sync_list
			if (!unwanted) {
				// No need to try and process something against a sync_list if it has been configured
				if (syncListConfigured) {
					// Compute the item path if empty - as to check sync_list we need an actual path to check
					if (newItemPath.empty) {
						// Calculate this items path
						newItemPath = computeItemPath(thisItemDriveId, thisItemParentId) ~ "/" ~ thisItemName;
						addLogEntry("New Item calculated full path is: " ~ newItemPath, ["debug"]);
					}
					
					// What path are we checking?
					addLogEntry("path to check against 'sync_list' entries: " ~ newItemPath, ["debug"]);
					
					// Unfortunately there is no avoiding this call to check if the path is excluded|included via sync_list
					if (selectiveSync.isPathExcludedViaSyncList(newItemPath)) {
						// selective sync advised to skip, however is this a file and are we configured to upload / download files in the root?
						if ((isItemFile(onedriveJSONItem)) && (appConfig.getValueBool("sync_root_files")) && (rootName(newItemPath) == "") ) {
							// This is a file
							// We are configured to sync all files in the root
							// This is a file in the logical root
							unwanted = false;
						} else {
							// path is unwanted
							unwanted = true;
							addLogEntry("Skipping path - excluded by sync_list config: " ~ newItemPath, ["verbose"]);
							// flagging to skip this item now, but does this exist in the DB thus needs to be removed / deleted?
							if (existingDBEntry) {
								// flag to delete
								addLogEntry("Flagging item for local delete as item exists in database: " ~ newItemPath, ["verbose"]);
								idsToDelete ~= [thisItemDriveId, thisItemId];
							}
						}
					}
				}
			}
			
			// Check if the user has configured to skip downloading .files or .folders: skip_dotfiles
			if (!unwanted) {
				if (appConfig.getValueBool("skip_dotfiles")) {
					if (isDotFile(newItemPath)) {
						addLogEntry("Skipping item - .file or .folder: " ~ newItemPath, ["verbose"]);
						unwanted = true;
					}
				}
			}
			
			// Check if this should be skipped due to a --check-for-nosync directive (.nosync)?
			if (!unwanted) {
				if (appConfig.getValueBool("check_nosync")) {
					// need the parent path for this object
					string parentPath = dirName(newItemPath);
					// Check for the presence of a .nosync in the parent path
					if (exists(parentPath ~ "/.nosync")) {
						addLogEntry("Skipping downloading item - .nosync found in parent folder & --check-for-nosync is enabled: " ~ newItemPath, ["verbose"]);
						unwanted = true;
					}
				}
			}
			
			// Check if this is excluded by a user set maximum filesize to download
			if (!unwanted) {
				if (isItemFile(onedriveJSONItem)) {
					if (fileSizeLimit != 0) {
						if (onedriveJSONItem["size"].integer >= fileSizeLimit) {
							addLogEntry("Skipping file - excluded by skip_size config: " ~ thisItemName ~ " (" ~ to!string(onedriveJSONItem["size"].integer/2^^20) ~ " MB)", ["verbose"]);
							unwanted = true;
						}
					}
				}
			}
			
			// At this point all the applicable checks on this JSON object from OneDrive are complete:
			// - skip_file
			// - skip_dir
			// - sync_list
			// - skip_dotfiles
			// - check_nosync
			// - skip_size
			// - We know if this item exists in the DB or not in the DB
			
			// We know if this JSON item is unwanted or not
			if (unwanted) {
				// This JSON item is NOT wanted - it is excluded
				addLogEntry("Skipping OneDrive change as this is determined to be unwanted", ["debug"]);
				
				// Add to the skippedItems array, but only if it is a directory ... pointless adding 'files' here, as it is the 'id' we check as the parent path which can only be a directory
				if (!isItemFile(onedriveJSONItem)) {
					skippedItems.insert(thisItemId);
				}
			} else {
				// This JSON item is wanted - we need to process this JSON item further
				// Take the JSON item and create a consumable object for eventual database insertion
				Item newDatabaseItem = makeItem(onedriveJSONItem);
				
				if (existingDBEntry) {
					// The details of this JSON item are already in the DB
					// Is the item in the DB the same as the JSON data provided - or is the JSON data advising this is an updated file?
					addLogEntry("OneDrive change is an update to an existing local item", ["debug"]);
					
					// Compute the existing item path
					// NOTE:
					//		string existingItemPath = computeItemPath(existingDatabaseItem.driveId, existingDatabaseItem.id);
					//
					// This will calculate the path as follows:
					//
					//		existingItemPath:     Document.txt
					//
					// Whereas above we use the following
					//
					//		newItemPath = computeItemPath(newDatabaseItem.driveId, newDatabaseItem.parentId) ~ "/" ~ newDatabaseItem.name;
					//
					// Which generates the following path:
					//
					//  	changedItemPath:      ./Document.txt
					// 
					// Need to be consistent here with how 'newItemPath' was calculated
					string queryDriveID;
					string queryParentID;
					
					// Must query with a valid driveid entry
					if (existingDatabaseItem.driveId.empty) {
						queryDriveID = thisItemDriveId;
					} else {
						queryDriveID = existingDatabaseItem.driveId;
					}
					
					// Must query with a valid parentid entry
					if (existingDatabaseItem.parentId.empty) {
						queryParentID = thisItemParentId;
					} else {
						queryParentID = existingDatabaseItem.parentId;
					}
					
					// Calculate the existing path
					string existingItemPath = computeItemPath(queryDriveID, queryParentID) ~ "/" ~ existingDatabaseItem.name;
					addLogEntry("existingItemPath calculated full path is: " ~ existingItemPath, ["debug"]);
					
					// Attempt to apply this changed item
					applyPotentiallyChangedItem(existingDatabaseItem, existingItemPath, newDatabaseItem, newItemPath, onedriveJSONItem);
				} else {
					// Action this JSON item as a new item as we have no DB record of it
					// The actual item may actually exist locally already, meaning that just the database is out-of-date or missing the data due to --resync
					// But we also cannot compute the newItemPath as the parental objects may not exist as well
					addLogEntry("OneDrive change is potentially a new local item", ["debug"]);
					
					// Attempt to apply this potentially new item
					applyPotentiallyNewLocalItem(newDatabaseItem, onedriveJSONItem, newItemPath);
				}
			}
			
			// How long to process this JSON item in batch
			auto jsonProcessingElapsedTime = Clock.currTime() - jsonProcessingStartTime;
			addLogEntry("Batched JSON item processing time: " ~ to!string(jsonProcessingElapsedTime), ["debug"]);
			
			// Tracking as to if this item was processed
			processedCount++;
		}
	}
	
	// Perform the download of any required objects in parallel
	void processDownloadActivities() {
			
		// Are there any items to delete locally? Cleanup space locally first
		if (!idsToDelete.empty) {
			// There are elements that potentially need to be deleted locally
			addLogEntry("Items to potentially delete locally: " ~ to!string(idsToDelete.length), ["verbose"]);
			
			if (appConfig.getValueBool("download_only")) {
				// Download only has been configured
				if (cleanupLocalFiles) {
					// Process online deleted items
					addLogEntry("Processing local deletion activity as --download-only & --cleanup-local-files configured", ["verbose"]);
					processDeleteItems();
				} else {
					// Not cleaning up local files
					addLogEntry("Skipping local deletion activity as --download-only has been used", ["verbose"]);
					// List files and directories we are not deleting locally
					listDeletedItems();
				}
			} else {
				// Not using --download-only process normally
				processDeleteItems();
			}
			// Cleanup array memory
			idsToDelete = [];
		}
		
		// Are there any items to download post fetching and processing the /delta data?
		if (!fileJSONItemsToDownload.empty) {
			// There are elements to download
			addLogEntry("Number of items to download from Microsoft OneDrive: " ~ to!string(fileJSONItemsToDownload.length));
			downloadOneDriveItems();
			// Cleanup array memory
			fileJSONItemsToDownload = [];
		}
		
		// Are there any skipped items still?
		if (!skippedItems.empty) {
			// Cleanup array memory
			skippedItems.clear();
		}
		
		// If deltaLinkCache.latestDeltaLink is not empty, update the deltaLink in the database for this driveId so that we can reuse this now that jsonItemsToProcess has been fully processed
		if (!deltaLinkCache.latestDeltaLink.empty) {
			addLogEntry("Updating completed deltaLink for driveID " ~ deltaLinkCache.driveId ~ " in DB to: " ~ deltaLinkCache.latestDeltaLink, ["debug"]);
			itemDB.setDeltaLink(deltaLinkCache.driveId, deltaLinkCache.itemId, deltaLinkCache.latestDeltaLink);
			
			// Now that the DB is updated, when we perform the last examination of the most recent online data, cache this so this can be obtained this from memory
			cacheLatestDeltaLink(deltaLinkInfo, deltaLinkCache.driveId, deltaLinkCache.latestDeltaLink);		
		}
	}
	
	// Function to add or update a key pair in the deltaLinkInfo array
	void cacheLatestDeltaLink(ref DeltaLinkInfo deltaLinkInfo, string driveId, string latestDeltaLink) {
		if (driveId !in deltaLinkInfo) {
			addLogEntry("Added new latestDeltaLink entry: " ~ driveId ~ " -> " ~ latestDeltaLink, ["debug"]);
		} else {
			addLogEntry("Updated latestDeltaLink entry for " ~ driveId ~ " from " ~ deltaLinkInfo[driveId] ~ " to " ~ latestDeltaLink, ["debug"]);
		}
		deltaLinkInfo[driveId] = latestDeltaLink;
	}
	
	// Function to get the latestDeltaLink based on driveId
	string getDeltaLinkFromCache(ref DeltaLinkInfo deltaLinkInfo, string driveId) {
		string cachedDeltaLink;
		if (driveId in deltaLinkInfo) {
			cachedDeltaLink = deltaLinkInfo[driveId];
		}
		return cachedDeltaLink;
	}
	
	// If the JSON item is not in the database, it is potentially a new item that we need to action
	void applyPotentiallyNewLocalItem(Item newDatabaseItem, JSONValue onedriveJSONItem, string newItemPath) {
			
		// The JSON and Database items being passed in here have passed the following checks:
		// - skip_file
		// - skip_dir
		// - sync_list
		// - skip_dotfiles
		// - check_nosync
		// - skip_size
		// - Is not currently cached in the local database
		// As such, we should not be doing any other checks here to determine if the JSON item is wanted .. it is
		
		if (exists(newItemPath)) {
			addLogEntry("Path on local disk already exists", ["debug"]);
			// Issue #2209 fix - test if path is a bad symbolic link
			if (isSymlink(newItemPath)) {
				addLogEntry("Path on local disk is a symbolic link ........", ["debug"]);
				if (!exists(readLink(newItemPath))) {
					// reading the symbolic link failed	
					addLogEntry("Reading the symbolic link target failed ........ ", ["debug"]);
					addLogEntry("Skipping item - invalid symbolic link: " ~ newItemPath, ["info", "notify"]);
					return;
				}
			}
			
			// Path exists locally, is not a bad symbolic link
			// Test if this item is actually in-sync
			// What is the source of this item data?
			string itemSource = "remote";
			if (isItemSynced(newDatabaseItem, newItemPath, itemSource)) {
				// Item details from OneDrive and local item details in database are in-sync
				addLogEntry("The item to sync is already present on the local filesystem and is in-sync with what is reported online", ["debug"]);
				addLogEntry("Update/Insert local database with item details: " ~ to!string(newDatabaseItem), ["debug"]);
				itemDB.upsert(newDatabaseItem);
				return;
			} else {
				// Item details from OneDrive and local item details in database are NOT in-sync
				addLogEntry("The item to sync exists locally but is potentially not in the local database - otherwise this would be handled as changed item", ["debug"]);
				
				// Which object is newer? The local file or the remote file?
				SysTime localModifiedTime = timeLastModified(newItemPath).toUTC();
				SysTime itemModifiedTime = newDatabaseItem.mtime;
				// Reduce time resolution to seconds before comparing
				localModifiedTime.fracSecs = Duration.zero;
				itemModifiedTime.fracSecs = Duration.zero;
				
				// Is the local modified time greater than that from OneDrive?
				if (localModifiedTime > itemModifiedTime) {
					// Local file is newer than item on OneDrive based on file modified time
					// Is this item id in the database?
					if (itemDB.idInLocalDatabase(newDatabaseItem.driveId, newDatabaseItem.id)) {
						// item id is in the database
						// no local rename
						// no download needed
						
						// Fetch the latest DB record - as this could have been updated by the isItemSynced if the date online was being corrected, then the DB updated as a result
						Item latestDatabaseItem;
						itemDB.selectById(newDatabaseItem.driveId, newDatabaseItem.id, latestDatabaseItem);
						addLogEntry("latestDatabaseItem: " ~ to!string(latestDatabaseItem), ["debug"]);
						
						SysTime latestItemModifiedTime = latestDatabaseItem.mtime;
						// Reduce time resolution to seconds before comparing
						latestItemModifiedTime.fracSecs = Duration.zero;
						
						if (localModifiedTime == latestItemModifiedTime) {
							// Log action
							addLogEntry("Local file modified time matches existing database record - keeping local file", ["verbose"]);
							addLogEntry("Skipping OneDrive change as this is determined to be unwanted due to local file modified time matching database data", ["debug"]);
						} else {
							// Log action
							addLogEntry("Local file modified time is newer based on UTC time conversion - keeping local file as this exists in the local database", ["verbose"]);
							addLogEntry("Skipping OneDrive change as this is determined to be unwanted due to local file modified time being newer than OneDrive file and present in the sqlite database", ["debug"]);
						}
						// Return as no further action needed
						return;
					} else {
						// item id is not in the database .. maybe a --resync ?
						// file exists locally but is not in the sqlite database - maybe a failed download?
						addLogEntry("Local item does not exist in local database - replacing with file from OneDrive - failed download?", ["verbose"]);
						
						// In a --resync scenario or if items.sqlite3 was deleted before startup we have zero way of knowing IF the local file is meant to be the right file
						// To this pint we have passed the following checks:
						// 1. Any client side filtering checks - this determined this is a file that is wanted
						// 2. A file with the exact name exists locally
						// 3. The local modified time > remote modified time
						// 4. The id of the item from OneDrive is not in the database
						
						// Has the user configured to IGNORE local data protection rules?
						if (bypassDataPreservation) {
							// The user has configured to ignore data safety checks and overwrite local data rather than preserve & safeBackup
							addLogEntry("WARNING: Local Data Protection has been disabled. You may experience data loss on this file: " ~ newItemPath, ["info", "notify"]);
						} else {
							// local data protection is configured, safeBackup the local file, passing in if we are performing a --dry-run or not
							// In case the renamed path is needed
							string renamedPath;
							safeBackup(newItemPath, dryRun, renamedPath);
						}
					}
				} else {
					// Is the remote newer?
					if (localModifiedTime < itemModifiedTime) {
						// Remote file is newer than the existing local item
						addLogEntry("Remote item modified time is newer based on UTC time conversion", ["verbose"]); // correct message, remote item is newer
						addLogEntry("localModifiedTime (local file):   " ~ to!string(localModifiedTime), ["debug"]);
						addLogEntry("itemModifiedTime (OneDrive item): " ~ to!string(itemModifiedTime), ["debug"]);
						
						// Has the user configured to IGNORE local data protection rules?
						if (bypassDataPreservation) {
							// The user has configured to ignore data safety checks and overwrite local data rather than preserve & safeBackup
							addLogEntry("WARNING: Local Data Protection has been disabled. You may experience data loss on this file: " ~ newItemPath, ["info", "notify"]);
						} else {
							// local data protection is configured, safeBackup the local file, passing in if we are performing a --dry-run or not
							// In case the renamed path is needed
							string renamedPath;
							safeBackup(newItemPath, dryRun, renamedPath);							
						}
					}
					
					// Are the timestamps equal?
					if (localModifiedTime == itemModifiedTime) {
						// yes they are equal
						addLogEntry("File timestamps are equal, no further action required", ["debug"]); // correct message as timestamps are equal
						addLogEntry("Update/Insert local database with item details: " ~ to!string(newDatabaseItem), ["debug"]);
						itemDB.upsert(newDatabaseItem);
						return;
					}
				}
			}
		} 
			
		// Path does not exist locally (should not exist locally if renamed file) - this will be a new file download or new folder creation
		// How to handle this Potentially New Local Item JSON ?
		final switch (newDatabaseItem.type) {
			case ItemType.file:
				// Add to the file to the download array for processing later
				fileJSONItemsToDownload ~= onedriveJSONItem;
				break;
			case ItemType.dir:
				// Create the directory immediately as we depend on its entry existing
				handleLocalDirectoryCreation(newDatabaseItem, newItemPath, onedriveJSONItem);
				break;
			case ItemType.remote:
				// Add to the directory and relevant detils for processing later
				if (newDatabaseItem.remoteType == ItemType.dir) {
					handleLocalDirectoryCreation(newDatabaseItem, newItemPath, onedriveJSONItem);
				} else {
					// Add to the file to the download array for processing later
					fileJSONItemsToDownload ~= onedriveJSONItem;
				}
				break;
			case ItemType.unknown:
			case ItemType.none:
				// Unknown type - we dont action or sync these items
				break;
		}
	}
	
	// Handle the creation of a new local directory
	void handleLocalDirectoryCreation(Item newDatabaseItem, string newItemPath, JSONValue onedriveJSONItem) {
		// To create a path, 'newItemPath' must not be empty
		if (!newItemPath.empty) {
			// Update the logging output to be consistent
			addLogEntry("Creating local directory: " ~ "./" ~ buildNormalizedPath(newItemPath), ["verbose"]);
			if (!dryRun) {
				try {
					// Create the new directory
					addLogEntry("Requested path does not exist, creating directory structure: " ~ newItemPath, ["debug"]);
					mkdirRecurse(newItemPath);
					// Configure the applicable permissions for the folder
					addLogEntry("Setting directory permissions for: " ~ newItemPath, ["debug"]);
					newItemPath.setAttributes(appConfig.returnRequiredDirectoryPermisions());
					// Update the time of the folder to match the last modified time as is provided by OneDrive
					// If there are any files then downloaded into this folder, the last modified time will get 
					// updated by the local Operating System with the latest timestamp - as this is normal operation
					// as the directory has been modified
					addLogEntry("Setting directory lastModifiedDateTime for: " ~ newItemPath ~ " to " ~ to!string(newDatabaseItem.mtime), ["debug"]);
					addLogEntry("Calling setTimes() for this directory: " ~ newItemPath, ["debug"]);
					setTimes(newItemPath, newDatabaseItem.mtime, newDatabaseItem.mtime);
					// Save the item to the database
					saveItem(onedriveJSONItem);
				} catch (FileException e) {
					// display the error message
					displayFileSystemErrorMessage(e.msg, getFunctionName!({}));
				}
			} else {
				// we dont create the directory, but we need to track that we 'faked it'
				idsFaked ~= [newDatabaseItem.driveId, newDatabaseItem.id];
				// Save the item to the dry-run database
				saveItem(onedriveJSONItem);
			}
		}
	}
	
	// If the JSON item IS in the database, this will be an update to an existing in-sync item
	void applyPotentiallyChangedItem(Item existingDatabaseItem, string existingItemPath, Item changedOneDriveItem, string changedItemPath, JSONValue onedriveJSONItem) {
				
		// If we are moving the item, we do not need to download it again
		bool itemWasMoved = false;
		
		// Do we need to actually update the database with the details that were provided by the OneDrive API?
		// Calculate these time items from the provided items
		SysTime existingItemModifiedTime = existingDatabaseItem.mtime;
		existingItemModifiedTime.fracSecs = Duration.zero;
		SysTime changedOneDriveItemModifiedTime = changedOneDriveItem.mtime;
		changedOneDriveItemModifiedTime.fracSecs = Duration.zero;
		
		// Did the eTag change?
		if (existingDatabaseItem.eTag != changedOneDriveItem.eTag) {
			// The eTag has changed to what we previously cached
			if (existingItemPath != changedItemPath) {
				// Log that we are changing / moving an item to a new name
				addLogEntry("Moving " ~ existingItemPath ~ " to " ~ changedItemPath);
				// Is the destination path empty .. or does something exist at that location?
				if (exists(changedItemPath)) {
					// Destination we are moving to exists ... 
					Item changedLocalItem;
					// Query DB for this changed item in specified path that exists and see if it is in-sync
					if (itemDB.selectByPath(changedItemPath, changedOneDriveItem.driveId, changedLocalItem)) {
						// The 'changedItemPath' is in the database
						string itemSource = "database";
						if (isItemSynced(changedLocalItem, changedItemPath, itemSource)) {
							// The destination item is in-sync
							addLogEntry("Destination is in sync and will be overwritten", ["verbose"]);
						} else {
							// The destination item is different
							addLogEntry("The destination is occupied with a different item, renaming the conflicting file...", ["verbose"]);
							// Backup this item, passing in if we are performing a --dry-run or not
							// In case the renamed path is needed
							string renamedPath;
							safeBackup(changedItemPath, dryRun, renamedPath);
						}
					} else {
						// The to be overwritten item is not already in the itemdb, so it should saved to avoid data loss
						addLogEntry("The destination is occupied by an existing un-synced file, renaming the conflicting file...", ["verbose"]);
						// Backup this item, passing in if we are performing a --dry-run or not
						// In case the renamed path is needed
						string renamedPath;
						safeBackup(changedItemPath, dryRun, renamedPath);
					}
				}
				
				// Try and rename path, catch any exception generated
				try {
					// If we are in a --dry-run situation? , the actual rename did not occur - but we need to track like it did
					if(!dryRun) {
						// Rename this item, passing in if we are performing a --dry-run or not
						safeRename(existingItemPath, changedItemPath, dryRun);
					
						// Flag that the item was moved | renamed
						itemWasMoved = true;
					
						// If the item is a file, make sure that the local timestamp now is the same as the timestamp online
						// Otherwise when we do the DB check, the move on the file system, the file technically has a newer timestamp
						// which is 'correct' .. but we need to report locally the online timestamp here as the move was made online
						if (changedOneDriveItem.type == ItemType.file) {
							// Set the timestamp
							addLogEntry("Calling setTimes() for this file: " ~ changedItemPath, ["debug"]);
							setTimes(changedItemPath, changedOneDriveItem.mtime, changedOneDriveItem.mtime);
						}
					} else {
						// --dry-run situation - the actual rename did not occur - but we need to track like it did
						// Track this as a faked id item
						idsFaked ~= [changedOneDriveItem.driveId, changedOneDriveItem.id];
						// We also need to track that we did not rename this path
						pathsRenamed ~= [existingItemPath];
					}
				} catch (FileException e) {
					// display the error message
					displayFileSystemErrorMessage(e.msg, getFunctionName!({}));
				}
			}
			
			// What sort of changed item is this?
			// Is it a file or remote file, and we did not move it ..
			if (((changedOneDriveItem.type == ItemType.file) && (!itemWasMoved)) || (((changedOneDriveItem.type == ItemType.remote) && (changedOneDriveItem.remoteType == ItemType.file)) && (!itemWasMoved))) {
				// The eTag is notorious for being 'changed' online by some backend Microsoft process
				if (existingDatabaseItem.quickXorHash != changedOneDriveItem.quickXorHash) {
					// Add to the items to download array for processing - the file hash we previously recorded is not the same as online
					fileJSONItemsToDownload ~= onedriveJSONItem;
				} else {
					// If the timestamp is different, or we are running a client operational mode that does not support /delta queries - we have to update the DB with the details from OneDrive
					// Unfortunately because of the consequence of Nataional Cloud Deployments not supporting /delta queries, the application uses the local database to flag what is out-of-date / track changes
					// This means that the constant disk writing to the database fix implemented with https://github.com/abraunegg/onedrive/pull/2004 cannot be utilised when using these operational modes
					// as all records are touched / updated when performing the OneDrive sync operations. The impacted operational modes are:
					// - National Cloud Deployments do not support /delta as a query
					// - When using --single-directory
					// - When using --download-only --cleanup-local-files
				
					// Is the last modified timestamp in the DB the same as the API data or are we running an operational mode where we simulated the /delta response?
					if ((existingItemModifiedTime != changedOneDriveItemModifiedTime) || (generateSimulatedDeltaResponse)) {
					// Save this item in the database
						// Add to the local database
						addLogEntry("Adding changed OneDrive Item to database: " ~ to!string(changedOneDriveItem), ["debug"]);
						itemDB.upsert(changedOneDriveItem);
					}
				}
			} else {
				// Save this item in the database
				saveItem(onedriveJSONItem);
				
				// If the 'Add shortcut to My files' link was the item that was actually renamed .. we have to update our DB records
				if (changedOneDriveItem.type == ItemType.remote) {
					// Select remote item data from the database
					Item existingRemoteDbItem;
					itemDB.selectById(changedOneDriveItem.remoteDriveId, changedOneDriveItem.remoteId, existingRemoteDbItem);
					// Update the 'name' in existingRemoteDbItem and save it back to the database
					// This is the local name stored on disk that was just 'moved'
					existingRemoteDbItem.name = changedOneDriveItem.name;
					itemDB.upsert(existingRemoteDbItem);
				}
			}
		} else {
			// The existingDatabaseItem.eTag == changedOneDriveItem.eTag .. nothing has changed eTag wise
			
			// If the timestamp is different, or we are running a client operational mode that does not support /delta queries - we have to update the DB with the details from OneDrive
			// Unfortunately because of the consequence of Nataional Cloud Deployments not supporting /delta queries, the application uses the local database to flag what is out-of-date / track changes
			// This means that the constant disk writing to the database fix implemented with https://github.com/abraunegg/onedrive/pull/2004 cannot be utilised when using these operational modes
			// as all records are touched / updated when performing the OneDrive sync operations. The impacted operational modes are:
			// - National Cloud Deployments do not support /delta as a query
			// - When using --single-directory
			// - When using --download-only --cleanup-local-files
		
			// Is the last modified timestamp in the DB the same as the API data or are we running an operational mode where we simulated the /delta response?
			if ((existingItemModifiedTime != changedOneDriveItemModifiedTime) || (generateSimulatedDeltaResponse)) {
				// Database update needed for this item because our local record is out-of-date
				// Add to the local database
				addLogEntry("Adding changed OneDrive Item to database: " ~ to!string(changedOneDriveItem), ["debug"]);
				itemDB.upsert(changedOneDriveItem);
			}
		}
	}
	
	// Download new file items as identified
	void downloadOneDriveItems() {
		// Lets deal with all the JSON items that need to be downloaded in a batch process
		size_t batchSize = to!int(appConfig.getValueLong("threads"));
		ulong batchCount = (fileJSONItemsToDownload.length + batchSize - 1) / batchSize;
		ulong batchesProcessed = 0;
		
		foreach (chunk; fileJSONItemsToDownload.chunks(batchSize)) {
			// send an array containing 'appConfig.getValueLong("threads")' JSON items to download
			downloadOneDriveItemsInParallel(chunk);
		}
	}
	
	// Download items in parallel
	void downloadOneDriveItemsInParallel(JSONValue[] array) {
		// This function received an array of JSON items to download, the number of elements based on appConfig.getValueLong("threads")
		foreach (i, onedriveJSONItem; processPool.parallel(array)) {
			// Take each JSON item and 
			downloadFileItem(onedriveJSONItem);
		}
	}
	
	// Perform the actual download of an object from OneDrive
	void downloadFileItem(JSONValue onedriveJSONItem) {
				
		bool downloadFailed = false;
		string OneDriveFileXORHash;
		string OneDriveFileSHA256Hash;
		ulong jsonFileSize = 0;
		Item databaseItem;
		bool fileFoundInDB = false;
		
		// Download item specifics
		string downloadItemId = onedriveJSONItem["id"].str;
		string downloadItemName = onedriveJSONItem["name"].str;
		string downloadDriveId = onedriveJSONItem["parentReference"]["driveId"].str;
		string downloadParentId = onedriveJSONItem["parentReference"]["id"].str;
		
		// Calculate this items path
		string newItemPath = computeItemPath(downloadDriveId, downloadParentId) ~ "/" ~ downloadItemName;
		addLogEntry("JSON Item calculated full path for download is: " ~ newItemPath, ["debug"]);
		
		// Is the item reported as Malware ?
		if (isMalware(onedriveJSONItem)){
			// OneDrive reports that this file is malware
			addLogEntry("ERROR: MALWARE DETECTED IN FILE - DOWNLOAD SKIPPED: " ~ newItemPath, ["info", "notify"]);
			downloadFailed = true;
		} else {
			// Grab this file's filesize
			if (hasFileSize(onedriveJSONItem)) {
				// Use the configured filesize as reported by OneDrive
				jsonFileSize = onedriveJSONItem["size"].integer;
			} else {
				// filesize missing
				addLogEntry("ERROR: onedriveJSONItem['size'] is missing", ["debug"]);
			}
			
			// Configure the hashes for comparison post download
			if (hasHashes(onedriveJSONItem)) {
				// File details returned hash details
				// QuickXorHash
				if (hasQuickXorHash(onedriveJSONItem)) {
					// Use the provided quickXorHash as reported by OneDrive
					if (onedriveJSONItem["file"]["hashes"]["quickXorHash"].str != "") {
						OneDriveFileXORHash = onedriveJSONItem["file"]["hashes"]["quickXorHash"].str;
					}
				} else {
					// Fallback: Check for SHA256Hash
					if (hasSHA256Hash(onedriveJSONItem)) {
						// Use the provided sha256Hash as reported by OneDrive
						if (onedriveJSONItem["file"]["hashes"]["sha256Hash"].str != "") {
							OneDriveFileSHA256Hash = onedriveJSONItem["file"]["hashes"]["sha256Hash"].str;
						}
					}
				}
			} else {
				// file hash data missing
				addLogEntry("ERROR: onedriveJSONItem['file']['hashes'] is missing - unable to compare file hash after download", ["debug"]);
			}
		
			// Does the file already exist in the path locally?
			if (exists(newItemPath)) {
				// file exists locally already
				foreach (driveId; onlineDriveDetails.keys) {
					if (itemDB.selectByPath(newItemPath, driveId, databaseItem)) {
						fileFoundInDB = true;
						break;
					}
				}
				
				// Log the DB details
				addLogEntry("File to download exists locally and this is the DB record: " ~ to!string(databaseItem), ["debug"]);
				
				// Does the DB (what we think is in sync) hash match the existing local file hash?
				if (!testFileHash(newItemPath, databaseItem)) {
					// local file is different to what we know to be true
					addLogEntry("The local file to replace (" ~ newItemPath ~ ") has been modified locally since the last download. Renaming it to avoid potential local data loss.");
					
					// Perform the local safeBackup of the existing local file, passing in if we are performing a --dry-run or not
					// In case the renamed path is needed
					string renamedPath;
					safeBackup(newItemPath, dryRun, renamedPath);
				}
			}
			
			// Is there enough free space locally to download the file
			// - We can use '.' here as we change the current working directory to the configured 'sync_dir'
			ulong localActualFreeSpace = to!ulong(getAvailableDiskSpace("."));
			// So that we are not responsible in making the disk 100% full if we can download the file, compare the current available space against the reservation set and file size
			// The reservation value is user configurable in the config file, 50MB by default
			ulong freeSpaceReservation = appConfig.getValueLong("space_reservation");
			// debug output
			addLogEntry("Local Disk Space Actual: " ~ to!string(localActualFreeSpace), ["debug"]);
			addLogEntry("Free Space Reservation:  " ~ to!string(freeSpaceReservation), ["debug"]);
			addLogEntry("File Size to Download:   " ~ to!string(jsonFileSize), ["debug"]);
			
			// Calculate if we can actually download file - is there enough free space?
			if ((localActualFreeSpace < freeSpaceReservation) || (jsonFileSize > localActualFreeSpace)) {
				// localActualFreeSpace is less than freeSpaceReservation .. insufficient free space
				// jsonFileSize is greater than localActualFreeSpace .. insufficient free space
				addLogEntry("Downloading file: " ~ newItemPath ~ " ... failed!");
				addLogEntry("Insufficient local disk space to download file");
				downloadFailed = true;
			} else {
				// If we are in a --dry-run situation - if not, actually perform the download
				if (!dryRun) {
					// Attempt to download the file as there is enough free space locally
					OneDriveApi downloadFileOneDriveApiInstance;
					
					try {	
						// Initialise API instance
						downloadFileOneDriveApiInstance = new OneDriveApi(appConfig);
						downloadFileOneDriveApiInstance.initialise();
						
						// OneDrive Business Shared Files - update the driveId where to get the file from
						if (isItemRemote(onedriveJSONItem)) {
							downloadDriveId = onedriveJSONItem["remoteItem"]["parentReference"]["driveId"].str;
						}
						
						// Perform the download
						downloadFileOneDriveApiInstance.downloadById(downloadDriveId, downloadItemId, newItemPath, jsonFileSize);
						
						// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
						downloadFileOneDriveApiInstance.releaseCurlEngine();
						downloadFileOneDriveApiInstance = null;
						// Perform Garbage Collection
						GC.collect();
						
					} catch (OneDriveException exception) {
						addLogEntry("downloadFileOneDriveApiInstance.downloadById(downloadDriveId, downloadItemId, newItemPath, jsonFileSize); generated a OneDriveException", ["debug"]);
						string thisFunctionName = getFunctionName!({});
						
						// HTTP request returned status code 403
						if ((exception.httpStatusCode == 403) && (appConfig.getValueBool("sync_business_shared_files"))) {
							// We attempted to download a file, that was shared with us, but this was shared with us as read-only and no download permission
							addLogEntry("Unable to download this file as this was shared as read-only without download permission: " ~ newItemPath);
							downloadFailed = true;
						} else {
							// Default operation if not a 403 error
							// - 408,429,503,504 errors are handled as a retry within downloadFileOneDriveApiInstance
							// Display what the error is
							displayOneDriveErrorMessage(exception.msg, getFunctionName!({}));
						}
					} catch (FileException e) {
						// There was a file system error
						// display the error message
						displayFileSystemErrorMessage(e.msg, getFunctionName!({}));
						downloadFailed = true;
					} catch (ErrnoException e) {
						// There was a file system error
						// display the error message
						displayFileSystemErrorMessage(e.msg, getFunctionName!({}));
						downloadFailed = true;
					}
				
					// If we get to this point, something was downloaded .. does it match what we expected?
					if (exists(newItemPath)) {
						// When downloading some files from SharePoint, the OneDrive API reports one file size, 
						// but the SharePoint HTTP Server sends a totally different byte count for the same file
						// we have implemented --disable-download-validation to disable these checks
					
						if (!disableDownloadValidation) {
							// A 'file' was downloaded - does what we downloaded = reported jsonFileSize or if there is some sort of funky local disk compression going on
							// Does the file hash OneDrive reports match what we have locally?
							string onlineFileHash;
							string downloadedFileHash;
							ulong downloadFileSize = getSize(newItemPath);
							
							if (!OneDriveFileXORHash.empty) {
								onlineFileHash = OneDriveFileXORHash;
								// Calculate the QuickXOHash for this file
								downloadedFileHash = computeQuickXorHash(newItemPath);
							} else {
								onlineFileHash = OneDriveFileSHA256Hash;
								// Fallback: Calculate the SHA256 Hash for this file
								downloadedFileHash = computeSHA256Hash(newItemPath);
							}
							
							if ((downloadFileSize == jsonFileSize) && (downloadedFileHash == onlineFileHash)) {
								// Downloaded file matches size and hash
								addLogEntry("Downloaded file matches reported size and reported file hash", ["debug"]);
								
								try {
									// get the mtime from the JSON data
									SysTime itemModifiedTime;
									if (isItemRemote(onedriveJSONItem)) {
										// remote file item
										itemModifiedTime = SysTime.fromISOExtString(onedriveJSONItem["remoteItem"]["fileSystemInfo"]["lastModifiedDateTime"].str);
									} else {
										// not a remote item
										itemModifiedTime = SysTime.fromISOExtString(onedriveJSONItem["fileSystemInfo"]["lastModifiedDateTime"].str);
									}
									
									// set the correct time on the downloaded file
									if (!dryRun) {
										addLogEntry("Calling setTimes() for this file: " ~ newItemPath, ["debug"]);
										setTimes(newItemPath, itemModifiedTime, itemModifiedTime);
									}
								} catch (FileException e) {
									// display the error message
									displayFileSystemErrorMessage(e.msg, getFunctionName!({}));
								}
							} else {
								// Downloaded file does not match size or hash .. which is it?
								bool downloadValueMismatch = false;
								
								// Size error?
								if (downloadFileSize != jsonFileSize) {
									// downloaded file size does not match
									downloadValueMismatch = true;
									addLogEntry("Actual file size on disk:   " ~ to!string(downloadFileSize), ["debug"]);
									addLogEntry("OneDrive API reported size: " ~ to!string(jsonFileSize), ["debug"]);
									addLogEntry("ERROR: File download size mismatch. Increase logging verbosity to determine why.");
								}
								
								// Hash Error
								if (downloadedFileHash != onlineFileHash) {
									// downloaded file hash does not match
									downloadValueMismatch = true;
									addLogEntry("Actual local file hash:     " ~ downloadedFileHash, ["debug"]);
									addLogEntry("OneDrive API reported hash: " ~ onlineFileHash, ["debug"]);
									addLogEntry("ERROR: File download hash mismatch. Increase logging verbosity to determine why.");
								}
								
								// .heic data loss check
								// - https://github.com/abraunegg/onedrive/issues/2471
								// - https://github.com/OneDrive/onedrive-api-docs/issues/1532
								// - https://github.com/OneDrive/onedrive-api-docs/issues/1723
								if (downloadValueMismatch && (toLower(extension(newItemPath)) == ".heic")) {
									// Need to display a message to the user that they have experienced data loss
									addLogEntry("DATA-LOSS: File downloaded has experienced data loss due to a Microsoft OneDrive API bug. DO NOT DELETE THIS FILE ONLINE: " ~ newItemPath, ["info", "notify"]);
									addLogEntry("           Please read https://github.com/OneDrive/onedrive-api-docs/issues/1723 for more details.", ["verbose"]);
								}
								
								// Add some workaround messaging for SharePoint
								if (appConfig.accountType == "documentLibrary"){
									// It has been seen where SharePoint / OneDrive API reports one size via the JSON 
									// but the content length and file size written to disk is totally different - example:
									// From JSON:         "size": 17133
									// From HTTPS Server: < Content-Length: 19340
									// with no logical reason for the difference, except for a 302 redirect before file download
									addLogEntry("INFO: It is most likely that a SharePoint OneDrive API issue is the root cause. Add --disable-download-validation to work around this issue but downloaded data integrity cannot be guaranteed.");
								} else {
									// other account types
									addLogEntry("INFO: Potentially add --disable-download-validation to work around this issue but downloaded data integrity cannot be guaranteed.");
								}
								
								// If the computed hash does not equal provided online hash, consider this a failed download
								if (downloadedFileHash != onlineFileHash) {
									// We do not want this local file to remain on the local file system as it failed the integrity checks
									addLogEntry("Removing local file " ~ newItemPath ~ " due to failed integrity checks");
									if (!dryRun) {
										safeRemove(newItemPath);
									}
									
									// Was this item previously in-sync with the local system?
									// We previously searched for the file in the DB, we need to use that record
									if (fileFoundInDB) {
										// Purge DB record so that the deleted local file does not cause an online delete
										// In a --dry-run scenario, this is being done against a DB copy
										addLogEntry("Removing DB record due to failed integrity checks");
										itemDB.deleteById(databaseItem.driveId, databaseItem.id);
									}
									
									// Flag that the download failed
									downloadFailed = true;
								}
							}
						} else {
							// Download validation checks were disabled
							addLogEntry("Downloaded file validation disabled due to --disable-download-validation", ["debug"]);
							addLogEntry("WARNING: Skipping download integrity check for: " ~ newItemPath, ["verbose"]);
						}	 // end of (!disableDownloadValidation)
					} else {
						addLogEntry("ERROR: File failed to download. Increase logging verbosity to determine why.");
						downloadFailed = true;
					}
				}
			}
			
			// File should have been downloaded
			if (!downloadFailed) {
				// Download did not fail
				addLogEntry("Downloading file: " ~ newItemPath ~ " ... done");
				// Save this item into the database
				saveItem(onedriveJSONItem);
				
				// If we are in a --dry-run situation - if we are, we need to track that we faked the download
				if (dryRun) {
					// track that we 'faked it'
					idsFaked ~= [downloadDriveId, downloadItemId];
				}
				
				// If, the initial download failed, but, during the 'Performing a last examination of the most recent online data within Microsoft OneDrive' Process
				// the file downloads without issue, check if the path is in 'fileDownloadFailures' and if this is in this array, remove this entry as it is technically no longer valid to be in there
				if (canFind(fileDownloadFailures, newItemPath)) {
					// Remove 'newItemPath' from 'fileDownloadFailures' as this is no longer a failed download
					fileDownloadFailures = fileDownloadFailures.filter!(item => item != newItemPath).array;
				}
			} else {
				// Output download failed
				addLogEntry("Downloading file: " ~ newItemPath ~ " ... failed!");
				// Add the path to a list of items that failed to download
				if (!canFind(fileDownloadFailures, newItemPath)) {
					fileDownloadFailures ~= newItemPath; // Add newItemPath if it's not already present
				}
			}
		}
	}
	
	// Test if the given item is in-sync. Returns true if the given item corresponds to the local one
	bool isItemSynced(Item item, string path, string itemSource) {
		if (!exists(path)) return false;

		// Combine common logic for readability and file check into a single block
		if (item.type == ItemType.file || ((item.type == ItemType.remote) && (item.remoteType == ItemType.file))) {
			// Can we actually read the local file?
			if (!readLocalFile(path)) {
				// Unable to read local file
				addLogEntry("Unable to determine the sync state of this file as it cannot be read (file permissions or file corruption): " ~ path);
				return false;
			}
			
			// Get time values
			SysTime localModifiedTime = timeLastModified(path).toUTC();
			SysTime itemModifiedTime = item.mtime;
			// Reduce time resolution to seconds before comparing
			localModifiedTime.fracSecs = Duration.zero;
			itemModifiedTime.fracSecs = Duration.zero;

			if (localModifiedTime == itemModifiedTime) {
				return true;
			} else {
				// The file has a different timestamp ... is the hash the same meaning no file modification?
				addLogEntry("Local file time discrepancy detected: " ~ path, ["verbose"]);
				addLogEntry("This local file has a different modified time " ~ to!string(localModifiedTime) ~ " (UTC) when compared to " ~ itemSource ~ " modified time " ~ to!string(itemModifiedTime) ~ " (UTC)", ["verbose"]);

				// The file has a different timestamp ... is the hash the same meaning no file modification?
				// Test the file hash as the date / time stamp is different
				// Generating a hash is computationally expensive - we only generate the hash if timestamp was different
				if (testFileHash(path, item)) {
					// The hash is the same .. so we need to fix-up the timestamp depending on where it is wrong
					addLogEntry("Local item has the same hash value as the item online - correcting the applicable file timestamp", ["verbose"]);
					// Correction logic based on the configuration and the comparison of timestamps
					if (localModifiedTime > itemModifiedTime) {
						// Local file is newer .. are we in a --download-only situation?
						if (!appConfig.getValueBool("download_only") && !dryRun) {
							// The source of the out-of-date timestamp was OneDrive and this needs to be corrected to avoid always generating a hash test if timestamp is different
							addLogEntry("The source of the incorrect timestamp was OneDrive online - correcting timestamp online", ["verbose"]);
							// Attempt to update the online date time stamp
							// We need to use the correct driveId and itemId, especially if we are updating a OneDrive Business Shared File timestamp
							if (item.type == ItemType.file) {
								// Not a remote file
								uploadLastModifiedTime(item, item.driveId, item.id, localModifiedTime, item.eTag);
							} else {
								// Remote file, remote values need to be used
								uploadLastModifiedTime(item, item.remoteDriveId, item.remoteId, localModifiedTime, item.eTag);
							}
						} else if (!dryRun) {
							// --download-only is being used ... local file needs to be corrected ... but why is it newer - indexing application potentially changing the timestamp ?
							addLogEntry("The source of the incorrect timestamp was the local file - correcting timestamp locally due to --download-only", ["verbose"]);
							// Fix the local file timestamp
							addLogEntry("Calling setTimes() for this file: " ~ path, ["debug"]);
							setTimes(path, item.mtime, item.mtime);
						}
					} else if (!dryRun) {
						// The source of the out-of-date timestamp was the local file and this needs to be corrected to avoid always generating a hash test if timestamp is different
						addLogEntry("The source of the incorrect timestamp was the local file - correcting timestamp locally", ["verbose"]);
						// Fix the local file timestamp
						addLogEntry("Calling setTimes() for this file: " ~ path, ["debug"]);
						setTimes(path, item.mtime, item.mtime);
					}
					return false;
				} else {
					// The hash is different so the content of the file has to be different as to what is stored online
					addLogEntry("The local file has a different hash when compared to " ~ itemSource ~ " file hash", ["verbose"]);
					return false;
				}
			}
		} else if (item.type == ItemType.dir || ((item.type == ItemType.remote) && (item.remoteType == ItemType.dir))) {
			// item is a directory
			return true;
		} else {
			// ItemType.unknown or ItemType.none
			// Logically, we might not want to sync these items, but a more nuanced approach may be needed based on application context
			return true;
		}
	}
	
	// Get the /delta data using the provided details
	JSONValue getDeltaChangesByItemId(string selectedDriveId, string selectedItemId, string providedDeltaLink, OneDriveApi getDeltaQueryOneDriveApiInstance) {
			
		// Function variables
		JSONValue deltaChangesBundle;
		
		// Get the /delta data for this account | driveId | deltaLink combination
		addLogEntry("------------------------------------------------------------------", ["debug"]);
		addLogEntry("selectedDriveId:   " ~ selectedDriveId, ["debug"]);
		addLogEntry("selectedItemId:    " ~ selectedItemId, ["debug"]);
		addLogEntry("providedDeltaLink: " ~ providedDeltaLink, ["debug"]);
		addLogEntry("------------------------------------------------------------------", ["debug"]);
		
		try {
			deltaChangesBundle = getDeltaQueryOneDriveApiInstance.getChangesByItemId(selectedDriveId, selectedItemId, providedDeltaLink);
		} catch (OneDriveException exception) {
			// caught an exception
			addLogEntry("getDeltaQueryOneDriveApiInstance.getChangesByItemId(selectedDriveId, selectedItemId, providedDeltaLink) generated a OneDriveException", ["debug"]);
			
			auto errorArray = splitLines(exception.msg);
			string thisFunctionName = getFunctionName!({});
			
			// Error handling operation if not 408,429,503,504 errors
			// - 408,429,503,504 errors are handled as a retry within getDeltaQueryOneDriveApiInstance
			if (exception.httpStatusCode == 410) {
				addLogEntry();
				addLogEntry("WARNING: The OneDrive API responded with an error that indicates the locally stored deltaLink value is invalid");
				// Essentially the 'providedDeltaLink' that we have stored is no longer available ... re-try without the stored deltaLink
				addLogEntry("WARNING: Retrying OneDrive API call without using the locally stored deltaLink value");
				// Configure an empty deltaLink
				addLogEntry("Delta link expired for 'getDeltaQueryOneDriveApiInstance.getChangesByItemId(selectedDriveId, selectedItemId, providedDeltaLink)', setting 'deltaLink = null'", ["debug"]);
				string emptyDeltaLink = "";
				// retry with empty deltaLink
				deltaChangesBundle = getDeltaQueryOneDriveApiInstance.getChangesByItemId(selectedDriveId, selectedItemId, emptyDeltaLink);
			} else {
				// Display what the error is
				addLogEntry("CODING TO DO: Hitting this failure error output after getting a httpStatusCode != 410 when the API responded the deltaLink was invalid");
				displayOneDriveErrorMessage(exception.msg, thisFunctionName);
				deltaChangesBundle = null;
				// Perform Garbage Collection
				GC.collect();
			}
		}
		
		// Return data
		return deltaChangesBundle;
	}
	
	// If the JSON response is not correct JSON object, exit
	void invalidJSONResponseFromOneDriveAPI() {
		addLogEntry("ERROR: Query of the OneDrive API returned an invalid JSON response");
		// Must force exit here, allow logging to be done
		forceExit();
	}
	
	// Handle an unhandled API error
	void defaultUnhandledHTTPErrorCode(OneDriveException exception) {
		// display error
		displayOneDriveErrorMessage(exception.msg, getFunctionName!({}));
		// Must force exit here, allow logging to be done
		forceExit();
	}
	
	// Display the pertinant details of the sync engine
	void displaySyncEngineDetails() {
		// Display accountType, defaultDriveId, defaultRootId & remainingFreeSpace for verbose logging purposes
		addLogEntry("Application Version:  " ~ appConfig.applicationVersion, ["verbose"]);
		addLogEntry("Account Type:         " ~ appConfig.accountType, ["verbose"]);
		addLogEntry("Default Drive ID:     " ~ appConfig.defaultDriveId, ["verbose"]);
		addLogEntry("Default Root ID:      " ~ appConfig.defaultRootId, ["verbose"]);

		// Fetch the details from cachedOnlineDriveData
		DriveDetailsCache cachedOnlineDriveData;
		cachedOnlineDriveData = getDriveDetails(appConfig.defaultDriveId);
		
		// What do we display here for space remaining
		if (cachedOnlineDriveData.quotaRemaining > 0) {
			// Display the actual value
			addLogEntry("Remaining Free Space: " ~ to!string(byteToGibiByte(cachedOnlineDriveData.quotaRemaining)) ~ " GB (" ~ to!string(cachedOnlineDriveData.quotaRemaining) ~ " bytes)", ["verbose"]);
		} else {
			// zero or non-zero value or restricted
			if (!cachedOnlineDriveData.quotaRestricted){
				addLogEntry("Remaining Free Space:       0 KB", ["verbose"]);
			} else {
				addLogEntry("Remaining Free Space:       Not Available", ["verbose"]);
			}
		}
	}
	
	// Query itemdb.computePath() and catch potential assert when DB consistency issue occurs
	string computeItemPath(string thisDriveId, string thisItemId) {
		// static declare this for this function
		static import core.exception;
		string calculatedPath;
		
		// What driveID and itemID we trying to calculate the path for
		addLogEntry("Attempting to calculate local filesystem path for " ~ thisDriveId ~ " and " ~ thisItemId, ["debug"]);
		
		try {
			calculatedPath = itemDB.computePath(thisDriveId, thisItemId);
		} catch (core.exception.AssertError) {
			// broken tree in the database, we cant compute the path for this item id, exit
			addLogEntry("ERROR: A database consistency issue has been caught. A --resync is needed to rebuild the database.");
			// Must force exit here, allow logging to be done
			forceExit();
		}
		
		// return calculated path as string
		return calculatedPath;
	}
	
	// Try and compute the file hash for the given item
	bool testFileHash(string path, Item item) {
		
		// Generate QuickXORHash first before attempting to generate any other type of hash
		if (item.quickXorHash) {
			if (item.quickXorHash == computeQuickXorHash(path)) return true;
		} else if (item.sha256Hash) {
			if (item.sha256Hash == computeSHA256Hash(path)) return true;
		}
		return false;
	}
	
	// Process items that need to be removed
	void processDeleteItems() {
		
		foreach_reverse (i; idsToDelete) {
			Item item;
			string path;
			if (!itemDB.selectById(i[0], i[1], item)) continue; // check if the item is in the db
			// Compute this item path
			path = computeItemPath(i[0], i[1]);
			
			// Log the action if the path exists .. it may of already been removed and this is a legacy array item
			if (exists(path)) {
				if (item.type == ItemType.file) {
					addLogEntry("Trying to delete local file: " ~ path);
				} else {
					addLogEntry("Trying to delete local directory: " ~ path);
				}
			}
			
			// Process the database entry removal. In a --dry-run scenario, this is being done against a DB copy
			itemDB.deleteById(item.driveId, item.id);
			if (item.remoteDriveId != null) {
				// delete the linked remote folder
				itemDB.deleteById(item.remoteDriveId, item.remoteId);
			}
			
			// Add to pathFakeDeletedArray
			// We dont want to try and upload this item again, so we need to track this objects removal
			if (dryRun) {
				// We need to add './' here so that it can be correctly searched to ensure it is not uploaded
				string pathToAdd = "./" ~ path;
				pathFakeDeletedArray ~= pathToAdd;
			}
				
			bool needsRemoval = false;
			if (exists(path)) {
				// path exists on the local system	
				// make sure that the path refers to the correct item
				Item pathItem;
				if (itemDB.selectByPath(path, item.driveId, pathItem)) {
					if (pathItem.id == item.id) {
						needsRemoval = true;
					} else {
						addLogEntry("Skipped due to id difference!");
					}
				} else {
					// item has disappeared completely
					needsRemoval = true;
				}
			}
			if (needsRemoval) {
				// Log the action
				if (item.type == ItemType.file) {
					addLogEntry("Deleting local file: " ~ path);
				} else {
					addLogEntry("Deleting local directory: " ~ path);
				}
				
				// Perform the action
				if (!dryRun) {
					if (isFile(path)) {
						remove(path);
					} else {
						try {
							// Remove any children of this path if they still exist
							// Resolve 'Directory not empty' error when deleting local files
							foreach (DirEntry child; dirEntries(path, SpanMode.depth, false)) {
								attrIsDir(child.linkAttributes) ? rmdir(child.name) : remove(child.name);
							}
							// Remove the path now that it is empty of children
							rmdirRecurse(path);
						} catch (FileException e) {
							// display the error message
							displayFileSystemErrorMessage(e.msg, getFunctionName!({}));
						}
					}
				}
			}
		}
		
		if (!dryRun) {
			// Cleanup array memory
			idsToDelete = [];
		}
	}
	
	// List items that were deleted online, but, due to --download-only being used, will not be deleted locally
	void listDeletedItems() {
		// For each id in the idsToDelete array
		foreach_reverse (i; idsToDelete) {
			Item item;
			string path;
			if (!itemDB.selectById(i[0], i[1], item)) continue; // check if the item is in the db
			// Compute this item path
			path = computeItemPath(i[0], i[1]);
			
			// Log the action if the path exists .. it may of already been removed and this is a legacy array item
			if (exists(path)) {
				if (item.type == ItemType.file) {
					addLogEntry("Skipping local deletion for file " ~ path, ["verbose"]);
				} else {
					addLogEntry("Skipping local deletion for directory " ~ path, ["verbose"]);
				}
			}
		}
	}
	
	// Update the timestamp of an object online
	void uploadLastModifiedTime(Item originItem, string driveId, string id, SysTime mtime, string eTag) {
		
		string itemModifiedTime;
		itemModifiedTime = mtime.toISOExtString();
		JSONValue data = [
			"fileSystemInfo": JSONValue([
				"lastModifiedDateTime": itemModifiedTime
			])
		];
		
		// What eTag value do we use?
		string eTagValue;
		if (appConfig.accountType == "personal") {
			// Nullify the eTag to avoid 412 errors as much as possible
			eTagValue = null;
		} else {
			eTagValue = eTag;
		}
		
		JSONValue response;
		OneDriveApi uploadLastModifiedTimeApiInstance;
		
		// Try and update the online last modified time
		try {
			// Create a new OneDrive API instance
			uploadLastModifiedTimeApiInstance = new OneDriveApi(appConfig);
			uploadLastModifiedTimeApiInstance.initialise();
			// Use this instance
			response = uploadLastModifiedTimeApiInstance.updateById(driveId, id, data, eTagValue);
			
			// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
			uploadLastModifiedTimeApiInstance.releaseCurlEngine();
			uploadLastModifiedTimeApiInstance = null;
			// Perform Garbage Collection
			GC.collect();
			
			// Do we actually save the response?
			// Special case here .. if the DB record item (originItem) is a remote object, thus, if we save the 'response' we will have a DB FOREIGN KEY constraint failed problem
			//  Update 'originItem.mtime' with the correct timestamp
			//  Update 'originItem.size' with the correct size from the response
			//  Update 'originItem.eTag' with the correct eTag from the response
			//  Update 'originItem.cTag' with the correct cTag from the response
			//  Update 'originItem.quickXorHash' with the correct quickXorHash from the response
			// Everything else should remain the same .. and then save this DB record to the DB ..
			// However, we did this, for the local modified file right before calling this function to update the online timestamp ... so .. do we need to do this again, effectively performing a double DB write for the same data?
			if ((originItem.type != ItemType.remote) && (originItem.remoteType != ItemType.file)) {
				// Save the response JSON
				// Is the response a valid JSON object - validation checking done in saveItem
				saveItem(response);
			} 
		} catch (OneDriveException exception) {
			string thisFunctionName = getFunctionName!({});
			// Handle a 409 - ETag does not match current item's value
			// Handle a 412 - A precondition provided in the request (such as an if-match header) does not match the resource's current state.
			if ((exception.httpStatusCode == 409) || (exception.httpStatusCode == 412)) {
				// Handle the 409
				if (exception.httpStatusCode == 409) {
					// OneDrive threw a 412 error
					addLogEntry("OneDrive returned a 'HTTP 409 - ETag does not match current item's value' when attempting file time stamp update - gracefully handling error", ["verbose"]);
					addLogEntry("File Metadata Update Failed - OneDrive eTag / cTag match issue", ["debug"]);
					addLogEntry("Retrying Function: " ~ thisFunctionName, ["debug"]);
				}
				// Handle the 412
				if (exception.httpStatusCode == 412) {
					// OneDrive threw a 412 error
					addLogEntry("OneDrive returned a 'HTTP 412 - Precondition Failed' when attempting file time stamp update - gracefully handling error", ["verbose"]);
					addLogEntry("File Metadata Update Failed - OneDrive eTag / cTag match issue", ["debug"]);
					addLogEntry("Retrying Function: " ~ thisFunctionName, ["debug"]);
				}
				
				// Retry without eTag
				uploadLastModifiedTime(originItem, driveId, id, mtime, null);
			} else {
				// Any other error that should be handled
				// - 408,429,503,504 errors are handled as a retry within oneDriveApiInstance
				// Display what the error is
				displayOneDriveErrorMessage(exception.msg, getFunctionName!({}));
			}
			
			// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
			uploadLastModifiedTimeApiInstance.releaseCurlEngine();
			uploadLastModifiedTimeApiInstance = null;
			// Perform Garbage Collection
			GC.collect();
		}
	}
	
	// Perform a database integrity check - checking all the items that are in-sync at the moment, validating what we know should be on disk, to what is actually on disk
	void performDatabaseConsistencyAndIntegrityCheck() {
		
		// Log what we are doing
		if (!appConfig.suppressLoggingOutput) {
			addProcessingLogHeaderEntry("Performing a database consistency and integrity check on locally stored data", appConfig.verbosityCount);
		}
		
		// What driveIDsArray do we use? If we are doing a --single-directory we need to use just the drive id associated with that operation
		string[] consistencyCheckDriveIdsArray;
		if (singleDirectoryScope) {
			consistencyCheckDriveIdsArray ~= singleDirectoryScopeDriveId;
		} else {
			// Query the DB for all unique DriveID's
			consistencyCheckDriveIdsArray = itemDB.selectDistinctDriveIds();
		}
		
		// Create a new DB blank item
		Item item;
		// Use the array we populate, rather than selecting all distinct driveId's from the database
		foreach (driveId; consistencyCheckDriveIdsArray) {
			// Make the logging more accurate - we cant update driveId as this then breaks the below queries
			addLogEntry("Processing DB entries for this Drive ID: " ~ driveId, ["verbose"]);
			
			// Initialise the array 
			Item[] driveItems = [];
			
			// Freshen the cached quota details for this driveID
			addOrUpdateOneDriveOnlineDetails(driveId);
			
			// What OneDrive API query do we use?
			// - Are we running against a National Cloud Deployments that does not support /delta ?
			//   National Cloud Deployments do not support /delta as a query
			//   https://docs.microsoft.com/en-us/graph/deployments#supported-features
			//
			// - Are we performing a --single-directory sync, which will exclude many items online, focusing in on a specific online directory
			// - Are we performing a --download-only --cleanup-local-files action?
			// - Are we scanning a Shared Folder
			//
			// If we did, we self generated a /delta response, thus need to now process elements that are still flagged as out-of-sync
			if ((singleDirectoryScope) || (nationalCloudDeployment) || (cleanupLocalFiles) || sharedFolderDeltaGeneration) {
				// Any entry in the DB than is flagged as out-of-sync needs to be cleaned up locally first before we scan the entire DB
				// Normally, this is done at the end of processing all /delta queries, however when using --single-directory or a National Cloud Deployments is configured
				// We cant use /delta to query the OneDrive API as National Cloud Deployments dont support /delta
				// https://docs.microsoft.com/en-us/graph/deployments#supported-features
				// We dont use /delta for --single-directory as, in order to sync a single path with /delta, we need to query the entire OneDrive API JSON data to then filter out
				// objects that we dont want, thus, it is easier to use the same method as National Cloud Deployments, but query just the objects we are after
			
				// For each unique OneDrive driveID we know about
				Item[] outOfSyncItems = itemDB.selectOutOfSyncItems(driveId);
				foreach (outOfSyncItem; outOfSyncItems) {
					if (!dryRun) {
						// clean up idsToDelete
						idsToDelete.length = 0;
						assumeSafeAppend(idsToDelete);
						// flag to delete local file as it now is no longer in sync with OneDrive
						addLogEntry("Flagging to delete local item as it now is no longer in sync with OneDrive", ["debug"]);
						addLogEntry("outOfSyncItem: " ~ to!string(outOfSyncItem), ["debug"]);
						idsToDelete ~= [outOfSyncItem.driveId, outOfSyncItem.id];
						// delete items in idsToDelete
						if (idsToDelete.length > 0) processDeleteItems();
					}
				}
				
				// Clear array
				outOfSyncItems = [];
						
				// Fetch database items associated with this path
				if (singleDirectoryScope) {
					// Use the --single-directory items we previously configured
					// - query database for children objects using those items
					driveItems = getChildren(singleDirectoryScopeDriveId, singleDirectoryScopeItemId);
				} else {
					// Check everything associated with each driveId we know about
					addLogEntry("Selecting DB items via itemDB.selectByDriveId(driveId)", ["debug"]);
					// Query database
					driveItems = itemDB.selectByDriveId(driveId);
				}
				
				// Log DB items to process
				addLogEntry("Database items to process for this driveId: " ~ to!string(driveItems.count), ["debug"]);
				
				// Process each database database item associated with the driveId
				foreach(dbItem; driveItems) {
					// Does it still exist on disk in the location the DB thinks it is
					checkDatabaseItemForConsistency(dbItem);
				}
			} else {
				// Check everything associated with each driveId we know about
				addLogEntry("Selecting DB items via itemDB.selectByDriveId(driveId)", ["debug"]);
				
				// Query database
				driveItems = itemDB.selectByDriveId(driveId);
				addLogEntry("Database items to process for this driveId: " ~ to!string(driveItems.count), ["debug"]);
				
				// Process each database database item associated with the driveId
				foreach(dbItem; driveItems) {
					// Does it still exist on disk in the location the DB thinks it is
					checkDatabaseItemForConsistency(dbItem);
				}
			}
			
			// Clear the array
			driveItems = [];
		}

		// Close out the '....' being printed to the console
		if (!appConfig.suppressLoggingOutput) {
			if (appConfig.verbosityCount == 0) {
				completeProcessingDots();
			}
		}
		
		// Are we doing a --download-only sync?
		if (!appConfig.getValueBool("download_only")) {
			
			// Do we have any known items, where they have been deleted locally, that now need to be deleted online?
			if (databaseItemsToDeleteOnline.length > 0) {
				// There are items to delete online
				addLogEntry("Deleted local items to delete on Microsoft OneDrive: " ~ to!string(databaseItemsToDeleteOnline.length));
				foreach(localItemToDeleteOnline; databaseItemsToDeleteOnline) {
					// Upload to OneDrive the instruction to delete this item. This will handle the 'noRemoteDelete' flag if set
					uploadDeletedItem(localItemToDeleteOnline.dbItem, localItemToDeleteOnline.localFilePath);
				}
				// Cleanup array memory
				databaseItemsToDeleteOnline = [];
			}
			
			// Do we have any known items, where the content has changed locally, that needs to be uploaded?
			if (databaseItemsWhereContentHasChanged.length > 0) {
				// There are changed local files that were in the DB to upload
				addLogEntry("Changed local items to upload to Microsoft OneDrive: " ~ to!string(databaseItemsWhereContentHasChanged.length));
				processChangedLocalItemsToUpload();
				// Cleanup array memory
				databaseItemsWhereContentHasChanged = [];
			}
		}
	}
	
	// Check this Database Item for its consistency on disk
	void checkDatabaseItemForConsistency(Item dbItem) {
			
		// What is the local path item
		string localFilePath;
		// Do we want to onward process this item?
		bool unwanted = false;
		
		// Remote directory items we can 'skip'
		if ((dbItem.type == ItemType.remote) && (dbItem.remoteType == ItemType.dir)) {
			// return .. nothing to check here, no logging needed
			return;
		}
		
		// Compute this dbItem path early as we we use this path often
		localFilePath = buildNormalizedPath(computeItemPath(dbItem.driveId, dbItem.id));
		
		// To improve logging output for this function, what is the 'logical path'?
		string logOutputPath;
		if (localFilePath == ".") {
			// get the configured sync_dir
			logOutputPath = buildNormalizedPath(appConfig.getValueString("sync_dir"));
		} else {
			// Use the path that was computed
			logOutputPath = localFilePath;
		}
		
		// Log what we are doing
		addLogEntry("Processing: " ~ logOutputPath, ["verbose"]);
		// Add a processing '.'
		if (!appConfig.suppressLoggingOutput) {
			if (appConfig.verbosityCount == 0) {
				addProcessingDotEntry();
			}
		}
		
		// Determine which action to take
		final switch (dbItem.type) {
		case ItemType.file:
			// Logging output result is handled by checkFileDatabaseItemForConsistency
			checkFileDatabaseItemForConsistency(dbItem, localFilePath);
			break;
		case ItemType.dir:
			// Logging output result is handled by checkDirectoryDatabaseItemForConsistency
			checkDirectoryDatabaseItemForConsistency(dbItem, localFilePath);
			break;
		case ItemType.remote:
			// DB items that match: dbItem.remoteType == ItemType.dir - these should have been skipped above
			// This means that anything that hits here should be: dbItem.remoteType == ItemType.file
			checkFileDatabaseItemForConsistency(dbItem, localFilePath);
			break;
		case ItemType.unknown:
		case ItemType.none:
			// Unknown type - we dont action these items
			break;
		}
	}
	
	// Perform the database consistency check on this file item
	void checkFileDatabaseItemForConsistency(Item dbItem, string localFilePath) {
		
		// What is the source of this item data?
		string itemSource = "database";
		
		// Does this item|file still exist on disk?
		if (exists(localFilePath)) {
			// Path exists locally, is this path a file?
			if (isFile(localFilePath)) {
				// Can we actually read the local file?
				if (readLocalFile(localFilePath)){
					// File is readable
					SysTime localModifiedTime = timeLastModified(localFilePath).toUTC();
					SysTime itemModifiedTime = dbItem.mtime;
					// Reduce time resolution to seconds before comparing
					itemModifiedTime.fracSecs = Duration.zero;
					localModifiedTime.fracSecs = Duration.zero;
					
					if (localModifiedTime != itemModifiedTime) {
						// The modified dates are different
						addLogEntry("Local file time discrepancy detected: " ~ localFilePath, ["verbose"]);
						addLogEntry("This local file has a different modified time " ~ to!string(localModifiedTime) ~ " (UTC) when compared to " ~ itemSource ~ " modified time " ~ to!string(itemModifiedTime) ~ " (UTC)", ["debug"]);
						
						// Test the file hash
						if (!testFileHash(localFilePath, dbItem)) {
							// Is the local file 'newer' or 'older' (ie was an old file 'restored locally' by a different backup / replacement process?)
							if (localModifiedTime >= itemModifiedTime) {
								// Local file is newer
								if (!appConfig.getValueBool("download_only")) {
									addLogEntry("The file content has changed locally and has a newer timestamp, thus needs to be uploaded to OneDrive", ["verbose"]);
									// Add to an array of files we need to upload as this file has changed locally in-between doing the /delta check and performing this check
									databaseItemsWhereContentHasChanged ~= [dbItem.driveId, dbItem.id, localFilePath];
								} else {
									addLogEntry("The file content has changed locally and has a newer timestamp. The file will remain different to online file due to --download-only being used", ["verbose"]);
								}
							} else {
								// Local file is older - data recovery process? something else?
								if (!appConfig.getValueBool("download_only")) {
									addLogEntry("The file content has changed locally and file now has a older timestamp. Uploading this file to OneDrive may potentially cause data-loss online", ["verbose"]);
									// Add to an array of files we need to upload as this file has changed locally in-between doing the /delta check and performing this check
									databaseItemsWhereContentHasChanged ~= [dbItem.driveId, dbItem.id, localFilePath];
								} else {
									addLogEntry("The file content has changed locally and file now has a older timestamp. The file will remain different to online file due to --download-only being used", ["verbose"]);
								}
							}
						} else {
							// The file contents have not changed, but the modified timestamp has
							addLogEntry("The last modified timestamp has changed however the file content has not changed", ["verbose"]);
							
							// Local file is newer .. are we in a --download-only situation?
							if (!appConfig.getValueBool("download_only")) {
								// Not a --download-only scenario
								if (!dryRun) {
									// Attempt to update the online date time stamp
									// We need to use the correct driveId and itemId, especially if we are updating a OneDrive Business Shared File timestamp
									if (dbItem.type == ItemType.file) {
										// Not a remote file
										// Log what is being done
										addLogEntry("The local item has the same hash value as the item online - correcting timestamp online", ["verbose"]);
										// Correct timestamp
										uploadLastModifiedTime(dbItem, dbItem.driveId, dbItem.id, localModifiedTime.toUTC(), dbItem.eTag);
									} else {
										// Remote file, remote values need to be used, we may not even have permission to change timestamp, update local file
										addLogEntry("The local item has the same hash value as the item online, however file is a OneDrive Business Shared File - correcting local timestamp", ["verbose"]);
										addLogEntry("Calling setTimes() for this file: " ~ localFilePath, ["debug"]);
										setTimes(localFilePath, dbItem.mtime, dbItem.mtime);
									}
								}
							} else {
								// --download-only being used
								addLogEntry("The local item has the same hash value as the item online - correcting local timestamp due to --download-only being used to ensure local file matches timestamp online", ["verbose"]);
								if (!dryRun) {
									addLogEntry("Calling setTimes() for this file: " ~ localFilePath, ["debug"]);
									setTimes(localFilePath, dbItem.mtime, dbItem.mtime);
								}
							}
						}
					} else {
						// The file has not changed
						addLogEntry("The file has not changed", ["verbose"]);
					}
				} else {
					//The file is not readable - skipped
					addLogEntry("Skipping processing this file as it cannot be read (file permissions or file corruption): " ~ localFilePath);
				}
			} else {
				// The item was a file but now is a directory
				addLogEntry("The item was a file but now is a directory", ["verbose"]);
			}
		} else {
			// File does not exist locally, but is in our database as a dbItem containing all the data was passed into this function
			// If we are in a --dry-run situation - this file may never have existed as we never downloaded it
			if (!dryRun) {
				// Not --dry-run situation
				addLogEntry("The file has been deleted locally", ["verbose"]);
				// Add this to the array to handle post checking all database items
				databaseItemsToDeleteOnline ~= [DatabaseItemsToDeleteOnline(dbItem, localFilePath)];
			} else {
				// We are in a --dry-run situation, file appears to have been deleted locally - this file may never have existed locally as we never downloaded it due to --dry-run
				// Did we 'fake create it' as part of --dry-run ?
				bool idsFakedMatch = false;
				foreach (i; idsFaked) {
					if (i[1] == dbItem.id) {
						addLogEntry("Matched faked file which is 'supposed' to exist but not created due to --dry-run use", ["debug"]);
						addLogEntry("The file has not changed", ["verbose"]);
						idsFakedMatch = true;
					}
				}
				if (!idsFakedMatch) {
					// dbItem.id did not match a 'faked' download new file creation - so this in-sync object was actually deleted locally, but we are in a --dry-run situation
					addLogEntry("The file has been deleted locally", ["verbose"]);
					// Add this to the array to handle post checking all database items
					databaseItemsToDeleteOnline ~= [DatabaseItemsToDeleteOnline(dbItem, localFilePath)];
				}
			}
		}
	}
	
	// Perform the database consistency check on this directory item
	void checkDirectoryDatabaseItemForConsistency(Item dbItem, string localFilePath) {
			
		// What is the source of this item data?
		string itemSource = "database";
		
		// Does this item|directory still exist on disk?
		if (exists(localFilePath)) {
			// Fix https://github.com/abraunegg/onedrive/issues/1915
			try {
				if (!isDir(localFilePath)) {
					addLogEntry("The item was a directory but now it is a file", ["verbose"]);
					uploadDeletedItem(dbItem, localFilePath);
					uploadNewFile(localFilePath);
				} else {
					// Directory still exists locally
					addLogEntry("The directory has not changed", ["verbose"]);
					// When we are using --single-directory, we use a the getChildren() call to get all children of a path, meaning all children are already traversed
					// Thus, if we traverse the path of this directory .. we end up with double processing & log output .. which is not ideal
					if (!singleDirectoryScope) {
						// loop through the children
						Item[] childrenFromDatabase = itemDB.selectChildren(dbItem.driveId, dbItem.id);
						foreach (Item child; childrenFromDatabase) {
							checkDatabaseItemForConsistency(child);
						}
						// Clear DB response array
						childrenFromDatabase = [];
					}
				}
			} catch (FileException e) {
				// display the error message
				displayFileSystemErrorMessage(e.msg, getFunctionName!({}));
			}
		} else {
			// Directory does not exist locally, but it is in our database as a dbItem containing all the data was passed into this function
			// If we are in a --dry-run situation - this directory may never have existed as we never created it
			if (!dryRun) {
				// Not --dry-run situation
				if (!appConfig.getValueBool("monitor")) {
					// Not in --monitor mode
					addLogEntry("The directory has been deleted locally", ["verbose"]);
				} else {
					// Appropriate message as we are in --monitor mode
					addLogEntry("The directory appears to have been deleted locally .. but we are running in --monitor mode. This may have been 'moved' on the local filesystem rather than being 'deleted'", ["verbose"]);
					addLogEntry("Most likely cause - 'inotify' event was missing for whatever action was taken locally or action taken when application was stopped", ["debug"]);
				}
				// A moved directory will be uploaded as 'new', delete the old directory and database reference
				// Add this to the array to handle post checking all database items
				databaseItemsToDeleteOnline ~= [DatabaseItemsToDeleteOnline(dbItem, localFilePath)];
			} else {
				// We are in a --dry-run situation, directory appears to have been deleted locally - this directory may never have existed locally as we never created it due to --dry-run
				// Did we 'fake create it' as part of --dry-run ?
				bool idsFakedMatch = false;
				foreach (i; idsFaked) {
					if (i[1] == dbItem.id) {
						addLogEntry("Matched faked dir which is 'supposed' to exist but not created due to --dry-run use", ["debug"]);
						addLogEntry("The directory has not changed", ["verbose"]);
						idsFakedMatch = true;
					}
				}
				if (!idsFakedMatch) {
					// dbItem.id did not match a 'faked' download new directory creation - so this in-sync object was actually deleted locally, but we are in a --dry-run situation
					addLogEntry("The directory has been deleted locally", ["verbose"]);
					// Add this to the array to handle post checking all database items
					databaseItemsToDeleteOnline ~= [DatabaseItemsToDeleteOnline(dbItem, localFilePath)];
				} else {
					// When we are using --single-directory, we use a the getChildren() call to get all children of a path, meaning all children are already traversed
					// Thus, if we traverse the path of this directory .. we end up with double processing & log output .. which is not ideal
					if (!singleDirectoryScope) {
						// loop through the children
						Item[] childrenFromDatabase = itemDB.selectChildren(dbItem.driveId, dbItem.id);
						foreach (Item child; childrenFromDatabase) {
							checkDatabaseItemForConsistency(child);
						}
						// Clear DB response array
						childrenFromDatabase = [];
					}
				}
			}
		}
	}
	
	// Does this local path (directory or file) conform with the Microsoft Naming Restrictions? It needs to conform otherwise we cannot create the directory or upload the file.
	bool checkPathAgainstMicrosoftNamingRestrictions(string localFilePath, string logModifier = "item") {
			
		// Check if the given path violates certain Microsoft restrictions and limitations
		// Return a true|false response
		bool invalidPath = false;
		
		// Check path against Microsoft OneDrive restriction and limitations about Windows naming for files and folders
		if (!invalidPath) {
			if (!isValidName(localFilePath)) { // This will return false if this is not a valid name according to the OneDrive API specifications
				addLogEntry("Skipping " ~ logModifier ~" - invalid name (Microsoft Naming Convention): " ~ localFilePath, ["info", "notify"]);
				invalidPath = true;
			}
		}
		
		// Check path for bad whitespace items
		if (!invalidPath) {
			if (containsBadWhiteSpace(localFilePath)) { // This will return true if this contains a bad whitespace character
				addLogEntry("Skipping " ~ logModifier ~" - invalid name (Contains an invalid whitespace character): " ~ localFilePath, ["info", "notify"]);
				invalidPath = true;
			}
		}
		
		// Check path for HTML ASCII Codes
		if (!invalidPath) {
			if (containsASCIIHTMLCodes(localFilePath)) { // This will return true if this contains HTML ASCII Codes
				addLogEntry("Skipping " ~ logModifier ~" - invalid name (Contains HTML ASCII Code): " ~ localFilePath, ["info", "notify"]);
				invalidPath = true;
			}
		}
		
		// Validate that the path is a valid UTF-16 encoded path
		if (!invalidPath) {
			if (!isValidUTF16(localFilePath)) { // This will return true if this is a valid UTF-16 encoded path, so we are checking for 'false' as response
				addLogEntry("Skipping " ~ logModifier ~" - invalid name (Invalid UTF-16 encoded path): " ~ localFilePath, ["info", "notify"]);
				invalidPath = true;
			}
		}
		
		// Check path for ASCII Control Codes
		if (!invalidPath) {
			if (containsASCIIControlCodes(localFilePath)) { // This will return true if this contains ASCII Control Codes
				addLogEntry("Skipping " ~ logModifier ~" - invalid name (Contains ASCII Control Codes): " ~ localFilePath, ["info", "notify"]);
				invalidPath = true;
			}
		}
		
		// Return if this is a valid path
		return invalidPath;
	}
	
	// Does this local path (directory or file) get excluded from any operation based on any client side filtering rules?
	bool checkPathAgainstClientSideFiltering(string localFilePath) {
		
		// Check the path against client side filtering rules
		// - check_nosync
		// - skip_dotfiles
		// - skip_symlinks
		// - skip_file
		// - skip_dir
		// - sync_list
		// - skip_size
		// Return a true|false response
		
		bool clientSideRuleExcludesPath = false;
		
		// does the path exist?
		if (!exists(localFilePath)) {
			// path does not exist - we cant review any client side rules on something that does not exist locally
			return clientSideRuleExcludesPath;
		}
	
		// - check_nosync
		if (!clientSideRuleExcludesPath) {
			// Do we need to check for .nosync? Only if --check-for-nosync was passed in
			if (appConfig.getValueBool("check_nosync")) {
				if (exists(localFilePath ~ "/.nosync")) {
					addLogEntry("Skipping item - .nosync found & --check-for-nosync enabled: " ~ localFilePath, ["verbose"]);
					clientSideRuleExcludesPath = true;
				}
			}
		}
		
		// - skip_dotfiles
		if (!clientSideRuleExcludesPath) {
			// Do we need to check skip dot files if configured
			if (appConfig.getValueBool("skip_dotfiles")) {
				if (isDotFile(localFilePath)) {
					addLogEntry("Skipping item - .file or .folder: " ~ localFilePath, ["verbose"]);
					clientSideRuleExcludesPath = true;
				}
			}
		}
		
		// - skip_symlinks
		if (!clientSideRuleExcludesPath) {
			// Is the path a symbolic link
			if (isSymlink(localFilePath)) {
				// if config says so we skip all symlinked items
				if (appConfig.getValueBool("skip_symlinks")) {
					addLogEntry("Skipping item - skip symbolic links configured: " ~ localFilePath, ["verbose"]);
					clientSideRuleExcludesPath = true;
				}
				// skip unexisting symbolic links
				else if (!exists(readLink(localFilePath))) {
					// reading the symbolic link failed - is the link a relative symbolic link
					//   drwxrwxr-x. 2 alex alex 46 May 30 09:16 .
					//   drwxrwxr-x. 3 alex alex 35 May 30 09:14 ..
					//   lrwxrwxrwx. 1 alex alex 61 May 30 09:16 absolute.txt -> /home/alex/OneDrivePersonal/link_tests/intercambio/prueba.txt
					//   lrwxrwxrwx. 1 alex alex 13 May 30 09:16 relative.txt -> ../prueba.txt
					//
					// absolute links will be able to be read, but 'relative' links will fail, because they cannot be read based on the current working directory 'sync_dir'
					string currentSyncDir = getcwd();
					string fullLinkPath = buildNormalizedPath(absolutePath(localFilePath));
					string fileName = baseName(fullLinkPath);
					string parentLinkPath = dirName(fullLinkPath);
					// test if this is a 'relative' symbolic link
					chdir(parentLinkPath);
					auto relativeLink = readLink(fileName);
					auto relativeLinkTest = exists(readLink(fileName));
					// reset back to our 'sync_dir'
					chdir(currentSyncDir);
					// results
					if (relativeLinkTest) {
						addLogEntry("Not skipping item - symbolic link is a 'relative link' to target ('" ~ relativeLink ~ "') which can be supported: " ~ localFilePath, ["debug"]);
					} else {
						addLogEntry("Skipping item - invalid symbolic link: "~ localFilePath, ["info", "notify"]);
						clientSideRuleExcludesPath = true;
					}
				}
			}
		}
		
		// Is this item excluded by user configuration of skip_dir or skip_file?
		if (!clientSideRuleExcludesPath) {
			if (localFilePath != ".") {
				// skip_dir handling
				if (isDir(localFilePath)) {
					addLogEntry("Checking local path: " ~ localFilePath, ["debug"]);
					
					// Only check path if config is != ""
					if (appConfig.getValueString("skip_dir") != "") {
						// The path that needs to be checked needs to include the '/'
						// This due to if the user has specified in skip_dir an exclusive path: '/path' - that is what must be matched
						if (selectiveSync.isDirNameExcluded(localFilePath.strip('.'))) {
							addLogEntry("Skipping path - excluded by skip_dir config: " ~ localFilePath, ["verbose"]);
							clientSideRuleExcludesPath = true;
						}
					}
				}
				
				// skip_file handling
				if (isFile(localFilePath)) {
					addLogEntry("Checking file: " ~ localFilePath, ["debug"]);
					
					// The path that needs to be checked needs to include the '/'
					// This due to if the user has specified in skip_file an exclusive path: '/path/file' - that is what must be matched
					if (selectiveSync.isFileNameExcluded(localFilePath.strip('.'))) {
						addLogEntry("Skipping file - excluded by skip_dir config: " ~ localFilePath, ["verbose"]);
						clientSideRuleExcludesPath = true;
					}
				}
			}
		}
	
		// Is this item excluded by user configuration of sync_list?
		if (!clientSideRuleExcludesPath) {
			if (localFilePath != ".") {
				if (syncListConfigured) {
					// sync_list configured and in use
					if (selectiveSync.isPathExcludedViaSyncList(localFilePath)) {
						if ((isFile(localFilePath)) && (appConfig.getValueBool("sync_root_files")) && (rootName(localFilePath.strip('.').strip('/')) == "")) {
							addLogEntry("Not skipping path due to sync_root_files inclusion: " ~ localFilePath, ["debug"]);
						} else {
							if (exists(appConfig.syncListFilePath)){
								// skipped most likely due to inclusion in sync_list
								
								// is this path a file or directory?
								if (isFile(localFilePath)) {
									// file	
									addLogEntry("Skipping file - excluded by sync_list config: " ~ localFilePath, ["verbose"]);
								} else {
									// directory
									addLogEntry("Skipping path - excluded by sync_list config: " ~ localFilePath, ["verbose"]);
								}
								
								// flag as excluded
								clientSideRuleExcludesPath = true;
							} else {
								// skipped for some other reason
								addLogEntry("Skipping path - excluded by user config: " ~ localFilePath, ["verbose"]);
								clientSideRuleExcludesPath = true;
							}
						}
					}
				}
			}
		}
		
		// Check if this is excluded by a user set maximum filesize to upload
		if (!clientSideRuleExcludesPath) {
			if (isFile(localFilePath)) {
				if (fileSizeLimit != 0) {
					// Get the file size
					ulong thisFileSize = getSize(localFilePath);
					if (thisFileSize >= fileSizeLimit) {
						addLogEntry("Skipping file - excluded by skip_size config: " ~ localFilePath ~ " (" ~ to!string(thisFileSize/2^^20) ~ " MB)", ["verbose"]);
					}
				}
			}
		}
		
		return clientSideRuleExcludesPath;
	}
	
	// Does this JSON item (as received from OneDrive API) get excluded from any operation based on any client side filtering rules?
	// This function is used when we are fetching objects from the OneDrive API using a /children query to help speed up what object we query or when checking OneDrive Business Shared Files
	bool checkJSONAgainstClientSideFiltering(JSONValue onedriveJSONItem) {
			
		bool clientSideRuleExcludesPath = false;
		
		// Check the path against client side filtering rules
		// - check_nosync (MISSING)
		// - skip_dotfiles (MISSING)
		// - skip_symlinks (MISSING)
		// - skip_file
		// - skip_dir 
		// - sync_list
		// - skip_size
		// Return a true|false response
		
		// Use the JSON elements rather can computing a DB struct via makeItem()
		string thisItemId = onedriveJSONItem["id"].str;
		string thisItemDriveId = onedriveJSONItem["parentReference"]["driveId"].str;
		string thisItemParentId = onedriveJSONItem["parentReference"]["id"].str;
		string thisItemName = onedriveJSONItem["name"].str;
		
		// Is this parent is in the database
		bool parentInDatabase = false;
		
		// Calculate if the Parent Item is in the database so that it can be re-used
		parentInDatabase = itemDB.idInLocalDatabase(thisItemDriveId, thisItemParentId);
		
		// Check if this is excluded by config option: skip_dir 
		if (!clientSideRuleExcludesPath) {
			// Is the item a folder?
			if (isItemFolder(onedriveJSONItem)) {
				// Only check path if config is != ""
				if (!appConfig.getValueString("skip_dir").empty) {
					// work out the 'snippet' path where this folder would be created
					string simplePathToCheck = "";
					string complexPathToCheck = "";
					string matchDisplay = "";
					
					if (hasParentReference(onedriveJSONItem)) {
						// we need to workout the FULL path for this item
						// simple path
						if (("name" in onedriveJSONItem["parentReference"]) != null) {
							simplePathToCheck = onedriveJSONItem["parentReference"]["name"].str ~ "/" ~ onedriveJSONItem["name"].str;
						} else {
							simplePathToCheck = onedriveJSONItem["name"].str;
						}
						addLogEntry("skip_dir path to check (simple):  " ~ simplePathToCheck, ["debug"]);
						
						// complex path
						if (parentInDatabase) {
							// build up complexPathToCheck
							//complexPathToCheck = buildNormalizedPath(newItemPath);
							complexPathToCheck = computeItemPath(thisItemDriveId, thisItemParentId) ~ "/" ~ thisItemName;
						} else {
							addLogEntry("Parent details not in database - unable to compute complex path to check", ["debug"]);
						}
						if (!complexPathToCheck.empty) {
							addLogEntry("skip_dir path to check (complex): " ~ complexPathToCheck, ["debug"]);
						}
					} else {
						simplePathToCheck = onedriveJSONItem["name"].str;
					}
					
					// If 'simplePathToCheck' or 'complexPathToCheck' is of the following format:  root:/folder
					// then isDirNameExcluded matching will not work
					if (simplePathToCheck.canFind(":")) {
						addLogEntry("Updating simplePathToCheck to remove 'root:'", ["debug"]);
						simplePathToCheck = processPathToRemoveRootReference(simplePathToCheck);
					}
					if (complexPathToCheck.canFind(":")) {
						addLogEntry("Updating complexPathToCheck to remove 'root:'", ["debug"]);
						complexPathToCheck = processPathToRemoveRootReference(complexPathToCheck);
					}
					
					// OK .. what checks are we doing?
					if ((!simplePathToCheck.empty) && (complexPathToCheck.empty)) {
						// just a simple check
						addLogEntry("Performing a simple check only", ["debug"]);
						clientSideRuleExcludesPath = selectiveSync.isDirNameExcluded(simplePathToCheck);
					} else {
						// simple and complex
						addLogEntry("Performing a simple then complex path match if required", ["debug"]);
												
						// simple first
						addLogEntry("Performing a simple check first", ["debug"]);
						clientSideRuleExcludesPath = selectiveSync.isDirNameExcluded(simplePathToCheck);
						matchDisplay = simplePathToCheck;
						if (!clientSideRuleExcludesPath) {
							addLogEntry("Simple match was false, attempting complex match", ["debug"]);
							// simple didnt match, perform a complex check
							clientSideRuleExcludesPath = selectiveSync.isDirNameExcluded(complexPathToCheck);
							matchDisplay = complexPathToCheck;
						}
					}
					// End Result
					addLogEntry("skip_dir exclude result (directory based): " ~ to!string(clientSideRuleExcludesPath), ["debug"]);
					if (clientSideRuleExcludesPath) {
						// This path should be skipped
						addLogEntry("Skipping path - excluded by skip_dir config: " ~ matchDisplay, ["verbose"]);
					}
				}
			}
		}
		
		// Check if this is excluded by config option: skip_file
		if (!clientSideRuleExcludesPath) {
			// is the item a file ?
			if (isFileItem(onedriveJSONItem)) {
				// JSON item is a file
				
				// skip_file can contain 4 types of entries:
				// - wildcard - *.txt
				// - text + wildcard - name*.txt
				// - full path + combination of any above two - /path/name*.txt
				// - full path to file - /path/to/file.txt
				
				string exclusionTestPath = "";
				
				// is the parent id in the database?
				if (parentInDatabase) {
					// parent id is in the database, so we can try and calculate the full file path
					string jsonItemPath = "";
					
					// Compute this item path & need the full path for this file
					jsonItemPath = computeItemPath(thisItemDriveId, thisItemParentId) ~ "/" ~ thisItemName;
					// Log the calculation
					addLogEntry("New Item calculated full path is: " ~ jsonItemPath, ["debug"]);
					
					// The path that needs to be checked needs to include the '/'
					// This due to if the user has specified in skip_file an exclusive path: '/path/file' - that is what must be matched
					// However, as 'path' used throughout, use a temp variable with this modification so that we use the temp variable for exclusion checks
					if (!startsWith(jsonItemPath, "/")){
						// Add '/' to the path
						exclusionTestPath = '/' ~ jsonItemPath;
					}
					
					// what are we checking
					addLogEntry("skip_file item to check (full calculated path): " ~ exclusionTestPath, ["debug"]);
				} else {
					// parent not in database, we can only check using this JSON item's name
					if (!startsWith(thisItemName, "/")){
						// Add '/' to the path
						exclusionTestPath = '/' ~ thisItemName;
					}
					
					// what are we checking
					addLogEntry("skip_file item to check (file name only - parent path not in database): " ~ exclusionTestPath, ["debug"]);
					clientSideRuleExcludesPath = selectiveSync.isFileNameExcluded(exclusionTestPath);
				}
				
				// Perform the 'skip_file' evaluation
				clientSideRuleExcludesPath = selectiveSync.isFileNameExcluded(exclusionTestPath);
				addLogEntry("Result: " ~ to!string(clientSideRuleExcludesPath), ["debug"]);
				
				if (clientSideRuleExcludesPath) {
					// This path should be skipped
					addLogEntry("Skipping file - excluded by skip_dir config: " ~ exclusionTestPath, ["verbose"]);
				}
			}
		}
			
		// Check if this is included or excluded by use of sync_list
		if (!clientSideRuleExcludesPath) {
			// No need to try and process something against a sync_list if it has been configured
			if (syncListConfigured) {
				// Compute the item path if empty - as to check sync_list we need an actual path to check
				
				// What is the path of the new item
				string newItemPath;
				
				// Is the parent in the database? If not, we cannot compute the the full path based on the database entries
				// In a --resync scenario - the database is empty
				if (parentInDatabase) {
					// Calculate this items path based on database entries
					newItemPath = computeItemPath(thisItemDriveId, thisItemParentId) ~ "/" ~ thisItemName;
				} else {
					// parent not in the database
					if (("path" in onedriveJSONItem["parentReference"]) != null) {
						// If there is a parent reference path, try and use it
						string selfBuiltPath = onedriveJSONItem["parentReference"]["path"].str ~ "/" ~ onedriveJSONItem["name"].str;
						
						// Check for ':' and split if present
						string[] splitPaths;
						auto splitIndex = selfBuiltPath.indexOf(":");
						if (splitIndex != -1) {
							// Keep only the part after ':'
							splitPaths = selfBuiltPath.split(":");
							selfBuiltPath = splitPaths[1];
						}
						
						// Issue #2731
						// Is this potentially a shared folder?
						if (onedriveJSONItem["parentReference"]["driveId"].str != appConfig.defaultDriveId) {
							// Download item specifics
							string downloadDriveId = onedriveJSONItem["parentReference"]["driveId"].str;
							string parentFolderId = baseName(splitPaths[0]);
							
							// Query the database for the parent folder details
							Item remoteItem;
							itemDB.selectByRemoteId(downloadDriveId, parentFolderId, remoteItem);
							
							// Update the path that will be used to check 'sync_list' with
							selfBuiltPath = remoteItem.name ~ selfBuiltPath;
						}
						
						// Issue #2740
						// If selfBuiltPath is containing any sort of URL encoding, due to special characters (spaces, umlaut, or any other character that is HTML encoded, this specific path now needs to be HTML decoded
						// Does the path contain HTML encoding?
						if (containsURLEncodedItems(selfBuiltPath)) {
							// decode it
							addLogEntry("selfBuiltPath for sync_list check needs decoding: " ~ selfBuiltPath, ["debug"]);
							newItemPath = decodeComponent(selfBuiltPath);
						} else {
							// use as-is
							newItemPath = selfBuiltPath;
						}
					} else {
						// no parent reference path available in provided JSON
						newItemPath = thisItemName;
					}
				}
				
				// Check for HTML entities (e.g., '%20' for space) in newItemPath
				if (containsURLEncodedItems(newItemPath)) {
					addLogEntry("CAUTION:    The JSON element transmitted by the Microsoft OneDrive API includes HTML URL encoded items, which may complicate pattern matching and potentially lead to synchronisation problems for this item.");
					addLogEntry("WORKAROUND: An alternative solution could be to change the name of this item through the online platform: " ~ newItemPath, ["verbose"]);
					addLogEntry("See: https://github.com/OneDrive/onedrive-api-docs/issues/1765 for further details", ["verbose"]);
				}
				
				// If this is a Shared Folder, we need to 'trim' the resulting path to that of the 'folder' that is actually shared with us so that this can be appropriatly checked against 'sync_list' entries
				if (sharedFolderDeltaGeneration) {
					// Find the index of 'currentSharedFolderName' in 'newItemPath'
					int pos = cast(int) newItemPath.indexOf(currentSharedFolderName);
					
					// If currentSharedFolderName is found within newItemPath
					if (pos != -1) {
						// Get the substring from the position of currentSharedFolderName
						string result = newItemPath[pos .. $];
						newItemPath = result;
					}
				}
				
				// Update newItemPath, remove leading '/' if present
				if(newItemPath[0] == '/') {
					newItemPath = newItemPath[1..$];
				}
				
				// What path are we checking against sync_list?
				addLogEntry("path to check against 'sync_list' entries: " ~ newItemPath, ["debug"]);
				
				// Unfortunately there is no avoiding this call to check if the path is excluded|included via sync_list
				if (selectiveSync.isPathExcludedViaSyncList(newItemPath)) {
					// selective sync advised to skip, however is this a file and are we configured to upload / download files in the root?
					if ((isItemFile(onedriveJSONItem)) && (appConfig.getValueBool("sync_root_files")) && (rootName(newItemPath) == "") ) {
						// This is a file
						// We are configured to sync all files in the root
						// This is a file in the logical root
						clientSideRuleExcludesPath = false;
					} else {
						// Path is unwanted, flag to exclude
						clientSideRuleExcludesPath = true;
						
						// Has this itemId already been flagged as being skipped?
						if (!syncListSkippedParentIds.canFind(thisItemId)) {
							if (isItemFolder(onedriveJSONItem)) {
								// Detail we are skipping this JSON data from online
								addLogEntry("Skipping path - excluded by sync_list config: " ~ newItemPath, ["verbose"]);
								// Add this folder id to the elements we have already detailed we are skipping, so we do no output this again
								syncListSkippedParentIds ~= thisItemId;
							}
						}
						
						// If this is a 'add shortcut to onedrive' link, we need to actually scan this path, so add this we need to pass this JSON
						if (isItemRemote(onedriveJSONItem)) {
							addLogEntry("Skipping shared folder shortcut - excluded by sync_list config: " ~ newItemPath, ["verbose"]);
						}
					}
				} else {
					// Is this a file or directory?
					if (isItemFile(onedriveJSONItem)) {
						// File included due to 'sync_list' match
						addLogEntry("Including file - included by sync_list config: " ~ newItemPath, ["verbose"]);
						
						// Is the parent item in the database?
						if (!parentInDatabase) {
							// Parental database structure needs to be created
							addLogEntry("Parental Path structure needs to be created to support included file: " ~ dirName(newItemPath), ["verbose"]);
							// Recursivly, stepping backward from 'thisItemParentId', query online, save entry to DB
							createLocalPathStructure(onedriveJSONItem);
						}
					} else {
						// Directory included due to 'sync_list' match
						addLogEntry("Including path - included by sync_list config: " ~ newItemPath, ["verbose"]);
					}
				}
			}
		}
		
		// Check if this is excluded by a user set maximum filesize to download
		if (!clientSideRuleExcludesPath) {
			if (isItemFile(onedriveJSONItem)) {
				if (fileSizeLimit != 0) {
					if (onedriveJSONItem["size"].integer >= fileSizeLimit) {
						addLogEntry("Skipping file - excluded by skip_size config: " ~ thisItemName ~ " (" ~ to!string(onedriveJSONItem["size"].integer/2^^20) ~ " MB)", ["verbose"]);
						clientSideRuleExcludesPath = true;
					}
				}
			}
		}
		
		// return if path is excluded
		return clientSideRuleExcludesPath;
	}
	
	// When using 'sync_list' if a file is to be included, ensure that the path that the file resides in, is available locally and in the database
	void createLocalPathStructure(JSONValue onedriveJSONItem) {
	
		// Function variables
		bool parentInDatabase;
		JSONValue onlinePathData;
		OneDriveApi onlinePathOneDriveApiInstance;
		onlinePathOneDriveApiInstance = new OneDriveApi(appConfig);
		onlinePathOneDriveApiInstance.initialise();
		
		// Configure these variables based on the JSON input
		string thisItemDriveId = onedriveJSONItem["parentReference"]["driveId"].str;
		string thisItemParentId = onedriveJSONItem["parentReference"]["id"].str;
		
		// Calculate if the Parent Item is in the database so that it can be re-used
		parentInDatabase = itemDB.idInLocalDatabase(thisItemDriveId, thisItemParentId);
		
		// Is the parent in the database?
		if (!parentInDatabase) {
			// Get data from online for this driveId and itemId
			try {
				onlinePathData = onlinePathOneDriveApiInstance.getPathDetailsById(thisItemDriveId, thisItemParentId);
			} catch (OneDriveException exception) {
				// Display what the error is
				// - 408,429,503,504 errors are handled as a retry within uploadFileOneDriveApiInstance
				displayOneDriveErrorMessage(exception.msg, getFunctionName!({}));
			} 
			
			// Does this JSON match the root name of a shared folder we may be trying to match?
			if (sharedFolderDeltaGeneration) {
				if (currentSharedFolderName == onlinePathData["name"].str) {
					createDatabaseRootTieRecordForOnlineSharedFolder(onlinePathData);
				}
			} 
			
			// Configure the grandparent items
			string grandparentItemDriveId;
			string grandparentItemParentId;
			grandparentItemDriveId = onlinePathData["parentReference"]["driveId"].str;
			
			// OneDrive Personal JSON responses are in-consistent with not having 'id' available
			if (hasParentReferenceId(onlinePathData)) {
				// Use the parent reference id
				grandparentItemParentId = onlinePathData["parentReference"]["id"].str;
			} else {
				// Testing evidence shows that for Personal accounts, use the 'id' itself
				grandparentItemParentId = onlinePathData["id"].str;
			}
			
			// Is this item's grandparent data in the database?
			if (!itemDB.idInLocalDatabase(grandparentItemDriveId, grandparentItemParentId)) {
				// grandparent needs to be added
				createLocalPathStructure(onlinePathData);
			}
			
			// Save JSON to database
			saveItem(onlinePathData);
		}
		
		// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
		onlinePathOneDriveApiInstance.releaseCurlEngine();
		onlinePathOneDriveApiInstance = null;
		// Perform Garbage Collection
		GC.collect();
	}
	
	// Process the list of local changes to upload to OneDrive
	void processChangedLocalItemsToUpload() {
		
		// Each element in this array 'databaseItemsWhereContentHasChanged' is an Database Item ID that has been modified locally
		size_t batchSize = to!int(appConfig.getValueLong("threads"));
		ulong batchCount = (databaseItemsWhereContentHasChanged.length + batchSize - 1) / batchSize;
		ulong batchesProcessed = 0;
		
		// For each batch of files to upload, upload the changed data to OneDrive
		foreach (chunk; databaseItemsWhereContentHasChanged.chunks(batchSize)) {
			processChangedLocalItemsToUploadInParallel(chunk);
			chunk = null;
		}
	}

	// Process all the changed local items in parallel
	void processChangedLocalItemsToUploadInParallel(string[3][] array) {
		// This function received an array of string items to upload, the number of elements based on appConfig.getValueLong("threads")
		foreach (i, localItemDetails; processPool.parallel(array)) {
			addLogEntry("Upload Thread " ~ to!string(i) ~ " Starting: " ~ to!string(Clock.currTime()), ["debug"]);
			uploadChangedLocalFileToOneDrive(localItemDetails);
			addLogEntry("Upload Thread " ~ to!string(i) ~ " Finished: " ~ to!string(Clock.currTime()), ["debug"]);
		}
	}
	
	// Upload changed local files to OneDrive in parallel
	void uploadChangedLocalFileToOneDrive(string[3] localItemDetails) {
		
		// These are the details of the item we need to upload
		string changedItemParentId = localItemDetails[0];
		string changedItemId = localItemDetails[1];
		string localFilePath = localItemDetails[2];
		
		// Log the path that was modified
		addLogEntry("uploadChangedLocalFileToOneDrive: " ~ localFilePath, ["debug"]);
		
		// How much space is remaining on OneDrive
		ulong remainingFreeSpace;
		// Did the upload fail?
		bool uploadFailed = false;
		// Did we skip due to exceeding maximum allowed size?
		bool skippedMaxSize = false;
		// Did we skip to an exception error?
		bool skippedExceptionError = false;
		// Flag for if space is available online
		bool spaceAvailableOnline = false;
		
		// When we are uploading OneDrive Business Shared Files, we need to be targeting the right driveId and itemId
		string targetDriveId;
		string targetItemId;
		
		// Unfortunately, we cant store an array of Item's ... so we have to re-query the DB again - unavoidable extra processing here
		// This is because the Item[] has no other functions to allow is to parallel process those elements, so we have to use a string array as input to this function
		Item dbItem;
		itemDB.selectById(changedItemParentId, changedItemId, dbItem);
		
		// Is this a remote target?
		if ((dbItem.type == ItemType.remote) && (dbItem.remoteType == ItemType.file)) {
			// This is a remote file
			targetDriveId = dbItem.remoteDriveId;
			targetItemId = dbItem.remoteId;
			// we are going to make the assumption here that as this is a OneDrive Business Shared File, that there is space available
			spaceAvailableOnline = true;
		} else {
			// This is not a remote file
			targetDriveId = dbItem.driveId;
			targetItemId = dbItem.id;
		}
			
		// Fetch the details from cachedOnlineDriveData
		// - cachedOnlineDriveData.quotaRestricted;
		// - cachedOnlineDriveData.quotaAvailable;
		// - cachedOnlineDriveData.quotaRemaining;
		DriveDetailsCache cachedOnlineDriveData;
		cachedOnlineDriveData = getDriveDetails(targetDriveId);
		remainingFreeSpace = cachedOnlineDriveData.quotaRemaining;
		
		// Get the file size from the actual file
		ulong thisFileSizeLocal = getSize(localFilePath);
		// Get the file size from the DB data
		ulong thisFileSizeFromDB;
		if (!dbItem.size.empty) {
			thisFileSizeFromDB = to!ulong(dbItem.size);
		} else {
			thisFileSizeFromDB = 0;
		}
		
		// 'remainingFreeSpace' online includes the current file online
		// We need to remove the online file (add back the existing file size) then take away the new local file size to get a new approximate value
		ulong calculatedSpaceOnlinePostUpload = (remainingFreeSpace + thisFileSizeFromDB) - thisFileSizeLocal;
		
		// Based on what we know, for this thread - can we safely upload this modified local file?
		addLogEntry("This Thread Estimated Free Space Online:              " ~ to!string(remainingFreeSpace), ["debug"]);
		addLogEntry("This Thread Calculated Free Space Online Post Upload: " ~ to!string(calculatedSpaceOnlinePostUpload), ["debug"]);
		JSONValue uploadResponse;
		
		// Is there quota available for the given drive where we are uploading to?
		// 	If 'personal' accounts, if driveId == defaultDriveId, then we will have quota data - cachedOnlineDriveData.quotaRemaining will be updated so it can be reused
		// 	If 'personal' accounts, if driveId != defaultDriveId, then we will not have quota data - cachedOnlineDriveData.quotaRestricted will be set as true
		// 	If 'business' accounts, if driveId == defaultDriveId, then we will potentially have quota data - cachedOnlineDriveData.quotaRemaining will be updated so it can be reused
		// 	If 'business' accounts, if driveId != defaultDriveId, then we will potentially have quota data, but it most likely will be a 0 value - cachedOnlineDriveData.quotaRestricted will be set as true
		if (cachedOnlineDriveData.quotaAvailable) {
			// Our query told us we have free space online .. if we upload this file, will we exceed space online - thus upload will fail during upload?
			if (calculatedSpaceOnlinePostUpload > 0) {
				// Based on this thread action, we believe that there is space available online to upload - proceed
				spaceAvailableOnline = true;
			}
		}
		
		// Is quota being restricted?
		if (cachedOnlineDriveData.quotaRestricted) {
			// Space available online is being restricted - so we have no way to really know if there is space available online
			spaceAvailableOnline = true;
		}
			
		// Do we have space available or is space available being restricted (so we make the blind assumption that there is space available)
		if (spaceAvailableOnline) {
			// Does this file exceed the maximum file size to upload to OneDrive?
			if (thisFileSizeLocal <= maxUploadFileSize) {
				// Attempt to upload the modified file
				// Error handling is in performModifiedFileUpload(), and the JSON that is responded with - will either be null or a valid JSON object containing the upload result
				uploadResponse = performModifiedFileUpload(dbItem, localFilePath, thisFileSizeLocal);
				
				// Evaluate the returned JSON uploadResponse
				// If there was an error uploading the file, uploadResponse should be empty and invalid
				if (uploadResponse.type() != JSONType.object) {
					uploadFailed = true;
					skippedExceptionError = true;
				}
				
			} else {
				// Skip file - too large
				uploadFailed = true;
				skippedMaxSize = true;
			}
		} else {
			// Cant upload this file - no space available
			uploadFailed = true;
		}
		
		// Did the upload fail?
		if (uploadFailed) {
			// Upload failed .. why?
			// No space available online
			if (!spaceAvailableOnline) {
				addLogEntry("Skipping uploading modified file: " ~ localFilePath ~ " due to insufficient free space available on Microsoft OneDrive", ["info", "notify"]);
			}
			// File exceeds max allowed size
			if (skippedMaxSize) {
				addLogEntry("Skipping uploading this modified file as it exceeds the maximum size allowed by Microsoft OneDrive: " ~ localFilePath, ["info", "notify"]);
			}
			// Generic message
			if (skippedExceptionError) {
				// normal failure message if API or exception error generated
				// If Issue #2626 | Case 2-1 is triggered, the file we tried to upload was renamed, then uploaded as a new name
				if (exists(localFilePath)) {
					// Issue #2626 | Case 2-1 was not triggered, file still exists on local filesystem
					addLogEntry("Uploading modified file: " ~ localFilePath ~ " ... failed!", ["info", "notify"]);
				}
			}
		} else {
			// Upload was successful
			addLogEntry("Uploading modified file: " ~ localFilePath ~ " ... done.", ["info", "notify"]);
			
			// What do we save to the DB? Is this a OneDrive Business Shared File?
			if ((dbItem.type == ItemType.remote) && (dbItem.remoteType == ItemType.file)) {
				// We need to 'massage' the old DB record, with data from online, as the DB record was specifically crafted for OneDrive Business Shared Files
				Item tempItem = makeItem(uploadResponse);
				dbItem.eTag = tempItem.eTag;
				dbItem.cTag = tempItem.cTag;
				dbItem.mtime = tempItem.mtime;
				dbItem.quickXorHash = tempItem.quickXorHash;
				dbItem.sha256Hash = tempItem.sha256Hash;
				dbItem.size = tempItem.size;
				itemDB.upsert(dbItem);
			} else {
				// Save the response JSON item in database as is
				saveItem(uploadResponse);
			}
			
			// Update the 'cachedOnlineDriveData' record for this 'targetDriveId' so that this is tracked as accurately as possible for other threads
			updateDriveDetailsCache(targetDriveId, cachedOnlineDriveData.quotaRestricted, cachedOnlineDriveData.quotaAvailable, thisFileSizeLocal);
			
			// Check the integrity of the uploaded modified file if not in a --dry-run scenario
			if (!dryRun) {
				// Perform the integrity of the uploaded modified file
				performUploadIntegrityValidationChecks(uploadResponse, localFilePath, thisFileSizeLocal);
				
				// Update the date / time of the file online to match the local item
				// Get the local file last modified time
				SysTime localModifiedTime = timeLastModified(localFilePath).toUTC();
				localModifiedTime.fracSecs = Duration.zero;
				// Get the latest eTag, and use that
				string etagFromUploadResponse = uploadResponse["eTag"].str;
				// Attempt to update the online date time stamp based on our local data
				uploadLastModifiedTime(dbItem, targetDriveId, targetItemId, localModifiedTime, etagFromUploadResponse);
			}
		}
	}
	
	// Perform the upload of a locally modified file to OneDrive
	JSONValue performModifiedFileUpload(Item dbItem, string localFilePath, ulong thisFileSizeLocal) {
			
		// Function variables
		JSONValue uploadResponse;
		OneDriveApi uploadFileOneDriveApiInstance;
		uploadFileOneDriveApiInstance = new OneDriveApi(appConfig);
		uploadFileOneDriveApiInstance.initialise();
		
		// Configure JSONValue variables we use for a session upload
		JSONValue currentOnlineData;
		JSONValue uploadSessionData;
		string currentETag;
		
		// When we are uploading OneDrive Business Shared Files, we need to be targeting the right driveId and itemId
		string targetDriveId;
		string targetParentId;
		string targetItemId;
		
		// Is this a remote target?
		if ((dbItem.type == ItemType.remote) && (dbItem.remoteType == ItemType.file)) {
			// This is a remote file
			targetDriveId = dbItem.remoteDriveId;
			targetParentId = dbItem.remoteParentId;
			targetItemId = dbItem.remoteId;
		} else {
			// This is not a remote file
			targetDriveId = dbItem.driveId;
			targetParentId = dbItem.parentId;
			targetItemId = dbItem.id;
		}
		
		// Is this a dry-run scenario?
		if (!dryRun) {
			// Do we use simpleUpload or create an upload session?
			bool useSimpleUpload = false;
			
			// Try and get the absolute latest object details from online, so we get the latest eTag to try and avoid a 412 eTag error
			try {
				currentOnlineData = uploadFileOneDriveApiInstance.getPathDetailsById(targetDriveId, targetItemId);
			} catch (OneDriveException exception) {
				// Display what the error is
				// - 408,429,503,504 errors are handled as a retry within uploadFileOneDriveApiInstance
				displayOneDriveErrorMessage(exception.msg, getFunctionName!({}));
			}
			
			// Was a valid JSON response provided?
			if (currentOnlineData.type() == JSONType.object) {
				// Does the response contain an eTag?
				if (hasETag(currentOnlineData)) {
					// Use the value returned from online as this will attempt to avoid a 412 response if we are creating a session upload
					currentETag = currentOnlineData["eTag"].str;
				} else {
					// Use the database value - greater potential for a 412 error to occur if we are creating a session upload
					addLogEntry("Online data for file returned zero eTag - using database eTag value", ["debug"]);
					currentETag = dbItem.eTag;
				}
			} else {
				// no valid JSON response - greater potential for a 412 error to occur if we are creating a session upload
				addLogEntry("Online data returned was invalid - using database eTag value", ["debug"]);
				currentETag = dbItem.eTag;
			}
			
			// What upload method should be used?
			if (thisFileSizeLocal <= sessionThresholdFileSize) {
				useSimpleUpload = true;
			}
		
			// If the filesize is greater than zero , and we have valid 'latest' online data is the online file matching what we think is in the database?
			if ((thisFileSizeLocal > 0) && (currentOnlineData.type() == JSONType.object)) {
				// Issue #2626 | Case 2-1 
				// If the 'online' file is newer, this will be overwritten with the file from the local filesystem - potentially constituting online data loss
				Item onlineFile = makeItem(currentOnlineData);
				
				// Which file is technically newer? The local file or the remote file?
				SysTime localModifiedTime = timeLastModified(localFilePath).toUTC();
				SysTime onlineModifiedTime = onlineFile.mtime;
				
				// Reduce time resolution to seconds before comparing
				localModifiedTime.fracSecs = Duration.zero;
				onlineModifiedTime.fracSecs = Duration.zero;
				
				// Which file is newer? If local is newer, it will be uploaded as a modified file in the correct manner
				if (localModifiedTime < onlineModifiedTime) {
					// Online File is actually newer than the locally modified file
					addLogEntry("currentOnlineData: " ~ to!string(currentOnlineData), ["debug"]);
					addLogEntry("onlineFile:    " ~ to!string(onlineFile), ["debug"]);
					addLogEntry("database item: " ~ to!string(dbItem), ["debug"]);
					addLogEntry("Skipping uploading this item as a locally modified file, will upload as a new file (online file already exists and is newer): " ~ localFilePath);
					
					// Online is newer, rename local, then upload the renamed file
					// We need to know the renamed path so we can upload it
					string renamedPath;
					// Rename the local path
					safeBackup(localFilePath, dryRun, renamedPath);
					// Upload renamed local file as a new file
					uploadNewFile(renamedPath);
					
					// Process the database entry removal for the original file. In a --dry-run scenario, this is being done against a DB copy.
					// This is done so we can download the newer online file
					itemDB.deleteById(targetDriveId, targetItemId);

					// This file is now uploaded, return from here, but this will trigger a response that the upload failed (technically for the original filename it did, but we renamed it, then uploaded it
					return uploadResponse;
				}
			}
			
			// We can only upload zero size files via simpleFileUpload regardless of account type
			// Reference: https://github.com/OneDrive/onedrive-api-docs/issues/53
			// Additionally, all files where file size is < 4MB should be uploaded by simpleUploadReplace - everything else should use a session to upload the modified file
			if ((thisFileSizeLocal == 0) || (useSimpleUpload)) {
				// Must use Simple Upload to replace the file online
				try {
					uploadResponse = uploadFileOneDriveApiInstance.simpleUploadReplace(localFilePath, targetDriveId, targetItemId);
				} catch (OneDriveException exception) {
					// Function name
					string thisFunctionName = getFunctionName!({});
					// HTTP request returned status code 403
					if ((exception.httpStatusCode == 403) && (appConfig.getValueBool("sync_business_shared_files"))) {
						// We attempted to upload a file, that was shared with us, but this was shared with us as read-only
						addLogEntry("Unable to upload this modified file as this was shared as read-only: " ~ localFilePath);
					}
					// HTTP request returned status code 423
					// Resolve https://github.com/abraunegg/onedrive/issues/36
					if (exception.httpStatusCode == 423) {
						// The file is currently checked out or locked for editing by another user
						// We cant upload this file at this time
						addLogEntry("Unable to upload this modified file as this is currently checked out or locked for editing by another user: " ~ localFilePath);
					} else {
						// Handle all other HTTP status codes
						// - 408,429,503,504 errors are handled as a retry within uploadFileOneDriveApiInstance
						// Display what the error is
						displayOneDriveErrorMessage(exception.msg, thisFunctionName);
					}
				} catch (FileException e) {
					// filesystem error
					displayFileSystemErrorMessage(e.msg, getFunctionName!({}));
				}
			} else {
				// As this is a unique thread, the sessionFilePath for where we save the data needs to be unique
				// The best way to do this is generate a 10 digit alphanumeric string, and use this as the file extension
				string threadUploadSessionFilePath = appConfig.uploadSessionFilePath ~ "." ~ generateAlphanumericString();
				
				// Create the upload session
				try {
					uploadSessionData = createSessionFileUpload(uploadFileOneDriveApiInstance, localFilePath, targetDriveId, targetParentId, baseName(localFilePath), currentETag, threadUploadSessionFilePath);
				} catch (OneDriveException exception) {
					
					string thisFunctionName = getFunctionName!({});
					
					// HTTP request returned status code 403
					if ((exception.httpStatusCode == 403) && (appConfig.getValueBool("sync_business_shared_files"))) {
						// We attempted to upload a file, that was shared with us, but this was shared with us as read-only
						addLogEntry("Unable to upload this modified file as this was shared as read-only: " ~ localFilePath);
						return uploadResponse;
					} 
					// HTTP request returned status code 423
					// Resolve https://github.com/abraunegg/onedrive/issues/36
					if (exception.httpStatusCode == 423) {
						// The file is currently checked out or locked for editing by another user
						// We cant upload this file at this time
						addLogEntry("Unable to upload this modified file as this is currently checked out or locked for editing by another user: " ~ localFilePath);
						return uploadResponse;
					} else {
						// Handle all other HTTP status codes
						// - 408,429,503,504 errors are handled as a retry within uploadFileOneDriveApiInstance
						// Display what the error is
						displayOneDriveErrorMessage(exception.msg, thisFunctionName);
					}
					
				} catch (FileException e) {
					writeln("DEBUG TO REMOVE: Modified file upload FileException Handling (Create the Upload Session)");
					displayFileSystemErrorMessage(e.msg, getFunctionName!({}));
				}
				
				// Perform the upload using the session that has been created
				try {
					uploadResponse = performSessionFileUpload(uploadFileOneDriveApiInstance, thisFileSizeLocal, uploadSessionData, threadUploadSessionFilePath);
				} catch (OneDriveException exception) {
					// Function name
					string thisFunctionName = getFunctionName!({});
					
					// Handle all other HTTP status codes
					// - 408,429,503,504 errors are handled as a retry within uploadFileOneDriveApiInstance
					// Display what the error is
					displayOneDriveErrorMessage(exception.msg, thisFunctionName);
					
				} catch (FileException e) {
					writeln("DEBUG TO REMOVE: Modified file upload FileException Handling (Perform the Upload using the session)");
					displayFileSystemErrorMessage(e.msg, getFunctionName!({}));
				}
			}
		} else {
			// We are in a --dry-run scenario
			uploadResponse = createFakeResponse(localFilePath);
		}
		
		// Debug Log the modified upload response
		addLogEntry("Modified File Upload Response: " ~ to!string(uploadResponse), ["debug"]);
		
		// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
		uploadFileOneDriveApiInstance.releaseCurlEngine();
		uploadFileOneDriveApiInstance = null;
		// Perform Garbage Collection
		GC.collect();
		
		// Return JSON
		return uploadResponse;
	}
		
	// Query the OneDrive API using the provided driveId to get the latest quota details
	string[3][] getRemainingFreeSpaceOnline(string driveId) {
		// Get the quota details for this driveId
		// Quota details are ONLY available for the main default driveId, as the OneDrive API does not provide quota details for shared folders
		JSONValue currentDriveQuota;
		bool quotaRestricted = false; // Assume quota is not restricted unless "remaining" is missing
		bool quotaAvailable = false;
		ulong quotaRemainingOnline = 0;
		string[3][] result;
		OneDriveApi getCurrentDriveQuotaApiInstance;

		// Ensure that we have a valid driveId to query
		if (driveId.empty) {
			// No 'driveId' was provided, use the application default
			driveId = appConfig.defaultDriveId;
		}

		// Try and query the quota for the provided driveId
		try {
			// Create a new OneDrive API instance
			getCurrentDriveQuotaApiInstance = new OneDriveApi(appConfig);
			getCurrentDriveQuotaApiInstance.initialise();
			addLogEntry("Seeking available quota for this drive id: " ~ driveId, ["debug"]);
			currentDriveQuota = getCurrentDriveQuotaApiInstance.getDriveQuota(driveId);
			
			// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
			getCurrentDriveQuotaApiInstance.releaseCurlEngine();
			getCurrentDriveQuotaApiInstance = null;
			// Perform Garbage Collection
			GC.collect();
			
		} catch (OneDriveException e) {
			addLogEntry("currentDriveQuota = onedrive.getDriveQuota(driveId) generated a OneDriveException", ["debug"]);
			// If an exception occurs, it's unclear if quota is restricted, but quota details are not available
			quotaRestricted = true; // Considering restricted due to failure to access
			// Return result
			result ~= [to!string(quotaRestricted), to!string(quotaAvailable), to!string(quotaRemainingOnline)];
			
			// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
			getCurrentDriveQuotaApiInstance.releaseCurlEngine();
			getCurrentDriveQuotaApiInstance = null;
			// Perform Garbage Collection
			GC.collect();
			return result;
		}
		
		// Validate that currentDriveQuota is a JSON value
		if (currentDriveQuota.type() == JSONType.object && "quota" in currentDriveQuota) {
			// Response from API contains valid data
			// If 'personal' accounts, if driveId == defaultDriveId, then we will have data
			// If 'personal' accounts, if driveId != defaultDriveId, then we will not have quota data
			// If 'business' accounts, if driveId == defaultDriveId, then we will have data
			// If 'business' accounts, if driveId != defaultDriveId, then we will have data, but it will be a 0 value
			addLogEntry("Quota Details: " ~ to!string(currentDriveQuota), ["debug"]);
			
			auto quota = currentDriveQuota["quota"];
			if ("remaining" in quota) {
				quotaRemainingOnline = quota["remaining"].integer;
				quotaAvailable = quotaRemainingOnline > 0;
				// If "remaining" is present but its value is <= 0, it's not restricted but exhausted
				if (quotaRemainingOnline <= 0) {
					if (appConfig.accountType == "personal") {
						addLogEntry("ERROR: OneDrive account currently has zero space available. Please free up some space online or purchase additional capacity.");
					} else { // Assuming 'business' or 'sharedLibrary'
						addLogEntry("WARNING: OneDrive quota information is being restricted or providing a zero value. Please fix by speaking to your OneDrive / Office 365 Administrator.");
					}
				}
			} else {
				// "remaining" not present, indicating restricted quota information
				quotaRestricted = true;
				addLogEntry("Quota information is restricted or not available for this drive.", ["verbose"]);
			}
		} else {
			// When valid quota details are not fetched
			addLogEntry("Failed to fetch or query quota details for OneDrive Drive ID: " ~ driveId, ["verbose"]);
			quotaRestricted = true; // Considering restricted due to failure to interpret
		}

		// What was the determined available quota?
		addLogEntry("Reported Available Online Quota for driveID '" ~ driveId ~ "': " ~ to!string(quotaRemainingOnline), ["debug"]);
		
		// Return result
		result ~= [to!string(quotaRestricted), to!string(quotaAvailable), to!string(quotaRemainingOnline)];
		return result;
	}

	// Perform a filesystem walk to uncover new data to upload to OneDrive
	void scanLocalFilesystemPathForNewData(string path) {
		// Cleanup array memory before we start adding files
		pathsToCreateOnline = [];
		newLocalFilesToUploadToOneDrive = [];
		
		// Perform a filesystem walk to uncover new data
		scanLocalFilesystemPathForNewDataToUpload(path);
		
		// Create new directories online that has been identified
		processNewDirectoriesToCreateOnline();
		
		// Upload new data that has been identified
		processNewLocalItemsToUpload();
	}

	// Scan the local filesystem for new data to upload
	void scanLocalFilesystemPathForNewDataToUpload(string path) {
		// To improve logging output for this function, what is the 'logical path' we are scanning for file & folder differences?
		string logPath;
		if (path == ".") {
			// get the configured sync_dir
			logPath = buildNormalizedPath(appConfig.getValueString("sync_dir"));
		} else {
			// use what was passed in
			if (!appConfig.getValueBool("monitor")) {
				logPath = buildNormalizedPath(appConfig.getValueString("sync_dir")) ~ "/" ~ path;
			} else {
				logPath = path;
			}
		}
		
		// Log the action that we are performing, however only if this is a directory
		if (isDir(path)) {
			if (!appConfig.suppressLoggingOutput) {
				if (!cleanupLocalFiles) {
					addProcessingLogHeaderEntry("Scanning the local file system '" ~ logPath ~ "' for new data to upload", appConfig.verbosityCount);
				} else {
					addProcessingLogHeaderEntry("Scanning the local file system '" ~ logPath ~ "' for data to cleanup", appConfig.verbosityCount);
					// Set the cleanup flag
					cleanupDataPass = true;
				}
			}
		}
		
		auto startTime = Clock.currTime();
		addLogEntry("Starting Filesystem Walk:     " ~ to!string(startTime), ["debug"]);
		
		// Add a processing '.' if this is a directory we are scanning
		if (isDir(path)) {
			if (!appConfig.suppressLoggingOutput) {
				if (appConfig.verbosityCount == 0) {
					addProcessingDotEntry();
				}
			}
		}
		
		// Perform the filesystem walk of this path, building an array of new items to upload
		scanPathForNewData(path);
		// Reset flag
		cleanupDataPass = false;
		
		// Close processing '.' if this is a directory we are scanning
		if (isDir(path)) {
			if (appConfig.verbosityCount == 0) {
				if (!appConfig.suppressLoggingOutput) {
					// Close out the '....' being printed to the console
					completeProcessingDots();
				}
			}
		}
		
		// To finish off the processing items, this is needed to reflect this in the log
		addLogEntry("------------------------------------------------------------------", ["debug"]);
		
		auto finishTime = Clock.currTime();
		addLogEntry("Finished Filesystem Walk:     " ~ to!string(finishTime), ["debug"]);
		
		auto elapsedTime = finishTime - startTime;
		addLogEntry("Elapsed Time Filesystem Walk: " ~ to!string(elapsedTime), ["debug"]);
	}
	
	void processNewDirectoriesToCreateOnline() {
		// Are there any new local directories to create online?
		if (!pathsToCreateOnline.empty) {
			// There are new directories to create online
			addLogEntry("New directories to create on Microsoft OneDrive: " ~ to!string(pathsToCreateOnline.length) );
			foreach(pathToCreateOnline; pathsToCreateOnline) {
				// Create this directory on OneDrive so that we can upload files to it
				createDirectoryOnline(pathToCreateOnline);
			}
		}
	}
	
	// Upload new data that has been identified to Microsoft OneDrive
	void processNewLocalItemsToUpload() {
		// Are there any new local items to upload?
		if (!newLocalFilesToUploadToOneDrive.empty) {
			// There are elements to upload
			addLogEntry("New items to upload to Microsoft OneDrive: " ~ to!string(newLocalFilesToUploadToOneDrive.length) );
			
			// Reset totalDataToUpload
			totalDataToUpload = 0;
			
			// How much data do we need to upload? This is important, as, we need to know how much data to determine if all the files can be uploaded
			foreach (uploadFilePath; newLocalFilesToUploadToOneDrive) {
				// validate that the path actually exists so that it can be counted
				if (exists(uploadFilePath)) {
					totalDataToUpload = totalDataToUpload + getSize(uploadFilePath);
				}
			}
			
			// How much data is there to upload
			if (totalDataToUpload < 1024) {
				// Display as Bytes to upload
				addLogEntry("Total New Data to Upload:        " ~ to!string(totalDataToUpload) ~ " Bytes", ["verbose"]);
			} else {
				if ((totalDataToUpload > 1024) && (totalDataToUpload < 1048576)) {
					// Display as KB to upload
					addLogEntry("Total New Data to Upload:        " ~ to!string((totalDataToUpload / 1024)) ~ " KB", ["verbose"]);
				} else {
					// Display as MB to upload
					addLogEntry("Total New Data to Upload:        " ~ to!string((totalDataToUpload / 1024 / 1024)) ~ " MB", ["verbose"]);
				}
			}
			
			// How much space is available 
			// The file, could be uploaded to a shared folder, which, we are not tracking how much free space is available there ... 
			// Iterate through all the drives we have cached thus far, that we know about
			foreach (driveId, driveDetails; onlineDriveDetails) {
				// Log how much space is available for each driveId
				addLogEntry("Current Available Space Online (" ~ driveId ~ "): " ~ to!string((driveDetails.quotaRemaining / 1024 / 1024)) ~ " MB", ["debug"]);
			}
			
			// Perform the upload
			uploadNewLocalFileItems();
			
			// Cleanup array memory after uploading all files
			newLocalFilesToUploadToOneDrive = [];
		}
	}
	
	// Scan this path for new data
	void scanPathForNewData(string path) {
	
		// Add a processing '.'
		if (isDir(path)) {
			if (!appConfig.suppressLoggingOutput) {
				if (appConfig.verbosityCount == 0) {
					addProcessingDotEntry();
				}
			}
		}

		ulong maxPathLength;
		ulong pathWalkLength;
		
		// Add this logging break to assist with what was checked for each path
		if (path != ".") {
			addLogEntry("------------------------------------------------------------------", ["debug"]);
		}
		
		// https://support.microsoft.com/en-us/help/3125202/restrictions-and-limitations-when-you-sync-files-and-folders
		// If the path is greater than allowed characters, then one drive will return a '400 - Bad Request'
		// Need to ensure that the URI is encoded before the check is made:
		// - 400 Character Limit for OneDrive Business / Office 365
		// - 430 Character Limit for OneDrive Personal
		
		// Configure maxPathLength based on account type
		if (appConfig.accountType == "personal") {
			// Personal Account
			maxPathLength = 430;
		} else {
			// Business Account / Office365 / SharePoint
			maxPathLength = 400;
		}
		
		// OneDrive Business Shared Files Handling - if we make a 'backup' locally of a file shared with us (because we modified it, and then maybe did a --resync), it will be treated as a new file to upload ...
		// The issue here is - the 'source' was a shared file - we may not even have permission to upload a 'renamed' file to the shared file's parent folder
		// In this case, we need to skip adding this new local file - we do not upload it (we cant , and we should not)
		if (appConfig.accountType == "business") {
			// Check appConfig.configuredBusinessSharedFilesDirectoryName against 'path'
			if (canFind(path, baseName(appConfig.configuredBusinessSharedFilesDirectoryName))) {
				// Log why this path is being skipped
				addLogEntry("Skipping scanning path for new files as this is reserved for OneDrive Business Shared Files: " ~ path, ["info"]);
				return;
			}
		}
				
		// A short lived item that has already disappeared will cause an error - is the path still valid?
		if (!exists(path)) {
			addLogEntry("Skipping path - path has disappeared: " ~ path);
			return;
		}
		
		// Calculate the path length by walking the path and catch any UTF-8 sequence errors at the same time
		// https://github.com/skilion/onedrive/issues/57
		// https://github.com/abraunegg/onedrive/issues/487
		// https://github.com/abraunegg/onedrive/issues/1192
		try {
			pathWalkLength = path.byGrapheme.walkLength;
		} catch (std.utf.UTFException e) {
			// Path contains characters which generate a UTF exception
			addLogEntry("Skipping item - invalid UTF sequence: " ~ path, ["info", "notify"]);
			addLogEntry("  Error Reason:" ~ e.msg, ["debug"]);
			return;
		}
		
		// Is the path length is less than maxPathLength
		if (pathWalkLength < maxPathLength) {
			// Is this path unwanted
			bool unwanted = false;
			
			// First check of this item - if we are in a --dry-run scenario, we may have 'fake deleted' this path
			// thus, the entries are not in the dry-run DB copy, thus, at this point the client thinks that this is an item to upload
			// Check this 'path' for an entry in pathFakeDeletedArray - if it is there, this is unwanted
			if (dryRun) {
				// Is this path in the array of fake deleted items? If yes, return early, nothing else to do, save processing
				if (canFind(pathFakeDeletedArray, path)) return;
			}
			
			// Check if item if found in database
			bool itemFoundInDB = pathFoundInDatabase(path);
			
			// If the item is already found in the database, it is redundant to perform these checks
			if (!itemFoundInDB) {
				// This not a Client Side Filtering check, nor a Microsoft Check, but is a sanity check that the path provided is UTF encoded correctly
				// Check the std.encoding of the path against: Unicode 5.0, ASCII, ISO-8859-1, ISO-8859-2, WINDOWS-1250, WINDOWS-1251, WINDOWS-1252
				if (!unwanted) {
					if(!isValid(path)) {
						// Path is not valid according to https://dlang.org/phobos/std_encoding.html
						addLogEntry("Skipping item - invalid character encoding sequence: " ~ path, ["info", "notify"]);
						unwanted = true;
					}
				}
				
				// Check this path against the Client Side Filtering Rules
				// - check_nosync
				// - skip_dotfiles
				// - skip_symlinks
				// - skip_file
				// - skip_dir
				// - sync_list
				// - skip_size
				if (!unwanted) {
					// If this is not the cleanup data pass when using --download-only --cleanup-local-files we dont want to exclude files we need to delete locally when using 'sync_list'
					if (!cleanupDataPass) {
						unwanted = checkPathAgainstClientSideFiltering(path);
					}
				}
				
				// Check this path against the Microsoft Naming Conventions & Restristions
				// - Check path against Microsoft OneDrive restriction and limitations about Windows naming for files and folders
				// - Check path for bad whitespace items
				// - Check path for HTML ASCII Codes
				// - Check path for ASCII Control Codes
				if (!unwanted) {
					unwanted = checkPathAgainstMicrosoftNamingRestrictions(path);
				}
			}
			
			if (!unwanted) {
				// At this point, this path, we want to scan for new data as it is not excluded
				if (isDir(path)) {
					// Was the path found in the database?
					if (!itemFoundInDB) {
						// Path not found in database when searching all drive id's
						if (!cleanupLocalFiles) {
							// --download-only --cleanup-local-files not used
							// Create this directory on OneDrive so that we can upload files to it
							// Add this path to an array so that the directory online can be created before we upload files
							pathsToCreateOnline ~= [path];
						} else {
							// we need to clean up this directory
							addLogEntry("Removing local directory as --download-only & --cleanup-local-files configured");
							// Remove any children of this path if they still exist
							// Resolve 'Directory not empty' error when deleting local files
							try {
								auto directoryEntries = dirEntries(path, SpanMode.depth, false);
								foreach (DirEntry child; directoryEntries) {
									// what sort of child is this?
									if (isDir(child.name)) {
										addLogEntry("Removing local directory: " ~ child.name);
									} else {
										addLogEntry("Removing local file: " ~ child.name);
									}
									
									// are we in a --dry-run scenario?
									if (!dryRun) {
										// No --dry-run ... process local delete
										if (exists(child)) {
											try {
												attrIsDir(child.linkAttributes) ? rmdir(child.name) : remove(child.name);
											} catch (FileException e) {
												// display the error message
												displayFileSystemErrorMessage(e.msg, getFunctionName!({}));
											}
										}
									}
								}
								// Clear directoryEntries
								object.destroy(directoryEntries);
								
								// Remove the path now that it is empty of children
								addLogEntry("Removing local directory: " ~ path);
								// are we in a --dry-run scenario?
								if (!dryRun) {
									// No --dry-run ... process local delete
									if (exists(path)) {
									
										try {
											rmdirRecurse(path);
										} catch (FileException e) {
											// display the error message
											displayFileSystemErrorMessage(e.msg, getFunctionName!({}));
										}
										
									}
								}
							} catch (FileException e) {
								// display the error message
								displayFileSystemErrorMessage(e.msg, getFunctionName!({}));
								return;
							}
						}
					}
				
					// flag for if we are going traverse this path
					bool skipFolderTraverse = false;
					
					// Before we traverse this 'path', we need to make a last check to see if this was just excluded
					if (appConfig.accountType == "business") {
						// search businessSharedFoldersOnlineToSkip for this path
						if (canFind(businessSharedFoldersOnlineToSkip, path)) {
							// This path was skipped - why?
							addLogEntry("Skipping item '" ~ path ~ "' due to this path matching an existing online Business Shared Folder name", ["info", "notify"]);
							addLogEntry("To sync this Business Shared Folder, consider enabling 'sync_business_shared_folders' within your application configuration.", ["info"]);
							skipFolderTraverse = true;
						}
					}
					
					// Do we traverse this path?
					if (!skipFolderTraverse) {
						// Try and access this directory and any path below
						if (exists(path)) {
							try {
								auto directoryEntries = dirEntries(path, SpanMode.shallow, false);
								foreach (DirEntry entry; directoryEntries) {
									string thisPath = entry.name;
									scanPathForNewData(thisPath);
								}
								// Clear directoryEntries
								object.destroy(directoryEntries);
							} catch (FileException e) {
								// display the error message
								displayFileSystemErrorMessage(e.msg, getFunctionName!({}));
								return;
							}
						}
					}
				} else {
					// https://github.com/abraunegg/onedrive/issues/984
					// path is not a directory, is it a valid file?
					// pipes - whilst technically valid files, are not valid for this client
					//  prw-rw-r--.  1 user user    0 Jul  7 05:55 my_pipe
					if (isFile(path)) {
						// Is the file a '.nosync' file?
						if (canFind(path, ".nosync")) {
							addLogEntry("Skipping .nosync file", ["debug"]);
							return;
						}
					
						// Was the file found in the database?
						if (!itemFoundInDB) {
							// File not found in database when searching all drive id's
							// Do we upload the file or clean up the file?
							if (!cleanupLocalFiles) {
								// --download-only --cleanup-local-files not used
								// Add this path as a file we need to upload
								addLogEntry("OneDrive Client flagging to upload this file to Microsoft OneDrive: " ~ path, ["debug"]);
								newLocalFilesToUploadToOneDrive ~= path;
							} else {
								// we need to clean up this file
								addLogEntry("Removing local file as --download-only & --cleanup-local-files configured");
								// are we in a --dry-run scenario?
								addLogEntry("Removing local file: " ~ path);
								if (!dryRun) {
									// No --dry-run ... process local file delete
									safeRemove(path);
								}
							}
						}
					} else {
						// path is not a valid file
						addLogEntry("Skipping item - item is not a valid file: " ~ path, ["info", "notify"]);
					}
				}
			}
		} else {
			// This path was skipped - why?
			addLogEntry("Skipping item '" ~ path ~ "' due to the full path exceeding " ~ to!string(maxPathLength) ~ " characters (Microsoft OneDrive limitation)", ["info", "notify"]);
		}
	}
	
	// Handle a single file inotify trigger when using --monitor
	void handleLocalFileTrigger(string[] changedLocalFilesToUploadToOneDrive) {
		// Is this path a new file or an existing one?
		// Normally we would use pathFoundInDatabase() to calculate, but we need 'databaseItem' as well if the item is in the database
		foreach (localFilePath; changedLocalFilesToUploadToOneDrive) {
			try {
				Item databaseItem;
				bool fileFoundInDB = false;
				
				foreach (driveId; onlineDriveDetails.keys) {
					if (itemDB.selectByPath(localFilePath, driveId, databaseItem)) {
						fileFoundInDB = true;
						break;
					}
				}
				
				// Was the file found in the database?
				if (!fileFoundInDB) {
					// This is a new file as it is not in the database
					// Log that the file has been added locally
					addLogEntry("[M] New local file added: " ~ localFilePath, ["verbose"]);
					scanLocalFilesystemPathForNewDataToUpload(localFilePath);
				} else {
					// This is a potentially modified file, needs to be handled as such. Is the item truly modified?
					if (!testFileHash(localFilePath, databaseItem)) {
						// The local file failed the hash comparison test - there is a data difference
						// Log that the file has changed locally
						addLogEntry("[M] Local file changed: " ~ localFilePath, ["verbose"]);
						// Add the modified item to the array to upload
						uploadChangedLocalFileToOneDrive([databaseItem.driveId, databaseItem.id, localFilePath]);
					}
				}
			} catch(Exception e) {
				addLogEntry("Cannot upload file changes/creation: " ~ e.msg, ["info", "notify"]);
			}
		}
		processNewLocalItemsToUpload();
	}
	
	// Query the database to determine if this path is within the existing database
	bool pathFoundInDatabase(string searchPath) {
		
		// Check if this path in the database
		Item databaseItem;
		addLogEntry("Search DB for this path: " ~ searchPath, ["debug"]);
		
		foreach (driveId; onlineDriveDetails.keys) {
			if (itemDB.selectByPath(searchPath, driveId, databaseItem)) {
				addLogEntry("DB Record for search path: " ~ to!string(databaseItem), ["debug"]);
				return true; // Early exit on finding the path in the DB
			}
		}
		return false; // Return false if path is not found in any drive
	}
	
	// Create a new directory online on OneDrive
	// - Test if we can get the parent path details from the database, otherwise we need to search online
	//   for the path flow and create the folder that way
	void createDirectoryOnline(string thisNewPathToCreate) {
		// Log what we are doing
		addLogEntry("OneDrive Client requested to create this directory online: " ~ thisNewPathToCreate, ["verbose"]);
		
		// Function variables
		Item parentItem;
		JSONValue onlinePathData;
		
		// Special Folder Handling: Do NOT create the folder online if it is being used for OneDrive Business Shared Files
		// These are local copy files, in a self created directory structure which is not to be replicated online
		// Check appConfig.configuredBusinessSharedFilesDirectoryName against 'thisNewPathToCreate'
		if (canFind(thisNewPathToCreate, baseName(appConfig.configuredBusinessSharedFilesDirectoryName))) {
			// Log why this is being skipped
			addLogEntry("Skipping creating '" ~ thisNewPathToCreate ~ "' as this path is used for handling OneDrive Business Shared Files", ["info", "notify"]);
			return;
		}
		
		// Create a new API Instance for this thread and initialise it
		OneDriveApi createDirectoryOnlineOneDriveApiInstance;
		createDirectoryOnlineOneDriveApiInstance = new OneDriveApi(appConfig);
		createDirectoryOnlineOneDriveApiInstance.initialise();
		
		// What parent path to use?
		string parentPath = dirName(thisNewPathToCreate); // will be either . or something else
		
		// Configure the parentItem by if this is the account 'root' use the root details, or search the database for the parent details
		if (parentPath == ".") {
			// Parent path is '.' which is the account root
			// Use client defaults
			parentItem.driveId = appConfig.defaultDriveId; 	// Should give something like 12345abcde1234a1
			parentItem.id = appConfig.defaultRootId;  		// Should give something like 12345ABCDE1234A1!101
		} else {
			// Query the parent path online
			addLogEntry("Attempting to query Local Database for this parent path: " ~ parentPath, ["debug"]);

			// Attempt a 2 step process to work out where to create the directory
			// Step 1: Query the DB first for the parent path, to try and avoid an API call
			// Step 2: Query online as last resort
			
			// Step 1: Check if this parent path in the database
			Item databaseItem;
			bool parentPathFoundInDB = false;
			
			foreach (driveId; onlineDriveDetails.keys) {
				addLogEntry("Query DB with this driveID for the Parent Path: " ~ driveId, ["debug"]);
				// Query the database for this parent path using each driveId that we know about
				if (itemDB.selectByPath(parentPath, driveId, databaseItem)) {
					parentPathFoundInDB = true;
					addLogEntry("Parent databaseItem: " ~ to!string(databaseItem), ["debug"]);
					addLogEntry("parentPathFoundInDB: " ~ to!string(parentPathFoundInDB), ["debug"]);
					parentItem = databaseItem;
				}
			}
			
			// After querying all DB entries for each driveID for the parent path, what are the details in parentItem?
			addLogEntry("Parent parentItem after DB Query exhausted: " ~ to!string(parentItem), ["debug"]);

			// Step 2: Query for the path online if not found in the local database
			if (!parentPathFoundInDB) {
				// parent path not found in database
				try {
					addLogEntry("Attempting to query OneDrive Online for this parent path as path not found in local database: " ~ parentPath, ["debug"]);
					onlinePathData = createDirectoryOnlineOneDriveApiInstance.getPathDetails(parentPath);
					addLogEntry("Online Parent Path Query Response: " ~ to!string(onlinePathData), ["debug"]);
					
					// Save item to the database
					saveItem(onlinePathData);
					parentItem = makeItem(onlinePathData);
				} catch (OneDriveException exception) {
					if (exception.httpStatusCode == 404) {
						// Parent does not exist ... need to create parent
						addLogEntry("Parent path does not exist online: " ~ parentPath, ["debug"]);
						createDirectoryOnline(parentPath);
						// no return here as we need to continue, but need to re-query the OneDrive API to get the right parental details now that they exist
						onlinePathData = createDirectoryOnlineOneDriveApiInstance.getPathDetails(parentPath);
						parentItem = makeItem(onlinePathData);
					} else {
						string thisFunctionName = getFunctionName!({});
						// Default operation if not 408,429,503,504 errors
						// - 408,429,503,504 errors are handled as a retry within oneDriveApiInstance
						// Display what the error is
						displayOneDriveErrorMessage(exception.msg, thisFunctionName);
					}
				}
			}
		}
		
		// Make sure the full path does not exist online, this should generate a 404 response, to which then the folder will be created online
		try {
			// Try and query the OneDrive API for the path we need to create
			addLogEntry("Attempting to query OneDrive API for this path: " ~ thisNewPathToCreate, ["debug"]);
			addLogEntry("parentItem details: " ~ to!string(parentItem), ["debug"]);
			
			// Depending on the data within parentItem, will depend on what method we are using to search
			// A Shared Folder will be 'remote' so we need to check the remote parent id, rather than parentItem details
			Item queryItem;
			
			if (parentItem.type == ItemType.remote) {
				// This folder is a potential shared object
				addLogEntry("ParentItem is a remote item object", ["debug"]);
				// Need to create the DB Tie for this shared object to ensure this exists in the database
				createDatabaseTieRecordForOnlineSharedFolder(parentItem);
				// Update the queryItem values
				queryItem.driveId = parentItem.remoteDriveId;
				queryItem.id = parentItem.remoteId;
			} else {
				// Use parent item for the query item
				addLogEntry("Standard Query, use parentItem", ["debug"]);
				queryItem = parentItem;
			}
			
			if (queryItem.driveId == appConfig.defaultDriveId) {
				// Use getPathDetailsByDriveId
				addLogEntry("Selecting getPathDetailsByDriveId to query OneDrive API for path data", ["debug"]);
				onlinePathData = createDirectoryOnlineOneDriveApiInstance.getPathDetailsByDriveId(queryItem.driveId, thisNewPathToCreate);
			} else {
				// Use searchDriveForPath to query OneDrive
				addLogEntry("Selecting searchDriveForPath to query OneDrive API for path data", ["debug"]);
				// If the queryItem.driveId is not our driveId - the path we are looking for will not be at the logical location that getPathDetailsByDriveId 
				// can use - as it will always return a 404 .. even if the path actually exists (which is the whole point of this test)
				// Search the queryItem.driveId for any folder name match that we are going to create, then compare response JSON items with queryItem.id
				// If no match, the folder we want to create does not exist at the location we are seeking to create it at, thus generate a 404
				onlinePathData = createDirectoryOnlineOneDriveApiInstance.searchDriveForPath(queryItem.driveId, baseName(thisNewPathToCreate));
				addLogEntry("onlinePathData: " ~to!string(onlinePathData), ["debug"]);
				
				// Process the response from searching the drive
				ulong responseCount = count(onlinePathData["value"].array);
				if (responseCount > 0) {
					// Search 'name' matches were found .. need to match these against queryItem.id
					bool foundDirectoryOnline = false;
					JSONValue foundDirectoryJSONItem;
					// Items were returned .. but is one of these what we are looking for?
					foreach (childJSON; onlinePathData["value"].array) {
						// Is this item not a file?
						if (!isFileItem(childJSON)) {
							Item thisChildItem = makeItem(childJSON);
							// Direct Match Check
							if ((queryItem.id == thisChildItem.parentId) && (baseName(thisNewPathToCreate) == thisChildItem.name)) {
								// High confidence that this child folder is a direct match we are trying to create and it already exists online
								addLogEntry("Path we are searching for exists online (Direct Match): " ~ baseName(thisNewPathToCreate), ["debug"]);
								addLogEntry("childJSON: " ~ to!string(childJSON), ["debug"]);
								foundDirectoryOnline = true;
								foundDirectoryJSONItem = childJSON;
								break;
							}
							
							// Full Lower Case POSIX Match Check
							string childAsLower = toLower(childJSON["name"].str);
							string thisFolderNameAsLower = toLower(baseName(thisNewPathToCreate));
							
							// Child name check
							if (childAsLower == thisFolderNameAsLower) {	
								// This is a POSIX 'case in-sensitive match' ..... in folder name only
								// - Local item name has a 'case-insensitive match' to an existing item on OneDrive
								// The 'parentId' of this JSON object must match the the parentId of where the folder was created
								// - why .. we might have the same folder name, but somewhere totally different
								
								if (queryItem.id == thisChildItem.parentId) {
									// Found the directory in the location, using case in-sensitive matching
									addLogEntry("Path we are searching for exists online (POSIX 'case in-sensitive match'): " ~ baseName(thisNewPathToCreate), ["debug"]);
									addLogEntry("childJSON: " ~ to!string(childJSON), ["debug"]);
									foundDirectoryOnline = true;
									foundDirectoryJSONItem = childJSON;
									break;
								}
							}
						}
					}
					
					if (foundDirectoryOnline) {
						// Directory we are seeking was found online ...
						addLogEntry("The directory we are seeking was found online by using searchDriveForPath ...", ["debug"]);
						onlinePathData = foundDirectoryJSONItem;
					} else {
						// No 'search item matches found' - raise a 404 so that the exception handling will take over to create the folder
						throw new OneDriveException(404, "Name not found via search");
					}
				} else {
					// No 'search item matches found' - raise a 404 so that the exception handling will take over to create the folder
					throw new OneDriveException(404, "Name not found via search");
				}
			}
		} catch (OneDriveException exception) {
			if (exception.httpStatusCode == 404) {
				// This is a good error - it means that the directory to create 100% does not exist online
				// The directory was not found on the drive id we queried
				addLogEntry("The requested directory to create was not found on OneDrive - creating remote directory: " ~ thisNewPathToCreate, ["verbose"]);
				
				// Build up the online create directory request
				JSONValue createDirectoryOnlineAPIResponse;
				JSONValue newDriveItem = [
						"name": JSONValue(baseName(thisNewPathToCreate)),
						"folder": parseJSON("{}")
				];
				
				// Submit the creation request
				// Fix for https://github.com/skilion/onedrive/issues/356
				if (!dryRun) {
					try {
						// Attempt to create a new folder on the required driveId and parent item id
						string requiredDriveId;
						string requiredParentItemId;
						
						// Is the item a Remote Object (Shared Folder) ?
						if (parentItem.type == ItemType.remote) {
							// Yes .. Shared Folder
							addLogEntry("parentItem data: " ~ to!string(parentItem), ["debug"]);
							requiredDriveId = parentItem.remoteDriveId;
							requiredParentItemId = parentItem.remoteId;
						} else {
							// Not a Shared Folder
							requiredDriveId = parentItem.driveId;
							requiredParentItemId = parentItem.id;
						}
						
						// Where are we creating this new folder?
						addLogEntry("requiredDriveId:      " ~ requiredDriveId, ["debug"]);
						addLogEntry("requiredParentItemId: " ~ requiredParentItemId, ["debug"]);
						addLogEntry("newDriveItem JSON:    " ~ to!string(newDriveItem), ["debug"]);
					
						// Create the new folder
						createDirectoryOnlineAPIResponse = createDirectoryOnlineOneDriveApiInstance.createById(requiredDriveId, requiredParentItemId, newDriveItem);
						// Is the response a valid JSON object - validation checking done in saveItem
						saveItem(createDirectoryOnlineAPIResponse);
						// Log that the directory was created
						addLogEntry("Successfully created the remote directory " ~ thisNewPathToCreate ~ " on Microsoft OneDrive");
					} catch (OneDriveException exception) {
						if (exception.httpStatusCode == 409) {
							// OneDrive API returned a 404 (above) to say the directory did not exist
							// but when we attempted to create it, OneDrive responded that it now already exists
							addLogEntry("OneDrive reported that " ~ thisNewPathToCreate ~ " already exists .. OneDrive API race condition", ["verbose"]);
							// Shutdown this API instance, as we will create API instances as required, when required
							createDirectoryOnlineOneDriveApiInstance.releaseCurlEngine();
							// Free object and memory
							createDirectoryOnlineOneDriveApiInstance = null;
							// Perform Garbage Collection
							GC.collect();
							return;
						} else {
							// some other error from OneDrive was returned - display what it is
							addLogEntry("OneDrive generated an error when creating this path: " ~ thisNewPathToCreate);
							displayOneDriveErrorMessage(exception.msg, getFunctionName!({}));
							// Shutdown this API instance, as we will create API instances as required, when required
							createDirectoryOnlineOneDriveApiInstance.releaseCurlEngine();
							// Free object and memory
							createDirectoryOnlineOneDriveApiInstance = null;
							// Perform Garbage Collection
							GC.collect();
							return;
						}
					}
				} else {
					// Simulate a successful 'directory create' & save it to the dryRun database copy
					addLogEntry("Successfully created the remote directory " ~ thisNewPathToCreate ~ " on Microsoft OneDrive");
					// The simulated response has to pass 'makeItem' as part of saveItem
					auto fakeResponse = createFakeResponse(thisNewPathToCreate);
					// Save item to the database
					saveItem(fakeResponse);
				}
				
				// Shutdown this API instance, as we will create API instances as required, when required
				createDirectoryOnlineOneDriveApiInstance.releaseCurlEngine();
				// Free object and memory
				createDirectoryOnlineOneDriveApiInstance = null;
				// Perform Garbage Collection
				GC.collect();
				return;
				
			} else {
				// Default operation if not 408,429,503,504 errors
				// - 408,429,503,504 errors are handled as a retry within createDirectoryOnlineOneDriveApiInstance
				
				// If we get a 400 error, there is an issue creating this folder on Microsoft OneDrive for some reason
				// If the error is not 400, re-try, else fail
				if (exception.httpStatusCode != 400) {
					// Attempt a re-try
					createDirectoryOnline(thisNewPathToCreate);
				} else {
					// We cant create this directory online
					addLogEntry("This folder cannot be created online: " ~ buildNormalizedPath(absolutePath(thisNewPathToCreate)), ["debug"]);
				}	
			}
		}
		
		// If we get to this point - onlinePathData = createDirectoryOnlineOneDriveApiInstance.getPathDetailsByDriveId(parentItem.driveId, thisNewPathToCreate) generated a 'valid' response ....
		// This means that the folder potentially exists online .. which is odd .. as it should not have existed
		if (onlinePathData.type() == JSONType.object) {
			// A valid object was responded with
			if (onlinePathData["name"].str == baseName(thisNewPathToCreate)) {
				// OneDrive 'name' matches local path name
				if (appConfig.accountType == "business") {
					// We are a business account, this existing online folder, could be a Shared Online Folder could be a 'Add shortcut to My files' item
					addLogEntry("onlinePathData: " ~ to!string(onlinePathData), ["debug"]);
					
					// Is this a remote folder
					if (isItemRemote(onlinePathData)) {
						// The folder is a remote item ... we do not want to create this ...
						addLogEntry("Existing Remote Online Folder is most likely a OneDrive Shared Business Folder Link added by 'Add shortcut to My files'", ["debug"]);
						
						// Is Shared Business Folder Syncing enabled ?
						if (!appConfig.getValueBool("sync_business_shared_items")) {
							// Shared Business Folder Syncing is NOT enabled
							addLogEntry("We need to skip this path: " ~ thisNewPathToCreate, ["debug"]);
							// Add this path to businessSharedFoldersOnlineToSkip
							businessSharedFoldersOnlineToSkip ~= [thisNewPathToCreate];
							// no save to database, no online create
							
							// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
							createDirectoryOnlineOneDriveApiInstance.releaseCurlEngine();
							createDirectoryOnlineOneDriveApiInstance = null;
							// Perform Garbage Collection
							GC.collect();
							
							return;
						} else {
							// As the 'onlinePathData' is potentially missing the actual correct parent folder id in the 'remoteItem' JSON response, we have to perform a further query to get the correct answer
							// Failure to do this, means the 'root' DB Tie Record has a different parent reference id to that what this folder's parent reference id actually is
							JSONValue sharedFolderParentPathData;
							string remoteDriveId = onlinePathData["remoteItem"]["parentReference"]["driveId"].str;
							string remoteItemId = onlinePathData["remoteItem"]["id"].str;
							sharedFolderParentPathData = createDirectoryOnlineOneDriveApiInstance.getPathDetailsById(remoteDriveId, remoteItemId);
							
							// A 'root' DB Tie Record needed for this folder using the correct parent data
							createDatabaseRootTieRecordForOnlineSharedFolder(sharedFolderParentPathData);
						}
					}
				}
				
				// Path found online
				addLogEntry("The requested directory to create was found on OneDrive - skipping creating the directory: " ~ thisNewPathToCreate, ["verbose"]);
				
				// Is the response a valid JSON object - validation checking done in saveItem
				saveItem(onlinePathData);
				
				// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
				createDirectoryOnlineOneDriveApiInstance.releaseCurlEngine();
				createDirectoryOnlineOneDriveApiInstance = null;
				// Perform Garbage Collection
				GC.collect();
				return;
			} else {
				// Normally this would throw an error, however we cant use throw new PosixException()
				string msg = format("POSIX 'case-insensitive match' between '%s' (local) and '%s' (online) which violates the Microsoft OneDrive API namespace convention", baseName(thisNewPathToCreate), onlinePathData["name"].str);
				displayPosixErrorMessage(msg);
				addLogEntry("ERROR: Requested directory to create has a 'case-insensitive match' to an existing directory on OneDrive online.");
				addLogEntry("ERROR: To resolve, rename this local directory: " ~ buildNormalizedPath(absolutePath(thisNewPathToCreate)));
				addLogEntry("Skipping creating this directory online due to 'case-insensitive match': " ~ thisNewPathToCreate);
				// Add this path to posixViolationPaths
				posixViolationPaths ~= [thisNewPathToCreate];
				
				// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
				createDirectoryOnlineOneDriveApiInstance.releaseCurlEngine();
				createDirectoryOnlineOneDriveApiInstance = null;
				// Perform Garbage Collection
				GC.collect();
				return;
			}
		} else {
			// response is not valid JSON, an error was returned from OneDrive
			addLogEntry("ERROR: There was an error performing this operation on Microsoft OneDrive");
			addLogEntry("ERROR: Increase logging verbosity to assist determining why.");
			addLogEntry("Skipping: " ~ buildNormalizedPath(absolutePath(thisNewPathToCreate)));
			// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
			createDirectoryOnlineOneDriveApiInstance.releaseCurlEngine();
			createDirectoryOnlineOneDriveApiInstance = null;
			// Perform Garbage Collection
			GC.collect();
			return;
		}
	}
	
	// Test that the online name actually matches the requested local name
	void performPosixTest(string localNameToCheck, string onlineName) {
			
		// https://docs.microsoft.com/en-us/windows/desktop/FileIO/naming-a-file
		// Do not assume case sensitivity. For example, consider the names OSCAR, Oscar, and oscar to be the same, 
		// even though some file systems (such as a POSIX-compliant file system) may consider them as different. 
		// Note that NTFS supports POSIX semantics for case sensitivity but this is not the default behavior.
		if (localNameToCheck != onlineName) {
			// POSIX Error
			// Local item name has a 'case-insensitive match' to an existing item on OneDrive
			throw new PosixException(localNameToCheck, onlineName);
		}
	}
	
	// Upload new file items as identified
	void uploadNewLocalFileItems() {
		// Lets deal with the new local items in a batch process
		size_t batchSize = to!int(appConfig.getValueLong("threads"));
		ulong batchCount = (newLocalFilesToUploadToOneDrive.length + batchSize - 1) / batchSize;
		ulong batchesProcessed = 0;
		
		foreach (chunk; newLocalFilesToUploadToOneDrive.chunks(batchSize)) {
			uploadNewLocalFileItemsInParallel(chunk);
		}
	}
	
	// Upload the file batches in parallel
	void uploadNewLocalFileItemsInParallel(string[] array) {
		// This function received an array of string items to upload, the number of elements based on appConfig.getValueLong("threads")
		foreach (i, fileToUpload; processPool.parallel(array)) {
			addLogEntry("Upload Thread " ~ to!string(i) ~ " Starting: " ~ to!string(Clock.currTime()), ["debug"]);
			uploadNewFile(fileToUpload);
			addLogEntry("Upload Thread " ~ to!string(i) ~ " Finished: " ~ to!string(Clock.currTime()), ["debug"]);
		}
	}
	
	// Upload a new file to OneDrive
	void uploadNewFile(string fileToUpload) {
		// Debug for the moment
		addLogEntry("fileToUpload: " ~ fileToUpload, ["debug"]);
		
		// These are the details of the item we need to upload
		// How much space is remaining on OneDrive
		ulong remainingFreeSpaceOnline;
		// Did the upload fail?
		bool uploadFailed = false;
		// Did we skip due to exceeding maximum allowed size?
		bool skippedMaxSize = false;
		// Did we skip to an exception error?
		bool skippedExceptionError = false;
		// Is the parent path in the item database?
		bool parentPathFoundInDB = false;
		// Get this file size
		ulong thisFileSize;
		// Is there space available online
		bool spaceAvailableOnline = false;
		
		DriveDetailsCache cachedOnlineDriveData;
		ulong calculatedSpaceOnlinePostUpload;
		
		OneDriveApi checkFileOneDriveApiInstance;
		
		// Check the database for the parent path of fileToUpload
		Item parentItem;
		// What parent path to use?
		string parentPath = dirName(fileToUpload); // will be either . or something else
		if (parentPath == "."){
			// Assume this is a new file in the users configured sync_dir root
			// Use client defaults
			parentItem.id = appConfig.defaultRootId;  		// Should give something like 12345ABCDE1234A1!101
			parentItem.driveId = appConfig.defaultDriveId; 	// Should give something like 12345abcde1234a1
			parentPathFoundInDB = true;
		} else {
			// Query the database using each of the driveId's we are using
			foreach (driveId; onlineDriveDetails.keys) {
				// Query the database for this parent path using each driveId
				Item dbResponse;
				if(itemDB.selectByPath(parentPath, driveId, dbResponse)){
					// parent path was found in the database
					parentItem = dbResponse;
					parentPathFoundInDB = true;
				}
			}
		}
		
		// If the parent path was found in the DB, to ensure we are uploading the the right location 'parentItem.driveId' must not be empty
		if ((parentPathFoundInDB) && (parentItem.driveId.empty)) {
			// switch to using defaultDriveId
			addLogEntry("parentItem.driveId is empty - using defaultDriveId for upload API calls", ["debug"]);
			parentItem.driveId = appConfig.defaultDriveId;
		}
		
		// Check if the path still exists locally before we try to upload
		if (exists(fileToUpload)) {
			// Can we read the file - as a permissions issue or actual file corruption will cause a failure
			// Resolves: https://github.com/abraunegg/onedrive/issues/113
			if (readLocalFile(fileToUpload)) {
				// The local file can be read - so we can read it to attempt to upload it in this thread
				// Is the path parent in the DB?
				if (parentPathFoundInDB) {
					// Parent path is in the database
					// Get the new file size
					// Even if the permissions on the file are: -rw-------.  1 root root    8 Jan 11 09:42
					// we can still obtain the file size, however readLocalFile() also tests if the file can be read (permission check)
					thisFileSize = getSize(fileToUpload);
					
					// Does this file exceed the maximum filesize for OneDrive
					// Resolves: https://github.com/skilion/onedrive/issues/121 , https://github.com/skilion/onedrive/issues/294 , https://github.com/skilion/onedrive/issues/329
					if (thisFileSize <= maxUploadFileSize) {
						// Is there enough free space on OneDrive as compared to when we started this thread, to safely upload the file to OneDrive?
						
						// Make sure that parentItem.driveId is in our driveIDs array to use when checking if item is in database
						// Keep the DriveDetailsCache array with unique entries only
						if (!canFindDriveId(parentItem.driveId, cachedOnlineDriveData)) {
							// Add this driveId to the drive cache, which then also sets for the defaultDriveId:
							// - quotaRestricted;
							// - quotaAvailable;
							// - quotaRemaining;
							addOrUpdateOneDriveOnlineDetails(parentItem.driveId);
							// Fetch the details from cachedOnlineDriveData
							cachedOnlineDriveData = getDriveDetails(parentItem.driveId);
						} 
						
						// Fetch the details from cachedOnlineDriveData
						// - cachedOnlineDriveData.quotaRestricted;
						// - cachedOnlineDriveData.quotaAvailable;
						// - cachedOnlineDriveData.quotaRemaining;
						remainingFreeSpaceOnline = cachedOnlineDriveData.quotaRemaining;
						
						// When we compare the space online to the total we are trying to upload - is there space online?
						calculatedSpaceOnlinePostUpload = remainingFreeSpaceOnline - thisFileSize;
						
						// Based on what we know, for this thread - can we safely upload this modified local file?
						addLogEntry("This Thread Estimated Free Space Online:              " ~ to!string(remainingFreeSpaceOnline), ["debug"]);
						addLogEntry("This Thread Calculated Free Space Online Post Upload: " ~ to!string(calculatedSpaceOnlinePostUpload), ["debug"]);
			
						// If 'personal' accounts, if driveId == defaultDriveId, then we will have data - appConfig.quotaAvailable will be updated
						// If 'personal' accounts, if driveId != defaultDriveId, then we will not have quota data - appConfig.quotaRestricted will be set as true
						// If 'business' accounts, if driveId == defaultDriveId, then we will have data
						// If 'business' accounts, if driveId != defaultDriveId, then we will have data, but it will be a 0 value - appConfig.quotaRestricted will be set as true
						
						if (remainingFreeSpaceOnline > totalDataToUpload) {
							// Space available
							spaceAvailableOnline = true;
						} else {
							// we need to look more granular
							// What was the latest getRemainingFreeSpace() value?
							if (cachedOnlineDriveData.quotaAvailable) {
								// Our query told us we have free space online .. if we upload this file, will we exceed space online - thus upload will fail during upload?
								if (calculatedSpaceOnlinePostUpload > 0) {
									// Based on this thread action, we believe that there is space available online to upload - proceed
									spaceAvailableOnline = true;
								}
							}
						}
						
						// Is quota being restricted?
						if (cachedOnlineDriveData.quotaRestricted) {
							// If the upload target drive is not our drive id, then it is a shared folder .. we need to print a space warning message
							if (parentItem.driveId != appConfig.defaultDriveId) {
								// Different message depending on account type
								if (appConfig.accountType == "personal") {
									addLogEntry("WARNING: Shared Folder OneDrive quota information is being restricted or providing a zero value. Space available online cannot be guaranteed.", ["verbose"]);
								} else {
									addLogEntry("WARNING: Shared Folder OneDrive quota information is being restricted or providing a zero value. Please fix by speaking to your OneDrive / Office 365 Administrator.", ["verbose"]);
								}
							} else {
								if (appConfig.accountType == "personal") {
									addLogEntry("WARNING: OneDrive quota information is being restricted or providing a zero value. Space available online cannot be guaranteed.", ["verbose"]);
								} else {
									addLogEntry("WARNING: OneDrive quota information is being restricted or providing a zero value. Please fix by speaking to your OneDrive / Office 365 Administrator.", ["verbose"]);
								}
							}
							// Space available online is being restricted - so we have no way to really know if there is space available online
							spaceAvailableOnline = true;
						}
						
						// Do we have space available or is space available being restricted (so we make the blind assumption that there is space available)
						if (spaceAvailableOnline) {
							// We need to check that this new local file does not exist on OneDrive
							JSONValue fileDetailsFromOneDrive;

							// https://docs.microsoft.com/en-us/windows/desktop/FileIO/naming-a-file
							// Do not assume case sensitivity. For example, consider the names OSCAR, Oscar, and oscar to be the same, 
							// even though some file systems (such as a POSIX-compliant file systems that Linux use) may consider them as different.
							// Note that NTFS supports POSIX semantics for case sensitivity but this is not the default behavior, OneDrive does not use this.
							
							// In order to upload this file - this query HAS to respond with a '404 - Not Found' so that the upload is triggered
							
							// Does this 'file' already exist on OneDrive?
							try {
							
								// Create a new API Instance for this thread and initialise it
								checkFileOneDriveApiInstance = new OneDriveApi(appConfig);
								checkFileOneDriveApiInstance.initialise();

								if (parentItem.driveId == appConfig.defaultDriveId) {
									// getPathDetailsByDriveId is only reliable when the driveId is our driveId
									fileDetailsFromOneDrive = checkFileOneDriveApiInstance.getPathDetailsByDriveId(parentItem.driveId, fileToUpload);
								} else {
									// We need to curate a response by listing the children of this parentItem.driveId and parentItem.id , without traversing directories
									// So that IF the file is on a Shared Folder, it can be found, and, if it exists, checked correctly
									fileDetailsFromOneDrive = searchDriveItemForFile(parentItem.driveId, parentItem.id, fileToUpload);
									// Was the file found?
									if (fileDetailsFromOneDrive.type() != JSONType.object) {
										// No ....
										throw new OneDriveException(404, "Name not found via searchDriveItemForFile");
									}
								}
								
								// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
								checkFileOneDriveApiInstance.releaseCurlEngine();
								checkFileOneDriveApiInstance = null;
								// Perform Garbage Collection
								GC.collect();
								
								// Portable Operating System Interface (POSIX) testing of JSON response from OneDrive API
								if (hasName(fileDetailsFromOneDrive)) {
									performPosixTest(baseName(fileToUpload), fileDetailsFromOneDrive["name"].str);
								} else {
									throw new JsonResponseException("Unable to perform POSIX test as the OneDrive API request generated an invalid JSON response");
								}
								
								// If we get to this point, the OneDrive API returned a 200 OK with valid JSON data that indicates a 'file' exists at this location already
								// and that it matches the POSIX filename of the local item we are trying to upload as a new file
								addLogEntry("The file we are attempting to upload as a new file already exists on Microsoft OneDrive: " ~ fileToUpload, ["verbose"]);
								
								// No 404 or otherwise was triggered, meaning that the file already exists online and passes the POSIX test ...
								addLogEntry("fileDetailsFromOneDrive after exist online check: " ~ to!string(fileDetailsFromOneDrive), ["debug"]);
								
								// Does the data from online match our local file that we are attempting to upload as a new file?
								if (!disableUploadValidation && performUploadIntegrityValidationChecks(fileDetailsFromOneDrive, fileToUpload, thisFileSize)) {
									// Save online item details to the database
									saveItem(fileDetailsFromOneDrive);
								} else {
									// The local file we are attempting to upload as a new file is different to the existing file online
									addLogEntry("Triggering newfile upload target already exists edge case, where the online item does not match what we are trying to upload", ["debug"]);
									
									// Issue #2626 | Case 2-2 (resync)
									
									// If the 'online' file is newer, this will be overwritten with the file from the local filesystem - potentially constituting online data loss
									// The file 'version history' online will have to be used to 'recover' the prior online file
									string changedItemParentDriveId = fileDetailsFromOneDrive["parentReference"]["driveId"].str;
									string changedItemId = fileDetailsFromOneDrive["id"].str;
									addLogEntry("Skipping uploading this item as a new file, will upload as a modified file (online file already exists): " ~ fileToUpload);
									
									// In order for the processing of the local item as a 'changed' item, unfortunately we need to save the online data of the existing online file to the local DB
									saveItem(fileDetailsFromOneDrive);
									
									// Which file is technically newer? The local file or the remote file?
									Item onlineFile = makeItem(fileDetailsFromOneDrive);
									SysTime localModifiedTime = timeLastModified(fileToUpload).toUTC();
									SysTime onlineModifiedTime = onlineFile.mtime;
									
									// Reduce time resolution to seconds before comparing
									localModifiedTime.fracSecs = Duration.zero;
									onlineModifiedTime.fracSecs = Duration.zero;
									
									// Which file is newer?
									if (localModifiedTime >= onlineModifiedTime) {
										// Upload the locally modified file as-is, as it is newer
										uploadChangedLocalFileToOneDrive([changedItemParentDriveId, changedItemId, fileToUpload]);
									} else {
										// Online is newer, rename local, then upload the renamed file
										// We need to know the renamed path so we can upload it
										string renamedPath;
										// Rename the local path
										safeBackup(fileToUpload, dryRun, renamedPath);
										// Upload renamed local file as a new file
										uploadNewFile(renamedPath);
										// Process the database entry removal for the original file. In a --dry-run scenario, this is being done against a DB copy.
										// This is done so we can download the newer online file
										itemDB.deleteById(changedItemParentDriveId, changedItemId);
									}
								}
							} catch (OneDriveException exception) {
								// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
								checkFileOneDriveApiInstance.releaseCurlEngine();
								checkFileOneDriveApiInstance = null;
								// Perform Garbage Collection
								GC.collect();
								
								// If we get a 404 .. the file is not online .. this is what we want .. file does not exist online
								if (exception.httpStatusCode == 404) {
									// The file has been checked, client side filtering checked, does not exist online - we need to upload it
									addLogEntry("fileDetailsFromOneDrive = checkFileOneDriveApiInstance.getPathDetailsByDriveId(parentItem.driveId, fileToUpload); generated a 404 - file does not exist online - must upload it", ["debug"]);
									uploadFailed = performNewFileUpload(parentItem, fileToUpload, thisFileSize);
								} else {
									// some other error
									string thisFunctionName = getFunctionName!({});
									// Default operation if not 408,429,503,504 errors
									// - 408,429,503,504 errors are handled as a retry within oneDriveApiInstance
									// Display what the error is
									displayOneDriveErrorMessage(exception.msg, thisFunctionName);
								}
							} catch (PosixException e) {
								// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
								checkFileOneDriveApiInstance.releaseCurlEngine();
								checkFileOneDriveApiInstance = null;
								// Perform Garbage Collection
								GC.collect();
								
								// Display POSIX error message
								displayPosixErrorMessage(e.msg);
								uploadFailed = true;
							} catch (JsonResponseException e) {
								// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
								checkFileOneDriveApiInstance.releaseCurlEngine();
								checkFileOneDriveApiInstance = null;
								// Perform Garbage Collection
								GC.collect();
								
								// Display JSON error message
								addLogEntry(e.msg, ["debug"]);
								uploadFailed = true;
							}
						} else {
							// skip file upload - insufficient space to upload
							addLogEntry("Skipping uploading this new file as it exceeds the available free space on Microsoft OneDrive: " ~ fileToUpload);
							uploadFailed = true;
						}
					} else {
						// Skip file upload - too large
						addLogEntry("Skipping uploading this new file as it exceeds the maximum size allowed by Microsoft OneDrive: " ~ fileToUpload);
						uploadFailed = true;
					}
				} else {
					// why was the parent path not in the database?
					if (canFind(posixViolationPaths, parentPath)) {
						addLogEntry("ERROR: POSIX 'case-insensitive match' for the parent path which violates the Microsoft OneDrive API namespace convention.");
					} else {
						addLogEntry("ERROR: Parent path is not in the database or online.");
					}
					addLogEntry("ERROR: Unable to upload this file: " ~ fileToUpload);
					uploadFailed = true;
				}
			} else {
				// Unable to read local file
				addLogEntry("Skipping uploading this file as it cannot be read (file permissions or file corruption): " ~ fileToUpload);
				uploadFailed = true;
			}
		} else {
			// File disappeared before upload
			addLogEntry("File disappeared locally before upload: " ~ fileToUpload);
			// dont set uploadFailed = true; as the file disappeared before upload, thus nothing here failed
		}

		// Upload success or failure?
		if (!uploadFailed) {
			// Update the 'cachedOnlineDriveData' record for this 'dbItem.driveId' so that this is tracked as accurately as possible for other threads
			updateDriveDetailsCache(parentItem.driveId, cachedOnlineDriveData.quotaRestricted, cachedOnlineDriveData.quotaAvailable, thisFileSize);
			
		} else {
			// Need to add this to fileUploadFailures to capture at the end
			fileUploadFailures ~= fileToUpload;
		}
	}
	
	// Perform the actual upload to OneDrive
	bool performNewFileUpload(Item parentItem, string fileToUpload, ulong thisFileSize) {
			
		// Assume that by default the upload fails
		bool uploadFailed = true;
		
		// OneDrive API Upload Response
		JSONValue uploadResponse;
		
		// Create the OneDriveAPI Upload Instance
		OneDriveApi uploadFileOneDriveApiInstance;
		
		// Calculate upload speed
		auto uploadStartTime = Clock.currTime();
		
		// Is this a dry-run scenario?
		if (!dryRun) {
			// Not a dry-run situation
			// Do we use simpleUpload or create an upload session?
			bool useSimpleUpload = false;
			if (thisFileSize <= sessionThresholdFileSize) {
				useSimpleUpload = true;
			}
			
			// We can only upload zero size files via simpleFileUpload regardless of account type
			// Reference: https://github.com/OneDrive/onedrive-api-docs/issues/53
			// Additionally, only where file size is < 4MB should be uploaded by simpleUpload - everything else should use a session to upload
			
			if ((thisFileSize == 0) || (useSimpleUpload)) { 
				try {
					// Initialise API for simple upload
					uploadFileOneDriveApiInstance = new OneDriveApi(appConfig);
					uploadFileOneDriveApiInstance.initialise();
				
					// Attempt to upload the zero byte file using simpleUpload for all account types
					uploadResponse = uploadFileOneDriveApiInstance.simpleUpload(fileToUpload, parentItem.driveId, parentItem.id, baseName(fileToUpload));
					uploadFailed = false;
					addLogEntry("Uploading new file: " ~ fileToUpload ~ " ... done.");
					
					// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
					uploadFileOneDriveApiInstance.releaseCurlEngine();
					uploadFileOneDriveApiInstance = null;
					// Perform Garbage Collection
					GC.collect();
					
				} catch (OneDriveException exception) {
					// An error was responded with - what was it
					
					string thisFunctionName = getFunctionName!({});
					// Default operation if not 408,429,503,504 errors
					// - 408,429,503,504 errors are handled as a retry within oneDriveApiInstance
					// Display what the error is
					addLogEntry("Uploading new file: " ~ fileToUpload ~ " ... failed.");
					displayOneDriveErrorMessage(exception.msg, thisFunctionName);
					
					// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
					uploadFileOneDriveApiInstance.releaseCurlEngine();
					uploadFileOneDriveApiInstance = null;
					// Perform Garbage Collection
					GC.collect();
					
				} catch (FileException e) {
					// display the error message
					addLogEntry("Uploading new file: " ~ fileToUpload ~ " ... failed.");
					displayFileSystemErrorMessage(e.msg, getFunctionName!({}));
					
					// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
					uploadFileOneDriveApiInstance.releaseCurlEngine();
					uploadFileOneDriveApiInstance = null;
					// Perform Garbage Collection
					GC.collect();
				}
			} else {
				// Initialise API for session upload
				uploadFileOneDriveApiInstance = new OneDriveApi(appConfig);
				uploadFileOneDriveApiInstance.initialise();
				
				// Session Upload for this criteria:
				// - Personal Account and file size > 4MB
				// - All Business | Office365 | SharePoint files > 0 bytes
				JSONValue uploadSessionData;
				// As this is a unique thread, the sessionFilePath for where we save the data needs to be unique
				// The best way to do this is generate a 10 digit alphanumeric string, and use this as the file extension
				string threadUploadSessionFilePath = appConfig.uploadSessionFilePath ~ "." ~ generateAlphanumericString();
				
				// Attempt to upload the > 4MB file using an upload session for all account types
				try {
					// Create the Upload Session
					uploadSessionData = createSessionFileUpload(uploadFileOneDriveApiInstance, fileToUpload, parentItem.driveId, parentItem.id, baseName(fileToUpload), null, threadUploadSessionFilePath);
				} catch (OneDriveException exception) {
					// An error was responded with - what was it
					
					string thisFunctionName = getFunctionName!({});
					// Default operation if not 408,429,503,504 errors
					// - 408,429,503,504 errors are handled as a retry within oneDriveApiInstance
					// Display what the error is
					addLogEntry("Uploading new file: " ~ fileToUpload ~ " ... failed.");
					displayOneDriveErrorMessage(exception.msg, thisFunctionName);
										
				} catch (FileException e) {
					// display the error message
					addLogEntry("Uploading new file: " ~ fileToUpload ~ " ... failed.");
					displayFileSystemErrorMessage(e.msg, getFunctionName!({}));
				}
				
				// Do we have a valid session URL that we can use ?
				if (uploadSessionData.type() == JSONType.object) {
					// This is a valid JSON object
					bool sessionDataValid = true;
					
					// Validate that we have the following items which we need
					if (!hasUploadURL(uploadSessionData)) {
						sessionDataValid = false;
						addLogEntry("Session data missing 'uploadUrl'", ["debug"]);
					}
					
					if (!hasNextExpectedRanges(uploadSessionData)) {
						sessionDataValid = false;
						addLogEntry("Session data missing 'nextExpectedRanges'", ["debug"]);
					}
					
					if (!hasLocalPath(uploadSessionData)) {
						sessionDataValid = false;
						addLogEntry("Session data missing 'localPath'", ["debug"]);
					}
								
					if (sessionDataValid) {
						// We have a valid Upload Session Data we can use
						try {
							// Try and perform the upload session
							uploadResponse = performSessionFileUpload(uploadFileOneDriveApiInstance, thisFileSize, uploadSessionData, threadUploadSessionFilePath);
							
							if (uploadResponse.type() == JSONType.object) {
								uploadFailed = false;
								addLogEntry("Uploading new file: " ~ fileToUpload ~ " ... done.");
							} else {
								addLogEntry("Uploading new file: " ~ fileToUpload ~ " ... failed.");
								uploadFailed = true;
							}
						} catch (OneDriveException exception) {
						
							string thisFunctionName = getFunctionName!({});
							// Default operation if not 408,429,503,504 errors
							// - 408,429,503,504 errors are handled as a retry within oneDriveApiInstance
							// Display what the error is
							addLogEntry("Uploading new file: " ~ fileToUpload ~ " ... failed.");
							displayOneDriveErrorMessage(exception.msg, thisFunctionName);
							
						}
					} else {
						// No Upload URL or nextExpectedRanges or localPath .. not a valid JSON we can use
						addLogEntry("Session data is missing required elements to perform a session upload.", ["verbose"]);
						addLogEntry("Uploading new file: " ~ fileToUpload ~ " ... failed.");
					}
				} else {
					// Create session Upload URL failed
					addLogEntry("Uploading new file: " ~ fileToUpload ~ " ... failed.");
				}
				
				// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
				uploadFileOneDriveApiInstance.releaseCurlEngine();
				uploadFileOneDriveApiInstance = null;
				// Perform Garbage Collection
				GC.collect();
			}
		} else {
			// We are in a --dry-run scenario
			uploadResponse = createFakeResponse(fileToUpload);
			uploadFailed = false;
			addLogEntry("Uploading new file: " ~ fileToUpload ~ " ... done.", ["info", "notify"]);
		}
		
		// Upload has finished
		auto uploadFinishTime = Clock.currTime();
		// If no upload failure, calculate metrics, perform integrity validation
		if (!uploadFailed) {
			// Upload did not fail ...
			auto uploadDuration = uploadFinishTime - uploadStartTime;
			addLogEntry("File Size: " ~ to!string(thisFileSize) ~ " Bytes", ["debug"]);
			addLogEntry("Upload Duration: " ~ to!string((uploadDuration.total!"msecs"/1e3)) ~ " Seconds", ["debug"]);
			auto uploadSpeed = (thisFileSize / (uploadDuration.total!"msecs"/1e3)/ 1024 / 1024);
			addLogEntry("Upload Speed: " ~ to!string(uploadSpeed) ~ " Mbps (approx)", ["debug"]);
			
			// OK as the upload did not fail, we need to save the response from OneDrive, but it has to be a valid JSON response
			if (uploadResponse.type() == JSONType.object) {
				// check if the path still exists locally before we try to set the file times online - as short lived files, whilst we uploaded it - it may not exist locally already
				if (exists(fileToUpload)) {
					if (!dryRun) {
						// Check the integrity of the uploaded file, if the local file still exists
						performUploadIntegrityValidationChecks(uploadResponse, fileToUpload, thisFileSize);
						
						// Update the file modified time on OneDrive and save item details to database
						// Update the item's metadata on OneDrive
						SysTime mtime = timeLastModified(fileToUpload).toUTC();
						mtime.fracSecs = Duration.zero;
						string newFileId = uploadResponse["id"].str;
						string newFileETag = uploadResponse["eTag"].str;
						// Attempt to update the online date time stamp based on our local data
						uploadLastModifiedTime(parentItem, parentItem.driveId, newFileId, mtime, newFileETag);
					}
				} else {
					// will be removed in different event!
					addLogEntry("File disappeared locally after upload: " ~ fileToUpload);
				}
			} else {
				// Log that an invalid JSON object was returned
				addLogEntry("uploadFileOneDriveApiInstance.simpleUpload or session.upload call returned an invalid JSON Object from the OneDrive API", ["debug"]);
			}
		}
		
		// Return upload status
		return uploadFailed;
	}
	
	// Create the OneDrive Upload Session
	JSONValue createSessionFileUpload(OneDriveApi activeOneDriveApiInstance, string fileToUpload, string parentDriveId, string parentId, string filename, string eTag, string threadUploadSessionFilePath) {
		
		// Upload file via a OneDrive API session
		JSONValue uploadSession;
		
		// Calculate modification time
		SysTime localFileLastModifiedTime = timeLastModified(fileToUpload).toUTC();
		localFileLastModifiedTime.fracSecs = Duration.zero;
		
		// Construct the fileSystemInfo JSON component needed to create the Upload Session
		JSONValue fileSystemInfo = [
				"item": JSONValue([
					"@microsoft.graph.conflictBehavior": JSONValue("replace"),
					"fileSystemInfo": JSONValue([
						"lastModifiedDateTime": localFileLastModifiedTime.toISOExtString()
					])
				])
			];
		
		// Try to create the upload session for this file
		uploadSession = activeOneDriveApiInstance.createUploadSession(parentDriveId, parentId, filename, eTag, fileSystemInfo);
		
		if (uploadSession.type() == JSONType.object) {
			// a valid session object was created
			if ("uploadUrl" in uploadSession) {
				// Add the file path we are uploading to this JSON Session Data
				uploadSession["localPath"] = fileToUpload;
				// Save this session
				saveSessionFile(threadUploadSessionFilePath, uploadSession);
			}
		} else {
			// no valid session was created
			addLogEntry("Creation of OneDrive API Upload Session failed.", ["verbose"]);
			// return upload() will return a JSONValue response, create an empty JSONValue response to return
			uploadSession = null;
		}
		// Return the JSON
		return uploadSession;
	}
	
	// Save the session upload data
	void saveSessionFile(string threadUploadSessionFilePath, JSONValue uploadSessionData) {
		
		try {
			std.file.write(threadUploadSessionFilePath, uploadSessionData.toString());
		} catch (FileException e) {
			// display the error message
			displayFileSystemErrorMessage(e.msg, getFunctionName!({}));
		}
	}
	
	// Perform the upload of file via the Upload Session that was created
	JSONValue performSessionFileUpload(OneDriveApi activeOneDriveApiInstance, ulong thisFileSize, JSONValue uploadSessionData, string threadUploadSessionFilePath) {
			
		// Response for upload
		JSONValue uploadResponse;
	
		// Session JSON needs to contain valid elements
		// Get the offset details
		ulong fragmentSize = 10 * 2^^20; // 10 MiB
		size_t fragmentCount = 0;
		ulong fragSize = 0;
		ulong offset = uploadSessionData["nextExpectedRanges"][0].str.splitter('-').front.to!ulong;
		size_t expected_total_fragments = cast(size_t) ceil(double(thisFileSize) / double(fragmentSize));
		ulong start_unix_time = Clock.currTime.toUnixTime();
		int h, m, s;
		string etaString;
		string uploadLogEntry = "Uploading: " ~ uploadSessionData["localPath"].str ~ " ... ";

		// Start the session upload using the active API instance for this thread
		while (true) {
			fragmentCount++;
			addLogEntry("Fragment: " ~ to!string(fragmentCount) ~ " of " ~ to!string(expected_total_fragments), ["debug"]);
			
			// What ETA string do we use?
			auto eta = calc_eta((fragmentCount -1), expected_total_fragments, start_unix_time);
			if (eta == 0) {
				// Initial calculation ... 
				etaString = format!"|  ETA    --:--:--";
			} else {
				// we have at least an ETA provided
				dur!"seconds"(eta).split!("hours", "minutes", "seconds")(h, m, s);
				etaString = format!"|  ETA    %02d:%02d:%02d"( h, m, s);
			}
			
			// Calculate this progress output
			auto ratio = cast(double)(fragmentCount -1) / expected_total_fragments;
			// Convert the ratio to a percentage and format it to two decimal places
			string percentage = leftJustify(format("%d%%", cast(int)(ratio * 100)), 5, ' ');
			addLogEntry(uploadLogEntry ~ percentage ~ etaString, ["consoleOnly"]);
			
			// What fragment size will be used?
			addLogEntry("fragmentSize: " ~ to!string(fragmentSize) ~ " offset: " ~ to!string(offset) ~ " thisFileSize: " ~ to!string(thisFileSize), ["debug"]);
			fragSize = fragmentSize < thisFileSize - offset ? fragmentSize : thisFileSize - offset;
			addLogEntry("Using fragSize: " ~ to!string(fragSize), ["debug"]);
						
			// fragSize must not be a negative value
			if (fragSize < 0) {
				// Session upload will fail
				// not a JSON object - fragment upload failed
				addLogEntry("File upload session failed - invalid calculation of fragment size", ["verbose"]);
				if (exists(threadUploadSessionFilePath)) {
					remove(threadUploadSessionFilePath);
				}
				// set uploadResponse to null as error
				uploadResponse = null;
				return uploadResponse;
			}
			
			// If the resume upload fails, we need to check for a return code here
			try {
				uploadResponse = activeOneDriveApiInstance.uploadFragment(
					uploadSessionData["uploadUrl"].str,
					uploadSessionData["localPath"].str,
					offset,
					fragSize,
					thisFileSize
				);
			} catch (OneDriveException exception) {
				// if a 100 uploadResponse is generated, continue
				if (exception.httpStatusCode == 100) {
					continue;
				}
				
				// There was an error uploadResponse from OneDrive when uploading the file fragment
				
				// Issue https://github.com/abraunegg/onedrive/issues/2747
				// if a 416 uploadResponse is generated, continue
				if (exception.httpStatusCode == 416) {
					continue;
				}
				
				// Handle transient errors:
				//   408 - Request Time Out
				//   429 - Too Many Requests
				//   503 - Service Unavailable
				//   504 - Gateway Timeout
					
				// Insert a new line as well, so that the below error is inserted on the console in the right location
				addLogEntry("Fragment upload failed - received an exception response from OneDrive API", ["verbose"]);
				// display what the error is
				displayOneDriveErrorMessage(exception.msg, getFunctionName!({}));
				// retry fragment upload in case error is transient
				addLogEntry("Retrying fragment upload", ["verbose"]);
				
				try {
					uploadResponse = activeOneDriveApiInstance.uploadFragment(
						uploadSessionData["uploadUrl"].str,
						uploadSessionData["localPath"].str,
						offset,
						fragSize,
						thisFileSize
					);
				} catch (OneDriveException e) {
					// OneDrive threw another error on retry
					addLogEntry("Retry to upload fragment failed", ["verbose"]);
					// display what the error is
					displayOneDriveErrorMessage(e.msg, getFunctionName!({}));
					// set uploadResponse to null as the fragment upload was in error twice
					uploadResponse = null;
				} catch (std.exception.ErrnoException e) {
					// There was a file system error - display the error message
					displayFileSystemErrorMessage(e.msg, getFunctionName!({}));
					return uploadResponse;
				}
			} catch (ErrnoException e) {
				// There was a file system error
				// display the error message
				displayFileSystemErrorMessage(e.msg, getFunctionName!({}));
				uploadResponse = null;
				return uploadResponse;
			}
			
			// was the fragment uploaded without issue?
			if (uploadResponse.type() == JSONType.object){
				offset += fragmentSize;
				if (offset >= thisFileSize) {
					break;
				}
				// update the uploadSessionData details
				uploadSessionData["expirationDateTime"] = uploadResponse["expirationDateTime"];
				uploadSessionData["nextExpectedRanges"] = uploadResponse["nextExpectedRanges"];
				saveSessionFile(threadUploadSessionFilePath, uploadSessionData);
			} else {
				// not a JSON object - fragment upload failed
				addLogEntry("File upload session failed - invalid response from OneDrive API", ["verbose"]);
				
				// cleanup session data
				if (exists(threadUploadSessionFilePath)) {
					remove(threadUploadSessionFilePath);
				}
				// set uploadResponse to null as error
				uploadResponse = null;
				return uploadResponse;
			}
		}
		
		// upload complete
		ulong end_unix_time = Clock.currTime.toUnixTime();
		auto upload_duration = cast(int)(end_unix_time - start_unix_time);
		dur!"seconds"(upload_duration).split!("hours", "minutes", "seconds")(h, m, s);
		etaString = format!"| DONE in %02d:%02d:%02d"( h, m, s);
		addLogEntry(uploadLogEntry ~ "100% " ~ etaString, ["consoleOnly"]);
		
		// Remove session file if it exists		
		if (exists(threadUploadSessionFilePath)) {
			remove(threadUploadSessionFilePath);
		}
		
		// Return the session upload response
		return uploadResponse;
	}
	
	// Delete an item on OneDrive
	void uploadDeletedItem(Item itemToDelete, string path) {
	
		OneDriveApi uploadDeletedItemOneDriveApiInstance;
			
		// Are we in a situation where we HAVE to keep the data online - do not delete the remote object
		if (noRemoteDelete) {
			if ((itemToDelete.type == ItemType.dir)) {
				// Do not process remote directory delete
				addLogEntry("Skipping remote directory delete as --upload-only & --no-remote-delete configured", ["verbose"]);
			} else {
				// Do not process remote file delete
				addLogEntry("Skipping remote file delete as --upload-only & --no-remote-delete configured", ["verbose"]);
			}
		} else {
			
			// Is this a --download-only operation?
			if (!appConfig.getValueBool("download_only")) {
				// Process the delete - delete the object online
				addLogEntry("Deleting item from Microsoft OneDrive: " ~ path);
				bool flagAsBigDelete = false;
				
				Item[] children;
				ulong itemsToDelete;
			
				if ((itemToDelete.type == ItemType.dir)) {
					// Query the database - how many objects will this remove?
					children = getChildren(itemToDelete.driveId, itemToDelete.id);
					// Count the returned items + the original item (1)
					itemsToDelete = count(children) + 1;
					addLogEntry("Number of items online to delete: " ~ to!string(itemsToDelete), ["debug"]);
				} else {
					itemsToDelete = 1;
				}
				// Clear array
				children = [];
				
				// A local delete of a file|folder when using --monitor  will issue a inotify event, which will trigger the local & remote data immediately be deleted
				// The user may also be --sync process, so we are checking if something was deleted between application use
				if (itemsToDelete >= appConfig.getValueLong("classify_as_big_delete")) {
					// A big delete has been detected
					flagAsBigDelete = true;
					if (!appConfig.getValueBool("force")) {
						addLogEntry("ERROR: An attempt to remove a large volume of data from OneDrive has been detected. Exiting client to preserve your data on Microsoft OneDrive");
						addLogEntry("ERROR: The total number of items being deleted is: " ~ to!string(itemsToDelete));
						addLogEntry("ERROR: To delete a large volume of data use --force or increase the config value 'classify_as_big_delete' to a larger value");
						addLogEntry("ERROR: Optionally, perform a --resync to reset your local syncronisation state");
						// Must exit here to preserve data on online , allow logging to be done
						forceExit();
					}
				}
				
				// Are we in a --dry-run scenario?
				if (!dryRun) {
					// We are not in a dry run scenario
					addLogEntry("itemToDelete: " ~ to!string(itemToDelete), ["debug"]);
					
					// what item are we trying to delete?
					addLogEntry("Attempting to delete this single item id: " ~ itemToDelete.id ~ " from drive: " ~ itemToDelete.driveId, ["debug"]);
					
					// Configure these item variables to handle OneDrive Business Shared Folder Deletion
					Item actualItemToDelete;
					Item remoteShortcutLinkItem;
					
					// OneDrive Business Shared Folder Deletion Handling
					// Is this a Business Account with Sync Business Shared Items enabled?
					if ((appConfig.accountType == "business") && (appConfig.getValueBool("sync_business_shared_items"))) {
						// Syncing Business Shared Items is enabled
						if (itemToDelete.driveId != appConfig.defaultDriveId) {
							// The item to delete is on a remote drive ... technically we do not own this and should not be deleting this online
							// We should however be deleting the 'link' in our account online, and, remove the DB link entry
							if (itemToDelete.type == ItemType.dir) {			
								// Query the database for this potential link
								itemDB.selectByPathIncludingRemoteItems(path, appConfig.defaultDriveId, remoteShortcutLinkItem);
							}
						}
					}
					
					// Configure actualItemToDelete
					if (remoteShortcutLinkItem.id != "") {
						// A DB entry was returned
						addLogEntry("remoteShortcutLinkItem: " ~ to!string(remoteShortcutLinkItem), ["debug"]);
						// Set actualItemToDelete to this data
						actualItemToDelete = remoteShortcutLinkItem;
						// Delete the shortcut reference in the local database
						itemDB.deleteById(remoteShortcutLinkItem.driveId, remoteShortcutLinkItem.id);
						addLogEntry("Deleted OneDrive Business Shared Folder 'Shorcut Link'", ["debug"]);
					} else {
						// No data was returned, use the original data
						actualItemToDelete = itemToDelete;
					}
					
					// Try the online deletion
					try {
						// Create new OneDrive API Instance
						uploadDeletedItemOneDriveApiInstance = new OneDriveApi(appConfig);
						uploadDeletedItemOneDriveApiInstance.initialise();
					
						// Perform the delete via the default OneDrive API instance
						uploadDeletedItemOneDriveApiInstance.deleteById(actualItemToDelete.driveId, actualItemToDelete.id);
						
						// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
						uploadDeletedItemOneDriveApiInstance.releaseCurlEngine();
						uploadDeletedItemOneDriveApiInstance = null;
						// Perform Garbage Collection
						GC.collect();
					
					} catch (OneDriveException e) {
						if (e.httpStatusCode == 404) {
							// item.id, item.eTag could not be found on the specified driveId
							addLogEntry("OneDrive reported: The resource could not be found to be deleted.", ["verbose"]);
						}
						
						// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
						uploadDeletedItemOneDriveApiInstance.releaseCurlEngine();
						uploadDeletedItemOneDriveApiInstance = null;
						// Perform Garbage Collection
						GC.collect();
					}
					
					// Delete the reference in the local database - use the original input
					itemDB.deleteById(itemToDelete.driveId, itemToDelete.id);
					if (itemToDelete.remoteId != null) {
						// If the item is a remote item, delete the reference in the local database
						itemDB.deleteById(itemToDelete.remoteDriveId, itemToDelete.remoteId);
					}
				} else {
					// log that this is a dry-run activity
					addLogEntry("dry run - no delete activity");
				}
			} else {
				// --download-only operation, we are not uploading any delete event to OneDrive
				addLogEntry("Not pushing local delete to Microsoft OneDrive due to --download-only being used", ["debug"]);
			}
		}
	}
	
	// Get the children of an item id from the database
	Item[] getChildren(string driveId, string id) {
				
		Item[] children;
		children ~= itemDB.selectChildren(driveId, id);
		foreach (Item child; children) {
			if (child.type != ItemType.file) {
				// recursively get the children of this child
				children ~= getChildren(child.driveId, child.id);
			}
		}
		return children;
	}
	
	// Perform a 'reverse' delete of all child objects on OneDrive
	void performReverseDeletionOfOneDriveItems(Item[] children, Item itemToDelete) {
		
		// Log what is happening
		addLogEntry("Attempting a reverse delete of all child objects from OneDrive", ["debug"]);
		
		// Create a new API Instance for this thread and initialise it
		OneDriveApi performReverseDeletionOneDriveApiInstance;
		performReverseDeletionOneDriveApiInstance = new OneDriveApi(appConfig);
		performReverseDeletionOneDriveApiInstance.initialise();
		
		foreach_reverse (Item child; children) {
			// Log the action
			addLogEntry("Attempting to delete this child item id: " ~ child.id ~ " from drive: " ~ child.driveId, ["debug"]);
			
			// perform the delete via the default OneDrive API instance
			performReverseDeletionOneDriveApiInstance.deleteById(child.driveId, child.id, child.eTag);
			// delete the child reference in the local database
			itemDB.deleteById(child.driveId, child.id);
		}
		// Log the action
		addLogEntry("Attempting to delete this parent item id: " ~ itemToDelete.id ~ " from drive: " ~ itemToDelete.driveId, ["debug"]);
		
		// Perform the delete via the default OneDrive API instance
		performReverseDeletionOneDriveApiInstance.deleteById(itemToDelete.driveId, itemToDelete.id, itemToDelete.eTag);
		
		// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
		performReverseDeletionOneDriveApiInstance.releaseCurlEngine();
		performReverseDeletionOneDriveApiInstance = null;
		// Perform Garbage Collection
		GC.collect();
	}
	
	// Create a fake OneDrive response suitable for use with saveItem
	// Create a fake OneDrive response suitable for use with saveItem
	JSONValue createFakeResponse(string path) {
		import std.digest.sha;
		
		// Generate a simulated JSON response which can be used
		// At a minimum we need:
		// 1. eTag
		// 2. cTag
		// 3. fileSystemInfo
		// 4. file or folder. if file, hash of file
		// 5. id
		// 6. name
		// 7. parent reference
		
		string fakeDriveId = appConfig.defaultDriveId;
		string fakeRootId = appConfig.defaultRootId;
		SysTime mtime = exists(path) ? timeLastModified(path).toUTC() : Clock.currTime(UTC());
		auto sha1 = new SHA1Digest();
		ubyte[] fakedOneDriveItemValues = sha1.digest(path);
		JSONValue fakeResponse;

		string parentPath = dirName(path);
		if (parentPath != "." && exists(path)) {
			foreach (searchDriveId; onlineDriveDetails.keys) {
				Item databaseItem;
				if (itemDB.selectByPath(parentPath, searchDriveId, databaseItem)) {
					fakeDriveId = databaseItem.driveId;
					fakeRootId = databaseItem.id;
					break; // Exit loop after finding the first match
				}
			}
		}

		fakeResponse = [
			"id": JSONValue(toHexString(fakedOneDriveItemValues)),
			"cTag": JSONValue(toHexString(fakedOneDriveItemValues)),
			"eTag": JSONValue(toHexString(fakedOneDriveItemValues)),
			"fileSystemInfo": JSONValue([
				"createdDateTime": mtime.toISOExtString(),
				"lastModifiedDateTime": mtime.toISOExtString()
			]),
			"name": JSONValue(baseName(path)),
			"parentReference": JSONValue([
				"driveId": JSONValue(fakeDriveId),
				"driveType": JSONValue(appConfig.accountType),
				"id": JSONValue(fakeRootId)
			])
		];

		if (exists(path)) {
			if (isDir(path)) {
				fakeResponse["folder"] = JSONValue("");
			} else {
				string quickXorHash = computeQuickXorHash(path);
				fakeResponse["file"] = JSONValue([
					"hashes": JSONValue(["quickXorHash": JSONValue(quickXorHash)])
				]);
			}
		} else {
			// Assume directory if path does not exist
			fakeResponse["folder"] = JSONValue("");
		}

		addLogEntry("Generated Fake OneDrive Response: " ~ to!string(fakeResponse), ["debug"]);
		return fakeResponse;
	}

	// Save JSON item details into the item database
	void saveItem(JSONValue jsonItem) {
		// jsonItem has to be a valid object
		if (jsonItem.type() == JSONType.object) {
			// Check if the response JSON has an 'id', otherwise makeItem() fails with 'Key not found: id'
			if (hasId(jsonItem)) {
				// Are we in a --upload-only & --remove-source-files scenario?
				// We do not want to add the item to the database in this situation as there is no local reference to the file post file deletion
				// If the item is a directory, we need to add this to the DB, if this is a file, we dont add this, the parent path is not in DB, thus any new files in this directory are not added
				if ((uploadOnly) && (localDeleteAfterUpload) && (isItemFile(jsonItem))) {
					// Log that we skipping adding item to the local DB and the reason why
					addLogEntry("Skipping adding to database as --upload-only & --remove-source-files configured", ["debug"]);
				} else {
					// What is the JSON item we are trying to create a DB record with?
					addLogEntry("saveItem - creating DB item from this JSON: " ~ to!string(jsonItem), ["debug"]);
					
					// Takes a JSON input and formats to an item which can be used by the database
					Item item = makeItem(jsonItem);
					
					// Is this JSON item a 'root' item?
					if ((isItemRoot(jsonItem)) && (item.name == "root")) {
						addLogEntry("Updating DB Item object with correct values as this is a 'root' object", ["debug"]);
						item.parentId = null; 	// ensures that this database entry has no parent
						// Check for parentReference
						if (hasParentReference(jsonItem)) {
							// Set the correct item.driveId
							addLogEntry("ROOT JSON Item HAS parentReference .... setting item.driveId = jsonItem['parentReference']['driveId'].str", ["debug"]);
							item.driveId = jsonItem["parentReference"]["driveId"].str;
						}
						
						// We only should be adding our account 'root' to the database, not shared folder 'root' items
						if (item.driveId != appConfig.defaultDriveId) {
							// Shared Folder drive 'root' object .. we dont want this item
							addLogEntry("NOT adding 'remote root' object to database: " ~ to!string(item), ["debug"]);
							return;
						}
					}
					
					// Add to the local database
					itemDB.upsert(item);
					
					// If we have a remote drive ID, add this to our list of known drive id's
					if (!item.remoteDriveId.empty) {
						// Keep the DriveDetailsCache array with unique entries only
						DriveDetailsCache cachedOnlineDriveData;
						if (!canFindDriveId(item.remoteDriveId, cachedOnlineDriveData)) {
							// Add this driveId to the drive cache
							addOrUpdateOneDriveOnlineDetails(item.remoteDriveId);
						}
					}
				}
			} else {
				// log error
				addLogEntry("ERROR: OneDrive response missing required 'id' element");
				addLogEntry("ERROR: " ~ to!string(jsonItem));
			}
		} else {
			// log error
			addLogEntry("ERROR: An error was returned from OneDrive and the resulting response is not a valid JSON object that can be processed.");
			addLogEntry("ERROR: Increase logging verbosity to assist determining why.");
		}
	}
	
	// Wrapper function for makeDatabaseItem so we can check to ensure that the item has the required hashes
	Item makeItem(JSONValue onedriveJSONItem) {
			
		// Make the DB Item from the JSON data provided
		Item newDatabaseItem = makeDatabaseItem(onedriveJSONItem);
		
		// Is this a 'file' item that has not been deleted? Deleted items have no hash
		if ((newDatabaseItem.type == ItemType.file) && (!isItemDeleted(onedriveJSONItem))) {
			// Does this item have a file size attribute?
			if (hasFileSize(onedriveJSONItem)) {
				// Is the file size greater than 0?
				if (onedriveJSONItem["size"].integer > 0) {
					// Does the DB item have any hashes as per the API provided JSON data?
					if ((newDatabaseItem.quickXorHash.empty) && (newDatabaseItem.sha256Hash.empty)) {
						// Odd .. there is no hash for this item .. why is that?
						// Is there a 'file' JSON element?
						if ("file" in onedriveJSONItem) {
							// Microsoft OneDrive OneNote objects will report as files but have 'application/msonenote' and 'application/octet-stream' as mime types
							if ((isMicrosoftOneNoteMimeType1(onedriveJSONItem)) || (isMicrosoftOneNoteMimeType2(onedriveJSONItem))) {
								// Debug log output that this is a potential OneNote object
								addLogEntry("This item is potentially an associated Microsoft OneNote Object Item", ["debug"]);
							} else {
								// Not a Microsoft OneNote Mime Type Object ..
								string apiWarningMessage = "WARNING: OneDrive API inconsistency - this file does not have any hash: ";
								// This is computationally expensive .. but we are only doing this if there are no hashes provided
								bool parentInDatabase = itemDB.idInLocalDatabase(newDatabaseItem.driveId, newDatabaseItem.parentId);
								// Is the parent id in the database?
								if (parentInDatabase) {
									// This is again computationally expensive .. calculate this item path to advise the user the actual path of this item that has no hash
									string newItemPath = computeItemPath(newDatabaseItem.driveId, newDatabaseItem.parentId) ~ "/" ~ newDatabaseItem.name;
									addLogEntry(apiWarningMessage ~ newItemPath);
								} else {
									// Parent is not in the database .. why?
									// Check if the parent item had been skipped .. 
									if (newDatabaseItem.parentId in skippedItems) {
										addLogEntry(apiWarningMessage ~ "newDatabaseItem.parentId listed within skippedItems", ["debug"]);
									} else {
										// Use the item ID .. there is no other reference available, parent is not being skipped, so we should have been able to calculate this - but we could not
										addLogEntry(apiWarningMessage ~ newDatabaseItem.id);
									}
								}
							}
						}	
					}
				} else {
					// zero file size
					addLogEntry("This item file is zero size - potentially no hash provided by the OneDrive API", ["debug"]);
				}
			}
		}
		
		// Return the new database item
		return newDatabaseItem;
	}
	
	// Print the fileDownloadFailures and fileUploadFailures arrays if they are not empty
	void displaySyncFailures() {
		bool logFailures(string[] failures, string operation) {
			if (failures.empty) return false;

			addLogEntry();
			addLogEntry("Failed items to " ~ operation ~ " to/from Microsoft OneDrive: " ~ to!string(failures.length));

			foreach (failedFile; failures) {
				addLogEntry("Failed to " ~ operation ~ ": " ~ failedFile, ["info", "notify"]);

				foreach (searchDriveId; onlineDriveDetails.keys) {
					Item dbItem;
					if (itemDB.selectByPath(failedFile, searchDriveId, dbItem)) {
						addLogEntry("ERROR: Failed " ~ operation ~ " path found in database, must delete this item from the database .. it should not be in there if the file failed to " ~ operation);
						itemDB.deleteById(dbItem.driveId, dbItem.id);
						if (dbItem.remoteDriveId != null) {
							itemDB.deleteById(dbItem.remoteDriveId, dbItem.remoteId);
						}
					}
				}
			}
			return true;
		}

		bool downloadFailuresLogged = logFailures(fileDownloadFailures, "download");
		bool uploadFailuresLogged = logFailures(fileUploadFailures, "upload");
		syncFailures = downloadFailuresLogged || uploadFailuresLogged;
	}
	
	// Generate a /delta compatible response - for use when we cant actually use /delta
	// This is required when the application is configured to use National Azure AD deployments as these do not support /delta queries
	// The same technique can also be used when we are using --single-directory. The parent objects up to the single directory target can be added,
	// then once the target of the --single-directory request is hit, all of the children of that path can be queried, giving a much more focused
	// JSON response which can then be processed, negating the need to continuously traverse the tree and 'exclude' items
	JSONValue generateDeltaResponse(string pathToQuery = null) {
		// JSON value which will be responded with
		JSONValue selfGeneratedDeltaResponse;
		
		// Function variables
		bool remotePathObject = false;
		Item searchItem;
		JSONValue rootData;
		JSONValue driveData;
		JSONValue pathData;
		JSONValue topLevelChildren;
		JSONValue[] childrenData;
		string nextLink;
		OneDriveApi generateDeltaResponseOneDriveApiInstance;
		
		// Was a path to query passed in?
		if (pathToQuery.empty) {
			// Will query for the 'root'
			pathToQuery = ".";
		}
		
		// Create new OneDrive API Instance
		generateDeltaResponseOneDriveApiInstance = new OneDriveApi(appConfig);
		generateDeltaResponseOneDriveApiInstance.initialise();
		
		// Is this a --single-directory invocation?
		if (!singleDirectoryScope) {
			// In a --resync scenario, there is no DB data to query, so we have to query the OneDrive API here to get relevant details
			try {
				// Query the OneDrive API, using the path, which will query 'our' OneDrive Account
				pathData = generateDeltaResponseOneDriveApiInstance.getPathDetails(pathToQuery);
				
				// Is the path on OneDrive local or remote to our account drive id?
				if (!isItemRemote(pathData)) {
					// The path we are seeking is local to our account drive id
					searchItem.driveId = pathData["parentReference"]["driveId"].str;
					searchItem.id = pathData["id"].str;
				} else {
					// The path we are seeking is remote to our account drive id
					searchItem.driveId = pathData["remoteItem"]["parentReference"]["driveId"].str;
					searchItem.id = pathData["remoteItem"]["id"].str;
					remotePathObject = true;
				}
			} catch (OneDriveException e) {
				// Display error message
				displayOneDriveErrorMessage(e.msg, getFunctionName!({}));
				
				// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
				generateDeltaResponseOneDriveApiInstance.releaseCurlEngine();
				generateDeltaResponseOneDriveApiInstance = null;
				// Perform Garbage Collection
				GC.collect();
				
				// Must force exit here, allow logging to be done
				forceExit();
			}
		} else {
			// When setSingleDirectoryScope() was called, the following were set to the correct items, even if the path was remote:
			// - singleDirectoryScopeDriveId
			// - singleDirectoryScopeItemId
			// Reuse these prior set values
			searchItem.driveId = singleDirectoryScopeDriveId;
			searchItem.id = singleDirectoryScopeItemId;
		}
		
		// Before we get any data from the OneDrive API, flag any child object in the database as out-of-sync for this driveId & and object id
		// Downgrade ONLY files associated with this driveId and idToQuery
		addLogEntry("Downgrading all children for this searchItem.driveId (" ~ searchItem.driveId ~ ") and searchItem.id (" ~ searchItem.id ~ ") to an out-of-sync state", ["debug"]);
		
		Item[] drivePathChildren = getChildren(searchItem.driveId, searchItem.id);
		if (count(drivePathChildren) > 0) {
			// Children to process and flag as out-of-sync	
			foreach (drivePathChild; drivePathChildren) {
				// Flag any object in the database as out-of-sync for this driveId & and object id
				addLogEntry("Downgrading item as out-of-sync: " ~ drivePathChild.id, ["debug"]);
				itemDB.downgradeSyncStatusFlag(drivePathChild.driveId, drivePathChild.id);
			}
		}
		// Clear DB response array
		drivePathChildren = [];
		
		// Get drive details for the provided driveId
		try {
			driveData = generateDeltaResponseOneDriveApiInstance.getPathDetailsById(searchItem.driveId, searchItem.id);
		} catch (OneDriveException exception) {
			addLogEntry("driveData = generateDeltaResponseOneDriveApiInstance.getPathDetailsById(searchItem.driveId, searchItem.id) generated a OneDriveException", ["debug"]);
			
			string thisFunctionName = getFunctionName!({});
			// Default operation if not 408,429,503,504 errors
			// - 408,429,503,504 errors are handled as a retry within oneDriveApiInstance
			// Display what the error is
			displayOneDriveErrorMessage(exception.msg, thisFunctionName);
		}
		
		// Was a valid JSON response for 'driveData' provided?
		if (driveData.type() == JSONType.object) {
		
			// Dynamic output for a non-verbose run so that the user knows something is happening
			if (appConfig.verbosityCount == 0) {
				if (!appConfig.suppressLoggingOutput) {
					addProcessingLogHeaderEntry("Fetching items from the OneDrive API for Drive ID: " ~ searchItem.driveId, appConfig.verbosityCount);
				}
			} else {
				addLogEntry("Generating a /delta response from the OneDrive API for Drive ID: " ~ searchItem.driveId, ["verbose"]);
			}
		
			// Process this initial JSON response
			if (!isItemRoot(driveData)) {
				// Are we generating a /delta response for a Shared Folder, if not, then we need to add the drive root details first
				if (!sharedFolderDeltaGeneration) {
					// Get root details for the provided driveId
					try {
						rootData = generateDeltaResponseOneDriveApiInstance.getDriveIdRoot(searchItem.driveId);
					} catch (OneDriveException exception) {
						addLogEntry("rootData = onedrive.getDriveIdRoot(searchItem.driveId) generated a OneDriveException", ["debug"]);
						
						string thisFunctionName = getFunctionName!({});
						// Default operation if not 408,429,503,504 errors
						// - 408,429,503,504 errors are handled as a retry within oneDriveApiInstance
						// Display what the error is
						displayOneDriveErrorMessage(exception.msg, thisFunctionName);
					}
					// Add driveData JSON data to array
					addLogEntry("Adding OneDrive root details for processing", ["verbose"]);
					childrenData ~= rootData;
				}
			}
			
			// Add driveData JSON data to array
			addLogEntry("Adding OneDrive folder details for processing", ["verbose"]);
			childrenData ~= driveData;
		} else {
			// driveData is an invalid JSON object
			addLogEntry("CODING TO DO: The query of OneDrive API to getPathDetailsById generated an invalid JSON response - thus we cant build our own /delta simulated response ... how to handle?");
			// Must exit here
			generateDeltaResponseOneDriveApiInstance.releaseCurlEngine();
			// Free object and memory
			generateDeltaResponseOneDriveApiInstance = null;
			// Perform Garbage Collection
			GC.collect();
			
			// Must force exit here, allow logging to be done
			forceExit();
		}
		
		// For each child object, query the OneDrive API
		while (true) {
			// Check if exitHandlerTriggered is true
			if (exitHandlerTriggered) {
				// break out of the 'while (true)' loop
				break;
			}
			// query top level children
			try {
				topLevelChildren = generateDeltaResponseOneDriveApiInstance.listChildren(searchItem.driveId, searchItem.id, nextLink);
			} catch (OneDriveException exception) {
				// OneDrive threw an error
				addLogEntry("------------------------------------------------------------------", ["debug"]);
				addLogEntry("Query Error: topLevelChildren = generateDeltaResponseOneDriveApiInstance.listChildren(searchItem.driveId, searchItem.id, nextLink)", ["debug"]);
				addLogEntry("driveId:   " ~ searchItem.driveId, ["debug"]);
				addLogEntry("idToQuery: " ~ searchItem.id, ["debug"]);
				addLogEntry("nextLink:  " ~ nextLink, ["debug"]);
				
				string thisFunctionName = getFunctionName!({});
				// Default operation if not 408,429,503,504 errors
				// - 408,429,503,504 errors are handled as a retry within oneDriveApiInstance
				// Display what the error is
				displayOneDriveErrorMessage(exception.msg, thisFunctionName);
			}
			
			// Process top level children
			if (!remotePathObject) {
				// Main account root folder
				addLogEntry("Adding " ~ to!string(count(topLevelChildren["value"].array)) ~ " OneDrive items for processing from the OneDrive 'root' Folder", ["verbose"]);
			} else {
				// Shared Folder
				addLogEntry("Adding " ~ to!string(count(topLevelChildren["value"].array)) ~ " OneDrive items for processing from the OneDrive Shared Folder", ["verbose"]);
			}
			
			foreach (child; topLevelChildren["value"].array) {
				// Check for any Client Side Filtering here ... we should skip querying the OneDrive API for 'folders' that we are going to just process and skip anyway.
				// This avoids needless calls to the OneDrive API, and potentially speeds up this process.
				if (!checkJSONAgainstClientSideFiltering(child)) {
					// add this child to the array of objects
					childrenData ~= child;
					// is this child a folder?
					if (isItemFolder(child)) {
						// We have to query this folders children if childCount > 0
						if (child["folder"]["childCount"].integer > 0){
							// This child folder has children
							string childIdToQuery = child["id"].str;
							string childDriveToQuery = child["parentReference"]["driveId"].str;
							auto childParentPath = child["parentReference"]["path"].str.split(":");
							string folderPathToScan = childParentPath[1] ~ "/" ~ child["name"].str;
							
							string pathForLogging;
							// Are we in a --single-directory situation? If we are, the path we are using for logging needs to use the input path as a base
							if (singleDirectoryScope) {
								pathForLogging = appConfig.getValueString("single_directory") ~ "/" ~ child["name"].str;
							} else {
								pathForLogging = child["name"].str;
							}
							
							// Query the children of this item
							JSONValue[] grandChildrenData = queryForChildren(childDriveToQuery, childIdToQuery, folderPathToScan, pathForLogging);
							foreach (grandChild; grandChildrenData.array) {
								// add the grandchild to the array
								childrenData ~= grandChild;
							}
						}
					}
				}
			}
			// If a collection exceeds the default page size (200 items), the @odata.nextLink property is returned in the response 
			// to indicate more items are available and provide the request URL for the next page of items.
			if ("@odata.nextLink" in topLevelChildren) {
				// Update nextLink to next changeSet bundle
				addLogEntry("Setting nextLink to (@odata.nextLink): " ~ nextLink, ["debug"]);
				nextLink = topLevelChildren["@odata.nextLink"].str;
			} else break;
			
			// Sleep for a while to avoid busy-waiting
			Thread.sleep(dur!"msecs"(100)); // Adjust the sleep duration as needed
		}
		
		if (appConfig.verbosityCount == 0) {
			// Dynamic output for a non-verbose run so that the user knows something is happening
			if (!appConfig.suppressLoggingOutput) {
				// Close out the '....' being printed to the console
				completeProcessingDots();
			}
		}
		
		// Craft response from all returned JSON elements
		selfGeneratedDeltaResponse = [
						"@odata.context": JSONValue("https://graph.microsoft.com/v1.0/$metadata#Collection(driveItem)"),
						"value": JSONValue(childrenData.array)
						];
		
		// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
		generateDeltaResponseOneDriveApiInstance.releaseCurlEngine();
		generateDeltaResponseOneDriveApiInstance = null;
		// Perform Garbage Collection
		GC.collect();
		
		// Return the generated JSON response
		return selfGeneratedDeltaResponse;
	}
	
	// Query the OneDrive API for the specified child id for any children objects
	JSONValue[] queryForChildren(string driveId, string idToQuery, string childParentPath, string pathForLogging) {
				
		// function variables
		JSONValue thisLevelChildren;
		JSONValue[] thisLevelChildrenData;
		string nextLink;
		
		// Create new OneDrive API Instance
		OneDriveApi queryChildrenOneDriveApiInstance;
		queryChildrenOneDriveApiInstance = new OneDriveApi(appConfig);
		queryChildrenOneDriveApiInstance.initialise();
		
		while (true) {
			// Check if exitHandlerTriggered is true
			if (exitHandlerTriggered) {
				// break out of the 'while (true)' loop
				break;
			}
			
			// query this level children
			try {
				thisLevelChildren = queryThisLevelChildren(driveId, idToQuery, nextLink, queryChildrenOneDriveApiInstance);
			} catch (OneDriveException exception) {
				// MAY NEED FUTURE WORK HERE .. YET TO TRIGGER THIS
				addLogEntry("CODING TO DO: EXCEPTION HANDLING NEEDED: thisLevelChildren = queryThisLevelChildren(driveId, idToQuery, nextLink, queryChildrenOneDriveApiInstance)");
			}
			
			if (appConfig.verbosityCount == 0) {
				// Dynamic output for a non-verbose run so that the user knows something is happening
				if (!appConfig.suppressLoggingOutput) {
					addProcessingDotEntry();
				}
			}
			
			// Was a valid JSON response for 'thisLevelChildren' provided?
			if (thisLevelChildren.type() == JSONType.object) {
				// process this level children
				if (!childParentPath.empty) {
					// We dont use childParentPath to log, as this poses an information leak risk.
					// The full parent path of the child, as per the JSON might be:
					//   /Level 1/Level 2/Level 3/Child Shared Folder/some folder/another folder
					// But 'Child Shared Folder' is what is shared, thus '/Level 1/Level 2/Level 3/' is a potential information leak if logged.
					// Plus, the application output now shows accurately what is being shared - so that is a good thing.
					addLogEntry("Adding " ~ to!string(count(thisLevelChildren["value"].array)) ~ " OneDrive items for processing from " ~ pathForLogging, ["verbose"]);
				}
				foreach (child; thisLevelChildren["value"].array) {
					// Check for any Client Side Filtering here ... we should skip querying the OneDrive API for 'folders' that we are going to just process and skip anyway.
					// This avoids needless calls to the OneDrive API, and potentially speeds up this process.
					if (!checkJSONAgainstClientSideFiltering(child)) {
						// add this child to the array of objects
						thisLevelChildrenData ~= child;
						// is this child a folder?
						if (isItemFolder(child)){
							// We have to query this folders children if childCount > 0
							if (child["folder"]["childCount"].integer > 0){
								// This child folder has children
								string childIdToQuery = child["id"].str;
								string childDriveToQuery = child["parentReference"]["driveId"].str;
								auto grandchildParentPath = child["parentReference"]["path"].str.split(":");
								string folderPathToScan = grandchildParentPath[1] ~ "/" ~ child["name"].str;
								string newLoggingPath = pathForLogging ~ "/" ~ child["name"].str;
								JSONValue[] grandChildrenData = queryForChildren(childDriveToQuery, childIdToQuery, folderPathToScan, newLoggingPath);
								foreach (grandChild; grandChildrenData.array) {
									// add the grandchild to the array
									thisLevelChildrenData ~= grandChild;
								}
							}
						}
					}
				}
				// If a collection exceeds the default page size (200 items), the @odata.nextLink property is returned in the response 
				// to indicate more items are available and provide the request URL for the next page of items.
				if ("@odata.nextLink" in thisLevelChildren) {
					// Update nextLink to next changeSet bundle
					nextLink = thisLevelChildren["@odata.nextLink"].str;
					addLogEntry("Setting nextLink to (@odata.nextLink): " ~ nextLink, ["debug"]);
				} else break;
			
			} else {
				// Invalid JSON response when querying this level children
				addLogEntry("INVALID JSON response when attempting a retry of parent function - queryForChildren(driveId, idToQuery, childParentPath, pathForLogging)", ["debug"]);
				
				// retry thisLevelChildren = queryThisLevelChildren
				addLogEntry("Thread sleeping for an additional 30 seconds", ["debug"]);
				Thread.sleep(dur!"seconds"(30));
				addLogEntry("Retry this call thisLevelChildren = queryThisLevelChildren(driveId, idToQuery, nextLink, queryChildrenOneDriveApiInstance)", ["debug"]);
				thisLevelChildren = queryThisLevelChildren(driveId, idToQuery, nextLink, queryChildrenOneDriveApiInstance);
			}
			
			// Sleep for a while to avoid busy-waiting
			Thread.sleep(dur!"msecs"(100)); // Adjust the sleep duration as needed
		}
		
		// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
		queryChildrenOneDriveApiInstance.releaseCurlEngine();
		queryChildrenOneDriveApiInstance = null;
		// Perform Garbage Collection
		GC.collect();
		
		// return response
		return thisLevelChildrenData;
	}
	
	// Query the OneDrive API for the child objects for this element
	JSONValue queryThisLevelChildren(string driveId, string idToQuery, string nextLink, OneDriveApi queryChildrenOneDriveApiInstance) {
		
		// function variables 
		JSONValue thisLevelChildren;
		
		// query children
		try {
			// attempt API call
			addLogEntry("Attempting Query: thisLevelChildren = queryChildrenOneDriveApiInstance.listChildren(driveId, idToQuery, nextLink)", ["debug"]);
			thisLevelChildren = queryChildrenOneDriveApiInstance.listChildren(driveId, idToQuery, nextLink);
			addLogEntry("Query 'thisLevelChildren = queryChildrenOneDriveApiInstance.listChildren(driveId, idToQuery, nextLink)' performed successfully", ["debug"]);
		} catch (OneDriveException exception) {
			// OneDrive threw an error
			addLogEntry("------------------------------------------------------------------", ["debug"]);
			addLogEntry("Query Error: thisLevelChildren = queryChildrenOneDriveApiInstance.listChildren(driveId, idToQuery, nextLink)", ["debug"]);
			addLogEntry("driveId: " ~ driveId, ["debug"]);
			addLogEntry("idToQuery: " ~ idToQuery, ["debug"]);
			addLogEntry("nextLink: " ~ nextLink, ["debug"]);
			
			string thisFunctionName = getFunctionName!({});
			// Default operation if not 408,429,503,504 errors
			// - 408,429,503,504 errors are handled as a retry within oneDriveApiInstance
			// Display what the error is
			displayOneDriveErrorMessage(exception.msg, thisFunctionName);
			
		}
				
		// return response
		return thisLevelChildren;
	}
	
	// Traverses the provided path online, via the OneDrive API, following correct parent driveId and itemId elements across the account
	// to find if this full path exists. If this path exists online, the last item in the object path will be returned as a full JSON item.
	//
	// If the createPathIfMissing = false + no path exists online, a null invalid JSON item will be returned.
	// If the createPathIfMissing = true + no path exists online, the requested path will be created in the correct location online. The resulting
	// response to the directory creation will then be returned.
	//
	// This function also ensures that each path in the requested path actually matches the requested element to ensure that the OneDrive API response
	// is not falsely matching a 'case insensitive' match to the actual request which is a POSIX compliance issue.
	JSONValue queryOneDriveForSpecificPathAndCreateIfMissing(string thisNewPathToSearch, bool createPathIfMissing) {
		
		// function variables
		JSONValue getPathDetailsAPIResponse;
		string currentPathTree;
		Item parentDetails;
		JSONValue topLevelChildren;
		string nextLink;
		bool directoryFoundOnline = false;
		bool posixIssue = false;
		
		// Create a new API Instance for this thread and initialise it
		OneDriveApi queryOneDriveForSpecificPath;
		queryOneDriveForSpecificPath = new OneDriveApi(appConfig);
		queryOneDriveForSpecificPath.initialise();
		
		foreach (thisFolderName; pathSplitter(thisNewPathToSearch)) {
			addLogEntry("Testing for the existence online of this folder path: " ~ thisFolderName, ["debug"]);
			directoryFoundOnline = false;
			
			// If this is '.' this is the account root
			if (thisFolderName == ".") {
				currentPathTree = thisFolderName;
			} else {
				currentPathTree = currentPathTree ~ "/" ~ thisFolderName;
			}
			
			// What path are we querying
			addLogEntry("Attempting to query OneDrive for this path: " ~ currentPathTree, ["debug"]);
			
			// What query do we use?
			if (thisFolderName == ".") {
				// Query the root, set the right details
				try {
					getPathDetailsAPIResponse = queryOneDriveForSpecificPath.getPathDetails(currentPathTree);
					parentDetails = makeItem(getPathDetailsAPIResponse);
					// Save item to the database
					saveItem(getPathDetailsAPIResponse);
					directoryFoundOnline = true;
				} catch (OneDriveException exception) {
				
					string thisFunctionName = getFunctionName!({});
					// Default operation if not 408,429,503,504 errors
					// - 408,429,503,504 errors are handled as a retry within oneDriveApiInstance
					// Display what the error is
					displayOneDriveErrorMessage(exception.msg, thisFunctionName);
				}
			} else {
				// Ensure we have a valid driveId to search here
				if (parentDetails.driveId.empty) {
					parentDetails.driveId = appConfig.defaultDriveId;
				}
				
				// If the prior JSON 'getPathDetailsAPIResponse' is on this account driveId .. then continue to use getPathDetails
				if (parentDetails.driveId == appConfig.defaultDriveId) {
				
					try {
						// Query OneDrive API for this path
						getPathDetailsAPIResponse = queryOneDriveForSpecificPath.getPathDetails(currentPathTree);
						
						// Portable Operating System Interface (POSIX) testing of JSON response from OneDrive API
						if (hasName(getPathDetailsAPIResponse)) {
							performPosixTest(thisFolderName, getPathDetailsAPIResponse["name"].str);
						} else {
							throw new JsonResponseException("Unable to perform POSIX test as the OneDrive API request generated an invalid JSON response");
						}
						
						// No POSIX issue with requested path element
						parentDetails = makeItem(getPathDetailsAPIResponse);
						// Save item to the database
						saveItem(getPathDetailsAPIResponse);
						directoryFoundOnline = true;
						
						// Is this JSON a remote object
						addLogEntry("Testing if this is a remote Shared Folder", ["debug"]);
						if (isItemRemote(getPathDetailsAPIResponse)) {
							// Remote Directory .. need a DB Tie Record
							createDatabaseTieRecordForOnlineSharedFolder(parentDetails);
							
							// Temp DB Item to bind the 'remote' path to our parent path
							Item tempDBItem;
							// Set the name
							tempDBItem.name = parentDetails.name;
							// Set the correct item type
							tempDBItem.type = ItemType.dir;
							// Set the right elements using the 'remote' of the parent as the 'actual' for this DB Tie
							tempDBItem.driveId = parentDetails.remoteDriveId;
							tempDBItem.id = parentDetails.remoteId;
							// Set the correct mtime
							tempDBItem.mtime = parentDetails.mtime;
							
							// Update parentDetails to use this temp record
							parentDetails = tempDBItem;
						}
					} catch (OneDriveException exception) {
						if (exception.httpStatusCode == 404) {
							directoryFoundOnline = false;
						} else {
						
							string thisFunctionName = getFunctionName!({});
							// Default operation if not 408,429,503,504 errors
							// - 408,429,503,504 errors are handled as a retry within oneDriveApiInstance
							// Display what the error is
							displayOneDriveErrorMessage(exception.msg, thisFunctionName);
						}
					} catch (JsonResponseException e) {
							addLogEntry(e.msg, ["debug"]);
					}
				} else {
					// parentDetails.driveId is not the account drive id - thus will be a remote shared item
					addLogEntry("This parent directory is a remote object this next path will be on a remote drive", ["debug"]);
					
					// For this parentDetails.driveId, parentDetails.id object, query the OneDrive API for it's children
					while (true) {
						// Check if exitHandlerTriggered is true
						if (exitHandlerTriggered) {
							// break out of the 'while (true)' loop
							break;
						}
						// Query this remote object for its children
						topLevelChildren = queryOneDriveForSpecificPath.listChildren(parentDetails.driveId, parentDetails.id, nextLink);
						// Process each child
						foreach (child; topLevelChildren["value"].array) {
							// Is this child a folder?
							if (isItemFolder(child)) {
								// Is this the child folder we are looking for, and is a POSIX match?
								if (child["name"].str == thisFolderName) {
									// EXACT MATCH including case sensitivity: Flag that we found the folder online 
									directoryFoundOnline = true;
									// Use these details for the next entry path
									getPathDetailsAPIResponse = child;
									parentDetails = makeItem(getPathDetailsAPIResponse);
									// Save item to the database
									saveItem(getPathDetailsAPIResponse);
									// No need to continue searching
									break;
								} else {
									string childAsLower = toLower(child["name"].str);
									string thisFolderNameAsLower = toLower(thisFolderName);
									if (childAsLower == thisFolderNameAsLower) {	
										// This is a POSIX 'case in-sensitive match' ..... 
										// Local item name has a 'case-insensitive match' to an existing item on OneDrive
										posixIssue = true;
										throw new PosixException(thisFolderName, child["name"].str);
									}
								}
							}
						}
						
						if (directoryFoundOnline) {
							// We found the folder, no need to continue searching nextLink data
							break;
						}
						
						// If a collection exceeds the default page size (200 items), the @odata.nextLink property is returned in the response 
						// to indicate more items are available and provide the request URL for the next page of items.
						if ("@odata.nextLink" in topLevelChildren) {
							// Update nextLink to next changeSet bundle
							addLogEntry("Setting nextLink to (@odata.nextLink): " ~ nextLink, ["debug"]);
							nextLink = topLevelChildren["@odata.nextLink"].str;
						} else break;
						
						// Sleep for a while to avoid busy-waiting
						Thread.sleep(dur!"msecs"(100)); // Adjust the sleep duration as needed
					}
				}
			}
			
			// If we did not find the folder, we need to create this folder
			if (!directoryFoundOnline) {
				// Folder not found online
				// Set any response to be an invalid JSON item
				getPathDetailsAPIResponse = null;
				// Was there a POSIX issue?
				if (!posixIssue) {
					// No POSIX issue
					if (createPathIfMissing) {
						// Create this path as it is missing on OneDrive online and there is no POSIX issue with a 'case-insensitive match'
						addLogEntry("FOLDER NOT FOUND ONLINE AND WE ARE REQUESTED TO CREATE IT", ["debug"]);
						addLogEntry("Create folder on this drive:             " ~ parentDetails.driveId, ["debug"]);
						addLogEntry("Create folder as a child on this object: " ~ parentDetails.id, ["debug"]);
						addLogEntry("Create this folder name:                 " ~ thisFolderName, ["debug"]);
						
						// Generate the JSON needed to create the folder online
						JSONValue newDriveItem = [
								"name": JSONValue(thisFolderName),
								"folder": parseJSON("{}")
						];
					
						JSONValue createByIdAPIResponse;
						// Submit the creation request
						// Fix for https://github.com/skilion/onedrive/issues/356
						if (!dryRun) {
							try {
								// Attempt to create a new folder on the configured parent driveId & parent id
								createByIdAPIResponse = queryOneDriveForSpecificPath.createById(parentDetails.driveId, parentDetails.id, newDriveItem);
								// Is the response a valid JSON object - validation checking done in saveItem
								saveItem(createByIdAPIResponse);
								// Set getPathDetailsAPIResponse to createByIdAPIResponse
								getPathDetailsAPIResponse = createByIdAPIResponse;
							} catch (OneDriveException e) {
								// 409 - API Race Condition
								if (e.httpStatusCode == 409) {
									// When we attempted to create it, OneDrive responded that it now already exists
									addLogEntry("OneDrive reported that " ~ thisFolderName ~ " already exists .. OneDrive API race condition", ["verbose"]);
								} else {
									// some other error from OneDrive was returned - display what it is
									addLogEntry("OneDrive generated an error when creating this path: " ~ thisFolderName);
									displayOneDriveErrorMessage(e.msg, getFunctionName!({}));
								}
							}
						} else {
							// Simulate a successful 'directory create' & save it to the dryRun database copy
							// The simulated response has to pass 'makeItem' as part of saveItem
							auto fakeResponse = createFakeResponse(thisNewPathToSearch);
							// Save item to the database
							saveItem(fakeResponse);
						}
					}
				}
			}
		}
		
		// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
		queryOneDriveForSpecificPath.releaseCurlEngine();
		queryOneDriveForSpecificPath = null;
		// Perform Garbage Collection
		GC.collect();
		
		// Output our search results
		addLogEntry("queryOneDriveForSpecificPathAndCreateIfMissing.getPathDetailsAPIResponse = " ~ to!string(getPathDetailsAPIResponse), ["debug"]);
		return getPathDetailsAPIResponse;
	}
	
	// Delete an item by it's path
	// This function is only used in --monitor mode to remove a directory online
	void deleteByPath(string path) {
		
		// function variables
		Item dbItem;
		
		// Need to check all driveid's we know about, not just the defaultDriveId
		bool itemInDB = false;
		foreach (searchDriveId; onlineDriveDetails.keys) {
			if (itemDB.selectByPath(path, searchDriveId, dbItem)) {
				// item was found in the DB
				itemInDB = true;
				break;
			}
		}
		
		// Was the item found in the database?
		if (!itemInDB) {
			// path to delete is not in the local database ..
			// was this a --remove-directory attempt?
			if (!appConfig.getValueBool("monitor")) {
				// --remove-directory deletion attempt
				addLogEntry("The item to delete is not in the local database - unable to delete online");
				return;
			} else {
				// normal use .. --monitor being used
				throw new SyncException("The item to delete is not in the local database");
			}
		}
		
		// This needs to be enforced as we have to know the parent id of the object being deleted
		if (dbItem.parentId == null) {
			// the item is a remote folder, need to do the operation on the parent
			enforce(itemDB.selectByPathIncludingRemoteItems(path, appConfig.defaultDriveId, dbItem));
		}
		
		try {
			if (noRemoteDelete) {
				// do not process remote delete
				addLogEntry("Skipping remote delete as --upload-only & --no-remote-delete configured", ["verbose"]);
			} else {
				uploadDeletedItem(dbItem, path);
			}
		} catch (OneDriveException e) {
			if (e.httpStatusCode == 404) {
				addLogEntry(e.msg);
			} else {
				// display what the error is
				displayOneDriveErrorMessage(e.msg, getFunctionName!({}));
			}
		}
	}
	
	// Delete an item by it's path
	// Delete a directory on OneDrive without syncing. This function is only used with --remove-directory
	void deleteByPathNoSync(string path) {
	
		// Attempt to delete the requested path within OneDrive without performing a sync
		addLogEntry("Attempting to delete the requested path within Microsoft OneDrive");
		
		// function variables
		JSONValue getPathDetailsAPIResponse;
		OneDriveApi deleteByPathNoSyncAPIInstance;
		
		// test if the path we are going to exists on OneDrive
		try {
			// Create a new API Instance for this thread and initialise it
			deleteByPathNoSyncAPIInstance = new OneDriveApi(appConfig);
			deleteByPathNoSyncAPIInstance.initialise();
			getPathDetailsAPIResponse = deleteByPathNoSyncAPIInstance.getPathDetails(path);
			
			// If we get here, no error, the path to delete exists online

		} catch (OneDriveException exception) {
		
			// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
			deleteByPathNoSyncAPIInstance.releaseCurlEngine();
			deleteByPathNoSyncAPIInstance = null;
			// Perform Garbage Collection
			GC.collect();
		
			// Log that an error was generated
			addLogEntry("deleteByPathNoSyncAPIInstance.getPathDetails(path) generated a OneDriveException", ["debug"]);
			if (exception.httpStatusCode == 404) {
				// The directory was not found on OneDrive - no need to delete it
				addLogEntry("The requested directory to delete was not found on OneDrive - skipping removing the remote directory online as it does not exist");
				return;
			}
			
			// Default operation if not 408,429,503,504 errors
			// - 408,429,503,504 errors are handled as a retry within oneDriveApiInstance
			// Display what the error is
			displayOneDriveErrorMessage(exception.msg, getFunctionName!({}));
			return;	
		}
		
		// Make a DB item from the JSON data that was returned via the API call
		Item deletionItem = makeItem(getPathDetailsAPIResponse);
		
		// Is the item to remove the correct type
		if (deletionItem.type == ItemType.dir) {
			// Item is a directory to remove
			// Log that the path | item was found, is a directory
			addLogEntry("The requested directory to delete was found on OneDrive - attempting deletion");
			
			// Try the online deletion
			try {
				// Perform the delete via the default OneDrive API instance
				deleteByPathNoSyncAPIInstance.deleteById(deletionItem.driveId, deletionItem.id);
				// If we get here without error, directory was deleted
				addLogEntry("The requested directory to delete online has been deleted");
			} catch (OneDriveException exception) {
				// Display what the error is
				displayOneDriveErrorMessage(exception.msg, getFunctionName!({}));
			}
		} else {
			// --remove-directory is for removing directories
			// Log that the path | item was found, is a directory
			addLogEntry("The requested path to delete is not a directory - aborting deletion attempt");
		}
		
		// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
		deleteByPathNoSyncAPIInstance.releaseCurlEngine();
		deleteByPathNoSyncAPIInstance = null;
		// Perform Garbage Collection
		GC.collect();
	}
	
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_move
	// This function is only called in monitor mode when an move event is coming from
	// inotify and we try to move the item.
	void uploadMoveItem(string oldPath, string newPath) {
		// Log that we are doing a move
		addLogEntry("Moving " ~ oldPath ~ " to " ~ newPath);
		// Is this move unwanted?
		bool unwanted = false;
		// Item variables
		Item oldItem, newItem, parentItem;
		
		// This not a Client Side Filtering check, nor a Microsoft Check, but is a sanity check that the path provided is UTF encoded correctly
		// Check the std.encoding of the path against: Unicode 5.0, ASCII, ISO-8859-1, ISO-8859-2, WINDOWS-1250, WINDOWS-1251, WINDOWS-1252
		if (!unwanted) {
			if(!isValid(newPath)) {
				// Path is not valid according to https://dlang.org/phobos/std_encoding.html
				addLogEntry("Skipping item - invalid character encoding sequence: " ~ newPath, ["info", "notify"]);
				unwanted = true;
			}
		}
		
		// Check this path against the Client Side Filtering Rules
		// - check_nosync
		// - skip_dotfiles
		// - skip_symlinks
		// - skip_file
		// - skip_dir
		// - sync_list
		// - skip_size
		if (!unwanted) {
			unwanted = checkPathAgainstClientSideFiltering(newPath);
		}
		
		// Check this path against the Microsoft Naming Conventions & Restristions
		// - Check path against Microsoft OneDrive restriction and limitations about Windows naming for files and folders
		// - Check path for bad whitespace items
		// - Check path for HTML ASCII Codes
		// - Check path for ASCII Control Codes
		if (!unwanted) {
			unwanted = checkPathAgainstMicrosoftNamingRestrictions(newPath);
		}
		
		// 'newPath' has passed client side filtering validation
		if (!unwanted) {
		
			if (!itemDB.selectByPath(oldPath, appConfig.defaultDriveId, oldItem)) {
				// The old path|item is not synced with the database, upload as a new file
				addLogEntry("Moved local item was not in-sync with local database - uploading as new item");
				scanLocalFilesystemPathForNewData(newPath);
				return;
			}
		
			if (oldItem.parentId == null) {
				// the item is a remote folder, need to do the operation on the parent
				enforce(itemDB.selectByPathIncludingRemoteItems(oldPath, appConfig.defaultDriveId, oldItem));
			}
		
			if (itemDB.selectByPath(newPath, appConfig.defaultDriveId, newItem)) {
				// the destination has been overwritten
				addLogEntry("Moved local item overwrote an existing item - deleting old online item");
				uploadDeletedItem(newItem, newPath);
			}
			
			if (!itemDB.selectByPath(dirName(newPath), appConfig.defaultDriveId, parentItem)) {
				// the parent item is not in the database
				throw new SyncException("Can't move an item to an unsynced directory");
			}
		
			if (oldItem.driveId != parentItem.driveId) {
				// items cannot be moved between drives
				uploadDeletedItem(oldItem, oldPath);
				
				// what sort of move is this?
				if (isFile(newPath)) {
					// newPath is a file
					uploadNewFile(newPath);
				} else {
					// newPath is a directory
					scanLocalFilesystemPathForNewData(newPath);
				}
			} else {
				if (!exists(newPath)) {
					// is this --monitor use?
					if (appConfig.getValueBool("monitor")) {
						addLogEntry("uploadMoveItem target has disappeared: " ~ newPath, ["verbose"]);
						return;
					}
				}
			
				// Configure the modification JSON item
				SysTime mtime;
				if (appConfig.getValueBool("monitor")) {
					// Use the newPath modified timestamp
					mtime = timeLastModified(newPath).toUTC();
				} else {
					// Use the current system time
					mtime = Clock.currTime().toUTC();
				}
								
				JSONValue data = [
					"name": JSONValue(baseName(newPath)),
					"parentReference": JSONValue([
						"id": parentItem.id
					]),
					"fileSystemInfo": JSONValue([
						"lastModifiedDateTime": mtime.toISOExtString()
					])
				];
				
				// Perform the move operation on OneDrive
				bool isMoveSuccess = false;
				JSONValue response;
				string eTag = oldItem.eTag;
				
				// Create a new API Instance for this thread and initialise it
				OneDriveApi movePathOnlineApiInstance;
				movePathOnlineApiInstance = new OneDriveApi(appConfig);
				movePathOnlineApiInstance.initialise();
				
				// Try the online move
				for (int i = 0; i < 3; i++) {
					try {
						response = movePathOnlineApiInstance.updateById(oldItem.driveId, oldItem.id, data, eTag);
						isMoveSuccess = true;
						break;
					} catch (OneDriveException e) {
						// Handle a 412 - A precondition provided in the request (such as an if-match header) does not match the resource's current state.
						if (e.httpStatusCode == 412) {
							// OneDrive threw a 412 error, most likely: ETag does not match current item's value
							// Retry without eTag
							addLogEntry("File Move Failed - OneDrive eTag / cTag match issue", ["debug"]);
							addLogEntry("OneDrive returned a 'HTTP 412 - Precondition Failed' when attempting to move the file - gracefully handling error", ["verbose"]);
							eTag = null;
							// Retry to move the file but without the eTag, via the for() loop
						} else if (e.httpStatusCode == 409) {
							// Destination item already exists and is a conflict, delete existing item first
							addLogEntry("Moved local item will overwrite an existing online item - deleting old online item first");
							uploadDeletedItem(newItem, newPath);
						} else
							break;
					}
				} 
				
				// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
				movePathOnlineApiInstance.releaseCurlEngine();
				movePathOnlineApiInstance = null;
				// Perform Garbage Collection
				GC.collect();
				
				// save the move response from OneDrive in the database
				// Is the response a valid JSON object - validation checking done in saveItem
				saveItem(response);
			}
		} else {
			// Moved item is unwanted
			addLogEntry("Item has been moved to a location that is excluded from sync operations. Removing item from OneDrive");
			uploadDeletedItem(oldItem, oldPath);
		}
	}
	
	// Perform integrity validation of the file that was uploaded
	bool performUploadIntegrityValidationChecks(JSONValue uploadResponse, string localFilePath, ulong localFileSize) {
	
		bool integrityValid = false;
	
		if (!disableUploadValidation) {
			// Integrity validation has not been disabled (this is the default so we are always integrity checking our uploads)
			if (uploadResponse.type() == JSONType.object) {
				// Provided JSON is a valid JSON
				ulong uploadFileSize;
				string uploadFileHash;
				string localFileHash;
				// Regardless if valid JSON is responded with, 'size' and 'quickXorHash' must be present
				if (hasFileSize(uploadResponse) && hasQuickXorHash(uploadResponse)) {
					uploadFileSize = uploadResponse["size"].integer;
					uploadFileHash = uploadResponse["file"]["hashes"]["quickXorHash"].str;
					localFileHash = computeQuickXorHash(localFilePath);
				} else {
					addLogEntry("Online file validation unable to be performed: input JSON whilst valid did not contain data which could be validated");
					addLogEntry("WARNING: Skipping upload integrity check for: " ~ localFilePath);
					return integrityValid;
				}
				
				// compare values
				if ((localFileSize == uploadFileSize) && (localFileHash == uploadFileHash)) {
					// Uploaded file integrity intact
					addLogEntry("Uploaded local file matches reported online size and hash values", ["debug"]);
					integrityValid = true;
				} else {
					// Upload integrity failure .. what failed?
					// There are 2 scenarios where this happens:
					// 1. Failed Transfer
					// 2. Upload file is going to a SharePoint Site, where Microsoft enriches the file with additional metadata with no way to disable
					addLogEntry("WARNING: Online file integrity failure for: " ~ localFilePath, ["info", "notify"]);
					
					// What integrity failed - size?
					if (localFileSize != uploadFileSize) {
						addLogEntry("WARNING: Online file integrity failure - Size Mismatch", ["verbose"]);
					}
					
					// What integrity failed - hash?
					if (localFileHash != uploadFileHash) {
						addLogEntry("WARNING: Online file integrity failure - Hash Mismatch", ["verbose"]);
					}
					
					// What account type is this?
					if (appConfig.accountType != "personal") {
						// Not a personal account, thus the integrity failure is most likely due to SharePoint
						addLogEntry("CAUTION: When you upload files to Microsoft OneDrive that uses SharePoint as its backend, Microsoft OneDrive will alter your files post upload.", ["verbose"]);
						addLogEntry("CAUTION: This will lead to technical differences between the version stored online and your local original file, potentially causing issues with the accuracy or consistency of your data.", ["verbose"]);
						addLogEntry("CAUTION: Please read https://github.com/OneDrive/onedrive-api-docs/issues/935 for further details.", ["verbose"]);
					}
					// How can this be disabled?
					addLogEntry("To disable the integrity checking of uploaded files use --disable-upload-validation");
				}
			} else {
				addLogEntry("Online file validation unable to be performed: input JSON was invalid");
				addLogEntry("WARNING: Skipping upload integrity check for: " ~ localFilePath);
			}
		} else {
			// We are bypassing integrity checks due to --disable-upload-validation
			addLogEntry("Online file validation disabled due to --disable-upload-validation", ["debug"]);
			addLogEntry("WARNING: Skipping upload integrity check for: " ~ localFilePath, ["info", "notify"]);
		}
		
		// Is the file integrity online valid?
		return integrityValid;
	}
	
	// Query Office 365 SharePoint Shared Library site name to obtain it's Drive ID
	void querySiteCollectionForDriveID(string sharepointLibraryNameToQuery) {
		// Steps to get the ID:
		// 1. Query https://graph.microsoft.com/v1.0/sites?search= with the name entered
		// 2. Evaluate the response. A valid response will contain the description and the id. If the response comes back with nothing, the site name cannot be found or no access
		// 3. If valid, use the returned ID and query the site drives
		//		https://graph.microsoft.com/v1.0/sites/<site_id>/drives
		// 4. Display Shared Library Name & Drive ID
		
		string site_id;
		string drive_id;
		bool found = false;
		JSONValue siteQuery;
		string nextLink;
		string[] siteSearchResults;
		
		// Create a new API Instance for this thread and initialise it
		OneDriveApi querySharePointLibraryNameApiInstance;
		querySharePointLibraryNameApiInstance = new OneDriveApi(appConfig);
		querySharePointLibraryNameApiInstance.initialise();
		
		// The account type must not be a personal account type
		if (appConfig.accountType == "personal") {
			addLogEntry("ERROR: A OneDrive Personal Account cannot be used with --get-sharepoint-drive-id. Please re-authenticate your client using a OneDrive Business Account.");
			return;
		}
		
		// What query are we performing?
		addLogEntry();
		addLogEntry("Office 365 Library Name Query: " ~ sharepointLibraryNameToQuery);
		
		while (true) {
			// Check if exitHandlerTriggered is true
			if (exitHandlerTriggered) {
				// break out of the 'while (true)' loop
				break;
			}
		
			try {
				siteQuery = querySharePointLibraryNameApiInstance.o365SiteSearch(nextLink);
			} catch (OneDriveException e) {
				addLogEntry("ERROR: Query of OneDrive for Office 365 Library Name failed");
				// Forbidden - most likely authentication scope needs to be updated
				if (e.httpStatusCode == 403) {
					addLogEntry("ERROR: Authentication scope needs to be updated. Use --reauth and re-authenticate client.");
					
					// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
					querySharePointLibraryNameApiInstance.releaseCurlEngine();
					querySharePointLibraryNameApiInstance = null;
					// Perform Garbage Collection
					GC.collect();
					return;
				}
				
				// Requested resource cannot be found
				if (e.httpStatusCode == 404) {
					string siteSearchUrl;
					if (nextLink.empty) {
						siteSearchUrl = querySharePointLibraryNameApiInstance.getSiteSearchUrl();
					} else {
						siteSearchUrl = nextLink;
					}
					// log the error
					addLogEntry("ERROR: Your OneDrive Account and Authentication Scope cannot access this OneDrive API: " ~ siteSearchUrl);
					addLogEntry("ERROR: To resolve, please discuss this issue with whomever supports your OneDrive and SharePoint environment.");
					
					// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
					querySharePointLibraryNameApiInstance.releaseCurlEngine();
					querySharePointLibraryNameApiInstance = null;
					// Perform Garbage Collection
					GC.collect();
					return;
				}
				
				// Default operation if not 408,429,503,504 errors
				// - 408,429,503,504 errors are handled as a retry within oneDriveApiInstance
				// Display what the error is
				displayOneDriveErrorMessage(e.msg, getFunctionName!({}));
				
				// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
				querySharePointLibraryNameApiInstance.releaseCurlEngine();
				querySharePointLibraryNameApiInstance = null;
				// Perform Garbage Collection
				GC.collect();
				return;
			}
			
			// is siteQuery a valid JSON object & contain data we can use?
			if ((siteQuery.type() == JSONType.object) && ("value" in siteQuery)) {
				// valid JSON object
				addLogEntry("O365 Query Response: " ~ to!string(siteQuery), ["debug"]);
				
				foreach (searchResult; siteQuery["value"].array) {
					// Need an 'exclusive' match here with sharepointLibraryNameToQuery as entered
					addLogEntry("Found O365 Site: " ~ to!string(searchResult), ["debug"]);
					
					// 'displayName' and 'id' have to be present in the search result record in order to query the site
					if (("displayName" in searchResult) && ("id" in searchResult)) {
						if (sharepointLibraryNameToQuery == searchResult["displayName"].str){
							// 'displayName' matches search request
							site_id = searchResult["id"].str;
							JSONValue siteDriveQuery;
							string nextLinkDrive;

							while (true) {
								try {
									siteDriveQuery = querySharePointLibraryNameApiInstance.o365SiteDrives(site_id, nextLinkDrive);
								} catch (OneDriveException e) {
									addLogEntry("ERROR: Query of OneDrive for Office Site ID failed");
									// display what the error is
									displayOneDriveErrorMessage(e.msg, getFunctionName!({}));
									
									// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
									querySharePointLibraryNameApiInstance.releaseCurlEngine();
									querySharePointLibraryNameApiInstance = null;
									// Perform Garbage Collection
									GC.collect();
									return;
								}
								
								// is siteDriveQuery a valid JSON object & contain data we can use?
								if ((siteDriveQuery.type() == JSONType.object) && ("value" in siteDriveQuery)) {
									// valid JSON object
									foreach (driveResult; siteDriveQuery["value"].array) {
										// Display results
										found = true;
										addLogEntry("-----------------------------------------------");
										addLogEntry("Site Details: " ~ to!string(driveResult), ["debug"]);
										addLogEntry("Site Name:    " ~ searchResult["displayName"].str);
										addLogEntry("Library Name: " ~ driveResult["name"].str);
										addLogEntry("drive_id:     " ~ driveResult["id"].str);
										addLogEntry("Library URL:  " ~ driveResult["webUrl"].str);
									}
			
									// If a collection exceeds the default page size (200 items), the @odata.nextLink property is returned in the response 
									// to indicate more items are available and provide the request URL for the next page of items.
									if ("@odata.nextLink" in siteDriveQuery) {
										// Update nextLink to next set of SharePoint library names
										nextLinkDrive = siteDriveQuery["@odata.nextLink"].str;
										addLogEntry("Setting nextLinkDrive to (@odata.nextLink): " ~ nextLinkDrive, ["debug"]);

										// Sleep for a while to avoid busy-waiting
										Thread.sleep(dur!"msecs"(100)); // Adjust the sleep duration as needed
									} else {
										// closeout
										addLogEntry("-----------------------------------------------");
										break;
									}
								} else {
									// not a valid JSON object
									addLogEntry("ERROR: There was an error performing this operation on Microsoft OneDrive");
									addLogEntry("ERROR: Increase logging verbosity to assist determining why.");
									
									// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
									querySharePointLibraryNameApiInstance.releaseCurlEngine();
									querySharePointLibraryNameApiInstance = null;
									// Perform Garbage Collection
									GC.collect();
									return;
								}
							}
						}
					} else {
						// 'displayName', 'id' or ''webUrl' not present in JSON results for a specific site
						string siteNameAvailable = "Site 'name' was restricted by OneDrive API permissions";
						bool displayNameAvailable = false;
						bool idAvailable = false;
						if ("name" in searchResult) siteNameAvailable = searchResult["name"].str;
						if ("displayName" in searchResult) displayNameAvailable = true;
						if ("id" in searchResult) idAvailable = true;
						
						// Display error details for this site data
						addLogEntry();
						addLogEntry("ERROR: SharePoint Site details not provided for: " ~ siteNameAvailable);
						addLogEntry("ERROR: The SharePoint Site results returned from OneDrive API do not contain the required items to match. Please check your permissions with your site administrator.");
						addLogEntry("ERROR: Your site security settings is preventing the following details from being accessed: 'displayName' or 'id'");
						addLogEntry(" - Is 'displayName' available = " ~ to!string(displayNameAvailable), ["verbose"]);
						addLogEntry(" - Is 'id' available          = " ~ to!string(idAvailable), ["verbose"]);
						addLogEntry("ERROR: To debug this further, please increase verbosity (--verbose or --verbose --verbose) to provide further insight as to what details are actually being returned.");
					}
				}
				
				if(!found) {
					// The SharePoint site we are searching for was not found in this bundle set
					// Add to siteSearchResults so we can display what we did find
					string siteSearchResultsEntry;
					foreach (searchResult; siteQuery["value"].array) {
						// We can only add the displayName if it is available
						if ("displayName" in searchResult) {
							// Use the displayName
							siteSearchResultsEntry = " * " ~ searchResult["displayName"].str;
							siteSearchResults ~= siteSearchResultsEntry;
						} else {
							// Add, but indicate displayName unavailable, use id
							if ("id" in searchResult) {
								siteSearchResultsEntry = " * " ~ "Unknown displayName (Data not provided by API), Site ID: " ~ searchResult["id"].str;
								siteSearchResults ~= siteSearchResultsEntry;
							} else {
								// displayName and id unavailable, display in debug log the entry
								addLogEntry("Bad SharePoint Data for site: " ~ to!string(searchResult), ["debug"]);
							}
						}
					}
				}
			} else {
				// not a valid JSON object
				addLogEntry("ERROR: There was an error performing this operation on Microsoft OneDrive");
				addLogEntry("ERROR: Increase logging verbosity to assist determining why.");
				
				// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
				querySharePointLibraryNameApiInstance.releaseCurlEngine();
				querySharePointLibraryNameApiInstance = null;
				// Perform Garbage Collection
				GC.collect();
				return;
			}
			
			// If a collection exceeds the default page size (200 items), the @odata.nextLink property is returned in the response 
			// to indicate more items are available and provide the request URL for the next page of items.
			if ("@odata.nextLink" in siteQuery) {
				// Update nextLink to next set of SharePoint library names
				nextLink = siteQuery["@odata.nextLink"].str;
				addLogEntry("Setting nextLink to (@odata.nextLink): " ~ nextLink, ["debug"]);
			} else break;
			
			// Sleep for a while to avoid busy-waiting
			Thread.sleep(dur!"msecs"(100)); // Adjust the sleep duration as needed
		}
		
		// Was the intended target found?
		if(!found) {
			// Was the search a wildcard?
			if (sharepointLibraryNameToQuery != "*") {
				// Only print this out if the search was not a wildcard
				addLogEntry();
				addLogEntry("ERROR: The requested SharePoint site could not be found. Please check it's name and your permissions to access the site.");
			}
			// List all sites returned to assist user
			addLogEntry();
			addLogEntry("The following SharePoint site names were returned:");
			foreach (searchResultEntry; siteSearchResults) {
				// list the display name that we use to match against the user query
				addLogEntry(searchResultEntry);
			}
		}
		
		// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
		querySharePointLibraryNameApiInstance.releaseCurlEngine();
		querySharePointLibraryNameApiInstance = null;
		// Perform Garbage Collection
		GC.collect();
	}
	
	// Query the sync status of the client and the local system
	void queryOneDriveForSyncStatus(string pathToQueryStatusOn) {
	
		// Query the account driveId and rootId to get the /delta JSON information
		// Process that JSON data for relevancy
		
		// Function variables
		ulong downloadSize = 0;
		string deltaLink = null;
		string driveIdToQuery = appConfig.defaultDriveId;
		string itemIdToQuery = appConfig.defaultRootId;
		JSONValue deltaChanges;
		
		// Array of JSON items
		JSONValue[] jsonItemsArray;
		
		// Query Database for a potential deltaLink starting point
		deltaLink = itemDB.getDeltaLink(driveIdToQuery, itemIdToQuery);
		
		// Log what we are doing
		addProcessingLogHeaderEntry("Querying the change status of Drive ID: " ~ driveIdToQuery, appConfig.verbosityCount);
		
		// Create a new API Instance for querying the actual /delta and initialise it
		OneDriveApi getDeltaDataOneDriveApiInstance;
		getDeltaDataOneDriveApiInstance = new OneDriveApi(appConfig);
		getDeltaDataOneDriveApiInstance.initialise();
		
		while (true) {
			// Check if exitHandlerTriggered is true
			if (exitHandlerTriggered) {
				// break out of the 'while (true)' loop
				break;
			}
			
			// Add a processing '.'
			if (appConfig.verbosityCount == 0) {
				addProcessingDotEntry();
			}
		
			// Get the /delta changes via the OneDrive API
			// getDeltaChangesByItemId has the re-try logic for transient errors
			deltaChanges = getDeltaChangesByItemId(driveIdToQuery, itemIdToQuery, deltaLink, getDeltaDataOneDriveApiInstance);
			
			// If the initial deltaChanges response is an invalid JSON object, keep trying until we get a valid response ..
			if (deltaChanges.type() != JSONType.object) {
				// While the response is not a JSON Object or the Exit Handler has not been triggered
				while (deltaChanges.type() != JSONType.object) {
					// Handle the invalid JSON response and retry
					addLogEntry("ERROR: Query of the OneDrive API via deltaChanges = getDeltaChangesByItemId() returned an invalid JSON response", ["debug"]);
					deltaChanges = getDeltaChangesByItemId(driveIdToQuery, itemIdToQuery, deltaLink, getDeltaDataOneDriveApiInstance);
				}
			}
			
			// We have a valid deltaChanges JSON array. This means we have at least 200+ JSON items to process.
			// The API response however cannot be run in parallel as the OneDrive API sends the JSON items in the order in which they must be processed
			foreach (onedriveJSONItem; deltaChanges["value"].array) {
				// is the JSON a root object - we dont want to count this
				if (!isItemRoot(onedriveJSONItem)) {
					// Files are the only item that we want to calculate
					if (isItemFile(onedriveJSONItem)) {
						// JSON item is a file
						// Is the item filtered out due to client side filtering rules?
						if (!checkJSONAgainstClientSideFiltering(onedriveJSONItem)) {
							// Is the path of this JSON item 'in-scope' or 'out-of-scope' ?
							if (pathToQueryStatusOn != "/") {
								// We need to check the path of this item against pathToQueryStatusOn
								string thisItemPath = "";
								if (("path" in onedriveJSONItem["parentReference"]) != null) {
									// If there is a parent reference path, try and use it
									string selfBuiltPath = onedriveJSONItem["parentReference"]["path"].str ~ "/" ~ onedriveJSONItem["name"].str;
									
									// Check for ':' and split if present
									auto splitIndex = selfBuiltPath.indexOf(":");
									if (splitIndex != -1) {
										// Keep only the part after ':'
										selfBuiltPath = selfBuiltPath[splitIndex + 1 .. $];
									}
									
									// Set thisItemPath to the self built path
									thisItemPath = selfBuiltPath;
								} else {
									// no parent reference path available
									thisItemPath = onedriveJSONItem["name"].str;
								}
								// can we find 'pathToQueryStatusOn' in 'thisItemPath' ?
								if (canFind(thisItemPath, pathToQueryStatusOn)) {
									// Add this to the array for processing
									jsonItemsArray ~= onedriveJSONItem;
								}
							} else {
								// We are not doing a --single-directory check
								// Add this to the array for processing
								jsonItemsArray ~= onedriveJSONItem;
							}
						}
					}
				}
			}
			
			// The response may contain either @odata.deltaLink or @odata.nextLink
			if ("@odata.deltaLink" in deltaChanges) {
				deltaLink = deltaChanges["@odata.deltaLink"].str;
				addLogEntry("Setting next deltaLink to (@odata.deltaLink): " ~ deltaLink, ["debug"]);
			}
			
			// Update deltaLink to next changeSet bundle
			if ("@odata.nextLink" in deltaChanges) {	
				deltaLink = deltaChanges["@odata.nextLink"].str;
				addLogEntry("Setting next deltaLink to (@odata.nextLink): " ~ deltaLink, ["debug"]);
			} else break;
			
			// Sleep for a while to avoid busy-waiting
			Thread.sleep(dur!"msecs"(100)); // Adjust the sleep duration as needed
		}
		
		// Terminate getDeltaDataOneDriveApiInstance here
		getDeltaDataOneDriveApiInstance.releaseCurlEngine();
		getDeltaDataOneDriveApiInstance = null;
		// Perform Garbage Collection on this destroyed curl engine
		GC.collect();
		
		// Needed after printing out '....' when fetching changes from OneDrive API
		if (appConfig.verbosityCount == 0) {
			completeProcessingDots();
		}
		
		// Are there any JSON items to process?
		if (count(jsonItemsArray) != 0) {
			// There are items to process
			foreach (onedriveJSONItem; jsonItemsArray.array) {
			
				// variables we need
				string thisItemParentDriveId;
				string thisItemId;
				string thisItemHash;
				bool existingDBEntry = false;
				
				// Is this file a remote item (on a shared folder) ?
				if (isItemRemote(onedriveJSONItem)) {
					// remote drive item
					thisItemParentDriveId = onedriveJSONItem["remoteItem"]["parentReference"]["driveId"].str;
					thisItemId = onedriveJSONItem["id"].str;
				} else {
					// standard drive item
					thisItemParentDriveId = onedriveJSONItem["parentReference"]["driveId"].str;
					thisItemId = onedriveJSONItem["id"].str;
				}
				
				// Get the file hash
				if (hasHashes(onedriveJSONItem)) {
					// At a minimum we require 'quickXorHash' to exist
					if (hasQuickXorHash(onedriveJSONItem)) {
						// JSON itme has a hash we can use
						thisItemHash = onedriveJSONItem["file"]["hashes"]["quickXorHash"].str;
					}
					
					// Check if the item has been seen before
					Item existingDatabaseItem;
					existingDBEntry = itemDB.selectById(thisItemParentDriveId, thisItemId, existingDatabaseItem);
					
					if (existingDBEntry) {
						// item exists in database .. do the database details match the JSON record?
						if (existingDatabaseItem.quickXorHash != thisItemHash) {
							// file hash is different, this will trigger a download event
							if (hasFileSize(onedriveJSONItem)) {
								downloadSize = downloadSize + onedriveJSONItem["size"].integer;
							}
						} 
					} else {
						// item does not exist in the database
						// this item has already passed client side filtering rules (skip_dir, skip_file, sync_list)
						// this will trigger a download event
						if (hasFileSize(onedriveJSONItem)) {
							downloadSize = downloadSize + onedriveJSONItem["size"].integer;
						}
					}
				}
			}
		}
			
		// Was anything detected that would constitute a download?
		if (downloadSize > 0) {
			// we have something to download
			if (pathToQueryStatusOn != "/") {
				addLogEntry("The selected local directory via --single-directory is out of sync with Microsoft OneDrive");
			} else {
				addLogEntry("The configured local 'sync_dir' directory is out of sync with Microsoft OneDrive");
			}
			addLogEntry("Approximate data to download from Microsoft OneDrive: " ~ to!string(downloadSize/1024) ~ " KB");
		} else {
			// No changes were returned
			addLogEntry("There are no pending changes from Microsoft OneDrive; your local directory matches the data online.");
		}
	}
	
	// Query OneDrive for file details of a given path, returning either the 'webURL' or 'lastModifiedBy' JSON facet
	void queryOneDriveForFileDetails(string inputFilePath, string runtimePath, string outputType) {
	
		OneDriveApi queryOneDriveForFileDetailsApiInstance;
		
		// Calculate the full local file path
		string fullLocalFilePath = buildNormalizedPath(buildPath(runtimePath, inputFilePath));
		
		// Query if file is valid locally
		if (exists(fullLocalFilePath)) {
			// search drive_id list
			string[] distinctDriveIds = itemDB.selectDistinctDriveIds();
			bool pathInDB = false;
			Item dbItem;
			
			foreach (searchDriveId; distinctDriveIds) {
				// Does this path exist in the database, use the 'inputFilePath'
				if (itemDB.selectByPath(inputFilePath, searchDriveId, dbItem)) {
					// item is in the database
					pathInDB = true;
					JSONValue fileDetailsFromOneDrive;
				
					// Create a new API Instance for this thread and initialise it
					queryOneDriveForFileDetailsApiInstance = new OneDriveApi(appConfig);
					queryOneDriveForFileDetailsApiInstance.initialise();
					
					try {
						fileDetailsFromOneDrive = queryOneDriveForFileDetailsApiInstance.getPathDetailsById(dbItem.driveId, dbItem.id);
						// Dont cleanup here as if we are creating a shareable file link (below) it is still needed
						
					} catch (OneDriveException exception) {
						// display what the error is
						displayOneDriveErrorMessage(exception.msg, getFunctionName!({}));
						
						// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
						queryOneDriveForFileDetailsApiInstance.releaseCurlEngine();
						queryOneDriveForFileDetailsApiInstance = null;
						// Perform Garbage Collection
						GC.collect();
						return;
					}
					
					// Is the API response a valid JSON file?
					if (fileDetailsFromOneDrive.type() == JSONType.object) {
					
						// debug output of response
						addLogEntry("API Response: " ~ to!string(fileDetailsFromOneDrive), ["debug"]);
						
						// What sort of response to we generate
						// --get-file-link response
						if (outputType == "URL") {
							if ((fileDetailsFromOneDrive.type() == JSONType.object) && ("webUrl" in fileDetailsFromOneDrive)) {
								// Valid JSON object
								addLogEntry();
								writeln("WebURL: ", fileDetailsFromOneDrive["webUrl"].str);
							}
						}
						
						// --modified-by response
						if (outputType == "ModifiedBy") {
							if ((fileDetailsFromOneDrive.type() == JSONType.object) && ("lastModifiedBy" in fileDetailsFromOneDrive)) {
								// Valid JSON object
								writeln();
								writeln("Last modified:    ", fileDetailsFromOneDrive["lastModifiedDateTime"].str);
								writeln("Last modified by: ", fileDetailsFromOneDrive["lastModifiedBy"]["user"]["displayName"].str);
								// if 'email' provided, add this to the output
								if ("email" in fileDetailsFromOneDrive["lastModifiedBy"]["user"]) {
									writeln("Email Address:    ", fileDetailsFromOneDrive["lastModifiedBy"]["user"]["email"].str);
								}
							}
						}
						
						// --create-share-link response
						if (outputType == "ShareableLink") {
						
							JSONValue accessScope;
							JSONValue createShareableLinkResponse;
							string thisDriveId = fileDetailsFromOneDrive["parentReference"]["driveId"].str;
							string thisItemId = fileDetailsFromOneDrive["id"].str;
							string fileShareLink;
							bool writeablePermissions = appConfig.getValueBool("with_editing_perms");
							
							// What sort of shareable link is required?
							if (writeablePermissions) {
								// configure the read-write access scope
								accessScope = [
									"type": "edit",
									"scope": "anonymous"
								];
							} else {
								// configure the read-only access scope (default)
								accessScope = [
									"type": "view",
									"scope": "anonymous"
								];
							}
							
							// Try and create the shareable file link
							try {
								createShareableLinkResponse = queryOneDriveForFileDetailsApiInstance.createShareableLink(thisDriveId, thisItemId, accessScope);
							} catch (OneDriveException exception) {
								// display what the error is
								displayOneDriveErrorMessage(exception.msg, getFunctionName!({}));
								return;
							}
							
							// Is the API response a valid JSON file?
							if ((createShareableLinkResponse.type() == JSONType.object) && ("link" in createShareableLinkResponse)) {
								// Extract the file share link from the JSON response
								fileShareLink = createShareableLinkResponse["link"]["webUrl"].str;
								writeln("File Shareable Link: ", fileShareLink);
								if (writeablePermissions) {
									writeln("Shareable Link has read-write permissions - use and provide with caution"); 
								}
							}
						}
					}
					
					// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
					queryOneDriveForFileDetailsApiInstance.releaseCurlEngine();
					queryOneDriveForFileDetailsApiInstance = null;
					// Perform Garbage Collection
					GC.collect();
				}
			}
			
			// was path found?
			if (!pathInDB) {
				// File has not been synced with OneDrive
				addLogEntry("Selected path has not been synced with Microsoft OneDrive: " ~ inputFilePath);
			}
		} else {
			// File does not exist locally
			addLogEntry("Selected path not found on local system: " ~ inputFilePath);
		}
	}
	
	// Query OneDrive for the quota details
	void queryOneDriveForQuotaDetails() {
		// This function is similar to getRemainingFreeSpace() but is different in data being analysed and output method
		JSONValue currentDriveQuota;
		string driveId;
		OneDriveApi getCurrentDriveQuotaApiInstance;

		if (appConfig.getValueString("drive_id").length) {
			driveId = appConfig.getValueString("drive_id");
		} else {
			driveId = appConfig.defaultDriveId;
		}
		
		try {
			// Create a new OneDrive API instance
			getCurrentDriveQuotaApiInstance = new OneDriveApi(appConfig);
			getCurrentDriveQuotaApiInstance.initialise();
			addLogEntry("Seeking available quota for this drive id: " ~ driveId, ["debug"]);
			currentDriveQuota = getCurrentDriveQuotaApiInstance.getDriveQuota(driveId);
			
			// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
			getCurrentDriveQuotaApiInstance.releaseCurlEngine();
			getCurrentDriveQuotaApiInstance = null;
			// Perform Garbage Collection
			GC.collect();
			
		} catch (OneDriveException e) {
			addLogEntry("currentDriveQuota = onedrive.getDriveQuota(driveId) generated a OneDriveException", ["debug"]);
			// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
			getCurrentDriveQuotaApiInstance.releaseCurlEngine();
			getCurrentDriveQuotaApiInstance = null;
			// Perform Garbage Collection
			GC.collect();
		}
		
		// validate that currentDriveQuota is a JSON value
		if (currentDriveQuota.type() == JSONType.object) {
			// was 'quota' in response?
			if ("quota" in currentDriveQuota) {
		
				// debug output of response
				addLogEntry("currentDriveQuota: " ~ to!string(currentDriveQuota), ["debug"]);
				
				// human readable output of response
				string deletedValue = "Not Provided";
				string remainingValue = "Not Provided";
				string stateValue = "Not Provided";
				string totalValue = "Not Provided";
				string usedValue = "Not Provided";
			
				// Update values
				if ("deleted" in currentDriveQuota["quota"]) {
					deletedValue = byteToGibiByte(currentDriveQuota["quota"]["deleted"].integer);
				}
				
				if ("remaining" in currentDriveQuota["quota"]) {
					remainingValue = byteToGibiByte(currentDriveQuota["quota"]["remaining"].integer);
				}
				
				if ("state" in currentDriveQuota["quota"]) {
					stateValue = currentDriveQuota["quota"]["state"].str;
				}
				
				if ("total" in currentDriveQuota["quota"]) {
					totalValue = byteToGibiByte(currentDriveQuota["quota"]["total"].integer);
				}
				
				if ("used" in currentDriveQuota["quota"]) {
					usedValue = byteToGibiByte(currentDriveQuota["quota"]["used"].integer);
				}
				
				writeln("Microsoft OneDrive quota information as reported for this Drive ID: ", driveId);
				writeln();
				writeln("Deleted:   ", deletedValue, " GB (", currentDriveQuota["quota"]["deleted"].integer, " bytes)");
				writeln("Remaining: ", remainingValue, " GB (", currentDriveQuota["quota"]["remaining"].integer, " bytes)");
				writeln("State:     ", stateValue);
				writeln("Total:     ", totalValue, " GB (", currentDriveQuota["quota"]["total"].integer, " bytes)");
				writeln("Used:      ", usedValue, " GB (", currentDriveQuota["quota"]["used"].integer, " bytes)");
				writeln();
			} else {
				writeln("Microsoft OneDrive quota information is being restricted for this Drive ID: ", driveId);
			}
		} 
	}
	
	// Query the system for session_upload.* files
	bool checkForInterruptedSessionUploads() {
	
		bool interruptedUploads = false;
		ulong interruptedUploadsCount;
		
		// Scan the filesystem for the files we are interested in, build up interruptedUploadsSessionFiles array
		foreach (sessionFile; dirEntries(appConfig.configDirName, "session_upload.*", SpanMode.shallow)) {
			// calculate the full path
			string tempPath = buildNormalizedPath(buildPath(appConfig.configDirName, sessionFile));
			// add to array
			interruptedUploadsSessionFiles ~= [tempPath];
		}
		
		// Count all 'session_upload' files in appConfig.configDirName
		//interruptedUploadsCount = count(dirEntries(appConfig.configDirName, "session_upload.*", SpanMode.shallow));
		interruptedUploadsCount = count(interruptedUploadsSessionFiles);
		if (interruptedUploadsCount != 0) {
			interruptedUploads = true;
		}
		
		// return if there are interrupted uploads to process
		return interruptedUploads;
	}
	
	// Clear any session_upload.* files
	void clearInterruptedSessionUploads() {
		// Scan the filesystem for the files we are interested in, build up interruptedUploadsSessionFiles array
		foreach (sessionFile; dirEntries(appConfig.configDirName, "session_upload.*", SpanMode.shallow)) {
			// calculate the full path
			string tempPath = buildNormalizedPath(buildPath(appConfig.configDirName, sessionFile));
			JSONValue sessionFileData = readText(tempPath).parseJSON();
			addLogEntry("Removing interrupted session upload file due to --resync for: " ~ sessionFileData["localPath"].str, ["info"]);
			
			// Process removal
			if (!dryRun) {
				safeRemove(tempPath);
			}
		}
	}
	
	// Process interrupted 'session_upload' files
	void processForInterruptedSessionUploads() {
		// For each upload_session file that has been found, process the data to ensure it is still valid
		foreach (sessionFilePath; interruptedUploadsSessionFiles) {
			if (!validateUploadSessionFileData(sessionFilePath)) {
				// Remove upload_session file as it is invalid
				// upload_session file file contains an error - cant resume this session
				addLogEntry("Restore file upload session failed - cleaning up resumable session data file: " ~ sessionFilePath, ["verbose"]);
				
				// cleanup session path
				if (exists(sessionFilePath)) {
					if (!dryRun) {
						remove(sessionFilePath);
					}
				}
			}
		}
		
		// At this point we should have an array of JSON items to resume uploading
		if (count(jsonItemsToResumeUpload) > 0) {
			// there are valid items to resume upload
			// Lets deal with all the JSON items that need to be reumed for upload in a batch process
			size_t batchSize = to!int(appConfig.getValueLong("threads"));
			ulong batchCount = (jsonItemsToResumeUpload.length + batchSize - 1) / batchSize;
			ulong batchesProcessed = 0;
			
			foreach (chunk; jsonItemsToResumeUpload.chunks(batchSize)) {
				// send an array containing 'appConfig.getValueLong("threads")' JSON items to resume upload
				resumeSessionUploadsInParallel(chunk);
			}
		}
	}
	
	// A resume session upload file need to be valid to be used
	// This function validates this data
	bool validateUploadSessionFileData(string sessionFilePath) {
		
		JSONValue sessionFileData;
		OneDriveApi validateUploadSessionFileDataApiInstance;

		// Try and read the text from the session file as a JSON array
		try {
			sessionFileData = readText(sessionFilePath).parseJSON();
		} catch (JSONException e) {
			addLogEntry("SESSION-RESUME: Invalid JSON data in: " ~ sessionFilePath, ["debug"]);
			return false;
		}
		
		// Does the file we wish to resume uploading exist locally still?
		if ("localPath" in sessionFileData) {
			string sessionLocalFilePath = sessionFileData["localPath"].str;
			addLogEntry("SESSION-RESUME: sessionLocalFilePath: " ~ sessionLocalFilePath, ["debug"]);
			
			// Does the file exist?
			if (!exists(sessionLocalFilePath)) {
				addLogEntry("The local file to upload does not exist locally anymore", ["verbose"]);
				return false;
			}
			
			// Can we read the file?
			if (!readLocalFile(sessionLocalFilePath)) {
				// filesystem error already returned if unable to read
				return false;
			}
			
		} else {
			addLogEntry("SESSION-RESUME: No localPath data in: " ~ sessionFilePath, ["debug"]);
			return false;
		}
		
		// Check the session data for expirationDateTime
		if ("expirationDateTime" in sessionFileData) {
			auto expiration = SysTime.fromISOExtString(sessionFileData["expirationDateTime"].str);
			if (expiration < Clock.currTime()) {
				addLogEntry("The upload session has expired for: " ~ sessionFilePath, ["verbose"]);
				return false;
			}
		} else {
			addLogEntry("SESSION-RESUME: No expirationDateTime data in: " ~ sessionFilePath, ["debug"]);
			return false;
		}
		
		// Check the online upload status, using the uloadURL in sessionFileData
		if ("uploadUrl" in sessionFileData) {
			JSONValue response;
			
			try {
				// Create a new OneDrive API instance
				validateUploadSessionFileDataApiInstance = new OneDriveApi(appConfig);
				validateUploadSessionFileDataApiInstance.initialise();
				
				// Request upload status
				response = validateUploadSessionFileDataApiInstance.requestUploadStatus(sessionFileData["uploadUrl"].str);
				
				// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
				validateUploadSessionFileDataApiInstance.releaseCurlEngine();
				validateUploadSessionFileDataApiInstance = null;
				// Perform Garbage Collection
				GC.collect();
				
			} catch (OneDriveException e) {
				// handle any onedrive error response as invalid
				addLogEntry("SESSION-RESUME: Invalid response when using uploadUrl in: " ~ sessionFilePath, ["debug"]);
				
				// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
				validateUploadSessionFileDataApiInstance.releaseCurlEngine();
				validateUploadSessionFileDataApiInstance = null;
				// Perform Garbage Collection
				GC.collect();
				return false;
			}
			
			// Do we have a valid response from OneDrive?
			if (response.type() == JSONType.object) {
				// Valid JSON object was returned
				if (("expirationDateTime" in response) && ("nextExpectedRanges" in response)) {
					// The 'uploadUrl' is valid, and the response contains elements we need
					sessionFileData["expirationDateTime"] = response["expirationDateTime"];
					sessionFileData["nextExpectedRanges"] = response["nextExpectedRanges"];
					
					if (sessionFileData["nextExpectedRanges"].array.length == 0) {
						addLogEntry("The upload session was already completed", ["verbose"]);
						return false;
					}
				} else {
					addLogEntry("SESSION-RESUME: No expirationDateTime & nextExpectedRanges data in Microsoft OneDrive API response: " ~ to!string(response), ["debug"]);
					return false;
				}
			} else {
				// not a JSON object
				addLogEntry("Restore file upload session failed - invalid response from Microsoft OneDrive", ["verbose"]);
				return false;
			}
		} else {
			addLogEntry("SESSION-RESUME: No uploadUrl data in: " ~ sessionFilePath, ["debug"]);
			return false;
		}
		
		// Add 'sessionFilePath' to 'sessionFileData' so that it can be used when we reuse the JSON data to resume the upload
		sessionFileData["sessionFilePath"] = sessionFilePath;
		
		// Add sessionFileData to jsonItemsToResumeUpload as it is now valid
		jsonItemsToResumeUpload ~= sessionFileData;
		return true;
	}
	
	// Resume all resumable session uploads in parallel
	void resumeSessionUploadsInParallel(JSONValue[] array) {
		// This function received an array of JSON items to resume upload, the number of elements based on appConfig.getValueLong("threads")
		foreach (i, jsonItemToResume; processPool.parallel(array)) {
			// Take each JSON item and resume upload using the JSON data
			JSONValue uploadResponse;
			OneDriveApi uploadFileOneDriveApiInstance;
			
			// Create a new API instance
			uploadFileOneDriveApiInstance = new OneDriveApi(appConfig);
			uploadFileOneDriveApiInstance.initialise();
			
			// Pull out data from this JSON element
			string threadUploadSessionFilePath = jsonItemToResume["sessionFilePath"].str;
			ulong thisFileSizeLocal = getSize(jsonItemToResume["localPath"].str);
			
			// Try to resume the session upload using the provided data
			try {
				uploadResponse = performSessionFileUpload(uploadFileOneDriveApiInstance, thisFileSizeLocal, jsonItemToResume, threadUploadSessionFilePath);
			} catch (OneDriveException exception) {
				writeln("CODING TO DO: Handle an exception when performing a resume session upload");	
			}
			
			// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
			uploadFileOneDriveApiInstance.releaseCurlEngine();
			uploadFileOneDriveApiInstance = null;
			// Perform Garbage Collection
			GC.collect();
						
			// Was the response from the OneDrive API a valid JSON item?
			if (uploadResponse.type() == JSONType.object) {
				// A valid JSON object was returned - session resumption upload successful
				
				// Are we in an --upload-only & --remove-source-files scenario?
				// Use actual config values as we are doing an upload session recovery
				if (localDeleteAfterUpload) {
					// Log that we are deleting a local item
					addLogEntry("Removing local file as --upload-only & --remove-source-files configured");
					// are we in a --dry-run scenario?
					if (!dryRun) {
						// No --dry-run ... process local file delete
						// Only perform the delete if we have a valid file path
						if (exists(jsonItemToResume["localPath"].str)) {
							// file exists
							addLogEntry("Removing local file: " ~ jsonItemToResume["localPath"].str, ["debug"]);
							safeRemove(jsonItemToResume["localPath"].str);
						}
					}
					// as file is removed, we have nothing to add to the local database
					addLogEntry("Skipping adding to database as --upload-only & --remove-source-files configured", ["debug"]);
				} else {
					// Save JSON item in database
					saveItem(uploadResponse);
				}
			} else {
				// No valid response was returned
				addLogEntry("CODING TO DO: what to do when session upload resumption JSON data is not valid ... nothing ? error message ?");
			}
		}
	}
	
	// Function to process the path by removing prefix up to ':' - remove '/drive/root:' from a path string
	string processPathToRemoveRootReference(ref string pathToCheck) {
		size_t colonIndex = pathToCheck.indexOf(":");
		if (colonIndex != -1) {
			addLogEntry("Updating " ~ pathToCheck ~ " to remove prefix up to ':'", ["debug"]);
			pathToCheck = pathToCheck[colonIndex + 1 .. $];
			addLogEntry("Updated path for 'skip_dir' check: " ~ pathToCheck, ["debug"]);
		}
		return pathToCheck;
	}
	
	// Function to find a given DriveId in the onlineDriveDetails associative array that maps driveId to DriveDetailsCache
	// If 'true' will return 'driveDetails' containing the struct data 'DriveDetailsCache'
	bool canFindDriveId(string driveId, out DriveDetailsCache driveDetails) {
		auto ptr = driveId in onlineDriveDetails;
		if (ptr !is null) {
			driveDetails = *ptr; // Dereference the pointer to get the value
			return true;
		} else {
			return false;
		}
	}
	
	// Add this driveId plus relevant details for future reference and use
	void addOrUpdateOneDriveOnlineDetails(string driveId) {
	
		bool quotaRestricted;
		bool quotaAvailable;
		ulong quotaRemaining;
		
		// Get the data from online
		auto onlineDriveData = getRemainingFreeSpaceOnline(driveId);
		quotaRestricted = to!bool(onlineDriveData[0][0]);
		quotaAvailable = to!bool(onlineDriveData[0][1]);
		quotaRemaining = to!long(onlineDriveData[0][2]);
		onlineDriveDetails[driveId] = DriveDetailsCache(driveId, quotaRestricted, quotaAvailable, quotaRemaining);
		
		// Debug log what the cached array now contains
		addLogEntry("onlineDriveDetails: " ~ to!string(onlineDriveDetails), ["debug"]);
	}

	// Return a specific 'driveId' details from 'onlineDriveDetails'
	DriveDetailsCache getDriveDetails(string driveId) {
		auto ptr = driveId in onlineDriveDetails;
		if (ptr !is null) {
			return *ptr;  // Dereference the pointer to get the value
		} else {
			// Return a default DriveDetailsCache or handle the case where the driveId is not found
			return DriveDetailsCache.init; // Return default-initialised struct
		}
	}
	
	// Search a given Drive ID, Item ID and filename to see if this exists in the location specified
	JSONValue searchDriveItemForFile(string parentItemDriveId, string parentItemId, string fileToUpload) {
	
		JSONValue onedriveJSONItem;
		string searchName = baseName(fileToUpload);
		JSONValue thisLevelChildren;
		string nextLink;
		
		// Create a new API Instance for this thread and initialise it
		OneDriveApi checkFileOneDriveApiInstance;
		checkFileOneDriveApiInstance = new OneDriveApi(appConfig);
		checkFileOneDriveApiInstance.initialise();
		
		while (true) {
			// Check if exitHandlerTriggered is true
			if (exitHandlerTriggered) {
				// break out of the 'while (true)' loop
				break;
			}
		
			// query top level children
			try {
				thisLevelChildren = checkFileOneDriveApiInstance.listChildren(parentItemDriveId, parentItemId, nextLink);
			} catch (OneDriveException exception) {
				// OneDrive threw an error
				addLogEntry("------------------------------------------------------------------", ["debug"]);
				addLogEntry("Query Error: thisLevelChildren = checkFileOneDriveApiInstance.listChildren(parentItemDriveId, parentItemId, nextLink)", ["debug"]);
				addLogEntry("driveId:   " ~ parentItemDriveId, ["debug"]);
				addLogEntry("idToQuery: " ~ parentItemId, ["debug"]);
				addLogEntry("nextLink:  " ~ nextLink, ["debug"]);
				
				string thisFunctionName = getFunctionName!({});
				// Default operation if not 408,429,503,504 errors
				// - 408,429,503,504 errors are handled as a retry within oneDriveApiInstance
				// Display what the error is
				displayOneDriveErrorMessage(exception.msg, thisFunctionName);
			}
			
			// process thisLevelChildren response
			foreach (child; thisLevelChildren["value"].array) {
                // Only looking at files
				if ((child["name"].str == searchName) && (("file" in child) != null)) {
					// Found the matching file, return its JSON representation
					// Operations in this thread are done / complete
					
					// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
					checkFileOneDriveApiInstance.releaseCurlEngine();
					checkFileOneDriveApiInstance = null;
					// Perform Garbage Collection
					GC.collect();
					
					// Return child
                    return child;
                }
            }
			
			// If a collection exceeds the default page size (200 items), the @odata.nextLink property is returned in the response 
			// to indicate more items are available and provide the request URL for the next page of items.
			if ("@odata.nextLink" in thisLevelChildren) {
				// Update nextLink to next changeSet bundle
				addLogEntry("Setting nextLink to (@odata.nextLink): " ~ nextLink, ["debug"]);
				nextLink = thisLevelChildren["@odata.nextLink"].str;
			} else break;
			
			// Sleep for a while to avoid busy-waiting
			Thread.sleep(dur!"msecs"(100)); // Adjust the sleep duration as needed
		}
		
		// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
		checkFileOneDriveApiInstance.releaseCurlEngine();
		checkFileOneDriveApiInstance = null;
		// Perform Garbage Collection
		GC.collect();
					
		// return an empty JSON item
		return onedriveJSONItem;
	}
	
	// Update 'onlineDriveDetails' with the latest data about this drive
	void updateDriveDetailsCache(string driveId, bool quotaRestricted, bool quotaAvailable, ulong localFileSize) {
	
		// As each thread is running differently, what is the current 'quotaRemaining' for 'driveId' ?
		ulong quotaRemaining;
		DriveDetailsCache cachedOnlineDriveData;
		cachedOnlineDriveData = getDriveDetails(driveId);
		quotaRemaining = cachedOnlineDriveData.quotaRemaining;
		
		// Update 'quotaRemaining'
		quotaRemaining = quotaRemaining - localFileSize;
		
		// Do the flags get updated?
		if (quotaRemaining <= 0) {
			if (appConfig.accountType == "personal"){
				// zero space available
				addLogEntry("ERROR: OneDrive account currently has zero space available. Please free up some space online or purchase additional space.");
				quotaRemaining = 0;
				quotaAvailable = false;
			} else {
				// zero space available is being reported, maybe being restricted?
				addLogEntry("WARNING: OneDrive quota information is being restricted or providing a zero value. Please fix by speaking to your OneDrive / Office 365 Administrator.", ["verbose"]);
				quotaRemaining = 0;
				quotaRestricted = true;
			}
		}
		
		// Updated the details
		onlineDriveDetails[driveId] = DriveDetailsCache(driveId, quotaRestricted, quotaAvailable, quotaRemaining);
	}
	
	// Update all of the known cached driveId quota details
	void freshenCachedDriveQuotaDetails() {
		foreach (driveId; onlineDriveDetails.keys) {
			// Update this driveid quota details
			addLogEntry("Freshen Quota Details: " ~ driveId, ["debug"]);
			addOrUpdateOneDriveOnlineDetails(driveId);
		}
	}
	
	// Create a 'root' DB Tie Record for a Shared Folder from the JSON data
	void createDatabaseRootTieRecordForOnlineSharedFolder(JSONValue onedriveJSONItem) {
		// Creating|Updating a DB Tie
		addLogEntry("Creating|Updating a 'root' DB Tie Record for this Shared Folder: " ~ onedriveJSONItem["name"].str, ["debug"]);
		addLogEntry("Creating|Updating a 'root' DB Tie Record for this Shared Folder: " ~ onedriveJSONItem["name"].str);
		addLogEntry("Raw JSON for 'root' DB Tie Record: " ~ to!string(onedriveJSONItem), ["debug"]);
		addLogEntry("Raw JSON for 'root' DB Tie Record: " ~ to!string(onedriveJSONItem));
		
		// New DB Tie Item to detail the 'root' of the Shared Folder
		Item tieDBItem;
		tieDBItem.name = "root";
		
		// Get the right parentReference details
		if (isItemRemote(onedriveJSONItem)) {
			tieDBItem.driveId = onedriveJSONItem["remoteItem"]["parentReference"]["driveId"].str;
			tieDBItem.id = onedriveJSONItem["remoteItem"]["id"].str;
		} else {
			if (onedriveJSONItem["name"].str != "root") {
				tieDBItem.driveId = onedriveJSONItem["parentReference"]["driveId"].str;
				
				// OneDrive Personal JSON responses are in-consistent with not having 'id' available
				if (hasParentReferenceId(onedriveJSONItem)) {
					// Use the parent reference id
					tieDBItem.id = onedriveJSONItem["parentReference"]["id"].str;
				} else {
					// Testing evidence shows that for Personal accounts, use the 'id' itself
					tieDBItem.id = onedriveJSONItem["id"].str;
				}
			} else {
				tieDBItem.driveId = onedriveJSONItem["parentReference"]["driveId"].str;
				tieDBItem.id = onedriveJSONItem["id"].str;
			}
		}
		
		tieDBItem.type = ItemType.dir;
		tieDBItem.mtime = SysTime.fromISOExtString(onedriveJSONItem["fileSystemInfo"]["lastModifiedDateTime"].str);
		tieDBItem.parentId = null;
		
		// Add this DB Tie parent record to the local database
		addLogEntry("Creating|Updating into local database a 'root' DB Tie record: " ~ to!string(tieDBItem), ["debug"]);
		itemDB.upsert(tieDBItem);
	}
	
	// Create a DB Tie Record for a Shared Folder 
	void createDatabaseTieRecordForOnlineSharedFolder(Item parentItem) {
		// Creating|Updating a DB Tie
		addLogEntry("Creating|Updating a DB Tie Record for this Shared Folder: " ~ parentItem.name, ["debug"]);
		addLogEntry("Parent Item Record: " ~ to!string(parentItem), ["debug"]);
		
		// New DB Tie Item to bind the 'remote' path to our parent path
		Item tieDBItem;
		tieDBItem.name = parentItem.name;
		tieDBItem.driveId = parentItem.remoteDriveId;
		tieDBItem.id = parentItem.remoteId;
		tieDBItem.type = ItemType.dir;
		tieDBItem.mtime = parentItem.mtime;
		
		// What account type is this as this determines what 'tieDBItem.parentId' should be set to
		// There is a difference in the JSON responses between 'personal' and 'business' account types for Shared Folders
		// Essentially an API inconsistency
		if (appConfig.accountType == "personal") {
			// Set tieDBItem.parentId to null
			tieDBItem.parentId = null;
		} else {
			// The tieDBItem.parentId needs to be the correct driveId id reference
			// Query the DB 
			Item[] rootDriveItems;
			Item dbRecord;
			rootDriveItems = itemDB.selectByDriveId(parentItem.remoteDriveId);
			dbRecord = rootDriveItems[0];
			tieDBItem.parentId = dbRecord.id;
			rootDriveItems = [];
		}
		
		// Add tie DB record to the local database
		addLogEntry("Creating|Updating into local database a DB Tie record: " ~ to!string(tieDBItem), ["debug"]);
		itemDB.upsert(tieDBItem);
	}
	
	// List all the OneDrive Business Shared Items for the user to see
	void listBusinessSharedObjects() {
	
		JSONValue sharedWithMeItems;
		
		// Create a new API Instance for this thread and initialise it
		OneDriveApi sharedWithMeOneDriveApiInstance;
		sharedWithMeOneDriveApiInstance = new OneDriveApi(appConfig);
		sharedWithMeOneDriveApiInstance.initialise();
		
		try {
			sharedWithMeItems = sharedWithMeOneDriveApiInstance.getSharedWithMe();
			
			// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
			sharedWithMeOneDriveApiInstance.releaseCurlEngine();
			sharedWithMeOneDriveApiInstance = null;
			// Perform Garbage Collection
			GC.collect();
			
		} catch (OneDriveException e) {
			// Display error message
			displayOneDriveErrorMessage(e.msg, getFunctionName!({}));
			
			// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
			sharedWithMeOneDriveApiInstance.releaseCurlEngine();
			sharedWithMeOneDriveApiInstance = null;
			// Perform Garbage Collection
			GC.collect();
			return;
		}
		
		if (sharedWithMeItems.type() == JSONType.object) {
		
			if (count(sharedWithMeItems["value"].array) > 0) {
				// No shared items
				addLogEntry();
				addLogEntry("Listing available OneDrive Business Shared Items:");
				addLogEntry();
				
				// Iterate through the array
				foreach (searchResult; sharedWithMeItems["value"].array) {
				
					// loop variables for each item
					string sharedByName;
					string sharedByEmail;
					
					// Debug response output
					addLogEntry("shared folder entry: " ~ to!string(searchResult), ["debug"]);
					
					// Configure 'who' this was shared by
					if ("sharedBy" in searchResult["remoteItem"]["shared"]) {
						// we have shared by details we can use
						if ("displayName" in searchResult["remoteItem"]["shared"]["sharedBy"]["user"]) {
							sharedByName = searchResult["remoteItem"]["shared"]["sharedBy"]["user"]["displayName"].str;
						}
						if ("email" in searchResult["remoteItem"]["shared"]["sharedBy"]["user"]) {
							sharedByEmail = searchResult["remoteItem"]["shared"]["sharedBy"]["user"]["email"].str;
						}
					}
					
					// Output query result
					addLogEntry("-----------------------------------------------------------------------------------");
					if (isItemFile(searchResult)) {
						addLogEntry("Shared File:     " ~ to!string(searchResult["name"].str));
					} else {
						addLogEntry("Shared Folder:   " ~ to!string(searchResult["name"].str));
					}
					
					// Detail 'who' shared this
					if ((sharedByName != "") && (sharedByEmail != "")) {
						addLogEntry("Shared By:       " ~ sharedByName ~ " (" ~ sharedByEmail ~ ")");
					} else {
						if (sharedByName != "") {
							addLogEntry("Shared By:       " ~ sharedByName);
						}
					}
					
					// More detail if --verbose is being used
					addLogEntry("Item Id:         " ~ searchResult["remoteItem"]["id"].str, ["verbose"]);
					addLogEntry("Parent Drive Id: " ~ searchResult["remoteItem"]["parentReference"]["driveId"].str, ["verbose"]);
					if ("id" in searchResult["remoteItem"]["parentReference"]) {
						addLogEntry("Parent Item Id:  " ~ searchResult["remoteItem"]["parentReference"]["id"].str, ["verbose"]);
					}	
				}
				
				// Close out the loop
				addLogEntry("-----------------------------------------------------------------------------------");
				addLogEntry();
				
			} else {
				// No shared items
				addLogEntry();
				addLogEntry("No OneDrive Business Shared Folders were returned");
				addLogEntry();
			}
		}
	}
	
	// Query all the OneDrive Business Shared Objects to sync only Shared Files
	void queryBusinessSharedObjects() {
	
		JSONValue sharedWithMeItems;
		Item sharedFilesRootDirectoryDatabaseRecord;
		
		// Create a new API Instance for this thread and initialise it
		OneDriveApi sharedWithMeOneDriveApiInstance;
		sharedWithMeOneDriveApiInstance = new OneDriveApi(appConfig);
		sharedWithMeOneDriveApiInstance.initialise();
		
		try {
			sharedWithMeItems = sharedWithMeOneDriveApiInstance.getSharedWithMe();
			
			// We cant shutdown the API instance here, as we reuse it below
			
		} catch (OneDriveException e) {
			// Display error message
			displayOneDriveErrorMessage(e.msg, getFunctionName!({}));
			
			// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
			sharedWithMeOneDriveApiInstance.releaseCurlEngine();
			sharedWithMeOneDriveApiInstance = null;
			// Perform Garbage Collection
			GC.collect();
			return;
		}
		
		// Valid JSON response
		if (sharedWithMeItems.type() == JSONType.object) {
		
			// Get the configuredBusinessSharedFilesDirectoryName DB item
			// We need this as we need to 'fake' create all the folders for the shared files
			// Then fake create the file entries for the database with the correct parent folder that is the local folder
			itemDB.selectByPath(baseName(appConfig.configuredBusinessSharedFilesDirectoryName), appConfig.defaultDriveId, sharedFilesRootDirectoryDatabaseRecord);
		
			// For each item returned, if a file, process it
			foreach (searchResult; sharedWithMeItems["value"].array) {
			
				// Shared Business Folders are added to the account using 'Add shortcut to My files'
				// We only care here about any remaining 'files' that are shared with the user
				
				if (isItemFile(searchResult)) {
					// Debug response output
					addLogEntry("getSharedWithMe Response Shared File JSON: " ~ to!string(searchResult), ["debug"]);
					
					// Make a DB item from this JSON
					Item sharedFileOriginalData = makeItem(searchResult);
					
					// Variables for each item
					string sharedByName;
					string sharedByEmail;
					string sharedByFolderName;
					string newLocalSharedFilePath;
					string newItemPath;
					Item sharedFilesPath;
					JSONValue fileToDownload;
					JSONValue detailsToUpdate;
					JSONValue latestOnlineDetails;
										
					// Configure 'who' this was shared by
					if ("sharedBy" in searchResult["remoteItem"]["shared"]) {
						// we have shared by details we can use
						if ("displayName" in searchResult["remoteItem"]["shared"]["sharedBy"]["user"]) {
							sharedByName = searchResult["remoteItem"]["shared"]["sharedBy"]["user"]["displayName"].str;
						}
						if ("email" in searchResult["remoteItem"]["shared"]["sharedBy"]["user"]) {
							sharedByEmail = searchResult["remoteItem"]["shared"]["sharedBy"]["user"]["email"].str;
						}
					}
					
					// Configure 'who' shared this, so that we can create the directory for that users shared files with us
					if ((sharedByName != "") && (sharedByEmail != "")) {
						sharedByFolderName = sharedByName ~ " (" ~ sharedByEmail ~ ")";
						
					} else {
						if (sharedByName != "") {
							sharedByFolderName = sharedByName;
						}
					}
					
					// Create the local path to store this users shared files with us
					newLocalSharedFilePath = buildNormalizedPath(buildPath(appConfig.configuredBusinessSharedFilesDirectoryName, sharedByFolderName));
					
					// Does the Shared File Users Local Directory to store the shared file(s) exist?
					if (!exists(newLocalSharedFilePath)) {
						// Folder does not exist locally and needs to be created
						addLogEntry("Creating the OneDrive Business Shared File Users Local Directory: " ~ newLocalSharedFilePath);
					
						// Local folder does not exist, thus needs to be created
						mkdirRecurse(newLocalSharedFilePath);
						
						// As this will not be created online, generate a response so it can be saved to the database
						sharedFilesPath = makeItem(createFakeResponse(baseName(newLocalSharedFilePath)));
						
						// Update sharedFilesPath parent items to that of sharedFilesRootDirectoryDatabaseRecord
						sharedFilesPath.parentId = sharedFilesRootDirectoryDatabaseRecord.id;
						
						// Add DB record to the local database
						addLogEntry("Creating|Updating into local database a DB record for storing OneDrive Business Shared Files: " ~ to!string(sharedFilesPath), ["debug"]);
						itemDB.upsert(sharedFilesPath);
					} else {
						// Folder exists locally, is the folder in the database? 
						// Query DB for this path
						Item dbRecord;
						if (!itemDB.selectByPath(baseName(newLocalSharedFilePath), appConfig.defaultDriveId, dbRecord)) {
							// As this will not be created online, generate a response so it can be saved to the database
							sharedFilesPath = makeItem(createFakeResponse(baseName(newLocalSharedFilePath)));
							
							// Update sharedFilesPath parent items to that of sharedFilesRootDirectoryDatabaseRecord
							sharedFilesPath.parentId = sharedFilesRootDirectoryDatabaseRecord.id;
							
							// Add DB record to the local database
							addLogEntry("Creating|Updating into local database a DB record for storing OneDrive Business Shared Files: " ~ to!string(sharedFilesPath), ["debug"]);
							itemDB.upsert(sharedFilesPath);
						}
					}
					
					// The file to download JSON details
					fileToDownload = searchResult;
					
					// Get the latest online details
					latestOnlineDetails = sharedWithMeOneDriveApiInstance.getPathDetailsById(sharedFileOriginalData.remoteDriveId, sharedFileOriginalData.remoteId);
					Item tempOnlineRecord = makeItem(latestOnlineDetails);
					
					// With the local folders created, now update 'fileToDownload' to download the file to our location:
					//	"parentReference": {
					//		"driveId": "<account drive id>",
					//		"driveType": "business",
					//		"id": "<local users shared folder id>",
					//	},
					
					// The getSharedWithMe() JSON response also contains an API bug where the 'hash' of the file is not provided
					// Use the 'latestOnlineDetails' response to obtain the hash
					//	"file": {
					//		"hashes": {
					//			"quickXorHash": "<hash value>"
					//		}
					//	},
					//
					
					// The getSharedWithMe() JSON response also contains an API bug where the 'size' of the file is not the actual size of the file
					// The getSharedWithMe() JSON response also contains an API bug where the 'eTag' of the file is not present
					// The getSharedWithMe() JSON response also contains an API bug where the 'lastModifiedDateTime' of the file is date when the file was shared, not the actual date last modified
					
					detailsToUpdate = [
								"parentReference": JSONValue([
															"driveId": JSONValue(appConfig.defaultDriveId),
															"driveType": JSONValue("business"),
															"id": JSONValue(sharedFilesPath.id)
															]),
								"file": JSONValue([
													"hashes":JSONValue([
																		"quickXorHash": JSONValue(tempOnlineRecord.quickXorHash)
																		])
													]),
								"eTag": JSONValue(tempOnlineRecord.eTag)
								];
					
					foreach (string key, JSONValue value; detailsToUpdate.object) {
						fileToDownload[key] = value;
					}
					
					// Update specific items
					// Update 'size'
					fileToDownload["size"] = to!int(tempOnlineRecord.size);
					fileToDownload["remoteItem"]["size"] = to!int(tempOnlineRecord.size);
					// Update 'lastModifiedDateTime'
					fileToDownload["lastModifiedDateTime"] = latestOnlineDetails["fileSystemInfo"]["lastModifiedDateTime"].str;
					fileToDownload["fileSystemInfo"]["lastModifiedDateTime"] = latestOnlineDetails["fileSystemInfo"]["lastModifiedDateTime"].str;
					fileToDownload["remoteItem"]["lastModifiedDateTime"] = latestOnlineDetails["fileSystemInfo"]["lastModifiedDateTime"].str;
					fileToDownload["remoteItem"]["fileSystemInfo"]["lastModifiedDateTime"] = latestOnlineDetails["fileSystemInfo"]["lastModifiedDateTime"].str;
					
					// Final JSON that will be used to download the file
					addLogEntry("Final fileToDownload: " ~ to!string(fileToDownload), ["debug"]);
					
					// Make the new DB item from the consolidated JSON item
					Item downloadSharedFileDbItem = makeItem(fileToDownload);
					
					// Calculate the full local path for this shared file
					newItemPath = computeItemPath(downloadSharedFileDbItem.driveId, downloadSharedFileDbItem.parentId) ~ "/" ~ downloadSharedFileDbItem.name;
					
					// Does this potential file exists on disk?
					if (!exists(newItemPath)) {
						// The shared file does not exists locally
						// Is this something we actually want? Check the JSON against Client Side Filtering Rules
						bool unwanted = checkJSONAgainstClientSideFiltering(fileToDownload);
						if (!unwanted) {
							// File has not been excluded via Client Side Filtering
							// Submit this shared file to be processed further for downloading
							applyPotentiallyNewLocalItem(downloadSharedFileDbItem, fileToDownload, newItemPath);
						}
					} else {
						// A file, in the desired local location already exists with the same name
						// Is this local file in sync?
						string itemSource = "remote";
						if (!isItemSynced(downloadSharedFileDbItem, newItemPath, itemSource)) {
							// Not in sync ....
							Item existingDatabaseItem;
							bool existingDBEntry = itemDB.selectById(downloadSharedFileDbItem.driveId, downloadSharedFileDbItem.id, existingDatabaseItem);
							
							// Is there a DB entry?
							if (existingDBEntry) {
								// Existing DB entry
								// Need to be consistent here with how 'newItemPath' was calculated
								string existingItemPath = computeItemPath(existingDatabaseItem.driveId, existingDatabaseItem.parentId) ~ "/" ~ existingDatabaseItem.name;
								// Attempt to apply this changed item
								applyPotentiallyChangedItem(existingDatabaseItem, existingItemPath, downloadSharedFileDbItem, newItemPath, fileToDownload);
							} else {
								// File exists locally, it is not in sync, there is no record in the DB of this file
								// In case the renamed path is needed
								string renamedPath;
								// Rename the local file
								safeBackup(newItemPath, dryRun, renamedPath);
								// Submit this shared file to be processed further for downloading
								applyPotentiallyNewLocalItem(downloadSharedFileDbItem, fileToDownload, newItemPath);
							}
						} else {
							// Item is in sync, ensure the DB record is the same
							itemDB.upsert(downloadSharedFileDbItem);
						}
					}
				}
			}
		}
		
		// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
		sharedWithMeOneDriveApiInstance.releaseCurlEngine();
		sharedWithMeOneDriveApiInstance = null;
		// Perform Garbage Collection
		GC.collect();
	}
	
	// Renaming or moving a directory online manually using --source-directory 'path/as/source/' --destination-directory 'path/as/destination'
	void moveOrRenameDirectoryOnline(string sourcePath, string destinationPath) {
	
		// Function Variables
		bool sourcePathExists = false;
		bool destinationPathExists = false;
		bool invalidDestination = false;
		JSONValue sourcePathData;
		JSONValue destinationPathData;
		JSONValue parentPathData;
		Item sourceItem;
		Item parentItem;
		
		// Log that we are doing a move
		addLogEntry("Moving " ~ sourcePath ~ " to " ~ destinationPath);
		
		// Create a new API Instance for this thread and initialise it
		OneDriveApi onlineMoveApiInstance;
		onlineMoveApiInstance = new OneDriveApi(appConfig);
		onlineMoveApiInstance.initialise();
		
		// In order to move, the 'source' needs to exist online, so this is the first check
		try {
			sourcePathData = onlineMoveApiInstance.getPathDetails(sourcePath);
			sourceItem = makeItem(sourcePathData);
			sourcePathExists = true;
		} catch (OneDriveException exception) {
		
			if (exception.httpStatusCode == 404) {
				// The item to search was not found. If it does not exist, how can we move it?
				addLogEntry("The source path to move does not exist online - unable to move|rename a path that does not already exist online");
				forceExit();
			} else {
				// An error, regardless of what it is ... not good
				// Display what the error is
				// - 408,429,503,504 errors are handled as a retry within uploadFileOneDriveApiInstance
				displayOneDriveErrorMessage(exception.msg, getFunctionName!({}));
				forceExit();
			}
		}
		
		// The second check needs to be that the destination does not already exist
		try {
			destinationPathData = onlineMoveApiInstance.getPathDetails(destinationPath);
			destinationPathExists = true;
			addLogEntry("The destination path to move to exists online - unable to move|rename to a path that already exists online");
			forceExit();
		} catch (OneDriveException exception) {
		
			if (exception.httpStatusCode == 404) {
				// The item to search was not found. This is good as the destination path is empty
			} else {
				// An error, regardless of what it is ... not good
				// Display what the error is
				// - 408,429,503,504 errors are handled as a retry within uploadFileOneDriveApiInstance
				displayOneDriveErrorMessage(exception.msg, getFunctionName!({}));
				forceExit();
			}
		}
		
		// Can we move?
		if ((sourcePathExists) && (!destinationPathExists)) {
			// Make an item we can use
			Item onlineItem = makeItem(sourcePathData);
		
			// The directory to move MUST be a directory
			if (onlineItem.type == ItemType.dir) {
			
				// Validate that the 'destination' is valid
				
				// This not a Client Side Filtering check, nor a Microsoft Check, but is a sanity check that the path provided is UTF encoded correctly
				// Check the std.encoding of the path against: Unicode 5.0, ASCII, ISO-8859-1, ISO-8859-2, WINDOWS-1250, WINDOWS-1251, WINDOWS-1252
				if (!invalidDestination) {
					if(!isValid(destinationPath)) {
						// Path is not valid according to https://dlang.org/phobos/std_encoding.html
						addLogEntry("Skipping move - invalid character encoding sequence: " ~ destinationPath, ["info", "notify"]);
						invalidDestination = true;
					}
				}
				
				// We do not check this path against the Client Side Filtering Rules as this is 100% an online move only
				
				// Check this path against the Microsoft Naming Conventions & Restristions
				// - Check path against Microsoft OneDrive restriction and limitations about Windows naming for files and folders
				// - Check path for bad whitespace items
				// - Check path for HTML ASCII Codes
				// - Check path for ASCII Control Codes
				if (!invalidDestination) {
					invalidDestination = checkPathAgainstMicrosoftNamingRestrictions(destinationPath, "move");
				}
				
				// Is the destination location invalid?
				if (!invalidDestination) {
					// We can perform the online move
					// We need to query for the parent information of the destination path
					string parentPath = dirName(destinationPath);
					
					// Configure the parentItem by if this is the account 'root' use the root details, or query online for the parent details
					if (parentPath == ".") {
						// Parent path is '.' which is the account root - use client defaults
						parentItem.driveId = appConfig.defaultDriveId; 	// Should give something like 12345abcde1234a1
						parentItem.id = appConfig.defaultRootId;  		// Should give something like 12345ABCDE1234A1!101
					} else {
						// Need to query to obtain the details
						try {
							addLogEntry("Attempting to query OneDrive Online for this parent path: " ~ parentPath, ["debug"]);
							parentPathData = onlineMoveApiInstance.getPathDetails(parentPath);
							addLogEntry("Online Parent Path Query Response: " ~ to!string(parentPathData), ["debug"]);
							parentItem = makeItem(parentPathData);
						} catch (OneDriveException exception) {
							if (exception.httpStatusCode == 404) {
								// The item to search was not found. If it does not exist, how can we move it?
								addLogEntry("The parent path to move to does not exist online - unable to move|rename a path to a parent that does exist online");
								forceExit();
							} else {
								// Display what the error is
								// - 408,429,503,504 errors are handled as a retry within uploadFileOneDriveApiInstance
								displayOneDriveErrorMessage(exception.msg, getFunctionName!({}));
								forceExit();
							}
						}
					}
					
					// Configure the modification JSON item
					SysTime mtime;
					// Use the current system time
					mtime = Clock.currTime().toUTC();
					
					JSONValue data = [
						"name": JSONValue(baseName(destinationPath)),
						"parentReference": JSONValue([
							"id": parentItem.id
						]),
						"fileSystemInfo": JSONValue([
							"lastModifiedDateTime": mtime.toISOExtString()
						])
					];
					
					// Try the online move
					try {
						onlineMoveApiInstance.updateById(sourceItem.driveId, sourceItem.id, data, sourceItem.eTag);
						// Log that it was successful
						addLogEntry("Successfully moved " ~ sourcePath ~ " to " ~ destinationPath);
					} catch (OneDriveException exception) {
						// Display what the error is
						// - 408,429,503,504 errors are handled as a retry within uploadFileOneDriveApiInstance
						displayOneDriveErrorMessage(exception.msg, getFunctionName!({}));
						forceExit();	
					}
				}
			} else {
				// The source item is not a directory
				addLogEntry("ERROR: The source path to move is not a directory");
				forceExit();
			}
		}
	}
}