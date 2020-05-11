module sqlite;
import std.stdio;
import etc.c.sqlite3;
import std.string: fromStringz, toStringz;
import core.stdc.stdlib;
import std.conv;
static import log;

extern (C) immutable(char)* sqlite3_errstr(int); // missing from the std library

static this()
{
	if (sqlite3_libversion_number() < 3006019) {
		throw new SqliteException("sqlite 3.6.19 or newer is required");
	}
}

private string ifromStringz(const(char)* cstr)
{
	return fromStringz(cstr).dup;
}

class SqliteException: Exception
{
	@safe pure nothrow this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable next = null)
    {
        super(msg, file, line, next);
    }

    @safe pure nothrow this(string msg, Throwable next, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line, next);
    }
}

struct Database
{
	private sqlite3* pDb;

	this(const(char)[] filename)
	{
		open(filename);
	}

	~this()
	{
		close();
	}

	int db_checkpoint()
	{
		return sqlite3_wal_checkpoint(pDb, null);
	}

	void dump_open_statements()
	{
		log.log("Dumpint open statements: \n");
		auto p = sqlite3_next_stmt(pDb, null);
		while (p != null) {
			log.log (" - " ~ ifromStringz(sqlite3_sql(p)) ~ "\n");
			p = sqlite3_next_stmt(pDb, p);
		}
	}


	void open(const(char)[] filename)
	{
		// https://www.sqlite.org/c3ref/open.html
		int rc = sqlite3_open(toStringz(filename), &pDb);
		if (rc == SQLITE_CANTOPEN) {
			// Database cannot be opened
			log.error("\nThe database cannot be opened. Please check the permissions of ~/.config/onedrive/items.sqlite3\n");
			close();
			exit(-1);
		}
		if (rc != SQLITE_OK) {
			log.error("\nA database access error occurred: " ~ getErrorMessage() ~ "\n");
			close();
			exit(-1);
		}
		sqlite3_extended_result_codes(pDb, 1); // always use extended result codes
	}

	void exec(const(char)[] sql)
	{
		// https://www.sqlite.org/c3ref/exec.html
		int rc = sqlite3_exec(pDb, toStringz(sql), null, null, null);
		if (rc != SQLITE_OK) {
			log.error("\nA database execution error occurred: "~ getErrorMessage() ~ "\n");
			log.error("Please retry your command with --resync to fix any local database corruption issues.\n");
			close();
			exit(-1);
		}
	}

	int getVersion()
	{
		int userVersion;
		extern (C) int callback(void* user_version, int count, char** column_text, char** column_name) {
			import core.stdc.stdlib: atoi;
			*(cast(int*) user_version) = atoi(*column_text);
			return 0;
		}
		int rc = sqlite3_exec(pDb, "PRAGMA user_version", &callback, &userVersion, null);
		if (rc != SQLITE_OK) {
			throw new SqliteException(ifromStringz(sqlite3_errmsg(pDb)));
		}
		return userVersion;
	}

	string getErrorMessage()
	{
		return ifromStringz(sqlite3_errmsg(pDb));
	}
	
	void setVersion(int userVersion)
	{
		import std.conv: to;
		exec("PRAGMA user_version=" ~ to!string(userVersion));
	}

	Statement prepare(const(char)[] zSql)
	{
		Statement s;
		// https://www.sqlite.org/c3ref/prepare.html
		int rc = sqlite3_prepare_v2(pDb, zSql.ptr, cast(int) zSql.length, &s.pStmt, null);
		if (rc != SQLITE_OK) {
			throw new SqliteException(ifromStringz(sqlite3_errmsg(pDb)));
		}
		return s;
	}

	void close()
	{
		// https://www.sqlite.org/c3ref/close.html
		sqlite3_close_v2(pDb);
		pDb = null;
	}
}

struct Statement
{
	struct Result
	{
		private sqlite3_stmt* pStmt;
		private const(char)[][] row;

		private this(sqlite3_stmt* pStmt)
		{
			this.pStmt = pStmt;
			step(); // initialize the range
		}

		@property bool empty()
		{
			return row.length == 0;
		}

		@property auto front()
		{
			return row;
		}

		alias step popFront;

		void step()
		{
			// https://www.sqlite.org/c3ref/step.html
			int rc = sqlite3_step(pStmt);
			if (rc == SQLITE_BUSY) {
				// Database is locked by another onedrive process
				log.error("The database is currently locked by another process - cannot sync");
				return;
			}
			if (rc == SQLITE_DONE) {
				row.length = 0;
			} else if (rc == SQLITE_ROW) {
				// https://www.sqlite.org/c3ref/data_count.html
				int count = 0;
				count = sqlite3_data_count(pStmt);
				row = new const(char)[][count];
				foreach (size_t i, ref column; row) {
					// https://www.sqlite.org/c3ref/column_blob.html
					column = fromStringz(sqlite3_column_text(pStmt, to!int(i)));
				}
			} else {
				string errorMessage = ifromStringz(sqlite3_errmsg(sqlite3_db_handle(pStmt)));
				log.error("\nA database statement execution error occurred: "~ errorMessage ~ "\n");
				log.error("Please retry your command with --resync to fix any local database corruption issues.\n");
				exit(-1);
			}
		}
	}

	private sqlite3_stmt* pStmt;

	~this()
	{
		// https://www.sqlite.org/c3ref/finalize.html
		sqlite3_finalize(pStmt);
	}

	void bind(int index, const(char)[] value)
	{
		reset();
		// https://www.sqlite.org/c3ref/bind_blob.html
		int rc = sqlite3_bind_text(pStmt, index, value.ptr, cast(int) value.length, SQLITE_STATIC);
		if (rc != SQLITE_OK) {
			throw new SqliteException(ifromStringz(sqlite3_errmsg(sqlite3_db_handle(pStmt))));
		}
	}

	Result exec()
	{
		reset();
		return Result(pStmt);
	}

	private void reset()
	{
		// https://www.sqlite.org/c3ref/reset.html
		int rc = sqlite3_reset(pStmt);
		if (rc != SQLITE_OK) {
			throw new SqliteException(ifromStringz(sqlite3_errmsg(sqlite3_db_handle(pStmt))));
		}
	}
}

unittest
{
	auto db = Database(":memory:");
	db.exec("CREATE TABLE test(
		id    TEXT PRIMARY KEY,
		value TEXT
	)");

	assert(db.getVersion() == 0);
	db.setVersion(1);
	assert(db.getVersion() == 1);

	auto s = db.prepare("INSERT INTO test VALUES (?, ?)");
	s.bind(1, "key1");
	s.bind(2, "value");
	s.exec();
	s.bind(1, "key2");
	s.bind(2, null);
	s.exec();

	s = db.prepare("SELECT * FROM test ORDER BY id ASC");
	auto r = s.exec();
	assert(r.front[0] == "key1");
	r.popFront();
	assert(r.front[1] == null);
	r.popFront();
	assert(r.empty);
}
