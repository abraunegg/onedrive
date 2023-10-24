// What is this module called?
module curlEngine;

// What does this module require to function?
import std.net.curl;
import etc.c.curl: CurlOption;
import std.datetime;
import std.conv;
import std.file;
import std.json;
import std.stdio;

// What other modules that we have created do we need to import?
import log;


class CurlResponse {
	char[] content;
	bool debugResponse;
	string[string] responseHeaders;
	HTTP.StatusLine status;

	this(bool debugResponse) {
		this.debugResponse = debugResponse;
	}

	JSONValue json() {
		JSONValue json;
		try {
			json = content.parseJSON();
		} catch (JSONException e) {
			// Log that a JSON Exception was caught, dont output the HTML response from OneDrive
			log.vdebug("JSON Exception caught when performing HTTP operations - use --debug-https to diagnose further");
		}
		if (debugResponse){
			log.vdebug("OneDrive API Response: ", json);
        }
		return json;
	};

	void update(HTTP *http) {
		this.responseHeaders = http.responseHeaders();
		this.status = http.statusLine;
		if (debugResponse)
			log.vdebug("curlEngine.http.perform() => HTTP Response Headers: ", responseHeaders);
	}

	@safe pure HTTP.StatusLine getStatus() {
		return this.status;
	}

	// Return the current value of retryAfterValue
	ulong getRetryAfterValue() {
		ulong delayBeforeRetry;
		// is retry-after in the response headers
		if ("retry-after" in responseHeaders) {
			// Set the retry-after value
			log.vdebug("curlEngine.http.perform() => Received a 'Retry-After' Header Response with the following value: ", responseHeaders["retry-after"]);
			log.vdebug("curlEngine.http.perform() => Setting retryAfterValue to: ", responseHeaders["retry-after"]);
			delayBeforeRetry = to!ulong(responseHeaders["retry-after"]);
		} else {
			// Use a 120 second delay as a default given header value was zero
			// This value is based on log files and data when determining correct process for 429 response handling
			delayBeforeRetry = 120;
			// Update that we are over-riding the provided value with a default
			log.vdebug("HTTP Response Header retry-after value was 0 - Using a preconfigured default of: ", delayBeforeRetry);
		}
		
		return delayBeforeRetry; // default to 60 seconds
	}
}

class CurlEngine {
	HTTP http;
	bool keepAlive;
	bool debugResponse;
	
	this() {	
		http = HTTP();
	}
	
	void initialise(long dnsTimeout, long connectTimeout, long dataTimeout, long operationTimeout, int maxRedirects, bool httpsDebug, string userAgent, bool httpProtocol, long userRateLimit, long protocolVersion, bool debugResponse, bool keepAlive=false) {
		//   Setting this to false ensures that when we close the curl instance, any open sockets are closed - which we need to do when running 
		//   multiple threads and API instances at the same time otherwise we run out of local files | sockets pretty quickly
		this.debugResponse = debugResponse;
		this.keepAlive = keepAlive;

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
			log.vdebug("http.dnsTimeout = ", dnsTimeout);
			log.vdebug("http.connectTimeout = ", connectTimeout);
			log.vdebug("http.dataTimeout = ", dataTimeout);
			log.vdebug("http.operationTimeout = ", operationTimeout);
			log.vdebug("http.maxRedirects = ", maxRedirects);
			log.vdebug("http.CurlOption.ipresolve = ", protocolVersion);
			log.vdebug("http.header.Connection.keepAlive = ", keepAlive);
		}
	}

	void connect(HTTP.Method method, const(char)[] url) {
		if (!keepAlive)
			http.addRequestHeader("Connection", "close");
		http.method = method;
		http.url = url;
	}

	void setContent(const(char)[] contentType, const(void)[] sendData) {
		http.addRequestHeader("Content-Type", contentType);
		if (sendData) {
			http.contentLength = sendData.length;
			http.onSend = (void[] buf) {
				import std.algorithm: min;
				size_t minLen = min(buf.length, sendData.length);
				if (minLen == 0) return 0;
				buf[0 .. minLen] = sendData[0 .. minLen];
				sendData = sendData[minLen .. $];
				return minLen;
			};
		}
	}

	void setFile(File* file, ulong offsetSize) {
		http.addRequestHeader("Content-Type", "application/octet-stream");
		http.onSend = data => file.rawRead(data).length;
		http.contentLength = offsetSize;
	}

	CurlResponse execute() {
		scope(exit) {
			cleanUp();
		}
		CurlResponse response = new CurlResponse(debugResponse);
		http.onReceive = (ubyte[] data) {
			response.content ~= data;
			// HTTP Server Response Code Debugging if --https-debug is being used
			if (debugResponse) {
				log.vdebug("onedrive.performHTTPOperation() => OneDrive HTTP Server Response: ", http.statusLine.code);
			}
			return data.length;
		};
		http.perform();
		response.update(&http);
		return response;
	}

	void cleanUp() {
		// Reset any values to defaults, freeing any set objects
		http.clearRequestHeaders();
		http.onSend = null;
		http.onReceive = null;
		http.onReceiveHeader = null;
		http.onReceiveStatusLine = null;
		http.onProgress = delegate int(size_t dltotal, size_t dlnow, size_t ultotal, size_t ulnow) {
			return 0;
		};
		http.contentLength = 0;
	}

	void shutdown() {
		cleanUp();
		// Shut down the curl instance & close any open sockets
		http.shutdown();
	}
	
	void setDisableSSLVerifyPeer() {
		log.vdebug("Switching off CurlOption.ssl_verifypeer");
		http.handle.set(CurlOption.ssl_verifypeer, 0);
	}
}