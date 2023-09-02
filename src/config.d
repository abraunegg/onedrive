// What is this module called?
module config;

// What does this module require to function?
import core.stdc.stdlib: EXIT_SUCCESS, EXIT_FAILURE, exit;
import std.stdio;
import std.process;
import std.regex;
import std.string;
import std.algorithm.searching;
import std.algorithm.sorting: sort;
import std.file;
import std.conv;
import std.path;
import std.getopt;
import std.format;
import std.ascii;

// What other modules that we have created do we need to import?
import log;
import util;

class ApplicationConfig {
	// Application default values - these do not change
	// - Compile time regex
	immutable auto configRegex = ctRegex!(`^(\w+)\s*=\s*"(.*)"\s*$`);
	// - Default directory to store data
	immutable string defaultSyncDir = "~/OneDrive";
	// - Default Directory Permissions
	immutable long defaultDirectoryPermissionMode = 700;
	// - Default File Permissions
	immutable long defaultFilePermissionMode = 600;
	// - Default types of files to skip
	// v2.0.x - 2.4.x: ~*|.~*|*.tmp
	// v2.5.x  		 : ~*|.~*|*.tmp|*.swp|*.partial
	immutable string defaultSkipFile = "~*|.~*|*.tmp|*.swp|*.partial";
	// - Default directories to skip (default is skip none)
	immutable string defaultSkipDir = "";
	// - Default log directory
	immutable string defaultLogFileDir = "/var/log/onedrive";
	// - Default configuration directory
	immutable string defaultConfigDirName = "~/.config/onedrive";
	
	// Microsoft Requirements 
	// - Default Application ID (abraunegg)
	immutable string defaultApplicationId = "d50ca740-c83f-4d1b-b616-12c519384f0c";
	// - Microsoft User Agent ISV Tag
	immutable string isvTag = "ISV";
	// - Microsoft User Agent Company name
	immutable string companyName = "abraunegg";
	// - Microsoft Application name as per Microsoft Azure application registration
	immutable string appTitle = "OneDrive Client for Linux";
	// Comply with OneDrive traffic decoration requirements
	// https://docs.microsoft.com/en-us/sharepoint/dev/general-development/how-to-avoid-getting-throttled-or-blocked-in-sharepoint-online
	// - Identify as ISV and include Company Name, App Name separated by a pipe character and then adding Version number separated with a slash character
	
	//immutable string defaultUserAgent = isvTag ~ "|" ~ companyName ~ "|" ~ appTitle ~ "/" ~ strip(import("version"));
	immutable string defaultUserAgent = isvTag ~ "|" ~ companyName ~ "|" ~ appTitle ~ "/" ~ "v2.5.0-alpha-0";
	
	// HTTP Struct items, used for configuring HTTP()
	// Curl Timeout Handling
	// libcurl dns_cache_timeout timeout
	immutable int defaultDnsTimeout = 60;
	// Connect timeout for HTTP|HTTPS connections
	immutable int defaultConnectTimeout = 10;
	// With the following settings we force
	// - if there is no data flow for 10min, abort
	// - if the download time for one item exceeds 1h, abort
	//
	// Timeout for activity on connection
	//  this translates into Curl's CURLOPT_LOW_SPEED_TIME
	//  which says:
	//   It contains the time in number seconds that the
	//   transfer speed should be below the CURLOPT_LOW_SPEED_LIMIT
	//   for the library to consider it too slow and abort.
	immutable int defaultDataTimeout = 600;
	// Maximum time any operation is allowed to take
	// This includes dns resolution, connecting, data transfer, etc.
	immutable int defaultOperationTimeout = 3600;
	// Specify what IP protocol version should be used when communicating with OneDrive
	immutable int defaultIpProtocol = 0; // 0 = IPv4 + IPv6, 1 = IPv4 Only, 2 = IPv6 Only
	// Specify how many redirects should be allowed
	immutable int defaultMaxRedirects = 5;
		
	// Azure Active Directory & Graph Explorer Endpoints
	// - Global & Default
	immutable string globalAuthEndpoint = "https://login.microsoftonline.com";
	immutable string globalGraphEndpoint = "https://graph.microsoft.com";
	// - US Government L4
	immutable string usl4AuthEndpoint = "https://login.microsoftonline.us";
	immutable string usl4GraphEndpoint = "https://graph.microsoft.us";
	// - US Government L5
	immutable string usl5AuthEndpoint = "https://login.microsoftonline.us";
	immutable string usl5GraphEndpoint = "https://dod-graph.microsoft.us";
	// - Germany
	immutable string deAuthEndpoint = "https://login.microsoftonline.de";
	immutable string deGraphEndpoint = "https://graph.microsoft.de";
	// - China
	immutable string cnAuthEndpoint = "https://login.chinacloudapi.cn";
	immutable string cnGraphEndpoint = "https://microsoftgraph.chinacloudapi.cn";
	
	// Application items that depend on application run-time environment, thus cannot be immutable
	// Public variables
	// Was the application just authorised - paste of response uri
	bool applicationAuthorizeResponseUri = false;
	// Store the 'refresh_token' file path
	string refreshTokenFilePath = "";
	// Store the refreshToken for use within the application
	string refreshToken;
	// Store the 'session_upload.CRC32-HASH' file path
	string uploadSessionFilePath = "";
	
	bool apiWasInitialised = false;
	bool syncEngineWasInitialised = false;
	string accountType;
	string defaultDriveId;
	string defaultRootId;
	ulong remainingFreeSpace = 0;
	bool quotaAvailable = true;
	bool quotaRestricted = false;
	
	bool fullScanTrueUpRequired = false;
	bool surpressLoggingOutput = false;
	
	// This is the value that needs testing when we are actually downloading and uploading data
	ulong concurrentThreads = 16;
		
	// All application run-time paths are formulated from this as a set of defaults
	// - What is the home path of the actual 'user' that is running the application
	string defaultHomePath = "";
	// - What is the config path for the application. By default, this is ~/.config/onedrive but can be overridden by using --confdir
	private string configDirName = defaultConfigDirName;
	// - In case we have to use a system config directory such as '/etc/onedrive' or similar, store that path in this variable
	private string systemConfigDirName = "";
	// - Store the configured converted octal value for directory permissions
	private int configuredDirectoryPermissionMode;
	// - Store the configured converted octal value for file permissions
	private int configuredFilePermissionMode;
	// - Store the 'delta_link' file path
	private string deltaLinkFilePath = "";
	// - Store the 'items.sqlite3' file path
	string databaseFilePath = "";
	// - Store the 'items-dryrun.sqlite3' file path
	string databaseFilePathDryRun = "";
	// - Store the user 'config' file path
	private string userConfigFilePath = "";
	// - Store the system 'config' file path
	private string systemConfigFilePath = "";
	// - Store the 'sync_list' file path
	string syncListFilePath = "";
	// - Store the 'business_shared_items' file path
	string businessSharedItemsFilePath = "";
	// - What is the 'config' file path that will be used?
	private string applicableConfigFilePath = "";
	
	// Hash files so that we can detect when the configuration has changed, in items that will require a --resync
	private string configHashFile = "";
	private string configBackupFile = "";
	private string syncListHashFile = "";
	private string businessSharedItemsHashFile = "";
	// hash file permission values (set via initialize function)
	private int convertedPermissionValue;
	
	// Store the actual 'runtime' hash
	private string currentConfigHash = "";
	private string currentSyncListHash = "";
	private string currentBusinessSharedItemsHash = "";
	
	// Store the previous config files hash values (file contents)
	private string previousConfigHash = "";
	private string previousSyncListHash = "";
	private string previousBusinessSharedItemsHash = "";
	
	// Store items that come in from the 'config' file, otherwise these need to be set the the defaults
	private string configFileSyncDir = defaultSyncDir;
	private string configFileSkipFile = defaultSkipFile;
	private string configFileSkipDir = ""; // Default here is no directories are skipped
	
	// Array of values that are the actual application runtime configuration
	// The values stored in these array's are the actual application configuration which can then be accessed by getValue & setValue
	string[string] stringValues;
	long[string] longValues;
	bool[string] boolValues;
	
	// Initialise the application configuration
	bool initialize(string confdirOption) {
		
		// Default runtime configuration - entries in config file ~/.config/onedrive/config or derived from variables above
		// An entry here means it can be set via the config file if there is a coresponding entry, read from config and set via update_from_args()
		// The below becomes the 'default' application configuration before config file and/or cli options are overlayed on top
		
		// - Set the required default values
		stringValues["application_id"] = defaultApplicationId;
		stringValues["log_dir"] = defaultLogFileDir;
		stringValues["skip_dir"] = defaultSkipDir;
		stringValues["skip_file"] = defaultSkipFile;
		stringValues["sync_dir"] = defaultSyncDir;
		stringValues["user_agent"] = defaultUserAgent;
		// - The 'drive_id' is used when we specify a specific OneDrive ID when attempting to sync Shared Folders and SharePoint items
		stringValues["drive_id"] = "";
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
		// Support single-tenant applications that are not able to use the "common" multiplexer
		stringValues["azure_tenant_id"] = "";
		
		// - Store how many times was --verbose added
		longValues["verbose"] = log.verbose; // might also be initialized by the first getopt call!
		// - The amount of time (seconds) between monitor sync loops
		longValues["monitor_interval"] = 300;
		// - What size of file should be skipped?
		longValues["skip_size"] = 0;
		// - How many 'changes' from the OneDrive API need to occur to trigger a notification?
		longValues["min_notify_changes"] = 5;
		// - How many 'loops' when using --monitor, before we print out high frequency recurring items?
		longValues["monitor_log_frequency"] = 6;
		// - Number of N sync runs before performing a full local scan of sync_dir
		//   By default 12 which means every ~60 minutes a full disk scan of sync_dir will occur 
		//   'monitor_interval' * 'monitor_fullscan_frequency' = 3600 = 1 hour
		longValues["monitor_fullscan_frequency"] = 12;
		// - Number of children in a path that is locally removed which will be classified as a 'big data delete'
		longValues["classify_as_big_delete"] = 1000;
		// - Configure the default folder permission attributes for newly created folders
		longValues["sync_dir_permissions"] = defaultDirectoryPermissionMode;
		// - Configure the default file permission attributes for newly created file
		longValues["sync_file_permissions"] = defaultFilePermissionMode;
		// - Configure download / upload rate limits
		longValues["rate_limit"] = 0;
		// - To ensure we do not fill up the load disk, how much disk space should be reserved by default
		longValues["space_reservation"] = 50 * 2^^20; // 50 MB as Bytes
		
		// HTTPS & CURL Operation Settings
		// - Maximum time an operation is allowed to take
		//   This includes dns resolution, connecting, data transfer, etc.
		longValues["operation_timeout"] = defaultOperationTimeout;
		// libcurl dns_cache_timeout timeout
		longValues["dns_timeout"] = defaultDnsTimeout;
		// Timeout for HTTPS connections
		longValues["connect_timeout"] = defaultConnectTimeout;
		// Timeout for activity on a HTTPS connection
		longValues["data_timeout"] = defaultDataTimeout;
		// What IP protocol version should be used when communicating with OneDrive
		longValues["ip_protocol_version"] = defaultIpProtocol; // 0 = IPv4 + IPv6, 1 = IPv4 Only, 2 = IPv6 Only
		
		// - Do we wish to upload only?
		boolValues["upload_only"] = false;
		// - Do we need to check for the .nomount file on the mount point?
		boolValues["check_nomount"] = false;
		// - Do we need to check for the .nosync file anywhere?
		boolValues["check_nosync"] = false;
		// - Do we wish to download only?
		boolValues["download_only"] = false;
		// - Do we disable notifications?
		boolValues["disable_notifications"] = false;
		// - Do we bypass all the download validation? 
		//   This is critically important not to disable, but because of SharePoint 'feature' can be highly desirable to enable
		boolValues["disable_download_validation"] = false;
		// - Do we bypass all the upload validation? 
		//   This is critically important not to disable, but because of SharePoint 'feature' can be highly desirable to enable
		boolValues["disable_upload_validation"] = false;
		// - Do we enable logging?
		boolValues["enable_logging"] = false;
		// - Do we force HTTP 1.1 for connections to the OneDrive API
		//   By default we use the curl library default, which should be HTTP2 for most operations governed by the OneDrive API
		boolValues["force_http_11"] = false;
		// - Do we treat the local file system as the source of truth for our data?
		boolValues["local_first"] = false;
		// - Do we ignore local file deletes, so that all files are retained online?
		boolValues["no_remote_delete"] = false;
		// - Do we skip symbolic links?
		boolValues["skip_symlinks"] = false;
		// - Do we enable debugging for all HTTPS flows. Critically important for debugging API issues.
		boolValues["debug_https"] = false;
		// - Do we skip .files and .folders?
		boolValues["skip_dotfiles"] = false;
		// - Do we perform a 'dry-run' with no local or remote changes actually being performed?
		boolValues["dry_run"] = false;
		// - Do we sync all the files in the 'sync_dir' root?
		boolValues["sync_root_files"] = false;
		// - Do we delete source after successful transfer?
		boolValues["remove_source_files"] = false;
		// - Do we perform strict matching for skip_dir?
		boolValues["skip_dir_strict_match"] = false;
		// - Do we perform a --resync?
		boolValues["resync"] = false;
		// - resync now needs to be acknowledged based on the 'risk' of using it
		boolValues["resync_auth"] = false;
		// - Ignore data safety checks and overwrite local data rather than preserve & rename
		//   This is a config file option ONLY
		boolValues["bypass_data_preservation"] = false;
		// - Allow enable / disable of the syncing of OneDrive Business Shared items (files & folders) via configuration file
		boolValues["sync_business_shared_items"] = false;
		// - Log to application output running configuration values
		boolValues["display_running_config"] = false;
		// - Configure read-only authentication scope
		boolValues["read_only_auth_scope"] = false;
		// - Flag to cleanup local files when using --download-only
		boolValues["cleanup_local_files"] = false;
		
		// Webhook Feature Options
		stringValues["webhook_public_url"] = "";
		stringValues["webhook_listening_host"] = "";
		longValues["webhook_listening_port"] = 8888;
		longValues["webhook_expiration_interval"] = 3600 * 24;
		longValues["webhook_renewal_interval"] = 3600 * 12;
		boolValues["webhook_enabled"] = false;
		
		// Print in debug the application version as soon as possible
		//log.vdebug("Application Version: ", strip(import("version")));
		string tempVersion = "v2.5.0-alpha-0" ~ " GitHub version: " ~ strip(import("version"));
		log.vdebug("Application Version: ", tempVersion);
		
		// EXPAND USERS HOME DIRECTORY
		// Determine the users home directory.
		// Need to avoid using ~ here as expandTilde() below does not interpret correctly when running under init.d or systemd scripts
		// Check for HOME environment variable
		if (environment.get("HOME") != ""){
			// Use HOME environment variable
			log.vdebug("defaultHomePath: HOME environment variable set");
			defaultHomePath = environment.get("HOME");
		} else {
			if ((environment.get("SHELL") == "") && (environment.get("USER") == "")){
				// No shell is set or username - observed case when running as systemd service under CentOS 7.x
				log.vdebug("defaultHomePath: WARNING - no HOME environment variable set");
				log.vdebug("defaultHomePath: WARNING - no SHELL environment variable set");
				log.vdebug("defaultHomePath: WARNING - no USER environment variable set");
				defaultHomePath = "/root";
			} else {
				// A shell & valid user is set, but no HOME is set, use ~ which can be expanded
				log.vdebug("defaultHomePath: WARNING - no HOME environment variable set");
				defaultHomePath = "~";
			}
		}
		
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
		// force_children_scan = true | false
		// - Force client to use /children rather than /delta to query changes on OneDrive
		// - This option flags nationalCloudDeployment as true, forcing the client to act like it is using a National Cloud Deployment model
		boolValues["force_children_scan"] = false;
		// display_processing_time = true | false
		// - Enabling this option will add function processing times to the console output
		// - This then enables tracking of where the application is spending most amount of time when processing data when users have questions re performance
		boolValues["display_processing_time"] = false;
		
		// Function variables
		string configDirBase;
		string systemConfigDirBase;
		bool configurationInitialised = false;
		
		// Initialise the application configuration, using the provided --confdir option was passed in
		if (!confdirOption.empty) {
			// A CLI 'confdir' was passed in
			// Clean up any stray " .. these should not be there for correct process handling of the configuration option
			confdirOption = strip(confdirOption,"\"");
			log.vdebug("configDirName: CLI override to set configDirName to: ", confdirOption);
			if (canFind(confdirOption,"~")) {
				// A ~ was found
				log.vdebug("configDirName: A '~' was found in configDirName, using the calculated 'defaultHomePath' to replace '~'");
				configDirName = defaultHomePath ~ strip(confdirOption,"~","~");
			} else {
				configDirName = confdirOption;
			}
		} else {
			// Determine the base directory relative to which user specific configuration files should be stored
			if (environment.get("XDG_CONFIG_HOME") != ""){
				log.vdebug("configDirBase: XDG_CONFIG_HOME environment variable set");
				configDirBase = environment.get("XDG_CONFIG_HOME");
			} else {
				// XDG_CONFIG_HOME does not exist on systems where X11 is not present - ie - headless systems / servers
				log.vdebug("configDirBase: WARNING - no XDG_CONFIG_HOME environment variable set");
				configDirBase = defaultHomePath ~ "/.config";
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
		
		// Configuration directory should now have been correctly identified
		if (!exists(configDirName)) {
			// create the directory
			mkdirRecurse(configDirName);
			// Configure the applicable permissions for the folder
			configDirName.setAttributes(returnRequiredDirectoryPermisions());
		} else {
			// The config path exists
			// The path that exists must be a directory, not a file
			if (!isDir(configDirName)) {
				if (!confdirOption.empty) {
					// the configuration path was passed in by the user .. user error
					log.error("ERROR: --confdir entered value is an existing file instead of an existing directory");
				} else {
					// other error
					log.error("ERROR: " ~ confdirOption ~ " is a file rather than a directory");
				}
				// Must exit
				exit(EXIT_FAILURE);	
			}
		}
		
		// Update application set variables based on configDirName
		// - What is the full path for the 'refresh_token'
		refreshTokenFilePath = buildNormalizedPath(configDirName ~ "/refresh_token");
		// - What is the full path for the 'delta_link'
		deltaLinkFilePath = buildNormalizedPath(configDirName ~ "/delta_link");
		// - What is the full path for the 'items.sqlite3' - the database cache file
		databaseFilePath = buildNormalizedPath(configDirName ~ "/items.sqlite3");
		// - What is the full path for the 'items-dryrun.sqlite3' - the dry-run database cache file
		databaseFilePathDryRun = buildNormalizedPath(configDirName ~ "/items-dryrun.sqlite3");
		// - What is the full path for the 'resume_upload'
		uploadSessionFilePath = buildNormalizedPath(configDirName ~ "/session_upload");
		// - What is the full path for the 'sync_list' file
		syncListFilePath = buildNormalizedPath(configDirName ~ "/sync_list");
		// - What is the full path for the 'config' - the user file to configure the application
		userConfigFilePath = buildNormalizedPath(configDirName ~ "/config");
		// - What is the full path for the system 'config' file if it is required
		systemConfigFilePath = buildNormalizedPath(systemConfigDirName ~ "/config");
		// - What is the full path for the 'business_shared_items'
		businessSharedItemsFilePath = buildNormalizedPath(configDirName ~ "/business_shared_items");
		
		// To determine if any configuration items has changed, where a --resync would be required, we need to have a hash file for the following items
		// - 'config.backup' file
		// - applicable 'config' file
		// - 'sync_list' file
		// - 'business_shared_items' file
		configBackupFile = buildNormalizedPath(configDirName ~ "/.config.backup");
		configHashFile = buildNormalizedPath(configDirName ~ "/.config.hash");
		syncListHashFile = buildNormalizedPath(configDirName ~ "/.sync_list.hash");
		businessSharedItemsHashFile = buildNormalizedPath(configDirName ~ "/.business_shared_items.hash");
				
		// Debug Output for application set variables based on configDirName
		log.vdebug("refreshTokenFilePath = ", refreshTokenFilePath);
		log.vdebug("deltaLinkFilePath = ", deltaLinkFilePath);
		log.vdebug("databaseFilePath = ", databaseFilePath);
		log.vdebug("databaseFilePathDryRun = ", databaseFilePathDryRun);
		log.vdebug("uploadSessionFilePath = ", uploadSessionFilePath);
		log.vdebug("userConfigFilePath = ", userConfigFilePath);
		log.vdebug("syncListFilePath = ", syncListFilePath);
		if (!systemConfigDirName.empty) log.vdebug("systemConfigFilePath = ", systemConfigFilePath);
		log.vdebug("businessSharedItemsFilePath = ", businessSharedItemsFilePath);
		log.vdebug("configBackupFile = ", configBackupFile);
		log.vdebug("configHashFile = ", configHashFile);
		log.vdebug("syncListHashFile = ", syncListHashFile);
		log.vdebug("businessSharedItemsHashFile = ", businessSharedItemsHashFile);
		
		// Configure the Hash and Backup File Permission Value
		string valueToConvert = to!string(defaultFilePermissionMode);
		auto convertedValue = parse!long(valueToConvert, 8);
		convertedPermissionValue = to!int(convertedValue);
		
		// Initialise the application using the configuration file if it exists
		if (!exists(userConfigFilePath)) {
			// 'user' configuration file does not exist
			// Is there a system configuration file?
			if (!exists(systemConfigFilePath)) {
				// 'system' configuration file does not exist
				log.vlog("No user or system config file found, using application defaults");
				applicableConfigFilePath = userConfigFilePath;
				configurationInitialised = true;
			} else {
				// 'system' configuration file exists
				// can we load the configuration file without error?
				if (loadConfigFile(systemConfigFilePath)) {
					// configuration file loaded without error
					log.log("System configuration file successfully loaded");
					// Set 'applicableConfigFilePath' to equal the 'config' we loaded
					applicableConfigFilePath = systemConfigFilePath;
					// Update the configHashFile path value to ensure we are using the system 'config' file for the hash
					configHashFile = buildNormalizedPath(systemConfigFilePath ~ ".hash");
					configurationInitialised = true;
				} else {
					// there was a problem loading the configuration file
					log.log("\nSystem configuration file has errors - please check your configuration");
				}
			}						
		} else {
			// 'user' configuration file exists
			// can we load the configuration file without error?
			if (loadConfigFile(userConfigFilePath)) {
				// configuration file loaded without error
				log.log("Configuration file successfully loaded");
				// Set 'applicableConfigFilePath' to equal the 'config' we loaded
				applicableConfigFilePath = userConfigFilePath;
				configurationInitialised = true;
			} else {
				// there was a problem loading the configuration file
				log.log("\nConfiguration file has errors - please check your configuration");
			}
		}
		
		// Advise the user path that we use for the application configuration
		if (canFind(applicableConfigFilePath, configDirName)) {
			log.vlog("Using 'user' Config Dir: ", configDirName);
		}
		if (canFind(applicableConfigFilePath, systemConfigDirName)) {
			log.vlog("Using 'system' Config Dir: ", systemConfigDirName);
		}
		return configurationInitialised;
	}
	
	// Create a backup of the 'config' file if it does not exist
	void createBackupConfigFile() {
		if (!getValueBool("dry_run")) {
			// Is there a backup of the config file if the config file exists?
			if (exists(applicableConfigFilePath)) {
				log.vdebug("Creating a backup of the applicable config file");
				// create backup copy of current config file
				std.file.copy(applicableConfigFilePath, configBackupFile);
				// File Copy should only be readable by the user who created it - 0600 permissions needed
				configBackupFile.setAttributes(convertedPermissionValue);
			}
		} else {
			// --dry-run scenario ... technically we should not be making any local file changes .......
			log.log("DRY RUN: Not creating backup config file as --dry-run has been used");
		}
	}
	
	// Return a given string value based on the provided key
	string getValueString(string key) {
		auto p = key in stringValues;
		if (p) {
			return *p;
		} else {
			throw new Exception("Missing config value: " ~ key);
		}
	}

	// Return a given long value based on the provided key
	long getValueLong(string key) {
		auto p = key in longValues;
		if (p) {
			return *p;
		} else {
			throw new Exception("Missing config value: " ~ key);
		}
	}

	// Return a given bool value based on the provided key
	bool getValueBool(string key) {
		auto p = key in boolValues;
		if (p) {
			return *p;
		} else {
			throw new Exception("Missing config value: " ~ key);
		}
	}
	
	// Set a given string value based on the provided key
	void setValueString(string key, string value) {
		stringValues[key] = value;
	}

	// Set a given long value based on the provided key
	void setValueLong(string key, long value) {
		longValues[key] = value;
	}

	// Set a given long value based on the provided key
	void setValueBool(string key, bool value) {
		boolValues[key] = value;
	}
	
	// Configure the directory octal permission value
	void configureRequiredDirectoryPermisions() {
		// return the directory permission mode required
		// - return octal!defaultDirectoryPermissionMode; ... cant be used .. which is odd
		// Error: variable defaultDirectoryPermissionMode cannot be read at compile time
		if (getValueLong("sync_dir_permissions") != defaultDirectoryPermissionMode) {
			// return user configured permissions as octal integer
			string valueToConvert = to!string(getValueLong("sync_dir_permissions"));
			auto convertedValue = parse!long(valueToConvert, 8);
			configuredDirectoryPermissionMode = to!int(convertedValue);
		} else {
			// return default as octal integer
			string valueToConvert = to!string(defaultDirectoryPermissionMode);
			auto convertedValue = parse!long(valueToConvert, 8);
			configuredDirectoryPermissionMode = to!int(convertedValue);
		}
	}

	// Configure the file octal permission value
	void configureRequiredFilePermisions() {
		// return the file permission mode required
		// - return octal!defaultFilePermissionMode; ... cant be used .. which is odd
		// Error: variable defaultFilePermissionMode cannot be read at compile time
		if (getValueLong("sync_file_permissions") != defaultFilePermissionMode) {
			// return user configured permissions as octal integer
			string valueToConvert = to!string(getValueLong("sync_file_permissions"));
			auto convertedValue = parse!long(valueToConvert, 8);
			configuredFilePermissionMode = to!int(convertedValue);
		} else {
			// return default as octal integer
			string valueToConvert = to!string(defaultFilePermissionMode);
			auto convertedValue = parse!long(valueToConvert, 8);
			configuredFilePermissionMode = to!int(convertedValue);
		}
	}

	// Read the configuredDirectoryPermissionMode and return
	int returnRequiredDirectoryPermisions() {
		if (configuredDirectoryPermissionMode == 0) {
			// the configured value is zero, this means that directories would get
			// values of d---------
			configureRequiredDirectoryPermisions();
		}
		return configuredDirectoryPermissionMode;
	}

	// Read the configuredFilePermissionMode and return
	int returnRequiredFilePermisions() {
		if (configuredFilePermissionMode == 0) {
			// the configured value is zero
			configureRequiredFilePermisions();
		}
		return configuredFilePermissionMode;
	}
	
	// Load a configuration file from the provided filename
	private bool loadConfigFile(string filename) {
		// configure function variables
		try {
			log.log("Reading configuration file: ", filename);
			readText(filename);
		} catch (std.file.FileException e) {
			// Unable to access required file
			log.error("ERROR: Unable to access ", e.msg);
			// Use exit scopes to shutdown API
			return false;
		}
		
		// We were able to readText the config file - so, we should be able to open and read it
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
						if (key == "skip_file") {
							// Handle multiple entries of skip_file
							if (configFileSkipFile.empty) {
								// currently no entry exists
								configFileSkipFile = c.front.dup;
							} else {
								// add to existing entry
								configFileSkipFile = configFileSkipFile ~ "|" ~ to!string(c.front.dup);
								setValueString("skip_file", configFileSkipFile);
							}
						}
						if (key == "skip_dir") {
							// Handle multiple entries of skip_dir
							if (configFileSkipDir.empty) {
								// currently no entry exists
								configFileSkipDir = c.front.dup;
							} else {
								// add to existing entry
								configFileSkipDir = configFileSkipDir ~ "|" ~ to!string(c.front.dup);
								setValueString("skip_dir", configFileSkipDir);
							}
						}
						// --single-directory Strip quotation marks from path 
						// This is an issue when using ONEDRIVE_SINGLE_DIRECTORY with Docker
						if (key == "single_directory") {
							// Strip quotation marks from provided path
							string configSingleDirectory = strip(to!string(c.front.dup), "\"");
							setValueString("single_directory", configSingleDirectory);
						}
						// Azure AD Configuration
						if (key == "azure_ad_endpoint") {
							string azureConfigValue = strip(c.front.dup);
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
						
						// Application ID
						if (key == "application_id") {
							// This key cannot be empty
							string tempApplicationId = strip(c.front.dup);
							if (tempApplicationId.empty) {
								log.log("Invalid value for key in config file - using default value: ", key);
								log.vdebug("application_id in config file cannot be empty - using default application_id");
								setValueString("application_id", defaultApplicationId);
							} else {
								setValueString("application_id", tempApplicationId);
							}
						}
					} else {
						auto ppp = key in longValues;
						if (ppp) {
							c.popFront();
							ulong thisConfigValue;
							
							// Can this value actually be converted to an integer?
							try {
								thisConfigValue = to!long(c.front.dup);
							} catch (std.conv.ConvException) {
								log.log("Invalid value for key in config file: ", key);
								return false;
							}
							
							setValueLong(key, thisConfigValue);
							
							// if key is 'monitor_interval' the value must be 300 or greater
							if (key == "monitor_interval") {
								// temp value
								ulong tempValue = thisConfigValue;
								// the temp value needs to be greater than 300 
								if (tempValue < 300) {
									log.log("Invalid value for key in config file - using default value: ", key);
									tempValue = 300;
								}
								setValueLong("monitor_interval", to!long(tempValue));
							}
							
							// if key is 'monitor_fullscan_frequency' the value must be 12 or greater
							if (key == "monitor_fullscan_frequency") {
								// temp value
								ulong tempValue = thisConfigValue;
								// the temp value needs to be greater than 12 
								if (tempValue < 12) {
									log.log("Invalid value for key in config file - using default value: ", key);
									tempValue = 12;
								}
								setValueLong("monitor_fullscan_frequency", to!long(tempValue));
							}
							
							// if key is 'space_reservation' we have to calculate MB -> bytes
							if (key == "space_reservation") {
								// temp value
								ulong tempValue = thisConfigValue;
								// a value of 0 needs to be made at least 1MB .. 
								if (tempValue == 0) {
									log.log("Invalid value for key in config file - using 1MB: ", key);
									tempValue = 1;
								}
								setValueLong("space_reservation", to!long(tempValue * 2^^20));
							}
							
							// if key is 'ip_protocol_version' this has to be a value of 0 or 1 or 2 .. nothing else
							if (key == "ip_protocol_version") {
								// temp value
								ulong tempValue = thisConfigValue;
								// If greater than 2, set to default
								if (tempValue > 2) {
									log.log("Invalid value for key in config file - using default value: ", key);
									// Set to default of 0
									tempValue = 0;
								}
								setValueLong("ip_protocol_version", to!long(tempValue));
							}
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
	
	// Update the application configuration based on CLI passed in parameters
	void updateFromArgs(string[] cliArgs) {
		// Add additional options that are NOT configurable via config file
		stringValues["create_directory"]  = "";
		stringValues["create_share_link"] = "";
		stringValues["destination_directory"] = "";
		stringValues["get_file_link"]     = "";
		stringValues["modified_by"]       = "";
		stringValues["get_o365_drive_id"] = "";
		stringValues["remove_directory"]  = "";
		stringValues["single_directory"]  = "";
		stringValues["source_directory"]  = "";
		stringValues["auth_files"]        = "";
		stringValues["auth_response"]     = "";
		boolValues["display_config"]      = false;
		boolValues["display_sync_status"] = false;
		boolValues["print_token"]         = false;
		boolValues["logout"]              = false;
		boolValues["reauth"]              = false;
		boolValues["monitor"]             = false;
		boolValues["synchronize"]         = false;
		boolValues["force"]               = false;
		boolValues["list_business_shared_items"] = false;
		boolValues["force_sync"]          = false;
		boolValues["with_editing_perms"]  = false;

		// Application Startup option validation
		try {
			string tmpStr;
			bool tmpBol;
			long tmpVerb;
			// duplicated from main.d to get full help output!
			auto opt = getopt(

				cliArgs,
				std.getopt.config.bundling,
				std.getopt.config.caseSensitive,
				"auth-files",
					"Perform authentication not via interactive dialog but via files read/writes to these files.",
					&stringValues["auth_files"],
				"auth-response",
					"Perform authentication not via interactive dialog but via providing the response url directly.",
					&stringValues["auth_response"],
				"check-for-nomount",
					"Check for the presence of .nosync in the syncdir root. If found, do not perform sync.",
					&boolValues["check_nomount"],
				"check-for-nosync",
					"Check for the presence of .nosync in each directory. If found, skip directory from sync.",
					&boolValues["check_nosync"],
				"classify-as-big-delete",
					"Number of children in a path that is locally removed which will be classified as a 'big data delete'",
					&longValues["classify_as_big_delete"],
				"cleanup-local-files",
					"Cleanup additional local files when using --download-only. This will remove local data.",
					&boolValues["cleanup_local_files"],	
				"create-directory",
					"Create a directory on OneDrive - no sync will be performed.",
					&stringValues["create_directory"],
				"create-share-link",
					"Create a shareable link for an existing file on OneDrive",
					&stringValues["create_share_link"],
				"debug-https",
					"Debug OneDrive HTTPS communication.",
					&boolValues["debug_https"],
				"destination-directory",
					"Destination directory for renamed or move on OneDrive - no sync will be performed.",
					&stringValues["destination_directory"],
				"disable-notifications",
					"Do not use desktop notifications in monitor mode.",
					&boolValues["disable_notifications"],
				"disable-download-validation",
					"Disable download validation when downloading from OneDrive",
					&boolValues["disable_download_validation"],
				"disable-upload-validation",
					"Disable upload validation when uploading to OneDrive",
					&boolValues["disable_upload_validation"],
				"display-config",
					"Display what options the client will use as currently configured - no sync will be performed.",
					&boolValues["display_config"],
				"display-running-config",
					"Display what options the client has been configured to use on application startup.",
					&boolValues["display_running_config"],
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
				"force-http-11",
					"Force the use of HTTP 1.1 for all operations",
					&boolValues["force_http_11"],
				"force",
					"Force the deletion of data when a 'big delete' is detected",
					&boolValues["force"],
				"force-sync",
					"Force a synchronization of a specific folder, only when using --sync --single-directory and ignore all non-default skip_dir and skip_file rules",
					&boolValues["force_sync"],
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
				"modified-by",
					"Display the last modified by details of a given path",
					&stringValues["modified_by"],
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
				"reauth",
					"Reauthenticate the client with OneDrive",
					&boolValues["reauth"],
				"resync",
					"Forget the last saved state, perform a full sync",
					&boolValues["resync"],
				"resync-auth",
					"Approve the use of performing a --resync action",
					&boolValues["resync_auth"],
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
				"space-reservation",
					"The amount of disk space to reserve (in MB) to avoid 100% disk space utilisation",
					&longValues["space_reservation"],
				"syncdir",
					"Specify the local directory used for synchronization to OneDrive",
					&stringValues["sync_dir"],
				"sync|s",
					"Perform a synchronization with OneDrive",
					&boolValues["synchronize"],
				"sync-root-files",
					"Sync all files in sync_dir root when using sync_list.",
					&boolValues["sync_root_files"],
				"upload-only",
					"Replicate the locally configured sync_dir state to OneDrive, by only uploading local changes to OneDrive. Do not download changes from OneDrive.",
					&boolValues["upload_only"],
				"user-agent",
					"Specify a User Agent string to use as the client identifier to Microsoft OneDrive",
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
					"List OneDrive Business Shared Items",
					&boolValues["list_business_shared_items"],
				"sync-shared-folders",
					"Sync OneDrive Business Shared Items",
					&boolValues["sync_business_shared_items"],
				"with-editing-perms",
					"Create a read-write shareable link for an existing file on OneDrive when used with --create-share-link <file>",
					&boolValues["with_editing_perms"]
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
	
	// Display the applicable application configuration
	void displayApplicationConfiguration() {
		if (getValueBool("display_running_config")) {
			writeln("--------------- Application Runtime Configuration ---------------");
		}
		
		// Display application version
		//writeln("onedrive version                             = ", strip(import("version")));
		
		string tempVersion = "v2.5.0-alpha-0" ~ " GitHub version: " ~ strip(import("version"));
		writeln("onedrive version                             = ", tempVersion);
		
		// Display all of the pertinent configuration options
		writeln("Config path                                  = ", configDirName);
		// Does a config file exist or are we using application defaults
		writeln("Config file found in config path             = ", exists(applicableConfigFilePath));
		
		// Is config option drive_id configured?
		writeln("Config option 'drive_id'                     = ", getValueString("drive_id"));
		
		// Config Options as per 'config' file
		writeln("Config option 'sync_dir'                     = ", getValueString("sync_dir"));
		
		// logging and notifications
		writeln("Config option 'enable_logging'               = ", getValueBool("enable_logging"));
		writeln("Config option 'log_dir'                      = ", getValueString("log_dir"));
		writeln("Config option 'disable_notifications'        = ", getValueBool("disable_notifications"));
		writeln("Config option 'min_notify_changes'           = ", getValueLong("min_notify_changes"));
		
		// skip files and directory and 'matching' policy
		writeln("Config option 'skip_dir'                     = ", getValueString("skip_dir"));
		writeln("Config option 'skip_dir_strict_match'        = ", getValueBool("skip_dir_strict_match"));
		writeln("Config option 'skip_file'                    = ", getValueString("skip_file"));
		writeln("Config option 'skip_dotfiles'                = ", getValueBool("skip_dotfiles"));
		writeln("Config option 'skip_symlinks'                = ", getValueBool("skip_symlinks"));
		
		// --monitor sync process options
		writeln("Config option 'monitor_interval'             = ", getValueLong("monitor_interval"));
		writeln("Config option 'monitor_log_frequency'        = ", getValueLong("monitor_log_frequency"));
		writeln("Config option 'monitor_fullscan_frequency'   = ", getValueLong("monitor_fullscan_frequency"));
		
		// sync process and method
		writeln("Config option 'read_only_auth_scope'         = ", getValueBool("read_only_auth_scope"));
		writeln("Config option 'dry_run'                      = ", getValueBool("dry_run"));
		writeln("Config option 'upload_only'                  = ", getValueBool("upload_only"));
		writeln("Config option 'download_only'                = ", getValueBool("download_only"));
		writeln("Config option 'local_first'                  = ", getValueBool("local_first"));
		writeln("Config option 'check_nosync'                 = ", getValueBool("check_nosync"));
		writeln("Config option 'check_nomount'                = ", getValueBool("check_nomount"));
		writeln("Config option 'resync'                       = ", getValueBool("resync"));
		writeln("Config option 'resync_auth'                  = ", getValueBool("resync_auth"));
		writeln("Config option 'cleanup_local_files'          = ", getValueBool("cleanup_local_files"));

		// data integrity
		writeln("Config option 'classify_as_big_delete'       = ", getValueLong("classify_as_big_delete"));
		writeln("Config option 'disable_upload_validation'    = ", getValueBool("disable_upload_validation"));
		writeln("Config option 'bypass_data_preservation'     = ", getValueBool("bypass_data_preservation"));
		writeln("Config option 'no_remote_delete'             = ", getValueBool("no_remote_delete"));
		writeln("Config option 'remove_source_files'          = ", getValueBool("remove_source_files"));
		writeln("Config option 'sync_dir_permissions'         = ", getValueLong("sync_dir_permissions"));
		writeln("Config option 'sync_file_permissions'        = ", getValueLong("sync_file_permissions"));
		writeln("Config option 'space_reservation'            = ", getValueLong("space_reservation"));
		
		// curl operations
		writeln("Config option 'application_id'               = ", getValueString("application_id"));
		writeln("Config option 'azure_ad_endpoint'            = ", getValueString("azure_ad_endpoint"));
		writeln("Config option 'azure_tenant_id'              = ", getValueString("azure_tenant_id"));
		writeln("Config option 'user_agent'                   = ", getValueString("user_agent"));
		writeln("Config option 'force_http_11'                = ", getValueBool("force_http_11"));
		writeln("Config option 'debug_https'                  = ", getValueBool("debug_https"));
		writeln("Config option 'rate_limit'                   = ", getValueLong("rate_limit"));
		writeln("Config option 'operation_timeout'            = ", getValueLong("operation_timeout"));
		writeln("Config option 'dns_timeout'                  = ", getValueLong("dns_timeout"));
		writeln("Config option 'connect_timeout'              = ", getValueLong("connect_timeout"));
		writeln("Config option 'data_timeout'                 = ", getValueLong("data_timeout"));
		writeln("Config option 'ip_protocol_version'          = ", getValueLong("ip_protocol_version"));
		
		// Is sync_list configured ?
		writeln("Config option 'sync_root_files'              = ", getValueBool("sync_root_files"));
		if (exists(syncListFilePath)){
			
			writeln("Selective sync 'sync_list' configured        = true");
			writeln("sync_list contents:");
			// Output the sync_list contents
			auto syncListFile = File(syncListFilePath, "r");
			auto range = syncListFile.byLine();
			foreach (line; range)
			{
				writeln(line);
			}
		} else {
			writeln("Selective sync 'sync_list' configured        = false");
			
		}

		// Is sync_business_shared_items enabled and configured ?
		writeln("Config option 'sync_business_shared_items'   = ", getValueBool("sync_business_shared_items"));
		if (exists(businessSharedItemsFilePath)){
			writeln("Business Shared Items configured             = true");
			writeln("sync_business_shared_items contents:");
			// Output the sync_business_shared_items contents
			auto businessSharedItemsFileList = File(businessSharedItemsFilePath, "r");
			auto range = businessSharedItemsFileList.byLine();
			foreach (line; range)
			{
				writeln(line);
			}
		} else {
			writeln("Business Shared Items configured             = false");
		}
		
		// Are webhooks enabled?
		writeln("Config option 'webhook_enabled'              = ", getValueBool("webhook_enabled"));
		if (getValueBool("webhook_enabled")) {
			writeln("Config option 'webhook_public_url'           = ", getValueString("webhook_public_url"));
			writeln("Config option 'webhook_listening_host'       = ", getValueString("webhook_listening_host"));
			writeln("Config option 'webhook_listening_port'       = ", getValueLong("webhook_listening_port"));
			writeln("Config option 'webhook_expiration_interval'  = ", getValueLong("webhook_expiration_interval"));
			writeln("Config option 'webhook_renewal_interval'     = ", getValueLong("webhook_renewal_interval"));
		}
		
		if (getValueBool("display_running_config")) {
			writeln("-----------------------------------------------------------------");
		}
	}
	
	// Prompt the user to accept the risk of using --resync
	bool displayResyncRiskForAcceptance() {
		// what is the user risk acceptance?
		bool userRiskAcceptance = false;
		
		// Did the user use --resync-auth or 'resync_auth' in the config file to negate presenting this message?
		if (!getValueBool("resync_auth")) {
			// need to prompt user
			char response;
			
			// --resync warning message
			writeln("\nThe usage of --resync will delete your local 'onedrive' client state, thus no record of your current 'sync status' will exist.");
			writeln("This has the potential to overwrite local versions of files with perhaps older versions of documents downloaded from OneDrive, resulting in local data loss.");
			writeln("If in doubt, backup your local data before using --resync");
			write("\nAre you sure you wish to proceed with --resync? [Y/N] ");
			
			try {
				// Attempt to read user response
				string input = readln().strip;
				if (input.length > 0) {
					response = std.ascii.toUpper(input[0]);
				}
			} catch (std.format.FormatException e) {
				userRiskAcceptance = false;
				// Caught an error
				return EXIT_FAILURE;
			}
			
			// What did the user enter?
			log.vdebug("--resync warning User Response Entered: ", (to!string(response)));
			
			// Evaluate user repsonse
			if ((to!string(response) == "y") || (to!string(response) == "Y")) {
				// User has accepted --resync risk to proceed
				userRiskAcceptance = true;
				// Are you sure you wish .. does not use writeln();
				write("\n");
			}
		} else {
			// resync_auth is true
			userRiskAcceptance = true;
		}
		
		// Return the --resync acceptance or not
		return userRiskAcceptance;
	}
	
	// Check the application configuration for any changes that need to trigger a --resync
	// This function is only called if --resync is not present
	bool applicationChangeWhereResyncRequired() {
		// Default is that no resync is required
		bool resyncRequired = false;
		
		// Configuration File Flags
		bool configFileOptionsDifferent = false;
		bool syncListFileDifferent = false;
		bool businessSharedItemsFileDifferent = false;
		bool syncDirDifferent = false;
		bool skipFileDifferent = false;
		bool skipDirDifferent = false;
		bool skipDotFilesDifferent = false;
		bool skipSymbolicLinksDifferent = false;
		
		// Create the required initial hash files
		createRequiredInitialConfigurationHashFiles();
		
		// Read in the existing hash file values
		readExistingConfigurationHashFiles();
		
		// Was the 'sync_list' file updated?
		if (currentSyncListHash != previousSyncListHash) {
			// Debugging output to assist what changed
			log.vdebug("sync_list file has been updated, --resync needed");
			syncListFileDifferent = true;
		}
		
		// Was the 'business_shared_items' file updated?
		if (currentBusinessSharedItemsHash != previousBusinessSharedItemsHash) {
			// Debugging output to assist what changed
			log.vdebug("business_shared_folders file has been updated, --resync needed");
			businessSharedItemsFileDifferent = true;
		}
		
		// Was the 'config' file updated between last execution and this execution?
		if (currentConfigHash != previousConfigHash) {
			// config file was updated, however we only want to trigger a --resync requirement if sync_dir, skip_dir, skip_file or drive_id was modified
			log.log("Application configuration file has been updated, checking if --resync needed");
			log.vdebug("Using this configBackupFile: ", configBackupFile);
			
			if (exists(configBackupFile)) {
				// check backup config what has changed for these configuration options if anything
				// # drive_id = ""
				// # sync_dir = "~/OneDrive"
				// # skip_file = "~*|.~*|*.tmp|*.swp|*.partial"
				// # skip_dir = ""
				// # skip_dotfiles = ""
				// # skip_symlinks = ""
				string[string] backupConfigStringValues;
				backupConfigStringValues["drive_id"] = "";
				backupConfigStringValues["sync_dir"] = "";
				backupConfigStringValues["skip_file"] = "";
				backupConfigStringValues["skip_dir"] = "";
				backupConfigStringValues["skip_dotfiles"] = "";
				backupConfigStringValues["skip_symlinks"] = "";
				
				// Common debug message if an element is different
				string configOptionModifiedMessage = " was modified since the last time the application was successfully run, --resync required";
				
				auto configBackupFileHandle = File(configBackupFile, "r");
				string lineBuffer;
				
				// read configBackupFile line by line
				auto range = configBackupFileHandle.byLine();
				// for each line
				foreach (line; range) {
					log.vdebug("Backup Config Line: ", lineBuffer);
					lineBuffer = stripLeft(line).to!string;
					if (lineBuffer.length == 0 || lineBuffer[0] == ';' || lineBuffer[0] == '#') continue;
					auto c = lineBuffer.matchFirst(configRegex);
					if (!c.empty) {
						c.popFront(); // skip the whole match
						string key = c.front.dup;
						log.vdebug("Backup Config Key: ", key);
						auto p = key in backupConfigStringValues;
						if (p) {
							c.popFront();
							// compare this key
							if ((key == "sync_dir") && (c.front.dup != getValueString("sync_dir"))) {
								log.vdebug(key, configOptionModifiedMessage);
								configFileOptionsDifferent = true;
							}
							if ((key == "skip_file") && (c.front.dup != getValueString("skip_file"))){
								log.vdebug(key, configOptionModifiedMessage);
								configFileOptionsDifferent = true;
							}
							if ((key == "skip_dir") && (c.front.dup != getValueString("skip_dir"))){
								log.vdebug(key, configOptionModifiedMessage);
								configFileOptionsDifferent = true;
							}
							if ((key == "drive_id") && (c.front.dup != getValueString("drive_id"))){
								log.vdebug(key, configOptionModifiedMessage);
								configFileOptionsDifferent = true;
							}
							if ((key == "skip_dotfiles") && (c.front.dup != to!string(getValueBool("skip_dotfiles")))){
								log.vdebug(key, configOptionModifiedMessage);
								configFileOptionsDifferent = true;
							}
							if ((key == "skip_symlinks") && (c.front.dup != to!string(getValueBool("skip_symlinks")))){
								log.vdebug(key, configOptionModifiedMessage);
								configFileOptionsDifferent = true;
							}
						}
					}
				}
				
				// close file if open
				if (configBackupFileHandle.isOpen()) {
					// close open file
					configBackupFileHandle.close();
				}
			} else {
				// no backup to check
				log.log("WARNING: no backup config file was found, unable to validate if any changes made");
			}
		}
		
		// config file set options can be changed via CLI input, specifically these will impact sync and a --resync will be needed:
		//  --syncdir ARG
		//  --skip-file ARG
		//  --skip-dir ARG
		if (exists(applicableConfigFilePath)) {
			// config file exists
			// was the sync_dir updated by CLI?
			if (configFileSyncDir != "") {
				// sync_dir was set in config file
				if (configFileSyncDir != getValueString("sync_dir")) {
					// config file was set and CLI input changed this
					log.vdebug("sync_dir: CLI override of config file option, --resync needed");
					syncDirDifferent = true;
				}
			}
			
			// was the skip_file updated by CLI?
			if (configFileSkipFile != "") {
				// skip_file was set in config file
				if (configFileSkipFile != getValueString("skip_file")) {
					// config file was set and CLI input changed this
					log.vdebug("skip_file: CLI override of config file option, --resync needed");
					skipFileDifferent = true;
				}
			}

			// was the skip_dir updated by CLI?
			if (configFileSkipDir != "") {
				// skip_dir was set in config file
				if (configFileSkipDir != getValueString("skip_dir")) {
					// config file was set and CLI input changed this
					log.vdebug("skip_dir: CLI override of config file option, --resync needed");
					skipDirDifferent = true;
				}
			}
		}
		
		// Did any of the config files or CLI options trigger a --resync requirement?
		log.vdebug("configFileOptionsDifferent: ", configFileOptionsDifferent);
		log.vdebug("syncListFileDifferent: ", syncListFileDifferent);
		log.vdebug("businessSharedItemsFileDifferent: ", businessSharedItemsFileDifferent);
		log.vdebug("syncDirDifferent: ", syncDirDifferent);
		log.vdebug("skipFileDifferent: ", skipFileDifferent);
		log.vdebug("skipDirDifferent: ", skipDirDifferent);
		
		if ((configFileOptionsDifferent) || (syncListFileDifferent) || (businessSharedItemsFileDifferent) || (syncDirDifferent) || (skipFileDifferent) || (skipDirDifferent)) {
			// set the flag
			resyncRequired = true;
		}
		return resyncRequired;
	}
	
	// Cleanup hash files that require to be cleaned up when a --resync is issued
	void cleanupHashFilesDueToResync() {
		if (!getValueBool("dry_run")) {
			// cleanup hash files
			log.vdebug("Cleaning up configuration hash files");
			safeRemove(configHashFile);
			safeRemove(syncListHashFile);
			safeRemove(businessSharedItemsHashFile);
		} else {
			// --dry-run scenario ... technically we should not be making any local file changes .......
			log.log("DRY RUN: Not removing hash files as --dry-run has been used");
		}
	}
	
	// For each of the config files, update the hash data in the hash files
	void updateHashContentsForConfigFiles() {
		// Are we in a --dry-run scenario?
		if (!getValueBool("dry_run")) {
			// Not a dry-run scenario, update the applicable files
			// Update applicable 'config' files
			if (exists(applicableConfigFilePath)) {
				// Update the hash of the applicable config file
				log.vdebug("Updating applicable config file hash");
				std.file.write(configHashFile, computeQuickXorHash(applicableConfigFilePath));
				// Hash file should only be readable by the user who created it - 0600 permissions needed
				configHashFile.setAttributes(convertedPermissionValue);
			}
			// Update 'sync_list' files
			if (exists(syncListFilePath)) {
				// update sync_list hash
				log.vdebug("Updating sync_list hash");
				std.file.write(syncListHashFile, computeQuickXorHash(syncListFilePath));
				// Hash file should only be readable by the user who created it - 0600 permissions needed
				syncListHashFile.setAttributes(convertedPermissionValue);
			}
			// Update 'update business_shared_items' files
			if (exists(businessSharedItemsFilePath)) {
				// update business_shared_folders hash
				log.vdebug("Updating business_shared_items hash");
				std.file.write(businessSharedItemsHashFile, computeQuickXorHash(businessSharedItemsFilePath));
				// Hash file should only be readable by the user who created it - 0600 permissions needed
				businessSharedItemsHashFile.setAttributes(convertedPermissionValue);
			}
		} else {
			// --dry-run scenario ... technically we should not be making any local file changes .......
			log.log("DRY RUN: Not updating hash files as --dry-run has been used");
		}
	}
	
	// Create any required hash files for files that help us determine if the configuration has changed since last run
	void createRequiredInitialConfigurationHashFiles() {
		// Does a 'config' file exist with a valid hash file
		if (exists(applicableConfigFilePath)) {
			if (!exists(configHashFile)) {
				// no existing hash file exists
				std.file.write(configHashFile, "initial-hash");
				// Hash file should only be readable by the user who created it - 0600 permissions needed
				configHashFile.setAttributes(convertedPermissionValue);
			}
			// Generate the runtime hash for the 'config' file
			currentConfigHash = computeQuickXorHash(applicableConfigFilePath);
		}
		
		// Does a 'sync_list' file exist with a valid hash file
		if (exists(syncListFilePath)) {
			if (!exists(syncListHashFile)) {
				// no existing hash file exists
				std.file.write(syncListHashFile, "initial-hash");
				// Hash file should only be readable by the user who created it - 0600 permissions needed
				syncListHashFile.setAttributes(convertedPermissionValue);
			}
			// Generate the runtime hash for the 'sync_list' file
			currentSyncListHash = computeQuickXorHash(syncListFilePath);
		}
		
		// Does a 'business_shared_items' file exist with a valid hash file
		if (exists(businessSharedItemsFilePath)) {
			if (!exists(businessSharedItemsHashFile)) {
				// no existing hash file exists
				std.file.write(businessSharedItemsHashFile, "initial-hash");
				// Hash file should only be readable by the user who created it - 0600 permissions needed
				businessSharedItemsHashFile.setAttributes(convertedPermissionValue);
			}
			// Generate the runtime hash for the 'sync_list' file
			currentBusinessSharedItemsHash = computeQuickXorHash(businessSharedItemsFilePath);
		}
	}
	
	// Read in the text values of the previous configurations
	int readExistingConfigurationHashFiles() {
		if (exists(configHashFile)) {
			try {
				previousConfigHash = readText(configHashFile);
			} catch (std.file.FileException e) {
				// Unable to access required file
				log.error("ERROR: Unable to access ", e.msg);
				// Use exit scopes to shutdown API
				return EXIT_FAILURE;
			}
		}
		
		if (exists(syncListHashFile)) {
			try {
				previousSyncListHash = readText(syncListHashFile);
			} catch (std.file.FileException e) {
				// Unable to access required file
				log.error("ERROR: Unable to access ", e.msg);
				// Use exit scopes to shutdown API
				return EXIT_FAILURE;
			}
		}
		if (exists(businessSharedItemsHashFile)) {
			try {
				previousBusinessSharedItemsHash = readText(businessSharedItemsHashFile);
			} catch (std.file.FileException e) {
				// Unable to access required file
				log.error("ERROR: Unable to access ", e.msg);
				// Use exit scopes to shutdown API
				return EXIT_FAILURE;
			}
		}
		return 0;
	}
	
	// Check for basic option conflicts - flags that should not be used together and/or flag combinations that conflict with each other
	bool checkForBasicOptionConflicts() {
	
		bool operationalConflictDetected = false;
		
		// What are the permission that have been set for the application?
		// These are relevant for:
		// - The ~/OneDrive parent folder or 'sync_dir' configured item
		// - Any new folder created under ~/OneDrive or 'sync_dir'
		// - Any new file created under ~/OneDrive or 'sync_dir'
		// valid permissions are 000 -> 777 - anything else is invalid
		if ((getValueLong("sync_dir_permissions") < 0) || (getValueLong("sync_file_permissions") < 0) || (getValueLong("sync_dir_permissions") > 777) || (getValueLong("sync_file_permissions") > 777)) {
			log.error("ERROR: Invalid 'User|Group|Other' permissions set within config file. Please check your configuration.");
			operationalConflictDetected = true;
		} else {
			// Debug log output what permissions are being set to
			log.vdebug("Configuring default new folder permissions as: ", getValueLong("sync_dir_permissions"));
			configureRequiredDirectoryPermisions();
			log.vdebug("Configuring default new file permissions as: ", getValueLong("sync_file_permissions"));
			configureRequiredFilePermisions();
		}
		
		// --upload-only and --download-only cannot be used together
		if ((getValueBool("upload_only")) && (getValueBool("download_only"))) {
			log.error("ERROR: --upload-only and --download-only cannot be used together. Use one, not both at the same time.");
			operationalConflictDetected = true;
		}
		
		// --sync and --monitor cannot be used together
		if ((getValueBool("synchronize")) && (getValueBool("monitor"))) {
			log.error("ERROR: --sync and --monitor cannot be used together. Use one, not both at the same time.");
			operationalConflictDetected = true;
		}
		
		// --no-remote-delete can ONLY be enabled when --upload-only is used
		if ((getValueBool("no_remote_delete")) && (!getValueBool("upload_only"))) {
			log.error("ERROR: --no-remote-delete can only be used with --upload-only.");
			operationalConflictDetected = true;
		}
		
		// --cleanup-local-files can ONLY be enabled when --download-only is used
		if ((getValueBool("cleanup_local_files")) && (!getValueBool("download_only"))) {
			log.error("ERROR: --cleanup-local-files can only be used with --download-only.");
			operationalConflictDetected = true;
		}
		
		// --list-shared-folders cannot be used with --resync and/or --resync-auth
		if ((getValueBool("list_business_shared_items")) && ((getValueBool("resync")) || (getValueBool("resync_auth")))) {
			log.error("ERROR: --list-shared-folders cannot be used with --resync or --resync-auth.");
			operationalConflictDetected = true;
		}
		
		// --display-sync-status cannot be used with --resync and/or --resync-auth
		if ((getValueBool("display_sync_status")) && ((getValueBool("resync")) || (getValueBool("resync_auth")))) {
			log.error("ERROR: --display-sync-status cannot be used with --resync or --resync-auth.");
			operationalConflictDetected = true;
		}
		
		// --modified-by cannot be used with --resync and/or --resync-auth
		if ((!getValueString("modified_by").empty) && ((getValueBool("resync")) || (getValueBool("resync_auth")))) {
			log.error("ERROR: --modified-by cannot be used with --resync or --resync-auth.");
			operationalConflictDetected = true;
		}
		
		// --get-file-link cannot be used with --resync and/or --resync-auth
		if ((!getValueString("get_file_link").empty) && ((getValueBool("resync")) || (getValueBool("resync_auth")))) {
			log.error("ERROR: --get-file-link cannot be used with --resync or --resync-auth.");
			operationalConflictDetected = true;
		}
		
		// --create-share-link cannot be used with --resync and/or --resync-auth
		if ((!getValueString("create_share_link").empty) && ((getValueBool("resync")) || (getValueBool("resync_auth")))) {
			log.error("ERROR: --create-share-link cannot be used with --resync or --resync-auth.");
			operationalConflictDetected = true;
		}
		
		// --get-O365-drive-id cannot be used with --resync and/or --resync-auth
		if ((!getValueString("get_o365_drive_id").empty) && ((getValueBool("resync")) || (getValueBool("resync_auth")))) {
			log.error("ERROR: --get-O365-drive-id cannot be used with --resync or --resync-auth.");
			operationalConflictDetected = true;
		}
		
		// --monitor and --download-only cannot be used together
		if ((getValueBool("monitor")) && (getValueBool("download_only"))) {
			log.error("ERROR: --monitor and --download-only cannot be used together.");
			operationalConflictDetected = true;
		}
		
		// Return bool value indicating if we have an operational conflict
		return operationalConflictDetected;
	}
}

// Output the full application help when --help is passed in
void outputLongHelp(Option[] opt) {
		auto argsNeedingOptions = [
			"--auth-files",
			"--auth-response",
			"--confdir",
			"--create-directory",
			"--create-share-link",
			"--destination-directory",
			"--get-file-link",
			"--get-O365-drive-id",
			"--log-dir",
			"--min-notify-changes",
			"--modified-by",
			"--monitor-interval",
			"--monitor-log-frequency",
			"--monitor-fullscan-frequency",
			"--operation-timeout",
			"--remove-directory",
			"--single-directory",
			"--skip-dir",
			"--skip-file",
			"--skip-size",
			"--source-directory",
			"--space-reservation",
			"--syncdir",
			"--user-agent" ];
		writeln(`OneDrive - a client for OneDrive Cloud Services

	Usage:
	  onedrive [options] --sync
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