// What is this module called?
module curlEngine;

// What does this module require to function?
import std.net.curl;
import etc.c.curl: CurlOption;
import std.datetime;

// What other modules that we have created do we need to import?
import log;

import std.stdio;

class CurlEngine {
	HTTP http;
	
	this() {	
		http = HTTP();
	}
	
	void initialise(long dnsTimeout, long connectTimeout, long dataTimeout, long operationTimeout, int maxRedirects, bool httpsDebug, string userAgent, bool httpProtocol, long userRateLimit, long protocolVersion, long forbidReuse=1) {
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
		
		//   https://curl.se/libcurl/c/CURLOPT_FORBID_REUSE.html
		//   CURLOPT_FORBID_REUSE - make connection get closed at once after use
		//   Ensure that we ARE NOT reusing TCP sockets connections - setting to 0 ensures that we ARE reusing connections (we did this in v2.4.xx) to ensure connections remained open and usable
		//   Setting this to 1 ensures that when we close the curl instance, any open sockets are closed - which we need to do when running 
		//   multiple threads and API instances at the same time otherwise we run out of local files | sockets pretty quickly
		//   The libcurl default is 1 - ensure we are configuring not to reuse connections and leave unused sockets open
		http.handle.set(CurlOption.forbid_reuse,forbidReuse);
		
		if (httpsDebug) {
			// Output what options we are using so that in the debug log this can be tracked
			log.vdebug("http.dnsTimeout = ", dnsTimeout);
			log.vdebug("http.connectTimeout = ", connectTimeout);
			log.vdebug("http.dataTimeout = ", dataTimeout);
			log.vdebug("http.operationTimeout = ", operationTimeout);
			log.vdebug("http.maxRedirects = ", maxRedirects);
			log.vdebug("http.CurlOption.ipresolve = ", protocolVersion);
			log.vdebug("http.forbid_reuse.forbidReuse = ", forbidReuse);
		}
	}
	
	void setMethodPost() {
		http.method = HTTP.Method.post;
	}
	
	void setMethodPatch() {
		http.method = HTTP.Method.patch;
	}
	
	void setDisableSSLVerifyPeer() {
		log.vdebug("Switching off CurlOption.ssl_verifypeer");
		http.handle.set(CurlOption.ssl_verifypeer, 0);
	}
}