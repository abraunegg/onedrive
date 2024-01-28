// What is this module called?
module syncEngine;

// What does this module require to function?
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

class jsonResponseException: Exception {
	@safe pure this(string inputMessage) {
		string msg = format(inputMessage);
		super(msg);
	}	
}

class posixException: Exception {
	@safe pure this(string localTargetName, string remoteTargetName) {
		string msg = format("POSIX 'case-insensitive match' between '%s' (local) and '%s' (online) which violates the Microsoft OneDrive API namespace convention", localTargetName, remoteTargetName);
		super(msg);
	}	
}

class accountDetailsException: Exception {
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

class SyncEngine {
	// Class Variables
	ApplicationConfig appConfig;
	OneDriveApi oneDriveApiInstance;
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
	// Array of all OneDrive driveId's that have been seen
	string[] driveIDsArray;
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
	// List of local paths, that, when using the OneDrive Business Shared Folders feature, then diabling it, folder still exists locally and online
	// This list of local paths need to be skipped
	string[] businessSharedFoldersOnlineToSkip;
	// List of interrupted uploads session files that need to be resumed
	string[] interruptedUploadsSessionFiles;
	// List of validated interrupted uploads session JSON items to resume
	JSONValue[] jsonItemsToResumeUpload;
		
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
	
	// Configure this class instance
	this(ApplicationConfig appConfig, ItemDatabase itemDB, ClientSideFiltering selectiveSync) {
		// Configure the class varaible to consume the application configuration
		this.appConfig = appConfig;
		// Configure the class varaible to consume the database configuration
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

		// create a new instance of the OneDrive API
		oneDriveApiInstance = new OneDriveApi(appConfig);
		if (oneDriveApiInstance.initialise()) {
			try {
				// Get the relevant default account & drive details
				getDefaultDriveDetails();
			} catch (accountDetailsException exception) {
				// details could not be queried
				addLogEntry(exception.msg);
				// Shutdown API instance
				oneDriveApiInstance.shutdown();
				// Free object and memory
				object.destroy(oneDriveApiInstance);
				// Must force exit here, allow logging to be done
				forceExit();
			}
			
			try {
				// Get the relevant default account & drive details
				getDefaultRootDetails();
			} catch (accountDetailsException exception) {
				// details could not be queried
				addLogEntry(exception.msg);
				// Shutdown API instance
				oneDriveApiInstance.shutdown();
				// Free object and memory
				object.destroy(oneDriveApiInstance);
				// Must force exit here, allow logging to be done
				forceExit();
			}
			
			try {
				// Display details
				displaySyncEngineDetails();
			} catch (accountDetailsException exception) {
				// details could not be queried
				addLogEntry(exception.msg);
				// Shutdown API instance
				oneDriveApiInstance.shutdown();
				// Free object and memory
				object.destroy(oneDriveApiInstance);
				// Must force exit here, allow logging to be done
				forceExit();
			}
		} else {
			// API could not be initialised
			addLogEntry("OneDrive API could not be initialised with previously used details");
			// Shutdown API instance
			oneDriveApiInstance.shutdown();
			// Free object and memory
			object.destroy(oneDriveApiInstance);
			// Must force exit here, allow logging to be done
			forceExit();
		}
		
		// API was initialised
		addLogEntry("Sync Engine Initialised with new Onedrive API instance", ["verbose"]);
		
		// Shutdown this API instance, as we will create API instances as required, when required
		oneDriveApiInstance.shutdown();
		// Free object and memory
		object.destroy(oneDriveApiInstance);
		return true;
	}
	
	// Get Default Drive Details for this Account
	void getDefaultDriveDetails() {
		
		// Function variables
		JSONValue defaultOneDriveDriveDetails;
		
		// Get Default Drive Details for this Account
		try {
			addLogEntry("Getting Account Default Drive Details", ["debug"]);
			defaultOneDriveDriveDetails = oneDriveApiInstance.getDefaultDriveDetails();
		} catch (OneDriveException exception) {
			addLogEntry("defaultOneDriveDriveDetails = oneDriveApiInstance.getDefaultDriveDetails() generated a OneDriveException", ["debug"]);
			string thisFunctionName = getFunctionName!({});
			
			if ((exception.httpStatusCode == 400) || (exception.httpStatusCode == 401)) {
				// Handle the 400 | 401 error
				handleClientUnauthorised(exception.httpStatusCode, exception.msg);
			}
			
			// HTTP request returned status code 408,429,503,504
			if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 429) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
				// Handle the 429
				if (exception.httpStatusCode == 429) {
					// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
					handleOneDriveThrottleRequest(oneDriveApiInstance);
					addLogEntry("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - attempting to retry " ~ thisFunctionName, ["debug"]);
				}
				// re-try the specific changes queries
				if ((exception.httpStatusCode == 408) ||(exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
					// 408 - Request Time Out
					// 503 - Service Unavailable
					// 504 - Gateway Timeout
					// Transient error - try again in 30 seconds
					auto errorArray = splitLines(exception.msg);
					addLogEntry(to!string(errorArray[0]) ~ " when attempting to query Account Default Drive Details - retrying applicable request in 30 seconds");
					addLogEntry("defaultOneDriveDriveDetails = oneDriveApiInstance.getDefaultDriveDetails() previously threw an error - retrying", ["debug"]);
					// The server, while acting as a proxy, did not receive a timely response from the upstream server it needed to access in attempting to complete the request. 
					addLogEntry("Thread sleeping for 30 seconds as the server did not receive a timely response from the upstream server it needed to access in attempting to complete the request", ["debug"]);
					Thread.sleep(dur!"seconds"(30));
				}
				// re-try original request - retried for 429 and 504 - but loop back calling this function 
				addLogEntry("Retrying Function: getDefaultDriveDetails()", ["debug"]);
				getDefaultDriveDetails();
			} else {
				// Default operation if not 408,429,503,504 errors
				// display what the error is
				displayOneDriveErrorMessage(exception.msg, getFunctionName!({}));
			}
		}
		
		// If the JSON response is a correct JSON object, and has an 'id' we can set these details
		if ((defaultOneDriveDriveDetails.type() == JSONType.object) && (hasId(defaultOneDriveDriveDetails))) {
			addLogEntry("OneDrive Account Default Drive Details:      " ~ to!string(defaultOneDriveDriveDetails), ["debug"]);
			appConfig.accountType = defaultOneDriveDriveDetails["driveType"].str;
			appConfig.defaultDriveId = defaultOneDriveDriveDetails["id"].str;
			
			// Get the initial remaining size from OneDrive API response JSON
			// This will be updated as we upload data to OneDrive
			if (hasQuota(defaultOneDriveDriveDetails)) {
				if ("remaining" in defaultOneDriveDriveDetails["quota"]){
					// use the value provided
					appConfig.remainingFreeSpace = defaultOneDriveDriveDetails["quota"]["remaining"].integer;
				}
			}
			
			// In some cases OneDrive Business configurations 'restrict' quota details thus is empty / blank / negative value / zero
			if (appConfig.remainingFreeSpace <= 0) {
				// free space is <= 0  .. why ?
				if ("remaining" in defaultOneDriveDriveDetails["quota"]) {
					if (appConfig.accountType == "personal") {
						// zero space available
						addLogEntry("ERROR: OneDrive account currently has zero space available. Please free up some space online.");
						appConfig.quotaAvailable = false;
					} else {
						// zero space available is being reported, maybe being restricted?
						addLogEntry("WARNING: OneDrive quota information is being restricted or providing a zero value. Please fix by speaking to your OneDrive / Office 365 Administrator.");
						appConfig.quotaRestricted = true;
					}
				} else {
					// json response was missing a 'remaining' value
					if (appConfig.accountType == "personal") {
						addLogEntry("ERROR: OneDrive quota information is missing. Potentially your OneDrive account currently has zero space available. Please free up some space online.");
						appConfig.quotaAvailable = false;
					} else {
						// quota details not available
						addLogEntry("ERROR: OneDrive quota information is being restricted. Please fix by speaking to your OneDrive / Office 365 Administrator.");
						appConfig.quotaRestricted = true;
					}
				}
			}
			// What did we set based on the data from the JSON
			addLogEntry("appConfig.accountType        = " ~ appConfig.accountType, ["debug"]);
			addLogEntry("appConfig.defaultDriveId     = " ~ appConfig.defaultDriveId, ["debug"]);
			addLogEntry("appConfig.remainingFreeSpace = " ~ to!string(appConfig.remainingFreeSpace), ["debug"]);
			addLogEntry("appConfig.quotaAvailable     = " ~ to!string(appConfig.quotaAvailable), ["debug"]);
			addLogEntry("appConfig.quotaRestricted    = " ~ to!string(appConfig.quotaRestricted), ["debug"]);
			
			// Make sure that appConfig.defaultDriveId is in our driveIDs array to use when checking if item is in database
			// Keep the driveIDsArray with unique entries only
			if (!canFind(driveIDsArray, appConfig.defaultDriveId)) {
				// Add this drive id to the array to search with
				driveIDsArray ~= appConfig.defaultDriveId;
			}
		} else {
			// Handle the invalid JSON response
			throw new accountDetailsException();
		}
	}
	
	// Get Default Root Details for this Account
	void getDefaultRootDetails() {
		
		// Function variables
		JSONValue defaultOneDriveRootDetails;
		
		// Get Default Root Details for this Account
		try {
			addLogEntry("Getting Account Default Root Details", ["debug"]);
			defaultOneDriveRootDetails = oneDriveApiInstance.getDefaultRootDetails();
		} catch (OneDriveException exception) {
			addLogEntry("defaultOneDriveRootDetails = oneDriveApiInstance.getDefaultRootDetails() generated a OneDriveException", ["debug"]);
			string thisFunctionName = getFunctionName!({});

			if ((exception.httpStatusCode == 400) || (exception.httpStatusCode == 401)) {
				// Handle the 400 | 401 error
				handleClientUnauthorised(exception.httpStatusCode, exception.msg);
			}
			
			// HTTP request returned status code 408,429,503,504
			if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 429) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
				// Handle the 429
				if (exception.httpStatusCode == 429) {
					// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
					handleOneDriveThrottleRequest(oneDriveApiInstance);
					addLogEntry("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - attempting to retry " ~ thisFunctionName, ["debug"]);
				}
				// re-try the specific changes queries
				if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
					// 503 - Service Unavailable
					// 504 - Gateway Timeout
					// Transient error - try again in 30 seconds
					auto errorArray = splitLines(exception.msg);
					addLogEntry(to!string(errorArray[0]) ~ " when attempting to query Account Default Root Details - retrying applicable request in 30 seconds");
					addLogEntry("defaultOneDriveRootDetails = oneDriveApiInstance.getDefaultRootDetails() previously threw an error - retrying", ["debug"]);
					
					// The server, while acting as a proxy, did not receive a timely response from the upstream server it needed to access in attempting to complete the request. 
					addLogEntry("Thread sleeping for 30 seconds as the server did not receive a timely response from the upstream server it needed to access in attempting to complete the request", ["debug"]);
					Thread.sleep(dur!"seconds"(30));
				}
				// re-try original request - retried for 429, 503, 504 - but loop back calling this function 
				addLogEntry("Retrying Function: " ~ thisFunctionName, ["debug"]);
				getDefaultRootDetails();
			} else {
				// Default operation if not 408,429,503,504 errors
				// display what the error is
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
			throw new accountDetailsException();
		}
	}
	
	// Reset syncFailures to false
	void resetSyncFailures() {
		// Reset syncFailures to false if these are both empty
		if (syncFailures) {
			if ((fileDownloadFailures.empty) && (fileUploadFailures.empty)) {
				addLogEntry("Resetting syncFailures = false");
				syncFailures = false;
			} else {
				addLogEntry("File activity array's not empty - not resetting syncFailures");
			}
		}
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
		
		// Fetch the API response of /delta to track changes on OneDrive
		fetchOneDriveDeltaAPIResponse(null, null, null);
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
							addLogEntry("Skipping item - excluded by skip_dir config: " ~ remoteItem.name, ["verbose"]);
							continue;
						}
					}
					
					// Directory name is not excluded or skip_dir is not populated
					if (!appConfig.surpressLoggingOutput) {
						addLogEntry("Syncing this OneDrive Personal Shared Folder: " ~ remoteItem.name);
					}
					// Check this OneDrive Personal Shared Folder for changes
					fetchOneDriveDeltaAPIResponse(remoteItem.remoteDriveId, remoteItem.remoteId, remoteItem.name);
					// Process any download activities or cleanup actions for this OneDrive Personal Shared Folder
					processDownloadActivities();
				}
			} else {
				// Is this a Business Account with Sync Business Shared Items enabled?
				if ((appConfig.accountType == "business") && ( appConfig.getValueBool("sync_business_shared_items"))) {
				
					// Business Account Shared Items Handling
					// - OneDrive Business Shared Folder
					// - OneDrive Business Shared Files ??
					// - SharePoint Links
				
					// Get the Remote Items from the Database
					Item[] remoteItems = itemDB.selectRemoteItems();
					
					foreach (remoteItem; remoteItems) {
						// Check if this path is specifically excluded by 'skip_dir', but only if 'skip_dir' is not empty
						if (appConfig.getValueString("skip_dir") != "") {
							// The path that needs to be checked needs to include the '/'
							// This due to if the user has specified in skip_dir an exclusive path: '/path' - that is what must be matched
							if (selectiveSync.isDirNameExcluded(remoteItem.name)) {
								// This directory name is excluded
								addLogEntry("Skipping item - excluded by skip_dir config: " ~ remoteItem.name, ["verbose"]);
								continue;
							}
						}
						
						// Directory name is not excluded or skip_dir is not populated
						if (!appConfig.surpressLoggingOutput) {
							addLogEntry("Syncing this OneDrive Business Shared Folder: " ~ remoteItem.name);
						}
						
						// Debug log output
						addLogEntry("Fetching /delta API response for:", ["debug"]);
						addLogEntry("    remoteItem.remoteDriveId: " ~ remoteItem.remoteDriveId, ["debug"]);
						addLogEntry("    remoteItem.remoteId:      " ~ remoteItem.remoteId, ["debug"]);
						
						// Check this OneDrive Personal Shared Folder for changes
						fetchOneDriveDeltaAPIResponse(remoteItem.remoteDriveId, remoteItem.remoteId, remoteItem.name);
						
						// Process any download activities or cleanup actions for this OneDrive Personal Shared Folder
						processDownloadActivities();
					}
				}
			}
		}
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
		} catch (posixException e) {
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
		string deltaLinkAvailable;
		JSONValue deltaChanges;
		ulong responseBundleCount;
		ulong jsonItemsReceived = 0;
		
		// Reset jsonItemsToProcess & processedCount
		jsonItemsToProcess = [];
		processedCount = 0;
		
		// Was a driveId provided as an input
		//if (driveIdToQuery == "") {
		if (strip(driveIdToQuery).empty) {
			// No provided driveId to query, use the account default
			addLogEntry("driveIdToQuery was empty, setting to appConfig.defaultDriveId", ["debug"]);
			driveIdToQuery = appConfig.defaultDriveId;
			addLogEntry("driveIdToQuery: " ~ driveIdToQuery, ["debug"]);
		}
		
		// Was an itemId provided as an input
		//if (itemIdToQuery == "") {
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
		//   - If the user deletes a folder online, then replaces it online, we download the deletion events and process the new 'upload' via the web iterface .. 
		//     the net effect of this, is that the valid local files we want to keep, are actually deleted ...... not desirable
		if ((singleDirectoryScope) || (nationalCloudDeployment) || (cleanupLocalFiles)) {
			// Generate a simulated /delta response so that we correctly capture the current online state, less any 'online' delete and replace activity
			generateSimulatedDeltaResponse = true;
		}
		
		// What /delta query do we use?
		if (!generateSimulatedDeltaResponse) {
			// This should be the majority default pathway application use
			// Get the current delta link from the database for this DriveID and RootID
			deltaLinkAvailable = itemDB.getDeltaLink(driveIdToQuery, itemIdToQuery);
			if (!deltaLinkAvailable.empty) {
				addLogEntry("Using database stored deltaLink", ["debug"]);
				currentDeltaLink = deltaLinkAvailable;
			}
			
			// Do we need to perform a Full Scan True Up? Is 'appConfig.fullScanTrueUpRequired' set to 'true'?
			if (appConfig.fullScanTrueUpRequired) {
				addLogEntry("Performing a full scan of online data to ensure consistent local state");
				addLogEntry("Setting currentDeltaLink = null", ["debug"]);
				currentDeltaLink = null;
			}
			
			// Dynamic output for non-verbose and verbose run so that the user knows something is being retreived from the OneDrive API
			if (appConfig.verbosityCount == 0) {
				if (!appConfig.surpressLoggingOutput) {
					addProcessingLogHeaderEntry("Fetching items from the OneDrive API for Drive ID: " ~ driveIdToQuery);
				}
			} else {
				addLogEntry("Fetching /delta response from the OneDrive API for Drive ID: " ~  driveIdToQuery, ["verbose"]);
			}
							
			// Create a new API Instance for querying /delta and initialise it
			// Reuse the socket to speed up
			bool keepAlive = true;
			OneDriveApi getDeltaQueryOneDriveApiInstance;
			getDeltaQueryOneDriveApiInstance = new OneDriveApi(appConfig);
			getDeltaQueryOneDriveApiInstance.initialise(keepAlive);
			
			for (;;) {
				responseBundleCount++;
				// Get the /delta changes via the OneDrive API
				// getDeltaChangesByItemId has the re-try logic for transient errors
				deltaChanges = getDeltaChangesByItemId(driveIdToQuery, itemIdToQuery, currentDeltaLink, getDeltaQueryOneDriveApiInstance);
				
				// If the initial deltaChanges response is an invalid JSON object, keep trying ..
				if (deltaChanges.type() != JSONType.object) {
					while (deltaChanges.type() != JSONType.object) {
						// Handle the invalid JSON response adn retry
						addLogEntry("ERROR: Query of the OneDrive API via deltaChanges = getDeltaChangesByItemId() returned an invalid JSON response", ["debug"]);
						deltaChanges = getDeltaChangesByItemId(driveIdToQuery, itemIdToQuery, currentDeltaLink, getDeltaQueryOneDriveApiInstance);
					}
				}
				
				ulong nrChanges = count(deltaChanges["value"].array);
				int changeCount = 0;
				
				if (appConfig.verbosityCount == 0) {
					// Dynamic output for a non-verbose run so that the user knows something is happening
					if (!appConfig.surpressLoggingOutput) {
						addProcessingDotEntry();
					}
				} else {
					addLogEntry("Processing API Response Bundle: " ~ to!string(responseBundleCount) ~ " - Quantity of 'changes|items' in this bundle to process: " ~ to!string(nrChanges), ["verbose"]);
				}
				
				jsonItemsReceived = jsonItemsReceived + nrChanges;
				
				// We have a valid deltaChanges JSON array. This means we have at least 200+ JSON items to process.
				// The API response however cannot be run in parallel as the OneDrive API sends the JSON items in the order in which they must be processed
				foreach (onedriveJSONItem; deltaChanges["value"].array) {
					// increment change count for this item
					changeCount++;
					// Process the OneDrive object item JSON
					processDeltaJSONItem(onedriveJSONItem, nrChanges, changeCount, responseBundleCount, singleDirectoryScope);
				}
				
				// The response may contain either @odata.deltaLink or @odata.nextLink
				if ("@odata.deltaLink" in deltaChanges) {
					// Log action
					addLogEntry("Setting next currentDeltaLink to (@odata.deltaLink): " ~ deltaChanges["@odata.deltaLink"].str, ["debug"]);
					// Update currentDeltaLink
					currentDeltaLink = deltaChanges["@odata.deltaLink"].str;
					// Store this for later use post processing jsonItemsToProcess items
					latestDeltaLink = deltaChanges["@odata.deltaLink"].str;
				}
				
				// Update deltaLink to next changeSet bundle
				if ("@odata.nextLink" in deltaChanges) {	
					// Log action
					addLogEntry("Setting next currentDeltaLink & deltaLinkAvailable to (@odata.nextLink): " ~ deltaChanges["@odata.nextLink"].str, ["debug"]);
					// Update currentDeltaLink
					currentDeltaLink = deltaChanges["@odata.nextLink"].str;
					// Update deltaLinkAvailable to next changeSet bundle to quantify how many changes we have to process
					deltaLinkAvailable = deltaChanges["@odata.nextLink"].str;
					// Store this for later use post processing jsonItemsToProcess items
					latestDeltaLink = deltaChanges["@odata.nextLink"].str;
				}
				else break;
			}
			
			// To finish off the JSON processing items, this is needed to reflect this in the log
			addLogEntry("------------------------------------------------------------------", ["debug"]);
			
			// Shutdown the API
			getDeltaQueryOneDriveApiInstance.shutdown();
			// Free object and memory
			object.destroy(getDeltaQueryOneDriveApiInstance);
			
			// Log that we have finished querying the /delta API
			if (appConfig.verbosityCount == 0) {
				if (!appConfig.surpressLoggingOutput) {
					// Close out the '....' being printed to the console
					addLogEntry("\n", ["consoleOnlyNoNewLine"]);
				}
			} else {
				addLogEntry("Finished processing /delta JSON response from the OneDrive API", ["verbose"]);
			}
			
			// If this was set, now unset it, as this will have been completed, so that for a true up, we dont do a double full scan
			if (appConfig.fullScanTrueUpRequired) {
				addLogEntry("Unsetting fullScanTrueUpRequired as this has been performed", ["debug"]);
				appConfig.fullScanTrueUpRequired = false;
			}
		} else {
			// Why are are generating a /delta response
			addLogEntry("Why are we generating a /delta response:", ["debug"]);
			addLogEntry(" singleDirectoryScope:    " ~ to!string(singleDirectoryScope), ["debug"]);
			addLogEntry(" nationalCloudDeployment: " ~ to!string(nationalCloudDeployment), ["debug"]);
			addLogEntry(" cleanupLocalFiles:       " ~ to!string(cleanupLocalFiles), ["debug"]);
			
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
			
			ulong nrChanges = count(deltaChanges["value"].array);
			int changeCount = 0;
			addLogEntry("API Response Bundle: " ~ to!string(responseBundleCount) ~ " - Quantity of 'changes|items' in this bundle to process: " ~ to!string(nrChanges), ["debug"]);
			jsonItemsReceived = jsonItemsReceived + nrChanges;
			
			// The API response however cannot be run in parallel as the OneDrive API sends the JSON items in the order in which they must be processed
			foreach (onedriveJSONItem; deltaChanges["value"].array) {
				// increment change count for this item
				changeCount++;
				// Process the OneDrive object item JSON
				processDeltaJSONItem(onedriveJSONItem, nrChanges, changeCount, responseBundleCount, singleDirectoryScope);	
			}
			
			// To finish off the JSON processing items, this is needed to reflect this in the log
			addLogEntry("------------------------------------------------------------------", ["debug"]);
			
			// Log that we have finished generating our self generated /delta response
			if (!appConfig.surpressLoggingOutput) {
				addLogEntry("Finished processing self generated /delta JSON response from the OneDrive API");
			}
		}
		
		// Cleanup deltaChanges as this is no longer needed
		object.destroy(deltaChanges);
		
		// We have JSON items received from the OneDrive API
		addLogEntry("Number of JSON Objects received from OneDrive API:                 " ~ to!string(jsonItemsReceived), ["debug"]);
		addLogEntry("Number of JSON Objects already processed (root and deleted items): " ~ to!string((jsonItemsReceived - jsonItemsToProcess.length)), ["debug"]);
		
		// We should have now at least processed all the JSON items as returned by the /delta call
		// Additionally, we should have a new array, that now contains all the JSON items we need to process that are non 'root' or deleted items
		addLogEntry("Number of JSON items to process is: " ~ to!string(jsonItemsToProcess.length), ["debug"]);
		
		// Are there items to process?
		if (jsonItemsToProcess.length > 0) {
			// Lets deal with the JSON items in a batch process
			ulong batchSize = 500;
			ulong batchCount = (jsonItemsToProcess.length + batchSize - 1) / batchSize;
			ulong batchesProcessed = 0;
			
			// Dynamic output for a non-verbose run so that the user knows something is happening
			if (!appConfig.surpressLoggingOutput) {
				// Logfile entry
				addProcessingLogHeaderEntry("Processing " ~ to!string(jsonItemsToProcess.length) ~ " applicable changes and items received from Microsoft OneDrive");
				
				if (appConfig.verbosityCount != 0) {
					// Close out the console only processing line above, if we are doing verbose or above logging
					addLogEntry("\n", ["consoleOnlyNoNewLine"]);
				}
			}
			
			// For each batch, process the JSON items that need to be now processed.
			// 'root' and deleted objects have already been handled
			foreach (batchOfJSONItems; jsonItemsToProcess.chunks(batchSize)) {
				// Chunk the total items to process into 500 lot items
				batchesProcessed++;
				
				if (appConfig.verbosityCount == 0) {
					// Dynamic output for a non-verbose run so that the user knows something is happening
					if (!appConfig.surpressLoggingOutput) {
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
				if (!appConfig.surpressLoggingOutput) {
					addLogEntry("\n", ["consoleOnlyNoNewLine"]);
				}
			}
			
			// Free up memory and items processed as it is pointless now having this data around
			jsonItemsToProcess = [];
			
			// Debug output - what was processed
			addLogEntry("Number of JSON items to process is: " ~ to!string(jsonItemsToProcess.length), ["debug"]);
			addLogEntry("Number of JSON items processed was: " ~ to!string(processedCount), ["debug"]);
		} else {
			if (!appConfig.surpressLoggingOutput) {
				addLogEntry("No additional changes or items that can be applied were discovered while processing the data received from Microsoft OneDrive");
			}
		}
		
		// Update the deltaLink in the database so that we can reuse this now that jsonItemsToProcess has been processed
		if (!latestDeltaLink.empty) {
			addLogEntry("Updating completed deltaLink in DB to: " ~ latestDeltaLink, ["debug"]);
			itemDB.setDeltaLink(driveIdToQuery, itemIdToQuery, latestDeltaLink);
		}
		
		// Keep the driveIDsArray with unique entries only
		if (!canFind(driveIDsArray, driveIdToQuery)) {
			// Add this driveId to the array of driveId's we know about
			driveIDsArray ~= driveIdToQuery;
		}		
	}
	
	// Process the /delta API JSON response items
	void processDeltaJSONItem(JSONValue onedriveJSONItem, ulong nrChanges, int changeCount, ulong responseBundleCount, bool singleDirectoryScope) {
		
		// Variables for this foreach loop
		string thisItemId;
		bool itemIsRoot = false;
		bool handleItemAsRootObject = false;
		bool itemIsDeletedOnline = false;
		bool itemHasParentReferenceId = false;
		bool itemHasParentReferencePath = false;
		bool itemIdMatchesDefaultRootId = false;
		bool itemNameExplicitMatchRoot = false;
		string objectParentDriveId;
		
		addLogEntry("------------------------------------------------------------------", ["debug"]);
		addLogEntry("Processing OneDrive Item " ~ to!string(changeCount) ~ " of " ~ to!string(nrChanges) ~ " from API Response Bundle " ~ to!string(responseBundleCount), ["debug"]);
		addLogEntry("Raw JSON OneDrive Item: " ~ to!string(onedriveJSONItem), ["debug"]);
		
		// What is this item's id
		thisItemId = onedriveJSONItem["id"].str;
		// Is this a deleted item - only calculate this once
		itemIsDeletedOnline = isItemDeleted(onedriveJSONItem);
		
		if(!itemIsDeletedOnline){
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
				addLogEntry("Adding this Raw JSON OneDrive Item to jsonItemsToProcess array for further processing", ["debug"]);
				jsonItemsToProcess ~= onedriveJSONItem;
			}
		}
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
				// Flag to delete
				addLogEntry("Flagging to delete item locally: " ~ to!string(onedriveJSONItem), ["debug"]);
				idsToDelete ~= [thisItemDriveId, thisItemId];
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
			
			// To show this is the processing for this particular item, start off with this breaker line
			addLogEntry("------------------------------------------------------------------", ["debug"]);
			addLogEntry("Processing OneDrive JSON item " ~ to!string(elementCount) ~ " of " ~ to!string(batchElementCount) ~ " as part of JSON Item Batch " ~ to!string(batchGroup) ~ " of " ~ to!string(batchCount), ["debug"]);
			addLogEntry("Raw JSON OneDrive Item: " ~ to!string(onedriveJSONItem), ["debug"]);
			
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
				addLogEntry("New Item calculated full path is: " ~ newItemPath, ["debug"]);
			} else {
				// Parent not in the database
				// Is the parent a 'folder' from another user? ie - is this a 'shared folder' that has been shared with us?
				addLogEntry("Parent ID is not in DB .. ", ["debug"]);
				
				// Why?
				if (thisItemDriveId == appConfig.defaultDriveId) {
					// Flagging as unwanted
					addLogEntry("Flagging as unwanted: thisItemDriveId (" ~ thisItemDriveId ~ "), thisItemParentId (" ~ thisItemParentId ~ ") not in local database", ["debug"]);
					
					if (thisItemParentId in skippedItems) {
						addLogEntry("Reason: thisItemParentId listed within skippedItems", ["debug"]);
					}
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
						
							// Create a DB Tie Record for this parent object
							addLogEntry("Creating a DB Tie for this Personal Shared Folder", ["debug"]);
							
							// DB Tie
							Item parentItem;
							parentItem.driveId = onedriveJSONItem["parentReference"]["driveId"].str;
							parentItem.id = onedriveJSONItem["parentReference"]["id"].str;
							parentItem.name = "root";
							parentItem.type = ItemType.dir;
							parentItem.mtime = remoteItem.mtime;
							parentItem.parentId = null;
							
							// Add this DB Tie parent record to the local database
							addLogEntry("Insert local database with remoteItem parent details: " ~ to!string(parentItem), ["debug"]);
							itemDB.upsert(parentItem);
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
							// Create a DB Tie Record for this parent object
							addLogEntry("Creating a DB Tie for this Business Shared Folder", ["debug"]);
							
							// DB Tie
							Item parentItem;
							parentItem.driveId = onedriveJSONItem["parentReference"]["driveId"].str;
							parentItem.id = onedriveJSONItem["parentReference"]["id"].str;
							parentItem.name = "root";
							parentItem.type = ItemType.dir;
							parentItem.mtime = remoteItem.mtime;
							parentItem.parentId = null;
							
							// Add this DB Tie parent record to the local database
							addLogEntry("Insert local database with remoteItem parent details: " ~ to!string(parentItem), ["debug"]);
							itemDB.upsert(parentItem);
							
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
							addLogEntry("Handling a SharePoint Shared Item JSON object - NOT IMPLEMENTED ........ ", ["debug"]);
	
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
							addLogEntry("Skipping item - excluded by skip_dir config: " ~ matchDisplay, ["verbose"]);
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
							addLogEntry("Skipping item - file path is excluded by skip_dir config: " ~ newItemPath, ["verbose"]);
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
						if (unwanted) addLogEntry("Skipping item - excluded by skip_file config: " ~ thisItemName, ["verbose"]);
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
					addLogEntry("sync_list item to check: " ~ newItemPath, ["debug"]);
					
					// Unfortunatly there is no avoiding this call to check if the path is excluded|included via sync_list
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
							addLogEntry("Skipping item - excluded by sync_list config: " ~ newItemPath, ["verbose"]);
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
							addLogEntry("Skipping item - excluded by skip_size config: " ~ thisItemName ~ " (" ~ to!string(onedriveJSONItem["size"].integer/2^^20) ~ " MB)", ["verbose"]);
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
					string existingItemPath = computeItemPath(existingDatabaseItem.driveId, existingDatabaseItem.parentId) ~ "/" ~ existingDatabaseItem.name;
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
			addLogEntry("Number of items to download from OneDrive: " ~ to!string(fileJSONItemsToDownload.length), ["verbose"]);
			downloadOneDriveItems();
			// Cleanup array memory
			fileJSONItemsToDownload = [];
		}
		
		// Are there any skipped items still?
		if (!skippedItems.empty) {
			// Cleanup array memory
			skippedItems.clear();
		}
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
							safeBackup(newItemPath, dryRun);
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
							safeBackup(newItemPath, dryRun);							
						}
					}
					
					// Are the timestamps equal?
					if (localModifiedTime == itemModifiedTime) {
						// yes they are equal
						addLogEntry("File timestamps are equal, no further action required", ["verbose"]); // correct message as timestamps are equal
						return;
					}
				}
			}
		} 
			
		// Path does not exist locally (should not exist locally if renamed file) - this will be a new file download or new folder creation
		// How to handle this Potentially New Local Item JSON ?
		final switch (newDatabaseItem.type) {
			case ItemType.file:
				// Add to the items to download array for processing
				fileJSONItemsToDownload ~= onedriveJSONItem;
				break;
			case ItemType.dir:
			case ItemType.remote:
				addLogEntry("Creating local directory: " ~ newItemPath);
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
				break;
			case ItemType.unknown:
				// Unknown type - we dont action or sync these items
				break;
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
							safeBackup(changedItemPath, dryRun);
						}
					} else {
						// The to be overwritten item is not already in the itemdb, so it should saved to avoid data loss
						addLogEntry("The destination is occupied by an existing un-synced file, renaming the conflicting file...", ["verbose"]);
						// Backup this item, passing in if we are performing a --dry-run or not
						safeBackup(changedItemPath, dryRun);
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
			// Is it a file, and we did not move it ..
			if ((changedOneDriveItem.type == ItemType.file) && (!itemWasMoved)) {
				// The eTag is notorious for being 'changed' online by some backend Microsoft process
				if (existingDatabaseItem.quickXorHash != changedOneDriveItem.quickXorHash) {
					// Add to the items to download array for processing - the file hash we previously recorded is not the same as online
					fileJSONItemsToDownload ~= onedriveJSONItem;
				} else {
					// If the timestamp is different, or we are running a client operational mode that does not support /delta queries - we have to update the DB with the details from OneDrive
					// Unfortunatly because of the consequence of Nataional Cloud Deployments not supporting /delta queries, the application uses the local database to flag what is out-of-date / track changes
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
			// Unfortunatly because of the consequence of Nataional Cloud Deployments not supporting /delta queries, the application uses the local database to flag what is out-of-date / track changes
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
		ulong batchSize = appConfig.getValueLong("threads");
		ulong batchCount = (fileJSONItemsToDownload.length + batchSize - 1) / batchSize;
		ulong batchesProcessed = 0;
		
		foreach (chunk; fileJSONItemsToDownload.chunks(batchSize)) {
			// send an array containing 'appConfig.getValueLong("threads")' JSON items to download
			downloadOneDriveItemsInParallel(chunk);
		}
	}
	
	// Download items in parallel
	void downloadOneDriveItemsInParallel(JSONValue[] array) {
		// This function recieved an array of 16 JSON items to download
		foreach (i, onedriveJSONItem; taskPool.parallel(array)) {
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
		
		// Download item specifics
		string downloadDriveId = onedriveJSONItem["parentReference"]["driveId"].str;
		string downloadParentId = onedriveJSONItem["parentReference"]["id"].str;
		string downloadItemName = onedriveJSONItem["name"].str;
		string downloadItemId = onedriveJSONItem["id"].str;
	
		// Calculate this items path
		string newItemPath = computeItemPath(downloadDriveId, downloadParentId) ~ "/" ~ downloadItemName;
		addLogEntry("New Item calculated full path is: " ~ newItemPath, ["debug"]);
		
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
		
			// Is this a --download-only scenario?
			if (appConfig.getValueBool("download_only")) {
				if (exists(newItemPath)) {
					// file exists locally already
					Item databaseItem;
					bool fileFoundInDB = false;
					
					foreach (driveId; driveIDsArray) {
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
						safeBackup(newItemPath, dryRun);
					}
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
				addLogEntry("Downloading file " ~ newItemPath ~ " ... failed!");
				addLogEntry("Insufficient local disk space to download file");
				downloadFailed = true;
			} else {
				// If we are in a --dry-run situation - if not, actually perform the download
				if (!dryRun) {
					// Attempt to download the file as there is enough free space locally
					OneDriveApi downloadFileOneDriveApiInstance;
					downloadFileOneDriveApiInstance = new OneDriveApi(appConfig);
					try {	
						downloadFileOneDriveApiInstance.initialise();
						downloadFileOneDriveApiInstance.downloadById(downloadDriveId, downloadItemId, newItemPath, jsonFileSize);
						downloadFileOneDriveApiInstance.shutdown();
						// Free object and memory
						object.destroy(downloadFileOneDriveApiInstance);
					} catch (OneDriveException exception) {
						addLogEntry("downloadFileOneDriveApiInstance.downloadById(downloadDriveId, downloadItemId, newItemPath, jsonFileSize); generated a OneDriveException", ["debug"]);
						string thisFunctionName = getFunctionName!({});
						
						// HTTP request returned status code 408,429,503,504
						if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 429) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
							// Handle the 429
							if (exception.httpStatusCode == 429) {
								// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
								handleOneDriveThrottleRequest(downloadFileOneDriveApiInstance);
								addLogEntry("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - attempting to retry " ~ thisFunctionName, ["debug"]);
							}
							// re-try the specific changes queries
							if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
								// 408 - Request Time Out
								// 503 - Service Unavailable
								// 504 - Gateway Timeout
								// Transient error - try again in 30 seconds
								auto errorArray = splitLines(exception.msg);
								addLogEntry(to!string(errorArray[0]) ~ " when attempting to download an item from OneDrive - retrying applicable request in 30 seconds");
								addLogEntry(thisFunctionName ~ " previously threw an error - retrying", ["debug"]);
								
								// The server, while acting as a proxy, did not receive a timely response from the upstream server it needed to access in attempting to complete the request. 
								addLogEntry("Thread sleeping for 30 seconds as the server did not receive a timely response from the upstream server it needed to access in attempting to complete the request", ["debug"]);
								Thread.sleep(dur!"seconds"(30));
							}
							// re-try original request - retried for 429, 503, 504 - but loop back calling this function 
							addLogEntry("Retrying Function: " ~ thisFunctionName, ["debug"]);
							downloadFileItem(onedriveJSONItem);
						} else {
							// Default operation if not 408,429,503,504 errors
							// display what the error is
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
									addLogEntry("ERROR: File download size mis-match. Increase logging verbosity to determine why.");
								}
								// Hash Error
								if (downloadedFileHash != onlineFileHash) {
									// downloaded file hash does not match
									downloadValueMismatch = true;
									addLogEntry("Actual local file hash:     " ~ downloadedFileHash, ["debug"]);
									addLogEntry("OneDrive API reported hash: " ~ onlineFileHash, ["debug"]);
									addLogEntry("ERROR: File download hash mis-match. Increase logging verbosity to determine why.");
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
								// We do not want this local file to remain on the local file system as it failed the integrity checks
								addLogEntry("Removing file " ~ newItemPath ~ " due to failed integrity checks");
								if (!dryRun) {
									safeRemove(newItemPath);
								}
								downloadFailed = true;
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
				addLogEntry("Downloading file " ~ newItemPath ~ " ... done");
				// Save this item into the database
				saveItem(onedriveJSONItem);
				
				// If we are in a --dry-run situation - if we are, we need to track that we faked the download
				if (dryRun) {
					// track that we 'faked it'
					idsFaked ~= [downloadDriveId, downloadItemId];
				}
			} else {
				// Output download failed
				addLogEntry("Downloading file " ~ newItemPath ~ " ... failed!");
				// Add the path to a list of items that failed to download
				fileDownloadFailures ~= newItemPath;
			}
		}
	}
	
	// Test if the given item is in-sync. Returns true if the given item corresponds to the local one
	bool isItemSynced(Item item, string path, string itemSource) {
	
		// This function is typically called when we are processing JSON objects from 'online'
		// This function is not used in an --upload-only scenario
		
		if (!exists(path)) return false;
		final switch (item.type) {
		case ItemType.file:
			if (isFile(path)) {
				// can we actually read the local file?
				if (readLocalFile(path)){
					// local file is readable
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
							// Test if the local timestamp is newer
							if (localModifiedTime > itemModifiedTime) {
								// Local file is newer .. are we in a --download-only situation?
								if (!appConfig.getValueBool("download_only")) {
									// --download-only not being used
									// The source of the out-of-date timestamp was OneDrive and this needs to be corrected to avoid always generating a hash test if timestamp is different
									addLogEntry("The source of the incorrect timestamp was OneDrive online - correcting timestamp online", ["verbose"]);
									if (!dryRun) {
										// Attempt to update the online date time stamp
										uploadLastModifiedTime(item.driveId, item.id, localModifiedTime.toUTC(), item.eTag);
										return false;
									}									
								} else {	
									// --download-only is being used ... local file needs to be corrected ... but why is it newer - indexing application potentially changing the timestamp ?
									addLogEntry("The source of the incorrect timestamp was the local file - correcting timestamp locally due to --download-only", ["verbose"]);
									if (!dryRun) {
										addLogEntry("Calling setTimes() for this file: " ~ path, ["debug"]);
										setTimes(path, item.mtime, item.mtime);
										return false;
									}
								}
							} else {
								// The source of the out-of-date timestamp was the local file and this needs to be corrected to avoid always generating a hash test if timestamp is different
								addLogEntry("The source of the incorrect timestamp was the local file - correcting timestamp locally", ["verbose"]);
								if (!dryRun) {
									addLogEntry("Calling setTimes() for this file: " ~ path, ["debug"]);
									setTimes(path, item.mtime, item.mtime);
									return false;
								}
							}
						} else {
							// The hash is different so the content of the file has to be different as to what is stored online
							addLogEntry("The local file has a different hash when compared to " ~ itemSource ~ " file hash", ["verbose"]);
							return false;
						}
					}
				} else {
					// Unable to read local file
					addLogEntry("Unable to determine the sync state of this file as it cannot be read (file permissions or file corruption): " ~ path);
					return false;
				}
			} else {
				addLogEntry("The local item is a directory but should be a file", ["verbose"]);
			}
			break;
		case ItemType.dir:
		case ItemType.remote:
			if (isDir(path)) {
				return true;
			} else {
				addLogEntry("The local item is a file but should be a directory", ["verbose"]);
			}
			break;
		case ItemType.unknown:
			// Unknown type - return true but we dont action or sync these items 
			return true;
		}
		return false;
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
			deltaChangesBundle = getDeltaQueryOneDriveApiInstance.viewChangesByItemId(selectedDriveId, selectedItemId, providedDeltaLink);
		} catch (OneDriveException exception) {
			// caught an exception
			addLogEntry("getDeltaQueryOneDriveApiInstance.viewChangesByItemId(selectedDriveId, selectedItemId, providedDeltaLink) generated a OneDriveException", ["debug"]);
			
			auto errorArray = splitLines(exception.msg);
			string thisFunctionName = getFunctionName!({});
			// HTTP request returned status code 408,429,503,504
			if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 429) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
				// Handle the 429
				if (exception.httpStatusCode == 429) {
					// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
					handleOneDriveThrottleRequest(getDeltaQueryOneDriveApiInstance);
					addLogEntry("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - attempting to retry " ~ thisFunctionName, ["debug"]);
				}
				// re-try the specific changes queries
				if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
					// 408 - Request Time Out
					// 503 - Service Unavailable
					// 504 - Gateway Timeout
					// Transient error - try again in 30 seconds
					addLogEntry(to!string(errorArray[0]) ~ " when attempting to query OneDrive API for Delta Changes - retrying applicable request in 30 seconds");
					addLogEntry(thisFunctionName ~ " previously threw an error - retrying", ["debug"]);
					
					// The server, while acting as a proxy, did not receive a timely response from the upstream server it needed to access in attempting to complete the request. 
					addLogEntry("Thread sleeping for 30 seconds as the server did not receive a timely response from the upstream server it needed to access in attempting to complete the request", ["debug"]);
					Thread.sleep(dur!"seconds"(30));
				}
				// dont retry request, loop back to calling function
				addLogEntry("Looping back after failure", ["debug"]);
				deltaChangesBundle = null;
			} else {
				// Default operation if not 408,429,503,504 errors
				if (exception.httpStatusCode == 410) {
					addLogEntry();
					addLogEntry("WARNING: The OneDrive API responded with an error that indicates the locally stored deltaLink value is invalid");
					// Essentially the 'providedDeltaLink' that we have stored is no longer available ... re-try without the stored deltaLink
					addLogEntry("WARNING: Retrying OneDrive API call without using the locally stored deltaLink value");
					// Configure an empty deltaLink
					addLogEntry("Delta link expired for 'getDeltaQueryOneDriveApiInstance.viewChangesByItemId(selectedDriveId, selectedItemId, providedDeltaLink)', setting 'deltaLink = null'", ["debug"]);
					string emptyDeltaLink = "";
					// retry with empty deltaLink
					deltaChangesBundle = getDeltaQueryOneDriveApiInstance.viewChangesByItemId(selectedDriveId, selectedItemId, emptyDeltaLink);
				} else {
					// display what the error is
					addLogEntry("CODING TO DO: Hitting this failure error output");
					displayOneDriveErrorMessage(exception.msg, thisFunctionName);
					deltaChangesBundle = null;
				}
			}
		}
		
		return deltaChangesBundle;
	}
	
	// Common code to handle a 408 or 429 response from the OneDrive API
	void handleOneDriveThrottleRequest(OneDriveApi activeOneDriveApiInstance) {
		
		// If OneDrive sends a status code 429 then this function will be used to process the Retry-After response header which contains the value by which we need to wait
		addLogEntry("Handling a OneDrive HTTP 429 Response Code (Too Many Requests)", ["debug"]);
		
		// Read in the Retry-After HTTP header as set and delay as per this value before retrying the request
		auto retryAfterValue = activeOneDriveApiInstance.getRetryAfterValue();
		addLogEntry("Using Retry-After Value = " ~ to!string(retryAfterValue), ["debug"]);
		
		// HTTP request returned status code 429 (Too Many Requests)
		// https://github.com/abraunegg/onedrive/issues/133
		// https://github.com/abraunegg/onedrive/issues/815
		
		ulong delayBeforeRetry = 0;
		if (retryAfterValue != 0) {
			// Use the HTTP Response Header Value
			delayBeforeRetry = retryAfterValue;
		} else {
			// Use a 120 second delay as a default given header value was zero
			// This value is based on log files and data when determining correct process for 429 response handling
			delayBeforeRetry = 120;
			// Update that we are over-riding the provided value with a default
			addLogEntry("HTTP Response Header retry-after value was 0 - Using a preconfigured default of: " ~ to!string(delayBeforeRetry), ["debug"]);
		}
		
		// Sleep thread as per request
		addLogEntry("Thread sleeping due to 'HTTP request returned status code 429' - The request has been throttled");
		addLogEntry("Sleeping for " ~ to!string(delayBeforeRetry) ~ " seconds");
		Thread.sleep(dur!"seconds"(delayBeforeRetry));
		
		// Reset retry-after value to zero as we have used this value now and it may be changed in the future to a different value
		activeOneDriveApiInstance.resetRetryAfterValue();
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

		// What do we display here for space remaining
		if (appConfig.remainingFreeSpace > 0) {
			// Display the actual value
			addLogEntry("Remaining Free Space: " ~ to!string(byteToGibiByte(appConfig.remainingFreeSpace)) ~ " GB (" ~ to!string(appConfig.remainingFreeSpace) ~ " bytes)", ["verbose"]);
		} else {
			// zero or non-zero value or restricted
			if (!appConfig.quotaRestricted){
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
					addLogEntry("Trying to delete file " ~ path);
				} else {
					addLogEntry("Trying to delete directory " ~ path);
				}
			}
			
			// Process the database entry removal. In a --dry-run scenario, this is being done against a DB copy
			itemDB.deleteById(item.driveId, item.id);
			if (item.remoteDriveId != null) {
				// delete the linked remote folder
				itemDB.deleteById(item.remoteDriveId, item.remoteId);
			}
			
			// Add to pathFakeDeletedArray
			// We dont want to try and upload this item again, so we need to track this object
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
					addLogEntry("Deleting file " ~ path);
				} else {
					addLogEntry("Deleting directory " ~ path);
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
	
	// Update the timestamp of an object online
	void uploadLastModifiedTime(string driveId, string id, SysTime mtime, string eTag) {
		
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
			eTagValue = null;
		} else {
			eTagValue = eTag;
		}
		
		JSONValue response;
		// Create a new OneDrive API instance
		OneDriveApi uploadLastModifiedTimeApiInstance;
		uploadLastModifiedTimeApiInstance = new OneDriveApi(appConfig);
		uploadLastModifiedTimeApiInstance.initialise();
		
		// Try and update the online last modified time
		try {
			// Use this instance
			response = uploadLastModifiedTimeApiInstance.updateById(driveId, id, data, eTagValue);
			// Shut the instance down
			uploadLastModifiedTimeApiInstance.shutdown();
			// Free object and memory
			object.destroy(uploadLastModifiedTimeApiInstance);
			// Is the response a valid JSON object - validation checking done in saveItem
			saveItem(response);
		} catch (OneDriveException exception) {
			
			string thisFunctionName = getFunctionName!({});
			// HTTP request returned status code 408,429,503,504
			if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 429) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
				// Handle the 429
				if (exception.httpStatusCode == 429) {
					// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
					handleOneDriveThrottleRequest(uploadLastModifiedTimeApiInstance);
					addLogEntry("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - attempting to retry " ~ thisFunctionName, ["debug"]);
				}
				// re-try the specific changes queries
				if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
					// 408 - Request Time Out
					// 503 - Service Unavailable
					// 504 - Gateway Timeout
					// Transient error - try again in 30 seconds
					auto errorArray = splitLines(exception.msg);
					addLogEntry(to!string(errorArray[0]) ~ " when attempting to update the timestamp on an item on OneDrive - retrying applicable request in 30 seconds");
					addLogEntry(thisFunctionName ~ " previously threw an error - retrying", ["debug"]);
					
					// The server, while acting as a proxy, did not receive a timely response from the upstream server it needed to access in attempting to complete the request. 
					addLogEntry("Thread sleeping for 30 seconds as the server did not receive a timely response from the upstream server it needed to access in attempting to complete the request", ["debug"]);
					Thread.sleep(dur!"seconds"(30));
				}
				// re-try original request - retried for 429, 503, 504 - but loop back calling this function 
				addLogEntry("Retrying Function: " ~ thisFunctionName, ["debug"]);
				uploadLastModifiedTime(driveId, id, mtime, eTag);
				return;
			} else {
				// Default operation if not 408,429,503,504 errors
				if (exception.httpStatusCode == 409) {
					// ETag does not match current item's value - use a null eTag
					addLogEntry("Retrying Function: " ~ thisFunctionName, ["debug"]);
					uploadLastModifiedTime(driveId, id, mtime, null);
				} else {
					// display what the error is
					displayOneDriveErrorMessage(exception.msg, getFunctionName!({}));
				}
			}
		}
	}
	
	// Perform a database integrity check - checking all the items that are in-sync at the moment, validating what we know should be on disk, to what is actually on disk
	void performDatabaseConsistencyAndIntegrityCheck() {
		
		// Log what we are doing
		if (!appConfig.surpressLoggingOutput) {
			addProcessingLogHeaderEntry("Performing a database consistency and integrity check on locally stored data");
		}
		
		// What driveIDsArray do we use? If we are doing a --single-directory we need to use just the drive id associated with that operation
		string[] consistencyCheckDriveIdsArray;
		if (singleDirectoryScope) {
			consistencyCheckDriveIdsArray ~= singleDirectoryScopeDriveId;
		} else {
			consistencyCheckDriveIdsArray = driveIDsArray;
		}
		
		// Create a new DB blank item
		Item item;
		// Use the array we populate, rather than selecting all distinct driveId's from the database
		foreach (driveId; consistencyCheckDriveIdsArray) {
			// Make the logging more accurate - we cant update driveId as this then breaks the below queries
			addLogEntry("Processing DB entries for this Drive ID: " ~ driveId, ["verbose"]);
			
			// What OneDrive API query do we use?
			// - Are we running against a National Cloud Deployments that does not support /delta ?
			//   National Cloud Deployments do not support /delta as a query
			//   https://docs.microsoft.com/en-us/graph/deployments#supported-features
			//
			// - Are we performing a --single-directory sync, which will exclude many items online, focusing in on a specific online directory
			// 
			// - Are we performing a --download-only --cleanup-local-files action?
			//
			// If we did, we self generated a /delta response, thus need to now process elements that are still flagged as out-of-sync
			if ((singleDirectoryScope) || (nationalCloudDeployment) || (cleanupLocalFiles)) {
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
						
				// Fetch database items associated with this path
				Item[] driveItems;
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
				auto driveItems = itemDB.selectByDriveId(driveId);
				addLogEntry("Database items to process for this driveId: " ~ to!string(driveItems.count), ["debug"]);
				
				// Process each database database item associated with the driveId
				foreach(dbItem; driveItems) {
					// Does it still exist on disk in the location the DB thinks it is
					checkDatabaseItemForConsistency(dbItem);
				}
			}
		}

		// Close out the '....' being printed to the console
		addLogEntry("\n", ["consoleOnlyNoNewLine"]);
		
		// Are we doing a --download-only sync?
		if (!appConfig.getValueBool("download_only")) {
			// Do we have any known items, where the content has changed locally, that needs to be uploaded?
			if (!databaseItemsWhereContentHasChanged.empty) {
				// There are changed local files that were in the DB to upload
				addLogEntry("Changed local items to upload to OneDrive: " ~ to!string(databaseItemsWhereContentHasChanged.length));
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
		addLogEntry("Processing " ~ logOutputPath, ["verbose"]);
		// Add a processing '.'
		addProcessingDotEntry();
		
		// Determine which action to take
		final switch (dbItem.type) {
		case ItemType.file:
			// Logging output
			checkFileDatabaseItemForConsistency(dbItem, localFilePath);
			break;
		case ItemType.dir:
			// Logging output
			checkDirectoryDatabaseItemForConsistency(dbItem, localFilePath);
			break;
		case ItemType.remote:
			// checkRemoteDirectoryDatabaseItemForConsistency(dbItem, localFilePath);
			break;
		case ItemType.unknown:
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
						addLogEntry("The local item has a different modified time " ~ to!string(localModifiedTime) ~ " when compared to " ~ itemSource ~ " modified time " ~ to!string(itemModifiedTime), ["debug"]);
						
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
								addLogEntry("The local item has the same hash value as the item online - correcting timestamp online", ["verbose"]);
								if (!dryRun) {
									// Attempt to update the online date time stamp
									uploadLastModifiedTime(dbItem.driveId, dbItem.id, localModifiedTime.toUTC(), dbItem.eTag);
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
				// Upload to OneDrive the instruction to delete this item. This will handle the 'noRemoteDelete' flag if set
				uploadDeletedItem(dbItem, localFilePath);
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
					// Upload to OneDrive the instruction to delete this item. This will handle the 'noRemoteDelete' flag if set
					uploadDeletedItem(dbItem, localFilePath);
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
						foreach (Item child; itemDB.selectChildren(dbItem.driveId, dbItem.id)) {
							checkDatabaseItemForConsistency(child);
						}
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
				// Upload to OneDrive the instruction to delete this item. This will handle the 'noRemoteDelete' flag if set
				uploadDeletedItem(dbItem, localFilePath);
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
					// Upload to OneDrive the instruction to delete this item. This will handle the 'noRemoteDelete' flag if set
					uploadDeletedItem(dbItem, localFilePath);
				} else {
					// When we are using --single-directory, we use a the getChildren() call to get all children of a path, meaning all children are already traversed
					// Thus, if we traverse the path of this directory .. we end up with double processing & log output .. which is not ideal
					if (!singleDirectoryScope) {
						// loop through the children
						foreach (Item child; itemDB.selectChildren(dbItem.driveId, dbItem.id)) {
							checkDatabaseItemForConsistency(child);
						}
					}
				}
			}
		}
	}
	
	// Does this local path (directory or file) conform with the Microsoft Naming Restrictions? It needs to conform otherwise we cannot create the directory or upload the file.
	bool checkPathAgainstMicrosoftNamingRestrictions(string localFilePath) {
			
		// Check if the given path violates certain Microsoft restrictions and limitations
		// Return a true|false response
		bool invalidPath = false;
		
		// Check path against Microsoft OneDrive restriction and limitations about Windows naming for files and folders
		if (!invalidPath) {
			if (!isValidName(localFilePath)) { // This will return false if this is not a valid name according to the OneDrive API specifications
				addLogEntry("Skipping item - invalid name (Microsoft Naming Convention): " ~ localFilePath, ["info", "notify"]);
				invalidPath = true;
			}
		}
		
		// Check path for bad whitespace items
		if (!invalidPath) {
			if (containsBadWhiteSpace(localFilePath)) { // This will return true if this contains a bad whitespace item
				addLogEntry("Skipping item - invalid name (Contains an invalid whitespace item): " ~ localFilePath, ["info", "notify"]);
				invalidPath = true;
			}
		}
		
		// Check path for HTML ASCII Codes
		if (!invalidPath) {
			if (containsASCIIHTMLCodes(localFilePath)) { // This will return true if this contains HTML ASCII Codes
				addLogEntry("Skipping item - invalid name (Contains HTML ASCII Code): " ~ localFilePath, ["info", "notify"]);
				invalidPath = true;
			}
		}
		
		// Validate that the path is a valid UTF-16 encoded path
		if (!invalidPath) {
			if (!isValidUTF16(localFilePath)) { // This will return true if this is a valid UTF-16 encoded path, so we are checking for 'false' as response
				addLogEntry("Skipping item - invalid name (Invalid UTF-16 encoded item): " ~ localFilePath, ["info", "notify"]);
				invalidPath = true;
			}
		}
		
		// Check path for ASCII Control Codes
		if (!invalidPath) {
			if (containsASCIIControlCodes(localFilePath)) { // This will return true if this contains ASCII Control Codes
				addLogEntry("Skipping item - invalid name (Contains ASCII Control Codes): " ~ localFilePath, ["info", "notify"]);
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
							addLogEntry("Skipping item - excluded by skip_dir config: " ~ localFilePath, ["verbose"]);
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
						addLogEntry("Skipping item - excluded by skip_file config: " ~ localFilePath, ["verbose"]);
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
								addLogEntry("Skipping item - excluded by sync_list config: " ~ localFilePath, ["verbose"]);
								clientSideRuleExcludesPath = true;
							} else {
								// skipped for some other reason
								addLogEntry("Skipping item - path excluded by user config: " ~ localFilePath, ["verbose"]);
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
						addLogEntry("Skipping item - excluded by skip_size config: " ~ localFilePath ~ " (" ~ to!string(thisFileSize/2^^20) ~ " MB)", ["verbose"]);
					}
				}
			}
		}
		
		return clientSideRuleExcludesPath;
	}
	
	// Does this JSON item (as received from OneDrive API) get excluded from any operation based on any client side filtering rules?
	// This function is only used when we are fetching objects from the OneDrive API using a /children query to help speed up what object we query
	bool checkJSONAgainstClientSideFiltering(JSONValue onedriveJSONItem) {
			
		bool clientSideRuleExcludesPath = false;
		
		// Check the path against client side filtering rules
		// - check_nosync (MISSING)
		// - skip_dotfiles (MISSING)
		// - skip_symlinks (MISSING)
		// - skip_file
		// - skip_dir 
		// - sync_list
		// - skip_size (MISSING)
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
						addLogEntry("Skipping item - excluded by skip_dir config: " ~ matchDisplay, ["verbose"]);
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
					addLogEntry("Skipping item - excluded by skip_file config: " ~ exclusionTestPath, ["verbose"]);
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
						auto splitIndex = selfBuiltPath.indexOf(":");
						if (splitIndex != -1) {
							// Keep only the part after ':'
							selfBuiltPath = selfBuiltPath[splitIndex + 1 .. $];
						}
						
						// Set newItemPath to the self built path
						newItemPath = selfBuiltPath;
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
				
				// Update newItemPath
				if(newItemPath[0] == '/') {
					newItemPath = newItemPath[1..$];
				}
				
				// What path are we checking?
				addLogEntry("sync_list item to check: " ~ newItemPath, ["debug"]);
				
				// Unfortunatly there is no avoiding this call to check if the path is excluded|included via sync_list
				if (selectiveSync.isPathExcludedViaSyncList(newItemPath)) {
					// selective sync advised to skip, however is this a file and are we configured to upload / download files in the root?
					if ((isItemFile(onedriveJSONItem)) && (appConfig.getValueBool("sync_root_files")) && (rootName(newItemPath) == "") ) {
						// This is a file
						// We are configured to sync all files in the root
						// This is a file in the logical root
						clientSideRuleExcludesPath = false;
					} else {
						// path is unwanted
						clientSideRuleExcludesPath = true;
						addLogEntry("Skipping item - excluded by sync_list config: " ~ newItemPath, ["verbose"]);
					}
				}
			}
		}
		
		// return if path is excluded
		return clientSideRuleExcludesPath;
	}
	
	// Process the list of local changes to upload to OneDrive
	void processChangedLocalItemsToUpload() {
		
		// Each element in this array 'databaseItemsWhereContentHasChanged' is an Database Item ID that has been modified locally
		ulong batchSize = appConfig.getValueLong("threads");
		ulong batchCount = (databaseItemsWhereContentHasChanged.length + batchSize - 1) / batchSize;
		ulong batchesProcessed = 0;
		
		// For each batch of files to upload, upload the changed data to OneDrive
		foreach (chunk; databaseItemsWhereContentHasChanged.chunks(batchSize)) {
			processChangedLocalItemsToUploadInParallel(chunk);
		}
	}

	// Upload the changed file batches in parallel
	void processChangedLocalItemsToUploadInParallel(string[3][] array) {
		foreach (i, localItemDetails; taskPool.parallel(array)) {
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
		
		addLogEntry("uploadChangedLocalFileToOneDrive: " ~ localFilePath, ["debug"]);
		
		// How much space is remaining on OneDrive
		ulong remainingFreeSpace;
		// Did the upload fail?
		bool uploadFailed = false;
		// Did we skip due to exceeding maximum allowed size?
		bool skippedMaxSize = false;
		// Did we skip to an exception error?
		bool skippedExceptionError = false;
		
		// Unfortunatly, we cant store an array of Item's ... so we have to re-query the DB again - unavoidable extra processing here
		// This is because the Item[] has no other functions to allow is to parallel process those elements, so we have to use a string array as input to this function
		Item dbItem;
		itemDB.selectById(changedItemParentId, changedItemId, dbItem);
	
		// Query the available space online
		// This will update appConfig.quotaAvailable & appConfig.quotaRestricted values
		remainingFreeSpace = getRemainingFreeSpace(dbItem.driveId);
		
		// Get the file size from the actual file
		ulong thisFileSizeLocal = getSize(localFilePath);
		// Get the file size from the DB data
		ulong thisFileSizeFromDB;
		if (!dbItem.size.empty) {
			thisFileSizeFromDB = to!ulong(dbItem.size);
		} else {
			thisFileSizeFromDB = 0;
		}
		
		// remainingFreeSpace online includes the current file online
		// we need to remove the online file (add back the existing file size) then take away the new local file size to get a new approximate value
		ulong calculatedSpaceOnlinePostUpload = (remainingFreeSpace + thisFileSizeFromDB) - thisFileSizeLocal;
		
		// Based on what we know, for this thread - can we safely upload this modified local file?
		addLogEntry("This Thread Current Free Space Online:                " ~ to!string(remainingFreeSpace), ["debug"]);
		addLogEntry("This Thread Calculated Free Space Online Post Upload: " ~ to!string(calculatedSpaceOnlinePostUpload), ["debug"]);
	
		JSONValue uploadResponse;
		
		bool spaceAvailableOnline = false;
		// If 'personal' accounts, if driveId == defaultDriveId, then we will have data - appConfig.quotaAvailable will be updated
		// If 'personal' accounts, if driveId != defaultDriveId, then we will not have quota data - appConfig.quotaRestricted will be set as true
		// If 'business' accounts, if driveId == defaultDriveId, then we will have data
		// If 'business' accounts, if driveId != defaultDriveId, then we will have data, but it will be a 0 value - appConfig.quotaRestricted will be set as true
		
		// What was the latest getRemainingFreeSpace() value?
		if (appConfig.quotaAvailable) {
			// Our query told us we have free space online .. if we upload this file, will we exceed space online - thus upload will fail during upload?
			if (calculatedSpaceOnlinePostUpload > 0) {
				// Based on this thread action, we beleive that there is space available online to upload - proceed
				spaceAvailableOnline = true;
			}
		}
		// Is quota being restricted?
		if (appConfig.quotaRestricted) {
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
				addLogEntry("Skipping uploading modified file " ~ localFilePath ~ " due to insufficient free space available on Microsoft OneDrive", ["info", "notify"]);
			}
			// File exceeds max allowed size
			if (skippedMaxSize) {
				addLogEntry("Skipping uploading this modified file as it exceeds the maximum size allowed by OneDrive: " ~ localFilePath, ["info", "notify"]);
			}
			// Generic message
			if (skippedExceptionError) {
				// normal failure message if API or exception error generated
				addLogEntry("Uploading modified file " ~ localFilePath ~ " ... failed!", ["info", "notify"]);
			}
		} else {
			// Upload was successful
			addLogEntry("Uploading modified file " ~ localFilePath ~ " ... done.", ["info", "notify"]);
			
			// Save JSON item in database
			saveItem(uploadResponse);
			
			if (!dryRun) {
				// Check the integrity of the uploaded modified file
				performUploadIntegrityValidationChecks(uploadResponse, localFilePath, thisFileSizeLocal);
				
				// Update the date / time of the file online to match the local item
				// Get the local file last modified time
				SysTime localModifiedTime = timeLastModified(localFilePath).toUTC();
				localModifiedTime.fracSecs = Duration.zero;
				// Get the latest eTag, and use that
				string etagFromUploadResponse = uploadResponse["eTag"].str;
				// Attempt to update the online date time stamp based on our local data
				uploadLastModifiedTime(dbItem.driveId, dbItem.id, localModifiedTime, etagFromUploadResponse);
			}
		}
	}
	
	// Perform the upload of a locally modified file to OneDrive
	JSONValue performModifiedFileUpload(Item dbItem, string localFilePath, ulong thisFileSizeLocal) {
			
		JSONValue uploadResponse;
		OneDriveApi uploadFileOneDriveApiInstance;
		uploadFileOneDriveApiInstance = new OneDriveApi(appConfig);
		uploadFileOneDriveApiInstance.initialise();
		
		// Is this a dry-run scenario?
		if (!dryRun) {
			// Do we use simpleUpload or create an upload session?
			bool useSimpleUpload = false;
			
			//if ((appConfig.accountType == "personal") && (thisFileSizeLocal <= sessionThresholdFileSize)) {
			
			if (thisFileSizeLocal <= sessionThresholdFileSize) {
				useSimpleUpload = true;
			}
		
			// We can only upload zero size files via simpleFileUpload regardless of account type
			// Reference: https://github.com/OneDrive/onedrive-api-docs/issues/53
			// Additionally, all files where file size is < 4MB should be uploaded by simpleUploadReplace - everything else should use a session to upload the modified file
		
			if ((thisFileSizeLocal == 0) || (useSimpleUpload)) {
				// Must use Simple Upload to replace the file online
				try {
					uploadResponse = uploadFileOneDriveApiInstance.simpleUploadReplace(localFilePath, dbItem.driveId, dbItem.id);
				} catch (OneDriveException exception) {
				
					string thisFunctionName = getFunctionName!({});
					// HTTP request returned status code 408,429,503,504
					if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 429) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
						// Handle the 429
						if (exception.httpStatusCode == 429) {
							// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
							handleOneDriveThrottleRequest(uploadFileOneDriveApiInstance);
							addLogEntry("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - attempting to retry " ~ thisFunctionName, ["debug"]);
						}
						// re-try the specific changes queries
						if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
							// 408 - Request Time Out
							// 503 - Service Unavailable
							// 504 - Gateway Timeout
							// Transient error - try again in 30 seconds
							auto errorArray = splitLines(exception.msg);
							addLogEntry(to!string(errorArray[0]) ~ " when attempting to upload a modified file to OneDrive - retrying applicable request in 30 seconds");
							addLogEntry(thisFunctionName ~ " previously threw an error - retrying", ["debug"]);
							
							// The server, while acting as a proxy, did not receive a timely response from the upstream server it needed to access in attempting to complete the request. 
							addLogEntry("Thread sleeping for 30 seconds as the server did not receive a timely response from the upstream server it needed to access in attempting to complete the request", ["debug"]);
							Thread.sleep(dur!"seconds"(30));
						}
						// re-try original request - retried for 429, 503, 504 - but loop back calling this function 
						addLogEntry("Retrying Function: " ~ thisFunctionName, ["debug"]);
						performModifiedFileUpload(dbItem, localFilePath, thisFileSizeLocal);
					} else {
						// Default operation if not 408,429,503,504 errors
						// display what the error is
						displayOneDriveErrorMessage(exception.msg, getFunctionName!({}));
					}
				
				} catch (FileException e) {
					// filesystem error
					displayFileSystemErrorMessage(e.msg, getFunctionName!({}));
				}
			} else {
				// Configure JSONValue variables we use for a session upload
				JSONValue currentOnlineData;
				JSONValue uploadSessionData;
				string currentETag;
				
				// As this is a unique thread, the sessionFilePath for where we save the data needs to be unique
				// The best way to do this is generate a 10 digit alphanumeric string, and use this as the file extention
				string threadUploadSessionFilePath = appConfig.uploadSessionFilePath ~ "." ~ generateAlphanumericString();
				
				// Get the absolute latest object details from online
				try {
					currentOnlineData = uploadFileOneDriveApiInstance.getPathDetailsByDriveId(dbItem.driveId, localFilePath);
				} catch (OneDriveException exception) {
				
					string thisFunctionName = getFunctionName!({});
					// HTTP request returned status code 408,429,503,504
					if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 429) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
						// Handle the 429
						if (exception.httpStatusCode == 429) {
							// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
							handleOneDriveThrottleRequest(uploadFileOneDriveApiInstance);
							addLogEntry("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - attempting to retry " ~ thisFunctionName, ["debug"]);
						}
						// re-try the specific changes queries
						if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
							// 408 - Request Time Out
							// 503 - Service Unavailable
							// 504 - Gateway Timeout
							// Transient error - try again in 30 seconds
							auto errorArray = splitLines(exception.msg);
							addLogEntry(to!string(errorArray[0]) ~ " when attempting to obtain latest file details from OneDrive - retrying applicable request in 30 seconds");
							addLogEntry(thisFunctionName ~ " previously threw an error - retrying", ["debug"]);
							
							// The server, while acting as a proxy, did not receive a timely response from the upstream server it needed to access in attempting to complete the request.
							addLogEntry("Thread sleeping for 30 seconds as the server did not receive a timely response from the upstream server it needed to access in attempting to complete the request", ["debug"]);
							Thread.sleep(dur!"seconds"(30));
						}
						// re-try original request - retried for 429, 503, 504 - but loop back calling this function 
						addLogEntry("Retrying Function: " ~ thisFunctionName, ["debug"]);
						performModifiedFileUpload(dbItem, localFilePath, thisFileSizeLocal);
					} else {
						// Default operation if not 408,429,503,504 errors
						// display what the error is
						displayOneDriveErrorMessage(exception.msg, getFunctionName!({}));
					}
					
				}
				
				// Was a valid JSON response provided?
				if (currentOnlineData.type() == JSONType.object) {
					// Does the response contain an eTag?
					if (hasETag(currentOnlineData)) {
						// Use the value returned from online
						currentETag = currentOnlineData["eTag"].str;
					} else {
						// Use the database value
						currentETag = dbItem.eTag;
					}
				} else {
					// no valid JSON response
					currentETag = dbItem.eTag;
				}
				
				// Create the Upload Session
				try {
					uploadSessionData = createSessionFileUpload(uploadFileOneDriveApiInstance, localFilePath, dbItem.driveId, dbItem.parentId, baseName(localFilePath), currentETag, threadUploadSessionFilePath);
				} catch (OneDriveException exception) {
					
					string thisFunctionName = getFunctionName!({});
					// HTTP request returned status code 408,429,503,504
					if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 429) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
						// Handle the 429
						if (exception.httpStatusCode == 429) {
							// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
							handleOneDriveThrottleRequest(uploadFileOneDriveApiInstance);
							addLogEntry("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - attempting to retry " ~ thisFunctionName, ["debug"]);
						}
						// re-try the specific changes queries
						if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
							// 408 - Request Time Out
							// 503 - Service Unavailable
							// 504 - Gateway Timeout
							// Transient error - try again in 30 seconds
							auto errorArray = splitLines(exception.msg);
							addLogEntry(to!string(errorArray[0]) ~ " when attempting to create an upload session on OneDrive - retrying applicable request in 30 seconds");
							addLogEntry(thisFunctionName ~ " previously threw an error - retrying", ["debug"]);
							
							// The server, while acting as a proxy, did not receive a timely response from the upstream server it needed to access in attempting to complete the request. 
							addLogEntry("Thread sleeping for 30 seconds as the server did not receive a timely response from the upstream server it needed to access in attempting to complete the request", ["debug"]);
							Thread.sleep(dur!"seconds"(30));
						}
						// re-try original request - retried for 429, 503, 504 - but loop back calling this function 
						addLogEntry("Retrying Function: " ~ thisFunctionName, ["debug"]);
						performModifiedFileUpload(dbItem, localFilePath, thisFileSizeLocal);
					} else {
						// Default operation if not 408,429,503,504 errors
						// display what the error is
						displayOneDriveErrorMessage(exception.msg, getFunctionName!({}));
					}
					
				} catch (FileException e) {
					writeln("DEBUG TO REMOVE: Modified file upload FileException Handling (Create the Upload Session)");
					displayFileSystemErrorMessage(e.msg, getFunctionName!({}));
				}
				
				// Perform the Upload using the session
				try {
					uploadResponse = performSessionFileUpload(uploadFileOneDriveApiInstance, thisFileSizeLocal, uploadSessionData, threadUploadSessionFilePath);
				} catch (OneDriveException exception) {
					
					string thisFunctionName = getFunctionName!({});
					// HTTP request returned status code 408,429,503,504
					if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 429) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
						// Handle the 429
						if (exception.httpStatusCode == 429) {
							// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
							handleOneDriveThrottleRequest(uploadFileOneDriveApiInstance);
							addLogEntry("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - attempting to retry " ~ thisFunctionName, ["debug"]);
						}
						// re-try the specific changes queries
						if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
							// 408 - Request Time Out
							// 503 - Service Unavailable
							// 504 - Gateway Timeout
							// Transient error - try again in 30 seconds
							auto errorArray = splitLines(exception.msg);
							addLogEntry(to!string(errorArray[0]) ~ " when attempting to upload a file via a session to OneDrive - retrying applicable request in 30 seconds");
							addLogEntry(thisFunctionName ~ " previously threw an error - retrying", ["debug"]);
							// The server, while acting as a proxy, did not receive a timely response from the upstream server it needed to access in attempting to complete the request. 
							addLogEntry("Thread sleeping for 30 seconds as the server did not receive a timely response from the upstream server it needed to access in attempting to complete the request", ["debug"]);
							Thread.sleep(dur!"seconds"(30));
						}
						// re-try original request - retried for 429, 503, 504 - but loop back calling this function 
						addLogEntry("Retrying Function: " ~ thisFunctionName, ["debug"]);
						performModifiedFileUpload(dbItem, localFilePath, thisFileSizeLocal);
					} else {
						// Default operation if not 408,429,503,504 errors
						// display what the error is
						displayOneDriveErrorMessage(exception.msg, getFunctionName!({}));
					}
					
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
		
		// Shutdown the API instance
		uploadFileOneDriveApiInstance.shutdown();
		// Free object and memory
		object.destroy(uploadFileOneDriveApiInstance);
		// Return JSON
		return uploadResponse;
	}
		
	// Query the OneDrive API using the provided driveId to get the latest quota details
	ulong getRemainingFreeSpace(string driveId) {
				
		// Get the quota details for this driveId, as this could have changed since we started the application - the user could have added / deleted data online, or purchased additional storage
		// Quota details are ONLY available for the main default driveId, as the OneDrive API does not provide quota details for shared folders
		
		JSONValue currentDriveQuota;
		ulong remainingQuota;
		
		// Ensure that we have a valid driveId
		if (driveId.empty) {
			// no driveId was provided, use the application default
			driveId = appConfig.defaultDriveId;
		}
		
		// Try and query the quota for the provided driveId
		try {
			// Create a new OneDrive API instance
			OneDriveApi getCurrentDriveQuotaApiInstance;
			getCurrentDriveQuotaApiInstance = new OneDriveApi(appConfig);
			getCurrentDriveQuotaApiInstance.initialise();
			addLogEntry("Seeking available quota for this drive id: " ~ driveId, ["debug"]);
			currentDriveQuota = getCurrentDriveQuotaApiInstance.getDriveQuota(driveId);
			// Shut this API instance down
			getCurrentDriveQuotaApiInstance.shutdown();
			// Free object and memory
			object.destroy(getCurrentDriveQuotaApiInstance);
		} catch (OneDriveException e) {
			addLogEntry("currentDriveQuota = onedrive.getDriveQuota(driveId) generated a OneDriveException", ["debug"]);
		}
		
		// validate that currentDriveQuota is a JSON value
		if (currentDriveQuota.type() == JSONType.object) {
			// Response from API contains valid data
			// If 'personal' accounts, if driveId == defaultDriveId, then we will have data
			// If 'personal' accounts, if driveId != defaultDriveId, then we will not have quota data
			// If 'business' accounts, if driveId == defaultDriveId, then we will have data
			// If 'business' accounts, if driveId != defaultDriveId, then we will have data, but it will be a 0 value
			
			if ("quota" in currentDriveQuota){
				if (driveId == appConfig.defaultDriveId) {
					// We potentially have updated quota remaining details available
					// However in some cases OneDrive Business configurations 'restrict' quota details thus is empty / blank / negative value / zero
					if ("remaining" in currentDriveQuota["quota"]){
						// We have valid quota remaining details returned for the provided drive id
						remainingQuota = currentDriveQuota["quota"]["remaining"].integer;
						
						if (remainingQuota <= 0) {
							if (appConfig.accountType == "personal"){
								// zero space available
								addLogEntry("ERROR: OneDrive account currently has zero space available. Please free up some space online or purchase additional space.");
								remainingQuota = 0;
								appConfig.quotaAvailable = false;
							} else {
								// zero space available is being reported, maybe being restricted?
								addLogEntry("WARNING: OneDrive quota information is being restricted or providing a zero value. Please fix by speaking to your OneDrive / Office 365 Administrator.");
								remainingQuota = 0;
								appConfig.quotaRestricted = true;
							}
						}
					}
				} else {
					// quota details returned, but for a drive id that is not ours
					if ("remaining" in currentDriveQuota["quota"]){
						// remaining is in the quota JSON response					
						if (currentDriveQuota["quota"]["remaining"].integer <= 0) {
							// value returned is 0 or less than 0
							addLogEntry("OneDrive quota information is set at zero, as this is not our drive id, ignoring", ["verbose"]);
							remainingQuota = 0;
							appConfig.quotaRestricted = true;
						}
					}
				}
			} else {
				// No quota details returned
				if (driveId == appConfig.defaultDriveId) {
					// no quota details returned for current drive id
					addLogEntry("ERROR: OneDrive quota information is missing. Potentially your OneDrive account currently has zero space available. Please free up some space online or purchase additional space.");
					remainingQuota = 0;
					appConfig.quotaRestricted = true;
				} else {
					// quota details not available
					addLogEntry("WARNING: OneDrive quota information is being restricted as this is not our drive id.", ["debug"]);
					remainingQuota = 0;
					appConfig.quotaRestricted = true;
				}
			}
		}
		
		// what was the determined available quota?
		addLogEntry("Available quota: " ~ to!string(remainingQuota), ["debug"]);
		return remainingQuota;
	}
	
	// Perform a filesystem walk to uncover new data to upload to OneDrive
	void scanLocalFilesystemPathForNewData(string path) {
		// Cleanup array memory before we start adding files
		newLocalFilesToUploadToOneDrive = [];
		
		// Perform a filesystem walk to uncover new data
		scanLocalFilesystemPathForNewDataToUpload(path);
		
		// Upload new data that has been identified
		processNewLocalItemsToUpload();
	}

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
			if (!appConfig.surpressLoggingOutput) {
				if (!cleanupLocalFiles) {
					addProcessingLogHeaderEntry("Scanning the local file system '" ~ logPath ~ "' for new data to upload");
				} else {
					addProcessingLogHeaderEntry("Scanning the local file system '" ~ logPath ~ "' for data to cleanup");
				}
			}
		}
		
		auto startTime = Clock.currTime();
		addLogEntry("Starting Filesystem Walk:     " ~ to!string(startTime), ["debug"]);
	
		// Perform the filesystem walk of this path, building an array of new items to upload
		scanPathForNewData(path);
		addLogEntry("\n", ["consoleOnlyNoNewLine"]);
		
		// To finish off the processing items, this is needed to reflect this in the log
		addLogEntry("------------------------------------------------------------------", ["debug"]);
		
		auto finishTime = Clock.currTime();
		addLogEntry("Finished Filesystem Walk:     " ~ to!string(finishTime), ["debug"]);
		
		auto elapsedTime = finishTime - startTime;
		addLogEntry("Elapsed Time Filesystem Walk: " ~ to!string(elapsedTime), ["debug"]);
	}
	
	// Perform a filesystem walk to uncover new data to upload to OneDrive
	void processNewLocalItemsToUpload() {
		// Upload new data that has been identified
		// Are there any items to download post fetching the /delta data?
		if (!newLocalFilesToUploadToOneDrive.empty) {
			// There are elements to upload
			addProcessingLogHeaderEntry("New items to upload to OneDrive: " ~ to!string(newLocalFilesToUploadToOneDrive.length));
			
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
			
			// How much space is available (Account Drive ID)
			// The file, could be uploaded to a shared folder, which, we are not tracking how much free space is available there ... 
			addLogEntry("Current Available Space Online (Account Drive ID): " ~ to!string((appConfig.remainingFreeSpace / 1024 / 1024)) ~ " MB", ["debug"]);
			
			// Perform the upload
			uploadNewLocalFileItems();
			
			// Cleanup array memory after uploading all files
			newLocalFilesToUploadToOneDrive = [];
		}
	}
	
	// Scan this path for new data
	void scanPathForNewData(string path) {
		// Add a processing '.'
		addProcessingDotEntry();

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
		
		// A short lived item that has already disappeared will cause an error - is the path still valid?
		if (!exists(path)) {
			addLogEntry("Skipping item - path has disappeared: " ~ path);
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
					unwanted = checkPathAgainstClientSideFiltering(path);
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
							createDirectoryOnline(path);
						} else {
							// we need to clean up this directory
							addLogEntry("Removing local directory as --download-only & --cleanup-local-files configured");
							// Remove any children of this path if they still exist
							// Resolve 'Directory not empty' error when deleting local files
							try {
								foreach (DirEntry child; dirEntries(path, SpanMode.depth, false)) {
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
								// Remove the path now that it is empty of children
								addLogEntry("Removing local directory: " ~ path);
								// are we in a --dry-run scenario?
								if (!dryRun) {
									// No --dry-run ... process local delete
									try {
										rmdirRecurse(path);
									} catch (FileException e) {
										// display the error message
										displayFileSystemErrorMessage(e.msg, getFunctionName!({}));
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
							skipFolderTraverse = true;
						}
					}
					
					// Do we traverse this path?
					if (!skipFolderTraverse) {
						// Try and access this directory and any path below
						try {
							auto entries = dirEntries(path, SpanMode.shallow, false);
							foreach (DirEntry entry; entries) {
								string thisPath = entry.name;
								scanPathForNewData(thisPath);
							}
						} catch (FileException e) {
							// display the error message
							displayFileSystemErrorMessage(e.msg, getFunctionName!({}));
							return;
						}
					}
				} else {
					// https://github.com/abraunegg/onedrive/issues/984
					// path is not a directory, is it a valid file?
					// pipes - whilst technically valid files, are not valid for this client
					//  prw-rw-r--.  1 user user    0 Jul  7 05:55 my_pipe
					if (isFile(path)) {
						// Was the file found in the database?
						if (!itemFoundInDB) {
							// File not found in database when searching all drive id's
							// Do we upload the file or clean up the file?
							if (!cleanupLocalFiles) {
								// --download-only --cleanup-local-files not used
								// Add this path as a file we need to upload
								addLogEntry("OneDrive Client flagging to upload this file to OneDrive: " ~ path, ["debug"]);
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
			Item databaseItem;
			bool fileFoundInDB = false;
			
			foreach (driveId; driveIDsArray) {
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
		}
		processNewLocalItemsToUpload();
	}
	
	// Query the database to determine if this path is within the existing database
	bool pathFoundInDatabase(string searchPath) {
		
		// Check if this path in the database
		Item databaseItem;
		addLogEntry("Search DB for this path: " ~ searchPath, ["debug"]);
		foreach (driveId; driveIDsArray) {
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
		
		Item parentItem;
		JSONValue onlinePathData;
		
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
			
			foreach (driveId; driveIDsArray) {
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
						// HTTP request returned status code 408,429,503,504
						if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 429) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
							// Handle the 429
							if (exception.httpStatusCode == 429) {
								// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
								handleOneDriveThrottleRequest(createDirectoryOnlineOneDriveApiInstance);
								addLogEntry("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - attempting to retry " ~ thisFunctionName, ["debug"]);
							}
							// re-try the specific changes queries
							if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
								// 408 - Request Time Out
								// 503 - Service Unavailable
								// 504 - Gateway Timeout
								// Transient error - try again in 30 seconds
								auto errorArray = splitLines(exception.msg);
								addLogEntry(to!string(errorArray[0]) ~ " when attempting to create a remote directory on OneDrive - retrying applicable request in 30 seconds");
								addLogEntry(thisFunctionName ~ " previously threw an error - retrying", ["debug"]);
								
								// The server, while acting as a proxy, did not receive a timely response from the upstream server it needed to access in attempting to complete the request. 
								addLogEntry("Thread sleeping for 30 seconds as the server did not receive a timely response from the upstream server it needed to access in attempting to complete the request", ["debug"]);
								Thread.sleep(dur!"seconds"(30));
							}
							// re-try original request - retried for 429, 503, 504 - but loop back calling this function 
							addLogEntry("Retrying Function: " ~ thisFunctionName, ["debug"]);
							createDirectoryOnline(thisNewPathToCreate);
						} else {
							// Default operation if not 408,429,503,504 errors
							// display what the error is
							displayOneDriveErrorMessage(exception.msg, thisFunctionName);
						}
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
			// In a --local-first scenario, a Shared Folder will be 'remote' so we need to check the remote parent id, rather than parentItem details
			Item queryItem;
			
			if ((appConfig.getValueBool("local_first")) &&  (parentItem.type == ItemType.remote)) {
				// We are --local-first scenario and this folder is a potential shared object
				addLogEntry("--localfirst & parentItem is a remote item object", ["debug"]);
			
				queryItem.driveId = parentItem.remoteDriveId;
				queryItem.id = parentItem.remoteId;
				
				// Need to create the DB Tie for this object
				addLogEntry("Creating a DB Tie for this Shared Folder", ["debug"]);
				// New DB Tie Item to bind the 'remote' path to our parent path
				Item tieDBItem;
				// Set the name
				tieDBItem.name = parentItem.name;
				// Set the correct item type
				tieDBItem.type = ItemType.dir;
				// Set the right elements using the 'remote' of the parent as the 'actual' for this DB Tie
				tieDBItem.driveId = parentItem.remoteDriveId;
				tieDBItem.id = parentItem.remoteId;
				// Set the correct mtime
				tieDBItem.mtime = parentItem.mtime;
				// Add tie DB record to the local database
				addLogEntry("Adding DB Tie record to database: " ~ to!string(tieDBItem), ["debug"]);
				itemDB.upsert(tieDBItem);
				
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
							
							if (childAsLower == thisFolderNameAsLower) {	
								// This is a POSIX 'case in-sensitive match' ..... 
								// Local item name has a 'case-insensitive match' to an existing item on OneDrive
								addLogEntry("Path we are searching for exists online (POSIX 'case in-sensitive match'): " ~ baseName(thisNewPathToCreate), ["debug"]);
								addLogEntry("childJSON: " ~ to!string(childJSON), ["debug"]);
								foundDirectoryOnline = true;
								foundDirectoryJSONItem = childJSON;
								break;
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
				
				// Build up the create directory request
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
						
						// Is this a Personal Account and is the item a Remote Object (Shared Folder) ?
						if ((appConfig.accountType == "personal") && (parentItem.type == ItemType.remote)) {
							// Yes .. Shared Folder
							addLogEntry("parentItem data: " ~ to!string(parentItem), ["debug"]);
							requiredDriveId = parentItem.remoteDriveId;
							requiredParentItemId = parentItem.remoteId;
						} else {
							// Not a personal account + Shared Folder
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
							// Shutdown API instance
							createDirectoryOnlineOneDriveApiInstance.shutdown();
							// Free object and memory
							object.destroy(createDirectoryOnlineOneDriveApiInstance);
							return;
						} else {
							// some other error from OneDrive was returned - display what it is
							addLogEntry("OneDrive generated an error when creating this path: " ~ thisNewPathToCreate);
							displayOneDriveErrorMessage(exception.msg, getFunctionName!({}));
							// Shutdown API instance
							createDirectoryOnlineOneDriveApiInstance.shutdown();
							// Free object and memory
							object.destroy(createDirectoryOnlineOneDriveApiInstance);
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
				
				// Shutdown API instance
				createDirectoryOnlineOneDriveApiInstance.shutdown();
				// Free object and memory
				object.destroy(createDirectoryOnlineOneDriveApiInstance);
				return;
				
			} else {
			
				string thisFunctionName = getFunctionName!({});
				// HTTP request returned status code 408,429,503,504
				if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 429) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
					// Handle the 429
					if (exception.httpStatusCode == 429) {
						// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
						handleOneDriveThrottleRequest(createDirectoryOnlineOneDriveApiInstance);
						addLogEntry("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - attempting to retry " ~ thisFunctionName, ["debug"]);
					}
					// re-try the specific changes queries
					if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
						// 408 - Request Time Out
						// 503 - Service Unavailable
						// 504 - Gateway Timeout
						// Transient error - try again in 30 seconds
						auto errorArray = splitLines(exception.msg);
						addLogEntry(to!string(errorArray[0]) ~ " when attempting to create a remote directory on OneDrive - retrying applicable request in 30 seconds");
						addLogEntry(thisFunctionName ~ " previously threw an error - retrying", ["debug"]);
						
						// The server, while acting as a proxy, did not receive a timely response from the upstream server it needed to access in attempting to complete the request. 
						addLogEntry("Thread sleeping for 30 seconds as the server did not receive a timely response from the upstream server it needed to access in attempting to complete the request", ["debug"]);
						Thread.sleep(dur!"seconds"(30));
					}
					// re-try original request - retried for 429, 503, 504 - but loop back calling this function 
					addLogEntry("Retrying Function: " ~ thisFunctionName, ["debug"]);
					createDirectoryOnline(thisNewPathToCreate);
				} else {
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
		}
		
		// If we get to this point - onlinePathData = createDirectoryOnlineOneDriveApiInstance.getPathDetailsByDriveId(parentItem.driveId, thisNewPathToCreate) generated a 'valid' response ....
		// This means that the folder potentially exists online .. which is odd .. as it should not have existed
		if (onlinePathData.type() == JSONType.object) {
			// A valid object was responded with
			if (onlinePathData["name"].str == baseName(thisNewPathToCreate)) {
				// OneDrive 'name' matches local path name
				if (appConfig.accountType == "business") {
					// We are a business account, this existing online folder, could be a Shared Online Folder and is the 'Add shortcut to My files' item
					addLogEntry("onlinePathData: " ~ to!string(onlinePathData), ["debug"]);
					
					if (isItemRemote(onlinePathData)) {
						// The folder is a remote item ... we do not want to create this ...
						addLogEntry("Remote Existing Online Folder is most likely a OneDrive Shared Business Folder Link added by 'Add shortcut to My files'", ["debug"]);
						addLogEntry("We need to skip this path: " ~ thisNewPathToCreate, ["debug"]);
						
						// Add this path to businessSharedFoldersOnlineToSkip
						businessSharedFoldersOnlineToSkip ~= [thisNewPathToCreate];
						// no save to database, no online create
						// Shutdown API instance
						createDirectoryOnlineOneDriveApiInstance.shutdown();
						// Free object and memory
						object.destroy(createDirectoryOnlineOneDriveApiInstance);
						return;
					}
				}
				
				// Path found online
				addLogEntry("The requested directory to create was found on OneDrive - skipping creating the directory: " ~ thisNewPathToCreate, ["verbose"]);
				
				// Is the response a valid JSON object - validation checking done in saveItem
				saveItem(onlinePathData);
				
				// Shutdown API instance
				createDirectoryOnlineOneDriveApiInstance.shutdown();
				// Free object and memory
				object.destroy(createDirectoryOnlineOneDriveApiInstance);
				return;
			} else {
				// Normally this would throw an error, however we cant use throw new posixException()
				string msg = format("POSIX 'case-insensitive match' between '%s' (local) and '%s' (online) which violates the Microsoft OneDrive API namespace convention", baseName(thisNewPathToCreate), onlinePathData["name"].str);
				displayPosixErrorMessage(msg);
				addLogEntry("ERROR: Requested directory to create has a 'case-insensitive match' to an existing directory on OneDrive online.");
				addLogEntry("ERROR: To resolve, rename this local directory: " ~ buildNormalizedPath(absolutePath(thisNewPathToCreate)));
				addLogEntry("Skipping creating this directory online due to 'case-insensitive match': " ~ thisNewPathToCreate);
				// Add this path to posixViolationPaths
				posixViolationPaths ~= [thisNewPathToCreate];
				// Shutdown API instance
				createDirectoryOnlineOneDriveApiInstance.shutdown();
				// Free object and memory
				object.destroy(createDirectoryOnlineOneDriveApiInstance);
				return;
			}
		} else {
			// response is not valid JSON, an error was returned from OneDrive
			addLogEntry("ERROR: There was an error performing this operation on Microsoft OneDrive");
			addLogEntry("ERROR: Increase logging verbosity to assist determining why.");
			addLogEntry("Skipping: " ~ buildNormalizedPath(absolutePath(thisNewPathToCreate)));
			// Shutdown API instance
			createDirectoryOnlineOneDriveApiInstance.shutdown();
			// Free object and memory
			object.destroy(createDirectoryOnlineOneDriveApiInstance);
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
			throw new posixException(localNameToCheck, onlineName);
		}
	}
	
	// Upload new file items as identified
	void uploadNewLocalFileItems() {
		// Lets deal with the new local items in a batch process
		ulong batchSize = appConfig.getValueLong("threads");
		ulong batchCount = (newLocalFilesToUploadToOneDrive.length + batchSize - 1) / batchSize;
		ulong batchesProcessed = 0;
		
		foreach (chunk; newLocalFilesToUploadToOneDrive.chunks(batchSize)) {
			uploadNewLocalFileItemsInParallel(chunk);
		}
		addLogEntry("\n", ["consoleOnlyNoNewLine"]);
	}
	
	// Upload the file batches in parallel
	void uploadNewLocalFileItemsInParallel(string[] array) {
		foreach (i, fileToUpload; taskPool.parallel(array)) {
			// Add a processing '.'
			addProcessingDotEntry();
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
			foreach (driveId; driveIDsArray) {
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
			addLogEntry("parentItem.driveId is empty - using defaultDriveId for upload API calls");
			parentItem.driveId = appConfig.defaultDriveId;
		}
		
		// Check if the path still exists locally before we try to upload
		if (exists(fileToUpload)) {
			// Can we read the file - as a permissions issue or actual file corruption will cause a failure
			// Resolves: https://github.com/abraunegg/onedrive/issues/113
			if (readLocalFile(fileToUpload)) {
				// The local file can be read - so we can read it to attemtp to upload it in this thread
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
						// Is there enough free space on OneDrive when we started this thread, to upload the file to OneDrive?
						remainingFreeSpaceOnline = getRemainingFreeSpace(parentItem.driveId);
						addLogEntry("Current Available Space Online (Upload Target Drive ID): " ~ to!string((remainingFreeSpaceOnline / 1024 / 1024)) ~ " MB", ["debug"]);
						
						// When we compare the space online to the total we are trying to upload - is there space online?
						ulong calculatedSpaceOnlinePostUpload = remainingFreeSpaceOnline - thisFileSize;
						
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
							if (appConfig.quotaAvailable) {
								// Our query told us we have free space online .. if we upload this file, will we exceed space online - thus upload will fail during upload?
								if (calculatedSpaceOnlinePostUpload > 0) {
									// Based on this thread action, we beleive that there is space available online to upload - proceed
									spaceAvailableOnline = true;
								}
							}
						}
						
						// Is quota being restricted?
						if (appConfig.quotaRestricted) {
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
							
							// Create a new API Instance for this thread and initialise it
							OneDriveApi checkFileOneDriveApiInstance;
							checkFileOneDriveApiInstance = new OneDriveApi(appConfig);
							checkFileOneDriveApiInstance.initialise();
							
							JSONValue fileDetailsFromOneDrive;

							// https://docs.microsoft.com/en-us/windows/desktop/FileIO/naming-a-file
							// Do not assume case sensitivity. For example, consider the names OSCAR, Oscar, and oscar to be the same, 
							// even though some file systems (such as a POSIX-compliant file systems that Linux use) may consider them as different.
							// Note that NTFS supports POSIX semantics for case sensitivity but this is not the default behavior, OneDrive does not use this.
							
							// In order to upload this file - this query HAS to respond as a 404 - Not Found
							
							// Does this 'file' already exist on OneDrive?
							try {
								fileDetailsFromOneDrive = checkFileOneDriveApiInstance.getPathDetailsByDriveId(parentItem.driveId, fileToUpload);
								// Portable Operating System Interface (POSIX) testing of JSON response from OneDrive API
								if (hasName(fileDetailsFromOneDrive)) {
									performPosixTest(baseName(fileToUpload), fileDetailsFromOneDrive["name"].str);
								} else {
									throw new jsonResponseException("Unable to perform POSIX test as the OneDrive API request generated an invalid JSON response");
								}
								
								// If we get to this point, the OneDrive API returned a 200 OK with valid JSON data that indicates a 'file' exists at this location already
								// and that it matches the POSIX filename of the local item we are trying to upload as a new file
								addLogEntry("The file we are attemtping to upload as a new file already exists on Microsoft OneDrive: " ~ fileToUpload, ["verbose"]);
								
								// No 404 or otherwise was triggered, meaning that the file already exists online and passes the POSIX test ...
								addLogEntry("fileDetailsFromOneDrive after exist online check: " ~ to!string(fileDetailsFromOneDrive), ["debug"]);
								
								// Does the data from online match our local file that we are attempting to upload as a new file?
								bool raiseWarning = false;
								if (!disableUploadValidation && performUploadIntegrityValidationChecks(fileDetailsFromOneDrive, fileToUpload, thisFileSize, raiseWarning)) {
									// Save online item details to the database
									saveItem(fileDetailsFromOneDrive);
								} else {
									// The local file we are attempting to upload as a new file is different to the existing file online
									addLogEntry("Triggering newfile upload target already exists edge case, where the online item does not match what we are trying to upload", ["debug"]);
									
									// If the 'online' file is newer, this will be overwritten with the file from the local filesystem - consituting online data loss
									// The file 'version history' online will have to be used to 'recover' the prior online file
									string changedItemParentId = fileDetailsFromOneDrive["parentReference"]["driveId"].str;
									string changedItemId = fileDetailsFromOneDrive["id"].str;
									addLogEntry("Skipping uploading this file as moving it to upload as a modified file (online item already exists): " ~ fileToUpload);
									
									// In order for the processing of the local item as a 'changed' item, unfortunatly we need to save the online data to the local DB
									saveItem(fileDetailsFromOneDrive);
									uploadChangedLocalFileToOneDrive([changedItemParentId, changedItemId, fileToUpload]);
								}
							} catch (OneDriveException exception) {
								// If we get a 404 .. the file is not online .. this is what we want .. file does not exist online
								if (exception.httpStatusCode == 404) {
									// The file has been checked, client side filtering checked, does not exist online - we need to upload it
									addLogEntry("fileDetailsFromOneDrive = checkFileOneDriveApiInstance.getPathDetailsByDriveId(parentItem.driveId, fileToUpload); generated a 404 - file does not exist online - must upload it", ["debug"]);
									uploadFailed = performNewFileUpload(parentItem, fileToUpload, thisFileSize);
								} else {
									
									string thisFunctionName = getFunctionName!({});
									// HTTP request returned status code 408,429,503,504
									if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 429) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
										// Handle the 429
										if (exception.httpStatusCode == 429) {
											// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
											handleOneDriveThrottleRequest(checkFileOneDriveApiInstance);
											addLogEntry("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - attempting to retry " ~ thisFunctionName, ["debug"]);
										}
										// re-try the specific changes queries
										if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
											// 408 - Request Time Out
											// 503 - Service Unavailable
											// 504 - Gateway Timeout
											// Transient error - try again in 30 seconds
											auto errorArray = splitLines(exception.msg);
											addLogEntry(to!string(errorArray[0]) ~ " when attempting to validate file details on OneDrive - retrying applicable request in 30 seconds");
											addLogEntry(thisFunctionName ~ " previously threw an error - retrying", ["debug"]);
											
											// The server, while acting as a proxy, did not receive a timely response from the upstream server it needed to access in attempting to complete the request. 
											addLogEntry("Thread sleeping for 30 seconds as the server did not receive a timely response from the upstream server it needed to access in attempting to complete the request", ["debug"]);
											Thread.sleep(dur!"seconds"(30));
										}
										// re-try original request - retried for 429, 503, 504 - but loop back calling this function 
										addLogEntry("Retrying Function: " ~ thisFunctionName, ["debug"]);
										uploadNewFile(fileToUpload);
									} else {
										// Default operation if not 408,429,503,504 errors
										// display what the error is
										displayOneDriveErrorMessage(exception.msg, thisFunctionName);
									}
								}
							} catch (posixException e) {
								displayPosixErrorMessage(e.msg);
								uploadFailed = true;
							} catch (jsonResponseException e) {
								addLogEntry(e.msg, ["debug"]);
								uploadFailed = true;
							}
							
							// Operations in this thread are done / complete - either upload was done or it failed
							checkFileOneDriveApiInstance.shutdown();
							// Free object and memory
							object.destroy(checkFileOneDriveApiInstance);
						} else {
							// skip file upload - insufficent space to upload
							addLogEntry("Skipping uploading this new file as it exceeds the available free space on OneDrive: " ~ fileToUpload);
							uploadFailed = true;
						}
					} else {
						// Skip file upload - too large
						addLogEntry("Skipping uploading this new file as it exceeds the maximum size allowed by OneDrive: " ~ fileToUpload);
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
		if (uploadFailed) {
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
		uploadFileOneDriveApiInstance = new OneDriveApi(appConfig);
		uploadFileOneDriveApiInstance.initialise();
		
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
					// Attempt to upload the zero byte file using simpleUpload for all account types
					uploadResponse = uploadFileOneDriveApiInstance.simpleUpload(fileToUpload, parentItem.driveId, parentItem.id, baseName(fileToUpload));
					uploadFailed = false;
					addLogEntry("Uploading new file " ~ fileToUpload ~ " ... done.");
					// Shutdown the API
					uploadFileOneDriveApiInstance.shutdown();
					// Free object and memory
					object.destroy(uploadFileOneDriveApiInstance);
				} catch (OneDriveException exception) {
					// An error was responded with - what was it
					
					string thisFunctionName = getFunctionName!({});
					// HTTP request returned status code 408,429,503,504
					if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 429) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
						// Handle the 429
						if (exception.httpStatusCode == 429) {
							// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
							handleOneDriveThrottleRequest(uploadFileOneDriveApiInstance);
							addLogEntry("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - attempting to retry " ~ thisFunctionName, ["debug"]);
						}
						// re-try the specific changes queries
						if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
							// 408 - Request Time Out
							// 503 - Service Unavailable
							// 504 - Gateway Timeout
							// Transient error - try again in 30 seconds
							auto errorArray = splitLines(exception.msg);
							addLogEntry(to!string(errorArray[0]) ~ " when attempting to upload a new file to OneDrive - retrying applicable request in 30 seconds");
							addLogEntry(thisFunctionName ~ " previously threw an error - retrying", ["debug"]);
							
							// The server, while acting as a proxy, did not receive a timely response from the upstream server it needed to access in attempting to complete the request. 
							addLogEntry("Thread sleeping for 30 seconds as the server did not receive a timely response from the upstream server it needed to access in attempting to complete the request", ["debug"]);
							Thread.sleep(dur!"seconds"(30));
						}
						// re-try original request - retried for 429, 503, 504 - but loop back calling this function 
						performNewFileUpload(parentItem, fileToUpload, thisFileSize);
						// Return upload status
						return uploadFailed;
					} else {
						// Default operation if not 408,429,503,504 errors
						// display what the error is
						addLogEntry("Uploading new file " ~ fileToUpload ~ " ... failed.");
						displayOneDriveErrorMessage(exception.msg, thisFunctionName);
					}
					
				} catch (FileException e) {
					// display the error message
					addLogEntry("Uploading new file " ~ fileToUpload ~ " ... failed.");
					displayFileSystemErrorMessage(e.msg, getFunctionName!({}));
				}
			} else {
				// Session Upload for this criteria:
				// - Personal Account and file size > 4MB
				// - All Business | Office365 | SharePoint files > 0 bytes
				JSONValue uploadSessionData;
				// As this is a unique thread, the sessionFilePath for where we save the data needs to be unique
				// The best way to do this is generate a 10 digit alphanumeric string, and use this as the file extention
				string threadUploadSessionFilePath = appConfig.uploadSessionFilePath ~ "." ~ generateAlphanumericString();
				
				// Attempt to upload the > 4MB file using an upload session for all account types
				try {
					// Create the Upload Session
					uploadSessionData = createSessionFileUpload(uploadFileOneDriveApiInstance, fileToUpload, parentItem.driveId, parentItem.id, baseName(fileToUpload), null, threadUploadSessionFilePath);
				} catch (OneDriveException exception) {
					// An error was responded with - what was it
					
					string thisFunctionName = getFunctionName!({});
					// HTTP request returned status code 408,429,503,504
					if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 429) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
						// Handle the 429
						if (exception.httpStatusCode == 429) {
							// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
							handleOneDriveThrottleRequest(uploadFileOneDriveApiInstance);
							addLogEntry("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - attempting to retry " ~ thisFunctionName, ["debug"]);
						}
						// re-try the specific changes queries
						if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
							// 408 - Request Time Out
							// 503 - Service Unavailable
							// 504 - Gateway Timeout
							// Transient error - try again in 30 seconds
							auto errorArray = splitLines(exception.msg);
							addLogEntry(to!string(errorArray[0]) ~ " when attempting to create an upload session on OneDrive - retrying applicable request in 30 seconds");
							addLogEntry(thisFunctionName ~ " previously threw an error - retrying", ["debug"]);
							
							// The server, while acting as a proxy, did not receive a timely response from the upstream server it needed to access in attempting to complete the request. 
							addLogEntry("Thread sleeping for 30 seconds as the server did not receive a timely response from the upstream server it needed to access in attempting to complete the request", ["debug"]);
							Thread.sleep(dur!"seconds"(30));
						}
						// re-try original request - retried for 429, 503, 504 - but loop back calling this function 
						addLogEntry("Retrying Function: " ~ thisFunctionName, ["debug"]);
						performNewFileUpload(parentItem, fileToUpload, thisFileSize);
					} else {
						// Default operation if not 408,429,503,504 errors
						// display what the error is
						addLogEntry("Uploading new file " ~ fileToUpload ~ " ... failed.");
						displayOneDriveErrorMessage(exception.msg, thisFunctionName);
					}
					
				} catch (FileException e) {
					// display the error message
					addLogEntry("Uploading new file " ~ fileToUpload ~ " ... failed.");
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
								addLogEntry("Uploading new file " ~ fileToUpload ~ " ... done.");
							} else {
								addLogEntry("Uploading new file " ~ fileToUpload ~ " ... failed.");
								uploadFailed = true;
							}
						} catch (OneDriveException exception) {
						
							string thisFunctionName = getFunctionName!({});
							// HTTP request returned status code 408,429,503,504
							if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 429) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
								// Handle the 429
								if (exception.httpStatusCode == 429) {
									// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
									handleOneDriveThrottleRequest(uploadFileOneDriveApiInstance);
									addLogEntry("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - attempting to retry " ~ thisFunctionName, ["debug"]);
								}
								// re-try the specific changes queries
								if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
									// 408 - Request Time Out
									// 503 - Service Unavailable
									// 504 - Gateway Timeout
									// Transient error - try again in 30 seconds
									auto errorArray = splitLines(exception.msg);
									addLogEntry(to!string(errorArray[0]) ~ " when attempting to upload a new file via a session to OneDrive - retrying applicable request in 30 seconds");
									addLogEntry(thisFunctionName ~ " previously threw an error - retrying", ["debug"]);
									
									// The server, while acting as a proxy, did not receive a timely response from the upstream server it needed to access in attempting to complete the request. 
									addLogEntry("Thread sleeping for 30 seconds as the server did not receive a timely response from the upstream server it needed to access in attempting to complete the request", ["debug"]);
									Thread.sleep(dur!"seconds"(30));
								}
								// re-try original request - retried for 429, 503, 504 - but loop back calling this function 
								addLogEntry("Retrying Function: " ~ thisFunctionName, ["debug"]);
								performNewFileUpload(parentItem, fileToUpload, thisFileSize);
							} else {
								// Default operation if not 408,429,503,504 errors
								// display what the error is
								addLogEntry("Uploading new file " ~ fileToUpload ~ " ... failed.");
								displayOneDriveErrorMessage(exception.msg, thisFunctionName);
							}
						}
					} else {
						// No Upload URL or nextExpectedRanges or localPath .. not a valid JSON we can use
						addLogEntry("Session data is missing required elements to perform a session upload.", ["verbose"]);
						addLogEntry("Uploading new file " ~ fileToUpload ~ " ... failed.");
					}
				} else {
					// Create session Upload URL failed
					addLogEntry("Uploading new file " ~ fileToUpload ~ " ... failed.");
				}
			}
		} else {
			// We are in a --dry-run scenario
			uploadResponse = createFakeResponse(fileToUpload);
			uploadFailed = false;
			addLogEntry("Uploading new file " ~ fileToUpload ~ " ... done.", ["info", "notify"]);
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
				// check if the path still exists locally before we try to set the file times online - as short lived files, whilst we uploaded it - it may not exist locally aready
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
						uploadLastModifiedTime(parentItem.driveId, newFileId, mtime, newFileETag);
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
		ulong fragmentCount = 0;
		ulong fragSize = 0;
		ulong offset = uploadSessionData["nextExpectedRanges"][0].str.splitter('-').front.to!ulong;
		size_t expected_total_fragments = cast(ulong) ceil(double(thisFileSize) / double(fragmentSize));
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
				
				// Handle transient errors:
				//   408 - Request Time Out
				//   429 - Too Many Requests
				//   503 - Service Unavailable
				//   504 - Gateway Timeout
					
				// HTTP request returned status code 408,429,503,504
				if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 429) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
					// Handle 'HTTP request returned status code 429 (Too Many Requests)' first
					addLogEntry("Fragment upload failed - received throttle request uploadResponse from OneDrive", ["debug"]);
					
					if (exception.httpStatusCode == 429) {
						auto retryAfterValue = activeOneDriveApiInstance.getRetryAfterValue();
						addLogEntry("Using Retry-After Value = " ~ to!string(retryAfterValue), ["debug"]);
						
						// Sleep thread as per request
						addLogEntry();
						addLogEntry("Thread sleeping due to 'HTTP request returned status code 429' - The request has been throttled");
						addLogEntry("Sleeping for " ~ to!string(retryAfterValue) ~ " seconds");
						Thread.sleep(dur!"seconds"(retryAfterValue));
						addLogEntry("Retrying fragment upload");
					} else {
						// Handle 408, 503 and 504
						auto errorArray = splitLines(exception.msg);
						auto retryAfterValue = 30;
						addLogEntry();
						addLogEntry("Thread sleeping due to '" ~ to!string(errorArray[0]) ~ "' - retrying applicable request in 30 seconds");
						addLogEntry("Sleeping for " ~ to!string(retryAfterValue) ~ " seconds");
						Thread.sleep(dur!"seconds"(retryAfterValue));
						addLogEntry("Retrying fragment upload");
					}
				} else {
					// insert a new line as well, so that the below error is inserted on the console in the right location
					addLogEntry("Fragment upload failed - received an exception response from OneDrive API", ["verbose"]);
					// display what the error is
					displayOneDriveErrorMessage(exception.msg, getFunctionName!({}));
					// retry fragment upload in case error is transient
					addLogEntry("Retrying fragment upload", ["verbose"]);
				}
				
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
				addLogEntry("Deleting item from OneDrive: " ~ path);
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
				
				// A local delete of a file|folder when using --monitor  will issue a inotify event, which will trigger the local & remote data immediately be deleted
				// The user may also be --sync process, so we are checking if something was deleted between application use
				if (itemsToDelete >= appConfig.getValueLong("classify_as_big_delete")) {
					// A big delete has been detected
					flagAsBigDelete = true;
					if (!appConfig.getValueBool("force")) {
						addLogEntry("ERROR: An attempt to remove a large volume of data from OneDrive has been detected. Exiting client to preserve data on Microsoft OneDrive");
						addLogEntry("ERROR: To delete a large volume of data use --force or increase the config value 'classify_as_big_delete' to a larger value");
						// Must exit here to preserve data on online , allow logging to be done
						forceExit();
					}
				}
				
				// Are we in a --dry-run scenario?
				if (!dryRun) {
					// We are not in a dry run scenario
					addLogEntry("itemToDelete: " ~ to!string(itemToDelete), ["debug"]);
					
					// Create new OneDrive API Instance
					OneDriveApi uploadDeletedItemOneDriveApiInstance;
					uploadDeletedItemOneDriveApiInstance = new OneDriveApi(appConfig);
					uploadDeletedItemOneDriveApiInstance.initialise();
				
					// what item are we trying to delete?
					addLogEntry("Attempting to delete this single item id: " ~ itemToDelete.id ~ " from drive: " ~ itemToDelete.driveId, ["debug"]);
					
					try {
						// perform the delete via the default OneDrive API instance
						uploadDeletedItemOneDriveApiInstance.deleteById(itemToDelete.driveId, itemToDelete.id);
						// Shutdown API
						uploadDeletedItemOneDriveApiInstance.shutdown();
						// Free object and memory
						object.destroy(uploadDeletedItemOneDriveApiInstance);
					} catch (OneDriveException e) {
						if (e.httpStatusCode == 404) {
							// item.id, item.eTag could not be found on the specified driveId
							addLogEntry("OneDrive reported: The resource could not be found to be deleted.", ["verbose"]);
						}
					}
					
					// Delete the reference in the local database
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
		// Shutdown API instance
		performReverseDeletionOneDriveApiInstance.shutdown();
		// Free object and memory
		object.destroy(performReverseDeletionOneDriveApiInstance);
	}
	
	// Create a fake OneDrive response suitable for use with saveItem
	JSONValue createFakeResponse(const(string) path) {
		
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
		SysTime mtime = timeLastModified(path).toUTC();
		
		// Need to update the 'fakeDriveId' & 'fakeRootId' with elements from the --dry-run database
		// Otherwise some calls to validate objects will fail as the actual driveId being used is invalid
		string parentPath = dirName(path);
		Item databaseItem;
		
		if (parentPath != ".") {
			// Not a 'root' parent
			// For each driveid in the existing driveIDsArray 
			foreach (searchDriveId; driveIDsArray) {
				addLogEntry("FakeResponse: searching database for: " ~ searchDriveId ~ " " ~ parentPath, ["debug"]);
				
				if (itemDB.selectByPath(parentPath, searchDriveId, databaseItem)) {
					addLogEntry("FakeResponse: Found Database Item: " ~ to!string(databaseItem), ["debug"]);
					fakeDriveId = databaseItem.driveId;
					fakeRootId = databaseItem.id;
				}
			}
		}
		
		// real id / eTag / cTag are different format for personal / business account
		auto sha1 = new SHA1Digest();
		ubyte[] fakedOneDriveItemValues = sha1.digest(path);
		
		JSONValue fakeResponse;
		
		if (isDir(path)) {
			// path is a directory
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
														]),
							"folder": JSONValue("")
							];
		} else {
			// path is a file
			// compute file hash - both business and personal responses use quickXorHash
			string quickXorHash = computeQuickXorHash(path);
	
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
														]),
							"file": JSONValue([
												"hashes":JSONValue([
																	"quickXorHash": JSONValue(quickXorHash)
																	])
												
												])
							];
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
					addLogEntry("Adding to database: " ~ to!string(item), ["debug"]);
					itemDB.upsert(item);
					
					// If we have a remote drive ID, add this to our list of known drive id's
					if (!item.remoteDriveId.empty) {
						// Keep the driveIDsArray with unique entries only
						if (!canFind(driveIDsArray, item.remoteDriveId)) {
							// Add this drive id to the array to search with
							driveIDsArray ~= item.remoteDriveId;
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
								// This is computationally expensive .. but we are only doing this if there are no hashses provided
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
			
		// Were there any file download failures?
		if (!fileDownloadFailures.empty) {
			// There are download failures ...
			addLogEntry();
			addLogEntry("Failed items to download from OneDrive: " ~ to!string(fileDownloadFailures.length));
			foreach(failedFileToDownload; fileDownloadFailures) {
				// List the detail of the item that failed to download
				addLogEntry("Failed to download: " ~ failedFileToDownload, ["info", "notify"]);
				
				// Is this failed item in the DB? It should not be ..
				Item downloadDBItem;
				// Need to check all driveid's we know about, not just the defaultDriveId
				foreach (searchDriveId; driveIDsArray) {
					if (itemDB.selectByPath(failedFileToDownload, searchDriveId, downloadDBItem)) {
						// item was found in the DB
						addLogEntry("ERROR: Failed Download Path found in database, must delete this item from the database .. it should not be in there if it failed to download");
						// Process the database entry removal. In a --dry-run scenario, this is being done against a DB copy
						itemDB.deleteById(downloadDBItem.driveId, downloadDBItem.id);
						if (downloadDBItem.remoteDriveId != null) {
							// delete the linked remote folder
							itemDB.deleteById(downloadDBItem.remoteDriveId, downloadDBItem.remoteId);
						}	
					}
				}
			}
			// Set the flag
			syncFailures = true;
		}
		
		// Were there any file upload failures?
		if (!fileUploadFailures.empty) {
			// There are download failures ...
			addLogEntry();
			addLogEntry("Failed items to upload to OneDrive: " ~ to!string(fileUploadFailures.length));
			foreach(failedFileToUpload; fileUploadFailures) {
				// List the path of the item that failed to upload
				addLogEntry("Failed to upload: " ~ failedFileToUpload, ["info", "notify"]);
				
				// Is this failed item in the DB? It should not be ..
				Item uploadDBItem;
				// Need to check all driveid's we know about, not just the defaultDriveId
				foreach (searchDriveId; driveIDsArray) {
					if (itemDB.selectByPath(failedFileToUpload, searchDriveId, uploadDBItem)) {
						// item was found in the DB
						addLogEntry("ERROR: Failed Upload Path found in database, must delete this item from the database .. it should not be in there if it failed to upload");
						// Process the database entry removal. In a --dry-run scenario, this is being done against a DB copy
						itemDB.deleteById(uploadDBItem.driveId, uploadDBItem.id);
						if (uploadDBItem.remoteDriveId != null) {
							// delete the linked remote folder
							itemDB.deleteById(uploadDBItem.remoteDriveId, uploadDBItem.remoteId);
						}	
					}
				}
			}
			// Set the flag
			syncFailures = true;
		}
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
		Item searchItem;
		JSONValue rootData;
		JSONValue driveData;
		JSONValue pathData;
		JSONValue topLevelChildren;
		JSONValue[] childrenData;
		string nextLink;
		
		// Was a path to query passed in?
		if (pathToQuery.empty) {
			// Will query for the 'root'
			pathToQuery = ".";
		}
		
		// Create new OneDrive API Instance
		OneDriveApi generateDeltaResponseOneDriveApiInstance;
		generateDeltaResponseOneDriveApiInstance = new OneDriveApi(appConfig);
		generateDeltaResponseOneDriveApiInstance.initialise();
		
		if (!singleDirectoryScope) {
			// In a --resync scenario, there is no DB data to query, so we have to query the OneDrive API here to get relevant details
			try {
				// Query the OneDrive API
				pathData = generateDeltaResponseOneDriveApiInstance.getPathDetails(pathToQuery);
				// Is the path on OneDrive local or remote to our account drive id?
				if (isItemRemote(pathData)) {
					// The path we are seeking is remote to our account drive id
					searchItem.driveId = pathData["remoteItem"]["parentReference"]["driveId"].str;
					searchItem.id = pathData["remoteItem"]["id"].str;
				} else {
					// The path we are seeking is local to our account drive id
					searchItem.driveId = pathData["parentReference"]["driveId"].str;
					searchItem.id = pathData["id"].str;
				}
			} catch (OneDriveException e) {
				// Display error message
				displayOneDriveErrorMessage(e.msg, getFunctionName!({}));
				// Must exit here
				generateDeltaResponseOneDriveApiInstance.shutdown();
				// Free object and memory
				object.destroy(generateDeltaResponseOneDriveApiInstance);
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
		
		auto drivePathChildren = getChildren(searchItem.driveId, searchItem.id);
		if (count(drivePathChildren) > 0) {
			// Children to process and flag as out-of-sync	
			foreach (drivePathChild; drivePathChildren) {
				// Flag any object in the database as out-of-sync for this driveId & and object id
				addLogEntry("Downgrading item as out-of-sync: " ~ drivePathChild.id, ["debug"]);
				itemDB.downgradeSyncStatusFlag(drivePathChild.driveId, drivePathChild.id);
			}
		}
		
		// Get drive details for the provided driveId
		try {
			driveData = generateDeltaResponseOneDriveApiInstance.getPathDetailsById(searchItem.driveId, searchItem.id);
		} catch (OneDriveException exception) {
			addLogEntry("driveData = generateDeltaResponseOneDriveApiInstance.getPathDetailsById(searchItem.driveId, searchItem.id) generated a OneDriveException", ["debug"]);
			
			string thisFunctionName = getFunctionName!({});
			// HTTP request returned status code 408,429,503,504
			if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 429) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
				// Handle the 429
				if (exception.httpStatusCode == 429) {
					// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
					handleOneDriveThrottleRequest(generateDeltaResponseOneDriveApiInstance);
					addLogEntry("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - attempting to retry " ~ thisFunctionName, ["debug"]);
				}
				// re-try the specific changes queries
				if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
					// 408 - Request Time Out
					// 503 - Service Unavailable
					// 504 - Gateway Timeout
					// Transient error - try again in 30 seconds
					auto errorArray = splitLines(exception.msg);
					addLogEntry(to!string(errorArray[0]) ~ " when attempting to query path details on OneDrive - retrying applicable request in 30 seconds");
					addLogEntry(thisFunctionName ~ " previously threw an error - retrying", ["debug"]);
					
					// The server, while acting as a proxy, did not receive a timely response from the upstream server it needed to access in attempting to complete the request. 
					addLogEntry("Thread sleeping for 30 seconds as the server did not receive a timely response from the upstream server it needed to access in attempting to complete the request", ["debug"]);
					Thread.sleep(dur!"seconds"(30));
				}
				// re-try original request - retried for 429, 503, 504 - but loop back calling this function 
				addLogEntry("Retrying Function: " ~ thisFunctionName, ["debug"]);
				generateDeltaResponse(pathToQuery);
			} else {
				// Default operation if not 408,429,503,504 errors
				// display what the error is
				displayOneDriveErrorMessage(exception.msg, thisFunctionName);
			}
		}
		
		// Was a valid JSON response for 'driveData' provided?
		if (driveData.type() == JSONType.object) {
		
			// Dynamic output for a non-verbose run so that the user knows something is happening
			if (appConfig.verbosityCount == 0) {
				if (!appConfig.surpressLoggingOutput) {
					addProcessingLogHeaderEntry("Fetching items from the OneDrive API for Drive ID: " ~ searchItem.driveId);
				}
			} else {
				addLogEntry("Generating a /delta response from the OneDrive API for Drive ID: " ~ searchItem.driveId, ["verbose"]);
			}
		
			// Process this initial JSON response
			if (!isItemRoot(driveData)) {
				// Get root details for the provided driveId
				try {
					rootData = generateDeltaResponseOneDriveApiInstance.getDriveIdRoot(searchItem.driveId);
				} catch (OneDriveException exception) {
					addLogEntry("rootData = onedrive.getDriveIdRoot(searchItem.driveId) generated a OneDriveException", ["debug"]);
					
					string thisFunctionName = getFunctionName!({});
					// HTTP request returned status code 408,429,503,504
					if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 429) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
						// Handle the 429
						if (exception.httpStatusCode == 429) {
							// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
							handleOneDriveThrottleRequest(generateDeltaResponseOneDriveApiInstance);
							addLogEntry("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - attempting to retry " ~ thisFunctionName, ["debug"]);
						}
						// re-try the specific changes queries
						if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
							// 408 - Request Time Out
							// 503 - Service Unavailable
							// 504 - Gateway Timeout
							// Transient error - try again in 30 seconds
							auto errorArray = splitLines(exception.msg);
							addLogEntry(to!string(errorArray[0]) ~ " when attempting to query drive root details on OneDrive - retrying applicable request in 30 seconds");
							addLogEntry(thisFunctionName ~ " previously threw an error - retrying", ["debug"]);
							
							// The server, while acting as a proxy, did not receive a timely response from the upstream server it needed to access in attempting to complete the request. 
							addLogEntry("Thread sleeping for 30 seconds as the server did not receive a timely response from the upstream server it needed to access in attempting to complete the request", ["debug"]);
							Thread.sleep(dur!"seconds"(30));
						}
						// re-try original request - retried for 429, 503, 504 - but loop back calling this function 
						addLogEntry("Retrying Query: rootData = generateDeltaResponseOneDriveApiInstance.getDriveIdRoot(searchItem.driveId)");
						rootData = generateDeltaResponseOneDriveApiInstance.getDriveIdRoot(searchItem.driveId);
					} else {
						// Default operation if not 408,429,503,504 errors
						// display what the error is
						displayOneDriveErrorMessage(exception.msg, thisFunctionName);
					}
				}
				// Add driveData JSON data to array
				addLogEntry("Adding OneDrive root details for processing", ["verbose"]);
				childrenData ~= rootData;
			}
			
			// Add driveData JSON data to array
			addLogEntry("Adding OneDrive folder details for processing", ["verbose"]);
			childrenData ~= driveData;
		} else {
			// driveData is an invalid JSON object
			writeln("CODING TO DO: The query of OneDrive API to getPathDetailsById generated an invalid JSON response - thus we cant build our own /delta simulated response ... how to handle?");
			// Must exit here
			generateDeltaResponseOneDriveApiInstance.shutdown();
			// Free object and memory
			object.destroy(generateDeltaResponseOneDriveApiInstance);
			// Must force exit here, allow logging to be done
			forceExit();
		}
		
		// For each child object, query the OneDrive API
		for (;;) {
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
				// HTTP request returned status code 408,429,503,504
				if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 429) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
					// Handle the 429
					if (exception.httpStatusCode == 429) {
						// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
						handleOneDriveThrottleRequest(generateDeltaResponseOneDriveApiInstance);
						addLogEntry("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - attempting to retry topLevelChildren = generateDeltaResponseOneDriveApiInstance.listChildren(searchItem.driveId, searchItem.id, nextLink)", ["debug"]);
					}
					// re-try the specific changes queries
					if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
						// 408 - Request Time Out
						// 503 - Service Unavailable
						// 504 - Gateway Timeout
						// Transient error - try again in 30 seconds
						auto errorArray = splitLines(exception.msg);
						addLogEntry(to!string(errorArray[0]) ~ " when attempting to query OneDrive top level drive children on OneDrive - retrying applicable request in 30 seconds");
						addLogEntry("generateDeltaResponseOneDriveApiInstance.listChildren(searchItem.driveId, searchItem.id, nextLink) previously threw an error - retrying", ["debug"]);
						
						// The server, while acting as a proxy, did not receive a timely response from the upstream server it needed to access in attempting to complete the request. 
						addLogEntry("Thread sleeping for 30 seconds as the server did not receive a timely response from the upstream server it needed to access in attempting to complete the request", ["debug"]);
						Thread.sleep(dur!"seconds"(30));
					}
					// re-try original request - retried for 429, 503, 504 - but loop back calling this function 
					addLogEntry("Retrying Function: " ~ thisFunctionName, ["debug"]);
					generateDeltaResponse(pathToQuery);
				} else {
					// Default operation if not 408,429,503,504 errors
					// display what the error is
					displayOneDriveErrorMessage(exception.msg, thisFunctionName);
				}
			}
			
			// process top level children
			addLogEntry("Adding " ~ to!string(count(topLevelChildren["value"].array)) ~ " OneDrive items for processing from the OneDrive 'root' folder", ["verbose"]);
			
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
		}
		
		if (appConfig.verbosityCount == 0) {
			// Dynamic output for a non-verbose run so that the user knows something is happening
			if (!appConfig.surpressLoggingOutput) {
				addLogEntry("\n", ["consoleOnlyNoNewLine"]);
			}
		}
		
		// Craft response from all returned JSON elements
		selfGeneratedDeltaResponse = [
						"@odata.context": JSONValue("https://graph.microsoft.com/v1.0/$metadata#Collection(driveItem)"),
						"value": JSONValue(childrenData.array)
						];
		
		// Shutdown API
		generateDeltaResponseOneDriveApiInstance.shutdown();
		// Free object and memory
		object.destroy(generateDeltaResponseOneDriveApiInstance);
		
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
		
		for (;;) {
			// query this level children
			try {
				thisLevelChildren = queryThisLevelChildren(driveId, idToQuery, nextLink, queryChildrenOneDriveApiInstance);
			} catch (OneDriveException exception) {
				
				writeln("CODING TO DO: EXCEPTION HANDLING NEEDED: thisLevelChildren = queryThisLevelChildren(driveId, idToQuery, nextLink, queryChildrenOneDriveApiInstance)");
			
			}
			
			if (appConfig.verbosityCount == 0) {
				// Dynamic output for a non-verbose run so that the user knows something is happening
				if (!appConfig.surpressLoggingOutput) {
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
					// Plus, the application output now shows accuratly what is being shared - so that is a good thing.
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
		}
		
		// Shutdown API instance
		queryChildrenOneDriveApiInstance.shutdown();
		// Free object and memory
		object.destroy(queryChildrenOneDriveApiInstance);
		
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
			// HTTP request returned status code 408,429,503,504
			if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 429) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
				// Handle the 429
				if (exception.httpStatusCode == 429) {
					// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
					handleOneDriveThrottleRequest(queryChildrenOneDriveApiInstance);
					addLogEntry("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - attempting to retry " ~ thisFunctionName, ["debug"]);
				}
				// re-try the specific changes queries
				if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
					// 408 - Request Time Out
					// 503 - Service Unavailable
					// 504 - Gateway Timeout
					// Transient error - try again in 30 seconds
					auto errorArray = splitLines(exception.msg);
					addLogEntry(to!string(errorArray[0]) ~ " when attempting to query OneDrive drive item children - retrying applicable request in 30 seconds");
					addLogEntry("thisLevelChildren = queryChildrenOneDriveApiInstance.listChildren(driveId, idToQuery, nextLink) previously threw an error - retrying", ["debug"]);
					
					// The server, while acting as a proxy, did not receive a timely response from the upstream server it needed to access in attempting to complete the request. 
					addLogEntry("Thread sleeping for 30 seconds as the server did not receive a timely response from the upstream server it needed to access in attempting to complete the request", ["debug"]);
					Thread.sleep(dur!"seconds"(30));
				}
				// re-try original request - retried for 429, 503, 504 - but loop back calling this function 
				addLogEntry("Retrying Function: " ~ thisFunctionName, ["debug"]);
				queryThisLevelChildren(driveId, idToQuery, nextLink, queryChildrenOneDriveApiInstance);
			} else {
				// Default operation if not 408,429,503,504 errors
				// display what the error is
				displayOneDriveErrorMessage(exception.msg, thisFunctionName);
			}
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
			addLogEntry("Testing for the existance online of this folder path: " ~ thisFolderName, ["debug"]);
			directoryFoundOnline = false;
			
			// If this is '.' this is the account root
			if (thisFolderName == ".") {
				currentPathTree = thisFolderName;
			} else {
				currentPathTree = currentPathTree ~ "/" ~ thisFolderName;
			}
			
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
					// HTTP request returned status code 408,429,503,504
					if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 429) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
						// Handle the 429
						if (exception.httpStatusCode == 429) {
							// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
							handleOneDriveThrottleRequest(queryOneDriveForSpecificPath);
							addLogEntry("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - attempting to retry " ~ thisFunctionName, ["debug"]);
						}
						// re-try the specific changes queries
						if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
							// 408 - Request Time Out
							// 503 - Service Unavailable
							// 504 - Gateway Timeout
							// Transient error - try again in 30 seconds
							auto errorArray = splitLines(exception.msg);
							addLogEntry(to!string(errorArray[0]) ~ " when attempting to query path on OneDrive - retrying applicable request in 30 seconds");
							addLogEntry(thisFunctionName ~ " previously threw an error - retrying", ["debug"]);
							
							// The server, while acting as a proxy, did not receive a timely response from the upstream server it needed to access in attempting to complete the request. 
							addLogEntry("Thread sleeping for 30 seconds as the server did not receive a timely response from the upstream server it needed to access in attempting to complete the request", ["debug"]);
							Thread.sleep(dur!"seconds"(30));
						}
						// re-try original request - retried for 429, 503, 504 - but loop back calling this function 
						addLogEntry("Retrying Function: " ~ thisFunctionName, ["debug"]);
						queryOneDriveForSpecificPathAndCreateIfMissing(thisNewPathToSearch, createPathIfMissing);
					} else {
						// Default operation if not 408,429,503,504 errors
						// display what the error is
						displayOneDriveErrorMessage(exception.msg, thisFunctionName);
					}	
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
							throw new jsonResponseException("Unable to perform POSIX test as the OneDrive API request generated an invalid JSON response");
						}
						
						// No POSIX issue with requested path element
						parentDetails = makeItem(getPathDetailsAPIResponse);
						// Save item to the database
						saveItem(getPathDetailsAPIResponse);
						directoryFoundOnline = true;
						
						// Is this JSON a remote object
						addLogEntry("Testing if this is a remote Shared Folder", ["debug"]);
						if (isItemRemote(getPathDetailsAPIResponse)) {
							// Remote Directory .. need a DB Tie Item
							addLogEntry("Creating a DB Tie for this Shared Folder", ["debug"]);
							// New DB Tie Item to bind the 'remote' path to our parent path
							Item tieDBItem;
							// Set the name
							tieDBItem.name = parentDetails.name;
							// Set the correct item type
							tieDBItem.type = ItemType.dir;
							// Set the right elements using the 'remote' of the parent as the 'actual' for this DB Tie
							tieDBItem.driveId = parentDetails.remoteDriveId;
							tieDBItem.id = parentDetails.remoteId;
							// Set the correct mtime
							tieDBItem.mtime = parentDetails.mtime;
							// Add tie DB record to the local database
							addLogEntry("Adding DB Tie record to database: " ~ to!string(tieDBItem), ["debug"]);
							itemDB.upsert(tieDBItem);
							// Update parentDetails to use the DB Tie record
							parentDetails = tieDBItem;
						}
					} catch (OneDriveException exception) {
						if (exception.httpStatusCode == 404) {
							directoryFoundOnline = false;
						} else {
						
							string thisFunctionName = getFunctionName!({});
							// HTTP request returned status code 408,429,503,504
							if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 429) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
								// Handle the 429
								if (exception.httpStatusCode == 429) {
									// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
									handleOneDriveThrottleRequest(queryOneDriveForSpecificPath);
									addLogEntry("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - attempting to retry " ~ thisFunctionName, ["debug"]);
								}
								// re-try the specific changes queries
								if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
									// 408 - Request Time Out
									// 503 - Service Unavailable
									// 504 - Gateway Timeout
									// Transient error - try again in 30 seconds
									auto errorArray = splitLines(exception.msg);
									addLogEntry(to!string(errorArray[0]) ~ " when attempting to query path on OneDrive - retrying applicable request in 30 seconds");
									addLogEntry(thisFunctionName ~ " previously threw an error - retrying", ["debug"]);
									
									// The server, while acting as a proxy, did not receive a timely response from the upstream server it needed to access in attempting to complete the request. 
									addLogEntry("Thread sleeping for 30 seconds as the server did not receive a timely response from the upstream server it needed to access in attempting to complete the request", ["debug"]);
									Thread.sleep(dur!"seconds"(30));
								}
								// re-try original request - retried for 429, 503, 504 - but loop back calling this function 
								addLogEntry("Retrying Function: " ~ thisFunctionName, ["debug"]);
								queryOneDriveForSpecificPathAndCreateIfMissing(thisNewPathToSearch, createPathIfMissing);
							} else {
								// Default operation if not 408,429,503,504 errors
								// display what the error is
								displayOneDriveErrorMessage(exception.msg, thisFunctionName);
							}
						}
					} catch (jsonResponseException e) {
							addLogEntry(e.msg, ["debug"]);
					}
				} else {
					// parentDetails.driveId is not the account drive id - thus will be a remote shared item
					addLogEntry("This parent directory is a remote object this next path will be on a remote drive", ["debug"]);
					
					// For this parentDetails.driveId, parentDetails.id object, query the OneDrive API for it's children
					for (;;) {
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
										throw new posixException(thisFolderName, child["name"].str);
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
		
		// Shutdown API instance
		queryOneDriveForSpecificPath.shutdown();
		// Free object and memory
		object.destroy(queryOneDriveForSpecificPath);
		
		// Output our search results
		addLogEntry("queryOneDriveForSpecificPathAndCreateIfMissing.getPathDetailsAPIResponse = " ~ to!string(getPathDetailsAPIResponse), ["debug"]);
		return getPathDetailsAPIResponse;
	}
	
	// Delete an item by it's path
	// This function is only used in --monitor mode and --remove-directory directive
	void deleteByPath(string path) {
		
		// function variables
		Item dbItem;
		
		// Need to check all driveid's we know about, not just the defaultDriveId
		bool itemInDB = false;
		foreach (searchDriveId; driveIDsArray) {
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
				addLogEntry("Moved local item was not in-sync with local databse - uploading as new item");
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
						response = movePathOnlineApiInstance.updateById(oldItem.driveId, oldItem.id, data, oldItem.eTag);
						isMoveSuccess = true;
						break;
					} catch (OneDriveException e) {
						if (e.httpStatusCode == 412) {
							// OneDrive threw a 412 error, most likely: ETag does not match current item's value
							// Retry without eTag
							addLogEntry("File Move Failed - OneDrive eTag / cTag match issue", ["debug"]);
							addLogEntry("OneDrive returned a 'HTTP 412 - Precondition Failed' when attempting to move the file - gracefully handling error", ["verbose"]);
							eTag = null;
							// Retry to move the file but without the eTag, via the for() loop
						} else if (e.httpStatusCode == 409) {
							// Destination item already exists, delete it first
							addLogEntry("Moved local item overwrote an existing item - deleting old online item");
							uploadDeletedItem(newItem, newPath);
						} else
							break;
					}
				} 
				
				// Shutdown API instance
				movePathOnlineApiInstance.shutdown();
				// Free object and memory
				object.destroy(movePathOnlineApiInstance);
				
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
	bool performUploadIntegrityValidationChecks(JSONValue uploadResponse, string localFilePath, ulong localFileSize, bool raiseWarning=true) {
	
		bool integrityValid = false;
	
		if (!disableUploadValidation) {
			// Integrity validation has not been disabled (this is the default so we are always integrity checking our uploads)
			if (uploadResponse.type() == JSONType.object) {
				// Provided JSON is a valid JSON	
				ulong uploadFileSize = uploadResponse["size"].integer;
				string uploadFileHash = uploadResponse["file"]["hashes"]["quickXorHash"].str;
				string localFileHash = computeQuickXorHash(localFilePath);
				
				if ((localFileSize == uploadFileSize) && (localFileHash == uploadFileHash)) {
					// Uploaded file integrity intact
					addLogEntry("Uploaded local file matches reported online size and hash values", ["debug"]);
					integrityValid = true;
				} else if (raiseWarning) {
					// Upload integrity failure .. what failed?
					// There are 2 scenarios where this happens:
					// 1. Failed Transfer
					// 2. Upload file is going to a SharePoint Site, where Microsoft enriches the file with additional metadata with no way to disable
					addLogEntry("WARNING: Uploaded file integrity failure for: " ~ localFilePath, ["info", "notify"]);
					
					// What integrity failed - size?
					if (localFileSize != uploadFileSize) {
						addLogEntry("WARNING: Uploaded file integrity failure - Size Mismatch", ["verbose"]);
					}
					// What integrity failed - hash?
					if (localFileHash != uploadFileHash) {
						addLogEntry("WARNING: Uploaded file integrity failure - Hash Mismatch", ["verbose"]);
					}
					
					// What account type is this?
					if (appConfig.accountType != "personal") {
						// Not a personal account, thus the integrity failure is most likely due to SharePoint
						addLogEntry("CAUTION: Microsoft OneDrive when using SharePoint as a backend enhances files after you upload them, which means this file may now have technical differences from your local copy, resulting in a data integrity issue.", ["verbose"]);
						addLogEntry("See: https://github.com/OneDrive/onedrive-api-docs/issues/935 for further details", ["verbose"]);
					}
					// How can this be disabled?
					addLogEntry("To disable the integrity checking of uploaded files use --disable-upload-validation");
				}
			} else {
				addLogEntry("Upload file validation unable to be performed: input JSON was invalid");
				addLogEntry("WARNING: Skipping upload integrity check for: " ~ localFilePath);
			}
		} else {
			// We are bypassing integrity checks due to --disable-upload-validation
			addLogEntry("Upload file validation disabled due to --disable-upload-validation", ["debug"]);
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
		
		for (;;) {
			try {
				siteQuery = querySharePointLibraryNameApiInstance.o365SiteSearch(nextLink);
			} catch (OneDriveException e) {
				addLogEntry("ERROR: Query of OneDrive for Office 365 Library Name failed");
				// Forbidden - most likely authentication scope needs to be updated
				if (e.httpStatusCode == 403) {
					addLogEntry("ERROR: Authentication scope needs to be updated. Use --reauth and re-authenticate client.");
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
					return;
				}
				// HTTP request returned status code 429 (Too Many Requests)
				if (e.httpStatusCode == 429) {
					// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
					handleOneDriveThrottleRequest(querySharePointLibraryNameApiInstance);
					addLogEntry("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - attempting to query OneDrive drive children", ["debug"]);
				}
				// HTTP request returned status code 504 (Gateway Timeout) or 429 retry
				if ((e.httpStatusCode == 429) || (e.httpStatusCode == 504)) {
					// re-try the specific changes queries	
					if (e.httpStatusCode == 504) {
						addLogEntry("OneDrive returned a 'HTTP 504 - Gateway Timeout' when attempting to query Sharepoint Sites - retrying applicable request");
						addLogEntry("siteQuery = onedrive.o365SiteSearch(nextLink) previously threw an error - retrying", ["debug"]);
						
						// The server, while acting as a proxy, did not receive a timely response from the upstream server it needed to access in attempting to complete the request. 
						addLogEntry("Thread sleeping for 30 seconds as the server did not receive a timely response from the upstream server it needed to access in attempting to complete the request", ["debug"]);
						Thread.sleep(dur!"seconds"(30));
					}
					// re-try original request - retried for 429 and 504
					try {
						addLogEntry("Retrying Query: siteQuery = onedrive.o365SiteSearch(nextLink)", ["debug"]);
						siteQuery = querySharePointLibraryNameApiInstance.o365SiteSearch(nextLink);
						addLogEntry("Query 'siteQuery = onedrive.o365SiteSearch(nextLink)' performed successfully on re-try", ["debug"]);
					} catch (OneDriveException e) {
						// display what the error is
						addLogEntry("Query Error: siteQuery = onedrive.o365SiteSearch(nextLink) on re-try after delay", ["debug"]);
						// error was not a 504 this time
						displayOneDriveErrorMessage(e.msg, getFunctionName!({}));
						return;
					}
				} else {
					// display what the error is
					displayOneDriveErrorMessage(e.msg, getFunctionName!({}));
					return;
				}
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
							
							try {
								siteDriveQuery = querySharePointLibraryNameApiInstance.o365SiteDrives(site_id);
							} catch (OneDriveException e) {
								addLogEntry("ERROR: Query of OneDrive for Office Site ID failed");
								// display what the error is
								displayOneDriveErrorMessage(e.msg, getFunctionName!({}));
								return;
							}
							
							// is siteDriveQuery a valid JSON object & contain data we can use?
							if ((siteDriveQuery.type() == JSONType.object) && ("value" in siteDriveQuery)) {
								// valid JSON object
								foreach (driveResult; siteDriveQuery["value"].array) {
									// Display results
									writeln("-----------------------------------------------");
									addLogEntry("Site Details: " ~ to!string(driveResult), ["debug"]);
									found = true;
									writeln("Site Name:    ", searchResult["displayName"].str);
									writeln("Library Name: ", driveResult["name"].str);
									writeln("drive_id:     ", driveResult["id"].str);
									writeln("Library URL:  ", driveResult["webUrl"].str);
								}
								// closeout
								writeln("-----------------------------------------------");
							} else {
								// not a valid JSON object
								addLogEntry("ERROR: There was an error performing this operation on Microsoft OneDrive");
								addLogEntry("ERROR: Increase logging verbosity to assist determining why.");
								return;
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
				return;
			}
			
			// If a collection exceeds the default page size (200 items), the @odata.nextLink property is returned in the response 
			// to indicate more items are available and provide the request URL for the next page of items.
			if ("@odata.nextLink" in siteQuery) {
				// Update nextLink to next set of SharePoint library names
				nextLink = siteQuery["@odata.nextLink"].str;
				addLogEntry("Setting nextLink to (@odata.nextLink): " ~ nextLink, ["debug"]);
			} else break;
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
		
		// Shutdown API instance
		querySharePointLibraryNameApiInstance.shutdown();
		// Free object and memory
		object.destroy(querySharePointLibraryNameApiInstance);
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
		addProcessingLogHeaderEntry("Querying the change status of Drive ID: " ~ driveIdToQuery);
		
		// Query the OenDrive API using the applicable details, following nextLink if applicable
		// Create a new API Instance for querying /delta and initialise it
		OneDriveApi getDeltaQueryOneDriveApiInstance;
		getDeltaQueryOneDriveApiInstance = new OneDriveApi(appConfig);
		getDeltaQueryOneDriveApiInstance.initialise();
		
		for (;;) {
			// Add a processing '.'
			addProcessingDotEntry();
		
			// Get the /delta changes via the OneDrive API
			// getDeltaChangesByItemId has the re-try logic for transient errors
			deltaChanges = getDeltaChangesByItemId(driveIdToQuery, itemIdToQuery, deltaLink, getDeltaQueryOneDriveApiInstance);
			
			// If the initial deltaChanges response is an invalid JSON object, keep trying ..
			if (deltaChanges.type() != JSONType.object) {
				while (deltaChanges.type() != JSONType.object) {
					// Handle the invalid JSON response adn retry
					addLogEntry("ERROR: Query of the OneDrive API via deltaChanges = getDeltaChangesByItemId() returned an invalid JSON response", ["debug"]);
					deltaChanges = getDeltaChangesByItemId(driveIdToQuery, itemIdToQuery, deltaLink, getDeltaQueryOneDriveApiInstance);
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
			}
			else break;
		}
		// Needed after printing out '....' when fetching changes from OneDrive API
		addLogEntry("\n", ["consoleOnlyNoNewLine"]);
		
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
					thisItemHash = onedriveJSONItem["file"]["hashes"]["quickXorHash"].str;
					
					// Check if the item has been seen before
					Item existingDatabaseItem;
					existingDBEntry = itemDB.selectById(thisItemParentDriveId, thisItemId, existingDatabaseItem);
					
					if (existingDBEntry) {
						// item exists in database .. do the database details match the JSON record?
						if (existingDatabaseItem.quickXorHash != thisItemHash) {
							// file hash is different, this will trigger a download event
							downloadSize = downloadSize + onedriveJSONItem["size"].integer;
						} 
					} else {
						// item does not exist in the database
						// this item has already passed client side filtering rules (skip_dir, skip_file, sync_list)
						// this will trigger a download event
						downloadSize = downloadSize + onedriveJSONItem["size"].integer;
					}
				}
			}
		}
			
		// Was anything detected that would constitute a download?
		if (downloadSize > 0) {
			// we have something to download
			if (pathToQueryStatusOn != "/") {
				writeln("The selected local directory via --single-directory is out of sync with Microsoft OneDrive");
			} else {
				writeln("The configured local 'sync_dir' directory is out of sync with Microsoft OneDrive");
			}
			writeln("Approximate data to download from Microsoft OneDrive: ", (downloadSize/1024), " KB");
		} else {
			// No changes were returned
			writeln("There are no pending changes from Microsoft OneDrive; your local directory matches the data online.");
		}
	}
	
	// Query OneDrive for file details of a given path, returning either the 'webURL' or 'lastModifiedBy' JSON facet
	void queryOneDriveForFileDetails(string inputFilePath, string runtimePath, string outputType) {
	
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
					OneDriveApi queryOneDriveForFileDetailsApiInstance;
					queryOneDriveForFileDetailsApiInstance = new OneDriveApi(appConfig);
					queryOneDriveForFileDetailsApiInstance.initialise();
					
					try {
						fileDetailsFromOneDrive = queryOneDriveForFileDetailsApiInstance.getPathDetailsById(dbItem.driveId, dbItem.id);
					} catch (OneDriveException exception) {
						// display what the error is
						displayOneDriveErrorMessage(exception.msg, getFunctionName!({}));
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
					
					// Shutdown the API access
					queryOneDriveForFileDetailsApiInstance.shutdown();
					// Free object and memory
					object.destroy(queryOneDriveForFileDetailsApiInstance);
				}
			}
			
			// was path found?
			if (!pathInDB) {
				// File has not been synced with OneDrive
				addLogEntry("Selected path has not been synced with OneDrive: " ~ inputFilePath);
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

		if (appConfig.getValueString("drive_id").length) {
			driveId = appConfig.getValueString("drive_id");
		} else {
			driveId = appConfig.defaultDriveId;
		}
		
		try {
			// Create a new OneDrive API instance
			OneDriveApi getCurrentDriveQuotaApiInstance;
			getCurrentDriveQuotaApiInstance = new OneDriveApi(appConfig);
			getCurrentDriveQuotaApiInstance.initialise();
			addLogEntry("Seeking available quota for this drive id: " ~ driveId, ["debug"]);
			currentDriveQuota = getCurrentDriveQuotaApiInstance.getDriveQuota(driveId);
			// Shut this API instance down
			getCurrentDriveQuotaApiInstance.shutdown();
			// Free object and memory
			object.destroy(getCurrentDriveQuotaApiInstance);
		} catch (OneDriveException e) {
			addLogEntry("currentDriveQuota = onedrive.getDriveQuota(driveId) generated a OneDriveException", ["debug"]);
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
			ulong batchSize = appConfig.getValueLong("threads");
			ulong batchCount = (jsonItemsToResumeUpload.length + batchSize - 1) / batchSize;
			ulong batchesProcessed = 0;
			
			foreach (chunk; jsonItemsToResumeUpload.chunks(batchSize)) {
				// send an array containing 'appConfig.getValueLong("threads")' JSON items to resume upload
				resumeSessionUploadsInParallel(chunk);
			}
		}
	}
	
	bool validateUploadSessionFileData(string sessionFilePath) {
		
		JSONValue sessionFileData;

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
			
			// Create a new OneDrive API instance
			OneDriveApi validateUploadSessionFileDataApiInstance;
			validateUploadSessionFileDataApiInstance = new OneDriveApi(appConfig);
			validateUploadSessionFileDataApiInstance.initialise();
			
			try {
				response = validateUploadSessionFileDataApiInstance.requestUploadStatus(sessionFileData["uploadUrl"].str);
			} catch (OneDriveException e) {
				// handle any onedrive error response as invalid
				addLogEntry("SESSION-RESUME: Invalid response when using uploadUrl in: " ~ sessionFilePath, ["debug"]);
				return false;
			}
			
			// Shutdown API instance
			validateUploadSessionFileDataApiInstance.shutdown();
			// Free object and memory
			object.destroy(validateUploadSessionFileDataApiInstance);
			
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
		
		// Add 'sessionFilePath' to 'sessionFileData' so that it can be used when we re-use the JSON data to resume the upload
		sessionFileData["sessionFilePath"] = sessionFilePath;
		
		// Add sessionFileData to jsonItemsToResumeUpload as it is now valid
		jsonItemsToResumeUpload ~= sessionFileData;
		return true;
	}
	
	void resumeSessionUploadsInParallel(JSONValue[] array) {
		// This function recieved an array of 16 JSON items to resume upload
		foreach (i, jsonItemToResume; taskPool.parallel(array)) {
			// Take each JSON item and resume upload using the JSON data
			
			JSONValue uploadResponse;
			OneDriveApi uploadFileOneDriveApiInstance;
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
			
			// Was the response from the OneDrive API a valid JSON item?
			if (uploadResponse.type() == JSONType.object) {
				// A valid JSON object was returned - session resumption upload sucessful
				
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
			
			// Shutdown API instance
			uploadFileOneDriveApiInstance.shutdown();
			// Free object and memory
			object.destroy(uploadFileOneDriveApiInstance);
		}
	}
	
	// Function to process the path by removing prefix up to ':' - remove '/drive/root:' from a path string
	string processPathToRemoveRootReference(ref string pathToCheck) {
		long colonIndex = pathToCheck.indexOf(":");
		if (colonIndex != -1) {
			addLogEntry("Updating " ~ pathToCheck ~ " to remove prefix up to ':'", ["debug"]);
			pathToCheck = pathToCheck[colonIndex + 1 .. $];
			addLogEntry("Updated path for 'skip_dir' check: " ~ pathToCheck, ["debug"]);
		}
		return pathToCheck;
	}
}