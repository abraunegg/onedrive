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

// flag to set whether local files should be deleted
private bool noRemoteDelete = false;

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

private bool isDotFile(string path)
{
	// always allow the root
	if (path == ".") return false;
	
	path = buildNormalizedPath(path);
	auto paths = pathSplitter(path);
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

	return item;
}

private bool testFileHash(string path, const ref Item item)
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
			if (e.httpStatusCode == 400) {
				// OneDrive responded with 400 error: Bad Request
				log.error("\nERROR: OneDrive returned a 'HTTP 400 Bad Request' - Cannot Initialize Sync Engine");
				// Check this
				if (cfg.getValueString("drive_id").length) {
					log.error("ERROR: Check your 'drive_id' entry in your configuration file as it may be incorrect\n");
				}
				// Must exit here
				exit(-1);
			}
			if (e.httpStatusCode == 401) {
				// HTTP request returned status code 401 (Unauthorized)
				log.error("\nERROR: OneDrive returned a 'HTTP 401 Unauthorized' - Cannot Initialize Sync Engine");
				log.error("ERROR: Check your configuration as your access token may be empty or invalid\n");
				// Must exit here
				exit(-1);
			}
			if (e.httpStatusCode >= 500) {
				// There was a HTTP 5xx Server Side Error
				log.error("ERROR: OneDrive returned a 'HTTP 5xx Server Side Error' - Cannot Initialize Sync Engine");
				// Must exit here
				exit(-1);
			}
		}
		
		// Get Default Root
		try {
			oneDriveRootDetails = onedrive.getDefaultRoot();
		} catch (OneDriveException e) {
			if (e.httpStatusCode == 400) {
				// OneDrive responded with 400 error: Bad Request
				log.error("\nERROR: OneDrive returned a 'HTTP 400 Bad Request' - Cannot Initialize Sync Engine");
				// Check this
				if (cfg.getValueString("drive_id").length) {
					log.error("ERROR: Check your 'drive_id' entry in your configuration file as it may be incorrect\n");
				}
				// Must exit here
				exit(-1);
			}
			if (e.httpStatusCode == 401) {
				// HTTP request returned status code 401 (Unauthorized)
				log.error("\nERROR: OneDrive returned a 'HTTP 401 Unauthorized' - Cannot Initialize Sync Engine");
				log.error("ERROR: Check your configuration as your access token may be empty or invalid\n");
				// Must exit here
				exit(-1);
			}
			if (e.httpStatusCode >= 500) {
				// There was a HTTP 5xx Server Side Error
				log.error("ERROR: OneDrive returned a 'HTTP 5xx Server Side Error' - Cannot Initialize Sync Engine");
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
			
			// In some cases OneDrive Business configurations 'restrict' quota details thus is empty / blank / negative value / zero
			if (remainingFreeSpace <= 0) {
				// quota details not available
				log.error("ERROR: OneDrive quota information is being restricted. Please fix by speaking to your OneDrive / Office 365 Administrator.");
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
			// Must exit here
			exit(-1);
		}
	}

	// Configure noRemoteDelete if function is called
	// By default, noRemoteDelete = false;
	// Meaning we will process local deletes to delete item on OneDrive
	void setNoRemoteDelete()
	{
		noRemoteDelete = true;
	}
	
	// Configure uploadOnly if function is called
	// By default, uploadOnly = false;
	void setUploadOnly()
	{
		uploadOnly = true;
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
	
	// download all new changes from OneDrive
	void applyDifferences()
	{
		// Set defaults for the root folder
		// Use the global's as initialised via init() rather than performing unnecessary additional HTTPS calls
		string driveId = defaultDriveId;
		string rootId = defaultRootId;
		applyDifferences(driveId, rootId);

		// Check OneDrive Personal Shared Folders
		// https://github.com/OneDrive/onedrive-api-docs/issues/764
		Item[] items = itemdb.selectRemoteItems();
		foreach (item; items) {
			log.vlog("Syncing OneDrive Shared Folder: ", item.name);
			applyDifferences(item.remoteDriveId, item.remoteId);
		}
	}

	// download all new changes from a specified folder on OneDrive
	void applyDifferencesSingleDirectory(string path)
	{
		log.vlog("Getting path details from OneDrive ...");
		JSONValue onedrivePathDetails;
		
		// test if the path we are going to sync from actually exists on OneDrive
		try {
			onedrivePathDetails = onedrive.getPathDetails(path); // Returns a JSON String for the OneDrive Path
		} catch (OneDriveException e) {
			if (e.httpStatusCode == 404) {
				// The directory was not found 
				log.error("ERROR: The requested single directory to sync was not found on OneDrive");
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
			string driveId;
			string folderId;
			
			if(isItemRemote(onedrivePathDetails)){
				// 2 step approach:
				//		1. Ensure changes for the root remote path are captured
				//		2. Download changes specific to the remote path
				
				// root remote
				applyDifferences(defaultDriveId, onedrivePathDetails["id"].str);
			
				// remote changes
				driveId = onedrivePathDetails["remoteItem"]["parentReference"]["driveId"].str; // Should give something like 66d53be8a5056eca
				folderId = onedrivePathDetails["remoteItem"]["id"].str; // Should give something like BC7D88EC1F539DCF!107
				
				// Apply any differences found on OneDrive for this path (download data)
				applyDifferences(driveId, folderId);
			} else {
				// use the item id as folderId
				folderId = onedrivePathDetails["id"].str; // Should give something like 12345ABCDE1234A1!101
				// Apply any differences found on OneDrive for this path (download data)
				applyDifferences(defaultDriveId, folderId);
			}
		} else {
			// Log that an invalid JSON object was returned
			log.error("ERROR: onedrive.getPathDetails call returned an invalid JSON Object");
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
			log.error("ERROR: onedrive.getDefaultRoot call returned an invalid JSON Object");
			// Must exit here as we cant configure our required variables
			exit(-1);
		}
	}
	
	// create a directory on OneDrive without syncing
	auto createDirectoryNoSync(string path)
	{
		// Attempt to create the requested path within OneDrive without performing a sync
		log.vlog("Attempting to create the requested path within OneDrive");
		
		// Handle the remote folder creation and updating of the local database without performing a sync
		uploadCreateDir(path);
	}
	
	// delete a directory on OneDrive without syncing
	auto deleteDirectoryNoSync(string path)
	{
		// Use the global's as initialised via init() rather than performing unnecessary additional HTTPS calls
		const(char)[] rootId = defaultRootId;
		
		// Attempt to delete the requested path within OneDrive without performing a sync
		log.vlog("Attempting to delete the requested path within OneDrive");
		
		// test if the path we are going to exists on OneDrive
		try {
			onedrive.getPathDetails(path);
		} catch (OneDriveException e) {
			if (e.httpStatusCode == 404) {
				// The directory was not found on OneDrive - no need to delete it
				log.vlog("The requested directory to delete was not found on OneDrive - skipping removing the remote directory as it doesn't exist");
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
			if (e.httpStatusCode == 404) {
				// The directory was not found 
				log.vlog("The requested directory to rename was not found on OneDrive");
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
	private void applyDifferences(string driveId, const(char)[] id)
	{
		log.vlog("Applying changes of Path ID: " ~ id);
		JSONValue changes;
		string deltaLink = itemdb.getDeltaLink(driveId, id);
		
		// Query the name of this folder id
		string syncFolderName;
		string syncFolderPath;
		string syncFolderChildPath;
		JSONValue idDetails = parseJSON("{}");
		try {
			idDetails = onedrive.getPathDetailsById(driveId, id);
		} catch (OneDriveException e) {
			if (e.httpStatusCode == 404) {
				// id was not found - possibly a remote (shared) folder
				log.vlog("No details returned for given Path ID");
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
				// Is this a 'local' or 'remote' item?
				if(isItemRemote(idDetails)){
					// A remote drive item will not have ["parentReference"]["path"]
					syncFolderPath = "";
					syncFolderChildPath = "";
				} else {
					if (hasParentReferencePath(idDetails)) {
						syncFolderPath = idDetails["parentReference"]["path"].str;
						syncFolderChildPath = syncFolderPath ~ "/" ~ idDetails["name"].str ~ "/";
					} else {
						// root drive item will not have ["parentReference"]["path"] 
						syncFolderPath = "";
						syncFolderChildPath = "";
					}
				}
				
				// Debug Output
				log.vdebug("Sync Folder Name: ", syncFolderName);
				// Debug Output of path if only set, generally only set if using --single-directory
				if (hasParentReferencePath(idDetails)) {
					log.vdebug("Sync Folder Path: ", syncFolderPath);
					log.vdebug("Sync Folder Child Path: ", syncFolderChildPath);
				}
			}
		} else {
			// Log that an invalid JSON object was returned
			log.error("ERROR: onedrive.getPathDetailsById call returned an invalid JSON Object");
		}
		
		for (;;) {
			// Due to differences in OneDrive API's between personal and business we need to get changes only from defaultRootId
			// If we used the 'id' passed in & when using --single-directory with a business account we get:
			//	'HTTP request returned status code 501 (Not Implemented): view.delta can only be called on the root.'
			// To view changes correctly, we need to use the correct path id for the request
			const(char)[] idToQuery;
			if (driveId == defaultDriveId) {
				// The drive id matches our users default drive id
				idToQuery = defaultRootId.dup;
			} else {
				// The drive id does not match our users default drive id
				// Potentially the 'path id' we are requesting the details of is a Shared Folder (remote item)
				// Use the 'id' that was passed in (folderId)
				idToQuery = id;
			}
			
			try {
				// Fetch the changes relative to the path id we want to query
				changes = onedrive.viewChangesById(driveId, idToQuery, deltaLink);
			} catch (OneDriveException e) {
				// OneDrive threw an error
				log.vdebug("OneDrive threw an error when querying for these changes:");
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
					log.vlog("Delta link expired, re-syncing...");
					deltaLink = null;
					continue;
				}
				
				// HTTP request returned status code 500 (Internal Server Error)
				if (e.httpStatusCode == 500) {
					// Stop application
					log.log("\n\nOneDrive returned a 'HTTP 500 - Internal Server Error'");
					log.log("This is a OneDrive API Bug - https://github.com/OneDrive/onedrive-api-docs/issues/844\n\n");
					log.log("\nRemove your '", cfg.databaseFilePath, "' file and try to sync again\n");
					return;
				}
				
				if (e.httpStatusCode == 504) {
					// HTTP request returned status code 504 (Gateway Timeout)
					// Retry by calling applyDifferences() again
					log.vlog("OneDrive returned a 'HTTP 504 - Gateway Timeout' - gracefully handling error");
					applyDifferences(driveId, idToQuery);
				} else {
					// Default operation if not 404, 410, 500, 504 errors
					// display what the error is
					displayOneDriveErrorMessage(e.msg);
					log.log("\nRemove your '", cfg.databaseFilePath, "' file and try to sync again\n");
					return;
				}
			}
			
			// is changes a valid JSON response
			if (changes.type() == JSONType.object) {
				// Are there any changes to process?
				if (("value" in changes) != null) {
					auto nrChanges = count(changes["value"].array);

					if (nrChanges >= cfg.getValueLong("min_notify_changes")) {
						log.logAndNotify("Processing ", nrChanges, " changes");
					} else {
						// There are valid changes
						log.vdebug("Number of changes from OneDrive to process: ", nrChanges);
					}
					
					foreach (item; changes["value"].array) {
						bool isRoot = false;
						string thisItemPath;
						
						// Change as reported by OneDrive
						log.vdebug("------------------------------------------------------------------");
						log.vdebug("OneDrive Change: ", item);
						
						// Deleted items returned from onedrive.viewChangesById (/delta) do not have a 'name' attribute
						// Thus we cannot name check for 'root' below on deleted items
						if(!isItemDeleted(item)){
							// This is not a deleted item
							// Test is this is the OneDrive Users Root?
							// Use the global's as initialised via init() rather than performing unnecessary additional HTTPS calls 
							if ((id == defaultRootId) && (isItemRoot(item)) && (item["name"].str == "root")) { 
								// This IS a OneDrive Root item
								isRoot = true;
							}
						}

						// How do we handle this change?
						if (isRoot || !hasParentReferenceId(item) || isItemDeleted(item)){
							// Is a root item, has no id in parentReference or is a OneDrive deleted item
							log.vdebug("Handling change as 'root item', has no parent reference or is a deleted item");
							applyDifference(item, driveId, isRoot);
						} else {
							// What is this item's path?
							if (hasParentReferencePath(item)) {
								thisItemPath = item["parentReference"]["path"].str;
							} else {
								thisItemPath = "";
							}
							
							// Debug output of change evaluation items
							log.vdebug("'search id'                                       = ", id);
							log.vdebug("'parentReference id'                              = ", item["parentReference"]["id"].str);
							log.vdebug("syncFolderPath                                    = ", syncFolderPath);
							log.vdebug("syncFolderChildPath                               = ", syncFolderChildPath);
							log.vdebug("thisItemId                                        = ", item["id"].str);
							log.vdebug("thisItemPath                                      = ", thisItemPath);
							log.vdebug("'item id' matches search 'id'                     = ", (item["id"].str == id));
							log.vdebug("'parentReference id' matches search 'id'          = ", (item["parentReference"]["id"].str == id));
							log.vdebug("'item path' contains 'syncFolderChildPath'        = ", (canFind(thisItemPath, syncFolderChildPath)));
							log.vdebug("'item path' contains search 'id'                  = ", (canFind(thisItemPath, id)));
							
							// Check this item's path to see if this is a change on the path we want:
							// 1. 'item id' matches 'id'
							// 2. 'parentReference id' matches 'id'
							// 3. 'item path' contains 'syncFolderChildPath'
							// 4. 'item path' contains 'id'
							
							if ( (item["id"].str == id) || (item["parentReference"]["id"].str == id) || (canFind(thisItemPath, syncFolderChildPath)) || (canFind(thisItemPath, id)) ){
								// This is a change we want to apply
								log.vdebug("Change matches search criteria to apply");
								applyDifference(item, driveId, isRoot);
							} else {
								// No item ID match or folder sync match
								// Before discarding change - does this ID still exist on OneDrive - as in IS this 
								// potentially a --single-directory sync and the user 'moved' the file out of the 'sync-dir' to another OneDrive folder
								// This is a corner edge case - https://github.com/skilion/onedrive/issues/341
								JSONValue oneDriveMovedNotDeleted;
								try {
									oneDriveMovedNotDeleted = onedrive.getPathDetailsById(driveId, item["id"].str);
								} catch (OneDriveException e) {
									if (e.httpStatusCode == 404) {
										// No .. that ID is GONE
										log.vlog("Remote change discarded - item cannot be found");
										return;
									}
									
									if (e.httpStatusCode >= 500) {
										// OneDrive returned a 'HTTP 5xx Server Side Error' - gracefully handling error - error message already logged
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
									}
								} else {
									log.vlog("Remote change discarded - not in --single-directory scope");
								}
							} 
						}
					}
				}
				
				// the response may contain either @odata.deltaLink or @odata.nextLink
				if ("@odata.deltaLink" in changes) deltaLink = changes["@odata.deltaLink"].str;
				if (deltaLink) itemdb.setDeltaLink(driveId, id, deltaLink);
				if ("@odata.nextLink" in changes) deltaLink = changes["@odata.nextLink"].str;
				else break;	
			} else {
				// Log that an invalid JSON object was returned
				log.error("ERROR: onedrive.viewChangesById call returned an invalid JSON Object");
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
				if (selectiveSync.isPathExcluded(driveItem["parentReference"]["name"].str)) {
					// Previously synced item is now out of scope as it has been moved out of what is included in sync_list
					log.vdebug("This previously synced item is now excluded from being synced due to sync_list exclusion");
					// flag to delete local file as it now is no longer in sync with OneDrive
					log.vdebug("Flagging to delete item locally");
					idsToDelete ~= [item.driveId, item.id];
				}
			}
		}
		
		// Check if this is a directory to skip
		if (!unwanted) {
			// Only check path if config is != ""
			if (cfg.getValueString("skip_dir") != "") {
				unwanted = selectiveSync.isDirNameExcluded(item.name);
				if (unwanted) log.vlog("Skipping item - excluded by skip_dir config: ", item.name);
			}
		}
		// Check if this is a file to skip
		if (!unwanted) {
			unwanted = selectiveSync.isFileNameExcluded(item.name);
			if (unwanted) log.vlog("Skipping item - excluded by skip_file config: ", item.name);
		}

		// check the item type
		if (!unwanted) {
			if (isItemFile(driveItem)) {
				log.vdebug("The item we are syncing is a file");
			} else if (isItemFolder(driveItem)) {
				log.vdebug("The item we are syncing is a folder");
			} else if (isItemRemote(driveItem)) {
				log.vdebug("The item we are syncing is a remote item");
				assert(isItemFolder(driveItem["remoteItem"]), "The remote item is not a folder");
			} else {
				log.vlog("This item type (", item.name, ") is not supported");
				unwanted = true;
				log.vdebug("Flagging as unwanted: item type is not supported");
			}
		}

		// check for selective sync
		string path;
		if (!unwanted) {
			// Is the item in the local database
			if (itemdb.idInLocalDatabase(item.driveId, item.parentId)){
				// compute the item path to see if the path is excluded
				path = itemdb.computePath(item.driveId, item.parentId) ~ "/" ~ item.name;
				path = buildNormalizedPath(path);
				if (selectiveSync.isPathExcluded(path)) {
					// selective sync advised to skip, however is this a file and are we configured to upload / download files in the root?
					if ((isItemFile(driveItem)) && (cfg.getValueBool("sync_root_files")) && (rootName(path) == "") ) {
						// This is a file
						// We are configured to sync all files in the root
						// This is a file in the logical root
						unwanted = false;
					} else {
						// path is unwanted
						unwanted = true;
						log.vdebug("OneDrive change path is to be excluded by user configuration: ", path);
					}
				}
			} else {
				log.vdebug("Flagging as unwanted: item.driveId (", item.driveId,"), item.parentId (", item.parentId,") not in local database");
				unwanted = true;
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
				idsToDelete ~= [item.driveId, item.id];
			} else {
				// flag to ignore
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
							log.vlog("The local item is out-of-sync with OneDrive, renaming to preserve existing file: ", oldPath, " -> ", newPath);
							if (!dryRun) {
								safeRename(oldPath);
							} else {
								// Expectation here is that there is a new file locally (newPath) however as we don't create this, the "new file" will not be uploaded as it does not exist
								log.vdebug("DRY-RUN: Skipping local file rename");
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
	private void applyNewItem(Item item, string path)
	{
		if (exists(path)) {
			if (isItemSynced(item, path)) {
				//log.vlog("The item is already present");
				return;
			} else {
				// TODO: force remote sync by deleting local item
				
				// Is the local file technically 'newer' based on UTC timestamp?
				SysTime localModifiedTime = timeLastModified(path).toUTC();
				localModifiedTime.fracSecs = Duration.zero;
				item.mtime.fracSecs = Duration.zero;
				
				if (localModifiedTime > item.mtime) {
					// local file is newer than item on OneDrive
					// no local rename
					// no download needed
					log.vlog("Local item modified time is newer based on UTC time conversion - keeping local item");
					log.vdebug("Skipping OneDrive change as this is determined to be unwanted due to local item modified time being newer than OneDrive item");
					return;
				} else {
					// remote file is newer than local item
					log.vlog("Remote item modified time is newer based on UTC time conversion");
					auto ext = extension(path);
					auto newPath = path.chomp(ext) ~ "-" ~ deviceName ~ ext;
					log.vlog("The local item is out-of-sync with OneDrive, renaming to preserve existing file: ", path, " -> ", newPath);
					if (!dryRun) {
						safeRename(path);
					} else {
						// Expectation here is that there is a new file locally (newPath) however as we don't create this, the "new file" will not be uploaded as it does not exist
						log.vdebug("DRY-RUN: Skipping local file rename");
					}
				}
			}
		}
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
			log.log("Creating directory: ", path);
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
				setTimes(newPath, newItem.mtime, newItem.mtime);
			}
		} 
	}

	// downloads a File resource
	private void downloadFileItem(Item item, string path)
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
			log.error("ERROR: onedrive.getFileDetails call returned an invalid JSON Object");
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
				if (e.httpStatusCode == 429) {
					// HTTP request returned status code 429 (Too Many Requests)
					// https://github.com/abraunegg/onedrive/issues/133
					// Back off & retry with incremental delay
					int retryCount = 10; 
					int retryAttempts = 1;
					int backoffInterval = 2;
					while (retryAttempts < retryCount){
						Thread.sleep(dur!"seconds"(retryAttempts*backoffInterval));
						try {
							onedrive.downloadById(item.driveId, item.id, path, fileSize);
							// successful download
							retryAttempts = retryCount;
						} catch (OneDriveException e) {
							if (e.httpStatusCode == 429) {
								// Increment & loop around
								retryAttempts++;
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
					setTimes(path, item.mtime, item.mtime);
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
	private bool isItemSynced(Item item, string path)
	{
		if (!exists(path)) return false;
		final switch (item.type) {
		case ItemType.file:
			if (isFile(path)) {
				SysTime localModifiedTime = timeLastModified(path).toUTC();
				// HACK: reduce time resolution to seconds before comparing
				item.mtime.fracSecs = Duration.zero;
				localModifiedTime.fracSecs = Duration.zero;
				if (localModifiedTime == item.mtime) {
					return true;
				} else {
					log.vlog("The local item has a different modified time ", localModifiedTime, " remote is ", item.mtime);
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
			string path = itemdb.computePath(i[0], i[1]);
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
	
	// scan the given directory for differences and new items
	void scanForDifferences(string path)
	{
		// scan for changes
		log.vlog("Uploading differences of ", path);
		Item item;
		if (itemdb.selectByPath(path, defaultDriveId, item)) {
			uploadDifferences(item);
		}
		log.vlog("Uploading new items of ", path);
		uploadNewItems(path);
		
		// clean up idsToDelete only if --dry-run is set
		if (dryRun) {
			idsToDelete.length = 0;
			assumeSafeAppend(idsToDelete);
		}
	}

	private void uploadDifferences(Item item)
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
			unwanted = selectiveSync.isPathExcluded(path);
		}

		// skip unwanted items
		if (unwanted) {
			//log.vlog("Filtered out");
			return;
		}
		
		// Restriction and limitations about windows naming files
		if (!isValidName(path)) {
			log.vlog("Skipping item - invalid name (Microsoft Naming Convention): ", path);
			return;
		}
		
		// Check for bad whitespace items
		if (!containsBadWhiteSpace(path)) {
			log.vlog("Skipping item - invalid name (Contains an invalid whitespace item): ", path);
			return;
		}
		
		// Check for HTML ASCII Codes as part of file name
		if (!containsASCIIHTMLCodes(path)) {
			log.vlog("Skipping item - invalid name (Contains HTML ASCII Code): ", path);
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

	private void uploadDirDifferences(Item item, string path)
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
				if (!itemdb.selectByPath(path, defaultDriveId, item)) {
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

	private void uploadRemoteDirDifferences(Item item, string path)
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
			log.vlog("The directory has been deleted");
			uploadDeleteItem(item, path);
		}
	}

	// upload local file system differences to OneDrive
	private void uploadFileDifferences(Item item, string path)
	{
		// Reset upload failure - OneDrive or filesystem issue (reading data)
		uploadFailed = false;
	
		assert(item.type == ItemType.file);
		if (exists(path)) {
			if (isFile(path)) {
				SysTime localModifiedTime = timeLastModified(path).toUTC();
				// HACK: reduce time resolution to seconds before comparing
				item.mtime.fracSecs = Duration.zero;
				localModifiedTime.fracSecs = Duration.zero;
				
				if (localModifiedTime != item.mtime) {
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
								}
								// OneDrive documentLibrary
								if (accountType == "documentLibrary"){
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
				log.vlog("The file has been deleted locally");
				if (noRemoteDelete) {
					// do not process remote file delete
					log.vlog("Skipping remote file delete as --upload-only & --no-remote-delete configured");
				} else {
					uploadDeleteItem(item, path);
				}
			} else {
				// We are in a --dry-run situation, file appears to have deleted locally - this file may never have existed as we never downloaded it ..
				// Check if path does not exist in database
				if (!itemdb.selectByPath(path, defaultDriveId, item)) {
					// file not found in database
					log.vlog("The file has been deleted locally");
					if (noRemoteDelete) {
						// do not process remote file delete
						log.vlog("Skipping remote file delete as --upload-only & --no-remote-delete configured");
					} else {
						uploadDeleteItem(item, path);
					}
				}  else {
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
					uploadDeleteItem(item, path);
				}
			}
		}
	}

	// upload new items to OneDrive
	private void uploadNewItems(string path)
	{
		//	https://support.microsoft.com/en-us/help/3125202/restrictions-and-limitations-when-you-sync-files-and-folders
		//  If the path is greater than allowed characters, then one drive will return a '400 - Bad Request' 
		//  Need to ensure that the URI is encoded before the check is made
		//  400 Character Limit for OneDrive Business / Office 365
		//  430 Character Limit for OneDrive Personal
		auto maxPathLength = 0;
		import std.range : walkLength;
		import std.uni : byGrapheme;
		if (accountType == "business"){
			// Business Account
			maxPathLength = 400;
		} else {
			// Personal Account
			maxPathLength = 430;
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
		
		if(path.byGrapheme.walkLength < maxPathLength){
			// path is less than maxPathLength
			
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
					log.vlog("Skipping item - invalid symbolic link: ", path);
					return;
				}
			}
			
			// Restriction and limitations about windows naming files
			if (!isValidName(path)) {
				log.vlog("Skipping item - invalid name (Microsoft Naming Convention): ", path);
				return;
			}
			
			// Check for bad whitespace items
			if (!containsBadWhiteSpace(path)) {
				log.vlog("Skipping item - invalid name (Contains an invalid whitespace item): ", path);
				return;
			}
			
			// Check for HTML ASCII Codes as part of file name
			if (!containsASCIIHTMLCodes(path)) {
				log.vlog("Skipping item - invalid name (Contains HTML ASCII Code): ", path);
				return;
			}

			// filter out user configured items to skip
			if (path != ".") {
				if (isDir(path)) {
					log.vdebug("Checking path: ", path);
					// Only check path if config is != ""
					if (cfg.getValueString("skip_dir") != "") {
						if (selectiveSync.isDirNameExcluded(strip(path,"./"))) {
							log.vlog("Skipping item - excluded by skip_dir config: ", path);
							return;
						}
					}
				}
				if (isFile(path)) {
					log.vdebug("Checking file: ", path);
					if (selectiveSync.isFileNameExcluded(strip(path,"./"))) {
						log.vlog("Skipping item - excluded by skip_file config: ", path);
						return;
					}
				}
				if (selectiveSync.isPathExcluded(path)) {
					if ((isFile(path)) && (cfg.getValueBool("sync_root_files")) && (rootName(strip(path,"./")) == "")) {
						log.vdebug("Not skipping path due to sync_root_files inclusion: ", path);
					} else {
						log.vlog("Skipping item - path excluded by sync_list: ", path);
						return;
					}
				}
			}

			// This item passed all the unwanted checks
			// We want to upload this new item
			if (isDir(path)) {
				Item item;
				if (!itemdb.selectByPath(path, defaultDriveId, item)) {
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
						uploadNewItems(entry.name);
					}
				} catch (FileException e) {
					// display the error message
					displayFileSystemErrorMessage(e.msg);
					return;
				}
			} else {
				// This item is a file
				auto fileSize = getSize(path);
				// Can we upload this file - is there enough free space? - https://github.com/skilion/onedrive/issues/73
				// However if the OneDrive account does not provide the quota details, we have no idea how much free space is available
				if ((!quotaAvailable) || ((remainingFreeSpace - fileSize) > 0)){
					if (!quotaAvailable) {
						log.vlog("Ignoring OneDrive account quota details to upload file - this may fail if not enough space on OneDrive ..");
					}
					Item item;
					if (!itemdb.selectByPath(path, defaultDriveId, item)) {
						// item is not in the database, upload new file
						uploadNewFile(path);
						if (!uploadFailed) {
							// upload did not fail
							remainingFreeSpace = (remainingFreeSpace - fileSize);
							log.vlog("Remaining free space: ", remainingFreeSpace);
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
			// If this is null or empty - we cant query the database properly
			if ((parent.driveId == "") && (parent.id == "")){
				// What path to use?
				string parentPath = dirName(path);		// will be either . or something else
								
				try {
					log.vdebug("Attempting to query OneDrive for this parent path: ", parentPath);
					onedrivePathDetails = onedrive.getPathDetails(parentPath);
				} catch (OneDriveException e) {
					// exception - set onedriveParentRootDetails to a blank valid JSON
					onedrivePathDetails = parseJSON("{}");
					if (e.httpStatusCode == 404) {
						// Parent does not exist ... need to create parent
						log.vdebug("Parent path does not exist: ", parentPath);
						uploadCreateDir(parentPath);
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
				response = onedrive.getPathDetails(path);
			} catch (OneDriveException e) {
				if (e.httpStatusCode == 404) {
					// The directory was not found 
					log.vlog("The requested directory to create was not found on OneDrive - creating remote directory: ", path);

					if (!dryRun) {
						// Perform the database lookup
						enforce(itemdb.selectByPath(dirName(path), parent.driveId, parent), "The parent item id is not in the database");
						JSONValue driveItem = [
								"name": JSONValue(baseName(path)),
								"folder": parseJSON("{}")
						];
						
						// Submit the creation request
						// Fix for https://github.com/skilion/onedrive/issues/356
						try {
							response = onedrive.createById(parent.driveId, parent.id, driveItem);
						} catch (OneDriveException e) {
							if (e.httpStatusCode == 409) {
								// OneDrive API returned a 404 (above) to say the directory did not exist
								// but when we attempted to create it, OneDrive responded that it now already exists
								log.vlog("OneDrive reported that ", path, " already exists .. OneDrive API race condition");
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
						string parentPath = dirName(path);
						uploadCreateDir(parentPath);
					} else {
						// parent is in database
						log.vlog("The parent for this path is in the local database - adding requested path (", path ,") to database");
						auto res = onedrive.getPathDetails(path);
						// Is the response a valid JSON object - validation checking done in saveItem
						saveItem(res);
					}
				} else {
					// They are the "same" name wise but different in case sensitivity
					log.error("ERROR: Current directory has a 'case-insensitive match' to an existing directory on OneDrive");
					log.error("ERROR: To resolve, rename this local directory: ", absolutePath(path));
					log.log("Skipping: ", absolutePath(path));
					return;
				}
			} else {
				// response is not valid JSON, an error was returned from OneDrive
				log.error("ERROR: There was an error performing this operation on OneDrive");
				log.error("ERROR: Increase logging verbosity to assist determining why.");
				log.log("Skipping: ", absolutePath(path));
				return;
			}
		}
	}
	
	// upload a new file to OneDrive
	private void uploadNewFile(string path)
	{
		// Reset upload failure - OneDrive or filesystem issue (reading data)
		uploadFailed = false;
	
		Item parent;
		// Check the database for the parent
		//enforce(itemdb.selectByPath(dirName(path), defaultDriveId, parent), "The parent item is not in the local database");
		if ((dryRun) || (itemdb.selectByPath(dirName(path), defaultDriveId, parent))) {
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
						if (e.httpStatusCode == 401) {
							// OneDrive returned a 'HTTP/1.1 401 Unauthorized Error'
							writeln("Skipping item - OneDrive returned a 'HTTP 401 - Unauthorized' when attempting to query if file exists"); 
							log.vlog("OneDrive returned a 'HTTP 401 - Unauthorized' - gracefully handling error");
							return;
						}
					
						if (e.httpStatusCode == 404) {
							// The file was not found on OneDrive, need to upload it		
							// Check if file should be skipped based on skip_size config
							if (thisFileSize >= this.newSizeLimit) {
								writeln("Skipping item - excluded by skip_size config: ", path, " (", thisFileSize/2^^20," MB)");
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
										// display what the error is
										writeln("skipped.");
										displayOneDriveErrorMessage(e.msg);
										uploadFailed = true;
										return;
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
												if (e.httpStatusCode == 504) {
													// HTTP request returned status code 504 (Gateway Timeout)
													// Try upload as a session
													try {
														response = session.upload(path, parent.driveId, parent.id, baseName(path));
													} catch (OneDriveException e) {
														// error uploading file
														// display what the error is
														writeln("skipped.");
														displayOneDriveErrorMessage(e.msg);
														uploadFailed = true;
														return;
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
									writeln("error");
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
												if (e.httpStatusCode == 401) {
													// OneDrive returned a 'HTTP/1.1 401 Unauthorized Error' - file failed to be uploaded
													writeln("skipped.");
													log.vlog("OneDrive returned a 'HTTP 401 - Unauthorized' - gracefully handling error");
													uploadFailed = true;
													return;
												}
												if (e.httpStatusCode == 504) {
													// HTTP request returned status code 504 (Gateway Timeout)
													// Try upload as a session
													try {
														response = session.upload(path, parent.driveId, parent.id, baseName(path));
														writeln("done.");
													} catch (OneDriveException e) {
														// error uploading file
														// display what the error is
														writeln("skipped.");
														displayOneDriveErrorMessage(e.msg);
														uploadFailed = true;
														return;
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
											log.error("ERROR: onedrive.simpleUpload or session.upload call returned an invalid JSON Object");
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
								saveItem(fileDetailsFromOneDrive);
							}
						} else {
							// The files are the "same" name wise but different in case sensitivity
							log.error("ERROR: A local file has the same name as another local file.");
							log.error("ERROR: To resolve, rename this local file: ", absolutePath(path));
							log.log("Skipping uploading this new file: ", absolutePath(path));
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
	private void uploadDeleteItem(Item item, string path)
	{
		log.log("Deleting item from OneDrive: ", path);
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
				
			try {
				onedrive.deleteById(item.driveId, item.id, item.eTag);
			} catch (OneDriveException e) {
				if (e.httpStatusCode == 404) {
					// item.id, item.eTag could not be found on driveId
					log.vlog("OneDrive reported: The resource could not be found.");
				}
				
				else {
					// Not a 404 response .. is this a 403 response due to OneDrive Business Retention Policy being enabled?
					if ((e.httpStatusCode == 403) && (accountType != "personal")) {
						auto errorArray = splitLines(e.msg);
						JSONValue errorMessage = parseJSON(replace(e.msg, errorArray[0], ""));
						if (errorMessage["error"]["message"].str == "Request was cancelled by event received. If attempting to delete a non-empty folder, it's possible that it's on hold") {
							// Issue #338 - Unable to delete OneDrive content when OneDrive Business Retention Policy is enabled
							// TODO: We have to recursively delete all files & folders from this path to delete
							// WARN: 
							log.error("\nERROR: Unable to delete the requested remote path from OneDrive: ", path);
							log.error("ERROR: This error is due to OneDrive Business Retention Policy being applied");
							log.error("WORKAROUND: Manually delete all files and folders from the above path as per Business Retention Policy\n");
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

	// update the item's last modified time
	private void uploadLastModifiedTime(const(char)[] driveId, const(char)[] id, const(char)[] eTag, SysTime mtime)
	{
		JSONValue data = [
			"fileSystemInfo": JSONValue([
				"lastModifiedDateTime": mtime.toISOExtString()
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
	private void displayOneDriveErrorMessage(string message) {
		log.error("ERROR: OneDrive returned an error with the following message:");
		auto errorArray = splitLines(message);
		log.error("  Error Message: ", errorArray[0]);
		// extract 'message' as the reason
		JSONValue errorMessage = parseJSON(replace(message, errorArray[0], ""));
		log.error("  Error Reason:  ", errorMessage["error"]["message"].str);	
	}
	
	// Parse and display error message received from the local file system
	private void displayFileSystemErrorMessage(string message) {
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
		Item fromItem, toItem, parentItem;
		if (!itemdb.selectByPath(from, defaultDriveId, fromItem)) {
			uploadNewFile(to);
			return;
		}
		if (fromItem.parentId == null) {
			// the item is a remote folder, need to do the operation on the parent
			enforce(itemdb.selectByPathNoRemote(from, defaultDriveId, fromItem));
		}
		if (itemdb.selectByPath(to, defaultDriveId, toItem)) {
			// the destination has been overwritten
			uploadDeleteItem(toItem, to);
		}
		if (!itemdb.selectByPath(dirName(to), defaultDriveId, parentItem)) {
			throw new SyncException("Can't move an item to an unsynced directory");
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
			auto res = onedrive.updateById(fromItem.driveId, fromItem.id, diff, fromItem.eTag);
			// update itemdb
			// Is the response a valid JSON object - validation checking done in saveItem
			saveItem(res);
		}
	}

	// delete an item by it's path
	void deleteByPath(string path)
	{
		Item item;
		if (!itemdb.selectByPath(path, defaultDriveId, item)) {
			throw new SyncException("The item to delete is not in the local database");
		}
		if (item.parentId == null) {
			// the item is a remote folder, need to do the operation on the parent
			enforce(itemdb.selectByPathNoRemote(path, defaultDriveId, item));
		}
		try {
			uploadDeleteItem(item, path);
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
	void querySiteCollectionForDriveID(string o365SharedLibraryName){
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
	void queryOneDriveForFileURL(string localFilePath, string syncDir) {
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
	void queryDriveForChanges(string path) {
		
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
			if (e.httpStatusCode == 404) {
				// Requested path could not be found
				log.error("ERROR: The requested path to query was not found on OneDrive");
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
		changes = onedrive.viewChangesById(driveId, idToQuery, deltaLink);
		
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
}
