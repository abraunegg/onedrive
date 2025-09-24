module socketio;

// ----------------------------
// Imports (explicit, Phobos only)
// ----------------------------
import std.concurrency : Tid, spawn, send;
import std.conv        : to;
import std.json        : parseJSON, JSONValue, JSONType;
import std.datetime    : SysTime, Clock, UTC;
import std.exception   : collectException;
import std.string      : indexOf;
import core.thread     : Thread;
import core.time       : Duration, dur;

// ----------------------------
// Project modules
// ----------------------------
import log;             // addLogEntry(...)
import util;            // (kept for project cohesion; not used directly here)
import config;          // ApplicationConfig
import curlWebsockets;  // CurlWebSocket (manual RFC6455 + EIOv4 over curl CONNECT_ONLY)

// ----------------------------
// Helpers
// ----------------------------

// Redact token=... value in URLs for logging
private string redactWsUrl(string url)
{
    auto i = url.indexOf("token=");
    if (i < 0) return url;

    auto j = url.indexOf("&", i);
    if (j < 0) j = cast(int) url.length;

    return url[0 .. i + 6] ~ "****" ~ url[j .. $];
}

// Check if URL has basic Engine.IO v4 WebSocket params
private bool looksLikeEioWs(string url)
{
    auto hasEio = (url.indexOf("EIO=4") >= 0) || (url.indexOf("eio=4") >= 0);
    auto hasWs  = (url.indexOf("transport=websocket") >= 0);
    return hasEio && hasWs;
}

// ----------------------------
// Socket.IO (Engine.IO v4) listener for Microsoft Graph notifications.
// ----------------------------
final class OneDriveSocketIo
{
    private Tid                parentTid;
    private ApplicationConfig  appConfig;

    private shared bool stopRequested = false;
    private bool        started       = false;

    private uint     notifyCount = 0;
    private Duration renewEarly  = dur!"seconds"(120);

    // track whether we've sent the client-side namespace connect ("40")
    private bool sentNamespaceConnect = false;

public:
    this(Tid parentTid, ApplicationConfig appConfig)
    {
        this.parentTid = parentTid;
        this.appConfig = appConfig;
    }

    void start()
    {
        if (started) return;

        static if (__traits(compiles, appConfig.websocketNotificationUrlAvailable))
        {
            if (!appConfig.websocketNotificationUrlAvailable)
            {
                addLogEntry("WebSocket: notification URL not available; listener not started.");
                return;
            }
        }

        stopRequested = false;
        started = true;
        spawn(&run, cast(shared) this);
        addLogEntry("Enabled WebSocket support to monitor Microsoft Graph API changes in near real-time.");
    }

    void stop()
    {
        if (!started) return;
        stopRequested = true;
        started = false;
    }

    Duration getNextExpirationCheckDuration()
    {
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
    static void run(shared OneDriveSocketIo _this)
    {
        addLogEntry("SOCKETIO: run() entered");

        auto self = cast(OneDriveSocketIo) _this;

        // Exponential backoff parameters
        Duration backoff          = dur!"seconds"(2);
        enum Duration backoffMax  = dur!"seconds"(60);

        // Default heartbeat (used until we parse 0{...})
        enum Duration defaultPingInterval = dur!"msecs"(25000); // 25s
        enum Duration defaultPingTimeout  = dur!"msecs"(6000);  // 6s

        // Diagnostics
        enum bool LOG_ALL_SIO_EVENTS = true;

        while (!_this.stopRequested)
        {
            const string baseUrl = self.appConfig.websocketNotificationUrl;

            addLogEntry("WS: baseUrl length = " ~ to!string(baseUrl.length));

            if (baseUrl.length == 0)
            {
                addLogEntry("WS: no endpoint yet; sleeping 3s");
                Thread.sleep(dur!"seconds"(3));
                continue;
            }

            const string wsUrl = baseUrl;
            addLogEntry("WS: connecting to " ~ redactWsUrl(wsUrl));

            // Quick sanity: does it look like an Engine.IO v4 WebSocket URL?
            if (!looksLikeEioWs(wsUrl))
            {
                addLogEntry("WS WARN: URL does not look like Engine.IO v4 WebSocket (missing EIO=4 and/or transport=websocket)");
            }

            auto ws = new CurlWebSocket();

            // Timeouts from config (sane defaults)
            int connectTimeoutSeconds = 10;   // default 10s connect
            int totalOpTimeoutMillis  = 3600; // default 3.6s

            static if (__traits(compiles, self.appConfig.getValueLong("connect_timeout")))
            {
                auto vConnect = cast(int) self.appConfig.getValueLong("connect_timeout");
                if (vConnect > 0) connectTimeoutSeconds = vConnect;
            }
            static if (__traits(compiles, self.appConfig.getValueLong("operation_timeout")))
            {
                auto vOpTimeout = cast(int) self.appConfig.getValueLong("operation_timeout");
                if (vOpTimeout >= 0) totalOpTimeoutMillis = vOpTimeout;
            }

            ws.setTimeouts(connectTimeoutSeconds, totalOpTimeoutMillis);

            string ua = "onedrive-client";
            static if (__traits(compiles, self.appConfig.getValueString("user_agent")))
            {
                auto tmpUa = self.appConfig.getValueString("user_agent");
                if (tmpUa.length) ua = tmpUa;
            }
            ws.setUserAgent(ua);

            addLogEntry(
                "WS: Timeouts set: connect=" ~ to!string(connectTimeoutSeconds * 1000) ~ "ms total=" ~ to!string(totalOpTimeoutMillis) ~ "ms");

            try
            {
                auto rc = ws.connect(wsUrl);
                addLogEntry("RC VALUE: " ~ to!string(rc));

                if (rc != ws.CURLE_OK)
                {
                    addLogEntry("WS: connect failed rc=" ~ to!string(rc));
                    throw new Exception("curl ws connect failed rc=" ~ to!string(rc));
                }

                addLogEntry("WS: connected");

                // Decide whether to drive Engine.IO ping/pong.
                // Default: TRUE. Allow override via config (getValueLong("drive_engine_ping") == 0 -> false).
                bool driveEnginePing = true;
                static if (__traits(compiles, self.appConfig.getValueLong("drive_engine_ping")))
                {
                    auto v = cast(int) self.appConfig.getValueLong("drive_engine_ping");
                    if (v == 0) driveEnginePing = false;
                    if (v == 1) driveEnginePing = true;
                }

                // Reset namespace-connect flag per connection
                self.sentNamespaceConnect = false;

                // Immediately join the default namespace so some servers start their Socket.IO layer
                if (!self.sentNamespaceConnect)
                {
                    auto ok = ws.sendText("40");
                    collectException(addLogEntry("WS: TX => 40 (client namespace connect)"));
                    self.sentNamespaceConnect = true;
                }

                // Reset backoff after a successful connection
                backoff = dur!"seconds"(2);

                // ------------ Engine.IO + Socket.IO processing loop ------------
                bool     namespaceOpened = false;
                bool     sawOpenMeta     = false;

                // Heartbeat values; will be replaced by meta 0{...} if received
                Duration pingInterval = defaultPingInterval;
                Duration pingTimeout  = defaultPingTimeout;

                // Track key times
                const SysTime connectedAt = Clock.currTime(UTC());
                SysTime  lastRxAt         = connectedAt; // last time we saw *any* frame
                SysTime  lastPingAt       = connectedAt; // client-driven heartbeat
                bool     awaitingPong     = false;

                // Watchdog: if completely silent for too long, reconnect
                Duration idleReconnect = dur!"seconds"(90);

                // Give the server a short grace period to send Engine.IO "0{...}"
                Duration openMetaGrace = dur!"seconds"(5);
                bool     nudgedOpen    = false; // whether we've "prodded" the server once

                // Diagnostic preview of early frames
                size_t diagFramesLeft = 30;

                for (;;)
                {
                    if (_this.stopRequested) break;

                    string s = ws.recvText();

                    auto now = Clock.currTime(UTC());

                    if (s.length == 0)
                    {
                        // Silence watchdog: if we've heard nothing for too long, reconnect
                        auto silence = now - lastRxAt;
                        if (silence >= idleReconnect)
                        {
                            addLogEntry("WS: no frames for " ~ to!string(silence.total!"msecs"()) ~
                                        "ms; watchdog reconnect");
                            break;
                        }

                        // If we didn't get Engine.IO open within a short grace, nudge once
                        if (!sawOpenMeta && (now - connectedAt) >= openMetaGrace && !nudgedOpen)
                        {
                            addLogEntry("WS: no Engine.IO open meta after " ~
                                        to!string((now - connectedAt).total!"msecs"()) ~ "ms; nudging (40 + optional ping)");
                            ws.sendText("40");
                            if (driveEnginePing) { ws.sendText("2"); lastPingAt = now; awaitingPong = true; }
                            nudgedOpen = true;
                        }

                        // Drive client pings (Engine.IO v4) if enabled
                        if (driveEnginePing)
                        {
                            if (awaitingPong)
                            {
                                auto sincePing = now - lastPingAt;
                                if (sincePing >= pingTimeout)
                                {
                                    addLogEntry("WS: pong timeout after " ~ to!string(sincePing.total!"msecs"()) ~
                                                "ms (limit=" ~ to!string(pingTimeout.total!"msecs"()) ~ "ms); reconnecting");
                                    break;
                                }
                            }
                            else
                            {
                                auto sincePing = now - lastPingAt;
                                if (sincePing >= pingInterval)
                                {
                                    auto rcPing = ws.sendText("2");
                                    lastPingAt = now;
                                    awaitingPong = true;
                                    addLogEntry("WS TX: 2 (ping), rc=" ~ to!string(rcPing) ~
                                                " next due in " ~ to!string(pingInterval.total!"msecs"()) ~ "ms");
                                }
                            }
                        }

                        // Lightweight heartbeat status
                        auto silenceNow = now - lastRxAt;
                        addLogEntry("WS: idle; silence=" ~ to!string(silenceNow.total!"msecs"()) ~
                                    "ms (pingInterval=" ~ to!string(pingInterval.total!"msecs"()) ~
                                    "ms pingTimeout=" ~ to!string(pingTimeout.total!"msecs"()) ~ "ms)");

                        Thread.sleep(dur!"msecs"(50));
                        continue;
                    }

                    // Diagnostics: raw Socket.IO frames
                    static if (LOG_ALL_SIO_EVENTS)
                    {
                        if (s.length > 0 && s[0] == '4')
                        {
                            string prev = (s.length > 256) ? s[0 .. 256] ~ "…" : s;
                            addLogEntry("WS SIO raw: " ~ prev);
                        }
                    }

                    // Any non-empty read counts as activity
                    lastRxAt = now;

                    // Optional diagnostic preview
                    if (diagFramesLeft)
                    {
                        string preview;
                        if (s.length > 64)
                            preview = s[0 .. 64] ~ "…";
                        else
                            preview = s;
                        addLogEntry("WS RX: " ~ preview);
                        --diagFramesLeft;
                    }

                    // ---------------------------
                    // Frame handling (Engine.IO/Socket.IO)
                    // ---------------------------

                    // Engine.IO "open" meta: "0{...}"
                    if (s.length > 0 && s[0] == '0')
                    {
                        sawOpenMeta = true;

                        // Try to parse pingInterval/pingTimeout (ms) and recompute timers
                        try
                        {
                            auto meta = parseJSON(s[1 .. $]);
                            if (meta.type() == JSONType.object)
                            {
                                auto m = meta.object;
                                if ("pingInterval" in m && m["pingInterval"].type() == JSONType.integer)
                                {
                                    auto ms = cast(long) m["pingInterval"].integer;
                                    if (ms > 1000 && ms < 120000) pingInterval = dur!"msecs"(cast(int) ms);
                                }
                                if ("pingTimeout" in m && m["pingTimeout"].type() == JSONType.integer)
                                {
                                    auto ms = cast(long) m["pingTimeout"].integer;
                                    if (ms > 500 && ms < 60000) pingTimeout = dur!"msecs"(cast(int) ms);
                                }
                                addLogEntry("WS: server heartbeat: pingInterval=" ~
                                            to!string(pingInterval.total!"msecs"()) ~ "ms pingTimeout=" ~
                                            to!string(pingTimeout.total!"msecs"()) ~ "ms");
                            }
                        }
                        catch (Exception) { /* ignore parse errors */ }

                        // Proactively open the default namespace as per Socket.IO (harmless if already sent)
                        auto rc40 = ws.sendText("40");
                        addLogEntry("WS TX: 40 (open namespace), rc=" ~ to!string(rc40));

                        // Reset ping scheduler on open meta if we drive pings
                        if (driveEnginePing)
                        {
                            lastPingAt   = Clock.currTime(UTC());
                            awaitingPong = false;
                        }
                        continue;
                    }

                    // Engine.IO server → client ping: "2" (client must reply "3")
                    if (s.length == 1 && s[0] == '2')
                    {
                        auto rc3 = ws.sendText("3");
                        addLogEntry("WS TX: 3 (pong to server ping), rc=" ~ to!string(rc3));
                        continue;
                    }

                    // Engine.IO server pong: "3" (in response to our ping "2")
                    if (s.length == 1 && s[0] == '3')
                    {
                        if (driveEnginePing) awaitingPong = false;
                        addLogEntry("WS RX: 3 (pong) — heartbeat ok");
                        continue;
                    }

                    // Engine.IO "close": "1" → reconnect
                    if (s.length == 1 && s[0] == '1')
                    {
                        addLogEntry("WS: Engine.IO close (1) received; reconnecting");
                        break;
                    }

                    // Socket.IO "opened" ack: "40" (may include namespace like "40/xyz,")
                    if (s.length >= 2 && s[0] == '4' && s[1] == '0')
                    {
                        if (!namespaceOpened)
                        {
                            namespaceOpened = true;
                            addLogEntry("WS: namespace opened (40 ack)");
                        }

                        // Some deployments require the client to have sent its own 40. Re-send (idempotent) if needed.
                        if (!self.sentNamespaceConnect) {
                            ws.sendText("40");
                            self.sentNamespaceConnect = true;
                            addLogEntry("WS: TX => 40 (ack server 40)");
                        }
                        continue;
                    }

                    // Socket.IO "closed" ack: "41" → reconnect
                    if (s.length >= 2 && s[0] == '4' && s[1] == '1')
                    {
                        if (namespaceOpened)
                        {
                            namespaceOpened = false;
                            addLogEntry("WS: namespace closed (41); reconnecting");
                        }
                        break;
                    }

                    // Socket.IO event: "42[...]" → typically ["notification", {...}]
                    if (s.length >= 2 && s[0] == '4' && s[1] == '2')
                    {
                        JSONValue packet;
                        try
                        {
                            packet = parseJSON(s[2 .. $]);
                        }
                        catch (Exception e)
                        {
                            addLogEntry("WS JSON parse error in 42 payload: " ~ e.msg);
                            string prev = (s.length > 256) ? s[0 .. 256] ~ "…" : s;
                            addLogEntry("WS 42 raw preview: " ~ prev);
                            continue;
                        }

                        if (packet.type() == JSONType.array && packet.array.length >= 1)
                        {
                            auto a = packet.array;
                            string evName;
                            if (a[0].type() == JSONType.string) evName = a[0].str;

                            // Always log the event name we actually received
                            addLogEntry("WS SIO event: " ~ (evName.length ? evName : "<non-string-name>")
                                        ~ " payloadItems=" ~ to!string(a.length));

                            // Existing handling: only act on "notification"
                            if (evName == "notification")
                            {
                                ++self.notifyCount;
                                send(self.parentTid, to!ulong(self.notifyCount));
                                addLogEntry("WS event: notification #" ~ to!string(self.notifyCount));
                            }
                        }
                        else
                        {
                            addLogEntry("WS 42 payload was not an array or was empty");
                        }
                        continue;
                    }

                    // Catch-all for other Socket.IO message types under "4" that we didn't handle above
                    if (s.length >= 2 && s[0] == '4')
                    {
                        auto upto = (s.length > 64 ? 64 : s.length);
                        addLogEntry("WS SIO unhandled frame: " ~ s[0 .. upto] ~ (s.length > 64 ? "…" : ""));
                        continue;
                    }

                    // Other frames are ignored (but count as activity)
                } // end for(;;)

                addLogEntry("WS: disconnected; will backoff and reconnect");
            }
            catch (Exception e)
            {
                addLogEntry("WS exception: " ~ e.msg);
            }

            if (_this.stopRequested) break;

            addLogEntry("WS: sleeping(backoff) for " ~ to!string(backoff.total!"msecs"()) ~ "ms");
            Thread.sleep(backoff);

            auto next = backoff * 2;
            if (next > backoffMax) next = backoffMax;
            backoff = next;
        } // while

        addLogEntry("WS: worker exit");
    }
}
