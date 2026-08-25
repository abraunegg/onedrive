// What is this module called?
module curlEngine;

// What does this module require to function?
import std.net.curl;
import etc.c.curl;
import std.datetime;
import std.conv;
import std.file;
import std.format;
import std.json;
import std.stdio;
import std.range;
import core.sys.posix.signal;
// Required for WebSocket Support
import core.stdc.stdlib : getenv;
import core.stdc.string : strcmp;
import core.sys.posix.dlfcn : dlopen, dlsym, dlclose, RTLD_NOW; // Posix elements
import std.exception : enforce;     // for enforce(...)

// What other modules that we have created do we need to import?
import log;
import util;

// WebSocket check elements
enum CURL_WS_MIN_NUM = 0x075600; // 7.86.0 (version which WebSocket support was added to cURL)

extern (C) void sigpipeHandler(int signum) {
	// Custom handler to ignore SIGPIPE signals
	addLogEntry("ERROR: Handling a cURL SIGPIPE signal despite CURLOPT_NOSIGNAL being set (cURL Operational Bug) ...");
}

// Function pointer types matching libcurl WebSocket (WS) API
extern(C) struct curl_ws_frame {
	uint age;
	uint flags;
	size_t len;
	size_t offset;
	size_t bytesleft;
}

// WebSocket alias
alias PFN_curl_ws_recv =
	extern(C) CURLcode function(CURL*, void*, size_t, size_t*, const curl_ws_frame**);
alias PFN_curl_ws_send =
	extern(C) CURLcode function(CURL*, const void*, size_t, size_t*, long /*curl_off_t*/, uint);

extern(C) struct curl_slist { char* data; curl_slist* next; }
extern(C) curl_slist* curl_slist_append(curl_slist* list, const char* string);
extern(C) void curl_slist_free_all(curl_slist* list);

// Shared pool of CurlEngine instances accessible across all threads
__gshared CurlEngine[] curlEnginePool; // __gshared is used to declare a variable that is shared across all threads

private __gshared {
	void*                 _curlLib;
	PFN_curl_ws_recv      p_curl_ws_recv;
	PFN_curl_ws_send      p_curl_ws_send;
	bool                  _wsSymbolsReady;
	uint                  _wsProbeOnce; // 0=not run, 1=success, 2=fail
}

private void* loadCurlLib() {
	// Respect LD_LIBRARY_PATH etc.
	auto h = dlopen("libcurl.so.4", RTLD_NOW);
	if (h is null) h = dlopen("libcurl.so", RTLD_NOW);
	return h;
}

private void* findSymbol(const(char)* name) {
	return dlsym(_curlLib, name);
}

private bool probeCurlWsSymbols() {
	if (_wsProbeOnce == 1) return _wsSymbolsReady;
	if (_wsProbeOnce == 2) return false;

	// 1) libcurl version check
	auto vi = curl_version_info(CURLVERSION_NOW);
	if (vi is null || vi.version_num < CURL_WS_MIN_NUM) {
		_wsProbeOnce = 2; _wsSymbolsReady = false; return false;
	}

	// 2) load libcurl and resolve symbols
	_curlLib = loadCurlLib();
	if (_curlLib is null) {
		_wsProbeOnce = 2; _wsSymbolsReady = false; return false;
	}

	p_curl_ws_recv = cast(PFN_curl_ws_recv) findSymbol("curl_ws_recv");
	p_curl_ws_send = cast(PFN_curl_ws_send) findSymbol("curl_ws_send");

	_wsSymbolsReady = (p_curl_ws_recv !is null) && (p_curl_ws_send !is null);
	_wsProbeOnce = _wsSymbolsReady ? 1 : 2;
	return _wsSymbolsReady;
}

bool curlSupportsWebSockets() {
	return probeCurlWsSymbols();
}

class CurlResponse {
	HTTP.Method method;
	const(char)[] url;
	const(char)[][const(char)[]] requestHeaders;
	const(char)[] postBody;

	bool hasResponse;
	string[string] responseHeaders;
	HTTP.StatusLine statusLine;
	char[] content;

	// Streamed download hash metadata. These values are populated only when
	// curlEngine.download() receives a complete file from byte zero. Resumed
	// downloads intentionally leave these disabled because only the remaining
	// byte range is streamed through the receive callback.
	bool hasStreamedQuickXorHash;
	string streamedQuickXorHash;
	ulong streamedHashBytes;

	this() {
		reset();
	}
	
	~this() {
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
		hasStreamedQuickXorHash = false;
		streamedQuickXorHash = "";
		streamedHashBytes = 0;
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
			if (debugLogging) {addLogEntry("JSON Exception caught when performing HTTP operations - use --debug-https to diagnose further", ["debug"]);}
		}
		return json;
	};

	void update(HTTP *http) {
		hasResponse = true;
		this.responseHeaders = http.responseHeaders();
		this.statusLine = http.statusLine;
		
		// has 'microsoftDataCentre' been set yet?
		if (microsoftDataCentre.empty) {
			// Extract the 'x-ms-ags-diagnostic' header if it exists
			if ("x-ms-ags-diagnostic" in this.responseHeaders) {
				// try and extract the data centre details
				try {
					// attempt to extract the data centre location from the header
					auto diagHeaderData = parseJSON(this.responseHeaders["x-ms-ags-diagnostic"]);
					string dataCentre = diagHeaderData["ServerInfo"]["DataCenter"].str;
					// set the Microsoft Data Centre value
					microsoftDataCentre = dataCentre;
				} catch (Exception e) {
					// do nothing
				}	
			}
		}
				
		// Output the response headers only if using debug mode + debugging https itself
		if ((debugLogging) && (debugHTTPSResponse)) {
			addLogEntry("HTTP Response Headers: " ~ to!string(this.responseHeaders), ["debug"]);
			addLogEntry("HTTP Status Line: " ~ to!string(this.statusLine), ["debug"]);
		}
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
			if (debugLogging) {
				addLogEntry("curlEngine.http.perform() => Received a 'Retry-After' Header Response with the following value: " ~ to!string(responseHeaders["retry-after"]), ["debug"]);
				addLogEntry("curlEngine.http.perform() => Setting retryAfterValue to: " ~ responseHeaders["retry-after"], ["debug"]);
			}
			delayBeforeRetry = to!int(responseHeaders["retry-after"]);
		} else {
			// Use a 120 second delay as a default given header value was zero
			// This value is based on log files and data when determining correct process for 429 response handling
			delayBeforeRetry = 120;
			// Update that we are over-riding the provided value with a default
			if (debugLogging) {addLogEntry("HTTP Response Header retry-after value was missing - Using a preconfigured default of: " ~ to!string(delayBeforeRetry), ["debug"]);}
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

// When a request body is supplied to libcurl via a read callback, libcurl requires a seek
// callback in order to rewind that body if the request has to be sent again - for example when
// the server drops the connection after the body has already been sent. Without a seek callback
// the body cannot be replayed, and libcurl fails the transfer with CURLE_SEND_FAIL_REWIND (65).
//
// That failure is not transient. Every subsequent attempt fails immediately having transferred
// zero bytes, so a single file can prevent synchronisation from ever completing.
// https://github.com/abraunegg/onedrive/issues/3789
// https://curl.se/libcurl/c/CURLOPT_SEEKFUNCTION.html
extern (C) int curlUploadSeekCallback(void* userData, long offset, int origin) nothrow {
	// Only SEEK_SET is required by libcurl in order to rewind a request body
	if (origin != CurlSeekPos.set) {
		return CurlSeek.cantseek;
	}

	// Retrieve the CurlEngine instance that was supplied via CurlOption.seekdata
	CurlEngine curlEngineInstance = cast(CurlEngine) userData;
	if (curlEngineInstance is null) {
		return CurlSeek.cantseek;
	}

	// Reposition the upload so that the request body can be sent again
	return curlEngineInstance.repositionUploadFile(offset);
}

class CurlEngine {

	HTTP http;
	File uploadFile;
	CurlResponse response;
	bool keepAlive;
	ulong dnsTimeout;
	string internalThreadId;
	SysTime releaseTimestamp;
	ulong maxIdleTime;
	private long resumeFromOffset = -1;
	// Position within the file at which the current request body begins. This is zero for a
	// whole-file upload, and the fragment offset when uploading part of a file.
	// https://github.com/abraunegg/onedrive/issues/3789
	private long uploadBodyBaseOffset = 0;
	// An in-memory request body, as used by post() and patch(), together with how much of it has
	// been sent. Retaining these allows the body to be replayed if libcurl has to send the
	// request again.
	// https://github.com/abraunegg/onedrive/issues/3789
	private const(char)[] requestBodyData;
	private size_t requestBodyOffset = 0;
	private bool uploadStreamHashActive = false;
	private QuickXorStreamHasher uploadQuickXorStreamHasher;
	private ulong uploadStreamHashBytes = 0;
	
	this() {
		http = HTTP();   // Directly initializes HTTP using its default constructor
		response = null; // Initialize as null
		internalThreadId = generateAlphanumericString(); // Give this CurlEngine instance a unique ID
		if ((debugLogging) && (debugHTTPSResponse)) {addLogEntry("Created new CurlEngine instance id: " ~ to!string(internalThreadId), ["debug"]);}
	}

	// The destructor should only clean up resources owned directly by this CurlEngine instance
	~this() {
		// Is the file still open?
		if (uploadFile.isOpen()) {
			uploadFile.close();
		}
		// Is 'response' cleared?
		object.destroy(response); // Destroy, then set to null
		response = null;
		// Is the actual http instance is stopped?
		if (!http.isStopped) {
			http.shutdown();
		}
		// Make sure this HTTP instance is destroyed
		object.destroy(http);
		// ThreadId needs to be set to null
		internalThreadId = null;
	}
		
	// We are releasing a curl instance back to the pool
	void releaseEngine() {
		// Set timestamp of release
		releaseTimestamp = Clock.currTime(UTC());
		// Log that we are releasing this engine back to the pool
		if ((debugLogging) && (debugHTTPSResponse)) {
			addLogEntry("CurlEngine releaseEngine() called on instance id: " ~ to!string(internalThreadId), ["debug"]);
			addLogEntry("CurlEngine curlEnginePool size before release: " ~ to!string(curlEnginePool.length), ["debug"]);
			string engineReleaseMessage = format("Release Timestamp for CurlEngine %s: %s", to!string(internalThreadId), to!string(releaseTimestamp));
			addLogEntry(engineReleaseMessage, ["debug"]);
		}
		
		// cleanup this curl instance before putting it back in the pool
		cleanup(true); // Cleanup instance by resetting values and flushing cookie cache
		synchronized (CurlEngine.classinfo) {
			curlEnginePool ~= this;
			if ((debugLogging) && (debugHTTPSResponse)) {addLogEntry("CurlEngine curlEnginePool size after release: " ~ to!string(curlEnginePool.length), ["debug"]);}
		}
	}
	
	// Setup a specific SIGPIPE Signal handler due to curl bugs that ignore CurlOption.nosignal
	void setupSIGPIPESignalHandler() {
		// Setup the signal handler
		sigaction_t curlAction;
		curlAction.sa_handler = &sigpipeHandler; // Direct function pointer assignment
		sigaction(SIGPIPE, &curlAction, null); // Broken Pipe signal from curl
	}
	
	// Initialise this curl instance
	void initialise(ulong dnsTimeout, ulong connectTimeout, ulong dataTimeout, ulong operationTimeout, int maxRedirects, bool httpsDebug, string userAgent, bool httpProtocol, ulong userRateLimit, ulong protocolVersion, ulong maxIdleTime, bool keepAlive=true) {
		// There are many broken curl versions being used, mainly provided by Ubuntu
		// Ignore SIGPIPE to prevent the application from exiting without reason with an exit code of 141 when bad curl version generate this signal despite being told not to (CurlOption.nosignal) below
		setupSIGPIPESignalHandler();
		
		// Setting 'keepAlive' to false ensures that when we close the curl instance, any open sockets are closed - which we need to do when running 
		// multiple threads and API instances at the same time otherwise we run out of local files | sockets pretty quickly
		this.keepAlive = keepAlive;
		
		// Curl DNS Timeout Handling
		this.dnsTimeout = dnsTimeout;

		// Curl Timeout Handling
		this.maxIdleTime = maxIdleTime;
		
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
			if ((debugLogging) && (debugHTTPSResponse)) {
				addLogEntry("http.dnsTimeout = " ~ to!string(dnsTimeout), ["debug"]);
				addLogEntry("http.connectTimeout = " ~ to!string(connectTimeout), ["debug"]);
				addLogEntry("http.dataTimeout = " ~ to!string(dataTimeout), ["debug"]);
				addLogEntry("http.operationTimeout = " ~ to!string(operationTimeout), ["debug"]);
				addLogEntry("http.maxRedirects = " ~ to!string(maxRedirects), ["debug"]);
				addLogEntry("http.CurlOption.ipresolve = " ~ to!string(protocolVersion), ["debug"]);
				addLogEntry("http.header.Connection.keepAlive = " ~ to!string(keepAlive), ["debug"]);
			}
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
			// Retain the request body and track how much of it has been sent, rather than
			// consuming the data as it is sent. If libcurl has to send the request again, for
			// example when the connection is dropped after the body has already been sent, the
			// body must still be available in order to be replayed.
			// https://github.com/abraunegg/onedrive/issues/3789
			requestBodyData = sendData;
			requestBodyOffset = 0;

			http.contentLength = sendData.length;
			http.onSend = (void[] buf) {
				import std.algorithm: min;
				size_t remaining = requestBodyData.length - requestBodyOffset;
				size_t minLen = min(buf.length, remaining);
				if (minLen == 0) return 0;
				buf[0 .. minLen] = cast(void[]) requestBodyData[requestBodyOffset .. requestBodyOffset + minLen];
				requestBodyOffset += minLen;
				return minLen;
			};

			// Allow libcurl to rewind this request body should the request need to be sent
			// again. Without this the transfer fails with CURLE_SEND_FAIL_REWIND, which affects
			// token acquisition as well as data requests.
			// https://github.com/abraunegg/onedrive/issues/3789
			http.handle.set(CurlOption.seekdata, cast(void*) this);
			http.handle.set(CurlOption.seekfunction, cast(void*) &curlUploadSeekCallback);

			response.postBody = sendData;
		}
	}

	void setFile(string filepath, string contentRange, ulong offset, ulong offsetSize) {
		setResponseHolder(null);
		// open file as read-only in binary mode
		uploadFile = File(filepath, "rb");

		if (contentRange.empty) {
			offsetSize = uploadFile.size();
			// The request body is the whole file, so it begins at the start of the file
			uploadBodyBaseOffset = 0;
		} else {
			addRequestHeader("Content-Range", contentRange);
			uploadFile.seek(offset);
			// The request body is a fragment, so it begins at the fragment offset rather than
			// at the start of the file. This is needed to rewind the body correctly.
			uploadBodyBaseOffset = to!long(offset);
		}

		// Allow libcurl to rewind the request body should the request need to be sent again,
		// for example if the server drops the connection after the body has been sent. Without
		// this the transfer fails with CURLE_SEND_FAIL_REWIND and cannot recover.
		// https://github.com/abraunegg/onedrive/issues/3789
		http.handle.set(CurlOption.seekdata, cast(void*) this);
		http.handle.set(CurlOption.seekfunction, cast(void*) &curlUploadSeekCallback);

		// The streamed QuickXorHash is accumulated across an entire file as each fragment of a
		// session upload is sent, and is only restarted for the fragment at offset zero. If this
		// request is a re-send, for example because a transient error caused the fragment to be
		// retried, then the data that is about to be read has already been passed through the
		// hasher once, and the accumulated hash no longer represents the file being uploaded.
		//
		// The number of bytes hashed so far should always equal the offset of the fragment now
		// being sent. Where it does not, the hash is out of step with the data being sent.
		//
		// Data already added to a streaming hash cannot be removed from it, so rather than
		// reporting an integrity failure for a file that has in fact uploaded correctly, the
		// streamed hash is discarded here. The upload is then validated using the existing
		// fallback, which obtains the hash of the local file directly.
		// https://github.com/abraunegg/onedrive/issues/3790
		if (uploadStreamHashActive && (uploadStreamHashBytes != offset)) {
			if (debugLogging) {
				addLogEntry("Streamed QuickXorHash is not aligned with the data being sent (hashed " ~ to!string(uploadStreamHashBytes) ~ " bytes, sending from offset " ~ to!string(offset) ~ ") - discarding the streamed hash for this upload", ["debug"]);
			}
			uploadStreamHashActive = false;
			uploadStreamHashBytes = 0;
		}

		// Setup progress bar to display
		http.onProgress = delegate int(size_t dltotal, size_t dlnow, size_t ultotal, size_t ulnow) {
			return 0;
		};
		
		addRequestHeader("Content-Type", "application/octet-stream");
		http.onSend = (void[] data) {
			auto bytesRead = uploadFile.rawRead(data);
			if (uploadStreamHashActive && (bytesRead.length > 0)) {
				uploadQuickXorStreamHasher.update(cast(ubyte[]) bytesRead);
				uploadStreamHashBytes += bytesRead.length;
			}
			return bytesRead.length;
		};
		http.contentLength = offsetSize;
	}

	// Reposition the file being uploaded so that libcurl is able to replay the request body.
	// Returns a CurlSeek value indicating whether the reposition was possible.
	// https://github.com/abraunegg/onedrive/issues/3789
	private int repositionUploadFile(long offset) nothrow {
		try {
			// An in-memory request body, as used by post() and patch(). This covers token
			// acquisition, which is otherwise unable to recover from a dropped connection.
			if (!uploadFile.isOpen()) {
				if (requestBodyData is null) {
					// There is no request body that can be replayed
					return CurlSeek.cantseek;
				}
				if ((offset < 0) || (offset > cast(long) requestBodyData.length)) {
					// The requested position is not within the request body
					return CurlSeek.cantseek;
				}
				requestBodyOffset = cast(size_t) offset;
				return CurlSeek.ok;
			}

			// The offset supplied by libcurl is relative to the start of the request body. When
			// uploading a fragment the body does not begin at the start of the file, so the
			// offset of that fragment must be included.
			uploadFile.seek(uploadBodyBaseOffset + offset);

			// The data being replayed has already been passed through the streamed hasher once,
			// and hashing it a second time would generate a hash that does not match the file
			// that was actually uploaded.
			if (uploadStreamHashActive) {
				if (uploadBodyBaseOffset == 0) {
					// The request body is the whole file, so the streamed hash covers only the
					// data being replayed and can simply be restarted.
					uploadQuickXorStreamHasher.start();
					uploadStreamHashBytes = 0;
				} else {
					// The request body is one fragment of a larger file, and the streamed hash
					// also covers the fragments that were sent before it. Those contributions
					// cannot be removed from the hash, so the streamed hash can no longer be
					// relied upon. Discard it, so that the upload is validated by other means
					// rather than a false integrity failure being reported for a file that was
					// uploaded correctly.
					uploadStreamHashActive = false;
					uploadStreamHashBytes = 0;
				}
			}

			return CurlSeek.ok;
		} catch (Exception exception) {
			// The file could not be repositioned. Report this to libcurl rather than allowing
			// incorrect data to be sent.
			return CurlSeek.cantseek;
		}
	}

	void beginUploadStreamHash() {
		uploadQuickXorStreamHasher = QuickXorStreamHasher();
		uploadStreamHashBytes = 0;
		uploadStreamHashActive = true;
	}

	void cancelUploadStreamHash() {
		uploadStreamHashActive = false;
		uploadStreamHashBytes = 0;
	}

	void finishUploadStreamHash(CurlResponse uploadResponse = null) {
		if (!uploadStreamHashActive) {
			return;
		}

		if (uploadResponse !is null) {
			response = uploadResponse;
		} else {
			setResponseHolder(null);
		}

		response.streamedQuickXorHash = uploadQuickXorStreamHasher.finishB64();
		response.hasStreamedQuickXorHash = true;
		response.streamedHashBytes = uploadStreamHashBytes;
		cancelUploadStreamHash();
	}
	
	void setZeroContentLength() {
		// Explicit HTTP semantics
		http.contentLength = 0;
		addRequestHeader("Content-Length", to!string(0));
		
		// Force libcurl POST-with-empty-body semantics
		// This prevents libcurl from attempting to read from stdin when performing a POST with no payload.
		http.handle.set(CurlOption.postfields, "");
		http.handle.set(CurlOption.postfieldsize, 0L);
		
		// Defensive: ensure we are NOT in upload/read-callback mode
		http.handle.set(CurlOption.upload, 0);
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

	CurlResponse download(string downloadFilename, bool delegate(int) shouldAcceptResponseBody = null) {
		setResponseHolder(null);
		
		// Open the file in append mode if resuming, else write mode
		auto file = (resumeFromOffset > 0)
			? File(downloadFilename, "ab") // append binary
			: File(downloadFilename, "wb"); // write binary

		// Function exit scope
		scope(exit) {
			cleanup();
			if (file.isOpen()){
				// close open file
				file.close();
			}
		}
		
		// Apply Range header if resuming
		if (resumeFromOffset > 0) {
			string rangeHeader = format("bytes=%d-", resumeFromOffset);
			addRequestHeader("Range", rangeHeader);
		}

		// Streaming hashes are only valid when this download starts at byte zero.
		// For resumed downloads, the receive callback only sees the remaining byte
		// range, so callers must continue to use the existing full-file fallback.
		bool enableStreamedHash = (resumeFromOffset <= 0);
		QuickXorStreamHasher quickXorStreamHasher;
		ulong streamedHashBytes = 0;
		
		// Only persist response bodies that the caller considers valid download
		// responses. This prevents HTTP error bodies from contaminating a valid
		// resumable partial file before the higher-level retry/error handler runs.
		bool acceptResponseBody = true;
		if (shouldAcceptResponseBody !is null) {
			http.onReceiveStatusLine = (HTTP.StatusLine statusLine) {
				acceptResponseBody = shouldAcceptResponseBody(statusLine.code);
			};
		}

		// Receive data
		http.onReceive = (ubyte[] data) {
			if (acceptResponseBody) {
				if (enableStreamedHash) {
					quickXorStreamHasher.update(data);
					streamedHashBytes += data.length;
				}
				file.rawWrite(data);
			}
			return data.length;
		};
		
		// Perform HTTP Operation
		http.perform();
		
		// close open file before returning control to the caller
		if (file.isOpen()){
			file.close();
		}

		// Update response and return response. Promotion of the temporary download
		// into the final destination is deliberately owned by the API layer after
		// HTTP response validation has completed.
		response.update(&http);
		if (enableStreamedHash) {
			response.streamedQuickXorHash = quickXorStreamHasher.finishB64();
			response.hasStreamedQuickXorHash = true;
			response.streamedHashBytes = streamedHashBytes;
		}

		// Return the response which now has the file hash generated from the download stream
		if (debugLogging) {addLogEntry("response.streamedQuickXorHash = " ~ response.streamedQuickXorHash, ["debug"]);}
		return response;
	}

	// Cleanup this instance internal variables that may have been set
	void cleanup(bool flushCookies = false) {
		// Reset any values to defaults, freeing any set objects
		if ((debugLogging) && (debugHTTPSResponse)) {addLogEntry("CurlEngine cleanup() called on instance id: " ~ to!string(internalThreadId), ["debug"]);}
		
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

		// Remove the seek callback and the reference to this instance that was provided to
		// libcurl. This instance is returned to the curl engine pool and reused, so the
		// callback must not be left referring to an upload that has been completed.
		// https://github.com/abraunegg/onedrive/issues/3789
		if (!http.isStopped) {
			http.handle.set(CurlOption.seekfunction, cast(void*) null);
			http.handle.set(CurlOption.seekdata, cast(void*) null);
		}
		uploadBodyBaseOffset = 0;
		requestBodyData = null;
		requestBodyOffset = 0;

		// close file if open
		if (uploadFile.isOpen()){
			// close open file
			uploadFile.close();
		}
	}

	// Shut down the curl instance & close any open sockets
	void shutdownCurlHTTPInstance() {
		// Log that we are attempting to shutdown this curl instance
		if ((debugLogging) && (debugHTTPSResponse)) {addLogEntry("CurlEngine shutdownCurlHTTPInstance() called on instance id: " ~ to!string(internalThreadId), ["debug"]);}
		
		// Is this curl instance is stopped?
		if (!http.isStopped) {
			if ((debugLogging) && (debugHTTPSResponse)) {
				addLogEntry("HTTP instance still active: " ~ to!string(internalThreadId), ["debug"]);
				addLogEntry("HTTP instance isStopped state before http.shutdown(): " ~ to!string(http.isStopped), ["debug"]);
			}
			http.shutdown();
			if ((debugLogging) && (debugHTTPSResponse)) {addLogEntry("HTTP instance isStopped state post http.shutdown(): " ~ to!string(http.isStopped), ["debug"]);}
			object.destroy(http); // Destroy, however we cant set to null
			if ((debugLogging) && (debugHTTPSResponse)) {addLogEntry("HTTP instance shutdown and destroyed: " ~ to!string(internalThreadId), ["debug"]);}
			
		} else {
			// Already stopped .. destroy it
			object.destroy(http); // Destroy, however we cant set to null
			if ((debugLogging) && (debugHTTPSResponse)) {addLogEntry("Stopped HTTP instance shutdown and destroyed: " ~ to!string(internalThreadId), ["debug"]);}
		}
	}
	
	// Disable SSL certificate peer verification for libcurl operations.
	//
	// This function disables the verification of the SSL peer's certificate
	// by setting CURLOPT_SSL_VERIFYPEER to 0. This means that libcurl will
	// accept any certificate presented by the server, regardless of whether
	// it is signed by a trusted certificate authority.
	//
	// -------------------------------------------------------------------------------------
	// WARNING: Disabling SSL peer verification introduces significant security risks:
	// -------------------------------------------------------------------------------------
	// - Man-in-the-Middle (MITM) attacks become trivially possible.
	// - Malicious servers can impersonate trusted endpoints.
	// - Confidential data (authentication tokens, file contents) can be intercepted.
	// - Violates industry security standards and regulatory compliance requirements.
	// - Should never be used in production environments or on untrusted networks.
	//
	// This option should only be enabled for internal testing, debugging self-signed
	// certificates, or explicitly controlled environments with known risks.
	//
	// See also:
	// https://curl.se/libcurl/c/CURLOPT_SSL_VERIFYPEER.html
	void setDisableSSLVerifyPeer() {
		// Emit a runtime warning if debug logging is enabled
		if (debugLogging) {
			addLogEntry("WARNING: SSL peer verification has been DISABLED!", ["debug"]);
			addLogEntry("         This allows invalid or self-signed certificates to be accepted.", ["debug"]);
			addLogEntry("         Use ONLY for testing. This severely weakens HTTPS security.", ["debug"]);
		}

		// Disable SSL certificate verification (DANGEROUS)
		http.handle.set(CurlOption.ssl_verifypeer, 0);
	}
	
	// Enable SSL Certificate Verification
	void setEnableSSLVerifyPeer() {
		// Enable SSL certificate verification
		addLogEntry("Enabling SSL peer verification");
		http.handle.set(CurlOption.ssl_verifypeer, 1);
	}
	
	// Set an applicable resumable offset point when downloading a file
	void setDownloadResumeOffset(long offset) {
		resumeFromOffset = offset;
	}
	
	// reset resumable offset point to negative value
	void resetDownloadResumeOffset() {
		resumeFromOffset = -1;
	}
}

// Methods to control obtaining and releasing a CurlEngine instance from the curlEnginePool

// Get a curl instance for the OneDrive API to use
CurlEngine getCurlInstance() {
	if ((debugLogging) && (debugHTTPSResponse)) {addLogEntry("CurlEngine getCurlInstance() called", ["debug"]);}
	
	synchronized (CurlEngine.classinfo) {
		// What is the current pool size
		if ((debugLogging) && (debugHTTPSResponse)) {addLogEntry("CurlEngine curlEnginePool current size: " ~ to!string(curlEnginePool.length), ["debug"]);}
	
		if (curlEnginePool.empty) {
			if ((debugLogging) && (debugHTTPSResponse)) {addLogEntry("CurlEngine curlEnginePool is empty - constructing a new CurlEngine instance", ["debug"]);}
			return new CurlEngine;  // Constructs a new CurlEngine with a fresh HTTP instance
		} else {
			CurlEngine curlEngine = curlEnginePool[$ - 1];
			curlEnginePool.popBack(); // assumes a LIFO (last-in, first-out) usage pattern
			
			// Is this engine stopped?
			if (curlEngine.http.isStopped) {
				// return a new curl engine as a stopped one cannot be used
				if ((debugLogging) && (debugHTTPSResponse)) {addLogEntry("CurlEngine was in a stopped state (not usable) - constructing a new CurlEngine instance", ["debug"]);}
				return new CurlEngine;  // Constructs a new CurlEngine with a fresh HTTP instance
			} else {
				// When was this engine last used?
				auto elapsedTime = Clock.currTime(UTC()) - curlEngine.releaseTimestamp;
				if ((debugLogging) && (debugHTTPSResponse)) {
					string engineIdleMessage = format("CurlEngine %s time since last use: %s", to!string(curlEngine.internalThreadId), to!string(elapsedTime));
					addLogEntry(engineIdleMessage, ["debug"]);
				}
				
				// If greater than 120 seconds (default), the treat this as a stale engine, preventing:
				// 	* Too old connection (xxx seconds idle), disconnect it
				// 	* Connection 0 seems to be dead!
				// 	* Closing connection 0
				
				if (elapsedTime > dur!"seconds"(curlEngine.maxIdleTime)) {
					// Too long idle engine, clean it up and create a new one
					if ((debugLogging) && (debugHTTPSResponse)) {
						string curlTooOldMessage = format("CurlEngine idle for > %d seconds .... destroying and returning a new curl engine instance", curlEngine.maxIdleTime);
						addLogEntry(curlTooOldMessage, ["debug"]);
					}
					
					curlEngine.cleanup(true); // Cleanup instance by resetting values and flushing cookie cache
					curlEngine.shutdownCurlHTTPInstance();  // Assume proper cleanup of any resources used by HTTP
					if ((debugLogging) && (debugHTTPSResponse)) {addLogEntry("Returning NEW curlEngine instance", ["debug"]);}
					return new CurlEngine;  // Constructs a new CurlEngine with a fresh HTTP instance
				} else {
					// return an existing curl engine
					if ((debugLogging) && (debugHTTPSResponse)) {
						addLogEntry("CurlEngine was in a valid state - returning existing CurlEngine instance", ["debug"]);
						addLogEntry("Using CurlEngine instance ID: " ~ curlEngine.internalThreadId, ["debug"]);
					}
				
					// return the existing engine
					return curlEngine;
				}
			}
		}
	}
}

// Release all CurlEngine instances
void releaseAllCurlInstances() {
	if ((debugLogging) && (debugHTTPSResponse)) {addLogEntry("CurlEngine releaseAllCurlInstances() called", ["debug"]);}
	synchronized (CurlEngine.classinfo) {
		// What is the current pool size
		if ((debugLogging) && (debugHTTPSResponse)) {addLogEntry("CurlEngine curlEnginePool size to release: " ~ to!string(curlEnginePool.length), ["debug"]);}
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
				object.destroy(curlEngineInstance); // Destroy, then set to null
				curlEngineInstance = null;
				// Log release
				if ((debugLogging) && (debugHTTPSResponse)) {addLogEntry("CurlEngine destroyed", ["debug"]);}
			}
		
		}

		// Drop the pool backing allocation as well as its logical contents. The
		// pool is rebuilt on demand during the next monitor loop.
		curlEnginePool = null;
	}
	// Log that all curl engines have been released
	if ((debugLogging) && (debugHTTPSResponse)) {addLogEntry("CurlEngine releaseAllCurlInstances() completed", ["debug"]);}
}

// Return how many curl engines there are
ulong curlEnginePoolLength() {
	return curlEnginePool.length;
}