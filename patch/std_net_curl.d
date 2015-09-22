// Written in the D programming language.

/**
Networking client functionality as provided by $(WEB _curl.haxx.se/libcurl,
libcurl). The libcurl library must be installed on the system in order to use
this module.

$(SCRIPT inhibitQuickIndex = 1;)

$(DIVC quickindex,
$(BOOKTABLE ,
$(TR $(TH Category) $(TH Functions)
)
$(TR $(TDNW High level) $(TD $(MYREF download) $(MYREF upload) $(MYREF get)
$(MYREF post) $(MYREF put) $(MYREF del) $(MYREF options) $(MYREF trace)
$(MYREF connect) $(MYREF byLine) $(MYREF byChunk)
$(MYREF byLineAsync) $(MYREF byChunkAsync) )
)
$(TR $(TDNW Low level) $(TD $(MYREF HTTP) $(MYREF FTP) $(MYREF
SMTP) )
)
)
)

Note:
You may need to link to the $(B curl) library, e.g. by adding $(D "libs": ["curl"])
to your $(B dub.json) file if you are using $(LINK2 http://code.dlang.org, DUB).

Windows x86 note:
A DMD compatible libcurl static library can be downloaded from the dlang.org
$(LINK2 http://dlang.org/download.html, download page).

Compared to using libcurl directly this module allows simpler client code for
common uses, requires no unsafe operations, and integrates better with the rest
of the language. Futhermore it provides <a href="std_range.html">$(D range)</a>
access to protocols supported by libcurl both synchronously and asynchronously.

A high level and a low level API are available. The high level API is built
entirely on top of the low level one.

The high level API is for commonly used functionality such as HTTP/FTP get. The
$(LREF byLineAsync) and $(LREF byChunkAsync) provides asynchronous <a
href="std_range.html">$(D ranges)</a> that performs the request in another
thread while handling a line/chunk in the current thread.

The low level API allows for streaming and other advanced features.

$(BOOKTABLE Cheat Sheet,
$(TR $(TH Function Name) $(TH Description)
)
$(LEADINGROW High level)
$(TR $(TDNW $(LREF download)) $(TD $(D
download("ftp.digitalmars.com/sieve.ds", "/tmp/downloaded-ftp-file"))
downloads file from URL to file system.)
)
$(TR $(TDNW $(LREF upload)) $(TD $(D
upload("/tmp/downloaded-ftp-file", "ftp.digitalmars.com/sieve.ds");)
uploads file from file system to URL.)
)
$(TR $(TDNW $(LREF get)) $(TD $(D
get("dlang.org")) returns a char[] containing the dlang.org web page.)
)
$(TR $(TDNW $(LREF put)) $(TD $(D
put("dlang.org", "Hi")) returns a char[] containing
the dlang.org web page. after a HTTP PUT of "hi")
)
$(TR $(TDNW $(LREF post)) $(TD $(D
post("dlang.org", "Hi")) returns a char[] containing
the dlang.org web page. after a HTTP POST of "hi")
)
$(TR $(TDNW $(LREF byLine)) $(TD $(D
byLine("dlang.org")) returns a range of char[] containing the
dlang.org web page.)
)
$(TR $(TDNW $(LREF byChunk)) $(TD $(D
byChunk("dlang.org", 10)) returns a range of ubyte[10] containing the
dlang.org web page.)
)
$(TR $(TDNW $(LREF byLineAsync)) $(TD $(D
byLineAsync("dlang.org")) returns a range of char[] containing the dlang.org web
 page asynchronously.)
)
$(TR $(TDNW $(LREF byChunkAsync)) $(TD $(D
byChunkAsync("dlang.org", 10)) returns a range of ubyte[10] containing the
dlang.org web page asynchronously.)
)
$(LEADINGROW Low level
)
$(TR $(TDNW $(LREF HTTP)) $(TD $(D HTTP) struct for advanced usage))
$(TR $(TDNW $(LREF FTP)) $(TD $(D FTP) struct for advanced usage))
$(TR $(TDNW $(LREF SMTP)) $(TD $(D SMTP) struct for advanced usage))
)


Example:
---
import std.net.curl, std.stdio;

// Return a char[] containing the content specified by an URL
auto content = get("dlang.org");

// Post data and return a char[] containing the content specified by an URL
auto content = post("mydomain.com/here.cgi", "post data");

// Get content of file from ftp server
auto content = get("ftp.digitalmars.com/sieve.ds");

// Post and print out content line by line. The request is done in another thread.
foreach (line; byLineAsync("dlang.org", "Post data"))
    writeln(line);

// Get using a line range and proxy settings
auto client = HTTP();
client.proxy = "1.2.3.4";
foreach (line; byLine("dlang.org", client))
    writeln(line);
---

For more control than the high level functions provide, use the low level API:

Example:
---
import std.net.curl, std.stdio;

// GET with custom data receivers
auto http = HTTP("dlang.org");
http.onReceiveHeader =
    (in char[] key, in char[] value) { writeln(key, ": ", value); };
http.onReceive = (ubyte[] data) { /+ drop +/ return data.length; };
http.perform();
---

First, an instance of the reference-counted HTTP struct is created. Then the
custom delegates are set. These will be called whenever the HTTP instance
receives a header and a data buffer, respectively. In this simple example, the
headers are written to stdout and the data is ignored. If the request should be
stopped before it has finished then return something less than data.length from
the onReceive callback. See $(LREF onReceiveHeader)/$(LREF onReceive) for more
information. Finally the HTTP request is effected by calling perform(), which is
synchronous.

Source: $(PHOBOSSRC std/net/_curl.d)

Copyright: Copyright Jonas Drewsen 2011-2012
License: $(WEB www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
Authors: Jonas Drewsen. Some of the SMTP code contributed by Jimmy Cao.

Credits: The functionally is based on $(WEB _curl.haxx.se/libcurl, libcurl).
         LibCurl is licensed under an MIT/X derivative license.
*/
/*
         Copyright Jonas Drewsen 2011 - 2012.
Distributed under the Boost Software License, Version 1.0.
   (See accompanying file LICENSE_1_0.txt or copy at
         http://www.boost.org/LICENSE_1_0.txt)
*/
module std.net.curl;

import core.thread;
import etc.c.curl;
import std.algorithm;
import std.array;
import std.concurrency;
import std.conv;
import std.datetime;
import std.encoding;
import std.exception;
import std.regex;
import std.socket : InternetAddress;
import std.stdio;
import std.string;
import std.traits;
import std.typecons;
import std.typetuple;

import std.internal.cstring;

public import etc.c.curl : CurlOption;

version(unittest)
{
    // Run unit test with the PHOBOS_TEST_ALLOW_NET=1 set in order to
    // allow net traffic
    import std.stdio;
    import std.range;
    import std.process : environment;
    import std.file : tempDir;
    import std.path : buildPath;

    import std.socket : Address, INADDR_LOOPBACK, Socket, TcpSocket;

    private struct TestServer
    {
        string addr() { return _addr; }

        void handle(void function(Socket s) dg)
        {
            tid.send(dg);
        }

    private:
        string _addr;
        Tid tid;

        static void loop(shared TcpSocket listener)
        {
            try while (true)
            {
                void function(Socket) handler = void;
                try
                    handler = receiveOnly!(typeof(handler));
                catch (OwnerTerminated)
                    return;
                handler((cast()listener).accept);
            }
            catch (Throwable e)
            {
                import core.stdc.stdlib : exit, EXIT_FAILURE;
                stderr.writeln(e);
                exit(EXIT_FAILURE); // Bugzilla 7018
            }
        }
    }

    private TestServer startServer()
    {
        auto sock = new TcpSocket;
        sock.bind(new InternetAddress(INADDR_LOOPBACK, InternetAddress.PORT_ANY));
        sock.listen(1);
        auto addr = sock.localAddress.toString();
        auto tid = spawn(&TestServer.loop, cast(shared)sock);
        return TestServer(addr, tid);
    }

    private ref TestServer testServer()
    {
        __gshared TestServer server;
        return initOnce!server(startServer());
    }

    private struct Request(T)
    {
        string hdrs;
        immutable(T)[] bdy;
    }

    private Request!T recvReq(T=char)(Socket s)
    {
        ubyte[1024] tmp=void;
        ubyte[] buf;

        while (true)
        {
            auto nbytes = s.receive(tmp[]);
            assert(nbytes >= 0);

            immutable beg = buf.length > 3 ? buf.length - 3 : 0;
            buf ~= tmp[0 .. nbytes];
            auto bdy = buf[beg .. $].find(cast(ubyte[])"\r\n\r\n");
            if (bdy.empty)
                continue;

            auto hdrs = cast(string)buf[0 .. $ - bdy.length];
            bdy.popFrontN(4);
            // no support for chunked transfer-encoding
            if (auto m = hdrs.matchFirst(ctRegex!(`Content-Length: ([0-9]+)`, "i")))
            {
                import std.uni : asUpperCase;
                if (hdrs.asUpperCase.canFind("EXPECT: 100-CONTINUE"))
                    s.send(httpContinue);

                size_t remain = m.captures[1].to!size_t - bdy.length;
                while (remain)
                {
                    nbytes = s.receive(tmp[0 .. min(remain, $)]);
                    assert(nbytes >= 0);
                    buf ~= tmp[0 .. nbytes];
                    remain -= nbytes;
                }
            }
            else
            {
                assert(bdy.empty);
            }
            bdy = buf[hdrs.length + 4 .. $];
            return typeof(return)(hdrs, cast(immutable(T)[])bdy);
        }
    }

    private string httpOK(string msg)
    {
        return "HTTP/1.1 200 OK\r\n"~
            "Content-Type: text/plain\r\n"~
            "Content-Length: "~msg.length.to!string~"\r\n"
            "\r\n"~
            msg;
    }

    private string httpOK()
    {
        return "HTTP/1.1 200 OK\r\n"~
            "Content-Length: 0\r\n"~
            "\r\n";
    }

    private string httpNotFound()
    {
        return "HTTP/1.1 404 Not Found\r\n"~
            "Content-Length: 0\r\n"~
            "\r\n";
    }

    private enum httpContinue = "HTTP/1.1 100 Continue\r\n\r\n";
}
version(StdDdoc) import std.stdio;

extern (C) void exit(int);

// Default data timeout for Protocols
private enum _defaultDataTimeout = dur!"minutes"(2);

/**
Macros:

CALLBACK_PARAMS = $(TABLE ,
    $(DDOC_PARAM_ROW
        $(DDOC_PARAM_ID $(DDOC_PARAM dlTotal))
        $(DDOC_PARAM_DESC total bytes to download)
        )
    $(DDOC_PARAM_ROW
        $(DDOC_PARAM_ID $(DDOC_PARAM dlNow))
        $(DDOC_PARAM_DESC currently downloaded bytes)
        )
    $(DDOC_PARAM_ROW
        $(DDOC_PARAM_ID $(DDOC_PARAM ulTotal))
        $(DDOC_PARAM_DESC total bytes to upload)
        )
    $(DDOC_PARAM_ROW
        $(DDOC_PARAM_ID $(DDOC_PARAM ulNow))
        $(DDOC_PARAM_DESC currently uploaded bytes)
        )
)
*/

/** Connection type used when the URL should be used to auto detect the protocol.
  *
  * This struct is used as placeholder for the connection parameter when calling
  * the high level API and the connection type (HTTP/FTP) should be guessed by
  * inspecting the URL parameter.
  *
  * The rules for guessing the protocol are:
  * 1, if URL starts with ftp://, ftps:// or ftp. then FTP connection is assumed.
  * 2, HTTP connection otherwise.
  *
  * Example:
  * ---
  * import std.net.curl;
  * // Two requests below will do the same.
  * string content;
  *
  * // Explicit connection provided
  * content = get!HTTP("dlang.org");
  *
  * // Guess connection type by looking at the URL
  * content = get!AutoProtocol("ftp://foo.com/file");
  * // and since AutoProtocol is default this is the same as
  * connect = get("ftp://foo.com/file");
  * // and will end up detecting FTP from the url and be the same as
  * connect = get!FTP("ftp://foo.com/file");
  * ---
  */
struct AutoProtocol { }

// Returns true if the url points to an FTP resource
private bool isFTPUrl(const(char)[] url)
{
    return startsWith(url.toLower(), "ftp://", "ftps://", "ftp.") != 0;
}

// Is true if the Conn type is a valid Curl Connection type.
private template isCurlConn(Conn)
{
    enum auto isCurlConn = is(Conn : HTTP) ||
        is(Conn : FTP) || is(Conn : AutoProtocol);
}

/** HTTP/FTP download to local file system.
 *
 * Params:
 * url = resource to download
 * saveToPath = path to store the downloaded content on local disk
 * conn = connection to use e.g. FTP or HTTP. The default AutoProtocol will
 *        guess connection type and create a new instance for this call only.
 *
 * Example:
 * ----
 * import std.net.curl;
 * download("d-lang.appspot.com/testUrl2", "/tmp/downloaded-http-file");
 * ----
 */
void download(Conn = AutoProtocol)(const(char)[] url, string saveToPath, Conn conn = Conn())
    if (isCurlConn!Conn)
{
    static if (is(Conn : HTTP) || is(Conn : FTP))
    {
        import std.stdio : File;
        conn.url = url;
        auto f = File(saveToPath, "wb");
        conn.onReceive = (ubyte[] data) { f.rawWrite(data); return data.length; };
        conn.perform();
    }
    else
    {
        if (isFTPUrl(url))
            return download!FTP(url, saveToPath, FTP());
        else
            return download!HTTP(url, saveToPath, HTTP());
    }
}

unittest
{
    foreach (host; [testServer.addr, "http://"~testServer.addr])
    {
        testServer.handle((s) {
            assert(s.recvReq.hdrs.canFind("GET /"));
            s.send(httpOK("Hello world"));
        });
        auto fn = buildPath(tempDir(), "downloaded-http-file");
        scope (exit) std.file.remove(fn);
        download(host, fn);
        assert(std.file.readText(fn) == "Hello world");
    }
}

/** Upload file from local files system using the HTTP or FTP protocol.
 *
 * Params:
 * loadFromPath = path load data from local disk.
 * url = resource to upload to
 * conn = connection to use e.g. FTP or HTTP. The default AutoProtocol will
 *        guess connection type and create a new instance for this call only.
 *
 * Example:
 * ----
 * import std.net.curl;
 * upload("/tmp/downloaded-ftp-file", "ftp.digitalmars.com/sieve.ds");
 * upload("/tmp/downloaded-http-file", "d-lang.appspot.com/testUrl2");
 * ----
 */
void upload(Conn = AutoProtocol)(string loadFromPath, const(char)[] url, Conn conn = Conn())
    if (isCurlConn!Conn)
{
    static if (is(Conn : HTTP))
    {
        conn.url = url;
        conn.method = HTTP.Method.put;
    }
    else static if (is(Conn : FTP))
    {
        conn.url = url;
        conn.handle.set(CurlOption.upload, 1L);
    }
    else
    {
        if (isFTPUrl(url))
            return upload!FTP(loadFromPath, url, FTP());
        else
            return upload!HTTP(loadFromPath, url, HTTP());
    }

    static if (is(Conn : HTTP) || is(Conn : FTP))
    {
        auto f = File(loadFromPath, "rb");
        conn.onSend = buf => f.rawRead(buf).length;
        auto sz = f.size;
        if (sz != ulong.max)
            conn.contentLength = sz;
        conn.perform();
    }
}

unittest
{
    foreach (host; [testServer.addr, "http://"~testServer.addr])
    {
        auto fn = buildPath(tempDir(), "downloaded-http-file");
        scope (exit) std.file.remove(fn);
        std.file.write(fn, "upload data\n");
        testServer.handle((s) {
            auto req = s.recvReq;
            assert(req.hdrs.canFind("PUT /path"));
            assert(req.bdy.canFind("upload data"));
            s.send(httpOK());
        });
        upload(fn, host ~ "/path");
    }
}

/** HTTP/FTP get content.
 *
 * Params:
 * url = resource to get
 * conn = connection to use e.g. FTP or HTTP. The default AutoProtocol will
 *        guess connection type and create a new instance for this call only.
 *
 * The template parameter $(D T) specifies the type to return. Possible values
 * are $(D char) and $(D ubyte) to return $(D char[]) or $(D ubyte[]). If asking
 * for $(D char), content will be converted from the connection character set
 * (specified in HTTP response headers or FTP connection properties, both ISO-8859-1
 * by default) to UTF-8.
 *
 * Example:
 * ----
 * import std.net.curl;
 * auto content = get("d-lang.appspot.com/testUrl2");
 * ----
 *
 * Returns:
 * A T[] range containing the content of the resource pointed to by the URL.
 *
 * Throws:
 *
 * $(D CurlException) on error.
 *
 * See_Also: $(LREF HTTP.Method)
 */
T[] get(Conn = AutoProtocol, T = char)(const(char)[] url, Conn conn = Conn())
    if ( isCurlConn!Conn && (is(T == char) || is(T == ubyte)) )
{
    static if (is(Conn : HTTP))
    {
        conn.method = HTTP.Method.get;
        return _basicHTTP!(T)(url, "", conn);

    }
    else static if (is(Conn : FTP))
    {
        return _basicFTP!(T)(url, "", conn);
    }
    else
    {
        if (isFTPUrl(url))
            return get!(FTP,T)(url, FTP());
        else
            return get!(HTTP,T)(url, HTTP());
    }
}

unittest
{
    foreach (host; [testServer.addr, "http://"~testServer.addr])
    {
        testServer.handle((s) {
            assert(s.recvReq.hdrs.canFind("GET /path"));
            s.send(httpOK("GETRESPONSE"));
        });
        auto res = get(host ~ "/path");
        assert(res == "GETRESPONSE");
    }
}


/** HTTP post content.
 *
 * Params:
 * url = resource to post to
 * postData = data to send as the body of the request. An array
 *            of an arbitrary type is accepted and will be cast to ubyte[]
 *            before sending it.
 * conn = HTTP connection to use
 *
 * The template parameter $(D T) specifies the type to return. Possible values
 * are $(D char) and $(D ubyte) to return $(D char[]) or $(D ubyte[]). If asking
 * for $(D char), content will be converted from the connection character set
 * (specified in HTTP response headers or FTP connection properties, both ISO-8859-1
 * by default) to UTF-8.
 *
 * Example:
 * ----
 * import std.net.curl;
 * auto content = post("d-lang.appspot.com/testUrl2", [1,2,3,4]);
 * ----
 *
 * Returns:
 * A T[] range containing the content of the resource pointed to by the URL.
 *
 * See_Also: $(LREF HTTP.Method)
 */
T[] post(T = char, PostUnit)(const(char)[] url, const(PostUnit)[] postData, HTTP conn = HTTP())
if (is(T == char) || is(T == ubyte))
{
    conn.method = HTTP.Method.post;
    return _basicHTTP!(T)(url, postData, conn);
}

unittest
{
    foreach (host; [testServer.addr, "http://"~testServer.addr])
    {
        testServer.handle((s) {
            auto req = s.recvReq;
            assert(req.hdrs.canFind("POST /path"));
            assert(req.bdy.canFind("POSTBODY"));
            s.send(httpOK("POSTRESPONSE"));
        });
        auto res = post(host ~ "/path", "POSTBODY");
        assert(res == "POSTRESPONSE");
    }
}

unittest
{
    auto data = new ubyte[](256);
    foreach (i, ref ub; data)
        ub = cast(ubyte)i;

    testServer.handle((s) {
        auto req = s.recvReq!ubyte;
        assert(req.bdy.canFind(cast(ubyte[])[0, 1, 2, 3, 4]));
        assert(req.bdy.canFind(cast(ubyte[])[253, 254, 255]));
        s.send(httpOK(cast(ubyte[])[17, 27, 35, 41]));
    });
    auto res = post!ubyte(testServer.addr, data);
    assert(res == cast(ubyte[])[17, 27, 35, 41]);
}


/** HTTP/FTP put content.
 *
 * Params:
 * url = resource to put
 * putData = data to send as the body of the request. An array
 *           of an arbitrary type is accepted and will be cast to ubyte[]
 *           before sending it.
 * conn = connection to use e.g. FTP or HTTP. The default AutoProtocol will
 *        guess connection type and create a new instance for this call only.
 *
 * The template parameter $(D T) specifies the type to return. Possible values
 * are $(D char) and $(D ubyte) to return $(D char[]) or $(D ubyte[]). If asking
 * for $(D char), content will be converted from the connection character set
 * (specified in HTTP response headers or FTP connection properties, both ISO-8859-1
 * by default) to UTF-8.
 *
 * Example:
 * ----
 * import std.net.curl;
 * auto content = put("d-lang.appspot.com/testUrl2",
 *                      "Putting this data");
 * ----
 *
 * Returns:
 * A T[] range containing the content of the resource pointed to by the URL.
 *
 * See_Also: $(LREF HTTP.Method)
 */
T[] put(Conn = AutoProtocol, T = char, PutUnit)(const(char)[] url, const(PutUnit)[] putData,
                                                  Conn conn = Conn())
    if ( isCurlConn!Conn && (is(T == char) || is(T == ubyte)) )
{
    static if (is(Conn : HTTP))
    {
        conn.method = HTTP.Method.put;
        return _basicHTTP!(T)(url, putData, conn);
    }
    else static if (is(Conn : FTP))
    {
        return _basicFTP!(T)(url, putData, conn);
    }
    else
    {
        if (isFTPUrl(url))
            return put!(FTP,T)(url, putData, FTP());
        else
            return put!(HTTP,T)(url, putData, HTTP());
    }
}

unittest
{
    foreach (host; [testServer.addr, "http://"~testServer.addr])
    {
        testServer.handle((s) {
            auto req = s.recvReq;
            assert(req.hdrs.canFind("PUT /path"));
            assert(req.bdy.canFind("PUTBODY"));
            s.send(httpOK("PUTRESPONSE"));
        });
        auto res = put(host ~ "/path", "PUTBODY");
        assert(res == "PUTRESPONSE");
    }
}


/** HTTP/FTP delete content.
 *
 * Params:
 * url = resource to delete
 * conn = connection to use e.g. FTP or HTTP. The default AutoProtocol will
 *        guess connection type and create a new instance for this call only.
 *
 * Example:
 * ----
 * import std.net.curl;
 * del("d-lang.appspot.com/testUrl2");
 * ----
 *
 * See_Also: $(LREF HTTP.Method)
 */
void del(Conn = AutoProtocol)(const(char)[] url, Conn conn = Conn())
    if (isCurlConn!Conn)
{
    static if (is(Conn : HTTP))
    {
        conn.method = HTTP.Method.del;
        _basicHTTP!char(url, cast(void[]) null, conn);
    }
    else static if (is(Conn : FTP))
    {
        auto trimmed = url.findSplitAfter("ftp://")[1];
        auto t = trimmed.findSplitAfter("/");
        enum minDomainNameLength = 3;
        enforce!CurlException(t[0].length > minDomainNameLength,
                                text("Invalid FTP URL for delete ", url));
        conn.url = t[0];

        enforce!CurlException(!t[1].empty,
                                text("No filename specified to delete for URL ", url));
        conn.addCommand("DELE " ~ t[1]);
        conn.perform();
    }
    else
    {
        if (isFTPUrl(url))
            return del!FTP(url, FTP());
        else
            return del!HTTP(url, HTTP());
    }
}

unittest
{
    foreach (host; [testServer.addr, "http://"~testServer.addr])
    {
        testServer.handle((s) {
            auto req = s.recvReq;
            assert(req.hdrs.canFind("DELETE /path"));
            s.send(httpOK());
        });
        del(host ~ "/path");
    }
}


/** HTTP options request.
 *
 * Params:
 * url = resource make a option call to
 * conn = connection to use e.g. FTP or HTTP. The default AutoProtocol will
 *        guess connection type and create a new instance for this call only.
 *
 * The template parameter $(D T) specifies the type to return. Possible values
 * are $(D char) and $(D ubyte) to return $(D char[]) or $(D ubyte[]).
 *
 * Example:
 * ----
 * import std.net.curl;
 * auto http = HTTP();
 * options("d-lang.appspot.com/testUrl2", http);
 * writeln("Allow set to " ~ http.responseHeaders["Allow"]);
 * ----
 *
 * Returns:
 * A T[] range containing the options of the resource pointed to by the URL.
 *
 * See_Also: $(LREF HTTP.Method)
 */
T[] options(T = char)(const(char)[] url, HTTP conn = HTTP())
    if (is(T == char) || is(T == ubyte))
{
    conn.method = HTTP.Method.options;
    return _basicHTTP!(T)(url, null, conn);
}

deprecated("options does not send any data")
T[] options(T = char, OptionsUnit)(const(char)[] url,
                                   const(OptionsUnit)[] optionsData = null,
                                   HTTP conn = HTTP())
    if (is(T == char) || is(T == ubyte))
{
    return options!T(url, conn);
}

unittest
{
    testServer.handle((s) {
        auto req = s.recvReq;
        assert(req.hdrs.canFind("OPTIONS /path"));
        s.send(httpOK("OPTIONSRESPONSE"));
    });
    auto res = options(testServer.addr ~ "/path");
    assert(res == "OPTIONSRESPONSE");
}


/** HTTP trace request.
 *
 * Params:
 * url = resource make a trace call to
 * conn = connection to use e.g. FTP or HTTP. The default AutoProtocol will
 *        guess connection type and create a new instance for this call only.
 *
 * The template parameter $(D T) specifies the type to return. Possible values
 * are $(D char) and $(D ubyte) to return $(D char[]) or $(D ubyte[]).
 *
 * Example:
 * ----
 * import std.net.curl;
 * trace("d-lang.appspot.com/testUrl1");
 * ----
 *
 * Returns:
 * A T[] range containing the trace info of the resource pointed to by the URL.
 *
 * See_Also: $(LREF HTTP.Method)
 */
T[] trace(T = char)(const(char)[] url, HTTP conn = HTTP())
   if (is(T == char) || is(T == ubyte))
{
    conn.method = HTTP.Method.trace;
    return _basicHTTP!(T)(url, cast(void[]) null, conn);
}

unittest
{
    testServer.handle((s) {
        auto req = s.recvReq;
        assert(req.hdrs.canFind("TRACE /path"));
        s.send(httpOK("TRACERESPONSE"));
    });
    auto res = trace(testServer.addr ~ "/path");
    assert(res == "TRACERESPONSE");
}


/** HTTP connect request.
 *
 * Params:
 * url = resource make a connect to
 * conn = HTTP connection to use
 *
 * The template parameter $(D T) specifies the type to return. Possible values
 * are $(D char) and $(D ubyte) to return $(D char[]) or $(D ubyte[]).
 *
 * Example:
 * ----
 * import std.net.curl;
 * connect("d-lang.appspot.com/testUrl1");
 * ----
 *
 * Returns:
 * A T[] range containing the connect info of the resource pointed to by the URL.
 *
 * See_Also: $(LREF HTTP.Method)
 */
T[] connect(T = char)(const(char)[] url, HTTP conn = HTTP())
   if (is(T == char) || is(T == ubyte))
{
    conn.method = HTTP.Method.connect;
    return _basicHTTP!(T)(url, cast(void[]) null, conn);
}

unittest
{
    testServer.handle((s) {
        auto req = s.recvReq;
        assert(req.hdrs.canFind("CONNECT /path"));
        s.send(httpOK("CONNECTRESPONSE"));
    });
    auto res = connect(testServer.addr ~ "/path");
    assert(res == "CONNECTRESPONSE");
}


/** HTTP patch content.
 *
 * Params:
 * url = resource to patch
 * patchData = data to send as the body of the request. An array
 *           of an arbitrary type is accepted and will be cast to ubyte[]
 *           before sending it.
 * conn = HTTP connection to use
 *
 * The template parameter $(D T) specifies the type to return. Possible values
 * are $(D char) and $(D ubyte) to return $(D char[]) or $(D ubyte[]).
 *
 * Example:
 * ----
 * auto http = HTTP();
 * http.addRequestHeader("Content-Type", "application/json");
 * auto content = patch("d-lang.appspot.com/testUrl2", `{"title": "Patched Title"}`, http);
 * ----
 *
 * Returns:
 * A T[] range containing the content of the resource pointed to by the URL.
 *
 * See_Also: $(LREF HTTP.Method)
 */
T[] patch(T = char, PatchUnit)(const(char)[] url, const(PatchUnit)[] patchData,
                               HTTP conn = HTTP())
    if (is(T == char) || is(T == ubyte))
{
    conn.method = HTTP.Method.patch;
    return _basicHTTP!(T)(url, patchData, conn);
}

unittest
{
    testServer.handle((s) {
        auto req = s.recvReq;
        assert(req.hdrs.canFind("PATCH /path"));
        assert(req.bdy.canFind("PATCHBODY"));
        s.send(httpOK("PATCHRESPONSE"));
    });
    auto res = patch(testServer.addr ~ "/path", "PATCHBODY");
    assert(res == "PATCHRESPONSE");
}


/*
 * Helper function for the high level interface.
 *
 * It performs an HTTP request using the client which must have
 * been setup correctly before calling this function.
 */
private auto _basicHTTP(T)(const(char)[] url, const(void)[] sendData, HTTP client)
{
    immutable doSend = sendData !is null &&
        (client.method == HTTP.Method.post ||
         client.method == HTTP.Method.put ||
         client.method == HTTP.Method.patch);

    scope (exit)
    {
        client.onReceiveHeader = null;
        client.onReceiveStatusLine = null;
        client.onReceive = null;

        if (doSend)
        {
            client.onSend = null;
            client.handle.onSeek = null;
            client.contentLength = 0;
        }
    }
    client.url = url;
    HTTP.StatusLine statusLine;
    ubyte[] content;
    string[string] headers;
    client.onReceive = (ubyte[] data)
    {
        content ~= data;
        return data.length;
    };

    if (doSend)
    {
        client.contentLength = sendData.length;
        auto remainingData = sendData;
        client.onSend = delegate size_t(void[] buf)
        {
            size_t minLen = min(buf.length, remainingData.length);
            if (minLen == 0) return 0;
            buf[0..minLen] = remainingData[0..minLen];
            remainingData = remainingData[minLen..$];
            return minLen;
        };
        client.handle.onSeek = delegate(long offset, CurlSeekPos mode)
        {
            switch (mode)
            {
                case CurlSeekPos.set:
                    remainingData = sendData[cast(size_t)offset..$];
                    return CurlSeek.ok;
                default:
                    // As of curl 7.18.0, libcurl will not pass
                    // anything other than CurlSeekPos.set.
                    return CurlSeek.cantseek;
            }
        };
    }

    client.onReceiveHeader = (in char[] key,
                              in char[] value)
    {
        if (auto v = key in headers)
        {
            *v ~= ", ";
            *v ~= value;
        }
        else
            headers[key] = value.idup;
    };
    client.onReceiveStatusLine = (HTTP.StatusLine l) { statusLine = l; };
    client.perform();
    enforce!CurlException(statusLine.code / 100 == 2,
                            format("HTTP request returned status code %d (%s)",
                                   statusLine.code, statusLine.reason));

    // Default charset defined in HTTP RFC
    auto charset = "ISO-8859-1";
    if (auto v = "content-type" in headers)
    {
        auto m = match(cast(char[]) (*v), regex("charset=([^;,]*)"));
        if (!m.empty && m.captures.length > 1)
        {
            charset = m.captures[1].idup;
        }
    }

    return _decodeContent!T(content, charset);
}

unittest
{
    testServer.handle((s) {
        auto req = s.recvReq;
        assert(req.hdrs.canFind("GET /path"));
        s.send(httpNotFound());
    });
    auto e = collectException!CurlException(get(testServer.addr ~ "/path"));
    assert(e.msg == "HTTP request returned status code 404 (Not Found)");
}

// Bugzilla 14760 - content length must be reset after post
unittest
{
    testServer.handle((s) {
        auto req = s.recvReq;
        assert(req.hdrs.canFind("POST /"));
        assert(req.bdy.canFind("POSTBODY"));
        s.send(httpOK("POSTRESPONSE"));

        req = s.recvReq;
        assert(req.hdrs.canFind("TRACE /"));
        assert(req.bdy.empty);
        s.blocking = false;
        ubyte[6] buf = void;
        assert(s.receive(buf[]) < 0);
        s.send(httpOK("TRACERESPONSE"));
    });
    auto http = HTTP();
    auto res = post(testServer.addr, "POSTBODY", http);
    assert(res == "POSTRESPONSE");
    res = trace(testServer.addr, http);
    assert(res == "TRACERESPONSE");
}

/*
 * Helper function for the high level interface.
 *
 * It performs an FTP request using the client which must have
 * been setup correctly before calling this function.
 */
private auto _basicFTP(T)(const(char)[] url, const(void)[] sendData, FTP client)
{
    scope (exit)
    {
        client.onReceive = null;
        if (!sendData.empty)
            client.onSend = null;
    }

    ubyte[] content;

    if (client.encoding.empty)
        client.encoding = "ISO-8859-1";

    client.url = url;
    client.onReceive = (ubyte[] data)
    {
        content ~= data;
        return data.length;
    };

    if (!sendData.empty)
    {
        client.handle.set(CurlOption.upload, 1L);
        client.onSend = delegate size_t(void[] buf)
        {
            size_t minLen = min(buf.length, sendData.length);
            if (minLen == 0) return 0;
            buf[0..minLen] = sendData[0..minLen];
            sendData = sendData[minLen..$];
            return minLen;
        };
    }

    client.perform();

    return _decodeContent!T(content, client.encoding);
}

/* Used by _basicHTTP() and _basicFTP() to decode ubyte[] to
 * correct string format
 */
private auto _decodeContent(T)(ubyte[] content, string encoding)
{
    static if (is(T == ubyte))
    {
        return content;
    }
    else
    {
        // Optimally just return the utf8 encoded content
        if (encoding == "UTF-8")
            return cast(char[])(content);

        // The content has to be re-encoded to utf8
        auto scheme = EncodingScheme.create(encoding);
        enforce!CurlException(scheme !is null,
                                format("Unknown encoding '%s'", encoding));

        auto strInfo = decodeString(content, scheme);
        enforce!CurlException(strInfo[0] != size_t.max,
                                format("Invalid encoding sequence for encoding '%s'",
                                       encoding));

        return strInfo[1];
    }
}

alias KeepTerminator = Flag!"keepTerminator";
/+
struct ByLineBuffer(Char)
{
    bool linePresent;
    bool EOF;
    Char[] buffer;
    ubyte[] decodeRemainder;

    bool append(const(ubyte)[] data)
    {
        byLineBuffer ~= data;
    }

    @property bool linePresent()
    {
        return byLinePresent;
    }

    Char[] get()
    {
        if (!linePresent)
        {
            // Decode ubyte[] into Char[] until a Terminator is found.
            // If not Terminator is found and EOF is false then raise an
            // exception.
        }
        return byLineBuffer;
    }

}
++/
/** HTTP/FTP fetch content as a range of lines.
 *
 * A range of lines is returned when the request is complete. If the method or
 * other request properties is to be customized then set the $(D conn) parameter
 * with a HTTP/FTP instance that has these properties set.
 *
 * Example:
 * ----
 * import std.net.curl, std.stdio;
 * foreach (line; byLine("dlang.org"))
 *     writeln(line);
 * ----
 *
 * Params:
 * url = The url to receive content from
 * keepTerminator = KeepTerminator.yes signals that the line terminator should be
 *                  returned as part of the lines in the range.
 * terminator = The character that terminates a line
 * conn = The connection to use e.g. HTTP or FTP.
 *
 * Returns:
 * A range of Char[] with the content of the resource pointer to by the URL
 */
auto byLine(Conn = AutoProtocol, Terminator = char, Char = char)
           (const(char)[] url, KeepTerminator keepTerminator = KeepTerminator.no,
            Terminator terminator = '\n', Conn conn = Conn())
if (isCurlConn!Conn && isSomeChar!Char && isSomeChar!Terminator)
{
    static struct SyncLineInputRange
    {

        private Char[] lines;
        private Char[] current;
        private bool currentValid;
        private bool keepTerminator;
        private Terminator terminator;

        this(Char[] lines, bool kt, Terminator terminator)
        {
            this.lines = lines;
            this.keepTerminator = kt;
            this.terminator = terminator;
            currentValid = true;
            popFront();
        }

        @property @safe bool empty()
        {
            return !currentValid;
        }

        @property @safe Char[] front()
        {
            enforce!CurlException(currentValid, "Cannot call front() on empty range");
            return current;
        }

        void popFront()
        {
            enforce!CurlException(currentValid, "Cannot call popFront() on empty range");
            if (lines.empty)
            {
                currentValid = false;
                return;
            }

            if (keepTerminator)
            {
                auto r = findSplitAfter(lines, [ terminator ]);
                if (r[0].empty)
                {
                    current = r[1];
                    lines = r[0];
                }
                else
                {
                    current = r[0];
                    lines = r[1];
                }
            }
            else
            {
                auto r = findSplit(lines, [ terminator ]);
                current = r[0];
                lines = r[2];
            }
        }
    }

    auto result = _getForRange!Char(url, conn);
    return SyncLineInputRange(result, keepTerminator == KeepTerminator.yes, terminator);
}

unittest
{
    foreach (host; [testServer.addr, "http://"~testServer.addr])
    {
        testServer.handle((s) {
            auto req = s.recvReq;
            s.send(httpOK("Line1\nLine2\nLine3"));
        });
        assert(byLine(host).equal(["Line1", "Line2", "Line3"]));
    }
}

/** HTTP/FTP fetch content as a range of chunks.
 *
 * A range of chunks is returned when the request is complete. If the method or
 * other request properties is to be customized then set the $(D conn) parameter
 * with a HTTP/FTP instance that has these properties set.
 *
 * Example:
 * ----
 * import std.net.curl, std.stdio;
 * foreach (chunk; byChunk("dlang.org", 100))
 *     writeln(chunk); // chunk is ubyte[100]
 * ----
 *
 * Params:
 * url = The url to receive content from
 * chunkSize = The size of each chunk
 * conn = The connection to use e.g. HTTP or FTP.
 *
 * Returns:
 * A range of ubyte[chunkSize] with the content of the resource pointer to by the URL
 */
auto byChunk(Conn = AutoProtocol)
            (const(char)[] url, size_t chunkSize = 1024, Conn conn = Conn())
    if (isCurlConn!(Conn))
{
    static struct SyncChunkInputRange
    {
        private size_t chunkSize;
        private ubyte[] _bytes;
        private size_t offset;

        this(ubyte[] bytes, size_t chunkSize)
        {
            this._bytes = bytes;
            this.chunkSize = chunkSize;
        }

        @property @safe auto empty()
        {
            return offset == _bytes.length;
        }

        @property ubyte[] front()
        {
            size_t nextOffset = offset + chunkSize;
            if (nextOffset > _bytes.length) nextOffset = _bytes.length;
            return _bytes[offset..nextOffset];
        }

        @safe void popFront()
        {
            offset += chunkSize;
            if (offset > _bytes.length) offset = _bytes.length;
        }
    }

    auto result = _getForRange!ubyte(url, conn);
    return SyncChunkInputRange(result, chunkSize);
}

unittest
{
    foreach (host; [testServer.addr, "http://"~testServer.addr])
    {
        testServer.handle((s) {
            auto req = s.recvReq;
            s.send(httpOK(cast(ubyte[])[0, 1, 2, 3, 4, 5]));
        });
        assert(byChunk(host, 2).equal([[0, 1], [2, 3], [4, 5]]));
    }
}

private T[] _getForRange(T,Conn)(const(char)[] url, Conn conn)
{
    static if (is(Conn : HTTP))
    {
        conn.method = conn.method == HTTP.Method.undefined ? HTTP.Method.get : conn.method;
        return _basicHTTP!(T)(url, null, conn);
    }
    else static if (is(Conn : FTP))
    {
        return _basicFTP!(T)(url, null, conn);
    }
    else
    {
        if (isFTPUrl(url))
            return get!(FTP,T)(url, FTP());
        else
            return get!(HTTP,T)(url, HTTP());
    }
}

/*
  Main thread part of the message passing protocol used for all async
  curl protocols.
 */
private mixin template WorkerThreadProtocol(Unit, alias units)
{
    @property bool empty()
    {
        tryEnsureUnits();
        return state == State.done;
    }

    @property Unit[] front()
    {
        tryEnsureUnits();
        assert(state == State.gotUnits,
               format("Expected %s but got $s",
                      State.gotUnits, state));
        return units;
    }

    void popFront()
    {
        tryEnsureUnits();
        assert(state == State.gotUnits,
               format("Expected %s but got $s",
                      State.gotUnits, state));
        state = State.needUnits;
        // Send to worker thread for buffer reuse
        workerTid.send(cast(immutable(Unit)[]) units);
        units = null;
    }

    /** Wait for duration or until data is available and return true if data is
         available
    */
    bool wait(Duration d)
    {
        if (state == State.gotUnits)
            return true;

        enum noDur = dur!"hnsecs"(0);
        StopWatch sw;
        sw.start();
        while (state != State.gotUnits && d > noDur)
        {
            final switch (state)
            {
            case State.needUnits:
                receiveTimeout(d,
                        (Tid origin, CurlMessage!(immutable(Unit)[]) _data)
                        {
                            if (origin != workerTid)
                                return false;
                            units = cast(Unit[]) _data.data;
                            state = State.gotUnits;
                            return true;
                        },
                        (Tid origin, CurlMessage!bool f)
                        {
                            if (origin != workerTid)
                                return false;
                            state = state.done;
                            return true;
                        }
                        );
                break;
            case State.gotUnits: return true;
            case State.done:
                return false;
            }
            d -= sw.peek();
            sw.reset();
        }
        return state == State.gotUnits;
    }

    enum State
    {
        needUnits,
        gotUnits,
        done
    }
    State state;

    void tryEnsureUnits()
    {
        while (true)
        {
            final switch (state)
            {
            case State.needUnits:
                receive(
                        (Tid origin, CurlMessage!(immutable(Unit)[]) _data)
                        {
                            if (origin != workerTid)
                                return false;
                            units = cast(Unit[]) _data.data;
                            state = State.gotUnits;
                            return true;
                        },
                        (Tid origin, CurlMessage!bool f)
                        {
                            if (origin != workerTid)
                                return false;
                            state = state.done;
                            return true;
                        }
                        );
                break;
            case State.gotUnits: return;
            case State.done:
                return;
            }
        }
    }
}

// Workaround bug #2458
// It should really be defined inside the byLineAsync method.
// Do not create instances of this struct since it will be
// moved when the bug has been fixed.
// Range that reads one line at a time asynchronously.
static struct AsyncLineInputRange(Char)
{
    private Char[] line;
    mixin WorkerThreadProtocol!(Char, line);

    private Tid workerTid;
    private State running;

    private this(Tid tid, size_t transmitBuffers, size_t bufferSize)
    {
        workerTid = tid;
        state = State.needUnits;

        // Send buffers to other thread for it to use.  Since no mechanism is in
        // place for moving ownership a cast to shared is done here and casted
        // back to non-shared in the receiving end.
        foreach (i ; 0..transmitBuffers)
        {
            auto arr = new Char[](bufferSize);
            workerTid.send(cast(immutable(Char[]))arr);
        }
    }
}


/** HTTP/FTP fetch content as a range of lines asynchronously.
 *
 * A range of lines is returned immediately and the request that fetches the
 * lines is performed in another thread. If the method or other request
 * properties is to be customized then set the $(D conn) parameter with a
 * HTTP/FTP instance that has these properties set.
 *
 * If $(D postData) is non-_null the method will be set to $(D post) for HTTP
 * requests.
 *
 * The background thread will buffer up to transmitBuffers number of lines
 * before it stops receiving data from network. When the main thread reads the
 * lines from the range it frees up buffers and allows for the background thread
 * to receive more data from the network.
 *
 * If no data is available and the main thread accesses the range it will block
 * until data becomes available. An exception to this is the $(D wait(Duration)) method on
 * the $(LREF AsyncLineInputRange). This method will wait at maximum for the
 * specified duration and return true if data is available.
 *
 * Example:
 * ----
 * import std.net.curl, std.stdio;
 * // Get some pages in the background
 * auto range1 = byLineAsync("www.google.com");
 * auto range2 = byLineAsync("www.wikipedia.org");
 * foreach (line; byLineAsync("dlang.org"))
 *     writeln(line);
 *
 * // Lines already fetched in the background and ready
 * foreach (line; range1) writeln(line);
 * foreach (line; range2) writeln(line);
 * ----
 *
 * ----
 * import std.net.curl, std.stdio;
 * // Get a line in a background thread and wait in
 * // main thread for 2 seconds for it to arrive.
 * auto range3 = byLineAsync("dlang.com");
 * if (range.wait(dur!"seconds"(2)))
 *     writeln(range.front);
 * else
 *     writeln("No line received after 2 seconds!");
 * ----
 *
 * Params:
 * url = The url to receive content from
 * postData = Data to HTTP Post
 * keepTerminator = KeepTerminator.yes signals that the line terminator should be
 *                  returned as part of the lines in the range.
 * terminator = The character that terminates a line
 * transmitBuffers = The number of lines buffered asynchronously
 * conn = The connection to use e.g. HTTP or FTP.
 *
 * Returns:
 * A range of Char[] with the content of the resource pointer to by the
 * URL.
 */
auto byLineAsync(Conn = AutoProtocol, Terminator = char, Char = char, PostUnit)
            (const(char)[] url, const(PostUnit)[] postData,
             KeepTerminator keepTerminator = KeepTerminator.no,
             Terminator terminator = '\n',
             size_t transmitBuffers = 10, Conn conn = Conn())
    if (isCurlConn!Conn && isSomeChar!Char && isSomeChar!Terminator)
{
    static if (is(Conn : AutoProtocol))
    {
        if (isFTPUrl(url))
            return byLineAsync(url, postData, keepTerminator,
                               terminator, transmitBuffers, FTP());
        else
            return byLineAsync(url, postData, keepTerminator,
                               terminator, transmitBuffers, HTTP());
    }
    else
    {
        // 50 is just an arbitrary number for now
        setMaxMailboxSize(thisTid, 50, OnCrowding.block);
        auto tid = spawn(&_spawnAsync!(Conn, Char, Terminator));
        tid.send(thisTid);
        tid.send(terminator);
        tid.send(keepTerminator == KeepTerminator.yes);

        _asyncDuplicateConnection(url, conn, postData, tid);

        return AsyncLineInputRange!Char(tid, transmitBuffers,
                                        Conn.defaultAsyncStringBufferSize);
    }
}

/// ditto
auto byLineAsync(Conn = AutoProtocol, Terminator = char, Char = char)
            (const(char)[] url, KeepTerminator keepTerminator = KeepTerminator.no,
             Terminator terminator = '\n',
             size_t transmitBuffers = 10, Conn conn = Conn())
{
    static if (is(Conn : AutoProtocol))
    {
        if (isFTPUrl(url))
            return byLineAsync(url, cast(void[])null, keepTerminator,
                               terminator, transmitBuffers, FTP());
        else
            return byLineAsync(url, cast(void[])null, keepTerminator,
                               terminator, transmitBuffers, HTTP());
    }
    else
    {
        return byLineAsync(url, cast(void[])null, keepTerminator,
                           terminator, transmitBuffers, conn);
    }
}

unittest
{
    foreach (host; [testServer.addr, "http://"~testServer.addr])
    {
        testServer.handle((s) {
            auto req = s.recvReq;
            s.send(httpOK("Line1\nLine2\nLine3"));
        });
        assert(byLineAsync(host).equal(["Line1", "Line2", "Line3"]));
    }
}


// Workaround bug #2458
// It should really be defined inside the byLineAsync method.
// Do not create instances of this struct since it will be
// moved when the bug has been fixed.
// Range that reads one chunk at a time asynchronously.
static struct AsyncChunkInputRange
{
    private ubyte[] chunk;
    mixin WorkerThreadProtocol!(ubyte, chunk);

    private Tid workerTid;
    private State running;

    private this(Tid tid, size_t transmitBuffers, size_t chunkSize)
    {
        workerTid = tid;
        state = State.needUnits;

        // Send buffers to other thread for it to use.  Since no mechanism is in
        // place for moving ownership a cast to shared is done here and a cast
        // back to non-shared in the receiving end.
        foreach (i ; 0..transmitBuffers)
        {
            ubyte[] arr = new ubyte[](chunkSize);
            workerTid.send(cast(immutable(ubyte[]))arr);
        }
    }
}

/** HTTP/FTP fetch content as a range of chunks asynchronously.
 *
 * A range of chunks is returned immediately and the request that fetches the
 * chunks is performed in another thread. If the method or other request
 * properties is to be customized then set the $(D conn) parameter with a
 * HTTP/FTP instance that has these properties set.
 *
 * If $(D postData) is non-_null the method will be set to $(D post) for HTTP
 * requests.
 *
 * The background thread will buffer up to transmitBuffers number of chunks
 * before is stops receiving data from network. When the main thread reads the
 * chunks from the range it frees up buffers and allows for the background
 * thread to receive more data from the network.
 *
 * If no data is available and the main thread access the range it will block
 * until data becomes available. An exception to this is the $(D wait(Duration))
 * method on the $(LREF AsyncChunkInputRange). This method will wait at maximum for the specified
 * duration and return true if data is available.
 *
 * Example:
 * ----
 * import std.net.curl, std.stdio;
 * // Get some pages in the background
 * auto range1 = byChunkAsync("www.google.com", 100);
 * auto range2 = byChunkAsync("www.wikipedia.org");
 * foreach (chunk; byChunkAsync("dlang.org"))
 *     writeln(chunk); // chunk is ubyte[100]
 *
 * // Chunks already fetched in the background and ready
 * foreach (chunk; range1) writeln(chunk);
 * foreach (chunk; range2) writeln(chunk);
 * ----
 *
 * ----
 * import std.net.curl, std.stdio;
 * // Get a line in a background thread and wait in
 * // main thread for 2 seconds for it to arrive.
 * auto range3 = byChunkAsync("dlang.com", 10);
 * if (range.wait(dur!"seconds"(2)))
 *     writeln(range.front);
 * else
 *     writeln("No chunk received after 2 seconds!");
 * ----
 *
 * Params:
 * url = The url to receive content from
 * postData = Data to HTTP Post
 * chunkSize = The size of the chunks
 * transmitBuffers = The number of chunks buffered asynchronously
 * conn = The connection to use e.g. HTTP or FTP.
 *
 * Returns:
 * A range of ubyte[chunkSize] with the content of the resource pointer to by
 * the URL.
 */
auto byChunkAsync(Conn = AutoProtocol, PostUnit)
           (const(char)[] url, const(PostUnit)[] postData,
            size_t chunkSize = 1024, size_t transmitBuffers = 10,
            Conn conn = Conn())
    if (isCurlConn!(Conn))
{
    static if (is(Conn : AutoProtocol))
    {
        if (isFTPUrl(url))
            return byChunkAsync(url, postData, chunkSize,
                                transmitBuffers, FTP());
        else
            return byChunkAsync(url, postData, chunkSize,
                                transmitBuffers, HTTP());
    }
    else
    {
        // 50 is just an arbitrary number for now
        setMaxMailboxSize(thisTid, 50, OnCrowding.block);
        auto tid = spawn(&_spawnAsync!(Conn, ubyte));
        tid.send(thisTid);

        _asyncDuplicateConnection(url, conn, postData, tid);

        return AsyncChunkInputRange(tid, transmitBuffers, chunkSize);
    }
}

/// ditto
auto byChunkAsync(Conn = AutoProtocol)
           (const(char)[] url,
            size_t chunkSize = 1024, size_t transmitBuffers = 10,
            Conn conn = Conn())
    if (isCurlConn!(Conn))
{
    static if (is(Conn : AutoProtocol))
    {
        if (isFTPUrl(url))
            return byChunkAsync(url, cast(void[])null, chunkSize,
                                transmitBuffers, FTP());
        else
            return byChunkAsync(url, cast(void[])null, chunkSize,
                                transmitBuffers, HTTP());
    }
    else
    {
        return byChunkAsync(url, cast(void[])null, chunkSize,
                            transmitBuffers, conn);
    }
}

unittest
{
    foreach (host; [testServer.addr, "http://"~testServer.addr])
    {
        testServer.handle((s) {
            auto req = s.recvReq;
            s.send(httpOK(cast(ubyte[])[0, 1, 2, 3, 4, 5]));
        });
        assert(byChunkAsync(host, 2).equal([[0, 1], [2, 3], [4, 5]]));
    }
}


/* Used by byLineAsync/byChunkAsync to duplicate an existing connection
 * that can be used exclusively in a spawned thread.
 */
private void _asyncDuplicateConnection(Conn, PostData)
    (const(char)[] url, Conn conn, PostData postData, Tid tid)
{
    // no move semantic available in std.concurrency ie. must use casting.
    auto connDup = conn.dup();
    connDup.url = url;

    static if ( is(Conn : HTTP) )
    {
        connDup.p.headersOut = null;
        connDup.method = conn.method == HTTP.Method.undefined ?
            HTTP.Method.get : conn.method;
        if (postData !is null)
        {
            if (connDup.method == HTTP.Method.put)
            {
                connDup.handle.set(CurlOption.infilesize_large,
                                   postData.length);
            }
            else
            {
                // post
                connDup.method = HTTP.Method.post;
                connDup.handle.set(CurlOption.postfieldsize_large,
                                   postData.length);
            }
            connDup.handle.set(CurlOption.copypostfields,
                               cast(void*) postData.ptr);
        }
        tid.send(cast(ulong)connDup.handle.handle);
        tid.send(connDup.method);
    }
    else
    {
        enforce!CurlException(postData is null,
                                "Cannot put ftp data using byLineAsync()");
        tid.send(cast(ulong)connDup.handle.handle);
        tid.send(HTTP.Method.undefined);
    }
    connDup.p.curl.handle = null; // make sure handle is not freed
}

/*
  Mixin template for all supported curl protocols. This is the commom
  functionallity such as timeouts and network interface settings. This should
  really be in the HTTP/FTP/SMTP structs but the documentation tool does not
  support a mixin to put its doc strings where a mixin is done. Therefore docs
  in this template is copied into each of HTTP/FTP/SMTP below.
*/
private mixin template Protocol()
{

    /// Value to return from $(D onSend)/$(D onReceive) delegates in order to
    /// pause a request
    alias requestPause = CurlReadFunc.pause;

    /// Value to return from onSend delegate in order to abort a request
    alias requestAbort = CurlReadFunc.abort;

    static uint defaultAsyncStringBufferSize = 100;

    /**
       The curl handle used by this connection.
    */
    @property ref Curl handle() return
    {
        return p.curl;
    }

    /**
       True if the instance is stopped. A stopped instance is not usable.
    */
    @property bool isStopped()
    {
        return p.curl.stopped;
    }

    /// Stop and invalidate this instance.
    void shutdown()
    {
        p.curl.shutdown();
    }

    /** Set verbose.
        This will print request information to stderr.
     */
    @property void verbose(bool on)
    {
        p.curl.set(CurlOption.verbose, on ? 1L : 0L);
    }

    // Connection settings

    /// Set timeout for activity on connection.
    @property void dataTimeout(Duration d)
    {
        p.curl.set(CurlOption.low_speed_limit, 1);
        p.curl.set(CurlOption.low_speed_time, d.total!"seconds");
    }

    /** Set maximum time an operation is allowed to take.
        This includes dns resolution, connecting, data transfer, etc.
     */
    @property void operationTimeout(Duration d)
    {
        p.curl.set(CurlOption.timeout_ms, d.total!"msecs");
    }

    /// Set timeout for connecting.
    @property void connectTimeout(Duration d)
    {
        p.curl.set(CurlOption.connecttimeout_ms, d.total!"msecs");
    }

    // Network settings

    /** Proxy
     *  See: $(WEB curl.haxx.se/libcurl/c/curl_easy_setopt.html#CURLOPTPROXY, _proxy)
     */
    @property void proxy(const(char)[] host)
    {
        p.curl.set(CurlOption.proxy, host);
    }

    /** Proxy port
     *  See: $(WEB curl.haxx.se/libcurl/c/curl_easy_setopt.html#CURLOPTPROXYPORT, _proxy_port)
     */
    @property void proxyPort(ushort port)
    {
        p.curl.set(CurlOption.proxyport, cast(long) port);
    }

    /// Type of proxy
    alias CurlProxy = etc.c.curl.CurlProxy;

    /** Proxy type
     *  See: $(WEB curl.haxx.se/libcurl/c/curl_easy_setopt.html#CURLOPTPROXY, _proxy_type)
     */
    @property void proxyType(CurlProxy type)
    {
        p.curl.set(CurlOption.proxytype, cast(long) type);
    }

    /// DNS lookup timeout.
    @property void dnsTimeout(Duration d)
    {
        p.curl.set(CurlOption.dns_cache_timeout, d.total!"msecs");
    }

    /**
     * The network interface to use in form of the the IP of the interface.
     *
     * Example:
     * ----
     * theprotocol.netInterface = "192.168.1.32";
     * theprotocol.netInterface = [ 192, 168, 1, 32 ];
     * ----
     *
     * See: $(XREF socket, InternetAddress)
     */
    @property void netInterface(const(char)[] i)
    {
        p.curl.set(CurlOption.intrface, i);
    }

    /// ditto
    @property void netInterface(const(ubyte)[4] i)
    {
        auto str = format("%d.%d.%d.%d", i[0], i[1], i[2], i[3]);
        netInterface = str;
    }

    /// ditto
    @property void netInterface(InternetAddress i)
    {
        netInterface = i.toAddrString();
    }

    /**
       Set the local outgoing port to use.
       Params:
       port = the first outgoing port number to try and use
    */
    @property void localPort(ushort port)
    {
        p.curl.set(CurlOption.localport, cast(long)port);
    }

    /**
       Set the local outgoing port range to use.
       This can be used together with the localPort property.
       Params:
       range = if the first port is occupied then try this many
               port number forwards
    */
    @property void localPortRange(ushort range)
    {
        p.curl.set(CurlOption.localportrange, cast(long)range);
    }

    /** Set the tcp no-delay socket option on or off.
        See: $(WEB curl.haxx.se/libcurl/c/curl_easy_setopt.html#CURLOPTTCPNODELAY, nodelay)
    */
    @property void tcpNoDelay(bool on)
    {
        p.curl.set(CurlOption.tcp_nodelay, cast(long) (on ? 1 : 0) );
    }

    /** Sets whether SSL peer certificates should be verified.
        See: $(WEB curl.haxx.se/libcurl/c/curl_easy_setopt.html#CURLOPTSSLVERIFYPEER, verifypeer)
    */
    @property void verifyPeer(bool on)
    {
      p.curl.set(CurlOption.ssl_verifypeer, on ? 1 : 0);
    }

    /** Sets whether the host within an SSL certificate should be verified.
        See: $(WEB curl.haxx.se/libcurl/c/curl_easy_setopt.html#CURLOPTSSLVERIFYHOST, verifypeer)
    */
    @property void verifyHost(bool on)
    {
      p.curl.set(CurlOption.ssl_verifyhost, on ? 2 : 0);
    }

    // Authentication settings

    /**
       Set the user name, password and optionally domain for authentication
       purposes.

       Some protocols may need authentication in some cases. Use this
       function to provide credentials.

       Params:
       username = the username
       password = the password
       domain = used for NTLM authentication only and is set to the NTLM domain
                name
    */
    void setAuthentication(const(char)[] username, const(char)[] password,
                           const(char)[] domain = "")
    {
        if (!domain.empty)
            username = format("%s/%s", domain, username);
        p.curl.set(CurlOption.userpwd, format("%s:%s", username, password));
    }

    unittest
    {
        testServer.handle((s) {
            auto req = s.recvReq;
            assert(req.hdrs.canFind("GET /"));
            assert(req.hdrs.canFind("Basic dXNlcjpwYXNz"));
            s.send(httpOK());
        });

        auto http = HTTP(testServer.addr);
        http.onReceive = (ubyte[] data) { return data.length; };
        http.setAuthentication("user", "pass");
        http.perform();
    }

    /**
       Set the user name and password for proxy authentication.

       Params:
       username = the username
       password = the password
    */
    void setProxyAuthentication(const(char)[] username, const(char)[] password)
    {
        p.curl.set(CurlOption.proxyuserpwd,
            format("%s:%s",
                username.replace(":", "%3A"),
                password.replace(":", "%3A"))
        );
    }

    /**
     * The event handler that gets called when data is needed for sending. The
     * length of the $(D void[]) specifies the maximum number of bytes that can
     * be sent.
     *
     * Returns:
     * The callback returns the number of elements in the buffer that have been
     * filled and are ready to send.
     * The special value $(D .abortRequest) can be returned in order to abort the
     * current request.
     * The special value $(D .pauseRequest) can be returned in order to pause the
     * current request.
     *
     * Example:
     * ----
     * import std.net.curl;
     * string msg = "Hello world";
     * auto client = HTTP("dlang.org");
     * client.onSend = delegate size_t(void[] data)
     * {
     *     auto m = cast(void[])msg;
     *     size_t length = m.length > data.length ? data.length : m.length;
     *     if (length == 0) return 0;
     *     data[0..length] = m[0..length];
     *     msg = msg[length..$];
     *     return length;
     * };
     * client.perform();
     * ----
     */
    @property void onSend(size_t delegate(void[]) callback)
    {
        p.curl.clear(CurlOption.postfields); // cannot specify data when using callback
        p.curl.onSend = callback;
    }

    /**
      * The event handler that receives incoming data. Be sure to copy the
      * incoming ubyte[] since it is not guaranteed to be valid after the
      * callback returns.
      *
      * Returns:
      * The callback returns the number of incoming bytes read. If the entire array is
      * not read the request will abort.
      * The special value .pauseRequest can be returned in order to pause the
      * current request.
      *
      * Example:
      * ----
      * import std.net.curl, std.stdio;
      * auto client = HTTP("dlang.org");
      * client.onReceive = (ubyte[] data)
      * {
      *     writeln("Got data", to!(const(char)[])(data));
      *     return data.length;
      * };
      * client.perform();
      * ----
      */
    @property void onReceive(size_t delegate(ubyte[]) callback)
    {
        p.curl.onReceive = callback;
    }

    /**
      * The event handler that gets called to inform of upload/download progress.
      *
      * Params:
      * dlTotal = total bytes to download
      * dlNow = currently downloaded bytes
      * ulTotal = total bytes to upload
      * ulNow = currently uploaded bytes
      *
      * Returns:
      * Return 0 from the callback to signal success, return non-zero to abort
      *          transfer
      *
      * Example:
      * ----
      * import std.net.curl, std.stdio;
      * auto client = HTTP("dlang.org");
      * client.onProgress = delegate int(size_t dl, size_t dln, size_t ul, size_t ult)
      * {
      *     writeln("Progress: downloaded ", dln, " of ", dl);
      *     writeln("Progress: uploaded ", uln, " of ", ul);
      * };
      * client.perform();
      * ----
      */
    @property void onProgress(int delegate(size_t dlTotal, size_t dlNow,
                                           size_t ulTotal, size_t ulNow) callback)
    {
        p.curl.onProgress = callback;
    }
}

/*
  Decode $(D ubyte[]) array using the provided EncodingScheme up to maxChars
  Returns: Tuple of ubytes read and the $(D Char[]) characters decoded.
           Not all ubytes are guaranteed to be read in case of decoding error.
*/
private Tuple!(size_t,Char[])
decodeString(Char = char)(const(ubyte)[] data,
                          EncodingScheme scheme,
                          size_t maxChars = size_t.max)
{
    Char[] res;
    auto startLen = data.length;
    size_t charsDecoded = 0;
    while (data.length && charsDecoded < maxChars)
    {
        dchar dc = scheme.safeDecode(data);
        if (dc == INVALID_SEQUENCE)
        {
            return typeof(return)(size_t.max, cast(Char[])null);
        }
        charsDecoded++;
        res ~= dc;
    }
    return typeof(return)(startLen-data.length, res);
}

/*
  Decode $(D ubyte[]) array using the provided $(D EncodingScheme) until a the
  line terminator specified is found. The basesrc parameter is effectively
  prepended to src as the first thing.

  This function is used for decoding as much of the src buffer as
  possible until either the terminator is found or decoding fails. If
  it fails as the last data in the src it may mean that the src buffer
  were missing some bytes in order to represent a correct code
  point. Upon the next call to this function more bytes have been
  received from net and the failing bytes should be given as the
  basesrc parameter. It is done this way to minimize data copying.

  Returns: true if a terminator was found
           Not all ubytes are guaranteed to be read in case of decoding error.
           any decoded chars will be inserted into dst.
*/
private bool decodeLineInto(Terminator, Char = char)(ref const(ubyte)[] basesrc,
                                                     ref const(ubyte)[] src,
                                                     ref Char[] dst,
                                                     EncodingScheme scheme,
                                                     Terminator terminator)
{
    auto startLen = src.length;
    size_t charsDecoded = 0;
    // if there is anything in the basesrc then try to decode that
    // first.
    if (basesrc.length != 0)
    {
        // Try to ensure 4 entries in the basesrc by copying from src.
        auto blen = basesrc.length;
        size_t len = (basesrc.length + src.length) >= 4 ?
                     4 : basesrc.length + src.length;
        basesrc.length = len;

        dchar dc = scheme.safeDecode(basesrc);
        if (dc == INVALID_SEQUENCE)
        {
            enforce!CurlException(len != 4, "Invalid code sequence");
            return false;
        }
        dst ~= dc;
        src = src[len-basesrc.length-blen .. $]; // remove used ubytes from src
        basesrc.length = 0;
    }

    while (src.length)
    {
        auto lsrc = src;
        dchar dc = scheme.safeDecode(src);
        if (dc == INVALID_SEQUENCE)
        {
            if (src.empty)
            {
                // The invalid sequence was in the end of the src.  Maybe there
                // just need to be more bytes available so these last bytes are
                // put back to src for later use.
                src = lsrc;
                return false;
            }
            dc = '?';
        }
        dst ~= dc;

        if (dst.endsWith(terminator))
            return true;
    }
    return false; // no terminator found
}

/**
  * HTTP client functionality.
  *
  * Example:
  * ---
  * import std.net.curl, std.stdio;
  *
  * // Get with custom data receivers
  * auto http = HTTP("dlang.org");
  * http.onReceiveHeader =
  *     (in char[] key, in char[] value) { writeln(key ~ ": " ~ value); };
  * http.onReceive = (ubyte[] data) { /+ drop +/ return data.length; };
  * http.perform();
  *
  * // Put with data senders
  * auto msg = "Hello world";
  * http.contentLength = msg.length;
  * http.onSend = (void[] data)
  * {
  *     auto m = cast(void[])msg;
  *     size_t len = m.length > data.length ? data.length : m.length;
  *     if (len == 0) return len;
  *     data[0..len] = m[0..len];
  *     msg = msg[len..$];
  *     return len;
  * };
  * http.perform();
  *
  * // Track progress
  * http.method = HTTP.Method.get;
  * http.url = "http://upload.wikimedia.org/wikipedia/commons/"
  *            "5/53/Wikipedia-logo-en-big.png";
  * http.onReceive = (ubyte[] data) { return data.length; };
  * http.onProgress = (size_t dltotal, size_t dlnow,
  *                    size_t ultotal, size_t ulnow)
  * {
  *     writeln("Progress ", dltotal, ", ", dlnow, ", ", ultotal, ", ", ulnow);
  *     return 0;
  * };
  * http.perform();
  * ---
  *
  * See_Also: $(WEB www.ietf.org/rfc/rfc2616.txt, RFC2616)
  *
  */
struct HTTP
{
    mixin Protocol;

    /// Authentication method equal to $(ECXREF curl, CurlAuth)
    alias AuthMethod = CurlAuth;

    static private uint defaultMaxRedirects = 10;

    private struct Impl
    {
        ~this()
        {
			// WORKAROUND: prevent segfault
            /*if (headersOut !is null)
                Curl.curl.slist_free_all(headersOut);
            if (curl.handle !is null) // work around RefCounted/emplace bug
                curl.shutdown();*/
        }
        Curl curl;
        curl_slist* headersOut;
        string[string] headersIn;
        string charset;

        /// The status line of the final sub-request in a request.
        StatusLine status;
        private void delegate(StatusLine) onReceiveStatusLine;

        /// The HTTP method to use.
        Method method = Method.undefined;

        @property void onReceiveHeader(void delegate(in char[] key,
                                                     in char[] value) callback)
        {
            // Wrap incoming callback in order to separate http status line from
            // http headers.  On redirected requests there may be several such
            // status lines. The last one is the one recorded.
            auto dg = (in char[] header)
            {
                import std.utf : UTFException;
                try
                {
                    if (header.empty)
                    {
                        // header delimiter
                        return;
                    }
                    if (header.startsWith("HTTP/"))
                    {
                        string[string] empty;
                        headersIn = empty; // clear

                        auto m = match(header, regex(r"^HTTP/(\d+)\.(\d+) (\d+) (.*)$"));
                        if (m.empty)
                        {
                            // Invalid status line
                        }
                        else
                        {
                            status.majorVersion = to!ushort(m.captures[1]);
                            status.minorVersion = to!ushort(m.captures[2]);
                            status.code = to!ushort(m.captures[3]);
                            status.reason = m.captures[4].idup;
                            if (onReceiveStatusLine != null)
                                onReceiveStatusLine(status);
                        }
                        return;
                    }

                    // Normal http header
                    auto m = match(cast(char[]) header, regex("(.*?): (.*)$"));

                    auto fieldName = m.captures[1].toLower().idup;
                    if (fieldName == "content-type")
                    {
                        auto mct = match(cast(char[]) m.captures[2],
                                         regex("charset=([^;]*)"));
                        if (!mct.empty && mct.captures.length > 1)
                            charset = mct.captures[1].idup;
                    }

                    if (!m.empty && callback !is null)
                        callback(fieldName, m.captures[2]);
                    headersIn[fieldName] = m.captures[2].idup;
                }
                catch(UTFException e)
                {
                    //munch it - a header should be all ASCII, any "wrong UTF" is broken header
                }
            };

            curl.onReceiveHeader = dg;
        }
    }

    private RefCounted!Impl p;

    /** Time condition enumeration as an alias of $(ECXREF curl, CurlTimeCond)

        $(WEB www.w3.org/Protocols/rfc2616/rfc2616-sec14.html#sec14.25, _RFC2616 Section 14.25)
    */
    alias TimeCond = CurlTimeCond;

    /**
       Constructor taking the url as parameter.
    */
    static HTTP opCall(const(char)[] url)
    {
        HTTP http;
        http.initialize();
        http.url = url;
        return http;
    }

    static HTTP opCall()
    {
        HTTP http;
        http.initialize();
        return http;
    }

    HTTP dup()
    {
        HTTP copy;
        copy.initialize();
        copy.p.method = p.method;
        curl_slist* cur = p.headersOut;
        curl_slist* newlist = null;
        while (cur)
        {
            newlist = Curl.curl.slist_append(newlist, cur.data);
            cur = cur.next;
        }
        copy.p.headersOut = newlist;
        copy.p.curl.set(CurlOption.httpheader, copy.p.headersOut);
        copy.p.curl = p.curl.dup();
        copy.dataTimeout = _defaultDataTimeout;
        copy.onReceiveHeader = null;
        return copy;
    }

    private void initialize()
    {
        p.curl.initialize();
        maxRedirects = HTTP.defaultMaxRedirects;
        p.charset = "ISO-8859-1"; // Default charset defined in HTTP RFC
        p.method = Method.undefined;
        setUserAgent(HTTP.defaultUserAgent);
        dataTimeout = _defaultDataTimeout;
        onReceiveHeader = null;
        verifyPeer = true;
        verifyHost = true;
    }

    /**
       Perform a http request.

       After the HTTP client has been setup and possibly assigned callbacks the
       $(D perform()) method will start performing the request towards the
       specified server.

       Params:
       throwOnError = whether to throw an exception or return a CurlCode on error
    */
    CurlCode perform(ThrowOnError throwOnError = ThrowOnError.yes)
    {
        p.status.reset();

        CurlOption opt;
        final switch (p.method)
        {
        case Method.head:
            p.curl.set(CurlOption.nobody, 1L);
            opt = CurlOption.nobody;
            break;
        case Method.undefined:
        case Method.get:
            p.curl.set(CurlOption.httpget, 1L);
            opt = CurlOption.httpget;
            break;
        case Method.post:
            p.curl.set(CurlOption.post, 1L);
            opt = CurlOption.post;
            break;
        case Method.put:
            p.curl.set(CurlOption.upload, 1L);
            opt = CurlOption.upload;
            break;
        case Method.del:
            p.curl.set(CurlOption.customrequest, "DELETE");
            opt = CurlOption.customrequest;
            break;
        case Method.options:
            p.curl.set(CurlOption.customrequest, "OPTIONS");
            opt = CurlOption.customrequest;
            break;
        case Method.trace:
            p.curl.set(CurlOption.customrequest, "TRACE");
            opt = CurlOption.customrequest;
            break;
        case Method.connect:
            p.curl.set(CurlOption.customrequest, "CONNECT");
            opt = CurlOption.customrequest;
            break;
        case Method.patch:
            p.curl.set(CurlOption.customrequest, "PATCH");
			// FIX: missing method
            p.curl.set(CurlOption.post, 1L);
            opt = CurlOption.customrequest;
            break;
        }

        scope (exit) p.curl.clear(opt);
        return p.curl.perform(throwOnError);
    }

    /// The URL to specify the location of the resource.
    @property void url(const(char)[] url)
    {
        if (!startsWith(url.toLower(), "http://", "https://"))
            url = "http://" ~ url;
        p.curl.set(CurlOption.url, url);
    }

    /// Set the CA certificate bundle file to use for SSL peer verification
    @property void caInfo(const(char)[] caFile)
    {
        p.curl.set(CurlOption.cainfo, caFile);
    }

    // This is a workaround for mixed in content not having its
    // docs mixed in.
    version (StdDdoc)
    {
        /// Value to return from $(D onSend)/$(D onReceive) delegates in order to
        /// pause a request
        alias requestPause = CurlReadFunc.pause;

        /// Value to return from onSend delegate in order to abort a request
        alias requestAbort = CurlReadFunc.abort;

        /**
           True if the instance is stopped. A stopped instance is not usable.
        */
        @property bool isStopped();

        /// Stop and invalidate this instance.
        void shutdown();

        /** Set verbose.
            This will print request information to stderr.
        */
        @property void verbose(bool on);

        // Connection settings

        /// Set timeout for activity on connection.
        @property void dataTimeout(Duration d);

        /** Set maximum time an operation is allowed to take.
            This includes dns resolution, connecting, data transfer, etc.
          */
        @property void operationTimeout(Duration d);

        /// Set timeout for connecting.
        @property void connectTimeout(Duration d);

        // Network settings

        /** Proxy
         *  See: $(WEB curl.haxx.se/libcurl/c/curl_easy_setopt.html#CURLOPTPROXY, _proxy)
         */
        @property void proxy(const(char)[] host);

        /** Proxy port
         *  See: $(WEB curl.haxx.se/libcurl/c/curl_easy_setopt.html#CURLOPTPROXYPORT, _proxy_port)
         */
        @property void proxyPort(ushort port);

        /// Type of proxy
        alias CurlProxy = etc.c.curl.CurlProxy;

        /** Proxy type
         *  See: $(WEB curl.haxx.se/libcurl/c/curl_easy_setopt.html#CURLOPTPROXY, _proxy_type)
         */
        @property void proxyType(CurlProxy type);

        /// DNS lookup timeout.
        @property void dnsTimeout(Duration d);

        /**
         * The network interface to use in form of the the IP of the interface.
         *
         * Example:
         * ----
         * theprotocol.netInterface = "192.168.1.32";
         * theprotocol.netInterface = [ 192, 168, 1, 32 ];
         * ----
         *
         * See: $(XREF socket, InternetAddress)
         */
        @property void netInterface(const(char)[] i);

        /// ditto
        @property void netInterface(const(ubyte)[4] i);

        /// ditto
        @property void netInterface(InternetAddress i);

        /**
           Set the local outgoing port to use.
           Params:
           port = the first outgoing port number to try and use
        */
        @property void localPort(ushort port);

        /**
           Set the local outgoing port range to use.
           This can be used together with the localPort property.
           Params:
           range = if the first port is occupied then try this many
           port number forwards
        */
        @property void localPortRange(ushort range);

        /** Set the tcp no-delay socket option on or off.
            See: $(WEB curl.haxx.se/libcurl/c/curl_easy_setopt.html#CURLOPTTCPNODELAY, nodelay)
        */
        @property void tcpNoDelay(bool on);

        // Authentication settings

        /**
           Set the user name, password and optionally domain for authentication
           purposes.

           Some protocols may need authentication in some cases. Use this
           function to provide credentials.

           Params:
           username = the username
           password = the password
           domain = used for NTLM authentication only and is set to the NTLM domain
           name
        */
        void setAuthentication(const(char)[] username, const(char)[] password,
                               const(char)[] domain = "");

        /**
           Set the user name and password for proxy authentication.

           Params:
           username = the username
           password = the password
        */
        void setProxyAuthentication(const(char)[] username, const(char)[] password);

        /**
         * The event handler that gets called when data is needed for sending. The
         * length of the $(D void[]) specifies the maximum number of bytes that can
         * be sent.
         *
         * Returns:
         * The callback returns the number of elements in the buffer that have been
         * filled and are ready to send.
         * The special value $(D .abortRequest) can be returned in order to abort the
         * current request.
         * The special value $(D .pauseRequest) can be returned in order to pause the
         * current request.
         *
         * Example:
         * ----
         * import std.net.curl;
         * string msg = "Hello world";
         * auto client = HTTP("dlang.org");
         * client.onSend = delegate size_t(void[] data)
         * {
         *     auto m = cast(void[])msg;
         *     size_t length = m.length > data.length ? data.length : m.length;
         *     if (length == 0) return 0;
         *     data[0..length] = m[0..length];
         *     msg = msg[length..$];
         *     return length;
         * };
         * client.perform();
         * ----
         */
        @property void onSend(size_t delegate(void[]) callback);

        /**
         * The event handler that receives incoming data. Be sure to copy the
         * incoming ubyte[] since it is not guaranteed to be valid after the
         * callback returns.
         *
         * Returns:
         * The callback returns the incoming bytes read. If not the entire array is
         * the request will abort.
         * The special value .pauseRequest can be returned in order to pause the
         * current request.
         *
         * Example:
         * ----
         * import std.net.curl, std.stdio;
         * auto client = HTTP("dlang.org");
         * client.onReceive = (ubyte[] data)
         * {
         *     writeln("Got data", to!(const(char)[])(data));
         *     return data.length;
         * };
         * client.perform();
         * ----
         */
        @property void onReceive(size_t delegate(ubyte[]) callback);

        /**
         * Register an event handler that gets called to inform of
         * upload/download progress.
         *
         * Callback_parameters:
         * $(CALLBACK_PARAMS)
         *
         * Callback_returns: Return 0 to signal success, return non-zero to
         * abort transfer.
         *
         * Example:
         * ----
         * import std.net.curl, std.stdio;
         * auto client = HTTP("dlang.org");
         * client.onProgress = delegate int(size_t dl, size_t dln, size_t ul, size_t ult)
         * {
         *     writeln("Progress: downloaded ", dln, " of ", dl);
         *     writeln("Progress: uploaded ", uln, " of ", ul);
         * };
         * client.perform();
         * ----
         */
        @property void onProgress(int delegate(size_t dlTotal, size_t dlNow,
                                               size_t ulTotal, size_t ulNow) callback);
    }

    /** Clear all outgoing headers.
    */
    void clearRequestHeaders()
    {
        if (p.headersOut !is null)
            Curl.curl.slist_free_all(p.headersOut);
        p.headersOut = null;
        p.curl.clear(CurlOption.httpheader);
    }

    /** Add a header e.g. "X-CustomField: Something is fishy".
     *
     * There is no remove header functionality. Do a $(LREF clearRequestHeaders)
     * and set the needed headers instead.
     *
     * Example:
     * ---
     * import std.net.curl;
     * auto client = HTTP();
     * client.addRequestHeader("X-Custom-ABC", "This is the custom value");
     * auto content = get("dlang.org", client);
     * ---
     */
    void addRequestHeader(const(char)[] name, const(char)[] value)
    {
        if (icmp(name, "User-Agent") == 0)
            return setUserAgent(value);
        string nv = format("%s: %s", name, value);
        p.headersOut = Curl.curl.slist_append(p.headersOut,
                                              nv.tempCString().buffPtr);
        p.curl.set(CurlOption.httpheader, p.headersOut);
    }

    /**
     * The default "User-Agent" value send with a request.
     * It has the form "Phobos-std.net.curl/$(I PHOBOS_VERSION) (libcurl/$(I CURL_VERSION))"
     */
    static string defaultUserAgent() @property
    {
        import std.compiler : version_major, version_minor;

        // http://curl.haxx.se/docs/versions.html
        enum fmt = "Phobos-std.net.curl/%d.%03d (libcurl/%d.%d.%d)";
        enum maxLen = fmt.length - "%d%03d%d%d%d".length + 10 + 10 + 3 + 3 + 3;

        static char[maxLen] buf = void;
        static string userAgent;

        if (!userAgent.length)
        {
            auto curlVer = Curl.curl.version_info(CURLVERSION_NOW).version_num;
            userAgent = cast(immutable)sformat(
                buf, fmt, version_major, version_minor,
                curlVer >> 16 & 0xFF, curlVer >> 8 & 0xFF, curlVer & 0xFF);
        }
        return userAgent;
    }

    /** Set the value of the user agent request header field.
     *
     * By default a request has it's "User-Agent" field set to $(LREF
     * defaultUserAgent) even if $(D setUserAgent) was never called.  Pass
     * an empty string to suppress the "User-Agent" field altogether.
     */
    void setUserAgent(const(char)[] userAgent)
    {
        p.curl.set(CurlOption.useragent, userAgent);
    }

    /** The headers read from a successful response.
     *
     */
    @property string[string] responseHeaders()
    {
        return p.headersIn;
    }

    /// HTTP method used.
    @property void method(Method m)
    {
        p.method = m;
    }

    /// ditto
    @property Method method()
    {
        return p.method;
    }

    /**
       HTTP status line of last response. One call to perform may
       result in several requests because of redirection.
    */
    @property StatusLine statusLine()
    {
        return p.status;
    }

    /// Set the active cookie string e.g. "name1=value1;name2=value2"
    void setCookie(const(char)[] cookie)
    {
        p.curl.set(CurlOption.cookie, cookie);
    }

    /// Set a file path to where a cookie jar should be read/stored.
    void setCookieJar(const(char)[] path)
    {
        p.curl.set(CurlOption.cookiefile, path);
        if (path.length)
            p.curl.set(CurlOption.cookiejar, path);
    }

    /// Flush cookie jar to disk.
    void flushCookieJar()
    {
        p.curl.set(CurlOption.cookielist, "FLUSH");
    }

    /// Clear session cookies.
    void clearSessionCookies()
    {
        p.curl.set(CurlOption.cookielist, "SESS");
    }

    /// Clear all cookies.
    void clearAllCookies()
    {
        p.curl.set(CurlOption.cookielist, "ALL");
    }

    /**
       Set time condition on the request.

       Params:
       cond =  $(D CurlTimeCond.{none,ifmodsince,ifunmodsince,lastmod})
       timestamp = Timestamp for the condition

       $(WEB www.w3.org/Protocols/rfc2616/rfc2616-sec14.html#sec14.25, _RFC2616 Section 14.25)
    */
    void setTimeCondition(HTTP.TimeCond cond, SysTime timestamp)
    {
        p.curl.set(CurlOption.timecondition, cond);
        p.curl.set(CurlOption.timevalue, timestamp.toUnixTime());
    }

    /** Specifying data to post when not using the onSend callback.
      *
      * The data is NOT copied by the library.  Content-Type will default to
      * application/octet-stream.  Data is not converted or encoded by this
      * method.
      *
      * Example:
      * ----
      * import std.net.curl, std.stdio;
      * auto http = HTTP("http://www.mydomain.com");
      * http.onReceive = (ubyte[] data) { writeln(to!(const(char)[])(data)); return data.length; };
      * http.postData = [1,2,3,4,5];
      * http.perform();
      * ----
      */
    @property void postData(const(void)[] data)
    {
        setPostData(data, "application/octet-stream");
    }

    /** Specifying data to post when not using the onSend callback.
      *
      * The data is NOT copied by the library.  Content-Type will default to
      * text/plain.  Data is not converted or encoded by this method.
      *
      * Example:
      * ----
      * import std.net.curl, std.stdio;
      * auto http = HTTP("http://www.mydomain.com");
      * http.onReceive = (ubyte[] data) { writeln(to!(const(char)[])(data)); return data.length; };
      * http.postData = "The quick....";
      * http.perform();
      * ----
      */
    @property void postData(const(char)[] data)
    {
        setPostData(data, "text/plain");
    }

    /**
     * Specify data to post when not using the onSend callback, with
     * user-specified Content-Type.
     * Params:
     *  data = Data to post.
     *  contentType = MIME type of the data, for example, "text/plain" or
     *      "application/octet-stream". See also:
     *      $(LINK2 http://en.wikipedia.org/wiki/Internet_media_type,
     *      Internet media type) on Wikipedia.
     * -----
     * import std.net.curl;
     * auto http = HTTP("http://onlineform.example.com");
     * auto data = "app=login&username=bob&password=s00perS3kret";
     * http.setPostData(data, "application/x-www-form-urlencoded");
     * http.onReceive = (ubyte[] data) { return data.length; };
     * http.perform();
     * -----
     */
    void setPostData(const(void)[] data, string contentType)
    {
        // cannot use callback when specifying data directly so it is disabled here.
        p.curl.clear(CurlOption.readfunction);
        addRequestHeader("Content-Type", contentType);
        p.curl.set(CurlOption.postfields, cast(void*)data.ptr);
        p.curl.set(CurlOption.postfieldsize, data.length);
        if (method == Method.undefined)
            method = Method.post;
    }

    unittest
    {
        testServer.handle((s) {
            auto req = s.recvReq!ubyte;
            assert(req.hdrs.canFind("POST /path"));
            assert(req.bdy.canFind(cast(ubyte[])[0, 1, 2, 3, 4]));
            assert(req.bdy.canFind(cast(ubyte[])[253, 254, 255]));
            s.send(httpOK(cast(ubyte[])[17, 27, 35, 41]));
        });
        auto data = new ubyte[](256);
        foreach (i, ref ub; data)
            ub = cast(ubyte)i;

        auto http = HTTP(testServer.addr~"/path");
        http.postData = data;
        ubyte[] res;
        http.onReceive = (data) { res ~= data; return data.length; };
        http.perform();
        assert(res == cast(ubyte[])[17, 27, 35, 41]);
    }

    /**
      * Set the event handler that receives incoming headers.
      *
      * The callback will receive a header field key, value as parameter. The
      * $(D const(char)[]) arrays are not valid after the delegate has returned.
      *
      * Example:
      * ----
      * import std.net.curl, std.stdio;
      * auto http = HTTP("dlang.org");
      * http.onReceive = (ubyte[] data) { writeln(to!(const(char)[])(data)); return data.length; };
      * http.onReceiveHeader = (in char[] key, in char[] value) { writeln(key, " = ", value); };
      * http.perform();
      * ----
      */
    @property void onReceiveHeader(void delegate(in char[] key,
                                                 in char[] value) callback)
    {
        p.onReceiveHeader = callback;
    }

    /**
       Callback for each received StatusLine.

       Notice that several callbacks can be done for each call to
       $(D perform()) due to redirections.

       See_Also: $(LREF StatusLine)
     */
    @property void onReceiveStatusLine(void delegate(StatusLine) callback)
    {
        p.onReceiveStatusLine = callback;
    }

    /**
       The content length in bytes when using request that has content
       e.g. POST/PUT and not using chunked transfer. Is set as the
       "Content-Length" header.  Set to ulong.max to reset to chunked transfer.
    */
    @property void contentLength(ulong len)
    {
        CurlOption lenOpt;

        // Force post if necessary
        if (p.method != Method.put && p.method != Method.post &&
            p.method != Method.patch)
            p.method = Method.post;

        if (p.method == Method.post || p.method == Method.patch)
            lenOpt = CurlOption.postfieldsize_large;
        else
            lenOpt = CurlOption.infilesize_large;

        if (size_t.max != ulong.max && len == size_t.max)
            len = ulong.max; // check size_t.max for backwards compat, turn into error

        if (len == ulong.max)
        {
            // HTTP 1.1 supports requests with no length header set.
            addRequestHeader("Transfer-Encoding", "chunked");
            addRequestHeader("Expect", "100-continue");
        }
        else
        {
            p.curl.set(lenOpt, to!curl_off_t(len));
        }
    }

    /**
       Authentication method as specified in $(LREF AuthMethod).
    */
    @property void authenticationMethod(AuthMethod authMethod)
    {
        p.curl.set(CurlOption.httpauth, cast(long) authMethod);
    }

    /**
       Set max allowed redirections using the location header.
       uint.max for infinite.
    */
    @property void maxRedirects(uint maxRedirs)
    {
        if (maxRedirs == uint.max)
        {
            // Disable
            p.curl.set(CurlOption.followlocation, 0);
        }
        else
        {
            p.curl.set(CurlOption.followlocation, 1);
            p.curl.set(CurlOption.maxredirs, maxRedirs);
        }
    }

    /** <a name="HTTP.Method"/ >The standard HTTP methods :
     *  $(WEB www.w3.org/Protocols/rfc2616/rfc2616-sec5.html#sec5.1.1, _RFC2616 Section 5.1.1)
     */
    enum Method
    {
        undefined,
        head, ///
        get,  ///
        post, ///
        put,  ///
        del,  ///
        options, ///
        trace,   ///
        connect,  ///
        patch, ///
    }

    /**
       HTTP status line ie. the first line returned in an HTTP response.

       If authentication or redirections are done then the status will be for
       the last response received.
    */
    struct StatusLine
    {
        ushort majorVersion; /// Major HTTP version ie. 1 in HTTP/1.0.
        ushort minorVersion; /// Minor HTTP version ie. 0 in HTTP/1.0.
        ushort code;         /// HTTP status line code e.g. 200.
        string reason;       /// HTTP status line reason string.

        /// Reset this status line
        @safe void reset()
        {
            majorVersion = 0;
            minorVersion = 0;
            code = 0;
            reason = "";
        }

        ///
        string toString()
        {
            return format("%s %s (%s.%s)",
                          code, reason, majorVersion, minorVersion);
        }
    }

} // HTTP

/**
   FTP client functionality.

   See_Also: $(WEB tools.ietf.org/html/rfc959, RFC959)
*/
struct FTP
{

    mixin Protocol;

    private struct Impl
    {
        ~this()
        {
            if (commands !is null)
                Curl.curl.slist_free_all(commands);
            if (curl.handle !is null) // work around RefCounted/emplace bug
                curl.shutdown();
        }
        curl_slist* commands;
        Curl curl;
        string encoding;
    }

    private RefCounted!Impl p;

    /**
       FTP access to the specified url.
    */
    static FTP opCall(const(char)[] url)
    {
        FTP ftp;
        ftp.initialize();
        ftp.url = url;
        return ftp;
    }

    static FTP opCall()
    {
        FTP ftp;
        ftp.initialize();
        return ftp;
    }

    FTP dup()
    {
        FTP copy = FTP();
        copy.initialize();
        copy.p.encoding = p.encoding;
        copy.p.curl = p.curl.dup();
        curl_slist* cur = p.commands;
        curl_slist* newlist = null;
        while (cur)
        {
            newlist = Curl.curl.slist_append(newlist, cur.data);
            cur = cur.next;
        }
        copy.p.commands = newlist;
        copy.p.curl.set(CurlOption.postquote, copy.p.commands);
        copy.dataTimeout = _defaultDataTimeout;
        return copy;
    }

    private void initialize()
    {
        p.curl.initialize();
        p.encoding = "ISO-8859-1";
        dataTimeout = _defaultDataTimeout;
    }

    /**
       Performs the ftp request as it has been configured.

       After a FTP client has been setup and possibly assigned callbacks the $(D
       perform()) method will start performing the actual communication with the
       server.

       Params:
       throwOnError = whether to throw an exception or return a CurlCode on error
    */
    CurlCode perform(ThrowOnError throwOnError = ThrowOnError.yes)
    {
        return p.curl.perform(throwOnError);
    }

    /// The URL to specify the location of the resource.
    @property void url(const(char)[] url)
    {
        if (!startsWith(url.toLower(), "ftp://", "ftps://"))
            url = "ftp://" ~ url;
        p.curl.set(CurlOption.url, url);
    }

    // This is a workaround for mixed in content not having its
    // docs mixed in.
    version (StdDdoc)
    {
        /// Value to return from $(D onSend)/$(D onReceive) delegates in order to
        /// pause a request
        alias requestPause = CurlReadFunc.pause;

        /// Value to return from onSend delegate in order to abort a request
        alias requestAbort = CurlReadFunc.abort;

        /**
           True if the instance is stopped. A stopped instance is not usable.
        */
        @property bool isStopped();

        /// Stop and invalidate this instance.
        void shutdown();

        /** Set verbose.
            This will print request information to stderr.
        */
        @property void verbose(bool on);

        // Connection settings

        /// Set timeout for activity on connection.
        @property void dataTimeout(Duration d);

        /** Set maximum time an operation is allowed to take.
            This includes dns resolution, connecting, data transfer, etc.
          */
        @property void operationTimeout(Duration d);

        /// Set timeout for connecting.
        @property void connectTimeout(Duration d);

        // Network settings

        /** Proxy
         *  See: $(WEB curl.haxx.se/libcurl/c/curl_easy_setopt.html#CURLOPTPROXY, _proxy)
         */
        @property void proxy(const(char)[] host);

        /** Proxy port
         *  See: $(WEB curl.haxx.se/libcurl/c/curl_easy_setopt.html#CURLOPTPROXYPORT, _proxy_port)
         */
        @property void proxyPort(ushort port);

        /// Type of proxy
        alias CurlProxy = etc.c.curl.CurlProxy;

        /** Proxy type
         *  See: $(WEB curl.haxx.se/libcurl/c/curl_easy_setopt.html#CURLOPTPROXY, _proxy_type)
         */
        @property void proxyType(CurlProxy type);

        /// DNS lookup timeout.
        @property void dnsTimeout(Duration d);

        /**
         * The network interface to use in form of the the IP of the interface.
         *
         * Example:
         * ----
         * theprotocol.netInterface = "192.168.1.32";
         * theprotocol.netInterface = [ 192, 168, 1, 32 ];
         * ----
         *
         * See: $(XREF socket, InternetAddress)
         */
        @property void netInterface(const(char)[] i);

        /// ditto
        @property void netInterface(const(ubyte)[4] i);

        /// ditto
        @property void netInterface(InternetAddress i);

        /**
           Set the local outgoing port to use.
           Params:
           port = the first outgoing port number to try and use
        */
        @property void localPort(ushort port);

        /**
           Set the local outgoing port range to use.
           This can be used together with the localPort property.
           Params:
           range = if the first port is occupied then try this many
           port number forwards
        */
        @property void localPortRange(ushort range);

        /** Set the tcp no-delay socket option on or off.
            See: $(WEB curl.haxx.se/libcurl/c/curl_easy_setopt.html#CURLOPTTCPNODELAY, nodelay)
        */
        @property void tcpNoDelay(bool on);

        // Authentication settings

        /**
           Set the user name, password and optionally domain for authentication
           purposes.

           Some protocols may need authentication in some cases. Use this
           function to provide credentials.

           Params:
           username = the username
           password = the password
           domain = used for NTLM authentication only and is set to the NTLM domain
           name
        */
        void setAuthentication(const(char)[] username, const(char)[] password,
                               const(char)[] domain = "");

        /**
           Set the user name and password for proxy authentication.

           Params:
           username = the username
           password = the password
        */
        void setProxyAuthentication(const(char)[] username, const(char)[] password);

        /**
         * The event handler that gets called when data is needed for sending. The
         * length of the $(D void[]) specifies the maximum number of bytes that can
         * be sent.
         *
         * Returns:
         * The callback returns the number of elements in the buffer that have been
         * filled and are ready to send.
         * The special value $(D .abortRequest) can be returned in order to abort the
         * current request.
         * The special value $(D .pauseRequest) can be returned in order to pause the
         * current request.
         *
         */
        @property void onSend(size_t delegate(void[]) callback);

        /**
         * The event handler that receives incoming data. Be sure to copy the
         * incoming ubyte[] since it is not guaranteed to be valid after the
         * callback returns.
         *
         * Returns:
         * The callback returns the incoming bytes read. If not the entire array is
         * the request will abort.
         * The special value .pauseRequest can be returned in order to pause the
         * current request.
         *
         */
        @property void onReceive(size_t delegate(ubyte[]) callback);

        /**
         * The event handler that gets called to inform of upload/download progress.
         *
         * Callback_parameters:
         * $(CALLBACK_PARAMS)
         *
         * Callback_returns:
         * Return 0 from the callback to signal success, return non-zero to
         * abort transfer.
         */
        @property void onProgress(int delegate(size_t dlTotal, size_t dlNow,
                                               size_t ulTotal, size_t ulNow) callback);
    }

    /** Clear all commands send to ftp server.
    */
    void clearCommands()
    {
        if (p.commands !is null)
            Curl.curl.slist_free_all(p.commands);
        p.commands = null;
        p.curl.clear(CurlOption.postquote);
    }

    /** Add a command to send to ftp server.
     *
     * There is no remove command functionality. Do a $(LREF clearCommands) and
     * set the needed commands instead.
     *
     * Example:
     * ---
     * import std.net.curl;
     * auto client = FTP();
     * client.addCommand("RNFR my_file.txt");
     * client.addCommand("RNTO my_renamed_file.txt");
     * upload("my_file.txt", "ftp.digitalmars.com", client);
     * ---
     */
    void addCommand(const(char)[] command)
    {
        p.commands = Curl.curl.slist_append(p.commands,
                                            command.tempCString().buffPtr);
        p.curl.set(CurlOption.postquote, p.commands);
    }

    /// Connection encoding. Defaults to ISO-8859-1.
    @property void encoding(string name)
    {
        p.encoding = name;
    }

    /// ditto
    @property string encoding()
    {
        return p.encoding;
    }

    /**
       The content length in bytes of the ftp data.
    */
    @property void contentLength(ulong len)
    {
        p.curl.set(CurlOption.infilesize_large, to!curl_off_t(len));
    }
}

/**
  * Basic SMTP protocol support.
  *
  * Example:
  * ---
  * import std.net.curl;
  *
  * // Send an email with SMTPS
  * auto smtp = SMTP("smtps://smtp.gmail.com");
  * smtp.setAuthentication("from.addr@gmail.com", "password");
  * smtp.mailTo = ["<to.addr@gmail.com>"];
  * smtp.mailFrom = "<from.addr@gmail.com>";
  * smtp.message = "Example Message";
  * smtp.perform();
  * ---
  *
  * See_Also: $(WEB www.ietf.org/rfc/rfc2821.txt, RFC2821)
  */
struct SMTP
{
    mixin Protocol;

    private struct Impl
    {
        ~this()
        {
            if (curl.handle !is null) // work around RefCounted/emplace bug
                curl.shutdown();
        }
        Curl curl;

        @property void message(string msg)
        {
            auto _message = msg;
            /**
                This delegate reads the message text and copies it.
            */
            curl.onSend = delegate size_t(void[] data)
            {
                if (!msg.length) return 0;
                auto m = cast(void[])msg;
                size_t to_copy = min(data.length, _message.length);
                data[0..to_copy] = (cast(void[])_message)[0..to_copy];
                _message = _message[to_copy..$];
                return to_copy;
            };
        }
    }

    private RefCounted!Impl p;

    /**
        Sets to the URL of the SMTP server.
    */
    static SMTP opCall(const(char)[] url)
    {
        SMTP smtp;
        smtp.initialize();
        smtp.url = url;
        return smtp;
    }

    static SMTP opCall()
    {
        SMTP smtp;
        smtp.initialize();
        return smtp;
    }

    /+ TODO: The other structs have this function.
    SMTP dup()
    {
        SMTP copy = SMTP();
        copy.initialize();
        copy.p.encoding = p.encoding;
        copy.p.curl = p.curl.dup();
        curl_slist* cur = p.commands;
        curl_slist* newlist = null;
        while (cur)
        {
            newlist = Curl.curl.slist_append(newlist, cur.data);
            cur = cur.next;
        }
        copy.p.commands = newlist;
        copy.p.curl.set(CurlOption.postquote, copy.p.commands);
        copy.dataTimeout = _defaultDataTimeout;
        return copy;
    }
    +/

    /**
        Performs the request as configured.
        Params:
        throwOnError = whether to throw an exception or return a CurlCode on error
    */
    CurlCode perform(ThrowOnError throwOnError = ThrowOnError.yes)
    {
        return p.curl.perform(throwOnError);
    }

    /// The URL to specify the location of the resource.
    @property void url(const(char)[] url)
    {
        auto lowered = url.toLower();

        if (lowered.startsWith("smtps://"))
        {
            p.curl.set(CurlOption.use_ssl, CurlUseSSL.all);
        }
        else
        {
            enforce!CurlException(lowered.startsWith("smtp://"),
                                    "The url must be for the smtp protocol.");
        }
        p.curl.set(CurlOption.url, url);
    }

    private void initialize()
    {
        p.curl.initialize();
        p.curl.set(CurlOption.upload, 1L);
        dataTimeout = _defaultDataTimeout;
        verifyPeer = true;
        verifyHost = true;
    }

    // This is a workaround for mixed in content not having its
    // docs mixed in.
    version (StdDdoc)
    {
        /// Value to return from $(D onSend)/$(D onReceive) delegates in order to
        /// pause a request
        alias requestPause = CurlReadFunc.pause;

        /// Value to return from onSend delegate in order to abort a request
        alias requestAbort = CurlReadFunc.abort;

        /**
           True if the instance is stopped. A stopped instance is not usable.
        */
        @property bool isStopped();

        /// Stop and invalidate this instance.
        void shutdown();

        /** Set verbose.
            This will print request information to stderr.
        */
        @property void verbose(bool on);

        // Connection settings

        /// Set timeout for activity on connection.
        @property void dataTimeout(Duration d);

        /** Set maximum time an operation is allowed to take.
            This includes dns resolution, connecting, data transfer, etc.
          */
        @property void operationTimeout(Duration d);

        /// Set timeout for connecting.
        @property void connectTimeout(Duration d);

        // Network settings

        /** Proxy
         *  See: $(WEB curl.haxx.se/libcurl/c/curl_easy_setopt.html#CURLOPTPROXY, _proxy)
         */
        @property void proxy(const(char)[] host);

        /** Proxy port
         *  See: $(WEB curl.haxx.se/libcurl/c/curl_easy_setopt.html#CURLOPTPROXYPORT, _proxy_port)
         */
        @property void proxyPort(ushort port);

        /// Type of proxy
        alias CurlProxy = etc.c.curl.CurlProxy;

        /** Proxy type
         *  See: $(WEB curl.haxx.se/libcurl/c/curl_easy_setopt.html#CURLOPTPROXY, _proxy_type)
         */
        @property void proxyType(CurlProxy type);

        /// DNS lookup timeout.
        @property void dnsTimeout(Duration d);

        /**
         * The network interface to use in form of the the IP of the interface.
         *
         * Example:
         * ----
         * theprotocol.netInterface = "192.168.1.32";
         * theprotocol.netInterface = [ 192, 168, 1, 32 ];
         * ----
         *
         * See: $(XREF socket, InternetAddress)
         */
        @property void netInterface(const(char)[] i);

        /// ditto
        @property void netInterface(const(ubyte)[4] i);

        /// ditto
        @property void netInterface(InternetAddress i);

        /**
           Set the local outgoing port to use.
           Params:
           port = the first outgoing port number to try and use
        */
        @property void localPort(ushort port);

        /**
           Set the local outgoing port range to use.
           This can be used together with the localPort property.
           Params:
           range = if the first port is occupied then try this many
           port number forwards
        */
        @property void localPortRange(ushort range);

        /** Set the tcp no-delay socket option on or off.
            See: $(WEB curl.haxx.se/libcurl/c/curl_easy_setopt.html#CURLOPTTCPNODELAY, nodelay)
        */
        @property void tcpNoDelay(bool on);

        // Authentication settings

        /**
           Set the user name, password and optionally domain for authentication
           purposes.

           Some protocols may need authentication in some cases. Use this
           function to provide credentials.

           Params:
           username = the username
           password = the password
           domain = used for NTLM authentication only and is set to the NTLM domain
           name
        */
        void setAuthentication(const(char)[] username, const(char)[] password,
                               const(char)[] domain = "");

        /**
           Set the user name and password for proxy authentication.

           Params:
           username = the username
           password = the password
        */
        void setProxyAuthentication(const(char)[] username, const(char)[] password);

        /**
         * The event handler that gets called when data is needed for sending. The
         * length of the $(D void[]) specifies the maximum number of bytes that can
         * be sent.
         *
         * Returns:
         * The callback returns the number of elements in the buffer that have been
         * filled and are ready to send.
         * The special value $(D .abortRequest) can be returned in order to abort the
         * current request.
         * The special value $(D .pauseRequest) can be returned in order to pause the
         * current request.
         */
        @property void onSend(size_t delegate(void[]) callback);

        /**
         * The event handler that receives incoming data. Be sure to copy the
         * incoming ubyte[] since it is not guaranteed to be valid after the
         * callback returns.
         *
         * Returns:
         * The callback returns the incoming bytes read. If not the entire array is
         * the request will abort.
         * The special value .pauseRequest can be returned in order to pause the
         * current request.
         */
        @property void onReceive(size_t delegate(ubyte[]) callback);

        /**
         * The event handler that gets called to inform of upload/download progress.
         *
         * Callback_parameters:
         * $(CALLBACK_PARAMS)
         *
         * Callback_returns:
         * Return 0 from the callback to signal success, return non-zero to
         * abort transfer.
         */
        @property void onProgress(int delegate(size_t dlTotal, size_t dlNow,
                                               size_t ulTotal, size_t ulNow) callback);
    }

    /**
        Setter for the sender's email address.
    */
    @property void mailFrom()(const(char)[] sender)
    {
        assert(!sender.empty, "Sender must not be empty");
        p.curl.set(CurlOption.mail_from, sender);
    }

    /**
        Setter for the recipient email addresses.
    */
    void mailTo()(const(char)[][] recipients...)
    {
        assert(!recipients.empty, "Recipient must not be empty");
        curl_slist* recipients_list = null;
        foreach(recipient; recipients)
        {
            recipients_list =
                Curl.curl.slist_append(recipients_list,
                                  recipient.tempCString().buffPtr);
        }
        p.curl.set(CurlOption.mail_rcpt, recipients_list);
    }

    /**
        Sets the message body text.
    */

    @property void message(string msg)
    {
        p.message = msg;
    }
}

/++
    Exception thrown on errors in std.net.curl functions.
+/
class CurlException : Exception
{
    /++
        Params:
            msg  = The message for the exception.
            file = The file where the exception occurred.
            line = The line number where the exception occurred.
            next = The previous exception in the chain of exceptions, if any.
      +/
    @safe pure nothrow
    this(string msg,
         string file = __FILE__,
         size_t line = __LINE__,
         Throwable next = null)
    {
        super(msg, file, line, next);
    }
}

/++
    Exception thrown on timeout errors in std.net.curl functions.
+/
class CurlTimeoutException : CurlException
{
    /++
        Params:
            msg  = The message for the exception.
            file = The file where the exception occurred.
            line = The line number where the exception occurred.
            next = The previous exception in the chain of exceptions, if any.
      +/
    @safe pure nothrow
    this(string msg,
         string file = __FILE__,
         size_t line = __LINE__,
         Throwable next = null)
    {
        super(msg, file, line, next);
    }
}

/// Equal to $(ECXREF curl, CURLcode)
alias CurlCode = CURLcode;

import std.typecons : Flag;
/// Flag to specify whether or not an exception is thrown on error.
alias ThrowOnError = Flag!"throwOnError";

private struct CurlAPI
{
    static struct API
    {
    extern(C):
        import core.stdc.config : c_long;
        CURLcode function(c_long flags) global_init;
        void function() global_cleanup;
        curl_version_info_data * function(CURLversion) version_info;
        CURL* function() easy_init;
        CURLcode function(CURL *curl, CURLoption option,...) easy_setopt;
        CURLcode function(CURL *curl) easy_perform;
        CURL* function(CURL *curl) easy_duphandle;
        char* function(CURLcode) easy_strerror;
        CURLcode function(CURL *handle, int bitmask) easy_pause;
        void function(CURL *curl) easy_cleanup;
        curl_slist* function(curl_slist *, char *) slist_append;
        void function(curl_slist *) slist_free_all;
    }
    __gshared API _api;
    __gshared void* _handle;

    static ref API instance() @property
    {
        import std.concurrency;
        initOnce!_handle(loadAPI());
        return _api;
    }

    static void* loadAPI()
    {
        version (Posix)
        {
            import core.sys.posix.dlfcn;
            alias loadSym = dlsym;
        }
        else version (Windows)
        {
            import core.sys.windows.windows;
            alias loadSym = GetProcAddress;
        }
        else
            static assert(0, "unimplemented");

        void* handle;
        version (Posix)
            handle = dlopen(null, RTLD_LAZY);
        else version (Windows)
            handle = GetModuleHandleA(null);
        assert(handle !is null);

        // try to load curl from the executable to allow static linking
        if (loadSym(handle, "curl_global_init") is null)
        {
            version (Posix)
                dlclose(handle);

            version (OSX)
                static immutable names = ["libcurl.4.dylib"];
            else version (Posix)
                static immutable names = ["libcurl.so", "libcurl.so.4", "libcurl-gnutls.so.4", "libcurl-nss.so.4", "libcurl.so.3"];
            else version (Windows)
                static immutable names = ["libcurl.dll", "curl.dll"];

            foreach (name; names)
            {
                version (Posix)
                    handle = dlopen(name.ptr, RTLD_LAZY);
                else version (Windows)
                    handle = LoadLibraryA(name.ptr);
                if (handle !is null) break;
            }

            enforce!CurlException(handle !is null, "Failed to load curl, tried %(%s, %).".format(names));
        }

        foreach (mem; __traits(allMembers, API))
        {
            void* p = loadSym(handle, "curl_"~mem);

            __traits(getMember, _api, mem) = cast(typeof(__traits(getMember, _api, mem)))
                enforce!CurlException(p, "Couldn't load curl_"~mem~" from libcurl.");
        }

        enforce!CurlException(!_api.global_init(CurlGlobal.all),
                              "Failed to initialize libcurl");

        return handle;
    }

    shared static ~this()
    {
        if (_handle is null) return;

        _api.global_cleanup();
        version (Posix)
        {
            import core.sys.posix.dlfcn;
            dlclose(_handle);
        }
        else version (Windows)
        {
            import core.sys.windows.windows;
            FreeLibrary(_handle);
        }
        else
            static assert(0, "unimplemented");

        _api = API.init;
        _handle = null;
    }
}

/**
  Wrapper to provide a better interface to libcurl than using the plain C API.
  It is recommended to use the $(D HTTP)/$(D FTP) etc. structs instead unless
  raw access to libcurl is needed.

  Warning: This struct uses interior pointers for callbacks. Only allocate it
  on the stack if you never move or copy it. This also means passing by reference
  when passing Curl to other functions. Otherwise always allocate on
  the heap.
*/
struct Curl
{
    alias OutData = void[];
    alias InData = ubyte[];
    bool stopped;

    private static auto ref curl() @property { return CurlAPI.instance(); }

    // A handle should not be used by two threads simultaneously
    private CURL* handle;

    // May also return $(D CURL_READFUNC_ABORT) or $(D CURL_READFUNC_PAUSE)
    private size_t delegate(OutData) _onSend;
    private size_t delegate(InData) _onReceive;
    private void delegate(in char[]) _onReceiveHeader;
    private CurlSeek delegate(long,CurlSeekPos) _onSeek;
    private int delegate(curl_socket_t,CurlSockType) _onSocketOption;
    private int delegate(size_t dltotal, size_t dlnow,
                         size_t ultotal, size_t ulnow) _onProgress;

    alias requestPause = CurlReadFunc.pause;
    alias requestAbort = CurlReadFunc.abort;

    /**
       Initialize the instance by creating a working curl handle.
    */
    void initialize()
    {
        enforce!CurlException(!handle, "Curl instance already initialized");
        handle = curl.easy_init();
        enforce!CurlException(handle, "Curl instance couldn't be initialized");
        stopped = false;
        set(CurlOption.nosignal, 1);
    }

    /**
       Duplicate this handle.

       The new handle will have all options set as the one it was duplicated
       from. An exception to this is that all options that cannot be shared
       across threads are reset thereby making it safe to use the duplicate
       in a new thread.
    */
    Curl dup()
    {
        Curl copy;
        copy.handle = curl.easy_duphandle(handle);
        copy.stopped = false;

        with (CurlOption) {
            auto tt = TypeTuple!(file, writefunction, writeheader,
                headerfunction, infile, readfunction, ioctldata, ioctlfunction,
                seekdata, seekfunction, sockoptdata, sockoptfunction,
                opensocketdata, opensocketfunction, progressdata,
                progressfunction, debugdata, debugfunction, interleavedata,
                interleavefunction, chunk_data, chunk_bgn_function,
                chunk_end_function, fnmatch_data, fnmatch_function, cookiejar, postfields);

            foreach(option; tt)
                copy.clear(option);
        }

        // The options are only supported by libcurl when it has been built
        // against certain versions of OpenSSL - if your libcurl uses an old
        // OpenSSL, or uses an entirely different SSL engine, attempting to
        // clear these normally will raise an exception
        copy.clearIfSupported(CurlOption.ssl_ctx_function);
        copy.clearIfSupported(CurlOption.ssh_keydata);

        // Enable for curl version > 7.21.7
        static if (LIBCURL_VERSION_MAJOR >= 7 &&
                   LIBCURL_VERSION_MINOR >= 21 &&
                   LIBCURL_VERSION_PATCH >= 7)
        {
            copy.clear(CurlOption.closesocketdata);
            copy.clear(CurlOption.closesocketfunction);
        }

        copy.set(CurlOption.nosignal, 1);

        // copy.clear(CurlOption.ssl_ctx_data); Let ssl function be shared
        // copy.clear(CurlOption.ssh_keyfunction); Let key function be shared

        /*
          Allow sharing of conv functions
          copy.clear(CurlOption.conv_to_network_function);
          copy.clear(CurlOption.conv_from_network_function);
          copy.clear(CurlOption.conv_from_utf8_function);
        */

        return copy;
    }

    private void _check(CurlCode code)
    {
        enforce!CurlTimeoutException(code != CurlError.operation_timedout,
                                       errorString(code));

        enforce!CurlException(code == CurlError.ok,
                                errorString(code));
    }

    private string errorString(CurlCode code)
    {
        import core.stdc.string : strlen;

        auto msgZ = curl.easy_strerror(code);
        // doing the following (instead of just using std.conv.to!string) avoids 1 allocation
        return format("%s on handle %s", msgZ[0 .. core.stdc.string.strlen(msgZ)], handle);
    }

    private void throwOnStopped(string message = null)
    {
        auto def = "Curl instance called after being cleaned up";
        enforce!CurlException(!stopped,
                                message == null ? def : message);
    }

    /**
        Stop and invalidate this curl instance.
        Warning: Do not call this from inside a callback handler e.g. $(D onReceive).
    */
    void shutdown()
    {
        throwOnStopped();
        stopped = true;
        curl.easy_cleanup(this.handle);
        this.handle = null;
    }

    /**
       Pausing and continuing transfers.
    */
    void pause(bool sendingPaused, bool receivingPaused)
    {
        throwOnStopped();
        _check(curl.easy_pause(this.handle,
                               (sendingPaused ? CurlPause.send_cont : CurlPause.send) |
                               (receivingPaused ? CurlPause.recv_cont : CurlPause.recv)));
    }

    /**
       Set a string curl option.
       Params:
       option = A $(ECXREF curl, CurlOption) as found in the curl documentation
       value = The string
    */
    void set(CurlOption option, const(char)[] value)
    {
        throwOnStopped();
        _check(curl.easy_setopt(this.handle, option, value.tempCString().buffPtr));
    }

    /**
       Set a long curl option.
       Params:
       option = A $(ECXREF curl, CurlOption) as found in the curl documentation
       value = The long
    */
    void set(CurlOption option, long value)
    {
        throwOnStopped();
        _check(curl.easy_setopt(this.handle, option, value));
    }

    /**
       Set a void* curl option.
       Params:
       option = A $(ECXREF curl, CurlOption) as found in the curl documentation
       value = The pointer
    */
    void set(CurlOption option, void* value)
    {
        throwOnStopped();
        _check(curl.easy_setopt(this.handle, option, value));
    }

    /**
       Clear a pointer option.
       Params:
       option = A $(ECXREF curl, CurlOption) as found in the curl documentation
    */
    void clear(CurlOption option)
    {
        throwOnStopped();
        _check(curl.easy_setopt(this.handle, option, null));
    }

    /**
       Clear a pointer option. Does not raise an exception if the underlying
       libcurl does not support the option. Use sparingly.
       Params:
       option = A $(ECXREF curl, CurlOption) as found in the curl documentation
    */
    void clearIfSupported(CurlOption option)
    {
        throwOnStopped();
        auto rval = curl.easy_setopt(this.handle, option, null);
        if (rval != CurlError.unknown_option && rval != CurlError.not_built_in)
            _check(rval);
    }

    /**
       perform the curl request by doing the HTTP,FTP etc. as it has
       been setup beforehand.

       Params:
       throwOnError = whether to throw an exception or return a CurlCode on error
    */
    CurlCode perform(ThrowOnError throwOnError = ThrowOnError.yes)
    {
        throwOnStopped();
        CurlCode code = curl.easy_perform(this.handle);
        if (throwOnError)
            _check(code);
        return code;
    }

    // Explicitly undocumented. It will be removed in November 2015.
    deprecated("Pass ThrowOnError.yes or .no instead of a boolean.")
    CurlCode perform(bool throwOnError)
    {
        return perform(cast(ThrowOnError)throwOnError);
    }

    /**
      * The event handler that receives incoming data.
      *
      * Params:
      * callback = the callback that receives the $(D ubyte[]) data.
      * Be sure to copy the incoming data and not store
      * a slice.
      *
      * Returns:
      * The callback returns the incoming bytes read. If not the entire array is
      * the request will abort.
      * The special value HTTP.pauseRequest can be returned in order to pause the
      * current request.
      *
      * Example:
      * ----
      * import std.net.curl, std.stdio;
      * Curl curl;
      * curl.initialize();
      * curl.set(CurlOption.url, "http://dlang.org");
      * curl.onReceive = (ubyte[] data) { writeln("Got data", to!(const(char)[])(data)); return data.length;};
      * curl.perform();
      * ----
      */
    @property void onReceive(size_t delegate(InData) callback)
    {
        _onReceive = (InData id)
        {
            throwOnStopped("Receive callback called on cleaned up Curl instance");
            return callback(id);
        };
        set(CurlOption.file, cast(void*) &this);
        set(CurlOption.writefunction, cast(void*) &Curl._receiveCallback);
    }

    /**
      * The event handler that receives incoming headers for protocols
      * that uses headers.
      *
      * Params:
      * callback = the callback that receives the header string.
      * Make sure the callback copies the incoming params if
      * it needs to store it because they are references into
      * the backend and may very likely change.
      *
      * Example:
      * ----
      * import std.net.curl, std.stdio;
      * Curl curl;
      * curl.initialize();
      * curl.set(CurlOption.url, "http://dlang.org");
      * curl.onReceiveHeader = (in char[] header) { writeln(header); };
      * curl.perform();
      * ----
      */
    @property void onReceiveHeader(void delegate(in char[]) callback)
    {
        _onReceiveHeader = (in char[] od)
        {
            throwOnStopped("Receive header callback called on "~
                           "cleaned up Curl instance");
            callback(od);
        };
        set(CurlOption.writeheader, cast(void*) &this);
        set(CurlOption.headerfunction,
            cast(void*) &Curl._receiveHeaderCallback);
    }

    /**
      * The event handler that gets called when data is needed for sending.
      *
      * Params:
      * callback = the callback that has a $(D void[]) buffer to be filled
      *
      * Returns:
      * The callback returns the number of elements in the buffer that have been
      * filled and are ready to send.
      * The special value $(D Curl.abortRequest) can be returned in
      * order to abort the current request.
      * The special value $(D Curl.pauseRequest) can be returned in order to
      * pause the current request.
      *
      * Example:
      * ----
      * import std.net.curl;
      * Curl curl;
      * curl.initialize();
      * curl.set(CurlOption.url, "http://dlang.org");
      *
      * string msg = "Hello world";
      * curl.onSend = (void[] data)
      * {
      *     auto m = cast(void[])msg;
      *     size_t length = m.length > data.length ? data.length : m.length;
      *     if (length == 0) return 0;
      *     data[0..length] = m[0..length];
      *     msg = msg[length..$];
      *     return length;
      * };
      * curl.perform();
      * ----
      */
    @property void onSend(size_t delegate(OutData) callback)
    {
        _onSend = (OutData od)
        {
            throwOnStopped("Send callback called on cleaned up Curl instance");
            return callback(od);
        };
        set(CurlOption.infile, cast(void*) &this);
        set(CurlOption.readfunction, cast(void*) &Curl._sendCallback);
    }

    /**
      * The event handler that gets called when the curl backend needs to seek
      * the data to be sent.
      *
      * Params:
      * callback = the callback that receives a seek offset and a seek position
      *            $(ECXREF curl, CurlSeekPos)
      *
      * Returns:
      * The callback returns the success state of the seeking
      * $(ECXREF curl, CurlSeek)
      *
      * Example:
      * ----
      * import std.net.curl;
      * Curl curl;
      * curl.initialize();
      * curl.set(CurlOption.url, "http://dlang.org");
      * curl.onSeek = (long p, CurlSeekPos sp)
      * {
      *     return CurlSeek.cantseek;
      * };
      * curl.perform();
      * ----
      */
    @property void onSeek(CurlSeek delegate(long, CurlSeekPos) callback)
    {
        _onSeek = (long ofs, CurlSeekPos sp)
        {
            throwOnStopped("Seek callback called on cleaned up Curl instance");
            return callback(ofs, sp);
        };
        set(CurlOption.seekdata, cast(void*) &this);
        set(CurlOption.seekfunction, cast(void*) &Curl._seekCallback);
    }

    /**
      * The event handler that gets called when the net socket has been created
      * but a $(D connect()) call has not yet been done. This makes it possible to set
      * misc. socket options.
      *
      * Params:
      * callback = the callback that receives the socket and socket type
      * $(ECXREF curl, CurlSockType)
      *
      * Returns:
      * Return 0 from the callback to signal success, return 1 to signal error
      * and make curl close the socket
      *
      * Example:
      * ----
      * import std.net.curl;
      * Curl curl;
      * curl.initialize();
      * curl.set(CurlOption.url, "http://dlang.org");
      * curl.onSocketOption = delegate int(curl_socket_t s, CurlSockType t) { /+ do stuff +/ };
      * curl.perform();
      * ----
      */
    @property void onSocketOption(int delegate(curl_socket_t,
                                               CurlSockType) callback)
    {
        _onSocketOption = (curl_socket_t sock, CurlSockType st)
        {
            throwOnStopped("Socket option callback called on "~
                           "cleaned up Curl instance");
            return callback(sock, st);
        };
        set(CurlOption.sockoptdata, cast(void*) &this);
        set(CurlOption.sockoptfunction,
            cast(void*) &Curl._socketOptionCallback);
    }

    /**
      * The event handler that gets called to inform of upload/download progress.
      *
      * Params:
      * callback = the callback that receives the (total bytes to download,
      * currently downloaded bytes, total bytes to upload, currently uploaded
      * bytes).
      *
      * Returns:
      * Return 0 from the callback to signal success, return non-zero to abort
      * transfer
      *
      * Example:
      * ----
      * import std.net.curl;
      * Curl curl;
      * curl.initialize();
      * curl.set(CurlOption.url, "http://dlang.org");
      * curl.onProgress = delegate int(size_t dltotal, size_t dlnow, size_t ultotal, size_t uln)
      * {
      *     writeln("Progress: downloaded bytes ", dlnow, " of ", dltotal);
      *     writeln("Progress: uploaded bytes ", ulnow, " of ", ultotal);
      *     curl.perform();
      * };
      * ----
      */
    @property void onProgress(int delegate(size_t dlTotal,
                                           size_t dlNow,
                                           size_t ulTotal,
                                           size_t ulNow) callback)
    {
        _onProgress = (size_t dlt, size_t dln, size_t ult, size_t uln)
        {
            throwOnStopped("Progress callback called on cleaned "~
                           "up Curl instance");
            return callback(dlt, dln, ult, uln);
        };
        set(CurlOption.noprogress, 0);
        set(CurlOption.progressdata, cast(void*) &this);
        set(CurlOption.progressfunction, cast(void*) &Curl._progressCallback);
    }

    // Internal C callbacks to register with libcurl
    extern (C) private static
    size_t _receiveCallback(const char* str,
                            size_t size, size_t nmemb, void* ptr)
    {
        auto b = cast(Curl*) ptr;
        if (b._onReceive != null)
            return b._onReceive(cast(InData)(str[0..size*nmemb]));
        return size*nmemb;
    }

    extern (C) private static
    size_t _receiveHeaderCallback(const char* str,
                                  size_t size, size_t nmemb, void* ptr)
    {
        auto b = cast(Curl*) ptr;
        auto s = str[0..size*nmemb].chomp();
        if (b._onReceiveHeader != null)
            b._onReceiveHeader(s);

        return size*nmemb;
    }

    extern (C) private static
    size_t _sendCallback(char *str, size_t size, size_t nmemb, void *ptr)
    {
        Curl* b = cast(Curl*) ptr;
        auto a = cast(void[]) str[0..size*nmemb];
        if (b._onSend == null)
            return 0;
        return b._onSend(a);
    }

    extern (C) private static
    int _seekCallback(void *ptr, curl_off_t offset, int origin)
    {
        auto b = cast(Curl*) ptr;
        if (b._onSeek == null)
            return CurlSeek.cantseek;

        // origin: CurlSeekPos.set/current/end
        // return: CurlSeek.ok/fail/cantseek
        return b._onSeek(cast(long) offset, cast(CurlSeekPos) origin);
    }

    extern (C) private static
    int _socketOptionCallback(void *ptr,
                              curl_socket_t curlfd, curlsocktype purpose)
    {
        auto b = cast(Curl*) ptr;
        if (b._onSocketOption == null)
            return 0;

        // return: 0 ok, 1 fail
        return b._onSocketOption(curlfd, cast(CurlSockType) purpose);
    }

    extern (C) private static
    int _progressCallback(void *ptr,
                          double dltotal, double dlnow,
                          double ultotal, double ulnow)
    {
        auto b = cast(Curl*) ptr;
        if (b._onProgress == null)
            return 0;

        // return: 0 ok, 1 fail
        return b._onProgress(cast(size_t)dltotal, cast(size_t)dlnow,
                             cast(size_t)ultotal, cast(size_t)ulnow);
    }

}

// Internal messages send between threads.
// The data is wrapped in this struct in order to ensure that
// other std.concurrency.receive calls does not pick up our messages
// by accident.
private struct CurlMessage(T)
{
    public T data;
}

private static CurlMessage!T curlMessage(T)(T data)
{
    return CurlMessage!T(data);
}

// Pool of to be used for reusing buffers
private struct Pool(Data)
{
    private struct Entry
    {
        Data data;
        Entry* next;
    }
    private Entry*  root;
    private Entry* freeList;

    @safe @property bool empty()
    {
        return root == null;
    }

    @safe nothrow void push(Data d)
    {
        if (freeList == null)
        {
            // Allocate new Entry since there is no one
            // available in the freeList
            freeList = new Entry;
        }
        freeList.data = d;
        Entry* oldroot = root;
        root = freeList;
        freeList = freeList.next;
        root.next = oldroot;
    }

    @safe Data pop()
    {
        enforce!Exception(root != null, "pop() called on empty pool");
        auto d = root.data;
        auto n = root.next;
        root.next = freeList;
        freeList = root;
        root = n;
        return d;
    }
}

// Shared function for reading incoming chunks of data and
// sending the to a parent thread
private static size_t _receiveAsyncChunks(ubyte[] data, ref ubyte[] outdata,
                                          Pool!(ubyte[]) freeBuffers,
                                          ref ubyte[] buffer, Tid fromTid,
                                          ref bool aborted)
{
    immutable datalen = data.length;

    // Copy data to fill active buffer
    while (!data.empty)
    {

        // Make sure a buffer is present
        while ( outdata.empty && freeBuffers.empty)
        {
            // Active buffer is invalid and there are no
            // available buffers in the pool. Wait for buffers
            // to return from main thread in order to reuse
            // them.
            receive((immutable(ubyte)[] buf)
                    {
                        buffer = cast(ubyte[])buf;
                        outdata = buffer[];
                    },
                    (bool flag) { aborted = true; }
                    );
            if (aborted) return cast(size_t)0;
        }
        if (outdata.empty)
        {
            buffer = freeBuffers.pop();
            outdata = buffer[];
        }

        // Copy data
        auto copyBytes = outdata.length < data.length ?
            outdata.length : data.length;

        outdata[0..copyBytes] = data[0..copyBytes];
        outdata = outdata[copyBytes..$];
        data = data[copyBytes..$];

        if (outdata.empty)
            fromTid.send(thisTid, curlMessage(cast(immutable(ubyte)[])buffer));
    }

    return datalen;
}

// ditto
private static void _finalizeAsyncChunks(ubyte[] outdata, ref ubyte[] buffer,
                                         Tid fromTid)
{
    if (!outdata.empty)
    {
        // Resize the last buffer
        buffer.length = buffer.length - outdata.length;
        fromTid.send(thisTid, curlMessage(cast(immutable(ubyte)[])buffer));
    }
}


// Shared function for reading incoming lines of data and sending the to a
// parent thread
private static size_t _receiveAsyncLines(Terminator, Unit)
    (const(ubyte)[] data, ref EncodingScheme encodingScheme,
     bool keepTerminator, Terminator terminator,
     ref const(ubyte)[] leftOverBytes, ref bool bufferValid,
     ref Pool!(Unit[]) freeBuffers, ref Unit[] buffer,
     Tid fromTid, ref bool aborted)
{

    immutable datalen = data.length;

    // Terminator is specified and buffers should be resized as determined by
    // the terminator

    // Copy data to active buffer until terminator is found.

    // Decode as many lines as possible
    while (true)
    {

        // Make sure a buffer is present
        while (!bufferValid && freeBuffers.empty)
        {
            // Active buffer is invalid and there are no available buffers in
            // the pool. Wait for buffers to return from main thread in order to
            // reuse them.
            receive((immutable(Unit)[] buf)
                    {
                        buffer = cast(Unit[])buf;
                        buffer.length = 0;
                        buffer.assumeSafeAppend();
                        bufferValid = true;
                    },
                    (bool flag) { aborted = true; }
                    );
            if (aborted) return cast(size_t)0;
        }
        if (!bufferValid)
        {
            buffer = freeBuffers.pop();
            bufferValid = true;
        }

        // Try to read a line from left over bytes from last onReceive plus the
        // newly received bytes.
        try
        {
            if (decodeLineInto(leftOverBytes, data, buffer,
                               encodingScheme, terminator))
            {
                if (keepTerminator)
                {
                    fromTid.send(thisTid,
                                 curlMessage(cast(immutable(Unit)[])buffer));
                }
                else
                {
                    static if (isArray!Terminator)
                        fromTid.send(thisTid,
                                     curlMessage(cast(immutable(Unit)[])
                                             buffer[0..$-terminator.length]));
                    else
                        fromTid.send(thisTid,
                                     curlMessage(cast(immutable(Unit)[])
                                             buffer[0..$-1]));
                }
                bufferValid = false;
            }
            else
            {
                // Could not decode an entire line. Save
                // bytes left in data for next call to
                // onReceive. Can be up to a max of 4 bytes.
                enforce!CurlException(data.length <= 4,
                                        format(
                                        "Too many bytes left not decoded %s"~
                                        " > 4. Maybe the charset specified in"~
                                        " headers does not match "~
                                        "the actual content downloaded?",
                                        data.length));
                leftOverBytes ~= data;
                break;
            }
        }
        catch (CurlException ex)
        {
            prioritySend(fromTid, cast(immutable(CurlException))ex);
            return cast(size_t)0;
        }
    }
    return datalen;
}

// ditto
private static
void _finalizeAsyncLines(Unit)(bool bufferValid, Unit[] buffer, Tid fromTid)
{
    if (bufferValid && buffer.length != 0)
        fromTid.send(thisTid, curlMessage(cast(immutable(Unit)[])buffer[0..$]));
}


// Spawn a thread for handling the reading of incoming data in the
// background while the delegate is executing.  This will optimize
// throughput by allowing simultaneous input (this struct) and
// output (e.g. AsyncHTTPLineOutputRange).
private static void _spawnAsync(Conn, Unit, Terminator = void)()
{
    Tid fromTid = receiveOnly!Tid();

    // Get buffer to read into
    Pool!(Unit[]) freeBuffers;  // Free list of buffer objects

    // Number of bytes filled into active buffer
    Unit[] buffer;
    bool aborted = false;

    EncodingScheme encodingScheme;
    static if ( !is(Terminator == void))
    {
        // Only lines reading will receive a terminator
        auto terminator = receiveOnly!Terminator();
        auto keepTerminator = receiveOnly!bool();

        // max number of bytes to carry over from an onReceive
        // callback. This is 4 because it is the max code units to
        // decode a code point in the supported encodings.
        auto leftOverBytes =  new const(ubyte)[4];
        leftOverBytes.length = 0;
        auto bufferValid = false;
    }
    else
    {
        Unit[] outdata;
    }

    // no move semantic available in std.concurrency ie. must use casting.
    auto connDup = cast(CURL*)receiveOnly!ulong();
    auto client = Conn();
    client.p.curl.handle = connDup;

    // receive a method for both ftp and http but just use it for http
    auto method = receiveOnly!(HTTP.Method)();

    client.onReceive = (ubyte[] data)
    {
        // If no terminator is specified the chunk size is fixed.
        static if ( is(Terminator == void) )
            return _receiveAsyncChunks(data, outdata, freeBuffers, buffer,
                                       fromTid, aborted);
        else
            return _receiveAsyncLines(data, encodingScheme,
                                      keepTerminator, terminator, leftOverBytes,
                                      bufferValid, freeBuffers, buffer,
                                      fromTid, aborted);
    };

    static if ( is(Conn == HTTP) )
    {
        client.method = method;
        // register dummy header handler
        client.onReceiveHeader = (in char[] key, in char[] value)
        {
            if (key == "content-type")
                encodingScheme = EncodingScheme.create(client.p.charset);
        };
    }
    else
    {
        encodingScheme = EncodingScheme.create(client.encoding);
    }

    // Start the request
    CurlCode code;
    try
    {
        code = client.perform(ThrowOnError.no);
    }
    catch (Exception ex)
    {
        prioritySend(fromTid, cast(immutable(Exception)) ex);
        fromTid.send(thisTid, curlMessage(true)); // signal done
        return;
    }

    if (code != CurlError.ok)
    {
        if (aborted && (code == CurlError.aborted_by_callback ||
                        code == CurlError.write_error))
        {
            fromTid.send(thisTid, curlMessage(true)); // signal done
            return;
        }
        prioritySend(fromTid, cast(immutable(CurlException))
                     new CurlException(client.p.curl.errorString(code)));

        fromTid.send(thisTid, curlMessage(true)); // signal done
        return;
    }

    // Send remaining data that is not a full chunk size
    static if ( is(Terminator == void) )
        _finalizeAsyncChunks(outdata, buffer, fromTid);
    else
        _finalizeAsyncLines(bufferValid, buffer, fromTid);

    fromTid.send(thisTid, curlMessage(true)); // signal done
}
