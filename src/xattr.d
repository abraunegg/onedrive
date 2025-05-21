module xattr;

import core.sys.posix.sys.types;
import core.stdc.errno;
import core.stdc.stdlib;
import core.stdc.string;
import core.stdc.stdio;
import std.string;
import std.conv;

class XAttrException : Exception {
    this(string message) {
        super(message);
    }
}

version (Linux) {
    // Linux specific imports and C bindings
    extern (C) {
        int setxattr(const(char)* path, const(char)* name, const(void)* value, size_t size, int flags);
        ssize_t getxattr(const(char)* path, const(char)* name, void* value, size_t size);
        int removexattr(const(char)* path, const(char)* name);
    }

    // Define xattr flags for Linux
    enum XATTR_FLAGS : int {
        XATTR_CREATE = 0x1, // Set attribute only if it doesn't exist.
        XATTR_REPLACE = 0x2 // Set attribute only if it already exists.
    }
} else { // Define even if not Linux
    enum XATTR_FLAGS : int {
        XATTR_CREATE = 0,
        XATTR_REPLACE = 0
    }
}

version (FreeBSD) {
    // FreeBSD specific imports and C bindings
    extern (C) {
        // From <sys/extattr.h>
        int extattr_get_file(const(char)* path, int attrnamespace, const(char)* attrname, void* data, size_t nbytes);
        int extattr_set_file(const(char)* path, int attrnamespace, const(char)* attrname, const(void)* data, size_t nbytes);
        int extattr_delete_file(const(char)* path, int attrnamespace, const(char)* attrname);
        int extattr_list_file(const(char)* path, int attrnamespace, void* data, size_t nbytes);

        // Define extattr namespaces for FreeBSD
        enum EXTATTR_NAMESPACE : int {
            EXTATTR_NAMESPACE_USER = 0x0001,
            EXTATTR_NAMESPACE_SYSTEM = 0x0002
        }
    }

    // FreeBSD: Helper function to get the size of an attribute
    ssize_t extattr_get_size(const(char)* path, int attrnamespace, const(char)* attrname) {
        int result = extattr_get_file(path, attrnamespace, attrname, null, 0);
        if (result == -1) {
            return -1;
        }
        return cast(ssize_t)result;
    }
} else { // Define even if not FreeBSD
    enum EXTATTR_NAMESPACE : int {
        EXTATTR_NAMESPACE_USER = 0,
        EXTATTR_NAMESPACE_SYSTEM = 0
    }
}

// Sets an extended attribute for a given file.
// Throws `XAttrException` on failure.
void setXAttr(string filePath, string attrName, string attrValue, int flags = 0) { // Added flags with default
    version (Linux) {
        int result = setxattr(filePath.toStringz(), attrName.toStringz(), cast(const(void)*)attrValue.ptr, attrValue.length, flags);
        if (result != 0) {
            throw new XAttrException("Failed to set xattr '" ~ attrName ~ "' on '" ~ filePath ~ "': " ~ to!string(strerror(errno)));
        }
    } else version (FreeBSD) {
        int result;
        if (flags & XATTR_FLAGS.XATTR_CREATE) { // Mimic XATTR_CREATE
            if (extattr_get_size(filePath.toStringz(), EXTATTR_NAMESPACE.EXTATTR_NAMESPACE_USER, attrName.toStringz()) >= 0) {
                throw new XAttrException("Failed to set xattr '" ~ attrName ~ "' on '" ~ filePath ~ "': Attribute already exists");
            }
        } else if (flags & XATTR_FLAGS.XATTR_REPLACE) { // Mimic XATTR_REPLACE
            if (extattr_get_size(filePath.toStringz(), EXTATTR_NAMESPACE.EXTATTR_NAMESPACE_USER, attrName.toStringz()) < 0) {
                throw new XAttrException("Failed to set xattr '" ~ attrName ~ "' on '" ~ filePath ~ "': Attribute does not exist");
            }
        }
        result = extattr_set_file(filePath.toStringz(), EXTATTR_NAMESPACE.EXTATTR_NAMESPACE_USER, attrName.toStringz(), cast(const(void)*)attrValue.ptr, attrValue.length);
        if (result != 0) {
            throw new XAttrException("Failed to set xattr '" ~ attrName ~ "' on '" ~ filePath ~ "': " ~ to!string(strerror(errno)));
        }
    } else {
        throw new XAttrException("Extended attributes not supported on this OS.");
    }
}

// Retrieves an extended attribute value from a file.
// Returns the attribute value as a string.
// Throws `XAttrException` if the attribute cannot be read.
string getXAttr(string filePath, string attrName) {
    version (Linux) {
        // First, determine the required buffer size
        ssize_t size = getxattr(filePath.toStringz(), attrName.toStringz(), null, 0);
        if (size == -1) {
            throw new XAttrException("Failed to determine xattr size for '" ~ attrName ~ "' on '" ~ filePath ~ "': " ~ to!string(strerror(errno)));
        }

        // Allocate buffer
        char[] buffer = new char[size];

        // Read the attribute value
        ssize_t result = getxattr(filePath.toStringz(), attrName.toStringz(), cast(void*)buffer.ptr, buffer.length);
        if (result == -1) {
            throw new XAttrException("Failed to read xattr '" ~ attrName ~ "' from '" ~ filePath ~ "': " ~ to!string(strerror(errno)));
        }

        return buffer[0 .. result].idup;
    } else version (FreeBSD) {
        // FreeBSD: Determine the required buffer size
        ssize_t size = extattr_get_size(filePath.toStringz(), EXTATTR_NAMESPACE.EXTATTR_NAMESPACE_USER, attrName.toStringz());
        if (size == -1) {
            throw new XAttrException("Failed to determine xattr size for '" ~ attrName ~ "' on '" ~ filePath ~ "': " ~ to!string(strerror(errno)));
        }

        // Allocate buffer
        char[] buffer = new char[cast(size_t)size];

        // Read the attribute value
        int result = extattr_get_file(filePath.toStringz(), EXTATTR_NAMESPACE.EXTATTR_NAMESPACE_USER, attrName.toStringz(), cast(void*)buffer.ptr, cast(size_t)size);
        if (result == -1) {
            throw new XAttrException("Failed to read xattr '" ~ attrName ~ "' from '" ~ filePath ~ "': " ~ to!string(strerror(errno)));
        }

        return buffer[0 .. result].idup;
    } else {
        throw new XAttrException("Extended attributes not supported on this OS.");
    }
}
