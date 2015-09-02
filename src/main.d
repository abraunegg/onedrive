import std.file;
import config, onedrive, sync;

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

	/*import std.stdio;
	import std.net.curl;
	try {
		onedrive.simpleUpload("a.txt", "a.txt", "error").toPrettyString.writeln;
	} catch (CurlException e) {
		writeln("exc ", e.msg);
	}*/
}
