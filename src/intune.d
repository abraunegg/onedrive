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

bool check_intune_broker_available() {
	version (linux) {
		DBusError err;
		dbus_error_init(&err);
		DBusConnection* conn = dbus_bus_get(DBusBusType.DBUS_BUS_SESSION, &err);
		if (dbus_error_is_set(&err)) {
			dbus_error_free(&err);
			return false;
		}
		if (conn is null) return false;
		dbus_bool_t hasOwner = dbus_bus_name_has_owner(conn, "com.microsoft.identity.broker1", &err);
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
        if (check_intune_broker_available()) return true;
        Thread.sleep(dur!"seconds"(1));
        waited++;
    }
    return false;
}

string build_auth_request(string accountJson = "", string clientId = "") {
    string header = format(`{
  "authParameters": {
    "clientId": "%s",
    "redirectUri": "https://login.microsoftonline.com/common/oauth2/nativeclient",
    "authority": "https://login.microsoftonline.com/common",
    "requestedScopes": [
      "Files.ReadWrite",
      "Files.ReadWrite.All",
      "Sites.ReadWrite.All",
      "offline_access"
    ]`, clientId);

    string footer = `
  }
}`;

    if (!accountJson.empty)
        return header ~ `,"account": ` ~ accountJson ~ footer;
    else
        return header ~ footer;
}

struct AuthResult {
    JSONValue brokerTokenResponse;
}

// Initiate interactive authentication via D-Bus using the Microsoft Identity Broker
AuthResult acquire_token_interactive(string clientId) {
    AuthResult result;
	
	version (linux) {
		if (!wait_for_broker(10)) {
			addLogEntry("Timed out waiting for Identity Broker to appear on D-Bus");
			return result;
		}

		// Step 1: Call acquireTokenInteractively and capture account from result
		DBusError err;
		dbus_error_init(&err);
		DBusConnection* conn = dbus_bus_get(DBusBusType.DBUS_BUS_SESSION, &err);
		if (dbus_error_is_set(&err) || conn is null) return result;

		DBusMessage* msg = dbus_message_new_method_call(
			"com.microsoft.identity.broker1",
			"/com/microsoft/identity/broker1",
			"com.microsoft.identity.Broker1",
			"acquireTokenInteractively"
		);
		if (msg is null) return result;

		string correlationId = randomUUID().toString();
		string accountJson = "";
		string requestJson = build_auth_request(accountJson, clientId);

		DBusMessageIter* args = cast(DBusMessageIter*) malloc(DBUS_MESSAGE_ITER_SIZE);
		if (!dbus_message_iter_init_append(msg, args)) {
			dbus_message_unref(msg); free(args); return result;
		}

		const(char)* protocol = toStringz("0.0");
		const(char)* corrId = toStringz(correlationId);
		const(char)* reqJson = toStringz(requestJson);

		dbus_message_iter_append_basic(args, DBUS_TYPE_STRING, &protocol);
		dbus_message_iter_append_basic(args, DBUS_TYPE_STRING, &corrId);
		dbus_message_iter_append_basic(args, DBUS_TYPE_STRING, &reqJson);
		free(args);

		DBusMessage* reply = dbus_connection_send_with_reply_and_block(conn, msg, 60000, &err);
		dbus_message_unref(msg);

		if (dbus_error_is_set(&err) || reply is null) {
			addLogEntry("Interactive call failed");
			return result;
		}

		DBusMessageIter* iter = cast(DBusMessageIter*) malloc(DBUS_MESSAGE_ITER_SIZE);
		if (!dbus_message_iter_init(reply, iter)) {
			dbus_message_unref(reply); free(iter); return result;
		}

		char* responseStr;
		dbus_message_iter_get_basic(iter, &responseStr);
		dbus_message_unref(reply); free(iter);

		string jsonResponse = fromStringz(responseStr).idup;
		if (debugLogging) {addLogEntry("Interactive raw response: " ~ to!string(jsonResponse), ["debug"]);}
		
		JSONValue parsed = parseJSON(jsonResponse);
		if (parsed.type != JSONType.object) return result;
		
		auto obj = parsed.object;
		if ("brokerTokenResponse" in obj) {
			result.brokerTokenResponse = obj["brokerTokenResponse"];
		}
	}

    return result;
}

// Perform silent authentication via D-Bus using the Microsoft Identity Broker
AuthResult acquire_token_silently(string accountJson, string clientId) {
    AuthResult result;
	
	version (linux) {
		DBusError err;
		dbus_error_init(&err);
		DBusConnection* conn = dbus_bus_get(DBusBusType.DBUS_BUS_SESSION, &err);
		if (dbus_error_is_set(&err) || conn is null) return result;

		DBusMessage* msg = dbus_message_new_method_call(
			"com.microsoft.identity.broker1",
			"/com/microsoft/identity/broker1",
			"com.microsoft.identity.Broker1",
			"acquireTokenSilently"
		);
		if (msg is null) return result;
		
		string correlationId = randomUUID().toString();
		string requestJson = build_auth_request(accountJson, clientId);

		DBusMessageIter* args = cast(DBusMessageIter*) malloc(DBUS_MESSAGE_ITER_SIZE);
		if (!dbus_message_iter_init_append(msg, args)) {
			dbus_message_unref(msg);
			free(args);
			return result;
		}
		
		const(char)* protocol = toStringz("0.0");
		const(char)* corrId = toStringz(correlationId);
		const(char)* reqJson = toStringz(requestJson);

		dbus_message_iter_append_basic(args, DBUS_TYPE_STRING, &protocol);
		dbus_message_iter_append_basic(args, DBUS_TYPE_STRING, &corrId);
		dbus_message_iter_append_basic(args, DBUS_TYPE_STRING, &reqJson);
		free(args);
		
		DBusMessage* reply = dbus_connection_send_with_reply_and_block(conn, msg, 10000, &err);
		dbus_message_unref(msg);
		if (dbus_error_is_set(&err) || reply is null) return result;

		DBusMessageIter* iter = cast(DBusMessageIter*) malloc(DBUS_MESSAGE_ITER_SIZE);
		if (!dbus_message_iter_init(reply, iter)) {
			dbus_message_unref(reply);
			free(iter);
			return result;
		}
		
		char* responseStr;
		dbus_message_iter_get_basic(iter, &responseStr);
		dbus_message_unref(reply);
		free(iter);
		
		string jsonResponse = fromStringz(responseStr).idup;
		if (debugLogging) {addLogEntry("Silent raw response: " ~ to!string(jsonResponse), ["debug"]);}
		
		JSONValue parsed = parseJSON(jsonResponse);
		if (parsed.type != JSONType.object) return result;
		
		auto obj = parsed.object;
		if (!("brokerTokenResponse" in obj)) return result;
		
		result.brokerTokenResponse = obj["brokerTokenResponse"];
	}
	
    return result;
}
