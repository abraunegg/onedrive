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
	string[] syncListIncludePathsOnly; // These are 'include' rules that start with a '/'
	string[] syncListAnywherePathOnly; // These are 'include' rules that do not start with a '/', thus are to be searched anywhere for inclusion
	Regex!char fileMask;
	Regex!char directoryMask;
	bool skipDirStrictMatch = false;
	bool skipDotfiles = false;
	
	// Define these at the class level
	string wildcard = "*";
	string globbing = "**";
	
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
		
		// Handle skip_dir configuration in config file
		if (debugLogging) {addLogEntry("Configuring skip_dir ...", ["debug"]);}
		
		// Validate skip_dir entries to ensure that this does not contain an invalid configuration
		// Do not use a skip_dir entry of .* as this will prevent correct searching of local changes to process.
		foreach(entry; appConfig.getValueString("skip_dir").split("|")){
			if (entry == ".*") {
				// invalid entry element detected
				addLogEntry();
				addLogEntry("ERROR: Invalid skip_dir entry '.*' detected.");
				addLogEntry("       To exclude hidden directories (those starting with '.'), enable the 'skip_dotfiles' configuration option instead of using wildcard patterns.");
				addLogEntry();
				return false;
			}
		}
		
		// All skip_dir entries are valid
		if (debugLogging) {addLogEntry("skip_dir: " ~ appConfig.getValueString("skip_dir"), ["debug"]);}
		setDirMask(appConfig.getValueString("skip_dir"));
		
		// Was --skip-dir-strict-match configured?
		if (debugLogging) {
			addLogEntry("Configuring skip_dir_strict_match ...", ["debug"]);
			addLogEntry("skip_dir_strict_match: " ~ to!string(appConfig.getValueBool("skip_dir_strict_match")), ["debug"]);
		}
		if (appConfig.getValueBool("skip_dir_strict_match")) {
			setSkipDirStrictMatch();
		}
		
		// Handle skip_file configuration in config file
		if (debugLogging) {addLogEntry("Configuring skip_file ...", ["debug"]);}
		
		// Validate skip_file entries to ensure that this does not contain an invalid configuration
		// Do not use a skip_file entry of .* as this will prevent correct searching of local changes to process.
		foreach(entry; appConfig.getValueString("skip_file").split("|")){
			if (entry == ".*") {
				// invalid entry element detected
				addLogEntry();
				addLogEntry("ERROR: Invalid skip_file entry '.*' detected.");
				addLogEntry("       To exclude hidden files (those starting with '.'), enable the 'skip_dotfiles' configuration option instead of using wildcard patterns.");
				addLogEntry();
				return false;
			}
		}
		
		// All skip_file entries are valid
		if (debugLogging) {addLogEntry("skip_file: " ~ appConfig.getValueString("skip_file"), ["debug"]);}
		setFileMask(appConfig.getValueString("skip_file"));
		
		// Was --skip-dot-files configured?
		if (debugLogging) {
			addLogEntry("Configuring skip_dotfiles ...", ["debug"]);
			addLogEntry("skip_dotfiles: " ~ to!string(appConfig.getValueBool("skip_dotfiles")), ["debug"]);
		}
		if (appConfig.getValueBool("skip_dotfiles")) {
			setSkipDotfiles();
		}

		// Validate 'sync_list' include rules are not shadowed by 'skip_file' entries
		if (!validateSyncListNotShadowedBySkipFile()) {
			return false;
		}
		
		// Validate 'sync_list' include rules are not shadowed by 'skip_dir' entries
		if (!validateSyncListNotShadowedBySkipDir()) {
			// The application configuration is invalid .. 'skip_dir' is shadowing paths included by 'sync_list'
			return false;
		}
		
		// Client Side Filtering has been configured correctly
		return true;
	}
	
	// Shutdown components
	void shutdown() {
		syncListRules = null;
		syncListIncludePathsOnly = null;
		syncListAnywherePathOnly = null;
		fileMask = regex("");
		directoryMask = regex("");
	}

	// Load sync_list file if it exists
	void loadSyncList(string filepath) {
		// open file as read only
		auto file = File(filepath, "r");
		auto range = file.byLine();

		scope(exit) {
			file.close();
			object.destroy(file);
			object.destroy(range);
		}

		scope(failure) {
			file.close();
			object.destroy(file);
			object.destroy(range);
		}

		foreach (line; range) {
			auto cleanLine = strip(line);

			// Skip any line that is empty or just contains whitespace
			if (cleanLine.length == 0) continue;

			// Skip comments in file
			if (cleanLine[0] == ';' || cleanLine[0] == '#') continue;

			// Invalid exclusion rule patterns
			if (cleanLine == "!/*" || cleanLine == "!/" || cleanLine == "-/*" || cleanLine == "-/") {
				string errorMessage = "ERROR: Invalid sync_list rule '" ~ to!string(cleanLine) ~ "' detected. Please read the 'sync_list' documentation.";
				addLogEntry();
				addLogEntry(errorMessage, ["info", "notify"]);
				addLogEntry();
				// do not add this rule
				continue;
			}

			// Legacy include root rule
			if (cleanLine == "/*" || cleanLine == "/") {
				string errorMessage = "ERROR: Invalid sync_list rule '" ~ to!string(cleanLine) ~ "' detected. Please use 'sync_root_files = \"true\"' or --sync-root-files option to sync files in the root path.";
				addLogEntry();
				addLogEntry(errorMessage, ["info", "notify"]);
				addLogEntry();
				// do not add this rule
				continue;
			}

			// './' rule warning
			if ((cleanLine.length > 1) && (cleanLine[0] == '.') && (cleanLine[1] == '/')) {
				string errorMessage = "ERROR: Invalid sync_list rule '" ~ to!string(cleanLine) ~ "' detected. Rule should not start with './' - please fix your 'sync_list' rule.";
				addLogEntry();
				addLogEntry(errorMessage, ["info", "notify"]);
				addLogEntry();
				// do not add this rule
				continue;
			}

			// Normalise the 'sync_list' rule and store
			auto normalisedRulePath = buildNormalizedPath(cleanLine);
			syncListRules ~= normalisedRulePath;

			// Only add the normalised rule to the specific include list if not an exclude rule
			if (cleanLine[0] != '!' && cleanLine[0] != '-') {
				// All include rules get added here
				syncListIncludePathsOnly ~= normalisedRulePath;
				
				// Special case for searching local disk for new data added 'somewhere'
				if (cleanLine[0] != '/') {
					// Rule is an 'anywhere' rule within the 'sync_list'
					syncListAnywherePathOnly ~= normalisedRulePath;
				}
			}
		}
		
		// Close the file post reading it
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
	
	// Match against 'sync_list' only
	bool isPathExcludedViaSyncList(string path) {
		// Are there 'sync_list' rules to process?
		if (count(syncListRules) > 0) {
			// Perform 'sync_list' rule testing on the given path
			return isPathExcluded(path);
		} else {
			// There are no valid 'sync_list' rules that were loaded
			return false; // not excluded by 'sync_list'
		}
	}
	
	// config 'skip_dir' parameter checking
	bool isDirNameExcluded(string inputPath) {
		// Returns true if the inputPath matches a skip_dir config entry (directoryMask)
		// Returns false if no match

		if (debugLogging) {
			addLogEntry("skip_dir evaluation for: " ~ inputPath, ["debug"]);
		}

		// Build candidate path variants to cover common inputs:
		// - "./Documents/Uni" (most common from sync engine)
		// - "Documents/Uni"  (relative)
		// - "/Documents/Uni" (user occasionally prefixes with '/')
		string name = inputPath;

		// Normalise leading "./" to relative
		if (startsWith(name, "./")) {
			name = name[2 .. $];
			if (debugLogging) addLogEntry("skip_dir evaluation (normalised inputPath, removed leading './'): " ~ name, ["debug"]);
		}

		// Create a small set of candidates (avoid duplicates)
		string[] candidates;
		void addCandidate(string c) {
			if (c.empty) return;
			foreach (e; candidates) {
				if (e == c) return;
			}
			candidates ~= c;
		}

		addCandidate(name);

		// If name is rooted, also test relative form
		if (!name.empty && name[0] == '/') {
			addCandidate(name[1 .. $]);
		} else {
			// If name is relative, also test rooted form (covers skip_dir rules that were authored with a leading '/')
			addCandidate("/" ~ name);
		}

		// Also test trailing-slash equivalence for directory roots
		// (treat "Documents" and "Documents/" the same, but do not create "//")
		string[] expanded;
		foreach (c; candidates) {
			expanded ~= c;
			if (c.length > 1 && c[$ - 1] != '/') {
				expanded ~= (c ~ "/");
			}
		}
		candidates = expanded;

		// ------------------------------------------------------------
		// 1) Full-path match first (strict semantics)
		// ------------------------------------------------------------
		foreach (c; candidates) {
			if (!c.matchFirst(directoryMask).empty) {
				if (debugLogging) addLogEntry("skip_dir full-path match: " ~ c, ["debug"]);
				return true;
			}
		}

		// ------------------------------------------------------------
		// 2) Non-strict mode: test path segments for a match
		// ------------------------------------------------------------
		if (!skipDirStrictMatch) {
			if (debugLogging) addLogEntry("No Strict Matching Enforced - testing individual path segments", ["debug"]);

			foreach (c; candidates) {
				// buildNormalizedPath may introduce a leading '/', so we keep it as-is
				// and let pathSplitter do its job. We are matching segments, not full paths here.
				string path = buildNormalizedPath(c);

				if (debugLogging) addLogEntry("skip_dir segment test path: " ~ path, ["debug"]);

				foreach_reverse(seg; pathSplitter(path)) {
					if (seg == "/") continue;

					// seg is a single component (e.g. "Documents")
					if (!seg.matchFirst(directoryMask).empty) {
						if (debugLogging) {
							addLogEntry("skip_dir segment match: " ~ seg, ["debug"]);
						}
						return true;
					}
				}
			}
		} else {
			if (debugLogging) addLogEntry("Strict Matching Enforced - no segment testing", ["debug"]);
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
		
		// Split input path by '/' to create an applicable path segment array
		// - This is reused below in a number of places
		string[] pathSegments = path.strip.split("/").filter!(s => !s.empty).array;
		
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
			
			// Split rule path by '/' to create an applicable path segment array
			// - This is reused below in a number of places
			string[] ruleSegments = syncListRuleEntry.strip.split("/").filter!(s => !s.empty).array;
			
			// Configure logging rule type
			string ruleKind = thisIsAnExcludeRule ? "exclusion rule" : "inclusion rule";
			
			// Is path is an exact match of the 'sync_list' rule, or do the input path segments (directories) match the 'sync_list' rule?
			// wildcard (*) rules are below if we get there, if this rule does not contain a wildcard
			if ((to!string(syncListRuleEntry[0]) == "/") && (!canFind(syncListRuleEntry, wildcard))) {
			
				// what sort of rule is this - 'exact match' include or exclude rule?
				if (debugLogging) {addLogEntry("Testing input path against an exact match 'sync_list' " ~ ruleKind, ["debug"]);}
			
				// Print rule and input segments for validation during debug
				if (debugLogging) {
					addLogEntry(" - Calculated Rule Segments: " ~ to!string(ruleSegments), ["debug"]);
					addLogEntry(" - Calculated Path Segments: " ~ to!string(pathSegments), ["debug"]);
				}
				
				// Test for exact segment matching of input path to rule
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
					if (debugLogging) {addLogEntry("No exact path match with 'sync_list' rule entry - checking path segments to verify", ["debug"]);}
										
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
								{addLogEntry("Evaluation against 'sync_list' rule result: exclusion parent root path match to rule - path to be excluded", ["debug"]);}
								excludeParentMatched = true;
								exclude = true;
								// final result
								finalResult = true;
								// dont break here, finish checking other rules
							}
						}
					} else {
						// No parental path segment match
						if (debugLogging) {addLogEntry("No parental path match with 'sync_list' rule entry - exact path matching not possible", ["debug"]);}
					}
				}
				
				// What 'rule' type are we currently testing?
				if (!thisIsAnExcludeRule) {
					// Is the path a parental path match to an include 'sync_list' rule?
					if (isSyncListPrefixMatch(path)) {
						// PARENTAL PATH MATCH
						if (debugLogging) {
							addLogEntry("Parental path match with 'sync_list' rule entry (syncListIncludePathsOnly)", ["debug"]);
							addLogEntry("Evaluation against 'sync_list' rule result: parental path match (syncListIncludePathsOnly)", ["debug"]);
						}
						// final result
						finalResult = false;
						// parental path match, break and search rules no more given include rule match
						break;
					}
				}
			}
			
			// Is the 'sync_list' rule an 'anywhere' rule?
			//  EXCLUSION
			//    !foldername/*
			//    !*.extension
			//    !foldername
			//  INCLUSION
			//    foldername/*
			//    *.extension
			//    foldername
			if (to!string(syncListRuleEntry[0]) != "/") {
				// reset anywhereRuleMatched
				anywhereRuleMatched = false; 
			
				// what sort of rule is this - 'anywhere' include or exclude rule?
				if (debugLogging) {addLogEntry("Testing input path against an anywhere 'sync_list' " ~ ruleKind, ["debug"]);}
				
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
				
				// If the input path is exactly the parent root (single segment) and that segment
				// matches the rule's first segment, treat it as a match.
				if (!ruleSegments.empty && count(pathSegments) == 1 && matchFirstSegmentToPathFirstSegment(ruleSegments, pathSegments)) {
					if (debugLogging) {
						addLogEntry(" - anywhere rule 'parent root' MATCH with '" ~ ruleSegments[0] ~ "'", ["debug"]);
					}
					anywhereRuleMatched = true;
				}
				
				if (!anywhereRuleMatched) {
					if (canFind(path, anywhereRuleStripped)) {
						// we matched the path to the rule
						if (debugLogging) {addLogEntry(" - anywhere rule 'canFind' MATCH", ["debug"]);}
						anywhereRuleMatched = true;
					} else {
						// no 'canFind' match, try via regex
						if (debugLogging) {addLogEntry(" - anywhere rule 'canFind' NO_MATCH .. trying a regex match", ["debug"]);}
						
						// create regex from 'syncListRuleEntry'
						auto allowedMask = regex(createRegexCompatiblePath(syncListRuleEntry));
						
						// perform regex match attempt
						if (matchAll(path, allowedMask)) {
							// we regex matched the path to the rule
							if (debugLogging) {addLogEntry(" - anywhere rule 'matchAll via regex' MATCH", ["debug"]);}
							anywhereRuleMatched = true;
						} else {
							// no match
							if (debugLogging) {addLogEntry(" - anywhere rule 'matchAll via regex' NO_MATCH", ["debug"]);}
						}
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
			//  EXCLUSION
			//    !/Programming/Projects/Android/**/build/*
			//    !/build/kotlin/*
			//  INCLUSION
			//    /Programming/Projects/Android/**/build/*
			//    /build/kotlin/*
			if (canFind(syncListRuleEntry, wildcard)) {
				// A '*' wildcard is in the rule, but we do not know what type of wildcard yet .. 
				// reset the applicable flag
				wildcardRuleMatched = false;
				
				// What sort of rule is this - globbing (**) or wildcard (*)
				bool globbingRule = false;
				globbingRule = canFind(syncListRuleEntry, globbing);
				
				// The sync_list rule contains some sort of wildcard sequence - lets log this correctly as to the rule type we are testing
				string ruleType = globbingRule ? "globbing (**)" : "wildcard (*)";
				if (debugLogging) {addLogEntry("Testing input path against a " ~ ruleType ~ " 'sync_list' " ~ ruleKind, ["debug"]);}
				
				// Does the parents of the input path and rule path match .. meaning we can actually evaluate this wildcard rule against the input path
				if (matchFirstSegmentToPathFirstSegment(ruleSegments, pathSegments)) {

					// A deeper wildcard/globbing exclusion rule must not exclude an ancestor path
					// when the next unmatched rule segment is a named path component.
					//
					// Example:
					//     input path: /SHARED_FOLDERS/SUB_FOLDER_1/CORE
					//     exclusion:  !/SHARED_FOLDERS/SUB_FOLDER_1/CORE/nested/exclude/*
					//
					// The input path ends at CORE and the next rule segment is "nested",
					// not "*" or "**". The exclusion targets a deeper named child path,
					// not the CORE directory itself.
					//
					// Do not apply this guard when the next unmatched rule segment is "*" or "**",
					// as those rules intentionally target the direct or recursive contents below
					// the current input path.
					if (thisIsAnExcludeRule && exclusionRuleTargetsNamedChildBeyondInputPath(ruleSegments, pathSegments)) {
						if (debugLogging) {
							addLogEntry("Evaluation against 'sync_list' rule result: exclusion wildcard|globbing rule targets a deeper named child path; ancestor input path must not be excluded", ["debug"]);
						}
						continue;
					}

					// A child-only exclusion rule must not exclude the container itself when
					// there is an explicit include rule for that same container.
					//
					// Example:
					//     exclusion: !/SHARED_FOLDERS/SUB_FOLDER_2/WIDE_*_15/*
					//     inclusion:  /SHARED_FOLDERS/SUB_FOLDER_2/WIDE_*/
					//     input:      /SHARED_FOLDERS/SUB_FOLDER_2/WIDE_SET_15
					//
					// The exclusion applies to children below WIDE_SET_15, not to the
					// WIDE_SET_15 container itself. This is intentionally guarded by the
					// presence of a same-depth include rule so ordinary deeper exclusions
					// such as !/Projects/Code*/JOBXYZ/Exports/* are not weakened.
					if (thisIsAnExcludeRule && childWildcardExclusionHasSpecificIncludeForCurrentPath(ruleSegments, pathSegments)) {
						if (debugLogging) {
							addLogEntry("Evaluation against 'sync_list' rule result: child-only wildcard exclusion targets contents below an explicitly included container; container input path must not be excluded", ["debug"]);
						}
						continue;
					}
					
					// Is this a globbing rule (**) or just a single wildcard (*) entries
					if (globbingRule) {
						// globbing (**) rule processing
						
						// globbing rules can only realistically apply if there are enough path segments for the globbing rule to actually apply
						// otherwise we get a bad match - see:
						// - https://github.com/abraunegg/onedrive/issues/3122
						// - https://github.com/abraunegg/onedrive/issues/3122#issuecomment-2661556789
						
						auto wildcardDepth = firstWildcardDepth(syncListRuleEntry);
						auto pathCount = count(pathSegments);

						// Are there enough path segments for this globbing rule to apply?
						if (pathCount < wildcardDepth) {
							// there are not enough path segments up to the first wildcard character (*) for this rule to even be applicable
							if (debugLogging) {addLogEntry(" - This sync list globbing rule cannot not be evaluated as the globbing appears beyond the current input path", ["debug"]);}
						} else {
							// There are enough segments in the path and rule to test against this globbing rule
							if (matchPathAgainstRule(path, syncListRuleEntry)) {
								// set the applicable flag
								wildcardRuleMatched = true;
								if (debugLogging) {addLogEntry("Evaluation against 'sync_list' rule result: globbing pattern match using segment matching", ["debug"]);}
							}
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
					

					// If this is an include rule that targets a descendant path, allow the
					// current input path as a traversal container even before the final
					// descendant exists in the evaluation path.
					//
					// Example:
					//     include: /SHARED_FOLDERS/SUB_FOLDER_2/TREE/**/tree.txt
					//     input:   /SHARED_FOLDERS/SUB_FOLDER_2/TREE
					//
					// TREE itself does not directly match tree.txt, but it must be
					// traversed so that A/B/C/tree.txt can be discovered and included.
					if (!thisIsAnExcludeRule && !wildcardRuleMatched && inclusionWildcardRuleCanMatchDescendant(ruleSegments, pathSegments)) {
						wildcardRuleMatched = true;
						if (debugLogging) {
							addLogEntry("Evaluation against 'sync_list' rule result: wildcard|globbing inclusion rule requires traversal of this container path", ["debug"]);
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
							// Do not clear excludeWildcardMatched here.
							// A prior wildcard/globbing exclusion rule must retain precedence over a later wildcard/globbing inclusion rule for the same path.
						}
					} else {
						if (debugLogging) {addLogEntry("Evaluation against 'sync_list' rule result: No match to 'sync_list' wildcard|globbing rule", ["debug"]);}
					}
				} else {
					// log that parental path in input path does not match the parental path in the rule
					if (debugLogging) {addLogEntry("Evaluation against 'sync_list' rule result: No evaluation possible - parental input path does not match 'sync_list' rule", ["debug"]);}
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
		
		// Only force exclusion if an exclusion rule actually matched this path
		if (excludeExactMatch || excludeParentMatched || excludeAnywhereMatched || excludeWildcardMatched) {
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
		
		// Restore wildcard (*) support with '.*' to be compatible with function and to match any characters
		regexCompatiblePath = regexCompatiblePath.replace("\\*", ".*");
		
		// Ensure space matches only literal space, not \s (tabs, etc.)
		regexCompatiblePath = regexCompatiblePath.replace(" ", "\\ ");
		
		// Return the regex compatible path
		return regexCompatiblePath;
	}

	// Create a regex compatible string to match a relevant segment
	bool matchSegment(string ruleSegment, string pathSegment) {
		// Create the required pattern
		auto pattern = regex("^" ~ createRegexCompatiblePath(ruleSegment) ~ "$");
		// Check if there's a match and return result
		return !match(pathSegment, pattern).empty;
	}
	

	// Function to determine if an exclusion wildcard/globbing rule targets a deeper named child path beyond the current input path.
	//
	// This prevents a deeper exclusion such as:
	//     !/SHARED_FOLDERS/SUB_FOLDER_1/CORE/nested/exclude/*
	// from incorrectly excluding the ancestor path:
	//     /SHARED_FOLDERS/SUB_FOLDER_1/CORE
	//
	// This helper is intentionally used only for exclusion wildcard/globbing rules so that
	// existing include traversal behaviour is not altered.
	//
	// The guard is intentionally narrow:
	// - If the input path is not a prefix of the rule, do not guard.
	// - If the rule is not deeper than the input path, do not guard.
	// - If the next unmatched rule segment is "*" or "**", do not guard because
	//   the rule intentionally targets the contents below the input path.
	// - If the next unmatched rule segment is a named segment, guard because the rule
	//   targets a deeper child path and must not exclude the ancestor.
	bool exclusionRuleTargetsNamedChildBeyondInputPath(string[] ruleSegments, string[] pathSegments) {
		// If the rule is not deeper than the input path, there is no deeper named child path to guard
		if (ruleSegments.length <= pathSegments.length) {
			return false;
		}

		// Compare the input path against the equivalent prefix of the rule path
		foreach (index, pathSegment; pathSegments) {
			if (!matchSegment(ruleSegments[index], pathSegment)) {
				return false;
			}
		}

		// The input path is a prefix of the rule. Inspect the next unmatched rule segment.
		string nextRuleSegment = ruleSegments[pathSegments.length];

		// If the next segment is a wildcard/globbing segment, the rule is intentionally targeting
		// contents immediately below the input path, so allow normal exclusion evaluation.
		if ((nextRuleSegment == wildcard) || (nextRuleSegment == globbing)) {
			return false;
		}

		// The next segment is a named child path, so this exclusion rule must not exclude the ancestor.
		return true;
	}

	// Function to determine if an exclusion rule of the form:
	//     /path/to/container/*
	// is being evaluated against the container itself, and that same container
	// is explicitly included by an include rule at the same path depth.
	//
	// This preserves child-only exclusion semantics without weakening broader
	// exclusion precedence. The same-depth include requirement is important:
	// it prevents a broad include such as /Projects/Code* from re-including a
	// deeper excluded container such as /Projects/Code/JOBXYZ/Exports.
	bool childWildcardExclusionHasSpecificIncludeForCurrentPath(string[] ruleSegments, string[] pathSegments) {
		// This helper only applies to direct child wildcard exclusions where the
		// rule is exactly one segment deeper than the current input path.
		if (ruleSegments.length != pathSegments.length + 1) {
			return false;
		}

		// Only direct child wildcard exclusions are handled here. Globbing exclusions
		// are intentionally left to the normal exclusion logic.
		if (ruleSegments[$ - 1] != wildcard) {
			return false;
		}

		// The current input path must match the exclusion rule's container prefix.
		foreach (index, pathSegment; pathSegments) {
			if (!matchSegment(ruleSegments[index], pathSegment)) {
				return false;
			}
		}

		// The same container must be explicitly included at the same path depth.
		foreach (includeRule; syncListIncludePathsOnly) {
			if (includeRule.empty) continue;

			string candidate = includeRule;
			if (candidate.endsWith("/*")) {
				candidate = candidate[0 .. $ - 2];
			}
			if (candidate.length > 1 && candidate[$ - 1] == '/') {
				candidate = candidate[0 .. $ - 1];
			}

			string[] includeSegments = candidate.strip.split("/").filter!(s => !s.empty).array;
			if (includeSegments.length != pathSegments.length) {
				continue;
			}

			bool includeMatchesCurrentPath = true;
			foreach (index, pathSegment; pathSegments) {
				if (!matchSegment(includeSegments[index], pathSegment)) {
					includeMatchesCurrentPath = false;
					break;
				}
			}

			if (includeMatchesCurrentPath) {
				return true;
			}
		}

		return false;
	}

	// Function to determine if an include wildcard/globbing rule can match a
	// descendant of the current input path. This allows directory/container
	// traversal for rules that target deeper file descendants, for example:
	//     /SHARED_FOLDERS/SUB_FOLDER_2/TREE/**/tree.txt
	// when evaluating:
	//     /SHARED_FOLDERS/SUB_FOLDER_2/TREE
	//
	// This must not be used as a broad include for every container below a
	// globbing segment. For example, this rule:
	//     /ZZ_E2E_SYNC_LIST/Programming/Projects/**/src/
	// must include matching src directories only. It must not include sibling
	// containers such as build, .gradle, .next, node_modules or __pycache__
	// merely because they are below Programming/Projects.
	bool inclusionWildcardRuleCanMatchDescendant(string[] ruleSegments, string[] pathSegments) {
		if (pathSegments.empty || ruleSegments.empty) {
			return false;
		}

		// This helper exists to allow traversal for descendant file targets such
		// as **/tree.txt. Directory include rules such as **/src/ are handled by
		// normal segment matching and must not cause unrelated sibling containers
		// to be included. Because sync_list normalisation removes the trailing
		// slash, use a conservative file-target heuristic here.
		string terminalRuleSegment = ruleSegments[$ - 1];
		if (terminalRuleSegment == wildcard || terminalRuleSegment == globbing || !canFind(terminalRuleSegment, ".")) {
			return false;
		}

		size_t ruleIndex = 0;
		size_t pathIndex = 0;

		while (pathIndex < pathSegments.length) {
			if (ruleIndex >= ruleSegments.length) {
				return false;
			}

			if (ruleSegments[ruleIndex] == globbing) {
				// A globbing segment may consume the current path segment only for
				// the conservative descendant-file traversal case guarded above.
				return true;
			}

			if (!matchSegment(ruleSegments[ruleIndex], pathSegments[pathIndex])) {
				return false;
			}

			pathIndex++;
			ruleIndex++;
		}

		// The full input path matched the leading portion of the include rule and
		// the rule still has unmatched segments. Therefore a descendant of the
		// current input path can match this include rule.
		return ruleIndex < ruleSegments.length;
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
	
	// Function to perform an exact match of path segments to rule segments
	bool exactMatchRuleSegmentsToPathSegments(string[] ruleSegments, string[] inputSegments) {
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
	
	// Function to perform a match of path segments to rule segments
	bool matchRuleSegmentsToPathSegments(string[] ruleSegments, string[] inputSegments) {
		if (debugLogging) {addLogEntry("Running matchRuleSegmentsToPathSegments()", ["debug"]);}
		
		// If rule has more segments than input, no match is possible
		if (ruleSegments.length > inputSegments.length) {
			return false;
		}

		// Compare segments up to the length of the rule path
		return equal(ruleSegments, inputSegments[0 .. ruleSegments.length]);
	}
	
	// Function to match the first segment only of the path and rule
	bool matchFirstSegmentToPathFirstSegment(string[] ruleSegments, string[] inputSegments) {
		// Check that both segments are not empty
		if (ruleSegments.length == 0 || inputSegments.length == 0) {
			return false; // Return false if either segment array is empty
		}

		// Compare the first segments only
		return equal(ruleSegments[0], inputSegments[0]);
	}
	
	// Test the path for prefix matching an include sync_list rule
	bool isSyncListPrefixMatch(string inputPath) {
		// Ensure inputPath ends with a '/' if not root, to avoid false positives
		string inputPrefix = inputPath.endsWith("/") ? inputPath : inputPath ~ "/";

		foreach (entry; syncListIncludePathsOnly) {
			string normalisedEntry = entry;
			
			// If rule ends in '/*', treat it as if the '/*' is not there
			if (normalisedEntry.endsWith("/*")) {
				normalisedEntry = normalisedEntry[0 .. $ - 2]; // remove '/*' for this rule comparison
			}

			// Ensure trailing '/' for safe prefix match
			string entryWithSlash = normalisedEntry.endsWith("/") ? normalisedEntry : normalisedEntry ~ "/";

			// Match input as being equal to or under the rule path, or rule path being under the input path
			if (entryWithSlash.startsWith(inputPrefix) || inputPrefix.startsWith(entryWithSlash)) {
				// Debug the exact 'sync_list' inclusion rule this matched
				if (debugLogging) {
					addLogEntry("Parental path matched 'sync_list' Inclusion Rule: " ~ to!string(entry), ["debug"]);
				}
				return true;
			}
		}

		return false;
	}
	
	// Do any 'anywhere' sync_list' rules exist for inclusion?
	bool syncListAnywhereInclusionRulesExist() {
		// Count the entries in syncListAnywherePathOnly
		auto anywhereRuleCount = count(syncListAnywherePathOnly);
		
		if (anywhereRuleCount > 0) {
			return true;
		} else {
			return false;
		}
	}
	
	// Validate that 'sync_list' *include* rules are not rendered non-viable by 'skip_dir' entries.
	// If an include rule would be excluded by 'skip_dir' evaluation, it is "shadowed" by that entry.
	bool validateSyncListNotShadowedBySkipDir() {
		// No sync_list include rules loaded => nothing to validate
		if (syncListIncludePathsOnly is null || syncListIncludePathsOnly.empty) return true;

		// No skip_dir configured => nothing to validate
		if (appConfig.getValueString("skip_dir").empty) return true;

		string[] shadowedRules;

		foreach (rule; syncListIncludePathsOnly) {
			// syncListIncludePathsOnly should only contain include rules, but be defensive.
			if (rule.empty) continue;
			if (rule[0] == '!' || rule[0] == '-') continue;

			// Normalise the rule to match how skip_dir rules are evaluated at runtime.
			// skip_dir entries are relative to sync_dir. sync_list entries may be rooted (start with '/').
			string candidate = rule;

			// Normalise leading "./" (defensive)
			if (candidate.length >= 2 && candidate[0 .. 2] == "./") {
				candidate = candidate[2 .. $];
			}

			// Normalise sync_list rooted includes: "/Documents" -> "Documents"
			if (candidate.length >= 1 && candidate[0] == '/') {
				// Remove only the first '/', sync_list rules are single-rooted relative to sync_dir
				candidate = candidate[1 .. $];
			}

			if (candidate.empty) continue;

			// Use the *actual* runtime skip_dir evaluation logic (strict/non-strict)
			// so the check matches real behaviour.
			bool shadowed = false;

			// Test as-is
			if (isDirNameExcluded(candidate)) {
				shadowed = true;
			} else {
				// Also test with a trailing slash where appropriate, so:
				//   skip_dir = "Documents/" correctly shadows sync_list = "/Documents"
				// (Users often represent a directory root either way.)
				if (candidate[$ - 1] != '/') {
					if (isDirNameExcluded(candidate ~ "/")) {
						shadowed = true;
					}
				}
			}

			if (shadowed) {
				shadowedRules ~= rule;
			}
		}

		if (!shadowedRules.empty) {
			addLogEntry();
			addLogEntry("ERROR: Invalid Client Side Filtering configuration detected.", ["info", "notify"]);
			addLogEntry("       One or more 'sync_list' inclusion rules are shadowed by 'skip_dir' and will never be viable.", ["info", "notify"]);
			foreach (r; shadowedRules) {
				addLogEntry("       Shadowed 'sync_list' rule: " ~ r, ["info", "notify"]);
			}
			addLogEntry("       Fix: remove or narrow the conflicting 'skip_dir' entry/entries, or adjust your 'sync_list' rules.", ["info", "notify"]);
			addLogEntry("       See the 'skip_dir' documentation for correct usage and examples.", ["info", "notify"]);
			addLogEntry();
			return false;
		}

		return true;
	}
	
	// Validate that 'sync_list' *include* rules are not rendered non-viable by 'skip_file' entries.
	// If an include rule would be excluded by 'skip_file' evaluation, it is "shadowed" by that entry.
	bool validateSyncListNotShadowedBySkipFile() {
		// No sync_list include rules loaded => nothing to validate
		if (syncListIncludePathsOnly is null || syncListIncludePathsOnly.empty) return true;

		// No skip_file configured => nothing to validate
		if (appConfig.getValueString("skip_file").empty) return true;

		string[] shadowedRules;

		foreach (rule; syncListIncludePathsOnly) {
			// Defensive: ignore empty or explicitly negative rules
			if (rule.empty) continue;
			if (rule[0] == '!' || rule[0] == '-') continue;

			// Only validate file-intent rules:
			// - If it ends with '/', treat as a directory include and do not apply skip_file shadow validation.
			//   (Users commonly include folders; skip_file patterns like '*.tmp' should not invalidate that.)
			if (rule.length > 1 && rule[$ - 1] == '/') continue;

			// Normalise the rule to match how skip_file rules are evaluated at runtime.
			// skip_file entries are relative to sync_dir. sync_list entries may be rooted (start with '/').
			string candidate = rule;

			// Normalise leading "./" (defensive)
			if (candidate.length >= 2 && candidate[0 .. 2] == "./") {
				candidate = candidate[2 .. $];
			}

			// Normalise sync_list rooted includes: "/Documents/file.txt" -> "Documents/file.txt"
			if (candidate.length >= 1 && candidate[0] == '/') {
				candidate = candidate[1 .. $];
			}

			if (candidate.empty) continue;

			// Use the *actual* runtime skip_file evaluation logic so this check matches real behaviour.
			if (isFileNameExcluded(candidate)) {
				shadowedRules ~= rule;
			}
		}

		if (!shadowedRules.empty) {
			addLogEntry();
			addLogEntry("ERROR: Invalid Client Side Filtering configuration detected.", ["info", "notify"]);
			addLogEntry("       One or more 'sync_list' inclusion rules are shadowed by 'skip_file' and will never be viable.", ["info", "notify"]);
			foreach (r; shadowedRules) {
				addLogEntry("       Shadowed 'sync_list' rule: " ~ r, ["info", "notify"]);
			}
			addLogEntry("       Fix: remove or narrow the conflicting 'skip_file' entry/entries, or adjust your 'sync_list' rules.", ["info", "notify"]);
			addLogEntry("       See the 'skip_file' documentation for correct usage and examples.", ["info", "notify"]);
			addLogEntry();
			return false;
		}

		return true;
	}
}