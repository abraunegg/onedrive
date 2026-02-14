/*
 *  Copyright (c) 2014, Facebook, Inc.
 *  All rights reserved.
 *
 *  This source code is licensed under the Boost-style license found in the
 *  LICENSE file in the root directory of this source tree. An additional grant
 *  of patent rights can be found in the PATENTS file in the same directory.
 *
 */
module c.fuse.common;

import std.stdint;

extern (System) {
    static assert(fuse_conn_info.sizeof == 128);
    struct fuse_conn_info
    {
        /**
         * Major version of the protocol (read-only)
         */
        uint proto_major;

        /**
         * Minor version of the protocol (read-only)
         */
        uint proto_minor;

        /**
         * Is asynchronous read supported (read-write)
         */
        uint async_read;

        /**
         * Maximum size of the write buffer
         */
        uint max_write;

        /**
         * Maximum readahead
         */
        uint max_readahead;

        /**
         * Capability flags, that the kernel supports
         */
        uint capable;

        /**
         * Capability flags, that the filesystem wants to enable
         */
        uint want;

        /**
         * Maximum number of backgrounded requests
         */
        uint max_background;

        /**
         * Kernel congestion threshold parameter
         */
        uint congestion_threshold;

        /**
         * For future use.
         */
        uint[23] reserved;
    }

    static assert(fuse_file_info.sizeof == 64);
    struct fuse_file_info
    {
        /** Open flags. Available in open() and release() */
        int flags;

        /** Old file handle, don't use */
        ulong fh_old;

        /** In case of a write operation indicates if this was caused by a
          writepage */
        int writepage;

        /** Can be filled in by open, to use direct I/O on this file.
          Introduced in version 2.4 */
        uint direct_io = 1;

        /** Can be filled in by open, to indicate, that cached file data
          need not be invalidated.  Introduced in version 2.4 */
        uint keep_cache = 1;

        /** Indicates a flush operation.  Set in flush operation, also
          maybe set in highlevel lock operation and lowlevel release
          operation. Introduced in version 2.6 */
        uint flush = 1;

        /** Can be filled in by open, to indicate that the file is not
          seekable.  Introduced in version 2.8 */
        uint nonseekable = 1;

        /* Indicates that flock locks for this file should be
           released.  If set, lock_owner shall contain a valid value.
           May only be set in ->release().  Introduced in version
           2.9 */
        uint flock_release = 1;

        /** Padding.  Do not use*/
        uint padding = 27;

        /** File handle.  May be filled in by filesystem in open().
          Available in all other file operations */
        uint64_t fh;

        /** Lock owner id.  Available in locking operations and flush */
        uint64_t lock_owner;
    }
}