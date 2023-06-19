import std.base64;
import std.conv;
import std.digest.crc, std.digest.sha;
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
import qxor;
import core.stdc.stdlib;
static import log;

shared string deviceName;

static this()
{
	deviceName = Socket.hostName;
}

// gives a new name to the specified file or directory
void safeRename(const(char)[] path)
{
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
	rename(path, newPath);
}

// deletes the specified file without throwing an exception if it does not exists
void safeRemove(const(char)[] path)
{
	if (exists(path)) remove(path);
}

// returns the quickXorHash base64 string of a file
string computeQuickXorHash(string path)
{
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
Regex!char wild2regex(const(char)[] pattern)
{
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

// returns true if the network connection is available
bool testNetwork()
{
	// Use low level HTTP struct
	auto http = HTTP();
	http.url = "https://login.microsoftonline.com";
	// DNS lookup timeout
	http.dnsTimeout = (dur!"seconds"(5));
	// Timeout for connecting
	http.connectTimeout = (dur!"seconds"(5));
	// HTTP connection test method
	http.method = HTTP.Method.head;
	// Attempt to contact the Microsoft Online Service
	try {
		log.vdebug("Attempting to contact online service");
		http.perform();
		log.vdebug("Shutting down HTTP engine as successfully reached OneDrive Online Service");
		http.shutdown();
		return true;
	} catch (SocketException e) {
		// Socket issue
		log.vdebug("HTTP Socket Issue");
		log.error("Cannot connect to Microsoft OneDrive Service - Socket Issue");
		displayOneDriveErrorMessage(e.msg, getFunctionName!({}));
		return false;
	} catch (CurlException e) {
		// No network connection to OneDrive Service
		log.vdebug("No Network Connection");
		log.error("Cannot connect to Microsoft OneDrive Service - Network Connection Issue");
		displayOneDriveErrorMessage(e.msg, getFunctionName!({}));
		return false;
	}
}

// Can we read the file - as a permissions issue or file corruption will cause a failure
// https://github.com/abraunegg/onedrive/issues/113
// returns true if file can be accessed
bool readLocalFile(string path)
{
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
bool multiGlobMatch(const(char)[] path, const(char)[] pattern)
{
	foreach (glob; pattern.split('|')) {
		if (globMatch!(std.path.CaseSensitive.yes)(path, glob)) {
			return true;
		}
	}
	return false;
}

bool isValidName(string path)
{
	// Restriction and limitations about windows naming files
	// https://msdn.microsoft.com/en-us/library/aa365247
	// https://support.microsoft.com/en-us/help/3125202/restrictions-and-limitations-when-you-sync-files-and-folders
	
	// allow root item
	if (path == ".") {
		return true;
	}

	bool matched = true;
	string itemName = baseName(path);

	auto invalidNameReg =
		ctRegex!(
			// Leading whitespace and trailing whitespace/dot
			`^\s.*|^.*[\s\.]$|` ~
			// Invalid characters
			`.*[<>:"\|\?*/\\].*|` ~
			// Reserved device name and trailing .~
			`(?:^CON|^PRN|^AUX|^NUL|^COM[0-9]|^LPT[0-9])(?:[.].+)?$`
		);
	auto m = match(itemName, invalidNameReg);
	matched = m.empty;
	
	// Additional explicit validation checks
	if (itemName == ".lock") {matched = false;}
	if (itemName == "desktop.ini") {matched = false;}
	// _vti_ cannot appear anywhere in a file or folder name
	if(canFind(itemName, "_vti_")){matched = false;}
	// Item name cannot equal '~'
	if (itemName == "~") {matched = false;}
	
	// return response
	return matched;
}

bool containsBadWhiteSpace(string path)
{
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

bool containsASCIIHTMLCodes(string path)
{
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
void displayOneDriveErrorMessage(string message, string callingFunction)
{
	writeln();
	log.error("ERROR: Microsoft OneDrive API returned an error with the following message:");
	auto errorArray = splitLines(message);
	log.error("  Error Message:    ", errorArray[0]);
	// Extract 'message' as the reason
	JSONValue errorMessage = parseJSON(replace(message, errorArray[0], ""));
	// extra debug
	log.vdebug("Raw Error Data: ", message);
	log.vdebug("JSON Message: ", errorMessage);
	
	// What is the reason for the error
	if (errorMessage.type() == JSONType.object) {
		// configure the error reason
		string errorReason;
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
			log.error("  Error Reason:  A HTML Error response was provided. Use debug logging (--verbose --verbose) to view this error");
			log.vdebug(errorReason);
		} else {
			// a non HTML Error Reason was given
			log.error("  Error Reason:     ", errorReason);
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
		
		// Display the date and request id if available
		if (requestDate != "") log.error("  Error Timestamp:  ", requestDate);
		if (requestId != "")   log.error("  API Request ID:   ", requestId);
	}
	
	// Where in the code was this error generated
	log.vlog("  Calling Function: ", callingFunction);
}

// Parse and display error message received from the local file system
void displayFileSystemErrorMessage(string message, string callingFunction) 
{
	writeln();
	log.error("ERROR: The local file system returned an error with the following message:");
	auto errorArray = splitLines(message);
	// What was the error message
	log.error("  Error Message:    ", errorArray[0]);
	// Where in the code was this error generated
	log.vlog("  Calling Function: ", callingFunction);
	// If we are out of disk space (despite download reservations) we need to exit the application
	ulong localActualFreeSpace = to!ulong(getAvailableDiskSpace("."));
	if (localActualFreeSpace == 0) {
		// force exit
		exit(-1);
	}
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
		log.vdebug("Unable to query GitHub for latest release");
	}
	
	try {
		githubLatest = content.parseJSON();
	} catch (JSONException e) {
		// unable to parse the content JSON, set to blank JSON
		log.vdebug("Unable to parse GitHub JSON response");
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
			log.vdebug("'tag_name' unavailable in JSON response. Setting GitHub 'tag_name' release version to 0.0.0");
			latestTag = "0.0.0";
		}
		// use the returned published_at date
		if ("published_at" in githubLatest) {
			// use the provided value
			publishedDate = githubLatest["published_at"].str;
		} else {
			// set to v2.0.0 release date
			log.vdebug("'published_at' unavailable in JSON response. Setting GitHub 'published_at' date to 2018-07-18T18:00:00Z");
			publishedDate = "2018-07-18T18:00:00Z";
		}
	} else {
		// JSONValue is not an object
		log.vdebug("Invalid JSON Object. Setting GitHub 'tag_name' release version to 0.0.0");
		latestTag = "0.0.0";
		log.vdebug("Invalid JSON Object. Setting GitHub 'published_at' date to 2018-07-18T18:00:00Z");
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
		log.vdebug("Unable to query GitHub for release details");
	}
	
	try {
		githubDetails = content.parseJSON();
	} catch (JSONException e) {
		// unable to parse the content JSON, set to blank JSON
		log.vdebug("Unable to parse GitHub JSON response");
		githubDetails = parseJSON("{}");
	}
	
	// githubDetails has to be a valid JSON array
	if (githubDetails.type() == JSONType.array){
		foreach (searchResult; githubDetails.array) {
			// searchResult["tag_name"].str;
			if (searchResult["tag_name"].str == versionTag) {
				log.vdebug("MATCHED version");
				log.vdebug("tag_name: ", searchResult["tag_name"].str);
				log.vdebug("published_at: ", searchResult["published_at"].str);
				publishedDate = searchResult["published_at"].str;
			}
		}
		
		if (publishedDate.empty) {
			// empty .. no version match ?
			// set to v2.0.0 release date
			log.vdebug("'published_at' unavailable in JSON response. Setting GitHub 'published_at' date to 2018-07-18T18:00:00Z");
			publishedDate = "2018-07-18T18:00:00Z";
		}
	} else {
		// JSONValue is not an Array
		log.vdebug("Invalid JSON Array. Setting GitHub 'published_at' date to 2018-07-18T18:00:00Z");
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
	log.vdebug("applicationVersion:       ", applicationVersion);
	log.vdebug("latestVersion:            ", latestVersion);
	log.vdebug("publishedDate:            ", publishedDate);
	log.vdebug("currentTime:              ", currentTime);
	log.vdebug("releaseGracePeriod:       ", releaseGracePeriod);
	
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
			log.vdebug("thisVersionPublishedDate: ", thisVersionPublishedDate);
			
			// the running version grace period is its release date + 1 month
			SysTime thisVersionReleaseGracePeriod = thisVersionPublishedDate;
			thisVersionReleaseGracePeriod = thisVersionReleaseGracePeriod.add!"months"(1);
			log.vdebug("thisVersionReleaseGracePeriod: ", thisVersionReleaseGracePeriod);
			
			// is the published latestest release date greater than the current running release date + grace period
			if (thisVersionReleaseGracePeriod.toUnixTime() < publishedDate.toUnixTime()) {
				// the running client is obsolete
				displayObsolete = true;
			}
			
			// is this running version obsolete ?
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
			writeln();
			if (!displayObsolete) {
				// display the new version is available message
				log.logAndNotify("INFO: A new onedrive client version is available. Please upgrade your client version when possible.");
			} else {
				// display the obsolete message
				log.logAndNotify("WARNING: Your onedrive client version is now obsolete and unsupported. Please upgrade your client version.");
			}
			log.log("Current Application Version: ", applicationVersion);
			log.log("Version Available:           ", latestVersion);
			writeln();
		}
	}
}

// Unit Tests
unittest
{
	assert(multiGlobMatch(".hidden", ".*"));
	assert(multiGlobMatch(".hidden", "file|.*"));
	assert(!multiGlobMatch("foo.bar", "foo|bar"));
	// that should detect invalid file/directory name.
	assert(isValidName("."));
	assert(isValidName("./general.file"));
	assert(!isValidName("./ leading_white_space"));
	assert(!isValidName("./trailing_white_space "));
	assert(!isValidName("./trailing_dot."));
	assert(!isValidName("./includes<in the path"));
	assert(!isValidName("./includes>in the path"));
	assert(!isValidName("./includes:in the path"));
	assert(!isValidName(`./includes"in the path`));
	assert(!isValidName("./includes|in the path"));
	assert(!isValidName("./includes?in the path"));
	assert(!isValidName("./includes*in the path"));
	assert(!isValidName("./includes / in the path"));
	assert(!isValidName(`./includes\ in the path`));
	assert(!isValidName(`./includes\\ in the path`));
	assert(!isValidName(`./includes\\\\ in the path`));
	assert(!isValidName("./includes\\ in the path"));
	assert(!isValidName("./includes\\\\ in the path"));
	assert(!isValidName("./CON"));
	assert(!isValidName("./CON.text"));
	assert(!isValidName("./PRN"));
	assert(!isValidName("./AUX"));
	assert(!isValidName("./NUL"));
	assert(!isValidName("./COM0"));
	assert(!isValidName("./COM1"));
	assert(!isValidName("./COM2"));
	assert(!isValidName("./COM3"));
	assert(!isValidName("./COM4"));
	assert(!isValidName("./COM5"));
	assert(!isValidName("./COM6"));
	assert(!isValidName("./COM7"));
	assert(!isValidName("./COM8"));
	assert(!isValidName("./COM9"));
	assert(!isValidName("./LPT0"));
	assert(!isValidName("./LPT1"));
	assert(!isValidName("./LPT2"));
	assert(!isValidName("./LPT3"));
	assert(!isValidName("./LPT4"));
	assert(!isValidName("./LPT5"));
	assert(!isValidName("./LPT6"));
	assert(!isValidName("./LPT7"));
	assert(!isValidName("./LPT8"));
	assert(!isValidName("./LPT9"));
}
