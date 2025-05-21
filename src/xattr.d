module xattr;

import core.sys.posix.sys.types;
import core.stdc.errno;
import core.stdc.stdlib;
import core.stdc.string;
import core.stdc.stdio;
import std.string;
import std.conv;

version (linux) {
    extern (C) {
        int setxattr(const(char)* path, const(char)* name, const(void)* value, size_t size, int flags);
        ssize_t getxattr(const(char)* path, const(char)* name, void* value, size_t size);
    }
}

version (FreeBSD) {
    extern (C) {
        int extattr_set_file(const(char)* path, int attrnamespace, const(char)* name, const(void)* value, size_t size);
        ssize_t extattr_get_file(const(char)* path, int attrnamespace, const(char)* name, void* value, size_t size);
    }

    enum EXTATTR_NAMESPACE_USER = 1;
}

class XAttrException : Exception {
    this(string message) {
        super(message);
    }
}

// Sets an extended attribute for a given file.
// Throws `XAttrException` on failure.
void setXAttr(string filePath, string attrName, string attrValue) {
    version (linux) {
        int result = setxattr(filePath.toStringz(), attrName.toStringz(), cast(const(void)*)attrValue.ptr, attrValue.length, 0);
        if (result != 0) {
            throw new XAttrException("Failed to set xattr '" ~ attrName ~ "' on '" ~ filePath ~ "': " ~ to!string(strerror(errno)));
        }
    } else version (FreeBSD) {
        int result = extattr_set_file(filePath.toStringz(), EXTATTR_NAMESPACE_USER, attrName.toStringz(), cast(const(void)*)attrValue.ptr, attrValue.length);
        if (result < 0) {
            throw new XAttrException("Failed to set xattr '" ~ attrName ~ "' on '" ~ filePath ~ "': " ~ to!string(strerror(errno)));
        }
    } else {
        throw new XAttrException("xattr not supported on this platform");
    }
}

// Retrieves an extended attribute value from a file.
// Returns the attribute value as a string or throws `XAttrException` on failure.
string getXAttr(string filePath, string attrName) {
    version (linux) {
        // First, determine the size of the attribute value
        ssize_t size = getxattr(filePath.toStringz(), attrName.toStringz(), null, 0);
        if (size < 0) {
            throw new XAttrException("Failed to get xattr size for '" ~ attrName ~ "' on '" ~ filePath ~ "': " ~ to!string(strerror(errno)));
        }

        void* buffer = malloc(size);
        scope(exit) free(buffer);

        ssize_t ret = getxattr(filePath.toStringz(), attrName.toStringz(), buffer, cast(size_t)size);
        if (ret < 0) {
            throw new XAttrException("Failed to get xattr '" ~ attrName ~ "' on '" ~ filePath ~ "': " ~ to!string(strerror(errno)));
        }

        return cast(string)(buffer[0 .. size]);
    } else version (FreeBSD) {
        // First, determine the size
        ssize_t size = extattr_get_file(filePath.toStringz(), EXTATTR_NAMESPACE_USER, attrName.toStringz(), null, 0);
        if (size < 0) {
            throw new XAttrException("Failed to get xattr size for '" ~ attrName ~ "' on '" ~ filePath ~ "': " ~ to!string(strerror(errno)));
        }

        void* buffer = malloc(size);
        scope(exit) free(buffer);

        ssize_t ret = extattr_get_file(filePath.toStringz(), EXTATTR_NAMESPACE_USER, attrName.toStringz(), buffer, cast(size_t)size);
        if (ret < 0) {
            throw new XAttrException("Failed to get xattr '" ~ attrName ~ "' on '" ~ filePath ~ "': " ~ to!string(strerror(errno)));
        }

        return cast(string)(buffer[0 .. size]);
    } else {
        throw new XAttrException("xattr not supported on this platform");
    }
}
