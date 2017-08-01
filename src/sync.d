import std.algorithm;
import std.net.curl: CurlTimeoutException;
import std.exception: ErrnoException;
import std.datetime, std.file, std.json, std.path;
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
	// HACK: fix for https://github.com/skilion/onedrive/issues/157
	return ("deleted" in item) || ("fileSystemInfo" !in item && "remoteItem" !in item);
}

private bool isItemRoot(const ref JSONValue item)
{
	return ("root" in item) != null;
}

private bool isItemRemote(const ref JSONValue item)
{
	return ("remoteItem" in item) != null;
}

// HACK: OneDrive Biz does not return parentReference for the root
string defaultDriveId;

private Item makeItem(const ref JSONValue jsonItem)
{
	ItemType type;
	if (isItemFile(jsonItem)) {
		type = ItemType.file;
	} else if (isItemFolder(jsonItem)) {
		type = ItemType.dir;
	} else if (isItemRemote(jsonItem)) {
		type = ItemType.remote;
	}

	Item item = {
		driveId: isItemRoot(jsonItem) ? defaultDriveId : jsonItem["parentReference"]["driveId"].str,
		id: jsonItem["id"].str,
		name: "name" in jsonItem ? jsonItem["name"].str : null, // name may be missing for deleted files in OneDrive Biz
		type: type,
		eTag: "eTag" in jsonItem ? jsonItem["eTag"].str : null, // eTag is not returned for the root in OneDrive Biz
		cTag: "cTag" in jsonItem ? jsonItem["cTag"].str : null, // cTag is missing in old files (and all folders)
		mtime: "fileSystemInfo" in jsonItem ? SysTime.fromISOExtString(jsonItem["fileSystemInfo"]["lastModifiedDateTime"].str) : SysTime(0),
		parentDriveId: isItemRoot(jsonItem) ? null : jsonItem["parentReference"]["driveId"].str,
		parentId: isItemRoot(jsonItem) ? null : jsonItem["parentReference"]["id"].str
	};

	// extract the file hash
	if (isItemFile(jsonItem)) {
		if ("hashes" in jsonItem["file"]) {
			if ("crc32Hash" in jsonItem["file"]["hashes"]) {
				item.crc32Hash = jsonItem["file"]["hashes"]["crc32Hash"].str;
			} else if ("sha1Hash" in jsonItem["file"]["hashes"]) {
				item.sha1Hash = jsonItem["file"]["hashes"]["sha1Hash"].str;
			} else if ("quickXorHash" in jsonItem["file"]["hashes"]) {
				item.quickXorHash = jsonItem["file"]["hashes"]["quickXorHash"].str;
			} else {
				log.vlog("The file does not have any hash");
			}
		}
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
    @nogc @safe pure nothrow this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable next = null)
    {
        super(msg, file, line, next);
    }

    @nogc @safe pure nothrow this(string msg, Throwable next, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line, next);
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

	void applyDifferences()
	{
		log.vlog("Applying differences ...");

		// restore the last known state
		string deltaLink;
		try {
			deltaLink = readText(cfg.deltaLinkFilePath);
		} catch (FileException e) {
			// swallow exception
		}

		try {
			defaultDriveId = onedrive.getDefaultDrive()["id"].str;
			JSONValue changes;
			do {
				// get changes from the server
				try {
					changes = onedrive.viewChangesByPath(".", deltaLink);
				} catch (OneDriveException e) {
					if (e.httpStatusCode == 410) {
						log.log("Delta link expired, resyncing");
						deltaLink = null;
						continue;
					} else {
						throw e;
					}
				}
				foreach (item; changes["value"].array) {
					applyDifference(item);
				}
				if ("@odata.nextLink" in changes) deltaLink = changes["@odata.nextLink"].str;
				if ("@odata.deltaLink" in changes) deltaLink = changes["@odata.deltaLink"].str;
				std.file.write(cfg.deltaLinkFilePath, deltaLink);
			} while ("@odata.nextLink" in changes);
		} catch (ErrnoException e) {
			throw new SyncException(e.msg, e);
		} catch (FileException e) {
			throw new SyncException(e.msg, e);
		} catch (CurlTimeoutException e) {
			throw new SyncException(e.msg, e);
		} catch (OneDriveException e) {
			throw new SyncException(e.msg, e);
		}
		// delete items in idsToDelete
		if (idsToDelete.length > 0) deleteItems();
		// empty the skipped items
		skippedItems.length = 0;
		assumeSafeAppend(skippedItems);
	}

	private void applyDifference(JSONValue jsonItem)
	{
		log.vlog(jsonItem["id"].str, " ", "name" in jsonItem ? jsonItem["name"].str : null);
		Item item = makeItem(jsonItem);

		string path = ".";
		bool unwanted;
		unwanted |= skippedItems.find(item.parentId).length != 0;
		unwanted |= selectiveSync.isNameExcluded(item.name);

		if (!unwanted && !isItemRoot(jsonItem)) {
			// delay path computation after assuring the item parent is not excluded
			path = itemdb.computePath(item.parentDriveId, item.parentId) ~ "/" ~ item.name;
			// selective sync
			unwanted |= selectiveSync.isPathExcluded(path);
		}

		// skip unwanted items early
		if (unwanted) {
			log.vlog("Filtered out");
			skippedItems ~= item.id;
			return;
		}

		// check the item type
		if (isItemRemote(jsonItem)) {
			// TODO
			// check name change
			// scan the children later
			// fix child references
			log.vlog("Remote items are not supported yet");
			skippedItems ~= item.id;
			return;
		} else if (!isItemFile(jsonItem) && !isItemFolder(jsonItem) && !isItemDeleted(jsonItem)) {
			log.vlog("The item is neither a file nor a directory, skipping");
			skippedItems ~= item.id;
			return;
		}

		// check if the item has been seen before
		Item oldItem;
		bool cached = itemdb.selectById(item.driveId, item.id, oldItem);

		// check if the item is going to be deleted
		if (isItemDeleted(jsonItem)) {
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

		if (!cached) {
			applyNewItem(item, path);
		} else {
			applyChangedItem(oldItem, oldPath, item, path);
		}

		// save the item in the db
		if (oldItem.id) {
			itemdb.update(item);
		} else {
			itemdb.insert(item);
		}
	}

	private void applyNewItem(Item item, string path)
	{
		if (exists(path)) {
			if (isItemSynced(item, path)) {
				log.vlog("The item is already present");
				// ensure the modified time is correct
				setTimes(path, item.mtime, item.mtime);
				return;
			} else {
				log.vlog("The local item is out of sync, renaming...");
				safeRename(path);
			}
		}
		final switch (item.type) {
		case ItemType.file:
			log.log("Downloading: ", path);
			onedrive.downloadById(item.id, path);
			break;
		case ItemType.dir:
			log.log("Creating directory: ", path);
			//Use mkdirRecuse to deal nested dir
			mkdirRecurse(path);
			break;
		case ItemType.remote:
			assert(0);
		}
		setTimes(path, item.mtime, item.mtime);
	}

	// update a local item
	// the local item is assumed to be in sync with the local db
	private void applyChangedItem(Item oldItem, string oldPath, Item newItem, string newPath)
	{
		assert(oldItem.driveId == newItem.driveId);
		assert(oldItem.id == newItem.id);
		assert(oldItem.type == newItem.type);

		if (oldItem.eTag != newItem.eTag) {
			if (oldPath != newPath) {
				log.log("Moving: ", oldPath, " -> ", newPath);
				if (exists(newPath)) {
					log.vlog("The destination is occupied, renaming the conflicting file...");
					safeRename(newPath);
				}
				rename(oldPath, newPath);
			}
			if (newItem.type == ItemType.file && oldItem.cTag != newItem.cTag) {
				log.log("Downloading: ", newPath);
				onedrive.downloadById(newItem.id, newPath);
			}
			setTimes(newPath, newItem.mtime, newItem.mtime);
		} else {
			log.vlog("The item has not changed");
		}
	}

	// returns true if the given item corresponds to the local one
	private bool isItemSynced(Item item, string path)
	{
		if (!exists(path)) return false;
		final switch (item.type) {
		case ItemType.file:
			if (isFile(path)) {
				SysTime localModifiedTime = timeLastModified(path);
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
			if (isDir(path)) {
				return true;
			} else {
				log.vlog("The local item is a file but should be a directory");
			}
			break;
		case ItemType.remote:
			assert(0);
		}
		return false;
	}

	private void deleteItems()
	{
		log.vlog("Deleting files ...");
		foreach_reverse (i; idsToDelete) {
			Item item;
			if (!itemdb.selectById(i[0], i[1], item)) continue; // check if the item is in the db
			string path = itemdb.computePath(i[0], i[1]);
			itemdb.deleteById(i[0], i[1]);
			if (exists(path)) {
				if (isFile(path)) {
					remove(path);
					log.log("Deleted file: ", path);
				} else {
					try {
						rmdir(path);
						log.log("Deleted directory: ", path);
					} catch (FileException e) {
						// directory not empty
					}
				}
			}
		}
		idsToDelete.length = 0;
		assumeSafeAppend(idsToDelete);
	}

	// scan the given directory for differences
	public void scanForDifferences(string path)
	{
		try {
			log.vlog("Uploading differences ...");
			Item item;
			if (itemdb.selectByPath(path, item)) {
				uploadDifferences(item);
			}
			log.vlog("Uploading new items ...");
			uploadNewItems(path);
		} catch (ErrnoException e) {
			throw new SyncException(e.msg, e);
		} catch (FileException e) {
			throw new SyncException(e.msg, e);
		} catch (OneDriveException e) {
			throw new SyncException(e.msg, e);
		}
	}

	private void uploadDifferences(Item item)
	{
		log.vlog(item.id, " ", item.name);

		// skip filtered items
		if (selectiveSync.isNameExcluded(item.name)) {
			log.vlog("Filtered out");
			return;
		}
		string path = itemdb.computePath(item.driveId, item.id);
		if (selectiveSync.isPathExcluded(path)) {
			log.vlog("Filtered out: ", path);
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
			assert(0);
		}
	}

	private void uploadDirDifferences(Item item, string path)
	{
		assert(item.type == ItemType.dir);
		if (exists(path)) {
			if (!isDir(path)) {
				log.vlog("The item was a directory but now is a file");
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

	private void uploadFileDifferences(Item item, string path)
	{
		assert(item.type == ItemType.file);
		if (exists(path)) {
			if (isFile(path)) {
				SysTime localModifiedTime = timeLastModified(path);
				// HACK: reduce time resolution to seconds before comparing
				item.mtime.fracSecs = Duration.zero;
				localModifiedTime.fracSecs = Duration.zero;
				if (localModifiedTime != item.mtime) {
					log.vlog("The file last modified time has changed");
					string id = item.id;
					string eTag = item.eTag;
					if (!testFileHash(path, item)) {
						log.vlog("The file content has changed");
						log.log("Uploading: ", path);
						JSONValue response;
						if (getSize(path) <= thresholdFileSize) {
							response = onedrive.simpleUpload(path, path, eTag);
						} else {
							response = session.upload(path, path, eTag);
						}
						saveItem(response);
						id = response["id"].str;
						/* use the cTag instead of the eTag because Onedrive changes the
						 * metadata of some type of files (ex. images) AFTER they have been
						 * uploaded */
						eTag = response["cTag"].str;
					}
					uploadLastModifiedTime(id, eTag, localModifiedTime.toUTC());
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
		log.log("Creating remote directory: ", path);
		JSONValue item = ["name": baseName(path).idup];
		item["folder"] = parseJSON("{}");
		auto res = onedrive.createByPath(path.dirName, item);
		saveItem(res);
	}

	private void uploadNewFile(string path)
	{
		log.log("Uploading: ", path);
		JSONValue response;
		if (getSize(path) <= thresholdFileSize) {
			response = onedrive.simpleUpload(path, path);
		} else {
			response = session.upload(path, path);
		}
		string id = response["id"].str;
		string cTag = response["cTag"].str;
		SysTime mtime = timeLastModified(path).toUTC();
		/* use the cTag instead of the eTag because Onedrive changes the
		 * metadata of some type of files (ex. images) AFTER they have been
		 * uploaded */
		uploadLastModifiedTime(id, cTag, mtime);
	}

	private void uploadDeleteItem(Item item, const(char)[] path)
	{
		log.log("Deleting remote item: ", path);
		try {
			onedrive.deleteById(item.id, item.eTag);
		} catch (OneDriveException e) {
			if (e.httpStatusCode == 404) log.log(e.msg);
			else throw e;
		}
		itemdb.deleteById(item.driveId, item.id);
	}

	private void uploadLastModifiedTime(const(char)[] id, const(char)[] eTag, SysTime mtime)
	{
		JSONValue mtimeJson = [
			"fileSystemInfo": JSONValue([
				"lastModifiedDateTime": mtime.toISOExtString()
			])
		];
		auto res = onedrive.updateById(id, mtimeJson, eTag);
		saveItem(res);
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
		auto res = onedrive.updateById(fromItem.id, diff, fromItem.eTag);
		saveItem(res);
		string id = res["id"].str;
		string eTag = res["eTag"].str;
		uploadLastModifiedTime(id, eTag, timeLastModified(to).toUTC());
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
