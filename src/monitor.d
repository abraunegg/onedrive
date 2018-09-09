import core.sys.linux.sys.inotify;
import core.stdc.errno;
import core.sys.posix.poll, core.sys.posix.unistd;
import std.exception, std.file, std.path, std.regex, std.stdio, std.string;
import config;
import selective;
import util;
static import log;

// relevant inotify events
private immutable uint32_t mask = IN_CLOSE_WRITE | IN_CREATE | IN_DELETE |
	IN_MOVE | IN_IGNORED | IN_Q_OVERFLOW;

class MonitorException: ErrnoException
{
    @safe this(string msg, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line);
    }
}

final class Monitor
{
	// inotify file descriptor
	private int fd;
	// map every inotify watch descriptor to its directory
	private string[int] wdToDirName;
	// map the inotify cookies of move_from events to their path
	private string[int] cookieToPath;
	// buffer to receive the inotify events
	private void[] buffer;

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

	void init(Config cfg)
	{
		assert(onDirCreated && onFileChanged && onDelete && onMove);
		fd = inotify_init();
		if (fd < 0) throw new MonitorException("inotify_init failed");
		if (!buffer) buffer = new void[4096];
		addRecursive(".");
	}

	void shutdown()
	{
		if (fd > 0) close(fd);
		wdToDirName = null;
	}

	private void addRecursive(string dirname)
	{
		// skip filtered items
		if (dirname != ".") {
			if (selectiveSync.isNameExcluded(baseName(dirname))) {
				return;
			}
			if (selectiveSync.isPathExcluded(buildNormalizedPath(dirname))) {
				return;
			}
		}

		add(dirname);
		foreach(DirEntry entry; dirEntries(dirname, SpanMode.shallow, false)) {
			if (entry.isDir) {
				addRecursive(entry.name);
			}
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
			throw new MonitorException("inotify_add_watch failed");
		}
		wdToDirName[wd] = buildNormalizedPath(pathname) ~ "/";
		log.vlog("Monitor directory: ", pathname);
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

				if (event.mask & IN_IGNORED) {
					// forget the directory associated to the watch descriptor
					wdToDirName.remove(event.wd);
					goto skip;
				} else if (event.mask & IN_Q_OVERFLOW) {
					throw new MonitorException("Inotify overflow, events missing");
				}

				// skip filtered items
				path = getPath(event);
				if (selectiveSync.isNameExcluded(baseName(path))) {
					goto skip;
				}
				if (selectiveSync.isPathExcluded(path)) {
					goto skip;
				}

				if (event.mask & IN_MOVED_FROM) {
					cookieToPath[event.cookie] = path;
				} else if (event.mask & IN_MOVED_TO) {
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
					if (event.mask & IN_ISDIR) {
						addRecursive(path);
						if (useCallbacks) onDirCreated(path);
					}
				} else if (event.mask & IN_DELETE) {
					if (useCallbacks) onDelete(path);
				} else if ((event.mask & IN_CLOSE_WRITE) && !(event.mask & IN_ISDIR)) {
					if (useCallbacks) onFileChanged(path);
				} else {
					assert(0);
				}

				skip:
				i += inotify_event.sizeof + event.len;
			}
			// assume that the items moved outside the watched directory have been deleted
			foreach (cookie, path; cookieToPath) {
				if (useCallbacks) onDelete(path);
				remove(path);
				cookieToPath.remove(cookie);
			}
		}
	}
}
