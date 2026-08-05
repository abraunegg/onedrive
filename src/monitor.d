// What is this module called?
module monitor;

// What does this module require to function?
import core.stdc.errno;
import core.stdc.stdlib;
import core.sys.linux.sys.inotify;
import core.sys.posix.poll;
import core.sys.posix.unistd;
import core.sys.posix.sys.select;
import core.thread;
import core.time;
import std.algorithm;
import std.concurrency;
import std.exception;
import std.file;
import std.path;
import std.process;
import std.regex;
import std.stdio;
import std.string;
import std.conv;
import core.sync.mutex;

// What other modules that we have created do we need to import?
import config;
import util;
import log;
import clientSideFiltering;

// Relevant inotify events. All currently supported/tested platforms provide
// these markers through their inotify implementation.
private immutable uint32_t mask = IN_CLOSE_WRITE | IN_CREATE | IN_DELETE | IN_MOVE | IN_IGNORED | IN_Q_OVERFLOW;

// FreeBSD and OpenBSD inotify compatibility layers may emit IN_CREATE without
// a later IN_CLOSE_WRITE when a newly written file is closed. Treat that file
// creation as the actionable change on those platforms. Linux continues to use
// IN_CLOSE_WRITE as the write-completion signal so partially written files are
// not processed prematurely.
version (FreeBSD) {
	private immutable bool triggerFileCreateAsChanged = true;
} else version (OpenBSD) {
	private immutable bool triggerFileCreateAsChanged = true;
} else {
	private immutable bool triggerFileCreateAsChanged = false;
}

class MonitorException: ErrnoException {
	@safe this(string msg, string file = __FILE__, size_t line = __LINE__) {
		super(msg, file, line);
	}
}

class MonitorBackgroundWorker {
	// inotify file descriptor
	int fd;
	Pipe p;
	bool isAlive;
	bool workerExited;

	this() {
		isAlive = true;
		workerExited = false;
		p = pipe();
	}

	shared void initialise() {
		workerExited = false;
		fd = inotify_init();
		if (fd < 0) throw new MonitorException("inotify_init failed");
	}

	// Add this path to be monitored
	shared int addInotifyWatch(string pathname) {
		int wd = inotify_add_watch(fd, toStringz(pathname), mask);
		if (wd < 0) {
			if (errno() == ENOSPC) {
				// Predefined Versions
				// https://dlang.org/spec/version.html#predefined-versions
				version (linux) {
					// Read max inotify watches from procfs on Linux
					ulong maxInotifyWatches = to!int(strip(readText("/proc/sys/fs/inotify/max_user_watches")));
					addLogEntry("The user limit on the total number of inotify watches has been reached.");
					addLogEntry("Your current limit of inotify watches is: " ~ to!string(maxInotifyWatches));
					addLogEntry("It is recommended that you change the max number of inotify watches to at least double your existing value.");
					addLogEntry("To change the current max number of watches to " ~ to!string((maxInotifyWatches * 2)) ~ " run:");
					addLogEntry("EXAMPLE: sudo sysctl fs.inotify.max_user_watches=" ~ to!string((maxInotifyWatches * 2)));
				} else {
					// some other platform
					addLogEntry("The user limit on the total number of inotify watches has been reached.");
					addLogEntry("Please seek support from your distribution on how to increase the max number of inotify watches to at least double your existing value.");
				}
			}
			if (errno() == 13) {
				if (verboseLogging) {addLogEntry("WARNING: inotify_add_watch failed - permission denied: " ~ pathname, ["verbose"]);}
			}
			// Flag any other errors
			addLogEntry("ERROR: inotify_add_watch failed: " ~ pathname);
			return wd;
		}
		
		// Add path to inotify watch - required regardless if a '.folder' or 'folder'
		if (debugLogging) {addLogEntry("inotify_add_watch successfully added for: " ~ pathname, ["debug"]);}
		
		// Do we log that we are monitoring this directory?
		if (isDir(pathname)) {
			// Log that this is directory is being monitored
			if (verboseLogging) {addLogEntry("Monitoring directory: " ~ pathname, ["verbose"]);}
		}
		return wd;
	}

	shared int removeInotifyWatch(int wd) {
		assert(fd > 0, "File descriptor 'fd' is invalid.");
		assert(wd > 0, "Watch descriptor 'wd' is invalid.");
		// Debug logging of the inotify watch being removed
		if (debugLogging) {addLogEntry("Attempting to remove inotify watch: fd=" ~ fd.to!string ~ ", wd=" ~ wd.to!string, ["debug"]);}
		// return the value of performing the action
		return inotify_rm_watch(fd, wd);
	}

	shared void watch(Tid callerTid) {
		// On failure, send -1 to caller
		int res;

		// Mark the worker as exited regardless of which shutdown/error path is used.
		scope(exit) {
			workerExited = true;
		}

		// Wait for the caller to be ready.
		receiveOnly!bool();

		while (isAlive) {
			fd_set fds;
			FD_ZERO(&fds);
			FD_SET(fd, &fds);

			// Listen for shutdown or interrupt wake-ups from the control pipe.
			int controlPipeFd = (cast()p).readEnd.fileno;
			FD_SET(controlPipeFd, &fds);

			// select() only needs to scan up to the highest descriptor plus one.
			int maxFd = max(fd, controlPipeFd) + 1;
			res = select(maxFd, &fds, null, null, null);

			if (res == -1) {
				if (errno() == EINTR) {
					// Interrupted by a signal; re-arm the wait.
					continue;
				}

				// Error occurred, tell the caller to terminate.
				callerTid.send(-1);
				break;
			}

			// Control-pipe readiness is not filesystem activity. It is used to
			// unblock select() during interrupt or shutdown, so drain it without
			// reporting a local-monitor wake-up to main.d.
			if (FD_ISSET(controlPipeFd, &fds)) {
				try {
					(cast()p).readEnd.readln();
				} catch (Exception) {
					// Ignore control-pipe drain errors during shutdown.
				}

				if (!isAlive) break;
				continue;
			}

			// Only inotify descriptor readiness should wake the caller for local
			// filesystem processing.
			if (FD_ISSET(fd, &fds)) {
				callerTid.send(1);

				// Wait for the caller to acknowledge whether monitoring should continue.
				if (isAlive) {
					isAlive = receiveOnly!bool();
				}

				continue;
			}
		}
	}

	shared bool hasExited() {
		return workerExited;
	}

	shared void interrupt() {
		isAlive = false;
		try {
			(cast()p).writeEnd.writeln("done");
			(cast()p).writeEnd.flush();
		} catch (Exception) {
			// The control pipe may already be closed during shutdown.
		}
	}

	shared void shutdown() {
		isAlive = false;
		if (fd > 0) {
			close(fd);
			fd = 0;
		}

		try {
			(cast()p).close();
		} catch (Exception) {
			// The control pipe may already be closed or partially initialised.
		}
	}
}

void startMonitorJob(shared(MonitorBackgroundWorker) worker, Tid callerTid) {
	try {
		worker.watch(callerTid);
	} catch (OwnerTerminated error) {
		// caller is terminated
		worker.shutdown();
	}
}

enum LocalChangeType {
	moved,
	deleted,
	changed,
	createDir
}

struct LocalChange {
	LocalChangeType type;
	bool skipped;
	string src;
	string dst;
}

private string normaliseMonitorPath(string path) {
	if (path.empty || path == ".") return path;

	// Monitor paths are already relative to the configured sync_dir. Preserve
	// that hot path without normalising or allocating another string.
	if (!isAbsolute(path)) {
		return startsWith(path, "./") ? path : "./" ~ path;
	}

	// A small number of SyncEngine paths (for example Business Shared Files)
	// are absolute. Convert only those to the representation used by Monitor.
	string normalised = buildNormalizedPath(relativePath(path, getcwd()));
	if (normalised == ".") return normalised;
	return startsWith(normalised, "./") ? normalised : "./" ~ normalised;
}

private bool isSameOrChildPath(string parent, string candidate) {
	string normalisedParent = normaliseMonitorPath(parent);
	string normalisedCandidate = normaliseMonitorPath(candidate);

	return (normalisedCandidate == normalisedParent) || startsWith(normalisedCandidate, normalisedParent ~ "/");
}

// Watch descriptors are stored with a trailing slash, while paths generated
// from events may be relative to the root watch ("./path") and may not have a
// trailing slash. Convert both representations to one canonical form before
// comparing a watch tree root with its descendants.
private string normaliseWatchPath(string path) {
	string normalisedPath = normaliseMonitorPath(path);

	while ((normalisedPath.length > 1) && normalisedPath.endsWith("/")) {
		normalisedPath = normalisedPath[0 .. $ - 1];
	}

	return normalisedPath;
}

private bool isSameOrChildWatchPath(string parent, string candidate) {
	string normalisedParent = normaliseWatchPath(parent);
	string normalisedCandidate = normaliseWatchPath(candidate);

	return (normalisedCandidate == normalisedParent) || startsWith(normalisedCandidate, normalisedParent ~ "/");
}

private string rebaseWatchPath(string fromRoot, string toRoot, string candidate) {
	string normalisedFromRoot = normaliseWatchPath(fromRoot);
	string normalisedToRoot = normaliseWatchPath(toRoot);
	string normalisedCandidate = normaliseWatchPath(candidate);

	if (normalisedCandidate == normalisedFromRoot) {
		return normalisedToRoot;
	}

	return normalisedToRoot ~ normalisedCandidate[normalisedFromRoot.length .. $];
}

private string rebasePath(string fromRoot, string toRoot, string candidate) {
	string normalisedFromRoot = normaliseMonitorPath(fromRoot);
	string normalisedCandidate = normaliseMonitorPath(candidate);
	string normalisedToRoot = normaliseMonitorPath(toRoot);

	if (normalisedCandidate == normalisedFromRoot) {
		return normalisedToRoot;
	}

	return normalisedToRoot ~ normalisedCandidate[normalisedFromRoot.length .. $];
}

// Coalesces raw filesystem observations into a pending local-change batch.
// It deliberately does not execute any synchronisation operation.
struct LocalChangeAccumulator {
	LocalChange[] changes;
	size_t[string] srcMap;

	void append(LocalChangeType type, string src, string dst = null) {
		src = normaliseMonitorPath(src);
		if (!dst.empty) dst = normaliseMonitorPath(dst);

		size_t[] pendingTargets;
		switch (type) {
			case LocalChangeType.changed:
				if (src in srcMap && changes[srcMap[src]].type == LocalChangeType.changed) {
					// Skip duplicate change observations.
					return;
				}
				break;
			case LocalChangeType.createDir:
				break;
			case LocalChangeType.deleted:
				foreach (change; changes) {
					if (change.skipped) continue;
					if (change.type == LocalChangeType.moved && isSameOrChildPath(change.src, src)) {
						// A delete beneath a pending move is an inotify artefact of the move.
						return;
					}
				}

				if (src in srcMap) {
					size_t pendingTarget = srcMap[src];
					switch (changes[pendingTarget].type) {
						case LocalChangeType.changed:
						case LocalChangeType.createDir:
							changes[pendingTarget].skipped = true;
							srcMap.remove(src);
							break;
						default:
							break;
					}
				}

				// If a parent directory delete arrives after child deletes, collapse
				// those child observations into the parent delete. Linux commonly
				// reports recursive deletion as child deletes followed by the parent.
				// Retaining only the parent preserves the intended recursive operation.
				foreach (ref change; changes) {
					if (change.skipped) continue;
					if (
						change.type == LocalChangeType.deleted &&
						isSameOrChildPath(src, change.src) &&
						normaliseMonitorPath(src) != normaliseMonitorPath(change.src)
					) {
						change.skipped = true;
						srcMap.remove(change.src);
					}
				}
				break;
			case LocalChangeType.moved:
				for (size_t i = 0; i < changes.length; i++) {
					if (changes[i].skipped) continue;
					if (changes[i].src in srcMap) {
						switch (changes[i].type) {
							case LocalChangeType.changed:
							case LocalChangeType.createDir:
								if (isSameOrChildPath(src, changes[i].src)) {
									// Hold operations requiring local reads until after the move.
									pendingTargets ~= i;
									changes[i].skipped = true;
									srcMap.remove(changes[i].src);
									changes[i].src = rebasePath(src, dst, changes[i].src);
								}
								break;
							case LocalChangeType.deleted:
								if (isSameOrChildPath(src, changes[i].src)) {
									// Suppress child deletes caused by the parent move.
									changes[i].skipped = true;
									srcMap.remove(changes[i].src);
								}
								break;
							default:
								break;
						}
					}
				}
				break;
			default:
				break;
		}

		changes ~= LocalChange(type, false, src, dst);
		srcMap[src] = changes.length - 1;

		foreach (pendingTarget; pendingTargets) {
			changes ~= changes[pendingTarget];
			changes[$ - 1].skipped = false;
			srcMap[changes[$ - 1].src] = changes.length - 1;
		}
	}

	bool hasPendingDeparture(string path) {
		string target = normaliseMonitorPath(path);
		foreach (change; changes) {
			if (change.skipped) continue;
			if ((change.type == LocalChangeType.moved || change.type == LocalChangeType.deleted) &&
				isSameOrChildPath(change.src, target)) {
				return true;
			}
		}
		return false;
	}

	LocalChange[] take() {
		LocalChange[] result;
		foreach (change; changes) {
			if (!change.skipped) result ~= change;
		}
		changes = [];
		srcMap = null;
		return result;
	}
}

final class Monitor {
	// Class variables
	ApplicationConfig appConfig;
	ClientSideFiltering selectiveSync;

	// Are we verbose in logging output
	bool verbose = false;
	// skip symbolic links
	bool skip_symlinks = false;
	// check for .nosync if enabled
	bool check_nosync = false;
	// check if initialised
	bool initialised = false;
	// Worker Tid
	Tid workerTid;
	
	// Configure Private Class Variables
	shared(MonitorBackgroundWorker) worker;
	// map every inotify watch descriptor to its normalised directory path
	private string[int] wdToDirName;
	// reverse map used to keep watch registration idempotent
	private int[string] dirNameToWd;
	// map the inotify cookies of move_from events to their path
	private string[int] cookieToPath;
	// buffer to receive the inotify events
	private void[] buffer;
	
	// Mutex to support thread safe access of inotify watch descriptors
	private Mutex inotifyMutex;

	// List of paths that were moved, not deleted
	private bool[string] movedNotDeleted;

	// Pending local observations. These are captured by Monitor and reconciled by main.d.
	private LocalChangeAccumulator pendingChanges;

	// Exact filesystem echoes expected from online-to-local operations performed by SyncEngine.
	// All of this state is owned by the main thread; the background worker only wakes the main thread.
	//
	// Counts/queues are deliberate. Parallel downloads can apply the same path more
	// than once before the next capture. A set-like associative array collapses those
	// registrations and allows the second client-generated move to escape as local
	// intent. Preserve one consumable expectation per filesystem operation.
	private size_t[string] expectedDirectoryCreates;
	private string[][string] expectedMoveDestinationsBySource;
	private string[][string] expectedMoveSourcesByDestination;
	private size_t[string] expectedFileArrivals;
	private bool[string] expectedRemovalRoots;
	private bool[string] observedRemovalRoots;
	
	// Configure the class variable to consume the application configuration including selective sync
	this(ApplicationConfig appConfig, ClientSideFiltering selectiveSync) {
		this.appConfig = appConfig;
		this.selectiveSync = selectiveSync;
		inotifyMutex = new Mutex(); // Define a Mutex for thread-safe access
	}
	
	// The destructor should only clean up resources owned directly by this instance.
	// shutdown() is responsible for stopping the worker before this object is destroyed.
	~this() {
		if (worker !is null) {
			try {
				worker.shutdown();
			} catch (Exception) {
				// Destructors must not throw during process teardown.
			}
			worker = null;
		}
	}
	
	// Initialise the monitor class
	void initialise() {
		// Configure the variables
		skip_symlinks = appConfig.getValueBool("skip_symlinks");
		check_nosync = appConfig.getValueBool("check_nosync");
		if (appConfig.getValueLong("verbose") > 0) {
			verbose = true;
		}
		
		if (!buffer) buffer = new void[4096];
		worker = cast(shared) new MonitorBackgroundWorker;
		worker.initialise();

		// from which point do we start watching for changes?
		string monitorPath;
		if (appConfig.getValueString("single_directory") != ""){
			// single directory in use, monitor only this path
			monitorPath = "./" ~ appConfig.getValueString("single_directory");
		} else {
			// default 
			monitorPath = ".";
		}
		addRecursive(monitorPath);
		
		// Start monitoring
		workerTid = spawn(&startMonitorJob, worker, thisTid);
		initialised = true;
	}

	// Communication with worker
	void send(bool isAlive) {
		workerTid.send(isAlive);
	}

	// Shutdown the monitor class
	void shutdown() {
		if (!initialised) {
			return;
		}
		initialised = false;

		// Interrupt the worker so select() wakes if it is waiting on inotify.
		if (worker !is null) {
			worker.interrupt();
		}

		// Remove all inotify watch descriptors before closing the inotify descriptor.
		removeAll();

		// If the worker has already reported an inotify wake-up, it may be waiting
		// for main.d to acknowledge whether monitoring should continue. Unblock that
		// receive without assuming the worker is still alive.
		try {
			send(false);
		} catch (Exception) {
			// The worker may already have exited during shutdown.
		}

		if (worker !is null) {
			worker.interrupt();

			// Do not allow Monitor destruction to race with the worker thread still
			// running inside MonitorBackgroundWorker.watch().
			foreach (_; 0 .. 100) {
				if (worker.hasExited()) {
					break;
				}
				Thread.sleep(dur!"msecs"(20));
			}

			worker.shutdown();
		}

		inotifyMutex.lock();
		try {
			wdToDirName = null;
			dirNameToWd = null;
		} finally {
			inotifyMutex.unlock();
		}
	}

	private string watchPathToEventPrefix(string watchPath) {
		return (watchPath == ".") ? "" : watchPath ~ "/";
	}

	private bool isWatchRegistered(string dirname) {
		string key = normaliseWatchPath(dirname);

		inotifyMutex.lock();
		try {
			return (key in dirNameToWd) !is null;
		} finally {
			inotifyMutex.unlock();
		}
	}

	private void registerWatchDescriptor(int wd, string dirname) {
		string key = normaliseWatchPath(dirname);

		inotifyMutex.lock();
		try {
			// If this watch descriptor was already associated with another path,
			// remove the old reverse entry before recording the new canonical path.
			auto previousPath = wd in wdToDirName;
			if (previousPath !is null) {
				dirNameToWd.remove(*previousPath);
			}

			// If the directory path was already associated with another descriptor,
			// drop that stale descriptor mapping. The reverse map is the source of
			// truth for idempotent path registration.
			auto previousWd = key in dirNameToWd;
			if ((previousWd !is null) && (*previousWd != wd)) {
				wdToDirName.remove(*previousWd);
			}

			wdToDirName[wd] = key;
			dirNameToWd[key] = wd;
		} finally {
			inotifyMutex.unlock();
		}
	}

	private bool unregisterWatchDescriptor(int wd, out string dirname) {
		dirname = null;

		inotifyMutex.lock();
		try {
			auto existingPath = wd in wdToDirName;
			if (existingPath is null) return false;

			dirname = *existingPath;
			wdToDirName.remove(wd);

			auto existingWd = dirname in dirNameToWd;
			if ((existingWd !is null) && (*existingWd == wd)) {
				dirNameToWd.remove(dirname);
			}

			return true;
		} finally {
			inotifyMutex.unlock();
		}
	}

	// Recursively add this path to be monitored
	private void addRecursive(string dirname) {
		// Set this function name
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		
		// skip non existing/disappeared items
		if (!exists(dirname)) {
			if (verboseLogging) {addLogEntry("Not adding non-existing/disappeared directory: " ~ dirname, ["verbose"]);}
			return;
		}
		
		// Issue #3404: If the file is a very short lived file, and exists when the above test is done, but then is removed shortly thereafter, we need to catch this as a filesystem exception
		try {
			// Skip the monitoring of any user filtered items
			if (dirname != ".") {
				// Is the directory name a match to a skip_dir entry?
				// The path that needs to be checked needs to include the '/'
				// This due to if the user has specified in skip_dir an exclusive path: '/path' - that is what must be matched
				if (isDir(dirname)) {
					if (selectiveSync.isDirNameExcluded(dirname.strip('.'))) {
						// dont add a watch for this item
						if (debugLogging) {addLogEntry("Skipping monitoring due to skip_dir match: " ~ dirname, ["debug"]);}
						return;
					}
				}
				if (isFile(dirname)) {
					// Is the filename a match to a skip_file entry?
					// The path that needs to be checked needs to include the '/'
					// This due to if the user has specified in skip_file an exclusive path: '/path/file' - that is what must be matched
					if (selectiveSync.isFileNameExcluded(dirname.strip('.'))) {
						// dont add a watch for this item
						if (debugLogging) {addLogEntry("Skipping monitoring due to skip_file match: " ~ dirname, ["debug"]);}
						return;
					}
				}
				// Is the path excluded by sync_list?
				if (selectiveSync.isPathExcludedViaSyncList(buildNormalizedPath(dirname))) {
					// dont add a watch for this item
					if (debugLogging) {addLogEntry("Skipping monitoring parent path due to sync_list exclusion: " ~ dirname, ["debug"]);}
					
					// However before we return, we need to test this path tree as a branch on this tree may be included by an anywhere exclusion rule. Do 'anywhere' inclusion rules exist?
					if (isDir(dirname)) {
						// Do any 'sync_list' anywhere inclusion rules exist?
						if (selectiveSync.syncListAnywhereInclusionRulesExist()) {
							// Yes ..
							if (debugLogging) {addLogEntry("Bypassing 'sync_list' exclusion to test if children should be monitored due to 'sync_list' anywhere rule existence", ["debug"]);}
							// Traverse this directory
							traverseDirectory(dirname);
						}
					}
					
					// For the original path, we return, no inotify watch was added
					return;
				}
			}
			
			// skip symlinks if configured
			if (isSymlink(dirname)) {
				// if config says so we skip all symlinked items
				if (skip_symlinks) {
					// dont add a watch for this directory
					return;
				}
			}
			
			// Do we need to check for .nosync? Only if check_nosync is true
			if (check_nosync) {
				if (exists(buildNormalizedPath(dirname) ~ "/.nosync")) {
					if (verboseLogging) {addLogEntry("Skipping watching path - .nosync found & --check-for-nosync enabled: " ~ buildNormalizedPath(dirname), ["verbose"]);}
					return;
				}
			}

			if (isDir(dirname)) {
				// This is a directory			
				// is the path excluded if skip_dotfiles configured and path is a .folder?
				if ((selectiveSync.getSkipDotfiles()) && (isDotFile(dirname))) {
					// dont add a watch for this directory
					return;
				}
			}

			// Only directories need inotify watches. File changes are reported by
			// the watch on the parent directory. Avoid file-level watches because
			// they cannot be maintained safely under rapid create/delete churn.
			if (!isDir(dirname)) {
				return;
			}

			// Avoid duplicate watch descriptors for the same directory when the
			// same path is seen as ./path, path, or path/.
			if (isWatchRegistered(dirname)) {
				if (debugLogging) {addLogEntry("Skipping duplicate inotify watch registration for: " ~ dirname, ["debug"]);}
				return;
			}
			
			// passed all potential exclusions
			// add inotify watch for this directory
			if (debugLogging) {addLogEntry("Calling worker.addInotifyWatch() for this dirname: " ~ dirname, ["debug"]);}
			int wd = worker.addInotifyWatch(dirname);
			if (wd > 0) {
				registerWatchDescriptor(wd, dirname);
			}
			
			// recursively add child directories
			traverseDirectory(dirname);
		// Catch any FileException error which is generated
		} catch (std.file.FileException e) {
			// Standard filesystem error
			displayFileSystemErrorMessage(e.msg, thisFunctionName, dirname);
			return;
		}
	}
	
	// Traverse directory to test if this should have an inotify watch added
	private void traverseDirectory(string dirname) {
		// Set this function name
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
	
		// Current path for error logging
		string currentPath;
		
		// Try and get all the directory entities for this path
		try {
			auto pathList = dirEntries(dirname, SpanMode.shallow, false);
			foreach(DirEntry entry; pathList) {
				currentPath = entry.name;
				if (entry.isDir) {
					if (debugLogging) {addLogEntry("Calling addRecursive() for this directory: " ~ entry.name, ["debug"]);}
					addRecursive(entry.name);
				}
			}
		// Catch any FileException error which is generated
		} catch (std.file.FileException e) {
			// Standard filesystem error
			displayFileSystemErrorMessage(e.msg, thisFunctionName, currentPath);
			return;
		} catch (Exception e) {
			// Issue #1154 handling
			// Need to check for: Failed to stat file in error message
			if (canFind(e.msg, "Failed to stat file")) {
				// File system access issue
				addLogEntry("ERROR: The local file system returned an error with the following message:");
				addLogEntry("  Error Message: " ~ e.msg);
				addLogEntry("ACCESS ERROR: Please check your UID and GID access to this file, as the permissions on this file is preventing this application to read it");
				addLogEntry("\nFATAL: Forcing exiting application to avoid deleting data due to local file system access issues\n");
				// Must force exit here, allow logging to be done
				forceExit();
			} else {
				// some other error
				displayFileSystemErrorMessage(e.msg, thisFunctionName, currentPath);
				return;
			}
		}
	}

	// Remove a watch descriptor
	private void removeAll() {
		string[int] copy;

		inotifyMutex.lock();
		try {
			copy = wdToDirName.dup; // Make a thread-safe copy
		} finally {
			inotifyMutex.unlock();
		}

		// Loop through the watch descriptors and remove. During shutdown or high churn,
		// inotify may already have invalidated a watch and emitted IN_IGNORED. Treat
		// those already-removed watches as cleanup success so shutdown cannot be
		// interrupted by stale watch descriptors.
		foreach (wd, path; copy) {
			// removeAll() is used during full monitor teardown / shutdown. In that
			// scenario it is useful to keep the existing verbose teardown logging.
			remove(wd, true);
		}
	}

	// Remove a watch descriptor.
	private void remove(int wd, bool verboseRemovalLog = false) {
		string dirname;
		int ret;
		int savedErrno;

		inotifyMutex.lock();
		try {
			auto existingPath = wd in wdToDirName;
			if (existingPath is null) {
				if (debugLogging) {
					addLogEntry(
						"inotify watch descriptor already removed from internal map: wd=" ~ wd.to!string,
						["debug"]
					);
				}
				return;
			}
			dirname = *existingPath;
		} finally {
			inotifyMutex.unlock();
		}

		// Do not hold the bookkeeping mutex across the kernel call.
		ret = worker.removeInotifyWatch(wd);
		savedErrno = (ret < 0) ? errno() : 0;

		if (ret < 0) {
			// EINVAL indicates that the watch descriptor is no longer valid. This can
			// occur legitimately if the watched directory was deleted/moved or the
			// kernel already removed the watch before explicit cleanup. Remove our
			// bookkeeping entry and continue.
			if (savedErrno == EINVAL) {
				if (debugLogging) {
					addLogEntry(
						"Ignoring already-invalid inotify watch during removal: wd=" ~ wd.to!string ~ ", path=" ~ dirname,
						["debug"]
					);
				}
			} else {
				throw new MonitorException("inotify_rm_watch failed");
			}
		}

		string removedPath;
		unregisterWatchDescriptor(wd, removedPath);

		// Runtime directory delete/move cleanup can remove many watches at once.
		// Keep that normal runtime cleanup out of verbose output, but retain it at
		// debug level. Full teardown / shutdown passes verboseRemovalLog=true.
		if (verboseRemovalLog && verboseLogging) {
			addLogEntry("Stopped monitoring directory (inotify watch removed): " ~ dirname, ["verbose"]);
		} else if (debugLogging) {
			addLogEntry("Stopped monitoring directory (inotify watch removed): " ~ dirname, ["debug"]);
		}
	}

	// Remove the watch descriptors associated with the given path and all child paths.
	private void remove(const(char)[] path) {
		removeWatchTree(path.idup);
	}

	private void removeWatchTree(string path) {
		int[] matchingWds;
		string key = normaliseWatchPath(path);

		inotifyMutex.lock();
		try {
			foreach (wd, dirname; wdToDirName) {
				if (isSameOrChildWatchPath(key, dirname)) {
					matchingWds ~= wd;
				}
			}
		} finally {
			inotifyMutex.unlock();
		}

		foreach (wd; matchingWds) {
			// Normal runtime recursive cleanup should not produce verbose output for
			// every child watch descriptor. Individual removals remain visible at
			// debug level through remove().
			remove(wd, false);
		}

		if ((matchingWds.length > 0) && debugLogging) {
			addLogEntry(
				"Removed " ~ matchingWds.length.to!string ~
				" inotify watch descriptor(s) for directory tree: " ~ key,
				["debug"]
			);
		}
	}

	// A directory moved within the monitored tree retains its kernel watch
	// descriptors. Rebase the stored paths instead of adding duplicate watches
	// for the destination hierarchy.
	private void rebaseWatchTree(string fromRoot, string toRoot) {
		string oldRoot = normaliseWatchPath(fromRoot);
		string newRoot = normaliseWatchPath(toRoot);
		string[int] copy;
		uint rebasedCount = 0;

		inotifyMutex.lock();
		try {
			copy = wdToDirName.dup;

			foreach (wd, dirname; copy) {
				if (!isSameOrChildWatchPath(oldRoot, dirname)) continue;

				string rebasedPath = rebaseWatchPath(oldRoot, newRoot, dirname);

				auto existingWd = rebasedPath in dirNameToWd;
				if ((existingWd !is null) && (*existingWd != wd)) {
					// A conflicting reverse entry should not normally exist after
					// idempotent registration. Prefer the descriptor belonging to
					// the subtree currently being rebased and discard stale map state.
					wdToDirName.remove(*existingWd);
				}

				dirNameToWd.remove(dirname);
				wdToDirName[wd] = rebasedPath;
				dirNameToWd[rebasedPath] = wd;
				rebasedCount++;
			}
		} finally {
			inotifyMutex.unlock();
		}

		if ((rebasedCount > 0) && debugLogging) {
			addLogEntry(
				"Rebased " ~ rebasedCount.to!string ~
				" inotify watch descriptor(s) from " ~ oldRoot ~
				" to " ~ newRoot,
				["debug"]
			);
		}
	}

	// Return the file path from an inotify event
	private bool getPath(const(inotify_event)* event, out string path) {
		path = null;

		inotifyMutex.lock();
		try {
			auto dirname = event.wd in wdToDirName;
			if (dirname is null) {
				// Under heavy churn or shutdown, inotify can still deliver queued
				// events for a watch descriptor that has already been removed from
				// the internal map. Treat those as stale events rather than allowing
				// associative-array indexing to raise a RangeError.
				if (debugLogging) {addLogEntry("Ignoring stale inotify event for removed watch descriptor: wd=" ~ event.wd.to!string ~ ", mask=" ~ event.mask.to!string, ["debug"]);}
				return false;
			}

			path = watchPathToEventPrefix(*dirname);
		} finally {
			inotifyMutex.unlock();
		}

		if (event.len > 0) path ~= fromStringz(event.name.ptr);
		if (debugLogging) {addLogEntry("inotify path event for: " ~ path, ["debug"]);}
		return true;
	}

	private void incrementExpectedCount(ref size_t[string] counts, string key) {
		auto currentCount = key in counts;
		if (currentCount) {
			(*currentCount)++;
		} else {
			counts[key] = 1;
		}
	}

	private bool consumeExpectedCount(ref size_t[string] counts, string key) {
		auto currentCount = key in counts;
		if (!currentCount) return false;

		if (*currentCount <= 1) {
			counts.remove(key);
		} else {
			(*currentCount)--;
		}
		return true;
	}

	private void removeStringAt(ref string[] values, size_t index) {
		if (values.length <= 1) {
			values = [];
		} else if (index == 0) {
			values = values[1 .. $];
		} else if (index == values.length - 1) {
			values = values[0 .. $ - 1];
		} else {
			values = values[0 .. index] ~ values[index + 1 .. $];
		}
	}

	// Remove exactly one expected move instance from both indexes.
	private bool consumeExpectedMovePair(string normalisedFrom, string normalisedTo) {
		auto destinations = normalisedFrom in expectedMoveDestinationsBySource;
		if (!destinations) return false;

		bool destinationFound = false;
		size_t destinationIndex;
		foreach (index, destination; *destinations) {
			if (destination == normalisedTo) {
				destinationFound = true;
				destinationIndex = index;
				break;
			}
		}
		if (!destinationFound) return false;

		string[] remainingDestinations = *destinations;
		removeStringAt(remainingDestinations, destinationIndex);
		if (remainingDestinations.empty) {
			expectedMoveDestinationsBySource.remove(normalisedFrom);
		} else {
			expectedMoveDestinationsBySource[normalisedFrom] = remainingDestinations;
		}

		auto sources = normalisedTo in expectedMoveSourcesByDestination;
		if (sources) {
			bool sourceFound = false;
			size_t sourceIndex;
			foreach (index, source; *sources) {
				if (source == normalisedFrom) {
					sourceFound = true;
					sourceIndex = index;
					break;
				}
			}

			if (sourceFound) {
				string[] remainingSources = *sources;
				removeStringAt(remainingSources, sourceIndex);
				if (remainingSources.empty) {
					expectedMoveSourcesByDestination.remove(normalisedTo);
				} else {
					expectedMoveSourcesByDestination[normalisedTo] = remainingSources;
				}
			}
		}

		return true;
	}

	// Record an exact directory-create echo expected from an online-to-local operation.
	void recordExpectedDirectoryCreate(string path) {
		string normalisedPath = normaliseMonitorPath(path);
		incrementExpectedCount(expectedDirectoryCreates, normalisedPath);
		if (debugLogging) {addLogEntry("MONITOR EXPECTED_ECHO register createDir path=" ~ normalisedPath ~ ", pending=" ~ to!string(expectedDirectoryCreates[normalisedPath]), ["debug"]);}
	}

	// Record an exact move echo expected from an online-to-local operation.
	void recordExpectedMove(string fromPath, string toPath) {
		string normalisedFrom = normaliseMonitorPath(fromPath);
		string normalisedTo = normaliseMonitorPath(toPath);
		expectedMoveDestinationsBySource[normalisedFrom] ~= normalisedTo;
		expectedMoveSourcesByDestination[normalisedTo] ~= normalisedFrom;
		if (debugLogging) {addLogEntry("MONITOR EXPECTED_ECHO register move from=" ~ normalisedFrom ~ ", to=" ~ normalisedTo ~ ", pending=" ~ to!string(expectedMoveDestinationsBySource[normalisedFrom].length), ["debug"]);}
	}

	// Record the final path of a successfully downloaded file. This is a fallback
	// for inotify implementations where the filtered '.partial' source event is
	// unavailable and the final file therefore appears as an unpaired arrival.
	void recordExpectedFileArrival(string path) {
		string normalisedPath = normaliseMonitorPath(path);
		incrementExpectedCount(expectedFileArrivals, normalisedPath);
		if (debugLogging) {addLogEntry("MONITOR EXPECTED_ECHO register fileArrival path=" ~ normalisedPath ~ ", pending=" ~ to!string(expectedFileArrivals[normalisedPath]), ["debug"]);}
	}

	// Record a path/subtree departure expected from an online-to-local deletion or recycle-bin move.
	void recordExpectedRemoval(string path) {
		string normalisedPath = normaliseMonitorPath(path);
		expectedRemovalRoots[normalisedPath] = true;
		if (debugLogging) {addLogEntry("MONITOR EXPECTED_ECHO register removal root=" ~ normalisedPath, ["debug"]);}
	}

	private bool consumeExpectedDirectoryCreate(string path) {
		if (expectedDirectoryCreates.length == 0) return false;
		string normalisedPath = normaliseMonitorPath(path);
		if (consumeExpectedCount(expectedDirectoryCreates, normalisedPath)) {
			if (debugLogging) {addLogEntry("MONITOR EXPECTED_ECHO consume createDir path=" ~ normalisedPath, ["debug"]);}
			return true;
		}
		return false;
	}

	private bool consumeExpectedMoveDestination(string destination) {
		if (expectedMoveSourcesByDestination.length == 0) return false;
		string normalisedDestination = normaliseMonitorPath(destination);
		auto sources = normalisedDestination in expectedMoveSourcesByDestination;
		if (sources && !(*sources).empty) {
			string normalisedSource = (*sources)[0];
			if (!consumeExpectedMovePair(normalisedSource, normalisedDestination)) return false;
			consumeExpectedCount(expectedFileArrivals, normalisedDestination);
			if (debugLogging) {addLogEntry("MONITOR EXPECTED_ECHO consume destination-only move from=" ~ normalisedSource ~ ", to=" ~ normalisedDestination, ["debug"]);}
			return true;
		}
		return false;
	}

	private bool consumeExpectedMove(string from, string to) {
		if (expectedMoveDestinationsBySource.length == 0) return false;
		string normalisedFrom = normaliseMonitorPath(from);
		string normalisedTo = normaliseMonitorPath(to);
		if (consumeExpectedMovePair(normalisedFrom, normalisedTo)) {
			consumeExpectedCount(expectedFileArrivals, normalisedTo);
			if (debugLogging) {addLogEntry("MONITOR EXPECTED_ECHO consume move from=" ~ normalisedFrom ~ ", to=" ~ normalisedTo, ["debug"]);}
			return true;
		}
		return false;
	}

	private bool consumeExpectedFileArrival(string path) {
		if (expectedFileArrivals.length == 0) return false;
		string normalisedPath = normaliseMonitorPath(path);
		if (!(normalisedPath in expectedFileArrivals)) return false;

		// If the source event was filtered or unavailable, consume the associated
		// move and arrival together. Otherwise consume only the remaining arrival.
		if (!consumeExpectedMoveDestination(normalisedPath)) {
			consumeExpectedCount(expectedFileArrivals, normalisedPath);
		}
		if (debugLogging) {addLogEntry("MONITOR EXPECTED_ECHO consume fileArrival path=" ~ normalisedPath, ["debug"]);}
		return true;
	}

	private bool isExpectedMoveSource(string path) {
		if (expectedMoveDestinationsBySource.length == 0) return false;
		return (normaliseMonitorPath(path) in expectedMoveDestinationsBySource) !is null;
	}

	private bool isExpectedMoveDestination(string path) {
		if (expectedMoveSourcesByDestination.length == 0) return false;
		return (normaliseMonitorPath(path) in expectedMoveSourcesByDestination) !is null;
	}

	private bool consumeExpectedRemovalObservation(string path) {
		if (expectedRemovalRoots.length == 0) return false;
		string currentPath = normaliseMonitorPath(path);
		bool matched = false;

		while (!currentPath.empty && currentPath != ".") {
			if (currentPath in expectedRemovalRoots) {
				observedRemovalRoots[currentPath] = true;
				matched = true;
				if (debugLogging) {addLogEntry("MONITOR EXPECTED_ECHO consume removal path=" ~ normaliseMonitorPath(path) ~ ", root=" ~ currentPath, ["debug"]);}
			}
			string parentPath = normaliseMonitorPath(dirName(currentPath));
			if (parentPath == currentPath) break;
			currentPath = parentPath;
		}
		return matched;
	}

	// Return whether a captured local move/delete means this path should not be restored yet.
	bool hasPendingDeparture(string path) {
		if (pendingChanges.hasPendingDeparture(path)) return true;
		string normalisedPath = normaliseMonitorPath(path);
		foreach (pendingPath; cookieToPath.byValue) {
			if (isSameOrChildPath(pendingPath, normalisedPath)) return true;
		}
		return false;
	}

	// Transfer the current observation batch to the coordinator.
	LocalChange[] takePendingChanges() {
		return pendingChanges.take();
	}

	// A completed post-online capture is the lifecycle boundary for expected echoes.
	void clearExpectedEvents(string invocationSource = "unspecified") {
		if (debugLogging) {
			foreach (path, count; expectedDirectoryCreates) {
				addLogEntry("MONITOR EXPECTED_ECHO unmatched createDir path=" ~ path ~ ", count=" ~ to!string(count) ~ ", source=" ~ invocationSource, ["debug"]);
			}
			foreach (from, destinations; expectedMoveDestinationsBySource) {
				foreach (to; destinations) {
					addLogEntry("MONITOR EXPECTED_ECHO unmatched move from=" ~ from ~ ", to=" ~ to ~ ", source=" ~ invocationSource, ["debug"]);
				}
			}
			foreach (path, count; expectedFileArrivals) {
				addLogEntry("MONITOR EXPECTED_ECHO unmatched fileArrival path=" ~ path ~ ", count=" ~ to!string(count) ~ ", source=" ~ invocationSource, ["debug"]);
			}
			foreach (root; expectedRemovalRoots.byKey) {
				if (!(root in observedRemovalRoots)) {
					addLogEntry("MONITOR EXPECTED_ECHO unmatched removal root=" ~ root ~ ", source=" ~ invocationSource, ["debug"]);
				}
			}
		}
		expectedDirectoryCreates = null;
		expectedMoveDestinationsBySource = null;
		expectedMoveSourcesByDestination = null;
		expectedFileArrivals = null;
		expectedRemovalRoots = null;
		observedRemovalRoots = null;
	}

	// Capture and coalesce inotify observations. No remote operation is executed here.
	void capture(string invocationSource = "unspecified", string parentLogKey = "") {
		// Observation-only counters for this invocation
		size_t readBatchCount = 0;
		size_t eventBatchCount = 0;
		size_t bytesRead = 0;
		size_t rawEventCount = 0;
		size_t ignoredEventCount = 0;
		size_t filteredEventCount = 0;
		size_t movedFromEventCount = 0;
		size_t movedToEventCount = 0;
		size_t createEventCount = 0;
		size_t deleteEventCount = 0;
		size_t closeWriteEventCount = 0;
		size_t suppressedMoveDeleteCount = 0;
		size_t queuedActionCount = 0;
		size_t skippedActionCount = 0;
		size_t executableMoveActionCount = 0;
		size_t executableDeleteActionCount = 0;
		size_t executableCreateDirActionCount = 0;
		size_t executableChangedActionCount = 0;
		size_t unmatchedMoveFromCount = 0;

		// Always emit the summary when leaving this function in debug mode, including exception paths
		scope(exit) {
			if (debugLogging) {
				addLogEntry("inotify processing summary context: source=" ~ invocationSource ~ ", mode=observation_capture, parentLogKey=" ~ (parentLogKey.empty ? "not-set" : parentLogKey), ["debug"]);
				addLogEntry("inotify processing summary events: readBatches=" ~ to!string(readBatchCount) ~ ", eventBatches=" ~ to!string(eventBatchCount) ~ ", bytesRead=" ~ to!string(bytesRead) ~ ", rawEvents=" ~ to!string(rawEventCount) ~ ", ignoredEvents=" ~ to!string(ignoredEventCount) ~ ", filteredEvents=" ~ to!string(filteredEventCount) ~ ", movedFrom=" ~ to!string(movedFromEventCount) ~ ", movedTo=" ~ to!string(movedToEventCount) ~ ", create=" ~ to!string(createEventCount) ~ ", delete=" ~ to!string(deleteEventCount) ~ ", closeWrite=" ~ to!string(closeWriteEventCount) ~ ", suppressedMoveDeletes=" ~ to!string(suppressedMoveDeleteCount), ["debug"]);
				addLogEntry("inotify processing summary observations: queued=" ~ to!string(queuedActionCount) ~ ", skipped=" ~ to!string(skippedActionCount) ~ ", executableMoved=" ~ to!string(executableMoveActionCount) ~ ", executableDeleted=" ~ to!string(executableDeleteActionCount) ~ ", executableCreateDir=" ~ to!string(executableCreateDirActionCount) ~ ", executableChanged=" ~ to!string(executableChangedActionCount) ~ ", unmatchedMoveFrom=" ~ to!string(unmatchedMoveFromCount), ["debug"]);
			}
		}

		if(!initialised)
			return;
	
		pollfd fds = {
			fd: worker.fd,
			events: POLLIN
		};

		while (true) {
			bool hasNotification = false;
			int sleep_counter = 0;
			// Batch events up to 5 seconds
			while (sleep_counter < 5) {
				int ret = poll(&fds, 1, 0);
				if (ret == -1) throw new MonitorException("poll failed");
				else if (ret == 0) break; // no events available
				hasNotification = true;
				size_t length = read(worker.fd, buffer.ptr, buffer.length);
				if (length == -1) throw new MonitorException("read failed");
				readBatchCount++;
				bytesRead += length;

				int i = 0;
				while (i < length) {
					inotify_event *event = cast(inotify_event*) &buffer[i];
					rawEventCount++;
					if (event.mask & IN_MOVED_FROM) movedFromEventCount++;
					if (event.mask & IN_MOVED_TO) movedToEventCount++;
					if (event.mask & IN_CREATE) createEventCount++;
					if (event.mask & IN_DELETE) deleteEventCount++;
					if (event.mask & IN_CLOSE_WRITE) closeWriteEventCount++;
					string path;
					string evalPath;
					bool expectedMoveSourceEvent = false;
					bool expectedMoveDestinationEvent = false;
					
					// inotify event debug
					if (debugLogging) {
						addLogEntry("inotify event wd: " ~ to!string(event.wd), ["debug"]);
						addLogEntry("inotify event mask: " ~ to!string(event.mask), ["debug"]);
						addLogEntry("inotify event cookie: " ~ to!string(event.cookie), ["debug"]);
						addLogEntry("inotify event len: " ~ to!string(event.len), ["debug"]);
						addLogEntry("inotify event name: " ~ to!string(event.name), ["debug"]);
					}
					
					// inotify event handling
					if (debugLogging) {
						if (event.mask & IN_ACCESS) addLogEntry("inotify event flag: IN_ACCESS", ["debug"]);
						if (event.mask & IN_MODIFY) addLogEntry("inotify event flag: IN_MODIFY", ["debug"]);
						if (event.mask & IN_ATTRIB) addLogEntry("inotify event flag: IN_ATTRIB", ["debug"]);
						if (event.mask & IN_CLOSE_WRITE) addLogEntry("inotify event flag: IN_CLOSE_WRITE", ["debug"]);
						if (event.mask & IN_CLOSE_NOWRITE) addLogEntry("inotify event flag: IN_CLOSE_NOWRITE", ["debug"]);
						if (event.mask & IN_MOVED_FROM) addLogEntry("inotify event flag: IN_MOVED_FROM", ["debug"]);
						if (event.mask & IN_MOVED_TO) addLogEntry("inotify event flag: IN_MOVED_TO", ["debug"]);
						if (event.mask & IN_CREATE) addLogEntry("inotify event flag: IN_CREATE", ["debug"]);
						if (event.mask & IN_DELETE) addLogEntry("inotify event flag: IN_DELETE", ["debug"]);
						if (event.mask & IN_DELETE_SELF) addLogEntry("inotify event flag: IN_DELETE_SELF", ["debug"]);
						if (event.mask & IN_MOVE_SELF) addLogEntry("inotify event flag: IN_MOVE_SELF", ["debug"]);
						if (event.mask & IN_UNMOUNT) addLogEntry("inotify event flag: IN_UNMOUNT", ["debug"]);
						if (event.mask & IN_Q_OVERFLOW) addLogEntry("inotify event flag: IN_Q_OVERFLOW", ["debug"]);
						if (event.mask & IN_IGNORED) addLogEntry("inotify event flag: IN_IGNORED", ["debug"]);
						if (event.mask & IN_CLOSE) addLogEntry("inotify event flag: IN_CLOSE", ["debug"]);
						if (event.mask & IN_MOVE) addLogEntry("inotify event flag: IN_MOVE", ["debug"]);
						if (event.mask & IN_ONLYDIR) addLogEntry("inotify event flag: IN_ONLYDIR", ["debug"]);
						if (event.mask & IN_DONT_FOLLOW) addLogEntry("inotify event flag: IN_DONT_FOLLOW", ["debug"]);
						if (event.mask & IN_EXCL_UNLINK) addLogEntry("inotify event flag: IN_EXCL_UNLINK", ["debug"]);
						if (event.mask & IN_MASK_ADD) addLogEntry("inotify event flag: IN_MASK_ADD", ["debug"]);
						if (event.mask & IN_ISDIR) addLogEntry("inotify event flag: IN_ISDIR", ["debug"]);
						if (event.mask & IN_ONESHOT) addLogEntry("inotify event flag: IN_ONESHOT", ["debug"]);
						if (event.mask & IN_ALL_EVENTS) addLogEntry("inotify event flag: IN_ALL_EVENTS", ["debug"]);
					}
					
					// skip events that need to be ignored
					if (event.mask & IN_IGNORED) {
						ignoredEventCount++;
						// Forget both directions of the watch bookkeeping entry.
						string ignoredPath;
						unregisterWatchDescriptor(event.wd, ignoredPath);
						goto skip;
					} else if (event.mask & IN_Q_OVERFLOW) {
						throw new MonitorException("inotify queue overflow: some events may be lost");
					}

					// if the event is not to be ignored, obtain path
					if (!getPath(event, path)) {
						goto skip;
					}
					// A client download is written to a filtered '.partial' path and then
					// renamed into place. Preserve an exact expected move source long enough
					// to pair it with the destination event instead of filtering it out.
					expectedMoveSourceEvent = ((event.mask & IN_MOVED_FROM) != 0) && isExpectedMoveSource(path);
					expectedMoveDestinationEvent = ((event.mask & IN_MOVED_TO) != 0) && isExpectedMoveDestination(path);
					// configure the skip_dir & skip skip_file comparison item
					evalPath = path.strip('.');
					
					// Skip events that should be excluded based on application configuration
					// We cant use isDir or isFile as this information is missing from the inotify event itself
					// Thus this causes a segfault when attempting to query this - https://github.com/abraunegg/onedrive/issues/995
					
					// Based on the 'type' of event & object type (directory or file) check that path against the 'right' user exclusions
					// Directory events should only be compared against skip_dir and file events should only be compared against skip_file
					if (event.mask & IN_ISDIR) {
						// The event in question contains IN_ISDIR event mask, thus highly likely this is an event on a directory
						// This due to if the user has specified in skip_dir an exclusive path: '/path' - that is what must be matched
						if (!(expectedMoveSourceEvent || expectedMoveDestinationEvent) && selectiveSync.isDirNameExcluded(evalPath)) {
							// The path to evaluate matches a path that the user has configured to skip
							filteredEventCount++;
							goto skip;
						}
					} else {
						// The event in question missing the IN_ISDIR event mask, thus highly likely this is an event on a file
						// This due to if the user has specified in skip_file an exclusive path: '/path/file' - that is what must be matched
						if (!(expectedMoveSourceEvent || expectedMoveDestinationEvent) && selectiveSync.isFileNameExcluded(evalPath)) {
							// The path to evaluate matches a path that the user has configured to skip
							filteredEventCount++;
							goto skip;
						}
					}
					
					// is the path, excluded via sync_list
					if (!(expectedMoveSourceEvent || expectedMoveDestinationEvent) && selectiveSync.isPathExcludedViaSyncList(path)) {
						// The path to evaluate matches a directory or file that the user has configured not to include in the sync
						filteredEventCount++;
						goto skip;
					}
					
					// handle the inotify events
					if (event.mask & IN_MOVED_FROM) {
						if (debugLogging) {addLogEntry("event IN_MOVED_FROM: " ~ path, ["debug"]);}
						if (consumeExpectedRemovalObservation(path)) {
							// Online-to-local deletion/recycle-bin move. Do not turn it into local intent.
							if (event.mask & IN_ISDIR) remove(path);
						} else {
							cookieToPath[event.cookie] = path;
							movedNotDeleted[path] = true; // Mark as moved, not deleted
						}
					} else if (event.mask & IN_MOVED_TO) {
						if (debugLogging) {addLogEntry("event IN_MOVED_TO: " ~ path, ["debug"]);}
						auto from = event.cookie in cookieToPath;
						if (from) {
							string sourcePath = *from;

							// A watched directory moved within the sync tree keeps its
							// underlying kernel watch descriptors. Rebase the stored
							// paths before recording or consuming the move.
							if (event.mask & IN_ISDIR) {
								rebaseWatchTree(sourcePath, path);
							}

							cookieToPath.remove(event.cookie);
							if (!consumeExpectedMove(sourcePath, path)) {
								pendingChanges.append(LocalChangeType.moved, sourcePath, path);
							}
							movedNotDeleted.remove(sourcePath); // Clear moved status
						} else {
							// Handle an item moved in from outside. An online-to-local move can
							// also appear destination-only if the source event was filtered or
							// unavailable on the platform.
							if (event.mask & IN_ISDIR) {
								addRecursive(path);
							}

							if (consumeExpectedMoveDestination(path)) {
								// Exact client-generated move echo consumed.
							} else if (event.mask & IN_ISDIR) {
								pendingChanges.append(LocalChangeType.createDir, path);
							} else if (!consumeExpectedFileArrival(path)) {
								pendingChanges.append(LocalChangeType.changed, path);
							}
						}
					} else if (event.mask & IN_CREATE) {
						if (debugLogging) {addLogEntry("event IN_CREATE: " ~ path, ["debug"]);}
						if (event.mask & IN_ISDIR) {
							// fix from #2586
							auto cookieToPath1 = cookieToPath.dup();
							foreach (cookie, path1; cookieToPath1) {
								if (path1 == path) {
									cookieToPath.remove(cookie);
								}
							}
							addRecursive(path);
							if (!consumeExpectedDirectoryCreate(path)) {
								pendingChanges.append(LocalChangeType.createDir, path);
							}
						} else {
							// Consume exact online-to-local arrivals first. On FreeBSD and
							// OpenBSD, a genuine local file write may be represented only by
							// IN_CREATE, with no subsequent IN_CLOSE_WRITE event.
							bool expectedFileArrival = consumeExpectedFileArrival(path);
							if (!expectedFileArrival && triggerFileCreateAsChanged) {
								if (debugLogging) {addLogEntry("Treating file IN_CREATE as an actionable local change on this platform: " ~ path, ["debug"]);}
								pendingChanges.append(LocalChangeType.changed, path);
							}
						}
					} else if (event.mask & IN_DELETE) {
						if (consumeExpectedRemovalObservation(path)) {
							// Online-to-local removal echo consumed.
						} else if (path in movedNotDeleted) {
							suppressedMoveDeleteCount++;
							movedNotDeleted.remove(path); // Ignore delete for moved files
						} else {
							if (debugLogging) {addLogEntry("event IN_DELETE: " ~ path, ["debug"]);}
							pendingChanges.append(LocalChangeType.deleted, path);
						}
					} else if ((event.mask & IN_CLOSE_WRITE) && !(event.mask & IN_ISDIR)) {
						if (debugLogging) {addLogEntry("event IN_CLOSE_WRITE and not IN_ISDIR: " ~ path, ["debug"]);}
						// fix from #2586
						auto cookieToPath1 = cookieToPath.dup();
						foreach (cookie, path1; cookieToPath1) {
							if (path1 == path) {
								cookieToPath.remove(cookie);
							}
						}
						if (!consumeExpectedFileArrival(path)) {
							pendingChanges.append(LocalChangeType.changed, path);
						}
					} else {
						// An unexpected event-mask combination must not terminate the
						// monitor. Log the complete event context and continue draining
						// the remaining queued events.
						addLogEntry(
							"inotify event unhandled: path=" ~ path ~
							", wd=" ~ event.wd.to!string ~
							", mask=" ~ event.mask.to!string ~
							", cookie=" ~ event.cookie.to!string,
							["debug"]
						);
					}

					skip:
					i += inotify_event.sizeof + event.len;
				}

				// Sleep for one second to prevent missing fast-changing events.
				if (poll(&fds, 1, 0) == 0) {
					sleep_counter += 1;
					Thread.sleep(dur!"seconds"(1));
				}
			}
			if (!hasNotification) break;
			eventBatchCount++;

			// Record the current pending observation state for diagnostics
			foreach (action; pendingChanges.changes) {
				queuedActionCount++;
				if (action.skipped) {
					skippedActionCount++;
					continue;
				}
				switch (action.type) {
					case LocalChangeType.moved:
						executableMoveActionCount++;
						break;
					case LocalChangeType.deleted:
						executableDeleteActionCount++;
						break;
					case LocalChangeType.createDir:
						executableCreateDirActionCount++;
						break;
					case LocalChangeType.changed:
						executableChangedActionCount++;
						break;
					default:
						break;
				}
			}

			// Assume that the items moved outside the watched directory have been deleted
			foreach (cookie, path; cookieToPath.dup) {
				unmatchedMoveFromCount++;
				if (isExpectedMoveSource(path)) {
					if (debugLogging) {addLogEntry("Discarding unmatched expected move source without creating a local-delete observation: " ~ path, ["debug"]);}
				} else {
					if (debugLogging) {addLogEntry("Deleting cookie|watch (post loop): " ~ path, ["debug"]);}
					pendingChanges.append(LocalChangeType.deleted, path);
					remove(path);
				}
				cookieToPath.remove(cookie);
			}
			// Debug Log that all inotify events are flushed
			if (debugLogging) {addLogEntry("inotify events flushed", ["debug"]);}
		}
	}  
}
