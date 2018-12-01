import std.net.curl;
import etc.c.curl: CurlOption;
import std.datetime, std.exception, std.file, std.json, std.path;
import std.stdio, std.string, std.uni, std.uri;
import core.stdc.stdlib;
import core.thread, std.conv, std.math;
import progress;
import config;
static import log;
shared bool debugResponse = false;

private immutable {
	string clientId = "22c49a0d-d21c-4792-aed1-8f163c982546";
	string authUrl = "https://login.microsoftonline.com/common/oauth2/v2.0/authorize";
	string redirectUrl = "https://login.microsoftonline.com/common/oauth2/nativeclient";
	string tokenUrl = "https://login.microsoftonline.com/common/oauth2/v2.0/token";
	string driveByIdUrl = "https://graph.microsoft.com/v1.0/drives/";
}

private {
    string driveUrl = "https://graph.microsoft.com/v1.0/me/drive";
    string itemByIdUrl = "https://graph.microsoft.com/v1.0/me/drive/items/";
    string itemByPathUrl = "https://graph.microsoft.com/v1.0/me/drive/root:/";
    string driveId = "";
}

class OneDriveException: Exception
{
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/concepts/errors
	int httpStatusCode;
	JSONValue error;

	@safe pure this(int httpStatusCode, string reason, string file = __FILE__, size_t line = __LINE__)
	{
		this.httpStatusCode = httpStatusCode;
		this.error = error;
		string msg = format("HTTP request returned status code %d (%s)", httpStatusCode, reason);
		super(msg, file, line);
	}

	this(int httpStatusCode, string reason, ref const JSONValue error, string file = __FILE__, size_t line = __LINE__)
	{
		this.httpStatusCode = httpStatusCode;
		this.error = error;
		string msg = format("HTTP request returned status code %d (%s)\n%s", httpStatusCode, reason, toJSON(error, true));
		super(msg, file, line);
	}
}

final class OneDriveApi
{
	private Config cfg;
	private string refreshToken, accessToken;
	private SysTime accessTokenExpiration;
	/* private */ HTTP http;

	// if true, every new access token is printed
	bool printAccessToken;

	this(Config cfg, bool debugHttp)
	{
		this.cfg = cfg;
		http = HTTP();
		http.dnsTimeout = (dur!"seconds"(5));
		http.dataTimeout = (dur!"seconds"(3600));
		
		// Specify how many redirects should be allowed
		http.maxRedirects(5);
		
		if (debugHttp) {
			http.verbose = true;
			.debugResponse = true;
        }
	}

	bool init()
	{
		try {
			driveId = cfg.getValue("drive_id");
			if (driveId.length) {
				driveUrl = driveByIdUrl ~ driveId;
                itemByIdUrl = driveUrl ~ "/items";
                itemByPathUrl = driveUrl ~ "/root:/";
				
				// Issue #248 extra debug
				writeln("driveUrl: ", driveUrl);
				writeln("itemByIdUrl: ", itemByIdUrl);
				writeln("itemByPathUrl: ", itemByPathUrl);
			}
		} catch (Exception e) {}
	
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
		string url = authUrl ~ "?client_id=" ~ clientId ~ "&scope=files.readwrite%20files.readwrite.all%20offline_access&response_type=code&redirect_uri=" ~ redirectUrl;
		log.log("Authorize this app visiting:\n");
		write(url, "\n\n", "Enter the response uri: ");
		readln(response);
		// match the authorization code
		auto c = matchFirst(response, r"(?:[\?&]code=)([\w\d-]+)");
		if (c.empty) {
			log.log("Invalid uri");
			return false;
		}
		c.popFront(); // skip the whole match
		redeemToken(c.front);
		return true;
	}

	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/drive_get
	JSONValue getDefaultDrive()
	{
		// Issue #248 extra debug
		writeln("Checking access token");
		checkAccessTokenExpired();
		// Issue #248 extra debug
		writeln("Done checking access token");
		
		writeln("List 'my' drives");
		string myDrivesUrl = "https://graph.microsoft.com/v1.0/me/drives";
		auto response = get(myDrivesUrl);
		writeln("Response: ", response);
		
		writeln("Performing a get of driveURL: ", driveUrl);
		return get(driveUrl);
	}

	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_get
	JSONValue getDefaultRoot()
	{
		checkAccessTokenExpired();
		return get(driveUrl ~ "/root");
	}

	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_delta
	JSONValue viewChangesById(const(char)[] driveId, const(char)[] id, const(char)[] deltaLink)
	{
		checkAccessTokenExpired();
		const(char)[] url = deltaLink;
		if (url == null) {
			url = driveByIdUrl ~ driveId ~ "/items/" ~ id ~ "/delta";
			url ~= "?select=id,name,eTag,cTag,deleted,file,folder,root,fileSystemInfo,remoteItem,parentReference";
		}
		return get(url);
	}

	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_get_content
	void downloadById(const(char)[] driveId, const(char)[] id, string saveToPath, long fileSize)
	{
		checkAccessTokenExpired();
		scope(failure) {
			if (exists(saveToPath)) remove(saveToPath);
		}
		mkdirRecurse(dirName(saveToPath));
		const(char)[] url = driveByIdUrl ~ driveId ~ "/items/" ~ id ~ "/content?AVOverride=1";
		download(url, saveToPath, fileSize);
	}

	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_put_content
	JSONValue simpleUpload(string localPath, string parentDriveId, string parentId, string filename, const(char)[] eTag = null)
	{
		checkAccessTokenExpired();
		string url = driveByIdUrl ~ parentDriveId ~ "/items/" ~ parentId ~ ":/" ~ encodeComponent(filename) ~ ":/content";
		// TODO: investigate why this fails for remote folders
		//if (eTag) http.addRequestHeader("If-Match", eTag);
		/*else http.addRequestHeader("If-None-Match", "*");*/
		return upload(localPath, url);
	}

	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_put_content
	JSONValue simpleUploadReplace(string localPath, string driveId, string id, const(char)[] eTag = null)
	{
		checkAccessTokenExpired();
		string url = driveByIdUrl ~ driveId ~ "/items/" ~ id ~ "/content";
		if (eTag) http.addRequestHeader("If-Match", eTag);
		return upload(localPath, url);
	}

	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_update
	JSONValue updateById(const(char)[] driveId, const(char)[] id, JSONValue data, const(char)[] eTag = null)
	{
		checkAccessTokenExpired();
		const(char)[] url = driveByIdUrl ~ driveId ~ "/items/" ~ id;
		if (eTag) http.addRequestHeader("If-Match", eTag);
		http.addRequestHeader("Content-Type", "application/json");
		return patch(url, data.toString());
	}

	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_delete
	void deleteById(const(char)[] driveId, const(char)[] id, const(char)[] eTag = null)
	{
		checkAccessTokenExpired();
		const(char)[] url = driveByIdUrl ~ driveId ~ "/items/" ~ id;
		//TODO: investigate why this always fail with 412 (Precondition Failed)
		//if (eTag) http.addRequestHeader("If-Match", eTag);
		del(url);
	}

	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_post_children
	JSONValue createById(const(char)[] parentDriveId, const(char)[] parentId, JSONValue item)
	{
		checkAccessTokenExpired();
		const(char)[] url = driveByIdUrl ~ parentDriveId ~ "/items/" ~ parentId ~ "/children";
		http.addRequestHeader("Content-Type", "application/json");		
		return post(url, item.toString());
	}

	// Return the details of the specified path
	JSONValue getPathDetails(const(string) path)
	{
		checkAccessTokenExpired();
		const(char)[] url;
		//		string itemByPathUrl = "https://graph.microsoft.com/v1.0/me/drive/root:/";
		if (path == ".") url = driveUrl ~ "/root/";
		else url = itemByPathUrl ~ encodeComponent(path) ~ ":/";
		url ~= "?select=id,name,eTag,cTag,deleted,file,folder,root,fileSystemInfo,remoteItem,parentReference";
		return get(url);
	}
	
	// Return the details of the specified id
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_get
	JSONValue getPathDetailsById(const(char)[] driveId, const(char)[] id)
	{
		checkAccessTokenExpired();
		const(char)[] url;
		//		string driveByIdUrl = "https://graph.microsoft.com/v1.0/drives/";
		url = driveByIdUrl ~ driveId ~ "/items/" ~ id;
		url ~= "?select=id,name,eTag,cTag,deleted,file,folder,root,fileSystemInfo,remoteItem,parentReference";
		return get(url);
	}
	
	// Return the requested details of the specified id
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_get
	JSONValue getFileDetails(const(char)[] driveId, const(char)[] id)
	{
		checkAccessTokenExpired();
		const(char)[] url;
		//		string driveByIdUrl = "https://graph.microsoft.com/v1.0/drives/";
		url = driveByIdUrl ~ driveId ~ "/items/" ~ id;
		url ~= "?select=size,malware";
		return get(url);
	}
	
	// https://dev.onedrive.com/items/move.htm
	JSONValue moveByPath(const(char)[] sourcePath, JSONValue moveData)
	{
		// Need to use itemByPathUrl
		checkAccessTokenExpired();
		string url = itemByPathUrl ~ encodeComponent(sourcePath);
		http.addRequestHeader("Content-Type", "application/json");
		return move(url, moveData.toString());
	}
	
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_createuploadsession
	JSONValue createUploadSession(const(char)[] parentDriveId, const(char)[] parentId, const(char)[] filename, const(char)[] eTag = null, JSONValue item = null)
	{
		checkAccessTokenExpired();
		const(char)[] url = driveByIdUrl ~ parentDriveId ~ "/items/" ~ parentId ~ ":/" ~ encodeComponent(filename) ~ ":/createUploadSession";
		if (eTag) http.addRequestHeader("If-Match", eTag);
		http.addRequestHeader("Content-Type", "application/json");
		return post(url, item.toString());
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
		// when using microsoft graph the auth code is different
		return get(uploadUrl, true);
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
		if (printAccessToken) writeln("New access token: ", accessToken);
	}

	private void checkAccessTokenExpired()
	{
		try {
			if (Clock.currTime() >= accessTokenExpiration) {
				newToken();
			}
		} catch (OneDriveException e) {
			if (e.httpStatusCode == 400 || e.httpStatusCode == 401) {
				e.msg ~= "\nRefresh token invalid, use --logout to authorize the client again";
			}
		}
	}

	private void addAccessTokenHeader()
	{
		http.addRequestHeader("Authorization", accessToken);
	}

	private JSONValue get(const(char)[] url, bool skipToken = false)
	{
		scope(exit) http.clearRequestHeaders();
		http.method = HTTP.Method.get;
		http.url = url;
		if (!skipToken) addAccessTokenHeader(); // HACK: requestUploadStatus
		auto response = perform();
		checkHttpCode(response);
		// OneDrive API Response Debugging
		if (.debugResponse){
			writeln("OneDrive API Response: ", response);
        }
		return response;
	}

	private void del(const(char)[] url)
	{
		scope(exit) http.clearRequestHeaders();
		http.method = HTTP.Method.del;
		http.url = url;
		addAccessTokenHeader();
		auto response = perform();
		checkHttpCode(response);
	}

	private void download(const(char)[] url, string filename, long fileSize)
	{
		// Threshold for displaying download bar
		long thresholdFileSize = 4 * 2^^20; // 4 MiB
		
		scope(exit) http.clearRequestHeaders();
		http.method = HTTP.Method.get;
		http.url = url;
		addAccessTokenHeader();
		auto f = File(filename, "wb");
		http.onReceive = (ubyte[] data) {
			f.rawWrite(data);
			return data.length;
		};
		
		if (fileSize >= thresholdFileSize){
			// Download Progress Bar
			size_t iteration = 20;
			Progress p = new Progress(iteration);
			p.title = "Downloading";
			writeln();
	
			real previousDLPercent = -1.0;
			real percentCheck = 5.0;
			// Setup progress bar to display
			http.onProgress = delegate int(size_t dltotal, size_t dlnow, size_t ultotal, size_t ulnow)
			{
				// For each onProgress, what is the % of dlnow to dltotal
				real currentDLPercent = round(double(dlnow)/dltotal*100);
				// If matching 5% of download, increment progress bar
				if ((isIdentical(fmod(currentDLPercent, percentCheck), 0.0)) && (previousDLPercent != currentDLPercent)) {
					p.next();
					previousDLPercent = currentDLPercent;
				}
				return 0;
			};
		
			// Perform download & display progress bar
			http.perform();
			writeln();
			// Reset onProgress to not display anything for next download
			http.onProgress = delegate int(size_t dltotal, size_t dlnow, size_t ultotal, size_t ulnow)
			{
				return 0;
			};
		} else {
			// No progress bar
			http.perform();
		}
		
		// Check the HTTP response code
		checkHttpCode();
	}

	private auto patch(T)(const(char)[] url, const(T)[] patchData)
	{
		scope(exit) http.clearRequestHeaders();
		http.method = HTTP.Method.patch;
		http.url = url;
		addAccessTokenHeader();
		auto response = perform(patchData);
		checkHttpCode(response);
		return response;
	}

	private auto post(T)(const(char)[] url, const(T)[] postData)
	{
		scope(exit) http.clearRequestHeaders();
		http.method = HTTP.Method.post;
		http.url = url;
		addAccessTokenHeader();
		auto response = perform(postData);
		checkHttpCode(response);
		return response;
	}

	private auto move(T)(const(char)[] url, const(T)[] postData)
	{
		scope(exit) http.clearRequestHeaders();
		http.method = HTTP.Method.patch;
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
		checkHttpCode(response);
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
			// HTTP Server Response Code Debugging
			if (.debugResponse){
				writeln("OneDrive HTTP Server Response: ", http.statusLine.code);
			}
			
			return data.length;
		};
		
		try {
			http.perform();
		} catch (CurlException e) {
			// Potentially Timeout was reached on handle error
			log.error("\nAccess to the Microsoft OneDrive service timed out - Internet connectivity issue?\n");
			exit(-1);
		}
		
		JSONValue json;
		try {
			json = content.parseJSON();
		} catch (JSONException e) {
			e.msg ~= "\n";
			e.msg ~= content;
			throw e;
		}
		return json;
	}

	private void checkHttpCode()
	{
		// https://dev.onedrive.com/misc/errors.htm
		// https://developer.overdrive.com/docs/reference-guide
		
		/*
			HTTP/1.1 Response handling

			Errors in the OneDrive API are returned using standard HTTP status codes, as well as a JSON error response object. The following HTTP status codes should be expected.

			Status code		Status message						Description
			
			200 			OK									Request was handled OK
			201 			Created								This means you've made a successful POST to checkout, lock in a format, or place a hold
			204				No Content							This means you've made a successful DELETE to remove a hold or return a title
			
			400				Bad Request							Cannot process the request because it is malformed or incorrect.
			401				Unauthorized						Required authentication information is either missing or not valid for the resource.
			403				Forbidden							Access is denied to the requested resource. The user might not have enough permission.
			404				Not Found							The requested resource doesn’t exist.
			405				Method Not Allowed					The HTTP method in the request is not allowed on the resource.
			406				Not Acceptable						This service doesn’t support the format requested in the Accept header.
			409				Conflict							The current state conflicts with what the request expects. For example, the specified parent folder might not exist.
			410				Gone								The requested resource is no longer available at the server.
			411				Length Required						A Content-Length header is required on the request.
			412				Precondition Failed					A precondition provided in the request (such as an if-match header) does not match the resource's current state.
			413				Request Entity Too Large			The request size exceeds the maximum limit.
			415				Unsupported Media Type				The content type of the request is a format that is not supported by the service.
			416				Requested Range Not Satisfiable		The specified byte range is invalid or unavailable.
			422				Unprocessable Entity				Cannot process the request because it is semantically incorrect.
			429				Too Many Requests					Client application has been throttled and should not attempt to repeat the request until an amount of time has elapsed.
			
			500				Internal Server Error				There was an internal server error while processing the request.
			501				Not Implemented						The requested feature isn’t implemented.
			502				Bad Gateway							The service was unreachable
			503				Service Unavailable					The service is temporarily unavailable. You may repeat the request after a delay. There may be a Retry-After header.
			507				Insufficient Storage				The maximum storage quota has been reached.
			509				Bandwidth Limit Exceeded			Your app has been throttled for exceeding the maximum bandwidth cap. Your app can retry the request again after more time has elapsed.
		
			HTTP/2 Response handling 
			
			0				OK
		
		*/
	
		switch(http.statusLine.code)
		{
			case 0:
				break;
			//	200 - OK
			case 200:
				// No Log .. 
				break;
			//	201 - Created OK
			//  202 - Accepted
			//	204 - Deleted OK
			case 201,202,204:
				// No actions, but log if verbose logging
				//log.vlog("OneDrive Response: '", http.statusLine.code, " - ", http.statusLine.reason, "'");
				break;
			
			// 302 - resource found and available at another location, redirect
			case 302:
				break;
			
			// 400 - Bad Request
			case 400:
				// Bad Request .. how should we act?
				log.vlog("OneDrive returned a 'HTTP 400 - Bad Request' - gracefully handling error");
				break;	
			
			// Item not found
			case 404:
				// Item was not found - do not throw an exception
				log.vlog("OneDrive returned a 'HTTP 404 - Item not found' - gracefully handling error");
				break;
			
			//	409 - Conflict
			case 409:
				// Conflict handling .. how should we act? This only really gets triggered if we are using --local-first & we remove items.db as the DB thinks the file is not uploaded but it is
				log.vlog("OneDrive returned a 'HTTP 409 - Conflict' - gracefully handling error");
				break;	
			
			//	412 - Precondition Failed
			case 412:
				// A precondition provided in the request (such as an if-match header) does not match the resource's current state.
				log.vlog("OneDrive returned a 'HTTP 412 - Precondition Failed' - gracefully handling error");
				break;	
			
			//  415 - Unsupported Media Type
			case 415:
				// Unsupported Media Type ... sometimes triggered on image files, especially PNG
				log.vlog("OneDrive returned a 'HTTP 415 - Unsupported Media Type' - gracefully handling error");
				break;
			
			//  429 - Too Many Requests
			case 429:
				// Too many requests in a certain time window
				// https://docs.microsoft.com/en-us/sharepoint/dev/general-development/how-to-avoid-getting-throttled-or-blocked-in-sharepoint-online
				log.vlog("OneDrive returned a 'HTTP 429 - Too Many Requests' - gracefully handling error");
				break;
			
			// Server side (OneDrive) Errors
			//  500 - Internal Server Error
			// 	502 - Bad Gateway
			//	503 - Service Unavailable
			//  504 - Gateway Timeout (Issue #320)
			case 500,502,503,504:
				// No actions
				log.vlog("OneDrive returned a 'HTTP 5xx Server Side Error' - gracefully handling error");
				break;	

			// "else"
			default:
				throw new OneDriveException(http.statusLine.code, http.statusLine.reason); 
				break;
		}
	}

	private void checkHttpCode(ref const JSONValue response)
	{
		switch(http.statusLine.code)
		{
			//	412 - Precondition Failed
			case 412:
				throw new OneDriveException(http.statusLine.code, http.statusLine.reason);
				break;
				
			// Server side (OneDrive) Errors
			//  500 - Internal Server Error
			// 	502 - Bad Gateway
			//	503 - Service Unavailable
			//  504 - Gateway Timeout (Issue #320)
			case 500,502,503,504:
				// No actions
				log.vlog("OneDrive returned a 'HTTP 5xx Server Side Error' - gracefully handling error");
				break;
			
			// Default - all other errors that are not a 2xx or a 302
			default:
			if (http.statusLine.code / 100 != 2 && http.statusLine.code != 302) {
				throw new OneDriveException(http.statusLine.code, http.statusLine.reason, response);
				break;
			}
		}
	}
}

unittest
{
	string configDirName = expandTilde("~/.config/onedrive");
	auto cfg = new config.Config(configDirName);
	cfg.init();
	OneDriveApi onedrive = new OneDriveApi(cfg);
	onedrive.init();
	std.file.write("/tmp/test", "test");

	// simpleUpload
	auto item = onedrive.simpleUpload("/tmp/test", "/test");
	try {
		item = onedrive.simpleUpload("/tmp/test", "/test");
	} catch (OneDriveException e) {
		assert(e.httpStatusCode == 409);
	}
	try {
		item = onedrive.simpleUpload("/tmp/test", "/test", "123");
	} catch (OneDriveException e) {
		assert(e.httpStatusCode == 412);
	}
	item = onedrive.simpleUpload("/tmp/test", "/test", item["eTag"].str);

	// deleteById
	try {
		onedrive.deleteById(item["id"].str, "123");
	} catch (OneDriveException e) {
		assert(e.httpStatusCode == 412);
	}
	onedrive.deleteById(item["id"].str, item["eTag"].str);
	onedrive.http.shutdown();
}
