import std.getopt, std.file, std.process, std.stdio;
import config, monitor, onedrive, sync;

string ver = "1.0";

void main(string[] args)
{
	bool monitor, resync, resetLocal, resetRemote,  verbose;
	try {
		writeln("OneDrive Client for Linux v", ver);
		auto opt = getopt(
			args,
			"monitor|m", "Keep monitoring for local and remote changes.", &monitor,
			"resync", "Perform a full synchronization.", &resync,
			"verbose|v", "Print more details, useful for debugging.", &verbose
		);
		if (opt.helpWanted) {
			defaultGetoptPrinter("Available options:", opt.options);
			return;
		}
	} catch (GetOptException e) {
		writeln(e.msg);
		writeln("Try 'onedrive -h' for more information.");
		return;
	}

	string homeDirName = environment["HOME"];
	string configDirName = environment.get("XDG_CONFIG_HOME", homeDirName ~ "/.config") ~ "/onedrive";
	string configFilePath = configDirName ~ "/config";
	string refreshTokenFilePath = configDirName ~ "/refresh_token";
	string statusTokenFilePath = configDirName ~ "/status_token";
	string databaseFilePath = configDirName ~ "/database";

	if (resync || resetLocal || resetRemote) {
		if (verbose) writeln("Deleting the current status ...");
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

	if (verbose) writeln("Initializing the Synchronization Engine ...");
	auto sync = new SyncEngine(cfg, onedrive);
	sync.applyDifferences();
	sync.uploadDifferences();

	if (monitor) {
		if (verbose) writeln("Monitoring for changes ...");
		Monitor m;
		m.onDirCreated = delegate(string path) {
			if (verbose) writeln("[M] Directory created: ", path);
			sync.createFolderItem(path);
			sync.uploadDifferences(path);
		};
		m.onFileChanged = delegate(string path) {
			if (verbose) writeln("[M] File changed: ", path);
			sync.uploadDifference2(path);
		};
		m.onDelete = delegate(string path) {
			if (verbose) writeln("[M] Item deleted: ", path);
			sync.deleteByPath(path);
		};
		m.onMove = delegate(string from, string to) {
			if (verbose) writeln("[M] Item moved: ", from, " -> ", to);
			sync.moveItem(from, to);
		};
		m.init();
		string syncDir = cfg.get("sync_dir");
		chdir(syncDir);
		m.addRecursive("test");
		while (true) m.update();
		// TODO download changes
	}
}
