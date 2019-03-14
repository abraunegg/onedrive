import std.file, std.string, std.regex, std.stdio;
import selective;
static import log;

final class Config
{
	public string refreshTokenFilePath;
	public string deltaLinkFilePath;
	public string databaseFilePath;
	public string databaseFilePathDryRun;
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
		databaseFilePathDryRun = configDirName ~ "/items-dryrun.sqlite3";
		uploadStateFilePath = configDirName ~ "/resume_upload";
		userConfigFilePath = configDirName ~ "/config";
		syncListFilePath = configDirName ~ "/sync_list";
	}

	bool init()
	{
		// Default configuration directory
		setValue("sync_dir", "~/OneDrive");
		// Skip Directories - no directories are skipped by default
		setValue("skip_dir", "");
		// Configure to skip ONLY temp files (~*.doc etc) by default
		// Prior configuration was: .*|~*
		setValue("skip_file", "~*");
		// By default skip dot files & folders are not skipped 
		setValue("skip_dotfiles", "false");
		// By default symlinks are not skipped (using string type
		// instead of boolean because hashmap only stores string types)
		setValue("skip_symlinks", "false");
		// Configure the monitor mode loop - the number of seconds by which
		// each sync operation is undertaken when idle under monitor mode
		setValue("monitor_interval", "45");
		// Configure the default logging directory to be /var/log/onedrive/
		setValue("log_dir", "/var/log/onedrive/");
		// Configure a default empty value for drive_id
		setValue("drive_id", "");
		// Minimal changes that trigger a log and notification on sync
		setValue("min_notif_changes", "5");
		// Frequency of log messages in monitor, ie after n sync runs ship out a log message
		setValue("monitor_log_frequency", "5");
		// Check if we should ignore a directory if a special file (.nosync) is present
		setValue("check_nosync", "false");
		
		if (!load(userConfigFilePath)) {
			// What was the reason for failure?
			if (!exists(userConfigFilePath)) {
				log.vlog("No config file found, using application defaults");
				return true;
			} else {
				log.log("Configuration file has errors - please check your configuration");
				return false;
			}
		}
		return true;
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
				auto p = key in values;
				if (p) {
					c.popFront();
					setValue(key, c.front.dup);
				} else {
					log.log("Unknown key in config file: ", key);
					return false;
				}
			} else {
				log.log("Malformed config line: ", line);
				return false;
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
