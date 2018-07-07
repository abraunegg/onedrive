import std.algorithm;
import std.array;
import std.file;
import std.path;
import std.regex;
import std.stdio;
import util;
static import log;

final class SelectiveSync
{
	private string[] paths;
	private Regex!char mask;

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

	void setMask(const(char)[] mask)
	{
		this.mask = wild2regex(mask);
	}

	// config file skip_file parameter
	bool isNameExcluded(string name)
	{
		// Does the file match skip_file config entry?
		// Returns true if the file matches a skip_file config entry
		// Returns false if no match
		log.dlog("Checking '", name, "' for exclusion...");
		log.dlog("    Name matched in skip_file: ", !name.matchFirst(mask).empty);
		return !name.matchFirst(mask).empty;
	}

	// config sync_list file handling
	// also incorporates skip_file config parameter for expanded regex path matching
	bool isPathExcluded(string path)
	{
		log.dlog("Checking '", path, "' for exclusion...");
		log.dlog("    Path excluded in sync_list: ", .isPathExcluded(path, paths));
		log.dlog("    Path matched in skip_file: ", .isPathMatched(path, mask));
		return .isPathExcluded(path, paths) || .isPathMatched(path, mask);
	}
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
			log.dlog("    Path matched for '", prefix, "'");
			return true;
		}
		prefix ~= dirSeparator;
	}
	return false;
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

unittest
{
	assert(isPathExcluded("Documents2", ["Documents"]));
	assert(!isPathExcluded("Documents", ["Documents"]));
	assert(!isPathExcluded("Documents/a.txt", ["Documents"]));
	assert(isPathExcluded("Hello/World", ["Hello/John"]));
	assert(!isPathExcluded(".", ["Documents"]));
}
