// What is this module called?
module monitor;

// What does this module require to function?
import core.stdc.errno;
import core.stdc.stdlib;
import core.sys.linux.sys.inotify;
import core.sys.posix.poll;
import core.sys.posix.unistd;
import core.sys.posix.sys.select;
import core.time;
import std.algorithm;
import std.concurrency;
import std.exception;
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
import clientSideFiltering;

// Relevant inotify events
private immutable uint32_t mask = IN_CLOSE_WRITE | IN_CREATE | IN_DELETE | IN_MOVE | IN_IGNORED | IN_Q_OVERFLOW;

class MonitorException: ErrnoException {
    @safe this(string msg, string file = __FILE__, size_t line = __LINE__) {
        super(msg, file, line);
    }
}

shared class MonitorBackgroundWorker {
	// inotify file descriptor
	int fd;
	private bool working;

	void initialise() {
		fd = inotify_init();
		working = false;
		if (fd < 0) throw new MonitorException("inotify_init failed");
	}

	// Add this path to be monitored
	private int add(string pathname) {
		int wd = inotify_add_watch(fd, toStringz(pathname), mask);
		if (wd < 0) {
			if (errno() == ENOSPC) {
				// Get the current value
				ulong maxInotifyWatches = to!int(strip(readText("/proc/sys/fs/inotify/max_user_watches")));
				log.log("The user limit on the total number of inotify watches has been reached.");
				log.log("Your current limit of inotify watches is: ", maxInotifyWatches);
				log.log("It is recommended that you change the max number of inotify watches to at least double your existing value.");
				log.log("To change the current max number of watches to " , (maxInotifyWatches * 2) , " run:");
				log.log("EXAMPLE: sudo sysctl fs.inotify.max_user_watches=", (maxInotifyWatches * 2));
			}
			if (errno() == 13) {
				log.vlog("WARNING: inotify_add_watch failed - permission denied: ", pathname);
			}
			// Flag any other errors
			log.error("ERROR: inotify_add_watch failed: ", pathname);
			return wd;
		}
		
		// Add path to inotify watch - required regardless if a '.folder' or 'folder'
		log.vdebug("inotify_add_watch successfully added for: ", pathname);
		
		// Do we log that we are monitoring this directory?
		if (isDir(pathname)) {
			// Log that this is directory is being monitored
			log.vlog("Monitoring directory: ", pathname);
		}
		return wd;
	}

	int remove(int wd) {
		return inotify_rm_watch(fd, wd);
	}

	bool isWorking() {
		return working;
	}

	void watch(Tid callerTid) {
		// On failure, send -1 to caller
		int res;

		// wait for the caller to be ready
		int isAlive = receiveOnly!int();

		while (isAlive) {
			fd_set fds;
			FD_ZERO (&fds);
			FD_SET(fd, &fds);
			
			working = true;
			res = select(FD_SETSIZE, &fds, null, null, null);

			if(res == -1) {
				if(errno() == EINTR) {
					// Received an interrupt signal but no events are available
					// try update work staus and directly watch again
					receiveTimeout(dur!"seconds"(1), (int msg) {
						isAlive = msg;
					});
				} else {
					// Error occurred, tell caller to terminate.
					callCaller(callerTid, -1);
					working = false;
					break;
				}
			} else {
				// Wake up caller
				callCaller(callerTid, 1);
				// Wait for the caller to be ready
				isAlive = receiveOnly!int();
			}
		}
	}

	void callCaller(Tid callerTid, int msg) {
		working = false;
		callerTid.send(msg);
	}

	void shutdown() {
		if (fd > 0) {
			close(fd);
			fd = 0;
		}
	}
}


void startMonitorJob(shared(MonitorBackgroundWorker) worker, Tid callerTid)
{
	try {
    	worker.watch(callerTid);
	} catch (OwnerTerminated error) {
		// caller is terminated
	}
	worker.shutdown();
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
	
	// Configure Private Class Variables
	shared(MonitorBackgroundWorker) worker;
	// map every inotify watch descriptor to its directory
	private string[int] wdToDirName;
	// map the inotify cookies of move_from events to their path
	private string[int] cookieToPath;
	// buffer to receive the inotify events
	private void[] buffer;

	// Configure function delegates
	void delegate(string path) onDirCreated;
	void delegate(string path) onFileChanged;
	void delegate(string path) onDelete;
	void delegate(string from, string to) onMove;
	
	// Configure the class varaible to consume the application configuration including selective sync
	this(ApplicationConfig appConfig, ClientSideFiltering selectiveSync) {
		this.appConfig = appConfig;
		this.selectiveSync = selectiveSync;
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
		worker = new shared(MonitorBackgroundWorker);
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
	}

	// Shutdown the monitor class
	void shutdown() {
		if(!initialised)
			return;
		worker.shutdown();
		wdToDirName = null;
	}

	// Recursivly add this path to be monitored
	private void addRecursive(string dirname) {
		// skip non existing/disappeared items
		if (!exists(dirname)) {
			log.vlog("Not adding non-existing/disappeared directory: ", dirname);
			return;
		}

		// Skip the monitoring of any user filtered items
		if (dirname != ".") {
			// Is the directory name a match to a skip_dir entry?
			// The path that needs to be checked needs to include the '/'
			// This due to if the user has specified in skip_dir an exclusive path: '/path' - that is what must be matched
			if (isDir(dirname)) {
				if (selectiveSync.isDirNameExcluded(dirname.strip('.'))) {
					// dont add a watch for this item
					log.vdebug("Skipping monitoring due to skip_dir match: ", dirname);
					return;
				}
			}
			if (isFile(dirname)) {
				// Is the filename a match to a skip_file entry?
				// The path that needs to be checked needs to include the '/'
				// This due to if the user has specified in skip_file an exclusive path: '/path/file' - that is what must be matched
				if (selectiveSync.isFileNameExcluded(dirname.strip('.'))) {
					// dont add a watch for this item
					log.vdebug("Skipping monitoring due to skip_file match: ", dirname);
					return;
				}
			}
			// is the path exluded by sync_list?
			if (selectiveSync.isPathExcludedViaSyncList(buildNormalizedPath(dirname))) {
				// dont add a watch for this item
				log.vdebug("Skipping monitoring due to sync_list match: ", dirname);
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
				log.vlog("Skipping watching path - .nosync found & --check-for-nosync enabled: ", buildNormalizedPath(dirname));
				return;
			}
		}

		if (isDir(dirname)) {
			// This is a directory			
			// is the path exluded if skip_dotfiles configured and path is a .folder?
			if ((selectiveSync.getSkipDotfiles()) && (isDotFile(dirname))) {
				// dont add a watch for this directory
				return;
			}
		}
		
		// passed all potential exclusions
		// add inotify watch for this path / directory / file
		log.vdebug("Calling add() for this dirname: ", dirname);
		int wd = worker.add(dirname);
		if (wd > 0) {
			wdToDirName[wd] = buildNormalizedPath(dirname) ~ "/";
		}
		
		// if this is a directory, recursivly add this path
		if (isDir(dirname)) {
			// try and get all the directory entities for this path
			try {
				auto pathList = dirEntries(dirname, SpanMode.shallow, false);
				foreach(DirEntry entry; pathList) {
					if (entry.isDir) {
						log.vdebug("Calling addRecursive() for this directory: ", entry.name);
						addRecursive(entry.name);
					}
				}
			// catch any error which is generated
			} catch (std.file.FileException e) {
				// Standard filesystem error
				displayFileSystemErrorMessage(e.msg, getFunctionName!({}));
				return;
			} catch (Exception e) {
				// Issue #1154 handling
				// Need to check for: Failed to stat file in error message
				if (canFind(e.msg, "Failed to stat file")) {
					// File system access issue
					log.error("ERROR: The local file system returned an error with the following message:");
					log.error("  Error Message: ", e.msg);
					log.error("ACCESS ERROR: Please check your UID and GID access to this file, as the permissions on this file is preventing this application to read it");
					log.error("\nFATAL: Exiting application to avoid deleting data due to local file system access issues\n");
					// Must exit here
					exit(-1);
				} else {
					// some other error
					displayFileSystemErrorMessage(e.msg, getFunctionName!({}));
					return;
				}
			}
		}
	}

	// Remove a watch descriptor
	private void remove(int wd) {
		assert(wd in wdToDirName);
		int ret = worker.remove(wd);
		if (ret < 0) throw new MonitorException("inotify_rm_watch failed");
		log.vlog("Monitored directory removed: ", wdToDirName[wd]);
		wdToDirName.remove(wd);
	}

	// Remove the watch descriptors associated to the given path
	private void remove(const(char)[] path) {
		path ~= "/";
		foreach (wd, dirname; wdToDirName) {
			if (dirname.startsWith(path)) {
				int ret = worker.remove(wd);
				if (ret < 0) throw new MonitorException("inotify_rm_watch failed");
				wdToDirName.remove(wd);
				log.vlog("Monitored directory removed: ", dirname);
			}
		}
	}

	// Return the file path from an inotify event
	private string getPath(const(inotify_event)* event) {
		string path = wdToDirName[event.wd];
		if (event.len > 0) path ~= fromStringz(event.name.ptr);
		log.vdebug("inotify path event for: ", path);
		return path;
	}

	shared(MonitorBackgroundWorker) getWorker() {
		return worker;
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
			int ret = poll(&fds, 1, 0);
			if (ret == -1) throw new MonitorException("poll failed");
			else if (ret == 0) break; // no events available

			size_t length = read(worker.fd, buffer.ptr, buffer.length);
			if (length == -1) throw new MonitorException("read failed");

			int i = 0;
			while (i < length) {
				inotify_event *event = cast(inotify_event*) &buffer[i];
				string path;
				string evalPath;
				// inotify event debug
				log.vdebug("inotify event wd: ", event.wd);
				log.vdebug("inotify event mask: ", event.mask);
				log.vdebug("inotify event cookie: ", event.cookie);
				log.vdebug("inotify event len: ", event.len);
				log.vdebug("inotify event name: ", event.name);
				if (event.mask & IN_ACCESS) log.vdebug("inotify event flag: IN_ACCESS");
				if (event.mask & IN_MODIFY) log.vdebug("inotify event flag: IN_MODIFY");
				if (event.mask & IN_ATTRIB) log.vdebug("inotify event flag: IN_ATTRIB");
				if (event.mask & IN_CLOSE_WRITE) log.vdebug("inotify event flag: IN_CLOSE_WRITE");
				if (event.mask & IN_CLOSE_NOWRITE) log.vdebug("inotify event flag: IN_CLOSE_NOWRITE");
				if (event.mask & IN_MOVED_FROM) log.vdebug("inotify event flag: IN_MOVED_FROM");
				if (event.mask & IN_MOVED_TO) log.vdebug("inotify event flag: IN_MOVED_TO");
				if (event.mask & IN_CREATE) log.vdebug("inotify event flag: IN_CREATE");
				if (event.mask & IN_DELETE) log.vdebug("inotify event flag: IN_DELETE");
				if (event.mask & IN_DELETE_SELF) log.vdebug("inotify event flag: IN_DELETE_SELF");
				if (event.mask & IN_MOVE_SELF) log.vdebug("inotify event flag: IN_MOVE_SELF");
				if (event.mask & IN_UNMOUNT) log.vdebug("inotify event flag: IN_UNMOUNT");
				if (event.mask & IN_Q_OVERFLOW) log.vdebug("inotify event flag: IN_Q_OVERFLOW");
				if (event.mask & IN_IGNORED) log.vdebug("inotify event flag: IN_IGNORED");
				if (event.mask & IN_CLOSE) log.vdebug("inotify event flag: IN_CLOSE");
				if (event.mask & IN_MOVE) log.vdebug("inotify event flag: IN_MOVE");
				if (event.mask & IN_ONLYDIR) log.vdebug("inotify event flag: IN_ONLYDIR");
				if (event.mask & IN_DONT_FOLLOW) log.vdebug("inotify event flag: IN_DONT_FOLLOW");
				if (event.mask & IN_EXCL_UNLINK) log.vdebug("inotify event flag: IN_EXCL_UNLINK");
				if (event.mask & IN_MASK_ADD) log.vdebug("inotify event flag: IN_MASK_ADD");
				if (event.mask & IN_ISDIR) log.vdebug("inotify event flag: IN_ISDIR");
				if (event.mask & IN_ONESHOT) log.vdebug("inotify event flag: IN_ONESHOT");
				if (event.mask & IN_ALL_EVENTS) log.vdebug("inotify event flag: IN_ALL_EVENTS");
				
				// skip events that need to be ignored
				if (event.mask & IN_IGNORED) {
					// forget the directory associated to the watch descriptor
					wdToDirName.remove(event.wd);
					goto skip;
				} else if (event.mask & IN_Q_OVERFLOW) {
					throw new MonitorException("Inotify overflow, events missing");
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
					log.vdebug("event IN_MOVED_FROM: ", path);
					cookieToPath[event.cookie] = path;
				} else if (event.mask & IN_MOVED_TO) {
					log.vdebug("event IN_MOVED_TO: ", path);
					if (event.mask & IN_ISDIR) addRecursive(path);
					auto from = event.cookie in cookieToPath;
					if (from) {
						cookieToPath.remove(event.cookie);
						if (useCallbacks) onMove(*from, path);
					} else {
						// item moved from the outside
						if (event.mask & IN_ISDIR) {
							if (useCallbacks) onDirCreated(path);
						} else {
							if (useCallbacks) onFileChanged(path);
						}
					}
				} else if (event.mask & IN_CREATE) {
					log.vdebug("event IN_CREATE: ", path);
					if (event.mask & IN_ISDIR) {
						addRecursive(path);
						if (useCallbacks) onDirCreated(path);
					}
				} else if (event.mask & IN_DELETE) {
					log.vdebug("event IN_DELETE: ", path);
					if (useCallbacks) onDelete(path);
				} else if ((event.mask & IN_CLOSE_WRITE) && !(event.mask & IN_ISDIR)) {
					log.vdebug("event IN_CLOSE_WRITE and ...: ", path);
					if (useCallbacks) onFileChanged(path);
				} else {
					log.vdebug("event unhandled: ", path);
					assert(0);
				}

				skip:
				i += inotify_event.sizeof + event.len;
			}
			// assume that the items moved outside the watched directory have been deleted
			foreach (cookie, path; cookieToPath) {
				log.vdebug("deleting (post loop): ", path);
				if (useCallbacks) onDelete(path);
				remove(path);
				cookieToPath.remove(cookie);
			}
			// Debug Log that all inotify events are flushed
			log.vdebug("inotify events flushed");
		}
	}

	Tid watch() {
		initialised = true;
		return spawn(&startMonitorJob, worker, thisTid);
	}

	bool isWorking() {
		return worker.isWorking();
	}
}
