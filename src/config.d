import std.file, std.string, std.regex, std.stdio;
import selective;
static import log;

final class Config
{
	public string refreshTokenFilePath;
	public string deltaLinkFilePath;
	public string databaseFilePath;
	public string uploadStateFilePath;
	public string syncListFilePath;

	private string userConfigFilePath;
	// hashmap for the values found in the user config file
	private string[string] values;

	this(string configDirName)
	{
		refreshTokenFilePath = configDirName ~ "/refresh_token";
		deltaLinkFilePath = configDirName ~ "/delta_link";
		databaseFilePath = configDirName ~ "/items.sqlite3";
		uploadStateFilePath = configDirName ~ "/resume_upload";
		userConfigFilePath = configDirName ~ "/config";
		syncListFilePath = configDirName ~ "/sync_list";
	}

	void init()
	{
		setValue("sync_dir", "~/OneDrive");
		setValue("skip_file", ".*|~*");
		if (!load(userConfigFilePath)) {
			log.vlog("No config file found, using defaults");
		}
	}

	string getValue(string key)
	{
		auto p = key in values;
		if (p) {
			return *p;
		} else {
			throw new Exception("Missing config value: " ~ key);
		}
	}

	string getValue(string key, string value)
	{
		auto p = key in values;
		if (p) {
			return *p;
		} else {
			return value;
		}
	}

	void setValue(string key, string value)
	{
		values[key] = value;
	}

	private bool load(string filename)
	{
		scope(failure) return false;
		auto file = File(filename, "r");
		auto r = regex(`^(\w+)\s*=\s*"(.*)"\s*$`);
		foreach (line; file.byLine()) {
			line = stripLeft(line);
			if (line.length == 0 || line[0] == ';' || line[0] == '#') continue;
			auto c = line.matchFirst(r);
			if (!c.empty) {
				c.popFront(); // skip the whole match
				string key = c.front.dup;
				c.popFront();
				values[key] = c.front.dup;
			} else {
				log.log("Malformed config line: ", line);
			}
		}
		return true;
	}
}

unittest
{
	auto cfg = new Config("");
	cfg.load("config");
	assert(cfg.getValue("sync_dir") == "~/OneDrive");
	assert(cfg.getValue("empty", "default") == "default");
}
