module webhook;

// What does this module require to function?
import core.atomic : atomicOp;
import std.datetime;
import std.concurrency;
import std.json;

// What other modules that we have created do we need to import?
import arsd.cgi;
import config;
import onedrive;
import log;
import util;

class OneDriveWebhook {
	private RequestServer server;
	private string host;
	private ushort port;
	private Tid parentTid;
	private bool started;

    private ApplicationConfig appConfig;
	private OneDriveApi oneDriveApiInstance;
	string subscriptionId = "";
	SysTime subscriptionExpiration, subscriptionLastErrorAt;
	Duration subscriptionExpirationInterval, subscriptionRenewalInterval, subscriptionRetryInterval;
	string notificationUrl = "";

	private uint count;
	
    this(Tid parentTid, ApplicationConfig appConfig) {
		this.host = appConfig.getValueString("webhook_listening_host");
		this.port = to!ushort(appConfig.getValueLong("webhook_listening_port"));
		this.parentTid = parentTid;
        this.appConfig = appConfig;

		subscriptionExpiration = Clock.currTime(UTC());
		subscriptionLastErrorAt = SysTime.fromUnixTime(0);
		subscriptionExpirationInterval = dur!"seconds"(appConfig.getValueLong("webhook_expiration_interval"));
		subscriptionRenewalInterval = dur!"seconds"(appConfig.getValueLong("webhook_renewal_interval"));
		subscriptionRetryInterval = dur!"seconds"(appConfig.getValueLong("webhook_retry_interval"));
		notificationUrl = appConfig.getValueString("webhook_public_url");
	}
	
	// The static serve() is necessary because spawn() does not like instance methods
	void serve() {
		if (this.started) {
			return;
		}
		
		this.started = true;
		this.count = 0;

		server.listeningHost = this.host;
		server.listeningPort = this.port;

		spawn(&serveImpl, cast(shared) this);
		addLogEntry("Started OneDrive API Webhook server");

		// Subscriptions
		oneDriveApiInstance = new OneDriveApi(this.appConfig);
		oneDriveApiInstance.initialise();
		createOrRenewSubscription();
	}
    
    void stop() {
        if (!this.started)
            return;
        server.stop();
        this.started = false;

		addLogEntry("Stopped OneDrive API Webhook server");
		object.destroy(server);

        // Delete subscription if there exists any
		try {
			deleteSubscription();
		} catch (OneDriveException e) {
			logSubscriptionError(e);
		}
		// Release API instance back to the pool
		oneDriveApiInstance.releaseCurlEngine();
		object.destroy(oneDriveApiInstance);
		oneDriveApiInstance = null;
	}

	private static void handle(shared OneDriveWebhook _this, Cgi cgi) {
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
			addLogEntry("OneDrive API Webhook: handled validation request");
		} else {
			// Notifications don't include any information about the changes that triggered them.
			// Put a refresh signal in the queue and let the main monitor loop process it.
			// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/concepts/using-webhooks
			_this.count.atomicOp!"+="(1);
			send(cast()_this.parentTid, to!ulong(_this.count));
			cgi.write("OK");
			addLogEntry("OneDrive API Webhook: sent refresh signal #" ~ to!string(_this.count));
		}
	}

    private static void serveImpl(shared OneDriveWebhook _this) {
		_this.server.serveEmbeddedHttp!(handle, OneDriveWebhook)(_this);
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

	private bool hasValidSubscription() {
		return !subscriptionId.empty && subscriptionExpiration > Clock.currTime(UTC());
	}

	private bool isSubscriptionUpForRenewal() {
		return subscriptionExpiration < Clock.currTime(UTC()) + subscriptionRenewalInterval;
	}

	private void createSubscription() {
		addLogEntry("Initialising webhook subscription for updates ...");

		auto expirationDateTime = Clock.currTime(UTC()) + subscriptionExpirationInterval;
		try {
			JSONValue response = oneDriveApiInstance.createSubscription(notificationUrl, expirationDateTime);
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
				addLogEntry("Found existing webhook subscription " ~ subscriptionId);
				renewSubscription();
			} else {
				throw e;
			}
		}
	}
	
	private void renewSubscription() {
		addLogEntry("Renewing webhook subscription for updates ...");

		auto expirationDateTime = Clock.currTime(UTC()) + subscriptionExpirationInterval;
		try {
			JSONValue response = oneDriveApiInstance.renewSubscription(subscriptionId, expirationDateTime);

			// Update subscription expiration from the response
			subscriptionExpiration = SysTime.fromISOExtString(response["expirationDateTime"].str);
			addLogEntry("Renewed webhook subscription " ~ subscriptionId ~ " with expiration: " ~ to!string(subscriptionExpiration.toISOExtString()));
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
			return;
		}
		oneDriveApiInstance.deleteSubscription(subscriptionId);
		addLogEntry("Deleted subscription");
	}
	
	private void logSubscriptionError(OneDriveException e) {
		// Log a message to the GUI only
		addLogEntry("ERROR: An issue has occured with webhook subscriptions: " ~ e.error["error"]["message"].str, ["notify"]);
		// Use the standard OneDrive API logging method
		displayOneDriveErrorMessage(e.msg, getFunctionName!({}));
	}
}