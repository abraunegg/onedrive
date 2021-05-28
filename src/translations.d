// The aim is to provide language translations for the following application logging output:
// - log.log 
// - log.vlog 
// - log.error
// - log.logAndNotify
import std.string, std.stdio, std.json, std.file;

ulong defaultMessageCount = 0;
string[] languageResponsesEN_AU;
string[] languageResponsesEN_US;
string defaultBadLookupResponse = "ERROR: BAD LOOKUP INDEX ";

// Initialise default message lookup using EN-AU
void initialize() {
	// Initialise default messages
	initialise_EN_AU();
	defaultMessageCount = count(languageResponsesEN_AU);
}

// Load user configured translation files from a file
void initializeUserConfiguredLanguageTranslations(string languageIdentifier) {
	// Path to translation files
	string translationPath = "/usr/share/onedrive/";
	
	// Translation files
	string EN_US_TranslationFile = translationPath ~ "EN-US.json";
	
	switch (languageIdentifier) {
		case "EN-US":
			// Load Translation Files if they exist
			if (exists(EN_US_TranslationFile)) {
				// Load the file
				auto fileContents = readText(EN_US_TranslationFile);
				JSONValue languageList = parseJSON(fileContents);
				
				// Load the message into the required array
				foreach (translationItem; languageList["list"].array) {
					string responseString = translationItem.toString;
					responseString = responseString[1 .. $-1];
					languageResponsesEN_US ~= responseString;
				}
				// If the loaded responses != defaultMessageCount there will be an issue in translation .. warn
				writeln("WARNING: " ~ EN_US_TranslationFile ~ " is out of sync with default application messages - application output will be inaccurate");
			}
			break;
			
		case "DE":
			//logMessageResponse = getResponseFromIndex_EN_US(requiredResponseIndex);
			break;
		default:
			//logMessageResponse = getResponseFromIndex_EN_AU(requiredResponseIndex);
			break;
	}	
}

// Provide a language response based on the setting of a 'config' file language option
string provideLanguageTranslation(string languageIdentifier, int requiredResponseIndex) {
	string logMessageResponse;
	// Application message indexes start at '1', however array index's start at '0'
	// Need to decrement the requiredResponseIndex so we get the right message
	requiredResponseIndex--;
	
	switch (languageIdentifier) {
		case "EN-AU":
			// Language Maintainer: abraunegg
			logMessageResponse = getResponseFromIndex_EN_AU(requiredResponseIndex);
			break;
		case "EN-US":
			// Language Maintainer: abraunegg
			logMessageResponse = getResponseFromIndex_EN_US(requiredResponseIndex);
			break;
		default:
			logMessageResponse = getResponseFromIndex_EN_AU(requiredResponseIndex);
			break;
	}
	
	// Return log message to application
	return logMessageResponse;	
}

// Load EN-AU application messages
void initialise_EN_AU(){
	// The below JSON array contains all the default application messages
	JSONValue languageList = [ "language": "EN-AU"];
	languageList.object["list"] = JSONValue([
												"No user or system config file found, using application defaults",
												"System configuration file successfully loaded",
												"System configuration file has errors - please check your configuration",
												"Configuration file successfully loaded",
												"Configuration file has errors - please check your configuration",
												"Using config option for Global Azure AD Endpoints",
												"Using config option for Azure AD for US Government Endpoints",
												"Using config option for Azure AD for US Government Endpoints (DOD)",
												"Using config option for Azure AD Germany",
												"Using config option for Azure AD China operated by 21Vianet",
												"Unknown Azure AD Endpoint - using Global Azure AD Endpoints",
												"Unknown key in config file: ",
												"Malformed config line: ",
												"config file has been updated, checking if --resync needed",
												"An application configuration change has been detected where a --resync is required",
												"DRY-RUN Configured. Output below shows what 'would' have occurred",
												"Using logfile dir: ",
												"Database schema changed, resync needed",
												"Deleting the saved status ...",
												"ERROR: Unable to reach Microsoft OneDrive API service, unable to initialise application",
												"ERROR: Unable to reach Microsoft OneDrive API service at this point in time, re-trying network tests",
												"Internet connectivity to Microsoft OneDrive service has been restored",
												"ERROR: The OneDrive Linux Client was unable to reconnect to the Microsoft OneDrive service after 10000 attempts lasting over 1.2 years!",
												"Initialising the OneDrive API ...",
												"Could not initialise the OneDrive API",
												"Application has been successfully authorised, however no additional command switches were provided",
												"Please use 'onedrive --help' for further assistance in regards to running this application",
												"Application has not been successfully authorised. Please check your URI response entry and try again",
												"ERROR: --synchronize or --monitor switches missing from your command line input. Please add one (not both) of these switches to your command line",
												"No OneDrive sync will be performed without one of these two arguments being present",
												"ERROR: --synchronize and --monitor cannot be used together",
												"Opening the item database ...",
												"ERROR: Invalid 'User|Group|Other' permissions set within config file. Please check your config file.",
												"All operations will be performed in: ",
												"ERROR: Unable to create local OneDrive syncDir - ",
												"ERROR: Invalid skip_file entry '.*' detected",
												"Initialising the Synchronisation Engine ...",
												"Cannot connect to Microsoft OneDrive Service - Network Connection Issue",
												"WARNING: Application has been configured to bypass local data preservation in the event of file conflict",
												"WARNING: Local data loss MAY occur in this scenario",
												"ERROR: .nosync file found. Aborting synchronisation process to safeguard data",
												"ERROR: Unsupported account type for listing OneDrive Business Shared Folders",
												"ERROR: Unsupported account type for syncing OneDrive Business Shared Folders",
												"WARNING: The requested path for --single-directory does not exist locally. Creating requested path within: ",
												"Initialising monitor ...",
												"OneDrive monitor interval (seconds): ",
												"[M] Skipping watching path - .folder found & --skip-dot-files enabled: ",
												"[M] Directory created: ",
												"Offline, cannot create remote directory!",
												"Cannot create remote directory: ",
												"[M] File changed: ",
												"Offline, cannot upload changed item!",
												"Cannot upload file changes/creation: ",
												"[M] Item deleted: ",
												"Offline, cannot delete item!",
												"Item cannot be deleted from OneDrive because it was not found in the local database",
												"Cannot delete remote item: ",
												"[M] Item moved: ",
												"Offline, cannot move item!",
												"Cannot move item: ",
												"ERROR: ",
												"ERROR: The following inotify error was generated: ",
												"Starting a sync with OneDrive",
												"Sync with OneDrive is complete",
												"Persistent connection errors, reinitialising connection",
												"Authorisation token invalid, use --logout to authorise the client again",
												"Syncing changes from this selected path: ",
												"Syncing changes from selected local path only - NOT syncing data changes from OneDrive ...",
												"Syncing changes from selected local path first before downloading changes from OneDrive ...",
												"Syncing changes from selected OneDrive path ...",
												"Syncing changes from local path only - NOT syncing data changes from OneDrive ...",
												"Syncing changes from local path first before downloading changes from OneDrive ...",
												"Syncing changes from OneDrive ...",
												"Giving up on sync after three attempts: ",
												"Retry sync count: ",
												" Got termination signal, shutting down DB connection",
												"Syncing changes from OneDrive only - NOT syncing local data changes to OneDrive ...",
												"The file does not have any hash",
												"ERROR: Check your 'drive_id' entry in your configuration file as it may be incorrect",
												"ERROR: Check your configuration as your refresh_token may be empty or invalid. You may need to issue a --logout and re-authorise this client.",
												"ERROR: OneDrive account currently has zero space available. Please free up some space online.",
												"WARNING: OneDrive quota information is being restricted or providing a zero value. Please fix by speaking to your OneDrive / Office 365 Administrator.",
												"ERROR: OneDrive quota information is missing. Potentially your OneDrive account currently has zero space available. Please free up some space online.",
												"ERROR: OneDrive quota information is being restricted. Please fix by speaking to your OneDrive / Office 365 Administrator.",
												"Application version: ",
												"Account Type: ",
												"Default Drive ID: ",
												"Default Root ID: ",
												"Remaining Free Space: ",
												"Continuing the upload session ...",
												"Removing local file as --upload-only & --remove-source-files configured",
												"ERROR: File failed to upload. Increase logging verbosity to determine why.",
												"Skipping item - excluded by skip_dir config: ",
												"Syncing this OneDrive Personal Shared Folder: ",
												"Attempting to sync OneDrive Business Shared Folders",
												"Syncing this OneDrive Business Shared Folder: ",
												"OneDrive Business Shared Folder - Shared By:  ",
												"WARNING: Skipping shared folder due to existing name conflict: ",
												"WARNING: Skipping changes of Path ID: ",
												"WARNING: To sync this shared folder, this shared folder needs to be renamed",
												"WARNING: Conflict Shared By:          ",
												"WARNING: Not syncing this OneDrive Business Shared File: ",
												"OneDrive Business Shared File - Shared By:  ",
												"WARNING: Not syncing this OneDrive Business Shared item: ",
												"ERROR: onedrive.getSharedWithMe call returned an invalid JSON Object",
												"Getting path details from OneDrive ...",
												"ERROR: The requested single directory to sync was not found on OneDrive",
												"Fetching details for OneDrive Root",
												"OneDrive Root does not exist in the database. We need to add it.",
												"Added OneDrive Root to the local database",
												"OneDrive Root exists in the database",
												"ERROR: Unable to query OneDrive for account details",
											]);
	
	// Load the message into the array
	foreach (translationItem; languageList["list"].array) {
		string responseString = translationItem.toString;
		responseString = responseString[1 .. $-1];
		languageResponsesEN_AU ~= responseString;
	}
}

// Provide the application message based on the index as provided
string getResponseFromIndex_EN_AU(int requiredResponseIndex) {
	string requiredResponse;
	// get response from message array
	try {
		// try and get the message from the required index
		requiredResponse = languageResponsesEN_AU[requiredResponseIndex];
	} catch (core.exception.RangeError e) {
		// invalid index provided
		requiredResponse = defaultBadLookupResponse;
	}
	// Return language response
	return requiredResponse;
}

// Provide the application message based on the index as provided
string getResponseFromIndex_EN_US(int requiredResponseIndex) {
	string requiredResponse;
	// get response from message array
	try {
		// try and get the message from the required index
		requiredResponse = languageResponsesEN_US[requiredResponseIndex];		
	} catch (core.exception.RangeError e) {
		// invalid index provided
		requiredResponse = defaultBadLookupResponse;
	}
	// Return language response
	return requiredResponse;
}