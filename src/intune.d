// What is this module called?
module intune;

// What does this module require to function?
import core.stdc.string : strcmp;
import core.stdc.stdlib : malloc, free;
import core.thread : Thread;
import core.time : dur;
import std.string : fromStringz, toStringz;
import std.conv : to;
import std.json : JSONValue, parseJSON, JSONType;
import std.uuid : randomUUID;
import std.range : empty;
import std.format : format;

// What 'onedrive' modules do we import?
import log;

extern(C):
alias dbus_bool_t = int;

struct DBusError {
    char* name;
    char* message;
    uint[8] dummy;
    void* padding;
}

struct DBusConnection;
struct DBusMessage;
struct DBusMessageIter;

enum DBusBusType {
    DBUS_BUS_SESSION = 0,
}

void dbus_error_init(DBusError* error);
void dbus_error_free(DBusError* error);
int dbus_error_is_set(DBusError* error);
DBusConnection* dbus_bus_get(DBusBusType type, DBusError* error);
dbus_bool_t dbus_bus_name_has_owner(DBusConnection* conn, const char* name, DBusError* error);
DBusMessage* dbus_message_new_method_call(const char* dest, const char* path, const char* iface, const char* method);
dbus_bool_t dbus_connection_send(DBusConnection* conn, DBusMessage* msg, void* client_serial);
void dbus_connection_flush(DBusConnection* conn);
DBusMessage* dbus_connection_send_with_reply_and_block(DBusConnection* conn, DBusMessage* msg, int timeout_ms, DBusError* error);
void dbus_message_unref(DBusMessage* msg);
dbus_bool_t dbus_message_iter_init_append(DBusMessage* msg, DBusMessageIter* iter);
dbus_bool_t dbus_message_iter_append_basic(DBusMessageIter* iter, int type, const void* value);
dbus_bool_t dbus_message_iter_init(DBusMessage* msg, DBusMessageIter* iter);
dbus_bool_t dbus_message_iter_get_arg_type(DBusMessageIter* iter);
void dbus_message_iter_get_basic(DBusMessageIter* iter, void* value);

enum DBUS_TYPE_STRING = 115;
enum DBUS_MESSAGE_ITER_SIZE = 128;

enum BROKER_BUS_NAME = "com.microsoft.identity.broker1";
enum BROKER_OBJECT_PATH = "/com/microsoft/identity/broker1";
enum BROKER_INTERFACE = "com.microsoft.identity.Broker1";
enum BROKER_PROTOCOL_VERSION = "0.0";
enum DEFAULT_REDIRECT_URI = "https://login.microsoftonline.com/common/oauth2/nativeclient";
enum DEFAULT_AUTHORITY = "https://login.microsoftonline.com/common";

// Based on observed broker 3.x behaviour and Linux reference clients
enum AUTHORIZATION_TYPE_CACHED_REFRESH_TOKEN = 1;

struct BrokerCallResult {
    bool callSucceeded;
    bool responseIsJson;
    string rawResponse;
    JSONValue parsedJson;
}

struct AuthResult {
    JSONValue brokerTokenResponse;
}

bool check_intune_broker_available() {
    version (linux) {
        DBusError err;
        dbus_error_init(&err);

        DBusConnection* conn = dbus_bus_get(DBusBusType.DBUS_BUS_SESSION, &err);
        if (dbus_error_is_set(&err)) {
            dbus_error_free(&err);
            return false;
        }

        if (conn is null) {
            return false;
        }

        dbus_bool_t hasOwner = dbus_bus_name_has_owner(conn, BROKER_BUS_NAME, &err);
        if (dbus_error_is_set(&err)) {
            dbus_error_free(&err);
            return false;
        }

        return hasOwner != 0;
    } else {
        return false;
    }
}

bool wait_for_broker(int timeoutSeconds = 10) {
    int waited = 0;

    while (waited < timeoutSeconds) {
        if (check_intune_broker_available()) {
            return true;
        }

        Thread.sleep(dur!"seconds"(1));
        waited++;
    }

    return false;
}

string build_generic_client_request(string clientId) {
    return format(`{
  "clientId": "%s"
}`, clientId);
}

string extract_username_from_account_json(string accountJson) {
    if (accountJson.empty) {
        return "";
    }

    try {
        JSONValue parsed = parseJSON(accountJson);
        if (parsed.type != JSONType.object) {
            return "";
        }

        auto obj = parsed.object;

        if ("username" in obj && obj["username"].type == JSONType.string) {
            return obj["username"].str;
        }

        if ("userName" in obj && obj["userName"].type == JSONType.string) {
            return obj["userName"].str;
        }

        if ("upn" in obj && obj["upn"].type == JSONType.string) {
            return obj["upn"].str;
        }
    } catch (Exception) {
        // Ignore malformed or unexpected account JSON
    }

    return "";
}

string build_interactive_auth_request(string clientId) {
    return format(`{
  "authParameters": {
    "clientId": "%s",
    "redirectUri": "%s",
    "authority": "%s",
    "requestedScopes": [
      "Files.ReadWrite",
      "Files.ReadWrite.All",
      "Sites.ReadWrite.All"
    ]
  }
}`, clientId, DEFAULT_REDIRECT_URI, DEFAULT_AUTHORITY);
}

string build_silent_auth_request(string accountJson, string clientId) {
    string username = extract_username_from_account_json(accountJson);

    string requestJson = format(`{
  "authParameters": {
    "clientId": "%s",
    "redirectUri": "%s",
    "authority": "%s",
    "authorizationType": %s,
    "requestedScopes": [
      "Files.ReadWrite",
      "Files.ReadWrite.All",
      "Sites.ReadWrite.All"
    ],
    "additionalQueryParametersForAuthorization": {},
    "uxContextHandle": -1`,
        clientId,
        DEFAULT_REDIRECT_URI,
        DEFAULT_AUTHORITY,
        AUTHORIZATION_TYPE_CACHED_REFRESH_TOKEN
    );

    if (!accountJson.empty) {
        requestJson ~= `,
    "account": ` ~ accountJson;
    }

    if (!username.empty) {
        requestJson ~= format(`,
    "username": "%s"`, username);
    }

    requestJson ~= `
  }
}`;

    return requestJson;
}

bool try_parse_json_response(string jsonResponse, out JSONValue parsedJson) {
    try {
        parsedJson = parseJSON(jsonResponse);
        return true;
    } catch (Exception) {
        return false;
    }
}

bool broker_token_response_has_error(JSONValue brokerTokenResponse) {
    if (brokerTokenResponse.type != JSONType.object) {
        return true;
    }

    auto obj = brokerTokenResponse.object;
    return ("error" in obj) !is null;
}

// Validate that the broker token response contains the elements required by the wider auth flow.
// This intentionally checks for multiple possible key names because broker payload naming may vary.
bool broker_token_response_has_required_auth_elements(JSONValue brokerTokenResponse) {
    if (brokerTokenResponse.type != JSONType.object) {
        return false;
    }

    auto obj = brokerTokenResponse.object;

    bool hasAccessToken =
        (("accessToken" in obj) !is null) && obj["accessToken"].type == JSONType.string && !obj["accessToken"].str.empty;

    bool hasExpiry =
        (("expiresOn" in obj) !is null) || (("expires_on" in obj) !is null) || (("expiresIn" in obj) !is null) || (("expires_in" in obj) !is null);

    bool hasEmbeddedAccount =
        (("account" in obj) !is null) && obj["account"].type == JSONType.object;

    bool hasAlternateAccountContext =
        ((("clientInfo" in obj) !is null) && obj["clientInfo"].type == JSONType.string && !obj["clientInfo"].str.empty) ||
        ((("accountId" in obj) !is null) && obj["accountId"].type == JSONType.string);

    return hasAccessToken && hasExpiry && (hasEmbeddedAccount || hasAlternateAccountContext);
}

BrokerCallResult call_broker_method(string methodName, string requestJson, int timeoutMs = 10000) {
    BrokerCallResult result;

    version (linux) {
        DBusError err;
        dbus_error_init(&err);

        DBusConnection* conn = dbus_bus_get(DBusBusType.DBUS_BUS_SESSION, &err);
        if (dbus_error_is_set(&err) || conn is null) {
            if (dbus_error_is_set(&err)) {
                addLogEntry("Failed to connect to D-Bus session bus for Intune broker method: " ~ methodName);
                dbus_error_free(&err);
            }
            return result;
        }

        DBusMessage* msg = dbus_message_new_method_call(
            BROKER_BUS_NAME,
            BROKER_OBJECT_PATH,
            BROKER_INTERFACE,
            toStringz(methodName)
        );
        if (msg is null) {
            addLogEntry("Failed to create D-Bus method call for Intune broker method: " ~ methodName);
            return result;
        }

        string correlationId = randomUUID().toString();

        if (debugLogging) {
            addLogEntry(methodName ~ " request JSON: " ~ requestJson, ["debug"]);
        }

        DBusMessageIter* args = cast(DBusMessageIter*) malloc(DBUS_MESSAGE_ITER_SIZE);
        if (args is null) {
            dbus_message_unref(msg);
            addLogEntry("Failed to allocate D-Bus argument iterator for Intune broker method: " ~ methodName);
            return result;
        }

        if (!dbus_message_iter_init_append(msg, args)) {
            dbus_message_unref(msg);
            free(args);
            addLogEntry("Failed to initialise D-Bus argument iterator for Intune broker method: " ~ methodName);
            return result;
        }

        const(char)* protocol = toStringz(BROKER_PROTOCOL_VERSION);
        const(char)* corrId = toStringz(correlationId);
        const(char)* reqJson = toStringz(requestJson);

        dbus_message_iter_append_basic(args, DBUS_TYPE_STRING, &protocol);
        dbus_message_iter_append_basic(args, DBUS_TYPE_STRING, &corrId);
        dbus_message_iter_append_basic(args, DBUS_TYPE_STRING, &reqJson);
        free(args);

        DBusMessage* reply = dbus_connection_send_with_reply_and_block(conn, msg, timeoutMs, &err);
        dbus_message_unref(msg);

        if (dbus_error_is_set(&err) || reply is null) {
            addLogEntry("Broker method call failed: " ~ methodName);
            if (dbus_error_is_set(&err)) {
                dbus_error_free(&err);
            }
            return result;
        }

        DBusMessageIter* iter = cast(DBusMessageIter*) malloc(DBUS_MESSAGE_ITER_SIZE);
        if (iter is null) {
            dbus_message_unref(reply);
            addLogEntry("Failed to allocate D-Bus reply iterator for Intune broker method: " ~ methodName);
            return result;
        }

        if (!dbus_message_iter_init(reply, iter)) {
            dbus_message_unref(reply);
            free(iter);
            addLogEntry("Failed to initialise D-Bus reply iterator for Intune broker method: " ~ methodName);
            return result;
        }

        if (dbus_message_iter_get_arg_type(iter) != DBUS_TYPE_STRING) {
            dbus_message_unref(reply);
            free(iter);
            addLogEntry("Unexpected D-Bus reply argument type for Intune broker method: " ~ methodName);
            return result;
        }

        char* responseStr = null;
        dbus_message_iter_get_basic(iter, &responseStr);

        // Copy the returned string before unreferencing the reply message
        string jsonResponse;
        if (responseStr !is null) {
            jsonResponse = fromStringz(responseStr).idup;
        } else {
            jsonResponse = "";
        }

        dbus_message_unref(reply);
        free(iter);

        result.callSucceeded = true;
        result.rawResponse = jsonResponse;

        if (debugLogging) {
            addLogEntry(methodName ~ " raw response length: " ~ to!string(jsonResponse.length), ["debug"]);
            addLogEntry(methodName ~ " raw response: " ~ jsonResponse, ["debug"]);
        }

        JSONValue parsed;
        if (try_parse_json_response(jsonResponse, parsed)) {
            result.responseIsJson = true;
            result.parsedJson = parsed;
        }
    }

    return result;
}

string get_linux_broker_version(string clientId) {
    BrokerCallResult result = call_broker_method("getLinuxBrokerVersion", build_generic_client_request(clientId), 10000);

    if (!result.callSucceeded || !result.responseIsJson) {
        return "";
    }

    if (result.parsedJson.type != JSONType.object) {
        return "";
    }

    auto obj = result.parsedJson.object;
    if ("linuxBrokerVersion" in obj && obj["linuxBrokerVersion"].type == JSONType.string) {
        return obj["linuxBrokerVersion"].str;
    }

    return "";
}

string get_first_broker_account_json(string clientId) {
    BrokerCallResult result = call_broker_method("getAccounts", build_generic_client_request(clientId), 10000);

    if (!result.callSucceeded) {
        return "";
    }

    if (!result.responseIsJson) {
        addLogEntry("Broker getAccounts response was not valid JSON");
        return "";
    }

    if (result.parsedJson.type != JSONType.object) {
        return "";
    }

    auto obj = result.parsedJson.object;

    if ("error" in obj) {
        if (debugLogging) {
            addLogEntry("Broker getAccounts returned an error payload", ["debug"]);
        }
        return "";
    }

    if (!("accounts" in obj)) {
        return "";
    }

    if (obj["accounts"].type != JSONType.array) {
        return "";
    }

    auto accountsArray = obj["accounts"].array;
    if (accountsArray.length == 0) {
        return "";
    }

    return to!string(accountsArray[0]);
}

// Perform silent authentication via D-Bus using the Microsoft Identity Broker
AuthResult acquire_token_silently(string accountJson, string clientId) {
    AuthResult result;

    version (linux) {
        BrokerCallResult brokerResult = call_broker_method(
            "acquireTokenSilently",
            build_silent_auth_request(accountJson, clientId),
            10000
        );

        if (!brokerResult.callSucceeded) {
            return result;
        }

        if (!brokerResult.responseIsJson) {
            addLogEntry("Failed to parse silent Intune JSON response");
            return result;
        }

        if (brokerResult.parsedJson.type != JSONType.object) {
            return result;
        }

        auto obj = brokerResult.parsedJson.object;
        if (!("brokerTokenResponse" in obj)) {
            return result;
        }

        result.brokerTokenResponse = obj["brokerTokenResponse"];
    }

    return result;
}

// Initiate interactive authentication via D-Bus using the Microsoft Identity Broker
AuthResult acquire_token_interactive(string clientId) {
    AuthResult result;

    version (linux) {
        if (!wait_for_broker(10)) {
            addLogEntry("Timed out waiting for Identity Broker to appear on D-Bus");
            return result;
        }

        string brokerVersion = get_linux_broker_version(clientId);
        if (!brokerVersion.empty && debugLogging) {
            addLogEntry("Detected Microsoft Identity Broker version: " ~ brokerVersion, ["debug"]);
        }

        // First attempt to query broker-known accounts and use silent auth.
        string brokerAccountJson = get_first_broker_account_json(clientId);
        if (!brokerAccountJson.empty) {
            if (debugLogging) {
                addLogEntry("Broker returned at least one cached account; attempting silent auth first", ["debug"]);
                addLogEntry("Broker cached account JSON: " ~ brokerAccountJson, ["debug"]);
            }

            AuthResult silentResult = acquire_token_silently(brokerAccountJson, clientId);

            if (silentResult.brokerTokenResponse.type != JSONType.null_) {
                if (broker_token_response_has_error(silentResult.brokerTokenResponse)) {
                    addLogEntry("Silent Intune authentication failed; broker returned an error payload. Falling back to interactive Intune authentication");
                } else if (broker_token_response_has_required_auth_elements(silentResult.brokerTokenResponse)) {
                    if (debugLogging) {
                        addLogEntry("Silent Intune authentication succeeded with a usable broker token response", ["debug"]);
                    }
                    return silentResult;
                } else {
                    addLogEntry("Silent Intune authentication returned an incomplete broker token response. Falling back to interactive authentication");
                }
            } else {
                if (debugLogging) {
                    addLogEntry("Silent Intune authentication returned no broker token response. Falling back to interactive authentication", ["debug"]);
                }
            }
        } else {
            if (debugLogging) {
                addLogEntry("Broker did not return any cached account. Falling back to interactive authentication", ["debug"]);
            }
        }

        BrokerCallResult brokerResult = call_broker_method(
            "acquireTokenInteractively",
            build_interactive_auth_request(clientId),
            60000
        );

        if (!brokerResult.callSucceeded) {
            addLogEntry("Interactive call failed");
            return result;
        }

        if (!brokerResult.responseIsJson) {
            addLogEntry("Failed to parse interactive Intune JSON response");
            return result;
        }

        if (brokerResult.parsedJson.type != JSONType.object) {
            addLogEntry("Interactive Intune response was not a JSON object");
            return result;
        }

        auto obj = brokerResult.parsedJson.object;
        if ("brokerTokenResponse" in obj) {
            result.brokerTokenResponse = obj["brokerTokenResponse"];
        }
    }

    return result;
}