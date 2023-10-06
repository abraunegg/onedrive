// What is this module called?
module syncEngine;

// What does this module require to function?
import core.stdc.stdlib: EXIT_SUCCESS, EXIT_FAILURE, exit;
import core.thread;
import core.time;
import std.algorithm;
import std.array;
import std.concurrency;
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

// What other modules that we have created do we need to import?
import config;
import log;
import util;
import onedrive;
import itemdb;
import clientSideFiltering;
import progress;

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
	string[] skippedItems;
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
			log.vdebug("Configuring uploadOnly flag to TRUE as --upload-only passed in or configured");
			this.uploadOnly = true;
		}
		
		// Configure the localDeleteAfterUpload flag
		if (appConfig.getValueBool("remove_source_files")) {
			log.vdebug("Configuring localDeleteAfterUpload flag to TRUE as --remove-source-files passed in or configured");
			this.localDeleteAfterUpload = true;
		}
		
		// Configure the disableDownloadValidation flag
		if (appConfig.getValueBool("disable_download_validation")) {
			log.vdebug("Configuring disableDownloadValidation flag to TRUE as --disable-download-validation passed in or configured");
			this.disableDownloadValidation = true;
		}
		
		// Configure the disableUploadValidation flag
		if (appConfig.getValueBool("disable_upload_validation")) {
			log.vdebug("Configuring disableUploadValidation flag to TRUE as --disable-upload-validation passed in or configured");
			this.disableUploadValidation = true;
		}
		
		// Do we configure to clean up local files if using --download-only ?
		if ((appConfig.getValueBool("download_only")) && (appConfig.getValueBool("cleanup_local_files"))) {
			// --download-only and --cleanup-local-files were passed in
			log.log("WARNING: Application has been configured to cleanup local files that are not present online.");
			log.log("WARNING: Local data loss MAY occur in this scenario if you are expecting data to remain archived locally.");
			// Set the flag
			this.cleanupLocalFiles = true;
		}
		
		// Do we configure to NOT perform a remote delete if --upload-only & --no-remote-delete configured ?
		if ((appConfig.getValueBool("upload_only")) && (appConfig.getValueBool("no_remote_delete"))) {
			// --upload-only and --no-remote-delete were passed in
			log.log("WARNING: Application has been configured NOT to cleanup remote files that are deleted locally.");
			// Set the flag
			this.noRemoteDelete = true;
		}
		
		// Are we forcing to use /children scan instead of /delta to simulate National Cloud Deployment use of /children?
		if (appConfig.getValueBool("force_children_scan")) {
			log.log("Forcing client to use /children API call rather than /delta API to retrieve objects from the OneDrive API");
			this.nationalCloudDeployment = true;
		}
		
		// Are we forcing the client to bypass any data preservation techniques to NOT rename any local files if there is a conflict?
		// The enabling of this function could lead to data loss
		if (appConfig.getValueBool("bypass_data_preservation")) {
			log.log("WARNING: Application has been configured to bypass local data preservation in the event of file conflict.");
			log.log("WARNING: Local data loss MAY occur in this scenario.");
			this.bypassDataPreservation = true;
		}
		
		// Did the user configure a specific rate limit for the application?
		if (appConfig.getValueLong("rate_limit") > 0) {
			// User configured rate limit
			log.log("User Configured Rate Limit: ", appConfig.getValueLong("rate_limit"));
			
			// If user provided rate limit is < 131072, flag that this is too low, setting to the recommended minimum of 131072
			if (appConfig.getValueLong("rate_limit") < 131072) {
				// user provided limit too low
				log.log("WARNING: User configured rate limit too low for normal application processing and preventing application timeouts. Overriding to recommended minimum of 131072 (128KB/s)");
				appConfig.setValueLong("rate_limit", 131072);
			}
		}
		
		// Did the user downgrade all HTTP operations to force HTTP 1.1
		if (appConfig.getValueBool("force_http_11")) {
			// User is forcing downgrade to curl to use HTTP 1.1 for all operations
			log.vlog("Downgrading all HTTP operations to HTTP/1.1 due to user configuration");
		} else {
			// Use curl defaults
			log.vdebug("Using Curl defaults for HTTP operational protocol version (potentially HTTP/2)");
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
				log.error(exception.msg);
				// Shutdown API instance
				oneDriveApiInstance.shutdown();
				// Free object and memory
				object.destroy(oneDriveApiInstance);
				exit(-1);
			}
			
			try {
				// Get the relevant default account & drive details
				getDefaultRootDetails();
			} catch (accountDetailsException exception) {
				// details could not be queried
				log.error(exception.msg);
				// Shutdown API instance
				oneDriveApiInstance.shutdown();
				// Free object and memory
				object.destroy(oneDriveApiInstance);
				exit(-1);
			}
			
			try {
				// Display details
				displaySyncEngineDetails();
			} catch (accountDetailsException exception) {
				// details could not be queried
				log.error(exception.msg);
				// Shutdown API instance
				oneDriveApiInstance.shutdown();
				// Free object and memory
				object.destroy(oneDriveApiInstance);
				exit(-1);
			}
		} else {
			// API could not be initialised
			log.error("OneDrive API could not be initialised with previously used details");
			// Shutdown API instance
			oneDriveApiInstance.shutdown();
			// Free object and memory
			object.destroy(oneDriveApiInstance);
			exit(-1);
		}
		log.log("Sync Engine Initialised with new Onedrive API instance");
		// Shutdown API instance
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
			log.vdebug("Getting Account Default Drive Details");
			defaultOneDriveDriveDetails = oneDriveApiInstance.getDefaultDriveDetails();
		} catch (OneDriveException exception) {
			log.vdebug("defaultOneDriveDriveDetails = oneDriveApiInstance.getDefaultDriveDetails() generated a OneDriveException");
			
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
					log.vdebug("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - attempting to retry ", thisFunctionName);
				}
				// re-try the specific changes queries
				if ((exception.httpStatusCode == 408) ||(exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
					// 408 - Request Time Out
					// 503 - Service Unavailable
					// 504 - Gateway Timeout
					// Transient error - try again in 30 seconds
					auto errorArray = splitLines(exception.msg);
					log.log(errorArray[0], " when attempting to query Account Default Drive Details - retrying applicable request in 30 seconds");
					log.vdebug("defaultOneDriveDriveDetails = oneDriveApiInstance.getDefaultDriveDetails() previously threw an error - retrying");
					// The server, while acting as a proxy, did not receive a timely response from the upstream server it needed to access in attempting to complete the request. 
					log.vdebug("Thread sleeping for 30 seconds as the server did not receive a timely response from the upstream server it needed to access in attempting to complete the request");
					Thread.sleep(dur!"seconds"(30));
				}
				// re-try original request - retried for 429 and 504 - but loop back calling this function 
				log.vdebug("Retrying Function: getDefaultDriveDetails()");
				getDefaultDriveDetails();
			} else {
				// Default operation if not 408,429,503,504 errors
				// display what the error is
				displayOneDriveErrorMessage(exception.msg, getFunctionName!({}));
			}
		}
		
		// If the JSON response is a correct JSON object, and has an 'id' we can set these details
		if ((defaultOneDriveDriveDetails.type() == JSONType.object) && (hasId(defaultOneDriveDriveDetails))) {
			log.vdebug("OneDrive Account Default Drive Details:      ", defaultOneDriveDriveDetails);
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
						log.error("ERROR: OneDrive account currently has zero space available. Please free up some space online.");
						appConfig.quotaAvailable = false;
					} else {
						// zero space available is being reported, maybe being restricted?
						log.error("WARNING: OneDrive quota information is being restricted or providing a zero value. Please fix by speaking to your OneDrive / Office 365 Administrator.");
						appConfig.quotaRestricted = true;
					}
				} else {
					// json response was missing a 'remaining' value
					if (appConfig.accountType == "personal") {
						log.error("ERROR: OneDrive quota information is missing. Potentially your OneDrive account currently has zero space available. Please free up some space online.");
						appConfig.quotaAvailable = false;
					} else {
						// quota details not available
						log.error("ERROR: OneDrive quota information is being restricted. Please fix by speaking to your OneDrive / Office 365 Administrator.");
						appConfig.quotaRestricted = true;
					}
				}
			}
			// What did we set based on the data from the JSON
			log.vdebug("appConfig.accountType        = ", appConfig.accountType);
			log.vdebug("appConfig.defaultDriveId     = ", appConfig.defaultDriveId);
			log.vdebug("appConfig.remainingFreeSpace = ", appConfig.remainingFreeSpace);
			log.vdebug("appConfig.quotaAvailable     = ", appConfig.quotaAvailable);
			log.vdebug("appConfig.quotaRestricted    = ", appConfig.quotaRestricted);
			
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
			log.vdebug("Getting Account Default Root Details");
			defaultOneDriveRootDetails = oneDriveApiInstance.getDefaultRootDetails();
		} catch (OneDriveException exception) {
			log.vdebug("defaultOneDriveRootDetails = oneDriveApiInstance.getDefaultRootDetails() generated a OneDriveException");

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
					log.vdebug("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - attempting to retry ", thisFunctionName);
				}
				// re-try the specific changes queries
				if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
					// 503 - Service Unavailable
					// 504 - Gateway Timeout
					// Transient error - try again in 30 seconds
					auto errorArray = splitLines(exception.msg);
					log.log(errorArray[0], " when attempting to query Account Default Root Details - retrying applicable request in 30 seconds");
					log.vdebug("defaultOneDriveRootDetails = oneDriveApiInstance.getDefaultRootDetails() previously threw an error - retrying");
					// The server, while acting as a proxy, did not receive a timely response from the upstream server it needed to access in attempting to complete the request. 
					log.vdebug("Thread sleeping for 30 seconds as the server did not receive a timely response from the upstream server it needed to access in attempting to complete the request");
					Thread.sleep(dur!"seconds"(30));
				}
				// re-try original request - retried for 429, 503, 504 - but loop back calling this function 
				log.vdebug("Retrying Function: getDefaultRootDetails()");
				getDefaultRootDetails();
			} else {
				// Default operation if not 408,429,503,504 errors
				// display what the error is
				displayOneDriveErrorMessage(exception.msg, getFunctionName!({}));
			}
		}
		
		// If the JSON response is a correct JSON object, and has an 'id' we can set these details
		if ((defaultOneDriveRootDetails.type() == JSONType.object) && (hasId(defaultOneDriveRootDetails))) {
			log.vdebug("OneDrive Account Default Root Details:       ", defaultOneDriveRootDetails);
			appConfig.defaultRootId = defaultOneDriveRootDetails["id"].str;
			log.vdebug("appConfig.defaultRootId      = ", appConfig.defaultRootId);
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
		if ((fileDownloadFailures.empty) && (fileUploadFailures.empty)) {
			log.log("Resetting syncFailures = false");
			syncFailures = false;
		} else {
			log.log("File activity array's not empty - not resetting syncFailures");
		}
	}
	
	// Perform a sync of the OneDrive Account
	// - Query /delta
	//		- If singleDirectoryScope or nationalCloudDeployment is used we need to generate a /delta like response
	// - Process changes (add, changes, moves, deletes)
	// - Process any items to add (download data to local)
	// - Detail any files that we failed to download
	// - Process any deletes (remove local data)
	// - Walk local file system for any differences (new files / data to upload to OneDrive)
	void syncOneDriveAccountToLocalDisk() {
	
		// performFullScanTrueUp value
		log.vdebug("Perform a Full Scan True-Up: ", appConfig.fullScanTrueUpRequired);
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
							log.vlog("Skipping item - excluded by skip_dir config: ", remoteItem.name);
							continue;
						}
					}
					
					// Directory name is not excluded or skip_dir is not populated
					if (!appConfig.surpressLoggingOutput) {
						log.log("Syncing this OneDrive Personal Shared Folder: ", remoteItem.name);
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
								log.vlog("Skipping item - excluded by skip_dir config: ", remoteItem.name);
								continue;
							}
						}
						
						// Directory name is not excluded or skip_dir is not populated
						if (!appConfig.surpressLoggingOutput) {
							log.log("Syncing this OneDrive Business Shared Folder: ", remoteItem.name);
						}
						
						log.vdebug("Fetching /delta API response for:");
						log.vdebug("    remoteItem.remoteDriveId: ", remoteItem.remoteDriveId);
						log.vdebug("    remoteItem.remoteId:      ", remoteItem.remoteId);
						
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
		log.log("The OneDrive Client was asked to search for this directory online and create it if it's not located: ", normalisedSingleDirectoryPath);
		
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
			log.error("ERROR: Requested directory to search for and potentially create has a 'case-insensitive match' to an existing directory on OneDrive online.");
		}
		
		// Was a valid JSON response provided?
		if (onlinePathData.type() == JSONType.object) {
			// Valid JSON item was returned
			searchItem = makeItem(onlinePathData);
			log.vdebug("searchItem: ", searchItem);
			
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
			log.error("\nThe requested --single-directory path to sync has generated an error. Please correct this error and try again.\n");
			exit(EXIT_FAILURE);
		}
	}
	
	// Query OneDrive API for /delta changes and iterate through items online
	void fetchOneDriveDeltaAPIResponse(string driveIdToQuery = null, string itemIdToQuery = null, string sharedFolderName = null) {
				
		string deltaLink = null;
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
			log.vdebug("driveIdToQuery was empty, setting to appConfig.defaultDriveId");
			driveIdToQuery = appConfig.defaultDriveId;
			log.vdebug("driveIdToQuery: ", driveIdToQuery);
		}
		
		// Was an itemId provided as an input
		//if (itemIdToQuery == "") {
		if (strip(itemIdToQuery).empty) {
			// No provided itemId to query, use the account default
			log.vdebug("itemIdToQuery was empty, setting to appConfig.defaultRootId");
			itemIdToQuery = appConfig.defaultRootId;
			log.vdebug("itemIdToQuery: ", itemIdToQuery);
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
				log.vdebug("Using stored deltaLink");
				deltaLink = deltaLinkAvailable;
			}
			
			// Do we need to perform a Full Scan True Up? Is 'appConfig.fullScanTrueUpRequired' set to 'true'?
			if (appConfig.fullScanTrueUpRequired) {
				log.log("Performing a full scan of online data to ensure consistent local state");
				log.vdebug("Setting deltaLink = null");
				deltaLink = null;
			}
			
			// Dynamic output for a non-verbose run so that the user knows something is happening
			if (log.verbose <= 1) {
				if (!appConfig.surpressLoggingOutput) {
					log.fileOnly("Fetching items from the OneDrive API for Drive ID: ", driveIdToQuery);
					write("Fetching items from the OneDrive API for Drive ID: ", driveIdToQuery, " .");
				}
			} else {
				log.vdebug("Fetching /delta response from the OneDrive API for driveId: ", driveIdToQuery);
			}
							
			for (;;) {
				responseBundleCount++;
				// Get the /delta changes via the OneDrive API
				// getDeltaChangesByItemId has the re-try logic for transient errors
				deltaChanges = getDeltaChangesByItemId(driveIdToQuery, itemIdToQuery, deltaLink);
				
				// If the initial deltaChanges response is an invalid JSON object, keep trying ..
				if (deltaChanges.type() != JSONType.object) {
					while (deltaChanges.type() != JSONType.object) {
						// Handle the invalid JSON response adn retry
						log.vdebug("ERROR: Query of the OneDrive API via deltaChanges = getDeltaChangesByItemId() returned an invalid JSON response");
						deltaChanges = getDeltaChangesByItemId(driveIdToQuery, itemIdToQuery, deltaLink);
					}
				}
				
				ulong nrChanges = count(deltaChanges["value"].array);
				int changeCount = 0;
				
				if (log.verbose <= 1) {
					// Dynamic output for a non-verbose run so that the user knows something is happening
					if (!appConfig.surpressLoggingOutput) {
						write(".");
					}
				} else {
					log.vdebug("API Response Bundle: ", responseBundleCount, " - Quantity of 'changes|items' in this bundle to process: ", nrChanges);
				}
				
				jsonItemsReceived = jsonItemsReceived + nrChanges;
				
				// This means we are most likely processing 200+ items at the same time as the OneDrive API bundles the JSON items
				// into 200+ bundle lots and there is zero way to configure or change this
				// The API response however cannot be run in parallel as the OneDrive API sends the JSON items in the order in which they must be processed
				foreach (onedriveJSONItem; deltaChanges["value"].array) {
					// increment change count for this item
					changeCount++;
					// Process the OneDrive object item JSON
					processDeltaJSONItem(onedriveJSONItem, nrChanges, changeCount, responseBundleCount, singleDirectoryScope);	
				}
				
				// The response may contain either @odata.deltaLink or @odata.nextLink
				if ("@odata.deltaLink" in deltaChanges) {
					deltaLink = deltaChanges["@odata.deltaLink"].str;
					log.vdebug("Setting next deltaLink to (@odata.deltaLink): ", deltaLink);
				}
				// Update the deltaLink in the database so that we can reuse this
				if (!deltaLink.empty) {
					log.vdebug("Updating completed deltaLink in DB to: ", deltaLink); 
					itemDB.setDeltaLink(driveIdToQuery, itemIdToQuery, deltaLink);
				}
				// Update deltaLink to next changeSet bundle
				if ("@odata.nextLink" in deltaChanges) {	
					deltaLink = deltaChanges["@odata.nextLink"].str;
					// Update deltaLinkAvailable to next changeSet bundle to quantify how many changes we have to process
					deltaLinkAvailable = deltaChanges["@odata.nextLink"].str;
					log.vdebug("Setting next deltaLink & deltaLinkAvailable to (@odata.nextLink): ", deltaLink);
				}
				else break;
			}
			
			// To finish off the JSON processing items, this is needed to reflect this in the log
			log.vdebug("------------------------------------------------------------------");
			
			// Log that we have finished querying the /delta API
			if (log.verbose <= 1) {
				if (!appConfig.surpressLoggingOutput) {
					write("\n");
				}
			} else {
				log.vdebug("Finished processing /delta JSON response from the OneDrive API");
			}
			
			// If this was set, now unset it, as this will have been completed, so that for a true up, we dont do a double full scan
			if (appConfig.fullScanTrueUpRequired) {
				log.vdebug("Unsetting fullScanTrueUpRequired as this has been performed");
				appConfig.fullScanTrueUpRequired = false;
			}
		} else {
			// We have to generate our own /delta response
			// Log what we are doing so that the user knows something is happening
			if (!appConfig.surpressLoggingOutput) {
				log.log("Generating a /delta compatible JSON response from the OneDrive API ...");
			}
			
			// Why are are generating a /delta response
			log.vdebug("Why are we generating a /delta response:");
			log.vdebug(" singleDirectoryScope:    ", singleDirectoryScope);
			log.vdebug(" nationalCloudDeployment: ", nationalCloudDeployment);
			log.vdebug(" cleanupLocalFiles:       ", cleanupLocalFiles);
			
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
			log.vdebug("API Response Bundle: ", responseBundleCount, " - Quantity of 'changes|items' in this bundle to process: ", nrChanges);
			jsonItemsReceived = jsonItemsReceived + nrChanges;
			
			// The API response however cannot be run in parallel as the OneDrive API sends the JSON items in the order in which they must be processed
			foreach (onedriveJSONItem; deltaChanges["value"].array) {
				// increment change count for this item
				changeCount++;
				// Process the OneDrive object item JSON
				processDeltaJSONItem(onedriveJSONItem, nrChanges, changeCount, responseBundleCount, singleDirectoryScope);	
			}
			
			// To finish off the JSON processing items, this is needed to reflect this in the log
			log.vdebug("------------------------------------------------------------------");
			
			// Log that we have finished generating our self generated /delta response
			if (!appConfig.surpressLoggingOutput) {
				log.log("Finished processing self generated /delta JSON response from the OneDrive API");
			}
		}
		
		// We have JSON items received from the OneDrive API
		log.vdebug("Number of JSON Objects received from OneDrive API:                 ", jsonItemsReceived);
		log.vdebug("Number of JSON Objects already processed (root and deleted items): ", (jsonItemsReceived - jsonItemsToProcess.length));
		
		// We should have now at least processed all the JSON items as returned by the /delta call
		// Additionally, we should have a new array, that now contains all the JSON items we need to process that are non 'root' or deleted items
		log.vdebug("Number of JSON items to process is: ", jsonItemsToProcess.length);
		
		// Lets deal with the JSON items in a batch process
		ulong batchSize = 500;
		ulong batchCount = (jsonItemsToProcess.length + batchSize - 1) / batchSize;
		ulong batchesProcessed = 0;
		
		if (log.verbose == 0) {
			// Dynamic output for a non-verbose run so that the user knows something is happening
			if (!appConfig.surpressLoggingOutput) {
				log.log("Processing changes and items received from Microsoft OneDrive ...");
			}
		}
		
		foreach (batchOfJSONItems; jsonItemsToProcess.chunks(batchSize)) {
			// Chunk the total items to process into 500 lot items
			batchesProcessed++;
			log.vlog("Processing OneDrive JSON item batch [", batchesProcessed,"/", batchCount, "] to ensure consistent local state");
			processJSONItemsInBatch(batchOfJSONItems, batchesProcessed, batchCount);
			// To finish off the JSON processing items, this is needed to reflect this in the log
			log.vdebug("------------------------------------------------------------------");
		}
		
		log.vdebug("Number of JSON items to process is: ", jsonItemsToProcess.length);
		log.vdebug("Number of JSON items processed was: ", processedCount);
		
		// Free up memory and items processed as it is pointless now having this data around
		jsonItemsToProcess = []; 
		
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
		
		log.vdebug("------------------------------------------------------------------");
		log.vdebug("Processing OneDrive Item ", changeCount, " of ", nrChanges, " from API Response Bundle ", responseBundleCount);
		log.vdebug("Raw JSON OneDrive Item: ", onedriveJSONItem);
		// What is this item's id
		thisItemId = onedriveJSONItem["id"].str;
		// Is this a deleted item - only calculate this once
		itemIsDeletedOnline = isItemDeleted(onedriveJSONItem);
		
		if(!itemIsDeletedOnline){
			// This is not a deleted item
			log.vdebug("This item is not a OneDrive deletion change");
			// Only calculate this once
			itemIsRoot = isItemRoot(onedriveJSONItem);
			itemHasParentReferenceId = hasParentReferenceId(onedriveJSONItem);
			itemIdMatchesDefaultRootId = (thisItemId == appConfig.defaultRootId);
			itemNameExplicitMatchRoot = (onedriveJSONItem["name"].str == "root");
			objectParentDriveId = onedriveJSONItem["parentReference"]["driveId"].str;
			
			// Shared Folder Items
			// !hasParentReferenceId(id)
			// !hasParentReferenceId(path)
			
			// Test is this is the OneDrive Users Root?
			// Debug output of change evaluation items
			log.vdebug("defaultRootId                                        = ", appConfig.defaultRootId);
			log.vdebug("'search id'                                          = ", thisItemId);
			log.vdebug("id == defaultRootId                                  = ", itemIdMatchesDefaultRootId);
			log.vdebug("isItemRoot(onedriveJSONItem)                         = ", itemIsRoot);
			log.vdebug("onedriveJSONItem['name'].str == 'root'               = ", itemNameExplicitMatchRoot);
			log.vdebug("itemHasParentReferenceId                             = ", itemHasParentReferenceId);
			
			if ( (itemIdMatchesDefaultRootId || singleDirectoryScope) && itemIsRoot && itemNameExplicitMatchRoot) {
				// This IS a OneDrive Root item or should be classified as such in the case of 'singleDirectoryScope'
				log.vdebug("JSON item will flagged as a 'root' item");
				handleItemAsRootObject = true;
			}
		}
		
		// How do we handle this JSON item from the OneDrive API?
		// Is this a confirmed 'root' item, has no Parent ID, or is a Deleted Item
		if (handleItemAsRootObject || !itemHasParentReferenceId || itemIsDeletedOnline){
			// Is a root item, has no id in parentReference or is a OneDrive deleted item
			log.vdebug("objectParentDriveId                                  = ", objectParentDriveId);
			log.vdebug("handleItemAsRootObject                               = ", handleItemAsRootObject);
			log.vdebug("itemHasParentReferenceId                             = ", itemHasParentReferenceId);
			log.vdebug("itemIsDeletedOnline                                  = ", itemIsDeletedOnline);
			log.vdebug("Handling change immediately as 'root item', or has no parent reference id or is a deleted item");
			// OK ... do something with this JSON post here ....
			processRootAndDeletedJSONItems(onedriveJSONItem, objectParentDriveId, handleItemAsRootObject, itemIsDeletedOnline, itemHasParentReferenceId);
		} else {
			// Do we need to update this RAW JSON from OneDrive?
			if ( (objectParentDriveId != appConfig.defaultDriveId) && (appConfig.accountType == "business") && (appConfig.getValueBool("sync_business_shared_items")) ) {
				// Potentially need to update this JSON data
				log.vdebug("Potentially need to update this source JSON .... need to check the database");
				
				// Check the DB for 'remote' objects, searching 'remoteDriveId' and 'remoteId' items for this remoteItem.driveId and remoteItem.id
				Item remoteDBItem;
				itemDB.selectByRemoteId(objectParentDriveId, thisItemId, remoteDBItem);
				
				// Is the data that was returned from the database what we are looking for?
				if ((remoteDBItem.remoteDriveId == objectParentDriveId) && (remoteDBItem.remoteId == thisItemId)) {
					// Yes, this is the record we are looking for
					log.vdebug("DB Item response for remoteDBItem: ", remoteDBItem);
				
					// Must compare remoteDBItem.name with remoteItem.name
					if (remoteDBItem.name != onedriveJSONItem["name"].str) {
						// Update JSON Item
						string actualOnlineName = onedriveJSONItem["name"].str;
						log.vdebug("Updating source JSON 'name' to that which is the actual local directory");
						log.vdebug("onedriveJSONItem['name'] was:         ", onedriveJSONItem["name"].str);
						log.vdebug("Updating onedriveJSONItem['name'] to: ", remoteDBItem.name);
						onedriveJSONItem["name"] = remoteDBItem.name;
						log.vdebug("onedriveJSONItem['name'] now:         ", onedriveJSONItem["name"].str);
						// Add the original name to the JSON 
						onedriveJSONItem["actualOnlineName"] = actualOnlineName;
					}
				}
			}
		
			// Add this JSON item for further processing
			log.vdebug("Adding this Raw JSON OneDrive Item to jsonItemsToProcess array for further processing");
			jsonItemsToProcess ~= onedriveJSONItem;
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
				log.vdebug("Handing JSON object as OneDrive 'root' object");
				if (!existingDBEntry) {
					// we have not seen this item before
					saveItem(onedriveJSONItem);
				}
			}
		} else {
			// Change is to delete an item
			log.vdebug("Handing a OneDrive Deleted Item");
			if (existingDBEntry) {
				// Flag to delete
				log.vdebug("Flagging to delete item locally: ", onedriveJSONItem);
				idsToDelete ~= [thisItemDriveId, thisItemId];
			} else {
				// Flag to ignore
				log.vdebug("Flagging item to skip: ", onedriveJSONItem);
				skippedItems ~= thisItemId;
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
			log.vdebug("------------------------------------------------------------------");
			log.vdebug("Processing OneDrive JSON item ", elementCount, " of ", batchElementCount, " as part of JSON Item Batch ", batchGroup, " of ", batchCount);
			log.vdebug("Raw JSON OneDrive Item: ", onedriveJSONItem);
			
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
				log.vdebug("New Item calculated full path is: ", newItemPath);
			} else {
				// Parent not in the database
				// Is the parent a 'folder' from another user? ie - is this a 'shared folder' that has been shared with us?
				log.vdebug("Parent ID is not in DB .. ");
				// Why?
				if (thisItemDriveId == appConfig.defaultDriveId) {
					// Flagging as unwanted
					log.vdebug("Flagging as unwanted: thisItemDriveId (", thisItemDriveId,"), thisItemParentId (", thisItemParentId,") not in local database");
					if (skippedItems.find(thisItemParentId).length != 0) {
						log.vdebug("Reason: thisItemParentId listed within skippedItems");
					}
					unwanted = true;
				} else {
					// Edge case as the parent (from another users OneDrive account) will never be in the database - potentially a shared object?
					log.vdebug("Potential Shared Object Item: ", onedriveJSONItem);
					// Format the OneDrive change into a consumable object for the database
					remoteItem = makeItem(onedriveJSONItem);
					log.vdebug("The reported parentId is not in the database. This potentially is a shared folder as 'remoteItem.driveId' != 'appConfig.defaultDriveId'. Relevant Details: remoteItem.driveId (", remoteItem.driveId,"), remoteItem.parentId (", remoteItem.parentId,")");
					
					if (appConfig.accountType == "personal") {
						// Personal Account Handling
						// Ensure that this item has no parent
						log.vdebug("Setting remoteItem.parentId to be null");
						remoteItem.parentId = null;
						// Add this record to the local database
						log.vdebug("Update/Insert local database with remoteItem details with remoteItem.parentId as null: ", remoteItem);
						itemDB.upsert(remoteItem);
					} else {
						// Business or SharePoint Account Handling
						log.vdebug("Handling a Business or SharePoint Shared Item JSON object");
						
						if (appConfig.accountType == "business") {
							// Create a DB Tie Record for this parent object
							Item parentItem;
							parentItem.driveId = onedriveJSONItem["parentReference"]["driveId"].str;
							parentItem.id = onedriveJSONItem["parentReference"]["id"].str;
							parentItem.name = "root";
							parentItem.type = ItemType.dir;
							parentItem.mtime = remoteItem.mtime;
							parentItem.parentId = null;
							
							// Add this parent record to the local database
							log.vdebug("Insert local database with remoteItem parent details: ", parentItem);
							itemDB.upsert(parentItem);
							
							// Ensure that this item has no parent
							log.vdebug("Setting remoteItem.parentId to be null");
							remoteItem.parentId = null;
							
							// Check the DB for 'remote' objects, searching 'remoteDriveId' and 'remoteId' items for this remoteItem.driveId and remoteItem.id
							Item remoteDBItem;
							itemDB.selectByRemoteId(remoteItem.driveId, remoteItem.id, remoteDBItem);
							
							// Must compare remoteDBItem.name with remoteItem.name
							if ((!remoteDBItem.name.empty) && (remoteDBItem.name != remoteItem.name)) {
								// Update DB Item
								log.vdebug("The shared item stored in OneDrive, has a different name to the actual name on the remote drive");
								log.vdebug("Updating remoteItem.name JSON data with the actual name being used on account drive and local folder");
								log.vdebug("remoteItem.name was:              ", remoteItem.name);
								log.vdebug("Updating remoteItem.name to:      ", remoteDBItem.name);
								remoteItem.name = remoteDBItem.name;
								log.vdebug("Setting remoteItem.remoteName to: ", onedriveJSONItem["name"].str);
								
								// Update JSON Item
								remoteItem.remoteName = onedriveJSONItem["name"].str;
								log.vdebug("Updating source JSON 'name' to that which is the actual local directory");
								log.vdebug("onedriveJSONItem['name'] was:         ", onedriveJSONItem["name"].str);
								log.vdebug("Updating onedriveJSONItem['name'] to: ", remoteDBItem.name);
								onedriveJSONItem["name"] = remoteDBItem.name;
								log.vdebug("onedriveJSONItem['name'] now:         ", onedriveJSONItem["name"].str);
								
								// Update newItemPath value
								newItemPath = computeItemPath(thisItemDriveId, thisItemParentId) ~ "/" ~ remoteDBItem.name;
								log.vdebug("New Item updated calculated full path is: ", newItemPath);
							}
								
							// Add this record to the local database
							log.vdebug("Update/Insert local database with remoteItem details: ", remoteItem);
							itemDB.upsert(remoteItem);
						}
					}
				}
			}
			
			// Check the skippedItems array for the parent id of this JSONItem if this is something we need to skip
			if (!unwanted) {
				if (skippedItems.find(thisItemParentId).length != 0) {
					// Flag this JSON item as unwanted
					log.vdebug("Flagging as unwanted: find(thisItemParentId).length != 0");
					unwanted = true;
					
					// Is this item id in the database?
					if (existingDBEntry) {
						// item exists in database, most likely moved out of scope for current client configuration
						log.vdebug("This item was previously synced / seen by the client");
						if (("name" in onedriveJSONItem["parentReference"]) != null) {
							
							// How is this out of scope?
							// is sync_list configured
							if (syncListConfigured) {
								// sync_list configured and in use
								if (selectiveSync.isPathExcludedViaSyncList(onedriveJSONItem["parentReference"]["name"].str)) {
									// Previously synced item is now out of scope as it has been moved out of what is included in sync_list
									log.vdebug("This previously synced item is now excluded from being synced due to sync_list exclusion");
								}
							}
							// flag to delete local file as it now is no longer in sync with OneDrive
							log.vdebug("Flagging to delete item locally: ", onedriveJSONItem);
							idsToDelete ~= [thisItemDriveId, thisItemId];
						}
					}	
				}
			}
			
			// Check the item type - if it not an item type that we support, we cant process the JSON item
			if (!unwanted) {
				if (isItemFile(onedriveJSONItem)) {
					log.vdebug("The item we are syncing is a file");
				} else if (isItemFolder(onedriveJSONItem)) {
					log.vdebug("The item we are syncing is a folder");
				} else if (isItemRemote(onedriveJSONItem)) {
					log.vdebug("The item we are syncing is a remote item");
				} else {
					// Why was this unwanted?
					if (newItemPath.empty) {
						// Compute this item path & need the full path for this file
						newItemPath = computeItemPath(thisItemDriveId, thisItemParentId) ~ "/" ~ thisItemName;
						log.vdebug("New Item calculated full path is: ", newItemPath);
					}
					// Microsoft OneNote container objects present as neither folder or file but has file size
					if ((!isItemFile(onedriveJSONItem)) && (!isItemFolder(onedriveJSONItem)) && (hasFileSize(onedriveJSONItem))) {
						// Log that this was skipped as this was a Microsoft OneNote item and unsupported
						log.vlog("The Microsoft OneNote Notebook '", newItemPath, "' is not supported by this client");
					} else {
						// Log that this item was skipped as unsupported 
						log.vlog("The OneDrive item '", newItemPath, "' is not supported by this client");
					}
					unwanted = true;
					log.vdebug("Flagging as unwanted: item type is not supported");
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
							log.vdebug("skip_dir path to check (simple):  ", simplePathToCheck);
							
							// complex path
							if (parentInDatabase) {
								// build up complexPathToCheck
								complexPathToCheck = buildNormalizedPath(newItemPath);
							} else {
								log.vdebug("Parent details not in database - unable to compute complex path to check");
							}
							if (!complexPathToCheck.empty) {
								log.vdebug("skip_dir path to check (complex): ", complexPathToCheck);
							}
						} else {
							simplePathToCheck = onedriveJSONItem["name"].str;
						}
						
						// If 'simplePathToCheck' or 'complexPathToCheck'  is of the following format:  root:/folder
						// then isDirNameExcluded matching will not work
						// Clean up 'root:' if present
						if (startsWith(simplePathToCheck, "root:")){
							log.vdebug("Updating simplePathToCheck to remove 'root:'");
							simplePathToCheck = strip(simplePathToCheck, "root:");
						}
						if (startsWith(complexPathToCheck, "root:")){
							log.vdebug("Updating complexPathToCheck to remove 'root:'");
							complexPathToCheck = strip(complexPathToCheck, "root:");
						}
						
						// OK .. what checks are we doing?
						if ((!simplePathToCheck.empty) && (complexPathToCheck.empty)) {
							// just a simple check
							log.vdebug("Performing a simple check only");
							unwanted = selectiveSync.isDirNameExcluded(simplePathToCheck);
						} else {
							// simple and complex
							log.vdebug("Performing a simple then complex path match if required");
							// simple first
							log.vdebug("Performing a simple check first");
							unwanted = selectiveSync.isDirNameExcluded(simplePathToCheck);
							matchDisplay = simplePathToCheck;
							if (!unwanted) {
								log.vdebug("Simple match was false, attempting complex match");
								// simple didnt match, perform a complex check
								unwanted = selectiveSync.isDirNameExcluded(complexPathToCheck);
								matchDisplay = complexPathToCheck;
							}
						}
						// result
						log.vdebug("skip_dir exclude result (directory based): ", unwanted);
						if (unwanted) {
							// This path should be skipped
							log.vlog("Skipping item - excluded by skip_dir config: ", matchDisplay);
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
						log.vdebug("skip_dir exclude result (file based): ", unwanted);
						if (unwanted) {
							// this files path should be skipped
							log.vlog("Skipping item - file path is excluded by skip_dir config: ", newItemPath);	
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
							log.vdebug("New Item calculated full path is: ", newItemPath);
						}
						
						// The path that needs to be checked needs to include the '/'
						// This due to if the user has specified in skip_file an exclusive path: '/path/file' - that is what must be matched
						// However, as 'path' used throughout, use a temp variable with this modification so that we use the temp variable for exclusion checks
						string exclusionTestPath = "";
						if (!startsWith(newItemPath, "/")){
							// Add '/' to the path
							exclusionTestPath = '/' ~ newItemPath;
						}
						
						log.vdebug("skip_file item to check: ", exclusionTestPath);
						unwanted = selectiveSync.isFileNameExcluded(exclusionTestPath);
						log.vdebug("Result: ", unwanted);
						if (unwanted) log.vlog("Skipping item - excluded by skip_file config: ", thisItemName);
					} else {
						// parent id is not in the database
						unwanted = true;
						log.vlog("Skipping file - parent path not present in local database");
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
						log.vdebug("New Item calculated full path is: ", newItemPath);
					}
					
					// What path are we checking?
					log.vdebug("sync_list item to check: ", newItemPath);
					
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
							log.vlog("Skipping item - excluded by sync_list config: ", newItemPath);
							// flagging to skip this item now, but does this exist in the DB thus needs to be removed / deleted?
							if (existingDBEntry) {
								// flag to delete
								log.vlog("Flagging item for local delete as item exists in database: ", newItemPath);
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
						log.vlog("Skipping item - .file or .folder: ", newItemPath);
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
						log.vlog("Skipping downloading item - .nosync found in parent folder & --check-for-nosync is enabled: ", newItemPath);
						unwanted = true;
					}
				}
			}
			
			// Check if this is excluded by a user set maximum filesize to download
			if (!unwanted) {
				if (isItemFile(onedriveJSONItem)) {
					if (fileSizeLimit != 0) {
						if (onedriveJSONItem["size"].integer >= fileSizeLimit) {
							log.vlog("Skipping item - excluded by skip_size config: ", thisItemName, " (", onedriveJSONItem["size"].integer/2^^20, " MB)");
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
				log.vdebug("Skipping OneDrive change as this is determined to be unwanted");
				// Add to the skippedItems array, but only if it is a directory ... pointless adding 'files' here, as it is the 'id' we check as the parent path which can only be a directory
				if (!isItemFile(onedriveJSONItem)) {
					skippedItems ~= thisItemId;
				}
			} else {
				// This JSON item is wanted - we need to process this JSON item further
				// Take the JSON item and create a consumable object for eventual database insertion
				Item newDatabaseItem = makeItem(onedriveJSONItem);
				
				if (existingDBEntry) {
					// The details of this JSON item are already in the DB
					// Is the item in the DB the same as the JSON data provided - or is the JSON data advising this is an updated file?
					log.vdebug("OneDrive change is an update to an existing local item");
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
					log.vdebug("OneDrive change is potentially a new local item");
					
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
			log.vlog("Items to potentially delete locally: ", idsToDelete.length);
			if (appConfig.getValueBool("download_only")) {
				// Download only has been configured
				if (cleanupLocalFiles) {
					// Process online deleted items
					log.vlog("Processing local deletion activity as --download-only & --cleanup-local-files configured");
					processDeleteItems();
				} else {
					// Not cleaning up local files
					log.vlog("Skipping local deletion activity as --download-only has been used");
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
			log.vlog("Number of items to download from OneDrive: ", fileJSONItemsToDownload.length);
			downloadOneDriveItems();
			// Cleanup array memory
			fileJSONItemsToDownload = [];
		}
		
		// Are there any skipped items still?
		if (!skippedItems.empty) {
			// Cleanup array memory
			skippedItems = [];
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
			// Issue #2209 fix - test if path is a bad symbolic link
			if (isSymlink(newItemPath)) {
				log.vdebug("Path on local disk is a symbolic link ........");
				if (!exists(readLink(newItemPath))) {
					// reading the symbolic link failed	
					log.vdebug("Reading the symbolic link target failed ........ ");
					log.logAndNotify("Skipping item - invalid symbolic link: ", newItemPath);
					return;
				}
			}
			
			// Path exists locally, is not a bad symbolic link
			// Test if this item is actually in-sync
			// What is the source of this item data?
			string itemSource = "remote";
			if (isItemSynced(newDatabaseItem, newItemPath, itemSource)) {
				// Item details from OneDrive and local item details in database are in-sync
				log.vdebug("The item to sync is already present on the local filesystem and is in-sync with what is reported online");
				log.vdebug("Update/Insert local database with item details");
				log.vdebug("item details to update/insert: ", newDatabaseItem);
				itemDB.upsert(newDatabaseItem);
				return;
			} else {
				// Item details from OneDrive and local item details in database are NOT in-sync
				log.vdebug("The item to sync exists locally but is NOT in the local database - otherwise this would be handled as changed item");
				
				// Which object is newer? The local file or the remote file?
				SysTime localModifiedTime = timeLastModified(newItemPath).toUTC();
				SysTime itemModifiedTime = newDatabaseItem.mtime;
				// Reduce time resolution to seconds before comparing
				localModifiedTime.fracSecs = Duration.zero;
				itemModifiedTime.fracSecs = Duration.zero;
				
				// If we need to rename the file, what do we rename it to?
				auto ext = extension(newItemPath);
				auto renamedNewItemPath = newItemPath.chomp(ext) ~ "-" ~ deviceName ~ ext;
				
				// Is the local modified time greater than that from OneDrive?
				if (localModifiedTime > itemModifiedTime) {
					// Local file is newer than item on OneDrive based on file modified time
					// Is this item id in the database?
					if (itemDB.idInLocalDatabase(newDatabaseItem.driveId, newDatabaseItem.id)) {
						// item id is in the database
						// no local rename
						// no download needed
						log.vlog("Local item modified time is newer based on UTC time conversion - keeping local item as this exists in the local database");
						log.vdebug("Skipping OneDrive change as this is determined to be unwanted due to local item modified time being newer than OneDrive item and present in the sqlite database");
					} else {
						// item id is not in the database .. maybe a --resync ?
						// file exists locally but is not in the sqlite database - maybe a failed download?
						log.vlog("Local item does not exist in local database - replacing with file from OneDrive - failed download?");
						
						// In a --resync scenario or if items.sqlite3 was deleted before startup we have zero way of knowing IF the local file is meant to be the right file
						// To this pint we have passed the following checks:
						// 1. Any client side filtering checks - this determined this is a file that is wanted
						// 2. A file with the exact name exists locally
						// 3. The local modified time > remote modified time
						// 4. The id of the item from OneDrive is not in the database
						
						// Has the user configured to IGNORE local data protection rules?
						if (bypassDataPreservation) {
							// The user has configured to ignore data safety checks and overwrite local data rather than preserve & rename
							log.vlog("WARNING: Local Data Protection has been disabled. You may experience data loss on this file: ", newItemPath);
						} else {
							// local data protection is configured, renaming local file
							log.log("The local item is out-of-sync with OneDrive, renaming to preserve existing file and prevent local data loss: ", newItemPath, " -> ", renamedNewItemPath);
							// perform the rename action of the local file
							if (!dryRun) {
								// Perform the local rename of the existing local file
								safeRename(newItemPath, renamedNewItemPath, dryRun);
							} else {
								// Expectation here is that there is a new file locally (renamedNewItemPath) however as we don't create this, the "new file" will not be uploaded as it does not exist
								log.vdebug("DRY-RUN: Skipping local file rename");
							}
						}
					}
				} else {
					// Remote file is newer than the existing local item
					log.vlog("Remote item modified time is newer based on UTC time conversion"); // correct message, remote item is newer
					log.vdebug("localModifiedTime (local file):   ", localModifiedTime);
					log.vdebug("itemModifiedTime (OneDrive item): ", itemModifiedTime);
					
					// Has the user configured to IGNORE local data protection rules?
					if (bypassDataPreservation) {
						// The user has configured to ignore data safety checks and overwrite local data rather than preserve & rename
						log.vlog("WARNING: Local Data Protection has been disabled. You may experience data loss on this file: ", newItemPath);
					} else {
						// local data protection is configured, renaming local file
						log.vlog("The local item is out-of-sync with OneDrive, renaming to preserve existing file and prevent data loss: ", newItemPath, " -> ", renamedNewItemPath);
						// perform the rename action of the local file
						if (!dryRun) {
							// Perform the local rename of the existing local file
							safeRename(newItemPath, renamedNewItemPath, dryRun);
						} else {
							// Expectation here is that there is a new file locally (renamedNewItemPath) however as we don't create this, the "new file" will not be uploaded as it does not exist
							log.vdebug("DRY-RUN: Skipping local file rename");
						}							
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
				log.log("Creating local directory: ", newItemPath);
				if (!dryRun) {
					try {
						// Create the new directory
						log.vdebug("Requested path does not exist, creating directory structure: ", newItemPath);
						mkdirRecurse(newItemPath);
						// Configure the applicable permissions for the folder
						log.vdebug("Setting directory permissions for: ", newItemPath);
						newItemPath.setAttributes(appConfig.returnRequiredDirectoryPermisions());
						// Update the time of the folder to match the last modified time as is provided by OneDrive
						// If there are any files then downloaded into this folder, the last modified time will get 
						// updated by the local Operating System with the latest timestamp - as this is normal operation
						// as the directory has been modified
						log.vdebug("Setting directory lastModifiedDateTime for: ", newItemPath , " to ", newDatabaseItem.mtime);
						log.vdebug("Calling setTimes() for this file: ", newItemPath);
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
				log.log("Moving ", existingItemPath, " to ", changedItemPath);
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
							log.vlog("Destination is in sync and will be overwritten");
						} else {
							// The destination item is different
							log.vlog("The destination is occupied with a different item, renaming the conflicting file...");
							// Backup this item, passing in if we are performing a --dry-run or not
							safeBackup(changedItemPath, dryRun);
						}
					} else {
						// The to be overwritten item is not already in the itemdb, so it should saved to avoid data loss
						log.vlog("The destination is occupied by an existing un-synced file, renaming the conflicting file...");
						// Backup this item, passing in if we are performing a --dry-run or not
						safeBackup(changedItemPath, dryRun);
					}
				}
				
				// Try and rename path, catch any exception generated
				try {
					// Rename this item, passing in if we are performing a --dry-run or not
					safeRename(existingItemPath, changedItemPath, dryRun);
					
					// If the item is a file, make sure that the local timestamp now is the same as the timestamp online
					// Otherwise when we do the DB check, the move on the file system, the file technically has a newer timestamp
					// which is 'correct' .. but we need to report locally the online timestamp here as the move was made online
					if (changedOneDriveItem.type == ItemType.file) {
						setTimes(changedItemPath, changedOneDriveItem.mtime, changedOneDriveItem.mtime);
					}
					
					// Flag that the item was moved | renamed
					itemWasMoved = true;
										
					// If we are in a --dry-run situation, the actual rename did not occur - but we need to track like it did
					if (dryRun) {
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
						log.vdebug("Adding changed OneDrive Item to database: ", changedOneDriveItem);
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
				log.vdebug("Adding changed OneDrive Item to database: ", changedOneDriveItem);
				itemDB.upsert(changedOneDriveItem);
			}
		}
	}
	
	// Download new file items as identified
	void downloadOneDriveItems() {
		// Lets deal with all the JSON items that need to be downloaded in a batch process
		ulong batchSize = appConfig.concurrentThreads;
		ulong batchCount = (fileJSONItemsToDownload.length + batchSize - 1) / batchSize;
		ulong batchesProcessed = 0;
		
		foreach (chunk; fileJSONItemsToDownload.chunks(batchSize)) {
			// send an array containing 'appConfig.concurrentThreads' (16) JSON items to download
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
		log.vdebug("New Item calculated full path is: ", newItemPath);
		
		// Is the item reported as Malware ?
		if (isMalware(onedriveJSONItem)){
			// OneDrive reports that this file is malware
			log.error("ERROR: MALWARE DETECTED IN FILE - DOWNLOAD SKIPPED: ", newItemPath);
			downloadFailed = true;
		} else {
			// Grab this file's filesize
			if (hasFileSize(onedriveJSONItem)) {
				// Use the configured filesize as reported by OneDrive
				jsonFileSize = onedriveJSONItem["size"].integer;
			} else {
				// filesize missing
				log.vdebug("WARNING: onedriveJSONItem['size'] is missing");
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
				log.vdebug("WARNING: onedriveJSONItem['file']['hashes'] is missing - unable to compare file hash after download");
			}
		
			// Is there enough free space locally to download the file
			// - We can use '.' here as we change the current working directory to the configured 'sync_dir'
			ulong localActualFreeSpace = to!ulong(getAvailableDiskSpace("."));
			// So that we are not responsible in making the disk 100% full if we can download the file, compare the current available space against the reservation set and file size
			// The reservation value is user configurable in the config file, 50MB by default
			ulong freeSpaceReservation = appConfig.getValueLong("space_reservation");
			// debug output
			log.vdebug("Local Disk Space Actual: ", localActualFreeSpace);
			log.vdebug("Free Space Reservation:  ", freeSpaceReservation);
			log.vdebug("File Size to Download:   ", jsonFileSize);
			
			// Calculate if we can actually download file - is there enough free space?
			if ((localActualFreeSpace < freeSpaceReservation) || (jsonFileSize > localActualFreeSpace)) {
				// localActualFreeSpace is less than freeSpaceReservation .. insufficient free space
				// jsonFileSize is greater than localActualFreeSpace .. insufficient free space
				log.log("Downloading file ", newItemPath, " ... failed!");
				log.log("Insufficient local disk space to download file");
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
						log.vdebug("downloadFileOneDriveApiInstance.downloadById(downloadDriveId, downloadItemId, newItemPath, jsonFileSize); generated a OneDriveException");
						
						string thisFunctionName = getFunctionName!({});
						// HTTP request returned status code 408,429,503,504
						if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 429) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
							// Handle the 429
							if (exception.httpStatusCode == 429) {
								// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
								handleOneDriveThrottleRequest(downloadFileOneDriveApiInstance);
								log.vdebug("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - attempting to retry ", thisFunctionName);
							}
							// re-try the specific changes queries
							if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
								// 408 - Request Time Out
								// 503 - Service Unavailable
								// 504 - Gateway Timeout
								// Transient error - try again in 30 seconds
								auto errorArray = splitLines(exception.msg);
								log.log(errorArray[0], " when attempting to download an item from OneDrive - retrying applicable request in 30 seconds");
								log.vdebug(thisFunctionName, " previously threw an error - retrying");
								// The server, while acting as a proxy, did not receive a timely response from the upstream server it needed to access in attempting to complete the request. 
								log.vdebug("Thread sleeping for 30 seconds as the server did not receive a timely response from the upstream server it needed to access in attempting to complete the request");
								Thread.sleep(dur!"seconds"(30));
							}
							// re-try original request - retried for 429, 503, 504 - but loop back calling this function 
							log.vdebug("Retrying Function: ", thisFunctionName);
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
								log.vdebug("Downloaded file matches reported size and reported file hash");
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
									log.vdebug("Calling setTimes() for this file: ", newItemPath);
									setTimes(newItemPath, itemModifiedTime, itemModifiedTime);
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
									log.vdebug("Actual file size on disk:   ", downloadFileSize);
									log.vdebug("OneDrive API reported size: ", jsonFileSize);
									log.error("ERROR: File download size mis-match. Increase logging verbosity to determine why.");
								}
								// Hash Error
								if (downloadedFileHash != onlineFileHash) {
									// downloaded file hash does not match
									downloadValueMismatch = true;
									log.vdebug("Actual local file hash:     ", downloadedFileHash);
									log.vdebug("OneDrive API reported hash: ", onlineFileHash);
									log.error("ERROR: File download hash mis-match. Increase logging verbosity to determine why.");
								}
								// .heic data loss check
								// - https://github.com/abraunegg/onedrive/issues/2471
								// - https://github.com/OneDrive/onedrive-api-docs/issues/1532
								// - https://github.com/OneDrive/onedrive-api-docs/issues/1723
								if (downloadValueMismatch && (toLower(extension(newItemPath)) == ".heic")) {
									// Need to display a message to the user that they have experienced data loss
									log.error("DATA-LOSS: File downloaded has experienced data loss due to a Microsoft OneDrive API bug. DO NOT DELETE THIS FILE ONLINE.");
									log.vlog("           Please read https://github.com/OneDrive/onedrive-api-docs/issues/1723 for more details.");
								}
								
								// Add some workaround messaging for SharePoint
								if (appConfig.accountType == "documentLibrary"){
									// It has been seen where SharePoint / OneDrive API reports one size via the JSON 
									// but the content length and file size written to disk is totally different - example:
									// From JSON:         "size": 17133
									// From HTTPS Server: < Content-Length: 19340
									// with no logical reason for the difference, except for a 302 redirect before file download
									log.error("INFO: It is most likely that a SharePoint OneDrive API issue is the root cause. Add --disable-download-validation to work around this issue but downloaded data integrity cannot be guaranteed.");
								} else {
									// other account types
									log.error("INFO: Potentially add --disable-download-validation to work around this issue but downloaded data integrity cannot be guaranteed.");
								}
								// We do not want this local file to remain on the local file system as it failed the integrity checks
								log.log("Removing file ", newItemPath, " due to failed integrity checks");
								if (!dryRun) {
									safeRemove(newItemPath);
								}
								downloadFailed = true;
							}
						} else {
							// Download validation checks were disabled
							log.vdebug("Downloaded file validation disabled due to --disable-download-validation");
							log.vlog("WARNING: Skipping download integrity check for: ", newItemPath);
						}	 // end of (!disableDownloadValidation)
					} else {
						log.error("ERROR: File failed to download. Increase logging verbosity to determine why.");
						downloadFailed = true;
					}
				}
			}
			
			// File should have been downloaded
			if (!downloadFailed) {
				// Download did not fail
				log.log("Downloading file ", newItemPath, " ... done");
				// Save this item into the database
				saveItem(onedriveJSONItem);
				
				/**
				log.vdebug("Inserting new item details to local database");
				// What was the item that was saved
				log.vdebug("item details: ", newDatabaseItem);
				itemDB.upsert(newDatabaseItem);
				**/
				
				
				// If we are in a --dry-run situation - if we are, we need to track that we faked the download
				if (dryRun) {
					// track that we 'faked it'
					idsFaked ~= [downloadDriveId, downloadItemId];
				}
			} else {
				// Output download failed
				log.log("Downloading file ", newItemPath, " ... failed!");
				// Add the path to a list of items that failed to download
				fileDownloadFailures ~= newItemPath;
			}
		}
	}
	
	// Test if the given item is in-sync. Returns true if the given item corresponds to the local one
	bool isItemSynced(Item item, string path, string itemSource) {
		
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
						log.vlog("Local item time discrepancy detected: ", path);
						log.vlog("This local item has a different modified time ", localModifiedTime, " when compared to ", itemSource, " modified time ", itemModifiedTime);
						// The file has been modified ... is the hash the same?
						// Test the file hash as the date / time stamp is different
						// Generating a hash is computationally expensive - we only generate the hash if timestamp was different
						if (testFileHash(path, item)) {
							// The hash is the same .. so we need to fix-up the timestamp depending on where it is wrong
							log.vlog("Local item has the same hash value as the item online - correcting timestamp");
							// Test if the local timestamp is newer
							if (localModifiedTime > itemModifiedTime) {
								// The source of the out-of-date timestamp was OneDrive and this needs to be corrected to avoid always generating a hash test if timestamp is different
								log.vlog("The source of the incorrect timestamp was OneDrive online - correcting timestamp online");
								if (!dryRun) {
									// Attempt to update the online date time stamp
									uploadLastModifiedTime(item.driveId, item.id, localModifiedTime.toUTC(), item.eTag);
								}
							} else {
								// The source of the out-of-date timestamp was the local file and this needs to be corrected to avoid always generating a hash test if timestamp is different
								log.vlog("The source of the incorrect timestamp was the local file - correcting timestamp locally");
								if (!dryRun) {
									log.vdebug("Calling setTimes() for this file: ", path);
									setTimes(path, item.mtime, item.mtime);
								}
							}
							return true;
						} else {
							// The hash is different so the content of the file has to be different as to what is stored online
							log.vlog("The local item has a different hash when compared to ", itemSource, " item hash");
							return false;
						}
					}
				} else {
					// Unable to read local file
					log.log("Unable to determine the sync state of this file as it cannot be read (file permissions or file corruption): ", path);
					return false;
				}
			} else {
				log.vlog("The local item is a directory but should be a file");
			}
			break;
		case ItemType.dir:
		case ItemType.remote:
			if (isDir(path)) {
				return true;
			} else {
				log.vlog("The local item is a file but should be a directory");
			}
			break;
		case ItemType.unknown:
			// Unknown type - return true but we dont action or sync these items 
			return true;
		}
		return false;
	}
	
	// Get the /delta data using the provided details
	JSONValue getDeltaChangesByItemId(string selectedDriveId, string selectedItemId, string providedDeltaLink) {
		
		// Function variables
		JSONValue deltaChangesBundle;
		// Get the /delta data for this account | driveId | deltaLink combination
		// Create a new API Instance for this thread and initialise it
		OneDriveApi getDeltaQueryOneDriveApiInstance;
		getDeltaQueryOneDriveApiInstance = new OneDriveApi(appConfig);
		getDeltaQueryOneDriveApiInstance.initialise();
		
		log.vdebug("------------------------------------------------------------------");
		log.vdebug("selectedDriveId:   ", selectedDriveId);
		log.vdebug("selectedItemId:    ", selectedItemId);
		log.vdebug("providedDeltaLink: ", providedDeltaLink);
		log.vdebug("------------------------------------------------------------------");
		
		try {
			deltaChangesBundle = getDeltaQueryOneDriveApiInstance.viewChangesByItemId(selectedDriveId, selectedItemId, providedDeltaLink);
		} catch (OneDriveException exception) {
			// caught an exception
			log.vdebug("getDeltaQueryOneDriveApiInstance.viewChangesByItemId(selectedDriveId, selectedItemId, providedDeltaLink) generated a OneDriveException");
			
			auto errorArray = splitLines(exception.msg);
			string thisFunctionName = getFunctionName!({});
			// HTTP request returned status code 408,429,503,504
			if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 429) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
				// Handle the 429
				if (exception.httpStatusCode == 429) {
					// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
					handleOneDriveThrottleRequest(getDeltaQueryOneDriveApiInstance);
					log.vdebug("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - attempting to retry ", thisFunctionName);
				}
				// re-try the specific changes queries
				if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
					// 408 - Request Time Out
					// 503 - Service Unavailable
					// 504 - Gateway Timeout
					// Transient error - try again in 30 seconds
					log.log(errorArray[0], " when attempting to query OneDrive API for Delta Changes - retrying applicable request in 30 seconds");
					log.vdebug(thisFunctionName, " previously threw an error - retrying");
					// The server, while acting as a proxy, did not receive a timely response from the upstream server it needed to access in attempting to complete the request. 
					log.vdebug("Thread sleeping for 30 seconds as the server did not receive a timely response from the upstream server it needed to access in attempting to complete the request");
					Thread.sleep(dur!"seconds"(30));
				}
				// dont retry request, loop back to calling function
				log.vdebug("Looping back after failure");
				deltaChangesBundle = null;
			} else {
				// Default operation if not 408,429,503,504 errors
				if (exception.httpStatusCode == 410) {
					log.log("\nWARNING: The OneDrive API responded with an error that indicates the locally stored deltaLink value is invalid");
					// Essentially the 'providedDeltaLink' that we have stored is no longer available ... re-try without the stored deltaLink
					log.log("WARNING: Retrying OneDrive API call without using the locally stored deltaLink value");
					// Configure an empty deltaLink
					log.vdebug("Delta link expired for 'getDeltaQueryOneDriveApiInstance.viewChangesByItemId(selectedDriveId, selectedItemId, providedDeltaLink)', setting 'deltaLink = null'");
					string emptyDeltaLink = "";
					// retry with empty deltaLink
					deltaChangesBundle = getDeltaQueryOneDriveApiInstance.viewChangesByItemId(selectedDriveId, selectedItemId, emptyDeltaLink);
				} else {
					// display what the error is
					log.log("CODING TO DO: Hitting this failure error output");
					displayOneDriveErrorMessage(exception.msg, thisFunctionName);
					deltaChangesBundle = null;
				}
			}
		}
		
		// Shutdown the API
		getDeltaQueryOneDriveApiInstance.shutdown();
		// Free object and memory
		object.destroy(getDeltaQueryOneDriveApiInstance);
		return deltaChangesBundle;
	}
	
	// Common code to handle a 408 or 429 response from the OneDrive API
	void handleOneDriveThrottleRequest(OneDriveApi activeOneDriveApiInstance) {
		
		// If OneDrive sends a status code 429 then this function will be used to process the Retry-After response header which contains the value by which we need to wait
		log.vdebug("Handling a OneDrive HTTP 429 Response Code (Too Many Requests)");
		// Read in the Retry-After HTTP header as set and delay as per this value before retrying the request
		auto retryAfterValue = activeOneDriveApiInstance.getRetryAfterValue();
		log.vdebug("Using Retry-After Value = ", retryAfterValue);
		
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
			log.vdebug("HTTP Response Header retry-after value was 0 - Using a preconfigured default of: ", delayBeforeRetry);
		}
		
		// Sleep thread as per request
		log.log("Thread sleeping due to 'HTTP request returned status code 429' - The request has been throttled");
		log.log("Sleeping for ", delayBeforeRetry, " seconds");
		Thread.sleep(dur!"seconds"(delayBeforeRetry));
		
		// Reset retry-after value to zero as we have used this value now and it may be changed in the future to a different value
		activeOneDriveApiInstance.resetRetryAfterValue();
	}
	
	// If the JSON response is not correct JSON object, exit
	void invalidJSONResponseFromOneDriveAPI() {
		log.error("ERROR: Query of the OneDrive API returned an invalid JSON response");
		// Must exit
		exit(-1);
	}
	
	// Handle an unhandled API error
	void defaultUnhandledHTTPErrorCode(OneDriveException exception) {
		
		// display error
		displayOneDriveErrorMessage(exception.msg, getFunctionName!({}));
		// Must exit here
		exit(-1);
	}
	
	// Display the pertinant details of the sync engine
	void displaySyncEngineDetails() {
		
		// Display accountType, defaultDriveId, defaultRootId & remainingFreeSpace for verbose logging purposes
		//log.vlog("Application version:  ", strip(import("version")));
		
		string tempVersion = "v2.5.0-alpha-2" ~ " GitHub version: " ~ strip(import("version"));
		log.vlog("Application version:  ", tempVersion);
		
		log.vlog("Account Type:         ", appConfig.accountType);
		log.vlog("Default Drive ID:     ", appConfig.defaultDriveId);
		log.vlog("Default Root ID:      ", appConfig.defaultRootId);
		
		// What do we display here for space remaining
		if (appConfig.remainingFreeSpace > 0) {
			// Display the actual value
			log.vlog("Remaining Free Space: ", (appConfig.remainingFreeSpace/1024) , " KB");
		} else {
			// zero or non-zero value or restricted
			if (!appConfig.quotaRestricted){
				log.vlog("Remaining Free Space:       0 KB");
			} else {
				log.vlog("Remaining Free Space:       Not Available");
			}
		}
	}
	
	// Query itemdb.computePath() and catch potential assert when DB consistency issue occurs
	string computeItemPath(string thisDriveId, string thisItemId) {
		
		// static declare this for this function
		static import core.exception;
		string calculatedPath;
		log.vdebug("Attempting to calculate local filesystem path for ", thisDriveId, " and ", thisItemId);
		try {
			calculatedPath = itemDB.computePath(thisDriveId, thisItemId);
		} catch (core.exception.AssertError) {
			// broken tree in the database, we cant compute the path for this item id, exit
			log.error("ERROR: A database consistency issue has been caught. A --resync is needed to rebuild the database.");
			// Must exit here to preserve data
			exit(-1);
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
					log.log("Trying to delete file ", path);
				} else {
					log.log("Trying to delete directory ", path);
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
						log.log("Skipped due to id difference!");
					}
				} else {
					// item has disappeared completely
					needsRemoval = true;
				}
			}
			if (needsRemoval) {
				// Log the action
				if (item.type == ItemType.file) {
					log.log("Deleting file ", path);
				} else {
					log.log("Deleting directory ", path);
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
					log.vdebug("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - attempting to retry ", thisFunctionName);
				}
				// re-try the specific changes queries
				if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
					// 408 - Request Time Out
					// 503 - Service Unavailable
					// 504 - Gateway Timeout
					// Transient error - try again in 30 seconds
					auto errorArray = splitLines(exception.msg);
					log.log(errorArray[0], " when attempting to update the timestamp on an item on OneDrive - retrying applicable request in 30 seconds");
					log.vdebug(thisFunctionName, " previously threw an error - retrying");
					// The server, while acting as a proxy, did not receive a timely response from the upstream server it needed to access in attempting to complete the request. 
					log.vdebug("Thread sleeping for 30 seconds as the server did not receive a timely response from the upstream server it needed to access in attempting to complete the request");
					Thread.sleep(dur!"seconds"(30));
				}
				// re-try original request - retried for 429, 503, 504 - but loop back calling this function 
				log.vdebug("Retrying Function: ", thisFunctionName);
				uploadLastModifiedTime(driveId, id, mtime, eTag);
				return;
			} else {
				// Default operation if not 408,429,503,504 errors
				if (exception.httpStatusCode == 409) {
					// ETag does not match current item's value - use a null eTag
					log.vdebug("Retrying Function: ", thisFunctionName);
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
			log.log("Performing a database consistency and integrity check on locally stored data ... ");
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
			log.vlog("Processing DB entries for this Drive ID: ", driveId);
			
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
						log.vdebug("Flagging to delete local item as it now is no longer in sync with OneDrive");
						log.vdebug("outOfSyncItem: ", outOfSyncItem);
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
					log.vdebug("Selecting DB items via itemDB.selectByDriveId(driveId)");
					// Query database
					driveItems = itemDB.selectByDriveId(driveId);
				}
				
				log.vdebug("Database items to process for this driveId: ", driveItems.count);
				// Process each database database item associated with the driveId
				foreach(dbItem; driveItems) {
					// Does it still exist on disk in the location the DB thinks it is
					checkDatabaseItemForConsistency(dbItem);
				}
			} else {
				// Check everything associated with each driveId we know about
				log.vdebug("Selecting DB items via itemDB.selectByDriveId(driveId)");
				// Query database
				auto driveItems = itemDB.selectByDriveId(driveId);
				log.vdebug("Database items to process for this driveId: ", driveItems.count);
				// Process each database database item associated with the driveId
				foreach(dbItem; driveItems) {
					// Does it still exist on disk in the location the DB thinks it is
					checkDatabaseItemForConsistency(dbItem);
				}
			}
		}
		
		// Are we doing a --download-only sync?
		if (!appConfig.getValueBool("download_only")) {
			// Do we have any known items, where the content has changed locally, that needs to be uploaded?
			if (!databaseItemsWhereContentHasChanged.empty) {
				// There are changed local files that were in the DB to upload
				log.log("Changed local items to upload to OneDrive: ", databaseItemsWhereContentHasChanged.length);
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
			// use what was computed
			logOutputPath = localFilePath;
		}
		
		// Log what we are doing
		log.vlog("Processing ", logOutputPath);
		
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
						log.vdebug("The local item has a different modified time ", localModifiedTime, " when compared to ", itemSource, " modified time ", itemModifiedTime);
						// Test the file hash
						if (!testFileHash(localFilePath, dbItem)) {
							// Is the local file 'newer' or 'older' (ie was an old file 'restored locally' by a different backup / replacement process?)
							if (localModifiedTime >= itemModifiedTime) {
								// Local file is newer
								if (!appConfig.getValueBool("download_only")) {
									log.vlog("The file content has changed locally and has a newer timestamp, thus needs to be uploaded to OneDrive");
									// Add to an array of files we need to upload as this file has changed locally in-between doing the /delta check and performing this check
									databaseItemsWhereContentHasChanged ~= [dbItem.driveId, dbItem.id, localFilePath];
								} else {
									log.vlog("The file content has changed locally and has a newer timestamp. The file will remain different to online file due to --download-only being used");
								}
							} else {
								// Local file is older - data recovery process? something else?
								if (!appConfig.getValueBool("download_only")) {
									log.vlog("The file content has changed locally and file now has a older timestamp. Uploading this file to OneDrive may potentially cause data-loss online");
									// Add to an array of files we need to upload as this file has changed locally in-between doing the /delta check and performing this check
									databaseItemsWhereContentHasChanged ~= [dbItem.driveId, dbItem.id, localFilePath];
								} else {
									log.vlog("The file content has changed locally and file now has a older timestamp. The file will remain different to online file due to --download-only being used");
								}
							}
						} else {
							// The file contents have not changed, but the modified timestamp has
							log.vlog("The last modified timestamp has changed however the file content has not changed");
							log.vlog("The local item has the same hash value as the item online - correcting timestamp online");
							if (!dryRun) {
								// Attempt to update the online date time stamp
								uploadLastModifiedTime(dbItem.driveId, dbItem.id, localModifiedTime.toUTC(), dbItem.eTag);
							}
						}
					} else {
						// The file has not changed
						log.vlog("The file has not changed");
					}
				} else {
					//The file is not readable - skipped
					log.log("Skipping processing this file as it cannot be read (file permissions or file corruption): ", localFilePath);
				}
			} else {
				// The item was a file but now is a directory
				log.vlog("The item was a file but now is a directory");
			}
		} else {
			// File does not exist locally, but is in our database as a dbItem containing all the data was passed into this function
			// If we are in a --dry-run situation - this file may never have existed as we never downloaded it
			if (!dryRun) {
				// Not --dry-run situation
				log.vlog("The file has been deleted locally");
				// Upload to OneDrive the instruction to delete this item. This will handle the 'noRemoteDelete' flag if set
				uploadDeletedItem(dbItem, localFilePath);
			} else {
				// We are in a --dry-run situation, file appears to have been deleted locally - this file may never have existed locally as we never downloaded it due to --dry-run
				// Did we 'fake create it' as part of --dry-run ?
				bool idsFakedMatch = false;
				foreach (i; idsFaked) {
					if (i[1] == dbItem.id) {
						log.vdebug("Matched faked file which is 'supposed' to exist but not created due to --dry-run use");
						log.vlog("The file has not changed");
						idsFakedMatch = true;
					}
				}
				if (!idsFakedMatch) {
					// dbItem.id did not match a 'faked' download new file creation - so this in-sync object was actually deleted locally, but we are in a --dry-run situation
					log.vlog("The file has been deleted locally");
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
					log.vlog("The item was a directory but now it is a file");
					uploadDeletedItem(dbItem, localFilePath);
					uploadNewFile(localFilePath);
				} else {
					// Directory still exists locally
					log.vlog("The directory has not changed");
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
					log.vlog("The directory has been deleted locally");
				} else {
					// Appropriate message as we are in --monitor mode
					log.vlog("The directory appears to have been deleted locally .. but we are running in --monitor mode. This may have been 'moved' on the local filesystem rather than being 'deleted'");
					log.vdebug("Most likely cause - 'inotify' event was missing for whatever action was taken locally or action taken when application was stopped");
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
						log.vdebug("Matched faked dir which is 'supposed' to exist but not created due to --dry-run use");
						log.vlog("The directory has not changed");
						idsFakedMatch = true;
					}
				}
				if (!idsFakedMatch) {
					// dbItem.id did not match a 'faked' download new directory creation - so this in-sync object was actually deleted locally, but we are in a --dry-run situation
					log.vlog("The directory has been deleted locally");
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
	
	/**
	// Perform the database consistency check on this remote directory item
	void checkRemoteDirectoryDatabaseItemForConsistency(Item dbItem, string localFilePath) {
	
		writeln("CODING TO DO: checkRemoteDirectoryDatabaseItemForConsistency");
	}
	**/
	
	// Does this Database Item (directory or file) get excluded from any operation based on any client side filtering rules?
	bool checkDBItemAndPathAgainstClientSideFiltering(Item dbItem, string localFilePath) {
		
		// Check the item and path against client side filtering rules
		// Return a true|false response
		bool clientSideRuleExcludesItem = false;
		
		// Is this item a directory or 'remote' type? A 'remote' type is a folder DB tie so should be compared as directory for exclusion
		if ((dbItem.type == ItemType.dir) || (dbItem.type == ItemType.remote)) {
			
			// Directory Path Tests
			if (!clientSideRuleExcludesItem) {
				// Do we need to check for .nosync? Only if --check-for-nosync was passed in
				if (appConfig.getValueBool("check_nosync")) {
					if (exists(localFilePath ~ "/.nosync")) {
						log.vlog("Skipping item - .nosync found & --check-for-nosync enabled: ", localFilePath);
						clientSideRuleExcludesItem = true;
					}
				}
				
				// Is this item excluded by user configuration of skip_dir?
				if (!clientSideRuleExcludesItem) {
					clientSideRuleExcludesItem = selectiveSync.isDirNameExcluded(dbItem.name);
				}
			}
		}
		
		// Is this item a file?
		if (dbItem.type == ItemType.file) {
			// Is this item excluded by user configuration of skip_file?
			if (!clientSideRuleExcludesItem) {
				clientSideRuleExcludesItem = selectiveSync.isFileNameExcluded(dbItem.name);
			}
			
			if (!clientSideRuleExcludesItem) {
				// Check if file should be skipped based on user configured size limit 'skip_size'
				if (fileSizeLimit != 0) {
					// Get the file size
					ulong thisFileSize = getSize(localFilePath);
					if (thisFileSize >= fileSizeLimit) {
						clientSideRuleExcludesItem = true;
						log.vlog("Skipping item - excluded by skip_size config: ", localFilePath, " (", thisFileSize/2^^20," MB)");
					}
				}
			} 
		}
		
		if (!clientSideRuleExcludesItem) {
			// Is sync_list configured?
			if (syncListConfigured) {
				// Is this item excluded by user configuration of sync_list?
				clientSideRuleExcludesItem = selectiveSync.isPathExcludedViaSyncList(localFilePath);
			}
		}
	
		// Return bool value
		return clientSideRuleExcludesItem;
	}
	
	// Does this local path (directory or file) conform with the Microsoft Naming Restrictions?
	bool checkPathAgainstMicrosoftNamingRestrictions(string localFilePath) {
			
		// Check if the given path violates certain Microsoft restrictions and limitations
		// Return a true|false response
		bool invalidPath = false;
		
		// Check against Microsoft OneDrive restriction and limitations about Windows naming files
		if (!invalidPath) {
			if (!isValidName(localFilePath)) {
				log.logAndNotify("Skipping item - invalid name (Microsoft Naming Convention): ", localFilePath);
				invalidPath = true;
			}
		}
		
		// Check for bad whitespace items
		if (!invalidPath) {
			if (!containsBadWhiteSpace(localFilePath)) {
				log.logAndNotify("Skipping item - invalid name (Contains an invalid whitespace item): ", localFilePath);
				invalidPath = true;
			}
		}
		
		// Check for HTML ASCII Codes as part of file name
		if (!invalidPath) {
			if (!containsASCIIHTMLCodes(localFilePath)) {
				log.logAndNotify("Skipping item - invalid name (Contains HTML ASCII Code): ", localFilePath);
				invalidPath = true;
			}
		}
		// Return if this is a valid path
		return invalidPath;
	}
	
	// Does this local path (directory or file) get excluded from any operation based on any client side filtering rules?
	bool checkPathAgainstClientSideFiltering(string localFilePath) {
		
		// Unlike checkDBItemAndPathAgainstClientSideFiltering - we need to check the path only
	
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
	
		// - check_nosync
		if (!clientSideRuleExcludesPath) {
			// Do we need to check for .nosync? Only if --check-for-nosync was passed in
			if (appConfig.getValueBool("check_nosync")) {
				if (exists(localFilePath ~ "/.nosync")) {
					log.vlog("Skipping item - .nosync found & --check-for-nosync enabled: ", localFilePath);
					clientSideRuleExcludesPath = true;
				}
			}
		}
		
		// - skip_dotfiles
		if (!clientSideRuleExcludesPath) {
			// Do we need to check skip dot files if configured
			if (appConfig.getValueBool("skip_dotfiles")) {
				if (isDotFile(localFilePath)) {
					log.vlog("Skipping item - .file or .folder: ", localFilePath);
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
					log.vlog("Skipping item - skip symbolic links configured: ", localFilePath);
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
						log.vdebug("Not skipping item - symbolic link is a 'relative link' to target ('", relativeLink, "') which can be supported: ", localFilePath);
					} else {
						log.logAndNotify("Skipping item - invalid symbolic link: ", localFilePath);
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
					log.vdebug("Checking local path: ", localFilePath);
					// Only check path if config is != ""
					if (appConfig.getValueString("skip_dir") != "") {
						// The path that needs to be checked needs to include the '/'
						// This due to if the user has specified in skip_dir an exclusive path: '/path' - that is what must be matched
						if (selectiveSync.isDirNameExcluded(localFilePath.strip('.'))) {
							log.vlog("Skipping item - excluded by skip_dir config: ", localFilePath);
							clientSideRuleExcludesPath = true;
						}
					}
				}
				
				// skip_file handling
				if (isFile(localFilePath)) {
					log.vdebug("Checking file: ", localFilePath);
					// The path that needs to be checked needs to include the '/'
					// This due to if the user has specified in skip_file an exclusive path: '/path/file' - that is what must be matched
					if (selectiveSync.isFileNameExcluded(localFilePath.strip('.'))) {
						log.vlog("Skipping item - excluded by skip_file config: ", localFilePath);
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
							log.vdebug("Not skipping path due to sync_root_files inclusion: ", localFilePath);
						} else {
							if (exists(appConfig.syncListFilePath)){
								// skipped most likely due to inclusion in sync_list
								log.vlog("Skipping item - excluded by sync_list config: ", localFilePath);
								clientSideRuleExcludesPath = true;
							} else {
								// skipped for some other reason
								log.vlog("Skipping item - path excluded by user config: ", localFilePath);
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
						log.vlog("Skipping item - excluded by skip_size config: ", localFilePath, " (", thisFileSize/2^^20," MB)");
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
		// - skip_file (MISSING)
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
						log.vdebug("skip_dir path to check (simple):  ", simplePathToCheck);
						
						// complex path
						if (parentInDatabase) {
							// build up complexPathToCheck
							//complexPathToCheck = buildNormalizedPath(newItemPath);
							complexPathToCheck = computeItemPath(thisItemDriveId, thisItemParentId) ~ "/" ~ thisItemName;
						} else {
							log.vdebug("Parent details not in database - unable to compute complex path to check");
						}
						if (!complexPathToCheck.empty) {
							log.vdebug("skip_dir path to check (complex): ", complexPathToCheck);
						}
					} else {
						simplePathToCheck = onedriveJSONItem["name"].str;
					}
					
					// If 'simplePathToCheck' or 'complexPathToCheck'  is of the following format:  root:/folder
					// then isDirNameExcluded matching will not work
					// Clean up 'root:' if present
					if (startsWith(simplePathToCheck, "root:")){
						log.vdebug("Updating simplePathToCheck to remove 'root:'");
						simplePathToCheck = strip(simplePathToCheck, "root:");
					}
					if (startsWith(complexPathToCheck, "root:")){
						log.vdebug("Updating complexPathToCheck to remove 'root:'");
						complexPathToCheck = strip(complexPathToCheck, "root:");
					}
					
					// OK .. what checks are we doing?
					if ((!simplePathToCheck.empty) && (complexPathToCheck.empty)) {
						// just a simple check
						log.vdebug("Performing a simple check only");
						clientSideRuleExcludesPath = selectiveSync.isDirNameExcluded(simplePathToCheck);
					} else {
						// simple and complex
						log.vdebug("Performing a simple then complex path match if required");
						// simple first
						log.vdebug("Performing a simple check first");
						clientSideRuleExcludesPath = selectiveSync.isDirNameExcluded(simplePathToCheck);
						matchDisplay = simplePathToCheck;
						if (!clientSideRuleExcludesPath) {
							log.vdebug("Simple match was false, attempting complex match");
							// simple didnt match, perform a complex check
							clientSideRuleExcludesPath = selectiveSync.isDirNameExcluded(complexPathToCheck);
							matchDisplay = complexPathToCheck;
						}
					}
					// result
					log.vdebug("skip_dir exclude result (directory based): ", clientSideRuleExcludesPath);
					if (clientSideRuleExcludesPath) {
						// This path should be skipped
						log.vlog("Skipping item - excluded by skip_dir config: ", matchDisplay);
					}
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
					newItemPath = thisItemName;
				}
				
				// What path are we checking?
				log.vdebug("sync_list item to check: ", newItemPath);
				
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
						log.vlog("Skipping item - excluded by sync_list config: ", newItemPath);
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
		ulong batchSize = appConfig.concurrentThreads;
		ulong batchCount = (databaseItemsWhereContentHasChanged.length + batchSize - 1) / batchSize;
		ulong batchesProcessed = 0;
		
		// For each batch of files to upload, upload the changed data to OneDrive
		foreach (chunk; databaseItemsWhereContentHasChanged.chunks(batchSize)) {
			uploadChangedLocalFileToOneDrive(chunk);
		}
	}
	
	// Upload changed local files to OneDrive in parallel
	void uploadChangedLocalFileToOneDrive(string[3][] array) {
			
		foreach (i, localItemDetails; taskPool.parallel(array)) {
		
			log.vdebug("Thread ", i, " Starting: ", Clock.currTime());
		
			// These are the details of the item we need to upload
			string changedItemParentId = localItemDetails[0];
			string changedItemId = localItemDetails[1];
			string localFilePath = localItemDetails[2];
			
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
			
			// Get the file size
			ulong thisFileSizeLocal = getSize(localFilePath);
			ulong thisFileSizeFromDB = to!ulong(dbItem.size);
			
			// remainingFreeSpace online includes the current file online
			// we need to remove the online file (add back the existing file size) then take away the new local file size to get a new approximate value
			ulong calculatedSpaceOnlinePostUpload = (remainingFreeSpace + thisFileSizeFromDB) - thisFileSizeLocal;
			
			// Based on what we know, for this thread - can we safely upload this modified local file?
			log.vdebug("This Thread Current Free Space Online:                ", remainingFreeSpace);
			log.vdebug("This Thread Calculated Free Space Online Post Upload: ", calculatedSpaceOnlinePostUpload);
		
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
					if (uploadResponse.type() != JSONType.object){
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
					log.logAndNotify("Skipping uploading modified file ", localFilePath, " due to insufficient free space available on OneDrive");
				}
				// File exceeds max allowed size
				if (skippedMaxSize) {
					log.logAndNotify("Skipping uploading this modified file as it exceeds the maximum size allowed by OneDrive: ", localFilePath);
				}
				// Generic message
				if (skippedExceptionError) {
					// normal failure message if API or exception error generated
					log.logAndNotify("Uploading modified file ", localFilePath, " ... failed!");
				}
			} else {
				// Upload was successful
				log.logAndNotify("Uploading modified file ", localFilePath, " ... done.");
				
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
			
			log.vdebug("Thread ", i, " Finished: ", Clock.currTime());
		
		} // end of 'foreach (i, localItemDetails; array.enumerate)'
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
							log.vdebug("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - attempting to retry ", thisFunctionName);
						}
						// re-try the specific changes queries
						if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
							// 408 - Request Time Out
							// 503 - Service Unavailable
							// 504 - Gateway Timeout
							// Transient error - try again in 30 seconds
							auto errorArray = splitLines(exception.msg);
							log.log(errorArray[0], " when attempting to upload a modified file to OneDrive - retrying applicable request in 30 seconds");
							log.vdebug(thisFunctionName, " previously threw an error - retrying");
							// The server, while acting as a proxy, did not receive a timely response from the upstream server it needed to access in attempting to complete the request. 
							log.vdebug("Thread sleeping for 30 seconds as the server did not receive a timely response from the upstream server it needed to access in attempting to complete the request");
							Thread.sleep(dur!"seconds"(30));
						}
						// re-try original request - retried for 429, 503, 504 - but loop back calling this function 
						log.vdebug("Retrying Function: ", thisFunctionName);
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
				// The best way to do this is calculate the CRC32 of the file, and use this as the suffix of the session file we save
				string threadUploadSessionFilePath = appConfig.uploadSessionFilePath ~ "." ~ computeCRC32(localFilePath);
				
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
							log.vdebug("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - attempting to retry ", thisFunctionName);
						}
						// re-try the specific changes queries
						if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
							// 408 - Request Time Out
							// 503 - Service Unavailable
							// 504 - Gateway Timeout
							// Transient error - try again in 30 seconds
							auto errorArray = splitLines(exception.msg);
							log.log(errorArray[0], " when attempting to obtain latest file details from OneDrive - retrying applicable request in 30 seconds");
							log.vdebug(thisFunctionName, " previously threw an error - retrying");
							// The server, while acting as a proxy, did not receive a timely response from the upstream server it needed to access in attempting to complete the request. 
							log.vdebug("Thread sleeping for 30 seconds as the server did not receive a timely response from the upstream server it needed to access in attempting to complete the request");
							Thread.sleep(dur!"seconds"(30));
						}
						// re-try original request - retried for 429, 503, 504 - but loop back calling this function 
						log.vdebug("Retrying Function: ", thisFunctionName);
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
							log.vdebug("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - attempting to retry ", thisFunctionName);
						}
						// re-try the specific changes queries
						if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
							// 408 - Request Time Out
							// 503 - Service Unavailable
							// 504 - Gateway Timeout
							// Transient error - try again in 30 seconds
							auto errorArray = splitLines(exception.msg);
							log.log(errorArray[0], " when attempting to create an upload session on OneDrive - retrying applicable request in 30 seconds");
							log.vdebug(thisFunctionName, " previously threw an error - retrying");
							// The server, while acting as a proxy, did not receive a timely response from the upstream server it needed to access in attempting to complete the request. 
							log.vdebug("Thread sleeping for 30 seconds as the server did not receive a timely response from the upstream server it needed to access in attempting to complete the request");
							Thread.sleep(dur!"seconds"(30));
						}
						// re-try original request - retried for 429, 503, 504 - but loop back calling this function 
						log.vdebug("Retrying Function: ", thisFunctionName);
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
							log.vdebug("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - attempting to retry ", thisFunctionName);
						}
						// re-try the specific changes queries
						if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
							// 408 - Request Time Out
							// 503 - Service Unavailable
							// 504 - Gateway Timeout
							// Transient error - try again in 30 seconds
							auto errorArray = splitLines(exception.msg);
							log.log(errorArray[0], " when attempting to upload a file via a session to OneDrive - retrying applicable request in 30 seconds");
							log.vdebug(thisFunctionName, " previously threw an error - retrying");
							// The server, while acting as a proxy, did not receive a timely response from the upstream server it needed to access in attempting to complete the request. 
							log.vdebug("Thread sleeping for 30 seconds as the server did not receive a timely response from the upstream server it needed to access in attempting to complete the request");
							Thread.sleep(dur!"seconds"(30));
						}
						// re-try original request - retried for 429, 503, 504 - but loop back calling this function 
						log.vdebug("Retrying Function: ", thisFunctionName);
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
		log.vdebug("Modified File Upload Response: ", uploadResponse);
		
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
		
		try {
			// Create a new OneDrive API instance
			OneDriveApi getCurrentDriveQuotaApiInstance;
			getCurrentDriveQuotaApiInstance = new OneDriveApi(appConfig);
			getCurrentDriveQuotaApiInstance.initialise();
			log.vdebug("Seeking available quota for this drive id: ", driveId);
			currentDriveQuota = getCurrentDriveQuotaApiInstance.getDriveQuota(driveId);
			// Shut this API instance down
			getCurrentDriveQuotaApiInstance.shutdown();
			// Free object and memory
			object.destroy(getCurrentDriveQuotaApiInstance);
		} catch (OneDriveException e) {
			log.vdebug("currentDriveQuota = onedrive.getDriveQuota(driveId) generated a OneDriveException");
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
								log.error("ERROR: OneDrive account currently has zero space available. Please free up some space online or purchase additional space.");
								remainingQuota = 0;
								appConfig.quotaAvailable = false;
							} else {
								// zero space available is being reported, maybe being restricted?
								log.error("WARNING: OneDrive quota information is being restricted or providing a zero value. Please fix by speaking to your OneDrive / Office 365 Administrator.");
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
							log.vlog("OneDrive quota information is set at zero, as this is not our drive id, ignoring");
							remainingQuota = 0;
							appConfig.quotaRestricted = true;
						}
					}
				}
			} else {
				// No quota details returned
				if (driveId == appConfig.defaultDriveId) {
					// no quota details returned for current drive id
					log.error("ERROR: OneDrive quota information is missing. Potentially your OneDrive account currently has zero space available. Please free up some space online or purchase additional space.");
					remainingQuota = 0;
					appConfig.quotaRestricted = true;
				} else {
					// quota details not available
					log.vdebug("WARNING: OneDrive quota information is being restricted as this is not our drive id.");
					remainingQuota = 0;
					appConfig.quotaRestricted = true;
				}
			}
		}
		
		// what was the determined available quota?
		log.vdebug("Available quota: ", remainingQuota);
		return remainingQuota;
	}
	
	// Perform a filesystem walk to uncover new data to upload to OneDrive
	void scanLocalFilesystemPathForNewData(string path) {
		
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
		
		// Log the action that we are performing
		if (!appConfig.surpressLoggingOutput) {
			if (!cleanupLocalFiles) {
				log.log("Scanning the local file system '", logPath, "' for new data to upload ...");
			} else {
				log.log("Scanning the local file system '", logPath, "' for data to cleanup ...");
			}
		}
		
		auto startTime = Clock.currTime();
		log.vdebug("Starting Filesystem Walk:     ", startTime);
	
		// Perform the filesystem walk of this path, building an array of new items to upload
		scanPathForNewData(path);
		
		// To finish off the processing items, this is needed to reflect this in the log
		log.vdebug("------------------------------------------------------------------");
		
		auto finishTime = Clock.currTime();
		log.vdebug("Finished Filesystem Walk:     ", finishTime);
		
		auto elapsedTime = finishTime - startTime;
		log.vdebug("Elapsed Time Filesystem Walk: ", elapsedTime);
		
		// Upload new data that has been identified
		// Are there any items to download post fetching the /delta data?
		if (!newLocalFilesToUploadToOneDrive.empty) {
			// There are elements to upload
			log.vlog("New items to upload to OneDrive: ", newLocalFilesToUploadToOneDrive.length);
			
			// How much data do we need to upload? This is important, as, we need to know how much data to determine if all the files can be uploaded
			foreach (uploadFilePath; newLocalFilesToUploadToOneDrive) {
				// validate that the path actually exists so that it can be counted
				if (exists(uploadFilePath)) {
					totalDataToUpload = totalDataToUpload + getSize(uploadFilePath);
				}
			}
			
			// How many bytes to upload
			if (totalDataToUpload < 1024) {
				// Display as Bytes to upload
				log.vlog("Total New Data to Upload:        ", totalDataToUpload, " Bytes");
			} else {
				if ((totalDataToUpload > 1024) && (totalDataToUpload < 1048576)) {
					// Display as KB to upload
					log.vlog("Total New Data to Upload:        ", (totalDataToUpload / 1024), " KB");
				} else {
					// Display as MB to upload
					log.vlog("Total New Data to Upload:        ", (totalDataToUpload / 1024 / 1024), " MB");
				}
			}
			
			// How much space is available (Account Drive ID)
			// The file, could be uploaded to a shared folder, which, we are not tracking how much free space is available there ... 
			log.vdebug("Current Available Space Online (Account Drive ID): ", (appConfig.remainingFreeSpace / 1024 / 1024), " MB");
			
			// Perform the upload
			uploadNewLocalFileItems();
			
			// Cleanup array memory
			newLocalFilesToUploadToOneDrive = [];
		}
	}
	
	// Scan this path for new data
	void scanPathForNewData(string path) {
			
		ulong maxPathLength;
		ulong pathWalkLength;
		
		// Add this logging break to assist with what was checked for each path
		if (path != ".") {
			log.vdebug("------------------------------------------------------------------");
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
			log.log("Skipping item - path has disappeared: ", path);
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
			log.logAndNotify("Skipping item - invalid UTF sequence: ", path);
			log.vdebug("  Error Reason:", e.msg);
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
			
			// This not a Client Side Filtering check, nor a Microsoft Check, but is a sanity check that the path provided is UTF encoded correctly
			// Check the std.encoding of the path against: Unicode 5.0, ASCII, ISO-8859-1, ISO-8859-2, WINDOWS-1250, WINDOWS-1251, WINDOWS-1252
			if (!unwanted) {
				if(!isValid(path)) {
					// Path is not valid according to https://dlang.org/phobos/std_encoding.html
					log.logAndNotify("Skipping item - invalid character encoding sequence: ", path);
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
			// - Microsoft OneDrive restriction and limitations about Windows naming files
			// - Bad whitespace items
			// - HTML ASCII Codes as part of file name
			if (!unwanted) {
				unwanted = checkPathAgainstMicrosoftNamingRestrictions(path);
			}
			
			if (!unwanted) {
				// At this point, this path, we want to scan for new data as it is not excluded
				if (isDir(path)) {
					// Check if this path in the database
					bool directoryFoundInDB = pathFoundInDatabase(path);
					
					// Was the path found in the database?
					if (!directoryFoundInDB) {
						// Path not found in database when searching all drive id's
						if (!cleanupLocalFiles) {
							// --download-only --cleanup-local-files not used
							// Create this directory on OneDrive so that we can upload files to it
							createDirectoryOnline(path);
						} else {
							// we need to clean up this directory
							log.log("Removing local directory as --download-only & --cleanup-local-files configured");
							// Remove any children of this path if they still exist
							// Resolve 'Directory not empty' error when deleting local files
							try {
								foreach (DirEntry child; dirEntries(path, SpanMode.depth, false)) {
									// what sort of child is this?
									if (isDir(child.name)) {
										log.log("Removing local directory: ", child.name);
									} else {
										log.log("Removing local file: ", child.name);
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
								log.log("Removing local directory: ", path);
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
							log.logAndNotify("Skipping item '", path, "' due to this path matching an existing online Business Shared Folder name");
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
						// Path is a valid file, not a pipe
						bool fileFoundInDB = pathFoundInDatabase(path);
						// Was the file found in the database?
						if (!fileFoundInDB) {
							// File not found in database when searching all drive id's
							// Do we upload the file or clean up the file?
							if (!cleanupLocalFiles) {
								// --download-only --cleanup-local-files not used
								// Add this path as a file we need to upload
								log.vdebug("OneDrive Client flagging to upload this file to OneDrive: ", path);
								newLocalFilesToUploadToOneDrive ~= path;
							} else {
								// we need to clean up this file
								log.log("Removing local file as --download-only & --cleanup-local-files configured");
								// are we in a --dry-run scenario?
								log.log("Removing local file: ", path);
								if (!dryRun) {
									// No --dry-run ... process local file delete
									safeRemove(path);
								}
							}
						}	
					} else {
						// path is not a valid file
						log.logAndNotify("Skipping item - item is not a valid file: ", path);
					}
				}
			}
		} else {
			// This path was skipped - why?
			log.logAndNotify("Skipping item '", path, "' due to the full path exceeding ", maxPathLength, " characters (Microsoft OneDrive limitation)");
		}
	}
	
	// Query the database to determine if this path is within the existing database
	bool pathFoundInDatabase(string searchPath) {
		
		// Check if this path in the database
		Item databaseItem;
		bool pathFoundInDB = false;
		foreach (driveId; driveIDsArray) {
			if (itemDB.selectByPath(searchPath, driveId, databaseItem)) {
				pathFoundInDB = true;
			}
		}
		return pathFoundInDB;
	}
	
	// Create a new directory online on OneDrive
	// - Test if we can get the parent path details from the database, otherwise we need to search online
	//   for the path flow and create the folder that way
	void createDirectoryOnline(string thisNewPathToCreate) {
		
		log.log("OneDrive Client requested to create this directory online: ", thisNewPathToCreate);
		
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
			log.vdebug("Attempting to query Local Database for this parent path: ", parentPath);
			
			// Attempt a 2 step process to work out where to create the directory
			// Step 1: Query the DB first
			// Step 2: Query online as last resort
			
			// Step 1: Check if this path in the database
			Item databaseItem;
			bool pathFoundInDB = false;
			foreach (driveId; driveIDsArray) {
				if (itemDB.selectByPath(parentPath, driveId, databaseItem)) {
					pathFoundInDB = true;
					log.vdebug("databaseItem: ", databaseItem);
					log.vdebug("pathFoundInDB: ", pathFoundInDB);
				}
			}
			
			// Step 2: Query for the path online
			if (!pathFoundInDB) {
			
				try {
					log.vdebug("Attempting to query OneDrive Online for this parent path as path not found in local database: ", parentPath);
					onlinePathData = createDirectoryOnlineOneDriveApiInstance.getPathDetails(parentPath);
					// Save item to the database
					saveItem(onlinePathData);
					parentItem = makeItem(onlinePathData);
				} catch (OneDriveException exception) {
					
					if (exception.httpStatusCode == 404) {
						// Parent does not exist ... need to create parent
						log.vdebug("Parent path does not exist online: ", parentPath);
						createDirectoryOnline(parentPath);
					} else {
						
						string thisFunctionName = getFunctionName!({});
						// HTTP request returned status code 408,429,503,504
						if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 429) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
							// Handle the 429
							if (exception.httpStatusCode == 429) {
								// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
								handleOneDriveThrottleRequest(createDirectoryOnlineOneDriveApiInstance);
								log.vdebug("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - attempting to retry ", thisFunctionName);
							}
							// re-try the specific changes queries
							if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
								// 408 - Request Time Out
								// 503 - Service Unavailable
								// 504 - Gateway Timeout
								// Transient error - try again in 30 seconds
								auto errorArray = splitLines(exception.msg);
								log.log(errorArray[0], " when attempting to create a remote directory on OneDrive - retrying applicable request in 30 seconds");
								log.vdebug(thisFunctionName, " previously threw an error - retrying");
								// The server, while acting as a proxy, did not receive a timely response from the upstream server it needed to access in attempting to complete the request. 
								log.vdebug("Thread sleeping for 30 seconds as the server did not receive a timely response from the upstream server it needed to access in attempting to complete the request");
								Thread.sleep(dur!"seconds"(30));
							}
							// re-try original request - retried for 429, 503, 504 - but loop back calling this function 
							log.vdebug("Retrying Function: ", thisFunctionName);
							createDirectoryOnline(thisNewPathToCreate);
						} else {
							// Default operation if not 408,429,503,504 errors
							// display what the error is
							displayOneDriveErrorMessage(exception.msg, thisFunctionName);
						}
					}
				}
			
			} else {
				// parent path found in database ... use those details ...
				parentItem = databaseItem;
			}
			
		}
		
		// Make sure the full path does not exist online, this should generate a 404 response, to which then the folder will be created online
		try {
			// Try and query the OneDrive API for the path we need to create
			log.vdebug("Attempting to query OneDrive for this path: ", thisNewPathToCreate);
			
			if (parentItem.driveId == appConfig.defaultDriveId) {
				// Use getPathDetailsByDriveId
				onlinePathData = createDirectoryOnlineOneDriveApiInstance.getPathDetailsByDriveId(parentItem.driveId, thisNewPathToCreate);
			} else {
				// If the parentItem.driveId is not our driveId - the path we are looking for will not be at the logical location that getPathDetailsByDriveId 
				// can use - as it will always return a 404 .. even if the path actually exists (which is the whole point of this test)
				// Search the parentItem.driveId for any folder name match that we are going to create, then compare response JSON items with parentItem.id
				// If no match, the folder we want to create does not exist at the location we are seeking to create it at, thus generate a 404
				onlinePathData = createDirectoryOnlineOneDriveApiInstance.searchDriveForPath(parentItem.driveId, baseName(thisNewPathToCreate));
				
				// Process the response from searching the drive
				ulong responseCount = count(onlinePathData["value"].array);
				if (responseCount > 0) {
					// Search 'name' matches were found .. need to match these against parentItem.id
					bool foundDirectoryOnline = false;
					JSONValue foundDirectoryJSONItem;
					// Items were returned .. but is one of these what we are looking for?
					foreach (childJSON; onlinePathData["value"].array) {
						// Is this item not a file?
						if (!isFileItem(childJSON)) {
							Item thisChildItem = makeItem(childJSON);
							// Direct Match Check
							if ((parentItem.id == thisChildItem.parentId) && (baseName(thisNewPathToCreate) == thisChildItem.name)) {
								// High confidence that this child folder is a direct match we are trying to create and it already exists online
								log.vdebug("Path we are searching for exists online: ", baseName(thisNewPathToCreate));
								log.vdebug("childJSON: ", childJSON);
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
								foundDirectoryOnline = true;
								foundDirectoryJSONItem = childJSON;
								break;
							}
						}
					}
					
					if (foundDirectoryOnline) {
						// Directory we are seeking was found online ... 
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
				log.vlog("The requested directory to create was not found on OneDrive - creating remote directory: ", thisNewPathToCreate);
				
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
						// Attempt to create a new folder on the configured parent driveId & parent id
						createDirectoryOnlineAPIResponse = createDirectoryOnlineOneDriveApiInstance.createById(parentItem.driveId, parentItem.id, newDriveItem);
						// Is the response a valid JSON object - validation checking done in saveItem
						saveItem(createDirectoryOnlineAPIResponse);
						// Log that the directory was created
						log.log("Successfully created the remote directory ", thisNewPathToCreate, " on OneDrive");
					} catch (OneDriveException exception) {
						if (exception.httpStatusCode == 409) {
							// OneDrive API returned a 404 (above) to say the directory did not exist
							// but when we attempted to create it, OneDrive responded that it now already exists
							log.vlog("OneDrive reported that ", thisNewPathToCreate, " already exists .. OneDrive API race condition");
							return;
						} else {
							// some other error from OneDrive was returned - display what it is
							log.error("OneDrive generated an error when creating this path: ", thisNewPathToCreate);
							displayOneDriveErrorMessage(exception.msg, getFunctionName!({}));
							return;
						}
					}
				} else {
					// Simulate a successful 'directory create' & save it to the dryRun database copy
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
						log.vdebug("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - attempting to retry ", thisFunctionName);
					}
					// re-try the specific changes queries
					if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
						// 408 - Request Time Out
						// 503 - Service Unavailable
						// 504 - Gateway Timeout
						// Transient error - try again in 30 seconds
						auto errorArray = splitLines(exception.msg);
						log.log(errorArray[0], " when attempting to create a remote directory on OneDrive - retrying applicable request in 30 seconds");
						log.vdebug(thisFunctionName, " previously threw an error - retrying");
						// The server, while acting as a proxy, did not receive a timely response from the upstream server it needed to access in attempting to complete the request. 
						log.vdebug("Thread sleeping for 30 seconds as the server did not receive a timely response from the upstream server it needed to access in attempting to complete the request");
						Thread.sleep(dur!"seconds"(30));
					}
					// re-try original request - retried for 429, 503, 504 - but loop back calling this function 
					log.vdebug("Retrying Function: ", thisFunctionName);
					createDirectoryOnline(thisNewPathToCreate);
				} else {
					// Re-Try
					createDirectoryOnline(thisNewPathToCreate);
				}
			}
		}
		
		// If we get to this point - onlinePathData = createDirectoryOnlineOneDriveApiInstance.getPathDetailsByDriveId(parentItem.driveId, thisNewPathToCreate) generated a 'valid' response ....
		// This means that the folder potentially exists online .. which is odd .. as it should not have existed
		if (onlinePathData.type() == JSONType.object){
			// A valid object was responded with
			if (onlinePathData["name"].str == baseName(thisNewPathToCreate)) {
				// OneDrive 'name' matches local path name
				if (appConfig.accountType == "business") {
					// We are a business account, this existing online folder, could be a Shared Online Folder and is the 'Add shortcut to My files' item
					log.vdebug("onlinePathData: ", onlinePathData);
					if (isItemRemote(onlinePathData)) {
						// The folder is a remote item ... we do not want to create this ...
						log.vdebug("Remote Existing Online Folder is most likely a OneDrive Shared Business Folder Link added by 'Add shortcut to My files'");
						log.vdebug("We need to skip this path: ", thisNewPathToCreate);
						// Add this path to businessSharedFoldersOnlineToSkip
						businessSharedFoldersOnlineToSkip ~= [thisNewPathToCreate];
						// no save to database, no online create
						return;
					}
				}
				
				log.vlog("The requested directory to create was found on OneDrive - skipping creating the directory: ", thisNewPathToCreate);
				// Is the response a valid JSON object - validation checking done in saveItem
				saveItem(onlinePathData);
				return;
			} else {
				// Normally this would throw an error, however we cant use throw new posixException()
				string msg = format("POSIX 'case-insensitive match' between '%s' (local) and '%s' (online) which violates the Microsoft OneDrive API namespace convention", baseName(thisNewPathToCreate), onlinePathData["name"].str);
				displayPosixErrorMessage(msg);
				log.error("ERROR: Requested directory to create has a 'case-insensitive match' to an existing directory on OneDrive online.");
				log.error("ERROR: To resolve, rename this local directory: ", buildNormalizedPath(absolutePath(thisNewPathToCreate)));
				log.log("Skipping creating this directory online due to 'case-insensitive match': ", thisNewPathToCreate);
				// Add this path to posixViolationPaths
				posixViolationPaths ~= [thisNewPathToCreate];
				return;
			}
		} else {
			// response is not valid JSON, an error was returned from OneDrive
			log.error("ERROR: There was an error performing this operation on OneDrive");
			log.error("ERROR: Increase logging verbosity to assist determining why.");
			log.log("Skipping: ", buildNormalizedPath(absolutePath(thisNewPathToCreate)));
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
		ulong batchSize = appConfig.concurrentThreads;
		ulong batchCount = (newLocalFilesToUploadToOneDrive.length + batchSize - 1) / batchSize;
		ulong batchesProcessed = 0;
		
		foreach (chunk; newLocalFilesToUploadToOneDrive.chunks(batchSize)) {
			uploadNewLocalFileItemsInParallel(chunk);
		}
	}
	
	// Upload the file batches in parallel
	void uploadNewLocalFileItemsInParallel(string[] array) {
		
		foreach (i, fileToUpload; taskPool.parallel(array)) {
			log.vdebug("Upload Thread ", i, " Starting: ", Clock.currTime());
			uploadNewFile(fileToUpload);
			log.vdebug("Upload Thread ", i, " Finished: ", Clock.currTime());
		}
	}
	
	// Upload a new file to OneDrive
	void uploadNewFile(string fileToUpload) {
			
		// Debug for the moment
		log.vdebug("fileToUpload: ", fileToUpload);
		
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
			log.log("parentItem.driveId is empty - using defaultDriveId for upload API calls");
			parentItem.driveId = appConfig.defaultDriveId;
		}
		
		// Can we read the file - as a permissions issue or actual file corruption will cause a failure
		// Resolves: https://github.com/abraunegg/onedrive/issues/113
		if (readLocalFile(fileToUpload)) {
			if (parentPathFoundInDB) {
				// The local file can be read - so we can read it to attemtp to upload it in this thread
				// Get the file size
				thisFileSize = getSize(fileToUpload);
				// Does this file exceed the maximum filesize for OneDrive
				// Resolves: https://github.com/skilion/onedrive/issues/121 , https://github.com/skilion/onedrive/issues/294 , https://github.com/skilion/onedrive/issues/329
				if (thisFileSize <= maxUploadFileSize) {
					// Is there enough free space on OneDrive when we started this thread, to upload the file to OneDrive?
					remainingFreeSpaceOnline = getRemainingFreeSpace(parentItem.driveId);
					log.vdebug("Current Available Space Online (Upload Target Drive ID): ", (remainingFreeSpaceOnline / 1024 / 1024), " MB");
					
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
								log.vlog("WARNING: Shared Folder OneDrive quota information is being restricted or providing a zero value. Space available online cannot be guaranteed.");
							} else {
								log.vlog("WARNING: Shared Folder OneDrive quota information is being restricted or providing a zero value. Please fix by speaking to your OneDrive / Office 365 Administrator.");
							}
						} else {
							if (appConfig.accountType == "personal") {
								log.vlog("WARNING: OneDrive quota information is being restricted or providing a zero value. Space available online cannot be guaranteed.");
							} else {
								log.vlog("WARNING: OneDrive quota information is being restricted or providing a zero value. Please fix by speaking to your OneDrive / Office 365 Administrator.");
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
							performPosixTest(baseName(fileToUpload), fileDetailsFromOneDrive["name"].str);
							
							// No 404 or otherwise was triggered, meaning that the file already exists online and passes the POSIX test ...
							log.vdebug("fileDetailsFromOneDrive after exist online check: ", fileDetailsFromOneDrive);
							// Does the data from online match our local file?
							if (performUploadIntegrityValidationChecks(fileDetailsFromOneDrive, fileToUpload, thisFileSize)) {
								// Save item to the database
								saveItem(fileDetailsFromOneDrive);
							}
						} catch (OneDriveException exception) {
							// If we get a 404 .. the file is not online .. this is what we want .. file does not exist online
							if (exception.httpStatusCode == 404) {
								// The file has been checked, client side filtering checked, does not exist online - we need to upload it
								log.vdebug("fileDetailsFromOneDrive = checkFileOneDriveApiInstance.getPathDetailsByDriveId(parentItem.driveId, fileToUpload); generated a 404 - file does not exist online - must upload it");
								uploadFailed = performNewFileUpload(parentItem, fileToUpload, thisFileSize);
							} else {
								
								string thisFunctionName = getFunctionName!({});
								// HTTP request returned status code 408,429,503,504
								if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 429) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
									// Handle the 429
									if (exception.httpStatusCode == 429) {
										// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
										handleOneDriveThrottleRequest(checkFileOneDriveApiInstance);
										log.vdebug("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - attempting to retry ", thisFunctionName);
									}
									// re-try the specific changes queries
									if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
										// 408 - Request Time Out
										// 503 - Service Unavailable
										// 504 - Gateway Timeout
										// Transient error - try again in 30 seconds
										auto errorArray = splitLines(exception.msg);
										log.log(errorArray[0], " when attempting to validate file details on OneDrive - retrying applicable request in 30 seconds");
										log.vdebug(thisFunctionName, " previously threw an error - retrying");
										// The server, while acting as a proxy, did not receive a timely response from the upstream server it needed to access in attempting to complete the request. 
										log.vdebug("Thread sleeping for 30 seconds as the server did not receive a timely response from the upstream server it needed to access in attempting to complete the request");
										Thread.sleep(dur!"seconds"(30));
									}
									// re-try original request - retried for 429, 503, 504 - but loop back calling this function 
									log.vdebug("Retrying Function: ", thisFunctionName);
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
						}
						
						// Operations in this thread are done / complete - either upload was done or it failed
						checkFileOneDriveApiInstance.shutdown();
						// Free object and memory
						object.destroy(checkFileOneDriveApiInstance);
					} else {
						// skip file upload - insufficent space to upload
						log.log("Skipping uploading this new file as it exceeds the available free space on OneDrive: ", fileToUpload);
						uploadFailed = true;
					}
				} else {
					// Skip file upload - too large
					log.log("Skipping uploading this new file as it exceeds the maximum size allowed by OneDrive: ", fileToUpload);
					uploadFailed = true;
				}
			} else {
				// why was the parent path not in the database?
				if (canFind(posixViolationPaths, parentPath)) {
					log.error("ERROR: POSIX 'case-insensitive match' for the parent path which violates the Microsoft OneDrive API namespace convention.");
				} else {
					log.error("ERROR: Parent path is not in the database or online.");
				}
				log.error("ERROR: Unable to upload this file: ", fileToUpload);
				uploadFailed = true;
			}
		} else {
			// Unable to read local file
			log.log("Skipping uploading this file as it cannot be read (file permissions or file corruption): ", fileToUpload);
			uploadFailed = true;
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
					log.log("Uploading new file ", fileToUpload, " ... done.");
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
							log.vdebug("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - attempting to retry ", thisFunctionName);
						}
						// re-try the specific changes queries
						if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
							// 408 - Request Time Out
							// 503 - Service Unavailable
							// 504 - Gateway Timeout
							// Transient error - try again in 30 seconds
							auto errorArray = splitLines(exception.msg);
							log.log(errorArray[0], " when attempting to upload a new file to OneDrive - retrying applicable request in 30 seconds");
							log.vdebug(thisFunctionName, " previously threw an error - retrying");
							// The server, while acting as a proxy, did not receive a timely response from the upstream server it needed to access in attempting to complete the request. 
							log.vdebug("Thread sleeping for 30 seconds as the server did not receive a timely response from the upstream server it needed to access in attempting to complete the request");
							Thread.sleep(dur!"seconds"(30));
						}
						// re-try original request - retried for 429, 503, 504 - but loop back calling this function 
						performNewFileUpload(parentItem, fileToUpload, thisFileSize);
						// Return upload status
						return uploadFailed;
					} else {
						// Default operation if not 408,429,503,504 errors
						// display what the error is
						log.log("Uploading new file ", fileToUpload, " ... failed.");
						displayOneDriveErrorMessage(exception.msg, thisFunctionName);
					}
					
				} catch (FileException e) {
					// display the error message
					log.log("Uploading new file ", fileToUpload, " ... failed.");
					displayFileSystemErrorMessage(e.msg, getFunctionName!({}));
				}
			} else {
				// Session Upload for this criteria:
				// - Personal Account and file size > 4MB
				// - All Business | Office365 | SharePoint files > 0 bytes
				JSONValue uploadSessionData;
				// As this is a unique thread, the sessionFilePath for where we save the data needs to be unique
				// The best way to do this is calculate the CRC32 of the file, and use this as the suffix of the session file we save
				string threadUploadSessionFilePath = appConfig.uploadSessionFilePath ~ "." ~ computeCRC32(fileToUpload);
				
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
							log.vdebug("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - attempting to retry ", thisFunctionName);
						}
						// re-try the specific changes queries
						if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
							// 408 - Request Time Out
							// 503 - Service Unavailable
							// 504 - Gateway Timeout
							// Transient error - try again in 30 seconds
							auto errorArray = splitLines(exception.msg);
							log.log(errorArray[0], " when attempting to create an upload session on OneDrive - retrying applicable request in 30 seconds");
							log.vdebug(thisFunctionName, " previously threw an error - retrying");
							// The server, while acting as a proxy, did not receive a timely response from the upstream server it needed to access in attempting to complete the request. 
							log.vdebug("Thread sleeping for 30 seconds as the server did not receive a timely response from the upstream server it needed to access in attempting to complete the request");
							Thread.sleep(dur!"seconds"(30));
						}
						// re-try original request - retried for 429, 503, 504 - but loop back calling this function 
						log.vdebug("Retrying Function: ", thisFunctionName);
						performNewFileUpload(parentItem, fileToUpload, thisFileSize);
					} else {
						// Default operation if not 408,429,503,504 errors
						// display what the error is
						log.log("Uploading new file ", fileToUpload, " ... failed.");
						displayOneDriveErrorMessage(exception.msg, thisFunctionName);
					}
					
				} catch (FileException e) {
					// display the error message
					log.log("Uploading new file ", fileToUpload, " ... failed.");
					displayFileSystemErrorMessage(e.msg, getFunctionName!({}));
				}
				
				// Do we have a valid session URL that we can use ?
				if (uploadSessionData.type() == JSONType.object) {
					// This is a valid JSON object
					bool sessionDataValid = true;
					
					// Validate that we have the following items which we need
					if (!hasUploadURL(uploadSessionData)) {
						sessionDataValid = false;
						log.vdebug("Session data missing 'uploadUrl'");
					}
					
					if (!hasNextExpectedRanges(uploadSessionData)) {
						sessionDataValid = false;
						log.vdebug("Session data missing 'nextExpectedRanges'");
					}
					
					if (!hasLocalPath(uploadSessionData)) {
						sessionDataValid = false;
						log.vdebug("Session data missing 'localPath'");
					}
								
					if (sessionDataValid) {
						// We have a valid Upload Session Data we can use
						
						try {
							// Try and perform the upload session
							uploadResponse = performSessionFileUpload(uploadFileOneDriveApiInstance, thisFileSize, uploadSessionData, threadUploadSessionFilePath);
							
							if (uploadResponse.type() == JSONType.object) {
								uploadFailed = false;
								log.log("Uploading new file ", fileToUpload, " ... done.");
							} else {
								log.log("Uploading new file ", fileToUpload, " ... failed.");
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
									log.vdebug("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - attempting to retry ", thisFunctionName);
								}
								// re-try the specific changes queries
								if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
									// 408 - Request Time Out
									// 503 - Service Unavailable
									// 504 - Gateway Timeout
									// Transient error - try again in 30 seconds
									auto errorArray = splitLines(exception.msg);
									log.log(errorArray[0], " when attempting to upload a new file via a session to OneDrive - retrying applicable request in 30 seconds");
									log.vdebug(thisFunctionName, " previously threw an error - retrying");
									// The server, while acting as a proxy, did not receive a timely response from the upstream server it needed to access in attempting to complete the request. 
									log.vdebug("Thread sleeping for 30 seconds as the server did not receive a timely response from the upstream server it needed to access in attempting to complete the request");
									Thread.sleep(dur!"seconds"(30));
								}
								// re-try original request - retried for 429, 503, 504 - but loop back calling this function 
								log.vdebug("Retrying Function: ", thisFunctionName);
								performNewFileUpload(parentItem, fileToUpload, thisFileSize);
							} else {
								// Default operation if not 408,429,503,504 errors
								// display what the error is
								log.log("Uploading new file ", fileToUpload, " ... failed.");
								displayOneDriveErrorMessage(exception.msg, thisFunctionName);
							}
						
						}
					} else {
						// No Upload URL or nextExpectedRanges or localPath .. not a valid JSON we can use
						log.vlog("Session data is missing required elements to perform a session upload.");
						log.log("Uploading new file ", fileToUpload, " ... failed.");
					}
				} else {
					// Create session Upload URL failed
					log.log("Uploading new file ", fileToUpload, " ... failed.");
				}
			}
		} else {
			// We are in a --dry-run scenario
			uploadResponse = createFakeResponse(fileToUpload);
			uploadFailed = false;
			log.logAndNotify("Uploading new file ", fileToUpload, " ... done.");
		}
		
		// Upload has finished
		auto uploadFinishTime = Clock.currTime();
		// If no upload failure, calculate metrics, perform integrity validation
		if (!uploadFailed) {
			// Upload did not fail ...
			auto uploadDuration = uploadFinishTime - uploadStartTime;
			log.vdebug("File Size: ", thisFileSize, " Bytes");
			log.vdebug("Upload Duration: ", (uploadDuration.total!"msecs"/1e3), " Seconds");
			auto uploadSpeed = (thisFileSize / (uploadDuration.total!"msecs"/1e3)/ 1024 / 1024);
			log.vdebug("Upload Speed: ", uploadSpeed, " Mbps (approx)");
		
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
					log.log("File disappeared locally after upload: ", fileToUpload);
				}
			} else {
				// Log that an invalid JSON object was returned
				log.vdebug("uploadFileOneDriveApiInstance.simpleUpload or session.upload call returned an invalid JSON Object from the OneDrive API");
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
			log.vlog("Creation of OneDrive API Upload Session failed.");
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
		size_t iteration = (roundTo!int(double(thisFileSize)/double(fragmentSize)))+1;
		Progress p = new Progress(iteration);
		p.title = "Uploading";
		
		// Initialise the download bar at 0%
		p.next();
		
		// Start the session upload using the active API instance for this thread
		while (true) {
			fragmentCount++;
			log.vdebugNewLine("Fragment: ", fragmentCount, " of ", iteration);
			p.next();
			log.vdebugNewLine("fragmentSize: ", fragmentSize, "offset: ", offset, " thisFileSize: ", thisFileSize );
			fragSize = fragmentSize < thisFileSize - offset ? fragmentSize : thisFileSize - offset;
			log.vdebugNewLine("Using fragSize: ", fragSize);
			
			// fragSize must not be a negative value
			if (fragSize < 0) {
				// Session upload will fail
				// not a JSON object - fragment upload failed
				log.vlog("File upload session failed - invalid calculation of fragment size");
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
					log.vdebug("Fragment upload failed - received throttle request uploadResponse from OneDrive");
					if (exception.httpStatusCode == 429) {
						auto retryAfterValue = activeOneDriveApiInstance.getRetryAfterValue();
						log.vdebug("Using Retry-After Value = ", retryAfterValue);
						// Sleep thread as per request
						log.log("\nThread sleeping due to 'HTTP request returned status code 429' - The request has been throttled");
						log.log("Sleeping for ", retryAfterValue, " seconds");
						Thread.sleep(dur!"seconds"(retryAfterValue));
						log.log("Retrying fragment upload");
					} else {
						// Handle 408, 503 and 504
						auto errorArray = splitLines(exception.msg);
						auto retryAfterValue = 30;
						log.log("\nThread sleeping due to '", errorArray[0], "' - retrying applicable request in 30 seconds");
						log.log("Sleeping for ", retryAfterValue, " seconds");
						Thread.sleep(dur!"seconds"(retryAfterValue));
						log.log("Retrying fragment upload");
					}
				} else {
					// insert a new line as well, so that the below error is inserted on the console in the right location
					log.vlog("\nFragment upload failed - received an exception response from OneDrive API");
					// display what the error is
					displayOneDriveErrorMessage(exception.msg, getFunctionName!({}));
					// retry fragment upload in case error is transient
					log.vlog("Retrying fragment upload");
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
					log.vlog("Retry to upload fragment failed");
					// display what the error is
					displayOneDriveErrorMessage(e.msg, getFunctionName!({}));
					// set uploadResponse to null as the fragment upload was in error twice
					uploadResponse = null;
				} catch (std.exception.ErrnoException e) {
					// There was a file system error - display the error message
					displayFileSystemErrorMessage(e.msg, getFunctionName!({}));
					return uploadResponse;
				}
			}
			
			// was the fragment uploaded without issue?
			if (uploadResponse.type() == JSONType.object){
				offset += fragmentSize;
				if (offset >= thisFileSize) break;
				// update the uploadSessionData details
				uploadSessionData["expirationDateTime"] = uploadResponse["expirationDateTime"];
				uploadSessionData["nextExpectedRanges"] = uploadResponse["nextExpectedRanges"];
				saveSessionFile(threadUploadSessionFilePath, uploadSessionData);
			} else {
				// not a JSON object - fragment upload failed
				log.vlog("File upload session failed - invalid response from OneDrive API");
				if (exists(threadUploadSessionFilePath)) {
					remove(threadUploadSessionFilePath);
				}
				// set uploadResponse to null as error
				uploadResponse = null;
				return uploadResponse;
			}
		}
		
		// upload complete
		p.next();
		writeln();
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
				log.vlog("Skipping remote directory delete as --upload-only & --no-remote-delete configured");
			} else {
				// Do not process remote file delete
				log.vlog("Skipping remote file delete as --upload-only & --no-remote-delete configured");
			}
		} else {
			// Process the delete - delete the object online
			log.log("Deleting item from OneDrive: ", path);
			bool flagAsBigDelete = false;
			
			Item[] children;
			ulong itemsToDelete;
		
			if ((itemToDelete.type == ItemType.dir)) {
				// Query the database - how many objects will this remove?
				children = getChildren(itemToDelete.driveId, itemToDelete.id);
				// Count the returned items + the original item (1)
				itemsToDelete = count(children) + 1;
				log.vdebug("Number of items online to delete: ", itemsToDelete);
			} else {
				itemsToDelete = 1;
			}
			
			// A local delete of a file|folder when using --monitor  will issue a inotify event, which will trigger the local & remote data immediately be deleted
			// The user may also be --sync process, so we are checking if something was deleted between application use
			if (itemsToDelete >= appConfig.getValueLong("classify_as_big_delete")) {
				// A big delete has been detected
				flagAsBigDelete = true;
				if (!appConfig.getValueBool("force")) {
					log.error("ERROR: An attempt to remove a large volume of data from OneDrive has been detected. Exiting client to preserve data on OneDrive");
					log.error("ERROR: To delete a large volume of data use --force or increase the config value 'classify_as_big_delete' to a larger value");
					// Must exit here to preserve data on online 
					exit(-1);
				}
			}
			
			// Are we in a --dry-run scenario?
			if (!dryRun) {
				// We are not in a dry run scenario
				log.vdebug("itemToDelete: ", itemToDelete);
				
				// Create new OneDrive API Instance
				OneDriveApi uploadDeletedItemOneDriveApiInstance;
				uploadDeletedItemOneDriveApiInstance = new OneDriveApi(appConfig);
				uploadDeletedItemOneDriveApiInstance.initialise();
			
				// what item are we trying to delete?
				log.vdebug("Attempting to delete this single item id: ", itemToDelete.id, " from drive: ", itemToDelete.driveId);
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
						log.vlog("OneDrive reported: The resource could not be found to be deleted.");
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
				log.log("dry run - no delete activity");
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
		log.vdebug("Attempting a reverse delete of all child objects from OneDrive");
		
		// Create a new API Instance for this thread and initialise it
		OneDriveApi performReverseDeletionOneDriveApiInstance;
		performReverseDeletionOneDriveApiInstance = new OneDriveApi(appConfig);
		performReverseDeletionOneDriveApiInstance.initialise();
		
		foreach_reverse (Item child; children) {
			// Log the action
			log.vdebug("Attempting to delete this child item id: ", child.id, " from drive: ", child.driveId);
			// perform the delete via the default OneDrive API instance
			performReverseDeletionOneDriveApiInstance.deleteById(child.driveId, child.id, child.eTag);
			// delete the child reference in the local database
			itemDB.deleteById(child.driveId, child.id);
		}
		// Log the action
		log.vdebug("Attempting to delete this parent item id: ", itemToDelete.id, " from drive: ", itemToDelete.driveId);
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
				log.vdebug("FakeResponse: searching database for: ", searchDriveId, " ", parentPath);
				if (itemDB.selectByPath(parentPath, searchDriveId, databaseItem)) {
					log.vdebug("FakeResponse: Found Database Item: ", databaseItem);
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
						
		log.vdebug("Generated Fake OneDrive Response: ", fakeResponse);
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
					log.vdebug("Skipping adding to database as --upload-only & --remove-source-files configured");
				} else {
					// What is the JSON item we are trying to create a DB record with?
					log.vdebug("saveItem - creating DB item from this JSON: ", jsonItem);
					// Takes a JSON input and formats to an item which can be used by the database
					Item item = makeItem(jsonItem);
					
					// Is this JSON item a 'root' item?
					if ((isItemRoot(jsonItem)) && (item.name == "root")) {
						log.vdebug("Updating DB Item object with correct values as this is a 'root' object");
						item.parentId = null; 	// ensures that this database entry has no parent
						// Check for parentReference
						if (hasParentReference(jsonItem)) {
							// Set the correct item.driveId
							log.vdebug("ROOT JSON Item HAS parentReference .... setting item.driveId = jsonItem['parentReference']['driveId'].str");
							item.driveId = jsonItem["parentReference"]["driveId"].str;
						}
						
						// We only should be adding our account 'root' to the database, not shared folder 'root' items
						if (item.driveId != appConfig.defaultDriveId) {
							// Shared Folder drive 'root' object .. we dont want this item
							log.vdebug("NOT adding 'remote root' object to database: ", item);
							return;
						}
					}
					
					// Add to the local database
					log.vdebug("Adding to database: ", item);
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
				log.error("ERROR: OneDrive response missing required 'id' element");
				log.error("ERROR: ", jsonItem);
			}
		} else {
			// log error
			log.error("ERROR: An error was returned from OneDrive and the resulting response is not a valid JSON object");
			log.error("ERROR: Increase logging verbosity to assist determining why.");
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
								log.vdebug("This item is potentially an associated Microsoft OneNote Object Item");
							} else {
								// Not a Microsoft OneNote Mime Type Object ..
								string apiWarningMessage = "WARNING: OneDrive API inconsistency - this file does not have any hash: ";
								// This is computationally expensive .. but we are only doing this if there are no hashses provided
								bool parentInDatabase = itemDB.idInLocalDatabase(newDatabaseItem.driveId, newDatabaseItem.parentId);
								// Is the parent id in the database?
								if (parentInDatabase) {
									// This is again computationally expensive .. calculate this item path to advise the user the actual path of this item that has no hash
									string newItemPath = computeItemPath(newDatabaseItem.driveId, newDatabaseItem.parentId) ~ "/" ~ newDatabaseItem.name;
									log.log(apiWarningMessage, newItemPath);
								} else {
									// Parent is not in the database .. why?
									// Check if the parent item had been skipped .. 
									if (skippedItems.find(newDatabaseItem.parentId).length != 0) {
										log.vdebug(apiWarningMessage, "newDatabaseItem.parentId listed within skippedItems");
									} else {
										// Use the item ID .. there is no other reference available, parent is not being skipped, so we should have been able to calculate this - but we could not
										log.log(apiWarningMessage, newDatabaseItem.id);
									}
								}
							}
						}	
					}
				} else {
					// zero file size
					log.vdebug("This item file is zero size - potentially no hash provided by the OneDrive API");
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
			log.log("\nFailed items to download from OneDrive: ", fileDownloadFailures.length);
			foreach(failedFileToDownload; fileDownloadFailures) {
				// List the detail of the item that failed to download
				log.logAndNotify("Failed to download: ", failedFileToDownload);
				
				// Is this failed item in the DB? It should not be ..
				Item downloadDBItem;
				// Need to check all driveid's we know about, not just the defaultDriveId
				foreach (searchDriveId; driveIDsArray) {
					if (itemDB.selectByPath(failedFileToDownload, searchDriveId, downloadDBItem)) {
						// item was found in the DB
						log.error("ERROR: Failed Download Path found in database, must delete this item from the database .. it should not be in there if it failed to download");
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
			log.log("\nFailed items to upload to OneDrive: ", fileUploadFailures.length);
			foreach(failedFileToUpload; fileUploadFailures) {
				// List the path of the item that failed to upload
				log.logAndNotify("Failed to upload: ", failedFileToUpload);
				
				// Is this failed item in the DB? It should not be ..
				Item uploadDBItem;
				// Need to check all driveid's we know about, not just the defaultDriveId
				foreach (searchDriveId; driveIDsArray) {
					if (itemDB.selectByPath(failedFileToUpload, searchDriveId, uploadDBItem)) {
						// item was found in the DB
						log.error("ERROR: Failed Upload Path found in database, must delete this item from the database .. it should not be in there if it failed to upload");
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
				exit(-1);
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
		log.vdebug("Downgrading all children for this searchItem.driveId (" ~ searchItem.driveId ~ ") and searchItem.id (" ~ searchItem.id ~ ") to an out-of-sync state");
		auto drivePathChildren = getChildren(searchItem.driveId, searchItem.id);
		if (count(drivePathChildren) > 0) {
			// Children to process and flag as out-of-sync	
			foreach (drivePathChild; drivePathChildren) {
				// Flag any object in the database as out-of-sync for this driveId & and object id
				log.vdebug("Downgrading item as out-of-sync: ", drivePathChild.id);
				itemDB.downgradeSyncStatusFlag(drivePathChild.driveId, drivePathChild.id);
			}
		}
		
		// Get drive details for the provided driveId
		try {
			driveData = generateDeltaResponseOneDriveApiInstance.getPathDetailsById(searchItem.driveId, searchItem.id);
		} catch (OneDriveException exception) {
			log.vdebug("driveData = generateDeltaResponseOneDriveApiInstance.getPathDetailsById(searchItem.driveId, searchItem.id) generated a OneDriveException");
			
			string thisFunctionName = getFunctionName!({});
			// HTTP request returned status code 408,429,503,504
			if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 429) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
				// Handle the 429
				if (exception.httpStatusCode == 429) {
					// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
					handleOneDriveThrottleRequest(generateDeltaResponseOneDriveApiInstance);
					log.vdebug("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - attempting to retry ", thisFunctionName);
				}
				// re-try the specific changes queries
				if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
					// 408 - Request Time Out
					// 503 - Service Unavailable
					// 504 - Gateway Timeout
					// Transient error - try again in 30 seconds
					auto errorArray = splitLines(exception.msg);
					log.log(errorArray[0], " when attempting to query path details on OneDrive - retrying applicable request in 30 seconds");
					log.vdebug(thisFunctionName, " previously threw an error - retrying");
					// The server, while acting as a proxy, did not receive a timely response from the upstream server it needed to access in attempting to complete the request. 
					log.vdebug("Thread sleeping for 30 seconds as the server did not receive a timely response from the upstream server it needed to access in attempting to complete the request");
					Thread.sleep(dur!"seconds"(30));
				}
				// re-try original request - retried for 429, 503, 504 - but loop back calling this function 
				log.vdebug("Retrying Function: ", thisFunctionName);
				generateDeltaResponse(pathToQuery);
			} else {
				// Default operation if not 408,429,503,504 errors
				// display what the error is
				displayOneDriveErrorMessage(exception.msg, thisFunctionName);
			}
		}
		
		// Was a valid JSON response for 'driveData' provided?
		if (driveData.type() == JSONType.object) {
		
			// Process this initial JSON response
			if (!isItemRoot(driveData)) {
				// Get root details for the provided driveId
				try {
					rootData = generateDeltaResponseOneDriveApiInstance.getDriveIdRoot(searchItem.driveId);
				} catch (OneDriveException exception) {
					log.vdebug("rootData = onedrive.getDriveIdRoot(searchItem.driveId) generated a OneDriveException");
					
					string thisFunctionName = getFunctionName!({});
					// HTTP request returned status code 408,429,503,504
					if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 429) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
						// Handle the 429
						if (exception.httpStatusCode == 429) {
							// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
							handleOneDriveThrottleRequest(generateDeltaResponseOneDriveApiInstance);
							log.vdebug("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - attempting to retry ", thisFunctionName);
						}
						// re-try the specific changes queries
						if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
							// 408 - Request Time Out
							// 503 - Service Unavailable
							// 504 - Gateway Timeout
							// Transient error - try again in 30 seconds
							auto errorArray = splitLines(exception.msg);
							log.log(errorArray[0], " when attempting to query drive root details on OneDrive - retrying applicable request in 30 seconds");
							log.vdebug(thisFunctionName, " previously threw an error - retrying");
							// The server, while acting as a proxy, did not receive a timely response from the upstream server it needed to access in attempting to complete the request. 
							log.vdebug("Thread sleeping for 30 seconds as the server did not receive a timely response from the upstream server it needed to access in attempting to complete the request");
							Thread.sleep(dur!"seconds"(30));
						}
						// re-try original request - retried for 429, 503, 504 - but loop back calling this function 
						log.log("Retrying Query: rootData = generateDeltaResponseOneDriveApiInstance.getDriveIdRoot(searchItem.driveId)");
						rootData = generateDeltaResponseOneDriveApiInstance.getDriveIdRoot(searchItem.driveId);
						
						
					} else {
						// Default operation if not 408,429,503,504 errors
						// display what the error is
						displayOneDriveErrorMessage(exception.msg, thisFunctionName);
					}
					
				}
				// Add driveData JSON data to array
				log.vlog("Adding OneDrive root details for processing");
				childrenData ~= rootData;
			}
			
			// Add driveData JSON data to array
			log.vlog("Adding OneDrive folder details for processing");
			childrenData ~= driveData;
			
		} else {
			// driveData is an invalid JSON object
			writeln("CODING TO DO: The query of OneDrive API to getPathDetailsById generated an invalid JSON response - thus we cant build our own /delta simulated response ... how to handle?");
			// Must exit here
			generateDeltaResponseOneDriveApiInstance.shutdown();
			// Free object and memory
			object.destroy(generateDeltaResponseOneDriveApiInstance);
			exit(-1);
		}
		
		// For each child object, query the OneDrive API
		for (;;) {
			// query top level children
			try {
				topLevelChildren = generateDeltaResponseOneDriveApiInstance.listChildren(searchItem.driveId, searchItem.id, nextLink);
			} catch (OneDriveException exception) {
				// OneDrive threw an error
				log.vdebug("------------------------------------------------------------------");
				log.vdebug("Query Error: topLevelChildren = generateDeltaResponseOneDriveApiInstance.listChildren(searchItem.driveId, searchItem.id, nextLink)");
				log.vdebug("driveId:   ", searchItem.driveId);
				log.vdebug("idToQuery: ", searchItem.id);
				log.vdebug("nextLink:  ", nextLink);
				
				string thisFunctionName = getFunctionName!({});
				// HTTP request returned status code 408,429,503,504
				if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 429) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
					// Handle the 429
					if (exception.httpStatusCode == 429) {
						// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
						handleOneDriveThrottleRequest(generateDeltaResponseOneDriveApiInstance);
						log.vdebug("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - attempting to retry topLevelChildren = generateDeltaResponseOneDriveApiInstance.listChildren(searchItem.driveId, searchItem.id, nextLink)");
					}
					// re-try the specific changes queries
					if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
						// 408 - Request Time Out
						// 503 - Service Unavailable
						// 504 - Gateway Timeout
						// Transient error - try again in 30 seconds
						auto errorArray = splitLines(exception.msg);
						log.log(errorArray[0], " when attempting to query OneDrive top level drive children on OneDrive - retrying applicable request in 30 seconds");
						log.vdebug("generateDeltaResponseOneDriveApiInstance.listChildren(searchItem.driveId, searchItem.id, nextLink) previously threw an error - retrying");
						// The server, while acting as a proxy, did not receive a timely response from the upstream server it needed to access in attempting to complete the request. 
						log.vdebug("Thread sleeping for 30 seconds as the server did not receive a timely response from the upstream server it needed to access in attempting to complete the request");
						Thread.sleep(dur!"seconds"(30));
					}
					// re-try original request - retried for 429, 503, 504 - but loop back calling this function 
					//log.vdebug("Retrying Query: generateDeltaResponseOneDriveApiInstance.listChildren(searchItem.driveId, searchItem.id, nextLink)");
					//topLevelChildren = generateDeltaResponseOneDriveApiInstance.listChildren(searchItem.driveId, searchItem.id, nextLink);
					
					log.vdebug("Retrying Function: ", thisFunctionName);
					generateDeltaResponse(pathToQuery);
					
				} else {
					// Default operation if not 408,429,503,504 errors
					// display what the error is
					displayOneDriveErrorMessage(exception.msg, thisFunctionName);
				}
			}
			
			// process top level children
			log.vlog("Adding ", count(topLevelChildren["value"].array), " OneDrive items for processing from the OneDrive 'root' folder");
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
				log.vdebug("Setting nextLink to (@odata.nextLink): ", nextLink);
				nextLink = topLevelChildren["@odata.nextLink"].str;
			} else break;
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

		for (;;) {
			// query this level children
			try {
				thisLevelChildren = queryThisLevelChildren(driveId, idToQuery, nextLink);
			} catch (OneDriveException exception) {
				
				writeln("CODING TO DO: EXCEPTION HANDLING NEEDED: thisLevelChildren = queryThisLevelChildren(driveId, idToQuery, nextLink)");
			
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
					log.vlog("Adding ", count(thisLevelChildren["value"].array), " OneDrive items for processing from ", pathForLogging);
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
					log.vdebug("Setting nextLink to (@odata.nextLink): ", nextLink);
				} else break;
			
			} else {
				// Invalid JSON response when querying this level children
				log.vdebug("INVALID JSON response when attempting a retry of parent function - queryForChildren(driveId, idToQuery, childParentPath, pathForLogging)");
				// retry thisLevelChildren = queryThisLevelChildren
				log.vdebug("Thread sleeping for an additional 30 seconds");
				Thread.sleep(dur!"seconds"(30));
				log.vdebug("Retry this call thisLevelChildren = queryThisLevelChildren(driveId, idToQuery, nextLink)");
				thisLevelChildren = queryThisLevelChildren(driveId, idToQuery, nextLink);
			}
		}
		
		// return response
		return thisLevelChildrenData;
	}
	
	// Query the OneDrive API for the child objects for this element
	JSONValue queryThisLevelChildren(string driveId, string idToQuery, string nextLink) {
		
		// function variables 
		JSONValue thisLevelChildren;
		
		// Create new OneDrive API Instance
		OneDriveApi queryChildrenOneDriveApiInstance;
		queryChildrenOneDriveApiInstance = new OneDriveApi(appConfig);
		queryChildrenOneDriveApiInstance.initialise();
	
		// query children
		try {
			// attempt API call
			log.vdebug("Attempting Query: thisLevelChildren = queryChildrenOneDriveApiInstance.listChildren(driveId, idToQuery, nextLink)");
			thisLevelChildren = queryChildrenOneDriveApiInstance.listChildren(driveId, idToQuery, nextLink);
			log.vdebug("Query 'thisLevelChildren = queryChildrenOneDriveApiInstance.listChildren(driveId, idToQuery, nextLink)' performed successfully");
			queryChildrenOneDriveApiInstance.shutdown();
			// Free object and memory
			object.destroy(queryChildrenOneDriveApiInstance);
		} catch (OneDriveException exception) {
			// OneDrive threw an error
			log.vdebug("------------------------------------------------------------------");
			log.vdebug("Query Error: thisLevelChildren = queryChildrenOneDriveApiInstance.listChildren(driveId, idToQuery, nextLink)");
			log.vdebug("driveId: ", driveId);
			log.vdebug("idToQuery: ", idToQuery);
			log.vdebug("nextLink: ", nextLink);
			
			string thisFunctionName = getFunctionName!({});
			// HTTP request returned status code 408,429,503,504
			if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 429) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
				// Handle the 429
				if (exception.httpStatusCode == 429) {
					// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
					handleOneDriveThrottleRequest(queryChildrenOneDriveApiInstance);
					log.vdebug("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - attempting to retry ", thisFunctionName);
				}
				// re-try the specific changes queries
				if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
					// 408 - Request Time Out
					// 503 - Service Unavailable
					// 504 - Gateway Timeout
					// Transient error - try again in 30 seconds
					auto errorArray = splitLines(exception.msg);
					log.log(errorArray[0], " when attempting to query OneDrive drive item children - retrying applicable request in 30 seconds");
					log.vdebug("thisLevelChildren = queryChildrenOneDriveApiInstance.listChildren(driveId, idToQuery, nextLink) previously threw an error - retrying");
					// The server, while acting as a proxy, did not receive a timely response from the upstream server it needed to access in attempting to complete the request. 
					log.vdebug("Thread sleeping for 30 seconds as the server did not receive a timely response from the upstream server it needed to access in attempting to complete the request");
					Thread.sleep(dur!"seconds"(30));
				}
				// re-try original request - retried for 429, 503, 504 - but loop back calling this function 
				//log.vdebug("Retrying Query: thisLevelChildren = queryThisLevelChildren(driveId, idToQuery, nextLink)");
				//thisLevelChildren = queryThisLevelChildren(driveId, idToQuery, nextLink);
				log.vdebug("Retrying Function: ", thisFunctionName);
				queryThisLevelChildren(driveId, idToQuery, nextLink);
				
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
			log.vdebug("Testing for the existance online of this folder path: ", thisFolderName);
			directoryFoundOnline = false;
			
			// If this is '.' this is the account root
			if (thisFolderName == ".") {
				currentPathTree = thisFolderName;
			} else {
				currentPathTree = currentPathTree ~ "/" ~ thisFolderName;
			}
			
			log.vdebug("Attempting to query OneDrive for this path: ", currentPathTree);
			
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
							log.vdebug("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - attempting to retry ", thisFunctionName);
						}
						// re-try the specific changes queries
						if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
							// 408 - Request Time Out
							// 503 - Service Unavailable
							// 504 - Gateway Timeout
							// Transient error - try again in 30 seconds
							auto errorArray = splitLines(exception.msg);
							log.log(errorArray[0], " when attempting to query path on OneDrive - retrying applicable request in 30 seconds");
							log.vdebug(thisFunctionName, " previously threw an error - retrying");
							// The server, while acting as a proxy, did not receive a timely response from the upstream server it needed to access in attempting to complete the request. 
							log.vdebug("Thread sleeping for 30 seconds as the server did not receive a timely response from the upstream server it needed to access in attempting to complete the request");
							Thread.sleep(dur!"seconds"(30));
						}
						// re-try original request - retried for 429, 503, 504 - but loop back calling this function 
						log.vdebug("Retrying Function: ", thisFunctionName);
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
						performPosixTest(thisFolderName, getPathDetailsAPIResponse["name"].str);
						// No POSIX issue with requested path element
						parentDetails = makeItem(getPathDetailsAPIResponse);
						// Save item to the database
						saveItem(getPathDetailsAPIResponse);
						directoryFoundOnline = true;
						
						// Is this JSON a remote object
						if (isItemRemote(getPathDetailsAPIResponse)) {
							// Remote Directory .. need a DB Tie Item
							log.vdebug("Creating a DB TIE for this Shared Folder");
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
							log.vdebug("Adding tie DB record to database: ", tieDBItem);
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
									log.vdebug("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - attempting to retry ", thisFunctionName);
								}
								// re-try the specific changes queries
								if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
									// 408 - Request Time Out
									// 503 - Service Unavailable
									// 504 - Gateway Timeout
									// Transient error - try again in 30 seconds
									auto errorArray = splitLines(exception.msg);
									log.log(errorArray[0], " when attempting to query path on OneDrive - retrying applicable request in 30 seconds");
									log.vdebug(thisFunctionName, " previously threw an error - retrying");
									// The server, while acting as a proxy, did not receive a timely response from the upstream server it needed to access in attempting to complete the request. 
									log.vdebug("Thread sleeping for 30 seconds as the server did not receive a timely response from the upstream server it needed to access in attempting to complete the request");
									Thread.sleep(dur!"seconds"(30));
								}
								// re-try original request - retried for 429, 503, 504 - but loop back calling this function 
								log.vdebug("Retrying Function: ", thisFunctionName);
								queryOneDriveForSpecificPathAndCreateIfMissing(thisNewPathToSearch, createPathIfMissing);
							} else {
								// Default operation if not 408,429,503,504 errors
								// display what the error is
								displayOneDriveErrorMessage(exception.msg, thisFunctionName);
							}
						}
					}
				} else {
					// parentDetails.driveId is not the account drive id - thus will be a remote shared item
					log.vdebug("This parent directory is a remote object this next path will be on a remote drive");
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
							log.vdebug("Setting nextLink to (@odata.nextLink): ", nextLink);
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
						log.vdebug("FOLDER NOT FOUND ONLINE AND WE ARE REQUESTED TO CREATE IT");
						log.vdebug("Create folder on this drive:             ", parentDetails.driveId);
						log.vdebug("Create folder as a child on this object: ", parentDetails.id);
						log.vdebug("Create this folder name:                 ", thisFolderName);
						
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
									log.vlog("OneDrive reported that ", thisFolderName, " already exists .. OneDrive API race condition");
								} else {
									// some other error from OneDrive was returned - display what it is
									log.error("OneDrive generated an error when creating this path: ", thisFolderName);
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
		log.vdebug("queryOneDriveForSpecificPathAndCreateIfMissing.getPathDetailsAPIResponse = ", getPathDetailsAPIResponse);
		return getPathDetailsAPIResponse;
	}
	
	// Delete an item by it's path
	// This function is only used in --monitor mode
	void deleteByPath(const(string) path) {
		
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
		if (!itemInDB) {
			throw new SyncException("The item to delete is not in the local database");
		}
		
		if (dbItem.parentId == null) {
			// the item is a remote folder, need to do the operation on the parent
			enforce(itemDB.selectByPathWithoutRemote(path, appConfig.defaultDriveId, dbItem));
		}
		
		try {
			if (noRemoteDelete) {
				// do not process remote delete
				log.vlog("Skipping remote delete as --upload-only & --no-remote-delete configured");
			} else {
				uploadDeletedItem(dbItem, path);
			}
		} catch (OneDriveException e) {
			if (e.httpStatusCode == 404) {
				log.log(e.msg);
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
		log.log("Moving ", oldPath, " to ", newPath);
		// Is this move unwanted?
		bool unwanted = false;
		// Item variables
		Item oldItem, newItem, parentItem;
		
		// This not a Client Side Filtering check, nor a Microsoft Check, but is a sanity check that the path provided is UTF encoded correctly
		// Check the std.encoding of the path against: Unicode 5.0, ASCII, ISO-8859-1, ISO-8859-2, WINDOWS-1250, WINDOWS-1251, WINDOWS-1252
		if (!unwanted) {
			if(!isValid(newPath)) {
				// Path is not valid according to https://dlang.org/phobos/std_encoding.html
				log.logAndNotify("Skipping item - invalid character encoding sequence: ", newPath);
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
		
		// Check against Microsoft OneDrive restriction and limitations about Windows naming files
		if (!unwanted) {
			unwanted = checkPathAgainstMicrosoftNamingRestrictions(newPath);
		}
		
		// 'newPath' has passed client side filtering validation
		if (!unwanted) {
		
			if (!itemDB.selectByPath(oldPath, appConfig.defaultDriveId, oldItem)) {
				// The old path|item is not synced with the database, upload as a new file
				log.log("Moved local item was not in-sync with local databse - uploading as new item");
				uploadNewFile(newPath);
				return;
			}
		
			if (oldItem.parentId == null) {
				// the item is a remote folder, need to do the operation on the parent
				enforce(itemDB.selectByPathWithoutRemote(oldPath, appConfig.defaultDriveId, oldItem));
			}
		
			if (itemDB.selectByPath(newPath, appConfig.defaultDriveId, newItem)) {
				// the destination has been overwritten
				log.log("Moved local item overwrote an existing item - deleting old online item");
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
					log.vlog("uploadMoveItem target has disappeared: ", newPath);
					return;
				}
			
				// Configure the modification JSON item
				SysTime mtime = timeLastModified(newPath).toUTC();
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
				JSONValue response;
				
				// Create a new API Instance for this thread and initialise it
				OneDriveApi movePathOnlineApiInstance;
				movePathOnlineApiInstance = new OneDriveApi(appConfig);
				movePathOnlineApiInstance.initialise();
				
				try {
					response = movePathOnlineApiInstance.updateById(oldItem.driveId, oldItem.id, data, oldItem.eTag);
				} catch (OneDriveException e) {
					if (e.httpStatusCode == 412) {
						// OneDrive threw a 412 error, most likely: ETag does not match current item's value
						// Retry without eTag
						log.vdebug("File Move Failed - OneDrive eTag / cTag match issue");
						log.vlog("OneDrive returned a 'HTTP 412 - Precondition Failed' when attempting to move the file - gracefully handling error");
						string nullTag = null;
						// move the file but without the eTag
						response = movePathOnlineApiInstance.updateById(oldItem.driveId, oldItem.id, data, nullTag);
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
			log.log("Item has been moved to a location that is excluded from sync operations. Removing item from OneDrive");
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
				ulong uploadFileSize = uploadResponse["size"].integer;
				string uploadFileHash = uploadResponse["file"]["hashes"]["quickXorHash"].str;
				string localFileHash = computeQuickXorHash(localFilePath);
				
				if ((localFileSize == uploadFileSize) && (localFileHash == uploadFileHash)) {
					// Uploaded file integrity intact
					log.vdebug("Uploaded local file matches reported online size and hash values");
					integrityValid = true;
				} else {
					// Upload integrity failure .. what failed?
					// There are 2 scenarios where this happens:
					// 1. Failed Transfer
					// 2. Upload file is going to a SharePoint Site, where Microsoft enriches the file with additional metadata with no way to disable
					log.logAndNotify("WARNING: Uploaded file integrity failure for: ", localFilePath);
					
					// What integrity failed - size?
					if (localFileSize != uploadFileSize) {
						log.vlog("WARNING: Uploaded file integrity failure - Size Mismatch");
					}
					// What integrity failed - hash?
					if (localFileHash != uploadFileHash) {
						log.vlog("WARNING: Uploaded file integrity failure - Hash Mismatch");
					}
					
					// What account type is this?
					if (appConfig.accountType != "personal") {
						// Not a personal account, thus the integrity failure is most likely due to SharePoint
						log.vlog("CAUTION: Microsoft SharePoint enhances files after you upload them, which means this file may now have technical differences from your local copy, resulting in an integrity issue.");
						log.vlog("See: https://github.com/OneDrive/onedrive-api-docs/issues/935 for further details");
					}
					// How can this be disabled?
					log.log("To disable the integrity checking of uploaded files use --disable-upload-validation");
				}
			} else {
				log.log("Upload file validation unable to be performed: input JSON was invalid");
				log.log("WARNING: Skipping upload integrity check for: ", localFilePath);
			}
		} else {
			// We are bypassing integrity checks due to --disable-upload-validation
			log.vdebug("Upload file validation disabled due to --disable-upload-validation");
			log.vlog("WARNING: Skipping upload integrity check for: ", localFilePath);
		}
		
		// Is the file integrity online valid?
		return integrityValid;
	}
	
	// Query Office 365 SharePoint Shared Library site name to obtain it's Drive ID
	void querySiteCollectionForDriveID(string sharepointLibraryNameToQuery)
	{
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
			log.error("ERROR: A OneDrive Personal Account cannot be used with --get-sharepoint-drive-id. Please re-authenticate your client using a OneDrive Business Account.");
			return;
		}
		
		// What query are we performing?
		writeln();
		log.log("Office 365 Library Name Query: ", sharepointLibraryNameToQuery);
		
		for (;;) {
			try {
				siteQuery = querySharePointLibraryNameApiInstance.o365SiteSearch(nextLink);
			} catch (OneDriveException e) {
				log.error("ERROR: Query of OneDrive for Office 365 Library Name failed");
				// Forbidden - most likely authentication scope needs to be updated
				if (e.httpStatusCode == 403) {
					log.error("ERROR: Authentication scope needs to be updated. Use --reauth and re-authenticate client.");
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
					log.error("ERROR: Your OneDrive Account and Authentication Scope cannot access this OneDrive API: ", siteSearchUrl);
					log.error("ERROR: To resolve, please discuss this issue with whomever supports your OneDrive and SharePoint environment.");
					return;
				}
				// HTTP request returned status code 429 (Too Many Requests)
				if (e.httpStatusCode == 429) {
					// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
					handleOneDriveThrottleRequest(querySharePointLibraryNameApiInstance);
					log.vdebug("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - attempting to query OneDrive drive children");
				}
				// HTTP request returned status code 504 (Gateway Timeout) or 429 retry
				if ((e.httpStatusCode == 429) || (e.httpStatusCode == 504)) {
					// re-try the specific changes queries	
					if (e.httpStatusCode == 504) {
						log.log("OneDrive returned a 'HTTP 504 - Gateway Timeout' when attempting to query Sharepoint Sites - retrying applicable request");
						log.vdebug("siteQuery = onedrive.o365SiteSearch(nextLink) previously threw an error - retrying");
						// The server, while acting as a proxy, did not receive a timely response from the upstream server it needed to access in attempting to complete the request. 
						log.vdebug("Thread sleeping for 30 seconds as the server did not receive a timely response from the upstream server it needed to access in attempting to complete the request");
						Thread.sleep(dur!"seconds"(30));
					}
					// re-try original request - retried for 429 and 504
					try {
						log.vdebug("Retrying Query: siteQuery = onedrive.o365SiteSearch(nextLink)");
						siteQuery = querySharePointLibraryNameApiInstance.o365SiteSearch(nextLink);
						log.vdebug("Query 'siteQuery = onedrive.o365SiteSearch(nextLink)' performed successfully on re-try");
					} catch (OneDriveException e) {
						// display what the error is
						log.vdebug("Query Error: siteQuery = onedrive.o365SiteSearch(nextLink) on re-try after delay");
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
				log.vdebug("O365 Query Response: ", siteQuery);
				
				foreach (searchResult; siteQuery["value"].array) {
					// Need an 'exclusive' match here with sharepointLibraryNameToQuery as entered
					log.vdebug("Found O365 Site: ", searchResult);
					
					// 'displayName' and 'id' have to be present in the search result record in order to query the site
					if (("displayName" in searchResult) && ("id" in searchResult)) {
						if (sharepointLibraryNameToQuery == searchResult["displayName"].str){
							// 'displayName' matches search request
							site_id = searchResult["id"].str;
							JSONValue siteDriveQuery;
							
							try {
								siteDriveQuery = querySharePointLibraryNameApiInstance.o365SiteDrives(site_id);
							} catch (OneDriveException e) {
								log.error("ERROR: Query of OneDrive for Office Site ID failed");
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
									log.vdebug("Site Details: ", driveResult);
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
								log.error("ERROR: There was an error performing this operation on OneDrive");
								log.error("ERROR: Increase logging verbosity to assist determining why.");
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
						writeln();
						log.error("ERROR: SharePoint Site details not provided for: ", siteNameAvailable);
						log.error("ERROR: The SharePoint Site results returned from OneDrive API do not contain the required items to match. Please check your permissions with your site administrator.");
						log.error("ERROR: Your site security settings is preventing the following details from being accessed: 'displayName' or 'id'");
						log.vlog(" - Is 'displayName' available = ", displayNameAvailable);
						log.vlog(" - Is 'id' available          = ", idAvailable);
						log.error("ERROR: To debug this further, please increase verbosity (--verbose or --verbose --verbose) to provide further insight as to what details are actually being returned.");
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
								log.vdebug("Bad SharePoint Data for site: ", searchResult);
							}
						}
					}
				}
			} else {
				// not a valid JSON object
				log.error("ERROR: There was an error performing this operation on OneDrive");
				log.error("ERROR: Increase logging verbosity to assist determining why.");
				return;
			}
			
			// If a collection exceeds the default page size (200 items), the @odata.nextLink property is returned in the response 
			// to indicate more items are available and provide the request URL for the next page of items.
			if ("@odata.nextLink" in siteQuery) {
				// Update nextLink to next set of SharePoint library names
				nextLink = siteQuery["@odata.nextLink"].str;
				log.vdebug("Setting nextLink to (@odata.nextLink): ", nextLink);
			} else break;
		}
		
		// Was the intended target found?
		if(!found) {
			
			// Was the search a wildcard?
			if (sharepointLibraryNameToQuery != "*") {
				// Only print this out if the search was not a wildcard
				writeln();
				log.error("ERROR: The requested SharePoint site could not be found. Please check it's name and your permissions to access the site.");
			}
			// List all sites returned to assist user
			writeln();
			log.log("The following SharePoint site names were returned:");
			foreach (searchResultEntry; siteSearchResults) {
				// list the display name that we use to match against the user query
				log.log(searchResultEntry);
			}
		}
		
		// Shutdown API instance
		querySharePointLibraryNameApiInstance.shutdown();
		// Free object and memory
		object.destroy(querySharePointLibraryNameApiInstance);
	}
}