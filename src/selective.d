import std.algorithm;
import std.array;
import std.file;
import std.path;
import std.regex;
import std.stdio;
import util;

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
		
		// Try full path match first
		if (!name.matchFirst(dirmask).empty) {
			return true;
		} else {
			// Do we check the base name as well?
			if (!skipDirStrictMatch) {
				// check just the basename in the path
				string filename = baseName(name);
				if(!filename.matchFirst(dirmask).empty) {
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
	// always allow the root
	if (path == ".") return false;
	// if there are no allowed paths always return false
	if (allowedPaths.empty) return false;

	path = buildNormalizedPath(path);
	foreach (allowed; allowedPaths) {
		auto comm = commonPrefix(path, allowed);
		if (comm.length == path.length) {
			// the given path is contained in an allowed path
			return false;
		}
		if (comm.length == allowed.length && path[comm.length] == '/') {
			// the given path is a subitem of an allowed path
			return false;
		}
	}
	return true;
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
