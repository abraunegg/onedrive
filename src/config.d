import core.stdc.stdlib: EXIT_SUCCESS, EXIT_FAILURE, exit;
import std.file, std.string, std.regex, std.stdio, std.process, std.algorithm.searching, std.getopt, std.conv;
import std.algorithm.sorting: sort;
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
	// ARGGGG D is stupid and cannot make hashmap initializations!!!
	// private string[string] foobar = [ "aa": "bb" ] does NOT work!!!
	private string[string] stringValues;
	private bool[string] boolValues;
	private long[string] longValues;


	this(string configDirName)
	{
		// default configuration
		stringValues["single_directory"] = "";
		stringValues["sync_dir"]         = "~/OneDrive";
		stringValues["skip_file"]        = "~*";
		stringValues["log_dir"]          = "/var/log/onedrive/";
		stringValues["drive_id"]         = "";
		boolValues["upload_only"]        = false;
		boolValues["check_for_nomount"]  = false;
		boolValues["download_only"]      = false;
		boolValues["disable_notifications"] = false;
		boolValues["disable_upload_validation"] = false;
		boolValues["enable_logging"]     = false;
		boolValues["force_http_11"]      = false;
		boolValues["local_first"]        = false;
		boolValues["no_remote_delete"]   = false;
		boolValues["skip_symlinks"]      = false;
		boolValues["debug_https"]        = false;
		boolValues["skip_dotfiles"]        = false;
		longValues["verbose"]            = 0;
		longValues["monitor_interval"]   = 45,
		longValues["min_notif_changes"]  = 5;

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
		string configDirBase;
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


	void update_from_args(string[] args)
	{

		// Add additional options that are NOT configurable via config file
		stringValues["create_directory"]  = "";
		stringValues["destination_directory"] = "";
		stringValues["get_o365_drive_id"] = "";
		stringValues["remove_directory"]  = "";
		stringValues["single_directory"]  = "";
		stringValues["source_directory"]  = "";
		boolValues["display_config"]      = false;
		boolValues["display_sync_status"] = false;
		boolValues["resync"]              = false;
		boolValues["print_token"]         = false;
		boolValues["logout"]              = false;
		boolValues["monitor"]             = false;
		boolValues["synchronize"]         = false;


		// Application Startup option validation
		try {
			string tmpStr;
			bool tmpBol;
			auto opt = getopt(
				args,
				std.getopt.config.bundling,
				std.getopt.config.caseSensitive,
				"check-for-nomount", 
					"Check for the presence of .nosync in the syncdir root. If found, do not perform sync.", 
					&boolValues["check_for_nomount"],
				"create-directory",
					"Create a directory on OneDrive - no sync will be performed.",
					&stringValues["create_directory"],
				"debug-https", 
					"Debug OneDrive HTTPS communication.", 
					&boolValues["debug_https"],
				"destination-directory",
					"Destination directory for renamed or move on OneDrive - no sync will be performed.",
					&stringValues["destination_directory"],
				"disable-notifications",
					"Do not use desktop notifications in monitor mode.",
					&boolValues["disable_notifications"],
				"disable-upload-validation",
					"Disable upload validation when uploading to OneDrive",
					&boolValues["disable_upload_validation"],
				"display-config",
					"Display what options the client will use as currently configured - no sync will be performed.",
					&boolValues["display_config"],
				"display-sync-status",
					"Display the sync status of the client - no sync will be performed.",
					&boolValues["display_sync_status"],
				"download-only|d",
					"Only download remote changes",
					&boolValues["download_only"],
				"enable-logging",
					"Enable client activity to a separate log file",
					&boolValues["enable_logging"],
				"force-http-1.1",
					"Force the use of HTTP 1.1 for all operations",
					&boolValues["force_http_11"],
				"get-O365-drive-id",
					"Query and return the Office 365 Drive ID for a given Office 365 SharePoint Shared Library",
					&stringValues["get_o365_drive_id"],
				"local-first",
					"Synchronize from the local directory source first, before downloading changes from OneDrive.",
					&boolValues["local_first"],
				"logout",
					"Logout the current user",
					&boolValues["logout"],
				"monitor|m",
					"Keep monitoring for local and remote changes",
					&boolValues["monitor"],
				"no-remote-delete",
					"Do not delete local file 'deletes' from OneDrive when using --upload-only",
					&boolValues["no_remote_delete"],
				"print-token",
					"Print the access token, useful for debugging",
					&boolValues["print_token"],
				"resync",
					"Forget the last saved state, perform a full sync",
					&boolValues["resync"],
				"remove-directory",
					"Remove a directory on OneDrive - no sync will be performed.",
					&stringValues["remove_directory"],
				"skip-dot-files",
					"Skip dot files and folders from syncing",
					&boolValues["skip_dotfiles"],
				"single-directory",
					"Specify a single local directory within the OneDrive root to sync.",
					&stringValues["single_directory"],
				"skip-symlinks",
					"Skip syncing of symlinks",
					&boolValues["skip_symlinks"],
				"source-directory",
					"Source directory to rename or move on OneDrive - no sync will be performed.",
					&stringValues["source_directory"],
				"syncdir",
					"Specify the local directory used for synchronization to OneDrive",
					&stringValues["sync_dir"],
				"synchronize",
					"Perform a synchronization",
					&boolValues["synchronize"],
				"upload-only",
					"Only upload to OneDrive, do not sync changes from OneDrive locally",
					&boolValues["upload_only"],
				"verbose|v+",
					"Print more details, useful for debugging (repeat for extra debugging)",
					&longValues["verbose"],
				// duplicated from main.d to get full help output!
				"confdir",
					"Set the directory used to store the configuration files",
					&tmpStr,
				"version",
					"Print the version and exit",
					&tmpBol

			);
			if (opt.helpWanted) {
				outputLongHelp(opt.options);
				exit(EXIT_SUCCESS);
			}
		} catch (GetOptException e) {
			log.error(e.msg);
			log.error("Try 'onedrive -h' for more information");
			exit(EXIT_FAILURE);
		} catch (Exception e) {
			// error
			log.error(e.msg);
			log.error("Try 'onedrive -h' for more information");
			exit(EXIT_FAILURE);
		}
	}


	string getValueString(string key)
	{
		auto p = key in stringValues;
		if (p) {
			return *p;
		} else {
			throw new Exception("Missing config value: " ~ key);
		}
	}

	long getValueLong(string key)
	{
		auto p = key in longValues;
		if (p) {
			return *p;
		} else {
			throw new Exception("Missing config value: " ~ key);
		}
	}

	bool getValueBool(string key)
	{
		auto p = key in boolValues;
		if (p) {
			return *p;
		} else {
			throw new Exception("Missing config value: " ~ key);
		}
	}

	void setValueBool(string key, bool value)
	{
		boolValues[key] = value;
	}

	void setValueString(string key, string value)
	{
		stringValues[key] = value;
	}

	void setValueLong(string key, long value)
	{
		longValues[key] = value;
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
				auto p = key in boolValues;
				if (p) {
					c.popFront();
					// only accept "true" as true value. TODO Should we support other formats?
					setValueBool(key, c.front.dup == "true" ? true : false);
				} else {
					auto pp = key in stringValues;
					if (pp) {
						c.popFront();
						setValueString(key, c.front.dup);
					} else {
						auto ppp = key in longValues;
						if (ppp) {
							c.popFront();
							setValueLong(key, to!long(c.front.dup));
						} else {
							log.log("Unknown key in config file: ", key);
							return false;
						}
					}
				}
			} else {
				log.log("Malformed config line: ", line);
				return false;
			}
		}
		return true;
	}
}


void outputLongHelp(Option[] opt)
{
	auto argsNeedingOptions = [
		"--confdir",
		"--create-directory",
		"--destination-directory",
		"--get-O365-drive-id",
		"--remove-directory",
		"--single-directory",
		"--source-directory",
		"--syncdir" ];
	writeln(`OneDrive - a client for OneDrive Cloud Services

Usage:
  onedrive [options] --synchronize
      Do a one time synchronization
  onedrive [options] --monitor
      Monitor filesystem and sync regularly
  onedrive [options] --display-config
      Display the currently used configuration
  onedrive [options] --display-sync-status
      Query OneDrive service and report on pending changes
  onedrive -h | --help
      Show this help screen
  onedrive --version
      Show version

Options:
`);
	foreach (it; opt.sort!("a.optLong < b.optLong")) {
		if (it.optLong == "--help") continue;
		writefln("  %s%s%s%s\n      %s",
				it.optLong,
				it.optShort == "" ? "" : " " ~ it.optShort,
				argsNeedingOptions.canFind(it.optLong) ? " ARG" : "",
				it.required ? " (required)" : "", it.help);
	}
	// write help last
	writefln("  --help -h\n      This help information.");
}

unittest
{
	auto cfg = new Config("");
	cfg.load("config");
	assert(cfg.getValueString("sync_dir") == "~/OneDrive");
}

