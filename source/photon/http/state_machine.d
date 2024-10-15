module phton.http.state_machine;

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

struct TrieEntry(T) {
    TrieEntry!T*[128] next;
    int id=0;
    bool final_;
    T payload;
}

void add(T)(TrieEntry!T* node, const(char)[] word, T payload) {
    TrieEntry!T* current = node;
    foreach (char w; word) {
        auto next = current.next[w];
        if (next == null) {
            current.next[w] = new TrieEntry!T;
            current = current.next[w];
        } else {
            current = next;
        } 
    }
    current.payload = payload;
}

void finalize(T)(TrieEntry!T* node) {
    import std.algorithm;
    void renumber(TrieEntry!T* root, ref int id) {
        root.id = id++;
        foreach (node; root.next[]) {
            if (node !is null)
                renumber(node, id);
        }
    }
    int n = 0;
    renumber(node, n);
    void finalizeStates(TrieEntry!T* root) {
        int nonNull = 0;
        foreach (node; root.next) {
            if (node !is null) {
                nonNull++;
                finalizeStates(node);
            }
        }
        if (nonNull == 0) root.final_ = true;
    }
    finalizeStates(node);
}

string toDot(T)(TrieEntry!T* root) {
    import std.conv;
    string buf = "digraph {\n";
    
    void plot(TrieEntry!T* root) {
        foreach(idx, node; root.next[]) {
            if (node !is null) {
                buf ~= "A" ~ root.id.to!string ~ " -> A" ~ node.id.to!string ~ " [label = " ~ cast(char)idx ~"]\n";
                plot(node);
            }
        }
    }
    plot(root);
    buf ~= "}";
    return buf;
}

struct Builder {
    string output;
    int indent;
    void incIndent() {
        indent += 4;
    }
    
    void decIndent() {
        indent -= 4;
    }

    void put(string line) {
        foreach (_; 0..indent) output ~= ' ';
        output ~= line;
        output ~= '\n';        
    }
}

void genCodeForState(T)(TrieEntry!T* node, ref Builder builder) {
    import std.format, std.ascii;
    if (node.final_) {
        builder.put("case %s:".format(node.id));
        builder.incIndent();
        builder.put("pos = p;");
        builder.put("state = s;");
        builder.put("e = %s.%s;".format(T.stringof, node.payload));
        builder.put("return 1;");
        builder.decIndent();
    } else {
        builder.put("case %s:".format(node.id));
        builder.incIndent();
        builder.put(`if (p == buf.length) {`);
        builder.incIndent();
        builder.put(`state = s;`);
        builder.put(`pos = p;`);
        builder.put(`return 0;`);
        builder.decIndent();
        builder.put(`}`);
        builder.put(`switch(buf[p]) {`);
        foreach (idx, n; node.next){
            if (n !is null) {
                builder.put(`case '%s','%s':`.format(toLower(cast(char)idx), toUpper(cast(char)idx)));
                builder.incIndent();
                builder.put(`p++;`);
                builder.put(`s = %s;`.format(n.id));
                builder.put(`goto case %d;`.format(n.id));
                builder.put(`break;`);
                builder.decIndent();
            }
        }
        builder.put(`default:`);
        builder.incIndent();
        builder.put(`pos = p;`);
        builder.put(`state = -1;`);
        builder.put(`return -1;`);
        builder.decIndent();
        builder.put(`}`);
        builder.put(`break;`);
        builder.decIndent();
    }
 }

auto generateStateMachine(alias enumeration)(string functionName) {
    enum members = __traits(allMembers, enumeration);
    Builder result;
    TrieEntry!enumeration* root = new TrieEntry!enumeration;
    static foreach (m; members) {
        add(root, m, mixin(enumeration.stringof~"."~m));
    }
    finalize(root);
    result.put(`import method;`);
    result.put(`int `~functionName~`(Buf)(ref Buf buf, ref size_t pos, ref int state, out `~enumeration.stringof~` e) {`);
    result.incIndent();
    result.put(`size_t p = pos;`);
    result.put(`int s = state;`);
    result.put(`switch(s) {`);
    result.incIndent();
    void recurse(TrieEntry!enumeration* node) {
        genCodeForState(node, result);
        foreach (n; node.next[]) {
            if (n !is null) {
                recurse(n);
            }
        }
    }
    recurse(root);
    result.decIndent();
    result.put(`}`);
    result.decIndent();
    result.put(`}`);
    return result.output;
}

enum m = generateStateMachine!HttpMethod("parseHttpMethod");

void main() {
    import std.stdio;
    writeln(m);
}

/+
int parse(Buf)(ref Buf buf, ref size_t pos, ref int state, out HttpMethod method) {
    size_t p = pos;
    int s = state;
    switch(s) {
    case some_state:
        if (p == buf.length) {
            state = s;
            pos = p;
            return 0;
        }
        switch(buf[p]) {
            case 'a','A':
                p++;
                s = next_state;
                break;
            default:
                pos = p;
                state = -1;
                return -1;
        }
        break;
    case final_state:
        pos = p;
        state = s;
        method = final_method;
        return 1;
    }
    case -1:
        return -1;
}
+/
