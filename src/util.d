import std.conv: to;
import std.digest.crc;
import std.digest.digest;
import std.file: exists, rename;
import std.path: extension;
import std.stdio;
import std.string: chomp;

private string deviceName;

static this()
{
	import std.socket;
	deviceName = Socket.hostName;
}

// give a new name to the specified file or directory
void safeRename(const(char)[] path)
{
	auto ext = extension(path);
	auto newPath = path.chomp(ext) ~ "-" ~ deviceName;
	if (exists(newPath ~ ext)) {
		int n = 2;
		char[] newPath2;
		do {
			newPath2 = newPath ~ "-" ~ n.to!string;
			n++;
		} while (exists(newPath2 ~ ext));
		newPath = newPath2;
	}
	newPath ~= ext;
	rename(path, newPath);
}

// return the crc32 hex string of a file
string computeCrc32(string path)
{
	CRC32 crc;
	auto file = File(path, "rb");
	foreach (ubyte[] data; chunks(file, 4096)) {
		crc.put(data);
	}
	return crc.finish().toHexString().dup;
}

// convert wildcards (*, ?) to regex
string wild2regex(const(char)[] pattern)
{
	string regex;
	regex.reserve(pattern.length + 2);
	regex ~= "^";
	foreach (c; pattern) {
		switch (c) {
		case '*':
			regex ~= ".*";
			break;
		case '.':
			regex ~= "\\.";
			break;
		case '?':
			regex ~= ".";
			break;
		case '|':
			regex ~= "$|^";
			break;
		default:
			regex ~= c;
			break;
		}
	}
	regex ~= "$";
	return regex;
}
