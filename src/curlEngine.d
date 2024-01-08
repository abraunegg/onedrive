// What is this module called?
module curlEngine;

// What does this module require to function?
import std.net.curl;
import etc.c.curl: CurlOption;
import std.datetime;
import std.conv;
import std.stdio;

// What other modules that we have created do we need to import?
import log;

class CurlEngine {
	HTTP http;
	bool keepAlive;
	ulong dnsTimeout;
	
	this() {	
		http = HTTP();
	}
	
	void initialise(ulong dnsTimeout, ulong connectTimeout, ulong dataTimeout, ulong operationTimeout, int maxRedirects, bool httpsDebug, string userAgent, bool httpProtocol, ulong userRateLimit, ulong protocolVersion, bool keepAlive=false) {
		//   Setting this to false ensures that when we close the curl instance, any open sockets are closed - which we need to do when running 
		//   multiple threads and API instances at the same time otherwise we run out of local files | sockets pretty quickly
		this.keepAlive = keepAlive;
		this.dnsTimeout = dnsTimeout;

		// Curl Timeout Handling
		
		// libcurl dns_cache_timeout timeout
		// https://curl.se/libcurl/c/CURLOPT_DNS_CACHE_TIMEOUT.html
		// https://dlang.org/library/std/net/curl/http.dns_timeout.html
		http.dnsTimeout = (dur!"seconds"(dnsTimeout));
		
		// Timeout for HTTPS connections
		// https://curl.se/libcurl/c/CURLOPT_CONNECTTIMEOUT.html
		// https://dlang.org/library/std/net/curl/http.connect_timeout.html
		http.connectTimeout = (dur!"seconds"(connectTimeout));
		
		// Timeout for activity on connection
		// This is a DMD | DLANG specific item, not a libcurl item
		// https://dlang.org/library/std/net/curl/http.data_timeout.html
		// https://raw.githubusercontent.com/dlang/phobos/master/std/net/curl.d - private enum _defaultDataTimeout = dur!"minutes"(2);
		http.dataTimeout = (dur!"seconds"(dataTimeout));
		
		// Maximum time any operation is allowed to take
		// This includes dns resolution, connecting, data transfer, etc.
		// https://curl.se/libcurl/c/CURLOPT_TIMEOUT_MS.html
		// https://dlang.org/library/std/net/curl/http.operation_timeout.html
		http.operationTimeout = (dur!"seconds"(operationTimeout));
		
		// Specify how many redirects should be allowed
		http.maxRedirects(maxRedirects);
		// Debug HTTPS
		http.verbose = httpsDebug;
		// Use the configured 'user_agent' value
		http.setUserAgent = userAgent;
		// What IP protocol version should be used when using Curl - IPv4 & IPv6, IPv4 or IPv6
		http.handle.set(CurlOption.ipresolve,protocolVersion); // 0 = IPv4 + IPv6, 1 = IPv4 Only, 2 = IPv6 Only
		
		// What version of HTTP protocol do we use?
		// Curl >= 7.62.0 defaults to http2 for a significant number of operations
		if (httpProtocol) {
			// Downgrade to HTTP 1.1 - yes version = 2 is HTTP 1.1
			http.handle.set(CurlOption.http_version,2);
		}
		
		// Configure upload / download rate limits if configured
		// 131072 = 128 KB/s - minimum for basic application operations to prevent timeouts
		// A 0 value means rate is unlimited, and is the curl default
		if (userRateLimit > 0) {
			// set rate limit
			http.handle.set(CurlOption.max_send_speed_large,userRateLimit);
			http.handle.set(CurlOption.max_recv_speed_large,userRateLimit);
		}
		
		// Explicitly set these libcurl options
		//   https://curl.se/libcurl/c/CURLOPT_NOSIGNAL.html
		//   Ensure that nosignal is set to 0 - Setting CURLOPT_NOSIGNAL to 0 makes libcurl ask the system to ignore SIGPIPE signals
		http.handle.set(CurlOption.nosignal,0);
		
		//   https://curl.se/libcurl/c/CURLOPT_TCP_NODELAY.html
		//   Ensure that TCP_NODELAY is set to 0 to ensure that TCP NAGLE is enabled
		http.handle.set(CurlOption.tcp_nodelay,0);
		
		if (httpsDebug) {
			// Output what options we are using so that in the debug log this can be tracked
			addLogEntry("http.dnsTimeout = " ~ to!string(dnsTimeout), ["debug"]);
			addLogEntry("http.connectTimeout = " ~ to!string(connectTimeout), ["debug"]);
			addLogEntry("http.dataTimeout = " ~ to!string(dataTimeout), ["debug"]);
			addLogEntry("http.operationTimeout = " ~ to!string(operationTimeout), ["debug"]);
			addLogEntry("http.maxRedirects = " ~ to!string(maxRedirects), ["debug"]);
			addLogEntry("http.CurlOption.ipresolve = " ~ to!string(protocolVersion), ["debug"]);
			addLogEntry("http.header.Connection.keepAlive = " ~ to!string(keepAlive), ["debug"]);
		}
	}

	void connect(HTTP.Method method, const(char)[] url) {
		if (!keepAlive)
			http.addRequestHeader("Connection", "close");
		http.method = method;
		http.url = url;
	}
	
	void setDisableSSLVerifyPeer() {
		addLogEntry("CAUTION: Switching off CurlOption.ssl_verifypeer ... this makes the application insecure.", ["debug"]);
		http.handle.set(CurlOption.ssl_verifypeer, 0);
	}
}