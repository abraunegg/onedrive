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
	public string homePath;

	private string userConfigFilePath;
	// hashmap for the values found in the user config file
	private string[string] values = [
		"upload_only": 			"false",
		"check_for_nomount":		"false",
		"download_only":		"false",
		"disable_notifications":	"false",
		"disable_upload_validation":	"false",
		"enable_logging":		"false",
		"force_http_11":		"false",
		"local_first":			"false",
		"no_remote_delete":		"false",
		"skip_symlinks":		"false",
		"debug_https":			"false",
		"verbose": 			"0",
		"monitor_interval" :		"45",
		"min_notif_changes":		"5",
		"single_directory":		"",
		"sync_dir": 			"~/OneDrive",
		"skip_file": 			"~*",
		"log_dir": 			"/var/log/onedrive/",
		"drive_id": 			""
	]:


	this(string configDirName)
	{
		// Determine the users home directory. 
		// Need to avoid using ~ here as expandTilde() below does not interpret correctly when running under init.d or systemd scripts
		// Check for HOME environment variable
		if (environment.get("HOME") != ""){
			// Use HOME environment variable
			log.vdebug("homePath: HOME environment variable set");
			homePath = environment.get("HOME");
		} else {
			if ((environment.get("SHELL") == "") && (environment.get("USER") == "")){
				// No shell is set or username - observed case when running as systemd service under CentOS 7.x
				log.vdebug("homePath: WARNING - no HOME environment variable set");
				log.vdebug("homePath: WARNING - no SHELL environment variable set");
				log.vdebug("homePath: WARNING - no USER environment variable set");
				homePath = "/root";
			} else {
				// A shell & valid user is set, but no HOME is set, use ~ which can be expanded
				log.vdebug("homePath: WARNING - no HOME environment variable set");
				homePath = "~";
			}
		}
	
		// Output homePath calculation
		log.vdebug("homePath: ", homePath);

	
		// Determine the correct configuration directory to use
		if (configDirName != "") {
			// A CLI 'confdir' was passed in
			log.vdebug("configDirName: CLI override to set configDirName to: ", configDirName);
			if (canFind(configDirName,"~")) {
				// A ~ was found
				log.vdebug("configDirName: A '~' was found in configDirName, using the calculated 'homePath' to replace '~'");
				configDirName = homePath ~ strip(configDirName,"~","~");
			}
		} else {
			// Determine the base directory relative to which user specific configuration files should be stored.
			if (environment.get("XDG_CONFIG_HOME") != ""){
				log.vdebug("configDirBase: XDG_CONFIG_HOME environment variable set");
				configDirBase = environment.get("XDG_CONFIG_HOME");
			} else {
				// XDG_CONFIG_HOME does not exist on systems where X11 is not present - ie - headless systems / servers
				log.vdebug("configDirBase: WARNING - no XDG_CONFIG_HOME environment variable set");
				configDirBase = homePath ~ "/.config";
			}
	
			// Output configDirBase calculation
			log.vdebug("configDirBase: ", configDirBase);
			// Set the default application configuration directory
			log.vdebug("configDirName: Configuring application to use default config path");
			// configDirBase contains the correct path so we do not need to check for presence of '~'
			configDirName = configDirBase ~ "/onedrive";
		}
	

		log.vlog("Using Config Dir: ", configDirName);
		if (!exists(configDirName)) mkdirRecurse(configDirName);

		refreshTokenFilePath = configDirName ~ "/refresh_token";
		deltaLinkFilePath = configDirName ~ "/delta_link";
		databaseFilePath = configDirName ~ "/items.sqlite3";
		uploadStateFilePath = configDirName ~ "/resume_upload";
		userConfigFilePath = configDirName ~ "/config";
		syncListFilePath = configDirName ~ "/sync_list";
	}

	bool initialize()
	{
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


	bool update_from_args(string[] args)
	{
		// Debug the HTTPS submit operations if required
		bool debugHttp = cfg.getValue("debug_https") == "false" ? false : true;
		// Do not use notifications in monitor mode
		bool disableNotifications = cfg.getValue("disable_notifications") == "false" ? false : true;
		// only download remote changes
		bool downloadOnly = cfg.getValue("download_only") == "false" ? false : true;
		// Does the user want to disable upload validation - https://github.com/abraunegg/onedrive/issues/205
		// SharePoint will associate some metadata from the library the file is uploaded to directly in the file - thus change file size & checksums
		bool disableUploadValidation = cfg.getValue("disable_upload_validation") == "false" ? false : true;
		// Do we enable a log file
		bool enableLogFile = cfg.getValue("enable_logging") == "false" ? false : true;
		// Force the use of HTTP 1.1 to overcome curl => 7.62.0 where some operations are now sent via HTTP/2
		// Whilst HTTP/2 operations are handled, in some cases the handling of this outside of the client is not being done correctly (router, other) thus the client breaks
		// This flag then allows the user to downgrade all HTTP operations to HTTP 1.1 for maximum network path compatibility
		bool forceHTTP11 = cfg.getValue("force_http_11") == "false" ? false : true;
		// Local sync - Upload local changes first before downloading changes from OneDrive
		bool localFirst = cfg.getValue("local_first") == "false" ? false : true;
		// Add option for no remote delete
		bool noRemoteDelete = cfg.getValue("no_remote_delete") == "false" ? false : true;
		// Add option to skip symlinks
		bool skipSymlinks = cfg.getValue("skip_symlinks") == "false" ? false : true;
		// override the sync directory
		string syncDirName = cfg.getValue("sync_dir");
		// Upload Only
		bool uploadOnly = cfg.getValue("upload_only") == "false" ? false : true;
	

		// Application Startup option validation
		try {
			auto opt = getopt(
				args,
				std.getopt.config.bundling,
				std.getopt.config.caseSensitive,
				"check-for-nomount", "Check for the presence of .nosync in the syncdir root. If found, do not perform sync.", &checkMount,
			"debug-https", "Debug OneDrive HTTPS communication.", &debugHttp,
			"disable-notifications", "Do not use desktop notifications in monitor mode.", &disableNotifications,
			"download-only|d", "Only download remote changes", &downloadOnly,
			"disable-upload-validation", "Disable upload validation when uploading to OneDrive", &disableUploadValidation,
			"enable-logging", "Enable client activity to a separate log file", &enableLogFile,
			"force-http-1.1", "Force the use of HTTP 1.1 for all operations", &forceHTTP11,
			"local-first", "Synchronize from the local directory source first, before downloading changes from OneDrive.", &localFirst,
			"no-remote-delete", "Do not delete local file 'deletes' from OneDrive when using --upload-only", &noRemoteDelete,
			"skip-symlinks", "Skip syncing of symlinks", &skipSymlinks,
			"syncdir", "Specify the local directory used for synchronization to OneDrive", &syncDirName,
			"upload-only", "Only upload to OneDrive, do not sync changes from OneDrive locally", &uploadOnly,
		);
		if (opt.helpWanted) {
			outputLongHelp(opt.options);
			return EXIT_SUCCESS;
		}
	} catch (GetOptException e) {
		log.error(e.msg);
		log.error("Try 'onedrive -h' for more information");
		return EXIT_FAILURE;
	} catch (Exception e) {
		// error
		log.error(e.msg);
		log.error("Try 'onedrive -h' for more information");
		return EXIT_FAILURE;
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
				auto p = key in values;
				if (p) {
					c.popFront();
					// TODO add check for correct format (numbers, booleans)
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
