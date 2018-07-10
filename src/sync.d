import std.algorithm;
import std.array: array;
import std.datetime;
import std.exception: enforce;
import std.file, std.json, std.path;
import std.regex;
import std.stdio, std.string, std.uni, std.uri;
import config, itemdb, onedrive, selective, upload, util;
static import log;

// threshold after which files will be uploaded using an upload session
private long thresholdFileSize = 4 * 2^^20; // 4 MiB

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

private bool changeHasParentReferenceId(const ref JSONValue item)
{
	return ("id" in item["parentReference"]) != null;
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
		item.driveId = driveItem["parentReference"]["driveId"].str,
		item.parentId = driveItem["parentReference"]["id"].str;
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
	// default drive id
	private string defaultDriveId;
	// default root id
	private string defaultRootId;
	// type of OneDrive account
	private string accountType;
	// free space remaining at init()
	private long remainingFreeSpace;

	this(Config cfg, OneDriveApi onedrive, ItemDatabase itemdb, SelectiveSync selectiveSync)
	{
		assert(onedrive && itemdb && selectiveSync);
		this.cfg = cfg;
		this.onedrive = onedrive;
		this.itemdb = itemdb;
		this.selectiveSync = selectiveSync;
		session = UploadSession(onedrive, cfg.uploadStateFilePath);
	}

	void init()
	{
		// Set accountType, defaultDriveId, defaultRootId & remainingFreeSpace once and reuse where possible
		auto oneDriveDetails = onedrive.getDefaultDrive();
		accountType = oneDriveDetails["driveType"].str;
		defaultDriveId = oneDriveDetails["id"].str;
		defaultRootId = onedrive.getDefaultRoot["id"].str;
		remainingFreeSpace = oneDriveDetails["quota"]["remaining"].integer;
		
		// Display accountType, defaultDriveId, defaultRootId & remainingFreeSpace for verbose logging purposes
		log.vlog("Account Type: ", accountType);
		log.vlog("Default Drive ID: ", defaultDriveId);
		log.vlog("Default Root ID: ", defaultRootId);
		log.vlog("Remaining Free Space: ", remainingFreeSpace);
	
		// Check the local database to ensure the OneDrive Root details are in the database
		checkDatabaseForOneDriveRoot();
	
		// check if there is an interrupted upload session
		if (session.restore()) {
			log.log("Continuing the upload session ...");
			auto item = session.upload();
			saveItem(item);
		}
	}

	// download all new changes from OneDrive
	void applyDifferences()
	{
		// Set defaults for the root folder
		// Use the global's as initialised via init() rather than performing unnecessary additional HTTPS calls
		string driveId = defaultDriveId;
		string rootId = defaultRootId;
		applyDifferences(driveId, rootId);

		// check all remote folders
		// https://github.com/OneDrive/onedrive-api-docs/issues/764
		Item[] items = itemdb.selectRemoteItems();
		foreach (item; items) applyDifferences(item.remoteDriveId, item.remoteId);
	}

	// download all new changes from a specified folder on OneDrive
	void applyDifferencesSingleDirectory(string path)
	{
		// test if the path we are going to sync from actually exists on OneDrive
		try {
			onedrive.getPathDetails(path);
		} catch (OneDriveException e) {
			if (e.httpStatusCode == 404) {
				// The directory was not found 
				log.vlog("ERROR: The requested single directory to sync was not found on OneDrive");
				return;
			}
		} 
		// OK - the path on OneDrive should exist, get the driveId and rootId for this folder
		log.vlog("Getting path details from OneDrive ...");
		JSONValue onedrivePathDetails = onedrive.getPathDetails(path); // Returns a JSON String for the OneDrive Path
		
		// Use the global's as initialised via init() rather than performing unnecessary additional HTTPS calls
		string driveId = defaultDriveId;
		string folderId = onedrivePathDetails["id"].str; // Should give something like 12345ABCDE1234A1!101
		
		// Apply any differences found on OneDrive for this path (download data)
		applyDifferences(driveId, folderId);
	}
	
	// make sure the OneDrive root is in our database
	auto checkDatabaseForOneDriveRoot()
	{
		log.vlog("Fetching details for OneDrive Root");
		JSONValue rootPathDetails = onedrive.getDefaultRoot(); // Returns a JSON Value
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
				log.vlog("The requested directory to create was not found on OneDrive - skipping removing the remote directory as it doesnt exist");
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
		JSONValue idDetails = parseJSON("{}");
		try {
			idDetails = onedrive.getPathDetailsById(driveId, id);
		} catch (OneDriveException e) {
			if (e.httpStatusCode == 404) {
				// id was not found - possibly a remote (shared) folder
				log.vlog("No details returned for given Path ID");
				return;
			}
		} 
		
		// Get the name of this 'Path ID'
		if (("id" in idDetails) != null) {
			// valid response from onedrive.getPathDetailsById(driveId, id) - a JSON item object present
			if ((idDetails["id"].str == id) && (isItemFolder(idDetails))){
				syncFolderName = encodeComponent(idDetails["name"].str);
			}
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
				// Use the 'id' that was passed in
				idToQuery = id;
			}
		
			try {
				// Fetch the changes relative to the path id we want to query
				changes = onedrive.viewChangesById(driveId, idToQuery, deltaLink);
				
			} catch (OneDriveException e) {
				// HTTP request returned status code 410 (The requested resource is no longer available at the server)
				if (e.httpStatusCode == 410) {
					log.vlog("Delta link expired, re-syncing...");
					deltaLink = null;
					continue;
				}
				
				if (e.httpStatusCode == 500) {
					// HTTP request returned status code 500 (Internal Server Error)
					// Exit Application
					log.log("\n\nOneDrive returned a 'HTTP 500 - Internal Server Error'");
					log.log("This is a OneDrive API Bug - https://github.com/OneDrive/onedrive-api-docs/issues/844\n\n");
					log.log("Remove your 'items.sqlite3' file and try to sync again\n\n");
					return;
				}
				
				if (e.httpStatusCode == 504) {
					// HTTP request returned status code 504 (Gateway Timeout)
					// Retry by calling applyDifferences() again
					log.vlog("OneDrive returned a 'HTTP 504 - Gateway Timeout' - gracefully handling error");
					applyDifferences(driveId, idToQuery);
				}
				
				else throw e;
			}
			foreach (item; changes["value"].array) {
				bool isRoot = false;
				string thisItemPath;
				
				// Deleted items returned from onedrive.viewChangesById (/delta) do not have a 'name' attribute
				// Thus we cannot name check for 'root' below on deleted items
				if(!isItemDeleted(item)){
					// This is not a deleted item
					// Test is this is the OneDrive Users Root?
					// Use the global's as initialised via init() rather than performing unnecessary additional HTTPS calls
					if ((id == defaultRootId) && (item["name"].str == "root")) { 
						// This IS the OneDrive Root
						isRoot = true;
					}
					
					// Test is this a Shared Folder - which should also be classified as a 'root' item
					if (changeHasParentReferenceId(item)) {
						// item contains parentReference key
						if (item["parentReference"]["driveId"].str != defaultDriveId) {
							// The change parentReference driveId does not match the defaultDriveId - this could be a Shared Folder root item
							string sharedDriveRootPath = "/drives/" ~ item["parentReference"]["driveId"].str ~ "/root:";
							if (item["parentReference"]["path"].str == sharedDriveRootPath) {
								// The drive path matches what a shared folder root item would equal
								isRoot = true;
							}
						}
					}
				}

				// How do we handle this change?
				if (isRoot || !changeHasParentReferenceId(item) || isItemDeleted(item)){
					// Is a root item, has no id in parentReference or is a OneDrive deleted item
					applyDifference(item, driveId, isRoot);
				} else {
					// What is this item's path?
					thisItemPath = item["parentReference"]["path"].str;
					// Check this item's path to see if this is a change on the path we want
					if ( (item["id"].str == id) || (item["parentReference"]["id"].str == id) || (canFind(thisItemPath, syncFolderName)) ){
						// This is a change we want to apply
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
						}
						// Yes .. ID is still on OneDrive but elsewhere .... #341 edge case handling
						// What is the original local path for this ID in the database? Does it match 'syncFolderName'
						if (itemdb.idInLocalDatabase(driveId, item["id"].str)){
							// item is in the database
							string originalLocalPath = itemdb.computePath(driveId, item["id"].str);
							if (canFind(originalLocalPath, syncFolderName)){
								// This 'change' relates to an item that WAS in 'syncFolderName' but is now 
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

			// the response may contain either @odata.deltaLink or @odata.nextLink
			if ("@odata.deltaLink" in changes) deltaLink = changes["@odata.deltaLink"].str;
			if (deltaLink) itemdb.setDeltaLink(driveId, id, deltaLink);
			if ("@odata.nextLink" in changes) deltaLink = changes["@odata.nextLink"].str;
			else break;
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
		Item item = makeItem(driveItem);
		
		if (isItemRoot(driveItem) || !item.parentId || isRoot) {
			item.parentId = null; // ensures that it has no parent
			item.driveId = driveId; // HACK: makeItem() cannot set the driveId property of the root
			itemdb.upsert(item);
			return;
		}

		bool unwanted;
		unwanted |= skippedItems.find(item.parentId).length != 0;
		unwanted |= selectiveSync.isNameExcluded(item.name);

		// check the item type
		if (!unwanted) {
			if (isItemFile(driveItem)) {
				//log.vlog("The item we are syncing is a file");
			} else if (isItemFolder(driveItem)) {
				//log.vlog("The item we are syncing is a folder");
			} else if (isItemRemote(driveItem)) {
				//log.vlog("The item we are syncing is a remote item");
				assert(isItemFolder(driveItem["remoteItem"]), "The remote item is not a folder");
			} else {
				log.vlog("This item type (", item.name, ") is not supported");
				unwanted = true;
			}
		}

		// check for selective sync
		string path;
		if (!unwanted) {
			// Is the item in the local database
			if (itemdb.idInLocalDatabase(item.driveId, item.parentId)){				
				path = itemdb.computePath(item.driveId, item.parentId) ~ "/" ~ item.name;
				path = buildNormalizedPath(path);
				unwanted = selectiveSync.isPathExcluded(path);
			} else {
				unwanted = true;
			}
		}

		// skip unwanted items early
		if (unwanted) {
			//log.vlog("Filtered out");
			skippedItems ~= item.id;
			return;
		}

		// check if the item has been seen before
		Item oldItem;
		bool cached = itemdb.selectById(item.driveId, item.id, oldItem);

		// check if the item is going to be deleted
		if (isItemDeleted(driveItem)) {
			// item.name is not available, so we get a bunch of meaningless log output
			// will fix this with wider logging changes being worked on
			//log.vlog("This item is marked for deletion:", item.name);
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
					log.vlog("The local item is unsynced, renaming");
					if (exists(oldPath)) safeRename(oldPath);
					cached = false;
				}
			}
		}

		// update the item
		if (cached) {
			applyChangedItem(oldItem, oldPath, item, path);
		} else {
			applyNewItem(item, path);
		}

		// save the item in the db
		if (cached) {
			itemdb.update(item);
		} else {
			itemdb.insert(item);
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
				log.vlog("The local item is out of sync, renaming...");
				safeRename(path);
			}
		}
		final switch (item.type) {
		case ItemType.file:
			downloadFileItem(item, path);
			break;
		case ItemType.dir:
		case ItemType.remote:
			log.log("Creating directory: ", path);
			mkdirRecurse(path);
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
					// TODO: force remote sync by deleting local item
					log.vlog("The destination is occupied, renaming the conflicting file...");
					safeRename(newPath);
				}
				rename(oldPath, newPath);
			}
			// handle changed content and mtime
			// HACK: use mtime+hash instead of cTag because of https://github.com/OneDrive/onedrive-api-docs/issues/765
			if (newItem.type == ItemType.file && oldItem.mtime != newItem.mtime && !testFileHash(newPath, newItem)) {
				downloadFileItem(newItem, newPath);
			} else {
				//log.vlog("The item content has not changed");
			}
			// handle changed time
			if (newItem.type == ItemType.file && oldItem.mtime != newItem.mtime) {
				setTimes(newPath, newItem.mtime, newItem.mtime);
			}
		} else {
			//log.vlog("", oldItem.name, " has not changed");
		}
	}

	// downloads a File resource
	private void downloadFileItem(Item item, string path)
	{
		assert(item.type == ItemType.file);
		write("Downloading ", path, "...");
		onedrive.downloadById(item.driveId, item.id, path);
		setTimes(path, item.mtime, item.mtime);
		writeln(" done.");
		log.fileOnly("Downloading ", path, "... done.");
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
			log.log("Deleting item ", path);
			itemdb.deleteById(item.driveId, item.id);
			if (item.remoteDriveId != null) {
				// delete the linked remote folder
				itemdb.deleteById(item.remoteDriveId, item.remoteId);
			}
			if (exists(path)) {
				// path exists on the local system	
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
						log.log(e.msg);
					}
				}
			}
		}
		idsToDelete.length = 0;
		assumeSafeAppend(idsToDelete);
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
	}

	private void uploadDifferences(Item item)
	{
		log.vlog("Processing ", item.name);

		string path;
		bool unwanted = selectiveSync.isNameExcluded(item.name);
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
				// loop trough the children
				foreach (Item child; itemdb.selectChildren(item.driveId, item.id)) {
					uploadDifferences(child);
				}
			}
		} else {
			log.vlog("The directory has been deleted");
			uploadDeleteItem(item, path);
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
				// continue trough the linked folder
				assert(item.remoteDriveId && item.remoteId);
				Item remoteItem;
				bool found = itemdb.selectById(item.remoteDriveId, item.remoteId, remoteItem);
				assert(found);
				uploadDifferences(remoteItem);
			}
		} else {
			log.vlog("The directory has been deleted");
			uploadDeleteItem(item, path);
		}
	}

	private void uploadFileDifferences(Item item, string path)
	{
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
						write("Uploading file ", path, " ...");
						JSONValue response;
						
						// Are we using OneDrive Personal or OneDrive Business?
						// To solve 'Multiple versions of file shown on website after single upload' (https://github.com/abraunegg/onedrive/issues/2)
						// check what 'account type' this is as this issue only affects OneDrive Business so we need some extra logic here
						if (accountType == "personal"){
							// Original file upload logic
							if (getSize(path) <= thresholdFileSize) {
								try {
									response = onedrive.simpleUploadReplace(path, item.driveId, item.id, item.eTag);
								} catch (OneDriveException e) {
									// Resolve https://github.com/abraunegg/onedrive/issues/36
									if ((e.httpStatusCode == 409) || (e.httpStatusCode == 423)) {
										// The file is currently checked out or locked for editing by another user
										// We cant upload this file at this time
										writeln(" skipped.");
										log.fileOnly("Uploading file ", path, " ... skipped.");
										write("", path, " is currently checked out or locked for editing by another user.");
										log.fileOnly(path, " is currently checked out or locked for editing by another user.");
										return;
									}
								
									if (e.httpStatusCode == 504) {
										// HTTP request returned status code 504 (Gateway Timeout)
										// Try upload as a session
										response = session.upload(path, item.driveId, item.parentId, baseName(path), eTag);
									}
									else throw e;
								}
								writeln(" done.");
							} else {
								writeln("");
								response = session.upload(path, item.driveId, item.parentId, baseName(path), eTag);
								writeln(" done.");
							}	
						} else {
							// OneDrive Business Account - always use a session to upload
							writeln("");
							
							try {
								response = session.upload(path, item.driveId, item.parentId, baseName(path));
							} catch (OneDriveException e) {
							
								// Resolve https://github.com/abraunegg/onedrive/issues/36
								if ((e.httpStatusCode == 409) || (e.httpStatusCode == 423)) {
									// The file is currently checked out or locked for editing by another user
									// We cant upload this file at this time
									writeln(" skipped.");
									log.fileOnly("Uploading file ", path, " ... skipped.");
									writeln("", path, " is currently checked out or locked for editing by another user.");
									log.fileOnly(path, " is currently checked out or locked for editing by another user.");
									return;
								}
							}
														
							writeln(" done.");
							// As the session.upload includes the last modified time, save the response
							saveItem(response);
						}
						log.fileOnly("Uploading file ", path, " ... done.");
						// use the cTag instead of the eTag because Onedrive may update the metadata of files AFTER they have been uploaded
						eTag = response["cTag"].str;
					}
					if (accountType == "personal"){
						// If Personal, call to update the modified time as stored on OneDrive
						uploadLastModifiedTime(item.driveId, item.id, eTag, localModifiedTime.toUTC());
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
			log.vlog("The file has been deleted locally");
			uploadDeleteItem(item, path);
		}
	}

	private void uploadNewItems(string path)
	{
		//	https://support.microsoft.com/en-us/help/3125202/restrictions-and-limitations-when-you-sync-files-and-folders
		//  If the path is greater than allowed characters, then one drive will return a '400 - Bad Request' 
		//  Need to ensure that the URI is encoded before the check is made
		//  400 Character Limit for OneDrive Business / Office 365
		//  430 Character Limit for OneDrive Personal
		auto maxPathLength = 0;
		if (accountType == "business"){
			// Business Account
			maxPathLength = 400;
		} else {
			// Personal Account
			maxPathLength = 430;
		}
		
		if(encodeComponent(path).length < maxPathLength){
			// path is less than maxPathLength

			// skip unexisting symbolic links
			if (isSymlink(path) && !exists(readLink(path))) {
				log.vlog("Skipping item - symbolic link: ", path);
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

			// filter out user configured items to skip
			if (path != ".") {
				if (selectiveSync.isNameExcluded(baseName(path))) {
					log.vlog("Skipping item - excluded by skip_file config: ", path);
					return;
				}
				if (selectiveSync.isPathExcluded(path)) {
					log.vlog("Skipping item - path excluded: ", path);
					return;
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
				auto entries = dirEntries(path, SpanMode.shallow, false);
				foreach (DirEntry entry; entries) {
					uploadNewItems(entry.name);
				}
			} else {
				// This item is a file
				// Can we upload this file - is there enough free space? - https://github.com/skilion/onedrive/issues/73
				auto fileSize = getSize(path);
				if ((remainingFreeSpace - fileSize) > 0){
					Item item;
					if (!itemdb.selectByPath(path, defaultDriveId, item)) {
						uploadNewFile(path);
						remainingFreeSpace = (remainingFreeSpace - fileSize);
						log.vlog("Remaining free space: ", remainingFreeSpace);
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
					onedrivePathDetails = onedrive.getPathDetails(parentPath);
				} catch (OneDriveException e) {
					if (e.httpStatusCode == 404) {
						// Parent does not exist ... need to create parent
						uploadCreateDir(parentPath);
					}
				}
								
				// configure the data
				parent.driveId = onedrivePathDetails["parentReference"]["driveId"].str; // Should give something like 12345abcde1234a1
				parent.id = onedrivePathDetails["id"].str; // This item's ID. Should give something like 12345ABCDE1234A1!101
			}
		
			// test if the path we are going to create already exists on OneDrive
			try {
				onedrive.getPathDetails(path);
			} catch (OneDriveException e) {
				if (e.httpStatusCode == 404) {
					// The directory was not found 
					log.vlog("The requested directory to create was not found on OneDrive - creating remote directory: ", path);

					// Perform the database lookup
					enforce(itemdb.selectById(parent.driveId, parent.id, parent), "The parent item id is not in the database");
					JSONValue driveItem = [
							"name": JSONValue(baseName(path)),
							"folder": parseJSON("{}")
					];
					
					// Submit the creation request
					JSONValue response;
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
					
					saveItem(response);
					log.vlog("Successfully created the remote directory ", path, " on OneDrive");
					return;
				}
			} 
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
				saveItem(res);
			}
		}
	}
	
	private void uploadNewFile(string path)
	{
		Item parent;
		
		// Check the database for the parent
		enforce(itemdb.selectByPath(dirName(path), defaultDriveId, parent), "The parent item is not in the local database");
		
		// Maximum file size upload
		//	https://support.microsoft.com/en-au/help/3125202/restrictions-and-limitations-when-you-sync-files-and-folders
		//	1. OneDrive Business say's 15GB
		//	2. Another article updated April 2018 says 20GB:
		//		https://answers.microsoft.com/en-us/onedrive/forum/odoptions-oddesktop-sdwin10/personal-onedrive-file-upload-size-max/a3621fc9-b766-4a99-99f8-bcc01ccb025f
		
		// Use smaller size for now
		auto maxUploadFileSize = 16106127360; // 15GB
		//auto maxUploadFileSize = 21474836480; // 20GB
		auto thisFileSize = getSize(path);
		
		if (thisFileSize <= maxUploadFileSize){
			// Resolves: https://github.com/skilion/onedrive/issues/121, https://github.com/skilion/onedrive/issues/294, https://github.com/skilion/onedrive/issues/329
		
			// To avoid a 409 Conflict error - does the file actually exist on OneDrive already?
			JSONValue fileDetailsFromOneDrive;
			
			// Does this 'file' already exist on OneDrive?
			try {
				// test if the local path exists on OneDrive
				fileDetailsFromOneDrive = onedrive.getPathDetails(path);
			} catch (OneDriveException e) {
				if (e.httpStatusCode == 404) {
					// The file was not found on OneDrive, need to upload it		
					write("Uploading file ", path, " ...");
					JSONValue response;
					
					// Resolve https://github.com/abraunegg/onedrive/issues/37
					if (thisFileSize == 0){
						// We can only upload zero size files via simpleFileUpload regardless of account type
						// https://github.com/OneDrive/onedrive-api-docs/issues/53
						response = onedrive.simpleUpload(path, parent.driveId, parent.id, baseName(path));
						writeln(" done.");
					} else {
						// File is not a zero byte file
						// Are we using OneDrive Personal or OneDrive Business?
						// To solve 'Multiple versions of file shown on website after single upload' (https://github.com/abraunegg/onedrive/issues/2)
						// check what 'account type' this is as this issue only affects OneDrive Business so we need some extra logic here
						if (accountType == "personal"){
							// Original file upload logic
							if (getSize(path) <= thresholdFileSize) {
								try {
										response = onedrive.simpleUpload(path, parent.driveId, parent.id, baseName(path));
									} catch (OneDriveException e) {
										if (e.httpStatusCode == 504) {
											// HTTP request returned status code 504 (Gateway Timeout)
											// Try upload as a session
											response = session.upload(path, parent.driveId, parent.id, baseName(path));
										}
										else throw e;
									}
									writeln(" done.");
							} else {
								writeln("");
								response = session.upload(path, parent.driveId, parent.id, baseName(path));
								writeln(" done.");
							}
						} else {
							// OneDrive Business Account - always use a session to upload
							writeln("");
							response = session.upload(path, parent.driveId, parent.id, baseName(path));
							writeln(" done.");
						}
					}
					
					// Log action to log file
					log.fileOnly("Uploading file ", path, " ... done.");
					
					// The file was uploaded
					ulong uploadFileSize = response["size"].integer;
					
					// In some cases the file that was uploaded was not complete, but 'completed' without errors on OneDrive
					// This has been seen with PNG / JPG files mainly, which then contributes to generating a 412 error when we attempt to update the metadata
					// Validate here that the file uploaded, at least in size, matches in the response to what the size is on disk
					if (thisFileSize != uploadFileSize){
						// OK .. the uploaded file does not match
						log.log("Uploaded file size does not match local file - upload failure - retrying");
						// Delete uploaded bad file
						onedrive.deleteById(response["parentReference"]["driveId"].str, response["id"].str, response["eTag"].str);
						// Re-upload
						uploadNewFile(path);
						return;
					} else {
						if ((accountType == "personal") || (thisFileSize == 0)){
							// Update the item's metadata on OneDrive
							string id = response["id"].str;
							string cTag = response["cTag"].str;
							SysTime mtime = timeLastModified(path).toUTC();
							// use the cTag instead of the eTag because OneDrive may update the metadata of files AFTER they have been uploaded
							uploadLastModifiedTime(parent.driveId, id, cTag, mtime);
							return;
						} else {
							// OneDrive Business Account - always use a session to upload
							// The session includes a Request Body element containing lastModifiedDateTime
							// which negates the need for a modify event against OneDrive
							saveItem(response);
							return;
						}
					}
				}
			}
			
			log.vlog("Requested file to upload exists on OneDrive - local database is out of sync for this file: ", path);
			
			// Is the local file newer than the uploaded file?
			SysTime localFileModifiedTime = timeLastModified(path).toUTC();
			SysTime remoteFileModifiedTime = SysTime.fromISOExtString(fileDetailsFromOneDrive["fileSystemInfo"]["lastModifiedDateTime"].str);
			
			if (localFileModifiedTime > remoteFileModifiedTime){
				// local file is newer
				log.vlog("Requested file to upload is newer than existing file on OneDrive");
				write("Uploading file ", path, " ...");
				JSONValue response;
				
				if (accountType == "personal"){
					// OneDrive Personal account upload handling
					if (getSize(path) <= thresholdFileSize) {
						response = onedrive.simpleUpload(path, parent.driveId, parent.id, baseName(path));
						writeln(" done.");
					} else {
						writeln("");
						response = session.upload(path, parent.driveId, parent.id, baseName(path));
						writeln(" done.");
					}
					string id = response["id"].str;
					string cTag = response["cTag"].str;
					SysTime mtime = timeLastModified(path).toUTC();
					// use the cTag instead of the eTag because Onedrive may update the metadata of files AFTER they have been uploaded
					uploadLastModifiedTime(parent.driveId, id, cTag, mtime);
				} else {
					// OneDrive Business account upload handling
					writeln("");
					response = session.upload(path, parent.driveId, parent.id, baseName(path));
					writeln(" done.");
					saveItem(response);
				}
				
				// Log action to log file
				log.fileOnly("Uploading file ", path, " ... done.");
				
			} else {
				// Save the details of the file that we got from OneDrive
				log.vlog("Updating the local database with details for this file: ", path);
				saveItem(fileDetailsFromOneDrive);
			}
		} else {
			// Skip file - too large
			log.log("Skipping uploading this new file as it exceeds the maximum size allowed by OneDrive: ", path);
		}
	}

	private void uploadDeleteItem(Item item, string path)
	{
		log.log("Deleting item from OneDrive: ", path);
		
		if ((item.driveId == "") && (item.id == "") && (item.eTag == "")){
			// These are empty ... we cannot delete if this is empty ....
			JSONValue onedrivePathDetails = onedrive.getPathDetails(path); // Returns a JSON String for the OneDrive Path
			item.driveId = onedrivePathDetails["parentReference"]["driveId"].str; // Should give something like 12345abcde1234a1
			item.id = onedrivePathDetails["id"].str; // This item's ID. Should give something like 12345ABCDE1234A1!101
			item.eTag = onedrivePathDetails["eTag"].str; // Should be something like aNjM2NjJFRUVGQjY2NjJFMSE5MzUuMA
		}
			
		try {
			onedrive.deleteById(item.driveId, item.id, item.eTag);
		} catch (OneDriveException e) {
			if (e.httpStatusCode == 404) log.vlog("OneDrive reported: The resource could not be found.");
			else throw e;
		}
		itemdb.deleteById(item.driveId, item.id);
		if (item.remoteId != null) {
			itemdb.deleteById(item.remoteDriveId, item.remoteId);
		}
	}

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
				log.vlog("OneDrive returned a 'HTTP 412 - Precondition Failed' - gracefully handling error");
				string nullTag = null;
				response = onedrive.updateById(driveId, id, data, nullTag);
			}
		} 
		saveItem(response);
	}

	private void saveItem(JSONValue jsonItem)
	{
		// Takes a JSON input and formats to an item which can be used by the database
		Item item = makeItem(jsonItem);
		
		// Add to the local database
		itemdb.upsert(item);
	}

	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_move
	void uploadMoveItem(string from, string to)
	{
		log.log("Moving ", from, " to ", to);
		Item fromItem, toItem, parentItem;
		if (!itemdb.selectByPath(from, defaultDriveId, fromItem)) {
			throw new SyncException("Can't move an unsynced item");
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
			saveItem(res);
		}
	}

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
			if (e.httpStatusCode == 404) log.log(e.msg);
			else throw e;
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
	
}
