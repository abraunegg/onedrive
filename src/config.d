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
import std.datetime;

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
	// - Default application logging directory
	immutable string defaultLogFileDir = "/var/log/onedrive";
	// - Default configuration directory
	immutable string defaultConfigDirName = "~/.config/onedrive";
	// - Default 'OneDrive Business Shared Files' Folder Name
	immutable string defaultBusinessSharedFilesDirectoryName = "Files Shared With Me";
	
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
	immutable string defaultUserAgent = isvTag ~ "|" ~ companyName ~ "|" ~ appTitle ~ "/" ~ strip(import("version"));
	
	// HTTP Struct items, used for configuring HTTP()
	// Curl Timeout Handling
	// libcurl dns_cache_timeout timeout
	immutable int defaultDnsTimeout = 60; // in seconds
	// Connect timeout for HTTP|HTTPS connections
	// Controls CURLOPT_CONNECTTIMEOUT
	immutable int defaultConnectTimeout = 10; // in seconds
	// Default data timeout for HTTP operations
	// curl.d has a default of: _defaultDataTimeout = dur!"minutes"(2);
	immutable int defaultDataTimeout = 60; // in seconds
	// Maximum time any operation is allowed to take
	// This includes dns resolution, connecting, data transfer, etc.
	// Controls CURLOPT_TIMEOUT
	immutable int defaultOperationTimeout = 3600; // in seconds
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
	
	// Application Version
	immutable string applicationVersion = "onedrive " ~ strip(import("version"));
	
	// Application items that depend on application run-time environment, thus cannot be immutable
	// Public variables
	
	// Logging output 
	bool verboseLogging = false;
	bool debugLogging = false;
	long verbosityCount = 0;
	
	// Was the application just authorised - paste of response uri
	bool applicationAuthorizeResponseUri = false;
	
	// Store the refreshToken for use within the application
	const(char)[] refreshToken;
	// Store the current accessToken for use within the application
	const(char)[] accessToken;
	// Store the 'refresh_token' file path
	string refreshTokenFilePath = "";
	// Store the accessTokenExpiration for use within the application
	SysTime accessTokenExpiration;
	// Store the 'session_upload.CRC32-HASH' file path
	string uploadSessionFilePath = "";
	
	// API initialisation flags
	bool apiWasInitialised = false;
	bool syncEngineWasInitialised = false;
	
	// Important Account Details
	string accountType;
	string defaultDriveId;
	string defaultRootId;
		
	// Sync Operations
	bool fullScanTrueUpRequired = false;
	bool suppressLoggingOutput = false;
	
	// Number of concurrent threads when downloading and uploading data
	ulong defaultConcurrentThreads = 8;
		
	// All application run-time paths are formulated from this as a set of defaults
	// - What is the home path of the actual 'user' that is running the application
	string defaultHomePath = "";
	// - What is the config path for the application. By default, this is ~/.config/onedrive but can be overridden by using --confdir
	string configDirName = defaultConfigDirName;
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
	// - What is the 'config' file path that will be used?
	private string applicableConfigFilePath = "";
	// - Store the 'sync_list' file path
	string syncListFilePath = "";
	
	// OneDrive Business Shared File handling - what directory will be used?
	string configuredBusinessSharedFilesDirectoryName = "";

	// Hash files so that we can detect when the configuration has changed, in items that will require a --resync
	private string configHashFile = "";
	private string configBackupFile = "";
	private string syncListHashFile = "";
	
	// Store the actual 'runtime' hash
	private string currentConfigHash = "";
	private string currentSyncListHash = "";
	
	// Store the previous config files hash values (file contents)
	private string previousConfigHash = "";
	private string previousSyncListHash = "";
		
	// Store items that come in from the 'config' file, otherwise these need to be set the the defaults
	private string configFileSyncDir = defaultSyncDir;
	private string configFileSkipFile = defaultSkipFile;
	private string configFileSkipDir = ""; // Default here is no directories are skipped
	private string configFileDriveId = ""; // Default here is that no drive id is specified
	private bool configFileSkipDotfiles = false;
	private bool configFileSkipSymbolicLinks = false;
	private bool configFileSyncBusinessSharedItems = false;
	
	// File permission values (set via initialise function)
	private int convertedPermissionValue;
	
	// Array of values that are the actual application runtime configuration
	// The values stored in these array's are the actual application configuration which can then be accessed by getValue & setValue
	string[string] stringValues;
	long[string] longValues;
	bool[string] boolValues;
	bool shellEnvironmentSet = false;
	
	// Initialise the application configuration
	bool initialise(string confdirOption, bool helpRequested) {
		
		// Default runtime configuration - entries in config file ~/.config/onedrive/config or derived from variables above
		// An entry here means it can be set via the config file if there is a corresponding entry, read from config and set via update_from_args()
		// The below becomes the 'default' application configuration before config file and/or cli options are overlaid on top
		
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
		longValues["verbose"] = verbosityCount; 
		// - The amount of time (seconds) between monitor sync loops
		longValues["monitor_interval"] = 300;
		// - What size of file should be skipped?
		longValues["skip_size"] = 0;
		// - How many 'loops' when using --monitor, before we print out high frequency recurring items?
		longValues["monitor_log_frequency"] = 12;
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
		//   This includes dns resolution, connecting, data transfer, etc - controls CURLOPT_TIMEOUT
		// CURLOPT_TIMEOUT: This option sets the maximum time in seconds that you allow the libcurl transfer operation to take. 
		// This is useful for controlling how long a specific transfer should take before it is considered too slow and aborted. However, it does not directly control the keep-alive time of a socket.
		longValues["operation_timeout"] = defaultOperationTimeout;
		// libcurl dns_cache_timeout timeout
		longValues["dns_timeout"] = defaultDnsTimeout;
		// Timeout for HTTPS connections - controls CURLOPT_CONNECTTIMEOUT
		// CURLOPT_CONNECTTIMEOUT: This option sets the timeout, in seconds, for the connection phase. It is the maximum time allowed for the connection to be established.
		longValues["connect_timeout"] = defaultConnectTimeout;
		// Timeout for activity on a HTTPS connection
		longValues["data_timeout"] = defaultDataTimeout;
		// What IP protocol version should be used when communicating with OneDrive
		longValues["ip_protocol_version"] = defaultIpProtocol; // 0 = IPv4 + IPv6, 1 = IPv4 Only, 2 = IPv6 Only
		
		// Number of concurrent threads
		longValues["threads"] = defaultConcurrentThreads; // Default is 8, user can increase to max of 16 or decrease
		
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
		boolValues["webhook_enabled"] = false;
		stringValues["webhook_public_url"] = "";
		stringValues["webhook_listening_host"] = "";
		longValues["webhook_listening_port"] = 8888;
		longValues["webhook_expiration_interval"] = 600;
		longValues["webhook_renewal_interval"] = 300;
		longValues["webhook_retry_interval"] = 60;
		
		// EXPAND USERS HOME DIRECTORY
		// Determine the users home directory.
		// Need to avoid using ~ here as expandTilde() below does not interpret correctly when running under init.d or systemd scripts
		// Check for HOME environment variable
		if (environment.get("HOME") != ""){
			// Use HOME environment variable
			logBuffer.addLogEntry("runtime_environment: HOME environment variable detected, expansion of '~' should be possible", ["debug"]);
			defaultHomePath = environment.get("HOME");
			shellEnvironmentSet = true;
		} else {
			if ((environment.get("SHELL") == "") && (environment.get("USER") == "")){
				// No shell is set or username - observed case when running as systemd service under CentOS 7.x
				logBuffer.addLogEntry("runtime_environment: No HOME, SHELL or USER environment variable configuration detected. Expansion of '~' not possible", ["debug"]);
				defaultHomePath = "/root";
				shellEnvironmentSet = false;
			} else {
				// A shell & valid user is set, but no HOME is set, use ~ which can be expanded
				logBuffer.addLogEntry("runtime_environment: SHELL and USER environment variable detected, expansion of '~' should be possible", ["debug"]);
				defaultHomePath = "~";
				shellEnvironmentSet = true;
			}
		}
		// outcome of setting defaultHomePath
		logBuffer.addLogEntry("runtime_environment: Calculated defaultHomePath: " ~ defaultHomePath, ["debug"]);
		
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
			logBuffer.addLogEntry("configDirName: CLI override to set configDirName to: " ~ confdirOption, ["debug"]);
			
			if (canFind(confdirOption,"~")) {
				// A ~ was found
				logBuffer.addLogEntry("configDirName: A '~' was found in configDirName, using the calculated 'defaultHomePath' to replace '~'", ["debug"]);
				configDirName = defaultHomePath ~ strip(confdirOption,"~","~");
			} else {
				configDirName = confdirOption;
			}
		} else {
			// Determine the base directory relative to which user specific configuration files should be stored
			if (environment.get("XDG_CONFIG_HOME") != ""){
				logBuffer.addLogEntry("configDirBase: XDG_CONFIG_HOME environment variable set", ["debug"]);
				configDirBase = environment.get("XDG_CONFIG_HOME");
			} else {
				// XDG_CONFIG_HOME does not exist on systems where X11 is not present - ie - headless systems / servers
				logBuffer.addLogEntry("configDirBase: WARNING - no XDG_CONFIG_HOME environment variable set", ["debug"]);
				configDirBase = buildNormalizedPath(buildPath(defaultHomePath, ".config"));
				// Also set up a path to pre-shipped shared configs (which can be overridden by supplying a config file in userspace)
				systemConfigDirBase = "/etc";
			}
			
			// Output configDirBase calculation
			logBuffer.addLogEntry("configDirBase: " ~ configDirBase, ["debug"]);
			// Set the calculated application configuration directory
			logBuffer.addLogEntry("configDirName: Configuring application to use calculated config path", ["debug"]);
			// configDirBase contains the correct path so we do not need to check for presence of '~'
			configDirName = buildNormalizedPath(buildPath(configDirBase, "onedrive"));
			// systemConfigDirBase contains the correct path so we do not need to check for presence of '~'
			systemConfigDirName = buildNormalizedPath(buildPath(systemConfigDirBase, "onedrive"));
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
					logBuffer.addLogEntry("ERROR: --confdir entered value is an existing file instead of an existing directory");
				} else {
					// other error
					logBuffer.addLogEntry("ERROR: " ~ confdirOption ~ " is a file rather than a directory");
				}
				// Must exit
				exit(EXIT_FAILURE);	
			}
		}
		
		// Update application set variables based on configDirName
		// - What is the full path for the 'refresh_token'
		refreshTokenFilePath = buildNormalizedPath(buildPath(configDirName, "refresh_token"));
		// - What is the full path for the 'delta_link'
		deltaLinkFilePath = buildNormalizedPath(buildPath(configDirName, "delta_link"));
		// - What is the full path for the 'items.sqlite3' - the database cache file
		databaseFilePath = buildNormalizedPath(buildPath(configDirName, "items.sqlite3"));
		// - What is the full path for the 'items-dryrun.sqlite3' - the dry-run database cache file
		databaseFilePathDryRun = buildNormalizedPath(buildPath(configDirName, "items-dryrun.sqlite3"));
		// - What is the full path for the 'resume_upload'
		uploadSessionFilePath = buildNormalizedPath(buildPath(configDirName, "session_upload"));
		// - What is the full path for the 'sync_list' file
		syncListFilePath = buildNormalizedPath(buildPath(configDirName, "sync_list"));
		// - What is the full path for the 'config' - the user file to configure the application
		userConfigFilePath = buildNormalizedPath(buildPath(configDirName, "config"));
		// - What is the full path for the system 'config' file if it is required
		systemConfigFilePath = buildNormalizedPath(buildPath(systemConfigDirName, "config"));
		
		// To determine if any configuration items has changed, where a --resync would be required, we need to have a hash file for the following items
		// - 'config.backup' file
		// - applicable 'config' file
		// - 'sync_list' file
		// - 'business_shared_items' file
		configBackupFile = buildNormalizedPath(buildPath(configDirName, ".config.backup"));
		configHashFile = buildNormalizedPath(buildPath(configDirName, ".config.hash"));
		syncListHashFile = buildNormalizedPath(buildPath(configDirName, ".sync_list.hash"));
						
		// Debug Output for application set variables based on configDirName
		logBuffer.addLogEntry("refreshTokenFilePath =   " ~ refreshTokenFilePath, ["debug"]);
		logBuffer.addLogEntry("deltaLinkFilePath =      " ~ deltaLinkFilePath, ["debug"]);
		logBuffer.addLogEntry("databaseFilePath =       " ~ databaseFilePath, ["debug"]);
		logBuffer.addLogEntry("databaseFilePathDryRun = " ~ databaseFilePathDryRun, ["debug"]);
		logBuffer.addLogEntry("uploadSessionFilePath =  " ~ uploadSessionFilePath, ["debug"]);
		logBuffer.addLogEntry("userConfigFilePath =     " ~ userConfigFilePath, ["debug"]);
		logBuffer.addLogEntry("syncListFilePath =       " ~ syncListFilePath, ["debug"]);
		logBuffer.addLogEntry("systemConfigFilePath =   " ~ systemConfigFilePath, ["debug"]);
		logBuffer.addLogEntry("configBackupFile =       " ~ configBackupFile, ["debug"]);
		logBuffer.addLogEntry("configHashFile =         " ~ configHashFile, ["debug"]);
		logBuffer.addLogEntry("syncListHashFile =       " ~ syncListHashFile, ["debug"]);
		
		// Configure the Hash and Backup File Permission Value
		string valueToConvert = to!string(defaultFilePermissionMode);
		auto convertedValue = parse!long(valueToConvert, 8);
		convertedPermissionValue = to!int(convertedValue);
		
		// Do not try and load any user configuration file if --help was used
		if (helpRequested) {
			return true;
		} else {
			// Initialise the application using the configuration file if it exists
			if (!exists(userConfigFilePath)) {
				// 'user' configuration file does not exist
				// Is there a system configuration file?
				if (!exists(systemConfigFilePath)) {
					// 'system' configuration file does not exist
					logBuffer.addLogEntry("No user or system config file found, using application defaults", ["verbose"]);
					applicableConfigFilePath = userConfigFilePath;
					configurationInitialised = true;
				} else {
					// 'system' configuration file exists
					// can we load the configuration file without error?
					if (loadConfigFile(systemConfigFilePath)) {
						// configuration file loaded without error
						logBuffer.addLogEntry("System configuration file successfully loaded");
						
						// Set 'applicableConfigFilePath' to equal the 'config' we loaded
						applicableConfigFilePath = systemConfigFilePath;
						// Update the configHashFile path value to ensure we are using the system 'config' file for the hash
						configHashFile = buildNormalizedPath(buildPath(systemConfigDirName, ".config.hash"));
						configurationInitialised = true;
					} else {
						// there was a problem loading the configuration file
						logBuffer.addLogEntry(); // used instead of an empty 'writeln();' to ensure the line break is correct in the buffered console output ordering
						logBuffer.addLogEntry("System configuration file has errors - please check your configuration");
					}
				}						
			} else {
				// 'user' configuration file exists
				// can we load the configuration file without error?
				if (loadConfigFile(userConfigFilePath)) {
					// configuration file loaded without error
					logBuffer.addLogEntry("Configuration file successfully loaded");
					
					// Set 'applicableConfigFilePath' to equal the 'config' we loaded
					applicableConfigFilePath = userConfigFilePath;
					configurationInitialised = true;
				} else {
					// there was a problem loading the configuration file
					logBuffer.addLogEntry(); // used instead of an empty 'writeln();' to ensure the line break is correct in the buffered console output ordering
					logBuffer.addLogEntry("Configuration file has errors - please check your configuration");
				}
			}
			
			// Advise the user path that we will use for the application state data
			if (canFind(applicableConfigFilePath, configDirName)) {
				logBuffer.addLogEntry("Using 'user' configuration path for application state data: " ~ configDirName, ["verbose"]);
			} else {
				if (canFind(applicableConfigFilePath, systemConfigDirName)) {
					logBuffer.addLogEntry("Using 'system' configuration path for application state data: " ~ systemConfigDirName, ["verbose"]);
				}
			}
		}
		
		// return if the configuration was initialised
		return configurationInitialised;
	}
	
	// Create a backup of the 'config' file if it does not exist
	void createBackupConfigFile() {
		if (!getValueBool("dry_run")) {
			// Is there a backup of the config file if the config file exists?
			if (exists(applicableConfigFilePath)) {
				logBuffer.addLogEntry("Creating a backup of the applicable config file", ["debug"]);
				// create backup copy of current config file
				std.file.copy(applicableConfigFilePath, configBackupFile);
				// File Copy should only be readable by the user who created it - 0600 permissions needed
				configBackupFile.setAttributes(convertedPermissionValue);
			}
		} else {
			// --dry-run scenario ... technically we should not be making any local file changes .......
			logBuffer.addLogEntry("DRY RUN: Not creating backup config file as --dry-run has been used");
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
		try {
			logBuffer.addLogEntry("Reading configuration file: " ~ filename);
			readText(filename);
		} catch (std.file.FileException e) {
			logBuffer.addLogEntry("ERROR: Unable to access " ~ e.msg);
			return false;
		}
		
		auto file = File(filename, "r");
		string lineBuffer;
		
		scope(exit) {
			file.close();
		}
		
		scope(failure) {
			file.close();
		}
		
		foreach (line; file.byLine()) {
			lineBuffer = stripLeft(line).to!string;
			if (lineBuffer.empty || lineBuffer[0] == ';' || lineBuffer[0] == '#') continue;
			auto c = lineBuffer.matchFirst(configRegex);
			if (c.empty) {
				logBuffer.addLogEntry("Malformed config line: " ~ lineBuffer);
				logBuffer.addLogEntry();
				logBuffer.addLogEntry("Please review the documentation on how to correctly configure this application.");
				forceExit();
			}

			c.popFront(); // skip the whole match
			string key = c.front.dup;
			c.popFront();

			// Handle deprecated keys
			switch (key) {
				case "min_notify_changes":
				case "force_http_2":
					logBuffer.addLogEntry("The option '" ~ key ~ "' has been depreciated and will be ignored. Please read the updated documentation and update your client configuration to remove this option.");
					continue;
				case "sync_business_shared_folders":
					logBuffer.addLogEntry();
					logBuffer.addLogEntry("The option 'sync_business_shared_folders' has been depreciated and the process for synchronising Microsoft OneDrive Business Shared Folders has changed.");
					logBuffer.addLogEntry("Please review the revised documentation on how to correctly configure this application feature.");
					logBuffer.addLogEntry("You must update your client configuration and make changes to your local filesystem and online data to use this capability.");
					return false;
				default:
					break;
			}

			// Process other keys
			if (key in boolValues) {
				// Only accept "true" as true value.
				setValueBool(key, c.front.dup == "true" ? true : false);
				if (key == "skip_dotfiles") configFileSkipDotfiles = true;
				if (key == "skip_symlinks") configFileSkipSymbolicLinks = true;
				if (key == "sync_business_shared_items") configFileSyncBusinessSharedItems = true;
			} else if (key in stringValues) {
				string value = c.front.dup;
				setValueString(key, value);
				if (key == "sync_dir") {
					if (!strip(value).empty) {
						configFileSyncDir = value;
					} else {
						logBuffer.addLogEntry();
						logBuffer.addLogEntry("Invalid value for key in config file: " ~ key);
						logBuffer.addLogEntry("ERROR: sync_dir in config file cannot be empty - this is a fatal error and must be corrected");
						logBuffer.addLogEntry();
						forceExit();
					}
				} else if (key == "skip_file") {
					// Handle multiple 'config' file entries of skip_file
					if (configFileSkipFile.empty) {
						// currently no entry exists
						configFileSkipFile = c.front.dup;
					} else {
						// add to existing entry
						configFileSkipFile = configFileSkipFile ~ "|" ~ to!string(c.front.dup);
						setValueString("skip_file", configFileSkipFile);
					}
				} else if (key == "skip_dir") {
					// Handle multiple entries of skip_dir
					if (configFileSkipDir.empty) {
						// currently no entry exists
						configFileSkipDir = c.front.dup;
					} else {
						// add to existing entry
						configFileSkipDir = configFileSkipDir ~ "|" ~ to!string(c.front.dup);
						setValueString("skip_dir", configFileSkipDir);
					}
				} else if (key == "single_directory") {
					string configFileSingleDirectory = strip(value, "\"");
					setValueString("single_directory", configFileSingleDirectory);
				} else if (key == "azure_ad_endpoint") {
					switch (value) {
						case "":
							logBuffer.addLogEntry("Using default config option for Global Azure AD Endpoints");
							break;
						case "USL4":
							logBuffer.addLogEntry("Using config option for Azure AD for US Government Endpoints");
							break;
						case "USL5":
							logBuffer.addLogEntry("Using config option for Azure AD for US Government Endpoints (DOD)");
							break;
						case "DE":
							logBuffer.addLogEntry("Using config option for Azure AD Germany");
							break;
						case "CN":
							logBuffer.addLogEntry("Using config option for Azure AD China operated by VNET");
							break;
						default:
							logBuffer.addLogEntry("Unknown Azure AD Endpoint - using Global Azure AD Endpoints");
					}
				} else if (key == "application_id") {
					string tempApplicationId = strip(value);
					if (tempApplicationId.empty) {
						logBuffer.addLogEntry("Invalid value for key in config file - using default value: " ~ key);
						logBuffer.addLogEntry("application_id in config file cannot be empty - using default application_id", ["debug"]);
						setValueString("application_id", defaultApplicationId);
					}
				} else if (key == "drive_id") {
					string tempDriveId = strip(value);
					if (tempDriveId.empty) {
						logBuffer.addLogEntry();
						logBuffer.addLogEntry("Invalid value for key in config file: " ~ key);
						logBuffer.addLogEntry("drive_id in config file cannot be empty - this is a fatal error and must be corrected by removing this entry from your config file.", ["debug"]);
						logBuffer.addLogEntry();
						forceExit();
					} else {
						configFileDriveId = tempDriveId;
					}
				} else if (key == "log_dir") {
					string tempLogDir = strip(value);
					if (tempLogDir.empty) {
						logBuffer.addLogEntry("Invalid value for key in config file - using default value: " ~ key);
						logBuffer.addLogEntry("log_dir in config file cannot be empty - using default log_dir", ["debug"]);
						setValueString("log_dir", defaultLogFileDir);
					}
				}
			} else if (key in longValues) {
				ulong thisConfigValue;
				try {
					thisConfigValue = to!ulong(c.front.dup);
				} catch (std.conv.ConvException) {
					logBuffer.addLogEntry("Invalid value for key in config file: " ~ key);
					return false;
				}
				setValueLong(key, thisConfigValue);
				if (key == "monitor_interval") { // if key is 'monitor_interval' the value must be 300 or greater
					ulong tempValue = thisConfigValue;
					// the temp value needs to be 300 or greater
					if (tempValue < 300) {
						logBuffer.addLogEntry("Invalid value for key in config file - using default value: " ~ key);
						tempValue = 300;
					}
					setValueLong("monitor_interval", tempValue);
				} else if (key == "monitor_fullscan_frequency") { // if key is 'monitor_fullscan_frequency' the value must be 12 or greater
					ulong tempValue = thisConfigValue;
					// the temp value needs to be 12 or greater
					if (tempValue < 12) {
						// If this is not set to zero (0) then we are not disabling 'monitor_fullscan_frequency'
						if (tempValue != 0) {
							// invalid value
							logBuffer.addLogEntry("Invalid value for key in config file - using default value: " ~ key);
							tempValue = 12;
						}
					}
					setValueLong("monitor_fullscan_frequency", tempValue);
				} else if (key == "space_reservation") { // if key is 'space_reservation' we have to calculate MB -> bytes
					ulong tempValue = thisConfigValue;
					// a value of 0 needs to be made at least 1MB .. 
					if (tempValue == 0) {
						logBuffer.addLogEntry("Invalid value for key in config file - using 1MB: " ~ key);
						tempValue = 1;
					}
					setValueLong("space_reservation", tempValue * 2^^20);
				} else if (key == "ip_protocol_version") {
					ulong tempValue = thisConfigValue;
					if (tempValue > 2) {
						logBuffer.addLogEntry("Invalid value for key in config file - using default value: " ~ key);
						tempValue = defaultIpProtocol;
					}
					setValueLong("ip_protocol_version", tempValue);
				} else if (key == "threads") {
					ulong tempValue = thisConfigValue;
					if (tempValue > 16) {
						logBuffer.addLogEntry("Invalid value for key in config file - using default value: " ~ key);
						tempValue = defaultConcurrentThreads;
					}
					setValueLong("threads", tempValue);
				}
			} else {
				logBuffer.addLogEntry("Unknown key in config file: " ~ key);
				return false;
			}
		}
		// Return that we were able to read in the config file and parse the options without issue
		return true;
	}

	// Update the application configuration based on CLI passed in parameters
	void updateFromArgs(string[] cliArgs) {
		// Add additional CLI options that are NOT configurable via config file
		stringValues["create_directory"] = "";
		stringValues["create_share_link"] = "";
		stringValues["destination_directory"] = "";
		stringValues["get_file_link"] = "";
		stringValues["modified_by"] = "";
		stringValues["sharepoint_library_name"] = "";
		stringValues["remove_directory"] = "";
		stringValues["single_directory"] = "";
		stringValues["source_directory"] = "";
		stringValues["auth_files"] = "";
		stringValues["auth_response"] = "";
		boolValues["display_config"] = false;
		boolValues["display_sync_status"] = false;
		boolValues["display_quota"] = false;
		boolValues["print_token"] = false;
		boolValues["logout"] = false;
		boolValues["reauth"] = false;
		boolValues["monitor"] = false;
		boolValues["synchronize"] = false;
		boolValues["force"] = false;
		boolValues["list_business_shared_items"] = false;
		boolValues["sync_business_shared_files"] = false;
		boolValues["force_sync"] = false;
		boolValues["with_editing_perms"] = false;
		
		// Specific options for CLI input handling
		stringValues["sync_dir_cli"] = "";
		
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
				"display-quota",
					"Display the quota status of the client - no sync will be performed.",
					&boolValues["display_quota"],
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
				"get-sharepoint-drive-id",
					"Query and return the Office 365 Drive ID for a given Office 365 SharePoint Shared Library",
					&stringValues["sharepoint_library_name"],
				"get-O365-drive-id",
					"Query and return the Office 365 Drive ID for a given Office 365 SharePoint Shared Library (DEPRECIATED)",
					&stringValues["sharepoint_library_name"],
				"list-shared-items",
					"List OneDrive Business Shared Items",
					&boolValues["list_business_shared_items"],
				"sync-shared-files",
					"Sync OneDrive Business Shared Files to the local filesystem",
					&boolValues["sync_business_shared_files"],
				"local-first",
					"Synchronize from the local directory source first, before downloading changes from OneDrive.",
					&boolValues["local_first"],
				"log-dir",
					"Directory where logging output is saved to, needs to end with a slash.",
					&stringValues["log_dir"],
				"logout",
					"Logout the current user",
					&boolValues["logout"],
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
				"print-access-token",
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
					"Specify the local directory used for synchronisation to OneDrive",
					&stringValues["sync_dir_cli"],
				"sync|s",
					"Perform a synchronisation with Microsoft OneDrive",
					&boolValues["synchronize"],
				"synchronize",
					"Perform a synchronisation with Microsoft OneDrive (DEPRECIATED)",
					&boolValues["synchronize"],
				"sync-root-files",
					"Sync all files in sync_dir root when using sync_list.",
					&boolValues["sync_root_files"],
				"upload-only",
					"Replicate the locally configured sync_dir state to OneDrive, by only uploading local changes to OneDrive. Do not download changes from OneDrive.",
					&boolValues["upload_only"],
				"confdir",
					"Set the directory used to store the configuration files",
					&tmpStr,
				"verbose|v+",
					"Print more details, useful for debugging (repeat for extra debugging)",
					&tmpVerb,
				"version",
					"Print the version and exit",
					&tmpBol,
				"with-editing-perms",
					"Create a read-write shareable link for an existing file on OneDrive when used with --create-share-link <file>",
					&boolValues["with_editing_perms"]
			);
			
			// Was --syncdir used?
			if (!getValueString("sync_dir_cli").empty) {
				// Build the line we need to update and/or write out
				string newConfigOptionSyncDirLine = "sync_dir = \"" ~ getValueString("sync_dir_cli") ~ "\"";
				
				// Does a 'config' file exist?
				if (!exists(applicableConfigFilePath)) {
					// No existing 'config' file exists, create it, and write the 'sync_dir' configuration to it
					if (!getValueBool("dry_run")) {
						std.file.write(applicableConfigFilePath, newConfigOptionSyncDirLine);
						// Config file should only be readable by the user who created it - 0600 permissions needed
						applicableConfigFilePath.setAttributes(convertedPermissionValue);
					}
				} else {
					// an existing config file exists .. so this now becomes tricky
					// string replace 'sync_dir' if it exists, in the existing 'config' file, but only if 'sync_dir' (already read in) is different from 'sync_dir_cli'
					if ( (getValueString("sync_dir")) != (getValueString("sync_dir_cli")) ) {
						// values are different
						File applicableConfigFilePathFileHandle = File(applicableConfigFilePath, "r");
						string lineBuffer;
						string[] newConfigFileEntries;
						
						// read applicableConfigFilePath line by line
						auto range = applicableConfigFilePathFileHandle.byLine();
						
						// for each 'config' file line
						foreach (line; range) {
							lineBuffer = stripLeft(line).to!string;
							if (lineBuffer.length == 0 || lineBuffer[0] == ';' || lineBuffer[0] == '#') {
								newConfigFileEntries ~= [lineBuffer];
							} else {
								auto c = lineBuffer.matchFirst(configRegex);
								if (!c.empty) {
									c.popFront(); // skip the whole match
									string key = c.front.dup;
									if (key == "sync_dir") {
										// lineBuffer is the line we want to keep
										newConfigFileEntries ~= [newConfigOptionSyncDirLine];
									} else {
										newConfigFileEntries ~= [lineBuffer];
									}
								}
							}
						}
						
						// close original 'config' file if still open
						if (applicableConfigFilePathFileHandle.isOpen()) {
							// close open file
							applicableConfigFilePathFileHandle.close();
						}
						
						// Update the existing item in the file line array
						if (!getValueBool("dry_run")) {
							// Open the file with write access using 'w' mode to overwrite existing content
							File applicableConfigFilePathFileHandleWrite = File(applicableConfigFilePath, "w");
							
							// Write each line from the 'newConfigFileEntries' array to the file
							foreach (line; newConfigFileEntries) {
								applicableConfigFilePathFileHandleWrite.writeln(line);
							}

							// Flush and close the file handle to ensure all data is written
							if (applicableConfigFilePathFileHandleWrite.isOpen()) {
								applicableConfigFilePathFileHandleWrite.flush();
								applicableConfigFilePathFileHandleWrite.close();
							}
						}
					}
				}
				
				// Final - configure sync_dir with the value of sync_dir_cli so that it can be used as part of the application configuration and detect change
				setValueString("sync_dir", getValueString("sync_dir_cli"));
			}
			
			// Was --auth-files used?
			if (!getValueString("auth_files").empty) {
				// --auth-files used, need to validate that '~' was not used as a path identifier, and if yes, perform the correct expansion
				string[] tempAuthFiles = getValueString("auth_files").split(":");
				string tempAuthUrl = tempAuthFiles[0];
				string tempResponseUrl = tempAuthFiles[1];
				string newAuthFilesString;
				
				// shell expansion if required
				if (!shellEnvironmentSet){
					// No shell environment is set, no automatic expansion of '~' if present is possible
					// Does the 'currently configured' tempAuthUrl include a ~
					if (canFind(tempAuthUrl, "~")) {	
						// A ~ was found in auth_files(authURL)
						logBuffer.addLogEntry("auth_files: A '~' was found in 'auth_files(authURL)', using the calculated 'homePath' to replace '~' as no SHELL or USER environment variable set", ["debug"]);
						tempAuthUrl = buildNormalizedPath(buildPath(defaultHomePath, strip(tempAuthUrl, "~")));
					}
					
					// Does the 'currently configured' tempAuthUrl include a ~
					if (canFind(tempResponseUrl, "~")) {
						// A ~ was found in auth_files(authURL)
						logBuffer.addLogEntry("auth_files: A '~' was found in 'auth_files(tempResponseUrl)', using the calculated 'homePath' to replace '~' as no SHELL or USER environment variable set", ["debug"]);
						tempResponseUrl = buildNormalizedPath(buildPath(defaultHomePath, strip(tempResponseUrl, "~")));
					}
				} else {
					// Shell environment is set, automatic expansion of '~' if present is possible
					// Does the 'currently configured' tempAuthUrl include a ~
					if (canFind(tempAuthUrl, "~")) {
						// A ~ was found in auth_files(authURL)
						logBuffer.addLogEntry("auth_files: A '~' was found in the configured 'auth_files(authURL)', automatically expanding as SHELL and USER environment variable is set", ["debug"]);
						tempAuthUrl = expandTilde(tempAuthUrl);
					}
					
					// Does the 'currently configured' tempAuthUrl include a ~
					if (canFind(tempResponseUrl, "~")) {
						// A ~ was found in auth_files(authURL)
						logBuffer.addLogEntry("auth_files: A '~' was found in the configured 'auth_files(tempResponseUrl)', automatically expanding as SHELL and USER environment variable is set", ["debug"]);
						tempResponseUrl = expandTilde(tempResponseUrl);
					}
				}
				
				// Build new string
				newAuthFilesString = tempAuthUrl ~ ":" ~ tempResponseUrl;
				logBuffer.addLogEntry("auth_files - updated value: " ~ newAuthFilesString, ["debug"]);
				setValueString("auth_files", newAuthFilesString);
			}
			
			if (opt.helpWanted) {
				outputLongHelp(opt.options);
				exit(EXIT_SUCCESS);
			}
		} catch (GetOptException e) {
			// getOpt error - must use writeln() here
			writeln(e.msg);
			writeln("Try 'onedrive -h' for more information");
			exit(EXIT_FAILURE);
		} catch (Exception e) {
			// general error - must use writeln() here
			writeln(e.msg);
			writeln("Try 'onedrive -h' for more information");
			exit(EXIT_FAILURE);
		}
	}
	
	// Check the arguments passed in for any that will be depreciated
	void checkDepreciatedOptions(string[] cliArgs) {
	
		bool depreciatedCommandsFound = false;
	
		foreach (cliArg; cliArgs) {
			// Check each CLI arg for items that have been depreciated
			
			// --synchronize depreciated in v2.5.0, will be removed in future version
			if (cliArg == "--synchronize") {
				logBuffer.addLogEntry(); // used instead of an empty 'writeln();' to ensure the line break is correct in the buffered console output ordering
				logBuffer.addLogEntry("DEPRECIATION WARNING: --synchronize has been depreciated in favour of --sync or -s");
				depreciatedCommandsFound = true;
			}
			
			// --get-O365-drive-id depreciated in v2.5.0, will be removed in future version
			if (cliArg == "--get-O365-drive-id") {
				logBuffer.addLogEntry(); // used instead of an empty 'writeln();' to ensure the line break is correct in the buffered console output ordering
				logBuffer.addLogEntry("DEPRECIATION WARNING: --get-O365-drive-id has been depreciated in favour of --get-sharepoint-drive-id");
				depreciatedCommandsFound = true;
			}
		}
	
		if (depreciatedCommandsFound) {
			logBuffer.addLogEntry("DEPRECIATION WARNING: Depreciated commands will be removed in a future release.");
			logBuffer.addLogEntry(); // used instead of an empty 'writeln();' to ensure the line break is correct in the buffered console output ordering
		}
	}
	
	// Display the applicable application configuration
	void displayApplicationConfiguration() {
		if (getValueBool("display_running_config")) {
			logBuffer.addLogEntry("--------------- Application Runtime Configuration ---------------");
		}
		
		// Display application version
		logBuffer.addLogEntry("onedrive version                             = " ~ applicationVersion);
		
		// Display all of the pertinent configuration options
		logBuffer.addLogEntry("Config path                                  = " ~ configDirName);
		// Does a config file exist or are we using application defaults
		logBuffer.addLogEntry("Config file found in config path             = " ~ to!string(exists(applicableConfigFilePath)));
		
		// Is config option drive_id configured?
		logBuffer.addLogEntry("Config option 'drive_id'                     = " ~ getValueString("drive_id"));
		
		// Config Options as per 'config' file
		logBuffer.addLogEntry("Config option 'sync_dir'                     = " ~ getValueString("sync_dir"));
		
		// logging and notifications
		logBuffer.addLogEntry("Config option 'enable_logging'               = " ~ to!string(getValueBool("enable_logging")));
		logBuffer.addLogEntry("Config option 'log_dir'                      = " ~ getValueString("log_dir"));
		logBuffer.addLogEntry("Config option 'disable_notifications'        = " ~ to!string(getValueBool("disable_notifications")));
		
		// skip files and directory and 'matching' policy
		logBuffer.addLogEntry("Config option 'skip_dir'                     = " ~ getValueString("skip_dir"));
		logBuffer.addLogEntry("Config option 'skip_dir_strict_match'        = " ~ to!string(getValueBool("skip_dir_strict_match")));
		logBuffer.addLogEntry("Config option 'skip_file'                    = " ~ getValueString("skip_file"));
		logBuffer.addLogEntry("Config option 'skip_dotfiles'                = " ~ to!string(getValueBool("skip_dotfiles")));
		logBuffer.addLogEntry("Config option 'skip_symlinks'                = " ~ to!string(getValueBool("skip_symlinks")));
		
		// --monitor sync process options
		logBuffer.addLogEntry("Config option 'monitor_interval'             = " ~ to!string(getValueLong("monitor_interval")));
		logBuffer.addLogEntry("Config option 'monitor_log_frequency'        = " ~ to!string(getValueLong("monitor_log_frequency")));
		logBuffer.addLogEntry("Config option 'monitor_fullscan_frequency'   = " ~ to!string(getValueLong("monitor_fullscan_frequency")));
		
		// sync process and method
		logBuffer.addLogEntry("Config option 'read_only_auth_scope'         = " ~ to!string(getValueBool("read_only_auth_scope")));
		logBuffer.addLogEntry("Config option 'dry_run'                      = " ~ to!string(getValueBool("dry_run")));
		logBuffer.addLogEntry("Config option 'upload_only'                  = " ~ to!string(getValueBool("upload_only")));
		logBuffer.addLogEntry("Config option 'download_only'                = " ~ to!string(getValueBool("download_only")));
		logBuffer.addLogEntry("Config option 'local_first'                  = " ~ to!string(getValueBool("local_first")));
		logBuffer.addLogEntry("Config option 'check_nosync'                 = " ~ to!string(getValueBool("check_nosync")));
		logBuffer.addLogEntry("Config option 'check_nomount'                = " ~ to!string(getValueBool("check_nomount")));
		logBuffer.addLogEntry("Config option 'resync'                       = " ~ to!string(getValueBool("resync")));
		logBuffer.addLogEntry("Config option 'resync_auth'                  = " ~ to!string(getValueBool("resync_auth")));
		logBuffer.addLogEntry("Config option 'cleanup_local_files'          = " ~ to!string(getValueBool("cleanup_local_files")));

		// data integrity
		logBuffer.addLogEntry("Config option 'classify_as_big_delete'       = " ~ to!string(getValueLong("classify_as_big_delete")));
		logBuffer.addLogEntry("Config option 'disable_upload_validation'    = " ~ to!string(getValueBool("disable_upload_validation")));
		logBuffer.addLogEntry("Config option 'disable_download_validation'  = " ~ to!string(getValueBool("disable_download_validation")));
		logBuffer.addLogEntry("Config option 'bypass_data_preservation'     = " ~ to!string(getValueBool("bypass_data_preservation")));
		logBuffer.addLogEntry("Config option 'no_remote_delete'             = " ~ to!string(getValueBool("no_remote_delete")));
		logBuffer.addLogEntry("Config option 'remove_source_files'          = " ~ to!string(getValueBool("remove_source_files")));
		logBuffer.addLogEntry("Config option 'sync_dir_permissions'         = " ~ to!string(getValueLong("sync_dir_permissions")));
		logBuffer.addLogEntry("Config option 'sync_file_permissions'        = " ~ to!string(getValueLong("sync_file_permissions")));
		logBuffer.addLogEntry("Config option 'space_reservation'            = " ~ to!string(getValueLong("space_reservation")));
		
		// curl operations
		logBuffer.addLogEntry("Config option 'application_id'               = " ~ getValueString("application_id"));
		logBuffer.addLogEntry("Config option 'azure_ad_endpoint'            = " ~ getValueString("azure_ad_endpoint"));
		logBuffer.addLogEntry("Config option 'azure_tenant_id'              = " ~ getValueString("azure_tenant_id"));
		logBuffer.addLogEntry("Config option 'user_agent'                   = " ~ getValueString("user_agent"));
		logBuffer.addLogEntry("Config option 'force_http_11'                = " ~ to!string(getValueBool("force_http_11")));
		logBuffer.addLogEntry("Config option 'debug_https'                  = " ~ to!string(getValueBool("debug_https")));
		logBuffer.addLogEntry("Config option 'rate_limit'                   = " ~ to!string(getValueLong("rate_limit")));
		logBuffer.addLogEntry("Config option 'operation_timeout'            = " ~ to!string(getValueLong("operation_timeout")));
		logBuffer.addLogEntry("Config option 'dns_timeout'                  = " ~ to!string(getValueLong("dns_timeout")));
		logBuffer.addLogEntry("Config option 'connect_timeout'              = " ~ to!string(getValueLong("connect_timeout")));
		logBuffer.addLogEntry("Config option 'data_timeout'                 = " ~ to!string(getValueLong("data_timeout")));
		logBuffer.addLogEntry("Config option 'ip_protocol_version'          = " ~ to!string(getValueLong("ip_protocol_version")));
		logBuffer.addLogEntry("Config option 'threads'                      = " ~ to!string(getValueLong("threads")));
		
		// Is sync_list configured ?
		if (exists(syncListFilePath)){
			logBuffer.addLogEntry(); // used instead of an empty 'writeln();' to ensure the line break is correct in the buffered console output ordering
			logBuffer.addLogEntry("Selective sync 'sync_list' configured        = true");
			logBuffer.addLogEntry("sync_list config option 'sync_root_files'    = " ~ to!string(getValueBool("sync_root_files")));
			logBuffer.addLogEntry("sync_list contents:");
			// Output the sync_list contents
			auto syncListFile = File(syncListFilePath, "r");
			auto range = syncListFile.byLine();
			foreach (line; range)
			{
				logBuffer.addLogEntry(to!string(line));
			}
		} else {
			logBuffer.addLogEntry(); // used instead of an empty 'writeln();' to ensure the line break is correct in the buffered console output ordering
			logBuffer.addLogEntry("Selective sync 'sync_list' configured        = false");
		}
		
		// Is sync_business_shared_items enabled and configured ?
		logBuffer.addLogEntry(); // used instead of an empty 'writeln();' to ensure the line break is correct in the buffered console output ordering
		logBuffer.addLogEntry("Config option 'sync_business_shared_items'   = " ~ to!string(getValueBool("sync_business_shared_items")));
		if (getValueBool("sync_business_shared_items")) {
			// display what the shared files directory will be
			logBuffer.addLogEntry("Config option 'Shared Files Directory'       = " ~ configuredBusinessSharedFilesDirectoryName);
		}
		
		// Are webhooks enabled?
		logBuffer.addLogEntry(); // used instead of an empty 'writeln();' to ensure the line break is correct in the buffered console output ordering
		logBuffer.addLogEntry("Config option 'webhook_enabled'              = " ~ to!string(getValueBool("webhook_enabled")));
		if (getValueBool("webhook_enabled")) {
			logBuffer.addLogEntry("Config option 'webhook_public_url'           = " ~ getValueString("webhook_public_url"));
			logBuffer.addLogEntry("Config option 'webhook_listening_host'       = " ~ getValueString("webhook_listening_host"));
			logBuffer.addLogEntry("Config option 'webhook_listening_port'       = " ~ to!string(getValueLong("webhook_listening_port")));
			logBuffer.addLogEntry("Config option 'webhook_expiration_interval'  = " ~ to!string(getValueLong("webhook_expiration_interval")));
			logBuffer.addLogEntry("Config option 'webhook_renewal_interval'     = " ~ to!string(getValueLong("webhook_renewal_interval")));
			logBuffer.addLogEntry("Config option 'webhook_retry_interval'       = " ~ to!string(getValueLong("webhook_retry_interval")));
		}
		
		if (getValueBool("display_running_config")) {
			logBuffer.addLogEntry();
			logBuffer.addLogEntry("--------------------DEVELOPER_OPTIONS----------------------------");
			logBuffer.addLogEntry("Config option 'force_children_scan'          = " ~ to!string(getValueBool("force_children_scan")));
			logBuffer.addLogEntry();
		}
		
		if (getValueBool("display_running_config")) {
			logBuffer.addLogEntry("-----------------------------------------------------------------");
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
			logBuffer.addLogEntry("", ["consoleOnly"]); // new line, console only
			logBuffer.addLogEntry("The usage of --resync will delete your local 'onedrive' client state, thus no record of your current 'sync status' will exist.", ["consoleOnly"]);
			logBuffer.addLogEntry("This has the potential to overwrite local versions of files with perhaps older versions of documents downloaded from OneDrive, resulting in local data loss.", ["consoleOnly"]);
			logBuffer.addLogEntry("If in doubt, backup your local data before using --resync", ["consoleOnly"]);
			logBuffer.addLogEntry("", ["consoleOnly"]); // new line, console only
			logBuffer.addLogEntry("Are you sure you wish to proceed with --resync? [Y/N] ", ["consoleOnlyNoNewLine"]);
						
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
			logBuffer.addLogEntry("--resync warning User Response Entered: " ~ to!string(response), ["debug"]);
			
			// Evaluate user response
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
	
	// Prompt the user to accept the risk of using --force-sync
	bool displayForceSyncRiskForAcceptance() {
		// what is the user risk acceptance?
		bool userRiskAcceptance = false;
		
		// need to prompt user
		char response;
		
		// --force-sync warning message
		logBuffer.addLogEntry("", ["consoleOnly"]); // new line, console only
		logBuffer.addLogEntry("The use of --force-sync will reconfigure the application to use defaults. This may have untold and unknown future impacts.", ["consoleOnly"]);
		logBuffer.addLogEntry("By proceeding in using this option you accept any impacts including any data loss that may occur as a result of using --force-sync.", ["consoleOnly"]);
		logBuffer.addLogEntry("", ["consoleOnly"]); // new line, console only
		logBuffer.addLogEntry("Are you sure you wish to proceed with --force-sync [Y/N] ", ["consoleOnlyNoNewLine"]);
				
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
		logBuffer.addLogEntry("--force-sync warning User Response Entered: " ~ to!string(response), ["debug"]);
		
		// Evaluate user response
		if ((to!string(response) == "y") || (to!string(response) == "Y")) {
			// User has accepted --force-sync risk to proceed
			userRiskAcceptance = true;
			// Are you sure you wish .. does not use writeln();
			write("\n");
		}
		
		// Return the --resync acceptance or not
		return userRiskAcceptance;
	}
	
	// Check the application configuration for any changes that need to trigger a --resync
	// This function is only called if --resync is not present
	bool applicationChangeWhereResyncRequired() {
		// Default is that no resync is required
		bool resyncRequired = false;

		// Consolidate the flags for different configuration changes
		bool[9] configOptionsDifferent;

		// Handle multiple entries of skip_file
		string backupConfigFileSkipFile;
		
		// Handle multiple entries of skip_dir
		string backupConfigFileSkipDir;
		
		// Create and read the required initial hash files
		createRequiredInitialConfigurationHashFiles();
		// Read in the existing hash file values
		readExistingConfigurationHashFiles();

		// Helper lambda for logging and setting the difference flag
		auto logAndSetDifference = (string message, size_t index) {
			logBuffer.addLogEntry(message, ["debug"]);
			configOptionsDifferent[index] = true;
		};

		// Check for changes in the sync_list and business_shared_items files
		if (currentSyncListHash != previousSyncListHash)
			logAndSetDifference("sync_list file has been updated, --resync needed", 0);

		// Check for updates in the config file
		if (currentConfigHash != previousConfigHash) {
			logBuffer.addLogEntry("Application configuration file has been updated, checking if --resync needed");
			logBuffer.addLogEntry("Using this configBackupFile: " ~ configBackupFile, ["debug"]);

			if (exists(configBackupFile)) {
				string[string] backupConfigStringValues;
				backupConfigStringValues["drive_id"] = "";
				backupConfigStringValues["sync_dir"] = "";
				backupConfigStringValues["skip_file"] = "";
				backupConfigStringValues["skip_dir"] = "";
				backupConfigStringValues["skip_dotfiles"] = "";
				backupConfigStringValues["skip_symlinks"] = "";
				backupConfigStringValues["sync_business_shared_items"] = "";

				bool drive_id_present = false;
				bool sync_dir_present = false;
				bool skip_file_present = false;
				bool skip_dir_present = false;
				bool skip_dotfiles_present = false;
				bool skip_symlinks_present = false;
				bool sync_business_shared_items_present = false;

				string configOptionModifiedMessage = " was modified since the last time the application was successfully run, --resync required";
				
				auto configBackupFileHandle = File(configBackupFile, "r");
				scope(exit) {
					if (configBackupFileHandle.isOpen()) {
						configBackupFileHandle.close();
					}
				}

				string lineBuffer;
				auto range = configBackupFileHandle.byLine();
				foreach (line; range) {
					lineBuffer = stripLeft(line).to!string;
					if (lineBuffer.length == 0 || lineBuffer[0] == ';' || lineBuffer[0] == '#') continue;
					auto c = lineBuffer.matchFirst(configRegex);
					if (!c.empty) {
						c.popFront(); // skip the whole match
						string key = c.front.dup;
						logBuffer.addLogEntry("Backup Config Key: " ~ key, ["debug"]);

						auto p = key in backupConfigStringValues;
						if (p) {
							c.popFront();
							string value = c.front.dup;
							// Compare each key value with current config
							if (key == "drive_id") {
								drive_id_present = true;
								if (value != getValueString("drive_id")) {
									logAndSetDifference(key ~ configOptionModifiedMessage, 2);
								}
							}
							if (key == "sync_dir") {
								sync_dir_present = true;
								if (value != getValueString("sync_dir")) {
									logAndSetDifference(key ~ configOptionModifiedMessage, 3);
								}
							}
							
							// skip_file handling
							if (key == "skip_file") {
								skip_file_present = true;
								// Handle multiple entries of skip_file
								if (backupConfigFileSkipFile.empty) {
									// currently no entry exists, include 'defaultSkipFile' entries
									backupConfigFileSkipFile = defaultSkipFile ~ "|" ~ to!string(c.front.dup);
								} else {
									// add to existing backupConfigFileSkipFile entry
									backupConfigFileSkipFile = backupConfigFileSkipFile ~ "|" ~ to!string(c.front.dup);
								}
							}
							
							// skip_dir handling
							if (key == "skip_dir") {
								skip_dir_present = true;
								// Handle multiple entries of skip_dir
								if (backupConfigFileSkipDir.empty) {
									// currently no entry exists
									backupConfigFileSkipDir = c.front.dup;
								} else {
									// add to existing backupConfigFileSkipDir entry
									backupConfigFileSkipDir = backupConfigFileSkipDir ~ "|" ~ to!string(c.front.dup);
								}
							}
							
							if (key == "skip_dotfiles") {
								skip_dotfiles_present = true;
								if (value != to!string(getValueBool("skip_dotfiles"))) {
									logAndSetDifference(key ~ configOptionModifiedMessage, 6);
								}
							}
							if (key == "skip_symlinks") {
								skip_symlinks_present = true;
								if (value != to!string(getValueBool("skip_symlinks"))) {
									logAndSetDifference(key ~ configOptionModifiedMessage, 7);
								}
							}
							if (key == "sync_business_shared_items") {
								sync_business_shared_items_present = true;
								if (value != to!string(getValueBool("sync_business_shared_items"))) {
									logAndSetDifference(key ~ configOptionModifiedMessage, 8);
								}
							}
						}
					}
				}
				
				// skip_file can be specified multiple times
				if (skip_file_present && backupConfigFileSkipFile != configFileSkipFile) logAndSetDifference("skip_file" ~ configOptionModifiedMessage, 4);
				
				// skip_dir can be specified multiple times
				if (skip_dir_present && backupConfigFileSkipDir != configFileSkipDir) logAndSetDifference("skip_dir" ~ configOptionModifiedMessage, 5);
				
				// Check for newly added configuration options
				if (!drive_id_present && configFileDriveId != "") logAndSetDifference("drive_id newly added ... --resync needed", 2);
				if (!sync_dir_present && configFileSyncDir != defaultSyncDir) logAndSetDifference("sync_dir newly added ... --resync needed", 3);
				if (!skip_file_present && configFileSkipFile != defaultSkipFile) logAndSetDifference("skip_file newly added ... --resync needed", 4);
				if (!skip_dir_present && configFileSkipDir != "") logAndSetDifference("skip_dir newly added ... --resync needed", 5);
				if (!skip_dotfiles_present && configFileSkipDotfiles) logAndSetDifference("skip_dotfiles newly added ... --resync needed", 6);
				if (!skip_symlinks_present && configFileSkipSymbolicLinks) logAndSetDifference("skip_symlinks newly added ... --resync needed", 7);
				if (!sync_business_shared_items_present && configFileSyncBusinessSharedItems) logAndSetDifference("sync_business_shared_items newly added ... --resync needed", 8);
			} else {
				logBuffer.addLogEntry("WARNING: no backup config file was found, unable to validate if any changes made");
			}
		}

		// Check CLI options
		if (exists(applicableConfigFilePath)) {
			if (configFileSyncDir != "" && configFileSyncDir != getValueString("sync_dir")) logAndSetDifference("sync_dir: CLI override of config file option, --resync needed", 3);
			if (configFileSkipFile != "" && configFileSkipFile != getValueString("skip_file")) logAndSetDifference("skip_file: CLI override of config file option, --resync needed", 4);
			if (configFileSkipDir != "" && configFileSkipDir != getValueString("skip_dir")) logAndSetDifference("skip_dir: CLI override of config file option, --resync needed", 5);
			if (!configFileSkipDotfiles && getValueBool("skip_dotfiles")) logAndSetDifference("skip_dotfiles: CLI override of config file option, --resync needed", 6);
			if (!configFileSkipSymbolicLinks && getValueBool("skip_symlinks")) logAndSetDifference("skip_symlinks: CLI override of config file option, --resync needed", 7);
		}

		// Aggregate the result to determine if a resync is required
		foreach (optionDifferent; configOptionsDifferent) {
			if (optionDifferent) {
				resyncRequired = true;
				break;
			}
		}
		
		// Final override
		// In certain situations, regardless of config 'resync' needed status, ignore this so that the application can display 'non-syncable' information
		// Options that should now be looked at are:
		// --list-shared-items
		if (getValueBool("list_business_shared_items")) resyncRequired = false;
		
		// Return the calculated boolean
		return resyncRequired;
	}
	
	// Cleanup hash files that require to be cleaned up when a --resync is issued
	void cleanupHashFilesDueToResync() {
		if (!getValueBool("dry_run")) {
			// cleanup hash files
			logBuffer.addLogEntry("Cleaning up configuration hash files", ["debug"]);
			safeRemove(configHashFile);
			safeRemove(syncListHashFile);
		} else {
			// --dry-run scenario ... technically we should not be making any local file changes .......
			logBuffer.addLogEntry("DRY RUN: Not removing hash files as --dry-run has been used");
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
				logBuffer.addLogEntry("Updating applicable config file hash", ["debug"]);
				std.file.write(configHashFile, computeQuickXorHash(applicableConfigFilePath));
				// Hash file should only be readable by the user who created it - 0600 permissions needed
				configHashFile.setAttributes(convertedPermissionValue);
			}
			// Update 'sync_list' files
			if (exists(syncListFilePath)) {
				// update sync_list hash
				logBuffer.addLogEntry("Updating sync_list hash", ["debug"]);
				std.file.write(syncListHashFile, computeQuickXorHash(syncListFilePath));
				// Hash file should only be readable by the user who created it - 0600 permissions needed
				syncListHashFile.setAttributes(convertedPermissionValue);
			}
		} else {
			// --dry-run scenario ... technically we should not be making any local file changes .......
			logBuffer.addLogEntry("DRY RUN: Not updating hash files as --dry-run has been used");
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
	}
	
	// Read in the text values of the previous configurations
	int readExistingConfigurationHashFiles() {
		if (exists(configHashFile)) {
			try {
				previousConfigHash = readText(configHashFile);
			} catch (std.file.FileException e) {
				// Unable to access required hash file
				logBuffer.addLogEntry("ERROR: Unable to access " ~ e.msg);
				// Use exit scopes to shutdown API
				return EXIT_FAILURE;
			}
		}
		
		if (exists(syncListHashFile)) {
			try {
				previousSyncListHash = readText(syncListHashFile);
			} catch (std.file.FileException e) {
				// Unable to access required hash file
				logBuffer.addLogEntry("ERROR: Unable to access " ~ e.msg);
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
			logBuffer.addLogEntry("ERROR: Invalid 'User|Group|Other' permissions set within config file. Please check your configuration");
			operationalConflictDetected = true;
		} else {
			// Debug log output what permissions are being set to
			logBuffer.addLogEntry("Configuring default new folder permissions as: " ~ to!string(getValueLong("sync_dir_permissions")), ["debug"]);
			configureRequiredDirectoryPermisions();
			logBuffer.addLogEntry("Configuring default new file permissions as: " ~ to!string(getValueLong("sync_file_permissions")), ["debug"]);
			configureRequiredFilePermisions();
		}
		
		// --upload-only and --download-only cannot be used together
		if ((getValueBool("upload_only")) && (getValueBool("download_only"))) {
			logBuffer.addLogEntry("ERROR: --upload-only and --download-only cannot be used together. Use one, not both at the same time");
			operationalConflictDetected = true;
		}
		
		// --sync and --monitor cannot be used together
		if ((getValueBool("synchronize")) && (getValueBool("monitor"))) {
			logBuffer.addLogEntry("ERROR: --sync and --monitor cannot be used together. Only use one of these options, not both at the same time");
			operationalConflictDetected = true;
		}
		
		// --no-remote-delete can ONLY be enabled when --upload-only is used
		if ((getValueBool("no_remote_delete")) && (!getValueBool("upload_only"))) {
			logBuffer.addLogEntry("ERROR: --no-remote-delete can only be used with --upload-only");
			operationalConflictDetected = true;
		}
		
		// --remove-source-files can ONLY be enabled when --upload-only is used
		if ((getValueBool("remove_source_files")) && (!getValueBool("upload_only"))) {
			logBuffer.addLogEntry("ERROR: --remove-source-files can only be used with --upload-only");
			operationalConflictDetected = true;
		}
		
		// --cleanup-local-files can ONLY be enabled when --download-only is used
		if ((getValueBool("cleanup_local_files")) && (!getValueBool("download_only"))) {
			logBuffer.addLogEntry("ERROR: --cleanup-local-files can only be used with --download-only");
			operationalConflictDetected = true;
		}
		
		// --list-shared-folders cannot be used with --resync and/or --resync-auth
		if ((getValueBool("list_business_shared_items")) && ((getValueBool("resync")) || (getValueBool("resync_auth")))) {
			logBuffer.addLogEntry("ERROR: --list-shared-items cannot be used with --resync or --resync-auth");
			operationalConflictDetected = true;
		}
		
		// --list-shared-folders cannot be used with --sync or --monitor
		if ((getValueBool("list_business_shared_items")) && ((getValueBool("synchronize")) || (getValueBool("monitor")))) {
			logBuffer.addLogEntry("ERROR: --list-shared-items cannot be used with --sync or --monitor");
			operationalConflictDetected = true;
		}
		
		// --sync-shared-files can ONLY be used with sync_business_shared_items
		if ((getValueBool("sync_business_shared_files")) && (!getValueBool("sync_business_shared_items"))) {
			logBuffer.addLogEntry("ERROR: The --sync-shared-files option can only be utilised if the 'sync_business_shared_items' configuration setting is enabled.");
			operationalConflictDetected = true;
		}
				
		// --display-sync-status cannot be used with --resync and/or --resync-auth
		if ((getValueBool("display_sync_status")) && ((getValueBool("resync")) || (getValueBool("resync_auth")))) {
			logBuffer.addLogEntry("ERROR: --display-sync-status cannot be used with --resync or --resync-auth");
			operationalConflictDetected = true;
		}
		
		// --modified-by cannot be used with --resync and/or --resync-auth
		if ((!getValueString("modified_by").empty) && ((getValueBool("resync")) || (getValueBool("resync_auth")))) {
			logBuffer.addLogEntry("ERROR: --modified-by cannot be used with --resync or --resync-auth");
			operationalConflictDetected = true;
		}
		
		// --get-file-link cannot be used with --resync and/or --resync-auth
		if ((!getValueString("get_file_link").empty) && ((getValueBool("resync")) || (getValueBool("resync_auth")))) {
			logBuffer.addLogEntry("ERROR: --get-file-link cannot be used with --resync or --resync-auth");
			operationalConflictDetected = true;
		}
		
		// --create-share-link cannot be used with --resync and/or --resync-auth
		if ((!getValueString("create_share_link").empty) && ((getValueBool("resync")) || (getValueBool("resync_auth")))) {
			logBuffer.addLogEntry("ERROR: --create-share-link cannot be used with --resync or --resync-auth");
			
			operationalConflictDetected = true;
		}
		
		// --get-sharepoint-drive-id cannot be used with --resync and/or --resync-auth
		if ((!getValueString("sharepoint_library_name").empty) && ((getValueBool("resync")) || (getValueBool("resync_auth")))) {
			logBuffer.addLogEntry("ERROR: --get-sharepoint-drive-id cannot be used with --resync or --resync-auth");
			operationalConflictDetected = true;
		}
		
		// --monitor and --display-sync-status cannot be used together
		if ((getValueBool("monitor")) && (getValueBool("display_sync_status"))) {
			logBuffer.addLogEntry("ERROR: --monitor and --display-sync-status cannot be used together");
			operationalConflictDetected = true;
		}
		
		// --sync and and --display-sync-status cannot be used together
		if ((getValueBool("synchronize")) && (getValueBool("display_sync_status"))) {
			logBuffer.addLogEntry("ERROR: --sync and and --display-sync-status cannot be used together");
			operationalConflictDetected = true;
		}
		
		// --monitor and --display-quota cannot be used together
		if ((getValueBool("monitor")) && (getValueBool("display_quota"))) {
			logBuffer.addLogEntry("ERROR: --monitor and --display-quota cannot be used together");
			operationalConflictDetected = true;
		}
		
		// --sync and and --display-quota cannot be used together
		if ((getValueBool("synchronize")) && (getValueBool("display_quota"))) {
			logBuffer.addLogEntry("ERROR: --sync and and --display-quota cannot be used together");
			operationalConflictDetected = true;
		}
				
		// --force-sync can only be used when using --sync --single-directory
		if (getValueBool("force_sync")) {
		
			bool conflict = false;
			// Should not be used with --monitor
			if (getValueBool("monitor")) conflict = true;
			// single_directory must not be empty
			if (getValueString("single_directory").empty) conflict = true;
			if (conflict) {
				logBuffer.addLogEntry("ERROR: --force-sync can only be used with --sync --single-directory");
				operationalConflictDetected = true;
			}
		}
		
		// When using 'azure_ad_endpoint', 'azure_tenant_id' cannot be empty
		if ((!getValueString("azure_ad_endpoint").empty) && (getValueString("azure_tenant_id").empty)) {
			logBuffer.addLogEntry("ERROR: config option 'azure_tenant_id' cannot be empty when 'azure_ad_endpoint' is configured");
			operationalConflictDetected = true;
		}
		
		// When using --enable-logging the 'log_dir' cannot be empty
		if ((getValueBool("enable_logging")) && (getValueString("log_dir").empty)) {
			logBuffer.addLogEntry("ERROR: config option 'log_dir' cannot be empty when 'enable_logging' is configured");
			operationalConflictDetected = true;
		}
		
		// When using --syncdir, the value cannot be empty.
		if (strip(getValueString("sync_dir")).empty) {
			logBuffer.addLogEntry("ERROR: --syncdir value cannot be empty");
			operationalConflictDetected = true;
		}
		
		// --monitor and --create-directory cannot be used together
		if ((getValueBool("monitor")) && (!getValueString("create_directory").empty)) {
			logBuffer.addLogEntry("ERROR: --monitor and --create-directory cannot be used together");
			operationalConflictDetected = true;
		}
		
		// --sync and --create-directory cannot be used together
		if ((getValueBool("synchronize")) && (!getValueString("create_directory").empty)) {
			logBuffer.addLogEntry("ERROR: --sync and --create-directory cannot be used together");
			operationalConflictDetected = true;
		}
		
		// --monitor and --remove-directory cannot be used together
		if ((getValueBool("monitor")) && (!getValueString("remove_directory").empty)) {
			logBuffer.addLogEntry("ERROR: --monitor and --remove-directory cannot be used together");
			operationalConflictDetected = true;
		}
		
		// --sync and --remove-directory cannot be used together
		if ((getValueBool("synchronize")) && (!getValueString("remove_directory").empty)) {
			logBuffer.addLogEntry("ERROR: --sync and --remove-directory cannot be used together");
			operationalConflictDetected = true;
		}
		
		// --monitor and --source-directory cannot be used together
		if ((getValueBool("monitor")) && (!getValueString("source_directory").empty)) {
			logBuffer.addLogEntry("ERROR: --monitor and --source-directory cannot be used together");
			operationalConflictDetected = true;
		}
		
		// --sync and --source-directory cannot be used together
		if ((getValueBool("synchronize")) && (!getValueString("source_directory").empty)) {
			logBuffer.addLogEntry("ERROR: --sync and --source-directory cannot be used together");
			operationalConflictDetected = true;
		}
		
		// --monitor and --destination-directory cannot be used together
		if ((getValueBool("monitor")) && (!getValueString("destination_directory").empty)) {
			logBuffer.addLogEntry("ERROR: --monitor and --destination-directory cannot be used together");
			operationalConflictDetected = true;
		}
		
		// --sync and --destination-directory cannot be used together
		if ((getValueBool("synchronize")) && (!getValueString("destination_directory").empty)) {
			logBuffer.addLogEntry("ERROR: --sync and --destination-directory cannot be used together");
			operationalConflictDetected = true;
		}
		
		// --download-only and --local-first cannot be used together
		if ((getValueBool("download_only")) && (getValueBool("local_first"))) {
			logBuffer.addLogEntry("ERROR: --download-only cannot be used with --local-first");
			operationalConflictDetected = true;
		}
				
		// Return bool value indicating if we have an operational conflict
		return operationalConflictDetected;
	}
	
	// Reset skip_file and skip_dir to application defaults when --force-sync is used
	void resetSkipToDefaults() {
		// skip_file
		logBuffer.addLogEntry("original skip_file: " ~ getValueString("skip_file"), ["debug"]);
		logBuffer.addLogEntry("resetting skip_file to application defaults", ["debug"]);
		setValueString("skip_file", defaultSkipFile);
		logBuffer.addLogEntry("reset skip_file: " ~ getValueString("skip_file"), ["debug"]);
		
		// skip_dir
		logBuffer.addLogEntry("original skip_dir: " ~ getValueString("skip_dir"), ["debug"]);
		logBuffer.addLogEntry("resetting skip_dir to application defaults", ["debug"]);
		setValueString("skip_dir", defaultSkipDir);
		logBuffer.addLogEntry("reset skip_dir: " ~ getValueString("skip_dir"), ["debug"]);
	}
	
	// Initialise the correct 'sync_dir' expanding any '~' if present
	string initialiseRuntimeSyncDirectory() {
	
		string runtimeSyncDirectory;
		
		logBuffer.addLogEntry("sync_dir: Setting runtimeSyncDirectory from config value 'sync_dir'", ["debug"]);
		
		if (!shellEnvironmentSet){
			logBuffer.addLogEntry("sync_dir: No SHELL or USER environment variable configuration detected", ["debug"]);
			
			// No shell or user set, so expandTilde() will fail - usually headless system running under init.d / systemd or potentially Docker
			// Does the 'currently configured' sync_dir include a ~
			if (canFind(getValueString("sync_dir"), "~")) {
				// A ~ was found in sync_dir
				logBuffer.addLogEntry("sync_dir: A '~' was found in 'sync_dir', using the calculated 'homePath' to replace '~' as no SHELL or USER environment variable set", ["debug"]);
				runtimeSyncDirectory = buildNormalizedPath(buildPath(defaultHomePath, strip(getValueString("sync_dir"), "~")));
			} else {
				// No ~ found in sync_dir, use as is
				logBuffer.addLogEntry("sync_dir: Using configured 'sync_dir' path as-is as no SHELL or USER environment variable configuration detected", ["debug"]);
				runtimeSyncDirectory = getValueString("sync_dir");
			}
		} else {
			// A shell and user environment variable is set, expand any ~ as this will be expanded correctly if present
			if (canFind(getValueString("sync_dir"), "~")) {
				logBuffer.addLogEntry("sync_dir: A '~' was found in the configured 'sync_dir', automatically expanding as SHELL and USER environment variable is set", ["debug"]);
				runtimeSyncDirectory = expandTilde(getValueString("sync_dir"));
			} else {
				// No ~ found in sync_dir, does the path begin with a '/' ?
				logBuffer.addLogEntry("sync_dir: Using configured 'sync_dir' path as-is as however SHELL or USER environment variable configuration detected - should be placed in USER home directory", ["debug"]);
				if (!startsWith(getValueString("sync_dir"), "/")) {
					logBuffer.addLogEntry("Configured 'sync_dir' does not start with a '/' or '~/' - adjusting configured 'sync_dir' to use User Home Directory as base for 'sync_dir' path", ["debug"]);
					string updatedPathWithHome = "~/" ~ getValueString("sync_dir");
					runtimeSyncDirectory = expandTilde(updatedPathWithHome);
				} else {
					logBuffer.addLogEntry("use 'sync_dir' as is - no touch", ["debug"]);
					runtimeSyncDirectory = getValueString("sync_dir");
				}
			}
		}
		
		// What will runtimeSyncDirectory be actually set to?
		logBuffer.addLogEntry("sync_dir: runtimeSyncDirectory set to: " ~ runtimeSyncDirectory, ["debug"]);
		
		// Configure configuredBusinessSharedFilesDirectoryName
		configuredBusinessSharedFilesDirectoryName = buildNormalizedPath(buildPath(runtimeSyncDirectory, defaultBusinessSharedFilesDirectoryName));
		
		return runtimeSyncDirectory;
	}
	
	// Initialise the correct 'log_dir' when application logging to a separate file is enabled with 'enable_logging' and expanding any '~' if present
	string calculateLogDirectory() {
		
		string configuredLogDirPath;
		
		logBuffer.addLogEntry("log_dir: Setting runtime application log from config value 'log_dir'", ["debug"]);
				
		if (getValueString("log_dir") != defaultLogFileDir) {
			// User modified 'log_dir' to be used with 'enable_logging'
			// if 'log_dir' contains a '~' this needs to be expanded correctly
			if (canFind(getValueString("log_dir"), "~")) {
				// ~ needs to be expanded correctly
				if (!shellEnvironmentSet) {
					// No shell or user environment variable set, so expandTilde() will fail - usually headless system running under init.d / systemd or potentially Docker
					logBuffer.addLogEntry("log_dir: A '~' was found in log_dir, using the calculated 'homePath' to replace '~' as no SHELL or USER environment variable set", ["debug"]);
					configuredLogDirPath = buildNormalizedPath(buildPath(defaultHomePath, strip(getValueString("log_dir"), "~")));
				} else {
					// A shell and user environment variable is set, expand any ~ as this will be expanded correctly if present
					logBuffer.addLogEntry("log_dir: A '~' was found in the configured 'log_dir', automatically expanding as SHELL and USER environment variable is set", ["debug"]);
					configuredLogDirPath = expandTilde(getValueString("log_dir"));
				}		
			} else {
				// '~' not found in log_dir entry, use as is
				configuredLogDirPath = getValueString("log_dir");
			}
		} else {
			// Default 'log_dir' to be used with 'enable_logging'
			configuredLogDirPath = defaultLogFileDir;
		}
		
		// Attempt to create 'configuredLogDirPath' otherwise we need to fall back to the users home directory
		if (!exists(configuredLogDirPath)) {
			// 'configuredLogDirPath' path does not exist - try and create it
			try {
				mkdirRecurse(configuredLogDirPath);
			} catch (std.file.FileException e) {
				// We got an error when attempting to create the directory ..
				logBuffer.addLogEntry();
				logBuffer.addLogEntry("ERROR: Unable to create " ~ configuredLogDirPath);
				logBuffer.addLogEntry("ERROR: Please manually create '" ~ configuredLogDirPath ~ "' and set appropriate permissions to allow write access for your user to this location.");
				logBuffer.addLogEntry("ERROR: The requested client activity log will instead be located in your users home directory");
				logBuffer.addLogEntry();
				
				// Reconfigure 'configuredLogDirPath' to use environment.get("HOME") value, which we have already calculated
				configuredLogDirPath = defaultHomePath;
			}
		}
		
		// Return the initialised application log path
		return configuredLogDirPath;
	}
	
	void setConfigLoggingLevels(bool verboseLoggingInput, bool debugLoggingInput, long verbosityCountInput) {
		// set the appConfig logging values
		verboseLogging = verboseLoggingInput;
		debugLogging = debugLoggingInput;
		verbosityCount = verbosityCountInput;
	}
	
	// What IP protocol is going to be used to access Microsoft OneDrive
	void displayIPProtocol() {
		if (getValueLong("ip_protocol_version") == 0) logBuffer.addLogEntry("Using IPv4 and IPv6 (if configured) for all network operations");
		if (getValueLong("ip_protocol_version") == 1) logBuffer.addLogEntry("Forcing client to use IPv4 connections only");
		if (getValueLong("ip_protocol_version") == 2) logBuffer.addLogEntry("Forcing client to use IPv6 connections only");
	}
	
	// Has a 'no-sync' task been requested?
	bool hasNoSyncOperationBeenRequested() {
	
		bool noSyncOperation = false;
	
		// Are we performing some sort of 'no-sync' task?
		// - Are we obtaining the Office 365 Drive ID for a given Office 365 SharePoint Shared Library?
		// - Are we displaying the sync status?
		// - Are we getting the URL for a file online?
		// - Are we listing who modified a file last online?
		// - Are we listing OneDrive Business Shared Items?
		// - Are we creating a shareable link for an existing file on OneDrive?
		// - Are we just creating a directory online, without any sync being performed?
		// - Are we just deleting a directory online, without any sync being performed?
		// - Are we renaming or moving a directory?
		// - Are we displaying the quota information?
		
		// Return a true|false if any of these have been set, so that we use the 'dry-run' DB copy, to execute these tasks, in case the client is currently operational
		
		// --get-sharepoint-drive-id - Get the SharePoint Library drive_id
		if (getValueString("sharepoint_library_name") != "") {
			// flag that a no sync operation has been requested
			noSyncOperation = true;
		}
		
		// --display-sync-status - Query the sync status
		if (getValueBool("display_sync_status")) {
			// flag that a no sync operation has been requested
			noSyncOperation = true;
		}
		
		// --get-file-link - Get the URL path for a synced file?
		if (getValueString("get_file_link") != "") {
			// flag that a no sync operation has been requested
			noSyncOperation = true;
		}
		
		// --modified-by - Are we listing the modified-by details of a provided path?
		if (getValueString("modified_by") != "") {
			// flag that a no sync operation has been requested
			noSyncOperation = true;
		}
		
		// --list-shared-items - Are we listing OneDrive Business Shared Items
		if (getValueBool("list_business_shared_items")) {
			// flag that a no sync operation has been requested
			noSyncOperation = true;
		}
		
		// --create-share-link - Are we creating a shareable link for an existing file on OneDrive?
		if (getValueString("create_share_link") != "") {
			// flag that a no sync operation has been requested
			noSyncOperation = true;
		}
		
		// --create-directory - Are we just creating a directory online, without any sync being performed?
		if ((getValueString("create_directory") != "")) {
			// flag that a no sync operation has been requested
			noSyncOperation = true;
		}
		
		// --remove-directory - Are we just deleting a directory online, without any sync being performed?
		if ((getValueString("remove_directory") != "")) {
			// flag that a no sync operation has been requested
			noSyncOperation = true;
		}
		
		// Are we renaming or moving a directory online?
		// 	onedrive --source-directory 'path/as/source/' --destination-directory 'path/as/destination'
		if ((getValueString("source_directory") != "") && (getValueString("destination_directory") != "")) {
			// flag that a no sync operation has been requested
			noSyncOperation = true;
		}
		
		// Are we displaying the quota information?
		if (getValueBool("display_quota")) {
			// flag that a no sync operation has been requested
			noSyncOperation = true;
		}
		
		// Return result
		return noSyncOperation;
	}
}

// Output the full application help when --help is passed in
void outputLongHelp(Option[] opt) {
		auto argsNeedingOptions = [
			"--auth-files",
			"--auth-response",
			"--confdir",
			"--create-directory",
			"--classify-as-big-delete",
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
			"--remove-directory",
			"--single-directory",
			"--skip-dir",
			"--skip-file",
			"--skip-size",
			"--source-directory",
			"--space-reservation",
			"--syncdir",
			"--user-agent" ];
		writeln(`onedrive - A client for the Microsoft OneDrive Cloud Service

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