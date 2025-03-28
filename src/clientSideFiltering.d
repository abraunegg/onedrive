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
	string[] syncListRules;
	Regex!char fileMask;
	Regex!char directoryMask;
	bool skipDirStrictMatch = false;
	bool skipDotfiles = false;
	
	this(ApplicationConfig appConfig) {
		// Configure the class variable to consume the application configuration
		this.appConfig = appConfig;
	}
	
	// Initialise the required items
	bool initialise() {
		// Log what is being done
		if (debugLogging) {addLogEntry("Configuring Client Side Filtering (Selective Sync)", ["debug"]);}
		
		// Load the sync_list file if it exists
		if (exists(appConfig.syncListFilePath)){
			loadSyncList(appConfig.syncListFilePath);
		}
		
		// Configure skip_dir, skip_file, skip-dir-strict-match & skip_dotfiles from config entries
		// Handle skip_dir configuration in config file
		if (debugLogging) {
			addLogEntry("Configuring skip_dir ...", ["debug"]);
			addLogEntry("skip_dir: " ~ to!string(appConfig.getValueString("skip_dir")), ["debug"]);
		}
		setDirMask(appConfig.getValueString("skip_dir"));
		
		// Was --skip-dir-strict-match configured?
		if (debugLogging) {
			addLogEntry("Configuring skip_dir_strict_match ...", ["debug"]);
			addLogEntry("skip_dir_strict_match: " ~ to!string(appConfig.getValueBool("skip_dir_strict_match")), ["debug"]);
		}
		if (appConfig.getValueBool("skip_dir_strict_match")) {
			setSkipDirStrictMatch();
		}
		
		// Was --skip-dot-files configured?
		if (debugLogging) {
			addLogEntry("Configuring skip_dotfiles ...", ["debug"]);
			addLogEntry("skip_dotfiles: " ~ to!string(appConfig.getValueBool("skip_dotfiles")), ["debug"]);
		}
		if (appConfig.getValueBool("skip_dotfiles")) {
			setSkipDotfiles();
		}
		
		// Handle skip_file configuration in config file
		if (debugLogging) {addLogEntry("Configuring skip_file ...", ["debug"]);}
		
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
		if (debugLogging) {addLogEntry("skip_file: " ~ appConfig.getValueString("skip_file"), ["debug"]);}
		setFileMask(appConfig.getValueString("skip_file"));
		
		// All configured OK
		return true;
	}
	
	// Shutdown components
	void shutdown() {
		syncListRules = null;
		fileMask = regex("");
		directoryMask = regex("");
	}
	
	// Load sync_list file if it exists
	void loadSyncList(string filepath) {
		// open file as read only
		auto file = File(filepath, "r");
		auto range = file.byLine();
		foreach (line; range) {
			// Skip any line that is empty or just contains whitespace
			if (line.strip.length == 0) continue;
			
			// Skip comments in file
			if (line[0] == ';' || line[0] == '#') continue;
			
			// Is the rule a legacy 'include all root files' lazy rule?
			if ((strip(line) == "/*") || (strip(line) == "/")) {
				// yes ...
				string errorMessage = "ERROR: Invalid sync_list rule '" ~ to!string(strip(line)) ~ "' detected. Please use 'sync_root_files = \"true\"' or --sync-root-files option to sync files in the root path.";
				addLogEntry();
				addLogEntry(errorMessage, ["info", "notify"]);
				addLogEntry();
				// do not add this rule
			} else {
				// Ensure that 'sync_list' rules do not start with the sequence './'
				if ((line[0] == '.') && (line[1] == '/')) {
					// Display warning about 'sync_list' rule composition
					string errorMessage = "ERROR: Invalid sync_list rule '" ~ to!string(strip(line)) ~ "' detected. Rule should not start with './' - please fix your 'sync_list' rule.";
					addLogEntry();
					addLogEntry(errorMessage, ["info", "notify"]);
					addLogEntry();
					// this broken rule will be added, but will not work right until the user fixes it ... user action required
				}
				
				// add rule to list of rules
				syncListRules ~= buildNormalizedPath(line);
			}
		}
		// Close reading the 'sync_list' file
		file.close();
	}
	
	// return true or false based on if we have loaded any valid sync_list rules
	bool validSyncListRules() {
		// If empty, will return true
		return syncListRules.empty;
	}
	
	// Configure the regex that will be used for 'skip_file'
	void setFileMask(const(char)[] mask) {
		fileMask = wild2regex(mask);
		if (debugLogging) {addLogEntry("Selective Sync File Mask: " ~ to!string(fileMask), ["debug"]);}
	}

	// Configure the regex that will be used for 'skip_dir'
	void setDirMask(const(char)[] dirmask) {
		directoryMask = wild2regex(dirmask);
		if (debugLogging) {addLogEntry("Selective Sync Directory Mask: " ~ to!string(directoryMask), ["debug"]);}
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
		return isPathExcluded(path);
	}
	
	// config file skip_dir parameter
	bool isDirNameExcluded(string name) {
		// Does the directory name match skip_dir config entry?
		// Returns true if the name matches a skip_dir config entry
		// Returns false if no match
		if (debugLogging) {addLogEntry("skip_dir evaluation for: " ~ name, ["debug"]);}

		// Ensure the path being passed in is cleaned up to remove the leading '.'
		if (startsWith(name, "./")) {
			name = name[1..$];
			if (debugLogging) {addLogEntry("skip_dir evaluation for (updated): " ~ name, ["debug"]);}
		}

		// Try full path match first
		if (!name.matchFirst(directoryMask).empty) {
			if (debugLogging) {addLogEntry("skip_dir evaluation: '!name.matchFirst(directoryMask).empty' returned true = matched", ["debug"]);}
			return true;
		} 

		// Test individual segments if not in strict match mode
		if (!skipDirStrictMatch) {
			if (debugLogging) {addLogEntry("No Strict Matching Enforced", ["debug"]);}

			string path = buildNormalizedPath(name);
			foreach_reverse(directory; pathSplitter(path)) {
				if (directory != "/") {
					if (directory.matchFirst(directoryMask)) {
						if (debugLogging) {addLogEntry("skip_dir evaluation: 'directory.matchFirst(directoryMask)' returned true = matched", ["debug"]);}
						return true;
					}
				}
			}
		} else {
			if (debugLogging) {addLogEntry("Strict Matching Enforced - No Match", ["debug"]);}
		}

		// No match
		return false;
	}

	// config file skip_file parameter
	bool isFileNameExcluded(string name) {
		// Does the file name match skip_file config entry?
		// Returns true if the name matches a skip_file config entry
		// Returns false if no match
		if (debugLogging) {addLogEntry("skip_file evaluation for: " ~ name, ["debug"]);}
	
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
	
	// test if the given path is not included in the allowed syncListRules
	// if there are no allowed syncListRules always return false
	private bool isPathExcluded(string path) {
		// function variables
		bool exclude = false;
		bool excludeExactMatch = false; // will get updated to true, if there is a pattern match to sync_list entry
		bool excludeParentMatched = false; // will get updated to true, if there is a pattern match to sync_list entry
		bool finalResult = true; // will get updated to false, if pattern match to sync_list entry
		bool anywhereRuleMatched = false; // will get updated if the 'anywhere' rule matches
		bool excludeAnywhereMatched = false; // will get updated if the 'anywhere' rule matches
		bool wildcardRuleMatched = false; // will get updated if the 'wildcard' rule matches
		bool excludeWildcardMatched = false; // will get updated if the 'wildcard' rule matches
		int offset;
		string wildcard = "*";
		string globbing = "**";
				
		// always allow the root
		if (path == ".") return false;
		
		// if there are no allowed syncListRules always return false, meaning path is not excluded
		if (syncListRules.empty) return false;
		
		// To ensure we are checking the 'right' path, build the path
		path = buildPath("/", buildNormalizedPath(path));
		
		// Evaluation start point, in order of what is checked as well
		if (debugLogging) {
			addLogEntry("******************* SYNC LIST RULES EVALUATION START *******************", ["debug"]);
			addLogEntry("Evaluation against 'sync_list' rules for this input path: " ~ path, ["debug"]);
			addLogEntry("[S]excludeExactMatch      = " ~ to!string(excludeExactMatch), ["debug"]);
			addLogEntry("[S]excludeParentMatched   = " ~ to!string(excludeParentMatched), ["debug"]);
			addLogEntry("[S]excludeAnywhereMatched = " ~ to!string(excludeAnywhereMatched), ["debug"]);
			addLogEntry("[S]excludeWildcardMatched = " ~ to!string(excludeWildcardMatched), ["debug"]);
		}
		
		// Unless path is an exact match, entire sync_list entries need to be processed to ensure negative matches are also correctly detected
		foreach (syncListRuleEntry; syncListRules) {

			// There are several matches we need to think of here
			// Exclusions:
			//		!foldername/*  					 			= As there is no preceding '/' (after the !) .. this is a rule that should exclude 'foldername' and all its children ANYWHERE
			//		!*.extension   					 			= As there is no preceding '/' (after the !) .. this is a rule that should exclude any item that has the specified extension ANYWHERE
			//		!/path/to/foldername/*  		 			= As there IS a preceding '/' (after the !) .. this is a rule that should exclude this specific path and all its children
			//		!/path/to/foldername/*.extension 			= As there IS a preceding '/' (after the !) .. this is a rule that should exclude any item that has the specified extension in this path ONLY
			//		!/path/to/foldername/*/specific_target/*	= As there IS a preceding '/' (after the !) .. this excludes 'specific_target' in any subfolder of '/path/to/foldername/'
			//
			// Inclusions:
			//		foldername/*  					 			= As there is no preceding '/' .. this is a rule that should INCLUDE 'foldername' and all its children ANYWHERE
			//		*.extension   					 			= As there is no preceding '/' .. this is a rule that should INCLUDE any item that has the specified extension ANYWHERE
			//		/path/to/foldername/*  		 				= As there IS a preceding '/' .. this is a rule that should INCLUDE this specific path and all its children
			//		/path/to/foldername/*.extension 			= As there IS a preceding '/' .. this is a rule that should INCLUDE any item that has the specified extension in this path ONLY
			//		/path/to/foldername/*/specific_target/*		= As there IS a preceding '/' .. this INCLUDES 'specific_target' in any subfolder of '/path/to/foldername/'

			if (debugLogging) {addLogEntry("------------------------------ NEW RULE --------------------------------", ["debug"]);}
			
			// Is this rule an 'exclude' or 'include' rule?
			bool thisIsAnExcludeRule = false;
			
			// Switch based on first character of rule to determine rule type
			switch (syncListRuleEntry[0]) {
				case '-':
					// sync_list path starts with '-', this user wants to exclude this path
					exclude = true; // default exclude
					thisIsAnExcludeRule = true; // exclude rule
					offset = 1; // To negate the '-' in the rule entry
					break;
				case '!':
					// sync_list path starts with '!', this user wants to exclude this path
					exclude = true; // default exclude
					thisIsAnExcludeRule = true; // exclude rule
					offset = 1; // To negate the '!' in the rule entry
					break;
				case '/':
					// sync_list path starts with '/', this user wants to include this path
					// but a '/' at the start causes matching issues, so use the offset for comparison
					exclude = false; // DO NOT EXCLUDE
					thisIsAnExcludeRule = false; // INCLUDE rule
					offset = 0;
					break;
				default:
					// no negative pattern, default is to not exclude
					exclude = false; // DO NOT EXCLUDE
					thisIsAnExcludeRule = false; // INCLUDE rule
					offset = 0;
			}
			
			// Update syncListRuleEntry to remove the offset
			syncListRuleEntry = syncListRuleEntry[offset..$];
			
			// What 'sync_list' rule are we comparing against?
			if (thisIsAnExcludeRule) {
				if (debugLogging) {addLogEntry("Evaluation against EXCLUSION 'sync_list' rule: !" ~ syncListRuleEntry, ["debug"]);}
			} else {
				if (debugLogging) {addLogEntry("Evaluation against INCLUSION 'sync_list' rule: " ~ syncListRuleEntry, ["debug"]);}
			}
			
			// Is path is an exact match of the 'sync_list' rule, or do the input path segments (directories) match the 'sync_list' rule?
			// wildcard (*) rules are below if we get there, if this rule does not contain a wildcard
			if ((to!string(syncListRuleEntry[0]) == "/") && (!canFind(syncListRuleEntry, wildcard))) {
				// attempt to perform an exact segment match
				// split both paths by '/' to create segment arrays
				string[] ruleSegments = syncListRuleEntry.strip.split("/").filter!(s => !s.empty).array;
				string[] pathSegments = path.strip.split("/").filter!(s => !s.empty).array;
				
				// Print rule and input segments for validation during debug
				if (debugLogging) {
					addLogEntry("Rule Segments: " ~ to!string(ruleSegments), ["debug"]);
					addLogEntry("Path Segments: " ~ to!string(pathSegments), ["debug"]);
				}
				
				if (exactMatchRuleSegmentsToPathSegments(ruleSegments, pathSegments)) {
					// EXACT PATH MATCH
					if (debugLogging) {addLogEntry("Exact path match with 'sync_list' rule entry", ["debug"]);}
					
					if (!thisIsAnExcludeRule) {
						// Include Rule
						if (debugLogging) {addLogEntry("Evaluation against 'sync_list' rule result: direct match", ["debug"]);}
						// final result
						finalResult = false;
						// direct match, break and search rules no more given include rule match
						break;
					} else {
						// Exclude rule
						if (debugLogging) {addLogEntry("Evaluation against 'sync_list' rule result: exclusion direct match - path to be excluded", ["debug"]);}
						// flag excludeExactMatch so that a 'wildcard match' will not override this exclude
						excludeExactMatch = true;
						exclude = true;
						// final result
						finalResult = true;
						// dont break here, finish checking other rules
					}
				} else {
					// NOT an EXACT MATCH, so check the very first path segment
					// - This is so that paths in 'sync_list' as specified as /some path/another path/ actually get included|excluded correctly
					if (matchFirstSegmentToPathFirstSegment(ruleSegments, pathSegments)) {
						// PARENT ROOT MATCH
						if (debugLogging) {addLogEntry("Parent root path match with 'sync_list' rule entry", ["debug"]);}
						
						// Does the 'rest' of the input path match?
						// We only need to do this step if the input path has more and 1 segment (the parent folder)
						if (count(pathSegments) > 1) {
							// More segments to check, so do a parental path match
							if (matchRuleSegmentsToPathSegments(ruleSegments, pathSegments)) {
								// PARENTAL PATH MATCH
								if (debugLogging) {addLogEntry("Parental path match with 'sync_list' rule entry", ["debug"]);}
								// What sort of rule was this?
								if (!thisIsAnExcludeRule) {
									// Include Rule
									if (debugLogging) {addLogEntry("Evaluation against 'sync_list' rule result: parental path match", ["debug"]);}
									// final result
									finalResult = false;
									// parental path match, break and search rules no more given include rule match
									break;
								} else {
									// Exclude rule
									if (debugLogging) {addLogEntry("Evaluation against 'sync_list' rule result: exclusion parental path match - path to be excluded", ["debug"]);}
									excludeParentMatched = true;
									exclude = true;
									// final result
									finalResult = true;
									// dont break here, finish checking other rules
								}
							}
						} else {
							// No more segments to check
							if (!thisIsAnExcludeRule) {
								// Include Rule
								if (debugLogging) {addLogEntry("Evaluation against 'sync_list' rule result: parent root path match to rule", ["debug"]);}
								// final result
								finalResult = false;
								// parental path match, break and search rules no more given include rule match
								break;
							} else {
								// Exclude rule
								{addLogEntry("Evaluation against 'sync_list' rule result: exclusion parent root path match to rul - path to be excluded", ["debug"]);}
								excludeParentMatched = true;
								exclude = true;
								// final result
								finalResult = true;
								// dont break here, finish checking other rules
							}
						}
					}
				}
			}
			
			// Is the 'sync_list' rule an 'anywhere' rule?
			//	EXCLUSION
			//		!foldername/*
			//		!*.extension 
			//  INCLUSION
			//		foldername/*
			//		*.extension 
			if (to!string(syncListRuleEntry[0]) != "/") {
				// reset anywhereRuleMatched
				anywhereRuleMatched = false; 
			
				// what sort of rule
				if (thisIsAnExcludeRule) {
					if (debugLogging) {addLogEntry("anywhere 'sync_list' exclusion rule: !" ~ syncListRuleEntry, ["debug"]);}
				} else {
					if (debugLogging) {addLogEntry("anywhere 'sync_list' inclusion rule: " ~ syncListRuleEntry, ["debug"]);}
				}
				
				// this is an 'anywhere' rule
				string anywhereRuleStripped;
				// If this 'sync_list' rule end in '/*' - if yes, remove it to allow for easier comparison
				if (syncListRuleEntry.endsWith("/*")) {
					// strip '/*' from the end of the rule
					anywhereRuleStripped = syncListRuleEntry.stripRight("/*");
				} else {
					// keep rule 'as-is'
					anywhereRuleStripped = syncListRuleEntry;
				}
				
				if (canFind(path, anywhereRuleStripped)) {
					// we matched the path to the rule
					if (debugLogging) {addLogEntry("anywhere rule 'canFind' MATCH", ["debug"]);}
					anywhereRuleMatched = true;
				} else {
					// no 'canFind' match, try via regex
					if (debugLogging) {addLogEntry("No anywhere rule 'canFind' MATCH .. trying a regex match", ["debug"]);}
					
					// create regex from 'syncListRuleEntry'
					auto allowedMask = regex(createRegexCompatiblePath(syncListRuleEntry));
					
					// perform regex match attempt
					if (matchAll(path, allowedMask)) {
						// we regex matched the path to the rule
						if (debugLogging) {addLogEntry("anywhere rule 'matchAll via regex' MATCH", ["debug"]);}
						anywhereRuleMatched = true;
					}
				}
				
				// is this rule matched?
				if (anywhereRuleMatched) {
					// Is this an exclude rule?
					if (thisIsAnExcludeRule) {
						if (debugLogging) {addLogEntry("Evaluation against 'sync_list' rule result: anywhere rule matched and must be excluded", ["debug"]);}
						excludeAnywhereMatched = true;
						exclude = true;
						finalResult = true;
						// anywhere match, break and search rules no more
						break;
					} else {
						if (debugLogging) {addLogEntry("Evaluation against 'sync_list' rule result: anywhere rule matched and must be included", ["debug"]);}
						finalResult = false;
						excludeAnywhereMatched = false;
						// anywhere match, break and search rules no more
						break;
					}
				}
			}
			
			// Does the 'sync_list' rule contain a wildcard (*) or globbing (**) reference anywhere in the rule?
			//	EXCLUSION
			//		!/Programming/Projects/Android/**/build/*
			//  INCLUSION
			//		/Programming/Projects/Android/**/build/*
			if (canFind(syncListRuleEntry, wildcard)) {
				// reset the applicable flag
				wildcardRuleMatched = false;
				
				// Does this 'wildcard' rule even apply to this path?
				auto wildcardDepth = firstWildcardDepth(syncListRuleEntry);
				auto pathSegments = count(path.strip.split("/").filter!(s => !s.empty).array);
				
				// are there enough path segments for this wildcard rule to apply?
				if (pathSegments < wildcardDepth) {
					// there are not enough path segments up to the first wildcard character for this rule to even be applicable
					if (debugLogging) {addLogEntry("- This sync list wildcard rule should not be evaluated as the wildcard appears beyond the current input path", ["debug"]);}
				} else {
					// path segments are enough for this wildcard rule to potentially apply
					// sync_list rule contains some sort of wildcard sequence
					if (thisIsAnExcludeRule) {
						if (debugLogging) {addLogEntry("wildcard (* or **) exclusion rule: !" ~ syncListRuleEntry, ["debug"]);}
					} else {
						if (debugLogging) {addLogEntry("wildcard (* or **) inclusion rule: " ~ syncListRuleEntry, ["debug"]);}
					}
					
					// Is this a globbing rule (**) or just a single wildcard (*) entries
					if (canFind(syncListRuleEntry, globbing)) {
						// globbing (**) rule processing
						if (matchPathAgainstRule(path, syncListRuleEntry)) {
							// set the applicable flag
							wildcardRuleMatched = true;
							if (debugLogging) {addLogEntry("Evaluation against 'sync_list' rule result: globbing pattern match using segment matching", ["debug"]);}
						}
					} else {
						// wildcard (*) rule processing
						// create regex from 'syncListRuleEntry'
						auto allowedMask = regex(createRegexCompatiblePath(syncListRuleEntry));
						if (matchAll(path, allowedMask)) {
							// set the applicable flag
							wildcardRuleMatched = true;
							if (debugLogging) {addLogEntry("Evaluation against 'sync_list' rule result: wildcard pattern match", ["debug"]);}
						} else {
							// matchAll no match ... try another way just to be sure
							if (matchPathAgainstRule(path, syncListRuleEntry)) {
								// set the applicable flag
								wildcardRuleMatched = true;
								if (debugLogging) {addLogEntry("Evaluation against 'sync_list' rule result: wildcard pattern match using segment matching", ["debug"]);}
							}
						}
					}
					
					// Was the rule matched?
					if (wildcardRuleMatched) {
						// Is this an exclude rule?
						if (thisIsAnExcludeRule) {
							// Yes exclude rule
							if (debugLogging) {addLogEntry("Evaluation against 'sync_list' rule result: wildcard|globbing rule matched and must be excluded", ["debug"]);}
							excludeWildcardMatched = true;
							exclude = true;
							finalResult = true;
						} else {
							// include rule
							if (debugLogging) {addLogEntry("Evaluation against 'sync_list' rule result: wildcard|globbing pattern matched and must be included", ["debug"]);}
							finalResult = false;
							excludeWildcardMatched = false;
						}
					}
				}
			}
		}
		
		// debug logging post 'sync_list' rule evaluations
		if (debugLogging) {
			// Rule evaluation complete
			addLogEntry("------------------------------------------------------------------------", ["debug"]);
		
			// Interim results after checking each 'sync_list' rule against the input path
			addLogEntry("[F]excludeExactMatch      = " ~ to!string(excludeExactMatch), ["debug"]);
			addLogEntry("[F]excludeParentMatched   = " ~ to!string(excludeParentMatched), ["debug"]);
			addLogEntry("[F]excludeAnywhereMatched = " ~ to!string(excludeAnywhereMatched), ["debug"]);
			addLogEntry("[F]excludeWildcardMatched = " ~ to!string(excludeWildcardMatched), ["debug"]);
		}
		
		// If any of these exclude match items is true, then finalResult has to be flagged as true
		if ((exclude) || (excludeExactMatch) || (excludeParentMatched) || (excludeAnywhereMatched) || (excludeWildcardMatched)) {
			finalResult = true;
		}
		
		// Final Result
		if (finalResult) {
			if (debugLogging) {addLogEntry("Evaluation against 'sync_list' final result: EXCLUDED as no rule included path", ["debug"]);}
		} else {
			if (debugLogging) {addLogEntry("Evaluation against 'sync_list' final result: included for sync", ["debug"]);}
		}
		if (debugLogging) {addLogEntry("******************* SYNC LIST RULES EVALUATION END *********************", ["debug"]);}
		return finalResult;
	}
	
	// Calculate wildcard character depth in path
	int firstWildcardDepth(string syncListRuleEntry) {
		int depth = 0;
		foreach (segment; pathSplitter(syncListRuleEntry))
		{
			if (segment.canFind("*")) // Check for wildcard characters
				return depth;
			depth++;
		}
		return depth; // No wildcard found should be '0'
	}

	// Create a wildcard regex compatible string based on the sync list rule
	string createRegexCompatiblePath(string regexCompatiblePath) {
		// Escape all special regex characters that could break regex parsing
		regexCompatiblePath = escaper(regexCompatiblePath).text;
		
		// Restore wildcard support
		regexCompatiblePath = regexCompatiblePath.replace("\\*", ".*");
		
		// Ensure space matches only literal space, not \s (tabs, etc.)
		regexCompatiblePath = regexCompatiblePath.replace(" ", "\\ ");
		
		// Return the regex compatible path
		return regexCompatiblePath;
	}

	// Create a regex compatible string to match a relevant segment
	bool matchSegment(string ruleSegment, string pathSegment) {
		ruleSegment = ruleSegment.replace("*", ".*");  // Replace * with '.*' to be compatible with function and to match any characters
		ruleSegment = ruleSegment.replace(" ", "\\s");  // Escape spaces if present
		auto pattern = regex("^" ~ ruleSegment ~ "$");
		// Check if there's a match
		return !match(pathSegment, pattern).empty;
	}
	
	// Function to handle path matching when using globbing (**)
	bool matchPathAgainstRule(string path, string rule) {
		// Split both the path and rule into segments
		auto pathSegments = pathSplitter(path).filter!(s => !s.empty).array;
		auto ruleSegments = pathSplitter(rule).filter!(s => !s.empty).array;

		bool lastSegmentMatchesRule = false;
		size_t i = 0, j = 0;

		while (i < pathSegments.length && j < ruleSegments.length) {
			if (ruleSegments[j] == "**") {
				if (j == ruleSegments.length - 1) {
					return true; // '**' at the end matches everything
				}

				// Find next matching part after '**'
				while (i < pathSegments.length && !matchSegment(ruleSegments[j + 1], pathSegments[i])) {
					i++;
				}
				j++; // Move past the '**' in the rule
			} else {
				if (!matchSegment(ruleSegments[j], pathSegments[i])) {
					return false;
				} else {
					// increment to next set of values
					i++;
					j++;
				}
			}
		}
		
		// Ensure that we handle the last segments gracefully
		if (i >= pathSegments.length && j < ruleSegments.length) {
			if (j == ruleSegments.length - 1 && ruleSegments[j] == "*") {
				return true;
			}
			if (ruleSegments[j - 1] == pathSegments[i - 1]) {
				lastSegmentMatchesRule = true;
			}
		}

		return j == ruleSegments.length || (j == ruleSegments.length - 1 && ruleSegments[j] == "**") || lastSegmentMatchesRule;
	}
	
	bool exactMatchRuleSegmentsToPathSegments(string[] ruleSegments, string[] inputSegments) {
		if (debugLogging) {addLogEntry("Running exactMatchRuleSegmentsToPathSegments()", ["debug"]);}
		
		// If rule has more segments than input, or input has more segments than rule, no match is possible
		if ((ruleSegments.length > inputSegments.length) || ( inputSegments.length > ruleSegments.length)) {
			return false;
		}

		// Iterate over each segment and compare
		for (size_t i = 0; i < ruleSegments.length; ++i) {
			if (ruleSegments[i] != inputSegments[i]) {
				if (debugLogging) {addLogEntry("Mismatch at segment " ~ to!string(i) ~ ": Rule Segment = " ~ ruleSegments[i] ~ ", Input Segment = " ~ inputSegments[i], ["debug"]);}
				return false; // Return false if any segment doesn't match
			}
		}

		// If all segments match, return true
		if (debugLogging) {addLogEntry("All segments matched: Rule Segments = " ~ to!string(ruleSegments) ~ ", Input Segments = " ~ to!string(inputSegments), ["debug"]);}
		return true;
	}
	
	bool matchRuleSegmentsToPathSegments(string[] ruleSegments, string[] inputSegments) {
		if (debugLogging) {addLogEntry("Running matchRuleSegmentsToPathSegments()", ["debug"]);}
		
		// If rule has more segments than input, no match is possible
		if (ruleSegments.length > inputSegments.length) {
			return false;
		}

		// Compare segments up to the length of the rule path
		return equal(ruleSegments, inputSegments[0 .. ruleSegments.length]);
	}
	
	bool matchFirstSegmentToPathFirstSegment(string[] ruleSegments, string[] inputSegments) {
		if (debugLogging) {addLogEntry("Running matchFirstSegmentToPathFirstSegment()", ["debug"]);}
				
		// Check that both segments are not empty
		if (ruleSegments.length == 0 || inputSegments.length == 0) {
			return false; // Return false if either segment array is empty
		}

		// Compare the first segments only
		return equal(ruleSegments[0], inputSegments[0]);
	}
}