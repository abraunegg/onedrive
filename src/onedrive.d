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
import progress;

// Shared variables between classes
shared bool debugHTTPResponseOutput = false;

class OneDriveException: Exception {
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/concepts/errors
	int httpStatusCode;
	JSONValue error;

	@safe pure this(HTTP.StatusLine statusLine, string file = __FILE__, size_t line = __LINE__) {
		this.httpStatusCode = statusLine.code;
		string msg = format("HTTP request returned status code %d (%s)", httpStatusCode, statusLine.reason);
		super(msg, file, line);
	}

	this(HTTP.StatusLine statusLine, ref const JSONValue error, string file = __FILE__, size_t line = __LINE__) {
		this.httpStatusCode = statusLine.code;
		this.error = error;
		string msg = format("HTTP request returned status code %d (%s)\n%s", httpStatusCode, statusLine.reason, toJSON(error, true));
		super(msg, file, line);
	}

	this(int httpStatusCode, string reason, string file = __FILE__, size_t line = __LINE__) {
		this.httpStatusCode = httpStatusCode;
		string msg = format("HTTP request returned status code %d (%s)\n%s", httpStatusCode, reason);
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

	private RequestServer *server;
	private string host;
	private ushort port;
	private Tid parentTid;
	private shared uint count;
	private OneDriveApi oneDriveApiInstance;

	string subscriptionId = "";
	SysTime subscriptionExpiration, subscriptionLastErrorAt;
	Duration subscriptionExpirationInterval, subscriptionRenewalInterval, subscriptionRetryInterval;
	string notificationUrl = "";

	static OneDriveWebhook getOrCreate(Tid parentTid, ApplicationConfig appConfig) {
		if (!instantiated_) {
			string host = appConfig.getValueString("webhook_listening_host");
			ushort port = to!ushort(appConfig.getValueLong("webhook_listening_port"));
			synchronized(OneDriveWebhook.classinfo) {
				if (!instance_) {
					instance_ = new OneDriveWebhook(host, port, parentTid, appConfig);
					spawn(&OneDriveWebhook.serve);
				}

				instantiated_ = true;
			}
		}

		return instance_;
	}

	private this(string host, ushort port, Tid parentTid, ApplicationConfig appConfig) {
		this.host = host;
		this.port = port;
		this.parentTid = parentTid;
		this.count = 0;
		this.oneDriveApiInstance = new OneDriveApi(appConfig);
		// Subscriptions
		subscriptionExpiration = Clock.currTime(UTC());
		subscriptionLastErrorAt = SysTime.fromUnixTime(0);
		subscriptionExpirationInterval = dur!"seconds"(appConfig.getValueLong("webhook_expiration_interval"));
		subscriptionRenewalInterval = dur!"seconds"(appConfig.getValueLong("webhook_renewal_interval"));
		subscriptionRetryInterval = dur!"seconds"(appConfig.getValueLong("webhook_retry_interval"));
		notificationUrl = appConfig.getValueString("webhook_public_url");
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
		server = new RequestServer(host, port);
		server.serveEmbeddedHttp!handle();
	}

	private void handleImpl(Cgi cgi) {
		if (debugHTTPResponseOutput) {
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

	// Create a new subscription or renew the existing subscription
	void createOrRenewSubscription() {
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
			log.log("Will retry creating or renewing subscription in ", subscriptionRetryInterval);
		} catch (JSONException e) {
			log.error("ERROR: Unexpected JSON error: ", e.msg);
			subscriptionLastErrorAt = Clock.currTime(UTC());
			log.log("Will retry creating or renewing subscription in ", subscriptionRetryInterval);
		}
	}

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

	void shutdown() {
		deleteSubscription();
		oneDriveApiInstance.shutdown();
		server.stop();
		server = null;
	}

	private bool hasValidSubscription() {
		return !subscriptionId.empty && subscriptionExpiration > Clock.currTime(UTC());
	}

	private bool isSubscriptionUpForRenewal() {
		return subscriptionExpiration < Clock.currTime(UTC()) + subscriptionRenewalInterval;
	}

	private void createSubscription() {
		log.log("Creating subscription for updates ...");

		auto expirationDateTime = Clock.currTime(UTC()) + subscriptionExpirationInterval;
		try {
			JSONValue response = oneDriveApiInstance.createSubscription(expirationDateTime, notificationUrl);
			// Save important subscription metadata including id and expiration
			subscriptionId = response["id"].str;
			subscriptionExpiration = SysTime.fromISOExtString(response["expirationDateTime"].str);
			log.log("Created new subscription ", subscriptionId, " with expiration: ", subscriptionExpiration.toISOExtString());
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
				log.log("Found existing subscription ", subscriptionId);
				renewSubscription();
			} else {
				throw e;
			}
		}
	}
	
	private void renewSubscription() {
		log.log("Renewing subscription for updates ...");

		auto expirationDateTime = Clock.currTime(UTC()) + subscriptionExpirationInterval;
		try {
			JSONValue response = oneDriveApiInstance.renewSubscription(subscriptionId, expirationDateTime);

			// Update subscription expiration from the response
			subscriptionExpiration = SysTime.fromISOExtString(response["expirationDateTime"].str);
			log.log("Renewed subscription ", subscriptionId, " with expiration: ", subscriptionExpiration.toISOExtString());
		} catch (OneDriveException e) {
			if (e.httpStatusCode == 404) {
				log.log("The subscription is not found on the server. Recreating subscription ...");
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
			return;
		}
		oneDriveApiInstance.deleteSubscription(subscriptionId);
		log.log("Deleted subscription");
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
						log.error("ERROR: Cannot create or renew subscription: Microsoft did not get 200 OK from the webhook endpoint.");
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
						log.error("ERROR: Cannot create or renew subscription: Authentication failed.");
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
						log.error("ERROR: Cannot create or renew subscription: Number of subscriptions has exceeded limit.");
						return;
					}
				}
			} catch (JSONException) {
				// fallthrough
			}
		}

		// Log detailed message for unknown errors
		log.error("ERROR: Cannot create or renew subscription.");
		displayOneDriveErrorMessage(e.msg, getFunctionName!({}));
	}
}

class OneDriveApi {
	// Class variables
	ApplicationConfig appConfig;
	CurlEngine curlEngine;
	
	// Client info
	string clientId = "";
	string companyName = "";
	// Configs
	bool dryRun = false;
	bool debugResponse = false;
	string tenantId = "";
	string authScope = "";
	// Endpoints
	// Authentication
	string authUrl = "";
	string redirectUrl = "";
	string tokenUrl = "";
	// Drive Queries
	string driveUrl = "";
	string driveByIdUrl = "";
	// What is 'shared with me' Query
	string sharedWithMeUrl = "";
	// Item Queries
	string itemByIdUrl = "";
	string itemByPathUrl = "";
	// Office 365 / SharePoint Queries
	string siteSearchUrl = "";
	string siteDriveUrl = "";
	// Subscriptions
	string subscriptionUrl = "";
	
	this(ApplicationConfig appConfig, bool keepAlive=false) {
		// Configure the class varaible to consume the application configuration
		this.appConfig = appConfig;
		initialise(keepAlive);
	}

	// Initialise the OneDrive API class
	private void initialise(bool keepAlive=false) {
		// Initialise the curl engine
		curlEngine = new CurlEngine();
		curlEngine.initialise(appConfig.getValueLong("dns_timeout"), appConfig.getValueLong("connect_timeout"), appConfig.getValueLong("data_timeout"), appConfig.getValueLong("operation_timeout"), appConfig.defaultMaxRedirects, appConfig.getValueBool("debug_https"), appConfig.getValueString("user_agent"), appConfig.getValueBool("force_http_11"), appConfig.getValueLong("rate_limit"), appConfig.getValueLong("ip_protocol_version"), appConfig.getValueBool("debug_https"), keepAlive);

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
					if (!appConfig.apiWasInitialised) log.log("Configuring Global Azure AD Endpoints");
				} else {
					if (!appConfig.apiWasInitialised) log.log("Configuring Global Azure AD Endpoints - Single Tenant Application");
				}
				break;
			case "USL4":
				if (!appConfig.apiWasInitialised) log.log("Configuring Azure AD for US Government Endpoints");
				break;
			case "USL5":
				if (!appConfig.apiWasInitialised) log.log("Configuring Azure AD for US Government Endpoints (DOD)");
				break;
			case "DE":
				if (!appConfig.apiWasInitialised) log.log("Configuring Azure AD Germany");
				break;
			case "CN":
				if (!appConfig.apiWasInitialised) log.log("Configuring AD China operated by 21Vianet");
				break;
			// Default - all other entries
			default:
				if (!appConfig.apiWasInitialised) log.log("Unknown Azure AD Endpoint request - using Global Azure AD Endpoints");
		}
		string authEndpoint = appConfig.endpoints[azureConfigValue].auth;
		string graphEndpoint = appConfig.endpoints[azureConfigValue].graph;

		authUrl = authEndpoint ~ "/" ~ tenantId ~ "/oauth2/v2.0/authorize";
		tokenUrl = authEndpoint ~ "/" ~ tenantId ~ "/oauth2/v2.0/token";
		if (clientId == appConfig.defaultApplicationId) {
			if (azureConfigValue != "") log.vdebug("Default application_id, redirectUrl needs to be aligned to globalAuthEndpoint");
			redirectUrl = appConfig.endpoints[""].auth ~ "/" ~ tenantId ~ "/oauth2/nativeclient";
		} else {
			redirectUrl = authEndpoint ~ "/" ~ tenantId ~ "/oauth2/nativeclient";
		}

		driveUrl = graphEndpoint ~ "/v1.0/me/drive";
		driveByIdUrl = graphEndpoint ~ "/v1.0/drives/";

		sharedWithMeUrl = graphEndpoint ~ "/v1.0/me/drive/sharedWithMe";
		
		itemByIdUrl = graphEndpoint ~ "/v1.0/me/drive/items/";
		itemByPathUrl = graphEndpoint ~ "/v1.0/me/drive/root:/";

		siteSearchUrl = graphEndpoint ~ "/v1.0/sites?search";
		siteDriveUrl = graphEndpoint ~ "/v1.0/sites/";
		
		subscriptionUrl = graphEndpoint ~ "/v1.0/subscriptions";
		
		appConfig.apiWasInitialised = true;
	}

	// If the API has been configured correctly, print the items that been configured
	void debugOutputConfiguredAPIItems() {
		// Debug output of configured URL's
		// Application Identification
		log.vdebug("Configured clientId          ", clientId);
		log.vdebug("Configured userAgent         ", appConfig.getValueString("user_agent"));
		// Authentication
		log.vdebug("Configured authScope:        ", authScope);
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
	}
	
	// Shutdown OneDrive API Curl Engine
	void shutdown() {
		curlEngine.shutdown();
		// Free object and memory
		object.destroy(curlEngine);
	}
	
	// Authenticate this client against Microsoft OneDrive API
	bool authorise() {
		char[] response;
		// What URL should be presented to the user to access
		string url = authUrl ~ "?client_id=" ~ clientId ~ authScope ~ redirectUrl;
		
		// Retry until user is authenticated
		long retryCount = 0;
		long retryInterval = 30;
		while (appConfig.getOneDriveRefreshToken().empty) {
			if (retryCount > 0) {
				log.error("Failed to authorize this application, retrying #",retryCount ," in ", retryInterval, " seconds");
				Thread.sleep(dur!("seconds")(retryInterval));
			}
			bool failure = false;
			// Configure automated authentication if --auth-files authUrl:responseUrl is being used
			string authFilesString = appConfig.getValueString("auth_files");
			string authResponseString = appConfig.getValueString("auth_response");
			
			if (!authResponseString.empty) {
				// Clear old response in case of failure
				appConfig.setValueString("auth_response", "");
				// Read the response from authResponseString
				response = cast(char[]) authResponseString;
			} else if (authFilesString != "") {
				string[] authFiles = authFilesString.split(":");
				string authUrl = authFiles[0];
				string responseUrl = authFiles[1];
				
				try {
					auto authUrlFile = File(authUrl, "w");
					authUrlFile.write(url);
					authUrlFile.close();
					
					log.log("Client requires authentication before proceeding. Waiting for --auth-files elements to be available.");
					while (!exists(responseUrl)) {
						Thread.sleep(dur!("msecs")(100));
					}
					
					// read response from provided from OneDrive
					response = cast(char[]) read(responseUrl);
				} catch (FileException e) {
					// There was a file system error
					// display the error message
					displayFileSystemErrorMessage(e.msg, getFunctionName!({}));
					failure = true;
				} catch (ErrnoException e) {
					// There was a file system error
					// display the error message
					displayFileSystemErrorMessage(e.msg, getFunctionName!({}));
					failure = true;
				}

				// try to remove old files
				try {
					std.file.remove(authUrl);
					std.file.remove(responseUrl);
				} catch (FileException e) {
					log.error("Cannot remove files ", authUrl, " ", responseUrl);
					failure = true;
				}
			} else {
				log.log("Authorise this application by visiting:\n");
				write(url, "\n\n", "Enter the response uri from your browser: ");
				readln(response);
			}
			if (!failure) {
				// match the authorization code
				auto c = matchFirst(response, r"(?:[\?&]code=)([\w\d-.]+)");
				if (c.empty) {
					log.log("An empty or invalid response uri was entered");
					return false;
				}
				c.popFront(); // skip the whole match
				redeemToken(c.front);
			}
			retryCount += 1;
		}

		// Return if we have a valid access token
		return retryCount > 0;
	}
	
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/drive_get
	JSONValue getDefaultDriveDetails() {
		string url;
		url = driveUrl;
		return get(url);
	}
	
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_get
	JSONValue getDefaultRootDetails() {
		string url;
		url = driveUrl ~ "/root";
		return get(url);
	}
	
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_get
	JSONValue getDriveIdRoot(string driveId) {
		string url;
		url = driveByIdUrl ~ driveId ~ "/root";
		return get(url);
	}
	
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/drive_get
	JSONValue getDriveQuota(string driveId) {
		string url;
		url = driveByIdUrl ~ driveId ~ "/";
		url ~= "?select=quota";
		return get(url);
	}


	// Return the details of the specified path, by giving the path we wish to query
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_get
	JSONValue getPathDetails(string path) {
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
		string url;
		url = driveByIdUrl ~ driveId ~ "/items/" ~ id;
		//url ~= "?select=id,name,eTag,cTag,deleted,file,folder,root,fileSystemInfo,remoteItem,parentReference,size";
		return get(url);
	}
	
	// Return the requested details of the specified path on the specified drive id and path
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_get
	JSONValue getPathDetailsByDriveId(string driveId, string path) {
		string url;
		// https://learn.microsoft.com/en-us/onedrive/developer/rest-api/concepts/addressing-driveitems?view=odsp-graph-online
		// Required format: /drives/{drive-id}/root:/{item-path}:
		url = driveByIdUrl ~ driveId ~ "/root:/" ~ encodeComponent(path) ~ ":";
		return get(url);
	}

	// Create a shareable link for an existing file on OneDrive based on the accessScope JSON permissions
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_createlink
	JSONValue createShareableLink(string driveId, string id, JSONValue accessScope) {
		string url;
		url = driveByIdUrl ~ driveId ~ "/items/" ~ id ~ "/createLink";
		return post(url, accessScope.toString());
	}
	
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_delta
	JSONValue viewChangesByItemId(string driveId, string id, string deltaLink) {
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
		string url;
		url = "https://graph.microsoft.com/v1.0/drives/" ~ driveId ~ "/root/search(q='" ~ encodeComponent(path) ~ "')";
		return get(url);
	}

	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_post_children
	JSONValue createById(string parentDriveId, string parentId, JSONValue item) {
		string url = driveByIdUrl ~ parentDriveId ~ "/items/" ~ parentId ~ "/children";
		return post(url, item.toString());
	}
	
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_update
	JSONValue updateById(const(char)[] driveId, const(char)[] id, JSONValue data, const(char)[] eTag = null) {
		const(char)[] url = driveByIdUrl ~ driveId ~ "/items/" ~ id;
		if (eTag) curlEngine.http.addRequestHeader("If-Match", eTag);
		return patch(url, data.toString());
	}
	
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_delete
	void deleteById(const(char)[] driveId, const(char)[] id, const(char)[] eTag = null) {
		const(char)[] url = driveByIdUrl ~ driveId ~ "/items/" ~ id;
		//TODO: investigate why this always fail with 412 (Precondition Failed)
		//if (eTag) http.addRequestHeader("If-Match", eTag);
		do_delete(url);
	}

	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_put_content
	JSONValue simpleUpload(string localPath, string parentDriveId, string parentId, string filename) {
		string url = driveByIdUrl ~ parentDriveId ~ "/items/" ~ parentId ~ ":/" ~ encodeComponent(filename) ~ ":/content";
		return put(url, localPath);
	}
	
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_put_content
	JSONValue simpleUploadReplace(string localPath, string driveId, string id) {
		string url = driveByIdUrl ~ driveId ~ "/items/" ~ id ~ "/content";
		return put(url, localPath);
	}

	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_createuploadsession
	//JSONValue createUploadSession(string parentDriveId, string parentId, string filename, string eTag = null, JSONValue item = null) {
	JSONValue createUploadSession(string parentDriveId, string parentId, string filename, const(char)[] eTag = null, JSONValue item = null) {
		string url = driveByIdUrl ~ parentDriveId ~ "/items/" ~ parentId ~ ":/" ~ encodeComponent(filename) ~ ":/createUploadSession";
		// eTag If-Match header addition commented out for the moment
		// At some point, post the creation of this upload session the eTag is being 'updated' by OneDrive, thus when uploadFragment() is used
		// this generates a 412 Precondition Failed and then a 416 Requested Range Not Satisfiable
		// This needs to be investigated further as to why this occurs
		//if (eTag) curlEngine.http.addRequestHeader("If-Match", eTag);
		return post(url, item.toString());
	}
	
	// https://dev.onedrive.com/items/upload_large_files.htm
	JSONValue uploadFragment(string uploadUrl, string filepath, long offset, long offsetSize, long fileSize) {
		// If we upload a modified file, with the current known online eTag, this gets changed when the session is started - thus, the tail end of uploading
		// a fragment fails with a 412 Precondition Failed and then a 416 Requested Range Not Satisfiable
		// For the moment, comment out adding the If-Match header in createUploadSession, which then avoids this issue
		string contentRange = "bytes " ~ to!string(offset) ~ "-" ~ to!string(offset + offsetSize - 1) ~ "/" ~ to!string(fileSize);
		log.vdebugNewLine("contentRange: ", contentRange);

		return put(uploadUrl, filepath, true, contentRange, offset, offsetSize);
	}

	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/site_search?view=odsp-graph-online
	JSONValue o365SiteSearch(string nextLink) {
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
		string url;
		url = siteDriveUrl ~ site_id ~ "/drives";
		return get(url);
	}
	
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_get_content
	void downloadById(const(char)[] driveId, const(char)[] id, string saveToPath, long fileSize) {
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
			log.vdebug("Setting file permissions for: ", saveToPath);
			saveToPath.setAttributes(appConfig.returnRequiredFilePermisions());
		}
	}
	
	// Return the actual siteSearchUrl being used and/or requested when performing 'siteQuery = onedrive.o365SiteSearch(nextLink);' call
	string getSiteSearchUrl() {
		return siteSearchUrl;
	}

	// Subscription
	private JSONValue createSubscription(SysTime expirationDateTime, string notificationUrl) {
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
		return post(url, request.toString());
	}
	
	private JSONValue renewSubscription(string subscriptionId, SysTime expirationDateTime) {
		string url;
		url = subscriptionUrl ~ "/" ~ subscriptionId;
		const JSONValue request = [
			"expirationDateTime": expirationDateTime.toISOExtString()
		];
		
		return patch(url, request.toString());
	}
	
	private void deleteSubscription(string subscriptionId) {
		string url;
		url = subscriptionUrl ~ "/" ~ subscriptionId;
		do_delete(url);
	}
	
	// Private functions
	// Oauth2 authorization
	private void checkAccessTokenExpired() {
		if (appConfig.accessToken.empty)
			return;
		// Clear the access token if it has expired
		if (Clock.currTime() >= appConfig.accessTokenExpiration)
			appConfig.accessToken = null;
	}

	private const(char)[] getAccessToken() {
		checkAccessTokenExpired();
		long retryCount = 0;
		long retryInterval = 30;
		while (appConfig.accessToken.empty) {
			if (retryCount > 0) {
				log.error("Failed to get accessToken , retrying #",retryCount ,"in ", retryInterval, " seconds");
				Thread.sleep(dur!("seconds")(retryInterval));
			}
			// Has the application been authenticated?
			if (!authorise()) {
				// Renew the accessToken
				newToken();
			}
			retryCount += 1;
		}
		return appConfig.accessToken;
	}
		
	private void acquireToken(char[] postData) {
		JSONValue response;

		try {
			response = post(tokenUrl, postData, true, "application/x-www-form-urlencoded");
		} catch (OneDriveException e) {
			// an error was generated
			int httpStatusCode = e.httpStatusCode;
			string message = e.msg;

			auto errorArray = splitLines(message);
			// Extract 'message' as the reason
			JSONValue errorMessage = parseJSON(replace(message, errorArray[0], ""));
			log.vdebug("errorMessage: ", errorMessage);

			if (httpStatusCode == 400) {
				// bad request or a new auth token is needed
				// configure the error reason
				writeln();
				string[] errorReason = splitLines(errorMessage["error_description"].str);
				log.errorAndNotify(errorReason[0]);
				writeln();
				log.errorAndNotify("ERROR: You will need to issue a --reauth and re-authorise this client to obtain a fresh auth token.");
				writeln();
			} else if (httpStatusCode == 401) {
				writeln();
				log.errorAndNotify("ERROR: Check your configuration as your refresh_token may be empty or invalid. You may need to issue a --reauth and re-authorise this client.");
				writeln();
				// Clear expired auth tokens
				appConfig.updateToken(Clock.currTime(), "", "");
			} else {
				displayOneDriveErrorMessage(e.msg, getFunctionName!({}));
			}
		}

		if (response.type() == JSONType.object) {
			// Has the client been configured to use read_only_auth_scope
			if (appConfig.getValueBool("read_only_auth_scope")) {
				// read_only_auth_scope has been configured
				if ("scope" in response){
					string effectiveScopes = response["scope"].str();
					// Display the effective authentication scopes
					writeln();
					writeln("Effective API Authentication Scopes: ", effectiveScopes);
					// if we have any write scopes, we need to tell the user to update an remove online prior authentication and exit application
					if (canFind(effectiveScopes, "Write")) {
						// effective scopes contain write scopes .. so not a read-only configuration
						writeln();
						writeln("ERROR: You have authentication scopes that allow write operations. You need to remove your existing application access consent");
						writeln();
						writeln("Please login to https://account.live.com/consent/Manage and remove your existing application access consent");
						writeln();
						return;
					}
				}
			}
		
			if ("access_token" in response){
				string accessToken = "bearer " ~ strip(response["access_token"].str);				
				string refreshToken = strip(response["refresh_token"].str);
				SysTime accessTokenExpiration = Clock.currTime() + dur!"seconds"(response["expires_in"].integer());
				appConfig.updateToken(accessTokenExpiration, accessToken, refreshToken);
				// Do we print the current access token
				if (log.verbose > 1) {
					if (appConfig.getValueBool("debug_https")) {
						if (appConfig.getValueBool("print_token")) {
							// This needs to be highly restricted in output .... 
							log.vdebug("CAUTION - KEEP THIS SAFE: Current access token: ", accessToken);
						}
					}
				}
			} else {
				log.error("\nInvalid authentication response from OneDrive. Please check the response uri\n");				
			}
		} else {
			log.log("Invalid response from the OneDrive API. Unable to initialise OneDrive API instance.");
		}
	}
	
	private void newToken() {
		log.vdebug("Need to generate a new access token for Microsoft OneDrive");
		string postData =
			"client_id=" ~ clientId ~
			"&redirect_uri=" ~ redirectUrl ~
			"&refresh_token=" ~ to!string(appConfig.getOneDriveRefreshToken()) ~
			"&grant_type=refresh_token";
		char[] strArr = postData.dup;
		acquireToken(strArr);
	}
	
	private void redeemToken(char[] authCode){
		char[] postData =
			"client_id=" ~ clientId ~
			"&redirect_uri=" ~ redirectUrl ~
			"&code=" ~ authCode ~
			"&grant_type=authorization_code";
		acquireToken(postData);
	}

	private void addAccessTokenHeader() {
		curlEngine.http.addRequestHeader("Authorization", getAccessToken());
	}

	private void addIncludeFeatureRequestHeader() {
		log.vdebug("Adding 'Include-Feature=AddToOneDrive' API request header as 'sync_business_shared_items' config option is enabled");
		curlEngine.http.addRequestHeader("Prefer", "Include-Feature=AddToOneDrive");
	}

	// connection
	private JSONValue get(string url, bool skipToken = false) {
		return oneDriveErrorHandlerWrapper(() {
			connect(HTTP.Method.get, url, skipToken);
			return curlEngine.execute();
		});
	}

	private void downloadFile(const(char)[] url, string filename, long fileSize) {
		// Threshold for displaying download bar
		long thresholdFileSize = 4 * 2^^20; // 4 MiB
		
		// To support marking of partially-downloaded files, 
		string originalFilename = filename;
		string downloadFilename = filename ~ ".partial";
		oneDriveErrorHandlerWrapper(() {
			CurlResponse nullVal;
			// open downloadFilename as write in binary mode
			auto file = File(downloadFilename, "wb");

			// function scopes
			scope(exit) {
				curlEngine.cleanUp();
				// Reset onProgress to not display anything for next download
				// close file if open
				if (file.isOpen()){
					// close open file
					file.close();
				}
			}

			connect(HTTP.Method.get, url, false);

			curlEngine.http.onReceive = (ubyte[] data) {
				file.rawWrite(data);
				return data.length;
			};

			bool useProgressbar = fileSize >= thresholdFileSize;
			Progress p;
			if (useProgressbar){
				// Download Progress Bar
				size_t iteration = 20;
				p = new Progress(iteration);
				p.title = "Downloading";
				writeln();
				bool barInit = false;
				real previousProgressPercent = -1.0;
				real percentCheck = 5.0;
				long segmentCount = 1;
				// Setup progress bar to display
				curlEngine.http.onProgress = delegate int(size_t dltotal, size_t dlnow, size_t ultotal, size_t ulnow)
				{
					// For each onProgress, what is the % of dlnow to dltotal
					// floor - rounds down to nearest whole number
					real currentDLPercent = floor(double(dlnow)/dltotal*100);
					// Have we started downloading?
					if (currentDLPercent > 0){
						// We have started downloading
						log.vdebugNewLine("Data Received    = ", dlnow);
						log.vdebug("Expected Total   = ", dltotal);
						log.vdebug("Percent Complete = ", currentDLPercent);
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
							ulong dataPerSegment = to!ulong(floor(double(dltotal)/iteration));
							// How much data received do we need to validate against
							ulong thisSegmentData = dataPerSegment * segmentCount;
							ulong nextSegmentData = dataPerSegment * (segmentCount + 1);
							// Has the data that has been received in a 5% window that we need to increment the progress bar at
							if ((dlnow > thisSegmentData) && (dlnow < nextSegmentData) && (previousProgressPercent != currentDLPercent) || (dlnow == dltotal)) {
								// Downloaded data equals approx 5%
								log.vdebug("Incrementing Progress Bar using calculated 5% of data received");
								// Downloading  50% |oooooooooooooooooooo                    |   ETA   00:01:40  
								// increment progress bar
								p.next();
								// update values
								log.vdebug("Setting previousProgressPercent to ", currentDLPercent);
								previousProgressPercent = currentDLPercent;
								log.vdebug("Incrementing segmentCount");
								segmentCount++;
							}
						} else {
							// Is currentDLPercent divisible by 5 leaving remainder 0 and does previousProgressPercent not equal currentDLPercent
							if ((isIdentical(fmod(currentDLPercent, percentCheck), 0.0)) && (previousProgressPercent != currentDLPercent)) {
								// currentDLPercent matches a new increment
								log.vdebug("Incrementing Progress Bar using fmod match");
								// Downloading  50% |oooooooooooooooooooo                    |   ETA   00:01:40  
								// increment progress bar
								p.next();
								// update values
								previousProgressPercent = currentDLPercent;
							}
						}
					} else {
						if ((currentDLPercent == 0) && (!barInit)) {
							// Initialise the download bar at 0%
							// Downloading   0% |                                        |   ETA   --:--:--:
							p.next();
							barInit = true;
						}
					}
					return 0;
				};

				// Perform download & display progress bar
			} else {
				// No progress bar
			}
			try {
				curlEngine.http.perform();
				// Rename downloaded file
				rename(downloadFilename, originalFilename);
				if (useProgressbar)
					writeln();
			} catch (Exception e) {
				remove(downloadFilename);
				throw e;
			}
			// free progress bar memory
			p = null;
			return nullVal;
		});
	}

	private JSONValue post(
		const(char)[] url, const(char)[] postData, 
		bool skipToken = false, 
		const(char)[] contentType = "application/json"
	) {
		return oneDriveErrorHandlerWrapper(() {
			connect(HTTP.Method.post, url, skipToken);
			curlEngine.setContent(contentType, postData);
			return curlEngine.execute();
		});
	}

	private JSONValue patch(
		const(char)[] url, const(char)[] patchData, 
		const(char)[] contentType = "application/json"
	) {
		return oneDriveErrorHandlerWrapper(() {
			connect(HTTP.Method.patch, url, false);
			curlEngine.setContent(contentType, patchData);
			return curlEngine.execute();
		});
	}
	
	private void do_delete(const(char)[] url) {
		oneDriveErrorHandlerWrapper(() {
			connect(HTTP.Method.del, url, false);
			return curlEngine.execute();
		});
	}


	private JSONValue put(const(char)[] url, string filepath, bool skipToken=false, string contentRange=null, ulong offset=0, ulong offsetSize=0) {
		return oneDriveErrorHandlerWrapper(() {
			// open file as read-only in binary mode
			auto file = File(filepath, "rb");
			if (!contentRange.empty)
				file.seek(offset);
			// function scopes
			scope(exit) {
				// close file if open
				if (file.isOpen()){
					// close open file
					file.close();
				}
			}
			if (!contentRange.empty)
				curlEngine.http.addRequestHeader("Content-Range", contentRange);
			else
				offsetSize = file.size;
			connect(HTTP.Method.put, url, skipToken);
			curlEngine.setFile(&file, offsetSize);
			return curlEngine.execute();
		});
	}

	private void connect(HTTP.Method method, const(char)[] url, bool skipToken) {
		log.vdebug("Request URL = ", url);
		// Check access token first in case the request is overridden
		if (!skipToken) addAccessTokenHeader();
		curlEngine.connect(method, url);
	}

	private JSONValue oneDriveErrorHandlerWrapper(CurlResponse delegate() executer) {
		int retryCount = 10000;
		int retryAttempts = 0;
		int backoffInterval = 0;
		int maxBackoffInterval = 3600;
		int timestampAlign = 0;
		bool retrySuccess = false;
		SysTime currentTime;
		CurlResponse response;
		JSONValue result;

		while (!retrySuccess && retryAttempts++ < retryCount) {
			try {
				response = executer();
				if (response) {
					result = response.json();
					checkHttpResponseCode(response.getStatus(), result);
				}
				retrySuccess = true;
				if (retryAttempts > 1) {
					// no error from http.perform() on re-try
					log.log("Internet connectivity to Microsoft OneDrive service has been restored");
					// unset the fresh connect option as this then creates performance issues if left enabled
					log.vdebug("Unsetting libcurl to use a fresh connection as this causes a performance impact if left enabled");
					curlEngine.http.handle.set(CurlOption.fresh_connect,0);
				}
			} catch (CurlException e) {
				retrySuccess = false;
				// Parse and display error message received from OneDrive
				log.vdebug("onedrive.performHTTPOperation() Generated a OneDrive CurlException");
				auto errorArray = splitLines(e.msg);
				string errorMessage = errorArray[0];
				
				// what is contained in the curl error message?
				if (canFind(errorMessage, "Couldn't connect to server on handle") || canFind(errorMessage, "Couldn't resolve host name on handle") || canFind(errorMessage, "Timeout was reached on handle")) {
					// This is a curl timeout
					// or is this a 408 request timeout
					// https://github.com/abraunegg/onedrive/issues/694
					
					// what caused the initial curl exception?
					if (canFind(errorMessage, "Couldn't connect to server on handle")) log.vdebug("Unable to connect to server - HTTPS access blocked?");
					if (canFind(errorMessage, "Couldn't resolve host name on handle")) log.vdebug("Unable to resolve server - DNS access blocked?");
					if (canFind(errorMessage, "Timeout was reached on handle")) log.vdebug("A timeout was triggered - data too slow, no response ... use --debug-https to diagnose further");
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
						
						log.vdebug("Problem with reading the SSL CA cert via libcurl - attempting work around");
						// TODO: User consent
						// curlEngine.setDisableSSLVerifyPeer();
						// continue to retry origional call
					} else {
						// Log that an error was returned
						log.error("ERROR: CurlException returned an error with the following message:");
						// Some other error was returned
						log.error("  Error Message: ", errorMessage);
						log.error("  Calling Function: ", getFunctionName!({}));
					
						// Was this a curl initialization error?
						if (canFind(errorMessage, "Failed initialization on handle")) {
							// initialization error ... prevent a run-away process if we have zero disk space
							ulong localActualFreeSpace = getAvailableDiskSpace(".");
							if (localActualFreeSpace == 0) {
								// force exit
								shutdown();
								exit(-1);
							}
						}
					}
				}
				// configure libcurl to perform a fresh connection
				log.vdebug("Configuring libcurl to use a fresh connection for re-try");
				curlEngine.http.handle.set(CurlOption.fresh_connect,1);

				// Back off & retry with incremental delay
				currentTime = Clock.currTime();
				// increment backoff interval
				backoffInterval++;
				int thisBackOffInterval = retryAttempts * backoffInterval;
							
				// display retry information
				currentTime.fracSecs = Duration.zero;
				auto timeString = currentTime.toString();
				log.vlog("  Retry attempt:          ", retryAttempts);
				log.vlog("  This attempt timestamp: ", timeString);
				if (thisBackOffInterval > maxBackoffInterval) {
					thisBackOffInterval = maxBackoffInterval;
				}
							
				// detail when the next attempt will be tried
				// factor in the delay for curl to generate the exception - otherwise the next timestamp appears to be 'out' even though technically correct
				auto nextRetry = currentTime + dur!"seconds"(thisBackOffInterval) + dur!"seconds"(timestampAlign);
				log.vlog("  Next retry in approx:   ", (thisBackOffInterval + timestampAlign), " seconds");
				log.vlog("  Next retry approx:      ", nextRetry);
				
				// thread sleep
				Thread.sleep(dur!"seconds"(thisBackOffInterval));		
			} catch (OneDriveException exception) {
				if ((exception.httpStatusCode == 408) || (exception.httpStatusCode == 429) || (exception.httpStatusCode == 503) || (exception.httpStatusCode == 504)) {
					log.vdebug("http.performHTTPOperation - received throttle request from OneDrive");
					long retryAfterValue = response.getRetryAfterValue();
					log.vdebug("Using Retry-After Value = ", retryAfterValue);
					log.log("\nThread sleeping due to 'HTTP request returned status code ", exception.httpStatusCode, "' - The request has been throttled");
					log.log("Sleeping for ", retryAfterValue, " seconds");
					Thread.sleep(dur!"seconds"(retryAfterValue));
					log.log("Retrying ...");
				} else
					throw exception;
			}
		}
		if (!retrySuccess) {
			log.error("  ERROR: Unable to reconnect to the Microsoft OneDrive service after ", retryCount, " attempts lasting over 1.2 years!");
			throw new OneDriveException(408, "Request Timeout after " ~ to!string(retryCount) ~ " attempts - HTTP 408 or Internet down?");
		}
		return result;
	}
	
	private void checkHttpResponseCode(HTTP.StatusLine statusLine, JSONValue response) {
		switch(statusLine.code) {
			//  0 - OK ... HTTP2 version of 200 OK
			case 0:
			//  100 - Continue
			case 100:
			//	200 - OK
			case 200:
			//	201 - Created OK
			//  202 - Accepted
			//	204 - Deleted OK
			case 201,202,204:
			// 302 - resource found and available at another location, redirect
			case 302:
				break;

			// Client side Errors
			// 400 - Bad Request
			case 400:
				// Bad Request .. how should we act?
			// 403 - Forbidden
			case 403:
				// OneDrive responded that the user is forbidden
			// 404 - Item not found
			case 404:
				// Item was not found - do not throw an exception
			//	408 - Request Timeout
			case 408:
				// Request to connect to OneDrive service timed out
			//	409 - Conflict
			case 409:
				// Conflict handling .. how should we act? This only really gets triggered if we are using --local-first & we remove items.db as the DB thinks the file is not uploaded but it is
			//	412 - Precondition Failed
			case 412:
				// The condition defined by headers is not fulfilled.
			//  415 - Unsupported Media Type
			case 415:
				// Unsupported Media Type ... sometimes triggered on image files, especially PNG
			//  429 - Too Many Requests
			case 429:
				// Too many requests in a certain time window
				// https://docs.microsoft.com/en-us/sharepoint/dev/general-development/how-to-avoid-getting-throttled-or-blocked-in-sharepoint-online
			// Server side (OneDrive) Errors
			//  500 - Internal Server Error
			// 	502 - Bad Gateway
			//	503 - Service Unavailable
			//  504 - Gateway Timeout (Issue #320)
			case 500:
			case 502:
			case 503:
			case 504:
				throw new OneDriveException(statusLine, response);

			// Default - all other errors that are not a 2xx or a 302
			default:
			if (statusLine.code / 100 != 2 && statusLine.code != 302) {
				throw new OneDriveException(statusLine, response);
			}
		}
	}	
}