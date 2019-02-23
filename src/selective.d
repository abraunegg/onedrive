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
	private Regex!char mask;
	private Regex!char dirmask;

	void load(string filepath)
	{
		if (exists(filepath)) {
			paths = File(filepath)
				.byLine()
				.map!(a => buildNormalizedPath(a))
				.filter!(a => a.length > 0)
				.array;
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
	
	// config file skip_dir parameter
	bool isDirNameExcluded(string name)
	{
		// Does the directory name match skip_dir config entry?
		// Returns true if the name matches a skip_dir config entry
		// Returns false if no match
		return !name.matchFirst(dirmask).empty;
	}
	
	// config file skip_file parameter
	bool isFileNameExcluded(string name)
	{
		// Does the file name match skip_file config entry?
		// Returns true if the name matches a skip_file config entry
		// Returns false if no match
		return !name.matchFirst(mask).empty;
	}
	
	// config sync_list file handling
	bool isPathExcluded(string path)
	{
		return .isPathExcluded(path, paths) || .isPathMatched(path, mask);
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

unittest
{
	assert(isPathExcluded("Documents2", ["Documents"]));
	assert(!isPathExcluded("Documents", ["Documents"]));
	assert(!isPathExcluded("Documents/a.txt", ["Documents"]));
	assert(isPathExcluded("Hello/World", ["Hello/John"]));
	assert(!isPathExcluded(".", ["Documents"]));
}
