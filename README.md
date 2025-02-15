# Photon.http

An HTTP library developed for use with [Photon](https://github.com/DmitryOlshansky/photon) fiber scheduler but can be used as a standalone parser.

## Build

Use the basic flow of [DUB](https://dub.pm/getting-started/first-steps/#building-a-third-party-project).

To build release specifically use the following command:
```
dub build -b release
```
## Example

As a simple example here is a static hello world HTTP server running on std.socket/photon:

```d
#!/usr/bin/env dub
/+ dub.json:
    {
	    "name" : "hello",
        "dependencies": {
            "photon": "~>0.10.2",
            "photon-http": "~>0.5.1"
        }
    }
+/
import std.stdio;
import std.socket;

import photon, photon.http;

class HelloWorldProcessor : HttpProcessor {
    HttpHeader[] headers = [HttpHeader("Content-Type", "text/plain; charset=utf-8")];

    this(Socket sock){ super(sock); }
    
    override void handle(HttpRequest req) {
        respondWith("Hello, world!", 200, headers);
    }
}

void server_worker(Socket client) {
    scope processor =  new HelloWorldProcessor(client);
    try {
        processor.run();
    }
    catch(Exception e) {
        stderr.writeln(e);
    }
}

void server() {
    Socket server = new TcpSocket();
    server.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
    server.bind(new InternetAddress("0.0.0.0", 8080));
    server.listen(1000);

    debug writeln("Started server");

    void processClient(Socket client) {
        go(() => server_worker(client));
    }

    while(true) {
        try {
            debug writeln("Waiting for server.accept()");
            Socket client = server.accept();
            debug writeln("New client accepted");
            processClient(client);
        }
        catch(Exception e) {
            writefln("Failure to accept %s", e);
        }
    }
}

void main() {
    startloop();
    go(() => server());
    runFibers();
}

```

And here is the same but running on threads and std.socket without Photon:
```d
#!/usr/bin/env dub
/+ dub.json:
    {
	"name" : "hello",
        "dependencies": {
            "photon-http": "~>0.4.5"
        }
    }
+/
import std.stdio;
import std.socket;
import core.thread;

import photon.http;

class HelloWorldProcessor : HttpProcessor {
    HttpHeader[] headers = [HttpHeader("Content-Type", "text/plain; charset=utf-8")];

    this(Socket sock){ super(sock); }
    
    override void handle(HttpRequest req) {
        respondWith("Hello, world!", 200, headers);
    }
}

void server_worker(Socket client) {
    scope processor =  new HelloWorldProcessor(client);
    try {
        processor.run();
    }
    catch(Exception e) {
        stderr.writeln(e);
    }
}

void server() {
    Socket server = new TcpSocket();
    server.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
    server.bind(new InternetAddress("0.0.0.0", 8080));
    server.listen(1000);

    debug writeln("Started server");

    void processClient(Socket client) {
        new Thread(() => server_worker(client)).start();
    }

    while(true) {
        try {
            debug writeln("Waiting for server.accept()");
            Socket client = server.accept();
            debug writeln("New client accepted");
            processClient(client);
        }
        catch(Exception e) {
            writefln("Failure to accept %s", e);
        }
    }
}

void main() {
    new Thread(() => server()).start();
}

```



