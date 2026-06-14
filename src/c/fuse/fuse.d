/*
 * From: https://code.google.com/p/dutils/
 *
 * Licensed under the Apache License 2.0. See
 * http://www.apache.org/licenses/LICENSE-2.0
 */
module c.fuse.fuse;
public import c.fuse.common;

import std.stdint;
import core.sys.posix.sys.statvfs;
import core.sys.posix.fcntl;
import core.sys.posix.time;
import core.sys.posix.utime;

extern (System)
{
    struct fuse;

    struct fuse_pollhandle;
    struct fuse_conn_info; /* temporary anonymous struct */
    struct fuse_dirhandle;

    alias fuse_dirh_t = fuse_dirhandle*;
    alias flock _flock;
    alias fuse_fill_dir_t =
        int function(void *buf, char *name, stat_t *stbuf, off_t off);
    alias fuse_dirfil_t =
        int function(fuse_dirh_t, const char *name, int type, ino_t ino);

    struct fuse_operations
    {
        int function(const char*, stat_t*) getattr;
        int function(const char*, char *, size_t) readlink;
        int function(const char*, fuse_dirh_t, fuse_dirfil_t) getdir;
        int function(const char*, mode_t, dev_t) mknod;
        int function(const char*, mode_t) mkdir;
        int function(const char*) unlink;
        int function(const char*) rmdir;
        int function(const char*, char*) symlink;
        int function(const char*, const char*) rename;
        int function(const char*, char*) link;
        int function(const char*, mode_t) chmod;
        int function(const char*, uid_t, gid_t) chown;
        int function(const char*, off_t) truncate;
        int function(const char*, utimbuf *) utime;
        int function(const char*, fuse_file_info *) open;
        int function(const char*, char*, size_t, off_t, fuse_file_info*) read;
        int function(const char*, char*, size_t, off_t, fuse_file_info*) write;
        int function(const char*, statvfs_t*) statfs;
        int function(const char*, fuse_file_info*) flush;
        int function(const char*, fuse_file_info*) release;
        int function(const char*, int, fuse_file_info*) fsync;
        int function(const char*, char*, char*, size_t, int) setxattr;
        int function(const char*, char*, char*, size_t) getxattr;
        int function(const char*, char*, size_t) listxattr;
        int function(const char*, char*) removexattr;
        int function(const char*, fuse_file_info*) opendir;
        int function(const char*, void*, fuse_fill_dir_t, off_t,
                fuse_file_info*) readdir;
        int function(const char*, fuse_file_info*) releasedir;
        int function(const char*, int, fuse_file_info*) fsyncdir;
        void* function(fuse_conn_info* conn) init;
        void function(void*) destroy;
        int function(const char*, int) access;
        int function(const char*, mode_t, fuse_file_info*) create;
        int function(const char*, off_t, fuse_file_info*)  ftruncate;
        int function(const char*, stat_t*, fuse_file_info*) fgetattr;
        int function(const char*, fuse_file_info*, int cmd, _flock*) lock;
        int function(const char*, const timespec) utimens;
        int function(const char*, size_t, uint64_t*) bmap;
        uint flag_nullpath_ok = 1;
        uint flag_reserved = 31;
        int function(const char*, int, void*, fuse_file_info*, uint, void*)
            ioctl;
        int function(const char*, fuse_file_info*, fuse_pollhandle*, uint*)
            poll;
    }

    struct fuse_context
    {
        /** Pointer to the fuse object */
        fuse* _fuse;

        uid_t uid; // User ID of the calling process
        gid_t gid; // Group ID of the calling process
        pid_t pid; // Thread ID of the calling process

        void* private_data; // Private filesystem data

        mode_t umask; // Umask of the calling process (introduced in version 2.8)
    }

    fuse_context* fuse_get_context();
    int fuse_main_real(int argc, char** argv, fuse_operations* op,
        size_t op_size, void* user_data);
}


/* mappping of the fuse_main macro in fuse.h */
int fuse_main(int argc, char** argv, fuse_operations* op, void* user_data)
{
    return fuse_main_real(argc, argv, op, fuse_operations.sizeof, user_data);
}