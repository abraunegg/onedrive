import std.datetime, std.path;
import sqlite;

enum ItemType
{
	file,
	dir
}

struct Item
{
	string   id;
	string   name;
	ItemType type;
	string   eTag;
	string   cTag;
	SysTime  mtime;
	string   parentId;
	string   crc32;
}

final class ItemDatabase
{
	Database db;
	Statement insertItemStmt;
	Statement updateItemStmt;
	Statement selectItemByIdStmt;
	Statement selectItemByParentIdStmt;

	this(const(char)[] filename)
	{
		db = Database(filename);
		db.exec("CREATE TABLE IF NOT EXISTS item (
			id       TEXT PRIMARY KEY,
			name     TEXT NOT NULL,
			type     TEXT NOT NULL,
			eTag     TEXT NOT NULL,
			cTag     TEXT NOT NULL,
			mtime    TEXT NOT NULL,
			parentId TEXT,
			crc32    TEXT,
			FOREIGN KEY (parentId) REFERENCES item (id) ON DELETE CASCADE
		)");
		db.exec("CREATE INDEX IF NOT EXISTS name_idx ON item (name)");
		db.exec("PRAGMA foreign_keys = ON");
		db.exec("PRAGMA recursive_triggers = ON");
		insertItemStmt = db.prepare("INSERT OR REPLACE INTO item (id, name, type, eTag, cTag, mtime, parentId, crc32) VALUES (?, ?, ?, ?, ?, ?, ?, ?)");
		updateItemStmt = db.prepare("
			UPDATE item
			SET name = ?2, type = ?3, eTag = ?4, cTag = ?5, mtime = ?6, parentId = ?7, crc32 = ?8
			WHERE id = ?1
		");
		selectItemByIdStmt = db.prepare("SELECT id, name, type, eTag, cTag, mtime, parentId, crc32 FROM item WHERE id = ?");
		selectItemByParentIdStmt = db.prepare("SELECT id FROM item WHERE parentId = ?");
	}

	void insert(const(char)[] id, const(char)[] name, ItemType type, const(char)[] eTag, const(char)[] cTag, const(char)[] mtime, const(char)[] parentId, const(char)[] crc32)
	{
		with (insertItemStmt) {
			bind(1, id);
			bind(2, name);
			string typeStr = void;
			final switch (type) {
			case ItemType.file: typeStr = "file"; break;
			case ItemType.dir:  typeStr = "dir";  break;
			}
			bind(3, typeStr);
			bind(4, eTag);
			bind(5, cTag);
			bind(6, mtime);
			bind(7, parentId);
			bind(8, crc32);
			exec();
		}
	}

	void update(const(char)[] id, const(char)[] name, ItemType type, const(char)[] eTag, const(char)[] cTag, const(char)[] mtime, const(char)[] parentId, const(char)[] crc32)
	{
		with (updateItemStmt) {
			bind(1, id);
			bind(2, name);
			string typeStr = void;
			final switch (type) {
			case ItemType.file: typeStr = "file"; break;
			case ItemType.dir:  typeStr = "dir";  break;
			}
			bind(3, typeStr);
			bind(4, eTag);
			bind(5, cTag);
			bind(6, mtime);
			bind(7, parentId);
			bind(8, crc32);
			exec();
		}
	}

	void upsert(const(char)[] id, const(char)[] name, ItemType type, const(char)[] eTag, const(char)[] cTag, const(char)[] mtime, const(char)[] parentId, const(char)[] crc32)
	{
		auto s = db.prepare("SELECT COUNT(*) FROM item WHERE id = ?");
		s.bind(1, id);
		auto r = s.exec();
		Statement* p;
		if (r.front[0] == "0") p = &insertItemStmt;
		else p = &updateItemStmt;
		with (p) {
			bind(1, id);
			bind(2, name);
			string typeStr = void;
			final switch (type) {
			case ItemType.file: typeStr = "file"; break;
			case ItemType.dir:  typeStr = "dir";  break;
			}
			bind(3, typeStr);
			bind(4, eTag);
			bind(5, cTag);
			bind(6, mtime);
			bind(7, parentId);
			bind(8, crc32);
			exec();
		}
	}

	Item[] selectChildren(const(char)[] id)
	{
		selectItemByParentIdStmt.bind(1, id);
		auto res = selectItemByParentIdStmt.exec();
		Item[] items;
		foreach (row; res) {
			Item item;
			bool found = selectById(row[0], item);
			assert(found);
			items ~= item;
		}
		return items;
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
		if (path == ".") path = "root"; // HACK
		string[2][] candidates; // [id, parentId]
		auto s = db.prepare("SELECT id, parentId FROM item WHERE name = ?");
		s.bind(1, baseName(path));
		auto r = s.exec();
		foreach (row; r) candidates ~= [row[0].dup, row[1].dup];
		if (candidates.length > 1) {
			s = db.prepare("SELECT parentId FROM item WHERE id = ? AND name = ?");
			do {
				string[2][] newCandidates;
				newCandidates.reserve(candidates.length);
				path = dirName(path);
				if (path.length != 0) {
					s.bind(2, baseName(path));
					foreach (candidate; candidates) {
						s.bind(1, candidate[1]);
						r = s.exec();
						if (!r.empty) {
							string[2] c = [candidate[0], r.front[0].idup];
							newCandidates ~= c;
						}
					}
				} else {
					// reached the root
					foreach (candidate; candidates) {
						if (!candidate[1]) {
							newCandidates ~= candidate;
						}
					}
					assert(newCandidates.length <= 1);
				}
				candidates = newCandidates;
			} while (candidates.length > 1);
		}
		if (candidates.length == 1) return selectById(candidates[0][0], item);
		return false;
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
		assert(!result.empty && result.front.length == 8);
		Item item = {
			id: result.front[0].dup,
			name: result.front[1].dup,
			eTag: result.front[3].dup,
			cTag: result.front[4].dup,
			mtime: SysTime.fromISOExtString(result.front[5]),
			parentId: result.front[6].dup,
			crc32: result.front[7].dup
		};
		switch (result.front[2]) {
		case "file": item.type = ItemType.file; break;
		case "dir":  item.type = ItemType.dir;  break;
		default: assert(0);
		}
		return item;
	}

	string computePath(const(char)[] id)
	{
		if (!id) return null;
		string path;
		auto s = db.prepare("SELECT name, parentId FROM item WHERE id = ?");
		while (true) {
			s.bind(1, id);
			auto r = s.exec();
			if (r.empty) break;
			if (path) path = r.front[0].idup ~ "/" ~ path;
			else path = r.front[0].dup;
			id = r.front[1].dup;
		}
		// HACK: skip "root/"
		if (path.length < 5) return ".";
		return path[5 .. $];
	}
}
