// What is this module called?
module util;

// What does this module require to function?
import core.stdc.stdlib: EXIT_SUCCESS, EXIT_FAILURE, exit;
import core.stdc.errno : ENOENT;
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
import core.sys.posix.signal;
import etc.c.curl;
import std.process;

// What other modules that we have created do we need to import?
import log;
import config;
import qxor;
import curlEngine;

// Global variable for the device name
__gshared string deviceName;
// Global flag for SIGINT (CTRL-C) and SIGTERM (kill) state
__gshared bool exitHandlerTriggered = false;
// util module variable
ulong previousRSS;

struct DesktopHints {
    bool gnome;
    bool kde;
}

shared static this() {
	deviceName = Socket.hostName;
}

// Creates a safe backup of the given item, and only performs the function if not in a --dry-run scenario.
// If the path already ends with "-<deviceName>-safeBackup-####", the counter is incremented
// instead of appending another "-<deviceName>-safeBackup-".
void safeBackup(const(char)[] path, bool dryRun, bool bypassDataPreservation, out string renamedPath) {
    // Is the input path a folder|directory? These should never be renamed
	if (isDir(path)) {
		if (verboseLogging) {
			addLogEntry("Renaming request of local directory is being ignored: " ~ to!string(path), ["verbose"]);
		}
		return;
	}
	
	// Ensure this is currently null
	renamedPath = null;
	
	// Has the user configured to IGNORE local data protection rules?
    if (bypassDataPreservation) {
        addLogEntry("WARNING: Local Data Protection has been disabled - not renaming local file. You may experience data loss on this file: " ~ to!string(path), ["info", "notify"]);
        return;
    }
	
	// Convert once for convenience
    const string spath = to!string(path);
    const string ext   = extension(spath);

    // Compute stem without extension (handles no-extension case too)
    const size_t stemLen = spath.length >= ext.length ? spath.length - ext.length : spath.length;
    string stem = spath[0 .. stemLen];

    // Tag used for our safe backups
    string tag = "-" ~ deviceName ~ "-safeBackup-";

    // Detect if already a tagged safeBackup on THIS device; if so, bump the 4-digit counter
    int startN = 1;
    string baseStem = stem;

    if (stem.length >= tag.length + 4) {
        // Slice out last 4 chars and the tag position
        auto last4   = stem[$ - 4 .. $];
        auto tagSpan = stem[$ - (tag.length + 4) .. $ - 4];

        bool fourDigits = true;
        foreach (c; last4) {
            if (!c.isDigit) { fourDigits = false; break; }
        }

        if (fourDigits && tagSpan == tag) {
            // Already a backup from this device — bump the counter
            startN   = to!int(last4) + 1;
            baseStem = stem[0 .. $ - (tag.length + 4)];
        }
    }

    // Find the first available name, capped at 1000 attempts
    int n = startN;
    string candidate;

    while (n <= 1000) {
        candidate = baseStem ~ tag ~ format("%04d", n) ~ ext;
        if (!exists(candidate)) break;
        ++n;
    }

    // If we exhausted our attempts, fail out
    if (n > 1000) {
        addLogEntry("Failed to backup " ~ spath ~ ": Unique file name could not be found after 1000 attempts", ["error"]);
        return;
    }

    // Log intent
    if (verboseLogging) {
        addLogEntry("The local item is out-of-sync with OneDrive, renaming to preserve existing file and prevent local data loss: " ~ spath ~ " -> " ~ candidate, ["verbose"]);
    }

    // Perform (or simulate) the rename
    if (!dryRun) {
	
		// Not a --dry-run scenario - attempt the file rename
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
            rename(spath, candidate); // POSIX atomic on same mount
            renamedPath = candidate;
        } catch (Exception e) {
            addLogEntry("Renaming of local file failed for " ~ spath ~ ": " ~ e.msg, ["error"]);
        }
    } else {
        if (debugLogging) {
            addLogEntry("DRY-RUN: Skipping renaming local file to preserve existing file and prevent data loss: " ~ spath ~ " -> " ~ candidate, ["debug"]);
        }
    }
}

// Rename the given item, and only performs the function if not in a --dry-run scenario
void safeRename(const(char)[] oldPath, const(char)[] newPath, bool dryRun) {
	// Perform the rename
	if (!dryRun) {
		if (debugLogging) {addLogEntry("Calling rename(oldPath, newPath)", ["debug"]);}
		// Use rename() as Linux is POSIX compliant, we have an atomic operation where at no point in time the 'to' is missing.
		rename(oldPath, newPath);
	} else {
		if (debugLogging) {addLogEntry("DRY-RUN: Skipping local file rename", ["debug"]);}
	}
}

// Deletes the specified file without throwing an exception if it does not exists
void safeRemove(const(char)[] path) {
	// Set this function name
	string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
	
	// Attempt the local deletion
	try {
		// Attempt once; no pre-check to avoid TOCTTOU
		remove(path);				// attempt once, no pre-check
		return;						// removed
	} catch (FileException e) {
		if (e.errno == ENOENT) {	// already gone → fine
			return;					// nothing to do
		}
		// Anything else is noteworthy (EISDIR, EACCES, etc.)
		displayFileSystemErrorMessage(e.msg, thisFunctionName);
	}
}

// Returns the SHA1 hash hex string of a file, or an empty string on failure
string computeSha1Hash(string path) {
	SHA1 sha;
	File file;
	bool fileOpened = false;
	
	scope(exit) {
		if (fileOpened) {
			file.close(); // Ensure file is closed on function exit
		}
	}

	try {
		file = File(path, "rb");
		fileOpened = true;

		// Read file in chunks and feed into the hash
		foreach (ubyte[] data; chunks(file, 4096)) {
			sha.put(data);
		}
	} catch (ErrnoException e) {
		addLogEntry("Failed to compute SHA1 Hash for file: " ~ path ~ " - " ~ e.msg);
		return "";
	} catch (Exception e) {
		addLogEntry("Unexpected error while computing SHA1 Hash for file: " ~ path ~ " - " ~ e.msg);
		return "";
	}

	// Ensure file is closed if opened
	if (fileOpened) {
		try {
			file.close();
		} catch (Exception e) {
			addLogEntry("Failed to close file after hashing: " ~ path ~ " - " ~ e.msg);
		}
	}

	// Finish hashing and return hex result
	auto hashResult = sha.finish();
	return toHexString(hashResult).idup;
}

// Returns the quickXorHash base64 string of a file, or an empty string on failure
string computeQuickXorHash(string path) {
	QuickXor qxor;
	File file;
	bool fileOpened = false;
	
	scope(exit) {
		if (fileOpened) {
			file.close(); // Ensure file is closed on function exit
		}
	}

	try {
		file = File(path, "rb");
		fileOpened = true;

		// Read file in chunks and feed into the hash
		foreach (ubyte[] data; chunks(file, 4096)) {
			qxor.put(data);
		}
	} catch (ErrnoException e) {
		addLogEntry("Failed to compute QuickXor Hash for file: " ~ path ~ " - " ~ e.msg);
		return ""; // Return empty string on failure
	} catch (Exception e) {
		addLogEntry("Unexpected error while computing QuickXor Hash for file: " ~ path ~ " - " ~ e.msg);
		return ""; // Return empty string on unexpected error
	}

	// Ensure file is closed if opened
	if (fileOpened) {
		try {
			file.close();
		} catch (Exception e) {
			addLogEntry("Failed to close file after hashing: " ~ path ~ " - " ~ e.msg);
		}
	}

	// Finish hashing and return base64 result
	auto hashResult = qxor.finish();
	return Base64.encode(hashResult).idup;
}

// Returns the SHA256 hash hex string of a file, or an empty string on failure
string computeSHA256Hash(string path) {
	SHA256 sha256;
	File file;
	bool fileOpened = false;
	
	scope(exit) {
		if (fileOpened) {
			file.close(); // Ensure file is closed on function exit
		}
	}

	try {
		file = File(path, "rb");
		fileOpened = true;

		// Read file in chunks and feed into the hash
		foreach (ubyte[] data; chunks(file, 4096)) {
			sha256.put(data);
		}
	} catch (ErrnoException e) {
		addLogEntry("Failed to compute SHA256 Hash for file: " ~ path ~ " - " ~ e.msg);
		return "";
	} catch (Exception e) {
		addLogEntry("Unexpected error while computing SHA256 Hash for file: " ~ path ~ " - " ~ e.msg);
		return "";
	}

	// Ensure file is closed if opened
	if (fileOpened) {
		try {
			file.close();
		} catch (Exception e) {
			addLogEntry("Failed to close file after hashing: " ~ path ~ " - " ~ e.msg);
		}
	}

	// Finish hashing and return hex result
	auto hashResult = sha256.finish();
	return toHexString(hashResult).idup;
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
bool testInternetReachability(ApplicationConfig appConfig, bool displayLogging = true) {
	HTTP http = HTTP();
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
	
	bool reachedService = false;
	
	// Exit scope to ensure cleanup
	scope(exit) {
		// Shut http down and destroy
		http.shutdown();
		object.destroy(http);
		// Perform Garbage Collection
		GC.collect();
		// Return free memory to the OS
		GC.minimize();
	}

	// Execute the request and handle exceptions
	try {
		if (displayLogging) {
			addLogEntry("Attempting to contact the Microsoft OneDrive Service");
		}
		http.perform();

		// Check response for HTTP status code
		if (http.statusLine.code >= 200 && http.statusLine.code < 400) {
			if (displayLogging) {
				addLogEntry("Successfully reached the Microsoft OneDrive Service");
			}
			reachedService = true;
		} else {
			addLogEntry("Failed to reach the Microsoft OneDrive Service. HTTP status code: " ~ to!string(http.statusLine.code));
			reachedService = false;
		}
	} catch (SocketException e) {
		addLogEntry("Cannot connect to the Microsoft OneDrive Service - Socket Issue: " ~ e.msg);
		displayOneDriveErrorMessage(e.msg, getFunctionName!({}));
		reachedService = false;
	} catch (CurlException e) {
		addLogEntry("Cannot connect to the Microsoft OneDrive Service - Network Connection Issue: " ~ e.msg);
		displayOneDriveErrorMessage(e.msg, getFunctionName!({}));
		reachedService = false;
	} catch (Exception e) {
		addLogEntry("An unexpected error occurred: " ~ e.toString());
		displayOneDriveErrorMessage(e.toString(), getFunctionName!({}));
		reachedService = false;
	}
	
	// Ensure everything is shutdown cleanly
	http.shutdown();
	object.destroy(http);
	// Perform Garbage Collection
	GC.collect();
	// Return free memory to the OS
	GC.minimize();
	
	// Return state
	return reachedService;
}

// Retry Internet access test to Microsoft OneDrive
bool retryInternetConnectivityTest(ApplicationConfig appConfig) {
    int retryAttempts = 0;
    int backoffInterval = 1; // initial backoff interval in seconds
    int maxBackoffInterval = 3600; // maximum backoff interval in seconds
    int maxRetryCount = 100; // max retry attempts, reduced for practicality
    bool isOnline = false;

    while (retryAttempts < maxRetryCount && !isOnline) {
        if (backoffInterval < maxBackoffInterval) {
            backoffInterval = min(backoffInterval * 2, maxBackoffInterval); // exponential increase
        }

        if (debugLogging) {
			addLogEntry("  Retry Attempt:      " ~ to!string(retryAttempts + 1), ["debug"]);
			addLogEntry("  Retry In (seconds): " ~ to!string(backoffInterval), ["debug"]);
		}

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
				// Read operation not successful
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

// Is the string a valid UTF-8 timestamp string?
bool isValidUTF8Timestamp(string input) {
	try {
		// Validate the entire string for UTF-8 correctness
		validate(input); // Throws UTFException if invalid UTF-8 is found

		// Validate the input against UTF-8 test cases
		if (!isValidUTF8(input)) {
			// error message already printed
			return false;
		}
		
		// Additional edge-case handling because the input format is known and controlled:
		// Ensure input length is within the expected range for a UTC datetime
		if (input.length < 20 || input.length > 30) {
			// not the correct length
			addLogEntry("UTF-8 validation failed: Input '" ~ input ~ "' is not within the expected length range for UTC datetime strings (20-30 characters).");
			return false;
		}

		return true;
	} catch (UTFException) {
		addLogEntry("UTF-8 validation failed: Input '" ~ input ~ "' contains invalid UTF-8 characters.");
		return false;
	}
}

// Is the string a valid UTF-8 string?
bool isValidUTF8(string input) {
	try {
		// Validate the entire string for UTF-8 correctness
		validate(input); // Throws UTFException if invalid UTF-8 is found

		// Iterate through each character using byUTF to ensure proper UTF-8 decoding
		auto it = input.byUTF!(char);
		foreach (_; it) {
			// Iterating over the range ensures every UTF-8 sequence in the string is decoded into valid `dchar`s.
			// Throws a UTFException if an invalid UTF-8 sequence is encountered during decoding.
		}

		// Check for replacement characters
		if (input.count!((dchar c) => c == '\uFFFD') > 0) {
			// contains replacement character
			addLogEntry("UTF-8 validation failed: Input contains replacement characters (�).");
			return false;
		}

		// is the string empty?
		if (input.empty) {
			// input is empty
			addLogEntry("UTF-8 validation failed: Input is empty.");
			return false;
		}
	
		// return true
		return true;
	} catch (UTFException) {
		addLogEntry("UTF-8 validation failed: Input '" ~ input ~ "' contains invalid UTF-8 characters.");
		return false;
	}
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

// Validate that the provided string is a valid date time stamp in UTC format
bool isValidUTCDateTime(string dateTimeString) {
    // Regular expression for validating the string against UTC datetime format
	// Allows for an optional fractional second part (e.g., .123 or .123456789)
	auto pattern = regex(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$");
		
	// Validate for UTF-8 first
	if (!isValidUTF8Timestamp(dateTimeString)) {
		if (dateTimeString.empty) {
			// empty string
			addLogEntry("BAD TIMESTAMP (UTF-8 FAIL): empty string");
		} else {
			// log string that caused UTF-8 failure
			addLogEntry("BAD TIMESTAMP (UTF-8 FAIL): " ~ dateTimeString);
		}
		return false;
	}
	
	// First, check if the string matches the pattern
	if (!match(dateTimeString, pattern)) {
		addLogEntry("BAD TIMESTAMP (REGEX FAIL): " ~ dateTimeString);
		return false;
	}

	// Attempt to parse the string into a DateTime object
	try {
		auto dt = SysTime.fromISOExtString(dateTimeString);
		return true;
	} catch (TimeException) {
		addLogEntry("BAD TIMESTAMP (CONVERSION FAIL): " ~ dateTimeString);
		return false;
	}
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
	addLogEntry("  Error Message:       " ~ to!string(errorArray[0]));
	// Extract 'message' as the reason
	JSONValue errorMessage = parseJSON(replace(message, errorArray[0], ""));
	
	// What is the reason for the error
	if (errorMessage.type() == JSONType.object) {
		// configure the error reason
		string errorReason;
		string errorCode;
		string requestDate;
		string requestId;
		string localizedMessage;
		
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
		
		// Microsoft has started adding 'localizedMessage' to error JSON responses. If this is available, use this
		try {
			// Use ["error"]["localizedMessage"] as localised reason
			localizedMessage = errorMessage["error"]["localizedMessage"].str;	
		} catch (JSONException e) {
			// we dont want to do anything here if not available
		}
		
		// Display the error reason
		if (errorReason.startsWith("<!DOCTYPE")) {
			// a HTML Error Reason was given
			addLogEntry("  Error Reason:        A HTML Error response was provided. Use debug logging (--verbose --verbose) to view this error");
			if (debugLogging) {addLogEntry(errorReason, ["debug"]);}
			
		} else {
			// a non HTML Error Reason was given
			addLogEntry("  Error Reason:        " ~ errorReason);
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
		
		// Display the localizedMessage, error code, date and request id if available
		if (localizedMessage != "")   addLogEntry("  Error Reason (L10N): " ~ localizedMessage);
		if (errorCode != "")   addLogEntry("  Error Code:          " ~ errorCode);
		if (requestDate != "") addLogEntry("  Error Timestamp:     " ~ requestDate);
		if (requestId != "")   addLogEntry("  API Request ID:      " ~ requestId);		   
	}
	
	// Where in the code was this error generated
	if (verboseLogging) {addLogEntry("  Calling Function:    " ~ callingFunction, ["verbose"]);} // will get printed in debug
	
	// Extra Debug if we are using --verbose --verbose
	if (debugLogging) {
		addLogEntry("Raw Error Data: " ~ message, ["debug"]);
		addLogEntry("JSON Message: " ~ to!string(errorMessage), ["debug"]);
	}
	
	// Close out logging with an empty line, so that in console output, and logging output this becomes clear
	addLogEntry();
}

// Common code for handling when a client is unauthorised
void handleClientUnauthorised(int httpStatusCode, JSONValue errorMessage) {
	// What httpStatusCode was received
	if (httpStatusCode == 400) {
		// bad request or a new auth token is needed
		// configure the error reason
		// Is there an error description?
		if ("error_description" in errorMessage) {
			// error_description to process
			addLogEntry();
			string[] errorReason = splitLines(errorMessage["error_description"].str);
			addLogEntry(to!string(errorReason[0]), ["info", "notify"]);
			addLogEntry();
			addLogEntry("ERROR: You will need to issue a --reauth and re-authorise this client to obtain a fresh auth token.", ["info", "notify"]);
			addLogEntry();
		} else {
			if ("code" in errorMessage["error"]) {
				if (errorMessage["error"]["code"].str == "invalidRequest") {
					addLogEntry();
					addLogEntry("ERROR: Check your configuration as your existing refresh_token generated an invalid request. You may need to issue a --reauth and re-authorise this client.", ["info", "notify"]);
					addLogEntry();
				}
			} else {
				// no error_description
				addLogEntry();
				addLogEntry("ERROR: Check your configuration as it may be invalid. You will need to issue a --reauth and re-authorise this client to obtain a fresh auth token.", ["info", "notify"]);
				addLogEntry();
			}
		}
	} else {
		// 401 error code
		addLogEntry();
		addLogEntry("ERROR: Check your configuration as your refresh_token may be empty or invalid. You may need to issue a --reauth and re-authorise this client.", ["info", "notify"]);
		addLogEntry();
	}
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
			forceExit();
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
	addLogEntry("ERROR: Encountered a " ~ e.classinfo.name ~ ":");
	addLogEntry("  Error Message:    " ~ e.msg);
	addLogEntry("  Calling Function: " ~ callingFunction);
	addLogEntry("  Line number:      " ~ to!string(lineno));
}

// Get the function name that is being called to assist with identifying where an error is being generated
string getFunctionName(alias func)() {
    return __traits(identifier, __traits(parent, func)) ~ "()\n";
}

JSONValue fetchOnlineURLContent(string url) {
	// Function variables
	char[] content;
	JSONValue onlineContent;

	// Setup HTTP request
	HTTP http = HTTP();
	
	// Exit scope to ensure cleanup
	scope(exit) {
		// Shut http down and destroy
		http.shutdown();
		object.destroy(http);
		// Perform Garbage Collection
		GC.collect();
		// Return free memory to the OS
		GC.minimize();
	}
	
	// Configure the URL to access
	http.url = url;
	// HTTP the connection method
	http.method = HTTP.Method.get;
	// Data receive handler
	http.onReceive = (ubyte[] data) {
		content ~= data; // Append data as it's received
		return data.length;
	};
	
	// Perform HTTP request
	http.perform();
	// Parse Content
	onlineContent = parseJSON(to!string(content));
	// Return onlineResponse
    return onlineContent;
}

// Get the latest release version from GitHub
JSONValue getLatestReleaseDetails() {
	JSONValue githubLatest;
	JSONValue versionDetails;
	string latestTag;
	string publishedDate;
	
	// Query GitHub for the 'latest' release details
	try {	
		githubLatest = fetchOnlineURLContent("https://api.github.com/repos/abraunegg/onedrive/releases/latest");
    } catch (CurlException e) {
        if (debugLogging) {addLogEntry("CurlException: Unable to query GitHub for latest release - " ~ e.msg, ["debug"]);}
    } catch (JSONException e) {
        if (debugLogging) {addLogEntry("JSONException: Unable to parse GitHub JSON response - " ~ e.msg, ["debug"]);}
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
			if (debugLogging) {addLogEntry("'tag_name' unavailable in JSON response. Setting GitHub 'tag_name' release version to 0.0.0", ["debug"]);}
			latestTag = "0.0.0";
		}
		// use the returned published_at date
		if ("published_at" in githubLatest) {
			// use the provided value
			publishedDate = githubLatest["published_at"].str;
		} else {
			// set to v2.0.0 release date
			if (debugLogging) {addLogEntry("'published_at' unavailable in JSON response. Setting GitHub 'published_at' date to 2018-07-18T18:00:00Z", ["debug"]);}
			publishedDate = "2018-07-18T18:00:00Z";
		}
	} else {
		// JSONValue is not an object
		if (debugLogging) {addLogEntry("Invalid JSON Object response from GitHub. Setting GitHub 'tag_name' release version to 0.0.0", ["debug"]);}
		latestTag = "0.0.0";
		if (debugLogging) {addLogEntry("Invalid JSON Object. Setting GitHub 'published_at' date to 2018-07-18T18:00:00Z", ["debug"]);}
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
	JSONValue githubDetails;
	JSONValue versionDetails;
	string versionTag = "v" ~ thisVersion;
	string publishedDate;
	
	// Query GitHub for the release details to match the running version
	try {
		githubDetails = fetchOnlineURLContent("https://api.github.com/repos/abraunegg/onedrive/releases");
	} catch (CurlException e) {
        if (debugLogging) {addLogEntry("CurlException: Unable to query GitHub for release details - " ~ e.msg, ["debug"]);}
        return parseJSON(`{"Error": "CurlException", "message": "` ~ e.msg ~ `"}`);
    } catch (JSONException e) {
        if (debugLogging) {addLogEntry("JSONException: Unable to parse GitHub JSON response - " ~ e.msg, ["debug"]);}
        return parseJSON(`{"Error": "JSONException", "message": "` ~ e.msg ~ `"}`);
    }
	
	// githubDetails has to be a valid JSON array
	if (githubDetails.type() == JSONType.array){
		foreach (searchResult; githubDetails.array) {
			// searchResult["tag_name"].str;
			if (searchResult["tag_name"].str == versionTag) {
				if (debugLogging) {
					addLogEntry("MATCHED version", ["debug"]);
					addLogEntry("tag_name: " ~ searchResult["tag_name"].str, ["debug"]);
					addLogEntry("published_at: " ~ searchResult["published_at"].str, ["debug"]);
				}
				publishedDate = searchResult["published_at"].str;
			}
		}
		
		if (publishedDate.empty) {
			// empty .. no version match ?
			// set to v2.0.0 release date
			if (debugLogging) {addLogEntry("'published_at' unavailable in JSON response. Setting GitHub 'published_at' date to 2018-07-18T18:00:00Z", ["debug"]);}
			publishedDate = "2018-07-18T18:00:00Z";
		}
	} else {
		// JSONValue is not an Array
		if (debugLogging) {addLogEntry("Invalid JSON Array. Setting GitHub 'published_at' date to 2018-07-18T18:00:00Z", ["debug"]);}
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
	if (debugLogging) {
		addLogEntry("applicationVersion:       " ~ applicationVersion, ["debug"]);
		addLogEntry("latestVersion:            " ~ latestVersion, ["debug"]);
		addLogEntry("publishedDate:            " ~ to!string(publishedDate), ["debug"]);
		addLogEntry("currentTime:              " ~ to!string(currentTime), ["debug"]);
		addLogEntry("releaseGracePeriod:       " ~ to!string(releaseGracePeriod), ["debug"]);
	}
	
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
			if (debugLogging) {addLogEntry("thisVersionPublishedDate: " ~ to!string(thisVersionPublishedDate), ["debug"]);}
			
			// the running version grace period is its release date + 1 month
			SysTime thisVersionReleaseGracePeriod = thisVersionPublishedDate;
			thisVersionReleaseGracePeriod = thisVersionReleaseGracePeriod.add!"months"(1);
			if (debugLogging) {addLogEntry("thisVersionReleaseGracePeriod: " ~ to!string(thisVersionReleaseGracePeriod), ["debug"]);}
			
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

bool hasMimeType(const ref JSONValue item) {
	return ("mimeType" in item["file"]) != null;
}

bool hasQuota(JSONValue item) {
	return ("quota" in item) != null;
}

bool hasQuotaState(JSONValue item) {
	return ("state" in item["quota"]) != null;
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

bool hasParentReferenceDriveId(JSONValue item) {
	return ("driveId" in item["parentReference"]) != null;
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

bool isRemoteFolderItem(const ref JSONValue item) {
	if (isItemRemote(item)) {
		return ("folder" in item["remoteItem"]) != null;
	} else {
		return false;
	}
}

bool isFileItem(const ref JSONValue item) {
	return ("file" in item) != null;
}

bool isItemRemote(const ref JSONValue item) {
	return ("remoteItem" in item) != null;
}

// Check if ["remoteItem"]["parentReference"]["driveId"] exists
bool hasRemoteParentDriveId(const ref JSONValue item) {
    return ("remoteItem" in item) &&
           ("parentReference" in item["remoteItem"]) &&
           ("driveId" in item["remoteItem"]["parentReference"]);
}

// Check if ["remoteItem"]["id"] exists
bool hasRemoteItemId(const ref JSONValue item) {
    return ("remoteItem" in item) &&
           ("id" in item["remoteItem"]);
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

bool isOneNotePackageFolder(const ref JSONValue item) {
    if ("package" in item) {
        auto pkg = item["package"];
        if ("type" in pkg && pkg["type"].type == JSONType.string) {
            return pkg["type"].str == "oneNote";
        }
    }
    return false;
}

bool hasHashes(const ref JSONValue item) {
	return ("hashes" in item["file"]) != null;
}

bool hasZeroHashes(const ref JSONValue item) {
    // Check if "hashes" exists under "file" and is empty
    if ("hashes" in item["file"]) {
        auto hashes = item["file"]["hashes"];
        if (hashes.type == JSONType.object && hashes.object.keys.length == 0) {
            return true;
        }
    }
    return false;
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

bool isMicrosoftOneNoteFileExtensionType1(const ref JSONValue item) {
    return item["name"].str.endsWith(".one");
}

bool isMicrosoftOneNoteFileExtensionType2(const ref JSONValue item) {
    return item["name"].str.endsWith(".onetoc2");
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

bool hasCreatedBy(const ref JSONValue item) {
	return ("createdBy" in item) != null;
}

bool hasCreatedByUser(const ref JSONValue item) {
	return ("user" in item["createdBy"]) != null;
}

bool hasCreatedByUserDisplayName(const ref JSONValue item) {
	if (hasCreatedBy(item)) {
		if (hasCreatedByUser(item)) {
			return ("displayName" in item["createdBy"]["user"]) != null;
		} else {
			return false;
		}
	} else {
		return false;
	}
}

bool hasLastModifiedBy(const ref JSONValue item) {
	return ("lastModifiedBy" in item) != null;
}

bool hasLastModifiedByUser(const ref JSONValue item) {
	return ("user" in item["lastModifiedBy"]) != null;
}

bool hasLastModifiedByUserDisplayName(const ref JSONValue item) {
	if (hasLastModifiedBy(item)) {
		if (hasLastModifiedByUser(item)) {
			return ("displayName" in item["lastModifiedBy"]["user"]) != null;
		} else {
			return false;
		}
	} else {
		return false;
	}
}

// Check Intune JSON response for 'accessToken'
bool hasAccessTokenData(const ref JSONValue item) {
	return ("accessToken" in item) != null;
}

// Check Intune JSON response for 'account'
bool hasAccountData(const ref JSONValue item) {
	return ("account" in item) != null;
}

// Check Intune JSON response for 'expiresOn'
bool hasExpiresOn(const ref JSONValue item) {
	return ("expiresOn" in item) != null;
}

// Resumable Download checks
bool hasDriveId(const ref JSONValue item) {
	return ("driveId" in item) != null;
}

bool hasItemId(const ref JSONValue item) {
	return ("itemId" in item) != null;
}

bool hasDownloadFilename(const ref JSONValue item) {
	return ("downloadFilename" in item) != null;
}

bool hasResumeOffset(const ref JSONValue item) {
	return ("resumeOffset" in item) != null;
}

bool hasOnlineHash(const ref JSONValue item) {
	return ("onlineHash" in item) != null;
}

bool hasQuickXorHashResume(const ref JSONValue item) {
	return ("quickXorHash" in item["onlineHash"]) != null;
}

bool hasSHA256HashResume(const ref JSONValue item) {
	return ("sha256Hash" in item["onlineHash"]) != null;
}

// Test if a path is the equivalent of root '.'
bool isRootEquivalent(string inputPath) {
	auto normalisedPath = buildNormalizedPath(inputPath);
	return normalisedPath == "." || normalisedPath == "";
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
        addLogEntry("An error occurred: " ~ e.msg);
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

// Display internal memory stats pre garbage collection
void displayMemoryUsagePreGC() {
	// Display memory usage
	addLogEntry();
	addLogEntry("Memory Usage PRE Garbage Collection (KB)");
	addLogEntry("-----------------------------------------------------");
	writeMemoryStats();
	addLogEntry();
}

// Display internal memory stats post garbage collection + RSS (actual memory being used)
void displayMemoryUsagePostGC() {
    // Display memory usage title
    addLogEntry("Memory Usage POST Garbage Collection (KB)");
    addLogEntry("-----------------------------------------------------");
    writeMemoryStats();  // Assuming this function logs memory stats correctly

    // Query the actual Resident Set Size (RSS) for the PID
    pid_t pid = getCurrentPID();
    ulong rss = getRSS(pid);

    // Check and log the previous RSS value
    if (previousRSS != 0) {
        addLogEntry("previous Resident Set Size (RSS)         = " ~ to!string(previousRSS) ~ " KB");
        
        // Calculate and log the difference in RSS
        long difference = rss - previousRSS;  // 'difference' can be negative, use 'long' to handle it
        string sign = difference > 0 ? "+" : (difference < 0 ? "" : "");  // Determine the sign for display, no sign for zero
        addLogEntry("difference in Resident Set Size (RSS)    = " ~ sign ~ to!string(difference) ~ " KB");
    }
    
    // Update previous RSS with the new value
    previousRSS = rss;
    
    // Closeout
	addLogEntry();
}

// Write internal memory stats
void writeMemoryStats() {
	addLogEntry("current memory usedSize                  = " ~ to!string((GC.stats.usedSize/1024))); // number of used bytes on the GC heap (might only get updated after a collection)
	addLogEntry("current memory freeSize                  = " ~ to!string((GC.stats.freeSize/1024))); // number of free bytes on the GC heap (might only get updated after a collection)
	addLogEntry("current memory allocatedInCurrentThread  = " ~ to!string((GC.stats.allocatedInCurrentThread/1024))); // number of bytes allocated for current thread since program start
	
	// Query the actual Resident Set Size (RSS) for the PID
	pid_t pid = getCurrentPID();
	ulong rss = getRSS(pid);
	// The RSS includes all memory that is currently marked as occupied by the process. 
	// Over time, the heap can become fragmented. Even after garbage collection, fragmented memory blocks may not be contiguous enough to be returned to the OS, leading to an increase in the reported memory usage despite having free space.
	// This includes memory that might not be actively used but has not been returned to the system. 
	// The GC.minimize() function can sometimes cause an increase in RSS due to how memory pages are managed and freed.
	addLogEntry("current Resident Set Size (RSS)          = " ~ to!string(rss)  ~ " KB"); // actual memory in RAM used by the process at this point in time
}

// Return the username of the UID running the 'onedrive' process
string getUserName() {
    // Retrieve the UID of the current user
    auto uid = getuid();

    // Retrieve password file entry for the user
    auto pw = getpwuid(uid);
	
	// If user info is not found (e.g. no /etc/passwd entry), fallback to environment
    if (pw is null) {
        if (debugLogging) {
            addLogEntry("Unable to retrieve user info for UID: " ~ to!string(uid), ["debug"]);
            addLogEntry("Falling back to environment variable USER or returning 'unknown'", ["debug"]);
        }

        // Try environment variable
        string userEnv = environment.get("USER", "unknown");
        return userEnv.length > 0 ? userEnv : "unknown";
    }
	
	// If pw is valid, we can safely access pw.pw_name
    string userName = to!string(fromStringz(pw.pw_name));

    // Log User identifiers from process
	if (debugLogging) {
		addLogEntry("Process ID: " ~ to!string(pw), ["debug"]);
		addLogEntry("User UID:   " ~ to!string(pw.pw_uid), ["debug"]);
		addLogEntry("User GID:   " ~ to!string(pw.pw_gid), ["debug"]);
	}

    // Check if username is valid
    if (!userName.empty) {
        if (debugLogging) {addLogEntry("User Name:  " ~ userName, ["debug"]);}
        return userName;
    } else {
        // Log and return unknown user
        if (debugLogging) {addLogEntry("User Name:  unknown", ["debug"]);}
        return "unknown";
    }
}

// Calculate the ETA for when a 'large file' will be completed (upload & download operations)
int calc_eta(size_t counter, size_t iterations, long start_time) {
	if (counter == 0) {
		return 0; // Avoid division by zero
	}
	
	// Get the current time as a Unix timestamp (seconds since the epoch, January 1, 1970, 00:00:00 UTC)
	SysTime currentTime = Clock.currTime();
	long current_time = currentTime.toUnixTime();

	// 'start_time' must be less than 'current_time' otherwise ETA will have negative values
	if (start_time > current_time) {
		if (debugLogging) {
			addLogEntry("Warning: start_time is in the future. Cannot calculate ETA.", ["debug"]);
		}
		return 0;
	}
	
	// Calculate duration
	long duration = (current_time - start_time);

	// Calculate the ratio we are at
	double ratio = cast(double) counter / iterations;

	// Calculate segments left to download
	auto segments_remaining = (iterations > counter) ? (iterations - counter) : 0;

	// Calculate the average time per iteration so far
	double avg_time_per_iteration = cast(double) duration / counter;

	// Debug output for the ETA calculation
	if (debugLogging) {
		addLogEntry("counter:                " ~ to!string(counter), ["debug"]);
		addLogEntry("iterations:             " ~ to!string(iterations), ["debug"]);
		addLogEntry("segments_remaining:     " ~ to!string(segments_remaining), ["debug"]);
		addLogEntry("ratio:                  " ~ format("%.2f", ratio), ["debug"]);
		addLogEntry("start_time:             " ~ to!string(start_time), ["debug"]);
		addLogEntry("current_time:           " ~ to!string(current_time), ["debug"]);
		addLogEntry("duration:               " ~ to!string(duration), ["debug"]);
		addLogEntry("avg_time_per_iteration: " ~ format("%.2f", avg_time_per_iteration), ["debug"]);
	}
	
	// Return the ETA or duration
    if (counter != iterations) {
		auto eta_sec = avg_time_per_iteration * segments_remaining;
		// ETA Debug
		if (debugLogging) {
			addLogEntry("eta_sec:                " ~ to!string(eta_sec), ["debug"]);
			addLogEntry("estimated_total_time:   " ~ to!string(avg_time_per_iteration * iterations), ["debug"]);
		}
		// Return ETA
		return eta_sec > 0 ? cast(int) ceil(eta_sec) : 0;
	} else {
		// Return the average time per iteration for the last iteration
		return cast(int) ceil(avg_time_per_iteration); 
    }
}

// Use the ETA value and return a formatted string in a consistent manner
string formatETA(int eta) {
	// How do we format the ETA string. Guard against zero and negative values
	if (eta <= 0) {
		return "|  ETA    --:--:--";
	}
	int h, m, s;
	dur!"seconds"(eta).split!("hours", "minutes", "seconds")(h, m, s);
	return format!"|  ETA    %02d:%02d:%02d"(h, m, s);
}

// Force Exit due to failure
void forceExit() {
	// Allow any logging complete before we force exit
	Thread.sleep(dur!("msecs")(500));
	// Shutdown logging, which also flushes all logging buffers
	shutdownLogging();
	// Setup signal handling for the exit scope
	setupExitScopeSignalHandler();
	// Force Exit
	exit(EXIT_FAILURE);
}

// Get the current PID of the application
pid_t getCurrentPID() {
    // The '/proc/self' is a symlink to the current process's proc directory
    string path = "/proc/self/stat";
    
    // Read the content of the stat file
    string content;
    try {
        content = readText(path);
    } catch (Exception e) {
        writeln("Failed to read stat file: ", e.msg);
        return 0;
    }

    // The first value in the stat file is the PID
    auto parts = split(content);
    return to!pid_t(parts[0]);  // Convert the first part to pid_t
}

// Access the Resident Set Size (RSS) based on the PID of the running application
ulong getRSS(pid_t pid) {
    // Construct the path to the statm file for the given PID
    string path = format("/proc/%s/statm", to!string(pid));

    // Read the content of the file
    string content;
    try {
        content = readText(path);
    } catch (Exception e) {
        writeln("Failed to read statm file: ", e.msg);
        return 0;
    }

    // Split the content and get the RSS (second value)
    auto stats = split(content);
    if (stats.length < 2) {
        writeln("Unexpected format in statm file.");
        return 0;
    }

    // RSS is in pages, convert it to kilobytes
    ulong rssPages = to!ulong(stats[1]);
    ulong rssKilobytes = rssPages * sysconf(_SC_PAGESIZE) / 1024;
    return rssKilobytes;
}

// Getting around the @nogc problem
// https://p0nce.github.io/d-idioms/#Bypassing-@nogc
auto assumeNoGC(T) (T t) if (isFunctionPointer!T || isDelegate!T) {
	enum attrs = functionAttributes!T | FunctionAttribute.nogc;
	return cast(SetFunctionAttributes!(T, functionLinkage!T, attrs)) t;
}

// When using exit scopes, set up this to catch any undesirable signal
void setupExitScopeSignalHandler() {
	sigaction_t action;
	action.sa_handler = &exitScopeSignalHandler; // Direct function pointer assignment
	sigemptyset(&action.sa_mask); // Initialize the signal set to empty
	action.sa_flags = 0;
	sigaction(SIGSEGV, &action, null); // Invalid Memory Access signal
}

// Catch any SIGSEV generated by the exit scopes
extern(C) nothrow @nogc @system void exitScopeSignalHandler(int signo) {
	if (signo == SIGSEGV) {
		assumeNoGC ( () {
			// Caught a SIGSEGV but everything was shutdown cleanly .....
			//printf("Caught a SIGSEGV but everything was shutdown cleanly .....\n");
			exit(0);
		})();
	}
}

// Return the compiler details
string compilerDetails() {
	version(DigitalMars) enum compiler = "DMD";
	else version(LDC)    enum compiler = "LDC";
	else version(GNU)    enum compiler = "GDC";
	else enum compiler = "Unknown compiler";
	string compilerString = compiler ~ " " ~ to!string(__VERSION__);
	return compilerString;
}

// Return the curl version details
string getCurlVersionString() {
	// Get curl version
	auto versionInfo = curl_version();
	return to!string(versionInfo);
}

// Function to return the decoded curl version as a string
string getCurlVersionNumeric() {
    // Get curl version info using curl_version_info
    auto curlVersionDetails = curl_version_info(CURLVERSION_NOW);

    // Extract the major, minor, and patch numbers from version_num
    uint versionNum = curlVersionDetails.version_num;
    
    // The version number is in the format 0xXXYYZZ
    uint major = (versionNum >> 16) & 0xFF; // Extract XX (major version)
    uint minor = (versionNum >> 8) & 0xFF;  // Extract YY (minor version)
    uint patch = versionNum & 0xFF;         // Extract ZZ (patch version)

    // Return the version in the format "major.minor.patch"
    return major.to!string ~ "." ~ minor.to!string ~ "." ~ patch.to!string;
}

// Test the curl version against known curl versions with HTTP/2 issues
bool isBadCurlVersion(string curlVersion) {
    // List of known curl versions with HTTP/2 issues
    string[] supportedVersions = [
		"7.68.0", // Ubuntu 20.x
		"7.74.0", // Debian 11
		"7.81.0", // Ubuntu 22.x
		"7.88.1", // Debian 12
		"8.2.1",  // Ubuntu 23.10
		"8.5.0",  // Ubuntu 24.04
		"8.9.1",  // Ubuntu 24.10
		"8.10.0",  // Various - HTTP/2 bug which was fixed in 8.10.1
		"8.13.0",  // Has a SSL Certificate read issue fixed by 8.14.1
		"8.13.1",  // Has a SSL Certificate read issue fixed by 8.14.1
		"8.14.0",  // Has a SSL Certificate read issue fixed by 8.14.1
    ];
    
    // Check if the current version matches one of the supported versions
    return canFind(supportedVersions, curlVersion);
}

// Set the timestamp of the provided path to ensure this is done in a consistent manner
void setLocalPathTimestamp(bool dryRun, string inputPath, SysTime newTimeStamp) {
	
	SysTime updatedModificationTime;
	bool makeTimestampChange = false;
	
	// Try and set the local path timestamp, catch filesystem error
	try {
		// Set the correct time on the requested inputPath
		if (!dryRun) {
			if (debugLogging) {
				// Generate the initial log message
				string logMessage = format("Setting 'lastAccessTime' and 'lastModificationTime' properties for: %s to %s if required", inputPath, to!string(newTimeStamp));
				addLogEntry(logMessage, ["debug"]);
			}
			
			// Obtain the existing timestamp values
			SysTime existingAccessTime;
			SysTime existingModificationTime;
			getTimes(inputPath, existingAccessTime, existingModificationTime);
			
			if (debugLogging) {
				addLogEntry("Existing timestamp values:", ["debug"]);
				addLogEntry("  Access Time:       " ~ to!string(existingAccessTime), ["debug"]);
				addLogEntry("  Modification Time: " ~ to!string(existingModificationTime), ["debug"]);
			}
			
			// Compare the requested new modified timestamp to existing local modified timestamp
			SysTime newTimeStampZeroFracSec = newTimeStamp;
			SysTime existingTimeStampZeroFracSec = existingModificationTime;
			// Convert timestamps to UTC
			newTimeStampZeroFracSec = newTimeStampZeroFracSec.toUTC();
			existingTimeStampZeroFracSec = existingTimeStampZeroFracSec.toUTC();
			// Drop fractional seconds on both
			newTimeStampZeroFracSec.fracSecs = Duration.zero;
			existingTimeStampZeroFracSec.fracSecs = Duration.zero;
			
			if (debugLogging) {
				addLogEntry("Comparison timestamp values:", ["debug"]);
				addLogEntry("  newTimeStampZeroFracSec =      " ~ to!string(newTimeStampZeroFracSec), ["debug"]);
				addLogEntry("  existingTimeStampZeroFracSec = " ~ to!string(existingTimeStampZeroFracSec), ["debug"]);
			}
			
			// Perform the comparison of the fracsec truncated timestamps
			if (newTimeStampZeroFracSec == existingTimeStampZeroFracSec) {
				if (debugLogging) {addLogEntry("Fractional seconds only difference in modification time; preserving existing modification time", ["debug"]);}
				updatedModificationTime = existingModificationTime;
			} else {
				if (debugLogging) {addLogEntry("New timestamp is different to existing timestamp; using new modification time", ["debug"]);}
				updatedModificationTime = newTimeStamp;
				makeTimestampChange = true;
			}
			
			// Make the timestamp change for the path provided
			try {
				// Function detailed here: https://dlang.org/library/std/file/set_times.html
				// 		setTimes(path, accessTime, modificationTime)
				// We use the provided 'updatedModificationTime' to set modificationTime:
				//		modificationTime	Time the file/folder was last modified.
				// We use the existing 'existingAccessTime' to set accessTime:
				//		accessTime			Time the file/folder was last accessed.
				if (makeTimestampChange) {
					// new timestamp is different
					if (debugLogging) {addLogEntry("Calling setTimes() for the given path", ["debug"]);}
					setTimes(inputPath, existingAccessTime, updatedModificationTime);
					if (debugLogging) {addLogEntry("Timestamp updated for this path: " ~ inputPath, ["debug"]);}
				} else {
					if (debugLogging) {addLogEntry("No local timestamp change required", ["debug"]);}
				}
			} catch (FileException e) {
				// display the error message
				displayFileSystemErrorMessage(e.msg, getFunctionName!({}));
			}
			
			SysTime newAccessTime;
			SysTime newModificationTime;
			getTimes(inputPath, newAccessTime, newModificationTime);
			
			if (debugLogging) {
				addLogEntry("Current timestamp values post any change (if required):", ["debug"]);
				addLogEntry("  Access Time:       " ~ to!string(newAccessTime), ["debug"]);
				addLogEntry("  Modification Time: " ~ to!string(newModificationTime), ["debug"]);
			}
		}
	} catch (FileException e) {
		// display the error message
		displayFileSystemErrorMessage(e.msg, getFunctionName!({}));
	}
}

// Generate the initial function processing time log entry
void displayFunctionProcessingStart(string functionName, string logKey) {
	// Output the function processing header
	addLogEntry(format("[%s] Application Function '%s' Started", strip(logKey), strip(functionName)));
}

// Calculate the time taken to perform the application Function
void displayFunctionProcessingTime(string functionName, SysTime functionStartTime, SysTime functionEndTime, string logKey) {
	// Calculate processing time
	auto functionDuration = functionEndTime - functionStartTime;
	double functionDurationAsSeconds = (functionDuration.total!"msecs"/1e3); // msec --> seconds
	
	// Output the function processing time
	string processingTime = format("[%s] Application Function '%s' Processing Time = %.4f Seconds", strip(logKey), strip(functionName), functionDurationAsSeconds);
	addLogEntry(processingTime);
}

// Return true if `dir` exists and has no entries.
// Symlinks are treated as non-removable.
bool isDirEmpty(string dir) {
    if (!exists(dir) || !isDir(dir) || isSymlink(dir)) return false;
    foreach (_; dirEntries(dir, SpanMode.shallow)) {
        // Found at least one entry
        return false;
    }
    return true;
}

// Escape a string for literal use inside a regex
string regexEscape(string s) {
	auto b = appender!string();
	foreach (c; s) {
		// characters with special meaning in regex
		immutable specials = "\\.^$|?*+()[]{}";
		if (specials.canFind(c)) b.put('\\');
		b.put(c);
	}
	return b.data;
}
