// What is this module called?
module sqlite;

// What does this module require to function?
import std.stdio;
import etc.c.sqlite3;
import std.string: fromStringz, toStringz;
import core.stdc.stdlib;
import std.conv;

// What other modules that we have created do we need to import?
import log;
import util;

extern (C) immutable(char)* sqlite3_errstr(int); // missing from the std library

static this() {
	if (sqlite3_libversion_number() < 3006019) {
		throw new SqliteException(-1, "SQLite 3.6.19 or newer is required");
	}
}

private string ifromStringz(const(char)* cstr) {
	return fromStringz(cstr).idup;
}

class SqliteException: Exception {
	int errorCode; // Add an errorCode member to store the SQLite error code
	@safe pure nothrow this(int errorCode, string msg, string file = __FILE__, size_t line = __LINE__, Throwable next = null) {
        super(msg, file, line, next);
		this.errorCode = errorCode; // Set the errorCode
    }

    @safe pure nothrow this(int errorCode, string msg, Throwable next, string file = __FILE__, size_t line = __LINE__) {
        super(msg, file, line, next);
		this.errorCode = errorCode; // Set the errorCode
    }
}

struct Database {
	private sqlite3* pDb;

	this(const(char)[] filename) {
		open(filename);
	}

	~this() {
		close();
	}

	int db_checkpoint() {
		return sqlite3_wal_checkpoint(pDb, null);
	}

	// Dump open statements
	void dump_open_statements() {
		addLogEntry("Dumping open SQL statements:", ["debug"]);
		auto p = sqlite3_next_stmt(pDb, null);
		while (p != null) {
			addLogEntry(" Still Open: " ~ to!string(ifromStringz(sqlite3_sql(p))), ["debug"]);
			p = sqlite3_next_stmt(pDb, p);
		}
	}
	
	// Close open statements
	void close_open_statements() {
		addLogEntry("Closing open SQL statements:", ["debug"]);
		auto p = sqlite3_next_stmt(pDb, null);
		while (p != null) {
			// The sqlite3_finalize() function is called to delete a prepared statement
			sqlite3_finalize(p);
			addLogEntry(" Finalised:  " ~ to!string(ifromStringz(sqlite3_sql(p))));
			p = sqlite3_next_stmt(pDb, p);
		}
	}
	
	// Count open statements
	int count_open_statements() {
		addLogEntry("Counting open SQL statements", ["debug"]);
		int openStatementCount = 0;
		auto p = sqlite3_next_stmt(pDb, null);
		while (p != null) {
			openStatementCount++;
			p = sqlite3_next_stmt(pDb, p);
		}
		return openStatementCount;
	}
	
	// Check DB Status
	void checkStatus() {
        int rc = sqlite3_errcode(pDb);
        if (rc != SQLITE_OK) {
            throw new SqliteException(rc, getErrorMessage());
        }
    }
	
	// Open the database file
	void open(const(char)[] filename) {
		// https://www.sqlite.org/c3ref/open.html
		int rc = sqlite3_open(toStringz(filename), &pDb);
		
		if (rc != SQLITE_OK) {
			string errorMsg;
			if (rc == SQLITE_CANTOPEN) {
				// Database cannot be opened
				errorMsg = "The database cannot be opened. Please check the permissions of " ~ to!string(filename);
			} else {
				// Some other error
				errorMsg = "A database access error occurred: " ~ getErrorMessage();
			}
			
			// Log why we could not open the database file
			addLogEntry();
			addLogEntry(errorMsg);
			addLogEntry();
			
			close();
			throw new SqliteException(rc, getErrorMessage());
		}
		
		// Opened database file OK
		// Flag to always use extended result codes for errors
		sqlite3_extended_result_codes(pDb, 1);
	}

	void exec(const(char)[] sql) {
		// https://www.sqlite.org/c3ref/exec.html
		if (pDb !is null) {
			int rc = sqlite3_exec(pDb, toStringz(sql), null, null, null);
			if (rc != SQLITE_OK) {
				// Get error message and print it, then exit
				string errorMessage = getErrorMessage();
				close();
				// Throw sqlite error
				throw new SqliteException(rc, errorMessage);
			}
		}
	}
	
	int getVersion() {
		int userVersion;
		extern (C) int callback(void* user_version, int count, char** column_text, char** column_name) {
			import core.stdc.stdlib: atoi;
			*(cast(int*) user_version) = atoi(*column_text);
			return 0;
		}
		int rc = sqlite3_exec(pDb, "PRAGMA user_version", &callback, &userVersion, null);
		if (rc != SQLITE_OK) {
			throw new SqliteException(rc, getErrorMessage());
		}
		return userVersion;
	}
	
	int getThreadsafeValue() {
		// Get the threadsafe value
		return sqlite3_threadsafe();
	}

	string getErrorMessage() {
		return ifromStringz(sqlite3_errmsg(pDb));
	}
	
	void setVersion(int userVersion) {
		exec("PRAGMA user_version=" ~ to!string(userVersion));
	}

	Statement prepare(const(char)[] zSql) {
		Statement s;
		// https://www.sqlite.org/c3ref/prepare.html
		if (pDb !is null) {
			int rc = sqlite3_prepare_v2(pDb, zSql.ptr, cast(int) zSql.length, &s.pStmt, null);
			if (rc != SQLITE_OK) {
				throw new SqliteException(rc, getErrorMessage());
			}
		}
		return s;
	}

	void close() {
		// https://www.sqlite.org/c3ref/close.html
		if (pDb !is null) {
			sqlite3_close_v2(pDb);
			pDb = null;
		}
	}
}

struct Statement {
	struct Result {
		private sqlite3_stmt* pStmt;
		private const(char)[][] row;

		private this(sqlite3_stmt* pStmt) {
			this.pStmt = pStmt;
			step(); // initialize the range
		}

		@property bool empty() {
			return row.length == 0;
		}

		@property auto front() {
			return row;
		}

		alias step popFront;

		void step() {
			// https://www.sqlite.org/c3ref/step.html
			int rc = sqlite3_step(pStmt);
			if (rc == SQLITE_BUSY) {
				// Database is locked by another onedrive process
				addLogEntry("The database is currently locked by another process - cannot sync");
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
				string errorMessage = getErrorMessage();
				// Must force exit here, allow logging to be done
				throw new SqliteException(rc, errorMessage);
			}
		}
		
		string getErrorMessage() {
			return ifromStringz(sqlite3_errmsg(sqlite3_db_handle(pStmt)));
		}	
	}

	private sqlite3_stmt* pStmt;

	~this() {
		// Finalise any prepared statement
		finalise();
	}
	
	// https://www.sqlite.org/c3ref/finalize.html
	void finalise() {
		if (pStmt !is null) {
			// The sqlite3_finalize() function is called to delete a prepared statement
			sqlite3_finalize(pStmt);
			pStmt = null;
		}
	}

	void bind(int index, const(char)[] value) {
		reset();
		// https://www.sqlite.org/c3ref/bind_blob.html
		int rc = sqlite3_bind_text(pStmt, index, value.ptr, cast(int) value.length, SQLITE_STATIC);
		if (rc != SQLITE_OK) {
			throw new SqliteException(rc, getErrorMessage());
		}
	}

	Result exec() {
		reset();
		return Result(pStmt);
	}
	
	private void reset() {
		// https://www.sqlite.org/c3ref/reset.html
		int rc = sqlite3_reset(pStmt);
		if (rc != SQLITE_OK) {
			throw new SqliteException(rc, getErrorMessage());
		}
	}
	
	string getErrorMessage() {
		return ifromStringz(sqlite3_errmsg(sqlite3_db_handle(pStmt)));
	}
}