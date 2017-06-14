import std.datetime, std.path, std.exception, std.string;
import sqlite;

enum ItemType
{
	file,
	dir,
	remote
}

struct Item
{
	string   driveId;
	string   id;
	string   name;
	ItemType type;
	string   eTag;
	string   cTag;
	SysTime  mtime;
	string   parentDriveId;
	string   parentId;
	string   crc32Hash;
	string   sha1Hash;
	string   quickXorHash;
}

final class ItemDatabase
{
	// increment this for every change in the db schema
	immutable int itemDatabaseVersion = 5;

	Database db;
	Statement insertItemStmt;
	Statement updateItemStmt;
	Statement selectItemByIdStmt;
	Statement selectItemByParentIdStmt;
	Statement deleteItemByIdStmt;

	this(const(char)[] filename)
	{
		db = Database(filename);
		if (db.getVersion() == 0) {
			db.exec("CREATE TABLE item (
				driveId          TEXT NOT NULL,
				id               TEXT NOT NULL,
				name             TEXT NOT NULL,
				type             TEXT NOT NULL,
				eTag             TEXT,
				cTag             TEXT,
				mtime            TEXT NOT NULL,
				parentDriveId    TEXT,
				parentId         TEXT,
				crc32Hash        TEXT,
				sha1Hash         TEXT,
				quickXorHash     TEXT,
				PRIMARY KEY (driveId, id),
				FOREIGN KEY (parentDriveId, parentId)
				REFERENCES item (driveId, id)
				ON DELETE CASCADE
				ON UPDATE RESTRICT
			)");
			db.exec("CREATE INDEX name_idx ON item (name)");
			db.setVersion(itemDatabaseVersion);
		} else if (db.getVersion() != itemDatabaseVersion) {
			throw new Exception("The item database is incompatible, please resync manually");
		}
		db.exec("PRAGMA foreign_keys = ON");
		db.exec("PRAGMA recursive_triggers = ON");
		insertItemStmt = db.prepare("
			INSERT OR REPLACE INTO item (driveId, id, name, type, eTag, cTag, mtime, parentDriveId, parentId, crc32Hash, sha1Hash, quickXorHash)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		");
		updateItemStmt = db.prepare("
			UPDATE item
			SET name = ?3, type = ?4, eTag = ?5, cTag = ?6, mtime = ?7, parentDriveId = ?8, parentId = ?9, crc32Hash = ?10, sha1Hash = ?11, quickXorHash = ?12
			WHERE driveId = ?1 AND id = ?2
		");
		selectItemByIdStmt = db.prepare("
			SELECT *
			FROM item
			WHERE driveId = ?1 AND id = ?2
		");
		selectItemByParentIdStmt = db.prepare("SELECT driveId, id FROM item WHERE parentId = ? AND id = ?");
		deleteItemByIdStmt = db.prepare("DELETE FROM item WHERE driveId = ? AND id = ?");
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
		foreach (row; res) {
			Item item;
			bool found = selectById(row[0], row[1], item);
			assert(found, "Could not select the child of the item");
			items ~= item;
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

	// returns the item with the given path
	// the path is relative to the sync directory ex: "./Music/Turbo Killer.mp3"
	bool selectByPath(const(char)[] path, out Item item)
	{
		Item currItem;
		path = "root/" ~ path.chompPrefix(".");
		auto s = db.prepare("SELECT * FROM item WHERE name IS ?1 AND parentDriveId IS ?2 AND parentId IS ?3");
		foreach (name; pathSplitter(path)) {
			s.bind(1, name);
			s.bind(2, currItem.driveId);
			s.bind(3, currItem.id);
			auto r = s.exec();
			if (r.empty) return false;
			currItem = buildItem(r);
			// if the item is of type remote substitute it with the child
			if (currItem.type == ItemType.remote) {
				auto children = selectChildren(currItem.driveId, currItem.id);
				enforce(children.length == 1, "The remote item does not have exactly 1 child");
				// keep the name of the remote item
				children[0].name = currItem.name;
				currItem = children[0];
			}
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
			bind(8, parentDriveId);
			bind(9, parentId);
			bind(10, crc32Hash);
			bind(11, sha1Hash);
			bind(12, quickXorHash);
		}
	}

	private Item buildItem(Statement.Result result)
	{
		assert(!result.empty, "The result must not be empty");
		assert(result.front.length == 12, "The result must have 12 columns");
		Item item = {
			driveId: result.front[0].dup,
			id: result.front[1].dup,
			name: result.front[2].dup,
			eTag: result.front[4].dup,
			cTag: result.front[5].dup,
			mtime: SysTime.fromISOExtString(result.front[6]),
			parentDriveId: result.front[7].dup,
			parentId: result.front[8].dup,
			crc32Hash: result.front[9].dup,
			sha1Hash: result.front[10].dup,
			quickXorHash: result.front[11].dup
		};
		switch (result.front[3]) {
			case "file":    item.type = ItemType.file;    break;
			case "dir":     item.type = ItemType.dir;     break;
			case "remote":  item.type = ItemType.remote;  break;
			default: assert(0);
		}
		return item;
	}

	// computes the path of the given item id
	// the path is relative to the sync directory ex: "Music/Turbo Killer.mp3"
	// a trailing slash is not added if the item is a directory
	string computePath(const(char)[] driveId, const(char)[] id)
	{
		string path;
		Item item;
		while (true) {
			enforce(selectById(driveId, id, item), "Unknow item id");
			if (item.type == ItemType.remote) {
				// substitute the last name with the current
				path = item.name ~ path[indexOf(path, '/') .. $];
			} else if (item.parentId) {
				if (path) path = item.name ~ "/" ~ path;
				else path = item.name;
			} else {
				// root
				if (!path) path = ".";
				break;
			}
			driveId = item.parentDriveId;
			id = item.parentId;
		}
		return path;
	}
}
