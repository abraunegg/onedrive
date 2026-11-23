/*
 *  Copyright (c) 2014, Facebook, Inc.
 *  All rights reserved.
 *
 *  This source code is licensed under the Boost-style license found in the
 *  LICENSE file in the root directory of this source tree.
 */
module c.fuse.common;

/*
 * libfuse 3 bindings uplifted from paalkr/onedrive ondemand/main.
 * The ABI layout is verified for LP64 Linux with FUSE_USE_VERSION 31.
 */

import std.bitmanip : bitfields;
import std.stdint;

extern (System) {
    struct fuse_conn_info
    {
        uint proto_major;
        uint proto_minor;
        uint max_write;
        uint max_read;
        uint max_readahead;
        uint capable;
        uint want;
        uint max_background;
        uint congestion_threshold;
        uint time_gran;
        uint[22] reserved;
    }

    struct fuse_file_info
    {
        int flags;
        mixin(bitfields!(
            uint, "writepage", 1,
            uint, "direct_io", 1,
            uint, "keep_cache", 1,
            uint, "flush", 1,
            uint, "nonseekable", 1,
            uint, "flock_release", 1,
            uint, "cache_readdir", 1,
            uint, "noflush", 1,
            uint, "padding", 24));
        uint padding2;
        uint64_t fh;
        uint64_t lock_owner;
        uint32_t poll_events;
    }

    static if (size_t.sizeof == 8)
    {
        static assert(fuse_conn_info.sizeof == 128);
        static assert(fuse_conn_info.time_gran.offsetof == 36);
        static assert(fuse_conn_info.reserved.offsetof == 40);
        static assert(fuse_file_info.sizeof == 40);
        static assert(fuse_file_info.padding2.offsetof == 8);
        static assert(fuse_file_info.fh.offsetof == 16);
        static assert(fuse_file_info.lock_owner.offsetof == 24);
        static assert(fuse_file_info.poll_events.offsetof == 32);
    }
}
