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

immutable bool[256] isURL = () {
  bool[256] table;
  foreach (ch; 0..128) {
      table[ch] = ch == '/' || ch == '-' || ch == '%' || ch == '.' || ch == '_' || 
      ch == '~' || ch == '?' || ch == '&' || ch == '=' || ch == ':' ||
      ch == '#' || ch == '+' || ch.isAlpha() || ch.isDigit();
  }
  return table;
}();

immutable bool[256] isVersion = () {
  bool[256] table;
  foreach (ch; 0..128) {
    table[ch] = ch == '.' || ch == '/' || ch.isAlpha() || ch.isDigit();
  }
  return table;
}();

immutable bool[256] isHeader = () {
  bool[256] table;
  foreach (ch; 0..128) {
    table[ch] = ch == '-' || ch.isAlpha() || ch.isDigit();
  }
  return table;
}();

bool isSpace(char c) {
  return c == ' ' || (c >= 0x09 && c <= 0x0D);
}

struct Slice {
  size_t start, end;

  const(char)[] instantiate(ref XBuf buf) {
    return cast(const(char)[])buf[start..end];
  }
}

struct HttpHeaderSlice {
  Slice key, value;

  HttpHeader instantiate(ref XBuf buf) {
    return HttpHeader(key.instantiate(buf), value.instantiate(buf));
  }
}

struct Parser {
private:
  XBuf buf;
  size_t begin;
  size_t pos;
  int state;
  HttpMethod method;
  Slice url;
  int length;
  public bool connectionClose;
  Buffer!(HttpHeaderSlice) headers;
  Buffer!(HttpHeader) parsedHeaders;
  HttpHeaderSlice header;
  Slice version_;
  Slice body_;
  public string error;
  
  public this(XBuf buf) {
    import std.algorithm.mutation;
    this.buf = move(buf);
    headers = Buffer!(HttpHeaderSlice)(16);
    parsedHeaders = Buffer!(HttpHeader)(16);
  }

  size_t skipWs(size_t p) {
    while (p < buf.length && isSpace(buf[p])) p++;
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
      else if(isSpace(buf[p])) {
        p++;
      } else {
        return size_t.max;
      }
    }
    return 0;
  }

  private static void shift(ref Slice slice, size_t offs) {
    slice.start -= offs;
    slice.end -= offs;
  }

  public void compact() {
    if (begin > 0) {
      buf.compact(begin);
      foreach (ref h; headers.data) {
        shift(h.key, begin);
        shift(h.value, begin);
      }
      shift(header.key, begin);
      shift(header.value, begin);
      shift(url, begin);
      shift(version_, begin);
      pos -= begin;
      begin = 0;
    }
  }

  public void reset() {
    begin = pos;
    state = 0;
    url = Slice(0, 0);
    header = HttpHeaderSlice.init;
    headers.clear();
    parsedHeaders.clear();
    method = HttpMethod.init;
    version_ = Slice(0, 0);
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
      req.body_ = cast(ubyte[])body_.instantiate(buf);
      req.version_ = version_.instantiate(buf);
      req.method = method;
      req.uri = url.instantiate(buf);
      foreach (h; headers.data) {
        parsedHeaders.put(h.instantiate(buf));
      }
      req.headers = parsedHeaders.data;
      return 1;
    }
  }

  int step() {
    size_t p = pos;
    with (HttpState) switch(state) {
      case 0: .. case METHOD:
        auto r = parseHttpMethod(buf, p, state, method);
        pos = p;
        if (r < 0) {
          error = "Wrong http method";
          return -1;
        }
        if (r == 0) {
          return 0;
        }
        state = HttpState.URL;
        goto case URL;
      case URL:
        p = skipWs(pos);
        auto start = p;
        while (p < buf.length) {
          if (isURL[buf[p]])
            p++;
          else
            break;
        }
        if (p == buf.length) {
          return 0;
        }
        pos = p;
        url.start = start;
        url.end = p;
        state = VERSION;
        goto case VERSION;
      case VERSION:
        p = skipWs(pos);
        auto start = p;
        while (p < buf.length) {
          if (isVersion[buf[p]])
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
        version_ .start = start;
        version_.end = p;
        state = HEADER_START;
        goto case HEADER_START;
      case HEADER_START:
        auto start = pos;
        p = pos;
        auto p2 = skipRN(p);
        if (p2 == 0) return 0;
        if (p2 != size_t.max) {
          pos = p2;
          state = BODY;
          goto case BODY;
        }
        while (p < buf.length) {
          if (isHeader[buf[p]])
            p++;
          else if (buf[p] == ':')
            break;
        }
        if (p == buf.length) return 0;
        header.key.start = start;
        header.key.end = p;
        p++;
        pos = p;
        state = HEADER_VALUE_START;
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
            header.value.start = start;
            header.value.end = end;
            headers.put(header);
            state = HEADER_START;
            pos = p;
            auto hk = header.key.instantiate(buf);
            auto hv = header.value.instantiate(buf);
            if (caselessEqual(hk, "CONTENT-LENGTH")) {
              import std.conv;
              length = hv.to!int;
            }
            else if(caselessEqual(hk, "CONNECTION")) {
              if (caselessEqual(hv, "CLOSE")) {
                connectionClose = true;
              }
            }
            goto case HEADER_START;
          }
        }
        return 0;
      case BODY:
        if (buf.length - pos >= length) {
          body_.start = pos;
          body_.end = pos + length;
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
