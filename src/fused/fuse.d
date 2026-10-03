/*
 *  Copyright (c) 2014, Facebook, Inc.
 *  All rights reserved.
 *
 *  This source code is licensed under the Boost-style license found in the
 *  LICENSE file in the root directory of this source tree. An additional grant
 *  of patent rights can be found in the PATENTS file in the same directory.
 *
 */
module fused.fuse;

/* reexport stat_t */
public import core.sys.posix.fcntl;
public import core.sys.posix.utime;
public import core.sys.posix.time : timespec;
public import c.fuse.fuse : fuse_config;

import std.algorithm;
import std.array;
import std.conv;
import std.stdio;
import std.string;
import std.process;
import errno = core.stdc.errno;
import core.stdc.string;
import core.sys.posix.signal;

import c.fuse.fuse;

import core.thread : thread_attachThis, thread_detachThis;
import core.sys.posix.pthread;

/**
 * libfuse is handling the thread creation and we cannot hook into it. However
 * we need to make the GC aware of the threads. So for any call to a handler
 * we check if the current thread is attached and attach it if necessary.
 */
private int threadAttached = false;
private pthread_cleanup cleanup;

extern(C) void detach(void* ptr) nothrow
{
    import std.exception;
    collectException(thread_detachThis());
}

private void attach()
{
    if (!threadAttached)
    {
        thread_attachThis();
        cleanup.push(&detach, cast(void*) null);
        threadAttached = true;
    }
}

/**
 * A template to wrap C function calls and support exceptions to indicate
 * errors.
 *
 * The template passes the Operations object to the lambda as the first
 * argument.
 */
private auto call(alias fn)()
{
    auto t = cast(Operations*) fuse_get_context().private_data;
    try
    {
        return fn(*t);
    }
    catch (FuseException fe)
    {
        /* errno is used to indicate an error to libfuse */
        stderr.writefln("[FUSE-DEBUG] callback FuseException errno=%s", fe.errno);
        errno.errno = fe.errno;
        return -fe.errno;
    }
    catch (Exception e)
    {
        stderr.writefln("[FUSE-DEBUG] callback exception: %s", e.msg);
        (*t).exception(e);
        return -errno.EIO;
    }
}

/* C calling convention compatible function wrappers to hand into libfuse which wrap
 * the call to our Operations object.
 *
 * Note that we convert our * char pointer to an array using the
 * ptr[0..len] syntax.
 */
extern(System)
{
    private int dfuse_access(const char* path, int mode)
    {
        return call!(
            (Operations t)
            {
                if(t.access(path[0..path.strlen], mode))
                {
                    return 0;
                }
                return -1;
            })();
    }

    private int dfuse_getattr(const char*  path, stat_t* st, fuse_file_info* fi)
    {
        auto dPath = path is null ? null : path[0..path.strlen];
        stderr.writefln("[FUSE-DEBUG] dfuse_getattr path='%s'", dPath);
        int rc = call!(
            (Operations t)
            {
                t.getattr(dPath, *st);
                return 0;
            })();
        stderr.writefln("[FUSE-DEBUG] dfuse_getattr return=%s", rc);
        return rc;
    }

    private int dfuse_readdir(const char* path, void* buf,
            fuse_fill_dir_t filler, off_t offset, fuse_file_info* fi,
            fuse_readdir_flags flags)
    {
        return call!(
            (Operations t)
            {
                foreach(file; t.readdir(path[0..path.strlen]))
                {
                    filler(buf, toStringz(file), null, 0, cast(fuse_fill_dir_flags) 0);
                }
                return 0;
            })();
    }

    private int dfuse_readlink(const char* path, char* buf, size_t size)
    {
        return call!(
            (Operations t)
            {
                auto length = t.readlink(path[0..path.strlen],
                    (cast(ubyte*)buf)[0..size]);
                /* Null-terminate the string and copy it over to the buffer. */
                assert(length <= size);
                buf[length] = '\0';

                return 0;
            })();
    }

    private int dfuse_open(const char* path, fuse_file_info* fi)
    {
        return call!(
            (Operations t)
            {
                t.open(path[0..path.strlen]);
                return 0;
            })();
    }

    private int dfuse_release(const char* path, fuse_file_info* fi)
    {
        return call!(
            (Operations t)
            {
                t.release(path[0..path.strlen]);
                return 0;
            })();
    }

    private int dfuse_read(const char* path, char* buf, size_t size,
                           off_t offset, fuse_file_info* fi)
    {
        /* Ensure at compile time that off_t and size_t fit into an ulong. */
        static assert(ulong.max >= size_t.max);
        static assert(ulong.max >= off_t.max);

        return call!(
            (Operations t)
            {
                auto bbuf = cast(ubyte*) buf;
                return cast(int) t.read(path[0..path.strlen], bbuf[0..size],
                    to!ulong(offset));
            })();
    }

    private int dfuse_write(const char* path, const char* data, size_t size,
                            off_t offset, fuse_file_info* fi)
    {
        static assert(ulong.max >= size_t.max);
        static assert(ulong.max >= off_t.max);

        return call!(
            (Operations t)
            {
                auto bdata = cast(const(ubyte)*) data;
                return t.write(path[0..path.strlen], bdata[0..size],
                    to!ulong(offset));
            })();
    }

    private int dfuse_truncate(const char* path, off_t length, fuse_file_info* fi)
    {
        static assert(ulong.max >= off_t.max);
        return call!(
            (Operations t)
            {
                t.truncate(path[0..path.strlen], to!ulong(length));
                return 0;
            })();
    }

    private int dfuse_mknod(const char* path, mode_t mod, dev_t dev)
    {
        static assert(ulong.max >= dev_t.max);
        static assert(uint.max >= mode_t.max);
        return call!(
            (Operations t)
            {
                t.mknod(path[0..path.strlen], mod, dev);
                return 0;
            })();
    }

    private int dfuse_unlink(const char* path)
    {
        return call!(
            (Operations t)
            {
                t.unlink(path[0..path.strlen]);
                return 0;
            })();
    }

    private int dfuse_mkdir(const char * path, mode_t mode)
    {
        static assert(uint.max >= mode_t.max);
        return call!(
            (Operations t)
            {
                t.mkdir(path[0..path.strlen], mode.to!uint);
                return 0;
            })();
    }
    private int dfuse_rmdir(const char * path)
    {
        return call!(
            (Operations t)
            {
                t.rmdir(path[0..path.strlen]);
                return 0;
            })();
    }

    private int dfuse_rename(const char* orig, const char* dest, uint flags) {
        return call!(
            (Operations t)
            {
                // The scaffold does not implement rename flags yet.
                if (flags != 0)
                    throw new FuseException(errno.EINVAL);
                t.rename(orig[0..orig.strlen], dest[0..dest.strlen]);
                return 0;
            })();
    }

    private int dfuse_chmod(const char* path, mode_t mode, fuse_file_info* fi) {
        return call!(
            (Operations t)
            {
                t.chmod(path[0 .. path.strlen], mode);
                return 0;
            }
        )();
    }

    private int dfuse_utimens(const char* path, const(timespec)* tv,
            fuse_file_info* fi) {
        return call!(
            (Operations t)
            {
                // Preserve the scaffold's existing second-resolution Operations API.
                // UTIME_NOW/UTIME_OMIT are not required for the current read-only proof.
                if (tv is null)
                {
                    t.utime(path[0 .. path.strlen], null);
                }
                else
                {
                    utimbuf times;
                    times.actime = tv[0].tv_sec;
                    times.modtime = tv[1].tv_sec;
                    t.utime(path[0 .. path.strlen], &times);
                }
                return 0;
            }
        )();
    }

    private int dfuse_symlink(const char* target, const char* link) {
        return call!(
            (Operations t)
            {
                t.symlink(target[0 .. target.strlen], link[0 .. link.strlen]);
                return 0;
            }
        );
    }

    private int dfuse_chown(const char* path, uid_t uid, gid_t gid, fuse_file_info* fi) {
        return call!(
            (Operations t)
            {
                t.chown(path[0 .. path.strlen], uid, gid);
                return 0;
            }
        );
    }

    private void* dfuse_init(fuse_conn_info* conn, fuse_config* cfg)
    {
        auto t = cast(Operations*) fuse_get_context().private_data;
        (*t).initialize();
        return t;
    }

    private void dfuse_destroy(void* data)
    {
        // libfuse3 has completed filesystem teardown. The scaffold runs FUSE
        // in its forked child, so allow fuse_main() to return normally.
    }
} /* extern(C) */

export class FuseException : Exception
{
    public int errno;
    this(int errno, string file = __FILE__, size_t line = __LINE__,
         Throwable next = null)
    {
        super("Fuse Exception", file, line, next);
        this.errno = errno;
    }
}

/**
 * An object oriented wrapper around fuse_operations.
 */
export class Operations
{
    /**
     * Runs on filesystem creation
     */
    void initialize()
    {
    }

    /**
     * Called to get a stat(2) structure for a path.
     */
    void getattr(const(char)[] path, ref stat_t stat)
    {
        throw new FuseException(errno.EOPNOTSUPP);
    }

    /**
     * Read path into the provided buffer beginning at offset.
     *
     * Params:
     *   path   = The path to the file to read.
     *   buf    = The buffer to read the data into.
     *   offset = An offset to start reading at.
     * Returns: The amount of bytes read.
     */
    ulong read(const(char)[] path, ubyte[] buf, ulong offset)
    {
        throw new FuseException(errno.EOPNOTSUPP);
    }

    /**
     * Write the given data to the file.
     *
     * Params:
     *   path   = The path to the file to write.
     *   buf    = A read-only buffer containing the data to write.
     *   offset = An offset to start writing at.
     * Returns: The amount of bytes written.
     */
    int write(const(char)[] path, in ubyte[] data, ulong offset)
    {
        throw new FuseException(errno.EOPNOTSUPP);
    }

    /**
     * Truncate a file to the given length.
     * Params:
     *   path   = The path to the file to truncate.
     *   length = Truncate file to this given length.
     */
    void truncate(const(char)[] path, ulong length)
    {
        throw new FuseException(errno.EOPNOTSUPP);
    }

    /**
     * Returns a list of files and directory names in the given folder. Note
     * that you have to return . and ..
     *
     * Params:
     *   path = The path to the directory.
     * Returns: An array of filenames.
     */
    string[] readdir(const(char)[] path)
    {
        throw new FuseException(errno.EOPNOTSUPP);
    }

    /**
     * Reads the link identified by path into the given buffer.
     *
     * Params:
     *   path = The path to the directory.
     */
    size_t readlink(const(char)[] path, ubyte[] buf)
    {
        throw new FuseException(errno.EOPNOTSUPP);
    }

    /**
     * Determine if the user has access to the given path.
     *
     * Params:
     *   path = The path to check.
     *   mode = A flag indicating what to check for. See access(2) for
     *          supported modes.
     * Returns: True on success otherwise false.
     */
    bool access(const(char)[] path, int mode)
    {
        throw new FuseException(errno.EOPNOTSUPP);
    }

    /**
     * Changes the mode of a path.
     *
     * Params:
     *   path = The path to check.
     *   mode = The mode to set.
     */
    void chmod(const(char)[] path, mode_t mode)
    {
        throw new FuseException(errno.EOPNOTSUPP);
    }

    /**
     * Sets access and modification time.
     *
     * Params:
     *   path = The path to modify.
     *   time = The time to set.
     */
    void utime(const(char)[] path, utimbuf* time)
    {
        throw new FuseException(errno.EOPNOTSUPP);
    }

    /**
     * Creates a symlink.
     *
     * Params:
     *   path = The path to create.
     *   target = The target of the link.
     */
    void symlink(const(char)[] target, const(char)[] path)
    {
        throw new FuseException(errno.EOPNOTSUPP);
    }

    /**
     * Changes ownership of a file.
     *
     * Params:
     *   path = Path to the file.
     *   uid = New user ID.
     *   gid = New group ID.
     */
    void chown(const(char)[] path, uid_t uid, gid_t gid)
    {
        throw new FuseException(errno.EOPNOTSUPP);
    }

    void mknod(const(char)[] path, int mod, ulong dev)
    {
        throw new FuseException(errno.EOPNOTSUPP);
    }

    void unlink(const(char)[] path)
    {
        throw new FuseException(errno.EOPNOTSUPP);
    }

    void mkdir(const(char)[] path, uint mode)
    {
        throw new FuseException(errno.EOPNOTSUPP);
    }

    void rmdir(const(char)[] path)
    {
        throw new FuseException(errno.EOPNOTSUPP);
    }

    void rename(const(char)[] orig, const(char)[] dest)
    {
        throw new FuseException(errno.EOPNOTSUPP);
    }

    void open(const(char)[] path)
    {
        throw new FuseException(errno.EOPNOTSUPP);
    }

    void release(const(char)[] path)
    {
        throw new FuseException(errno.EOPNOTSUPP);
    }

    void exception(Exception e)
    {
    }
}

/**
 * A wrapper around fuse_main()
 */
export class Fuse
{
private:
    bool foreground;
    bool threaded;
    string fsname;
    int pid;

public:
    this(string fsname)
    {
        this(fsname, false, true);
    }

    this(string fsname, bool foreground, bool threaded)
    {
        this.fsname = fsname;
        this.foreground = foreground;
        this.threaded = threaded;
    }

    void mount(Operations ops, const string mountpoint, string[] mountopts)
    {
        // Build only the arguments parsed by fuse_new(); mountpoint is supplied
        // separately to fuse_mount().
        // Enable libfuse protocol diagnostics for the scaffold. This is
        // intentionally diagnostic-only: no callback or lifecycle semantics
        // are changed.
        string[] args = [this.fsname, "-d"];
        if (mountopts.length > 0)
            args ~= format("-o%s", mountopts.join(","));

        debug writefln("fuse arguments s=(%s)", args);

        fuse_operations fops;
        fops.init = &dfuse_init;
        fops.access = &dfuse_access;
        fops.getattr = &dfuse_getattr;
        fops.readdir = &dfuse_readdir;
        fops.open = &dfuse_open;
        fops.release = &dfuse_release;
        fops.read = &dfuse_read;
        fops.write = &dfuse_write;
        fops.truncate = &dfuse_truncate;
        fops.readlink = &dfuse_readlink;
        fops.destroy = &dfuse_destroy;
        fops.mknod = &dfuse_mknod;
        fops.unlink = &dfuse_unlink;
        fops.mkdir = &dfuse_mkdir;
        fops.rmdir = &dfuse_rmdir;
        fops.rename = &dfuse_rename;
        fops.chmod = &dfuse_chmod;
        fops.utimens = &dfuse_utimens;
        fops.symlink = &dfuse_symlink;
        fops.chown = &dfuse_chown;

        auto cargs = array(map!(a => cast(char*) toStringz(a))(args)) ~ null;
        fuse_args fargs = fuse_args(cast(int) args.length, cargs.ptr, 0);

        stderr.writeln("[FUSE-DEBUG] creating explicit libfuse3 session");
        auto f = fuse_new_31(&fargs, &fops, fuse_operations.sizeof, &ops);
        if (f is null)
            throw new Exception("fuse_new_31 failed");

        scope(exit) fuse_destroy(f);

        stderr.writefln("[FUSE-DEBUG] mounting explicit libfuse3 session at '%s'", mountpoint);
        if (fuse_mount(f, toStringz(mountpoint)) != 0)
            throw new Exception("fuse_mount failed");

        scope(exit) fuse_unmount(f);

        this.pid = thisProcessID();
        stderr.writeln("[FUSE-DEBUG] entering explicit fuse_loop request loop");
        int fuseResult = fuse_loop(f);
        stderr.writefln("[FUSE-DEBUG] explicit fuse_loop exited result=%s", fuseResult);

        if (fuseResult != 0)
            throw new Exception("fuse_loop failed");
    }

    void exit()
    {
        kill(this.pid, SIGINT);
    }
}
