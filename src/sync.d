import std.algorithm;
import std.array: array;
import std.datetime;
import std.exception: enforce;
import std.file, std.json, std.path;
import std.regex;
import std.stdio, std.string, std.uni, std.uri;
import std.conv;
import std.encoding;
import core.time, core.thread;
import core.stdc.stdlib;
import config, itemdb, onedrive, selective, upload, util;
static import log;

// threshold after which files will be uploaded using an upload session
private long thresholdFileSize = 4 * 2^^20; // 4 MiB

// flag to set whether local files should be deleted from OneDrive
private bool noRemoteDelete = false;

// flag to set whether the local file should be deleted once it is successfully uploaded to OneDrive
private bool localDeleteAfterUpload = false;

// flag to set if we are running as uploadOnly
private bool uploadOnly = false;

// Do we configure to disable the upload validation routine
private bool disableUploadValidation = false;

private bool isItemFolder(const ref JSONValue item)
{
	return ("folder" in item) != null;
}

private bool isItemFile(const ref JSONValue item)
{
	return ("file" in item) != null;
}

private bool isItemDeleted(const ref JSONValue item)
{
	return ("deleted" in item) != null;
}

private bool isItemRoot(const ref JSONValue item)
{
	return ("root" in item) != null;
}

private bool isItemRemote(const ref JSONValue item)
{
	return ("remoteItem" in item) != null;
}

private bool hasParentReference(const ref JSONValue item)
{
	return ("parentReference" in item) != null;
}

private bool hasParentReferenceId(const ref JSONValue item)
{
	return ("id" in item["parentReference"]) != null;
}

private bool hasParentReferencePath(const ref JSONValue item)
{
	return ("path" in item["parentReference"]) != null;
}

private bool isMalware(const ref JSONValue item)
{
	return ("malware" in item) != null;
}

private bool hasFileSize(const ref JSONValue item)
{
	return ("size" in item) != null;
}

private bool hasId(const ref JSONValue item)
{
	return ("id" in item) != null;
}

private bool hasHashes(const ref JSONValue item)
{
	return ("hashes" in item["file"]) != null;
}

private bool hasQuickXorHash(const ref JSONValue item)
{
	return ("quickXorHash" in item["file"]["hashes"]) != null;
}

private bool hasSha1Hash(const ref JSONValue item)
{
	return ("sha1Hash" in item["file"]["hashes"]) != null;
}

private bool isDotFile(const(string) path)
{
	// always allow the root
	if (path == ".") return false;
	auto paths = pathSplitter(buildNormalizedPath(path));
	foreach(base; paths) {
		if (startsWith(base, ".")){
			return true;
		}
	}
	return false;
}

// construct an Item struct from a JSON driveItem
private Item makeItem(const ref JSONValue driveItem)
{
	Item item = {
		id: driveItem["id"].str,
		name: "name" in driveItem ? driveItem["name"].str : null, // name may be missing for deleted files in OneDrive Biz
		eTag: "eTag" in driveItem ? driveItem["eTag"].str : null, // eTag is not returned for the root in OneDrive Biz
		cTag: "cTag" in driveItem ? driveItem["cTag"].str : null, // cTag is missing in old files (and all folders in OneDrive Biz)
	};

	// OneDrive API Change: https://github.com/OneDrive/onedrive-api-docs/issues/834
	// OneDrive no longer returns lastModifiedDateTime if the item is deleted by OneDrive
	if(isItemDeleted(driveItem)){
		// Set mtime to SysTime(0)
		item.mtime = SysTime(0);
	} else {
		// Item is not in a deleted state
		// Resolve 'Key not found: fileSystemInfo' when then item is a remote item
		// https://github.com/abraunegg/onedrive/issues/11
		if (isItemRemote(driveItem)) {
			item.mtime = SysTime.fromISOExtString(driveItem["remoteItem"]["fileSystemInfo"]["lastModifiedDateTime"].str);
		} else {
			item.mtime = SysTime.fromISOExtString(driveItem["fileSystemInfo"]["lastModifiedDateTime"].str);
		}
	}
		
	if (isItemFile(driveItem)) {
		item.type = ItemType.file;
	} else if (isItemFolder(driveItem)) {
		item.type = ItemType.dir;
	} else if (isItemRemote(driveItem)) {
		item.type = ItemType.remote;
	} else {
		// do not throw exception, item will be removed in applyDifferences()
	}

	// root and remote items do not have parentReference
	if (!isItemRoot(driveItem) && ("parentReference" in driveItem) != null) {
		item.driveId = driveItem["parentReference"]["driveId"].str;
		if (hasParentReferenceId(driveItem)) {
			item.parentId = driveItem["parentReference"]["id"].str;
		}
	}

	// extract the file hash
	if (isItemFile(driveItem) && ("hashes" in driveItem["file"])) {
		if ("crc32Hash" in driveItem["file"]["hashes"]) {
			item.crc32Hash = driveItem["file"]["hashes"]["crc32Hash"].str;
		} else if ("sha1Hash" in driveItem["file"]["hashes"]) {
			item.sha1Hash = driveItem["file"]["hashes"]["sha1Hash"].str;
		} else if ("quickXorHash" in driveItem["file"]["hashes"]) {
			item.quickXorHash = driveItem["file"]["hashes"]["quickXorHash"].str;
		} else {
			log.vlog("The file does not have any hash");
		}
	}

	if (isItemRemote(driveItem)) {
		item.remoteDriveId = driveItem["remoteItem"]["parentReference"]["driveId"].str;
		item.remoteId = driveItem["remoteItem"]["id"].str;
	}
	
	// National Cloud Deployments (US and DE) do not support /delta as a query
	// Thus we need to track in the database that this item is in sync
	// As we are making an item, set the syncStatus to Y
	// ONLY when using a National Cloud Deployment, all the existing DB entries will get set to N
	// so when processing /children, it can be identified what the 'deleted' difference is
	item.syncStatus = "Y";

	return item;
}

private bool testFileHash(const(string) path, const ref Item item)
{
	if (item.crc32Hash) {
		if (item.crc32Hash == computeCrc32(path)) return true;
	} else if (item.sha1Hash) {
		if (item.sha1Hash == computeSha1Hash(path)) return true;
	} else if (item.quickXorHash) {
		if (item.quickXorHash == computeQuickXorHash(path)) return true;
	}
	return false;
}

class SyncException: Exception
{
    @nogc @safe pure nothrow this(string msg, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line);
    }
}

final class SyncEngine
{
	private Config cfg;
	private OneDriveApi onedrive;
	private ItemDatabase itemdb;
	private UploadSession session;
	private SelectiveSync selectiveSync;
	// list of items to skip while applying the changes
	private string[] skippedItems;
	// list of items to delete after the changes has been downloaded
	private string[2][] idsToDelete;
	// list of items we fake created when running --dry-run
	private string[2][] idsFaked;
	// default drive id
	private string defaultDriveId;
	// default root id
	private string defaultRootId;
	// type of OneDrive account
	private string accountType;
	// free space remaining at init()
	private long remainingFreeSpace;
	// file size limit for a new file
	private long newSizeLimit;
	// is file malware flag
	private bool malwareDetected = false;
	// download filesystem issue flag
	private bool downloadFailed = false;
	// upload failure - OneDrive or filesystem issue (reading data)
	private bool uploadFailed = false;
	// initialization has been done
	private bool initDone = false;
	// sync engine dryRun flag
	private bool dryRun = false;
	// quota details available
	private bool quotaAvailable = true;
	// sync business shared folders flag
	private bool syncBusinessFolders = false;
	// single directory scope flag
	private bool singleDirectoryScope = false;
	// is sync_list configured
	private bool syncListConfigured = false;
	// sync_list new folder added, trigger delta scan override
	private bool oneDriveFullScanTrigger = false;
	// is bypass_data_preservation set via config file
	// Local data loss MAY occur in this scenario
	private bool bypassDataPreservation = false;
	// is National Cloud Deployments configured
	private bool nationalCloudDeployment = false;
	// array of all OneDrive driveId's for use with OneDrive Business Folders
	private string[] driveIDsArray;

	this(Config cfg, OneDriveApi onedrive, ItemDatabase itemdb, SelectiveSync selectiveSync)
	{
		assert(onedrive && itemdb && selectiveSync);
		this.cfg = cfg;
		this.onedrive = onedrive;
		this.itemdb = itemdb;
		this.selectiveSync = selectiveSync;
		// session = UploadSession(onedrive, cfg.uploadStateFilePath);
		this.dryRun = cfg.getValueBool("dry_run");
		this.newSizeLimit = cfg.getValueLong("skip_size") * 2^^20;
		this.newSizeLimit = (this.newSizeLimit == 0) ? long.max : this.newSizeLimit;
	}

	void reset()
	{
		initDone=false;
	}

	void init()
	{
		// Set accountType, defaultDriveId, defaultRootId & remainingFreeSpace once and reuse where possible
		JSONValue oneDriveDetails;
		JSONValue oneDriveRootDetails;

		if (initDone) {
			return;
		}

		session = UploadSession(onedrive, cfg.uploadStateFilePath);

		// Need to catch 400 or 5xx server side errors at initialization
		// Get Default Drive
		try {
			oneDriveDetails	= onedrive.getDefaultDrive();
		} catch (OneDriveException e) {
			log.vdebug("oneDriveDetails	= onedrive.getDefaultDrive() generated a OneDriveException");
			if (e.httpStatusCode == 400) {
				// OneDrive responded with 400 error: Bad Request
				displayOneDriveErrorMessage(e.msg);
				
				// Check this
				if (cfg.getValueString("drive_id").length) {
					log.error("\nERROR: Check your 'drive_id' entry in your configuration file as it may be incorrect\n");
				}
				// Must exit here
				exit(-1);
			}
			if (e.httpStatusCode == 401) {
				// HTTP request returned status code 401 (Unauthorized)
				displayOneDriveErrorMessage(e.msg);
				log.error("\nERROR: Check your configuration as your refresh_token may be empty or invalid. You may need to issue a --logout and re-authorise this client.\n");
				// Must exit here
				exit(-1);
			}
			if (e.httpStatusCode == 429) {
				// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
				handleOneDriveThrottleRequest();
				// Retry original request by calling function again to avoid replicating any further error handling
				log.vdebug("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - calling init();");
				init();
				// return back to original call
				return;
			}
			if (e.httpStatusCode >= 500) {
				// There was a HTTP 5xx Server Side Error
				displayOneDriveErrorMessage(e.msg);
				// Must exit here
				exit(-1);
			}
		}
		
		// Get Default Root
		try {
			oneDriveRootDetails = onedrive.getDefaultRoot();
		} catch (OneDriveException e) {
			log.vdebug("oneDriveRootDetails = onedrive.getDefaultRoot() generated a OneDriveException");
			if (e.httpStatusCode == 400) {
				// OneDrive responded with 400 error: Bad Request
				displayOneDriveErrorMessage(e.msg);
				// Check this
				if (cfg.getValueString("drive_id").length) {
					log.error("\nERROR: Check your 'drive_id' entry in your configuration file as it may be incorrect\n");
				}
				// Must exit here
				exit(-1);
			}
			if (e.httpStatusCode == 401) {
				// HTTP request returned status code 401 (Unauthorized)
				displayOneDriveErrorMessage(e.msg);
				log.error("\nERROR: Check your configuration as your refresh_token may be empty or invalid. You may need to issue a --logout and re-authorise this client.\n");
				// Must exit here
				exit(-1);
			}
			if (e.httpStatusCode == 429) {
				// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
				handleOneDriveThrottleRequest();
				// Retry original request by calling function again to avoid replicating any further error handling
				log.vdebug("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - calling init();");
				init();
				// return back to original call
				return;
			}
			if (e.httpStatusCode >= 500) {
				// There was a HTTP 5xx Server Side Error
				displayOneDriveErrorMessage(e.msg);
				// Must exit here
				exit(-1);
			}
		}

		if ((oneDriveDetails.type() == JSONType.object) && (oneDriveRootDetails.type() == JSONType.object) && (hasId(oneDriveDetails)) && (hasId(oneDriveRootDetails))) {
			// JSON elements are valid
			// Debug OneDrive Account details response
			log.vdebug("OneDrive Account Details:      ", oneDriveDetails);
			log.vdebug("OneDrive Account Root Details: ", oneDriveRootDetails);
			
			// Successfully got details from OneDrive without a server side error such as 'HTTP/1.1 500 Internal Server Error' or 'HTTP/1.1 504 Gateway Timeout' 
			accountType = oneDriveDetails["driveType"].str;
			defaultDriveId = oneDriveDetails["id"].str;
			defaultRootId = oneDriveRootDetails["id"].str;
			remainingFreeSpace = oneDriveDetails["quota"]["remaining"].integer;
			// Make sure that defaultDriveId is in our driveIDs array to use when checking if item is in database
			// Keep the driveIDsArray with unique entries only
			if (!canFind(driveIDsArray, defaultDriveId)) {
				// Add this drive id to the array to search with
				driveIDsArray ~= defaultDriveId;
			}
			
			// In some cases OneDrive Business configurations 'restrict' quota details thus is empty / blank / negative value / zero
			if (remainingFreeSpace <= 0) {
				// free space is <= 0  .. why ?
				if ("remaining" in oneDriveDetails["quota"]){
					// json response contained a 'remaining' value
					log.error("ERROR: OneDrive account currently has zero space available. Please free up some space online.");
				} else {
					// json response was missing a 'remaining' value
					if (accountType == "personal"){
						log.error("ERROR: OneDrive quota information is missing. Potentially your OneDrive account currently has zero space available. Please free up some space online.");
					} else {
						// quota details not available
						log.error("ERROR: OneDrive quota information is being restricted. Please fix by speaking to your OneDrive / Office 365 Administrator.");
					}				
				}
				// flag to not perform quota checks
				log.error("ERROR: Flagging to disable upload space checks - this MAY have undesirable results if a file cannot be uploaded due to out of space.");
				quotaAvailable = false;
			}
			
			// Display accountType, defaultDriveId, defaultRootId & remainingFreeSpace for verbose logging purposes
			log.vlog("Application version: ", strip(import("version")));
			log.vlog("Account Type: ", accountType);
			log.vlog("Default Drive ID: ", defaultDriveId);
			log.vlog("Default Root ID: ", defaultRootId);
			log.vlog("Remaining Free Space: ", remainingFreeSpace);
		
			// If account type is documentLibrary - then most likely this is a SharePoint repository
			// and files 'may' be modified after upload. See: https://github.com/abraunegg/onedrive/issues/205
			if(accountType == "documentLibrary") {
				setDisableUploadValidation();
			}
		
			// Check the local database to ensure the OneDrive Root details are in the database
			checkDatabaseForOneDriveRoot();
		
			// Check if there is an interrupted upload session
			if (session.restore()) {
				log.log("Continuing the upload session ...");
				auto item = session.upload();
				saveItem(item);
			}		
			initDone = true;
		} else {
			// init failure
			initDone = false;
			// log why
			log.error("ERROR: Unable to query OneDrive to initialize application");
			// Debug OneDrive Account details response
			log.vdebug("OneDrive Account Details:      ", oneDriveDetails);
			log.vdebug("OneDrive Account Root Details: ", oneDriveRootDetails);
			// Must exit here
			exit(-1);
		}
	}

	// Configure uploadOnly if function is called
	// By default, uploadOnly = false;
	void setUploadOnly()
	{
		uploadOnly = true;
	}
	
	// Configure noRemoteDelete if function is called
	// By default, noRemoteDelete = false;
	// Meaning we will process local deletes to delete item on OneDrive
	void setNoRemoteDelete()
	{
		noRemoteDelete = true;
	}
	
	// Configure localDeleteAfterUpload if function is called
	// By default, localDeleteAfterUpload = false;
	// Meaning we will not delete any local file after upload is successful
	void setLocalDeleteAfterUpload()
	{
		localDeleteAfterUpload = true;
	}
	
	// set the flag that we are going to sync business shared folders
	void setSyncBusinessFolders()
	{
		syncBusinessFolders = true;
	}
	
	// Configure singleDirectoryScope if function is called
	// By default, singleDirectoryScope = false
	void setSingleDirectoryScope()
	{
		singleDirectoryScope = true;
	}
	
	// Configure disableUploadValidation if function is called
	// By default, disableUploadValidation = false;
	// Meaning we will always validate our uploads
	// However, when uploading a file that can contain metadata SharePoint will associate some 
	// metadata from the library the file is uploaded to directly in the file
	// which breaks this validation. See https://github.com/abraunegg/onedrive/issues/205
	void setDisableUploadValidation()
	{
		disableUploadValidation = true;
		log.vdebug("documentLibrary account type - flagging to disable upload validation checks due to Microsoft SharePoint file modification enrichments");
	}
	
	// Issue #658 Handling
	// If an existing folder is moved into a sync_list valid path (where it previously was out of scope due to sync_list), 
	// then set this flag to true, so that on the second 'true-up' sync, we force a rescan of the OneDrive path to capture any 'files'
	void setOneDriveFullScanTrigger()
	{
		oneDriveFullScanTrigger = true;
		log.vdebug("Setting oneDriveFullScanTrigger = true due to new folder creation request in a location that is now in-scope which may have previously out of scope");
	}
	
	// unset method
	void unsetOneDriveFullScanTrigger()
	{
		oneDriveFullScanTrigger = false;
		log.vdebug("Setting oneDriveFullScanTrigger = false");
	}
	
	// set syncListConfigured to true
	void setSyncListConfigured()
	{
		syncListConfigured = true;
		log.vdebug("Setting syncListConfigured = true");
	}
	
	// set bypassDataPreservation to true
	void setBypassDataPreservation()
	{
		bypassDataPreservation = true;
		log.vdebug("Setting bypassDataPreservation = true");
	}
	
	// set nationalCloudDeployment to true
	void setNationalCloudDeployment()
	{
		nationalCloudDeployment = true;
		log.vdebug("Setting nationalCloudDeployment = true");
	}
	
	// return the OneDrive Account Type
	auto getAccountType()
	{
		// return account type in use
		return accountType;
	}
	
	// download all new changes from OneDrive
	void applyDifferences(bool performFullItemScan)
	{
		// Set defaults for the root folder
		// Use the global's as initialised via init() rather than performing unnecessary additional HTTPS calls
		string driveId = defaultDriveId;
		string rootId = defaultRootId;
		applyDifferences(driveId, rootId, performFullItemScan);

		// Check OneDrive Personal Shared Folders
		if (accountType == "personal"){
			// https://github.com/OneDrive/onedrive-api-docs/issues/764
			Item[] items = itemdb.selectRemoteItems();
			foreach (item; items) {
				log.vdebug("------------------------------------------------------------------");
				if (!cfg.getValueBool("monitor")) {
					log.log("Syncing this OneDrive Personal Shared Folder: ", item.name);
				} else {
					log.vlog("Syncing this OneDrive Personal Shared Folder: ", item.name);
				}
				// Check OneDrive Personal Folders
				applyDifferences(item.remoteDriveId, item.remoteId, performFullItemScan);
			}
		}
		
		// Check OneDrive Business Shared Folders, if configured to do so
		if (syncBusinessFolders){
			// query OneDrive Business Shared Folders shared with me
			log.vlog("Attempting to sync OneDrive Business Shared Folders");
			JSONValue graphQuery = onedrive.getSharedWithMe();
			if (graphQuery.type() == JSONType.object) {
				string sharedFolderName;
				foreach (searchResult; graphQuery["value"].array) {
					sharedFolderName = searchResult["name"].str;
					// Compare this to values in business_shared_folders
					if(selectiveSync.isSharedFolderMatched(sharedFolderName)){
						// Folder name matches what we are looking for
						// Flags for matching
						bool itemInDatabase = false;
						bool itemLocalDirExists = false;
						bool itemPathIsLocal = false;
						
						// "what if" there are 2 or more folders shared with me have the "same" name?
						// The folder name will be the same, but driveId will be different
						// This will then cause these 'shared folders' to cross populate data, which may not be desirable
						log.vdebug("Shared Folder Name: ", sharedFolderName);
						log.vdebug("Parent Drive Id:    ", searchResult["remoteItem"]["parentReference"]["driveId"].str);
						log.vdebug("Shared Item Id:     ", searchResult["remoteItem"]["id"].str);
						Item databaseItem;
						
						// for each driveid in the existing driveIDsArray 
						foreach (searchDriveId; driveIDsArray) {
							log.vdebug("searching database for: ", searchDriveId, " ", sharedFolderName);
							if (itemdb.selectByPath(sharedFolderName, searchDriveId, databaseItem)) {
								log.vdebug("Found shared folder name in database");
								itemInDatabase = true;
								log.vdebug("databaseItem: ", databaseItem);
								// Does the databaseItem.driveId == defaultDriveId?
								if (databaseItem.driveId == defaultDriveId) {
									itemPathIsLocal = true;
								}
							} else {	
								log.vdebug("Shared folder name not found in database");
								// "what if" there is 'already' a local folder with this name
								// Check if in the database
								// If NOT in the database, but resides on disk, this could be a new local folder created after last sync but before this one
								// However we sync 'shared folders' before checking for local changes
								string localpath = expandTilde(cfg.getValueString("sync_dir")) ~ "/" ~ sharedFolderName;
								if (exists(localpath)) {
									// local path exists
									log.vdebug("Found shared folder name in local OneDrive sync_dir");
									itemLocalDirExists = true;
								}
							}
						}
						
						// Shared Folder Evaluation Debugging
						log.vdebug("item in database:                         ", itemInDatabase);
						log.vdebug("path exists on disk:                      ", itemLocalDirExists);
						log.vdebug("database drive id matches defaultDriveId: ", itemPathIsLocal);
						log.vdebug("database data matches search data:        ", ((databaseItem.driveId == searchResult["remoteItem"]["parentReference"]["driveId"].str) && (databaseItem.id == searchResult["remoteItem"]["id"].str)));
						
						// Additional logging
						string sharedByName;
						string sharedByEmail;
						
						// Extra details for verbose logging
						if ("sharedBy" in searchResult["remoteItem"]["shared"]) {
							if ("displayName" in searchResult["remoteItem"]["shared"]["sharedBy"]["user"]) {
								sharedByName = searchResult["remoteItem"]["shared"]["sharedBy"]["user"]["displayName"].str;
							}
							if ("email" in searchResult["remoteItem"]["shared"]["sharedBy"]["user"]) {
								sharedByEmail = searchResult["remoteItem"]["shared"]["sharedBy"]["user"]["email"].str;
							}
						}
						
						if ( ((!itemInDatabase) || (!itemLocalDirExists)) || (((databaseItem.driveId == searchResult["remoteItem"]["parentReference"]["driveId"].str) && (databaseItem.id == searchResult["remoteItem"]["id"].str)) && (!itemPathIsLocal)) ) {
							// This shared folder does not exist in the database
							if (!cfg.getValueBool("monitor")) {
								log.log("Syncing this OneDrive Business Shared Folder: ", sharedFolderName);
							} else {
								log.vlog("Syncing this OneDrive Business Shared Folder: ", sharedFolderName);
							}
							Item businessSharedFolder = makeItem(searchResult);
							
							// Log who shared this to assist with sync data correlation
							if ((sharedByName != "") && (sharedByEmail != "")) {	
								log.vlog("OneDrive Business Shared Folder - Shared By:  ", sharedByName, " (", sharedByEmail, ")");
							} else {
								if (sharedByName != "") {
									log.vlog("OneDrive Business Shared Folder - Shared By:  ", sharedByName);
								}
							}
							
							// Do the actual sync
							applyDifferences(businessSharedFolder.remoteDriveId, businessSharedFolder.remoteId, performFullItemScan);
							// add this parent drive id to the array to search for, ready for next use
							string newDriveID = searchResult["remoteItem"]["parentReference"]["driveId"].str;
							// Keep the driveIDsArray with unique entries only
							if (!canFind(driveIDsArray, newDriveID)) {
								// Add this drive id to the array to search with
								driveIDsArray ~= newDriveID;
							}
						} else {
							// Shared Folder Name Conflict ...
							log.log("WARNING: Skipping shared folder due to existing name conflict: ", sharedFolderName);
							log.log("WARNING: Skipping changes of Path ID: ", searchResult["remoteItem"]["id"].str);
							log.log("WARNING: To sync this shared folder, this shared folder needs to be renamed");
							
							// Log who shared this to assist with conflict resolution
							if ((sharedByName != "") && (sharedByEmail != "")) {	
								log.vlog("WARNING: Conflict Shared By:          ", sharedByName, " (", sharedByEmail, ")");
							} else {
								if (sharedByName != "") {
									log.vlog("WARNING: Conflict Shared By:          ", sharedByName);
								}
							}
						}	
					}
				}
			} else {
				// Log that an invalid JSON object was returned
				log.error("ERROR: onedrive.getSharedWithMe call returned an invalid JSON Object");
			}	
		}
	}

	// download all new changes from a specified folder on OneDrive
	void applyDifferencesSingleDirectory(const(string) path)
	{
		// Ensure we check the 'right' location for this directory on OneDrive
		// It could come from the following places:
		// 1. My OneDrive Root
		// 2. My OneDrive Root as an Office 365 Shared Library
		// 3. A OneDrive Business Shared Folder
		// If 1 & 2, the configured default items are what we need
		// If 3, we need to query OneDrive
		
		string driveId = defaultDriveId;
		string rootId = defaultRootId;
		string folderId;
		JSONValue onedrivePathDetails;
		
		// Check OneDrive Business Shared Folders, if configured to do so
		if (syncBusinessFolders){
			log.vlog("Attempting to sync OneDrive Business Shared Folders");
			// query OneDrive Business Shared Folders shared with me
			JSONValue graphQuery = onedrive.getSharedWithMe();
			
			if (graphQuery.type() == JSONType.object) {
				// valid response from OneDrive
				foreach (searchResult; graphQuery["value"].array) {
					string sharedFolderName = searchResult["name"].str;
					// Compare this to values in business_shared_folders
					if(selectiveSync.isSharedFolderMatched(sharedFolderName)){
						// Folder matches a user configured sync entry
						string[] allowedPath;
						allowedPath ~= sharedFolderName;
						// But is this shared folder what we are looking for?
						if (selectiveSync.isPathIncluded(path,allowedPath)) {
							// Path we want to sync is on a OneDrive Business Shared Folder
							// Set the correct driveId
							driveId = searchResult["remoteItem"]["parentReference"]["driveId"].str;
							// Keep the driveIDsArray with unique entries only
							if (!canFind(driveIDsArray, driveId)) {
								// Add this drive id to the array to search with
								driveIDsArray ~= driveId;
							}
						} 
					} 
				}
			} else {
				// Log that an invalid JSON object was returned
				log.error("ERROR: onedrive.getSharedWithMe call returned an invalid JSON Object");
			}
		}
		
		// Test if the path we are going to sync from actually exists on OneDrive
		log.vlog("Getting path details from OneDrive ...");
		try {
			onedrivePathDetails = onedrive.getPathDetailsByDriveId(driveId, path);
		} catch (OneDriveException e) {
			log.vdebug("onedrivePathDetails = onedrive.getPathDetails(path) generated a OneDriveException");
			if (e.httpStatusCode == 404) {
				// The directory was not found 
				log.error("ERROR: The requested single directory to sync was not found on OneDrive");
				return;
			}
			
			if (e.httpStatusCode == 429) {
				// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
				handleOneDriveThrottleRequest();
				// Retry original request by calling function again to avoid replicating any further error handling
				log.vdebug("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - calling applyDifferencesSingleDirectory(path);");
				applyDifferencesSingleDirectory(path);
				// return back to original call
				return;
			}
						
			if (e.httpStatusCode >= 500) {
				// OneDrive returned a 'HTTP 5xx Server Side Error' - gracefully handling error - error message already logged
				return;
			}
		}
		
		// OK - the path on OneDrive should exist, get the driveId and rootId for this folder
		// Was the response a valid JSON Object?
		if (onedrivePathDetails.type() == JSONType.object) {
			// OneDrive Personal Shared Folder handling
			// Is this item a remote item?
			if(isItemRemote(onedrivePathDetails)){
				// 2 step approach:
				//		1. Ensure changes for the root remote path are captured
				//		2. Download changes specific to the remote path
				
				// root remote
				applyDifferences(defaultDriveId, onedrivePathDetails["id"].str, false);
			
				// remote changes
				driveId = onedrivePathDetails["remoteItem"]["parentReference"]["driveId"].str; // Should give something like 66d53be8a5056eca
				folderId = onedrivePathDetails["remoteItem"]["id"].str; // Should give something like BC7D88EC1F539DCF!107
				
				// Apply any differences found on OneDrive for this path (download data)
				applyDifferences(driveId, folderId, false);
			} else {
				// use the item id as folderId
				folderId = onedrivePathDetails["id"].str; // Should give something like 12345ABCDE1234A1!101
				// Apply any differences found on OneDrive for this path (download data)
				applyDifferences(defaultDriveId, folderId, false);
			}
		} else {
			// Log that an invalid JSON object was returned
			log.vdebug("onedrive.getPathDetails call returned an invalid JSON Object");
		}
	}
	
	// make sure the OneDrive root is in our database
	auto checkDatabaseForOneDriveRoot()
	{
		log.vlog("Fetching details for OneDrive Root");
		JSONValue rootPathDetails = onedrive.getDefaultRoot(); // Returns a JSON Value
		
		// validate object is a JSON value
		if (rootPathDetails.type() == JSONType.object) {
			// valid JSON object
			Item rootPathItem = makeItem(rootPathDetails);
			// configure driveId and rootId for the OneDrive Root
			// Set defaults for the root folder
			string driveId = rootPathDetails["parentReference"]["driveId"].str; // Should give something like 12345abcde1234a1
			string rootId = rootPathDetails["id"].str; // Should give something like 12345ABCDE1234A1!101
			
			// Query the database
			if (!itemdb.selectById(driveId, rootId, rootPathItem)) {
				log.vlog("OneDrive Root does not exist in the database. We need to add it.");	
				applyDifference(rootPathDetails, driveId, true);
				log.vlog("Added OneDrive Root to the local database");
			} else {
				log.vlog("OneDrive Root exists in the database");
			}
		} else {
			// Log that an invalid JSON object was returned
			log.error("ERROR: Unable to query OneDrive for account details");
			log.vdebug("onedrive.getDefaultRoot call returned an invalid JSON Object");
			// Must exit here as we cant configure our required variables
			exit(-1);
		}
	}
	
	// create a directory on OneDrive without syncing
	auto createDirectoryNoSync(const(string) path)
	{
		// Attempt to create the requested path within OneDrive without performing a sync
		log.vlog("Attempting to create the requested path within OneDrive");
		
		// Handle the remote folder creation and updating of the local database without performing a sync
		uploadCreateDir(path);
	}
	
	// delete a directory on OneDrive without syncing
	auto deleteDirectoryNoSync(const(string) path)
	{
		// Use the global's as initialised via init() rather than performing unnecessary additional HTTPS calls
		const(char)[] rootId = defaultRootId;
		
		// Attempt to delete the requested path within OneDrive without performing a sync
		log.vlog("Attempting to delete the requested path within OneDrive");
		
		// test if the path we are going to exists on OneDrive
		try {
			onedrive.getPathDetails(path);
		} catch (OneDriveException e) {
			log.vdebug("onedrive.getPathDetails(path) generated a OneDriveException");
			if (e.httpStatusCode == 404) {
				// The directory was not found on OneDrive - no need to delete it
				log.vlog("The requested directory to delete was not found on OneDrive - skipping removing the remote directory as it doesn't exist");
				return;
			}
			
			if (e.httpStatusCode == 429) {
				// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
				handleOneDriveThrottleRequest();
				// Retry original request by calling function again to avoid replicating any further error handling
				log.vdebug("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - calling deleteDirectoryNoSync(path);");
				deleteDirectoryNoSync(path);
				// return back to original call
				return;
			}
			
			if (e.httpStatusCode >= 500) {
				// OneDrive returned a 'HTTP 5xx Server Side Error' - gracefully handling error - error message already logged
				return;
			}
		}
		
		Item item;
		if (!itemdb.selectByPath(path, defaultDriveId, item)) {
			// this is odd .. this directory is not in the local database - just go delete it
			log.vlog("The requested directory to delete was not found in the local database - pushing delete request direct to OneDrive");
			uploadDeleteItem(item, path);
		} else {
			// the folder was in the local database
			// Handle the deletion and saving any update to the local database
			log.vlog("The requested directory to delete was found in the local database. Processing the deletion normally");
			deleteByPath(path);
		}
	}
	
	// rename a directory on OneDrive without syncing
	auto renameDirectoryNoSync(string source, string destination)
	{
		try {
			// test if the local path exists on OneDrive
			onedrive.getPathDetails(source);
		} catch (OneDriveException e) {
			log.vdebug("onedrive.getPathDetails(source); generated a OneDriveException");
			if (e.httpStatusCode == 404) {
				// The directory was not found 
				log.vlog("The requested directory to rename was not found on OneDrive");
				return;
			}
			
			if (e.httpStatusCode == 429) {
				// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
				handleOneDriveThrottleRequest();
				// Retry original request by calling function again to avoid replicating any further error handling
				log.vdebug("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - calling renameDirectoryNoSync(source, destination);");
				renameDirectoryNoSync(source, destination);
				// return back to original call
				return;
			}
			
			if (e.httpStatusCode >= 500) {
				// OneDrive returned a 'HTTP 5xx Server Side Error' - gracefully handling error - error message already logged
				return;
			}
		}
		// The OneDrive API returned a 200 OK status, so the folder exists
		// Rename the requested directory on OneDrive without performing a sync
		moveByPath(source, destination);
	}
	
	// download the new changes of a specific item
	// id is the root of the drive or a shared folder
	private void applyDifferences(string driveId, const(char)[] id, bool performFullItemScan)
	{
		log.vlog("Applying changes of Path ID: " ~ id);
		// function variables
		const(char)[] idToQuery;
		JSONValue changes;
		JSONValue changesAvailable;
		JSONValue idDetails;
		string syncFolderName;
		string syncFolderPath;
		string syncFolderChildPath;
		string deltaLink;
		string deltaLinkAvailable;
		bool nationalCloudChildrenScan = false;
		
		// Query the name of this folder id
		try {
			idDetails = onedrive.getPathDetailsById(driveId, id);
		} catch (OneDriveException e) {
			log.vdebug("idDetails = onedrive.getPathDetailsById(driveId, id) generated a OneDriveException");
			if (e.httpStatusCode == 404) {
				// id was not found - possibly a remote (shared) folder
				log.vlog("No details returned for given Path ID");
				return;
			}
			
			if (e.httpStatusCode == 429) {
				// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
				handleOneDriveThrottleRequest();
				// Retry original request by calling function again to avoid replicating any further error handling
				log.vdebug("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - calling applyDifferences(driveId, id, performFullItemScan);");
				applyDifferences(driveId, id, performFullItemScan);
				// return back to original call
				return;
			}
			
			if (e.httpStatusCode >= 500) {
				// OneDrive returned a 'HTTP 5xx Server Side Error' - gracefully handling error - error message already logged
				return;
			}
		} 
		
		// validate that idDetails is a JSON value
		if (idDetails.type() == JSONType.object) {
			// Get the name of this 'Path ID'
			if (("id" in idDetails) != null) {
				// valid response from onedrive.getPathDetailsById(driveId, id) - a JSON item object present
				if ((idDetails["id"].str == id) && (!isItemFile(idDetails))){
					// Is a Folder or Remote Folder
					syncFolderName = idDetails["name"].str;
				}
				
				// Debug output of path details as queried from OneDrive
				log.vdebug("OneDrive Path Details: ", idDetails);
							
				// OneDrive Personal Folder Item Reference (24/4/2019)
				//	"@odata.context": "https://graph.microsoft.com/v1.0/$metadata#drives('66d53be8a5056eca')/items/$entity",
				//	"cTag": "adDo2NkQ1M0JFOEE1MDU2RUNBITEwMS42MzY5MTY5NjQ1ODcwNzAwMDA",
				//	"eTag": "aNjZENTNCRThBNTA1NkVDQSExMDEuMQ",
				//	"fileSystemInfo": {
				//		"createdDateTime": "2018-06-06T20:45:24.436Z",
				//		"lastModifiedDateTime": "2019-04-24T07:09:31.29Z"
				//	},
				//	"folder": {
				//		"childCount": 3,
				//		"view": {
				//			"sortBy": "takenOrCreatedDateTime",
				//			"sortOrder": "ascending",
				//			"viewType": "thumbnails"
				//		}
				//	},
				//	"id": "66D53BE8A5056ECA!101",
				//	"name": "root",
				//	"parentReference": {
				//		"driveId": "66d53be8a5056eca",
				//		"driveType": "personal"
				//	},
				//	"root": {},
				//	"size": 0
			
				// OneDrive Personal Remote / Shared Folder Item Reference (4/9/2019)
				//	"@odata.context": "https://graph.microsoft.com/v1.0/$metadata#drives('driveId')/items/$entity",
				//	"cTag": "cTag",
				//	"eTag": "eTag",
				//	"id": "itemId",
				//	"name": "shared",
				//	"parentReference": {
				//		"driveId": "driveId",
				//		"driveType": "personal",
				//		"id": "parentItemId",
				//		"path": "/drive/root:"
				//	},
				//	"remoteItem": {
				//		"fileSystemInfo": {
				//			"createdDateTime": "2019-01-14T18:54:43.2666667Z",
				//			"lastModifiedDateTime": "2019-04-24T03:47:22.53Z"
				//		},
				//		"folder": {
				//			"childCount": 0,
				//			"view": {
				//				"sortBy": "takenOrCreatedDateTime",
				//				"sortOrder": "ascending",
				//				"viewType": "thumbnails"
				//			}
				//		},
				//		"id": "remoteItemId",
				//		"parentReference": {
				//			"driveId": "remoteDriveId",
				//			"driveType": "personal"
				//			"id": "id",
				//			"name": "name",
				//			"path": "/drives/<remote_drive_id>/items/<remote_parent_id>:/<parent_name>"
				//		},
				//		"size": 0,
				//		"webUrl": "webUrl"
				//	}
				
				// OneDrive Business Folder & Shared Folder Item Reference (24/4/2019)
				//	"@odata.context": "https://graph.microsoft.com/v1.0/$metadata#drives('driveId')/items/$entity",
				//	"@odata.etag": "\"{eTag},1\"",
				//	"cTag": "\"c:{cTag},0\"",
				//	"eTag": "\"{eTag},1\"",
				//	"fileSystemInfo": {
				//		"createdDateTime": "2019-04-17T04:00:43Z",
				//		"lastModifiedDateTime": "2019-04-17T04:00:43Z"
				//	},
				//	"folder": {
				//		"childCount": 2
				//	},
				//	"id": "itemId",
				//	"name": "shared_folder",
				//	"parentReference": {
				//		"driveId": "parentDriveId",
				//		"driveType": "business",
				//		"id": "parentId",
				//		"path": "/drives/driveId/root:"
				//	},
				//	"size": 0
				
				// To evaluate a change received from OneDrive, this must be set correctly
				if (hasParentReferencePath(idDetails)) {
					// Path from OneDrive has a parentReference we can use
					log.vdebug("Item details returned contains parent reference path - potentially shared folder object");
					syncFolderPath = idDetails["parentReference"]["path"].str;
					syncFolderChildPath = syncFolderPath ~ "/" ~ idDetails["name"].str ~ "/";
				} else {
					// No parentReference, set these to blank
					log.vdebug("Item details returned no parent reference path");
					syncFolderPath = "";
					syncFolderChildPath = ""; 
				}
				
				// Debug Output
				log.vdebug("Sync Folder Name:        ", syncFolderName);
				log.vdebug("Sync Folder Parent Path: ", syncFolderPath);
				log.vdebug("Sync Folder Child Path:  ", syncFolderChildPath);
			}
		} else {
			// Log that an invalid JSON object was returned
			log.vdebug("onedrive.getPathDetailsById call returned an invalid JSON Object");
		}
		
		// Issue #658
		// If we are using a sync_list file, using deltaLink will actually 'miss' changes (moves & deletes) on OneDrive as using sync_list discards changes
		// Use the performFullItemScan boolean to control whether we perform a full object scan of use the delta link for the root folder
		// When using --synchronize the normal process order is:
		//   1. Scan OneDrive for changes
		//   2. Scan local folder for changes
		//   3. Scan OneDrive for changes
		// When using sync_list and performing a full scan, what this means is a full scan is performed twice, which leads to massive processing & time overheads 
		// Control this via performFullItemScan
		
		// Get the current delta link
		deltaLinkAvailable = itemdb.getDeltaLink(driveId, id);
		// if sync_list is not configured, syncListConfigured should be false
		log.vdebug("syncListConfigured = ", syncListConfigured);
		// oneDriveFullScanTrigger should be false unless set by actions on OneDrive and only if sync_list or skip_dir is used
		log.vdebug("oneDriveFullScanTrigger = ", oneDriveFullScanTrigger);
		// should only be set if 10th scan in monitor mode or as final true up sync in stand alone mode
		log.vdebug("performFullItemScan = ", performFullItemScan);
				
		// do we override performFullItemScan if it is currently false and oneDriveFullScanTrigger is true?
		if ((!performFullItemScan) && (oneDriveFullScanTrigger)) {
			// forcing a full scan earlier than potentially normal
			// oneDriveFullScanTrigger = true due to new folder creation request in a location that is now in-scope which was previously out of scope
			performFullItemScan = true;
			log.vdebug("overriding performFullItemScan as oneDriveFullScanTrigger was set");
		}
		
		// depending on the scan type (--monitor or --synchronize) performFullItemScan is set depending on the number of sync passes performed (--monitor) or ALWAYS if just --synchronize is used
		if (!performFullItemScan){
			// performFullItemScan == false
			// use delta link
			log.vdebug("performFullItemScan is false, using the deltaLink as per database entry");
			if (deltaLinkAvailable == ""){
				deltaLink = "";
				log.vdebug("deltaLink was requested to be used, but contains no data - resulting API query will be treated as a full scan of OneDrive");
			} else {
				deltaLink = deltaLinkAvailable;
				log.vdebug("deltaLink contains valid data - resulting API query will be treated as a delta scan of OneDrive");
			}
		} else {
			// performFullItemScan == true
			// do not use delta-link
			deltaLink = "";
			log.vdebug("performFullItemScan is true, not using the database deltaLink so that we query all objects on OneDrive to compare against all local objects");
		}
		
		for (;;) {
			// Due to differences in OneDrive API's between personal and business we need to get changes only from defaultRootId
			// If we used the 'id' passed in & when using --single-directory with a business account we get:
			//	'HTTP request returned status code 501 (Not Implemented): view.delta can only be called on the root.'
			// To view changes correctly, we need to use the correct path id for the request
			if (driveId == defaultDriveId) {
				// The drive id matches our users default drive id
				idToQuery = defaultRootId.dup;
			} else {
				// The drive id does not match our users default drive id
				// Potentially the 'path id' we are requesting the details of is a Shared Folder (remote item)
				// Use the 'id' that was passed in (folderId)
				idToQuery = id;
			}
			// what path id are we going to query?
			log.vdebug("path idToQuery = ", idToQuery);
			long deltaChanges = 0;
			
			// What query do we use?
			// National Cloud Deployments (US and DE) do not support /delta as a query
			// https://docs.microsoft.com/en-us/graph/deployments#supported-features
			// Are we running against a National Cloud Deployments that does not support /delta
			if ((nationalCloudDeployment) || ((driveId!= defaultDriveId) && (syncBusinessFolders))) {
				// Have to query /children rather than /delta
				nationalCloudChildrenScan = true;
				log.vdebug("Using /children call to query drive for items");
				// In OneDrive Business Shared Folder scenario, if ALL items are downgraded, then this leads to local file deletion
				// Downgrade ONLY files associated with this driveId and idToQuery
				log.vdebug("Downgrading all children for this driveId (" ~ driveId ~ ") and idToQuery (" ~ idToQuery ~ ") to an out-of-sync state");
				// Before we get any data, flag any object in the database as out-of-sync for this driveID & ID
				auto drivePathChildren = itemdb.selectChildren(driveId, idToQuery);
				if (count(drivePathChildren) > 0) {
					// Children to process and flag as out-of-sync	
					foreach (drivePathChild; drivePathChildren) {
						// Flag any object in the database as out-of-sync for this driveID & ID
						itemdb.downgradeSyncStatusFlag(drivePathChild.driveId, drivePathChild.id);
					}
				}
				
				// Build own 'changes' response
				try {
					// we have to 'build' our own JSON response that looks like /delta
					changes = generateDeltaResponse(driveId, idToQuery);
					if (changes.type() == JSONType.object) {
						log.vdebug("Query 'changes = generateDeltaResponse(driveId, idToQuery)' performed successfully");
					}
				} catch (OneDriveException e) {
					// OneDrive threw an error
					log.vdebug("------------------------------------------------------------------");
					log.vdebug("Query Error: changes = generateDeltaResponse(driveId, idToQuery)");
					log.vdebug("driveId: ", driveId);
					log.vdebug("idToQuery: ", idToQuery);
					
					// HTTP request returned status code 404 (Not Found)
					if (e.httpStatusCode == 404) {
						// Stop application
						log.log("\n\nOneDrive returned a 'HTTP 404 - Item not found'");
						log.log("The item id to query was not found on OneDrive");
						log.log("\nRemove your '", cfg.databaseFilePath, "' file and try to sync again\n");
						return;
					}
					
					// HTTP request returned status code 429 (Too Many Requests)
					if (e.httpStatusCode == 429) {
						// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
						handleOneDriveThrottleRequest();
						log.vdebug("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - attempting to query OneDrive drive items");
					}
					
					// HTTP request returned status code 500 (Internal Server Error)
					if (e.httpStatusCode == 500) {
						// display what the error is
						displayOneDriveErrorMessage(e.msg);
						return;
					}
					
					// HTTP request returned status code 504 (Gateway Timeout) or 429 retry
					if ((e.httpStatusCode == 429) || (e.httpStatusCode == 504)) {
						// If an error is returned when querying 'changes' and we recall the original function, we go into a never ending loop where the sync never ends
						// re-try the specific changes queries	
						if (e.httpStatusCode == 504) {
							log.log("OneDrive returned a 'HTTP 504 - Gateway Timeout' when attempting to query OneDrive drive items - retrying applicable request");
							log.vdebug("changes = generateDeltaResponse(driveId, idToQuery) previously threw an error - retrying");
							// The server, while acting as a proxy, did not receive a timely response from the upstream server it needed to access in attempting to complete the request. 
							log.vdebug("Thread sleeping for 30 seconds as the server did not receive a timely response from the upstream server it needed to access in attempting to complete the request");
							Thread.sleep(dur!"seconds"(30));
							log.vdebug("Retrying Query - using original deltaLink after delay");
						}
						// re-try original request - retried for 429 and 504
						try {
							log.vdebug("Retrying Query: changes = generateDeltaResponse(driveId, idToQuery)");
							changes = generateDeltaResponse(driveId, idToQuery);
							log.vdebug("Query 'changes = generateDeltaResponse(driveId, idToQuery)' performed successfully on re-try");
						} catch (OneDriveException e) {
							// display what the error is
							log.vdebug("Query Error: changes = generateDeltaResponse(driveId, idToQuery) on re-try after delay");
							// error was not a 504 this time
							displayOneDriveErrorMessage(e.msg);
							return;
						}
					} else {
						// Default operation if not 404, 410, 429, 500 or 504 errors
						// display what the error is
						displayOneDriveErrorMessage(e.msg);
						return;
					}
				}
			} else {
				log.vdebug("Using /delta call to query drive for items");
			
				// query for changes = onedrive.viewChangesByItemId(driveId, idToQuery, deltaLink);
				try {
					// Fetch the changes relative to the path id we want to query
					// changes with or without deltaLink
					changes = onedrive.viewChangesByItemId(driveId, idToQuery, deltaLink);
					if (changes.type() == JSONType.object) {
						log.vdebug("Query 'changes = onedrive.viewChangesByItemId(driveId, idToQuery, deltaLink)' performed successfully");
					}
				} catch (OneDriveException e) {
					// OneDrive threw an error
					log.vdebug("------------------------------------------------------------------");
					log.vdebug("Query Error: changes = onedrive.viewChangesByItemId(driveId, idToQuery, deltaLink)");
					log.vdebug("driveId: ", driveId);
					log.vdebug("idToQuery: ", idToQuery);
					log.vdebug("deltaLink: ", deltaLink);
					
					// HTTP request returned status code 404 (Not Found)
					if (e.httpStatusCode == 404) {
						// Stop application
						log.log("\n\nOneDrive returned a 'HTTP 404 - Item not found'");
						log.log("The item id to query was not found on OneDrive");
						log.log("\nRemove your '", cfg.databaseFilePath, "' file and try to sync again\n");
						return;
					}
					
					// HTTP request returned status code 410 (The requested resource is no longer available at the server)
					if (e.httpStatusCode == 410) {
						log.vdebug("Delta link expired for 'onedrive.viewChangesByItemId(driveId, idToQuery, deltaLink)', setting 'deltaLink = null'");
						deltaLink = null;
						continue;
					}
					
					// HTTP request returned status code 429 (Too Many Requests)
					if (e.httpStatusCode == 429) {
						// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
						handleOneDriveThrottleRequest();
						log.vdebug("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - attempting to query changes from OneDrive using deltaLink");
					}
					
					// HTTP request returned status code 500 (Internal Server Error)
					if (e.httpStatusCode == 500) {
						// display what the error is
						displayOneDriveErrorMessage(e.msg);
						return;
					}
					
					// HTTP request returned status code 504 (Gateway Timeout) or 429 retry
					if ((e.httpStatusCode == 429) || (e.httpStatusCode == 504)) {
						// If an error is returned when querying 'changes' and we recall the original function, we go into a never ending loop where the sync never ends
						// re-try the specific changes queries	
						if (e.httpStatusCode == 504) {
							log.log("OneDrive returned a 'HTTP 504 - Gateway Timeout' when attempting to query for changes - retrying applicable request");
							log.vdebug("changes = onedrive.viewChangesByItemId(driveId, idToQuery, deltaLink) previously threw an error - retrying");
							// The server, while acting as a proxy, did not receive a timely response from the upstream server it needed to access in attempting to complete the request. 
							log.vdebug("Thread sleeping for 30 seconds as the server did not receive a timely response from the upstream server it needed to access in attempting to complete the request");
							Thread.sleep(dur!"seconds"(30));
							log.vdebug("Retrying Query - using original deltaLink after delay");
						}
						// re-try original request - retried for 429 and 504
						try {
							log.vdebug("Retrying Query: changes = onedrive.viewChangesByItemId(driveId, idToQuery, deltaLink)");
							changes = onedrive.viewChangesByItemId(driveId, idToQuery, deltaLink);
							log.vdebug("Query 'changes = onedrive.viewChangesByItemId(driveId, idToQuery, deltaLink)' performed successfully on re-try");
						} catch (OneDriveException e) {
							// display what the error is
							log.vdebug("Query Error: changes = onedrive.viewChangesByItemId(driveId, idToQuery, deltaLink) on re-try after delay");
							if (e.httpStatusCode == 504) {
								log.log("OneDrive returned a 'HTTP 504 - Gateway Timeout' when attempting to query for changes - retrying applicable request");
								log.vdebug("changes = onedrive.viewChangesByItemId(driveId, idToQuery, deltaLink) previously threw an error - retrying with empty deltaLink");
								try {
									// try query with empty deltaLink value
									deltaLink = null;
									changes = onedrive.viewChangesByItemId(driveId, idToQuery, deltaLink);
									log.vdebug("Query 'changes = onedrive.viewChangesByItemId(driveId, idToQuery, deltaLink)' performed successfully on re-try");
								} catch (OneDriveException e) {
									// Tried 3 times, give up
									displayOneDriveErrorMessage(e.msg);
									return;
								}
							} else {
								// error was not a 504 this time
								displayOneDriveErrorMessage(e.msg);
								return;
							}
						}
					} else {
						// Default operation if not 404, 410, 429, 500 or 504 errors
						// display what the error is
						displayOneDriveErrorMessage(e.msg);
						return;
					}
				}
				
				// query for changesAvailable = onedrive.viewChangesByItemId(driveId, idToQuery, deltaLinkAvailable);
				try {
					// Fetch the changes relative to the path id we want to query
					// changes based on deltaLink
					changesAvailable = onedrive.viewChangesByItemId(driveId, idToQuery, deltaLinkAvailable);
					if (changesAvailable.type() == JSONType.object) {
						log.vdebug("Query 'changesAvailable = onedrive.viewChangesByItemId(driveId, idToQuery, deltaLinkAvailable)' performed successfully");
						// are there any delta changes?
						if (("value" in changesAvailable) != null) {
							deltaChanges = count(changesAvailable["value"].array);
							log.vdebug("changesAvailable query reports that there are " , deltaChanges , " changes that need processing on OneDrive");
						}
					}
				} catch (OneDriveException e) {
					// OneDrive threw an error
					log.vdebug("------------------------------------------------------------------");
					log.vdebug("Query Error: changesAvailable = onedrive.viewChangesByItemId(driveId, idToQuery, deltaLinkAvailable)");
					log.vdebug("driveId: ", driveId);
					log.vdebug("idToQuery: ", idToQuery);
					log.vdebug("deltaLinkAvailable: ", deltaLinkAvailable);
					
					// HTTP request returned status code 404 (Not Found)
					if (e.httpStatusCode == 404) {
						// Stop application
						log.log("\n\nOneDrive returned a 'HTTP 404 - Item not found'");
						log.log("The item id to query was not found on OneDrive");
						log.log("\nRemove your '", cfg.databaseFilePath, "' file and try to sync again\n");
						return;
					}
					
					// HTTP request returned status code 410 (The requested resource is no longer available at the server)
					if (e.httpStatusCode == 410) {
						log.vdebug("Delta link expired for 'onedrive.viewChangesByItemId(driveId, idToQuery, deltaLinkAvailable)', setting 'deltaLinkAvailable = null'");
						deltaLinkAvailable = null;
						continue;
					}
					
					// HTTP request returned status code 429 (Too Many Requests)
					if (e.httpStatusCode == 429) {
						// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
						handleOneDriveThrottleRequest();
						log.vdebug("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - attempting to query changes from OneDrive using deltaLinkAvailable");
					}
					
					// HTTP request returned status code 500 (Internal Server Error)
					if (e.httpStatusCode == 500) {
						// display what the error is
						displayOneDriveErrorMessage(e.msg);
						return;
					}
					
					// HTTP request returned status code 504 (Gateway Timeout) or 429 retry
					if ((e.httpStatusCode == 429) || (e.httpStatusCode == 504)) {
						// If an error is returned when querying 'changes' and we recall the original function, we go into a never ending loop where the sync never ends
						// re-try the specific changes queries	
						if (e.httpStatusCode == 504) {
							log.log("OneDrive returned a 'HTTP 504 - Gateway Timeout' when attempting to query for changes - retrying applicable request");
							log.vdebug("changesAvailable = onedrive.viewChangesByItemId(driveId, idToQuery, deltaLinkAvailable) previously threw an error - retrying");
							// The server, while acting as a proxy, did not receive a timely response from the upstream server it needed to access in attempting to complete the request. 
							log.vdebug("Thread sleeping for 30 seconds as the server did not receive a timely response from the upstream server it needed to access in attempting to complete the request");
							Thread.sleep(dur!"seconds"(30));
							log.vdebug("Retrying Query - using original deltaLinkAvailable after delay");
						}
						// re-try original request - retried for 429 and 504
						try {
							log.vdebug("Retrying Query: changesAvailable = onedrive.viewChangesByItemId(driveId, idToQuery, deltaLinkAvailable)");
							changesAvailable = onedrive.viewChangesByItemId(driveId, idToQuery, deltaLinkAvailable);
							log.vdebug("Query 'changesAvailable = onedrive.viewChangesByItemId(driveId, idToQuery, deltaLinkAvailable)' performed successfully on re-try");
						} catch (OneDriveException e) {
							// display what the error is
							log.vdebug("Query Error: changesAvailable = onedrive.viewChangesByItemId(driveId, idToQuery, deltaLinkAvailable) on re-try after delay");
							if (e.httpStatusCode == 504) {
								log.log("OneDrive returned a 'HTTP 504 - Gateway Timeout' when attempting to query for changes - retrying applicable request");
								log.vdebug("changesAvailable = onedrive.viewChangesByItemId(driveId, idToQuery, deltaLinkAvailable) previously threw an error - retrying with empty deltaLinkAvailable");
								try {
									// try query with empty deltaLinkAvailable value
									deltaLinkAvailable = null;
									changesAvailable = onedrive.viewChangesByItemId(driveId, idToQuery, deltaLinkAvailable);
									log.vdebug("Query 'changesAvailable = onedrive.viewChangesByItemId(driveId, idToQuery, deltaLinkAvailable)' performed successfully on re-try");
								} catch (OneDriveException e) {
									// Tried 3 times, give up
									displayOneDriveErrorMessage(e.msg);
									return;
								}
							} else {
								// error was not a 504 this time
								displayOneDriveErrorMessage(e.msg);
								return;
							}
						}
					} else {
						// Default operation if not 404, 410, 429, 500 or 504 errors
						// display what the error is
						displayOneDriveErrorMessage(e.msg);
						return;
					}
				}
			}
			
			// is changes a valid JSON response
			if (changes.type() == JSONType.object) {
				// Are there any changes to process?
				if ((("value" in changes) != null) && ((deltaChanges > 0) || (oneDriveFullScanTrigger) || (nationalCloudChildrenScan) || (syncBusinessFolders) )) {
					auto nrChanges = count(changes["value"].array);
					auto changeCount = 0;
					
					// Display the number of changes or OneDrive objects we are processing
					// OneDrive ships 'changes' in ~200 bundles. We display that we are processing X number of objects
					// Do not display anything unless we are doing a verbose debug as due to #658 we are essentially doing a --resync each time when using sync_list
					
					// is nrChanges >= min_notify_changes (default of min_notify_changes = 5)
					if (nrChanges >= cfg.getValueLong("min_notify_changes")) {
						// nrChanges is >= than min_notify_changes
						// verbose log, no 'notify' .. it is over the top
						if (!syncListConfigured) {
							// sync_list is not being used - lets use the right messaging here
							if (oneDriveFullScanTrigger) {
								// full scan was triggered out of cycle
								log.vlog("Processing ", nrChanges, " OneDrive items to ensure consistent local state due to a full scan being triggered by actions on OneDrive");
								// unset now the full scan trigger if set
								unsetOneDriveFullScanTrigger();
							} else {
								// no sync_list in use, oneDriveFullScanTrigger not set via sync_list or skip_dir 
								if (performFullItemScan){
									// performFullItemScan was set
									log.vlog("Processing ", nrChanges, " OneDrive items to ensure consistent local state due to a full scan being requested");
								} else {
									// default processing message
									log.vlog("Processing ", nrChanges, " OneDrive items to ensure consistent local state");
								}
							}
						} else {
							// sync_list is being used - why are we going through the entire OneDrive contents?
							log.vlog("Processing ", nrChanges, " OneDrive items to ensure consistent local state due to sync_list being used");
						}
					} else {
						// There are valid changes but less than the min_notify_changes configured threshold
						// We will only output the number of changes being processed to debug log if this is set to assist with debugging
						// As this is debug logging, messaging can be the same, regardless of sync_list being used or not
						
						// is performFullItemScan set due to a full scan required?
						// is oneDriveFullScanTrigger set due to a potentially out-of-scope item now being in-scope
						if ((performFullItemScan) || (oneDriveFullScanTrigger)) {
							// oneDriveFullScanTrigger should be false unless set by actions on OneDrive and only if sync_list or skip_dir is used
							log.vdebug("performFullItemScan or oneDriveFullScanTrigger = true");
							// full scan was requested or triggered
							// use the right message
							if (oneDriveFullScanTrigger) {
								log.vlog("Processing ", nrChanges, " OneDrive items to ensure consistent local state due to a full scan being triggered by actions on OneDrive");
								// unset now the full scan trigger if set
								unsetOneDriveFullScanTrigger();
							} else {
								log.vlog("Processing ", nrChanges, " OneDrive items to ensure consistent local state due to a full scan being requested");
							}
						} else {
							// standard message
							log.vlog("Number of items from OneDrive to process: ", nrChanges);
						}
					}

					foreach (item; changes["value"].array) {
						bool isRoot = false;
						string thisItemPath;
						changeCount++;
						
						// Change as reported by OneDrive
						log.vdebug("------------------------------------------------------------------");
						log.vdebug("Processing change ", changeCount, " of ", nrChanges);
						log.vdebug("OneDrive Change: ", item);
						
						// Deleted items returned from onedrive.viewChangesByItemId or onedrive.viewChangesByDriveId (/delta) do not have a 'name' attribute
						// Thus we cannot name check for 'root' below on deleted items
						if(!isItemDeleted(item)){
							// This is not a deleted item
							log.vdebug("Not a OneDrive deleted item change");
							// Test is this is the OneDrive Users Root?
							// Debug output of change evaluation items
							log.vdebug("defaultRootId                                        = ", defaultRootId);
							log.vdebug("'search id'                                          = ", id);
							log.vdebug("id == defaultRootId                                  = ", (id == defaultRootId));
							log.vdebug("isItemRoot(item)                                     = ", (isItemRoot(item)));
							log.vdebug("item['name'].str == 'root'                           = ", (item["name"].str == "root"));
							log.vdebug("singleDirectoryScope                                 = ", (singleDirectoryScope));
							
							// Use the global's as initialised via init() rather than performing unnecessary additional HTTPS calls
							// In a --single-directory scenario however, '(id == defaultRootId) = false' for root items
							if ( ((id == defaultRootId) || (singleDirectoryScope)) && (isItemRoot(item)) && (item["name"].str == "root")) { 
								// This IS a OneDrive Root item
								log.vdebug("Change will flagged as a 'root' item change");
								isRoot = true;
							}
						}

						// How do we handle this change?
						if (isRoot || !hasParentReferenceId(item) || isItemDeleted(item)){
							// Is a root item, has no id in parentReference or is a OneDrive deleted item
							log.vdebug("isRoot                                               = ", isRoot);
							log.vdebug("!hasParentReferenceId(item)                          = ", (!hasParentReferenceId(item)));
							log.vdebug("isItemDeleted(item)                                  = ", (isItemDeleted(item)));
							log.vdebug("Handling change as 'root item', has no parent reference or is a deleted item");
							applyDifference(item, driveId, isRoot);
						} else {
							// What is this item's path?
							if (hasParentReferencePath(item)) {
								thisItemPath = item["parentReference"]["path"].str;
							} else {
								thisItemPath = "";
							}
							
							// Business Shared Folders special case handling
							bool sharedFoldersSpecialCase = false;
							
							// Debug output of change evaluation items
							log.vdebug("'parentReference id'                                 = ", item["parentReference"]["id"].str);
							log.vdebug("syncFolderName                                       = ", syncFolderName);
							log.vdebug("syncFolderPath                                       = ", syncFolderPath);
							log.vdebug("syncFolderChildPath                                  = ", syncFolderChildPath);
							log.vdebug("thisItemId                                           = ", item["id"].str);
							log.vdebug("thisItemPath                                         = ", thisItemPath);
							log.vdebug("'item id' matches search 'id'                        = ", (item["id"].str == id));
							log.vdebug("'parentReference id' matches search 'id'             = ", (item["parentReference"]["id"].str == id));
							log.vdebug("'thisItemPath' contains 'syncFolderChildPath'        = ", (canFind(thisItemPath, syncFolderChildPath)) );
							log.vdebug("'thisItemPath' contains search 'id'                  = ", (canFind(thisItemPath, id)) );
							
							// Special case handling
							// - IF we are syncing shared folders, and the shared folder is not the 'top level' folder being shared out
							// canFind(thisItemPath, syncFolderChildPath) will never match:
							//		Syncing this OneDrive Business Shared Folder: MyFolderName
							//		OneDrive Business Shared By:                  Firstname Lastname (email@address)
							//		Applying changes of Path ID:    pathId
							//		[DEBUG] Sync Folder Name:       MyFolderName
							//		[DEBUG] Sync Folder Path:       /drives/driveId/root:/TopLevel/ABCD
							//		[DEBUG] Sync Folder Child Path: /drives/driveId/root:/TopLevel/ABCD/MyFolderName/
							//		...
							//		[DEBUG] 'item id' matches search 'id'                        = false
							//		[DEBUG] 'parentReference id' matches search 'id'             = false
							//		[DEBUG] 'thisItemPath' contains 'syncFolderChildPath'        = false
							//		[DEBUG] 'thisItemPath' contains search 'id'                  = false
							//		[DEBUG] Change does not match any criteria to apply
							//		Remote change discarded - not in business shared folders sync scope
							
							if ((!canFind(thisItemPath, syncFolderChildPath)) && (syncBusinessFolders)) {
								// Syncing Shared Business folders & we dont have a path match
								// is this a reverse path match?
								log.vdebug("'thisItemPath' contains 'syncFolderName'             = ", (canFind(thisItemPath, syncFolderName)) );
								if (canFind(thisItemPath, syncFolderName)) {
									sharedFoldersSpecialCase = true;
								}
							}
							
							// Check this item's path to see if this is a change on the path we want:
							// 1. 'item id' matches 'id'
							// 2. 'parentReference id' matches 'id'
							// 3. 'item path' contains 'syncFolderChildPath'
							// 4. 'item path' contains 'id'
							
							if ( (item["id"].str == id) || (item["parentReference"]["id"].str == id) || (canFind(thisItemPath, syncFolderChildPath)) || (canFind(thisItemPath, id)) || (sharedFoldersSpecialCase) ){
								// This is a change we want to apply
								if (!sharedFoldersSpecialCase) {
									log.vdebug("Change matches search criteria to apply");
								} else {
									log.vdebug("Change matches search criteria to apply - special case criteria - reverse path matching used");
								}
								// Apply OneDrive change
								applyDifference(item, driveId, isRoot);
							} else {
								// No item ID match or folder sync match
								log.vdebug("Change does not match any criteria to apply");
								// Before discarding change - does this ID still exist on OneDrive - as in IS this 
								// potentially a --single-directory sync and the user 'moved' the file out of the 'sync-dir' to another OneDrive folder
								// This is a corner edge case - https://github.com/skilion/onedrive/issues/341
								JSONValue oneDriveMovedNotDeleted;
								try {
									oneDriveMovedNotDeleted = onedrive.getPathDetailsById(driveId, item["id"].str);
								} catch (OneDriveException e) {
									log.vdebug("oneDriveMovedNotDeleted = onedrive.getPathDetailsById(driveId, item['id'].str); generated a OneDriveException");
									if (e.httpStatusCode == 404) {
										// No .. that ID is GONE
										log.vlog("Remote change discarded - item cannot be found");
										return;
									}
									
									if (e.httpStatusCode == 429) {
										// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
										handleOneDriveThrottleRequest();
										// Retry request after delay
										log.vdebug("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - calling oneDriveMovedNotDeleted = onedrive.getPathDetailsById(driveId, item['id'].str);");
										try {
											oneDriveMovedNotDeleted = onedrive.getPathDetailsById(driveId, item["id"].str);
										} catch (OneDriveException e) {
											// A further error was generated
											// Rather than retry original function, retry the actual call and replicate error handling
											if (e.httpStatusCode == 404) {
												// No .. that ID is GONE
												log.vlog("Remote change discarded - item cannot be found");
												return;
											} else {
												// not a 404
												displayOneDriveErrorMessage(e.msg);
												return;
											}
										}
									} else {
										// not a 404 or a 429
										displayOneDriveErrorMessage(e.msg);
										return;
									}
								}
								// Yes .. ID is still on OneDrive but elsewhere .... #341 edge case handling
								// What is the original local path for this ID in the database? Does it match 'syncFolderChildPath'
								if (itemdb.idInLocalDatabase(driveId, item["id"].str)){
									// item is in the database
									string originalLocalPath = itemdb.computePath(driveId, item["id"].str);
									if (canFind(originalLocalPath, syncFolderChildPath)){
										// This 'change' relates to an item that WAS in 'syncFolderChildPath' but is now 
										// stored elsewhere on OneDrive - outside the path we are syncing from
										// Remove this item locally as it's local path is now obsolete
										idsToDelete ~= [driveId, item["id"].str];
									} else {
										// out of scope for some other reason
										if (singleDirectoryScope){
											log.vlog("Remote change discarded - not in --single-directory sync scope");
										} else {
											log.vlog("Remote change discarded - not in sync scope");
										}
										log.vdebug("Remote change discarded: ", item); 
									}
								} else {
									// item is not in the database
									if (singleDirectoryScope){
										// We are syncing a single directory, so this is the reason why it is out of scope
										log.vlog("Remote change discarded - not in --single-directory sync scope");
										log.vdebug("Remote change discarded: ", item);
									} else {
										// Not a single directory sync
										if (syncBusinessFolders) {
											// if we are syncing shared business folders, a 'change' may be out of scope as we are not syncing that 'folder'
											// but we are sent all changes from the 'parent root' as we cannot query the 'delta' for this folder
											// as that is a 501 error - not implemented
											log.vlog("Remote change discarded - not in business shared folders sync scope");
											log.vdebug("Remote change discarded: ", item);
										} else {
											// out of scope for some other reason
											log.vlog("Remote change discarded - not in sync scope");
											log.vdebug("Remote change discarded: ", item);
										}
									}
								}
							} 
						}
					}
				} else {
					// No changes reported on OneDrive
					log.vdebug("OneDrive Reported no delta changes - Local path and OneDrive in-sync");
				}
				
				// the response may contain either @odata.deltaLink or @odata.nextLink
				if ("@odata.deltaLink" in changes) {
					deltaLink = changes["@odata.deltaLink"].str;
					log.vdebug("Setting next deltaLink to (@odata.deltaLink): ", deltaLink);
				}
				if (deltaLink != "") {
					// we initialise deltaLink to a blank string - if it is blank, dont update the DB to be empty
					log.vdebug("Updating completed deltaLink in DB to: ", deltaLink); 
					itemdb.setDeltaLink(driveId, id, deltaLink);
				}
				if ("@odata.nextLink" in changes) {
					// Update deltaLink to next changeSet bundle
					deltaLink = changes["@odata.nextLink"].str;
					// Update deltaLinkAvailable to next changeSet bundle to quantify how many changes we have to process
					deltaLinkAvailable = changes["@odata.nextLink"].str;
					log.vdebug("Setting next deltaLink & deltaLinkAvailable to (@odata.nextLink): ", deltaLink);
				}
				else break;
			} else {
				// Log that an invalid JSON object was returned
				if ((driveId == defaultDriveId) || (!syncBusinessFolders)) {
					log.vdebug("onedrive.viewChangesByItemId call returned an invalid JSON Object");
				} else {
					log.vdebug("onedrive.viewChangesByDriveId call returned an invalid JSON Object");
				}
			}
		}
		
		// delete items in idsToDelete
		if (idsToDelete.length > 0) deleteItems();
		// empty the skipped items
		skippedItems.length = 0;
		assumeSafeAppend(skippedItems);
	}

	// process the change of a single DriveItem
	private void applyDifference(JSONValue driveItem, string driveId, bool isRoot)
	{
		// Format the OneDrive change into a consumable object for the database
		Item item = makeItem(driveItem);
		
		// Reset the malwareDetected flag for this item
		malwareDetected = false;
		
		// Reset the downloadFailed flag for this item
		downloadFailed = false;
		
		if(isItemDeleted(driveItem)){
			// Change is to delete an item
			log.vdebug("Remote deleted item");
		} else {
			// Is the change from OneDrive a 'root' item
			// The change should be considered a 'root' item if:
			// 1. Contains a ["root"] element
			// 2. Has no ["parentReference"]["id"] ... #323 & #324 highlighted that this is false as some 'root' shared objects now can have an 'id' element .. OneDrive API change
			// 2. Has no ["parentReference"]["path"]
			// 3. Was detected by an input flag as to be handled as a root item regardless of actual status
			if (isItemRoot(driveItem) || !hasParentReferencePath(driveItem) || isRoot) {
				log.vdebug("Handing a OneDrive 'root' change");
				item.parentId = null; // ensures that it has no parent
				item.driveId = driveId; // HACK: makeItem() cannot set the driveId property of the root
				log.vdebug("Update/Insert local database with item details");
				itemdb.upsert(item);
				log.vdebug("item details: ", item);
				return;
			}
		}

		bool unwanted;
		// Check if the parent id is something we need to skip
		if (skippedItems.find(item.parentId).length != 0) {
			// Potentially need to flag as unwanted
			log.vdebug("Flagging as unwanted: find(item.parentId).length != 0");
			unwanted = true;
			
			// Is this item id in the database?
			if (itemdb.idInLocalDatabase(item.driveId, item.id)){
				// item exists in database, most likely moved out of scope for current client configuration
				log.vdebug("This item was previously synced / seen by the client");				
				if (("name" in driveItem["parentReference"]) != null) {
					// How is this out of scope?
					if (selectiveSync.isPathExcludedViaSyncList(driveItem["parentReference"]["name"].str)) {
						// Previously synced item is now out of scope as it has been moved out of what is included in sync_list
						log.vdebug("This previously synced item is now excluded from being synced due to sync_list exclusion");
					}
					// flag to delete local file as it now is no longer in sync with OneDrive
					log.vdebug("Flagging to delete item locally");
					idsToDelete ~= [item.driveId, item.id];					
				} 
			}
		}
		
		// Check if this is excluded by config option: skip_dir
		if (!unwanted) {
			// Only check path if config is != ""
			if (cfg.getValueString("skip_dir") != "") {
				// Is the item a folder and not a deleted item?
				if ((isItemFolder(driveItem)) && (!isItemDeleted(driveItem))) {
					// work out the 'snippet' path where this folder would be created
					string simplePathToCheck = "";
					string complexPathToCheck = "";
					string matchDisplay = "";
					
					if (hasParentReference(driveItem)) {
						// we need to workout the FULL path for this item
						string parentDriveId = driveItem["parentReference"]["driveId"].str;
						string parentItem = driveItem["parentReference"]["id"].str;
						// simple path
						if (("name" in driveItem["parentReference"]) != null) {
							simplePathToCheck = driveItem["parentReference"]["name"].str ~ "/" ~ driveItem["name"].str;
						} else {
							simplePathToCheck = driveItem["name"].str;
						}
						log.vdebug("skip_dir path to check (simple):  ", simplePathToCheck);
						// complex path
						if (itemdb.idInLocalDatabase(parentDriveId, parentItem)){
							complexPathToCheck = itemdb.computePath(parentDriveId, parentItem) ~ "/" ~ driveItem["name"].str;
							complexPathToCheck = buildNormalizedPath(complexPathToCheck);
						} else {
							log.vdebug("Parent details not in database - unable to compute complex path to check");
						}
						log.vdebug("skip_dir path to check (complex): ", complexPathToCheck);
					} else {
						simplePathToCheck = driveItem["name"].str;
					}
					
					// OK .. what checks are we doing?
					if ((simplePathToCheck != "") && (complexPathToCheck == "")) {
						// just a simple check
						log.vdebug("Performing a simple check only");
						unwanted = selectiveSync.isDirNameExcluded(simplePathToCheck);
					} else {
						// simple and complex
						log.vdebug("Performing a simple & complex path match if required");
						// simple first
						unwanted = selectiveSync.isDirNameExcluded(simplePathToCheck);
						matchDisplay = simplePathToCheck;
						if (!unwanted) {
							log.vdebug("Simple match was false, attempting complex match");
							// simple didnt match, perform a complex check
							unwanted = selectiveSync.isDirNameExcluded(complexPathToCheck);
							matchDisplay = complexPathToCheck;
						}
					}
					
					log.vdebug("Result: ", unwanted);
					if (unwanted) log.vlog("Skipping item - excluded by skip_dir config match: ", matchDisplay);
				}
			}
		}
		
		// Check if this is excluded by config option: skip_file
		if (!unwanted) {
			// Is the item a file and not a deleted item?
			if ((isItemFile(driveItem)) && (!isItemDeleted(driveItem))) {
				log.vdebug("skip_file item to check: ", item.name);
				unwanted = selectiveSync.isFileNameExcluded(item.name);
				log.vdebug("Result: ", unwanted);
				if (unwanted) log.vlog("Skipping item - excluded by skip_file config: ", item.name);
			}
		}

		// check the item type
		string path = "";
		if (!unwanted) {
			if (isItemFile(driveItem)) {
				log.vdebug("The item we are syncing is a file");
			} else if (isItemFolder(driveItem)) {
				log.vdebug("The item we are syncing is a folder");
			} else if (isItemRemote(driveItem)) {
				log.vdebug("The item we are syncing is a remote item");
				assert(isItemFolder(driveItem["remoteItem"]), "The remote item is not a folder");
			} else {
				// Why was this unwanted?
				path = itemdb.computePath(item.driveId, item.parentId) ~ "/" ~ item.name;
				// Microsoft OneNote container objects present as neither folder or file but has file size
				if ((!isItemFile(driveItem)) && (!isItemFolder(driveItem)) && (hasFileSize(driveItem))) {
					// Log that this was skipped as this was a Microsoft OneNote item and unsupported
					log.vlog("The Microsoft OneNote Notebook '", path, "' is not supported by this client");
				} else {
					// Log that this item was skipped as unsupported 
					log.vlog("The OneDrive item '", path, "' is not supported by this client");
				}
				unwanted = true;
				log.vdebug("Flagging as unwanted: item type is not supported");
			}
		}

		// Check if this is included by use of sync_list
		if (!unwanted) {
			// Is the item parent in the local database?
			if (itemdb.idInLocalDatabase(item.driveId, item.parentId)){
				// compute the item path to see if the path is excluded
				path = itemdb.computePath(item.driveId, item.parentId) ~ "/" ~ item.name;
				path = buildNormalizedPath(path);
				if (selectiveSync.isPathExcludedViaSyncList(path)) {
					// selective sync advised to skip, however is this a file and are we configured to upload / download files in the root?
					if ((isItemFile(driveItem)) && (cfg.getValueBool("sync_root_files")) && (rootName(path) == "") ) {
						// This is a file
						// We are configured to sync all files in the root
						// This is a file in the logical root
						unwanted = false;
					} else {
						// path is unwanted
						unwanted = true;
						log.vlog("Skipping item - excluded by sync_list config: ", path);
						// flagging to skip this file now, but does this exist in the DB thus needs to be removed / deleted?
						if (itemdb.idInLocalDatabase(item.driveId, item.id)){
							log.vlog("Flagging item for local delete as item exists in database: ", path);
							// flag to delete
							idsToDelete ~= [item.driveId, item.id];
						}
					}
				}
			} else {
				// Parent not in the database
				// Is the parent a 'folder' from another user? ie - is this a 'shared folder' that has been shared with us?
				if (defaultDriveId == item.driveId){
					// Flagging as unwanted
					log.vdebug("Flagging as unwanted: item.driveId (", item.driveId,"), item.parentId (", item.parentId,") not in local database");
					unwanted = true;
				} else {
					// Edge case as the parent (from another users OneDrive account) will never be in the database
					log.vdebug("The reported parentId is not in the database. This potentially is a shared folder as 'item.driveId' != 'defaultDriveId'. Relevant Details: item.driveId (", item.driveId,"), item.parentId (", item.parentId,")");
					// If we are syncing OneDrive Business Shared Folders, a 'folder' shared with us, has a 'parent' that is not shared with us hence the above message
					// What we need to do is query the DB for this 'item.driveId' and use the response from the DB to set the 'item.parentId' for this new item we are trying to add to the database
					if (syncBusinessFolders) {
						foreach(dbItem; itemdb.selectByDriveId(item.driveId)) {
							if (dbItem.name == "root") {
								// Ensure that this item uses the root id as parent
								log.vdebug("Falsifying item.parentId to be ", dbItem.id);
								item.parentId = dbItem.id;
							}
						}
					} else {
						// Ensure that this item has no parent
						log.vdebug("Setting item.parentId to be null");
						item.parentId = null;
					}
					log.vdebug("Update/Insert local database with item details");
					itemdb.upsert(item);
					log.vdebug("item details: ", item);
					return;
				}
			}
		}
		
		// skip downloading dot files if configured
		if (cfg.getValueBool("skip_dotfiles")) {
			if (isDotFile(path)) {
				log.vlog("Skipping item - .file or .folder: ", path);
				unwanted = true;
			}
		}

		// skip unwanted items early
		if (unwanted) {
			log.vdebug("Skipping OneDrive change as this is determined to be unwanted");
			skippedItems ~= item.id;
			return;
		}

		// check if the item has been seen before
		Item oldItem;
		bool cached = itemdb.selectById(item.driveId, item.id, oldItem);

		// check if the item is going to be deleted
		if (isItemDeleted(driveItem)) {
			// item.name is not available, so we get a bunch of meaningless log output
			// Item name we will attempt to delete will be printed out later
			if (cached) {
				// flag to delete
				log.vdebug("Flagging item for deletion: ", item);
				idsToDelete ~= [item.driveId, item.id];
			} else {
				// flag to ignore
				log.vdebug("Flagging item to skip: ", item);
				skippedItems ~= item.id;
			}
			return;
		}

		// rename the local item if it is unsynced and there is a new version of it on OneDrive
		string oldPath;
		if (cached && item.eTag != oldItem.eTag) {
			// Is the item in the local database
			if (itemdb.idInLocalDatabase(item.driveId, item.id)){
				oldPath = itemdb.computePath(item.driveId, item.id);
				if (!isItemSynced(oldItem, oldPath)) {
					if (exists(oldPath)) {
						// Is the local file technically 'newer' based on UTC timestamp?
						SysTime localModifiedTime = timeLastModified(oldPath).toUTC();
						localModifiedTime.fracSecs = Duration.zero;
						item.mtime.fracSecs = Duration.zero;
						
						if (localModifiedTime > item.mtime) {
							// local file is newer than item on OneDrive
							// no local rename
							// no download needed
							log.vlog("Local item modified time is newer based on UTC time conversion - keeping local item");
							log.vdebug("Skipping OneDrive change as this is determined to be unwanted due to local item modified time being newer than OneDrive item");
							skippedItems ~= item.id;
							return;
						} else {
							// remote file is newer than local item
							log.vlog("Remote item modified time is newer based on UTC time conversion");
							auto ext = extension(oldPath);
							auto newPath = path.chomp(ext) ~ "-" ~ deviceName ~ ext;
							
							// has the user configured to IGNORE local data protection rules?
							if (bypassDataPreservation) {
								// The user has configured to ignore data safety checks and overwrite local data rather than preserve & rename
								log.vlog("WARNING: Local Data Protection has been disabled. You may experience data loss on this file: ", oldPath);
							} else {
								// local data protection is configured, renaming local file
								log.vlog("The local item is out-of-sync with OneDrive, renaming to preserve existing file and prevent data loss: ", oldPath, " -> ", newPath);
								
								// perform the rename action
								if (!dryRun) {
									safeRename(oldPath);
								} else {
									// Expectation here is that there is a new file locally (newPath) however as we don't create this, the "new file" will not be uploaded as it does not exist
									log.vdebug("DRY-RUN: Skipping local file rename");
								}							
							}
						}
					}
					cached = false;
				}
			}
		}

		// update the item
		if (cached) {
			log.vdebug("OneDrive change is an update to an existing local item");
			applyChangedItem(oldItem, oldPath, item, path);
		} else {
			log.vdebug("OneDrive change is a new local item");
			// Check if file should be skipped based on size limit
			if (isItemFile(driveItem)) {
				if (cfg.getValueLong("skip_size") != 0) {
					if (driveItem["size"].integer >= this.newSizeLimit) {
						log.vlog("Skipping item - excluded by skip_size config: ", item.name, " (", driveItem["size"].integer/2^^20, " MB)");
						return;
					}
				}
			}
			applyNewItem(item, path);
		}

		if ((malwareDetected == false) && (downloadFailed == false)){
			// save the item in the db
			// if the file was detected as malware and NOT downloaded, we dont want to falsify the DB as downloading it as otherwise the next pass will think it was deleted, thus delete the remote item
			// Likewise if the download failed, we dont want to falsify the DB as downloading it as otherwise the next pass will think it was deleted, thus delete the remote item 
			if (cached) {
				log.vdebug("Updating local database with item details");
				itemdb.update(item);
			} else {
				log.vdebug("Inserting item details to local database");
				itemdb.insert(item);
			}
			// What was the item that was saved
			log.vdebug("item details: ", item);
		}
	}

	// download an item that was not synced before
	private void applyNewItem(const ref Item item, const(string) path)
	{
		if (exists(path)) {
			// path exists locally
			if (isItemSynced(item, path)) {
				// file details from OneDrive and local file details in database are in-sync
				log.vdebug("The item to sync is already present on the local file system and is in-sync with the local database");
				return;
			} else {
				// file is not in sync with the database
				// is the local file technically 'newer' based on UTC timestamp?
				SysTime localModifiedTime = timeLastModified(path).toUTC();
				SysTime itemModifiedTime = item.mtime;
				// HACK: reduce time resolution to seconds before comparing
				itemModifiedTime.fracSecs = Duration.zero;
				localModifiedTime.fracSecs = Duration.zero;
				
				// is the local modified time greater than that from OneDrive?
				if (localModifiedTime > itemModifiedTime) {
					// local file is newer than item on OneDrive based on file modified time
					// Is this item id in the database?
					if (itemdb.idInLocalDatabase(item.driveId, item.id)){
						// item id is in the database
						// no local rename
						// no download needed
						log.vlog("Local item modified time is newer based on UTC time conversion - keeping local item as this exists in the local database");
						log.vdebug("Skipping OneDrive change as this is determined to be unwanted due to local item modified time being newer than OneDrive item and present in the sqlite database");
						return;
					} else {
						// item id is not in the database .. maybe a --resync ?
						// Should this 'download' be skipped?
						// Do we need to check for .nosync? Only if --check-for-nosync was passed in
						if (cfg.getValueBool("check_nosync")) {
							// need the parent path for this object
							string parentPath = dirName(path);		
							if (exists(parentPath ~ "/.nosync")) {
								log.vlog("Skipping downloading item - .nosync found in parent folder & --check-for-nosync is enabled: ", path);
								// flag that this download failed, otherwise the 'item' is added to the database - then, as not present on the local disk, would get deleted from OneDrive
								downloadFailed = true;
								// clean up this partial file, otherwise every sync we will get theis warning
								log.vlog("Removing previous partial file download due to .nosync found in parent folder & --check-for-nosync is enabled");
								safeRemove(path);
								return;
							}
						}
						// file exists locally but is not in the sqlite database - maybe a failed download?
						log.vlog("Local item does not exist in local database - replacing with file from OneDrive - failed download?");
						
						// was --resync issued?
						if (cfg.getValueBool("resync")) {
							// in a --resync scenario we have zero way of knowing IF the local file is meant to be the right file
							// we have passed the following checks:
							// 1. file exists locally
							// 2. local modified time > remote modified time
							// 3. id is not in the database
							// 4. --resync was issued
							auto ext = extension(path);
							auto newPath = path.chomp(ext) ~ "-" ~ deviceName ~ ext;
							// has the user configured to IGNORE local data protection rules?
							if (bypassDataPreservation) {
								// The user has configured to ignore data safety checks and overwrite local data rather than preserve & rename
								log.vlog("WARNING: Local Data Protection has been disabled. You may experience data loss on this file: ", path);
							} else {
								// local data protection is configured, renaming local file
								log.vlog("The local item is out-of-sync with OneDrive, renaming to preserve existing file and prevent data loss due to --resync: ", path, " -> ", newPath);
								// perform the rename action of the local file
								if (!dryRun) {
									safeRename(path);
								} else {
									// Expectation here is that there is a new file locally (newPath) however as we don't create this, the "new file" will not be uploaded as it does not exist
									log.vdebug("DRY-RUN: Skipping local file rename");
								}
							}
						}
					}
				} else {
					// remote file is newer than local item
					log.vlog("Remote item modified time is newer based on UTC time conversion");
					auto ext = extension(path);
					auto newPath = path.chomp(ext) ~ "-" ~ deviceName ~ ext;
					
					// has the user configured to IGNORE local data protection rules?
					if (bypassDataPreservation) {
						// The user has configured to ignore data safety checks and overwrite local data rather than preserve & rename
						log.vlog("WARNING: Local Data Protection has been disabled. You may experience data loss on this file: ", path);
					} else {
						// local data protection is configured, renaming local file
						log.vlog("The local item is out-of-sync with OneDrive, renaming to preserve existing file and prevent data loss: ", path, " -> ", newPath);
						// perform the rename action of the local file
						if (!dryRun) {
							safeRename(path);
						} else {
							// Expectation here is that there is a new file locally (newPath) however as we don't create this, the "new file" will not be uploaded as it does not exist
							log.vdebug("DRY-RUN: Skipping local file rename");
						}							
					}
				}
			}
		} else {
			// path does not exist locally - this will be a new file download or folder creation
			// Should this 'download' be skipped?
			// Do we need to check for .nosync? Only if --check-for-nosync was passed in
			if (cfg.getValueBool("check_nosync")) {
				// need the parent path for this object
				string parentPath = dirName(path);		
				if (exists(parentPath ~ "/.nosync")) {
					log.vlog("Skipping downloading item - .nosync found in parent folder & --check-for-nosync is enabled: ", path);
					// flag that this download failed, otherwise the 'item' is added to the database - then, as not present on the local disk, would get deleted from OneDrive
					downloadFailed = true;
					return;
				}
			}
		}
		
		// how to handle this item?
		final switch (item.type) {
		case ItemType.file:
			downloadFileItem(item, path);
			if (dryRun) {
				// we dont download the file, but we need to track that we 'faked it'
				idsFaked ~= [item.driveId, item.id];
			}
			break;
		case ItemType.dir:
		case ItemType.remote:
			log.log("Creating local directory: ", path);
			
			// Issue #658 handling - is sync_list in use?
			if (syncListConfigured) {
				// sync_list in use
				// path to create was previously checked if this should be included / excluded. No need to check again.
				log.vdebug("Issue #658 handling");
				setOneDriveFullScanTrigger();
			}
			
			// Issue #865 handling - is skip_dir in use?
			if (cfg.getValueString("skip_dir") != "") {
				// we have some entries in skip_dir
				// path to create was previously checked if this should be included / excluded. No need to check again.
				log.vdebug("Issue #865 handling");
				setOneDriveFullScanTrigger();
			}
			
			if (!dryRun) {
				mkdirRecurse(path);
			} else {
				// we dont create the directory, but we need to track that we 'faked it'
				idsFaked ~= [item.driveId, item.id];
			}
			break;
		}
	}

	// update a local item
	// the local item is assumed to be in sync with the local db
	private void applyChangedItem(Item oldItem, string oldPath, Item newItem, string newPath)
	{
		assert(oldItem.driveId == newItem.driveId);
		assert(oldItem.id == newItem.id);
		assert(oldItem.type == newItem.type);
		assert(oldItem.remoteDriveId == newItem.remoteDriveId);
		assert(oldItem.remoteId == newItem.remoteId);

		if (oldItem.eTag != newItem.eTag) {
			// handle changed name/path
			if (oldPath != newPath) {
				log.log("Moving ", oldPath, " to ", newPath);
				if (exists(newPath)) {
					Item localNewItem;
					if (itemdb.selectByPath(newPath, defaultDriveId, localNewItem)) {
						if (isItemSynced(localNewItem, newPath)) {
							log.vlog("Destination is in sync and will be overwritten");
						} else {
							// TODO: force remote sync by deleting local item
							log.vlog("The destination is occupied, renaming the conflicting file...");
							safeRename(newPath);
						}
					} else {
						// to be overwritten item is not already in the itemdb, so it should
						// be synced. Do a safe rename here, too.
						// TODO: force remote sync by deleting local item
						log.vlog("The destination is occupied by new file, renaming the conflicting file...");
						safeRename(newPath);
					}
				}
				rename(oldPath, newPath);
			}
			// handle changed content and mtime
			// HACK: use mtime+hash instead of cTag because of https://github.com/OneDrive/onedrive-api-docs/issues/765
			if (newItem.type == ItemType.file && oldItem.mtime != newItem.mtime && !testFileHash(newPath, newItem)) {
				downloadFileItem(newItem, newPath);
			} 
			
			// handle changed time
			if (newItem.type == ItemType.file && oldItem.mtime != newItem.mtime) {
				try {
					setTimes(newPath, newItem.mtime, newItem.mtime);
				} catch (FileException e) {
					// display the error message
					displayFileSystemErrorMessage(e.msg);
				}
			}
		} 
	}

	// downloads a File resource
	private void downloadFileItem(const ref Item item, const(string) path)
	{
		assert(item.type == ItemType.file);
		write("Downloading file ", path, " ... ");
		JSONValue fileDetails;
		
		try {
			fileDetails = onedrive.getFileDetails(item.driveId, item.id);
		} catch (OneDriveException e) {
			log.error("ERROR: Query of OneDrive for file details failed");
			if (e.httpStatusCode >= 500) {
				// OneDrive returned a 'HTTP 5xx Server Side Error' - gracefully handling error - error message already logged
				downloadFailed = true;
				return;
			}
		}
		
		// fileDetails has to be a valid JSON object
		if (fileDetails.type() == JSONType.object){
			if (isMalware(fileDetails)){
				// OneDrive reports that this file is malware
				log.error("ERROR: MALWARE DETECTED IN FILE - DOWNLOAD SKIPPED");
				// set global flag
				malwareDetected = true;
				return;
			}
		} else {
			// Issue #550 handling
			log.error("ERROR: Query of OneDrive for file details failed");
			log.vdebug("onedrive.getFileDetails call returned an invalid JSON Object");
			// We want to return, cant download
			downloadFailed = true;
			return;
		}
		
		if (!dryRun) {
			ulong fileSize = 0;
			string OneDriveFileHash;
			
			// fileDetails should be a valid JSON due to prior check
			if (hasFileSize(fileDetails)) {
				// Use the configured filesize as reported by OneDrive
				fileSize = fileDetails["size"].integer;
			} else {
				// filesize missing
				log.vdebug("WARNING: fileDetails['size'] is missing");
			}

			if (hasHashes(fileDetails)) {
				// File details returned hash details
				// QuickXorHash
				if (hasQuickXorHash(fileDetails)) {
					// Use the configured quickXorHash as reported by OneDrive
					if (fileDetails["file"]["hashes"]["quickXorHash"].str != "") {
						OneDriveFileHash = fileDetails["file"]["hashes"]["quickXorHash"].str;
					}
				} 
				// Check for Sha1Hash
				if (hasSha1Hash(fileDetails)) {
					// Use the configured sha1Hash as reported by OneDrive
					if (fileDetails["file"]["hashes"]["sha1Hash"].str != "") {
						OneDriveFileHash = fileDetails["file"]["hashes"]["sha1Hash"].str;
					}
				}
			} else {
				// file hash data missing
				log.vdebug("WARNING: fileDetails['file']['hashes'] is missing - unable to compare file hash after download");
			}
			
			try {
				onedrive.downloadById(item.driveId, item.id, path, fileSize);
			} catch (OneDriveException e) {
				log.vdebug("onedrive.downloadById(item.driveId, item.id, path, fileSize); generated a OneDriveException");
				// 408 = Request Time Out 
				// 429 = Too Many Requests - need to delay
				
				if (e.httpStatusCode == 408) {
					// 408 error handling - request time out
					// https://github.com/abraunegg/onedrive/issues/694
					// Back off & retry with incremental delay
					int retryCount = 10; 
					int retryAttempts = 1;
					int backoffInterval = 2;
					while (retryAttempts < retryCount){
						// retry in 2,4,8,16,32,64,128,256,512,1024 seconds
						Thread.sleep(dur!"seconds"(retryAttempts*backoffInterval));
						try {
							onedrive.downloadById(item.driveId, item.id, path, fileSize);
							// successful download
							retryAttempts = retryCount;
						} catch (OneDriveException e) {
							log.vdebug("onedrive.downloadById(item.driveId, item.id, path, fileSize); generated a OneDriveException");
							if ((e.httpStatusCode == 429) || (e.httpStatusCode == 408)) {
								// If another 408 .. 
								if (e.httpStatusCode == 408) {
									// Increment & loop around
									log.vdebug("HTTP 408 generated - incrementing retryAttempts");
									retryAttempts++;
								}
								// If a 429 ..
								if (e.httpStatusCode == 429) {
									// Increment & loop around
									handleOneDriveThrottleRequest();
									log.vdebug("HTTP 429 generated - incrementing retryAttempts");
									retryAttempts++;
								}
							} else {
								displayOneDriveErrorMessage(e.msg);
							}
						}
					}
				}
			
				if (e.httpStatusCode == 429) {
					// HTTP request returned status code 429 (Too Many Requests)
					// https://github.com/abraunegg/onedrive/issues/133
					int retryCount = 10; 
					int retryAttempts = 1;
					while (retryAttempts < retryCount){
						// retry after waiting the timeout value from the 429 HTTP response header Retry-After
						handleOneDriveThrottleRequest();
						try {
							onedrive.downloadById(item.driveId, item.id, path, fileSize);
							// successful download
							retryAttempts = retryCount;
						} catch (OneDriveException e) {
							log.vdebug("onedrive.downloadById(item.driveId, item.id, path, fileSize); generated a OneDriveException");
							if ((e.httpStatusCode == 429) || (e.httpStatusCode == 408)) {
								// If another 408 .. 
								if (e.httpStatusCode == 408) {
									// Increment & loop around
									log.vdebug("HTTP 408 generated - incrementing retryAttempts");
									retryAttempts++;
								}
								// If a 429 ..
								if (e.httpStatusCode == 429) {
									// Increment & loop around
									handleOneDriveThrottleRequest();
									log.vdebug("HTTP 429 generated - incrementing retryAttempts");
									retryAttempts++;
								}
							} else {
								displayOneDriveErrorMessage(e.msg);
							}
						}
					}
				}
			} catch (std.exception.ErrnoException e) {
				// There was a file system error
				// display the error message
				displayFileSystemErrorMessage(e.msg);							
				downloadFailed = true;
				return;
			}
			// file has to have downloaded in order to set the times / data for the file
			if (exists(path)) {
				// A 'file' was downloaded - does what we downloaded = reported fileSize or if there is some sort of funky local disk compression going on
				// does the file hash OneDrive reports match what we have locally?
				string quickXorHash = computeQuickXorHash(path);
				string sha1Hash = computeSha1Hash(path);
				
				if ((getSize(path) == fileSize) || (OneDriveFileHash == quickXorHash) || (OneDriveFileHash == sha1Hash)) {
					// downloaded matches either size or hash
					log.vdebug("Downloaded file matches reported size and or reported file hash");
					try {
						setTimes(path, item.mtime, item.mtime);
					} catch (FileException e) {
						// display the error message
						displayFileSystemErrorMessage(e.msg);
					}
				} else {
					// size error?
					if (getSize(path) != fileSize) {
						// downloaded file size does not match
						log.error("ERROR: File download size mis-match. Increase logging verbosity to determine why.");
					}
					// hash error?
					if ((OneDriveFileHash != quickXorHash) || (OneDriveFileHash != sha1Hash))  {
						// downloaded file hash does not match
						log.error("ERROR: File download hash mis-match. Increase logging verbosity to determine why.");
					}	
					// we do not want this local file to remain on the local file system
					safeRemove(path);	
					downloadFailed = true;
					return;
				}
			} else {
				log.error("ERROR: File failed to download. Increase logging verbosity to determine why.");
				downloadFailed = true;
				return;
			}
		}
		
		if (!downloadFailed) {
			writeln("done.");
			log.fileOnly("Downloading file ", path, " ... done.");
		}
	}

	// returns true if the given item corresponds to the local one
	private bool isItemSynced(const ref Item item, const(string) path)
	{
		if (!exists(path)) return false;
		final switch (item.type) {
		case ItemType.file:
			if (isFile(path)) {
				SysTime localModifiedTime = timeLastModified(path).toUTC();
				SysTime itemModifiedTime = item.mtime;
				// HACK: reduce time resolution to seconds before comparing
				itemModifiedTime.fracSecs = Duration.zero;
				localModifiedTime.fracSecs = Duration.zero;
				if (localModifiedTime == itemModifiedTime) {
					return true;
				} else {
					log.vlog("The local item has a different modified time ", localModifiedTime, " remote is ", itemModifiedTime);
				}
				if (testFileHash(path, item)) {
					return true;
				} else {
					log.vlog("The local item has a different hash");
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
		}
		return false;
	}

	private void deleteItems()
	{
		foreach_reverse (i; idsToDelete) {
			Item item;
			if (!itemdb.selectById(i[0], i[1], item)) continue; // check if the item is in the db
			const(string) path = itemdb.computePath(i[0], i[1]);
			log.log("Trying to delete item ", path);
			if (!dryRun) {
				// Actually process the database entry removal
				itemdb.deleteById(item.driveId, item.id);
				if (item.remoteDriveId != null) {
					// delete the linked remote folder
					itemdb.deleteById(item.remoteDriveId, item.remoteId);
				}
			}
			bool needsRemoval = false;
			if (exists(path)) {
				// path exists on the local system	
				// make sure that the path refers to the correct item
				Item pathItem;
				if (itemdb.selectByPath(path, item.driveId, pathItem)) {
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
				log.log("Deleting item ", path);
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
							displayFileSystemErrorMessage(e.msg);
						}
					}
				}
			}
		}
		
		if (!dryRun) {
			// clean up idsToDelete
			idsToDelete.length = 0;
			assumeSafeAppend(idsToDelete);
		}
	}
	
	// scan the given directory for differences and new items - for use with --synchronize
	void scanForDifferences(const(string) path)
	{
		// To improve logging output for this function, what is the 'logical path' we are scanning for file & folder differences?
		string logPath;
		if (path == ".") {
			// get the configured sync_dir
			logPath = buildNormalizedPath(cfg.getValueString("sync_dir"));
		} else {
			// use what was passed in
			logPath = path;
		}
		
		// Are we configured to use a National Cloud Deployment
		// Any entry in the DB than is flagged as out-of-sync needs to be cleaned up locally first before we scan the entire DB
		// Normally, this is done at the end of processing all /delta queries, but National Cloud Deployments (US and DE) do not support /delta as a query
		if ((nationalCloudDeployment) || (syncBusinessFolders)) {
			// Select items that have a out-of-sync flag set
			foreach (driveId; driveIDsArray) {
				// For each unique OneDrive driveID we know about
				Item[] outOfSyncItems = itemdb.selectOutOfSyncItems(driveId);
				foreach (item; outOfSyncItems) {
					if (!dryRun) {
						// clean up idsToDelete
						idsToDelete.length = 0;
						assumeSafeAppend(idsToDelete);
						// flag to delete local file as it now is no longer in sync with OneDrive
						log.vdebug("Flagging to delete local item as it now is no longer in sync with OneDrive");
						log.vdebug("item: ", item);
						idsToDelete ~= [item.driveId, item.id];	
						// delete items in idsToDelete
						if (idsToDelete.length > 0) deleteItems();
					}
				}
			}
		}
		
		// scan for changes in the path provided
		log.log("Uploading differences of ", logPath);
		Item item;
		// For each unique OneDrive driveID we know about
		foreach (driveId; driveIDsArray) {
			log.vdebug("Processing DB entries for this driveId: ", driveId);
			// Database scan of every item in DB for the given driveId based on the root parent for that drive
			if ((syncBusinessFolders) && (driveId != defaultDriveId)) {
				// There could be multiple shared folders all from this same driveId
				foreach(dbItem; itemdb.selectByDriveId(driveId)) {
					// Does it still exist on disk in the location the DB thinks it is
					uploadDifferences(dbItem);
				}
			} else {
				if (itemdb.selectByPath(path, driveId, item)) {
					// Does it still exist on disk in the location the DB thinks it is
					uploadDifferences(item);
				}
			}
		}

		log.log("Uploading new items of ", logPath);
		// Filesystem walk to find new files not uploaded
		uploadNewItems(path);
		// clean up idsToDelete only if --dry-run is set
		if (dryRun) {
			idsToDelete.length = 0;
			assumeSafeAppend(idsToDelete);
		}
	}
	
	// scan the given directory for differences only - for use with --monitor
	void scanForDifferencesDatabaseScan(const(string) path)
	{
		// To improve logging output for this function, what is the 'logical path' we are scanning for file & folder differences?
		string logPath;
		if (path == ".") {
			// get the configured sync_dir
			logPath = buildNormalizedPath(cfg.getValueString("sync_dir"));
		} else {
			// use what was passed in
			logPath = path;
		}
		
		// Are we configured to use a National Cloud Deployment
		// Any entry in the DB than is flagged as out-of-sync needs to be cleaned up locally first before we scan the entire DB
		// Normally, this is done at the end of processing all /delta queries, but National Cloud Deployments (US and DE) do not support /delta as a query
		if ((nationalCloudDeployment) || (syncBusinessFolders)) {
			// Select items that have a out-of-sync flag set
			foreach (driveId; driveIDsArray) {
				// For each unique OneDrive driveID we know about
				Item[] outOfSyncItems = itemdb.selectOutOfSyncItems(driveId);
				foreach (item; outOfSyncItems) {
					if (!dryRun) {
						// clean up idsToDelete
						idsToDelete.length = 0;
						assumeSafeAppend(idsToDelete);
						// flag to delete local file as it now is no longer in sync with OneDrive
						log.vdebug("Flagging to delete local item as it now is no longer in sync with OneDrive");
						log.vdebug("item: ", item);
						idsToDelete ~= [item.driveId, item.id];	
						// delete items in idsToDelete
						if (idsToDelete.length > 0) deleteItems();
					}
				}
			}
		}
		
		// scan for changes in the path provided
		log.vlog("Uploading differences of ", logPath);
		Item item;
		// For each unique OneDrive driveID we know about
		foreach (driveId; driveIDsArray) {
			log.vdebug("Processing DB entries for this driveId: ", driveId);
			// Database scan of every item in DB for the given driveId based on the root parent for that drive
			if ((syncBusinessFolders) && (driveId != defaultDriveId)) {
				// There could be multiple shared folders all from this same driveId
				foreach(dbItem; itemdb.selectByDriveId(driveId)) {
					// Does it still exist on disk in the location the DB thinks it is
					uploadDifferences(dbItem);
				}
			} else {
				if (itemdb.selectByPath(path, driveId, item)) {
					// Does it still exist on disk in the location the DB thinks it is
					uploadDifferences(item);
				}
			}
		}
	}
	
	// scan the given directory for new items - for use with --monitor
	void scanForDifferencesFilesystemScan(const(string) path)
	{
		// To improve logging output for this function, what is the 'logical path' we are scanning for file & folder differences?
		string logPath;
		if (path == ".") {
			// get the configured sync_dir
			logPath = buildNormalizedPath(cfg.getValueString("sync_dir"));
		} else {
			// use what was passed in
			logPath = path;
		}
		
		log.vlog("Uploading new items of ", logPath);
		// Filesystem walk to find new files not uploaded
		uploadNewItems(path);
	}
	
	private void uploadDifferences(const ref Item item)
	{
		// see if this item.id we were supposed to have deleted
		// match early and return
		if (dryRun) {
			foreach (i; idsToDelete) {
				if (i[1] == item.id) {
					return;
				}	
			}
		}
		
		log.vlog("Processing ", item.name);
		bool unwanted = false;
		string path;
		
		// Is the path excluded?
		unwanted = selectiveSync.isDirNameExcluded(item.name);
		
		// If the path is not excluded, is the filename excluded?
		if (!unwanted) {
			unwanted = selectiveSync.isFileNameExcluded(item.name);
		}

		// If path or filename does not exclude, is this excluded due to use of selective sync?
		if (!unwanted) {
			path = itemdb.computePath(item.driveId, item.id);
			unwanted = selectiveSync.isPathExcludedViaSyncList(path);
		}

		// skip unwanted items
		if (unwanted) {
			//log.vlog("Filtered out");
			return;
		}
		
		// Restriction and limitations about windows naming files
		if (!isValidName(path)) {
			log.log("Skipping item - invalid name (Microsoft Naming Convention): ", path);
			return;
		}
		
		// Check for bad whitespace items
		if (!containsBadWhiteSpace(path)) {
			log.log("Skipping item - invalid name (Contains an invalid whitespace item): ", path);
			return;
		}
		
		// Check for HTML ASCII Codes as part of file name
		if (!containsASCIIHTMLCodes(path)) {
			log.log("Skipping item - invalid name (Contains HTML ASCII Code): ", path);
			return;
		}
		
		final switch (item.type) {
		case ItemType.dir:
			uploadDirDifferences(item, path);
			break;
		case ItemType.file:
			uploadFileDifferences(item, path);
			break;
		case ItemType.remote:
			uploadRemoteDirDifferences(item, path);
			break;
		}
	}

	private void uploadDirDifferences(const ref Item item, const(string) path)
	{
		assert(item.type == ItemType.dir);
		if (exists(path)) {
			if (!isDir(path)) {
				log.vlog("The item was a directory but now it is a file");
				uploadDeleteItem(item, path);
				uploadNewFile(path);
			} else {
				log.vlog("The directory has not changed");
				// loop through the children
				foreach (Item child; itemdb.selectChildren(item.driveId, item.id)) {
					uploadDifferences(child);
				}
			}
		} else {
			// Directory does not exist locally
			// If we are in a --dry-run situation - this directory may never have existed as we never downloaded it
			if (!dryRun) {
				// Not --dry-run situation
				if (!cfg.getValueBool("monitor")) {
					// Not in --monitor mode
					log.vlog("The directory has been deleted locally");
					if (noRemoteDelete) {
						// do not process remote directory delete
						log.vlog("Skipping remote directory delete as --upload-only & --no-remote-delete configured");
					} else {
						uploadDeleteItem(item, path);
					}	
				} else {
					// Appropriate message as we are in --monitor mode
					log.vlog("The directory appears to have been deleted locally .. but we are running in --monitor mode. This may have been 'moved' rather than 'deleted'");
				}
			} else {
				// we are in a --dry-run situation, directory appears to have deleted locally - this directory may never have existed as we never downloaded it ..
				// Check if path does not exist in database
				Item databaseItem;
				if (!itemdb.selectByPath(path, defaultDriveId, databaseItem)) {
					// Path not found in database
					log.vlog("The directory has been deleted locally");
					if (noRemoteDelete) {
						// do not process remote directory delete
						log.vlog("Skipping remote directory delete as --upload-only & --no-remote-delete configured");
					} else {
						uploadDeleteItem(item, path);
					}
				} else {
					// Path was found in the database
					// Did we 'fake create it' as part of --dry-run ?
					foreach (i; idsFaked) {
						if (i[1] == item.id) {
							log.vdebug("Matched faked dir which is 'supposed' to exist but not created due to --dry-run use");
							log.vlog("The directory has not changed");
							return;
						}
					}
					// item.id did not match a 'faked' download new directory creation
					log.vlog("The directory has been deleted locally");
					uploadDeleteItem(item, path);
				}
			}
		}
	}

	private void uploadRemoteDirDifferences(const ref Item item, const(string) path)
	{
		assert(item.type == ItemType.remote);
		if (exists(path)) {
			if (!isDir(path)) {
				log.vlog("The item was a directory but now it is a file");
				uploadDeleteItem(item, path);
				uploadNewFile(path);
			} else {
				log.vlog("The directory has not changed");
				// continue through the linked folder
				assert(item.remoteDriveId && item.remoteId);
				Item remoteItem;
				bool found = itemdb.selectById(item.remoteDriveId, item.remoteId, remoteItem);
				if(found){
					// item was found in the database
					uploadDifferences(remoteItem);
				}
			}
		} else {
			// are we in a dry-run scenario
			if (!dryRun) {
				// no dry-run
				log.vlog("The directory has been deleted locally");
				if (noRemoteDelete) {
					// do not process remote directory delete
					log.vlog("Skipping remote directory delete as --upload-only & --no-remote-delete configured");
				} else {
					uploadDeleteItem(item, path);
				}
			} else {
				// we are in a --dry-run situation, directory appears to have deleted locally - this directory may never have existed as we never downloaded it ..
				// Check if path does not exist in database
				Item databaseItem;
				if (!itemdb.selectByPathWithRemote(path, defaultDriveId, databaseItem)) {
					// Path not found in database
					log.vlog("The directory has been deleted locally");
					if (noRemoteDelete) {
						// do not process remote directory delete
						log.vlog("Skipping remote directory delete as --upload-only & --no-remote-delete configured");
					} else {
						uploadDeleteItem(item, path);
					}
				} else {
					// Path was found in the database
					// Did we 'fake create it' as part of --dry-run ?
					foreach (i; idsFaked) {
						if (i[1] == item.id) {
							log.vdebug("Matched faked dir which is 'supposed' to exist but not created due to --dry-run use");
							log.vlog("The directory has not changed");
							return;
						}
					}
					// item.id did not match a 'faked' download new directory creation
					log.vlog("The directory has been deleted locally");
					uploadDeleteItem(item, path);
				}
			}
		}
	}

	// upload local file system differences to OneDrive
	private void uploadFileDifferences(const ref Item item, const(string) path)
	{
		// Reset upload failure - OneDrive or filesystem issue (reading data)
		uploadFailed = false;
	
		assert(item.type == ItemType.file);
		if (exists(path)) {
			if (isFile(path)) {
				SysTime localModifiedTime = timeLastModified(path).toUTC();
				SysTime itemModifiedTime = item.mtime;
				// HACK: reduce time resolution to seconds before comparing
				itemModifiedTime.fracSecs = Duration.zero;
				localModifiedTime.fracSecs = Duration.zero;
				
				if (localModifiedTime != itemModifiedTime) {
					log.vlog("The file last modified time has changed");					
					string eTag = item.eTag;
					if (!testFileHash(path, item)) {
						log.vlog("The file content has changed");
						write("Uploading modified file ", path, " ... ");
						JSONValue response;
						
						if (!dryRun) {
							// Are we using OneDrive Personal or OneDrive Business?
							// To solve 'Multiple versions of file shown on website after single upload' (https://github.com/abraunegg/onedrive/issues/2)
							// check what 'account type' this is as this issue only affects OneDrive Business so we need some extra logic here
							if (accountType == "personal"){
								// Original file upload logic
								if (getSize(path) <= thresholdFileSize) {
									try {
										response = onedrive.simpleUploadReplace(path, item.driveId, item.id, item.eTag);
									} catch (OneDriveException e) {
										if (e.httpStatusCode == 401) {
											// OneDrive returned a 'HTTP/1.1 401 Unauthorized Error' - file failed to be uploaded
											writeln("skipped.");
											log.vlog("OneDrive returned a 'HTTP 401 - Unauthorized' - gracefully handling error");
											uploadFailed = true;
											return;
										}
										if (e.httpStatusCode == 404) {
											// HTTP request returned status code 404 - the eTag provided does not exist
											// Delete record from the local database - file will be uploaded as a new file
											writeln("skipped.");
											log.vlog("OneDrive returned a 'HTTP 404 - eTag Issue' - gracefully handling error");
											itemdb.deleteById(item.driveId, item.id);
											uploadFailed = true;
											return;
										}
										// Resolve https://github.com/abraunegg/onedrive/issues/36
										if ((e.httpStatusCode == 409) || (e.httpStatusCode == 423)) {
											// The file is currently checked out or locked for editing by another user
											// We cant upload this file at this time
											writeln("skipped.");
											log.fileOnly("Uploading modified file ", path, " ... skipped.");
											write("", path, " is currently checked out or locked for editing by another user.");
											log.fileOnly(path, " is currently checked out or locked for editing by another user.");
											uploadFailed = true;
											return;
										}
										if (e.httpStatusCode == 412) {
											// HTTP request returned status code 412 - ETag does not match current item's value
											// Delete record from the local database - file will be uploaded as a new file
											writeln("skipped.");
											log.vdebug("Simple Upload Replace Failed - OneDrive eTag / cTag match issue");
											log.vlog("OneDrive returned a 'HTTP 412 - Precondition Failed' - gracefully handling error. Will upload as new file.");
											itemdb.deleteById(item.driveId, item.id);
											uploadFailed = true;
											return;
										}
										if (e.httpStatusCode == 504) {
											// HTTP request returned status code 504 (Gateway Timeout)
											log.log("OneDrive returned a 'HTTP 504 - Gateway Timeout' - retrying upload request as a session");
											// Try upload as a session
											response = session.upload(path, item.driveId, item.parentId, baseName(path), item.eTag);
										} else {
											// display what the error is
											writeln("skipped.");
											displayOneDriveErrorMessage(e.msg);
											uploadFailed = true;
											return;
										}
									} catch (FileException e) {
										// display the error message
										writeln("skipped.");
										displayFileSystemErrorMessage(e.msg);
										uploadFailed = true;
										return;
									}
									// upload done without error
									writeln("done.");
								} else {
									writeln("");
									try {
										response = session.upload(path, item.driveId, item.parentId, baseName(path), item.eTag);
									} catch (OneDriveException e) {
										if (e.httpStatusCode == 401) {
											// OneDrive returned a 'HTTP/1.1 401 Unauthorized Error' - file failed to be uploaded
											writeln("skipped.");
											log.vlog("OneDrive returned a 'HTTP 401 - Unauthorized' - gracefully handling error");
											uploadFailed = true;
											return;
										}
										if (e.httpStatusCode == 412) {
											// HTTP request returned status code 412 - ETag does not match current item's value
											// Delete record from the local database - file will be uploaded as a new file
											writeln("skipped.");
											log.vdebug("Simple Upload Replace Failed - OneDrive eTag / cTag match issue");
											log.vlog("OneDrive returned a 'HTTP 412 - Precondition Failed' - gracefully handling error. Will upload as new file.");
											itemdb.deleteById(item.driveId, item.id);
											uploadFailed = true;
											return;
										} else {
											// display what the error is
											writeln("skipped.");
											displayOneDriveErrorMessage(e.msg);
											uploadFailed = true;
											return;
										}
									} catch (FileException e) {
										// display the error message
										writeln("skipped.");
										displayFileSystemErrorMessage(e.msg);
										uploadFailed = true;
										return;
									}
									// upload done without error
									writeln("done.");
								}
							} else {
								// OneDrive Business Account
								// We need to always use a session to upload, but handle the changed file correctly
								if (accountType == "business"){
									
									try {
										// is this a zero-byte file?
										if (getSize(path) == 0) {
											// the file we are trying to upload as a session is a zero byte file - we cant use a session to upload or replace the file 
											// as OneDrive technically does not support zero byte files
											writeln("skipped.");
											log.fileOnly("Uploading modified file ", path, " ... skipped.");
											log.vlog("Skip Reason: Microsoft OneDrive does not support 'zero-byte' files as a modified upload. Will upload as new file.");
											// delete file on OneDrive
											onedrive.deleteById(item.driveId, item.id, item.eTag);
											// delete file from local database
											itemdb.deleteById(item.driveId, item.id);
											return;
										} else {
											// For logging consistency
											writeln("");
											// normal session upload
											response = session.upload(path, item.driveId, item.parentId, baseName(path), item.eTag);
										}
									} catch (OneDriveException e) {
										if (e.httpStatusCode == 401) {
											// OneDrive returned a 'HTTP/1.1 401 Unauthorized Error' - file failed to be uploaded
											writeln("skipped.");
											log.vlog("OneDrive returned a 'HTTP 401 - Unauthorized' - gracefully handling error");
											uploadFailed = true;
											return;
										}
										// Resolve https://github.com/abraunegg/onedrive/issues/36
										if ((e.httpStatusCode == 409) || (e.httpStatusCode == 423)) {
											// The file is currently checked out or locked for editing by another user
											// We cant upload this file at this time
											writeln("skipped.");
											log.fileOnly("Uploading modified file ", path, " ... skipped.");
											writeln("", path, " is currently checked out or locked for editing by another user.");
											log.fileOnly(path, " is currently checked out or locked for editing by another user.");
											uploadFailed = true;
											return;
										} else {
											// display what the error is
											writeln("skipped.");
											displayOneDriveErrorMessage(e.msg);
											uploadFailed = true;
											return;
										}
									} catch (FileException e) {
										// display the error message
										writeln("skipped.");
										displayFileSystemErrorMessage(e.msg);
										uploadFailed = true;
										return;
									}
									// upload done without error
									writeln("done.");
									
									// As the session.upload includes the last modified time, save the response
									// Is the response a valid JSON object - validation checking done in saveItem
									saveItem(response);
								}
								// OneDrive documentLibrary
								if (accountType == "documentLibrary"){
									// is this a zero-byte file?
									if (getSize(path) == 0) {
										// the file we are trying to upload as a session is a zero byte file - we cant use a session to upload or replace the file 
										// as OneDrive technically does not support zero byte files
										writeln("skipped.");
										log.fileOnly("Uploading modified file ", path, " ... skipped.");
										log.vlog("Skip Reason: Microsoft OneDrive does not support 'zero-byte' files as a modified upload. Will upload as new file.");
										// delete file on OneDrive
										onedrive.deleteById(item.driveId, item.id, item.eTag);
										// delete file from local database
										itemdb.deleteById(item.driveId, item.id);
										return;
									} else {
										// Handle certain file types differently
										if ((extension(path) == ".txt") || (extension(path) == ".csv")) {
											// .txt and .csv are unaffected by https://github.com/OneDrive/onedrive-api-docs/issues/935 
											// For logging consistency
											writeln("");
											try {
												response = session.upload(path, item.driveId, item.parentId, baseName(path), item.eTag);
											} catch (OneDriveException e) {
												if (e.httpStatusCode == 401) {
													// OneDrive returned a 'HTTP/1.1 401 Unauthorized Error' - file failed to be uploaded
													writeln("skipped.");
													log.vlog("OneDrive returned a 'HTTP 401 - Unauthorized' - gracefully handling error");
													uploadFailed = true;
													return;
												}										
												// Resolve https://github.com/abraunegg/onedrive/issues/36
												if ((e.httpStatusCode == 409) || (e.httpStatusCode == 423)) {
													// The file is currently checked out or locked for editing by another user
													// We cant upload this file at this time
													writeln("skipped.");
													log.fileOnly("Uploading modified file ", path, " ... skipped.");
													writeln("", path, " is currently checked out or locked for editing by another user.");
													log.fileOnly(path, " is currently checked out or locked for editing by another user.");
													uploadFailed = true;
													return;
												} else {
													// display what the error is
													writeln("skipped.");
													displayOneDriveErrorMessage(e.msg);
													uploadFailed = true;
													return;
												}
											} catch (FileException e) {
												// display the error message
												writeln("skipped.");
												displayFileSystemErrorMessage(e.msg);
												uploadFailed = true;
												return;
											}
											// upload done without error
											writeln("done.");
											// As the session.upload includes the last modified time, save the response
											// Is the response a valid JSON object - validation checking done in saveItem
											saveItem(response);
										} else {									
											// Due to https://github.com/OneDrive/onedrive-api-docs/issues/935 Microsoft modifies all PDF, MS Office & HTML files with added XML content. It is a 'feature' of SharePoint.
											// This means, as a session upload, on 'completion' the file is 'moved' and generates a 404 ......
											writeln("skipped.");
											log.fileOnly("Uploading modified file ", path, " ... skipped.");
											log.vlog("Skip Reason: Microsoft Sharepoint 'enrichment' after upload issue");
											log.vlog("See: https://github.com/OneDrive/onedrive-api-docs/issues/935 for further details");
											// Delete record from the local database - file will be uploaded as a new file
											itemdb.deleteById(item.driveId, item.id);
											return;
										}
									}
								}
							}
							log.fileOnly("Uploading modified file ", path, " ... done.");
							if ("cTag" in response) {
								// use the cTag instead of the eTag because OneDrive may update the metadata of files AFTER they have been uploaded via simple upload
								eTag = response["cTag"].str;
							} else {
								// Is there an eTag in the response?
								if ("eTag" in response) {
									// use the eTag from the response as there was no cTag
									eTag = response["eTag"].str;
								} else {
									// no tag available - set to nothing
									eTag = "";
								}
							}
						} else {
							// we are --dry-run - simulate the file upload
							writeln("done.");
							response = createFakeResponse(path);
							// Log action to log file
							log.fileOnly("Uploading modified file ", path, " ... done.");
							// Is the response a valid JSON object - validation checking done in saveItem
							saveItem(response);
							return;
						}
					}
					if (accountType == "personal"){
						// If Personal, call to update the modified time as stored on OneDrive
						if (!dryRun) {
							uploadLastModifiedTime(item.driveId, item.id, eTag, localModifiedTime.toUTC());
						}
					}
				} else {
					log.vlog("The file has not changed");
				}
			} else {
				log.vlog("The item was a file but now is a directory");
				uploadDeleteItem(item, path);
				uploadCreateDir(path);
			}
		} else {
			// File does not exist locally
			// If we are in a --dry-run situation - this file may never have existed as we never downloaded it
			if (!dryRun) {
				// Not --dry-run situation
				if (!cfg.getValueBool("monitor")) {
					log.vlog("The file has been deleted locally");
					if (noRemoteDelete) {
						// do not process remote file delete
						log.vlog("Skipping remote file delete as --upload-only & --no-remote-delete configured");
					} else {
						uploadDeleteItem(item, path);
					}
				} else {
					// Appropriate message as we are in --monitor mode
					log.vlog("The file appears to have been deleted locally .. but we are running in --monitor mode. This may have been 'moved' rather than 'deleted'");
				}
			} else {
				// We are in a --dry-run situation, file appears to have deleted locally - this file may never have existed as we never downloaded it ..
				// Check if path does not exist in database
				Item databaseItem;
				if (!itemdb.selectByPath(path, defaultDriveId, databaseItem)) {
					// file not found in database
					log.vlog("The file has been deleted locally");
					if (noRemoteDelete) {
						// do not process remote file delete
						log.vlog("Skipping remote file delete as --upload-only & --no-remote-delete configured");
					} else {
						uploadDeleteItem(item, path);
					}
				} else {
					// file was found in the database
					// Did we 'fake create it' as part of --dry-run ?
					foreach (i; idsFaked) {
						if (i[1] == item.id) {
							log.vdebug("Matched faked file which is 'supposed' to exist but not created due to --dry-run use");
							log.vlog("The file has not changed");
							return;
						}
					}
					// item.id did not match a 'faked' download new file creation
					log.vlog("The file has been deleted locally");
					if (noRemoteDelete) {
						// do not process remote file delete
						log.vlog("Skipping remote file delete as --upload-only & --no-remote-delete configured");
					} else {
						uploadDeleteItem(item, path);
					}
				}
			}
		}
	}

	// upload new items to OneDrive
	private void uploadNewItems(const(string) path)
	{
		import std.range : walkLength;
		import std.uni : byGrapheme;
		//	https://support.microsoft.com/en-us/help/3125202/restrictions-and-limitations-when-you-sync-files-and-folders
		//  If the path is greater than allowed characters, then one drive will return a '400 - Bad Request' 
		//  Need to ensure that the URI is encoded before the check is made
		//  400 Character Limit for OneDrive Business / Office 365
		//  430 Character Limit for OneDrive Personal
		long maxPathLength = 0;
		long pathWalkLength = path.byGrapheme.walkLength;
		
		// Configure maxPathLength based on account type
		if (accountType == "personal"){
			// Personal Account
			maxPathLength = 430;
		} else {
			// Business Account / Office365
			maxPathLength = 400;
		}
				
		// A short lived file that has disappeared will cause an error - is the path valid?
		if (!exists(path)) {
			log.log("Skipping item - has disappeared: ", path);
			return;
		}
		
		// Invalid UTF-8 sequence check
		// https://github.com/skilion/onedrive/issues/57
		// https://github.com/abraunegg/onedrive/issues/487
		if(!isValid(path)) {
			// Path is not valid according to https://dlang.org/phobos/std_encoding.html
			log.vlog("Skipping item - invalid character sequences: ", path);
			return;
		}
		
		if(pathWalkLength < maxPathLength){
			// path length is less than maxPathLength
			
			// skip dot files if configured
			if (cfg.getValueBool("skip_dotfiles")) {
				if (isDotFile(path)) {
					log.vlog("Skipping item - .file or .folder: ", path);
					return;
				}
			}
			
			// Do we need to check for .nosync? Only if --check-for-nosync was passed in
			if (cfg.getValueBool("check_nosync")) {
				if (exists(path ~ "/.nosync")) {
					log.vlog("Skipping item - .nosync found & --check-for-nosync enabled: ", path);
					return;
				}
			}
			
			if (isSymlink(path)) {
				// if config says so we skip all symlinked items
				if (cfg.getValueBool("skip_symlinks")) {
					log.vlog("Skipping item - skip symbolic links configured: ", path);
					return;

				}
				// skip unexisting symbolic links
				else if (!exists(readLink(path))) {
					// reading the symbolic link failed - is the link a relative symbolic link
					//   drwxrwxr-x. 2 alex alex 46 May 30 09:16 .
					//   drwxrwxr-x. 3 alex alex 35 May 30 09:14 ..
					//   lrwxrwxrwx. 1 alex alex 61 May 30 09:16 absolute.txt -> /home/alex/OneDrivePersonal/link_tests/intercambio/prueba.txt
					//   lrwxrwxrwx. 1 alex alex 13 May 30 09:16 relative.txt -> ../prueba.txt
					//
					// absolute links will be able to be read, but 'relative' links will fail, because they cannot be read based on the current working directory 'sync_dir'
					string currentSyncDir = getcwd();
					string fullLinkPath = buildNormalizedPath(absolutePath(path));
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
						log.vdebug("Not skipping item - symbolic link is a 'relative link' to target ('", relativeLink, "') which can be supported: ", path);
					} else {
						log.log("Skipping item - invalid symbolic link: ", path);
						return;
					}
				}
			}
			
			// Restriction and limitations about windows naming files
			if (!isValidName(path)) {
				log.log("Skipping item - invalid name (Microsoft Naming Convention): ", path);
				return;
			}
			
			// Check for bad whitespace items
			if (!containsBadWhiteSpace(path)) {
				log.log("Skipping item - invalid name (Contains an invalid whitespace item): ", path);
				return;
			}
			
			// Check for HTML ASCII Codes as part of file name
			if (!containsASCIIHTMLCodes(path)) {
				log.log("Skipping item - invalid name (Contains HTML ASCII Code): ", path);
				return;
			}

			// filter out user configured items to skip
			if (path != ".") {
				if (isDir(path)) {
					log.vdebug("Checking local path: ", path);
					// Only check path if config is != ""
					if (cfg.getValueString("skip_dir") != "") {
						if (selectiveSync.isDirNameExcluded(path.strip('.').strip('/'))) {
							log.vlog("Skipping item - excluded by skip_dir config: ", path);
							return;
						}
					}
				
					// In the event that this 'new item' is actually a OneDrive Business Shared Folder
					// however the user may have omitted --sync-shared-folders, thus 'technically' this is a new item
					// for this account OneDrive root, however this then would cause issues if --sync-shared-folders 
					// is added again after this sync
					if ((exists(cfg.businessSharedFolderFilePath)) && (!syncBusinessFolders)){
						// business_shared_folders file exists, but we are not using / syncing them
						if(selectiveSync.isSharedFolderMatched(strip(path,"./"))){
							// path detected as a 'new item' is matched as a path in business_shared_folders
							log.vlog("Skipping item - excluded as included in business_shared_folders config: ", path);
							log.vlog("To sync this directory to your OneDrive Account update your business_shared_folders config");
							return;
						}
					}
				}
				if (isFile(path)) {
					log.vdebug("Checking file: ", path);
					if (selectiveSync.isFileNameExcluded(path.strip('.').strip('/'))) {
						log.vlog("Skipping item - excluded by skip_file config: ", path);
						return;
					}
				}
				if (selectiveSync.isPathExcludedViaSyncList(path)) {
					if ((isFile(path)) && (cfg.getValueBool("sync_root_files")) && (rootName(path.strip('.').strip('/')) == "")) {
						log.vdebug("Not skipping path due to sync_root_files inclusion: ", path);
					} else {
						string userSyncList = cfg.configDirName ~ "/sync_list";
						if (exists(userSyncList)){
							// skipped most likely due to inclusion in sync_list
							log.vlog("Skipping item - excluded by sync_list config: ", path);
							return;
						} else {
							// skipped for some other reason
							log.vlog("Skipping item - path excluded by user config: ", path);
							return;
						}
					}
				}
			}

			// This item passed all the unwanted checks
			// We want to upload this new item
			if (isDir(path)) {
				Item item;
				bool pathFoundInDB = false;
				foreach (driveId; driveIDsArray) {
					if (itemdb.selectByPath(path, driveId, item)) {
						pathFoundInDB = true; 
					}
				}
				
				// Was the path found in the database?
				if (!pathFoundInDB) {
					// Path not found in database when searching all drive id's
					uploadCreateDir(path);
				}
				
				// recursively traverse children
				// the above operation takes time and the directory might have
				// disappeared in the meantime
				if (!exists(path)) {
					log.vlog("Directory disappeared during upload: ", path);
					return;
				}
				
				// Try and access the directory and any path below
				try {
					auto entries = dirEntries(path, SpanMode.shallow, false);
					foreach (DirEntry entry; entries) {
						string thisPath = entry.name;
						uploadNewItems(thisPath);
					}
				} catch (FileException e) {
					// display the error message
					displayFileSystemErrorMessage(e.msg);
					return;
				}
			} else {
				bool fileFoundInDB = false;
				// This item is a file
				long fileSize = getSize(path);
				// Can we upload this file - is there enough free space? - https://github.com/skilion/onedrive/issues/73
				// However if the OneDrive account does not provide the quota details, we have no idea how much free space is available
				if ((!quotaAvailable) || ((remainingFreeSpace - fileSize) > 0)){
					if (!quotaAvailable) {
						log.vlog("Ignoring OneDrive account quota details to upload file - this may fail if not enough space on OneDrive ..");
					}
					Item item;
					foreach (driveId; driveIDsArray) {
						if (itemdb.selectByPath(path, driveId, item)) {
							fileFoundInDB = true; 
						}
					}
					
					// Was the file found in the database?
					if (!fileFoundInDB) {
						// File not found in database when searching all drive id's, upload as new file
						uploadNewFile(path);
						
						// did the upload fail?
						if (!uploadFailed) {
							// upload did not fail
							// Issue #763 - Delete local files after sync handling
							// are we in an --upload-only scenario?
							if (uploadOnly) {
								// are we in a delete local file after upload?
								if (localDeleteAfterUpload) {
									// Log that we are deleting a local item
									log.log("Removing local file as --upload-only & --remove-source-files configured");
									// are we in a --dry-run scenario?
									if (!dryRun) {
										// No --dry-run ... process local file delete
										log.vdebug("Removing local file: ", path);
										safeRemove(path);
									}
								}
							}
							
							// how much space is left on OneDrive after upload?
							remainingFreeSpace = (remainingFreeSpace - fileSize);
							log.vlog("Remaining free space on OneDrive: ", remainingFreeSpace);
						}
					}
				} else {
					// Not enough free space
					log.log("Skipping item '", path, "' due to insufficient free space available on OneDrive");
 				}
			}
		} else {
			// This path was skipped - why?
			log.log("Skipping item '", path, "' due to the full path exceeding ", maxPathLength, " characters (Microsoft OneDrive limitation)");
		}
	}

	// create new directory on OneDrive
	private void uploadCreateDir(const(string) path)
	{
		log.vlog("OneDrive Client requested to create remote path: ", path);
		JSONValue onedrivePathDetails;
		Item parent;
		// Was the path entered the root path?
		if (path != "."){
			// What parent path to use?
			string parentPath = dirName(path);		// will be either . or something else
			if (parentPath == "."){
				// Assume this is a new 'local' folder in the users configured sync_dir
				// Use client defaults
				parent.id = defaultRootId;  // Should give something like 12345ABCDE1234A1!101
				parent.driveId = defaultDriveId;  // Should give something like 12345abcde1234a1
			} else {
				// Query the database using each of the driveId's we are using
				foreach (driveId; driveIDsArray) {
					// Query the database for this parent path using each driveId
					Item dbResponse;
					if(itemdb.selectByPathWithRemote(parentPath, driveId, dbResponse)){
						// parent path was found in the database
						parent = dbResponse;
					}
				}
			}
			
			// If this is still null or empty - we cant query the database properly later on
			// Query OneDrive API for parent details
			if ((parent.driveId == "") && (parent.id == "")){
				try {
					log.vdebug("Attempting to query OneDrive for this parent path: ", parentPath);
					onedrivePathDetails = onedrive.getPathDetails(parentPath);
				} catch (OneDriveException e) {
					log.vdebug("onedrivePathDetails = onedrive.getPathDetails(parentPath); generated a OneDriveException");
					// exception - set onedriveParentRootDetails to a blank valid JSON
					onedrivePathDetails = parseJSON("{}");
					if (e.httpStatusCode == 404) {
						// Parent does not exist ... need to create parent
						log.vdebug("Parent path does not exist: ", parentPath);
						uploadCreateDir(parentPath);
					}
					
					if (e.httpStatusCode == 429) {
						// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
						handleOneDriveThrottleRequest();
						// Retry original request by calling function again to avoid replicating any further error handling
						log.vdebug("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - calling uploadCreateDir(path);");
						uploadCreateDir(path);
						// return back to original call
						return;
					}
					
					if (e.httpStatusCode >= 500) {
						// OneDrive returned a 'HTTP 5xx Server Side Error' - gracefully handling error - error message already logged
						return;
					}
				}
				
				// configure the parent item data
				if (hasId(onedrivePathDetails) && hasParentReference(onedrivePathDetails)){
					log.vdebug("Parent path found, configuring parent item");
					parent.id = onedrivePathDetails["id"].str; // This item's ID. Should give something like 12345ABCDE1234A1!101
					parent.driveId = onedrivePathDetails["parentReference"]["driveId"].str; // Should give something like 12345abcde1234a1
				} else {
					// OneDrive API query failed
					// Assume client defaults
					log.vdebug("Parent path could not be queried, using OneDrive account defaults");
					parent.id = defaultRootId;  // Should give something like 12345ABCDE1234A1!101
					parent.driveId = defaultDriveId;  // Should give something like 12345abcde1234a1
				}
			}
		
			JSONValue response;
			// test if the path we are going to create already exists on OneDrive
			try {
				log.vdebug("Attempting to query OneDrive for this path: ", path);
				response = onedrive.getPathDetailsByDriveId(parent.driveId, path);
			} catch (OneDriveException e) {
				log.vdebug("response = onedrive.getPathDetails(path); generated a OneDriveException");
				if (e.httpStatusCode == 404) {
					// The directory was not found on the drive id we queried
					log.vlog("The requested directory to create was not found on OneDrive - creating remote directory: ", path);

					if (!dryRun) {
						// Perform the database lookup - is the parent in the database?
						if (!itemdb.selectByPath(dirName(path), parent.driveId, parent)) {
							// parent is not in the database
							log.vdebug("Parent path is not in the database - need to add it: ", dirName(path));
							uploadCreateDir(dirName(path));
						}
						
						// Is the parent a 'folder' from another user? ie - is this a 'shared folder' that has been shared with us?
						if (defaultDriveId == parent.driveId){
							// enforce check of parent path. if the above was triggered, the below will generate a sync retry and will now be sucessful
							enforce(itemdb.selectByPath(dirName(path), parent.driveId, parent), "The parent item id is not in the database");
						} else {
							log.vdebug("Parent drive ID is not our drive ID - parent most likely a shared folder");
						}
						
						JSONValue driveItem = [
								"name": JSONValue(baseName(path)),
								"folder": parseJSON("{}")
						];
						
						// Submit the creation request
						// Fix for https://github.com/skilion/onedrive/issues/356
						try {
							// Attempt to create a new folder on the configured parent driveId & parent id
							response = onedrive.createById(parent.driveId, parent.id, driveItem);
						} catch (OneDriveException e) {
							if (e.httpStatusCode == 409) {
								// OneDrive API returned a 404 (above) to say the directory did not exist
								// but when we attempted to create it, OneDrive responded that it now already exists
								log.vlog("OneDrive reported that ", path, " already exists .. OneDrive API race condition");
								return;
							} else {
								// some other error from OneDrive was returned - display what it is
								log.error("OneDrive generated an error when creating this path: ", path);
								displayOneDriveErrorMessage(e.msg);
								return;
							}
						}
						// Is the response a valid JSON object - validation checking done in saveItem
						saveItem(response);
					} else {
						// Simulate a successful 'directory create' & save it to the dryRun database copy
						// The simulated response has to pass 'makeItem' as part of saveItem
						auto fakeResponse = createFakeResponse(path);
						saveItem(fakeResponse);
					}
						
					log.vlog("Successfully created the remote directory ", path, " on OneDrive");
					return;
				}
				
				if (e.httpStatusCode == 429) {
					// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
					handleOneDriveThrottleRequest();
					// Retry original request by calling function again to avoid replicating any further error handling
					log.vdebug("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - calling uploadCreateDir(path);");
					uploadCreateDir(path);
					// return back to original call
					return;
				}
				
				if (e.httpStatusCode >= 500) {
					// OneDrive returned a 'HTTP 5xx Server Side Error' - gracefully handling error - error message already logged
					return;
				}
			} 
			
			// response from OneDrive has to be a valid JSON object
			if (response.type() == JSONType.object){
				// https://docs.microsoft.com/en-us/windows/desktop/FileIO/naming-a-file
				// Do not assume case sensitivity. For example, consider the names OSCAR, Oscar, and oscar to be the same, 
				// even though some file systems (such as a POSIX-compliant file system) may consider them as different. 
				// Note that NTFS supports POSIX semantics for case sensitivity but this is not the default behavior.
				
				if (response["name"].str == baseName(path)){
					// OneDrive 'name' matches local path name
					log.vlog("The requested directory to create was found on OneDrive - skipping creating the directory: ", path );
					// Check that this path is in the database
					if (!itemdb.selectById(parent.driveId, parent.id, parent)){
						// parent for 'path' is NOT in the database
						log.vlog("The parent for this path is not in the local database - need to add parent to local database");
						parentPath = dirName(path);
						uploadCreateDir(parentPath);
					} else {
						// parent is in database
						log.vlog("The parent for this path is in the local database - adding requested path (", path ,") to database");
						
						// are we in a --dry-run scenario?
						if (!dryRun) {
							// get the live data
							auto res = onedrive.getPathDetails(path);
							// Is the response a valid JSON object - validation checking done in saveItem
							saveItem(res);
						} else {
							// need to fake this data
							auto fakeResponse = createFakeResponse(path);
							saveItem(fakeResponse);
						}
					}
				} else {
					// They are the "same" name wise but different in case sensitivity
					log.error("ERROR: Current directory has a 'case-insensitive match' to an existing directory on OneDrive");
					log.error("ERROR: To resolve, rename this local directory: ", buildNormalizedPath(absolutePath(path)));
					log.error("ERROR: Remote OneDrive directory: ", response["name"].str);
					log.log("Skipping: ", buildNormalizedPath(absolutePath(path)));
					return;
				}
			} else {
				// response is not valid JSON, an error was returned from OneDrive
				log.error("ERROR: There was an error performing this operation on OneDrive");
				log.error("ERROR: Increase logging verbosity to assist determining why.");
				log.log("Skipping: ", buildNormalizedPath(absolutePath(path)));
				return;
			}
		}
	}
	
	// upload a new file to OneDrive
	private void uploadNewFile(const(string) path)
	{
		// Reset upload failure - OneDrive or filesystem issue (reading data)
		uploadFailed = false;
	
		Item parent;
		bool parentPathFoundInDB = false;
		// Check the database for the parent path
		// What parent path to use?
		string parentPath = dirName(path);		// will be either . or something else
		if (parentPath == "."){
			// Assume this is a new file in the users configured sync_dir root
			// Use client defaults
			parent.id = defaultRootId;  // Should give something like 12345ABCDE1234A1!101
			parent.driveId = defaultDriveId;  // Should give something like 12345abcde1234a1
			parentPathFoundInDB = true;
		} else {
			// Query the database using each of the driveId's we are using
			foreach (driveId; driveIDsArray) {
				// Query the database for this parent path using each driveId
				Item dbResponse;
				if(itemdb.selectByPathWithRemote(parentPath, driveId, dbResponse)){
					// parent path was found in the database
					parent = dbResponse;
					parentPathFoundInDB = true;
				}
			}
		}
				
		// If performing a dry-run or parent path is found in the database
		if ((dryRun) || (parentPathFoundInDB)) {
			// Maximum file size upload
			//	https://support.microsoft.com/en-au/help/3125202/restrictions-and-limitations-when-you-sync-files-and-folders
			//	1. OneDrive Business say's 15GB
			//	2. Another article updated April 2018 says 20GB:
			//		https://answers.microsoft.com/en-us/onedrive/forum/odoptions-oddesktop-sdwin10/personal-onedrive-file-upload-size-max/a3621fc9-b766-4a99-99f8-bcc01ccb025f
			
			// Use smaller size for now
			auto maxUploadFileSize = 16106127360; // 15GB
			//auto maxUploadFileSize = 21474836480; // 20GB
			auto thisFileSize = getSize(path);
			// To avoid a 409 Conflict error - does the file actually exist on OneDrive already?
			JSONValue fileDetailsFromOneDrive;
			
			// Can we read the file - as a permissions issue or file corruption will cause a failure
			// https://github.com/abraunegg/onedrive/issues/113
			if (readLocalFile(path)){
				// able to read the file
				if (thisFileSize <= maxUploadFileSize){
					// Resolves: https://github.com/skilion/onedrive/issues/121, https://github.com/skilion/onedrive/issues/294, https://github.com/skilion/onedrive/issues/329
					// Does this 'file' already exist on OneDrive?
					try {
						// test if the local path exists on OneDrive
						fileDetailsFromOneDrive = onedrive.getPathDetails(path);
					} catch (OneDriveException e) {
						log.vdebug("fileDetailsFromOneDrive = onedrive.getPathDetails(path); generated a OneDriveException");
						if (e.httpStatusCode == 401) {
							// OneDrive returned a 'HTTP/1.1 401 Unauthorized Error'
							log.vlog("Skipping item - OneDrive returned a 'HTTP 401 - Unauthorized' when attempting to query if file exists");
							return;
						}
					
						if (e.httpStatusCode == 404) {
							// The file was not found on OneDrive, need to upload it		
							// Check if file should be skipped based on skip_size config
							if (thisFileSize >= this.newSizeLimit) {
								log.vlog("Skipping item - excluded by skip_size config: ", path, " (", thisFileSize/2^^20," MB)");
								return;
							}
							write("Uploading new file ", path, " ... ");
							JSONValue response;
							
							if (!dryRun) {
								// Resolve https://github.com/abraunegg/onedrive/issues/37
								if (thisFileSize == 0){
									// We can only upload zero size files via simpleFileUpload regardless of account type
									// https://github.com/OneDrive/onedrive-api-docs/issues/53
									try {
										response = onedrive.simpleUpload(path, parent.driveId, parent.id, baseName(path));
									} catch (OneDriveException e) {
										// error uploading file
										if (e.httpStatusCode == 401) {
											// OneDrive returned a 'HTTP/1.1 401 Unauthorized Error' - file failed to be uploaded
											writeln("skipped.");
											log.vlog("OneDrive returned a 'HTTP 401 - Unauthorized' - gracefully handling error");
											uploadFailed = true;
											return;
										}
										if (e.httpStatusCode == 429) {
											// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
											handleOneDriveThrottleRequest();
											// Retry original request by calling function again to avoid replicating any further error handling
											uploadNewFile(path);
											// return back to original call
											return;
										}
										if (e.httpStatusCode == 504) {
											// HTTP request returned status code 504 (Gateway Timeout)
											log.log("OneDrive returned a 'HTTP 504 - Gateway Timeout' - retrying upload request");
											// Retry original request by calling function again to avoid replicating any further error handling
											uploadNewFile(path);
											// return back to original call
											return;
										} else {
											// display what the error is
											writeln("skipped.");
											displayOneDriveErrorMessage(e.msg);
											uploadFailed = true;
											return;
										}
									} catch (FileException e) {
										// display the error message
										writeln("skipped.");
										displayFileSystemErrorMessage(e.msg);
										uploadFailed = true;
										return;
									}
								} else {
									// File is not a zero byte file
									// Are we using OneDrive Personal or OneDrive Business?
									// To solve 'Multiple versions of file shown on website after single upload' (https://github.com/abraunegg/onedrive/issues/2)
									// check what 'account type' this is as this issue only affects OneDrive Business so we need some extra logic here
									if (accountType == "personal"){
										// Original file upload logic
										if (thisFileSize <= thresholdFileSize) {
											try {
												response = onedrive.simpleUpload(path, parent.driveId, parent.id, baseName(path));
											} catch (OneDriveException e) {
												if (e.httpStatusCode == 401) {
													// OneDrive returned a 'HTTP/1.1 401 Unauthorized Error' - file failed to be uploaded
													writeln("skipped.");
													log.vlog("OneDrive returned a 'HTTP 401 - Unauthorized' - gracefully handling error");
													uploadFailed = true;
													return;
												}
												
												if (e.httpStatusCode == 429) {
													// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
													handleOneDriveThrottleRequest();
													// Retry original request by calling function again to avoid replicating any further error handling
													uploadNewFile(path);
													// return back to original call
													return;
												}
												
												if (e.httpStatusCode == 504) {
													// HTTP request returned status code 504 (Gateway Timeout)
													log.log("OneDrive returned a 'HTTP 504 - Gateway Timeout' - retrying upload request as a session");
													// Try upload as a session
													try {
														response = session.upload(path, parent.driveId, parent.id, baseName(path));
													} catch (OneDriveException e) {
														// error uploading file
														if (e.httpStatusCode == 429) {
															// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
															handleOneDriveThrottleRequest();
															// Retry original request by calling function again to avoid replicating any further error handling
															uploadNewFile(path);
															// return back to original call
															return;
														} else {
															// display what the error is
															writeln("skipped.");
															displayOneDriveErrorMessage(e.msg);
															uploadFailed = true;
															return;
														}
													}
												} else {
													// display what the error is
													writeln("skipped.");
													displayOneDriveErrorMessage(e.msg);
													uploadFailed = true;
													return;
												}
											} catch (FileException e) {
												// display the error message
												writeln("skipped.");
												displayFileSystemErrorMessage(e.msg);
												uploadFailed = true;
												return;
											}
										} else {
											// File larger than threshold - use a session to upload
											writeln("");
											try {
												response = session.upload(path, parent.driveId, parent.id, baseName(path));
											} catch (OneDriveException e) {
												if (e.httpStatusCode == 401) {
													// OneDrive returned a 'HTTP/1.1 401 Unauthorized Error' - file failed to be uploaded
													writeln("skipped.");
													log.vlog("OneDrive returned a 'HTTP 401 - Unauthorized' - gracefully handling error");
													uploadFailed = true;
													return;
												}	
												if (e.httpStatusCode == 429) {
													// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
													handleOneDriveThrottleRequest();
													// Retry original request by calling function again to avoid replicating any further error handling
													uploadNewFile(path);
													// return back to original call
													return;
												} 
												if (e.httpStatusCode == 504) {
													// HTTP request returned status code 504 (Gateway Timeout)
													log.log("OneDrive returned a 'HTTP 504 - Gateway Timeout' - retrying upload request");
													// Retry original request by calling function again to avoid replicating any further error handling
													uploadNewFile(path);
													// return back to original call
													return;
												} else {
													// display what the error is
													writeln("skipped.");
													displayOneDriveErrorMessage(e.msg);
													uploadFailed = true;
													return;
												}
											} catch (FileException e) {
												// display the error message
												writeln("skipped.");
												displayFileSystemErrorMessage(e.msg);
												uploadFailed = true;
												return;
											}
										}
									} else {
										// OneDrive Business Account - always use a session to upload
										writeln("");
										try {
											response = session.upload(path, parent.driveId, parent.id, baseName(path));
										} catch (OneDriveException e) {
											if (e.httpStatusCode == 401) {
												// OneDrive returned a 'HTTP/1.1 401 Unauthorized Error' - file failed to be uploaded
												writeln("skipped.");
												log.vlog("OneDrive returned a 'HTTP 401 - Unauthorized' - gracefully handling error");
												uploadFailed = true;
												return;
											}	
											if (e.httpStatusCode == 429) {
												// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
												handleOneDriveThrottleRequest();
												// Retry original request by calling function again to avoid replicating any further error handling
												uploadNewFile(path);
												// return back to original call
												return;
											}
											if (e.httpStatusCode == 504) {
												// HTTP request returned status code 504 (Gateway Timeout)
												log.log("OneDrive returned a 'HTTP 504 - Gateway Timeout' - retrying upload request");
												// Retry original request by calling function again to avoid replicating any further error handling
												uploadNewFile(path);
												// return back to original call
												return;
											} else {
												// display what the error is
												writeln("skipped.");
												displayOneDriveErrorMessage(e.msg);
												uploadFailed = true;
												return;
											}
										} catch (FileException e) {
											// display the error message
											writeln("skipped.");
											displayFileSystemErrorMessage(e.msg);
											uploadFailed = true;
											return;
										}
									}
								}
								
								// response from OneDrive has to be a valid JSON object
								if (response.type() == JSONType.object){
									// upload done without error
									writeln("done.");
									// Log action to log file
									log.fileOnly("Uploading new file ", path, " ... done.");
									// The file was uploaded, or a 4xx / 5xx error was generated
									if ("size" in response){
										// The response JSON contains size, high likelihood valid response returned 
										ulong uploadFileSize = response["size"].integer;
										
										// In some cases the file that was uploaded was not complete, but 'completed' without errors on OneDrive
										// This has been seen with PNG / JPG files mainly, which then contributes to generating a 412 error when we attempt to update the metadata
										// Validate here that the file uploaded, at least in size, matches in the response to what the size is on disk
										if (thisFileSize != uploadFileSize){
											if(disableUploadValidation){
												// Print a warning message
												log.log("WARNING: Uploaded file size does not match local file - skipping upload validation");
											} else {
												// OK .. the uploaded file does not match and we did not disable this validation
												log.log("Uploaded file size does not match local file - upload failure - retrying");
												// Delete uploaded bad file
												onedrive.deleteById(response["parentReference"]["driveId"].str, response["id"].str, response["eTag"].str);
												// Re-upload
												uploadNewFile(path);
												return;
											}
										} 
										
										// File validation is OK
										if ((accountType == "personal") || (thisFileSize == 0)){
											// Update the item's metadata on OneDrive
											string id = response["id"].str;
											string cTag; 
											
											// Is there a valid cTag in the response?
											if ("cTag" in response) {
												// use the cTag instead of the eTag because OneDrive may update the metadata of files AFTER they have been uploaded
												cTag = response["cTag"].str;
											} else {
												// Is there an eTag in the response?
												if ("eTag" in response) {
													// use the eTag from the response as there was no cTag
													cTag = response["eTag"].str;
												} else {
													// no tag available - set to nothing
													cTag = "";
												}
											}
											
											if (exists(path)) {
												SysTime mtime = timeLastModified(path).toUTC();
												uploadLastModifiedTime(parent.driveId, id, cTag, mtime);
											} else {
												// will be removed in different event!
												log.log("File disappeared after upload: ", path);
											}
											return;
										} else {
											// OneDrive Business Account - always use a session to upload
											// The session includes a Request Body element containing lastModifiedDateTime
											// which negates the need for a modify event against OneDrive
											// Is the response a valid JSON object - validation checking done in saveItem
											saveItem(response);
											return;
										}
									}
								} else {
									// response is not valid JSON, an error was returned from OneDrive
									log.fileOnly("Uploading new file ", path, " ... error");
									uploadFailed = true;
									return;
								}
							} else {
								// we are --dry-run - simulate the file upload
								writeln("done.");
								response = createFakeResponse(path);
								// Log action to log file
								log.fileOnly("Uploading new file ", path, " ... done.");
								// Is the response a valid JSON object - validation checking done in saveItem
								saveItem(response);
								return;
							}
						}

						if (e.httpStatusCode == 429) {
							// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
							handleOneDriveThrottleRequest();
							// Retry original request by calling function again to avoid replicating any further error handling
							log.vdebug("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - calling uploadNewFile(path);");
							uploadNewFile(path);
							// return back to original call
							return;
						}
					
						if (e.httpStatusCode >= 500) {
							// OneDrive returned a 'HTTP 5xx Server Side Error' - gracefully handling error - error message already logged
							uploadFailed = true;
							return;
						}
					}
					
					// Check that the filename that is returned is actually the file we wish to upload
					// https://docs.microsoft.com/en-us/windows/desktop/FileIO/naming-a-file
					// Do not assume case sensitivity. For example, consider the names OSCAR, Oscar, and oscar to be the same, 
					// even though some file systems (such as a POSIX-compliant file system) may consider them as different. 
					// Note that NTFS supports POSIX semantics for case sensitivity but this is not the default behavior.
					
					// fileDetailsFromOneDrive has to be a valid object
					if (fileDetailsFromOneDrive.type() == JSONType.object){
						// Check that 'name' is in the JSON response (validates data) and that 'name' == the path we are looking for
						if (("name" in fileDetailsFromOneDrive) && (fileDetailsFromOneDrive["name"].str == baseName(path))) {
							// OneDrive 'name' matches local path name
							log.vlog("Requested file to upload exists on OneDrive - local database is out of sync for this file: ", path);
							
							// Is the local file newer than the uploaded file?
							SysTime localFileModifiedTime = timeLastModified(path).toUTC();
							SysTime remoteFileModifiedTime = SysTime.fromISOExtString(fileDetailsFromOneDrive["fileSystemInfo"]["lastModifiedDateTime"].str);
							localFileModifiedTime.fracSecs = Duration.zero;
							
							if (localFileModifiedTime > remoteFileModifiedTime){
								// local file is newer
								log.vlog("Requested file to upload is newer than existing file on OneDrive");
								write("Uploading modified file ", path, " ... ");
								JSONValue response;
								
								if (!dryRun) {
									if (accountType == "personal"){
										// OneDrive Personal account upload handling
										if (thisFileSize <= thresholdFileSize) {
											try {
												response = onedrive.simpleUpload(path, parent.driveId, parent.id, baseName(path));
												writeln("done.");
											} catch (OneDriveException e) {
												log.vdebug("response = onedrive.simpleUpload(path, parent.driveId, parent.id, baseName(path)); generated a OneDriveException");
												if (e.httpStatusCode == 401) {
													// OneDrive returned a 'HTTP/1.1 401 Unauthorized Error' - file failed to be uploaded
													writeln("skipped.");
													log.vlog("OneDrive returned a 'HTTP 401 - Unauthorized' - gracefully handling error");
													uploadFailed = true;
													return;
												}
												
												if (e.httpStatusCode == 429) {
													// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
													handleOneDriveThrottleRequest();
													// Retry original request by calling function again to avoid replicating any further error handling
													log.vdebug("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - calling uploadNewFile(path);");
													uploadNewFile(path);
													// return back to original call
													return;
												}
												
												if (e.httpStatusCode == 504) {
													// HTTP request returned status code 504 (Gateway Timeout)
													log.log("OneDrive returned a 'HTTP 504 - Gateway Timeout' - retrying upload request as a session");
													// Try upload as a session
													try {
														response = session.upload(path, parent.driveId, parent.id, baseName(path));
														writeln("done.");
													} catch (OneDriveException e) {
														if (e.httpStatusCode == 429) {
															// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
															handleOneDriveThrottleRequest();
															// Retry original request by calling function again to avoid replicating any further error handling
															uploadNewFile(path);
															// return back to original call
															return;
														} else {
															// error uploading file
															// display what the error is
															writeln("skipped.");
															displayOneDriveErrorMessage(e.msg);
															uploadFailed = true;
															return;
														}
													}
												} else {
													// display what the error is
													writeln("skipped.");
													displayOneDriveErrorMessage(e.msg);
													uploadFailed = true;
													return;
												}
											} catch (FileException e) {
												// display the error message
												writeln("skipped.");
												displayFileSystemErrorMessage(e.msg);
												uploadFailed = true;
												return;
											}
										} else {
											// File larger than threshold - use a session to upload
											writeln("");
											try {
												response = session.upload(path, parent.driveId, parent.id, baseName(path));
												writeln("done.");
											} catch (OneDriveException e) {
												log.vdebug("response = session.upload(path, parent.driveId, parent.id, baseName(path)); generated a OneDriveException");
												if (e.httpStatusCode == 401) {
													// OneDrive returned a 'HTTP/1.1 401 Unauthorized Error' - file failed to be uploaded
													writeln("skipped.");
													log.vlog("OneDrive returned a 'HTTP 401 - Unauthorized' - gracefully handling error");
													uploadFailed = true;
													return;
												}
												if (e.httpStatusCode == 429) {
													// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
													handleOneDriveThrottleRequest();
													// Retry original request by calling function again to avoid replicating any further error handling
													log.vdebug("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - calling uploadNewFile(path);");
													uploadNewFile(path);
													// return back to original call
													return;
												} 
												if (e.httpStatusCode == 504) {
													// HTTP request returned status code 504 (Gateway Timeout)
													log.log("OneDrive returned a 'HTTP 504 - Gateway Timeout' - retrying upload request");
													// Retry original request by calling function again to avoid replicating any further error handling
													uploadNewFile(path);
													// return back to original call
													return;
												} else {
													// error uploading file
													// display what the error is
													writeln("skipped.");
													displayOneDriveErrorMessage(e.msg);
													uploadFailed = true;
													return;
												}
											} catch (FileException e) {
												// display the error message
												writeln("skipped.");
												displayFileSystemErrorMessage(e.msg);
												uploadFailed = true;
												return;
											}
										}
										
										// response from OneDrive has to be a valid JSON object
										if (response.type() == JSONType.object){
											// response is a valid JSON object
											string id = response["id"].str;
											string cTag;
										
											// Is there a valid cTag in the response?
											if ("cTag" in response) {
												// use the cTag instead of the eTag because Onedrive may update the metadata of files AFTER they have been uploaded
												cTag = response["cTag"].str;
											} else {
												// Is there an eTag in the response?
												if ("eTag" in response) {
													// use the eTag from the response as there was no cTag
													cTag = response["eTag"].str;
												} else {
													// no tag available - set to nothing
													cTag = "";
												}
											}
											// validate if path exists so mtime can be calculated
											if (exists(path)) {
												SysTime mtime = timeLastModified(path).toUTC();
												uploadLastModifiedTime(parent.driveId, id, cTag, mtime);
											} else {
												// will be removed in different event!
												log.log("File disappeared after upload: ", path);
											}
										} else {
											// Log that an invalid JSON object was returned
											log.vdebug("onedrive.simpleUpload or session.upload call returned an invalid JSON Object");
											return;
										}
									} else {
										// OneDrive Business account modified file upload handling
										if (accountType == "business"){
											// OneDrive Business Account - always use a session to upload
											writeln("");
											try {
												response = session.upload(path, parent.driveId, parent.id, baseName(path), fileDetailsFromOneDrive["eTag"].str);
											} catch (OneDriveException e) {
												log.vdebug("response = session.upload(path, parent.driveId, parent.id, baseName(path), fileDetailsFromOneDrive['eTag'].str); generated a OneDriveException");
												if (e.httpStatusCode == 401) {
													// OneDrive returned a 'HTTP/1.1 401 Unauthorized Error' - file failed to be uploaded
													writeln("skipped.");
													log.vlog("OneDrive returned a 'HTTP 401 - Unauthorized' - gracefully handling error");
													uploadFailed = true;
													return;
												}
												if (e.httpStatusCode == 429) {
													// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
													handleOneDriveThrottleRequest();
													// Retry original request by calling function again to avoid replicating any further error handling
													log.vdebug("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - calling uploadNewFile(path);");
													uploadNewFile(path);
													// return back to original call
													return;
												} 
												if (e.httpStatusCode == 504) {
													// HTTP request returned status code 504 (Gateway Timeout)
													log.log("OneDrive returned a 'HTTP 504 - Gateway Timeout' - retrying upload request");
													// Retry original request by calling function again to avoid replicating any further error handling
													uploadNewFile(path);
													// return back to original call
													return;
												} else {
													// error uploading file
													// display what the error is
													writeln("skipped.");
													displayOneDriveErrorMessage(e.msg);
													uploadFailed = true;
													return;
												}
											} catch (FileException e) {
												// display the error message
												writeln("skipped.");
												displayFileSystemErrorMessage(e.msg);
												uploadFailed = true;
												return;
											}
											// upload complete
											writeln("done.");
											saveItem(response);
										}
										
										// OneDrive SharePoint account modified file upload handling
										if (accountType == "documentLibrary"){
											// Depending on the file size, this will depend on how best to handle the modified local file
											// as if too large, the following error will be generated by OneDrive:
											//     HTTP request returned status code 413 (Request Entity Too Large)
											// We also cant use a session to upload the file, we have to use simpleUploadReplace
											
											if (getSize(path) <= thresholdFileSize) {
												// Upload file via simpleUploadReplace as below threshold size
												try {
													response = onedrive.simpleUploadReplace(path, fileDetailsFromOneDrive["parentReference"]["driveId"].str, fileDetailsFromOneDrive["id"].str, fileDetailsFromOneDrive["eTag"].str);
												} catch (OneDriveException e) {
													if (e.httpStatusCode == 401) {
														// OneDrive returned a 'HTTP/1.1 401 Unauthorized Error' - file failed to be uploaded
														writeln("skipped.");
														log.vlog("OneDrive returned a 'HTTP 401 - Unauthorized' - gracefully handling error");
														uploadFailed = true;
														return;
													} else {
														// display what the error is
														writeln("skipped.");
														displayOneDriveErrorMessage(e.msg);
														uploadFailed = true;
														return;
													}
												} catch (FileException e) {
													// display the error message
													writeln("skipped.");
													displayFileSystemErrorMessage(e.msg);
													uploadFailed = true;
													return;
												}
											} else {
												// Have to upload via a session, however we have to delete the file first otherwise this will generate a 404 error post session upload
												// Remove the existing file
												onedrive.deleteById(fileDetailsFromOneDrive["parentReference"]["driveId"].str, fileDetailsFromOneDrive["id"].str, fileDetailsFromOneDrive["eTag"].str);	
												// Upload as a session, as a new file
												writeln("");
												try {
													response = session.upload(path, parent.driveId, parent.id, baseName(path));
												} catch (OneDriveException e) {
													if (e.httpStatusCode == 401) {
														// OneDrive returned a 'HTTP/1.1 401 Unauthorized Error' - file failed to be uploaded
														writeln("skipped.");
														log.vlog("OneDrive returned a 'HTTP 401 - Unauthorized' - gracefully handling error");
														uploadFailed = true;
														return;
													} else {
														// display what the error is
														writeln("skipped.");
														displayOneDriveErrorMessage(e.msg);
														uploadFailed = true;
														return;
													}
												} catch (FileException e) {
													// display the error message
													writeln("skipped.");
													displayFileSystemErrorMessage(e.msg);
													uploadFailed = true;
													return;
												}
											}
											writeln(" done.");
											// Is the response a valid JSON object - validation checking done in saveItem
											saveItem(response);
											// Due to https://github.com/OneDrive/onedrive-api-docs/issues/935 Microsoft modifies all PDF, MS Office & HTML files with added XML content. It is a 'feature' of SharePoint.
											// So - now the 'local' and 'remote' file is technically DIFFERENT ... thanks Microsoft .. NO way to disable this stupidity
											if(!uploadOnly){
												// Download the Microsoft 'modified' file so 'local' is now in sync
												log.vlog("Due to Microsoft Sharepoint 'enrichment' of files, downloading 'enriched' file to ensure local file is in-sync");
												log.vlog("See: https://github.com/OneDrive/onedrive-api-docs/issues/935 for further details");
												auto fileSize = response["size"].integer;
												onedrive.downloadById(response["parentReference"]["driveId"].str, response["id"].str, path, fileSize);
											} else {
												// we are not downloading a file, warn that file differences will exist
												log.vlog("WARNING: Due to Microsoft Sharepoint 'enrichment' of files, this file is now technically different to your local copy");
												log.vlog("See: https://github.com/OneDrive/onedrive-api-docs/issues/935 for further details");
											}
										}
									}
								} else {
									// we are --dry-run - simulate the file upload
									writeln("done.");
									response = createFakeResponse(path);
									// Log action to log file
									log.fileOnly("Uploading modified file ", path, " ... done.");
									// Is the response a valid JSON object - validation checking done in saveItem
									saveItem(response);
									return;
								}
								
								// Log action to log file
								log.fileOnly("Uploading modified file ", path, " ... done.");
							} else {
								// Save the details of the file that we got from OneDrive
								// --dry-run safe
								log.vlog("Updating the local database with details for this file: ", path);
								if (!dryRun) {
									// use the live data
									saveItem(fileDetailsFromOneDrive);
								} else {
									// need to fake this data
									auto fakeResponse = createFakeResponse(path);
									saveItem(fakeResponse);
								}
							}
						} else {
							// The files are the "same" name wise but different in case sensitivity
							log.error("ERROR: A local file has the same name as another local file.");
							log.error("ERROR: To resolve, rename this local file: ", buildNormalizedPath(absolutePath(path)));
							log.log("Skipping uploading this new file: ", buildNormalizedPath(absolutePath(path)));
						}
					} else {
						// fileDetailsFromOneDrive is not valid JSON, an error was returned from OneDrive
						log.error("ERROR: An error was returned from OneDrive and the resulting response is not a valid JSON object");
						log.error("ERROR: Increase logging verbosity to assist determining why.");
						uploadFailed = true;
						return;
					}
				} else {
					// Skip file - too large
					log.log("Skipping uploading this new file as it exceeds the maximum size allowed by OneDrive: ", path);
					uploadFailed = true;
					return;
				}
			}
		} else {
			log.log("Skipping uploading this new file as parent path is not in the database: ", path);
			uploadFailed = true;
			return;
		}
	}

	// delete an item on OneDrive
	private void uploadDeleteItem(Item item, const(string) path)
	{
		log.log("Deleting item from OneDrive: ", path);
		bool flagAsBigDelete = false;
		
		// query the database - how many objects will this remove?
		auto children = getChildren(item.driveId, item.id);
		long itemsToDelete = count(children);
		
		// Are we running in monitor mode? A local delete of a file will issue a inotify event, which will trigger the local & remote data immediately
		if (!cfg.getValueBool("monitor")) {
			// not running in monitor mode
			if (itemsToDelete > cfg.getValueLong("classify_as_big_delete")) {
				// A big delete detected
				flagAsBigDelete = true;
				if (!cfg.getValueBool("force")) {
					log.error("ERROR: An attempt to remove a large volume of data from OneDrive has been detected. Exiting client to preserve data on OneDrive");
					log.error("ERROR: To delete delete a large volume of data use --force or increase the config value 'classify_as_big_delete' to a larger value");
					// Must exit here to preserve data on OneDrive
					exit(-1);
				}
			}
		}
		
		if (!dryRun) {
			// we are not in a --dry-run situation, process deletion to OneDrive
			if ((item.driveId == "") && (item.id == "") && (item.eTag == "")){
				// These are empty ... we cannot delete if this is empty ....
				log.vdebug("item.driveId, item.id & item.eTag are empty ... need to query OneDrive for values");
				log.vdebug("Checking OneDrive for path: ", path);
				JSONValue onedrivePathDetails = onedrive.getPathDetails(path); // Returns a JSON String for the OneDrive Path
				log.vdebug("OneDrive path details: ", onedrivePathDetails);
				item.driveId = onedrivePathDetails["parentReference"]["driveId"].str; // Should give something like 12345abcde1234a1
				item.id = onedrivePathDetails["id"].str; // This item's ID. Should give something like 12345ABCDE1234A1!101
				item.eTag = onedrivePathDetails["eTag"].str; // Should be something like aNjM2NjJFRUVGQjY2NjJFMSE5MzUuMA
			}
			
			//	do the delete
			try {
				onedrive.deleteById(item.driveId, item.id, item.eTag);
			} catch (OneDriveException e) {
				if (e.httpStatusCode == 404) {
					// item.id, item.eTag could not be found on driveId
					log.vlog("OneDrive reported: The resource could not be found.");
				} else {
					// Not a 404 response .. is this a 403 response due to OneDrive Business Retention Policy being enabled?
					if ((e.httpStatusCode == 403) && (accountType != "personal")) {
						auto errorArray = splitLines(e.msg);
						JSONValue errorMessage = parseJSON(replace(e.msg, errorArray[0], ""));
						if (errorMessage["error"]["message"].str == "Request was cancelled by event received. If attempting to delete a non-empty folder, it's possible that it's on hold") {
							// Issue #338 - Unable to delete OneDrive content when OneDrive Business Retention Policy is enabled
							try {
								foreach_reverse (Item child; children) {
									onedrive.deleteById(child.driveId, child.id, child.eTag);
									// delete the child reference in the local database
									itemdb.deleteById(child.driveId, child.id);
								}
								onedrive.deleteById(item.driveId, item.id, item.eTag);
							} catch (OneDriveException e) {
								// display what the error is
								displayOneDriveErrorMessage(e.msg);
								return;
							}
						}
					} else {
						// Not a 403 response & OneDrive Business Account / O365 Shared Folder / Library
						// display what the error is
						displayOneDriveErrorMessage(e.msg);
						return;
					}
				}
			}
			
			// delete the reference in the local database
			itemdb.deleteById(item.driveId, item.id);
			if (item.remoteId != null) {
				// If the item is a remote item, delete the reference in the local database
				itemdb.deleteById(item.remoteDriveId, item.remoteId);
			}
		}
	}

	// get the children of an item id from the database
	private Item[] getChildren(string driveId, string id)
	{
		Item[] children;
		children ~= itemdb.selectChildren(driveId, id);
		foreach (Item child; children) {
			if (child.type != ItemType.file) {
				// recursively get the children of this child
				children ~= getChildren(child.driveId, child.id);
			}
		}
		return children;
	}

	// update the item's last modified time
	private void uploadLastModifiedTime(const(char)[] driveId, const(char)[] id, const(char)[] eTag, SysTime mtime)
	{
		string itemModifiedTime;
		itemModifiedTime = mtime.toISOExtString();
		JSONValue data = [
			"fileSystemInfo": JSONValue([
				"lastModifiedDateTime": itemModifiedTime
			])
		];
		
		JSONValue response;
		try {
			response = onedrive.updateById(driveId, id, data, eTag);
		} catch (OneDriveException e) {
			if (e.httpStatusCode == 412) {
				// OneDrive threw a 412 error, most likely: ETag does not match current item's value
				// Retry without eTag
				log.vdebug("File Metadata Update Failed - OneDrive eTag / cTag match issue");
				log.vlog("OneDrive returned a 'HTTP 412 - Precondition Failed' when attempting file time stamp update - gracefully handling error");
				string nullTag = null;
				response = onedrive.updateById(driveId, id, data, nullTag);
			}
		} 
		// save the updated response from OneDrive in the database
		// Is the response a valid JSON object - validation checking done in saveItem
		saveItem(response);
	}

	// save item details into database
	private void saveItem(JSONValue jsonItem)
	{
		// jsonItem has to be a valid object
		if (jsonItem.type() == JSONType.object){
			// Check if the response JSON has an 'id', otherwise makeItem() fails with 'Key not found: id'
			if (hasId(jsonItem)) {
				// Takes a JSON input and formats to an item which can be used by the database
				Item item = makeItem(jsonItem);
				// Add to the local database
				log.vdebug("Adding to database: ", item);
				itemdb.upsert(item);
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

	// Parse and display error message received from OneDrive
	private void displayOneDriveErrorMessage(string message)
	{
		log.error("\nERROR: OneDrive returned an error with the following message:");
		auto errorArray = splitLines(message);
		log.error("  Error Message: ", errorArray[0]);
		// extract 'message' as the reason
		JSONValue errorMessage = parseJSON(replace(message, errorArray[0], ""));
		string errorReason = errorMessage["error"]["message"].str;
		// display reason
		if (errorReason.startsWith("<!DOCTYPE")) {
			// a HTML Error Reason was given
			log.error("  Error Reason:  A HTML Error response was provided. Use debug logging (--verbose --verbose) to view.");
			log.vdebug(errorReason);
		} else {
			// a non HTML Error Reason was given
			log.error("  Error Reason:  ", errorReason);
		}
	}
	
	// Parse and display error message received from the local file system
	private void displayFileSystemErrorMessage(string message) 
	{
		log.error("ERROR: The local file system returned an error with the following message:");
		auto errorArray = splitLines(message);
		log.error("  Error Message: ", errorArray[0]);
	}
	
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_move
	// This function is only called in monitor mode when an move event is coming from
	// inotify and we try to move the item.
	void uploadMoveItem(string from, string to)
	{
		log.log("Moving ", from, " to ", to);
		
		// 'to' file validation .. is the 'to' file valid for upload?
		if (isSymlink(to)) {
			// if config says so we skip all symlinked items
			if (cfg.getValueBool("skip_symlinks")) {
				log.vlog("Skipping item - skip symbolic links configured: ", to);
				return;

			}
			// skip unexisting symbolic links
			else if (!exists(readLink(to))) {
				log.log("Skipping item - invalid symbolic link: ", to);
				return;
			}
		}
		
		// Restriction and limitations about windows naming files
		if (!isValidName(to)) {
			log.log("Skipping item - invalid name (Microsoft Naming Convention): ", to);
			return;
		}
		
		// Check for bad whitespace items
		if (!containsBadWhiteSpace(to)) {
			log.log("Skipping item - invalid name (Contains an invalid whitespace item): ", to);
			return;
		}
		
		// Check for HTML ASCII Codes as part of file name
		if (!containsASCIIHTMLCodes(to)) {
			log.log("Skipping item - invalid name (Contains HTML ASCII Code): ", to);
			return;
		}
		
		// 'to' file has passed file validation
		Item fromItem, toItem, parentItem;
		if (!itemdb.selectByPath(from, defaultDriveId, fromItem)) {
			if (cfg.getValueBool("skip_dotfiles") && isDotFile(to)){	
				log.log("Skipping upload due to skip_dotfile = true");
				return;
			} else {
				uploadNewFile(to);
				return;
			}
		}
		if (fromItem.parentId == null) {
			// the item is a remote folder, need to do the operation on the parent
			enforce(itemdb.selectByPathWithRemote(from, defaultDriveId, fromItem));
		}
		if (itemdb.selectByPath(to, defaultDriveId, toItem)) {
			// the destination has been overwritten
			uploadDeleteItem(toItem, to);
		}
		if (!itemdb.selectByPath(dirName(to), defaultDriveId, parentItem)) {
			// the parent item is not in the database
			
			// is the destination a .folder that is being skipped?
			if (cfg.getValueBool("skip_dotfiles")) {
				if (isDotFile(dirName(to))) {
					// target location is a .folder
					log.vdebug("Target location is excluded from sync due to skip_dotfiles = true");
					// item will have been moved locally, but as this is now to a location that is not synced, needs to be removed from OneDrive
					log.log("Item has been moved to a location that is excluded from sync operations. Removing item from OneDrive");
					uploadDeleteItem(fromItem, from);
					return;
				}
			}
			
			// some other error
			throw new SyncException("Can't move an item to an unsynced directory");
		}
		if (cfg.getValueBool("skip_dotfiles") && isDotFile(to)){
			log.log("Removing item from OneDrive due to skip_dotfiles = true");
			uploadDeleteItem(fromItem, from);
			return;
		}
		if (fromItem.driveId != parentItem.driveId) {
			// items cannot be moved between drives
			uploadDeleteItem(fromItem, from);
			uploadNewFile(to);
		} else {
			if (!exists(to)) {
				log.vlog("uploadMoveItem target has disappeared: ", to);
				return;
			}
			SysTime mtime = timeLastModified(to).toUTC();
			JSONValue diff = [
				"name": JSONValue(baseName(to)),
				"parentReference": JSONValue([
					"id": parentItem.id
				]),
				"fileSystemInfo": JSONValue([
					"lastModifiedDateTime": mtime.toISOExtString()
				])
			];
			
			// Perform the move operation on OneDrive
			JSONValue response;
			try {
				response = onedrive.updateById(fromItem.driveId, fromItem.id, diff, fromItem.eTag);
			} catch (OneDriveException e) {
				if (e.httpStatusCode == 412) {
					// OneDrive threw a 412 error, most likely: ETag does not match current item's value
					// Retry without eTag
					log.vdebug("File Move Failed - OneDrive eTag / cTag match issue");
					log.vlog("OneDrive returned a 'HTTP 412 - Precondition Failed' when attempting to move the file - gracefully handling error");
					string nullTag = null;
					// move the file but without the eTag
					response = onedrive.updateById(fromItem.driveId, fromItem.id, diff, nullTag);
				}
			} 
			// save the move response from OneDrive in the database
			// Is the response a valid JSON object - validation checking done in saveItem
			saveItem(response);
		}
	}

	// delete an item by it's path
	void deleteByPath(const(string) path)
	{
		Item item;
		if (!itemdb.selectByPath(path, defaultDriveId, item)) {
			throw new SyncException("The item to delete is not in the local database");
		}
		if (item.parentId == null) {
			// the item is a remote folder, need to do the operation on the parent
			enforce(itemdb.selectByPathWithRemote(path, defaultDriveId, item));
		}
		try {
			if (noRemoteDelete) {
				// do not process remote delete
				log.vlog("Skipping remote delete as --upload-only & --no-remote-delete configured");
			} else {
				uploadDeleteItem(item, path);
			}
		} catch (OneDriveException e) {
			if (e.httpStatusCode == 404) {
				log.log(e.msg);
			} else {
				// display what the error is
				displayOneDriveErrorMessage(e.msg);
			}
		}
	}
	
	// move a OneDrive folder from one name to another
	void moveByPath(const(string) source, const(string) destination)
	{
		log.vlog("Moving remote folder: ", source, " -> ", destination);
		
		// Source and Destination are relative to ~/OneDrive
		string sourcePath = source;
		string destinationBasePath = dirName(destination).idup;
		
		// if destinationBasePath == '.' then destinationBasePath needs to be ""
		if (destinationBasePath == ".") {
			destinationBasePath = "";
		}
		
		string newFolderName = baseName(destination).idup;
		string destinationPathString = "/drive/root:/" ~ destinationBasePath;
		
		// Build up the JSON changes
		JSONValue moveData = ["name": newFolderName];
		JSONValue destinationPath = ["path": destinationPathString];
		moveData["parentReference"] = destinationPath;
				
		// Make the change on OneDrive
		auto res = onedrive.moveByPath(sourcePath, moveData);	
	}
	
	// Query Office 365 SharePoint Shared Library site to obtain it's Drive ID
	void querySiteCollectionForDriveID(string o365SharedLibraryName)
	{
		// Steps to get the ID:
		// 1. Query https://graph.microsoft.com/v1.0/sites?search= with the name entered
		// 2. Evaluate the response. A valid response will contain the description and the id. If the response comes back with nothing, the site name cannot be found or no access
		// 3. If valid, use the returned ID and query the site drives
		//		https://graph.microsoft.com/v1.0/sites/<site_id>/drives
		// 4. Display Shared Library Name & Drive ID
		
		string site_id;
		string drive_id;
		string webUrl;
		bool found = false;
		JSONValue siteQuery; 
		
		log.log("Office 365 Library Name Query: ", o365SharedLibraryName);
		
		try {
			siteQuery = onedrive.o365SiteSearch(encodeComponent(o365SharedLibraryName));
		} catch (OneDriveException e) {
			log.error("ERROR: Query of OneDrive for Office 365 Library Name failed");
			if (e.httpStatusCode == 403) {
				// Forbidden - most likely authentication scope needs to be updated
				log.error("ERROR: Authentication scope needs to be updated. Use --logout and re-authenticate client.");
				return;
			} else {
				// display what the error is
				displayOneDriveErrorMessage(e.msg);
				return;
			}
		}
		
		// is siteQuery a valid JSON object & contain data we can use?
		if ((siteQuery.type() == JSONType.object) && ("value" in siteQuery)) {
			// valid JSON object
			foreach (searchResult; siteQuery["value"].array) {
				// Need an 'exclusive' match here with o365SharedLibraryName as entered
				log.vdebug("Found O365 Site: ", searchResult);
				if (o365SharedLibraryName == searchResult["displayName"].str){
					// 'displayName' matches search request
					site_id = searchResult["id"].str;
					webUrl = searchResult["webUrl"].str;
					JSONValue siteDriveQuery;
					
					try {
						siteDriveQuery = onedrive.o365SiteDrives(site_id);
					} catch (OneDriveException e) {
						log.error("ERROR: Query of OneDrive for Office Site ID failed");
						// display what the error is
						displayOneDriveErrorMessage(e.msg);
						return;
					}
					
					// is siteDriveQuery a valid JSON object & contain data we can use?
					if ((siteDriveQuery.type() == JSONType.object) && ("value" in siteDriveQuery)) {
						// valid JSON object
						foreach (driveResult; siteDriveQuery["value"].array) {
							// Display results
							found = true;
							writeln("SiteName: ", searchResult["displayName"].str);
							writeln("drive_id: ", driveResult["id"].str);
							writeln("URL:      ", webUrl);
						}
					} else {
						// not a valid JSON object
						log.error("ERROR: There was an error performing this operation on OneDrive");
						log.error("ERROR: Increase logging verbosity to assist determining why.");
						return;
					}
				}
			}
			
			if(!found) {
				log.error("ERROR: This site could not be found. Please check it's name and your permissions to access the site.");
			}
		} else {
			// not a valid JSON object
			log.error("ERROR: There was an error performing this operation on OneDrive");
			log.error("ERROR: Increase logging verbosity to assist determining why.");
			return;
		}
	}
	
	// Query OneDrive for a URL path of a file
	void queryOneDriveForFileURL(string localFilePath, string syncDir)
	{
		// Query if file is valid locally
		if (exists(localFilePath)) {
			// File exists locally, does it exist in the database
			// Path needs to be relative to sync_dir path
			string relativePath = relativePath(localFilePath, syncDir);
			Item item;
			if (itemdb.selectByPath(relativePath, defaultDriveId, item)) {
				// File is in the local database cache
				JSONValue fileDetails;
		
				try {
					fileDetails = onedrive.getFileDetails(item.driveId, item.id);
				} catch (OneDriveException e) {
					// display what the error is
					displayOneDriveErrorMessage(e.msg);
					return;
				}

				if ((fileDetails.type() == JSONType.object) && ("webUrl" in fileDetails)) {
					// Valid JSON object
					writeln(fileDetails["webUrl"].str);
				}
			} else {
				// File has not been synced with OneDrive
				log.error("File has not been synced with OneDrive: ", localFilePath);
			}
		} else {
			// File does not exist locally
			log.error("File not found on local system: ", localFilePath);
		}
	}
	
	// Query the OneDrive 'drive' to determine if we are 'in sync' or if there are pending changes
	void queryDriveForChanges(const(string) path)
	{
		
		// Function variables
		int validChanges = 0;
		long downloadSize = 0;
		string driveId;
		string folderId;
		string deltaLink;
		string thisItemId;
		string thisItemPath;
		string syncFolderName;
		string syncFolderPath;
		string syncFolderChildPath;
		JSONValue changes;
		JSONValue onedrivePathDetails;
		
		// Get the path details from OneDrive
		try {
			onedrivePathDetails = onedrive.getPathDetails(path); // Returns a JSON String for the OneDrive Path
		} catch (OneDriveException e) {
			log.vdebug("onedrivePathDetails = onedrive.getPathDetails(path); generated a OneDriveException");
			if (e.httpStatusCode == 404) {
				// Requested path could not be found
				log.error("ERROR: The requested path to query was not found on OneDrive");
				return;
			}
			
			if (e.httpStatusCode == 429) {
				// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
				handleOneDriveThrottleRequest();
				// Retry original request by calling function again to avoid replicating any further error handling
				log.vdebug("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - calling queryDriveForChanges(path);");
				queryDriveForChanges(path);
				// return back to original call
				return;
			}
			
			if (e.httpStatusCode == 504) {
				// HTTP request returned status code 504 (Gateway Timeout)
				log.log("OneDrive returned a 'HTTP 504 - Gateway Timeout' - retrying request");
				// Retry original request by calling function again to avoid replicating any further error handling
				queryDriveForChanges(path);
				// return back to original call
				return;
			} else {
				// display what the error is
				displayOneDriveErrorMessage(e.msg);
				return;
			}
		} 
		
		if(isItemRemote(onedrivePathDetails)){
			// remote changes
			driveId = onedrivePathDetails["remoteItem"]["parentReference"]["driveId"].str; // Should give something like 66d53be8a5056eca
			folderId = onedrivePathDetails["remoteItem"]["id"].str; // Should give something like BC7D88EC1F539DCF!107
			syncFolderName = onedrivePathDetails["name"].str;
			// A remote drive item will not have ["parentReference"]["path"]
			syncFolderPath = "";
			syncFolderChildPath = "";
		} else {
			driveId = defaultDriveId;
			folderId = onedrivePathDetails["id"].str; // Should give something like 12345ABCDE1234A1!101
			syncFolderName = onedrivePathDetails["name"].str;
			if (hasParentReferencePath(onedrivePathDetails)) {
				syncFolderPath = onedrivePathDetails["parentReference"]["path"].str;
				syncFolderChildPath = syncFolderPath ~ "/" ~ syncFolderName ~ "/";
			} else {
				// root drive item will not have ["parentReference"]["path"] 
				syncFolderPath = "";
				syncFolderChildPath = "";
			}
		}
		
		// Query Database for the deltaLink
		deltaLink = itemdb.getDeltaLink(driveId, folderId);
		
		const(char)[] idToQuery;
		if (driveId == defaultDriveId) {
			// The drive id matches our users default drive id
			idToQuery = defaultRootId.dup;
		} else {
			// The drive id does not match our users default drive id
			// Potentially the 'path id' we are requesting the details of is a Shared Folder (remote item)
			// Use folderId
			idToQuery = folderId;
		}
		
		// Query OneDrive changes
		try {
			changes = onedrive.viewChangesByItemId(driveId, idToQuery, deltaLink);
		} catch (OneDriveException e) {
			if (e.httpStatusCode == 429) {
				// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
				handleOneDriveThrottleRequest();
				// Retry original request by calling function again to avoid replicating any further error handling
				log.vdebug("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - calling queryDriveForChanges(path);");
				queryDriveForChanges(path);
				// return back to original call
				return;
			} else {
				// OneDrive threw an error
				log.vdebug("Error query: changes = onedrive.viewChangesById(driveId, idToQuery, deltaLink)");
				log.vdebug("OneDrive threw an error when querying for these changes:");
				log.vdebug("driveId: ", driveId);
				log.vdebug("idToQuery: ", idToQuery);
				log.vdebug("deltaLink: ", deltaLink);
				displayOneDriveErrorMessage(e.msg);
				return;				
			}
		}
		
		// Are there any changes on OneDrive?
		if (count(changes["value"].array) != 0) {
			// Were we given a remote path to check if we are in sync for, or the root?
			if (path != "/") {
				// we were given a directory to check, we need to validate the list of changes against this path only
				foreach (item; changes["value"].array) {
					// Is this change valid for the 'path' we are checking?
					if (hasParentReferencePath(item)) {
						thisItemId = item["parentReference"]["id"].str;
						thisItemPath = item["parentReference"]["path"].str;
					} else {
						thisItemId = item["id"].str;
						// Is the defaultDriveId == driveId
						if (driveId == defaultDriveId){
							// 'root' items will not have ["parentReference"]["path"]
							if (isItemRoot(item)){
								thisItemPath = "";
							} else {
								thisItemPath = item["parentReference"]["path"].str;
							}
						} else {
							// A remote drive item will not have ["parentReference"]["path"]
							thisItemPath = "";
						}
					}
					
					if ( (thisItemId == folderId) || (canFind(thisItemPath, syncFolderChildPath)) || (canFind(thisItemPath, folderId)) ){
						// This is a change we want count
						validChanges++;
						if ((isItemFile(item)) && (hasFileSize(item))) {
							downloadSize = downloadSize + item["size"].integer;
						}
					}
				}
				// Are there any valid changes?
				if (validChanges != 0){
					writeln("Selected directory is out of sync with OneDrive");
					if (downloadSize > 0){
						downloadSize = downloadSize / 1000;
						writeln("Approximate data to transfer: ", downloadSize, " KB");
					}
				} else {
					writeln("No pending remote changes - selected directory is in sync");
				}
			} else {
				writeln("Local directory is out of sync with OneDrive");
				foreach (item; changes["value"].array) {
					if ((isItemFile(item)) && (hasFileSize(item))) {
						downloadSize = downloadSize + item["size"].integer;
					}
				}
				if (downloadSize > 0){
					downloadSize = downloadSize / 1000;
					writeln("Approximate data to transfer: ", downloadSize, " KB");
				}
			}
		} else {
			writeln("No pending remote changes - in sync");
		}
	}
	
	// Create a fake OneDrive response suitable for use with saveItem
	JSONValue createFakeResponse(const(string) path)
	{
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
		
		SysTime mtime = timeLastModified(path).toUTC();
		
		// real id / eTag / cTag are different format for personal / business account
		auto sha1 = new SHA1Digest();
		ubyte[] hash1 = sha1.digest(path);
		
		JSONValue fakeResponse;
		
		if (isDir(path)) {
			// path is a directory
			fakeResponse = [
							"id": JSONValue(toHexString(hash1)),
							"cTag": JSONValue(toHexString(hash1)),
							"eTag": JSONValue(toHexString(hash1)),
							"fileSystemInfo": JSONValue([
														"createdDateTime": mtime.toISOExtString(),
														"lastModifiedDateTime": mtime.toISOExtString()
														]),
							"name": JSONValue(baseName(path)),
							"parentReference": JSONValue([
														"driveId": JSONValue(defaultDriveId),
														"driveType": JSONValue(accountType),
														"id": JSONValue(defaultRootId)
														]),
							"folder": JSONValue("")
							];
		} else {
			// path is a file
			// compute file hash - both business and personal responses use quickXorHash
			string quickXorHash = computeQuickXorHash(path);
	
			fakeResponse = [
							"id": JSONValue(toHexString(hash1)),
							"cTag": JSONValue(toHexString(hash1)),
							"eTag": JSONValue(toHexString(hash1)),
							"fileSystemInfo": JSONValue([
														"createdDateTime": mtime.toISOExtString(),
														"lastModifiedDateTime": mtime.toISOExtString()
														]),
							"name": JSONValue(baseName(path)),
							"parentReference": JSONValue([
														"driveId": JSONValue(defaultDriveId),
														"driveType": JSONValue(accountType),
														"id": JSONValue(defaultRootId)
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
	
	void handleOneDriveThrottleRequest()
	{
		// If OneDrive sends a status code 429 then this function will be used to process the Retry-After response header which contains the value by which we need to wait
		log.vdebug("Handling a OneDrive HTTP 429 Response Code (Too Many Requests)");
		// Read in the Retry-After HTTP header as set and delay as per this value before retrying the request
		auto retryAfterValue = onedrive.getRetryAfterValue();
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
		onedrive.resetRetryAfterValue();
	}
	
	// Generage a /delta compatible response when using National Azure AD deployments that do not support /delta queries
	// see: https://docs.microsoft.com/en-us/graph/deployments#supported-features
	JSONValue generateDeltaResponse(const(char)[] driveId, const(char)[] idToQuery)
	{
		// JSON value which will be responded with
		JSONValue deltaResponse;
		// initial data
		JSONValue rootData;
		JSONValue driveData;
		JSONValue topLevelChildren;
		JSONValue[] childrenData;
		string nextLink;
		
		// Get drive details for the provided driveId
		try {
			driveData = onedrive.getPathDetailsById(driveId, idToQuery);
		} catch (OneDriveException e) {
			log.vdebug("driveData = onedrive.getPathDetailsById(driveId, idToQuery) generated a OneDriveException");
			// HTTP request returned status code 504 (Gateway Timeout) or 429 retry
			if ((e.httpStatusCode == 429) || (e.httpStatusCode == 504)) {
				// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
				if (e.httpStatusCode == 429) {
					log.vdebug("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - retrying applicable request");
					handleOneDriveThrottleRequest();
				}
				if (e.httpStatusCode == 504) {
					log.vdebug("Retrying original request that generated the HTTP 504 (Gateway Timeout) - retrying applicable request");
					Thread.sleep(dur!"seconds"(30));
				}
				// Retry original request by calling function again to avoid replicating any further error handling
				driveData = onedrive.getPathDetailsById(driveId, idToQuery);
			} else {
				// There was a HTTP 5xx Server Side Error
				displayOneDriveErrorMessage(e.msg);
				// Must exit here
				exit(-1);
			}
		}
		
		if (!isItemRoot(driveData)) {
			// Get root details for the provided driveId
			try {
				rootData = onedrive.getDriveIdRoot(driveId);
			} catch (OneDriveException e) {
				log.vdebug("rootData = onedrive.getDriveIdRoot(driveId) generated a OneDriveException");
				// HTTP request returned status code 504 (Gateway Timeout) or 429 retry
				if ((e.httpStatusCode == 429) || (e.httpStatusCode == 504)) {
					// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
					if (e.httpStatusCode == 429) {
						log.vdebug("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - retrying applicable request");
						handleOneDriveThrottleRequest();
					}
					if (e.httpStatusCode == 504) {
						log.vdebug("Retrying original request that generated the HTTP 504 (Gateway Timeout) - retrying applicable request");
						Thread.sleep(dur!"seconds"(30));
					}
					// Retry original request by calling function again to avoid replicating any further error handling
					rootData = onedrive.getDriveIdRoot(driveId);
					
				} else {
					// There was a HTTP 5xx Server Side Error
					displayOneDriveErrorMessage(e.msg);
					// Must exit here
					exit(-1);
				}
			}
			// Add driveData JSON data to array
			log.vlog("Adding OneDrive root details for processing");
			childrenData ~= rootData;
		}
		
		// Add driveData JSON data to array
		log.vlog("Adding OneDrive folder details for processing");
		childrenData ~= driveData;
		
		for (;;) {
			// query top level children
			try {
				topLevelChildren = onedrive.listChildren(driveId, idToQuery, nextLink);
			} catch (OneDriveException e) {
				// OneDrive threw an error
				log.vdebug("------------------------------------------------------------------");
				log.vdebug("Query Error: topLevelChildren = onedrive.listChildren(driveId, idToQuery, nextLink)");
				log.vdebug("driveId: ", driveId);
				log.vdebug("idToQuery: ", idToQuery);
				log.vdebug("nextLink: ", nextLink);
				
				// HTTP request returned status code 404 (Not Found)
				if (e.httpStatusCode == 404) {
					// Stop application
					log.log("\n\nOneDrive returned a 'HTTP 404 - Item not found'");
					log.log("The item id to query was not found on OneDrive");
					log.log("\nRemove your '", cfg.databaseFilePath, "' file and try to sync again\n");
				}
				
				// HTTP request returned status code 429 (Too Many Requests)
				if (e.httpStatusCode == 429) {
					// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
					handleOneDriveThrottleRequest();
					log.vdebug("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - attempting to query OneDrive drive children");
				}
				
				// HTTP request returned status code 500 (Internal Server Error)
				if (e.httpStatusCode == 500) {
					// display what the error is
					displayOneDriveErrorMessage(e.msg);
				}
				
				// HTTP request returned status code 504 (Gateway Timeout) or 429 retry
				if ((e.httpStatusCode == 429) || (e.httpStatusCode == 504)) {
					// re-try the specific changes queries	
					if (e.httpStatusCode == 504) {
						log.log("OneDrive returned a 'HTTP 504 - Gateway Timeout' when attempting to query OneDrive drive children - retrying applicable request");
						log.vdebug("topLevelChildren = onedrive.listChildren(driveId, idToQuery, nextLink) previously threw an error - retrying");
						// The server, while acting as a proxy, did not receive a timely response from the upstream server it needed to access in attempting to complete the request. 
						log.vdebug("Thread sleeping for 30 seconds as the server did not receive a timely response from the upstream server it needed to access in attempting to complete the request");
						Thread.sleep(dur!"seconds"(30));
					}
					// re-try original request - retried for 429 and 504
					try {
						log.vdebug("Retrying Query: topLevelChildren = onedrive.listChildren(driveId, idToQuery, nextLink)");
						topLevelChildren = onedrive.listChildren(driveId, idToQuery, nextLink);
						log.vdebug("Query 'topLevelChildren = onedrive.listChildren(driveId, idToQuery, nextLink)' performed successfully on re-try");
					} catch (OneDriveException e) {
						// display what the error is
						log.vdebug("Query Error: topLevelChildren = onedrive.listChildren(driveId, idToQuery, nextLink) on re-try after delay");
						// error was not a 504 this time
						displayOneDriveErrorMessage(e.msg);
					}
				} else {
					// Default operation if not 404, 410, 429, 500 or 504 errors
					// display what the error is
					displayOneDriveErrorMessage(e.msg);
				}
			}
			
			// process top level children
			log.vlog("Adding ", count(topLevelChildren["value"].array), " OneDrive items for processing from OneDrive folder");
			foreach (child; topLevelChildren["value"].array) {
				// add this child to the array of objects
				childrenData ~= child;
				// is this child a folder?
				if (isItemFolder(child)){
					// We have to query this folders children if childCount > 0
					if (child["folder"]["childCount"].integer > 0){
						// This child folder has children
						string childIdToQuery = child["id"].str;
						string childDriveToQuery = child["parentReference"]["driveId"].str;
						auto childParentPath = child["parentReference"]["path"].str.split(":");
						string folderPathToScan = childParentPath[1] ~ "/" ~ child["name"].str;
						string pathForLogging = "/" ~ driveData["name"].str ~ "/" ~ child["name"].str;
						JSONValue[] grandChildrenData = queryForChildren(childDriveToQuery, childIdToQuery, folderPathToScan, pathForLogging);
						foreach (grandChild; grandChildrenData.array) {
							// add the grandchild to the array
							childrenData ~= grandChild;
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
		
		// craft response from all returned elements
		deltaResponse = [
						"@odata.context": JSONValue("https://graph.microsoft.com/v1.0/$metadata#Collection(driveItem)"),
						"value": JSONValue(childrenData.array)
						];
		
		// return the generated JSON response
		return deltaResponse;
	}
	
	// query child for children
	JSONValue[] queryForChildren(const(char)[] driveId, const(char)[] idToQuery, const(char)[] childParentPath, string pathForLogging)
	{
		// function variables
		JSONValue thisLevelChildren;
		JSONValue[] thisLevelChildrenData;
		string nextLink;

		for (;;) {
			// query children
			try {
				thisLevelChildren = onedrive.listChildren(driveId, idToQuery, nextLink);
			} catch (OneDriveException e) {
				// OneDrive threw an error
				log.vdebug("------------------------------------------------------------------");
				log.vdebug("Query Error: thisLevelChildren = onedrive.listChildren(driveId, idToQuery, nextLink)");
				log.vdebug("driveId: ", driveId);
				log.vdebug("idToQuery: ", idToQuery);
				log.vdebug("nextLink: ", nextLink);
				
				// HTTP request returned status code 404 (Not Found)
				if (e.httpStatusCode == 404) {
					// Stop application
					log.log("\n\nOneDrive returned a 'HTTP 404 - Item not found'");
					log.log("The item id to query was not found on OneDrive");
					log.log("\nRemove your '", cfg.databaseFilePath, "' file and try to sync again\n");
				}
				
				// HTTP request returned status code 429 (Too Many Requests)
				if (e.httpStatusCode == 429) {
					// HTTP request returned status code 429 (Too Many Requests). We need to leverage the response Retry-After HTTP header to ensure minimum delay until the throttle is removed.
					handleOneDriveThrottleRequest();
					log.vdebug("Retrying original request that generated the OneDrive HTTP 429 Response Code (Too Many Requests) - attempting to query OneDrive drive children");
				}
				
				// HTTP request returned status code 500 (Internal Server Error)
				if (e.httpStatusCode == 500) {
					// display what the error is
					displayOneDriveErrorMessage(e.msg);
				}
				
				// HTTP request returned status code 504 (Gateway Timeout) or 429 retry
				if ((e.httpStatusCode == 429) || (e.httpStatusCode == 504)) {
					// re-try the specific changes queries	
					if (e.httpStatusCode == 504) {
						log.log("OneDrive returned a 'HTTP 504 - Gateway Timeout' when attempting to query OneDrive drive children - retrying applicable request");
						log.vdebug("thisLevelChildren = onedrive.listChildren(driveId, idToQuery, nextLink) previously threw an error - retrying");
						// The server, while acting as a proxy, did not receive a timely response from the upstream server it needed to access in attempting to complete the request. 
						log.vdebug("Thread sleeping for 30 seconds as the server did not receive a timely response from the upstream server it needed to access in attempting to complete the request");
						Thread.sleep(dur!"seconds"(30));
					}
					// re-try original request - retried for 429 and 504
					try {
						log.vdebug("Retrying Query: thisLevelChildren = onedrive.listChildren(driveId, idToQuery, nextLink)");
						thisLevelChildren = onedrive.listChildren(driveId, idToQuery, nextLink);
						log.vdebug("Query 'thisLevelChildren = onedrive.listChildren(driveId, idToQuery, nextLink)' performed successfully on re-try");
					} catch (OneDriveException e) {
						// display what the error is
						log.vdebug("Query Error: thisLevelChildren = onedrive.listChildren(driveId, idToQuery, nextLink) on re-try after delay");
						// error was not a 504 this time
						displayOneDriveErrorMessage(e.msg);
					}
				} else {
					// Default operation if not 404, 410, 429, 500 or 504 errors
					// display what the error is
					displayOneDriveErrorMessage(e.msg);
				}
			}
			
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
			// If a collection exceeds the default page size (200 items), the @odata.nextLink property is returned in the response 
			// to indicate more items are available and provide the request URL for the next page of items.
			if ("@odata.nextLink" in thisLevelChildren) {
				// Update nextLink to next changeSet bundle
				log.vdebug("Setting nextLink to (@odata.nextLink): ", nextLink);
				nextLink = thisLevelChildren["@odata.nextLink"].str;
			} else break;
		}
		
		// return response
		return thisLevelChildrenData;
	}
	
	// OneDrive Business Shared Folder support
	void listOneDriveBusinessSharedFolders()
	{
		// List OneDrive Business Shared Folders
		log.log("\nListing available OneDrive Business Shared Folders:");
		// Query the GET /me/drive/sharedWithMe API
		JSONValue graphQuery = onedrive.getSharedWithMe();
		if (graphQuery.type() == JSONType.object) {
			if (count(graphQuery["value"].array) == 0) {
				// no shared folders returned
				write("\nNo OneDrive Business Shared Folders were returned\n");
			} else {
				// shared folders were returned
				log.vdebug("onedrive.getSharedWithMe API Response: ", graphQuery);
				foreach (searchResult; graphQuery["value"].array) {
					// loop variables
					string sharedFolderName;
					string sharedByName;
					string sharedByEmail;
					
					// Debug response output
					log.vdebug("shared folder entry: ", searchResult);
					sharedFolderName = searchResult["name"].str;
					
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
					log.log("---------------------------------------");
					log.log("Shared Folder:   ", sharedFolderName);
					if ((sharedByName != "") && (sharedByEmail != "")) {
						log.log("Shared By:       ", sharedByName, " (", sharedByEmail, ")");
					} else {
						if (sharedByName != "") {
							log.log("Shared By:       ", sharedByName);
						}
					}
					log.vlog("Item Id:         ", searchResult["remoteItem"]["id"].str);
					log.vlog("Parent Drive Id: ", searchResult["remoteItem"]["parentReference"]["driveId"].str);
					if ("id" in searchResult["remoteItem"]["parentReference"]) {
						log.vlog("Parent Item Id:  ", searchResult["remoteItem"]["parentReference"]["id"].str);
					}
				}
			}
			write("\n");
		} else {
			// Log that an invalid JSON object was returned
			log.error("ERROR: onedrive.getSharedWithMe call returned an invalid JSON Object");
		}
	}
}