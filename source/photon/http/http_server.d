/// An example "HTTP server" with poor usability but sensible performance
///
module photon.http.http_server;

import std.array, std.range, std.datetime, 
std.exception, std.format, std.uni,
std.algorithm.mutation, std.socket;

import core.stdc.stdlib, core.stdc.string;
import core.thread, core.atomic;

import photon.http.http_parser;

abstract class HttpProcessor {
	Socket sock;
	bool connectionClose;
    
	this(Socket sock) {
		this.sock = sock;
	}

	void respondWith(const(char)[] range, int status, HttpHeader[] headers) {
		char[] buf;
		import std.conv;
		
		buf ~= "HTTP/1.1 ";
		buf ~= status.to!string;
		buf ~= " OK\r\n";
		foreach (header; headers)
		{
			buf ~= header.name;
			buf ~= ": ";
			buf ~= header.value;
			buf ~= "\r\n";
		}
		buf ~= "Server: photon-http\r\n";
		auto t = atomicLoad(httpDate);
		buf ~= cast(const char[])*t;
		if (connectionClose) {
			buf ~= "Connection: close\r\n";
		}
		buf ~= "Content-Length: %d\r\n".format(range.length);
		buf ~= "\r\n";
		buf ~= range;
		sock.send(buf);
	}

	void respondWith(InputRange!dchar range, int status, HttpHeader[] headers) {
		char[] buf;
		foreach (el; range){
			buf ~= cast(char)el;
		}
		respondWith(buf, status, headers);
	}

    void handle(HttpRequest req);

	void run() {
		char[8096] buf;
		Parser parser;
		for (;;) {
			HttpRequest request;
			connectionClose = false;
			long size = sock.receive(buf);
			if (size == 0) break;
			enforce(size > 0);
			parser.put(buf[0..size]);
			while (!parser.empty) {
				with (ParserFields) switch(parser.front.tag) {
					case method:
						request.method = cast(HttpMethod)parser.front.method;
						break;
					case url:
						request.uri = parser.front.url;
						break;
					case header:
						request.headers ~= HttpHeader(
							parser.front.header.key,
							parser.front.header.value
						);
						if (sicmp(parser.front.header.key, "connection") == 0) {
							connectionClose = true;
						}
						break;
					case body_:
						request.body_ ~= parser.front.body_;
						break;
					case version_:
						request.version_ = parser.front.version_;
						break;
					default:
				}
				parser.popFront();
			}
			handle(request);
			parser.clear();
		}
	}
}

struct HttpHeader {
	const(char)[] name, value;
}

struct HttpRequest {
	HttpHeader[] headers;
	HttpMethod method;
	const(char)[] uri;
	const(char)[] version_;
	const(char)[] body_;
}

shared const(char)[]* httpDate;

shared static this(){
	Thread httpDateThread;
    Appender!(char[])[3] bufs;
    const(char)[][3] targets;
    {
        auto date = Clock.currTime!(ClockType.coarse)(UTC());
        size_t sz = writeDateHeader(bufs[0], date);
        targets[0] = bufs[0].data;
        atomicStore(httpDate, cast(shared)&targets[0]);
    }
    httpDateThread = new Thread({
        size_t cur = 1;
        for(;;){ 
            bufs[cur].clear();
            auto date = Clock.currTime!(ClockType.coarse)(UTC());
            writeDateHeader(bufs[cur], date);
            targets[cur] = cast(const)bufs[cur].data;
            atomicStore(httpDate, cast(shared)&targets[cur]);
            if (++cur == 3) cur = 0;
            Thread.sleep(250.msecs);
        }
    });
	httpDateThread.isDaemon = true;
    cast()httpDateThread.start(); 
}



// ==================================== IMPLEMENTATION DETAILS ==============================================
private:

struct ScratchPad {
	ubyte* ptr;
	size_t capacity;
	size_t last, current;

	this(size_t size) {
		ptr = cast(ubyte*)malloc(size);
		capacity = size;
	}

	void put(const(ubyte)[] slice)
	{
		enforce(current + slice.length <= capacity, "HTTP headers too long");
		ptr[current..current+slice.length] = slice[];
		current += slice.length;
	}

	const(ubyte)[] slice()
	{
		auto data = ptr[last..current];
		last = current;
		return data;
	}

	const(char)[] sliceStr()
	{
		return cast(const(char)[])slice;
	}

	void reset()
	{
		current = 0;
		last = 0;
	}

	@disable this(this);

	~this() {
		free(ptr);
		ptr = null;
	}
}

unittest
{
	auto pad = ScratchPad(1024);
	pad.put([1, 2, 3, 4]);
	pad.put([5, 6, 7]);
	assert(pad.slice == cast(ubyte[])[1, 2, 3, 4, 5, 6, 7]);
	pad.put([8, 9, 0]);
	assert(pad.slice == cast(ubyte[])[8, 9, 0]);
	pad.reset();
	assert(pad.slice == []);
	pad.put([3, 2, 1]);
	assert(pad.slice == cast(ubyte[])[3, 2, 1]);
}


string dayAsString(DayOfWeek day) {
    final switch(day) with(DayOfWeek) {
        case mon: return "Mon";
        case tue: return "Tue";
        case wed: return "Wed";
        case thu: return "Thu";
        case fri: return "Fri";
        case sat: return "Sat";
        case sun: return "Sun";
    }
}

string monthAsString(Month month){
    final switch(month) with (Month) {
        case jan: return "Jan";
        case feb: return "Feb";
        case mar: return "Mar";
        case apr: return "Apr";
        case may: return "May";
        case jun: return "Jun";
        case jul: return "Jul";
        case aug: return "Aug";
        case sep: return "Sep";
        case oct: return "Oct";
        case nov: return "Nov";
        case dec: return "Dec";
    }
}

size_t writeDateHeader(Output, D)(ref Output sink, D date){
    string weekDay = dayAsString(date.dayOfWeek);
    string month = monthAsString(date.month);
    return formattedWrite(sink,
        "Date: %s, %02s %s %04s %02s:%02s:%02s GMT\r\n",
        weekDay, date.day, month, date.year,
        date.hour, date.minute, date.second
    );
}

unittest
{
	import std.conv, std.regex, std.stdio;
	import core.thread;

	static struct TestCase {
		string raw;
		HttpMethod method;
		string reqBody;
		HttpHeader[] expected;
		string respPat;
	}

	static class TestHttpProcessor : HttpProcessor {
		TestCase[] cases;

		this(Socket sock, TestCase[] cases) {
			super(sock);
			this.cases = cases;
		}

		override void handle(HttpRequest req) {
			assert(req.method == cases.front.method, text(req.method));
			assert(req.headers == cases.front.expected, text("Unexpected:", req.headers));
			respondWith(req.body_, 200, []);
			cases.popFront();
		}
	}


	auto groups = [
		[
			TestCase("GET /test HTTP/1.1\r\n" ~
	         "Host: host\r\n" ~
	         "Accept: */*\r\n" ~
	         "Connection: close\r\n" ~
	         "Content-Length: 5\r\n" ~
	         "\r\nHELLO",
	         HttpMethod.GET,
	         "HELLO",
	         [ HttpHeader("Host", "host"), HttpHeader("Accept", "*/*"), HttpHeader("Connection", "close"), HttpHeader("Content-Length", "5")],
	         `HTTP/1.1 200 OK\r\nServer: photon-http\r\nDate: .* GMT\r\nConnection: close\r\nContent-Length: 5\r\n\r\nHELLO`
         	)
		],
		[
			TestCase("POST /test2 HTTP/1.1\r\n" ~
	         "Host: host\r\n" ~
	         "Accept: */*\r\n" ~
	         "Content-Length: 2\r\n" ~
	         "\r\nHI",
	         HttpMethod.POST,
	         "HI",
	         [ HttpHeader("Host", "host"), HttpHeader("Accept", "*/*"), HttpHeader("Content-Length", "2")],
	         `HTTP/1.1 200 OK\r\nServer: photon-http\r\nDate: .* GMT\r\nContent-Length: 2\r\n\r\nHI`
         	),
         	TestCase("GET /test3 HTTP/1.1\r\n" ~
	         "Host: host2\r\n" ~
	         "Accept: */*\r\n" ~
	         "Content-Length: 7\r\n" ~
	         "\r\nGOODBAY",
	         HttpMethod.GET,
	         "GOODBAY",
	         [ HttpHeader("Host", "host2"), HttpHeader("Accept", "*/*"), HttpHeader("Content-Length", "7")],
	         `HTTP/1.1 200 OK\r\nServer: photon-http\r\nDate: .* GMT\r\nContent-Length: 7\r\n\r\nGOODBAY`
         	)
		]
	];

	foreach (i, series; groups) {
		Socket[2] pair = socketPair();
		char[1024] buf;
		auto serv = new TestHttpProcessor(pair[1], series);
		auto t = new Thread({
			try {
				serv.run();
			} 
			catch(Throwable t) {
				stderr.writeln("Server failed: ", t);
				throw t;
			}
		});
		t.start();
		try {
			foreach(j, tc; series) {
				pair[0].send(tc.raw);
				size_t resp = pair[0].receive(buf[]);
				import std.stdio;
				if (!buf[0..resp].matchFirst(tc.respPat)) {
					writeln(buf[0..resp]);
					assert(false, text("test series:", i, "\ntest case ", j, "\n", buf[0..resp]));
				}
				
			}
		} finally { 
			pair[0].close();
			t.join();
		}
	}
}
