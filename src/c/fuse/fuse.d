/*
 * From: https://code.google.com/p/dutils/
 * Licensed under the Apache License 2.0.
 */
module c.fuse.fuse;
public import c.fuse.common;

/*
 * libfuse 3 high-level API binding uplifted from paalkr/onedrive
 * ondemand/main. ABI layout is verified for LP64 Linux with
 * FUSE_USE_VERSION 31.
 */

import std.stdint;
import core.sys.posix.sys.stat;
import core.sys.posix.sys.statvfs;
import core.sys.posix.sys.types;
import core.sys.posix.fcntl;
import core.sys.posix.time;

extern (System)
{
    struct fuse;
    struct fuse_pollhandle;
    struct fuse_bufvec;
    alias flock _flock;

    enum fuse_readdir_flags : int { FUSE_READDIR_PLUS = (1 << 0) }
    enum fuse_fill_dir_flags : int { FUSE_FILL_DIR_PLUS = (1 << 1) }

    alias fuse_fill_dir_t = int function(void* buf, const(char)* name,
        const(stat_t)* stbuf, off_t off, fuse_fill_dir_flags flags);

    struct fuse_config
    {
        int set_gid;
        uint gid;
        int set_uid;
        uint uid;
        int set_mode;
        uint umask;
        double entry_timeout;
        double negative_timeout;
        double attr_timeout;
        int intr;
        int intr_signal;
        int remember;
        int hard_remove;
        int use_ino;
        int readdir_ino;
        int direct_io;
        int kernel_cache;
        int auto_cache;
        int no_rofd_flush;
        int ac_attr_timeout_set;
        double ac_attr_timeout;
        int nullpath_ok;
        int show_help;
        char* modules;
        int debug_;
    }

    struct fuse_operations
    {
        int function(const(char)*, stat_t*, fuse_file_info*) getattr;
        int function(const(char)*, char*, size_t) readlink;
        int function(const(char)*, mode_t, dev_t) mknod;
        int function(const(char)*, mode_t) mkdir;
        int function(const(char)*) unlink;
        int function(const(char)*) rmdir;
        int function(const(char)*, const(char)*) symlink;
        int function(const(char)*, const(char)*, uint flags) rename;
        int function(const(char)*, const(char)*) link;
        int function(const(char)*, mode_t, fuse_file_info*) chmod;
        int function(const(char)*, uid_t, gid_t, fuse_file_info*) chown;
        int function(const(char)*, off_t, fuse_file_info*) truncate;
        int function(const(char)*, fuse_file_info*) open;
        int function(const(char)*, char*, size_t, off_t, fuse_file_info*) read;
        int function(const(char)*, const(char)*, size_t, off_t, fuse_file_info*) write;
        int function(const(char)*, statvfs_t*) statfs;
        int function(const(char)*, fuse_file_info*) flush;
        int function(const(char)*, fuse_file_info*) release;
        int function(const(char)*, int, fuse_file_info*) fsync;
        int function(const(char)*, const(char)*, const(char)*, size_t, int) setxattr;
        int function(const(char)*, const(char)*, char*, size_t) getxattr;
        int function(const(char)*, char*, size_t) listxattr;
        int function(const(char)*, const(char)*) removexattr;
        int function(const(char)*, fuse_file_info*) opendir;
        int function(const(char)*, void*, fuse_fill_dir_t, off_t, fuse_file_info*, fuse_readdir_flags) readdir;
        int function(const(char)*, fuse_file_info*) releasedir;
        int function(const(char)*, int, fuse_file_info*) fsyncdir;
        void* function(fuse_conn_info*, fuse_config*) init;
        void function(void*) destroy;
        int function(const(char)*, int) access;
        int function(const(char)*, mode_t, fuse_file_info*) create;
        int function(const(char)*, fuse_file_info*, int, _flock*) lock;
        int function(const(char)*, const(timespec)*, fuse_file_info*) utimens;
        int function(const(char)*, size_t, uint64_t*) bmap;
        int function(const(char)*, int, void*, fuse_file_info*, uint, void*) ioctl;
        int function(const(char)*, fuse_file_info*, fuse_pollhandle*, uint*) poll;
        int function(const(char)*, fuse_bufvec*, off_t, fuse_file_info*) write_buf;
        int function(const(char)*, fuse_bufvec**, size_t, off_t, fuse_file_info*) read_buf;
        int function(const(char)*, fuse_file_info*, int) flock;
        int function(const(char)*, int, off_t, off_t, fuse_file_info*) fallocate;
        ssize_t function(const(char)*, fuse_file_info*, off_t, const(char)*, fuse_file_info*, off_t, size_t, int) copy_file_range;
        off_t function(const(char)*, off_t, int, fuse_file_info*) lseek;
    }

    struct fuse_context
    {
        fuse* _fuse;
        uid_t uid;
        gid_t gid;
        pid_t pid;
        void* private_data;
        mode_t umask;
    }

    static if (size_t.sizeof == 8)
    {
        static assert(fuse_config.sizeof == 128);
        static assert(fuse_config.entry_timeout.offsetof == 24);
        static assert(fuse_config.ac_attr_timeout.offsetof == 96);
        static assert(fuse_config.modules.offsetof == 112);
        static assert(fuse_config.debug_.offsetof == 120);
        static assert(fuse_operations.sizeof == 336);
        static assert(fuse_operations.init.offsetof == 216);
        static assert(fuse_operations.utimens.offsetof == 256);
        static assert(fuse_operations.lseek.offsetof == 328);
        static assert(fuse_context.sizeof == 40);
        static assert(fuse_context.private_data.offsetof == 24);
    }
    struct fuse_session;

    struct fuse_args
    {
        int argc;
        char** argv;
        int allocated;
    }

    fuse* fuse_new(fuse_args* args, const(fuse_operations)* op,
        size_t op_size, void* private_data);
    int fuse_mount(fuse* f, const(char)* mountpoint);
    int fuse_loop(fuse* f);
    void fuse_unmount(fuse* f);
    void fuse_destroy(fuse* f);

    fuse_context* fuse_get_context();
    int fuse_main_real(int argc, char** argv, const(fuse_operations)* op,
        size_t op_size, void* private_data);
}

int fuse_main(int argc, char** argv, const(fuse_operations)* op, void* private_data)
{
    return fuse_main_real(argc, argv, op, fuse_operations.sizeof, private_data);
}
