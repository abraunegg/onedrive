import std.algorithm: find;
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

// construct an Item struct from a JSON driveItem
private Item makeItem(const ref JSONValue driveItem)
{
	Item item = {
		id: driveItem["id"].str,
		name: "name" in driveItem ? driveItem["name"].str : null, // name may be missing for deleted files in OneDrive Biz
		eTag: "eTag" in driveItem ? driveItem["eTag"].str : null, // eTag is not returned for the root in OneDrive Biz
		cTag: "cTag" in driveItem ? driveItem["cTag"].str : null, // cTag is missing in old files (and all folders in OneDrive Biz)
		mtime: "fileSystemInfo" in driveItem ? SysTime.fromISOExtString(driveItem["fileSystemInfo"]["lastModifiedDateTime"].str) : SysTime(0),
	};

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
		string driveId = defaultDriveId = onedrive.getDefaultDrive()["id"].str;
		string rootId = onedrive.getDefaultRoot["id"].str;
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
		// OK - it should exist, get the driveId and rootId for this folder
		log.vlog("Checking for differences from OneDrive ...");
		JSONValue onedrivePathDetails = onedrive.getPathDetails(path); // Returns a JSON String for the OneDrive Path
		
		// If the OneDrive Root is not in the local database, creating a remote folder will fail
		checkDatabaseForOneDriveRoot();
		
		// Configure the defaults
		defaultDriveId = onedrive.getDefaultDrive()["id"].str;
		string driveId = onedrivePathDetails["parentReference"]["driveId"].str; // Should give something like 12345abcde1234a1
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
		} else {
			log.vlog("OneDrive Root exists in the database");
		}
	}
	
	// create a directory on OneDrive without syncing
	auto createDirectoryNoSync(string path)
	{
		// Attempt to create the requested path within OneDrive without performing a sync
		log.vlog("Attempting to create the requested path within OneDrive");
		
		// If the OneDrive Root is not in the local database, creating a remote folder will fail
		checkDatabaseForOneDriveRoot();
		
		// Handle the remote folder creation and updating of the local database without performing a sync
		uploadCreateDir(path);
	}
	
	// delete a directory on OneDrive without syncing
	auto deleteDirectoryNoSync(string path)
	{
		// Set defaults for the root folder
		defaultDriveId = onedrive.getDefaultDrive()["id"].str;
		string rootId = onedrive.getDefaultRoot["id"].str;
		
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
			log.vlog("The requested directory to delete was found in the local database. Processing the delection normally");
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
		JSONValue changes;
		string deltaLink = itemdb.getDeltaLink(driveId, id);
		log.vlog("Applying changes of Path ID: " ~ id);
		
		// Get the OneDrive Root ID
		string oneDriveRootId = onedrive.getDefaultRoot["id"].str;
		
		for (;;) {
			try {
				changes = onedrive.viewChangesById(driveId, id, deltaLink);
			} catch (OneDriveException e) {
				if (e.httpStatusCode == 410) {
					log.vlog("Delta link expired, resyncing...");
					deltaLink = null;
					continue;
				} else {
					throw e;
				}
			}
			foreach (item; changes["value"].array) {			
				// Test is this is the OneDrive Root - not say a single folder root sync
				bool isRoot = false;
				if ((id == oneDriveRootId) && (item["name"].str == "root")) { // fix for https://github.com/skilion/onedrive/issues/269
					// This IS the OneDrive Root
					isRoot = true;
				}
				// Apply the change
				applyDifference(item, driveId, isRoot);
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
		//log.vlog("Processing item to apply differences");

		if (isItemRoot(driveItem) || !item.parentId || isRoot) {
			log.vlog("Adding OneDrive Root to the local database");
			item.parentId = null; // ensures that it has no parent
			item.driveId = driveId; // HACK: makeItem() cannot set the driveId propery of the root
			
			// What parent.driveId and parent.id are we using?
			//log.vlog("Parent Drive ID: ", item.driveId);
			//log.vlog("Parent ID:       ", item.parentId);
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
			path = itemdb.computePath(item.driveId, item.parentId) ~ "/" ~ item.name;
			path = buildNormalizedPath(path);
			unwanted = selectiveSync.isPathExcluded(path);
		}

		// skip unwanted items early
		if (unwanted) {
			log.vlog("Filtered out");
			skippedItems ~= item.id;
			return;
		}

		// check if the item has been seen before
		Item oldItem;
		bool cached = itemdb.selectById(item.driveId, item.id, oldItem);

		// check if the item is going to be deleted
		if (isItemDeleted(driveItem)) {
			log.vlog("The item is marked for deletion");
			if (cached) {
				// flag to delete
				idsToDelete ~= [item.driveId, item.id];
			} else {
				// flag to ignore
				skippedItems ~= item.id;
			}
			return;
		}

		// rename the local item if it is unsynced and there is a new version of it
		string oldPath;
		if (cached && item.eTag != oldItem.eTag) {
			oldPath = itemdb.computePath(item.driveId, item.id);
			if (!isItemSynced(oldItem, oldPath)) {
				log.vlog("The local item is unsynced, renaming");
				if (exists(oldPath)) safeRename(oldPath);
				cached = false;
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

		// sync remote folder
		// https://github.com/OneDrive/onedrive-api-docs/issues/764
		/*if (isItemRemote(driveItem)) {
			log.log("Syncing remote folder: ", path);
			applyDifferences(item.remoteDriveId, item.remoteId);
		}*/
	}

	// download an item that was not synced before
	private void applyNewItem(Item item, string path)
	{
		if (exists(path)) {
			if (isItemSynced(item, path)) {
				log.vlog("The item is already present");
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
			log.log("Creating directory ", path);
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
			log.log("Deleting ", path);
			itemdb.deleteById(item.driveId, item.id);
			if (item.remoteDriveId != null) {
				// delete the linked remote folder
				itemdb.deleteById(item.remoteDriveId, item.remoteId);
			}
			if (exists(path)) {
				if (isFile(path)) {
					remove(path);
				} else {
					try {
						if (item.remoteDriveId == null) {
							rmdir(path);
						} else {
							// children of remote items are not enumerated
							rmdirRecurse(path);
						}
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
		// Make sure the OneDrive Root is in the database
		checkDatabaseForOneDriveRoot();
	
		// make sure defaultDriveId is set
		if (defaultDriveId == ""){
			// defaultDriveId is not set ... odd ..
			defaultDriveId = onedrive.getDefaultDrive()["id"].str;
		}
	
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
			log.vlog("Filtered out");
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
						write("Uploading file ", path, "...");
						JSONValue response;
						if (getSize(path) <= thresholdFileSize) {
							response = onedrive.simpleUploadReplace(path, item.driveId, item.id, item.eTag);
							writeln(" done.");
						} else {
							writeln("");
							response = session.upload(path, item.driveId, item.parentId, baseName(path), eTag);
						}
						log.vlog("Uploading file ", path, "... done.");
						// saveItem(response); redundant
						// use the cTag instead of the eTag because Onedrive may update the metadata of files AFTER they have been uploaded
						eTag = response["cTag"].str;
					}
					uploadLastModifiedTime(item.driveId, item.id, eTag, localModifiedTime.toUTC());
				} else {
					log.vlog("The file has not changed");
				}
			} else {
				log.vlog("The item was a file but now is a directory");
				uploadDeleteItem(item, path);
				uploadCreateDir(path);
			}
		} else {
			log.vlog("The file has been deleted");
			uploadDeleteItem(item, path);
		}
	}

	private void uploadNewItems(string path)
	{
		//	https://github.com/OneDrive/onedrive-api-docs/issues/443
		//  If the path is greater than 430 characters, then one drive will return a '400 - Bad Request' 
		//  Need to ensure that the URI is encoded before the check is made
		if(encodeComponent(path).length < 430){
			// path is less than 430 characters

			if (defaultDriveId == ""){
				// defaultDriveId is not set ... odd ..
				defaultDriveId = onedrive.getDefaultDrive()["id"].str;
			}
			
			// skip unexisting symbolic links
			if (isSymlink(path) && !exists(readLink(path))) {
				return;
			}

			// skip filtered items
			if (path != ".") {
				if (selectiveSync.isNameExcluded(baseName(path))) {
					return;
				}
				if (selectiveSync.isPathExcluded(path)) {
					return;
				}
			}

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
				Item item;
				if (!itemdb.selectByPath(path, defaultDriveId, item)) {
					uploadNewFile(path);
				}
			}
		} else {
			// This path was skipped - why?
			log.log("Skipping item '", path, "' due to the full path exceeding 430 characters (Microsoft OneDrive limitation)");
		}
	}

	private void uploadCreateDir(const(string) path)
	{
		log.vlog("OneDrive Client requested to create remote path: ", path);
		Item parent;
		
		// Was the path entered the root path?
		if (path == "."){
			// We cant create this directory, as this would essentially equal the users OneDrive root:/
			checkDatabaseForOneDriveRoot();
		} else {
			// If this is null or empty - we cant query the database properly
			if ((parent.driveId == "") && (parent.id == "")){
				// These are both empty .. not good
				//log.vlog("WHOOPS: Well this is odd - parent.driveId & parent.id are empty - we have to query OneDrive for some values for the parent");
				
				// What path to use?
				string parentPath = dirName(path);		// will be either . or something else
				//log.vlog("WHOOPS FIX: Query OneDrive path details for parent: ", parentPath);
				
				if (parentPath == "."){
					// We cant create this directory, as this would essentially equal the users OneDrive root:/
					checkDatabaseForOneDriveRoot();
				}
				
				try {
					onedrive.getPathDetails(parentPath);
				} catch (OneDriveException e) {
					if (e.httpStatusCode == 404) {
						// Parent does not exist ... need to create parent
						uploadCreateDir(parentPath);
					}
				}
				
				// Get the Parent Path Details
				JSONValue onedrivePathDetails = onedrive.getPathDetails(parentPath); // Returns a JSON String for the OneDrive Path
				
				// JSON Response
				//log.vlog("WHOOPS JSON Response: ", onedrivePathDetails);
				
				// configure the data
				parent.driveId = onedrivePathDetails["parentReference"]["driveId"].str; // Should give something like 12345abcde1234a1
				parent.id = onedrivePathDetails["id"].str; // This item's ID. Should give something like 12345ABCDE1234A1!101
				
				// What parent.driveId and parent.id did we find?
				//log.vlog("Using Parent DriveID: ", parent.driveId);
				//log.vlog("Using Parent ID:      ", parent.id);
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
					auto res = onedrive.createById(parent.driveId, parent.id, driveItem);
					// What is returned?
					//log.vlog("Create Folder Response JSON: ", res);
					saveItem(res);
					log.vlog("Sucessfully created the remote directory ", path, " on OneDrive");
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
		
		if (defaultDriveId == ""){
			// defaultDriveId is not set ... odd ..
			defaultDriveId = onedrive.getDefaultDrive()["id"].str;
		}
		
		// Check the database for the parent
		enforce(itemdb.selectByPath(dirName(path), defaultDriveId, parent), "The parent item is not in the local database");
		
		// To avoid a 409 Conflict error - does the file actually exist on OneDrive already?
		JSONValue fileDetailsFromOneDrive;
		
		// Does this 'file' already exist on OneDrive?
		try {
			// test if the local path exists on OneDrive
			fileDetailsFromOneDrive = onedrive.getPathDetails(path);
		} catch (OneDriveException e) {
			if (e.httpStatusCode == 404) {
				// The file was not found on OneDrive, need to upload it		
				write("Uploading file ", path, "...");
				JSONValue response;
				if (getSize(path) <= thresholdFileSize) {
					response = onedrive.simpleUpload(path, parent.driveId, parent.id, baseName(path));
					writeln(" done.");
				} else {
					writeln("");
					response = session.upload(path, parent.driveId, parent.id, baseName(path));
				}
				log.vlog("Uploading file ", path, "... done.");
				string id = response["id"].str;
				string cTag = response["cTag"].str;
				SysTime mtime = timeLastModified(path).toUTC();
				// use the cTag instead of the eTag because Onedrive may update the metadata of files AFTER they have been uploaded
				uploadLastModifiedTime(parent.driveId, id, cTag, mtime);
				return;
			}
		}
		
		log.vlog("Requested file to upload exists on OneDrive - local database is out of sync for this file: ", path);
		
		// Is the local file newer than the uploaded file?
		SysTime localFileModifiedTime = timeLastModified(path).toUTC();
		SysTime remoteFileModifiedTime = SysTime.fromISOExtString(fileDetailsFromOneDrive["fileSystemInfo"]["lastModifiedDateTime"].str);
		
		if (localFileModifiedTime > remoteFileModifiedTime){
			// local file is newer
			log.vlog("Requested file to upload is newer than existing file on OneDrive");
			
			write("Uploading file ", path, "...");
			JSONValue response;
			if (getSize(path) <= thresholdFileSize) {
				response = onedrive.simpleUpload(path, parent.driveId, parent.id, baseName(path));
				writeln(" done.");
			} else {
				writeln("");
				response = session.upload(path, parent.driveId, parent.id, baseName(path));
			}
			log.vlog("Uploading file ", path, "... done.");
			string id = response["id"].str;
			string cTag = response["cTag"].str;
			SysTime mtime = timeLastModified(path).toUTC();
			// use the cTag instead of the eTag because Onedrive may update the metadata of files AFTER they have been uploaded
			uploadLastModifiedTime(parent.driveId, id, cTag, mtime);
		} else {
			// Save the details of the file that we got from OneDrive
			log.vlog("Updating the local database with details for this file: ", path);
			saveItem(fileDetailsFromOneDrive);
		}
	}

	private void uploadDeleteItem(Item item, string path)
	{
		log.log("Deleting directory from OneDrive: ", path);
		
		if ((item.driveId == "") && (item.id == "") && (item.eTag == "")){
			// These are empty ... we cannot delete if this is empty ....
			JSONValue onedrivePathDetails = onedrive.getPathDetails(path); // Returns a JSON String for the OneDrive Path
			//log.vlog("WHOOPS JSON Response: ", onedrivePathDetails);
			item.driveId = onedrivePathDetails["parentReference"]["driveId"].str; // Should give something like 12345abcde1234a1
			item.id = onedrivePathDetails["id"].str; // This item's ID. Should give something like 12345ABCDE1234A1!101
			item.eTag = onedrivePathDetails["eTag"].str; // Should be something like aNjM2NjJFRUVGQjY2NjJFMSE5MzUuMA
		
			//log.vlog("item.driveId = ", item.driveId);
			//log.vlog("item.id = ", item.id);
			//log.vlog("item.eTag = ", item.eTag);
		}
			
		try {
			onedrive.deleteById(item.driveId, item.id, item.eTag);
		} catch (OneDriveException e) {
			if (e.httpStatusCode == 404) log.log(e.msg);
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
		auto response = onedrive.updateById(driveId, id, data, eTag);
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
