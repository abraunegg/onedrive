// What is this module called?
module onedrive;

// What does this module require to function?
import core.stdc.stdlib: EXIT_SUCCESS, EXIT_FAILURE, exit;
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

// What other modules that we have created do we need to import?
import config;
import log;
import util;
import curlEngine;
import progress;

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

class OneDriveApi {
	// Class variables
	ApplicationConfig appConfig;
	CurlEngine curlEngine;
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
	string subscriptionUrl = "";
	string tenantId = "";
	string authScope = "";
	string refreshToken = "";
	string accessToken = "";
	SysTime accessTokenExpiration;
	bool dryRun = false;
	bool printAccessToken = false;
	bool debugResponse = false;
	ulong retryAfterValue = 0;
	
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
	}
	
	// Initialise the OneDrive API class
	bool initialise() {
		// Initialise the curl engine
		curlEngine = new CurlEngine();
		curlEngine.initialise(appConfig.getValueLong("dns_timeout"), appConfig.getValueLong("connect_timeout"), appConfig.getValueLong("data_timeout"), appConfig.getValueLong("operation_timeout"), appConfig.defaultMaxRedirects, appConfig.getValueBool("debug_https"), appConfig.getValueString("user_agent"), appConfig.getValueBool("force_http_11"), appConfig.getValueLong("rate_limit"), appConfig.getValueLong("ip_protocol_version"));

		// Authorised value to return
		bool authorised = false;

		// Did the user specify --dry-run
		dryRun = appConfig.getValueBool("dry_run");
		
		// Did the user specify --debug-https
		debugResponse = appConfig.getValueBool("debug_https");
		
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
				// Authentication
				authUrl = appConfig.globalAuthEndpoint ~ "/" ~ tenantId ~ "/oauth2/v2.0/authorize";
				redirectUrl = appConfig.globalAuthEndpoint ~ "/" ~ tenantId ~ "/oauth2/nativeclient";
				tokenUrl = appConfig.globalAuthEndpoint ~ "/" ~ tenantId ~ "/oauth2/v2.0/token";
				break;
			case "USL4":
				if (!appConfig.apiWasInitialised) log.log("Configuring Azure AD for US Government Endpoints");
				// Authentication
				authUrl = appConfig.usl4AuthEndpoint ~ "/" ~ tenantId ~ "/oauth2/v2.0/authorize";
				tokenUrl = appConfig.usl4AuthEndpoint ~ "/" ~ tenantId ~ "/oauth2/v2.0/token";
				if (clientId == appConfig.defaultApplicationId) {
					// application_id == default
					log.vdebug("USL4 AD Endpoint but default application_id, redirectUrl needs to be aligned to globalAuthEndpoint");
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
				if (!appConfig.apiWasInitialised) log.log("Configuring Azure AD for US Government Endpoints (DOD)");
				// Authentication
				authUrl = appConfig.usl5AuthEndpoint ~ "/" ~ tenantId ~ "/oauth2/v2.0/authorize";
				tokenUrl = appConfig.usl5AuthEndpoint ~ "/" ~ tenantId ~ "/oauth2/v2.0/token";
				if (clientId == appConfig.defaultApplicationId) {
					// application_id == default
					log.vdebug("USL5 AD Endpoint but default application_id, redirectUrl needs to be aligned to globalAuthEndpoint");
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
				if (!appConfig.apiWasInitialised) log.log("Configuring Azure AD Germany");
				// Authentication
				authUrl = appConfig.deAuthEndpoint ~ "/" ~ tenantId ~ "/oauth2/v2.0/authorize";
				tokenUrl = appConfig.deAuthEndpoint ~ "/" ~ tenantId ~ "/oauth2/v2.0/token";
				if (clientId == appConfig.defaultApplicationId) {
					// application_id == default
					log.vdebug("DE AD Endpoint but default application_id, redirectUrl needs to be aligned to globalAuthEndpoint");
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
				if (!appConfig.apiWasInitialised) log.log("Configuring AD China operated by 21Vianet");
				// Authentication
				authUrl = appConfig.cnAuthEndpoint ~ "/" ~ tenantId ~ "/oauth2/v2.0/authorize";
				tokenUrl = appConfig.cnAuthEndpoint ~ "/" ~ tenantId ~ "/oauth2/v2.0/token";
				if (clientId == appConfig.defaultApplicationId) {
					// application_id == default
					log.vdebug("CN AD Endpoint but default application_id, redirectUrl needs to be aligned to globalAuthEndpoint");
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
				if (!appConfig.apiWasInitialised) log.log("Unknown Azure AD Endpoint request - using Global Azure AD Endpoints");
		}
		
		// Has the application been authenticated?
		if (!exists(appConfig.refreshTokenFilePath)) {
			log.vdebug("Application has no 'refresh_token' thus needs to be authenticated");
			authorised = authorise();
		} else {
			// Try and read the value from the appConfig if it is set, rather than trying to read the value from disk
			if (!appConfig.refreshToken.empty) {
				log.vdebug("Read token from appConfig");
				refreshToken = strip(appConfig.refreshToken);
				authorised = true;
			} else {
				// Try and read the file from disk
				try {
					refreshToken = strip(readText(appConfig.refreshTokenFilePath));
					// is the refresh_token empty?
					if (refreshToken.empty) {
						log.error("refreshToken exists but is empty: ", appConfig.refreshTokenFilePath);
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
					log.error("Cannot read refreshToken from: ", appConfig.refreshTokenFilePath);
					log.error("  Error Reason:", e.msg);
					authorised = false;
				}
			}
			
			if (refreshToken.empty) {
				// PROBLEM
				writeln("refreshToken is empty !!!!!!!!!! will cause 4xx errors");
			}
		}
		// Return if we are authorised
		log.vdebug("Authorised State: ", authorised);
		return authorised;
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
		// Delete subscription if there exists any
		//deleteSubscription();

		// Reset any values to defaults, freeing any set objects
		curlEngine.http.clearRequestHeaders();
		curlEngine.http.onSend = null;
		curlEngine.http.onReceive = null;
		curlEngine.http.onReceiveHeader = null;
		curlEngine.http.onReceiveStatusLine = null;
		curlEngine.http.contentLength = 0;
		// Shut down the curl instance & close any open sockets
		curlEngine.http.shutdown();
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
			auto authUrlFile = File(authUrl, "w");
			authUrlFile.write(url);
			authUrlFile.close();
			
			log.log("Client requires authentication before proceeding. Waiting for --auth-files elements to be available.");
			
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
				log.error("Cannot remove files ", authUrl, " ", responseUrl);
				return false;
			}
		} else {
			log.log("Authorise this application by visiting:\n");
			write(url, "\n\n", "Enter the response uri from your browser: ");
			readln(response);
			appConfig.applicationAuthorizeResponseUri = true;
		}
		// match the authorization code
		auto c = matchFirst(response, r"(?:[\?&]code=)([\w\d-.]+)");
		if (c.empty) {
			log.log("An empty or invalid response uri was entered");
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
		return get(driveUrl);
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
	
	// Return the requested details of the specified path on the specified drive id and path
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_get
	JSONValue getPathDetailsByDriveId(string driveId, string path) {
		checkAccessTokenExpired();
		string url;
		// Required format: /drives/{drive-id}/root:/{item-path}
		url = driveByIdUrl ~ driveId ~ "/root:/" ~ encodeComponent(path);
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
		log.vdebugNewLine("contentRange: ", contentRange);

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

		curlEngine.http.method = HTTP.Method.put;
		curlEngine.http.url = uploadUrl;
		curlEngine.http.addRequestHeader("Content-Range", contentRange);
		curlEngine.http.onSend = data => file.rawRead(data).length;
		// convert offsetSize to ulong
		curlEngine.http.contentLength = to!ulong(offsetSize);
		auto response = performHTTPOperation();
		checkHttpResponseCode(response);
		return response;
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
	
	// Return the current value of retryAfterValue
	ulong getRetryAfterValue() {
		return retryAfterValue;
	}

	// Reset the current value of retryAfterValue to 0 after it has been used
	void resetRetryAfterValue() {
		retryAfterValue = 0;
	}
	
	private void addAccessTokenHeader() {
		curlEngine.http.addRequestHeader("Authorization", accessToken);
	}
	
	private void addIncludeFeatureRequestHeader() {
		log.vdebug("Adding 'Include-Feature=AddToOneDrive' API request header as 'sync_business_shared_items' config option is enabled");
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
						// force exit
						shutdown();
						exit(-1);
					}
				}
			}
		
			if ("access_token" in response){
				accessToken = "bearer " ~ strip(response["access_token"].str);
				refreshToken = strip(response["refresh_token"].str);
				accessTokenExpiration = Clock.currTime() + dur!"seconds"(response["expires_in"].integer());
				if (!dryRun) {
					// Update the refreshToken in appConfig so that we can reuse it
					if (appConfig.refreshToken.empty) {
						// The access token is empty
						log.vdebug("Updating appConfig.refreshToken with new refreshToken as appConfig.refreshToken is empty");
						appConfig.refreshToken = refreshToken;
					} else {
						// Is the access token different?
						if (appConfig.refreshToken != refreshToken) {
							// Update the memory version
							log.vdebug("Updating appConfig.refreshToken with updated refreshToken");
							appConfig.refreshToken = refreshToken;
						}
					}
					
					// try and update the refresh_token file on disk
					try {
						log.vdebug("Updating refreshToken on disk");
						std.file.write(appConfig.refreshTokenFilePath, refreshToken);
						log.vdebug("Setting file permissions for: ", appConfig.refreshTokenFilePath);
						appConfig.refreshTokenFilePath.setAttributes(appConfig.returnRequiredFilePermisions());
					} catch (FileException e) {
						// display the error message
						displayFileSystemErrorMessage(e.msg, getFunctionName!({}));
					}
				}
				if (printAccessToken) writeln("Current access token: ", accessToken);
			} else {
				log.error("\nInvalid authentication response from OneDrive. Please check the response uri\n");
				// re-authorize
				authorise();
			}
		} else {
			log.log("Invalid response from the OneDrive API. Unable to initialise OneDrive API instance.");
			exit(-1);
		}
	}
	
	private void checkAccessTokenExpired() {
		try {
			if (Clock.currTime() >= accessTokenExpiration) {
				newToken();
			}
		} catch (OneDriveException e) {
			if (e.httpStatusCode == 400 || e.httpStatusCode == 401) {
				// flag error and notify
				writeln();
				log.errorAndNotify("ERROR: Refresh token invalid, use --reauth to authorize the client again.");
				writeln();
				// set error message
				e.msg ~= "\nRefresh token invalid, use --reauth to authorize the client again";
			}
		}
	}
	
	private void performDelete(const(char)[] url) {
		scope(exit) curlEngine.http.clearRequestHeaders();
		curlEngine.http.method = HTTP.Method.del;
		curlEngine.http.url = url;
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

		curlEngine.http.method = HTTP.Method.get;
		curlEngine.http.url = url;
		addAccessTokenHeader();

		curlEngine.http.onReceive = (ubyte[] data) {
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
			try {
				// try and catch any curl error
				curlEngine.http.perform();
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
		log.vdebug("Request URL = ", url);
		curlEngine.http.method = HTTP.Method.get;
		curlEngine.http.url = url;
		if (!skipToken) addAccessTokenHeader(); // HACK: requestUploadStatus
		JSONValue response;
		response = performHTTPOperation();
		checkHttpResponseCode(response);
		// OneDrive API Response Debugging if --https-debug is being used
		if (debugResponse){
			log.vdebug("OneDrive API Response: ", response);
        }
		return response;
	}
	
	private void newToken() {
		string postData =
			"client_id=" ~ clientId ~
			"&redirect_uri=" ~ redirectUrl ~
			"&refresh_token=" ~ refreshToken ~
			"&grant_type=refresh_token";
		char[] strArr = postData.dup;
		acquireToken(strArr);
	}
	
	private auto patch(T)(const(char)[] url, const(T)[] patchData) {
		curlEngine.setMethodPatch();
		curlEngine.http.url = url;
		addAccessTokenHeader();
		auto response = perform(patchData);
		checkHttpResponseCode(response);
		return response;
	}
	
	private auto post(T)(string url, const(T)[] postData) {
		curlEngine.setMethodPost();
		curlEngine.http.url = url;
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
				log.vdebug("onedrive.performHTTPOperation() => OneDrive HTTP Server Response: ", curlEngine.http.statusLine.code);
			}
			return data.length;
		};

		try {
			curlEngine.http.perform();
			// Check the HTTP Response headers - needed for correct 429 handling
			checkHTTPResponseHeaders();
		} catch (CurlException e) {
			// Parse and display error message received from OneDrive
			log.vdebug("onedrive.performHTTPOperation() Generated a OneDrive CurlException");
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
				
				// what caused the initial curl exception?
				if (canFind(errorMessage, "Couldn't connect to server on handle")) log.vdebug("Unable to connect to server - HTTPS access blocked?");
				if (canFind(errorMessage, "Couldn't resolve host name on handle")) log.vdebug("Unable to resolve server - DNS access blocked?");
				if (canFind(errorMessage, "Timeout was reached on handle")) log.vdebug("A timeout was triggered - data too slow, no response ... use --debug-https to diagnose further");
				
				while (!retrySuccess){
					try {
						// configure libcurl to perform a fresh connection
						log.vdebug("Configuring libcurl to use a fresh connection for re-try");
						curlEngine.http.handle.set(CurlOption.fresh_connect,1);
						// try the access
						curlEngine.http.perform();
						// Check the HTTP Response headers - needed for correct 429 handling
						checkHTTPResponseHeaders();
						// no error from http.perform() on re-try
						log.log("Internet connectivity to Microsoft OneDrive service has been restored");
						// unset the fresh connect option as this then creates performance issues if left enabled
						log.vdebug("Unsetting libcurl to use a fresh connection as this causes a performance impact if left enabled");
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
							writeln();
							log.error("ERROR: There was a timeout in accessing the Microsoft OneDrive service - Internet connectivity issue?");
							// what is the error reason to assis the user as what to check
							if (canFind(e.msg, "Couldn't connect to server on handle")) {
								log.log("  - Check HTTPS access or Firewall Rules");
								timestampAlign = 9;
							}	
							if (canFind(e.msg, "Couldn't resolve host name on handle")) {
								log.log("  - Check DNS resolution or Firewall Rules");
								timestampAlign = 0;
							}
							
							// increment backoff interval
							backoffInterval++;
							int thisBackOffInterval = retryAttempts*backoffInterval;
							
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
						}
						if (retryAttempts == retryCount) {
							// we have attempted to re-connect X number of times
							// false set this to true to break out of while loop
							retrySuccess = true;
						}
					}
				}
				if (retryAttempts >= retryCount) {
					log.error("  ERROR: Unable to reconnect to the Microsoft OneDrive service after ", retryCount, " attempts lasting over 1.2 years!");
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
					
					log.vdebug("Problem with reading the SSL CA cert via libcurl - attempting work around");
					curlEngine.setDisableSSLVerifyPeer();
					// retry origional call
					performHTTPOperation();
				} else {
					// Log that an error was returned
					log.error("ERROR: OneDrive returned an error with the following message:");
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

		curlEngine.http.method = HTTP.Method.put;
		curlEngine.http.url = url;
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
			log.vdebug("curlEngine.http.perform() => HTTP Response Headers: ", responseHeaders);
		}

		// is retry-after in the response headers
		if ("retry-after" in curlEngine.http.responseHeaders) {
			// Set the retry-after value
			log.vdebug("curlEngine.http.perform() => Received a 'Retry-After' Header Response with the following value: ", curlEngine.http.responseHeaders["retry-after"]);
			log.vdebug("curlEngine.http.perform() => Setting retryAfterValue to: ", curlEngine.http.responseHeaders["retry-after"]);
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
				// No actions, but log if verbose logging
				//log.vlog("OneDrive Response: '", curlEngine.http.statusLine.code, " - ", curlEngine.http.statusLine.reason, "'");
				break;

			// 302 - resource found and available at another location, redirect
			case 302:
				break;

			// 400 - Bad Request
			case 400:
				// Bad Request .. how should we act?
				// make sure this is thrown so that it is caught
				throw new OneDriveException(curlEngine.http.statusLine.code, curlEngine.http.statusLine.reason, response);

			// 403 - Forbidden
			case 403:
				// OneDrive responded that the user is forbidden
				log.vlog("OneDrive returned a 'HTTP 403 - Forbidden' - gracefully handling error");
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
				throw new OneDriveException(curlEngine.http.statusLine.code, curlEngine.http.statusLine.reason);

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
				throw new OneDriveException(curlEngine.http.statusLine.code, curlEngine.http.statusLine.reason);
		}
	}
}