// What is this module called?
module curlWebsockets;

/******************************************************************************
 * Minimal RFC6455 WebSocket client over libcurl (CONNECT_ONLY).
 ******************************************************************************/

// What does this module require to function?
import etc.c.curl : CURL, CURLcode, curl_easy_cleanup, curl_easy_getinfo,
	curl_easy_init, curl_easy_perform, curl_easy_recv, curl_easy_reset,
	curl_easy_send, curl_easy_setopt, curl_global_cleanup, curl_global_init;

import core.stdc.string : memcpy, memmove;
import core.time        : MonoTime, dur;
import std.array        : Appender, appender;
import std.base64       : Base64;
import std.meta         : AliasSeq;
import std.random       : Random, unpredictableSeed, uniform;
import std.range        : empty;
import std.string       : indexOf, startsWith, toLower, toStringz;
import std.exception    : collectException;
import std.conv;

// What other modules that we have created do we need to import?
import log;

// ========== Logging Shim ==========
private void logCurlWebsocketOutput(string s) {
	if (debugLogging) {
		collectException(addLogEntry("WEBSOCKET: " ~ s, ["debug"]));
	}
}

private struct WsFrame {
	ubyte fin;
	ubyte opcode;
	bool  masked;
	ulong payloadLen;
	ubyte[4] maskKey;
	ubyte[] payload;
}

final class CurlWebSocket {

private:
	// libcurl constants defined locally
	enum long CURL_GLOBAL_DEFAULT = 3;
	enum int  CURLOPT_URL               = 10002;
	enum int  CURLOPT_FOLLOWLOCATION    = 52;
	enum int  CURLOPT_NOSIGNAL          = 99;
	enum int  CURLOPT_USERAGENT         = 10018;
	enum int  CURLOPT_SSL_VERIFYPEER    = 64;
	enum int  CURLOPT_SSL_VERIFYHOST    = 81;
	enum int  CURLOPT_CONNECT_ONLY      = 141;
	enum int  CURLOPT_TIMEOUT_MS        = 155;
	enum int  CURLOPT_CONNECTTIMEOUT_MS = 156;
	enum int  CURLOPT_VERBOSE           = 41;
	
	// Additional constants needed for WebSocket handling
	enum int  CURLOPT_HTTP_VERSION      = 84;   // CURLOPT_HTTP_VERSION
	enum int  CURLOPT_SSL_ENABLE_ALPN   = 226;  // CURLOPT_SSL_ENABLE_ALPN
	enum int  CURLOPT_SSL_ENABLE_NPN    = 225;  // CURLOPT_SSL_ENABLE_NPN

	// HTTP version flags (for CURLOPT_HTTP_VERSION)
	enum long CURL_HTTP_VERSION_NONE           = 0;
	enum long CURL_HTTP_VERSION_1_0            = 1;
	enum long CURL_HTTP_VERSION_1_1            = 2;
	enum long CURL_HTTP_VERSION_2_0            = 3;
	enum long CURL_HTTP_VERSION_2TLS           = 4;
	enum long CURL_HTTP_VERSION_2_PRIOR_KNOWLEDGE = 5;
	enum long CURL_HTTP_VERSION_3              = 30; // (added in curl 7.66.0+)

	CURL*   curl = null;
	bool    websocketConnected = false;
	int     connectTimeoutMs   = 10000;
	int     ioTimeoutMs        = 15000;
	string  userAgent          = "";
	bool    httpsDebug         = false;
	string  scheme;
	string  host;
	int     port;
	string  hostPort;
	string  pathQuery;
	ubyte[] recvBuf;
	Random  rng;

public:
	this() {
		websocketConnected = false;
		curl = curl_easy_init();
		rng = Random(unpredictableSeed);
		logCurlWebsocketOutput("Created a new instance of a CurlWebSocket object accessing libcurl for HTTP operations");
	}

	~this() {
		if (curl !is null) {
			curl_easy_cleanup(curl);
			curl = null;
		}
		websocketConnected = false;
		logCurlWebsocketOutput("Cleaned-up an instance of a CurlWebSocket object accessing libcurl for HTTP operations");
    }

	bool isConnected() {
		return websocketConnected;
	}

	void setTimeouts(int connectMs, int rwMs) {
		this.connectTimeoutMs = connectMs;
		this.ioTimeoutMs = rwMs;
	}

	void setUserAgent(string ua) {
		if (!ua.empty) userAgent = ua;
	}

	void setHTTPSDebug(bool httpsDebug) {
		this.httpsDebug = httpsDebug;
	}

	int connect(string wsUrl) {
		if (curl is null) {
			logCurlWebsocketOutput("libcurl handle not initialised");
			return -1;
		}

		ParsedUrl p = parseWsUrl(wsUrl);
		if (!p.ok) {
			logCurlWebsocketOutput("Invalid WebSocket URL: " ~ wsUrl);
			return -2;
		}
		scheme    = p.scheme;
		host      = p.host;
		port      = p.port;
		hostPort  = p.hostPort;
		pathQuery = p.pathQuery;

		string connectUrl = (scheme == "wss" ? "https://" : "http://") ~ hostPort ~ pathQuery;
		
		// Reset
		curl_easy_reset(curl);
		// Configure curl options
		curl_easy_setopt(curl, cast(int)CURLOPT_NOSIGNAL,           1L);
		curl_easy_setopt(curl, cast(int)CURLOPT_FOLLOWLOCATION,     1L);
		curl_easy_setopt(curl, cast(int)CURLOPT_USERAGENT,          userAgent.toStringz);   // NUL-terminated
		curl_easy_setopt(curl, cast(int)CURLOPT_CONNECTTIMEOUT_MS,  cast(long)connectTimeoutMs);
		curl_easy_setopt(curl, cast(int)CURLOPT_TIMEOUT_MS,         cast(long)ioTimeoutMs);
		curl_easy_setopt(curl, cast(int)CURLOPT_SSL_VERIFYPEER,     1L);
		curl_easy_setopt(curl, cast(int)CURLOPT_SSL_VERIFYHOST,     2L);
		curl_easy_setopt(curl, cast(int)CURLOPT_CONNECT_ONLY,       1L);
		curl_easy_setopt(curl, cast(int)CURLOPT_URL,                connectUrl.toStringz);  // NUL-terminated
		
		// Force HTTP/1.1 and disable ALPN/NPN
		curl_easy_setopt(curl, cast(int)CURLOPT_SSL_ENABLE_ALPN,    0L);
		curl_easy_setopt(curl, cast(int)CURLOPT_SSL_ENABLE_NPN,     0L);
		curl_easy_setopt(curl, cast(int)CURLOPT_HTTP_VERSION,       CURL_HTTP_VERSION_1_1);
				
		// Do we enable HTTPS Debugging?
		if (httpsDebug) {
			// Enable curl verbosity
			curl_easy_setopt(curl, cast(int)CURLOPT_VERBOSE,        1L);
		} else {
			// Disable curl verbosity
			curl_easy_setopt(curl, cast(int)CURLOPT_VERBOSE,        0L);
		}

		auto rc = curl_easy_perform(curl);
		if (rc != 0) {
			logCurlWebsocketOutput("libcurl connect failed");
			return -3;
		}

		auto req = buildUpgradeRequest();
		if (sendAll(req) != 0) {
			logCurlWebsocketOutput("Failed sending HTTP upgrade request");
			return -4;
		}

		// Read headers until CRLFCRLF, with deadline (don’t treat 0-bytes as EOF).
		string hdrs;
		enum maxHdr = 16 * 1024;
		auto deadline = MonoTime.currTime + dur!"seconds"(10);
		{
			ubyte[4096] tmp;
			size_t total;
			for (;;) {
				int got = recvSome(tmp[]);
				if (got < 0) {
					logCurlWebsocketOutput("Failed receiving HTTP upgrade response");
					return -5;
				}
				if (got == 0) {
					if (MonoTime.currTime >= deadline) {
						logCurlWebsocketOutput("Timeout waiting for HTTP upgrade response");
						return -6;
					}
					continue;
				}
				hdrs ~= cast(const(char)[]) tmp[0 .. cast(size_t)got];
				total += cast(size_t)got;
				auto pos = hdrs.indexOf("\r\n\r\n");
				if (pos >= 0) {
					auto remain = hdrs[(cast(size_t)pos + 4) .. hdrs.length];
					if (remain.length > 0) {
						auto ru = cast(const(ubyte)[]) remain;
						size_t old = recvBuf.length;
						recvBuf.length = old + ru.length;
						memcpy(recvBuf.ptr + old, ru.ptr, ru.length);
					}
					hdrs = hdrs[0 .. cast(size_t)pos];
					break;
				}
				if (total > maxHdr) {
					logCurlWebsocketOutput("HTTP upgrade headers too large");
					return -7;
				}
			}
		}

		{
			auto firstLineEnd = hdrs.indexOf("\r\n");
			string statusLine = firstLineEnd > 0 ? hdrs[0 .. cast(size_t)firstLineEnd] : hdrs;
			if (statusLine.indexOf("101") < 0) {
				logCurlWebsocketOutput("HTTP upgrade failed; status line: " ~ statusLine);
				return -8;
			}
			auto low = hdrs.toLower();
			if (low.indexOf("upgrade: websocket") < 0 || low.indexOf("connection: upgrade") < 0) {
				logCurlWebsocketOutput("HTTP upgrade missing expected headers");
				return -9;
			}
		}

		// Log that protocol switch confirmed, upgraded to RFC6455
		logCurlWebsocketOutput("Received HTTP 101 Switching Protocols confirmed; Upgraded to RFC6455");
		websocketConnected = true;
		return 0;
	}

	int close(ushort code = 1000, string reason = "") {
		logCurlWebsocketOutput("Running curlWebsocket close()");
		if (!websocketConnected) return 0;
		logCurlWebsocketOutput("Running curlWebsocket close() - websocketConnected = true");

		// Build close payload: 2 bytes status code (network order) + optional reason
		ubyte[] pay;
		pay.length = 2 + reason.length;
		pay[0] = cast(ubyte)((code >> 8) & 0xFF);
		pay[1] = cast(ubyte)(code & 0xFF);
		foreach (i; 0 .. reason.length) pay[2 + i] = cast(ubyte)reason[i];

		auto frame = encodeFrame(0x8, pay); // opcode 0x8 = Close
		auto rc = sendAll(frame);
		// Even if sending fails, cleanup below so we don’t leak.
		collectException(logCurlWebsocketOutput("Sending RFC6455 Close (code=" ~ to!string(code) ~ ")"));
		// Clean up curl handle
		if (curl !is null) {
			curl_easy_cleanup(curl);
			curl = null;
		}
		websocketConnected = false;
		return rc;
	}

	int sendText(string payload) {
		if (!websocketConnected) return -1;
		auto frame = encodeFrame(0x1, cast(const(ubyte)[])payload);
		return sendAll(frame);
	}

	string recvText() {
		if (!websocketConnected) return "";

		for (;;) {
			auto f = tryParseFrame();
			if (f.opcode == 0xFF) {
				ubyte[4096] tmp;
				int got = recvSome(tmp[]);
				if (got <= 0) return "";
				size_t old = recvBuf.length;
				recvBuf.length = old + cast(size_t)got;
				memcpy(recvBuf.ptr + old, tmp.ptr, cast(size_t)got);
				continue;
			}

			if (f.opcode == 0x1) {
				return cast(string) f.payload;
			} else if (f.opcode == 0x9) {
				auto pong = encodeFrame(0xA, f.payload);
				auto _ = sendAll(pong);
				continue;
			} else if (f.opcode == 0xA) {
				continue;
			} else if (f.opcode == 0x8) {
				websocketConnected = false;
				return "";
			} else {
				continue;
			}
		}
	}

private:
	struct ParsedUrl {
		bool   ok;
		string scheme;
		string host;
		int    port;
		string hostPort;
		string pathQuery;
	}

	static int parsePortDec(string s) {
		if (s.length == 0) return 0;
		int v = 0;
		foreach (ch; s) {
			if (ch < '0' || ch > '9') return 0;
			v = v * 10 + (cast(int)ch - cast(int)'0');
			if (v > 65535) return 0;
		}
		return v;
	}

	ParsedUrl parseWsUrl(string u) {
		ParsedUrl p;
		p.ok = false;
		auto sidx = u.indexOf("://");
		if (sidx <= 0) return p;
		string sc   = u[0 .. cast(size_t)sidx];
		string rest = u[(cast(size_t)sidx + 3) .. u.length];
		auto scl = sc.toLower();
		if (scl == "ws")  p.scheme = "ws";
		else if (scl == "wss") p.scheme = "wss";
		else return p;

		auto slash = rest.indexOf("/");
		string hostport;
		if (slash < 0) {
			hostport = rest;
			p.pathQuery = "/";
		} else {
			hostport = rest[0 .. cast(size_t)slash];
			p.pathQuery = rest[cast(size_t)slash .. rest.length];
		}

		auto col = hostport.indexOf(":");
		if (col >= 0) {
			p.host = hostport[0 .. cast(size_t)col];
			string ps = hostport[(cast(size_t)col + 1) .. hostport.length];

			int prt = parsePortDec(ps);
			if (prt == 0) return p;

			p.port = prt;
			p.hostPort = p.host ~ ":" ~ to!string(p.port);
		} else {
			p.host = hostport;
			p.port = (p.scheme == "wss") ? 443 : 80;
			p.hostPort = p.host;
		}

		if (p.pathQuery.length == 0 || p.pathQuery[0] != '/') p.pathQuery = "/" ~ p.pathQuery;

		p.ok = true;
		return p;
	}

	string buildUpgradeRequest() {
		// Sec-WebSocket-Key: random 16 bytes, base64
		ubyte[16] keyBytes;
		foreach (i; 0 .. 16) keyBytes[i] = cast(ubyte) uniform(0, 256, rng);
		auto keyB64 = Base64.encode(keyBytes[]);

		// Origin header (some proxies expect it)
		string origin = (scheme == "wss" ? "https://" : "http://") ~ host;

		string req  = "GET " ~ pathQuery ~ " HTTP/1.1\r\n";
		req ~= "Host: " ~ hostPort ~ "\r\n";
		req ~= "User-Agent: " ~ userAgent ~ "\r\n";
		req ~= "Upgrade: websocket\r\n";
		req ~= "Connection: Upgrade\r\n";
		req ~= "Sec-WebSocket-Version: 13\r\n";
		req ~= "Sec-WebSocket-Key: " ~ keyB64 ~ "\r\n";
		req ~= "Origin: " ~ origin ~ "\r\n";
		req ~= "\r\n";
		return req;
	}

	int sendAll(const(char)[] data) {
		size_t sent = 0;
		while (sent < data.length) {
			size_t now = 0;
			auto rc = curl_easy_send(curl, cast(void*)(data.ptr + sent), data.length - sent, &now);
			if (rc != 0 && now == 0) return -1;
			sent += now;
		}
		return 0;
	}

	int sendAll(const(ubyte)[] data) {
		size_t sent = 0;
		while (sent < data.length) {
			size_t now = 0;
			auto rc = curl_easy_send(curl, cast(void*)(data.ptr + sent), data.length - sent, &now);
			if (rc != 0 && now == 0) return -1;
			sent += now;
		}
		return 0;
	}

	int recvSome(ubyte[] buf) {
		size_t got = 0;
		auto rc = curl_easy_recv(curl, cast(void*)buf.ptr, buf.length, &got);
		if (rc != 0) return 0; // treat EAGAIN etc. as "no bytes now"
		return cast(int)got;
	}

	ubyte[] encodeFrame(ubyte opcode, const(ubyte)[] payload) {
		Appender!(ubyte[]) outp = appender!(ubyte[])();
		outp.reserve(2 + 4 + payload.length + 8);

		ubyte b0 = cast(ubyte)(0x80 | (opcode & 0x0F)); // FIN=1
		outp.put(b0);

		ubyte maskBit = 0x80;
		ulong len = cast(ulong)payload.length;

		if (len <= 125) {
			outp.put(cast(ubyte)(maskBit | cast(ubyte)len));
		} else if (len <= 0xFFFF) {
			outp.put(cast(ubyte)(maskBit | 126));
			outp.put(cast(ubyte)((len >> 8) & 0xFF));
			outp.put(cast(ubyte)(len & 0xFF));
		} else {
			outp.put(cast(ubyte)(maskBit | 127));
			foreach (shift; AliasSeq!(56, 48, 40, 32, 24, 16, 8, 0)) {
				outp.put(cast(ubyte)((len >> shift) & 0xFF));
			}
		}

		ubyte[4] key;
		foreach (i; 0 .. 4) key[i] = cast(ubyte) uniform(0, 256, rng);
		outp.put(key[]);

		auto masked = new ubyte[payload.length];
		foreach (i; 0 .. payload.length) masked[i] = payload[i] ^ key[i % 4];
		outp.put(masked[]);

		return outp.data;
	}

	WsFrame tryParseFrame() {
		WsFrame f;
		f.opcode = 0xFF;

		if (recvBuf.length < 2) return f;

		size_t i = 0;
		ubyte b0 = recvBuf[i]; i += 1;
		ubyte b1 = recvBuf[i]; i += 1;

		bool fin = (b0 & 0x80) != 0;
		ubyte opcode = cast(ubyte)(b0 & 0x0F);
		bool masked = (b1 & 0x80) != 0;
		ulong len = cast(ulong)(b1 & 0x7F);

		if (len == 126) {
			if (recvBuf.length < i + 2) return f;
			len = (cast(ulong)recvBuf[i] << 8) | cast(ulong)recvBuf[i + 1];
			i += 2;
		} else if (len == 127) {
			if (recvBuf.length < i + 8) return f;
			len = 0;
			foreach (shift; AliasSeq!(56, 48, 40, 32, 24, 16, 8, 0)) {
				len |= (cast(ulong)recvBuf[i] << shift);
				i += 1;
			}
		}

		ubyte[4] key;
		if (masked) {
			if (recvBuf.length < i + 4) return f;
			foreach (k; 0 .. 4) key[k] = recvBuf[i + k];
			i += 4;
		}

		if (recvBuf.length < i + cast(size_t)len) return f;

		auto start = i;
		auto end   = i + cast(size_t)len;
		auto raw   = recvBuf[start .. end];

		ubyte[] data;
		if (masked) {
			data = new ubyte[raw.length];
			foreach (idx; 0 .. raw.length) data[idx] = raw[idx] ^ key[idx % 4];
		} else {
			data = raw.dup;
		}

		auto consumed  = end;
		auto remainLen = recvBuf.length - consumed;
		if (remainLen > 0) {
			memmove(recvBuf.ptr, recvBuf.ptr + consumed, remainLen);
		}
		recvBuf.length = remainLen;

		f.fin        = fin ? 1 : 0;
		f.opcode     = opcode;
		f.masked     = masked;
		f.payloadLen = len;
		f.maskKey    = key;
		f.payload    = data;
		return f;
	}
}
