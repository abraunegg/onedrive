import std.net.curl: CurlException, HTTP;
import std.datetime, std.exception, std.file, std.json, std.path;
import std.stdio, std.string, std.uni, std.uri;
import config;
static import log;


private immutable {
	string authUrl = "https://login.live.com/oauth20_authorize.srf";
	string redirectUrl = "https://login.live.com/oauth20_desktop.srf"; // "urn:ietf:wg:oauth:2.0:oob";
	string tokenUrl = "https://login.live.com/oauth20_token.srf";
	string itemByIdUrl = "https://api.onedrive.com/v1.0/drive/items/";
	string itemByPathUrl = "https://api.onedrive.com/v1.0/drive/root:/";
}

class OneDriveException: Exception
{
	// HTTP status code
	int code;

    @nogc @safe pure nothrow this(string msg, Throwable next, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line, next);
    }

	@safe pure this(int code, string reason, string file = __FILE__, size_t line = __LINE__)
	{
		this.code = code;
		string msg = format("HTTP request returned status code %d (%s)", code, reason);
		super(msg, file, line, next);
	}
}

final class OneDriveApi
{
	private Config cfg;
	private string clientId;
	private string refreshToken, accessToken;
	private SysTime accessTokenExpiration;
	/* private */ HTTP http;

	this(Config cfg)
	{
		this.cfg = cfg;
		this.clientId = cfg.getValue("client_id");
		http = HTTP();
		//http.verbose = true;
	}

	bool init()
	{
		try {
			refreshToken = readText(cfg.refreshTokenFilePath);
		} catch (FileException e) {
			return authorize();
		}
		return true;
	}

	bool authorize()
	{
		import std.stdio, std.regex;
		char[] response;
		string url = authUrl ~ "?client_id=" ~ clientId ~ "&scope=onedrive.readwrite%20offline_access&response_type=code&redirect_uri=" ~ redirectUrl;
		log.log("Authorize this app visiting:\n");
		write(url, "\n\n", "Enter the response uri: ");
		readln(response);
		// match the authorization code
		auto c = matchFirst(response, r"(?:code=)(([\w\d]+-){4}[\w\d]+)");
		if (c.empty) {
			log.log("Invalid uri");
			return false;
		}
		c.popFront(); // skip the whole match
		redeemToken(c.front);
		return true;
	}

	// https://dev.onedrive.com/items/view_delta.htm
	JSONValue viewChangesById(const(char)[] id, const(char)[] statusToken)
	{
		checkAccessTokenExpired();
		const(char)[] url = itemByIdUrl ~ id ~ "/view.delta";
		url ~= "?select=id,name,eTag,cTag,deleted,file,folder,fileSystemInfo,remoteItem,parentReference";
		if (statusToken) url ~= "?token=" ~ statusToken;
		return get(url);
	}

	// https://dev.onedrive.com/items/view_delta.htm
	JSONValue viewChangesByPath(const(char)[] path, const(char)[] statusToken)
	{
		checkAccessTokenExpired();
		string url = itemByPathUrl ~ encodeComponent(path) ~ ":/view.delta";
		url ~= "?select=id,name,eTag,cTag,deleted,file,folder,fileSystemInfo,remoteItem,parentReference";
		if (statusToken) url ~= "&token=" ~ statusToken;
		return get(url);
	}

	// https://dev.onedrive.com/items/download.htm
	void downloadById(const(char)[] id, string saveToPath)
	{
		checkAccessTokenExpired();
		scope(failure) {
			import std.file;
			if (exists(saveToPath)) remove(saveToPath);
		}
		const(char)[] url = itemByIdUrl ~ id ~ "/content?AVOverride=1";
		download(url, saveToPath);
	}

	// https://dev.onedrive.com/items/upload_put.htm
	JSONValue simpleUpload(string localPath, const(char)[] remotePath, const(char)[] eTag = null)
	{
		checkAccessTokenExpired();
		string url = itemByPathUrl ~ encodeComponent(remotePath) ~ ":/content";
		http.addRequestHeader("Content-Type", "application/octet-stream");
		if (eTag) http.addRequestHeader("If-Match", eTag);
		else url ~= "?@name.conflictBehavior=fail";
		return upload(localPath, url);
	}

	// https://dev.onedrive.com/items/update.htm
	JSONValue updateById(const(char)[] id, JSONValue data, const(char)[] eTag = null)
	{
		checkAccessTokenExpired();
		char[] url = itemByIdUrl ~ id;
		if (eTag) http.addRequestHeader("If-Match", eTag);
		http.addRequestHeader("Content-Type", "application/json");
		return patch(url, data.toString());
	}

	// https://dev.onedrive.com/items/delete.htm
	void deleteById(const(char)[] id, const(char)[] eTag = null)
	{
		checkAccessTokenExpired();
		char[] url = itemByIdUrl ~ id;
		if (eTag) http.addRequestHeader("If-Match", eTag);
		del(url);
	}

	// https://dev.onedrive.com/items/create.htm
	JSONValue createByPath(const(char)[] parentPath, JSONValue item)
	{
		string url = itemByPathUrl ~ encodeComponent(parentPath) ~ ":/children";
		http.addRequestHeader("Content-Type", "application/json");
		return post(url, item.toString());
	}

	// https://dev.onedrive.com/items/upload_large_files.htm
	JSONValue createUploadSession(const(char)[] path, const(char)[] eTag = null)
	{
		checkAccessTokenExpired();
		string url = itemByPathUrl ~ encodeComponent(path) ~ ":/upload.createSession";
		if (eTag) http.addRequestHeader("If-Match", eTag);
		return post(url, null);
	}

	// https://dev.onedrive.com/items/upload_large_files.htm
	JSONValue uploadFragment(const(char)[] uploadUrl, string filepath, long offset, long offsetSize, long fileSize)
	{
		checkAccessTokenExpired();
		scope(exit) {
			http.clearRequestHeaders();
			http.onSend = null;
		}
		http.method = HTTP.Method.put;
		http.url = uploadUrl;
		addAccessTokenHeader();
		import std.conv;
		string contentRange = "bytes " ~ to!string(offset) ~ "-" ~ to!string(offset + offsetSize - 1) ~ "/" ~ to!string(fileSize);
		http.addRequestHeader("Content-Range", contentRange);
		auto file = File(filepath, "rb");
		file.seek(offset);
		http.onSend = data => file.rawRead(data).length;
		http.contentLength = offsetSize;
		auto response = perform();
		// TODO: retry on 5xx errors
		checkHttpCode();
		return response;
	}

	// https://dev.onedrive.com/items/upload_large_files.htm
	JSONValue requestUploadStatus(const(char)[] uploadUrl)
	{
		checkAccessTokenExpired();
		return get(uploadUrl);
	}

	private void redeemToken(const(char)[] authCode)
	{
		const(char)[] postData =
			"client_id=" ~ clientId ~
			"&redirect_uri=" ~ redirectUrl ~
			"&code=" ~ authCode ~
			"&grant_type=authorization_code";
		acquireToken(postData);
	}

	private void newToken()
	{
		string postData =
			"client_id=" ~ clientId ~
			"&redirect_uri=" ~ redirectUrl ~
			"&refresh_token=" ~ refreshToken ~
			"&grant_type=refresh_token";
		acquireToken(postData);
	}

	private void acquireToken(const(char)[] postData)
	{
		JSONValue response = post(tokenUrl, postData);
		accessToken = "bearer " ~ response["access_token"].str();
		refreshToken = response["refresh_token"].str();
		accessTokenExpiration = Clock.currTime() + dur!"seconds"(response["expires_in"].integer());
		std.file.write(cfg.refreshTokenFilePath, refreshToken);
	}

	private void checkAccessTokenExpired()
	{
		if (Clock.currTime() >= accessTokenExpiration) {
			newToken();
		}
	}

	private void addAccessTokenHeader()
	{
		http.addRequestHeader("Authorization", accessToken);
	}

	private JSONValue get(const(char)[] url)
	{
		scope(exit) http.clearRequestHeaders();
		http.method = HTTP.Method.get;
		http.url = url;
		addAccessTokenHeader();
		auto response = perform();
		checkHttpCode();
		return response;
	}

	private void del(const(char)[] url)
	{
		scope(exit) http.clearRequestHeaders();
		http.method = HTTP.Method.del;
		http.url = url;
		addAccessTokenHeader();
		perform();
		checkHttpCode();
	}

	private void download(const(char)[] url, string filename)
	{
		scope(exit) http.clearRequestHeaders();
		http.method = HTTP.Method.get;
		http.url = url;
		addAccessTokenHeader();
		auto f = File(filename, "wb");
		http.onReceive = (ubyte[] data) {
			f.rawWrite(data);
			return data.length;
		};
		http.perform();
		checkHttpCode();
	}

	private auto patch(T)(const(char)[] url, const(T)[] patchData)
	{
		scope(exit) http.clearRequestHeaders();
		http.method = HTTP.Method.patch;
		http.url = url;
		addAccessTokenHeader();
		auto response = perform(patchData);
		checkHttpCode();
		return response;
	}

	private auto post(T)(const(char)[] url, const(T)[] postData)
	{
		scope(exit) http.clearRequestHeaders();
		http.method = HTTP.Method.post;
		http.url = url;
		addAccessTokenHeader();
		auto response = perform(postData);
		checkHttpCode();
		return response;
	}

	private JSONValue upload(string filepath, string url)
	{
		scope(exit) {
			http.clearRequestHeaders();
			http.onSend = null;
			http.contentLength = 0;
		}
		http.method = HTTP.Method.put;
		http.url = url;
		addAccessTokenHeader();
		http.addRequestHeader("Content-Type", "application/octet-stream");
		auto file = File(filepath, "rb");
		http.onSend = data => file.rawRead(data).length;
		http.contentLength = file.size;
		auto response = perform();
		checkHttpCode();
		return response;
	}

	private JSONValue perform(const(void)[] sendData)
	{
		scope(exit) {
			http.onSend = null;
			http.contentLength = 0;
		}
		if (sendData) {
			http.contentLength = sendData.length;
			http.onSend = (void[] buf) {
				import std.algorithm: min;
				size_t minLen = min(buf.length, sendData.length);
				if (minLen == 0) return 0;
				buf[0 .. minLen] = sendData[0 .. minLen];
				sendData = sendData[minLen .. $];
				return minLen;
			};
		} else {
			http.onSend = buf => 0;
		}
		return perform();
	}

	private JSONValue perform()
	{
		scope(exit) http.onReceive = null;
		char[] content;
		http.onReceive = (ubyte[] data) {
			content ~= data;
			return data.length;
		};
		try {
			http.perform();
		} catch (CurlException e) {
			throw new OneDriveException(e.msg, e);
		}
		return content.parseJSON();
	}

	private void checkHttpCode()
	{
		if (http.statusLine.code / 100 != 2) {
			throw new OneDriveException(http.statusLine.code, http.statusLine.reason);
		}
	}
}
