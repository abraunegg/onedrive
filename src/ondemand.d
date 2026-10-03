module ondemand;

// EXPERIMENTAL on-demand scaffold.
//
// This module intentionally contains no OneDrive/Graph/database/hydration logic.
// Its only purpose is to prove that a FUSE filesystem can be mounted over the
// existing sync_dir while operations continue to target the physical directory
// that existed before the mount.

import fused.fuse;

import core.stdc.errno : errno;
import core.sys.posix.fcntl : open, O_RDONLY, O_WRONLY, O_CREAT, O_EXCL, O_DIRECTORY;
import core.sys.posix.signal : kill, signal, SIGINT, SIGTERM, SIGKILL;
import core.sys.posix.sys.stat : stat, lstat, mkdir, chmod, stat_t, mode_t;
import core.sys.posix.sys.wait : waitpid, WNOHANG;
import core.sys.posix.unistd : fork, execv, close, pread, pwrite, unlink, rmdir, truncate, chown, readlink, symlink, _exit, getpid;
import core.sys.posix.utime : utime, utimbuf;
import core.sys.posix.sys.types : pid_t, uid_t, gid_t;

import std.conv : to;
import std.file : dirEntries, SpanMode;
import std.path : baseName;
import std.process : execute;
import std.stdio : stderr;
import std.string : toStringz;
import core.thread : Thread;
import core.time : dur;


class OnDemandException : Exception {
    this(string message) { super(message); }
}

final class OnDemandPassthroughOperations : Operations {
private:
    string physicalRoot;

    string physicalPath(const(char)[] fusePath) const {
        if (fusePath.length == 0 || fusePath == "/") return physicalRoot;
        // FUSE paths are rooted and begin with '/'. Appending to the retained
        // /proc/self/fd/<fd> path deliberately bypasses the FUSE mountpoint.
        return physicalRoot ~ fusePath.idup;
    }

    void throwErrno() {
        int e = errno;
        if (e == 0) e = 5; // EIO fallback
        throw new FuseException(e);
    }

public:
    this(int physicalDirectoryFd) {
        physicalRoot = "/proc/self/fd/" ~ to!string(physicalDirectoryFd);
    }

    override void getattr(const(char)[] path, ref stat_t st) {
        auto p = physicalPath(path);
        stderr.writefln("[FUSE-DEBUG] getattr path='%s' physicalPath='%s'", path, p);
        errno = 0;

        // The retained directory FD is exposed through /proc/self/fd/<fd>,
        // which is itself a symlink. For the FUSE root, follow that symlink
        // so "/" is reported as the real backing directory. For descendants,
        // retain lstat() semantics so user-created symlinks are not followed.
        int rc;
        if (path.length == 0 || path == "/") {
            rc = stat(toStringz(p), &st);
            stderr.writefln("[FUSE-DEBUG] getattr root stat rc=%s errno=%s mode=%o mtime=%s",
                rc, errno, st.st_mode, st.st_mtime);
        } else {
            rc = lstat(toStringz(p), &st);
            stderr.writefln("[FUSE-DEBUG] getattr lstat rc=%s errno=%s", rc, errno);
        }

        int savedErrno = errno;
        if (rc != 0) {
            errno = savedErrno;
            throwErrno();
        }
        stderr.writeln("[FUSE-DEBUG] getattr returning success");
    }

    override string[] readdir(const(char)[] path) {
        string[] result = [".", ".."];
        auto p = physicalPath(path);
        try {
            foreach (entry; dirEntries(p, SpanMode.shallow)) {
                result ~= baseName(entry.name);
            }
        } catch (Exception) {
            throwErrno();
        }
        return result;
    }

    override void open(const(char)[] path) {
        auto p = physicalPath(path);
        int fd = .open(toStringz(p), O_RDONLY);
        if (fd < 0) throwErrno();
        close(fd);
    }

    override ulong read(const(char)[] path, ubyte[] buf, ulong offset) {
        auto p = physicalPath(path);
        int fd = .open(toStringz(p), O_RDONLY);
        if (fd < 0) throwErrno();
        scope(exit) close(fd);
        auto n = pread(fd, buf.ptr, buf.length, cast(long)offset);
        if (n < 0) throwErrno();
        return cast(ulong)n;
    }

    override int write(const(char)[] path, in ubyte[] data, ulong offset) {
        auto p = physicalPath(path);
        int fd = .open(toStringz(p), O_WRONLY);
        if (fd < 0) throwErrno();
        scope(exit) close(fd);
        auto n = pwrite(fd, data.ptr, data.length, cast(long)offset);
        if (n < 0) throwErrno();
        return cast(int)n;
    }

    override void truncate(const(char)[] path, ulong length) {
        auto p = physicalPath(path);
        if (.truncate(toStringz(p), cast(long)length) != 0) throwErrno();
    }

    override void mknod(const(char)[] path, int mode, ulong dev) {
        // For the scaffold we only need normal file creation. FUSE commonly
        // reaches this callback for a create followed by open/write.
        auto p = physicalPath(path);
        int fd = .open(toStringz(p), O_WRONLY | O_CREAT | O_EXCL, cast(mode_t)mode);
        if (fd < 0) throwErrno();
        close(fd);
    }

    override void mkdir(const(char)[] path, uint mode) {
        auto p = physicalPath(path);
        if (.mkdir(toStringz(p), cast(mode_t)mode) != 0) throwErrno();
    }

    override void unlink(const(char)[] path) {
        auto p = physicalPath(path);
        if (.unlink(toStringz(p)) != 0) throwErrno();
    }

    override void rmdir(const(char)[] path) {
        auto p = physicalPath(path);
        if (.rmdir(toStringz(p)) != 0) throwErrno();
    }

    override void rename(const(char)[] from, const(char)[] to) {
        import core.stdc.stdio : rename;
        auto pFrom = physicalPath(from);
        auto pTo = physicalPath(to);
        if (rename(toStringz(pFrom), toStringz(pTo)) != 0) throwErrno();
    }

    override void chmod(const(char)[] path, mode_t mode) {
        auto p = physicalPath(path);
        if (.chmod(toStringz(p), mode) != 0) throwErrno();
    }

    override void chown(const(char)[] path, uid_t uid, gid_t gid) {
        auto p = physicalPath(path);
        if (.chown(toStringz(p), uid, gid) != 0) throwErrno();
    }

    override void utime(const(char)[] path, utimbuf* times) {
        auto p = physicalPath(path);
        if (.utime(toStringz(p), times) != 0) throwErrno();
    }

    override size_t readlink(const(char)[] path, ubyte[] buf) {
        auto p = physicalPath(path);
        if (buf.length == 0) return 0;
        auto n = .readlink(toStringz(p), cast(char*)buf.ptr, buf.length - 1);
        if (n < 0) throwErrno();
        return cast(size_t)n;
    }

    override void symlink(const(char)[] target, const(char)[] path) {
        auto p = physicalPath(path);
        auto t = target.idup;
        if (.symlink(toStringz(t), toStringz(p)) != 0) throwErrno();
    }

    override bool access(const(char)[] path, int mode) {
        import core.sys.posix.unistd : access;
        auto p = physicalPath(path);
        if (access(toStringz(p), mode) == 0) return true;
        throwErrno();
        return false;
    }
}

int runOnDemandFuseHelper(string physicalDirectoryFdArgument, string syncDirectory)
{
    int physicalDirectoryFd;
    try {
        physicalDirectoryFd = to!int(physicalDirectoryFdArgument);
    } catch (Exception e) {
        stderr.writefln("[FUSE-DEBUG] invalid helper physical directory fd: %s", e.msg);
        return 2;
    }

    stderr.writefln("[FUSE-DEBUG] helper process started pid=%s physicalFd=%s mountpoint='%s'",
        getpid(), physicalDirectoryFd, syncDirectory);

    try {
        auto operations = new OnDemandPassthroughOperations(physicalDirectoryFd);
        auto fuse = new Fuse("onedrive-on-demand", true, false);
        fuse.mount(operations, syncDirectory, []);
        return 0;
    } catch (Exception e) {
        stderr.writefln("[FUSE-DEBUG] helper process exception: %s", e.msg);
        return 1;
    }
}

final class OnDemand {
private:
    string syncDirectory;
    int physicalDirectoryFd = -1;
    pid_t fusePid = -1;
    bool running = false;

public:
    this(string syncDirectory) {
        this.syncDirectory = syncDirectory;
    }

    @property bool isRunning() const { return running; }
    @property pid_t childPid() const { return fusePid; }

    void start() {
        if (running) return;

        // Capture the physical directory BEFORE FUSE covers the pathname.
        physicalDirectoryFd = .open(toStringz(syncDirectory), O_RDONLY | O_DIRECTORY);
        if (physicalDirectoryFd < 0) {
            throw new OnDemandException("Unable to open physical sync_dir before FUSE mount: " ~ syncDirectory);
        }

        // Build every exec argument before fork(). The child of this already
        // multi-threaded process must do no D runtime/libfuse work before exec.
        string helperFdArgument = to!string(physicalDirectoryFd);
        auto helperExecutable = toStringz("/proc/self/exe");
        char*[] helperArguments = [
            cast(char*) helperExecutable,
            cast(char*) toStringz("--internal-on-demand-fuse-helper"),
            cast(char*) toStringz(helperFdArgument),
            cast(char*) toStringz(syncDirectory),
            null
        ];

        fusePid = fork();
        if (fusePid < 0) {
            close(physicalDirectoryFd);
            physicalDirectoryFd = -1;
            throw new OnDemandException("Unable to fork experimental FUSE helper process");
        }

        if (fusePid == 0) {
            // POSIX fork boundary: immediately replace the child image. This
            // gives FUSE a fresh D runtime rather than continuing inside the
            // multi-threaded parent's inherited runtime state.
            execv(helperExecutable, helperArguments.ptr);
            _exit(127);
        }

        // Parent retains its own descriptor for the duration of the experiment.
        // Give fusermount a brief opportunity to establish the mount before the
        // normal client continues.
        Thread.sleep(dur!"msecs"(500));
        int status;
        if (waitpid(fusePid, &status, WNOHANG) == fusePid) {
            close(physicalDirectoryFd);
            physicalDirectoryFd = -1;
            fusePid = -1;
            throw new OnDemandException("Experimental FUSE process exited before the overlay became active");
        }
        running = true;
    }

    void stop() {
        if (fusePid > 0) {
            // Explicitly unmount the overlay before terminating the child.
            // Killing a fuse_main() process is not sufficient: the kernel can
            // retain a stale FUSE mount over sync_dir after the process exits.
            try {
                auto result = execute(["fusermount3", "-u", syncDirectory]);
                if (result.status != 0) {
                    throw new OnDemandException(
                        "Unable to unmount experimental FUSE overlay from sync_dir: " ~
                        syncDirectory ~ " (fusermount3 exit status " ~
                        to!string(result.status) ~ ")");
                }
            } catch (OnDemandException e) {
                // Preserve the safety fallback below: terminate the child even
                // if userspace unmount failed, but surface the unmount failure.
                kill(fusePid, SIGTERM);
                int status;
                foreach (_; 0 .. 20) {
                    if (waitpid(fusePid, &status, WNOHANG) == fusePid) {
                        fusePid = -1;
                        break;
                    }
                    Thread.sleep(dur!"msecs"(100));
                }
                if (fusePid > 0) {
                    kill(fusePid, SIGKILL);
                    waitpid(fusePid, &status, 0);
                    fusePid = -1;
                }
                throw e;
            } catch (Exception e) {
                kill(fusePid, SIGTERM);
                int status;
                foreach (_; 0 .. 20) {
                    if (waitpid(fusePid, &status, WNOHANG) == fusePid) {
                        fusePid = -1;
                        break;
                    }
                    Thread.sleep(dur!"msecs"(100));
                }
                if (fusePid > 0) {
                    kill(fusePid, SIGKILL);
                    waitpid(fusePid, &status, 0);
                    fusePid = -1;
                }
                throw new OnDemandException(
                    "Unable to execute fusermount3 while stopping experimental FUSE overlay: " ~ e.msg);
            }

            // Successful unmount should make fuse_main() return. Wait for the
            // child to exit cleanly before releasing the retained physical FD.
            int status;
            bool exited = false;
            foreach (_; 0 .. 20) {
                if (waitpid(fusePid, &status, WNOHANG) == fusePid) {
                    exited = true;
                    break;
                }
                Thread.sleep(dur!"msecs"(100));
            }
            if (!exited) {
                kill(fusePid, SIGTERM);
                foreach (_; 0 .. 20) {
                    if (waitpid(fusePid, &status, WNOHANG) == fusePid) {
                        exited = true;
                        break;
                    }
                    Thread.sleep(dur!"msecs"(100));
                }
            }
            if (!exited) {
                kill(fusePid, SIGKILL);
                waitpid(fusePid, &status, 0);
            }
            fusePid = -1;
        }

        if (physicalDirectoryFd >= 0) {
            close(physicalDirectoryFd);
            physicalDirectoryFd = -1;
        }
        running = false;
    }
}
