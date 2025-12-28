// What is this module called?
module socketio;

// What does this module require to function?
import core.atomic     : atomicLoad, atomicStore;
import core.thread     : Thread;
import core.time       : Duration, dur;
import std.concurrency : spawn, Tid, thisTid, send, receiveTimeout;
import std.conv        : to;
import std.datetime    : SysTime, Clock, UTC;
import std.exception   : collectException;
import std.json        : JSONValue, JSONType, parseJSON;
import std.net.curl    : CurlException;
import std.socket      : SocketException;
import std.string      : indexOf;

// What other modules that we have created do we need to import?
import log;
import util;
import config;
import curlWebsockets;

// ========== Logging Shim ==========
private void logSocketIOOutput(string s) {
	if (debugLogging) {
		addLogEntry("SOCKETIO: " ~ s, ["debug"]);
	}
}

final class OneDriveSocketIo {
	private Tid parentTid;
	private ApplicationConfig appConfig;
	private bool started = false;
	private Duration renewEarly = dur!"seconds"(120);
	private string engineSid;
	private bool expiryWarned = false;
	private bool renewRequested = false;
	private string currentNotifUrl;

	// Worker / state
	private Tid controllerTid; // main/control thread to notify when the worker exits
	private Tid workerTid;
	private shared bool pleaseStop = false;
	private long  pingIntervalMs = 25000;
	private long  pingTimeoutMs  = 60000;
	private bool  namespaceOpened = false;
	private CurlWebSocket ws;
	private shared bool workerExited = false; // set true by run() on clean exit

public:
	this(Tid parentTid, ApplicationConfig appConfig) {
		this.parentTid = parentTid;
		this.appConfig = appConfig;
	}
	
	~this() {
		logSocketIOOutput("Signalling to stop a OneDriveSocketIo instance");
		stop(); // sets pleaseStop + waits for workerExited

		if (atomicLoad(workerExited)) {
			if (ws !is null) {
				logSocketIOOutput("Attempting to destroy libcurl RFC6455 WebSocket client cleanly");
				// Worker has exited; safe to close/cleanup/destroy
				collectException(ws.close(1000, "client stop"));
				object.destroy(ws);
				ws = null;
				logSocketIOOutput("Destroyed libcurl RFC6455 WebSocket client cleanly");
			}
		} else {
			// Worker still running; DO NOT touch ws/curl from this thread.
			logSocketIOOutput("Worker still running; skipping ws destruction to avoid race.");
		}
	}
	
	void start() {
		if (started) return;
		// Get current WebSocket Notification URL
		currentNotifUrl = appConfig.websocketNotificationUrl;
		
		// Reset cooperative flags
		pleaseStop = false;
		atomicStore(workerExited, false);
		
		// Set Flag
		started = true;
		
		// Spawn worker thread
		workerTid = spawn(&run, cast(shared) this);
	}

	void stop() {
		if (!started) return;

		// Ask the worker to stop cooperatively
		pleaseStop = true;
		logSocketIOOutput("Flagged to stop WebSocket monitoring of Microsoft Graph API changes.");
		// Wait up to ~6 seconds for the worker to finish cleanup.
		// No mailbox usage here to avoid nested receiveTimeout on FreeBSD.
		enum int totalWaitMs = 6000;
		enum int stepMs = 100;
		int waited = 0;
		
		while (!atomicLoad(workerExited) && waited < totalWaitMs) {
			Thread.sleep(dur!"msecs"(stepMs));
			waited += stepMs;
		}
		
		// Mark not started only after we know we've requested stop
		started = false;

		if (!atomicLoad(workerExited)) {
			// We asked nicely but didn’t get an ack within the window; continue shutdown anyway.
			// Keeps behaviour safe; avoids hanging the main shutdown path
			logSocketIOOutput("Worker stop acknowledgement not received within timeout; continuing shutdown.");
		}
	}

	Duration getNextExpirationCheckDuration() {
		if (appConfig.websocketUrlExpiry.length == 0)
			return dur!"seconds"(5);

		SysTime expiry;
		auto err = collectException(expiry = SysTime.fromISOExtString(appConfig.websocketUrlExpiry));
		if (err !is null)
			return dur!"seconds"(5);

		auto now = Clock.currTime(UTC());
		if (expiry <= now) return dur!"seconds"(5);

		auto delta = expiry - now;
		if (delta > renewEarly) delta -= renewEarly;
		return (delta > Duration.zero) ? delta : dur!"seconds"(5);
	}

private:
	// Main function that listens and sends events
	static void run(shared OneDriveSocketIo _this) {
		logSocketIOOutput("run() entered");

		auto self = cast(OneDriveSocketIo) _this;

		// Capped exponential backoff: 1s, 2s, 4s, ... up to 60s
		int backoffSeconds = 1;
		const int maxBackoffSeconds = 60;
		bool online;
		
		scope(exit) {
			// Signal that the worker is fully done (visible across threads)
			atomicStore(self.workerExited, true);
			
			// Log that we are exiting the run() function
			logSocketIOOutput("run() exiting");
		}

		while (!self.pleaseStop) {
			// Catch network exceptions at the socketio-loop level and treat them as recoverable
			try {
				// If we're offline (or OneDrive service not reachable), don't bother trying yet
				logSocketIOOutput("Testing network to ensure network connectivity to Microsoft OneDrive Service");
				online = testInternetReachability(self.appConfig, false); // Will display failures, but nothing if successful .. a quiet check of sorts.
				if (!online) {
					logSocketIOOutput("Network or OneDrive service not reachable; delaying reconnect");
					logSocketIOOutput("Backoff " ~ to!string(backoffSeconds) ~ "s before retry");
					Thread.sleep(dur!"seconds"(backoffSeconds));
					if (backoffSeconds < maxBackoffSeconds) backoffSeconds *= 2;
					continue;
				} else {
					// We are 'online'
					// Build Socket.IO WS URL from notificationUrl
					string notif = self.appConfig.websocketNotificationUrl;
					if (notif.length == 0) {
						logSocketIOOutput("No notificationUrl available; will retry");
						logSocketIOOutput("Backoff " ~ to!string(backoffSeconds) ~ "s before retry");
						Thread.sleep(dur!"seconds"(backoffSeconds));
						if (backoffSeconds < maxBackoffSeconds) backoffSeconds *= 2;
						continue;
					}

					self.currentNotifUrl = notif;
					string wsUrl = toSocketIoWsUrl(notif);

					// Fresh WS instance per attempt
					self.ws = new CurlWebSocket();

					// Use application configuration values
					self.ws.setUserAgent(self.appConfig.getValueString("user_agent"));
					self.ws.setHTTPSDebug(self.appConfig.getValueBool("debug_https"));
					self.ws.setTimeouts(10000, 15000);

					// Connect to Microsoft Graph API using WebSockets and Socket.IO v4
					logSocketIOOutput("Connecting to " ~ wsUrl);
					auto rc = self.ws.connect(wsUrl);
					if (rc != 0) {
						logSocketIOOutput("self.ws.connect failed; will retry");
						collectException(self.ws.close(1002, "connect-failed"));
						Thread.sleep(dur!"seconds"(backoffSeconds));
						if (backoffSeconds < maxBackoffSeconds) backoffSeconds *= 2;
						continue;
					}

					// Socket.IO handshake: wait for '0{json}'
					if (!awaitEngineOpen(self.ws, self)) {
						logSocketIOOutput("Socket.IO open handshake failed; will retry");
						collectException(self.ws.close(1002, "handshake-failed"));
						Thread.sleep(dur!"seconds"(backoffSeconds));
						if (backoffSeconds < maxBackoffSeconds) backoffSeconds *= 2;
						continue;
					}

					// Open default namespace: send "40"
					logSocketIOOutput("Sending Socket.IO connect (40) to default namespace");
					if (self.ws.sendText("40") != 0) {
						logSocketIOOutput("Failed to send 40 (open namespace); will retry");
						collectException(self.ws.close(1002, "ns40-failed"));
						Thread.sleep(dur!"seconds"(backoffSeconds));
						if (backoffSeconds < maxBackoffSeconds) backoffSeconds *= 2;
						continue;
					} else {
						logSocketIOOutput("Sent Socket.IO connect '40' for namespace '/'");
					}

					// Open 'notifications' namespace: send "40/notifications"
					logSocketIOOutput("Sending Socket.IO connect (40) to '/notifications' namespace");
					if (self.ws.sendText("40/notifications") != 0) {
						logSocketIOOutput("Failed to send 40 for '/notifications' namespace; will retry");
						collectException(self.ws.close(1002, "ns40-failed"));
						Thread.sleep(dur!"seconds"(backoffSeconds));
						if (backoffSeconds < maxBackoffSeconds) backoffSeconds *= 2;
						continue;
					} else {
						logSocketIOOutput("Sent Socket.IO connect '40' for namespace '/notifications'");
					}

					// Connected successfully → reset backoff
					backoffSeconds = 1;
					// Reset per-connection flags so renew logic and ns-open tracking work after reconnection
					self.expiryWarned   = false;
					self.renewRequested = false;
					self.namespaceOpened = false;

					// Track last server ping received to detect a dead connection
					SysTime lastPingAt = Clock.currTime(UTC());

					// Listen for Socket.IO Events
					for (;;) {
						// Stop request
						if (self.pleaseStop) {
							logSocketIOOutput("Stop requested; shutting down run() loop");
							collectException(self.ws.close(1000, "stop-requested"));
							collectException(self.ws.cleanupCurlHandle());
							return;
						}

						// Subscription nearing expiry? (informational; renewal happens elsewhere)
						if (!self.expiryWarned && self.appConfig.websocketUrlExpiry.length > 0) {
							SysTime expiry;
							auto e = collectException(expiry = SysTime.fromISOExtString(self.appConfig.websocketUrlExpiry));
							if (e is null) {
								auto remain = expiry - Clock.currTime(UTC());
								if (remain <= dur!"minutes"(5)) {
									self.expiryWarned = true; // emit only once
									logSocketIOOutput("subscription nearing expiry; renewal required soon");
								}
							}
						}

						// Renewal window check (emit once; 2 minutes before)
						if (!self.renewRequested && self.appConfig.websocketUrlExpiry.length > 0) {
							SysTime expiry;
							auto e = collectException(expiry = SysTime.fromISOExtString(self.appConfig.websocketUrlExpiry));
							if (e is null) {
								auto remain = expiry - Clock.currTime(UTC());
								if (remain <= dur!"minutes"(2)) {
									self.renewRequested = true;
									logSocketIOOutput("Subscription nearing expiry; requesting renewal from main() monitor loop");
									send(self.parentTid, "SOCKETIO_RENEWAL_REQUEST");
									send(self.parentTid, "SOCKETIO_RENEWAL_CONTEXT:" ~ "id=" ~ self.appConfig.websocketEndpointResponse ~ " url=" ~ self.appConfig.websocketNotificationUrl);
								}
							}
						}

						// If we haven't seen a server ping within pingInterval + pingTimeout → treat as dead link
						auto now = Clock.currTime(UTC());
						auto maxSilence = dur!"msecs"(self.pingIntervalMs + self.pingTimeoutMs);
						if (now - lastPingAt > maxSilence) {
							logSocketIOOutput("No server ping within expected window; restarting WebSocket");
							break; // fall out to backoff/retry
						}

						// Reconnect to a new endpoint if main updated websocketNotificationUrl
						if (self.appConfig.websocketNotificationUrl.length > 0 &&
							self.appConfig.websocketNotificationUrl != self.currentNotifUrl) {

							logSocketIOOutput("Detected new notificationUrl; reconnecting");
							collectException(self.ws.close(1000, "reconnect"));

							self.currentNotifUrl = self.appConfig.websocketNotificationUrl;
							string newWsUrl = toSocketIoWsUrl(self.currentNotifUrl);

							// Establish a fresh connection and handshakes
							self.ws = new CurlWebSocket();
							self.ws.setUserAgent(self.appConfig.getValueString("user_agent"));
							self.ws.setTimeouts(10000, 15000);
							self.ws.setHTTPSDebug(self.appConfig.getValueBool("debug_https"));

							auto rc2 = self.ws.connect(newWsUrl);
							if (rc2 != 0) {
								logSocketIOOutput("reconnect failed");
								break; // fall out to backoff/retry
							}
							if (!awaitEngineOpen(self.ws, self)) {
								logSocketIOOutput("Socket.IO open after reconnect failed");
								break; // fall out to backoff/retry
							}

							// Open default namespace again
							logSocketIOOutput("Sending Socket.IO connect (40) to default namespace");
							if (self.ws.sendText("40") != 0) {
								logSocketIOOutput("Failed to send 40 (open namespace)");
								break; // fall out to backoff/retry
							} else {
								logSocketIOOutput("Sent Socket.IO connect '40' for namespace '/'");
							}

							// Open '/notifications' again (best-effort)
							logSocketIOOutput("Sending Socket.IO connect (40) to '/notifications' namespace");
							if (self.ws.sendText("40/notifications") != 0) {
								logSocketIOOutput("Failed to send 40 for '/notifications' namespace");
								break; // fall out to backoff/retry
							} else {
								logSocketIOOutput("Sent Socket.IO connect '40' for namespace '/notifications'");
							}

							// Reset ping reference after a clean reconnect
							lastPingAt = Clock.currTime(UTC());
						}

						// Receive message
						auto msg = self.ws.recvText();
						if (msg.length == 0) {
							Thread.sleep(dur!"msecs"(20));
							continue;
						}

						// Socket.IO parsing
						if (msg.length > 0 && msg[0] == '2') {
							// Server ping -> immediate pong, and mark last ping time
							if (self.ws.sendText("3") != 0) {
								logSocketIOOutput("Failed sending Socket.IO pong '3'");
								break; // fall out to backoff/retry
							} else {
								lastPingAt = Clock.currTime(UTC());
								logSocketIOOutput("Socket.IO ping received, → pong sent");
							}
							continue;
						}

						if (msg.length > 0 && msg[0] == '3') {
							continue;
						} else if (msg.length > 1 && msg[0] == '4' && msg[1] == '2') {
							logSocketIOOutput("Received 42 msg = " ~ to!string(msg));
							handleSocketIoEvent(msg, self);
							continue;
						} else if (msg.length > 1 && msg[0] == '4' && msg[1] == '0') {
							logSocketIOOutput("Received 40 msg = " ~ to!string(msg));
							// 40{"sid":...} or 40/notifications,{...}
							size_t i = 3;
							while (i < msg.length && msg[i] != ',') i++;
							auto ns = msg[3 .. i];

							if (ns == "notifications") {
								logSocketIOOutput("Namespace '/notifications' opened; listening for Socket.IO events via WebSocket Transport");
							} else {
								logSocketIOOutput("Namespace '/' opened; listening for Socket.IO events via WebSocket Transport");
							}
							self.namespaceOpened = true;
							continue;

						} else if (msg.length > 1 && msg[0] == '4' && msg[1] == '1') {
							logSocketIOOutput("got 41 (disconnect)");
							break; // fall out to backoff/retry
						} else if (msg.length > 0 && msg[0] == '0') {
							parseEngineOpenFromPacket(msg, self);
							continue;
						} else {
							logSocketIOOutput("Received Unhandled Message: " ~ msg);
						}
					}

					// Fell out of the inner loop → close and backoff, then retry
					logSocketIOOutput("Retrying WebSocket Connection");
					collectException(self.ws.close(1001, "reconnect"));
					logSocketIOOutput("Backoff " ~ to!string(backoffSeconds) ~ "s before retry");
					Thread.sleep(dur!"seconds"(backoffSeconds));
					if (backoffSeconds < maxBackoffSeconds) backoffSeconds *= 2;
				}
			} catch (CurlException e) {
				// Caught a CurlException
				addLogEntry("Network error during socketio loop: " ~ e.msg ~ " (will retry)");
			} catch (SocketException e) {
				// Caught a SocketException
				addLogEntry("Socket error during socketio loop: " ~ e.msg ~ " (will retry)");
			} catch (Exception e) {
				// Caught some other error
				addLogEntry("Unexpected error during socketio loop: " ~ e.toString());
			}
		}
	}

	// Convert the notificationURL into a usable WebSocket URL
	static string toSocketIoWsUrl(string notificationUrl) {
		// input:  https://host/notifications?token=...&applicationId=...
		// output: wss://host/socket.io/?EIO=4&transport=websocket&token=...&applicationId=...
		logSocketIOOutput("toSocketIoWsUrl input: " ~ notificationUrl);
		
		size_t schemePos = notificationUrl.length;
		{
			auto pos = cast(ptrdiff_t) -1;
			// manual indexOf("://") without std.string
			for (size_t i = 0; i + 2 < notificationUrl.length; ++i) {
				if (notificationUrl[i] == ':' && notificationUrl[i+1] == '/' && notificationUrl[i+2] == '/') {
					pos = cast(ptrdiff_t)i;
					break;
				}
			}
			if (pos >= 0) schemePos = cast(size_t)pos;
		}

		string hostAndAfter;
		if (schemePos < notificationUrl.length) {
			hostAndAfter = notificationUrl[(schemePos + 3) .. notificationUrl.length];
		} else {
			hostAndAfter = notificationUrl;
		}

		size_t slash = hostAndAfter.length;
		foreach (i; 0 .. hostAndAfter.length) {
			if (hostAndAfter[i] == '/') { slash = i; break; }
		}

		string host = (slash < hostAndAfter.length) ? hostAndAfter[0 .. slash] : hostAndAfter;
		string query = "";
		if (slash < hostAndAfter.length) {
			auto rest = hostAndAfter[slash .. hostAndAfter.length];
			size_t qpos = rest.length;
			foreach (i; 0 .. rest.length) { if (rest[i] == '?') { qpos = i; break; } }
			if (qpos < rest.length) query = rest[(qpos + 1) .. rest.length];
		}

		string outUrl = "wss://" ~ host ~ "/socket.io/?EIO=4&transport=websocket";
		if (query.length > 0) outUrl ~= "&" ~ query;

		logSocketIOOutput("toSocketIoWsUrl output: " ~ outUrl);
		return outUrl;
	}

	// Wait for Socket.IO to open
	static bool awaitEngineOpen(curlWebsockets.CurlWebSocket ws, OneDriveSocketIo self) {
		SysTime deadline = Clock.currTime(UTC()) + dur!"seconds"(10);
		for (;;) {
			if (Clock.currTime(UTC()) >= deadline) return false;

			auto msg = ws.recvText();
			if (msg.length == 0) {
				Thread.sleep(dur!"msecs"(25));
				continue;
			}

			if (msg.length > 0 && msg[0] == '0') {
				return parseEngineOpenFromPacket(msg, self);
			}
			if (msg.length > 1 && msg[0] == '4' && msg[1] == '0') {
				self.namespaceOpened = true;
				return true;
			}
			logSocketIOOutput("Pre-open RX: " ~ msg);
		}
	}

	// Parse Socket.IO response
	static bool parseEngineOpenFromPacket(string packet, OneDriveSocketIo self) {
		// packet = "0{...json...}"
		if (packet.length < 2) return false;
		auto jsonPart = packet[1 .. packet.length];

		JSONValue j;
		auto err = collectException(j = parseJSON(jsonPart));
		if (err !is null) {
			logSocketIOOutput("Failed to parse Socket.IO open JSON");
			return false;
		}

		if (j.type == JSONType.object) {
			// sid
			if ("sid" in j.object) {
				auto vsid = j["sid"];
				if (vsid.type == JSONType.string) {
					self.engineSid = vsid.str;
				}
			}
			// pingInterval
			if ("pingInterval" in j.object) {
				auto v = j["pingInterval"];
				if (v.type == JSONType.integer) {
					self.pingIntervalMs = v.integer;
				}
			}
			// pingTimeout
			if ("pingTimeout" in j.object) {
				auto v2 = j["pingTimeout"];
				if (v2.type == JSONType.integer) {
					self.pingTimeoutMs = v2.integer;
				}
			}
		}

		// Log that we have opened a connection and have a valid SID
		logSocketIOOutput("Engine open; sid=" ~ self.engineSid ~ " pingInterval=" ~ self.pingIntervalMs.to!string ~ "ms" ~ " pingTimeout="  ~ self.pingTimeoutMs.to!string  ~ "ms");
		return true;
	}

	// Handle Socket.IO Events
	static void handleSocketIoEvent(string msg, OneDriveSocketIo self) {
		// Accept both: 42[...]
		// and:         42/<namespace>,[...]
		size_t i = 2;
		string ns = "/";

		// Optional namespace: 42/notifications,[...]
		if (i < msg.length && msg[i] == '/') {
			size_t j = i + 1;
			while (j < msg.length && msg[j] != ',') j++;
			if (j >= msg.length) {
				logSocketIOOutput("42 frame (malformed namespace): " ~ msg);
				return;
			}
			ns = msg[(i + 1) .. j];
			i = j + 1; // payload starts after comma
		}

		if (i >= msg.length || msg[i] != '[') {
			logSocketIOOutput("42 frame (unexpected payload start): ns='/" ~ ns ~ "' raw=" ~ msg);
			return;
		}

		JSONValue arr;
		auto ex = collectException(arr = parseJSON(msg[i .. $]));
		if (ex !is null || arr.type != JSONType.array || arr.array.length == 0) {
			logSocketIOOutput("42 frame (unparsed): ns='/" ~ ns ~ "' raw=" ~ msg);
			return;
		}

		auto evNameVal = arr.array[0];
		if (evNameVal.type != JSONType.string) {
			logSocketIOOutput("42 frame (no string event name): ns='/" ~ ns ~ "' raw=" ~ msg);
			return;
		}
		string evName = evNameVal.str;

		// 2nd element may be a JSON string containing the real JSON
		string dataText = "null";
		if (arr.array.length > 1) {
			auto d = arr.array[1];
			if (d.type == JSONType.string) {
				JSONValue inner;
				auto ex2 = collectException(inner = parseJSON(d.str));
				if (ex2 is null) {
					dataText = inner.toString(); // normalized JSON
				} else {
					dataText = d.str;           // raw string if not JSON
				}
			} else {
				dataText = d.toString();
			}
		}

		if (evName == "notification") {
			logSocketIOOutput("Notification Event (ns='/" ~ ns ~ "') -> " ~ dataText);
			// Signal main() monitor loop exactly like webhook does
			collectException(send(self.parentTid, cast(ulong)1));
		} else {
			// Visibility in case the service uses other event names
			logSocketIOOutput("Event '" ~ evName ~ "' (ns='/" ~ ns ~ "') -> " ~ dataText);
		}
	}
}
