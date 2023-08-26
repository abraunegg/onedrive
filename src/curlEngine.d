// What is this module called?
module curlEngine;

// What does this module require to function?
import std.net.curl;
import etc.c.curl: CurlOption;
import std.datetime;

// What other modules that we have created do we need to import?
import log;

class CurlEngine {
	HTTP http;
	
	this() {	
		http = HTTP();
	}
	
	void initialise(long dnsTimeout, long connectTimeout, long dataTimeout, long operationTimeout, int maxRedirects, bool httpsDebug, string userAgent, bool httpProtocol, long userRateLimit, long protocolVersion) {
		// Curl Timeout Handling
		// libcurl dns_cache_timeout timeout
		http.dnsTimeout = (dur!"seconds"(dnsTimeout));
		// Timeout for HTTPS connections
		http.connectTimeout = (dur!"seconds"(connectTimeout));
		// Data Timeout for HTTPS connections
		http.dataTimeout = (dur!"seconds"(dataTimeout));
		// maximum time any operation is allowed to take
		// This includes dns resolution, connecting, data transfer, etc.
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
			// Downgrade to curl to use HTTP 1.1 for all operations
			log.vlog("Downgrading all HTTP operations to HTTP/1.1 due to user configuration");
			// Downgrade to HTTP 1.1 - yes version = 2 is HTTP 1.1
			http.handle.set(CurlOption.http_version,2);
		} else {
			// Use curl defaults
			log.vdebug("Using Curl defaults for HTTP operational protocol version (potentially HTTP/2)");
		}
		
		// Configure upload / download rate limits if configured
		// 131072 = 128 KB/s - minimum for basic application operations to prevent timeouts
		// A 0 value means rate is unlimited, and is the curl default
		if (userRateLimit > 0) {
			// User configured rate limit
			log.log("User Configured Rate Limit: ", userRateLimit);

			// If user provided rate limit is < 131072, flag that this is too low, setting to the minimum of 131072
			if (userRateLimit < 131072) {
				// user provided limit too low
				log.log("WARNING: User configured rate limit too low for normal application processing and preventing application timeouts. Overriding to default minimum of 131072 (128KB/s)");
				userRateLimit = 131072;
			}

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
		//   Ensure that we ARE reusing connections - setting to 0 ensures that we are reusing connections
		http.handle.set(CurlOption.forbid_reuse,0);
		
		if (httpsDebug) {
			// Output what options we are using so that in the debug log this can be tracked
			log.vdebug("http.dnsTimeout = ", dnsTimeout);
			log.vdebug("http.connectTimeout = ", connectTimeout);
			log.vdebug("http.dataTimeout = ", dataTimeout);
			log.vdebug("http.operationTimeout = ", operationTimeout);
			log.vdebug("http.maxRedirects = ", maxRedirects);
		}
	}
	
	void setMethodPost(){
		http.method = HTTP.Method.post;
	}
	
	void setMethodPatch(){
		http.method = HTTP.Method.patch;
	}
}