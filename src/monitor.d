// What is this module called?
module monitor;

version (OSX) {

// macOS has no inotify-compatible API. Use FSEvents and keep the public
// Monitor interface aligned with the inotify implementation below.
import core.stdc.string;
import core.sync.mutex;
import config;
import clientSideFiltering;
import util;
import log;
import std.algorithm;
import std.array;
import std.concurrency;
import std.conv;
import std.file;
import std.path;
import std.string;

alias CFAllocatorRef = const(void)*;
alias CFArrayRef = const(void)*;
alias CFStringRef = const(void)*;
alias FSEventStreamRef = void*;
alias ConstFSEventStreamRef = const(void)*;
alias FSEventStreamCreateFlags = uint;
alias FSEventStreamEventFlags = uint;
alias FSEventStreamEventId = ulong;
alias dispatch_queue_t = void*;

enum kCFStringEncodingUTF8 = 0x08000100;
enum kFSEventStreamEventIdSinceNow = ulong.max;
enum kFSEventStreamCreateFlagNoDefer = 0x00000002;
enum kFSEventStreamCreateFlagWatchRoot = 0x00000004;
enum kFSEventStreamCreateFlagFileEvents = 0x00000010;
enum kFSEventStreamEventFlagMustScanSubDirs = 0x00000001;
enum kFSEventStreamEventFlagRootChanged = 0x00000020;
enum kFSEventStreamEventFlagItemCreated = 0x00000100;
enum kFSEventStreamEventFlagItemRemoved = 0x00000200;
enum kFSEventStreamEventFlagItemInodeMetaMod = 0x00000400;
enum kFSEventStreamEventFlagItemRenamed = 0x00000800;
enum kFSEventStreamEventFlagItemModified = 0x00001000;
enum kFSEventStreamEventFlagItemFinderInfoMod = 0x00002000;
enum kFSEventStreamEventFlagItemChangeOwner = 0x00004000;
enum kFSEventStreamEventFlagItemXattrMod = 0x00008000;
enum kFSEventStreamEventFlagItemIsFile = 0x00010000;
enum kFSEventStreamEventFlagItemIsDir = 0x00020000;

alias FSEventStreamCallback = extern(C) void function(
	ConstFSEventStreamRef streamRef,
	void* clientCallBackInfo,
	size_t numEvents,
	void* eventPaths,
	const(FSEventStreamEventFlags)* eventFlags,
	const(FSEventStreamEventId)* eventIds
);

struct FSEventStreamContext {
	long version_;
	void* info;
	void* retain;
	void* release;
	void* copyDescription;
}

extern(C) {
	CFStringRef CFStringCreateWithCString(CFAllocatorRef alloc, const(char)* cStr, uint encoding);
	CFArrayRef CFArrayCreate(CFAllocatorRef allocator, const(void)** values, long numValues, const(void)* callbacks);
	void CFRelease(const(void)* cf);
	dispatch_queue_t dispatch_get_global_queue(long identifier, ulong flags);
	FSEventStreamRef FSEventStreamCreate(
		CFAllocatorRef allocator,
		FSEventStreamCallback callback,
		FSEventStreamContext* context,
		CFArrayRef pathsToWatch,
		FSEventStreamEventId sinceWhen,
		double latency,
		FSEventStreamCreateFlags flags
	);
	void FSEventStreamSetDispatchQueue(FSEventStreamRef streamRef, dispatch_queue_t q);
	ubyte FSEventStreamStart(FSEventStreamRef streamRef);
	void FSEventStreamStop(FSEventStreamRef streamRef);
	void FSEventStreamInvalidate(FSEventStreamRef streamRef);
	void FSEventStreamRelease(FSEventStreamRef streamRef);
	void FSEventStreamFlushSync(FSEventStreamRef streamRef);
}

struct FsEvent {
	string path;
	FSEventStreamEventFlags flags;
}

struct RenameTarget {
	string path;
	bool isDir;
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

	void append(ActionType type, string src, string dst=null) {
		if (type == ActionType.changed) {
			if (src in srcMap && actions[srcMap[src]].type == ActionType.changed) return;
		}
		actions ~= Action(type, false, src, dst);
		srcMap[src] = actions.length - 1;
	}
}

class MonitorException: Exception {
	@safe this(string msg, string file = __FILE__, size_t line = __LINE__) {
		super(msg, file, line);
	}
}

final class Monitor {
	ApplicationConfig appConfig;
	ClientSideFiltering selectiveSync;
	bool verbose = false;
	bool skip_symlinks = false;
	bool check_nosync = false;
	bool initialised = false;
	FSEventStreamRef stream;
	CFStringRef watchedPathRef;
	CFArrayRef pathsToWatch;
	string rootAbsolute;
	string rootRelative;
	Tid callerTid;
	Mutex eventMutex;
	FsEvent[] queuedEvents;
	ActionHolder actionHolder;

	void delegate(string path) onDirCreated;
	void delegate(string[] path) onFileChanged;
	void delegate(string path) onDelete;
	void delegate(string from, string to) onMove;

	this(ApplicationConfig appConfig, ClientSideFiltering selectiveSync) {
		this.appConfig = appConfig;
		this.selectiveSync = selectiveSync;
		eventMutex = new Mutex();
	}

	~this() {
		shutdown();
	}

	void initialise() {
		skip_symlinks = appConfig.getValueBool("skip_symlinks");
		check_nosync = appConfig.getValueBool("check_nosync");
		if (appConfig.getValueLong("verbose") > 0) verbose = true;
		callerTid = thisTid;

		assert(onDirCreated && onFileChanged && onDelete && onMove);
		string monitorPath = ".";
		if (appConfig.getValueString("single_directory") != "") {
			monitorPath = "./" ~ appConfig.getValueString("single_directory");
		}

		rootRelative = buildNormalizedPath(monitorPath);
		if (rootRelative == "") rootRelative = ".";
		rootAbsolute = buildNormalizedPath(absolutePath(monitorPath));

		watchedPathRef = CFStringCreateWithCString(null, toStringz(rootAbsolute), kCFStringEncodingUTF8);
		if (watchedPathRef is null) throw new MonitorException("CFStringCreateWithCString failed for FSEvents path: " ~ rootAbsolute);

		const(void)* pathValue = watchedPathRef;
		pathsToWatch = CFArrayCreate(null, &pathValue, 1, null);
		if (pathsToWatch is null) throw new MonitorException("CFArrayCreate failed for FSEvents path: " ~ rootAbsolute);

		FSEventStreamContext context;
		context.version_ = 0;
		context.info = cast(void*) this;

		auto flags = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot;
		stream = FSEventStreamCreate(null, &fseventsCallback, &context, pathsToWatch, kFSEventStreamEventIdSinceNow, 1.0, flags);
		if (stream is null) throw new MonitorException("FSEventStreamCreate failed for path: " ~ rootAbsolute);

		FSEventStreamSetDispatchQueue(stream, dispatch_get_global_queue(0, 0));
		if (FSEventStreamStart(stream) == 0) throw new MonitorException("FSEventStreamStart failed for path: " ~ rootAbsolute);

		addLogEntry("Initialised macOS FSEvents monitoring for: " ~ rootRelative, ["info"]);
		initialised = true;
	}

	void send(bool isAlive) {
	}

	void shutdown() {
		if (stream !is null) {
			FSEventStreamStop(stream);
			FSEventStreamInvalidate(stream);
			FSEventStreamRelease(stream);
			stream = null;
		}
		if (pathsToWatch !is null) {
			CFRelease(pathsToWatch);
			pathsToWatch = null;
		}
		if (watchedPathRef !is null) {
			CFRelease(watchedPathRef);
			watchedPathRef = null;
		}
		initialised = false;
	}

	void update(bool useCallbacks = true) {
		if (!initialised) return;
		if (stream !is null) FSEventStreamFlushSync(stream);

		auto events = drainEvents();
		if (events.empty) return;
		if (!useCallbacks) return;

		processEvents(events);
		processChanges();
	}

	void enqueueEvent(string absoluteEventPath, FSEventStreamEventFlags flags) {
		auto relativePath = toMonitorPath(absoluteEventPath);
		if (relativePath.empty) return;
		bool shouldWake;

		eventMutex.lock();
		try {
			shouldWake = queuedEvents.empty;
			queuedEvents ~= FsEvent(relativePath, flags);
		} finally {
			eventMutex.unlock();
		}
		if (shouldWake) callerTid.send(1);
	}

	private FsEvent[] drainEvents() {
		FsEvent[] events;
		eventMutex.lock();
		try {
			events = queuedEvents;
			queuedEvents = null;
		} finally {
			eventMutex.unlock();
		}
		return events;
	}

	private string toMonitorPath(string absoluteEventPath) {
		auto normalised = buildNormalizedPath(absoluteEventPath);
		if (normalised == rootAbsolute) return rootRelative;
		auto prefix = rootAbsolute ~ "/";
		if (!normalised.startsWith(prefix)) return null;
		auto suffix = normalised[prefix.length .. $];
		if (rootRelative == ".") return "./" ~ suffix;
		return buildNormalizedPath(rootRelative ~ "/" ~ suffix);
	}

	private bool isDirectoryEvent(FsEvent event) {
		if (event.flags & kFSEventStreamEventFlagItemIsDir) return true;
		try {
			return exists(event.path) && isDir(event.path);
		} catch (FileException e) {
			return false;
		}
	}

	private bool shouldSkipEvent(string path, bool isDirEvent) {
		if (path == ".") return false;
		try {
			if (exists(path) && isSymlink(path) && skip_symlinks) return true;
			if (check_nosync && isDirEvent && exists(buildNormalizedPath(path) ~ "/.nosync")) return true;
			auto evalPath = path.strip('.');
			if (isDirEvent) {
				if (selectiveSync.isDirNameExcluded(evalPath)) return true;
				if ((selectiveSync.getSkipDotfiles()) && (isDotFile(path))) return true;
			} else {
				if (selectiveSync.isFileNameExcluded(evalPath)) return true;
			}
			if (selectiveSync.isPathExcludedViaSyncList(buildNormalizedPath(path))) return true;
		} catch (FileException e) {
			return false;
		}
		return false;
	}

	private void processEvents(FsEvent[] events) {
		RenameTarget[] removedRenames;
		RenameTarget[] createdRenames;

		foreach (event; events) {
			if (debugLogging) {
				addLogEntry("FSEvents path event for: " ~ event.path, ["debug"]);
				addLogEntry("FSEvents event flags: " ~ to!string(event.flags), ["debug"]);
			}

			if ((event.flags & kFSEventStreamEventFlagMustScanSubDirs) || (event.flags & kFSEventStreamEventFlagRootChanged)) {
				if (!shouldSkipEvent(rootRelative, true)) actionHolder.append(ActionType.createDir, rootRelative);
				continue;
			}

			bool isDirEvent = isDirectoryEvent(event);
			if (shouldSkipEvent(event.path, isDirEvent)) continue;

			if (event.flags & kFSEventStreamEventFlagItemRenamed) {
				if (exists(event.path)) {
					createdRenames ~= RenameTarget(event.path, isDirEvent);
				} else {
					removedRenames ~= RenameTarget(event.path, isDirEvent);
				}
				continue;
			}

			if (event.flags & kFSEventStreamEventFlagItemRemoved) {
				actionHolder.append(ActionType.deleted, event.path);
			} else if (event.flags & kFSEventStreamEventFlagItemCreated) {
				if (isDirEvent) {
					actionHolder.append(ActionType.createDir, event.path);
				} else {
					actionHolder.append(ActionType.changed, event.path);
				}
			} else if (event.flags & (kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemInodeMetaMod | kFSEventStreamEventFlagItemFinderInfoMod | kFSEventStreamEventFlagItemChangeOwner | kFSEventStreamEventFlagItemXattrMod)) {
				if (!isDirEvent) actionHolder.append(ActionType.changed, event.path);
			}
		}

		pairRenameEvents(removedRenames, createdRenames);
	}

	private void pairRenameEvents(RenameTarget[] removedRenames, RenameTarget[] createdRenames) {
		bool[] usedCreated;
		usedCreated.length = createdRenames.length;

		foreach (removed; removedRenames) {
			ptrdiff_t targetIndex = -1;

			foreach (idx, created; createdRenames) {
				if (usedCreated[idx]) continue;
				if (removed.isDir == created.isDir && baseName(removed.path) == baseName(created.path)) {
					targetIndex = cast(ptrdiff_t) idx;
					break;
				}
			}

			if (targetIndex >= 0) {
				usedCreated[targetIndex] = true;
				if (debugLogging) {addLogEntry("FSEvents paired rename: " ~ removed.path ~ " -> " ~ createdRenames[targetIndex].path, ["debug"]);}
				actionHolder.append(ActionType.moved, removed.path, createdRenames[targetIndex].path);
			} else {
				// FSEvents has no inotify-style rename cookie. A rename-away may
				// be an application-driven safeBackup, not a user delete. Real
				// deletes arrive as ItemRemoved and are handled above.
				if (debugLogging) {addLogEntry("FSEvents unpaired rename-away ignored as delete: " ~ removed.path, ["debug"]);}
			}
		}

		foreach (idx, created; createdRenames) {
			if (usedCreated[idx]) continue;
			if (created.isDir) {
				actionHolder.append(ActionType.createDir, created.path);
			} else {
				actionHolder.append(ActionType.changed, created.path);
			}
		}
	}

	private void processChanges() {
		string[] changes;

		foreach(action; actionHolder.actions) {
			if (action.skipped) continue;
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
		if (!changes.empty) onFileChanged(changes);
		object.destroy(actionHolder);
	}
}

extern(C) void fseventsCallback(
	ConstFSEventStreamRef streamRef,
	void* clientCallBackInfo,
	size_t numEvents,
	void* eventPaths,
	const(FSEventStreamEventFlags)* eventFlags,
	const(FSEventStreamEventId)* eventIds
) {
	if (clientCallBackInfo is null) return;
	auto monitor = cast(Monitor) clientCallBackInfo;
	auto paths = cast(const(char)**) eventPaths;
	foreach (idx; 0 .. numEvents) {
		monitor.enqueueEvent(fromStringz(paths[idx]).idup, eventFlags[idx]);
	}
}

} else {

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

	this() {
		isAlive = true;
		p = pipe();
	}

	shared void initialise() {
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

		// wait for the caller to be ready
		receiveOnly!int();

		while (isAlive) {
			fd_set fds;
			FD_ZERO (&fds);
			FD_SET(fd, &fds);
			// Listen for messages from the caller
			FD_SET((cast()p).readEnd.fileno, &fds);
			
			res = select(FD_SETSIZE, &fds, null, null, null);

			if(res == -1) {
				if(errno() == EINTR) {
					// Received an interrupt signal but no events are available
					// directly watch again
				} else {
					// Error occurred, tell caller to terminate.
					callerTid.send(-1);
					break;
				}
			} else {
				// Wake up caller
				callerTid.send(1);

				// wait for the caller to be ready
				if (isAlive)
					isAlive = receiveOnly!bool();
			}
		}
	}

	shared void interrupt() {
		isAlive = false;
		(cast()p).writeEnd.writeln("done");
		(cast()p).writeEnd.flush();
	}

	shared void shutdown() {
		isAlive = false;
		if (fd > 0) {
			close(fd);
			fd = 0;
			(cast()p).close();
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
				break;
			case ActionType.moved:
				for(int i = 0; i < actions.length; i++) {
					// Only match for latest operation
					if (actions[i].src in srcMap) {
						switch (actions[i].type) {
							case ActionType.changed:
							case ActionType.createDir:
								// check if the source is the prefix of the target
								string prefix = src ~ "/";
								string target = actions[i].src;
								if (prefix[0] != '.')
									prefix = "./" ~ prefix;
								if (target[0] != '.')
									target = "./" ~ target;
								string comm = commonPrefix(prefix, target);
								if (src == actions[i].src || comm.length == prefix.length) {
									// Hold operations require reading local file that is moved after the target is moved online
									pendingTargets ~= i;
									actions[i].skipped = true;
									srcMap.remove(actions[i].src);
									if (comm.length == target.length)
										actions[i].src = dst;
									else
										actions[i].src = dst ~ target[comm.length - 1 .. target.length];
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
	// map every inotify watch descriptor to its directory
	private string[int] wdToDirName;
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
	
	// The destructor should only clean up resources owned directly by this instance
	~this() {
		object.destroy(worker);
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

		// Interrupt the worker to allow removal of inotify watch descriptors
		worker.interrupt();

		// Remove all the inotify watch descriptors
		removeAll();

		// Notify the worker that the monitor has been shutdown
		worker.interrupt();
		send(false);

		inotifyMutex.lock();
		try {
			wdToDirName = null;
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
			
			// passed all potential exclusions
			// add inotify watch for this path / directory / file
			if (debugLogging) {addLogEntry("Calling worker.addInotifyWatch() for this dirname: " ~ dirname, ["debug"]);}
			int wd = worker.addInotifyWatch(dirname);
			if (wd > 0) {
				inotifyMutex.lock();
				try {
					wdToDirName[wd] = buildNormalizedPath(dirname) ~ "/";
				} finally {
					inotifyMutex.unlock();
				}
			}
			
			// if this is a directory, recursively add this path
			if (isDir(dirname)) {
				traverseDirectory(dirname);
			}
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

		// Loop through the watch descriptors and remove
		foreach (wd, path; copy) {
			remove(wd);
		}
	}

	private void remove(int wd) {
		string dirname;
		int ret;

		inotifyMutex.lock();
		try {
			assert(wd in wdToDirName);
			dirname = wdToDirName[wd];
			ret = worker.removeInotifyWatch(wd);
			if (ret < 0) throw new MonitorException("inotify_rm_watch failed");
			wdToDirName.remove(wd);
		} finally {
			inotifyMutex.unlock();
		}

		if (verboseLogging) {addLogEntry("Stopped monitoring directory (inotify watch removed): " ~ dirname, ["verbose"]);}
	}

	// Remove the watch descriptors associated to the given path
	private void remove(const(char)[] path) {
		string[] matchingPaths;
		int[] matchingWds;

		path ~= "/";

		inotifyMutex.lock();
		try {
			foreach (wd, dirname; wdToDirName) {
				if (dirname.startsWith(path)) {
					matchingWds ~= wd;
					matchingPaths ~= dirname;
				}
			}
		} finally {
			inotifyMutex.unlock();
		}

		foreach (idx, wd; matchingWds) {
			int ret = worker.removeInotifyWatch(wd);
			if (ret < 0) throw new MonitorException("inotify_rm_watch failed");

			inotifyMutex.lock();
			try {
				wdToDirName.remove(wd);
			} finally {
				inotifyMutex.unlock();
			}

			if (verboseLogging) {addLogEntry("Stopped monitoring directory (inotify watch removed): " ~ matchingPaths[idx], ["verbose"]);}
		}
	}

	// Return the file path from an inotify event
	private string getPath(const(inotify_event)* event) {
		string path;

		inotifyMutex.lock();
		try {
			path = wdToDirName[event.wd];
		} finally {
			inotifyMutex.unlock();
		}

		if (event.len > 0) path ~= fromStringz(event.name.ptr);
		if (debugLogging) {addLogEntry("inotify path event for: " ~ path, ["debug"]);}
		return path;
	}

	// Update
	void update(bool useCallbacks = true) {
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
						// forget the directory associated to the watch descriptor
						inotifyMutex.lock();
						try {
							wdToDirName.remove(event.wd);
						} finally {
							inotifyMutex.unlock();
						}
						goto skip;
					} else if (event.mask & IN_Q_OVERFLOW) {
						throw new MonitorException("inotify queue overflow: some events may be lost");
					}

					// if the event is not to be ignored, obtain path
					path = getPath(event);
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
						if (event.mask & IN_ISDIR) addRecursive(path);
						auto from = event.cookie in cookieToPath;
						if (from) {
							cookieToPath.remove(event.cookie);
							if (useCallbacks) actionHolder.append(ActionType.moved, *from, path);
							movedNotDeleted.remove(*from); // Clear moved status
						} else {
							// Handle file moved in from outside
							if (event.mask & IN_ISDIR) {
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
					} else if (event.mask & IN_DELETE) {
						if (path in movedNotDeleted) {
							movedNotDeleted.remove(path); // Ignore delete for moved files
						} else {
							if (debugLogging) {addLogEntry("event IN_DELETE: " ~ path, ["debug"]);}
							if (useCallbacks) actionHolder.append(ActionType.deleted, path);
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
						addLogEntry("inotify event unhandled: " ~ path);
						assert(0);
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

			// Assume that the items moved outside the watched directory have been deleted
			foreach (cookie, path; cookieToPath) {
				if (debugLogging) {addLogEntry("Deleting cookie|watch (post loop): " ~ path, ["debug"]);}
				if (useCallbacks) onDelete(path);
				remove(path);
				cookieToPath.remove(cookie);
			}
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

}
