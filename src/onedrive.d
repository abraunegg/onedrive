import std.datetime, std.exception, std.json, std.net.curl, std.path;
import std.string, std.uni, std.uri;
import config;

private immutable {
	string authUrl = "https://login.live.com/oauth20_authorize.srf";
	string redirectUrl = "https://login.live.com/oauth20_desktop.srf";
	string tokenUrl = "https://login.live.com/oauth20_token.srf";
	string itemByIdUrl = "https://api.onedrive.com/v1.0/drive/items/";
	string itemByPathUrl = "https://api.onedrive.com/v1.0/drive/root:/";
}

class OneDriveException: Exception
{
    @nogc @safe pure nothrow this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable next = null)
    {
        super(msg, file, line, next);
    }

    @nogc @safe pure nothrow this(string msg, Throwable next, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line, next);
    }
}

final class OneDriveApi
{
	private string clientId, clientSecret;
	private string refreshToken, accessToken;
	private SysTime accessTokenExpiration;
	private HTTP http;

	void delegate(string) onRefreshToken; // called when a new refresh_token is received

	this(Config cfg, bool verbose)
	{
		this.clientId = cfg.get("client_id");
		this.clientSecret = cfg.get("client_secret");
		http = HTTP();
		//http.verbose = verbose;
	}

	void authorize()
	{
		import std.stdio, std.regex;
		string url = authUrl ~ "?client_id=" ~ clientId ~ "&scope=wl.offline_access onedrive.readwrite&response_type=code&redirect_url=" ~ redirectUrl;
		writeln("Authorize this app visiting:\n");
		writeln(url, "\n");

		while (true) {
			char[] response;
			write("Enter the response url: ");
			readln(response);
			auto c = matchFirst(response, r"(?:code=)(([\w\d]+-){4}[\w\d]+)");
			if (!c.empty) {
				c.popFront(); // skip the whole match
				redeemToken(c.front);
				break;
			}
		}
	}

	void setRefreshToken(string refreshToken)
	{
		this.refreshToken = refreshToken;
		newToken();
	}

	string getItemPath(const(char)[] id)
	{
		checkAccessTokenExpired();
		JSONValue response = get(itemByIdUrl ~ id ~ "/?select=name,parentReference");
		string path;
		try {
			path = response["parentReference"].object["path"].str;
		} catch (JSONException e) {
			// root does not have parentReference
			return "";
		}
		path = decodeComponent(path[path.indexOf(':') + 1 .. $]);
		return buildNormalizedPath("." ~ path ~ "/" ~ response["name"].str);
	}

	string getItemId(const(char)[] path)
	{
		checkAccessTokenExpired();
		JSONValue response = get(itemByPathUrl ~ encodeComponent(path) ~ ":/?select=id");
		return response["id"].str;
	}

	// https://dev.onedrive.com/items/view_changes.htm
	JSONValue viewChangesById(const(char)[] id, const(char)[] statusToken)
	{
		checkAccessTokenExpired();
		char[] url = itemByIdUrl ~ id ~ "/view.changes";
		if (statusToken) url ~= "?token=" ~ statusToken;
		return get(url);
	}

	// https://dev.onedrive.com/items/view_changes.htm
	JSONValue viewChangesByPath(const(char)[] path, const(char)[] statusToken)
	{
		checkAccessTokenExpired();
		string url = itemByPathUrl ~ encodeComponent(path) ~ ":/view.changes";
		url ~= "?select=id,name,eTag,cTag,deleted,file,folder,fileSystemInfo,parentReference";
		if (statusToken) url ~= "&token=" ~ statusToken;
		return get(url);
	}

	// https://dev.onedrive.com/items/download.htm
	void downloadById(const(char)[] id, string saveToPath)
	{
		checkAccessTokenExpired();
		char[] url = itemByIdUrl ~ id ~ "/content";
		try {
			download(url, saveToPath, http);
		} catch (CurlException e) {
			import std.file;
			if (exists(saveToPath)) remove(saveToPath);
			throw new OneDriveException("Download error", e);
		}
	}

	// https://dev.onedrive.com/items/upload_put.htm
	JSONValue simpleUpload(string localPath, const(char)[] remotePath, const(char)[] eTag = null)
	{
		checkAccessTokenExpired();
		string url = itemByPathUrl ~ encodeComponent(remotePath) ~ ":/content";
		if (!eTag) url ~= "?@name.conflictBehavior=fail";
		ubyte[] content;
		http.onReceive = (ubyte[] data) {
			content ~= data;
			return data.length;
		};
		if (eTag) http.addRequestHeader("If-Match", eTag);
		http.addRequestHeader("Content-Type", "application/octet-stream");
		try {
			upload(localPath, url, http);
		} catch (ErrnoException e) {
			throw e;
		} finally {
			// remove the headers
			setAccessToken(accessToken);
		}
		checkHttpCode();
		return parseJSON(content);
	}

	// https://dev.onedrive.com/items/update.htm
	JSONValue updateById(const(char)[] id, JSONValue data, const(char)[] eTag = null)
	{
		checkAccessTokenExpired();
		char[] url = itemByIdUrl ~ id;
		if (eTag) http.addRequestHeader("If-Match", eTag);
		http.addRequestHeader("Content-Type", "application/json");
		auto result = patch(url, data.toString());
		// remove the headers
		setAccessToken(accessToken);
		return result;
	}

	//https://dev.onedrive.com/items/delete.htm
	void deleteById(const(char)[] id, const(char)[] eTag = null)
	{
		checkAccessTokenExpired();
		char[] url = itemByIdUrl ~ id;
		if (eTag) http.addRequestHeader("If-Match", eTag);
		del(url, http);
		// remove the if-match header
		if (eTag) setAccessToken(accessToken);
	}

	//https://dev.onedrive.com/items/create.htm
	JSONValue createByPath(const(char)[] parentPath, JSONValue item)
	{
		string url = itemByPathUrl ~ encodeComponent(parentPath) ~ ":/children";
		http.addRequestHeader("Content-Type", "application/json");
		auto result = post(url, item.toString());
		// remove the if-match header
		setAccessToken(accessToken);
		return result;
	}

	private void redeemToken(const(char)[] authCode)
	{
		string postData = "client_id=" ~ clientId ~ "&redirect_url=" ~ redirectUrl ~ "&client_secret=" ~ clientSecret;
		postData ~= "&code=" ~ authCode ~ "&grant_type=authorization_code";
		acquireToken(postData);
	}

	private void newToken()
	{
		string postData = "client_id=" ~ clientId ~ "&redirect_url=" ~ redirectUrl ~ "&client_secret=" ~ clientSecret;
		postData ~= "&refresh_token=" ~ refreshToken ~ "&grant_type=refresh_token";
		acquireToken(postData);
	}

	private void acquireToken(const(char)[] postData)
	{
		JSONValue response = post(tokenUrl, postData);
		setAccessToken(response["access_token"].str());
		refreshToken = response["refresh_token"].str();
		accessTokenExpiration = Clock.currTime() + dur!"seconds"(response["expires_in"].integer());
		if (onRefreshToken) onRefreshToken(refreshToken);
	}

	private void setAccessToken(string accessToken)
	{
		http.clearRequestHeaders();
		this.accessToken = accessToken;
		http.addRequestHeader("Authorization", "bearer " ~ accessToken);
	}

	private void checkAccessTokenExpired()
	{
		if (Clock.currTime() >= accessTokenExpiration) {
			newToken();
		}
	}

	private auto get(const(char)[] url)
	{
		return parseJSON(.get(url, http));
	}

	private auto patch(T)(const(char)[] url, const(T)[] patchData)
	{
		return parseJSON(.patch(url, patchData, http));
	}

	private auto post(T)(const(char)[] url, const(T)[] postData)
	{
		return parseJSON(.post(url, postData, http));
	}

	private void checkHttpCode()
	{
		if (http.statusLine.code / 100 != 2) {
			throw new OneDriveException(format("HTTP request returned status code %d (%s)", http.statusLine.code, http.statusLine.reason));
		}
	}
}
