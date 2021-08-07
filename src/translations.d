// The aim is to provide language translations for the following application logging output:
// - log.log 
// - log.vlog 
// - log.error
// - log.logAndNotify
import std.string, std.stdio, std.json, std.file, std.conv;
static import log;

ulong defaultMessageCount = 0;
string[] languageResponsesDefault;
string[] languageResponsesTranslations;
string defaultBadLookupResponse = "ERROR: BAD LOOKUP INDEX FOR LANGUAGE TRANSLATION";

// Initialise default message lookup using EN-AU
void initialize() {
	// Initialise default messages
	initialise_EN_AU();
	defaultMessageCount = count(languageResponsesDefault);
}

// Load user configured translation files from a file
void initializeUserConfiguredLanguageTranslations(string languageIdentifier) {
	// Path to translation files
	string translationPath = "/usr/share/onedrive/";
	
	// Translation files
	string EN_US_TranslationFile = translationPath ~ "EN-US.json";
	string DE_TranslationFile = translationPath ~ "DE.json";
	
	// Load the right file
	switch (languageIdentifier) {
		case "EN-US":
			// Load Translation Files if they exist
			if (exists(EN_US_TranslationFile)) {
				// Load the file
				auto fileContents = readText(EN_US_TranslationFile);
				JSONValue languageList = parseJSON(fileContents);
				// Load the message into the required array
				languageResponsesTranslations = loadTranslationFromJSON(EN_US_TranslationFile, languageList, languageIdentifier);
			}
			break;
		case "DE":
			// Load Translation Files if they exist
			if (exists(DE_TranslationFile)) {
				// Load the file
				auto fileContents = readText(DE_TranslationFile);
				JSONValue languageList = parseJSON(fileContents);
				// Load the message into the required array
				languageResponsesTranslations = loadTranslationFromJSON(DE_TranslationFile, languageList, languageIdentifier);
			}
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
			// Use EN-AU for application output
			logMessageResponse = getResponseFromIndex_EN_AU(requiredResponseIndex);
			break;
		default:
			// Default is to use any 'loaded' translations
			logMessageResponse = getResponseFromIndex(requiredResponseIndex);
			break;
	}
	
	// Return log message to application
	return logMessageResponse;	
}

// Load specific application messages
string[] loadTranslationFromJSON(string translationFile, JSONValue languageList, string languageIdentifier) {
	// parse the input JSON and provide back the loaded array for use
	string[] languageResponsesTemp;
	
	// Load the message into the required array
	foreach (translationItem; languageList["list"].array) {
		// translationItem["2"].str
		ulong thisMessageID = 0;
		log.vdebug("Loading Language Translations for " ~ languageIdentifier);
		while (thisMessageID != defaultMessageCount) {
			// iterate through message ID's
			thisMessageID++;
			// If the translation JSON has an unequal number of entries to default, the 'key' will not be found	
			try {
				// debug output what we are loading and at what index
				log.vdebug("translationItem['" ~ to!string(thisMessageID) ~ "']: ", translationItem[to!string(thisMessageID)].str);
				string responseString = translationItem[to!string(thisMessageID)].str;
				languageResponsesTemp ~= responseString;
			} catch (std.json.JSONException) {
				// dont print anything out - catch error and move on	
			}
		}
	}
	
	// If the loaded responses != defaultMessageCount there will be an issue in translation .. warn the user
	if (count(languageResponsesTemp) < defaultMessageCount) {
		log.log("WARNING: " ~ translationFile ~ " is out of sync with default application messages - application output will be inaccurate");
		ulong missing = 0;
		missing = defaultMessageCount - count(languageResponsesTemp);
		log.vdebug("Number of missing translations: ", missing);
	}
	
	// Return the loaded translations
	return languageResponsesTemp;
}

// Provide the application message based on the index as provided
string getResponseFromIndex_EN_AU(int requiredResponseIndex) {
	static import core.exception;
	string requiredResponse;
	// get response from message array
	try {
		// try and get the message from the required index
		requiredResponse = languageResponsesDefault[requiredResponseIndex];
	} catch (core.exception.RangeError e) {
		// invalid index provided
		requiredResponse = defaultBadLookupResponse;
	}
	// Return language response
	return requiredResponse;
}

// Provide the application message based on the index as provided
string getResponseFromIndex(int requiredResponseIndex) {
	static import core.exception;
	string requiredResponse;
	// get response from message array
	try {
		// try and get the message from the required index
		requiredResponse = languageResponsesTranslations[requiredResponseIndex];		
	} catch (core.exception.RangeError e) {
		// invalid index was provided
		// get the required response from EN-AU ... whilst might not be ideal (potentially different language) better than a generic error response
		requiredResponse = getResponseFromIndex_EN_AU(requiredResponseIndex);
	}
	// Return language response
	return requiredResponse;
}

// Load EN-AU application messages
void initialise_EN_AU(){
	// The below JSON array contains all the default application messages
	JSONValue languageList = [ "language": "EN-AU"];
	languageList.object["list"] = JSONValue([
		JSONValue([ "1": "No user or system config file found, using application defaults" ]),
		JSONValue([ "2": "System configuration file successfully loaded" ]),
		JSONValue([ "3": "System configuration file has errors - please check your configuration" ]),
		JSONValue([ "4": "Configuration file successfully loaded" ]),
		JSONValue([ "5": "Configuration file has errors - please check your configuration" ]),
		JSONValue([ "6": "Using config option for Global Azure AD Endpoints" ]),
		JSONValue([ "7": "Using config option for Azure AD for US Government Endpoints" ]),
		JSONValue([ "8": "Using config option for Azure AD for US Government Endpoints (DOD)" ]),
		JSONValue([ "9": "Using config option for Azure AD Germany" ]),
		JSONValue([ "10": "Using config option for Azure AD China operated by 21Vianet" ]),
		JSONValue([ "11": "Unknown Azure AD Endpoint - using Global Azure AD Endpoints" ]),
		JSONValue([ "12": "Unknown key in config file: " ]),
		JSONValue([ "13": "Malformed config line: " ]),
		JSONValue([ "14": "config file has been updated, checking if --resync needed" ]),
		JSONValue([ "15": "An application configuration change has been detected where a --resync is required" ]),
		JSONValue([ "16": "DRY-RUN Configured. Output below shows what 'would' have occurred" ]),
		JSONValue([ "17": "Using logfile dir: " ]),
		JSONValue([ "18": "Database schema changed, resync needed" ]),
		JSONValue([ "19": "Deleting the saved status ..." ]),
		JSONValue([ "20": "ERROR: Unable to reach Microsoft OneDrive API service, unable to initialise application" ]),
		JSONValue([ "21": "ERROR: Unable to reach Microsoft OneDrive API service at this point in time, re-trying network tests" ]),
		JSONValue([ "22": "Internet connectivity to Microsoft OneDrive service has been restored" ]),
		JSONValue([ "23": "ERROR: The OneDrive Linux Client was unable to reconnect to the Microsoft OneDrive service after 10000 attempts lasting over 1.2 years!" ]),
		JSONValue([ "24": "Initialising the OneDrive API ..." ]),
		JSONValue([ "25": "Could not initialise the OneDrive API" ]),
		JSONValue([ "26": "Application has been successfully authorised, however no additional command switches were provided" ]),
		JSONValue([ "27": "Please use 'onedrive --help' for further assistance in regards to running this application" ]),
		JSONValue([ "28": "Application has not been successfully authorised. Please check your URI response entry and try again" ]),
		JSONValue([ "29": "ERROR: --synchronize or --monitor switches missing from your command line input. Please add one (not both) of these switches to your command line" ]),
		JSONValue([ "30": "No OneDrive sync will be performed without one of these two arguments being present" ]),
		JSONValue([ "31": "ERROR: --synchronize and --monitor cannot be used together" ]),
		JSONValue([ "32": "Opening the item database ..." ]),
		JSONValue([ "33": "ERROR: Invalid 'User|Group|Other' permissions set within config file. Please check your config file." ]),
		JSONValue([ "34": "All operations will be performed in: " ]),
		JSONValue([ "35": "ERROR: Unable to create local OneDrive syncDir - " ]),
		JSONValue([ "36": "ERROR: Invalid skip_file entry '.*' detected" ]),
		JSONValue([ "37": "Initialising the Synchronisation Engine ..." ]),
		JSONValue([ "38": "Cannot connect to Microsoft OneDrive Service - Network Connection Issue" ]),
		JSONValue([ "39": "WARNING: Application has been configured to bypass local data preservation in the event of file conflict" ]),
		JSONValue([ "40": "WARNING: Local data loss MAY occur in this scenario" ]),
		JSONValue([ "41": "ERROR: .nosync file found. Aborting synchronisation process to safeguard data" ]),
		JSONValue([ "42": "ERROR: Unsupported account type for listing OneDrive Business Shared Folders" ]),
		JSONValue([ "43": "ERROR: Unsupported account type for syncing OneDrive Business Shared Folders" ]),
		JSONValue([ "44": "WARNING: The requested path for --single-directory does not exist locally. Creating requested path within: " ]),
		JSONValue([ "45": "Initialising monitor ..." ]),
		JSONValue([ "46": "OneDrive monitor interval (seconds): " ]),
		JSONValue([ "47": "[M] Skipping watching path - .folder found & --skip-dot-files enabled: " ]),
		JSONValue([ "48": "[M] Directory created: " ]),
		JSONValue([ "49": "Offline, cannot create remote directory!" ]),
		JSONValue([ "50": "Cannot create remote directory: " ]),
		JSONValue([ "51": "[M] File changed: " ]),
		JSONValue([ "52": "Offline, cannot upload changed item!" ]),
		JSONValue([ "53": "Cannot upload file changes/creation: " ]),
		JSONValue([ "54": "[M] Item deleted: " ]),
		JSONValue([ "55": "Offline, cannot delete item!" ]),
		JSONValue([ "56": "Item cannot be deleted from OneDrive because it was not found in the local database" ]),
		JSONValue([ "57": "Cannot delete remote item: " ]),
		JSONValue([ "58": "[M] Item moved: " ]),
		JSONValue([ "59": "Offline, cannot move item!" ]),
		JSONValue([ "60": "Cannot move item: " ]),
		JSONValue([ "61": "ERROR: " ]),
		JSONValue([ "62": "ERROR: The following inotify error was generated: " ]),
		JSONValue([ "63": "Starting a sync with OneDrive" ]),
		JSONValue([ "64": "Sync with OneDrive is complete" ]),
		JSONValue([ "65": "Persistent connection errors, reinitialising connection" ]),
		JSONValue([ "66": "Authorisation token invalid, use --logout to authorise the client again" ]),
		JSONValue([ "67": "Syncing changes from this selected path: " ]),
		JSONValue([ "68": "Syncing changes from selected local path only - NOT syncing data changes from OneDrive ..." ]),
		JSONValue([ "69": "Syncing changes from selected local path first before downloading changes from OneDrive ..." ]),
		JSONValue([ "70": "Syncing changes from selected OneDrive path ..." ]),
		JSONValue([ "71": "Syncing changes from local path only - NOT syncing data changes from OneDrive ..." ]),
		JSONValue([ "72": "Syncing changes from local path first before downloading changes from OneDrive ..." ]),
		JSONValue([ "73": "Syncing changes from OneDrive ..." ]),
		JSONValue([ "74": "Giving up on sync after three attempts: " ]),
		JSONValue([ "75": "Retry sync count: " ]),
		JSONValue([ "76": " Got termination signal, shutting down DB connection" ]),
		JSONValue([ "77": "Syncing changes from OneDrive only - NOT syncing local data changes to OneDrive ..." ]),
		JSONValue([ "78": "The file does not have any hash" ]),
		JSONValue([ "79": "ERROR: Check your 'drive_id' entry in your configuration file as it may be incorrect" ]),
		JSONValue([ "80": "ERROR: Check your configuration as your refresh_token may be empty or invalid. You may need to issue a --logout and re-authorise this client." ]),
		JSONValue([ "81": "ERROR: OneDrive account currently has zero space available. Please free up some space online." ]),
		JSONValue([ "82": "WARNING: OneDrive quota information is being restricted or providing a zero value. Please fix by speaking to your OneDrive / Office 365 Administrator." ]),
		JSONValue([ "83": "ERROR: OneDrive quota information is missing. Potentially your OneDrive account currently has zero space available. Please free up some space online." ]),
		JSONValue([ "84": "ERROR: OneDrive quota information is being restricted. Please fix by speaking to your OneDrive / Office 365 Administrator." ]),
		JSONValue([ "85": "Application version: " ]),
		JSONValue([ "86": "Account Type: " ]),
		JSONValue([ "87": "Default Drive ID: " ]),
		JSONValue([ "88": "Default Root ID: " ]),
		JSONValue([ "89": "Remaining Free Space: " ]),
		JSONValue([ "90": "Continuing the upload session ..." ]),
		JSONValue([ "91": "Removing local file as --upload-only & --remove-source-files configured" ]),
		JSONValue([ "92": "ERROR: File failed to upload. Increase logging verbosity to determine why." ]),
		JSONValue([ "93": "Skipping item - excluded by skip_dir config: " ]),
		JSONValue([ "94": "Syncing this OneDrive Personal Shared Folder: " ]),
		JSONValue([ "95": "Attempting to sync OneDrive Business Shared Folders" ]),
		JSONValue([ "96": "Syncing this OneDrive Business Shared Folder: " ]),
		JSONValue([ "97": "OneDrive Business Shared Folder - Shared By:  " ]),
		JSONValue([ "98": "WARNING: Skipping shared folder due to existing name conflict: " ]),
		JSONValue([ "99": "WARNING: Skipping changes of Path ID: " ]),
		JSONValue([ "100": "WARNING: To sync this shared folder, this shared folder needs to be renamed" ]),
		JSONValue([ "101": "WARNING: Conflict Shared By:          " ]),
		JSONValue([ "102": "WARNING: Not syncing this OneDrive Business Shared File: " ]),
		JSONValue([ "103": "OneDrive Business Shared File - Shared By:  " ]),
		JSONValue([ "104": "WARNING: Not syncing this OneDrive Business Shared item: " ]),
		JSONValue([ "105": "ERROR: onedrive.getSharedWithMe call returned an invalid JSON Object" ]),
		JSONValue([ "106": "Getting path details from OneDrive ..." ]),
		JSONValue([ "107": "ERROR: The requested single directory to sync was not found on OneDrive" ]),
		JSONValue([ "108": "Fetching details for OneDrive Root" ]),
		JSONValue([ "109": "OneDrive Root does not exist in the database. We need to add it." ]),
		JSONValue([ "110": "Added OneDrive Root to the local database" ]),
		JSONValue([ "111": "OneDrive Root exists in the database" ]),
		JSONValue([ "112": "ERROR: Unable to query OneDrive for account details" ]),
		JSONValue([ "113": "Attempting to create the requested path within OneDrive" ]),
		JSONValue([ "114": "Attempting to delete the requested path within OneDrive" ]),
		JSONValue([ "115": "The requested directory to delete was not found on OneDrive - skipping removing the remote directory as it doesn't exist" ]),
		JSONValue([ "116": "The requested directory to delete was not found in the local database - pushing delete request direct to OneDrive" ]),
		JSONValue([ "117": "The requested directory to delete was found in the local database. Processing the deletion normally" ]),
		JSONValue([ "118": "The requested directory to rename was not found on OneDrive" ]),
		JSONValue([ "119": "Applying changes of Path ID: " ]),
		JSONValue([ "120": "Updated Remaining Free Space: " ]),
		JSONValue([ "121": "OneDrive quota information is set at zero, as this is not our drive id, ignoring" ]),
		JSONValue([ "122": "No details returned for given Path ID" ]),
		JSONValue([ "123": "ERROR: A potential local database consistency issue has been caught. Please retry your command with '--resync' to fix any local database consistency issues." ]),
		JSONValue([ "124": "OneDrive returned a 'HTTP 504 - Gateway Timeout' when attempting to query the OneDrive API - retrying the applicable request" ]),
		JSONValue([ "125": "Processing " ]),
		JSONValue([ "126": " OneDrive items to ensure consistent local state due to a full scan being triggered by actions on OneDrive" ]),
		JSONValue([ "127": " OneDrive items to ensure consistent local state due to a full scan being requested" ]),
		JSONValue([ "128": " OneDrive items to ensure consistent local state" ]),
		JSONValue([ "129": " OneDrive items to ensure consistent local state due to sync_list being used" ]),
		JSONValue([ "130": "Number of items from OneDrive to process: " ]),
		JSONValue([ "131": "Remote change discarded - item cannot be found" ]),
		JSONValue([ "132": "Remote change discarded - not in --single-directory sync scope (in DB)" ]),
		JSONValue([ "133": "Remote change discarded - not in sync scope" ]),
		JSONValue([ "134": "Remote change discarded - not in --single-directory sync scope (not in DB)" ]),
		JSONValue([ "135": "Remote change discarded - not in business shared folders sync scope" ]),
		JSONValue([ "136": "Skipping item - file path is excluded by skip_dir config: " ]),
		JSONValue([ "137": "Skipping item - excluded by skip_file config: " ]),
		JSONValue([ "138": "Skipping file - parent path not present in local database" ]),
		JSONValue([ "139": "The Microsoft OneNote Notebook '" ]),
		JSONValue([ "140": "' is not supported by this client" ]),
		JSONValue([ "141": "The OneDrive item '" ]),
		JSONValue([ "142": "Flagging as unwanted: item type is not supported" ]),
		JSONValue([ "143": "Skipping item - excluded by sync_list config: " ]),
		JSONValue([ "144": "Flagging item for local delete as item exists in database: " ]),
		JSONValue([ "145": "Skipping item - .file or .folder: " ]),
		JSONValue([ "146": "Local item modified time is equal to OneDrive item modified time based on UTC time conversion - keeping local item" ]),
		JSONValue([ "147": "Local item modified time is newer than OneDrive item modified time based on UTC time conversion - keeping local item" ]),
		JSONValue([ "148": "Remote item modified time is newer based on UTC time conversion" ]),
		JSONValue([ "149": "WARNING: Local Data Protection has been disabled by your configuration. You may experience data loss on this file: " ]),
		JSONValue([ "150": "The local item is out-of-sync with OneDrive, renaming to preserve existing file and prevent data loss: " ]),
		JSONValue([ "151": "Skipping item - excluded by skip_size config: " ]),
		JSONValue([ "152": "Local item modified time is newer based on UTC time conversion - keeping local item as this exists in the local database" ]),
		JSONValue([ "153": "Skipping downloading item - .nosync found in parent folder & --check-for-nosync is enabled: " ]),
		JSONValue([ "154": "Removing previous partial file download due to .nosync found in parent folder & --check-for-nosync is enabled" ]),
		JSONValue([ "155": "Local item does not exist in local database - replacing with file from OneDrive - failed download?" ]),
		JSONValue([ "156": "The local item is out-of-sync with OneDrive, renaming to preserve existing file and prevent data loss due to --resync: " ]),
		JSONValue([ "157": "Remote item modified time is newer based on UTC time conversion" ]),
		JSONValue([ "158": "Creating local directory: " ]),
		JSONValue([ "159": "Moving " ]),
		JSONValue([ "160": " to " ]),
		JSONValue([ "161": "Destination is in sync and will be overwritten" ]),
		JSONValue([ "162": "The destination is occupied, renaming the conflicting file..." ]),
		JSONValue([ "163": "The destination is occupied by new file, renaming the conflicting file..." ]),
		JSONValue([ "164": "Downloading file " ]),
		JSONValue([ "165": "ERROR: Query of OneDrive for file details failed" ]),
		JSONValue([ "166": "ERROR: MALWARE DETECTED IN FILE - DOWNLOAD SKIPPED" ]),
		JSONValue([ "167": "ERROR: File download size mis-match. Increase logging verbosity to determine why." ]),
		JSONValue([ "168": "ERROR: File download hash mis-match. Increase logging verbosity to determine why." ]),
		JSONValue([ "169": "ERROR: File failed to download. Increase logging verbosity to determine why." ]),
		JSONValue([ "170": "done." ]),
		JSONValue([ "171": " ... done." ]),
		JSONValue([ "172": "The local item has a different modified time " ]),
		JSONValue([ "173": " when compared to " ]),
		JSONValue([ "174": " modified time " ]),
		JSONValue([ "175": "The local item has a different hash when compared to " ]),
		JSONValue([ "176": " item hash" ]),
		JSONValue([ "177": "Unable to determine the sync state of this file as it cannot be read (file permissions or file corruption): " ]),
		JSONValue([ "178": "The local item is a directory but should be a file" ]),
		JSONValue([ "179": "The local item is a file but should be a directory" ]),
		JSONValue([ "180": "Trying to delete item " ]),
		JSONValue([ "181": "ERROR: The requested single directory to sync was not found on OneDrive - Check folder permissions and sharing status with folder owner" ]),
		JSONValue([ "182": "Skipped due to id difference!" ]),
		JSONValue([ "183": "Deleting item " ]),
		JSONValue([ "184": "Uploading differences of " ]),
		JSONValue([ "185": "Uploading new items of " ]),
		JSONValue([ "186": "Skipping item - .nosync found & --check-for-nosync enabled: " ]),
		JSONValue([ "187": "Skipping item - invalid name (Microsoft Naming Convention): " ]),
		JSONValue([ "188": "Skipping item - invalid name (Contains an invalid whitespace item): " ]),
		JSONValue([ "189": "Skipping item - invalid name (Contains HTML ASCII Code): " ]),
		JSONValue([ "190": "The item was a directory but now it is a file" ]),
		JSONValue([ "191": "The directory has not changed" ]),
		JSONValue([ "192": "The directory has been deleted locally" ]),
		JSONValue([ "193": "The directory appears to have been deleted locally .. but we are running in --monitor mode. This may have been 'moved' on the local filesystem rather than being 'deleted'" ]),
		JSONValue([ "194": "Skipping remote directory delete as --upload-only & --no-remote-delete configured" ]),
		JSONValue([ "195": "The file last modified time has changed" ]),
		JSONValue([ "196": "The file content has changed" ]),
		JSONValue([ "197": "Uploading modified file " ]),
		JSONValue([ "198": "skipped." ]),
		JSONValue([ "199": " is currently checked out or locked for editing by another user." ]),
		JSONValue([ "200": "Skip Reason: Microsoft OneDrive does not support 'zero-byte' files as a modified upload. Will upload as new file." ]),
		JSONValue([ "201": "Remaining free space on OneDrive: " ]),
		JSONValue([ "202": "The file has not changed" ]),
		JSONValue([ "203": "Skipping processing this file as it cannot be read (file permissions or file corruption): " ]),
		JSONValue([ "204": "The item was a file but now is a directory" ]),
		JSONValue([ "205": "The file has been deleted locally" ]),
		JSONValue([ "206": "The file appears to have been deleted locally .. but we are running in --monitor mode. This may have been 'moved' on the local filesystem rather than being 'deleted'" ]),
		JSONValue([ "207": "Skipping remote file delete as --upload-only & --no-remote-delete configured" ]),
		JSONValue([ "208": "Skip Reason: Microsoft Sharepoint 'enrichment' after upload issue" ]),
		JSONValue([ "209": "See: https://github.com/OneDrive/onedrive-api-docs/issues/935 for further details" ]),
		JSONValue([ "210": "Skipping item - path has disappeared: " ]),
		JSONValue([ "211": "Skipping item - invalid UTF sequence: " ]),
		JSONValue([ "212": "Skipping item - invalid character encoding sequence: " ]),
		JSONValue([ "213": "Skipping item - skip symbolic links configured: " ]),
		JSONValue([ "214": "Skipping item - invalid symbolic link: " ]),
		JSONValue([ "215": "Skipping item - excluded as included in business_shared_folders config: " ]),
		JSONValue([ "216": "To sync this directory to your OneDrive Account update your business_shared_folders config" ]),
		JSONValue([ "217": "Skipping item - path excluded by user config: " ]),
		JSONValue([ "218": "Directory disappeared during upload: " ]),
		JSONValue([ "219": "Skipping item - item is not a valid file: " ]),
		JSONValue([ "220": "Skipping item '" ]),
		JSONValue([ "221": "' due to the full path exceeding " ]),
		JSONValue([ "222": " characters (Microsoft OneDrive limitation)" ]),
		JSONValue([ "223": "OneDrive Client requested to create remote path: " ]),
		JSONValue([ "224": "The requested directory to create was not found on OneDrive - creating remote directory: " ]),
		JSONValue([ "225": "OneDrive generated an error when creating this path: " ]),
		JSONValue([ "226": "Successfully created the remote directory " ]),
		JSONValue([ "227": " on OneDrive" ]),
		JSONValue([ "228": "The requested directory to create was found on OneDrive - skipping creating the directory: " ]),
		JSONValue([ "229": "The parent for this path is not in the local database - need to add parent to local database" ]),
		JSONValue([ "230": "The parent for this path has been added to the local database - adding requested path (" ]),
		JSONValue([ "231": ") to the database" ]),
		JSONValue([ "232": "The parent for this path is in the local database - adding requested path (" ]),
		JSONValue([ "233": "ERROR: Current directory has a 'case-insensitive match' to an existing directory on OneDrive" ]),
		JSONValue([ "234": "ERROR: To resolve, rename this local directory: " ]),
		JSONValue([ "235": "ERROR: Remote OneDrive directory: " ]),
		JSONValue([ "236": "Skipping: " ]),
		JSONValue([ "237": "ERROR: There was an error performing this operation on OneDrive" ]),
		JSONValue([ "238": "ERROR: Increase logging verbosity to assist determining why." ]),
		JSONValue([ "239": "Skipping uploading this new file: " ]),
		JSONValue([ "240": "ERROR: To resolve, rename this local file: " ]),
		JSONValue([ "241": "Skipping item - excluded by skip_size config: " ]),
		JSONValue([ "242": "Uploading new file " ]),
		JSONValue([ "243": "WARNING: Uploaded file size does not match local file - skipping upload validation" ]),
		JSONValue([ "244": "WARNING: Due to Microsoft Sharepoint 'enrichment' of files, this file is now technically different to your local copy" ]),
		JSONValue([ "245": "Uploaded file size does not match local file - upload failure - retrying" ]),
		JSONValue([ "246": "File disappeared after upload: " ]),
		JSONValue([ "247": " ... error" ]),
		JSONValue([ "248": "Requested file to upload exists on OneDrive - local database is out of sync for this file: " ]),
		JSONValue([ "249": "Requested file to upload is newer than existing file on OneDrive" ]),
		JSONValue([ "250": "Updating the local database with details for this file: " ]),
		JSONValue([ "251": "ERROR: A local file has the same name as another local file." ]),
		JSONValue([ "252": "ERROR: An error was returned from OneDrive and the resulting response is not a valid JSON object" ]),
		JSONValue([ "253": "ERROR: Increase logging verbosity to assist determining why." ]),
		JSONValue([ "254": "Skipping uploading this new file as it exceeds the maximum size allowed by OneDrive: " ]),
		JSONValue([ "255": "Skipping uploading this file as it cannot be read (file permissions or file corruption): " ]),
		JSONValue([ "256": "Skipping uploading this new file as parent path is not in the database: " ]),
		JSONValue([ "257": "' due to insufficient free space available on OneDrive" ]),
		
		
		
	]);
	
	// Load the message into the array
	ulong thisMessageID = 0;
	foreach (translationItem; languageList["list"].array) {
		thisMessageID++;
		string responseString = translationItem[to!string(thisMessageID)].str;
		languageResponsesDefault ~= responseString;
	}
}
