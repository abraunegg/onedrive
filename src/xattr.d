module xattr;

import core.sys.posix.sys.types;
import core.stdc.errno;
import core.stdc.stdlib;
import core.stdc.string;
import core.stdc.stdio;
import std.string;
import std.conv;

extern (C) {
    int setxattr(const(char)* path, const(char)* name, const(void)* value, size_t size, int flags);
    ssize_t getxattr(const(char)* path, const(char)* name, void* value, size_t size);
}

class XAttrException : Exception {
    this(string message) {
        super(message);
    }
}

// Sets an extended attribute for a given file.
// Throws `XAttrException` on failure.
void setXAttr(string filePath, string attrName, string attrValue) {
    int result = setxattr(filePath.toStringz(), attrName.toStringz(), cast(const(void)*)attrValue.ptr, attrValue.length, 0);
    if (result != 0) {
        throw new XAttrException("Failed to set xattr '" ~ attrName ~ "' on '" ~ filePath ~ "': " ~ to!string(strerror(errno)));
    }
}

// Retrieves an extended attribute value from a file.
// Returns the attribute value as a string.
// Throws `XAttrException` if the attribute cannot be read.
string getXAttr(string filePath, string attrName) {
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
}
