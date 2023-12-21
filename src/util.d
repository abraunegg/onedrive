// What is this module called?
module util;

// What does this module require to function?
import core.stdc.stdlib: EXIT_SUCCESS, EXIT_FAILURE, exit;
import std.base64;
import std.conv;
import std.digest.crc;
import std.digest.sha;
import std.net.curl;
import std.datetime;
import std.file;
import std.path;
import std.regex;
import std.socket;
import std.stdio;
import std.string;
import std.algorithm;
import std.uri;
import std.json;
import std.traits;
import core.stdc.stdlib;
import core.thread;
import core.memory;
import std.math;
import std.format;
import std.random;
import std.array;
import std.ascii;
import std.range;
import core.sys.posix.pwd;
import core.sys.posix.unistd;
import core.stdc.string : strlen;

// What other modules that we have created do we need to import?
import log;
import config;
import qxor;
import curlEngine;

// module variables
shared string deviceName;

static this() {
	deviceName = Socket.hostName;
}

// Creates a safe backup of the given item, and only performs the function if not in a --dry-run scenario
void safeBackup(const(char)[] path, bool dryRun) {
	auto ext = extension(path);
	auto newPath = path.chomp(ext) ~ "-" ~ deviceName;
	if (exists(newPath ~ ext)) {
		int n = 2;
		char[] newPath2;
		do {
			newPath2 = newPath ~ "-" ~ n.to!string;
			n++;
		} while (exists(newPath2 ~ ext));
		newPath = newPath2;
	}
	newPath ~= ext;
	
	// Log that we are perform the backup by renaming the file
	addLogEntry("The local item is out-of-sync with OneDrive, renaming to preserve existing file and prevent local data loss: " ~ to!string(path) ~ " -> " ~ to!string(newPath));
	
	// Are we in a --dry-run scenario?
	if (!dryRun) {
		// Not a --dry-run scenario - do the file rename
		//
		// There are 2 options to rename a file
		// rename() - https://dlang.org/library/std/file/rename.html
		// std.file.copy() - https://dlang.org/library/std/file/copy.html
		//
		// rename:
		//   It is not possible to rename a file across different mount points or drives. On POSIX, the operation is atomic. That means, if to already exists there will be no time period during the operation where to is missing.
		//
		// std.file.copy
		//   Copy file from to file to. File timestamps are preserved. File attributes are preserved, if preserve equals Yes.preserveAttributes
		//
		// Use rename() as Linux is POSIX compliant, we have an atomic operation where at no point in time the 'to' is missing.
		rename(path, newPath);
	} else {
		addLogEntry("DRY-RUN: Skipping renaming local file to preserve existing file and prevent data loss: " ~ to!string(path) ~ " -> " ~ to!string(newPath), ["debug"]);
	}
}

// deletes the specified file without throwing an exception if it does not exists
void safeRemove(const(char)[] path) {
	if (exists(path)) remove(path);
}

// returns the SHA1 hash hex string of a file
string computeSha1Hash(string path) {
	SHA1 sha;
	auto file = File(path, "rb");
	foreach (ubyte[] data; chunks(file, 4096)) {
		sha.put(data);
	}
	return sha.finish().toHexString().dup;
}

// returns the quickXorHash base64 string of a file
string computeQuickXorHash(string path) {
	QuickXor qxor;
	auto file = File(path, "rb");
	foreach (ubyte[] data; chunks(file, 4096)) {
		qxor.put(data);
	}
	return Base64.encode(qxor.finish());
}

// returns the SHA256 hex string of a file
string computeSHA256Hash(string path) {
	SHA256 sha256;
    auto file = File(path, "rb");
    foreach (ubyte[] data; chunks(file, 4096)) {
        sha256.put(data);
    }
    return sha256.finish().toHexString().dup;
}

// converts wildcards (*, ?) to regex
Regex!char wild2regex(const(char)[] pattern) {
	string str;
	str.reserve(pattern.length + 2);
	str ~= "^";
	foreach (c; pattern) {
		switch (c) {
		case '*':
			str ~= "[^/]*";
			break;
		case '.':
			str ~= "\\.";
			break;
		case '?':
			str ~= "[^/]";
			break;
		case '|':
			str ~= "$|^";
			break;
		case '+':
			str ~= "\\+";
			break;
		case ' ':
			str ~= "\\s+";
			break;	
		case '/':
			str ~= "\\/";
			break;
		case '(':
			str ~= "\\(";
			break;
		case ')':
			str ~= "\\)";
			break;
		default:
			str ~= c;
			break;
		}
	}
	str ~= "$";
	return regex(str, "i");
}

// Test Internet access to Microsoft OneDrive
bool testInternetReachability(ApplicationConfig appConfig) {
	// Use preconfigured object with all the correct http values assigned
	auto curlEngine = new CurlEngine();
	curlEngine.initialise(appConfig.getValueLong("dns_timeout"), appConfig.getValueLong("connect_timeout"), appConfig.getValueLong("data_timeout"), appConfig.getValueLong("operation_timeout"), appConfig.defaultMaxRedirects, appConfig.getValueBool("debug_https"), appConfig.getValueString("user_agent"), appConfig.getValueBool("force_http_11"), appConfig.getValueLong("rate_limit"), appConfig.getValueLong("ip_protocol_version"));
	
	// Configure the remaining items required
	// URL to use
	// HTTP connection test method
	curlEngine.connect(HTTP.Method.head, "https://login.microsoftonline.com");
	// Attempt to contact the Microsoft Online Service
	try {
		addLogEntry("Attempting to contact Microsoft OneDrive Login Service", ["debug"]);
		curlEngine.http.perform();
		addLogEntry("Shutting down HTTP engine as successfully reached OneDrive Login Service", ["debug"]);
		curlEngine.http.shutdown();
		// Free object and memory
		object.destroy(curlEngine);
		return true;
	} catch (SocketException e) {
		// Socket issue
		addLogEntry("HTTP Socket Issue", ["debug"]);
		addLogEntry("Cannot connect to Microsoft OneDrive Login Service - Socket Issue");
		displayOneDriveErrorMessage(e.msg, getFunctionName!({}));
		return false;
	} catch (CurlException e) {
		// No network connection to OneDrive Service
		addLogEntry("No Network Connection", ["debug"]);
		addLogEntry("Cannot connect to Microsoft OneDrive Login Service - Network Connection Issue");
		displayOneDriveErrorMessage(e.msg, getFunctionName!({}));
		return false;
	}
}

// Retry Internet access test to Microsoft OneDrive
bool retryInternetConnectivtyTest(ApplicationConfig appConfig) {
	// re-try network connection to OneDrive
	// https://github.com/abraunegg/onedrive/issues/1184
	// Back off & retry with incremental delay
	int retryCount = 10000;
	int retryAttempts = 1;
	int backoffInterval = 1;
	int maxBackoffInterval = 3600;
	bool onlineRetry = false;
	bool retrySuccess = false;
	while (!retrySuccess){
		// retry to access OneDrive API
		backoffInterval++;
		int thisBackOffInterval = retryAttempts*backoffInterval;
		addLogEntry("  Retry Attempt:      " ~ to!string(retryAttempts), ["debug"]);
		
		if (thisBackOffInterval <= maxBackoffInterval) {
			addLogEntry("  Retry In (seconds): " ~ to!string(thisBackOffInterval), ["debug"]);
			Thread.sleep(dur!"seconds"(thisBackOffInterval));
		} else {
			addLogEntry("  Retry In (seconds): " ~ to!string(maxBackoffInterval), ["debug"]);
			Thread.sleep(dur!"seconds"(maxBackoffInterval));
		}
		// perform the re-rty
		onlineRetry = testInternetReachability(appConfig);
		if (onlineRetry) {
			// We are now online
			addLogEntry("Internet connectivity to Microsoft OneDrive service has been restored");
			retrySuccess = true;
		} else {
			// We are still offline
			if (retryAttempts == retryCount) {
				// we have attempted to re-connect X number of times
				// false set this to true to break out of while loop
				retrySuccess = true;
			}
		}
		// Increment & loop around
		retryAttempts++;
	}
	if (!onlineRetry) {
		// Not online after 1.2 years of trying
		addLogEntry("ERROR: Was unable to reconnect to the Microsoft OneDrive service after 10000 attempts lasting over 1.2 years!");
	}
	// return the state
	return onlineRetry;
}

// Can we read the local file - as a permissions issue or file corruption will cause a failure
// https://github.com/abraunegg/onedrive/issues/113
// returns true if file can be accessed
bool readLocalFile(string path) {
	try {
		// attempt to read up to the first 1 byte of the file
		// validates we can 'read' the file based on file permissions
		read(path,1);
	} catch (std.file.FileException e) {
		// unable to read the new local file
		displayFileSystemErrorMessage(e.msg, getFunctionName!({}));
		return false;
	}
	return true;
}

// calls globMatch for each string in pattern separated by '|'
bool multiGlobMatch(const(char)[] path, const(char)[] pattern) {
	foreach (glob; pattern.split('|')) {
		if (globMatch!(std.path.CaseSensitive.yes)(path, glob)) {
			return true;
		}
	}
	return false;
}

bool isValidName(string path) {
	// Restriction and limitations about windows naming files
	// https://msdn.microsoft.com/en-us/library/aa365247
	// https://support.microsoft.com/en-us/help/3125202/restrictions-and-limitations-when-you-sync-files-and-folders

	// allow root item
	if (path == ".") {
		return true;
	}

	string itemName = baseName(path);

	// Check for explicitly disallowed names
	// https://support.microsoft.com/en-us/office/restrictions-and-limitations-in-onedrive-and-sharepoint-64883a5d-228e-48f5-b3d2-eb39e07630fa?ui=en-us&rs=en-us&ad=us#invalidfilefoldernames
	string[] disallowedNames = [
		".lock", "desktop.ini", "CON", "PRN", "AUX", "NUL",
		"COM0", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
		"LPT0", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9", "_vti_"
	];

	if (canFind(disallowedNames, itemName) || itemName.startsWith("~$")) {
		return false;
	}

	// Regular expression for invalid patterns
	auto invalidNameReg =
		ctRegex!(
			// https://support.microsoft.com/en-us/office/restrictions-and-limitations-in-onedrive-and-sharepoint-64883a5d-228e-48f5-b3d2-eb39e07630fa?ui=en-us&rs=en-us&ad=us#invalidcharacters
			// Leading whitespace and trailing whitespace/dot
			`^\s.*|^.*[\s\.]$|` ~
			// Invalid characters - 
			`.*[<>:"\|\?*/\\].*`
		);

	auto m = match(itemName, invalidNameReg);
	bool matched = m.empty;

	// Check if "_vti_" appears anywhere in a file name
	if (canFind(itemName, "_vti_")) {
		matched = false;
	}

	// Determine if the path is at the root level, if yes, check that 'forms' is not the first folder
	auto segments = pathSplitter(path).array;
	if (segments.length <= 2 && itemName.toLower() == "forms") { // Convert to lower as OneDrive is not POSIX compliant, easier to compare
		matched = false;
	}

	return matched;
}

bool containsBadWhiteSpace(string path) {
	// allow root item
	if (path == ".") {
		return true;
	}
	
	// https://github.com/abraunegg/onedrive/issues/35
	// Issue #35 presented an interesting issue where the filename contained a newline item
	//		'State-of-the-art, challenges, and open issues in the integration of Internet of'$'\n''Things and Cloud Computing.pdf'
	// When the check to see if this file was present the GET request queries as follows:
	//		/v1.0/me/drive/root:/.%2FState-of-the-art%2C%20challenges%2C%20and%20open%20issues%20in%20the%20integration%20of%20Internet%20of%0AThings%20and%20Cloud%20Computing.pdf
	// The '$'\n'' is translated to %0A which causes the OneDrive query to fail
	// Check for the presence of '%0A' via regex
	
	string itemName = encodeComponent(baseName(path));
	auto invalidWhitespaceReg =
		ctRegex!(
			// Check for \n which is %0A when encoded
			`%0A`
		);
	auto m = match(itemName, invalidWhitespaceReg);
	return m.empty;
}

bool containsASCIIHTMLCodes(string path) {
	// https://github.com/abraunegg/onedrive/issues/151
	// If a filename contains ASCII HTML codes, regardless of if it gets encoded, it generates an error
	// Check if the filename contains an ASCII HTML code sequence

	auto invalidASCIICode = 
		ctRegex!(
			// Check to see if &#XXXX is in the filename
			`(?:&#|&#[0-9][0-9]|&#[0-9][0-9][0-9]|&#[0-9][0-9][0-9][0-9])`
		);
	
	auto m = match(path, invalidASCIICode);
	return m.empty;
}

// Parse and display error message received from OneDrive
void displayOneDriveErrorMessage(string message, string callingFunction) {
	addLogEntry();
	addLogEntry("ERROR: Microsoft OneDrive API returned an error with the following message:");
	auto errorArray = splitLines(message);
	addLogEntry("  Error Message:    " ~ to!string(errorArray[0]));
	// Extract 'message' as the reason
	JSONValue errorMessage = parseJSON(replace(message, errorArray[0], ""));
	
	// What is the reason for the error
	if (errorMessage.type() == JSONType.object) {
		// configure the error reason
		string errorReason;
		string errorCode;
		string requestDate;
		string requestId;
		
		// set the reason for the error
		try {
			// Use error_description as reason
			errorReason = errorMessage["error_description"].str;
		} catch (JSONException e) {
			// we dont want to do anything here
		}
		
		// set the reason for the error
		try {
			// Use ["error"]["message"] as reason
			errorReason = errorMessage["error"]["message"].str;	
		} catch (JSONException e) {
			// we dont want to do anything here
		}
		
		// Display the error reason
		if (errorReason.startsWith("<!DOCTYPE")) {
			// a HTML Error Reason was given
			addLogEntry("  Error Reason:  A HTML Error response was provided. Use debug logging (--verbose --verbose) to view this error");
			addLogEntry(errorReason, ["debug"]);
			
		} else {
			// a non HTML Error Reason was given
			addLogEntry("  Error Reason:     " ~ errorReason);
		}
		
		// Get the error code if available
		try {
			// Use ["error"]["code"] as code
			errorCode = errorMessage["error"]["code"].str;
		} catch (JSONException e) {
			// we dont want to do anything here
		}
		
		// Get the date of request if available
		try {
			// Use ["error"]["innerError"]["date"] as date
			requestDate = errorMessage["error"]["innerError"]["date"].str;	
		} catch (JSONException e) {
			// we dont want to do anything here
		}
		
		// Get the request-id if available
		try {
			// Use ["error"]["innerError"]["request-id"] as request-id
			requestId = errorMessage["error"]["innerError"]["request-id"].str;	
		} catch (JSONException e) {
			// we dont want to do anything here
		}
		
		// Display the error code, date and request id if available
		if (errorCode != "")   addLogEntry("  Error Code:       " ~ errorCode);
		if (requestDate != "") addLogEntry("  Error Timestamp:  " ~ requestDate);
		if (requestId != "")   addLogEntry("  API Request ID:   " ~ requestId);
	}
	
	// Where in the code was this error generated
	addLogEntry("  Calling Function: " ~ callingFunction, ["verbose"]);
	
	// Extra Debug if we are using --verbose --verbose
	addLogEntry("Raw Error Data: " ~ message, ["debug"]);
	addLogEntry("JSON Message: " ~ to!string(errorMessage), ["debug"]);
}

// Common code for handling when a client is unauthorised
void handleClientUnauthorised(int httpStatusCode, string message) {
	// Split the lines of the error message
	auto errorArray = splitLines(message);
	// Extract 'message' as the reason
	JSONValue errorMessage = parseJSON(replace(message, errorArray[0], ""));
	addLogEntry("errorMessage: " ~ to!string(errorMessage), ["debug"]);
	
	if (httpStatusCode == 400) {
		// bad request or a new auth token is needed
		// configure the error reason
		addLogEntry();
		string[] errorReason = splitLines(errorMessage["error_description"].str);
		addLogEntry(to!string(errorReason[0]), ["info", "notify"]);
		addLogEntry();
		addLogEntry("ERROR: You will need to issue a --reauth and re-authorise this client to obtain a fresh auth token.", ["info", "notify"]);
		addLogEntry();
	}
	
	if (httpStatusCode == 401) {
		writeln("CODING TO DO: Triggered a 401 HTTP unauthorised response when client was unauthorised");
		addLogEntry();
		addLogEntry("ERROR: Check your configuration as your refresh_token may be empty or invalid. You may need to issue a --reauth and re-authorise this client.", ["info", "notify"]);
		addLogEntry();
	}
	
	// Must exit here
	exit(EXIT_FAILURE);
}

// Parse and display error message received from the local file system
void displayFileSystemErrorMessage(string message, string callingFunction) {
	addLogEntry(); // used rather than writeln
	addLogEntry("ERROR: The local file system returned an error with the following message:");
	auto errorArray = splitLines(message);
	// What was the error message
	addLogEntry("  Error Message:    " ~ to!string(errorArray[0]));
	// Where in the code was this error generated
	addLogEntry("  Calling Function: " ~ callingFunction, ["verbose"]);
	// If we are out of disk space (despite download reservations) we need to exit the application
	ulong localActualFreeSpace = to!ulong(getAvailableDiskSpace("."));
	if (localActualFreeSpace == 0) {
		// force exit
		exit(EXIT_FAILURE);
	}
}

// Display the POSIX Error Message
void displayPosixErrorMessage(string message) {
	addLogEntry(); // used rather than writeln
	addLogEntry("ERROR: Microsoft OneDrive API returned data that highlights a POSIX compliance issue:");
	addLogEntry("  Error Message:    " ~ message);
}

// Get the function name that is being called to assist with identifying where an error is being generated
string getFunctionName(alias func)() {
    return __traits(identifier, __traits(parent, func)) ~ "()\n";
}

// Get the latest release version from GitHub
JSONValue getLatestReleaseDetails() {
	// Import curl just for this function
	import std.net.curl;
	char[] content;
	JSONValue githubLatest;
	JSONValue versionDetails;
	string latestTag;
	string publishedDate;
	
	try {
		content = get("https://api.github.com/repos/abraunegg/onedrive/releases/latest");
	} catch (CurlException e) {
		// curl generated an error - meaning we could not query GitHub
		addLogEntry("Unable to query GitHub for latest release", ["debug"]);
	}
	
	try {
		githubLatest = content.parseJSON();
	} catch (JSONException e) {
		// unable to parse the content JSON, set to blank JSON
		addLogEntry("Unable to parse GitHub JSON response", ["debug"]);
		githubLatest = parseJSON("{}");
	}
	
	// githubLatest has to be a valid JSON object
	if (githubLatest.type() == JSONType.object){
		// use the returned tag_name
		if ("tag_name" in githubLatest) {
			// use the provided tag
			// "tag_name": "vA.B.CC" and strip 'v'
			latestTag = strip(githubLatest["tag_name"].str, "v");
		} else {
			// set to latestTag zeros
			addLogEntry("'tag_name' unavailable in JSON response. Setting GitHub 'tag_name' release version to 0.0.0", ["debug"]);
			latestTag = "0.0.0";
		}
		// use the returned published_at date
		if ("published_at" in githubLatest) {
			// use the provided value
			publishedDate = githubLatest["published_at"].str;
		} else {
			// set to v2.0.0 release date
			addLogEntry("'published_at' unavailable in JSON response. Setting GitHub 'published_at' date to 2018-07-18T18:00:00Z", ["debug"]);
			publishedDate = "2018-07-18T18:00:00Z";
		}
	} else {
		// JSONValue is not an object
		addLogEntry("Invalid JSON Object response from GitHub. Setting GitHub 'tag_name' release version to 0.0.0", ["debug"]);
		latestTag = "0.0.0";
		addLogEntry("Invalid JSON Object. Setting GitHub 'published_at' date to 2018-07-18T18:00:00Z", ["debug"]);
		publishedDate = "2018-07-18T18:00:00Z";
	}
		
	// return the latest github version and published date as our own JSON
	versionDetails = [
		"latestTag": JSONValue(latestTag),
		"publishedDate": JSONValue(publishedDate)
	];
	
	// return JSON
	return versionDetails;
}

// Get the release details from the 'current' running version
JSONValue getCurrentVersionDetails(string thisVersion) {
	// Import curl just for this function
	import std.net.curl;
	char[] content;
	JSONValue githubDetails;
	JSONValue versionDetails;
	string versionTag = "v" ~ thisVersion;
	string publishedDate;
	
	try {
		content = get("https://api.github.com/repos/abraunegg/onedrive/releases");
	} catch (CurlException e) {
		// curl generated an error - meaning we could not query GitHub
		addLogEntry("Unable to query GitHub for release details", ["debug"]);
	}
	
	try {
		githubDetails = content.parseJSON();
	} catch (JSONException e) {
		// unable to parse the content JSON, set to blank JSON
		addLogEntry("Unable to parse GitHub JSON response", ["debug"]);
		githubDetails = parseJSON("{}");
	}
	
	// githubDetails has to be a valid JSON array
	if (githubDetails.type() == JSONType.array){
		foreach (searchResult; githubDetails.array) {
			// searchResult["tag_name"].str;
			if (searchResult["tag_name"].str == versionTag) {
				addLogEntry("MATCHED version", ["debug"]);
				addLogEntry("tag_name: " ~ searchResult["tag_name"].str, ["debug"]);
				addLogEntry("published_at: " ~ searchResult["published_at"].str, ["debug"]);
				publishedDate = searchResult["published_at"].str;
			}
		}
		
		if (publishedDate.empty) {
			// empty .. no version match ?
			// set to v2.0.0 release date
			addLogEntry("'published_at' unavailable in JSON response. Setting GitHub 'published_at' date to 2018-07-18T18:00:00Z", ["debug"]);
			publishedDate = "2018-07-18T18:00:00Z";
		}
	} else {
		// JSONValue is not an Array
		addLogEntry("Invalid JSON Array. Setting GitHub 'published_at' date to 2018-07-18T18:00:00Z", ["debug"]);
		publishedDate = "2018-07-18T18:00:00Z";
	}
		
	// return the latest github version and published date as our own JSON
	versionDetails = [
		"versionTag": JSONValue(thisVersion),
		"publishedDate": JSONValue(publishedDate)
	];
	
	// return JSON
	return versionDetails;
}

// Check the application version versus GitHub latestTag
void checkApplicationVersion() {
	// Get the latest details from GitHub
	JSONValue latestVersionDetails = getLatestReleaseDetails();
	string latestVersion = latestVersionDetails["latestTag"].str;
	SysTime publishedDate = SysTime.fromISOExtString(latestVersionDetails["publishedDate"].str).toUTC();
	SysTime releaseGracePeriod = publishedDate;
	SysTime currentTime = Clock.currTime().toUTC();
	
	// drop fraction seconds
	publishedDate.fracSecs = Duration.zero;
	currentTime.fracSecs = Duration.zero;
	releaseGracePeriod.fracSecs = Duration.zero;
	// roll the grace period forward to allow distributions to catch up based on their release cycles
	releaseGracePeriod = releaseGracePeriod.add!"months"(1);

	// what is this clients version?
	auto currentVersionArray = strip(strip(import("version"), "v")).split("-");
	string applicationVersion = currentVersionArray[0];
	
	// debug output
	addLogEntry("applicationVersion:       " ~ applicationVersion, ["debug"]);
	addLogEntry("latestVersion:            " ~ latestVersion, ["debug"]);
	addLogEntry("publishedDate:            " ~ to!string(publishedDate), ["debug"]);
	addLogEntry("currentTime:              " ~ to!string(currentTime), ["debug"]);
	addLogEntry("releaseGracePeriod:       " ~ to!string(releaseGracePeriod), ["debug"]);
	
	// display details if not current
	// is application version is older than available on GitHub
	if (applicationVersion != latestVersion) {
		// application version is different
		bool displayObsolete = false;
		
		// what warning do we present?
		if (applicationVersion < latestVersion) {
			// go get this running version details
			JSONValue thisVersionDetails = getCurrentVersionDetails(applicationVersion);
			SysTime thisVersionPublishedDate = SysTime.fromISOExtString(thisVersionDetails["publishedDate"].str).toUTC();
			thisVersionPublishedDate.fracSecs = Duration.zero;
			addLogEntry("thisVersionPublishedDate: " ~ to!string(thisVersionPublishedDate), ["debug"]);
			
			// the running version grace period is its release date + 1 month
			SysTime thisVersionReleaseGracePeriod = thisVersionPublishedDate;
			thisVersionReleaseGracePeriod = thisVersionReleaseGracePeriod.add!"months"(1);
			addLogEntry("thisVersionReleaseGracePeriod: " ~ to!string(thisVersionReleaseGracePeriod), ["debug"]);
			
			// Is this running version obsolete ?
			if (!displayObsolete) {
				// if releaseGracePeriod > currentTime
				// display an information warning that there is a new release available
				if (releaseGracePeriod.toUnixTime() > currentTime.toUnixTime()) {
					// inside release grace period ... set flag to false
					displayObsolete = false;
				} else {
					// outside grace period
					displayObsolete = true;
				}
			}
			
			// display version response
			addLogEntry();
			if (!displayObsolete) {
				// display the new version is available message
				addLogEntry("INFO: A new onedrive client version is available. Please upgrade your client version when possible.", ["info", "notify"]);
			} else {
				// display the obsolete message
				addLogEntry("WARNING: Your onedrive client version is now obsolete and unsupported. Please upgrade your client version.", ["info", "notify"]);
			}
			addLogEntry("Current Application Version: " ~ applicationVersion);
			addLogEntry("Version Available:           " ~ latestVersion);
			addLogEntry();
		}
	}
}

bool hasId(JSONValue item) {
	return ("id" in item) != null;
}

bool hasQuota(JSONValue item) {
	return ("quota" in item) != null;
}

bool isItemDeleted(JSONValue item) {
	return ("deleted" in item) != null;
}

bool isItemRoot(JSONValue item) {
	return ("root" in item) != null;
}

bool hasParentReference(const ref JSONValue item) {
	return ("parentReference" in item) != null;
}

bool hasParentReferenceId(JSONValue item) {
	return ("id" in item["parentReference"]) != null;
}

bool hasParentReferencePath(JSONValue item) {
	return ("path" in item["parentReference"]) != null;
}

bool isFolderItem(const ref JSONValue item) {
	return ("folder" in item) != null;
}

bool isFileItem(const ref JSONValue item) {
	return ("file" in item) != null;
}

bool isItemRemote(const ref JSONValue item) {
	return ("remoteItem" in item) != null;
}

bool isItemFile(const ref JSONValue item) {
	return ("file" in item) != null;
}

bool isItemFolder(const ref JSONValue item) {
	return ("folder" in item) != null;
}

bool hasFileSize(const ref JSONValue item) {
	return ("size" in item) != null;
}

bool isDotFile(const(string) path) {
	// always allow the root
	if (path == ".") return false;
	auto paths = pathSplitter(buildNormalizedPath(path));
	foreach(base; paths) {
		if (startsWith(base, ".")){
			return true;
		}
	}
	return false;
}

bool isMalware(const ref JSONValue item) {
	return ("malware" in item) != null;
}

bool hasHashes(const ref JSONValue item) {
	return ("hashes" in item["file"]) != null;
}

bool hasQuickXorHash(const ref JSONValue item) {
	return ("quickXorHash" in item["file"]["hashes"]) != null;
}

bool hasSHA256Hash(const ref JSONValue item) {
	return ("sha256Hash" in item["file"]["hashes"]) != null;
}

bool isMicrosoftOneNoteMimeType1(const ref JSONValue item) {
	return (item["file"]["mimeType"].str) == "application/msonenote";
}

bool isMicrosoftOneNoteMimeType2(const ref JSONValue item) {
	return (item["file"]["mimeType"].str) == "application/octet-stream";
}

bool hasUploadURL(const ref JSONValue item) {
	return ("uploadUrl" in item) != null;
}

bool hasNextExpectedRanges(const ref JSONValue item) {
	return ("nextExpectedRanges" in item) != null;
}

bool hasLocalPath(const ref JSONValue item) {
	return ("localPath" in item) != null;
}

bool hasETag(const ref JSONValue item) {
	return ("eTag" in item) != null;
}

bool hasSharedElement(const ref JSONValue item) {
	return ("shared" in item) != null;
}

bool hasName(const ref JSONValue item) {
	return ("name" in item) != null;
}

// Convert bytes to GB
string byteToGibiByte(ulong bytes) {
	double gib = bytes / pow(1024.0,3);
	double roundedGib = round(gib * 100) / 100;
	return to!string(format("%.2f", roundedGib)); // Format to ensure two decimal places
}

// Test if entrypoint.sh exists on the root filesystem
bool entrypointExists() {
	// build the path
	string entrypointPath = buildNormalizedPath(buildPath("/", "entrypoint.sh"));
	// return if path exists
	return exists(entrypointPath);
}

// Generate a random alphanumeric string
string generateAlphanumericString() {
	auto asciiLetters = to!(dchar[])(letters);
	auto asciiDigits = to!(dchar[])(digits);
	dchar[16] randomString;
	fill(randomString[], randomCover(chain(asciiLetters, asciiDigits), rndGen));
	return to!string(randomString);
}

void displayMemoryUsagePreGC() {
	// Display memory usage
	writeln();
	writeln("Memory Usage pre GC (KB)");
	writeln("------------------------");
	writeMemoryStats();
	writeln();
}

void displayMemoryUsagePostGC() {
	// Display memory usage
	writeln();
	writeln("Memory Usage post GC (KB)");
	writeln("-------------------------");
	writeMemoryStats();
	writeln();
}

void writeMemoryStats() {
	// write memory stats
	writeln("memory usedSize                 = ", (GC.stats.usedSize/1024));
	writeln("memory freeSize                 = ", (GC.stats.freeSize/1024));
	writeln("memory allocatedInCurrentThread = ", (GC.stats.allocatedInCurrentThread/1024));
}

string getUserName() {
	auto pw = getpwuid(getuid);
	
	// get required details
	auto runtime_pw_name = pw.pw_name[0 .. strlen(pw.pw_name)].splitter(',');
	auto runtime_pw_uid = pw.pw_uid;
	auto runtime_pw_gid = pw.pw_gid;
	
	// User identifiers from process
	addLogEntry("Process ID: " ~ to!string(pw), ["debug"]);
	addLogEntry("User UID:   " ~ to!string(runtime_pw_uid), ["debug"]);
	addLogEntry("User GID:   " ~ to!string(runtime_pw_gid), ["debug"]);
	
	// What should be returned as username?
	if (!runtime_pw_name.empty && runtime_pw_name.front.length){
		// user resolved
		addLogEntry("User Name:  " ~ runtime_pw_name.front.idup, ["debug"]);
		return runtime_pw_name.front.idup;
	} else {
		// Unknown user?
		addLogEntry("User Name:  unknown", ["debug"]);
		return "unknown";
	}
}

int calc_eta(size_t counter, size_t iterations, ulong start_time) {
	auto ratio = cast(double)counter / iterations;
	auto current_time = Clock.currTime.toUnixTime();
	auto duration = cast(int)(current_time - start_time);

	// Segments left to download
	auto segments_remaining = (iterations - counter);
	if (segments_remaining == 0) segments_remaining = iterations;
	
	// Calculate the average time per iteration so far
	auto avg_time_per_iteration = cast(int)(duration / cast(double)counter);

	// Estimate total time for all iterations
	auto estimated_total_time = avg_time_per_iteration * iterations;
	
	// Calculate ETA as estimated total time minus elapsed time
	auto eta_sec = cast(int)(avg_time_per_iteration * segments_remaining);
	
	/**
	addLogEntry("counter: " ~ to!string(counter));
	addLogEntry("iterations: " ~ to!string(iterations));
	addLogEntry("segments_remaining: " ~ to!string(segments_remaining));
	addLogEntry("ratio: " ~ to!string(ratio));
	addLogEntry("start_time:   " ~ to!string(start_time));
	addLogEntry("current_time: " ~ to!string(current_time));
	addLogEntry("duration: " ~ to!string(duration));
	addLogEntry("avg_time_per_iteration: " ~ to!string(avg_time_per_iteration));
	addLogEntry("eta_sec: " ~ to!string(eta_sec));
	addLogEntry("estimated_total_time: " ~ to!string(estimated_total_time));
	**/

	
	// Return the ETA or duration
	// - If 'counter' != 'iterations', this means we are doing 1 .. n and this is not the last iteration of calculating the ETA
	if (counter != iterations) {
				
		// Return the ETA
		return eta_sec;
		
		/**
		// First iteration to second last
		if (counter == 2) {
			// On the second iteration, return estimated time
			return cast(int)estimated_total_time;
		} else {
			// Return the ETA
			return eta_sec;
		}
		**/
		
		
	} else {
		// Last iteration, which is done before we actually start the last iteration, so sending this as the remaining ETA is as close as we will get to an actual value
		return avg_time_per_iteration;
	}
}