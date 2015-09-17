import core.exception: RangeError;
import std.algorithm, std.datetime, std.file, std.json, std.path, std.stdio;
import config, itemdb, onedrive, util;

private bool isItemFolder(const ref JSONValue item)
{
	scope (failure) return false;
	JSONValue folder = item["folder"];
	return true;
}

private bool isItemFile(const ref JSONValue item)
{
	scope (failure) return false;
	JSONValue folder = item["file"];
	return true;
}

private bool isItemDeleted(const ref JSONValue item)
{
	scope (failure) return false;
	return !item["deleted"].isNull();
}

private bool testCrc32(string path, const(char)[] crc32)
{
	if (crc32) {
		string localCrc32 = computeCrc32(path);
		if (crc32 == localCrc32) return true;
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
	private bool verbose;
	private string statusToken;
	private string[] skippedItems;
	private string[] itemsToDelete;

	void delegate(string) onStatusToken;

	this(Config cfg, OneDriveApi onedrive, ItemDatabase itemdb, bool verbose)
	{
		assert(onedrive && itemdb);
		this.cfg = cfg;
		this.onedrive = onedrive;
		this.itemdb = itemdb;
		this.verbose = verbose;
	}

	void setStatusToken(string statusToken)
	{
		this.statusToken = statusToken;
	}

	void applyDifferences()
	{
		if (verbose) writeln("Applying differences ...");
		JSONValue changes;
		do {
			changes = onedrive.viewChangesByPath("/", statusToken);
			foreach (item; changes["value"].array) {
				applyDifference(item);
			}
			statusToken = changes["@changes.token"].str;
			onStatusToken(statusToken);
		} while (changes["@changes.hasMoreChanges"].type == JSON_TYPE.TRUE);
		// delete items in itemsToDelete
		if (itemsToDelete.length > 0) deleteItems();
		// empty the skipped items
		skippedItems.length = 0;
		assumeSafeAppend(skippedItems);
	}

	private void applyDifference(JSONValue item)
	{
		string id = item["id"].str;
		string name = item["name"].str;
		string eTag = item["eTag"].str;

		if (verbose) writeln(id, " ", name);

		Item cachedItem;
		bool cached = itemdb.selectById(id, cachedItem);

		if (cached && !isItemSynced(cachedItem)) {
			if (verbose) writeln("The local item is out of sync, renaming: ", cachedItem.path);
			if (exists(cachedItem.path)) safeRename(cachedItem.path);
			cached = false;
		}

		ItemType type;
		if (isItemDeleted(item)) {
			if (verbose) writeln("The item is marked for deletion");
			if (cached) applyDeleteItem(cachedItem);
			return;
		} else if (isItemFile(item)) {
			type = ItemType.file;
		} else if (isItemFolder(item)) {
			type = ItemType.dir;
		} else {
			if (verbose) writeln("The item is neither a file nor a directory, skipping");
			skippedItems ~= id;
			return;
		}

		string parentId = item["parentReference"].object["id"].str;
		if (name == "root" && parentId[$ - 1] == '0' && parentId[$ - 2] == '!') {
			// HACK: recognize the root directory
			parentId = null;
		}
		if (skippedItems.find(parentId).length != 0) {
			if (verbose) writeln("The item is a children of a skipped item");
			skippedItems ~= id;
			return;
		}

		string cTag = item["cTag"].str;
		string mtime = item["fileSystemInfo"].object["lastModifiedDateTime"].str;

		string crc32;
		if (type == ItemType.file) {
			try {
				crc32 = item["file"].object["hashes"].object["crc32Hash"].str;
			} catch (JSONException e) {
				if (verbose) writeln("The hash is not available");
			} catch (RangeError e) {
				if (verbose) writeln("The crc32 hash is not available");
			}
		}

		if (cached) {
			itemdb.update(id, name, type, eTag, cTag, mtime, parentId, crc32);
		} else {
			itemdb.insert(id, name, type, eTag, cTag, mtime, parentId, crc32);
		}
		Item newItem;
		itemdb.selectById(id, newItem);

		// TODO add item in the db only if correctly downloaded
		try {
			if (!cached) {
				applyNewItem(newItem);
			} else {
				applyChangedItem(cachedItem, newItem);
			}
		} catch (SyncException e) {
			itemdb.deleteById(id);
			throw e;
		}
	}

	private void applyDeleteItem(Item item)
	{
		itemsToDelete ~= item.path;
		itemdb.deleteById(item.id);
	}

	private void applyNewItem(Item item)
	{
		assert(item.id);
		if (exists(item.path)) {
			if (isItemSynced(item)) {
				if (verbose) writeln("The item is already present");
				// ensure the modified time is correct
				setTimes(item.path, item.mtime, item.mtime);
				return;
			} else {
				if (verbose) writeln("The local item is out of sync, renaming ...");
				safeRename(item.path);
			}
		}
		final switch (item.type) {
		case ItemType.file:
			writeln("Downloading: ", item.path);
			try {
				onedrive.downloadById(item.id, item.path);
			} catch (OneDriveException e) {
				throw new SyncException("Sync error", e);
			}
			break;
		case ItemType.dir:
			writeln("Creating directory: ", item.path);
			mkdir(item.path);
			break;
		}
		setTimes(item.path, item.mtime, item.mtime);
	}

	private void applyChangedItem(Item oldItem, Item newItem)
	{
		assert(oldItem.id == newItem.id);
		assert(oldItem.type == newItem.type);
		assert(exists(oldItem.path));

		if (oldItem.eTag != newItem.eTag) {
			if (oldItem.path != newItem.path) {
				writeln("Moving: ", oldItem.path, " -> ", newItem.path);
				if (exists(newItem.path)) {
					if (verbose) writeln("The destination is occupied, renaming ...");
					safeRename(newItem.path);
				}
				rename(oldItem.path, newItem.path);
			}
			if (newItem.type == ItemType.file && oldItem.cTag != newItem.cTag) {
				writeln("Downloading: ", newItem.path);
				onedrive.downloadById(newItem.id, newItem.path);
			}
			setTimes(newItem.path, newItem.mtime, newItem.mtime);
		} else {
			if (verbose) writeln("The item is not changed");
		}
	}

	// returns true if the given item corresponds to the local one
	private bool isItemSynced(Item item)
	{
		if (!exists(item.path)) return false;
		final switch (item.type) {
		case ItemType.file:
			if (isFile(item.path)) {
				SysTime localModifiedTime = timeLastModified(item.path);
				import core.time: Duration;
				item.mtime.fracSecs = Duration.zero; // HACK
				if (localModifiedTime == item.mtime) {
					return true;
				} else {
					if (verbose) writeln("The local item has a different modified time ", localModifiedTime, " remote is ", item.mtime);
				}
				if (item.crc32) {
					string localCrc32 = computeCrc32(item.path);
					if (localCrc32 == item.crc32) {
						return true;
					} else {
						if (verbose) writeln("The local item has a different hash");
					}
				}
			} else {
				if (verbose) writeln("The local item is a directory but should be a file");
			}
			break;
		case ItemType.dir:
			if (isDir(item.path)) {
				return true;
			} else {
				if (verbose) writeln("The local item is a file but should be a directory");
			}
			break;
		}
		return false;
	}

	private void deleteItems()
	{
		if (verbose) writeln("Deleting files ...");
		foreach_reverse (path; itemsToDelete) {
			if (exists(path)) {
				if (isFile(path)) {
					remove(path);
					writeln("Deleted file: ", path);
				}
			} else {
				try {
					rmdir(path);
					writeln("Deleted dir: ", path);
				} catch (FileException e) {
					writeln("Keeping dir: ", path);
				}
			}
		}
		itemsToDelete.length = 0;
		assumeSafeAppend(itemsToDelete);
	}

	// scan the root directory for unsynced files and upload them
	public void uploadDifferences()
	{
		if (verbose) writeln("Uploading differences ...");
		// check for changed files or deleted items
		foreach (Item item; itemdb.selectAll()) {
			uploadDifference(item);
		}
		if (verbose) writeln("Uploading new items ...");
		// check for new files or directories
		foreach (DirEntry entry; dirEntries(".", SpanMode.breadth, false)) {
			string path = entry.name[2 .. $]; // HACK: skip "./"
			Item item;
			if (!itemdb.selectByPath(path, item)) {
				if (entry.isDir) {
					uploadCreateDir(path);
				} else {
					uploadNewFile(path);
				 }
			}
		}
	}

	/* scan the specified directory for unsynced files and uplaod them
	   NOTE: this function does not check for deleted files. */
	public void uploadDifferences(string dirname)
	{
		foreach (DirEntry entry; dirEntries(dirname, SpanMode.breadth, false)) {
			uploadDifference(entry.name);
		}
	}

	private void uploadDifference(Item item)
	{
		if (verbose) writeln(item.id, " ", item.name);
		if (exists(item.path)) {
			final switch (item.type) {
			case ItemType.file:
				if (isFile(item.path)) {
					SysTime localModifiedTime = timeLastModified(item.path);
					import core.time: Duration;
					item.mtime.fracSecs = Duration.zero; // HACK
					if (localModifiedTime != item.mtime) {
						if (verbose) writeln("The item last modified time has changed");
						string id = item.id;
						string eTag = item.eTag;
						if (!testCrc32(item.path, item.crc32)) {
							if (verbose) writeln("The item content has changed");
							writeln("Uploading: ", item.path);
							auto res = onedrive.simpleUpload(item.path, item.path, item.eTag);
							saveItem(res);
							id = res["id"].str;
							eTag = res["eTag"].str;
						}
						uploadLastModifiedTime(id, eTag, localModifiedTime.toUTC());
					} else {
						if (verbose) writeln("The item has not changed");
					}
				} else {
					if (verbose) writeln("The item was a file but now is a directory");
					uploadDeleteItem(item);
					uploadCreateDir(item.path);
				}
				break;
			case ItemType.dir:
				if (!isDir(item.path)) {
					if (verbose) writeln("The item was a directory but now is a file");
					uploadDeleteItem(item);
					uploadNewFile(item.path);
				} else {
					if (verbose) writeln("The item has not changed");
				}
				break;
			}
		} else {
			if (verbose) writeln("The item has been deleted");
			uploadDeleteItem(item);
		}
	}

	void uploadDifference(string path)
	{
		try {
			Item item;
			if (itemdb.selectByPath(path, item)) {
				uploadDifference(item);
			} else {
				if (isDir(path)) {
					uploadCreateDir(path);
				} else {
					uploadNewFile(path);
				 }
			}
		} catch (FileException e) {
			throw new SyncException(e.msg, e);
		}
	}

	void uploadCreateDir(const(char)[] path)
	{
		writeln("Creating remote directory: ", path);
		JSONValue item = ["name": baseName(path).idup];
		item["folder"] = parseJSON("{}");
		auto res = onedrive.createByPath(dirName(path), item);
		saveItem(res);
	}

	private void uploadNewFile(string path)
	{
		writeln("Uploading: ", path);
		JSONValue res;
		try {
			res = onedrive.simpleUpload(path, path);
		} catch (OneDriveException e) {
			writeln(e.msg);
			return;
		}
		saveItem(res);
		string id = res["id"].str;
		string eTag = res["eTag"].str;
		SysTime mtime;
		try {
			mtime = timeLastModified(path).toUTC();
		} catch (FileException e) {
			writeln(e.msg);
			return;
		}
		uploadLastModifiedTime(id, eTag, mtime);
	}

	private void uploadDeleteItem(Item item)
	{
		writeln("Deleting remote item: ", item.path);
		onedrive.deleteById(item.id, item.eTag);
		itemdb.deleteById(item.id);
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

	private void saveItem(JSONValue item)
	{
		string id = item["id"].str;
		ItemType type;
		if (isItemFile(item)) {
			type = ItemType.file;
		} else if (isItemFolder(item)) {
			type = ItemType.dir;
		} else {
			assert(0);
		}
		string name = item["name"].str;
		string eTag = item["eTag"].str;
		string cTag = item["cTag"].str;
		string mtime = item["fileSystemInfo"].object["lastModifiedDateTime"].str;
		string parentId = item["parentReference"].object["id"].str;
		string crc32;
		if (type == ItemType.file) {
			try {
				crc32 = item["file"].object["hashes"].object["crc32Hash"].str;
			} catch (JSONException e) {
				// swallow exception
			} catch (RangeError e) {
				// swallow exception
			}
		}
		itemdb.upsert(id, name, type, eTag, cTag, mtime, parentId, crc32);
	}

	void uploadMoveItem(const(char)[] from, string to)
	{
		writeln("Moving remote item: ", from, " -> ", to);
		Item item;
		if (!itemdb.selectByPath(from, item) || !isItemSynced(item)) {
			writeln("Can't move an unsynced item");
			return;
		}
		if (itemdb.selectByPath(to, item)) {
			uploadDeleteItem(item);
		}
		JSONValue diff = ["name": baseName(to)];
		diff["parentReference"] = JSONValue([
			"path": "/drive/root:/" ~ dirName(to)
		]);
		auto res = onedrive.updateById(item.id, diff, item.eTag);
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
		uploadDeleteItem(item);
	}
}
