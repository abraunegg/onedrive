// What is this module called?
module itemdb;

// What does this module require to function?
import std.datetime;
import std.exception;
import std.path;
import std.string;
import std.stdio;
import std.algorithm.searching;
import core.stdc.stdlib;
import std.json;
import std.conv;

// What other modules that we have created do we need to import?
import sqlite;
import util;
import log;

enum ItemType {
	none,
	file,
	dir,
	remote,
	unknown
}

struct Item {
	string   driveId;
	string   id;
	string   name;
	string   remoteName;
	ItemType type;
	string   eTag;
	string   cTag;
	SysTime  mtime;
	string   parentId;
	string   quickXorHash;
	string   sha256Hash;
	string   remoteDriveId;
	string   remoteParentId;
	string   remoteId;
	ItemType remoteType;
	string   syncStatus;
	string   size;
}

// Construct an Item struct from a JSON driveItem
Item makeDatabaseItem(JSONValue driveItem) {
	
	Item item = {
		id: driveItem["id"].str,
		name: "name" in driveItem ? driveItem["name"].str : null, // name may be missing for deleted files in OneDrive Business
		eTag: "eTag" in driveItem ? driveItem["eTag"].str : null, // eTag is not returned for the root in OneDrive Business
		cTag: "cTag" in driveItem ? driveItem["cTag"].str : null, // cTag is missing in old files (and all folders in OneDrive Business)
		remoteName: "actualOnlineName" in driveItem ? driveItem["actualOnlineName"].str : null, // actualOnlineName is only used with OneDrive Business Shared Folders
	};

	// OneDrive API Change: https://github.com/OneDrive/onedrive-api-docs/issues/834
	// OneDrive no longer returns lastModifiedDateTime if the item is deleted by OneDrive
	if(isItemDeleted(driveItem)) {
		// Set mtime to SysTime(0)
		item.mtime = SysTime(0);
	} else {
		// Item is not in a deleted state
		// Resolve 'Key not found: fileSystemInfo' when then item is a remote item
		// https://github.com/abraunegg/onedrive/issues/11
		if (isItemRemote(driveItem)) {
			// remoteItem is a OneDrive object that exists on a 'different' OneDrive drive id, when compared to account default
			// Normally, the 'remoteItem' field will contain 'fileSystemInfo' however, if the user uses the 'Add Shortcut ..' option in OneDrive WebUI
			// to create a 'link', this object, whilst remote, does not have 'fileSystemInfo' in the expected place, thus leading to a application crash
			// See: https://github.com/abraunegg/onedrive/issues/1533
			if ("fileSystemInfo" in driveItem["remoteItem"]) {
				// 'fileSystemInfo' is in 'remoteItem' which will be the majority of cases
				item.mtime = SysTime.fromISOExtString(driveItem["remoteItem"]["fileSystemInfo"]["lastModifiedDateTime"].str);
			} else {
				// is a remote item, but 'fileSystemInfo' is missing from 'remoteItem'
				if ("fileSystemInfo" in driveItem) {
					item.mtime = SysTime.fromISOExtString(driveItem["fileSystemInfo"]["lastModifiedDateTime"].str);
				}
			}
		} else {
			// Does fileSystemInfo exist at all ?
			if ("fileSystemInfo" in driveItem) {
				item.mtime = SysTime.fromISOExtString(driveItem["fileSystemInfo"]["lastModifiedDateTime"].str);
			}
		}
	}
		
	// Set this item object type
	bool typeSet = false;
	if (isItemFile(driveItem)) {
		// 'file' object exists in the JSON
		addLogEntry("Flagging object as a file", ["debug"]);
		typeSet = true;
		item.type = ItemType.file;
	}
	
	if (isItemFolder(driveItem)) {
		// 'folder' object exists in the JSON
		addLogEntry("Flagging object as a directory", ["debug"]);
		typeSet = true;
		item.type = ItemType.dir;
	}
	
	if (isItemRemote(driveItem)) {
		// 'remote' object exists in the JSON
		addLogEntry("Flagging object as a remote", ["debug"]);
		typeSet = true;
		item.type = ItemType.remote;
	}

	// root and remote items do not have parentReference
	if (!isItemRoot(driveItem) && ("parentReference" in driveItem) != null) {
		item.driveId = driveItem["parentReference"]["driveId"].str;
		if (hasParentReferenceId(driveItem)) {
			item.parentId = driveItem["parentReference"]["id"].str;
		}
	}
	
	// extract the file hash and file size
	if (isItemFile(driveItem) && ("hashes" in driveItem["file"])) {
		// Get file size
		if (hasFileSize(driveItem)) {
			item.size = to!string(driveItem["size"].integer);	
			// Get quickXorHash as default
			if ("quickXorHash" in driveItem["file"]["hashes"]) {
				item.quickXorHash = driveItem["file"]["hashes"]["quickXorHash"].str;
			} else {
				addLogEntry("quickXorHash is missing from " ~ driveItem["id"].str, ["debug"]);
			}
			
			// If quickXorHash is empty ..
			if (item.quickXorHash.empty) {
				// Is there a sha256Hash?
				if ("sha256Hash" in driveItem["file"]["hashes"]) {
					item.sha256Hash = driveItem["file"]["hashes"]["sha256Hash"].str;
				} else {
					addLogEntry("sha256Hash is missing from " ~ driveItem["id"].str, ["debug"]);
				}
			}
		} else {
			// So that we have at least a zero value here as the API provided no 'size' data for this file item
			item.size = "0";
		}
	}
	
	// Is the object a remote drive item - living on another driveId ?
	if (isItemRemote(driveItem)) {
		// Check and assign remoteDriveId
		if ("parentReference" in driveItem["remoteItem"] && "driveId" in driveItem["remoteItem"]["parentReference"]) {
			item.remoteDriveId = driveItem["remoteItem"]["parentReference"]["driveId"].str;
		}
		
		// Check and assign remoteParentId
		if ("parentReference" in driveItem["remoteItem"] && "id" in driveItem["remoteItem"]["parentReference"]) {
			item.remoteParentId = driveItem["remoteItem"]["parentReference"]["id"].str;
		}
		
		// Check and assign remoteId
		if ("id" in driveItem["remoteItem"]) {
			item.remoteId = driveItem["remoteItem"]["id"].str;
		}
		
		// Check and assign remoteType
		if ("file" in driveItem["remoteItem"].object) {
			item.remoteType = ItemType.file;
		} else {
			item.remoteType = ItemType.dir;
		}
	}
	
	// We have 3 different operational modes where 'item.syncStatus' is used to flag if an item is synced or not:
	// - National Cloud Deployments do not support /delta as a query
	// - When using --single-directory
	// - When using --download-only --cleanup-local-files
	//
	// Thus we need to track in the database that this item is in sync
	// As we are making an item, set the syncStatus to Y
	// ONLY when either of the three modes above are being used, all the existing DB entries will get set to N
	// so when processing /children, it can be identified what the 'deleted' difference is
	item.syncStatus = "Y";

	// Return the created item
	return item;
}

final class ItemDatabase {
	// increment this for every change in the db schema
	immutable int itemDatabaseVersion = 13;

	Database db;
	string insertItemStmt;
	string updateItemStmt;
	string selectItemByIdStmt;
	string selectItemByRemoteIdStmt;
	string selectItemByParentIdStmt;
	string deleteItemByIdStmt;
	bool databaseInitialised = false;

	this(const(char)[] filename) {
		db = Database(filename);
		int dbVersion;
		try {
			dbVersion = db.getVersion();
		} catch (SqliteException e) {
			// An error was generated - what was the error?
			if (e.msg == "database is locked") {
				addLogEntry();
				addLogEntry("ERROR: The 'onedrive' application is already running - please check system process list for active application instances");
				addLogEntry(" - Use 'sudo ps aufxw | grep onedrive' to potentially determine acive running process");
				addLogEntry();
			} else {
				// A different error .. detail the message, detail the actual SQLite Error Code to assist with troubleshooting
				addLogEntry();
				addLogEntry("ERROR: An internal database error occurred: " ~ e.msg ~ " (SQLite Error Code: " ~ to!string(e.errorCode) ~ ")");
				addLogEntry();
				
				// Give the user some additional information and pointers on this error
				// The below list is based on user issue / discussion reports since 2018
				switch (e.errorCode) {
					case 7: // SQLITE_NOMEM
						addLogEntry("The operation could not be completed due to insufficient memory. Please close unnecessary applications to free up memory and try again.");
						break;
					case 10: // SQLITE_IOERR
						addLogEntry("A disk I/O error occurred. This could be due to issues with the storage medium (e.g., disk full, hardware failure, filesystem corruption). Please check your disk's health using a disk utility tool, ensure there is enough free space, and check the filesystem for errors.");
						break;
					case 11: // SQLITE_CORRUPT
						addLogEntry("The database file appears to be corrupt. This could be due to incomplete or failed writes, hardware issues, or unexpected interruptions during database operations. Please perform a --resync operation.");
						break;
					case 14: // SQLITE_CANTOPEN
						addLogEntry("The database file could not be opened. Please check that the database file exists, has the correct permissions, and is not being blocked by another process or security software.");
						break;
					case 26: // SQLITE_NOTADB
						addLogEntry("The file attempted to be opened does not appear to be a valid SQLite database, or it may have been corrupted to a point where it's no longer recognizable. Please check your application configuration directory and/or perform a --resync operation.");
						break;
					default:
						addLogEntry("An unexpected error occurred. Please consult the application documentation or support to resolve this issue.");
						break;
				}
				// Blank line before exit
				addLogEntry();
			}
			return;
		}
		
		if (dbVersion == 0) {
			createTable();
		} else if (db.getVersion() != itemDatabaseVersion) {
			addLogEntry("The item database is incompatible, re-creating database table structures");
			db.exec("DROP TABLE item");
			createTable();
		}
		
		// What is the threadsafe value
		auto threadsafeValue = db.getThreadsafeValue();
		addLogEntry("Threadsafe database value: " ~ to!string(threadsafeValue), ["debug"]);
		
		// Set the enforcement of foreign key constraints.
		// https://www.sqlite.org/pragma.html#pragma_foreign_keys
		// PRAGMA foreign_keys = boolean;
		db.exec("PRAGMA foreign_keys = TRUE");
		// Set the recursive trigger capability
		// https://www.sqlite.org/pragma.html#pragma_recursive_triggers
		// PRAGMA recursive_triggers = boolean;
		db.exec("PRAGMA recursive_triggers = TRUE");
		// Set the journal mode for databases associated with the current connection
		// https://www.sqlite.org/pragma.html#pragma_journal_mode
		db.exec("PRAGMA journal_mode = WAL");
		// Automatic indexing is enabled by default as of version 3.7.17
		// https://www.sqlite.org/pragma.html#pragma_automatic_index 
		// PRAGMA automatic_index = boolean;
		db.exec("PRAGMA automatic_index = FALSE");
		// Tell SQLite to store temporary tables in memory. This will speed up many read operations that rely on temporary tables, indices, and views.
		// https://www.sqlite.org/pragma.html#pragma_temp_store
		db.exec("PRAGMA temp_store = MEMORY");
		// Tell SQlite to cleanup database table size
		// https://www.sqlite.org/pragma.html#pragma_auto_vacuum
		// PRAGMA schema.auto_vacuum = 0 | NONE | 1 | FULL | 2 | INCREMENTAL;
		db.exec("PRAGMA auto_vacuum = FULL");
		// This pragma sets or queries the database connection locking-mode. The locking-mode is either NORMAL or EXCLUSIVE.
		// https://www.sqlite.org/pragma.html#pragma_locking_mode
		// PRAGMA schema.locking_mode = NORMAL | EXCLUSIVE
		db.exec("PRAGMA locking_mode = EXCLUSIVE");
		
		insertItemStmt = "
			INSERT OR REPLACE INTO item (driveId, id, name, remoteName, type, eTag, cTag, mtime, parentId, quickXorHash, sha256Hash, remoteDriveId, remoteParentId, remoteId, remoteType, syncStatus, size)
			VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17)
		";
		updateItemStmt = "
			UPDATE item
			SET name = ?3, remoteName = ?4, type = ?5, eTag = ?6, cTag = ?7, mtime = ?8, parentId = ?9, quickXorHash = ?10, sha256Hash = ?11, remoteDriveId = ?12, remoteParentId = ?13, remoteId = ?14, remoteType = ?15, syncStatus = ?16, size = ?17
			WHERE driveId = ?1 AND id = ?2
		";
		selectItemByIdStmt = "
			SELECT *
			FROM item
			WHERE driveId = ?1 AND id = ?2
		";
		selectItemByRemoteIdStmt = "
			SELECT *
			FROM item
			WHERE remoteDriveId = ?1 AND remoteId = ?2
		";
		selectItemByParentIdStmt = "SELECT * FROM item WHERE driveId = ? AND parentId = ?";
		deleteItemByIdStmt = "DELETE FROM item WHERE driveId = ? AND id = ?";
		
		// flag that the database is accessible and we have control
		databaseInitialised = true;
	}

	bool isDatabaseInitialised() {
		return databaseInitialised;
	}

	void createTable() {
		db.exec("CREATE TABLE item (
				driveId          TEXT NOT NULL,
				id               TEXT NOT NULL,
				name             TEXT NOT NULL,
				remoteName       TEXT,
				type             TEXT NOT NULL,
				eTag             TEXT,
				cTag             TEXT,
				mtime            TEXT NOT NULL,
				parentId         TEXT,
				quickXorHash     TEXT,
				sha256Hash       TEXT,
				remoteDriveId    TEXT,
				remoteParentId   TEXT,
				remoteId         TEXT,
				remoteType       TEXT,
				deltaLink        TEXT,
				syncStatus       TEXT,
				size             TEXT,
				PRIMARY KEY (driveId, id),
				FOREIGN KEY (driveId, parentId)
				REFERENCES item (driveId, id)
				ON DELETE CASCADE
				ON UPDATE RESTRICT
			)");
		db.exec("CREATE INDEX name_idx ON item (name)");
		db.exec("CREATE INDEX remote_idx ON item (remoteDriveId, remoteId)");
		db.exec("CREATE INDEX item_children_idx ON item (driveId, parentId)");
		db.exec("CREATE INDEX selectByPath_idx ON item (name, driveId, parentId)");
		db.setVersion(itemDatabaseVersion);
	}
	
	void insert(const ref Item item) {
		auto p = db.prepare(insertItemStmt);
		bindItem(item, p);
		p.exec();
	}

	void update(const ref Item item) {
		auto p = db.prepare(updateItemStmt);
		bindItem(item, p);
		p.exec();
	}

	void dump_open_statements() {
		db.dump_open_statements();
	}

	int db_checkpoint() {
		return db.db_checkpoint();
	}

	void upsert(const ref Item item) {
		auto s = db.prepare("SELECT COUNT(*) FROM item WHERE driveId = ? AND id = ?");
		s.bind(1, item.driveId);
		s.bind(2, item.id);
		auto r = s.exec();
		Statement stmt;
		if (r.front[0] == "0") stmt = db.prepare(insertItemStmt);
		else stmt = db.prepare(updateItemStmt);
		bindItem(item, stmt);
		stmt.exec();
	}

	Item[] selectChildren(const(char)[] driveId, const(char)[] id) {
		auto p = db.prepare(selectItemByParentIdStmt);
		p.bind(1, driveId);
		p.bind(2, id);
		auto res = p.exec();
		Item[] items;
		while (!res.empty) {
			items ~= buildItem(res);
			res.step();
		}
		return items;
	}

	bool selectById(const(char)[] driveId, const(char)[] id, out Item item) {
		auto p = db.prepare(selectItemByIdStmt);
		p.bind(1, driveId);
		p.bind(2, id);
		auto r = p.exec();
		if (!r.empty) {
			item = buildItem(r);
			return true;
		}
		return false;
	}

	bool selectByRemoteId(const(char)[] remoteDriveId, const(char)[] remoteId, out Item item) {
		auto p = db.prepare(selectItemByRemoteIdStmt);
		p.bind(1, remoteDriveId);
		p.bind(2, remoteId);
		auto r = p.exec();
		if (!r.empty) {
			item = buildItem(r);
			return true;
		}
		return false;
	}
	
	// returns true if an item id is in the database
	bool idInLocalDatabase(const(string) driveId, const(string)id) {
		auto p = db.prepare(selectItemByIdStmt);
		p.bind(1, driveId);
		p.bind(2, id);
		auto r = p.exec();
		if (!r.empty) {
			return true;
		}
		return false;
	}
	
	// returns the item with the given path
	// the path is relative to the sync directory ex: "./Music/Turbo Killer.mp3"
	bool selectByPath(const(char)[] path, string rootDriveId, out Item item) {
		Item currItem = { driveId: rootDriveId };
		
		// Issue https://github.com/abraunegg/onedrive/issues/578
		path = "root/" ~ (startsWith(path, "./") || path == "." ? path.chompPrefix(".") : path);
		
		auto s = db.prepare("SELECT * FROM item WHERE name = ?1 AND driveId IS ?2 AND parentId IS ?3");
		foreach (name; pathSplitter(path)) {
			s.bind(1, name);
			s.bind(2, currItem.driveId);
			s.bind(3, currItem.id);
			auto r = s.exec();
			if (r.empty) return false;
			currItem = buildItem(r);
			
			// If the item is of type remote substitute it with the child
			if (currItem.type == ItemType.remote) {
				addLogEntry("Record is a Remote Object: " ~  to!string(currItem), ["debug"]);
				Item child;
				if (selectById(currItem.remoteDriveId, currItem.remoteId, child)) {
					assert(child.type != ItemType.remote, "The type of the child cannot be remote");
					currItem = child;
					addLogEntry("Selecting Record that is NOT Remote Object: " ~  to!string(currItem), ["debug"]);
				}
			}
		}
		item = currItem;
		return true;
	}

	// same as selectByPath() but it does not traverse remote folders, returns the remote element if that is what is required
	bool selectByPathIncludingRemoteItems(const(char)[] path, string rootDriveId, out Item item) {
		Item currItem = { driveId: rootDriveId };
		
		// Issue https://github.com/abraunegg/onedrive/issues/578
		path = "root/" ~ (startsWith(path, "./") || path == "." ? path.chompPrefix(".") : path);
		
		auto s = db.prepare("SELECT * FROM item WHERE name IS ?1 AND driveId IS ?2 AND parentId IS ?3");
		foreach (name; pathSplitter(path)) {
			s.bind(1, name);
			s.bind(2, currItem.driveId);
			s.bind(3, currItem.id);
			auto r = s.exec();
			if (r.empty) return false;
			currItem = buildItem(r);
		}
		
		if (currItem.type == ItemType.remote) {
			addLogEntry("Record selected is a Remote Object: " ~  to!string(currItem), ["debug"]);
		}
		
		item = currItem;
		return true;
	}

	void deleteById(const(char)[] driveId, const(char)[] id) {
		auto p = db.prepare(deleteItemByIdStmt);
		p.bind(1, driveId);
		p.bind(2, id);
		p.exec();
	}

	private void bindItem(const ref Item item, ref Statement stmt) {
		with (stmt) with (item) {
			bind(1, driveId);
			bind(2, id);
			bind(3, name);
			bind(4, remoteName);
			// type handling
			string typeStr = null;
			final switch (type) with (ItemType) {
				case file:    typeStr = "file";    break;
				case dir:     typeStr = "dir";     break;
				case remote:  typeStr = "remote";  break;
				case unknown: typeStr = "unknown"; break;
				case none:    typeStr = null; break;
			}
			bind(5, typeStr);
			bind(6, eTag);
			bind(7, cTag);
			bind(8, mtime.toISOExtString());
			bind(9, parentId);
			bind(10, quickXorHash);
			bind(11, sha256Hash);
			bind(12, remoteDriveId);
			bind(13, remoteParentId);
			bind(14, remoteId);
			// remoteType handling
			string remoteTypeStr = null;
			final switch (remoteType) with (ItemType) {
				case file:    remoteTypeStr = "file";    break;
				case dir:     remoteTypeStr = "dir";     break;
				case remote:  remoteTypeStr = "remote";  break;
				case unknown: remoteTypeStr = "unknown"; break;
				case none:    remoteTypeStr = null; break;
			}
			bind(15, remoteTypeStr);
			bind(16, syncStatus);
			bind(17, size);
		}
	}

	private Item buildItem(Statement.Result result) {
		assert(!result.empty, "The result must not be empty");
		assert(result.front.length == 18, "The result must have 18 columns");
		Item item = {
		
			// column 0: driveId
			// column 1: id
			// column 2: name
			// column 3: remoteName - only used when there is a difference in the local name & remote shared folder name
			// column 4: type
			// column 5: eTag
			// column 6: cTag
			// column 7: mtime
			// column 8: parentId
			// column 9: quickXorHash
			// column 10: sha256Hash
			// column 11: remoteDriveId
			// column 12: remoteParentId
			// column 13: remoteId
			// column 14: remoteType
			// column 15: deltaLink
			// column 16: syncStatus
			// column 17: size
				
			driveId: result.front[0].dup,
			id: result.front[1].dup,
			name: result.front[2].dup,
			remoteName: result.front[3].dup,
			// Column 4 is type - not set here
			eTag: result.front[5].dup,
			cTag: result.front[6].dup,
			mtime: SysTime.fromISOExtString(result.front[7]),
			parentId: result.front[8].dup,
			quickXorHash: result.front[9].dup,
			sha256Hash: result.front[10].dup,
			remoteDriveId: result.front[11].dup,
			remoteParentId: result.front[12].dup,
			remoteId: result.front[13].dup,
			// Column 14 is remoteType - not set here
			// Column 15 is deltaLink - not set here
			syncStatus: result.front[16].dup,
			size: result.front[17].dup
		};
		// Configure item.type
		switch (result.front[4]) {
			case "file":    item.type = ItemType.file;    break;
			case "dir":     item.type = ItemType.dir;     break;
			case "remote":  item.type = ItemType.remote;  break;
			default: assert(0, "Invalid item type");
		}
		
		// Configure item.remoteType
		switch (result.front[14]) {
			// We only care about 'dir' and 'file' for 'remote' items
			case "file":    item.remoteType = ItemType.file;    break;
			case "dir":     item.remoteType = ItemType.dir;     break;
			default: item.remoteType = ItemType.none;    break; // Default to ItemType.none
		}
		
		// Return item
		return item;
	}

	// computes the path of the given item id
	// the path is relative to the sync directory ex: "Music/Turbo Killer.mp3"
	// the trailing slash is not added even if the item is a directory
	string computePath(const(char)[] driveId, const(char)[] id) {
		assert(driveId && id);
		string path;
		Item item;
		auto s = db.prepare("SELECT * FROM item WHERE driveId = ?1 AND id = ?2");
		auto s2 = db.prepare("SELECT driveId, id FROM item WHERE remoteDriveId = ?1 AND remoteId = ?2");
		while (true) {
			s.bind(1, driveId);
			s.bind(2, id);
			auto r = s.exec();
			if (!r.empty) {
				item = buildItem(r);
				if (item.type == ItemType.remote) {
					// substitute the last name with the current
					ptrdiff_t idx = indexOf(path, '/');
					path = idx >= 0 ? item.name ~ path[idx .. $] : item.name;
				} else {
					if (path) path = item.name ~ "/" ~ path;
					else path = item.name;
				}
				id = item.parentId;
			} else {
				if (id == null) {
					// check for remoteItem
					s2.bind(1, item.driveId);
					s2.bind(2, item.id);
					auto r2 = s2.exec();
					if (r2.empty) {
						// root reached
						assert(path.length >= 4);
						// remove "root/" from path string if it exists
						if (path.length >= 5) {
							if (canFind(path, "root/")){
								path = path[5 .. $];
							}
						} else {
							path = path[4 .. $];
						}
						// special case of computing the path of the root itself
						if (path.length == 0) path = ".";
						break;
					} else {
						// remote folder
						driveId = r2.front[0].dup;
						id = r2.front[1].dup;
					}
				} else {
					// broken tree
					addLogEntry("The following generated a broken tree query:", ["debug"]);
					addLogEntry("Drive ID: " ~ to!string(driveId), ["debug"]);
					addLogEntry("Item ID: " ~ to!string(id), ["debug"]);
					assert(0);
				}
			}
		}
		return path;
	}

	Item[] selectRemoteItems() {
		Item[] items;
		auto stmt = db.prepare("SELECT * FROM item WHERE remoteDriveId IS NOT NULL");
		auto res = stmt.exec();
		while (!res.empty) {
			items ~= buildItem(res);
			res.step();
		}
		return items;
	}

	string getDeltaLink(const(char)[] driveId, const(char)[] id) {
		// Log what we received
		addLogEntry("DeltaLink Query (driveId): " ~ to!string(driveId), ["debug"]);
		addLogEntry("DeltaLink Query (id):      " ~ to!string(id), ["debug"]);
			
		assert(driveId && id);
		auto stmt = db.prepare("SELECT deltaLink FROM item WHERE driveId = ?1 AND id = ?2");
		stmt.bind(1, driveId);
		stmt.bind(2, id);
		auto res = stmt.exec();
		if (res.empty) return null;
		return res.front[0].dup;
	}

	void setDeltaLink(const(char)[] driveId, const(char)[] id, const(char)[] deltaLink) {
		assert(driveId && id);
		assert(deltaLink);
		auto stmt = db.prepare("UPDATE item SET deltaLink = ?3 WHERE driveId = ?1 AND id = ?2");
		stmt.bind(1, driveId);
		stmt.bind(2, id);
		stmt.bind(3, deltaLink);
		stmt.exec();
	}
	
	// National Cloud Deployments (US and DE) do not support /delta as a query
	// We need to track in the database that this item is in sync
	// As we query /children to get all children from OneDrive, update anything in the database 
	// to be flagged as not-in-sync, thus, we can use that flag to determing what was previously
	// in-sync, but now deleted on OneDrive
	void downgradeSyncStatusFlag(const(char)[] driveId, const(char)[] id) {
		assert(driveId);
		auto stmt = db.prepare("UPDATE item SET syncStatus = 'N' WHERE driveId = ?1 AND id = ?2");
		stmt.bind(1, driveId);
		stmt.bind(2, id);
		stmt.exec();
	}
	
	// National Cloud Deployments (US and DE) do not support /delta as a query
	// Select items that have a out-of-sync flag set
	Item[] selectOutOfSyncItems(const(char)[] driveId) {
		assert(driveId);
		Item[] items;
		auto stmt = db.prepare("SELECT * FROM item WHERE syncStatus = 'N' AND driveId = ?1");
		stmt.bind(1, driveId);
		auto res = stmt.exec();
		while (!res.empty) {
			items ~= buildItem(res);
			res.step();
		}
		return items;
	}
	
	// OneDrive Business Folders are stored in the database potentially without a root | parentRoot link
	// Select items associated with the provided driveId
	Item[] selectByDriveId(const(char)[] driveId) {
		assert(driveId);
		Item[] items;
		auto stmt = db.prepare("SELECT * FROM item WHERE driveId = ?1 AND parentId IS NULL");
		stmt.bind(1, driveId);
		auto res = stmt.exec();
		while (!res.empty) {
			items ~= buildItem(res);
			res.step();
		}
		return items;
	}
	
	// Select all items associated with the provided driveId
	Item[] selectAllItemsByDriveId(const(char)[] driveId) {
		assert(driveId);
		Item[] items;
		auto stmt = db.prepare("SELECT * FROM item WHERE driveId = ?1");
		stmt.bind(1, driveId);
		auto res = stmt.exec();
		while (!res.empty) {
			items ~= buildItem(res);
			res.step();
		}
		return items;
	}
	
	// Perform a vacuum on the database, commit WAL / SHM to file
	void performVacuum() {
		addLogEntry("Attempting to perform a database vacuum to merge any temporary data", ["debug"]);
		
		try {
			auto stmt = db.prepare("VACUUM;");
			stmt.exec();
			addLogEntry("Database vacuum is complete", ["debug"]);
		} catch (SqliteException e) {
			addLogEntry();
			addLogEntry("ERROR: Unable to perform a database vacuum: " ~ e.msg);
			addLogEntry();
		}
	}
	
	// Select distinct driveId items from database
	string[] selectDistinctDriveIds() {
		string[] driveIdArray;
		auto stmt = db.prepare("SELECT DISTINCT driveId FROM item;");
		auto res = stmt.exec();
		if (res.empty) return driveIdArray;
		while (!res.empty) {
			driveIdArray ~= res.front[0].dup;
			res.step();
		}
		return driveIdArray;
	}
}