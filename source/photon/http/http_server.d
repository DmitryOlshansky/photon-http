/// An example "HTTP server" with poor usability but sensible performance
///
module photon.http.http_server;

import std.array, std.range, std.datetime, 
std.exception, std.format, std.uni,
std.algorithm, std.socket;

import core.stdc.stdlib, core.stdc.string, core.stdc.errno;
import core.thread, core.atomic, core.time;

import photon.http.state_machine, photon.http.http_parser;
import glow.xbuf;

void putInt(Output)(ref Output sink, long value) {
	immutable table = "0123456789";
	char[16] buf=void;
	size_t i = 16;
	do {
		buf[--i] = table[value % 10];
		value /= 10;
	} while(value);
	sink.put(buf[i..$]);
}

abstract class HttpProcessor {
	Socket sock;
	Buffer!char output;
	bool connectionClose;
    
	this(Socket sock) {
		this.sock = sock;
		try {
			sock.setOption(SocketOptionLevel.TCP, SocketOption.TCP_NODELAY, true);
		} catch(Exception e) { } // not tcp socket
		output = Buffer!char(256);
	}

	void respondWith(const(char)[] range, int status, HttpHeader[] headers) {
		output ~= "HTTP/1.1 ";
		putInt(output, status);
		output ~= " OK\r\n";
		foreach (header; headers)
		{
			output ~= header.key;
			output ~= ": ";
			output ~= header.value;
			output ~= "\r\n";
		}
		output ~= "Server: photon-http\r\n";
		auto t = atomicLoad(httpDate);
		output ~= cast(const char[])*t;
		if (connectionClose) {
			output ~= "Connection: close\r\n";
		}
		output ~= "Content-Length: ";
		putInt(output, range.length);
		output ~= "\r\n";
		output ~= "\r\n";
		output ~= range;
		if (output.length > 8096) flush();
	}

	void respondWith(InputRange!dchar range, int status, HttpHeader[] headers) {
		char[] buf;
		foreach (el; range){
			buf ~= el;
		}
		respondWith(buf, status, headers);
	}

	void flush() {
		sock.send(output.data);
		output.clear();
	}

    void handle(HttpRequest req);

	int read(ubyte[] s) nothrow {
		try {
			return cast(int)sock.receive(s);
		} catch(Throwable e) {
			assert(false);
		}
	}

	void run() {
		XBuf buf = XBuf(8096, 1024, &this.read);
		Parser parser = Parser(move(buf));
	L_serving:
		for (;;) {
			HttpRequest request;
			for (;;) {
				int r = parser.parse(request);
				if (r == 1) {
					break;
				}
				else if (r == 0) {
					if (output.length) flush();
					parser.compact();
					r = parser.load();
				}
				if (r == 0) break L_serving;
				else if (r < 0) {
					if (parser.error.ptr) {
						throw new Exception("Failed during http parsing: %s".format(parser.error));
					}
					auto zstr = strerror(errno);
					throw new Exception("I/O error %s".format(zstr[0..strlen(zstr)]));
				}
			}
			connectionClose = parser.connectionClose;
			handle(request);
			parser.reset();
			if (connectionClose) {
				if (output.length) flush();
				break;
			}
		}
	}
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
			respondWith(cast(char[])req.body_, 200, []);
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
			 "X-api-key: " ~ 'x'.repeat(1000).array.idup ~ "\r\n" ~
	         "Content-Length: 7\r\n" ~
	         "\r\nGOODBAY",
	         HttpMethod.GET,
	         "GOODBAY",
	         [ HttpHeader("Host", "host2"), HttpHeader("Accept", "*/*"), HttpHeader("X-api-key", 'x'.repeat(1000).array), HttpHeader("Content-Length", "7")],
	         `HTTP/1.1 200 OK\r\nServer: photon-http\r\nDate: .* GMT\r\nContent-Length: 7\r\n\r\nGOODBAY`
         	)
		]
	];

	void testGroup(void delegate(size_t, TestCase[], Socket) dg) {
		foreach (i, series; groups) {
			Socket[2] pair = socketPair();
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
				dg(i, series, pair[0]);
			} finally { 
				pair[0].close();
				t.join();
			}
		}
	}
	
	testGroup((size_t i, TestCase[] series, Socket sock) {
		char[1024] buf;
		foreach(j, tc; series) {
			for (size_t k = 0; k < tc.raw.length; k++) {
				Thread.sleep(1.msecs);
				sock.send(tc.raw[k..k+1]);
			}
			size_t resp = sock.receive(buf[]);
			if (!buf[0..resp].matchFirst(tc.respPat)) {
				writeln(buf[0..resp]);
				assert(false, text("test series:", i, "\ntest case ", j, "\n", buf[0..resp]));
			}
		}
	});

	testGroup((size_t i, TestCase[] series, Socket sock) {
		char[1024] buf;
		char[] reqs = reduce!((acc, t) => acc ~ t.raw)(new char[0], series);
		sock.send(reqs[0..min(100, $)]);
		Thread.sleep(100.msecs);
		sock.send(reqs[min(100, $)..$]);
		Thread.sleep(100.msecs);
		size_t resp = sock.receive(buf[]);
		size_t ofs = 0;
		foreach (j, tc; series) {
			auto m = buf[ofs..resp].matchFirst(tc.respPat);
			if (!m) {
				writeln(buf[0..resp]);
				assert(false, text("test series:", i, "\ntest case ", j, "\n", buf[0..resp]));
			}
			ofs = m.hit.ptr + m.hit.length - buf.ptr;
		}
	});
}
