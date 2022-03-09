import std.net.curl;
import etc.c.curl: CurlOption;
import std.datetime, std.datetime.systime, std.exception, std.file, std.json, std.path;
import std.stdio, std.string, std.uni, std.uri, std.file, std.uuid;
import std.array: split;
import core.atomic : atomicOp;
import core.stdc.stdlib;
import core.thread, std.conv, std.math;
import std.algorithm.searching;
import std.concurrency;
import progress;
import config;
import util;
import arsd.cgi;
static import log;
shared bool debugResponse = false;
private bool dryRun = false;
private bool simulateNoRefreshTokenFile = false;
private ulong retryAfterValue = 0;

private immutable {
	// Client ID / Application ID (abraunegg)
	string clientIdDefault = "d50ca740-c83f-4d1b-b616-12c519384f0c";

	// Azure Active Directory & Graph Explorer Endpoints
	// Global & Defaults
	string globalAuthEndpoint = "https://login.microsoftonline.com";
	string globalGraphEndpoint = "https://graph.microsoft.com";

	// US Government L4
	string usl4AuthEndpoint = "https://login.microsoftonline.us";
	string usl4GraphEndpoint = "https://graph.microsoft.us";

	// US Government L5
	string usl5AuthEndpoint = "https://login.microsoftonline.us";
	string usl5GraphEndpoint = "https://dod-graph.microsoft.us";

	// Germany
	string deAuthEndpoint = "https://login.microsoftonline.de";
	string deGraphEndpoint = "https://graph.microsoft.de";

	// China
	string cnAuthEndpoint = "https://login.chinacloudapi.cn";
	string cnGraphEndpoint = "https://microsoftgraph.chinacloudapi.cn";
}

private {
	// Client ID / Application ID
	string clientId = clientIdDefault;

	// Default User Agent configuration
	string isvTag = "ISV";
	string companyName = "abraunegg";
	// Application name as per Microsoft Azure application registration
	string appTitle = "OneDrive Client for Linux";

	// Default Drive ID
	string driveId = "";

	// API Query URL's, based on using defaults, but can be updated by config option 'azure_ad_endpoint'
	// Authentication
	string authUrl = globalAuthEndpoint ~ "/common/oauth2/v2.0/authorize";
	string redirectUrl = globalAuthEndpoint ~ "/common/oauth2/nativeclient";
	string tokenUrl = globalAuthEndpoint ~ "/common/oauth2/v2.0/token";

	// Drive Queries
	string driveUrl = globalGraphEndpoint ~ "/v1.0/me/drive";
	string driveByIdUrl = globalGraphEndpoint ~ "/v1.0/drives/";

	// What is 'shared with me' Query
	string sharedWithMeUrl = globalGraphEndpoint ~ "/v1.0/me/drive/sharedWithMe";

	// Item Queries
	string itemByIdUrl = globalGraphEndpoint ~ "/v1.0/me/drive/items/";
	string itemByPathUrl = globalGraphEndpoint ~ "/v1.0/me/drive/root:/";

	// Office 365 / SharePoint Queries
	string siteSearchUrl = globalGraphEndpoint ~ "/v1.0/sites?search";
	string siteDriveUrl = globalGraphEndpoint ~ "/v1.0/sites/";

	// Subscriptions
	string subscriptionUrl = globalGraphEndpoint ~ "/v1.0/subscriptions";
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

class OneDriveWebhook {
	// We need OneDriveWebhook.serve to be a static function, otherwise we would hit the member function
	// "requires a dual-context, which is deprecated" warning. The root cause is described here:
	//   - https://issues.dlang.org/show_bug.cgi?id=5710
	//   - https://forum.dlang.org/post/fkyppfxzegenniyzztos@forum.dlang.org
	// The problem is deemed a bug and should be fixed in the compilers eventually. The singleton stuff
	// could be undone when it is fixed.
	//
	// Following the singleton pattern described here: https://wiki.dlang.org/Low-Lock_Singleton_Pattern
	// Cache instantiation flag in thread-local bool
	// Thread local
	private static bool instantiated_;

	// Thread global
	private __gshared OneDriveWebhook instance_;

	private string host;
	private ushort port;
	private Tid parentTid;
	private shared uint count;

	static OneDriveWebhook getOrCreate(string host, ushort port, Tid parentTid) {
		if (!instantiated_) {
			synchronized(OneDriveWebhook.classinfo) {
				if (!instance_) {
						instance_ = new OneDriveWebhook(host, port, parentTid);
				}

				instantiated_ = true;
			}
		}

		return instance_;
	}

	private this(string host, ushort port, Tid parentTid) {
		this.host = host;
		this.port = port;
		this.parentTid = parentTid;
		this.count = 0;
	}

	// The static serve() is necessary because spawn() does not like instance methods
	static serve() {
		// we won't create the singleton instance if it hasn't been created already
		// such case is a bug which should crash the program and gets fixed
		instance_.serveImpl();
	}

	// The static handle() is necessary to work around the dual-context warning mentioned above
	private static void handle(Cgi cgi) {
		// we won't create the singleton instance if it hasn't been created already
		// such case is a bug which should crash the program and gets fixed
		instance_.handleImpl(cgi);
	}

	private void serveImpl() {
		auto server = new RequestServer(host, port);
		server.serveEmbeddedHttp!handle();
	}

	private void handleImpl(Cgi cgi) {
		if (.debugResponse) {
			log.log("Webhook request: ", cgi.requestMethod, " ", cgi.requestUri);
			if (!cgi.postBody.empty) {
				log.log("Webhook post body: ", cgi.postBody);
			}
		}

		cgi.setResponseContentType("text/plain");

		if ("validationToken" in cgi.get)	{
			// For validation requests, respond with the validation token passed in the query string
			// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/concepts/webhook-receiver-validation-request
			cgi.write(cgi.get["validationToken"]);
			log.log("Webhook: handled validation request");
		} else {
			// Notifications don't include any information about the changes that triggered them.
			// Put a refresh signal in the queue and let the main monitor loop process it.
			// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/concepts/using-webhooks
			count.atomicOp!"+="(1);
			send(parentTid, to!ulong(count));
			cgi.write("OK");
			log.log("Webhook: sent refresh signal #", count);
		}
	}
}

final class OneDriveApi
{
	private Config cfg;
	private string refreshToken, accessToken, subscriptionId;
	private SysTime accessTokenExpiration;
	private HTTP http;
	private OneDriveWebhook webhook;
	private SysTime subscriptionExpiration;
	private Duration subscriptionExpirationInterval, subscriptionRenewalInterval;
	private string notificationUrl;

	// if true, every new access token is printed
	bool printAccessToken;

	this(Config cfg)
	{
		this.cfg = cfg;
		http = HTTP();
		// Curl Timeout Handling
		// DNS lookup timeout
		http.dnsTimeout = (dur!"seconds"(5));
		// Timeout for connecting
		http.connectTimeout = (dur!"seconds"(10));
		// with the following settings we force
		// - if there is no data flow for 10min, abort
		// - if the download time for one item exceeds 1h, abort
		//
		// timeout for activity on connection
		// this translates into Curl's CURLOPT_LOW_SPEED_TIME
		// which says
		//   It contains the time in number seconds that the
		//   transfer speed should be below the CURLOPT_LOW_SPEED_LIMIT
		//   for the library to consider it too slow and abort.
		http.dataTimeout = (dur!"seconds"(600));
		// maximum time an operation is allowed to take
		// This includes dns resolution, connecting, data transfer, etc.
		http.operationTimeout = (dur!"seconds"(cfg.getValueLong("operation_timeout")));
		// Specify how many redirects should be allowed
		http.maxRedirects(5);

		// Do we enable curl debugging?
		if (cfg.getValueBool("debug_https")) {
			http.verbose = true;
			.debugResponse = true;
		}

		// Update clientId if application_id is set in config file
		if (cfg.getValueString("application_id") != "") {
			// an application_id is set in config file
			log.vdebug("Setting custom application_id to: " , cfg.getValueString("application_id"));
			clientId = cfg.getValueString("application_id");
			companyName = "custom_application";
		}

		// Configure tenant id value, if 'azure_tenant_id' is configured,
		// otherwise use the "common" multiplexer
		string tenantId = "common";
		if (cfg.getValueString("azure_tenant_id") != "") {
			// Use the value entered by the user
			tenantId = cfg.getValueString("azure_tenant_id");
		}

		// Configure Azure AD endpoints if 'azure_ad_endpoint' is configured
		string azureConfigValue = cfg.getValueString("azure_ad_endpoint");
		switch(azureConfigValue) {
			case "":
				if (tenantId == "common") {
					log.log("Configuring Global Azure AD Endpoints");
				} else {
					log.log("Configuring Global Azure AD Endpoints - Single Tenant Application");
				}
				// Authentication
				authUrl = globalAuthEndpoint ~ "/" ~ tenantId ~ "/oauth2/v2.0/authorize";
				redirectUrl = globalAuthEndpoint ~ "/" ~ tenantId ~ "/oauth2/nativeclient";
				tokenUrl = globalAuthEndpoint ~ "/" ~ tenantId ~ "/oauth2/v2.0/token";
				break;
			case "USL4":
				log.log("Configuring Azure AD for US Government Endpoints");
				// Authentication
				authUrl = usl4AuthEndpoint ~ "/" ~ tenantId ~ "/oauth2/v2.0/authorize";
				tokenUrl = usl4AuthEndpoint ~ "/" ~ tenantId ~ "/oauth2/v2.0/token";
				if (clientId == clientIdDefault) {
					// application_id == default
					log.vdebug("USL4 AD Endpoint but default application_id, redirectUrl needs to be aligned to globalAuthEndpoint");
					redirectUrl = globalAuthEndpoint ~ "/" ~ tenantId ~ "/oauth2/nativeclient";
				} else {
					// custom application_id
					redirectUrl = usl4AuthEndpoint ~ "/" ~ tenantId ~ "/oauth2/nativeclient";
				}

				// Drive Queries
				driveUrl = usl4GraphEndpoint ~ "/v1.0/me/drive";
				driveByIdUrl = usl4GraphEndpoint ~ "/v1.0/drives/";
				// Item Queries
				itemByIdUrl = usl4GraphEndpoint ~ "/v1.0/me/drive/items/";
				itemByPathUrl = usl4GraphEndpoint ~ "/v1.0/me/drive/root:/";
				// Office 365 / SharePoint Queries
				siteSearchUrl = usl4GraphEndpoint ~ "/v1.0/sites?search";
				siteDriveUrl = usl4GraphEndpoint ~ "/v1.0/sites/";
				// Shared With Me
				sharedWithMeUrl = usl4GraphEndpoint ~ "/v1.0/me/drive/sharedWithMe";
				// Subscriptions
				subscriptionUrl = usl4GraphEndpoint ~ "/v1.0/subscriptions";
				break;
			case "USL5":
				log.log("Configuring Azure AD for US Government Endpoints (DOD)");
				// Authentication
				authUrl = usl5AuthEndpoint ~ "/" ~ tenantId ~ "/oauth2/v2.0/authorize";
				tokenUrl = usl5AuthEndpoint ~ "/" ~ tenantId ~ "/oauth2/v2.0/token";
				if (clientId == clientIdDefault) {
					// application_id == default
					log.vdebug("USL5 AD Endpoint but default application_id, redirectUrl needs to be aligned to globalAuthEndpoint");
					redirectUrl = globalAuthEndpoint ~ "/" ~ tenantId ~ "/oauth2/nativeclient";
				} else {
					// custom application_id
					redirectUrl = usl5AuthEndpoint ~ "/" ~ tenantId ~ "/oauth2/nativeclient";
				}

				// Drive Queries
				driveUrl = usl5GraphEndpoint ~ "/v1.0/me/drive";
				driveByIdUrl = usl5GraphEndpoint ~ "/v1.0/drives/";
				// Item Queries
				itemByIdUrl = usl5GraphEndpoint ~ "/v1.0/me/drive/items/";
				itemByPathUrl = usl5GraphEndpoint ~ "/v1.0/me/drive/root:/";
				// Office 365 / SharePoint Queries
				siteSearchUrl = usl5GraphEndpoint ~ "/v1.0/sites?search";
				siteDriveUrl = usl5GraphEndpoint ~ "/v1.0/sites/";
				// Shared With Me
				sharedWithMeUrl = usl5GraphEndpoint ~ "/v1.0/me/drive/sharedWithMe";
				// Subscriptions
				subscriptionUrl = usl5GraphEndpoint ~ "/v1.0/subscriptions";
				break;
			case "DE":
				log.log("Configuring Azure AD Germany");
				// Authentication
				authUrl = deAuthEndpoint ~ "/" ~ tenantId ~ "/oauth2/v2.0/authorize";
				tokenUrl = deAuthEndpoint ~ "/" ~ tenantId ~ "/oauth2/v2.0/token";
				if (clientId == clientIdDefault) {
					// application_id == default
					log.vdebug("DE AD Endpoint but default application_id, redirectUrl needs to be aligned to globalAuthEndpoint");
					redirectUrl = globalAuthEndpoint ~ "/" ~ tenantId ~ "/oauth2/nativeclient";
				} else {
					// custom application_id
					redirectUrl = deAuthEndpoint ~ "/" ~ tenantId ~ "/oauth2/nativeclient";
				}

				// Drive Queries
				driveUrl = deGraphEndpoint ~ "/v1.0/me/drive";
				driveByIdUrl = deGraphEndpoint ~ "/v1.0/drives/";
				// Item Queries
				itemByIdUrl = deGraphEndpoint ~ "/v1.0/me/drive/items/";
				itemByPathUrl = deGraphEndpoint ~ "/v1.0/me/drive/root:/";
				// Office 365 / SharePoint Queries
				siteSearchUrl = deGraphEndpoint ~ "/v1.0/sites?search";
				siteDriveUrl = deGraphEndpoint ~ "/v1.0/sites/";
				// Shared With Me
				sharedWithMeUrl = deGraphEndpoint ~ "/v1.0/me/drive/sharedWithMe";
				// Subscriptions
				subscriptionUrl = deGraphEndpoint ~ "/v1.0/subscriptions";
				break;
			case "CN":
				log.log("Configuring AD China operated by 21Vianet");
				// Authentication
				authUrl = cnAuthEndpoint ~ "/" ~ tenantId ~ "/oauth2/v2.0/authorize";
				tokenUrl = cnAuthEndpoint ~ "/" ~ tenantId ~ "/oauth2/v2.0/token";
				if (clientId == clientIdDefault) {
					// application_id == default
					log.vdebug("CN AD Endpoint but default application_id, redirectUrl needs to be aligned to globalAuthEndpoint");
					redirectUrl = globalAuthEndpoint ~ "/" ~ tenantId ~ "/oauth2/nativeclient";
				} else {
					// custom application_id
					redirectUrl = cnAuthEndpoint ~ "/" ~ tenantId ~ "/oauth2/nativeclient";
				}

				// Drive Queries
				driveUrl = cnGraphEndpoint ~ "/v1.0/me/drive";
				driveByIdUrl = cnGraphEndpoint ~ "/v1.0/drives/";
				// Item Queries
				itemByIdUrl = cnGraphEndpoint ~ "/v1.0/me/drive/items/";
				itemByPathUrl = cnGraphEndpoint ~ "/v1.0/me/drive/root:/";
				// Office 365 / SharePoint Queries
				siteSearchUrl = cnGraphEndpoint ~ "/v1.0/sites?search";
				siteDriveUrl = cnGraphEndpoint ~ "/v1.0/sites/";
				// Shared With Me
				sharedWithMeUrl = cnGraphEndpoint ~ "/v1.0/me/drive/sharedWithMe";
				// Subscriptions
				subscriptionUrl = cnGraphEndpoint ~ "/v1.0/subscriptions";
				break;
			// Default - all other entries
			default:
				log.log("Unknown Azure AD Endpoint request - using Global Azure AD Endpoints");
		}

		// Debug output of configured URL's
		// Authentication
		log.vdebug("Configured authUrl:          ", authUrl);
		log.vdebug("Configured redirectUrl:      ", redirectUrl);
		log.vdebug("Configured tokenUrl:         ", tokenUrl);

		// Drive Queries
		log.vdebug("Configured driveUrl:         ", driveUrl);
		log.vdebug("Configured driveByIdUrl:     ", driveByIdUrl);

		// Shared With Me
		log.vdebug("Configured sharedWithMeUrl:  ", sharedWithMeUrl);

		// Item Queries
		log.vdebug("Configured itemByIdUrl:      ", itemByIdUrl);
		log.vdebug("Configured itemByPathUrl:    ", itemByPathUrl);

		// SharePoint Queries
		log.vdebug("Configured siteSearchUrl:    ", siteSearchUrl);
		log.vdebug("Configured siteDriveUrl:     ", siteDriveUrl);

		// Configure the User Agent string
		if (cfg.getValueString("user_agent") == "") {
			// Application User Agent string defaults
			// Comply with OneDrive traffic decoration requirements
			// https://docs.microsoft.com/en-us/sharepoint/dev/general-development/how-to-avoid-getting-throttled-or-blocked-in-sharepoint-online
			// - Identify as ISV and include Company Name, App Name separated by a pipe character and then adding Version number separated with a slash character
			// Note: If you've created an application, the recommendation is to register and use AppID and AppTitle
			// The issue here is that currently the application is still using the 'skilion' application ID, thus no idea what the AppTitle used was.
			http.setUserAgent = isvTag ~ "|" ~ companyName ~ "|" ~ appTitle ~ "/" ~ strip(import("version"));
		} else {
			// Use the value entered by the user
			http.setUserAgent = cfg.getValueString("user_agent");
		}

		// What version of HTTP protocol do we use?
		// Curl >= 7.62.0 defaults to http2 for a significant number of operations
		if (cfg.getValueBool("force_http_2")) {
			// Use curl defaults
			log.vdebug("Upgrading all HTTP operations to HTTP/2 where applicable");
		} else {
			// Downgrade curl by default due to silent exist issues when using http/2
			// See issue #501 for details and discussion
			log.vdebug("Downgrading all HTTP operations to HTTP/1.1 by default");
			// Downgrade to HTTP 1.1 - yes version = 2 is HTTP 1.1
			http.handle.set(CurlOption.http_version,2);
		}

		// Configure upload / download rate limits if configured
		long userRateLimit = cfg.getValueLong("rate_limit");
		// 131072 = 128 KB/s - minimum for basic application operations to prevent timeouts
		// A 0 value means rate is unlimited, and is the curl default

		if (userRateLimit > 0) {
			// User configured rate limit
			writeln("User Configured Rate Limit: ", userRateLimit);

			// If user provided rate limit is < 131072, flag that this is too low, setting to the minimum of 131072
			if (userRateLimit < 131072) {
				// user provided limit too low
				log.log("WARNING: User configured rate limit too low for normal application processing and preventing application timeouts. Overriding to default minimum of 131072 (128KB/s)");
				userRateLimit = 131072;
			}

			// set rate limit
			http.handle.set(CurlOption.max_send_speed_large,userRateLimit);
			http.handle.set(CurlOption.max_recv_speed_large,userRateLimit);
		}

		// Explicitly set libcurl options
		//   https://curl.se/libcurl/c/CURLOPT_NOSIGNAL.html
		//   Ensure that nosignal is set to 0 - Setting CURLOPT_NOSIGNAL to 0 makes libcurl ask the system to ignore SIGPIPE signals
		http.handle.set(CurlOption.nosignal,0);
		//   https://curl.se/libcurl/c/CURLOPT_TCP_NODELAY.html
		//   Ensure that TCP_NODELAY is set to 0 to ensure that TCP NAGLE is enabled
		http.handle.set(CurlOption.tcp_nodelay,0);
		//   https://curl.se/libcurl/c/CURLOPT_FORBID_REUSE.html
		//   Ensure that we ARE reusing connections - setting to 0 ensures that we are reusing connections
		http.handle.set(CurlOption.forbid_reuse,0);
		
		// Do we set the dryRun handlers?
		if (cfg.getValueBool("dry_run")) {
			.dryRun = true;
			if (cfg.getValueBool("logout")) {
				.simulateNoRefreshTokenFile = true;
			}
		}

		subscriptionExpiration = Clock.currTime(UTC());
		subscriptionExpirationInterval = dur!"seconds"(cfg.getValueLong("webhook_expiration_interval"));
		subscriptionRenewalInterval = dur!"seconds"(cfg.getValueLong("webhook_renewal_interval"));
		notificationUrl = cfg.getValueString("webhook_public_url");
	}

	// Shutdown OneDrive HTTP construct
	void shutdown()
	{
		// delete subscription if there exists any
		deleteSubscription();

		// reset any values to defaults, freeing any set objects
		http.clearRequestHeaders();
		http.onSend = null;
		http.onReceive = null;
		http.onReceiveHeader = null;
		http.onReceiveStatusLine = null;
		http.contentLength = 0;
		// shut down the curl instance
		http.shutdown();
	}

	bool init()
	{
		static import std.utf;
		// detail what we are using for applicaion identification
		log.vdebug("clientId    = ", clientId);
		log.vdebug("companyName = ", companyName);
		log.vdebug("appTitle    = ", appTitle);

		try {
			driveId = cfg.getValueString("drive_id");
			if (driveId.length) {
				driveUrl = driveByIdUrl ~ driveId;
				itemByIdUrl = driveUrl ~ "/items";
				itemByPathUrl = driveUrl ~ "/root:/";
			}
		} catch (Exception e) {}

		if (!.dryRun) {
			// original code
			try {
				refreshToken = readText(cfg.refreshTokenFilePath);
			} catch (FileException e) {
				try {
					return authorize();
				} catch (CurlException e) {
					log.error("Cannot authorize with Microsoft OneDrive Service");
					return false;
				}
			} catch (std.utf.UTFException e) {
				// path contains characters which generate a UTF exception
				log.error("Cannot read refreshToken from: ", cfg.refreshTokenFilePath);
				log.error("  Error Reason:", e.msg);
				return false;
			}
			return true;
		} else {
			// --dry-run
			if (!.simulateNoRefreshTokenFile) {
				try {
					refreshToken = readText(cfg.refreshTokenFilePath);
				} catch (FileException e) {
					return authorize();
				} catch (std.utf.UTFException e) {
					// path contains characters which generate a UTF exception
					log.error("Cannot read refreshToken from: ", cfg.refreshTokenFilePath);
					log.error("  Error Reason:", e.msg);
					return false;
				}
				return true;
			} else {
				// --dry-run & --reauth
				return authorize();
			}
		}
	}

	bool authorize()
	{
		import std.stdio, std.regex;
		char[] response;
		string url = authUrl ~ "?client_id=" ~ clientId ~ "&scope=Files.ReadWrite%20Files.ReadWrite.all%20Sites.Read.All%20Sites.ReadWrite.All%20offline_access&response_type=code&prompt=login&redirect_uri=" ~ redirectUrl;
		string authFilesString = cfg.getValueString("auth_files");
		string authResponseString = cfg.getValueString("auth_response");
		if (authResponseString != "") {
			response = cast(char[]) authResponseString;
		} else if (authFilesString != "") {
			string[] authFiles = authFilesString.split(":");
			string authUrl = authFiles[0];
			string responseUrl = authFiles[1];
			auto authUrlFile = File(authUrl, "w");
			authUrlFile.write(url);
			authUrlFile.close();
			while (!exists(responseUrl)) {
				Thread.sleep(dur!("msecs")(100));
			}

			// read response from OneDrive
			try {
				response = cast(char[]) read(responseUrl);
			} catch (OneDriveException e) {
				// exception generated
				displayOneDriveErrorMessage(e.msg, getFunctionName!({}));
				return false;
			}

			// try to remove old files
			try {
				std.file.remove(authUrl);
				std.file.remove(responseUrl);
			} catch (FileException e) {
				log.error("Cannot remove files ", authUrl, " ", responseUrl);
				return false;
			}
		} else {
			log.log("Authorize this app visiting:\n");
			write(url, "\n\n", "Enter the response uri: ");
			readln(response);
			cfg.applicationAuthorizeResponseUri = true;
		}
		// match the authorization code
		auto c = matchFirst(response, r"(?:[\?&]code=)([\w\d-.]+)");
		if (c.empty) {
			log.log("Invalid uri");
			return false;
		}
		c.popFront(); // skip the whole match
		redeemToken(c.front);
		return true;
	}

	ulong getRetryAfterValue()
	{
		// Return the current value of retryAfterValue if it has been set to something other than 0
		return .retryAfterValue;
	}

	void resetRetryAfterValue()
	{
		// Reset the current value of retryAfterValue to 0 after it has been used
		.retryAfterValue = 0;
	}

	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/drive_get
	JSONValue getDefaultDrive()
	{
		checkAccessTokenExpired();
		const(char)[] url;
		url = driveUrl;
		return get(driveUrl);
	}

	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_get
	JSONValue getDefaultRoot()
	{
		checkAccessTokenExpired();
		const(char)[] url;
		url = driveUrl ~ "/root";
		return get(url);
	}

	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_get
	JSONValue getDriveIdRoot(const(char)[] driveId)
	{
		checkAccessTokenExpired();
		const(char)[] url;
		url = driveByIdUrl ~ driveId ~ "/root";
		return get(url);
	}

	// https://docs.microsoft.com/en-us/graph/api/drive-sharedwithme
	JSONValue getSharedWithMe()
	{
		checkAccessTokenExpired();
		return get(sharedWithMeUrl);
	}

	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/drive_get
	JSONValue getDriveQuota(const(char)[] driveId)
	{
		checkAccessTokenExpired();
		const(char)[] url;
		url = driveByIdUrl ~ driveId ~ "/";
		url ~= "?select=quota";
		return get(url);
	}

	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_delta
	JSONValue viewChangesByItemId(const(char)[] driveId, const(char)[] id, const(char)[] deltaLink)
	{
		checkAccessTokenExpired();
		const(char)[] url;
		// configure deltaLink to query
		if (deltaLink.empty) {
			url = driveByIdUrl ~ driveId ~ "/items/" ~ id ~ "/delta";
			url ~= "?select=id,name,eTag,cTag,deleted,file,folder,root,fileSystemInfo,remoteItem,parentReference,size";
		} else {
			url = deltaLink;
		}
		return get(url);
	}

	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_delta
	JSONValue viewChangesByDriveId(const(char)[] driveId, const(char)[] deltaLink)
	{
		checkAccessTokenExpired();
		const(char)[] url = deltaLink;
		if (url == null) {
			url = driveByIdUrl ~ driveId ~ "/root/delta";
			url ~= "?select=id,name,eTag,cTag,deleted,file,folder,root,fileSystemInfo,remoteItem,parentReference,size";
		}
		return get(url);
	}

	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_list_children
	JSONValue listChildren(const(char)[] driveId, const(char)[] id, const(char)[] nextLink)
	{
		checkAccessTokenExpired();
		const(char)[] url;
		// configure URL to query
		if (nextLink.empty) {
			url = driveByIdUrl ~ driveId ~ "/items/" ~ id ~ "/children";
			url ~= "?select=id,name,eTag,cTag,deleted,file,folder,root,fileSystemInfo,remoteItem,parentReference,size";
		} else {
			url = nextLink;
		}
		return get(url);
	}

	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_get_content
	void downloadById(const(char)[] driveId, const(char)[] id, string saveToPath, long fileSize)
	{
		checkAccessTokenExpired();
		scope(failure) {
			if (exists(saveToPath)) {
				// try and remove the file, catch error
				try {
					remove(saveToPath);
				} catch (FileException e) {
					// display the error message
					displayFileSystemErrorMessage(e.msg, getFunctionName!({}));
				}
			}
		}

		// Create the required local directory
		string newPath = dirName(saveToPath);

		// Does the path exist locally?
		if (!exists(newPath)) {
			try {
				log.vdebug("Requested path does not exist, creating directory structure: ", newPath);
				mkdirRecurse(newPath);
				// Configure the applicable permissions for the folder
				log.vdebug("Setting directory permissions for: ", newPath);
				newPath.setAttributes(cfg.returnRequiredDirectoryPermisions());
			} catch (FileException e) {
				// display the error message
				displayFileSystemErrorMessage(e.msg, getFunctionName!({}));
			}
		}

		const(char)[] url = driveByIdUrl ~ driveId ~ "/items/" ~ id ~ "/content?AVOverride=1";
		// Download file
		download(url, saveToPath, fileSize);
		// Does path exist?
		if (exists(saveToPath)) {
			// File was downloaded sucessfully - configure the applicable permissions for the file
			log.vdebug("Setting file permissions for: ", saveToPath);
			saveToPath.setAttributes(cfg.returnRequiredFilePermisions());
		}
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
		if ((path == ".")||(path == "/")) url = driveUrl ~ "/root/";
		else url = itemByPathUrl ~ encodeComponent(path) ~ ":/";
		url ~= "?select=id,name,eTag,cTag,deleted,file,folder,root,fileSystemInfo,remoteItem,parentReference,size";
		return get(url);
	}

	// Return the details of the specified id
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_get
	JSONValue getPathDetailsById(const(char)[] driveId, const(char)[] id)
	{
		checkAccessTokenExpired();
		const(char)[] url;
		url = driveByIdUrl ~ driveId ~ "/items/" ~ id;
		url ~= "?select=id,name,eTag,cTag,deleted,file,folder,root,fileSystemInfo,remoteItem,parentReference,size";
		return get(url);
	}

	// Return the requested details of the specified path on the specified drive id and path
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_get?view=odsp-graph-online
	JSONValue getPathDetailsByDriveId(const(char)[] driveId, const(string) path)
	{
		checkAccessTokenExpired();
		const(char)[] url;
		//		string driveByIdUrl = "https://graph.microsoft.com/v1.0/drives/";
		// Required format: /drives/{drive-id}/root:/{item-path}
		url = driveByIdUrl ~ driveId ~ "/root:/" ~ encodeComponent(path);
		url ~= "?select=id,name,eTag,cTag,deleted,file,folder,root,fileSystemInfo,remoteItem,parentReference,size";
		return get(url);
	}

	// Return the requested details of the specified path on the specified drive id and item id
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_get?view=odsp-graph-online
	JSONValue getPathDetailsByDriveIdAndItemId(const(char)[] driveId, const(char)[] itemId)
	{
		checkAccessTokenExpired();
		const(char)[] url;
		//		string driveByIdUrl = "https://graph.microsoft.com/v1.0/drives/";
		// Required format: /drives/{drive-id}/items/{item-id}
		url = driveByIdUrl ~ driveId ~ "/items/" ~ itemId;
		url ~= "?select=id,name,eTag,cTag,deleted,file,folder,root,fileSystemInfo,remoteItem,parentReference,size";
		return get(url);
	}

	// Return the requested details of the specified id
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_get
	JSONValue getFileDetails(const(char)[] driveId, const(char)[] id)
	{
		checkAccessTokenExpired();
		const(char)[] url;
		url = driveByIdUrl ~ driveId ~ "/items/" ~ id;
		url ~= "?select=size,malware,file,webUrl,lastModifiedBy,lastModifiedDateTime";
		return get(url);
	}

	// Create an anonymous read-only shareable link for an existing file on OneDrive
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_createlink
	JSONValue createShareableLink(const(char)[] driveId, const(char)[] id, JSONValue accessScope)
	{
		checkAccessTokenExpired();
		const(char)[] url;
		url = driveByIdUrl ~ driveId ~ "/items/" ~ id ~ "/createLink";
		http.addRequestHeader("Content-Type", "application/json");
		return post(url, accessScope.toString());
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
		// open file as read-only in binary mode
		auto file = File(filepath, "rb");
		file.seek(offset);
		string contentRange = "bytes " ~ to!string(offset) ~ "-" ~ to!string(offset + offsetSize - 1) ~ "/" ~ to!string(fileSize);
		log.vdebugNewLine("contentRange: ", contentRange);

		// function scopes
		scope(exit) {
			http.clearRequestHeaders();
			http.onSend = null;
			http.onReceive = null;
			http.onReceiveHeader = null;
			http.onReceiveStatusLine = null;
			http.contentLength = 0;
			// close file if open
			if (file.isOpen()){
				// close open file
				file.close();
			}
		}

		http.method = HTTP.Method.put;
		http.url = uploadUrl;
		http.addRequestHeader("Content-Range", contentRange);
		http.onSend = data => file.rawRead(data).length;
		// convert offsetSize to ulong
		http.contentLength = to!ulong(offsetSize);
		auto response = perform();
		// TODO: retry on 5xx errors
		checkHttpCode(response);
		return response;
	}

	// https://dev.onedrive.com/items/upload_large_files.htm
	JSONValue requestUploadStatus(const(char)[] uploadUrl)
	{
		checkAccessTokenExpired();
		// when using microsoft graph the auth code is different
		return get(uploadUrl, true);
	}

	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/site_search?view=odsp-graph-online
	JSONValue o365SiteSearch(const(char)[] nextLink){
		checkAccessTokenExpired();
		const(char)[] url;
		// configure URL to query
		if (nextLink.empty) {
			url = siteSearchUrl ~ "=*";
		} else {
			url = nextLink;
		}
		return get(url);
	}

	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/drive_list?view=odsp-graph-online
	JSONValue o365SiteDrives(string site_id){
		checkAccessTokenExpired();
		const(char)[] url;
		url = siteDriveUrl ~ site_id ~ "/drives";
		return get(url);
	}

	// Create a new subscription or renew the existing subscription
	void createOrRenewSubscription() {
		checkAccessTokenExpired();

		// Kick off the webhook server first
		if (webhook is null) {
			webhook = OneDriveWebhook.getOrCreate(
				cfg.getValueString("webhook_listening_host"),
				to!ushort(cfg.getValueLong("webhook_listening_port")),
				thisTid
			);
			spawn(&OneDriveWebhook.serve);
		}

		if (!hasValidSubscription()) {
			createSubscription();
		} else if (isSubscriptionUpForRenewal()) {
			try {
				renewSubscription();
			} catch (OneDriveException e) {
				if (e.httpStatusCode == 404) {
					log.log("The subscription is not found on the server. Recreating subscription ...");
					createSubscription();
				}
			}
		}
	}

	private bool hasValidSubscription() {
		return !subscriptionId.empty && subscriptionExpiration > Clock.currTime(UTC());
	}

	private bool isSubscriptionUpForRenewal() {
		return subscriptionExpiration < Clock.currTime(UTC()) + subscriptionRenewalInterval;
	}

	private void createSubscription() {
		log.log("Initializing subscription for updates ...");

		auto expirationDateTime = Clock.currTime(UTC()) + subscriptionExpirationInterval;
		const(char)[] url;
		url = subscriptionUrl;
		const JSONValue request = [
			"changeType": "updated",
			"notificationUrl": notificationUrl,
			"resource": "/me/drive/root",
			"expirationDateTime": expirationDateTime.toISOExtString(),
 			"clientState": randomUUID().toString()
		];
		http.addRequestHeader("Content-Type", "application/json");
		JSONValue response;

		try {
			response = post(url, request.toString());
		} catch (OneDriveException e) {
			displayOneDriveErrorMessage(e.msg, getFunctionName!({}));
			
			// We need to exit here, user needs to fix issue
			log.error("ERROR: Unable to initialize subscriptions for updates. Please fix this issue.");
			exit(-1);
		}

		// Save important subscription metadata including id and expiration
		subscriptionId = response["id"].str;
		subscriptionExpiration = SysTime.fromISOExtString(response["expirationDateTime"].str);
	}

	private void renewSubscription() {
		log.log("Renewing subscription for updates ...");

		auto expirationDateTime = Clock.currTime(UTC()) + subscriptionExpirationInterval;
		const(char)[] url;
		url = subscriptionUrl ~ "/" ~ subscriptionId;
		const JSONValue request = [
			"expirationDateTime": expirationDateTime.toISOExtString()
		];
		http.addRequestHeader("Content-Type", "application/json");
		JSONValue response = patch(url, request.toString());

		// Update subscription expiration from the response
		subscriptionExpiration = SysTime.fromISOExtString(response["expirationDateTime"].str);
	}

	private void deleteSubscription() {
		if (!hasValidSubscription()) {
			return;
		}

		const(char)[] url;
		url = subscriptionUrl ~ "/" ~ subscriptionId;
		del(url);
		log.log("Deleted subscription");
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
		JSONValue response;

		try {
			response = post(tokenUrl, postData);
		} catch (OneDriveException e) {
			// an error was generated
			displayOneDriveErrorMessage(e.msg, getFunctionName!({}));
		}

		if (response.type() == JSONType.object) {
			if ("access_token" in response){
				accessToken = "bearer " ~ response["access_token"].str();
				refreshToken = response["refresh_token"].str();
				accessTokenExpiration = Clock.currTime() + dur!"seconds"(response["expires_in"].integer());
				if (!.dryRun) {
					try {
						// try and update the refresh_token file
						std.file.write(cfg.refreshTokenFilePath, refreshToken);
						log.vdebug("Setting file permissions for: ", cfg.refreshTokenFilePath);
						cfg.refreshTokenFilePath.setAttributes(cfg.returnRequiredFilePermisions());
					} catch (FileException e) {
						// display the error message
						displayFileSystemErrorMessage(e.msg, getFunctionName!({}));
					}
				}
				if (printAccessToken) writeln("New access token: ", accessToken);
			} else {
				log.error("\nInvalid authentication response from OneDrive. Please check the response uri\n");
				// re-authorize
				authorize();
			}
		} else {
			log.vdebug("Invalid JSON response from OneDrive unable to initialize application");
		}
	}

	private void checkAccessTokenExpired()
	{
		try {
			if (Clock.currTime() >= accessTokenExpiration) {
				newToken();
			}
		} catch (OneDriveException e) {
			if (e.httpStatusCode == 400 || e.httpStatusCode == 401) {
				// flag error and notify
				log.errorAndNotify("\nERROR: Refresh token invalid, use --reauth to authorize the client again.\n");
				// set error message
				e.msg ~= "\nRefresh token invalid, use --reauth to authorize the client again";
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
		log.vdebug("Request URL = ", url);
		http.method = HTTP.Method.get;
		http.url = url;
		if (!skipToken) addAccessTokenHeader(); // HACK: requestUploadStatus
		JSONValue response;
		response = perform();
		checkHttpCode(response);
		// OneDrive API Response Debugging if --https-debug is being used
		if (.debugResponse){
			log.vdebug("OneDrive API Response: ", response);
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
		
		// To support marking of partially-downloaded files, 
		string originalFilename = filename;
		string downloadFilename = filename ~ ".partial";
		
		// open downloadFilename as write in binary mode
		auto file = File(downloadFilename, "wb");

		// function scopes
		scope(exit) {
			http.clearRequestHeaders();
			http.onSend = null;
			http.onReceive = null;
			http.onReceiveHeader = null;
			http.onReceiveStatusLine = null;
			http.contentLength = 0;
			// Reset onProgress to not display anything for next download
			http.onProgress = delegate int(size_t dltotal, size_t dlnow, size_t ultotal, size_t ulnow)
			{
				return 0;
			};
			// close file if open
			if (file.isOpen()){
				// close open file
				file.close();
			}
		}

		http.method = HTTP.Method.get;
		http.url = url;
		addAccessTokenHeader();

		http.onReceive = (ubyte[] data) {
			file.rawWrite(data);
			return data.length;
		};

		if (fileSize >= thresholdFileSize){
			// Download Progress Bar
			size_t iteration = 20;
			Progress p = new Progress(iteration);
			p.title = "Downloading";
			writeln();
			bool barInit = false;
			real previousDLPercent = -1.0;
			real percentCheck = 5.0;
			// Setup progress bar to display
			http.onProgress = delegate int(size_t dltotal, size_t dlnow, size_t ultotal, size_t ulnow)
			{
				// For each onProgress, what is the % of dlnow to dltotal
				// floor - rounds down to nearest whole number
				real currentDLPercent = floor(double(dlnow)/dltotal*100);
				if (currentDLPercent > 0){
					// We have started downloading
					// If matching 5% of download, increment progress bar
					if ((isIdentical(fmod(currentDLPercent, percentCheck), 0.0)) && (previousDLPercent != currentDLPercent)) {
						// What have we downloaded thus far
						log.vdebugNewLine("Data Received  = ", dlnow);
						log.vdebug("Expected Total = ", dltotal);
						log.vdebug("Percent Complete = ", currentDLPercent);
						// Increment counter & show bar update
						p.next();
						previousDLPercent = currentDLPercent;
					}
				} else {
					if ((currentDLPercent == 0) && (!barInit)) {
						// Initialise the download bar at 0%
						// Downloading   0% |                                        |   ETA   --:--:--:^C
						p.next();
						barInit = true;
					}
				}
				return 0;
			};

			// Perform download & display progress bar
			try {
				// try and catch any curl error
				http.perform();
				// Check the HTTP Response headers - needed for correct 429 handling
				// check will be performed in checkHttpCode()
				writeln();
				// Reset onProgress to not display anything for next download done using exit scope
			} catch (CurlException e) {
				displayOneDriveErrorMessage(e.msg, getFunctionName!({}));
			}
			// free progress bar memory
			p = null;
		} else {
			// No progress bar
			try {
				// try and catch any curl error
				http.perform();
				// Check the HTTP Response headers - needed for correct 429 handling
				// check will be performed in checkHttpCode()
			} catch (CurlException e) {
				displayOneDriveErrorMessage(e.msg, getFunctionName!({}));
			}
		}

		// Rename downloaded file
		rename(downloadFilename, originalFilename);

		// Check the HTTP response code, which, if a 429, will also check response headers
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
		// Check the HTTP response code, which, if a 429, will also check response headers
		checkHttpCode();
		return response;
	}

	private JSONValue upload(string filepath, string url)
	{
		checkAccessTokenExpired();
		// open file as read-only in binary mode
		auto file = File(filepath, "rb");

		// function scopes
		scope(exit) {
			http.clearRequestHeaders();
			http.onSend = null;
			http.onReceive = null;
			http.onReceiveHeader = null;
			http.onReceiveStatusLine = null;
			http.contentLength = 0;
			// close file if open
			if (file.isOpen()){
				// close open file
				file.close();
			}
		}

		http.method = HTTP.Method.put;
		http.url = url;
		addAccessTokenHeader();
		http.addRequestHeader("Content-Type", "application/octet-stream");
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
		auto response = perform();
		return response;
	}

	private JSONValue perform()
	{
		scope(exit) http.onReceive = null;
		char[] content;
		JSONValue json;

		http.onReceive = (ubyte[] data) {
			content ~= data;
			// HTTP Server Response Code Debugging if --https-debug is being used
			if (.debugResponse){
				log.vdebug("onedrive.perform() => OneDrive HTTP Server Response: ", http.statusLine.code);
			}
			return data.length;
		};

		try {
			http.perform();
			// Check the HTTP Response headers - needed for correct 429 handling
			checkHTTPResponseHeaders();
		} catch (CurlException e) {
			// Parse and display error message received from OneDrive
			log.vdebug("onedrive.perform() Generated a OneDrive CurlException");
			log.error("ERROR: OneDrive returned an error with the following message:");
			auto errorArray = splitLines(e.msg);
			string errorMessage = errorArray[0];
			string defaultTimeoutErrorMessage = "  Error Message: There was a timeout in accessing the Microsoft OneDrive service - Internet connectivity issue?";

			if (canFind(errorMessage, "Couldn't connect to server on handle") || canFind(errorMessage, "Couldn't resolve host name on handle") || canFind(errorMessage, "Timeout was reached on handle")) {
				// This is a curl timeout
				log.error(defaultTimeoutErrorMessage);
				// or 408 request timeout
				// https://github.com/abraunegg/onedrive/issues/694
				// Back off & retry with incremental delay
				int retryCount = 10000;
				int retryAttempts = 1;
				int backoffInterval = 1;
				int maxBackoffInterval = 3600;
				bool retrySuccess = false;
				while (!retrySuccess){
					backoffInterval++;
					int thisBackOffInterval = retryAttempts*backoffInterval;
					log.vdebug("  Retry Attempt:      ", retryAttempts);
					if (thisBackOffInterval <= maxBackoffInterval) {
						log.vdebug("  Retry In (seconds): ", thisBackOffInterval);
						Thread.sleep(dur!"seconds"(thisBackOffInterval));
					} else {
						log.vdebug("  Retry In (seconds): ", maxBackoffInterval);
						Thread.sleep(dur!"seconds"(maxBackoffInterval));
					}
					try {
						http.perform();
						// Check the HTTP Response headers - needed for correct 429 handling
						checkHTTPResponseHeaders();
						// no error from http.perform() on re-try
						log.log("Internet connectivity to Microsoft OneDrive service has been restored");
						retrySuccess = true;
					} catch (CurlException e) {
						if (canFind(e.msg, "Couldn't connect to server on handle") || canFind(e.msg, "Couldn't resolve host name on handle") || canFind(errorMessage, "Timeout was reached on handle")) {
							log.error(defaultTimeoutErrorMessage);
							// Increment & loop around
							retryAttempts++;
						}
						if (retryAttempts == retryCount) {
							// we have attempted to re-connect X number of times
							// false set this to true to break out of while loop
							retrySuccess = true;
						}
					}
				}
				if (retryAttempts >= retryCount) {
					log.error("  Error Message: Was unable to reconnect to the Microsoft OneDrive service after 10000 attempts lasting over 1.2 years!");
					throw new OneDriveException(408, "Request Timeout - HTTP 408 or Internet down?");
				}
			} else {
				// Some other error was returned
				log.error("  Error Message: ", errorMessage);
				log.error("  Calling Function: ", getFunctionName!({}));
			}
			// return an empty JSON for handling
			return json;
		}

		try {
			json = content.parseJSON();
		} catch (JSONException e) {
			// Log that a JSON Exception was caught, dont output the HTML response from OneDrive
			log.vdebug("JSON Exception caught when performing HTTP operations - use --debug-https to diagnose further");
		}
		return json;
	}

	private void checkHTTPResponseHeaders()
	{
		// Get the HTTP Response headers - needed for correct 429 handling
		auto responseHeaders = http.responseHeaders();
		if (.debugResponse){
			log.vdebug("http.perform() => HTTP Response Headers: ", responseHeaders);
		}

		// is retry-after in the response headers
		if ("retry-after" in http.responseHeaders) {
			// Set the retry-after value
			log.vdebug("http.perform() => Received a 'Retry-After' Header Response with the following value: ", http.responseHeaders["retry-after"]);
			log.vdebug("http.perform() => Setting retryAfterValue to: ", http.responseHeaders["retry-after"]);
			.retryAfterValue = to!ulong(http.responseHeaders["retry-after"]);
		}
	}

	private void checkHttpCode()
	{
		// https://dev.onedrive.com/misc/errors.htm
		// https://developer.overdrive.com/docs/reference-guide

		/*
			HTTP/1.1 Response handling

			Errors in the OneDrive API are returned using standard HTTP status codes, as well as a JSON error response object. The following HTTP status codes should be expected.

			Status code		Status message						Description
			100				Continue							Continue
			200 			OK									Request was handled OK
			201 			Created								This means you've made a successful POST to checkout, lock in a format, or place a hold
			204				No Content							This means you've made a successful DELETE to remove a hold or return a title

			400				Bad Request							Cannot process the request because it is malformed or incorrect.
			401				Unauthorized						Required authentication information is either missing or not valid for the resource.
			403				Forbidden							Access is denied to the requested resource. The user might not have enough permission.
			404				Not Found							The requested resource doesn’t exist.
			405				Method Not Allowed					The HTTP method in the request is not allowed on the resource.
			406				Not Acceptable						This service doesn’t support the format requested in the Accept header.
			408				Request Time out					Not expected from OneDrive, but can be used to handle Internet connection failures the same (fallback and try again)
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
			//  0 - OK ... HTTP2 version of 200 OK
			case 0:
				break;
			//  100 - Continue
			case 100:
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

			// 403 - Forbidden
			case 403:
				// OneDrive responded that the user is forbidden
				log.vlog("OneDrive returned a 'HTTP 403 - Forbidden' - gracefully handling error");
				break;

			// 404 - Item not found
			case 404:
				// Item was not found - do not throw an exception
				log.vlog("OneDrive returned a 'HTTP 404 - Item not found' - gracefully handling error");
				break;

			//	408 - Request Timeout
			case 408:
				// Request to connect to OneDrive service timed out
				log.vlog("Request Timeout - gracefully handling error");
				throw new OneDriveException(408, "Request Timeout - HTTP 408 or Internet down?");

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
				// Check the HTTP Response headers - needed for correct 429 handling
				checkHTTPResponseHeaders();
				// https://docs.microsoft.com/en-us/sharepoint/dev/general-development/how-to-avoid-getting-throttled-or-blocked-in-sharepoint-online
				log.vlog("OneDrive returned a 'HTTP 429 - Too Many Requests' - gracefully handling error");
				throw new OneDriveException(http.statusLine.code, http.statusLine.reason);

			// Server side (OneDrive) Errors
			//  500 - Internal Server Error
			// 	502 - Bad Gateway
			//	503 - Service Unavailable
			//  504 - Gateway Timeout (Issue #320)
			case 500:
				// No actions
				log.vlog("OneDrive returned a 'HTTP 500 Internal Server Error' - gracefully handling error");
				break;

			case 502:
				// No actions
				log.vlog("OneDrive returned a 'HTTP 502 Bad Gateway Error' - gracefully handling error");
				break;

			case 503:
				// No actions
				log.vlog("OneDrive returned a 'HTTP 503 Service Unavailable Error' - gracefully handling error");
				break;

			case 504:
				// No actions
				log.vlog("OneDrive returned a 'HTTP 504 Gateway Timeout Error' - gracefully handling error");
				break;

			// "else"
			default:
				throw new OneDriveException(http.statusLine.code, http.statusLine.reason);
		}
	}

	private void checkHttpCode(ref const JSONValue response)
	{
		switch(http.statusLine.code)
		{
			//  0 - OK ... HTTP2 version of 200 OK
			case 0:
				break;
			//  100 - Continue
			case 100:
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
				// make sure this is thrown so that it is caught
				throw new OneDriveException(http.statusLine.code, http.statusLine.reason, response);

			// 403 - Forbidden
			case 403:
				// OneDrive responded that the user is forbidden
				log.vlog("OneDrive returned a 'HTTP 403 - Forbidden' - gracefully handling error");
				// Throw this as a specific exception so this is caught when performing sync.o365SiteSearch
				throw new OneDriveException(http.statusLine.code, http.statusLine.reason, response);

			//	412 - Precondition Failed
			case 412:
				// Throw this as a specific exception so this is caught when performing sync.uploadLastModifiedTime
				throw new OneDriveException(http.statusLine.code, http.statusLine.reason, response);

			// Server side (OneDrive) Errors
			//  500 - Internal Server Error
			// 	502 - Bad Gateway
			//	503 - Service Unavailable
			//  504 - Gateway Timeout (Issue #320)
			case 500:
				// Throw this as a specific exception so this is caught
				throw new OneDriveException(http.statusLine.code, http.statusLine.reason, response);

			case 502:
				// Throw this as a specific exception so this is caught
				throw new OneDriveException(http.statusLine.code, http.statusLine.reason, response);

			case 503:
				// Throw this as a specific exception so this is caught
				throw new OneDriveException(http.statusLine.code, http.statusLine.reason, response);

			case 504:
				// Throw this as a specific exception so this is caught
				throw new OneDriveException(http.statusLine.code, http.statusLine.reason, response);

			// Default - all other errors that are not a 2xx or a 302
			default:
			if (http.statusLine.code / 100 != 2 && http.statusLine.code != 302) {
				throw new OneDriveException(http.statusLine.code, http.statusLine.reason, response);
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
