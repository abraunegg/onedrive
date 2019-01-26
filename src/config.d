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
	private string[string] values;

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

	bool init()
	{
		// Default configuration directory
		setValue("sync_dir", "~/OneDrive");
		// Configure to skip ONLY temp files (~*.doc etc) by default
		// Prior configuration was: .*|~*
		setValue("skip_file", "~*");
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

	bool updateConfigFromCmdLine(string[] args) {

	auto cfg2settingBool = [
		"upload_only": &uploadOnly,
		"check_for_nomount": &checkMount,
		"download_only": &downloadOnly,
		"disable_notifications": &disableNotifications,
		"disable_upload_validation": &disableUploadValidation,
		"enable_logging": &enableLogFile,
		"force_http_11": &forceHTTP11,
		"local_first": &localFirst,
		"no_remote_delete": &noRemoteDelete,
		"skip_symlinks": &skipSymlinks,
		"verbose": &verbose
			];
	auto cfg2settingString = [
		"single_directory": &singleDirectory,
		"syncdir": &syncDirName
			];

		void boolHandler(string option) {
			switch (option) {
				case "upload_only":
				case "check_for_nomount":
				case "download_only":
				case "disable_notifications":
				case "disable_upload_validation":
				case "enable_logging":
				case "force_http_11":
				case "local_first":
				case "no_remote_delete":
				case "skip_symlinks":
				case "verbose":
					setValue(option, "true");




				case "quiet": verbosityLevel = 0; break;
				case "verbose": verbosityLevel = 2; break;
				case "shouting": verbosityLevel = verbosityLevel.max; break;
				default:
					stderr.writeln("Unknown verbosity level ", value);
					handlerFailed = true;
					break;
			}
		}


		// Application Option Variables
		// Add a check mounts option to resolve https://github.com/abraunegg/onedrive/issues/8
		bool checkMount = false;
		// Create a single root directory on OneDrive
		string createDirectory;
		// The destination directory if we are using the OneDrive client to rename a directory
		string destinationDirectory;
		// Debug the HTTPS submit operations if required
		bool debugHttp = false;
		// Do not use notifications in monitor mode
		bool disableNotifications = false;
		// Display application configuration but do not sync
		bool displayConfiguration = false;
		// Display sync status
		bool displaySyncStatus = false;
		// only download remote changes
		bool downloadOnly = false;
		// Does the user want to disable upload validation - https://github.com/abraunegg/onedrive/issues/205
		// SharePoint will associate some metadata from the library the file is uploaded to directly in the file - thus change file size & checksums
		bool disableUploadValidation = false;
		// Do we enable a log file
		bool enableLogFile = false;
		// Force the use of HTTP 1.1 to overcome curl => 7.62.0 where some operations are now sent via HTTP/2
		// Whilst HTTP/2 operations are handled, in some cases the handling of this outside of the client is not being done correctly (router, other) thus the client breaks
		// This flag then allows the user to downgrade all HTTP operations to HTTP 1.1 for maximum network path compatibility
		bool forceHTTP11 = false;
		// SharePoint / Office 365 Shared Library name to query
		string o365SharedLibraryName;
		// Local sync - Upload local changes first before downloading changes from OneDrive
		bool localFirst = false;
		// remove the current user and sync state
		bool logout = false;
		// enable monitor mode
		bool monitor = false;
		// Add option for no remote delete
		bool noRemoteDelete = false;
		// print the access token
		bool printAccessToken = false;
		// force a full resync
		bool resync = false;
		// Remove a single directory on OneDrive
		string removeDirectory;
		// This allows for selective directory syncing instead of everything under ~/OneDrive/
		string singleDirectory;
		// Add option to skip symlinks
		bool skipSymlinks = false;
		// The source directory if we are using the OneDrive client to rename a directory
		string sourceDirectory;
		// override the sync directory
		string syncDirName;
		// Configure a flag to perform a sync
		// This is beneficial so that if just running the client itself - without any options, or sync check, the client does not perform a sync
		bool synchronize = false;
		// Upload Only
		bool uploadOnly = false;
		// enable verbose logging
		bool verbose = false;
	


	//
	// IDEA TODO TODO
	// first run of getopt that leaves options (passThrough etc) only for the conffile
	// then load config files
	// then second getopt run with all other options overwriting config files options

	// Application Startup option validation
	try {
		auto opt = getopt(
			args,
			std.getopt.config.bundling,
			std.getopt.config.caseSensitive,
			"check-for-nomount", "Check for the presence of .nosync in the syncdir root. If found, do not perform sync.", &checkMount,
			"confdir", "Set the directory used to store the configuration files", &configDirName,
			"create-directory", "Create a directory on OneDrive - no sync will be performed.", &createDirectory,
			"destination-directory", "Destination directory for renamed or move on OneDrive - no sync will be performed.", &destinationDirectory,
			"debug-https", "Debug OneDrive HTTPS communication.", &debugHttp,
			"disable-notifications", "Do not use desktop notifications in monitor mode.", &disableNotifications,
			"display-config", "Display what options the client will use as currently configured - no sync will be performed.", &displayConfiguration,
			"display-sync-status", "Display the sync status of the client - no sync will be performed.", &displaySyncStatus,
			"download-only|d", "Only download remote changes", &downloadOnly,
			"disable-upload-validation", "Disable upload validation when uploading to OneDrive", &disableUploadValidation,
			"enable-logging", "Enable client activity to a separate log file", &enableLogFile,
			"force-http-1.1", "Force the use of HTTP 1.1 for all operations", &forceHTTP11,
			"get-O365-drive-id", "Query and return the Office 365 Drive ID for a given Office 365 SharePoint Shared Library", &o365SharedLibraryName,
			"local-first", "Synchronize from the local directory source first, before downloading changes from OneDrive.", &localFirst,
			"logout", "Logout the current user", &logout,
			"monitor|m", "Keep monitoring for local and remote changes", &monitor,
			"no-remote-delete", "Do not delete local file 'deletes' from OneDrive when using --upload-only", &noRemoteDelete,
			"print-token", "Print the access token, useful for debugging", &printAccessToken,
			"resync", "Forget the last saved state, perform a full sync", &resync,
			"remove-directory", "Remove a directory on OneDrive - no sync will be performed.", &removeDirectory,
			"single-directory", "Specify a single local directory within the OneDrive root to sync.", &singleDirectory,
			"skip-symlinks", "Skip syncing of symlinks", &skipSymlinks,
			"source-directory", "Source directory to rename or move on OneDrive - no sync will be performed.", &sourceDirectory,
			"syncdir", "Specify the local directory used for synchronization to OneDrive", &syncDirName,
			"synchronize", "Perform a synchronization", &synchronize,
			"upload-only", "Only upload to OneDrive, do not sync changes from OneDrive locally", &uploadOnly,
			"verbose|v+", "Print more details, useful for debugging (repeat for extra debugging)", &log.verbose,
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

	// Main function variables
	string homePath = "";
	string configDirBase = "";
	// Debug the HTTPS response operations if required
	bool debugHttpSubmit;
	// Are we able to reach the OneDrive Service
	bool online = false;
	
	auto cfg = new config.Config(configDirName);
	if(!cfg.init()){
		// There was an error loading the configuration
		// Error message already printed
		return EXIT_FAILURE;
	}

	config.updateConfigFromCmdLine(args);

	
	foreach (cfgKey, p; cfg2settingBool) {
		if (*p) {
			// the user passed in an alternate setting via cmd line
			log.vdebug("CLI override to set", cfgKey, "to true");
			cfg.setValue(cfgKey, "true");
		}
	}
	foreach (cfgKey, p; cfg2settingString) {
		if (*p) {
			// the user passed in an alternate setting via cmd line
			log.vdebug("CLI override to set", cfgKey, "to", *p);
			cfg.setValue(cfgKey, *p);
		}
	}

	// command line parameters to override default 'config' & take precedence
	// Set the client to skip symbolic links if --skip-symlinks was passed in
	if (skipSymlinks) {
		// The user passed in an alternate skip_symlinks as to what was either in 'config' file or application default
		log.vdebug("CLI override to set skip_symlinks to: true");
		cfg.setValue("skip_symlinks", "true");
	}
	
	// Set the OneDrive Local Sync Directory if was passed in via --syncdir
	if (syncDirName) {
		// The user passed in an alternate sync_dir as to what was either in 'config' file or application default
		// Do not expandTilde here as we do not know if we reliably can
		log.vdebug("CLI override to set sync_dir to: ", syncDirName);
		cfg.setValue("sync_dir", syncDirName);
	}
	
	// sync_dir environment handling to handle ~ expansion properly
	string syncDir;
	if ((environment.get("SHELL") == "") && (environment.get("USER") == "")){
		log.vdebug("sync_dir: No SHELL or USER environment variable configuration detected");
		// No shell or user set, so expandTilde() will fail - usually headless system running under init.d / systemd or potentially Docker
		// Does the 'currently configured' sync_dir include a ~
		if (canFind(cfg.getValue("sync_dir"),"~")) {
			// A ~ was found
			log.vdebug("sync_dir: A '~' was found in sync_dir, using the calculated 'homePath' to replace '~'");
			syncDir = homePath ~ strip(cfg.getValue("sync_dir"),"~","~");
		} else {
			// No ~ found in sync_dir, use as is
			log.vdebug("sync_dir: Getting syncDir from config value sync_dir");
			syncDir = cfg.getValue("sync_dir");
		}
	} else {
		// A shell and user is set, expand any ~ as this will be expanded correctly if present
		log.vdebug("sync_dir: Getting syncDir from config value sync_dir");
		if (canFind(cfg.getValue("sync_dir"),"~")) {
			log.vdebug("sync_dir: A '~' was found in configured sync_dir, automatically expanding as SHELL and USER environment variable is set");
			syncDir = expandTilde(cfg.getValue("sync_dir"));
		} else {
			syncDir = cfg.getValue("sync_dir");
		}
	}
	
	// vdebug syncDir as set and calculated
	log.vdebug("syncDir: ", syncDir);

















	}


}

unittest
{
	auto cfg = new Config("");
	cfg.load("config");
	assert(cfg.getValue("sync_dir") == "~/OneDrive");
	assert(cfg.getValue("empty", "default") == "default");
}
