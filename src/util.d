import std.conv, std.digest.crc, std.digest.digest, std.file, std.path;
import std.regex, std.stdio, std.string: chomp;

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
Regex!char wild2regex(const(char)[] pattern)
{
	string str;
	str.reserve(pattern.length + 2);
	str ~= "/";
	foreach (c; pattern) {
		switch (c) {
		case '*':
			str ~= "[^/]*";
			break;
		case '.':
			str ~= "\\.";
			break;
		case '?':
			str ~= "[^/]";
			break;
		case '|':
			str ~= "$|/";
			break;
		default:
			str ~= c;
			break;
		}
	}
	str ~= "$";
	return regex(str, "i");
}
