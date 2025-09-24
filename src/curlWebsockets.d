module curlWebsockets;

// Manual RFC6455 + Engine.IO v4 over libcurl CONNECT_ONLY
// DMD 2.103.0; stock Phobos only; no libcurl WS API.
// Allowed curl functions only: curl_easy_init/cleanup/setopt/perform/send/recv, curl_slist_append/free_all.
//
// Required API by project:
// class CurlWebSocket {
//   this(); ~this();
//   void setTimeouts(int,int);
//   void setUserAgent(string);
//   void setSslVerify(bool,bool); // no-op
//   bool isConnected();
//   int  connect(string wsUrl);   // expects socket.io EIO=4-capable URL (notifications-derived)
//   int  sendText(string);
//   string recvText();
// }
//
// All logging goes via addLogEntry; local helper wraps it as “WS: …”.

import std.array                 : Appender;
import std.conv                  : to;
import std.exception             : collectException;
import std.format                : format;
import std.random                : Random, unpredictableSeed, uniform;
import std.string                : indexOf, strip, toLower, split, startsWith, replace, toStringz;
import std.utf                   : byCodeUnit;
import std.algorithm.searching   : countUntil;
import std.datetime              : Clock, UTC;
import std.digest.sha            : SHA1;
import std.base64                : Base64;

import core.time                 : dur;
import core.thread               : Thread;

import log; // addLogEntry(string)

// ========== libcurl minimal decls ==========
extern(C) {

struct CURL { }
struct curl_slist { char* data; curl_slist* next; }

enum CURLE_OK = 0;
enum CURLE_AGAIN = 81;

enum CURLOPTTYPE_LONG          = 0;
enum CURLOPTTYPE_OBJECTPOINT   = 10000;
enum CURLOPTTYPE_FUNCTIONPOINT = 20000;
enum CURLOPTTYPE_OFF_T         = 30000;

enum CURLOPT_URL               = CURLOPTTYPE_OBJECTPOINT + 2;
enum CURLOPT_USERAGENT         = CURLOPTTYPE_OBJECTPOINT + 18;
enum CURLOPT_HTTPHEADER        = CURLOPTTYPE_OBJECTPOINT + 23;
enum CURLOPT_WRITEFUNCTION     = CURLOPTTYPE_FUNCTIONPOINT + 11;
enum CURLOPT_WRITEDATA         = CURLOPTTYPE_OBJECTPOINT + 1;
enum CURLOPT_HEADER            = CURLOPTTYPE_LONG + 42;
enum CURLOPT_CONNECT_ONLY      = CURLOPTTYPE_LONG + 141;
enum CURLOPT_TIMEOUT_MS        = CURLOPTTYPE_LONG + 155;
enum CURLOPT_CONNECTTIMEOUT_MS = CURLOPTTYPE_LONG + 156;
enum CURLOPT_FRESH_CONNECT     = CURLOPTTYPE_LONG + 74;
enum CURLOPT_FORBID_REUSE      = CURLOPTTYPE_LONG + 75;
enum CURLOPT_VERBOSE           = CURLOPTTYPE_LONG + 41;

enum CURLOPT_HEADERFUNCTION    = CURLOPTTYPE_FUNCTIONPOINT + 79;
enum CURLOPT_HEADERDATA        = CURLOPTTYPE_OBJECTPOINT   + 29;

enum CURLOPT_IPRESOLVE         = CURLOPTTYPE_LONG + 113;
enum CURL_IPRESOLVE_V4         = 1;

enum CURLOPT_TCP_NODELAY       = CURLOPTTYPE_LONG + 121;
enum CURLOPT_NOSIGNAL          = CURLOPTTYPE_LONG + 99;

enum CURLOPT_HTTP_VERSION      = CURLOPTTYPE_LONG + 84;
enum CURL_HTTP_VERSION_1_1     = 2;

enum CURLOPT_SSLVERSION        = CURLOPTTYPE_LONG + 32;
enum CURL_SSLVERSION_TLSv1_2   = 6;

enum CURLOPT_SSL_ENABLE_ALPN   = CURLOPTTYPE_LONG + 272;
enum CURLOPT_SSL_ENABLE_NPN    = CURLOPTTYPE_LONG + 274;

CURL* curl_easy_init();
void  curl_easy_cleanup(CURL*);
int   curl_easy_setopt(CURL*, int option, ...);
int   curl_easy_perform(CURL*);

int   curl_easy_send(CURL*, const(void)* buffer, size_t buflen, size_t* n);
int   curl_easy_recv(CURL*, void* buffer, size_t buflen, size_t* n);

curl_slist* curl_slist_append(curl_slist*, const(char)*);
void        curl_slist_free_all(curl_slist*);
}

// ========== logging shim ==========
private void logCurlWebsocketOutput(string s) {
    collectException(addLogEntry("WS: " ~ s));
}
private void sleepMs(int ms) { Thread.sleep(dur!"msecs"(ms)); }

// ========== URL parsing (no std.uri) ==========
private struct ParsedUrl {
    string scheme; // ws|wss
    string host;
    ushort port;
    string pathAndQuery; // includes leading '/'
}

private ParsedUrl parseWsUrl(string u) {
    ParsedUrl p;
    if (u.length < 5) throw new Exception("URL too short");
    auto low = u.toLower();

    if (low.startsWith("wss://")) { p.scheme = "wss"; }
    else if (low.startsWith("ws://")) { p.scheme = "ws"; }
    else throw new Exception("URL must start with ws:// or wss://");

    size_t off = (p.scheme == "wss") ? 6 : 5;

    // host[:port][/...]
    ptrdiff_t slashRel = (u.length > off) ? u[off .. $].countUntil('/') : -1;
    ptrdiff_t slashAbs = (slashRel < 0) ? -1 : (off + slashRel);

    string hostPort;
    if (slashAbs < 0) {
        hostPort = u[off .. $];
        p.pathAndQuery = "/";
    } else {
        hostPort = u[off .. cast(size_t)slashAbs];
        p.pathAndQuery = u[cast(size_t)slashAbs .. $];
        if (p.pathAndQuery.length == 0) p.pathAndQuery = "/";
    }

    auto colon = hostPort.indexOf(":");
    if (colon < 0) {
        p.host = hostPort;
        p.port = (p.scheme == "wss") ? 443 : 80;
    } else {
        p.host = hostPort[0 .. cast(size_t)colon];
        auto ps = hostPort[cast(size_t)(colon + 1) .. $];
        ushort prt = 0;
        foreach (ch; ps.byCodeUnit) {
            if (ch < '0' || ch > '9') throw new Exception("invalid port");
            prt = cast(ushort)(prt * 10 + (ch - '0'));
        }
        if (prt == 0) throw new Exception("invalid port");
        p.port = prt;
    }

    return p;
}

// ========== small utils ==========

private ubyte[] randomBytes(size_t n) {
    static bool seeded = false;
    static Random rng;
    if (!seeded) { rng = Random(unpredictableSeed); seeded = true; }
    auto buf = new ubyte[](n);
    foreach (i; 0 .. n) buf[i] = uniform!ubyte(rng);
    return buf;
}

// minimal Base64 via Phobos (standard alphabet)
private string b64(const(ubyte)[] data) {
    return cast(string)Base64.encode(data).idup;
}

private string sha1b64(string s) {
    auto sha = SHA1();
    sha.put(cast(const(ubyte)[])s);
    auto dig = sha.finish();
    return cast(string)Base64.encode(dig[]).idup;
}

// masking per RFC6455
private void maskPayload(ubyte[] buf, ubyte[4] key) {
    foreach (i; 0 .. buf.length) buf[i] ^= key[i & 3];
}

// recv buffer with small scratch
private struct RecvBuf {
    private ubyte[] buf;
    private ubyte[] scratch;
    CURL* handle;

    void clear() { buf.length = 0; }

    bool ensure(size_t need, int timeoutMs = 250) {
        if (buf.length >= need) return true;

        if (scratch.length == 0) {
            logCurlWebsocketOutput("RecvBuf.ensureScratch: allocated scratch=4096");
            scratch = new ubyte[4096]; // allocate a real 4KB buffer
        }

        size_t loops = 0;
        auto start = Clock.currTime(UTC());
        for (;;) {
            if (buf.length >= need) return true;

            size_t n = 0;
            auto rc = curl_easy_recv(handle, scratch.ptr, scratch.length, &n);
            if (rc == CURLE_OK) {
                if (n > 0) {
                    auto old = buf.length;
                    buf.length = old + n;
                    foreach (i; 0 .. n) buf[old + i] = scratch[i];
                }
            } else if (rc == CURLE_AGAIN) {
                // spin until timeout
            } else {
                // treat as no progress
            }

            ++loops;
            auto elapsed = (Clock.currTime(UTC()) - start).total!"msecs";
            if (buf.length >= need) return true;
            if (elapsed >= timeoutMs) {
                logCurlWebsocketOutput(format("RecvBuf.ensure: timeout after %sms (AGAIN), have=%s need=%s -> return false",
                               elapsed, buf.length, need));
                return false;
            }
            if ((loops % 20) == 0) {
                logCurlWebsocketOutput(format("RecvBuf.ensure: CURLE_AGAIN loops=%s elapsed=%sms have=%s need=%s",
                    loops, elapsed, buf.length, need));
            }
            sleepMs(5);
        }
    }

    ubyte[] take(size_t n) {
        auto have = buf.length;
        size_t m = (n > have) ? have : n;
        auto chunk = new ubyte[](m);
        foreach (i; 0 .. m) chunk[i] = buf[i];
        auto remain = have - m;
        foreach (i; 0 .. remain) buf[i] = buf[m + i];
        buf.length = remain;
        return chunk;
    }

    ubyte[] takeAll() { return take(buf.length); }
}

// ========== simple HTTP helpers over CONNECT_ONLY ==========
private struct HttpResp {
    int statusCode;
    string headers;   // raw headers (without the terminating CRLFCRLF)
    ubyte[] body;     // body bytes
}

private string normalizeQueryKeepExtras(string q, bool toPolling) {
    // remove any existing eio/transport/sid, then add the desired ones
    auto items = q.split("&");
    Appender!string qb;
    bool first = true;
    foreach (it; items) {
        auto kv = it.split("=");
        if (kv.length == 0) continue;
        auto k = kv[0].toLower().strip();
        if (k == "eio" || k == "transport" || k == "sid") continue;
        if (!first) qb.put("&"); first = false;
        qb.put(it);
    }
    auto suffix = toPolling ? "EIO=4&transport=polling" : "EIO=4&transport=websocket";
    if (!first) qb.put("&");
    qb.put(suffix);
    return qb.data;
}

private int findContentLength(string headers) {
    auto low = headers.toLower();
    auto k = "content-length:";
    auto p = low.indexOf(k);
    if (p < 0) return -1;
    size_t i = cast(size_t)(p + k.length);
    while (i < low.length && (low[i] == ' ' || low[i] == '\t')) ++i;
    int v = 0;
    bool any = false;
    while (i < low.length) {
        auto ch = low[i];
        if (ch < '0' || ch > '9') break;
        v = v * 10 + (ch - '0');
        any = true;
        ++i;
    }
    return any ? v : -1;
}

private HttpResp httpGetOnSocket(CURL* h, ref RecvBuf rb, string hostHeader, string pathQuery, string cookieLine, string userAgent, int readTimeoutMs) {
    // Build GET
    string req =
        format("GET %s HTTP/1.1\r\n", pathQuery) ~
        format("Host: %s\r\n", hostHeader) ~
        format("User-Agent: %s\r\n", userAgent) ~
        "Accept: */*\r\n" ~
        "Connection: keep-alive\r\n" ~
        "Origin: https://graph.microsoft.com\r\n" ~
        (cookieLine.length ? cookieLine : "") ~
        "\r\n";

    logCurlWebsocketOutput("EIO open via same socket: sending " ~ pathQuery);
    logCurlWebsocketOutput("EIO open: request line = " ~ format("GET %s HTTP/1.1", pathQuery));

    // send all
    size_t off = 0;
    auto bytes = cast(const(ubyte)[])req;
    while (off < bytes.length) {
        size_t n = 0;
        auto rc = curl_easy_send(h, bytes.ptr + off, bytes.length - off, &n);
        if (rc == CURLE_OK) {
            off += n;
        } else if (rc == CURLE_AGAIN) {
            sleepMs(5);
        } else {
            logCurlWebsocketOutput("send failed during httpGetOnSocket");
            return HttpResp.init;
        }
    }
    logCurlWebsocketOutput(format("send: wrote %s bytes, total=%s/%s", bytes.length, bytes.length, bytes.length));

    // read headers (may overread some bytes from body; capture leftovers)
    Appender!(ubyte[]) ab;
    auto start = Clock.currTime(UTC());
    for (;;) {
        if (!rb.ensure(1, 250)) {
            auto elapsed = (Clock.currTime(UTC()) - start).total!"msecs";
            if (elapsed >= readTimeoutMs) {
                logCurlWebsocketOutput("HTTP: header read timeout");
                return HttpResp.init;
            }
            continue;
        }
        auto chunk = rb.takeAll();
        if (chunk.length) ab.put(chunk);
        string s = cast(string)ab.data;
        auto p = s.indexOf("\r\n\r\n");
        if (p >= 0) {
            auto statusEnd = s.indexOf("\r\n");
            auto statusLine = (statusEnd > 0) ? s[0 .. cast(size_t)statusEnd] : s;
            auto headersOnly = s[cast(size_t)(statusEnd + 2) .. cast(size_t)p];
            logCurlWebsocketOutput(format("HTTP: header block length=%s", (statusEnd >= 0 ? statusEnd : 0)));

            // status code
            int statusCode = 0;
            auto sp = statusLine.split(" ");
            if (sp.length >= 2) { try { statusCode = sp[1].strip().to!int; } catch(Exception) {} }

            // content length
            int clen = findContentLength(headersOnly);
            if (clen < 0) clen = 0;

            // leftover (start of body)
            size_t headerLen = cast(size_t)(p + 4);
            auto all = ab.data;
            size_t leftoverLen = (all.length > headerLen) ? (all.length - headerLen) : 0;

            ubyte[] body = new ubyte[](cast(size_t)clen);
            // copy leftovers
            size_t have = (leftoverLen > cast(size_t)clen) ? cast(size_t)clen : leftoverLen;
            foreach (i; 0 .. have) body[i] = all[headerLen + i];

            // need more?
            size_t pos = have;
            while (pos < cast(size_t)clen) {
                if (!rb.ensure(1, 250)) {
                    auto e2 = (Clock.currTime(UTC()) - start).total!"msecs";
                    if (e2 >= readTimeoutMs) {
                        logCurlWebsocketOutput("HTTP: body read timeout");
                        return HttpResp.init;
                    }
                    continue;
                }
                auto more = rb.take(cast(size_t)clen - pos);
                foreach (i; 0 .. more.length) body[pos + i] = more[i];
                pos += more.length;
            }

            logCurlWebsocketOutput(format("HTTP: body read %s bytes", body.length));
            return HttpResp(statusCode, headersOnly, body);
        }
    }
}

// ========== RFC6455 helpers ==========
private string wsAcceptForKey(string secKeyB64) {
    enum GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    return sha1b64(secKeyB64 ~ GUID);
}

// ========== class ==========
class CurlWebSocket {
public:
    this() {
        httpHostHeader = "";
        userAgent = "onedrive-websocket";
        connectTimeoutMs = 10000;
        totalTimeoutMs = 60 * 60 * 1000; // 1 hour default
        connected = false;
        h = null;
        rb.handle = null;
    }

    ~this() {
        if (h !is null) curl_easy_cleanup(h);
        h = null;
        connected = false;
    }

    void setTimeouts(int connectSeconds, int totalMillis) {
        connectTimeoutMs = (connectSeconds <= 0) ? 10000 : connectSeconds * 1000;
        totalTimeoutMs   = (totalMillis   <  0) ? 0 : totalMillis;
        logCurlWebsocketOutput(format("Timeouts set: connect=%sms total=%sms", connectTimeoutMs, totalTimeoutMs));
    }

    void setUserAgent(string ua) { if (ua.length) userAgent = ua; }
    void setSslVerify(bool, bool) { /* no-op */ }
    bool isConnected() { return connected; }

    // Allow both `ws.CURLE_OK` and `ws.CURLE_OK()` in existing code.
    @property int CURLE_OK() { return 0; }

    enum ubyte WS_TEXT  = 0x1;
    enum ubyte WS_PING  = 0x9;
    enum ubyte WS_PONG  = 0xA;
    enum ubyte WS_CLOSE = 0x8;

    int connect(string wsUrl) {
        logCurlWebsocketOutput("connect() begin");
        try {
            pu = parseWsUrl(wsUrl);
            logCurlWebsocketOutput(format("Parsed URL ok: scheme=%s host=%s port=%s path=%s", pu.scheme, pu.host, pu.port, pu.pathAndQuery));

            const bool isSecure = (pu.scheme == "wss");
            const bool omitPort = (isSecure && pu.port == 443) || (!isSecure && pu.port == 80);
            httpHostHeader = omitPort ? pu.host : format("%s:%s", pu.host, pu.port);
            baseHttpUrl = isSecure ? format("https://%s/", httpHostHeader) : format("http://%s/", httpHostHeader);
            logCurlWebsocketOutput("curl URL = " ~ baseHttpUrl);

            if (h is null) {
                h = curl_easy_init();
                if (h is null) { logCurlWebsocketOutput("curl_easy_init failed"); return -1; }
                rb.handle = h;
            } else {
                rb.handle = h;
            }
            rb.clear();

            // TCP/TLS connect
            if (curl_easy_setopt(h, CURLOPT_URL, cast(void*)baseHttpUrl.toStringz()) != CURLE_OK) { logCurlWebsocketOutput("setopt URL failed"); return -1; }
            cast(void)curl_easy_setopt(h, CURLOPT_HTTP_VERSION, cast(long)CURL_HTTP_VERSION_1_1);
            cast(void)curl_easy_setopt(h, CURLOPT_SSL_ENABLE_ALPN, cast(long)0);
            cast(void)curl_easy_setopt(h, CURLOPT_SSL_ENABLE_NPN,  cast(long)0);
            cast(void)curl_easy_setopt(h, CURLOPT_IPRESOLVE, cast(long)CURL_IPRESOLVE_V4);
            cast(void)curl_easy_setopt(h, CURLOPT_SSLVERSION, cast(long)CURL_SSLVERSION_TLSv1_2);
            cast(void)curl_easy_setopt(h, CURLOPT_TCP_NODELAY, cast(long)1);
            cast(void)curl_easy_setopt(h, CURLOPT_NOSIGNAL, cast(long)1);
            cast(void)curl_easy_setopt(h, CURLOPT_VERBOSE, cast(long)0);
            cast(void)curl_easy_setopt(h, CURLOPT_CONNECTTIMEOUT_MS, cast(long)connectTimeoutMs);
            cast(void)curl_easy_setopt(h, CURLOPT_TIMEOUT_MS,        cast(long)totalTimeoutMs);
            cast(void)curl_easy_setopt(h, CURLOPT_USERAGENT, cast(void*)userAgent.toStringz());
            cast(void)curl_easy_setopt(h, CURLOPT_CONNECT_ONLY, cast(long)1);

            logCurlWebsocketOutput("calling curl_easy_perform (CONNECT_ONLY) …");
            auto rc = curl_easy_perform(h);
            if (rc != CURLE_OK) {
                logCurlWebsocketOutput("connect: perform failed rc=" ~ to!string(rc));
                return rc;
            }
            logCurlWebsocketOutput("underlying TCP/TLS connected");

            // ------------ 1) Engine.IO open via polling ------------
            string pathQ = pu.pathAndQuery;
            auto qpos = pathQ.indexOf("?");
            if (qpos >= 0) {
                auto parts = pathQ.split("?");
                pathQ = parts[0] ~ "?" ~ normalizeQueryKeepExtras(parts[1], true);
            } else {
                pathQ = pathQ ~ "?EIO=4&transport=polling";
            }
            // add probe timestamp t=...
            auto tval = to!string(Clock.currTime(UTC()).stdTime);
            pathQ = pathQ ~ (pathQ.indexOf("?") >= 0 ? "&" : "?") ~ "t=" ~ tval;

            auto respOpen = httpGetOnSocket(h, rb, pu.host, pathQ, "", userAgent, 60000);
            if (respOpen.statusCode < 200 || respOpen.statusCode >= 300) {
                logCurlWebsocketOutput("EIO open: bad status " ~ to!string(respOpen.statusCode));
                return -1;
            }

            // Extract sid from body text
            string bodyStr = cast(string)respOpen.body;
            auto brace = bodyStr.indexOf("{");
            string sid = "";
            if (brace >= 0) {
                auto tail = bodyStr[cast(size_t)brace .. $];
                auto key = "\"sid\":\"";
                auto p = tail.indexOf(key);
                if (p >= 0) {
                    size_t i = cast(size_t)(p + key.length);
                    Appender!string sidApp;
                    while (i < tail.length) {
                        auto ch = tail[i];
                        if (ch == '"') break;
                        sidApp.put(ch);
                        ++i;
                    }
                    sid = sidApp.data;
                }
            }
            logCurlWebsocketOutput("EIO open: " ~ (sid.length ? ("sid=" ~ sid) : "sid not found"));
            if (sid.length == 0) return -1;

            // ------------ 2) WebSocket upgrade with sid ------------
            string wsPQ;
            {
                auto pq = pu.pathAndQuery;
                auto qp = pq.indexOf("?");
                if (qp >= 0) {
                    auto parts = pq.split("?");
                    auto nq = normalizeQueryKeepExtras(parts[1], false);
                    wsPQ = parts[0] ~ "?" ~ nq ~ "&sid=" ~ sid;
                } else {
                    wsPQ = pq ~ "?EIO=4&transport=websocket&sid=" ~ sid;
                }
            }
            // Always send Cookie: io=<sid>
            string cookieLine = "Cookie: io=" ~ sid ~ "\r\n";

            if (!websocketUpgradeSameSocket(wsPQ, cookieLine)) {
                logCurlWebsocketOutput("connect: WebSocket upgrade failed");
                return -1;
            }

            // ------------ 3) Engine.IO WS probe/upgrade ------------
            // send "2probe"
            cast(void)sendText("2probe");
            // wait for "3probe"
            if (!waitForTextExact("3probe", 10000)) {
                logCurlWebsocketOutput("probe: did not receive 3probe");
                return -1;
            }
            // send "5" (upgrade)
            cast(void)sendText("5");

            // send Socket.IO namespace connect now
            cast(void)sendText("40");

            // **NEW (surgical): kick the ping cycle** — some servers expect the client
            // to send a ping on the WebSocket transport post-upgrade before they start
            // their own cadence.
            cast(void)sendText("2");

            connected = true;
            return 0;
        } catch (Exception ex) {
            logCurlWebsocketOutput("connect() exception: " ~ ex.msg);
            return -1;
        }
    }

    int sendText(string s) {
        return sendFrame(WS_TEXT, cast(const(ubyte)[])s);
    }

    string recvText() {
        auto fr = readFrame();
        if (fr.rc != 0 || fr.opcode != WS_TEXT) return "";
        auto chars = new char[](fr.payload.length);
        foreach (i; 0 .. fr.payload.length) chars[i] = cast(char)fr.payload[i];
        return cast(string)chars;
    }

private:
    CURL*  h;
    bool   connected;
    string userAgent;
    string httpHostHeader; // includes :port if non-default
    string baseHttpUrl;    // https://host[:port]/
    ParsedUrl pu;

    int connectTimeoutMs;
    int totalTimeoutMs;

    RecvBuf rb;

    private bool websocketUpgradeSameSocket(string pathQueryWs, string cookieLine) {
        auto secKey = b64(randomBytes(16));

        rb.clear();

        string req =
            format("GET %s HTTP/1.1\r\n", pathQueryWs) ~
            format("Host: %s\r\n", httpHostHeader) ~
            "Upgrade: websocket\r\n" ~
            "Connection: Upgrade\r\n" ~
            format("Sec-WebSocket-Key: %s\r\n", secKey) ~
            "Sec-WebSocket-Version: 13\r\n" ~
            "Sec-WebSocket-Extensions: permessage-deflate; client_max_window_bits\r\n" ~
            "Origin: https://graph.microsoft.com\r\n" ~
            "Pragma: no-cache\r\n" ~
            "Cache-Control: no-cache\r\n" ~
            format("User-Agent: %s\r\n", userAgent) ~
            cookieLine ~
            "\r\n";

        logCurlWebsocketOutput(format("sending WS upgrade (%s bytes) …", req.length));
        if (sendAll(cast(const(ubyte)[])req) != 0) {
            logCurlWebsocketOutput("WS upgrade: send failed");
            return false;
        }

        // Read headers
        Appender!(ubyte[]) ab;
        auto start = Clock.currTime(UTC());
        for (;;) {
            if (!rb.ensure(1, 250)) {
                auto elapsed = (Clock.currTime(UTC()) - start).total!"msecs";
                if (elapsed >= 60000) {
                    logCurlWebsocketOutput("HTTP: header read timeout");
                    return false;
                }
                continue;
            }
            auto chunk = rb.takeAll();
            if (chunk.length) ab.put(chunk);
            string s = cast(string)ab.data;
            auto p = s.indexOf("\r\n\r\n");
            if (p >= 0) {
                auto statusEnd = s.indexOf("\r\n");
                if (statusEnd < 0) { logCurlWebsocketOutput("WS upgrade: bad status line"); return false; }
                auto status = s[0 .. cast(size_t)statusEnd];
                auto headersOnly = s[cast(size_t)(statusEnd + 2) .. cast(size_t)p];
                logCurlWebsocketOutput("WS upgrade: status " ~ status);

                auto low = headersOnly.toLower();
                bool hasUpgrade = low.startsWith("upgrade: websocket") || (low.indexOf("\r\nupgrade: websocket") >= 0);
                bool hasConn    = low.startsWith("connection: upgrade") || (low.indexOf("\r\nconnection: upgrade") >= 0);
                bool has101     = (status.indexOf(" 101 ") >= 0);

                // Validate Sec-WebSocket-Accept too
                string acceptGot = "";
                {
                    auto k = "sec-websocket-accept:";
                    auto pos = low.indexOf(k);
                    if (pos >= 0) {
                        pos += k.length;
                        while (pos < low.length && (low[pos] == ' ' || low[pos] == '\t')) ++pos;
                        auto end = low.indexOf("\r\n", pos);
                        if (end < 0) end = low.length;
                        acceptGot = headersOnly[cast(size_t)pos .. cast(size_t)end].strip();
                    }
                }
                auto acceptExpect = wsAcceptForKey(secKey);
                if (!(has101 && hasUpgrade && hasConn && acceptGot == acceptExpect)) {
                    logCurlWebsocketOutput("WS upgrade: header validation failed");
                    logCurlWebsocketOutput("Headers:\n" ~ headersOnly);
                    return false;
                }
                logCurlWebsocketOutput("WS upgrade: complete");

                rb.clear();
                return true;
            }
        }
    }

    private bool waitForTextExact(string expected, int timeoutMs) {
        auto start = Clock.currTime(UTC());
        for (;;) {
            if ((Clock.currTime(UTC()) - start).total!"msecs" >= timeoutMs) return false;
            auto s = recvText();
            if (s.length == 0) { Thread.sleep(dur!"msecs"(10)); continue; }
            if (s == expected) return true;
        }
    }

    private int sendAll(const(ubyte)[] data) {
        size_t off = 0;
        while (off < data.length) {
            size_t n = 0;
            auto rc = curl_easy_send(h, data.ptr + off, data.length - off, &n);
            if (rc == CURLE_OK) {
                off += n;
            } else if (rc == CURLE_AGAIN) {
                sleepMs(5);
            } else {
                logCurlWebsocketOutput("sendAll: curl_easy_send error rc=" ~ to!string(rc));
                return -1;
            }
        }
        logCurlWebsocketOutput(format("send: wrote %s bytes, total=%s/%s", data.length, data.length, data.length));
        return 0;
    }

    private struct FrameResult {
        int    rc;      // 0 ok
        ubyte  opcode;
        ubyte[] payload;
    }

    private FrameResult readFrame() {
        FrameResult fr; fr.rc = -1;

        if (!rb.ensure(2)) return fr;
        auto h2 = rb.take(2);
        if (h2 is null || h2.length < 2) return fr;

        ubyte b0 = h2[0];
        ubyte b1 = h2[1];
        fr.opcode = cast(ubyte)(b0 & 0x0F);
        bool masked = (b1 & 0x80) != 0;
        size_t len = (b1 & 0x7F);

        if (len == 126) {
            if (!rb.ensure(2)) return fr;
            auto ext = rb.take(2);
            if (ext is null || ext.length < 2) return fr;
            len = (cast(size_t)ext[0] << 8) | ext[1];
        } else if (len == 127) {
            if (!rb.ensure(8)) return fr;
            auto ext = rb.take(8);
            if (ext is null || ext.length < 8) return fr;
            size_t L = 0;
            foreach (idx, shift; [56,48,40,32,24,16,8,0]) {
                L |= (cast(size_t)ext[idx] << shift);
            }
            len = L;
        }

        ubyte[4] maskKey;
        if (masked) {
            if (!rb.ensure(4)) return fr;
            auto mk = rb.take(4);
            foreach (i; 0 .. 4) maskKey[i] = mk[i];
        }

        if (!rb.ensure(len)) return fr;
        auto pay = rb.take(len);
        fr.payload = new ubyte[](pay.length);
        foreach (i; 0 .. pay.length) fr.payload[i] = pay[i];

        if (masked) {
            maskPayload(fr.payload, maskKey);
        }

        // Auto-handle WS control frames at this layer
        if (fr.opcode == WS_PING) { cast(void)sendFrame(WS_PONG, fr.payload); return readFrame(); }
        if (fr.opcode == WS_PONG) { return readFrame(); }
        if (fr.opcode == WS_CLOSE){ connected = false; return fr; }

        fr.rc = 0;
        return fr;
    }

    int sendFrame(ubyte opcode, const(ubyte)[] payload) {
        Appender!(ubyte[]) wb;
        wb.put(cast(ubyte)(0x80 | opcode)); // FIN + opcode

        size_t len = payload.length;
        if (len < 126) {
            wb.put(cast(ubyte)(0x80 | cast(ubyte)len));
        } else if (len <= 0xFFFF) {
            wb.put(cast(ubyte)(0x80 | 126));
            wb.put(cast(ubyte)((len >> 8) & 0xFF));
            wb.put(cast(ubyte)(len & 0xFF));
        } else {
            wb.put(cast(ubyte)(0x80 | 127));
            foreach (shift; [56,48,40,32,24,16,8,0]) wb.put(cast(ubyte)((len >> shift) & 0xFF));
        }

        auto maskKeyArr = randomBytes(4);
        ubyte[4] maskKey = [ maskKeyArr[0], maskKeyArr[1], maskKeyArr[2], maskKeyArr[3] ];
        foreach (i; 0 .. 4) wb.put(maskKey[i]);

        ubyte[] masked = new ubyte[](payload.length);
        foreach (i; 0 .. payload.length) masked[i] = payload[i];
        maskPayload(masked, maskKey);

        wb.put(masked[]);
        return sendAll(wb.data);
    }
}
