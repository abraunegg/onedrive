import std.file, std.regex, std.stdio;

struct Config
{
	private string[string] values;

	this(string[] filenames...)
	{
		foreach (filename; filenames) {
			load(filename);
		}
	}

	string get(string key)
	{
		import core.exception;
		try {
			return values[key];
		} catch (RangeError e) {
			throw new Exception("Missing config value: " ~ key);
		}
	}

	private void load(string filename)
	{
		if (exists(filename)) {
			auto file = File(filename, "r");
			auto r = regex("(?:^\\s*)(\\w+)(?:\\s*=\\s*\")(.*)(?:\"\\s*$)");
			foreach (line; file.byLine()) {
				auto c = line.matchFirst(r);
				if (!c.empty) {
					c.popFront(); // skip the whole match
					string key = c.front.dup;
					c.popFront();
					values[key] = c.front.dup;
				} else {
					writeln("Malformed config line: ", line);
				}
			}
		}
	}
}

unittest
{
	auto cfg = Config("empty", "onedrive.conf");
	assert(cfg.get("sync_dir") == "~/OneDrive");
}
