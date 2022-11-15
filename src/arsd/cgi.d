// FIXME: if an exception is thrown, we shouldn't necessarily cache...
// FIXME: there's some annoying duplication of code in the various versioned mains

// add the Range header in there too. should return 206

// FIXME: cgi per-request arena allocator

// i need to add a bunch of type templates for validations... mayne @NotNull or NotNull!

// FIXME: I might make a cgi proxy class which can change things; the underlying one is still immutable
// but the later one can edit and simplify the api. You'd have to use the subclass tho!

/*
void foo(int f, @("test") string s) {}

void main() {
	static if(is(typeof(foo) Params == __parameters))
		//pragma(msg, __traits(getAttributes, Params[0]));
		pragma(msg, __traits(getAttributes, Params[1..2]));
	else
		pragma(msg, "fail");
}
*/

// Note: spawn-fcgi can help with fastcgi on nginx

// FIXME: to do: add openssl optionally
// make sure embedded_httpd doesn't send two answers if one writes() then dies

// future direction: websocket as a separate process that you can sendfile to for an async passoff of those long-lived connections

/*
	Session manager process: it spawns a new process, passing a
	command line argument, to just be a little key/value store
	of some serializable struct. On Windows, it CreateProcess.
	On Linux, it can just fork or maybe fork/exec. The session
	key is in a cookie.

	Server-side event process: spawns an async manager. You can
	push stuff out to channel ids and the clients listen to it.

	websocket process: spawns an async handler. They can talk to
	each other or get info from a cgi request.

	Tempting to put web.d 2.0 in here. It would:
		* map urls and form generation to functions
		* have data presentation magic
		* do the skeleton stuff like 1.0
		* auto-cache generated stuff in files (at least if pure?)
		* introspect functions in json for consumers


	https://linux.die.net/man/3/posix_spawn
*/

/++
	Provides a uniform server-side API for CGI, FastCGI, SCGI, and HTTP web applications.

	---
	import arsd.cgi;

	// Instead of writing your own main(), you should write a function
	// that takes a Cgi param, and use mixin GenericMain
	// for maximum compatibility with different web servers.
	void hello(Cgi cgi) {
		cgi.setResponseContentType("text/plain");

		if("name" in cgi.get)
			cgi.write("Hello, " ~ cgi.get["name"]);
		else
			cgi.write("Hello, world!");
	}

	mixin GenericMain!hello;
	---

	Test on console (works in any interface mode):
	$(CONSOLE
		$ ./cgi_hello GET / name=whatever
	)

	If using http version (default on `dub` builds, or on custom builds when passing `-version=embedded_httpd` to dmd):
	$(CONSOLE
		$ ./cgi_hello --port 8080
		# now you can go to http://localhost:8080/?name=whatever
	)

	Please note: the default port for http is 8085 and for cgi is 4000. I recommend you set your own by the command line argument in a startup script instead of relying on any hard coded defaults. It is possible though to hard code your own with [RequestServer].


	Compile_versions:

	If you are using `dub`, use:

	```sdlang
	subConfiguration "arsd-official:cgi" "VALUE_HERE"
	```

	or to dub.json:

	```json
        	"subConfigurations": {"arsd-official:cgi": "VALUE_HERE"}
	```

	to change versions. The possible options for `VALUE_HERE` are:

	$(LIST
		* `embedded_httpd` for the embedded httpd version (built-in web server). This is the default.
		* `cgi` for traditional cgi binaries.
		* `fastcgi` for FastCGI builds.
		* `scgi` for SCGI builds.
		* `stdio_http` for speaking raw http over stdin and stdout. See [RequestServer.serveSingleHttpConnectionOnStdio] for more information.
	)

	With dmd, use:

	$(TABLE_ROWS

		* + Interfaces
		  + (mutually exclusive)

		* - `-version=plain_cgi`
			- The default building the module alone without dub - a traditional, plain CGI executable will be generated.
		* - `-version=embedded_httpd`
			- A HTTP server will be embedded in the generated executable. This is default when building with dub.
		* - `-version=fastcgi`
			- A FastCGI executable will be generated.
		* - `-version=scgi`
			- A SCGI (SimpleCGI) executable will be generated.

		* - `-version=embedded_httpd_threads`
			- The embedded HTTP server will use a single process with a thread pool. (use instead of plain `embedded_httpd` if you want this specific implementation)
		* - `-version=embedded_httpd_processes`
			- The embedded HTTP server will use a prefork style process pool. (use instead of plain `embedded_httpd` if you want this specific implementation)
		* - `-version=embedded_httpd_processes_accept_after_fork`
			- It will call accept() in each child process, after forking. This is currently the only option, though I am experimenting with other ideas. You probably should NOT specify this right now.
		* - `-version=stdio_http`
			- The embedded HTTP server will be spoken over stdin and stdout.

		* + Tweaks
		  + (can be used together with others)

		* - `-version=cgi_with_websocket`
			- The CGI class has websocket server support.

		* - `-version=with_openssl`
			- not currently used
		* - `-version=cgi_embedded_sessions`
			- The session server will be embedded in the cgi.d server process
		* - `-version=cgi_session_server_process`
			- The session will be provided in a separate process, provided by cgi.d.
	)

	Compile_and_run:

	For CGI, `dmd yourfile.d cgi.d` then put the executable in your cgi-bin directory.

	For FastCGI: `dmd yourfile.d cgi.d -version=fastcgi` and run it. spawn-fcgi helps on nginx. You can put the file in the directory for Apache. On IIS, run it with a port on the command line (this causes it to call FCGX_OpenSocket, which can work on nginx too).

	For SCGI: `dmd yourfile.d cgi.d -version=scgi` and run the executable, providing a port number on the command line.

	For an embedded HTTP server, run `dmd yourfile.d cgi.d -version=embedded_httpd` and run the generated program. It listens on port 8085 by default. You can change this on the command line with the --port option when running your program.

	You can also simulate a request by passing parameters on the command line, like:

	$(CONSOLE
	./yourprogram GET / name=adr
	)

	And it will print the result to stdout.

	CGI_Setup_tips:

	On Apache, you may do `SetHandler cgi-script` in your `.htaccess` file.

	Integration_tips:

	cgi.d works well with dom.d for generating html. You may also use web.d for other utilities and automatic api wrapping.

	dom.d usage:

	---
		import arsd.cgi;
		import arsd.dom;

		void hello_dom(Cgi cgi) {
			auto document = new Document();

			static import std.file;
			// parse the file in strict mode, requiring it to be well-formed UTF-8 XHTML
			// (You'll appreciate this if you've ever had to deal with a missing </div>
			// or something in a php or erb template before that would randomly mess up
			// the output in your browser. Just check it and throw an exception early!)
			//
			// You could also hard-code a template or load one at compile time with an
			// import expression, but you might appreciate making it a regular file
			// because that means it can be more easily edited by the frontend team and
			// they can see their changes without needing to recompile the program.
			//
			// Note on CTFE: if you do choose to load a static file at compile time,
			// you *can* parse it in CTFE using enum, which will cause it to throw at
			// compile time, which is kinda cool too. Be careful in modifying that document,
			// though, as it will be a static instance. You might want to clone on on demand,
			// or perhaps modify it lazily as you print it out. (Try element.tree, it returns
			// a range of elements which you could send through std.algorithm functions. But
			// since my selector implementation doesn't work on that level yet, you'll find that
			// harder to use. Of course, you could make a static list of matching elements and
			// then use a simple e is e2 predicate... :) )
			document.parseUtf8(std.file.read("your_template.html"), true, true);

			// fill in data using DOM functions, so placing it is in the hands of HTML
			// and it will be properly encoded as text too.
			//
			// Plain html templates can't run server side logic, but I think that's a
			// good thing - it keeps them simple. You may choose to extend the html,
			// but I think it is best to try to stick to standard elements and fill them
			// in with requested data with IDs or class names. A further benefit of
			// this is the designer can also highlight data based on sources in the CSS.
			//
			// However, all of dom.d is available, so you can format your data however
			// you like. You can do partial templates with innerHTML too, or perhaps better,
			// injecting cloned nodes from a partial document.
			//
			// There's a lot of possibilities.
			document["#name"].innerText = cgi.request("name", "default name");

			// send the document to the browser. The second argument to `cgi.write`
			// indicates that this is all the data at once, enabling a few small
			// optimizations.
			cgi.write(document.toString(), true);
		}
	---

	Concepts:
		Input: [Cgi.get], [Cgi.post], [Cgi.request], [Cgi.files], [Cgi.cookies], [Cgi.pathInfo], [Cgi.requestMethod],
		       and HTTP headers ([Cgi.headers], [Cgi.userAgent], [Cgi.referrer], [Cgi.accept], [Cgi.authorization], [Cgi.lastEventId])

		Output: [Cgi.write], [Cgi.header], [Cgi.setResponseStatus], [Cgi.setResponseContentType], [Cgi.gzipResponse]

		Cookies: [Cgi.setCookie], [Cgi.clearCookie], [Cgi.cookie], [Cgi.cookies]

		Caching: [Cgi.setResponseExpires], [Cgi.updateResponseExpires], [Cgi.setCache]

		Redirections: [Cgi.setResponseLocation]

		Other Information: [Cgi.remoteAddress], [Cgi.https], [Cgi.port], [Cgi.scriptName], [Cgi.requestUri], [Cgi.getCurrentCompleteUri], [Cgi.onRequestBodyDataReceived]

		Overriding behavior: [Cgi.handleIncomingDataChunk], [Cgi.prepareForIncomingDataChunks], [Cgi.cleanUpPostDataState]

		Installing: Apache, IIS, CGI, FastCGI, SCGI, embedded HTTPD (not recommended for production use)

	Guide_for_PHP_users:
		If you are coming from PHP, here's a quick guide to help you get started:

		$(SIDE_BY_SIDE
			$(COLUMN
				```php
				<?php
					$foo = $_POST["foo"];
					$bar = $_GET["bar"];
					$baz = $_COOKIE["baz"];

					$user_ip = $_SERVER["REMOTE_ADDR"];
					$host = $_SERVER["HTTP_HOST"];
					$path = $_SERVER["PATH_INFO"];

					setcookie("baz", "some value");

					echo "hello!";
				?>
				```
			)
			$(COLUMN
				---
				import arsd.cgi;
				void app(Cgi cgi) {
					string foo = cgi.post["foo"];
					string bar = cgi.get["bar"];
					string baz = cgi.cookies["baz"];

					string user_ip = cgi.remoteAddress;
					string host = cgi.host;
					string path = cgi.pathInfo;

					cgi.setCookie("baz", "some value");

					cgi.write("hello!");
				}

				mixin GenericMain!app
				---
			)
		)

		$(H3 Array elements)


		In PHP, you can give a form element a name like `"something[]"`, and then
		`$_POST["something"]` gives an array. In D, you can use whatever name
		you want, and access an array of values with the `cgi.getArray["name"]` and
		`cgi.postArray["name"]` members.

		$(H3 Databases)

		PHP has a lot of stuff in its standard library. cgi.d doesn't include most
		of these, but the rest of my arsd repository has much of it. For example,
		to access a MySQL database, download `database.d` and `mysql.d` from my
		github repo, and try this code (assuming, of course, your database is
		set up):

		---
		import arsd.cgi;
		import arsd.mysql;

		void app(Cgi cgi) {
			auto database = new MySql("localhost", "username", "password", "database_name");
			foreach(row; mysql.query("SELECT count(id) FROM people"))
				cgi.write(row[0] ~ " people in database");
		}

		mixin GenericMain!app;
		---

		Similar modules are available for PostgreSQL, Microsoft SQL Server, and SQLite databases,
		implementing the same basic interface.

	See_Also:

	You may also want to see [arsd.dom], [arsd.web], and [arsd.html] for more code for making
	web applications.

	For working with json, try [arsd.jsvar].

	[arsd.database], [arsd.mysql], [arsd.postgres], [arsd.mssql], and [arsd.sqlite] can help in
	accessing databases.

	If you are looking to access a web application via HTTP, try [std.net.curl], [arsd.curl], or [arsd.http2].

	Copyright:

	cgi.d copyright 2008-2022, Adam D. Ruppe. Provided under the Boost Software License.

	Yes, this file is old, and yes, it is still actively maintained and used.
+/
module arsd.cgi;

version(Demo)
unittest {

}

static import std.file;

// for a single thread, linear request thing, use:
// -version=embedded_httpd_threads -version=cgi_no_threads

version(Posix) {
	version(CRuntime_Musl) {

	} else version(minimal) {

	} else {
		version(GNU) {
			// GDC doesn't support static foreach so I had to cheat on it :(
		} else version(FreeBSD) {
			// I never implemented the fancy stuff there either
		} else {
			version=with_breaking_cgi_features;
			version=with_sendfd;
			version=with_addon_servers;
		}
	}
}

version(Windows) {
	version(minimal) {

	} else {
		// not too concerned about gdc here since the mingw version is fairly new as well
		version=with_breaking_cgi_features;
	}
}

void cloexec(int fd) {
	version(Posix) {
		import core.sys.posix.fcntl;
		fcntl(fd, F_SETFD, FD_CLOEXEC);
	}
}

void cloexec(Socket s) {
	version(Posix) {
		import core.sys.posix.fcntl;
		fcntl(s.handle, F_SETFD, FD_CLOEXEC);
	}
}

version(embedded_httpd_hybrid) {
	version=embedded_httpd_threads;
	version(cgi_no_fork) {} else version(Posix)
		version=cgi_use_fork;
	version=cgi_use_fiber;
}

version(cgi_use_fork)
	enum cgi_use_fork_default = true;
else
	enum cgi_use_fork_default = false;

// the servers must know about the connections to talk to them; the interfaces are vital
version(with_addon_servers)
	version=with_addon_servers_connections;

version(embedded_httpd) {
	version(linux)
		version=embedded_httpd_processes;
	else {
		version=embedded_httpd_threads;
	}

	/*
	version(with_openssl) {
		pragma(lib, "crypto");
		pragma(lib, "ssl");
	}
	*/
}

version(embedded_httpd_processes)
	version=embedded_httpd_processes_accept_after_fork; // I am getting much better average performance on this, so just keeping it. But the other way MIGHT help keep the variation down so i wanna keep the code to play with later

version(embedded_httpd_threads) {
	//  unless the user overrides the default..
	version(cgi_session_server_process)
		{}
	else
		version=cgi_embedded_sessions;
}
version(scgi) {
	//  unless the user overrides the default..
	version(cgi_session_server_process)
		{}
	else
		version=cgi_embedded_sessions;
}

// fall back if the other is not defined so we can cleanly version it below
version(cgi_embedded_sessions) {}
else version=cgi_session_server_process;


version=cgi_with_websocket;

enum long defaultMaxContentLength = 5_000_000;

/*

	To do a file download offer in the browser:

    cgi.setResponseContentType("text/csv");
    cgi.header("Content-Disposition: attachment; filename=\"customers.csv\"");
*/

// FIXME: the location header is supposed to be an absolute url I guess.

// FIXME: would be cool to flush part of a dom document before complete
// somehow in here and dom.d.


// these are public so you can mixin GenericMain.
// FIXME: use a function level import instead!
public import std.string;
public import std.stdio;
public import std.conv;
import std.uri;
import std.uni;
import std.algorithm.comparison;
import std.algorithm.searching;
import std.exception;
import std.base64;
static import std.algorithm;
import std.datetime;
import std.range;

import std.process;

import std.zlib;


T[] consume(T)(T[] range, int count) {
	if(count > range.length)
		count = range.length;
	return range[count..$];
}

int locationOf(T)(T[] data, string item) {
	const(ubyte[]) d = cast(const(ubyte[])) data;
	const(ubyte[]) i = cast(const(ubyte[])) item;

	// this is a vague sanity check to ensure we aren't getting insanely
	// sized input that will infinite loop below. it should never happen;
	// even huge file uploads ought to come in smaller individual pieces.
	if(d.length > (int.max/2))
		throw new Exception("excessive block of input");

	for(int a = 0; a < d.length; a++) {
		if(a + i.length > d.length)
			return -1;
		if(d[a..a+i.length] == i)
			return a;
	}

	return -1;
}

/// If you are doing a custom cgi class, mixing this in can take care of
/// the required constructors for you
mixin template ForwardCgiConstructors() {
	this(long maxContentLength = defaultMaxContentLength,
		string[string] env = null,
		const(ubyte)[] delegate() readdata = null,
		void delegate(const(ubyte)[]) _rawDataOutput = null,
		void delegate() _flush = null
		) { super(maxContentLength, env, readdata, _rawDataOutput, _flush); }

	this(string[] args) { super(args); }

	this(
		BufferedInputRange inputData,
		string address, ushort _port,
		int pathInfoStarts = 0,
		bool _https = false,
		void delegate(const(ubyte)[]) _rawDataOutput = null,
		void delegate() _flush = null,
		// this pointer tells if the connection is supposed to be closed after we handle this
		bool* closeConnection = null)
	{
		super(inputData, address, _port, pathInfoStarts, _https, _rawDataOutput, _flush, closeConnection);
	}

	this(BufferedInputRange ir, bool* closeConnection) { super(ir, closeConnection); }
}

/// thrown when a connection is closed remotely while we waiting on data from it
class ConnectionClosedException : Exception {
	this(string message, string file = __FILE__, size_t line = __LINE__, Throwable next = null) {
		super(message, file, line, next);
	}
}


version(Windows) {
// FIXME: ugly hack to solve stdin exception problems on Windows:
// reading stdin results in StdioException (Bad file descriptor)
// this is probably due to http://d.puremagic.com/issues/show_bug.cgi?id=3425
private struct stdin {
	struct ByChunk { // Replicates std.stdio.ByChunk
	private:
		ubyte[] chunk_;
	public:
		this(size_t size)
		in {
			assert(size, "size must be larger than 0");
		}
		do {
			chunk_ = new ubyte[](size);
			popFront();
		}

		@property bool empty() const {
			return !std.stdio.stdin.isOpen || std.stdio.stdin.eof; // Ugly, but seems to do the job
		}
		@property nothrow ubyte[] front() {	return chunk_; }
		void popFront()	{
			enforce(!empty, "Cannot call popFront on empty range");
			chunk_ = stdin.rawRead(chunk_);
		}
	}

	import core.sys.windows.windows;
static:

	T[] rawRead(T)(T[] buf) {
		uint bytesRead;
		auto result = ReadFile(GetStdHandle(STD_INPUT_HANDLE), buf.ptr, cast(int) (buf.length * T.sizeof), &bytesRead, null);

		if (!result) {
			auto err = GetLastError();
			if (err == 38/*ERROR_HANDLE_EOF*/ || err == 109/*ERROR_BROKEN_PIPE*/) // 'good' errors meaning end of input
				return buf[0..0];
			// Some other error, throw it

			char* buffer;
			scope(exit) LocalFree(buffer);

			// FORMAT_MESSAGE_ALLOCATE_BUFFER	= 0x00000100
			// FORMAT_MESSAGE_FROM_SYSTEM		= 0x00001000
			FormatMessageA(0x1100, null, err, 0, cast(char*)&buffer, 256, null);
			throw new Exception(to!string(buffer));
		}
		enforce(!(bytesRead % T.sizeof), "I/O error");
		return buf[0..bytesRead / T.sizeof];
	}

	auto byChunk(size_t sz) { return ByChunk(sz); }

	void close() {
		std.stdio.stdin.close;
	}
}
}

/// The main interface with the web request
class Cgi {
  public:
	/// the methods a request can be
	enum RequestMethod { GET, HEAD, POST, PUT, DELETE, // GET and POST are the ones that really work
		// these are defined in the standard, but idk if they are useful for anything
		OPTIONS, TRACE, CONNECT,
		// These seem new, I have only recently seen them
		PATCH, MERGE,
		// this is an extension for when the method is not specified and you want to assume
		CommandLine }


	/+
	/++
		Cgi provides a per-request memory pool

	+/
	void[] allocateMemory(size_t nBytes) {

	}

	/// ditto
	void[] reallocateMemory(void[] old, size_t nBytes) {

	}

	/// ditto
	void freeMemory(void[] memory) {

	}
	+/


/*
	import core.runtime;
	auto args = Runtime.args();

	we can call the app a few ways:

	1) set up the environment variables and call the app (manually simulating CGI)
	2) simulate a call automatically:
		./app method 'uri'

		for example:
			./app get /path?arg arg2=something

	  Anything on the uri is treated as query string etc

	  on get method, further args are appended to the query string (encoded automatically)
	  on post method, further args are done as post


	  @name means import from file "name". if name == -, it uses stdin
	  (so info=@- means set info to the value of stdin)


	  Other arguments include:
	  	--cookie name=value (these are all concated together)
		--header 'X-Something: cool'
		--referrer 'something'
		--port 80
		--remote-address some.ip.address.here
		--https yes
		--user-agent 'something'
		--userpass 'user:pass'
		--authorization 'Basic base64encoded_user:pass'
		--accept 'content' // FIXME: better example
		--last-event-id 'something'
		--host 'something.com'

	  Non-simulation arguments:
	  	--port xxx listening port for non-cgi things (valid for the cgi interfaces)
		--listening-host  the ip address the application should listen on, or if you want to use unix domain sockets, it is here you can set them: `--listening-host unix:filename` or, on Linux, `--listening-host abstract:name`.

*/

	/** Initializes it with command line arguments (for easy testing) */
	this(string[] args, void delegate(const(ubyte)[]) _rawDataOutput = null) {
		rawDataOutput = _rawDataOutput;
		// these are all set locally so the loop works
		// without triggering errors in dmd 2.064
		// we go ahead and set them at the end of it to the this version
		int port;
		string referrer;
		string remoteAddress;
		string userAgent;
		string authorization;
		string origin;
		string accept;
		string lastEventId;
		bool https;
		string host;
		RequestMethod requestMethod;
		string requestUri;
		string pathInfo;
		string queryString;

		bool lookingForMethod;
		bool lookingForUri;
		string nextArgIs;

		string _cookie;
		string _queryString;
		string[][string] _post;
		string[string] _headers;

		string[] breakUp(string s) {
			string k, v;
			auto idx = s.indexOf("=");
			if(idx == -1) {
				k = s;
			} else {
				k = s[0 .. idx];
				v = s[idx + 1 .. $];
			}

			return [k, v];
		}

		lookingForMethod = true;

		scriptName = args[0];
		scriptFileName = args[0];

		environmentVariables = cast(const) environment.toAA;

		foreach(arg; args[1 .. $]) {
			if(arg.startsWith("--")) {
				nextArgIs = arg[2 .. $];
			} else if(nextArgIs.length) {
				if (nextArgIs == "cookie") {
					auto info = breakUp(arg);
					if(_cookie.length)
						_cookie ~= "; ";
					_cookie ~= std.uri.encodeComponent(info[0]) ~ "=" ~ std.uri.encodeComponent(info[1]);
				}
				else if (nextArgIs == "port") {
					port = to!int(arg);
				}
				else if (nextArgIs == "referrer") {
					referrer = arg;
				}
				else if (nextArgIs == "remote-address") {
					remoteAddress = arg;
				}
				else if (nextArgIs == "user-agent") {
					userAgent = arg;
				}
				else if (nextArgIs == "authorization") {
					authorization = arg;
				}
				else if (nextArgIs == "userpass") {
					authorization = "Basic " ~ Base64.encode(cast(immutable(ubyte)[]) (arg)).idup;
				}
				else if (nextArgIs == "origin") {
					origin = arg;
				}
				else if (nextArgIs == "accept") {
					accept = arg;
				}
				else if (nextArgIs == "last-event-id") {
					lastEventId = arg;
				}
				else if (nextArgIs == "https") {
					if(arg == "yes")
						https = true;
				}
				else if (nextArgIs == "header") {
					string thing, other;
					auto idx = arg.indexOf(":");
					if(idx == -1)
						throw new Exception("need a colon in a http header");
					thing = arg[0 .. idx];
					other = arg[idx + 1.. $];
					_headers[thing.strip.toLower()] = other.strip;
				}
				else if (nextArgIs == "host") {
					host = arg;
				}
				// else
				// skip, we don't know it but that's ok, it might be used elsewhere so no error

				nextArgIs = null;
			} else if(lookingForMethod) {
				lookingForMethod = false;
				lookingForUri = true;

				if(arg.asLowerCase().equal("commandline"))
					requestMethod = RequestMethod.CommandLine;
				else
					requestMethod = to!RequestMethod(arg.toUpper());
			} else if(lookingForUri) {
				lookingForUri = false;

				requestUri = arg;

				auto idx = arg.indexOf("?");
				if(idx == -1)
					pathInfo = arg;
				else {
					pathInfo = arg[0 .. idx];
					_queryString = arg[idx + 1 .. $];
				}
			} else {
				// it is an argument of some sort
				if(requestMethod == Cgi.RequestMethod.POST || requestMethod == Cgi.RequestMethod.PATCH || requestMethod == Cgi.RequestMethod.PUT || requestMethod == Cgi.RequestMethod.CommandLine) {
					auto parts = breakUp(arg);
					_post[parts[0]] ~= parts[1];
					allPostNamesInOrder ~= parts[0];
					allPostValuesInOrder ~= parts[1];
				} else {
					if(_queryString.length)
						_queryString ~= "&";
					auto parts = breakUp(arg);
					_queryString ~= std.uri.encodeComponent(parts[0]) ~ "=" ~ std.uri.encodeComponent(parts[1]);
				}
			}
		}

		acceptsGzip = false;
		keepAliveRequested = false;
		requestHeaders = cast(immutable) _headers;

		cookie = _cookie;
		cookiesArray =  getCookieArray();
		cookies = keepLastOf(cookiesArray);

		queryString = _queryString;
		getArray = cast(immutable) decodeVariables(queryString, "&", &allGetNamesInOrder, &allGetValuesInOrder);
		get = keepLastOf(getArray);

		postArray = cast(immutable) _post;
		post = keepLastOf(_post);

		// FIXME
		filesArray = null;
		files = null;

		isCalledWithCommandLineArguments = true;

		this.port = port;
		this.referrer = referrer;
		this.remoteAddress = remoteAddress;
		this.userAgent = userAgent;
		this.authorization = authorization;
		this.origin = origin;
		this.accept = accept;
		this.lastEventId = lastEventId;
		this.https = https;
		this.host = host;
		this.requestMethod = requestMethod;
		this.requestUri = requestUri;
		this.pathInfo = pathInfo;
		this.queryString = queryString;
		this.postBody = null;
	}

	private {
		string[] allPostNamesInOrder;
		string[] allPostValuesInOrder;
		string[] allGetNamesInOrder;
		string[] allGetValuesInOrder;
	}

	CgiConnectionHandle getOutputFileHandle() {
		return _outputFileHandle;
	}

	CgiConnectionHandle _outputFileHandle = INVALID_CGI_CONNECTION_HANDLE;

	/** Initializes it using a CGI or CGI-like interface */
	this(long maxContentLength = defaultMaxContentLength,
		// use this to override the environment variable listing
		in string[string] env = null,
		// and this should return a chunk of data. return empty when done
		const(ubyte)[] delegate() readdata = null,
		// finally, use this to do custom output if needed
		void delegate(const(ubyte)[]) _rawDataOutput = null,
		// to flush teh custom output
		void delegate() _flush = null
		)
	{

		// these are all set locally so the loop works
		// without triggering errors in dmd 2.064
		// we go ahead and set them at the end of it to the this version
		int port;
		string referrer;
		string remoteAddress;
		string userAgent;
		string authorization;
		string origin;
		string accept;
		string lastEventId;
		bool https;
		string host;
		RequestMethod requestMethod;
		string requestUri;
		string pathInfo;
		string queryString;



		isCalledWithCommandLineArguments = false;
		rawDataOutput = _rawDataOutput;
		flushDelegate = _flush;
		auto getenv = delegate string(string var) {
			if(env is null)
				return std.process.environment.get(var);
			auto e = var in env;
			if(e is null)
				return null;
			return *e;
		};

		environmentVariables = env is null ?
			cast(const) environment.toAA :
			env;

		// fetching all the request headers
		string[string] requestHeadersHere;
		foreach(k, v; env is null ? cast(const) environment.toAA() : env) {
			if(k.startsWith("HTTP_")) {
				requestHeadersHere[replace(k["HTTP_".length .. $].toLower(), "_", "-")] = v;
			}
		}

		this.requestHeaders = assumeUnique(requestHeadersHere);

		requestUri = getenv("REQUEST_URI");

		cookie = getenv("HTTP_COOKIE");
		cookiesArray = getCookieArray();
		cookies = keepLastOf(cookiesArray);

		referrer = getenv("HTTP_REFERER");
		userAgent = getenv("HTTP_USER_AGENT");
		remoteAddress = getenv("REMOTE_ADDR");
		host = getenv("HTTP_HOST");
		pathInfo = getenv("PATH_INFO");

		queryString = getenv("QUERY_STRING");
		scriptName = getenv("SCRIPT_NAME");
		{
			import core.runtime;
			auto sfn = getenv("SCRIPT_FILENAME");
			scriptFileName = sfn.length ? sfn : (Runtime.args.length ? Runtime.args[0] : null);
		}

		bool iis = false;

		// Because IIS doesn't pass requestUri, we simulate it here if it's empty.
		if(requestUri.length == 0) {
			// IIS sometimes includes the script name as part of the path info - we don't want that
			if(pathInfo.length >= scriptName.length && (pathInfo[0 .. scriptName.length] == scriptName))
				pathInfo = pathInfo[scriptName.length .. $];

			requestUri = scriptName ~ pathInfo ~ (queryString.length ? ("?" ~ queryString) : "");

			iis = true; // FIXME HACK - used in byChunk below - see bugzilla 6339

			// FIXME: this works for apache and iis... but what about others?
		}


		auto ugh = decodeVariables(queryString, "&", &allGetNamesInOrder, &allGetValuesInOrder);
		getArray = assumeUnique(ugh);
		get = keepLastOf(getArray);


		// NOTE: on shitpache, you need to specifically forward this
		authorization = getenv("HTTP_AUTHORIZATION");
		// this is a hack because Apache is a shitload of fuck and
		// refuses to send the real header to us. Compatible
		// programs should send both the standard and X- versions

		// NOTE: if you have access to .htaccess or httpd.conf, you can make this
		// unnecessary with mod_rewrite, so it is commented

		//if(authorization.length == 0) // if the std is there, use it
		//	authorization = getenv("HTTP_X_AUTHORIZATION");

		// the REDIRECT_HTTPS check is here because with an Apache hack, the port can become wrong
		if(getenv("SERVER_PORT").length && getenv("REDIRECT_HTTPS") != "on")
			port = to!int(getenv("SERVER_PORT"));
		else
			port = 0; // this was probably called from the command line

		auto ae = getenv("HTTP_ACCEPT_ENCODING");
		if(ae.length && ae.indexOf("gzip") != -1)
			acceptsGzip = true;

		accept = getenv("HTTP_ACCEPT");
		lastEventId = getenv("HTTP_LAST_EVENT_ID");

		auto ka = getenv("HTTP_CONNECTION");
		if(ka.length && ka.asLowerCase().canFind("keep-alive"))
			keepAliveRequested = true;

		auto or = getenv("HTTP_ORIGIN");
			origin = or;

		auto rm = getenv("REQUEST_METHOD");
		if(rm.length)
			requestMethod = to!RequestMethod(getenv("REQUEST_METHOD"));
		else
			requestMethod = RequestMethod.CommandLine;

						// FIXME: hack on REDIRECT_HTTPS; this is there because the work app uses mod_rewrite which loses the https flag! So I set it with [E=HTTPS=%HTTPS] or whatever but then it gets translated to here so i want it to still work. This is arguably wrong but meh.
		https = (getenv("HTTPS") == "on" || getenv("REDIRECT_HTTPS") == "on");

		// FIXME: DOCUMENT_ROOT?

		// FIXME: what about PUT?
		if(requestMethod == RequestMethod.POST || requestMethod == Cgi.RequestMethod.PATCH || requestMethod == Cgi.RequestMethod.PUT || requestMethod == Cgi.RequestMethod.CommandLine) {
			version(preserveData) // a hack to make forwarding simpler
				immutable(ubyte)[] data;
			size_t amountReceived = 0;
			auto contentType = getenv("CONTENT_TYPE");

			// FIXME: is this ever not going to be set? I guess it depends
			// on if the server de-chunks and buffers... seems like it has potential
			// to be slow if they did that. The spec says it is always there though.
			// And it has worked reliably for me all year in the live environment,
			// but some servers might be different.
			auto cls = getenv("CONTENT_LENGTH");
			auto contentLength = to!size_t(cls.length ? cls : "0");

			immutable originalContentLength = contentLength;
			if(contentLength) {
				if(maxContentLength > 0 && contentLength > maxContentLength) {
					setResponseStatus("413 Request entity too large");
					write("You tried to upload a file that is too large.");
					close();
					throw new Exception("POST too large");
				}
				prepareForIncomingDataChunks(contentType, contentLength);


				int processChunk(in ubyte[] chunk) {
					if(chunk.length > contentLength) {
						handleIncomingDataChunk(chunk[0..contentLength]);
						amountReceived += contentLength;
						contentLength = 0;
						return 1;
					} else {
						handleIncomingDataChunk(chunk);
						contentLength -= chunk.length;
						amountReceived += chunk.length;
					}
					if(contentLength == 0)
						return 1;

					onRequestBodyDataReceived(amountReceived, originalContentLength);
					return 0;
				}


				if(readdata is null) {
					foreach(ubyte[] chunk; stdin.byChunk(iis ? contentLength : 4096))
						if(processChunk(chunk))
							break;
				} else {
					// we have a custom data source..
					auto chunk = readdata();
					while(chunk.length) {
						if(processChunk(chunk))
							break;
						chunk = readdata();
					}
				}

				onRequestBodyDataReceived(amountReceived, originalContentLength);
				postArray = assumeUnique(pps._post);
				filesArray = assumeUnique(pps._files);
				files = keepLastOf(filesArray);
				post = keepLastOf(postArray);
				this.postBody = pps.postBody;
				cleanUpPostDataState();
			}

			version(preserveData)
				originalPostData = data;
		}
		// fixme: remote_user script name


		this.port = port;
		this.referrer = referrer;
		this.remoteAddress = remoteAddress;
		this.userAgent = userAgent;
		this.authorization = authorization;
		this.origin = origin;
		this.accept = accept;
		this.lastEventId = lastEventId;
		this.https = https;
		this.host = host;
		this.requestMethod = requestMethod;
		this.requestUri = requestUri;
		this.pathInfo = pathInfo;
		this.queryString = queryString;
	}

	/// Cleans up any temporary files. Do not use the object
	/// after calling this.
	///
	/// NOTE: it is called automatically by GenericMain
	// FIXME: this should be called if the constructor fails too, if it has created some garbage...
	void dispose() {
		foreach(file; files) {
			if(!file.contentInMemory)
				if(std.file.exists(file.contentFilename))
					std.file.remove(file.contentFilename);
		}
	}

	private {
		struct PostParserState {
			string contentType;
			string boundary;
			string localBoundary; // the ones used at the end or something lol
			bool isMultipart;
			bool needsSavedBody;

			ulong expectedLength;
			ulong contentConsumed;
			immutable(ubyte)[] buffer;

			// multipart parsing state
			int whatDoWeWant;
			bool weHaveAPart;
			string[] thisOnesHeaders;
			immutable(ubyte)[] thisOnesData;

			string postBody;

			UploadedFile piece;
			bool isFile = false;

			size_t memoryCommitted;

			// do NOT keep mutable references to these anywhere!
			// I assume they are unique in the constructor once we're all done getting data.
			string[][string] _post;
			UploadedFile[][string] _files;
		}

		PostParserState pps;
	}

	/// This represents a file the user uploaded via a POST request.
	static struct UploadedFile {
		/// If you want to create one of these structs for yourself from some data,
		/// use this function.
		static UploadedFile fromData(immutable(void)[] data, string name = null) {
			Cgi.UploadedFile f;
			f.filename = name;
			f.content = cast(immutable(ubyte)[]) data;
			f.contentInMemory = true;
			return f;
		}

		string name; 		/// The name of the form element.
		string filename; 	/// The filename the user set.
		string contentType; 	/// The MIME type the user's browser reported. (Not reliable.)

		/**
			For small files, cgi.d will buffer the uploaded file in memory, and make it
			directly accessible to you through the content member. I find this very convenient
			and somewhat efficient, since it can avoid hitting the disk entirely. (I
			often want to inspect and modify the file anyway!)

			I find the file is very large, it is undesirable to eat that much memory just
			for a file buffer. In those cases, if you pass a large enough value for maxContentLength
			to the constructor so they are accepted, cgi.d will write the content to a temporary
			file that you can re-read later.

			You can override this behavior by subclassing Cgi and overriding the protected
			handlePostChunk method. Note that the object is not initialized when you
			write that method - the http headers are available, but the cgi.post method
			is not. You may parse the file as it streams in using this method.


			Anyway, if the file is small enough to be in memory, contentInMemory will be
			set to true, and the content is available in the content member.

			If not, contentInMemory will be set to false, and the content saved in a file,
			whose name will be available in the contentFilename member.


			Tip: if you know you are always dealing with small files, and want the convenience
			of ignoring this member, construct Cgi with a small maxContentLength. Then, if
			a large file comes in, it simply throws an exception (and HTTP error response)
			instead of trying to handle it.

			The default value of maxContentLength in the constructor is for small files.
		*/
		bool contentInMemory = true; // the default ought to always be true
		immutable(ubyte)[] content; /// The actual content of the file, if contentInMemory == true
		string contentFilename; /// the file where we dumped the content, if contentInMemory == false. Note that if you want to keep it, you MUST move the file, since otherwise it is considered garbage when cgi is disposed.

		///
		ulong fileSize() {
			if(contentInMemory)
				return content.length;
			import std.file;
			return std.file.getSize(contentFilename);

		}

		///
		void writeToFile(string filenameToSaveTo) const {
			import std.file;
			if(contentInMemory)
				std.file.write(filenameToSaveTo, content);
			else
				std.file.rename(contentFilename, filenameToSaveTo);
		}
	}

	// given a content type and length, decide what we're going to do with the data..
	protected void prepareForIncomingDataChunks(string contentType, ulong contentLength) {
		pps.expectedLength = contentLength;

		auto terminator = contentType.indexOf(";");
		if(terminator == -1)
			terminator = contentType.length;

		pps.contentType = contentType[0 .. terminator];
		auto b = contentType[terminator .. $];
		if(b.length) {
			auto idx = b.indexOf("boundary=");
			if(idx != -1) {
				pps.boundary = b[idx + "boundary=".length .. $];
				pps.localBoundary = "\r\n--" ~ pps.boundary;
			}
		}

		// while a content type SHOULD be sent according to the RFC, it is
		// not required. We're told we SHOULD guess by looking at the content
		// but it seems to me that this only happens when it is urlencoded.
		if(pps.contentType == "application/x-www-form-urlencoded" || pps.contentType == "") {
			pps.isMultipart = false;
			pps.needsSavedBody = false;
		} else if(pps.contentType == "multipart/form-data") {
			pps.isMultipart = true;
			enforce(pps.boundary.length, "no boundary");
		} else if(pps.contentType == "text/xml") { // FIXME: could this be special and load the post params
			// save the body so the application can handle it
			pps.isMultipart = false;
			pps.needsSavedBody = true;
		} else if(pps.contentType == "application/json") { // FIXME: this could prolly try to load post params too
			// save the body so the application can handle it
			pps.needsSavedBody = true;
			pps.isMultipart = false;
		} else {
			// the rest is 100% handled by the application. just save the body and send it to them
			pps.needsSavedBody = true;
			pps.isMultipart = false;
		}
	}

	// handles streaming POST data. If you handle some other content type, you should
	// override this. If the data isn't the content type you want, you ought to call
	// super.handleIncomingDataChunk so regular forms and files still work.

	// FIXME: I do some copying in here that I'm pretty sure is unnecessary, and the
	// file stuff I'm sure is inefficient. But, my guess is the real bottleneck is network
	// input anyway, so I'm not going to get too worked up about it right now.
	protected void handleIncomingDataChunk(const(ubyte)[] chunk) {
		if(chunk.length == 0)
			return;
		assert(chunk.length <= 32 * 1024 * 1024); // we use chunk size as a memory constraint thing, so
							// if we're passed big chunks, it might throw unnecessarily.
							// just pass it smaller chunks at a time.
		if(pps.isMultipart) {
			// multipart/form-data


			// FIXME: this might want to be factored out and factorized
			// need to make sure the stream hooks actually work.
			void pieceHasNewContent() {
				// we just grew the piece's buffer. Do we have to switch to file backing?
				if(pps.piece.contentInMemory) {
					if(pps.piece.content.length <= 10 * 1024 * 1024)
						// meh, I'm ok with it.
						return;
					else {
						// this is too big.
						if(!pps.isFile)
							throw new Exception("Request entity too large"); // a variable this big is kinda ridiculous, just reject it.
						else {
							// a file this large is probably acceptable though... let's use a backing file.
							pps.piece.contentInMemory = false;
							// FIXME: say... how do we intend to delete these things? cgi.dispose perhaps.

							int count = 0;
							pps.piece.contentFilename = getTempDirectory() ~ "arsd_cgi_uploaded_file_" ~ to!string(getUtcTime()) ~ "-" ~ to!string(count);
							// odds are this loop will never be entered, but we want it just in case.
							while(std.file.exists(pps.piece.contentFilename)) {
								count++;
								pps.piece.contentFilename = getTempDirectory() ~ "arsd_cgi_uploaded_file_" ~ to!string(getUtcTime()) ~ "-" ~ to!string(count);
							}
							// I hope this creates the file pretty quickly, or the loop might be useless...
							// FIXME: maybe I should write some kind of custom transaction here.
							std.file.write(pps.piece.contentFilename, pps.piece.content);

							pps.piece.content = null;
						}
					}
				} else {
					// it's already in a file, so just append it to what we have
					if(pps.piece.content.length) {
						// FIXME: this is surely very inefficient... we'll be calling this by 4kb chunk...
						std.file.append(pps.piece.contentFilename, pps.piece.content);
						pps.piece.content = null;
					}
				}
			}


			void commitPart() {
				if(!pps.weHaveAPart)
					return;

				pieceHasNewContent(); // be sure the new content is handled every time

				if(pps.isFile) {
					// I'm not sure if other environments put files in post or not...
					// I used to not do it, but I think I should, since it is there...
					pps._post[pps.piece.name] ~= pps.piece.filename;
					pps._files[pps.piece.name] ~= pps.piece;

					allPostNamesInOrder ~= pps.piece.name;
					allPostValuesInOrder ~= pps.piece.filename;
				} else {
					pps._post[pps.piece.name] ~= cast(string) pps.piece.content;

					allPostNamesInOrder ~= pps.piece.name;
					allPostValuesInOrder ~= cast(string) pps.piece.content;
				}

				/*
				stderr.writeln("RECEIVED: ", pps.piece.name, "=",
					pps.piece.content.length < 1000
					?
					to!string(pps.piece.content)
					:
					"too long");
				*/

				// FIXME: the limit here
				pps.memoryCommitted += pps.piece.content.length;

				pps.weHaveAPart = false;
				pps.whatDoWeWant = 1;
				pps.thisOnesHeaders = null;
				pps.thisOnesData = null;

				pps.piece = UploadedFile.init;
				pps.isFile = false;
			}

			void acceptChunk() {
				pps.buffer ~= chunk;
				chunk = null; // we've consumed it into the buffer, so keeping it just brings confusion
			}

			immutable(ubyte)[] consume(size_t howMuch) {
				pps.contentConsumed += howMuch;
				auto ret = pps.buffer[0 .. howMuch];
				pps.buffer = pps.buffer[howMuch .. $];
				return ret;
			}

			dataConsumptionLoop: do {
			switch(pps.whatDoWeWant) {
				default: assert(0);
				case 0:
					acceptChunk();
					// the format begins with two extra leading dashes, then we should be at the boundary
					if(pps.buffer.length < 2)
						return;
					assert(pps.buffer[0] == '-', "no leading dash");
					consume(1);
					assert(pps.buffer[0] == '-', "no second leading dash");
					consume(1);

					pps.whatDoWeWant = 1;
					goto case 1;
				/* fallthrough */
				case 1: // looking for headers
					// here, we should be lined up right at the boundary, which is followed by a \r\n

					// want to keep the buffer under control in case we're under attack
					//stderr.writeln("here once");
					//if(pps.buffer.length + chunk.length > 70 * 1024) // they should be < 1 kb really....
					//	throw new Exception("wtf is up with the huge mime part headers");

					acceptChunk();

					if(pps.buffer.length < pps.boundary.length)
						return; // not enough data, since there should always be a boundary here at least

					if(pps.contentConsumed + pps.boundary.length + 6 == pps.expectedLength) {
						assert(pps.buffer.length == pps.boundary.length + 4 + 2); // --, --, and \r\n
						// we *should* be at the end here!
						assert(pps.buffer[0] == '-');
						consume(1);
						assert(pps.buffer[0] == '-');
						consume(1);

						// the message is terminated by --BOUNDARY--\r\n (after a \r\n leading to the boundary)
						assert(pps.buffer[0 .. pps.boundary.length] == cast(const(ubyte[])) pps.boundary,
							"not lined up on boundary " ~ pps.boundary);
						consume(pps.boundary.length);

						assert(pps.buffer[0] == '-');
						consume(1);
						assert(pps.buffer[0] == '-');
						consume(1);

						assert(pps.buffer[0] == '\r');
						consume(1);
						assert(pps.buffer[0] == '\n');
						consume(1);

						assert(pps.buffer.length == 0);
						assert(pps.contentConsumed == pps.expectedLength);
						break dataConsumptionLoop; // we're done!
					} else {
						// we're not done yet. We should be lined up on a boundary.

						// But, we want to ensure the headers are here before we consume anything!
						auto headerEndLocation = locationOf(pps.buffer, "\r\n\r\n");
						if(headerEndLocation == -1)
							return; // they *should* all be here, so we can handle them all at once.

						assert(pps.buffer[0 .. pps.boundary.length] == cast(const(ubyte[])) pps.boundary,
							"not lined up on boundary " ~ pps.boundary);

						consume(pps.boundary.length);
						// the boundary is always followed by a \r\n
						assert(pps.buffer[0] == '\r');
						consume(1);
						assert(pps.buffer[0] == '\n');
						consume(1);
					}

					// re-running since by consuming the boundary, we invalidate the old index.
					auto headerEndLocation = locationOf(pps.buffer, "\r\n\r\n");
					assert(headerEndLocation >= 0, "no header");
					auto thisOnesHeaders = pps.buffer[0..headerEndLocation];

					consume(headerEndLocation + 4); // The +4 is the \r\n\r\n that caps it off

					pps.thisOnesHeaders = split(cast(string) thisOnesHeaders, "\r\n");

					// now we'll parse the headers
					foreach(h; pps.thisOnesHeaders) {
						auto p = h.indexOf(":");
						assert(p != -1, "no colon in header, got " ~ to!string(pps.thisOnesHeaders));
						string hn = h[0..p];
						string hv = h[p+2..$];

						switch(hn.toLower) {
							default: assert(0);
							case "content-disposition":
								auto info = hv.split("; ");
								foreach(i; info[1..$]) { // skipping the form-data
									auto o = i.split("="); // FIXME
									string pn = o[0];
									string pv = o[1][1..$-1];

									if(pn == "name") {
										pps.piece.name = pv;
									} else if (pn == "filename") {
										pps.piece.filename = pv;
										pps.isFile = true;
									}
								}
							break;
							case "content-type":
								pps.piece.contentType = hv;
							break;
						}
					}

					pps.whatDoWeWant++; // move to the next step - the data
				break;
				case 2:
					// when we get here, pps.buffer should contain our first chunk of data

					if(pps.buffer.length + chunk.length > 8 * 1024 * 1024) // we might buffer quite a bit but not much
						throw new Exception("wtf is up with the huge mime part buffer");

					acceptChunk();

					// so the trick is, we want to process all the data up to the boundary,
					// but what if the chunk's end cuts the boundary off? If we're unsure, we
					// want to wait for the next chunk. We start by looking for the whole boundary
					// in the buffer somewhere.

					auto boundaryLocation = locationOf(pps.buffer, pps.localBoundary);
					// assert(boundaryLocation != -1, "should have seen "~to!string(cast(ubyte[]) pps.localBoundary)~" in " ~ to!string(pps.buffer));
					if(boundaryLocation != -1) {
						// this is easy - we can see it in it's entirety!

						pps.piece.content ~= consume(boundaryLocation);

						assert(pps.buffer[0] == '\r');
						consume(1);
						assert(pps.buffer[0] == '\n');
						consume(1);
						assert(pps.buffer[0] == '-');
						consume(1);
						assert(pps.buffer[0] == '-');
						consume(1);
						// the boundary here is always preceded by \r\n--, which is why we used localBoundary instead of boundary to locate it. Cut that off.
						pps.weHaveAPart = true;
						pps.whatDoWeWant = 1; // back to getting headers for the next part

						commitPart(); // we're done here
					} else {
						// we can't see the whole thing, but what if there's a partial boundary?

						enforce(pps.localBoundary.length < 128); // the boundary ought to be less than a line...
						assert(pps.localBoundary.length > 1); // should already be sane but just in case
						bool potentialBoundaryFound = false;

						boundaryCheck: for(int a = 1; a < pps.localBoundary.length; a++) {
							// we grow the boundary a bit each time. If we think it looks the
							// same, better pull another chunk to be sure it's not the end.
							// Starting small because exiting the loop early is desirable, since
							// we're not keeping any ambiguity and 1 / 256 chance of exiting is
							// the best we can do.
							if(a > pps.buffer.length)
								break; // FIXME: is this right?
							assert(a <= pps.buffer.length);
							assert(a > 0);
							if(std.algorithm.endsWith(pps.buffer, pps.localBoundary[0 .. a])) {
								// ok, there *might* be a boundary here, so let's
								// not treat the end as data yet. The rest is good to
								// use though, since if there was a boundary there, we'd
								// have handled it up above after locationOf.

								pps.piece.content ~= pps.buffer[0 .. $ - a];
								consume(pps.buffer.length - a);
								pieceHasNewContent();
								potentialBoundaryFound = true;
								break boundaryCheck;
							}
						}

						if(!potentialBoundaryFound) {
							// we can consume the whole thing
							pps.piece.content ~= pps.buffer;
							pieceHasNewContent();
							consume(pps.buffer.length);
						} else {
							// we found a possible boundary, but there was
							// insufficient data to be sure.
							assert(pps.buffer == cast(const(ubyte[])) pps.localBoundary[0 .. pps.buffer.length]);

							return; // wait for the next chunk.
						}
					}
			}
			} while(pps.buffer.length);

			// btw all boundaries except the first should have a \r\n before them
		} else {
			// application/x-www-form-urlencoded and application/json

				// not using maxContentLength because that might be cranked up to allow
				// large file uploads. We can handle them, but a huge post[] isn't any good.
			if(pps.buffer.length + chunk.length > 8 * 1024 * 1024) // surely this is plenty big enough
				throw new Exception("wtf is up with such a gigantic form submission????");

			pps.buffer ~= chunk;

			// simple handling, but it works... until someone bombs us with gigabytes of crap at least...
			if(pps.buffer.length == pps.expectedLength) {
				if(pps.needsSavedBody)
					pps.postBody = cast(string) pps.buffer;
				else
					pps._post = decodeVariables(cast(string) pps.buffer, "&", &allPostNamesInOrder, &allPostValuesInOrder);
				version(preserveData)
					originalPostData = pps.buffer;
			} else {
				// just for debugging
			}
		}
	}

	protected void cleanUpPostDataState() {
		pps = PostParserState.init;
	}

	/// you can override this function to somehow react
	/// to an upload in progress.
	///
	/// Take note that parts of the CGI object is not yet
	/// initialized! Stuff from HTTP headers, including get[], is usable.
	/// But, none of post[] is usable, and you cannot write here. That's
	/// why this method is const - mutating the object won't do much anyway.
	///
	/// My idea here was so you can output a progress bar or
	/// something to a cooperative client (see arsd.rtud for a potential helper)
	///
	/// The default is to do nothing. Subclass cgi and use the
	/// CustomCgiMain mixin to do something here.
	void onRequestBodyDataReceived(size_t receivedSoFar, size_t totalExpected) const {
		// This space intentionally left blank.
	}

	/// Initializes the cgi from completely raw HTTP data. The ir must have a Socket source.
	/// *closeConnection will be set to true if you should close the connection after handling this request
	this(BufferedInputRange ir, bool* closeConnection) {
		isCalledWithCommandLineArguments = false;
		import al = std.algorithm;

		immutable(ubyte)[] data;

		void rdo(const(ubyte)[] d) {
		//import std.stdio; writeln(d);
			sendAll(ir.source, d);
		}

		auto ira = ir.source.remoteAddress();
		auto irLocalAddress = ir.source.localAddress();

		ushort port = 80;
		if(auto ia = cast(InternetAddress) irLocalAddress) {
			port = ia.port;
		} else if(auto ia = cast(Internet6Address) irLocalAddress) {
			port = ia.port;
		}

		// that check for UnixAddress is to work around a Phobos bug
		// see: https://github.com/dlang/phobos/pull/7383
		// but this might be more useful anyway tbh for this case
		version(Posix)
		this(ir, ira is null ? null : cast(UnixAddress) ira ? "unix:" : ira.toString(), port, 0, false, &rdo, null, closeConnection);
		else
		this(ir, ira is null ? null : ira.toString(), port, 0, false, &rdo, null, closeConnection);
	}

	/**
		Initializes it from raw HTTP request data. GenericMain uses this when you compile with -version=embedded_httpd.

		NOTE: If you are behind a reverse proxy, the values here might not be what you expect.... it will use X-Forwarded-For for remote IP and X-Forwarded-Host for host

		Params:
			inputData = the incoming data, including headers and other raw http data.
				When the constructor exits, it will leave this range exactly at the start of
				the next request on the connection (if there is one).

			address = the IP address of the remote user
			_port = the port number of the connection
			pathInfoStarts = the offset into the path component of the http header where the SCRIPT_NAME ends and the PATH_INFO begins.
			_https = if this connection is encrypted (note that the input data must not actually be encrypted)
			_rawDataOutput = delegate to accept response data. It should write to the socket or whatever; Cgi does all the needed processing to speak http.
			_flush = if _rawDataOutput buffers, this delegate should flush the buffer down the wire
			closeConnection = if the request asks to close the connection, *closeConnection == true.
	*/
	this(
		BufferedInputRange inputData,
//		string[] headers, immutable(ubyte)[] data,
		string address, ushort _port,
		int pathInfoStarts = 0, // use this if you know the script name, like if this is in a folder in a bigger web environment
		bool _https = false,
		void delegate(const(ubyte)[]) _rawDataOutput = null,
		void delegate() _flush = null,
		// this pointer tells if the connection is supposed to be closed after we handle this
		bool* closeConnection = null)
	{
		// these are all set locally so the loop works
		// without triggering errors in dmd 2.064
		// we go ahead and set them at the end of it to the this version
		int port;
		string referrer;
		string remoteAddress;
		string userAgent;
		string authorization;
		string origin;
		string accept;
		string lastEventId;
		bool https;
		string host;
		RequestMethod requestMethod;
		string requestUri;
		string pathInfo;
		string queryString;
		string scriptName;
		string[string] get;
		string[][string] getArray;
		bool keepAliveRequested;
		bool acceptsGzip;
		string cookie;



		environmentVariables = cast(const) environment.toAA;

		idlol = inputData;

		isCalledWithCommandLineArguments = false;

		https = _https;
		port = _port;

		rawDataOutput = _rawDataOutput;
		flushDelegate = _flush;
		nph = true;

		remoteAddress = address;

		// streaming parser
		import al = std.algorithm;

			// FIXME: tis cast is technically wrong, but Phobos deprecated al.indexOf... for some reason.
		auto idx = indexOf(cast(string) inputData.front(), "\r\n\r\n");
		while(idx == -1) {
			inputData.popFront(0);
			idx = indexOf(cast(string) inputData.front(), "\r\n\r\n");
		}

		assert(idx != -1);


		string contentType = "";
		string[string] requestHeadersHere;

		size_t contentLength;

		bool isChunked;

		{
			import core.runtime;
			scriptFileName = Runtime.args.length ? Runtime.args[0] : null;
		}


		int headerNumber = 0;
		foreach(line; al.splitter(inputData.front()[0 .. idx], "\r\n"))
		if(line.length) {
			headerNumber++;
			auto header = cast(string) line.idup;
			if(headerNumber == 1) {
				// request line
				auto parts = al.splitter(header, " ");
				requestMethod = to!RequestMethod(parts.front);
				parts.popFront();
				requestUri = parts.front;

				// FIXME:  the requestUri could be an absolute path!!! should I rename it or something?
				scriptName = requestUri[0 .. pathInfoStarts];

				auto question = requestUri.indexOf("?");
				if(question == -1) {
					queryString = "";
					// FIXME: double check, this might be wrong since it could be url encoded
					pathInfo = requestUri[pathInfoStarts..$];
				} else {
					queryString = requestUri[question+1..$];
					pathInfo = requestUri[pathInfoStarts..question];
				}

				auto ugh = decodeVariables(queryString, "&", &allGetNamesInOrder, &allGetValuesInOrder);
				getArray = cast(string[][string]) assumeUnique(ugh);

				if(header.indexOf("HTTP/1.0") != -1) {
					http10 = true;
					autoBuffer = true;
					if(closeConnection) {
						// on http 1.0, close is assumed (unlike http/1.1 where we assume keep alive)
						*closeConnection = true;
					}
				}
			} else {
				// other header
				auto colon = header.indexOf(":");
				if(colon == -1)
					throw new Exception("HTTP headers should have a colon!");
				string name = header[0..colon].toLower;
				string value = header[colon+2..$]; // skip the colon and the space

				requestHeadersHere[name] = value;

				if (name == "accept") {
					accept = value;
				}
				else if (name == "origin") {
					origin = value;
				}
				else if (name == "connection") {
					if(value == "close" && closeConnection)
						*closeConnection = true;
					if(value.asLowerCase().canFind("keep-alive")) {
						keepAliveRequested = true;

						// on http 1.0, the connection is closed by default,
						// but not if they request keep-alive. then we don't close
						// anymore - undoing the set above
						if(http10 && closeConnection) {
							*closeConnection = false;
						}
					}
				}
				else if (name == "transfer-encoding") {
					if(value == "chunked")
						isChunked = true;
				}
				else if (name == "last-event-id") {
					lastEventId = value;
				}
				else if (name == "authorization") {
					authorization = value;
				}
				else if (name == "content-type") {
					contentType = value;
				}
				else if (name == "content-length") {
					contentLength = to!size_t(value);
				}
				else if (name == "x-forwarded-for") {
					remoteAddress = value;
				}
				else if (name == "x-forwarded-host" || name == "host") {
					if(name != "host" || host is null)
						host = value;
				}
				// FIXME: https://tools.ietf.org/html/rfc7239
				else if (name == "accept-encoding") {
					if(value.indexOf("gzip") != -1)
						acceptsGzip = true;
				}
				else if (name == "user-agent") {
					userAgent = value;
				}
				else if (name == "referer") {
					referrer = value;
				}
				else if (name == "cookie") {
					cookie ~= value;
				} else if(name == "expect") {
					if(value == "100-continue") {
						// FIXME we should probably give user code a chance
						// to process and reject but that needs to be virtual,
						// perhaps part of the CGI redesign.

						// FIXME: if size is > max content length it should
						// also fail at this point.
						_rawDataOutput(cast(ubyte[]) "HTTP/1.1 100 Continue\r\n\r\n");

						// FIXME: let the user write out 103 early hints too
					}
				}
				// else
				// ignore it

			}
		}

		inputData.consume(idx + 4);
		// done

		requestHeaders = assumeUnique(requestHeadersHere);

		ByChunkRange dataByChunk;

		// reading Content-Length type data
		// We need to read up the data we have, and write it out as a chunk.
		if(!isChunked) {
			dataByChunk = byChunk(inputData, contentLength);
		} else {
			// chunked requests happen, but not every day. Since we need to know
			// the content length (for now, maybe that should change), we'll buffer
			// the whole thing here instead of parse streaming. (I think this is what Apache does anyway in cgi modes)
			auto data = dechunk(inputData);

			// set the range here
			dataByChunk = byChunk(data);
			contentLength = data.length;
		}

		assert(dataByChunk !is null);

		if(contentLength) {
			prepareForIncomingDataChunks(contentType, contentLength);
			foreach(dataChunk; dataByChunk) {
				handleIncomingDataChunk(dataChunk);
			}
			postArray = assumeUnique(pps._post);
			filesArray = assumeUnique(pps._files);
			files = keepLastOf(filesArray);
			post = keepLastOf(postArray);
			postBody = pps.postBody;
			cleanUpPostDataState();
		}

		this.port = port;
		this.referrer = referrer;
		this.remoteAddress = remoteAddress;
		this.userAgent = userAgent;
		this.authorization = authorization;
		this.origin = origin;
		this.accept = accept;
		this.lastEventId = lastEventId;
		this.https = https;
		this.host = host;
		this.requestMethod = requestMethod;
		this.requestUri = requestUri;
		this.pathInfo = pathInfo;
		this.queryString = queryString;

		this.scriptName = scriptName;
		this.get = keepLastOf(getArray);
		this.getArray = cast(immutable) getArray;
		this.keepAliveRequested = keepAliveRequested;
		this.acceptsGzip = acceptsGzip;
		this.cookie = cookie;

		cookiesArray = getCookieArray();
		cookies = keepLastOf(cookiesArray);

	}
	BufferedInputRange idlol;

	private immutable(string[string]) keepLastOf(in string[][string] arr) {
		string[string] ca;
		foreach(k, v; arr)
			ca[k] = v[$-1];

		return assumeUnique(ca);
	}

	// FIXME duplication
	private immutable(UploadedFile[string]) keepLastOf(in UploadedFile[][string] arr) {
		UploadedFile[string] ca;
		foreach(k, v; arr)
			ca[k] = v[$-1];

		return assumeUnique(ca);
	}


	private immutable(string[][string]) getCookieArray() {
		auto forTheLoveOfGod = decodeVariables(cookie, "; ");
		return assumeUnique(forTheLoveOfGod);
	}

	/// Very simple method to require a basic auth username and password.
	/// If the http request doesn't include the required credentials, it throws a
	/// HTTP 401 error, and an exception.
	///
	/// Note: basic auth does not provide great security, especially over unencrypted HTTP;
	/// the user's credentials are sent in plain text on every request.
	///
	/// If you are using Apache, the HTTP_AUTHORIZATION variable may not be sent to the
	/// application. Either use Apache's built in methods for basic authentication, or add
	/// something along these lines to your server configuration:
	///
	///      RewriteEngine On
	///      RewriteCond %{HTTP:Authorization} ^(.*)
	///      RewriteRule ^(.*) - [E=HTTP_AUTHORIZATION:%1]
	///
	/// To ensure the necessary data is available to cgi.d.
	void requireBasicAuth(string user, string pass, string message = null) {
		if(authorization != "Basic " ~ Base64.encode(cast(immutable(ubyte)[]) (user ~ ":" ~ pass))) {
			setResponseStatus("401 Authorization Required");
			header ("WWW-Authenticate: Basic realm=\""~message~"\"");
			close();
			throw new Exception("Not authorized; got " ~ authorization);
		}
	}

	/// Very simple caching controls - setCache(false) means it will never be cached. Good for rapidly updated or sensitive sites.
	/// setCache(true) means it will always be cached for as long as possible. Best for static content.
	/// Use setResponseExpires and updateResponseExpires for more control
	void setCache(bool allowCaching) {
		noCache = !allowCaching;
	}

	/// Set to true and use cgi.write(data, true); to send a gzipped response to browsers
	/// who can accept it
	bool gzipResponse;

	immutable bool acceptsGzip;
	immutable bool keepAliveRequested;

	/// Set to true if and only if this was initialized with command line arguments
	immutable bool isCalledWithCommandLineArguments;

	/// This gets a full url for the current request, including port, protocol, host, path, and query
	string getCurrentCompleteUri() const {
		ushort defaultPort = https ? 443 : 80;

		string uri = "http";
		if(https)
			uri ~= "s";
		uri ~= "://";
		uri ~= host;
		/+ // the host has the port so p sure this never needed, cgi on apache and embedded http all do the right hting now
		version(none)
		if(!(!port || port == defaultPort)) {
			uri ~= ":";
			uri ~= to!string(port);
		}
		+/
		uri ~= requestUri;
		return uri;
	}

	/// You can override this if your site base url isn't the same as the script name
	string logicalScriptName() const {
		return scriptName;
	}

	/++
		Sets the HTTP status of the response. For example, "404 File Not Found" or "500 Internal Server Error".
		It assumes "200 OK", and automatically changes to "302 Found" if you call setResponseLocation().
		Note setResponseStatus() must be called *before* you write() any data to the output.

		History:
			The `int` overload was added on January 11, 2021.
	+/
	void setResponseStatus(string status) {
		assert(!outputtedResponseData);
		responseStatus = status;
	}
	/// ditto
	void setResponseStatus(int statusCode) {
		setResponseStatus(getHttpCodeText(statusCode));
	}
	private string responseStatus = null;

	/// Returns true if it is still possible to output headers
	bool canOutputHeaders() {
		return !isClosed && !outputtedResponseData;
	}

	/// Sets the location header, which the browser will redirect the user to automatically.
	/// Note setResponseLocation() must be called *before* you write() any data to the output.
	/// The optional important argument is used if it's a default suggestion rather than something to insist upon.
	void setResponseLocation(string uri, bool important = true, string status = null) {
		if(!important && isCurrentResponseLocationImportant)
			return; // important redirects always override unimportant ones

		if(uri is null) {
			responseStatus = "200 OK";
			responseLocation = null;
			isCurrentResponseLocationImportant = important;
			return; // this just cancels the redirect
		}

		assert(!outputtedResponseData);
		if(status is null)
			responseStatus = "302 Found";
		else
			responseStatus = status;

		responseLocation = uri.strip;
		isCurrentResponseLocationImportant = important;
	}
	protected string responseLocation = null;
	private bool isCurrentResponseLocationImportant = false;

	/// Sets the Expires: http header. See also: updateResponseExpires, setPublicCaching
	/// The parameter is in unix_timestamp * 1000. Try setResponseExpires(getUTCtime() + SOME AMOUNT) for normal use.
	/// Note: the when parameter is different than setCookie's expire parameter.
	void setResponseExpires(long when, bool isPublic = false) {
		responseExpires = when;
		setCache(true); // need to enable caching so the date has meaning

		responseIsPublic = isPublic;
		responseExpiresRelative = false;
	}

	/// Sets a cache-control max-age header for whenFromNow, in seconds.
	void setResponseExpiresRelative(int whenFromNow, bool isPublic = false) {
		responseExpires = whenFromNow;
		setCache(true); // need to enable caching so the date has meaning

		responseIsPublic = isPublic;
		responseExpiresRelative = true;
	}
	private long responseExpires = long.min;
	private bool responseIsPublic = false;
	private bool responseExpiresRelative = false;

	/// This is like setResponseExpires, but it can be called multiple times. The setting most in the past is the one kept.
	/// If you have multiple functions, they all might call updateResponseExpires about their own return value. The program
	/// output as a whole is as cacheable as the least cachable part in the chain.

	/// setCache(false) always overrides this - it is, by definition, the strictest anti-cache statement available. If your site outputs sensitive user data, you should probably call setCache(false) when you do, to ensure no other functions will cache the content, as it may be a privacy risk.
	/// Conversely, setting here overrides setCache(true), since any expiration date is in the past of infinity.
	void updateResponseExpires(long when, bool isPublic) {
		if(responseExpires == long.min)
			setResponseExpires(when, isPublic);
		else if(when < responseExpires)
			setResponseExpires(when, responseIsPublic && isPublic); // if any part of it is private, it all is
	}

	/*
	/// Set to true if you want the result to be cached publically - that is, is the content shared?
	/// Should generally be false if the user is logged in. It assumes private cache only.
	/// setCache(true) also turns on public caching, and setCache(false) sets to private.
	void setPublicCaching(bool allowPublicCaches) {
		publicCaching = allowPublicCaches;
	}
	private bool publicCaching = false;
	*/

	/++
		History:
			Added January 11, 2021
	+/
	enum SameSitePolicy {
		Lax,
		Strict,
		None
	}

	/++
		Sets an HTTP cookie, automatically encoding the data to the correct string.
		expiresIn is how many milliseconds in the future the cookie will expire.
		TIP: to make a cookie accessible from subdomains, set the domain to .yourdomain.com.
		Note setCookie() must be called *before* you write() any data to the output.

		History:
			Parameter `sameSitePolicy` was added on January 11, 2021.
	+/
	void setCookie(string name, string data, long expiresIn = 0, string path = null, string domain = null, bool httpOnly = false, bool secure = false, SameSitePolicy sameSitePolicy = SameSitePolicy.Lax) {
		assert(!outputtedResponseData);
		string cookie = std.uri.encodeComponent(name) ~ "=";
		cookie ~= std.uri.encodeComponent(data);
		if(path !is null)
			cookie ~= "; path=" ~ path;
		// FIXME: should I just be using max-age here? (also in cache below)
		if(expiresIn != 0)
			cookie ~= "; expires=" ~ printDate(cast(DateTime) Clock.currTime(UTC()) + dur!"msecs"(expiresIn));
		if(domain !is null)
			cookie ~= "; domain=" ~ domain;
		if(secure == true)
			cookie ~= "; Secure";
		if(httpOnly == true )
			cookie ~= "; HttpOnly";
		final switch(sameSitePolicy) {
			case SameSitePolicy.Lax:
				cookie ~= "; SameSite=Lax";
			break;
			case SameSitePolicy.Strict:
				cookie ~= "; SameSite=Strict";
			break;
			case SameSitePolicy.None:
				cookie ~= "; SameSite=None";
				assert(secure); // cookie spec requires this now, see: https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Set-Cookie/SameSite
			break;
		}

		if(auto idx = name in cookieIndexes) {
			responseCookies[*idx] = cookie;
		} else {
			cookieIndexes[name] = responseCookies.length;
			responseCookies ~= cookie;
		}
	}
	private string[] responseCookies;
	private size_t[string] cookieIndexes;

	/// Clears a previously set cookie with the given name, path, and domain.
	void clearCookie(string name, string path = null, string domain = null) {
		assert(!outputtedResponseData);
		setCookie(name, "", 1, path, domain);
	}

	/// Sets the content type of the response, for example "text/html" (the default) for HTML, or "image/png" for a PNG image
	void setResponseContentType(string ct) {
		assert(!outputtedResponseData);
		responseContentType = ct;
	}
	private string responseContentType = null;

	/// Adds a custom header. It should be the name: value, but without any line terminator.
	/// For example: header("X-My-Header: Some value");
	/// Note you should use the specialized functions in this object if possible to avoid
	/// duplicates in the output.
	void header(string h) {
		customHeaders ~= h;
	}

	/++
		I named the original function `header` after PHP, but this pattern more fits
		the rest of the Cgi object.

		Either name are allowed.

		History:
			Alias added June 17, 2022.
	+/
	alias setResponseHeader = header;

	private string[] customHeaders;
	private bool websocketMode;

	void flushHeaders(const(void)[] t, bool isAll = false) {
		StackBuffer buffer = StackBuffer(0);

		prepHeaders(t, isAll, &buffer);

		if(rawDataOutput !is null)
			rawDataOutput(cast(const(ubyte)[]) buffer.get());
		else {
			stdout.rawWrite(buffer.get());
		}
	}

	private void prepHeaders(const(void)[] t, bool isAll, StackBuffer* buffer) {
		string terminator = "\n";
		if(rawDataOutput !is null)
			terminator = "\r\n";

		if(responseStatus !is null) {
			if(nph) {
				if(http10)
					buffer.add("HTTP/1.0 ", responseStatus, terminator);
				else
					buffer.add("HTTP/1.1 ", responseStatus, terminator);
			} else
				buffer.add("Status: ", responseStatus, terminator);
		} else if (nph) {
			if(http10)
				buffer.add("HTTP/1.0 200 OK", terminator);
			else
				buffer.add("HTTP/1.1 200 OK", terminator);
		}

		if(websocketMode)
			goto websocket;

		if(nph) { // we're responsible for setting the date too according to http 1.1
			char[29] db = void;
			printDateToBuffer(cast(DateTime) Clock.currTime(UTC()), db[]);
			buffer.add("Date: ", db[], terminator);
		}

		// FIXME: what if the user wants to set his own content-length?
		// The custom header function can do it, so maybe that's best.
		// Or we could reuse the isAll param.
		if(responseLocation !is null) {
			buffer.add("Location: ", responseLocation, terminator);
		}
		if(!noCache && responseExpires != long.min) { // an explicit expiration date is set
			if(responseExpiresRelative) {
				buffer.add("Cache-Control: ", responseIsPublic ? "public" : "private", ", max-age=");
				buffer.add(responseExpires);
				buffer.add(", no-cache=\"set-cookie, set-cookie2\"", terminator);
			} else {
				auto expires = SysTime(unixTimeToStdTime(cast(int)(responseExpires / 1000)), UTC());
				char[29] db = void;
				printDateToBuffer(cast(DateTime) expires, db[]);
				buffer.add("Expires: ", db[], terminator);
				// FIXME: assuming everything is private unless you use nocache - generally right for dynamic pages, but not necessarily
				buffer.add("Cache-Control: ", (responseIsPublic ? "public" : "private"), ", no-cache=\"set-cookie, set-cookie2\"");
				buffer.add(terminator);
			}
		}
		if(responseCookies !is null && responseCookies.length > 0) {
			foreach(c; responseCookies)
				buffer.add("Set-Cookie: ", c, terminator);
		}
		if(noCache) { // we specifically do not want caching (this is actually the default)
			buffer.add("Cache-Control: private, no-cache=\"set-cookie\"", terminator);
			buffer.add("Expires: 0", terminator);
			buffer.add("Pragma: no-cache", terminator);
		} else {
			if(responseExpires == long.min) { // caching was enabled, but without a date set - that means assume cache forever
				buffer.add("Cache-Control: public", terminator);
				buffer.add("Expires: Tue, 31 Dec 2030 14:00:00 GMT", terminator); // FIXME: should not be more than one year in the future
			}
		}
		if(responseContentType !is null) {
			buffer.add("Content-Type: ", responseContentType, terminator);
		} else
			buffer.add("Content-Type: text/html; charset=utf-8", terminator);

		if(gzipResponse && acceptsGzip && isAll) { // FIXME: isAll really shouldn't be necessary
			buffer.add("Content-Encoding: gzip", terminator);
		}


		if(!isAll) {
			if(nph && !http10) {
				buffer.add("Transfer-Encoding: chunked", terminator);
				responseChunked = true;
			}
		} else {
			buffer.add("Content-Length: ");
			buffer.add(t.length);
			buffer.add(terminator);
			if(nph && keepAliveRequested) {
				buffer.add("Connection: Keep-Alive", terminator);
			}
		}

		websocket:

		foreach(hd; customHeaders)
			buffer.add(hd, terminator);

		// FIXME: what about duplicated headers?

		// end of header indicator
		buffer.add(terminator);

		outputtedResponseData = true;
	}

	/// Writes the data to the output, flushing headers if they have not yet been sent.
	void write(const(void)[] t, bool isAll = false, bool maybeAutoClose = true) {
		assert(!closed, "Output has already been closed");

		StackBuffer buffer = StackBuffer(0);

		if(gzipResponse && acceptsGzip && isAll) { // FIXME: isAll really shouldn't be necessary
			// actually gzip the data here

			auto c = new Compress(HeaderFormat.gzip); // want gzip

			auto data = c.compress(t);
			data ~= c.flush();

			// std.file.write("/tmp/last-item", data);

			t = data;
		}

		if(!outputtedResponseData && (!autoBuffer || isAll)) {
			prepHeaders(t, isAll, &buffer);
		}

		if(requestMethod != RequestMethod.HEAD && t.length > 0) {
			if (autoBuffer && !isAll) {
				outputBuffer ~= cast(ubyte[]) t;
			}
			if(!autoBuffer || isAll) {
				if(rawDataOutput !is null)
					if(nph && responseChunked) {
						//rawDataOutput(makeChunk(cast(const(ubyte)[]) t));
						// we're making the chunk here instead of in a function
						// to avoid unneeded gc pressure
						buffer.add(toHex(t.length));
						buffer.add("\r\n");
						buffer.add(cast(char[]) t, "\r\n");
					} else {
						buffer.add(cast(char[]) t);
					}
				else
					buffer.add(cast(char[]) t);
			}
		}

		if(rawDataOutput !is null)
			rawDataOutput(cast(const(ubyte)[]) buffer.get());
		else
			stdout.rawWrite(buffer.get());

		if(maybeAutoClose && isAll)
			close(); // if you say it is all, that means we're definitely done
				// maybeAutoClose can be false though to avoid this (important if you call from inside close()!
	}

	/++
		Convenience method to set content type to json and write the string as the complete response.

		History:
			Added January 16, 2020
	+/
	void writeJson(string json) {
		this.setResponseContentType("application/json");
		this.write(json, true);
	}

	/// Flushes the pending buffer, leaving the connection open so you can send more.
	void flush() {
		if(rawDataOutput is null)
			stdout.flush();
		else if(flushDelegate !is null)
			flushDelegate();
	}

	version(autoBuffer)
		bool autoBuffer = true;
	else
		bool autoBuffer = false;
	ubyte[] outputBuffer;

	/// Flushes the buffers to the network, signifying that you are done.
	/// You should always call this explicitly when you are done outputting data.
	void close() {
		if(closed)
			return; // don't double close

		if(!outputtedResponseData)
			write("", false, false);

		// writing auto buffered data
		if(requestMethod != RequestMethod.HEAD && autoBuffer) {
			if(!nph)
				stdout.rawWrite(outputBuffer);
			else
				write(outputBuffer, true, false); // tell it this is everything
		}

		// closing the last chunk...
		if(nph && rawDataOutput !is null && responseChunked)
			rawDataOutput(cast(const(ubyte)[]) "0\r\n\r\n");

		if(flushDelegate)
			flushDelegate();

		closed = true;
	}

	// Closes without doing anything, shouldn't be used often
	void rawClose() {
		closed = true;
	}

	/++
		Gets a request variable as a specific type, or the default value of it isn't there
		or isn't convertible to the request type.

		Checks both GET and POST variables, preferring the POST variable, if available.

		A nice trick is using the default value to choose the type:

		---
			/*
				The return value will match the type of the default.
				Here, I gave 10 as a default, so the return value will
				be an int.

				If the user-supplied value cannot be converted to the
				requested type, you will get the default value back.
			*/
			int a = cgi.request("number", 10);

			if(cgi.get["number"] == "11")
				assert(a == 11); // conversion succeeds

			if("number" !in cgi.get)
				assert(a == 10); // no value means you can't convert - give the default

			if(cgi.get["number"] == "twelve")
				assert(a == 10); // conversion from string to int would fail, so we get the default
		---

		You can use an enum as an easy whitelist, too:

		---
			enum Operations {
				add, remove, query
			}

			auto op = cgi.request("op", Operations.query);

			if(cgi.get["op"] == "add")
				assert(op == Operations.add);
			if(cgi.get["op"] == "remove")
				assert(op == Operations.remove);
			if(cgi.get["op"] == "query")
				assert(op == Operations.query);

			if(cgi.get["op"] == "random string")
				assert(op == Operations.query); // the value can't be converted to the enum, so we get the default
		---
	+/
	T request(T = string)(in string name, in T def = T.init) const nothrow {
		try {
			return
				(name in post) ? to!T(post[name]) :
				(name in get)  ? to!T(get[name]) :
				def;
		} catch(Exception e) { return def; }
	}

	/// Is the output already closed?
	bool isClosed() const {
		return closed;
	}

	/++
		Gets a session object associated with the `cgi` request. You can use different type throughout your application.
	+/
	Session!Data getSessionObject(Data)() {
		if(testInProcess !is null) {
			// test mode
			auto obj = testInProcess.getSessionOverride(typeid(typeof(return)));
			if(obj !is null)
				return cast(typeof(return)) obj;
			else {
				auto o = new MockSession!Data();
				testInProcess.setSessionOverride(typeid(typeof(return)), o);
				return o;
			}
		} else {
			// normal operation
			return new BasicDataServerSession!Data(this);
		}
	}

	// if it is in test mode; triggers mock sessions. Used by CgiTester
	version(with_breaking_cgi_features)
	private CgiTester testInProcess;

	/* Hooks for redirecting input and output */
	private void delegate(const(ubyte)[]) rawDataOutput = null;
	private void delegate() flushDelegate = null;

	/* This info is used when handling a more raw HTTP protocol */
	private bool nph;
	private bool http10;
	private bool closed;
	private bool responseChunked = false;

	version(preserveData) // note: this can eat lots of memory; don't use unless you're sure you need it.
	immutable(ubyte)[] originalPostData;

	public immutable string postBody;
	alias postJson = postBody; // old name

	/* Internal state flags */
	private bool outputtedResponseData;
	private bool noCache = true;

	const(string[string]) environmentVariables;

	/** What follows is data gotten from the HTTP request. It is all fully immutable,
	    partially because it logically is (your code doesn't change what the user requested...)
	    and partially because I hate how bad programs in PHP change those superglobals to do
	    all kinds of hard to follow ugliness. I don't want that to ever happen in D.

	    For some of these, you'll want to refer to the http or cgi specs for more details.
	*/
	immutable(string[string]) requestHeaders; /// All the raw headers in the request as name/value pairs. The name is stored as all lower case, but otherwise the same as it is in HTTP; words separated by dashes. For example, "cookie" or "accept-encoding". Many HTTP headers have specialized variables below for more convenience and static name checking; you should generally try to use them.

	immutable(char[]) host; 	/// The hostname in the request. If one program serves multiple domains, you can use this to differentiate between them.
	immutable(char[]) origin; 	/// The origin header in the request, if present. Some HTML5 cross-domain apis set this and you should check it on those cross domain requests and websockets.
	immutable(char[]) userAgent; 	/// The browser's user-agent string. Can be used to identify the browser.
	immutable(char[]) pathInfo; 	/// This is any stuff sent after your program's name on the url, but before the query string. For example, suppose your program is named "app". If the user goes to site.com/app, pathInfo is empty. But, he can also go to site.com/app/some/sub/path; treating your program like a virtual folder. In this case, pathInfo == "/some/sub/path".
	immutable(char[]) scriptName;   /// The full base path of your program, as seen by the user. If your program is located at site.com/programs/apps, scriptName == "/programs/apps".
	immutable(char[]) scriptFileName;   /// The physical filename of your script
	immutable(char[]) authorization; /// The full authorization string from the header, undigested. Useful for implementing auth schemes such as OAuth 1.0. Note that some web servers do not forward this to the app without taking extra steps. See requireBasicAuth's comment for more info.
	immutable(char[]) accept; 	/// The HTTP accept header is the user agent telling what content types it is willing to accept. This is often */*; they accept everything, so it's not terribly useful. (The similar sounding Accept-Encoding header is handled automatically for chunking and gzipping. Simply set gzipResponse = true and cgi.d handles the details, zipping if the user's browser is willing to accept it.)
	immutable(char[]) lastEventId; 	/// The HTML 5 draft includes an EventSource() object that connects to the server, and remains open to take a stream of events. My arsd.rtud module can help with the server side part of that. The Last-Event-Id http header is defined in the draft to help handle loss of connection. When the browser reconnects to you, it sets this header to the last event id it saw, so you can catch it up. This member has the contents of that header.

	immutable(RequestMethod) requestMethod; /// The HTTP request verb: GET, POST, etc. It is represented as an enum in cgi.d (which, like many enums, you can convert back to string with std.conv.to()). A HTTP GET is supposed to, according to the spec, not have side effects; a user can GET something over and over again and always have the same result. On all requests, the get[] and getArray[] members may be filled in. The post[] and postArray[] members are only filled in on POST methods.
	immutable(char[]) queryString; 	/// The unparsed content of the request query string - the stuff after the ? in your URL. See get[] and getArray[] for a parse view of it. Sometimes, the unparsed string is useful though if you want a custom format of data up there (probably not a good idea, unless it is really simple, like "?username" perhaps.)
	immutable(char[]) cookie; 	/// The unparsed content of the Cookie: header in the request. See also the cookies[string] member for a parsed view of the data.
	/** The Referer header from the request. (It is misspelled in the HTTP spec, and thus the actual request and cgi specs too, but I spelled the word correctly here because that's sane. The spec's misspelling is an implementation detail.) It contains the site url that referred the user to your program; the site that linked to you, or if you're serving images, the site that has you as an image. Also, if you're in an iframe, the referrer is the site that is framing you.

	Important note: if the user copy/pastes your url, this is blank, and, just like with all other user data, their browsers can also lie to you. Don't rely on it for real security.
	*/
	immutable(char[]) referrer;
	immutable(char[]) requestUri; 	/// The full url if the current request, excluding the protocol and host. requestUri == scriptName ~ pathInfo ~ (queryString.length ? "?" ~ queryString : "");

	immutable(char[]) remoteAddress; /// The IP address of the user, as we see it. (Might not match the IP of the user's computer due to things like proxies and NAT.)

	immutable bool https; 	/// Was the request encrypted via https?
	immutable int port; 	/// On what TCP port number did the server receive the request?

	/** Here come the parsed request variables - the things that come close to PHP's _GET, _POST, etc. superglobals in content. */

	immutable(string[string]) get; 	/// The data from your query string in the url, only showing the last string of each name. If you want to handle multiple values with the same name, use getArray. This only works right if the query string is x-www-form-urlencoded; the default you see on the web with name=value pairs separated by the & character.
	immutable(string[string]) post; /// The data from the request's body, on POST requests. It parses application/x-www-form-urlencoded data (used by most web requests, including typical forms), and multipart/form-data requests (used by file uploads on web forms) into the same container, so you can always access them the same way. It makes no attempt to parse other content types. If you want to accept an XML Post body (for a web api perhaps), you'll need to handle the raw data yourself.
	immutable(string[string]) cookies; /// Separates out the cookie header into individual name/value pairs (which is how you set them!)

	/**
		Represents user uploaded files.

		When making a file upload form, be sure to follow the standard: set method="POST" and enctype="multipart/form-data" in your html <form> tag attributes. The key into this array is the name attribute on your input tag, just like with other post variables. See the comments on the UploadedFile struct for more information about the data inside, including important notes on max size and content location.
	*/
	immutable(UploadedFile[][string]) filesArray;
	immutable(UploadedFile[string]) files;

	/// Use these if you expect multiple items submitted with the same name. btw, assert(get[name] is getArray[name][$-1); should pass. Same for post and cookies.
	/// the order of the arrays is the order the data arrives
	immutable(string[][string]) getArray; /// like get, but an array of values per name
	immutable(string[][string]) postArray; /// ditto for post
	immutable(string[][string]) cookiesArray; /// ditto for cookies

	// convenience function for appending to a uri without extra ?
	// matches the name and effect of javascript's location.search property
	string search() const {
		if(queryString.length)
			return "?" ~ queryString;
		return "";
	}

	// FIXME: what about multiple files with the same name?
  private:
	//RequestMethod _requestMethod;
}

/// use this for testing or other isolated things when you want it to be no-ops
Cgi dummyCgi(Cgi.RequestMethod method = Cgi.RequestMethod.GET, string url = null, in ubyte[] data = null, void delegate(const(ubyte)[]) outputSink = null) {
	// we want to ignore, not use stdout
	if(outputSink is null)
		outputSink = delegate void(const(ubyte)[]) { };

	string[string] env;
	env["REQUEST_METHOD"] = to!string(method);
	env["CONTENT_LENGTH"] = to!string(data.length);

	auto cgi = new Cgi(
		0,
		env,
		{ return data; },
		outputSink,
		null);

	return cgi;
}

/++
	A helper test class for request handler unittests.
+/
version(with_breaking_cgi_features)
class CgiTester {
	private {
		SessionObject[TypeInfo] mockSessions;
		SessionObject getSessionOverride(TypeInfo ti) {
			if(auto o = ti in mockSessions)
				return *o;
			else
				return null;
		}
		void setSessionOverride(TypeInfo ti, SessionObject so) {
			mockSessions[ti] = so;
		}
	}

	/++
		Gets (and creates if necessary) a mock session object for this test. Note
		it will be the same one used for any test operations through this CgiTester instance.
	+/
	Session!Data getSessionObject(Data)() {
		auto obj = getSessionOverride(typeid(typeof(return)));
		if(obj !is null)
			return cast(typeof(return)) obj;
		else {
			auto o = new MockSession!Data();
			setSessionOverride(typeid(typeof(return)), o);
			return o;
		}
	}

	/++
		Pass a reference to your request handler when creating the tester.
	+/
	this(void function(Cgi) requestHandler) {
		this.requestHandler = requestHandler;
	}

	/++
		You can check response information with these methods after you call the request handler.
	+/
	struct Response {
		int code;
		string[string] headers;
		string responseText;
		ubyte[] responseBody;
	}

	/++
		Executes a test request on your request handler, and returns the response.

		Params:
			url = The URL to test. Should be an absolute path, but excluding domain. e.g. `"/test"`.
			args = additional arguments. Same format as cgi's command line handler.
	+/
	Response GET(string url, string[] args = null) {
		return executeTest("GET", url, args);
	}
	/// ditto
	Response POST(string url, string[] args = null) {
		return executeTest("POST", url, args);
	}

	/// ditto
	Response executeTest(string method, string url, string[] args) {
		ubyte[] outputtedRawData;
		void outputSink(const(ubyte)[] data) {
			outputtedRawData ~= data;
		}
		auto cgi = new Cgi(["test", method, url] ~ args, &outputSink);
		cgi.testInProcess = this;
		scope(exit) cgi.dispose();

		requestHandler(cgi);

		cgi.close();

		Response response;

		if(outputtedRawData.length) {
			enum LINE = "\r\n";

			auto idx = outputtedRawData.locationOf(LINE ~ LINE);
			assert(idx != -1, to!string(outputtedRawData));
			auto headers = cast(string) outputtedRawData[0 .. idx];
			response.code = 200;
			while(headers.length) {
				auto i = headers.locationOf(LINE);
				if(i == -1) i = cast(int) headers.length;

				auto header = headers[0 .. i];

				auto c = header.locationOf(":");
				if(c != -1) {
					auto name = header[0 .. c];
					auto value = header[c + 2 ..$];

					if(name == "Status")
						response.code = value[0 .. value.locationOf(" ")].to!int;

					response.headers[name] = value;
				} else {
					assert(0);
				}

				if(i != headers.length)
					i += 2;
				headers = headers[i .. $];
			}
			response.responseBody = outputtedRawData[idx + 4 .. $];
			response.responseText = cast(string) response.responseBody;
		}

		return response;
	}

	private void function(Cgi) requestHandler;
}


// should this be a separate module? Probably, but that's a hassle.

/// Makes a data:// uri that can be used as links in most newer browsers (IE8+).
string makeDataUrl(string mimeType, in void[] data) {
	auto data64 = Base64.encode(cast(const(ubyte[])) data);
	return "data:" ~ mimeType ~ ";base64," ~ assumeUnique(data64);
}

// FIXME: I don't think this class correctly decodes/encodes the individual parts
/// Represents a url that can be broken down or built up through properties
struct Uri {
	alias toString this; // blargh idk a url really is a string, but should it be implicit?

	// scheme//userinfo@host:port/path?query#fragment

	string scheme; /// e.g. "http" in "http://example.com/"
	string userinfo; /// the username (and possibly a password) in the uri
	string host; /// the domain name
	int port; /// port number, if given. Will be zero if a port was not explicitly given
	string path; /// e.g. "/folder/file.html" in "http://example.com/folder/file.html"
	string query; /// the stuff after the ? in a uri
	string fragment; /// the stuff after the # in a uri.

	// idk if i want to keep these, since the functions they wrap are used many, many, many times in existing code, so this is either an unnecessary alias or a gratuitous break of compatibility
	// the decode ones need to keep different names anyway because we can't overload on return values...
	static string encode(string s) { return std.uri.encodeComponent(s); }
	static string encode(string[string] s) { return encodeVariables(s); }
	static string encode(string[][string] s) { return encodeVariables(s); }

	/// Breaks down a uri string to its components
	this(string uri) {
		reparse(uri);
	}

	private void reparse(string uri) {
		// from RFC 3986
		// the ctRegex triples the compile time and makes ugly errors for no real benefit
		// it was a nice experiment but just not worth it.
		// enum ctr = ctRegex!r"^(([^:/?#]+):)?(//([^/?#]*))?([^?#]*)(\?([^#]*))?(#(.*))?";
		/*
			Captures:
				0 = whole url
				1 = scheme, with :
				2 = scheme, no :
				3 = authority, with //
				4 = authority, no //
				5 = path
				6 = query string, with ?
				7 = query string, no ?
				8 = anchor, with #
				9 = anchor, no #
		*/
		// Yikes, even regular, non-CT regex is also unacceptably slow to compile. 1.9s on my computer!
		// instead, I will DIY and cut that down to 0.6s on the same computer.
		/*

				Note that authority is
					user:password@domain:port
				where the user:password@ part is optional, and the :port is optional.

				Regex translation:

				Scheme cannot have :, /, ?, or # in it, and must have one or more chars and end in a :. It is optional, but must be first.
				Authority must start with //, but cannot have any other /, ?, or # in it. It is optional.
				Path cannot have any ? or # in it. It is optional.
				Query must start with ? and must not have # in it. It is optional.
				Anchor must start with # and can have anything else in it to end of string. It is optional.
		*/

		this = Uri.init; // reset all state

		// empty uri = nothing special
		if(uri.length == 0) {
			return;
		}

		size_t idx;

		scheme_loop: foreach(char c; uri[idx .. $]) {
			switch(c) {
				case ':':
				case '/':
				case '?':
				case '#':
					break scheme_loop;
				default:
			}
			idx++;
		}

		if(idx == 0 && uri[idx] == ':') {
			// this is actually a path! we skip way ahead
			goto path_loop;
		}

		if(idx == uri.length) {
			// the whole thing is a path, apparently
			path = uri;
			return;
		}

		if(idx > 0 && uri[idx] == ':') {
			scheme = uri[0 .. idx];
			idx++;
		} else {
			// we need to rewind; it found a / but no :, so the whole thing is prolly a path...
			idx = 0;
		}

		if(idx + 2 < uri.length && uri[idx .. idx + 2] == "//") {
			// we have an authority....
			idx += 2;

			auto authority_start = idx;
			authority_loop: foreach(char c; uri[idx .. $]) {
				switch(c) {
					case '/':
					case '?':
					case '#':
						break authority_loop;
					default:
				}
				idx++;
			}

			auto authority = uri[authority_start .. idx];

			auto idx2 = authority.indexOf("@");
			if(idx2 != -1) {
				userinfo = authority[0 .. idx2];
				authority = authority[idx2 + 1 .. $];
			}

			if(authority.length && authority[0] == '[') {
				// ipv6 address special casing
				idx2 = authority.indexOf(']');
				if(idx2 != -1) {
					auto end = authority[idx2 + 1 .. $];
					if(end.length && end[0] == ':')
						idx2 = idx2 + 1;
					else
						idx2 = -1;
				}
			} else {
				idx2 = authority.indexOf(":");
			}

			if(idx2 == -1) {
				port = 0; // 0 means not specified; we should use the default for the scheme
				host = authority;
			} else {
				host = authority[0 .. idx2];
				if(idx2 + 1 < authority.length)
					port = to!int(authority[idx2 + 1 .. $]);
				else
					port = 0;
			}
		}

		path_loop:
		auto path_start = idx;

		foreach(char c; uri[idx .. $]) {
			if(c == '?' || c == '#')
				break;
			idx++;
		}

		path = uri[path_start .. idx];

		if(idx == uri.length)
			return; // nothing more to examine...

		if(uri[idx] == '?') {
			idx++;
			auto query_start = idx;
			foreach(char c; uri[idx .. $]) {
				if(c == '#')
					break;
				idx++;
			}
			query = uri[query_start .. idx];
		}

		if(idx < uri.length && uri[idx] == '#') {
			idx++;
			fragment = uri[idx .. $];
		}

		// uriInvalidated = false;
	}

	private string rebuildUri() const {
		string ret;
		if(scheme.length)
			ret ~= scheme ~ ":";
		if(userinfo.length || host.length)
			ret ~= "//";
		if(userinfo.length)
			ret ~= userinfo ~ "@";
		if(host.length)
			ret ~= host;
		if(port)
			ret ~= ":" ~ to!string(port);

		ret ~= path;

		if(query.length)
			ret ~= "?" ~ query;

		if(fragment.length)
			ret ~= "#" ~ fragment;

		// uri = ret;
		// uriInvalidated = false;
		return ret;
	}

	/// Converts the broken down parts back into a complete string
	string toString() const {
		// if(uriInvalidated)
			return rebuildUri();
	}

	/// Returns a new absolute Uri given a base. It treats this one as
	/// relative where possible, but absolute if not. (If protocol, domain, or
	/// other info is not set, the new one inherits it from the base.)
	///
	/// Browsers use a function like this to figure out links in html.
	Uri basedOn(in Uri baseUrl) const {
		Uri n = this; // copies
		if(n.scheme == "data")
			return n;
		// n.uriInvalidated = true; // make sure we regenerate...

		// userinfo is not inherited... is this wrong?

		// if anything is given in the existing url, we don't use the base anymore.
		if(n.scheme.empty) {
			n.scheme = baseUrl.scheme;
			if(n.host.empty) {
				n.host = baseUrl.host;
				if(n.port == 0) {
					n.port = baseUrl.port;
					if(n.path.length > 0 && n.path[0] != '/') {
						auto b = baseUrl.path[0 .. baseUrl.path.lastIndexOf("/") + 1];
						if(b.length == 0)
							b = "/";
						n.path = b ~ n.path;
					} else if(n.path.length == 0) {
						n.path = baseUrl.path;
					}
				}
			}
		}

		n.removeDots();

		return n;
	}

	void removeDots() {
		auto parts = this.path.split("/");
		string[] toKeep;
		foreach(part; parts) {
			if(part == ".") {
				continue;
			} else if(part == "..") {
				//if(toKeep.length > 1)
					toKeep = toKeep[0 .. $-1];
				//else
					//toKeep = [""];
				continue;
			} else {
				//if(toKeep.length && toKeep[$-1].length == 0 && part.length == 0)
					//continue; // skip a `//` situation
				toKeep ~= part;
			}
		}

		auto path = toKeep.join("/");
		if(path.length && path[0] != '/')
			path = "/" ~ path;

		this.path = path;
	}

	unittest {
		auto uri = Uri("test.html");
		assert(uri.path == "test.html");
		uri = Uri("path/1/lol");
		assert(uri.path == "path/1/lol");
		uri = Uri("http://me@example.com");
		assert(uri.scheme == "http");
		assert(uri.userinfo == "me");
		assert(uri.host == "example.com");
		uri = Uri("http://example.com/#a");
		assert(uri.scheme == "http");
		assert(uri.host == "example.com");
		assert(uri.fragment == "a");
		uri = Uri("#foo");
		assert(uri.fragment == "foo");
		uri = Uri("?lol");
		assert(uri.query == "lol");
		uri = Uri("#foo?lol");
		assert(uri.fragment == "foo?lol");
		uri = Uri("?lol#foo");
		assert(uri.fragment == "foo");
		assert(uri.query == "lol");

		uri = Uri("http://127.0.0.1/");
		assert(uri.host == "127.0.0.1");
		assert(uri.port == 0);

		uri = Uri("http://127.0.0.1:123/");
		assert(uri.host == "127.0.0.1");
		assert(uri.port == 123);

		uri = Uri("http://[ff:ff::0]/");
		assert(uri.host == "[ff:ff::0]");

		uri = Uri("http://[ff:ff::0]:123/");
		assert(uri.host == "[ff:ff::0]");
		assert(uri.port == 123);
	}

	// This can sometimes be a big pain in the butt for me, so lots of copy/paste here to cover
	// the possibilities.
	unittest {
		auto url = Uri("cool.html"); // checking relative links

		assert(url.basedOn(Uri("http://test.com/what/test.html")) == "http://test.com/what/cool.html");
		assert(url.basedOn(Uri("https://test.com/what/test.html")) == "https://test.com/what/cool.html");
		assert(url.basedOn(Uri("http://test.com/what/")) == "http://test.com/what/cool.html");
		assert(url.basedOn(Uri("http://test.com/")) == "http://test.com/cool.html");
		assert(url.basedOn(Uri("http://test.com")) == "http://test.com/cool.html");
		assert(url.basedOn(Uri("http://test.com/what/test.html?a=b")) == "http://test.com/what/cool.html");
		assert(url.basedOn(Uri("http://test.com/what/test.html?a=b&c=d")) == "http://test.com/what/cool.html");
		assert(url.basedOn(Uri("http://test.com/what/test.html?a=b&c=d#what")) == "http://test.com/what/cool.html");
		assert(url.basedOn(Uri("http://test.com")) == "http://test.com/cool.html");

		url = Uri("/something/cool.html"); // same server, different path
		assert(url.basedOn(Uri("http://test.com/what/test.html")) == "http://test.com/something/cool.html");
		assert(url.basedOn(Uri("https://test.com/what/test.html")) == "https://test.com/something/cool.html");
		assert(url.basedOn(Uri("http://test.com/what/")) == "http://test.com/something/cool.html");
		assert(url.basedOn(Uri("http://test.com/")) == "http://test.com/something/cool.html");
		assert(url.basedOn(Uri("http://test.com")) == "http://test.com/something/cool.html");
		assert(url.basedOn(Uri("http://test.com/what/test.html?a=b")) == "http://test.com/something/cool.html");
		assert(url.basedOn(Uri("http://test.com/what/test.html?a=b&c=d")) == "http://test.com/something/cool.html");
		assert(url.basedOn(Uri("http://test.com/what/test.html?a=b&c=d#what")) == "http://test.com/something/cool.html");
		assert(url.basedOn(Uri("http://test.com")) == "http://test.com/something/cool.html");

		url = Uri("?query=answer"); // same path. server, protocol, and port, just different query string and fragment
		assert(url.basedOn(Uri("http://test.com/what/test.html")) == "http://test.com/what/test.html?query=answer");
		assert(url.basedOn(Uri("https://test.com/what/test.html")) == "https://test.com/what/test.html?query=answer");
		assert(url.basedOn(Uri("http://test.com/what/")) == "http://test.com/what/?query=answer");
		assert(url.basedOn(Uri("http://test.com/")) == "http://test.com/?query=answer");
		assert(url.basedOn(Uri("http://test.com")) == "http://test.com?query=answer");
		assert(url.basedOn(Uri("http://test.com/what/test.html?a=b")) == "http://test.com/what/test.html?query=answer");
		assert(url.basedOn(Uri("http://test.com/what/test.html?a=b&c=d")) == "http://test.com/what/test.html?query=answer");
		assert(url.basedOn(Uri("http://test.com/what/test.html?a=b&c=d#what")) == "http://test.com/what/test.html?query=answer");
		assert(url.basedOn(Uri("http://test.com")) == "http://test.com?query=answer");

		url = Uri("/test/bar");
		assert(Uri("./").basedOn(url) == "/test/", Uri("./").basedOn(url));
		assert(Uri("../").basedOn(url) == "/");

		url = Uri("http://example.com/");
		assert(Uri("../foo").basedOn(url) == "http://example.com/foo");

		//auto uriBefore = url;
		url = Uri("#anchor"); // everything should remain the same except the anchor
		//uriBefore.anchor = "anchor");
		//assert(url == uriBefore);

		url = Uri("//example.com"); // same protocol, but different server. the path here should be blank.

		url = Uri("//example.com/example.html"); // same protocol, but different server and path

		url = Uri("http://example.com/test.html"); // completely absolute link should never be modified

		url = Uri("http://example.com"); // completely absolute link should never be modified, even if it has no path

		// FIXME: add something for port too
	}

	// these are like javascript's location.search and location.hash
	string search() const {
		return query.length ? ("?" ~ query) : "";
	}
	string hash() const {
		return fragment.length ? ("#" ~ fragment) : "";
	}
}


/*
	for session, see web.d
*/

/// breaks down a url encoded string
string[][string] decodeVariables(string data, string separator = "&", string[]* namesInOrder = null, string[]* valuesInOrder = null) {
	auto vars = data.split(separator);
	string[][string] _get;
	foreach(var; vars) {
		auto equal = var.indexOf("=");
		string name;
		string value;
		if(equal == -1) {
			name = decodeComponent(var);
			value = "";
		} else {
			//_get[decodeComponent(var[0..equal])] ~= decodeComponent(var[equal + 1 .. $].replace("+", " "));
			// stupid + -> space conversion.
			name = decodeComponent(var[0..equal].replace("+", " "));
			value = decodeComponent(var[equal + 1 .. $].replace("+", " "));
		}

		_get[name] ~= value;
		if(namesInOrder)
			(*namesInOrder) ~= name;
		if(valuesInOrder)
			(*valuesInOrder) ~= value;
	}
	return _get;
}

/// breaks down a url encoded string, but only returns the last value of any array
string[string] decodeVariablesSingle(string data) {
	string[string] va;
	auto varArray = decodeVariables(data);
	foreach(k, v; varArray)
		va[k] = v[$-1];

	return va;
}

/// url encodes the whole string
string encodeVariables(in string[string] data) {
	string ret;

	bool outputted = false;
	foreach(k, v; data) {
		if(outputted)
			ret ~= "&";
		else
			outputted = true;

		ret ~= std.uri.encodeComponent(k) ~ "=" ~ std.uri.encodeComponent(v);
	}

	return ret;
}

/// url encodes a whole string
string encodeVariables(in string[][string] data) {
	string ret;

	bool outputted = false;
	foreach(k, arr; data) {
		foreach(v; arr) {
			if(outputted)
				ret ~= "&";
			else
				outputted = true;
			ret ~= std.uri.encodeComponent(k) ~ "=" ~ std.uri.encodeComponent(v);
		}
	}

	return ret;
}

/// Encodes all but the explicitly unreserved characters per rfc 3986
/// Alphanumeric and -_.~ are the only ones left unencoded
/// name is borrowed from php
string rawurlencode(in char[] data) {
	string ret;
	ret.reserve(data.length * 2);
	foreach(char c; data) {
		if(
			(c >= 'a' && c <= 'z') ||
			(c >= 'A' && c <= 'Z') ||
			(c >= '0' && c <= '9') ||
			c == '-' || c == '_' || c == '.' || c == '~')
		{
			ret ~= c;
		} else {
			ret ~= '%';
			// since we iterate on char, this should give us the octets of the full utf8 string
			ret ~= toHexUpper(c);
		}
	}

	return ret;
}


// http helper functions

// for chunked responses (which embedded http does whenever possible)
version(none) // this is moved up above to avoid making a copy of the data
const(ubyte)[] makeChunk(const(ubyte)[] data) {
	const(ubyte)[] ret;

	ret = cast(const(ubyte)[]) toHex(data.length);
	ret ~= cast(const(ubyte)[]) "\r\n";
	ret ~= data;
	ret ~= cast(const(ubyte)[]) "\r\n";

	return ret;
}

string toHex(long num) {
	string ret;
	while(num) {
		int v = num % 16;
		num /= 16;
		char d = cast(char) ((v < 10) ? v + '0' : (v-10) + 'a');
		ret ~= d;
	}

	return to!string(array(ret.retro));
}

string toHexUpper(long num) {
	string ret;
	while(num) {
		int v = num % 16;
		num /= 16;
		char d = cast(char) ((v < 10) ? v + '0' : (v-10) + 'A');
		ret ~= d;
	}

	if(ret.length == 1)
		ret ~= "0"; // url encoding requires two digits and that's what this function is used for...

	return to!string(array(ret.retro));
}


// the generic mixins

/// Use this instead of writing your own main
mixin template GenericMain(alias fun, long maxContentLength = defaultMaxContentLength) {
	mixin CustomCgiMain!(Cgi, fun, maxContentLength);
}

/++
	Boilerplate mixin for a main function that uses the [dispatcher] function.

	You can send `typeof(null)` as the `Presenter` argument to use a generic one.

	History:
		Added July 9, 2021
+/
mixin template DispatcherMain(Presenter, DispatcherArgs...) {
	/++
		Handler to the generated presenter you can use from your objects, etc.
	+/
	Presenter activePresenter;

	/++
		Request handler that creates the presenter then forwards to the [dispatcher] function.
		Renders 404 if the dispatcher did not handle the request.

		Will automatically serve the presenter.style and presenter.script as "style.css" and "script.js"
	+/
	void handler(Cgi cgi) {
		auto presenter = new Presenter;
		activePresenter = presenter;
		scope(exit) activePresenter = null;

		if(cgi.dispatcher!DispatcherArgs(presenter))
			return;

		switch(cgi.pathInfo) {
			case "/style.css":
				cgi.setCache(true);
				cgi.setResponseContentType("text/css");
				cgi.write(presenter.style(), true);
			break;
			case "/script.js":
				cgi.setCache(true);
				cgi.setResponseContentType("application/javascript");
				cgi.write(presenter.script(), true);
			break;
			default:
				presenter.renderBasicError(cgi, 404);
		}
	}
	mixin GenericMain!handler;
}

mixin template DispatcherMain(DispatcherArgs...) if(!is(DispatcherArgs[0] : WebPresenter!T, T)) {
	class GenericPresenter : WebPresenter!GenericPresenter {}
	mixin DispatcherMain!(GenericPresenter, DispatcherArgs);
}

private string simpleHtmlEncode(string s) {
	return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\n", "<br />\n");
}

string messageFromException(Throwable t) {
	string message;
	if(t !is null) {
		debug message = t.toString();
		else  message = "An unexpected error has occurred.";
	} else {
		message = "Unknown error";
	}
	return message;
}

string plainHttpError(bool isCgi, string type, Throwable t) {
	auto message = messageFromException(t);
	message = simpleHtmlEncode(message);

	return format("%s %s\r\nContent-Length: %s\r\n\r\n%s",
		isCgi ? "Status:" : "HTTP/1.0",
		type, message.length, message);
}

// returns true if we were able to recover reasonably
bool handleException(Cgi cgi, Throwable t) {
	if(cgi.isClosed) {
		// if the channel has been explicitly closed, we can't handle it here
		return true;
	}

	if(cgi.outputtedResponseData) {
		// the headers are sent, but the channel is open... since it closes if all was sent, we can append an error message here.
		return false; // but I don't want to, since I don't know what condition the output is in; I don't want to inject something (nor check the content-type for that matter. So we say it was not a clean handling.
	} else {
		// no headers are sent, we can send a full blown error and recover
		cgi.setCache(false);
		cgi.setResponseContentType("text/html");
		cgi.setResponseLocation(null); // cancel the redirect
		cgi.setResponseStatus("500 Internal Server Error");
		cgi.write(simpleHtmlEncode(messageFromException(t)));
		cgi.close();
		return true;
	}
}

bool isCgiRequestMethod(string s) {
	s = s.toUpper();
	if(s == "COMMANDLINE")
		return true;
	foreach(member; __traits(allMembers, Cgi.RequestMethod))
		if(s == member)
			return true;
	return false;
}

/// If you want to use a subclass of Cgi with generic main, use this mixin.
mixin template CustomCgiMain(CustomCgi, alias fun, long maxContentLength = defaultMaxContentLength) if(is(CustomCgi : Cgi)) {
	// kinda hacky - the T... is passed to Cgi's constructor in standard cgi mode, and ignored elsewhere
	void main(string[] args) {
		cgiMainImpl!(fun, CustomCgi, maxContentLength)(args);
	}
}

version(embedded_httpd_processes)
	__gshared int processPoolSize = 8;

// Returns true if run. You should exit the program after that.
bool tryAddonServers(string[] args) {
	if(args.length > 1) {
		// run the special separate processes if needed
		switch(args[1]) {
			case "--websocket-server":
				version(with_addon_servers)
					websocketServers[args[2]](args[3 .. $]);
				else
					printf("Add-on servers not compiled in.\n");
				return true;
			case "--websocket-servers":
				import core.demangle;
				version(with_addon_servers_connections)
				foreach(k, v; websocketServers)
					writeln(k, "\t", demangle(k));
				return true;
			case "--session-server":
				version(with_addon_servers)
					runSessionServer();
				else
					printf("Add-on servers not compiled in.\n");
				return true;
			case "--event-server":
				version(with_addon_servers)
					runEventServer();
				else
					printf("Add-on servers not compiled in.\n");
				return true;
			case "--timer-server":
				version(with_addon_servers)
					runTimerServer();
				else
					printf("Add-on servers not compiled in.\n");
				return true;
			case "--timed-jobs":
				import core.demangle;
				version(with_addon_servers_connections)
				foreach(k, v; scheduledJobHandlers)
					writeln(k, "\t", demangle(k));
				return true;
			case "--timed-job":
				scheduledJobHandlers[args[2]](args[3 .. $]);
				return true;
			default:
				// intentionally blank - do nothing and carry on to run normally
		}
	}
	return false;
}

/// Tries to simulate a request from the command line. Returns true if it does, false if it didn't find the args.
bool trySimulatedRequest(alias fun, CustomCgi = Cgi)(string[] args) if(is(CustomCgi : Cgi)) {
	// we support command line thing for easy testing everywhere
	// it needs to be called ./app method uri [other args...]
	if(args.length >= 3 && isCgiRequestMethod(args[1])) {
		Cgi cgi = new CustomCgi(args);
		scope(exit) cgi.dispose();
		fun(cgi);
		cgi.close();
		return true;
	}
	return false;
}

/++
	A server control and configuration struct, as a potential alternative to calling [GenericMain] or [cgiMainImpl]. See the source of [cgiMainImpl] to an example of how you can use it.

	History:
		Added Sept 26, 2020 (release version 8.5).
+/
struct RequestServer {
	///
	string listeningHost = defaultListeningHost();
	///
	ushort listeningPort = defaultListeningPort();

	/++
		Uses a fork() call, if available, to provide additional crash resiliency and possibly improved performance. On the
		other hand, if you fork, you must not assume any memory is shared between requests (you shouldn't be anyway though! But
		if you have to, you probably want to set this to false and use an explicit threaded server with [serveEmbeddedHttp]) and
		[stop] may not work as well.

		History:
			Added August 12, 2022  (dub v10.9). Previously, this was only configurable through the `-version=cgi_no_fork`
			argument to dmd. That version still defines the value of `cgi_use_fork_default`, used to initialize this, for
			compatibility.
	+/
	bool useFork = cgi_use_fork_default;

	/++
		Determines the number of worker threads to spawn per process, for server modes that use worker threads. 0 will use a
		default based on the number of cpus modified by the server mode.

		History:
			Added August 12, 2022 (dub v10.9)
	+/
	int numberOfThreads = 0;

	///
	this(string defaultHost, ushort defaultPort) {
		this.listeningHost = defaultHost;
		this.listeningPort = defaultPort;
	}

	///
	this(ushort defaultPort) {
		listeningPort = defaultPort;
	}

	/++
		Reads the command line arguments into the values here.

		Possible arguments are `--listening-host`, `--listening-port` (or `--port`), `--uid`, and `--gid`.
	+/
	void configureFromCommandLine(string[] args) {
		bool foundPort = false;
		bool foundHost = false;
		bool foundUid = false;
		bool foundGid = false;
		foreach(arg; args) {
			if(foundPort) {
				listeningPort = to!ushort(arg);
				foundPort = false;
			}
			if(foundHost) {
				listeningHost = arg;
				foundHost = false;
			}
			if(foundUid) {
				privilegesDropToUid = to!uid_t(arg);
				foundUid = false;
			}
			if(foundGid) {
				privilegesDropToGid = to!gid_t(arg);
				foundGid = false;
			}
			if(arg == "--listening-host" || arg == "-h" || arg == "/listening-host")
				foundHost = true;
			else if(arg == "--port" || arg == "-p" || arg == "/port" || arg == "--listening-port")
				foundPort = true;
			else if(arg == "--uid")
				foundUid = true;
			else if(arg == "--gid")
				foundGid = true;
		}
	}

	version(Windows) {
		private alias uid_t = int;
		private alias gid_t = int;
	}

	/// user (uid) to drop privileges to
	/// 0 … do nothing
	uid_t privilegesDropToUid = 0;
	/// group (gid) to drop privileges to
	/// 0 … do nothing
	gid_t privilegesDropToGid = 0;

	private void dropPrivileges() {
		version(Posix) {
			import core.sys.posix.unistd;

			if (privilegesDropToGid != 0 && setgid(privilegesDropToGid) != 0)
				throw new Exception("Dropping privileges via setgid() failed.");

			if (privilegesDropToUid != 0 && setuid(privilegesDropToUid) != 0)
				throw new Exception("Dropping privileges via setuid() failed.");
		}
		else {
			// FIXME: Windows?
			//pragma(msg, "Dropping privileges is not implemented for this platform");
		}

		// done, set zero
		privilegesDropToGid = 0;
		privilegesDropToUid = 0;
	}

	/++
		Serves a single HTTP request on this thread, with an embedded server, then stops. Designed for cases like embedded oauth responders

		History:
			Added Oct 10, 2020.
		Example:

		---
		import arsd.cgi;
		void main() {
			RequestServer server = RequestServer("127.0.0.1", 6789);
			string oauthCode;
			string oauthScope;
			server.serveHttpOnce!((cgi) {
				oauthCode = cgi.request("code");
				oauthScope = cgi.request("scope");
				cgi.write("Thank you, please return to the application.");
			});
			// use the code and scope given
		}
		---
	+/
	void serveHttpOnce(alias fun, CustomCgi = Cgi, long maxContentLength = defaultMaxContentLength)() {
		import std.socket;

		bool tcp;
		void delegate() cleanup;
		auto socket = startListening(listeningHost, listeningPort, tcp, cleanup, 1, &dropPrivileges);
		auto connection = socket.accept();
		doThreadHttpConnectionGuts!(CustomCgi, fun, true)(connection);

		if(cleanup)
			cleanup();
	}

	/++
		Starts serving requests according to the current configuration.
	+/
	void serve(alias fun, CustomCgi = Cgi, long maxContentLength = defaultMaxContentLength)() {
		version(netman_httpd) {
			// Obsolete!

			import arsd.httpd;
			// what about forwarding the other constructor args?
			// this probably needs a whole redoing...
			serveHttp!CustomCgi(&fun, listeningPort);//5005);
			return;
		} else
		version(embedded_httpd_processes) {
			serveEmbeddedHttpdProcesses!(fun, CustomCgi)(this);
		} else
		version(embedded_httpd_threads) {
			serveEmbeddedHttp!(fun, CustomCgi, maxContentLength)();
		} else
		version(scgi) {
			serveScgi!(fun, CustomCgi, maxContentLength)();
		} else
		version(fastcgi) {
			serveFastCgi!(fun, CustomCgi, maxContentLength)(this);
		} else
		version(stdio_http) {
			serveSingleHttpConnectionOnStdio!(fun, CustomCgi, maxContentLength)();
		} else {
			//version=plain_cgi;
			handleCgiRequest!(fun, CustomCgi, maxContentLength)();
		}
	}

	/++
		Runs the embedded HTTP thread server specifically, regardless of which build configuration you have.

		If you want the forking worker process server, you do need to compile with the embedded_httpd_processes config though.
	+/
	void serveEmbeddedHttp(alias fun, CustomCgi = Cgi, long maxContentLength = defaultMaxContentLength)(ThisFor!fun _this) {
		globalStopFlag = false;
		static if(__traits(isStaticFunction, fun))
			alias funToUse = fun;
		else
			void funToUse(CustomCgi cgi) {
				static if(__VERSION__ > 2097)
					__traits(child, _this, fun)(cgi);
				else static assert(0, "Not implemented in your compiler version!");
			}
		auto manager = new ListeningConnectionManager(listeningHost, listeningPort, &doThreadHttpConnection!(CustomCgi, funToUse), null, useFork, numberOfThreads);
		manager.listen();
	}

	/++
		Runs the embedded SCGI server specifically, regardless of which build configuration you have.
	+/
	void serveScgi(alias fun, CustomCgi = Cgi, long maxContentLength = defaultMaxContentLength)() {
		globalStopFlag = false;
		auto manager = new ListeningConnectionManager(listeningHost, listeningPort, &doThreadScgiConnection!(CustomCgi, fun, maxContentLength), null, useFork, numberOfThreads);
		manager.listen();
	}

	/++
		Serves a single "connection", but the connection is spoken on stdin and stdout instead of on a socket.

		Intended for cases like working from systemd, like discussed here: https://forum.dlang.org/post/avmkfdiitirnrenzljwc@forum.dlang.org

		History:
			Added May 29, 2021
	+/
	void serveSingleHttpConnectionOnStdio(alias fun, CustomCgi = Cgi, long maxContentLength = defaultMaxContentLength)() {
		doThreadHttpConnectionGuts!(CustomCgi, fun, true)(new FakeSocketForStdin());
	}

	/++
		The [stop] function sets a flag that request handlers can (and should) check periodically. If a handler doesn't
		respond to this flag, the library will force the issue. This determines when and how the issue will be forced.
	+/
	enum ForceStop {
		/++
			Stops accepting new requests, but lets ones already in the queue start and complete before exiting.
		+/
		afterQueuedRequestsComplete,
		/++
			Finishes requests already started their handlers, but drops any others in the queue. Streaming handlers
			should cooperate and exit gracefully, but if they don't, it will continue waiting for them.
		+/
		afterCurrentRequestsComplete,
		/++
			Partial response writes will throw an exception, cancelling any streaming response, but complete
			writes will continue to process. Request handlers that respect the stop token will also gracefully cancel.
		+/
		cancelStreamingRequestsEarly,
		/++
			All writes will throw.
		+/
		cancelAllRequestsEarly,
		/++
			Use OS facilities to forcibly kill running threads. The server process will be in an undefined state after this call (if this call ever returns).
		+/
		forciblyTerminate,
	}

	version(embedded_httpd_processes) {} else
	/++
		Stops serving after the current requests are completed.

		Bugs:
			Not implemented on version=embedded_httpd_processes, version=fastcgi on any system, or embedded_httpd on Windows (it does work on embedded_httpd_hybrid
			on Windows however). Only partially implemented on non-Linux posix systems.

			You might also try SIGINT perhaps.

			The stopPriority is not yet fully implemented.
	+/
	static void stop(ForceStop stopPriority = ForceStop.afterCurrentRequestsComplete) {
		globalStopFlag = true;

		version(Posix)
		if(cancelfd > 0) {
			ulong a = 1;
			core.sys.posix.unistd.write(cancelfd, &a, a.sizeof);
		}
		version(Windows)
		if(iocp) {
			foreach(i; 0 .. 16) // FIXME
			PostQueuedCompletionStatus(iocp, 0, cast(ULONG_PTR) null, null);
		}
	}
}

private alias AliasSeq(T...) = T;

version(with_breaking_cgi_features)
mixin(q{
	template ThisFor(alias t) {
		static if(__traits(isStaticFunction, t)) {
			alias ThisFor = AliasSeq!();
		} else {
			alias ThisFor = __traits(parent, t);
		}
	}
});
else
	alias ThisFor(alias t) = AliasSeq!();

private __gshared bool globalStopFlag = false;

version(embedded_httpd_processes)
void serveEmbeddedHttpdProcesses(alias fun, CustomCgi = Cgi)(RequestServer params) {
	import core.sys.posix.unistd;
	import core.sys.posix.sys.socket;
	import core.sys.posix.netinet.in_;
	//import std.c.linux.socket;

	int sock = socket(AF_INET, SOCK_STREAM, 0);
	if(sock == -1)
		throw new Exception("socket");

	cloexec(sock);

	{

		sockaddr_in addr;
		addr.sin_family = AF_INET;
		addr.sin_port = htons(params.listeningPort);
		auto lh = params.listeningHost;
		if(lh.length) {
			if(inet_pton(AF_INET, lh.toStringz(), &addr.sin_addr.s_addr) != 1)
				throw new Exception("bad listening host given, please use an IP address.\nExample: --listening-host 127.0.0.1 means listen only on Localhost.\nExample: --listening-host 0.0.0.0 means listen on all interfaces.\nOr you can pass any other single numeric IPv4 address.");
		} else
			addr.sin_addr.s_addr = INADDR_ANY;

		// HACKISH
		int on = 1;
		setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &on, on.sizeof);
		// end hack


		if(bind(sock, cast(sockaddr*) &addr, addr.sizeof) == -1) {
			close(sock);
			throw new Exception("bind");
		}

		// FIXME: if this queue is full, it will just ignore it
		// and wait for the client to retransmit it. This is an
		// obnoxious timeout condition there.
		if(sock.listen(128) == -1) {
			close(sock);
			throw new Exception("listen");
		}
		params.dropPrivileges();
	}

	version(embedded_httpd_processes_accept_after_fork) {} else {
		int pipeReadFd;
		int pipeWriteFd;

		{
			int[2] pipeFd;
			if(socketpair(AF_UNIX, SOCK_DGRAM, 0, pipeFd)) {
				import core.stdc.errno;
				throw new Exception("pipe failed " ~ to!string(errno));
			}

			pipeReadFd = pipeFd[0];
			pipeWriteFd = pipeFd[1];
		}
	}


	int processCount;
	pid_t newPid;
	reopen:
	while(processCount < processPoolSize) {
		newPid = fork();
		if(newPid == 0) {
			// start serving on the socket
			//ubyte[4096] backingBuffer;
			for(;;) {
				bool closeConnection;
				uint i;
				sockaddr addr;
				i = addr.sizeof;
				version(embedded_httpd_processes_accept_after_fork) {
					int s = accept(sock, &addr, &i);
					int opt = 1;
					import core.sys.posix.netinet.tcp;
					// the Cgi class does internal buffering, so disabling this
					// helps with latency in many cases...
					setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &opt, opt.sizeof);
					cloexec(s);
				} else {
					int s;
					auto readret = read_fd(pipeReadFd, &s, s.sizeof, &s);
					if(readret != s.sizeof) {
						import core.stdc.errno;
						throw new Exception("pipe read failed " ~ to!string(errno));
					}

					//writeln("process ", getpid(), " got socket ", s);
				}

				try {

					if(s == -1)
						throw new Exception("accept");

					scope(failure) close(s);
					//ubyte[__traits(classInstanceSize, BufferedInputRange)] bufferedRangeContainer;
					auto ir = new BufferedInputRange(s);
					//auto ir = emplace!BufferedInputRange(bufferedRangeContainer, s, backingBuffer);

					while(!ir.empty) {
						//ubyte[__traits(classInstanceSize, CustomCgi)] cgiContainer;

						Cgi cgi;
						try {
							cgi = new CustomCgi(ir, &closeConnection);
							cgi._outputFileHandle = cast(CgiConnectionHandle) s;
							// if we have a single process and the browser tries to leave the connection open while concurrently requesting another, it will block everything an deadlock since there's no other server to accept it. By closing after each request in this situation, it tells the browser to serialize for us.
							if(processPoolSize <= 1)
								closeConnection = true;
							//cgi = emplace!CustomCgi(cgiContainer, ir, &closeConnection);
						} catch(Throwable t) {
							// a construction error is either bad code or bad request; bad request is what it should be since this is bug free :P
							// anyway let's kill the connection
							version(CRuntime_Musl) {
								// LockingTextWriter fails here
								// so working around it
								auto estr = t.toString();
								stderr.rawWrite(estr);
								stderr.rawWrite("\n");
							} else
								stderr.writeln(t.toString());
							sendAll(ir.source, plainHttpError(false, "400 Bad Request", t));
							closeConnection = true;
							break;
						}
						assert(cgi !is null);
						scope(exit)
							cgi.dispose();

						try {
							fun(cgi);
							cgi.close();
							if(cgi.websocketMode)
								closeConnection = true;
						} catch(ConnectionException ce) {
							closeConnection = true;
						} catch(Throwable t) {
							// a processing error can be recovered from
							version(CRuntime_Musl) {
								// LockingTextWriter fails here
								// so working around it
								auto estr = t.toString();
								stderr.rawWrite(estr);
							} else {
								stderr.writeln(t.toString);
							}
							if(!handleException(cgi, t))
								closeConnection = true;
						}

						if(closeConnection) {
							ir.source.close();
							break;
						} else {
							if(!ir.empty)
								ir.popFront(); // get the next
							else if(ir.sourceClosed) {
								ir.source.close();
							}
						}
					}

					ir.source.close();
				} catch(Throwable t) {
					version(CRuntime_Musl) {} else
						debug writeln(t);
					// most likely cause is a timeout
				}
			}
		} else if(newPid < 0) {
			throw new Exception("fork failed");
		} else {
			processCount++;
		}
	}

	// the parent should wait for its children...
	if(newPid) {
		import core.sys.posix.sys.wait;

		version(embedded_httpd_processes_accept_after_fork) {} else {
			import core.sys.posix.sys.select;
			int[] fdQueue;
			while(true) {
				// writeln("select call");
				int nfds = pipeWriteFd;
				if(sock > pipeWriteFd)
					nfds = sock;
				nfds += 1;
				fd_set read_fds;
				fd_set write_fds;
				FD_ZERO(&read_fds);
				FD_ZERO(&write_fds);
				FD_SET(sock, &read_fds);
				if(fdQueue.length)
					FD_SET(pipeWriteFd, &write_fds);
				auto ret = select(nfds, &read_fds, &write_fds, null, null);
				if(ret == -1) {
					import core.stdc.errno;
					if(errno == EINTR)
						goto try_wait;
					else
						throw new Exception("wtf select");
				}

				int s = -1;
				if(FD_ISSET(sock, &read_fds)) {
					uint i;
					sockaddr addr;
					i = addr.sizeof;
					s = accept(sock, &addr, &i);
					cloexec(s);
					import core.sys.posix.netinet.tcp;
					int opt = 1;
					setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &opt, opt.sizeof);
				}

				if(FD_ISSET(pipeWriteFd, &write_fds)) {
					if(s == -1 && fdQueue.length) {
						s = fdQueue[0];
						fdQueue = fdQueue[1 .. $]; // FIXME reuse buffer
					}
					write_fd(pipeWriteFd, &s, s.sizeof, s);
					close(s); // we are done with it, let the other process take ownership
				} else
					fdQueue ~= s;
			}
		}

		try_wait:

		int status;
		while(-1 != wait(&status)) {
			version(CRuntime_Musl) {} else {
				import std.stdio; writeln("Process died ", status);
			}
			processCount--;
			goto reopen;
		}
		close(sock);
	}
}

version(fastcgi)
void serveFastCgi(alias fun, CustomCgi = Cgi, long maxContentLength = defaultMaxContentLength)(RequestServer params) {
	//         SetHandler fcgid-script
	FCGX_Stream* input, output, error;
	FCGX_ParamArray env;



	const(ubyte)[] getFcgiChunk() {
		const(ubyte)[] ret;
		while(FCGX_HasSeenEOF(input) != -1)
			ret ~= cast(ubyte) FCGX_GetChar(input);
		return ret;
	}

	void writeFcgi(const(ubyte)[] data) {
		FCGX_PutStr(data.ptr, data.length, output);
	}

	void doARequest() {
		string[string] fcgienv;

		for(auto e = env; e !is null && *e !is null; e++) {
			string cur = to!string(*e);
			auto idx = cur.indexOf("=");
			string name, value;
			if(idx == -1)
				name = cur;
			else {
				name = cur[0 .. idx];
				value = cur[idx + 1 .. $];
			}

			fcgienv[name] = value;
		}

		void flushFcgi() {
			FCGX_FFlush(output);
		}

		Cgi cgi;
		try {
			cgi = new CustomCgi(maxContentLength, fcgienv, &getFcgiChunk, &writeFcgi, &flushFcgi);
		} catch(Throwable t) {
			FCGX_PutStr(cast(ubyte*) t.msg.ptr, t.msg.length, error);
			writeFcgi(cast(const(ubyte)[]) plainHttpError(true, "400 Bad Request", t));
			return; //continue;
		}
		assert(cgi !is null);
		scope(exit) cgi.dispose();
		try {
			fun(cgi);
			cgi.close();
		} catch(Throwable t) {
			// log it to the error stream
			FCGX_PutStr(cast(ubyte*) t.msg.ptr, t.msg.length, error);
			// handle it for the user, if we can
			if(!handleException(cgi, t))
				return; // continue;
		}
	}

	auto lp = params.listeningPort;
	auto host = params.listeningHost;

	FCGX_Request request;
	if(lp || !host.empty) {
		// if a listening port was specified on the command line, we want to spawn ourself
		// (needed for nginx without spawn-fcgi, e.g. on Windows)
		FCGX_Init();

		int sock;

		if(host.startsWith("unix:")) {
			sock = FCGX_OpenSocket(toStringz(params.listeningHost["unix:".length .. $]), 12);
		} else if(host.startsWith("abstract:")) {
			sock = FCGX_OpenSocket(toStringz("\0" ~ params.listeningHost["abstract:".length .. $]), 12);
		} else {
			sock = FCGX_OpenSocket(toStringz(params.listeningHost ~ ":" ~ to!string(lp)), 12);
		}

		if(sock < 0)
			throw new Exception("Couldn't listen on the port");
		FCGX_InitRequest(&request, sock, 0);
		while(FCGX_Accept_r(&request) >= 0) {
			input = request.inStream;
			output = request.outStream;
			error = request.errStream;
			env = request.envp;
			doARequest();
		}
	} else {
		// otherwise, assume the httpd is doing it (the case for Apache, IIS, and Lighttpd)
		// using the version with a global variable since we are separate processes anyway
		while(FCGX_Accept(&input, &output, &error, &env) >= 0) {
			doARequest();
		}
	}
}

/// Returns the default listening port for the current cgi configuration. 8085 for embedded httpd, 4000 for scgi, irrelevant for others.
ushort defaultListeningPort() {
	version(netman_httpd)
		return 8080;
	else version(embedded_httpd_processes)
		return 8085;
	else version(embedded_httpd_threads)
		return 8085;
	else version(scgi)
		return 4000;
	else
		return 0;
}

/// Default host for listening. 127.0.0.1 for scgi, null (aka all interfaces) for all others. If you want the server directly accessible from other computers on the network, normally use null. If not, 127.0.0.1 is a bit better. Settable with default handlers with --listening-host command line argument.
string defaultListeningHost() {
	version(netman_httpd)
		return null;
	else version(embedded_httpd_processes)
		return null;
	else version(embedded_httpd_threads)
		return null;
	else version(scgi)
		return "127.0.0.1";
	else
		return null;

}

/++
	This is the function [GenericMain] calls. View its source for some simple boilerplate you can copy/paste and modify, or you can call it yourself from your `main`.

	Params:
		fun = Your request handler
		CustomCgi = a subclass of Cgi, if you wise to customize it further
		maxContentLength = max POST size you want to allow
		args = command-line arguments

	History:
	Documented Sept 26, 2020.
+/
void cgiMainImpl(alias fun, CustomCgi = Cgi, long maxContentLength = defaultMaxContentLength)(string[] args) if(is(CustomCgi : Cgi)) {
	if(tryAddonServers(args))
		return;

	if(trySimulatedRequest!(fun, CustomCgi)(args))
		return;

	RequestServer server;
	// you can change the port here if you like
	// server.listeningPort = 9000;

	// then call this to let the command line args override your default
	server.configureFromCommandLine(args);

	// and serve the request(s).
	server.serve!(fun, CustomCgi, maxContentLength)();
}

//version(plain_cgi)
void handleCgiRequest(alias fun, CustomCgi = Cgi, long maxContentLength = defaultMaxContentLength)() {
	// standard CGI is the default version


	// Set stdin to binary mode if necessary to avoid mangled newlines
	// the fact that stdin is global means this could be trouble but standard cgi request
	// handling is one per process anyway so it shouldn't actually be threaded here or anything.
	version(Windows) {
		version(Win64)
		_setmode(std.stdio.stdin.fileno(), 0x8000);
		else
		setmode(std.stdio.stdin.fileno(), 0x8000);
	}

	Cgi cgi;
	try {
		cgi = new CustomCgi(maxContentLength);
		version(Posix)
			cgi._outputFileHandle = cast(CgiConnectionHandle) 1; // stdout
		else version(Windows)
			cgi._outputFileHandle = cast(CgiConnectionHandle) GetStdHandle(STD_OUTPUT_HANDLE);
		else static assert(0);
	} catch(Throwable t) {
		version(CRuntime_Musl) {
			// LockingTextWriter fails here
			// so working around it
			auto s = t.toString();
			stderr.rawWrite(s);
			stdout.rawWrite(plainHttpError(true, "400 Bad Request", t));
		} else {
			stderr.writeln(t.msg);
			// the real http server will probably handle this;
			// most likely, this is a bug in Cgi. But, oh well.
			stdout.write(plainHttpError(true, "400 Bad Request", t));
		}
		return;
	}
	assert(cgi !is null);
	scope(exit) cgi.dispose();

	try {
		fun(cgi);
		cgi.close();
	} catch (Throwable t) {
		version(CRuntime_Musl) {
			// LockingTextWriter fails here
			// so working around it
			auto s = t.msg;
			stderr.rawWrite(s);
		} else {
			stderr.writeln(t.msg);
		}
		if(!handleException(cgi, t))
			return;
	}
}

private __gshared int cancelfd = -1;

/+
	The event loop for embedded_httpd_threads will prolly fiber dispatch
	cgi constructors too, so slow posts will not monopolize a worker thread.

	May want to provide the worker task system just need to ensure all the fibers
	has a big enough stack for real work... would also ideally like to reuse them.


	So prolly bir would switch it to nonblocking. If it would block, it epoll
	registers one shot with this existing fiber to take it over.

		new connection comes in. it picks a fiber off the free list,
		or if there is none, it creates a new one. this fiber handles
		this connection the whole time.

		epoll triggers the fiber when something comes in. it is called by
		a random worker thread, it might change at any time. at least during
		the constructor. maybe into the main body it will stay tied to a thread
		just so TLS stuff doesn't randomly change in the middle. but I could
		specify if you yield all bets are off.

		when the request is finished, if there's more data buffered, it just
		keeps going. if there is no more data buffered, it epoll ctls to
		get triggered when more data comes in. all one shot.

		when a connection is closed, the fiber returns and is then reset
		and added to the free list. if the free list is full, the fiber is
		just freed, this means it will balloon to a certain size but not generally
		grow beyond that unless the activity keeps going.

		256 KB stack i thnk per fiber. 4,000 active fibers per gigabyte of memory.

	So the fiber has its own magic methods to read and write. if they would block, it registers
	for epoll and yields. when it returns, it read/writes and then returns back normal control.

	basically you issue the command and it tells you when it is done

	it needs to DEL the epoll thing when it is closed. add it when opened. mod it when anther thing issued

+/

/++
	The stack size when a fiber is created. You can set this from your main or from a shared static constructor
	to optimize your memory use if you know you don't need this much space. Be careful though, some functions use
	more stack space than you realize and a recursive function (including ones like in dom.d) can easily grow fast!

	History:
		Added July 10, 2021. Previously, it used the druntime default of 16 KB.
+/
version(cgi_use_fiber)
__gshared size_t fiberStackSize = 4096 * 100;

version(cgi_use_fiber)
class CgiFiber : Fiber {
	private void function(Socket) f_handler;
	private void f_handler_dg(Socket s) { // to avoid extra allocation w/ function
		f_handler(s);
	}
	this(void function(Socket) handler) {
		this.f_handler = handler;
		this(&f_handler_dg);
	}

	this(void delegate(Socket) handler) {
		this.handler = handler;
		super(&run, fiberStackSize);
	}

	Socket connection;
	void delegate(Socket) handler;

	void run() {
		handler(connection);
	}

	void delegate() postYield;

	private void setPostYield(scope void delegate() py) @nogc {
		postYield = cast(void delegate()) py;
	}

	void proceed() {
		try {
			call();
			auto py = postYield;
			postYield = null;
			if(py !is null)
				py();
		} catch(Exception e) {
			if(connection)
				connection.close();
			goto terminate;
		}

		if(state == State.TERM) {
			terminate:
			import core.memory;
			GC.removeRoot(cast(void*) this);
		}
	}
}

version(cgi_use_fiber)
version(Windows) {

extern(Windows) private {

	import core.sys.windows.mswsock;

	alias GROUP=uint;
	alias LPWSAPROTOCOL_INFOW = void*;
	SOCKET WSASocketW(int af, int type, int protocol, LPWSAPROTOCOL_INFOW lpProtocolInfo, GROUP g, DWORD dwFlags);
	int WSASend(SOCKET s, LPWSABUF lpBuffers, DWORD dwBufferCount, LPDWORD lpNumberOfBytesSent, DWORD dwFlags, LPWSAOVERLAPPED lpOverlapped, LPWSAOVERLAPPED_COMPLETION_ROUTINE lpCompletionRoutine);
	int WSARecv(SOCKET s, LPWSABUF lpBuffers, DWORD dwBufferCount, LPDWORD lpNumberOfBytesRecvd, LPDWORD lpFlags, LPWSAOVERLAPPED lpOverlapped, LPWSAOVERLAPPED_COMPLETION_ROUTINE lpCompletionRoutine);

	struct WSABUF {
		ULONG len;
		CHAR  *buf;
	}
	alias LPWSABUF = WSABUF*;

	alias WSAOVERLAPPED = OVERLAPPED;
	alias LPWSAOVERLAPPED = LPOVERLAPPED;
	/+

	alias LPFN_ACCEPTEX =
		BOOL
		function(
				SOCKET sListenSocket,
				SOCKET sAcceptSocket,
				//_Out_writes_bytes_(dwReceiveDataLength+dwLocalAddressLength+dwRemoteAddressLength) PVOID lpOutputBuffer,
				void* lpOutputBuffer,
				WORD dwReceiveDataLength,
				WORD dwLocalAddressLength,
				WORD dwRemoteAddressLength,
				LPDWORD lpdwBytesReceived,
				LPOVERLAPPED lpOverlapped
			);

	enum WSAID_ACCEPTEX = GUID([0xb5367df1,0xcbac,0x11cf,[0x95,0xca,0x00,0x80,0x5f,0x48,0xa1,0x92]]);
	+/

	enum WSAID_GETACCEPTEXSOCKADDRS = GUID(0xb5367df2,0xcbac,0x11cf,[0x95,0xca,0x00,0x80,0x5f,0x48,0xa1,0x92]);
}

private class PseudoblockingOverlappedSocket : Socket {
	SOCKET handle;

	CgiFiber fiber;

	this(AddressFamily af, SocketType st) {
		auto handle = WSASocketW(af, st, 0, null, 0, 1 /*WSA_FLAG_OVERLAPPED*/);
		if(!handle)
			throw new Exception("WSASocketW");
		this.handle = handle;

		iocp = CreateIoCompletionPort(cast(HANDLE) handle, iocp, cast(ULONG_PTR) cast(void*) this, 0);

		if(iocp is null) {
			writeln(GetLastError());
			throw new Exception("CreateIoCompletionPort");
		}

		super(cast(socket_t) handle, af);
	}
	this() pure nothrow @trusted { assert(0); }

	override void blocking(bool) {} // meaningless to us, just ignore it.

	protected override Socket accepting() pure nothrow {
		assert(0);
	}

	bool addressesParsed;
	Address la;
	Address ra;

	private void populateAddresses() {
		if(addressesParsed)
			return;
		addressesParsed = true;

		int lalen, ralen;

		sockaddr_in* la;
		sockaddr_in* ra;

		lpfnGetAcceptExSockaddrs(
			scratchBuffer.ptr,
			0, // same as in the AcceptEx call!
			sockaddr_in.sizeof + 16,
			sockaddr_in.sizeof + 16,
			cast(sockaddr**) &la,
			&lalen,
			cast(sockaddr**) &ra,
			&ralen
		);

		if(la)
			this.la = new InternetAddress(*la);
		if(ra)
			this.ra = new InternetAddress(*ra);

	}

	override @property @trusted Address localAddress() {
		populateAddresses();
		return la;
	}
	override @property @trusted Address remoteAddress() {
		populateAddresses();
		return ra;
	}

	PseudoblockingOverlappedSocket accepted;

	__gshared static LPFN_ACCEPTEX lpfnAcceptEx;
	__gshared static typeof(&GetAcceptExSockaddrs) lpfnGetAcceptExSockaddrs;

	override Socket accept() @trusted {
		__gshared static LPFN_ACCEPTEX lpfnAcceptEx;

		if(lpfnAcceptEx is null) {
			DWORD dwBytes;
			GUID GuidAcceptEx = WSAID_ACCEPTEX;

			auto iResult = WSAIoctl(handle, 0xc8000006 /*SIO_GET_EXTENSION_FUNCTION_POINTER*/,
					&GuidAcceptEx, GuidAcceptEx.sizeof,
					&lpfnAcceptEx, lpfnAcceptEx.sizeof,
					&dwBytes, null, null);

			GuidAcceptEx = WSAID_GETACCEPTEXSOCKADDRS;
			iResult = WSAIoctl(handle, 0xc8000006 /*SIO_GET_EXTENSION_FUNCTION_POINTER*/,
					&GuidAcceptEx, GuidAcceptEx.sizeof,
					&lpfnGetAcceptExSockaddrs, lpfnGetAcceptExSockaddrs.sizeof,
					&dwBytes, null, null);

		}

		auto pfa = new PseudoblockingOverlappedSocket(AddressFamily.INET, SocketType.STREAM);
		accepted = pfa;

		SOCKET pendingForAccept = pfa.handle;
		DWORD ignored;

		auto ret = lpfnAcceptEx(handle,
			pendingForAccept,
			// buffer to receive up front
			pfa.scratchBuffer.ptr,
			0,
			// size of local and remote addresses. normally + 16.
			sockaddr_in.sizeof + 16,
			sockaddr_in.sizeof + 16,
			&ignored, // bytes would be given through the iocp instead but im not even requesting the thing
			&overlapped
		);

		return pfa;
	}

	override void connect(Address to) { assert(0); }

	DWORD lastAnswer;
	ubyte[1024] scratchBuffer;
	static assert(scratchBuffer.length > sockaddr_in.sizeof * 2 + 32);

	WSABUF[1] buffer;
	OVERLAPPED overlapped;
	override ptrdiff_t send(scope const(void)[] buf, SocketFlags flags) @trusted {
		overlapped = overlapped.init;
		buffer[0].len = cast(DWORD) buf.length;
		buffer[0].buf = cast(CHAR*) buf.ptr;
		fiber.setPostYield( () {
			if(!WSASend(handle, buffer.ptr, cast(DWORD) buffer.length, null, 0, &overlapped, null)) {
				if(GetLastError() != 997) {
					//throw new Exception("WSASend fail");
				}
			}
		});

		Fiber.yield();
		return lastAnswer;
	}
	override ptrdiff_t receive(scope void[] buf, SocketFlags flags) @trusted {
		overlapped = overlapped.init;
		buffer[0].len = cast(DWORD) buf.length;
		buffer[0].buf = cast(CHAR*) buf.ptr;

		DWORD flags2 = 0;

		fiber.setPostYield(() {
			if(!WSARecv(handle, buffer.ptr, cast(DWORD) buffer.length, null, &flags2 /* flags */, &overlapped, null)) {
				if(GetLastError() != 997) {
					//writeln("WSARecv ", WSAGetLastError());
					//throw new Exception("WSARecv fail");
				}
			}
		});

		Fiber.yield();
		return lastAnswer;
	}

	// I might go back and implement these for udp things.
	override ptrdiff_t receiveFrom(scope void[] buf, SocketFlags flags, ref Address from) @trusted {
		assert(0);
	}
	override ptrdiff_t receiveFrom(scope void[] buf, SocketFlags flags) @trusted {
		assert(0);
	}
	override ptrdiff_t sendTo(scope const(void)[] buf, SocketFlags flags, Address to) @trusted {
		assert(0);
	}
	override ptrdiff_t sendTo(scope const(void)[] buf, SocketFlags flags) @trusted {
		assert(0);
	}

	// lol overload sets
	alias send = typeof(super).send;
	alias receive = typeof(super).receive;
	alias sendTo = typeof(super).sendTo;
	alias receiveFrom = typeof(super).receiveFrom;

}
}

void doThreadHttpConnection(CustomCgi, alias fun)(Socket connection) {
	assert(connection !is null);
	version(cgi_use_fiber) {
		auto fiber = new CgiFiber(&doThreadHttpConnectionGuts!(CustomCgi, fun));

		version(Windows) {
			(cast(PseudoblockingOverlappedSocket) connection).fiber = fiber;
		}

		import core.memory;
		GC.addRoot(cast(void*) fiber);
		fiber.connection = connection;
		fiber.proceed();
	} else {
		doThreadHttpConnectionGuts!(CustomCgi, fun)(connection);
	}
}

void doThreadHttpConnectionGuts(CustomCgi, alias fun, bool alwaysCloseConnection = false)(Socket connection) {
	scope(failure) {
		// catch all for other errors
		try {
			sendAll(connection, plainHttpError(false, "500 Internal Server Error", null));
			connection.close();
		} catch(Exception e) {} // swallow it, we're aborting anyway.
	}

	bool closeConnection = alwaysCloseConnection;

	/+
	ubyte[4096] inputBuffer = void;
	ubyte[__traits(classInstanceSize, BufferedInputRange)] birBuffer = void;
	ubyte[__traits(classInstanceSize, CustomCgi)] cgiBuffer = void;

	birBuffer[] = cast(ubyte[]) typeid(BufferedInputRange).initializer()[];
	BufferedInputRange ir = cast(BufferedInputRange) cast(void*) birBuffer.ptr;
	ir.__ctor(connection, inputBuffer[], true);
	+/

	auto ir = new BufferedInputRange(connection);

	while(!ir.empty) {

		if(ir.view.length == 0) {
			ir.popFront();
			if(ir.sourceClosed) {
				connection.close();
				closeConnection = true;
				break;
			}
		}

		Cgi cgi;
		try {
			cgi = new CustomCgi(ir, &closeConnection);
			// There's a bunch of these casts around because the type matches up with
			// the -version=.... specifiers, just you can also create a RequestServer
			// and instantiate the things where the types don't match up. It isn't exactly
			// correct but I also don't care rn. Might FIXME and either remove it later or something.
			cgi._outputFileHandle = cast(CgiConnectionHandle) connection.handle;
		} catch(ConnectionClosedException ce) {
			closeConnection = true;
			break;
		} catch(ConnectionException ce) {
			// broken pipe or something, just abort the connection
			closeConnection = true;
			break;
		} catch(Throwable t) {
			// a construction error is either bad code or bad request; bad request is what it should be since this is bug free :P
			// anyway let's kill the connection
			version(CRuntime_Musl) {
				stderr.rawWrite(t.toString());
				stderr.rawWrite("\n");
			} else {
				stderr.writeln(t.toString());
			}
			sendAll(connection, plainHttpError(false, "400 Bad Request", t));
			closeConnection = true;
			break;
		}
		assert(cgi !is null);
		scope(exit)
			cgi.dispose();

		try {
			fun(cgi);
			cgi.close();
			if(cgi.websocketMode)
				closeConnection = true;
		} catch(ConnectionException ce) {
			// broken pipe or something, just abort the connection
			closeConnection = true;
		} catch(ConnectionClosedException ce) {
			// broken pipe or something, just abort the connection
			closeConnection = true;
		} catch(Throwable t) {
			// a processing error can be recovered from
			version(CRuntime_Musl) {} else
			stderr.writeln(t.toString);
			if(!handleException(cgi, t))
				closeConnection = true;
		}

		if(globalStopFlag)
			closeConnection = true;

		if(closeConnection || alwaysCloseConnection) {
			connection.shutdown(SocketShutdown.BOTH);
			connection.close();
			ir.dispose();
			closeConnection = false; // don't reclose after loop
			break;
		} else {
			if(ir.front.length) {
				ir.popFront(); // we can't just discard the buffer, so get the next bit and keep chugging along
			} else if(ir.sourceClosed) {
				ir.source.shutdown(SocketShutdown.BOTH);
				ir.source.close();
				ir.dispose();
				closeConnection = false;
			} else {
				continue;
				// break; // this was for a keepalive experiment
			}
		}
	}

	if(closeConnection) {
		connection.shutdown(SocketShutdown.BOTH);
		connection.close();
		ir.dispose();
	}

	// I am otherwise NOT closing it here because the parent thread might still be able to make use of the keep-alive connection!
}

void doThreadScgiConnection(CustomCgi, alias fun, long maxContentLength)(Socket connection) {
	// and now we can buffer
	scope(failure)
		connection.close();

	import al = std.algorithm;

	size_t size;

	string[string] headers;

	auto range = new BufferedInputRange(connection);
	more_data:
	auto chunk = range.front();
	// waiting for colon for header length
	auto idx = indexOf(cast(string) chunk, ':');
	if(idx == -1) {
		try {
			range.popFront();
		} catch(Exception e) {
			// it is just closed, no big deal
			connection.close();
			return;
		}
		goto more_data;
	}

	size = to!size_t(cast(string) chunk[0 .. idx]);
	chunk = range.consume(idx + 1);
	// reading headers
	if(chunk.length < size)
		range.popFront(0, size + 1);
	// we are now guaranteed to have enough
	chunk = range.front();
	assert(chunk.length > size);

	idx = 0;
	string key;
	string value;
	foreach(part; al.splitter(chunk, '\0')) {
		if(idx & 1) { // odd is value
			value = cast(string)(part.idup);
			headers[key] = value; // commit
		} else
			key = cast(string)(part.idup);
		idx++;
	}

	enforce(chunk[size] == ','); // the terminator

	range.consume(size + 1);
	// reading data
	// this will be done by Cgi

	const(ubyte)[] getScgiChunk() {
		// we are already primed
		auto data = range.front();
		if(data.length == 0 && !range.sourceClosed) {
			range.popFront(0);
			data = range.front();
		} else if (range.sourceClosed)
			range.source.close();

		return data;
	}

	void writeScgi(const(ubyte)[] data) {
		sendAll(connection, data);
	}

	void flushScgi() {
		// I don't *think* I have to do anything....
	}

	Cgi cgi;
	try {
		cgi = new CustomCgi(maxContentLength, headers, &getScgiChunk, &writeScgi, &flushScgi);
		cgi._outputFileHandle = cast(CgiConnectionHandle) connection.handle;
	} catch(Throwable t) {
		sendAll(connection, plainHttpError(true, "400 Bad Request", t));
		connection.close();
		return; // this connection is dead
	}
	assert(cgi !is null);
	scope(exit) cgi.dispose();
	try {
		fun(cgi);
		cgi.close();
		connection.close();
	} catch(Throwable t) {
		// no std err
		if(!handleException(cgi, t)) {
			connection.close();
			return;
		} else {
			connection.close();
			return;
		}
	}
}

string printDate(DateTime date) {
	char[29] buffer = void;
	printDateToBuffer(date, buffer[]);
	return buffer.idup;
}

int printDateToBuffer(DateTime date, char[] buffer) @nogc {
	assert(buffer.length >= 29);
	// 29 static length ?

	static immutable daysOfWeek = [
		"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"
	];

	static immutable months = [
		null, "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
	];

	buffer[0 .. 3] = daysOfWeek[date.dayOfWeek];
	buffer[3 .. 5] = ", ";
	buffer[5] = date.day / 10 + '0';
	buffer[6] = date.day % 10 + '0';
	buffer[7] = ' ';
	buffer[8 .. 11] = months[date.month];
	buffer[11] = ' ';
	auto y = date.year;
	buffer[12] = cast(char) (y / 1000 + '0'); y %= 1000;
	buffer[13] = cast(char) (y / 100 + '0'); y %= 100;
	buffer[14] = cast(char) (y / 10 + '0'); y %= 10;
	buffer[15] = cast(char) (y + '0');
	buffer[16] = ' ';
	buffer[17] = date.hour / 10 + '0';
	buffer[18] = date.hour % 10 + '0';
	buffer[19] = ':';
	buffer[20] = date.minute / 10 + '0';
	buffer[21] = date.minute % 10 + '0';
	buffer[22] = ':';
	buffer[23] = date.second / 10 + '0';
	buffer[24] = date.second % 10 + '0';
	buffer[25 .. $] = " GMT";

	return 29;
}


// Referencing this gigantic typeid seems to remind the compiler
// to actually put the symbol in the object file. I guess the immutable
// assoc array array isn't actually included in druntime
void hackAroundLinkerError() {
      stdout.rawWrite(typeid(const(immutable(char)[][])[immutable(char)[]]).toString());
      stdout.rawWrite(typeid(immutable(char)[][][immutable(char)[]]).toString());
      stdout.rawWrite(typeid(Cgi.UploadedFile[immutable(char)[]]).toString());
      stdout.rawWrite(typeid(Cgi.UploadedFile[][immutable(char)[]]).toString());
      stdout.rawWrite(typeid(immutable(Cgi.UploadedFile)[immutable(char)[]]).toString());
      stdout.rawWrite(typeid(immutable(Cgi.UploadedFile[])[immutable(char)[]]).toString());
      stdout.rawWrite(typeid(immutable(char[])[immutable(char)[]]).toString());
      // this is getting kinda ridiculous btw. Moving assoc arrays
      // to the library is the pain that keeps on coming.

      // eh this broke the build on the work server
      // stdout.rawWrite(typeid(immutable(char)[][immutable(string[])]));
      stdout.rawWrite(typeid(immutable(string[])[immutable(char)[]]).toString());
}





version(fastcgi) {
	pragma(lib, "fcgi");

	static if(size_t.sizeof == 8) // 64 bit
		alias long c_int;
	else
		alias int c_int;

	extern(C) {
		struct FCGX_Stream {
			ubyte* rdNext;
			ubyte* wrNext;
			ubyte* stop;
			ubyte* stopUnget;
			c_int isReader;
			c_int isClosed;
			c_int wasFCloseCalled;
			c_int FCGI_errno;
			void* function(FCGX_Stream* stream) fillBuffProc;
			void* function(FCGX_Stream* stream, c_int doClose) emptyBuffProc;
			void* data;
		}

		// note: this is meant to be opaque, so don't access it directly
		struct FCGX_Request {
			int requestId;
			int role;
			FCGX_Stream* inStream;
			FCGX_Stream* outStream;
			FCGX_Stream* errStream;
			char** envp;
			void* paramsPtr;
			int ipcFd;
			int isBeginProcessed;
			int keepConnection;
			int appStatus;
			int nWriters;
			int flags;
			int listen_sock;
		}

		int FCGX_InitRequest(FCGX_Request *request, int sock, int flags);
		void FCGX_Init();

		int FCGX_Accept_r(FCGX_Request *request);


		alias char** FCGX_ParamArray;

		c_int FCGX_Accept(FCGX_Stream** stdin, FCGX_Stream** stdout, FCGX_Stream** stderr, FCGX_ParamArray* envp);
		c_int FCGX_GetChar(FCGX_Stream* stream);
		c_int FCGX_PutStr(const ubyte* str, c_int n, FCGX_Stream* stream);
		int FCGX_HasSeenEOF(FCGX_Stream* stream);
		c_int FCGX_FFlush(FCGX_Stream *stream);

		int FCGX_OpenSocket(in char*, int);
	}
}


/* This might go int a separate module eventually. It is a network input helper class. */

import std.socket;

version(cgi_use_fiber) {
	import core.thread;

	version(linux) {
		import core.sys.linux.epoll;

		int epfd = -1; // thread local because EPOLLEXCLUSIVE works much better this way... weirdly.
	} else version(Windows) {
		// declaring the iocp thing below...
	} else static assert(0, "The hybrid fiber server is not implemented on your OS.");
}

version(Windows)
	__gshared HANDLE iocp;

version(cgi_use_fiber) {
	version(linux)
	private enum WakeupEvent {
		Read = EPOLLIN,
		Write = EPOLLOUT
	}
	else version(Windows)
	private enum WakeupEvent {
		Read, Write
	}
	else static assert(0);
}

version(cgi_use_fiber)
private void registerEventWakeup(bool* registered, Socket source, WakeupEvent e) @nogc {

	// static cast since I know what i have in here and don't want to pay for dynamic cast
	auto f = cast(CgiFiber) cast(void*) Fiber.getThis();

	version(linux) {
		f.setPostYield = () {
			if(*registered) {
				// rearm
				epoll_event evt;
				evt.events = e | EPOLLONESHOT;
				evt.data.ptr = cast(void*) f;
				if(epoll_ctl(epfd, EPOLL_CTL_MOD, source.handle, &evt) == -1)
					throw new Exception("epoll_ctl");
			} else {
				// initial registration
				*registered = true ;
				int fd = source.handle;
				epoll_event evt;
				evt.events = e | EPOLLONESHOT;
				evt.data.ptr = cast(void*) f;
				if(epoll_ctl(epfd, EPOLL_CTL_ADD, fd, &evt) == -1)
					throw new Exception("epoll_ctl");
			}
		};

		Fiber.yield();

		f.setPostYield(null);
	} else version(Windows) {
		Fiber.yield();
	}
	else static assert(0);
}

version(cgi_use_fiber)
void unregisterSource(Socket s) {
	version(linux) {
		epoll_event evt;
		epoll_ctl(epfd, EPOLL_CTL_DEL, s.handle(), &evt);
	} else version(Windows) {
		// intentionally blank
	}
	else static assert(0);
}

// it is a class primarily for reference semantics
// I might change this interface
/// This is NOT ACTUALLY an input range! It is too different. Historical mistake kinda.
class BufferedInputRange {
	version(Posix)
	this(int source, ubyte[] buffer = null) {
		this(new Socket(cast(socket_t) source, AddressFamily.INET), buffer);
	}

	this(Socket source, ubyte[] buffer = null, bool allowGrowth = true) {
		// if they connect but never send stuff to us, we don't want it wasting the process
		// so setting a time out
		version(cgi_use_fiber)
			source.blocking = false;
		else
			source.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, dur!"seconds"(3));

		this.source = source;
		if(buffer is null) {
			underlyingBuffer = new ubyte[4096];
			this.allowGrowth = true;
		} else {
			underlyingBuffer = buffer;
			this.allowGrowth = allowGrowth;
		}

		assert(underlyingBuffer.length);

		// we assume view.ptr is always inside underlyingBuffer
		view = underlyingBuffer[0 .. 0];

		popFront(); // prime
	}

	version(cgi_use_fiber) {
		bool registered;
	}

	void dispose() {
		version(cgi_use_fiber) {
			if(registered)
				unregisterSource(source);
		}
	}

	/**
		A slight difference from regular ranges is you can give it the maximum
		number of bytes to consume.

		IMPORTANT NOTE: the default is to consume nothing, so if you don't call
		consume() yourself and use a regular foreach, it will infinitely loop!

		The default is to do what a normal range does, and consume the whole buffer
		and wait for additional input.

		You can also specify 0, to append to the buffer, or any other number
		to remove the front n bytes and wait for more.
	*/
	void popFront(size_t maxBytesToConsume = 0 /*size_t.max*/, size_t minBytesToSettleFor = 0, bool skipConsume = false) {
		if(sourceClosed)
			throw new ConnectionClosedException("can't get any more data from a closed source");
		if(!skipConsume)
			consume(maxBytesToConsume);

		// we might have to grow the buffer
		if(minBytesToSettleFor > underlyingBuffer.length || view.length == underlyingBuffer.length) {
			if(allowGrowth) {
			//import std.stdio; writeln("growth");
				auto viewStart = view.ptr - underlyingBuffer.ptr;
				size_t growth = 4096;
				// make sure we have enough for what we're being asked for
				if(minBytesToSettleFor > 0 && minBytesToSettleFor - underlyingBuffer.length > growth)
					growth = minBytesToSettleFor - underlyingBuffer.length;
				//import std.stdio; writeln(underlyingBuffer.length, " ", viewStart, " ", view.length, " ", growth,  " ", minBytesToSettleFor, " ", minBytesToSettleFor - underlyingBuffer.length);
				underlyingBuffer.length += growth;
				view = underlyingBuffer[viewStart .. view.length];
			} else
				throw new Exception("No room left in the buffer");
		}

		do {
			auto freeSpace = underlyingBuffer[view.ptr - underlyingBuffer.ptr + view.length .. $];
			try_again:
			auto ret = source.receive(freeSpace);
			if(ret == Socket.ERROR) {
				if(wouldHaveBlocked()) {
					version(cgi_use_fiber) {
						registerEventWakeup(&registered, source, WakeupEvent.Read);
						goto try_again;
					} else {
						// gonna treat a timeout here as a close
						sourceClosed = true;
						return;
					}
				}
				version(Posix) {
					import core.stdc.errno;
					if(errno == EINTR || errno == EAGAIN) {
						goto try_again;
					}
					if(errno == ECONNRESET) {
						sourceClosed = true;
						return;
					}
				}
				throw new Exception(lastSocketError); // FIXME
			}
			if(ret == 0) {
				sourceClosed = true;
				return;
			}

			//import std.stdio; writeln(view.ptr); writeln(underlyingBuffer.ptr); writeln(view.length, " ", ret, " = ", view.length + ret);
			view = underlyingBuffer[view.ptr - underlyingBuffer.ptr .. view.length + ret];
			//import std.stdio; writeln(cast(string) view);
		} while(view.length < minBytesToSettleFor);
	}

	/// Removes n bytes from the front of the buffer, and returns the new buffer slice.
	/// You might want to idup the data you are consuming if you store it, since it may
	/// be overwritten on the new popFront.
	///
	/// You do not need to call this if you always want to wait for more data when you
	/// consume some.
	ubyte[] consume(size_t bytes) {
		//import std.stdio; writeln("consuime ", bytes, "/", view.length);
		view = view[bytes > $ ? $ : bytes .. $];
		if(view.length == 0) {
			view = underlyingBuffer[0 .. 0]; // go ahead and reuse the beginning
			/*
			writeln("HERE");
			popFront(0, 0, true); // try to load more if we can, checks if the source is closed
			writeln(cast(string)front);
			writeln("DONE");
			*/
		}
		return front;
	}

	bool empty() {
		return sourceClosed && view.length == 0;
	}

	ubyte[] front() {
		return view;
	}

	invariant() {
		assert(view.ptr >= underlyingBuffer.ptr);
		// it should never be equal, since if that happens view ought to be empty, and thus reusing the buffer
		assert(view.ptr < underlyingBuffer.ptr + underlyingBuffer.length);
	}

	ubyte[] underlyingBuffer;
	bool allowGrowth;
	ubyte[] view;
	Socket source;
	bool sourceClosed;
}

private class FakeSocketForStdin : Socket {
	import std.stdio;

	this() {

	}

	private bool closed;

	override ptrdiff_t receive(scope void[] buffer, std.socket.SocketFlags) @trusted {
		if(closed)
			throw new Exception("Closed");
		return stdin.rawRead(buffer).length;
	}

	override ptrdiff_t send(const scope void[] buffer, std.socket.SocketFlags) @trusted {
		if(closed)
			throw new Exception("Closed");
		stdout.rawWrite(buffer);
		return buffer.length;
	}

	override void close() @trusted scope {
		(cast(void delegate() @nogc nothrow) &realClose)();
	}

	override void shutdown(SocketShutdown s) {
		// FIXME
	}

	override void setOption(SocketOptionLevel, SocketOption, scope void[]) {}
	override void setOption(SocketOptionLevel, SocketOption, Duration) {}

	override @property @trusted Address remoteAddress() { return null; }
	override @property @trusted Address localAddress() { return null; }

	void realClose() {
		closed = true;
		try {
			stdin.close();
			stdout.close();
		} catch(Exception e) {

		}
	}
}

import core.sync.semaphore;
import core.atomic;

/**
	To use this thing:

	---
	void handler(Socket s) { do something... }
	auto manager = new ListeningConnectionManager("127.0.0.1", 80, &handler, &delegateThatDropsPrivileges);
	manager.listen();
	---

	The 4th parameter is optional.

	I suggest you use BufferedInputRange(connection) to handle the input. As a packet
	comes in, you will get control. You can just continue; though to fetch more.


	FIXME: should I offer an event based async thing like netman did too? Yeah, probably.
*/
class ListeningConnectionManager {
	Semaphore semaphore;
	Socket[256] queue;
	shared(ubyte) nextIndexFront;
	ubyte nextIndexBack;
	shared(int) queueLength;

	Socket acceptCancelable() {
		version(Posix) {
			import core.sys.posix.sys.select;
			fd_set read_fds;
			FD_ZERO(&read_fds);
			FD_SET(listener.handle, &read_fds);
			FD_SET(cancelfd, &read_fds);
			auto max = listener.handle > cancelfd ? listener.handle : cancelfd;
			auto ret = select(max + 1, &read_fds, null, null, null);
			if(ret == -1) {
				import core.stdc.errno;
				if(errno == EINTR)
					return null;
				else
					throw new Exception("wtf select");
			}

			if(FD_ISSET(cancelfd, &read_fds)) {
				return null;
			}

			if(FD_ISSET(listener.handle, &read_fds))
				return listener.accept();

			return null;
		} else
			return listener.accept(); // FIXME: check the cancel flag!
	}

	int defaultNumberOfThreads() {
		import std.parallelism;
		version(cgi_use_fiber) {
			return totalCPUs * 1 + 1;
		} else {
			// I times 4 here because there's a good chance some will be blocked on i/o.
			return totalCPUs * 4;
		}

	}

	void listen() {
		shared(int) loopBroken;

		version(Posix) {
			import core.sys.posix.signal;
			signal(SIGPIPE, SIG_IGN);
		}

		version(linux) {
			if(cancelfd == -1)
				cancelfd = eventfd(0, 0);
		}

		version(cgi_no_threads) {
			// NEVER USE THIS
			// it exists only for debugging and other special occasions

			// the thread mode is faster and less likely to stall the whole
			// thing when a request is slow
			while(!loopBroken && !globalStopFlag) {
				auto sn = acceptCancelable();
				if(sn is null) continue;
				cloexec(sn);
				try {
					handler(sn);
				} catch(Exception e) {
					// if a connection goes wrong, we want to just say no, but try to carry on unless it is an Error of some sort (in which case, we'll die. You might want an external helper program to revive the server when it dies)
					sn.close();
				}
			}
		} else {

			if(useFork) {
				version(linux) {
					//asm { int 3; }
					fork();
				}
			}

			version(cgi_use_fiber) {

				version(Windows) {
					listener.accept();
				}

				WorkerThread[] threads = new WorkerThread[](numberOfThreads);
				foreach(i, ref thread; threads) {
					thread = new WorkerThread(this, handler, cast(int) i);
					thread.start();
				}

				bool fiber_crash_check() {
					bool hasAnyRunning;
					foreach(thread; threads) {
						if(!thread.isRunning) {
							thread.join();
						} else hasAnyRunning = true;
					}

					return (!hasAnyRunning);
				}


				while(!globalStopFlag) {
					Thread.sleep(1.seconds);
					if(fiber_crash_check())
						break;
				}

			} else {
				semaphore = new Semaphore();

				ConnectionThread[] threads = new ConnectionThread[](numberOfThreads);
				foreach(i, ref thread; threads) {
					thread = new ConnectionThread(this, handler, cast(int) i);
					thread.start();
				}

				while(!loopBroken && !globalStopFlag) {
					Socket sn;

					bool crash_check() {
						bool hasAnyRunning;
						foreach(thread; threads) {
							if(!thread.isRunning) {
								thread.join();
							} else hasAnyRunning = true;
						}

						return (!hasAnyRunning);
					}


					void accept_new_connection() {
						sn = acceptCancelable();
						if(sn is null) return;
						cloexec(sn);
						if(tcp) {
							// disable Nagle's algorithm to avoid a 40ms delay when we send/recv
							// on the socket because we do some buffering internally. I think this helps,
							// certainly does for small requests, and I think it does for larger ones too
							sn.setOption(SocketOptionLevel.TCP, SocketOption.TCP_NODELAY, 1);

							sn.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, dur!"seconds"(10));
						}
					}

					void existing_connection_new_data() {
						// wait until a slot opens up
						//int waited = 0;
						while(queueLength >= queue.length) {
							Thread.sleep(1.msecs);
							//waited ++;
						}
						//if(waited) {import std.stdio; writeln(waited);}
						synchronized(this) {
							queue[nextIndexBack] = sn;
							nextIndexBack++;
							atomicOp!"+="(queueLength, 1);
						}
						semaphore.notify();
					}


					accept_new_connection();
					if(sn !is null)
						existing_connection_new_data();
					else if(sn is null && globalStopFlag) {
						foreach(thread; threads) {
							semaphore.notify();
						}
						Thread.sleep(50.msecs);
					}

					if(crash_check())
						break;
				}
			}

			// FIXME: i typically stop this with ctrl+c which never
			// actually gets here. i need to do a sigint handler.
			if(cleanup)
				cleanup();
		}
	}

	//version(linux)
		//int epoll_fd;

	bool tcp;
	void delegate() cleanup;

	private void function(Socket) fhandler;
	private void dg_handler(Socket s) {
		fhandler(s);
	}
	this(string host, ushort port, void function(Socket) handler, void delegate() dropPrivs = null, bool useFork = cgi_use_fork_default, int numberOfThreads = 0) {
		fhandler = handler;
		this(host, port, &dg_handler, dropPrivs, useFork, numberOfThreads);
	}

	this(string host, ushort port, void delegate(Socket) handler, void delegate() dropPrivs = null, bool useFork = cgi_use_fork_default, int numberOfThreads = 0) {
		this.handler = handler;
		this.useFork = useFork;
		this.numberOfThreads = numberOfThreads ? numberOfThreads : defaultNumberOfThreads();

		listener = startListening(host, port, tcp, cleanup, 128, dropPrivs);

		version(cgi_use_fiber)
		if(useFork)
			listener.blocking = false;

		// this is the UI control thread and thus gets more priority
		Thread.getThis.priority = Thread.PRIORITY_MAX;
	}

	Socket listener;
	void delegate(Socket) handler;

	immutable bool useFork;
	int numberOfThreads;
}

Socket startListening(string host, ushort port, ref bool tcp, ref void delegate() cleanup, int backQueue, void delegate() dropPrivs) {
	Socket listener;
	if(host.startsWith("unix:")) {
		version(Posix) {
			listener = new Socket(AddressFamily.UNIX, SocketType.STREAM);
			cloexec(listener);
			string filename = host["unix:".length .. $].idup;
			listener.bind(new UnixAddress(filename));
			cleanup = delegate() {
				listener.close();
				import std.file;
				remove(filename);
			};
			tcp = false;
		} else {
			throw new Exception("unix sockets not supported on this system");
		}
	} else if(host.startsWith("abstract:")) {
		version(linux) {
			listener = new Socket(AddressFamily.UNIX, SocketType.STREAM);
			cloexec(listener);
			string filename = "\0" ~ host["abstract:".length .. $];
			import std.stdio; stderr.writeln("Listening to abstract unix domain socket: ", host["abstract:".length .. $]);
			listener.bind(new UnixAddress(filename));
			tcp = false;
		} else {
			throw new Exception("abstract unix sockets not supported on this system");
		}
	} else {
		version(cgi_use_fiber) {
			version(Windows)
				listener = new PseudoblockingOverlappedSocket(AddressFamily.INET, SocketType.STREAM);
			else
				listener = new TcpSocket();
		} else {
			listener = new TcpSocket();
		}
		cloexec(listener);
		listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
		listener.bind(host.length ? parseAddress(host, port) : new InternetAddress(port));
		cleanup = delegate() {
			listener.close();
		};
		tcp = true;
	}

	listener.listen(backQueue);

	if (dropPrivs !is null) // can be null, backwards compatibility
		dropPrivs();

	return listener;
}

// helper function to send a lot to a socket. Since this blocks for the buffer (possibly several times), you should probably call it in a separate thread or something.
void sendAll(Socket s, const(void)[] data, string file = __FILE__, size_t line = __LINE__) {
	if(data.length == 0) return;
	ptrdiff_t amount;
	//import std.stdio; writeln("***",cast(string) data,"///");
	do {
		amount = s.send(data);
		if(amount == Socket.ERROR) {
			version(cgi_use_fiber) {
				if(wouldHaveBlocked()) {
					bool registered = true;
					registerEventWakeup(&registered, s, WakeupEvent.Write);
					continue;
				}
			}
			throw new ConnectionException(s, lastSocketError, file, line);
		}
		assert(amount > 0);

		data = data[amount .. $];
	} while(data.length);
}

class ConnectionException : Exception {
	Socket socket;
	this(Socket s, string msg, string file = __FILE__, size_t line = __LINE__) {
		this.socket = s;
		super(msg, file, line);
	}
}

alias void delegate(Socket) CMT;

import core.thread;
/+
	cgi.d now uses a hybrid of event i/o and threads at the top level.

	Top level thread is responsible for accepting sockets and selecting on them.

	It then indicates to a child that a request is pending, and any random worker
	thread that is free handles it. It goes into blocking mode and handles that
	http request to completion.

	At that point, it goes back into the waiting queue.


	This concept is only implemented on Linux. On all other systems, it still
	uses the worker threads and semaphores (which is perfectly fine for a lot of
	things! Just having a great number of keep-alive connections will break that.)


	So the algorithm is:

	select(accept, event, pending)
		if accept -> send socket to free thread, if any. if not, add socket to queue
		if event -> send the signaling thread a socket from the queue, if not, mark it free
			- event might block until it can be *written* to. it is a fifo sending socket fds!

	A worker only does one http request at a time, then signals its availability back to the boss.

	The socket the worker was just doing should be added to the one-off epoll read. If it is closed,
	great, we can get rid of it. Otherwise, it is considered `pending`. The *kernel* manages that; the
	actual FD will not be kept out here.

	So:
		queue = sockets we know are ready to read now, but no worker thread is available
		idle list = worker threads not doing anything else. they signal back and forth

	the workers all read off the event fd. This is the semaphore wait

	the boss waits on accept or other sockets read events (one off! and level triggered). If anything happens wrt ready read,
	it puts it in the queue and writes to the event fd.

	The child could put the socket back in the epoll thing itself.

	The child needs to be able to gracefully handle being given a socket that just closed with no work.
+/
class ConnectionThread : Thread {
	this(ListeningConnectionManager lcm, CMT dg, int myThreadNumber) {
		this.lcm = lcm;
		this.dg = dg;
		this.myThreadNumber = myThreadNumber;
		super(&run);
	}

	void run() {
		while(true) {
			// so if there's a bunch of idle keep-alive connections, it can
			// consume all the worker threads... just sitting there.
			lcm.semaphore.wait();
			if(globalStopFlag)
				return;
			Socket socket;
			synchronized(lcm) {
				auto idx = lcm.nextIndexFront;
				socket = lcm.queue[idx];
				lcm.queue[idx] = null;
				atomicOp!"+="(lcm.nextIndexFront, 1);
				atomicOp!"-="(lcm.queueLength, 1);
			}
			try {
			//import std.stdio; writeln(myThreadNumber, " taking it");
				dg(socket);
				/+
				if(socket.isAlive) {
					// process it more later
					version(linux) {
						import core.sys.linux.epoll;
						epoll_event ev;
						ev.events = EPOLLIN | EPOLLONESHOT | EPOLLET;
						ev.data.fd = socket.handle;
						import std.stdio; writeln("adding");
						if(epoll_ctl(lcm.epoll_fd, EPOLL_CTL_ADD, socket.handle, &ev) == -1) {
							if(errno == EEXIST) {
								ev.events = EPOLLIN | EPOLLONESHOT | EPOLLET;
								ev.data.fd = socket.handle;
								if(epoll_ctl(lcm.epoll_fd, EPOLL_CTL_MOD, socket.handle, &ev) == -1)
									throw new Exception("epoll_ctl " ~ to!string(errno));
							} else
								throw new Exception("epoll_ctl " ~ to!string(errno));
						}
						//import std.stdio; writeln("keep alive");
						// writing to this private member is to prevent the GC from closing my precious socket when I'm trying to use it later
						__traits(getMember, socket, "sock") = cast(socket_t) -1;
					} else {
						continue; // hope it times out in a reasonable amount of time...
					}
				}
				+/
			} catch(ConnectionClosedException e) {
				// can just ignore this, it is fairly normal
				socket.close();
			} catch(Throwable e) {
				import std.stdio; stderr.rawWrite(e.toString); stderr.rawWrite("\n");
				socket.close();
			}
		}
	}

	ListeningConnectionManager lcm;
	CMT dg;
	int myThreadNumber;
}

version(cgi_use_fiber)
class WorkerThread : Thread {
	this(ListeningConnectionManager lcm, CMT dg, int myThreadNumber) {
		this.lcm = lcm;
		this.dg = dg;
		this.myThreadNumber = myThreadNumber;
		super(&run);
	}

	version(Windows)
	void run() {
		auto timeout = INFINITE;
		PseudoblockingOverlappedSocket key;
		OVERLAPPED* overlapped;
		DWORD bytes;
		while(!globalStopFlag && GetQueuedCompletionStatus(iocp, &bytes, cast(PULONG_PTR) &key, &overlapped, timeout)) {
			if(key is null)
				continue;
			key.lastAnswer = bytes;
			if(key.fiber) {
				key.fiber.proceed();
			} else {
				// we have a new connection, issue the first receive on it and issue the next accept

				auto sn = key.accepted;

				key.accept();

				cloexec(sn);
				if(lcm.tcp) {
					// disable Nagle's algorithm to avoid a 40ms delay when we send/recv
					// on the socket because we do some buffering internally. I think this helps,
					// certainly does for small requests, and I think it does for larger ones too
					sn.setOption(SocketOptionLevel.TCP, SocketOption.TCP_NODELAY, 1);

					sn.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, dur!"seconds"(10));
				}

				dg(sn);
			}
		}
		//SleepEx(INFINITE, TRUE);
	}

	version(linux)
	void run() {

		import core.sys.linux.epoll;
		epfd = epoll_create1(EPOLL_CLOEXEC);
		if(epfd == -1)
			throw new Exception("epoll_create1 " ~ to!string(errno));
		scope(exit) {
			import core.sys.posix.unistd;
			close(epfd);
		}

		{
			epoll_event ev;
			ev.events = EPOLLIN;
			ev.data.fd = cancelfd;
			epoll_ctl(epfd, EPOLL_CTL_ADD, cancelfd, &ev);
		}

		epoll_event ev;
		ev.events = EPOLLIN | EPOLLEXCLUSIVE; // EPOLLEXCLUSIVE is only available on kernels since like 2017 but that's prolly good enough.
		ev.data.fd = lcm.listener.handle;
		if(epoll_ctl(epfd, EPOLL_CTL_ADD, lcm.listener.handle, &ev) == -1)
			throw new Exception("epoll_ctl " ~ to!string(errno));



		while(!globalStopFlag) {
			Socket sn;

			epoll_event[64] events;
			auto nfds = epoll_wait(epfd, events.ptr, events.length, -1);
			if(nfds == -1) {
				if(errno == EINTR)
					continue;
				throw new Exception("epoll_wait " ~ to!string(errno));
			}

			foreach(idx; 0 .. nfds) {
				auto flags = events[idx].events;

				if(cast(size_t) events[idx].data.ptr == cast(size_t) cancelfd) {
					globalStopFlag = true;
					//import std.stdio; writeln("exit heard");
					break;
				} else if(cast(size_t) events[idx].data.ptr == cast(size_t) lcm.listener.handle) {
					//import std.stdio; writeln(myThreadNumber, " woken up ", flags);
					// this try/catch is because it is set to non-blocking mode
					// and Phobos' stupid api throws an exception instead of returning
					// if it would block. Why would it block? because a forked process
					// might have beat us to it, but the wakeup event thundered our herds.
						try
						sn = lcm.listener.accept(); // don't need to do the acceptCancelable here since the epoll checks it better
						catch(SocketAcceptException e) { continue; }

					cloexec(sn);
					if(lcm.tcp) {
						// disable Nagle's algorithm to avoid a 40ms delay when we send/recv
						// on the socket because we do some buffering internally. I think this helps,
						// certainly does for small requests, and I think it does for larger ones too
						sn.setOption(SocketOptionLevel.TCP, SocketOption.TCP_NODELAY, 1);

						sn.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, dur!"seconds"(10));
					}

					dg(sn);
				} else {
					if(cast(size_t) events[idx].data.ptr < 1024) {
						throw new Exception("this doesn't look like a fiber pointer...");
					}
					auto fiber = cast(CgiFiber) events[idx].data.ptr;
					fiber.proceed();
				}
			}
		}
	}

	ListeningConnectionManager lcm;
	CMT dg;
	int myThreadNumber;
}


/* Done with network helper */

/* Helpers for doing temporary files. Used both here and in web.d */

version(Windows) {
	import core.sys.windows.windows;
	extern(Windows) DWORD GetTempPathW(DWORD, LPWSTR);
	alias GetTempPathW GetTempPath;
}

version(Posix) {
	static import linux = core.sys.posix.unistd;
}

string getTempDirectory() {
	string path;
	version(Windows) {
		wchar[1024] buffer;
		auto len = GetTempPath(1024, buffer.ptr);
		if(len == 0)
			throw new Exception("couldn't find a temporary path");

		auto b = buffer[0 .. len];

		path = to!string(b);
	} else
		path = "/tmp/";

	return path;
}


// I like std.date. These functions help keep my old code and data working with phobos changing.

long sysTimeToDTime(in SysTime sysTime) {
    return convert!("hnsecs", "msecs")(sysTime.stdTime - 621355968000000000L);
}

long dateTimeToDTime(in DateTime dt) {
	return sysTimeToDTime(cast(SysTime) dt);
}

long getUtcTime() { // renamed primarily to avoid conflict with std.date itself
	return sysTimeToDTime(Clock.currTime(UTC()));
}

// NOTE: new SimpleTimeZone(minutes); can perhaps work with the getTimezoneOffset() JS trick
SysTime dTimeToSysTime(long dTime, immutable TimeZone tz = null) {
	immutable hnsecs = convert!("msecs", "hnsecs")(dTime) + 621355968000000000L;
	return SysTime(hnsecs, tz);
}



// this is a helper to read HTTP transfer-encoding: chunked responses
immutable(ubyte[]) dechunk(BufferedInputRange ir) {
	immutable(ubyte)[] ret;

	another_chunk:
	// If here, we are at the beginning of a chunk.
	auto a = ir.front();
	int chunkSize;
	int loc = locationOf(a, "\r\n");
	while(loc == -1) {
		ir.popFront();
		a = ir.front();
		loc = locationOf(a, "\r\n");
	}

	string hex;
	hex = "";
	for(int i = 0; i < loc; i++) {
		char c = a[i];
		if(c >= 'A' && c <= 'Z')
			c += 0x20;
		if((c >= '0' && c <= '9') || (c >= 'a' && c <= 'z')) {
			hex ~= c;
		} else {
			break;
		}
	}

	assert(hex.length);

	int power = 1;
	int size = 0;
	foreach(cc1; retro(hex)) {
		dchar cc = cc1;
		if(cc >= 'a' && cc <= 'z')
			cc -= 0x20;
		int val = 0;
		if(cc >= '0' && cc <= '9')
			val = cc - '0';
		else
			val = cc - 'A' + 10;

		size += power * val;
		power *= 16;
	}

	chunkSize = size;
	assert(size >= 0);

	if(loc + 2 > a.length) {
		ir.popFront(0, a.length + loc + 2);
		a = ir.front();
	}

	a = ir.consume(loc + 2);

	if(chunkSize == 0) { // we're done with the response
		// if we got here, will change must be true....
		more_footers:
		loc = locationOf(a, "\r\n");
		if(loc == -1) {
			ir.popFront();
			a = ir.front;
			goto more_footers;
		} else {
			assert(loc == 0);
			ir.consume(loc + 2);
			goto finish;
		}
	} else {
		// if we got here, will change must be true....
		if(a.length < chunkSize + 2) {
			ir.popFront(0, chunkSize + 2);
			a = ir.front();
		}

		ret ~= (a[0..chunkSize]);

		if(!(a.length > chunkSize + 2)) {
			ir.popFront(0, chunkSize + 2);
			a = ir.front();
		}
		assert(a[chunkSize] == 13);
		assert(a[chunkSize+1] == 10);
		a = ir.consume(chunkSize + 2);
		chunkSize = 0;
		goto another_chunk;
	}

	finish:
	return ret;
}

// I want to be able to get data from multiple sources the same way...
interface ByChunkRange {
	bool empty();
	void popFront();
	const(ubyte)[] front();
}

ByChunkRange byChunk(const(ubyte)[] data) {
	return new class ByChunkRange {
		override bool empty() {
			return !data.length;
		}

		override void popFront() {
			if(data.length > 4096)
				data = data[4096 .. $];
			else
				data = null;
		}

		override const(ubyte)[] front() {
			return data[0 .. $ > 4096 ? 4096 : $];
		}
	};
}

ByChunkRange byChunk(BufferedInputRange ir, size_t atMost) {
	const(ubyte)[] f;

	f = ir.front;
	if(f.length > atMost)
		f = f[0 .. atMost];

	return new class ByChunkRange {
		override bool empty() {
			return atMost == 0;
		}

		override const(ubyte)[] front() {
			return f;
		}

		override void popFront() {
			ir.consume(f.length);
			atMost -= f.length;
			auto a = ir.front();

			if(a.length <= atMost) {
				f = a;
				atMost -= a.length;
				a = ir.consume(a.length);
				if(atMost != 0)
					ir.popFront();
				if(f.length == 0) {
					f = ir.front();
				}
			} else {
				// we actually have *more* here than we need....
				f = a[0..atMost];
				atMost = 0;
				ir.consume(atMost);
			}
		}
	};
}

version(cgi_with_websocket) {
	// http://tools.ietf.org/html/rfc6455

	/**
		WEBSOCKET SUPPORT:

		Full example:
		---
			import arsd.cgi;

			void websocketEcho(Cgi cgi) {
				if(cgi.websocketRequested()) {
					if(cgi.origin != "http://arsdnet.net")
						throw new Exception("bad origin");
					auto websocket = cgi.acceptWebsocket();

					websocket.send("hello");
					websocket.send(" world!");

					auto msg = websocket.recv();
					while(msg.opcode != WebSocketOpcode.close) {
						if(msg.opcode == WebSocketOpcode.text) {
							websocket.send(msg.textData);
						} else if(msg.opcode == WebSocketOpcode.binary) {
							websocket.send(msg.data);
						}

						msg = websocket.recv();
					}

					websocket.close();
				} else assert(0, "i want a web socket!");
			}

			mixin GenericMain!websocketEcho;
		---
	*/

	class WebSocket {
		Cgi cgi;

		private this(Cgi cgi) {
			this.cgi = cgi;

			Socket socket = cgi.idlol.source;
			socket.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, dur!"minutes"(5));
		}

		// returns true if data available, false if it timed out
		bool recvAvailable(Duration timeout = dur!"msecs"(0)) {
			if(!waitForNextMessageWouldBlock())
				return true;
			if(isDataPending(timeout))
				return true; // this is kinda a lie.

			return false;
		}

		public bool lowLevelReceive() {
			auto bfr = cgi.idlol;
			top:
			auto got = bfr.front;
			if(got.length) {
				if(receiveBuffer.length < receiveBufferUsedLength + got.length)
					receiveBuffer.length += receiveBufferUsedLength + got.length;

				receiveBuffer[receiveBufferUsedLength .. receiveBufferUsedLength + got.length] = got[];
				receiveBufferUsedLength += got.length;
				bfr.consume(got.length);

				return true;
			}

			if(bfr.sourceClosed)
				return false;

			bfr.popFront(0);
			if(bfr.sourceClosed)
				return false;
			goto top;
		}


		bool isDataPending(Duration timeout = 0.seconds) {
			Socket socket = cgi.idlol.source;

			auto check = new SocketSet();
			check.add(socket);

			auto got = Socket.select(check, null, null, timeout);
			if(got > 0)
				return true;
			return false;
		}

		// note: this blocks
		WebSocketFrame recv() {
			return waitForNextMessage();
		}




		private void llclose() {
			cgi.close();
		}

		private void llsend(ubyte[] data) {
			cgi.write(data);
			cgi.flush();
		}

		void unregisterActiveSocket(WebSocket) {}

		/* copy/paste section { */

		private int readyState_;
		private ubyte[] receiveBuffer;
		private size_t receiveBufferUsedLength;

		private Config config;

		enum CONNECTING = 0; /// Socket has been created. The connection is not yet open.
		enum OPEN = 1; /// The connection is open and ready to communicate.
		enum CLOSING = 2; /// The connection is in the process of closing.
		enum CLOSED = 3; /// The connection is closed or couldn't be opened.

		/++

		+/
		/// Group: foundational
		static struct Config {
			/++
				These control the size of the receive buffer.

				It starts at the initial size, will temporarily
				balloon up to the maximum size, and will reuse
				a buffer up to the likely size.

				Anything larger than the maximum size will cause
				the connection to be aborted and an exception thrown.
				This is to protect you against a peer trying to
				exhaust your memory, while keeping the user-level
				processing simple.
			+/
			size_t initialReceiveBufferSize = 4096;
			size_t likelyReceiveBufferSize = 4096; /// ditto
			size_t maximumReceiveBufferSize = 10 * 1024 * 1024; /// ditto

			/++
				Maximum combined size of a message.
			+/
			size_t maximumMessageSize = 10 * 1024 * 1024;

			string[string] cookies; /// Cookies to send with the initial request. cookies[name] = value;
			string origin; /// Origin URL to send with the handshake, if desired.
			string protocol; /// the protocol header, if desired.

			int pingFrequency = 5000; /// Amount of time (in msecs) of idleness after which to send an automatic ping
		}

		/++
			Returns one of [CONNECTING], [OPEN], [CLOSING], or [CLOSED].
		+/
		int readyState() {
			return readyState_;
		}

		/++
			Closes the connection, sending a graceful teardown message to the other side.
		+/
		/// Group: foundational
		void close(int code = 0, string reason = null)
			//in (reason.length < 123)
			in { assert(reason.length < 123); } do
		{
			if(readyState_ != OPEN)
				return; // it cool, we done
			WebSocketFrame wss;
			wss.fin = true;
			wss.opcode = WebSocketOpcode.close;
			wss.data = cast(ubyte[]) reason.dup;
			wss.send(&llsend);

			readyState_ = CLOSING;

			llclose();
		}

		/++
			Sends a ping message to the server. This is done automatically by the library if you set a non-zero [Config.pingFrequency], but you can also send extra pings explicitly as well with this function.
		+/
		/// Group: foundational
		void ping() {
			WebSocketFrame wss;
			wss.fin = true;
			wss.opcode = WebSocketOpcode.ping;
			wss.send(&llsend);
		}

		// automatically handled....
		void pong() {
			WebSocketFrame wss;
			wss.fin = true;
			wss.opcode = WebSocketOpcode.pong;
			wss.send(&llsend);
		}

		/++
			Sends a text message through the websocket.
		+/
		/// Group: foundational
		void send(in char[] textData) {
			WebSocketFrame wss;
			wss.fin = true;
			wss.opcode = WebSocketOpcode.text;
			wss.data = cast(ubyte[]) textData.dup;
			wss.send(&llsend);
		}

		/++
			Sends a binary message through the websocket.
		+/
		/// Group: foundational
		void send(in ubyte[] binaryData) {
			WebSocketFrame wss;
			wss.fin = true;
			wss.opcode = WebSocketOpcode.binary;
			wss.data = cast(ubyte[]) binaryData.dup;
			wss.send(&llsend);
		}

		/++
			Waits for and returns the next complete message on the socket.

			Note that the onmessage function is still called, right before
			this returns.
		+/
		/// Group: blocking_api
		public WebSocketFrame waitForNextMessage() {
			do {
				auto m = processOnce();
				if(m.populated)
					return m;
			} while(lowLevelReceive());

			throw new ConnectionClosedException("Websocket receive timed out");
			//return WebSocketFrame.init; // FIXME? maybe.
		}

		/++
			Tells if [waitForNextMessage] would block.
		+/
		/// Group: blocking_api
		public bool waitForNextMessageWouldBlock() {
			checkAgain:
			if(isMessageBuffered())
				return false;
			if(!isDataPending())
				return true;
			while(isDataPending())
				lowLevelReceive();
			goto checkAgain;
		}

		/++
			Is there a message in the buffer already?
			If `true`, [waitForNextMessage] is guaranteed to return immediately.
			If `false`, check [isDataPending] as the next step.
		+/
		/// Group: blocking_api
		public bool isMessageBuffered() {
			ubyte[] d = receiveBuffer[0 .. receiveBufferUsedLength];
			auto s = d;
			if(d.length) {
				auto orig = d;
				auto m = WebSocketFrame.read(d);
				// that's how it indicates that it needs more data
				if(d !is orig)
					return true;
			}

			return false;
		}

		private ubyte continuingType;
		private ubyte[] continuingData;
		//private size_t continuingDataLength;

		private WebSocketFrame processOnce() {
			ubyte[] d = receiveBuffer[0 .. receiveBufferUsedLength];
			auto s = d;
			// FIXME: handle continuation frames more efficiently. it should really just reuse the receive buffer.
			WebSocketFrame m;
			if(d.length) {
				auto orig = d;
				m = WebSocketFrame.read(d);
				// that's how it indicates that it needs more data
				if(d is orig)
					return WebSocketFrame.init;
				m.unmaskInPlace();
				switch(m.opcode) {
					case WebSocketOpcode.continuation:
						if(continuingData.length + m.data.length > config.maximumMessageSize)
							throw new Exception("message size exceeded");

						continuingData ~= m.data;
						if(m.fin) {
							if(ontextmessage)
								ontextmessage(cast(char[]) continuingData);
							if(onbinarymessage)
								onbinarymessage(continuingData);

							continuingData = null;
						}
					break;
					case WebSocketOpcode.text:
						if(m.fin) {
							if(ontextmessage)
								ontextmessage(m.textData);
						} else {
							continuingType = m.opcode;
							//continuingDataLength = 0;
							continuingData = null;
							continuingData ~= m.data;
						}
					break;
					case WebSocketOpcode.binary:
						if(m.fin) {
							if(onbinarymessage)
								onbinarymessage(m.data);
						} else {
							continuingType = m.opcode;
							//continuingDataLength = 0;
							continuingData = null;
							continuingData ~= m.data;
						}
					break;
					case WebSocketOpcode.close:
						readyState_ = CLOSED;
						if(onclose)
							onclose();

						unregisterActiveSocket(this);
					break;
					case WebSocketOpcode.ping:
						pong();
					break;
					case WebSocketOpcode.pong:
						// just really references it is still alive, nbd.
					break;
					default: // ignore though i could and perhaps should throw too
				}
			}

			// the recv thing can be invalidated so gotta copy it over ugh
			if(d.length) {
				m.data = m.data.dup();
			}

			import core.stdc.string;
			memmove(receiveBuffer.ptr, d.ptr, d.length);
			receiveBufferUsedLength = d.length;

			return m;
		}

		private void autoprocess() {
			// FIXME
			do {
				processOnce();
			} while(lowLevelReceive());
		}


		void delegate() onclose; ///
		void delegate() onerror; ///
		void delegate(in char[]) ontextmessage; ///
		void delegate(in ubyte[]) onbinarymessage; ///
		void delegate() onopen; ///

		/++

		+/
		/// Group: browser_api
		void onmessage(void delegate(in char[]) dg) {
			ontextmessage = dg;
		}

		/// ditto
		void onmessage(void delegate(in ubyte[]) dg) {
			onbinarymessage = dg;
		}

		/* } end copy/paste */


	}

	bool websocketRequested(Cgi cgi) {
		return
			"sec-websocket-key" in cgi.requestHeaders
			&&
			"connection" in cgi.requestHeaders &&
				cgi.requestHeaders["connection"].asLowerCase().canFind("upgrade")
			&&
			"upgrade" in cgi.requestHeaders &&
				cgi.requestHeaders["upgrade"].asLowerCase().equal("websocket")
			;
	}

	WebSocket acceptWebsocket(Cgi cgi) {
		assert(!cgi.closed);
		assert(!cgi.outputtedResponseData);
		cgi.setResponseStatus("101 Switching Protocols");
		cgi.header("Upgrade: WebSocket");
		cgi.header("Connection: upgrade");

		string key = cgi.requestHeaders["sec-websocket-key"];
		key ~= "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"; // the defined guid from the websocket spec

		import std.digest.sha;
		auto hash = sha1Of(key);
		auto accept = Base64.encode(hash);

		cgi.header(("Sec-WebSocket-Accept: " ~ accept).idup);

		cgi.websocketMode = true;
		cgi.write("");

		cgi.flush();

		return new WebSocket(cgi);
	}

	// FIXME get websocket to work on other modes, not just embedded_httpd

	/* copy/paste in http2.d { */
	enum WebSocketOpcode : ubyte {
		continuation = 0,
		text = 1,
		binary = 2,
		// 3, 4, 5, 6, 7 RESERVED
		close = 8,
		ping = 9,
		pong = 10,
		// 11,12,13,14,15 RESERVED
	}

	public struct WebSocketFrame {
		private bool populated;
		bool fin;
		bool rsv1;
		bool rsv2;
		bool rsv3;
		WebSocketOpcode opcode; // 4 bits
		bool masked;
		ubyte lengthIndicator; // don't set this when building one to send
		ulong realLength; // don't use when sending
		ubyte[4] maskingKey; // don't set this when sending
		ubyte[] data;

		static WebSocketFrame simpleMessage(WebSocketOpcode opcode, void[] data) {
			WebSocketFrame msg;
			msg.fin = true;
			msg.opcode = opcode;
			msg.data = cast(ubyte[]) data.dup;

			return msg;
		}

		private void send(scope void delegate(ubyte[]) llsend) {
			ubyte[64] headerScratch;
			int headerScratchPos = 0;

			realLength = data.length;

			{
				ubyte b1;
				b1 |= cast(ubyte) opcode;
				b1 |= rsv3 ? (1 << 4) : 0;
				b1 |= rsv2 ? (1 << 5) : 0;
				b1 |= rsv1 ? (1 << 6) : 0;
				b1 |= fin  ? (1 << 7) : 0;

				headerScratch[0] = b1;
				headerScratchPos++;
			}

			{
				headerScratchPos++; // we'll set header[1] at the end of this
				auto rlc = realLength;
				ubyte b2;
				b2 |= masked ? (1 << 7) : 0;

				assert(headerScratchPos == 2);

				if(realLength > 65535) {
					// use 64 bit length
					b2 |= 0x7f;

					// FIXME: double check endinaness
					foreach(i; 0 .. 8) {
						headerScratch[2 + 7 - i] = rlc & 0x0ff;
						rlc >>>= 8;
					}

					headerScratchPos += 8;
				} else if(realLength > 125) {
					// use 16 bit length
					b2 |= 0x7e;

					// FIXME: double check endinaness
					foreach(i; 0 .. 2) {
						headerScratch[2 + 1 - i] = rlc & 0x0ff;
						rlc >>>= 8;
					}

					headerScratchPos += 2;
				} else {
					// use 7 bit length
					b2 |= realLength & 0b_0111_1111;
				}

				headerScratch[1] = b2;
			}

			//assert(!masked, "masking key not properly implemented");
			if(masked) {
				// FIXME: randomize this
				headerScratch[headerScratchPos .. headerScratchPos + 4] = maskingKey[];
				headerScratchPos += 4;

				// we'll just mask it in place...
				int keyIdx = 0;
				foreach(i; 0 .. data.length) {
					data[i] = data[i] ^ maskingKey[keyIdx];
					if(keyIdx == 3)
						keyIdx = 0;
					else
						keyIdx++;
				}
			}

			//writeln("SENDING ", headerScratch[0 .. headerScratchPos], data);
			llsend(headerScratch[0 .. headerScratchPos]);
			llsend(data);
		}

		static WebSocketFrame read(ref ubyte[] d) {
			WebSocketFrame msg;

			auto orig = d;

			WebSocketFrame needsMoreData() {
				d = orig;
				return WebSocketFrame.init;
			}

			if(d.length < 2)
				return needsMoreData();

			ubyte b = d[0];

			msg.populated = true;

			msg.opcode = cast(WebSocketOpcode) (b & 0x0f);
			b >>= 4;
			msg.rsv3 = b & 0x01;
			b >>= 1;
			msg.rsv2 = b & 0x01;
			b >>= 1;
			msg.rsv1 = b & 0x01;
			b >>= 1;
			msg.fin = b & 0x01;

			b = d[1];
			msg.masked = (b & 0b1000_0000) ? true : false;
			msg.lengthIndicator = b & 0b0111_1111;

			d = d[2 .. $];

			if(msg.lengthIndicator == 0x7e) {
				// 16 bit length
				msg.realLength = 0;

				if(d.length < 2) return needsMoreData();

				foreach(i; 0 .. 2) {
					msg.realLength |= d[0] << ((1-i) * 8);
					d = d[1 .. $];
				}
			} else if(msg.lengthIndicator == 0x7f) {
				// 64 bit length
				msg.realLength = 0;

				if(d.length < 8) return needsMoreData();

				foreach(i; 0 .. 8) {
					msg.realLength |= ulong(d[0]) << ((7-i) * 8);
					d = d[1 .. $];
				}
			} else {
				// 7 bit length
				msg.realLength = msg.lengthIndicator;
			}

			if(msg.masked) {

				if(d.length < 4) return needsMoreData();

				msg.maskingKey = d[0 .. 4];
				d = d[4 .. $];
			}

			if(msg.realLength > d.length) {
				return needsMoreData();
			}

			msg.data = d[0 .. cast(size_t) msg.realLength];
			d = d[cast(size_t) msg.realLength .. $];

			return msg;
		}

		void unmaskInPlace() {
			if(this.masked) {
				int keyIdx = 0;
				foreach(i; 0 .. this.data.length) {
					this.data[i] = this.data[i] ^ this.maskingKey[keyIdx];
					if(keyIdx == 3)
						keyIdx = 0;
					else
						keyIdx++;
				}
			}
		}

		char[] textData() {
			return cast(char[]) data;
		}
	}
	/* } */
}


version(Windows)
{
    version(CRuntime_DigitalMars)
    {
        extern(C) int setmode(int, int) nothrow @nogc;
    }
    else version(CRuntime_Microsoft)
    {
        extern(C) int _setmode(int, int) nothrow @nogc;
        alias setmode = _setmode;
    }
    else static assert(0);
}

version(Posix) {
	version(CRuntime_Musl) {} else {
		import core.sys.posix.unistd;
		private extern(C) int posix_spawn(pid_t*, const char*, void*, void*, const char**, const char**);
	}
}


// FIXME: these aren't quite public yet.
//private:

// template for laziness
void startAddonServer()(string arg) {
	version(OSX) {
		assert(0, "Not implemented");
	} else version(linux) {
		import core.sys.posix.unistd;
		pid_t pid;
		const(char)*[16] args;
		args[0] = "ARSD_CGI_ADDON_SERVER";
		args[1] = arg.ptr;
		posix_spawn(&pid, "/proc/self/exe",
			null,
			null,
			args.ptr,
			null // env
		);
	} else version(Windows) {
		wchar[2048] filename;
		auto len = GetModuleFileNameW(null, filename.ptr, cast(DWORD) filename.length);
		if(len == 0 || len == filename.length)
			throw new Exception("could not get process name to start helper server");

		STARTUPINFOW startupInfo;
		startupInfo.cb = cast(DWORD) startupInfo.sizeof;
		PROCESS_INFORMATION processInfo;

		import std.utf;

		// I *MIGHT* need to run it as a new job or a service...
		auto ret = CreateProcessW(
			filename.ptr,
			toUTF16z(arg),
			null, // process attributes
			null, // thread attributes
			false, // inherit handles
			0, // creation flags
			null, // environment
			null, // working directory
			&startupInfo,
			&processInfo
		);

		if(!ret)
			throw new Exception("create process failed");

		// when done with those, if we set them
		/*
		CloseHandle(hStdInput);
		CloseHandle(hStdOutput);
		CloseHandle(hStdError);
		*/

	} else static assert(0, "Websocket server not implemented on this system yet (email me, i can prolly do it if you need it)");
}

// template for laziness
/*
	The websocket server is a single-process, single-thread, event
	I/O thing. It is passed websockets from other CGI processes
	and is then responsible for handling their messages and responses.
	Note that the CGI process is responsible for websocket setup,
	including authentication, etc.

	It also gets data sent to it by other processes and is responsible
	for distributing that, as necessary.
*/
void runWebsocketServer()() {
	assert(0, "not implemented");
}

void sendToWebsocketServer(WebSocket ws, string group) {
	assert(0, "not implemented");
}

void sendToWebsocketServer(string content, string group) {
	assert(0, "not implemented");
}


void runEventServer()() {
	runAddonServer("/tmp/arsd_cgi_event_server", new EventSourceServerImplementation());
}

void runTimerServer()() {
	runAddonServer("/tmp/arsd_scheduled_job_server", new ScheduledJobServerImplementation());
}

version(Posix) {
	alias LocalServerConnectionHandle = int;
	alias CgiConnectionHandle = int;
	alias SocketConnectionHandle = int;

	enum INVALID_CGI_CONNECTION_HANDLE = -1;
} else version(Windows) {
	alias LocalServerConnectionHandle = HANDLE;
	version(embedded_httpd_threads) {
		alias CgiConnectionHandle = SOCKET;
		enum INVALID_CGI_CONNECTION_HANDLE = INVALID_SOCKET;
	} else version(fastcgi) {
		alias CgiConnectionHandle = void*; // Doesn't actually work! But I don't want compile to fail pointlessly at this point.
		enum INVALID_CGI_CONNECTION_HANDLE = null;
	} else version(scgi) {
		alias CgiConnectionHandle = SOCKET;
		enum INVALID_CGI_CONNECTION_HANDLE = INVALID_SOCKET;
	} else { /* version(plain_cgi) */
		alias CgiConnectionHandle = HANDLE;
		enum INVALID_CGI_CONNECTION_HANDLE = null;
	}
	alias SocketConnectionHandle = SOCKET;
}

version(with_addon_servers_connections)
LocalServerConnectionHandle openLocalServerConnection()(string name, string arg) {
	version(Posix) {
		import core.sys.posix.unistd;
		import core.sys.posix.sys.un;

		int sock = socket(AF_UNIX, SOCK_STREAM, 0);
		if(sock == -1)
			throw new Exception("socket " ~ to!string(errno));

		scope(failure)
			close(sock);

		cloexec(sock);

		// add-on server processes are assumed to be local, and thus will
		// use unix domain sockets. Besides, I want to pass sockets to them,
		// so it basically must be local (except for the session server, but meh).
		sockaddr_un addr;
		addr.sun_family = AF_UNIX;
		version(linux) {
			// on linux, we will use the abstract namespace
			addr.sun_path[0] = 0;
			addr.sun_path[1 .. name.length + 1] = cast(typeof(addr.sun_path[])) name[];
		} else {
			// but otherwise, just use a file cuz we must.
			addr.sun_path[0 .. name.length] = cast(typeof(addr.sun_path[])) name[];
		}

		bool alreadyTried;

		try_again:

		if(connect(sock, cast(sockaddr*) &addr, addr.sizeof) == -1) {
			if(!alreadyTried && errno == ECONNREFUSED) {
				// try auto-spawning the server, then attempt connection again
				startAddonServer(arg);
				import core.thread;
				Thread.sleep(50.msecs);
				alreadyTried = true;
				goto try_again;
			} else
				throw new Exception("connect " ~ to!string(errno));
		}

		return sock;
	} else version(Windows) {
		return null; // FIXME
	}
}

version(with_addon_servers_connections)
void closeLocalServerConnection(LocalServerConnectionHandle handle) {
	version(Posix) {
		import core.sys.posix.unistd;
		close(handle);
	} else version(Windows)
		CloseHandle(handle);
}

void runSessionServer()() {
	runAddonServer("/tmp/arsd_session_server", new BasicDataServerImplementation());
}

version(Posix)
private void makeNonBlocking(int fd) {
	import core.sys.posix.fcntl;
	auto flags = fcntl(fd, F_GETFL, 0);
	if(flags == -1)
		throw new Exception("fcntl get");
	flags |= O_NONBLOCK;
	auto s = fcntl(fd, F_SETFL, flags);
	if(s == -1)
		throw new Exception("fcntl set");
}

import core.stdc.errno;

struct IoOp {
	@disable this();
	@disable this(this);

	/*
		So we want to be able to eventually handle generic sockets too.
	*/

	enum Read = 1;
	enum Write = 2;
	enum Accept = 3;
	enum ReadSocketHandle = 4;

	// Your handler may be called in a different thread than the one that initiated the IO request!
	// It is also possible to have multiple io requests being called simultaneously. Use proper thread safety caution.
	private bool delegate(IoOp*, int) handler; // returns true if you are done and want it to be closed
	private void delegate(IoOp*) closeHandler;
	private void delegate(IoOp*) completeHandler;
	private int internalFd;
	private int operation;
	private int bufferLengthAllocated;
	private int bufferLengthUsed;
	private ubyte[1] internalBuffer; // it can be overallocated!

	ubyte[] allocatedBuffer() return {
		return internalBuffer.ptr[0 .. bufferLengthAllocated];
	}

	ubyte[] usedBuffer() return {
		return allocatedBuffer[0 .. bufferLengthUsed];
	}

	void reset() {
		bufferLengthUsed = 0;
	}

	int fd() {
		return internalFd;
	}
}

IoOp* allocateIoOp(int fd, int operation, int bufferSize, bool delegate(IoOp*, int) handler) {
	import core.stdc.stdlib;

	auto ptr = calloc(IoOp.sizeof + bufferSize, 1);
	if(ptr is null)
		assert(0); // out of memory!

	auto op = cast(IoOp*) ptr;

	op.handler = handler;
	op.internalFd = fd;
	op.operation = operation;
	op.bufferLengthAllocated = bufferSize;
	op.bufferLengthUsed = 0;

	import core.memory;

	GC.addRoot(ptr);

	return op;
}

void freeIoOp(ref IoOp* ptr) {

	import core.memory;
	GC.removeRoot(ptr);

	import core.stdc.stdlib;
	free(ptr);
	ptr = null;
}

version(Posix)
version(with_addon_servers_connections)
void nonBlockingWrite(EventIoServer eis, int connection, const void[] data) {

	//import std.stdio : writeln; writeln(cast(string) data);

	import core.sys.posix.unistd;

	auto ret = write(connection, data.ptr, data.length);
	if(ret != data.length) {
		if(ret == 0 || (ret == -1 && (errno == EPIPE || errno == ETIMEDOUT))) {
			// the file is closed, remove it
			eis.fileClosed(connection);
		} else
			throw new Exception("alas " ~ to!string(ret) ~ " " ~ to!string(errno)); // FIXME
	}
}
version(Windows)
version(with_addon_servers_connections)
void nonBlockingWrite(EventIoServer eis, int connection, const void[] data) {
	// FIXME
}

bool isInvalidHandle(CgiConnectionHandle h) {
	return h == INVALID_CGI_CONNECTION_HANDLE;
}

/+
https://docs.microsoft.com/en-us/windows/desktop/api/winsock2/nf-winsock2-wsarecv
https://support.microsoft.com/en-gb/help/181611/socket-overlapped-i-o-versus-blocking-nonblocking-mode
https://stackoverflow.com/questions/18018489/should-i-use-iocps-or-overlapped-wsasend-receive
https://docs.microsoft.com/en-us/windows/desktop/fileio/i-o-completion-ports
https://docs.microsoft.com/en-us/windows/desktop/fileio/createiocompletionport
https://docs.microsoft.com/en-us/windows/desktop/api/mswsock/nf-mswsock-acceptex
https://docs.microsoft.com/en-us/windows/desktop/Sync/waitable-timer-objects
https://docs.microsoft.com/en-us/windows/desktop/api/synchapi/nf-synchapi-setwaitabletimer
https://docs.microsoft.com/en-us/windows/desktop/Sync/using-a-waitable-timer-with-an-asynchronous-procedure-call
https://docs.microsoft.com/en-us/windows/desktop/api/winsock2/nf-winsock2-wsagetoverlappedresult

+/

/++
	You can customize your server by subclassing the appropriate server. Then, register your
	subclass at compile time with the [registerEventIoServer] template, or implement your own
	main function and call it yourself.

	$(TIP If you make your subclass a `final class`, there is a slight performance improvement.)
+/
version(with_addon_servers_connections)
interface EventIoServer {
	bool handleLocalConnectionData(IoOp* op, int receivedFd);
	void handleLocalConnectionClose(IoOp* op);
	void handleLocalConnectionComplete(IoOp* op);
	void wait_timeout();
	void fileClosed(int fd);

	void epoll_fd(int fd);
}

// the sink should buffer it
private void serialize(T)(scope void delegate(scope ubyte[]) sink, T t) {
	static if(is(T == struct)) {
		foreach(member; __traits(allMembers, T))
			serialize(sink, __traits(getMember, t, member));
	} else static if(is(T : int)) {
		// no need to think of endianness just because this is only used
		// for local, same-machine stuff anyway. thanks private lol
		sink((cast(ubyte*) &t)[0 .. t.sizeof]);
	} else static if(is(T == string) || is(T : const(ubyte)[])) {
		// these are common enough to optimize
		int len = cast(int) t.length; // want length consistent size tho, in case 32 bit program sends to 64 bit server, etc.
		sink((cast(ubyte*) &len)[0 .. int.sizeof]);
		sink(cast(ubyte[]) t[]);
	} else static if(is(T : A[], A)) {
		// generic array is less optimal but still prolly ok
		int len = cast(int) t.length;
		sink((cast(ubyte*) &len)[0 .. int.sizeof]);
		foreach(item; t)
			serialize(sink, item);
	} else static assert(0, T.stringof);
}

// all may be stack buffers, so use cautio
private void deserialize(T)(scope ubyte[] delegate(int sz) get, scope void delegate(T) dg) {
	static if(is(T == struct)) {
		T t;
		foreach(member; __traits(allMembers, T))
			deserialize!(typeof(__traits(getMember, T, member)))(get, (mbr) { __traits(getMember, t, member) = mbr; });
		dg(t);
	} else static if(is(T : int)) {
		// no need to think of endianness just because this is only used
		// for local, same-machine stuff anyway. thanks private lol
		T t;
		auto data = get(t.sizeof);
		t = (cast(T[]) data)[0];
		dg(t);
	} else static if(is(T == string) || is(T : const(ubyte)[])) {
		// these are common enough to optimize
		int len;
		auto data = get(len.sizeof);
		len = (cast(int[]) data)[0];

		/*
		typeof(T[0])[2000] stackBuffer;
		T buffer;

		if(len < stackBuffer.length)
			buffer = stackBuffer[0 .. len];
		else
			buffer = new T(len);

		data = get(len * typeof(T[0]).sizeof);
		*/

		T t = cast(T) get(len * cast(int) typeof(T.init[0]).sizeof);

		dg(t);
	} else static if(is(T == E[], E)) {
		T t;
		int len;
		auto data = get(len.sizeof);
		len = (cast(int[]) data)[0];
		t.length = len;
		foreach(ref e; t) {
			deserialize!E(get, (ele) { e = ele; });
		}
		dg(t);
	} else static assert(0, T.stringof);
}

unittest {
	serialize((ubyte[] b) {
		deserialize!int( sz => b[0 .. sz], (t) { assert(t == 1); });
	}, 1);
	serialize((ubyte[] b) {
		deserialize!int( sz => b[0 .. sz], (t) { assert(t == 56674); });
	}, 56674);
	ubyte[1000] buffer;
	int bufferPoint;
	void add(ubyte[] b) {
		buffer[bufferPoint ..  bufferPoint + b.length] = b[];
		bufferPoint += b.length;
	}
	ubyte[] get(int sz) {
		auto b = buffer[bufferPoint .. bufferPoint + sz];
		bufferPoint += sz;
		return b;
	}
	serialize(&add, "test here");
	bufferPoint = 0;
	deserialize!string(&get, (t) { assert(t == "test here"); });
	bufferPoint = 0;

	struct Foo {
		int a;
		ubyte c;
		string d;
	}
	serialize(&add, Foo(403, 37, "amazing"));
	bufferPoint = 0;
	deserialize!Foo(&get, (t) {
		assert(t.a == 403);
		assert(t.c == 37);
		assert(t.d == "amazing");
	});
	bufferPoint = 0;
}

/*
	Here's the way the RPC interface works:

	You define the interface that lists the functions you can call on the remote process.
	The interface may also have static methods for convenience. These forward to a singleton
	instance of an auto-generated class, which actually sends the args over the pipe.

	An impl class actually implements it. A receiving server deserializes down the pipe and
	calls methods on the class.

	I went with the interface to get some nice compiler checking and documentation stuff.

	I could have skipped the interface and just implemented it all from the server class definition
	itself, but then the usage may call the method instead of rpcing it; I just like having the user
	interface and the implementation separate so you aren't tempted to `new impl` to call the methods.


	I fiddled with newlines in the mixin string to ensure the assert line numbers matched up to the source code line number. Idk why dmd didn't do this automatically, but it was important to me.

	Realistically though the bodies would just be
		connection.call(this.mangleof, args...) sooooo.

	FIXME: overloads aren't supported
*/

/// Base for storing sessions in an array. Exists primarily for internal purposes and you should generally not use this.
interface SessionObject {}

private immutable void delegate(string[])[string] scheduledJobHandlers;
private immutable void delegate(string[])[string] websocketServers;

version(with_breaking_cgi_features)
mixin(q{

mixin template ImplementRpcClientInterface(T, string serverPath, string cmdArg) {
	static import std.traits;

	// derivedMembers on an interface seems to give exactly what I want: the virtual functions we need to implement. so I am just going to use it directly without more filtering.
	static foreach(idx, member; __traits(derivedMembers, T)) {
	static if(__traits(isVirtualFunction, __traits(getMember, T, member)))
		mixin( q{
		std.traits.ReturnType!(__traits(getMember, T, member))
		} ~ member ~ q{(std.traits.Parameters!(__traits(getMember, T, member)) params)
		{
			SerializationBuffer buffer;
			auto i = cast(ushort) idx;
			serialize(&buffer.sink, i);
			serialize(&buffer.sink, __traits(getMember, T, member).mangleof);
			foreach(param; params)
				serialize(&buffer.sink, param);

			auto sendable = buffer.sendable;

			version(Posix) {{
				auto ret = send(connectionHandle, sendable.ptr, sendable.length, 0);

				if(ret == -1) {
					throw new Exception("send returned -1, errno: " ~ to!string(errno));
				} else if(ret == 0) {
					throw new Exception("Connection to addon server lost");
				} if(ret < sendable.length)
					throw new Exception("Send failed to send all");
				assert(ret == sendable.length);
			}} // FIXME Windows impl

			static if(!is(typeof(return) == void)) {
				// there is a return value; we need to wait for it too
				version(Posix) {
					ubyte[3000] revBuffer;
					auto ret = recv(connectionHandle, revBuffer.ptr, revBuffer.length, 0);
					auto got = revBuffer[0 .. ret];

					int dataLocation;
					ubyte[] grab(int sz) {
						auto dataLocation1 = dataLocation;
						dataLocation += sz;
						return got[dataLocation1 .. dataLocation];
					}

					typeof(return) retu;
					deserialize!(typeof(return))(&grab, (a) { retu = a; });
					return retu;
				} else {
					// FIXME Windows impl
					return typeof(return).init;
				}

			}
		}});
	}

	private static typeof(this) singletonInstance;
	private LocalServerConnectionHandle connectionHandle;

	static typeof(this) connection() {
		if(singletonInstance is null) {
			singletonInstance = new typeof(this)();
			singletonInstance.connect();
		}
		return singletonInstance;
	}

	void connect() {
		connectionHandle = openLocalServerConnection(serverPath, cmdArg);
	}

	void disconnect() {
		closeLocalServerConnection(connectionHandle);
	}
}

void dispatchRpcServer(Interface, Class)(Class this_, ubyte[] data, int fd) if(is(Class : Interface)) {
	ushort calledIdx;
	string calledFunction;

	int dataLocation;
	ubyte[] grab(int sz) {
		if(sz == 0) assert(0);
		auto d = data[dataLocation .. dataLocation + sz];
		dataLocation += sz;
		return d;
	}

	again:

	deserialize!ushort(&grab, (a) { calledIdx = a; });
	deserialize!string(&grab, (a) { calledFunction = a; });

	import std.traits;

	sw: switch(calledIdx) {
		foreach(idx, memberName; __traits(derivedMembers, Interface))
		static if(__traits(isVirtualFunction, __traits(getMember, Interface, memberName))) {
			case idx:
				assert(calledFunction == __traits(getMember, Interface, memberName).mangleof);

				Parameters!(__traits(getMember, Interface, memberName)) params;
				foreach(ref param; params)
					deserialize!(typeof(param))(&grab, (a) { param = a; });

				static if(is(ReturnType!(__traits(getMember, Interface, memberName)) == void)) {
					__traits(getMember, this_, memberName)(params);
				} else {
					auto ret = __traits(getMember, this_, memberName)(params);
					SerializationBuffer buffer;
					serialize(&buffer.sink, ret);

					auto sendable = buffer.sendable;

					version(Posix) {
						auto r = send(fd, sendable.ptr, sendable.length, 0);
						if(r == -1) {
							throw new Exception("send returned -1, errno: " ~ to!string(errno));
						} else if(r == 0) {
							throw new Exception("Connection to addon client lost");
						} if(r < sendable.length)
							throw new Exception("Send failed to send all");

					} // FIXME Windows impl
				}
			break sw;
		}
		default: assert(0);
	}

	if(dataLocation != data.length)
		goto again;
}


private struct SerializationBuffer {
	ubyte[2048] bufferBacking;
	int bufferLocation;
	void sink(scope ubyte[] data) {
		bufferBacking[bufferLocation .. bufferLocation + data.length] = data[];
		bufferLocation += data.length;
	}

	ubyte[] sendable() return {
		return bufferBacking[0 .. bufferLocation];
	}
}

/*
	FIXME:
		add a version command line arg
		version data in the library
		management gui as external program

		at server with event_fd for each run
		use .mangleof in the at function name

		i think the at server will have to:
			pipe args to the child
			collect child output for logging
			get child return value for logging

			on windows timers work differently. idk how to best combine with the io stuff.

			will have to have dump and restore too, so i can restart without losing stuff.
*/

/++
	A convenience object for talking to the [BasicDataServer] from a higher level.
	See: [Cgi.getSessionObject].

	You pass it a `Data` struct describing the data you want saved in the session.
	Then, this class will generate getter and setter properties that allow access
	to that data.

	Note that each load and store will be done as-accessed; it doesn't front-load
	mutable data nor does it batch updates out of fear of read-modify-write race
	conditions. (In fact, right now it does this for everything, but in the future,
	I might batch load `immutable` members of the Data struct.)

	At some point in the future, I might also let it do different backends, like
	a client-side cookie store too, but idk.

	Note that the plain-old-data members of your `Data` struct are wrapped by this
	interface via a static foreach to make property functions.

	See_Also: [MockSession]
+/
interface Session(Data) : SessionObject {
	@property string sessionId() const;

	/++
		Starts a new session. Note that a session is also
		implicitly started as soon as you write data to it,
		so if you need to alter these parameters from their
		defaults, be sure to explicitly call this BEFORE doing
		any writes to session data.

		Params:
			idleLifetime = How long, in seconds, the session
			should remain in memory when not being read from
			or written to. The default is one day.

			NOT IMPLEMENTED

			useExtendedLifetimeCookie = The session ID is always
			stored in a HTTP cookie, and by default, that cookie
			is discarded when the user closes their browser.

			But if you set this to true, it will use a non-perishable
			cookie for the given idleLifetime.

			NOT IMPLEMENTED
	+/
	void start(int idleLifetime = 2600 * 24, bool useExtendedLifetimeCookie = false);

	/++
		Regenerates the session ID and updates the associated
		cookie.

		This is also your chance to change immutable data
		(not yet implemented).
	+/
	void regenerateId();

	/++
		Terminates this session, deleting all saved data.
	+/
	void terminate();

	/++
		Plain-old-data members of your `Data` struct are wrapped here via
		the property getters and setters.

		If the member is a non-string array, it returns a magical array proxy
		object which allows for atomic appends and replaces via overloaded operators.
		You can slice this to get a range representing a $(B const) view of the array.
		This is to protect you against read-modify-write race conditions.
	+/
	static foreach(memberName; __traits(allMembers, Data))
		static if(is(typeof(__traits(getMember, Data, memberName))))
		mixin(q{
			@property inout(typeof(__traits(getMember, Data, memberName))) } ~ memberName ~ q{ () inout;
			@property typeof(__traits(getMember, Data, memberName)) } ~ memberName ~ q{ (typeof(__traits(getMember, Data, memberName)) value);
		});

}

/++
	An implementation of [Session] that works on real cgi connections utilizing the
	[BasicDataServer].

	As opposed to a [MockSession] which is made for testing purposes.

	You will not construct one of these directly. See [Cgi.getSessionObject] instead.
+/
class BasicDataServerSession(Data) : Session!Data {
	private Cgi cgi;
	private string sessionId_;

	public @property string sessionId() const {
		return sessionId_;
	}

	protected @property string sessionId(string s) {
		return this.sessionId_ = s;
	}

	private this(Cgi cgi) {
		this.cgi = cgi;
		if(auto ptr = "sessionId" in cgi.cookies)
			sessionId = (*ptr).length ? *ptr : null;
	}

	void start(int idleLifetime = 2600 * 24, bool useExtendedLifetimeCookie = false) {
		assert(sessionId is null);

		// FIXME: what if there is a session ID cookie, but no corresponding session on the server?

		import std.random, std.conv;
		sessionId = to!string(uniform(1, long.max));

		BasicDataServer.connection.createSession(sessionId, idleLifetime);
		setCookie();
	}

	protected void setCookie() {
		cgi.setCookie(
			"sessionId", sessionId,
			0 /* expiration */,
			"/" /* path */,
			null /* domain */,
			true /* http only */,
			cgi.https /* if the session is started on https, keep it there, otherwise, be flexible */);
	}

	void regenerateId() {
		if(sessionId is null) {
			start();
			return;
		}
		import std.random, std.conv;
		auto oldSessionId = sessionId;
		sessionId = to!string(uniform(1, long.max));
		BasicDataServer.connection.renameSession(oldSessionId, sessionId);
		setCookie();
	}

	void terminate() {
		BasicDataServer.connection.destroySession(sessionId);
		sessionId = null;
		setCookie();
	}

	static foreach(memberName; __traits(allMembers, Data))
		static if(is(typeof(__traits(getMember, Data, memberName))))
		mixin(q{
			@property inout(typeof(__traits(getMember, Data, memberName))) } ~ memberName ~ q{ () inout {
				if(sessionId is null)
					return typeof(return).init;

				import std.traits;
				auto v = BasicDataServer.connection.getSessionData(sessionId, fullyQualifiedName!Data ~ "." ~ memberName);
				if(v.length == 0)
					return typeof(return).init;
				import std.conv;
				// why this cast? to doesn't like being given an inout argument. so need to do it without that, then
				// we need to return it and that needed the cast. It should be fine since we basically respect constness..
				// basically. Assuming the session is POD this should be fine.
				return cast(typeof(return)) to!(typeof(__traits(getMember, Data, memberName)))(v);
			}
			@property typeof(__traits(getMember, Data, memberName)) } ~ memberName ~ q{ (typeof(__traits(getMember, Data, memberName)) value) {
				if(sessionId is null)
					start();
				import std.conv;
				import std.traits;
				BasicDataServer.connection.setSessionData(sessionId, fullyQualifiedName!Data ~ "." ~ memberName, to!string(value));
				return value;
			}
		});
}

/++
	A mock object that works like the real session, but doesn't actually interact with any actual database or http connection.
	Simply stores the data in its instance members.
+/
class MockSession(Data) : Session!Data {
	pure {
		@property string sessionId() const { return "mock"; }
		void start(int idleLifetime = 2600 * 24, bool useExtendedLifetimeCookie = false) {}
		void regenerateId() {}
		void terminate() {}

		private Data store_;

		static foreach(memberName; __traits(allMembers, Data))
			static if(is(typeof(__traits(getMember, Data, memberName))))
			mixin(q{
				@property inout(typeof(__traits(getMember, Data, memberName))) } ~ memberName ~ q{ () inout {
					return __traits(getMember, store_, memberName);
				}
				@property typeof(__traits(getMember, Data, memberName)) } ~ memberName ~ q{ (typeof(__traits(getMember, Data, memberName)) value) {
					return __traits(getMember, store_, memberName) = value;
				}
			});
	}
}

/++
	Direct interface to the basic data add-on server. You can
	typically use [Cgi.getSessionObject] as a more convenient interface.
+/
version(with_addon_servers_connections)
interface BasicDataServer {
	///
	void createSession(string sessionId, int lifetime);
	///
	void renewSession(string sessionId, int lifetime);
	///
	void destroySession(string sessionId);
	///
	void renameSession(string oldSessionId, string newSessionId);

	///
	void setSessionData(string sessionId, string dataKey, string dataValue);
	///
	string getSessionData(string sessionId, string dataKey);

	///
	static BasicDataServerConnection connection() {
		return BasicDataServerConnection.connection();
	}
}

version(with_addon_servers_connections)
class BasicDataServerConnection : BasicDataServer {
	mixin ImplementRpcClientInterface!(BasicDataServer, "/tmp/arsd_session_server", "--session-server");
}

version(with_addon_servers)
final class BasicDataServerImplementation : BasicDataServer, EventIoServer {

	void createSession(string sessionId, int lifetime) {
		sessions[sessionId.idup] = Session(lifetime);
	}
	void destroySession(string sessionId) {
		sessions.remove(sessionId);
	}
	void renewSession(string sessionId, int lifetime) {
		sessions[sessionId].lifetime = lifetime;
	}
	void renameSession(string oldSessionId, string newSessionId) {
		sessions[newSessionId.idup] = sessions[oldSessionId];
		sessions.remove(oldSessionId);
	}
	void setSessionData(string sessionId, string dataKey, string dataValue) {
		if(sessionId !in sessions)
			createSession(sessionId, 3600); // FIXME?
		sessions[sessionId].values[dataKey.idup] = dataValue.idup;
	}
	string getSessionData(string sessionId, string dataKey) {
		if(auto session = sessionId in sessions) {
			if(auto data = dataKey in (*session).values)
				return *data;
			else
				return null; // no such data

		} else {
			return null; // no session
		}
	}


	protected:

	struct Session {
		int lifetime;

		string[string] values;
	}

	Session[string] sessions;

	bool handleLocalConnectionData(IoOp* op, int receivedFd) {
		auto data = op.usedBuffer;
		dispatchRpcServer!BasicDataServer(this, data, op.fd);
		return false;
	}

	void handleLocalConnectionClose(IoOp* op) {} // doesn't really matter, this is a fairly stateless go
	void handleLocalConnectionComplete(IoOp* op) {} // again, irrelevant
	void wait_timeout() {}
	void fileClosed(int fd) {} // stateless so irrelevant
	void epoll_fd(int fd) {}
}

/++
	See [schedule] to make one of these. You then call one of the methods here to set it up:

	---
		schedule!fn(args).at(DateTime(2019, 8, 7, 12, 00, 00)); // run the function at August 7, 2019, 12 noon UTC
		schedule!fn(args).delay(6.seconds); // run it after waiting 6 seconds
		schedule!fn(args).asap(); // run it in the background as soon as the event loop gets around to it
	---
+/
version(with_addon_servers_connections)
struct ScheduledJobHelper {
	private string func;
	private string[] args;
	private bool consumed;

	private this(string func, string[] args) {
		this.func = func;
		this.args = args;
	}

	~this() {
		assert(consumed);
	}

	/++
		Schedules the job to be run at the given time.
	+/
	void at(DateTime when, immutable TimeZone timezone = UTC()) {
		consumed = true;

		auto conn = ScheduledJobServerConnection.connection;
		import std.file;
		auto st = SysTime(when, timezone);
		auto jobId = conn.scheduleJob(1, cast(int) st.toUnixTime(), thisExePath, func, args);
	}

	/++
		Schedules the job to run at least after the specified delay.
	+/
	void delay(Duration delay) {
		consumed = true;

		auto conn = ScheduledJobServerConnection.connection;
		import std.file;
		auto jobId = conn.scheduleJob(0, cast(int) delay.total!"seconds", thisExePath, func, args);
	}

	/++
		Runs the job in the background ASAP.

		$(NOTE It may run in a background thread. Don't segfault!)
	+/
	void asap() {
		consumed = true;

		auto conn = ScheduledJobServerConnection.connection;
		import std.file;
		auto jobId = conn.scheduleJob(0, 1, thisExePath, func, args);
	}

	/+
	/++
		Schedules the job to recur on the given pattern.
	+/
	void recur(string spec) {

	}
	+/
}

/++
	First step to schedule a job on the scheduled job server.

	The scheduled job needs to be a top-level function that doesn't read any
	variables from outside its arguments because it may be run in a new process,
	without any context existing later.

	You MUST set details on the returned object to actually do anything!
+/
template schedule(alias fn, T...) if(is(typeof(fn) == function)) {
	///
	ScheduledJobHelper schedule(T args) {
		// this isn't meant to ever be called, but instead just to
		// get the compiler to type check the arguments passed for us
		auto sample = delegate() {
			fn(args);
		};
		string[] sargs;
		foreach(arg; args)
			sargs ~= to!string(arg);
		return ScheduledJobHelper(fn.mangleof, sargs);
	}

	shared static this() {
		scheduledJobHandlers[fn.mangleof] = delegate(string[] sargs) {
			import std.traits;
			Parameters!fn args;
			foreach(idx, ref arg; args)
				arg = to!(typeof(arg))(sargs[idx]);
			fn(args);
		};
	}
}

///
interface ScheduledJobServer {
	/// Use the [schedule] function for a higher-level interface.
	int scheduleJob(int whenIs, int when, string executable, string func, string[] args);
	///
	void cancelJob(int jobId);
}

version(with_addon_servers_connections)
class ScheduledJobServerConnection : ScheduledJobServer {
	mixin ImplementRpcClientInterface!(ScheduledJobServer, "/tmp/arsd_scheduled_job_server", "--timer-server");
}

version(with_addon_servers)
final class ScheduledJobServerImplementation : ScheduledJobServer, EventIoServer {
	// FIXME: we need to handle SIGCHLD in this somehow
	// whenIs is 0 for relative, 1 for absolute
	protected int scheduleJob(int whenIs, int when, string executable, string func, string[] args) {
		auto nj = nextJobId;
		nextJobId++;

		version(linux) {
			import core.sys.linux.timerfd;
			import core.sys.linux.epoll;
			import core.sys.posix.unistd;


			auto fd = timerfd_create(CLOCK_REALTIME, TFD_NONBLOCK | TFD_CLOEXEC);
			if(fd == -1)
				throw new Exception("fd timer create failed");

			foreach(ref arg; args)
				arg = arg.idup;
			auto job = Job(executable.idup, func.idup, .dup(args), fd, nj);

			itimerspec value;
			value.it_value.tv_sec = when;
			value.it_value.tv_nsec = 0;

			value.it_interval.tv_sec = 0;
			value.it_interval.tv_nsec = 0;

			if(timerfd_settime(fd, whenIs == 1 ? TFD_TIMER_ABSTIME : 0, &value, null) == -1)
				throw new Exception("couldn't set fd timer");

			auto op = allocateIoOp(fd, IoOp.Read, 16, (IoOp* op, int fd) {
				jobs.remove(nj);
				epoll_ctl(epoll_fd, EPOLL_CTL_DEL, fd, null);
				close(fd);


				spawnProcess([job.executable, "--timed-job", job.func] ~ job.args);

				return true;
			});
			scope(failure)
				freeIoOp(op);

			epoll_event ev;
			ev.events = EPOLLIN | EPOLLET;
			ev.data.ptr = op;
			if(epoll_ctl(epoll_fd, EPOLL_CTL_ADD, fd, &ev) == -1)
				throw new Exception("epoll_ctl " ~ to!string(errno));

			jobs[nj] = job;
			return nj;
		} else assert(0);
	}

	protected void cancelJob(int jobId) {
		version(linux) {
			auto job = jobId in jobs;
			if(job is null)
				return;

			jobs.remove(jobId);

			version(linux) {
				import core.sys.linux.timerfd;
				import core.sys.linux.epoll;
				import core.sys.posix.unistd;
				epoll_ctl(epoll_fd, EPOLL_CTL_DEL, job.timerfd, null);
				close(job.timerfd);
			}
		}
		jobs.remove(jobId);
	}

	int nextJobId = 1;
	static struct Job {
		string executable;
		string func;
		string[] args;
		int timerfd;
		int id;
	}
	Job[int] jobs;


	// event io server methods below

	bool handleLocalConnectionData(IoOp* op, int receivedFd) {
		auto data = op.usedBuffer;
		dispatchRpcServer!ScheduledJobServer(this, data, op.fd);
		return false;
	}

	void handleLocalConnectionClose(IoOp* op) {} // doesn't really matter, this is a fairly stateless go
	void handleLocalConnectionComplete(IoOp* op) {} // again, irrelevant
	void wait_timeout() {}
	void fileClosed(int fd) {} // stateless so irrelevant

	int epoll_fd_;
	void epoll_fd(int fd) {this.epoll_fd_ = fd; }
	int epoll_fd() { return epoll_fd_; }
}

///
version(with_addon_servers_connections)
interface EventSourceServer {
	/++
		sends this cgi request to the event server so it will be fed events. You should not do anything else with the cgi object after this.

		$(WARNING This API is extremely unstable. I might change it or remove it without notice.)

		See_Also:
			[sendEvent]
	+/
	public static void adoptConnection(Cgi cgi, in char[] eventUrl) {
		/*
			If lastEventId is missing or empty, you just get new events as they come.

			If it is set from something else, it sends all since then (that are still alive)
			down the pipe immediately.

			The reason it can come from the header is that's what the standard defines for
			browser reconnects. The reason it can come from a query string is just convenience
			in catching up in a user-defined manner.

			The reason the header overrides the query string is if the browser tries to reconnect,
			it will send the header AND the query (it reconnects to the same url), so we just
			want to do the restart thing.

			Note that if you ask for "0" as the lastEventId, it will get ALL still living events.
		*/
		string lastEventId = cgi.lastEventId;
		if(lastEventId.length == 0 && "lastEventId" in cgi.get)
			lastEventId = cgi.get["lastEventId"];

		cgi.setResponseContentType("text/event-stream");
		cgi.write(":\n", false); // to initialize the chunking and send headers before keeping the fd for later
		cgi.flush();

		cgi.closed = true;
		auto s = openLocalServerConnection("/tmp/arsd_cgi_event_server", "--event-server");
		scope(exit)
			closeLocalServerConnection(s);

		version(fastcgi)
			throw new Exception("sending fcgi connections not supported");
		else {
			auto fd = cgi.getOutputFileHandle();
			if(isInvalidHandle(fd))
				throw new Exception("bad fd from cgi!");

			EventSourceServerImplementation.SendableEventConnection sec;
			sec.populate(cgi.responseChunked, eventUrl, lastEventId);

			version(Posix) {
				auto res = write_fd(s, cast(void*) &sec, sec.sizeof, fd);
				assert(res == sec.sizeof);
			} else version(Windows) {
				// FIXME
			}
		}
	}

	/++
		Sends an event to the event server, starting it if necessary. The event server will distribute it to any listening clients, and store it for `lifetime` seconds for any later listening clients to catch up later.

		$(WARNING This API is extremely unstable. I might change it or remove it without notice.)

		Params:
			url = A string identifying this event "bucket". Listening clients must also connect to this same string. I called it `url` because I envision it being just passed as the url of the request.
			event = the event type string, which is used in the Javascript addEventListener API on EventSource
			data = the event data. Available in JS as `event.data`.
			lifetime = the amount of time to keep this event for replaying on the event server.

		See_Also:
			[sendEventToEventServer]
	+/
	public static void sendEvent(string url, string event, string data, int lifetime) {
		auto s = openLocalServerConnection("/tmp/arsd_cgi_event_server", "--event-server");
		scope(exit)
			closeLocalServerConnection(s);

		EventSourceServerImplementation.SendableEvent sev;
		sev.populate(url, event, data, lifetime);

		version(Posix) {
			auto ret = send(s, &sev, sev.sizeof, 0);
			assert(ret == sev.sizeof);
		} else version(Windows) {
			// FIXME
		}
	}

	/++
		Messages sent to `url` will also be sent to anyone listening on `forwardUrl`.

		See_Also: [disconnect]
	+/
	void connect(string url, string forwardUrl);

	/++
		Disconnects `forwardUrl` from `url`

		See_Also: [connect]
	+/
	void disconnect(string url, string forwardUrl);
}

///
version(with_addon_servers)
final class EventSourceServerImplementation : EventSourceServer, EventIoServer {

	protected:

	void connect(string url, string forwardUrl) {
		pipes[url] ~= forwardUrl;
	}
	void disconnect(string url, string forwardUrl) {
		auto t = url in pipes;
		if(t is null)
			return;
		foreach(idx, n; (*t))
			if(n == forwardUrl) {
				(*t)[idx] = (*t)[$-1];
				(*t) = (*t)[0 .. $-1];
				break;
			}
	}

	bool handleLocalConnectionData(IoOp* op, int receivedFd) {
		if(receivedFd != -1) {
			//writeln("GOT FD ", receivedFd, " -- ", op.usedBuffer);

			//core.sys.posix.unistd.write(receivedFd, "hello".ptr, 5);

			SendableEventConnection* got = cast(SendableEventConnection*) op.usedBuffer.ptr;

			auto url = got.url.idup;
			eventConnectionsByUrl[url] ~= EventConnection(receivedFd, got.responseChunked > 0 ? true : false);

			// FIXME: catch up on past messages here
		} else {
			auto data = op.usedBuffer;
			auto event = cast(SendableEvent*) data.ptr;

			if(event.magic == 0xdeadbeef) {
				handleInputEvent(event);

				if(event.url in pipes)
				foreach(pipe; pipes[event.url]) {
					event.url = pipe;
					handleInputEvent(event);
				}
			} else {
				dispatchRpcServer!EventSourceServer(this, data, op.fd);
			}
		}
		return false;
	}
	void handleLocalConnectionClose(IoOp* op) {
		fileClosed(op.fd);
	}
	void handleLocalConnectionComplete(IoOp* op) {}

	void wait_timeout() {
		// just keeping alive
		foreach(url, connections; eventConnectionsByUrl)
		foreach(connection; connections)
			if(connection.needsChunking)
				nonBlockingWrite(this, connection.fd, "1b\r\nevent: keepalive\ndata: ok\n\n\r\n");
			else
				nonBlockingWrite(this, connection.fd, "event: keepalive\ndata: ok\n\n\r\n");
	}

	void fileClosed(int fd) {
		outer: foreach(url, ref connections; eventConnectionsByUrl) {
			foreach(idx, conn; connections) {
				if(fd == conn.fd) {
					connections[idx] = connections[$-1];
					connections = connections[0 .. $ - 1];
					continue outer;
				}
			}
		}
	}

	void epoll_fd(int fd) {}


	private:


	struct SendableEventConnection {
		ubyte responseChunked;

		int urlLength;
		char[256] urlBuffer = 0;

		int lastEventIdLength;
		char[32] lastEventIdBuffer = 0;

		char[] url() return {
			return urlBuffer[0 .. urlLength];
		}
		void url(in char[] u) {
			urlBuffer[0 .. u.length] = u[];
			urlLength = cast(int) u.length;
		}
		char[] lastEventId() return {
			return lastEventIdBuffer[0 .. lastEventIdLength];
		}
		void populate(bool responseChunked, in char[] url, in char[] lastEventId)
		in {
			assert(url.length < this.urlBuffer.length);
			assert(lastEventId.length < this.lastEventIdBuffer.length);
		}
		do {
			this.responseChunked = responseChunked ? 1 : 0;
			this.urlLength = cast(int) url.length;
			this.lastEventIdLength = cast(int) lastEventId.length;

			this.urlBuffer[0 .. url.length] = url[];
			this.lastEventIdBuffer[0 .. lastEventId.length] = lastEventId[];
		}
	}

	struct SendableEvent {
		int magic = 0xdeadbeef;
		int urlLength;
		char[256] urlBuffer = 0;
		int typeLength;
		char[32] typeBuffer = 0;
		int messageLength;
		char[2048 * 4] messageBuffer = 0; // this is an arbitrary limit, it needs to fit comfortably in stack (including in a fiber) and be a single send on the kernel side cuz of the impl... i think this is ok for a unix socket.
		int _lifetime;

		char[] message() return {
			return messageBuffer[0 .. messageLength];
		}
		char[] type() return {
			return typeBuffer[0 .. typeLength];
		}
		char[] url() return {
			return urlBuffer[0 .. urlLength];
		}
		void url(in char[] u) {
			urlBuffer[0 .. u.length] = u[];
			urlLength = cast(int) u.length;
		}
		int lifetime() {
			return _lifetime;
		}

		///
		void populate(string url, string type, string message, int lifetime)
		in {
			assert(url.length < this.urlBuffer.length);
			assert(type.length < this.typeBuffer.length);
			assert(message.length < this.messageBuffer.length);
		}
		do {
			this.urlLength = cast(int) url.length;
			this.typeLength = cast(int) type.length;
			this.messageLength = cast(int) message.length;
			this._lifetime = lifetime;

			this.urlBuffer[0 .. url.length] = url[];
			this.typeBuffer[0 .. type.length] = type[];
			this.messageBuffer[0 .. message.length] = message[];
		}
	}

	struct EventConnection {
		int fd;
		bool needsChunking;
	}

	private EventConnection[][string] eventConnectionsByUrl;
	private string[][string] pipes;

	private void handleInputEvent(scope SendableEvent* event) {
		static int eventId;

		static struct StoredEvent {
			int id;
			string type;
			string message;
			int lifetimeRemaining;
		}

		StoredEvent[][string] byUrl;

		int thisId = ++eventId;

		if(event.lifetime)
			byUrl[event.url.idup] ~= StoredEvent(thisId, event.type.idup, event.message.idup, event.lifetime);

		auto connectionsPtr = event.url in eventConnectionsByUrl;
		EventConnection[] connections;
		if(connectionsPtr is null)
			return;
		else
			connections = *connectionsPtr;

		char[4096] buffer;
		char[] formattedMessage;

		void append(const char[] a) {
			// the 6's here are to leave room for a HTTP chunk header, if it proves necessary
			buffer[6 + formattedMessage.length .. 6 + formattedMessage.length + a.length] = a[];
			formattedMessage = buffer[6 .. 6 + formattedMessage.length + a.length];
		}

		import std.algorithm.iteration;

		if(connections.length) {
			append("id: ");
			append(to!string(thisId));
			append("\n");

			append("event: ");
			append(event.type);
			append("\n");

			foreach(line; event.message.splitter("\n")) {
				append("data: ");
				append(line);
				append("\n");
			}

			append("\n");
		}

		// chunk it for HTTP!
		auto len = toHex(formattedMessage.length);
		buffer[4 .. 6] = "\r\n"[];
		buffer[4 - len.length .. 4] = len[];
		buffer[6 + formattedMessage.length] = '\r';
		buffer[6 + formattedMessage.length + 1] = '\n';

		auto chunkedMessage = buffer[4 - len.length .. 6 + formattedMessage.length +2];
		// done

		// FIXME: send back requests when needed
		// FIXME: send a single ":\n" every 15 seconds to keep alive

		foreach(connection; connections) {
			if(connection.needsChunking) {
				nonBlockingWrite(this, connection.fd, chunkedMessage);
			} else {
				nonBlockingWrite(this, connection.fd, formattedMessage);
			}
		}
	}
}

void runAddonServer(EIS)(string localListenerName, EIS eis) if(is(EIS : EventIoServer)) {
	version(Posix) {

		import core.sys.posix.unistd;
		import core.sys.posix.fcntl;
		import core.sys.posix.sys.un;

		import core.sys.posix.signal;
		signal(SIGPIPE, SIG_IGN);

		static extern(C) void sigchldhandler(int) {
			int status;
			import w = core.sys.posix.sys.wait;
			w.wait(&status);
		}
		signal(SIGCHLD, &sigchldhandler);

		int sock = socket(AF_UNIX, SOCK_STREAM, 0);
		if(sock == -1)
			throw new Exception("socket " ~ to!string(errno));

		scope(failure)
			close(sock);

		cloexec(sock);

		// add-on server processes are assumed to be local, and thus will
		// use unix domain sockets. Besides, I want to pass sockets to them,
		// so it basically must be local (except for the session server, but meh).
		sockaddr_un addr;
		addr.sun_family = AF_UNIX;
		version(linux) {
			// on linux, we will use the abstract namespace
			addr.sun_path[0] = 0;
			addr.sun_path[1 .. localListenerName.length + 1] = cast(typeof(addr.sun_path[])) localListenerName[];
		} else {
			// but otherwise, just use a file cuz we must.
			addr.sun_path[0 .. localListenerName.length] = cast(typeof(addr.sun_path[])) localListenerName[];
		}

		if(bind(sock, cast(sockaddr*) &addr, addr.sizeof) == -1)
			throw new Exception("bind " ~ to!string(errno));

		if(listen(sock, 128) == -1)
			throw new Exception("listen " ~ to!string(errno));

		makeNonBlocking(sock);

		version(linux) {
			import core.sys.linux.epoll;
			auto epoll_fd = epoll_create1(EPOLL_CLOEXEC);
			if(epoll_fd == -1)
				throw new Exception("epoll_create1 " ~ to!string(errno));
			scope(failure)
				close(epoll_fd);
		} else {
			import core.sys.posix.poll;
		}

		version(linux)
		eis.epoll_fd = epoll_fd;

		auto acceptOp = allocateIoOp(sock, IoOp.Read, 0, null);
		scope(exit)
			freeIoOp(acceptOp);

		version(linux) {
			epoll_event ev;
			ev.events = EPOLLIN | EPOLLET;
			ev.data.ptr = acceptOp;
			if(epoll_ctl(epoll_fd, EPOLL_CTL_ADD, sock, &ev) == -1)
				throw new Exception("epoll_ctl " ~ to!string(errno));

			epoll_event[64] events;
		} else {
			pollfd[] pollfds;
			IoOp*[int] ioops;
			pollfds ~= pollfd(sock, POLLIN);
			ioops[sock] = acceptOp;
		}

		import core.time : MonoTime, seconds;

		MonoTime timeout = MonoTime.currTime + 15.seconds;

		while(true) {

			// FIXME: it should actually do a timerfd that runs on any thing that hasn't been run recently

			int timeout_milliseconds = 0; //  -1; // infinite

			timeout_milliseconds = cast(int) (timeout - MonoTime.currTime).total!"msecs";
			if(timeout_milliseconds < 0)
				timeout_milliseconds = 0;

			//writeln("waiting for ", name);

			version(linux) {
				auto nfds = epoll_wait(epoll_fd, events.ptr, events.length, timeout_milliseconds);
				if(nfds == -1) {
					if(errno == EINTR)
						continue;
					throw new Exception("epoll_wait " ~ to!string(errno));
				}
			} else {
				int nfds = poll(pollfds.ptr, cast(int) pollfds.length, timeout_milliseconds);
				size_t lastIdx = 0;
			}

			if(nfds == 0) {
				eis.wait_timeout();
				timeout += 15.seconds;
			}

			foreach(idx; 0 .. nfds) {
				version(linux) {
					auto flags = events[idx].events;
					auto ioop = cast(IoOp*) events[idx].data.ptr;
				} else {
					IoOp* ioop;
					foreach(tidx, thing; pollfds[lastIdx .. $]) {
						if(thing.revents) {
							ioop = ioops[thing.fd];
							lastIdx += tidx + 1;
							break;
						}
					}
				}

				//writeln(flags, " ", ioop.fd);

				void newConnection() {
					// on edge triggering, it is important that we get it all
					while(true) {
						version(Android) {
							auto size = cast(int) addr.sizeof;
						} else {
							auto size = cast(uint) addr.sizeof;
						}
						auto ns = accept(sock, cast(sockaddr*) &addr, &size);
						if(ns == -1) {
							if(errno == EAGAIN || errno == EWOULDBLOCK) {
								// all done, got it all
								break;
							}
							throw new Exception("accept " ~ to!string(errno));
						}
						cloexec(ns);

						makeNonBlocking(ns);
						auto niop = allocateIoOp(ns, IoOp.ReadSocketHandle, 4096 * 4, &eis.handleLocalConnectionData);
						niop.closeHandler = &eis.handleLocalConnectionClose;
						niop.completeHandler = &eis.handleLocalConnectionComplete;
						scope(failure) freeIoOp(niop);

						version(linux) {
							epoll_event nev;
							nev.events = EPOLLIN | EPOLLET;
							nev.data.ptr = niop;
							if(epoll_ctl(epoll_fd, EPOLL_CTL_ADD, ns, &nev) == -1)
								throw new Exception("epoll_ctl " ~ to!string(errno));
						} else {
							bool found = false;
							foreach(ref pfd; pollfds) {
								if(pfd.fd < 0) {
									pfd.fd = ns;
									found = true;
								}
							}
							if(!found)
								pollfds ~= pollfd(ns, POLLIN);
							ioops[ns] = niop;
						}
					}
				}

				bool newConnectionCondition() {
					version(linux)
						return ioop.fd == sock && (flags & EPOLLIN);
					else
						return pollfds[idx].fd == sock && (pollfds[idx].revents & POLLIN);
				}

				if(newConnectionCondition()) {
					newConnection();
				} else if(ioop.operation == IoOp.ReadSocketHandle) {
					while(true) {
						int in_fd;
						auto got = read_fd(ioop.fd, ioop.allocatedBuffer.ptr, ioop.allocatedBuffer.length, &in_fd);
						if(got == -1) {
							if(errno == EAGAIN || errno == EWOULDBLOCK) {
								// all done, got it all
								if(ioop.completeHandler)
									ioop.completeHandler(ioop);
								break;
							}
							throw new Exception("recv " ~ to!string(errno));
						}

						if(got == 0) {
							if(ioop.closeHandler) {
								ioop.closeHandler(ioop);
								version(linux) {} // nothing needed
								else {
									foreach(ref pfd; pollfds) {
										if(pfd.fd == ioop.fd)
											pfd.fd = -1;
									}
								}
							}
							close(ioop.fd);
							freeIoOp(ioop);
							break;
						}

						ioop.bufferLengthUsed = cast(int) got;
						ioop.handler(ioop, in_fd);
					}
				} else if(ioop.operation == IoOp.Read) {
					while(true) {
						auto got = read(ioop.fd, ioop.allocatedBuffer.ptr, ioop.allocatedBuffer.length);
						if(got == -1) {
							if(errno == EAGAIN || errno == EWOULDBLOCK) {
								// all done, got it all
								if(ioop.completeHandler)
									ioop.completeHandler(ioop);
								break;
							}
							throw new Exception("recv " ~ to!string(ioop.fd) ~ " errno " ~ to!string(errno));
						}

						if(got == 0) {
							if(ioop.closeHandler)
								ioop.closeHandler(ioop);
							close(ioop.fd);
							freeIoOp(ioop);
							break;
						}

						ioop.bufferLengthUsed = cast(int) got;
						if(ioop.handler(ioop, ioop.fd)) {
							close(ioop.fd);
							freeIoOp(ioop);
							break;
						}
					}
				}

				// EPOLLHUP?
			}
		}
	} else version(Windows) {

		// set up a named pipe
		// https://msdn.microsoft.com/en-us/library/windows/desktop/ms724251(v=vs.85).aspx
		// https://docs.microsoft.com/en-us/windows/desktop/api/winsock2/nf-winsock2-wsaduplicatesocketw
		// https://docs.microsoft.com/en-us/windows/desktop/api/winbase/nf-winbase-getnamedpipeserverprocessid

	} else static assert(0);
}


version(with_sendfd)
// copied from the web and ported from C
// see https://stackoverflow.com/questions/2358684/can-i-share-a-file-descriptor-to-another-process-on-linux-or-are-they-local-to-t
ssize_t write_fd(int fd, void *ptr, size_t nbytes, int sendfd) {
	msghdr msg;
	iovec[1] iov;

	version(OSX) {
		//msg.msg_accrights = cast(cattr_t) &sendfd;
		//msg.msg_accrightslen = int.sizeof;
	} else version(Android) {
	} else {
		union ControlUnion {
			cmsghdr cm;
			char[CMSG_SPACE(int.sizeof)] control;
		}

		ControlUnion control_un;
		cmsghdr* cmptr;

		msg.msg_control = control_un.control.ptr;
		msg.msg_controllen = control_un.control.length;

		cmptr = CMSG_FIRSTHDR(&msg);
		cmptr.cmsg_len = CMSG_LEN(int.sizeof);
		cmptr.cmsg_level = SOL_SOCKET;
		cmptr.cmsg_type = SCM_RIGHTS;
		*(cast(int *) CMSG_DATA(cmptr)) = sendfd;
	}

	msg.msg_name = null;
	msg.msg_namelen = 0;

	iov[0].iov_base = ptr;
	iov[0].iov_len = nbytes;
	msg.msg_iov = iov.ptr;
	msg.msg_iovlen = 1;

	return sendmsg(fd, &msg, 0);
}

version(with_sendfd)
// copied from the web and ported from C
ssize_t read_fd(int fd, void *ptr, size_t nbytes, int *recvfd) {
	msghdr msg;
	iovec[1] iov;
	ssize_t n;
	int newfd;

	version(OSX) {
		//msg.msg_accrights = cast(cattr_t) recvfd;
		//msg.msg_accrightslen = int.sizeof;
	} else version(Android) {
	} else {
		union ControlUnion {
			cmsghdr cm;
			char[CMSG_SPACE(int.sizeof)] control;
		}
		ControlUnion control_un;
		cmsghdr* cmptr;

		msg.msg_control = control_un.control.ptr;
		msg.msg_controllen = control_un.control.length;
	}

	msg.msg_name = null;
	msg.msg_namelen = 0;

	iov[0].iov_base = ptr;
	iov[0].iov_len = nbytes;
	msg.msg_iov = iov.ptr;
	msg.msg_iovlen = 1;

	if ( (n = recvmsg(fd, &msg, 0)) <= 0)
		return n;

	version(OSX) {
		//if(msg.msg_accrightslen != int.sizeof)
			//*recvfd = -1;
	} else version(Android) {
	} else {
		if ( (cmptr = CMSG_FIRSTHDR(&msg)) != null &&
				cmptr.cmsg_len == CMSG_LEN(int.sizeof)) {
			if (cmptr.cmsg_level != SOL_SOCKET)
				throw new Exception("control level != SOL_SOCKET");
			if (cmptr.cmsg_type != SCM_RIGHTS)
				throw new Exception("control type != SCM_RIGHTS");
			*recvfd = *(cast(int *) CMSG_DATA(cmptr));
		} else
			*recvfd = -1;       /* descriptor was not passed */
	}

	return n;
}
/* end read_fd */


/*
	Event source stuff

	The api is:

	sendEvent(string url, string type, string data, int timeout = 60*10);

	attachEventListener(string url, int fd, lastId)


	It just sends to all attached listeners, and stores it until the timeout
	for replaying via lastEventId.
*/

/*
	Session process stuff

	it stores it all. the cgi object has a session object that can grab it

	session may be done in the same process if possible, there is a version
	switch to choose if you want to override.
*/

struct DispatcherDefinition(alias dispatchHandler, DispatcherDetails = typeof(null)) {// if(is(typeof(dispatchHandler("str", Cgi.init, void) == bool))) { // bool delegate(string urlPrefix, Cgi cgi) dispatchHandler;
	alias handler = dispatchHandler;
	string urlPrefix;
	bool rejectFurther;
	immutable(DispatcherDetails) details;
}

private string urlify(string name) pure {
	return beautify(name, '-', true);
}

private string beautify(string name, char space = ' ', bool allLowerCase = false) pure {
	if(name == "id")
		return allLowerCase ? name : "ID";

	char[160] buffer;
	int bufferIndex = 0;
	bool shouldCap = true;
	bool shouldSpace;
	bool lastWasCap;
	foreach(idx, char ch; name) {
		if(bufferIndex == buffer.length) return name; // out of space, just give up, not that important

		if((ch >= 'A' && ch <= 'Z') || ch == '_') {
			if(lastWasCap) {
				// two caps in a row, don't change. Prolly acronym.
			} else {
				if(idx)
					shouldSpace = true; // new word, add space
			}

			lastWasCap = true;
		} else {
			lastWasCap = false;
		}

		if(shouldSpace) {
			buffer[bufferIndex++] = space;
			if(bufferIndex == buffer.length) return name; // out of space, just give up, not that important
			shouldSpace = false;
		}
		if(shouldCap) {
			if(ch >= 'a' && ch <= 'z')
				ch -= 32;
			shouldCap = false;
		}
		if(allLowerCase && ch >= 'A' && ch <= 'Z')
			ch += 32;
		buffer[bufferIndex++] = ch;
	}
	return buffer[0 .. bufferIndex].idup;
}

/*
string urlFor(alias func)() {
	return __traits(identifier, func);
}
*/

/++
	UDA: The name displayed to the user in auto-generated HTML.

	Default is `beautify(identifier)`.
+/
struct DisplayName {
	string name;
}

/++
	UDA: The name used in the URL or web parameter.

	Default is `urlify(identifier)` for functions and `identifier` for parameters and data members.
+/
struct UrlName {
	string name;
}

/++
	UDA: default format to respond for this method
+/
struct DefaultFormat { string value; }

class MissingArgumentException : Exception {
	string functionName;
	string argumentName;
	string argumentType;

	this(string functionName, string argumentName, string argumentType, string file = __FILE__, size_t line = __LINE__, Throwable next = null) {
		this.functionName = functionName;
		this.argumentName = argumentName;
		this.argumentType = argumentType;

		super("Missing Argument: " ~ this.argumentName, file, line, next);
	}
}

/++
	You can throw this from an api handler to indicate a 404 response. This is done by the presentExceptionAsHtml function in the presenter.

	History:
		Added December 15, 2021 (dub v10.5)
+/
class ResourceNotFoundException : Exception {
	string resourceType;
	string resourceId;

	this(string resourceType, string resourceId, string file = __FILE__, size_t line = __LINE__, Throwable next = null) {
		this.resourceType = resourceType;
		this.resourceId = resourceId;

		super("Resource not found: " ~ resourceType ~ " " ~ resourceId, file, line, next);
	}

}

/++
	This can be attached to any constructor or function called from the cgi system.

	If it is present, the function argument can NOT be set from web params, but instead
	is set to the return value of the given `func`.

	If `func` can take a parameter of type [Cgi], it will be passed the one representing
	the current request. Otherwise, it must take zero arguments.

	Any params in your function of type `Cgi` are automatically assumed to take the cgi object
	for the connection. Any of type [Session] (with an argument) is	also assumed to come from
	the cgi object.

	const arguments are also supported.
+/
struct ifCalledFromWeb(alias func) {}

// it only looks at query params for GET requests, the rest must be in the body for a function argument.
auto callFromCgi(alias method, T)(T dg, Cgi cgi) {

	// FIXME: any array of structs should also be settable or gettable from csv as well.

	// FIXME: think more about checkboxes and bools.

	import std.traits;

	Parameters!method params;
	alias idents = ParameterIdentifierTuple!method;
	alias defaults = ParameterDefaults!method;

	const(string)[] names;
	const(string)[] values;

	// first, check for missing arguments and initialize to defaults if necessary

	static if(is(typeof(method) P == __parameters))
	foreach(idx, param; P) {{
		// see: mustNotBeSetFromWebParams
		static if(is(param : Cgi)) {
			static assert(!is(param == immutable));
			cast() params[idx] = cgi;
		} else static if(is(param == Session!D, D)) {
			static assert(!is(param == immutable));
			cast() params[idx] = cgi.getSessionObject!D();
		} else {
			bool populated;
			foreach(uda; __traits(getAttributes, P[idx .. idx + 1])) {
				static if(is(uda == ifCalledFromWeb!func, alias func)) {
					static if(is(typeof(func(cgi))))
						params[idx] = func(cgi);
					else
						params[idx] = func();

					populated = true;
				}
			}

			if(!populated) {
				static if(__traits(compiles, { params[idx] = param.getAutomaticallyForCgi(cgi); } )) {
					params[idx] = param.getAutomaticallyForCgi(cgi);
					populated = true;
				}
			}

			if(!populated) {
				auto ident = idents[idx];
				if(cgi.requestMethod == Cgi.RequestMethod.GET) {
					if(ident !in cgi.get) {
						static if(is(defaults[idx] == void)) {
							static if(is(param == bool))
								params[idx] = false;
							else
								throw new MissingArgumentException(__traits(identifier, method), ident, param.stringof);
						} else
							params[idx] = defaults[idx];
					}
				} else {
					if(ident !in cgi.post) {
						static if(is(defaults[idx] == void)) {
							static if(is(param == bool))
								params[idx] = false;
							else
								throw new MissingArgumentException(__traits(identifier, method), ident, param.stringof);
						} else
							params[idx] = defaults[idx];
					}
				}
			}
		}
	}}

	// second, parse the arguments in order to build up arrays, etc.

	static bool setVariable(T)(string name, string paramName, T* what, string value) {
		static if(is(T == struct)) {
			if(name == paramName) {
				*what = T.init;
				return true;
			} else {
				// could be a child. gonna allow either obj.field OR obj[field]

				string afterName;

				if(name[paramName.length] == '[') {
					int count = 1;
					auto idx = paramName.length + 1;
					while(idx < name.length && count > 0) {
						if(name[idx] == '[')
							count++;
						else if(name[idx] == ']') {
							count--;
							if(count == 0) break;
						}
						idx++;
					}

					if(idx == name.length)
						return false; // malformed

					auto insideBrackets = name[paramName.length + 1 .. idx];
					afterName = name[idx + 1 .. $];

					name = name[0 .. paramName.length];

					paramName = insideBrackets;

				} else if(name[paramName.length] == '.') {
					paramName = name[paramName.length + 1 .. $];
					name = paramName;
					int p = 0;
					foreach(ch; paramName) {
						if(ch == '.' || ch == '[')
							break;
						p++;
					}

					afterName = paramName[p .. $];
					paramName = paramName[0 .. p];
				} else {
					return false;
				}

				if(paramName.length)
				// set the child member
				switch(paramName) {
					foreach(idx, memberName; __traits(allMembers, T))
					static if(__traits(compiles, __traits(getMember, T, memberName).offsetof)) {
						// data member!
						case memberName:
							return setVariable(name ~ afterName, paramName, &(__traits(getMember, *what, memberName)), value);
					}
					default:
						// ok, not a member
				}
			}

			return false;
		} else static if(is(T == enum)) {
			*what = to!T(value);
			return true;
		} else static if(isSomeString!T || isIntegral!T || isFloatingPoint!T) {
			*what = to!T(value);
			return true;
		} else static if(is(T == bool)) {
			*what = value == "1" || value == "yes" || value == "t" || value == "true" || value == "on";
			return true;
		} else static if(is(T == K[], K)) {
			K tmp;
			if(name == paramName) {
				// direct - set and append
				if(setVariable(name, paramName, &tmp, value)) {
					(*what) ~= tmp;
					return true;
				} else {
					return false;
				}
			} else {
				// child, append to last element
				// FIXME: what about range violations???
				auto ptr = &(*what)[(*what).length - 1];
				return setVariable(name, paramName, ptr, value);

			}
		} else static if(is(T == V[K], K, V)) {
			// assoc array, name[key] is valid
			if(name == paramName) {
				// no action necessary
				return true;
			} else if(name[paramName.length] == '[') {
				int count = 1;
				auto idx = paramName.length + 1;
				while(idx < name.length && count > 0) {
					if(name[idx] == '[')
						count++;
					else if(name[idx] == ']') {
						count--;
						if(count == 0) break;
					}
					idx++;
				}
				if(idx == name.length)
					return false; // malformed

				auto insideBrackets = name[paramName.length + 1 .. idx];
				auto afterName = name[idx + 1 .. $];

				auto k = to!K(insideBrackets);
				V v;
				if(auto ptr = k in *what)
					v = *ptr;

				name = name[0 .. paramName.length];
				//writeln(name, afterName, " ", paramName);

				auto ret = setVariable(name ~ afterName, paramName, &v, value);
				if(ret) {
					(*what)[k] = v;
					return true;
				}
			}

			return false;
		} else {
			static assert(0, "unsupported type for cgi call " ~ T.stringof);
		}

		//return false;
	}

	void setArgument(string name, string value) {
		int p;
		foreach(ch; name) {
			if(ch == '.' || ch == '[')
				break;
			p++;
		}

		auto paramName = name[0 .. p];

		sw: switch(paramName) {
			static if(is(typeof(method) P == __parameters))
			foreach(idx, param; P) {
				static if(mustNotBeSetFromWebParams!(P[idx], __traits(getAttributes, P[idx .. idx + 1]))) {
					// cannot be set from the outside
				} else {
					case idents[idx]:
						static if(is(param == Cgi.UploadedFile)) {
							params[idx] = cgi.files[name];
						} else {
							setVariable(name, paramName, &params[idx], value);
						}
					break sw;
				}
			}
			default:
				// ignore; not relevant argument
		}
	}

	if(cgi.requestMethod == Cgi.RequestMethod.GET) {
		names = cgi.allGetNamesInOrder;
		values = cgi.allGetValuesInOrder;
	} else {
		names = cgi.allPostNamesInOrder;
		values = cgi.allPostValuesInOrder;
	}

	foreach(idx, name; names) {
		setArgument(name, values[idx]);
	}

	static if(is(ReturnType!method == void)) {
		typeof(null) ret;
		dg(params);
	} else {
		auto ret = dg(params);
	}

	// FIXME: format return values
	// options are: json, html, csv.
	// also may need to wrap in envelope format: none, html, or json.
	return ret;
}

private bool mustNotBeSetFromWebParams(T, attrs...)() {
	static if(is(T : const(Cgi))) {
		return true;
	} else static if(is(T : const(Session!D), D)) {
		return true;
	} else static if(__traits(compiles, T.getAutomaticallyForCgi(Cgi.init))) {
		return true;
	} else {
		foreach(uda; attrs)
			static if(is(uda == ifCalledFromWeb!func, alias func))
				return true;
		return false;
	}
}

private bool hasIfCalledFromWeb(attrs...)() {
	foreach(uda; attrs)
		static if(is(uda == ifCalledFromWeb!func, alias func))
			return true;
	return false;
}

/++
	Implies POST path for the thing itself, then GET will get the automatic form.

	The given customizer, if present, will be called as a filter on the Form object.

	History:
		Added December 27, 2020
+/
template AutomaticForm(alias customizer) { }

/++
	This is meant to be returned by a function that takes a form POST submission. You
	want to set the url of the new resource it created, which is set as the http
	Location header for a "201 Created" result, and you can also set a separate
	destination for browser users, which it sets via a "Refresh" header.

	The `resourceRepresentation` should generally be the thing you just created, and
	it will be the body of the http response when formatted through the presenter.
	The exact thing is up to you - it could just return an id, or the whole object, or
	perhaps a partial object.

	Examples:
	---
	class Test : WebObject {
		@(Cgi.RequestMethod.POST)
		CreatedResource!int makeThing(string value) {
			return CreatedResource!int(value.to!int, "/resources/id");
		}
	}
	---

	History:
		Added December 18, 2021
+/
struct CreatedResource(T) {
	static if(!is(T == void))
		T resourceRepresentation;
	string resourceUrl;
	string refreshUrl;
}

/+
/++
	This can be attached as a UDA to a handler to add a http Refresh header on a
	successful run. (It will not be attached if the function throws an exception.)
	This will refresh the browser the given number of seconds after the page loads,
	to the url returned by `urlFunc`, which can be either a static function or a
	member method of the current handler object.

	You might use this for a POST handler that is normally used from ajax, but you
	want it to degrade gracefully to a temporarily flashed message before reloading
	the main page.

	History:
		Added December 18, 2021
+/
struct Refresh(alias urlFunc) {
	int waitInSeconds;

	string url() {
		static if(__traits(isStaticFunction, urlFunc))
			return urlFunc();
		else static if(is(urlFunc : string))
			return urlFunc;
	}
}
+/

/+
/++
	Sets a filter to be run before

	A before function can do validations of params and log and stop the function from running.
+/
template Before(alias b) {}
template After(alias b) {}
+/

/+
	Argument conversions: for the most part, it is to!Thing(string).

	But arrays and structs are a bit different. Arrays come from the cgi array. Thus
	they are passed

	arr=foo&arr=bar <-- notice the same name.

	Structs are first declared with an empty thing, then have their members set individually,
	with dot notation. The members are not required, just the initial declaration.

	struct Foo {
		int a;
		string b;
	}
	void test(Foo foo){}

	foo&foo.a=5&foo.b=str <-- the first foo declares the arg, the others set the members

	Arrays of structs use this declaration.

	void test(Foo[] foo) {}

	foo&foo.a=5&foo.b=bar&foo&foo.a=9

	You can use a hidden input field in HTML forms to achieve this. The value of the naked name
	declaration is ignored.

	Mind that order matters! The declaration MUST come first in the string.

	Arrays of struct members follow this rule recursively.

	struct Foo {
		int[] a;
	}

	foo&foo.a=1&foo.a=2&foo&foo.a=1


	Associative arrays are formatted with brackets, after a declaration, like structs:

	foo&foo[key]=value&foo[other_key]=value


	Note: for maximum compatibility with outside code, keep your types simple. Some libraries
	do not support the strict ordering requirements to work with these struct protocols.

	FIXME: also perhaps accept application/json to better work with outside trash.


	Return values are also auto-formatted according to user-requested type:
		for json, it loops over and converts.
		for html, basic types are strings. Arrays are <ol>. Structs are <dl>. Arrays of structs are tables!
+/

/++
	A web presenter is responsible for rendering things to HTML to be usable
	in a web browser.

	They are passed as template arguments to the base classes of [WebObject]

	Responsible for displaying stuff as HTML. You can put this into your own aggregate
	and override it. Use forwarding and specialization to customize it.

	When you inherit from it, pass your own class as the CRTP argument. This lets the base
	class templates and your overridden templates work with each other.

	---
	class MyPresenter : WebPresenter!(MyPresenter) {
		@Override
		void presentSuccessfulReturnAsHtml(T : CustomType)(Cgi cgi, T ret, typeof(null) meta) {
			// present the CustomType
		}
		@Override
		void presentSuccessfulReturnAsHtml(T)(Cgi cgi, T ret, typeof(null) meta) {
			// handle everything else via the super class, which will call
			// back to your class when appropriate
			super.presentSuccessfulReturnAsHtml(cgi, ret);
		}
	}
	---

	The meta argument in there can be overridden by your own facility.

+/
class WebPresenter(CRTP) {

	/// A UDA version of the built-in `override`, to be used for static template polymorphism
	/// If you override a plain method, use `override`. If a template, use `@Override`.
	enum Override;

	string script() {
		return `
		`;
	}

	string style() {
		return `
			:root {
				--mild-border: #ccc;
				--middle-border: #999;
				--accent-color: #f2f2f2;
				--sidebar-color: #fefefe;
			}
		` ~ genericFormStyling() ~ genericSiteStyling();
	}

	string genericFormStyling() {
		return
q"css
			table.automatic-data-display {
				border-collapse: collapse;
				border: solid 1px var(--mild-border);
			}

			table.automatic-data-display td {
				vertical-align: top;
				border: solid 1px var(--mild-border);
				padding: 2px 4px;
			}

			table.automatic-data-display th {
				border: solid 1px var(--mild-border);
				border-bottom: solid 1px var(--middle-border);
				padding: 2px 4px;
			}

			ol.automatic-data-display {
				margin: 0px;
				list-style-position: inside;
				padding: 0px;
			}

			dl.automatic-data-display {

			}

			.automatic-form {
				max-width: 600px;
			}

			.form-field {
				margin: 0.5em;
				padding-left: 0.5em;
			}

			.label-text {
				display: block;
				font-weight: bold;
				margin-left: -0.5em;
			}

			.submit-button-holder {
				padding-left: 2em;
			}

			.add-array-button {

			}
css";
	}

	string genericSiteStyling() {
		return
q"css
			* { box-sizing: border-box; }
			html, body { margin: 0px; }
			body {
				font-family: sans-serif;
			}
			header {
				background: var(--accent-color);
				height: 64px;
			}
			footer {
				background: var(--accent-color);
				height: 64px;
			}
			#site-container {
				display: flex;
			}
			main {
				flex: 1 1 auto;
				order: 2;
				min-height: calc(100vh - 64px - 64px);
				padding: 4px;
				padding-left: 1em;
			}
			#sidebar {
				flex: 0 0 16em;
				order: 1;
				background: var(--sidebar-color);
			}
css";
	}

	import arsd.dom;
	Element htmlContainer() {
		auto document = new Document(q"html
<!DOCTYPE html>
<html>
<head>
	<title>D Application</title>
	<link rel="stylesheet" href="style.css" />
</head>
<body>
	<header></header>
	<div id="site-container">
		<main></main>
		<div id="sidebar"></div>
	</div>
	<footer></footer>
	<script src="script.js"></script>
</body>
</html>
html", true, true);

		return document.requireSelector("main");
	}

	/// Renders a response as an HTTP error
	void renderBasicError(Cgi cgi, int httpErrorCode) {
		cgi.setResponseStatus(getHttpCodeText(httpErrorCode));
		auto c = htmlContainer();
		c.innerText = getHttpCodeText(httpErrorCode);
		cgi.setResponseContentType("text/html; charset=utf-8");
		cgi.write(c.parentDocument.toString(), true);
	}

	template methodMeta(alias method) {
		enum methodMeta = null;
	}

	void presentSuccessfulReturn(T, Meta)(Cgi cgi, T ret, Meta meta, string format) {
		// FIXME? format?
		(cast(CRTP) this).presentSuccessfulReturnAsHtml(cgi, ret, meta);
	}

	/// typeof(null) (which is also used to represent functions returning `void`) do nothing
	/// in the default presenter - allowing the function to have full low-level control over the
	/// response.
	void presentSuccessfulReturn(T : typeof(null), Meta)(Cgi cgi, T ret, Meta meta, string format) {
		// nothing intentionally!
	}

	/// Redirections are forwarded to [Cgi.setResponseLocation]
	void presentSuccessfulReturn(T : Redirection, Meta)(Cgi cgi, T ret, Meta meta, string format) {
		cgi.setResponseLocation(ret.to, true, getHttpCodeText(ret.code));
	}

	/// [CreatedResource]s send code 201 and will set the given urls, then present the given representation.
	void presentSuccessfulReturn(T : CreatedResource!R, Meta, R)(Cgi cgi, T ret, Meta meta, string format) {
		cgi.setResponseStatus(getHttpCodeText(201));
		if(ret.resourceUrl.length)
			cgi.header("Location: " ~ ret.resourceUrl);
		if(ret.refreshUrl.length)
			cgi.header("Refresh: 0;" ~ ret.refreshUrl);
		static if(!is(R == void))
			presentSuccessfulReturn(cgi, ret.resourceRepresentation, meta, format);
	}

	/// Multiple responses deconstruct the algebraic type and forward to the appropriate handler at runtime
	void presentSuccessfulReturn(T : MultipleResponses!Types, Meta, Types...)(Cgi cgi, T ret, Meta meta, string format) {
		bool outputted = false;
		foreach(index, type; Types) {
			if(ret.contains == index) {
				assert(!outputted);
				outputted = true;
				(cast(CRTP) this).presentSuccessfulReturn(cgi, ret.payload[index], meta, format);
			}
		}
		if(!outputted)
			assert(0);
	}

	/// An instance of the [arsd.dom.FileResource] interface has its own content type; assume it is a download of some sort.
	void presentSuccessfulReturn(T : FileResource, Meta)(Cgi cgi, T ret, Meta meta, string format) {
		cgi.setCache(true); // not necessarily true but meh
		cgi.setResponseContentType(ret.contentType);
		cgi.write(ret.getData(), true);
	}

	/// And the default handler for HTML will call [formatReturnValueAsHtml] and place it inside the [htmlContainer].
	void presentSuccessfulReturnAsHtml(T)(Cgi cgi, T ret, typeof(null) meta) {
		auto container = this.htmlContainer();
		container.appendChild(formatReturnValueAsHtml(ret));
		cgi.write(container.parentDocument.toString(), true);
	}

	/++
		If you override this, you will need to cast the exception type `t` dynamically,
		but can then use the template arguments here to refer back to the function.

		`func` is an alias to the method itself, and `dg` is a callable delegate to the same
		method on the live object. You could, in theory, change arguments and retry, but I
		provide that information mostly with the expectation that you will use them to make
		useful forms or richer error messages for the user.
	+/
	void presentExceptionAsHtml(alias func, T)(Cgi cgi, Throwable t, T dg) {
		Form af;
		foreach(attr; __traits(getAttributes, func)) {
			static if(__traits(isSame, attr, AutomaticForm)) {
				af = createAutomaticFormForFunction!(func)(dg);
			}
		}
		presentExceptionAsHtmlImpl(cgi, t, af);
	}

	void presentExceptionAsHtmlImpl(Cgi cgi, Throwable t, Form automaticForm) {
		if(auto e = cast(ResourceNotFoundException) t) {
			auto container = this.htmlContainer();

			container.addChild("p", e.msg);

			if(!cgi.outputtedResponseData)
				cgi.setResponseStatus("404 Not Found");
			cgi.write(container.parentDocument.toString(), true);
		} else if(auto mae = cast(MissingArgumentException) t) {
			if(automaticForm is null)
				goto generic;
			auto container = this.htmlContainer();
			if(cgi.requestMethod == Cgi.RequestMethod.POST)
				container.appendChild(Element.make("p", "Argument `" ~ mae.argumentName ~ "` of type `" ~ mae.argumentType ~ "` is missing"));
			container.appendChild(automaticForm);

			cgi.write(container.parentDocument.toString(), true);
		} else {
			generic:
			auto container = this.htmlContainer();

			// import std.stdio; writeln(t.toString());

			container.appendChild(exceptionToElement(t));

			container.addChild("h4", "GET");
			foreach(k, v; cgi.get) {
				auto deets = container.addChild("details");
				deets.addChild("summary", k);
				deets.addChild("div", v);
			}

			container.addChild("h4", "POST");
			foreach(k, v; cgi.post) {
				auto deets = container.addChild("details");
				deets.addChild("summary", k);
				deets.addChild("div", v);
			}


			if(!cgi.outputtedResponseData)
				cgi.setResponseStatus("500 Internal Server Error");
			cgi.write(container.parentDocument.toString(), true);
		}
	}

	Element exceptionToElement(Throwable t) {
		auto div = Element.make("div");
		div.addClass("exception-display");

		div.addChild("p", t.msg);
		div.addChild("p", "Inner code origin: " ~ typeid(t).name ~ "@" ~ t.file ~ ":" ~ to!string(t.line));

		auto pre = div.addChild("pre");
		string s;
		s = t.toString();
		Element currentBox;
		bool on = false;
		foreach(line; s.splitLines) {
			if(!on && line.startsWith("-----"))
				on = true;
			if(!on) continue;
			if(line.indexOf("arsd/") != -1) {
				if(currentBox is null) {
					currentBox = pre.addChild("details");
					currentBox.addChild("summary", "Framework code");
				}
				currentBox.addChild("span", line ~ "\n");
			} else {
				pre.addChild("span", line ~ "\n");
				currentBox = null;
			}
		}

		return div;
	}

	/++
		Returns an element for a particular type
	+/
	Element elementFor(T)(string displayName, string name, Element function() udaSuggestion) {
		import std.traits;

		auto div = Element.make("div");
		div.addClass("form-field");

		static if(is(T == Cgi.UploadedFile)) {
			Element lbl;
			if(displayName !is null) {
				lbl = div.addChild("label");
				lbl.addChild("span", displayName, "label-text");
				lbl.appendText(" ");
			} else {
				lbl = div;
			}
			auto i = lbl.addChild("input", name);
			i.attrs.name = name;
			i.attrs.type = "file";
		} else static if(is(T == enum)) {
			Element lbl;
			if(displayName !is null) {
				lbl = div.addChild("label");
				lbl.addChild("span", displayName, "label-text");
				lbl.appendText(" ");
			} else {
				lbl = div;
			}
			auto i = lbl.addChild("select", name);
			i.attrs.name = name;

			foreach(memberName; __traits(allMembers, T))
				i.addChild("option", memberName);

		} else static if(is(T == struct)) {
			if(displayName !is null)
				div.addChild("span", displayName, "label-text");
			auto fieldset = div.addChild("fieldset");
			fieldset.addChild("legend", beautify(T.stringof)); // FIXME
			fieldset.addChild("input", name);
			foreach(idx, memberName; __traits(allMembers, T))
			static if(__traits(compiles, __traits(getMember, T, memberName).offsetof)) {
				fieldset.appendChild(elementFor!(typeof(__traits(getMember, T, memberName)))(beautify(memberName), name ~ "." ~ memberName, null /* FIXME: pull off the UDA */));
			}
		} else static if(isSomeString!T || isIntegral!T || isFloatingPoint!T) {
			Element lbl;
			if(displayName !is null) {
				lbl = div.addChild("label");
				lbl.addChild("span", displayName, "label-text");
				lbl.appendText(" ");
			} else {
				lbl = div;
			}
			Element i;
			if(udaSuggestion) {
				i = udaSuggestion();
				lbl.appendChild(i);
			} else {
				i = lbl.addChild("input", name);
			}
			i.attrs.name = name;
			static if(isSomeString!T)
				i.attrs.type = "text";
			else
				i.attrs.type = "number";
			if(i.tagName == "textarea")
				i.textContent = to!string(T.init);
			else
				i.attrs.value = to!string(T.init);
		} else static if(is(T == bool)) {
			Element lbl;
			if(displayName !is null) {
				lbl = div.addChild("label");
				lbl.addChild("span", displayName, "label-text");
				lbl.appendText(" ");
			} else {
				lbl = div;
			}
			auto i = lbl.addChild("input", name);
			i.attrs.type = "checkbox";
			i.attrs.value = "true";
			i.attrs.name = name;
		} else static if(is(T == K[], K)) {
			auto templ = div.addChild("template");
			templ.appendChild(elementFor!(K)(null, name, null /* uda??*/));
			if(displayName !is null)
				div.addChild("span", displayName, "label-text");
			auto btn = div.addChild("button");
			btn.addClass("add-array-button");
			btn.attrs.type = "button";
			btn.innerText = "Add";
			btn.attrs.onclick = q{
				var a = document.importNode(this.parentNode.firstChild.content, true);
				this.parentNode.insertBefore(a, this);
			};
		} else static if(is(T == V[K], K, V)) {
			div.innerText = "assoc array not implemented for automatic form at this time";
		} else {
			static assert(0, "unsupported type for cgi call " ~ T.stringof);
		}


		return div;
	}

	/// creates a form for gathering the function's arguments
	Form createAutomaticFormForFunction(alias method, T)(T dg) {

		auto form = cast(Form) Element.make("form");

		form.method = "POST"; // FIXME

		form.addClass("automatic-form");

		string formDisplayName = beautify(__traits(identifier, method));
		foreach(attr; __traits(getAttributes, method))
			static if(is(typeof(attr) == DisplayName))
				formDisplayName = attr.name;
		form.addChild("h3", formDisplayName);

		import std.traits;

		//Parameters!method params;
		//alias idents = ParameterIdentifierTuple!method;
		//alias defaults = ParameterDefaults!method;

		static if(is(typeof(method) P == __parameters))
		foreach(idx, _; P) {{

			alias param = P[idx .. idx + 1];

			static if(!mustNotBeSetFromWebParams!(param[0], __traits(getAttributes, param))) {
				string displayName = beautify(__traits(identifier, param));
				Element function() element;
				foreach(attr; __traits(getAttributes, param)) {
					static if(is(typeof(attr) == DisplayName))
						displayName = attr.name;
					else static if(is(typeof(attr) : typeof(element))) {
						element = attr;
					}
				}
				auto i = form.appendChild(elementFor!(param)(displayName, __traits(identifier, param), element));
				if(i.querySelector("input[type=file]") !is null)
					form.setAttribute("enctype", "multipart/form-data");
			}
		}}

		form.addChild("div", Html(`<input type="submit" value="Submit" />`), "submit-button-holder");

		return form;
	}

	/// creates a form for gathering object members (for the REST object thing right now)
	Form createAutomaticFormForObject(T)(T obj) {
		auto form = cast(Form) Element.make("form");

		form.addClass("automatic-form");

		form.addChild("h3", beautify(__traits(identifier, T)));

		import std.traits;

		//Parameters!method params;
		//alias idents = ParameterIdentifierTuple!method;
		//alias defaults = ParameterDefaults!method;

		foreach(idx, memberName; __traits(derivedMembers, T)) {{
		static if(__traits(compiles, __traits(getMember, obj, memberName).offsetof)) {
			string displayName = beautify(memberName);
			Element function() element;
			foreach(attr; __traits(getAttributes,  __traits(getMember, T, memberName)))
				static if(is(typeof(attr) == DisplayName))
					displayName = attr.name;
				else static if(is(typeof(attr) : typeof(element)))
					element = attr;
			form.appendChild(elementFor!(typeof(__traits(getMember, T, memberName)))(displayName, memberName, element));

			form.setValue(memberName, to!string(__traits(getMember, obj, memberName)));
		}}}

		form.addChild("div", Html(`<input type="submit" value="Submit" />`), "submit-button-holder");

		return form;
	}

	///
	Element formatReturnValueAsHtml(T)(T t) {
		import std.traits;

		static if(is(T == typeof(null))) {
			return Element.make("span");
		} else static if(is(T : Element)) {
			return t;
		} else static if(is(T == MultipleResponses!Types, Types...)) {
			foreach(index, type; Types) {
				if(t.contains == index)
					return formatReturnValueAsHtml(t.payload[index]);
			}
			assert(0);
		} else static if(is(T == Paginated!E, E)) {
			auto e = Element.make("div").addClass("paginated-result");
			e.appendChild(formatReturnValueAsHtml(t.items));
			if(t.nextPageUrl.length)
				e.appendChild(Element.make("a", "Next Page", t.nextPageUrl));
			return e;
		} else static if(isIntegral!T || isSomeString!T || isFloatingPoint!T) {
			return Element.make("span", to!string(t), "automatic-data-display");
		} else static if(is(T == V[K], K, V)) {
			auto dl = Element.make("dl");
			dl.addClass("automatic-data-display associative-array");
			foreach(k, v; t) {
				dl.addChild("dt", to!string(k));
				dl.addChild("dd", formatReturnValueAsHtml(v));
			}
			return dl;
		} else static if(is(T == struct)) {
			auto dl = Element.make("dl");
			dl.addClass("automatic-data-display struct");

			foreach(idx, memberName; __traits(allMembers, T))
			static if(__traits(compiles, __traits(getMember, T, memberName).offsetof)) {
				dl.addChild("dt", beautify(memberName));
				dl.addChild("dd", formatReturnValueAsHtml(__traits(getMember, t, memberName)));
			}

			return dl;
		} else static if(is(T == bool)) {
			return Element.make("span", t ? "true" : "false", "automatic-data-display");
		} else static if(is(T == E[], E)) {
			static if(is(E : RestObject!Proxy, Proxy)) {
				// treat RestObject similar to struct
				auto table = cast(Table) Element.make("table");
				table.addClass("automatic-data-display");
				string[] names;
				foreach(idx, memberName; __traits(derivedMembers, E))
				static if(__traits(compiles, __traits(getMember, E, memberName).offsetof)) {
					names ~= beautify(memberName);
				}
				table.appendHeaderRow(names);

				foreach(l; t) {
					auto tr = table.appendRow();
					foreach(idx, memberName; __traits(derivedMembers, E))
					static if(__traits(compiles, __traits(getMember, E, memberName).offsetof)) {
						static if(memberName == "id") {
							string val = to!string(__traits(getMember, l, memberName));
							tr.addChild("td", Element.make("a", val, E.stringof.toLower ~ "s/" ~ val)); // FIXME
						} else {
							tr.addChild("td", formatReturnValueAsHtml(__traits(getMember, l, memberName)));
						}
					}
				}

				return table;
			} else static if(is(E == struct)) {
				// an array of structs is kinda special in that I like
				// having those formatted as tables.
				auto table = cast(Table) Element.make("table");
				table.addClass("automatic-data-display");
				string[] names;
				foreach(idx, memberName; __traits(allMembers, E))
				static if(__traits(compiles, __traits(getMember, E, memberName).offsetof)) {
					names ~= beautify(memberName);
				}
				table.appendHeaderRow(names);

				foreach(l; t) {
					auto tr = table.appendRow();
					foreach(idx, memberName; __traits(allMembers, E))
					static if(__traits(compiles, __traits(getMember, E, memberName).offsetof)) {
						tr.addChild("td", formatReturnValueAsHtml(__traits(getMember, l, memberName)));
					}
				}

				return table;
			} else {
				// otherwise, I will just make a list.
				auto ol = Element.make("ol");
				ol.addClass("automatic-data-display");
				foreach(e; t)
					ol.addChild("li", formatReturnValueAsHtml(e));
				return ol;
			}
		} else static if(is(T : Object)) {
			static if(is(typeof(t.toHtml()))) // FIXME: maybe i will make this an interface
				return Element.make("div", t.toHtml());
			else
				return Element.make("div", t.toString());
		} else static assert(0, "bad return value for cgi call " ~ T.stringof);

		assert(0);
	}

}

/++
	The base class for the [dispatcher] function and object support.
+/
class WebObject {
	//protected Cgi cgi;

	protected void initialize(Cgi cgi) {
		//this.cgi = cgi;
	}
}

/++
	Can return one of the given types, decided at runtime. The syntax
	is to declare all the possible types in the return value, then you
	can `return typeof(return)(...value...)` to construct it.

	It has an auto-generated constructor for each value it can hold.

	---
	MultipleResponses!(Redirection, string) getData(int how) {
		if(how & 1)
			return typeof(return)(Redirection("http://dpldocs.info/"));
		else
			return typeof(return)("hi there!");
	}
	---

	If you have lots of returns, you could, inside the function, `alias r = typeof(return);` to shorten it a little.
+/
struct MultipleResponses(T...) {
	private size_t contains;
	private union {
		private T payload;
	}

	static foreach(index, type; T)
	public this(type t) {
		contains = index;
		payload[index] = t;
	}

	/++
		This is primarily for testing. It is your way of getting to the response.

		Let's say you wanted to test that one holding a Redirection and a string actually
		holds a string, by name of "test":

		---
			auto valueToTest = your_test_function();

			valueToTest.visit(
				(Redirection r) { assert(0); }, // got a redirection instead of a string, fail the test
				(string s) { assert(s == "test"); } // right value, go ahead and test it.
			);
		---

		History:
			Was horribly broken until June 16, 2022. Ironically, I wrote it for tests but never actually tested it.
			It tried to use alias lambdas before, but runtime delegates work much better so I changed it.
	+/
	void visit(Handlers...)(Handlers handlers) {
		template findHandler(type, int count, HandlersToCheck...) {
			static if(HandlersToCheck.length == 0)
				enum findHandler = -1;
			else {
				static if(is(typeof(HandlersToCheck[0].init(type.init))))
					enum findHandler = count;
				else
					enum findHandler = findHandler!(type, count + 1, HandlersToCheck[1 .. $]);
			}
		}
		foreach(index, type; T) {
			enum handlerIndex = findHandler!(type, 0, Handlers);
			static if(handlerIndex == -1)
				static assert(0, "Type " ~ type.stringof ~ " was not handled by visitor");
			else {
				if(index == this.contains)
					handlers[handlerIndex](this.payload[index]);
			}
		}
	}

	/+
	auto toArsdJsvar()() {
		import arsd.jsvar;
		return var(null);
	}
	+/
}

// FIXME: implement this somewhere maybe
struct RawResponse {
	int code;
	string[] headers;
	const(ubyte)[] responseBody;
}

/++
	You can return this from [WebObject] subclasses for redirections.

	(though note the static types means that class must ALWAYS redirect if
	you return this directly. You might want to return [MultipleResponses] if it
	can be conditional)
+/
struct Redirection {
	string to; /// The URL to redirect to.
	int code = 303; /// The HTTP code to return.
}

/++
	Serves a class' methods, as a kind of low-state RPC over the web. To be used with [dispatcher].

	Usage of this function will add a dependency on [arsd.dom] and [arsd.jsvar] unless you have overriden
	the presenter in the dispatcher.

	FIXME: explain this better

	You can overload functions to a limited extent: you can provide a zero-arg and non-zero-arg function,
	and non-zero-arg functions can filter via UDAs for various http methods. Do not attempt other overloads,
	the runtime result of that is undefined.

	A method is assumed to allow any http method unless it lists some in UDAs, in which case it is limited to only those.
	(this might change, like maybe i will use pure as an indicator GET is ok. idk.)

	$(WARNING
		---
		// legal in D, undefined runtime behavior with cgi.d, it may call either method
		// even if you put different URL udas on it, the current code ignores them.
		void foo(int a) {}
		void foo(string a) {}
		---
	)

	See_Also: [serveRestObject], [serveStaticFile]
+/
auto serveApi(T)(string urlPrefix) {
	assert(urlPrefix[$ - 1] == '/');
	return serveApiInternal!T(urlPrefix);
}

private string nextPieceFromSlash(ref string remainingUrl) {
	if(remainingUrl.length == 0)
		return remainingUrl;
	int slash = 0;
	while(slash < remainingUrl.length && remainingUrl[slash] != '/') // && remainingUrl[slash] != '.')
		slash++;

	// I am specifically passing `null` to differentiate it vs empty string
	// so in your ctor, `items` means new T(null) and `items/` means new T("")
	auto ident = remainingUrl.length == 0 ? null : remainingUrl[0 .. slash];
	// so if it is the last item, the dot can be used to load an alternative view
	// otherwise tho the dot is considered part of the identifier
	// FIXME

	// again notice "" vs null here!
	if(slash == remainingUrl.length)
		remainingUrl = null;
	else
		remainingUrl = remainingUrl[slash + 1 .. $];

	return ident;
}

/++
	UDA used to indicate to the [dispatcher] that a trailing slash should always be added to or removed from the url. It will do it as a redirect header as-needed.
+/
enum AddTrailingSlash;
/// ditto
enum RemoveTrailingSlash;

private auto serveApiInternal(T)(string urlPrefix) {

	import arsd.dom;
	import arsd.jsvar;

	static bool internalHandler(Presenter)(string urlPrefix, Cgi cgi, Presenter presenter, immutable void* details) {
		string remainingUrl = cgi.pathInfo[urlPrefix.length .. $];

		try {
			// see duplicated code below by searching subresource_ctor
			// also see mustNotBeSetFromWebParams

			static if(is(typeof(T.__ctor) P == __parameters)) {
				P params;

				foreach(pidx, param; P) {
					static if(is(param : Cgi)) {
						static assert(!is(param == immutable));
						cast() params[pidx] = cgi;
					} else static if(is(param == Session!D, D)) {
						static assert(!is(param == immutable));
						cast() params[pidx] = cgi.getSessionObject!D();

					} else {
						static if(hasIfCalledFromWeb!(__traits(getAttributes, P[pidx .. pidx + 1]))) {
							foreach(uda; __traits(getAttributes, P[pidx .. pidx + 1])) {
								static if(is(uda == ifCalledFromWeb!func, alias func)) {
									static if(is(typeof(func(cgi))))
										params[pidx] = func(cgi);
									else
										params[pidx] = func();
								}
							}
						} else {

							static if(__traits(compiles, { params[pidx] = param.getAutomaticallyForCgi(cgi); } )) {
								params[pidx] = param.getAutomaticallyForCgi(cgi);
							} else static if(is(param == string)) {
								auto ident = nextPieceFromSlash(remainingUrl);
								params[pidx] = ident;
							} else static assert(0, "illegal type for subresource " ~ param.stringof);
						}
					}
				}

				auto obj = new T(params);
			} else {
				auto obj = new T();
			}

			return internalHandlerWithObject(obj, remainingUrl, cgi, presenter);
		} catch(Throwable t) {
			switch(cgi.request("format", "html")) {
				case "html":
					static void dummy() {}
					presenter.presentExceptionAsHtml!(dummy)(cgi, t, &dummy);
				return true;
				case "json":
					var envelope = var.emptyObject;
					envelope.success = false;
					envelope.result = null;
					envelope.error = t.toString();
					cgi.setResponseContentType("application/json");
					cgi.write(envelope.toJson(), true);
				return true;
				default:
					throw t;
				// return true;
			}
			// return true;
		}

		assert(0);
	}

	static bool internalHandlerWithObject(T, Presenter)(T obj, string remainingUrl, Cgi cgi, Presenter presenter) {

		obj.initialize(cgi);

		/+
			Overload rules:
				Any unique combination of HTTP verb and url path can be dispatched to function overloads
				statically.

				Moreover, some args vs no args can be overloaded dynamically.
		+/

		auto methodNameFromUrl = nextPieceFromSlash(remainingUrl);
		/+
		auto orig = remainingUrl;
		assert(0,
			(orig is null ? "__null" : orig)
			~ " .. " ~
			(methodNameFromUrl is null ? "__null" : methodNameFromUrl));
		+/

		if(methodNameFromUrl is null)
			methodNameFromUrl = "__null";

		string hack = to!string(cgi.requestMethod) ~ " " ~ methodNameFromUrl;

		if(remainingUrl.length)
			hack ~= "/";

		switch(hack) {
			foreach(methodName; __traits(derivedMembers, T))
			static if(methodName != "__ctor")
			foreach(idx, overload; __traits(getOverloads, T, methodName)) {
			static if(is(typeof(overload) P == __parameters))
			static if(is(typeof(overload) R == return))
			static if(__traits(getProtection, overload) == "public" || __traits(getProtection, overload) == "export")
			{
			static foreach(urlNameForMethod; urlNamesForMethod!(overload, urlify(methodName)))
			case urlNameForMethod:

				static if(is(R : WebObject)) {
					// if it returns a WebObject, it is considered a subresource. That means the url is dispatched like the ctor above.

					// the only argument it is allowed to take, outside of cgi, session, and set up thingies, is a single string

					// subresource_ctor
					// also see mustNotBeSetFromWebParams

					P params;

					string ident;

					foreach(pidx, param; P) {
						static if(is(param : Cgi)) {
							static assert(!is(param == immutable));
							cast() params[pidx] = cgi;
						} else static if(is(param == typeof(presenter))) {
							cast() param[pidx] = presenter;
						} else static if(is(param == Session!D, D)) {
							static assert(!is(param == immutable));
							cast() params[pidx] = cgi.getSessionObject!D();
						} else {
							static if(hasIfCalledFromWeb!(__traits(getAttributes, P[pidx .. pidx + 1]))) {
								foreach(uda; __traits(getAttributes, P[pidx .. pidx + 1])) {
									static if(is(uda == ifCalledFromWeb!func, alias func)) {
										static if(is(typeof(func(cgi))))
											params[pidx] = func(cgi);
										else
											params[pidx] = func();
									}
								}
							} else {

								static if(__traits(compiles, { params[pidx] = param.getAutomaticallyForCgi(cgi); } )) {
									params[pidx] = param.getAutomaticallyForCgi(cgi);
								} else static if(is(param == string)) {
									ident = nextPieceFromSlash(remainingUrl);
									if(ident is null) {
										// trailing slash mandated on subresources
										cgi.setResponseLocation(cgi.pathInfo ~ "/");
										return true;
									} else {
										params[pidx] = ident;
									}
								} else static assert(0, "illegal type for subresource " ~ param.stringof);
							}
						}
					}

					auto nobj = (__traits(getOverloads, obj, methodName)[idx])(ident);
					return internalHandlerWithObject!(typeof(nobj), Presenter)(nobj, remainingUrl, cgi, presenter);
				} else {
					// 404 it if any url left - not a subresource means we don't get to play with that!
					if(remainingUrl.length)
						return false;

					bool automaticForm;

					foreach(attr; __traits(getAttributes, overload))
						static if(is(attr == AddTrailingSlash)) {
							if(remainingUrl is null) {
								cgi.setResponseLocation(cgi.pathInfo ~ "/");
								return true;
							}
						} else static if(is(attr == RemoveTrailingSlash)) {
							if(remainingUrl !is null) {
								cgi.setResponseLocation(cgi.pathInfo[0 .. lastIndexOf(cgi.pathInfo, "/")]);
								return true;
							}

						} else static if(__traits(isSame, AutomaticForm, attr)) {
							automaticForm = true;
						}

				/+
				int zeroArgOverload = -1;
				int overloadCount = cast(int) __traits(getOverloads, T, methodName).length;
				bool calledWithZeroArgs = true;
				foreach(k, v; cgi.get)
					if(k != "format") {
						calledWithZeroArgs = false;
						break;
					}
				foreach(k, v; cgi.post)
					if(k != "format") {
						calledWithZeroArgs = false;
						break;
					}

				// first, we need to go through and see if there is an empty one, since that
				// changes inside. But otherwise, all the stuff I care about can be done via
				// simple looping (other improper overloads might be flagged for runtime semantic check)
				//
				// an argument of type Cgi is ignored for these purposes
				static foreach(idx, overload; __traits(getOverloads, T, methodName)) {{
					static if(is(typeof(overload) P == __parameters))
						static if(P.length == 0)
							zeroArgOverload = cast(int) idx;
						else static if(P.length == 1 && is(P[0] : Cgi))
							zeroArgOverload = cast(int) idx;
				}}
				// FIXME: static assert if there are multiple non-zero-arg overloads usable with a single http method.
				bool overloadHasBeenCalled = false;
				static foreach(idx, overload; __traits(getOverloads, T, methodName)) {{
					bool callFunction = true;
					// there is a zero arg overload and this is NOT it, and we have zero args - don't call this
					if(overloadCount > 1 && zeroArgOverload != -1 && idx != zeroArgOverload && calledWithZeroArgs)
						callFunction = false;
					// if this is the zero-arg overload, obviously it cannot be called if we got any args.
					if(overloadCount > 1 && idx == zeroArgOverload && !calledWithZeroArgs)
						callFunction = false;

					// FIXME: so if you just add ?foo it will give the error below even when. this might not be a great idea.

					bool hadAnyMethodRestrictions = false;
					bool foundAcceptableMethod = false;
					foreach(attr; __traits(getAttributes, overload)) {
						static if(is(typeof(attr) == Cgi.RequestMethod)) {
							hadAnyMethodRestrictions = true;
							if(attr == cgi.requestMethod)
								foundAcceptableMethod = true;
						}
					}

					if(hadAnyMethodRestrictions && !foundAcceptableMethod)
						callFunction = false;

					/+
						The overloads we really want to allow are the sane ones
						from the web perspective. Which is likely on HTTP verbs,
						for the most part, but might also be potentially based on
						some args vs zero args, or on argument names. Can't really
						do argument types very reliable through the web though; those
						should probably be different URLs.

						Even names I feel is better done inside the function, so I'm not
						going to support that here. But the HTTP verbs and zero vs some
						args makes sense - it lets you define custom forms pretty easily.

						Moreover, I'm of the opinion that empty overload really only makes
						sense on GET for this case. On a POST, it is just a missing argument
						exception and that should be handled by the presenter. But meh, I'll
						let the user define that, D only allows one empty arg thing anyway
						so the method UDAs are irrelevant.
					+/
					if(callFunction)
				+/

					if(automaticForm && cgi.requestMethod == Cgi.RequestMethod.GET) {
						// Should I still show the form on a json thing? idk...
						auto ret = presenter.createAutomaticFormForFunction!((__traits(getOverloads, obj, methodName)[idx]))(&(__traits(getOverloads, obj, methodName)[idx]));
						presenter.presentSuccessfulReturn(cgi, ret, presenter.methodMeta!(__traits(getOverloads, obj, methodName)[idx]), "html");
						return true;
					}
					switch(cgi.request("format", defaultFormat!overload())) {
						case "html":
							// a void return (or typeof(null) lol) means you, the user, is doing it yourself. Gives full control.
							try {

								auto ret = callFromCgi!(__traits(getOverloads, obj, methodName)[idx])(&(__traits(getOverloads, obj, methodName)[idx]), cgi);
								presenter.presentSuccessfulReturn(cgi, ret, presenter.methodMeta!(__traits(getOverloads, obj, methodName)[idx]), "html");
							} catch(Throwable t) {
								presenter.presentExceptionAsHtml!(__traits(getOverloads, obj, methodName)[idx])(cgi, t, &(__traits(getOverloads, obj, methodName)[idx]));
							}
						return true;
						case "json":
							auto ret = callFromCgi!(__traits(getOverloads, obj, methodName)[idx])(&(__traits(getOverloads, obj, methodName)[idx]), cgi);
							static if(is(typeof(ret) == MultipleResponses!Types, Types...)) {
								var json;
								foreach(index, type; Types) {
									if(ret.contains == index)
										json = ret.payload[index];
								}
							} else {
								var json = ret;
							}
							var envelope = json; // var.emptyObject;
							/*
							envelope.success = true;
							envelope.result = json;
							envelope.error = null;
							*/
							cgi.setResponseContentType("application/json");
							cgi.write(envelope.toJson(), true);
						return true;
						default:
							cgi.setResponseStatus("406 Not Acceptable"); // not exactly but sort of.
						return true;
					}
				//}}

				//cgi.header("Accept: POST"); // FIXME list the real thing
				//cgi.setResponseStatus("405 Method Not Allowed"); // again, not exactly, but sort of. no overload matched our args, almost certainly due to http verb filtering.
				//return true;
				}
			}
			}
			case "GET script.js":
				cgi.setResponseContentType("text/javascript");
				cgi.gzipResponse = true;
				cgi.write(presenter.script(), true);
				return true;
			case "GET style.css":
				cgi.setResponseContentType("text/css");
				cgi.gzipResponse = true;
				cgi.write(presenter.style(), true);
				return true;
			default:
				return false;
		}

		assert(0);
	}
	return DispatcherDefinition!internalHandler(urlPrefix, false);
}

string defaultFormat(alias method)() {
	bool nonConstConditionForWorkingAroundASpuriousDmdWarning = true;
	foreach(attr; __traits(getAttributes, method)) {
		static if(is(typeof(attr) == DefaultFormat)) {
			if(nonConstConditionForWorkingAroundASpuriousDmdWarning)
				return attr.value;
		}
	}
	return "html";
}

struct Paginated(T) {
	T[] items;
	string nextPageUrl;
}

template urlNamesForMethod(alias method, string default_) {
	string[] helper() {
		auto verb = Cgi.RequestMethod.GET;
		bool foundVerb = false;
		bool foundNoun = false;

		string def = default_;

		bool hasAutomaticForm = false;

		foreach(attr; __traits(getAttributes, method)) {
			static if(is(typeof(attr) == Cgi.RequestMethod)) {
				verb = attr;
				if(foundVerb)
					assert(0, "Multiple http verbs on one function is not currently supported");
				foundVerb = true;
			}
			static if(is(typeof(attr) == UrlName)) {
				if(foundNoun)
					assert(0, "Multiple url names on one function is not currently supported");
				foundNoun = true;
				def = attr.name;
			}
			static if(__traits(isSame, attr, AutomaticForm)) {
				hasAutomaticForm = true;
			}
		}

		if(def is null)
			def = "__null";

		string[] ret;

		static if(is(typeof(method) R == return)) {
			static if(is(R : WebObject)) {
				def ~= "/";
				foreach(v; __traits(allMembers, Cgi.RequestMethod))
					ret ~= v ~ " " ~ def;
			} else {
				if(hasAutomaticForm) {
					ret ~= "GET " ~ def;
					ret ~= "POST " ~ def;
				} else {
					ret ~= to!string(verb) ~ " " ~ def;
				}
			}
		} else static assert(0);

		return ret;
	}
	enum urlNamesForMethod = helper();
}


	enum AccessCheck {
		allowed,
		denied,
		nonExistant,
	}

	enum Operation {
		show,
		create,
		replace,
		remove,
		update
	}

	enum UpdateResult {
		accessDenied,
		noSuchResource,
		success,
		failure,
		unnecessary
	}

	enum ValidationResult {
		valid,
		invalid
	}


/++
	The base of all REST objects, to be used with [serveRestObject] and [serveRestCollectionOf].

	WARNING: this is not stable.
+/
class RestObject(CRTP) : WebObject {

	import arsd.dom;
	import arsd.jsvar;

	/// Prepare the object to be shown.
	void show() {}
	/// ditto
	void show(string urlId) {
		load(urlId);
		show();
	}

	/// Override this to provide access control to this object.
	AccessCheck accessCheck(string urlId, Operation operation) {
		return AccessCheck.allowed;
	}

	ValidationResult validate() {
		// FIXME
		return ValidationResult.valid;
	}

	string getUrlSlug() {
		import std.conv;
		static if(is(typeof(CRTP.id)))
			return to!string((cast(CRTP) this).id);
		else
			return null;
	}

	// The functions with more arguments are the low-level ones,
	// they forward to the ones with fewer arguments by default.

	// POST on a parent collection - this is called from a collection class after the members are updated
	/++
		Given a populated object, this creates a new entry. Returns the url identifier
		of the new object.
	+/
	string create(scope void delegate() applyChanges) {
		applyChanges();
		save();
		return getUrlSlug();
	}

	void replace() {
		save();
	}
	void replace(string urlId, scope void delegate() applyChanges) {
		load(urlId);
		applyChanges();
		replace();
	}

	void update(string[] fieldList) {
		save();
	}
	void update(string urlId, scope void delegate() applyChanges, string[] fieldList) {
		load(urlId);
		applyChanges();
		update(fieldList);
	}

	void remove() {}

	void remove(string urlId) {
		load(urlId);
		remove();
	}

	abstract void load(string urlId);
	abstract void save();

	Element toHtml(Presenter)(Presenter presenter) {
		import arsd.dom;
		import std.conv;
		auto obj = cast(CRTP) this;
		auto div = Element.make("div");
		div.addClass("Dclass_" ~ CRTP.stringof);
		div.dataset.url = getUrlSlug();
		bool first = true;
		foreach(idx, memberName; __traits(derivedMembers, CRTP))
		static if(__traits(compiles, __traits(getMember, obj, memberName).offsetof)) {
			if(!first) div.addChild("br"); else first = false;
			div.appendChild(presenter.formatReturnValueAsHtml(__traits(getMember, obj, memberName)));
		}
		return div;
	}

	var toJson() {
		import arsd.jsvar;
		var v = var.emptyObject();
		auto obj = cast(CRTP) this;
		foreach(idx, memberName; __traits(derivedMembers, CRTP))
		static if(__traits(compiles, __traits(getMember, obj, memberName).offsetof)) {
			v[memberName] = __traits(getMember, obj, memberName);
		}
		return v;
	}

	/+
	auto structOf(this This) {

	}
	+/
}

// FIXME XSRF token, prolly can just put in a cookie and then it needs to be copied to header or form hidden value
// https://use-the-index-luke.com/sql/partial-results/fetch-next-page

/++
	Base class for REST collections.
+/
class CollectionOf(Obj) : RestObject!(CollectionOf) {
	/// You might subclass this and use the cgi object's query params
	/// to implement a search filter, for example.
	///
	/// FIXME: design a way to auto-generate that form
	/// (other than using the WebObject thing above lol
	// it'll prolly just be some searchParams UDA or maybe an enum.
	//
	// pagination too perhaps.
	//
	// and sorting too
	IndexResult index() { return IndexResult.init; }

	string[] sortableFields() { return null; }
	string[] searchableFields() { return null; }

	struct IndexResult {
		Obj[] results;

		string[] sortableFields;

		string previousPageIdentifier;
		string nextPageIdentifier;
		string firstPageIdentifier;
		string lastPageIdentifier;

		int numberOfPages;
	}

	override string create(scope void delegate() applyChanges) { assert(0); }
	override void load(string urlId) { assert(0); }
	override void save() { assert(0); }
	override void show() {
		index();
	}
	override void show(string urlId) {
		show();
	}

	/// Proxy POST requests (create calls) to the child collection
	alias PostProxy = Obj;
}

/++
	Serves a REST object, similar to a Ruby on Rails resource.

	You put data members in your class. cgi.d will automatically make something out of those.

	It will call your constructor with the ID from the URL. This may be null.
	It will then populate the data members from the request.
	It will then call a method, if present, telling what happened. You don't need to write these!
	It finally returns a reply.

	Your methods are passed a list of fields it actually set.

	The URL mapping - despite my general skepticism of the wisdom - matches up with what most REST
	APIs I have used seem to follow. (I REALLY want to put trailing slashes on it though. Works better
	with relative linking. But meh.)

	GET /items -> index. all values not set.
	GET /items/id -> get. only ID will be set, other params ignored.
	POST /items -> create. values set as given
	PUT /items/id -> replace. values set as given
		or POST /items/id with cgi.post["_method"] (thus urlencoded or multipart content-type) set to "PUT" to work around browser/html limitation
		a GET with cgi.get["_method"] (in the url) set to "PUT" will render a form.
	PATCH /items/id -> update. values set as given, list of changed fields passed
		or POST /items/id with cgi.post["_method"] == "PATCH"
	DELETE /items/id -> destroy. only ID guaranteed to be set
		or POST /items/id with cgi.post["_method"] == "DELETE"

	Following the stupid convention, there will never be a trailing slash here, and if it is there, it will
	redirect you away from it.

	API clients should set the `Accept` HTTP header to application/json or the cgi.get["_format"] = "json" var.

	I will also let you change the default, if you must.

	// One add-on is validation. You can issue a HTTP GET to a resource with _method = VALIDATE to check potential changes.

	You can define sub-resources on your object inside the object. These sub-resources are also REST objects
	that follow the same thing. They may be individual resources or collections themselves.

	Your class is expected to have at least the following methods:

	FIXME: i kinda wanna add a routes object to the initialize call

	create
		Create returns the new address on success, some code on failure.
	show
	index
	update
	remove

	You will want to be able to customize the HTTP, HTML, and JSON returns but generally shouldn't have to - the defaults
	should usually work. The returned JSON will include a field "href" on all returned objects along with "id". Or omething like that.

	Usage of this function will add a dependency on [arsd.dom] and [arsd.jsvar].

	NOT IMPLEMENTED


	Really, a collection is a resource with a bunch of subresources.

		GET /items
			index because it is GET on the top resource

		GET /items/foo
			item but different than items?

		class Items {

		}

	... but meh, a collection can be automated. not worth making it
	a separate thing, let's look at a real example. Users has many
	items and a virtual one, /users/current.

	the individual users have properties and two sub-resources:
	session, which is just one, and comments, a collection.

	class User : RestObject!() { // no parent
		int id;
		string name;

		// the default implementations of the urlId ones is to call load(that_id) then call the arg-less one.
		// but you can override them to do it differently.

		// any member which is of type RestObject can be linked automatically via href btw.

		void show() {}
		void show(string urlId) {} // automated! GET of this specific thing
		void create() {} // POST on a parent collection - this is called from a collection class after the members are updated
		void replace(string urlId) {} // this is the PUT; really, it just updates all fields.
		void update(string urlId, string[] fieldList) {} // PATCH, it updates some fields.
		void remove(string urlId) {} // DELETE

		void load(string urlId) {} // the default implementation of show() populates the id, then

		this() {}

		mixin Subresource!Session;
		mixin Subresource!Comment;
	}

	class Session : RestObject!() {
		// the parent object may not be fully constructed/loaded
		this(User parent) {}

	}

	class Comment : CollectionOf!Comment {
		this(User parent) {}
	}

	class Users : CollectionOf!User {
		// but you don't strictly need ANYTHING on a collection; it will just... collect. Implement the subobjects.
		void index() {} // GET on this specific thing; just like show really, just different name for the different semantics.
		User create() {} // You MAY implement this, but the default is to create a new object, populate it from args, and then call create() on the child
	}

+/
auto serveRestObject(T)(string urlPrefix) {
	assert(urlPrefix[0] == '/');
	assert(urlPrefix[$ - 1] != '/', "Do NOT use a trailing slash on REST objects.");
	static bool internalHandler(Presenter)(string urlPrefix, Cgi cgi, Presenter presenter, immutable void* details) {
		string url = cgi.pathInfo[urlPrefix.length .. $];

		if(url.length && url[$ - 1] == '/') {
			// remove the final slash...
			cgi.setResponseLocation(cgi.scriptName ~ cgi.pathInfo[0 .. $ - 1]);
			return true;
		}

		return restObjectServeHandler!T(cgi, presenter, url);
	}
	return DispatcherDefinition!internalHandler(urlPrefix, false);
}

/+
/// Convenience method for serving a collection. It will be named the same
/// as type T, just with an s at the end. If you need any further, just
/// write the class yourself.
auto serveRestCollectionOf(T)(string urlPrefix) {
	assert(urlPrefix[0] == '/');
	mixin(`static class `~T.stringof~`s : CollectionOf!(T) {}`);
	return serveRestObject!(mixin(T.stringof ~ "s"))(urlPrefix);
}
+/

bool restObjectServeHandler(T, Presenter)(Cgi cgi, Presenter presenter, string url) {
	string urlId = null;
	if(url.length && url[0] == '/') {
		// asking for a subobject
		urlId = url[1 .. $];
		foreach(idx, ch; urlId) {
			if(ch == '/') {
				urlId = urlId[0 .. idx];
				break;
			}
		}
	}

	// FIXME handle other subresources

	static if(is(T : CollectionOf!(C), C)) {
		if(urlId !is null) {
			return restObjectServeHandler!(C, Presenter)(cgi, presenter, url); // FIXME?  urlId);
		}
	}

	// FIXME: support precondition failed, if-modified-since, expectation failed, etc.

	auto obj = new T();
	obj.initialize(cgi);
	// FIXME: populate reflection info delegates


	// FIXME: I am not happy with this.
	switch(urlId) {
		case "script.js":
			cgi.setResponseContentType("text/javascript");
			cgi.gzipResponse = true;
			cgi.write(presenter.script(), true);
			return true;
		case "style.css":
			cgi.setResponseContentType("text/css");
			cgi.gzipResponse = true;
			cgi.write(presenter.style(), true);
			return true;
		default:
			// intentionally blank
	}




	static void applyChangesTemplate(Obj)(Cgi cgi, Obj obj) {
		foreach(idx, memberName; __traits(derivedMembers, Obj))
		static if(__traits(compiles, __traits(getMember, obj, memberName).offsetof)) {
			__traits(getMember, obj, memberName) = cgi.request(memberName, __traits(getMember, obj, memberName));
		}
	}
	void applyChanges() {
		applyChangesTemplate(cgi, obj);
	}

	string[] modifiedList;

	void writeObject(bool addFormLinks) {
		if(cgi.request("format") == "json") {
			cgi.setResponseContentType("application/json");
			cgi.write(obj.toJson().toString, true);
		} else {
			auto container = presenter.htmlContainer();
			if(addFormLinks) {
				static if(is(T : CollectionOf!(C), C))
				container.appendHtml(`
					<form>
						<button type="submit" name="_method" value="POST">Create New</button>
					</form>
				`);
				else
				container.appendHtml(`
					<a href="..">Back</a>
					<form>
						<button type="submit" name="_method" value="PATCH">Edit</button>
						<button type="submit" name="_method" value="DELETE">Delete</button>
					</form>
				`);
			}
			container.appendChild(obj.toHtml(presenter));
			cgi.write(container.parentDocument.toString, true);
		}
	}

	// FIXME: I think I need a set type in here....
	// it will be nice to pass sets of members.

	try
	switch(cgi.requestMethod) {
		case Cgi.RequestMethod.GET:
			// I could prolly use template this parameters in the implementation above for some reflection stuff.
			// sure, it doesn't automatically work in subclasses... but I instantiate here anyway...

			// automatic forms here for usable basic auto site from browser.
			// even if the format is json, it could actually send out the links and formats, but really there i'ma be meh.
			switch(cgi.request("_method", "GET")) {
				case "GET":
					static if(is(T : CollectionOf!(C), C)) {
						auto results = obj.index();
						if(cgi.request("format", "html") == "html") {
							auto container = presenter.htmlContainer();
							auto html = presenter.formatReturnValueAsHtml(results.results);
							container.appendHtml(`
								<form>
									<button type="submit" name="_method" value="POST">Create New</button>
								</form>
							`);

							container.appendChild(html);
							cgi.write(container.parentDocument.toString, true);
						} else {
							cgi.setResponseContentType("application/json");
							import arsd.jsvar;
							var json = var.emptyArray;
							foreach(r; results.results) {
								var o = var.emptyObject;
								foreach(idx, memberName; __traits(derivedMembers, typeof(r)))
								static if(__traits(compiles, __traits(getMember, r, memberName).offsetof)) {
									o[memberName] = __traits(getMember, r, memberName);
								}

								json ~= o;
							}
							cgi.write(json.toJson(), true);
						}
					} else {
						obj.show(urlId);
						writeObject(true);
					}
				break;
				case "PATCH":
					obj.load(urlId);
				goto case;
				case "PUT":
				case "POST":
					// an editing form for the object
					auto container = presenter.htmlContainer();
					static if(__traits(compiles, () { auto o = new obj.PostProxy(); })) {
						auto form = (cgi.request("_method") == "POST") ? presenter.createAutomaticFormForObject(new obj.PostProxy()) : presenter.createAutomaticFormForObject(obj);
					} else {
						auto form = presenter.createAutomaticFormForObject(obj);
					}
					form.attrs.method = "POST";
					form.setValue("_method", cgi.request("_method", "GET"));
					container.appendChild(form);
					cgi.write(container.parentDocument.toString(), true);
				break;
				case "DELETE":
					// FIXME: a delete form for the object (can be phrased "are you sure?")
					auto container = presenter.htmlContainer();
					container.appendHtml(`
						<form method="POST">
							Are you sure you want to delete this item?
							<input type="hidden" name="_method" value="DELETE" />
							<input type="submit" value="Yes, Delete It" />
						</form>

					`);
					cgi.write(container.parentDocument.toString(), true);
				break;
				default:
					cgi.write("bad method\n", true);
			}
		break;
		case Cgi.RequestMethod.POST:
			// this is to allow compatibility with HTML forms
			switch(cgi.request("_method", "POST")) {
				case "PUT":
					goto PUT;
				case "PATCH":
					goto PATCH;
				case "DELETE":
					goto DELETE;
				case "POST":
					static if(__traits(compiles, () { auto o = new obj.PostProxy(); })) {
						auto p = new obj.PostProxy();
						void specialApplyChanges() {
							applyChangesTemplate(cgi, p);
						}
						string n = p.create(&specialApplyChanges);
					} else {
						string n = obj.create(&applyChanges);
					}

					auto newUrl = cgi.scriptName ~ cgi.pathInfo ~ "/" ~ n;
					cgi.setResponseLocation(newUrl);
					cgi.setResponseStatus("201 Created");
					cgi.write(`The object has been created.`);
				break;
				default:
					cgi.write("bad method\n", true);
			}
			// FIXME this should be valid on the collection, but not the child....
			// 303 See Other
		break;
		case Cgi.RequestMethod.PUT:
		PUT:
			obj.replace(urlId, &applyChanges);
			writeObject(false);
		break;
		case Cgi.RequestMethod.PATCH:
		PATCH:
			obj.update(urlId, &applyChanges, modifiedList);
			writeObject(false);
		break;
		case Cgi.RequestMethod.DELETE:
		DELETE:
			obj.remove(urlId);
			cgi.setResponseStatus("204 No Content");
		break;
		default:
			// FIXME: OPTIONS, HEAD
	}
	catch(Throwable t) {
		presenter.presentExceptionAsHtml!(DUMMY)(cgi, t, null);
	}

	return true;
}

struct DUMMY {}

/+
struct SetOfFields(T) {
	private void[0][string] storage;
	void set(string what) {
		//storage[what] =
	}
	void unset(string what) {}
	void setAll() {}
	void unsetAll() {}
	bool isPresent(string what) { return false; }
}
+/

/+
enum readonly;
enum hideonindex;
+/

/++
	Serves a static file. To be used with [dispatcher].

	See_Also: [serveApi], [serveRestObject], [dispatcher], [serveRedirect]
+/
auto serveStaticFile(string urlPrefix, string filename = null, string contentType = null) {
// https://baus.net/on-tcp_cork/
// man 2 sendfile
	assert(urlPrefix[0] == '/');
	if(filename is null)
		filename = decodeComponent(urlPrefix[1 .. $]); // FIXME is this actually correct?
	if(contentType is null) {
		contentType = contentTypeFromFileExtension(filename);
	}

	static struct DispatcherDetails {
		string filename;
		string contentType;
	}

	static bool internalHandler(string urlPrefix, Cgi cgi, Object presenter, DispatcherDetails details) {
		if(details.contentType.indexOf("image/") == 0)
			cgi.setCache(true);
		cgi.setResponseContentType(details.contentType);
		cgi.write(std.file.read(details.filename), true);
		return true;
	}
	return DispatcherDefinition!(internalHandler, DispatcherDetails)(urlPrefix, true, DispatcherDetails(filename, contentType));
}

/++
	Serves static data. To be used with [dispatcher].

	History:
		Added October 31, 2021
+/
auto serveStaticData(string urlPrefix, immutable(void)[] data, string contentType = null) {
	assert(urlPrefix[0] == '/');
	if(contentType is null) {
		contentType = contentTypeFromFileExtension(urlPrefix);
	}

	static struct DispatcherDetails {
		immutable(void)[] data;
		string contentType;
	}

	static bool internalHandler(string urlPrefix, Cgi cgi, Object presenter, DispatcherDetails details) {
		cgi.setCache(true);
		cgi.setResponseContentType(details.contentType);
		cgi.write(details.data, true);
		return true;
	}
	return DispatcherDefinition!(internalHandler, DispatcherDetails)(urlPrefix, true, DispatcherDetails(data, contentType));
}

string contentTypeFromFileExtension(string filename) {
		if(filename.endsWith(".png"))
			return "image/png";
		if(filename.endsWith(".apng"))
			return "image/apng";
		if(filename.endsWith(".svg"))
			return "image/svg+xml";
		if(filename.endsWith(".jpg"))
			return "image/jpeg";
		if(filename.endsWith(".html"))
			return "text/html";
		if(filename.endsWith(".css"))
			return "text/css";
		if(filename.endsWith(".js"))
			return "application/javascript";
		if(filename.endsWith(".wasm"))
			return "application/wasm";
		if(filename.endsWith(".mp3"))
			return "audio/mpeg";
		return null;
}

/// This serves a directory full of static files, figuring out the content-types from file extensions.
/// It does not let you to descend into subdirectories (or ascend out of it, of course)
auto serveStaticFileDirectory(string urlPrefix, string directory = null) {
	assert(urlPrefix[0] == '/');
	assert(urlPrefix[$-1] == '/');

	static struct DispatcherDetails {
		string directory;
	}

	if(directory is null)
		directory = urlPrefix[1 .. $];

	assert(directory[$-1] == '/');

	static bool internalHandler(string urlPrefix, Cgi cgi, Object presenter, DispatcherDetails details) {
		auto file = decodeComponent(cgi.pathInfo[urlPrefix.length .. $]); // FIXME: is this actually correct
		if(file.indexOf("/") != -1 || file.indexOf("\\") != -1)
			return false;

		auto contentType = contentTypeFromFileExtension(file);

		auto fn = details.directory ~ file;
		if(std.file.exists(fn)) {
			//if(contentType.indexOf("image/") == 0)
				//cgi.setCache(true);
			//else if(contentType.indexOf("audio/") == 0)
				cgi.setCache(true);
			cgi.setResponseContentType(contentType);
			cgi.write(std.file.read(fn), true);
			return true;
		} else {
			return false;
		}
	}

	return DispatcherDefinition!(internalHandler, DispatcherDetails)(urlPrefix, false, DispatcherDetails(directory));
}

/++
	Redirects one url to another

	See_Also: [dispatcher], [serveStaticFile]
+/
auto serveRedirect(string urlPrefix, string redirectTo, int code = 303) {
	assert(urlPrefix[0] == '/');
	static struct DispatcherDetails {
		string redirectTo;
		string code;
	}

	static bool internalHandler(string urlPrefix, Cgi cgi, Object presenter, DispatcherDetails details) {
		cgi.setResponseLocation(details.redirectTo, true, details.code);
		return true;
	}


	return DispatcherDefinition!(internalHandler, DispatcherDetails)(urlPrefix, true, DispatcherDetails(redirectTo, getHttpCodeText(code)));
}

/// Used exclusively with `dispatchTo`
struct DispatcherData(Presenter) {
	Cgi cgi; /// You can use this cgi object.
	Presenter presenter; /// This is the presenter from top level, and will be forwarded to the sub-dispatcher.
	size_t pathInfoStart; /// This is forwarded to the sub-dispatcher. It may be marked private later, or at least read-only.
}

/++
	Dispatches the URL to a specific function.
+/
auto handleWith(alias handler)(string urlPrefix) {
	// cuz I'm too lazy to do it better right now
	static class Hack : WebObject {
		static import std.traits;
		@UrlName("")
		auto handle(std.traits.Parameters!handler args) {
			return handler(args);
		}
	}

	return urlPrefix.serveApiInternal!Hack;
}

/++
	Dispatches the URL (and anything under it) to another dispatcher function. The function should look something like this:

	---
	bool other(DD)(DD dd) {
		return dd.dispatcher!(
			"/whatever".serveRedirect("/success"),
			"/api/".serveApi!MyClass
		);
	}
	---

	The `DD` in there will be an instance of [DispatcherData] which you can inspect, or forward to another dispatcher
	here. It is a template to account for any Presenter type, so you can do compile-time analysis in your presenters.
	Or, of course, you could just use the exact type in your own code.

	You return true if you handle the given url, or false if not. Just returning the result of [dispatcher] will do a
	good job.


+/
auto dispatchTo(alias handler)(string urlPrefix) {
	assert(urlPrefix[0] == '/');
	assert(urlPrefix[$-1] != '/');
	static bool internalHandler(Presenter)(string urlPrefix, Cgi cgi, Presenter presenter, const void* details) {
		return handler(DispatcherData!Presenter(cgi, presenter, urlPrefix.length));
	}

	return DispatcherDefinition!(internalHandler)(urlPrefix, false);
}

/+
/++
	See [serveStaticFile] if you want to serve a file off disk.
+/
auto serveStaticData(string urlPrefix, const(void)[] data, string contentType) {

}
+/

/++
	A URL dispatcher.

	---
	if(cgi.dispatcher!(
		"/api/".serveApi!MyApiClass,
		"/objects/lol".serveRestObject!MyRestObject,
		"/file.js".serveStaticFile,
		"/admin/".dispatchTo!adminHandler
	)) return;
	---


	You define a series of url prefixes followed by handlers.

	[dispatchTo] will send the request to another function for handling.
	You may want to do different pre- and post- processing there, for example,
	an authorization check and different page layout. You can use different
	presenters and different function chains. NOT IMPLEMENTED
+/
template dispatcher(definitions...) {
	bool dispatcher(Presenter)(Cgi cgi, Presenter presenterArg = null) {
		static if(is(Presenter == typeof(null))) {
			static class GenericWebPresenter : WebPresenter!(GenericWebPresenter) {}
			auto presenter = new GenericWebPresenter();
		} else
			alias presenter = presenterArg;

		return dispatcher(DispatcherData!(typeof(presenter))(cgi, presenter, 0));
	}

	bool dispatcher(DispatcherData)(DispatcherData dispatcherData) if(!is(DispatcherData : Cgi)) {
		// I can prolly make this more efficient later but meh.
		foreach(definition; definitions) {
			if(definition.rejectFurther) {
				if(dispatcherData.cgi.pathInfo[dispatcherData.pathInfoStart .. $] == definition.urlPrefix) {
					auto ret = definition.handler(
						dispatcherData.cgi.pathInfo[0 .. dispatcherData.pathInfoStart + definition.urlPrefix.length],
						dispatcherData.cgi, dispatcherData.presenter, definition.details);
					if(ret)
						return true;
				}
			} else if(
				dispatcherData.cgi.pathInfo[dispatcherData.pathInfoStart .. $].startsWith(definition.urlPrefix) &&
				// cgi.d dispatcher urls must be complete or have a /;
				// "foo" -> thing should NOT match "foobar", just "foo" or "foo/thing"
				(definition.urlPrefix[$-1] == '/' || (dispatcherData.pathInfoStart + definition.urlPrefix.length) == dispatcherData.cgi.pathInfo.length
				|| dispatcherData.cgi.pathInfo[dispatcherData.pathInfoStart + definition.urlPrefix.length] == '/')
				) {
				auto ret = definition.handler(
					dispatcherData.cgi.pathInfo[0 .. dispatcherData.pathInfoStart + definition.urlPrefix.length],
					dispatcherData.cgi, dispatcherData.presenter, definition.details);
				if(ret)
					return true;
			}
		}
		return false;
	}
}

});

private struct StackBuffer {
	char[1024] initial = void;
	char[] buffer;
	size_t position;

	this(int a) {
		buffer = initial[];
		position = 0;
	}

	void add(in char[] what) {
		if(position + what.length > buffer.length)
			buffer.length = position + what.length + 1024; // reallocate with GC to handle special cases
		buffer[position .. position + what.length] = what[];
		position += what.length;
	}

	void add(in char[] w1, in char[] w2, in char[] w3 = null) {
		add(w1);
		add(w2);
		add(w3);
	}

	void add(long v) {
		char[16] buffer = void;
		auto pos = buffer.length;
		bool negative;
		if(v < 0) {
			negative = true;
			v = -v;
		}
		do {
			buffer[--pos] = cast(char) (v % 10 + '0');
			v /= 10;
		} while(v);

		if(negative)
			buffer[--pos] = '-';

		auto res = buffer[pos .. $];

		add(res[]);
	}

	char[] get() @nogc {
		return buffer[0 .. position];
	}
}

// duplicated in http2.d
private static string getHttpCodeText(int code) pure nothrow @nogc {
	switch(code) {
		case 200: return "200 OK";
		case 201: return "201 Created";
		case 202: return "202 Accepted";
		case 203: return "203 Non-Authoritative Information";
		case 204: return "204 No Content";
		case 205: return "205 Reset Content";
		case 206: return "206 Partial Content";
		//
		case 300: return "300 Multiple Choices";
		case 301: return "301 Moved Permanently";
		case 302: return "302 Found";
		case 303: return "303 See Other";
		case 304: return "304 Not Modified";
		case 305: return "305 Use Proxy";
		case 307: return "307 Temporary Redirect";
		case 308: return "308 Permanent Redirect";

		//
		case 400: return "400 Bad Request";
		case 401: return "401 Unauthorized";
		case 402: return "402 Payment Required";
		case 403: return "403 Forbidden";
		case 404: return "404 Not Found";
		case 405: return "405 Method Not Allowed";
		case 406: return "406 Not Acceptable";
		case 407: return "407 Proxy Authentication Required";
		case 408: return "408 Request Timeout";
		case 409: return "409 Conflict";
		case 410: return "410 Gone";
		case 411: return "411 Length Required";
		case 412: return "412 Precondition Failed";
		case 413: return "413 Payload Too Large";
		case 414: return "414 URI Too Long";
		case 415: return "415 Unsupported Media Type";
		case 416: return "416 Range Not Satisfiable";
		case 417: return "417 Expectation Failed";
		case 418: return "418 I'm a teapot";
		case 421: return "421 Misdirected Request";
		case 422: return "422 Unprocessable Entity (WebDAV)";
		case 423: return "423 Locked (WebDAV)";
		case 424: return "424 Failed Dependency (WebDAV)";
		case 425: return "425 Too Early";
		case 426: return "426 Upgrade Required";
		case 428: return "428 Precondition Required";
		case 431: return "431 Request Header Fields Too Large";
		case 451: return "451 Unavailable For Legal Reasons";

		case 500: return "500 Internal Server Error";
		case 501: return "501 Not Implemented";
		case 502: return "502 Bad Gateway";
		case 503: return "503 Service Unavailable";
		case 504: return "504 Gateway Timeout";
		case 505: return "505 HTTP Version Not Supported";
		case 506: return "506 Variant Also Negotiates";
		case 507: return "507 Insufficient Storage (WebDAV)";
		case 508: return "508 Loop Detected (WebDAV)";
		case 510: return "510 Not Extended";
		case 511: return "511 Network Authentication Required";
		//
		default: assert(0, "Unsupported http code");
	}
}


/+
/++
	This is the beginnings of my web.d 2.0 - it dispatches web requests to a class object.

	It relies on jsvar.d and dom.d.


	You can get javascript out of it to call. The generated functions need to look
	like

	function name(a,b,c,d,e) {
		return _call("name", {"realName":a,"sds":b});
	}

	And _call returns an object you can call or set up or whatever.
+/
bool apiDispatcher()(Cgi cgi) {
	import arsd.jsvar;
	import arsd.dom;
}
+/
version(linux)
private extern(C) int eventfd (uint initval, int flags) nothrow @trusted @nogc;
/*
Copyright: Adam D. Ruppe, 2008 - 2022
License:   [http://www.boost.org/LICENSE_1_0.txt|Boost License 1.0].
Authors: Adam D. Ruppe

	Copyright Adam D. Ruppe 2008 - 2022.
Distributed under the Boost Software License, Version 1.0.
   (See accompanying file LICENSE_1_0.txt or copy at
	http://www.boost.org/LICENSE_1_0.txt)
*/
