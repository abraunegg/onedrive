import std.regex, std.stdio, std.file;

final class Config
{
	private string filename;
	private string[string] values;

	this(string filename)
	{
		this.filename = filename;
		load();
	}

	string get(string key)
	{
		return values[key];
	}

	void set(string key, string value)
	{
		values[key] = value;
	}

	void load()
	{
		values = null;
		scope (failure) return;
		auto file = File(filename, "r");
		auto r = regex("(?:^\\s*)(\\w+)(?:\\s*=\\s*\")(.*)(?:\"\\s*$)");
		foreach (line; file.byLine()) {
			auto c = matchFirst(line, r);
			if (!c.empty) {
				c.popFront(); // skip whole match
				string key = c.front.dup;
				c.popFront();
				values[key] = c.front.dup;
			}
		}
	}

	void save()
	{
		if (exists(filename)) {
			string bkpFilename = filename ~ "~";
			rename(filename, bkpFilename);
		}
		auto file = File(filename, "w");
		foreach (key, value; values) {
			file.writeln(key, " = \"", value, "\"");
		}
	}
}

unittest
{
	auto cfg = new Config("/tmp/test.conf");
	cfg.set("test1", "1");
	cfg.set("test2", "2");
	cfg.set("test1", "3");
	cfg.save();
	cfg.load();
	assert(cfg.get("test1") == "3");
	assert(cfg.get("test2") == "2");
}
