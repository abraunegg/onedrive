// What is this module called?
module curlEngine;

// What does this module require to function?
import std.net.curl;
import etc.c.curl;
import std.datetime;
import std.conv;
import std.file;
import std.json;
import std.stdio;
import std.range;

// What other modules that we have created do we need to import?
import log;
import util;

class CurlResponse {
	HTTP.Method method;
	const(char)[] url;
	const(char)[][const(char)[]] requestHeaders;
	const(char)[] postBody;

	bool hasResponse;
	string[string] responseHeaders;
	HTTP.StatusLine statusLine;
	char[] content;

	this() {
		reset();
	}

	void reset() {
		method = HTTP.Method.undefined;
		url = "";
		requestHeaders = null;
		postBody = [];
		hasResponse = false;
		responseHeaders = null;
		statusLine.reset();
		content = [];
	}

	void addRequestHeader(const(char)[] name, const(char)[] value) {
		requestHeaders[to!string(name)] = to!string(value);
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
		hasResponse = true;
		this.responseHeaders = http.responseHeaders();
		this.statusLine = http.statusLine;
	}

	@safe pure HTTP.StatusLine getStatus() {
		return this.statusLine;
	}

	// Return the current value of retryAfterValue
	int getRetryAfterValue() {
		int delayBeforeRetry;
		// Is 'retry-after' in the response headers
		if ("retry-after" in responseHeaders) {
			// Set the retry-after value
			addLogEntry("curlEngine.http.perform() => Received a 'Retry-After' Header Response with the following value: " ~ to!string(responseHeaders["retry-after"]), ["debug"]);
			addLogEntry("curlEngine.http.perform() => Setting retryAfterValue to: " ~ responseHeaders["retry-after"], ["debug"]);
			delayBeforeRetry = to!int(responseHeaders["retry-after"]);
		} else {
			// Use a 120 second delay as a default given header value was zero
			// This value is based on log files and data when determining correct process for 429 response handling
			delayBeforeRetry = 120;
			// Update that we are over-riding the provided value with a default
			addLogEntry("HTTP Response Header retry-after value was missing - Using a preconfigured default of: " ~ to!string(delayBeforeRetry), ["debug"]);
		}
		return delayBeforeRetry;
	}
	
	const string parseRequestHeaders(const(const(char)[][const(char)[]]) headers) {
		string requestHeadersStr = "";
		foreach (string header; headers.byKey()) {
			if (header == "Authorization") {
				continue;
			}
			// Use the 'in' operator to safely check if the key exists in the associative array.
			if (auto val = header in headers) {
				requestHeadersStr ~= "< " ~ header ~ ": " ~ *val ~ "\n";
			}
		}
		return requestHeadersStr;
	}

	const string parseResponseHeaders(const(immutable(char)[][immutable(char)[]]) headers) {
		string responseHeadersStr = "";
		// Ensure response headers is not null and iterate over keys safely.
		if (headers !is null) {
			foreach (const(char)[] header; headers.byKey()) {
				// Check if the key actually exists before accessing it to avoid RangeError.
				if (auto val = header in headers) { // 'in' checks for the key and returns a pointer to the value if found.
					responseHeadersStr ~= "> " ~ header ~ ": " ~ *val ~ "\n"; // Dereference pointer to get the value.
				}
			}
		}
		return responseHeadersStr;
	}

	const string dumpDebug() {
		import std.range;
		import std.format : format;
		
		string str = "";
		str ~= format("< %s %s\n", method, url);
		if (!requestHeaders.empty) {
			str ~= parseRequestHeaders(requestHeaders);
		}
		if (!postBody.empty) {
			str ~= format("\n----\n%s\n----\n", postBody);
		}
		str ~= format("< %s\n", statusLine);
		if (!responseHeaders.empty) {
			str ~= parseResponseHeaders(responseHeaders);
		}
		return str;
	}

	const string dumpResponse() {
		import std.range;
		import std.format : format;

		string str = "";
		if (!content.empty) {
			str ~= format("\n----\n%s\n----\n", content);
		}
		return str;
	}

	override string toString() const {
		string str = "Curl debugging: \n";
		str ~= dumpDebug();
		if (hasResponse) {
			str ~= "Curl response: \n";
			str ~= dumpResponse();
		}
		return str;
	}
}

class CurlEngine {

	// Shared pool of CurlEngine instances accessible across all threads
	__gshared CurlEngine[] curlEnginePool; // __gshared is used to declare a variable that is shared across all threads
	
	HTTP http;
	File uploadFile;
	CurlResponse response;
	bool keepAlive;
	ulong dnsTimeout;
	string internalThreadId;
	
    this() {
        http = HTTP();   // Directly initializes HTTP using its default constructor
        response = null; // Initialize as null
		internalThreadId = generateAlphanumericString();
    }

	// The destructor should only clean up resources owned directly by this instance
	~this() {
		// Is the file still open?
		if (uploadFile.isOpen()) {
			uploadFile.close();
		}
		
		// Is 'response' cleared?
		if (response !is null) {
			object.destroy(response); // Destroy, then set to null
			response = null;
		}
		
		// Is the actual http instance is stopped?
		if (!http.isStopped) {
			// HTTP instance was not stopped .. need to stop it
			http.shutdown();
			object.destroy(http); // Destroy, however we cant set to null
		}
    }
		
	// Get a curl instance for the OneDrive API to use
	static CurlEngine getCurlInstance() {
		addLogEntry("CurlEngine getCurlInstance() called", ["debug"]);
		
		synchronized (CurlEngine.classinfo) {
			// What is the current pool size
			addLogEntry("CurlEngine curlEnginePool current size: " ~ to!string(curlEnginePool.length), ["debug"]);
		
			if (curlEnginePool.empty) {
				addLogEntry("CurlEngine curlEnginePool is empty - constructing a new CurlEngine instance", ["debug"]);
				return new CurlEngine;  // Constructs a new CurlEngine with a fresh HTTP instance
			} else {
				CurlEngine curlEngine = curlEnginePool[$ - 1];
				curlEnginePool.popBack();
				
				// Is this engine stopped?
				if (curlEngine.http.isStopped) {
					// return a new curl engine as a stopped one cannot be used
					addLogEntry("CurlEngine was in a stoppped state (not usable) - constructing a new CurlEngine instance", ["debug"]);
					return new CurlEngine;  // Constructs a new CurlEngine with a fresh HTTP instance
				} else {
					// return an existing curl engine
					addLogEntry("CurlEngine was in a valid state - returning existing CurlEngine instance", ["debug"]);
					addLogEntry("CurlEngine instance ID: " ~ curlEngine.internalThreadId, ["debug"]);
					return curlEngine;
				}
			}
		}
	}
	
	// Release all curl instances
	static void releaseAllCurlInstances() {
		addLogEntry("CurlEngine releaseAllCurlInstances() called", ["debug"]);
	
		synchronized (CurlEngine.classinfo) {
			// What is the current pool size
			addLogEntry("CurlEngine curlEnginePool size to release: " ~ to!string(curlEnginePool.length), ["debug"]);
			
			// Safely iterate and clean up each CurlEngine instance
			foreach (curlEngineInstance; curlEnginePool) {
                try {
					curlEngineInstance.cleanup(); // Cleanup instance by resetting values
					curlEngineInstance.shutdownCurlHTTPInstance();  // Assume proper cleanup of any resources used by HTTP
                } catch (Exception e) {
					// Log the error or handle it appropriately
					// e.g., writeln("Error during cleanup/shutdown: ", e.toString());
                }
                // It's safe to destroy the object here assuming no other references exist
                object.destroy(curlEngineInstance); // Destroy, then set to null
				curlEngineInstance = null;
            }
            // Clear the array after all instances have been handled
            curlEnginePool.length = 0; // More explicit than curlEnginePool = [];
        }
    }

    // Destroy all curl instances
	static void destroyAllCurlInstances() {
		addLogEntry("CurlEngine destroyAllCurlInstances() called", ["debug"]);
		// Release all 'curl' instances
		releaseAllCurlInstances();
    }

	// We are releasing a curl instance back to the pool
	void releaseEngine() {
		// Log that we are releasing this engine back to the pool
		addLogEntry("CurlEngine releaseEngine() called on instance id: " ~ to!string(internalThreadId), ["debug"]);
		addLogEntry("CurlEngine curlEnginePool size before release: " ~ to!string(curlEnginePool.length), ["debug"]);
		cleanup();
        synchronized (CurlEngine.classinfo) {
            curlEnginePool ~= this;
			addLogEntry("CurlEngine curlEnginePool size after release: " ~ to!string(curlEnginePool.length), ["debug"]);
        }
    }
	
	// Initialise this curl instance
	void initialise(ulong dnsTimeout, ulong connectTimeout, ulong dataTimeout, ulong operationTimeout, int maxRedirects, bool httpsDebug, string userAgent, bool httpProtocol, ulong userRateLimit, ulong protocolVersion, bool keepAlive=true) {
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

	void setResponseHolder(CurlResponse response) {
		if (response is null) {
			// Create a response instance if it doesn't already exist
			if (this.response is null)
				this.response = new CurlResponse();
		} else {
			this.response = response;
		}
	}

	void addRequestHeader(const(char)[] name, const(char)[] value) {
		setResponseHolder(null);
		http.addRequestHeader(name, value);
		response.addRequestHeader(name, value);
	}

	void connect(HTTP.Method method, const(char)[] url) {
		setResponseHolder(null);
		if (!keepAlive)
			addRequestHeader("Connection", "close");
		http.method = method;
		http.url = url;
		response.connect(method, url);
	}

	void setContent(const(char)[] contentType, const(char)[] sendData) {
		setResponseHolder(null);
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

	void setFile(string filepath, string contentRange, ulong offset, ulong offsetSize) {
		setResponseHolder(null);
		// open file as read-only in binary mode
		uploadFile = File(filepath, "rb");

		if (contentRange.empty) {
			offsetSize = uploadFile.size();
		} else {
			addRequestHeader("Content-Range", contentRange);
			uploadFile.seek(offset);
		}

		// Setup progress bar to display
		http.onProgress = delegate int(size_t dltotal, size_t dlnow, size_t ultotal, size_t ulnow) {
			return 0;
		};
		
		addRequestHeader("Content-Type", "application/octet-stream");
		http.onSend = data => uploadFile.rawRead(data).length;
		http.contentLength = offsetSize;
	}

	CurlResponse execute() {
		scope(exit) {
			cleanup();
		}
		setResponseHolder(null);
		http.onReceive = (ubyte[] data) {
			response.content ~= data;
			// HTTP Server Response Code Debugging if --https-debug is being used
			
			return data.length;
		};
		http.perform();
		response.update(&http);
		return response;
	}

	CurlResponse download(string originalFilename, string downloadFilename) {
		setResponseHolder(null);
		// open downloadFilename as write in binary mode
		auto file = File(downloadFilename, "wb");

		// function scopes
		scope(exit) {
			cleanup();
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

	// Cleanup this instance internal variables that may have been set
	void cleanup() {
		// Reset any values to defaults, freeing any set objects
		addLogEntry("CurlEngine cleanup() called on instance id: " ~ to!string(internalThreadId), ["debug"]);
		
		// Is the instance is stopped?
		if (!http.isStopped) {
			// A stopped instance is not usable, these cannot be reset
			http.clearRequestHeaders();
			http.onSend = null;
			http.onReceive = null;
			http.onReceiveHeader = null;
			http.onReceiveStatusLine = null;
			http.onProgress = delegate int(size_t dltotal, size_t dlnow, size_t ultotal, size_t ulnow) {
				return 0;
			};
			http.contentLength = 0;
			http.flushCookieJar();
			http.clearSessionCookies();
			http.clearAllCookies();
		}
		
		// set the response to null
		response = null;

		// close file if open
		if (uploadFile.isOpen()){
			// close open file
			uploadFile.close();
		}
	}

	// Shut down the curl instance & close any open sockets
	void shutdownCurlHTTPInstance() {
		addLogEntry("CurlEngine shutdownCurlHTTPInstance() called on instance id: " ~ to!string(internalThreadId), ["debug"]);
		
		// Is the instance is stopped?
		if (!http.isStopped) {
			addLogEntry("HTTP instance still active: " ~ to!string(internalThreadId), ["debug"]);
			http.shutdown();
			object.destroy(http); // Destroy, however we cant set to null
			addLogEntry("HTTP instance shutdown and destroyed: " ~ to!string(internalThreadId), ["debug"]);
		}
	}
}