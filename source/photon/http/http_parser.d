/// Simple HTTP parser
module photon.http.http_parser;

import std.range.primitives;
import std.ascii, std.array, std.string, std.exception;
import photon.http.state_machine;

import glow.xbuf;

enum HTTP_REQUEST = 1;
enum HTTP_RESPONSE = 2;
enum HTTP_BOTH = 3;
enum HTTP_MAX_HEADER_SIZE = (80*1024);

public enum HttpParserType: uint {
	request = 0,
	response = 1,
	both = 2
}

struct HttpHeader
{
  const(char)[] key;
  const(char)[] value;
}

struct HttpRequest {
	HttpHeader[] headers;
	HttpMethod method;
	const(char)[] uri;
	const(char)[] version_;
	const(ubyte)[] body_;
}

enum HttpState : int {
  METHOD = 170, // include all up to 170
  URL = 171,
  VERSION = 172,
  HEADER_START = 173,
  HEADER_VALUE_START = 174,
  BODY = 175,
  END = 176,
  ERROR = -1
}

immutable toUpper = () {
  char[256] table;
  foreach (i; 0..table.length) {
    table[i] = std.ascii.toUpper(cast(char)i);
  }
  return table;
}();

// assumes b is UPPER CASE already
bool caselessEqual(const(char)[] a, const(char)[] b) {
    if (a.length != b.length) return false;
    for (size_t i = 0; i < a.length; i++) {
      if (a[i] != b[i] && toUpper[a[i]] != b[i]) {
        return false;
      }
    }
    return true;
}

struct Parser {
private:
  XBuf buf;
  size_t pos;
  int state;
  HttpMethod method;
  char[] url;
  int length;
  Appender!(HttpHeader[]) headers;
  HttpHeader header;
  char[] version_;
  ubyte[] body_;
  public bool connectionClose;
  public string error;
  
  public this(XBuf buf) {
    import std.algorithm.mutation;
    this.buf = move(buf);
  }

  size_t skipWs(size_t p) {
    while (p < buf.length && buf[p].isWhite()) p++;
    return p;
  }

  size_t skipRN(size_t p) {
    while (p < buf.length) {
      if (buf[p] == '\r') {
        p++;
        if (p == buf.length) {
          return 0;
        }
        if (buf[p] == '\n') {
          return p+1;
        }
        // If we found \r but next char is not \n, it's an error
        return size_t.max;
      }
      else if(buf[p] == '\n') {
        return p + 1;
      }
      else if(buf[p].isWhite()) {
        p++;
      } else {
        return size_t.max;
      }
    }
    return 0;
  }

  public void compact() {
    buf.compact(pos);
    pos = 0;
  }

  public void reset() {
    state = 0;
    url = null;
    header = HttpHeader.init;
    headers.clear();
    method = HttpMethod.init;
    version_ = null;
    error = null;
    connectionClose = false;
  }

  public int load() {
      int result = buf.load();
      if (result == 0 && state != 0) {
        error = "Unexpected end of input";
        return -1;
      }
      if (result < 0) return result;
      if (result == 0) return 0;
      return result;
  }

  public int parse(ref HttpRequest req) {
    int result = step();
    if (result == -1) {
      return result;
    }
    else if(result == 0) {
      return 0;
    }
    else {
      req.body_ = body_;
      req.method = method;
      req.uri = url;
      req.headers = headers[];
      req.body_ = body_;
      return 1;
    }
  }

  int step() {
    size_t p = pos;
    with (HttpState) switch(state) {
      case 0: .. case METHOD:
        parseHttpMethod(buf, p, state, method);
        pos = p;
        if (state < 0) {
          error = "Wrong http method";
          return -1;
        }
        if (state == 0) {
          return 0;
        }
        state = HttpState.URL;
        goto case URL;
      case URL:
        p = skipWs(pos);
        auto start = p;
        while (p < buf.length) {
          if (buf[p] == '/' || buf[p] == '-' || buf[p] == '%' || buf[p] == '.' || buf[p] == '_' || 
              buf[p] == '~' || buf[p] == '?' || buf[p] == '&' || buf[p] == '=' || buf[p] == ':' ||
              buf[p] == '#' || buf[p] == '+' || buf[p].isAlpha() || buf[p].isDigit())
            p++;
          else
            break;
        }
        if (p == buf.length) {
          return 0;
        }
        pos = p;
        url = cast(char[])buf[start..pos];
        state = VERSION;
        goto case VERSION;
      case VERSION:
        p = skipWs(pos);
        auto start = p;
        while (p < buf.length) {
          if (buf[p] == '.' || buf[p] == '/' || buf[p].isAlpha() || buf[p].isDigit())
            p++;
          else
            break;
        }
        if (p == buf.length) return 0;
        p = skipRN(p);
        if (p == 0) return 0;
        if (p == size_t.max) {
          error = "Expected \\r\\n after VERSION";
          return -1;
        }
        pos = p;
        version_ = cast(char[])buf[start..pos];
        state = HEADER_START;
        goto case HEADER_START;
      case HEADER_START:
        auto start = pos;
        p = pos;
        while (p < buf.length) {
          if (buf[p] == '-' || buf[p].isAlpha() || buf[p].isDigit())
            p++;
          else if (buf[p] == ':')
            break;
          else {
            p = skipRN(p);
            if (p == 0) return 0;
            if (p == size_t.max) {
              error = "Expected \\r\\n terminating headers list";
              return -1;
            }
            pos = p;
            state = BODY;
            goto case BODY;
          }
        }
        if (p == buf.length) return 0;
        header.key = cast(char[])buf[start..p];
        p++;
        pos = p;
        goto case HEADER_VALUE_START;
      case HEADER_VALUE_START:
        p = skipWs(pos);
        size_t start = p;
        while (p < buf.length) {
          if (buf[p] != '\r' && buf[p] != '\n')
            p++;
          else {
            size_t end = p;
            p = skipRN(p);
            if (p == 0) {
              return 0;
            }
            if (p == size_t.max) {
              error = "Expected \\r\\n terminating header value";
              return -1;
            }
            header.value = cast(char[])buf[start..end];
            headers ~= header;
            state = HEADER_START;
            pos = p;
            import std.uni;
            if (caselessEqual(header.key, "CONTENT-LENGTH")) {
              import std.conv;
              length = header.value.to!int;
            }
            else if(caselessEqual(header.key, "CONNECTION")) {
              if (caselessEqual(header.value, "CLOSE")) {
                connectionClose = true;
              }
            }
            goto case HEADER_START;
          }
        }
        return 0;
      case BODY:
        if (buf.length - pos >= length) {
          body_ = buf[pos..pos+length];
          pos = pos + length;
          state = END;
          goto case END;
        }
        return 0;
      case END:
        return 1;
      default:
        assert(false);
    }
    assert(false);
  }
}
