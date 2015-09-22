/**
   This is an interface to the libcurl library.

   Converted to D from curl headers by $(LINK2 http://www.digitalmars.com/d/2.0/htod.html, htod) and
   cleaned up by Jonas Drewsen (jdrewsen)

   Windows x86 note:
   A DMD compatible libcurl static library can be downloaded from the dlang.org
   $(LINK2 http://dlang.org/download.html, download page).
*/

/* **************************************************************************
 *                                  _   _ ____  _
 *  Project                     ___| | | |  _ \| |
 *                             / __| | | | |_) | |
 *                            | (__| |_| |  _ <| |___
 *                             \___|\___/|_| \_\_____|
 */

/**
 * Copyright (C) 1998 - 2010, Daniel Stenberg, &lt;daniel@haxx.se&gt;, et al.
 *
 * This software is licensed as described in the file COPYING, which
 * you should have received as part of this distribution. The terms
 * are also available at $(LINK http://curl.haxx.se/docs/copyright.html).
 *
 * You may opt to use, copy, modify, merge, publish, distribute and/or sell
 * copies of the Software, and permit persons to whom the Software is
 * furnished to do so, under the terms of the COPYING file.
 *
 * This software is distributed on an "AS IS" basis, WITHOUT WARRANTY OF ANY
 * KIND, either express or implied.
 *
 ***************************************************************************/

module etc.c.curl;

import core.stdc.time;
import core.stdc.config;
import std.socket;

// linux
import core.sys.posix.sys.socket;

//
// LICENSE FROM CURL HEADERS
//

/** This is the global package copyright */
enum LIBCURL_COPYRIGHT = "1996 - 2010 Daniel Stenberg, <daniel@haxx.se>.";

/** This is the version number of the libcurl package from which this header
   file origins: */
enum LIBCURL_VERSION = "7.21.4";

/** The numeric version number is also available "in parts" by using these
   constants */
enum LIBCURL_VERSION_MAJOR = 7;
/// ditto
enum LIBCURL_VERSION_MINOR = 21;
/// ditto
enum LIBCURL_VERSION_PATCH = 4;

/** This is the numeric version of the libcurl version number, meant for easier
   parsing and comparions by programs. The LIBCURL_VERSION_NUM define will
   always follow this syntax:

         0xXXYYZZ

   Where XX, YY and ZZ are the main version, release and patch numbers in
   hexadecimal (using 8 bits each). All three numbers are always represented
   using two digits.  1.2 would appear as "0x010200" while version 9.11.7
   appears as "0x090b07".

   This 6-digit (24 bits) hexadecimal number does not show pre-release number,
   and it is always a greater number in a more recent release. It makes
   comparisons with greater than and less than work.
*/

enum LIBCURL_VERSION_NUM = 0x071504;

/**
 * This is the date and time when the full source package was created. The
 * timestamp is not stored in git, as the timestamp is properly set in the
 * tarballs by the maketgz script.
 *
 * The format of the date should follow this template:
 *
 * "Mon Feb 12 11:35:33 UTC 2007"
 */
enum LIBCURL_TIMESTAMP = "Thu Feb 17 12:19:40 UTC 2011";

/** Data type definition of curl_off_t. */
/// jdrewsen - Always 64bit signed and that is what long is in D.
/// Comment below is from curlbuild.h:
/**
 * NOTE 2:
 *
 * For any given platform/compiler curl_off_t must be typedef'ed to a
 * 64-bit wide signed integral data type. The width of this data type
 * must remain constant and independent of any possible large file
 * support settings.
 *
 * As an exception to the above, curl_off_t shall be typedef'ed to a
 * 32-bit wide signed integral data type if there is no 64-bit type.
 */
alias long curl_off_t;

///
alias void CURL;

/// jdrewsen - Get socket alias from std.socket
alias socket_t curl_socket_t;

/// jdrewsen - Would like to get socket error constant from std.socket by it is private atm.
version(Windows) {
  private import core.sys.windows.windows, core.sys.windows.winsock2;
  enum CURL_SOCKET_BAD = SOCKET_ERROR;
}
version(Posix) enum CURL_SOCKET_BAD = -1;

///
extern (C) struct curl_httppost
{
    curl_httppost *next;        /** next entry in the list */
    char *name;                 /** pointer to allocated name */
    c_long namelength;          /** length of name length */
    char *contents;             /** pointer to allocated data contents */
    c_long contentslength;      /** length of contents field */
    char *buffer;               /** pointer to allocated buffer contents */
    c_long bufferlength;        /** length of buffer field */
    char *contenttype;          /** Content-Type */
    curl_slist *contentheader;  /** list of extra headers for this form */
    curl_httppost *more;        /** if one field name has more than one
                                    file, this link should link to following
                                    files */
    c_long flags;               /** as defined below */
    char *showfilename;         /** The file name to show. If not set, the
                                    actual file name will be used (if this
                                    is a file part) */
    void *userp;                /** custom pointer used for
                                    HTTPPOST_CALLBACK posts */
}

enum HTTPPOST_FILENAME    = 1;  /** specified content is a file name */
enum HTTPPOST_READFILE    = 2;  /** specified content is a file name */
enum HTTPPOST_PTRNAME     = 4;  /** name is only stored pointer
                                    do not free in formfree */
enum HTTPPOST_PTRCONTENTS = 8;  /** contents is only stored pointer
                                    do not free in formfree */
enum HTTPPOST_BUFFER      = 16; /** upload file from buffer */
enum HTTPPOST_PTRBUFFER   = 32; /** upload file from pointer contents */
enum HTTPPOST_CALLBACK    = 64; /** upload file contents by using the
                                    regular read callback to get the data
                                    and pass the given pointer as custom
                                    pointer */

///
alias int function(void *clientp, double dltotal, double dlnow, double ultotal, double ulnow) curl_progress_callback;

/** Tests have proven that 20K is a very bad buffer size for uploads on
   Windows, while 16K for some odd reason performed a lot better.
   We do the ifndef check to allow this value to easier be changed at build
   time for those who feel adventurous. The practical minimum is about
   400 bytes since libcurl uses a buffer of this size as a scratch area
   (unrelated to network send operations). */
enum CURL_MAX_WRITE_SIZE = 16384;

/** The only reason to have a max limit for this is to avoid the risk of a bad
   server feeding libcurl with a never-ending header that will cause reallocs
   infinitely */
enum CURL_MAX_HTTP_HEADER = (100*1024);


/** This is a magic return code for the write callback that, when returned,
   will signal libcurl to pause receiving on the current transfer. */
enum CURL_WRITEFUNC_PAUSE = 0x10000001;

///
alias size_t  function(char *buffer, size_t size, size_t nitems, void *outstream)curl_write_callback;

/** enumeration of file types */
enum CurlFileType {
    file,       ///
    directory,  ///
    symlink,    ///
    device_block, ///
    device_char, ///
    namedpipe,  ///
    socket,     ///
    door,       ///
    unknown /** is possible only on Sun Solaris now */
}

///
alias int curlfiletype;

///
enum CurlFInfoFlagKnown {
  filename    = 1,      ///
  filetype    = 2,      ///
  time        = 4,      ///
  perm        = 8,      ///
  uid         = 16,     ///
  gid         = 32,     ///
  size        = 64,     ///
  hlinkcount  = 128     ///
}

/** Content of this structure depends on information which is known and is
   achievable (e.g. by FTP LIST parsing). Please see the url_easy_setopt(3) man
   page for callbacks returning this structure -- some fields are mandatory,
   some others are optional. The FLAG field has special meaning. */


/** If some of these fields is not NULL, it is a pointer to b_data. */
extern (C) struct _N2
{
    char *time;   ///
    char *perm;   ///
    char *user;   ///
    char *group;  ///
    char *target; /** pointer to the target filename of a symlink */
}

/** Content of this structure depends on information which is known and is
   achievable (e.g. by FTP LIST parsing). Please see the url_easy_setopt(3) man
   page for callbacks returning this structure -- some fields are mandatory,
   some others are optional. The FLAG field has special meaning. */
extern (C) struct curl_fileinfo
{
    char *filename;             ///
    curlfiletype filetype;      ///
    time_t time;                ///
    uint perm;                  ///
    int uid;                    ///
    int gid;                    ///
    curl_off_t size;            ///
    c_long hardlinks;           ///
    _N2 strings;                ///
    uint flags;                 ///
    char *b_data;               ///
    size_t b_size;              ///
    size_t b_used;              ///
}

/** return codes for CURLOPT_CHUNK_BGN_FUNCTION */
enum CurlChunkBgnFunc {
  ok = 0,   ///
  fail = 1, /** tell the lib to end the task */
  skip = 2 /** skip this chunk over */
}

/** if splitting of data transfer is enabled, this callback is called before
   download of an individual chunk started. Note that parameter "remains" works
   only for FTP wildcard downloading (for now), otherwise is not used */
alias c_long function(void *transfer_info, void *ptr, int remains)curl_chunk_bgn_callback;

/** return codes for CURLOPT_CHUNK_END_FUNCTION */
enum CurlChunkEndFunc {
  ok = 0,       ///
  fail = 1,     ///
}
/** If splitting of data transfer is enabled this callback is called after
   download of an individual chunk finished.
   Note! After this callback was set then it have to be called FOR ALL chunks.
   Even if downloading of this chunk was skipped in CHUNK_BGN_FUNC.
   This is the reason why we don't need "transfer_info" parameter in this
   callback and we are not interested in "remains" parameter too. */
alias c_long function(void *ptr)curl_chunk_end_callback;

/** return codes for FNMATCHFUNCTION */
enum CurlFnMAtchFunc {
  match = 0,    ///
  nomatch = 1,  ///
  fail = 2      ///
}

/** callback type for wildcard downloading pattern matching. If the
   string matches the pattern, return CURL_FNMATCHFUNC_MATCH value, etc. */
alias int  function(void *ptr, in char *pattern, in char *string)curl_fnmatch_callback;

/// seek whence...
enum CurlSeekPos {
  set,          ///
  current,      ///
  end           ///
}

/** These are the return codes for the seek callbacks */
enum CurlSeek {
  ok,       ///
  fail,     /** fail the entire transfer */
  cantseek  /** tell libcurl seeking can't be done, so
               libcurl might try other means instead */
}

///
alias int  function(void *instream, curl_off_t offset, int origin)curl_seek_callback;

///
enum CurlReadFunc {
  /** This is a return code for the read callback that, when returned, will
     signal libcurl to immediately abort the current transfer. */
  abort = 0x10000000,

  /** This is a return code for the read callback that, when returned,
     will const signal libcurl to pause sending data on the current
     transfer. */
  pause = 0x10000001
}

///
alias size_t  function(char *buffer, size_t size, size_t nitems, void *instream)curl_read_callback;

///
enum CurlSockType {
    ipcxn, /** socket created for a specific IP connection */
    last   /** never use */
}
///
alias int curlsocktype;

///
alias int  function(void *clientp, curl_socket_t curlfd, curlsocktype purpose)curl_sockopt_callback;

/** addrlen was a socklen_t type before 7.18.0 but it turned really
   ugly and painful on the systems that lack this type */
extern (C) struct curl_sockaddr
{
    int family;   ///
    int socktype; ///
    int protocol; ///
    uint addrlen; /** addrlen was a socklen_t type before 7.18.0 but it
                     turned really ugly and painful on the systems that
                     lack this type */
    sockaddr addr; ///
}

///
alias curl_socket_t  function(void *clientp, curlsocktype purpose, curl_sockaddr *address)curl_opensocket_callback;

///
enum CurlIoError
{
    ok,            /** I/O operation successful */
    unknowncmd,    /** command was unknown to callback */
    failrestart,   /** failed to restart the read */
    last           /** never use */
}
///
alias int curlioerr;

///
enum CurlIoCmd {
    nop,         /** command was unknown to callback */
    restartread, /** failed to restart the read */
    last,        /** never use */
}
///
alias int curliocmd;

///
alias curlioerr  function(CURL *handle, int cmd, void *clientp)curl_ioctl_callback;

/**
 * The following typedef's are signatures of malloc, free, realloc, strdup and
 * calloc respectively.  Function pointers of these types can be passed to the
 * curl_global_init_mem() function to set user defined memory management
 * callback routines.
 */
alias void * function(size_t size)curl_malloc_callback;
/// ditto
alias void  function(void *ptr)curl_free_callback;
/// ditto
alias void * function(void *ptr, size_t size)curl_realloc_callback;
/// ditto
alias char * function(in char *str)curl_strdup_callback;
/// ditto
alias void * function(size_t nmemb, size_t size)curl_calloc_callback;

/** the kind of data that is passed to information_callback*/
enum CurlCallbackInfo {
    text,       ///
    header_in,  ///
    header_out, ///
    data_in,    ///
    data_out,   ///
    ssl_data_in, ///
    ssl_data_out, ///
    end         ///
}
///
alias int curl_infotype;

///
alias int  function(CURL *handle,        /** the handle/transfer this concerns */
                    curl_infotype type,  /** what kind of data */
                    char *data,          /** points to the data */
                    size_t size,         /** size of the data pointed to */
                    void *userptr        /** whatever the user please */
                    )curl_debug_callback;

/** All possible error codes from all sorts of curl functions. Future versions
   may return other values, stay prepared.

   Always add new return codes last. Never *EVER* remove any. The return
   codes must remain the same!
 */
enum CurlError
{
    ok,                          ///
    unsupported_protocol,        /** 1 */
    failed_init,                 /** 2 */
    url_malformat,               /** 3 */
    not_built_in,                /** 4 - [was obsoleted in August 2007 for
                                    7.17.0, reused in April 2011 for 7.21.5] */
    couldnt_resolve_proxy,       /** 5 */
    couldnt_resolve_host,        /** 6 */
    couldnt_connect,             /** 7 */
    ftp_weird_server_reply,      /** 8 */
    remote_access_denied,        /** 9 a service was denied by the server
                                    due to lack of access - when login fails
                                    this is not returned. */
    obsolete10,                  /** 10 - NOT USED */
    ftp_weird_pass_reply,        /** 11 */
    obsolete12,                  /** 12 - NOT USED */
    ftp_weird_pasv_reply,        /** 13 */
    ftp_weird_227_format,        /** 14 */
    ftp_cant_get_host,           /** 15 */
    obsolete16,                  /** 16 - NOT USED */
    ftp_couldnt_set_type,        /** 17 */
    partial_file,                /** 18 */
    ftp_couldnt_retr_file,       /** 19 */
    obsolete20,                  /** 20 - NOT USED */
    quote_error,                 /** 21 - quote command failure */
    http_returned_error,         /** 22 */
    write_error,                 /** 23 */
    obsolete24,                  /** 24 - NOT USED */
    upload_failed,               /** 25 - failed upload "command" */
    read_error,                  /** 26 - couldn't open/read from file */
    out_of_memory,               /** 27 */
    /** Note: CURLE_OUT_OF_MEMORY may sometimes indicate a conversion error
             instead of a memory allocation error if CURL_DOES_CONVERSIONS
             is defined
    */
    operation_timedout,          /** 28 - the timeout time was reached */
    obsolete29,                  /** 29 - NOT USED */
    ftp_port_failed,             /** 30 - FTP PORT operation failed */
    ftp_couldnt_use_rest,        /** 31 - the REST command failed */
    obsolete32,                  /** 32 - NOT USED */
    range_error,                 /** 33 - RANGE "command" didn't work */
    http_post_error,             /** 34 */
    ssl_connect_error,           /** 35 - wrong when connecting with SSL */
    bad_download_resume,         /** 36 - couldn't resume download */
    file_couldnt_read_file,      /** 37 */
    ldap_cannot_bind,            /** 38 */
    ldap_search_failed,          /** 39 */
    obsolete40,                  /** 40 - NOT USED */
    function_not_found,          /** 41 */
    aborted_by_callback,         /** 42 */
    bad_function_argument,       /** 43 */
    obsolete44,                  /** 44 - NOT USED */
    interface_failed,            /** 45 - CURLOPT_INTERFACE failed */
    obsolete46,                  /** 46 - NOT USED */
    too_many_redirects,          /** 47 - catch endless re-direct loops */
    unknown_option,              /** 48 - User specified an unknown option */
    telnet_option_syntax,        /** 49 - Malformed telnet option */
    obsolete50,                  /** 50 - NOT USED */
    peer_failed_verification,    /** 51 - peer's certificate or fingerprint
                                         wasn't verified fine */
    got_nothing,                 /** 52 - when this is a specific error */
    ssl_engine_notfound,         /** 53 - SSL crypto engine not found */
    ssl_engine_setfailed,        /** 54 - can not set SSL crypto engine as default */
    send_error,                  /** 55 - failed sending network data */
    recv_error,                  /** 56 - failure in receiving network data */
    obsolete57,                  /** 57 - NOT IN USE */
    ssl_certproblem,             /** 58 - problem with the local certificate */
    ssl_cipher,                  /** 59 - couldn't use specified cipher */
    ssl_cacert,                  /** 60 - problem with the CA cert (path?) */
    bad_content_encoding,        /** 61 - Unrecognized transfer encoding */
    ldap_invalid_url,            /** 62 - Invalid LDAP URL */
    filesize_exceeded,           /** 63 - Maximum file size exceeded */
    use_ssl_failed,              /** 64 - Requested FTP SSL level failed */
    send_fail_rewind,            /** 65 - Sending the data requires a rewind that failed */
    ssl_engine_initfailed,       /** 66 - failed to initialise ENGINE */
    login_denied,                /** 67 - user, password or similar was not accepted and we failed to login */
    tftp_notfound,               /** 68 - file not found on server */
    tftp_perm,                   /** 69 - permission problem on server */
    remote_disk_full,            /** 70 - out of disk space on server */
    tftp_illegal,                /** 71 - Illegal TFTP operation */
    tftp_unknownid,              /** 72 - Unknown transfer ID */
    remote_file_exists,          /** 73 - File already exists */
    tftp_nosuchuser,             /** 74 - No such user */
    conv_failed,                 /** 75 - conversion failed */
    conv_reqd,                   /** 76 - caller must register conversion
                                    callbacks using curl_easy_setopt options
                                    CURLOPT_CONV_FROM_NETWORK_FUNCTION,
                                    CURLOPT_CONV_TO_NETWORK_FUNCTION, and
                                    CURLOPT_CONV_FROM_UTF8_FUNCTION */
    ssl_cacert_badfile,          /** 77 - could not load CACERT file, missing  or wrong format */
    remote_file_not_found,       /** 78 - remote file not found */
    ssh,                         /** 79 - error from the SSH layer, somewhat
                                    generic so the error message will be of
                                    interest when this has happened */
    ssl_shutdown_failed,         /** 80 - Failed to shut down the SSL connection */
    again,                       /** 81 - socket is not ready for send/recv,
                                    wait till it's ready and try again (Added
                                    in 7.18.2) */
    ssl_crl_badfile,             /** 82 - could not load CRL file, missing or wrong format (Added in 7.19.0) */
    ssl_issuer_error,            /** 83 - Issuer check failed.  (Added in 7.19.0) */
    ftp_pret_failed,             /** 84 - a PRET command failed */
    rtsp_cseq_error,             /** 85 - mismatch of RTSP CSeq numbers */
    rtsp_session_error,          /** 86 - mismatch of RTSP Session Identifiers */
    ftp_bad_file_list,           /** 87 - unable to parse FTP file list */
    chunk_failed,                /** 88 - chunk callback reported error */
    curl_last                    /** never use! */
}
///
alias int CURLcode;

/** This prototype applies to all conversion callbacks */
alias CURLcode  function(char *buffer, size_t length)curl_conv_callback;

/** actually an OpenSSL SSL_CTX */
alias CURLcode  function(CURL *curl,    /** easy handle */
                         void *ssl_ctx, /** actually an
                                           OpenSSL SSL_CTX */
                         void *userptr
                         )curl_ssl_ctx_callback;

///
enum CurlProxy {
    http,         /** added in 7.10, new in 7.19.4 default is to use CONNECT HTTP/1.1 */
    http_1_0,     /** added in 7.19.4, force to use CONNECT HTTP/1.0  */
    socks4 = 4,   /** support added in 7.15.2, enum existed already in 7.10 */
    socks5 = 5,   /** added in 7.10 */
    socks4a = 6,  /** added in 7.18.0 */
    socks5_hostname =7   /** Use the SOCKS5 protocol but pass along the
                         host name rather than the IP address. added
                         in 7.18.0 */
}
///
alias int curl_proxytype;

///
enum CurlAuth : long {
  none =         0,
  basic =        1,  /** Basic (default) */
  digest =       2,  /** Digest */
  gssnegotiate = 4,  /** GSS-Negotiate */
  ntlm =         8,  /** NTLM */
  digest_ie =    16, /** Digest with IE flavour */
  only =         2147483648, /** used together with a single other
                                type to force no auth or just that
                                single type */
  any = -17,     /* (~CURLAUTH_DIGEST_IE) */  /** all fine types set */
  anysafe = -18  /* (~(CURLAUTH_BASIC|CURLAUTH_DIGEST_IE)) */ ///
}

///
enum CurlSshAuth {
  any       = -1,     /** all types supported by the server */
  none      = 0,      /** none allowed, silly but complete */
  publickey = 1, /** public/private key files */
  password  = 2, /** password */
  host      = 4, /** host key files */
  keyboard  = 8, /** keyboard interactive */
  default_  = -1 // CURLSSH_AUTH_ANY;
}
///
enum CURL_ERROR_SIZE = 256;
/** points to a zero-terminated string encoded with base64
   if len is zero, otherwise to the "raw" data */
enum CurlKHType
{
    unknown,    ///
    rsa1,       ///
    rsa,        ///
    dss         ///
}
///
extern (C) struct curl_khkey
{
    const(char) *key; /** points to a zero-terminated string encoded with base64
                         if len is zero, otherwise to the "raw" data */
    size_t len; ///
    CurlKHType keytype; ///
}

/** this is the set of return values expected from the curl_sshkeycallback
   callback */
enum CurlKHStat {
    fine_add_to_file, ///
    fine,       ///
    reject,  /** reject the connection, return an error */
    defer,   /** do not accept it, but we can't answer right now so
                this causes a CURLE_DEFER error but otherwise the
                connection will be left intact etc */
    last     /** not for use, only a marker for last-in-list */
}

/** this is the set of status codes pass in to the callback */
enum CurlKHMatch {
    ok,       /** match */
    mismatch, /** host found, key mismatch! */
    missing,  /** no matching host/key found */
    last      /** not for use, only a marker for last-in-list */
}

///
alias int  function(CURL *easy,            /** easy handle */
                    curl_khkey *knownkey,  /** known */
                    curl_khkey *foundkey,  /** found */
                    CurlKHMatch m,         /** libcurl's view on the keys */
                    void *clientp          /** custom pointer passed from app */
                    )curl_sshkeycallback;

/** parameter for the CURLOPT_USE_SSL option */
enum CurlUseSSL {
    none,     /** do not attempt to use SSL */
    tryssl,   /** try using SSL, proceed anyway otherwise */
    control,  /** SSL for the control connection or fail */
    all,      /** SSL for all communication or fail */
    last      /** not an option, never use */
}
///
alias int curl_usessl;

/** parameter for the CURLOPT_FTP_SSL_CCC option */
enum CurlFtpSSL {
    ccc_none,     /** do not send CCC */
    ccc_passive,  /** Let the server initiate the shutdown */
    ccc_active,   /** Initiate the shutdown */
    ccc_last      /** not an option, never use */
}
///
alias int curl_ftpccc;

/** parameter for the CURLOPT_FTPSSLAUTH option */
enum CurlFtpAuth {
    defaultauth, /** let libcurl decide */
    ssl,         /** use "AUTH SSL" */
    tls,         /** use "AUTH TLS" */
    last         /** not an option, never use */
}
///
alias int curl_ftpauth;

/** parameter for the CURLOPT_FTP_CREATE_MISSING_DIRS option */
enum CurlFtp {
    create_dir_none,   /** do NOT create missing dirs! */
    create_dir,        /** (FTP/SFTP) if CWD fails, try MKD and then CWD again if MKD
                          succeeded, for SFTP this does similar magic */
    create_dir_retry,  /** (FTP only) if CWD fails, try MKD and then CWD again even if MKD
                          failed! */
    create_dir_last    /** not an option, never use */
}
///
alias int curl_ftpcreatedir;

/** parameter for the CURLOPT_FTP_FILEMETHOD option */
enum CurlFtpMethod {
    defaultmethod,    /** let libcurl pick */
    multicwd,         /** single CWD operation for each path part */
    nocwd,            /** no CWD at all */
    singlecwd,        /** one CWD to full dir, then work on file */
    last              /** not an option, never use */
}
///
alias int curl_ftpmethod;

/** CURLPROTO_ defines are for the CURLOPT_*PROTOCOLS options */
enum CurlProto {
  http   = 1,   ///
  https  = 2,   ///
  ftp    = 4,   ///
  ftps   = 8,   ///
  scp    = 16,  ///
  sftp   = 32,  ///
  telnet = 64,  ///
  ldap   = 128, ///
  ldaps  = 256, ///
  dict   = 512, ///
  file   = 1024,        ///
  tftp   = 2048,        ///
  imap   = 4096,        ///
  imaps  = 8192,        ///
  pop3   = 16384,       ///
  pop3s  = 32768,       ///
  smtp   = 65536,       ///
  smtps  = 131072,      ///
  rtsp   = 262144,      ///
  rtmp   = 524288,      ///
  rtmpt  = 1048576,     ///
  rtmpe  = 2097152,     ///
  rtmpte = 4194304,     ///
  rtmps  = 8388608,     ///
  rtmpts = 16777216,    ///
  gopher = 33554432,    ///
  all    = -1 /** enable everything */
}

/** long may be 32 or 64 bits, but we should never depend on anything else
   but 32 */
enum CURLOPTTYPE_LONG = 0;
/// ditto
enum CURLOPTTYPE_OBJECTPOINT = 10000;
/// ditto
enum CURLOPTTYPE_FUNCTIONPOINT = 20000;

/// ditto
enum CURLOPTTYPE_OFF_T = 30000;
/** name is uppercase CURLOPT_<name>,
   type is one of the defined CURLOPTTYPE_<type>
   number is unique identifier */

/** The macro "##" is ISO C, we assume pre-ISO C doesn't support it. */
alias CURLOPTTYPE_LONG LONG;
/// ditto
alias CURLOPTTYPE_OBJECTPOINT OBJECTPOINT;
/// ditto
alias CURLOPTTYPE_FUNCTIONPOINT FUNCTIONPOINT;

/// ditto
alias CURLOPTTYPE_OFF_T OFF_T;

///
enum CurlOption {
  /** This is the FILE * or void * the regular output should be written to. */
  file = 10001,
  /** The full URL to get/put */
  url,
  /** Port number to connect to, if other than default. */
  port = 3,
  /** Name of proxy to use. */
  proxy = 10004,
  /** "name:password" to use when fetching. */
  userpwd,
  /** "name:password" to use with proxy. */
  proxyuserpwd,
  /** Range to get, specified as an ASCII string. */
  range,
  /** not used */

  /** Specified file stream to upload from (use as input): */
  infile = 10009,
  /** Buffer to receive error messages in, must be at least CURL_ERROR_SIZE
   * bytes big. If this is not used, error messages go to stderr instead: */
  errorbuffer,
  /** Function that will be called to store the output (instead of fwrite). The
   * parameters will use fwrite() syntax, make sure to follow them. */
  writefunction = 20011,
  /** Function that will be called to read the input (instead of fread). The
   * parameters will use fread() syntax, make sure to follow them. */
  readfunction,
  /** Time-out the read operation after this amount of seconds */
  timeout = 13,
  /** If the CURLOPT_INFILE is used, this can be used to inform libcurl about
   * how large the file being sent really is. That allows better error
   * checking and better verifies that the upload was successful. -1 means
   * unknown size.
   *
   * For large file support, there is also a _LARGE version of the key
   * which takes an off_t type, allowing platforms with larger off_t
   * sizes to handle larger files.  See below for INFILESIZE_LARGE.
   */
  infilesize,
  /** POST static input fields. */
  postfields = 10015,
  /** Set the referrer page (needed by some CGIs) */
  referer,
  /** Set the FTP PORT string (interface name, named or numerical IP address)
     Use i.e '-' to use default address. */
  ftpport,
  /** Set the User-Agent string (examined by some CGIs) */
  useragent,
  /** If the download receives less than "low speed limit" bytes/second
   * during "low speed time" seconds, the operations is aborted.
   * You could i.e if you have a pretty high speed connection, abort if
   * it is less than 2000 bytes/sec during 20 seconds.
   */

  /** Set the "low speed limit" */
  low_speed_limit = 19,
  /** Set the "low speed time" */
  low_speed_time,
  /** Set the continuation offset.
   *
   * Note there is also a _LARGE version of this key which uses
   * off_t types, allowing for large file offsets on platforms which
   * use larger-than-32-bit off_t's.  Look below for RESUME_FROM_LARGE.
   */
  resume_from,
  /** Set cookie in request: */
  cookie = 10022,
  /** This points to a linked list of headers, struct curl_slist kind */
  httpheader,
  /** This points to a linked list of post entries, struct curl_httppost */
  httppost,
  /** name of the file keeping your private SSL-certificate */
  sslcert,
  /** password for the SSL or SSH private key */
  keypasswd,
  /** send TYPE parameter? */
  crlf = 27,
  /** send linked-list of QUOTE commands */
  quote = 10028,
  /** send FILE * or void * to store headers to, if you use a callback it
     is simply passed to the callback unmodified */
  writeheader,
  /** point to a file to read the initial cookies from, also enables
     "cookie awareness" */
  cookiefile = 10031,
  /** What version to specifically try to use.
     See CURL_SSLVERSION defines below. */
  sslversion = 32,
  /** What kind of HTTP time condition to use, see defines */
  timecondition,
  /** Time to use with the above condition. Specified in number of seconds
     since 1 Jan 1970 */
  timevalue,
  /** 35 = OBSOLETE */

  /** Custom request, for customizing the get command like
     HTTP: DELETE, TRACE and others
     FTP: to use a different list command
     */
  customrequest = 10036,
  /** HTTP request, for odd commands like DELETE, TRACE and others */
  stderr,
  /** 38 is not used */

  /** send linked-list of post-transfer QUOTE commands */
  postquote = 10039,
  /** Pass a pointer to string of the output using full variable-replacement
     as described elsewhere. */
  writeinfo,
  verbose = 41,       /** talk a lot */
  header,             /** throw the header out too */
  noprogress,         /** shut off the progress meter */
  nobody,             /** use HEAD to get http document */
  failonerror,        /** no output on http error codes >= 300 */
  upload,             /** this is an upload */
  post,               /** HTTP POST method */
  dirlistonly,        /** return bare names when listing directories */
  append = 50,        /** Append instead of overwrite on upload! */
  /** Specify whether to read the user+password from the .netrc or the URL.
   * This must be one of the CURL_NETRC_* enums below. */
  netrc,
  followlocation, /** use Location: Luke! */
  transfertext,  /** transfer data in text/ASCII format */
  put,           /** HTTP PUT */
  /** 55 = OBSOLETE */

  /** Function that will be called instead of the internal progress display
   * function. This function should be defined as the curl_progress_callback
   * prototype defines. */
  progressfunction = 20056,
  /** Data passed to the progress callback */
  progressdata = 10057,
  /** We want the referrer field set automatically when following locations */
  autoreferer = 58,
  /** Port of the proxy, can be set in the proxy string as well with:
     "[host]:[port]" */
  proxyport,
  /** size of the POST input data, if strlen() is not good to use */
  postfieldsize,
  /** tunnel non-http operations through a HTTP proxy */
  httpproxytunnel,
  /** Set the interface string to use as outgoing network interface */
  intrface = 10062,
  /** Set the krb4/5 security level, this also enables krb4/5 awareness.  This
   * is a string, 'clear', 'safe', 'confidential' or 'private'.  If the string
   * is set but doesn't match one of these, 'private' will be used.  */
  krblevel,
  /** Set if we should verify the peer in ssl handshake, set 1 to verify. */
  ssl_verifypeer = 64,
  /** The CApath or CAfile used to validate the peer certificate
     this option is used only if SSL_VERIFYPEER is true */
  cainfo = 10065,
  /** 66 = OBSOLETE */
  /** 67 = OBSOLETE */

  /** Maximum number of http redirects to follow */
  maxredirs = 68,
  /** Pass a long set to 1 to get the date of the requested document (if
     possible)! Pass a zero to shut it off. */
  filetime,
  /** This points to a linked list of telnet options */
  telnetoptions = 10070,
  /** Max amount of cached alive connections */
  maxconnects = 71,
  /** What policy to use when closing connections when the cache is filled
     up */
  closepolicy,
  /** 73 = OBSOLETE */

  /** Set to explicitly use a new connection for the upcoming transfer.
     Do not use this unless you're absolutely sure of this, as it makes the
     operation slower and is less friendly for the network. */
  fresh_connect = 74,
  /** Set to explicitly forbid the upcoming transfer's connection to be re-used
     when done. Do not use this unless you're absolutely sure of this, as it
     makes the operation slower and is less friendly for the network. */
  forbid_reuse,
  /** Set to a file name that contains random data for libcurl to use to
     seed the random engine when doing SSL connects. */
  random_file = 10076,
  /** Set to the Entropy Gathering Daemon socket pathname */
  egdsocket,
  /** Time-out connect operations after this amount of seconds, if connects
     are OK within this time, then fine... This only aborts the connect
     phase. [Only works on unix-style/SIGALRM operating systems] */
  connecttimeout = 78,
  /** Function that will be called to store headers (instead of fwrite). The
   * parameters will use fwrite() syntax, make sure to follow them. */
  headerfunction = 20079,
  /** Set this to force the HTTP request to get back to GET. Only really usable
     if POST, PUT or a custom request have been used first.
   */
  httpget = 80,
  /** Set if we should verify the Common name from the peer certificate in ssl
   * handshake, set 1 to check existence, 2 to ensure that it matches the
   * provided hostname. */
  ssl_verifyhost,
  /** Specify which file name to write all known cookies in after completed
     operation. Set file name to "-" (dash) to make it go to stdout. */
  cookiejar = 10082,
  /** Specify which SSL ciphers to use */
  ssl_cipher_list,
  /** Specify which HTTP version to use! This must be set to one of the
     CURL_HTTP_VERSION* enums set below. */
  http_version = 84,
  /** Specifically switch on or off the FTP engine's use of the EPSV command. By
     default, that one will always be attempted before the more traditional
     PASV command. */
  ftp_use_epsv,
  /** type of the file keeping your SSL-certificate ("DER", "PEM", "ENG") */
  sslcerttype = 10086,
  /** name of the file keeping your private SSL-key */
  sslkey,
  /** type of the file keeping your private SSL-key ("DER", "PEM", "ENG") */
  sslkeytype,
  /** crypto engine for the SSL-sub system */
  sslengine,
  /** set the crypto engine for the SSL-sub system as default
     the param has no meaning...
   */
  sslengine_default = 90,
  /** Non-zero value means to use the global dns cache */
  dns_use_global_cache,
  /** DNS cache timeout */
  dns_cache_timeout,
  /** send linked-list of pre-transfer QUOTE commands */
  prequote = 10093,
  /** set the debug function */
  debugfunction = 20094,
  /** set the data for the debug function */
  debugdata = 10095,
  /** mark this as start of a cookie session */
  cookiesession = 96,
  /** The CApath directory used to validate the peer certificate
     this option is used only if SSL_VERIFYPEER is true */
  capath = 10097,
  /** Instruct libcurl to use a smaller receive buffer */
  buffersize = 98,
  /** Instruct libcurl to not use any signal/alarm handlers, even when using
     timeouts. This option is useful for multi-threaded applications.
     See libcurl-the-guide for more background information. */
  nosignal,
  /** Provide a CURLShare for mutexing non-ts data */
  share = 10100,
  /** indicates type of proxy. accepted values are CURLPROXY_HTTP (default),
     CURLPROXY_SOCKS4, CURLPROXY_SOCKS4A and CURLPROXY_SOCKS5. */
  proxytype = 101,
  /** Set the Accept-Encoding string. Use this to tell a server you would like
     the response to be compressed. */
  encoding = 10102,
  /** Set pointer to private data */
  private_opt,
  /** Set aliases for HTTP 200 in the HTTP Response header */
  http200aliases,
  /** Continue to send authentication (user+password) when following locations,
     even when hostname changed. This can potentially send off the name
     and password to whatever host the server decides. */
  unrestricted_auth = 105,
  /** Specifically switch on or off the FTP engine's use of the EPRT command ( it
     also disables the LPRT attempt). By default, those ones will always be
     attempted before the good old traditional PORT command. */
  ftp_use_eprt,
  /** Set this to a bitmask value to enable the particular authentications
     methods you like. Use this in combination with CURLOPT_USERPWD.
     Note that setting multiple bits may cause extra network round-trips. */
  httpauth,
  /** Set the ssl context callback function, currently only for OpenSSL ssl_ctx
     in second argument. The function must be matching the
     curl_ssl_ctx_callback proto. */
  ssl_ctx_function = 20108,
  /** Set the userdata for the ssl context callback function's third
     argument */
  ssl_ctx_data = 10109,
  /** FTP Option that causes missing dirs to be created on the remote server.
     In 7.19.4 we introduced the convenience enums for this option using the
     CURLFTP_CREATE_DIR prefix.
  */
  ftp_create_missing_dirs = 110,
  /** Set this to a bitmask value to enable the particular authentications
     methods you like. Use this in combination with CURLOPT_PROXYUSERPWD.
     Note that setting multiple bits may cause extra network round-trips. */
  proxyauth,
  /** FTP option that changes the timeout, in seconds, associated with
     getting a response.  This is different from transfer timeout time and
     essentially places a demand on the FTP server to acknowledge commands
     in a timely manner. */
  ftp_response_timeout,
  /** Set this option to one of the CURL_IPRESOLVE_* defines (see below) to
     tell libcurl to resolve names to those IP versions only. This only has
     affect on systems with support for more than one, i.e IPv4 _and_ IPv6. */
  ipresolve,
  /** Set this option to limit the size of a file that will be downloaded from
     an HTTP or FTP server.

     Note there is also _LARGE version which adds large file support for
     platforms which have larger off_t sizes.  See MAXFILESIZE_LARGE below. */
  maxfilesize,
  /** See the comment for INFILESIZE above, but in short, specifies
   * the size of the file being uploaded.  -1 means unknown.
   */
  infilesize_large = 30115,
  /** Sets the continuation offset.  There is also a LONG version of this;
   * look above for RESUME_FROM.
   */
  resume_from_large,
  /** Sets the maximum size of data that will be downloaded from
   * an HTTP or FTP server.  See MAXFILESIZE above for the LONG version.
   */
  maxfilesize_large,
  /** Set this option to the file name of your .netrc file you want libcurl
     to parse (using the CURLOPT_NETRC option). If not set, libcurl will do
     a poor attempt to find the user's home directory and check for a .netrc
     file in there. */
  netrc_file = 10118,
  /** Enable SSL/TLS for FTP, pick one of:
     CURLFTPSSL_TRY     - try using SSL, proceed anyway otherwise
     CURLFTPSSL_CONTROL - SSL for the control connection or fail
     CURLFTPSSL_ALL     - SSL for all communication or fail
  */
  use_ssl = 119,
  /** The _LARGE version of the standard POSTFIELDSIZE option */
  postfieldsize_large = 30120,
  /** Enable/disable the TCP Nagle algorithm */
  tcp_nodelay = 121,
  /** 122 OBSOLETE, used in 7.12.3. Gone in 7.13.0 */
  /** 123 OBSOLETE. Gone in 7.16.0 */
  /** 124 OBSOLETE, used in 7.12.3. Gone in 7.13.0 */
  /** 125 OBSOLETE, used in 7.12.3. Gone in 7.13.0 */
  /** 126 OBSOLETE, used in 7.12.3. Gone in 7.13.0 */
  /** 127 OBSOLETE. Gone in 7.16.0 */
  /** 128 OBSOLETE. Gone in 7.16.0 */

  /** When FTP over SSL/TLS is selected (with CURLOPT_USE_SSL), this option
     can be used to change libcurl's default action which is to first try
     "AUTH SSL" and then "AUTH TLS" in this order, and proceed when a OK
     response has been received.

     Available parameters are:
     CURLFTPAUTH_DEFAULT - let libcurl decide
     CURLFTPAUTH_SSL     - try "AUTH SSL" first, then TLS
     CURLFTPAUTH_TLS     - try "AUTH TLS" first, then SSL
  */
  ftpsslauth = 129,
  ioctlfunction = 20130,        ///
  ioctldata = 10131,            ///
  /** 132 OBSOLETE. Gone in 7.16.0 */
  /** 133 OBSOLETE. Gone in 7.16.0 */

  /** zero terminated string for pass on to the FTP server when asked for
     "account" info */
  ftp_account = 10134,
  /** feed cookies into cookie engine */
  cookielist,
  /** ignore Content-Length */
  ignore_content_length = 136,
  /** Set to non-zero to skip the IP address received in a 227 PASV FTP server
     response. Typically used for FTP-SSL purposes but is not restricted to
     that. libcurl will then instead use the same IP address it used for the
     control connection. */
  ftp_skip_pasv_ip,
  /** Select "file method" to use when doing FTP, see the curl_ftpmethod
     above. */
  ftp_filemethod,
  /** Local port number to bind the socket to */
  localport,
  /** Number of ports to try, including the first one set with LOCALPORT.
     Thus, setting it to 1 will make no additional attempts but the first.
  */
  localportrange,
  /** no transfer, set up connection and let application use the socket by
     extracting it with CURLINFO_LASTSOCKET */
  connect_only,
  /** Function that will be called to convert from the
     network encoding (instead of using the iconv calls in libcurl) */
  conv_from_network_function = 20142,
  /** Function that will be called to convert to the
     network encoding (instead of using the iconv calls in libcurl) */
  conv_to_network_function,
  /** Function that will be called to convert from UTF8
     (instead of using the iconv calls in libcurl)
     Note that this is used only for SSL certificate processing */
  conv_from_utf8_function,
  /** if the connection proceeds too quickly then need to slow it down */
  /** limit-rate: maximum number of bytes per second to send or receive */
  max_send_speed_large = 30145,
  max_recv_speed_large, /// ditto
  /** Pointer to command string to send if USER/PASS fails. */
  ftp_alternative_to_user = 10147,
  /** callback function for setting socket options */
  sockoptfunction = 20148,
  sockoptdata = 10149,
  /** set to 0 to disable session ID re-use for this transfer, default is
     enabled (== 1) */
  ssl_sessionid_cache = 150,
  /** allowed SSH authentication methods */
  ssh_auth_types,
  /** Used by scp/sftp to do public/private key authentication */
  ssh_public_keyfile = 10152,
  ssh_private_keyfile,
  /** Send CCC (Clear Command Channel) after authentication */
  ftp_ssl_ccc = 154,
  /** Same as TIMEOUT and CONNECTTIMEOUT, but with ms resolution */
  timeout_ms,
  connecttimeout_ms,
  /** set to zero to disable the libcurl's decoding and thus pass the raw body
     data to the application even when it is encoded/compressed */
  http_transfer_decoding,
  http_content_decoding,        /// ditto
  /** Permission used when creating new files and directories on the remote
     server for protocols that support it, SFTP/SCP/FILE */
  new_file_perms,
  new_directory_perms,          /// ditto
  /** Set the behaviour of POST when redirecting. Values must be set to one
     of CURL_REDIR* defines below. This used to be called CURLOPT_POST301 */
  postredir,
  /** used by scp/sftp to verify the host's public key */
  ssh_host_public_key_md5 = 10162,
  /** Callback function for opening socket (instead of socket(2)). Optionally,
     callback is able change the address or refuse to connect returning
     CURL_SOCKET_BAD.  The callback should have type
     curl_opensocket_callback */
  opensocketfunction = 20163,
  opensocketdata = 10164,       /// ditto
  /** POST volatile input fields. */
  copypostfields,
  /** set transfer mode (;type=<a|i>) when doing FTP via an HTTP proxy */
  proxy_transfer_mode = 166,
  /** Callback function for seeking in the input stream */
  seekfunction = 20167,
  seekdata = 10168,     /// ditto
  /** CRL file */
  crlfile,
  /** Issuer certificate */
  issuercert,
  /** (IPv6) Address scope */
  address_scope = 171,
  /** Collect certificate chain info and allow it to get retrievable with
     CURLINFO_CERTINFO after the transfer is complete. (Unfortunately) only
     working with OpenSSL-powered builds. */
  certinfo,
  /** "name" and "pwd" to use when fetching. */
  username = 10173,
  password,     /// ditto
  /** "name" and "pwd" to use with Proxy when fetching. */
  proxyusername,
  proxypassword,        /// ditto
  /** Comma separated list of hostnames defining no-proxy zones. These should
     match both hostnames directly, and hostnames within a domain. For
     example, local.com will match local.com and www.local.com, but NOT
     notlocal.com or www.notlocal.com. For compatibility with other
     implementations of this, .local.com will be considered to be the same as
     local.com. A single * is the only valid wildcard, and effectively
     disables the use of proxy. */
  noproxy,
  /** block size for TFTP transfers */
  tftp_blksize = 178,
  /** Socks Service */
  socks5_gssapi_service = 10179,
  /** Socks Service */
  socks5_gssapi_nec = 180,
  /** set the bitmask for the protocols that are allowed to be used for the
     transfer, which thus helps the app which takes URLs from users or other
     external inputs and want to restrict what protocol(s) to deal
     with. Defaults to CURLPROTO_ALL. */
  protocols,
  /** set the bitmask for the protocols that libcurl is allowed to follow to,
     as a subset of the CURLOPT_PROTOCOLS ones. That means the protocol needs
     to be set in both bitmasks to be allowed to get redirected to. Defaults
     to all protocols except FILE and SCP. */
  redir_protocols,
  /** set the SSH knownhost file name to use */
  ssh_knownhosts = 10183,
  /** set the SSH host key callback, must point to a curl_sshkeycallback
     function */
  ssh_keyfunction = 20184,
  /** set the SSH host key callback custom pointer */
  ssh_keydata = 10185,
  /** set the SMTP mail originator */
  mail_from,
  /** set the SMTP mail receiver(s) */
  mail_rcpt,
  /** FTP: send PRET before PASV */
  ftp_use_pret = 188,
  /** RTSP request method (OPTIONS, SETUP, PLAY, etc...) */
  rtsp_request,
  /** The RTSP session identifier */
  rtsp_session_id = 10190,
  /** The RTSP stream URI */
  rtsp_stream_uri,
  /** The Transport: header to use in RTSP requests */
  rtsp_transport,
  /** Manually initialize the client RTSP CSeq for this handle */
  rtsp_client_cseq = 193,
  /** Manually initialize the server RTSP CSeq for this handle */
  rtsp_server_cseq,
  /** The stream to pass to INTERLEAVEFUNCTION. */
  interleavedata = 10195,
  /** Let the application define a custom write method for RTP data */
  interleavefunction = 20196,
  /** Turn on wildcard matching */
  wildcardmatch = 197,
  /** Directory matching callback called before downloading of an
     individual file (chunk) started */
  chunk_bgn_function = 20198,
  /** Directory matching callback called after the file (chunk)
     was downloaded, or skipped */
  chunk_end_function,
  /** Change match (fnmatch-like) callback for wildcard matching */
  fnmatch_function,
  /** Let the application define custom chunk data pointer */
  chunk_data = 10201,
  /** FNMATCH_FUNCTION user pointer */
  fnmatch_data,
  /** send linked-list of name:port:address sets */
  resolve,
  /** Set a username for authenticated TLS */
  tlsauth_username,
  /** Set a password for authenticated TLS */
  tlsauth_password,
  /** Set authentication type for authenticated TLS */
  tlsauth_type,
  /** the last unused */
  lastentry,

  writedata = file, /// convenient alias
  readdata = infile, /// ditto
  headerdata = writeheader, /// ditto
  rtspheader = httpheader, /// ditto
}
///
alias int CURLoption;
///
enum CURLOPT_SERVER_RESPONSE_TIMEOUT = CurlOption.ftp_response_timeout;

/** Below here follows defines for the CURLOPT_IPRESOLVE option. If a host
   name resolves addresses using more than one IP protocol version, this
   option might be handy to force libcurl to use a specific IP version. */
enum CurlIpResolve {
  whatever = 0, /** default, resolves addresses to all IP versions that your system allows */
  v4 = 1,       /** resolve to ipv4 addresses */
  v6 = 2        /** resolve to ipv6 addresses */
}

/** three convenient "aliases" that follow the name scheme better */
enum CURLOPT_WRITEDATA = CurlOption.file;
/// ditto
enum CURLOPT_READDATA = CurlOption.infile;
/// ditto
enum CURLOPT_HEADERDATA = CurlOption.writeheader;
/// ditto
enum CURLOPT_RTSPHEADER = CurlOption.httpheader;

/** These enums are for use with the CURLOPT_HTTP_VERSION option. */
enum CurlHttpVersion {
    none, /** setting this means we don't care, and that we'd
             like the library to choose the best possible
             for us! */
    v1_0, /** please use HTTP 1.0 in the request */
    v1_1, /** please use HTTP 1.1 in the request */
    last  /** *ILLEGAL* http version */
}

/**
 * Public API enums for RTSP requests
 */
enum CurlRtspReq {
    none,       ///
    options,    ///
    describe,   ///
    announce,   ///
    setup,      ///
    play,       ///
    pause,      ///
    teardown,   ///
    get_parameter,      ///
    set_parameter,      ///
    record,     ///
    receive,    ///
    last        ///
}

 /** These enums are for use with the CURLOPT_NETRC option. */
enum CurlNetRcOption {
    ignored,  /** The .netrc will never be read. This is the default. */
    optional  /** A user:password in the URL will be preferred to one in the .netrc. */,
    required, /** A user:password in the URL will be ignored.
               * Unless one is set programmatically, the .netrc
               * will be queried. */
    last        ///
}

///
enum CurlSslVersion {
    default_version,    ///
    tlsv1,      ///
    sslv2,      ///
    sslv3,      ///
    last /** never use */
}

///
enum CurlTlsAuth {
    none,       ///
    srp,        ///
    last /** never use */
}

/** symbols to use with CURLOPT_POSTREDIR.
   CURL_REDIR_POST_301 and CURL_REDIR_POST_302 can be bitwise ORed so that
   CURL_REDIR_POST_301 | CURL_REDIR_POST_302 == CURL_REDIR_POST_ALL */
enum CurlRedir {
  get_all = 0,  ///
  post_301 = 1, ///
  post_302 = 2, ///
  ///
  post_all = (1 | 2) // (CURL_REDIR_POST_301|CURL_REDIR_POST_302);
}
///
enum CurlTimeCond {
    none,       ///
    ifmodsince, ///
    ifunmodsince,       ///
    lastmod,    ///
    last        ///
}
///
alias int curl_TimeCond;


/** curl_strequal() and curl_strnequal() are subject for removal in a future
   libcurl, see lib/README.curlx for details */
extern (C) {
int  curl_strequal(in char *s1, in char *s2);
/// ditto
int  curl_strnequal(in char *s1, in char *s2, size_t n);
}
enum CurlForm {
    nothing, /********** the first one is unused ************/
    copyname,
    ptrname,
    namelength,
    copycontents,
    ptrcontents,
    contentslength,
    filecontent,
    array,
    obsolete,
    file,
    buffer,
    bufferptr,
    bufferlength,
    contenttype,
    contentheader,
    filename,
    end,
    obsolete2,
    stream,
    lastentry /** the last unused */
}
alias int CURLformoption;


/** structure to be used as parameter for CURLFORM_ARRAY */
extern (C) struct curl_forms
{
    CURLformoption option;      ///
    const(char) *value;        ///
}

/** use this for multipart formpost building */
/** Returns code for curl_formadd()
 *
 * Returns:
 * CURL_FORMADD_OK             on success
 * CURL_FORMADD_MEMORY         if the FormInfo allocation fails
 * CURL_FORMADD_OPTION_TWICE   if one option is given twice for one Form
 * CURL_FORMADD_NULL           if a null pointer was given for a char
 * CURL_FORMADD_MEMORY         if the allocation of a FormInfo struct failed
 * CURL_FORMADD_UNKNOWN_OPTION if an unknown option was used
 * CURL_FORMADD_INCOMPLETE     if the some FormInfo is not complete (or error)
 * CURL_FORMADD_MEMORY         if a curl_httppost struct cannot be allocated
 * CURL_FORMADD_MEMORY         if some allocation for string copying failed.
 * CURL_FORMADD_ILLEGAL_ARRAY  if an illegal option is used in an array
 *
 ***************************************************************************/
enum CurlFormAdd {
    ok, /** first, no error */
    memory,     ///
    option_twice,       ///
    null_ptr,   ///
    unknown_option,     ///
    incomplete, ///
    illegal_array,      ///
    disabled,  /** libcurl was built with this disabled */
    last        ///
}
///
alias int CURLFORMcode;

extern (C) {

/**
 * Name: curl_formadd()
 *
 * Description:
 *
 * Pretty advanced function for building multi-part formposts. Each invoke
 * adds one part that together construct a full post. Then use
 * CURLOPT_HTTPPOST to send it off to libcurl.
 */
CURLFORMcode  curl_formadd(curl_httppost **httppost, curl_httppost **last_post,...);

/**
 * callback function for curl_formget()
 * The void *arg pointer will be the one passed as second argument to
 *   curl_formget().
 * The character buffer passed to it must not be freed.
 * Should return the buffer length passed to it as the argument "len" on
 *   success.
 */
alias size_t  function(void *arg, in char *buf, size_t len)curl_formget_callback;

/**
 * Name: curl_formget()
 *
 * Description:
 *
 * Serialize a curl_httppost struct built with curl_formadd().
 * Accepts a void pointer as second argument which will be passed to
 * the curl_formget_callback function.
 * Returns 0 on success.
 */
int  curl_formget(curl_httppost *form, void *arg, curl_formget_callback append);
/**
 * Name: curl_formfree()
 *
 * Description:
 *
 * Free a multipart formpost previously built with curl_formadd().
 */
void  curl_formfree(curl_httppost *form);

/**
 * Name: curl_getenv()
 *
 * Description:
 *
 * Returns a malloc()'ed string that MUST be curl_free()ed after usage is
 * complete. DEPRECATED - see lib/README.curlx
 */
char * curl_getenv(in char *variable);

/**
 * Name: curl_version()
 *
 * Description:
 *
 * Returns a static ascii string of the libcurl version.
 */
char * curl_version();

/**
 * Name: curl_easy_escape()
 *
 * Description:
 *
 * Escapes URL strings (converts all letters consider illegal in URLs to their
 * %XX versions). This function returns a new allocated string or NULL if an
 * error occurred.
 */
char * curl_easy_escape(CURL *handle, in char *string, int length) @trusted;

/** the previous version: */
char * curl_escape(in char *string, int length) @trusted;


/**
 * Name: curl_easy_unescape()
 *
 * Description:
 *
 * Unescapes URL encoding in strings (converts all %XX codes to their 8bit
 * versions). This function returns a new allocated string or NULL if an error
 * occurred.
 * Conversion Note: On non-ASCII platforms the ASCII %XX codes are
 * converted into the host encoding.
 */
char * curl_easy_unescape(CURL *handle, in char *string, int length, int *outlength) @trusted;

/** the previous version */
char * curl_unescape(in char *string, int length) @trusted;

/**
 * Name: curl_free()
 *
 * Description:
 *
 * Provided for de-allocation in the same translation unit that did the
 * allocation. Added in libcurl 7.10
 */
void  curl_free(void *p);

/**
 * Name: curl_global_init()
 *
 * Description:
 *
 * curl_global_init() should be invoked exactly once for each application that
 * uses libcurl and before any call of other libcurl functions.
 *
 * This function is not thread-safe!
 */
CURLcode  curl_global_init(c_long flags);

/**
 * Name: curl_global_init_mem()
 *
 * Description:
 *
 * curl_global_init() or curl_global_init_mem() should be invoked exactly once
 * for each application that uses libcurl.  This function can be used to
 * initialize libcurl and set user defined memory management callback
 * functions.  Users can implement memory management routines to check for
 * memory leaks, check for mis-use of the curl library etc.  User registered
 * callback routines with be invoked by this library instead of the system
 * memory management routines like malloc, free etc.
 */
CURLcode  curl_global_init_mem(c_long flags, curl_malloc_callback m, curl_free_callback f, curl_realloc_callback r, curl_strdup_callback s, curl_calloc_callback c);

/**
 * Name: curl_global_cleanup()
 *
 * Description:
 *
 * curl_global_cleanup() should be invoked exactly once for each application
 * that uses libcurl
 */
void  curl_global_cleanup();
}

/** linked-list structure for the CURLOPT_QUOTE option (and other) */
extern (C) {

struct curl_slist
{
    char *data;
    curl_slist *next;
}

/**
 * Name: curl_slist_append()
 *
 * Description:
 *
 * Appends a string to a linked list. If no list exists, it will be created
 * first. Returns the new list, after appending.
 */
curl_slist * curl_slist_append(curl_slist *, in char *);

/**
 * Name: curl_slist_free_all()
 *
 * Description:
 *
 * free a previously built curl_slist.
 */
void  curl_slist_free_all(curl_slist *);

/**
 * Name: curl_getdate()
 *
 * Description:
 *
 * Returns the time, in seconds since 1 Jan 1970 of the time string given in
 * the first argument. The time argument in the second parameter is unused
 * and should be set to NULL.
 */
time_t  curl_getdate(char *p, time_t *unused);

/** info about the certificate chain, only for OpenSSL builds. Asked
   for with CURLOPT_CERTINFO / CURLINFO_CERTINFO */
struct curl_certinfo
{
    int num_of_certs;      /** number of certificates with information */
    curl_slist **certinfo; /** for each index in this array, there's a
                              linked list with textual information in the
                              format "name: value" */
}

} // extern (C) end

///
enum CURLINFO_STRING = 0x100000;
///
enum CURLINFO_LONG = 0x200000;
///
enum CURLINFO_DOUBLE = 0x300000;
///
enum CURLINFO_SLIST = 0x400000;
///
enum CURLINFO_MASK = 0x0fffff;

///
enum CURLINFO_TYPEMASK = 0xf00000;

///
enum CurlInfo {
    none,       ///
    effective_url = 1048577,    ///
    response_code = 2097154,    ///
    total_time = 3145731,       ///
    namelookup_time,    ///
    connect_time,       ///
    pretransfer_time,   ///
    size_upload,        ///
    size_download,      ///
    speed_download,     ///
    speed_upload,       ///
    header_size = 2097163,      ///
    request_size,       ///
    ssl_verifyresult,   ///
    filetime,   ///
    content_length_download = 3145743,  ///
    content_length_upload,      ///
    starttransfer_time, ///
    content_type = 1048594,     ///
    redirect_time = 3145747,    ///
    redirect_count = 2097172,   ///
    private_info = 1048597,     ///
    http_connectcode = 2097174, ///
    httpauth_avail,     ///
    proxyauth_avail,    ///
    os_errno,   ///
    num_connects,       ///
    ssl_engines = 4194331,      ///
    cookielist, ///
    lastsocket = 2097181,       ///
    ftp_entry_path = 1048606,   ///
    redirect_url,       ///
    primary_ip, ///
    appconnect_time = 3145761,  ///
    certinfo = 4194338, ///
    condition_unmet = 2097187,  ///
    rtsp_session_id = 1048612,  ///
    rtsp_client_cseq = 2097189, ///
    rtsp_server_cseq,   ///
    rtsp_cseq_recv,     ///
    primary_port,       ///
    local_ip = 1048617, ///
    local_port = 2097194,       ///
    /** Fill in new entries below here! */
    lastone = 42
}
///
alias int CURLINFO;

/** CURLINFO_RESPONSE_CODE is the new name for the option previously known as
   CURLINFO_HTTP_CODE */
enum CURLINFO_HTTP_CODE = CurlInfo.response_code;

///
enum CurlClosePolicy {
    none,       ///
    oldest,     ///
    least_recently_used,        ///
    least_traffic,      ///
    slowest,    ///
    callback,   ///
    last        ///
}
///
alias int curl_closepolicy;

///
enum CurlGlobal {
  ssl = 1,      ///
  win32 = 2,    ///
  ///
  all = (1 | 2), // (CURL_GLOBAL_SSL|CURL_GLOBAL_WIN32);
  nothing = 0,  ///
  default_ = (1 | 2) /// all
}

/******************************************************************************
 * Setup defines, protos etc for the sharing stuff.
 */

/** Different data locks for a single share */
enum CurlLockData {
    none,       ///
    /**  CURL_LOCK_DATA_SHARE is used internally to say that
     *  the locking is just made to change the internal state of the share
     *  itself.
     */
    share,
    cookie,     ///
    dns,        ///
    ssl_session,        ///
    connect,    ///
    last        ///
}
///
alias int curl_lock_data;

/** Different lock access types */
enum CurlLockAccess {
    none,            /** unspecified action */
    shared_access,   /** for read perhaps */
    single,          /** for write perhaps */
    last             /** never use */
}
///
alias int curl_lock_access;

///
alias void  function(CURL *handle, curl_lock_data data, curl_lock_access locktype, void *userptr)curl_lock_function;
///
alias void  function(CURL *handle, curl_lock_data data, void *userptr)curl_unlock_function;

///
alias void CURLSH;

///
enum CurlShError {
    ok,          /** all is fine */
    bad_option,  /** 1 */
    in_use,      /** 2 */
    invalid,     /** 3 */
    nomem,       /** out of memory */
    last         /** never use */
}
///
alias int CURLSHcode;

/** pass in a user data pointer used in the lock/unlock callback
   functions */
enum CurlShOption {
    none,         /** don't use */
    share,        /** specify a data type to share */
    unshare,      /** specify which data type to stop sharing */
    lockfunc,     /** pass in a 'curl_lock_function' pointer */
    unlockfunc,   /** pass in a 'curl_unlock_function' pointer */
    userdata,     /** pass in a user data pointer used in the lock/unlock
                     callback functions */
    last          /** never use */
}
///
alias int CURLSHoption;

extern (C) {
///
CURLSH * curl_share_init();
///
CURLSHcode  curl_share_setopt(CURLSH *, CURLSHoption option,...);
///
CURLSHcode  curl_share_cleanup(CURLSH *);
}

/*****************************************************************************
 * Structures for querying information about the curl library at runtime.
 */

// CURLVERSION_*
enum CurlVer {
    first,      ///
    second,     ///
    third,      ///
    fourth,     ///
    last        ///
}
///
alias int CURLversion;

/** The 'CURLVERSION_NOW' is the symbolic name meant to be used by
   basically all programs ever that want to get version information. It is
   meant to be a built-in version number for what kind of struct the caller
   expects. If the struct ever changes, we redefine the NOW to another enum
   from above. */
enum CURLVERSION_NOW = CurlVer.fourth;

///
extern (C) struct _N28
{
  CURLversion age;     /** age of the returned struct */
  const(char) *version_;      /** LIBCURL_VERSION */
  uint version_num;    /** LIBCURL_VERSION_NUM */
  const(char) *host;          /** OS/host/cpu/machine when configured */
  int features;        /** bitmask, see defines below */
  const(char) *ssl_version;   /** human readable string */
  c_long ssl_version_num; /** not used anymore, always 0 */
  const(char) *libz_version;     /** human readable string */
  /** protocols is terminated by an entry with a NULL protoname */
  const(char) **protocols;
  /** The fields below this were added in CURLVERSION_SECOND */
  const(char) *ares;
  int ares_num;
  /** This field was added in CURLVERSION_THIRD */
  const(char) *libidn;
  /** These field were added in CURLVERSION_FOURTH */
  /** Same as '_libiconv_version' if built with HAVE_ICONV */
  int iconv_ver_num;
  const(char) *libssh_version;  /** human readable string */
}
///
alias _N28 curl_version_info_data;

///
// CURL_VERSION_*
enum CurlVersion {
  ipv6         = 1,     /** IPv6-enabled */
  kerberos4    = 2,     /** kerberos auth is supported */
  ssl          = 4,     /** SSL options are present */
  libz         = 8,     /** libz features are present */
  ntlm         = 16,    /** NTLM auth is supported */
  gssnegotiate = 32,    /** Negotiate auth support */
  dbg          = 64,    /** built with debug capabilities */
  asynchdns    = 128,   /** asynchronous dns resolves */
  spnego       = 256,   /** SPNEGO auth */
  largefile    = 512,   /** supports files bigger than 2GB */
  idn          = 1024,  /** International Domain Names support */
  sspi         = 2048,  /** SSPI is supported */
  conv         = 4096,  /** character conversions supported */
  curldebug    = 8192,  /** debug memory tracking supported */
  tlsauth_srp  = 16384  /** TLS-SRP auth is supported */
}

extern (C) {
/**
 * Name: curl_version_info()
 *
 * Description:
 *
 * This function returns a pointer to a static copy of the version info
 * struct. See above.
 */
curl_version_info_data * curl_version_info(CURLversion );

/**
 * Name: curl_easy_strerror()
 *
 * Description:
 *
 * The curl_easy_strerror function may be used to turn a CURLcode value
 * into the equivalent human readable error string.  This is useful
 * for printing meaningful error messages.
 */
const(char)* curl_easy_strerror(CURLcode );

/**
 * Name: curl_share_strerror()
 *
 * Description:
 *
 * The curl_share_strerror function may be used to turn a CURLSHcode value
 * into the equivalent human readable error string.  This is useful
 * for printing meaningful error messages.
 */
const(char)* curl_share_strerror(CURLSHcode );

/**
 * Name: curl_easy_pause()
 *
 * Description:
 *
 * The curl_easy_pause function pauses or unpauses transfers. Select the new
 * state by setting the bitmask, use the convenience defines below.
 *
 */
CURLcode  curl_easy_pause(CURL *handle, int bitmask);
}


///
enum CurlPause {
  recv      = 1,        ///
  recv_cont = 0,        ///
  send      = 4,        ///
  send_cont = 0,        ///
  ///
  all       = (1 | 4), // CURLPAUSE_RECV | CURLPAUSE_SEND
  ///
  cont      = (0 | 0), // CURLPAUSE_RECV_CONT | CURLPAUSE_SEND_CONT
}

/* unfortunately, the easy.h and multi.h include files need options and info
  stuff before they can be included! */
/* ***************************************************************************
 *                                  _   _ ____  _
 *  Project                     ___| | | |  _ \| |
 *                             / __| | | | |_) | |
 *                            | (__| |_| |  _ <| |___
 *                             \___|\___/|_| \_\_____|
 *
 * Copyright (C) 1998 - 2008, Daniel Stenberg, <daniel@haxx.se>, et al.
 *
 * This software is licensed as described in the file COPYING, which
 * you should have received as part of this distribution. The terms
 * are also available at http://curl.haxx.se/docs/copyright.html.
 *
 * You may opt to use, copy, modify, merge, publish, distribute and/or sell
 * copies of the Software, and permit persons to whom the Software is
 * furnished to do so, under the terms of the COPYING file.
 *
 * This software is distributed on an "AS IS" basis, WITHOUT WARRANTY OF ANY
 * KIND, either express or implied.
 *
 ***************************************************************************/

extern (C) {
  ///
  CURL * curl_easy_init();
  ///
  CURLcode  curl_easy_setopt(CURL *curl, CURLoption option,...);
  ///
  CURLcode  curl_easy_perform(CURL *curl);
  ///
  void  curl_easy_cleanup(CURL *curl);
}

/**
 * Name: curl_easy_getinfo()
 *
 * Description:
 *
 * Request internal information from the curl session with this function.  The
 * third argument MUST be a pointer to a long, a pointer to a char * or a
 * pointer to a double (as the documentation describes elsewhere).  The data
 * pointed to will be filled in accordingly and can be relied upon only if the
 * function returns CURLE_OK.  This function is intended to get used *AFTER* a
 * performed transfer, all results from this function are undefined until the
 * transfer is completed.
 */
extern (C) CURLcode  curl_easy_getinfo(CURL *curl, CURLINFO info,...);


/**
 * Name: curl_easy_duphandle()
 *
 * Description:
 *
 * Creates a new curl session handle with the same options set for the handle
 * passed in. Duplicating a handle could only be a matter of cloning data and
 * options, internal state info and things like persistant connections cannot
 * be transfered. It is useful in multithreaded applications when you can run
 * curl_easy_duphandle() for each new thread to avoid a series of identical
 * curl_easy_setopt() invokes in every thread.
 */
extern (C) CURL * curl_easy_duphandle(CURL *curl);

/**
 * Name: curl_easy_reset()
 *
 * Description:
 *
 * Re-initializes a CURL handle to the default values. This puts back the
 * handle to the same state as it was in when it was just created.
 *
 * It does keep: live connections, the Session ID cache, the DNS cache and the
 * cookies.
 */
extern (C) void  curl_easy_reset(CURL *curl);

/**
 * Name: curl_easy_recv()
 *
 * Description:
 *
 * Receives data from the connected socket. Use after successful
 * curl_easy_perform() with CURLOPT_CONNECT_ONLY option.
 */
extern (C) CURLcode  curl_easy_recv(CURL *curl, void *buffer, size_t buflen, size_t *n);

/**
 * Name: curl_easy_send()
 *
 * Description:
 *
 * Sends data over the connected socket. Use after successful
 * curl_easy_perform() with CURLOPT_CONNECT_ONLY option.
 */
extern (C) CURLcode  curl_easy_send(CURL *curl, void *buffer, size_t buflen, size_t *n);


/*
 * This header file should not really need to include "curl.h" since curl.h
 * itself includes this file and we expect user applications to do #include
 * <curl/curl.h> without the need for especially including multi.h.
 *
 * For some reason we added this include here at one point, and rather than to
 * break existing (wrongly written) libcurl applications, we leave it as-is
 * but with this warning attached.
 */
/* ***************************************************************************
 *                                  _   _ ____  _
 *  Project                     ___| | | |  _ \| |
 *                             / __| | | | |_) | |
 *                            | (__| |_| |  _ <| |___
 *                             \___|\___/|_| \_\_____|
 *
 * Copyright (C) 1998 - 2010, Daniel Stenberg, <daniel@haxx.se>, et al.
 *
 * This software is licensed as described in the file COPYING, which
 * you should have received as part of this distribution. The terms
 * are also available at http://curl.haxx.se/docs/copyright.html.
 *
 * You may opt to use, copy, modify, merge, publish, distribute and/or sell
 * copies of the Software, and permit persons to whom the Software is
 * furnished to do so, under the terms of the COPYING file.
 *
 * This software is distributed on an "AS IS" basis, WITHOUT WARRANTY OF ANY
 * KIND, either express or implied.
 *
 ***************************************************************************/

///
alias void CURLM;

///
enum CurlM {
    call_multi_perform = -1, /** please call curl_multi_perform() or curl_multi_socket*() soon */
    ok, ///
    bad_handle,              /** the passed-in handle is not a valid CURLM handle */
    bad_easy_handle,       /** an easy handle was not good/valid */
    out_of_memory,         /** if you ever get this, you're in deep sh*t */
    internal_error,        /** this is a libcurl bug */
    bad_socket,            /** the passed in socket argument did not match */
    unknown_option,        /** curl_multi_setopt() with unsupported option */
    last,       ///
}
///
alias int CURLMcode;

/** just to make code nicer when using curl_multi_socket() you can now check
   for CURLM_CALL_MULTI_SOCKET too in the same style it works for
   curl_multi_perform() and CURLM_CALL_MULTI_PERFORM */
enum CURLM_CALL_MULTI_SOCKET = CurlM.call_multi_perform;

///
enum CurlMsg
{
    none,       ///
    done, /** This easy handle has completed. 'result' contains
             the CURLcode of the transfer */
    last, /** no used */
}
///
alias int CURLMSG;

///
extern (C) union _N31
{
    void *whatever;  /** message-specific data */
    CURLcode result; /** return code for transfer */
}

///
extern (C) struct CURLMsg
{
    CURLMSG msg;        /** what this message means */
    CURL *easy_handle;  /** the handle it concerns */
    _N31 data;  ///
}

/**
 * Name:    curl_multi_init()
 *
 * Desc:    inititalize multi-style curl usage
 *
 * Returns: a new CURLM handle to use in all 'curl_multi' functions.
 */
extern (C) CURLM * curl_multi_init();

/**
 * Name:    curl_multi_add_handle()
 *
 * Desc:    add a standard curl handle to the multi stack
 *
 * Returns: CURLMcode type, general multi error code.
 */
extern (C) CURLMcode  curl_multi_add_handle(CURLM *multi_handle, CURL *curl_handle);

 /**
  * Name:    curl_multi_remove_handle()
  *
  * Desc:    removes a curl handle from the multi stack again
  *
  * Returns: CURLMcode type, general multi error code.
  */
extern (C) CURLMcode  curl_multi_remove_handle(CURLM *multi_handle, CURL *curl_handle);

 /**
  * Name:    curl_multi_fdset()
  *
  * Desc:    Ask curl for its fd_set sets. The app can use these to select() or
  *          poll() on. We want curl_multi_perform() called as soon as one of
  *          them are ready.
  *
  * Returns: CURLMcode type, general multi error code.
  */

/** tmp decl */
alias int fd_set;
///
extern (C) CURLMcode  curl_multi_fdset(CURLM *multi_handle, fd_set *read_fd_set, fd_set *write_fd_set, fd_set *exc_fd_set, int *max_fd);

 /**
  * Name:    curl_multi_perform()
  *
  * Desc:    When the app thinks there's data available for curl it calls this
  *          function to read/write whatever there is right now. This returns
  *          as soon as the reads and writes are done. This function does not
  *          require that there actually is data available for reading or that
  *          data can be written, it can be called just in case. It returns
  *          the number of handles that still transfer data in the second
  *          argument's integer-pointer.
  *
  * Returns: CURLMcode type, general multi error code. *NOTE* that this only
  *          returns errors etc regarding the whole multi stack. There might
  *          still have occurred problems on invidual transfers even when this
  *          returns OK.
  */
extern (C) CURLMcode  curl_multi_perform(CURLM *multi_handle, int *running_handles);

 /**
  * Name:    curl_multi_cleanup()
  *
  * Desc:    Cleans up and removes a whole multi stack. It does not free or
  *          touch any individual easy handles in any way. We need to define
  *          in what state those handles will be if this function is called
  *          in the middle of a transfer.
  *
  * Returns: CURLMcode type, general multi error code.
  */
extern (C) CURLMcode  curl_multi_cleanup(CURLM *multi_handle);

/**
 * Name:    curl_multi_info_read()
 *
 * Desc:    Ask the multi handle if there's any messages/informationals from
 *          the individual transfers. Messages include informationals such as
 *          error code from the transfer or just the fact that a transfer is
 *          completed. More details on these should be written down as well.
 *
 *          Repeated calls to this function will return a new struct each
 *          time, until a special "end of msgs" struct is returned as a signal
 *          that there is no more to get at this point.
 *
 *          The data the returned pointer points to will not survive calling
 *          curl_multi_cleanup().
 *
 *          The 'CURLMsg' struct is meant to be very simple and only contain
 *          very basic informations. If more involved information is wanted,
 *          we will provide the particular "transfer handle" in that struct
 *          and that should/could/would be used in subsequent
 *          curl_easy_getinfo() calls (or similar). The point being that we
 *          must never expose complex structs to applications, as then we'll
 *          undoubtably get backwards compatibility problems in the future.
 *
 * Returns: A pointer to a filled-in struct, or NULL if it failed or ran out
 *          of structs. It also writes the number of messages left in the
 *          queue (after this read) in the integer the second argument points
 *          to.
 */
extern (C) CURLMsg * curl_multi_info_read(CURLM *multi_handle, int *msgs_in_queue);

/**
 * Name:    curl_multi_strerror()
 *
 * Desc:    The curl_multi_strerror function may be used to turn a CURLMcode
 *          value into the equivalent human readable error string.  This is
 *          useful for printing meaningful error messages.
 *
 * Returns: A pointer to a zero-terminated error message.
 */
extern (C) const(char)* curl_multi_strerror(CURLMcode );

/**
 * Name:    curl_multi_socket() and
 *          curl_multi_socket_all()
 *
 * Desc:    An alternative version of curl_multi_perform() that allows the
 *          application to pass in one of the file descriptors that have been
 *          detected to have "action" on them and let libcurl perform.
 *          See man page for details.
 */
enum CurlPoll {
  none_ = 0,   /** jdrewsen - underscored in order not to clash with reserved D symbols */
  in_ = 1,      ///
  out_ = 2,     ///
  inout_ = 3,   ///
  remove_ = 4   ///
}

///
alias CURL_SOCKET_BAD CURL_SOCKET_TIMEOUT;

///
enum CurlCSelect {
  in_ = 0x01,  /** jdrewsen - underscored in order not to clash with reserved D symbols */
  out_ = 0x02,  ///
  err_ = 0x04   ///
}

extern (C) {
  ///
  alias int function(CURL *easy,                            /** easy handle */
                     curl_socket_t s,                     /** socket */
                     int what,                            /** see above */
                     void *userp,                         /** private callback pointer */
                     void *socketp)curl_socket_callback;          /** private socket pointer */
}

/**
 * Name:    curl_multi_timer_callback
 *
 * Desc:    Called by libcurl whenever the library detects a change in the
 *          maximum number of milliseconds the app is allowed to wait before
 *          curl_multi_socket() or curl_multi_perform() must be called
 *          (to allow libcurl's timed events to take place).
 *
 * Returns: The callback should return zero.
 */
/** private callback pointer */

extern (C) {
  alias int function(CURLM *multi,    /** multi handle */
                     c_long timeout_ms,  /** see above */
                     void *userp) curl_multi_timer_callback;  /** private callback pointer */
  /// ditto
  CURLMcode  curl_multi_socket(CURLM *multi_handle, curl_socket_t s, int *running_handles);
  /// ditto
  CURLMcode  curl_multi_socket_action(CURLM *multi_handle, curl_socket_t s, int ev_bitmask, int *running_handles);
  /// ditto
  CURLMcode  curl_multi_socket_all(CURLM *multi_handle, int *running_handles);
}

/** This macro below was added in 7.16.3 to push users who recompile to use
   the new curl_multi_socket_action() instead of the old curl_multi_socket()
*/

/**
 * Name:    curl_multi_timeout()
 *
 * Desc:    Returns the maximum number of milliseconds the app is allowed to
 *          wait before curl_multi_socket() or curl_multi_perform() must be
 *          called (to allow libcurl's timed events to take place).
 *
 * Returns: CURLM error code.
 */
extern (C) CURLMcode  curl_multi_timeout(CURLM *multi_handle, c_long *milliseconds);

///
enum CurlMOption {
    socketfunction = 20001,    /** This is the socket callback function pointer */
    socketdata = 10002,        /** This is the argument passed to the socket callback */
    pipelining = 3,             /** set to 1 to enable pipelining for this multi handle */
    timerfunction = 20004,     /** This is the timer callback function pointer */
    timerdata = 10005,          /** This is the argument passed to the timer callback */
    maxconnects = 6,            /** maximum number of entries in the connection cache */
    lastentry   ///
}
///
alias int CURLMoption;


/**
 * Name:    curl_multi_setopt()
 *
 * Desc:    Sets options for the multi handle.
 *
 * Returns: CURLM error code.
 */
extern (C) CURLMcode  curl_multi_setopt(CURLM *multi_handle, CURLMoption option,...);


/**
 * Name:    curl_multi_assign()
 *
 * Desc:    This function sets an association in the multi handle between the
 *          given socket and a private pointer of the application. This is
 *          (only) useful for curl_multi_socket uses.
 *
 * Returns: CURLM error code.
 */
extern (C) CURLMcode  curl_multi_assign(CURLM *multi_handle, curl_socket_t sockfd, void *sockp);
