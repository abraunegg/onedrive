module cache;

import std.datetime: SysTime, time_t;
import sqlite;

enum ItemType
{
	file,
	dir
}

struct Item
{
	string   id;
	string   path;
	string   name;
	ItemType type;
	string   eTag;
	string   cTag;
	SysTime  mtime;
	string   parentId;
	string   crc32;
}

struct ItemCache
{
	Database db;
	Statement insertItemStmt;
	Statement selectItemByIdStmt;
	Statement selectItemByPathStmt;

	void init()
	{
		db = Database("cache.db");
		db.exec("CREATE TABLE IF NOT EXISTS item (
			id       TEXT PRIMARY KEY,
			path     TEXT UNIQUE NOT NULL,
			name     TEXT NOT NULL,
			type     TEXT NOT NULL,
			eTag     TEXT NOT NULL,
			cTag     TEXT NOT NULL,
			mtime    TEXT NOT NULL,
			parentId TEXT NOT NULL,
			crc32    TEXT
		)");
		db.exec("CREATE UNIQUE INDEX IF NOT EXISTS path_idx ON item (path)");
		insertItemStmt = db.prepare("INSERT OR REPLACE INTO item (id, path, name, type, eTag, cTag, mtime, parentId, crc32) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)");
		selectItemByIdStmt = db.prepare("SELECT id, path, name, type, eTag, cTag, mtime, parentId, crc32 FROM item WHERE id = ?");
		selectItemByPathStmt = db.prepare("SELECT id, path, name, type, eTag, cTag, mtime, parentId, crc32 FROM item WHERE path = ?");
	}

	void insert(const(char)[] id, const(char)[] name, ItemType type, const(char)[] eTag, const(char)[] cTag, const(char)[] mtime, const(char)[] parentId, const(char)[] crc32)
	{
		with (insertItemStmt) {
			bind(1, id);
			bind(2, computePath(name, parentId));
			bind(3, name);
			string typeStr = void;
			final switch (type) {
			case ItemType.file: typeStr = "file"; break;
			case ItemType.dir:  typeStr = "dir";  break;
			}
			bind(4, typeStr);
			bind(5, eTag);
			bind(6, cTag);
			bind(7, mtime);
			bind(8, parentId);
			bind(9, crc32);
			exec();
		}
	}

	bool selectById(const(char)[] id, out Item item)
	{
		selectItemByIdStmt.bind(1, id);
		auto r = selectItemByIdStmt.exec();
		if (!r.empty) {
			item = buildItem(r);
			return true;
		}
		return false;
	}

	bool selectByPath(const(char)[] path, out Item item)
	{
		selectItemByPathStmt.bind(1, path);
		auto r = selectItemByPathStmt.exec();
		if (!r.empty) {
			item = buildItem(r);
			return true;
		}
		return false;
	}

	void updateModifiedTime(const(char)[] id, const(char)[] mtime)
	{
		auto s = db.prepare("UPDATE mtime FROM item WHERE id = ?");
		s.bind(1, id);
		s.exec();
	}

	void deleteById(const(char)[] id)
	{
		auto s = db.prepare("DELETE FROM item WHERE id = ?");
		s.bind(1, id);
		s.exec();
	}

	// returns true if the item has the specified parent
	bool hasParent(T)(const(char)[] itemId, T parentId)
	if (is(T : const(char)[]) || is(T : const(char[])[]))
	{
		auto s = db.prepare("SELECT parentId FROM item WHERE id = ?");
		while (true) {
			s.bind(1, itemId);
			auto r = s.exec();
			if (r.empty) break;
			auto currParentId = r.front[0];
			static if (is(T : const(char)[])) {
				if (currParentId == parentId) return true;
			} else {
				foreach (id; parentId) if (currParentId == id) return true;
			}
			itemId = currParentId.dup;
		}
		return false;
	}

	private Item buildItem(Statement.Result result)
	{
		assert(!result.empty && result.front.length == 9);
		Item item = {
			id: result.front[0].dup,
			path: result.front[1].dup,
			name: result.front[2].dup,
			eTag: result.front[4].dup,
			cTag: result.front[5].dup,
			mtime: SysTime.fromISOExtString(result.front[6]),
			parentId: result.front[7].dup,
			crc32: result.front[8].dup
		};
		switch (result.front[3]) {
		case "file": item.type = ItemType.file; break;
		case "dir":  item.type = ItemType.dir;  break;
		default: assert(0);
		}
		return item;
	}

	private string computePath(const(char)[] name, const(char)[] parentId)
	{
		auto s = db.prepare("SELECT name, parentId FROM item WHERE id = ?");
		string path = name.dup;
		while (true) {
			s.bind(1, parentId);
			auto r = s.exec();
			if (r.empty) break;
			path = r.front[0].idup ~ "/" ~ path;
			parentId = r.front[1].dup;
		}
		return path;
	}
}
