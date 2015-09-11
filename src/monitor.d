import core.stdc.errno: errno;
import core.stdc.string: strerror;
import core.sys.linux.sys.inotify;
import core.sys.posix.poll;
import core.sys.posix.unistd;
import std.file, std.stdio, std.string;

// relevant inotify events
private immutable uint32_t mask = IN_ATTRIB | IN_CLOSE_WRITE | IN_CREATE |
	IN_DELETE | IN_MOVE_SELF | IN_MOVE | IN_IGNORED | IN_Q_OVERFLOW;

class MonitorException: Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable next = null)
    {
        super(makeErrorMsg(msg), file, line, next);
    }

    this(string msg, Throwable next, string file = __FILE__, size_t line = __LINE__)
    {
        super(makeErrorMsg(msg), file, line, next);
    }

	private string makeErrorMsg(string msg)
	{
		return msg ~ " :" ~ fromStringz(strerror(errno())).idup;
	}
}

struct Monitor
{
	// inotify file descriptor
	private int fd;
	// map every watch descriptor to their dir
	private string[int] dirs;
	// map the inotify cookies of move_from events to their path
	private string[int] cookieToPath;
	// buffer to receive the inotify events
	private void[] buffer;

	void function(string path) onDirCreated;
	void function(string path) onFileChanged;
	void function(string path) onDelete;
	void function(string from, string to) onMove;

	@disable this(this);

	void init()
	{
		assert(onDirCreated);
		assert(onFileChanged);
		assert(onDelete);
		assert(onMove);
		fd = inotify_init();
		if (fd == -1) throw new MonitorException("inotify_init failed");
		buffer = new void[10000];
	}

	void shutdown()
	{
		if (fd > 0) close(fd);
	}

	void add(string path)
	{
		int wd = inotify_add_watch(fd, toStringz(path), mask);
		if (wd == -1) throw new MonitorException("inotify_add_watch failed");
		dirs[wd] = path ~ "/";
		writeln("Monitor directory: ", path);
	}

	void addRecursive(string path)
	{
		add(path);
		foreach(DirEntry entry; dirEntries(path, SpanMode.breadth, false)) {
			if (entry.isDir) add(entry.name);
		}
	}

	// remove a watch descriptor
	private void remove(int wd)
	{
		assert(wd in dirs);
		int ret = inotify_rm_watch(fd, wd);
		if (ret == -1) throw new MonitorException("inotify_rm_watch failed");
		writeln("Monitored directory removed: ", dirs[wd]);
		dirs.remove(wd);
	}

	// return the file path from an inotify event
	private string getPath(const(inotify_event)* event)
	{
		string path = dirs[event.wd];
		if (event.len > 0) path ~= fromStringz(event.name.ptr);
		return path;
	}

	void update()
	{
		pollfd[1] fds;
		fds[0].fd = fd;
		fds[0].events = POLLIN;
		int ret = poll(fds.ptr, 1, 15);
		if (ret == -1) throw new MonitorException("poll failed");
		else if (ret == 0) return; // no events available

		assert(fds[0].revents & POLLIN);
		size_t length = read(fds[0].fd, buffer.ptr, buffer.length);
		if (length == -1) throw new MonitorException("read failed");

		int i = 0;
		while (i < length) {
			inotify_event *event = cast(inotify_event*) &buffer[i];
			if (event.mask & IN_IGNORED) {
				// forget the path associated to the watch descriptor
				dirs.remove(event.wd);
			} else if (event.mask & IN_Q_OVERFLOW) {
				writeln("Inotify overflow, events missing");
				assert(0);
			} else if (event.mask & IN_MOVED_FROM) {
				string path = getPath(event);
				cookieToPath[event.cookie] = path;
				writeln("moved from ", path);
			} else if (event.mask & IN_MOVED_TO) {
				string path = getPath(event);
				if (event.mask & IN_ISDIR) addRecursive(path);
				auto from = event.cookie in cookieToPath;
				if (from) {
					cookieToPath.remove(event.cookie);
					onMove(*from, path);
				} else {
					if (event.mask & IN_ISDIR) {
						onDirCreated(path);
					} else {
						onFileChanged(path);
					}
				}
			} else {
				if (event.mask & IN_ISDIR) {
					if (event.mask & IN_CREATE) {
						string path = getPath(event);
						addRecursive(path);
						onDirCreated(path);
					} else if (event.mask & IN_DELETE) {
						string path = getPath(event);
						onDelete(path);
					}
				} else {
					if (event.mask & IN_ATTRIB || event.mask & IN_CLOSE_WRITE) {
						string path = getPath(event);
						onFileChanged(path);
					} else if (event.mask & IN_DELETE) {
						string path = getPath(event);
						onDelete(path);
					}
				}
			}
			i += inotify_event.sizeof + event.len;
		}
	}
}
