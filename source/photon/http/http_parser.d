/// Minimalistic low-overhead wrapper for nodejs/http-parser
/// Used for benchmarks with simple server
module photon.http.http_parser;

import std.range.primitives;
import std.ascii, std.string, std.exception;

enum HTTP_REQUEST = 1;
enum HTTP_RESPONSE = 2;
enum HTTP_BOTH = 3;
enum HTTTP_MAX_HEADER_SIZE = (80*1024);

/* Flag values for http_parser.flags field */
enum flags
  { F_CHUNKED               = 1 << 0
  , F_CONNECTION_KEEP_ALIVE = 1 << 1
  , F_CONNECTION_CLOSE      = 1 << 2
  , F_CONNECTION_UPGRADE    = 1 << 3
  , F_TRAILING              = 1 << 4
  , F_UPGRADE               = 1 << 5
  , F_SKIPBODY              = 1 << 6
  , F_CONTENTLENGTH         = 1 << 7
  };

public enum HttpParserType: uint {
	request = 0,
	response = 1,
	both = 2
}

public enum HttpMethod: uint {
	DELETE = 0,
	GET = 1,
	HEAD = 2,
	POST = 3,
	PUT = 4,
	/* pathological */
	CONNECT = 5,
	OPTIONS = 6,
	TRACE = 7,
	/* WebDAV */
	COPY = 8,
	LOCK = 9,
	MKCOL = 10,
	MOVE = 11,
	PROPFIND = 12,
	PROPPATCH = 13,
	SEARCH = 14,
	UNLOCK = 15,
	BIND = 16,
	REBIND = 17,
	UNBIND = 18,
	ACL = 19,
	/* subversion */
	REPORT = 20,
	MKACTIVITY = 21,
	CHECKOUT = 22,
	MERGE = 23,
	/* upnp */
	MSEARCH = 24,
	NOTIFY = 25,
	SUBSCRIBE = 26,
	UNSUBSCRIBE = 27,
	/* RFC-5789 */
	PATCH = 28,
	PURGE = 29,
	/* CalDAV */
	MKCALENDAR = 30,
	/* RFC-2068, section 19.6.1.2 */
	LINK = 31,
	UNLINK = 32,
	/* icecast */
	SOURCE = 33,
}

enum ParserFields {
  body_,
  method,
  url,
  status,
  port,
  header,
  query,
  version_,
  fragment,
  userinfo
}

struct Header
{
  char[] key;
  char[] value;
}

struct HttpEvent {
  ParserFields tag;
  union {
    ubyte[] body_;
    int method;
    char[] url;
    int status;
    int port;
    Header header;
    char[] query;
    char[] fragment;
    char[] userinfo;
    char[] version_;
  }
  string toString() {
    import std.conv;
    switch(tag) {
      case ParserFields.version_: 
        return "Version(" ~ version_.idup ~ ")";
      case ParserFields.method:
        return "Method("~ method.to!string ~")";
      case ParserFields.header:
        return "Header("~ header.key.idup ~"," ~ header.value.idup ~")";
      case ParserFields.url:
        return "URL("~ url.idup ~")";
      case ParserFields.body_:
        return "Body("~ body_.to!string ~")";
      default:
        return "****";
    }
  }
}

enum HttpState {
  METHOD = 0,
  URL = 1,
  VERSION = 2,
  HEADER_START = 3,
  BODY = 4,
  END = 5
}

struct Parser {
  char[] buf;
  size_t pos;
  HttpEvent event;
  bool isEmpty = false;
  HttpState state;

  void put(char[] bite) {
    buf ~= bite;
    step();
  }

  void skipWs() {
    while (buf[pos].isWhite()) pos++;
  }

  void step() {
    import std.stdio;
    int length = 0;
    with (HttpState) switch(state) {
      case METHOD:
        with (HttpMethod) 
          if (buf[pos..pos+3].toUpper() == "GET") {
            event.method = GET;
            pos += 3;
          } 
          else if (buf[pos..pos+3].toUpper() == "PUT") {
            event.method = PUT;
            pos += 3;
          }
          else if (buf[pos..pos+4].toUpper() == "POST") {
            event.method = POST;
            pos += 4;
          }
          else if (buf[pos..pos+6].toUpper() == "DELETE") {
            event.method = DELETE;
            pos += 6;
          }
        event.tag = ParserFields.method;
        state = HttpState.URL;
        break;
      case URL:
        skipWs();
        auto start = pos;
        while (pos < buf.length) {
          if (buf[pos] == '/' || buf[pos].isAlpha() || buf[pos].isDigit())
            pos++;
          else
            break;
        }
        event.tag = ParserFields.url;
        event.url = buf[start..pos];
        state = HttpState.VERSION;
        break;
      case VERSION:
        skipWs();
        auto start = pos;
        while (pos < buf.length) {
          if (buf[pos] == '.' || buf[pos] == '/' || buf[pos].isAlpha() || buf[pos].isDigit())
            pos++;
          else
            break;
        }
        event.tag = ParserFields.version_;
        event.version_ = buf[start..pos];
        state = HttpState.HEADER_START;
        skipWs();
        break;
      case HEADER_START:
        auto start = pos;
        while (pos < buf.length) {
          if (buf[pos] == '-' || buf[pos].isAlpha() || buf[pos].isDigit())
            pos++;
          else if (buf[pos] == ':')
            break;
          else {
            event.body_ = cast(ubyte[])buf[pos..$];
            event.tag = ParserFields.body_;
            state = BODY;
            return;
          }
        }
        Header hdr;
        event.tag = ParserFields.header;
        hdr.key = buf[start..pos];
        pos++;
        skipWs();
        start = pos;
        while (pos < buf.length) {
          if (buf[pos] == '*' || buf[pos] == '/' || buf[pos] == ':' || buf[pos] == '.' || buf[pos].isAlpha() || buf[pos].isDigit())
            pos++;
          else
            break;
        }
        hdr.value = buf[start..pos];
        event.header = hdr;
        state = HEADER_START;
        if (buf[pos] == '\r' && buf[pos+1] == '\n') pos += 2;
        if (hdr.key.toUpper() == "CONTENT-LENGTH") {
          import std.conv;
          length = hdr.value.to!int;
        }
        break;
      case BODY:
        event.tag = ParserFields.body_;
        event.body_ = cast(ubyte[])buf[pos..$];
        pos = buf.length;
        if (event.body_.length == length) {
          state = END;
        }
        break;
      case END:
        isEmpty = true;
        break;
      default:
        assert(false);
    }
  }

  void clear() {
    buf.length = 0;
    buf.assumeSafeAppend();
  }

  bool empty() const { return isEmpty; }

  void popFront() {
    step();
  }

  HttpEvent front() {
    return event;
  }
}

static assert(isInputRange!Parser);
static assert(isOutputRange!(Parser, char[]));
