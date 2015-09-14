import core.exception: RangeError;
import std.datetime, std.file, std.json, std.path, std.stdio;
import cache, config, onedrive, util;

private string statusTokenFile = "status_token";

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
	Config cfg;
	OneDriveApi onedrive;
	ItemCache itemCache;
	string[] itemToDelete; // array of items to be deleted
	JSONValue folderItem;

	this(Config cfg, OneDriveApi onedrive)
	{
		assert(onedrive);
		this.cfg = cfg;
		this.onedrive = onedrive;
		itemCache.init();
		folderItem = parseJSON("{
			\"name\": \"\",
			\"folder\": {},
			\"fileSystemInfo\": { \"lastModifiedDateTime\": \"\" }
		}");
	}

	void applyDifferences()
	{
		string statusToken;
		try {
			statusToken = readText(statusTokenFile);
		} catch (FileException e) {
			writeln("Welcome !");
		}
		writeln("Applying differences ...");

		string currDir = getcwd();
		string syncDir = cfg.get("sync_dir");

		JSONValue changes;
		do {
			chdir(syncDir);
			changes = onedrive.viewChangesByPath("test", statusToken);
			foreach (item; changes["value"].array) {
				applyDifference(item);
			}
			statusToken = changes["@changes.token"].str;
			chdir(currDir);
			std.file.write(statusTokenFile, statusToken);
		} while (changes["@changes.hasMoreChanges"].type == JSON_TYPE.TRUE);
		chdir(syncDir);
		deleteFiles();
		chdir(currDir);
	}

	private void applyDifference(JSONValue item)
	{
		string id = item["id"].str;
		string name = item["name"].str;
		string eTag = item["eTag"].str;

		Item cachedItem;
		bool cached = itemCache.selectById(id, cachedItem);

		// skip items already downloaded
		//if (cached && cachedItem.eTag == eTag) return;

		writeln("Item ", id, " ", name);

		ItemType type;
		if (isItemDeleted(item)) {
			writeln("The item is marked for deletion");
			if (cached) applyDelete(cachedItem);
			return;
		} else if (isItemFile(item)) {
			type = ItemType.file;
			writeln("The item is a file");
		} else if (isItemFolder(item)) {
			type = ItemType.dir;
			writeln("The item is a directory");
		} else {
			writeln("The item is neither a file nor a directory, skipping");
			//skippedFolders ~= id;
			return;
		}

		string cTag = item["cTag"].str;
		string mtime = item["fileSystemInfo"].object["lastModifiedDateTime"].str;
		string parentId = item["parentReference"].object["id"].str;

		string crc32;
		if (type == ItemType.file) {
			try {
				crc32 = item["file"].object["hashes"].object["crc32Hash"].str;
			} catch (JSONException e) {
				writeln("The hash is not available");
			} catch (RangeError e) {
				writeln("The crc32 hash is not available");
			}
		}

		Item newItem;
		itemCache.insert(id, name, type, eTag, cTag, mtime, parentId, crc32);
		itemCache.selectById(id, newItem);

		writeln("Path: ", newItem.path);

		try {
			if (!cached) {
				applyNewItem(newItem);
			} else {
				applyChangedItem(cachedItem, newItem);
			}
		} catch (SyncException e) {
			itemCache.deleteById(id);
			throw e;
		}
	}

	private void cacheItem(JSONValue item)
	{
		string id = item["id"].str;
		ItemType type;
		if (isItemDeleted(item)) {
			itemCache.deleteById(id);
		} else if (isItemFile(item)) {
			type = ItemType.file;
		} else if (isItemFolder(item)) {
			type = ItemType.dir;
		} else {
			writeln("The item is neither a file nor a directory, skipping");
			return;
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
				writeln("The hash is not available");
			} catch (RangeError e) {
				writeln("The crc32 hash is not available");
			}
		}
		itemCache.insert(id, name, type, eTag, cTag, mtime, parentId, crc32);
	}

	private void applyDelete(Item item)
	{
		if (exists(item.path)) {
			if (isItemSynced(item)) {
				addFileToDelete(item.path);
			} else {
				writeln("The local item is not synced, renaming ...");
				safeRename(item.path);
			}
		} else {
			writeln("The local item is already deleted");
		}
		itemCache.deleteById(item.id);
	}
	private void applyNewItem(Item item)
	{
		assert(item.id);
		if (exists(item.path)) {
			if (isItemSynced(item)) {
				writeln("The item is already present");
				// ensure the modified time is synced
				setTimes(item.path, item.mtime, item.mtime);
				return;
			} else {
				writeln("The item is not synced, renaming ...");
				safeRename(item.path);
			}
		}
		final switch (item.type) {
		case ItemType.file:
			writeln("Downloading ...");
			try {
				onedrive.downloadById(item.id, item.path);
			} catch (OneDriveException e) {
				throw new SyncException("Sync error", e);
			}
			break;
		case ItemType.dir:
			writeln("Creating local directory...");
			mkdir(item.path);
			break;
		}
		setTimes(item.path, item.mtime, item.mtime);
	}

	private void applyChangedItem(Item oldItem, Item newItem)
	{
		assert(oldItem.id == newItem.id);
		if (exists(oldItem.path)) {
			if (isItemSynced(oldItem)) {
				if (oldItem.eTag != newItem.eTag) {
					assert(oldItem.type == newItem.type);
					if (oldItem.path != newItem.path) {
						writeln("Moved item ", oldItem.path, " to ", newItem.path);
						if (exists(newItem.path)) {
							writeln("The destination is occupied, renaming ...");
							safeRename(newItem.path);
						}
						rename(oldItem.path, newItem.path);
					}
					if (oldItem.type == ItemType.file && oldItem.cTag != newItem.cTag) {
						writeln("Downloading ...");
						onedrive.downloadById(oldItem.id, oldItem.path);
					}
					setTimes(newItem.path, newItem.mtime, newItem.mtime);
					writeln("Updated last modified time");
				} else {
					writeln("The item is not changed");
				}
			} else {
				writeln("The item is not synced, renaming ...");
				safeRename(oldItem.path);
				applyNewItem(newItem);
			}
		} else {
			applyNewItem(newItem);
		}
	}

	// returns true if the given item corresponds to the local one
	private bool isItemSynced(Item item)
	{
		final switch (item.type) {
		case ItemType.file:
			if (isFile(item.path)) {
				SysTime localModifiedTime = timeLastModified(item.path);
				import core.time: Duration;
				item.mtime.fracSecs = Duration.zero; // HACK
				if (localModifiedTime == item.mtime) return true;
				else {
					writeln("The local item has a different modified time ", localModifiedTime, " remote is ", item.mtime);
				}
				if (item.crc32) {
					string localCrc32 = computeCrc32(item.path);
					if (localCrc32 == item.crc32) return true;
					else {
						writeln("The local item has a different hash");
					}
				}
			} else {
				writeln("The local item is a directory but should be a file");
			}
			break;
		case ItemType.dir:
			if (isDir(item.path)) return true;
			else {
				writeln("The local item is a file but should be a directory");
			}
			break;
		}
		return false;
	}

	private void addFileToDelete(string path)
	{
		itemToDelete ~= path;
	}

	private void deleteFiles()
	{
		writeln("Deleting marked files ...");
		foreach_reverse (ref path; itemToDelete) {
			if (isFile(path)) {
				remove(path);
			} else {
				try {
					rmdir(path);
				} catch (FileException e) {
					writeln("Keeping dir \"", path, "\" not empty");
				}
			}
		}
		itemToDelete.length = 0;
		assumeSafeAppend(itemToDelete);
	}

	// scan the directory for unsynced files and upload them
	public void uploadDifferences()
	{
		writeln("Uploading differences ...");
		string currDir = getcwd();
		string syncDir = cfg.get("sync_dir");
		chdir(syncDir);
		foreach (Item item; itemCache.selectAll()) {
			uploadDifference(item);
		}
		foreach (DirEntry entry; dirEntries("test", SpanMode.breadth, false)) {
			uploadDifference(entry.name/*[2 .. $]*/);
		}
		chdir(currDir);
	}

	public void uploadDifferences(string path)
	{
		assert(isDir(path));
		Item item;
		foreach (DirEntry entry; dirEntries(path, SpanMode.breadth, false)) {
			if (itemCache.selectByPath(entry.name, item)) {
				uploadDifference(item);
			} else {
				uploadNewItem(entry.name);
			}
		}
	}

	private void uploadDifference(Item item)
	{
		writeln(item.path);
		if (exists(item.path)) {
			final switch (item.type) {
			case ItemType.file:
				if (isFile(item.path)) {
					updateItem(item);
				} else {
					deleteItem(item);
					createFolderItem(item.path);
				}
				break;
			case ItemType.dir:
				if (isDir(item.path)) {
					updateItem(item);
				} else {
					deleteItem(item);
					writeln("Uploading ...");
					auto res = onedrive.simpleUpload(item.path, item.path);
					cacheItem(res);
				}
				break;
			}
		} else {
			deleteItem(item);
		}
	}

	private void uploadDifference(const(char)[] path)
	{
		Item item;
		if (!itemCache.selectByPath(path, item)) {
			writeln("New item ", path);
			uploadNewItem(path);
		}
	}

	// HACK
	void uploadDifference2(const(char)[] path)
	{
		assert(isFile(path));
		Item item;
		if (itemCache.selectByPath(path, item)) {
			uploadDifference(item);
		} else {
			uploadNewItem(path);
		}
	}

	private void deleteItem(Item item)
	{
		writeln("Deleting ...");
		onedrive.deleteById(item.id, item.eTag);
		itemCache.deleteById(item.id);
	}

	private void updateItem(Item item)
	{
		SysTime localModifiedTime = timeLastModified(item.path);
		import core.time: Duration;
		item.mtime.fracSecs = Duration.zero; // HACK
		if (localModifiedTime != item.mtime) {
			string id = item.id;
			string eTag = item.eTag;
			if (item.type == ItemType.file && !testCrc32(item.path, item.crc32)) {
				assert(isFile(item.path));
				writeln("Uploading ...");
				JSONValue res = onedrive.simpleUpload(item.path, item.path, item.eTag);
				cacheItem(res);
				id = res["id"].str;
				eTag = res["eTag"].str;
			}
			updateItemLastModifiedTime(id, eTag, localModifiedTime.toUTC());
		} else {
			writeln("The item is not changed");
		}
	}

	void createFolderItem(const(char)[] path)
	{
		writeln("Creating folder ...");
		folderItem["name"] = baseName(path).idup;
		folderItem["fileSystemInfo"].object["lastModifiedDateTime"] = timeLastModified(path).toUTC().toISOExtString();
		auto res = onedrive.createByPath(dirName(path), folderItem);
		cacheItem(res);
	}

	private void updateItemLastModifiedTime(const(char)[] id, const(char)[] eTag, SysTime mtime)
	{
		writeln("Updating last modified time ...");
		JSONValue mtimeJson = [
			"fileSystemInfo": JSONValue([
				"lastModifiedDateTime": mtime.toISOExtString()
			])
		];
		auto res = onedrive.updateById(id, mtimeJson, eTag);
		cacheItem(res);
	}

	private void uploadNewItem(const(char)[] path)
	{
		assert(exists(path));
		if (isFile(path)) {
			writeln("Uploading file ...");
			JSONValue res = onedrive.simpleUpload(path.dup, path);
			cacheItem(res);
			string id = res["id"].str;
			string eTag = res["eTag"].str;
			updateItemLastModifiedTime(id, eTag, timeLastModified(path).toUTC());
		} else {
			createFolderItem(path);
		}
	}

	void moveItem(const(char)[] from, string to)
	{
		writeln("Moving ", from, " to ", to, " ...");
		Item item;
		if (!itemCache.selectByPath(from, item)) {
			throw new SyncException("Can't move a non synced item");
		}
		JSONValue diff = ["name": baseName(to)];
		diff["parentReference"] = JSONValue([
			"path": "/drive/root:/" ~ dirName(to)
		]);
		writeln(diff.toPrettyString());
		auto res = onedrive.updateById(item.id, diff, item.eTag);
		cacheItem(res);
	}

	void deleteByPath(const(char)[] path)
	{
		writeln("Deleting: ", path);
		Item item;
		if (!itemCache.selectByPath(path, item)) {
			throw new SyncException("Can't delete a non synced item");
		}
		deleteItem(item);
	}
}
