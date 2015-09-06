import core.exception: RangeError;
import std.stdio, std.file, std.json;
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
			if (cached) {
				applyDelete(cachedItem);
			}
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
		foreach (DirEntry entry; dirEntries("test", SpanMode.breadth, false)) {
			uploadDifference(entry.name);
		}
		// TODO: check deleted files
		chdir(currDir);
	}

	private void uploadDifference(const(char)[] path)
	{
		writeln(path);
		assert(exists(path));
		Item item;
		bool needDelete, uploadFile, createDir, changedLastModifiedTime;
		if (itemCache.selectByPath(path, item)) {
			final switch (item.type) {
			case ItemType.file:
				if (isFile(item.path)) {
					SysTime localModifiedTime = timeLastModified(item.path);
					import core.time: Duration;
					item.mtime.fracSecs = Duration.zero; // HACK
					if (localModifiedTime != item.mtime) {
						writeln("Different last modified time");
						changedLastModifiedTime = true;
						if (item.crc32) {
							string localCrc32 = computeCrc32(item.path);
							if (localCrc32 != item.crc32) {
								writeln("Different content");
								uploadFile = true;
							}
						} else {
							writeln("The local item has no hash, assuming it's different");
							uploadFile = true;
						}
					}
				} else {
					writeln("The local item is changed in a directory");
					needDelete = true;
					createDir = true;
				}
				break;
			case ItemType.dir:
				if (isDir(item.path)) {
					// ignore folder mtime
				} else {
					writeln("The local item changed in a file");
					needDelete = true;
					uploadFile = true;
				}
				break;
			}
		} else {
			if (isFile(path)) uploadFile = true;
			else createDir = true;
		}

		string id = item.id;
		string eTag = item.eTag;
		if (needDelete) {
			assert(id);
			writeln("Deleting ...");
			onedrive.deleteById(id, eTag);
		}
		if (uploadFile) {
			writeln("Uploading file ...");
			auto returnedItem = onedrive.simpleUpload(path.dup, path, eTag);
			id = returnedItem["id"].str;
			eTag = returnedItem["eTag"].str;
		}
		if (uploadFile || changedLastModifiedTime) {
			writeln("Updating last modified time ...");
			JSONValue mtime = ["fileSystemInfo": JSONValue(["lastModifiedDateTime": timeLastModified(path).toUTC().toISOExtString()])];
			onedrive.updateById(id, mtime, eTag);
		}
		if (createDir) {
			writeln("Creating folder ...");
			import std.path;
			folderItem["name"] = baseName(path);
			folderItem["fileSystemInfo"].object["lastModifiedDateTime"] = timeLastModified(path).toUTC().toISOExtString();
			onedrive.createByPath(dirName(path), folderItem);
		}
	}
}
