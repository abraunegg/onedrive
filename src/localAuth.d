// What is this module called?
module localAuth;

// What does this module require to function?
import core.thread;
import std.algorithm : canFind, startsWith;
import std.array : split;
import std.concurrency;
import std.conv;
import std.datetime;
import std.exception;
import std.process : spawnProcess;
import std.socket;
import std.string;
import std.uri;

// What other modules that we have created do we need to import?
import config;
import log;

struct LocalAuthResponse {
	bool received = false;
	bool success = false;
	string responseUri = "";
	string code = "";
	string error = "";
	string errorDescription = "";
}

private struct LocalAuthServerResult {
	bool received = false;
	string responseUri = "";
	string code = "";
	string error = "";
	string errorDescription = "";
}

private enum string LOCAL_AUTH_HOST = "127.0.0.1";
private enum ushort LOCAL_AUTH_PORT_START = 53100;
private enum ushort LOCAL_AUTH_PORT_END = 53149;
private enum Duration LOCAL_AUTH_TIMEOUT = dur!"minutes"(10);

string buildLocalAuthRedirectUri(ushort port) {
	return "http://127.0.0.1:" ~ to!string(port) ~ "/";
}

bool shouldAttemptLocalBrowserAuth(ApplicationConfig appConfig) {
	// This is intentionally conservative. If any part of GUI detection fails,
	// the caller should fall back to the existing paste-the-redirect-URI flow.
	return appConfig.isGuiSessionDetected();
}

ushort findAvailableLocalAuthPort() {
	foreach (ushort port; LOCAL_AUTH_PORT_START .. LOCAL_AUTH_PORT_END + 1) {
		Socket listener;
		try {
			listener = new TcpSocket(AddressFamily.INET);
			listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
			listener.bind(new InternetAddress(LOCAL_AUTH_HOST, port));
			listener.close();
			return port;
		} catch (Exception e) {
			if (listener !is null) {
				try { listener.close(); } catch (Exception ignored) {}
			}
			continue;
		}
	}
	return 0;
}

bool openUrlInDefaultBrowser(string url) {
	try {
		auto p = spawnProcess(["xdg-open", url]);
		return true;
	} catch (Exception e) {
		addLogEntry("Unable to open the authorisation URL with xdg-open: " ~ e.msg, ["debug"]);
		return false;
	}
}

private string htmlEscape(string input) {
	return input
		.replace("&", "&amp;")
		.replace("<", "&lt;")
		.replace(">", "&gt;")
		.replace("\"", "&quot;")
		.replace("'", "&#39;");
}

private string buildBrowserResponse(LocalAuthServerResult result) {
	bool success = !result.code.empty && result.error.empty;
	string title = success ? "Authentication complete" : "Authentication failed";
	string message = success ?
		"Authentication is complete. You may close this browser window and return to the OneDrive Client for Linux." :
		"Authentication did not complete successfully. Please return to the OneDrive Client for Linux.";

	string body = "<!doctype html><html><head><meta charset=\"utf-8\"><title>" ~ title ~ "</title></head>" ~
		"<body><h1>" ~ title ~ "</h1><p>" ~ message ~ "</p>";
	if (!result.error.empty) {
		body ~= "<p><strong>Error:</strong> " ~ htmlEscape(result.error) ~ "</p>";
	}
	if (!result.errorDescription.empty) {
		body ~= "<p>" ~ htmlEscape(result.errorDescription) ~ "</p>";
	}
	body ~= "</body></html>";
	return body;
}

private string queryValue(string query, string key) {
	foreach (pair; query.split("&")) {
		if (pair.empty) {
			continue;
		}

		auto parts = pair.split("=");
		string pairKey = parts.length > 0 ? parts[0] : "";
		if (pairKey == key) {
			return parts.length > 1 ? parts[1] : "";
		}
	}
	return "";
}

private void parseHttpRequestTarget(string requestTarget, ushort port, ref LocalAuthServerResult result) {
	string pathAndQuery = requestTarget;
	if (pathAndQuery.startsWith("http://127.0.0.1")) {
		auto marker = ":" ~ to!string(port);
		auto markerIndex = pathAndQuery.indexOf(marker);
		if (markerIndex >= 0) {
			pathAndQuery = pathAndQuery[markerIndex + marker.length .. $];
		}
	}

	result.responseUri = "http://127.0.0.1:" ~ to!string(port) ~ pathAndQuery;

	auto queryIndex = pathAndQuery.indexOf("?");
	if (queryIndex < 0) {
		return;
	}

	string query = pathAndQuery[queryIndex + 1 .. $];
	result.code = queryValue(query, "code");
	result.error = queryValue(query, "error");
	result.errorDescription = queryValue(query, "error_description");
}

private void sendHttpResponse(Socket client, LocalAuthServerResult result) {
	string body = buildBrowserResponse(result);
	string response = "HTTP/1.1 200 OK\r\n" ~
		"Content-Type: text/html; charset=utf-8\r\n" ~
		"Content-Length: " ~ to!string(body.length) ~ "\r\n" ~
		"Connection: close\r\n\r\n" ~ body;
	client.send(cast(const(ubyte)[]) response);
}

private void closeSocketNoThrow(Socket socket) {
	if (socket is null) {
		return;
	}
	try {
		socket.close();
	} catch (Exception ignored) {
		// Ignore cleanup failures.
	}
}

private void localAuthServeOnce(Tid parentTid, ushort port) {
	LocalAuthServerResult result;
	Socket listener;
	Socket client;

	scope(exit) closeSocketNoThrow(client);
	scope(exit) closeSocketNoThrow(listener);

	try {
		listener = new TcpSocket(AddressFamily.INET);
		listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
		listener.bind(new InternetAddress(LOCAL_AUTH_HOST, port));
		listener.listen(1);

		client = listener.accept();
		ubyte[8192] buffer;
		auto received = client.receive(buffer[]);
		if (received > 0) {
			string request = cast(string) buffer[0 .. received];
			auto requestLineEnd = request.indexOf("\r\n");
			string requestLine = requestLineEnd >= 0 ? request[0 .. requestLineEnd] : request;
			auto requestParts = requestLine.split(" ");
			if (requestParts.length >= 2 && requestParts[0] == "GET") {
				result.received = true;
				parseHttpRequestTarget(requestParts[1], port, result);
			} else {
				result.received = true;
				result.error = "local_auth_invalid_request";
				result.errorDescription = "The local authentication listener received an invalid HTTP request.";
			}
		} else {
			result.received = true;
			result.error = "local_auth_empty_request";
			result.errorDescription = "The local authentication listener received an empty HTTP request.";
		}

		sendHttpResponse(client, result);
	} catch (Exception e) {
		result.received = true;
		result.error = "local_auth_listener_error";
		result.errorDescription = e.msg;
	}

	send(parentTid, result);
}

LocalAuthResponse performLocalBrowserAuth(string authorisationUrl, ushort port) {
	LocalAuthResponse response;
	Tid ownerTid = thisTid;
	spawn(&localAuthServeOnce, ownerTid, port);

	// Give the listener a very small window to bind before launching the browser.
	Thread.sleep(dur!"msecs"(200));

	if (!openUrlInDefaultBrowser(authorisationUrl)) {
		response.error = "browser_open_failed";
		return response;
	}

	bool gotMessage = receiveTimeout(LOCAL_AUTH_TIMEOUT,
		(LocalAuthServerResult serverResult) {
			response.received = serverResult.received;
			response.responseUri = serverResult.responseUri;
			response.code = decodeComponent(serverResult.code);
			response.error = decodeComponent(serverResult.error);
			response.errorDescription = decodeComponent(serverResult.errorDescription);
			response.success = response.received && !response.code.empty && response.error.empty;
		}
	);

	if (!gotMessage) {
		response.error = "local_auth_timeout";
	}
	return response;
}
