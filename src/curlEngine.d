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
	HTTP.Method method;
	const(char)[] url;
	const(char)[][const(char)[]] requestHeaders;
	const(char)[] postBody;

	string[string] responseHeaders;
	HTTP.StatusLine statusLine;
	char[] content;

	void reset() {
		method = HTTP.Method.undefined;
		url = null;
		requestHeaders = null;
		postBody = null;
		
		responseHeaders = null;
		object.destroy(statusLine);
		content = null;
	}

	void addRequestHeader(const(char)[] name, const(char)[] value) {
		requestHeaders[name] = value;
	}

	void connect(HTTP.Method method, const(char)[] url) {
		this.method = method;
		this.url = url;
	}

	const JSONValue json() {
		JSONValue json;
		try {
			json = content.parseJSON();
		} catch (JSONException e) {
			// Log that a JSON Exception was caught, dont output the HTML response from OneDrive
			addLogEntry("JSON Exception caught when performing HTTP operations - use --debug-https to diagnose further", ["debug"]);
		}
		return json;
	};

	void update(HTTP *http) {
		this.responseHeaders = http.responseHeaders();
		this.statusLine = http.statusLine;
	}

	@safe pure HTTP.StatusLine getStatus() {
		return this.statusLine;
	}

	// Return the current value of retryAfterValue
	ulong getRetryAfterValue() {
		ulong delayBeforeRetry;
		// is retry-after in the response headers
		if ("retry-after" in responseHeaders) {
			// Set the retry-after value
			addLogEntry("curlEngine.http.perform() => Received a 'Retry-After' Header Response with the following value: " ~ to!string(responseHeaders["retry-after"]), ["debug"]);
			addLogEntry("curlEngine.http.perform() => Setting retryAfterValue to: " ~ responseHeaders["retry-after"], ["debug"]);
			delayBeforeRetry = to!ulong(responseHeaders["retry-after"]);
		} else {
			// Use a 120 second delay as a default given header value was zero
			// This value is based on log files and data when determining correct process for 429 response handling
			delayBeforeRetry = 120;
			// Update that we are over-riding the provided value with a default
			addLogEntry("HTTP Response Header retry-after value was 0 - Using a preconfigured default of: " ~ to!string(delayBeforeRetry), ["debug"]);
		}
		
		return delayBeforeRetry; // default to 60 seconds
	}

	const string parseHeaders(const(string[string]) headers) {
		string responseHeadersStr = "";
		foreach (const(char)[] header; headers.byKey()) {
			responseHeadersStr ~= "> " ~ header ~ ": " ~ headers[header] ~ "\n";
		}
		return responseHeadersStr;
	}


	const string parseHeaders(const(const(char)[][const(char)[]]) headers) {
		string responseHeadersStr = "";
		foreach (string header; headers.byKey()) {
			if (header == "Authorization")
				continue;
			responseHeadersStr ~= "< " ~ header ~ ": " ~ headers[header] ~ "\n";
		}
		return responseHeadersStr;
	}

	const string dumpDebug() {
		import std.range;
		import std.format : format;
		
		string str = "";
		str ~= format("< %s %s\n", method, url);
		if (!requestHeaders.empty) {
			str ~= parseHeaders(requestHeaders);
		}
		if (!postBody.empty) {
			str ~= format("----\n%s\n----\n", postBody);
		}
		str ~= format("< %s\n", statusLine);
		if (!responseHeaders.empty) {
			str ~= parseHeaders(responseHeaders);
		}
		return str;
	}

	const string dumpResponse() {
		import std.range;
		import std.format : format;

		string str = "";
		if (!content.empty) {
			str ~= format("----\n%s\n----\n", content);
		}
		return str;
	}

	override string toString() const {
		string str = "Curl debugging: \n";
		str ~= dumpDebug();
		str ~= "Curl response: \n";
		str ~= dumpResponse();
		return str;
	}

	CurlResponse dup() {
        CurlResponse copy = new CurlResponse();
		copy.method = method;
		copy.url = url;
		copy.requestHeaders = requestHeaders;
		copy.postBody = postBody;
		
		copy.responseHeaders = responseHeaders;
		copy.statusLine = statusLine;
		copy.content = content;

		return copy;
	}
}

class CurlEngine {
	HTTP http;
	bool keepAlive;
	ulong dnsTimeout;
	CurlResponse response;

	this() {	
		http = HTTP();
	}

	~this() {
		shutdown();
	}
	
	void initialise(ulong dnsTimeout, ulong connectTimeout, ulong dataTimeout, ulong operationTimeout, int maxRedirects, bool httpsDebug, string userAgent, bool httpProtocol, ulong userRateLimit, ulong protocolVersion, bool keepAlive=false) {
		//   Setting this to false ensures that when we close the curl instance, any open sockets are closed - which we need to do when running 
		//   multiple threads and API instances at the same time otherwise we run out of local files | sockets pretty quickly
		this.keepAlive = keepAlive;
		this.dnsTimeout = dnsTimeout;
		this.response = new CurlResponse();

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
		//   Setting this to 0 ensures that we ARE reusing connections (we did this in v2.4.xx) to ensure connections remained open and usable
		//   Setting this to 1 ensures that when we close the curl instance, any open sockets are forced closed when the API curl instance is destroyed
		//   The libcurl default is 0 as per the documentation (to REUSE connections) - ensure we are configuring to reuse sockets
		http.handle.set(CurlOption.forbid_reuse,0);
		
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

	void addRequestHeader(const(char)[] name, const(char)[] value) {
		http.addRequestHeader(name, value);
		response.addRequestHeader(name, value);
	}

	void connect(HTTP.Method method, const(char)[] url) {
		if (!keepAlive)
			addRequestHeader("Connection", "close");
		http.method = method;
		http.url = url;
		response.connect(method, url);
	}

	void setContent(const(char)[] contentType, const(char)[] sendData) {
		addRequestHeader("Content-Type", contentType);
		if (sendData) {
			http.contentLength = sendData.length;
			http.onSend = (void[] buf) {
				import std.algorithm: min;
				size_t minLen = min(buf.length, sendData.length);
				if (minLen == 0) return 0;
				buf[0 .. minLen] = cast(void[]) sendData[0 .. minLen];
				sendData = sendData[minLen .. $];
				return minLen;
			};
			response.postBody = sendData;
		}
	}

	void setFile(File* file, ulong offsetSize) {
		addRequestHeader("Content-Type", "application/octet-stream");
		http.onSend = data => file.rawRead(data).length;
		http.contentLength = offsetSize;
	}

	CurlResponse execute() {
		scope(exit) {
			cleanUp();
		}
		http.onReceive = (ubyte[] data) {
			response.content ~= data;
			// HTTP Server Response Code Debugging if --https-debug is being used
			
			return data.length;
		};
		http.perform();
		response.update(&http);
		return response.dup;
	}

	CurlResponse download(string originalFilename, string downloadFilename) {
		// Threshold for displaying download bar
		long thresholdFileSize = 4 * 2^^20; // 4 MiB
		
		CurlResponse response = new CurlResponse();
		// open downloadFilename as write in binary mode
		auto file = File(downloadFilename, "wb");

		// function scopes
		scope(exit) {
			cleanUp();
			if (file.isOpen()){
				// close open file
				file.close();
			}
		}
		
		http.onReceive = (ubyte[] data) {
			file.rawWrite(data);
			return data.length;
		};
		
		http.perform();
		
		// Rename downloaded file
		rename(downloadFilename, originalFilename);

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
		response.reset();
	}

	void shutdown() {
		// Shut down the curl instance & close any open sockets
		object.destroy(http);
		object.destroy(response);
	}
	
	void setDisableSSLVerifyPeer() {
		addLogEntry("CAUTION: Switching off CurlOption.ssl_verifypeer ... this makes the application insecure.", ["debug"]);
		http.handle.set(CurlOption.ssl_verifypeer, 0);
	}
}