// What is this module called?
module onedrive;

// What does this module require to function?
import core.stdc.stdlib: EXIT_SUCCESS, EXIT_FAILURE, exit;
import core.memory;
import core.thread;
import std.stdio;
import std.string;
import std.utf;
import std.file;
import std.exception;
import std.regex;
import std.json;
import std.algorithm.searching;
import std.net.curl;
import std.datetime;
import std.path;
import std.conv;
import std.math;
import std.uri;
import std.array;

// Required for webhooks
import arsd.cgi;
import std.concurrency;
import core.atomic : atomicOp;
import std.uuid;

// What other modules that we have created do we need to import?
import config;
import log;
import util;
import curlEngine;

// Shared variables between classes
shared bool debugHTTPResponseOutput = false;

class OneDriveException: Exception {
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/concepts/errors
	int httpStatusCode;
	JSONValue error;

	@safe pure this(int httpStatusCode, string reason, string file = __FILE__, size_t line = __LINE__) {
		this.httpStatusCode = httpStatusCode;
		this.error = error;
		string msg = format("HTTP request returned status code %d (%s)", httpStatusCode, reason);
		super(msg, file, line);
	}

	this(int httpStatusCode, string reason, ref const JSONValue error, string file = __FILE__, size_t line = __LINE__) {
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
	private RequestServer server;

	// Thread global
	private __gshared OneDriveWebhook instance_;

	private string host;
	private ushort port;
	private Tid parentTid;
	private shared uint count;
	private bool started;

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
	
	void serve() {
		spawn(&serveStatic);
		this.started = true;
		addLogEntry("Started webhook server");
	}

	void stop() {
		if (this.started) {
			server.stop();
			this.started = false;
		}
		addLogEntry("Stopped webhook server");
		object.destroy(server);
	}

	// The static serve() is necessary because spawn() does not like instance methods
	private static void serveStatic() {
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
		server = RequestServer(host, port);
		server.serveEmbeddedHttp!handle();
	}

	private void handleImpl(Cgi cgi) {
		if (debugHTTPResponseOutput) {
			addLogEntry("Webhook request: " ~ to!string(cgi.requestMethod) ~ " " ~ to!string(cgi.requestUri));
			if (!cgi.postBody.empty) {
				addLogEntry("Webhook post body: " ~ to!string(cgi.postBody));
			}
		}

		cgi.setResponseContentType("text/plain");

		if ("validationToken" in cgi.get)	{
			// For validation requests, respond with the validation token passed in the query string
			// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/concepts/webhook-receiver-validation-request
			cgi.write(cgi.get["validationToken"]);
			addLogEntry("Webhook: handled validation request");
		} else {
			// Notifications don't include any information about the changes that triggered them.
			// Put a refresh signal in the queue and let the main monitor loop process it.
			// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/concepts/using-webhooks
			count.atomicOp!"+="(1);
			send(parentTid, to!ulong(count));
			cgi.write("OK");
			addLogEntry("Webhook: sent refresh signal #" ~ to!string(count));
		}
	}
}

class OneDriveApi {
	// Class variables
	ApplicationConfig appConfig;
	CurlEngine curlEngine;
	OneDriveWebhook webhook;
	
	string clientId = "";
	string companyName = "";
	string authUrl = "";
	string redirectUrl = "";
	string tokenUrl = "";
	string driveUrl = "";
	string driveByIdUrl = "";
	string sharedWithMeUrl = "";
	string itemByIdUrl = "";
	string itemByPathUrl = "";
	string siteSearchUrl = "";
	string siteDriveUrl = "";
	string tenantId = "";
	string authScope = "";
	const(char)[] refreshToken = "";
	bool dryRun = false;
	bool debugResponse = false;
	ulong retryAfterValue = 0;
	
	// Webhook Subscriptions
	string subscriptionUrl = "";
	string subscriptionId = "";
	SysTime subscriptionExpiration, subscriptionLastErrorAt;
	Duration subscriptionExpirationInterval, subscriptionRenewalInterval, subscriptionRetryInterval;
	string notificationUrl = "";
	
	this(ApplicationConfig appConfig) {
		// Configure the class varaible to consume the application configuration
		this.appConfig = appConfig;
		// Configure the major API Query URL's, based on using application configuration
		// These however can be updated by config option 'azure_ad_endpoint', thus handled differently
		
		// Drive Queries
		driveUrl = appConfig.globalGraphEndpoint ~ "/v1.0/me/drive";
		driveByIdUrl = appConfig.globalGraphEndpoint ~ "/v1.0/drives/";

		// What is 'shared with me' Query
		sharedWithMeUrl = appConfig.globalGraphEndpoint ~ "/v1.0/me/drive/sharedWithMe";

		// Item Queries
		itemByIdUrl = appConfig.globalGraphEndpoint ~ "/v1.0/me/drive/items/";
		itemByPathUrl = appConfig.globalGraphEndpoint ~ "/v1.0/me/drive/root:/";

		// Office 365 / SharePoint Queries
		siteSearchUrl = appConfig.globalGraphEndpoint ~ "/v1.0/sites?search";
		siteDriveUrl = appConfig.globalGraphEndpoint ~ "/v1.0/sites/";

		// Subscriptions
		subscriptionUrl = appConfig.globalGraphEndpoint ~ "/v1.0/subscriptions";
		subscriptionExpiration = Clock.currTime(UTC());
		subscriptionLastErrorAt = SysTime.fromUnixTime(0);
		subscriptionExpirationInterval = dur!"seconds"(appConfig.getValueLong("webhook_expiration_interval"));
		subscriptionRenewalInterval = dur!"seconds"(appConfig.getValueLong("webhook_renewal_interval"));
		subscriptionRetryInterval = dur!"seconds"(appConfig.getValueLong("webhook_retry_interval"));
		notificationUrl = appConfig.getValueString("webhook_public_url");
	}
	
	// Initialise the OneDrive API class
	bool initialise(bool keepAlive=false) {
		// Initialise the curl engine
		curlEngine = new CurlEngine();
		curlEngine.initialise(appConfig.getValueLong("dns_timeout"), appConfig.getValueLong("connect_timeout"), appConfig.getValueLong("data_timeout"), appConfig.getValueLong("operation_timeout"), appConfig.defaultMaxRedirects, appConfig.getValueBool("debug_https"), appConfig.getValueString("user_agent"), appConfig.getValueBool("force_http_11"), appConfig.getValueLong("rate_limit"), appConfig.getValueLong("ip_protocol_version"), keepAlive);

		// Authorised value to return
		bool authorised = false;

		// Did the user specify --dry-run
		dryRun = appConfig.getValueBool("dry_run");
		
		// Did the user specify --debug-https
		debugResponse = appConfig.getValueBool("debug_https");
		// Flag this so if webhooks are being used, it can also be consumed
		debugHTTPResponseOutput = appConfig.getValueBool("debug_https");
		
		// Set clientId to use the configured 'application_id'
		clientId = appConfig.getValueString("application_id");
		if (clientId != appConfig.defaultApplicationId) {
			// a custom 'application_id' was set
			companyName = "custom_application";
		}
		
		// Do we have a custom Azure Tenant ID?
		if (!appConfig.getValueString("azure_tenant_id").empty) {
			// Use the value entered by the user
			tenantId = appConfig.getValueString("azure_tenant_id");
		} else {
			// set to common
			tenantId = "common";
		}
		
		// Did the user specify a 'drive_id' ?
		if (!appConfig.getValueString("drive_id").empty) {
			// Update base URL's
			driveUrl = driveByIdUrl ~ appConfig.getValueString("drive_id");
			itemByIdUrl = driveUrl ~ "/items";
			itemByPathUrl = driveUrl ~ "/root:/";
		}
		
		// Configure the authentication scope
		if (appConfig.getValueBool("read_only_auth_scope")) {
			// read-only authentication scopes has been requested
			authScope = "&scope=Files.Read%20Files.Read.All%20Sites.Read.All%20offline_access&response_type=code&prompt=login&redirect_uri=";
		} else {
			// read-write authentication scopes will be used (default)
			authScope = "&scope=Files.ReadWrite%20Files.ReadWrite.All%20Sites.ReadWrite.All%20offline_access&response_type=code&prompt=login&redirect_uri=";
		}
		
		// Configure Azure AD endpoints if 'azure_ad_endpoint' is configured
		string azureConfigValue = appConfig.getValueString("azure_ad_endpoint");
		switch(azureConfigValue) {
			case "":
				if (tenantId == "common") {
					if (!appConfig.apiWasInitialised) addLogEntry("Configuring Global Azure AD Endpoints");
				} else {
					if (!appConfig.apiWasInitialised) addLogEntry("Configuring Global Azure AD Endpoints - Single Tenant Application");
				}
				// Authentication
				authUrl = appConfig.globalAuthEndpoint ~ "/" ~ tenantId ~ "/oauth2/v2.0/authorize";
				redirectUrl = appConfig.globalAuthEndpoint ~ "/" ~ tenantId ~ "/oauth2/nativeclient";
				tokenUrl = appConfig.globalAuthEndpoint ~ "/" ~ tenantId ~ "/oauth2/v2.0/token";
				break;
			case "USL4":
				if (!appConfig.apiWasInitialised) addLogEntry("Configuring Azure AD for US Government Endpoints");
				// Authentication
				authUrl = appConfig.usl4AuthEndpoint ~ "/" ~ tenantId ~ "/oauth2/v2.0/authorize";
				tokenUrl = appConfig.usl4AuthEndpoint ~ "/" ~ tenantId ~ "/oauth2/v2.0/token";
				if (clientId == appConfig.defaultApplicationId) {
					// application_id == default
					addLogEntry("USL4 AD Endpoint but default application_id, redirectUrl needs to be aligned to globalAuthEndpoint", ["debug"]);
					redirectUrl = appConfig.globalAuthEndpoint ~ "/" ~ tenantId ~ "/oauth2/nativeclient";
				} else {
					// custom application_id
					redirectUrl = appConfig.usl4AuthEndpoint ~ "/" ~ tenantId ~ "/oauth2/nativeclient";
				}

				// Drive Queries
				driveUrl = appConfig.usl4GraphEndpoint ~ "/v1.0/me/drive";
				driveByIdUrl = appConfig.usl4GraphEndpoint ~ "/v1.0/drives/";
				// Item Queries
				itemByIdUrl = appConfig.usl4GraphEndpoint ~ "/v1.0/me/drive/items/";
				itemByPathUrl = appConfig.usl4GraphEndpoint ~ "/v1.0/me/drive/root:/";
				// Office 365 / SharePoint Queries
				siteSearchUrl = appConfig.usl4GraphEndpoint ~ "/v1.0/sites?search";
				siteDriveUrl = appConfig.usl4GraphEndpoint ~ "/v1.0/sites/";
				// Shared With Me
				sharedWithMeUrl = appConfig.usl4GraphEndpoint ~ "/v1.0/me/drive/sharedWithMe";
				// Subscriptions
				subscriptionUrl = appConfig.usl4GraphEndpoint ~ "/v1.0/subscriptions";
				break;
			case "USL5":
				if (!appConfig.apiWasInitialised) addLogEntry("Configuring Azure AD for US Government Endpoints (DOD)");
				// Authentication
				authUrl = appConfig.usl5AuthEndpoint ~ "/" ~ tenantId ~ "/oauth2/v2.0/authorize";
				tokenUrl = appConfig.usl5AuthEndpoint ~ "/" ~ tenantId ~ "/oauth2/v2.0/token";
				if (clientId == appConfig.defaultApplicationId) {
					// application_id == default
					addLogEntry("USL5 AD Endpoint but default application_id, redirectUrl needs to be aligned to globalAuthEndpoint", ["debug"]);
					redirectUrl = appConfig.globalAuthEndpoint ~ "/" ~ tenantId ~ "/oauth2/nativeclient";
				} else {
					// custom application_id
					redirectUrl = appConfig.usl5AuthEndpoint ~ "/" ~ tenantId ~ "/oauth2/nativeclient";
				}

				// Drive Queries
				driveUrl = appConfig.usl5GraphEndpoint ~ "/v1.0/me/drive";
				driveByIdUrl = appConfig.usl5GraphEndpoint ~ "/v1.0/drives/";
				// Item Queries
				itemByIdUrl = appConfig.usl5GraphEndpoint ~ "/v1.0/me/drive/items/";
				itemByPathUrl = appConfig.usl5GraphEndpoint ~ "/v1.0/me/drive/root:/";
				// Office 365 / SharePoint Queries
				siteSearchUrl = appConfig.usl5GraphEndpoint ~ "/v1.0/sites?search";
				siteDriveUrl = appConfig.usl5GraphEndpoint ~ "/v1.0/sites/";
				// Shared With Me
				sharedWithMeUrl = appConfig.usl5GraphEndpoint ~ "/v1.0/me/drive/sharedWithMe";
				// Subscriptions
				subscriptionUrl = appConfig.usl5GraphEndpoint ~ "/v1.0/subscriptions";
				break;
			case "DE":
				if (!appConfig.apiWasInitialised) addLogEntry("Configuring Azure AD Germany");
				// Authentication
				authUrl = appConfig.deAuthEndpoint ~ "/" ~ tenantId ~ "/oauth2/v2.0/authorize";
				tokenUrl = appConfig.deAuthEndpoint ~ "/" ~ tenantId ~ "/oauth2/v2.0/token";
				if (clientId == appConfig.defaultApplicationId) {
					// application_id == default
					addLogEntry("DE AD Endpoint but default application_id, redirectUrl needs to be aligned to globalAuthEndpoint", ["debug"]);
					redirectUrl = appConfig.globalAuthEndpoint ~ "/" ~ tenantId ~ "/oauth2/nativeclient";
				} else {
					// custom application_id
					redirectUrl = appConfig.deAuthEndpoint ~ "/" ~ tenantId ~ "/oauth2/nativeclient";
				}

				// Drive Queries
				driveUrl = appConfig.deGraphEndpoint ~ "/v1.0/me/drive";
				driveByIdUrl = appConfig.deGraphEndpoint ~ "/v1.0/drives/";
				// Item Queries
				itemByIdUrl = appConfig.deGraphEndpoint ~ "/v1.0/me/drive/items/";
				itemByPathUrl = appConfig.deGraphEndpoint ~ "/v1.0/me/drive/root:/";
				// Office 365 / SharePoint Queries
				siteSearchUrl = appConfig.deGraphEndpoint ~ "/v1.0/sites?search";
				siteDriveUrl = appConfig.deGraphEndpoint ~ "/v1.0/sites/";
				// Shared With Me
				sharedWithMeUrl = appConfig.deGraphEndpoint ~ "/v1.0/me/drive/sharedWithMe";
				// Subscriptions
				subscriptionUrl = appConfig.deGraphEndpoint ~ "/v1.0/subscriptions";
				break;
			case "CN":
				if (!appConfig.apiWasInitialised) addLogEntry("Configuring AD China operated by 21Vianet");
				// Authentication
				authUrl = appConfig.cnAuthEndpoint ~ "/" ~ tenantId ~ "/oauth2/v2.0/authorize";
				tokenUrl = appConfig.cnAuthEndpoint ~ "/" ~ tenantId ~ "/oauth2/v2.0/token";
				if (clientId == appConfig.defaultApplicationId) {
					// application_id == default
					addLogEntry("CN AD Endpoint but default application_id, redirectUrl needs to be aligned to globalAuthEndpoint", ["debug"]);
					redirectUrl = appConfig.globalAuthEndpoint ~ "/" ~ tenantId ~ "/oauth2/nativeclient";
				} else {
					// custom application_id
					redirectUrl = appConfig.cnAuthEndpoint ~ "/" ~ tenantId ~ "/oauth2/nativeclient";
				}

				// Drive Queries
				driveUrl = appConfig.cnGraphEndpoint ~ "/v1.0/me/drive";
				driveByIdUrl = appConfig.cnGraphEndpoint ~ "/v1.0/drives/";
				// Item Queries
				itemByIdUrl = appConfig.cnGraphEndpoint ~ "/v1.0/me/drive/items/";
				itemByPathUrl = appConfig.cnGraphEndpoint ~ "/v1.0/me/drive/root:/";
				// Office 365 / SharePoint Queries
				siteSearchUrl = appConfig.cnGraphEndpoint ~ "/v1.0/sites?search";
				siteDriveUrl = appConfig.cnGraphEndpoint ~ "/v1.0/sites/";
				// Shared With Me
				sharedWithMeUrl = appConfig.cnGraphEndpoint ~ "/v1.0/me/drive/sharedWithMe";
				// Subscriptions
				subscriptionUrl = appConfig.cnGraphEndpoint ~ "/v1.0/subscriptions";
				break;
			// Default - all other entries
			default:
				if (!appConfig.apiWasInitialised) addLogEntry("Unknown Azure AD Endpoint request - using Global Azure AD Endpoints");
		}
		
		// Has the application been authenticated?
		if (!exists(appConfig.refreshTokenFilePath)) {
			addLogEntry("Application has no 'refresh_token' thus needs to be authenticated", ["debug"]);
			authorised = authorise();
		} else {
			// Try and read the value from the appConfig if it is set, rather than trying to read the value from disk
			if (!appConfig.refreshToken.empty) {
				addLogEntry("Read token from appConfig", ["debug"]);
				refreshToken = strip(appConfig.refreshToken);
				authorised = true;
			} else {
				// Try and read the file from disk
				try {
					refreshToken = strip(readText(appConfig.refreshTokenFilePath));
					// is the refresh_token empty?
					if (refreshToken.empty) {
						addLogEntry("RefreshToken exists but is empty: " ~ appConfig.refreshTokenFilePath);
						authorised = authorise();
					} else {
						// existing token not empty
						authorised = true;
						// update appConfig.refreshToken
						appConfig.refreshToken = refreshToken;	
					}
				} catch (FileException e) {
					authorised = authorise();
				} catch (std.utf.UTFException e) {
					// path contains characters which generate a UTF exception
					addLogEntry("Cannot read refreshToken from: " ~ appConfig.refreshTokenFilePath);
					addLogEntry("  Error Reason:" ~ e.msg);
					authorised = false;
				}
			}
			
			if (refreshToken.empty) {
				// PROBLEM ... CODING TO DO ??????????
				addLogEntry("refreshToken is empty !!!!!!!!!! This will cause 4xx errors ... CODING TO DO TO HANDLE ?????");
			}
		}
		// Return if we are authorised
		addLogEntry("Authorised State: " ~ to!string(authorised), ["debug"]);
		return authorised;
	}
	
	// If the API has been configured correctly, print the items that been configured
	void debugOutputConfiguredAPIItems() {
		// Debug output of configured URL's
		// Application Identification
		addLogEntry("Configured clientId          " ~ clientId, ["debug"]);
		addLogEntry("Configured userAgent         " ~ appConfig.getValueString("user_agent"), ["debug"]);
		// Authentication
		addLogEntry("Configured authScope:        " ~ authScope, ["debug"]);
		addLogEntry("Configured authUrl:          " ~ authUrl, ["debug"]);
		addLogEntry("Configured redirectUrl:      " ~ redirectUrl, ["debug"]);
		addLogEntry("Configured tokenUrl:         " ~ tokenUrl, ["debug"]);
		// Drive Queries
		addLogEntry("Configured driveUrl:         " ~ driveUrl, ["debug"]);
		addLogEntry("Configured driveByIdUrl:     " ~ driveByIdUrl, ["debug"]);
		// Shared With Me
		addLogEntry("Configured sharedWithMeUrl:  " ~ sharedWithMeUrl, ["debug"]);
		// Item Queries
		addLogEntry("Configured itemByIdUrl:      " ~ itemByIdUrl, ["debug"]);
		addLogEntry("Configured itemByPathUrl:    " ~ itemByPathUrl, ["debug"]);
		// SharePoint Queries
		addLogEntry("Configured siteSearchUrl:    " ~ siteSearchUrl, ["debug"]);
		addLogEntry("Configured siteDriveUrl:     " ~ siteDriveUrl, ["debug"]);
	}
	
	// Shutdown OneDrive API Curl Engine
	void shutdown() {
		
		// Delete subscription if there exists any
		try {
			deleteSubscription();
		} catch (OneDriveException e) {
			logSubscriptionError(e);
		}
		
		// Shutdown webhook server if it is running
		if (webhook !is null) {
			webhook.stop();
			object.destroy(webhook);
		}
		
		// Reset any values to defaults, freeing any set objects
		curlEngine.http.clearRequestHeaders();
		curlEngine.http.onSend = null;
		curlEngine.http.onReceive = null;
		curlEngine.http.onReceiveHeader = null;
		curlEngine.http.onReceiveStatusLine = null;
		curlEngine.http.contentLength = 0;
		// Shut down the curl instance & close any open sockets
		curlEngine.http.shutdown();
		// Free object and memory
		object.destroy(curlEngine);
	}
	
	// Authenticate this client against Microsoft OneDrive API
	bool authorise() {
	
		char[] response;
		// What URL should be presented to the user to access
		string url = authUrl ~ "?client_id=" ~ clientId ~ authScope ~ redirectUrl;
		// Configure automated authentication if --auth-files authUrl:responseUrl is being used
		string authFilesString = appConfig.getValueString("auth_files");
		string authResponseString = appConfig.getValueString("auth_response");
	
		if (!authResponseString.empty) {
			// read the response from authResponseString
			response = cast(char[]) authResponseString;
		} else if (authFilesString != "") {
			string[] authFiles = authFilesString.split(":");
			string authUrl = authFiles[0];
			string responseUrl = authFiles[1];
			
			try {
				auto authUrlFile = File(authUrl, "w");
				authUrlFile.write(url);
				authUrlFile.close();
			} catch (FileException e) {
				// There was a file system error
				// display the error message
				displayFileSystemErrorMessage(e.msg, getFunctionName!({}));
				// Must force exit here, allow logging to be done
				Thread.sleep(dur!("msecs")(500));
				exit(-1);
			} catch (ErrnoException e) {
				// There was a file system error
				// display the error message
				displayFileSystemErrorMessage(e.msg, getFunctionName!({}));
				// Must force exit here, allow logging to be done
				Thread.sleep(dur!("msecs")(500));
				exit(-1);
			}
	
			addLogEntry("Client requires authentication before proceeding. Waiting for --auth-files elements to be available.");
			
			while (!exists(responseUrl)) {
				Thread.sleep(dur!("msecs")(100));
			}

			// read response from provided from OneDrive
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
				addLogEntry("Cannot remove files " ~ authUrl ~ " " ~ responseUrl);
				return false;
			}
		} else {
			// Are we in a --dry-run scenario?
			if (!appConfig.getValueBool("dry_run")) {
				// No --dry-run is being used
				addLogEntry("Authorise this application by visiting:\n", ["consoleOnly"]);
				addLogEntry(url ~ "\n", ["consoleOnly"]);
				addLogEntry("Enter the response uri from your browser: ", ["consoleOnlyNoNewLine"]);
				readln(response);
				appConfig.applicationAuthorizeResponseUri = true;
			} else {
				// The application cannot be authorised when using --dry-run as we have to write out the authentication data, which negates the whole 'dry-run' process
				addLogEntry();
				addLogEntry("The application requires authorisation, which involves saving authentication data on your system. Note that authorisation cannot be completed with the '--dry-run' option.");
				addLogEntry();
				addLogEntry("To exclusively authorise the application without performing any additional actions, use this command: onedrive");
				addLogEntry();
				forceExit();
			}
		}
		// match the authorization code
		auto c = matchFirst(response, r"(?:[\?&]code=)([\w\d-.]+)");
		if (c.empty) {
			addLogEntry("An empty or invalid response uri was entered");
			return false;
		}
		c.popFront(); // skip the whole match
		redeemToken(c.front);
		
		
		return true;
		
	}
	
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/drive_get
	JSONValue getDefaultDriveDetails() {
		checkAccessTokenExpired();
		string url;
		url = driveUrl;
		return get(url);
	}
	
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_get
	JSONValue getDefaultRootDetails() {
		checkAccessTokenExpired();
		string url;
		url = driveUrl ~ "/root";
		return get(url);
	}
	
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_get
	JSONValue getDriveIdRoot(string driveId) {
		checkAccessTokenExpired();
		string url;
		url = driveByIdUrl ~ driveId ~ "/root";
		return get(url);
	}
	
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/drive_get
	JSONValue getDriveQuota(string driveId) {
		checkAccessTokenExpired();
		string url;
		url = driveByIdUrl ~ driveId ~ "/";
		url ~= "?select=quota";
		return get(url);
	}
	
	// Return the details of the specified path, by giving the path we wish to query
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_get
	JSONValue getPathDetails(string path) {
		checkAccessTokenExpired();
		string url;
		if ((path == ".")||(path == "/")) {
			url = driveUrl ~ "/root/";
		} else {
			url = itemByPathUrl ~ encodeComponent(path) ~ ":/";
		}
		return get(url);
	}
	
	// Return the details of the specified item based on its driveID and itemID
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_get
	JSONValue getPathDetailsById(string driveId, string id) {
		checkAccessTokenExpired();
		string url;
		url = driveByIdUrl ~ driveId ~ "/items/" ~ id;
		//url ~= "?select=id,name,eTag,cTag,deleted,file,folder,root,fileSystemInfo,remoteItem,parentReference,size";
		return get(url);
	}
	
	// Create a shareable link for an existing file on OneDrive based on the accessScope JSON permissions
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_createlink
	JSONValue createShareableLink(string driveId, string id, JSONValue accessScope) {
		checkAccessTokenExpired();
		string url;
		url = driveByIdUrl ~ driveId ~ "/items/" ~ id ~ "/createLink";
		curlEngine.http.addRequestHeader("Content-Type", "application/json");
		return post(url, accessScope.toString());
	}
	
	// Return the requested details of the specified path on the specified drive id and path
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_get
	JSONValue getPathDetailsByDriveId(string driveId, string path) {
		checkAccessTokenExpired();
		string url;
		// https://learn.microsoft.com/en-us/onedrive/developer/rest-api/concepts/addressing-driveitems?view=odsp-graph-online
		// Required format: /drives/{drive-id}/root:/{item-path}:
		url = driveByIdUrl ~ driveId ~ "/root:/" ~ encodeComponent(path) ~ ":";
		return get(url);
	}
	
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_delta
	JSONValue viewChangesByItemId(string driveId, string id, string deltaLink) {
		checkAccessTokenExpired();
		
		// If Business Account add addIncludeFeatureRequestHeader() which should add Prefer: Include-Feature=AddToOneDrive
		if ((appConfig.accountType != "personal") && ( appConfig.getValueBool("sync_business_shared_items"))) {
			addIncludeFeatureRequestHeader();
		}
		
		string url;
		// configure deltaLink to query
		if (deltaLink.empty) {
			url = driveByIdUrl ~ driveId ~ "/items/" ~ id ~ "/delta";
		} else {
			url = deltaLink;
		}
		return get(url);
	}
	
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_list_children
	JSONValue listChildren(string driveId, string id, string nextLink) {
		checkAccessTokenExpired();
		
		// If Business Account add addIncludeFeatureRequestHeader() which should add Prefer: Include-Feature=AddToOneDrive
		if ((appConfig.accountType != "personal") && ( appConfig.getValueBool("sync_business_shared_items"))) {
			addIncludeFeatureRequestHeader();
		}
		
		string url;
		// configure URL to query
		if (nextLink.empty) {
			url = driveByIdUrl ~ driveId ~ "/items/" ~ id ~ "/children";
			//url ~= "?select=id,name,eTag,cTag,deleted,file,folder,root,fileSystemInfo,remoteItem,parentReference,size";
		} else {
			url = nextLink;
		}
		return get(url);
	}
	
	// https://learn.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_search
	JSONValue searchDriveForPath(string driveId, string path) {
		checkAccessTokenExpired();
		string url;
		url = "https://graph.microsoft.com/v1.0/drives/" ~ driveId ~ "/root/search(q='" ~ encodeComponent(path) ~ "')";
		return get(url);
	}
	
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_update
	JSONValue updateById(const(char)[] driveId, const(char)[] id, JSONValue data, const(char)[] eTag = null) {
		checkAccessTokenExpired();
		const(char)[] url = driveByIdUrl ~ driveId ~ "/items/" ~ id;
		if (eTag) curlEngine.http.addRequestHeader("If-Match", eTag);
		curlEngine.http.addRequestHeader("Content-Type", "application/json");
		return patch(url, data.toString());
	}
	
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_delete
	void deleteById(const(char)[] driveId, const(char)[] id, const(char)[] eTag = null) {
		checkAccessTokenExpired();
		const(char)[] url = driveByIdUrl ~ driveId ~ "/items/" ~ id;
		//TODO: investigate why this always fail with 412 (Precondition Failed)
		//if (eTag) http.addRequestHeader("If-Match", eTag);
		performDelete(url);
	}
	
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_post_children
	JSONValue createById(string parentDriveId, string parentId, JSONValue item) {
		checkAccessTokenExpired();
		string url = driveByIdUrl ~ parentDriveId ~ "/items/" ~ parentId ~ "/children";
		curlEngine.http.addRequestHeader("Content-Type", "application/json");
		return post(url, item.toString());
	}
	
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_put_content
	JSONValue simpleUpload(string localPath, string parentDriveId, string parentId, string filename) {
		checkAccessTokenExpired();
		string url = driveByIdUrl ~ parentDriveId ~ "/items/" ~ parentId ~ ":/" ~ encodeComponent(filename) ~ ":/content";
		return upload(localPath, url);
	}
	
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_put_content
	JSONValue simpleUploadReplace(string localPath, string driveId, string id) {
		checkAccessTokenExpired();
		string url = driveByIdUrl ~ driveId ~ "/items/" ~ id ~ "/content";
		return upload(localPath, url);
	}
	
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_createuploadsession
	//JSONValue createUploadSession(string parentDriveId, string parentId, string filename, string eTag = null, JSONValue item = null) {
	JSONValue createUploadSession(string parentDriveId, string parentId, string filename, const(char)[] eTag = null, JSONValue item = null) {
		checkAccessTokenExpired();
		string url = driveByIdUrl ~ parentDriveId ~ "/items/" ~ parentId ~ ":/" ~ encodeComponent(filename) ~ ":/createUploadSession";
		// eTag If-Match header addition commented out for the moment
		// At some point, post the creation of this upload session the eTag is being 'updated' by OneDrive, thus when uploadFragment() is used
		// this generates a 412 Precondition Failed and then a 416 Requested Range Not Satisfiable
		// This needs to be investigated further as to why this occurs
		//if (eTag) curlEngine.http.addRequestHeader("If-Match", eTag);
		curlEngine.http.addRequestHeader("Content-Type", "application/json");
		return post(url, item.toString());
	}
	
	// https://dev.onedrive.com/items/upload_large_files.htm
	JSONValue uploadFragment(string uploadUrl, string filepath, long offset, long offsetSize, long fileSize) {
		checkAccessTokenExpired();
		// open file as read-only in binary mode
		
		// If we upload a modified file, with the current known online eTag, this gets changed when the session is started - thus, the tail end of uploading
		// a fragment fails with a 412 Precondition Failed and then a 416 Requested Range Not Satisfiable
		// For the moment, comment out adding the If-Match header in createUploadSession, which then avoids this issue
		
		auto file = File(filepath, "rb");
		file.seek(offset);
		string contentRange = "bytes " ~ to!string(offset) ~ "-" ~ to!string(offset + offsetSize - 1) ~ "/" ~ to!string(fileSize);
		addLogEntry("", ["debug"]); // Add an empty newline before log output
		addLogEntry("contentRange: " ~ contentRange, ["debug"]);
		
		// function scopes
		scope(exit) {
			curlEngine.http.clearRequestHeaders();
			curlEngine.http.onSend = null;
			curlEngine.http.onReceive = null;
			curlEngine.http.onReceiveHeader = null;
			curlEngine.http.onReceiveStatusLine = null;
			curlEngine.http.contentLength = 0;
			// close file if open
			if (file.isOpen()){
				// close open file
				file.close();
			}
		}

		curlEngine.connect(HTTP.Method.put, uploadUrl);
		curlEngine.http.addRequestHeader("Content-Range", contentRange);
		curlEngine.http.onSend = data => file.rawRead(data).length;
		// convert offsetSize to ulong
		curlEngine.http.contentLength = to!ulong(offsetSize);
		auto response = performHTTPOperation();
		checkHttpResponseCode(response);
		return response;
	}
	
	// https://dev.onedrive.com/items/upload_large_files.htm
	JSONValue requestUploadStatus(string uploadUrl) {
		checkAccessTokenExpired();
		return get(uploadUrl, true);
	}
	
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/site_search?view=odsp-graph-online
	JSONValue o365SiteSearch(string nextLink) {
		checkAccessTokenExpired();
		string url;
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
		string url;
		url = siteDriveUrl ~ site_id ~ "/drives";
		return get(url);
	}
	
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_get_content
	void downloadById(const(char)[] driveId, const(char)[] id, string saveToPath, long fileSize) {
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
				addLogEntry("Requested local path does not exist, creating directory structure: " ~ newPath, ["debug"]);
				mkdirRecurse(newPath);
				// Configure the applicable permissions for the folder
				addLogEntry("Setting directory permissions for: " ~ newPath, ["debug"]);
				newPath.setAttributes(appConfig.returnRequiredDirectoryPermisions());
			} catch (FileException e) {
				// display the error message
				displayFileSystemErrorMessage(e.msg, getFunctionName!({}));
			}
		}

		const(char)[] url = driveByIdUrl ~ driveId ~ "/items/" ~ id ~ "/content?AVOverride=1";
		// Download file
		downloadFile(url, saveToPath, fileSize);
		// Does path exist?
		if (exists(saveToPath)) {
			// File was downloaded successfully - configure the applicable permissions for the file
			addLogEntry("Setting file permissions for: " ~ saveToPath, ["debug"]);
			saveToPath.setAttributes(appConfig.returnRequiredFilePermisions());
		}
	}
	
	// Return the actual siteSearchUrl being used and/or requested when performing 'siteQuery = onedrive.o365SiteSearch(nextLink);' call
	string getSiteSearchUrl() {
		return siteSearchUrl;
	}
	
	// Return the current value of retryAfterValue
	ulong getRetryAfterValue() {
		return retryAfterValue;
	}

	// Reset the current value of retryAfterValue to 0 after it has been used
	void resetRetryAfterValue() {
		retryAfterValue = 0;
	}
	
	// Create a new subscription or renew the existing subscription
	void createOrRenewSubscription() {
		checkAccessTokenExpired();

		// Kick off the webhook server first
		if (webhook is null) {
			webhook = OneDriveWebhook.getOrCreate(
				appConfig.getValueString("webhook_listening_host"),
				to!ushort(appConfig.getValueLong("webhook_listening_port")),
				thisTid
			);
			webhook.serve();
		}

		auto elapsed = Clock.currTime(UTC()) - subscriptionLastErrorAt;
		if (elapsed < subscriptionRetryInterval) {
			return;
		}

		try {
			if (!hasValidSubscription()) {
				createSubscription();
			} else if (isSubscriptionUpForRenewal()) {
				renewSubscription();
			}
		} catch (OneDriveException e) {
			logSubscriptionError(e);
			subscriptionLastErrorAt = Clock.currTime(UTC());
			addLogEntry("Will retry creating or renewing subscription in " ~ to!string(subscriptionRetryInterval));
		} catch (JSONException e) {
			addLogEntry("ERROR: Unexpected JSON error when attempting to validate subscription: " ~ e.msg);
			subscriptionLastErrorAt = Clock.currTime(UTC());
			addLogEntry("Will retry creating or renewing subscription in " ~ to!string(subscriptionRetryInterval));
		}
	}
		
	// Return the duration to next subscriptionExpiration check
	Duration getNextExpirationCheckDuration() {
		SysTime now = Clock.currTime(UTC());
		if (hasValidSubscription()) {
			Duration elapsed = Clock.currTime(UTC()) - subscriptionLastErrorAt;
			// Check if we are waiting for the next retry
			if (elapsed < subscriptionRetryInterval)
				return subscriptionRetryInterval - elapsed;
			else 
				return subscriptionExpiration - now - subscriptionRenewalInterval;
		}
		else
			return subscriptionRetryInterval;
	}
	
	// Private functions
	private bool hasValidSubscription() {
		return !subscriptionId.empty && subscriptionExpiration > Clock.currTime(UTC());
	}

	private bool isSubscriptionUpForRenewal() {
		return subscriptionExpiration < Clock.currTime(UTC()) + subscriptionRenewalInterval;
	}
	
	private void createSubscription() {
		addLogEntry("Initializing subscription for updates ...");

		auto expirationDateTime = Clock.currTime(UTC()) + subscriptionExpirationInterval;
		string driveId = appConfig.getValueString("drive_id");
		string url = subscriptionUrl;
		
		// Create a resource item based on if we have a driveId
		string resourceItem;
		if (driveId.length) {
				resourceItem = "/drives/" ~ driveId ~ "/root";
		} else {
				resourceItem = "/me/drive/root";
		}

		// create JSON request to create webhook subscription
		const JSONValue request = [
			"changeType": "updated",
			"notificationUrl": notificationUrl,
			"resource": resourceItem,
			"expirationDateTime": expirationDateTime.toISOExtString(),
 			"clientState": randomUUID().toString()
		];
		curlEngine.http.addRequestHeader("Content-Type", "application/json");

		try {
			JSONValue response = post(url, request.toString());

			// Save important subscription metadata including id and expiration
			subscriptionId = response["id"].str;
			subscriptionExpiration = SysTime.fromISOExtString(response["expirationDateTime"].str);
			addLogEntry("Created new subscription " ~ subscriptionId ~ " with expiration: " ~ to!string(subscriptionExpiration.toISOExtString()));
		} catch (OneDriveException e) {
			if (e.httpStatusCode == 409) {
				// Take over an existing subscription on HTTP 409.
				//
				// Sample 409 error:
				// {
				// 	"error": {
				// 			"code": "ObjectIdentifierInUse",
				// 			"innerError": {
				// 					"client-request-id": "615af209-467a-4ab7-8eff-27c1d1efbc2d",
				// 					"date": "2023-09-26T09:27:45",
				// 					"request-id": "615af209-467a-4ab7-8eff-27c1d1efbc2d"
				// 			},
				// 			"message": "Subscription Id c0bba80e-57a3-43a7-bac2-e6f525a76e7c already exists for the requested combination"
				// 	}
				// }

				// Make sure the error code is "ObjectIdentifierInUse"
				try {
					if (e.error["error"]["code"].str != "ObjectIdentifierInUse") {
						throw e;
					}
				} catch (JSONException jsonEx) {
					throw e;
				}

				// Extract the existing subscription id from the error message
				import std.regex;
				auto idReg = ctRegex!(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", "i");
				auto m = matchFirst(e.error["error"]["message"].str, idReg);
				if (!m) {
					throw e;
				}

				// Save the subscription id and renew it immediately since we don't know the expiration timestamp
				subscriptionId = m[0];
				addLogEntry("Found existing subscription " ~ subscriptionId);
				renewSubscription();
			} else {
				throw e;
			}
		}
	}
	
	private void renewSubscription() {
		addLogEntry("Renewing subscription for updates ...");

		auto expirationDateTime = Clock.currTime(UTC()) + subscriptionExpirationInterval;
		string url;
		url = subscriptionUrl ~ "/" ~ subscriptionId;
		const JSONValue request = [
			"expirationDateTime": expirationDateTime.toISOExtString()
		];
		curlEngine.http.addRequestHeader("Content-Type", "application/json");

		try {
			JSONValue response = patch(url, request.toString());

			// Update subscription expiration from the response
			subscriptionExpiration = SysTime.fromISOExtString(response["expirationDateTime"].str);
			addLogEntry("Renewed subscription " ~ subscriptionId ~ " with expiration: " ~ to!string(subscriptionExpiration.toISOExtString()));
		} catch (OneDriveException e) {
			if (e.httpStatusCode == 404) {
				addLogEntry("The subscription is not found on the server. Recreating subscription ...");
				subscriptionId = null;
				subscriptionExpiration = Clock.currTime(UTC());
				createSubscription();
			} else {
				throw e;
			}
		}
	}
	
	private void deleteSubscription() {
		if (!hasValidSubscription()) {
			addLogEntry("No valid Microsoft OneDrive webhook subscription to delete", ["debug"]);
			return;
		}

		string url;
		url = subscriptionUrl ~ "/" ~ subscriptionId;
		performDelete(url);
		addLogEntry("Deleted Microsoft OneDrive webhook subscription", ["debug"]);
	}
	
	private void logSubscriptionError(OneDriveException e) {
		if (e.httpStatusCode == 400) {
			// Log known 400 error where Microsoft cannot get a 200 OK from the webhook endpoint
			//
			// Sample 400 error:
			// {
			// 	"error": {
			// 			"code": "InvalidRequest",
			// 			"innerError": {
			// 					"client-request-id": "<uuid>",
			// 					"date": "<timestamp>",
			// 					"request-id": "<uuid>"
			// 			},
			// 			"message": "Subscription validation request failed. Notification endpoint must respond with 200 OK to validation request."
			// 	}
			// }

			try {
				if (e.error["error"]["code"].str == "InvalidRequest") {
					import std.regex;
					auto msgReg = ctRegex!(r"Subscription validation request failed", "i");
					auto m = matchFirst(e.error["error"]["message"].str, msgReg);
					if (m) {
						addLogEntry("ERROR: Cannot create or renew subscription: Microsoft did not get 200 OK from the webhook endpoint.");
						return;
					}
				}
			} catch (JSONException) {
				// fallthrough
			}
		} else if (e.httpStatusCode == 401) {
			// Log known 401 error where authentication failed
			//
			// Sample 401 error:
			// {
			// 	"error": {
			// 			"code": "ExtensionError",
			// 			"innerError": {
			// 					"client-request-id": "<uuid>",
			// 					"date": "<timestamp>",
			// 					"request-id": "<uuid>"
			// 			},
			// 			"message": "Operation: Create; Exception: [Status Code: Unauthorized; Reason: Authentication failed]"
			// 	}
			// }

			try {
				if (e.error["error"]["code"].str == "ExtensionError") {
					import std.regex;
					auto msgReg = ctRegex!(r"Authentication failed", "i");
					auto m = matchFirst(e.error["error"]["message"].str, msgReg);
					if (m) {
						addLogEntry("ERROR: Cannot create or renew subscription: Authentication failed.");
						return;
					}
				}
			} catch (JSONException) {
				// fallthrough
			}
		} else if (e.httpStatusCode == 403) {
			// Log known 403 error where the number of subscriptions on item has exceeded limit
			//
			// Sample 403 error:
			// {
			// 	"error": {
			// 			"code": "ExtensionError",
			// 			"innerError": {
			// 					"client-request-id": "<uuid>",
			// 					"date": "<timestamp>",
			// 					"request-id": "<uuid>"
			// 			},
			// 			"message": "Operation: Create; Exception: [Status Code: Forbidden; Reason: Number of subscriptions on item has exceeded limit]"
			// 	}
			// }
			try {
				if (e.error["error"]["code"].str == "ExtensionError") {
					import std.regex;
					auto msgReg = ctRegex!(r"Number of subscriptions on item has exceeded limit", "i");
					auto m = matchFirst(e.error["error"]["message"].str, msgReg);
					if (m) {
						addLogEntry("ERROR: Cannot create or renew subscription: Number of subscriptions has exceeded limit.");
						return;
					}
				}
			} catch (JSONException) {
				// fallthrough
			}
		}

		// Log detailed message for unknown errors
		addLogEntry("ERROR: Cannot create or renew subscription.");
		displayOneDriveErrorMessage(e.msg, getFunctionName!({}));
	}
	
	private void addAccessTokenHeader() {
		curlEngine.http.addRequestHeader("Authorization", appConfig.accessToken);
	}
	
	private void addIncludeFeatureRequestHeader() {
		addLogEntry("Adding 'Include-Feature=AddToOneDrive' API request header as 'sync_business_shared_items' config option is enabled", ["debug"]);
		curlEngine.http.addRequestHeader("Prefer", "Include-Feature=AddToOneDrive");
	}
	
	private void acquireToken(char[] postData) {
		JSONValue response;

		try {
			response = post(tokenUrl, postData);
		} catch (OneDriveException e) {
			// an error was generated
			if ((e.httpStatusCode == 400) || (e.httpStatusCode == 401)) {
				// Handle an unauthorised client
				handleClientUnauthorised(e.httpStatusCode, e.msg);
			} else {
				if (e.httpStatusCode >= 500) {
					// There was a HTTP 5xx Server Side Error - retry
					acquireToken(postData);
				} else {
					displayOneDriveErrorMessage(e.msg, getFunctionName!({}));
				}
			}
		}

		if (response.type() == JSONType.object) {
			// Has the client been configured to use read_only_auth_scope
			if (appConfig.getValueBool("read_only_auth_scope")) {
				// read_only_auth_scope has been configured
				if ("scope" in response){
					string effectiveScopes = response["scope"].str();
					// Display the effective authentication scopes
					addLogEntry();
					addLogEntry("Effective API Authentication Scopes: " ~ effectiveScopes, ["verbose"]);
					
					// if we have any write scopes, we need to tell the user to update an remove online prior authentication and exit application
					if (canFind(effectiveScopes, "Write")) {
						// effective scopes contain write scopes .. so not a read-only configuration
						addLogEntry();
						addLogEntry("ERROR: You have authentication scopes that allow write operations. You need to remove your existing application access consent");
						addLogEntry();
						addLogEntry("Please login to https://account.live.com/consent/Manage and remove your existing application access consent");
						addLogEntry();
						// force exit
						shutdown();
						// Must force exit here, allow logging to be done
						Thread.sleep(dur!("msecs")(500));
						exit(-1);
					}
				}
			}
		
			if ("access_token" in response){
				appConfig.accessToken = "bearer " ~ strip(response["access_token"].str);
				
				// Do we print the current access token
				if (appConfig.verbosityCount > 1) {
					if (appConfig.getValueBool("debug_https")) {
						if (appConfig.getValueBool("print_token")) {
							// This needs to be highly restricted in output .... 
							addLogEntry("CAUTION - KEEP THIS SAFE: Current access token: " ~ to!string(appConfig.accessToken), ["debug"]);
						}
					}
				}
				
				refreshToken = strip(response["refresh_token"].str);
				appConfig.accessTokenExpiration = Clock.currTime() + dur!"seconds"(response["expires_in"].integer());
				if (!dryRun) {
					// Update the refreshToken in appConfig so that we can reuse it
					if (appConfig.refreshToken.empty) {
						// The access token is empty
						addLogEntry("Updating appConfig.refreshToken with new refreshToken as appConfig.refreshToken is empty", ["debug"]);
						appConfig.refreshToken = refreshToken;
					} else {
						// Is the access token different?
						if (appConfig.refreshToken != refreshToken) {
							// Update the memory version
							addLogEntry("Updating appConfig.refreshToken with updated refreshToken", ["debug"]);
							appConfig.refreshToken = refreshToken;
						}
					}
					
					// try and update the refresh_token file on disk
					try {
						addLogEntry("Updating refreshToken on disk", ["debug"]);
						std.file.write(appConfig.refreshTokenFilePath, refreshToken);
						addLogEntry("Setting file permissions for: " ~ appConfig.refreshTokenFilePath, ["debug"]);
						appConfig.refreshTokenFilePath.setAttributes(appConfig.returnRequiredFilePermisions());
					} catch (FileException e) {
						// display the error message
						displayFileSystemErrorMessage(e.msg, getFunctionName!({}));
					}
				}
			} else {
				addLogEntry("\nInvalid authentication response from OneDrive. Please check the response uri\n");
				// re-authorize
				authorise();
			}
		} else {
			addLogEntry("Invalid response from the OneDrive API. Unable to initialise OneDrive API instance.");
			// Must force exit here, allow logging to be done
			Thread.sleep(dur!("msecs")(500));
			exit(-1);
		}
	}
	
	private void checkAccessTokenExpired() {
		try {
			if (Clock.currTime() >= appConfig.accessTokenExpiration) {
				addLogEntry("Microsoft OneDrive Access Token has EXPIRED. Must generate a new Microsoft OneDrive Access Token", ["debug"]);
				newToken();
			} else {
				addLogEntry("Existing Microsoft OneDrive Access Token Expires: " ~ to!string(appConfig.accessTokenExpiration), ["debug"]);
			}
		} catch (OneDriveException e) {
			if (e.httpStatusCode == 400 || e.httpStatusCode == 401) {
				// flag error and notify
				addLogEntry();
				addLogEntry("ERROR: Refresh token invalid, use --reauth to authorize the client again.", ["info", "notify"]);
				addLogEntry();
				// set error message
				e.msg ~= "\nRefresh token invalid, use --reauth to authorize the client again";
			}
		}
	}
	
	private void performDelete(const(char)[] url) {
		scope(exit) curlEngine.http.clearRequestHeaders();
		curlEngine.connect(HTTP.Method.del, url);
		addAccessTokenHeader();
		auto response = performHTTPOperation();
		checkHttpResponseCode(response);
	}
	
	private void downloadFile(const(char)[] url, string filename, long fileSize) {
		// Threshold for displaying download bar
		long thresholdFileSize = 4 * 2^^20; // 4 MiB
		
		// To support marking of partially-downloaded files, 
		string originalFilename = filename;
		string downloadFilename = filename ~ ".partial";
		
		// open downloadFilename as write in binary mode
		auto file = File(downloadFilename, "wb");

		// function scopes
		scope(exit) {
			curlEngine.http.clearRequestHeaders();
			curlEngine.http.onSend = null;
			curlEngine.http.onReceive = null;
			curlEngine.http.onReceiveHeader = null;
			curlEngine.http.onReceiveStatusLine = null;
			curlEngine.http.contentLength = 0;
			// Reset onProgress to not display anything for next download
			curlEngine.http.onProgress = delegate int(size_t dltotal, size_t dlnow, size_t ultotal, size_t ulnow)
			{
				return 0;
			};
			// close file if open
			if (file.isOpen()){
				// close open file
				file.close();
			}
		}

		curlEngine.connect(HTTP.Method.get, url);
		addAccessTokenHeader();

		curlEngine.http.onReceive = (ubyte[] data) {
			file.rawWrite(data);
			return data.length;
		};

		if (fileSize >= thresholdFileSize){
			// Download Progress variables
			size_t expected_total_segments = 20;
			ulong start_unix_time = Clock.currTime.toUnixTime();
			int h, m, s;
			string etaString;
			bool barInit = false;
			real previousProgressPercent = -1.0;
			real percentCheck = 5.0;
			long segmentCount = -1;
			
			// Setup progress bar to display
			curlEngine.http.onProgress = delegate int(size_t dltotal, size_t dlnow, size_t ultotal, size_t ulnow) {
				// For each onProgress, what is the % of dlnow to dltotal
				// floor - rounds down to nearest whole number
				real currentDLPercent = floor(double(dlnow)/dltotal*100);
				string downloadLogEntry = "Downloading: " ~ filename ~ " ... ";
				
				// Have we started downloading?
				if (currentDLPercent > 0){
					// We have started downloading
					addLogEntry("", ["debug"]); // Debug new line only
					addLogEntry("Data Received    = " ~ to!string(dlnow), ["debug"]);
					addLogEntry("Expected Total   = " ~ to!string(dltotal), ["debug"]);
					addLogEntry("Percent Complete = " ~ to!string(currentDLPercent), ["debug"]);
					
					// Every 5% download we need to increment the download bar

					// Has the user set a data rate limit?
					// when using rate_limit, we will get odd download rates, for example:
					// Percent Complete = 24
					// Data Received    = 13080163
					// Expected Total   = 52428800
					// Percent Complete = 24
					// Data Received    = 13685777
					// Expected Total   = 52428800
					// Percent Complete = 26   <---- jumps to 26% missing 25%, thus fmod misses incrementing progress bar
					// Data Received    = 13685777
					// Expected Total   = 52428800
					// Percent Complete = 26
										
					if (appConfig.getValueLong("rate_limit") > 0) {
						// User configured rate limit
						// How much data should be in each segment to qualify for 5%
						ulong dataPerSegment = to!ulong(floor(double(dltotal)/expected_total_segments));
						// How much data received do we need to validate against
						ulong thisSegmentData = dataPerSegment * segmentCount;
						ulong nextSegmentData = dataPerSegment * (segmentCount + 1);
						
						// Has the data that has been received in a 5% window that we need to increment the progress bar at
						if ((dlnow > thisSegmentData) && (dlnow < nextSegmentData) && (previousProgressPercent != currentDLPercent) || (dlnow == dltotal)) {
							// Downloaded data equals approx 5%
							addLogEntry("Incrementing Progress Bar using calculated 5% of data received", ["debug"]);
							
							// 100% check
							if (currentDLPercent != 100) {
								// Not 100% yet
								// Calculate the output
								segmentCount++;
								auto eta = calc_eta(segmentCount, expected_total_segments, start_unix_time);
								dur!"seconds"(eta).split!("hours", "minutes", "seconds")(h, m, s);
								etaString = format!"|  ETA    %02d:%02d:%02d"( h, m, s);
								string percentage = leftJustify(to!string(currentDLPercent) ~ "%", 5, ' ');
								addLogEntry(downloadLogEntry ~ percentage ~ etaString, ["consoleOnly"]);
							} else {
								// 100% done
								ulong end_unix_time = Clock.currTime.toUnixTime();
								auto upload_duration = cast(int)(end_unix_time - start_unix_time);
								dur!"seconds"(upload_duration).split!("hours", "minutes", "seconds")(h, m, s);
								etaString = format!"| DONE in %02d:%02d:%02d"( h, m, s);
								string percentage = leftJustify(to!string(currentDLPercent) ~ "%", 5, ' ');
								addLogEntry(downloadLogEntry ~ percentage ~ etaString, ["consoleOnly"]);
							}
							
							// update values
							addLogEntry("Setting previousProgressPercent to " ~ to!string(currentDLPercent), ["debug"]);
							previousProgressPercent = currentDLPercent;
							addLogEntry("Incrementing segmentCount", ["debug"]);
							segmentCount++;
						}
					} else {
						// Is currentDLPercent divisible by 5 leaving remainder 0 and does previousProgressPercent not equal currentDLPercent
						if ((isIdentical(fmod(currentDLPercent, percentCheck), 0.0)) && (previousProgressPercent != currentDLPercent)) {
							// currentDLPercent matches a new increment
							addLogEntry("Incrementing Progress Bar using fmod match", ["debug"]);
							
							// 100% check
							if (currentDLPercent != 100) {
								// Not 100% yet
								// Calculate the output
								segmentCount++;
								auto eta = calc_eta(segmentCount, expected_total_segments, start_unix_time);
								dur!"seconds"(eta).split!("hours", "minutes", "seconds")(h, m, s);
								etaString = format!"|  ETA    %02d:%02d:%02d"( h, m, s);
								string percentage = leftJustify(to!string(currentDLPercent) ~ "%", 5, ' ');
								addLogEntry(downloadLogEntry ~ percentage ~ etaString, ["consoleOnly"]);
							} else {
								// 100% done
								ulong end_unix_time = Clock.currTime.toUnixTime();
								auto upload_duration = cast(int)(end_unix_time - start_unix_time);
								dur!"seconds"(upload_duration).split!("hours", "minutes", "seconds")(h, m, s);
								etaString = format!"| DONE in %02d:%02d:%02d"( h, m, s);
								string percentage = leftJustify(to!string(currentDLPercent) ~ "%", 5, ' ');
								addLogEntry(downloadLogEntry ~ percentage ~ etaString, ["consoleOnly"]);
							}
							
							// update values
							previousProgressPercent = currentDLPercent;
						}
					}
				} else {
					if ((currentDLPercent == 0) && (!barInit)) {
						// Calculate the output
						segmentCount++;
						etaString = "|  ETA    --:--:--";
						string percentage = leftJustify(to!string(currentDLPercent) ~ "%", 5, ' ');
						addLogEntry(downloadLogEntry ~ percentage ~ etaString, ["consoleOnly"]);
						barInit = true;
					}
				}
				return 0;
			};

			// Perform download
			try {
				// try and catch any curl error
				curlEngine.http.perform();
				// Check the HTTP Response headers - needed for correct 429 handling
				// check will be performed in checkHttpCode()
				// Reset onProgress to not display anything for next download done using exit scope
			} catch (CurlException e) {
				displayOneDriveErrorMessage(e.msg, getFunctionName!({}));
			}
		} else {
			// No progress bar
			try {
				// try and catch any curl error
				curlEngine.http.perform();
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

	private JSONValue get(string url, bool skipToken = false) {
		scope(exit) curlEngine.http.clearRequestHeaders();
		addLogEntry("Request URL = " ~ url, ["debug"]);
		curlEngine.connect(HTTP.Method.get, url);
		if (!skipToken) addAccessTokenHeader(); // HACK: requestUploadStatus
		JSONValue response;
		response = performHTTPOperation();
		checkHttpResponseCode(response);
		// OneDrive API Response Debugging if --https-debug is being used
		if (debugResponse){
			addLogEntry("OneDrive API Response: " ~ to!string(response), ["debug"]);
        }
		return response;
	}
	
	private void newToken() {
		addLogEntry("Need to generate a new access token for Microsoft OneDrive", ["debug"]);
		auto postData = appender!(string)();
		postData ~= "client_id=" ~ clientId;
		postData ~= "&redirect_uri=" ~ redirectUrl;
		postData ~= "&refresh_token=" ~ to!string(refreshToken);
		postData ~= "&grant_type=refresh_token";
		acquireToken(postData.data.dup);
	}

	private auto patch(T)(const(char)[] url, const(T)[] patchData) {
		scope(exit) curlEngine.http.clearRequestHeaders();
		curlEngine.connect(HTTP.Method.patch, url);
		addAccessTokenHeader();
		auto response = perform(patchData);
		checkHttpResponseCode(response);
		return response;
	}
	
	private auto post(T)(string url, const(T)[] postData) {
		scope(exit) curlEngine.http.clearRequestHeaders();
		curlEngine.connect(HTTP.Method.post, url);
		addAccessTokenHeader();
		auto response = perform(postData);
		checkHttpResponseCode(response);
		return response;
	}
	
	private JSONValue perform(const(void)[] sendData) {
		scope(exit) {
			curlEngine.http.onSend = null;
			curlEngine.http.contentLength = 0;
		}
		if (sendData) {
			curlEngine.http.contentLength = sendData.length;
			curlEngine.http.onSend = (void[] buf) {
				import std.algorithm: min;
				size_t minLen = min(buf.length, sendData.length);
				if (minLen == 0) return 0;
				buf[0 .. minLen] = sendData[0 .. minLen];
				sendData = sendData[minLen .. $];
				return minLen;
			};
		} else {
			curlEngine.http.onSend = buf => 0;
		}
		auto response = performHTTPOperation();
		return response;
	}
	
	private JSONValue performHTTPOperation() {
		scope(exit) curlEngine.http.onReceive = null;
		char[] content;
		JSONValue json;

		curlEngine.http.onReceive = (ubyte[] data) {
			content ~= data;
			// HTTP Server Response Code Debugging if --https-debug is being used
			if (debugResponse){
				addLogEntry("onedrive.performHTTPOperation() => OneDrive HTTP Server Response: " ~ to!string(curlEngine.http.statusLine.code), ["debug"]);
			}
			return data.length;
		};

		try {
			curlEngine.http.perform();
			// Check the HTTP Response headers - needed for correct 429 handling
			checkHTTPResponseHeaders();
		} catch (CurlException e) {
			// Parse and display error message received from OneDrive
			addLogEntry("onedrive.performHTTPOperation() Generated a OneDrive CurlException", ["debug"]);
			auto errorArray = splitLines(e.msg);
			string errorMessage = errorArray[0];
			
			// what is contained in the curl error message?
			if (canFind(errorMessage, "Couldn't connect to server on handle") || canFind(errorMessage, "Couldn't resolve host name on handle") || canFind(errorMessage, "Timeout was reached on handle")) {
				// This is a curl timeout
				// or is this a 408 request timeout
				// https://github.com/abraunegg/onedrive/issues/694
				// Back off & retry with incremental delay
				int retryCount = 10000;
				int retryAttempts = 0;
				int backoffInterval = 0;
				int maxBackoffInterval = 3600;
				int timestampAlign = 0;
				bool retrySuccess = false;
				SysTime currentTime;
				
				// Connectivity to Microsoft OneDrive was lost
				addLogEntry("Internet connectivity to Microsoft OneDrive service has been lost .. re-trying in the background");
				
				// what caused the initial curl exception?
				if (canFind(errorMessage, "Couldn't connect to server on handle")) addLogEntry("Unable to connect to server - HTTPS access blocked?", ["debug"]);
				if (canFind(errorMessage, "Couldn't resolve host name on handle")) addLogEntry("Unable to resolve server - DNS access blocked?", ["debug"]);
				if (canFind(errorMessage, "Timeout was reached on handle")) addLogEntry("A timeout was triggered - data too slow, no response ... use --debug-https to diagnose further", ["debug"]);
				
				while (!retrySuccess){
					try {
						// configure libcurl to perform a fresh connection
						addLogEntry("Configuring libcurl to use a fresh connection for re-try", ["debug"]);
						curlEngine.http.handle.set(CurlOption.fresh_connect,1);
						// try the access
						curlEngine.http.perform();
						// Check the HTTP Response headers - needed for correct 429 handling
						checkHTTPResponseHeaders();
						// no error from http.perform() on re-try
						addLogEntry("Internet connectivity to Microsoft OneDrive service has been restored");
						// unset the fresh connect option as this then creates performance issues if left enabled
						addLogEntry("Unsetting libcurl to use a fresh connection as this causes a performance impact if left enabled", ["debug"]);
						curlEngine.http.handle.set(CurlOption.fresh_connect,0);
						// connectivity restored
						retrySuccess = true;
					} catch (CurlException e) {
						// when was the exception generated
						currentTime = Clock.currTime();
						// Increment retry attempts
						retryAttempts++;
						if (canFind(e.msg, "Couldn't connect to server on handle") || canFind(e.msg, "Couldn't resolve host name on handle") || canFind(errorMessage, "Timeout was reached on handle")) {
							// no access to Internet
							addLogEntry();
							addLogEntry("ERROR: There was a timeout in accessing the Microsoft OneDrive service - Internet connectivity issue?");
							// what is the error reason to assis the user as what to check
							if (canFind(e.msg, "Couldn't connect to server on handle")) {
								addLogEntry("  - Check HTTPS access or Firewall Rules");
								timestampAlign = 9;
							}	
							if (canFind(e.msg, "Couldn't resolve host name on handle")) {
								addLogEntry("  - Check DNS resolution or Firewall Rules");
								timestampAlign = 0;
							}
							
							// increment backoff interval
							backoffInterval++;
							int thisBackOffInterval = retryAttempts*backoffInterval;
							
							// display retry information
							currentTime.fracSecs = Duration.zero;
							auto timeString = currentTime.toString();
							addLogEntry("  Retry attempt:          " ~ to!string(retryAttempts), ["verbose"]);
							addLogEntry("  This attempt timestamp: " ~ timeString, ["verbose"]);
							if (thisBackOffInterval > maxBackoffInterval) {
								thisBackOffInterval = maxBackoffInterval;
							}
							
							// detail when the next attempt will be tried
							// factor in the delay for curl to generate the exception - otherwise the next timestamp appears to be 'out' even though technically correct
							auto nextRetry = currentTime + dur!"seconds"(thisBackOffInterval) + dur!"seconds"(timestampAlign);
							addLogEntry("  Next retry in approx:   " ~ to!string((thisBackOffInterval + timestampAlign)) ~ " seconds", ["verbose"]);
							addLogEntry("  Next retry approx:      " ~ to!string(nextRetry), ["verbose"]);
							// thread sleep
							Thread.sleep(dur!"seconds"(thisBackOffInterval));
						}
						if (retryAttempts == retryCount) {
							// we have attempted to re-connect X number of times
							// false set this to true to break out of while loop
							retrySuccess = true;
						}
					}
				}
				if (retryAttempts >= retryCount) {
					addLogEntry("  ERROR: Unable to reconnect to the Microsoft OneDrive service after " ~ to!string(retryCount) ~ " attempts lasting over 1.2 years!");
					throw new OneDriveException(408, "Request Timeout - HTTP 408 or Internet down?");
				}
			} else {
			
				// what error was returned?
				if (canFind(errorMessage, "Problem with the SSL CA cert (path? access rights?) on handle")) {
					// error setting certificate verify locations:
					//  CAfile: /etc/pki/tls/certs/ca-bundle.crt
					//	CApath: none
					// 
					// Tell the Curl Engine to bypass SSL check - essentially SSL is passing back a bad value due to 'stdio' compile time option
					// Further reading:
					//  https://github.com/curl/curl/issues/6090
					//  https://github.com/openssl/openssl/issues/7536
					//  https://stackoverflow.com/questions/45829588/brew-install-fails-curl77-error-setting-certificate-verify
					//  https://forum.dlang.org/post/vwvkbubufexgeuaxhqfl@forum.dlang.org
					
					addLogEntry("Problem with reading the SSL CA cert via libcurl - please repair your system SSL CA Certificates");
					// Must force exit here, allow logging to be done. If needed later, we could re-use setDisableSSLVerifyPeer()
					Thread.sleep(dur!("msecs")(500));
					exit(-1);
				} else {
					// Log that an error was returned
					addLogEntry("ERROR: OneDrive returned an error with the following message:");
					// Some other error was returned
					addLogEntry("  Error Message: " ~ errorMessage);
					addLogEntry("  Calling Function: " ~ getFunctionName!({}));
				
					// Was this a curl initialization error?
					if (canFind(errorMessage, "Failed initialization on handle")) {
						// initialization error ... prevent a run-away process if we have zero disk space
						ulong localActualFreeSpace = getAvailableDiskSpace(".");
						if (localActualFreeSpace == 0) {
							// force exit
							shutdown();
							// Must force exit here, allow logging to be done
							Thread.sleep(dur!("msecs")(500));
							exit(-1);
						}
					}
				}
			}
			// return an empty JSON for handling
			return json;
		}

		try {
			json = content.parseJSON();
		} catch (JSONException e) {
			// Log that a JSON Exception was caught, dont output the HTML response from OneDrive
			addLogEntry("JSON Exception caught when performing HTTP operations - use --debug-https to diagnose further", ["debug"]);
		}
		return json;
	}
	
	private void redeemToken(char[] authCode){
		char[] postData =
			"client_id=" ~ clientId ~
			"&redirect_uri=" ~ redirectUrl ~
			"&code=" ~ authCode ~
			"&grant_type=authorization_code";
		acquireToken(postData);
	}
	
	private JSONValue upload(string filepath, string url) {
		checkAccessTokenExpired();
		// open file as read-only in binary mode
		auto file = File(filepath, "rb");

		// function scopes
		scope(exit) {
			curlEngine.http.clearRequestHeaders();
			curlEngine.http.onSend = null;
			curlEngine.http.onReceive = null;
			curlEngine.http.onReceiveHeader = null;
			curlEngine.http.onReceiveStatusLine = null;
			curlEngine.http.contentLength = 0;
			// close file if open
			if (file.isOpen()){
				// close open file
				file.close();
			}
		}

		curlEngine.connect(HTTP.Method.put, url);
		addAccessTokenHeader();
		curlEngine.http.addRequestHeader("Content-Type", "application/octet-stream");
		curlEngine.http.onSend = data => file.rawRead(data).length;
		curlEngine.http.contentLength = file.size;
		auto response = performHTTPOperation();
		checkHttpResponseCode(response);
		return response;
	}
	
	private void checkHTTPResponseHeaders() {
		// Get the HTTP Response headers - needed for correct 429 handling
		auto responseHeaders = curlEngine.http.responseHeaders();
		if (debugResponse){
			addLogEntry("curlEngine.http.perform() => HTTP Response Headers: " ~ to!string(responseHeaders), ["debug"]);
		}

		// is retry-after in the response headers
		if ("retry-after" in curlEngine.http.responseHeaders) {
			// Set the retry-after value
			addLogEntry("curlEngine.http.perform() => Received a 'Retry-After' Header Response with the following value: " ~ to!string(curlEngine.http.responseHeaders["retry-after"]), ["debug"]);
			addLogEntry("curlEngine.http.perform() => Setting retryAfterValue to: " ~ to!string(curlEngine.http.responseHeaders["retry-after"]), ["debug"]);
			retryAfterValue = to!ulong(curlEngine.http.responseHeaders["retry-after"]);
		}
	}

	private void checkHttpResponseCode(JSONValue response) {
		switch(curlEngine.http.statusLine.code) {
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
				// Log if --debug-https logging is used
				if (debugHTTPResponseOutput) {
					addLogEntry("OneDrive Response: '" ~ to!string(curlEngine.http.statusLine.code) ~ " - " ~ to!string(curlEngine.http.statusLine.reason) ~ "'", ["debug"]);
				}
				break;

			// 302 - resource found and available at another location, redirect
			case 302:
				// Log if --debug-https logging is used
				if (debugHTTPResponseOutput) {
					addLogEntry("OneDrive Response: '" ~ to!string(curlEngine.http.statusLine.code) ~ " - " ~ to!string(curlEngine.http.statusLine.reason) ~ "'", ["debug"]);
				}
				break;

			// 400 - Bad Request
			case 400:
				// Bad Request .. how should we act?
				// make sure this is thrown so that it is caught
				throw new OneDriveException(curlEngine.http.statusLine.code, curlEngine.http.statusLine.reason, response);

			// 403 - Forbidden
			case 403:
				// OneDrive responded that the user is forbidden
				addLogEntry("OneDrive returned a 'HTTP 403 - Forbidden' - gracefully handling error", ["verbose"]);
				
				// Throw this as a specific exception so this is caught when performing 'siteQuery = onedrive.o365SiteSearch(nextLink);' call
				throw new OneDriveException(curlEngine.http.statusLine.code, curlEngine.http.statusLine.reason, response);

			//	412 - Precondition Failed
			case 412:
				// Throw this as a specific exception so this is caught when performing sync.uploadLastModifiedTime
				throw new OneDriveException(curlEngine.http.statusLine.code, curlEngine.http.statusLine.reason, response);

			// Server side (OneDrive) Errors
			//  500 - Internal Server Error
			// 	502 - Bad Gateway
			//	503 - Service Unavailable
			//  504 - Gateway Timeout (Issue #320)
			case 500:
				// Throw this as a specific exception so this is caught
				throw new OneDriveException(curlEngine.http.statusLine.code, curlEngine.http.statusLine.reason, response);

			case 502:
				// Throw this as a specific exception so this is caught
				throw new OneDriveException(curlEngine.http.statusLine.code, curlEngine.http.statusLine.reason, response);

			case 503:
				// Throw this as a specific exception so this is caught
				throw new OneDriveException(curlEngine.http.statusLine.code, curlEngine.http.statusLine.reason, response);

			case 504:
				// Throw this as a specific exception so this is caught
				throw new OneDriveException(curlEngine.http.statusLine.code, curlEngine.http.statusLine.reason, response);

			// Default - all other errors that are not a 2xx or a 302
			default:
			if (curlEngine.http.statusLine.code / 100 != 2 && curlEngine.http.statusLine.code != 302) {
				throw new OneDriveException(curlEngine.http.statusLine.code, curlEngine.http.statusLine.reason, response);
			}
		}
	}
	
	private void checkHttpCode() {
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

		switch(curlEngine.http.statusLine.code)
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
				// Log if --debug-https logging is used
				if (debugHTTPResponseOutput) {
					addLogEntry("OneDrive Response: '" ~ to!string(curlEngine.http.statusLine.code) ~ " - " ~ to!string(curlEngine.http.statusLine.reason) ~ "'", ["debug"]);
				}
				break;

			// 302 - resource found and available at another location, redirect
			case 302:
				// Log if --debug-https logging is used
				if (debugHTTPResponseOutput) {
					addLogEntry("OneDrive Response: '" ~ to!string(curlEngine.http.statusLine.code) ~ " - " ~ to!string(curlEngine.http.statusLine.reason) ~ "'", ["debug"]);
				}
				break;

			// 400 - Bad Request
			case 400:
				// Bad Request .. how should we act?
				addLogEntry("OneDrive returned a 'HTTP 400 - Bad Request' - gracefully handling error", ["verbose"]);
				break;
				
			// 403 - Forbidden
			case 403:
				// OneDrive responded that the user is forbidden
				addLogEntry("OneDrive returned a 'HTTP 403 - Forbidden' - gracefully handling error", ["verbose"]);
				break;

			// 404 - Item not found
			case 404:
				// Item was not found - do not throw an exception
				addLogEntry("OneDrive returned a 'HTTP 404 - Item not found' - gracefully handling error", ["verbose"]);
				break;

			//	408 - Request Timeout
			case 408:
				// Request to connect to OneDrive service timed out
				addLogEntry("Request Timeout - gracefully handling error", ["verbose"]);
				throw new OneDriveException(408, "Request Timeout - HTTP 408 or Internet down?");

			//	409 - Conflict
			case 409:
				// Conflict handling .. how should we act? This only really gets triggered if we are using --local-first & we remove items.db as the DB thinks the file is not uploaded but it is
				addLogEntry("OneDrive returned a 'HTTP 409 - Conflict' - gracefully handling error", ["verbose"]);
				break;

			//	412 - Precondition Failed
			case 412:
				// A precondition provided in the request (such as an if-match header) does not match the resource's current state.
				addLogEntry("OneDrive returned a 'HTTP 412 - Precondition Failed' - gracefully handling error", ["verbose"]);
				break;

			//  415 - Unsupported Media Type
			case 415:
				// Unsupported Media Type ... sometimes triggered on image files, especially PNG
				addLogEntry("OneDrive returned a 'HTTP 415 - Unsupported Media Type' - gracefully handling error", ["verbose"]);
				break;

			//  429 - Too Many Requests
			case 429:
				// Too many requests in a certain time window
				// Check the HTTP Response headers - needed for correct 429 handling
				checkHTTPResponseHeaders();
				// https://docs.microsoft.com/en-us/sharepoint/dev/general-development/how-to-avoid-getting-throttled-or-blocked-in-sharepoint-online
				addLogEntry("OneDrive returned a 'HTTP 429 - Too Many Requests' - gracefully handling error", ["verbose"]);
				throw new OneDriveException(curlEngine.http.statusLine.code, curlEngine.http.statusLine.reason);

			// Server side (OneDrive) Errors
			//  500 - Internal Server Error
			// 	502 - Bad Gateway
			//	503 - Service Unavailable
			//  504 - Gateway Timeout (Issue #320)
			case 500:
				// No actions
				addLogEntry("OneDrive returned a 'HTTP 500 Internal Server Error' - gracefully handling error", ["verbose"]);
				break;

			case 502:
				// No actions
				addLogEntry("OneDrive returned a 'HTTP 502 Bad Gateway Error' - gracefully handling error", ["verbose"]);
				break;

			case 503:
				// No actions
				addLogEntry("OneDrive returned a 'HTTP 503 Service Unavailable Error' - gracefully handling error", ["verbose"]);
				break;

			case 504:
				// No actions
				addLogEntry("OneDrive returned a 'HTTP 504 Gateway Timeout Error' - gracefully handling error", ["verbose"]);
				break;

			// "else"
			default:
				throw new OneDriveException(curlEngine.http.statusLine.code, curlEngine.http.statusLine.reason);
		}
	}
}