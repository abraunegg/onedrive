// What is this module called?
module clientSideFiltering;

// What does this module require to function?
import std.algorithm;
import std.array;
import std.file;
import std.path;
import std.regex;
import std.stdio;
import std.string;
import std.conv;

// What other modules that we have created do we need to import?
import config;
import util;
import log;

class ClientSideFiltering {
	// Class variables
	ApplicationConfig appConfig;
	string[] paths;
	Regex!char fileMask;
	Regex!char directoryMask;
	bool skipDirStrictMatch = false;
	bool skipDotfiles = false;
	
	this(ApplicationConfig appConfig) {
		// Configure the class variable to consume the application configuration
		this.appConfig = appConfig;
	}
	
	~this() {
		object.destroy(appConfig);
		object.destroy(paths);
		object.destroy(fileMask);
		object.destroy(directoryMask);
	}
	
	// Initialise the required items
	bool initialise() {
		// Log what is being done
		addLogEntry("Configuring Client Side Filtering (Selective Sync)", ["debug"]);
		
		// Load the sync_list file if it exists
		if (exists(appConfig.syncListFilePath)){
			loadSyncList(appConfig.syncListFilePath);
		}
		
		// Configure skip_dir, skip_file, skip-dir-strict-match & skip_dotfiles from config entries
		// Handle skip_dir configuration in config file
		addLogEntry("Configuring skip_dir ...", ["debug"]);
		addLogEntry("skip_dir: " ~ to!string(appConfig.getValueString("skip_dir")), ["debug"]);
		setDirMask(appConfig.getValueString("skip_dir"));
		
		// Was --skip-dir-strict-match configured?
		addLogEntry("Configuring skip_dir_strict_match ...", ["debug"]);
		addLogEntry("skip_dir_strict_match: " ~ to!string(appConfig.getValueBool("skip_dir_strict_match")), ["debug"]);
		if (appConfig.getValueBool("skip_dir_strict_match")) {
			setSkipDirStrictMatch();
		}
		
		// Was --skip-dot-files configured?
		addLogEntry("Configuring skip_dotfiles ...", ["debug"]);
		addLogEntry("skip_dotfiles: " ~ to!string(appConfig.getValueBool("skip_dotfiles")), ["debug"]);
		if (appConfig.getValueBool("skip_dotfiles")) {
			setSkipDotfiles();
		}
		
		// Handle skip_file configuration in config file
		addLogEntry("Configuring skip_file ...", ["debug"]);
		
		// Validate skip_file to ensure that this does not contain an invalid configuration
		// Do not use a skip_file entry of .* as this will prevent correct searching of local changes to process.
		foreach(entry; appConfig.getValueString("skip_file").split("|")){
			if (entry == ".*") {
				// invalid entry element detected
				addLogEntry("ERROR: Invalid skip_file entry '.*' detected");
				return false;
			}
		}
		
		// All skip_file entries are valid
		addLogEntry("skip_file: " ~ appConfig.getValueString("skip_file"), ["debug"]);
		setFileMask(appConfig.getValueString("skip_file"));
		
		// All configured OK
		return true;
	}
	
	// Shutdown components
	void shutdown() {
		object.destroy(appConfig);
		object.destroy(paths);
		object.destroy(fileMask);
		object.destroy(directoryMask);
	}
	
	// Load sync_list file if it exists
	void loadSyncList(string filepath) {
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
	
	// Configure the regex that will be used for 'skip_file'
	void setFileMask(const(char)[] mask) {
		fileMask = wild2regex(mask);
		addLogEntry("Selective Sync File Mask: " ~ to!string(fileMask), ["debug"]);
	}

	// Configure the regex that will be used for 'skip_dir'
	void setDirMask(const(char)[] dirmask) {
		directoryMask = wild2regex(dirmask);
		addLogEntry("Selective Sync Directory Mask: " ~ to!string(directoryMask), ["debug"]);
	}
	
	// Configure skipDirStrictMatch if function is called
	// By default, skipDirStrictMatch = false;
	void setSkipDirStrictMatch() {
		skipDirStrictMatch = true;
	}
	
	// Configure skipDotfiles if function is called
	// By default, skipDotfiles = false;
	void setSkipDotfiles() {
		skipDotfiles = true;
	}
	
	// return value of skipDotfiles
	bool getSkipDotfiles() {
		return skipDotfiles;
	}
	
	// Match against sync_list only
	bool isPathExcludedViaSyncList(string path) {
		// Debug output that we are performing a 'sync_list' inclusion / exclusion test
		return isPathExcluded(path, paths);
	}
	
	// config file skip_dir parameter
	bool isDirNameExcluded(string name) {
		// Does the directory name match skip_dir config entry?
		// Returns true if the name matches a skip_dir config entry
		// Returns false if no match
		addLogEntry("skip_dir evaluation for: " ~ name, ["debug"]);
		
		// Try full path match first
		if (!name.matchFirst(directoryMask).empty) {
			addLogEntry("'!name.matchFirst(directoryMask).empty' returned true = matched", ["debug"]);
			return true;
		} else {
			// Do we check the base name as well?
			if (!skipDirStrictMatch) {
				addLogEntry("No Strict Matching Enforced", ["debug"]);
				
				// Test the entire path working backwards from child
				string path = buildNormalizedPath(name);
				string checkPath;
				foreach_reverse(directory; pathSplitter(path)) {
					if (directory != "/") {
						// This will add a leading '/' but that needs to be stripped to check
						checkPath = "/" ~ directory ~ checkPath;
						if(!checkPath.strip('/').matchFirst(directoryMask).empty) {
							addLogEntry("'!checkPath.matchFirst(directoryMask).empty' returned true = matched", ["debug"]);
							return true;
						}
					}
				}
			} else {
				// No match
				addLogEntry("Strict Matching Enforced - No Match", ["debug"]);
			}
		}
		// no match
		return false;
	}
	
	// config file skip_file parameter
	bool isFileNameExcluded(string name) {
		// Does the file name match skip_file config entry?
		// Returns true if the name matches a skip_file config entry
		// Returns false if no match
		addLogEntry("skip_file evaluation for: " ~ name, ["debug"]);
	
		// Try full path match first
		if (!name.matchFirst(fileMask).empty) {
			return true;
		} else {
			// check just the file name
			string filename = baseName(name);
			if(!filename.matchFirst(fileMask).empty) {
				return true;
			}
		}
		// no match
		return false;
	}
	
	// test if the given path is not included in the allowed paths
	// if there are no allowed paths always return false
	private bool isPathExcluded(string path, string[] allowedPaths) {
		// function variables
		bool exclude = false;
		bool exludeDirectMatch = false; // will get updated to true, if there is a pattern match to sync_list entry
		bool excludeMatched = false; // will get updated to true, if there is a pattern match to sync_list entry
		bool finalResult = true; // will get updated to false, if pattern match to sync_list entry
		int offset;
		string wildcard = "*";
		
		// always allow the root
		if (path == ".") return false;
		// if there are no allowed paths always return false
		if (allowedPaths.empty) return false;
		path = buildNormalizedPath(path);
		addLogEntry("Evaluation against 'sync_list' for this path: " ~ path, ["debug"]);
		addLogEntry("[S]exclude           = " ~  to!string(exclude), ["debug"]);
		addLogEntry("[S]exludeDirectMatch = " ~ to!string(exludeDirectMatch), ["debug"]);
		addLogEntry("[S]excludeMatched    = " ~ to!string(excludeMatched), ["debug"]);
		
		// unless path is an exact match, entire sync_list entries need to be processed to ensure
		// negative matches are also correctly detected
		foreach (allowedPath; allowedPaths) {
			// is this an inclusion path or finer grained exclusion?
			switch (allowedPath[0]) {
				case '-':
					// sync_list path starts with '-', this user wants to exclude this path
					exclude = true;
					// If the sync_list entry starts with '-/' offset needs to be 2, else 1
					if (startsWith(allowedPath, "-/")){
						// Offset needs to be 2
						offset = 2;
					} else {
						// Offset needs to be 1
						offset = 1;
					}
					break;
				case '!':
					// sync_list path starts with '!', this user wants to exclude this path
					exclude = true;
					// If the sync_list entry starts with '!/' offset needs to be 2, else 1
					if (startsWith(allowedPath, "!/")){
						// Offset needs to be 2
						offset = 2;
					} else {
						// Offset needs to be 1
						offset = 1;
					}
					break;
				case '/':
					// sync_list path starts with '/', this user wants to include this path
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
			addLogEntry("Evaluation against 'sync_list' entry: " ~ allowedPath, ["debug"]);
			
			// Generate the common prefix from the path vs the allowed path
			auto comm = commonPrefix(path, allowedPath[offset..$]);
			
			// Is path is an exact match of the allowed path?
			if (comm.length == path.length) {
				// we have a potential exact match
				// strip any potential '/*' from the allowed path, to avoid a potential lesser common match
				string strippedAllowedPath = strip(allowedPath[offset..$], "/*");
				
				if (path == strippedAllowedPath) {
					// we have an exact path match
					addLogEntry("Exact path match with 'sync_list' entry", ["debug"]);
					
					if (!exclude) {
						addLogEntry("Evaluation against 'sync_list' result: direct match", ["debug"]);
						finalResult = false;
						// direct match, break and go sync
						break;
					} else {
						addLogEntry("Evaluation against 'sync_list' result: direct match - path to be excluded", ["debug"]);
						
						// do not set excludeMatched = true here, otherwise parental path also gets excluded
						// flag exludeDirectMatch so that a 'wildcard match' will not override this exclude
						exludeDirectMatch = true;
						// final result
						finalResult = true;
					}	
				} else {
					// no exact path match, but something common does match
					addLogEntry("Something 'common' matches the 'sync_list' input path", ["debug"]);
					
					auto splitAllowedPaths = pathSplitter(strippedAllowedPath);
					string pathToEvaluate = "";
					foreach(base; splitAllowedPaths) {
						pathToEvaluate ~= base;
						if (path == pathToEvaluate) {
							// The input path matches what we want to evaluate against as a direct match
							if (!exclude) {
								addLogEntry("Evaluation against 'sync_list' result: direct match for parental path item", ["debug"]);
								finalResult = false;
								// direct match, break and go sync
								break;
							} else {
								addLogEntry("Evaluation against 'sync_list' result: direct match for parental path item but to be excluded", ["debug"]);
								finalResult = true;
								// do not set excludeMatched = true here, otherwise parental path also gets excluded
							}					
						}
						pathToEvaluate ~= dirSeparator;
					}
				}
			}
			
			// Is path is a subitem/sub-folder of the allowed path?
			if (comm.length == allowedPath[offset..$].length) {
				// The given path is potentially a subitem of an allowed path
				// We want to capture sub-folders / files of allowed paths here, but not explicitly match other items
				// if there is no wildcard
				auto subItemPathCheck = allowedPath[offset..$] ~ "/";
				if (canFind(path, subItemPathCheck)) {
					// The 'path' includes the allowed path, and is 'most likely' a sub-path item
					if (!exclude) {
						addLogEntry("Evaluation against 'sync_list' result: parental path match", ["debug"]);
						finalResult = false;
						// parental path matches, break and go sync
						break;
					} else {
						addLogEntry("Evaluation against 'sync_list' result: parental path match but must be excluded", ["debug"]);
						finalResult = true;
						excludeMatched = true;
					}
				}
			}
			
			// Does the allowed path contain a wildcard? (*)
			if (canFind(allowedPath[offset..$], wildcard)) {
				// allowed path contains a wildcard
				// manually replace '*' for '.*' to be compatible with regex
				string regexCompatiblePath = replace(allowedPath[offset..$], "*", ".*");
				auto allowedMask = regex(regexCompatiblePath);
				if (matchAll(path, allowedMask)) {
					// regex wildcard evaluation matches
					// if we have a prior pattern match for an exclude, excludeMatched = true
					if (!exclude && !excludeMatched && !exludeDirectMatch) {
						// nothing triggered an exclusion before evaluation against wildcard match attempt
						addLogEntry("Evaluation against 'sync_list' result: wildcard pattern match", ["debug"]);
						finalResult = false;
					} else {
						addLogEntry("Evaluation against 'sync_list' result: wildcard pattern matched but must be excluded", ["debug"]);
						finalResult = true;
						excludeMatched = true;
					}
				}
			}
		}
		// Interim results
		addLogEntry("[F]exclude           = " ~ to!string(exclude), ["debug"]);
		addLogEntry("[F]exludeDirectMatch = " ~ to!string(exludeDirectMatch), ["debug"]);
		addLogEntry("[F]excludeMatched    = " ~ to!string(excludeMatched), ["debug"]);
		
		// If exclude or excludeMatched is true, then finalResult has to be true
		if ((exclude) || (excludeMatched) || (exludeDirectMatch)) {
			finalResult = true;
		}
		
		// results
		if (finalResult) {
			addLogEntry("Evaluation against 'sync_list' final result: EXCLUDED", ["debug"]);
		} else {
			addLogEntry("Evaluation against 'sync_list' final result: included for sync", ["debug"]);
		}
		return finalResult;
	}
}