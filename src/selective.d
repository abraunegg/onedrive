import std.algorithm;
import std.array;
import std.file;
import std.path;
import std.regex;
import std.stdio;
import std.string;
import util;
import log;

final class SelectiveSync
{
	private string[] paths;
	private string[] businessSharedFoldersList;
	private Regex!char mask;
	private Regex!char dirmask;
	private bool skipDirStrictMatch = false;
	private bool skipDotfiles = false;

	// load sync_list file
	void load(string filepath)
	{
		if (exists(filepath)) {
			// open file as read only
			auto file = File(filepath, "r");
			auto range = file.byLine();
			foreach (line; range) {
				// Skip comments in file
				if (line.length == 0 || line[0] == ';' || line[0] == '#') continue;
				paths ~= buildNormalizedPath(line);
			}
			file.close();
		}
	}
	
	// Configure skipDirStrictMatch if function is called
	// By default, skipDirStrictMatch = false;
	void setSkipDirStrictMatch()
	{
		skipDirStrictMatch = true;
	}

	// load business_shared_folders file
	void loadSharedFolders(string filepath)
	{
		if (exists(filepath)) {
			// open file as read only
			auto file = File(filepath, "r");
			auto range = file.byLine();
			foreach (line; range) {
				// Skip comments in file
				if (line.length == 0 || line[0] == ';' || line[0] == '#') continue;
				businessSharedFoldersList ~= buildNormalizedPath(line);
			}
			file.close();
		}
	}
	
	void setFileMask(const(char)[] mask)
	{
		this.mask = wild2regex(mask);
	}

	void setDirMask(const(char)[] dirmask)
	{
		this.dirmask = wild2regex(dirmask);
	}
	
	// Configure skipDotfiles if function is called
	// By default, skipDotfiles = false;
	void setSkipDotfiles() 
	{
		skipDotfiles = true;
	}
	
	// return value of skipDotfiles
	bool getSkipDotfiles()
	{
		return skipDotfiles;
	}
	
	// config file skip_dir parameter
	bool isDirNameExcluded(string name)
	{
		// Does the directory name match skip_dir config entry?
		// Returns true if the name matches a skip_dir config entry
		// Returns false if no match
		log.vdebug("skip_dir evaluation for: ", name);
		
		// Try full path match first
		if (!name.matchFirst(dirmask).empty) {
			return true;
		} else {
			// Do we check the base name as well?
			if (!skipDirStrictMatch) {
				// check just the basename in the path
				string parent = baseName(name);
				if(!parent.matchFirst(dirmask).empty) {
					return true;
				}
			}
		}
		// no match
		return false;
	}
	
	// config file skip_file parameter
	bool isFileNameExcluded(string name)
	{
		// Does the file name match skip_file config entry?
		// Returns true if the name matches a skip_file config entry
		// Returns false if no match
		log.vdebug("skip_file evaluation for: ", name);
	
		// Try full path match first
		if (!name.matchFirst(mask).empty) {
			return true;
		} else {
			// check just the file name
			string filename = baseName(name);
			if(!filename.matchFirst(mask).empty) {
				return true;
			}
		}
		// no match
		return false;
	}
	
	// Match against sync_list only
	bool isPathExcludedViaSyncList(string path)
	{
		// Debug output that we are performing a 'sync_list' inclusion / exclusion test
		return .isPathExcluded(path, paths);
	}
	
	// Match against skip_dir, skip_file & sync_list entries
	bool isPathExcludedMatchAll(string path)
	{
		return .isPathExcluded(path, paths) || .isPathMatched(path, mask) || .isPathMatched(path, dirmask);
	}
	
	// is the path a dotfile?
	bool isDotFile(string path)
	{
		// always allow the root
		if (path == ".") return false;

		path = buildNormalizedPath(path);
		auto paths = pathSplitter(path);
		foreach(base; paths) {
			if (startsWith(base, ".")){
				return true;
			}
		}
		return false;
	}
	
	// is business shared folder matched
	bool isSharedFolderMatched(string name)
	{
		// if there are no shared folder always return false
		if (businessSharedFoldersList.empty) return false;
		
		if (!name.matchFirst(businessSharedFoldersList).empty) {
			return true;
		} else {
			return false;
		}
	}
	
	// is business shared folder included
	bool isPathIncluded(string path, string[] allowedPaths)
	{
		// always allow the root
		if (path == ".") return true;
		// if there are no allowed paths always return true
		if (allowedPaths.empty) return true;

		path = buildNormalizedPath(path);
		foreach (allowed; allowedPaths) {
			auto comm = commonPrefix(path, allowed);
			if (comm.length == path.length) {
				// the given path is contained in an allowed path
				return true;
			}
			if (comm.length == allowed.length && path[comm.length] == '/') {
				// the given path is a subitem of an allowed path
				return true;
			}
		}
		return false;
	}
}

// test if the given path is not included in the allowed paths
// if there are no allowed paths always return false
private bool isPathExcluded(string path, string[] allowedPaths)
{
	// function variables
	bool exclude = false;
	bool finalResult = true; // will get updated to false, if pattern matched to sync_list entry
	int offset;
	string wildcard = "*";
	
	// always allow the root
	if (path == ".") return false;
	// if there are no allowed paths always return false
	if (allowedPaths.empty) return false;
	path = buildNormalizedPath(path);
	log.vdebug("Evaluation against 'sync_list' for: ", path);
	
	// unless path is an exact match, entire sync_list entries need to be processed to ensure
	// negative matches are also correctly detected
	foreach (allowedPath; allowedPaths) {
		// is this an inclusion path or finer grained exclusion?
		switch (allowedPath[0]) {
			case '-':
				// allowed path starts with '-', this user wants to exclude this path
				exclude = true;
				offset = 1;
				break;
			case '!':
				// allowed path starts with '!', this user wants to exclude this path
				exclude = true;
				offset = 1;
				break;
			case '/':
				// allowed path starts with '/', this user wants to include this path
				// but a '/' at the start causes matching issues, so use the offset for comparison
				exclude = false;
				offset = 1;
				break;	
				
			default:
				// no negative pattern, default is to not exclude
				exclude = false;
				offset = 0;
		}
		
		// What are we comparing against?
		log.vdebug("Evaluation against 'sync_list' entry: ", allowedPath);
		
		// Generate the common prefix from the path vs the allowed path
		auto comm = commonPrefix(path, allowedPath[offset..$]);
		
		// is path is an exact match of the allowed path
		if (comm.length == path.length) {
			// the given path is contained in an allowed path
			if (!exclude) {
				log.vdebug("Evaluation against 'sync_list' result: direct match");
				finalResult = false;
				// direct match, break and go sync
				break;
			} else {
				log.vdebug("Evaluation against 'sync_list' result: direct match but to be excluded");
				finalResult = true;
			}
		}
		
		// is path is a subitem of the allowed path
		if (comm.length == allowedPath[offset..$].length) {
			// the given path is a subitem of an allowed path
			if (!exclude) {
				log.vdebug("Evaluation against 'sync_list' result: parental path match");
				finalResult = false;
			} else {
				log.vdebug("Evaluation against 'sync_list' result: parental path match but to be excluded");
				finalResult = true;
			}
		}
		
		// does the allowed path contain a wildcard? (*)
		if (canFind(allowedPath[offset..$], wildcard)) {
			// allowed path contains a wildcard
			// manually replace '*' for '.*' to be compatible with regex
			string regexCompatiblePath = replace(allowedPath[offset..$], "*", ".*");
			auto allowedMask = regex(regexCompatiblePath);
			if (matchAll(path, allowedMask)) {
				// regex wildcard evaluation matches
				if (!exclude) {
					log.vdebug("Evaluation against 'sync_list' result: wildcard pattern match");
					finalResult = false;
				} else {
					log.vdebug("Evaluation against 'sync_list' result: wildcard pattern match but to be excluded");
					finalResult = true;
				}
			}
		}
	}
	// results
	if (finalResult) {
		log.vdebug("Evaluation against 'sync_list' final result: EXCLUDED");
	} else {
		log.vdebug("Evaluation against 'sync_list' final result: included for sync");
	}
	return finalResult;
}

// test if the given path is matched by the regex expression.
// recursively test up the tree.
private bool isPathMatched(string path, Regex!char mask) {
	path = buildNormalizedPath(path);
	auto paths = pathSplitter(path);

	string prefix = "";
	foreach(base; paths) {
		prefix ~= base;
		if (!path.matchFirst(mask).empty) {
			// the given path matches something which we should skip
			return true;
		}
		prefix ~= dirSeparator;
	}
	return false;
}

// unit tests
unittest
{
	assert(isPathExcluded("Documents2", ["Documents"]));
	assert(!isPathExcluded("Documents", ["Documents"]));
	assert(!isPathExcluded("Documents/a.txt", ["Documents"]));
	assert(isPathExcluded("Hello/World", ["Hello/John"]));
	assert(!isPathExcluded(".", ["Documents"]));
}
