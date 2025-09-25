// What is this module called?
module socketio;

// What does this module require to function?
import std.exception   : collectException;
import core.thread     : Thread;
import std.concurrency : Tid, spawn, send;
import core.time       : Duration, dur;
import std.datetime    : SysTime, Clock, UTC;
import std.conv        : to;

// What other modules that we have created do we need to import?
import log;
import util;
import config;
import curlWebsockets;

// ========== Logging Shim ==========
private void logSocketIOOutput(string s) {
    collectException(addLogEntry("SOCKETIO: " ~ s));
}

final class OneDriveSocketIo {
	private Tid                parentTid;
    private ApplicationConfig  appConfig;
	private bool started = false;
	private Duration renewEarly = dur!"seconds"(120);
	private string engineSid;
	private bool expiryWarned = false;
	private bool renewRequested = false;
	private string currentNotifUrl;
	

    // Worker / state
    private shared bool pleaseStop = false;
    private long  pingIntervalMs = 25000;
    private long  pingTimeoutMs  = 60000;
    private bool  namespaceOpened = false;

public:
	this(Tid parentTid, ApplicationConfig appConfig) {
        this.parentTid = parentTid;
        this.appConfig = appConfig;
		
    }
	
	~this(){
	
		logSocketIOOutput("Destroying OneDriveSocketIo");
	
	}

	void start() {
        if (started) return;

        // Use existing shim
        //logSocketIOOutput("Value from appConfig.websocketEndpointResponse = " ~ appConfig.websocketEndpointResponse);
        //logSocketIOOutput("Value from appConfig.websocketNotificationUrl  = " ~ appConfig.websocketNotificationUrl);
        //logSocketIOOutput("Value from appConfig.websocketUrlExpiry        = " ~ appConfig.websocketUrlExpiry);
		
		currentNotifUrl = appConfig.websocketNotificationUrl;

		started = true;
		spawn(&run, cast(shared) this);
		logSocketIOOutput("Enabled WebSocket support to monitor Microsoft Graph API changes in near real-time.");
	}

	void stop() {
        if (!started) return;
        pleaseStop = true; // worker loop is cooperative
        started = false;
		
		logSocketIOOutput("Disabled WebSocket monitoring of Microsoft Graph API changes.");
		
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
	static void run(shared OneDriveSocketIo _this) {
		
		logSocketIOOutput("run() entered");

		auto self = cast(OneDriveSocketIo) _this;

		CurlWebSocket ws = new CurlWebSocket();
		
		scope(exit) {
			// make shutdown explicit and visible
			logSocketIOOutput("leaving run() function");
			if (ws !is null) {
				object.destroy(ws);     // call destructor deterministically
				ws = null;
			}
			logSocketIOOutput("Disabled WebSocket monitoring of Microsoft Graph API changes.");
		}

        // Build Socket.IO WS URL from notificationUrl:
        string notif = self.appConfig.websocketNotificationUrl;
        if (notif.length == 0) {
            logSocketIOOutput("no notificationUrl available");
            return;
        }
        string wsUrl = toSocketIoWsUrl(notif);

        // Use application configuration values
		ws.setUserAgent(self.appConfig.getValueString("user_agent"));
        ws.setTimeouts(10000, 15000);
		
		logSocketIOOutput("Connecting to " ~ wsUrl);

        auto rc = ws.connect(wsUrl);
        if (rc != 0) {
            logSocketIOOutput("ws.connect failed");
            return;
        }

        // Engine.IO handshake: wait for '0{json}'
        if (!awaitEngineOpen(ws, self)) {
            logSocketIOOutput("Engine.IO open handshake failed");
            return;
        }

        // Open default namespace: send "40"
		logSocketIOOutput("Sending Socket.IO connect (40) to default namespace");
        if (ws.sendText("40") != 0) {
            logSocketIOOutput("Failed to send 40 (open namespace)");
            return;
        }
		logSocketIOOutput("Sent Socket.IO connect '40' for namespace '/'");
		
		bool firstPingLogged = false;
		bool firstPongLogged = false;

        // Main loop with SysTime-based timing (no MonoTime import)
        SysTime nextPing = Clock.currTime(UTC()) + dur!"msecs"(self.pingIntervalMs);
		
        for (;;) {
			if (self.pleaseStop) {
				logSocketIOOutput("stop requested; shutting down");
				
				// graceful RFC6455 close (implemented below in CurlWebSocket)
				collectException(ws.close(1000, "client stop"));
				object.destroy(ws);
				
				break;
			}

            // Subscription nearing expiry? (actual renewal lives elsewhere)
            if (!self.expiryWarned && self.appConfig.websocketUrlExpiry.length > 0) {
				SysTime expiry;
				auto e = collectException(expiry = SysTime.fromISOExtString(self.appConfig.websocketUrlExpiry));
				if (e is null) {
					auto remain = expiry - Clock.currTime(UTC());
					if (remain <= dur!"minutes"(5)) {
						self.expiryWarned = true; // emit only once
						logSocketIOOutput("subscription nearing expiry; renewal required soon");
						// (actual renewal call happens elsewhere in your app)
					}
				}
			}

            
			// renewal window check (emit once)
			if (!self.renewRequested && self.appConfig.websocketUrlExpiry.length > 0) {
				SysTime expiry;
				auto e = collectException(expiry = SysTime.fromISOExtString(self.appConfig.websocketUrlExpiry));
				if (e is null) {
					auto remain = expiry - Clock.currTime(UTC());
					if (remain <= dur!"minutes"(2)) {
						self.renewRequested = true;
						logSocketIOOutput("Subscription nearing expiry; requesting renewal from main");
						// Tell main run loop to renew (main already handles webhook-like messages).
						// Keep it super simple: a plain tag + context strings.
						send(self.parentTid, "SOCKETIO_RENEWAL_REQUEST");
						send(self.parentTid, "SOCKETIO_RENEWAL_CONTEXT:" ~ "id=" ~ self.appConfig.websocketEndpointResponse ~ " url=" ~ self.appConfig.websocketNotificationUrl);
					}
				}
			}
			
			// reconnect to a new endpoint if main updated appConfig.websocketNotificationUrl
			if (self.appConfig.websocketNotificationUrl.length > 0 && self.appConfig.websocketNotificationUrl != self.currentNotifUrl) {
				logSocketIOOutput("Detected new notificationUrl; reconnecting");
				// Graceful close current connection
				collectException(ws.close(1000, "reconnect"));
				// Update cache and rebuild WS URL
				self.currentNotifUrl = self.appConfig.websocketNotificationUrl;
				string newWsUrl = toSocketIoWsUrl(self.currentNotifUrl);
				// Establish a fresh connection and handshakes
				ws = new CurlWebSocket();
				ws.setUserAgent("onedrive-linux/socketio");
				ws.setTimeouts(10000, 15000);
				auto rc2 = ws.connect(newWsUrl);
				if (rc2 != 0) {
					logSocketIOOutput("reconnect failed");
					break;
				}
				// Expect a fresh Engine.IO open ("0{...}")
				if (!awaitEngineOpen(ws, self)) {
					logSocketIOOutput("Engine.IO open after reconnect failed");
					break;
				}
				logSocketIOOutput("sending Socket.IO connect (40) to default namespace");
				if (ws.sendText("40") != 0) {
					logSocketIOOutput("failed to send 40 (open namespace) after reconnect");
					break;
				}
				// reset state flags
				self.namespaceOpened = false; // will be set true on ack
				// continue loop; we'll read until we get the "40" ack again
			}

			// Receive
            auto msg = ws.recvText();
            if (msg.length == 0) {
                Thread.sleep(dur!"msecs"(20));
                continue;
            }

            // Engine.IO / Socket.IO parsing without startsWith()
			if (msg.length > 0 && msg[0] == '2') {
				// Server ping -> immediate pong
				if (ws.sendText("3") != 0) {
					logSocketIOOutput("Failed sending Engine.IO pong '3'");
					break;
				}
				// Optional: log once or sparsely
				logSocketIOOutput("Engine.IO ping received, → pong sent");
				continue;
			}
			
			
			
            if (msg.length > 0 && msg[0] == '3') {
                // Engine.IO pong
				if (!firstPongLogged) { logSocketIOOutput("Received Engine.IO pong"); firstPongLogged = true; }
                continue;
            } else if (msg.length > 1 && msg[0] == '4' && msg[1] == '2') { // Received a '42' code
                handleSocketIoEvent(msg);
                continue;
            } else if (msg.length > 1 && msg[0] == '4' && msg[1] == '0') { // Received a '40' code
				self.namespaceOpened = true;
				logSocketIOOutput("Namespace '/' opened; listening for Socket.IO 'notification' events");
                continue;
            } else if (msg.length > 1 && msg[0] == '4' && msg[1] == '1') { // Received a '41' code
                logSocketIOOutput("got 41 (disconnect)");
                break;
            } else if (msg.length > 0 && msg[0] == '0') {
                parseEngineOpenFromPacket(msg, self);
                continue;
            } else {
                logSocketIOOutput("rx: " ~ msg);
            }
        }
		
		// After the loop
		collectException(ws.close(1000, "normal closure"));
		object.destroy(ws);
		logSocketIOOutput("left run() loop");
		
	}

    // --- Helpers ---

    static string toSocketIoWsUrl(string notificationUrl) {
        // input:  https://host/notifications?token=...&applicationId=...
        // output: wss://host/socket.io/?EIO=4&transport=websocket&token=...&applicationId=...
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
        return outUrl;
    }

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
            logSocketIOOutput("pre-open rx: " ~ msg);
        }
    }

    static bool parseEngineOpenFromPacket(string packet, OneDriveSocketIo self) {
        // packet = "0{...json...}"
        if (packet.length < 2) return false;
        auto jsonPart = packet[1 .. packet.length];

        import std.json : JSONValue, parseJSON, JSONType;

        JSONValue j;
        auto err = collectException(j = parseJSON(jsonPart));
        if (err !is null) {
            logSocketIOOutput("failed to parse Engine.IO open JSON");
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

    static void handleSocketIoEvent(string msg) {
        // "42" + JSON array, e.g. 42["notification", {...}]
        if (msg.length < 3) return;
        auto jsonArr = msg[2 .. msg.length];

        import std.json : JSONValue, parseJSON, JSONType;

        JSONValue j;
        auto err = collectException(j = parseJSON(jsonArr));
        if (err !is null) return;
        if (j.type != JSONType.array) return;
        if (j.array.length == 0) return;

        string eventName;
        auto err2 = collectException(eventName = j.array[0].str);
        if (err2 !is null) return;

        if (eventName == "notification") {
            string payload = (j.array.length > 1) ? j.array[1].toString() : "{}";
            logSocketIOOutput("notification event -> " ~ payload);
        } else {
            logSocketIOOutput("event '" ~ eventName ~ "'");
        }
    }
}
