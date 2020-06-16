import core.sys.linux.sys.inotify;
import core.stdc.errno;
import core.sys.posix.poll, core.sys.posix.unistd;
import std.exception, std.file, std.path, std.regex, std.stdio, std.string, std.algorithm.mutation;
import config;
import selective;
import util;
static import log;

// relevant inotify events
private immutable uint32_t mask = IN_CLOSE_WRITE | IN_CREATE | IN_DELETE | IN_MOVE | IN_IGNORED | IN_Q_OVERFLOW;

class MonitorException: ErrnoException
{
    @safe this(string msg, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line);
    }
}

final class Monitor
{
	bool verbose;
	// inotify file descriptor
	private int fd;
	// map every inotify watch descriptor to its directory
	private string[int] wdToDirName;
	// map the inotify cookies of move_from events to their path
	private string[int] cookieToPath;
	// buffer to receive the inotify events
	private void[] buffer;
	// skip symbolic links
	bool skip_symlinks;
	// check for .nosync if enabled
	bool check_nosync;
	
	private SelectiveSync selectiveSync;

	void delegate(string path) onDirCreated;
	void delegate(string path) onFileChanged;
	void delegate(string path) onDelete;
	void delegate(string from, string to) onMove;

	this(SelectiveSync selectiveSync)
	{
		assert(selectiveSync);
		this.selectiveSync = selectiveSync;
	}

	void init(Config cfg, bool verbose, bool skip_symlinks, bool check_nosync)
	{
		this.verbose = verbose;
		this.skip_symlinks = skip_symlinks;
		this.check_nosync = check_nosync;
		
		assert(onDirCreated && onFileChanged && onDelete && onMove);
		fd = inotify_init();
		if (fd < 0) throw new MonitorException("inotify_init failed");
		if (!buffer) buffer = new void[4096];
		
		// from which point do we start watching for changes?
		string monitorPath;
		if (cfg.getValueString("single_directory") != ""){
			// single directory in use, monitor only this
			monitorPath = "./" ~ cfg.getValueString("single_directory");
		} else {
			// default 
			monitorPath = ".";
		}
		addRecursive(monitorPath);
	}

	void shutdown()
	{
		if (fd > 0) close(fd);
		wdToDirName = null;
	}

	private void addRecursive(string dirname)
	{
		// skip non existing/disappeared items
		if (!exists(dirname)) {
			log.vlog("Not adding non-existing/disappeared directory: ", dirname);
			return;
		}

		// skip monitoring any filtered items
		if (dirname != ".") {
			// is the directory name a match to a skip_dir entry?
			if (selectiveSync.isDirNameExcluded(dirname.strip('.').strip('/'))) {
				// dont add a watch for this item
				log.vdebug("Skipping monitoring due to skip_dir match: ", dirname);
				return;
			}
			// is the filename a match to a skip_file entry?
			if (selectiveSync.isFileNameExcluded(baseName(dirname))) {
				// dont add a watch for this item
				log.vdebug("Skipping monitoring due to skip_file match: ", dirname);
				return;
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
		
		// passed all potential exclusions
		add(dirname);
		try {
			auto pathList = dirEntries(dirname, SpanMode.shallow, false);
			foreach(DirEntry entry; pathList) {
				if (entry.isDir) {
					addRecursive(entry.name);
				}
			}
		} catch (std.file.FileException e) {
			log.vdebug("ERROR: ", e.msg);
			return;
		}
	}

	private void add(string pathname)
	{
		int wd = inotify_add_watch(fd, toStringz(pathname), mask);
		if (wd < 0) {
			if (errno() == ENOSPC) {
				log.log("The user limit on the total number of inotify watches has been reached.");
				log.log("To see the current max number of watches run:");
				log.log("sysctl fs.inotify.max_user_watches");
				log.log("To change the current max number of watches to 524288 run:");
				log.log("sudo sysctl fs.inotify.max_user_watches=524288");
			}
			if (errno() == 13) {
				if ((selectiveSync.getSkipDotfiles()) && (selectiveSync.isDotFile(pathname))) {
					// no misleading output that we could not add a watch due to permission denied
					return;
				} else {
					log.vlog("WARNING: inotify_add_watch failed - permission denied: ", pathname);
					return;
				}
			}
			// Flag any other errors
			log.error("ERROR: inotify_add_watch failed: ", pathname);
			return;
		}
		
		// Add path to inotify watch - required regardless if a '.folder' or 'folder'
		wdToDirName[wd] = buildNormalizedPath(pathname) ~ "/";
		
		// Do we log that we are monitoring this directory?
		if (isDir(pathname)) {
			// This is a directory			
			// is the path exluded if skip_dotfiles configured and path is a .folder?
			if ((selectiveSync.getSkipDotfiles()) && (selectiveSync.isDotFile(pathname))) {
				// no misleading output that we are monitoring this directory
				return;
			}
			// Log that this is directory is being monitored
			log.vlog("Monitor directory: ", pathname);
		}
	}

	// remove a watch descriptor
	private void remove(int wd)
	{
		assert(wd in wdToDirName);
		int ret = inotify_rm_watch(fd, wd);
		if (ret < 0) throw new MonitorException("inotify_rm_watch failed");
		log.vlog("Monitored directory removed: ", wdToDirName[wd]);
		wdToDirName.remove(wd);
	}

	// remove the watch descriptors associated to the given path
	private void remove(const(char)[] path)
	{
		path ~= "/";
		foreach (wd, dirname; wdToDirName) {
			if (dirname.startsWith(path)) {
				int ret = inotify_rm_watch(fd, wd);
				if (ret < 0) throw new MonitorException("inotify_rm_watch failed");
				wdToDirName.remove(wd);
				log.vlog("Monitored directory removed: ", dirname);
			}
		}
	}

	// return the file path from an inotify event
	private string getPath(const(inotify_event)* event)
	{
		string path = wdToDirName[event.wd];
		if (event.len > 0) path ~= fromStringz(event.name.ptr);
		log.vdebug("inotify path event for: ", path);
		return path;
	}

	void update(bool useCallbacks = true)
	{
		pollfd fds = {
			fd: fd,
			events: POLLIN
		};

		while (true) {
			int ret = poll(&fds, 1, 0);
			if (ret == -1) throw new MonitorException("poll failed");
			else if (ret == 0) break; // no events available

			size_t length = read(fd, buffer.ptr, buffer.length);
			if (length == -1) throw new MonitorException("read failed");

			int i = 0;
			while (i < length) {
				inotify_event *event = cast(inotify_event*) &buffer[i];
				string path;
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
				
				// skip events that should be excluded based on application configuration
				if (selectiveSync.isDirNameExcluded(path.strip('.').strip('/'))) {
					goto skip;
				}
				if (selectiveSync.isFileNameExcluded(path.strip('.').strip('/'))) {
					goto skip;
				}
				if (selectiveSync.isPathExcludedViaSyncList(path)) {
					goto skip;
				}
				
				// handle events
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
		}
	}
}
