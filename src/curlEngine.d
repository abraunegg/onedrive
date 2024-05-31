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
import core.memory;

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
			logBuffer.addLogEntry("JSON Exception caught when performing HTTP operations - use --debug-https to diagnose further", ["debug"]);
		}
		return json;
	};

	void update(HTTP *http) {
		hasResponse = true;
		this.responseHeaders = http.responseHeaders();
		this.statusLine = http.statusLine;
		logBuffer.addLogEntry("HTTP Response Headers: " ~ to!string(this.responseHeaders), ["debug"]);
		logBuffer.addLogEntry("HTTP Status Line: " ~ to!string(this.statusLine), ["debug"]);
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
			logBuffer.addLogEntry("curlEngine.http.perform() => Received a 'Retry-After' Header Response with the following value: " ~ to!string(responseHeaders["retry-after"]), ["debug"]);
			logBuffer.addLogEntry("curlEngine.http.perform() => Setting retryAfterValue to: " ~ responseHeaders["retry-after"], ["debug"]);
			delayBeforeRetry = to!int(responseHeaders["retry-after"]);
		} else {
			// Use a 120 second delay as a default given header value was zero
			// This value is based on log files and data when determining correct process for 429 response handling
			delayBeforeRetry = 120;
			// Update that we are over-riding the provided value with a default
			logBuffer.addLogEntry("HTTP Response Header retry-after value was missing - Using a preconfigured default of: " ~ to!string(delayBeforeRetry), ["debug"]);
		}
		return delayBeforeRetry;
	}
	
	const string parseRequestHeaders(const(const(char)[][const(char)[]]) headers) {
		string requestHeadersStr = "";
		// Ensure response headers is not null and iterate over keys safely.
		if (headers !is null) {
			foreach (string header; headers.byKey()) {
				if (header == "Authorization") {
					continue;
				}
				// Use the 'in' operator to safely check if the key exists in the associative array.
				if (auto val = header in headers) {
					requestHeadersStr ~= "< " ~ header ~ ": " ~ *val ~ "\n";
				}
			}
		}
		return requestHeadersStr;
	}

	const string parseResponseHeaders(const(string[string]) headers) {
		string responseHeadersStr = "";
		// Ensure response headers is not null and iterate over keys safely.
		if (headers !is null) {
			foreach (string header; headers.byKey()) {
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
			response = null;
		}
		
		// Is the actual http instance is stopped?
		if (!http.isStopped) {
			// HTTP instance was not stopped .. we need to stop it
			http.shutdown();
			object.destroy(http); // Destroy, however we cant set to null
		}
    }
		
	// Get a curl instance for the OneDrive API to use
	static CurlEngine getCurlInstance() {
		logBuffer.addLogEntry("CurlEngine getCurlInstance() called", ["debug"]);
		
		synchronized (CurlEngine.classinfo) {
			// What is the current pool size
			logBuffer.addLogEntry("CurlEngine curlEnginePool current size: " ~ to!string(curlEnginePool.length), ["debug"]);
		
			if (curlEnginePool.empty) {
				logBuffer.addLogEntry("CurlEngine curlEnginePool is empty - constructing a new CurlEngine instance", ["debug"]);
				return new CurlEngine;  // Constructs a new CurlEngine with a fresh HTTP instance
			} else {
				CurlEngine curlEngine = curlEnginePool[$ - 1];
				curlEnginePool.popBack(); // assumes a LIFO (last-in, first-out) usage pattern
				
				// Is this engine stopped?
				if (curlEngine.http.isStopped) {
					// return a new curl engine as a stopped one cannot be used
					logBuffer.addLogEntry("CurlEngine was in a stoppped state (not usable) - constructing a new CurlEngine instance", ["debug"]);
					return new CurlEngine;  // Constructs a new CurlEngine with a fresh HTTP instance
				} else {
					// return an existing curl engine
					logBuffer.addLogEntry("CurlEngine was in a valid state - returning existing CurlEngine instance", ["debug"]);
					logBuffer.addLogEntry("CurlEngine instance ID: " ~ curlEngine.internalThreadId, ["debug"]);
					return curlEngine;
				}
			}
		}
	}
	
	// Release all curl instances
	static void releaseAllCurlInstances() {
		logBuffer.addLogEntry("CurlEngine releaseAllCurlInstances() called", ["debug"]);
		synchronized (CurlEngine.classinfo) {
			// What is the current pool size
			logBuffer.addLogEntry("CurlEngine curlEnginePool size to release: " ~ to!string(curlEnginePool.length), ["debug"]);
			if (curlEnginePool.length > 0) {
				// Safely iterate and clean up each CurlEngine instance
				foreach (curlEngineInstance; curlEnginePool) {
					try {
						curlEngineInstance.cleanup(true); // Cleanup instance by resetting values and flushing cookie cache
						curlEngineInstance.shutdownCurlHTTPInstance();  // Assume proper cleanup of any resources used by HTTP
					} catch (Exception e) {
						// Log the error or handle it appropriately
						// e.g., writeln("Error during cleanup/shutdown: ", e.toString());
					}
					
					// It's safe to destroy the object here assuming no other references exist
					curlEngineInstance = null;
					// Perform Garbage Collection on this destroyed curl engine
					GC.collect();
				}
            
				// Clear the array after all instances have been handled
				curlEnginePool.length = 0; // More explicit than curlEnginePool = [];
			}
        }
		// Perform Garbage Collection on this destroyed curl engine
		GC.collect();
    }

    // Return how many curl engines there are
	static ulong curlEnginePoolLength() {
		return curlEnginePool.length;
	}
	
	// Destroy all curl instances
	static void destroyAllCurlInstances() {
		logBuffer.addLogEntry("CurlEngine destroyAllCurlInstances() called", ["debug"]);
		// Release all 'curl' instances
		releaseAllCurlInstances();
    }

	// We are releasing a curl instance back to the pool
	void releaseEngine() {
		// Log that we are releasing this engine back to the pool
		logBuffer.addLogEntry("CurlEngine releaseEngine() called on instance id: " ~ to!string(internalThreadId), ["debug"]);
		logBuffer.addLogEntry("CurlEngine curlEnginePool size before release: " ~ to!string(curlEnginePool.length), ["debug"]);
		
		// cleanup this curl instance before putting it back in the pool
		cleanup(true); // Cleanup instance by resetting values and flushing cookie cache
        synchronized (CurlEngine.classinfo) {
            curlEnginePool ~= this;
			logBuffer.addLogEntry("CurlEngine curlEnginePool size after release: " ~ to!string(curlEnginePool.length), ["debug"]);
        }
		// Perform Garbage Collection
		GC.collect();
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
		
		// Explicitly set libcurl options to avoid using signal handlers in a multi-threaded environment
		// See: https://curl.se/libcurl/c/CURLOPT_NOSIGNAL.html
		// The CURLOPT_NOSIGNAL option is intended for use in multi-threaded programs to ensure that libcurl does not use any signal handling.
		// Set CURLOPT_NOSIGNAL to 1 to prevent libcurl from using signal handlers, thus avoiding interference with the application's signal handling which could lead to issues such as unstable behavior or application crashes.
		http.handle.set(CurlOption.nosignal,1);
		
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
			logBuffer.addLogEntry("http.dnsTimeout = " ~ to!string(dnsTimeout), ["debug"]);
			logBuffer.addLogEntry("http.connectTimeout = " ~ to!string(connectTimeout), ["debug"]);
			logBuffer.addLogEntry("http.dataTimeout = " ~ to!string(dataTimeout), ["debug"]);
			logBuffer.addLogEntry("http.operationTimeout = " ~ to!string(operationTimeout), ["debug"]);
			logBuffer.addLogEntry("http.maxRedirects = " ~ to!string(maxRedirects), ["debug"]);
			logBuffer.addLogEntry("http.CurlOption.ipresolve = " ~ to!string(protocolVersion), ["debug"]);
			logBuffer.addLogEntry("http.header.Connection.keepAlive = " ~ to!string(keepAlive), ["debug"]);
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
	void cleanup(bool flushCookies = false) {
		// Reset any values to defaults, freeing any set objects
		logBuffer.addLogEntry("CurlEngine cleanup() called on instance id: " ~ to!string(internalThreadId), ["debug"]);
		
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
			
			// We only do this if we are pushing the curl engine back to the curl pool
			if (flushCookies) {
				// Flush the cookie cache as well
				http.flushCookieJar();
				http.clearSessionCookies();
				http.clearAllCookies();
			}
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
		logBuffer.addLogEntry("CurlEngine shutdownCurlHTTPInstance() called on instance id: " ~ to!string(internalThreadId), ["debug"]);
		
		// Is the instance is stopped?
		if (!http.isStopped) {
			logBuffer.addLogEntry("HTTP instance still active: " ~ to!string(internalThreadId), ["debug"]);
			http.shutdown();
			object.destroy(http); // Destroy, however we cant set to null
			logBuffer.addLogEntry("HTTP instance shutdown and destroyed: " ~ to!string(internalThreadId), ["debug"]);
		} else {
			// Already stopped .. destroy it
			object.destroy(http); // Destroy, however we cant set to null
			logBuffer.addLogEntry("Stopped HTTP instance shutdown and destroyed: " ~ to!string(internalThreadId), ["debug"]);
		}
		// Perform Garbage Collection
		GC.collect();
	}
}