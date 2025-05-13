// What is this module called?
module intune;

// What does this module require to function?
import core.stdc.string : strcmp;
import core.stdc.stdlib : malloc, free;
import std.string : fromStringz, toStringz;
import std.conv : to;
import std.json : JSONValue, parseJSON, JSONType;
import std.uuid : randomUUID;

// What 'onedrive' modules do we import?
import log;

extern(C):
alias dbus_bool_t = int;

struct DBusError {
    char* name;
    char* message;
    uint dummy1, dummy2, dummy3, dummy4, dummy5, dummy6, dummy7, dummy8;
    void* padding1;
}

struct DBusConnection;
struct DBusMessage;
struct DBusMessageIter;

enum DBusBusType {
    DBUS_BUS_SESSION = 0,
    DBUS_BUS_SYSTEM = 1,
    DBUS_BUS_STARTER = 2
}

void dbus_error_init(DBusError* error);
void dbus_error_free(DBusError* error);
int dbus_error_is_set(DBusError* error);

DBusConnection* dbus_bus_get(DBusBusType type, DBusError* error);
dbus_bool_t dbus_bus_name_has_owner(DBusConnection* conn, const char* name, DBusError* error);

DBusMessage* dbus_message_new_method_call(
    const char* destination,
    const char* path,
    const char* iface,
    const char* method
);

DBusMessage* dbus_connection_send_with_reply_and_block(
    DBusConnection* conn,
    DBusMessage* msg,
    int timeout_milliseconds,
    DBusError* error
);

dbus_bool_t dbus_message_iter_init_append(DBusMessage* msg, DBusMessageIter* iter);
dbus_bool_t dbus_message_iter_append_basic(DBusMessageIter* iter, int type, const void* value);

void dbus_message_unref(DBusMessage* msg);
dbus_bool_t dbus_message_iter_init(DBusMessage* msg, DBusMessageIter* iter);
dbus_bool_t dbus_message_iter_get_arg_type(DBusMessageIter* iter);
void dbus_message_iter_recurse(DBusMessageIter* iter, DBusMessageIter* sub);
void dbus_message_iter_next(DBusMessageIter* iter);
void dbus_message_iter_get_basic(DBusMessageIter* iter, void* value);

enum DBUS_TYPE_STRING = 115;
enum DBUS_MESSAGE_ITER_SIZE = 128;

// Check if the Microsoft Identity Broker D-Bus service is available on the session bus
bool check_intune_broker_available() {
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

    if (hasOwner) return true;

    DBusMessage* msg = dbus_message_new_method_call(
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        "ListActivatableNames"
    );
    if (msg is null) return false;

    DBusMessage* reply = dbus_connection_send_with_reply_and_block(conn, msg, -1, &err);
    dbus_message_unref(msg);

    if (dbus_error_is_set(&err) || reply is null) {
        dbus_error_free(&err);
        return false;
    }

    DBusMessageIter* iter = cast(DBusMessageIter*) malloc(DBUS_MESSAGE_ITER_SIZE);
    DBusMessageIter* arrayIter = cast(DBusMessageIter*) malloc(DBUS_MESSAGE_ITER_SIZE);

    if (!dbus_message_iter_init(reply, iter)) {
        dbus_message_unref(reply);
        free(iter);
        free(arrayIter);
        return false;
    }

    dbus_message_iter_recurse(iter, arrayIter);

    while (dbus_message_iter_get_arg_type(arrayIter)) {
        char* name;
        dbus_message_iter_get_basic(arrayIter, &name);

        if (strcmp(name, "com.microsoft.identity.broker1") == 0) {
            dbus_message_unref(reply);
            free(iter);
            free(arrayIter);
            return true;
        }

        dbus_message_iter_next(arrayIter);
    }

    dbus_message_unref(reply);
    free(iter);
    free(arrayIter);
    return false;
}

// Initiate interactive authentication via D-Bus using the Microsoft Identity Broker
string acquire_token_interactive() {
    DBusError err;
    dbus_error_init(&err);

    addLogEntry("Starting interactive authentication...");

    DBusConnection* conn = dbus_bus_get(DBusBusType.DBUS_BUS_SESSION, &err);
    if (dbus_error_is_set(&err) || conn is null) {
        dbus_error_free(&err);
        return "";
    }
	
	DBusMessage* msg = dbus_message_new_method_call(
        "com.microsoft.identity.broker1",
        "/com/microsoft/identity/broker1",
        "com.microsoft.identity.Broker1",
        "acquireTokenInteractively"
    );

	if (msg is null) return "";

    string correlationId = randomUUID().toString();

    string requestJson = `{
	  "authParameters": {
		"clientId": "d50ca740-c83f-4d1b-b616-12c519384f0c",
		"redirectUri": "urn:ietf:oob",
		"authority": "https://login.microsoftonline.com/common",
		"requestedScopes": [
		  "Files.ReadWrite",
		  "Files.ReadWrite.All",
		  "Sites.ReadWrite.All",
		  "offline_access"
		]
	  }
	}`;

	DBusMessageIter* args = cast(DBusMessageIter*) malloc(DBUS_MESSAGE_ITER_SIZE);
    if (!dbus_message_iter_init_append(msg, args)) {
        dbus_message_unref(msg);
        free(args);
        return "";
    }

    const(char)* protocol = toStringz("0.0");
    const(char)* corrId = toStringz(correlationId);
    const(char)* reqJson = toStringz(requestJson);
	
	if (!dbus_message_iter_append_basic(args, DBUS_TYPE_STRING, &protocol) ||
        !dbus_message_iter_append_basic(args, DBUS_TYPE_STRING, &corrId) ||
        !dbus_message_iter_append_basic(args, DBUS_TYPE_STRING, &reqJson)) {
        dbus_message_unref(msg);
        free(args);
        return "";
    }

	free(args);

    DBusMessage* reply = dbus_connection_send_with_reply_and_block(conn, msg, -1, &err);
    dbus_message_unref(msg);
	
	if (dbus_error_is_set(&err) || reply is null) {
        dbus_error_free(&err);
        return "";
    }
	
	DBusMessageIter* iter = cast(DBusMessageIter*) malloc(DBUS_MESSAGE_ITER_SIZE);
    if (!dbus_message_iter_init(reply, iter)) {
        dbus_message_unref(reply);
        free(iter);
        return "";
    }
	
	if (dbus_message_iter_get_arg_type(iter) != DBUS_TYPE_STRING) {
        dbus_message_unref(reply);
        free(iter);
        return "";
    }
	
	char* responseStr;
    dbus_message_iter_get_basic(iter, &responseStr);
    dbus_message_unref(reply);
    free(iter);
	
	string jsonResponse = fromStringz(responseStr).idup;
	
	addLogEntry("intune raw response: " ~ jsonResponse);

    JSONValue parsed = parseJSON(jsonResponse);
    if (parsed.type != JSONType.object) return "";

    auto obj = parsed.object;
    if (!("access_token" in obj)) return "";

    return obj["access_token"].str;
}
