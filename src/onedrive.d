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
import std.algorithm;
import std.net.curl;
import std.datetime;
import std.path;
import std.conv;
import std.math;
import std.uri;
import std.array;

// Required for webhooks
import std.uuid;

// What other modules that we have created do we need to import?
import config;
import log;
import util;
import curlEngine;

// Shared variables between classes
shared bool debugHTTPResponseOutput = false;

// Define the 'OneDriveException' class
class OneDriveException: Exception {
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/concepts/errors
	int httpStatusCode;
	const CurlResponse response;
	JSONValue error;

	this(int httpStatusCode, string reason, const CurlResponse response, string file = __FILE__, size_t line = __LINE__) {
		this.httpStatusCode = httpStatusCode;
		this.response = response;
		this.error = response.json();
		string msg = format("HTTP request returned status code %d (%s)\n%s", httpStatusCode, reason, toJSON(error, true));
		super(msg, file, line);
	}

	this(int httpStatusCode, string reason, string file = __FILE__, size_t line = __LINE__) {
		this.response = null;
		super(msg, file, line, null);
	}
}

// Define the 'OneDriveError' class
class OneDriveError: Error {
	this(string msg) {
		super(msg);
	}
}

// Define the 'OneDriveApi' class
class OneDriveApi {
	// Class variables that use other classes
	ApplicationConfig appConfig;
	CurlEngine curlEngine;
	CurlResponse response;
	
	// Class variables
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
	const(char)[] refreshToken = "";
	bool dryRun = false;
	bool debugResponse = false;
	bool keepAlive = false;

	this(ApplicationConfig appConfig) {
		// Configure the class varaible to consume the application configuration
		this.appConfig = appConfig;
		this.curlEngine = null;
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
	
	// The destructor should only clean up resources owned directly by this instance
	~this() {
		if (curlEngine !is null) {
			curlEngine = null;
		} 
		
		if (response !is null) {
			response = null;
		}
	}

	// Initialise the OneDrive API class
	bool initialise(bool keepAlive=true) {
		// Initialise the curl engine
		this.keepAlive = keepAlive;
		if (curlEngine is null) {
			curlEngine = CurlEngine.getCurlInstance();
			curlEngine.initialise(appConfig.getValueLong("dns_timeout"), appConfig.getValueLong("connect_timeout"), appConfig.getValueLong("data_timeout"), appConfig.getValueLong("operation_timeout"), appConfig.defaultMaxRedirects, appConfig.getValueBool("debug_https"), appConfig.getValueString("user_agent"), appConfig.getValueBool("force_http_11"), appConfig.getValueLong("rate_limit"), appConfig.getValueLong("ip_protocol_version"), keepAlive);
		}

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
				if (!appConfig.apiWasInitialised) addLogEntry("Configuring AD China operated by VNET");
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
				} catch (FileException exception) {
					authorised = authorise();
				} catch (std.utf.UTFException exception) {
					// path contains characters which generate a UTF exception
					addLogEntry("Cannot read refreshToken from: " ~ appConfig.refreshTokenFilePath);
					addLogEntry("  Error Reason:" ~ exception.msg);
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
	
	// Release CurlEngine bask to the Curl Engine Pool
	void releaseCurlEngine() {
		// Log that this was called
		addLogEntry("OneDrive API releaseCurlEngine() CALLED", ["debug"]);
		// Release curl instance back to the pool
		if (curlEngine !is null) {
			curlEngine.releaseEngine();
			curlEngine = null;
		}
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
			} catch (FileException exception) {
				// There was a file system error
				// display the error message
				displayFileSystemErrorMessage(exception.msg, getFunctionName!({}));
				// Must force exit here, allow logging to be done
				Thread.sleep(dur!("msecs")(500));
				exit(-1);
			} catch (ErrnoException exception) {
				// There was a file system error
				// display the error message
				displayFileSystemErrorMessage(exception.msg, getFunctionName!({}));
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
			} catch (OneDriveException exception) {
				// exception generated
				displayOneDriveErrorMessage(exception.msg, getFunctionName!({}));
				return false;
			}

			// try to remove old files
			try {
				std.file.remove(authUrl);
				std.file.remove(responseUrl);
			} catch (FileException exception) {
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
	
	// Return all the items that are shared with the user
	// https://docs.microsoft.com/en-us/graph/api/drive-sharedwithme
	JSONValue getSharedWithMe() {
		return get(sharedWithMeUrl);
	}
	
	// Create a shareable link for an existing file on OneDrive based on the accessScope JSON permissions
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_createlink
	JSONValue createShareableLink(string driveId, string id, JSONValue accessScope) {
		string url;
		url = driveByIdUrl ~ driveId ~ "/items/" ~ id ~ "/createLink";
		return post(url, accessScope.toString());
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
	
	// Track changes for a given driveId
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_delta
	//   Your app begins by calling delta without any parameters. The service starts enumerating the drive's hierarchy, returning pages of items and either an @odata.nextLink or an @odata.deltaLink, as described below. 
	//   Your app should continue calling with the @odata.nextLink until you no longer see an @odata.nextLink returned, or you see a response with an empty set of changes.
	//   After you have finished receiving all the changes, you may apply them to your local state. To check for changes in the future, call delta again with the @odata.deltaLink from the previous successful response.
	JSONValue getChangesByItemId(string driveId, string id, string deltaLink) {
		string[string] requestHeaders;
		// If Business Account add Prefer: Include-Feature=AddToOneDrive
		if ((appConfig.accountType != "personal") && ( appConfig.getValueBool("sync_business_shared_items"))) {
			addIncludeFeatureRequestHeader(&requestHeaders);
		}
		
		string url;
		// configure deltaLink to query
		if (deltaLink.empty) {
			url = driveByIdUrl ~ driveId ~ "/items/" ~ id ~ "/delta";
		} else {
			url = deltaLink;
		}
		return get(url, false, requestHeaders);
	}
	
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_list_children
	JSONValue listChildren(string driveId, string id, string nextLink) {
		string[string] requestHeaders;
		// If Business Account add addIncludeFeatureRequestHeader() which should add Prefer: Include-Feature=AddToOneDrive
		if ((appConfig.accountType != "personal") && ( appConfig.getValueBool("sync_business_shared_items"))) {
			addIncludeFeatureRequestHeader(&requestHeaders);
		}
		
		string url;
		// configure URL to query
		if (nextLink.empty) {
			url = driveByIdUrl ~ driveId ~ "/items/" ~ id ~ "/children";
			//url ~= "?select=id,name,eTag,cTag,deleted,file,folder,root,fileSystemInfo,remoteItem,parentReference,size";
		} else {
			url = nextLink;
		}
		return get(url, false, requestHeaders);
	}
	
	// https://learn.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_search
	JSONValue searchDriveForPath(string driveId, string path) {
		string url;
		url = "https://graph.microsoft.com/v1.0/drives/" ~ driveId ~ "/root/search(q='" ~ encodeComponent(path) ~ "')";
		return get(url);
	}
	
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_update
	JSONValue updateById(const(char)[] driveId, const(char)[] id, JSONValue data, const(char)[] eTag = null) {
		string[string] requestHeaders;
		const(char)[] url = driveByIdUrl ~ driveId ~ "/items/" ~ id;
		if (eTag) requestHeaders["If-Match"] = to!string(eTag);
		return patch(url, data.toString(), requestHeaders);
	}
	
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_delete
	void deleteById(const(char)[] driveId, const(char)[] id, const(char)[] eTag = null) {
		// string[string] requestHeaders;
		const(char)[] url = driveByIdUrl ~ driveId ~ "/items/" ~ id;
		//TODO: investigate why this always fail with 412 (Precondition Failed)
		// if (eTag) requestHeaders["If-Match"] = eTag;
		performDelete(url);
	}
	
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_post_children
	JSONValue createById(string parentDriveId, string parentId, JSONValue item) {
		string url = driveByIdUrl ~ parentDriveId ~ "/items/" ~ parentId ~ "/children";
		return post(url, item.toString());
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
		// string[string] requestHeaders;
		string url = driveByIdUrl ~ parentDriveId ~ "/items/" ~ parentId ~ ":/" ~ encodeComponent(filename) ~ ":/createUploadSession";
		// eTag If-Match header addition commented out for the moment
		// At some point, post the creation of this upload session the eTag is being 'updated' by OneDrive, thus when uploadFragment() is used
		// this generates a 412 Precondition Failed and then a 416 Requested Range Not Satisfiable
		// This needs to be investigated further as to why this occurs
		// if (eTag) requestHeaders["If-Match"] = eTag;
		return post(url, item.toString());
	}
	
	// https://dev.onedrive.com/items/upload_large_files.htm
	JSONValue uploadFragment(string uploadUrl, string filepath, long offset, long offsetSize, long fileSize) {
		// open file as read-only in binary mode
		
		// If we upload a modified file, with the current known online eTag, this gets changed when the session is started - thus, the tail end of uploading
		// a fragment fails with a 412 Precondition Failed and then a 416 Requested Range Not Satisfiable
		// For the moment, comment out adding the If-Match header in createUploadSession, which then avoids this issue
		
		string contentRange = "bytes " ~ to!string(offset) ~ "-" ~ to!string(offset + offsetSize - 1) ~ "/" ~ to!string(fileSize);
		addLogEntry("", ["debug"]); // Add an empty newline before log output
		addLogEntry("contentRange: " ~ contentRange, ["debug"]);

		return put(uploadUrl, filepath, true, contentRange, offset, offsetSize);
	}
	
	// https://dev.onedrive.com/items/upload_large_files.htm
	JSONValue requestUploadStatus(string uploadUrl) {
		return get(uploadUrl, true);
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

	JSONValue createSubscription(string notificationUrl, SysTime expirationDateTime) {
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
		return post(url, request.toString());
	}
	
	JSONValue renewSubscription(string subscriptionId, SysTime expirationDateTime) {
		string url;
		url = subscriptionUrl ~ "/" ~ subscriptionId;
		const JSONValue request = [
			"expirationDateTime": expirationDateTime.toISOExtString()
		];
		curlEngine.http.addRequestHeader("Content-Type", "application/json");
		return post(url, request.toString());
	}
	
	void deleteSubscription(string subscriptionId) {
		string url;
		url = subscriptionUrl ~ "/" ~ subscriptionId;
		performDelete(url);
	}
	
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_get_content
	void downloadById(const(char)[] driveId, const(char)[] id, string saveToPath, long fileSize) {
		scope(failure) {
			if (exists(saveToPath)) {
				// try and remove the file, catch error
				try {
					remove(saveToPath);
				} catch (FileException exception) {
					// display the error message
					displayFileSystemErrorMessage(exception.msg, getFunctionName!({}));
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
			} catch (FileException exception) {
				// display the error message
				displayFileSystemErrorMessage(exception.msg, getFunctionName!({}));
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
	
	// Private OneDrive API Functions
	private void addIncludeFeatureRequestHeader(string[string]* headers) {
		addLogEntry("Adding 'Include-Feature=AddToOneDrive' API request header as 'sync_business_shared_items' config option is enabled", ["debug"]);
		(*headers)["Prefer"] = "Include-Feature=AddToOneDrive";
	}

	private void redeemToken(char[] authCode){
		char[] postData =
			"client_id=" ~ clientId ~
			"&redirect_uri=" ~ redirectUrl ~
			"&code=" ~ authCode ~
			"&grant_type=authorization_code";
		acquireToken(postData);
	}
	
	private void acquireToken(char[] postData) {
		JSONValue response;

		try {
			response = post(tokenUrl, postData, true, "application/x-www-form-urlencoded");
		} catch (OneDriveException exception) {
			// an error was generated
			if ((exception.httpStatusCode == 400) || (exception.httpStatusCode == 401)) {
				// Handle an unauthorised client
				handleClientUnauthorised(exception.httpStatusCode, exception.msg);
			} else {
				if (exception.httpStatusCode >= 500) {
					// There was a HTTP 5xx Server Side Error - retry
					acquireToken(postData);
				} else {
					displayOneDriveErrorMessage(exception.msg, getFunctionName!({}));
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
						releaseCurlEngine();
						// Must force exit here, allow logging to be done
						forceExit();
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
					} catch (FileException exception) {
						// display the error message
						displayFileSystemErrorMessage(exception.msg, getFunctionName!({}));
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
			forceExit();
		}
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
	
	private void checkAccessTokenExpired() {
		if (Clock.currTime() >= appConfig.accessTokenExpiration) {
			addLogEntry("Microsoft OneDrive Access Token has EXPIRED. Must generate a new Microsoft OneDrive Access Token", ["debug"]);
			newToken();
		} else {
			addLogEntry("Existing Microsoft OneDrive Access Token Expires: " ~ to!string(appConfig.accessTokenExpiration), ["debug"]);
		}
	}
	
	private string getAccessToken() {
		checkAccessTokenExpired();
		return to!string(appConfig.accessToken);
	}

	private void addAccessTokenHeader(string[string]* requestHeaders) {
		(*requestHeaders)["Authorization"] = getAccessToken();
	}
	
	private void connect(HTTP.Method method, const(char)[] url, bool skipToken, CurlResponse response, string[string] requestHeaders=null) {
		addLogEntry("Request URL = " ~ to!string(url), ["debug"]);
		// Check access token first in case the request is overridden
		if (!skipToken) addAccessTokenHeader(&requestHeaders);
		curlEngine.setResponseHolder(response);
		foreach(k, v; requestHeaders) {
			curlEngine.addRequestHeader(k, v);
		}
		curlEngine.connect(method, url);
	}

	private void performDelete(const(char)[] url, string[string] requestHeaders=null, string callingFunction=__FUNCTION__, int lineno=__LINE__) {
		bool validateJSONResponse = false;
		oneDriveErrorHandlerWrapper((CurlResponse response) {
			connect(HTTP.Method.del, url, false, response, requestHeaders);
			return curlEngine.execute();
		}, validateJSONResponse, callingFunction, lineno);
	}
	
	private void downloadFile(const(char)[] url, string filename, long fileSize, string callingFunction=__FUNCTION__, int lineno=__LINE__) {
		// Threshold for displaying download bar
		long thresholdFileSize = 4 * 2^^20; // 4 MiB
		
		// To support marking of partially-downloaded files, 
		string originalFilename = filename;
		string downloadFilename = filename ~ ".partial";
		bool validateJSONResponse = false;
		oneDriveErrorHandlerWrapper((CurlResponse response) {
			connect(HTTP.Method.get, url, false, response);

			if (fileSize >= thresholdFileSize){
				// Download Progress variables
				size_t expected_total_segments = 20;
				ulong start_unix_time = Clock.currTime.toUnixTime();
				int h, m, s;
				string etaString;
				bool barInit = false;
				real previousProgressPercent = -1.0;
				real percentCheck = 5.0;
				size_t segmentCount = -1;
				
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
			} else {
				// No progress bar
			}
			
			return curlEngine.download(originalFilename, downloadFilename);
		}, validateJSONResponse, callingFunction, lineno);
	}

	private JSONValue get(string url, bool skipToken = false, string[string] requestHeaders=null, string callingFunction=__FUNCTION__, int lineno=__LINE__) {
		bool validateJSONResponse = true;
		return oneDriveErrorHandlerWrapper((CurlResponse response) {
			connect(HTTP.Method.get, url, skipToken, response, requestHeaders);
			return curlEngine.execute();
		}, validateJSONResponse, callingFunction, lineno);
	}

	private JSONValue patch(const(char)[] url, const(char)[] patchData, string[string] requestHeaders=null, const(char)[] contentType = "application/json", string callingFunction=__FUNCTION__, int lineno=__LINE__) {
		bool validateJSONResponse = true;
		return oneDriveErrorHandlerWrapper((CurlResponse response) {
			connect(HTTP.Method.patch, url, false, response, requestHeaders);
			curlEngine.setContent(contentType, patchData);
			return curlEngine.execute();
		}, validateJSONResponse, callingFunction, lineno);
	}

	private JSONValue post(const(char)[] url, const(char)[] postData, bool skipToken = false, const(char)[] contentType = "application/json", string callingFunction=__FUNCTION__, int lineno=__LINE__) {
		bool validateJSONResponse = true;
		return oneDriveErrorHandlerWrapper((CurlResponse response) {
			connect(HTTP.Method.post, url, skipToken, response);
			curlEngine.setContent(contentType, postData);
			return curlEngine.execute();
		}, validateJSONResponse, callingFunction, lineno);
	}
	
	private JSONValue put(const(char)[] url, string filepath, bool skipToken=false, string contentRange=null, ulong offset=0, ulong offsetSize=0, string callingFunction=__FUNCTION__, int lineno=__LINE__) {
		bool validateJSONResponse = true;
		return oneDriveErrorHandlerWrapper((CurlResponse response) {
			connect(HTTP.Method.put, url, skipToken, response);
			curlEngine.setFile(filepath, contentRange, offset, offsetSize);
			return curlEngine.execute();
		}, validateJSONResponse, callingFunction, lineno);
	}

	// Wrapper function for all requests to OneDrive API
	// - This should throw a OneDriveException so that this exception can be handled appropriately elsewhere in the application
	private JSONValue oneDriveErrorHandlerWrapper(CurlResponse delegate(CurlResponse response) executer, bool validateJSONResponse, string callingFunction, int lineno) {
		// Create a new 'curl' response
		response = new CurlResponse();
		
		// Other wrapper variables
		int retryAttempts = 0;
		int baseBackoffInterval = 1; // Base backoff interval in seconds
		int maxRetryCount = 175200; // Approx 365 days based on maxBackoffInterval + appConfig.defaultDataTimeout
		//int maxRetryCount = 5; // Temp
		int maxBackoffInterval = 120; // Maximum backoff interval in seconds
		int thisBackOffInterval = 0;
		int timestampAlign = 0;
		JSONValue result;
		SysTime currentTime;
		SysTime retryTime;
		bool retrySuccess = false;
		bool transientError = false;
		
		while (!retrySuccess) {
			// Reset thisBackOffInterval
			thisBackOffInterval = 0;
			transientError = false;
			
			if (retryAttempts >= 1) {
				// re-try log entry & clock time
				retryTime = Clock.currTime();
				retryTime.fracSecs = Duration.zero;
				addLogEntry("Retrying the respective OneDrive Graph API call ... (" ~ to!string(retryTime) ~ ")");
			}
		
			try {
				response.reset();
				response = executer(response);
				// Check for a valid response
				if (response.hasResponse) {
					// Process the response
					result = response.json();
					// Print response if 'debugResponse' is flagged
					if (debugResponse){
						addLogEntry("OneDrive API Response: " ~ response.dumpResponse(), ["debug"]);
					}
					// Check http response code, raise a OneDriveException if the operation was not successfully performed
					// '100 != 2' This condition checks if the response code does not start with 2. In the context of HTTP response codes, the 2xx series represents successful responses.
					// '!= 302' This condition explicitly checks if the response code is not 302. The 302 status code represents a temporary redirect, indicating that the requested resource has been temporarily moved to a different URI.
					if (response.statusLine.code / 100 != 2 && response.statusLine.code != 302) {
						// Not a 2xx or 302 response code
						// Every other HTTP status code, including those from the 1xx (Informational), 3xx (other Redirection codes excluding 302), 4xx (Client Error), and 5xx (Server Error) series, will trigger the following line of code.
						throw new OneDriveException(response.statusLine.code, response.statusLine.reason, response);
					}
					// Do we need to validate the JSON response?
					if (validateJSONResponse) {
						if (result.type() != JSONType.object) {
							throw new OneDriveException(0, "Caller request a non null JSON response, get null instead", response);
						}
					}
					
					// If retryAtempts is greater than 1, it means we were re-trying the request
					if (retryAttempts > 1) {
						// No error from http.perform() on re-try
						if (!transientError) {
							// Log that Internet access has been restored
							addLogEntry("Internet connectivity to Microsoft OneDrive service has been restored");
						}
						// unset the fresh connect option as this then creates performance issues if left enabled
						addLogEntry("Unsetting libcurl to use a fresh connection as this causes a performance impact if left enabled", ["debug"]);
						curlEngine.http.handle.set(CurlOption.fresh_connect,0);
					}
					
					// On successful processing, break out of the loop
					break;
				} else {
					// Throw a custom 506 error
					// Whilst this error code is a bit more esoteric and typically involves content negotiation issues that lead to a configuration error on the server, but it could be loosely 
					// interpreted to signal that the response received didn't meet the expected criteria or format.
					throw new OneDriveException(506, "Received an unexpected response from Microsoft OneDrive", response);
				}
			// A 'curl' exception was thrown 
			} catch (CurlException exception) {
				// Handle 'curl' exception errors
				
				// Detail the curl exception, debug output only
				addLogEntry("Handling a specific Curl exception:", ["debug"]);
				addLogEntry(to!string(response), ["debug"]);
				
				// Parse and display error message received from OneDrive
				addLogEntry(callingFunction ~ "() - Generated a OneDrive CurlException", ["debug"]);
				auto errorArray = splitLines(exception.msg);
				string errorMessage = errorArray[0];

				// Configure libcurl to perform a fresh connection
				setFreshConnectOption();

				// What is contained in the curl error message?
				if (canFind(errorMessage, "Couldn't connect to server on handle") || canFind(errorMessage, "Couldn't resolve host name on handle") || canFind(errorMessage, "Timeout was reached on handle")) {
					// Connectivity to Microsoft OneDrive was lost
					addLogEntry("Internet connectivity to Microsoft OneDrive service has been interrupted .. re-trying in the background");
					
					// What caused the initial curl exception?
					if (canFind(errorMessage, "Couldn't resolve host name on handle")) addLogEntry("Unable to resolve server - DNS access blocked?", ["debug"]);
					if (canFind(errorMessage, "Couldn't connect to server on handle")) addLogEntry("Unable to connect to server - HTTPS access blocked?", ["debug"]);
					if (canFind(errorMessage, "Timeout was reached on handle")) {
						// Common cause is libcurl trying IPv6 DNS resolution when there are only IPv4 DNS servers available
						addLogEntry("A libcurl timeout has been triggered - data transfer too slow, no DNS resolution response, no server response", ["verbose"]);
						// There are 3 common causes for this issue:
						// 1. Usually poor DNS resolution where libcurl flip/flops to use IPv6 and is unable to resolve
						// 2. A device between the user and Microsoft OneDrive is unable to correctly handle HTTP/2 communication
						// 3. No Internet access from this system at this point in time
						addLogEntry(" - IPv6 DNS resolution issues may be causing timeouts. Consider setting 'ip_protocol_version' to IPv4 to potentially avoid this", ["verbose"]);
						addLogEntry(" - HTTP/2 compatibility issues might also be interfering with your system. Use 'force_http_11' to switch to HTTP/1.1 to potentially avoid this", ["verbose"]);
						addLogEntry(" - If these options do not resolve this timeout issue, please use --debug-https to diagnose this issue further.", ["verbose"]);
					}
				} else {
					// Some other 'libcurl' error was returned
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
						
						addLogEntry("Problem with reading the local SSL CA cert via libcurl - please repair your system SSL CA Certificates");
						throw new OneDriveError("OneDrive operation encountered an issue with libcurl reading the local SSL CA Certificates");
					} else {
						// Was this a curl initialization error?
						if (canFind(errorMessage, "Failed initialization on handle")) {
							// initialization error ... prevent a run-away process if we have zero disk space
							ulong localActualFreeSpace = getAvailableDiskSpace(".");
							if (localActualFreeSpace == 0) {
								throw new OneDriveError("Zero disk space detected");
							}
						} else {
							// Unknown error
							displayGeneralErrorMessage(exception, callingFunction, lineno);
						}
					}
				}
			// A OneDrive API exception was thrown
			} catch (OneDriveException exception) {
				// https://developer.overdrive.com/docs/reference-guide
				// https://learn.microsoft.com/en-us/onedrive/developer/rest-api/concepts/errors?view=odsp-graph-online
				// https://learn.microsoft.com/en-us/graph/errors
				
				/**
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
					408				Request Time out					CUSTOM ERROR - Not expected from OneDrive, but can be used to handle Internet connection failures the same (fallback and try again)
					409				Conflict							The current state conflicts with what the request expects. For example, the specified parent folder might not exist.
					410				Gone								The requested resource is no longer available at the server.
					411				Length Required						A Content-Length header is required on the request.
					412				Precondition Failed					A precondition provided in the request (such as an if-match header) does not match the resource's current state.
					413				Request Entity Too Large			The request size exceeds the maximum limit.
					415				Unsupported Media Type				The content type of the request is a format that is not supported by the service.
					416				Requested Range Not Satisfiable		The specified byte range is invalid or unavailable.
					422				Unprocessable Entity				Cannot process the request because it is semantically incorrect.
					423				Locked								The file is currently checked out or locked for editing by another user
					429				Too Many Requests					Client application has been throttled and should not attempt to repeat the request until an amount of time has elapsed.

					500				Internal Server Error				There was an internal server error while processing the request.
					501				Not Implemented						The requested feature isn’t implemented.
					502				Bad Gateway							The service was unreachable
					503				Service Unavailable					The service is temporarily unavailable. You may repeat the request after a delay. There may be a Retry-After header.
					504				Gateway Timeout						The server, which is acting as a gateway or proxy, did not receive a timely response from an upstream server it needed to access in order to complete the request
					506				Variant Also Negotiates				CUSTOM ERROR - Received an unexpected response from Microsoft OneDrive
					507				Insufficient Storage				The maximum storage quota has been reached.
					509				Bandwidth Limit Exceeded			Your app has been throttled for exceeding the maximum bandwidth cap. Your app can retry the request again after more time has elapsed.

					HTTP/2 Response handling

					0				OK
					
				**/
				
				// Detail the OneDriveAPI exception, debug output only
				addLogEntry("Handling a OneDrive API exception:", ["debug"]);
				addLogEntry(to!string(response), ["debug"]);
				
				// Parse and display error message received from OneDrive
				addLogEntry(callingFunction ~ "() - Generated a OneDriveException", ["debug"]);
				
				// Configure libcurl to perform a fresh connection on API retry
				setFreshConnectOption();
				
				// Perform action based on the HTTP Status Code
				switch(exception.httpStatusCode) {
					
					//  0 - OK ... HTTP/2 version of 200 OK
					case 0:
						break;
					//  100 - Continue
					case 100:
						break;
					//  408 - Request Time Out
					//  429 - Too Many Requests, backoff
					case 408,429:
						// If OneDrive sends a status code 429 then this function will be used to process the Retry-After response header which contains the value by which we need to wait
						if (exception.httpStatusCode == 408) {
							addLogEntry("Handling a OneDrive HTTP 408 Response Code (Request Time Out) - Internal Thread ID: " ~ to!string(curlEngine.internalThreadId));
						} else {
							addLogEntry("Handling a OneDrive HTTP 429 Response Code (Too Many Requests) - Internal Thread ID: " ~ to!string(curlEngine.internalThreadId));
						}
						// Read in the Retry-After HTTP header as set and delay as per this value before retrying the request
						thisBackOffInterval = response.getRetryAfterValue();
						addLogEntry("Using Retry-After Value = " ~ to!string(thisBackOffInterval), ["debug"]);
						addLogEntry("Using Retry-After Value = " ~ to!string(thisBackOffInterval));
						transientError = true;
						break;
					//  Transient errors
					//	503 - Service Unavailable
					//  504 - Gateway Timeout
					case 503,504:
						// The server, while acting as a proxy, did not receive a timely response from the upstream server it needed to access in attempting to complete the request
						auto errorArray = splitLines(exception.msg);
						addLogEntry(to!string(errorArray[0]) ~ " when attempting to query the OneDrive API Service - retrying applicable request in 30 seconds - Internal Thread ID: " ~ to!string(curlEngine.internalThreadId));
						addLogEntry("Thread sleeping for 30 seconds as the server did not receive a timely response from the upstream server it needed to access in attempting to complete the request", ["debug"]);
						// Transient error - try again in 30 seconds
						thisBackOffInterval = 30;
						transientError = true;
						break;
					// Default
					default:
						// This exception should be then passed back to the original calling function for handling a OneDriveException
						throw new OneDriveException(curlEngine.http.statusLine.code, curlEngine.http.statusLine.reason, response);
				}
				
			// A FileSystem exception was thrown
			} catch (ErrnoException exception) {
				// There was a file system error
				// display the error message
				displayFileSystemErrorMessage(exception.msg, callingFunction);
				throw new OneDriveException(0, "There was a file system error during OneDrive request: " ~ exception.msg, response);
			}

			// Increment re-try counter
			retryAttempts++;
			
			// Has maxRetryCount been reached?
			if (retryAttempts > maxRetryCount) {
				addLogEntry("ERROR: Unable to reconnect to the Microsoft OneDrive service after " ~ to!string(retryAttempts) ~ " attempts lasting approximately 365 days");
				throw new OneDriveException(408, "Request Timeout - HTTP 408 or Internet down?", response);
			} else {
				// Was 'thisBackOffInterval' set by a 429 event ?
				if (thisBackOffInterval == 0) {
					// Calculate and apply exponential backoff upto a maximum of 120 seconds before the API call is re-tried
					thisBackOffInterval = calculateBackoff(retryAttempts, baseBackoffInterval, maxBackoffInterval);
				}
				
				// When are we re-trying the API call?
				currentTime = Clock.currTime();
				currentTime.fracSecs = Duration.zero;
				auto timeString = currentTime.toString();
				addLogEntry("Retry attempt:           " ~ to!string(retryAttempts) ~ " - Internal Thread ID: " ~ to!string(curlEngine.internalThreadId), ["verbose"]);
				addLogEntry(" This attempt timestamp: " ~ timeString, ["verbose"]);
				// Detail when the next attempt will be tried
				// Factor in the delay for curl to generate the exception - otherwise the next timestamp appears to be 'out' even though technically correct
				auto nextRetry = currentTime + dur!"seconds"(thisBackOffInterval) + dur!"seconds"(timestampAlign);
				addLogEntry(" Next retry in approx:   " ~ to!string((thisBackOffInterval + timestampAlign)) ~ " seconds");
				addLogEntry(" Next retry approx:      " ~ to!string(nextRetry), ["verbose"]);
				
				// Thread sleep
				Thread.sleep(dur!"seconds"(thisBackOffInterval));
			}
		}

		// Return the result
		return result;
	}
	
	// Calculates the delay for exponential backoff
	private int calculateBackoff(int retryAttempts, int baseInterval, int maxInterval) {
		int backoffTime = min(pow(2, retryAttempts) * baseInterval, maxInterval);
		return backoffTime;
	}
	
	// Configure libcurl to perform a fresh connection
	private void setFreshConnectOption() {
		addLogEntry("Configuring libcurl to use a fresh connection for re-try", ["debug"]);
		curlEngine.http.handle.set(CurlOption.fresh_connect,1);
	}
}