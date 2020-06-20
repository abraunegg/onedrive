import core.stdc.stdlib: EXIT_SUCCESS, EXIT_FAILURE, exit;
import std.file, std.string, std.regex, std.stdio, std.process, std.algorithm.searching, std.getopt, std.conv, std.path;
import std.algorithm.sorting: sort;
import selective;
static import log;

final class Config
{
	// application defaults
	public string defaultSyncDir = "~/OneDrive";
	public string defaultSkipFile = "~*|.~*|*.tmp";
	public string defaultSkipDir = "";
	// application set items
	public string refreshTokenFilePath = "";
	public string deltaLinkFilePath = "";
	public string databaseFilePath = "";
	public string databaseFilePathDryRun = "";
	public string uploadStateFilePath = "";
	public string syncListFilePath = "";
	public string homePath = "";
	public string configDirName = "";
	public string systemConfigDirName = "";
	public string configFileSyncDir = "";
	public string configFileSkipFile = "";
	public string configFileSkipDir = "";
	public string businessSharedFolderFilePath = "";
	private string userConfigFilePath = "";
	private string systemConfigFilePath = "";
	// was the application just authorised - paste of response uri
	public bool applicationAuthorizeResponseUri = false;
	// hashmap for the values found in the user config file
	// ARGGGG D is stupid and cannot make hashmap initializations!!!
	// private string[string] foobar = [ "aa": "bb" ] does NOT work!!!
	private string[string] stringValues;
	private bool[string] boolValues;
	private long[string] longValues;
	// Compile time regex - this does not change
	public auto configRegex = ctRegex!(`^(\w+)\s*=\s*"(.*)"\s*$`);
	
	this(string confdirOption)
	{
		// default configuration - entries in config file ~/.config/onedrive/config
		// an entry here means it can be set via the config file if there is a coresponding read and set in update_from_args()
		stringValues["sync_dir"] = defaultSyncDir;
		stringValues["skip_file"] = defaultSkipFile;
		stringValues["skip_dir"] = defaultSkipDir;
		stringValues["log_dir"] = "/var/log/onedrive/";
		stringValues["drive_id"] = "";
		stringValues["user_agent"] = "";
		boolValues["upload_only"] = false;
		boolValues["check_nomount"] = false;
		boolValues["check_nosync"] = false;
		boolValues["download_only"] = false;
		boolValues["disable_notifications"] = false;
		boolValues["disable_upload_validation"] = false;
		boolValues["enable_logging"] = false;
		boolValues["force_http_11"] = false;
		boolValues["force_http_2"] = false;
		boolValues["local_first"] = false;
		boolValues["no_remote_delete"] = false;
		boolValues["skip_symlinks"] = false;
		boolValues["debug_https"] = false;
		boolValues["skip_dotfiles"] = false;
		boolValues["dry_run"] = false;
		boolValues["sync_root_files"] = false;
		longValues["verbose"] = log.verbose; // might be initialized by the first getopt call!
		// The amount of time (seconds) between monitor sync loops
		longValues["monitor_interval"] = 300;
		longValues["skip_size"] = 0;
		longValues["min_notify_changes"] = 5;
		longValues["monitor_log_frequency"] = 5;
		// Number of n sync runs before performing a full local scan of sync_dir
		// By default 10 which means every ~7.5 minutes a full disk scan of sync_dir will occur
		longValues["monitor_fullscan_frequency"] = 10;
		// Number of children in a path that is locally removed which will be classified as a 'big data delete'
		longValues["classify_as_big_delete"] = 1000;
		// Delete source after successful transfer
		boolValues["remove_source_files"] = false;
		// Strict matching for skip_dir
		boolValues["skip_dir_strict_match"] = false;
		// Allow for a custom Client ID / Application ID to be used to replace the inbuilt default
		// This is a config file option ONLY
		stringValues["application_id"] = "";
		// allow for resync to be set via config file
		boolValues["resync"] = false;
		// Ignore data safety checks and overwrite local data rather than preserve & rename
		// This is a config file option ONLY
		boolValues["bypass_data_preservation"] = false;
		// Support National Azure AD endpoints as per https://docs.microsoft.com/en-us/graph/deployments
		// By default, if empty, use standard Azure AD URL's
		// Will support the following options:
		// - USL4
		//     AD Endpoint:    https://login.microsoftonline.us
		//     Graph Endpoint: https://graph.microsoft.us
		// - USL5
		//     AD Endpoint:    https://login.microsoftonline.us
		//     Graph Endpoint: https://dod-graph.microsoft.us
		// - DE
		//     AD Endpoint:    https://portal.microsoftazure.de
		//     Graph Endpoint: 	https://graph.microsoft.de
		// - CN
		//     AD Endpoint:    https://login.chinacloudapi.cn
		//     Graph Endpoint: 	https://microsoftgraph.chinacloudapi.cn
		stringValues["azure_ad_endpoint"] = "";
		// Allow enable / disable of the syncing of OneDrive Business Shared Folders via configuration file
		boolValues["sync_business_shared_folders"] = false;
		
		// DEVELOPER OPTIONS 
		// display_memory = true | false
		//  - It may be desirable to display the memory usage of the application to assist with diagnosing memory issues with the application
		//  - This is especially beneficial when debugging or performing memory tests with Valgrind
		boolValues["display_memory"] = false;
		// monitor_max_loop = long value
		//  - It may be desirable to, when running in monitor mode, force monitor mode to 'quit' after X number of loops
		//  - This is especially beneficial when debugging or performing memory tests with Valgrind
		longValues["monitor_max_loop"] = 0;
		// display_sync_options = true | false
		// - It may be desirable to see what options are being passed in to performSync() without enabling the full verbose debug logging
		boolValues["display_sync_options"] = false;

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
		string systemConfigDirBase;
		if (confdirOption != "") {
			// A CLI 'confdir' was passed in
			log.vdebug("configDirName: CLI override to set configDirName to: ", confdirOption);
			if (canFind(confdirOption,"~")) {
				// A ~ was found
				log.vdebug("configDirName: A '~' was found in configDirName, using the calculated 'homePath' to replace '~'");
				configDirName = homePath ~ strip(confdirOption,"~","~");
			} else {
				configDirName = confdirOption;
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
				// Also set up a path to pre-shipped shared configs (which can be overridden by supplying a config file in userspace)
				systemConfigDirBase = "/etc";
			}
	
			// Output configDirBase calculation
			log.vdebug("configDirBase: ", configDirBase);
			// Set the default application configuration directory
			log.vdebug("configDirName: Configuring application to use default config path");
			// configDirBase contains the correct path so we do not need to check for presence of '~'
			configDirName = configDirBase ~ "/onedrive";
			// systemConfigDirBase contains the correct path so we do not need to check for presence of '~'
			systemConfigDirName = systemConfigDirBase ~ "/onedrive";
		}
		
		// Config directory options all determined
		if (!exists(configDirName)) mkdirRecurse(configDirName);
		// configDirName has a trailing /
		log.vlog("Using 'user' Config Dir: ", configDirName);
		log.vlog("Using 'system' Config Dir: ", systemConfigDirName);
		
		// Update application set variables based on configDirName
		refreshTokenFilePath = buildNormalizedPath(configDirName ~ "/refresh_token");
		deltaLinkFilePath = buildNormalizedPath(configDirName ~ "/delta_link");
		databaseFilePath = buildNormalizedPath(configDirName ~ "/items.sqlite3");
		databaseFilePathDryRun = buildNormalizedPath(configDirName ~ "/items-dryrun.sqlite3");
		uploadStateFilePath = buildNormalizedPath(configDirName ~ "/resume_upload");
		userConfigFilePath = buildNormalizedPath(configDirName ~ "/config");
		syncListFilePath = buildNormalizedPath(configDirName ~ "/sync_list");
		systemConfigFilePath = buildNormalizedPath(systemConfigDirName ~ "/config");
		businessSharedFolderFilePath = buildNormalizedPath(configDirName ~ "/business_shared_folders");
		
		// Debug Output for application set variables based on configDirName
		log.vdebug("refreshTokenFilePath = ", refreshTokenFilePath);
		log.vdebug("deltaLinkFilePath = ", deltaLinkFilePath);
		log.vdebug("databaseFilePath = ", databaseFilePath);
		log.vdebug("databaseFilePathDryRun = ", databaseFilePathDryRun);
		log.vdebug("uploadStateFilePath = ", uploadStateFilePath);
		log.vdebug("userConfigFilePath = ", userConfigFilePath);
		log.vdebug("syncListFilePath = ", syncListFilePath);
		log.vdebug("systemConfigFilePath = ", systemConfigFilePath);
		log.vdebug("businessSharedFolderFilePath = ", businessSharedFolderFilePath);
	}

	bool initialize()
	{
		// Initialise the application
		if (!exists(userConfigFilePath)) {
			// 'user' configuration file does not exist
			// Is there a system configuration file?
			if (!exists(systemConfigFilePath)) {
				// 'system' configuration file does not exist
				log.vlog("No user or system config file found, using application defaults");
				return true;
			} else {
				// 'system' configuration file exists
				// can we load the configuration file without error?
				if (load(systemConfigFilePath)) {
					// configuration file loaded without error
					log.log("System configuration file successfully loaded");
					return true;
				} else {
					// there was a problem loading the configuration file
					log.log("System configuration file has errors - please check your configuration");
					return false;
				}
			}
		} else {
			// 'user' configuration file exists
			// can we load the configuration file without error?
			if (load(userConfigFilePath)) {
				// configuration file loaded without error
				log.log("Configuration file successfully loaded");
				return true;
			} else {
				// there was a problem loading the configuration file
				log.log("Configuration file has errors - please check your configuration");
				return false;
			}
		}
	}

	void update_from_args(string[] args)
	{
		// Add additional options that are NOT configurable via config file
		stringValues["create_directory"]  = "";
		stringValues["destination_directory"] = "";
		stringValues["get_file_link"]     = "";
		stringValues["get_o365_drive_id"] = "";
		stringValues["remove_directory"]  = "";
		stringValues["single_directory"]  = "";
		stringValues["source_directory"]  = "";
		stringValues["auth_files"]        = "";
		boolValues["display_config"]      = false;
		boolValues["display_sync_status"] = false;
		boolValues["print_token"]         = false;
		boolValues["logout"]              = false;
		boolValues["monitor"]             = false;
		boolValues["synchronize"]         = false;
		boolValues["force"]               = false;
		boolValues["remove_source_files"] = false;
		boolValues["skip_dir_strict_match"] = false;
		boolValues["list_business_shared_folders"] = false;
		
		// Application Startup option validation
		try {
			string tmpStr;
			bool tmpBol;
			long tmpVerb;
			// duplicated from main.d to get full help output!
			auto opt = getopt(
				
				args,
				std.getopt.config.bundling,
				std.getopt.config.caseSensitive,
				"auth-files",
					"Perform authentication not via interactive dialog but via files read/writes to these files.",
					&stringValues["auth_files"],
				"check-for-nomount",
					"Check for the presence of .nosync in the syncdir root. If found, do not perform sync.", 
					&boolValues["check_nomount"],
				"check-for-nosync",
					"Check for the presence of .nosync in each directory. If found, skip directory from sync.",
					&boolValues["check_nosync"],
				"classify-as-big-delete",
					"Number of children in a path that is locally removed which will be classified as a 'big data delete'",
					&longValues["classify_as_big_delete"],
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
				"download-only",
					"Replicate the OneDrive online state locally, by only downloading changes from OneDrive. Do not upload local changes to OneDrive.",
					&boolValues["download_only"],
				"dry-run",
					"Perform a trial sync with no changes made",
					&boolValues["dry_run"],
				"enable-logging",
					"Enable client activity to a separate log file",
					&boolValues["enable_logging"],
				"force-http-1.1",
					"Force the use of HTTP/1.1 for all operations (DEPRECIATED)",
					&boolValues["force_http_11"],
				"force-http-2",
					"Force the use of HTTP/2 for all operations where applicable",
					&boolValues["force_http_2"],
				"force",
					"Force the deletion of data when a 'big delete' is detected",
					&boolValues["force"],
				"get-file-link",
					"Display the file link of a synced file",
					&stringValues["get_file_link"],
				"get-O365-drive-id",
					"Query and return the Office 365 Drive ID for a given Office 365 SharePoint Shared Library",
					&stringValues["get_o365_drive_id"],
				"local-first",
					"Synchronize from the local directory source first, before downloading changes from OneDrive.",
					&boolValues["local_first"],
				"log-dir",
					"Directory where logging output is saved to, needs to end with a slash.",
					&stringValues["log_dir"],
				"logout",
					"Logout the current user",
					&boolValues["logout"],
				"min-notify-changes",
					"Minimum number of pending incoming changes necessary to trigger a desktop notification",
					&longValues["min_notify_changes"],
				"monitor|m",
					"Keep monitoring for local and remote changes",
					&boolValues["monitor"],
				"monitor-interval",
					"Number of seconds by which each sync operation is undertaken when idle under monitor mode.",
					&longValues["monitor_interval"],
				"monitor-fullscan-frequency",
					"Number of sync runs before performing a full local scan of the synced directory",
					&longValues["monitor_fullscan_frequency"],
				"monitor-log-frequency",
					"Frequency of logging in monitor mode",
					&longValues["monitor_log_frequency"],
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
				"remove-source-files",
					"Remove source file after successful transfer to OneDrive when using --upload-only",
					&boolValues["remove_source_files"],
				"single-directory",
					"Specify a single local directory within the OneDrive root to sync.",
					&stringValues["single_directory"],
				"skip-dot-files",
					"Skip dot files and folders from syncing",
					&boolValues["skip_dotfiles"],
				"skip-file",
					"Skip any files that match this pattern from syncing",
					&stringValues["skip_file"],
				"skip-dir",
					"Skip any directories that match this pattern from syncing",
					&stringValues["skip_dir"],
				"skip-size",
					"Skip new files larger than this size (in MB)",
					&longValues["skip_size"],
				"skip-dir-strict-match",
					"When matching skip_dir directories, only match explicit matches",
					&boolValues["skip_dir_strict_match"],
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
				"sync-root-files",
					"Sync all files in sync_dir root when using sync_list.",
					&boolValues["sync_root_files"],
				"upload-only",
					"Replicate the locally configured sync_dir state to OneDrive, by only uploading local changes to OneDrive. Do not download changes from OneDrive.",
					&boolValues["upload_only"],
				"user-agent",
					"Specify a User Agent string to the http client",
					&stringValues["user_agent"],
				"confdir",
					"Set the directory used to store the configuration files",
					&tmpStr,
				"verbose|v+",
					"Print more details, useful for debugging (repeat for extra debugging)",
					&tmpVerb,
				"version",
					"Print the version and exit",
					&tmpBol,
				"list-shared-folders",
					"List OneDrive Business Shared Folders",
					&boolValues["list_business_shared_folders"],
				"sync-shared-folders",
					"Sync OneDrive Business Shared Folders",
					&boolValues["sync_business_shared_folders"]
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

	// load a configuration file
	private bool load(string filename)
	{
		// configure function variables
		auto file = File(filename, "r");
		string lineBuffer;
		
		// configure scopes
		// - failure
		scope(failure) {
			// close file if open
			if (file.isOpen()){
				// close open file
				file.close();
			}
			return false;
		}
		// - exit
		scope(exit) {
			// close file if open
			if (file.isOpen()){
				// close open file
				file.close();
			}
		}
	
		// read file line by line
		auto range = file.byLine();
		foreach (line; range) {
			lineBuffer = stripLeft(line).to!string;
			if (lineBuffer.length == 0 || lineBuffer[0] == ';' || lineBuffer[0] == '#') continue;
			auto c = lineBuffer.matchFirst(configRegex);
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
						// detect need for --resync for these:
						//  --syncdir ARG
						//  --skip-file ARG
						//  --skip-dir ARG
						if (key == "sync_dir") configFileSyncDir = c.front.dup;
						if (key == "skip_file") configFileSkipFile = c.front.dup;
						if (key == "skip_dir") configFileSkipDir = c.front.dup;
						// Azure AD Configuration
						if (key == "azure_ad_endpoint") {
							string azureConfigValue = c.front.dup;
							switch(azureConfigValue) {
								case "":
									log.log("Using config option for Global Azure AD Endpoints");
									break;
								case "USL4":
									log.log("Using config option for Azure AD for US Government Endpoints");
									break;
								case "USL5":
									log.log("Using config option for Azure AD for US Government Endpoints (DOD)");
									break;
								case "DE":
									log.log("Using config option for Azure AD Germany");
									break;
								case "CN":
									log.log("Using config option for Azure AD China operated by 21Vianet");
									break;
								// Default - all other entries 
								default:
									log.log("Unknown Azure AD Endpoint - using Global Azure AD Endpoints");
							}
						}
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
				log.log("Malformed config line: ", lineBuffer);
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
		"--log-dir",
		"--min-notify-changes",
		"--monitor-interval",
		"--monitor-log-frequency",
		"--monitor-fullscan-frequency",
		"--remove-directory",
		"--single-directory",
		"--skip-file",
		"--source-directory",
		"--syncdir",
		"--user-agent" ];
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
		writefln("  %s%s%s%s\n      %s",
				it.optLong,
				it.optShort == "" ? "" : " " ~ it.optShort,
				argsNeedingOptions.canFind(it.optLong) ? " ARG" : "",
				it.required ? " (required)" : "", it.help);
	}
}

unittest
{
	auto cfg = new Config("");
	cfg.load("config");
	assert(cfg.getValueString("sync_dir") == "~/OneDrive");
}
