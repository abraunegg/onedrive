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
import std.utf;
import core.stdc.stdlib;
import core.thread;
import core.memory;
import std.math;
import std.format;
import std.random;
import std.array;
import std.ascii;
import std.range;
import std.exception;
import core.sys.posix.pwd;
import core.sys.posix.unistd;
import core.stdc.string;

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
void safeBackup(const(char)[] path, bool dryRun, out string renamedPath) {
    auto ext = extension(path);
    auto newPath = path.chomp(ext) ~ "-" ~ deviceName;
    int n = 2;
	
	// Limit to 1000 iterations .. 1000 file backups
    while (exists(newPath ~ ext) && n < 1000) { 
        newPath = newPath.chomp("-" ~ (n - 1).to!string) ~ "-" ~ n.to!string;
        n++;
    }
	
	// Check if unique file name was found
	if (exists(newPath ~ ext)) {
		// On the 1000th backup of this file, this should be triggered
		addLogEntry("Failed to backup " ~ to!string(path) ~ ": Unique file name could not be found after 1000 attempts", ["error"]);
		return; // Exit function as a unique file name could not be found
	}
	
    // Configure the new name
	newPath ~= ext;

    // Log that we are perform the backup by renaming the file
	addLogEntry("The local item is out-of-sync with OneDrive, renaming to preserve existing file and prevent local data loss: " ~ to!string(path) ~ " -> " ~ to!string(newPath));

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
		try {
			rename(path, newPath);
			renamedPath = to!string(newPath);
        } catch (Exception e) {
            // Handle exceptions, e.g., log error
            addLogEntry("Renaming of local file failed for " ~ to!string(path) ~ ": " ~ e.msg, ["error"]);
        }
    } else {
        addLogEntry("DRY-RUN: Skipping renaming local file to preserve existing file and prevent data loss: " ~ to!string(path) ~ " -> " ~ to!string(newPath), ["debug"]);
    }
}

// Rename the given item, and only performs the function if not in a --dry-run scenario
void safeRename(const(char)[] oldPath, const(char)[] newPath, bool dryRun) {
	// Perform the rename
	if (!dryRun) {
		addLogEntry("Calling rename(oldPath, newPath)", ["debug"]);
		// Use rename() as Linux is POSIX compliant, we have an atomic operation where at no point in time the 'to' is missing.
		rename(oldPath, newPath);
	} else {
		addLogEntry("DRY-RUN: Skipping local file rename", ["debug"]);
	}
}

// Deletes the specified file without throwing an exception if it does not exists
void safeRemove(const(char)[] path) {
	if (exists(path)) remove(path);
}

// Returns the SHA1 hash hex string of a file
string computeSha1Hash(string path) {
	SHA1 sha;
	auto file = File(path, "rb");
	scope(exit) file.close(); // Ensure file is closed post read
	foreach (ubyte[] data; chunks(file, 4096)) {
		sha.put(data);
	}
	
	// Store the hash in a local variable before converting to string
	auto hashResult = sha.finish();
	return toHexString(hashResult).idup; // Convert the hash to a hex string
}

// Returns the quickXorHash base64 string of a file
string computeQuickXorHash(string path) {
	QuickXor qxor;
	auto file = File(path, "rb");
	scope(exit) file.close(); // Ensure file is closed post read
	foreach (ubyte[] data; chunks(file, 4096)) {
		qxor.put(data);
	}
	
	// Store the hash in a local variable before converting to string
	auto hashResult = qxor.finish();
	return Base64.encode(hashResult).idup; // Convert the hash to a base64 string
}

// Returns the SHA256 hex string of a file
string computeSHA256Hash(string path) {
	SHA256 sha256;
    auto file = File(path, "rb");
	scope(exit) file.close(); // Ensure file is closed post read
    foreach (ubyte[] data; chunks(file, 4096)) {
        sha256.put(data);
    }
	
	// Store the hash in a local variable before converting to string
	auto hashResult = sha256.finish();
	return toHexString(hashResult).idup; // Convert the hash to a hex string
}

// Converts wildcards (*, ?) to regex
// The changes here need to be 100% regression tested before full release
Regex!char wild2regex(const(char)[] pattern) {
    string str;
    str.reserve(pattern.length + 2);
    str ~= "^";
    foreach (c; pattern) {
        switch (c) {
        case '*':
            str ~= ".*";  // Changed to match any character. Was:      str ~= "[^/]*";
            break;
        case '.':
            str ~= "\\.";
            break;
        case '?':
            str ~= ".";  // Changed to match any single character. Was:    str ~= "[^/]";
            break;
        case '|':
            str ~= "$|^";
            break;
        case '+':
            str ~= "\\+";
            break;
        case ' ':
            str ~= "\\s";  // Changed to match exactly one whitespace. Was:   str ~= "\\s+";
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

// Test Internet access to Microsoft OneDrive using a simple HTTP HEAD request
bool testInternetReachability(ApplicationConfig appConfig) {
    auto http = HTTP();
    http.url = "https://login.microsoftonline.com";
    
    // Configure timeouts based on application configuration
    http.dnsTimeout = dur!"seconds"(appConfig.getValueLong("dns_timeout"));
    http.connectTimeout = dur!"seconds"(appConfig.getValueLong("connect_timeout"));
    http.dataTimeout = dur!"seconds"(appConfig.getValueLong("data_timeout"));
    http.operationTimeout = dur!"seconds"(appConfig.getValueLong("operation_timeout"));

    // Set IP protocol version
    http.handle.set(CurlOption.ipresolve, appConfig.getValueLong("ip_protocol_version"));

    // Set HTTP method to HEAD for minimal data transfer
    http.method = HTTP.Method.head;

    // Execute the request and handle exceptions
    try {
        addLogEntry("Attempting to contact Microsoft OneDrive Login Service");
        http.perform();

        // Check response for HTTP status code
        if (http.statusLine.code >= 200 && http.statusLine.code < 400) {
            addLogEntry("Successfully reached Microsoft OneDrive Login Service");
        } else {
            addLogEntry("Failed to reach Microsoft OneDrive Login Service. HTTP status code: " ~ to!string(http.statusLine.code));
            throw new Exception("HTTP Request Failed with Status Code: " ~ to!string(http.statusLine.code));
        }

        http.shutdown();
        return true;
    } catch (SocketException e) {
        addLogEntry("Cannot connect to Microsoft OneDrive Service - Socket Issue: " ~ e.msg);
        displayOneDriveErrorMessage(e.msg, getFunctionName!({}));
        http.shutdown();
        return false;
    } catch (CurlException e) {
        addLogEntry("Cannot connect to Microsoft OneDrive Service - Network Connection Issue: " ~ e.msg);
        displayOneDriveErrorMessage(e.msg, getFunctionName!({}));
        http.shutdown();
        return false;
    } catch (Exception e) {
        addLogEntry("Unexpected error occurred: " ~ e.toString());
        displayOneDriveErrorMessage(e.toString(), getFunctionName!({}));
        http.shutdown();
        return false;
    }
}

// Retry Internet access test to Microsoft OneDrive
bool retryInternetConnectivtyTest(ApplicationConfig appConfig) {
    int retryAttempts = 0;
    int backoffInterval = 1; // initial backoff interval in seconds
    int maxBackoffInterval = 3600; // maximum backoff interval in seconds
    int maxRetryCount = 100; // max retry attempts, reduced for practicality
    bool isOnline = false;

    while (retryAttempts < maxRetryCount && !isOnline) {
        if (backoffInterval < maxBackoffInterval) {
            backoffInterval = min(backoffInterval * 2, maxBackoffInterval); // exponential increase
        }

        addLogEntry("  Retry Attempt:      " ~ to!string(retryAttempts + 1), ["debug"]);
        addLogEntry("  Retry In (seconds): " ~ to!string(backoffInterval), ["debug"]);

        Thread.sleep(dur!"seconds"(backoffInterval));
        isOnline = testInternetReachability(appConfig); // assuming this function is defined elsewhere

        if (isOnline) {
            addLogEntry("Internet connectivity to Microsoft OneDrive service has been restored");
        }

        retryAttempts++;
    }

    if (!isOnline) {
        addLogEntry("ERROR: Was unable to reconnect to the Microsoft OneDrive service after " ~ to!string(maxRetryCount) ~ " attempts!");
    }
	
	// Return state
    return isOnline;
}

// Can we read the local file - as a permissions issue or file corruption will cause a failure
// https://github.com/abraunegg/onedrive/issues/113
// returns true if file can be accessed
bool readLocalFile(string path) {
    // What is the file size
	if (getSize(path) != 0) {
		try {
			// Attempt to read up to the first 1 byte of the file
			auto data = read(path, 1);

			// Check if the read operation was successful
			if (data.length != 1) {
				// Read operation not sucessful
				addLogEntry("Failed to read the required amount from the file: " ~ path);
				return false;
			}
		} catch (std.file.FileException e) {
			// Unable to read the file, log the error message
			displayFileSystemErrorMessage(e.msg, getFunctionName!({}));
			return false;
		}
		return true;
	} else {
		// zero byte files cannot be read, return true
		return true;
	}
}

// Calls globMatch for each string in pattern separated by '|'
bool multiGlobMatch(const(char)[] path, const(char)[] pattern) {
    if (path.length == 0 || pattern.length == 0) {
        return false;
    }

    if (!pattern.canFind('|')) {
        return globMatch!(std.path.CaseSensitive.yes)(path, pattern);
    }

    foreach (glob; pattern.split('|')) {
        if (globMatch!(std.path.CaseSensitive.yes)(path, glob)) {
            return true;
        }
    }
    return false;
}

// Does the path pass the Microsoft restriction and limitations about naming files and folders
bool isValidName(string path) {
	// Restriction and limitations about windows naming files and folders
	// https://msdn.microsoft.com/en-us/library/aa365247
	// https://support.microsoft.com/en-us/help/3125202/restrictions-and-limitations-when-you-sync-files-and-folders
	
    if (path == ".") {
        return true;
    }

    string itemName = baseName(path).toLower(); // Ensure case-insensitivity

    // Check for explicitly disallowed names
	// https://support.microsoft.com/en-us/office/restrictions-and-limitations-in-onedrive-and-sharepoint-64883a5d-228e-48f5-b3d2-eb39e07630fa?ui=en-us&rs=en-us&ad=us#invalidfilefoldernames
	string[] disallowedNames = [
        ".lock", "desktop.ini", "CON", "PRN", "AUX", "NUL",
        "COM0", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT0", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"
    ];

    // Creating an associative array for faster lookup
    bool[string] disallowedSet;
    foreach (name; disallowedNames) {
        disallowedSet[name.toLower()] = true; // Normalise to lowercase
    }

    if (disallowedSet.get(itemName, false) || itemName.startsWith("~$") || canFind(itemName, "_vti_")) {
        return false;
    }

	// Regular expression for invalid patterns
	// https://support.microsoft.com/en-us/office/restrictions-and-limitations-in-onedrive-and-sharepoint-64883a5d-228e-48f5-b3d2-eb39e07630fa?ui=en-us&rs=en-us&ad=us#invalidcharacters
	// Leading whitespace and trailing whitespace
	// Invalid characters
	// Trailing dot '.' (not documented above) , however see issue https://github.com/abraunegg/onedrive/issues/2678
	
	//auto invalidNameReg = ctRegex!(`^\s.*|^.*[\s\.]$|.*[<>:"\|\?*/\\].*`); - original to remove at some point
	auto invalidNameReg = ctRegex!(`^\s+|\s$|\.$|[<>:"\|\?*/\\]`); // revised 25/3/2024
	// - ^\s+ matches one or more whitespace characters at the start of the string. The + ensures we match one or more whitespaces, making it more efficient than .* for detecting leading whitespaces.
	// - \s$ matches a whitespace character at the end of the string. This is more precise than [\s\.]$ because we'll handle the dot separately.
	// -  \.$ specifically matches a dot character at the end of the string, addressing the requirement to catch trailing dots as invalid.
	// - [<>:"\|\?*/\\] matches any single instance of the specified invalid characters: ", *, :, <, >, ?, /, \, |

	auto matchResult = match(itemName, invalidNameReg);
    if (!matchResult.empty) {
        return false;
    }

    // Determine if the path is at the root level, if yes, check that 'forms' is not the first folder
	auto segments = pathSplitter(path).array;
    if (segments.length <= 2 && segments.back.toLower() == "forms") { // Check only the last segment, convert to lower as OneDrive is not POSIX compliant, easier to compare
        return false;
    }

    return true;
}

// Does the path contain any bad whitespace characters
bool containsBadWhiteSpace(string path) {
    // Check for null or empty string
    if (path.length == 0) {
        return false;
    }

    // Check for root item
    if (path == ".") {
        return false;
    }
	
	// https://github.com/abraunegg/onedrive/issues/35
	// Issue #35 presented an interesting issue where the filename contained a newline item
	//		'State-of-the-art, challenges, and open issues in the integration of Internet of'$'\n''Things and Cloud Computing.pdf'
	// When the check to see if this file was present the GET request queries as follows:
	//		/v1.0/me/drive/root:/.%2FState-of-the-art%2C%20challenges%2C%20and%20open%20issues%20in%20the%20integration%20of%20Internet%20of%0AThings%20and%20Cloud%20Computing.pdf
	// The '$'\n'' is translated to %0A which causes the OneDrive query to fail
	// Check for the presence of '%0A' via regex

    string itemName = encodeComponent(baseName(path));
    // Check for encoded newline character
    return itemName.indexOf("%0A") != -1;
}

// Does the path contain any ASCII HTML Codes
bool containsASCIIHTMLCodes(string path) {
	// Check for null or empty string
    if (path.length == 0) {
        return false;
    }

    // Check for root item
    if (path == ".") {
        return false;
    }

	// https://github.com/abraunegg/onedrive/issues/151
	// If a filename contains ASCII HTML codes, it generates an error when attempting to upload this to Microsoft OneDrive
	// Check if the filename contains an ASCII HTML code sequence

	// Check for the pattern &# followed by 1 to 4 digits and a semicolon
	auto invalidASCIICode = ctRegex!(`&#[0-9]{1,4};`);

	// Use match to search for ASCII HTML codes in the path
	auto matchResult = match(path, invalidASCIICode);

	// Return true if ASCII HTML codes are found
	return !matchResult.empty;
}

// Does the path contain any ASCII Control Codes
bool containsASCIIControlCodes(string path) {
    // Check for null or empty string
    if (path.length == 0) {
        return false;
    }

    // Check for root item
    if (path == ".") {
        return false;
    }

    // https://github.com/abraunegg/onedrive/discussions/2553#discussioncomment-7995254
	//  Define a ctRegex pattern for ASCII control codes and specific non-ASCII control characters
    //  This pattern includes the ASCII control range and common non-ASCII control characters
    //  Adjust the pattern as needed to include specific characters of concern
	auto controlCodePattern = ctRegex!(`[\x00-\x1F\x7F]|\p{Cc}`); // Blocks ƒ†¯~‰ (#2553) , allows α (#2598)

    // Use match to search for ASCII control codes in the path
    auto matchResult = match(path, controlCodePattern);

    // Return true if matchResult is not empty (indicating a control code was found)
    return !matchResult.empty;
}

// Is the path a valid UTF-16 encoded path?
bool isValidUTF16(string path) {
    // Check for null or empty string
    if (path.length == 0) {
        return true;
    }

    // Check for root item
    if (path == ".") {
        return true;
    }

    auto wpath = toUTF16(path); // Convert to UTF-16 encoding
    auto it = wpath.byCodeUnit;

    while (!it.empty) {
        ushort current = it.front;
        
        // Check for valid single unit
        if (current <= 0xD7FF || (current >= 0xE000 && current <= 0xFFFF)) {
            it.popFront();
        }
        // Check for valid surrogate pair
        else if (current >= 0xD800 && current <= 0xDBFF) {
            it.popFront();
            if (it.empty || it.front < 0xDC00 || it.front > 0xDFFF) {
                return false; // Invalid surrogate pair
            }
            it.popFront();
        } else {
            return false; // Invalid code unit
        }
    }

    return true;
}

// Does the path contain any HTML URL encoded items (e.g., '%20' for space)
bool containsURLEncodedItems(string path) {
    // Check for null or empty string
    if (path.length == 0) {
        return false;
    }

    // Pattern for percent encoding: % followed by two hexadecimal digits
    auto urlEncodedPattern = ctRegex!(`%[0-9a-fA-F]{2}`);

    // Search for URL encoded items in the string
    auto matchResult = match(path, urlEncodedPattern);

    // Return true if URL encoded items are found
    return !matchResult.empty;
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
		// Is there an error description?
		if ("error_description" in errorMessage) {
			// error_description to process
			addLogEntry();
			string[] errorReason = splitLines(errorMessage["error_description"].str);
			addLogEntry(to!string(errorReason[0]), ["info", "notify"]);
		}
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
	
	// Must force exit here, allow logging to be done
	Thread.sleep(dur!("msecs")(500));
	exit(EXIT_FAILURE);
}

// Parse and display error message received from the local file system
void displayFileSystemErrorMessage(string message, string callingFunction) {
    addLogEntry(); // used rather than writeln
    addLogEntry("ERROR: The local file system returned an error with the following message:");

    auto errorArray = splitLines(message);
    // Safely get the error message
    string errorMessage = errorArray.length > 0 ? to!string(errorArray[0]) : "No error message available";
    addLogEntry("  Error Message:    " ~ errorMessage);
    
    // Log the calling function
    addLogEntry("  Calling Function: " ~ callingFunction);

    try {
        // Safely check for disk space
        ulong localActualFreeSpace = to!ulong(getAvailableDiskSpace("."));
        if (localActualFreeSpace == 0) {
            // Must force exit here, allow logging to be done
			Thread.sleep(dur!("msecs")(500));
            exit(EXIT_FAILURE);
        }
    } catch (Exception e) {
        // Handle exceptions from disk space check or type conversion
        addLogEntry("  Exception in disk space check: " ~ e.msg);
    }
}

// Display the POSIX Error Message
void displayPosixErrorMessage(string message) {
	addLogEntry(); // used rather than writeln
	addLogEntry("ERROR: Microsoft OneDrive API returned data that highlights a POSIX compliance issue:");
	addLogEntry("  Error Message:    " ~ message);
}

// Display the Error Message
void displayGeneralErrorMessage(Exception e, string callingFunction=__FUNCTION__, int lineno=__LINE__) {
	addLogEntry(); // used rather than writeln
	addLogEntry("ERROR: Encounter " ~ e.classinfo.name ~ ":");
	addLogEntry("  Error Message:    " ~ e.msg);
	addLogEntry("  Calling Function:    " ~ callingFunction);
	addLogEntry("  Line number:    " ~ to!string(lineno));
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
	
	// Query GitHub for the 'latest' release details
	try {
        content = get("https://api.github.com/repos/abraunegg/onedrive/releases/latest");
        githubLatest = content.parseJSON();
    } catch (CurlException e) {
        addLogEntry("CurlException: Unable to query GitHub for latest release - " ~ e.msg, ["debug"]);
    } catch (JSONException e) {
        addLogEntry("JSONException: Unable to parse GitHub JSON response - " ~ e.msg, ["debug"]);
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
	
	// Query GitHub for the release details to match the running version
	try {
        content = get("https://api.github.com/repos/abraunegg/onedrive/releases");
        githubDetails = content.parseJSON();
    } catch (CurlException e) {
        addLogEntry("CurlException: Unable to query GitHub for release details - " ~ e.msg, ["debug"]);
        return parseJSON(`{"Error": "CurlException", "message": "` ~ e.msg ~ `"}`);
    } catch (JSONException e) {
        addLogEntry("JSONException: Unable to parse GitHub JSON response - " ~ e.msg, ["debug"]);
        return parseJSON(`{"Error": "JSONException", "message": "` ~ e.msg ~ `"}`);
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

// Function to determine if the final component of the provided path is a .file or .folder
bool isDotFile(const(string) path) {
    // Check for null or empty path
    if (path is null || path.length == 0) {
        return false;
    }

    // Special case for root
    if (path == ".") {
        return false;
    }

    // Extract the last component of the path
    auto paths = pathSplitter(buildNormalizedPath(path));
    
    // Optimised way to fetch the last component
    string lastComponent = paths.empty ? "" : paths.back;

    // Check if the last component starts with a dot
    return startsWith(lastComponent, ".");
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
    if (bytes == 0) {
        return "0.00"; // or handle the zero case as needed
    }

    double gib = bytes / 1073741824.0; // 1024^3 for direct conversion
    return format("%.2f", gib); // Format to ensure two decimal places
}

// Test if entrypoint.sh exists on the root filesystem
bool entrypointExists(string basePath = "/") {
    try {
        // Build the path to the entrypoint.sh file
        string entrypointPath = buildNormalizedPath(buildPath(basePath, "entrypoint.sh"));

        // Check if the path exists and return the result
        return exists(entrypointPath);
    } catch (Exception e) {
        // Handle any exceptions (e.g., permission issues, invalid path)
        writeln("An error occurred: ", e.msg);
        return false;
    }
}

// Generate a random alphanumeric string with specified length
string generateAlphanumericString(size_t length = 16) {
    // Ensure length is not zero
    if (length == 0) {
        throw new Exception("Length must be greater than 0");
    }

    auto asciiLetters = to!(dchar[])(letters);
    auto asciiDigits = to!(dchar[])(digits);
    dchar[] randomString;
    randomString.length = length;

    // Create a random number generator
    auto rndGen = Random(unpredictableSeed);

    // Fill the string with random alphanumeric characters
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

// Return the username of the UID running the 'onedrive' process
string getUserName() {
    // Retrieve the UID of the current user
    auto uid = getuid();

    // Retrieve password file entry for the user
    auto pw = getpwuid(uid);
    enforce(pw !is null, "Failed to retrieve user information for UID: " ~ to!string(uid));

    // Extract username and convert to immutable string
    string userName = to!string(fromStringz(pw.pw_name));

    // Log User identifiers from process
    addLogEntry("Process ID: " ~ to!string(pw), ["debug"]);
    addLogEntry("User UID:   " ~ to!string(pw.pw_uid), ["debug"]);
    addLogEntry("User GID:   " ~ to!string(pw.pw_gid), ["debug"]);

    // Check if username is valid
    if (!userName.empty) {
        addLogEntry("User Name:  " ~ userName, ["debug"]);
        return userName;
    } else {
        // Log and return unknown user
        addLogEntry("User Name:  unknown", ["debug"]);
        return "unknown";
    }
}

// Calculate the ETA for when a 'large file' will be completed (upload & download operations)
int calc_eta(size_t counter, size_t iterations, ulong start_time) {
    if (counter == 0) {
        return 0; // Avoid division by zero
    }

    double ratio = cast(double) counter / iterations;
    auto current_time = Clock.currTime.toUnixTime();
    ulong duration = (current_time - start_time);

    // Segments left to download
    auto segments_remaining = (iterations > counter) ? (iterations - counter) : 0;
    
    // Calculate the average time per iteration so far
    double avg_time_per_iteration = cast(double) duration / counter;

    // Debug output for the ETA calculation
    addLogEntry("counter: " ~ to!string(counter), ["debug"]);
	addLogEntry("iterations: " ~ to!string(iterations), ["debug"]);
	addLogEntry("segments_remaining: " ~ to!string(segments_remaining), ["debug"]);
	addLogEntry("ratio: " ~ format("%.2f", ratio), ["debug"]);
	addLogEntry("start_time:   " ~ to!string(start_time), ["debug"]);
	addLogEntry("current_time: " ~ to!string(current_time), ["debug"]);
	addLogEntry("duration: " ~ to!string(duration), ["debug"]);
	addLogEntry("avg_time_per_iteration: " ~ format("%.2f", avg_time_per_iteration), ["debug"]);
	
	// Return the ETA or duration
    if (counter != iterations) {
        auto eta_sec = avg_time_per_iteration * segments_remaining;
		// ETA Debug
		addLogEntry("eta_sec: " ~ to!string(eta_sec), ["debug"]);
		addLogEntry("estimated_total_time: " ~ to!string(avg_time_per_iteration * iterations), ["debug"]);
		// Return ETA
        return eta_sec > 0 ? cast(int) ceil(eta_sec) : 0;
    } else {
		// Return the average time per iteration for the last iteration
        return cast(int) ceil(avg_time_per_iteration); 
    }
}

void forceExit() {
	// Allow logging to flush and complete
	Thread.sleep(dur!("msecs")(500));
	// Force Exit
	exit(EXIT_FAILURE);
}