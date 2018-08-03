import std.datetime;
import std.exception;
import std.path;
import std.string;
import core.stdc.stdlib;
import sqlite;
static import log;

enum ItemType {
	file,
	dir,
	remote
}

struct Item {
	string   driveId;
	string   id;
	string   name;
	ItemType type;
	string   eTag;
	string   cTag;
	SysTime  mtime;
	string   parentId;
	string   crc32Hash;
	string   sha1Hash;
	string   quickXorHash;
	string   remoteDriveId;
	string   remoteId;
}

final class ItemDatabase
{
	// increment this for every change in the db schema
	immutable int itemDatabaseVersion = 7;

	Database db;
	Statement insertItemStmt;
	Statement updateItemStmt;
	Statement selectItemByIdStmt;
	Statement selectItemByParentIdStmt;
	Statement deleteItemByIdStmt;

	this(const(char)[] filename)
	{
		db = Database(filename);
		int dbVersion;
		try {
			dbVersion = db.getVersion();
		} catch (SqliteException e) {
			// An error was generated - what was the error?
			log.error("\nAn internal database error occurred: " ~ e.msg ~ "\n");
			exit(-1);
		}
		
		if (dbVersion == 0) {
			createTable();
		} else if (db.getVersion() != itemDatabaseVersion) {
			log.log("The item database is incompatible, re-creating database table structures");
			db.exec("DROP TABLE item");
			createTable();
		}
		db.exec("PRAGMA foreign_keys = ON");
		db.exec("PRAGMA recursive_triggers = ON");
		db.exec("PRAGMA journal_mode = WAL");
		
		insertItemStmt = db.prepare("
			INSERT OR REPLACE INTO item (driveId, id, name, type, eTag, cTag, mtime, parentId, crc32Hash, sha1Hash, quickXorHash, remoteDriveId, remoteId)
			VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
		");
		updateItemStmt = db.prepare("
			UPDATE item
			SET name = ?3, type = ?4, eTag = ?5, cTag = ?6, mtime = ?7, parentId = ?8, crc32Hash = ?9, sha1Hash = ?10, quickXorHash = ?11, remoteDriveId = ?12, remoteId = ?13
			WHERE driveId = ?1 AND id = ?2
		");
		selectItemByIdStmt = db.prepare("
			SELECT *
			FROM item
			WHERE driveId = ?1 AND id = ?2
		");
		selectItemByParentIdStmt = db.prepare("SELECT * FROM item WHERE driveId = ? AND parentId = ?");
		deleteItemByIdStmt = db.prepare("DELETE FROM item WHERE driveId = ? AND id = ?");
	}

	void createTable()
	{
		db.exec("CREATE TABLE item (
				driveId          TEXT NOT NULL,
				id               TEXT NOT NULL,
				name             TEXT NOT NULL,
				type             TEXT NOT NULL,
				eTag             TEXT,
				cTag             TEXT,
				mtime            TEXT NOT NULL,
				parentId         TEXT,
				crc32Hash        TEXT,
				sha1Hash         TEXT,
				quickXorHash     TEXT,
				remoteDriveId    TEXT,
				remoteId         TEXT,
				deltaLink        TEXT,
				PRIMARY KEY (driveId, id),
				FOREIGN KEY (driveId, parentId)
				REFERENCES item (driveId, id)
				ON DELETE CASCADE
				ON UPDATE RESTRICT
			)");
		db.exec("CREATE INDEX name_idx ON item (name)");
		db.exec("CREATE INDEX remote_idx ON item (remoteDriveId, remoteId)");
		db.setVersion(itemDatabaseVersion);
	}
	
	void insert(const ref Item item)
	{
		bindItem(item, insertItemStmt);
		insertItemStmt.exec();
	}

	void update(const ref Item item)
	{
		bindItem(item, updateItemStmt);
		updateItemStmt.exec();
	}

	void upsert(const ref Item item)
	{
		auto s = db.prepare("SELECT COUNT(*) FROM item WHERE driveId = ? AND id = ?");
		s.bind(1, item.driveId);
		s.bind(2, item.id);
		auto r = s.exec();
		Statement* stmt;
		if (r.front[0] == "0") stmt = &insertItemStmt;
		else stmt = &updateItemStmt;
		bindItem(item, *stmt);
		stmt.exec();
	}

	Item[] selectChildren(const(char)[] driveId, const(char)[] id)
	{
		selectItemByParentIdStmt.bind(1, driveId);
		selectItemByParentIdStmt.bind(2, id);
		auto res = selectItemByParentIdStmt.exec();
		Item[] items;
		while (!res.empty) {
			items ~= buildItem(res);
			res.step();
		}
		return items;
	}

	bool selectById(const(char)[] driveId, const(char)[] id, out Item item)
	{
		selectItemByIdStmt.bind(1, driveId);
		selectItemByIdStmt.bind(2, id);
		auto r = selectItemByIdStmt.exec();
		if (!r.empty) {
			item = buildItem(r);
			return true;
		}
		return false;
	}

	// returns if an item id is in the database
	bool idInLocalDatabase(const(string) driveId, const(string)id)
	{
		selectItemByIdStmt.bind(1, driveId);
		selectItemByIdStmt.bind(2, id);
		auto r = selectItemByIdStmt.exec();
		if (!r.empty) {
			return true;
		}
		return false;
	}
	
	// returns the item with the given path
	// the path is relative to the sync directory ex: "./Music/Turbo Killer.mp3"
	bool selectByPath(const(char)[] path, string rootDriveId, out Item item)
	{
		Item currItem = { driveId: rootDriveId };
		path = "root/" ~ path.chompPrefix(".");
		auto s = db.prepare("SELECT * FROM item WHERE name = ?1 AND driveId IS ?2 AND parentId IS ?3");
		foreach (name; pathSplitter(path)) {
			s.bind(1, name);
			s.bind(2, currItem.driveId);
			s.bind(3, currItem.id);
			auto r = s.exec();
			if (r.empty) return false;
			currItem = buildItem(r);
			// if the item is of type remote substitute it with the child
			if (currItem.type == ItemType.remote) {
				Item child;
				if (selectById(currItem.remoteDriveId, currItem.remoteId, child)) {
					assert(child.type != ItemType.remote, "The type of the child cannot be remote");
					currItem = child;
				}
			}
		}
		item = currItem;
		return true;
	}

	// same as selectByPath() but it does not traverse remote folders
	bool selectByPathNoRemote(const(char)[] path, string rootDriveId, out Item item)
	{
		Item currItem = { driveId: rootDriveId };
		path = "root/" ~ path.chompPrefix(".");
		auto s = db.prepare("SELECT * FROM item WHERE name IS ?1 AND driveId IS ?2 AND parentId IS ?3");
		foreach (name; pathSplitter(path)) {
			s.bind(1, name);
			s.bind(2, currItem.driveId);
			s.bind(3, currItem.id);
			auto r = s.exec();
			if (r.empty) return false;
			currItem = buildItem(r);
		}
		item = currItem;
		return true;
	}

	void deleteById(const(char)[] driveId, const(char)[] id)
	{
		deleteItemByIdStmt.bind(1, driveId);
		deleteItemByIdStmt.bind(2, id);
		deleteItemByIdStmt.exec();
	}

	private void bindItem(const ref Item item, ref Statement stmt)
	{
		with (stmt) with (item) {
			bind(1, driveId);
			bind(2, id);
			bind(3, name);
			string typeStr = null;
			final switch (type) with (ItemType) {
				case file:    typeStr = "file";    break;
				case dir:     typeStr = "dir";     break;
				case remote:  typeStr = "remote";  break;
			}
			bind(4, typeStr);
			bind(5, eTag);
			bind(6, cTag);
			bind(7, mtime.toISOExtString());
			bind(8, parentId);
			bind(9, crc32Hash);
			bind(10, sha1Hash);
			bind(11, quickXorHash);
			bind(12, remoteDriveId);
			bind(13, remoteId);
		}
	}

	private Item buildItem(Statement.Result result)
	{
		assert(!result.empty, "The result must not be empty");
		assert(result.front.length == 14, "The result must have 14 columns");
		Item item = {
			driveId: result.front[0].dup,
			id: result.front[1].dup,
			name: result.front[2].dup,
			eTag: result.front[4].dup,
			cTag: result.front[5].dup,
			mtime: SysTime.fromISOExtString(result.front[6]),
			parentId: result.front[7].dup,
			crc32Hash: result.front[8].dup,
			sha1Hash: result.front[9].dup,
			quickXorHash: result.front[10].dup,
			remoteDriveId: result.front[11].dup,
			remoteId: result.front[12].dup
		};
		switch (result.front[3]) {
			case "file":    item.type = ItemType.file;    break;
			case "dir":     item.type = ItemType.dir;     break;
			case "remote":  item.type = ItemType.remote;  break;
			default: assert(0, "Invalid item type");
		}
		return item;
	}

	// computes the path of the given item id
	// the path is relative to the sync directory ex: "Music/Turbo Killer.mp3"
	// the trailing slash is not added even if the item is a directory
	string computePath(const(char)[] driveId, const(char)[] id)
	{
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
						// remove "root"
						if (path.length >= 5) path = path[5 .. $];
						else path = path[4 .. $];
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
					assert(0);
				}
			}
		}
		return path;
	}

	Item[] selectRemoteItems()
	{
		Item[] items;
		auto stmt = db.prepare("SELECT * FROM item WHERE remoteDriveId IS NOT NULL");
		auto res = stmt.exec();
		while (!res.empty) {
			items ~= buildItem(res);
			res.step();
		}
		return items;
	}

	string getDeltaLink(const(char)[] driveId, const(char)[] id)
	{
		assert(driveId && id);
		auto stmt = db.prepare("SELECT deltaLink FROM item WHERE driveId = ?1 AND id = ?2");
		stmt.bind(1, driveId);
		stmt.bind(2, id);
		auto res = stmt.exec();
		if (res.empty) return null;
		return res.front[0].dup;
	}

	void setDeltaLink(const(char)[] driveId, const(char)[] id, const(char)[] deltaLink)
	{
		assert(driveId && id);
		assert(deltaLink);
		auto stmt = db.prepare("UPDATE item SET deltaLink = ?3 WHERE driveId = ?1 AND id = ?2");
		stmt.bind(1, driveId);
		stmt.bind(2, id);
		stmt.bind(3, deltaLink);
		stmt.exec();
	}
}
