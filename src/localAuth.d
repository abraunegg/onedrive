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
import std.process : environment, spawnProcess, Config;
import std.stdio : File;
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
	bool browserResponsePending = false;
	string responseUri = "";
	string code = "";
	string error = "";
	string errorDescription = "";
}

private struct LocalAuthCompletionResult {
	bool success = false;
}

private struct LocalAuthBrowserResponseResult {
	bool sent = false;
}

private enum string LOCAL_AUTH_HOST = "127.0.0.1";
private enum ushort LOCAL_AUTH_PORT_START = 53100;
private enum ushort LOCAL_AUTH_PORT_END = 53149;
private enum Duration LOCAL_AUTH_TIMEOUT = dur!"minutes"(10);
private enum string SPONSORSHIP_URL = "https://github.com/sponsors/abraunegg?metadata_campaign=onedrive-sponsorship&metadata_source=client&metadata_content=initial-auth";

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
	string browser = environment.get("BROWSER", "").strip;
	if (!browser.empty) {
		try {
			auto devNullIn = File("/dev/null", "r");
			auto devNullOut = File("/dev/null", "w");
			auto devNullErr = File("/dev/null", "w");

			spawnProcess(
				[browser, url],
				devNullIn,
				devNullOut,
				devNullErr,
				null,
				Config.detached
			);

			return true;
		} catch (Exception e) {
			addLogEntry("Unable to open the authorisation URL with the browser configured by BROWSER ('" ~ browser ~ "'): " ~ e.msg ~ ". Falling back to xdg-open.", ["debug"]);
		}
	}

	try {
		auto devNullIn = File("/dev/null", "r");
		auto devNullOut = File("/dev/null", "w");
		auto devNullErr = File("/dev/null", "w");

		spawnProcess(
			["xdg-open", url],
			devNullIn,
			devNullOut,
			devNullErr,
			null,
			Config.detached
		);

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

private string buildBrowserResponse(LocalAuthServerResult result, bool authenticationSucceeded, bool displaySponsorship) {
	string title = authenticationSucceeded ? "Authentication complete" : "Authentication failed";
	string message;
	if (authenticationSucceeded) {
		message = "The OneDrive Client for Linux has been successfully authorised. You may close this browser window and return to the application.";
	} else if (!result.error.empty) {
		message = "Microsoft did not return a successful authorisation response. Please return to the OneDrive Client for Linux.";
	} else {
		message = "The OneDrive Client for Linux was unable to complete authentication with Microsoft. Please return to the application for additional information.";
	}

	string statusClass = authenticationSucceeded ? "success" : "failure";
	string statusLabel = authenticationSucceeded ? "Authorisation successful" : "Authorisation unsuccessful";

	string body = "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">" ~
		"<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">" ~
		"<meta name=\"referrer\" content=\"no-referrer\">" ~
		"<title>" ~ title ~ " - OneDrive Client for Linux</title>" ~
		"<style>" ~
		":root{color-scheme:light dark;font-family:system-ui,-apple-system,BlinkMacSystemFont,\"Segoe UI\",sans-serif;}" ~
		"*{box-sizing:border-box;}" ~
		"body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;padding:32px;background:#f6f8fa;color:#1f2328;}" ~
		"main{width:min(680px,100%);background:#fff;border:1px solid #d0d7de;border-radius:12px;padding:36px;box-shadow:0 8px 28px rgba(140,149,159,.18);}" ~
		".project{margin:0 0 18px;font-size:24px;line-height:1.25;font-weight:700;color:inherit;}" ~
		".status{display:inline-block;margin:0 0 12px;padding:5px 10px;border-radius:999px;font-size:13px;font-weight:600;}" ~
		".status.success{background:#dafbe1;color:#116329;}" ~
		".status.failure{background:#ffebe9;color:#cf222e;}" ~
		".auth-heading{margin:0 0 10px;font-size:22px;line-height:1.3;font-weight:650;}" ~
		"p{line-height:1.6;}" ~
		".message{margin:0;color:#424a53;}" ~
		".error{margin-top:20px;padding:14px 16px;border:1px solid #d0d7de;border-radius:8px;background:#f6f8fa;}" ~
		".error p{margin:0;}" ~
		".error p+p{margin-top:8px;}" ~
		".support{margin-top:28px;padding-top:26px;border-top:1px solid #d8dee4;}" ~
		".support h2{margin:0 0 10px;font-size:20px;}" ~
		".support p{margin:0 0 18px;color:#424a53;}" ~
		".support a{display:inline-block;padding:10px 16px;border-radius:7px;background:#0969da;color:#fff;text-decoration:none;font-weight:600;}" ~
		".support a:hover{background:#0860ca;}" ~
		".support a:focus-visible{outline:3px solid #54aeff;outline-offset:2px;}" ~
		".support .optional{margin:12px 0 0;font-size:13px;color:#656d76;}" ~
		"@media (prefers-color-scheme:dark){" ~
		"body{background:#0d1117;color:#e6edf3;}main{background:#161b22;border-color:#30363d;box-shadow:none;}" ~
		".message,.support p,.support .optional{color:#8b949e;}" ~
		".status.success{background:#12261e;color:#7ee787;}.status.failure{background:#321c1c;color:#ff7b72;}" ~
		".error{background:#0d1117;border-color:#30363d;}.support{border-color:#30363d;}" ~
		"}" ~
		"</style></head><body><main>" ~
		"<h1 class=\"project\">OneDrive Client for Linux</h1>" ~
		"<div class=\"status " ~ statusClass ~ "\">" ~ statusLabel ~ "</div>" ~
		"<h2 class=\"auth-heading\">" ~ title ~ "</h2><p class=\"message\">" ~ message ~ "</p>";

	if (!result.error.empty || !result.errorDescription.empty) {
		body ~= "<div class=\"error\">";
		if (!result.error.empty) {
			body ~= "<p><strong>Error:</strong> " ~ htmlEscape(result.error) ~ "</p>";
		}
		if (!result.errorDescription.empty) {
			body ~= "<p>" ~ htmlEscape(result.errorDescription) ~ "</p>";
		}
		body ~= "</div>";
	}

	if (authenticationSucceeded && displaySponsorship) {
		body ~= "<section class=\"support\" aria-labelledby=\"support-heading\">" ~
			"<h2 id=\"support-heading\">Help sustain OneDrive Client for Linux</h2>" ~
			"<p>OneDrive Client for Linux is free, open-source software that is independently developed and maintained. " ~
			"If it is useful to you or your organisation, you can help sustain ongoing development, testing and maintenance through GitHub Sponsors.</p>" ~
			"<a href=\"" ~ htmlEscape(SPONSORSHIP_URL) ~ "\" target=\"_blank\" rel=\"noopener noreferrer\">Sponsor on GitHub</a>" ~
			"<p class=\"optional\">Sponsorship is entirely optional.</p>" ~
			"</section>";
	}

	body ~= "</main></body></html>";
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

private void sendHttpResponse(Socket client, LocalAuthServerResult result, bool authenticationSucceeded, bool displaySponsorship) {
	string body = buildBrowserResponse(result, authenticationSucceeded, displaySponsorship);
	string response = "HTTP/1.1 200 OK\r\n" ~
		"Content-Type: text/html; charset=utf-8\r\n" ~
		"Content-Length: " ~ to!string(body.length) ~ "\r\n" ~
		"Cache-Control: no-store\r\n" ~
		"Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'\r\n" ~
		"Referrer-Policy: no-referrer\r\n" ~
		"X-Content-Type-Options: nosniff\r\n" ~
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

private void localAuthServeOnce(Tid parentTid, ushort port, bool displaySponsorship) {
	LocalAuthServerResult result;
	Socket listener;
	Socket client;
	bool resultSent = false;

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

		// Keep the browser connection open until the normal OneDrive authentication flow
		// confirms whether token redemption and credential persistence actually succeeded.
		result.browserResponsePending = true;
		send(parentTid, result);
		resultSent = true;

		LocalAuthCompletionResult completionResult;
		receive(
			(LocalAuthCompletionResult finalResult) {
				completionResult = finalResult;
			}
		);

		sendHttpResponse(client, result, completionResult.success, displaySponsorship);
		send(parentTid, LocalAuthBrowserResponseResult(true));
	} catch (Exception e) {
		if (!resultSent) {
			result.received = true;
			result.error = "local_auth_listener_error";
			result.errorDescription = e.msg;
			send(parentTid, result);
		} else {
			send(parentTid, LocalAuthBrowserResponseResult(false));
		}
	}
}

LocalAuthResponse performLocalBrowserAuth(string authorisationUrl, ushort port, bool displaySponsorship, bool delegate(string) completeAuthentication) {
	LocalAuthResponse response;
	Tid ownerTid = thisTid;
	Tid serverTid = spawn(&localAuthServeOnce, ownerTid, port, displaySponsorship);
	bool browserResponsePending = false;

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
			browserResponsePending = serverResult.browserResponsePending;
		}
	);

	if (!gotMessage) {
		response.error = "local_auth_timeout";
		return response;
	}

	bool callbackSucceeded = response.received && !response.code.empty && response.error.empty;
	if (callbackSucceeded) {
		try {
			response.success = completeAuthentication(response.code);
		} catch (Exception e) {
			addLogEntry("Local browser authentication could not be completed: " ~ e.msg);
			response.success = false;
		}
	}

	if (browserResponsePending) {
		send(serverTid, LocalAuthCompletionResult(response.success));

		receive(
			(LocalAuthBrowserResponseResult browserResult) {
				if (!browserResult.sent) {
					addLogEntry("Unable to send the final authentication result to the browser.", ["debug"]);
				}
			}
		);
	}

	return response;
}
