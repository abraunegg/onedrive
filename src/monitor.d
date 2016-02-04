import core.sys.linux.sys.inotify;
import core.stdc.errno;
import core.sys.posix.poll;
import core.sys.posix.unistd;
import std.exception, std.file, std.path, std.regex, std.stdio, std.string;
import config, util;

// relevant inotify events
private immutable uint32_t mask = IN_ATTRIB | IN_CLOSE_WRITE | IN_CREATE |
	IN_DELETE | IN_MOVE | IN_IGNORED | IN_Q_OVERFLOW;

class MonitorException: ErrnoException
{
    @safe this(string msg, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line);
    }
}

struct Monitor
{
	bool verbose;
	// regex that match files/dirs to skip
	private Regex!char skipDir, skipFile;
	// inotify file descriptor
	private int fd;
	// map every inotify watch descriptor to its directory
	private string[int] wdToDirName;
	// map the inotify cookies of move_from events to their path
	private string[int] cookieToPath;
	// buffer to receive the inotify events
	private void[] buffer;

	void delegate(string path) onDirCreated;
	void delegate(string path) onFileChanged;
	void delegate(string path) onDelete;
	void delegate(string from, string to) onMove;

	@disable this(this);

	void init(Config cfg, bool verbose)
	{
		this.verbose = verbose;
		skipDir = wild2regex(cfg.get("skip_dir"));
		skipFile = wild2regex(cfg.get("skip_file"));
		fd = inotify_init();
		if (fd == -1) throw new MonitorException("inotify_init failed");
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
		if (matchFirst(dirname, skipDir).empty) {
			add(dirname);
			foreach(DirEntry entry; dirEntries(dirname, SpanMode.shallow, false)) {
				if (entry.isDir) {
					addRecursive(entry.name);
				}
			}
		}
	}

	private void add(string dirname)
	{
		int wd = inotify_add_watch(fd, toStringz(dirname), mask);
		if (wd == -1) {
                    if (errno() == ENOSPC) {
                        writeln("The maximum number of inotify wathches is probably too low.");
                        writeln("");
                        writeln("To see the current max number of watches run");
                        writeln("");
                        writeln("   sysctl fs.inotify.max_user_watches");
                        writeln("");
                        writeln("To change the current max number of watches to 32768 run");
                        writeln("");
                        writeln("   sudo sysctl fs.inotify.max_user_watches=32768");
                        writeln("");
                    }
                    throw new MonitorException("inotify_add_watch failed");
                }
		wdToDirName[wd] = dirname ~ "/";
		if (verbose) writeln("Monitor directory: ", dirname);
	}

	// remove a watch descriptor
	private void remove(int wd)
	{
		assert(wd in wdToDirName);
		int ret = inotify_rm_watch(fd, wd);
		if (ret == -1) throw new MonitorException("inotify_rm_watch failed");
		if (verbose) writeln("Monitored directory removed: ", wdToDirName[wd]);
		wdToDirName.remove(wd);
	}

	// remove the watch descriptors associated to the given path
	private void remove(const(char)[] path)
	{
		path ~= "/";
		foreach (wd, dirname; wdToDirName) {
			if (dirname.startsWith(path)) {
				int ret = inotify_rm_watch(fd, wd);
				if (ret == -1) throw new MonitorException("inotify_rm_watch failed");
				wdToDirName.remove(wd);
				if (verbose) writeln("Monitored directory removed: ", dirname);
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
		assert(onDirCreated && onFileChanged && onDelete && onMove);
		pollfd[1] fds = void;
		fds[0].fd = fd;
		fds[0].events = POLLIN;

		while (true) {
			int ret = poll(fds.ptr, 1, 0);
			if (ret == -1) throw new MonitorException("poll failed");
			else if (ret == 0) break; // no events available

			assert(fds[0].revents & POLLIN);
			size_t length = read(fds[0].fd, buffer.ptr, buffer.length);
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
				if (event.mask & IN_ISDIR) {
					if (!matchFirst(path, skipDir).empty) {
						goto skip;
					}
				} else {
					if (!matchFirst(path, skipFile).empty) {
						goto skip;
					}
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
				} else if (event.mask & IN_ATTRIB || event.mask & IN_CLOSE_WRITE) {
					if (!(event.mask & IN_ISDIR)) {
						if (useCallbacks) onFileChanged(path);
					}
				} else {
					writeln("Unknow inotify event: ", format("%#x", event.mask));
				}

				skip:
				i += inotify_event.sizeof + event.len;
			}
			// assume that the items moved outside the watched directory has been deleted
			foreach (cookie, path; cookieToPath) {
				if (useCallbacks) onDelete(path);
				remove(path);
				cookieToPath.remove(cookie);
			}
		}
	}
}
