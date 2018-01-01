import std.algorithm: find;
import std.array: array;
import std.datetime;
import std.exception: enforce;
import std.file, std.json, std.path;
import std.regex;
import std.stdio, std.string;
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
		item.parentDriveId = item.driveId; // TODO: parentDriveId is redundant
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
		// root folder
		string driveId = onedrive.getDefaultDrive()["id"].str;
		string rootId = onedrive.getDefaultRoot["id"].str;
		applyDifferences(driveId, rootId);

		// check all remote folders
		// https://github.com/OneDrive/onedrive-api-docs/issues/764
		Item[] items = itemdb.selectRemoteItems();
		foreach (item; items) applyDifferences(item.remoteDriveId, item.remoteId);
	}


	// download the new changes of a specific item
	private void applyDifferences(string driveId, const(char)[] id)
	{
		JSONValue changes;
		string deltaLink = itemdb.getDeltaLink(driveId, id);
		log.vlog("Applying changes of " ~ id);
		do {
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
				applyDifference(item, driveId);
			}

			// the response may contain either @odata.deltaLink or @odata.nextLink
			if ("@odata.deltaLink" in changes) deltaLink = changes["@odata.deltaLink"].str;
			if (deltaLink) itemdb.setDeltaLink(driveId, id, deltaLink);
			if ("@odata.nextLink" in changes) deltaLink = changes["@odata.nextLink"].str;
		} while ("@odata.nextLink" in changes);

		// delete items in idsToDelete
		if (idsToDelete.length > 0) deleteItems();
		// empty the skipped items
		skippedItems.length = 0;
		assumeSafeAppend(skippedItems);
	}

	// process the change of a single DriveItem
	private void applyDifference(JSONValue driveItem, string driveId)
	{
		Item item = makeItem(driveItem);
		log.vlog("Processing ", item.id, " ", item.name);

		if (isItemRoot(driveItem) || !item.parentDriveId) {
			log.vlog("Root");
			item.driveId = driveId; // HACK: makeItem() cannot set the driveId propery of the root
			itemdb.upsert(item);
			return;
		}

		bool unwanted;
		unwanted |= skippedItems.find(item.parentId).length != 0;
		unwanted |= selectiveSync.isNameExcluded(item.name);

		// check the item type
		if (!unwanted) {
			if (isItemFile(driveItem)) {
				log.vlog("File");
			} else if (isItemFolder(driveItem)) {
				log.vlog("Folder");
			} else if (isItemRemote(driveItem)) {
				log.vlog("Remote item");
				assert(isItemFolder(driveItem["remoteItem"]), "The remote item is not a folder");
			} else {
				log.vlog("The item type is not supported");
				unwanted = true;
			}
		}

		// check for selective sync
		string path;
		if (!unwanted) {
			path = itemdb.computePath(item.parentDriveId, item.parentId) ~ "/" ~ item.name;
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
				log.vlog("The item content has not changed");
			}
			// handle changed time
			if (newItem.type == ItemType.file && oldItem.mtime != newItem.mtime) {
				setTimes(newPath, newItem.mtime, newItem.mtime);
			}
		} else {
			log.vlog("The item has not changed");
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
	void scanForDifferences(string path = ".")
	{
		log.vlog("Uploading differences of ", path);
		Item item;
		if (itemdb.selectByPath(path, item)) {
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
						write("Uploading ", path, "...");
						JSONValue response;
						if (getSize(path) <= thresholdFileSize) {
							response = onedrive.simpleUploadReplace(path, item.driveId, item.id, item.eTag);
							writeln(" done.");
						} else {
							writeln("");
							response = session.upload(path, item.parentDriveId, item.parentId, baseName(path), eTag);
						}
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
			if (!itemdb.selectByPath(path, item)) {
				uploadCreateDir(path);
			}
			// recursively traverse children
			auto entries = dirEntries(path, SpanMode.shallow, false);
			foreach (DirEntry entry; entries) {
				uploadNewItems(entry.name);
			}
		} else {
			Item item;
			if (!itemdb.selectByPath(path, item)) {
				uploadNewFile(path);
			}
		}
	}

	private void uploadCreateDir(const(char)[] path)
	{
		log.log("Creating folder ", path, "...");
		Item parent;
		enforce(itemdb.selectByPath(dirName(path), parent), "The parent item is not in the database");
		JSONValue driveItem = [
			"name": JSONValue(baseName(path)),
			"folder": parseJSON("{}")
		];
		auto res = onedrive.createById(parent.driveId, parent.id, driveItem);
		saveItem(res);
		writeln(" done.");
	}

	private void uploadNewFile(string path)
	{
		write("Uploading file ", path, "...");
		Item parent;
		enforce(itemdb.selectByPath(dirName(path), parent), "The parent item is not in the database");
		JSONValue response;
		if (getSize(path) <= thresholdFileSize) {
			response = onedrive.simpleUpload(path, parent.driveId, parent.id, baseName(path));
			writeln(" done.");
		} else {
			writeln("");
			response = session.upload(path, parent.driveId, parent.id, baseName(path));
		}
		string id = response["id"].str;
		string cTag = response["cTag"].str;
		SysTime mtime = timeLastModified(path).toUTC();
		// use the cTag instead of the eTag because Onedrive may update the metadata of files AFTER they have been uploaded
		uploadLastModifiedTime(parent.driveId, id, cTag, mtime);
	}

	private void uploadDeleteItem(Item item, const(char)[] path)
	{
		log.log("Deleting ", path);
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
		Item item = makeItem(jsonItem);
		itemdb.upsert(item);
	}

	void uploadMoveItem(string from, string to)
	{
		log.log("Moving remote item: ", from, " -> ", to);
		Item fromItem, toItem, parentItem;
		if (!itemdb.selectByPath(from, fromItem)) {
			throw new SyncException("Can't move an unsynced item");
		}
		if (itemdb.selectByPath(to, toItem)) {
			// the destination has been overridden
			uploadDeleteItem(toItem, to);
		}
		if (!itemdb.selectByPath(to.dirName, parentItem)) {
			throw new SyncException("Can't move an item to an unsynced directory");
		}
		JSONValue diff = ["name": baseName(to)];
		diff["parentReference"] = JSONValue([
			"id": parentItem.id
		]);
		auto res = onedrive.updateById(fromItem.driveId, fromItem.id, diff, fromItem.eTag);
		saveItem(res);
		string driveId = res["parentReference"]["driveId"].str;
		string id = res["id"].str;
		string eTag = res["eTag"].str;
		uploadLastModifiedTime(driveId, id, eTag, timeLastModified(to).toUTC());
	}

	void deleteByPath(const(char)[] path)
	{
		Item item;
		if (!itemdb.selectByPath(path, item)) {
			throw new SyncException("Can't delete an unsynced item");
		}
		try {
			uploadDeleteItem(item, path);
		} catch (OneDriveException e) {
			if (e.httpStatusCode == 404) log.log(e.msg);
			else throw e;
		}
	}
}
