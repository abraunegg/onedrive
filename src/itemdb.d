import std.datetime, std.path, std.exception, std.string;
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
	string   crc32Hash;
	string   sha1Hash;
	string   quickXorHash;
}

final class ItemDatabase
{
	// increment this for every change in the db schema
	immutable int itemDatabaseVersion = 4;

	Database db;
	Statement insertItemStmt;
	Statement updateItemStmt;
	Statement selectItemByIdStmt;
	Statement selectItemByParentIdStmt;

	this(const(char)[] filename)
	{
		db = Database(filename);
		if (db.getVersion() == 0) {
			db.exec("CREATE TABLE item (
				id              TEXT NOT NULL PRIMARY KEY,
				name            TEXT NOT NULL,
				type            TEXT NOT NULL,
				eTag            TEXT,
				cTag            TEXT,
				mtime           TEXT NOT NULL,
				parentId        TEXT,
				crc32Hash       TEXT,
				sha1Hash        TEXT,
				quickXorHash    TEXT,
				FOREIGN KEY (parentId) REFERENCES item (id) ON DELETE CASCADE
			)");
			db.exec("CREATE INDEX name_idx ON item (name)");
			db.setVersion(itemDatabaseVersion);
		} else if (db.getVersion() != itemDatabaseVersion) {
			throw new Exception("The item database is incompatible, please resync manually");
		}
		db.exec("PRAGMA foreign_keys = ON");
		db.exec("PRAGMA recursive_triggers = ON");
		insertItemStmt = db.prepare("INSERT OR REPLACE INTO item (id, name, type, eTag, cTag, mtime, parentId, crc32Hash, sha1Hash, quickXorHash) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)");
		updateItemStmt = db.prepare("
			UPDATE item
			SET name = ?2, type = ?3, eTag = ?4, cTag = ?5, mtime = ?6, parentId = ?7, crc32Hash = ?8, sha1Hash = ?9, quickXorHash = ?10
			WHERE id = ?1
		");
		selectItemByIdStmt = db.prepare("SELECT id, name, type, eTag, cTag, mtime, parentId, crc32Hash, sha1Hash, quickXorHash FROM item WHERE id = ?");
		selectItemByParentIdStmt = db.prepare("SELECT id FROM item WHERE parentId = ?");
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
		auto s = db.prepare("SELECT COUNT(*) FROM item WHERE id = ?");
		s.bind(1, item.id);
		auto r = s.exec();
		Statement* stmt;
		if (r.front[0] == "0") stmt = &insertItemStmt;
		else stmt = &updateItemStmt;
		bindItem(item, *stmt);
		stmt.exec();
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
		// prefix with the root dir
		path = "root/" ~ path.chompPrefix(".");

		// initialize the search
		string[2][] candidates; // [id, parentId]
		auto s = db.prepare("SELECT id, parentId FROM item WHERE name = ?");
		s.bind(1, baseName(path));
		auto r = s.exec();
		foreach (row; r) candidates ~= [row[0].dup, row[1].dup];
		path = dirName(path);

		if (path != ".") {
			s = db.prepare("SELECT parentId FROM item WHERE id = ? AND name = ?");
			// discard the candidates that do not have the correct parent
			do {
				s.bind(2, baseName(path));
				string[2][] newCandidates;
				newCandidates.reserve(candidates.length);
				foreach (candidate; candidates) {
					s.bind(1, candidate[1]);
					r = s.exec();
					if (!r.empty) {
						string[2] c = [candidate[0], r.front[0].idup];
						newCandidates ~= c;
					}
				}
				candidates = newCandidates;
				path = dirName(path);
			} while (path != ".");
		}

		// reached the root
		string[2][] newCandidates;
		foreach (candidate; candidates) {
			if (!candidate[1]) {
				newCandidates ~= candidate;
			}
		}
		candidates = newCandidates;
		assert(candidates.length <= 1);

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

	private void bindItem(const ref Item item, ref Statement stmt)
	{
		with (stmt) with (item) {
			bind(1, id);
			bind(2, name);
			string typeStr = null;
			final switch (type) with (ItemType) {
				case file: typeStr = "file"; break;
				case dir:  typeStr = "dir";  break;
			}
			bind(3, typeStr);
			bind(4, eTag);
			bind(5, cTag);
			bind(6, mtime.toISOExtString());
			bind(7, parentId);
			bind(8, crc32Hash);
			bind(9, sha1Hash);
			bind(10, quickXorHash);
		}
	}

	private Item buildItem(Statement.Result result)
	{
		assert(!result.empty && result.front.length == 10);
		Item item = {
			id: result.front[0].dup,
			name: result.front[1].dup,
			eTag: result.front[3].dup,
			cTag: result.front[4].dup,
			mtime: SysTime.fromISOExtString(result.front[5]),
			parentId: result.front[6].dup,
			crc32Hash: result.front[7].dup,
			sha1Hash: result.front[8].dup,
			quickXorHash: result.front[9].dup
		};
		switch (result.front[2]) {
			case "file": item.type = ItemType.file; break;
			case "dir":  item.type = ItemType.dir;  break;
			default: assert(0);
		}
		return item;
	}

	// computes the path of the given item id
	// the path is relative to the sync directory ex: "./Music/Turbo Killer.mp3"
	// a trailing slash is never added
	string computePath(const(char)[] id)
	{
		string path;
		auto s = db.prepare("SELECT name, parentId FROM item WHERE id = ?");
		while (true) {
			s.bind(1, id);
			auto r = s.exec();
			enforce(!r.empty, "Unknow item id");
			if (r.front[1]) {
				if (path) path = r.front[0].idup ~ "/" ~ path;
				else path = r.front[0].idup;
			} else {
				// root
				if (!path) path = ".";
				break;
			}
			id = r.front[1].dup;
		}
		return path;
	}
}
