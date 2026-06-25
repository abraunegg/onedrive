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

// Relevant inotify events
version(FreeBSD) {
	 private immutable uint32_t mask = IN_CLOSE_WRITE | IN_CREATE | IN_DELETE | IN_MOVE;
} else {
	 private immutable uint32_t mask = IN_CLOSE_WRITE | IN_CREATE | IN_DELETE | IN_MOVE | IN_IGNORED | IN_Q_OVERFLOW;
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

		// wait for the caller to be ready
		receiveOnly!bool();

		while (isAlive) {
			fd_set fds;
			FD_ZERO(&fds);
			FD_SET(fd, &fds);

			// Listen for shutdown / interrupt wakeups from the control pipe.
			int controlPipeFd = (cast()p).readEnd.fileno;
			FD_SET(controlPipeFd, &fds);

			// select() only needs to scan up to the highest fd + 1.
			int maxFd = max(fd, controlPipeFd) + 1;
			res = select(maxFd, &fds, null, null, null);

			if (res == -1) {
				if (errno() == EINTR) {
					// Interrupted by signal; re-arm the wait.
					continue;
				}

				// Error occurred, tell caller to terminate.
				callerTid.send(-1);
				break;
			}

			// Control-pipe readiness is not filesystem activity. It is used to
			// unblock select() during interrupt/shutdown, so drain it and do not
			// report a local monitor wake-up to main.d.
			if (FD_ISSET(controlPipeFd, &fds)) {
				try {
					(cast()p).readEnd.readln();
				} catch (Exception) {
					// Ignore control-pipe drain errors during shutdown.
				}

				if (!isAlive) break;
				continue;
			}

			// Only inotify fd readiness should wake the caller for local
			// filesystem processing.
			if (FD_ISSET(fd, &fds)) {
				callerTid.send(1);

				// wait for the caller to be ready
				if (isAlive)
					isAlive = receiveOnly!bool();

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

enum ActionType {
	moved,
	deleted, 
	changed,
	createDir
}

struct Action {
	ActionType type;
	bool skipped;
	string src;
	string dst;
}

struct ActionHolder {
	Action[] actions;
	size_t[string] srcMap;

	private string normaliseMonitorPath(string path) {
		if (path.empty) return path;
		return (path[0] == '.') ? path : "./" ~ path;
	}

	private bool isSameOrChildPath(string parent, string candidate) {
		string normalisedParent = normaliseMonitorPath(parent);
		string normalisedCandidate = normaliseMonitorPath(candidate);

		return (normalisedCandidate == normalisedParent) || startsWith(normalisedCandidate, normalisedParent ~ "/");
	}

	private string rebasePath(string fromRoot, string toRoot, string candidate) {
		string normalisedFromRoot = normaliseMonitorPath(fromRoot);
		string normalisedCandidate = normaliseMonitorPath(candidate);

		if (normalisedCandidate == normalisedFromRoot) {
			return toRoot;
		}

		return toRoot ~ normalisedCandidate[normalisedFromRoot.length .. $];
	}

	void append(ActionType type, string src, string dst=null) {
		size_t[] pendingTargets;
		switch (type) {
			case ActionType.changed:
				if (src in srcMap && actions[srcMap[src]].type == ActionType.changed) {
					// skip duplicate operations
					return;
				}
				break;
			case ActionType.createDir:
				break;
			case ActionType.deleted:
				foreach (action; actions) {
					if (action.skipped) continue;
					if (action.type == ActionType.moved && isSameOrChildPath(action.src, src)) {
						// A delete for an item underneath a pending move is an inotify artefact of the move.
						// The parent move will update Microsoft OneDrive without deleting child items.
						return;
					}
				}

				if (src in srcMap) {
					size_t pendingTarget = srcMap[src];
					// Skip operations require reading local file that is gone
					switch (actions[pendingTarget].type) {
						case ActionType.changed:
						case ActionType.createDir:
							actions[srcMap[src]].skipped = true;
							srcMap.remove(src);
							break;
						default:
							break;
					}
				}

				// If a parent directory delete arrives after child deletes, collapse the
				// child delete actions into the parent delete. Linux commonly reports
				// rm -rf as file deletes followed by the directory delete. Processing
				// only the parent preserves the intended recursive delete operation and
				// avoids leaving empty remote directories behind if child deletes were
				// observed first.
				foreach (ref action; actions) {
					if (action.skipped) continue;
					if (action.type == ActionType.deleted && isSameOrChildPath(src, action.src) && normaliseMonitorPath(src) != normaliseMonitorPath(action.src)) {
						action.skipped = true;
						srcMap.remove(action.src);
					}
				}
				break;
			case ActionType.moved:
				for(int i = 0; i < actions.length; i++) {
					// Only match for latest operation
					if (actions[i].src in srcMap) {
						switch (actions[i].type) {
							case ActionType.changed:
							case ActionType.createDir:
								if (isSameOrChildPath(src, actions[i].src)) {
									// Hold operations requiring local reads until after the target is moved online.
									pendingTargets ~= i;
									actions[i].skipped = true;
									srcMap.remove(actions[i].src);
									actions[i].src = rebasePath(src, dst, actions[i].src);
								}
								break;
							case ActionType.deleted:
								if (isSameOrChildPath(src, actions[i].src)) {
									// Suppress delete notifications for children of a moved directory.
									// These are artefacts of the local move and must not become remote deletes.
									actions[i].skipped = true;
									srcMap.remove(actions[i].src);
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
		actions ~= Action(type, false, src, dst);
		srcMap[src] = actions.length - 1;
		
		foreach (pendingTarget; pendingTargets) {
			actions ~= actions[pendingTarget];
			actions[$-1].skipped = false;
			srcMap[actions[$-1].src] = actions.length - 1;
		}
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
	// flag set when the monitor stream reports lost events
	private bool monitorStateDirty = false;
	// map the inotify cookies of move_from events to their path
	private string[int] cookieToPath;
	// buffer to receive the inotify events
	private void[] buffer;
	
	// Mutex to support thread safe access of inotify watch descriptors
	private Mutex inotifyMutex;

	// Configure function delegates
	void delegate(string path) onDirCreated;
	void delegate(string[] path) onFileChanged;
	void delegate(string path) onDelete;
	void delegate(string from, string to) onMove;
	
	// List of paths that were moved, not deleted
	bool[string] movedNotDeleted;

	// An array of actions
	ActionHolder actionHolder;
	
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
		
		assert(onDirCreated && onFileChanged && onDelete && onMove);
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
		if(!initialised)
			return;
		initialised = false;

		// Interrupt the worker so select() wakes if it is waiting on inotify.
		if (worker !is null) {
			worker.interrupt();
		}

		// Remove all the inotify watch descriptors before closing the fd.
		removeAll();

		// Notify the worker that the monitor has been shutdown. This unblocks the
		// worker if it has already sent a wake-up and is waiting for the main thread
		// to acknowledge whether monitoring should continue.
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
			cookieToPath = null;
			movedNotDeleted = null;
		} finally {
			inotifyMutex.unlock();
		}
	}


	// Return a stable monitor bookkeeping key for a path.
	// All internal watch maps use this form so that these variants are treated
	// as the same directory: ./path, path, path/.
	private string normaliseWatchPath(string path) {
		if (path.empty) return ".";

		string normalisedPath = buildNormalizedPath(path);

		if (normalisedPath.empty || normalisedPath == "./") return ".";
		if (normalisedPath.startsWith("./")) normalisedPath = normalisedPath[2 .. $];

		while ((normalisedPath.length > 1) && normalisedPath.endsWith("/")) {
			normalisedPath = normalisedPath[0 .. $-1];
		}

		if (normalisedPath.empty) return ".";
		return normalisedPath;
	}

	private string watchPathToEventPrefix(string watchPath) {
		return (watchPath == ".") ? "" : watchPath ~ "/";
	}

	private bool isSameOrChildWatchPath(string parent, string candidate) {
		string parentPath = normaliseWatchPath(parent);
		string candidatePath = normaliseWatchPath(candidate);

		return (candidatePath == parentPath) || startsWith(candidatePath, parentPath ~ "/");
	}

	private string rebaseWatchPath(string fromRoot, string toRoot, string candidate) {
		string normalisedFromRoot = normaliseWatchPath(fromRoot);
		string normalisedToRoot = normaliseWatchPath(toRoot);
		string normalisedCandidate = normaliseWatchPath(candidate);

		if (normalisedCandidate == normalisedFromRoot) return normalisedToRoot;
		return normalisedToRoot ~ normalisedCandidate[normalisedFromRoot.length .. $];
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
			// drop that stale descriptor mapping. The path-level reverse map is the
			// source of truth for idempotency.
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

	private void clearTransientEventState() {
		cookieToPath = null;
		movedNotDeleted = null;
		object.destroy(actionHolder);
	}

	bool isMonitorStateDirty() {
		return monitorStateDirty;
	}

	void clearMonitorStateDirty() {
		monitorStateDirty = false;
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

	// Remove all watch descriptors
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

	// Remove a watch descriptor
	private void remove(int wd, bool verboseRemovalLog = false) {
		string dirname;
		int ret;
		int savedErrno;

		inotifyMutex.lock();
		try {
			auto existingPath = wd in wdToDirName;
			if (existingPath is null) {
				if (debugLogging) {addLogEntry("inotify watch descriptor already removed from internal map: wd=" ~ wd.to!string, ["debug"]);}
				return;
			}
			dirname = *existingPath;
		} finally {
			inotifyMutex.unlock();
		}

		ret = worker.removeInotifyWatch(wd);
		savedErrno = errno();

		if (ret < 0) {
			// EINVAL indicates that the watch descriptor is no longer valid. This can
			// occur legitimately if the watched directory was deleted/moved or the
			// kernel already removed the watch before explicit cleanup. Remove our
			// bookkeeping entry and continue.
			if (savedErrno == EINVAL) {
				if (debugLogging) {addLogEntry("Ignoring already-invalid inotify watch during removal: wd=" ~ wd.to!string ~ ", path=" ~ dirname, ["debug"]);}
			} else {
				throw new MonitorException("inotify_rm_watch failed");
			}
		}

		string removedPath;
		unregisterWatchDescriptor(wd, removedPath);

		// Runtime directory delete/move cleanup can remove many watches at once,
		// especially on FreeBSD where the backend may not silently invalidate child
		// watches before our explicit recursive cleanup runs. Keep that normal
		// runtime cleanup out of verbose output, but retain it for debug diagnostics.
		// Full teardown / shutdown still passes verboseRemovalLog=true.
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
			// every child watch descriptor. The individual removals remain visible at
			// debug level via remove().
			remove(wd, false);
		}

		if ((matchingWds.length > 0) && debugLogging) {
			addLogEntry("Removed " ~ matchingWds.length.to!string ~ " inotify watch descriptor(s) for directory tree: " ~ key, ["debug"]);
		}
	}

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
					// This should not normally happen after idempotent registration, but if a
					// previous buggy run produced duplicate path state, prefer the watch that
					// is already being rebased and drop the stale reverse entry.
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
			addLogEntry("Rebased " ~ rebasedCount.to!string ~ " inotify watch descriptor(s) from " ~ oldRoot ~ " to " ~ newRoot, ["debug"]);
		}
	}

	private void pruneStaleWatches() {
		int[] staleWds;
		string[int] copy;

		inotifyMutex.lock();
		try {
			copy = wdToDirName.dup;
		} finally {
			inotifyMutex.unlock();
		}

		foreach (wd, dirname; copy) {
			if (dirname == ".") continue;

			try {
				if (!exists(dirname) || !isDir(dirname)) {
					staleWds ~= wd;
				}
			} catch (FileException) {
				staleWds ~= wd;
			}
		}

		foreach (wd; staleWds) {
			// Stale watch pruning is normal runtime housekeeping; keep verbose output
			// quiet and expose individual removals only at debug level.
			remove(wd, false);
		}

		if ((staleWds.length > 0) && debugLogging) {
			addLogEntry("Pruned " ~ staleWds.length.to!string ~ " stale inotify watch descriptor(s)", ["debug"]);
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

		if (event.len > 0) {
			path ~= fromStringz(event.name.ptr);
		} else if (path.empty) {
			path = ".";
		} else if (path.endsWith("/")) {
			path = path[0 .. $-1];
		}

		if (debugLogging) {addLogEntry("inotify path event for: " ~ path, ["debug"]);}
		return true;
	}

	private void drainPendingEventsOnly(ref pollfd fds) {
		size_t drainedEvents = 0;

		while (true) {
			bool hasNotification = false;
			int sleep_counter = 0;

			// Preserve the existing short batching window, but do not resolve paths,
			// update watches, evaluate filters, or invoke callbacks. This path is
			// used when callers explicitly want queued local events cancelled.
			while (sleep_counter < 5) {
				int ret = poll(&fds, 1, 0);
				if (ret == -1) throw new MonitorException("poll failed");
				else if (ret == 0) break;

				hasNotification = true;
				size_t length = read(worker.fd, buffer.ptr, buffer.length);
				if (length == -1) throw new MonitorException("read failed");

				int i = 0;
				while (i < length) {
					inotify_event *event = cast(inotify_event*) &buffer[i];

					if (event.mask & IN_IGNORED) {
						string ignoredPath;
						unregisterWatchDescriptor(event.wd, ignoredPath);
					} else if (event.mask & IN_Q_OVERFLOW) {
						monitorStateDirty = true;
						clearTransientEventState();
						throw new MonitorException("inotify queue overflow: some events may be lost");
					}

					drainedEvents++;
					i += inotify_event.sizeof + event.len;
				}

				if (poll(&fds, 1, 0) == 0) {
					sleep_counter += 1;
					Thread.sleep(dur!"seconds"(1));
				}
			}

			if (!hasNotification) break;
		}

		if ((drainedEvents > 0) && debugLogging) {
			addLogEntry("Drained " ~ drainedEvents.to!string ~ " stale local filesystem monitor event(s) without processing", ["debug"]);
		}
	}

	// Update
	void update(bool useCallbacks = true, bool processDeletesWhenDraining = false) {
		if(!initialised)
			return;
	
		pollfd fds = {
			fd: worker.fd,
			events: POLLIN
		};

		if (!useCallbacks && !processDeletesWhenDraining) {
			clearTransientEventState();
			drainPendingEventsOnly(fds);
			return;
		}

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

				int i = 0;
				while (i < length) {
					inotify_event *event = cast(inotify_event*) &buffer[i];
					string path;
					string evalPath;
					
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
						// The backend has invalidated this watch descriptor. Keep both
						// descriptor->path and path->descriptor maps in sync.
						string ignoredPath;
						unregisterWatchDescriptor(event.wd, ignoredPath);
						goto skip;
					} else if (event.mask & IN_Q_OVERFLOW) {
						monitorStateDirty = true;
						clearTransientEventState();
						throw new MonitorException("inotify queue overflow: some events may be lost");
					}

					// if the event is not to be ignored, obtain path
					if (!getPath(event, path)) {
						goto skip;
					}
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
						if (selectiveSync.isDirNameExcluded(evalPath)) {
							// The path to evaluate matches a path that the user has configured to skip
							goto skip;
						}
					} else {
						// The event in question missing the IN_ISDIR event mask, thus highly likely this is an event on a file
						// This due to if the user has specified in skip_file an exclusive path: '/path/file' - that is what must be matched
						if (selectiveSync.isFileNameExcluded(evalPath)) {
							// The path to evaluate matches a file that the user has configured to skip
							goto skip;
						}
					}
					
					// is the path, excluded via sync_list
					if (selectiveSync.isPathExcludedViaSyncList(path)) {
						// The path to evaluate matches a directory or file that the user has configured not to include in the sync
						goto skip;
					}
					
					// handle the inotify events
					if (event.mask & IN_MOVED_FROM) {
						if (debugLogging) {addLogEntry("event IN_MOVED_FROM: " ~ path, ["debug"]);}
						cookieToPath[event.cookie] = path;
						movedNotDeleted[path] = true; // Mark as moved, not deleted
					} else if (event.mask & IN_MOVED_TO) {
						if (debugLogging) {addLogEntry("event IN_MOVED_TO: " ~ path, ["debug"]);}
						auto from = event.cookie in cookieToPath;
						if (from) {
							// A watched directory moved inside the sync tree keeps its underlying
							// watch descriptors. Rebase the stored paths instead of adding another
							// recursive watch tree for the same directory hierarchy.
							if (event.mask & IN_ISDIR) rebaseWatchTree(*from, path);
							cookieToPath.remove(event.cookie);
							if (useCallbacks) actionHolder.append(ActionType.moved, *from, path);
							movedNotDeleted.remove(*from); // Clear moved status
						} else {
							// Handle item moved in from outside the watched tree.
							if (event.mask & IN_ISDIR) {
								addRecursive(path);
								if (useCallbacks) actionHolder.append(ActionType.createDir, path);
							} else {
								if (useCallbacks) actionHolder.append(ActionType.changed, path);
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
							if (useCallbacks) actionHolder.append(ActionType.createDir, path);
						}
					} else if (event.mask & IN_DELETE_SELF) {
						if (debugLogging) {addLogEntry("event IN_DELETE_SELF: " ~ path, ["debug"]);}
						removeWatchTree(path);
						if (useCallbacks || processDeletesWhenDraining) actionHolder.append(ActionType.deleted, path);
					} else if (event.mask & IN_MOVE_SELF) {
						// Do not remove the watch here. Directory moves inside the watched tree
						// are reconciled via the matching parent IN_MOVED_FROM/IN_MOVED_TO
						// cookie pair, where the watch tree is rebased to the new path.
						if (debugLogging) {addLogEntry("event IN_MOVE_SELF: " ~ path, ["debug"]);}
					} else if (event.mask & IN_DELETE) {
						if (path in movedNotDeleted) {
							movedNotDeleted.remove(path); // Ignore delete for moved files
						} else {
							if (debugLogging) {addLogEntry("event IN_DELETE: " ~ path, ["debug"]);}
							if (event.mask & IN_ISDIR) removeWatchTree(path);
							if (useCallbacks || processDeletesWhenDraining) actionHolder.append(ActionType.deleted, path);
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
						if (useCallbacks) actionHolder.append(ActionType.changed, path);
					} else {
						if (debugLogging) {addLogEntry("Ignoring unhandled inotify event for path: " ~ path ~ ", mask=" ~ event.mask.to!string, ["debug"]);}
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
			processChanges();

			// Assume that the items moved outside the watched directory have been deleted.
			// Iterate over a copy because cookieToPath is mutated during cleanup.
			auto cookieToPathCopy = cookieToPath.dup;
			foreach (cookie, path; cookieToPathCopy) {
				if (debugLogging) {addLogEntry("Deleting cookie|watch (post loop): " ~ path, ["debug"]);}
				if (useCallbacks || processDeletesWhenDraining) onDelete(path);
				removeWatchTree(path);
				cookieToPath.remove(cookie);
				movedNotDeleted.remove(path);
			}

			// Any lost delete/move events can leave stale watch entries behind. Prune
			// against the current filesystem before the monitor loop goes idle again.
			pruneStaleWatches();

			// Debug Log that all inotify events are flushed
			if (debugLogging) {addLogEntry("inotify events flushed", ["debug"]);}
		}
	}
  
	private void processChanges() {
		string[] changes;

		foreach(action; actionHolder.actions) {
			if (action.skipped)
				continue;
			switch (action.type) {
				case ActionType.changed:
					changes ~= action.src;
					break;
				case ActionType.deleted:
					onDelete(action.src);
					break;
				case ActionType.createDir:
					onDirCreated(action.src);
					break;
				case ActionType.moved:
					onMove(action.src, action.dst);
					break;
				default:
					break;
			}
		}
		if (!changes.empty) {
			onFileChanged(changes);
		}

		object.destroy(actionHolder);
	}
}
