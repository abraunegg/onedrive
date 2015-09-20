import core.time, core.thread;
import std.getopt, std.file, std.path, std.process, std.stdio;
import config, itemdb, monitor, onedrive, sync;

string ver = "1.0";

void main(string[] args)
{
	bool monitor, resync, verbose;
	try {
		auto opt = getopt(
			args,
			"monitor|m", "Keep monitoring for local and remote changes.", &monitor,
			"resync", "Forget the local state and perform a full synchronization.", &resync,
			"verbose|v", "Print more details, useful for debugging.", &verbose
		);
		if (opt.helpWanted) {
			defaultGetoptPrinter("OneDrive Free Client for Linux v" ~ ver ~ "\nAvailable options:", opt.options);
			return;
		}
	} catch (GetOptException e) {
		writeln(e.msg);
		writeln("Try 'onedrive -h' for more information.");
		return;
	}

	string configDirName = expandTilde(environment.get("XDG_CONFIG_HOME", "~/.config")) ~ "/onedrive";
	string configFilePath = configDirName ~ "/config";
	string refreshTokenFilePath = configDirName ~ "/refresh_token";
	string statusTokenFilePath = configDirName ~ "/status_token";
	string databaseFilePath = configDirName ~ "/items.db";

	if (resync) {
		if (verbose) writeln("Deleting the saved status ...");
		if (exists(databaseFilePath)) remove(databaseFilePath);
		if (exists(statusTokenFilePath)) remove(statusTokenFilePath);
	}

	if (verbose) writeln("Loading config ...");
	auto cfg = config.Config(configFilePath);
	cfg.load();

	if (verbose) writeln("Initializing the OneDrive API ...");
	auto onedrive = new OneDriveApi(cfg, verbose);
	onedrive.onRefreshToken = (string refreshToken) {
		std.file.write(refreshTokenFilePath, refreshToken);
	};
	try {
		string refreshToken = readText(refreshTokenFilePath);
		onedrive.setRefreshToken(refreshToken);
	} catch (FileException e) {
		onedrive.authorize();
	}
	// TODO check if the token is valid

	if (verbose) writeln("Opening the item database ...");
	auto itemdb = new ItemDatabase(databaseFilePath);

	if (verbose) writeln("Initializing the Synchronization Engine ...");
	auto sync = new SyncEngine(cfg, onedrive, itemdb, verbose);
	sync.onStatusToken = (string statusToken) {
		std.file.write(statusTokenFilePath, statusToken);
	};
	try {
		string statusToken = readText(statusTokenFilePath);
		sync.setStatusToken(statusToken);
	} catch (FileException e) {
		// swallow exception
	}

	string syncDir = expandTilde(cfg.get("sync_dir"));
	chdir(syncDir);
	sync.applyDifferences();
	sync.scanForDifferences(".");

	if (monitor) {
		if (verbose) writeln("Initializing monitor ...");
		Monitor m;
		m.onDirCreated = delegate(string path) {
			if (verbose) writeln("[M] Directory created: ", path);
			sync.scanForDifferences(path);
		};
		m.onFileChanged = delegate(string path) {
			if (verbose) writeln("[M] File changed: ", path);
			try {
				sync.scanForDifferences(path);
			} catch(SyncException e) {
				writeln(e.msg);
			}
		};
		m.onDelete = delegate(string path) {
			if (verbose) writeln("[M] Item deleted: ", path);
			sync.deleteByPath(path);
		};
		m.onMove = delegate(string from, string to) {
			if (verbose) writeln("[M] Item moved: ", from, " -> ", to);
			sync.uploadMoveItem(from, to);
		};
		m.init(cfg, verbose);
		// monitor loop
		immutable auto checkInterval = dur!"seconds"(45);
		auto lastCheckTime = MonoTime.currTime();
		while (true) {
			m.update();
			auto currTime = MonoTime.currTime();
			if (currTime - lastCheckTime > checkInterval) {
				lastCheckTime = currTime;
				m.shutdown();
				sync.applyDifferences();
				sync.scanForDifferences(".");
				m.init(cfg, verbose);
				import core.memory;
				GC.collect();
			} else {
				Thread.sleep(dur!"msecs"(100));
			}
		}
	}
}
