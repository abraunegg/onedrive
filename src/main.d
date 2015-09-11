import std.file;
import config, monitor, onedrive, sync;

private string configFile = "./onedrive.conf";
private string refreshTokenFile = "refresh_token";

void main()
{
	auto cfg = new Config(configFile);

	auto onedrive = new OneDriveApi(cfg.get("client_id"), cfg.get("client_secret"));
	onedrive.onRefreshToken = (string refreshToken) { std.file.write(refreshTokenFile, refreshToken); };
	try {
		string refreshToken = readText(refreshTokenFile);
		onedrive.setRefreshToken(refreshToken);
	} catch (FileException e) {
		onedrive.authorize();
	}

	auto sync = new SyncEngine(cfg, onedrive);
	sync.applyDifferences();
	sync.uploadDifferences();

	Monitor m;
	import std.stdio;
	m.onDirCreated = delegate(string path) {
		writeln("Directory created: ", path);
		sync.createFolderItem(path);
		sync.uploadDifferences(path);
	};
	m.onFileChanged = delegate(string path) {
		writeln("File changed: ", path);
		sync.uploadDifference2(path);
	};
	m.onDelete = delegate(string path) {
		sync.deleteByPath(path);
	};
	m.onMove = delegate(string from, string to) {
		sync.moveItem(from, to);
	};
	m.init();
	string syncDir = cfg.get("sync_dir");
	chdir(syncDir);
	m.addRecursive("test");
	while (true) m.update();
}
