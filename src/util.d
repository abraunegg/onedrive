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
import qxor;
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

// returns the crc32 hex string of a file
string computeCrc32(string path)
{
	CRC32 crc;
	auto file = File(path, "rb");
	foreach (ubyte[] data; chunks(file, 4096)) {
		crc.put(data);
	}
	return crc.finish().toHexString().dup;
}

// returns the sha1 hash hex string of a file
string computeSha1Hash(string path)
{
	SHA1 sha;
	auto file = File(path, "rb");
	foreach (ubyte[] data; chunks(file, 4096)) {
		sha.put(data);
	}
	return sha.finish().toHexString().dup;
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
	http.dnsTimeout = (dur!"seconds"(5));
	http.method = HTTP.Method.head;
	// Attempt to contact the Microsoft Online Service
	try {	
		http.perform();
		http.shutdown();
		return true;
	} catch (SocketException) {
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
		log.log("Skipping uploading this file as it cannot be read (file permissions or file corruption): ", path);
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
	if (itemName == "Icon") {matched = false;}
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
